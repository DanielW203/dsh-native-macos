import HarnessConsoleUI
import HarnessRuntime
import HarnessUI
import SwiftUI

/// The console, as a window of this app.
///
/// The surface itself lives in `HarnessConsoleUI`, next to the plugin window that shares
/// its model. This wrapper exists only to hand the surface a model built from the app's own
/// `RuntimePaths` and to mark it as embedded: the app's main window starts and stops the
/// harness, so the console's server controls say so rather than racing it for the port.
///
/// It also carries the workspace across the module boundary. `HarnessConsoleUI` knows the
/// *console*, not the app's main window, and deliberately cannot depend on `HarnessUI` (the
/// dependency runs the other way), so the choice is bridged here: the path goes in as a
/// value to display, the picker goes in as the act of asking. That keeps one owner of the
/// decision — the main window, which is also the model that persists it.
struct HarnessConsoleWindow: View {
  @ObservedObject var model: HarnessConsoleModel
  /// The main window's model: the only thing that owns and persists the workspace choice.
  @ObservedObject var workspace: HarnessWindowModel

  var body: some View {
    HarnessConsoleView(model: model)
      .onAppear {
        model.presentedAsEmbeddedWindow = true
        model.workspacePath = workspace.workspacePath
        model.chooseWorkspace = { [weak workspace] in workspace?.chooseWorkspace() }
        // Same bridge, same reason: the main window owns the server, so moving it to another
        // release is something only it can do. The console asks; the window acts.
        model.runUpgrade = { [weak workspace] id in
          guard let workspace else {
            return UpgradeReport(
              toReleaseID: id,
              outcome: .aborted,
              summary: "主窗口已关闭，本次更新未执行。"
            )
          }
          return await workspace.updateHarness(toReleaseID: id)
        }
      }
      // The main window can change the folder too (its own picker, from the "not running"
      // panel), so the console follows the model rather than reading it once.
      .onChange(of: workspace.workspacePath) { _, path in
        model.workspacePath = path
      }
  }
}
