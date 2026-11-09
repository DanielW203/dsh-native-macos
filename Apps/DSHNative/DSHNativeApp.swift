import HarnessConsoleUI
import HarnessIM
import HarnessMobileGateway
import HarnessSkills
import HarnessUI
import HarnessRuntime
import HarnessUI
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app: the harness Web UI in the native window that owns the server, plus the windows
/// opened from the menu bar — more views of the same harness, the plugin window, DSH
/// Market, the harness console, and the recovery window.
@main
struct DSHNativeApp: App {
  @NSApplicationDelegateAdaptor(HarnessWindowDelegate.self) private var delegate
  @StateObject private var model: HarnessWindowModel
  @StateObject private var console: HarnessConsoleModel
  @StateObject private var recovery: HarnessRecoveryModel
  /// The WeChat channel runs for the life of the app, not for the life of its window: a bot
  /// that only polls while a window is open would drop messages the user sent from a phone.
  @StateObject private var wechat: WeChatChannelModel
  /// Approvals outlive the window like the channel does: a notification that only worked
  /// while the approval centre was open would never be seen.
  @StateObject private var alerts: ApprovalAlertModel
  @StateObject private var backup: SessionBackupModel
  /// The skin manager. App-level rather than built by its window: the window it is shown in
  /// is one of several, and a switch must survive that window being closed and reopened —
  /// the reload offer it holds belongs to the session, not to the view.
  @StateObject private var skins: SkinManagerModel
  /// The native mobile gateway. App-level like the channel below: a gateway that only ran while
  /// its window was open would drop the phone mid-turn.
  @StateObject private var mobileGateway: MobileGatewayModel
  /// The skill centre. App-level for the same reason as the skins: the file it edits belongs to
  /// the harness home, and the workspace it scans is the one the main window chose, so a copy
  /// owned by the window would be stale the moment the window was reopened.
  @StateObject private var skills: SkillCenterModel
  /// The startup animation. App-level like the skins: it is chosen from the menu bar while the
  /// main window may not exist, and the launch-time decision must be its own, made once.
  @StateObject private var startup: StartupAnimationModel
  /// The built-in launch experience. App-level for the same reason: the menu bar can toggle
  /// or preview it while the main window is closed, and it presents once per process.
  @StateObject private var startupExperience: StartupExperienceModel
  /// Appearance and language. App-level because the menu bar and every window title read it,
  /// and because the settings pane has to apply a change to windows that are already open.
  @StateObject private var preferences: AppPreferences
  /// The rebuild sheet's state. App-level now that the command lives in the menu bar: the
  /// sheet is still presented by the main window, but the button that fills it no longer is.
  @StateObject private var rebuild: RebuildModel
  /// The running harness as the extra windows see it. The main window publishes the
  /// address here; every other window reads it, so no second window starts a server.
  @StateObject private var harnessPageHost = HarnessPageHost()
  /// Which home and profile this launch resolved to, decided before any model exists.
  private let safeBoot: SafeBootResolution
  /// Bridges the running harness URL (owned by the window model) to the channel's actors.
  private static let harnessURL = SharedValue<URL?>(nil)

