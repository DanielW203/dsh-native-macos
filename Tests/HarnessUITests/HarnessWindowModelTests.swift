import XCTest
@testable import HarnessUI
@testable import HarnessRuntime

/// A launcher that answers from a script.
private final class StubLauncher: HarnessLaunching, @unchecked Sendable {
  var outcome: Result<HarnessServerState, Error> = .success(
    HarnessServerState(
      phase: .running,
      url: "http://127.0.0.1:1234/?token=SECRETTOKENVALUE",
      port: 1234,
      pid: 42
    )
  )
  /// Emitted as if the harness printed it.
  var banner = "dsh web: http://127.0.0.1:1234/?token=SECRETTOKENVALUE"
  /// Emitted as if the launcher reported a boot step of its own.
  var stages: [String] = []
  /// Shared with the other stubs so a test can assert on ordering.
  var order: OrderLog?
  /// The profiles the launcher was asked to boot, in order.
  private(set) var profiles: [String] = []

  /// When held, a start parks until it is released, so "the window is busy" can be a state a
  /// test sets up rather than a race it hopes for. Polls instead of blocking a thread: the
  /// stub runs on the cooperative pool, and a semaphore there is a deadlock waiting to happen.
  private var holding = false
  private var released = true

  func holdStart() {
    lock.lock(); holding = true; released = false; lock.unlock()
  }

  func releaseStart() {
    lock.lock(); released = true; lock.unlock()
  }

  private var isHeld: Bool {
    lock.lock(); defer { lock.unlock() }
    return holding && !released
  }

  private let lock = NSLock()
  private var startTally = 0
  private var stopTally = 0

  var startCount: Int { lock.lock(); defer { lock.unlock() }; return startTally }
  var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopTally }

  func start(
    profile: String,
    host: String,
    workingDirectory: URL?,
    timeout: TimeInterval,
    onLine: @escaping @Sendable (String) -> Void,
    onStage: @escaping @Sendable (String) -> Void
  ) async throws -> HarnessServerState {
    lock.lock(); startTally += 1; lock.unlock()
    order?.append("start")
    profiles.append(profile)
    stages.forEach(onStage)
    onLine(banner)
    while isHeld {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return try outcome.get()
  }

  func stop(timeout: TimeInterval) async {
    lock.lock(); stopTally += 1; lock.unlock()
  }

  func state() async -> HarnessServerState {
    (try? outcome.get()) ?? .stopped
  }
}

/// A repairer that answers from a script.
///
/// The real one boots the profile several times and needs a profile on disk; what the
/// window's behaviour depends on is only its answer and its progress lines, so this is
/// where the interesting cases — proved a suspect, proved nobody, threw — are chosen.
private final class StubRecoverer: PluginRecovering, @unchecked Sendable {
  var outcome = PluginQuarantineOutcome(disabled: [], rounds: 1, started: true)
  var failure: Error?
  /// Emitted through the progress callback, as the real repairer's round boundaries are.
  var progressLines: [String] = []
  private(set) var quarantineCount = 0
  private(set) var profiles: [String] = []

  func quarantine(
    profile: String,
    maxRounds: Int,
    progress: @escaping @Sendable (PluginImportProgress) -> Void
  ) async throws -> PluginQuarantineOutcome {
    quarantineCount += 1
    profiles.append(profile)
    for line in progressLines { progress(PluginImportProgress(message: line)) }
    if let failure { throw failure }
    return outcome
  }
}

/// A Node provisioner that answers from a script.
///
/// The real one downloads ~50 MB; what the window's behaviour depends on is only whether
/// Node is reported missing, whether the install is offered at the right moment, and
/// whether a successful install hands control back to the harness.
private final class StubNodeProvisioner: NodeProvisioning, @unchecked Sendable {
  var missing = true
  var failure: Error?
  var outcome = NodeInstallOutcome(
    version: "24.10.0",
    binary: URL(fileURLWithPath: "/tmp/node/bin/node"),
    archive: "node-v24.10.0-darwin-arm64.tar.gz",
    bytes: 51_000_000
  )
  /// Emitted through the progress callback, as the real download's stages are.
  var progressLines: [String] = []
  private(set) var installCount = 0
  private(set) var probes = 0

