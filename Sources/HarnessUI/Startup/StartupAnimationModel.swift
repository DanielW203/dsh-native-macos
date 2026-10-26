import AVFoundation
import Foundation

/// The startup animation's video, its on/off switch, and the playback state the main window
/// reads.
///
/// App-level rather than owned by a window: the video is chosen from the menu bar while no
/// window of its own is open, the choice outlives every window, and the launch-time decision
/// has to exist before the main window draws. The file is copied into the app's own root
/// (`~/.nativeharness/startup/`) so the choice survives the source video being moved or
/// deleted; 移除视频 deletes only that copy.
@MainActor
public final class StartupAnimationModel: ObservableObject {
  /// Decides whether a chosen file can actually be played.
  ///
  /// Injected so the copy/persistence rules are testable without media: the app's default
  /// asks AVFoundation for `isPlayable` and a non-zero duration, while a test can answer
  /// yes or no directly. Kept as `async` because that is how AVFoundation loads assets now.
  public typealias VideoValidator = @Sendable (URL) async -> Bool

  public enum Keys {
    public static let isEnabled = "NativeHarness.startupAnimation.enabled"
    public static let videoFile = "NativeHarness.startupAnimation.videoFile"
  }

  public enum StartupVideoError: LocalizedError {
    case notPlayable(name: String)
    case copyFailed(String)
    case busy

    public var errorDescription: String? {
      switch self {
      case .notPlayable(let name):
        return "所选文件无法播放：\(name)。请选择 .mp4 / .mov 格式的视频。"
      case .copyFailed(let detail):
        return "无法把视频复制到 App 目录：\(detail)"
      case .busy:
        return "正在导入另一段视频，请等它完成。"
      }
    }
  }

  @Published public private(set) var isEnabled: Bool
  @Published public private(set) var videoURL: URL?
  /// True while the startup video covers the main window.
  @Published public private(set) var isPresenting = false
  /// True while a chosen file is being copied and checked.
  @Published public private(set) var isBusy = false

  /// Where the copied video lives. Under the app's own root so Safe Mode does not touch it,
  /// and so "remove" is one directory entry rather than a user file.
  private let directory: URL
  private let defaults: UserDefaults
  private let fileManager: FileManager
  private let validator: VideoValidator
  /// The launch decision is once per process: the main window can be shown again after being
  /// closed, and replaying the animation then would be a different feature (a preview).
  private var didPresentAtLaunch = false
  private var watchdog: Task<Void, Never>?

  public init(
    root: URL,
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    validator: VideoValidator? = nil
  ) {
    self.directory = root.appendingPathComponent("startup", isDirectory: true)
    self.defaults = defaults
    self.fileManager = fileManager
    self.validator = validator ?? Self.defaultValidator
    self.isEnabled = defaults.bool(forKey: Keys.isEnabled)
    self.videoURL = Self.resolveVideo(directory: directory, defaults: defaults, fileManager: fileManager)
  }

  public var hasVideo: Bool { videoURL != nil }

  /// Whether a launch would actually play something, i.e. what the menu's checkmark means.
  public var playsAtLaunch: Bool { isEnabled && videoURL != nil }

  /// Play the configured video once per process, if it is switched on and still on disk.
  ///
  /// Synchronous on purpose: the window must not wait on AVFoundation before it can draw,
  /// and a file that passed the validator when it was chosen only has to be looked up, not
  /// replayed. A file deleted behind the model's back simply means no animation.
  public func presentAtLaunch() {
    guard !didPresentAtLaunch else { return }
    didPresentAtLaunch = true
    guard isEnabled, videoURL != nil else { return }
    present()
  }

  /// Play now, whatever the switch says. This is what makes the menu's preview useful
  /// before committing to seeing the video on every launch.
  public func presentPreview() {
    guard videoURL != nil else { return }
    present()
  }

  public func dismiss() {
    watchdog?.cancel()
    watchdog = nil
    guard isPresenting else { return }
    isPresenting = false
  }

