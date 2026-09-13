import Foundation

/// What a Node install is doing, so a window can narrate it.
public struct NodeInstallProgress: Sendable, Equatable {
  public enum Phase: String, Sendable {
    case resolving
    case downloading
    case extracting
    case verifying
  }

  public var phase: Phase
  public var message: String
  /// Download progress in `0...1`, when the transport can report it.
  public var fraction: Double?

  public init(phase: Phase, message: String, fraction: Double? = nil) {
    self.phase = phase
    self.message = message
    self.fraction = fraction
  }
}

/// What installing Node produced.
public struct NodeInstallOutcome: Sendable, Equatable {
  public var version: String
  public var binary: URL
  public var archive: String
  public var bytes: Int64
  /// Non-fatal remarks — an unverified digest, a non-LTS release — worth showing.
  public var notes: [String]

  public init(version: String, binary: URL, archive: String, bytes: Int64, notes: [String] = []) {
    self.version = version
    self.binary = binary
    self.archive = archive
    self.bytes = bytes
    self.notes = notes
  }
}

/// Downloads a file, reporting progress.
///
/// Separate from `HTTPFetching` because the two have genuinely different shapes: reading
/// a few kilobytes of JSON into memory is the right call for a version index, and the
/// wrong one for a 50 MB runtime tarball. It is a protocol so a test can hand the
/// provisioner a real fixture archive without a network.
public protocol FileDownloading: Sendable {
  func download(
    _ url: URL,
    to destination: URL,
    timeout: TimeInterval,
    onProgress: (@Sendable (Int64, Int64?) -> Void)?
  ) async throws
}

/// `URLSession`'s own download task, which streams to a file rather than to `Data`.
public struct URLSessionFileDownloader: FileDownloading {
  private let userAgent: String

  public init(userAgent: String = "NativeHarness") {
    self.userAgent = userAgent
  }

  public func download(
    _ url: URL,
    to destination: URL,
    timeout: TimeInterval,
    onProgress: (@Sendable (Int64, Int64?) -> Void)?
  ) async throws {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

    let (temporary, response) = try await URLSession.shared.download(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw RuntimeError.installFailed(step: "download", detail: "\(url.absoluteString) answered HTTP \(status)")
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // `download(for:)` hands back a temporary file that the next request may reuse, so it
    // has to be moved rather than referenced.
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: temporary, to: destination)
    onProgress?(
      (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0,
      nil
    )
  }
}

/// The Node that was resolved, or the reason there is not one.
public struct NodeAvailability: Sendable, Equatable {
  public var isInstalled: Bool
  public var version: String?
  public var binary: URL?

