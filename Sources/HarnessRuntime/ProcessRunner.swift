import Darwin
import Foundation

/// Which pipe a line arrived on.
public enum ProcessStream: String, Sendable, Equatable {
  case stdout
  case stderr
}

/// One subprocess invocation.
///
/// The environment is passed whole rather than inherited: every harness process must
/// see an explicit `DSH_HOME` and an explicit `PATH` (the pnpm shim directory has to
/// win), so inheriting the app's environment and patching it in two places is how the
/// isolation silently breaks.
public struct ProcessRequest: Sendable {
  public var executable: URL
  public var arguments: [String]
  public var environment: [String: String]
  public var currentDirectory: URL?
  /// Seconds to wait before the process group is asked to stop. `nil` waits forever.
  public var timeout: TimeInterval?
  public var standardInput: Data?
  /// Shown in diagnostics; never passed to the process.
  public var label: String

  public init(
    executable: URL,
    arguments: [String] = [],
    environment: [String: String] = [:],
    currentDirectory: URL? = nil,
    timeout: TimeInterval? = nil,
    standardInput: Data? = nil,
    label: String? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.currentDirectory = currentDirectory
    self.timeout = timeout
    self.standardInput = standardInput
    self.label = label ?? executable.lastPathComponent
  }
}

/// The outcome of one invocation. Both pipes are captured in full; callers that want
/// streaming use `onLine` and may ignore the aggregates.
public struct ProcessResult: Sendable, Equatable {
  public var exitCode: Int32
  public var stdout: String
  public var stderr: String
  public var duration: TimeInterval
  public var timedOut: Bool
  /// True when the process did not exit on its own and was signalled.
  public var signalled: Bool

  public init(
    exitCode: Int32,
    stdout: String,
    stderr: String,
    duration: TimeInterval,
    timedOut: Bool = false,
    signalled: Bool = false
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.duration = duration
    self.timedOut = timedOut
    self.signalled = signalled
  }

  public var succeeded: Bool { exitCode == 0 && !timedOut }

  /// Tail of both pipes, for diagnostics that quote what actually went wrong.
  public func diagnostics(maxLines: Int = 40) -> String {
    var lines: [String] = []
    let sep = "\n"
    let out = stdout.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines)
    let err = stderr.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines)
    if !out.isEmpty { lines.append("stdout:" + sep + out.joined(separator: sep)) }
    if !err.isEmpty { lines.append("stderr:" + sep + err.joined(separator: sep)) }
    return lines.joined(separator: "\n")
  }
}

/// Runs a subprocess to completion.
public protocol ProcessRunning: Sendable {
  func run(
    _ request: ProcessRequest,
    onLine: (@Sendable (ProcessStream, String) -> Void)?
  ) async throws -> ProcessResult

  /// Start a process without waiting for it to exit.
  ///
  /// Separate from §run§ because a long-running child — the harness server — cannot be
  /// expressed by a call that only returns once the process is gone.
  func spawn(
    _ request: ProcessRequest,
    onLine: (@Sendable (ProcessStream, String) -> Void)?
  ) async throws -> RunningProcess
}

extension ProcessRunning {
  public func run(_ request: ProcessRequest) async throws -> ProcessResult {
    try await run(request, onLine: nil)
  }

  /// The default refuses rather than pretending.
  ///
  /// A runner that only knows how to run something to completion cannot honestly hand back
  /// a handle to a live process, and a test double has no business starting one.
  public func spawn(
    _ request: ProcessRequest,
    onLine: (@Sendable (ProcessStream, String) -> Void)?
  ) async throws -> RunningProcess {
    throw RuntimeError.unsupported("this process runner cannot start a long-running child")
  }
}

/// A `posix_spawn`-based runner.
///
/// `Foundation.Process` is not used for two reasons that matter here:
///
/// 1. It places the child in the caller's process group, so stopping a hung \pnpm
///    install would either leave its children running or signal this app. The plan
///    promises group termination, so the child gets its own group via
///    `POSIX_SPAWN_SETPGROUP` and is stopped with `kill(-pid, …)`.
/// 2. Its termination plumbing surfaces exit status through a callback whose ordering
///    against pipe EOF is unspecified, which makes "read everything, then reap" racy.
///    Here the readers are joined before `waitpid` returns a result — within the bound in
///    `RunningProcess.readerJoinGrace`, so a pipe held open by a process that outlived the
///    group cannot turn "stop the harness" into "wait forever".
public final class ProcessRunner: ProcessRunning, @unchecked Sendable {
  public init() {}

