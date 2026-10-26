import Foundation

/// One skill as the filesystem provider would compose it, with the extra state this window
/// needs to explain what the user is looking at.
public struct SkillRecord: Sendable, Equatable, Identifiable {
  /// How the skill is stored: a directory bundle (`<name>/SKILL.md`) or a flat `<name>.md`.
  public enum Form: String, Sendable, Equatable {
    case bundle
    case flat
  }

  /// The frontmatter `name` when the official provider would accept the file, otherwise the
  /// on-disk name — a broken skill still has to be listed, or it cannot be fixed or removed.
  public var name: String
  /// The frontmatter `description`, or the reason the file would not load.
  public var summary: String
  public var whenToUse: String?
  public var form: Form
  /// The file the skill loads from: `SKILL.md` for a bundle, the `.md` itself for a flat skill.
  public var entryURL: URL
  /// The directory relative paths in the skill resolve against.
  public var resourceURL: URL
  public var rootKind: SkillRootKind
  public var rootURL: URL
  /// The entry is a symbolic link. Writable, but not deletable: moving it moves the target.
  public var isLinked: Bool
  public var modelInvocable: Bool
  public var userInvocable: Bool
  /// Set when the official provider would ignore this entry entirely.
  public var issue: SkillFrontmatterIssue?
  /// Set when a higher-priority root already provides this name, so this entry cannot be
  /// the one a session loads.
  public var shadowedBy: SkillRootKind?

  public var id: String { entryURL.path }
  public var isLoadable: Bool { issue == nil && shadowedBy == nil }
  /// Whether the invocation switches may be written for this entry.
  public var isEditable: Bool { issue == nil }
  public var isDeletable: Bool { !isLinked }

  public init(
    name: String,
    summary: String,
    whenToUse: String? = nil,
    form: Form,
    entryURL: URL,
    resourceURL: URL,
    rootKind: SkillRootKind,
    rootURL: URL,
    isLinked: Bool = false,
    modelInvocable: Bool = true,
    userInvocable: Bool = true,
    issue: SkillFrontmatterIssue? = nil,
    shadowedBy: SkillRootKind? = nil
  ) {
    self.name = name
    self.summary = summary
    self.whenToUse = whenToUse
    self.form = form
    self.entryURL = entryURL
    self.resourceURL = resourceURL
    self.rootKind = rootKind
    self.rootURL = rootURL
    self.isLinked = isLinked
    self.modelInvocable = modelInvocable
    self.userInvocable = userInvocable
    self.issue = issue
    self.shadowedBy = shadowedBy
  }
}

/// One root's skills, ready to render as a section.
public struct SkillGroup: Sendable, Equatable, Identifiable {
  public var root: SkillRoot
  public var skills: [SkillRecord]

  public var id: String { root.url.path }

  public init(root: SkillRoot, skills: [SkillRecord]) {
    self.root = root
    self.skills = skills
  }
}

/// Everything one scan produced.
public struct SkillCatalog: Sendable, Equatable {
  public var workspace: URL
  public var projectRoot: URL
  /// Every root the provider composes, in rank order, whether or not it exists on disk.
  public var roots: [SkillRoot]
  /// Winners and shadowed losers alike, sorted by name then rank.
  public var skills: [SkillRecord]
  public var scannedAt: Date
  /// Non-fatal problems from the scan (an unreadable root, a file that vanished mid-scan).
  public var warnings: [String]

  public init(
    workspace: URL,
    projectRoot: URL,
    roots: [SkillRoot],
    skills: [SkillRecord],
    scannedAt: Date,
    warnings: [String]
  ) {
    self.workspace = workspace
    self.projectRoot = projectRoot
    self.roots = roots
    self.skills = skills
    self.scannedAt = scannedAt
    self.warnings = warnings
  }

  /// One section per root that exists on disk, so an untouched project does not grow two
  /// empty headings.
  public var groups: [SkillGroup] {
    let fileManager = FileManager.default
    return roots.filter { fileManager.fileExists(atPath: $0.url.path) }.map { root in
      SkillGroup(root: root, skills: skills.filter { $0.rootURL.path == root.url.path })
    }
  }

  public var rootMissingCount: Int {
    roots.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.count
  }
}

/// A skill sitting in a root's `.trash`, with what is needed to put it back.
public struct TrashedSkill: Sendable, Equatable, Identifiable {
  public var name: String
  /// The item inside `.trash` (a directory for a bundle, a `.md` for a flat skill).
  public var trashedURL: URL
  /// Where a restore moves it back to.
  public var originalURL: URL
  public var form: SkillRecord.Form
  public var rootKind: SkillRootKind
  public var rootURL: URL
  public var deletedAt: Date?
  public var bytes: Int64
  /// True when no sidecar manifest was found (an item another tool trashed); the name and
  /// shape were then inferred from the file itself.
  public var isInferred: Bool

  public var id: String { trashedURL.path }
  /// The parent `.trash` directory, used to gate restore against a re-occupied slot.
  public var trashURL: URL { trashedURL.deletingLastPathComponent() }

  public init(
    name: String,
    trashedURL: URL,
    originalURL: URL,
    form: SkillRecord.Form,
    rootKind: SkillRootKind,
    rootURL: URL,
    deletedAt: Date? = nil,
    bytes: Int64 = 0,
    isInferred: Bool = false
  ) {
    self.name = name
    self.trashedURL = trashedURL
    self.originalURL = originalURL
    self.form = form
    self.rootKind = rootKind
    self.rootURL = rootURL
    self.deletedAt = deletedAt
    self.bytes = bytes
    self.isInferred = isInferred
  }
}

/// A create-form submission.
public struct SkillDraft: Sendable, Equatable {
  public var name: String
  public var summary: String
  public var whenToUse: String
  public var content: String
  public var root: SkillWriteRoot

  public init(
    name: String = "",
    summary: String = "",
    whenToUse: String = "",
    content: String = "",
    root: SkillWriteRoot = .user
  ) {
    self.name = name
    self.summary = summary
    self.whenToUse = whenToUse
    self.content = content
    self.root = root
  }
}

/// The sidecar written next to a trashed skill.
///
/// A sidecar rather than a manifest inside the moved directory: a manifest inside would be
/// moved back on restore and left inside the user's skill directory.
struct SkillTrashManifest: Codable, Sendable, Equatable {
  var schemaVersion: Int
  var name: String
  /// Path relative to the skill root of the item as it was found (directory name, or file name).
  var relativePath: String
  var form: String
  var deletedAt: Date

  static let currentSchemaVersion = 1
  static let fileSuffix = ".trash.json"
}

/// The search the window's filter box runs.
public enum SkillSearch {
  /// Filter by name, description or `whenToUse`, case- and width-insensitively.
  ///
  /// Name matches come first: when a user types a fragment they are almost always naming a
  /// skill, not quoting its prose.
  public static func match(_ skills: [SkillRecord], query: String) -> [SkillRecord] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return skills }
    let hits = skills.filter { skill in
      skill.name.lowercased().contains(needle)
        || skill.summary.lowercased().contains(needle)
        || (skill.whenToUse?.lowercased().contains(needle) ?? false)
    }
    return hits.sorted { left, right in
      let leftName = left.name.lowercased().contains(needle)
      let rightName = right.name.lowercased().contains(needle)
      if leftName != rightName { return leftName }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
  }
}
