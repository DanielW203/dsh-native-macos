import AppKit
import Foundation
import HarnessRuntime
import SwiftUI

/// The window's state: whether the harness is up, where it is, and what the user is
/// pointing it at.
///
/// The launcher is injected as a protocol so this can be exercised without Node: the
/// behaviour worth testing is what the window shows when a start succeeds, fails, or runs
/// long, and none of those need a real server.
@MainActor
public final class HarnessWindowModel: ObservableObject {
  public enum Phase: String, Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed
  }

  @Published public private(set) var phase: Phase = .stopped
  @Published public private(set) var url: String?
  @Published public private(set) var detail: String?
  @Published public private(set) var isBusy = false
  @Published public private(set) var log: [String] = []
  /// The workspace handed to the harness. It uses its invoking directory as the default
  /// filesystem location, so this is what the Web UI offers first.
  @Published public private(set) var workspacePath: String
  /// Whether the harness could not start because this machine has no usable Node.
  ///
  /// Only ever true after a start has actually failed and the toolchain resolver has been
  /// asked: the offer to install Node must not appear for a failure that is something else.
  @Published public private(set) var needsNode = false
  /// What a Node install is doing right now, for the panel under the button.
  @Published public private(set) var nodeStage: String?
  @Published public private(set) var webModel: HarnessWebModel?
  /// The last runtime-version change this window performed, kept so the console can show it
  /// and so a failure survives the panel being closed.
  ///
  /// Published on the window rather than held by the console because the window is the
  /// server's owner: the upgrade moves the server, and a report of what happened to it
  /// belongs beside the thing it happened to.
  @Published public private(set) var upgradeReport: UpgradeReport?

  /// The profile this window boots.
  ///
  /// Normally the shipped `web` profile, which the harness creates on demand. A Safe Mode
  /// launch boots a plugin-free profile instead, and that profile may have to be created
  /// first — which is what `profilePreparing` is for.
  public let profile: String

  /// Where the last chosen workspace is remembered between launches.
  public static let workspaceDefaultsKey = "NativeHarness.workspace"

  private let launcher: any HarnessLaunching
  /// What this window can do about a profile the harness will not boot.
  ///
  /// Optional because the repair is a harness-side capability (`dsh plugin` plus the
  /// profile's own files) that a test or a stripped build may not have; `nil` turns the
  /// recovery entry point into a line in the log rather than a dead button.
  private let recoverer: (any PluginRecovering)?
  /// What this window can do about a machine with no Node.
  ///
  /// Optional for the same reason `recoverer` is: a test or a stripped build has no
  /// network, and `nil` turns the offer into an absent button rather than a dead one.
  private let nodeProvisioner: (any NodeProvisioning)?
  /// What this window can do about a profile that does not exist yet.
  ///
  /// Optional for the same reason `recoverer` is: the shipped `web` profile is created by
  /// the harness itself, so only a Safe Mode start needs this at all, and `nil` turns it
  /// into a no-op.
  private let profilePreparing: (any ProfilePreparing)?
  /// Where a boot that worked is recorded, so the recovery window has something to roll
  /// back to.
  ///
  /// `nil` in a disposable home, and `nil` in tests that do not care: a checkpoint of a
  /// throwaway profile is not worth keeping, and a checkpoint that cannot be written must
  /// never be the reason a start fails.
  private let checkpoints: (any HealthyStartRecording)?
  /// Whether this window has already asked the resolver whether Node is the problem, so a
  /// failure panel does not re-run `node --version` on every redraw.
  private var didProbeNode = false
  private let defaults: UserDefaults
  private var didAutoStart = false
  /// Where the window's log is mirrored. The console writes one for the same reason: a
  /// window has nowhere to print, and "the harness did not start" is not a diagnosis.
  private let logFileURL: URL?
  private var logHandle: FileHandle?
  /// Set when the app is on its way out. Nothing new starts after that, and a boot that was
  /// already in flight stops the server it produced instead of handing it to a window that
  /// is about to disappear — see `startUnchecked(clearingLog:)`.
  private var isQuitting = false
  /// Moves the runtime between installed releases. `nil` in a build with no paths wired for
  /// it, which turns the console's update button into an absent one rather than a dead one.
  private var upgrader: HarnessUpgradeCoordinator?
  /// The launch-time resume runs once per launch. Without this, a boot that fails and is
  /// retried by the user would re-run the resume against a marker the upgrade already
  /// resolved.
  private var didResumeUpgrade = false

  public init(
    launcher: any HarnessLaunching,
    profile: String = SafeBootResolution.normalProfile,
    defaults: UserDefaults = .standard,
    workspacePath: String? = nil,
    logFileURL: URL? = nil,
    recoverer: (any PluginRecovering)? = nil,
    nodeProvisioner: (any NodeProvisioning)? = nil,
    profilePreparing: (any ProfilePreparing)? = nil,
    checkpoints: (any HealthyStartRecording)? = nil
  ) {
    self.launcher = launcher
    self.profile = profile
    self.defaults = defaults
    self.logFileURL = logFileURL
    self.recoverer = recoverer
    self.nodeProvisioner = nodeProvisioner
    self.profilePreparing = profilePreparing
    self.checkpoints = checkpoints
    self.workspacePath = workspacePath
      ?? defaults.string(forKey: Self.workspaceDefaultsKey)
      ?? Self.defaultWorkspace
    openLogFile()
  }

  /// The production model: every repair path this app has, built from the same `paths` and
  /// the same release the launcher resolves.
  ///
  /// A factory rather than more default arguments, because the provisioner is an actor
  /// that has to be constructed from `RuntimePaths` — threading that through every call
  /// site would make "which home is this window talking to" a question each of them could
  /// get wrong.
  /// - Parameters:
  ///   - paths: the tree this window runs against. In Safe Mode that is the same root with
  ///     a disposable `DSH_HOME`, so the repairs below still act on the real profile files.
  ///   - profile: the profile to boot. Anything other than `web` is a Safe Mode start and
  ///     may have to be created first.
  ///   - logFileURL: where the window mirrors its log.
  public static func standard(
    paths: RuntimePaths,
    profile: String = SafeBootResolution.normalProfile,
    logFileURL: URL? = nil
  ) -> HarnessWindowModel {
    let installer = HarnessInstaller(paths: paths)
    let entry: @Sendable () async throws -> URL = { try await installer.activeEntryURL() }
    let model = HarnessWindowModel(
      launcher: HarnessLauncher(paths: paths, entryProvider: entry),
      profile: profile,
      logFileURL: logFileURL,
      recoverer: ProfileImporter(paths: paths, entryProvider: entry),
      nodeProvisioner: NodeProvisioner(paths: paths),
      // The shipped `web` profile is created by the harness on demand; only a rescue start
      // needs a profile built from a template before the first boot can succeed.
      profilePreparing: profile == SafeBootResolution.normalProfile
        ? nil
        : RescueProfileInstaller(paths: paths, entryProvider: entry),
      // A disposable home is deleted on the next normal launch, so a checkpoint of it would
      // be written, reported, and then thrown away unread.
      checkpoints: paths.isSafeMode ? nil : ProfileCheckpointStore(paths: paths)
    )
    // Attached after the fact because the coordinator drives this window's own start and stop,
    // and the window does not exist until the call above returns. Skipped in Safe Mode: a
    // disposable home is the wrong place to leave a marker about the user's real runtime.
    if !paths.isSafeMode {
      model.attachUpgrader(paths: paths, installer: installer)
    }
    return model
  }

  /// `~/Documents` rather than the home directory: a harness pointed at `~` offers the
  /// user's entire home as a workspace, which is a bad default to accept by reflex.
  public static var defaultWorkspace: String {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
      ?? NSHomeDirectory()
  }

  public var isRunning: Bool { phase == .running }

  /// Whether quitting has a server to stop.
  ///
  /// Deliberately wider than `isRunning`. A boot that has not finished (`.starting`) has
  /// already spawned a server, and one that just failed (`.failed`) may still have a live
  /// one — the launcher drops its handle on the way out of a failure. Quitting without
  /// stopping either is what leaves the next launch to clean up. When there is genuinely
  /// nothing to stop, the stop is a no-op.
  public var mayHoldAServer: Bool { phase != .stopped }
  public var workspaceURL: URL { URL(fileURLWithPath: workspacePath, isDirectory: true) }

  // MARK: - Lifecycle

  /// Start once, automatically, the first time the window appears.
  public func startIfNeeded() async {
    guard !didAutoStart else { return }
    didAutoStart = true
    await start()
    // After the boot, never before: an interrupted upgrade is decided by whether the release
    // it moved to actually came up, and that answer only exists once this attempt finished.
    await resumeUpgradeIfNeeded()
  }

  public func start() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    await startUnchecked()
  }

  /// The start itself, without the busy guard.
  ///
  /// Split out so a repair can run its own start inside the single busy period it already
  /// holds: `isBusy` is this window's "one long operation at a time" rule, and a repair that
  /// released it halfway would let a second Start race the harness it is about to boot.
  ///
  /// - Parameter clearingLog: whether this start owns a fresh log. A plain Start does,
  ///   because the panel belongs to this attempt; a repair does not, because the lines
  ///   naming the plugins it turned off are the outcome the user has to be able to read.
  private func startUnchecked(clearingLog: Bool = true) async {
    // On the way out nothing new is started: a boot begun after the quit would produce a
    // server with no app left to own it.
    guard !isQuitting else { return }
    phase = .starting
    detail = nil
    // A new attempt re-asks the question: the previous one may have ended with the user
    // installing Node from another window, and a stale "needs Node" would hide the real
    // failure behind an offer that can no longer help.
    needsNode = false
    nodeStage = nil
    didProbeNode = false
    if clearingLog { log.removeAll() }

    // The panel under the spinner shows what the harness prints, and a start prints
    // nothing until it is ready: the first ten seconds are this app resolving Node and
    // locating the runtime. The launcher narrates those steps through `onStage`, and this
    // ticker keeps the panel alive through the slow call in the middle; without the two of
    // them a perfectly normal boot shows an empty box.
    let ticker = Task { @MainActor in
      var seconds = 0
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if Task.isCancelled { return }
        seconds += 3
        self.record("Still starting the harness… (\(seconds)s)")
      }
    }
    defer { ticker.cancel() }

    // Both callbacks land in the same panel: stage lines come from this app, the rest from
    // the harness process, and a boot that shows one without the other is unreadable.
    let emit: @Sendable (String) -> Void = { line in
      Task { @MainActor in self.record(line) }
    }

    do {
      // Before the launcher, because a profile that does not exist cannot boot and the
      // harness only creates its own shipped ones. A failure here is a real failure: the
      // rescue profile is the entire point of the mode it was asked for, and reporting
      // "the harness did not start" instead would hide the one thing the user can fix.
      if let profilePreparing {
        record("Checking profile \(profile)…")
        if let note = try await profilePreparing.ensureProfile(
          named: profile,
          template: SafeBootResolution.normalProfile
        ) {
          record(note)
        }
      }

      let state = try await launcher.start(
        profile: profile,
        host: "127.0.0.1",
        workingDirectory: workspaceURL,
        timeout: 120,
        onLine: emit,
        onStage: emit
      )
      // The app may have been asked to quit while this boot was in flight. The stop that ran
      // then had nothing to stop yet, so the server this call just produced is precisely the
      // one that would be left behind — the "Stopped a harness left running by an earlier
      // session" line in the next launch's log. Stop it here rather than attach a window to a
      // process nobody is going to outlive.
      if isQuitting {
        await stopUnchecked(timeout: Self.quitStopTimeout)
        return
      }
      url = state.url
      phase = state.phase == .running ? .running : .failed
      detail = state.detail
      if state.phase == .running {
        record("harness is listening on port \(state.port.map(String.init) ?? "?")")
        // A boot that reached "listening" is the only proof a configuration works, so this
        // is where the rollback point is taken. Recorded after the fact and reported, never
        // thrown: the harness is already up, and failing the start now would take a working
        // runtime away from the user over a backup they did not ask for.
        if let note = await checkpoints?.recordHealthyStart(profile: profile) {
          record(note)
        }
      }
      if let address = state.url, let parsed = URL(string: address) {
        attachWebModel(to: parsed)
      }
    } catch {
      phase = .failed
      // The launcher puts the useful part — the failing process's own output — in the
      // error's description; dropping it would leave the user with only "failed".
      detail = (error as? RuntimeError)?.errorDescription ?? String(describing: error)
      // And it goes in the log too: a window with a failure panel that leaves no record
      // anywhere is undiagnosable once the window is closed.
      record("start failed: \(detail ?? "unknown")")
      await probeForMissingNode()
    }
  }

  /// Ask the toolchain resolver whether the failure just seen is a missing Node.
  ///
  /// The window deliberately does not match on the error's text: "no Node" is a fact the
  /// resolver owns, and the only way to know the offer is useful — rather than a button
  /// that installs a second Node next to a perfectly good one — is to ask it.
  private func probeForMissingNode() async {
    guard !didProbeNode, let nodeProvisioner else { return }
    didProbeNode = true
    needsNode = await nodeProvisioner.isNodeMissing()
    if needsNode {
      record("No usable Node found. The harness needs Node \(NodeRequirement.display).")
    }
  }

  /// Where the install is going, for the log line that precedes it.
  ///
  /// Derived from the window's own log path rather than from a second copy of
  /// `RuntimePaths`: this way the line can only ever name the home the launcher is
  /// actually using.
  private func describeInstallRoot() -> String {
    guard let logs = logFileURL?.deletingLastPathComponent() else { return "the app's own runtime directory" }
    return logs.deletingLastPathComponent().appendingPathComponent("runtime/node", isDirectory: true).path
  }

  /// Download and install Node, then try the start again.
  ///
  /// The install lands in this app's own `runtime/node` and nothing else on the machine is
  /// touched. It does not stop at "Node is installed": the next thing the user would do is
  /// press Start anyway, so this does it for them and reports whatever the harness says
  /// next — which, on a machine that also has no harness release, is that message instead
  /// of a success that still does not boot.
  public func installNode() async {
    guard !isBusy else { return }
    guard let nodeProvisioner else {
      record("Installing Node is not available in this build.")
      return
    }
    isBusy = true
    defer { isBusy = false }

    phase = .starting
    detail = nil
    needsNode = false
    let ticker = Task { @MainActor in
      var seconds = 0
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if Task.isCancelled { return }
        seconds += 3
        self.record("Still installing Node… (\(seconds)s)")
      }
    }
    defer { ticker.cancel() }

    record("Installing Node \(NodeRequirement.display) into \(describeInstallRoot())…")
    do {
      let outcome = try await nodeProvisioner.installNode { progress in
        Task { @MainActor in
          self.nodeStage = progress.message
          self.record(progress.message)
        }
      }
      record("Installed Node \(outcome.version) at \(outcome.binary.path) from \(outcome.archive).")
      for note in outcome.notes { record(note) }
      nodeStage = nil
    } catch {
      phase = .failed
      detail = (error as? RuntimeError)?.errorDescription ?? String(describing: error)
      record("Installing Node failed: \(detail ?? "unknown")")
      // A failed download is still a machine with no Node, so the offer stays up: the
      // usual cause is a network that will work in a minute.
      needsNode = true
      nodeStage = nil
      return
    }

    // The install proved the binary works, so this start re-resolves a toolchain that now
    // includes it. Its log is kept: the download's lines are why it is about to work.
    await startUnchecked(clearingLog: false)
  }

  public func stop() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    await stopUnchecked()
  }

  /// How long a quit waits for the harness.
  ///
  /// Long enough for a server that shuts down when asked — it gets a `SIGTERM` and then the
  /// group signal escalates — and short enough that this app is gone before the shell
  /// script waiting to reopen it gives up. A harness that outlives this window is taken
  /// over by the next launch (`HarnessServerRecord.reapOrphans`).
  public static let quitStopTimeout: TimeInterval = 3

  /// The stop a quit runs.
  ///
  /// Deliberately not `stop()`: the busy guard there is right for a button — one long
  /// operation at a time — and wrong on the way out. A boot that is still in flight is
  /// exactly the state a user restarts out of (the log has "Restarting the app…" nine
  /// seconds into one), and returning early then leaves a live server behind for the next
  /// launch to find and kill. That is the "Stopped a harness left running by an earlier
  /// session" line, and one of the ways a brand-new harness ends up dying with `-9`.
  public func stopForTermination() async {
    isQuitting = true
    await stopUnchecked(timeout: Self.quitStopTimeout)
  }

  /// The stop itself, without the busy guard — see `startUnchecked(clearingLog:)`.
  ///
  /// - Parameter timeout: how long to wait for the server to actually go away. The quit
  ///   path uses a much shorter one than a user-initiated Stop, because a quit is on a
  ///   clock: a shell script is waiting for this process to exit.
  private func stopUnchecked(timeout: TimeInterval = 15) async {
    await launcher.stop(timeout: timeout)
    webModel?.clear()
    webModel = nil
    url = nil
    detail = nil
    phase = .stopped
  }

  /// Repair a profile the harness will not boot, then start it.
  ///
  /// The failure this exists for is a plugin the loader cannot apply. The loader has no
  /// per-plugin isolation, so one bad package takes the whole boot down — and the Web UI,
  /// the only place that plugin could have been turned off, is exactly what never appears.
  /// This is the way out that does not need the page: stop whatever is running, let the
  /// repairer turn off only the plugins it can prove are at fault, then start again.
  ///
  /// Nothing is disabled on a hunch. When the repairer cannot prove anyone guilty, the
  /// window stays failed and says so rather than leaving a profile with plugins quietly
  /// missing — the plugin window lists whatever was turned off, and re-enabling is one
  /// click there.
  public func quarantineAndRestart(maxRounds: Int = 8) async {
    guard !isBusy else { return }
    guard let recoverer else {
      record("Plugin repair is not available in this build.")
      return
    }
    isBusy = true
    defer { isBusy = false }

    // Re-read the launcher rather than trusting the window's own phase: a harness that
    // died on its own leaves this window still saying "running", and the repair has to
    // stop what is actually up before it boots the profile itself.
    let reported = await launcher.state()
    if phase == .running || reported.phase == .running {
      record("Stopping the harness first…")
      await stopUnchecked()
    }
    phase = .starting
    detail = nil
    record("Looking for plugins this runtime cannot load…")

    // A round is a real boot with a two-minute timeout, so a round with nothing to say
    // would look exactly like a hang. The repairer reports round boundaries; this keeps the
    // panel moving inside one.
    let ticker = Task { @MainActor in
      var seconds = 0
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if Task.isCancelled { return }
        seconds += 3
        self.record("Still repairing the profile… (\(seconds)s)")
      }
    }
    defer { ticker.cancel() }

    do {
      let outcome = try await recoverer.quarantine(
        profile: profile,
        maxRounds: maxRounds
      ) { progress in
        Task { @MainActor in self.record(progress.message) }
      }

      for name in outcome.disabled {
        record("Turned off \(name): the boot output blames it.")
      }
      if outcome.started {
        record("The profile boots with \(outcome.disabled.count) plugin(s) turned off. Starting the harness…")
        // The repair already proved this profile boots, and its lines above are the record
        // of what it cost, so this start keeps the log instead of clearing it.
        await startUnchecked(clearingLog: false)
      } else {
        phase = .failed
        detail = outcome.diagnostic
          ?? "The harness still does not start with every plugin turned off that the boot output named."
        record("Repair did not get the harness up after \(outcome.rounds) round(s).")
      }
    } catch {
      phase = .failed
      detail = (error as? RuntimeError)?.errorDescription ?? String(describing: error)
      record("Repair failed: \(detail ?? "unknown")")
    }
  }

  /// Re-read the launcher, so a harness that died on its own stops looking alive.
  public func refresh() async {
    let state = await launcher.state()
    guard !isBusy else { return }
    switch state.phase {
    case .running:
      if phase != .running {
        url = state.url
        phase = .running
        if let address = state.url, let parsed = URL(string: address) { attachWebModel(to: parsed) }
      }
    case .stopped where phase == .running:
      phase = .stopped
      url = nil
      detail = state.detail
      webModel?.clear()
      webModel = nil
    default:
      break
    }
  }

  // MARK: - Actions

  /// Put a line about how this launch was resolved — or how it ended — into the window log.
  ///
  /// The window is built before anything the user can see explains why it looks different —
  /// a cleared leftover Safe Mode tree is exactly the kind of thing that must not happen
  /// silently, and the banner says what the mode *is* rather than what was thrown away on
  /// the way here.
  public func recordBootNote(_ line: String) {
    record(line)
  }

  public func reload() {
    webModel?.reload()
  }

  public func openInBrowser() {
    guard let url, let parsed = URL(string: url) else { return }
    NSWorkspace.shared.open(parsed)
  }

  // MARK: - Upgrading

  /// Give this window the ability to move the runtime between installed releases.
  ///
  /// Called by the factory that built the window, because the coordinator needs the window it
  /// is driving and that window does not exist yet while the factory is still running. The
  /// runtime is driven through this window rather than by the coordinator directly for the
  /// same reason the console's own text warns about a second server: this window owns the
  /// port and the WebView attached to it.
  public func attachUpgrader(paths: RuntimePaths, installer: HarnessInstaller) {
    let profile = self.profile
    upgrader = HarnessUpgradeCoordinator(
      paths: paths,
      installer: installer,
      profile: profile,
      stopRuntime: { [weak self] in await self?.stopForUpgrade() },
      startRuntime: { [weak self] in
        guard let self else {
          throw RuntimeError.installFailed(step: "harness boot", detail: "窗口已关闭")
        }
        return try await self.startForUpgrade()
      },
      currentRuntime: { [weak self] in await self?.currentRuntimeState() },
      makeChecks: { announcedURL in
        // The audit is against the release that is active *now* — at this point in an
        // upgrade that is the new one, which is the only version the answer can be about.
        let active = (try? await installer.index())?.active
        return await HarnessUpgradeChecks.make(
          announcedURL: announcedURL,
          paths: paths,
          profile: profile,
          activeReleaseID: active
        )
      },
      progress: { [weak self] line in
        Task { @MainActor in self?.record(line) }
      }
    )
  }

  /// Whether this build wired an upgrader at all.
  public var canUpgradeRuntime: Bool { upgrader != nil }

  /// Move the runtime to another installed release, with automatic fallback.
  ///
  /// Returns the report rather than only publishing it, so the console — which cannot see
  /// this module — can show the outcome in the window the user pressed the button in.
  public func updateHarness(toReleaseID id: String) async -> UpgradeReport {
    guard !isBusy else {
      return UpgradeReport(toReleaseID: id, outcome: .aborted, summary: "窗口正忙，本次更新未执行。")
    }
    guard let upgrader else {
      return UpgradeReport(toReleaseID: id, outcome: .aborted, summary: "这个构建没有接入版本更新。")
    }
    isBusy = true
    defer { isBusy = false }
    let report = await upgrader.update(toReleaseID: id)
    upgradeReport = report
    return report
  }

  /// Finish an upgrade that a crash interrupted, once per launch.
  ///
  /// Called after the window has made its own boot attempt, so "the new release is active and
  /// up" and "the new release is active and down" are already decided. Returns nothing when
  /// there was no upgrade in flight — the common case.
  public func resumeUpgradeIfNeeded() async {
    guard !didResumeUpgrade, let upgrader else { return }
    didResumeUpgrade = true
    guard let report = await upgrader.resumeIfNeeded() else { return }
    upgradeReport = report
  }

  /// A boot for the coordinator: the same start the button runs, but its failure is thrown
  /// rather than only displayed.
  ///
  /// The display half still happens — `startUnchecked` fills in the failure panel — because
  /// the user should see the reason in the window they are looking at, not only in a report.
  private func startForUpgrade() async throws -> HarnessServerState {
    // `clearingLog: false`: the lines this boot prints are the outcome of the upgrade, and
    // wiping them would destroy the evidence the report is about.
    await startUnchecked(clearingLog: false)
    if phase == .running, let url {
      return HarnessServerState(phase: .running, url: url, detail: nil)
    }
    throw RuntimeError.installFailed(step: "harness boot", detail: detail ?? "harness 未能启动")
  }

  private func stopForUpgrade() async {
    await stopUnchecked()
  }

  /// What the launcher reports right now, rather than what this window last cached.
  ///
  /// The distinction matters: a harness that died on its own leaves this window still saying
  /// "running", and a rollback decision made from that stale value would be about a server
  /// that is not there.
  private func currentRuntimeState() async -> HarnessServerState? {
    let reported = await launcher.state()
    guard reported.phase == .running, reported.url?.isEmpty == false else { return nil }
    return reported
  }

  /// Quit the app and start it again.
  ///
  /// A reload re-fetches the page; this is for what a page cannot change — the workspace
  /// the harness was pointed at, a runtime that was just installed, a server stuck on its
  /// port. The harness runs in its own process group and outlives the app, so the quit has
  /// to be a real quit: the app delegate stops the server on the way out, and the relaunch
  /// waits for this process to be gone before opening the bundle, so the new instance
  /// never races the old one for the port.
  public func restartApplication() {
    record("Restarting the app…")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      Self.relaunchScript(
        waitingFor: ProcessInfo.processInfo.processIdentifier,
        bundle: Bundle.main.bundleURL.path,
        logPath: logFileURL?.path
      ),
    ]
    do {
      try process.run()
    } catch {
      record("Could not schedule the relaunch: \(error)")
      return
    }
    NSApp.terminate(nil)
  }

  /// The shell that opens the bundle once `pid` is gone.
  ///
  /// Waiting on this pid is not politeness: the harness runs in its own process group and
  /// outlives the app, so a relaunch that fires while this process is alive races it for the
  /// port. The wait is *bounded* for the mirror-image reason: this script is the only thing
  /// that can bring the window back, and a process that will not exit must not be able to
  /// strand the user in front of a window that never closes. Past the deadline the app is
  /// killed outright — its harness is then taken over by the next launch, which is strictly
  /// better than a spinner that never ends. Each branch writes one line to the window log,
  /// so "the relaunch was slow" and "the relaunch was stuck" can be told apart afterwards.
  ///
  /// Separate, pure, and static so the quoting is covered by a test: the bundle path comes
  /// from the filesystem and ends up on a shell command line.
  ///
  /// - Parameters:
  ///   - pid: the process that must exit first — this one.
  ///   - bundle: the `.app` to open again.
  ///   - logPath: where to record what the relaunch waited for. Omitted when the model has
  ///     no log file, which leaves a script that only does the waiting and the opening.
  ///   - patience: seconds to wait for this process to exit before killing it.
  /// - Returns: a `/bin/sh` command line.
  static func relaunchScript(
    waitingFor pid: Int32,
    bundle: String,
    logPath: String? = nil,
    patience: TimeInterval = 10
  ) -> String {
    let quoted = shellQuoted(bundle)
    let attempts = max(1, Int((patience / 0.2).rounded()))
    var steps = [
      "i=0; while kill -0 \(pid) 2>/dev/null && [ \"$i\" -lt \(attempts) ]; do i=$((i + 1)); sleep 0.2; done",
    ]
    let stillAlive = "kill -0 \(pid) 2>/dev/null"
    if let logPath {
      // The app's log directory normally exists; making it here means a relaunch cannot fail
      // to explain itself because someone cleaned it out.
      steps.append("mkdir -p \(Self.shellQuoted((logPath as NSString).deletingLastPathComponent))")
      steps.append(
        "if \(stillAlive); then \(Self.logAppend(logPath, "relaunch: pid \(pid) was still alive after \(Int(patience))s; killing it")); fi"
      )
    }
    steps.append(
      "if \(stillAlive); then kill -9 \(pid) 2>/dev/null; j=0; while \(stillAlive) && [ \"$j\" -lt 10 ]; do j=$((j + 1)); sleep 0.2; done; fi"
    )
    if let logPath {
      steps.append(Self.logAppend(logPath, "relaunch: opening \(bundle)"))
    }
    steps.append("/usr/bin/open -n \(quoted)")
    return steps.joined(separator: "; ")
  }

  /// One `echo … >> log` step, for a script that has to explain itself after the app is gone.
  ///
  /// The message is ours and contains no quotes or expansions; the path is not.
  static func logAppend(_ path: String, _ message: String) -> String {
    "echo \"[$(date '+%Y-%m-%dT%H:%M:%SZ')] \(message)\" >> \(shellQuoted(path))"
  }

  /// Single-quote a value for `/bin/sh`, the POSIX way: a quote cannot appear inside
  /// quotes, so it is closed, escaped, and reopened.
  static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// The address the window shows: scheme, host, and port.
  ///
  /// The URL the web view loads carries the access token in its query, and that token is a
  /// credential, so the toolbar shows where the harness is listening rather than how to
  /// authenticate to it. `openInBrowser()` still hands the browser the full URL.
  public var displayURL: String? {
    guard let url, let parsed = URL(string: url) else { return nil }
    return Self.address(of: parsed)
  }

  /// Pick the workspace directory handed to the harness.
  public func chooseWorkspace() {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose the folder the harness should treat as your workspace"
    panel.directoryURL = workspaceURL
    guard panel.runModal() == .OK, let chosen = panel.url else { return }
    workspacePath = chosen.path
    defaults.set(chosen.path, forKey: Self.workspaceDefaultsKey)
    // A running server keeps the workspace it started in, so say so instead of silently
    // doing nothing.
    if phase == .running {
      record("Workspace changed to \(chosen.path). Restart the harness for it to apply.")
    }
  }

  // MARK: - Plumbing

  private func attachWebModel(to base: URL) {
    // The *address* decides, not the host. Every harness start picks a new port, so a
    // comparison that only looks at "127.0.0.1" keeps a window pinned to a server that is
    // gone: the page it holds still renders, then fails every request it makes — the
    // client-plugin bundles first — while the toolbar confidently reports "running".
    guard webModel?.webView.url.map(Self.address(of:)) != Self.address(of: base) else { return }
    record("harness URL: \(Self.address(of: base))")
    let model = HarnessWebModel(
      baseURL: base,
      onExternal: { url in NSWorkspace.shared.open(url) },
      onEvent: { [weak self] event in
        Task { @MainActor in self?.record(event) }
      }
    )
    model.load(base)
    webModel = model
  }

  /// The address through the port, without the query string.
  ///
  /// The URL the web view loads carries the access token in its query, and that token is a
  /// credential: the log lines here reach both the on-screen panel and the log file, so the
  /// query is dropped before logging while the loaded URL keeps it — the server answers a
  /// request without the token with 401. The `record` redaction stays as the backstop for
  /// tokens in forwarded process output. `displayURL` is the same address for the toolbar.
  /// @param url - the base URL the web view is about to load.
  /// @returns the scheme, host, and port only.
  static func address(of url: URL) -> String {
    var components = URLComponents()
    components.scheme = url.scheme
    components.host = url.host
    components.port = url.port
    return components.string ?? "\(url.host ?? ""):\(url.port.map(String.init) ?? "")"
  }

  private func record(_ line: String) {
    let safe = Self.redacting(line)
    log.append(safe)
    if log.count > 200 { log.removeFirst(log.count - 200) }
    write(safe)
  }

  /// Replace access-token values wherever they appear.
  ///
  /// The harness prints its own banner — "dsh web: http://127.0.0.1:<port>/?token=..." —
  /// and that line is forwarded here verbatim, so redacting at the call sites would miss
  /// it. Doing it once, on the way into the log, is the only version that covers every
  /// path: a token in a log file outlives the process that used it.
  ///
  /// Written as a single pass over a shrinking remainder rather than a replace-in-place
  /// loop. Replacing the *value* leaves the "token=" prefix behind, so a loop that
  /// re-scans the whole string finds it again and rewrites the same text forever — which
  /// is a hang on the main actor, not a cosmetic bug. Here every iteration consumes at
  /// least the marker, so the remainder strictly shrinks.
  static func redacting(_ line: String) -> String {
    var output = ""
    var rest = Substring(line)
    while let marker = rest.range(of: "token=") {
      output += rest[rest.startIndex..<marker.upperBound]
      let after = rest[marker.upperBound...]
      let end = after.firstIndex { $0 == " " || $0 == "&" || $0 == "\n" } ?? after.endIndex
      output += "<redacted>"
      rest = rest[end...]
    }
    output += rest
    return output
  }

  private func openLogFile() {
    guard let url = logFileURL else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    logHandle = try? FileHandle(forWritingTo: url)
    _ = try? logHandle?.seekToEnd()
    record("window opened; workspace \(workspacePath)")
  }

  private func write(_ line: String) {
    guard let logHandle else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
    try? logHandle.write(contentsOf: Data("[\(stamp)] \(line)\n".utf8))
  }

  public var recentLog: String {
    log.suffix(12).joined(separator: "\n")
  }
}

