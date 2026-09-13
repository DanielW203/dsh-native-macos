import Darwin
import Foundation

/// What the launched harness server is doing.
public struct HarnessServerState: Sendable, Equatable {
  public enum Phase: String, Sendable {
    case stopped
    case starting
    case running
    case failed
  }

  public var phase: Phase
  /// The URL the server announced once it finished booting.
  public var url: String?
  public var port: Int?
  public var pid: Int32?
  /// The last thing it said, or why it failed.
  public var detail: String?

  public init(phase: Phase, url: String? = nil, port: Int? = nil, pid: Int32? = nil, detail: String? = nil) {
    self.phase = phase
    self.url = url
    self.port = port
    self.pid = pid
    self.detail = detail
  }

  public static let stopped = HarnessServerState(phase: .stopped)

  public var isRunning: Bool { phase == .running }
}

/// Boots the installed runtime and stops it again.
///
/// The harness is a server, so it is started as a child process rather than driven
/// in-process, and a launch is only reported as ready once the server has announced the
/// URL it is listening on. Treating "the process is alive" as ready would hand the user a
/// link that refuses the connection for the next twenty seconds.
public actor HarnessLauncher {
  public let paths: RuntimePaths
  private let runner: ProcessRunning
  private let baseEnvironment: [String: String]
  private let toolchainResolver: ToolchainResolver
  private let entryProvider: @Sendable () async throws -> URL

  private var process: RunningProcess?
  private var current = HarnessServerState.stopped
  /// Tail of the server's output, kept for diagnosing a failed start.
  private var recentOutput: [String] = []

  public init(
    paths: RuntimePaths,
    entryProvider: @escaping @Sendable () async throws -> URL,
    runner: ProcessRunning = ProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.paths = paths
    self.entryProvider = entryProvider
    self.runner = runner
    self.baseEnvironment = baseEnvironment
    self.toolchainResolver = ToolchainResolver(paths: paths, runner: runner, baseEnvironment: baseEnvironment)
  }

  public func state() -> HarnessServerState {
    // A process that exited on its own is not a running server, however it was reported
    // when it started.
    if let process, !process.isRunning, current.phase == .running {
      current = HarnessServerState(
        phase: .stopped,
        detail: "The harness exited on its own (code \(process.pid))."
      )
    }
    return current
  }

  // MARK: - Start

  /// Boot the harness Web surface and wait until it is actually listening.
  /// - Parameter workingDirectory: the directory the harness runs in. It uses its
  ///   invoking directory as the default filesystem location, so this is what the Web UI
  ///   offers as the workspace. Defaults to the harness home.
  /// - Parameter onLine: every non-empty line the harness process itself prints.
  /// - Parameter onStage: what *this* app is doing between those lines — resolving the
  ///   toolchain, spawning the server, waiting for its address. A boot spends its first
  ///   ten seconds in here and prints nothing, so a window that only shows `onLine` sits
  ///   empty for that whole time; these lines are what keep it honest.
  public func start(
    profile: String,
    host: String = "127.0.0.1",
    workingDirectory: URL? = nil,
    timeout: TimeInterval = 120,
    onLine: @escaping @Sendable (String) -> Void = { _ in },
    onStage: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> HarnessServerState {
    if let process, process.isRunning { return state() }

    // A server recorded from an earlier run means the app that started it died without
    // cleaning up. Stop it first: the alternative is two servers on one home, which is
    // indistinguishable from a leak the next time the user looks.
    if takeOverStaleServer() {
      onStage("Stopped a harness left running by an earlier session.")
    }

    // The record covers the server *this app* spawned. A server the plugin market's
    // restart button produced is in its own session and overwrote the record with its own
    // pid, so it is invisible to the check above — and it survives an app upgrade, because
    // removing a release directory does not stop a process executing from it. Sweep by
    // identity instead of by record (see `HarnessProcessSweep`).
    HarnessServerRecord.reapOrphans(in: paths) { pid, port in
      let suffix = port.map { " (port \($0))" } ?? ""
      onStage("Stopped a stray harness server from an earlier run (pid \(pid)\(suffix)).")
    }

    onStage("Booting the \(profile) profile…")
    let port = try Self.freePort()
    onStage("Resolving the Node toolchain…")
    let toolchain = try await toolchainResolver.resolve()
    onStage("Node \(toolchain.nodeVersion) at \(toolchain.node.path)")
    onStage("Locating the installed harness…")
    let entry = try await entryProvider()
    onStage("Harness entry: \(entry.path)")

    // `--no-open` keeps the server from launching a browser of its own: this app decides
    // what opens, and a second window appearing on its own is not that decision.
    let arguments = Self.launchArguments(entry: entry, profile: profile, host: host, port: port)
    let request = ProcessRequest(
      executable: toolchain.node,
      arguments: arguments,
      environment: toolchainResolver.harnessEnvironment(for: toolchain),
      currentDirectory: workingDirectory ?? paths.dshHome,
      label: "harness web --port \(port)"
    )

    current = HarnessServerState(phase: .starting, port: port, detail: "Booting profile \(profile)…")
    recentOutput = []
    onStage("Starting: \(Self.commandLine(executable: toolchain.node, arguments: arguments))")

    let detector = URLDetector(host: host, port: port)
    let spawned = try await runner.spawn(request) { [weak self] _, line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      detector.observe(trimmed)
      onLine(trimmed)
      Task { await self?.remember(trimmed) }
    }
    process = spawned
    current.pid = spawned.pid
    HarnessServerRecord(pid: spawned.pid, port: port).save(to: paths)
    onStage("Waiting for the harness to announce its address (up to \(Int(timeout))s)…")

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let url = detector.url {
        current = HarnessServerState(
          phase: .running,
          url: url,
          port: port,
          pid: spawned.pid,
          detail: nil
        )
        return current
      }
      if !spawned.isRunning {
        let result = await spawned.wait()
        // The handle is dropped here, so anything still alive would keep this profile's
        // storage and its plugins' ports and be hit by the *next* start, which then exits
        // for no visible reason. Terminating a process that is already gone is a no-op;
        // terminating one that is not is the whole point of this line.
        spawned.terminate()
        process = nil
        current = HarnessServerState(
          phase: .failed,
          port: port,
          detail: "The harness exited with code \(result.exitCode).\n" + recentTail()
        )
        throw RuntimeError.installFailed(step: "harness web", detail: current.detail ?? "")
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }

    // Never became ready. Stop it rather than leave a half-booted server holding a port.
    spawned.terminate()
    _ = await spawned.wait(timeout: 10)
    process = nil
    current = HarnessServerState(
      phase: .failed,
      port: port,
      detail: "The harness did not become ready within \(Int(timeout))s.\n" + recentTail()
    )
    throw RuntimeError.installFailed(step: "harness web", detail: current.detail ?? "")
  }

  // MARK: - Stop

  /// Ask the server to stop and wait for it to actually go away.
  public func stop(timeout: TimeInterval = 15) async {
    guard let process else {
      current = .stopped
      return
    }
    process.terminate()
    _ = await process.wait(timeout: timeout)
    self.process = nil
    current = .stopped
    HarnessServerRecord.clear(in: paths)
  }

  /// Stop a harness left behind by a previous run, if one is really still there.
  ///
  /// The record is removed either way: once it has been examined it is stale by
  /// definition, and leaving it would make the next launch repeat this check against a
  /// process id that may since have been reused.
  /// - Returns: whether a live server was actually stopped.
  @discardableResult
  private func takeOverStaleServer() -> Bool {
    guard let record = HarnessServerRecord.load(from: paths) else { return false }
    defer { HarnessServerRecord.clear(in: paths) }
    guard record.isAlive, record.isListening else { return false }

    kill(record.pid, SIGTERM)
    // A deadline, not a fixed count: `for _ in 0..<30 where record.isAlive` keeps sleeping
    // out the remaining iterations after the process is already gone, which cost every
    // launch that took over a leftover three extra seconds of doing nothing.
    let deadline = Date().addingTimeInterval(3)
    while record.isAlive, Date() < deadline {
      usleep(100_000)
    }
    if record.isAlive { kill(record.pid, SIGKILL) }
    recentOutput.append("stopped a harness left running by an earlier session (pid (record.pid))")
    return true
  }

  /// The launch command, one line, for a boot log that has to show what is about to run.
  static func commandLine(executable: URL, arguments: [String]) -> String {
    ([executable.path] + arguments).joined(separator: " ")
  }

  private func remember(_ line: String) {
    recentOutput.append(line)
    if recentOutput.count > 200 { recentOutput.removeFirst(recentOutput.count - 200) }
  }

  private func recentTail() -> String {
    recentOutput.suffix(20).joined(separator: "\n")
  }

  /// The command line that boots the Web surface.
  ///
  /// A leading "web" is deliberately absent: the shipped CLI treats it as a subcommand
  /// alias for --profile web, and passing both is rejected outright with
  /// "web takes none of parent --profile...". --host, --port and --no-open are app
  /// arguments and follow the launcher's flags.
  static func launchArguments(entry: URL, profile: String, host: String, port: Int) -> [String] {
    [
      entry.path,
      "--profile", profile,
      "--host", host,
      "--port", String(port),
      "--no-open",
    ]
  }

  // MARK: - Port selection

  /// Ask the kernel for an unused port on the loopback interface.
  ///
  /// The port is released before the harness binds it, so there is an unavoidable race.
  /// The alternative — letting the server choose and reporting the port afterwards — is
  /// not available: the shipped Web app documents `--port` but no "pick one" value.
  static func freePort(host: String = "127.0.0.1") throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw RuntimeError.installFailed(step: "port", detail: "socket(): \(String(cString: strerror(errno)))")
    }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr(host == "127.0.0.1" ? "127.0.0.1" : "127.0.0.1")

    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      throw RuntimeError.installFailed(step: "port", detail: "bind(): \(String(cString: strerror(errno)))")
    }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(descriptor, sockaddrPointer, &length)
      }
    }
    guard named == 0 else {
      throw RuntimeError.installFailed(step: "port", detail: "getsockname(): \(String(cString: strerror(errno)))")
    }
    return Int(UInt16(bigEndian: address.sin_port))
  }
}

/// Watches a server's output for the URL it announces.
///
/// Lines arrive on a reader thread while the actor that started the process polls, so the
/// value is guarded rather than actor-isolated.
final class URLDetector: @unchecked Sendable {
  private let lock = NSLock()
  private var detected: String?
  private let prefix: String

  init(host: String, port: Int) {
    self.prefix = "http://\(host):\(port)"
  }

  var url: String? {
    lock.lock(); defer { lock.unlock() }
    return detected
  }

  func observe(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    guard detected == nil else { return }

    // The banner reads: dsh web: http://127.0.0.1:<port>/?token=<secret>
    //
    // The query string is not decoration — the server answers a request without the token
    // with 401 — so the whole URL is captured rather than the host:port prefix. Matching
    // on the exact host:port we asked for still guards against latching onto an unrelated
    // URL in a log line.
    guard let start = line.range(of: "http://") else { return }
    let candidate = line[start.lowerBound...].prefix { !$0.isWhitespace }
    guard candidate.hasPrefix(prefix) else { return }
    detected = String(candidate)
  }
}
