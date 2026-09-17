import XCTest
@testable import HarnessRuntime

/// The upgrade's decisions, exercised without Node, a network, or a real harness.
///
/// Every test here is about *what the app does next* rather than about any single step: the
/// activation is one symlink swap the installer already had, and the value of this feature is
/// entirely in which release the user is left running and what they are told about it.
final class HarnessUpgradeCoordinatorTests: XCTestCase {
  private let oldID = "0.1.5-rc.1-registry-npm"
  private let newID = "0.1.5-rc.2-registry-npm"

  // MARK: - Fixture

  /// A runtime that boots whichever release is active, and fails the ones it was told to.
  ///
  /// Modelling it this way — resolve the active release, then decide — is what makes the
  /// rollback assertions meaningful: the second boot in a rollback is only "the old version"
  /// because the activation moved the pointer first.
  private final class FakeRuntime: @unchecked Sendable {
    static let url = "http://127.0.0.1:55178/?token=secret"

    private let lock = NSLock()
    private let installer: HarnessInstaller
    private var bootedStorage: [String] = []
    private var stopStorage = 0
    private var failures: [String: String] = [:]
    private var up = true

    init(installer: HarnessInstaller) {
      self.installer = installer
    }

    var booted: [String] {
      lock.lock()
      defer { lock.unlock() }
      return bootedStorage
    }

    var stops: Int {
      lock.lock()
      defer { lock.unlock() }
      return stopStorage
    }

    func failBoot(of release: String, detail: String) {
      lock.lock()
      defer { lock.unlock() }
      failures[release] = detail
    }

    func setRunning(_ running: Bool) {
      lock.lock()
      defer { lock.unlock() }
      up = running
    }

    func start() async throws -> HarnessServerState {
      let active = ((try? await installer.index())?.active) ?? "?"
      lock.lock()
      bootedStorage.append(active)
      let failure = failures[active]
      lock.unlock()
      if let failure {
        throw RuntimeError.installFailed(step: "harness boot", detail: failure)
      }
      return HarnessServerState(phase: .running, url: Self.url, detail: nil)
    }

    func stop() async {
      lock.lock()
      stopStorage += 1
      lock.unlock()
    }

    func current() async -> HarnessServerState? {
      lock.lock()
      let running = up
      lock.unlock()
      guard running else { return nil }
      return HarnessServerState(phase: .running, url: Self.url, detail: nil)
    }
  }

  /// A check with a fixed verdict, so a test can choose which failure it wants to exercise.
  private struct StubCheck: HarnessCheck {
    let name: String
    let isBlocking: Bool
    let verdict: HarnessCheckResult.Verdict
    let detail: String

    func run() async -> HarnessCheckResult {
      HarnessCheckResult(name: name, verdict: verdict, detail: detail, isBlocking: isBlocking)
    }
  }

  private final class Bench {
    let paths: RuntimePaths
    let installer: HarnessInstaller
    let runtime: FakeRuntime
    let pending: PendingUpgradeStore
    let reports: UpgradeReportStore

    init(paths: RuntimePaths, installer: HarnessInstaller, runtime: FakeRuntime) {
      self.paths = paths
      self.installer = installer
      self.runtime = runtime
      self.pending = PendingUpgradeStore(paths: paths)
      self.reports = UpgradeReportStore(paths: paths)
    }

    func coordinator(checks: [any HarnessCheck] = []) -> HarnessUpgradeCoordinator {
      let runtime = self.runtime
      return HarnessUpgradeCoordinator(
        paths: paths,
        installer: installer,
        pending: pending,
        reports: reports,
        profile: "web",
        stopRuntime: { await runtime.stop() },
        startRuntime: { try await runtime.start() },
        currentRuntime: { await runtime.current() },
        makeChecks: { _ in checks }
      )
    }

    func activeReleaseID() async -> String? {
      (try? await installer.index())?.active
    }

    func makePending(from: String, to: String, stage: PendingUpgradeRecord.Stage = .activating) throws {
      try pending.save(PendingUpgradeRecord(
        fromReleaseID: from,
        toReleaseID: to,
        profile: "web",
        stage: stage
      ))
    }
  }

  private func makeBench(
    _ testCase: XCTestCase,
    active: String,
    materialized: Set<String>
  ) throws -> Bench {
    let root = try TestSupport.makeRoot(testCase)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()

    func release(id: String, version: String) -> HarnessRelease {
      HarnessRelease(
        id: id,
        version: version,
        entry: ReleaseValidator.prebuiltEntry,
        source: SourceRecord(kind: .registry, spec: "@deepseek-ai/dsh\(version)"),
        integrity: Integrity(digest: "", verified: true, origin: .npmRegistry),
        installedAt: Date(timeIntervalSince1970: 1_780_000_000)
      )
    }

    var index = InstallsIndex()
    index.active = active
    index.releases = [
      release(id: oldID, version: "0.1.5-rc.1"),
      release(id: newID, version: "0.1.5-rc.2"),
    ]
    for id in materialized {
      try TestSupport.write(
        "// stub entry",
        to: paths.releaseDirectory(id).appendingPathComponent(ReleaseValidator.prebuiltEntry)
      )
    }
    try index.save(to: paths.installsIndex)

    let installer = HarnessInstaller(paths: paths, runner: StubProcessRunner { _ in
      ProcessResult(exitCode: 0, stdout: "", stderr: "", duration: 0)
    })
    return Bench(paths: paths, installer: installer, runtime: FakeRuntime(installer: installer))
  }

