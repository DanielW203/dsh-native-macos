import AppKit
import Combine
import SwiftUI

/// The product name the windows, the About panel and the settings pane agree on.
///
/// It is a constant rather than a localized string: it is a brand, and a window whose title
/// changes with the interface language is a window the user cannot find again by name.
public enum AppBrand {
  public static let name = "Native DSH"
  /// The bundle name before it was renamed. Kept only so a lookup on an older build — where
  /// `mainWindow()` matched this title — cannot silently match the wrong window after an
  /// update has already recreated it.
  public static let legacyWindowTitle = "DeepSeek Harness"
}

/// Which appearance the app asks AppKit to draw.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  public var id: String { rawValue }
}

/// The interface language. `system` follows the Mac's preferred language, which is what a
/// first launch should do; the explicit cases exist for a user whose Mac is in one language
/// and whose tools are in another.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system
  case chinese
  case english

  public var id: String { rawValue }
}

/// App-wide preferences: appearance and language.
///
/// A single observable object, created before the first window and read by the menu bar, the
/// window titles and the settings pane. Both values are persisted in `UserDefaults`.
/// Appearance applies immediately; language relabels this app's own items immediately and the
/// framework-built menus on the next launch, because AppKit constructs those once per process.
///
/// Localization is deliberately a two-argument function instead of a string table. The menu
/// bar is its main consumer, and at each call site the Chinese and English labels sit next
/// to each other, which is what keeps the two languages from drifting apart as items are
/// added.
@MainActor
public final class AppPreferences: ObservableObject {
  public static let shared = AppPreferences()

  private enum Key {
    static let appearance = "app.appearance"
    static let language = "app.language"
    /// Read by Foundation and AppKit before the app's first window, to decide which
    /// localization the framework's own menus are drawn in.
    static let appleLanguages = "AppleLanguages"
  }

  private let defaults: UserDefaults
  /// The language this process started with. Switching the picker cannot relabel menus that
  /// AppKit already built, so the settings pane offers a relaunch when this differs.
  private let launchLanguage: AppLanguage

  @Published public var appearance: AppAppearance {
    didSet {
      guard appearance != oldValue else { return }
      defaults.set(appearance.rawValue, forKey: Key.appearance)
      applyAppearance()
    }
  }

  @Published public var language: AppLanguage {
    didSet {
      guard language != oldValue else { return }
      defaults.set(language.rawValue, forKey: Key.language)
      applyLanguageForNextLaunch()
    }
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let savedAppearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
    let savedLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
    appearance = savedAppearance
    language = savedLanguage
    launchLanguage = savedLanguage
    // Before SwiftUI builds its menu bar: AppKit reads this key when it localizes the
    // standard menus (编辑 / 显示 / 窗口 / 帮助, 关于, 隐藏, 退出), and setting it later only
    // takes effect on the next launch.
    applyLanguageForNextLaunch()
    applyAppearance()
  }

  /// Whether the system menus still speak the previous language. The app's own menu items
  /// relabel instantly; only the framework-provided ones need a new process.
  public var needsRestartForLanguage: Bool { language != launchLanguage }

  /// Quit and reopen through the app's own relaunch path, so the next process starts with
  /// the new `AppleLanguages` value and rebuilds every menu in the chosen language.
  public func restartToApplyLanguage() {
    Task { await HarnessAppHooks.shared.restart() }
  }

  /// Point the next launch's framework localization at the chosen language.
  ///
  /// `system` removes the override rather than writing the current system language, so the
  /// app keeps following the Mac if the user changes it in System Settings.
  private func applyLanguageForNextLaunch() {
    switch language {
    case .system:
      defaults.removeObject(forKey: Key.appleLanguages)
    case .chinese:
      defaults.set(["zh-Hans"], forKey: Key.appleLanguages)
    case .english:
      defaults.set(["en"], forKey: Key.appleLanguages)
    }
  }

  // MARK: - Language

  /// The language actually rendered: `system` resolved to Chinese or English once, here,
  /// so no call site has to repeat the fallback.
  public var resolvedLanguage: AppLanguage {
    guard language == .system else { return language }
    let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
    // `zh-Hans`, `zh-Hant`, `zh-CN` all start with `zh`; anything else falls back to English,
    // because a half-translated third language would be worse than the language the app was
    // written in.
    return preferred.hasPrefix("zh") ? .chinese : .english
  }

  public var isChinese: Bool { resolvedLanguage == .chinese }

