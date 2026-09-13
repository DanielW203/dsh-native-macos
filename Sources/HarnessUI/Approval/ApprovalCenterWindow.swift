import AppKit
import Foundation
import HarnessIM
import HarnessKit
import SwiftUI

/// How the turn watcher is doing, for the notifications footer.
///
/// Kept as a value the view reads rather than a message it computes: "no stream available on this
/// harness" is a fact about the connection, and a view that worked it out itself would have to ask
/// the watcher on every render.
public enum TurnWatchState: Sendable, Equatable {
  case idle
  case watching
  case note(String)

  public var label: String? {
    switch self {
    case .idle: return nil
    case .watching: return "轮次通知已就绪"
    case .note(let text): return text
    }
  }
}

/// The approval model: one live subscription to the harness's forwarded-event stream, and
/// the decisions that come back out of it.
///
/// This is the app-level owner of the notification path. It is deliberately separate from
/// `HarnessIM.PromptRelay` (which answers for a *chat* sender): both may be subscribed at
/// the same time, and only a human action here ever produces an outcome. When the browser
/// answers first, the answer from here fails, and that failure is reported as "already
/// handled" rather than retried.
@MainActor
public final class ApprovalAlertModel: ObservableObject {
  public enum Connection: Equatable, Sendable {
    case idle
    case connecting
    case live
    case retrying(String)
  }

  /// How a `$events` stream is built from an authenticated client. A seam so a test can
  /// drive the model from a scripted stream instead of a WebSocket.
  public typealias StreamFactory = @Sendable (HarnessAPIClient) async throws -> any RemoteEventStreaming

  @Published public private(set) var alerts: [ApprovalAlert] = []
  @Published public private(set) var connection: Connection = .idle
  @Published public private(set) var notice: String?
  @Published public private(set) var authorization: ApprovalNotificationAuthorization = .notDetermined
  @Published public private(set) var lastError: String?
  @Published public var notificationsEnabled: Bool {
    didSet { defaults.set(notificationsEnabled, forKey: Self.notificationsDefaultsKey) }
  }
  @Published public var floatingPanelEnabled: Bool {
    didSet { defaults.set(floatingPanelEnabled, forKey: Self.floatingPanelDefaultsKey) }
  }
  /// Announce turns that finished.
  @Published public var turnCompletionEnabled: Bool {
    didSet {
      defaults.set(turnCompletionEnabled, forKey: Self.turnCompletionDefaultsKey)
      pushTargetsToWatcher()
    }
  }
  /// Announce turns that failed.
  ///
  /// Separate from the completion switch because the two answer different questions: "tell me when
  /// it is done" and "tell me when it broke". A user who leaves the app running unattended wants
  /// the second and may not want the first.
  @Published public var turnFailureEnabled: Bool {
    didSet {
      defaults.set(turnFailureEnabled, forKey: Self.turnFailureDefaultsKey)
      pushTargetsToWatcher()
    }
  }
  /// Include subagent sessions in those announcements. Off by default: a turn that spawns three
  /// subagents would otherwise produce three extra notifications nobody asked for.
  @Published public var subagentNotificationsEnabled: Bool {
    didSet {
      defaults.set(subagentNotificationsEnabled, forKey: Self.subagentDefaultsKey)
      pushTargetsToWatcher()
    }
  }
  /// How the turn watcher is doing, for the footer.
  @Published public private(set) var turnWatch: TurnWatchState = .idle

  /// Called when the user asks to see an approval in the app (notification body click).
  public var onOpenAlert: ((String) -> Void)?

  public static let notificationsDefaultsKey = "NativeHarness.approval.notifications"
  public static let floatingPanelDefaultsKey = "NativeHarness.approval.floatingPanel"
  public static let turnCompletionDefaultsKey = "NativeHarness.notify.turnCompletion"
  public static let turnFailureDefaultsKey = "NativeHarness.notify.turnFailure"
  public static let subagentDefaultsKey = "NativeHarness.notify.subagents"

  /// The running harness's token-bearing URL, or nil while it is down. Read through a
  /// closure rather than observed: the app owns that value on the main actor and
  /// `refreshConnection()` is the only moment this model needs it.
  private let urlProvider: @Sendable () -> URL?
  private let transport: HarnessAPITransport
  private let defaults: UserDefaults
  private let presenter: any ApprovalPresenting
  private let streamFactory: StreamFactory
  private let isAppActive: @MainActor () -> Bool

