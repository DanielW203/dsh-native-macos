import AppKit
import Foundation
import HarnessIM
import HarnessKit
import SwiftUI
import UserNotifications

/// Whether macOS will let this app show notifications at all.
///
/// `unavailable` is a real state, not a placeholder: a process with no bundle identifier
/// (a SwiftPM test runner, the CLI) cannot talk to `UNUserNotificationCenter` at all, and
/// that is the one case where the floating panel is the only way an approval can reach
/// someone who is looking at another application.
public enum ApprovalNotificationAuthorization: String, Sendable, Equatable {
  case notDetermined
  case authorized
  case denied
  case unavailable

  public var label: String {
    switch self {
    case .notDetermined: return "尚未请求"
    case .authorized: return "已允许"
    case .denied: return "已被系统拒绝"
    case .unavailable: return "当前进程不支持系统通知"
    }
  }
}

/// Where an approval is shown.
///
/// A protocol rather than a class because the notification centre cannot be exercised in
/// a test process (no bundle, no user to click Allow), and because the panel/notification
/// pair is exactly the part that must be substitutable when the app runs inside a test
/// runner.
@MainActor
public protocol ApprovalPresenting: AnyObject {
  /// A decision came from a notification action or the floating panel.
  var onDecision: ((String, HarnessIM.ApprovalDecision) -> Void)? { get set }
  /// The user asked to see the approval in the app (clicked the notification body).
  var onOpenRequested: ((String) -> Void)? { get set }

  var authorization: ApprovalNotificationAuthorization { get }

  /// Ask the system once, and report what it answered.
  @discardableResult
  func ensureAuthorization() async -> ApprovalNotificationAuthorization
  /// Post one system notification. Kept separate from the panel so "notifications off"
  /// really means no notification, while the panel — the last resort when the app is in
  /// the background — still works.
  func post(_ alert: ApprovalAlert, sound: Bool)
  /// Show or hide the floating panel. The panel's *contents* come from `syncPanel`.
  func setPanelVisible(_ visible: Bool)
  /// The harness withdrew the request, or it was answered elsewhere.
  func withdraw(_ eventID: String)
  func withdrawAll()
  /// Mirror the currently pending alerts into the floating panel.
  func syncPanel(_ alerts: [ApprovalAlert])
  /// Post one turn-completion notification.
  ///
  /// A separate call rather than a reuse of `post` because the two notifications differ in the one
  /// way that matters: an approval asks a question and needs action buttons that answer it, while a
  /// turn ending only reports. Folding them together would put Approve/Reject on a message that has
  /// nothing to approve.
  func postTurnCompletion(_ completion: TurnCompletion)
}

// MARK: - Recording presenter

/// An `ApprovalPresenting` that shows nothing and remembers everything.
///
/// Used by the tests, and by the app when it is running outside a bundle (where the
/// notification centre is not reachable): the approval centre window still lists the
/// requests, so nothing is lost, and no code has to special-case "no notifications" at
/// the call sites.
@MainActor
public final class RecordingApprovalPresenter: ApprovalPresenting {
  public var onDecision: ((String, HarnessIM.ApprovalDecision) -> Void)?
  public var onOpenRequested: ((String) -> Void)?

  public private(set) var posted: [ApprovalAlert] = []
  /// Every `post` call with the flags it was made with, so a test can assert the
  /// background-only rules (sound) rather than just the content.
  public private(set) var posts: [(alert: ApprovalAlert, sound: Bool)] = []
  /// Every `setPanelVisible` call, in order.
  public private(set) var panelVisibility: [Bool] = []
  public private(set) var withdrawn: [String] = []
  public private(set) var panels: [[ApprovalAlert]] = []
  /// Every turn-completion notification, in order — the record the switch tests assert on.
  public private(set) var turnCompletions: [TurnCompletion] = []
  public private(set) var authorization: ApprovalNotificationAuthorization

  /// What `ensureAuthorization()` should answer. `.authorized` by default so a test that
  /// does not care about permission still exercises the notification path.
  public var stubbedAuthorization: ApprovalNotificationAuthorization

  public init(authorization: ApprovalNotificationAuthorization = .unavailable) {
    self.authorization = authorization
    self.stubbedAuthorization = authorization
  }

  @discardableResult
  public func ensureAuthorization() async -> ApprovalNotificationAuthorization {
    authorization = stubbedAuthorization
    return authorization
  }

  public func post(_ alert: ApprovalAlert, sound: Bool) {
    posted.append(alert)
    posts.append((alert, sound))
  }

  public func setPanelVisible(_ visible: Bool) {
    panelVisibility.append(visible)
  }

  public func withdraw(_ eventID: String) {
    withdrawn.append(eventID)
  }

