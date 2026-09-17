import Foundation
import HarnessKit

/// A progress report from a long-running install.
public struct InstallProgress: Sendable, Equatable {
  public enum Phase: String, Sendable, Equatable {
    case inspecting
    case verifying
    case extracting
    case installingDependencies
    case building
    case validating
    case smokeTesting
    case committing

    public var displayName: String {
      switch self {
      case .inspecting: return "Inspecting"
      case .verifying: return "Verifying"
      case .extracting: return "Unpacking"
      case .installingDependencies: return "Installing dependencies"
      case .building: return "Building"
      case .validating: return "Validating"
      case .smokeTesting: return "Starting the harness once"
      case .committing: return "Committing"
      }
    }
  }

  public var phase: Phase
  public var message: String
  /// `0…1` when the step has a real measure; `nil` when it is indeterminate.
  public var fraction: Double?

  public init(phase: Phase, message: String, fraction: Double? = nil) {
    self.phase = phase
    self.message = message
    self.fraction = fraction
  }
}

/// The result of an install request.
public struct InstallOutcome: Sendable, Equatable {
  public var release: HarnessRelease
  /// True when an identical release was already present and nothing was rebuilt.
  public var reused: Bool
  /// Non-fatal things the user should know — an unverified digest, a skipped pnpm.
  public var warnings: [String]

  public init(release: HarnessRelease, reused: Bool, warnings: [String] = []) {
    self.release = release
    self.reused = reused
    self.warnings = warnings
  }
}

