import HarnessCore
import HarnessEmbedded
import HarnessKit
import HarnessUI
import SwiftUI

/// Route B app: the Swift re-implementation of the harness core, with the embedded
/// engine available for comparison.
///
/// The native engine is preferred at launch; the embedded engine stays registered so
/// the same session can be reopened through it from the engine switcher.
@main
struct NativeHarnessApp: App {
  @StateObject private var app: AppModel

  init() {
    let native = NativeHarnessEngine()
    let embedded = EmbeddedEngine()
    _app = StateObject(wrappedValue: AppModel(engines: [native, embedded], preferred: .native))
  }

  var body: some Scene {
    WindowGroup {
      HarnessShellView(app: app)
        .frame(minWidth: 900, minHeight: 600)
    }
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Session") {
          Task { _ = await app.createSession(cwd: FileManager.default.currentDirectoryPath) }
        }
        .keyboardShortcut("n", modifiers: [.command])
      }
    }

    Settings {
      SettingsView(app: app)
    }
  }
}