  public func run(
    _ request: ProcessRequest,
    onLine: (@Sendable (ProcessStream, String) -> Void)? = nil
  ) async throws -> ProcessResult {
    let process = try await spawn(request, onLine: onLine)
    return await process.wait(timeout: request.timeout)
  }

  /// Start a process and return a handle to it, without waiting for it to exit.
  ///
  /// Waiting is the wrong shape for a long-running child — the harness server runs until
  /// it is stopped — but the timeout still applies: a server that never becomes ready has
  /// to be stopped too, and it is stopped the same way, by escalating the whole process
  /// group.
  public func spawn(
    _ request: ProcessRequest,
    onLine: (@Sendable (ProcessStream, String) -> Void)? = nil
  ) async throws -> RunningProcess {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          continuation.resume(returning: try Self.spawnSync(request, onLine: onLine))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - Synchronous core

  private static func spawnSync(
    _ request: ProcessRequest,
    onLine: (@Sendable (ProcessStream, String) -> Void)?
  ) throws -> RunningProcess {
    let started = Date()

    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    var inPipe: [Int32] = [0, 0]
    guard pipe(&outPipe) == 0, pipe(&errPipe) == 0, pipe(&inPipe) == 0 else {
      throw RuntimeError.installFailed(step: request.label, detail: "pipe() failed: \(String(cString: strerror(errno)))")
    }

    // A process may not keep an unrelated half of a pipe open, or the reader never
    // sees EOF and the call hangs after the child has already exited.
    var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
    if request.standardInput == nil {
      let devNull = open("/dev/null", O_RDONLY)
      if devNull >= 0 {
        posix_spawn_file_actions_adddup2(&actions, devNull, STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, devNull)
      }
    } else {
      posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
    }
    posix_spawn_file_actions_addclose(&actions, outPipe[0])
    posix_spawn_file_actions_addclose(&actions, errPipe[0])
    if request.standardInput != nil {
      posix_spawn_file_actions_addclose(&actions, inPipe[1])
    }
    if let directory = request.currentDirectory {
      // Directories are the one place a raw C string is unavoidable; a path with an
      // interior NUL cannot be represented, and rejecting it is better than truncating.
      if directory.path.utf8.contains(0) {
        throw RuntimeError.installFailed(step: request.label, detail: "working directory contains NUL")
      }
      posix_spawn_file_actions_addchdir_np(&actions, directory.path)
    }

    var attributes = posix_spawnattr_t(nil as OpaquePointer?)
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // New process group with the child as leader, so kill(-pid) reaches the whole
    // install tree without touching this app.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)

    let argv = ([request.executable.path] + request.arguments).map { strdup($0) }
    defer { argv.forEach { free($0) } }
    var argvPointer = argv + [nil]
    let envp = request.environment.map { strdup("\($0.key)=\($0.value)") }
    defer { envp.forEach { free($0) } }
    var envpPointer = envp + [nil]

    var pid: pid_t = 0
    let spawnResult: Int32 = argvPointer.withUnsafeMutableBufferPointer { argvBuffer in
      envpPointer.withUnsafeMutableBufferPointer { envpBuffer in
        posix_spawn(
          &pid,
          request.executable.path,
          &actions,
          &attributes,
          argvBuffer.baseAddress,
          envpBuffer.baseAddress
        )
      }
    }
    guard spawnResult == 0 else {
      close(outPipe[0]); close(outPipe[1])
      close(errPipe[0]); close(errPipe[1])
      close(inPipe[0]); close(inPipe[1])
      let detail = String(cString: strerror(spawnResult))
      throw RuntimeError.installFailed(
        step: request.label,
        detail: "cannot execute \(request.executable.path): \(detail)"
      )
    }

    close(outPipe[1])
    close(errPipe[1])
    if request.standardInput != nil { close(inPipe[0]) } else { close(inPipe[0]); close(inPipe[1]) }

    let outCollector = OutputCollector(stream: .stdout, onLine: onLine)
    let errCollector = OutputCollector(stream: .stderr, onLine: onLine)
    let readers = DispatchGroup()
    readers.enter()
    Thread.detachNewThread {
      drain(outPipe[0], into: outCollector)
      readers.leave()
    }
    readers.enter()
    Thread.detachNewThread {
      drain(errPipe[0], into: errCollector)
      readers.leave()
    }

    if let input = request.standardInput {
      let handle = FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: true)
      DispatchQueue.global(qos: .userInitiated).async {
        try? handle.write(contentsOf: input)
        try? handle.close()
      }
    }

    let process = RunningProcess(
      pid: pid,
      label: request.label,
      executable: request.executable.path,
      readers: readers,
      stdout: outCollector,
      stderr: errCollector,
      started: started
    )

    // The child is reaped on a dedicated thread, which then joins the readers before
    // publishing a result: reading everything before reporting an exit code is what makes
    // the returned output complete rather than racing the last chunk.
    Thread.detachNewThread {
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1 && errno == EINTR { continue }
      process.recordExit(status)
    }
    return process
  }

