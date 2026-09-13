import Foundation
import XCTest
@testable import HarnessRuntime

/// Regression cover for the leaked-server bug.
///
/// The bug was not a wrong branch, it was a missing actor: a harness server started by
/// the plugin market's restart button ran in a session of its own, replaced the
/// `server.json` record with its own pid, and stayed alive across an app upgrade — 384 MB
/// and a session lock for two days, with the app structurally unable to see it. Every
/// assertion below therefore runs against **real processes**: a sweep that only agrees
/// with a mock is exactly the kind of test that would have passed while the leak was
/// happening.
final class HarnessProcessSweepTests: XCTestCase {
  private var spawned: [RunningProcess] = []
  private let runner = ProcessRunner()

  override func tearDown() async throws {
    for process in spawned { process.terminate(grace: 0.2) }
    spawned = []
    try await super.tearDown()
  }

  // MARK: - Argument reading

  func testReadsTheArgumentVectorOfALiveProcess() async throws {
    let entry = try makeFakeHarnessEntry(named: "argv")
    let process = try await spawnServer(entry: entry, port: 5999)

    let commandLine = try XCTUnwrap(
      HarnessProcessSweep.arguments(of: process.pid),
      "KERN_PROCARGS2 should report a process this test owns"
    )
    XCTAssertTrue(
      commandLine.contains(entry.path),
      "the harness entry point is what identifies a server; got \(commandLine)"
    )
    XCTAssertEqual(HarnessServerRecord.port(inArguments: commandLine), 5999)
  }

  func testReportsNothingForAProcessTheKernelRefuses() {
    // pid 1 (launchd) belongs to root: the kernel answers EPERM, which must read as
    // "unknown", never as "no arguments".
    XCTAssertNil(HarnessProcessSweep.arguments(of: 1))
  }

  // MARK: - Identifying a server

  func testFindsOnlyServersRunningFromTheReleaseTree() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    let inside = try makeFakeHarnessEntry(named: "inside", root: root)

    let inServer = try await spawnServer(entry: inside, port: 6001)

    // Same command shape, a script OUTSIDE the release tree: the sweep must not claim it.
    // This is the assertion that keeps the sweep from becoming "kill all node processes",
    // and it is why the decoy has to live elsewhere — a decoy under `releases/` would be a
    // server by definition, since that tree is this app's own.
    let decoy = root.appendingPathComponent("elsewhere/lib/bin.js")
    try TestSupport.write("#!/bin/sh\nwhile :; do sleep 1; done\n", to: decoy, executable: true)
    let outServer = try await spawnProcess(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: [decoy.path, "--profile", "web", "--port", "6002"]
    )