  private var center: ApprovalAlertCenter?
  private var retryTask: Task<Void, Never>?
  private var backoff: TimeInterval = ApprovalAlertModel.initialBackoff

  /// The last session list read from the harness, kept so a switch change can re-apply it without
  /// waiting for the next poll.
  private var watchTargets: [TurnCompletionWatcher.WatchTarget] = []
  private var turnWatcher: TurnCompletionWatcher?
  /// The authenticated client the watcher's sockets are built from. Held so a target change does
  /// not have to re-authenticate against a single-use launch token, and so the session list can be
  /// re-read on its own schedule.
  private var watchClient: HarnessAPIClient?
  /// Re-reads the session list while the watcher is running.
  private var sessionPollTask: Task<Void, Never>?

  /// How often the watched session list is refreshed.
  ///
  /// The watcher only needs this to know *which* sessions to follow; the endings themselves arrive
  /// on the streams. Thirty seconds is short enough that a new session is picked up well within a
  /// turn, and long enough that the poll is invisible.
  static let sessionPollInterval: TimeInterval = 30

  static let initialBackoff: TimeInterval = 1
  static let maximumBackoff: TimeInterval = 60

  public init(
    urlProvider: @escaping @Sendable () -> URL?,
    defaults: UserDefaults = .standard,
    transport: HarnessAPITransport = URLSessionHarnessTransport(),
    presenter: any ApprovalPresenting,
    streamFactory: @escaping StreamFactory = { try $0.makeRemoteEventStream() },
    isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
  ) {
    self.urlProvider = urlProvider
    self.transport = transport
    self.defaults = defaults
    self.presenter = presenter
    self.streamFactory = streamFactory
    self.isAppActive = isAppActive
    self.notificationsEnabled = defaults.object(forKey: Self.notificationsDefaultsKey) as? Bool ?? true
    self.floatingPanelEnabled = defaults.object(forKey: Self.floatingPanelDefaultsKey) as? Bool ?? true
    self.turnCompletionEnabled = defaults.object(forKey: Self.turnCompletionDefaultsKey) as? Bool ?? true
    self.turnFailureEnabled = defaults.object(forKey: Self.turnFailureDefaultsKey) as? Bool ?? true
    self.subagentNotificationsEnabled = defaults.object(forKey: Self.subagentDefaultsKey) as? Bool ?? false
    self.authorization = presenter.authorization
    self.presenter.onDecision = { [weak self] eventID, decision in
      self?.handlePresentedDecision(eventID: eventID, decision: decision)
    }
    self.presenter.onOpenRequested = { [weak self] eventID in
      self?.onOpenAlert?(eventID)
    }
  }

  deinit {
    retryTask?.cancel()
  }

  // MARK: Derived state

  public var pending: [ApprovalAlert] { alerts.filter { $0.state == .pending } }

  public var connectionLabel: String {
    switch connection {
    case .idle: return "未连接（harness 未运行）"
    case .connecting: return "正在连接事件流…"
    case .live: return "已连接事件流"
    case .retrying(let detail): return detail
    }
  }

  public var statusSymbol: String {
    switch connection {
    case .live: return "checkmark.circle.fill"
    case .idle: return "circle.dashed"
    case .connecting, .retrying: return "arrow.triangle.2.circlepath"
    }
  }

  // MARK: Lifecycle

  /// Push the current target list to the watcher.
  ///
  /// Called when the switches change and on every poll. The list itself is read from the harness, so
  /// there is no caller-supplied list to reconcile — a second source would only give two answers to
  /// the same question.
  private func pushTargetsToWatcher() {
    guard let turnWatcher else { return }
    let targets = watchTargets
    let includeSubagents = subagentNotificationsEnabled
    Task { await turnWatcher.setTargets(targets, includeSubagents: includeSubagents) }
  }

  /// Start watching turn endings on the connection that just authenticated.
  ///
  /// A second stream over the same client, deliberately: approvals arrive on the host's forwarded
  /// event stream and turn endings do not — `$events` forwards only the names the host selects — so
  /// endings have to be read from `session/follow` per session.
  private func startTurnWatcher(client: HarnessAPIClient) async {
    await stopTurnWatcher()
    guard let muxURL = client.muxWebSocketURL else {
      turnWatch = .note("无法构造会话流地址")
      return
    }
    let cookie = await client.sessionCookie
    let watcher = TurnCompletionWatcher(
      followerFactory: { _ in
        HarnessSessionFollower(webSocketURL: muxURL, cookie: cookie)
      },
      onCompletion: { [weak self] completion in
        await self?.deliver(completion)
      }
    )
    watchClient = client
    turnWatcher = watcher
    turnWatch = .watching
    pushTargetsToWatcher()
    startSessionPoll(on: client)
  }

