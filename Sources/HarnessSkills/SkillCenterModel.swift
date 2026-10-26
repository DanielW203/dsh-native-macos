import AppKit
import Combine
import Foundation

/// Drives the 技能中心 window.
///
/// Every action is a method here and every outcome lands in the same two published strings
/// (`status` / `failure`), so the window never has to guess what happened — the same shape the
/// skin manager uses. Scans run on the main actor because they are a few dozen directory
/// reads; the one slow step, expanding an import archive, is a user-initiated action that runs
/// behind a busy label.
@MainActor
public final class SkillCenterModel: ObservableObject {
  /// The home whose `skills/` this window manages, shown in the header so a user with two
  /// installs knows which one they are about to change.
  @Published public private(set) var dshHome: String
  @Published public private(set) var workspace: String = ""
  @Published public private(set) var projectRoot: String = ""
  @Published public private(set) var groups: [SkillGroup] = []
  /// Every scanned skill, winners and shadowed alike, before the filter box.
  @Published public private(set) var allSkills: [SkillRecord] = []
  @Published public private(set) var trash: [TrashedSkill] = []
  @Published public private(set) var warnings: [String] = []
  @Published public private(set) var busyLabel: String?
  @Published public private(set) var status: String?
  @Published public private(set) var failure: String?
  @Published public private(set) var refreshedAt: Date?
  /// The filter box. Name hits are ranked above description hits by `SkillSearch`.
  @Published public var searchText: String = ""

  private let center: SkillCenter
  private let workspaceProvider: @Sendable () -> URL?
  private let fallbackWorkspace: URL
  private var started = false

  public init(
    dshHome: URL,
    workspaceProvider: @escaping @Sendable () -> URL?,
    fallbackWorkspace: URL,
    customSkillDirs: [URL] = [],
    center: SkillCenter? = nil
  ) {
    self.dshHome = dshHome.path
    self.workspaceProvider = workspaceProvider
    self.fallbackWorkspace = fallbackWorkspace
    self.center = center ?? SkillCenter(dshHome: dshHome, customSkillDirs: customSkillDirs)
  }

  public var isBusy: Bool { busyLabel != nil }
  /// Skills a session could actually load: not shadowed, not broken.
  public var loadableCount: Int { allSkills.filter { $0.isLoadable }.count }
  public var brokenCount: Int { allSkills.filter { $0.issue != nil }.count }
  public var trashCount: Int { trash.count }

  /// The workspace the window is scanning, resolved on every use so a workspace change made in
  /// the main window is reflected without a restart.
  public var resolvedWorkspace: URL {
    workspaceProvider()?.standardizedFileURL ?? fallbackWorkspace.standardizedFileURL
  }

  public func startIfNeeded() {
    guard !started else { return }
    started = true
    refresh()
  }

  /// Re-scan the roots and the trash.
  ///
  /// Deliberately silent about `status` / `failure`: a refresh triggered by `.task` must not
  /// erase the result of the action the user just took.
  public func refresh() {
    let workspace = resolvedWorkspace
    let catalog = center.catalog(workspace: workspace)
    self.workspace = catalog.workspace.path
    self.projectRoot = catalog.projectRoot.path
    self.allSkills = catalog.skills
    self.groups = catalog.groups
    self.warnings = catalog.warnings
    self.refreshedAt = catalog.scannedAt
    self.trash = center.trash(workspace: workspace)
  }

  /// The groups the window renders: the filter applied, empty sections dropped while filtering.
  public var visibleGroups: [SkillGroup] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return groups }
    return groups.compactMap { group in
      let matches = SkillSearch.match(group.skills, query: query)
      return matches.isEmpty ? nil : SkillGroup(root: group.root, skills: matches)
    }
  }

  public var visibleSkillCount: Int {
    visibleGroups.reduce(0) { $0 + $1.skills.count }
  }

  // MARK: - Invocation switches

  public func setModelInvocable(_ skill: SkillRecord, to value: Bool) {
    guard value != skill.modelInvocable else { return }
    let workspace = resolvedWorkspace
    do {
      try center.setModelInvocable(skill, to: value, workspace: workspace)
      status = value
        ? "「\(skill.name)」已允许模型调用。"
        : "「\(skill.name)」已禁止模型调用（不再进入技能目录）。"
      failure = nil
    } catch {
      failure = message(for: error)
    }
    refresh()
  }

  public func setUserInvocable(_ skill: SkillRecord, to value: Bool) {
    guard value != skill.userInvocable else { return }
    let workspace = resolvedWorkspace
    do {
      try center.setUserInvocable(skill, to: value, workspace: workspace)
      status = value
        ? "「\(skill.name)」已允许 /\(skill.name) 手动调用。"
        : "「\(skill.name)」已从手动 /技能 列表中移除。"
      failure = nil
    } catch {
      failure = message(for: error)
    }
    refresh()
  }

  // MARK: - Create and import

  /// - Returns: whether the skill was created.
  @discardableResult
  public func create(_ draft: SkillDraft) -> Bool {
    busyLabel = "正在创建技能…"
    defer { busyLabel = nil }
    do {
      let record = try center.create(draft, workspace: resolvedWorkspace)
      status = "已创建「\(record.name)」：\(record.entryURL.path)"
      failure = nil
      refresh()
      return true
    } catch {
      failure = message(for: error)
      refresh()
      return false
    }
  }

  /// - Returns: whether the skill was imported.
  @discardableResult
  public func importSkill(from source: URL, into root: SkillWriteRoot) -> Bool {
    busyLabel = "正在导入 \(source.lastPathComponent)…"
    defer { busyLabel = nil }
    do {
      let record = try center.importSkill(from: source, into: root, workspace: resolvedWorkspace)
      status = "已导入「\(record.name)」到 \(record.rootURL.path)"
      failure = nil
      refresh()
      return true
    } catch {
      failure = message(for: error)
      refresh()
      return false
    }
  }

  public func writeRootDirectory(_ choice: SkillWriteRoot) -> String {
    SkillRoots.directory(for: choice, workspace: resolvedWorkspace, dshHome: URL(fileURLWithPath: dshHome))
      .path
  }

  // MARK: - Delete and trash

  public func delete(_ skill: SkillRecord) {
    do {
      let trashed = try center.delete(skill, workspace: resolvedWorkspace)
      status = "「\(skill.name)」已移入回收站（\(trashed.trashURL.path)），可随时恢复。"
      failure = nil
    } catch {
      failure = message(for: error)
    }
    refresh()
  }

  public func restore(_ item: TrashedSkill) {
    do {
      let restored = try center.restore(item)
      status = "已恢复「\(item.name)」到 \(restored.path)"
      failure = nil
    } catch {
      failure = message(for: error)
    }
    refresh()
  }

  public func purge(_ item: TrashedSkill) {
    do {
      try center.purge(item)
      status = "已彻底删除「\(item.name)」。"
      failure = nil
    } catch {
      failure = message(for: error)
    }
    refresh()
  }

  public func emptyTrash() {
    do {
      let removed = try center.emptyTrash(workspace: resolvedWorkspace)
      status = removed == 0 ? "回收站已经是空的。" : "已彻底删除 \(removed) 个回收站条目。"
      failure = nil
    } catch {
      failure = message(for: error)
    }
    refresh()
  }

  /// Re-read only the trash, for the trash sheet's own refresh button.
  public func refreshTrash() {
    trash = center.trash(workspace: resolvedWorkspace)
  }

  // MARK: - Small helpers the window uses

  public func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  public func open(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  public func clearMessages() {
    status = nil
    failure = nil
  }

  private func message(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