  init() {
    let base: RuntimePaths
    do {
      base = try RuntimePaths.standard()
    } catch {
      // A missing application-support directory is not recoverable at launch and not
      // worth crashing over: fall back to a temporary root so the window can open and
      // report the problem rather than the app dying before it draws anything.
      base = RuntimePaths(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeHarness", isDirectory: true))
    }

    // Resolved before anything else touches a path: the harness home has to be correct from
    // the first spawn, and a model built against the wrong one would have to be torn down to
    // fix it. The marker also clears a Safe Mode environment a crash left behind.
    let boot = SafeBoot.resolve(base)
    safeBoot = boot

    // Before any scene reads them: the saved language decides the first menu bar this app
    // draws, and the saved appearance has to be in place before AppKit paints a window.
    _preferences = StateObject(wrappedValue: AppPreferences.shared)
    _rebuild = StateObject(wrappedValue: RebuildModel())

    // The one thing the runtime layer cannot do for itself: relaunch the app. The upgrade
    // ladder's last resort is "start without plugins", which is a Safe Mode marker plus a
    // restart, and only this type owns the lifecycle to perform it.
    HarnessAppHooks.shared.installRestart {
      DSHNativeApp.mainModel?.restartApplication()
    }

    // One factory so the launcher, the plugin repairer, and the Node provisioner all
    // resolve the same release and the same home: a repair run against a different runtime
    // than the one that failed would be answering another question.
    _model = StateObject(wrappedValue: HarnessWindowModel.standard(
      paths: boot.paths,
      profile: boot.profile,
      logFileURL: boot.paths.harnessRoot.appendingPathComponent("logs/window.log")
    ))
    // Management surfaces always act on the real tree — the console, the plugin windows, the
    // session archive and the recovery window all name `base`. Only the harness process is
    // pointed at a disposable home, and repairing the throwaway one would answer nothing.
    _console = StateObject(wrappedValue: HarnessConsoleModel(paths: base))
    // The same rule as the console: manage the real tree even in Safe Mode. A skin chosen
    // while the harness runs against a disposable home has to still be chosen when that
    // home is deleted, so this reads and writes `base` — never `boot.paths`.
    let skinManager = SkinManagerModel(paths: base, profile: boot.profile)
    // The page that has to be reloaded belongs to the main window, which does not exist yet
    // when this closure is built — so it is reached through the static handle, exactly as
    // the recovery window reaches the harness's start/stop.
    skinManager.onReloadPage = { DSHNativeApp.mainModel?.reload() }
    _skins = StateObject(wrappedValue: skinManager)
    // Same rule as the skins: this manages the real tree even in Safe Mode, because a skill
    // edited while the harness runs against a disposable home has to still be edited when that
    // home is deleted. The workspace is read through defaults rather than the window model for
    // the same reason `wechat` does: this runs during app init, before `model` is assigned, and
    // the key is exactly what the main window persists when a folder is chosen.
    _skills = StateObject(wrappedValue: SkillCenterModel(
      dshHome: base.dshHome,
      workspaceProvider: {
        UserDefaults.standard.string(forKey: HarnessWindowModel.workspaceDefaultsKey)
          .map { URL(fileURLWithPath: $0, isDirectory: true) }
      },
      fallbackWorkspace: URL(fileURLWithPath: HarnessWindowModel.defaultWorkspace, isDirectory: true)
    ))
    // The real root even in Safe Mode: the animation is about the app, not the profile being
    // booted, and the copy it plays must survive the disposable home being deleted.
    _startup = StateObject(wrappedValue: StartupAnimationModel(root: base.root))
    _startupExperience = StateObject(wrappedValue: StartupExperienceModel())
    let recoveryInstaller = HarnessInstaller(paths: base)
    let recoveryEntry: @Sendable () async throws -> URL = { try await recoveryInstaller.activeEntryURL() }
    _recovery = StateObject(wrappedValue: HarnessRecoveryModel(
      base: base,
      boot: boot,
      marking: SafeBootMarker(base: base),
      checkpoints: ProfileCheckpointStore(paths: base),
      rescueInstaller: RescueProfileInstaller(paths: base, entryProvider: recoveryEntry),
      // Resolved through the static handle rather than captured: the window model does not
      // exist yet when this closure is built, and the window it belongs to is the only thing
      // that owns the server's lifecycle.
      stopHarness: { await DSHNativeApp.mainModel?.stop() },
      restartApp: { DSHNativeApp.mainModel?.restartApplication() }
    ))
    let channelService = WeChatChannelService(
      appRoot: base.root,
      harnessURL: { DSHNativeApp.harnessURL.value },
      // The real home even in Safe Mode: the channel is never started there, and pointing it
      // at a disposable home would leave its stored session mapping behind when that home is
      // deleted.
      dshHome: { base.dshHome }
    )
    // Held in a local because two owners need it: the scene's `StateObject`, and the alert model
    // below, which forwards finished turns to the phone through it.
    let channelModel = WeChatChannelModel(
      service: channelService,
      initialConfig: ChannelConfig(),
      // Read through defaults rather than the window model: this runs during app init, before
      // `model` is fully assigned, and the key is exactly what `chooseWorkspace()` persists.
      appWorkspace: {
        UserDefaults.standard.string(forKey: HarnessWindowModel.workspaceDefaultsKey)
          ?? HarnessWindowModel.defaultWorkspace
      }
      // (evaluated on the main actor: the app's init is main-actor isolated, which is where
      //  `defaultWorkspace` is reachable from)
    )
    _wechat = StateObject(wrappedValue: channelModel)

    // The notification delegate must be in place before the app finishes launching, or
    // macOS drops the actions of every notification button — so the presenter is built
    // here, during init, rather than when the window first appears.
    let presenter = SystemApprovalPresenter()
    let alerts = ApprovalAlertModel(
      urlProvider: { DSHNativeApp.harnessURL.value },
      presenter: presenter
    )
    // Wired here rather than inside either model: the phone is the channel's business and the
    // "which endings are news" judgement is the alert model's, and neither should have to know the
    // other to be testable. Both are built in this initializer, so this is the one place that has
    // both. Nothing is sent unless 手机远控 is switched on.
    alerts.phoneForwarder = channelModel
    alerts.onOpenAlert = { _ in
      // A click on the notification body: come to the front and show the page that owns
      // the request. The reload is what makes the Web UI re-read the session list rather
      // than showing whatever it was showing when the app was last used.
      NSApp.activate(ignoringOtherApps: true)
      DSHNativeApp.mainWindow()?.makeKeyAndOrderFront(nil)
    }
    _alerts = StateObject(wrappedValue: alerts)

    // The backup window works with the harness stopped on purpose: a restore is most
    // often needed exactly when something is wrong. `onImported` only refreshes the open
    // page, because the harness enumerates its sessions directory on every list call.
    // It is pointed at the real home even in Safe Mode: restoring the user's sessions is
    // one of the things recovery is for, and the disposable home has none to restore.
    _backup = StateObject(wrappedValue: SessionBackupModel(
      dshHome: base.dshHome,
      stagingRoot: base.stagingRoot,
      onImported: { DSHNativeApp.mainModel?.reload() }
    ))

    // Built here, not in the window: the gateway binds its listener and holds the paired-device
    // registry for the life of the app, and a window that owned it would stop accepting phone
    // connections the moment the user closed the panel.
    _mobileGateway = StateObject(wrappedValue: MobileGatewayModel(
      appRoot: base.root,
      harnessURL: { DSHNativeApp.harnessURL.value }
    ))
  }

  /// The window the user thinks of as "the app".
  ///
  /// Matched on the current title and the one it shipped with: `mainWindow()` is called by
  /// the menu bar and the recovery flow, and an update that renames the window while the
  /// running process still carries the old one must not make both release paths go blind.
  @MainActor
  static func mainWindow() -> NSWindow? {
    NSApp.windows.first {
      $0.title == AppBrand.name || $0.title == AppBrand.legacyWindowTitle
    }
  }

  /// Set by the window scene so a restore can refresh the page that is already open.
  @MainActor static weak var mainModel: HarnessWindowModel?


  var body: some Scene {
    // The one window that owns the harness process. Single by identity on purpose: a
    // second owner would be a second server on one home.
    WindowGroup(AppBrand.name, id: HarnessWindowID.main) {
      HarnessWebWindow(
        model: model,
        banner: SafeModeBanner.make(safeBoot),
        startup: startup,
        startupExperience: startupExperience,
        preferences: preferences,
        rebuild: rebuild
      )
        // The delegate needs the model to shut the harness down on quit, and the model
        // is created in init(), before the adaptor hands over the delegate instance.
        .onAppear {
          delegate.model = model
          DSHNativeApp.mainModel = model
          // Re-assert the saved appearance once AppKit has a running application: some
          // launches reset `NSApp.appearance` after the initializer has set it.
          preferences.applyAppearance()
          DSHNativeApp.harnessURL.value = model.url.flatMap(URL.init(string:))
          harnessPageHost.update(url: model.url, isRunning: model.isRunning)
          if let note = safeBoot.note { model.recordBootNote(note) }
          // The channel talks to a running harness on the user's behalf. In Safe Mode it
          // stays down on purpose: it is an outbound network client holding provider
          // credentials, and "start clean" has to mean that too.
          if DSHNativeApp.harnessURL.value != nil, !safeBoot.isSafe { wechat.harnessBecameAvailable() }
          mobileGateway.harnessBecameAvailable()
          Task {
            await alerts.refreshConnection()
            // Ask once, at a moment the user is looking at the app. Completion banners
            // cannot appear before this process has notification permission, and the
            // old flow only asked after an approval happened to arrive.
            await alerts.requestNotificationAuthorization()
          }
        }
        // The channel reads this on every submission, so it must follow start/stop.
        .onChange(of: model.url) { _, newValue in
          DSHNativeApp.harnessURL.value = newValue.flatMap(URL.init(string:))
          harnessPageHost.update(url: newValue, isRunning: model.isRunning)
          // The harness only accepts workspace registration once it is listening, so the
          // repair pass waits for this moment rather than racing the harness's startup.
          if DSHNativeApp.harnessURL.value != nil, !safeBoot.isSafe { wechat.harnessBecameAvailable() }
          // A harness restart means a new port and a new single-use token, so the gateway's
          // API client has to be rebuilt rather than left pointed at a dead address.
          mobileGateway.harnessBecameAvailable()
          Task { await alerts.refreshConnection() }
        }
        // Stopping the harness leaves the address in place while it is down, so the extra
        // windows need the phase too: without this they would keep showing a page whose
        // server has gone, instead of saying so.
        .onChange(of: model.isRunning) { _, isRunning in
          harnessPageHost.update(url: model.url, isRunning: isRunning)
        }
        // The red close button is retargeted on the window that actually hosts this view,
        // rather than looked up by title: the title can be localized, and a lookup can run
        // before SwiftUI has set it.
        .background(MainWindowCloseGuard { window in
          delegate.attachCloseGuard(to: window)
        })
    }
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands {
      CommandGroup(replacing: .newItem) {}
      // Replaces AppKit's own "Settings…" entry rather than adding a second one: the label
      // has to follow the in-app language, and the automatic item follows the system's.
      CommandGroup(replacing: .appSettings) {
        SettingsMenuItem(preferences: preferences)
      }
      HarnessMenu(
        model: model,
        alerts: alerts,
        backup: backup,
        recovery: recovery,
        safeBoot: safeBoot,
        harnessPageHost: harnessPageHost,
        startup: startup,
        startupExperience: startupExperience,
        wechat: wechat,
        preferences: preferences,
        rebuild: rebuild
      )
    }

    // A Window scene rather than SwiftUI's Settings scene. `Settings` injects its own
    // app-menu item, which appeared as a second "Settings…" beside the localized one; a plain
    // window leaves exactly one item, the one replaced above, and ⌘, still opens this.
    Window(preferences.text("设置", "Settings"), id: HarnessWindowID.settings) {
      AppSettingsView(preferences: preferences)
    }
    .defaultSize(width: 480, height: 420)

    // Every window in this group is a second view of the harness the main window started:
    // one server, one workspace, one session list, and as many surfaces as the user opens.
    // A group rather than a single window because asking for it twice must produce two
    // windows — which is the entire difference between this and raising the main one.
    //
    // Opening these windows is a menu action of its own, so the group itself is not a
    // destination; `CommandGroup(replacing: .newItem) {}` above is what keeps AppKit's
    // automatic File ▸ New Window from turning into a second front door for it.
    WindowGroup(AppBrand.name, id: HarnessWindowID.page) {
      HarnessPageWindow(host: harnessPageHost)
    }
    .defaultSize(width: 1180, height: 780)

    Window(preferences.text("待审批", "Approvals"), id: HarnessWindowID.approvals) {
      ApprovalCenterWindow(model: alerts)
    }
    .defaultSize(width: 680, height: 520)

    Window(preferences.text("会话备份", "Session Backup"), id: HarnessWindowID.backup) {
      SessionBackupWindow(model: backup)
    }
    .defaultSize(width: 820, height: 620)

    Window(preferences.text("插件", "Plugins"), id: HarnessWindowID.plugins) {
      HarnessPluginWindow(
        model: console,
        // Read only when the boot actually blamed something: `quarantinedPlugins()` reads the
        // profile's manifest, and this scene body is evaluated on every language change too.
        bootProblems: model.bootPluginProblems,
        quarantined: model.isDegraded ? model.quarantinedPlugins().map(\.name) : [],
        bootTitle: preferences.text(
          "这个版本下没有加载上的插件（\(model.bootPluginProblems.count)）",
          "Plugins that did not load in this version (\(model.bootPluginProblems.count))"
        ),
        restoreTitle: preferences.text("恢复并重试", "Restore and Retry"),
        onRestore: model.isDegraded
          ? { Task { await model.restoreQuarantinedPluginsAndRetry() } }
          : nil
      )
    }
    .defaultSize(width: 900, height: 640)

    // Read-only, and deliberately its own window: it answers "does what is installed still
    // agree with this harness" while the Plugins window answers "what is installed", and
    // leaving both open must not make either one wrong.
    Window(preferences.text("插件兼容性", "Plugin Compatibility"), id: HarnessWindowID.pluginCompatibility) {
      PluginCompatibilityWindow(model: console)
    }
    .defaultSize(width: 760, height: 620)

    // Its own window, and reachable from the Harness menu. A skin changes the page the Web
    // UI *is*, so the control for it cannot live inside that page: the skin that renders
    // wrong is exactly the one a user needs to switch away from.
    Window(preferences.text("皮肤管理器", "Skin Manager"), id: HarnessWindowID.skinManager) {
      SkinManagerWindow(model: skins)
    }
    .defaultSize(width: 840, height: 640)

    // The skill centre. Another window the menu bar owns, and another surface that has to work
    // while the Web UI is the thing that is broken — its subject is files the harness loads, not
    // the page it renders.
    Window(preferences.text("技能中心", "Skill Center"), id: HarnessWindowID.skillCenter) {
      SkillCenterWindow(model: skills)
    }
    .defaultSize(width: 940, height: 680)

    Window("DSH Market", id: HarnessWindowID.market) {
      HarnessMarketWindow(harness: model)
    }
    .defaultSize(width: 1000, height: 700)

    Window(preferences.text("Harness 控制台", "Harness Console"), id: HarnessWindowID.console) {
      HarnessConsoleWindow(model: console, workspace: model)
    }
    .defaultSize(width: 980, height: 700)

    Window(preferences.text("微信通道", "WeChat Channel"), id: HarnessWindowID.wechat) {
      WeChatChannelWindow(model: wechat)
    }
    .defaultSize(width: 660, height: 660)

    // Its own window, and reachable from the Harness menu: the gateway has to keep serving
    // while this is closed, and pairing happens while the user is holding a phone — not while
    // they are looking at a transcript.
    Window(preferences.text("移动设备", "Mobile Devices"), id: HarnessWindowID.mobileGateway) {
      MobileGatewayWindow(model: mobileGateway)
        .onAppear { mobileGateway.harnessBecameAvailable() }
    }
    .defaultSize(width: 640, height: 700)

    Window(preferences.text("恢复模式", "Recovery Mode"), id: HarnessWindowID.recovery) {
      HarnessRecoveryWindow(recovery: recovery, console: console)
        // The app's main window owns the server's lifecycle; this window manages the
        // runtime and a profile's plugins, so it says so rather than racing it for the port.
        .onAppear { console.presentedAsEmbeddedWindow = true }
    }
    .defaultSize(width: 900, height: 680)
  }
}

/// The app's own menus: the extra windows, the management surfaces, and the actions that
/// act on the running harness.
///
/// A Commands value rather than inline buttons because opening a window needs the
/// openWindow action from the environment, which only a Commands or View type can read.
///
/// Four top-level menus, split by what an item acts on:
///
/// - **运行 / Harness** — the server's lifecycle, the page in front of it, and the app process.
/// - **插件 / Plugins** — local extensions (plugins, skins, skills) and the ways a phone
///   reaches this machine (WeChat channel, mobile gateway, phone remote control), because
///   they are all "things plugged into this harness".
/// - **会话 / Sessions** — approvals, the session archive, and exporting transcripts.
/// - **维护 / Maintenance** — the console, recovery, safe-boot modes and the launch animation.
///
/// Every label goes through `preferences.text(_:_:)`, so switching language in Settings
/// relabels the menu bar without a relaunch. Every shortcut and disabled condition is the
/// one the old single menu had, except where two items had collided.
private struct HarnessMenu: Commands {
  @Environment(\.openWindow) private var openWindow
  let model: HarnessWindowModel
  let alerts: ApprovalAlertModel
  let backup: SessionBackupModel
  let recovery: HarnessRecoveryModel
  /// Which mode this launch resolved to, for the Safe Mode items and the channel gating.
  let safeBoot: SafeBootResolution
  /// The address the extra windows attach to. Read for its `isRunning`, so the open action
  /// can be disabled while there is nothing to show.
  @ObservedObject var harnessPageHost: HarnessPageHost
  /// The startup video: its switch, its preview, and the file picker all live here because
  /// the main window may not be open when the user changes them.
  @ObservedObject var startup: StartupAnimationModel
  /// The built-in launch experience. Its switch and preview live here for the same reason.
  @ObservedObject var startupExperience: StartupExperienceModel
  /// The channel whose phone-remote switch used to be a button in the window toolbar.
  @ObservedObject var wechat: WeChatChannelModel
  /// Appearance and language. Observed rather than read once: a language change has to
  /// rebuild this menu bar, and a `Commands` value that captured a string would not.
  @ObservedObject var preferences: AppPreferences
  /// The rebuild sheet, now opened from here.
  @ObservedObject var rebuild: RebuildModel

