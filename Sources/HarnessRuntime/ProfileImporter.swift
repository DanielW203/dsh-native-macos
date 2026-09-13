import Foundation

/// A Harness home this app can read plugins from.
public struct PluginHome: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable {
    /// The official desktop app's home, ~/.dsh.
    case desktop
    /// This app's own home.
    case console
    /// A directory the user picked.
    case custom

    public var displayName: String {
      switch self {
      case .desktop: return "DSH Desktop"
      case .console: return "This app"
      case .custom: return "Chosen location"
      }
    }
  }

  public var url: URL
  public var kind: Kind
  public var profiles: [ProfileSummary]

  public var id: String { url.path }
  public var displayName: String { "\(kind.displayName) — \(url.path)" }
  public var initializedProfiles: [ProfileSummary] { profiles.filter { $0.isInitialized } }

  public init(url: URL, kind: Kind, profiles: [ProfileSummary]) {
    self.url = url
    self.kind = kind
    self.profiles = profiles
  }
}

/// What to do when the destination already has a package of the same name.
public enum PluginConflictPolicy: String, Sendable, Equatable, CaseIterable {
  /// Keep what the destination has; the incoming copy is skipped and reported.
  case keepDestination
  /// Replace the destination's copy with the incoming one. The old directory is moved into
  /// the operation's backup first, so the replacement is reversible by hand.
  case preferSource

  public var displayName: String {
    switch self {
    case .keepDestination: return "Keep existing"
    case .preferSource: return "Prefer source"
    }
  }
}

/// One import: from where, into which profile, under which conflict policy.
public struct PluginImportRequest: Sendable, Equatable {
  public var sourceHome: URL
  public var sourceProfile: String
  public var destinationProfile: String
  public var conflictPolicy: PluginConflictPolicy

  public init(
    sourceHome: URL,
    sourceProfile: String,
    destinationProfile: String,
    conflictPolicy: PluginConflictPolicy = .preferSource
  ) {
    self.sourceHome = sourceHome
    self.sourceProfile = sourceProfile
    self.destinationProfile = destinationProfile
    self.conflictPolicy = conflictPolicy
  }

  /// Where the copied entries come from, once a symlinked profile is followed.
  public var sourceProfileDirectory: URL {
    sourceHome
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(sourceProfile, isDirectory: true)
      .resolvingSymlinksInPath()
  }
}

/// Everything an import would do, computed without writing anything.
///
/// The plan is the contract the UI shows before the user commits: every entry that would
/// be copied or replaced, every manifest line that would change, and the minimum free
/// space the operation needs.
public struct PluginImportPlan: Sendable, Equatable {
  public enum Action: String, Sendable, Equatable {
    case copy
    case replace
    /// The destination already has this exact version.
    case skipIdentical
    /// Kept, because the policy says the destination wins.
    case skipExisting
    /// A directory both sides have: only the files the destination lacks are added.
    case mergeMissing

    public var displayName: String {
      switch self {
      case .copy: return "copy"
      case .replace: return "replace"
      case .skipIdentical: return "same version"
      case .skipExisting: return "kept"
      case .mergeMissing: return "merge"
      }
    }

    public var writes: Bool {
      switch self {
      case .copy, .replace, .mergeMissing: return true
      case .skipIdentical, .skipExisting: return false
      }
    }
  }

  /// Where an entry lives, so a caller can say more than its name.
  public enum Location: String, Sendable, Equatable {
    case nodeModules
    case profileRoot
  }

  public struct Item: Sendable, Equatable, Identifiable {
    public var name: String
    public var location: Location
    public var sourceVersion: String?
    public var destinationVersion: String?
    public var action: Action
    public var byteCount: Int64

    public var id: String { name }

    public init(
      name: String,
      location: Location = .nodeModules,
      sourceVersion: String? = nil,
      destinationVersion: String? = nil,
      action: Action,
      byteCount: Int64
    ) {
      self.name = name
      self.location = location
      self.sourceVersion = sourceVersion
      self.destinationVersion = destinationVersion
      self.action = action
      self.byteCount = byteCount
    }
  }

  public var request: PluginImportRequest
  public var sourceDirectory: URL
  public var destinationDirectory: URL
  public var items: [Item]
  public var dependencyChanges: [String]
  public var bundleChanges: [String]
  public var patchChanges: [String]
  public var allowBuildAdditions: [String]
  /// Bytes the copy itself needs.
  public var totalBytes: Int64
  /// Bytes of destination directories that are moved into the backup before replacement.
  public var backupBytes: Int64
  public var warnings: [String]

  public var writes: [Item] { items.filter { $0.action.writes } }
  public var isNoop: Bool {
    writes.isEmpty
      && dependencyChanges.isEmpty
      && bundleChanges.isEmpty
      && patchChanges.isEmpty
      && allowBuildAdditions.isEmpty
  }
}

/// What an import did.
public struct PluginImportOutcome: Sendable, Equatable {
  public var backupDirectory: URL?
  public var copied: [String]
  public var replaced: [String]
  public var skipped: [String]
  public var bytesCopied: Int64
  public var changes: [String]
  public var warnings: [String]

  public init(
    backupDirectory: URL? = nil,
    copied: [String] = [],
    replaced: [String] = [],
    skipped: [String] = [],
    bytesCopied: Int64 = 0,
    changes: [String] = [],
    warnings: [String] = []
  ) {
    self.backupDirectory = backupDirectory
    self.copied = copied
    self.replaced = replaced
    self.skipped = skipped
    self.bytesCopied = bytesCopied
    self.changes = changes
    self.warnings = warnings
  }
}

/// The result of composing a profile after an import, without booting it.
public struct PluginImportVerification: Sendable, Equatable {
  public struct Entry: Sendable, Equatable, Identifiable {
    public var name: String
    public var installedVersion: String?
    public var isBundle: Bool
    public var isEnabled: Bool
    /// The reason this plugin will not do anything, when there is one.
    public var problem: String?

    public var id: String { name }
  }

