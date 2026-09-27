import Foundation

/// What the harness runtime sometimes needs from the app that owns it.
///
/// The layering problem this solves is narrow and real: the window model drives the upgrade
/// coordinator, and the coordinator's last resort — "this release cannot be repaired, start
/// without plugins" — is a *relaunch*, which only the app can do (`NSApp.terminate` plus the
/// relaunch shell in `HarnessWindowModel.restartApplication`). Capturing the model in the
/// coordinator's hook would be the cycle the static handles already avoid; depending on the
/// app target would be a library importing its own host.
///
/// So the app installs two closures once, at launch, and everything below stays testable with
/// the defaults, which do nothing.
public final class HarnessAppHooks: @unchecked Sendable {
  public static let shared = HarnessAppHooks()

  private let lock = NSLock()
  private var restartAction: (@Sendable @MainActor () -> Void)?
  private var notes: [String] = []

  public init() {}

  /// The app's own relaunch. `nil` until the app installs it.
  public func installRestart(_ action: @escaping @Sendable @MainActor () -> Void) {
    lock.lock()
    restartAction = action
    lock.unlock()
  }

  /// Quit and reopen the app, if the app is able to.
  public func restart() async {
    lock.lock()
    let action = restartAction
    lock.unlock()
    guard let action else { return }
    await MainActor.run { action() }
  }

  /// Note something the app did that the next launch should be able to explain.
  ///
  /// Kept in memory rather than on disk: the launch that acts on it is reading the Safe Mode
  /// marker and the upgrade report, and this is only the sentence that connects the two.
  public func record(_ reason: String) {
    lock.lock()
    notes.append(reason)
    if notes.count > 20 { notes.removeFirst(notes.count - 20) }
    lock.unlock()
  }

  /// Everything recorded this launch, oldest first.
  public var recordedNotes: [String] {
    lock.lock()
    defer { lock.unlock() }
    return notes
  }
}