  /// Keep the watched-session set in step with the harness.
  ///
  /// The list is read from the harness rather than handed in by a view on purpose: a turn ending is
  /// a fact about the *harness's* sessions, and the app's own session list is a different thing that
  /// can be filtered, paged, or pointed at another engine. Reading it here also means the feature
  /// works with no view on screen, which is exactly when a notification matters most.
  private func startSessionPoll(on client: HarnessAPIClient) {
    sessionPollTask?.cancel()
    sessionPollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let watcher = self.turnWatcher else { return }
        do {
          let sessions = try await client.listSessions()
          let targets = sessions.map { summary in
            TurnCompletionWatcher.WatchTarget(
              sessionID: summary.id.description,
              title: summary.title,
              // A child session is one the harness recorded with a parent. `delegationDepth` is the
              // other available signal, and either is enough to keep a subagent out of the default
              // notification set.
              isSubagent: summary.parentID != nil || (summary.delegationDepth ?? 0) > 0,
              updatedAt: summary.updatedAt
            )
          }
          self.watchTargets = targets
          await watcher.setTargets(targets, includeSubagents: self.subagentNotificationsEnabled)
        } catch {
          // A poll that fails is not worth reporting: the watcher's own streams are the feature, and
          // the list is only how it chooses targets. It will be re-read on the next tick.
        }
        // Outside the do/catch on purpose: whether the *streams* are available is a separate fact
        // from whether this poll succeeded, and a list failure that hid the "this harness has no
        // session stream" note would leave the user with silently missing notifications.
        await self.noteTurnWatchAvailability()
        try? await Task.sleep(nanoseconds: UInt64(Self.sessionPollInterval * 1_000_000_000))
      }
    }
  }

  private func stopTurnWatcher() async {
    sessionPollTask?.cancel()
    sessionPollTask = nil
    if let turnWatcher { await turnWatcher.stop() }
    turnWatcher = nil
    watchClient = nil
    turnWatch = .idle
  }

  /// Report one turn ending, subject to the switches.
  ///
  /// The master switch gates everything, so turning notifications off really means off rather than
  /// leaving a second path alive. `deservesNotification` has already removed the endings that are
  /// not news (the user's own stop, a recovery artifact).
  func deliver(_ completion: TurnCompletion) async {
    guard notificationsEnabled else { return }
    if completion.isSubagent && !subagentNotificationsEnabled { return }
    if completion.kind.isFailure {
      guard turnFailureEnabled else { return }
    } else if completion.kind.isCompletion {
      guard turnCompletionEnabled else { return }
    } else {
      return
    }
    presenter.postTurnCompletion(completion)
  }

  /// Reflect a watcher that cannot follow this harness, so the footer can say so instead of leaving
  /// the user wondering why endings are silent.
  private func noteTurnWatchAvailability() async {
    guard let turnWatcher else { return }
    if await turnWatcher.hasUnavailableSubscription {
      turnWatch = .note("本版本 harness 不提供会话流，轮次通知不可用")
    } else {
      turnWatch = .watching
    }
  }

  /// Connect when the harness is up, disconnect when it is not. Safe to call repeatedly —
  /// the app calls it on every URL change.
  public func refreshConnection() async {
    guard let url = urlProvider() else {
      await teardown(clearAlerts: true)
      connection = .idle
      return
    }
    guard center == nil else { return }

    retryTask?.cancel()
    retryTask = nil
    connection = .connecting
    lastError = nil
    do {
      let parsed = try HarnessAPIClient.parse(authenticatedURL: url)
      let client = HarnessAPIClient(baseURL: parsed.origin, transport: transport)
      try await client.authenticate(token: parsed.token)
      let stream = try await streamFactory(client)
      let center = ApprovalAlertCenter(
        stream: stream,
        onAlert: { [weak self] alert in
          await self?.receive(alert)
        },
        onWithdraw: { [weak self] eventID in
          await self?.withdraw(eventID: eventID)
        }
      )
      self.center = center
      connection = .live
      backoff = Self.initialBackoff
      await startTurnWatcher(client: client)
      Task { [weak self] in
        await center.run()
        await self?.streamEnded()
      }
    } catch {
      self.center = nil
      let detail = (error as? HarnessAPIError)?.message ?? error.localizedDescription
      lastError = detail
      scheduleRetry(reason: "连接失败：\(detail)")
    }
  }

  /// The stream ended on its own (harness restarted, socket dropped). Reconnect with a
  /// bounded backoff — the same shape the chat channel uses, so a flapping harness cannot
  /// turn into a busy loop.
  private func streamEnded() async {
    guard center != nil else { return }
    center = nil
    if urlProvider() == nil {
      await teardown(clearAlerts: true)
      connection = .idle
      return
    }
    scheduleRetry(reason: "事件流已断开，正在重试")
  }

  private func scheduleRetry(reason: String) {
    connection = .retrying(reason)
    retryTask?.cancel()
    let delay = backoff
    backoff = min(backoff * 2, Self.maximumBackoff)
    retryTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.refreshConnection()
    }
  }

  private func teardown(clearAlerts: Bool) async {
    retryTask?.cancel()
    retryTask = nil
    await stopTurnWatcher()
    if let center {
      self.center = nil
      await center.stop()
    }
    presenter.withdrawAll()
    if clearAlerts { alerts.removeAll() }
    presenter.syncPanel([])
  }

  // MARK: Incoming

  private func receive(_ alert: ApprovalAlert) async {
    // A reconnect re-delivers whatever is still pending; one card per request id.
    if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
      alerts[index].state = .pending
      alerts[index].receivedAt = alert.receivedAt
    } else {
      alerts.append(alert)
    }
    alerts.sort { $0.receivedAt < $1.receivedAt }
    // The two surfaces are decided separately: "notifications off" must mean no
    // notification, not "no way to answer while the app is hidden".
    let background = !isAppActive()
    if notificationsEnabled {
      let status = await presenter.ensureAuthorization()
      authorization = status
      presenter.post(alert, sound: background)
    }
    presenter.syncPanel(pending)
    // The panel is for the case where the Web UI's own sheet is not on screen; when the
    // app is in front, that sheet is already showing this request.
    presenter.setPanelVisible(floatingPanelEnabled && background)
  }

  private func withdraw(eventID: String) {
    alerts.removeAll { $0.id == eventID }
    presenter.withdraw(eventID)
    presenter.syncPanel(pending)
  }

  // MARK: Answering

  /// Answer one alert. Called by the window's buttons, by a notification action, and by
  /// the floating panel — all three go through this one path.
  public func decide(_ alert: ApprovalAlert, decision: HarnessIM.ApprovalDecision) async {
    guard let center else {
      notice = "事件流未连接，无法答复。"
      return
    }
    do {
      try await center.answer(eventID: alert.id, decision: decision)
      if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
        alerts[index].state = .answered(decision)
      }
      presenter.withdraw(alert.id)
      presenter.syncPanel(pending)
      notice = "已\(decision == .allowedOnce ? "批准" : "拒绝") \(alert.toolName)。"
      lastError = nil
      // Answered alerts are no longer actionable; drop them once settled so the window
      // keeps showing only what still needs a person.
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        self?.alerts.removeAll { $0.id == alert.id }
        self?.presenter.syncPanel(self?.pending ?? [])
      }
    } catch {
      let detail = (error as? HarnessAPIError)?.message ?? error.localizedDescription
      // The overwhelmingly likely cause is another client answering first — the browser
      // sheet, or the chat channel. The request is gone either way, so the alert is
      // removed rather than left as a button that can only fail again.
      alerts.removeAll { $0.id == alert.id }
      presenter.withdraw(alert.id)
      presenter.syncPanel(pending)
      notice = "这条审批已经无法答复（可能已在浏览器或微信里处理）。"
      lastError = detail
    }
  }

  /// A decision arrived from a notification action or the panel.
  private func handlePresentedDecision(eventID: String, decision: HarnessIM.ApprovalDecision) {
    guard let alert = alerts.first(where: { $0.id == eventID }) else {
      // The alert is gone (already answered, or withdrawn while the banner was up): make
      // sure the stale banner disappears too.
      presenter.withdraw(eventID)
      return
    }
    Task { await decide(alert, decision: decision) }
  }

  // MARK: Manual controls

  /// Ask the system for permission now, from the window's button.
  public func requestNotificationAuthorization() async {
    authorization = await presenter.ensureAuthorization()
    if authorization == .denied {
      notice = "系统通知被拒绝，可在「系统设置 → 通知 → DSH Native」里打开。"
    }
  }

  public func dismissAlert(_ alert: ApprovalAlert) {
    alerts.removeAll { $0.id == alert.id }
    presenter.withdraw(alert.id)
    presenter.syncPanel(pending)
  }
}