  var body: some Commands {
    harnessMenu
    pluginsMenu
    sessionsMenu
    maintenanceMenu
  }

  private func t(_ chinese: String, _ english: String) -> String {
    preferences.text(chinese, english)
  }

  /// A `Toggle` in a menu drives its binding with the *new* value, so this compares before
  /// toggling: the channel's only operation is "flip", and calling it twice would cancel.
  private var phoneRemoteBinding: Binding<Bool> {
    Binding(
      get: { wechat.forwardsAllPrompts },
      set: { newValue in
        guard newValue != wechat.forwardsAllPrompts else { return }
        wechat.toggleForwardsAllPrompts()
      }
    )
  }

  private func presentRebuild() {
    NSApp.activate(ignoringOtherApps: true)
    rebuild.present()
  }

  // MARK: - 运行 / Harness

  private var harnessMenu: some Commands {
    CommandMenu(t("运行", "Harness")) {
      // First, because it is the one item here that makes more of the app rather than a
      // different part of it: another window onto the harness that is already running.
      Button(t("新建窗口…", "New Window…")) {
        openWindow(id: HarnessWindowID.page)
      }
      .keyboardShortcut("n", modifiers: [.command, .option])
      .help(t(
        "再开一个窗口看同一个 Harness，两页可以同时看着",
        "Open another window onto this same harness, to watch a second page at the same time"
      ))
      // The main window owns the server, so with nothing running there is no page to
      // attach to — and a second window never starts one of its own.
      .disabled(!harnessPageHost.isRunning)

      Divider()

      Button(t("重新载入页面", "Reload Harness UI")) { model.reload() }
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(!model.isRunning)

      Button(t("在浏览器中打开", "Open in Browser")) { model.openInBrowser() }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .help(t(
          "在默认浏览器里打开同一个会话",
          "Open the same session in your default browser"
        ))
        .disabled(!model.isRunning)

      if model.isRunning {
        Button(t("停止 Harness", "Stop Harness")) {
          Task { await model.stop() }
        }
        .disabled(model.isBusy)
      } else {
        Button(t("启动 Harness", "Start Harness")) {
          Task { await model.start() }
        }
        .disabled(model.isBusy)
      }

      Divider()

      // App-process actions, not server actions: both quit this process and come back to a
      // fresh one, which is why they sit last in this menu rather than beside Stop.
      Button(t("重启 App", "Restart App")) { model.restartApplication() }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help(t(
          "退出并重新打开这个 App，让 Harness 从头启动",
          "Quit and reopen this app, so the harness starts fresh"
        ))

      Button(t("重新编译并重启…", "Rebuild App…")) { presentRebuild() }
        .help(t(
          "从源码目录重新编译 DSHNative，然后退出并重新打开已安装的 App",
          "Rebuild DSHNative from its source checkout, then quit and reopen the installed app"
        ))
    }
  }