  // MARK: - Refusals

  /// The precondition the whole feature exists to enforce: no upgrade without a way back.
  func testRefusesWhenTheCurrentReleaseCannotBeFallenBackTo() async throws {
    // Active, but its directory is gone — so there is nothing to return to.
    let bench = try makeBench(self, active: oldID, materialized: [newID])

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .aborted)
    XCTAssertTrue(report.summary.contains("No release to roll back to"), report.summary)
    XCTAssertNil(bench.pending.record, "nothing may be written before the refusal")
    XCTAssertTrue(bench.runtime.booted.isEmpty, "and nothing may be booted")
    let active = await bench.activeReleaseID()
    XCTAssertEqual(active, oldID)
  }

  func testRefusesAnUnmaterializedTarget() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID])

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .aborted)
    XCTAssertNil(bench.pending.record)
    XCTAssertTrue(bench.runtime.booted.isEmpty)
    let active = await bench.activeReleaseID()
    XCTAssertEqual(active, oldID)
  }

  func testRefusesAnUnknownTarget() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])

    let report = await bench.coordinator().update(toReleaseID: "0.9.9-registry-npm")

    XCTAssertEqual(report.outcome, .aborted)
    XCTAssertNil(bench.pending.record)
  }

  // MARK: - The failed boot

  func testFailedBootRollsBackAndKeepsTheHarnessOutput() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    bench.runtime.failBoot(of: newID, detail: "Error: cannot find module '@deepseek-ai/dsh'")

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .rolledBack)
    XCTAssertEqual(report.rolledBackTo, oldID)
    XCTAssertEqual(report.fromReleaseID, oldID)
    XCTAssertEqual(report.toReleaseID, newID)
    XCTAssertTrue(
      report.bootFailure?.contains("cannot find module") == true,
      "the harness's own output is the only thing that explains why: \(report.bootFailure ?? "nil")"
    )
    XCTAssertEqual(report.checks.map(\.name), ["boot"])
    XCTAssertEqual(report.checks.first?.verdict, .fail)

    // The user is left on the release that works, and the marker is gone because the upgrade
    // reached a conclusion.
    let active = await bench.activeReleaseID()
    XCTAssertEqual(active, oldID)
    XCTAssertNil(bench.pending.record)
    XCTAssertEqual(bench.runtime.booted, [newID, oldID])

    // And the report outlives this process, which is the point of writing it down. Compared
    // field by field rather than whole: the file stores ISO-8601, which is whole-second, so
    // the timestamp comes back deliberately less precise than the value in memory.
    let stored = bench.reports.loadLatest()
    XCTAssertEqual(stored?.outcome, report.outcome)
    XCTAssertEqual(stored?.fromReleaseID, report.fromReleaseID)
    XCTAssertEqual(stored?.toReleaseID, report.toReleaseID)
    XCTAssertEqual(stored?.rolledBackTo, report.rolledBackTo)
    XCTAssertEqual(stored?.summary, report.summary)
    XCTAssertEqual(stored?.bootFailure, report.bootFailure)
    XCTAssertEqual(stored?.checks, report.checks)
  }

  /// A rollback that fails is where a naive implementation loops. This one stops and says so.
  func testRollbackFailureKeepsTheMarkerAndNamesBothFailures() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    bench.runtime.failBoot(of: newID, detail: "new is broken")
    bench.runtime.failBoot(of: oldID, detail: "old is broken too")

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .aborted)
    XCTAssertTrue(report.bootFailure?.contains("new is broken") == true)
    XCTAssertTrue(report.notes.contains { $0.contains("回退启动失败") }, "\(report.notes)")
    XCTAssertNotNil(bench.pending.record, "an unresolved upgrade must stay on disk")
    XCTAssertEqual(bench.runtime.booted, [newID, oldID], "exactly one attempt each, no loop")
  }

  // MARK: - The checks

  func testBlockingCheckFailureRollsBack() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let failing = StubCheck(
      name: "rpc-endpoints",
      isBlocking: true,
      verdict: .fail,
      detail: "缺少端点：session/create"
    )

    let report = await bench.coordinator(checks: [failing]).update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .rolledBack)
    XCTAssertEqual(report.checks.map(\.name), ["boot", "rpc-endpoints"])
    XCTAssertEqual(report.blockingFailures.map(\.name), ["rpc-endpoints"])
    XCTAssertNil(bench.pending.record)
    let active = await bench.activeReleaseID()
    XCTAssertEqual(active, oldID)
  }

  /// The asymmetry rule at the coordinator level: a warning is information, not a verdict, so
  /// it must not undo an upgrade the user already has.
  func testWarningOnlyCheckIsKeptAndReported() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let warning = StubCheck(
      name: "session-log",
      isBlocking: false,
      verdict: .warn,
      detail: "按本机路径约定找不到会话日志"
    )

    let report = await bench.coordinator(checks: [warning]).update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .kept)
    XCTAssertEqual(report.concerns.map(\.name), ["session-log"])
    XCTAssertTrue(report.summary.contains("session-log"), report.summary)
    let active = await bench.activeReleaseID()
    XCTAssertEqual(active, newID)
    XCTAssertNil(bench.pending.record)
  }

  // MARK: - Already there

  /// Asking for the version that is already installed verifies it and touches nothing else.
  func testActiveTargetVerifiesInPlaceWithoutRestarting() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    let passing = StubCheck(name: "rpc-endpoints", isBlocking: true, verdict: .pass, detail: "5 个端点都在")

    let report = await bench.coordinator(checks: [passing]).update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .kept)
    XCTAssertTrue(bench.runtime.booted.isEmpty, "in-place verification must not restart the runtime")
    XCTAssertEqual(bench.runtime.stops, 0)
    XCTAssertNil(bench.pending.record)
  }

  /// With nothing running there is no address to check against, and claiming a pass would be
  /// the worst possible answer to "is this release healthy?".
  func testActiveTargetWithNoRunningRuntimeReportsNoChange() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    bench.runtime.setRunning(false)

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .aborted)
    XCTAssertTrue(report.summary.contains("自检"), report.summary)
    XCTAssertNil(bench.pending.record)
  }

  // MARK: - Resuming an interrupted upgrade

  func testResumeDoesNothingWithoutAMarker() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let report = await bench.coordinator().resumeIfNeeded()
    XCTAssertNil(report)
    XCTAssertTrue(bench.runtime.booted.isEmpty)
  }

  func testResumeClearsAMarkerWhoseActivationNeverHappened() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .activating)

    let report = await bench.coordinator().resumeIfNeeded()

    XCTAssertEqual(report?.outcome, .aborted)
    XCTAssertTrue(report?.summary.contains("激活") == true, report?.summary ?? "nil")
    XCTAssertNil(bench.pending.record)
    XCTAssertTrue(bench.runtime.booted.isEmpty, "there was nothing to undo, so nothing to boot")
  }

  func testResumeRollsBackWhenTheNewReleaseIsNotUp() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .booting)
    bench.runtime.setRunning(false)

    let report = await bench.coordinator().resumeIfNeeded()

    XCTAssertEqual(report?.outcome, .rolledBack)
    XCTAssertEqual(report?.rolledBackTo, oldID)
    let active = await bench.activeReleaseID()
    XCTAssertEqual(active, oldID)
    XCTAssertNil(bench.pending.record)
  }

  func testResumeRollsBackWhenABlockingCheckFails() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .verifying)
    let failing = StubCheck(name: "rpc-endpoints", isBlocking: true, verdict: .fail, detail: "gone")

    let report = await bench.coordinator(checks: [failing]).resumeIfNeeded()

    XCTAssertEqual(report?.outcome, .rolledBack)
    let active = await bench.activeReleaseID()
    XCTAssertEqual(active, oldID)
    XCTAssertNil(bench.pending.record)
  }

  func testResumeConfirmsAnUpgradeThatIsActuallyFine() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .verifying)
    let passing = StubCheck(name: "rpc-endpoints", isBlocking: true, verdict: .pass, detail: "ok")

    let report = await bench.coordinator(checks: [passing]).resumeIfNeeded()

    XCTAssertEqual(report?.outcome, .kept)
    XCTAssertNil(bench.pending.record, "a confirmed upgrade stops being pending")
    let active = await bench.activeReleaseID()
    XCTAssertEqual(active, newID)
  }

  func testResumeClearsAndReportsAnUnreadableMarker() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    try Data("{ not a marker".utf8).write(to: bench.pending.url)

    let report = await bench.coordinator().resumeIfNeeded()

    XCTAssertEqual(report?.outcome, .aborted)
    XCTAssertNil(bench.pending.record)
  }

  // MARK: - Protecting the rollback target

  /// The UI disables the button; the installer has to refuse anyway, because the marker and
  /// the removal can be issued from different windows.
  func testRemoveRefusesTheRollbackTargetOfAnInFlightUpgrade() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .booting)

    do {
      try await bench.installer.remove(oldID)
      XCTFail("expected the removal to be refused")
    } catch let error as RuntimeError {
      XCTAssertEqual(error, .releaseIsRollbackTarget(oldID))
    }
  }

  func testRemoveStillWorksOnceTheUpgradeIsResolved() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .booting)
    bench.pending.clear()

    try await bench.installer.remove(oldID)

    let active = await bench.activeReleaseID()
    XCTAssertEqual(active, newID)
    let remaining = try await bench.installer.releases().map(\.id)
    XCTAssertEqual(remaining, [newID])
  }
}
