import AppKit
import Combine
import Foundation
import HarnessIM

/// The management surface behind DSHNative's 移动设备 window.
///
/// It owns one `MobileGatewayService` for the life of the running harness: the gateway's
/// listener is meaningless without a harness to drive, and the authenticated API client below is
/// bound to one harness URL, so a restart of the harness builds a new one rather than leaving a
/// client pointed at a dead port.
@MainActor
public final class MobileGatewayModel: ObservableObject {
  /// What the window renders. Starts empty so the window can open before a harness exists.
  @Published public private(set) var status: MobileGatewayService.Status
  /// The pairing offer currently on screen, if any. Cleared when it expires or is dismissed.
  @Published public private(set) var pairing: MobileGatewayService.PairingOffer?
  /// Set when the gateway cannot be built at all — a parse failure, a registry that will not
  /// load, a port that is taken. The window shows it verbatim rather than guessing.
  @Published public private(set) var setupError: String?
  /// Human-readable connection state of the harness the gateway drives.
  @Published public private(set) var harnessState: String = "未连接"
  /// The device name typed into the pairing sheet.
  @Published public var pairingName: String = ""
  /// The built-in Tailscale install flow's state, so the card can show progress and failures
  /// instead of a button that appears to do nothing.
  @Published public private(set) var tailscaleInstall: TailscaleInstallState = .idle
  /// User-editable gateway settings (public addresses, Tailscale switch, keepalive).
  @Published public private(set) var settings: MobileGatewaySettings
  /// Set when a settings change was rejected — a bad public address, typically.
  @Published public private(set) var settingsError: String?

  private let appRoot: URL
  private let settingsStore: MobileGatewaySettingsStore
  private let harnessURL: @Sendable () -> URL?
  private var service: MobileGatewayService?
  private var attachedURL: String?

  public init(
    appRoot: URL,
    harnessURL: @escaping @Sendable () -> URL?,
    settingsStore: MobileGatewaySettingsStore? = nil
  ) {
    self.appRoot = appRoot
    self.settingsStore = settingsStore ?? MobileGatewaySettingsStore()
    self.harnessURL = harnessURL
    self.settings = self.settingsStore.load()
    self.status = MobileGatewayService.Status(mode: .disabled)
    refresh()
  }

  /// Called when the app learns the harness is up (and on every URL change).
  ///
  /// Re-attaching is deliberately driven by the URL rather than by a flag: a harness restart
  /// produces a new port and a new single-use token, so the only correct signal that the old
  /// client is stale is that the address changed.
  public func harnessBecameAvailable() {
    guard let url = harnessURL() else {
      harnessState = "harness 未运行"
      return
    }
    guard url.absoluteString != attachedURL else {
      refresh()
      return
    }
    attachedURL = url.absoluteString
    Task { await attach(to: url) }
  }

  /// The harness went away: keep the listener (a phone that connects must still receive a clean
  /// 503) but say that nothing is driving it.
  public func harnessStopped() {
    harnessState = "harness 已停止"
    attachedURL = nil
  }

  private func attach(to url: URL) async {
    do {
      let parsed = try HarnessAPIClient.parse(authenticatedURL: url)
      let client = HarnessAPIClient(baseURL: parsed.origin)
      try await client.authenticate(token: parsed.token)
      var configuration = MobileGatewayConfiguration.standard()
      // The user's own settings win over the defaults: these are the addresses they configured a
      // tunnel for, and the switch that decides whether Tailscale is consulted.
      configuration.endpoints = settings.publicEndpoints
      configuration.tailscaleEnabled = settings.tailscaleEnabled
      configuration.keepAliveInterval = settings.keepAliveInterval
      let service = try MobileGatewayService(configuration: configuration, rpc: HarnessAPIRPC(client: client))
      service.onStatusChange = { [weak self] status in
        Task { @MainActor in self?.status = status }
      }
      // The previous instance must let go of the port before the new one binds it.
      self.service?.stop()
      self.service = service
      setupError = nil
      harnessState = "harness 已连接"
      service.start()
      status = service.status()
      if pairing == nil { refresh() }
      // Tailscale is probed after the listener is up so the advertised address carries the port
      // the gateway actually bound.
      await service.refreshTailscale()
      status = service.status()
    } catch {
      setupError = (error as NSError).localizedDescription
      harnessState = "无法连接 harness"
    }
  }

  public func refresh() {
    if let service {
      status = service.status()
    }
  }

  /// Re-read Tailscale. The window calls this when it appears, because a user who just switched
  /// Tailscale on expects to see the address without relaunching the app.
  public func refreshTailscale() {
    guard let service else { return }
    Task {
      await service.refreshTailscale()
      status = service.status()
    }
  }

  // MARK: - Actions

  public func setMode(_ mode: MobileGatewayMode) {
    do {
      try service?.setMode(mode)
      refresh()
    } catch {
      setupError = (error as NSError).localizedDescription
    }
  }

  public func setRequireAuth(_ enabled: Bool) {
    do {
      try service?.setRequireAuth(enabled)
      refresh()
    } catch {
      setupError = (error as NSError).localizedDescription
    }
  }

  /// Create a pairing code and show its QR. Only the gateway itself may mint one: a code issued
  /// while the gateway is closed could never be claimed, and would silently expire.
  public func createPairing() {
    guard let service else {
      setupError = "harness 未连接，无法生成配对码"
      return
    }
    do {
      let trimmed = pairingName.trimmingCharacters(in: .whitespacesAndNewlines)
      pairing = try service.createPairing(name: trimmed.isEmpty ? nil : trimmed)
      setupError = nil
    } catch {
      setupError = (error as NSError).localizedDescription
    }
  }