  // MARK: - 插件 / Plugins

  private var pluginsMenu: some Commands {
    CommandMenu(t("插件", "Plugins")) {
      // Local extensions first: what the profile loads, then what changes how the page looks,
      // then what the model can call.
      Button(t("插件…", "Plugins…")) {
        openWindow(id: HarnessWindowID.plugins)
      }
      .keyboardShortcut("p", modifiers: [.command, .shift])

      Button(t("插件兼容性…", "Plugin Compatibility…")) {
        openWindow(id: HarnessWindowID.pluginCompatibility)
      }
      .keyboardShortcut("p", modifiers: [.command, .option])

      // Right beside the plugin windows, because that is what it is: a profile-level plugin
      // concern this app took over from a web plugin, so that it keeps working on a page no
      // skin has rendered correctly yet.
      Button(t("皮肤管理器…", "Skin Manager…")) {
        openWindow(id: HarnessWindowID.skinManager)
      }
      .keyboardShortcut("k", modifiers: [.command, .shift])
      .help(t(
        "安装、切换、停用 Web UI 皮肤（替代 dsh-skin-manager 插件）",
        "Install, switch, or disable Web UI skins (replaces the dsh-skin-manager plugin)"
      ))

      // Next to the skins for the same reason: skills are files in the harness home, and having
      // them in the menu bar means they can be fixed without a working page.
      Button(t("技能中心…", "Skill Center…")) {
        openWindow(id: HarnessWindowID.skillCenter)
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .help(t(
        "管理技能：可调用状态（模型 / 手动）、新建、导入、删除到回收站",
        "Manage skills: invocation mode (model / manual), create, import, or delete to the Trash"
      ))

      Divider()

      // The ways a phone reaches this machine. Grouped together, and with the plugins, because
      // "WeChat console" is one of the things plugged into the harness rather than a session
      // action — the same reason the plugins are here.
      Toggle(isOn: phoneRemoteBinding) {
        if wechat.pendingPromptCount > 0 {
          Text(t(
            "手机远控（\(wechat.pendingPromptCount) 条待回答）",
            "Phone Remote Control (\(wechat.pendingPromptCount) waiting)"
          ))
        } else {
          Text(t("手机远控", "Phone Remote Control"))
        }
      }
      .disabled(!wechat.canForwardPromptsToPhone)
      .help(wechat.phoneControlHelp)

      Button(t("微信通道…", "WeChat Channel…")) {
        openWindow(id: HarnessWindowID.wechat)
      }
      .keyboardShortcut("w", modifiers: [.command, .shift])
      // The channel is an outbound client to the provider holding stored credentials.
      // Safe Mode is meant to take things out of the picture, so it stays down.
      .disabled(safeBoot.isSafe)

      Button(t("移动设备…", "Mobile Devices…")) {
        openWindow(id: HarnessWindowID.mobileGateway)
      }
      .keyboardShortcut("m", modifiers: [.command, .shift])
      // Same reasoning as the channel: the gateway accepts connections from the network and
      // executes work on this machine, which is exactly what Safe Mode removes.
      .disabled(safeBoot.isSafe)
    }
  }

  // MARK: - 会话 / Sessions

  private var sessionsMenu: some Commands {
    CommandMenu(t("会话", "Sessions")) {
      Button(
        alerts.pending.isEmpty
          ? t("待审批…", "Approvals…")
          : t("待审批（\(alerts.pending.count)）…", "Approvals (\(alerts.pending.count))…")
      ) {
        openWindow(id: HarnessWindowID.approvals)
      }
      .keyboardShortcut("a", modifiers: [.command, .shift])

      Divider()

      Button(t("会话备份…", "Session Backup…")) {
        openWindow(id: HarnessWindowID.backup)
      }
      .keyboardShortcut("b", modifiers: [.command, .shift])

      Button(t("导出全部对话日志…", "Export All Chat Logs…")) {
        backup.exportAllWithPanel()
      }
    }
  }

  // MARK: - 维护 / Maintenance

  private var maintenanceMenu: some Commands {
    CommandMenu(t("维护", "Maintenance")) {
      // Runtime management (install, update, rollback) and the recovery surfaces answer one
      // question — what this machine runs, and how to get it back when it will not run — so
      // they share a menu rather than being scattered through the window lists.
      Button(t("Harness 控制台…", "Harness Console…")) {
        openWindow(id: HarnessWindowID.console)
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])

      Divider()

      Button(t("恢复模式…", "Recovery Mode…")) {
        openWindow(id: HarnessWindowID.recovery)
      }
      .keyboardShortcut("r", modifiers: [.command, .option])

      Button(t("以安全模式重启（无插件）", "Restart in Safe Mode (No Plugins)")) {
        Task { await recovery.selectMode(.rescue) }
      }
      .disabled(safeBoot.mode == .rescue || recovery.isBusy)

      Button(t("以干净环境重启", "Restart with a Clean Home")) {
        Task { await recovery.selectMode(.cleanHome) }
      }
      .disabled(safeBoot.mode == .cleanHome || recovery.isBusy)

      if safeBoot.isSafe {
        Button(t("退出安全模式并重启", "Leave Safe Mode and Restart")) {
          Task { await recovery.selectMode(nil) }
        }
        .disabled(recovery.isBusy)
      }

      // The recovery entry point sits in the menu as well as on the failure panel: the
      // window it belongs to can be buried under others, and a repair reachable only from
      // the screen that is broken is not a repair.
      Button(t("停用故障插件并重试", "Disable Broken Plugins and Retry")) {
        Task { await model.quarantineAndRestart() }
      }
      .disabled(model.isBusy)

      Divider()

      Menu(t("启动动画", "Launch Animation")) {
        Toggle(t("播放内置启动动画", "Play Built-in Launch Animation"), isOn: Binding(
          get: { startupExperience.isEnabled },
          set: { startupExperience.setEnabled($0) }
        ))

        Button(t("预览内置启动动画", "Preview Built-in Launch Animation")) { presentBuiltInPreview() }

        Button(t("跳过启动动画", "Skip Launch Animation")) { startupExperience.dismiss() }
          .disabled(!startupExperience.isPresenting)

        Divider()

        // The custom video is an explicit override, not the default. Its labels say so,
        // because two switches both called "启动动画" are indistinguishable in a menu.
        Toggle(t("启用自定义视频", "Use Custom Video"), isOn: Binding(
          get: { startup.isEnabled },
          set: { startup.setEnabled($0) }
        ))
        .disabled(!startup.hasVideo)

        Button(t("选择视频…", "Choose Video…")) { chooseStartupVideo() }
          .help(t(
            "选一段本地视频，复制进 App 自己的目录；下次打开 App 时播放",
            "Pick a local video, copy it into the app's own folder, and play it the next time the app opens"
          ))

        Button(t("预览自定义视频", "Preview Custom Video")) { presentStartupPreview() }
          .disabled(!startup.hasVideo)

        Button(t("移除视频", "Remove Video")) { startup.removeVideo() }
          .disabled(!startup.hasVideo)

        Button(t("在 Finder 中显示", "Show in Finder")) { revealStartupVideo() }
          .disabled(!startup.hasVideo)
      }
    }
  }