  public func withdrawAll() {
    withdrawn.append(contentsOf: posted.map(\.id))
    posted.removeAll()
    posts.removeAll()
  }

  public func syncPanel(_ alerts: [ApprovalAlert]) {
    panels.append(alerts)
  }

  /// Records the completion rather than showing it: a test asserts on what would have been
  /// announced, not on the notification centre.
  public func postTurnCompletion(_ completion: TurnCompletion) {
    turnCompletions.append(completion)
  }
}

// MARK: - System presenter

/// System notifications with Approve/Reject actions, plus the floating panel.
///
/// Both surfaces answer through the same `onDecision`, so a decision made from a
/// notification banner and one made from the panel are indistinguishable to the caller.
@MainActor
public final class SystemApprovalPresenter: ApprovalPresenting {
  /// One category for every approval: the actions are the same two outcomes the harness
  /// accepts, and nothing about them varies per tool.
  ///
  /// `nonisolated` because the notification delegate reads them from outside the main
  /// actor; the values are immutable strings, so there is nothing to protect.
  public nonisolated static let categoryIdentifier = "harness.approval"
  public nonisolated static let approveAction = "harness.approve"
  public nonisolated static let rejectAction = "harness.reject"
  nonisolated static let eventIDKey = "harnessEventID"
  /// Its own category, with no actions: a turn ending has nothing to answer, so it must not present
  /// Approve/Reject. Registering it separately is also what lets a user silence endings in System
  /// Settings without silencing approvals.
  public nonisolated static let turnCategoryIdentifier = "harness.turn"
  nonisolated static let turnSessionKey = "harnessTurnSessionID"

  public var onDecision: ((String, HarnessIM.ApprovalDecision) -> Void)?
  public var onOpenRequested: ((String) -> Void)?

  public private(set) var authorization: ApprovalNotificationAuthorization = .notDetermined

  private let center: UNUserNotificationCenter?
  private let panel: FloatingApprovalPanelController?
  private let responseDelegate: NotificationResponseDelegate?
  private var activationObserver: NSObjectProtocol?
  private var terminationObserver: NSObjectProtocol?

