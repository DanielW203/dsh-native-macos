import HarnessConsoleUI
import HarnessIM
import HarnessUI
import HarnessRuntime
import HarnessUI
import AppKit
import SwiftUI

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
  }

  /// The window the user thinks of as "the app".
  @MainActor
  static func mainWindow() -> NSWindow? {
    NSApp.windows.first { $0.title == "DeepSeek Harness" }
  }

  /// Set by the window scene so a restore can refresh the page that is already open.
  @MainActor static weak var mainModel: HarnessWindowModel?


  var body: some Scene {
    // The one window that owns the harness process. Single by identity on purpose: a
    // second owner would be a second server on one home.
    WindowGroup("DeepSeek Harness", id: HarnessWindowID.main) {
      HarnessWebWindow(model: model, banner: SafeModeBanner.make(safeBoot), channel: wechat)
        // The delegate needs the model to shut the harness down on quit, and the model
        // is created in init(), before the adaptor hands over the delegate instance.
        .onAppear {
          delegate.model = model
          DSHNativeApp.mainModel = model
          DSHNativeApp.harnessURL.value = model.url.flatMap(URL.init(string:))
          harnessPageHost.update(url: model.url, isRunning: model.isRunning)
          if let note = safeBoot.note { model.recordBootNote(note) }
          // The channel talks to a running harness on the user's behalf. In Safe Mode it
          // stays down on purpose: it is an outbound network client holding provider
          // credentials, and "start clean" has to mean that too.
          if DSHNativeApp.harnessURL.value != nil, !safeBoot.isSafe { wechat.harnessBecameAvailable() }
          Task { await alerts.refreshConnection() }
        }
        // The channel reads this on every submission, so it must follow start/stop.
        .onChange(of: model.url) { _, newValue in
          DSHNativeApp.harnessURL.value = newValue.flatMap(URL.init(string:))
          harnessPageHost.update(url: newValue, isRunning: model.isRunning)
          // The harness only accepts workspace registration once it is listening, so the
          // repair pass waits for this moment rather than racing the harness's startup.
          if DSHNativeApp.harnessURL.value != nil, !safeBoot.isSafe { wechat.harnessBecameAvailable() }
          Task { await alerts.refreshConnection() }
        }
        // Stopping the harness leaves the address in place while it is down, so the extra
        // windows need the phase too: without this they would keep showing a page whose
        // server has gone, instead of saying so.
        .onChange(of: model.isRunning) { _, isRunning in
          harnessPageHost.update(url: model.url, isRunning: isRunning)
        }
    }
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands {
      CommandGroup(replacing: .newItem) {}
      HarnessMenu(
        model: model,
        alerts: alerts,
        backup: backup,
        recovery: recovery,
        safeBoot: safeBoot,
        harnessPageHost: harnessPageHost
      )
    }

    // Every window in this group is a second view of the harness the main window started:
    // one server, one workspace, one session list, and as many surfaces as the user opens.
    // A group rather than a single window because asking for it twice must produce two
    // windows — which is the entire difference between this and raising the main one.
    //
    // Opening these windows is a menu action of its own, so the group itself is not a
    // destination; `CommandGroup(replacing: .newItem) {}` above is what keeps AppKit's
    // automatic File ▸ New Window from turning into a second front door for it.
    WindowGroup("DeepSeek Harness", id: HarnessWindowID.page) {
      HarnessPageWindow(host: harnessPageHost)
    }
    .defaultSize(width: 1180, height: 780)

    Window("待审批", id: HarnessWindowID.approvals) {
      ApprovalCenterWindow(model: alerts)
    }
    .defaultSize(width: 680, height: 520)

    Window("会话备份", id: HarnessWindowID.backup) {
      SessionBackupWindow(model: backup)
    }
    .defaultSize(width: 820, height: 620)

    Window("Plugins", id: HarnessWindowID.plugins) {
      HarnessPluginWindow(model: console)
    }
    .defaultSize(width: 900, height: 640)

    // Read-only, and deliberately its own window: it answers "does what is installed still
    // agree with this harness" while the Plugins window answers "what is installed", and
    // leaving both open must not make either one wrong.
    Window("Plugin Compatibility", id: HarnessWindowID.pluginCompatibility) {
      PluginCompatibilityWindow(model: console)
    }
    .defaultSize(width: 760, height: 620)

    Window("DSH Market", id: HarnessWindowID.market) {
      HarnessMarketWindow(harness: model)
    }
    .defaultSize(width: 1000, height: 700)

    Window("Harness Console", id: HarnessWindowID.console) {
      HarnessConsoleWindow(model: console, workspace: model)
    }
    .defaultSize(width: 980, height: 700)

    Window("WeChat Channel", id: HarnessWindowID.wechat) {
      WeChatChannelWindow(model: wechat)
    }
    .defaultSize(width: 660, height: 660)

    Window("恢复模式", id: HarnessWindowID.recovery) {
      HarnessRecoveryWindow(recovery: recovery, console: console)
        // The app's main window owns the server's lifecycle; this window manages the
        // runtime and a profile's plugins, so it says so rather than racing it for the port.
        .onAppear { console.presentedAsEmbeddedWindow = true }
    }
    .defaultSize(width: 900, height: 680)
  }
}