  /// Pick the label for the current interface language.
  ///
  /// Argument order is fixed (`chinese`, `english`) so a call site cannot invert it, and the
  /// labels are literals rather than keys so a missing translation cannot compile.
  public func text(_ chinese: String, _ english: String) -> String {
    isChinese ? chinese : english
  }

  // MARK: - Appearance

  /// Hand the choice to AppKit. Setting `appearance` on `NSApp` covers every native window
  /// with one assignment, and the web view reads the same effective appearance, so a page
  /// that follows `prefers-color-scheme` switches with it.
  public func applyAppearance() {
    // `NSApplication.shared` rather than `NSApp`: this can run from the App's initializer,
    // before the global has necessarily been assigned, and `NSApp` is an implicitly
    // unwrapped optional whose nil would crash the launch before the first window.
    switch appearance {
    case .system:
      NSApplication.shared.appearance = nil
    case .light:
      NSApplication.shared.appearance = NSAppearance(named: .aqua)
    case .dark:
      NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }
  }
}

/// The app menu's Settings item.
///
/// It is a `View` rather than a `Button` written inline because `openWindow` is an
/// environment action, and a Commands value cannot read it reliably. The window is a normal
/// `Window` scene, not SwiftUI's `Settings` scene: that scene injects a second, unlabelled
/// "Settings…" item, which this replaces. `CommandGroup(replacing: .appSettings)` puts the
/// item exactly where macOS users look for it and keeps ⌘, working.
public struct SettingsMenuItem: View {
  @ObservedObject var preferences: AppPreferences
  @Environment(\.openWindow) private var openWindow

  public init(preferences: AppPreferences) {
    self.preferences = preferences
  }

  public var body: some View {
    Button(preferences.text("设置…", "Settings…")) {
      openWindow(id: HarnessWindowID.settings)
    }
    .keyboardShortcut(",", modifiers: .command)
  }
}

/// The settings pane behind ⌘,: appearance and language, applied live.
///
/// Two controls, not a tab bar. There is nothing else to configure yet, and a settings window
/// with one card per topic at this size would be mostly navigation.
public struct AppSettingsView: View {
  @ObservedObject var preferences: AppPreferences

  public init(preferences: AppPreferences) {
    self.preferences = preferences
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 10) {
        Image(systemName: "gearshape.fill")
          .font(.title2)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(AppBrand.name)
            .font(.headline)
          Text(preferences.text("外观与语言", "Appearance & Language"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Form {
        Section {
          Picker(preferences.text("主题", "Theme"), selection: $preferences.appearance) {
            Text(preferences.text("跟随系统", "System")).tag(AppAppearance.system)
            Text(preferences.text("浅色", "Light")).tag(AppAppearance.light)
            Text(preferences.text("深色", "Dark")).tag(AppAppearance.dark)
          }
          .pickerStyle(.segmented)
        } header: {
          Text(preferences.text("外观", "Appearance"))
        }

        Section {
          Picker(preferences.text("界面语言", "Language"), selection: $preferences.language) {
            Text(preferences.text("跟随系统", "System")).tag(AppLanguage.system)
            Text("简体中文").tag(AppLanguage.chinese)
            Text("English").tag(AppLanguage.english)
          }
          .pickerStyle(.segmented)
        } header: {
          Text(preferences.text("语言", "Language"))
        } footer: {
          Text(preferences.text(
            "外观立即生效。语言会先应用到这个 App 自己的菜单；系统菜单需要重启。",
            "Appearance applies immediately. Language updates this app's items now; the system menus need a restart."
          ))
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)

      // AppKit builds 编辑 / 显示 / 窗口 / 帮助 once per process, from the bundle's
      // localization, so the picker alone cannot relabel them. Say so instead of leaving
      // the user with a half-translated menu bar and no explanation.
      if preferences.needsRestartForLanguage {
        HStack(spacing: 10) {
          Image(systemName: "arrow.clockwise.circle")
            .foregroundStyle(.orange)
          Text(preferences.text(
            "重启 App 后，系统菜单也会切换到所选语言。",
            "Restart the app so the system menus switch to the selected language."
          ))
          .font(.caption)
          Spacer(minLength: 8)
          Button(preferences.text("立即重启", "Restart Now")) {
            preferences.restartToApplyLanguage()
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .padding(.horizontal, 22)
    .padding(.top, 20)
    .padding(.bottom, 12)
    .frame(width: 480)
  }
}
