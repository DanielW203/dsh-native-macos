import Foundation

/// The complete filesystem layout this app owns.
///
/// Everything lives under one root so a test can point the whole subsystem at a
/// temporary directory, and so `DSH_HOME`` is provably isolated from the one the
/// official Electron desktop uses (`~/.dsh``) — the user chose isolation, and the
/// layout is what enforces it.
public struct RuntimePaths: Sendable, Equatable {
  /// The name of the single directory this subsystem owns under the user's home
  /// directory, i.e. `~/.nativeharness`.
  ///
  /// A per-user tool directory rather than Application Support: the tree holds installed
  /// releases, profiles, sessions, and the toolchain cache, so it is something a user
  /// reasonably wants to find, move, or delete by name — the same way the official
  /// desktop client keeps its own `~/.dsh`.
  public static let directoryName = ".nativeharness"

  /// Where builds up to 2026-09 kept the same tree.
  ///
  /// It is still honored while it is the only root present: upgrading the app must never
  /// look like every installed release, profile, and session disappeared. `Tools/relocate-root.sh`
  /// is the supported way to carry an existing tree over.
  public static let legacyDirectoryName = "NativeHarness"

  /// `~/.nativeharness` — or the legacy Application Support root on an un-migrated upgrade.
  public let root: URL

  /// The harness home handed to every spawned harness process.
  ///
  /// Stored rather than derived so a Safe Mode launch can point the harness at a
  /// disposable home while releases, Node, the lock, and the logs stay in the one real
  /// tree — re-downloading a runtime to answer "does it still boot" would be a worse
  /// answer than the question deserves. `nil` means the conventional `root/home`.
  public let dshHome: URL

  /// Whether `dshHome` is the disposable Safe Mode home rather than the user's own.
  ///
  /// Callers use it to keep per-user state out of a home that is deleted on the next
  /// normal launch — the checkpoint of a throwaway profile is not worth keeping.
  public let isSafeMode: Bool

  /// - Parameters:
  ///   - root: the single directory this subsystem owns.
  ///   - dshHome: the harness home to hand over, or `nil` for `root/home`.
  ///   - isSafeMode: whether `dshHome` is the disposable Safe Mode home.
  public init(root: URL, dshHome: URL? = nil, isSafeMode: Bool = false) {
    self.root = root.standardizedFileURL
    self.dshHome = (dshHome ?? root.appendingPathComponent("home", isDirectory: true))
      .standardizedFileURL
    self.isSafeMode = isSafeMode
  }