    let found = HarnessProcessSweep.servers(under: paths.releasesDirectory)
    XCTAssertEqual(found.map(\.pid), [inServer.pid])
    XCTAssertEqual(HarnessServerRecord.port(inArguments: found[0].argv), 6001)
  }

  func testExcludedPidsAreNeverReturned() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    let entry = try makeFakeHarnessEntry(named: "excluded", root: root)
    let server = try await spawnServer(entry: entry, port: 6003)

    let found = HarnessProcessSweep.servers(under: paths.releasesDirectory, excluding: [server.pid])
    XCTAssertTrue(found.isEmpty, "the caller's own process must be excludable")
  }

  // MARK: - Stopping

  func testTerminateRefusesThisProcessAndPidOne() {
    let stopped = HarnessProcessSweep.terminate([getpid(), 1], grace: 0.1)
    XCTAssertTrue(stopped.isEmpty)
    XCTAssertGreaterThan(getpid(), 1, "the test process is still here, which is the point")
  }

  func testReapingStopsAStrayServerForTheHome() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    let entry = try makeFakeHarnessEntry(named: "stray", root: root)
    let server = try await spawnServer(entry: entry, port: 6004)
    XCTAssertTrue(server.isRunning, "precondition: the stray is alive before the sweep")

    var logged: [(pid: Int32, port: Int?)] = []
    let reaped = HarnessServerRecord.reapOrphans(in: paths) { pid, port in
      logged.append((pid, port))
    }

    XCTAssertEqual(reaped.map(\.pid), [server.pid])
    XCTAssertEqual(reaped.first?.port, 6004)
    XCTAssertEqual(logged.map(\.pid), [server.pid], "each stop is reported for the boot log")

    // Reaped through this test's own `ProcessRunner`, the stray becomes this test's child,
    // so the proof that it died is the exit status — `kill(pid, 0)` keeps answering "alive"
    // for a zombie, which is why asserting on it alone would pass on a broken sweep.
    let result = await server.wait(timeout: 10)
    XCTAssertFalse(server.isRunning, "the stray must actually be gone (exit \(result.exitCode))")
  }

  func testReapingIsIdempotentWhenNothingIsRunning() throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    XCTAssertTrue(HarnessServerRecord.reapOrphans(in: paths).isEmpty)
  }

  // MARK: - Removing a release that is still running

  /// The second half of the bug: `remove(_:)` deleted a release directory while a process
  /// was still executing the code inside it, which is how a server came to be running a
  /// release that no longer existed — nothing left to match it against, no file to inspect,
  /// only memory. A directory that is the last handle on a live process is not free to
  /// delete.
  func testRemovingAReleaseStopsTheServerRunningOutOfIt() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    let id = "0.1.5-rc.1-registry-npm"
    let release = paths.releaseDirectory(id)

    // The fake harness entry lives where a real one does, inside the release directory.
    let lib = release.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    let entry = try TestSupport.write(
      "#!/bin/sh\nwhile :; do sleep 1; done\n",
      to: lib.appendingPathComponent("bin.js"),
      executable: true
    )

    try TestSupport.installFakeToolchain(into: paths)
    let stale = HarnessRelease(
      id: id,
      version: "0.1.5-rc.1",
      entry: "node_modules/@deepseek-ai/dsh/lib/bin.js",
      source: SourceRecord(kind: .registry, spec: "@deepseek-ai/dsh0.1.5-rc.1"),
      integrity: Integrity(digest: "", verified: true, origin: .npmRegistry),
      installedAt: Date()
    )
    try InstallsIndex(active: nil, releases: [stale]).save(to: paths.installsIndex)

    let server = try await spawnServer(entry: entry, port: 6005)
    XCTAssertTrue(server.isRunning, "precondition: a server is running out of the release")

    let installer = HarnessInstaller(
      paths: paths,
      runner: StubProcessRunner { _ in nil },
      baseEnvironment: [:]
    )
    try await installer.remove(id)

    let stopped = await installer.lastRemoval?.stoppedPids
    XCTAssertEqual(stopped, [server.pid], "the stopped server must be reported")
    let result = await server.wait(timeout: 10)
    XCTAssertFalse(server.isRunning, "the server must die with its release (exit \(result.exitCode))")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: release.path),
      "and the directory is only deleted once nothing is executing from it"
    )
  }

  // MARK: - Helpers

  /// A file that looks enough like the harness entry point for `argv` matching, written
  /// into `lib/` under `<root>/harness/releases/<id>/` — the same shape the real release
  /// tree has.
  ///
  /// It is a `sh` script rather than a Node one on purpose: `/bin/sh` is guaranteed to
  /// exist, so the test never depends on a Node install being on PATH, and the entry point
  /// still lands in `argv[1]` — which is the only thing the sweep reads.
  @discardableResult
  private func makeFakeHarnessEntry(named id: String, root: URL? = nil) throws -> URL {
    let base = try root ?? TestSupport.makeRoot(self)
    let lib = base
      .appendingPathComponent("harness/releases/\(id)-registry-npm/node_modules/@deepseek-ai/dsh/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    // Staying alive is the whole job: the sweep has to find a *running* process. The loop
    // matters — a bare `sleep 60` would let `sh` exec into `sleep`, replacing its own
    // argument vector and destroying the very identity being tested.
    return try TestSupport.write(
      "#!/bin/sh\nwhile :; do sleep 1; done\n",
      to: lib.appendingPathComponent("bin.js"),
      executable: true
    )
  }

  /// Spawn the fake entry the way the launcher spawns the real one — through the same
  /// `posix_spawn` path, in its own process group, through the same argument list.
  private func spawnServer(entry: URL, port: Int) async throws -> RunningProcess {
    try await spawnProcess(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: HarnessLauncher.launchArguments(entry: entry, profile: "web", host: "127.0.0.1", port: port)
    )
  }

  private func spawnProcess(executable: URL, arguments: [String]) async throws -> RunningProcess {
    let request = ProcessRequest(
      executable: executable,
      arguments: arguments,
      environment: ProcessInfo.processInfo.environment,
      currentDirectory: nil,
      label: "fake harness server"
    )
    let process = try await runner.spawn(request, onLine: nil)
    // Registered for teardown BEFORE any assertion can run. A test that throws between the
    // spawn and the assertion — which is exactly what a broken sweep causes — would
    // otherwise leave its fake server alive, and the suite would leak one process per
    // failure, observed for real while writing these tests.
    spawned.append(process)
    // Give the kernel a moment to publish the new process before it is inspected.
    var waited = 0
    while !processIsAlive(process.pid), waited < 40 {
      usleep(25_000)
      waited += 1
    }
    return process
  }

  private func processIsAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }
}