  public func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: Keys.isEnabled)
  }

  /// Copy `source` into the app's startup directory, verify it, and switch the animation on.
  ///
  /// Copy-then-verify rather than verify-then-copy: AVFoundation needs a file URL, and a
  /// sandbox-free app still should not point its player at a path the user may delete a
  /// minute later. A rejected file leaves the previous choice untouched.
  public func chooseVideo(from source: URL) async throws {
    // The panel is modal, but the copy runs after it closes and the menu stays live: a
    // second import must be refused rather than race the first one's commit step.
    guard !isBusy else { throw StartupVideoError.busy }
    isBusy = true
    defer { isBusy = false }

    let incoming = try await copyIncoming(source)
    let playable = await validator(incoming)
    guard playable else {
      try? fileManager.removeItem(at: incoming)
      throw StartupVideoError.notPlayable(name: source.lastPathComponent)
    }
    do {
      try commit(incoming, named: source.lastPathComponent)
    } catch {
      try? fileManager.removeItem(at: incoming)
      throw error
    }
  }

  public func removeVideo() {
    dismiss()
    if let videoURL {
      try? fileManager.removeItem(at: videoURL)
    }
    videoURL = nil
    defaults.removeObject(forKey: Keys.videoFile)
    isEnabled = false
    defaults.set(false, forKey: Keys.isEnabled)
  }

  // MARK: - Playback state

  private func present() {
    isPresenting = true
    watchdog?.cancel()
    // The skip button is the fast way out; this is the backstop for a player that never
    // reports its end. Without it a file that loads but cannot decode would leave the
    // window covered until the user found the button.
    watchdog = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000_000)
      guard !Task.isCancelled else { return }
      self?.dismiss()
    }
  }

  // MARK: - Files

  private func copyIncoming(_ source: URL) async throws -> URL {
    let manager = fileManager
    let directory = self.directory
    let name = source.lastPathComponent
    return try await Task.detached(priority: .userInitiated) { () throws -> URL in
      do {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        throw StartupVideoError.copyFailed(error.localizedDescription)
      }
      let incoming = directory.appendingPathComponent(".incoming-\(UUID().uuidString)-\(name)")
      try? manager.removeItem(at: incoming)
      do {
        try manager.copyItem(at: source, to: incoming)
      } catch {
        throw StartupVideoError.copyFailed(error.localizedDescription)
      }
      return incoming
    }.value
  }

  private func commit(_ incoming: URL, named name: String) throws {
    let destination = directory.appendingPathComponent(name)
    let existing = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    // Compare by name, not by URL: on this machine contentsOfDirectory can spell a path
    // under /private/var while the URL this method built says /var, and URL equality would
    // then delete the very file it is about to move (the /private/var trap recorded in
    // CONTRACT.md).
    let incomingName = incoming.lastPathComponent
    // One active video: anything else in the directory is either the previous copy or a
    // half-finished import.
    for url in existing where url.lastPathComponent != incomingName {
      try? fileManager.removeItem(at: url)
    }
    try? fileManager.removeItem(at: destination)
    do {
      try fileManager.moveItem(at: incoming, to: destination)
    } catch {
      throw StartupVideoError.copyFailed(error.localizedDescription)
    }
    videoURL = destination
    defaults.set(name, forKey: Keys.videoFile)
    isEnabled = true
    defaults.set(true, forKey: Keys.isEnabled)
  }

  private static func resolveVideo(
    directory: URL,
    defaults: UserDefaults,
    fileManager: FileManager
  ) -> URL? {
    guard let name = defaults.string(forKey: Keys.videoFile),
          !name.isEmpty,
          !name.contains("/") else {
      return nil
    }
    let url = directory.appendingPathComponent(name)
    return fileManager.fileExists(atPath: url.path) ? url : nil
  }

  private static let defaultValidator: VideoValidator = { url in
    let asset = AVURLAsset(url: url)
    do {
      let playable = try await asset.load(.isPlayable)
      let duration = try await asset.load(.duration)
      return playable && duration.seconds > 0.2
    } catch {
      return false
    }
  }
}
