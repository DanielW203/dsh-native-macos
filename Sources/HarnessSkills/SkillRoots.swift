import Foundation

/// Where a skill root sits in the official provider's precedence order.
///
/// The raw values and rank numbers are `@deepseek-ai/dsh-skill-filesystem`'s own
/// (`PROJECT_DSH_RANK` … `USER_AGENTS_RANK`); a lower rank wins a duplicate name, so these
/// numbers are behaviour, not labels.
public enum SkillRootKind: String, Sendable, CaseIterable, Equatable {
  case projectDsh = "project-dsh"
  case projectAgents = "project-agents"
  case custom
  case userDsh = "user-dsh"
  case userAgents = "user-agents"

  public var rank: Int {
    switch self {
    case .projectDsh: return 100
    case .projectAgents: return 200
    case .custom: return 300
    case .userDsh: return 400
    case .userAgents: return 500
    }
  }

  /// Group heading in the window.
  public var title: String {
    switch self {
    case .projectDsh: return "项目 · .dsh/skills"
    case .projectAgents: return "项目 · .agents/skills"
    case .custom: return "自定义目录"
    case .userDsh: return "用户 · DSH_HOME/skills"
    case .userAgents: return "用户 · ~/.agents/skills"
    }
  }

  /// The line under the heading: which scope the root belongs to and what beats it.
  public var hint: String {
    switch self {
    case .projectDsh: return "优先级最高：同名技能会压过其它所有根"
    case .projectAgents: return "同一项目内的 .agents 约定，仅次于 .dsh/skills"
    case .custom: return "harness 配置里 customSkillDirs 指定的目录"
    case .userDsh: return "个人的技能库，对所有工作区生效"
    case .userAgents: return "跨工具的 ~/.agents 约定，优先级最低"
    }
  }

  public var isProjectScoped: Bool {
    self == .projectDsh || self == .projectAgents
  }
}

/// One resolved skill root: the directory the official provider scans, plus its rank.
public struct SkillRoot: Sendable, Equatable, Identifiable {
  public var kind: SkillRootKind
  public var url: URL
  /// `.system` is hidden in the user root only — the provider's `skipSystem` flag.
  public var skipsSystem: Bool
  /// Whether this root belongs to the harness home (editable) or a project checkout.
  public var isUserScoped: Bool

  public var id: String { url.path }
  public var rank: Int { kind.rank }

  public init(kind: SkillRootKind, url: URL, skipsSystem: Bool, isUserScoped: Bool) {
    self.kind = kind
    self.url = url
    self.skipsSystem = skipsSystem
    self.isUserScoped = isUserScoped
  }
}

/// The two roots the create form and the importer may write into.
///
/// Deliberately not the full root list: `.agents` roots are a cross-tool convention the user
/// did not ask this window to create files in, and a custom root has no single obvious place
/// for a new skill.
public enum SkillWriteRoot: String, Sendable, CaseIterable, Equatable, Identifiable {
  case user
  case project

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .user: return "用户根（DSH_HOME/skills）"
    case .project: return "项目根（.dsh/skills）"
    }
  }

  public var hint: String {
    switch self {
    case .user: return "对所有工作区生效"
    case .project: return "只对当前项目生效，并压过同名的用户技能"
    }
  }
}

/// Root resolution, mirroring the official provider's `roots(cwd)`.
public enum SkillRoots {
  /// The nearest ancestor of `workspace` that contains a `.git` entry.
  ///
  /// Falls back to `workspace` itself, exactly as `findProjectRoot` does: a folder that is not
  /// in a repository still has a project root, it is just the folder itself.
  public static func projectRoot(forWorkspace workspace: URL) -> URL {
    let fileManager = FileManager.default
    let start = workspace.standardizedFileURL
    var current = start
    while true {
      if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
      let parent = current.deletingLastPathComponent()
      // The root has to be named explicitly: `URL.deletingLastPathComponent()` on `/` returns
      // `/..` rather than `/` (measured), so "the parent is me" never becomes true and a
      // workspace outside any repository would walk forever.
      if parent.path == current.path || current.path == "/" { return start }
      current = parent
    }
  }

  /// Every root the official provider would compose for this workspace, in rank order.
  public static func resolve(
    workspace: URL,
    dshHome: URL,
    agentsHome: URL,
    custom: [URL] = []
  ) -> [SkillRoot] {
    let project = projectRoot(forWorkspace: workspace)
    var roots: [SkillRoot] = [
      SkillRoot(
        kind: .projectDsh,
        url: project.appendingPathComponent(".dsh/skills", isDirectory: true),
        skipsSystem: false,
        isUserScoped: false
      ),
      SkillRoot(
        kind: .projectAgents,
        url: project.appendingPathComponent(".agents/skills", isDirectory: true),
        skipsSystem: false,
        isUserScoped: false
      ),
    ]
    roots += custom.map {
      SkillRoot(kind: .custom, url: $0.standardizedFileURL, skipsSystem: false, isUserScoped: false)
    }
    roots.append(
      SkillRoot(
        kind: .userDsh,
        url: dshHome.appendingPathComponent("skills", isDirectory: true),
        skipsSystem: true,
        isUserScoped: true
      )
    )
    roots.append(
      SkillRoot(
        kind: .userAgents,
        url: agentsHome.appendingPathComponent("skills", isDirectory: true),
        skipsSystem: false,
        isUserScoped: true
      )
    )
    return roots
  }

  /// The `~/.agents` home the official provider defaults to (`DSH_AGENTS_HOME` wins).
  public static func agentsHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let configured = environment["DSH_AGENTS_HOME"], !configured.isEmpty {
      return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".agents", isDirectory: true)
  }

  /// The directory a create/import writes into for the chosen write root.
  public static func directory(
    for choice: SkillWriteRoot,
    workspace: URL,
    dshHome: URL
  ) -> URL {
    switch choice {
    case .user:
      return dshHome.appendingPathComponent("skills", isDirectory: true)
    case .project:
      return projectRoot(forWorkspace: workspace).appendingPathComponent(".dsh/skills", isDirectory: true)
    }
  }
}
