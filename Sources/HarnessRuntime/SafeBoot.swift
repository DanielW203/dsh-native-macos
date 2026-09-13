import Foundation

/// The two ways this app can start the harness with something taken out of the picture.
///
/// They isolate different layers, and that is the whole point: the patch stack the harness
/// composes is `bundlePatches + profile.patches + homePatches + overlays`, so a
/// plugin-free profile still inherits `$DSH_HOME/cordis.patch.yml`, while a disposable
/// home does not. Two modes make the diagnosis decidable instead of a guess:
///
/// - `rescue` boots a profile built from the shipped `web` template — official bundles
///   only — in the user's real home, so credentials, sessions, and settings keep working.
///   If it starts, the culprit is a third-party plugin.
/// - `cleanHome` boots in a disposable home. If `rescue` fails but this starts, the culprit
///   is home-level state (the user patch, settings, credentials, or sessions). If both
///   fail, the harness release, Node, or the app's own setup is at fault.
public enum SafeBootMode: String, Codable, Sendable, CaseIterable {
  /// A plugin-free profile in the real home.
  case rescue
  /// A disposable home, deleted on the next normal launch.
  case cleanHome

  public var displayName: String {
    switch self {
    case .rescue: return "安全模式 · 无插件"
    case .cleanHome: return "干净环境"
    }
  }
}

/// The persisted request to start in a Safe Mode. Absence means a normal start.
public struct SafeBootRecord: Codable, Sendable, Equatable {
  public var version: Int
  public var mode: SafeBootMode
  public var enteredAt: String
  public var profile: String

  public init(version: Int, mode: SafeBootMode, enteredAt: String, profile: String) {
    self.version = version
    self.mode = mode
    self.enteredAt = enteredAt
    self.profile = profile
  }
}

/// Which home and profile this launch uses, and whether a leftover tree was cleared.
///
/// Resolved once, before any model or process exists: the harness home has to be correct
/// from the very first spawn, and a model that started against the wrong home would have
/// to be torn down to fix it.
public struct SafeBootResolution: Sendable, Equatable {
  /// The requested mode, or `nil` for a normal start.
  public var mode: SafeBootMode?
  /// The paths the harness process runs under.
  public var paths: RuntimePaths
  /// The profile the harness boots.
  public var profile: String
  /// When Safe Mode was entered, as recorded in the marker.
  public var enteredAt: String?
  /// Something the user should be told in the log — a cleared leftover tree, or a marker
  /// that could not be honored.
  public var note: String?

  public init(
    mode: SafeBootMode?,
    paths: RuntimePaths,
    profile: String,
    enteredAt: String? = nil,
    note: String? = nil
  ) {
    self.mode = mode
    self.paths = paths
    self.profile = profile
    self.enteredAt = enteredAt
    self.note = note
  }

  public var isSafe: Bool { mode != nil }

  /// The profile a normal start boots. The window app is the only profile any window needs.
  public static let normalProfile = "web"
}

/// Reading, entering, and leaving Safe Mode.
///
/// The marker is the only state: a file says "start in this mode", and deleting it says
/// "stop". Nothing is inferred from the presence of a directory, because a directory can
/// be left behind by a crash while a file cannot be left behind by a clean exit — which is
/// exactly the distinction that keeps a user from being stuck in a mode they cannot see.
public enum SafeBoot {
  public static let markerVersion = 1

  /// The profile a `rescue` start boots.
  ///
  /// Custom on purpose: the harness reserves its shipped profile names (`web`, `headless`,
  /// …) as `--from-default-profile` targets, and refuses to initialize into an existing
  /// directory, so this name must be stable and unused.
  public static let rescueProfileName = "rescue"

  /// The profile a `cleanHome` start boots.
  ///
  /// `web` because a fresh home has no profiles at all and the harness creates a missing
  /// shipped profile from its own template — which is already plugin-free.
  public static let cleanHomeProfileName = SafeBootResolution.normalProfile

