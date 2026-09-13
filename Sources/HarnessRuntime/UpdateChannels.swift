import Foundation
import HarnessKit

/// A version the user may install.
public struct HarnessUpdateCandidate: Sendable, Equatable, Identifiable {
  public var channelID: String
  public var version: String
  public var tag: String?
  /// Where it comes from, shown verbatim so the user can see the actual URL or spec.
  public var origin: String
  /// A digest to enforce, when the channel supplies a trustworthy one.
  public var digest: String?
  public var publishedAt: Date?
  /// Ready to hand to the installer — channels never install anything themselves.
  public var source: InstallSource
  /// A caveat to show beside the candidate.
  public var note: String?

  public var id: String { "\(channelID):\(version)" }

  public init(
    channelID: String,
    version: String,
    tag: String? = nil,
    origin: String,
    digest: String? = nil,
    publishedAt: Date? = nil,
    source: InstallSource,
    note: String? = nil
  ) {
    self.channelID = channelID
    self.version = version
    self.tag = tag
    self.origin = origin
    self.digest = digest
    self.publishedAt = publishedAt
    self.source = source
    self.note = note
  }
}

/// What a channel check produced.
///
/// A channel never throws across this boundary. "GitHub is unreachable from this
/// machine" is an ordinary outcome that the UI must render as a fact, not an error —
/// measured on this machine, `github.com` refuses connections while the npm registry
/// answers, so a single failing channel must not take the update pane down with it.
public enum ChannelResult: Sendable, Equatable {
  case candidates([HarnessUpdateCandidate])
  case upToDate(current: String?)
  case unreachable(String)
  case failed(String)

  public var candidates: [HarnessUpdateCandidate] {
    if case .candidates(let list) = self { return list }
    return []
  }
}

/// The small slice of HTTP the channels need.
///
/// Injected so channel parsing is tested against recorded payloads rather than against
/// the network, which is both faster and the only way to test the rate-limited and
/// unreachable branches.
public protocol HTTPFetching: Sendable {
  func fetch(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int)
}

public struct URLSessionFetcher: HTTPFetching {
  private let userAgent: String

  public init(userAgent: String = "NativeHarness") {
    self.userAgent = userAgent
  }

  public func fetch(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (data, status)
  }
}

/// A source of newer harness versions.
public protocol HarnessUpdateChannel: Sendable {
  var id: String { get }
  var displayName: String { get }
  /// An honest statement about who publishes this channel, shown next to it.
  var publisherNote: String { get }
  func check(current: String?, fetcher: HTTPFetching) async -> ChannelResult
}

// MARK: - Registry

/// The official publication channel.
///
/// `registry.npmjs.org` is where the harness project actually publishes; a version that
/// exists there is the version its maintainers released.
public struct RegistryChannel: HarnessUpdateChannel {
  public static let packageName = "@deepseek-ai/dsh"
  public static let registryURL = URL(string: "https://registry.npmjs.org/@deepseek-ai/dsh")!

  /// Include rc/beta/alpha versions. Off by default because the registry's own
  /// `dist-tags.latest` is the release the project wants people to run.
  public var includePrereleases: Bool

  public init(includePrereleases: Bool = false) {
    self.includePrereleases = includePrereleases
  }

  public var id: String { "registry" }
  public var displayName: String { "npm registry" }
  public var publisherNote: String { "Published by the harness project itself." }

  public func check(current: String?, fetcher: HTTPFetching) async -> ChannelResult {
    let payload: Data
    do {
      let response = try await fetcher.fetch(Self.registryURL, timeout: 15)
      guard response.statusCode == 200 else {
        return .failed("registry returned HTTP \(response.statusCode)")
      }
      payload = response.data
    } catch {
      return .unreachable(String(describing: error))
    }

    do {
      let json = try JSONValue.parse(payload, context: "npm registry document")
      guard let versions = json["versions"]?.objectValue else {
        return .failed("registry document has no versions")
      }
      let latest = json.string(at: "dist-tags.latest")
      let currentSemver = current.flatMap { Semver($0) }
      // The registry keeps publish times in a sibling `time` map keyed by version.
      let publishedTimes = json["time"]?.objectValue ?? [:]
      let formatter = ISO8601DateFormatter()

      var candidates: [HarnessUpdateCandidate] = []
      for (version, _) in versions {
        guard let parsed = Semver(version) else { continue }
        if parsed.isPrerelease && !includePrereleases { continue }
        if let currentSemver, parsed <= currentSemver { continue }
        candidates.append(
          HarnessUpdateCandidate(
            channelID: id,
            version: version,
            origin: "\(Self.packageName)@\(version)",
            publishedAt: publishedTimes[version]?.stringValue.flatMap { formatter.date(from: $0) },
            source: .registry(version: version),
            note: version == latest ? "Tagged latest" : nil
          )
        )
      }
      guard !candidates.isEmpty else { return .upToDate(current: current) }
      candidates.sort { (Semver($0.version) ?? Semver(major: 0, minor: 0, patch: 0))
        > (Semver($1.version) ?? Semver(major: 0, minor: 0, patch: 0)) }
      return .candidates(candidates)
    } catch {
      return .failed("cannot parse the registry document: \(error)")
    }
  }
}