  public init(isInstalled: Bool, version: String? = nil, binary: URL? = nil) {
    self.isInstalled = isInstalled
    self.version = version
    self.binary = binary
  }
}

/// What the window needs in order to offer — and then run — a one-click Node install.
public protocol NodeProvisioning: Sendable {
  /// Whether a usable Node is already present, so the offer is not shown when it is not
  /// the problem.
  func isNodeMissing() async -> Bool
  /// Download, verify, unpack, and check a Node into `runtime/node`.
  func installNode(progress: @escaping @Sendable (NodeInstallProgress) -> Void) async throws -> NodeInstallOutcome
}

/// Fetches and installs the Node runtime the harness runs on — the implementation of the
/// "let the app fetch a copy" promise `ToolchainResolver` makes when it finds no Node.
///
/// **Why this exists at all.** Without it a machine with no Node is a dead end: the
/// harness cannot boot, and the only way out is the user installing Node by hand, outside
/// the app, before trying again. The resolver already *prefers* anything usable it finds
/// on the machine; this is only the last resort.
///
/// **What it writes.** Exactly `runtime/node`, the directory `ToolchainResolver` looks at
/// first. It never touches a system Node, `/usr/local`, Homebrew, or `~/.npm`, so
/// installing a copy here can never break the Node the rest of the machine uses.
///
/// **What it checks.** Stable Node only, a version and an OS/arch the project actually
/// published, the digest from Node's own `SHASUMS256.txt`, and finally the extracted
/// binary's `--version` — the same test the resolver applies, so "installed" and "usable"
/// cannot disagree.
public actor NodeProvisioner: NodeProvisioning {
  /// Node's distribution site. The index is what names the newest stable build rather
  /// than a version compiled into the app, which would go stale between releases.
  public static let indexURL = URL(string: "https://nodejs.org/dist/index.json")!

  public let paths: RuntimePaths
  private let fetcher: HTTPFetching
  private let downloader: FileDownloading
  private let runner: ProcessRunning
  private let inspector: ArchiveInspector
  private let resolver: ToolchainResolver
  private let baseEnvironment: [String: String]
  /// Injected so the whole pipeline can run against a fixture archive in tests.
  private let archiveURLProvider: @Sendable (String, PlatformAsset.Platform) -> URL

  public init(
    paths: RuntimePaths,
    fetcher: HTTPFetching = URLSessionFetcher(userAgent: "NativeHarness"),
    downloader: FileDownloading = URLSessionFileDownloader(userAgent: "NativeHarness"),
    runner: ProcessRunning = ProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    archiveURLProvider: @escaping @Sendable (String, PlatformAsset.Platform) -> URL = NodeProvisioner.distributionArchiveURL
  ) {
    self.paths = paths
    self.fetcher = fetcher
    self.downloader = downloader
    self.runner = runner
    self.inspector = ArchiveInspector(runner: runner)
    self.resolver = ToolchainResolver(paths: paths, runner: runner, baseEnvironment: baseEnvironment)
    self.baseEnvironment = baseEnvironment
    self.archiveURLProvider = archiveURLProvider
  }

  /// `https://nodejs.org/dist/v24.10.0/node-v24.10.0-darwin-arm64.tar.gz`
  @Sendable
  public static func distributionArchiveURL(version: String, platform: PlatformAsset.Platform) -> URL {
    let tag = version.hasPrefix("v") ? version : "v\(version)"
    let arch = platform.arch == "arm64" ? "arm64" : "x64"
    return URL(string: "https://nodejs.org/dist/\(tag)/node-\(tag)-darwin-\(arch).tar.gz")!
  }

  // MARK: - Is it needed?

  public func isNodeMissing() async -> Bool {
    // The resolver is the single source of truth for "is there a usable Node": asking it
    // rather than probing `runtime/node` is what keeps this offer from appearing when the
    // machine already has a perfectly good Node somewhere else.
    do {
      _ = try await resolver.resolve()
      return false
    } catch {
      return true
    }
  }

  // MARK: - Install

  public func installNode(
    progress: @escaping @Sendable (NodeInstallProgress) -> Void
  ) async throws -> NodeInstallOutcome {
    let platform = PlatformAsset.Platform.current
    guard platform.os == "macos" else {
      throw RuntimeError.unsupportedPlatform("the app only provisions Node for macOS, not \(platform.os)")
    }
    try paths.createDirectories()

    progress(NodeInstallProgress(phase: .resolving, message: "Asking nodejs.org for the newest stable Node…"))
    let release = try await latestRelease(for: platform)
    let tag = release.version.hasPrefix("v") ? release.version : "v\(release.version)"
    let url = archiveURLProvider(release.version, platform)
    let archiveName = url.lastPathComponent

    progress(NodeInstallProgress(phase: .downloading, message: "Downloading \(archiveName)…"))
    let download = paths.stagingRoot.appendingPathComponent("node-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: download) }
    let archive = download.appendingPathComponent(archiveName)

    try await downloader.download(url, to: archive, timeout: 900) { received, total in
      let message: String
      if let total, total > 0 {
        message = "Downloading \(archiveName) — \(Self.megabytes(received)) of \(Self.megabytes(total)) MB"
      } else {
        message = "Downloading \(archiveName) — \(Self.megabytes(received)) MB"
      }
      let fraction = (total ?? 0) > 0 ? Double(received) / Double(total!) : nil
      progress(NodeInstallProgress(phase: .downloading, message: message, fraction: fraction))
    }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? Int64 ?? 0

    progress(NodeInstallProgress(phase: .verifying, message: "Checking \(archiveName) against Node's published digest…"))
    try await verifyDigest(of: archive, named: archiveName, tag: tag, platform: platform)

    progress(NodeInstallProgress(phase: .extracting, message: "Unpacking Node \(tag)…"))
    let unpacked = download.appendingPathComponent("unpacked", isDirectory: true)
    try await inspector.extract(archive, to: unpacked)
    let payload = try payloadDirectory(in: unpacked, version: tag, platform: platform)

    // Staged beside the tree it will live in, so publishing it is a same-volume rename
    // rather than a copy of a 100 MB tree.
    let staged = paths.runtimeRoot.appendingPathComponent("node.staged-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.removeItem(at: staged)
    try FileManager.default.moveItem(at: payload, to: staged)

    progress(NodeInstallProgress(phase: .verifying, message: "Running the fetched Node to see whether it works…"))
    let stagedBinary = staged.appendingPathComponent("bin/node", isDirectory: false)
    guard let reported = await resolver.version(of: stagedBinary) else {
      try? FileManager.default.removeItem(at: staged)
      throw RuntimeError.installFailed(
        step: "verify node",
        detail: "the fetched binary at \(stagedBinary.path) would not report a version"
      )
    }
    let normalized = reported.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "v", with: "", options: .anchored)
    guard NodeRequirement.accepts(normalized) else {
      try? FileManager.default.removeItem(at: staged)
      throw RuntimeError.incompatibleNode(found: normalized, requirement: NodeRequirement.display)
    }

    try? FileManager.default.removeItem(at: paths.nodeDirectory)
    try FileManager.default.moveItem(at: staged, to: paths.nodeDirectory)

    // `dsh plugin` looks for a `pnpm` on the PATH this app builds; the shim has to point
    // at the Node that just arrived rather than at whatever was there before.
    let toolchain = Toolchain(node: paths.nodeBinary, nodeVersion: normalized, nodeOrigin: .appBundled)
    try? resolver.writePnpmShim(node: toolchain.node)

    var notes: [String] = []
    if !release.isLTS {
      notes.append("Node \(tag) is the newest stable release and is not yet an LTS line.")
    }
    return NodeInstallOutcome(
      version: normalized,
      binary: paths.nodeBinary,
      archive: archiveName,
      bytes: bytes,
      notes: notes
    )
  }

  // MARK: - Version discovery

  struct ReleaseCandidate: Sendable, Equatable {
    var version: String
    var isLTS: Bool
  }

  /// The newest published Node this app is allowed to use.
  ///
  /// The index is the authority on what exists: choosing from it means the app never
  /// offers a version the project has not published, and never needs its own hard-coded
  /// version list to go stale.
  func latestRelease(for platform: PlatformAsset.Platform) async throws -> ReleaseCandidate {
    let (data, status) = try await fetcher.fetch(Self.indexURL, timeout: 30)
    guard status == 200 else {
      throw RuntimeError.installFailed(step: "resolve node", detail: "nodejs.org/dist/index.json answered HTTP \(status)")
    }
    let entries = try Self.candidates(fromIndex: data, platform: platform)
    guard let newest = entries.first else {
      throw RuntimeError.installFailed(
        step: "resolve node",
        detail: "nodejs.org publishes no macOS tarball satisfying \(NodeRequirement.display)"
      )
    }
    return newest
  }

  /// Pick the newest usable entry out of the distribution index, newest first.
  ///
  /// Kept as a pure function of the JSON so the selection rule — newest, must satisfy the
  /// harness's engine range, must actually publish a macOS tarball — is testable without a
  /// network round trip.
  ///
  /// The index is ordered oldest-first, so the newest entry is the *last* one that
  /// qualifies and the order is normalized here rather than left as a trap for the caller.
  static func candidates(fromIndex data: Data, platform: PlatformAsset.Platform = .current) throws -> [ReleaseCandidate] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw RuntimeError.installFailed(step: "resolve node", detail: "the distribution index is not the expected JSON array")
    }
    let kind = platform.arch == "arm64" ? "osx-arm64-tar" : "osx-x64-tar"
    var found: [ReleaseCandidate] = []
    for entry in json {
      guard let raw = entry["version"] as? String else { continue }
      let version = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
      guard NodeRequirement.accepts(version) else { continue }
      let files = entry["files"] as? [String] ?? []
      guard files.contains(kind) else { continue }
      // `lts` is `false` or the LTS codename; anything else means a line that has landed.
      let lts = (entry["lts"] as? String).map { !$0.isEmpty } ?? false
      found.append(ReleaseCandidate(version: raw, isLTS: lts))
    }
    // Newest first, by version rather than by the index's own order: the list is sorted by
    // release date, and "the newest thing published" is not always "the newest version"
    // when a patch line is still being maintained.
    return found.sorted { lhs, rhs in
      let left = Semver(lhs.version.replacingOccurrences(of: "v", with: "", options: .anchored))
      let right = Semver(rhs.version.replacingOccurrences(of: "v", with: "", options: .anchored))
      guard let left, let right else { return lhs.version > rhs.version }
      return left > right
    }
  }

