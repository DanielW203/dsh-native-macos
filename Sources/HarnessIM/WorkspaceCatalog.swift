import Foundation

/// One workspace the harness has on file.
///
/// The channel never invents workspaces: this is a *reading* of the harness's own registry,
/// the same rows the desktop sidebar shows, so `/workspace` and the sidebar cannot disagree
/// about which folders exist.
public struct HarnessWorkspace: Sendable, Equatable {
  /// The harness's workspace id, or empty for a folder the user named that is not registered yet.
  public var id: String
  public var path: String
  public var title: String
  public var updatedAt: Date?
  public var sessionCount: Int
  /// Whether the folder is still on disk.
  ///
  /// Decoding cannot know this, so the pure decoder leaves it `true` and
  /// `WorkspaceCatalog.load(home:)` — the filesystem-aware entry point — is what turns it into
  /// `false` for a folder that was moved or deleted.
  public var isReachable: Bool

  public init(
    id: String,
    path: String,
    title: String,
    updatedAt: Date? = nil,
    sessionCount: Int = 0,
    isReachable: Bool = true
  ) {
    self.id = id
    self.path = path
    self.title = title
    self.updatedAt = updatedAt
    self.sessionCount = sessionCount
    self.isReachable = isReachable
  }

  /// A name that is never empty on a phone screen.
  public var displayTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
  }

  /// A phone-sized id, or `nil` when this folder has never been registered.
  public var shortID: String? {
    guard !id.isEmpty else { return nil }
    return String(id.prefix(8))
  }
}

/// Reads the harness's workspace registry.
///
/// The layout is `storages/workspace.json` under the harness home: a `tables.workspaces`
/// dictionary keyed by workspace id, plus a `global.workspaceIds` list that fixes the order the
/// desktop shows. Every parse step is tolerant on purpose — this file belongs to the harness,
/// and a version bump there must degrade to "no workspaces to offer", never to a crash in the
/// WeChat loop.
public enum WorkspaceCatalog {
  /// Path of the registry, relative to the harness home.
  public static func storageURL(home: URL) -> URL {
    home
      .appendingPathComponent("storages", isDirectory: true)
      .appendingPathComponent("workspace.json", isDirectory: false)
  }

  /// Load the registry, newest activity first, with reachability filled in.
  public static func load(home: URL, fileManager: FileManager = .default) -> [HarnessWorkspace] {
    guard let data = try? Data(contentsOf: storageURL(home: home)) else { return [] }
    return decode(data).map { workspace in
      var copy = workspace
      var isDirectory: ObjCBool = false
      let exists = fileManager.fileExists(atPath: workspace.path, isDirectory: &isDirectory)
      copy.isReachable = exists && isDirectory.boolValue
      return copy
    }
  }

  /// Decode the registry without touching the filesystem.
  public static func decode(_ data: Data) -> [HarnessWorkspace] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return []
    }
    let tables = root["tables"] as? [String: Any]
    let rawWorkspaces = tables?["workspaces"] as? [String: Any] ?? [:]
    let declaredOrder = (root["global"] as? [String: Any])?["workspaceIds"] as? [String] ?? []

    // Declared order first (that is the sidebar's order), then anything the list missed.
    var ordered: [HarnessWorkspace] = []
    var seen = Set<String>()
    for id in declaredOrder {
      guard let entry = rawWorkspaces[id] as? [String: Any] else { continue }
      guard let workspace = decodeEntry(id: id, entry: entry) else { continue }
      ordered.append(workspace)
      seen.insert(id)
    }
    for (id, value) in rawWorkspaces where !seen.contains(id) {
      guard let entry = value as? [String: Any] else { continue }
      guard let workspace = decodeEntry(id: id, entry: entry) else { continue }
      ordered.append(workspace)
    }

    // Most recently touched first: the folder the user wants is nearly always the last one used.
    return ordered.sorted { lhs, rhs in
      switch (lhs.updatedAt, rhs.updatedAt) {
      case let (left?, right?): return left > right
      case (nil, _?): return false
      case (_?, nil): return true
      case (nil, nil): return lhs.displayTitle < rhs.displayTitle
      }
    }
  }

  private static func decodeEntry(id: String, entry: [String: Any]) -> HarnessWorkspace? {
    guard let path = entry["path"] as? String, !path.isEmpty else { return nil }
    return HarnessWorkspace(
      id: id,
      path: path,
      title: entry["title"] as? String ?? "",
      updatedAt: (entry["updatedAt"] as? String).flatMap(date(from:)),
      sessionCount: (entry["sessionIds"] as? [Any])?.count ?? 0
    )
  }

  private static func date(from raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    return ISO8601DateFormatter().date(from: raw)
  }

  /// Resolve one `/workspace` argument against a listing.
  ///
  /// Accepts, in order: a 1-based row number (what the user was shown), a workspace id or id
  /// prefix, an exact path or a trailing path fragment, a title, and finally a path-shaped
  /// argument that names a folder the registry does not know yet — which the service registers
  /// on demand. Ordering matters: a bare number must never be read as a path.
  public static func resolve(
    target: String,
    in workspaces: [HarnessWorkspace],
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> HarnessWorkspace? {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let index = Int(trimmed) {
      guard index >= 1, index <= workspaces.count else { return nil }
      return workspaces[index - 1]
    }

    if let exact = workspaces.first(where: { $0.id == trimmed }) { return exact }
    if let prefixed = workspaces.first(where: { !$0.id.isEmpty && $0.id.hasPrefix(trimmed) }) {
      return prefixed
    }

    let expanded = expand(trimmed, home: home)
    if let exact = workspaces.first(where: { $0.path == expanded }) { return exact }
    if let suffixed = workspaces.first(where: { $0.path.hasSuffix("/" + trimmed) }) {
      return suffixed
    }
    if let titled = workspaces.first(where: { $0.displayTitle == trimmed }) { return titled }
    if let contained = workspaces.first(where: {
      !trimmed.isEmpty && $0.displayTitle.localizedCaseInsensitiveContains(trimmed)
    }) {
      return contained
    }

    guard isPathShaped(trimmed) else { return nil }
    return HarnessWorkspace(
      id: "",
      path: expanded,
      title: (expanded as NSString).lastPathComponent
    )
  }

  /// Whether an argument reads as "a folder", as opposed to a name or an id.
  static func isPathShaped(_ raw: String) -> Bool {
    raw.hasPrefix("/") || raw.hasPrefix("~") || raw.hasPrefix("./") || raw.hasPrefix("../")
  }

  /// Expand `~` and normalize, without resolving symlinks (the service canonicalizes later).
  static func expand(_ raw: String, home: URL) -> String {
    var path = raw
    if path == "~" {
      path = home.path
    } else if path.hasPrefix("~/") {
      path = home.path + String(path.dropFirst(1))
    } else if path.hasPrefix("./") || path.hasPrefix("../") {
      path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(path)
        .standardized.path
    }
    return (path as NSString).standardizingPath
  }
}