/// The Harness menu: the extra windows, plus the actions that act on the running
/// harness.
///
/// A Commands value rather than inline buttons because opening a window needs the
/// openWindow action from the environment, which only a Commands or View type can read.
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

  var body: some Commands {
    CommandMenu("Harness") {
      // First, because it is the one item here that makes more of the app rather than a
      // different part of it: another window onto the harness that is already running.
      Button("New Window…") {
        openWindow(id: HarnessWindowID.page)
      }
      .keyboardShortcut("n", modifiers: [.command, .option])
      .help("Open another window onto this same harness, to watch a second page at the same time")
      // The main window owns the server, so with nothing running there is no page to
      // attach to — and a second window never starts one of its own.
      .disabled(!harnessPageHost.isRunning)

      Divider()

      Button("Plugin…") {
        openWindow(id: HarnessWindowID.plugins)
      }
      .keyboardShortcut("p", modifiers: [.command, .shift])

      Button("Plugin Compatibility…") {
        openWindow(id: HarnessWindowID.pluginCompatibility)
      }
      .keyboardShortcut("p", modifiers: [.command, .option])

      // No "DSH Market…" item: the market window scene below is kept for a future entry
      // point, but the menu no longer offers it.

      Button("Harness Console…") {
        openWindow(id: HarnessWindowID.console)
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])

      Button("WeChat Channel…") {
        openWindow(id: HarnessWindowID.wechat)
      }
      .keyboardShortcut("w", modifiers: [.command, .shift])
      // The channel is an outbound client to the provider holding stored credentials.
      // Safe Mode is meant to take things out of the picture, so it stays down.
      .disabled(safeBoot.isSafe)

      Divider()

      Button("恢复模式…") {
        openWindow(id: HarnessWindowID.recovery)
      }
      .keyboardShortcut("r", modifiers: [.command, .option])

      Button("以安全模式重启（无插件）") {
        Task { await recovery.selectMode(.rescue) }
      }
      .disabled(safeBoot.mode == .rescue || recovery.isBusy)

      Button("以干净环境重启") {
        Task { await recovery.selectMode(.cleanHome) }
      }
      .disabled(safeBoot.mode == .cleanHome || recovery.isBusy)

      if safeBoot.isSafe {
        Button("退出安全模式并重启") {
          Task { await recovery.selectMode(nil) }
        }
        .disabled(recovery.isBusy)
      }

      Divider()

      Button(alerts.pending.isEmpty ? "待审批…" : "待审批（\(alerts.pending.count)）…") {
        openWindow(id: HarnessWindowID.approvals)
      }
      .keyboardShortcut("a", modifiers: [.command, .shift])

      Button("会话备份…") {
        openWindow(id: HarnessWindowID.backup)
      }
      .keyboardShortcut("b", modifiers: [.command, .shift])

      Button("导出全部对话日志…") {
        backup.exportAllWithPanel()
      }

      Divider()

      Button("Reload Harness UI") { model.reload() }
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(!model.isRunning)

      Button("Open in Browser") { model.openInBrowser() }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(!model.isRunning)

      Divider()

      // The recovery entry point sits in the menu as well as on the failure panel: the
      // window it belongs to can be buried under others, and a repair reachable only from
      // the screen that is broken is not a repair.
      Button("Disable Broken Plugins and Retry") {
        Task { await model.quarantineAndRestart() }
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(model.isBusy)
    }
  }
}
