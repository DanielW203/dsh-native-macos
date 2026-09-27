import Foundation
import HarnessRuntime
import SwiftUI

/// A skin *manager* installed in the profile as a web plugin.
///
/// Listed rather than ignored because this window is its replacement: two owners of the
/// same `cordis.patch.yml` block would fight over it, each rewriting what the other wrote.
/// The window offers to switch the old one off, and says so plainly instead of quietly
/// living beside it.
public struct LegacySkinPlugin: Sendable, Equatable, Identifiable {
  public var name: String
  /// Still listed in `dsh.profile.bundles`, i.e. it will load on the next harness start.
  public var isEnabled: Bool

  public var id: String { name }

  public init(name: String, isEnabled: Bool) {
    self.name = name
    self.isEnabled = isEnabled
  }
}

/// Drives the skin manager window.
///
/// Everything the window can do is a method here, and every outcome — a switch, a warning,
/// a refusal — lands in the same two published strings, so the window never has to guess at
/// what happened.
@MainActor
public final class SkinManagerModel: ObservableObject {
  /// The home the window is acting on, shown in the header so a user with two installs can
  /// tell which one they are about to change.
  @Published public private(set) var dshHome: String
  @Published public private(set) var profiles: [String] = []
  @Published public private(set) var selectedProfile: String
  @Published public private(set) var skins: [Skin] = []
  /// The skin the profile's patch file currently composes; `nil` is DeepSeek Harness' own look.
  @Published public private(set) var activeSkinID: String?
  @Published public private(set) var legacyPlugins: [LegacySkinPlugin] = []
  @Published public private(set) var busyLabel: String?
  @Published public private(set) var status: String?
  @Published public private(set) var failure: String?
  /// Anything the switch could not do cleanly, kept verbatim: they name files and packages,
  /// and paraphrasing them would lose the one detail a user needs to act on.
  @Published public private(set) var warnings: [String] = []
  /// A switch has been written and the page is still showing the previous look.
  ///
  /// Shown as an offer rather than done automatically: reloading the page throws away
  /// whatever the user was reading in the other window, which is not this window's call.
  @Published public private(set) var needsPageReload = false

  /// Reload the Web UI. Supplied by the app, because the window that owns the page is the
  /// main one and this model has no business holding a second reference to it.
  public var onReloadPage: (() -> Void)?

  private let paths: RuntimePaths
  private var started = false

  public init(paths: RuntimePaths, profile: String = "web") {
    self.paths = paths
    self.dshHome = paths.dshHome.path
    self.selectedProfile = profile
  }

  public var isBusy: Bool { busyLabel != nil }

  /// - Returns: whether `activeSkinID` names the skin the user would call current.
  public func isActive(_ skin: Skin) -> Bool {
    activeSkinID == skin.id
  }

  public func startIfNeeded() {
    guard !started else { return }
    started = true
    refresh()
  }

  public func selectProfile(_ profile: String) {
    guard profile != selectedProfile else { return }
    selectedProfile = profile
    needsPageReload = false
    refresh()
  }

  /// Re-read the profiles, the installed skins, and the legacy plugin's state.
  ///
  /// Deliberately silent about `failure` and `status`: a refresh triggered by a page's
  /// `.task` must not erase the result of the switch the user just performed.
  public func refresh() {
    let manager = SkinManager(paths: paths)
    let available = manager.profiles()
    profiles = available
    if !available.isEmpty, !available.contains(selectedProfile) {
      selectedProfile = available.contains("web") ? "web" : available[0]
    }
    let found = manager.skins(profile: selectedProfile)
    skins = found
    activeSkinID = manager.activeSkinID(profile: selectedProfile, in: found)
    legacyPlugins = Self.legacyPlugins(inProfile: manager.profileDirectory(selectedProfile))
  }

  /// Make one skin active, or — with `nil` — go back to the official look.
  public func apply(_ skin: Skin?) {
    busyLabel = skin.map { "正在应用「\($0.name)」…" } ?? "正在恢复官方默认…"
    defer { busyLabel = nil }
    do {
      let report = try SkinManager(paths: paths).switchTo(skin?.id, profile: selectedProfile)
      warnings = report.warnings
      failure = nil
      status = report.active.map { "已切换到「\($0.name)」，重载页面后生效。" }
        ?? "已恢复官方默认外观，重载页面后生效。"
      needsPageReload = true
      refresh()
    } catch {
      status = nil
      warnings = []
      failure = describe(error)
    }
  }

  public func reloadPage() {
    onReloadPage?()
    needsPageReload = false
    status = "已请求重载页面。"
  }

  /// Switch a replaced skin manager off, so this window is the only owner of the block.
  ///
  /// Disabling rather than uninstalling: it is the reversible operation, it keeps the
  /// package on disk, and removing a dependency is what the plugin window is for.
  public func disable(_ plugin: LegacySkinPlugin) async {
    busyLabel = "正在停用 \(plugin.name)…"
    defer { busyLabel = nil }
    do {
      // Resolved lazily, like the console's own store: a plugin can be switched off before a
      // release is even installed, and asking for the entry point is what would fail then.
      let installer = HarnessInstaller(paths: paths)
      let store = PluginStore(paths: paths) { try await installer.activeEntryURL() }
      let result = try await store.setEnabled(plugin.name, enabled: false, profile: selectedProfile)
      warnings = result.warnings
      failure = nil
      status = "已停用 \(plugin.name)。重启 harness 后彻底生效。"
      refresh()
    } catch {
      status = nil
      failure = describe(error)
    }
  }

  // MARK: - Reading the legacy managers

  /// Packages that *are* skin managers, and are therefore what this window replaces.
  ///
  /// Spelled out rather than matched by pattern: `dsh-skin` is a theme, and a prefix rule
  /// would offer to disable it as a manager.
  static let replacedManagerPackages = [
    "dsh-skin-manager",
    "dsh-skin-switcher",
    "dsh-skin-center",
    "@linxin666/dsh-client-ui-skin-center",
  ]

  static func legacyPlugins(inProfile directory: URL) -> [LegacySkinPlugin] {
    guard let manifest = try? ProfileManifest.read(directory.appendingPathComponent("package.json")) else {
      return []
    }
    let dependencies = ProfileManifest.dependencies(manifest)
    let bundles = Set(ProfileManifest.bundleList(manifest))
    return replacedManagerPackages.compactMap { name in
      guard dependencies[name] != nil else { return nil }
      return LegacySkinPlugin(name: name, isEnabled: bundles.contains(name))
    }
  }

  private func describe(_ error: Error) -> String {
    if let runtime = error as? RuntimeError {
      return "\(runtime.code)：\(runtime.errorDescription ?? "")"
    }
    return error.localizedDescription
  }
}