// MARK: - GitHub release

/// The prebuilt-package channel.
///
/// This is **not** an official DeepSeek publication: `dsh-tauri-desk/deepseek-harness-pkg`
/// is a third party repackaging each harness version into a self-contained archive.
/// `publisherNote` says so, and the UI shows it, because a user installing a prebuilt
/// runtime deserves to know who assembled it.
public struct GitHubChannel: HarnessUpdateChannel {
  public static let repository = "dsh-tauri-desk/deepseek-harness-pkg"
  public static let releasesAtom = URL(string: "https://github.com/dsh-tauri-desk/deepseek-harness-pkg/releases.atom")!

  public var platform: PlatformAsset.Platform

  public init(platform: PlatformAsset.Platform = .current) {
    self.platform = platform
  }

  public var id: String { "github-release" }
  public var displayName: String { "GitHub release (prebuilt)" }
  public var publisherNote: String {
    "Prebuilt archives repackaged by \(Self.repository), a third party — not an official DeepSeek publication."
  }

  public func check(current: String?, fetcher: HTTPFetching) async -> ChannelResult {
    let feed: Data
    do {
      // releases.atom is served from github.com, not api.github.com, so an unauthenticated
      // rate limit on the API does not affect the version check.
      let response = try await fetcher.fetch(Self.releasesAtom, timeout: 15)
      guard response.statusCode == 200 else {
        return .unreachable("releases.atom returned HTTP \(response.statusCode)")
      }
      feed = response.data
    } catch {
      return .unreachable(String(describing: error))
    }

    let releases = Self.parseAtom(String(decoding: feed, as: UTF8.self))
    guard !releases.isEmpty else { return .failed("releases.atom contained no releases") }

    let currentSemver = current.flatMap { Semver($0) }
    for entry in releases {
      // Preview tags are skipped: an rc is not what "there is an update" should mean.
      if Self.isPreviewTag(entry.tag) { continue }
      let version = entry.tag.hasPrefix("v") ? String(entry.tag.dropFirst()) : entry.tag
      guard let parsed = Semver(version) else { continue }
      guard currentSemver == nil || parsed > currentSemver! else { continue }
      guard let asset = PlatformAsset.assetName(for: platform) else {
        return .failed("no prebuilt archive is published for \(platform.os)/\(platform.arch)")
      }
      let url = URL(string: "https://github.com/\(Self.repository)/releases/download/\(entry.tag)/\(asset)")!
      return .candidates([
        HarnessUpdateCandidate(
          channelID: id,
          version: version,
          tag: entry.tag,
          origin: url.absoluteString,
          digest: nil,
          publishedAt: entry.updated,
          // The asset has to be downloaded before it can be installed, so the candidate
          // carries the URL and the caller fetches it; the installer only sees a file.
          source: .githubRelease(tag: entry.tag, assetName: asset, expectedDigest: nil),
          note: "Download required"
        )
      ])
    }
    return .upToDate(current: current)
  }

  // MARK: - Parsing

  struct AtomEntry: Sendable, Equatable {
    var tag: String
    var updated: Date?
  }

  /// Pull `(tag, updated)` pairs out of a releases atom feed.
  ///
  /// A hand-written scan rather than an XML parser: the feed is machine-generated by
  /// GitHub with a fixed shape, and the only fields needed are two text nodes. It is a
  /// pure function so it is tested against a recorded feed instead of the network.
  static func parseAtom(_ body: String) -> [AtomEntry] {
    var entries: [AtomEntry] = []
    var rest = Substring(body)
    while let start = rest.range(of: "<entry>") {
      guard let end = rest.range(of: "</entry>", range: start.upperBound..<rest.endIndex) else { break }
      let block = rest[start.upperBound..<end.lowerBound]
      if let tagRange = block.range(of: "releases/tag/") {
        let after = block[tagRange.upperBound...]
        if let quote = after.firstIndex(of: "\"") {
          let tag = String(after[after.startIndex..<quote])
          var updated: Date?
          if let open = block.range(of: "<updated>"),
             let close = block.range(of: "</updated>", range: open.upperBound..<block.endIndex) {
            let text = String(block[open.upperBound..<close.lowerBound])
            updated = ISO8601DateFormatter().date(from: text)
          }
          if !tag.isEmpty { entries.append(AtomEntry(tag: tag, updated: updated)) }
        }
      }
      rest = rest[end.upperBound...]
    }
    return entries
  }

  /// Whether a tag names a preview build.
  ///
  /// The feed carries no marker for pre-releases, so the tag itself is the only signal —
  /// the same conclusion the official desktop app reached.
  static func isPreviewTag(_ tag: String) -> Bool {
    let lowered = tag.lowercased()
    return lowered.contains("-rc") || lowered.contains("-beta") || lowered.contains("-alpha")
      || lowered.hasPrefix("test-")
  }
}