/// Installs, activates, and removes harness runtimes.
///
/// Every mutation happens inside a staging directory on the same volume as the release
/// store, so committing an install is a `rename(2)`: a failure at any earlier point
/// leaves no half-installed release for the engine to trip over. The ledger is written
/// after the rename, and the `current` symlink is swapped with `rename(2)` as well, so a
/// crash can lose a release but can never produce a release that is present and broken.
public actor HarnessInstaller {
  public let paths: RuntimePaths
  public let runner: ProcessRunning
  public let baseEnvironment: [String: String]
  public let inspector: ArchiveInspector
  public let validator: ReleaseValidator
  public let toolchainResolver: ToolchainResolver

  public init(
    paths: RuntimePaths,
    runner: ProcessRunning = ProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.paths = paths
    self.runner = runner
    self.baseEnvironment = baseEnvironment
    self.inspector = ArchiveInspector(runner: runner)
    self.validator = ReleaseValidator(runner: runner)
    self.toolchainResolver = ToolchainResolver(paths: paths, runner: runner, baseEnvironment: baseEnvironment)
  }

  // MARK: - Ledger

  public func index() throws -> InstallsIndex {
    try InstallsIndex.load(from: paths.installsIndex)
  }

  public func releases() throws -> [HarnessRelease] {
    try index().releases.sorted { $0.installedAt > $1.installedAt }
  }

  public func activeRelease() throws -> HarnessRelease? {
    let index = try index()
    guard let release = index.activeRelease else { return nil }
    // A ledger entry whose directory was deleted by hand is reported as absent rather
    // than returned, so callers never get a path that cannot be executed.
    guard release.isMaterialized(in: paths.releaseDirectory(release.id)) else { return nil }
    return release
  }

  /// The CLI entry point of the active release.
  public func activeEntryURL() throws -> URL {
    guard let release = try activeRelease() else { throw RuntimeError.noActiveRelease }
    return release.entryURL(in: paths.releaseDirectory(release.id))
  }

  public func toolchain() async throws -> Toolchain {
    try await toolchainResolver.resolve()
  }

  // MARK: - Install

  /// Run the full install pipeline for `source`.
  public func install(
    _ source: InstallSource,
    activate shouldActivate: Bool = true,
    progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
  ) async throws -> InstallOutcome {
    let lock = try FileLock(url: paths.lockFile)
    defer { lock.release() }
    try lock.acquire(holderDescription: "install")

    try paths.createDirectories()
    let operationID = UUID().uuidString
    let staging = paths.stagingDirectory(operationID)
    try? FileManager.default.removeItem(at: staging)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    var warnings: [String] = []
    let kind = source.kind

    // 1–4. Obtain the payload in staging and record what is known about its integrity.
    let prepared = try await prepare(source, staging: staging, kind: kind, warnings: &warnings, progress: progress)

    // 5–6. Locate the payload root and confirm the expected entry point is there.
    let payloadRoot = try Self.payloadRoot(in: staging, kind: kind)
    progress(InstallProgress(phase: .validating, message: "Checking the entry point"))
    let version = try validator.validate(directory: payloadRoot, kind: kind)

    // 7. Start it once. An install that cannot run is not an install.
    let toolchain = try await toolchainResolver.resolve()
    progress(InstallProgress(phase: .smokeTesting, message: "Running \(ReleaseValidator.entryPath(for: kind)) --version"))
    let reported = try await validator.smokeTest(
      directory: payloadRoot,
      kind: kind,
      node: toolchain.node,
      environment: toolchainResolver.harnessEnvironment(for: toolchain)
    )
    if !reported.contains(version) {
      warnings.append("The runtime reported \(reported) but the manifest declares \(version).")
    }

    // 8. Commit. The id is derived from the verified version, so an identical install
    //    resolves to the directory that already exists.
    let id = HarnessRelease.makeID(
      version: version,
      kind: kind,
      token: HarnessRelease.idToken(kind: kind, digest: prepared.digest)
    )
    let destination = paths.releaseDirectory(id)
    var ledger = try InstallsIndex.load(from: paths.installsIndex)

    if let existing = ledger.release(id: id), existing.isMaterialized(in: destination) {
      progress(InstallProgress(phase: .committing, message: "Already installed"))
      try? FileManager.default.removeItem(at: staging)
      if shouldActivate { try activateLocked(id, ledger: &ledger) }
      return InstallOutcome(release: existing, reused: true, warnings: warnings)
    }

    progress(InstallProgress(phase: .committing, message: "Publishing \(id)"))
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: payloadRoot, to: destination)
    if payloadRoot.path != staging.path {
      try? FileManager.default.removeItem(at: staging)
    }

    let release = HarnessRelease(
      id: id,
      version: version,
      entry: ReleaseValidator.entryPath(for: kind),
      source: SourceRecord(kind: kind, spec: source.spec, tag: source.tag),
      integrity: prepared.integrity,
      installedAt: Date(),
      byteCount: ArchiveInspector.byteCount(ofDirectory: destination)
    )
    ledger.releases.removeAll { $0.id == id }
    ledger.releases.append(release)
    ledger.releases.sort { $0.installedAt < $1.installedAt }
    try ledger.save(to: paths.installsIndex)

    if shouldActivate {
      try activateLocked(id, ledger: &ledger)
    }
    return InstallOutcome(release: release, reused: false, warnings: warnings)
  }

  // MARK: - Activation and removal

  /// Point `current` at an installed release.
  public func activate(_ id: String) throws {
    let lock = try FileLock(url: paths.lockFile)
    defer { lock.release() }
    try lock.acquire(holderDescription: "activate")
    var ledger = try InstallsIndex.load(from: paths.installsIndex)
    try activateLocked(id, ledger: &ledger)
  }

  private func activateLocked(_ id: String, ledger: inout InstallsIndex) throws {
    guard let release = ledger.release(id: id) else { throw RuntimeError.releaseNotFound(id) }
    let directory = paths.releaseDirectory(id)
    guard release.isMaterialized(in: directory) else {
      throw RuntimeError.archiveMissingEntry("\(release.entry) in \(directory.path)")
    }
    try Self.swapSymlink(at: paths.currentLink, to: directory)
    ledger.active = id
    try ledger.save(to: paths.installsIndex)
  }

  /// Delete an installed release. The active release cannot be removed, because there
  /// would be nothing left for `current` to point at.
  ///
  /// Any process still executing code out of this release is stopped first, and the
  /// directory is left alone when one cannot be stopped. Deleting the files alone — which
  /// is all this used to do — produced a server running a release directory that no
  /// longer existed: nothing could reap it by release (`remove(_:)` had already deleted
  /// it), the plugin market's restart had replaced the `server.json` record with its own
  /// pid, and 384 MB stayed resident for two days. A directory that is the last handle on
  /// a live process is not free to delete.
  public func remove(_ id: String) throws {
    let lock = try FileLock(url: paths.lockFile)
    defer { lock.release() }
    try lock.acquire(holderDescription: "remove")

    var ledger = try InstallsIndex.load(from: paths.installsIndex)
    guard ledger.release(id: id) != nil else { throw RuntimeError.releaseNotFound(id) }
    if ledger.active == id { throw RuntimeError.releaseInUse(id) }

    // An upgrade that is still in flight names this release as its way back. Deleting it
    // would leave the pending marker pointing at a directory that no longer exists, which is
    // exactly the "no way back" state the upgrade refuses to start in.
    if PendingUpgradeStore(paths: paths).record?.fromReleaseID == id {
      throw RuntimeError.releaseIsRollbackTarget(id)
    }

    // Only the servers belonging to *this* release are stopped: removing one old runtime
    // is not a reason to interrupt a server the user is working through right now.
    let stragglers = HarnessServerRecord.runningServers(in: paths.releaseDirectory(id))
    let stopped = HarnessProcessSweep.terminate(stragglers.map(\.pid))
    let survivors = HarnessServerRecord.runningServers(in: paths.releaseDirectory(id))
    guard survivors.isEmpty else {
      throw RuntimeError.releaseInUse(
        "\(id) is still running in \(survivors.count) process(es) that did not stop: "
          + survivors.map { String($0.pid) }.joined(separator: ", ")
      )
    }

    try? FileManager.default.removeItem(at: paths.releaseDirectory(id))
    ledger.releases.removeAll { $0.id == id }
    try ledger.save(to: paths.installsIndex)

    lastRemoval = ReleaseRemoval(id: id, stoppedPids: stopped)
  }

  /// What the most recent `remove(_:)` had to stop to succeed, for the install pipeline's
  /// log. Empty when nothing was running from the release, which is the common case.
  public private(set) var lastRemoval: ReleaseRemoval?

  /// A release removal and the servers it had to stop first.
  public struct ReleaseRemoval: Sendable, Equatable {
    public var id: String
    public var stoppedPids: [Int32]
  }

  /// Delete leftover staging directories from failed installs.
  @discardableResult
  public func pruneStaging(keeping operationID: String? = nil) -> Int {
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: paths.stagingRoot,
      includingPropertiesForKeys: nil
    ) else { return 0 }
    var removed = 0
    for entry in entries where entry.lastPathComponent != operationID {
      if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
    }
    return removed
  }

  // MARK: - Pipeline internals

  private struct Prepared {
    var digest: String?
    var integrity: Integrity
  }

  private func prepare(
    _ source: InstallSource,
    staging: URL,
    kind: InstallSourceKind,
    warnings: inout [String],
    progress: @escaping @Sendable (InstallProgress) -> Void
  ) async throws -> Prepared {
    switch source {
    case .prebuiltArchive(let url, let expected), .sourceArchive(let url, let expected):
      return try await unpack(url: url, expectedDigest: expected, staging: staging, kind: kind, warnings: &warnings, progress: progress)

    case .githubRelease(_, _, let expected):
      // Downloading is the caller's job (see UpdateChannels); by the time a source
      // reaches the installer it is a local file. Reaching here means a caller tried to
      // install straight from a URL, which is a programming error, not a user error.
      throw RuntimeError.unsupported("install a downloaded GitHub asset as .prebuiltArchive (expected digest \(expected ?? "none"))")

    case .sourceDirectory(let url):
      progress(InstallProgress(phase: .extracting, message: "Copying \(url.lastPathComponent)"))
      // Copied, never built in place: a failed build must not leave the user's own
      // checkout with a half-written node_modules they did not ask for.
      try await inspector.copyDirectory(url, to: staging)
      try await buildSourceTreeIfNeeded(staging: staging, progress: progress)
      return Prepared(
        digest: nil,
        integrity: Integrity(digest: "", verified: false, origin: .unverifiedLocal)
      )

    case .registry(let version):
      return try await installFromRegistry(version: version, staging: staging, progress: progress)
    }
  }

  private func unpack(
    url: URL,
    expectedDigest: String?,
    staging: URL,
    kind: InstallSourceKind,
    warnings: inout [String],
    progress: @escaping @Sendable (InstallProgress) -> Void
  ) async throws -> Prepared {
    progress(InstallProgress(phase: .inspecting, message: "Reading \(url.lastPathComponent)"))
    try await inspector.validateEntries(of: url)

    progress(InstallProgress(phase: .verifying, message: "Hashing \(url.lastPathComponent)"))
    let digest = try ArchiveInspector.sha256(of: url)
    let byteCount = try ArchiveInspector.byteCount(of: url)

    // Refuse before writing anything: a half-extracted release wastes minutes and disk.
    let available = try ArchiveInspector.availableBytes(at: paths.root)
    let required = byteCount * 3 + 512 * 1024 * 1024
    guard available >= required else {
      throw RuntimeError.insufficientSpace(requiredBytes: required, availableBytes: available)
    }

    let integrity: Integrity
    if let expectedDigest {
      let normalized = expectedDigest
        .replacingOccurrences(of: "sha256:", with: "")
        .lowercased()
      guard normalized == digest.lowercased() else {
        throw RuntimeError.integrityMismatch(expected: normalized, actual: digest)
      }
      integrity = Integrity(digest: digest, verified: true, origin: .sidecar)
    } else {
      // Recorded, not hidden: a local import has nothing to check against, and the UI
      // shows that rather than implying the artifact was validated.
      integrity = Integrity(digest: digest, verified: false, origin: .unverifiedLocal)
      warnings.append("No digest was supplied for \(url.lastPathComponent); it was imported without verification.")
    }

    progress(InstallProgress(phase: .extracting, message: "Unpacking \(url.lastPathComponent)"))
    try await inspector.extract(url, to: staging)

    if kind == .sourceArchive {
      try await buildSourceTreeIfNeeded(staging: staging, progress: progress)
    }
    return Prepared(digest: digest, integrity: integrity)
  }

  /// `pnpm install` then `pnpm run build` in a source tree, unless it is already built.
  ///
  /// A checkout that already carries `apps/cli/lib/bin.js` is used as-is: a GitHub
  /// source download is the slow path, and forcing a rebuild of a tree the user just
  /// built would spend ten minutes to reach the same bytes.
  private func buildSourceTreeIfNeeded(
    staging: URL,
    progress: @escaping @Sendable (InstallProgress) -> Void
  ) async throws {
    let builtEntry = staging.appendingPathComponent(ReleaseValidator.sourceEntry)
    if FileManager.default.isReadableFile(atPath: builtEntry.path) {
      progress(InstallProgress(phase: .building, message: "Checkout is already built; skipping pnpm"))
      return
    }

    let toolchain = try await toolchainResolver.resolve()
    guard let pnpm = toolchain.pnpm else {
      throw RuntimeError.missingToolchain("pnpm (a source install must run pnpm install and pnpm run build)")
    }
    var environment = toolchainResolver.harnessEnvironment(for: toolchain)
    environment["PATH"] = [pnpm.deletingLastPathComponent().path, environment["PATH"] ?? ""].joined(separator: ":")

    // A GitHub source download carries pnpm-lock.yaml, so the frozen install is the
    // reproducible path. It is also stricter: a lockfile that no longer matches
    // package.json is a real signal, but a plain failure it is not worth blocking on.
    progress(InstallProgress(phase: .installingDependencies, message: "pnpm install --frozen-lockfile"))
    let frozen = try await runStreaming(
      ProcessRequest(
        executable: pnpm,
        arguments: ["install", "--frozen-lockfile"],
        environment: environment,
        currentDirectory: staging,
        timeout: 3600,
        label: "pnpm install"
      ),
      phase: .installingDependencies,
      progress: progress
    )
    if !frozen.succeeded {
      progress(InstallProgress(phase: .installingDependencies, message: "Retrying pnpm install without the lockfile"))
      let relaxed = try await runStreaming(
        ProcessRequest(
          executable: pnpm,
          arguments: ["install"],
          environment: environment,
          currentDirectory: staging,
          timeout: 3600,
          label: "pnpm install"
        ),
        phase: .installingDependencies,
        progress: progress
      )
      guard relaxed.succeeded else {
        throw RuntimeError.installFailed(step: "pnpm install", detail: relaxed.diagnostics())
      }
    }

    // `pnpm run build` also builds native/system, an N-API addon, so a missing C++
    // toolchain fails here rather than at extraction. The error is passed through
    // verbatim because it names the missing piece precisely.
    progress(InstallProgress(phase: .building, message: "pnpm run build (this takes several minutes)"))
    let build = try await runStreaming(
      ProcessRequest(
        executable: pnpm,
        arguments: ["run", "build"],
        environment: environment,
        currentDirectory: staging,
        timeout: 5400,
        label: "pnpm run build"
      ),
      phase: .building,
      progress: progress
    )
    guard build.succeeded else {
      throw RuntimeError.installFailed(step: "pnpm run build", detail: build.diagnostics(maxLines: 200))
    }
  }

  /// Install `@deepseek-ai/dsh` from the npm registry.
  ///
  /// `npm` is used rather than pnpm because it travels with the Node distribution and
  /// needs no shim; the profile's own plugin resolution still goes through pnpm, which
  /// is a separate concern from laying down the runtime.
  private func installFromRegistry(
    version: String,
    staging: URL,
    progress: @escaping @Sendable (InstallProgress) -> Void
  ) async throws -> Prepared {
    let toolchain = try await toolchainResolver.resolve()
    guard let npm = toolchain.npm else {
      throw RuntimeError.missingToolchain("npm, needed to install a release from the registry")
    }
    let spec = "@deepseek-ai/dsh@\(version)"
    let manifest: JSONValue = .object([
      ("name", .string("native-harness-runtime")),
      ("private", .bool(true)),
      ("dependencies", .object([("@deepseek-ai/dsh", .string(version))])),
    ])
    try Data(try manifest.serialized().utf8).write(to: staging.appendingPathComponent("package.json"))

    progress(InstallProgress(phase: .installingDependencies, message: "npm install \(spec)"))
    try FileManager.default.createDirectory(at: paths.npmCacheDirectory, withIntermediateDirectories: true)
    let result = try await runStreaming(
      ProcessRequest(
        executable: npm.program,
        arguments: npm.prefix + ["install", "--no-audit", "--no-fund", "--loglevel=error", spec],
        environment: npmEnvironment(for: toolchain),
        currentDirectory: staging,
        timeout: 3600,
        label: "npm install \(spec)"
      ),
      phase: .installingDependencies,
      progress: progress
    )
    guard result.succeeded else {
      throw RuntimeError.installFailed(step: "npm install \(spec)", detail: result.diagnostics(maxLines: 120))
    }
    // The registry publishes an integrity value, but npm has already enforced it during
    // the fetch; re-deriving it here would mean hashing hundreds of megabytes of a tree
    // npm has already verified.
    return Prepared(
      digest: nil,
      integrity: Integrity(digest: "", verified: true, origin: .npmRegistry)
    )
  }

  /// The environment npm runs with: the harness environment plus a private cache.
  ///
  /// The toolchain is threaded through rather than re-resolved, because the Node
  /// directory it contributes to \$PATH is what lets a dependency's install script find
  /// Node at all.
  private func npmEnvironment(for toolchain: Toolchain) -> [String: String] {
    var environment = toolchainResolver.harnessEnvironment(for: toolchain)
    environment["npm_config_cache"] = paths.npmCacheDirectory.path
    environment["npm_config_prefix"] = paths.npmPrefixDirectory.path
    environment["npm_config_userconfig"] = paths.runtimeRoot.appendingPathComponent("npmrc").path
    environment["npm_config_update_notifier"] = "false"
    environment["npm_config_fund"] = "false"
    environment["npm_config_audit"] = "false"
    return environment
  }

  private func runStreaming(
    _ request: ProcessRequest,
    phase: InstallProgress.Phase,
    progress: @escaping @Sendable (InstallProgress) -> Void
  ) async throws -> ProcessResult {
    try await runner.run(request) { _, line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      progress(InstallProgress(phase: phase, message: trimmed))
    }
  }

  // MARK: - Helpers

  /// Find the directory that actually holds the harness.
  ///
  /// A GitHub "Download ZIP" wraps everything in a single `<repo>-<branch>/` folder,
  /// while a prebuilt package and a `pnpm pack` tarball put `node_modules` or `apps` at
  /// the root. Descending only when there is exactly one entry — and no files — avoids
  /// picking a subdirectory out of a real checkout.
  static func payloadRoot(in staging: URL, kind: InstallSourceKind) throws -> URL {
    let root = staging
    if kind == .sourceDirectory {
      // A copied checkout keeps its own layout; the single-folder rule does not apply.
      if isHarnessRoot(root) { return root }
    } else if isHarnessRoot(root) {
      return root
    }
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey]
    )) ?? []
    let directories = contents.filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    guard contents.count == directories.count, directories.count == 1, let only = directories.first else {
      throw RuntimeError.archiveRejected(
        reason: "the archive does not contain a harness: expected \(ReleaseValidator.entryPath(for: kind)) at the root or inside a single top-level folder"
      )
    }
    return only
  }

  private static func isHarnessRoot(_ url: URL) -> Bool {
    let marker = url.appendingPathComponent("node_modules")
    let apps = url.appendingPathComponent("apps/cli/package.json")
    let packageJSON = url.appendingPathComponent("package.json")
    return FileManager.default.fileExists(atPath: marker.path)
      || FileManager.default.fileExists(atPath: apps.path)
      || FileManager.default.fileExists(atPath: packageJSON.path)
  }

  /// Atomically repoint a symlink.
  ///
  /// `FileManager.replaceItemAt` is not used: it dereferences the existing link, which
  /// would replace the release directory's contents rather than the link itself.
  static func swapSymlink(at link: URL, to target: URL) throws {
    let parent = link.deletingLastPathComponent()
    let temporary = parent.appendingPathComponent(".\(link.lastPathComponent).\(UUID().uuidString)")
    try? FileManager.default.removeItem(at: temporary)
    try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: target)
    guard rename(temporary.path, link.path) == 0 else {
      let detail = String(cString: strerror(errno))
      try? FileManager.default.removeItem(at: temporary)
      throw RuntimeError.installFailed(step: "activate", detail: "cannot replace \(link.path): \(detail)")
    }
  }
}
