import Darwin
import Foundation

/// The skills half of a harness home: discovery, the two invocation switches, create,
/// import, and a recoverable delete.
///
/// Everything here is synchronous file work — a skill is a few kilobytes of markdown — and
/// the model above it calls these methods on the main actor, exactly as `SkinManager` does.
/// The one step that can take real time is expanding an archive, which is why the command
/// runner is an injected seam.
///
/// What this type deliberately does *not* do: it never touches a skill the harness composes
/// from a package (`bundled` / `runtime` providers) because those have no file to edit, and it
/// never writes outside the roots it reports. A panel path is a claim, never an authority — every
/// mutation re-resolves the skill against a fresh scan first, the same rule the Web plugin's
/// mutation routes enforce.
public struct SkillCenter: Sendable {
  public let dshHome: URL
  public let agentsHome: URL
  public let customSkillDirs: [URL]

  private let runner: any SkillCommandRunning

  public init(
    dshHome: URL,
    agentsHome: URL? = nil,
    customSkillDirs: [URL] = [],
    runner: (any SkillCommandRunning)? = nil
  ) {
    self.dshHome = dshHome
    self.agentsHome = agentsHome ?? SkillRoots.agentsHome()
    self.customSkillDirs = customSkillDirs
    self.runner = runner ?? SystemSkillCommandRunner()
  }

  // MARK: - Discovery

  /// The roots the official filesystem provider composes for `workspace`, in rank order.
  public func roots(workspace: URL) -> [SkillRoot] {
    SkillRoots.resolve(
      workspace: workspace,
      dshHome: dshHome,
      agentsHome: agentsHome,
      custom: customSkillDirs
    )
  }

  /// Scan every root and resolve duplicate names the way `@deepseek-ai/dsh-skill` does.
  public func catalog(workspace: URL) -> SkillCatalog {
    let resolved = roots(workspace: workspace)
    let projectRoot = SkillRoots.projectRoot(forWorkspace: workspace)
    var warnings: [String] = []
    var found: [SkillRecord] = []
    for root in resolved {
      found += scan(root: root, warnings: &warnings)
    }

    // Rank resolution. Only entries the provider would accept can win or be shadowed: an
    // unloadable file is dropped before ranking, so it must not hide a good skill with the
    // same on-disk name.
    var winner: [String: SkillRecord] = [:]
    var skills: [SkillRecord] = []
    for var skill in found {
      guard skill.issue == nil else {
        skills.append(skill)
        continue
      }
      if let existing = winner[skill.name] {
        skill.shadowedBy = existing.rootKind
      } else {
        winner[skill.name] = skill
      }
      skills.append(skill)
    }
    skills.sort { left, right in
      if left.name != right.name {
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
      }
      return left.rootKind.rank < right.rootKind.rank
    }

    return SkillCatalog(
      workspace: workspace.standardizedFileURL,
      projectRoot: projectRoot,
      roots: resolved,
      skills: skills,
      scannedAt: Date(),
      warnings: warnings
    )
  }