  /// Read until EOF, handing complete lines to the collector as they arrive.
  private static func drain(_ descriptor: Int32, into collector: OutputCollector) {
    defer { close(descriptor) }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count > 0 {
        collector.append(Data(bytes: buffer, count: count))
      } else if count == 0 {
        return
      } else if errno != EINTR {
        return
      }
    }
  }
}

/// A started process, and the only way to observe or stop it.
///
/// Holds the process group id, so stopping means stopping the whole tree — the harness
/// server spawns workers, and leaving them behind would leave the port bound.
public final class RunningProcess: @unchecked Sendable {
  public let pid: pid_t
  public let label: String
  /// The program this handle started, kept so a delayed signal can prove the pid is still
  /// this process and not a recycled number. See `terminate(grace:)`.
  public let executable: String

  /// How long a stopped process group gets to exit before it is killed. Not private:
  /// it is the default for `terminate`'s grace period.
  static let killGrace: TimeInterval = 5

  /// How long the exit path waits for the pipe readers once the child has been reaped.
  ///
  /// The readers are what makes a returned result carry everything the child printed, and
  /// in the normal case they finish the moment it exits. They cannot be joined without a
  /// bound: a *grandchild* that inherited the pipe and left the process group — a plugin
  /// that daemonises itself is the real example — keeps the write end open long after the
  /// child is gone, and a result the kernel already has must not be withheld because of a
  /// process this handle never owned. A quit that waits on that is a quit that never
  /// happens: measured on this machine, `wait(timeout: 1)` took 8s because of one
  /// `setsid()`ed `sleep`.
  static let readerJoinGrace: TimeInterval = 2

  private let lock = NSLock()
  private let readers: DispatchGroup
  private let stdoutCollector: OutputCollector
  private let stderrCollector: OutputCollector
  private let started: Date

  private var status: Int32 = 0
  private var timedOut = false
  private var finalResult: ProcessResult?
  private var waiters: [CheckedContinuation<ProcessResult, Never>] = []

  init(
    pid: pid_t,
    label: String,
    executable: String,
    readers: DispatchGroup,
    stdout: OutputCollector,
    stderr: OutputCollector,
    started: Date
  ) {
    self.pid = pid
    self.label = label
    self.executable = executable
    self.readers = readers
    self.stdoutCollector = stdout
    self.stderrCollector = stderr
    self.started = started
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return finalResult == nil
  }

