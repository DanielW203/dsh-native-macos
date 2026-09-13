import Foundation

/// How a release was obtained.
public enum InstallSourceKind: String, Codable, Sendable, CaseIterable {
  /// A self-contained prebuilt package (no Node install or build step needed).
  case prebuiltArchive
  /// A source archive that must be installed and built with pnpm.
  case sourceArchive
  /// A source checkout that must be installed and built with pnpm.
  case sourceDirectory
  /// Installed from the npm registry.
  case registry
  /// Downloaded from a GitHub Release asset.
  case githubRelease

  public var displayName: String {
    switch self {
    case .prebuiltArchive: return "Prebuilt package"
    case .sourceArchive: return "Source archive"
    case .sourceDirectory: return "Source checkout"
    case .registry: return "npm registry"
    case .githubRelease: return "GitHub release"
    }
  }
}

/// What the user asked to install.
public enum InstallSource: Sendable, Equatable {
  case prebuiltArchive(url: URL, expectedDigest: String?)
  case sourceArchive(url: URL, expectedDigest: String?)
  case sourceDirectory(url: URL)
  case registry(version: String)
  case githubRelease(tag: String?, assetName: String?, expectedDigest: String?)

  public var kind: InstallSourceKind {
    switch self {
    case .prebuiltArchive: return .prebuiltArchive
    case .sourceArchive: return .sourceArchive
    case .sourceDirectory: return .sourceDirectory
    case .registry: return .registry
    case .githubRelease: return .githubRelease
    }
  }

  /// Human-facing origin, persisted so the UI can explain where a release came from
  /// long after the download is gone.
  public var spec: String {
    switch self {
    case .prebuiltArchive(let url, _), .sourceArchive(let url, _), .sourceDirectory(let url):
      return url.path
    case .registry(let version):
      return "@deepseek-ai/dsh\(version)"
    case .githubRelease(let tag, let assetName, _):
      return [tag, assetName].compactMap { $0 }.joined(separator: "/")
    }
  }

  public var tag: String? {
    if case .githubRelease(let tag, _, _) = self { return tag }
    return nil
  }

  /// A digest the caller already trusts. Absent means the archive is local and
  /// unverified, which is recorded rather than hidden.
  public var expectedDigest: String? {
    switch self {
    case .prebuiltArchive(_, let digest), .sourceArchive(_, let digest): return digest
    case .githubRelease(_, _, let digest): return digest
    case .sourceDirectory, .registry: return nil
    }
  }
}

/// Where a digest came from. Persisted because "verified" is only meaningful next to
/// the reason it can be trusted — the prebuilt channel is a third-party repackaging
/// service, not an official publisher, and the UI says so.
public enum IntegrityOrigin: String, Codable, Sendable {
  /// A `.sha256` file shipped beside the archive.
  case sidecar
  /// The digest GitHub renders on the release asset page.
  case releaseAsset
  /// The registry's own `integrity` field.
  case npmRegistry
  /// Extracted locally with nothing to compare against.
  case unverifiedLocal
}

/// The integrity record for one installed release.
public struct Integrity: Codable, Sendable, Equatable {
  public var algorithm: String
  public var digest: String
  public var verified: Bool
  public var origin: IntegrityOrigin

  public init(algorithm: String = "sha256", digest: String, verified: Bool, origin: IntegrityOrigin) {
    self.algorithm = algorithm
    self.digest = digest
    self.verified = verified
    self.origin = origin
  }

  public var displayDigest: String { String(digest.prefix(12)) }
}

/// The persisted provenance of one installed release.
public struct SourceRecord: Codable, Sendable, Equatable {
  public var kind: InstallSourceKind
  public var spec: String
  public var tag: String?
  public var commit: String?

  public init(kind: InstallSourceKind, spec: String, tag: String? = nil, commit: String? = nil) {
    self.kind = kind
    self.spec = spec
    self.tag = tag
    self.commit = commit
  }
}

