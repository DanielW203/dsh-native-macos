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
    /// How many more boots of a release will fail before it boots. A count rather than a flag
    /// because the repair ladder exists to be *survived*: the same release has to be able to
    /// fail once and then come up, or the test would be asserting a rollback.
    private var remainingFailures: [String: Int] = [:]
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

    func failBoot(of release: String, detail: String, times: Int = .max) {
      lock.lock()
      defer { lock.unlock() }
      failures[release] = detail
      remainingFailures[release] = times
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
      var failure = failures[active]
      if let remaining = remainingFailures[active] {
        if remaining <= 0 {
          failure = nil
        } else {
          remainingFailures[active] = remaining - 1
        }
      }
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
    let strikes: BootStrikeLedger
    /// The pre-upgrade probe, present only when a test wired one. `nil` is the build that has
    /// no plugin repair at all, which is the behaviour every pre-existing test asserts.
    var preflight: StubPreflight?
    /// What a boot's output says, per announced URL. Empty means "this build cannot tell".
    var health: [String: HarnessBootHealth] = [:]
    /// Whether Safe Mode can be arranged, and what it was told.
    var safeModeAvailable = true
    var safeModeRequests: [String] = []

    init(paths: RuntimePaths, installer: HarnessInstaller, runtime: FakeRuntime) {
      self.paths = paths
      self.installer = installer
      self.runtime = runtime
      self.pending = PendingUpgradeStore(paths: paths)
      self.reports = UpgradeReportStore(paths: paths)
      self.strikes = BootStrikeLedger(paths: paths)
    }

    func coordinator(checks: [any HarnessCheck] = []) -> HarnessUpgradeCoordinator {
      let runtime = self.runtime
      let preflight = self.preflight
      let health = self.health
      let available = self.safeModeAvailable
      return HarnessUpgradeCoordinator(
        paths: paths,
        installer: installer,
        pending: pending,
        reports: reports,
        strikes: strikes,
        profile: "web",
        stopRuntime: { await runtime.stop() },
        startRuntime: { try await runtime.start() },
        currentRuntime: { await runtime.current() },
        makeChecks: { _ in checks },
        preflight: preflight,
        bootHealth: health.isEmpty ? nil : { url in health[url] ?? HarnessBootHealth(isRunning: true) },
        escalateToSafeMode: { reason in
          // A closure cannot mutate the bench, so the record of what it was asked lives in the
          // preflight-independent stub the test reads back through `SafeModeRecorder`.
          SafeModeRecorder.shared.record(reason)
          return available
        }
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

  // MARK: - The pre-upgrade plugin probe

  /// The point of the whole feature: a plugin that cannot load under the release being moved
  /// to is taken out of the picture *before* the switch, so the new release boots with it
  /// already gone instead of silently skipping it.
  func testPreflightQuarantinesBeforeAnyActivation() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let preflight = StubPreflight(findings: ["dsh-memoir": "Cannot find package '@deepseek-ai/dsh-llm'"])
    bench.preflight = preflight

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .kept)
    XCTAssertEqual(preflight.calls, [["dsh-memoir"]])
    XCTAssertEqual(report.pluginQuarantined, ["dsh-memoir"])
    XCTAssertEqual(report.pluginPreflight?["dsh-memoir"], "Cannot find package '@deepseek-ai/dsh-llm'")
    XCTAssertTrue(report.summary.contains("已隔离"), report.summary)
    let activeAfter = await bench.activeReleaseID()
    XCTAssertEqual(activeAfter, newID)
  }

  func testPreflightWithNothingToQuarantineTouchesNoProfile() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let preflight = StubPreflight()
    bench.preflight = preflight

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .kept)
    XCTAssertTrue(preflight.calls.isEmpty)
    XCTAssertNil(report.pluginQuarantined)
  }

  /// A plugin found but not actually disabled (it left the manifest, the write failed) must
  /// not be reported as quarantined: the report is what the user re-enables from.
  func testAPluginThatCouldNotBeDisabledIsNotReportedAsQuarantined() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let preflight = StubPreflight(findings: ["dsh-memoir": "boom"])
    preflight.refuses = ["dsh-memoir"]
    bench.preflight = preflight

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertNil(report.pluginQuarantined)
    XCTAssertEqual(report.pluginPreflight?.count, 1)
  }

  // MARK: - The boot-failure ladder

  /// A boot that fails and names a plugin: disable it, boot again, and keep the upgrade. The
  /// user never sees the failure panel.
  func testABootFailureThatNamesAPluginIsRepairedInPlace() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let preflight = StubPreflight()
    bench.preflight = preflight
    let marker = "/profiles/web/node_modules/dsh-pocket/lib/index.js:3"
    bench.runtime.failBoot(of: newID, detail: """
      Error: failed to apply loader entry dsh-pocket (dsh-pocket): boom
          at x (file:///x\(marker))
      """, times: 1)
    try TestSupport.write(
      #"{"name":"dsh-profile-web","private":true,"dependencies":{"dsh-pocket":"1.0.0"}}"#,
      to: bench.paths.profilesDirectory.appendingPathComponent("web/package.json")
    )

    // The quarantine is what makes it boot: the fake fails whatever release it was told to.
    let runtime = bench.runtime
    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .kept, report.summary)
    XCTAssertEqual(preflight.calls, [["dsh-pocket"]])
    XCTAssertEqual(report.pluginQuarantined, ["dsh-pocket"])
    XCTAssertGreaterThanOrEqual(runtime.booted.count, 2, "the repair boots again")
  }

  /// A boot failure that names nobody is not a plugin story. It goes straight to the rollback
  /// the app has always performed, without disabling anything.
  func testABootFailureThatNamesNoPluginSkipsTheRepair() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let preflight = StubPreflight()
    bench.preflight = preflight
    bench.runtime.failBoot(of: newID, detail: "Error: EADDRINUSE")

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .rolledBack)
    XCTAssertTrue(preflight.calls.isEmpty)
    let activeAfter = await bench.activeReleaseID()
    XCTAssertEqual(activeAfter, oldID)
  }

  /// The new shape: the server comes up, and its output says a plugin is missing. Nothing in
  /// the process state says anything is wrong, so the health factory is the only witness.
  func testABootThatComesUpDegradedIsRepairedThenVerified() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let preflight = StubPreflight()
    bench.preflight = preflight
    let degraded = HarnessBootHealth(
      isRunning: true,
      problems: [BootPluginProblem(name: "dsh-memoir", kind: .skippedBundle, isAttributed: true, line: "skipping profile bundle \"dsh-memoir\"")]
    )
    bench.health = [FakeRuntime.url: degraded]

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .kept, report.summary)
    XCTAssertEqual(preflight.calls, [["dsh-memoir"]])
    XCTAssertEqual(report.pluginQuarantined, ["dsh-memoir"])
    XCTAssertTrue(report.notes.contains { $0.contains("启动输出报告插件问题") }, "\(report.notes)")
  }

  /// A degraded boot with no proof-backed name is reported but never repaired: disabling a
  /// guess is how a working plugin disappears.
  func testADegradedBootWithNoAttributableNameIsReportedOnly() async throws {
    let bench = try makeBench(self, active: oldID, materialized: [oldID, newID])
    let preflight = StubPreflight()
    bench.preflight = preflight
    bench.health = [FakeRuntime.url: HarnessBootHealth(
      isRunning: true,
      problems: [BootPluginProblem(name: "who-knows", kind: .importFailed, isAttributed: false, line: "1 entry did not activate")]
    )]

    let report = await bench.coordinator().update(toReleaseID: newID)

    XCTAssertEqual(report.outcome, .kept)
    XCTAssertTrue(preflight.calls.isEmpty)
    XCTAssertNil(report.pluginQuarantined)
    XCTAssertTrue(report.notes.contains { $0.contains("没有可证实的包名") }, "\(report.notes)")
  }

  // MARK: - The launch-time ladder

  /// Second failure: the repair did not stick, so arrange Safe Mode rather than roll back
  /// again into the same loop.
  func testASecondFailureArrangesSafeMode() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .booting)
    bench.runtime.setRunning(false)
    bench.runtime.failBoot(of: newID, detail: "Error: exploded")
    bench.strikes.recordStrike(forReleaseID: newID, stage: "booting")
    SafeModeRecorder.shared.reset()

    let report = await bench.coordinator().resumeIfNeeded()

    XCTAssertEqual(report?.outcome, .aborted)
    XCTAssertTrue(report?.notes.contains { $0.contains("安全模式") } == true, "\(report?.notes ?? [])")
    XCTAssertTrue(SafeModeRecorder.shared.reasons.contains { $0.contains(newID) }, "\(SafeModeRecorder.shared.reasons)")
    XCTAssertNotNil(bench.pending.record, "the marker stays: the next launch finishes the decision")
  }

  /// Third failure: stop acting. An app that keeps escalating hides which release is broken.
  func testAThirdFailureStopsTryingAndSuggestsARollback() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .booting)
    bench.runtime.setRunning(false)
    bench.runtime.failBoot(of: newID, detail: "Error: exploded")
    bench.strikes.recordStrike(forReleaseID: newID, stage: "booting")
    bench.strikes.recordStrike(forReleaseID: newID, stage: "booting")
    SafeModeRecorder.shared.reset()

    let report = await bench.coordinator().resumeIfNeeded()

    XCTAssertEqual(report?.outcome, .aborted)
    XCTAssertTrue(report?.summary.contains("建议回退") == true, report?.summary ?? "")
    XCTAssertTrue(SafeModeRecorder.shared.reasons.isEmpty, "nothing may be arranged a third time")
  }

  /// The first failure still rolls back, exactly as before: a rollback needs no restart, and
  /// taking a user whose plugins merely need disabling on a Safe Mode detour is a regression.
  func testTheFirstFailureStillRollsBack() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .booting)
    bench.runtime.setRunning(false)
    bench.runtime.failBoot(of: newID, detail: "Error: exploded")
    SafeModeRecorder.shared.reset()

    let report = await bench.coordinator().resumeIfNeeded()

    XCTAssertEqual(report?.outcome, .rolledBack)
    let activeAfter = await bench.activeReleaseID()
    XCTAssertEqual(activeAfter, oldID)
    XCTAssertNil(bench.pending.record)
    XCTAssertTrue(SafeModeRecorder.shared.reasons.isEmpty)
  }

  /// A launch that works clears the count, so an unrelated bad launch tomorrow is not treated
  /// as the second strike of this one.
  func testAHealthyLaunchClearsTheStrikes() async throws {
    let bench = try makeBench(self, active: newID, materialized: [oldID, newID])
    try bench.makePending(from: oldID, to: newID, stage: .verifying)
    bench.strikes.recordStrike(forReleaseID: newID, stage: "booting")
    let passing = StubCheck(name: "rpc-endpoints", isBlocking: true, verdict: .pass, detail: "ok")

    let report = await bench.coordinator(checks: [passing]).resumeIfNeeded()

    XCTAssertEqual(report?.outcome, .kept)
    XCTAssertEqual(bench.strikes.count(forReleaseID: newID), 0)
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

/// The one piece of mutable state the safe-mode closure can reach: a class, because the
/// closure the bench hands the coordinator cannot capture a mutating method on the test.
final class SafeModeRecorder: @unchecked Sendable {
  static let shared = SafeModeRecorder()
  private let lock = NSLock()
  private var requests: [String] = []

  func record(_ reason: String) {
    lock.lock()
    requests.append(reason)
    lock.unlock()
  }

  func reset() {
    lock.lock()
    requests.removeAll()
    lock.unlock()
  }

  var reasons: [String] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

/// A preflight that answers from a table and records what it was asked to disable.
final class StubPreflight: PluginPreflighting, @unchecked Sendable {
  private let lock = NSLock()
  private var findings: [String: String] = [:]
  private var quarantineCalls: [[String]] = []
  /// Names the disable will fail for, so a test can exercise "found but could not act".
  var refuses: Set<String> = []

  init(findings: [String: String] = [:]) {
    self.findings = findings
  }

  func setFindings(_ findings: [String: String]) {
    lock.lock()
    self.findings = findings
    lock.unlock()
  }

  func findUnloadable(profile: String, releaseID: String) async -> PluginLoadProbeResult {
    lock.lock()
    defer { lock.unlock() }
    return PluginLoadProbeResult(unloadable: findings)
  }

  func quarantine(_ names: [String], profile: String, releaseID: String) async -> [String] {
    lock.lock()
    quarantineCalls.append(names)
    let refused = refuses
    lock.unlock()
    return names.filter { !refused.contains($0) }
  }

  var calls: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return quarantineCalls
  }
}