  func isNodeMissing() async -> Bool {
    probes += 1
    return missing
  }

  func installNode(progress: @escaping @Sendable (NodeInstallProgress) -> Void) async throws -> NodeInstallOutcome {
    installCount += 1
    for line in progressLines {
      progress(NodeInstallProgress(phase: .downloading, message: line))
    }
    if let failure { throw failure }
    return outcome
  }
}

/// The order in which the window's collaborators were asked to do something.
///
/// A safe-mode boot is only correct if the profile exists *before* the launcher is asked to
/// boot it — an ordering assertion needs the events in one list rather than two counters.
private final class OrderLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []
  func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
  var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

/// A profile preparer that answers from a script.
private final class StubProfilePreparer: ProfilePreparing, @unchecked Sendable {
  var note: String? = "Created profile rescue from the shipped web template."
  var failure: Error?
  private(set) var requests: [String] = []
  private let order: OrderLog?

  init(order: OrderLog? = nil) { self.order = order }

  func ensureProfile(named name: String, template: String) async throws -> String? {
    requests.append("\(name):\(template)")
    order?.append("prepare")
    if let failure { throw failure }
    return note
  }
}

/// A checkpoint recorder that answers from a script.
private final class StubCheckpoints: HealthyStartRecording, @unchecked Sendable {
  var note: String? = "Saved a healthy-start checkpoint in slot-1 (4 file(s))."
  private(set) var profiles: [String] = []
  private let order: OrderLog?

  init(order: OrderLog? = nil) { self.order = order }

  func recordHealthyStart(profile: String) async -> String? {
    profiles.append(profile)
    order?.append("checkpoint")
    return note
  }
}

@MainActor
final class HarnessWindowModelTests: XCTestCase {
  // MARK: - Token redaction

  func testRedactionTerminatesAndHidesTheToken() {
    // Regression: the first implementation replaced the value in place, leaving the
    // "token=" prefix behind. The loop then found it again and rewrote the same text
    // forever, hanging the main actor. This test fails by timing out rather than by
    // asserting if that returns.
    let banner = "dsh web: http://127.0.0.1:1234/?token=SECRETTOKENVALUE"
    let redacted = HarnessWindowModel.redacting(banner)
    XCTAssertEqual(redacted, "dsh web: http://127.0.0.1:1234/?token=<redacted>")
    XCTAssertFalse(redacted.contains("SECRETTOKENVALUE"))
  }

  func testRedactionLeavesOrdinaryLinesAlone() {
    XCTAssertEqual(HarnessWindowModel.redacting("page loaded: DeepSeek Harness"),
                   "page loaded: DeepSeek Harness")
    XCTAssertEqual(HarnessWindowModel.redacting(""), "")
  }

  func testRedactionStopsAtTheNextQueryParameter() {
    let line = "http://127.0.0.1:1/?token=abc&x=1"
    XCTAssertEqual(HarnessWindowModel.redacting(line), "http://127.0.0.1:1/?token=<redacted>&x=1")
  }

  func testRedactionHandlesAnEmptyValue() {
    // Must still terminate: nothing to hide, but the marker is consumed.
    XCTAssertEqual(HarnessWindowModel.redacting("?token="), "?token=<redacted>")
    XCTAssertEqual(HarnessWindowModel.redacting("?token= next"), "?token=<redacted> next")
  }

  // MARK: - Navigation policy

  func testSameOriginLoadsInApp() throws {
    let base = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/?token=x"))
    XCTAssertTrue(WebNavigationPolicy.shouldLoadInApp(URL(string: "http://127.0.0.1:1234/settings")!, base: base))
  }