  /// - Parameters:
  ///   - usesPanel: whether a floating panel may be created. False in a test runner,
  ///     where AppKit has no application to attach a panel to.
  public init(usesPanel: Bool = true) {
    var resolvedCenter: UNUserNotificationCenter?
    var resolvedDelegate: NotificationResponseDelegate?
    var resolvedAuthorization: ApprovalNotificationAuthorization = .notDetermined
    // `UNUserNotificationCenter.current()` traps when the process has no bundle: a bare
    // executable or the SwiftPM test runner. The bundle identifier is the cheapest honest
    // test for "this is an app".
    if Bundle.main.bundleIdentifier != nil {
      let center = UNUserNotificationCenter.current()
      let delegate = NotificationResponseDelegate()
      resolvedCenter = center
      resolvedDelegate = delegate
      center.delegate = delegate
      Self.registerCategories(on: center)
    } else {
      resolvedAuthorization = .unavailable
    }

    // Everything is assembled in locals first: reading an own property before `self` is
    // fully initialized is what the compiler refuses, and rightly so.
    let panel = usesPanel ? FloatingApprovalPanelController() : nil
    self.center = resolvedCenter
    self.responseDelegate = resolvedDelegate
    self.authorization = resolvedAuthorization
    self.panel = panel
    self.activationObserver = nil
    self.terminationObserver = nil

    resolvedDelegate?.handleDecision = { [weak self] eventID, decision in
      Task { @MainActor in self?.onDecision?(eventID, decision) }
    }
    resolvedDelegate?.handleOpen = { [weak self] eventID in
      Task { @MainActor in self?.onOpenRequested?(eventID) }
    }
    panel?.state.onDecision = { [weak self] eventID, decision in
      self?.onDecision?(eventID, decision)
    }
    // The panel exists for the case where the app is *not* in front; once the user comes
    // back to the app, the Web UI's own sheet is the better surface and a floating
    // duplicate would just sit on top of it.
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.hidePanel() }
    }
    // A banner left in Notification Center after the app is gone is a dead button: the
    // request it belongs to dies with the harness the app was hosting.
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.withdrawAll() }
    }
  }

  deinit {
    if let activationObserver {
      NotificationCenter.default.removeObserver(activationObserver)
    }
    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
    }
  }

  private static func registerCategories(on center: UNUserNotificationCenter) {
    let approve = UNNotificationAction(
      identifier: approveAction,
      title: "批准（仅这一次）",
      options: []
    )
    let reject = UNNotificationAction(
      identifier: rejectAction,
      title: "拒绝",
      options: [.destructive]
    )
    let category = UNNotificationCategory(
      identifier: categoryIdentifier,
      actions: [approve, reject],
      intentIdentifiers: [],
      options: []
    )
    // No actions on purpose: a turn ending is a report, and offering Approve on it would be an
    // answer to a question nobody asked.
    let turnCategory = UNNotificationCategory(
      identifier: turnCategoryIdentifier,
      actions: [],
      intentIdentifiers: [],
      options: []
    )
    center.setNotificationCategories([category, turnCategory])
  }

  // MARK: Authorization

  @discardableResult
  public func ensureAuthorization() async -> ApprovalNotificationAuthorization {
    guard let center else {
      authorization = .unavailable
      return authorization
    }
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      // Re-registering is harmless and repairs a category removed by an OS update.
      Self.registerCategories(on: center)
      authorization = .authorized
    case .denied:
      authorization = .denied
    case .notDetermined:
      do {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        authorization = granted ? .authorized : .denied
      } catch {
        authorization = .denied
      }
    @unknown default:
      authorization = .denied
    }
    return authorization
  }

  // MARK: Presentation

  public func setPanelVisible(_ visible: Bool) {
    guard let panel else { return }
    if visible {
      panel.show()
    } else {
      panel.hide()
    }
  }

  public func post(_ alert: ApprovalAlert, sound: Bool) {
    if let center, authorization == .authorized || authorization == .notDetermined {
      let content = UNMutableNotificationContent()
      content.title = "harness 需要批准"
      content.subtitle = alert.toolName
      content.body = alert.detail
      content.categoryIdentifier = Self.categoryIdentifier
      content.threadIdentifier = alert.sessionID
      content.userInfo = [
        Self.eventIDKey: alert.id,
        "sessionID": alert.sessionID,
      ]
      if sound { content.sound = .default }
      // `nil` trigger delivers immediately. `interruptionLevel` stays `.active`: the
      // time-sensitive level needs an entitlement this ad-hoc-signed build does not
      // carry, and asking for it would silently downgrade anyway.
      let request = UNNotificationRequest(
        identifier: Self.notificationIdentifier(for: alert.id),
        content: content,
        trigger: nil
      )
      center.add(request, withCompletionHandler: nil)
    }
    if !NSApp.isActive {
      // The notification may be missed entirely (Focus, a hidden banner); this is the
      // one signal that survives every notification setting.
      NSApp.requestUserAttention(.informationalRequest)
    }
  }

  /// Post one turn-completion notification.
  ///
  /// Silent when notification permission is not granted, exactly like an approval — the difference
  /// is that this path has no floating panel to fall back on, because a turn that finished does not
  /// need the user to do anything.
  public func postTurnCompletion(_ completion: TurnCompletion) {
    guard let center, authorization == .authorized || authorization == .notDetermined else { return }
    let content = UNMutableNotificationContent()
    content.title = Self.title(for: completion)
    if let title = completion.sessionTitle, !title.isEmpty {
      content.subtitle = title
    } else {
      content.subtitle = completion.sessionID
    }
    content.body = Self.body(for: completion)
    content.categoryIdentifier = Self.turnCategoryIdentifier
    content.threadIdentifier = completion.sessionID
    content.userInfo = [Self.turnSessionKey: completion.sessionID]
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: Self.turnNotificationIdentifier(for: completion),
      content: content,
      trigger: nil
    )
    center.add(request, withCompletionHandler: nil)
  }

  /// One line naming what happened, in the vocabulary the classification uses.
  static func title(for completion: TurnCompletion) -> String {
    switch completion.kind {
    case .completed: return "轮次完成"
    case .maxTokens: return "轮次结束（达到 token 上限）"
    case .error: return "轮次失败"
    case .blocked: return "轮次被阻断"
    case .aborted, .interrupted, .unknown:
      // Unreachable in practice: the model filters these out before posting. Named anyway so a
      // future caller that forgets the filter gets a truthful line rather than nothing.
      return "轮次结束"
    }
  }

  /// The failure detail when there is one, otherwise the turn number.
  static func body(for completion: TurnCompletion) -> String {
    if let message = completion.failureMessage, !message.isEmpty {
      return completion.failureCode.map { "[\($0)] \(message)" } ?? message
    }
    if let code = completion.failureCode { return code }
    guard let turn = completion.turn else { return "会话已结束一个轮次" }
    return "第 \(turn) 轮"
  }

  /// Identifier for one ending.
  ///
  /// Keyed by session and turn so a session that finishes several turns in a row stacks several
  /// notifications rather than replacing one — each turn is its own piece of news. `interrupted`
  /// and `unknown` share a slot because they carry no turn number worth distinguishing.
  static func turnNotificationIdentifier(for completion: TurnCompletion) -> String {
    let turn = completion.turn.map(String.init) ?? "unknown"
    return "harness.turn.\(completion.sessionID).\(turn)"
  }


  public func withdraw(_ eventID: String) {
    center?.removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier(for: eventID)])
    center?.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier(for: eventID)])
    if let panel {
      panel.state.alerts.removeAll { $0.id == eventID }
      if panel.state.alerts.isEmpty { hidePanel() }
    }
  }

  public func withdrawAll() {
    center?.removeAllDeliveredNotifications()
    center?.removeAllPendingNotificationRequests()
    panel?.state.alerts.removeAll()
    hidePanel()
  }

  public func syncPanel(_ alerts: [ApprovalAlert]) {
    guard let panel else { return }
    panel.state.alerts = alerts
    if alerts.isEmpty {
      hidePanel()
    }
  }

  private func hidePanel() {
    panel?.hide()
  }

  /// One notification per request id, so a reconnect that re-delivers the same waterfall
  /// replaces the banner instead of stacking a second one.
  static func notificationIdentifier(for eventID: String) -> String {
    "harness.approval.\(eventID)"
  }
}