  // MARK: - Resolution

  /// Decide which home and profile this launch uses, and clear a leftover Safe Mode tree.
  ///
  /// Never throws. A marker that cannot be read is treated as absent, because the one
  /// outcome that must be impossible is a user trapped in a mode nothing on screen
  /// explains.
  public static func resolve(_ base: RuntimePaths) -> SafeBootResolution {
    let normal = SafeBootResolution(
      mode: nil,
      paths: base,
      profile: SafeBootResolution.normalProfile
    )
    guard FileManager.default.fileExists(atPath: base.safeModeDirectory.path) else {
      return normal
    }

    guard let data = try? Data(contentsOf: base.safeModeMarker),
          let record = try? JSONDecoder().decode(SafeBootRecord.self, from: data),
          record.version == markerVersion
    else {
      // No marker at all, or one this build cannot honor. Either way this launch is
      // normal, and the disposable home — if one exists — is garbage from an earlier run.
      let cleared = discardTree(base)
      return SafeBootResolution(
        mode: nil,
        paths: base,
        profile: SafeBootResolution.normalProfile,
        note: cleared
          ? "Cleared a leftover Safe Mode environment from an earlier run."
          : "Ignored an unreadable Safe Mode marker; starting normally."
      )
    }

    switch record.mode {
    case .rescue:
      // The real home on purpose: the point of this mode is that everything except the
      // profile layer still works, so the user can confirm a plugin is the culprit and
      // keep working meanwhile. A disposable home left by an earlier `cleanHome` run is
      // not in use here and only wastes space.
      _ = discardDisposableHome(base)
      return SafeBootResolution(
        mode: .rescue,
        paths: base,
        profile: rescueProfileName,
        enteredAt: record.enteredAt
      )
    case .cleanHome:
      return SafeBootResolution(
        mode: .cleanHome,
        paths: base.withSafeModeHome(),
        profile: cleanHomeProfileName,
        enteredAt: record.enteredAt
      )
    }
  }

  // MARK: - Entering and leaving