  func testOtherHostsAndPortsOpenExternally() throws {
    let base = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/?token=x"))
    // The documentation and the DeepSeek key page are both reached from the UI; neither
    // belongs in a window with no address bar.
    XCTAssertFalse(WebNavigationPolicy.shouldLoadInApp(URL(string: "https://platform.deepseek.com/")!, base: base))
    XCTAssertFalse(WebNavigationPolicy.shouldLoadInApp(URL(string: "http://127.0.0.1:9999/")!, base: base))
    XCTAssertFalse(WebNavigationPolicy.shouldLoadInApp(URL(string: "http://localhost:1234/")!, base: base))
  }

  func testNonHTTPSchemesAreNotLoaded() throws {
    let base = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/?token=x"))
    XCTAssertFalse(WebNavigationPolicy.shouldLoadInApp(URL(string: "file:///etc/passwd")!, base: base))
  }

  // MARK: - State machine

  func testStartReachesRunningAndKeepsTheLogRedacted() async {
    let launcher = StubLauncher()
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws")

    await model.start()

    XCTAssertEqual(model.phase, .running)
    XCTAssertEqual(model.url, "http://127.0.0.1:1234/?token=SECRETTOKENVALUE")
    XCTAssertNotNil(model.webModel)
    // The banner the harness printed is in the log, but without the token.
    XCTAssertTrue(model.log.contains { $0.contains("<redacted>") })
    XCTAssertFalse(model.log.contains { $0.contains("SECRETTOKENVALUE") })
  }

  func testBootStagesReachTheSameLogAsTheHarnessOutput() async {
    // The panel under the spinner shows one list. If only the harness process could write
    // to it, a normal boot would show an empty box: the app spends its first ten seconds
    // resolving Node, and the harness prints nothing until it is ready.
    let launcher = StubLauncher()
    launcher.stages = ["Booting the web profile…", "Resolving the Node toolchain…"]
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws")

    await model.start()

    for stage in launcher.stages {
      XCTAssertTrue(model.log.contains(stage), "the boot log is missing \(stage)")
    }
    XCTAssertTrue(model.log.contains { $0.hasPrefix("dsh web: ") })
  }

  // MARK: - Safe Mode boots

  func testARescueStartCreatesTheProfileBeforeBootingIt() async {
    let order = OrderLog()
    let launcher = StubLauncher()
    launcher.order = order
    let preparer = StubProfilePreparer(order: order)
    let model = HarnessWindowModel(
      launcher: launcher,
      profile: "rescue",
      workspacePath: "/tmp/ws",
      profilePreparing: preparer
    )

    await model.start()

    // The order is the assertion: a launcher asked to boot a profile that does not exist
    // yet reports "the harness did not start", which hides the one thing the user can fix.
    XCTAssertEqual(order.all, ["prepare", "start"])
    XCTAssertEqual(preparer.requests, ["rescue:web"])
    XCTAssertEqual(launcher.profiles, ["rescue"])
    XCTAssertEqual(model.phase, .running)
    XCTAssertTrue(model.log.contains { $0.contains("Created profile rescue") })
  }

  func testAProfileThatCannotBeCreatedStopsBeforeTheLauncher() async {
    let order = OrderLog()
    let launcher = StubLauncher()
    launcher.order = order
    let preparer = StubProfilePreparer(order: order)
    preparer.failure = RuntimeError.unsupported("no space left on device")
    let model = HarnessWindowModel(
      launcher: launcher,
      profile: "rescue",
      workspacePath: "/tmp/ws",
      profilePreparing: preparer
    )

    await model.start()

    XCTAssertEqual(order.all, ["prepare"])
    XCTAssertEqual(launcher.startCount, 0)
    XCTAssertEqual(model.phase, .failed)
    XCTAssertTrue(model.detail?.contains("no space left") ?? false)
  }

  func testANormalStartWithoutAPreparerBootsDirectly() async {
    let launcher = StubLauncher()
    let model = HarnessWindowModel(launcher: launcher, profile: "web", workspacePath: "/tmp/ws")

    await model.start()

    XCTAssertEqual(launcher.profiles, ["web"])
    XCTAssertEqual(model.phase, .running)
  }

  // MARK: - Healthy-start checkpoints