  private func scan(root: SkillRoot, warnings: inout [String]) -> [SkillRecord] {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: root.url.path) else { return [] }
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: root.url,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: []
      )
    } catch {
      warnings.append("无法读取 \(root.url.path)：\(error.localizedDescription)")
      return []
    }

    var records: [SkillRecord] = []
    // The provider's own order inside a root: by entry name. It decides which of two entries
    // claiming one name wins, so it cannot be the file system's arbitrary order.
    for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
      let entryName = entry.lastPathComponent
      if root.skipsSystem && entryName == ".system" { continue }

      // Follow the link to decide the shape, as `nodeEntryKind` does with `stat`: a link to a
      // skill directory is a skill, a dangling link is not.
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
      let isLinked = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false

      if isDirectory.boolValue {
        let entryURL = entry.appendingPathComponent("SKILL.md", isDirectory: false)
        guard fileManager.fileExists(atPath: entryURL.path) else { continue }
        records.append(
          record(
            root: root,
            entryURL: entryURL,
            resourceURL: entry,
            form: .bundle,
            isLinked: isLinked,
            fallbackName: entryName
          )
        )
      } else if entryName.hasSuffix(".md") {
        records.append(
          record(
            root: root,
            entryURL: entry,
            resourceURL: root.url,
            form: .flat,
            isLinked: isLinked,
            fallbackName: String(entryName.dropLast(3))
          )
        )
      }
    }
    return records
  }

  private func record(
    root: SkillRoot,
    entryURL: URL,
    resourceURL: URL,
    form: SkillRecord.Form,
    isLinked: Bool,
    fallbackName: String
  ) -> SkillRecord {
    // `realpath` in the provider's node backend means the *file* it reads is the link target;
    // the path a mutation writes is the one the scan found, which is what keeps a symlinked
    // skill editable in place without this app ever inventing a path of its own.
    let raw: String
    do {
      raw = try String(contentsOf: entryURL, encoding: .utf8)
    } catch {
      return SkillRecord(
        name: fallbackName,
        summary: SkillFrontmatterIssue.unreadableFile.message,
        form: form,
        entryURL: entryURL,
        resourceURL: resourceURL,
        rootKind: root.kind,
        rootURL: root.url,
        isLinked: isLinked,
        issue: .unreadableFile
      )
    }

    switch SkillFrontmatter.read(raw) {
    case .loaded(let metadata):
      return SkillRecord(
        name: metadata.name,
        summary: metadata.description,
        whenToUse: metadata.whenToUse,
        form: form,
        entryURL: entryURL,
        resourceURL: resourceURL,
        rootKind: root.kind,
        rootURL: root.url,
        isLinked: isLinked,
        modelInvocable: metadata.modelInvocable,
        userInvocable: metadata.userInvocable
      )
    case .issue(let issue):
      return SkillRecord(
        name: fallbackName,
        summary: issue.message,
        form: form,
        entryURL: entryURL,
        resourceURL: resourceURL,
        rootKind: root.kind,
        rootURL: root.url,
        isLinked: isLinked,
        issue: issue
      )
    }
  }

  // MARK: - Invocation switches

  /// Turn model invocation on or off by writing `disable-model-invocation`.
  ///
  /// The value is always written rather than removed when it matches the default: an absent
  /// key and `false` mean the same thing to the registry, and a file that carries the switch
  /// explicitly is a file whose state a reader can see.
  @discardableResult
  public func setModelInvocable(_ skill: SkillRecord, to value: Bool, workspace: URL) throws -> SkillRecord {
    try rewrite(skill, field: "disable-model-invocation", value: !value, workspace: workspace)
  }

  /// Turn human (`/skill`) invocation on or off by writing `user-invocable`.
  @discardableResult
  public func setUserInvocable(_ skill: SkillRecord, to value: Bool, workspace: URL) throws -> SkillRecord {
    try rewrite(skill, field: "user-invocable", value: value, workspace: workspace)
  }

  private func rewrite(
    _ skill: SkillRecord,
    field: String,
    value: Bool,
    workspace: URL
  ) throws -> SkillRecord {
    let current = try resolve(skill, workspace: workspace)
    let raw = try readText(current.entryURL)
    let updated = try SkillFrontmatter.setting(field, to: value, in: raw)
    try writeAtomically(updated, to: current.entryURL)
    return try recordAfterWrite(current, raw: updated)
  }

  /// Re-resolve a panel row against a fresh scan.
  ///
  /// A row is a claim about a path; the scan is the authority. A skill that moved keeps the
  /// name but loses its path, and a skill that vanished is gone — the two are reported apart
  /// because only one of them is fixed by refreshing.
  private func resolve(_ skill: SkillRecord, workspace: URL) throws -> SkillRecord {
    let fresh = catalog(workspace: workspace).skills.first { $0.id == skill.id && $0.name == skill.name }
    if let fresh { return fresh }
    if FileManager.default.fileExists(atPath: skill.entryURL.path) {
      throw SkillCenterError.pathChanged(skill.name)
    }
    throw SkillCenterError.noSkillFound(skill.name)
  }

  private func recordAfterWrite(_ previous: SkillRecord, raw: String) throws -> SkillRecord {
    switch SkillFrontmatter.read(raw) {
    case .loaded(let metadata):
      var updated = previous
      updated.name = metadata.name
      updated.summary = metadata.description
      updated.whenToUse = metadata.whenToUse
      updated.modelInvocable = metadata.modelInvocable
      updated.userInvocable = metadata.userInvocable
      updated.issue = nil
      return updated
    case .issue(let issue):
      // The write succeeded but produced a file the provider would now ignore — say so
      // rather than reporting a clean switch.
      throw SkillCenterError.fileSystem("写入后 \(previous.entryURL.path) 无法被解析：\(issue.message)")
    }
  }

  // MARK: - Create

  /// Write a new skill bundle from the create form.
  @discardableResult
  public func create(_ draft: SkillDraft, workspace: URL) throws -> SkillRecord {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SkillFrontmatter.isSkillName(name) else { throw SkillCenterError.invalidName(name) }
    let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !summary.isEmpty else { throw SkillCenterError.emptyDescription }
    let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw SkillCenterError.emptyContent }
    let bytes = content.utf8.count
    guard bytes <= SkillFrontmatter.contentByteLimit else {
      throw SkillCenterError.contentTooLarge(bytes: bytes, limit: SkillFrontmatter.contentByteLimit)
    }

    let directory = SkillRoots.directory(for: draft.root, workspace: workspace, dshHome: dshHome)
    let bundle = directory.appendingPathComponent(name, isDirectory: true)
    let entryURL = bundle.appendingPathComponent("SKILL.md", isDirectory: false)
    if FileManager.default.fileExists(atPath: entryURL.path) {
      throw SkillCenterError.nameTaken(name, at: entryURL.path)
    }
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

    let text = SkillFrontmatter.created(
      name: name,
      description: summary,
      whenToUse: draft.whenToUse,
      content: content
    )
    try writeAtomically(text, to: entryURL)

    guard let root = roots(workspace: workspace).first(where: { $0.url.path == directory.path }) else {
      throw SkillCenterError.fileSystem("创建目录不在任何技能根内：\(directory.path)")
    }
    return record(
      root: root,
      entryURL: entryURL,
      resourceURL: bundle,
      form: .bundle,
      isLinked: false,
      fallbackName: name
    )
  }

  // MARK: - Import

  /// Copy a skill into `choice` from a directory, a single `.md`, or a `.zip` / `.tar.gz`.
  @discardableResult
  public func importSkill(from source: URL, into choice: SkillWriteRoot, workspace: URL) throws -> SkillRecord {
    let directory = SkillRoots.directory(for: choice, workspace: workspace, dshHome: dshHome)
    let staging = try makeStagingDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }

    let item = try materialize(source, into: staging)
    let entryURL =
      item.form == .bundle
      ? item.url.appendingPathComponent("SKILL.md", isDirectory: false)
      : item.url
    let raw = try readText(entryURL)
    let metadata: SkillMetadata
    switch SkillFrontmatter.read(raw) {
    case .loaded(let parsed): metadata = parsed
    case .issue(let issue): throw SkillCenterError.sourceNotSkill(path: entryURL.path, reason: issue.message)
    }

    let name = metadata.name
    guard SkillFrontmatter.isSkillName(name) else { throw SkillCenterError.invalidName(name) }

    // The destination is named after the frontmatter, not after whatever the source directory
    // happened to be called: `my-skill (1)` must not become a skill's identity.
    let destination: URL
    switch item.form {
    case .bundle:
      destination = directory.appendingPathComponent(name, isDirectory: true)
    case .flat:
      destination = directory.appendingPathComponent("\(name).md", isDirectory: false)
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      throw SkillCenterError.nameTaken(name, at: destination.path)
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: item.url, to: destination)

    guard let root = roots(workspace: workspace).first(where: { $0.url.path == directory.path }) else {
      throw SkillCenterError.fileSystem("导入目录不在任何技能根内：\(directory.path)")
    }
    let copiedEntry =
      item.form == .bundle
      ? destination.appendingPathComponent("SKILL.md", isDirectory: false)
      : destination
    return record(
      root: root,
      entryURL: copiedEntry,
      resourceURL: item.form == .bundle ? destination : directory,
      form: item.form,
      isLinked: false,
      fallbackName: name
    )
  }

  /// One importable item: where it is and which shape it has.
  struct ImportItem: Sendable, Equatable {
    var url: URL
    var form: SkillRecord.Form
  }

  /// Turn a picked path into the item to copy, expanding an archive into `staging` first.
  func materialize(_ source: URL, into staging: URL) throws -> ImportItem {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
      throw SkillCenterError.sourceNotSkill(path: source.path, reason: "路径不存在。")
    }

    if isDirectory.boolValue {
      return try locateSkill(in: source)
    }
    if source.pathExtension.lowercased() == "md" {
      return ImportItem(url: source, form: .flat)
    }
    guard let kind = SkillArchiveKind.detect(source) else {
      throw SkillCenterError.sourceNotSkill(
        path: source.path,
        reason: "只支持目录、单个 .md、.zip 和 .tar.gz / .tgz。"
      )
    }
    let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
    try fileManager.createDirectory(at: expanded, withIntermediateDirectories: true)
    let command = kind.extractionCommand(archive: source, into: expanded)
    let outcome = try runner.run(executable: command.executable, arguments: command.arguments, currentDirectory: nil)
    guard outcome.status == 0 else {
      throw SkillCenterError.commandFailed(
        label: "解包 \(kind.title)",
        status: outcome.status,
        message: outcome.standardError
      )
    }
    return try locateSkill(in: expanded)
  }

  /// Find the skill inside a directory: the directory itself, or its single skill child.
  ///
  /// An archive normally carries one top-level folder, so both shapes have to work; two
  /// candidates is ambiguous and refused rather than guessed.
  private func locateSkill(in directory: URL) throws -> ImportItem {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path) {
      return ImportItem(url: directory, form: .bundle)
    }
    let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
    var candidates: [URL] = []
    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      var isChildDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: child.path, isDirectory: &isChildDirectory), isChildDirectory.boolValue
      else { continue }
      if fileManager.fileExists(atPath: child.appendingPathComponent("SKILL.md").path) {
        candidates.append(child)
      }
    }
    // `.DS_Store`, `__MACOSX` and a flattened bundle are all ignored by the check above.
    if candidates.count == 1 { return ImportItem(url: candidates[0], form: .bundle) }
    if candidates.count > 1 {
      throw SkillCenterError.sourceNotSkill(
        path: directory.path,
        reason: "目录下有 \(candidates.count) 个技能，请只选其中一个。"
      )
    }
    throw SkillCenterError.sourceNotSkill(path: directory.path, reason: "没有找到 SKILL.md。")
  }

  private func makeStagingDirectory() throws -> URL {
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsh-skill-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    return staging
  }

  // MARK: - Delete, trash, restore

  /// Move a skill into its root's `.trash`.
  ///
  /// The whole entry moves — the bundle directory, not just its `SKILL.md` — because a skill
  /// is its referenced resources too, and because that is what makes a restore exact. The
  /// `.trash` directory is invisible to the provider for the same reason the Web plugin's is:
  /// discovery is one level deep, so it only ever looks for `.trash/SKILL.md`.
  @discardableResult
  public func delete(_ skill: SkillRecord, workspace: URL) throws -> TrashedSkill {
    let current = try resolve(skill, workspace: workspace)
    guard current.isDeletable else { throw SkillCenterError.linkedSkill(current.name) }

    let fileManager = FileManager.default
    let trashURL = current.rootURL.appendingPathComponent(".trash", isDirectory: true)
    try fileManager.createDirectory(at: trashURL, withIntermediateDirectories: true)

    let relativePath =
      current.form == .bundle
      ? current.resourceURL.lastPathComponent
      : current.entryURL.lastPathComponent
    let source = current.form == .bundle ? current.resourceURL : current.entryURL
    let destination = uniqueURL(for: "\(Self.stamp())-\(relativePath)", in: trashURL)
    try fileManager.moveItem(at: source, to: destination)

    let deletedAt = Date()
    let manifest = SkillTrashManifest(
      schemaVersion: SkillTrashManifest.currentSchemaVersion,
      name: current.name,
      relativePath: relativePath,
      form: current.form.rawValue,
      deletedAt: deletedAt
    )
    writeManifest(manifest, beside: destination)

    return TrashedSkill(
      name: current.name,
      trashedURL: destination,
      originalURL: current.rootURL.appendingPathComponent(relativePath),
      form: current.form,
      rootKind: current.rootKind,
      rootURL: current.rootURL,
      deletedAt: deletedAt,
      bytes: SkillCenter.byteCount(of: destination)
    )
  }

  /// Everything sitting in the roots' `.trash` directories, newest first.
  ///
  /// Two layouts are read, because two tools delete skills on this machine:
  ///
  /// * this window's `<root>/.trash/<stamp>-<entry>` with a sidecar, and
  /// * the Web plugin's `<bundle>/.trash/<ms>-SKILL.md`, which is invisible to a scan of the
  ///   root's own `.trash` — and to the official provider, which is exactly why the skill is
  ///   still deleted and still needs a way back.
  public func trash(workspace: URL) -> [TrashedSkill] {
    let fileManager = FileManager.default
    var items: [TrashedSkill] = []
    for root in roots(workspace: workspace) {
      items += collectTrashed(
        in: root.url.appendingPathComponent(".trash", isDirectory: true),
        root: root,
        manifestTarget: { root.url.appendingPathComponent($0.relativePath) },
        inferredTarget: { name, form in
          form == .bundle
            ? root.url.appendingPathComponent(name, isDirectory: true)
            : root.url.appendingPathComponent("\(name).md", isDirectory: false)
        }
      )

      guard let children = try? fileManager.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil, options: [])
      else { continue }
      for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue,
          child.lastPathComponent != ".trash"
        else { continue }
        // Rebuilt from the root instead of reusing `child`: `contentsOfDirectory` may report
        // `/private/var/...` for a directory reached through `/var/...` (measured), and every
        // path this window shows should be spelled the way the rest of the app spells it.
        let bundle = root.url.appendingPathComponent(child.lastPathComponent, isDirectory: true)
        items += collectTrashed(
          in: bundle.appendingPathComponent(".trash", isDirectory: true),
          root: root,
          manifestTarget: { bundle.appendingPathComponent($0.relativePath) },
          // The Web plugin's trashed file *is* the bundle's SKILL.md, so that is where it goes.
          inferredTarget: { _, _ in bundle.appendingPathComponent("SKILL.md", isDirectory: false) }
        )
      }
    }
    return items.sorted { left, right in
      let leftDate = left.deletedAt ?? .distantPast
      let rightDate = right.deletedAt ?? .distantPast
      if leftDate != rightDate { return leftDate > rightDate }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
  }

  /// List one `.trash` directory, pairing each item with its sidecar when there is one.
  private func collectTrashed(
    in trashURL: URL,
    root: SkillRoot,
    manifestTarget: (SkillTrashManifest) -> URL,
    inferredTarget: (String, SkillRecord.Form) -> URL
  ) -> [TrashedSkill] {
    guard let entries = try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: [])
    else { return [] }
    var items: [TrashedSkill] = []
    for entry in entries where !entry.lastPathComponent.hasSuffix(SkillTrashManifest.fileSuffix) {
      if let manifest = readManifest(beside: entry) {
        items.append(
          TrashedSkill(
            name: manifest.name,
            trashedURL: entry,
            originalURL: manifestTarget(manifest),
            form: manifest.form == SkillRecord.Form.flat.rawValue ? .flat : .bundle,
            rootKind: root.kind,
            rootURL: root.url,
            deletedAt: manifest.deletedAt,
            bytes: SkillCenter.byteCount(of: entry)
          )
        )
        continue
      }
      items.append(inferredItem(at: entry, root: root, target: inferredTarget))
    }
    return items
  }

  /// Reconstruct a trashed item that has no sidecar: the name comes from the file's own
  /// frontmatter when it still parses, and the shape from what is actually on disk.
  private func inferredItem(
    at entry: URL,
    root: SkillRoot,
    target: (String, SkillRecord.Form) -> URL
  ) -> TrashedSkill {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory)
    var form: SkillRecord.Form = isDirectory.boolValue ? .bundle : .flat
    var entryURL = isDirectory.boolValue ? entry.appendingPathComponent("SKILL.md") : entry
    if !fileManager.fileExists(atPath: entryURL.path) {
      form = .flat
      entryURL = entry
    }
    let raw = (try? String(contentsOf: entryURL, encoding: .utf8)) ?? ""
    let name: String
    if case .loaded(let metadata) = SkillFrontmatter.read(raw) {
      name = metadata.name
    } else {
      let base = entry.lastPathComponent
      name = String(base.dropLast(base.hasSuffix(".md") ? 3 : 0))
    }
    let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    return TrashedSkill(
      name: name,
      trashedURL: entry,
      originalURL: target(name, form),
      form: form,
      rootKind: root.kind,
      rootURL: root.url,
      deletedAt: modified,
      bytes: SkillCenter.byteCount(of: entry),
      isInferred: true
    )
  }

  /// Move a trashed skill back where it came from.
  @discardableResult
  public func restore(_ item: TrashedSkill) throws -> URL {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: item.trashedURL.path) else {
      throw SkillCenterError.trashMissing(item.trashedURL.path)
    }
    if fileManager.fileExists(atPath: item.originalURL.path) {
      throw SkillCenterError.entryOccupied(item.originalURL.path)
    }
    try fileManager.createDirectory(at: item.originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.moveItem(at: item.trashedURL, to: item.originalURL)
    removeManifest(beside: item.trashedURL)
    pruneTrashIfEmpty(item.trashURL)
    return item.originalURL
  }

  /// Delete one trashed skill for good.
  public func purge(_ item: TrashedSkill) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: item.trashedURL.path) else {
      throw SkillCenterError.trashMissing(item.trashedURL.path)
    }
    try fileManager.removeItem(at: item.trashedURL)
    removeManifest(beside: item.trashedURL)
    pruneTrashIfEmpty(item.trashURL)
  }

  /// Empty every root's `.trash`. Returns how many items were removed.
  @discardableResult
  public func emptyTrash(workspace: URL) throws -> Int {
    let fileManager = FileManager.default
    var removed = 0
    for root in roots(workspace: workspace) {
      let trashURL = root.url.appendingPathComponent(".trash", isDirectory: true)
      guard let entries = try? fileManager.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: [])
      else { continue }
      for entry in entries {
        try fileManager.removeItem(at: entry)
        if !entry.lastPathComponent.hasSuffix(SkillTrashManifest.fileSuffix) { removed += 1 }
      }
      pruneTrashIfEmpty(trashURL)
    }
    return removed
  }

  // MARK: - File helpers

  private func readText(_ url: URL) throws -> String {
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw SkillCenterError.fileSystem("无法读取 \(url.path)：\(error.localizedDescription)")
    }
  }

  /// Replace a file's contents in one step.
  ///
  /// Written beside the target and renamed over it: a half-written SKILL.md is a skill the
  /// harness drops, and the harness watches these directories, so it must never observe a
  /// partial file. The original mode is copied onto the temporary file first, because a
  /// rename would otherwise silently relax a file the user had tightened.
  func writeAtomically(_ text: String, to url: URL) throws {
    let fileManager = FileManager.default
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
      isDirectory: false
    )
    guard fileManager.createFile(atPath: temporary.path, contents: Data(text.utf8)) else {
      throw SkillCenterError.fileSystem("无法写入临时文件：\(temporary.path)")
    }
    if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let permissions = attributes[.posixPermissions]
    {
      try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
    }
    guard rename(temporary.path, url.path) == 0 else {
      let message = String(cString: strerror(errno))
      try? fileManager.removeItem(at: temporary)
      throw SkillCenterError.fileSystem("替换 \(url.path) 失败：\(message)")
    }
  }

  /// The file-system copy of the Web plugin's trash name: `yyyyMMdd-HHmmss` in local time.
  static func stamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }

  /// A name inside `directory` that is not taken yet, so two deletes in one second keep both.
  private func uniqueURL(for name: String, in directory: URL) -> URL {
    let fileManager = FileManager.default
    var candidate = directory.appendingPathComponent(name, isDirectory: false)
    var suffix = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(name)-\(suffix)", isDirectory: false)
      suffix += 1
    }
    return candidate
  }

  private func manifestURL(beside item: URL) -> URL {
    item.deletingLastPathComponent()
      .appendingPathComponent(item.lastPathComponent + SkillTrashManifest.fileSuffix, isDirectory: false)
  }

  private func writeManifest(_ manifest: SkillTrashManifest, beside item: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    // Best effort on purpose. The item is already moved, so a sidecar failure must not turn a
    // finished delete into a reported error; the trash list reconstructs the entry from the
    // file itself and says that it did (`isInferred`).
    try? encoder.encode(manifest).write(to: manifestURL(beside: item), options: .atomic)
  }

  private func readManifest(beside item: URL) -> SkillTrashManifest? {
    guard let data = try? Data(contentsOf: manifestURL(beside: item)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SkillTrashManifest.self, from: data)
  }

  private func removeManifest(beside item: URL) {
    try? FileManager.default.removeItem(at: manifestURL(beside: item))
  }

  /// An empty `.trash` is removed so a root the user emptied stops looking like it has state.
  private func pruneTrashIfEmpty(_ trashURL: URL) {
    let fileManager = FileManager.default
    guard let remaining = try? fileManager.contentsOfDirectory(atPath: trashURL.path), remaining.isEmpty else { return }
    try? fileManager.removeItem(at: trashURL)
  }

  /// The recursive size of one skill, for the trash list.
  public static func byteCount(of url: URL) -> Int64 {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    if !isDirectory.boolValue {
      let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
      return size?.int64Value ?? 0
    }
    guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let child as URL in enumerator {
      if let size = try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        total += Int64(size)
      }
    }
    return total
  }
}