// MARK: - Notification delegate

/// The notification centre's delegate, kept out of the presenter's actor isolation.
///
/// `UNUserNotificationCenterDelegate`'s methods are not main-actor isolated, so forwarding
/// through two `@Sendable` closures and hopping back with `Task { @MainActor in … }` is
/// what keeps the presenter itself a plain main-actor class.
final class NotificationResponseDelegate: NSObject, UNUserNotificationCenterDelegate {
  var handleDecision: (@Sendable (String, HarnessIM.ApprovalDecision) -> Void)?
  var handleOpen: (@Sendable (String) -> Void)?

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    // Without `.banner` a notification posted while the app is frontmost is dropped on
    // the floor, which would make "总是发通知" untrue exactly when the user asked for it.
    [.banner, .list, .sound]
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    guard let eventID = info[SystemApprovalPresenter.eventIDKey] as? String else { return }
    switch response.actionIdentifier {
    case SystemApprovalPresenter.approveAction:
      handleDecision?(eventID, .allowedOnce)
    case SystemApprovalPresenter.rejectAction:
      handleDecision?(eventID, .rejected)
    case UNNotificationDefaultActionIdentifier:
      handleOpen?(eventID)
    default:
      // A dismissal is not a decision: the request is still waiting in the harness.
      break
    }
  }
}

// MARK: - Floating panel

/// The panel's observable state, shared between the controller and its SwiftUI content.
@MainActor
final class ApprovalPanelState: ObservableObject {
  @Published var alerts: [ApprovalAlert] = []
  var onDecision: ((String, HarnessIM.ApprovalDecision) -> Void)?
}

/// A non-activating floating panel that can be answered without leaving the current app.
///
/// `.nonactivatingPanel` is the whole point: clicking Approve must not drag the user away
/// from whatever they were doing, and `canJoinAllSpaces` means the panel follows them to
/// the space they are actually on rather than waiting on the one the app was launched in.
@MainActor
final class FloatingApprovalPanelController {
  let state = ApprovalPanelState()
  private var panel: NSPanel?

  func show() {
    let panel = existingOrNewPanel()
    if !panel.isVisible { position(panel) }
    panel.orderFrontRegardless()
  }

  func hide() {
    panel?.orderOut(nil)
  }

  private func existingOrNewPanel() -> NSPanel {
    if let panel { return panel }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
      styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.title = "待审批"
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: ApprovalPromptView(state: state))
    self.panel = panel
    return panel
  }

  /// Top-right of the screen the user is looking at, clear of the menu bar.
  private func position(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    let origin = NSPoint(
      x: visible.maxX - size.width - 20,
      y: visible.maxY - size.height - 20
    )
    panel.setFrame(NSRect(origin: origin, size: size), display: false)
  }
}

/// The panel's content: one card per pending approval.
struct ApprovalPromptView: View {
  @ObservedObject var state: ApprovalPanelState

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("harness 需要你的批准")
          .font(.headline)
        if state.alerts.isEmpty {
          Text("没有待处理的审批。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(state.alerts) { alert in
          card(alert)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func card(_ alert: ApprovalAlert) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        Text(alert.toolName).font(.callout.weight(.semibold))
        Spacer()
      }
      Text(alert.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let callId = alert.callId {
        Text(callId).font(.caption2.monospaced()).foregroundStyle(.tertiary)
      }
      HStack(spacing: 8) {
        Button("批准（仅这一次）") { state.onDecision?(alert.id, .allowedOnce) }
          .keyboardShortcut(.defaultAction)
        Button("拒绝") { state.onDecision?(alert.id, .rejected) }
        Spacer()
        Text(alert.sessionID)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }
}
