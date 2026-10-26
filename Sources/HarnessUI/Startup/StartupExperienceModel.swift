import Combine
import Foundation

/// The built-in launch experience: whether it appears at launch, whether the current
/// appearance is a preview, and the user's on/off switch.
///
/// App-level rather than owned by a window for the same reason the custom video is: the
/// main window can be closed and opened again, and the launch decision belongs to the
/// process. It deliberately owns no boot state: the window model is the source of truth for
/// what the harness is doing, and this type only decides whether the overlay is on screen.
@MainActor
public final class StartupExperienceModel: ObservableObject {
  public enum Keys {
    public static let isEnabled = "NativeHarness.startupExperience.enabled"
  }

  @Published public private(set) var isPresenting = false
  @Published public private(set) var isPreview = false
  @Published public private(set) var isEnabled: Bool

  private let defaults: UserDefaults
  /// The launch decision is once per process: reopening the main window is not a launch.
  private var didPresentAtLaunch = false

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // UserDefaults.bool returns false for a missing key; the experience is on by default.
    self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
  }

  /// Present the built-in experience once, unless a custom video is about to play or the
  /// user turned it off. The flag is consumed even when nothing is shown, so flipping the
  /// switch later in the same process does not make the animation appear out of nowhere.
  public func presentAtLaunch(customVideoPlaying: Bool) {
    guard !didPresentAtLaunch else { return }
    didPresentAtLaunch = true
    guard isEnabled, !customVideoPlaying else { return }
    isPreview = false
    isPresenting = true
  }

  /// Replay the experience from the menu, whatever the launch switch says.
  public func presentPreview() {
    isPreview = true
    isPresenting = true
  }

  public func dismiss() {
    guard isPresenting else { return }
    isPresenting = false
    isPreview = false
  }

  public func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: Keys.isEnabled)
  }
}
