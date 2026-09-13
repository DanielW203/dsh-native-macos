import Foundation

/// Window identifiers, in one place because two targets need them.
///
/// The app declares the scenes; `HarnessUI` has to be able to ask for one from the failure
/// panel, where the Web UI is exactly what is missing. A shared constant is what keeps
/// those two from drifting into a button that opens nothing.
public enum HarnessWindowID {
  /// The main window. One per app, and the only one that owns the server's lifecycle.
  public static let main = "harness.main"
  /// Extra views of the *same* harness. A `WindowGroup`, so asking for it again opens
  /// another window instead of raising the one already there — two windows side by side
  /// showing two different pages of one running harness is the whole point.
  public static let page = "harness.page"
  public static let plugins = "harness.plugins"
  /// The plugin compatibility matrix. Its own window rather than a pane of the plugin window:
  /// it answers a read-only question ("does what is installed still agree with this harness?"),
  /// and that answer is worth leaving open beside the window that mutates the profile.
  public static let pluginCompatibility = "harness.pluginCompatibility"
  public static let market = "harness.market"
  public static let console = "harness.console"
  public static let wechat = "harness.wechat"
  public static let approvals = "harness.approvals"
  public static let backup = "harness.backup"
  public static let recovery = "harness.recovery"
}
