import CryptoKit
import SwiftUI
import WebKit

/// Whether a navigation target belongs to the server this window is showing.
///
/// The harness serves everything from one loopback origin, so "same origin" is the whole
/// rule. Links out — to the documentation, to platform.deepseek.com for an API key — are
/// opened in the system browser instead: this window has no address bar and no history,
/// so following them in place would strand the user on a page they cannot leave.
public enum WebNavigationPolicy {
  public static func shouldLoadInApp(_ url: URL, base: URL) -> Bool {
    // WKWebView loads about:blank for an empty document; allow it through so a clear
    // does not register as an external navigation.
    if url.scheme == "about" { return true }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return false
    }
    guard url.host == base.host else { return false }
    return effectivePort(url) == effectivePort(base)
  }

  private static func effectivePort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }
}

/// Owns the WKWebView and publishes its loading state.
///
/// A class rather than plain SwiftUI state because the web view outlives any single view
/// body: reloading the window must not throw away the loaded application, and a stale
/// WKWebView is what makes a "Reload" button either useless or destructive.
@MainActor
public final class HarnessWebModel: NSObject, ObservableObject {
  @Published public private(set) var isLoading = false
  @Published public private(set) var progress: Double = 0
  @Published public private(set) var failure: String?
  @Published public private(set) var title: String?

  public let webView: WKWebView
  private let baseURL: URL
  private let onExternal: (URL) -> Void
  /// Reports loading outcomes upward. A page that fails to load must leave a trace
  /// somewhere a human can read, and this window has no console to print to.
  private let onEvent: (String) -> Void
  /// Run once the page finishes loading. The harness has no URL routing — the active
  /// settings tab lives in React state — so reaching a tab from outside means clicking
  /// through the interface.
  private let postLoadScript: String?
  private var observations: [NSKeyValueObservation] = []

