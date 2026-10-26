import AppKit
import Combine
import Foundation
import WebKit

/// Hosts the bundled HTML/SVG/CSS startup surface and bridges it to the window model.
///
/// The web view is disposable: it is loaded from a file inside the app bundle, never talks
/// to the network, uses a non-persistent data store, and is removed as soon as the real
/// harness page has been revealed. The real WKWebView below is never touched.
@MainActor
final class StartupOverlayController: NSObject, ObservableObject {
  enum Mode {
    case live
    case preview
  }

  let webView: WKWebView
  /// True once the local page has painted. The SwiftUI dark backdrop is only there to
  /// cover the WKWebView's first frame; keeping it behind the fading web view at handoff
  /// would hide the real page and turn the cross-fade into an abrupt swap.
  @Published private(set) var hasLoaded = false

  private let boot: HarnessWindowModel
  private let mode: Mode
  private let safeMode: Bool
  private let onHandoff: () -> Void
  private let onUnavailable: (String) -> Void
  private let onOpenRecovery: () -> Void
  private let userContentController: WKUserContentController
  private let messageProxy: WeakScriptMessageHandler

  private var ticker: Task<Void, Never>?
  private var loadFallback: Task<Void, Never>?
  private var handoffFallback: Task<Void, Never>?

  private var didStart = false
  private var didReceiveReady = false
  private var didBeginHandoff = false
  private var didFinish = false
  private var didReportBridgeFailure = false
  private var startedAt = Date()
  private var lastPhase: HarnessWindowModel.Phase?
  private var lastKeyedSnapshot: StartupSnapshot?

  private static let handlerName = "startup"
  private static let startupColor = NSColor(
    calibratedRed: 0.027,
    green: 0.043,
    blue: 0.071,
    alpha: 1
  )

  init(
    boot: HarnessWindowModel,
    mode: Mode,
    safeMode: Bool,
    onHandoff: @escaping () -> Void,
    onUnavailable: @escaping (String) -> Void,
    onOpenRecovery: @escaping () -> Void
  ) {
    self.boot = boot
    self.mode = mode
    self.safeMode = safeMode
    self.onHandoff = onHandoff
    self.onUnavailable = onUnavailable
    self.onOpenRecovery = onOpenRecovery

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let controller = WKUserContentController()
    configuration.userContentController = controller
    self.userContentController = controller
    self.messageProxy = WeakScriptMessageHandler()

    let view = WKWebView(frame: .zero, configuration: configuration)
    self.webView = view

    super.init()

    view.navigationDelegate = self
    view.underPageBackgroundColor = Self.startupColor
    view.allowsBackForwardNavigationGestures = false
    view.allowsMagnification = false
    #if DEBUG
    view.isInspectable = true
    #endif
    messageProxy.target = self
    controller.add(messageProxy, name: Self.handlerName)
  }

  deinit {
    ticker?.cancel()
    loadFallback?.cancel()
    handoffFallback?.cancel()
  }

  // MARK: - Lifecycle

  func start() {
    guard !didStart else { return }
    didStart = true
    startedAt = Date()

    guard let url = Bundle.main.url(
      forResource: "startup",
      withExtension: "html",
      subdirectory: "Startup"
    ) else {
      fail("找不到启动界面资源（Startup/startup.html）")
      return
    }

    webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

    // A page that never reports ready is a page that would otherwise leave a dark rectangle
    // over a working app. The fallback is the existing boot placeholder.
    loadFallback = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      guard !Task.isCancelled, let self, !self.didReceiveReady, !self.didFinish else { return }
      self.fail("启动界面没有响应")
    }