// MARK: - Window

/// The approval centre: everything the harness is waiting on, and the two switches that
/// control how it reaches the user when the window is not in front.
public struct ApprovalCenterWindow: View {
  @ObservedObject private var model: ApprovalAlertModel

  public init(model: ApprovalAlertModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(minWidth: 620, minHeight: 460)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: model.statusSymbol)
          .foregroundStyle(model.connection == .live ? Color.green : Color.secondary)
        Text(model.connectionLabel).font(.callout)
        Spacer()
        Text("待审批 \(model.pending.count)").font(.callout.weight(.semibold))
      }
      Text("离开窗口也能批准：审批到达时会发系统通知，通知上可以直接「批准 / 拒绝」；"
           + "窗口不在前台时还会弹一个悬浮面板。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(14)
  }

  @ViewBuilder
  private var content: some View {
    if model.alerts.isEmpty {
      VStack(spacing: 6) {
        Text("没有待处理的审批").font(.callout)
        Text("harness 需要你确认某个工具调用时，这里会出现它。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(model.alerts) { alert in
            card(alert)
          }
        }
        .padding(14)
      }
    }
  }

  private func card(_ alert: ApprovalAlert) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        Text(alert.toolName).font(.callout.weight(.semibold))
        if case .answered(let decision) = alert.state {
          Text(decision.chineseLabel)
            .font(.caption2)
            .foregroundStyle(.green)
        }
        Spacer()
        Text(alert.receivedAt, style: .time)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Text(alert.detail).font(.caption).foregroundStyle(.secondary)
      if let callId = alert.callId {
        Text(callId).font(.caption2.monospaced()).foregroundStyle(.tertiary)
      }
      Text(alert.sessionID)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 8) {
        Button("批准（仅这一次）") {
          Task { await model.decide(alert, decision: .allowedOnce) }
        }
        .disabled(alert.state != .pending)
        Button("拒绝") {
          Task { await model.decide(alert, decision: .rejected) }
        }
        .disabled(alert.state != .pending)
        Spacer()
        Button("忽略") { model.dismissAlert(alert) }
          .buttonStyle(.link)
      }
    }
    .padding(12)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 14) {
        Toggle("系统通知", isOn: $model.notificationsEnabled)
          .toggleStyle(.checkbox)
        Toggle("悬浮审批面板", isOn: $model.floatingPanelEnabled)
          .toggleStyle(.checkbox)
        Spacer()
      }
      // The per-event switches. Disabled rather than hidden while the master switch is off, so the
      // settings stay legible and it is obvious which one is doing the silencing.
      HStack(spacing: 14) {
        Toggle("轮次完成", isOn: $model.turnCompletionEnabled)
          .toggleStyle(.checkbox)
          .disabled(!model.notificationsEnabled)
          .help("会话完成一个轮次时通知，包括因达到 token 上限而结束的轮次")
        Toggle("轮次失败", isOn: $model.turnFailureEnabled)
          .toggleStyle(.checkbox)
          .disabled(!model.notificationsEnabled)
          .help("轮次以错误结束或被阻断时通知。用户自己停止的轮次不会通知。")
        Toggle("含子代理", isOn: $model.subagentNotificationsEnabled)
          .toggleStyle(.checkbox)
          .disabled(!model.notificationsEnabled)
          .help("把子代理会话的轮次结束也算进来。默认关闭，避免一次任务刷出多条通知。")
        Spacer()
      }
      if let label = model.turnWatch.label {
        HStack(spacing: 6) {
          Image(systemName: model.turnWatch == .watching ? "dot.radiowaves.left.and.right" : "info.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(label).font(.caption2).foregroundStyle(.secondary)
          Spacer()
        }
      }
      HStack(spacing: 8) {
        Text("通知权限：\(model.authorization.label)")
          .font(.caption)
          .foregroundStyle(.secondary)
        if model.authorization != .authorized {
          Button("启用系统通知…") {
            Task { await model.requestNotificationAuthorization() }
          }
          .buttonStyle(.link)
          .font(.caption)
        }
        Spacer()
      }
      if let notice = model.notice {
        Text(notice).font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.lastError {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
    .padding(14)
  }
}