  public init(
    baseURL: URL,
    onExternal: @escaping (URL) -> Void,
    onEvent: @escaping (String) -> Void = { _ in },
    postLoadScript: String? = nil
  ) {
    self.baseURL = baseURL
    self.onExternal = onExternal
    self.onEvent = onEvent
    self.postLoadScript = postLoadScript

      let configuration = WKWebViewConfiguration()
    // Persistent on purpose: the sign-in state, the model configuration, and the chosen
    // workspace all live in the page's storage, and a fresh store would ask for all three
    // again on every launch.
    configuration.websiteDataStore = .default()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true

    self.webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()

    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = false

    observations = [
      webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
        let value = webView.estimatedProgress
        Task { @MainActor in self?.progress = value }
      },
      webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
        let value = webView.isLoading
        Task { @MainActor in self?.isLoading = value }
      },
    ]
  }

  /// The prefix the harness mints its Web authentication cookies with.
  ///
  /// A cookie is named `dsh-auth-` plus the base64url SHA-256 of the *authority* it was
  /// issued for, so every `host:port` gets a cookie of its own that never overwrites
  /// another one: `dsh-auth-<hash(host:port)>`.
  private static let authCookiePrefix = "dsh-auth-"

  /// The cookie name the harness issues for `url`'s authority, or `nil` for a URL with no
  /// usable host and port.
  ///
  /// Recomputing the server's name is what makes "keep the live session, drop the rest"
  /// possible at all: HTTP cookies carry no port, so the authority is only ever visible in
  /// the name.
  private static func authCookieName(for url: URL) -> String? {
    guard let host = url.host, let port = url.port else { return nil }
    let digest = SHA256.hash(data: Data("\(host):\(port)".utf8))
    let encoded = Data(digest).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return authCookiePrefix + encoded
  }

  /// Whether a late sweep has already recovered this page by loading it again.
  private var recoveredAfterSweep = false

  /// Load the server URL. The query string carries the access token and must be preserved.
  ///
  /// The cache is bypassed on purpose. The harness serves its client plugins — skins
  /// included — from files on this machine, and a web view that reuses a cached bundle
  /// makes an edited skin look as though nothing changed. Re-fetching local assets costs
  /// nothing next to the confusion of a change that appears not to apply.
  ///
  /// Stale authentication cookies go first, and the load waits for them: a request that
  /// still carried them would arrive with exactly the header this exists to keep short.
  public func load(_ url: URL) {
    failure = nil
    recoveredAfterSweep = false
    sweepThenLoad(url, schedulingFollowUps: true)
  }

  /// Drop every harness cookie that is not the one `url` needs, then load it.
  private func sweepThenLoad(_ url: URL, schedulingFollowUps: Bool) {
    discardStaleAuthCookies(keeping: url) { [weak self] removed in
      guard let self else { return }
      var request = URLRequest(url: url)
      request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      self.webView.load(request)
      if schedulingFollowUps {
        self.sweepAfterLoad(keeping: url)
      }
      if removed {
        self.onEvent("dropped stale harness cookies before loading the page")
      }
    }
  }

  /// Delete the harness authentication cookies an earlier launch left in this web view's store.
  ///
  /// The store is persistent on purpose — the page keeps the chosen model and workspace in
  /// its own storage — but the harness mints a cookie per authority, named for the port it
  /// happens to be listening on, and a cookie for a dead port is never replaced by the live
  /// one. The web view then sends *every* cookie it holds on *every* request to the loopback
  /// origin, so the header grows by one cookie per launch until it crosses the server's
  /// request limit — and the *page* survives that longest, because a document request carries
  /// few headers. What dies first is the client-plugin bundle, whose URL is already a
  /// kilobyte of package names before the cookies are counted: the server answers `431`,
  /// the loader sees a `<script>` that never loaded, and the whole UI reports "Failed to
  /// load plugins" while the harness itself is perfectly healthy.
  ///
  /// Only one cookie is kept, and the caller guarantees its authority is the live one. A
  /// window that follows the harness to a new port sweeps the old port's cookie away; the
  /// two windows this app can open (harness and market) always point at the same harness, so
  /// they never sweep each other's session.
  private func discardStaleAuthCookies(keeping url: URL, _ completion: @escaping (Bool) -> Void) {
    guard let keep = Self.authCookieName(for: url) else {
      completion(false)
      return
    }
    let store = webView.configuration.websiteDataStore.httpCookieStore
    store.getAllCookies { cookies in
      let stale = cookies.filter { $0.name.hasPrefix(Self.authCookiePrefix) && $0.name != keep }
      guard !stale.isEmpty else {
        completion(false)
        return
      }
      let group = DispatchGroup()
      for cookie in stale {
        group.enter()
        store.delete(cookie) { group.leave() }
      }
      group.notify(queue: .main) { completion(true) }
    }
  }

  /// Sweep again while the page is starting, because the cookie store answers before it has
  /// finished hydrating.
  ///
  /// WebKit reads the persistent jar lazily: right after a web view is created, `getAllCookies`
  /// can return a list that is still missing the cookies on disk, and the ones that arrive
  /// moments later are exactly the ones the page's first requests would carry. The follow-ups
  /// close that window. If one of them does find something, the page that is already loading
  /// was built on the oversized header — its plugin bundles are the ones that failed — so it
  /// is loaded once more, now that the jar is clean. Once every launch starts clean, the
  /// follow-ups find nothing and nothing reloads.
  private func sweepAfterLoad(keeping url: URL) {
    for delay in [0.3, 1.5, 4.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        self.discardStaleAuthCookies(keeping: url) { [weak self] removed in
          guard let self, removed else { return }
          self.onEvent("dropped stale harness cookies after the page started")
          guard !self.recoveredAfterSweep else { return }
          self.recoveredAfterSweep = true
          self.sweepThenLoad(url, schedulingFollowUps: false)
        }
      }
    }
  }

  /// Reload the page the web view is showing, re-authenticating it on the way.
  public func reload() {
    failure = nil
    // Reload through §load§ so the same cache policy applies; §webView.reload()§ reuses
    // the original request, which would keep serving the stale bundle this exists to avoid.
    if let current = webView.url, current.scheme != "about" {
      load(current)
    } else {
      webView.reload()
    }
  }

  /// Run a script in the page. Used by the market window to walk back to its section.
  public func evaluate(_ script: String) {
    webView.evaluateJavaScript(script) { [weak self] _, error in
      guard let error else { return }
      Task { @MainActor in self?.onEvent("script failed: \(error.localizedDescription)") }
    }
  }

  public func clear() {
    webView.load(URLRequest(url: URL(string: "about:blank")!))
  }
}

extension HarnessWebModel: WKNavigationDelegate {
  public func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }
    if WebNavigationPolicy.shouldLoadInApp(url, base: baseURL) {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.cancel)
    // Only a user-initiated jump leaves the app; a scripted redirect to somewhere else is
    // dropped rather than stealing focus to a browser window.
    if navigationAction.navigationType == .linkActivated {
      onExternal(url)
    }
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    failure = nil
    title = webView.title
    let name = webView.title ?? "untitled"
    onEvent("page loaded: \(name)")
    if let postLoadScript {
      webView.evaluateJavaScript(postLoadScript) { _, error in
        if let error {
          self.onEvent("post-load script failed: \(error.localizedDescription)")
        }
      }
    }
  }

  public func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    failure = error.localizedDescription
    onEvent("load failed: (error.localizedDescription)")
  }

  public func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    failure = error.localizedDescription
    onEvent("load failed before navigation: (error.localizedDescription)")
  }
}

/// SwiftUI wrapper. The web view instance comes from the model, so re-rendering the view
/// never reloads the page.
public struct HarnessWebView: NSViewRepresentable {
  @ObservedObject private var model: HarnessWebModel

  public init(model: HarnessWebModel) {
    self.model = model
  }

  public func makeNSView(context: Context) -> WKWebView { model.webView }

  public func updateNSView(_ nsView: WKWebView, context: Context) {}
}
