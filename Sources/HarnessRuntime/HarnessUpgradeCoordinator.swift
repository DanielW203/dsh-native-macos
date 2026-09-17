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
  /// Single flight. Two windows can both press the button, and two upgrades interleaving
  /// their activation and their rollback would produce a state neither of them wrote.
  private var isRunning = false

  public init(
    paths: RuntimePaths,
    installer: HarnessInstaller,
    pending: PendingUpgradeStore? = nil,
    reports: UpgradeReportStore? = nil,
    profile: String,
    stopRuntime: @escaping RuntimeStopper,
    startRuntime: @escaping RuntimeStarter,
    currentRuntime: @escaping RuntimeProbe,
    makeChecks: @escaping CheckFactory,
    progress: @escaping ProgressReporter = { _ in }
  ) {
    self.paths = paths
    self.installer = installer
    self.pending = pending ?? PendingUpgradeStore(paths: paths)
    self.reports = reports ?? UpgradeReportStore(paths: paths)
    self.profile = profile
    self.stopRuntime = stopRuntime
    self.startRuntime = startRuntime
    self.currentRuntime = currentRuntime
    self.makeChecks = makeChecks
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
        summary: "激活 \(target) 失败，未启动；旧版本 \(fromID) 仍在：\(describe(error))"
      ))
    }

    pending.advance(to: .booting)
    progress("Restarting the harness on \(target)…")
    await stopRuntime()

    let announced: String
    do {
      let state = try await startRuntime()
      guard state.phase == .running, let url = state.url, !url.isEmpty else {
        throw RuntimeError.installFailed(
          step: "harness boot",
          detail: state.detail ?? "harness 未报告监听地址"
        )
      }
      announced = url
    } catch {
      let detail = describe(error)
      return await rollBack(
        from: fromID,
        failedTarget: target,
        bootFailure: detail,
        reason: "启动失败",
        checks: [Self.failedBootResult(detail)]
      )
    }

    progress("Checking the new runtime…")
    pending.advance(to: .verifying)
    let checks = await verify(announcedURL: announced)
    let blocking = checks.filter { $0.isBlocking && $0.verdict == .fail }
    guard blocking.isEmpty else {
      return await rollBack(
        from: fromID,
        failedTarget: target,
        bootFailure: nil,
        reason: "关键自检未通过（\(blocking.map(\.name).joined(separator: ", "))）",
        checks: checks
      )
    }

    pending.clear()
    return finish(UpgradeReport(
      fromReleaseID: fromID,
      toReleaseID: target,
      outcome: .kept,
      summary: "\(target) 已启用并通过自检\(concernSuffix(checks))",
      checks: checks
    ))
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

    guard let state = await currentRuntime(), state.phase == .running, let url = state.url, !url.isEmpty else {
      // The new release is active and did not come up. One rollback attempt, no loop.
      return await rollBack(
        from: record.fromReleaseID,
        failedTarget: record.toReleaseID,
        bootFailure: "升级后首次启动未成功（标记停在 \(record.stage.rawValue)）",
        reason: "启动失败",
        checks: []
      )
    }

    // Active and up, but never verified: verify now and roll back only if a blocking check
    // fails. A warning is not a reason to undo an upgrade the user already has.
    let checks = await verify(announcedURL: url)
    let blocking = checks.filter { $0.isBlocking && $0.verdict == .fail }
    guard blocking.isEmpty else {
      return await rollBack(
        from: record.fromReleaseID,
        failedTarget: record.toReleaseID,
        bootFailure: nil,
        reason: "关键自检未通过（\(blocking.map(\.name).joined(separator: ", "))）",
        checks: checks
      )
    }

    pending.clear()
    return finish(UpgradeReport(
      fromReleaseID: record.fromReleaseID,
      toReleaseID: record.toReleaseID,
      outcome: .kept,
      summary: "上次中断的升级已确认完成：\(record.toReleaseID) 自检通过\(concernSuffix(checks))",
      checks: checks
    ))
  }

  // MARK: - Rolling back

  /// Put `from` back and boot it. One attempt: a failed rollback is reported, never retried,
  /// because a loop here would oscillate between two runtimes neither of which works.
  private func rollBack(
    from fromID: String,
    failedTarget: String,
    bootFailure: String?,
    reason: String,
    checks: [HarnessCheckResult]
  ) async -> UpgradeReport {
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
        checks: checks,
        notes: [Self.markerKept]
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
        checks: checks,
        notes: ["回退启动失败：\(describe(error))", Self.markerKept]
      ))
    }

    pending.clear()
    return finish(UpgradeReport(
      fromReleaseID: fromID,
      toReleaseID: failedTarget,
      rolledBackTo: fromID,
      outcome: .rolledBack,
      summary: "\(failedTarget) \(reason)，已自动回退到 \(fromID)。",
      bootFailure: bootFailure,
      checks: checks
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
