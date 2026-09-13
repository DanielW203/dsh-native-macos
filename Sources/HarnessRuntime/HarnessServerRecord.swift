import Darwin
import Foundation

/// A note of which harness server is running for this home.
///
/// The harness runs in its own process group, so it does not die with the app that
/// started it. That is deliberate — it means a signal aimed at one process cannot reach
/// the other — but it also means an app that dies without cleaning up leaves a server
/// listening and consuming memory with nothing pointing at it. The next launch then
/// starts a second one, which is exactly the state this record exists to prevent.
///
/// Only the process id and port are stored, never the access token: taking over means
/// stopping the old server, not attaching to it, so nothing here needs to authenticate.
struct HarnessServerRecord: Codable, Sendable, Equatable {
  var pid: Int32
  var port: Int

  static func url(in paths: RuntimePaths) -> URL {
    paths.harnessRoot.appendingPathComponent("server.json", isDirectory: false)
  }

  static func load(from paths: RuntimePaths) -> HarnessServerRecord? {
    guard let data = try? Data(contentsOf: url(in: paths)) else { return nil }
    return try? JSONDecoder().decode(HarnessServerRecord.self, from: data)
  }

  func save(to paths: RuntimePaths) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    try? data.write(to: Self.url(in: paths), options: .atomic)
  }

  static func clear(in paths: RuntimePaths) {
    try? FileManager.default.removeItem(at: url(in: paths))
  }

  /// Whether the recorded process still exists.
  var isAlive: Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }

  /// Stop every harness server for this home that this app did not start in this run.
  ///
  /// The record above covers the common case — this app spawned a server, died, and left
  /// it listening — because a single pid is enough when a single server exists. It is not
  /// enough for a server the app never spawned: the plugin market's restart button brings
  /// its replacement up through a detached helper, in its own session, and the
  /// replacement then writes its own pid into this same record. Any older server is
  /// therefore unreachable by pid, which is how three servers came to share one home and
  /// survive an app upgrade.
  ///
  /// The sweep closes that gap by identity rather than by record: see
  /// `HarnessProcessSweep`. It is safe to run on every start — it stops only processes
  /// executing the harness entry point out of this app's own release tree, never the
  /// caller's own process, and never anything on pid 1.
  /// - Parameter onStop: called once per stopped server, for the boot log.
  /// - Returns: the servers that were stopped, as `(pid, port)` where the port was
  ///   recoverable from the command line.
  @discardableResult
  static func reapOrphans(
    in paths: RuntimePaths,
    onStop: (Int32, Int?) -> Void = { _, _ in }
  ) -> [(pid: Int32, port: Int?)] {
    let candidates = runningServers(in: paths.releasesDirectory)
    guard !candidates.isEmpty else { return [] }

    let stopped = HarnessProcessSweep.terminate(candidates.map(\.pid))
    let stoppedSet = Set(stopped)
    return candidates.compactMap { entry in
      guard stoppedSet.contains(entry.pid) else { return nil }
      let port = Self.port(inArguments: entry.argv)
      onStop(entry.pid, port)
      return (pid: entry.pid, port: port)
    }
  }

  /// Harness servers currently running out of `directory`, this process excluded.
  ///
  /// Pointed at `paths.releasesDirectory` this is "every server this app owns"; pointed at
  /// one release directory it is "who is still executing the release about to be
  /// deleted". Both callers want the same answer from the same evidence, so the scoping
  /// is a parameter rather than two code paths.
  static func runningServers(in directory: URL) -> [(pid: Int32, argv: [String])] {
    HarnessProcessSweep.servers(under: directory, excluding: [getpid()])
      .map { (pid: Int32($0.pid), argv: $0.argv) }
  }

  /// The `--port` value a harness server was launched with, when it is stated.
  ///
  /// Used only to label a stopped server in the log; a missing port never prevents a
  /// stop, because the pid is the thing being acted on.
  static func port(inArguments argv: [String]) -> Int? {
    guard let flag = argv.firstIndex(of: "--port") else { return nil }
    let value = argv.index(after: flag)
    guard value < argv.count else { return nil }
    return Int(argv[value])
  }

  /// Whether something still accepts connections on the recorded port.
  ///
  /// The second half of the takeover predicate. A process id can be reused after the
  /// original exits, so liveness alone would let this kill an unrelated process that
  /// happened to inherit the number; requiring the port it was serving to answer as well
  /// makes a false positive require both a reused id and an unrelated listener on the
  /// exact port this app picked.
  var isListening: Bool {
    guard port > 0, port < 65_536 else { return false }
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    // Non-blocking: a stale record must not stall the launch behind a connect timeout.
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected == 0 { return true }
    guard errno == EINPROGRESS else { return false }

    var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    guard poll(&descriptorSet, 1, 300) > 0 else { return false }
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length)
    return socketError == 0
  }
}