  /// Persist the request. The next launch reads it; this one is already running.
  public static func enter(_ mode: SafeBootMode, base: RuntimePaths, at date: Date = Date()) throws {
    let record = SafeBootRecord(
      version: markerVersion,
      mode: mode,
      enteredAt: ISO8601DateFormatter().string(from: date),
      profile: mode == .rescue ? rescueProfileName : cleanHomeProfileName
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    try FileManager.default.createDirectory(at: base.safeModeDirectory, withIntermediateDirectories: true)
    try data.write(to: base.safeModeMarker, options: .atomic)
  }

  /// Stop asking for Safe Mode.
  ///
  /// Only the marker is removed, plus the disposable home it was pointing at — a home that
  /// is promised to be thrown away should not outlive the mode by even one launch. A
  /// `rescue` profile is deliberately left behind: it is three small files, it is useful
  /// the next time something will not boot, and deleting a profile is a destructive act
  /// that belongs behind an explicit confirmation in the recovery window.
  public static func leave(_ base: RuntimePaths) throws {
    try? FileManager.default.removeItem(at: base.safeModeMarker)
    _ = discardDisposableHome(base)
  }

  /// Remove the disposable home but keep the marker, so a mode switch does not look like a
  /// mode exit to the next launch.
  ///
  /// - Returns: whether anything was actually removed.
  @discardableResult
  public static func discardDisposableHome(_ base: RuntimePaths) -> Bool {
    let home = base.safeModeHome
    guard FileManager.default.fileExists(atPath: home.path) else { return false }
    do {
      try FileManager.default.removeItem(at: home)
      return true
    } catch {
      return false
    }
  }

  /// Remove the whole `safe-mode/` directory: the marker and any disposable home in it.
  ///
  /// - Returns: whether anything was actually removed.
  @discardableResult
  public static func discardTree(_ base: RuntimePaths) -> Bool {
    guard FileManager.default.fileExists(atPath: base.safeModeDirectory.path) else { return false }
    do {
      try FileManager.default.removeItem(at: base.safeModeDirectory)
      return true
    } catch {
      // A tree that cannot be removed must not stop the app from starting: the marker is
      // gone by now, so the next launch is normal regardless.
      return false
    }
  }

  // MARK: - Reading

  public static func record(_ base: RuntimePaths) -> SafeBootRecord? {
    guard let data = try? Data(contentsOf: base.safeModeMarker) else { return nil }
    guard let record = try? JSONDecoder().decode(SafeBootRecord.self, from: data),
          record.version == markerVersion
    else { return nil }
    return record
  }

  /// Whether a `rescue` profile already exists, so the caller can skip creating it.
  public static func rescueProfileExists(in base: RuntimePaths) -> Bool {
    FileManager.default.fileExists(
      atPath: base.profilesDirectory
        .appendingPathComponent(rescueProfileName, isDirectory: true)
        .appendingPathComponent("package.json", isDirectory: false)
        .path
    )
  }

  /// Delete the `rescue` profile.
  ///
  /// Only ever called from an explicit, confirmed action: the profile is disposable by
  /// construction, but it is still a profile someone may have edited, and nothing else in
  /// this app deletes a profile directory.
  public static func removeRescueProfile(in base: RuntimePaths) throws {
    let directory = base.profilesDirectory.appendingPathComponent(rescueProfileName, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }
}

/// What a window says about the mode a launch resolved to.
///
/// It lives beside the resolution rather than in a view because two surfaces describe the
/// same two modes — the main window's banner and the recovery window's mode picker — and
/// two copies of that description would eventually disagree about what is isolated, which is
/// the only thing the user needs it for.
public struct SafeModeBanner: Sendable, Equatable {
  public var title: String
  public var detail: String
  public var isSafe: Bool

  public init(title: String, detail: String, isSafe: Bool) {
    self.title = title
    self.detail = detail
    self.isSafe = isSafe
  }

  /// The banner for a resolution, or `nil` for a normal start.
  public static func make(_ resolution: SafeBootResolution) -> SafeModeBanner? {
    switch resolution.mode {
    case nil:
      return nil
    case .rescue:
      return SafeModeBanner(
        title: "安全模式 · 无插件",
        detail: "正在用 profile \(resolution.profile) 启动：只加载官方 bundle，第三方插件不会载入。"
          + "用的是你的真实 home，API key、会话和设置都还在——这样能确认问题是否出在插件上。"
          + "注意：安全模式下的对话会写进真实 home。",
        isSafe: true
      )
    case .cleanHome:
      return SafeModeBanner(
        title: "干净环境",
        detail: "正在用一次性 home 启动：没有插件、没有会话、没有凭据，也不读你的 cordis.patch.yml 和设置。"
          + "如果这里能起来而安全模式起不来，问题就在 home 层；退出后这个临时 home 会被删除。",
        isSafe: true
      )
    }
  }
}

/// The seam a view model uses to change the boot mode.
///
/// A protocol rather than the static functions above so the interesting behaviour — which
/// mode is written, and whether a restart follows — is testable without touching a real
/// `~/.nativeharness`.
public protocol SafeBootMarking: Sendable {
  func current() -> SafeBootResolution
  func enter(_ mode: SafeBootMode) throws
  func leave() throws
}

/// A marker writer rooted at one real tree.
public struct SafeBootMarker: SafeBootMarking {
  public let base: RuntimePaths
  private let now: @Sendable () -> Date

  public init(base: RuntimePaths, now: @escaping @Sendable () -> Date = { Date() }) {
    self.base = base
    self.now = now
  }

  public func current() -> SafeBootResolution {
    SafeBoot.resolve(base)
  }

  public func enter(_ mode: SafeBootMode) throws {
    try SafeBoot.enter(mode, base: base, at: now())
  }

  public func leave() throws {
    try SafeBoot.leave(base)
  }
}