    if mode == .live {
      startTicker()
    }
  }

  func stop() {
    ticker?.cancel()
    ticker = nil
    loadFallback?.cancel()
    loadFallback = nil
    handoffFallback?.cancel()
    handoffFallback = nil
    userContentController.removeScriptMessageHandler(forName: Self.handlerName)
    webView.navigationDelegate = nil
    webView.stopLoading()
  }

  // MARK: - Live updates

  private func startTicker() {
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled, let self else { return }
        self.pushSnapshot()
      }
    }
  }

  private func pushSnapshot(force: Bool = false) {
    guard didReceiveReady, !didFinish else { return }

    // A retry starts a new boot attempt; its elapsed clock should start from zero again even
    // though the overlay has been on screen for longer.
    if boot.phase == .starting, lastPhase != .starting {
      startedAt = Date()
    }
    lastPhase = boot.phase

    let web = boot.webModel
    let input = StartupSnapshotInput(
      phase: boot.phase,
      logs: boot.log,
      detail: boot.detail,
      pageReady: web?.isReady ?? false,
      pageFailure: web?.failure,
      elapsed: Date().timeIntervalSince(startedAt),
      needsNode: boot.needsNode,
      nodeStage: boot.nodeStage,
      safeMode: safeMode,
      isBusy: boot.isBusy,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    let snapshot = StartupSnapshotBuilder.make(input)

    var keyed = snapshot
    keyed.elapsed = floor(snapshot.elapsed)
    let shouldSend = force || lastKeyedSnapshot != keyed
    if shouldSend {
      lastKeyedSnapshot = keyed

      let object = snapshot.jsonObject
      webView.callAsyncJavaScript(
        "window.dshStartup.update(snapshot);",
        arguments: ["snapshot": object],
        in: nil,
        in: .page
      ) { [weak self] result in
        guard case .failure(let error) = result, let self else { return }
        self.reportBridgeFailure(error.localizedDescription)
      }
    }

    // The handoff decision is independent of whether the visible snapshot changed: the
    // minimum-display clock can cross 1.4s during a second in which the log did not move,
    // and a skipped update must not postpone the handoff to the next whole second.
    if StartupHandoffPolicy.shouldHandoff(snapshot) {
      beginHandoff()
    }
  }

  private func reportBridgeFailure(_ message: String) {
    guard !didReportBridgeFailure else { return }
    didReportBridgeFailure = true
    boot.recordBootNote("启动界面脚本更新失败：\(message)")
  }

  // MARK: - Handoff

  private func beginHandoff() {
    guard !didBeginHandoff, !didFinish else { return }
    didBeginHandoff = true

    webView.evaluateJavaScript("window.dshStartup.beginHandoff && window.dshStartup.beginHandoff();") {
      [weak self] _, error in
      guard let self, let error else { return }
      self.reportBridgeFailure(error.localizedDescription)
      self.finishHandoff()
    }

    handoffFallback?.cancel()
    handoffFallback = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard !Task.isCancelled, let self else { return }
      self.finishHandoff()
    }
  }

  private func finishHandoff() {
    guard !didFinish else { return }
    didFinish = true
    ticker?.cancel()
    ticker = nil
    loadFallback?.cancel()
    loadFallback = nil
    handoffFallback?.cancel()
    handoffFallback = nil

    let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.16 : 0.26
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      webView.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      Task { @MainActor in
        self?.onHandoff()
      }
    }
  }

  private func fail(_ reason: String) {
    guard !didFinish else { return }
    didFinish = true
    ticker?.cancel()
    ticker = nil
    loadFallback?.cancel()
    loadFallback = nil
    handoffFallback?.cancel()
    handoffFallback = nil
    onUnavailable(reason)
  }

  // MARK: - Actions

  private func handleAction(_ id: StartupAction.ID) {
    switch id {
    case .retryBoot:
      Task { await boot.start() }
    case .openRecovery:
      onOpenRecovery()
    case .disablePlugins:
      Task { await boot.quarantineAndRestart() }
    case .installNode:
      Task { await boot.installNode() }
    case .reloadPage:
      boot.reload()
    case .openInBrowser:
      boot.openInBrowser()
    case .continueAnyway:
      finishHandoff()
    }
  }
}

// MARK: - WKScriptMessageHandler

extension StartupOverlayController: WKScriptMessageHandler {
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
          let type = body["type"] as? String else {
      return
    }
    switch type {
    case "ready":
      didReceiveReady = true
      hasLoaded = true
      loadFallback?.cancel()
      loadFallback = nil
      if mode == .preview {
        webView.evaluateJavaScript("window.dshStartup.startPreview && window.dshStartup.startPreview();") {
          [weak self] _, error in
          guard let self, let error else { return }
          self.reportBridgeFailure(error.localizedDescription)
          self.fail("启动界面预览无法运行")
        }
      } else {
        pushSnapshot(force: true)
      }
    case "handoff":
      finishHandoff()
    case "action":
      guard let raw = body["id"] as? String,
            let action = StartupAction.ID(rawValue: raw) else { return }
      handleAction(action)
    default:
      break
    }
  }
}

// MARK: - WKNavigationDelegate

extension StartupOverlayController: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    // The launch surface is local-only. A remote URL here is a bug, never a feature.
    if url.isFileURL || url.scheme == "about" {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    fail("启动界面加载失败：\(error.localizedDescription)")
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    fail("启动界面加载失败：\(error.localizedDescription)")
  }
}

/// A message handler that does not make the web view's content controller retain its owner.
///
/// WKUserContentController retains its handlers, and the controller owns the web view, so a
/// direct conformance would be a retain cycle that keeps the whole launch surface alive
/// after handoff. The proxy is the one line that breaks it.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    target?.userContentController(userContentController, didReceive: message)
  }
}