  /// The production root, or an override supplied through the environment so
  /// `harnessctl`` and packaged builds can be pointed at a scratch tree.
  public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RuntimePaths {
    if let override = environment["NATIVE_HARNESS_ROOT"], !override.isEmpty {
      return RuntimePaths(root: URL(fileURLWithPath: override, isDirectory: true))
    }
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    )
    return RuntimePaths(root: resolveRoot(
      home: FileManager.default.homeDirectoryForCurrentUser,
      applicationSupport: applicationSupport,
      isPopulated: { Self.isPopulated(root: URL(fileURLWithPath: $0, isDirectory: true)) }
    ))
  }

  /// Whether `root` holds a tree this subsystem created.
  ///
  /// Deliberately not "the directory exists": an empty `~/.nativeharness` — a stray
  /// `mkdir`, a leftover from an aborted experiment — must not shadow a populated legacy
  /// tree and make an existing install look erased.
  public static func isPopulated(root: URL) -> Bool {
    let manager = FileManager.default
    return manager.fileExists(atPath: root.appendingPathComponent("harness", isDirectory: true).path)
      || manager.fileExists(atPath: root.appendingPathComponent("home", isDirectory: true).path)
  }

  /// Which root a fresh or upgraded install uses.
  ///
  /// `~/.nativeharness` wins once it holds a tree; the legacy Application Support root is
  /// used while it is the only populated one. Two populated directories side by side
  /// therefore resolve to the new one and the old one is left untouched rather than moved
  /// behind the user's back.
  ///
  /// - Parameters:
  ///   - home: the user's home directory.
  ///   - applicationSupport: `~/Library/Application Support`, or `nil` when it cannot be resolved.
  ///   - isPopulated: probe for "this root holds a tree", injected so the decision is testable
  ///     without touching a real home.
  public static func resolveRoot(
    home: URL,
    applicationSupport: URL?,
    isPopulated: (String) -> Bool
  ) -> URL {
    let preferred = home.appendingPathComponent(directoryName, isDirectory: true)
    if isPopulated(preferred.path) { return preferred }
    guard let applicationSupport else { return preferred }
    let legacy = applicationSupport.appendingPathComponent(legacyDirectoryName, isDirectory: true)
    return isPopulated(legacy.path) ? legacy : preferred
  }

  // MARK: - Harness home

  /// The `home` directory the user's own profiles, sessions, and credentials live in,
  /// regardless of which home the harness process was pointed at.
  ///
  /// The recovery surfaces (checkpoints, session restore, plugin repair) act on the real
  /// tree even while Safe Mode runs — repairing the disposable one would answer nothing.
  public var realDshHome: URL { root.appendingPathComponent("home", isDirectory: true) }
  public var profilesDirectory: URL { dshHome.appendingPathComponent("profiles", isDirectory: true) }

  // MARK: - Safe Mode

  /// The directory holding the Safe Mode marker and, for a clean-environment launch, the
  /// disposable home.
  ///
  /// Both live under the one root so "leaving Safe Mode" is a single deletion, and so
  /// `Tools/relocate-root.sh` carries the state along with everything else.
  public static let safeModeDirectoryName = "safe-mode"
  public var safeModeDirectory: URL { root.appendingPathComponent(Self.safeModeDirectoryName, isDirectory: true) }
  public var safeModeHome: URL { safeModeDirectory.appendingPathComponent("home", isDirectory: true) }
  public var safeModeMarker: URL { safeModeDirectory.appendingPathComponent("state.json", isDirectory: false) }

  /// The same root with the harness pointed at the disposable home.
  ///
  /// Everything shared stays shared: the installed releases, the Node/pnpm toolchain, the
  /// install lock, the server record, backups, and logs. Only `DSH_HOME` — which is where
  /// profiles, plugins, settings, credentials, and sessions live — moves aside.
  public func withSafeModeHome() -> RuntimePaths {
    RuntimePaths(root: root, dshHome: safeModeHome, isSafeMode: true)
  }

  // MARK: - Runtime toolchain

  public var runtimeRoot: URL { root.appendingPathComponent("runtime", isDirectory: true) }
  public var nodeDirectory: URL { runtimeRoot.appendingPathComponent("node", isDirectory: true) }
  public var nodeBinary: URL { nodeDirectory.appendingPathComponent("bin/node", isDirectory: false) }
  public var pnpmDirectory: URL { runtimeRoot.appendingPathComponent("pnpm", isDirectory: true) }
  public var pnpmEntry: URL { pnpmDirectory.appendingPathComponent("bin/pnpm.cjs", isDirectory: false) }
  public var binDirectory: URL { runtimeRoot.appendingPathComponent("bin", isDirectory: true) }
  /// ("npm")'s cache and configuration live here rather than in the user's home.
  ///
  /// A managed runtime must not read or write §~/.npm§: that directory is shared with
  /// every other npm on the machine, may be owned by another user (a real, observed
  /// failure: root-owned cache entries made a fresh install fail with EPERM), and
  /// carrying another project's cache into this app's installs is not this app's
  /// business.
  public var npmCacheDirectory: URL { runtimeRoot.appendingPathComponent("npm-cache", isDirectory: true) }
  public var npmPrefixDirectory: URL { runtimeRoot.appendingPathComponent("npm-prefix", isDirectory: true) }
  public var pnpmShim: URL { binDirectory.appendingPathComponent("pnpm", isDirectory: false) }

  // MARK: - Installed harness releases

  public var harnessRoot: URL { root.appendingPathComponent("harness", isDirectory: true) }
  public var releasesDirectory: URL { harnessRoot.appendingPathComponent("releases", isDirectory: true) }
  public var currentLink: URL { harnessRoot.appendingPathComponent("current") }
  public var installsIndex: URL { harnessRoot.appendingPathComponent("installs.json", isDirectory: false) }
  public var stagingRoot: URL { harnessRoot.appendingPathComponent("staging", isDirectory: true) }
  public var backupsRoot: URL { harnessRoot.appendingPathComponent("backups", isDirectory: true) }
  public var logsDirectory: URL { harnessRoot.appendingPathComponent("logs", isDirectory: true) }
  /// Held with `flock(2)`` for the duration of any mutating operation.
  public var lockFile: URL { harnessRoot.appendingPathComponent("lock", isDirectory: false) }

  public func releaseDirectory(_ id: String) -> URL {
    releasesDirectory.appendingPathComponent(id, isDirectory: true)
  }

  public func stagingDirectory(_ operationID: String) -> URL {
    stagingRoot.appendingPathComponent(operationID, isDirectory: true)
  }

  public func backupDirectory(_ stamp: String) -> URL {
    backupsRoot.appendingPathComponent(stamp, isDirectory: true)
  }

  // MARK: - Creation

  /// Create every directory the subsystem writes into. Idempotent.
  ///
  /// In Safe Mode this also creates `safe-mode/`, because `dshHome` sits inside it — the
  /// marker and the disposable home must not be able to disagree about whether Safe Mode
  /// is on.
  public func createDirectories() throws {
    let directories = [
      root, dshHome, profilesDirectory,
      runtimeRoot, nodeDirectory, pnpmDirectory, binDirectory,
      harnessRoot, releasesDirectory, stagingRoot, backupsRoot, logsDirectory,
    ]
    for directory in directories {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  /// Where the bridge patch and its plugin live once route A is wired up.
  public var bridgeDirectory: URL { root.appendingPathComponent("bridge", isDirectory: true) }
}