  /// Wait for the process to exit, optionally stopping it after `timeout` seconds.
  public func wait(timeout: TimeInterval? = nil) async -> ProcessResult {
    if let timeout {
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
        guard let self, self.isRunning else { return }
        self.lock.lock()
        self.timedOut = true
        self.lock.unlock()
        self.terminate(grace: Self.killGrace)
      }
    }
    return await withCheckedContinuation { continuation in
      lock.lock()
      if let finalResult {
        lock.unlock()
        continuation.resume(returning: finalResult)
        return
      }
      waiters.append(continuation)
      lock.unlock()
    }
  }

  /// Ask the process group to stop, escalating to `SIGKILL` after `grace` seconds.
  ///
  /// Returns whether a signal was actually sent, so a caller can tell "stopped it" from
  /// "it had already exited".
  @discardableResult
  public func terminate(grace: TimeInterval = 5) -> Bool {
    guard isRunning else { return false }
    kill(-pid, SIGTERM)
    let pid = self.pid
    let executable = self.executable
    DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
      // A process that ignores SIGTERM would otherwise hold the port forever — but a
      // process *group* id is a pid, and a pid becomes reusable the moment its owner is
      // gone, so an unconditional `kill(-pid, SIGKILL)` here shoots whoever owns the
      // number by the time it fires. On this machine that was a fresh harness dying with
      // `-9` seconds after a restart, for no reason its own log could explain. The command
      // line is the one thing a recycled number cannot copy by accident, so it is the
      // check.
      guard Self.isStill(pid: pid, executable: executable) else { return }
      kill(-pid, SIGKILL)
    }
    return true
  }

  /// Whether `pid` is still the process that was started from `executable`.
  ///
  /// `kill(pid, 0)` alone is not an answer: a recycled pid is perfectly alive. The argument
  /// vector is. An unreadable one counts as "not ours" on purpose — a leaked server is
  /// swept up by the next start (`HarnessProcessSweep`), while a signal delivered to a
  /// stranger is not recoverable.
  static func isStill(pid: pid_t, executable: String) -> Bool {
    guard kill(pid, 0) == 0 || errno == EPERM else { return false }
    guard let argv = HarnessProcessSweep.arguments(of: pid) else { return false }
    return argv.contains(executable)
  }

  /// Called once by the reaper thread. Joins the readers — within a bound — then publishes.
  func recordExit(_ status: Int32) {
    // Bounded on purpose: see `readerJoinGrace`. A grandchild that inherited the pipe and
    // left the process group must not be able to hold a caller that is quitting the app.
    _ = readers.wait(timeout: .now() + Self.readerJoinGrace)
    let stdout = stdoutCollector.text()
    let stderr = stderrCollector.text()
    let duration = Date().timeIntervalSince(started)

    lock.lock()
    self.status = status
    let exited = (status & 0x7f) == 0
    let result = ProcessResult(
      exitCode: exited ? (status >> 8) & 0xff : -(status & 0x7f),
      stdout: stdout,
      stderr: stderr,
      duration: duration,
      timedOut: timedOut,
      signalled: !exited
    )
    guard finalResult == nil else {
      lock.unlock()
      return
    }
    finalResult = result
    let pending = waiters
    waiters = []
    lock.unlock()

    for continuation in pending { continuation.resume(returning: result) }
  }
}


/// Accumulates a pipe and emits lines as they complete.
///
/// The aggregate is bounded. It exists for diagnostics on a command that terminates, but
/// the same collector serves a server that runs for hours, and retaining every byte such
/// a process prints would grow without bound. Only the tail is ever read back.
final class OutputCollector: @unchecked Sendable {
  /// Bytes of aggregate retained before the oldest are discarded.
  private static let retainedByteLimit = 4 * 1024 * 1024

  private let lock = NSLock()
  private var data = Data()
  private var pending = ""
  private let stream: ProcessStream
  private let onLine: (@Sendable (ProcessStream, String) -> Void)?

  init(stream: ProcessStream, onLine: (@Sendable (ProcessStream, String) -> Void)?) {
    self.stream = stream
    self.onLine = onLine
  }

  func append(_ chunk: Data) {
    lock.lock()
    data.append(chunk)
    if data.count > Self.retainedByteLimit {
      data.removeFirst(data.count - Self.retainedByteLimit)
    }
    guard let handler = onLine else {
      lock.unlock()
      return
    }
    pending += String(decoding: chunk, as: UTF8.self)
    var lines: [String] = []
    while let index = pending.firstIndex(of: "\n") {
      var line = String(pending[pending.startIndex..<index])
      pending = String(pending[pending.index(after: index)...])
      if line.hasSuffix("\r") { line.removeLast() }
      lines.append(line)
    }
    lock.unlock()
    for line in lines { handler(stream, line) }
  }

  func text() -> String {
    lock.lock()
    var tail = pending
    pending = ""
    lock.unlock()
    var text = String(decoding: data, as: UTF8.self)
    if !tail.isEmpty {
      if tail.hasSuffix("\r") { tail.removeLast() }
      text += tail
    }
    return text
  }
}