  func testAHealthyStartIsRecordedOnce() async {
    let launcher = StubLauncher()
    let checkpoints = StubCheckpoints()
    let model = HarnessWindowModel(
      launcher: launcher,
      profile: "web",
      workspacePath: "/tmp/ws",
      checkpoints: checkpoints
    )

    await model.start()

    XCTAssertEqual(checkpoints.profiles, ["web"])
    XCTAssertTrue(model.log.contains { $0.contains("Saved a healthy-start checkpoint") })
  }

  /// A checkpoint of a boot that failed would be a rollback point to a broken
  /// configuration, which is worse than having none.
  func testAFailedStartIsNotRecorded() async {
    let launcher = StubLauncher()
    launcher.outcome = .failure(RuntimeError.installFailed(step: "harness web", detail: "boom"))
    let checkpoints = StubCheckpoints()
    let model = HarnessWindowModel(
      launcher: launcher,
      profile: "web",
      workspacePath: "/tmp/ws",
      checkpoints: checkpoints
    )

    await model.start()

    XCTAssertEqual(model.phase, .failed)
    XCTAssertTrue(checkpoints.profiles.isEmpty)
  }

  /// The repair's own start is a real boot: it is the one that proved the profile works,
  /// so it is exactly the configuration worth being able to return to.
  func testTheStartAfterARepairIsRecorded() async {
    let launcher = StubLauncher()
    let checkpoints = StubCheckpoints()
    let recoverer = StubRecoverer()
    recoverer.outcome = PluginQuarantineOutcome(disabled: ["broken"], rounds: 2, started: true)
    let model = HarnessWindowModel(
      launcher: launcher,
      profile: "web",
      workspacePath: "/tmp/ws",
      recoverer: recoverer,
      checkpoints: checkpoints
    )

    await model.quarantineAndRestart()

    XCTAssertEqual(model.phase, .running)
    XCTAssertEqual(checkpoints.profiles, ["web"])
  }

  // MARK: - The address shown in the toolbar

  func testDisplayURLHidesTheAccessToken() async {
    let model = HarnessWindowModel(launcher: StubLauncher(), workspacePath: "/tmp/ws")

    await model.start()

    // The window says where the harness is listening; the token stays in the loaded URL.
    XCTAssertEqual(model.displayURL, "http://127.0.0.1:1234")
    XCTAssertFalse(model.displayURL?.contains("SECRETTOKENVALUE") ?? false)
  }

  func testDisplayURLIsNilUntilTheHarnessRuns() {
    let model = HarnessWindowModel(launcher: StubLauncher(), workspacePath: "/tmp/ws")
    XCTAssertNil(model.displayURL)
  }

  // MARK: - Restarting the app

  func testRelaunchWaitsForThisProcessAndQuotesTheBundle() {
    // Waiting on the pid is the whole point: the harness runs in its own process group, so
    // a relaunch that fires while this process is still alive races it for the port. The
    // wait is bounded, because the user must never have to force quit to get the window back.
    let script = HarnessWindowModel.relaunchScript(
      waitingFor: 4242,
      bundle: "/Applications/DSH Native.app"
    )
    XCTAssertEqual(
      script,
      "i=0; while kill -0 4242 2>/dev/null && [ \"$i\" -lt 50 ]; do i=$((i + 1)); sleep 0.2; done"
        + "; if kill -0 4242 2>/dev/null; then kill -9 4242 2>/dev/null; j=0; while kill -0 4242 2>/dev/null && [ \"$j\" -lt 10 ]; do j=$((j + 1)); sleep 0.2; done; fi"
        + "; /usr/bin/open -n '/Applications/DSH Native.app'"
    )
  }

  func testRelaunchScriptEscapesQuotesInTheBundlePath() {
    let script = HarnessWindowModel.relaunchScript(waitingFor: 1, bundle: "/tmp/it's here.app")
    XCTAssertTrue(script.hasSuffix("/usr/bin/open -n '/tmp/it'\\''s here.app'"), script)
  }