/// One installed harness runtime.
///
/// `entry` is stored relative to the release directory because the two source kinds
/// disagree: a prebuilt package puts the CLI at
/// `node_modules/@deepseek-ai/dsh/lib/bin.js`, while a source build puts it at
/// `apps/cli/lib/bin.js`. Storing the absolute path would make a release directory
/// un-relocatable, and the staging rename that commits an install would invalidate it.
public struct HarnessRelease: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var version: String
  public var entry: String
  public var source: SourceRecord
  public var integrity: Integrity
  public var installedAt: Date
  /// Bytes on disk after extraction, when known.
  public var byteCount: Int64?

  public init(
    id: String,
    version: String,
    entry: String,
    source: SourceRecord,
    integrity: Integrity,
    installedAt: Date,
    byteCount: Int64? = nil
  ) {
    self.id = id
    self.version = version
    self.entry = entry
    self.source = source
    self.integrity = integrity
    self.installedAt = installedAt
    self.byteCount = byteCount
  }

  /// The CLI entry point inside `directory`.
  public func entryURL(in directory: URL) -> URL {
    directory.appendingPathComponent(entry)
  }

  /// Whether this release's entry point is actually present.
  public func isMaterialized(in directory: URL) -> Bool {
    FileManager.default.isReadableFile(atPath: entryURL(in: directory).path)
  }

  /// Stable identity for a release: version, source kind, and a short discriminator.
  ///
  /// Re-importing the same artifact resolves to the same directory instead of
  /// accumulating copies. The token is the first six digest characters for anything
  /// that arrives as a file, and a fixed word otherwise — a registry install and a
  /// local checkout have no artifact to hash, and keying them on the version is what
  /// makes "install 0.1.5 twice" idempotent rather than duplicative.
  public static func makeID(version: String, kind: InstallSourceKind, token: String) -> String {
    let short = String(token.prefix(6))
    return "\(version)-\(kind.rawValue)-\(short)"
  }

  /// Idempotency token for a source kind: the digest prefix when there is an artifact,
  /// otherwise a constant that ties identity to the version alone.
  public static func idToken(kind: InstallSourceKind, digest: String?) -> String {
    if let digest, !digest.isEmpty { return digest }
    switch kind {
    case .registry: return "npm"
    case .sourceDirectory: return "local"
    case .prebuiltArchive, .sourceArchive, .githubRelease: return "archive"
    }
  }
}

/// The installed-release ledger at `<root>/harness/installs.json`.
public struct InstallsIndex: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  /// The release id currently linked as `current`, or `nil` when nothing is active.
  public var active: String?
  public var releases: [HarnessRelease]

  public init(schemaVersion: Int = InstallsIndex.currentSchemaVersion, active: String? = nil, releases: [HarnessRelease] = []) {
    self.schemaVersion = schemaVersion
    self.active = active
    self.releases = releases
  }

  public func release(id: String) -> HarnessRelease? {
    releases.first { $0.id == id }
  }

  public var activeRelease: HarnessRelease? {
    guard let active else { return nil }
    return release(id: active)
  }

  // MARK: - Persistence

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// Read the ledger. A missing file is an empty index; a corrupt one is an error,
  /// because silently starting from empty would orphan every installed release.
  public static func load(from url: URL) throws -> InstallsIndex {
    guard FileManager.default.fileExists(atPath: url.path) else { return InstallsIndex() }
    let data = try Data(contentsOf: url)
    let decoded = try Self.makeDecoder().decode(InstallsIndex.self, from: data)
    guard decoded.schemaVersion <= Self.currentSchemaVersion else {
      throw RuntimeError.unsupported("installs.json schemaVersion \(decoded.schemaVersion) is newer than \(Self.currentSchemaVersion)")
    }
    return decoded
  }

  /// Write the ledger atomically: a crash mid-write must not leave a truncated
  /// index, since that is what makes installed releases unreachable.
  public func save(to url: URL) throws {
    let data = try Self.makeEncoder().encode(self)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: .atomic)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }
}