  public func revoke(_ deviceID: String) {
    _ = service?.revoke(deviceID: deviceID)
    refresh()
  }

  /// Drop the QR from the window. The code itself stays valid until its TTL: hiding a picture
  /// is a UI decision and must not be mistaken for revocation.
  public func dismissPairing() {
    pairing = nil
  }

  /// Whether a pairing code is still inside its TTL, so the window can stop showing a dead QR.
  public func pairingIsLive(now: Date = Date()) -> Bool {
    guard let pairing else { return false }
    return pairing.expiresAt > now.timeIntervalSince1970 * 1000
  }

  public var isConnectedToHarness: Bool { service != nil }

  // MARK: - Installing Tailscale

  public enum TailscaleInstallState: Sendable, Equatable {
    case idle
    case downloading(Double)
    /// The installer was handed to Installer.app; the rest happens in the system UI.
    case opened
    case failed(String)
  }

  /// What to offer, given what is on the machine.
  public var tailscaleInstallPlan: MobileGatewayTailscaleInstaller.Plan {
    MobileGatewayTailscaleInstaller.plan(appInstalled: model_tailscaleInstalled)
  }

  private var model_tailscaleInstalled: Bool {
    if case .notInstalled = status.tailscale.state { return false }
    return true
  }

  /// Download Tailscale's official package and open it with Installer.app.
  ///
  /// The app stops here on purpose: the package installs a system extension, macOS owns that
  /// authorization, and a third-party app has no business collecting an administrator password of
  /// its own.
  public func installTailscale() {
    guard case .idle = tailscaleInstall else {
      if case .failed = tailscaleInstall {} else { return }
      tailscaleInstall = .idle
      return installTailscale()
    }
    tailscaleInstall = .downloading(0)
    Task {
      do {
        let package = try await MobileGatewayTailscaleInstaller.downloadPackage { progress in
          Task { @MainActor in self.tailscaleInstall = .downloading(progress) }
        }
        NSWorkspace.shared.open(package)
        tailscaleInstall = .opened
      } catch {
        let message = (error as? MobileGatewayTailscaleInstaller.InstallError)?.message
          ?? (error as NSError).localizedDescription
        tailscaleInstall = .failed(message)
      }
    }
  }

  /// Land on Tailscale's App Store page rather than a search box.
  public func openTailscaleAppStore() {
    if let url = URL(string: MobileGatewayTailscaleInstaller.appStoreDeepLink), NSWorkspace.shared.open(url) {
      return
    }
    if let url = URL(string: MobileGatewayTailscaleInstaller.appStoreWebURL) {
      NSWorkspace.shared.open(url)
    }
  }

  public func openTailscaleDownloadPage() {
    if let url = URL(string: MobileGatewayTailscaleInstaller.downloadPageURL) {
      NSWorkspace.shared.open(url)
    }
  }

  /// Launch an already-installed Tailscale so the user can log in — the step that turns
  /// "installed" into "running", and the one that a discovery pass cannot do for them.
  public func openTailscaleApp() {
    let bundleID = "io.tailscale.ipn.macos"
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
      return
    }
    let fallback = URL(fileURLWithPath: "/Applications/Tailscale.app")
    if FileManager.default.fileExists(atPath: fallback.path) {
      NSWorkspace.shared.openApplication(at: fallback, configuration: NSWorkspace.OpenConfiguration())
    }
  }

  // MARK: - Public addresses

  /// Register a public address typed into the panel.
  ///
  /// A bare hostname is accepted because that is what a tunnel gives you; it is completed into the
  /// `wss://…/ws/mobile` endpoint the protocol requires before anything is stored.
  public func addPublicEndpoint(_ raw: String) {
    do {
      let endpoint = try MobileGatewayCloudflare.endpoint(fromUserInput: raw)
      var next = settings
      guard !next.publicEndpoints.contains(endpoint) else {
        settingsError = nil
        return
      }
      next.publicEndpoints.append(endpoint)
      try settingsStore.save(next)
      settings = next
      settingsError = nil
      applyRuntimeSettings()
    } catch {
      settingsError = (error as? MobileGatewayConfiguration.EndpointError)?.message
        ?? (error as NSError).localizedDescription
    }
  }

  public func removePublicEndpoint(_ endpoint: String) {
    var next = settings
    next.publicEndpoints.removeAll { $0 == endpoint }
    try? settingsStore.save(next)
    settings = next
    applyRuntimeSettings()
  }

  public func setTailscaleEnabled(_ enabled: Bool) {
    var next = settings
    next.tailscaleEnabled = enabled
    try? settingsStore.save(next)
    settings = next
    guard let service else { return }
    Task {
      await service.setTailscaleEnabled(enabled)
      status = service.status()
    }
  }

  /// Push the settings into the live service. Endpoints update in place so the listener keeps its
  /// port and connected phones keep their sessions.
  private func applyRuntimeSettings() {
    guard let service else { return }
    do {
      try service.updatePublicEndpoints(settings.publicEndpoints)
      status = service.status()
    } catch {
      settingsError = (error as? MobileGatewayConfiguration.EndpointError)?.message
        ?? (error as NSError).localizedDescription
    }
  }

  public func copyCloudflareCommand(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
  }

  public var cloudflare: MobileGatewayCloudflare.Status { MobileGatewayCloudflare.detect() }

  public func copyHomebrewCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(MobileGatewayTailscaleInstaller.homebrewCommand, forType: .string)
  }
}
