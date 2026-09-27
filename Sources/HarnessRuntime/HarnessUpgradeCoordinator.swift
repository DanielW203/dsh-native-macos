import Foundation

/// Moves the app from one installed harness release to another, and puts it back when the
/// new one does not work.
///
/// **Why this is a coordinator and not a button handler.** The interesting behaviour is not
/// "activate a release" — that is one symlink swap `HarnessInstaller` already does. It is the
/// decision that follows: a failed boot must return the user to a working runtime *and* leave
/// behind an explanation, and a crash in the middle must not leave the app in a state neither
/// the user nor the next launch can name. That decision needs the ledger, the launcher, and
/// the checks to be the same object's collaborators, which is what this actor is.
///
/// **What it deliberately does not own.** The running server. The main window owns the port
/// and the WebView attached to it, so this actor drives the runtime through injected
/// closures rather than starting a second server of its own — the failure the console's own
/// text already warns about.
public actor HarnessUpgradeCoordinator {
  /// Boot the runtime the way the owner boots it, and report what happened.
  ///
  /// Throwing here means the new release did not come up; the state it returns is used for
  /// its announced URL and, on `phase != .running`, for its own failure text.
  public typealias RuntimeStarter = @Sendable () async throws -> HarnessServerState
  /// Stop whatever runtime is up. Called before every start, so a half-dead process from the
  /// attempt that just failed cannot hold the port against the retry.
  public typealias RuntimeStopper = @Sendable () async -> Void
  /// What the runtime is doing right now, or `nil` when nothing is up.
  ///
  /// Read rather than remembered: the leaker this app already fixed once was a window that
  /// still said "running" about a server that had died on its own, so the live answer is the
  /// only one worth acting on.
  public typealias RuntimeProbe = @Sendable () async -> HarnessServerState?
  /// Build the checks for a runtime that is up, given the address it announced.
  ///
  /// A factory rather than an array because half the checks need something that only exists
  /// after a successful boot — the URL and the launch token inside it. Checks live in
  /// `HarnessUI`, which is where the API client is visible; this actor never sees it.
  public typealias CheckFactory = @Sendable (String) async -> [any HarnessCheck]
  /// One progress line, for the console's log pane.
  public typealias ProgressReporter = @Sendable (String) -> Void
  /// What the runtime's own output says about the plugins it loaded, given the address it
  /// announced.
  ///
  /// A factory rather than a value because the answer only exists after a boot, and it is the
  /// one signal that tells "the server is up" apart from "the server is up and the profile is
  /// intact" — the distinction a 0.1.7-era boot made invisible.
  public typealias BootHealthFactory = @Sendable (String) async -> HarnessBootHealth
  /// Something that can put the app into Safe Mode for the next launch.
  ///
  /// Injected rather than called directly because the marker and the relaunch are the app's
  /// business, not this actor's: the coordinator decides *that* a release needs its plugins
  /// out of the picture; how that becomes a running app is the window's.
  public typealias SafeModeEscalator = @Sendable (String) async -> Bool

  /// The name the coordinator itself contributes to every report.
  public static let bootCheckName = "boot"

  public let paths: RuntimePaths
  private let installer: HarnessInstaller
  private let pending: PendingUpgradeStore
  private let reports: UpgradeReportStore
  private let profile: String
  private let stopRuntime: RuntimeStopper
  private let startRuntime: RuntimeStarter
  private let currentRuntime: RuntimeProbe
  private let makeChecks: CheckFactory
  private let progress: ProgressReporter
  /// The pre-upgrade plugin probe. `nil` keeps the old behaviour exactly: activate, boot,
  /// verify, roll back — which is what a test or a stripped build gets.
  private let preflight: (any PluginPreflighting)?
  /// What a boot's output said about the plugins. `nil` means this build cannot tell, and the
  /// coordinator falls back to "running is good enough".
  private let bootHealth: BootHealthFactory?
  /// How a release that cannot be repaired becomes a Safe Mode launch.
  private let escalateToSafeMode: SafeModeEscalator?
  /// How many launches in a row one release has already failed.
  private let strikes: BootStrikeLedger
  /// Single flight. Two windows can both press the button, and two upgrades interleaving
  /// their activation and their rollback would produce a state neither of them wrote.
  private var isRunning = false

  public init(
    paths: RuntimePaths,
    installer: HarnessInstaller,
    pending: PendingUpgradeStore? = nil,
    reports: UpgradeReportStore? = nil,
    strikes: BootStrikeLedger? = nil,
    profile: String,
    stopRuntime: @escaping RuntimeStopper,
    startRuntime: @escaping RuntimeStarter,
    currentRuntime: @escaping RuntimeProbe,
    makeChecks: @escaping CheckFactory,
    preflight: (any PluginPreflighting)? = nil,
    bootHealth: BootHealthFactory? = nil,
    escalateToSafeMode: SafeModeEscalator? = nil,
    progress: @escaping ProgressReporter = { _ in }
  ) {
    self.paths = paths
    self.installer = installer
    self.pending = pending ?? PendingUpgradeStore(paths: paths)
    self.reports = reports ?? UpgradeReportStore(paths: paths)
    self.strikes = strikes ?? BootStrikeLedger(paths: paths)
    self.profile = profile
    self.stopRuntime = stopRuntime
    self.startRuntime = startRuntime
    self.currentRuntime = currentRuntime
    self.makeChecks = makeChecks
    self.preflight = preflight
    self.bootHealth = bootHealth
    self.escalateToSafeMode = escalateToSafeMode
    self.progress = progress
  }

  /// Whether an upgrade is in flight right now.
  public var isBusy: Bool { isRunning }

  // MARK: - Updating

  /// Move the active runtime to `target`, verify it, and fall back if it does not work.
  ///
  /// One operation serves both the "update" and the "roll back to the previous version"
  /// buttons: rolling back is an upgrade in the other direction, and it deserves the same
  /// safety net — the version being returned to may itself have been left broken.
  public func update(toReleaseID target: String) async -> UpgradeReport {
    guard !isRunning else {
      return finish(UpgradeReport(
        toReleaseID: target,
        outcome: .aborted,
        summary: "另一个更新正在进行，本次未执行。"
      ))
    }
    isRunning = true
    defer { isRunning = false }
    // A person choosing a version is the authority on whether it is worth another try, so the
    // consecutive-failure counts are not evidence against what happens next. Leaving them would
    // make the first failure of this attempt look like the third, and the ladder would skip
    // straight to Safe Mode on an upgrade the user just asked for.
    strikes.clearAll()
    return await perform(target: target)
  }

  private func perform(target: String) async -> UpgradeReport {
    let ledger: InstallsIndex
    do {
      ledger = try await installer.index()
    } catch {
      return finish(UpgradeReport(
        toReleaseID: target,
        outcome: .aborted,
        summary: "读不到版本账本，未改动任何东西：\(describe(error))"
      ))
    }

    guard let toRelease = ledger.release(id: target) else {
      return finish(UpgradeReport(
        toReleaseID: target,
        outcome: .aborted,
        summary: "没有安装 id 为 \(target) 的版本，未改动任何东西。"
      ))
    }
    // A ledger entry whose directory was deleted by hand is not a version to move to. The
    // installer reports it as absent; so does this.
    guard toRelease.isMaterialized(in: paths.releaseDirectory(target)) else {
      return finish(UpgradeReport(
        toReleaseID: target,
        outcome: .aborted,
        summary: "\(target) 的目录不完整（缺少 \(toRelease.entry)），拒绝更新。"
      ))
    }

    guard let fromID = ledger.active else {
      return finish(UpgradeReport(
        toReleaseID: target,
        outcome: .aborted,
        summary: "当前没有正在使用的版本，未改动任何东西。"
      ))
    }

    // Already there: nothing to move to and nothing to fall back from. Verifying in place is
    // the useful half of the request, and it does not disturb a running window.
    if fromID == target {
      return await verifyInPlace(target: target)
    }

    // The refusal that must happen *before* the active pointer moves. An upgrade with no way
    // back is exactly the situation this feature exists to prevent, so it is a hard stop
    // rather than a warning.
    guard let fromRelease = ledger.release(id: fromID),
          fromRelease.isMaterialized(in: paths.releaseDirectory(fromID))
    else {
      let detail = "\(fromID) 的目录不存在或不可执行；先保留一个能用的旧版本再更新"
      return finish(UpgradeReport(
        fromReleaseID: fromID,
        toReleaseID: target,
        outcome: .aborted,
        summary: RuntimeError.noRollbackTarget(detail).errorDescription ?? detail
      ))
    }

    // The rollback point, written before anything moves.
    let record = PendingUpgradeRecord(
      fromReleaseID: fromID,
      toReleaseID: target,
      profile: profile,
      stage: .activating
    )
    do {
      try pending.save(record)
    } catch {
      return finish(UpgradeReport(
        fromReleaseID: fromID,
        toReleaseID: target,
        outcome: .aborted,
        summary: "写不进回退点标记，未改动任何东西：\(describe(error))"
      ))
    }

    var tracker = QuarantineTracker(profile: profile)
    // The pre-upgrade look, taken before the active pointer moves so the working version is
    // still the one a repair would run against. This is the step that turns "the new release
    // boots with your plugins quietly skipped" into "two plugins were already out of the way
    // when it booted".
    let preflightNotes = await runPreflight(target: target, tracker: &tracker)

    progress("Activating \(target)…")
    do {
      try await installer.activate(target)
    } catch {
      // Nothing was started, so the old runtime is still the one the user is looking at.
      // The marker goes away because there is no in-flight state to remember.
      pending.clear()
      return finish(UpgradeReport(
        fromReleaseID: fromID,
        toReleaseID: target,
        outcome: .aborted,
        summary: "激活 \(target) 失败，未启动；旧版本 \(fromID) 仍在：\(describe(error))",
        notes: preflightNotes,
        pluginQuarantined: tracker.quarantined.isEmpty ? nil : tracker.quarantined
      ))
    }

    pending.advance(to: .booting)
    progress("Restarting the harness on \(target)…")
    await stopRuntime()

    var notes = preflightNotes
    let recovery: RecoveryOutcome
    do {
      let state = try await startRuntime()
      guard state.phase == .running, let url = state.url, !url.isEmpty else {
        throw RuntimeError.installFailed(
          step: "harness boot",
          detail: state.detail ?? "harness 未报告监听地址"
        )
      }
      recovery = await assessBoot(announcedURL: url, target: target, tracker: &tracker, notes: &notes)
    } catch {
      recovery = await repairFailedBoot(
        failure: describe(error),
        target: target,
        tracker: &tracker,
        notes: &notes
      )
    }

    switch recovery {
    case .unrepaired(let bootFailure, let reason):
      return await concludeUnrepaired(
        from: fromID,
        failedTarget: target,
        bootFailure: bootFailure,
        reason: reason,
        tracker: tracker,
        notes: notes
      )

    case .working(let health):
      if health.verdict == .degraded {
        // Still degraded after a repair round. Reported as a check result rather than only a
        // note, so `plugins` in the saved report says what the window banner says.
        notes.append("隔离后启动输出仍有插件问题：" + health.summary)
      }
      progress("Checking the new runtime…")
      pending.advance(to: .verifying)
      guard let announced = await currentRuntimeURL() else {
        return await rollBack(
          from: fromID,
          failedTarget: target,
          bootFailure: nil,
          reason: "启动后没有可用的地址",
          checks: [],
          tracker: tracker,
          notes: notes
        )
      }
      let checks = await verify(announcedURL: announced)
      let blocking = checks.filter { $0.isBlocking && $0.verdict == .fail }
      guard blocking.isEmpty else {
        // A blocking check failure is not a plugin story: the endpoints, the session list, or
        // the address itself is what is wrong. Rolling back is the honest outcome, and the
        // quarantine that was already performed stays recorded so it is not a mystery later.
        return await rollBack(
          from: fromID,
          failedTarget: target,
          bootFailure: nil,
          reason: "关键自检未通过（\(blocking.map(\.name).joined(separator: ", "))）",
          checks: checks,
          tracker: tracker,
          notes: notes
        )
      }

      pending.clear()
      strikes.clear(target)
      return finish(UpgradeReport(
        fromReleaseID: fromID,
        toReleaseID: target,
        outcome: .kept,
        summary: "\(target) 已启用并通过自检"
          + concernSuffix(checks)
          + quarantineSuffix(tracker),
        checks: checks,
        notes: notes,
        pluginPreflight: tracker.findings.isEmpty ? nil : tracker.findings,
        pluginQuarantined: tracker.quarantined.isEmpty ? nil : tracker.quarantined
      ))
    }
  }

  // MARK: - The recovery ladder

  /// What one boot attempt, plus whatever repair it needed, concluded.
  private enum RecoveryOutcome {
    /// A runtime is up and the profile under it is intact.
    case working(HarnessBootHealth)
    /// Nothing that was tried produced a runtime, or the one that came up would not verify.
    case unrepaired(bootFailure: String?, reason: String)
  }

  /// What one recovery step is allowed to do, and what it accrues.
  ///
  /// A value carried through the ladder rather than four separate locals, because every step
  /// has to add to the same list: the report is what turns "the app quietly disabled two
  /// plugins" into something the user can undo.
  private struct QuarantineTracker {
    var profile: String
    var quarantined: [String] = []
    var findings: [String: String] = [:]

    mutating func add(_ names: [String]) {
      for name in names where !quarantined.contains(name) {
        quarantined.append(name)
      }
      quarantined.sort()
    }
  }

  /// Probe the target release's ability to load the profile's plugins, and take the ones that
  /// cannot out of the picture before the switch.
  private func runPreflight(target: String, tracker: inout QuarantineTracker) async -> [String] {
    guard let preflight else { return [] }
    progress("Preflight: loading \(profile)'s plugins under \(target)…")
    let result = await preflight.findUnloadable(profile: profile, releaseID: target)
    for (name, reason) in result.unloadable.sorted(by: { $0.key < $1.key }) {
      tracker.findings[name] = reason
    }
    guard !result.unloadable.isEmpty else {
      let line = result.notes.isEmpty ? "Preflight: nothing to quarantine." : "Preflight: \(result.notes.joined(separator: "；"))"
      progress(line)
      return result.notes
    }
    let names = result.unloadable.keys.sorted()
    progress("Preflight: \(names.count) plugin(s) cannot load under \(target): \(names.joined(separator: ", "))")
    let disabled = await preflight.quarantine(names, profile: profile, releaseID: target)
    tracker.add(disabled)
    progress("Preflight: turned off \(disabled.joined(separator: ", ")) before switching.")
    return result.notes
  }

  /// Read what the boot's output says, and repair it once when it says a plugin is missing.
  ///
  /// One round, deliberately: a boot costs a port and up to two minutes, and an upgrade that
  /// chained them would be a hang. The rest of the ladder is the next launch's business.
  private func assessBoot(
    announcedURL: String,
    target: String,
    tracker: inout QuarantineTracker,
    notes: inout [String]
  ) async -> RecoveryOutcome {
    guard let bootHealth else {
      return .working(HarnessBootHealth(isRunning: true))
    }
    let health = await bootHealth(announcedURL)
    guard health.verdict == .degraded else {
      return .working(health)
    }
    notes.append("启动输出报告插件问题：" + health.summary)

    let names = health.attributedPluginNames
    guard let preflight, !names.isEmpty else {
      // Nothing proof-backed to act on. A degraded boot with no attributable name is reported,
      // not repaired — disabling a guess is how a working plugin disappears by accident.
      notes.append("启动有插件问题但没有可证实的包名，未自动隔离。")
      return .working(health)
    }
    progress("Plugins missing from the boot: \(names.joined(separator: ", ")); turning them off and trying again…")
    let disabled = await preflight.quarantine(names, profile: tracker.profile, releaseID: target)
    tracker.add(disabled)
    guard !disabled.isEmpty else {
      notes.append("想隔离 \(names.joined(separator: ", ")) 但都没能写进 profile。")
      return .working(health)
    }
    notes.append("已隔离启动输出指认的插件：\(disabled.joined(separator: ", "))")

    await stopRuntime()
    do {
      let state = try await startRuntime()
      guard state.phase == .running, let url = state.url, !url.isEmpty else {
        return .unrepaired(bootFailure: state.detail, reason: "隔离插件后仍未报告监听地址")
      }
      let after = await bootHealth(url)
      if after.verdict == .degraded {
        notes.append("隔离后启动仍有插件问题：" + after.summary)
      }
      return .working(after)
    } catch {
      return .unrepaired(bootFailure: describe(error), reason: "隔离插件后启动失败")
    }
  }

  /// A boot that never came up: disable what the failure blames, boot again, and see.
  private func repairFailedBoot(
    failure: String,
    target: String,
    tracker: inout QuarantineTracker,
    notes: inout [String]
  ) async -> RecoveryOutcome {
    guard let preflight else {
      return .unrepaired(bootFailure: failure, reason: "启动失败")
    }
    let suspects = PluginFailureReader.suspects(in: failure, profile: profile, paths: paths)
    guard !suspects.isEmpty else {
      // Nothing in the output names a plugin, so this is not a plugin story. Guessing here
      // would disable a working plugin and still not boot.
      return .unrepaired(bootFailure: failure, reason: "启动失败")
    }
    progress("Boot failed and blamed \(suspects.joined(separator: ", ")); turning them off and trying again…")
    let disabled = await preflight.quarantine(suspects, profile: tracker.profile, releaseID: target)
    tracker.add(disabled)
    guard !disabled.isEmpty else {
      return .unrepaired(bootFailure: failure, reason: "启动失败，且没能把责任插件写进 profile")
    }
    notes.append("启动失败，已隔离：\(disabled.joined(separator: ", "))")

    await stopRuntime()
    do {
      let state = try await startRuntime()
      guard state.phase == .running, let url = state.url, !url.isEmpty else {
        return .unrepaired(bootFailure: state.detail ?? failure, reason: "隔离插件后仍未报告监听地址")
      }
      if let bootHealth {
        let health = await bootHealth(url)
        if health.verdict == .degraded {
          notes.append("抢救成功后启动仍有插件问题：" + health.summary)
        }
        return .working(health)
      }
      return .working(HarnessBootHealth(isRunning: true))
    } catch {
      return .unrepaired(bootFailure: describe(error), reason: "隔离插件后启动失败")
    }
  }

  /// Nothing worked, on the path where the user asked for the upgrade.
  ///
  /// This one ends in a rollback and never in Safe Mode. The two are not interchangeable: a
  /// rollback keeps the app running on the version that works and asks the user for nothing,
  /// while Safe Mode is a restart they have to notice and act on. Safe Mode is the answer to
  /// "the app will not come up again", which is a launch-time question — see
  /// `recoverInterruptedUpgrade`.
  private func concludeUnrepaired(
    from fromID: String,
    failedTarget: String,
    bootFailure: String?,
    reason: String,
    tracker: QuarantineTracker,
    notes: [String]
  ) async -> UpgradeReport {
    await rollBack(
      from: fromID,
      failedTarget: failedTarget,
      bootFailure: bootFailure,
      reason: reason,
      checks: [],
      tracker: tracker,
      notes: notes
    )
  }

  private static let safeModeArranged =
    "下次启动会以安全模式（无插件）运行；Harness 菜单可退出安全模式。"

  /// The address of whatever runtime is up right now.
  private func currentRuntimeURL() async -> String? {
    guard let state = await currentRuntime(), state.phase == .running, let url = state.url, !url.isEmpty else {
      return nil
    }
    return url
  }

  /// `（已隔离 …）`, or nothing.
  private func quarantineSuffix(_ tracker: QuarantineTracker) -> String {
    tracker.quarantined.isEmpty ? "" : "（已隔离 \(tracker.quarantined.joined(separator: ", "))）"
  }

  /// Checks only, for a release that is already active. Never restarts anything.
  private func verifyInPlace(target: String) async -> UpgradeReport {
    guard let state = await currentRuntime(), state.phase == .running,
          let url = state.url, !url.isEmpty
    else {
      // Nothing running means there is no address to check against, and reporting a pass
      // would be the worst possible answer to "is this release healthy?".
      return finish(UpgradeReport(
        toReleaseID: target,
        outcome: .aborted,
        summary: "\(target) 已经是当前版本；没有正在运行的 harness 可供自检，未做改动。"
      ))
    }
    let checks = await verify(announcedURL: url)
    let blocking = checks.filter { $0.isBlocking && $0.verdict == .fail }
    let outcome: UpgradeReport.Outcome = blocking.isEmpty ? .kept : .aborted
    return finish(UpgradeReport(
      toReleaseID: target,
      outcome: outcome,
      summary: blocking.isEmpty
        ? "\(target) 已经是当前版本，自检通过\(concernSuffix(checks))"
        : "\(target) 已经是当前版本，但关键自检未通过：\(blocking.map(\.name).joined(separator: ", "))",
      checks: checks
    ))
  }

  // MARK: - Resuming

  /// Finish an upgrade that a crash interrupted.
  ///
  /// Called once per launch, after the window has attempted its own boot — so "the new
  /// release is active and the runtime is up" and "the new release is active and the runtime
  /// is not" are both already decided by the time this asks.
  public func resumeIfNeeded() async -> UpgradeReport? {
    let loaded = pending.load()
    guard case .record(let record) = loaded else {
      if case .unreadable(let detail) = loaded {
        // A marker this build cannot understand is cleared rather than left to be
        // re-reported on every launch forever. Nothing is changed about the runtime.
        pending.clear()
        return finish(UpgradeReport(
          toReleaseID: "未知",
          outcome: .aborted,
          summary: "上次升级的标记读不出来（\(detail)），已清除；当前运行版本未改动。"
        ))
      }
      return nil
    }

    guard !isRunning else { return nil }
    isRunning = true
    defer { isRunning = false }

    let active = (try? await installer.index())?.active
    guard active == record.toReleaseID else {
      // Died before the new release took over, or a previous rollback already ran. There is
      // nothing to undo and nothing to verify.
      pending.clear()
      return finish(UpgradeReport(
        fromReleaseID: record.fromReleaseID,
        toReleaseID: record.toReleaseID,
        outcome: .aborted,
        summary: "上次升级在激活 \(record.toReleaseID) 之前中断（停在 \(record.stage.rawValue)）；"
          + "当前是 \(active ?? "无")，标记已清除，无需回退。"
      ))
    }

    // Active and up: verify it, and treat "up and intact" as the end of the story. This is the
    // first branch because a release that works must never be punished for an earlier launch's
    // failure — the strike ledger exists to stop a loop, not to keep score.
    guard let state = await currentRuntime(), state.phase == .running, let url = state.url, !url.isEmpty else {
      return await recoverInterruptedUpgrade(record: record, failure: "升级后首次启动未成功（标记停在 \(record.stage.rawValue)）")
    }

    if let bootHealth {
      let health = await bootHealth(url)
      if health.verdict == .degraded {
        return await recoverInterruptedUpgrade(
          record: record,
          failure: "升级后启动成功但插件缺失：" + health.summary,
          health: health,
          announcedURL: url
        )
      }
    }

    // Active and up, but never verified: verify now and roll back only if a blocking check
    // fails. A warning is not a reason to undo an upgrade the user already has.
    let checks = await verify(announcedURL: url)
    let blocking = checks.filter { $0.isBlocking && $0.verdict == .fail }
    guard blocking.isEmpty else {
      return await recoverInterruptedUpgrade(
        record: record,
        failure: "关键自检未通过（\(blocking.map(\.name).joined(separator: ", "))）",
        checks: checks,
        announcedURL: url
      )
    }

    pending.clear()
    strikes.clear(record.toReleaseID)
    return finish(UpgradeReport(
      fromReleaseID: record.fromReleaseID,
      toReleaseID: record.toReleaseID,
      outcome: .kept,
      summary: "上次中断的升级已确认完成：\(record.toReleaseID) 自检通过\(concernSuffix(checks))",
      checks: checks
    ))
  }

  // MARK: - The launch-time ladder

  /// One unhealthy launch of the release an interrupted upgrade moved to.
  ///
  /// This is the branch that makes an unattended recovery possible at all. The upgrade that
  /// first failed is over — the app is running the new release and it does not work — and the
  /// only thing standing between the user and a hand-repair is whether this decides to try the
  /// same repair the upgrade path would have.
  ///
  /// The decision is by consecutive-failure count, and the counts mean different things:
  ///
  /// - **first**: repair what can be repaired, and otherwise do what the app has always done —
  ///   put the previous release back and boot it. A rollback needs no restart, so it is the
  ///   right first answer for a user who is looking at the screen.
  /// - **second**: the rollback did not stick, or the user came back to the same broken
  ///   release. Repair again, and when that fails, arrange a Safe Mode launch — a rollback
  ///   loops between two versions when the home itself is what is wrong, and Safe Mode is the
  ///   answer to "the app must still open".
  /// - **third and beyond**: stop acting. The app is not going to repair this one, and
  ///   escalating forever would hide which release is actually broken.
  private func recoverInterruptedUpgrade(
    record: PendingUpgradeRecord,
    failure: String,
    health: HarnessBootHealth? = nil,
    checks: [HarnessCheckResult] = [],
    announcedURL: String? = nil
  ) async -> UpgradeReport {
    _ = announcedURL
    let strikesForRelease = strikes.recordStrike(
      forReleaseID: record.toReleaseID,
      stage: record.stage.rawValue
    )

    if strikesForRelease >= BootStrikeLedger.escalationLimit {
      return finish(UpgradeReport(
        fromReleaseID: record.fromReleaseID,
        toReleaseID: record.toReleaseID,
        outcome: .aborted,
        summary: "\(record.toReleaseID) 连续 \(strikesForRelease) 次启动未通过；"
          + "不再自动尝试，建议回退到 \(record.fromReleaseID)（控制台可一键切回）。",
        bootFailure: failure,
        checks: checks,
        notes: [Self.markerKept]
      ))
    }

    var tracker = QuarantineTracker(profile: record.profile)
    var notes: [String] = []
    let names = health?.attributedPluginNames
      ?? PluginFailureReader.suspects(in: failure, profile: record.profile, paths: paths)

    if let preflight, !names.isEmpty {
      progress("A release that failed to start blames \(names.joined(separator: ", ")); turning them off…")
      let disabled = await preflight.quarantine(names, profile: record.profile, releaseID: record.toReleaseID)
      tracker.add(disabled)
      if !disabled.isEmpty {
        notes.append("隔离后重试：\(disabled.joined(separator: ", "))")
        await stopRuntime()
        if let state = try? await startRuntime(),
           state.phase == .running, let url = state.url, !url.isEmpty {
          let afterChecks = await verify(announcedURL: url)
          let blocking = afterChecks.filter { $0.isBlocking && $0.verdict == .fail }
          if blocking.isEmpty {
            pending.clear()
            strikes.clear(record.toReleaseID)
            return finish(UpgradeReport(
              fromReleaseID: record.fromReleaseID,
              toReleaseID: record.toReleaseID,
              outcome: .kept,
              summary: "\(record.toReleaseID) 启动失败后已隔离 \(disabled.joined(separator: ", ")) 并通过自检。",
              checks: afterChecks,
              notes: notes,
              pluginQuarantined: disabled
            ))
          }
          notes.append("隔离后自检仍未过：\(blocking.map(\.name).joined(separator: ", "))")
        } else {
          notes.append("隔离后仍然起不来。")
        }
      }
    }

    // The repair did not produce a working runtime. On the first failure the answer is the one
    // the app has always given; only a *repeat* failure, which a rollback could not explain
    // away, turns into Safe Mode.
    if strikesForRelease >= 2,
       let escalateToSafeMode,
       await escalateToSafeMode("\(record.toReleaseID) 连续 \(strikesForRelease) 次未通过体检：\(failure)") {
      return finish(UpgradeReport(
        fromReleaseID: record.fromReleaseID,
        toReleaseID: record.toReleaseID,
        outcome: .aborted,
        summary: "\(record.toReleaseID) 连续 \(strikesForRelease) 次未通过体检；已安排以安全模式重启（无插件）。",
        bootFailure: failure,
        checks: checks,
        notes: notes + [Self.safeModeArranged, Self.markerKept],
        pluginQuarantined: tracker.quarantined.isEmpty ? nil : tracker.quarantined
      ))
    }

    return await rollBack(
      from: record.fromReleaseID,
      failedTarget: record.toReleaseID,
      bootFailure: failure,
      reason: "启动或自检未通过",
      checks: checks,
      tracker: tracker,
      notes: notes
    )
  }

  // MARK: - Rolling back

  /// Put `from` back and boot it. One attempt: a failed rollback is reported, never retried,
  /// because a loop here would oscillate between two runtimes neither of which works.
  private func rollBack(
    from fromID: String,
    failedTarget: String,
    bootFailure: String?,
    reason: String,
    checks: [HarnessCheckResult],
    tracker: QuarantineTracker? = nil,
    notes: [String] = [],
    extraNotes: [String] = []
  ) async -> UpgradeReport {
    let carriedNotes = notes + extraNotes
    let quarantined = tracker?.quarantined ?? []
    let findings = tracker?.findings ?? [:]
    // The failing boot is itself a check result, and it is the only one that exists when the
    // process never announced an address. Dropping it would leave the report with a reason but
    // no evidence, and the report is what the user reads.
    let allChecks: [HarnessCheckResult]
    if checks.isEmpty, let bootFailure {
      allChecks = [Self.failedBootResult(bootFailure)]
    } else {
      allChecks = checks
    }
    progress("Rolling back to \(fromID)…")
    do {
      try await installer.activate(fromID)
    } catch {
      // The marker stays: the app is not in a state it is willing to call good, and the next
      // launch has to know that.
      return finish(UpgradeReport(
        fromReleaseID: fromID,
        toReleaseID: failedTarget,
        outcome: .aborted,
        summary: "回退失败：无法激活 \(fromID)（\(describe(error))）。"
          + "请用 Harness Console 手动选版本，或进入安全模式。",
        bootFailure: bootFailure,
        checks: allChecks,
        notes: carriedNotes + [Self.markerKept],
        pluginPreflight: findings.isEmpty ? nil : findings,
        pluginQuarantined: quarantined.isEmpty ? nil : quarantined
      ))
    }

    await stopRuntime()
    do {
      _ = try await startRuntime()
    } catch {
      return finish(UpgradeReport(
        fromReleaseID: fromID,
        toReleaseID: failedTarget,
        outcome: .aborted,
        summary: "新旧版本都起不来：\(failedTarget) \(reason)，回退到 \(fromID) 也失败。"
          + "请进入安全模式或干净环境。",
        bootFailure: bootFailure,
        checks: allChecks,
        notes: carriedNotes + ["回退启动失败：\(describe(error))", Self.markerKept],
        pluginPreflight: findings.isEmpty ? nil : findings,
        pluginQuarantined: quarantined.isEmpty ? nil : quarantined
      ))
    }

    pending.clear()
    // The count for the failed release deliberately stays. A rollback undoes the *switch*, not
    // the evidence: if this version is activated again — by the user, or by the next launch of
    // a half-finished upgrade — it should be met with the knowledge that it already failed
    // once, rather than starting from zero and going through the whole ladder again.
    return finish(UpgradeReport(
      fromReleaseID: fromID,
      toReleaseID: failedTarget,
      rolledBackTo: fromID,
      outcome: .rolledBack,
      summary: "\(failedTarget) \(reason)，已自动回退到 \(fromID)。"
        + (quarantined.isEmpty ? "" : "（隔离记录已保留：\(quarantined.joined(separator: ", "))）"),
      bootFailure: bootFailure,
      checks: allChecks,
      notes: carriedNotes,
      pluginPreflight: findings.isEmpty ? nil : findings,
      pluginQuarantined: quarantined.isEmpty ? nil : quarantined
    ))
  }

  // MARK: - Checks

  /// The boot result plus every check, in order.
  private func verify(announcedURL: String) async -> [HarnessCheckResult] {
    var results = [HarnessCheckResult(
      name: Self.bootCheckName,
      verdict: .pass,
      detail: announcedURL,
      isBlocking: true
    )]
    for check in await makeChecks(announcedURL) {
      progress("· \(check.name)")
      results.append(await check.run())
    }
    return results
  }

  private static func failedBootResult(_ detail: String) -> HarnessCheckResult {
    HarnessCheckResult(name: bootCheckName, verdict: .fail, detail: detail, isBlocking: true)
  }

  // MARK: - Reporting

  /// Persist and hand back. A report that cannot be written must not change the outcome —
  /// the upgrade already happened, and failing here would take a working runtime away from
  /// the user over a diagnostic file.
  private func finish(_ report: UpgradeReport) -> UpgradeReport {
    try? reports.save(report)
    progress(report.summary)
    return report
  }

  private func concernSuffix(_ checks: [HarnessCheckResult]) -> String {
    let concerns = checks.filter { $0.verdict == .fail || $0.verdict == .warn }
    guard !concerns.isEmpty else { return "" }
    return "（\(concerns.count) 项需注意：\(concerns.map { "\($0.name)=\($0.verdict.displayName)" }.joined(separator: ", "))）"
  }

  private static let markerKept =
    "回退点标记已保留，下次启动会继续处理。"

  /// Prefer the error's own description: the launcher puts the failing process's output in
  /// `RuntimeError.installFailed.detail`, and that text is the only thing that says *why*.
  private func describe(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
      return description
    }
    return String(describing: error)
  }
}