  // MARK: - Startup animation actions

  /// Pick a video, copy it into the app's tree, and show it immediately: a choice the user
  /// cannot see is indistinguishable from one that was not accepted.
  private func chooseStartupVideo() {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.movie]
    panel.message = t("选择一段打开 App 时播放的视频", "Choose a video to play when the app opens")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { @MainActor in
      do {
        try await startup.chooseVideo(from: url)
        presentStartupPreview()
      } catch {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("无法使用这段视频", "That video could not be used")
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        alert.runModal()
      }
    }
  }

  /// Raise the window the overlay lives in, then ask for the preview.
  ///
  /// Opening the main window scene here would be a second owner of the same server, so a
  /// closed main window means no preview — logged rather than silently ignored.
  private func presentStartupPreview() {
    NSApp.activate(ignoringOtherApps: true)
    guard let window = DSHNativeApp.mainWindow() else {
      model.recordBootNote(t(
        "启动动画预览需要主窗口；当前没有打开的主窗口。",
        "The launch animation preview needs the main window, and none is open."
      ))
      return
    }
    window.makeKeyAndOrderFront(nil)
    startupExperience.dismiss()
    startup.presentPreview()
  }

  /// Raise the main window and play the built-in experience with its scripted preview data.
  /// The preview ignores the launch switch, so it can be reviewed before committing to it.
  private func presentBuiltInPreview() {
    NSApp.activate(ignoringOtherApps: true)
    guard let window = DSHNativeApp.mainWindow() else {
      model.recordBootNote(t(
        "内置启动动画预览需要主窗口；当前没有打开的主窗口。",
        "The built-in launch animation preview needs the main window, and none is open."
      ))
      return
    }
    window.makeKeyAndOrderFront(nil)
    startup.dismiss()
    startupExperience.presentPreview()
  }

  private func revealStartupVideo() {
    guard let url = startup.videoURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}


/// Hands the main window to the delegate once SwiftUI has put this view in it.
///
/// A representable rather than `NSApp.windows.first`: at `onAppear` the window has no title
/// yet, and a one-shot lookup that misses leaves the close button unguarded for the whole
/// session.
private struct MainWindowCloseGuard: NSViewRepresentable {
  let install: (NSWindow) -> Void

  func makeNSView(context: Context) -> WindowReaderView {
    let view = WindowReaderView()
    view.onWindow = install
    return view
  }

  func updateNSView(_ view: WindowReaderView, context: Context) {
    view.onWindow = install
    if let window = view.window { install(window) }
  }
}

private final class WindowReaderView: NSView {
  var onWindow: ((NSWindow) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window { onWindow?(window) }
  }
}