  // MARK: - Digest

  /// Verify the archive against the digest Node publishes beside it.
  ///
  /// A missing or unreadable manifest is a failure, not a warning: the digest is the only
  /// thing standing between a redirected download and executing whatever arrived.
  func verifyDigest(
    of archive: URL,
    named name: String,
    tag: String,
    platform: PlatformAsset.Platform
  ) async throws {
    let manifestURL = URL(string: "https://nodejs.org/dist/\(tag)/SHASUMS256.txt")!
    let (data, status) = try await fetcher.fetch(manifestURL, timeout: 60)
    guard status == 200, let text = String(data: data, encoding: .utf8) else {
      throw RuntimeError.integrityUnavailable("nodejs.org/dist/\(tag)/SHASUMS256.txt answered HTTP \(status)")
    }
    guard let expected = Self.digest(of: name, inManifest: text) else {
      throw RuntimeError.integrityUnavailable("Node's manifest for \(tag) does not list \(name)")
    }
    let actual = try ArchiveInspector.sha256(of: archive)
    guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
      throw RuntimeError.integrityMismatch(expected: expected, actual: actual)
    }
  }

  /// `SHASUMS256.txt` is `<digest>  <filename>` per line, sometimes with a leading `./`.
  static func digest(of name: String, inManifest text: String) -> String? {
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard parts.count >= 2 else { continue }
      let listed = parts[1].hasPrefix("./") ? String(parts[1].dropFirst(2)) : parts[1]
      if listed == name { return parts[0] }
    }
    return nil
  }

  // MARK: - Unpacked tree

  /// Find the Node distribution inside the extracted archive.
  ///
  /// Node's tarball has one top-level directory (`node-v24.10.0-darwin-arm64/`) and that is
  /// what gets published as `runtime/node`. The fallback scan exists because a mirror that
  /// re-packs the archive should not turn a good download into an unexplained failure.
  func payloadDirectory(in unpacked: URL, version: String, platform: PlatformAsset.Platform) throws -> URL {
    let arch = platform.arch == "arm64" ? "arm64" : "x64"
    let expected = unpacked.appendingPathComponent("node-\(version)-darwin-\(arch)", isDirectory: true)
    if Self.looksLikeNodeTree(expected) { return expected }

    let entries = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for entry in entries where Self.looksLikeNodeTree(entry) {
      return entry
    }
    throw RuntimeError.archiveMissingEntry("node-\(version)-darwin-\(arch)/bin/node")
  }

  static func looksLikeNodeTree(_ url: URL) -> Bool {
    FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("bin/node").path)
  }

  public static func megabytes(_ bytes: Int64) -> String {
    String(format: "%.1f", Double(bytes) / 1_048_576)
  }

  /// Reported for the log line that says which Node was installed and where it came from.
  public func describeInstalledNode() async -> NodeAvailability {
    do {
      let toolchain = try await resolver.resolve()
      return NodeAvailability(isInstalled: true, version: toolchain.nodeVersion, binary: toolchain.node)
    } catch {
      return NodeAvailability(isInstalled: false)
    }
  }
}