  public var entries: [Entry]
  public var composeSucceeded: Bool
  public var composeDiagnostic: String?
  /// Plugins whose entry module this runtime cannot import, with the reason it gave.
  public var importFailures: [String: String]
  /// What happened when the profile was actually started, when a boot was requested.
  public var boot: PluginBootCheck?

  public var problems: [Entry] { entries.filter { $0.problem != nil } }

  /// Whether the profile would actually start.
  ///
  /// Composing the tree is not enough: a plugin built against a different harness release
  /// composes fine and then fails when the loader imports it, which takes the whole boot
  /// down with it — the loader has no per-plugin isolation to fall back on.
  public var isHealthy: Bool {
    composeSucceeded && importFailures.isEmpty && (boot?.started ?? true)
  }
}

/// The result of starting a profile once, to see whether it comes up.
public struct PluginBootCheck: Sendable, Equatable {
  public var started: Bool
  public var url: String?
  /// What the harness said when it refused to come up.
  public var diagnostic: String?
  /// The plugins the failure blames, by package name.
  public var suspects: [String]

  public init(started: Bool, url: String? = nil, diagnostic: String? = nil, suspects: [String] = []) {
    self.started = started
    self.url = url
    self.diagnostic = diagnostic
    self.suspects = suspects
  }
}

/// What a quarantine run did.
public struct PluginQuarantineOutcome: Sendable, Equatable {
  public var disabled: [String]
  public var rounds: Int
  public var started: Bool
  public var diagnostic: String?

  public init(disabled: [String], rounds: Int, started: Bool, diagnostic: String? = nil) {
    self.disabled = disabled
    self.rounds = rounds
    self.started = started
    self.diagnostic = diagnostic
  }
}

/// A progress report from an import, which is a long copy of many directories.
public struct PluginImportProgress: Sendable, Equatable {
  public var message: String
  public var fraction: Double?

  public init(message: String, fraction: Double? = nil) {
    self.message = message
    self.fraction = fraction
  }
}

/// What was written to the operation's backup directory.
public struct PluginImportBackupRecord: Codable, Sendable, Equatable {
  public var sourceHome: String
  public var sourceProfile: String
  public var destinationProfile: String
  public var conflictPolicy: String
  public var createdAt: String
  public var copied: [String]
  public var replaced: [String]
  public var skipped: [String]
  public var bytesCopied: Int64
}

