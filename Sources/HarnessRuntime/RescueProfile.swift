import Foundation

/// What a window needs from something that can make a profile exist before it boots.
///
/// A protocol rather than the concrete installer for the same reason `PluginRecovering` is
/// one: the behaviour worth testing is what the window does when the profile is already
/// there, when it had to be created, and when creation fails — and none of that needs Node
/// or a real profile.
public protocol ProfilePreparing: Sendable {
  /// Create the profile when it does not exist.
  ///
  /// - Returns: a line for the log when something was created, or `nil` when the profile
  ///   was already there and nothing happened.
  func ensureProfile(named name: String, template: String) async throws -> String?
}

/// Creates the plugin-free profile a `rescue` start boots.
///
/// **Why the official CLI and not a hand-written manifest.** The bundle list and patch
/// reload policy of a shipped profile live in the harness, and a copy of them here would
/// drift silently — the app would keep creating a profile the harness no longer considers
/// valid. `dsh --profile <name> --from-default-profile web --dump-config` is the documented
/// way to initialize a custom profile from a shipped template, and it neither boots nor
/// needs a network: `initProfile` writes `package.json`, `cordis.patch.yml`, and
/// `pnpm-workspace.yaml`.
///
/// The harness refuses to initialize into an existing directory, so this is deliberately a
/// "create once" operation. Nothing is deleted to make room: a profile someone has since
/// edited is theirs, and re-creating it would silently undo that.
public actor RescueProfileInstaller: ProfilePreparing {
  private let paths: RuntimePaths
  private let store: PluginStore

  public init(
    paths: RuntimePaths,
    entryProvider: @escaping @Sendable () async throws -> URL,
    runner: ProcessRunning = ProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.paths = paths
    self.store = PluginStore(
      paths: paths,
      entryProvider: entryProvider,
      runner: runner,
      baseEnvironment: baseEnvironment
    )
  }

  public func ensureProfile(named name: String, template: String) async throws -> String? {
    guard !Self.profileExists(name, in: paths) else { return nil }

    do {
      let result = try await store.initializeProfile(name, template: template)
      return "Created profile \(name) from the shipped \(template) template: "
        + result.changes.joined(separator: "; ")
    } catch {
      // Only a failure that left a usable profile behind is tolerable. The harness refuses
      // to initialize into an existing directory, so losing a race with a second launch
      // (or with a `dsh plugin` run the user started) shows up here as an error from a
      // profile that is in fact ready to boot. Re-checking the filesystem is the
      // text-free way to tell that apart from a real failure.
      if Self.profileExists(name, in: paths) {
        return "Profile \(name) already existed; kept it as it is."
      }
      throw error
    }
  }

  /// Whether the profile can boot, which is what the harness itself keys on.
  ///
  /// Not "the directory exists": an empty directory left by an interrupted run would make
  /// this skip the initialization that actually creates the profile, and the failure would
  /// surface much later as a boot error with no visible cause.
  static func profileExists(_ name: String, in paths: RuntimePaths) -> Bool {
    FileManager.default.fileExists(
      atPath: paths.profilesDirectory
        .appendingPathComponent(name, isDirectory: true)
        .appendingPathComponent("package.json", isDirectory: false)
        .path
    )
  }
}