/// Turns a quit into a graceful shutdown.
///
/// The harness runs in its own process group precisely so signals aimed at one process do
/// not reach the app — which also means it does not die when the app does. Without this
/// hook, quitting leaves an orphan holding the port, and the next launch finds it busy.
///
/// §applicationShouldTerminate§ returns §.terminateLater§ so there is time to actually
/// stop the server; AppKit waits for §reply(toApplicationShouldTerminate:)§. That wait is
/// the whole danger, and this type now bounds it three ways: the stop is short, the reply
/// is issued once, and a deadline issues it anyway. An unbounded version of this is exactly
/// a "Restarting the app…" spinner that only a force quit ends — and force quitting is what
/// leaves the harness behind for the next launch to kill.
@MainActor
public final class HarnessWindowDelegate: NSObject, NSApplicationDelegate {
  /// Set by the app once the window model exists.
  public weak var model: HarnessWindowModel?

  /// How long after a quit is asked for the reply happens no matter what.
  ///
  /// The stop has its own timeout; this is the backstop for everything inside it that can
  /// outlast one — a process the kernel will not reap, a wait that comes back late, an
  /// await that never resumes. Meanwhile the shell script that reopens the app is waiting
  /// for *this* process, so failing to answer is failing to come back at all.
  public static let quitDeadline: TimeInterval = 10

  /// Whether the outstanding request has been answered. Reset per request so a reply owed
  /// to an earlier one cannot swallow this one.
  private var replied = false
  private var deadline: Task<Void, Never>?

  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    replied = false
    deadline?.cancel()
    deadline = nil

    guard let model, model.mayHoldAServer else { return .terminateNow }

    deadline = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(Self.quitDeadline * 1_000_000_000))
      guard !Task.isCancelled else { return }
      model.recordBootNote(
        "The harness did not stop within \(Int(Self.quitDeadline))s; closing the app anyway."
      )
      self.replyOnce()
    }
    Task { @MainActor in
      await model.stopForTermination()
      self.replyOnce()
    }
    return .terminateLater
  }

  /// Answer AppKit, at most once, whichever of the two paths got here first.
  private func replyOnce() {
    guard !replied else { return }
    replied = true
    deadline?.cancel()
    deadline = nil
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