/// Copies one profile's plugin tree into another Harness home.
///
/// **Why a copy and not an install.** This app's `DSH_HOME` is deliberately its own, so a
/// harness it boots shares nothing with the official desktop app. Reaching feature parity
/// would otherwise mean re-resolving every plugin from the registry, which costs a network
/// round trip per package and does not reproduce what the user already has. The profile
/// tree is a plain hoisted directory — pnpm writes real directories, not a tree of links —
/// and the profile's own `node_modules` is a complete closure, so the tree can be copied
/// as files and used as-is.
///
/// **What is never copied.** `node_modules/.dsh-module-fallback` holds links created by the
/// harness that point at absolute paths inside the *source* home; copying it would produce
/// links to a directory the destination does not have, so it is skipped and the harness
/// regenerates its own. The app's own disabled-plugin ledger, the profile's `cordis.yml`,
/// and the source's plugin data directories are skipped for the same class of reason: they
/// describe the source home, not the plugins.
public actor ProfileImporter {
  public let paths: RuntimePaths
  private let runner: ProcessRunning
  private let baseEnvironment: [String: String]
  private let inspector: ArchiveInspector
  private let invocation: HarnessInvocation
  private let entryProvider: @Sendable () async throws -> URL

  /// Names that are never copied, whatever they are.
  ///
  /// `.dsh-module-fallback` holds links the harness created that point at absolute paths
  /// inside the *source* home — copying them would produce links to a directory the
  /// destination does not have, and the harness regenerates its own on boot. The pnpm
  /// workspace-state cache is skipped for the same class of reason: it records the source
  /// profile's absolute path, and it is a cache rather than state.
  private static let ignoredEntries: Set<String> = [
    ".DS_Store", ".dsh-module-fallback", ".pnpm-workspace-state-v1.json",
  ]
  /// Directories merged file by file rather than replaced: a profile's CLI shims.
  private static let mergedDirectories: Set<String> = [".bin"]
  /// package-manager bookkeeping, copied only into a profile that has none of its own.
  private static let bookkeepingEntries: Set<String> = [
    ".modules.yaml", ".package-map.json", ".pnpm",
  ]

  public init(
    paths: RuntimePaths,
    entryProvider: @escaping @Sendable () async throws -> URL,
    runner: ProcessRunning = ProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.paths = paths
    self.entryProvider = entryProvider
    self.runner = runner
    self.baseEnvironment = baseEnvironment
    self.inspector = ArchiveInspector(runner: runner)
    self.invocation = HarnessInvocation(paths: paths, runner: runner, baseEnvironment: baseEnvironment)
  }

  // MARK: - Homes

  /// Every Harness home this app can see: the official desktop's, its own, and any the
  /// caller names.
  ///
  /// Deduplicated by resolved path, so pointing the picker at the desktop's home a second
  /// time lists it once.
  public func homes(extra: [URL] = []) -> [PluginHome] {
    var candidates: [(url: URL, kind: PluginHome.Kind)] = []
    let desktop = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".dsh", isDirectory: true)
    if FileManager.default.fileExists(atPath: desktop.path) {
      candidates.append((desktop, .desktop))
    }
    candidates.append((paths.dshHome, .console))
    candidates.append(contentsOf: extra.map { ($0, PluginHome.Kind.custom) })

    var seen = Set<String>()
    var homes: [PluginHome] = []
    for candidate in candidates {
      let url = candidate.url.standardizedFileURL.resolvingSymlinksInPath()
      guard seen.insert(url.path).inserted else { continue }
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      homes.append(
        PluginHome(
          url: url,
          kind: candidate.kind,
          profiles: ProfileCatalog.summaries(
            inProfilesDirectory: url.appendingPathComponent("profiles", isDirectory: true)
          )
        )
      )
    }
    return homes
  }

  // MARK: - Planning

  /// Work out exactly what an import would do, without touching the filesystem.
  public func plan(_ request: PluginImportRequest) throws -> PluginImportPlan {
    let fileManager = FileManager.default
    let sourceDirectory = request.sourceProfileDirectory
    let destinationDirectory = paths.profilesDirectory
      .appendingPathComponent(request.destinationProfile, isDirectory: true)
    let sourceManifestURL = sourceDirectory.appendingPathComponent("package.json")
    let destinationManifestURL = destinationDirectory.appendingPathComponent("package.json")

    guard fileManager.fileExists(atPath: sourceManifestURL.path) else {
      throw RuntimeError.unsupported(
        "profile \(request.sourceProfile) in \(request.sourceHome.path) has no package.json, so it is not initialized"
      )
    }
    guard fileManager.fileExists(atPath: destinationManifestURL.path) else {
      throw RuntimeError.unsupported(
        "profile \(request.destinationProfile) is not initialized; create it first"
      )
    }
    guard sourceDirectory.standardizedFileURL != destinationDirectory.standardizedFileURL else {
      throw RuntimeError.unsupported("the source and the destination are the same profile")
    }

    let sourceNodeModules = sourceDirectory.appendingPathComponent("node_modules", isDirectory: true)
    guard fileManager.fileExists(atPath: sourceNodeModules.path) else {
      throw RuntimeError.unsupported("profile \(request.sourceProfile) has no node_modules to copy from")
    }

    let sourceManifest = try ProfileManifest.read(sourceManifestURL)
    let destinationManifest = try ProfileManifest.read(destinationManifestURL)
    let destinationNodeModules = destinationDirectory.appendingPathComponent("node_modules", isDirectory: true)
    let destinationHasPNPMState = Self.hasPNPMState(destinationNodeModules)

    var warnings: [String] = []
    var items: [PluginImportPlan.Item] = []
    var totalBytes: Int64 = 0
    var backupBytes: Int64 = 0

    for entry in Self.entries(in: sourceNodeModules) {
      let name = entry.name
      if Self.ignoredEntries.contains(name) { continue }

      // CLI shims are merged rather than replaced: replacing a profile's .bin with another
      // profile's would drop the shims this profile's own packages installed.
      if Self.mergedDirectories.contains(name) {
        let destination = destinationNodeModules.appendingPathComponent(name, isDirectory: true)
        // A shim whose target the source no longer has is not going to be copied, so it does
        // not count as something to write either — the plan and the operation have to agree.
        let missing = Self.missingNames(from: entry.url, in: destination)
          .filter { !Self.isDangling(entry.url.appendingPathComponent($0)) }
        guard !missing.isEmpty else { continue }
        let bytes = ArchiveInspector.byteCount(ofDirectory: entry.url)
        items.append(PluginImportPlan.Item(name: name, action: .mergeMissing, byteCount: bytes))
        totalBytes += bytes
        continue
      }

      if Self.bookkeepingEntries.contains(name) {
        // Copied only into a profile that has no package-manager state of its own. Mixing
        // one profile's bookkeeping into another's would misdescribe every other package
        // already installed there.
        guard !destinationHasPNPMState else { continue }
        let bytes = Self.byteCount(of: entry.url)
        items.append(PluginImportPlan.Item(name: name, action: .copy, byteCount: bytes))
        totalBytes += bytes
        continue
      }

      let sourceVersion = Self.version(ofPackageAt: entry.url)
      let destinationEntry = destinationNodeModules.appendingPathComponent(name, isDirectory: true)
      let bytes = Self.byteCount(of: entry.url)
      var destinationVersion: String?
      let action: PluginImportPlan.Action

      if FileManager.default.fileExists(atPath: destinationEntry.path) {
        destinationVersion = Self.version(ofPackageAt: destinationEntry)
        if let destinationVersion, destinationVersion == sourceVersion {
          action = .skipIdentical
        } else if request.conflictPolicy == .preferSource {
          action = .replace
          backupBytes += Self.byteCount(of: destinationEntry)
        } else {
          action = .skipExisting
        }
      } else {
        action = .copy
      }

      if action.writes { totalBytes += bytes }
      items.append(
        PluginImportPlan.Item(
          name: name,
          sourceVersion: sourceVersion,
          destinationVersion: destinationVersion,
          action: action,
          byteCount: bytes
        )
      )
    }

    // The lockfile sits at the profile root, and follows the same "only into a profile that
    // has none" rule as the rest of the package-manager bookkeeping.
    let sourceLockfile = sourceDirectory.appendingPathComponent("pnpm-lock.yaml")
    let destinationLockfile = destinationDirectory.appendingPathComponent("pnpm-lock.yaml")
    if !destinationHasPNPMState,
       FileManager.default.fileExists(atPath: sourceLockfile.path),
       !FileManager.default.fileExists(atPath: destinationLockfile.path) {
      let bytes = (try? ArchiveInspector.byteCount(of: sourceLockfile)) ?? 0
      items.append(
        PluginImportPlan.Item(name: "pnpm-lock.yaml", location: .profileRoot, action: .copy, byteCount: bytes)
      )
      totalBytes += bytes
    }

    // Manifest: dependencies come from the source, bundles are a union so that copying one
    // profile's plugins never silently disables a bundle only the destination had.
    let sourceDependencies = ProfileManifest.dependencies(sourceManifest)
    let destinationDependencies = ProfileManifest.dependencies(destinationManifest)
    var dependencyChanges: [String] = []
    for name in sourceDependencies.keys.sorted() {
      let spec = sourceDependencies[name] ?? ""
      if let existing = destinationDependencies[name] {
        if existing != spec { dependencyChanges.append("update \(name) \(existing) to \(spec)") }
      } else {
        dependencyChanges.append("add \(name) \(spec)")
      }
    }

    // Appended, never re-sorted: layer order is meaningful, and the harness itself appends
    // when it reconciles. The destination's order is therefore kept and the incoming
    // bundles that it does not have are added at the end — which is exactly what apply
    // writes, so the preview and the operation cannot disagree.
    let sourceBundles = ProfileManifest.bundleList(sourceManifest)
    let destinationBundles = ProfileManifest.bundleList(destinationManifest)
    var mergedBundles = destinationBundles
    for name in sourceBundles where !mergedBundles.contains(name) { mergedBundles.append(name) }
    let bundleChanges = sourceBundles
      .filter { !destinationBundles.contains($0) }
      .map { "enable \($0)" }

    let sourcePatch = (try? String(contentsOf: sourceDirectory.appendingPathComponent("cordis.patch.yml"), encoding: .utf8)) ?? ""
    let destinationPatch = (try? String(contentsOf: destinationDirectory.appendingPathComponent("cordis.patch.yml"), encoding: .utf8)) ?? ""
    var patchChanges: [String] = []
    if let merged = try CordisPatchEditor.mergeEntries(
      sourcePatch,
      into: destinationPatch,
      marker: Self.patchMarker(for: request)
    ) {
      patchChanges = merged.appended.map { "append patch entry \($0)" }
        + merged.replaced.map { "replace patch entry \($0)" }
        + (merged.repaired ? ["drop the stray empty array so the file parses"] : [])
    }

    let sourceWorkspace = (try? String(
      contentsOf: sourceDirectory.appendingPathComponent("pnpm-workspace.yaml"),
      encoding: .utf8
    )) ?? ""
    let destinationWorkspaceURL = destinationDirectory.appendingPathComponent("pnpm-workspace.yaml")
    let destinationWorkspace = (try? String(contentsOf: destinationWorkspaceURL, encoding: .utf8)) ?? ""
    let allowBuildAdditions = FileManager.default.fileExists(atPath: destinationWorkspaceURL.path)
      ? PnpmWorkspaceEditor
        .allowedBuildNames(in: sourceWorkspace)
        .subtracting(PnpmWorkspaceEditor.allowedBuildNames(in: destinationWorkspace))
        .sorted()
      : []

    // An undeclared package is the normal case for a hoisted tree: pnpm hoists the whole
    // transitive closure next to the declared dependencies, and the closure is what makes
    // the copy self-contained. Counting them explains the number to a user who is about to
    // watch 146 directories appear.
    let copiedNames = items
      .filter { $0.action.writes && $0.location == .nodeModules }
      .map { $0.name }
    // Dotted names are shims and bookkeeping rather than packages, and are not counted here.
    let undeclared = copiedNames.filter {
      sourceDependencies[$0] == nil && !$0.hasPrefix(".") && !Self.bookkeepingEntries.contains($0)
    }
    if !undeclared.isEmpty {
      warnings.append(
        "\(undeclared.count) of the copied entries are not declared in the source profile's dependencies; they are its hoisted dependency closure, which is what makes the copied tree runnable on its own."
      )
    }

    if let sourceHarness = Self.harnessVersion(in: request.sourceHome),
       let destinationHarness = Self.harnessVersion(in: paths.dshHome),
       sourceHarness != destinationHarness {
      warnings.append(
        "The source home is running dsh \(sourceHarness) and this app runs \(destinationHarness). A plugin built against a different release can fail to activate — Node does not check the range at load time — so run the compose check after importing and disable whatever it names."
      )
    }

    for item in items where item.action == .replace {
      guard let sourceVersion = item.sourceVersion,
            let destinationVersion = item.destinationVersion,
            let source = Semver(sourceVersion),
            let destination = Semver(destinationVersion),
            source < destination else { continue }
      warnings.append(
        "\(item.name) \(destinationVersion) here is newer than \(sourceVersion) in the source; the source's copy replaces it."
      )
    }

    return PluginImportPlan(
      request: request,
      sourceDirectory: sourceDirectory,
      destinationDirectory: destinationDirectory,
      items: items.sorted { $0.name < $1.name },
      dependencyChanges: dependencyChanges,
      bundleChanges: bundleChanges,
      patchChanges: patchChanges,
      allowBuildAdditions: allowBuildAdditions,
      totalBytes: totalBytes,
      backupBytes: backupBytes,
      warnings: warnings
    )
  }

  // MARK: - Applying

  /// Perform the copy described by a plan.
  ///
  /// The order matters and is deliberate: the space check comes before anything is
  /// written, the destination's own files are snapshotted into a backup before they are
  /// replaced, every package copy happens before the manifest is touched, and the manifest
  /// is written last. A failure at any point therefore leaves the profile declaring exactly
  /// what it declared before, with at worst some unreferenced directories beside it.
  public func apply(
    _ plan: PluginImportPlan,
    progress: @escaping @Sendable (PluginImportProgress) -> Void = { _ in }
  ) async throws -> PluginImportOutcome {
    let lock = try FileLock(url: paths.lockFile)
    defer { lock.release() }
    try lock.acquire(holderDescription: "plugin import into \(plan.request.destinationProfile)")

    let required = plan.totalBytes + plan.backupBytes + 256 * 1024 * 1024
    let available = try ArchiveInspector.availableBytes(at: paths.root)
    guard available >= required else {
      throw RuntimeError.insufficientSpace(requiredBytes: required, availableBytes: available)
    }

    // A second import inside the same second must not land in the first one's backup: the
    // snapshot files below are copied, not overwritten.
    let stamp = Self.stamp()
    let firstChoice = paths.backupsRoot.appendingPathComponent("plugin-import-\(stamp)", isDirectory: true)
    let backup = FileManager.default.fileExists(atPath: firstChoice.path)
      ? paths.backupsRoot.appendingPathComponent("plugin-import-\(stamp)-\(UUID().uuidString.prefix(4))", isDirectory: true)
      : firstChoice
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

    // Snapshot the files this operation rewrites, so a hand edit is never lost to it.
    for name in ["package.json", "cordis.patch.yml", "pnpm-workspace.yaml"] {
      let url = plan.destinationDirectory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      try FileManager.default.copyItem(at: url, to: backup.appendingPathComponent("\(name).before"))
    }

    var copied: [String] = []
    var replaced: [String] = []
    var skipped: [String] = []
    var changes: [String] = []
    var bytesCopied: Int64 = 0
    var warnings = plan.warnings

    let sourceNodeModules = plan.sourceDirectory.appendingPathComponent("node_modules", isDirectory: true)
    let destinationNodeModules = plan.destinationDirectory.appendingPathComponent("node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: destinationNodeModules, withIntermediateDirectories: true)

    for item in plan.items {
      let source = item.location == .profileRoot
        ? plan.sourceDirectory.appendingPathComponent(item.name)
        : Self.url(of: item.name, in: sourceNodeModules)
      let destination = item.location == .profileRoot
        ? plan.destinationDirectory.appendingPathComponent(item.name)
        : Self.url(of: item.name, in: destinationNodeModules)

      switch item.action {
      case .skipIdentical, .skipExisting:
        skipped.append(item.name)

      case .mergeMissing:
        let merged = try await merge(from: source, into: destination)
        for name in merged.brokenLinks {
          warnings.append("node_modules/\(item.name)/\(name) points at a package the source no longer has; that broken shim was not copied.")
        }
        if merged.added.isEmpty {
          skipped.append(item.name)
        } else {
          copied.append(item.name)
          changes.append("added \(merged.added.count) file(s) to node_modules/\(item.name): \(merged.added.joined(separator: ", "))")
        }

      case .copy:
        progress(PluginImportProgress(message: "Copying \(item.name)"))
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        // Resolved first: a package linked into the source profile rather than materialized
        // in it has to arrive as content, or the destination would only inherit a link into
        // the home it came from.
        try await inspector.copyDirectory(source.resolvingSymlinksInPath(), to: destination)
        copied.append(item.name)
        bytesCopied += item.byteCount

      case .replace:
        progress(PluginImportProgress(message: "Replacing \(item.name)"))
        let staged = backup.appendingPathComponent("node_modules/\(item.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.moveItem(at: destination, to: staged)
        }
        do {
          try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try await inspector.copyDirectory(source.resolvingSymlinksInPath(), to: destination)
        } catch {
          // Put the original back rather than leave the profile with neither copy.
          try? FileManager.default.removeItem(at: destination)
          try? FileManager.default.moveItem(at: staged, to: destination)
          throw error
        }
        replaced.append(item.name)
        bytesCopied += item.byteCount
      }
    }

    // The manifest and the patch layer are the last things written.
    let destinationManifestURL = plan.destinationDirectory.appendingPathComponent("package.json")
    let sourceManifestURL = plan.sourceDirectory.appendingPathComponent("package.json")
    var manifest = try ProfileManifest.read(destinationManifestURL)
    var dependencies = ProfileManifest.dependencies(manifest)
    for (name, spec) in ProfileManifest.dependencies(try ProfileManifest.read(sourceManifestURL)) {
      dependencies[name] = spec
    }
    manifest = ProfileManifest.setDependencies(manifest, dependencies)
    var bundles = ProfileManifest.bundleList(manifest)
    for name in ProfileManifest.bundleList(try ProfileManifest.read(sourceManifestURL)) where !bundles.contains(name) {
      bundles.append(name)
    }
    manifest = ProfileManifest.setBundleList(manifest, bundles)
    try ProfileManifest.write(manifest, to: destinationManifestURL)
    changes.append("wrote package.json: \(dependencies.count) dependencies, \(bundles.count) bundles")

    let sourcePatch = (try? String(contentsOf: plan.sourceDirectory.appendingPathComponent("cordis.patch.yml"), encoding: .utf8)) ?? ""
    let destinationPatchURL = plan.destinationDirectory.appendingPathComponent("cordis.patch.yml")
    let destinationPatch = (try? String(contentsOf: destinationPatchURL, encoding: .utf8)) ?? ""
    if let merged = try CordisPatchEditor.mergeEntries(
      sourcePatch,
      into: destinationPatch,
      marker: Self.patchMarker(for: plan.request)
    ) {
      try merged.text.write(to: destinationPatchURL, atomically: true, encoding: .utf8)
      changes.append(contentsOf: merged.appended.map { "appended patch entry \($0)" })
      changes.append(contentsOf: merged.replaced.map { "replaced patch entry \($0)" })
      if merged.repaired { changes.append("removed a stray empty array from cordis.patch.yml") }
    }

    let destinationWorkspaceURL = plan.destinationDirectory.appendingPathComponent("pnpm-workspace.yaml")
    if !plan.allowBuildAdditions.isEmpty, FileManager.default.fileExists(atPath: destinationWorkspaceURL.path) {
      let destinationWorkspace = (try? String(contentsOf: destinationWorkspaceURL, encoding: .utf8)) ?? ""
      if let updated = PnpmWorkspaceEditor.applyAllowBuilds(destinationWorkspace, names: plan.allowBuildAdditions) {
        try updated.write(to: destinationWorkspaceURL, atomically: true, encoding: .utf8)
        changes.append("allowed builds: \(plan.allowBuildAdditions.joined(separator: ", "))")
      }
    }

    let record = PluginImportBackupRecord(
      sourceHome: plan.request.sourceHome.path,
      sourceProfile: plan.request.sourceProfile,
      destinationProfile: plan.request.destinationProfile,
      conflictPolicy: plan.request.conflictPolicy.rawValue,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      copied: copied,
      replaced: replaced,
      skipped: skipped,
      bytesCopied: bytesCopied
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: backup.appendingPathComponent("manifest.json"), options: .atomic)

    warnings.append("Restart the harness for the imported plugins to load.")
    return PluginImportOutcome(
      backupDirectory: backup,
      copied: copied,
      replaced: replaced,
      skipped: skipped,
      bytesCopied: bytesCopied,
      changes: changes,
      warnings: warnings
    )
  }

  // MARK: - Verification

  /// Answer three questions about a profile, each of which a plugin can fail on its own.
  ///
  /// 1. **Does the tree compose?** `--dump-config` asks the harness to initialize a missing
  ///    profile and print the composed loader tree. It starts no server, but it does write
  ///    the profile's `cordis.yml`, so it is a read of the *composition*, not of the disk.
  /// 2. **Do the plugins import?** Each enabled plugin's entry module is imported by name in
  ///    a throwaway Node process. A named export the runtime no longer provides fails here
  ///    and nowhere else.
  /// 3. **Does it start?** When `booting` is true the harness is launched for real, on a
  ///    free port, until it announces its URL — and stopped again. This is the only check
  ///    that sees a plugin whose import succeeds and whose *application* throws, which is
  ///    what a moved runtime API looks like from the outside. The loader has no per-plugin
  ///    isolation, so one of those is a boot failure for the whole profile.
  public func verify(
    profile: String,
    expecting: [String] = [],
    booting: Bool = false
  ) async throws -> PluginImportVerification {
    let verification = try await inspect(profile: profile, expecting: expecting)
    guard booting else { return verification }
    return try await withBootCheck(verification, profile: profile)
  }

  /// Composition and imports, without starting anything.
  public func inspect(profile: String, expecting: [String] = []) async throws -> PluginImportVerification {
    let store = PluginStore(
      paths: paths,
      entryProvider: entryProvider,
      runner: runner,
      baseEnvironment: baseEnvironment
    )
    let records = try await store.plugins(profile: profile)
    let directory = paths.profilesDirectory.appendingPathComponent(profile, isDirectory: true)

    var entries = records.map { record in
      PluginImportVerification.Entry(
        name: record.name,
        installedVersion: record.installedVersion,
        isBundle: record.isBundle,
        isEnabled: record.isEnabled,
        problem: Self.problem(for: record, in: directory)
      )
    }
    for name in expecting where !records.contains(where: { $0.name == name }) {
      entries.append(
        PluginImportVerification.Entry(
          name: name,
          installedVersion: nil,
          isBundle: false,
          isEnabled: false,
          problem: "imported but absent from profile \(profile)"
        )
      )
    }

    // What the loader would actually load: a disabled entry is never imported, so checking
    // it would report a failure the harness would never hit.
    let loadable = entries.filter { $0.isEnabled && $0.problem != "declared but not materialized in node_modules" }
    let failures = try await importFailures(
      profile: profile,
      names: loadable.map { $0.name }
    )
    for index in entries.indices {
      guard let reason = failures[entries[index].name] else { continue }
      entries[index].problem = "cannot be imported by this runtime: \(reason)"
    }

    let entry = try await entryProvider()
    let request = try await invocation.request(
      entry: entry,
      arguments: ["--profile", profile, "--dump-config"],
      timeout: 300
    )
    let result = try await runner.run(request, onLine: nil)

    return PluginImportVerification(
      entries: entries.sorted { $0.name < $1.name },
      composeSucceeded: result.succeeded,
      composeDiagnostic: result.succeeded ? nil : result.diagnostics(maxLines: 40),
      importFailures: failures,
      boot: nil
    )
  }

  /// Attach the answer to "does it start" to an inspection that already passed the first two
  /// questions.
  ///
  /// A profile that cannot compose or import is not booted: the failure is already known, and
  /// starting a server to watch it fail the same way costs a port and half a minute.
  private func withBootCheck(
    _ verification: PluginImportVerification,
    profile: String
  ) async throws -> PluginImportVerification {
    guard verification.composeSucceeded, verification.importFailures.isEmpty else { return verification }
    var result = verification
    let boot = await bootCheck(profile: profile)
    result.boot = boot
    if !boot.started {
      for index in result.entries.indices where boot.suspects.contains(result.entries[index].name) {
        result.entries[index].problem = "stops the harness from starting"
      }
    }
    return result
  }

  /// Start the profile for real, wait for it to announce its URL, then stop it.
  ///
  /// The launcher is the one the console uses, so this exercises the same path a user's
  /// Start button does — including the environment the harness is given.
  public func bootCheck(profile: String, timeout: TimeInterval = 120) async -> PluginBootCheck {
    let first = await attemptBoot(profile: profile, timeout: timeout)
    guard !first.started, first.suspects.isEmpty, (first.diagnostic ?? "").contains("exited with code 0") else {
      return first
    }
    // A clean exit before the URL is never a legitimate outcome for "serve the web UI", and
    // it is exactly what an instance left over from a previous attempt looks like — the
    // previous boot's plugins hold their own ports, and the new instance gives up. One retry
    // tells a race apart from a real failure; a second one would just be a slower lie.
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    return await attemptBoot(profile: profile, timeout: timeout)
  }

  private func attemptBoot(profile: String, timeout: TimeInterval) async -> PluginBootCheck {
    let launcher = HarnessLauncher(paths: paths, entryProvider: entryProvider, runner: runner, baseEnvironment: baseEnvironment)
    do {
      let state = try await launcher.start(profile: profile, timeout: timeout)
      await launcher.stop()
      return PluginBootCheck(started: true, url: state.url)
    } catch {
      await launcher.stop()
      let detail = (error as? RuntimeError)?.errorDescription ?? String(describing: error)
      let known = Set((try? await knownPluginNames(profile: profile)) ?? [])
      return PluginBootCheck(
        started: false,
        diagnostic: detail,
        suspects: Self.pluginSuspects(in: detail, profile: profile, known: known)
      )
    }
  }

  /// The package names this profile declares.
  private func knownPluginNames(profile: String) async throws -> [String] {
    let manifest = try ProfileManifest.read(
      paths.profilesDirectory.appendingPathComponent(profile, isDirectory: true)
        .appendingPathComponent("package.json")
    )
    return Array(ProfileManifest.dependencies(manifest).keys)
  }

  /// Read a failed boot's output for the plugins it blames.
  ///
  /// Two shapes are worth reading, and both were taken from real failures on this machine:
  ///
  /// - `failed to apply loader entry dsh-pocket (dsh-pocket): cannot get property "webServer"`
  ///   names the loader row, which is usually the package;
  /// - a stack frame under `profiles/<profile>/node_modules/<package>/…` names the file that
  ///   threw, which is the more reliable of the two and works for scoped packages.
  ///
  /// Only names that exist in the profile are returned: a guess must never cause the console
  /// to disable something that was not to blame.
  static func pluginSuspects(in diagnostic: String, profile: String, known: Set<String>) -> [String] {
    guard !known.isEmpty else { return [] }
    var suspects: Set<String> = []

    let marker = "/profiles/\(profile)/node_modules/"
    for line in diagnostic.components(separatedBy: "\n") {
      if let range = line.range(of: marker) {
        let remainder = line[range.upperBound...]
        let components = remainder.split(separator: "/", omittingEmptySubsequences: false)
        if let first = components.first {
          var name = String(first)
          if name.hasPrefix("@"), components.count > 1 {
            name += "/" + String(components[1])
          }
          if known.contains(name) { suspects.insert(name) }
        }
      }
      if let range = line.range(of: "failed to apply loader entry ") {
        let token = line[range.upperBound...].prefix { $0 != " " && $0 != "(" && $0 != ":" && $0 != "\"" }
        if known.contains(String(token)) { suspects.insert(String(token)) }
      }
    }
    return suspects.sorted()
  }

  /// Disable whatever this runtime cannot load, one failure at a time, until it starts.
  ///
  /// A repair loop rather than an answer, because the failures are not discoverable in one
  /// pass: the loader stops at the first plugin it cannot apply, so the second incompatible
  /// plugin is only visible after the first is out of the way. Each round disables everything
  /// it can prove guilty and boots again.
  public func quarantine(
    profile: String,
    maxRounds: Int = 8,
    progress: @escaping @Sendable (PluginImportProgress) -> Void = { _ in }
  ) async throws -> PluginQuarantineOutcome {
    let store = PluginStore(
      paths: paths,
      entryProvider: entryProvider,
      runner: runner,
      baseEnvironment: baseEnvironment
    )
    var disabled: [String] = []
    var rounds = 0
    var lastDiagnostic: String?

    while rounds < maxRounds {
      rounds += 1
      progress(PluginImportProgress(message: "Round \(rounds): checking \(profile)"))
      let verification = try await verify(profile: profile, booting: true)
      if verification.isHealthy {
        return PluginQuarantineOutcome(disabled: disabled, rounds: rounds, started: true)
      }
      lastDiagnostic = verification.boot?.diagnostic ?? verification.composeDiagnostic

      var suspects = Set(verification.importFailures.keys).subtracting(disabled)
      suspects.formUnion((verification.boot?.suspects ?? []).filter { !disabled.contains($0) })
      // An import-check sentinel is not a package name and cannot be disabled.
      suspects = suspects.filter { !$0.hasPrefix("(") }
      guard !suspects.isEmpty else {
        return PluginQuarantineOutcome(
          disabled: disabled,
          rounds: rounds,
          started: verification.boot?.started ?? false,
          diagnostic: lastDiagnostic
        )
      }

      for name in suspects.sorted() {
        progress(PluginImportProgress(message: "Disabling \(name)"))
        let result = try await store.setEnabled(name, enabled: false, profile: profile)
        for warning in result.warnings where !warning.hasPrefix("Restart") { _ = warning }
        disabled.append(name)
      }
    }

    return PluginQuarantineOutcome(
      disabled: disabled,
      rounds: rounds,
      started: false,
      diagnostic: lastDiagnostic
    )
  }

  /// Import each named plugin in a throwaway Node process and report the ones that fail.
  ///
  /// This is the check that catches a plugin built against a *different* harness release.
  /// The declared version range says nothing: the failing plugin here declares
  /// `>=0.1.0-rc.5` for a package whose newest release simply no longer exports the name it
  /// imports, and Node does not check ranges at load time. Only loading it tells the truth —
  /// and loading it costs a second, where a boot costs a port and a failure the user sees
  /// before the UI ever appears.
  public func importFailures(profile: String, names: [String]) async throws -> [String: String] {
    guard !names.isEmpty else { return [:] }
    let directory = paths.profilesDirectory.appendingPathComponent(profile, isDirectory: true)
    let request = try await invocation.nodeRequest(
      script: Self.importCheckScript,
      arguments: names,
      currentDirectory: directory,
      timeout: 180,
      label: "import check for \(profile)"
    )
    let result = try await runner.run(request, onLine: nil)

    var failures: [String: String] = [:]
    for line in result.stdout.components(separatedBy: "\n") {
      let parts = line.components(separatedBy: "|")
      guard parts.count >= 2, parts[0] == "fail" else { continue }
      failures[parts[1]] = parts.count > 2 && !parts[2].isEmpty ? parts[2] : "the module could not be imported"
    }
    // A process that died before printing anything is a failure of the check itself, and
    // saying so beats reporting a healthy profile.
    if failures.isEmpty, !result.succeeded {
      failures["(import check)"] = result.diagnostics(maxLines: 10)
    }
    return failures
  }

  /// The one-liner Node runs: import each name, print one line per plugin.
  ///
  /// Kept as a constant so the parser and the script cannot drift apart.
  static let importCheckScript = """
  for (const name of process.argv.slice(1)) {
    try {
      await import(name)
      console.log("ok|" + name)
    } catch (error) {
      console.log("fail|" + name + "|" + String((error && error.message) || error).split("\\n")[0])
    }
  }
  """

  // MARK: - Copy helpers

  /// Copy the files of one directory that the destination does not already have.
  ///
  /// Used for a profile's `.bin`, where both sides legitimately own entries — replacing the
  /// directory wholesale would drop the shims this profile's own packages installed.
  ///
  /// Entries are copied one at a time instead of with a single `ditto` of the directory,
  /// because a shim **is** a symlink: handing a link to `ditto` as a source root makes it
  /// resolve that root, and a pruned install leaves links pointing at packages which are no
  /// longer there. A link whose target is gone is reported rather than reproduced.
  ///
  /// Returns what it added and what it deliberately left behind.
  private func merge(
    from source: URL,
    into destination: URL
  ) async throws -> (added: [String], brokenLinks: [String]) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: source.path) else { return ([], []) }
    var added: [String] = []
    var brokenLinks: [String] = []
    for entry in (try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])) ?? [] {
      let name = entry.lastPathComponent
      let target = destination.appendingPathComponent(name)
      guard !fileManager.fileExists(atPath: target.path) else { continue }
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

      // A shim is a symlink, and a pruned install leaves links that point at packages which
      // are no longer there. Handing one to ditto as a source root makes ditto resolve it —
      // which is where the copy of this directory failed the first time it was tried — so
      // links are recreated by hand and a link whose target is gone is reported instead of
      // being reproduced as a broken shim.
      if let linkTarget = try? fileManager.destinationOfSymbolicLink(atPath: entry.path) {
        guard !Self.isDangling(entry) else {
          brokenLinks.append(name)
          continue
        }
        try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
      } else {
        try fileManager.copyItem(at: entry, to: target)
      }
      added.append(name)
    }
    return (added.sorted(), brokenLinks.sorted())
  }

  // MARK: - Reading a tree

  private struct TreeEntry {
    var name: String
    var url: URL
  }

  /// The packages directly inside a profile's node_modules, with scopes expanded.
  ///
  /// Scopes are expanded on purpose: `@scope` is a container, and treating it as one entry
  /// would make the whole scope all-or-nothing — a scope the destination already has would
  /// block every package inside it, and replacing one would delete the destination's other
  /// packages in the same scope.
  private static func entries(in nodeModules: URL) -> [TreeEntry] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: nodeModules.path) else { return [] }
    var result: [TreeEntry] = []
    for name in names.sorted() {
      let url = nodeModules.appendingPathComponent(name)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        result.append(TreeEntry(name: name, url: url))
        continue
      }
      guard name.hasPrefix("@") else {
        result.append(TreeEntry(name: name, url: url))
        continue
      }
      let children = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
        .filter { $0 != ".DS_Store" }
      // An empty scope is a leftover from a pruned install, not content: copying it would
      // only put an empty directory in a tree Node resolves by name.
      guard !children.isEmpty else { continue }
      for child in children.sorted() {
        result.append(TreeEntry(name: "\(name)/\(child)", url: url.appendingPathComponent(child)))
      }
    }
    return result
  }

  /// Whether a path is a symlink whose target is not there.
  ///
  /// A pruned install leaves these behind in a profile's `.bin`, and `ditto` refuses to use
  /// one as a source root — so they are identified up front rather than discovered by a
  /// failed copy halfway through.
  private static func isDangling(_ url: URL) -> Bool {
    let fileManager = FileManager.default
    guard let linkTarget = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return false }
    let resolved = URL(fileURLWithPath: linkTarget, relativeTo: url.deletingLastPathComponent())
    return !fileManager.fileExists(atPath: resolved.standardizedFileURL.path)
  }

  private static func missingNames(from source: URL, in destination: URL) -> [String] {
    let fileManager = FileManager.default
    let names = (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? []
    return names.filter { !fileManager.fileExists(atPath: destination.appendingPathComponent($0).path) }
  }

  /// Resolve an entry name that may carry a scope into a URL under a node_modules.
  private static func url(of name: String, in nodeModules: URL) -> URL {
    name.split(separator: "/").reduce(nodeModules) { partial, component in
      partial.appendingPathComponent(String(component))
    }
  }

  private static func version(ofPackageAt url: URL) -> String? {
    guard let manifest = try? ProfileManifest.read(url.appendingPathComponent("package.json")) else { return nil }
    return manifest["version"]?.stringValue
  }

  /// A directory is measured as a directory; a file as itself.
  private static func byteCount(of url: URL) -> Int64 {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    if isDirectory.boolValue { return ArchiveInspector.byteCount(ofDirectory: url) }
    return (try? ArchiveInspector.byteCount(of: url)) ?? 0
  }

  /// Whether a profile's node_modules has been written by a package manager.
  private static func hasPNPMState(_ nodeModules: URL) -> Bool {
    let fileManager = FileManager.default
    return fileManager.fileExists(atPath: nodeModules.appendingPathComponent(".modules.yaml").path)
      || fileManager.fileExists(atPath: nodeModules.appendingPathComponent(".pnpm").path)
  }

  /// The version of dsh a home is running, read from the installation closure it shares
  /// across its profiles.
  static func harnessVersion(in home: URL) -> String? {
    let manifest = home
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent("node_modules", isDirectory: true)
      .appendingPathComponent("@deepseek-ai/dsh/package.json")
    guard let value = try? ProfileManifest.read(manifest) else { return nil }
    return value["version"]?.stringValue
  }

  static func patchMarker(for request: PluginImportRequest) -> String {
    "# --- imported from \(request.sourceHome.lastPathComponent)/profiles/\(request.sourceProfile) ---"
  }

  static func stamp(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: now)
  }

  /// What stops a plugin from doing anything, phrased for the person who has to decide
  /// whether to keep it.
  private static func problem(for record: PluginRecord, in profileDirectory: URL) -> String? {
    if record.installedVersion == nil {
      return "declared but not materialized in node_modules"
    }
    if record.isConfigDisabled {
      return "disabled by cordis.patch.yml, so it will not load"
    }
    if record.isBundle && !record.isEnabled {
      return "not in dsh.profile.bundles, so it does not join the layer stack"
    }
    if !record.isBundle {
      return "declares no dsh.bundle, so it is installed but inert"
    }
    return nil
  }
}