  /// The relaunch is the only thing that can bring the window back, so it may not depend on
  /// this process quitting on its own: past the deadline the app is killed and the bundle is
  /// opened anyway. This runs the real script against a stand-in for a wedged app.
  func testRelaunchKillsAnAppThatOutstaysTheDeadlineAndStillReopens() throws {
    let sandbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("relaunch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let log = sandbox.appendingPathComponent("logs/window.log")

    let stubborn = Process()
    stubborn.executableURL = URL(fileURLWithPath: "/bin/sleep")
    stubborn.arguments = ["30"]
    try stubborn.run()
    defer { if stubborn.isRunning { stubborn.terminate() } }
    XCTAssertTrue(stubborn.isRunning)

    // A bundle path that does not exist: `open` fails, which is what keeps this test from
    // launching a second copy of the app under test.
    let bundle = sandbox.appendingPathComponent("NoSuchApp.app").path
    let script = HarnessWindowModel.relaunchScript(
      waitingFor: stubborn.processIdentifier,
      bundle: bundle,
      logPath: log.path,
      patience: 1
    )
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", script]
    shell.standardOutput = Pipe()
    shell.standardError = Pipe()
    try shell.run()
    shell.waitUntilExit()

    XCTAssertFalse(stubborn.isRunning, "the relaunch script must kill an app that outstays its deadline")
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    XCTAssertTrue(text.contains("killing it"), text)
    XCTAssertTrue(text.contains("relaunch: opening \(bundle)"), text)
    // The last step is the reopen, and it runs whatever happened before it.
    XCTAssertTrue(script.hasSuffix("/usr/bin/open -n '\(bundle)'"), script)
  }

  func testStartFailureKeepsTheReason() async {
    let launcher = StubLauncher()
    launcher.outcome = .failure(RuntimeError.installFailed(step: "harness web", detail: "port already in use"))
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws")

    await model.start()

    XCTAssertEqual(model.phase, .failed)
    XCTAssertNotNil(model.detail)
    XCTAssertTrue(model.detail?.contains("port already in use") == true)
    XCTAssertNil(model.webModel)
  }

  func testStopReturnsToStopped() async {
    let launcher = StubLauncher()
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws")
    await model.start()
    await model.stop()

    XCTAssertEqual(model.phase, .stopped)
    XCTAssertNil(model.url)
    XCTAssertNil(model.webModel)
    XCTAssertEqual(launcher.stopCount, 1)
  }

  /// The quit path must not take the busy guard's word for it.
  ///
  /// "Restarting the app…" nine seconds into a boot is in the shipped log: the user restarts
  /// while the window is busy. `stop()` returns early there — deliberately, it is a button —
  /// and the old delegate called exactly that, so the server it had just spawned was left
  /// running for the next launch to find and kill.
  func testStopForTerminationStopsWhileABootIsStillInFlight() async {
    let launcher = StubLauncher()
    launcher.holdStart()
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws")

    let booting = Task { await model.start() }
    while !model.isBusy { await Task.yield() }

    await model.stopForTermination()
    XCTAssertEqual(launcher.stopCount, 1, "a quit must stop the server even mid-boot")
    XCTAssertEqual(model.phase, .stopped)

    // Let the in-flight boot finish so the test does not leave a task running behind it.
    launcher.releaseStart()
    await booting.value
  }

  /// A boot that lands *after* the quit belongs to nobody: it has to stop what it started,
  /// or the next launch finds a server it never booted. That is the "Stopped a harness left
  /// running by an earlier session" line in the shipped log, on every restart.
  func testABootThatFinishesAfterTheQuitStopsTheServerItStarted() async {
    let launcher = StubLauncher()
    launcher.holdStart()
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws")

    let booting = Task { await model.start() }
    while !model.isBusy { await Task.yield() }

    await model.stopForTermination()
    XCTAssertEqual(launcher.stopCount, 1)

    launcher.releaseStart()
    await booting.value

    XCTAssertEqual(launcher.stopCount, 2, "the late boot's server must be stopped too")
    XCTAssertEqual(model.phase, .stopped)
    XCTAssertNil(model.url)
  }

  func testAutoStartOnlyRunsOnce() async {
    let launcher = StubLauncher()
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws")
    await model.startIfNeeded()
    await model.startIfNeeded()
    XCTAssertEqual(launcher.startCount, 1)
  }

  func testWorkspaceFallsBackToDocumentsRatherThanHome() {
    let defaults = UserDefaults(suiteName: "HarnessWindowModelTests.\(UUID().uuidString)")!
    let model = HarnessWindowModel(launcher: StubLauncher(), defaults: defaults)
    // A harness pointed at the home directory offers the whole home as a workspace.
    XCTAssertEqual(model.workspacePath, HarnessWindowModel.defaultWorkspace)
    XCTAssertNotEqual(model.workspacePath, NSHomeDirectory())
  }

  // MARK: - Repair after a boot a plugin broke

  func testRepairStopsTheHarnessQuarantinesThenStartsItAgain() async {
    let launcher = StubLauncher()
    let recoverer = StubRecoverer()
    recoverer.progressLines = ["Round 1: checking web"]
    recoverer.outcome = PluginQuarantineOutcome(disabled: ["dsh-pocket"], rounds: 2, started: true)
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws", recoverer: recoverer)

    await model.start()
    XCTAssertEqual(model.phase, .running)

    await model.quarantineAndRestart()

    // The running harness gives up its port before the repair boots the profile itself.
    XCTAssertEqual(launcher.stopCount, 1)
    XCTAssertEqual(recoverer.quarantineCount, 1)
    XCTAssertEqual(recoverer.profiles, ["web"])
    XCTAssertEqual(launcher.startCount, 2, "a completed repair starts the harness again")
    XCTAssertEqual(model.phase, .running)

    // The repair's own lines survive the start it causes: knowing which plugins were turned
    // off is the outcome, and a log cleared by the next boot would hide it.
    XCTAssertTrue(model.log.contains("Round 1: checking web"))
    XCTAssertTrue(model.log.contains { $0.contains("Turned off dsh-pocket") })
  }

  func testRepairLeavesTheWindowFailedWhenItCanProveNothing() async {
    let launcher = StubLauncher()
    let recoverer = StubRecoverer()
    recoverer.outcome = PluginQuarantineOutcome(
      disabled: [],
      rounds: 3,
      started: false,
      diagnostic: "dsh: plugin tree failed to load: Error: unknown failure"
    )
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws", recoverer: recoverer)

    await model.quarantineAndRestart()

    XCTAssertEqual(model.phase, .failed)
    XCTAssertEqual(model.detail, "dsh: plugin tree failed to load: Error: unknown failure")
    XCTAssertEqual(launcher.startCount, 0, "nothing is started while the profile still will not boot")
  }

  func testRepairReportsAFailureToRepairAtAll() async {
    let launcher = StubLauncher()
    let recoverer = StubRecoverer()
    recoverer.failure = RuntimeError.installFailed(step: "quarantine web", detail: "no runtime")
    let model = HarnessWindowModel(launcher: launcher, workspacePath: "/tmp/ws", recoverer: recoverer)

    await model.quarantineAndRestart()

    XCTAssertEqual(model.phase, .failed)
    XCTAssertEqual(model.detail, RuntimeError.installFailed(step: "quarantine web", detail: "no runtime").errorDescription)
    XCTAssertEqual(launcher.startCount, 0)
  }

  func testRepairWithoutARepairerSaysSoRatherThanHanging() async {
    let model = HarnessWindowModel(launcher: StubLauncher(), workspacePath: "/tmp/ws")

    await model.quarantineAndRestart()

    XCTAssertTrue(model.log.contains { $0.contains("not available") })
  }

  // MARK: - Node

  func testAFailedStartOnAMachineWithNoNodeOffersToInstallOne() async {
    let launcher = StubLauncher()
    launcher.outcome = .failure(RuntimeError.missingToolchain("Node ^22.19.0 || >=24.0.0"))
    let provisioner = StubNodeProvisioner()
    let model = HarnessWindowModel(
      launcher: launcher,
      workspacePath: "/tmp/ws",
      nodeProvisioner: provisioner
    )

    await model.start()

    XCTAssertEqual(model.phase, .failed)
    XCTAssertTrue(model.needsNode)
    XCTAssertEqual(provisioner.probes, 1)
    XCTAssertTrue(model.log.contains { $0.contains("No usable Node") })
  }

  func testAFailedStartForAnotherReasonDoesNotOfferNode() async {
    let launcher = StubLauncher()
    // Node resolved fine; the release is what is missing. Installing a Node here would be
    // an answer to a question nobody asked.
    launcher.outcome = .failure(RuntimeError.noActiveRelease)
    let provisioner = StubNodeProvisioner()
    provisioner.missing = false
    let model = HarnessWindowModel(
      launcher: launcher,
      workspacePath: "/tmp/ws",
      nodeProvisioner: provisioner
    )

    await model.start()

    XCTAssertEqual(model.phase, .failed)
    XCTAssertFalse(model.needsNode)
  }

  func testStartingAgainReAsksWhetherNodeIsStillMissing() async {
    let launcher = StubLauncher()
    launcher.outcome = .failure(RuntimeError.missingToolchain("Node ^22.19.0 || >=24.0.0"))
    let provisioner = StubNodeProvisioner()
    let model = HarnessWindowModel(
      launcher: launcher,
      workspacePath: "/tmp/ws",
      nodeProvisioner: provisioner
    )

    await model.start()
    XCTAssertTrue(model.needsNode)
    // The user installed Node from somewhere else and pressed Start again: the stale offer
    // must not survive the retry.
    provisioner.missing = false
    await model.start()

    XCTAssertFalse(model.needsNode)
    XCTAssertEqual(provisioner.probes, 2)
  }

  func testInstallingNodeStartsTheHarnessWithoutASecondClick() async {
    let launcher = StubLauncher()
    let provisioner = StubNodeProvisioner()
    let model = HarnessWindowModel(
      launcher: launcher,
      workspacePath: "/tmp/ws",
      nodeProvisioner: provisioner
    )

    await model.installNode()

    XCTAssertEqual(provisioner.installCount, 1)
    XCTAssertEqual(launcher.startCount, 1, "the whole point is that the user does not press Start too")
    XCTAssertEqual(model.phase, .running)
    XCTAssertFalse(model.needsNode)
    XCTAssertNil(model.nodeStage)
    XCTAssertTrue(model.log.contains { $0.contains("Installed Node 24.10.0") })
  }

  func testAFailedNodeInstallKeepsTheOfferUp() async {
    let launcher = StubLauncher()
    let provisioner = StubNodeProvisioner()
    provisioner.failure = RuntimeError.installFailed(step: "download", detail: "offline")
    let model = HarnessWindowModel(
      launcher: launcher,
      workspacePath: "/tmp/ws",
      nodeProvisioner: provisioner
    )

    await model.installNode()

    XCTAssertEqual(model.phase, .failed)
    // The usual cause is a network that will work in a minute, so the button has to stay.
    XCTAssertTrue(model.needsNode)
    XCTAssertEqual(launcher.startCount, 0)
    XCTAssertNil(model.nodeStage)
    XCTAssertTrue(model.log.contains { $0.contains("Installing Node failed") })
  }

  func testNodeProgressReachesTheLogAndTheStageLine() async {
    let launcher = StubLauncher()
    let provisioner = StubNodeProvisioner()
    provisioner.progressLines = ["Downloading node-v24.10.0-darwin-arm64.tar.gz — 10.0 of 50.0 MB"]
    let model = HarnessWindowModel(
      launcher: launcher,
      workspacePath: "/tmp/ws",
      nodeProvisioner: provisioner
    )

    await model.installNode()

    XCTAssertTrue(model.log.contains { $0.contains("Downloading node-v24.10.0-darwin-arm64.tar.gz") })
  }

  func testInstallingNodeWithoutAProvisionerSaysSoRatherThanHanging() async {
    let model = HarnessWindowModel(launcher: StubLauncher(), workspacePath: "/tmp/ws")

    await model.installNode()

    XCTAssertTrue(model.log.contains { $0.contains("not available") })
  }
}
