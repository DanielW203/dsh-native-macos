import Foundation
import XCTest

@testable import HarnessSkills

/// The three writes this window performs on a skill: the two invocation switches, create, and
/// the recoverable delete.
final class SkillMutationTests: XCTestCase {
  // MARK: - Invocation switches

  func testModelInvocationSwitchWritesTheOfficialField() throws {
    let sandbox = try makeSandbox()
    let entry = try sandbox.writeBundle(
      in: sandbox.userSkills,
      directory: "animate",
      name: "animate",
      description: "动效",
      body: "\n# Body\n\n正文\n"
    )
    let skill = try XCTUnwrap(sandbox.skill(named: "animate"))

    try sandbox.center.setModelInvocable(skill, to: false, workspace: sandbox.workspace)
    XCTAssertEqual(
      try String(contentsOf: entry, encoding: .utf8),
      "---\nname: animate\ndescription: 动效\ndisable-model-invocation: true\n---\n\n# Body\n\n正文\n"
    )
    XCTAssertFalse(try XCTUnwrap(sandbox.skill(named: "animate")).modelInvocable)

    // Switching back writes the value rather than removing the key: an absent key and `false`
    // mean the same thing to the registry, and the file stays explicit about it.
    let off = try XCTUnwrap(sandbox.skill(named: "animate"))
    try sandbox.center.setModelInvocable(off, to: true, workspace: sandbox.workspace)
    XCTAssertEqual(
      try String(contentsOf: entry, encoding: .utf8),
      "---\nname: animate\ndescription: 动效\ndisable-model-invocation: false\n---\n\n# Body\n\n正文\n"
    )
    XCTAssertTrue(try XCTUnwrap(sandbox.skill(named: "animate")).modelInvocable)
  }

  func testUserInvocationSwitchIsIndependentOfTheModelSwitch() throws {
    let sandbox = try makeSandbox()
    let entry = try sandbox.writeBundle(
      in: sandbox.userSkills,
      directory: "pick-ui-library",
      name: "pick-ui-library",
      extraLines: ["disable-model-invocation: true"]
    )
    let skill = try XCTUnwrap(sandbox.skill(named: "pick-ui-library"))
    XCTAssertFalse(skill.modelInvocable)

    try sandbox.center.setUserInvocable(skill, to: false, workspace: sandbox.workspace)
    let updated = try XCTUnwrap(sandbox.skill(named: "pick-ui-library"))
    XCTAssertFalse(updated.modelInvocable, "the model switch must not be touched")
    XCTAssertFalse(updated.userInvocable)
    XCTAssertEqual(
      try String(contentsOf: entry, encoding: .utf8),
      "---\nname: pick-ui-library\ndescription: 描述\ndisable-model-invocation: true\nuser-invocable: false\n---\n\n# Body\n"
    )
  }

  func testRewriteLeavesNoTemporaryFileAndKeepsTheMode() throws {
    let sandbox = try makeSandbox()
    let entry = try sandbox.writeBundle(in: sandbox.userSkills, directory: "animate", name: "animate")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.path)
    let skill = try XCTUnwrap(sandbox.skill(named: "animate"))

    try sandbox.center.setModelInvocable(skill, to: false, workspace: sandbox.workspace)

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: entry.deletingLastPathComponent().path)
      .filter { $0.hasSuffix(".tmp") }
    XCTAssertTrue(leftovers.isEmpty, "left behind \(leftovers)")
    let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testToggleOnAVanishedSkillIsRefused() throws {
    let sandbox = try makeSandbox()
    let entry = try sandbox.writeBundle(in: sandbox.userSkills, directory: "animate", name: "animate")
    let skill = try XCTUnwrap(sandbox.skill(named: "animate"))
    try FileManager.default.removeItem(at: entry)

    XCTAssertThrowsError(try sandbox.center.setModelInvocable(skill, to: false, workspace: sandbox.workspace)) {
      XCTAssertEqual($0 as? SkillCenterError, .noSkillFound("animate"))
    }
  }

  func testToggleOnAFileWithoutFrontmatterIsRefused() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeFlat(in: sandbox.userSkills, file: "notes.md", name: "ignored")
    try "# no frontmatter\n".write(
      to: sandbox.userSkills.appendingPathComponent("notes.md"),
      atomically: true,
      encoding: .utf8
    )
    // The record is listed (with the frontmatter's complaint) but is not editable.
    let skill = try XCTUnwrap(sandbox.skill(named: "notes"))
    XCTAssertEqual(skill.issue, .missingFrontmatter)
    XCTAssertFalse(skill.isEditable)
    XCTAssertThrowsError(try sandbox.center.setModelInvocable(skill, to: false, workspace: sandbox.workspace)) {
      XCTAssertEqual($0 as? SkillCenterError, .missingFrontmatter("SKILL.md"))
    }
  }

  // MARK: - Create

  func testCreateWritesTheCanonicalTemplate() throws {
    let sandbox = try makeSandbox()
    var draft = SkillDraft()
    draft.name = "my-skill"
    draft.summary = "一句话描述"
    draft.whenToUse = "需要时"
    draft.content = "# 标题\n\n正文"
    draft.root = .user

    let record = try sandbox.center.create(draft, workspace: sandbox.workspace)
    let entry = sandbox.userSkills.appendingPathComponent("my-skill/SKILL.md")
    XCTAssertEqual(record.entryURL.path, entry.path)
    XCTAssertEqual(
      try String(contentsOf: entry, encoding: .utf8),
      "---\nname: my-skill\ndescription: '一句话描述'\nwhenToUse: '需要时'\n---\n\n# 标题\n\n正文\n"
    )
    // The template is immediately loadable as a skill.
    let created = try XCTUnwrap(sandbox.skill(named: "my-skill"))
    XCTAssertNil(created.issue)
    XCTAssertTrue(created.modelInvocable)
    XCTAssertTrue(created.userInvocable)
  }

  func testCreateValidatesItsInput() throws {
    let sandbox = try makeSandbox()
    func draft(_ mutate: (inout SkillDraft) -> Void) -> SkillDraft {
      var value = SkillDraft()
      value.name = "ok"
      value.summary = "描述"
      value.content = "正文"
      mutate(&value)
      return value
    }

    XCTAssertThrowsError(try sandbox.center.create(draft { $0.name = "Bad Name" }, workspace: sandbox.workspace)) {
      XCTAssertEqual($0 as? SkillCenterError, .invalidName("Bad Name"))
    }
    XCTAssertThrowsError(try sandbox.center.create(draft { $0.summary = "  " }, workspace: sandbox.workspace)) {
      XCTAssertEqual($0 as? SkillCenterError, .emptyDescription)
    }
    XCTAssertThrowsError(try sandbox.center.create(draft { $0.content = "\n " }, workspace: sandbox.workspace)) {
      XCTAssertEqual($0 as? SkillCenterError, .emptyContent)
    }
    let tooBig = String(repeating: "a", count: SkillFrontmatter.contentByteLimit + 1)
    XCTAssertThrowsError(try sandbox.center.create(draft { $0.content = tooBig }, workspace: sandbox.workspace)) {
      XCTAssertEqual(
        $0 as? SkillCenterError,
        .contentTooLarge(bytes: SkillFrontmatter.contentByteLimit + 1, limit: SkillFrontmatter.contentByteLimit)
      )
    }

    try sandbox.center.create(draft { _ in }, workspace: sandbox.workspace)
    XCTAssertThrowsError(try sandbox.center.create(draft { _ in }, workspace: sandbox.workspace)) {
      guard case .nameTaken(let name, _)? = $0 as? SkillCenterError else {
        return XCTFail("expected a taken name, got \($0)")
      }
      XCTAssertEqual(name, "ok")
    }
  }

  func testCreateInTheProjectRootUsesTheGitAncestor() throws {
    let sandbox = try makeSandbox()
    let nested = sandbox.workspace.appendingPathComponent("packages/app", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    var draft = SkillDraft()
    draft.name = "project-skill"
    draft.summary = "描述"
    draft.content = "正文"
    draft.root = .project
    let record = try sandbox.center.create(draft, workspace: nested)

    XCTAssertEqual(
      record.entryURL.path,
      sandbox.workspace.appendingPathComponent(".dsh/skills/project-skill/SKILL.md").path
    )
  }

  // MARK: - Delete, trash, restore

  func testDeleteMovesTheWholeBundleIntoTrashAndRestoreBringsItBack() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(
      in: sandbox.userSkills,
      directory: "animate",
      name: "animate",
      resources: ["RECIPES.md": "# 配方\n"]
    )
    let skill = try XCTUnwrap(sandbox.skill(named: "animate"))

    let trashed = try sandbox.center.delete(skill, workspace: sandbox.workspace)
    XCTAssertEqual(trashed.rootKind, .userDsh)
    XCTAssertEqual(trashed.trashURL.lastPathComponent, ".trash")
    XCTAssertTrue(trashed.trashedURL.path.hasPrefix(sandbox.userSkills.appendingPathComponent(".trash").path + "/"))
    XCTAssertTrue(trashed.trashedURL.lastPathComponent.hasSuffix("-animate"))
    // The bundle moves whole, resources included — that is what makes a restore exact.
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: trashed.trashedURL.appendingPathComponent("SKILL.md").path)
    )
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: trashed.trashedURL.appendingPathComponent("RECIPES.md").path)
    )
    // The sidecar that records where it came from.
    let sidecar = trashed.trashedURL.path + SkillTrashManifest.fileSuffix
    XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar))

    // Gone from the catalog, and the `.trash` directory is not itself a skill: discovery only
    // ever looks one level down, for `.trash/SKILL.md`.
    XCTAssertNil(sandbox.skill(named: "animate"))
    XCTAssertTrue(sandbox.catalog().skills.isEmpty)

    let listed = try XCTUnwrap(sandbox.center.trash(workspace: sandbox.workspace).first)
    XCTAssertEqual(listed.name, "animate")
    XCTAssertEqual(listed.originalURL.path, sandbox.userSkills.appendingPathComponent("animate").path)
    XCTAssertFalse(listed.isInferred)
    XCTAssertNotNil(listed.deletedAt)

    try sandbox.center.restore(listed)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: sandbox.userSkills.appendingPathComponent("animate/SKILL.md").path)
    )
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: sandbox.userSkills.appendingPathComponent("animate/RECIPES.md").path)
    )
    XCTAssertNotNil(sandbox.skill(named: "animate"))
    XCTAssertTrue(sandbox.center.trash(workspace: sandbox.workspace).isEmpty)
    // An empty `.trash` is removed so the root stops looking like it holds state.
    XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.userSkills.appendingPathComponent(".trash").path))
  }

  func testDeleteFlatSkillThenPurge() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeFlat(in: sandbox.userSkills, file: "prototype.md", name: "prototype")
    let skill = try XCTUnwrap(sandbox.skill(named: "prototype"))

    let trashed = try sandbox.center.delete(skill, workspace: sandbox.workspace)
    XCTAssertTrue(trashed.trashedURL.lastPathComponent.hasSuffix("-prototype.md"))
    XCTAssertEqual(trashed.form, .flat)

    let listed = try XCTUnwrap(sandbox.center.trash(workspace: sandbox.workspace).first)
    try sandbox.center.purge(listed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.trashedURL.path))
    XCTAssertTrue(sandbox.center.trash(workspace: sandbox.workspace).isEmpty)
  }

  func testTrashIsPerRoot() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "user-skill", name: "user-skill")
    try sandbox.writeBundle(in: sandbox.projectSkills, directory: "project-skill", name: "project-skill")
    try sandbox.center.delete(
      try XCTUnwrap(sandbox.skill(named: "user-skill")),
      workspace: sandbox.workspace
    )
    try sandbox.center.delete(
      try XCTUnwrap(sandbox.skill(named: "project-skill")),
      workspace: sandbox.workspace
    )

    let items = sandbox.center.trash(workspace: sandbox.workspace)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(Set(items.map(\.rootKind)), [.userDsh, .projectDsh])
    XCTAssertEqual(try sandbox.center.emptyTrash(workspace: sandbox.workspace), 2)
    XCTAssertTrue(sandbox.center.trash(workspace: sandbox.workspace).isEmpty)
  }

  func testAnItemTrashedByAnotherToolIsStillRecoverable() throws {
    let sandbox = try makeSandbox()
    // The Web plugin moves only SKILL.md into `.trash`, named `<ms>-SKILL.md`, and writes no
    // sidecar — the trash list has to reconstruct what it can.
    let trash = sandbox.userSkills.appendingPathComponent(".trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let text = try sandbox.bundleText(name: "orphan", description: "描述", extraLines: [], body: "\n# B\n")
    try text.write(to: trash.appendingPathComponent("1700000000000-SKILL.md"), atomically: true, encoding: .utf8)

    let item = try XCTUnwrap(sandbox.center.trash(workspace: sandbox.workspace).first)
    XCTAssertEqual(item.name, "orphan")
    XCTAssertTrue(item.isInferred)
    XCTAssertEqual(item.originalURL.path, sandbox.userSkills.appendingPathComponent("orphan.md").path)

    try sandbox.center.restore(item)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: sandbox.userSkills.appendingPathComponent("orphan.md").path)
    )
  }

  /// The Web skill centre deletes a bundle skill by moving only its `SKILL.md` into
  /// `<bundle>/.trash/<ms>-SKILL.md`. That layout must be visible here, or a skill deleted in
  /// the other panel would look permanently lost from this one.
  func testSkillTrashedInsideItsOwnBundleIsListedAndRestorable() throws {
    let sandbox = try makeSandbox()
    let bundle = sandbox.userSkills.appendingPathComponent("animate", isDirectory: true)
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "animate", name: "animate")
    let nested = bundle.appendingPathComponent(".trash", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
      at: bundle.appendingPathComponent("SKILL.md"),
      to: nested.appendingPathComponent("1700000000000-SKILL.md")
    )
    XCTAssertNil(sandbox.skill(named: "animate"), "the bundle is no longer loadable")

    let item = try XCTUnwrap(sandbox.center.trash(workspace: sandbox.workspace).first)
    XCTAssertEqual(item.name, "animate")
    XCTAssertTrue(item.isInferred)
    XCTAssertEqual(item.originalURL.path, bundle.appendingPathComponent("SKILL.md").path)

    try sandbox.center.restore(item)
    XCTAssertNotNil(sandbox.skill(named: "animate"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path), "the emptied nested trash is pruned")
  }

  func testRestoreRefusesToOverwriteARecreatedSkill() throws {    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "animate", name: "animate")
    let trashed = try sandbox.center.delete(
      try XCTUnwrap(sandbox.skill(named: "animate")),
      workspace: sandbox.workspace
    )
    // The user recreates the skill while the old copy is still in the trash.
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "animate", name: "animate")

    let item = try XCTUnwrap(sandbox.center.trash(workspace: sandbox.workspace).first)
    XCTAssertThrowsError(try sandbox.center.restore(item)) {
      guard case .entryOccupied(let path)? = $0 as? SkillCenterError else {
        return XCTFail("expected an occupied entry, got \($0)")
      }
      XCTAssertEqual(path, trashed.originalURL.path)
    }
  }

  func testDeletingTheSameNameTwiceKeepsBothCopies() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "one", name: "one")
    let first = try sandbox.center.delete(try XCTUnwrap(sandbox.skill(named: "one")), workspace: sandbox.workspace)

    // Recreate and delete again: the stamp has second resolution, so two deletes inside one
    // second would otherwise land on one name and the Web plugin would lose a copy.
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "one", name: "one")
    let second = try sandbox.center.delete(try XCTUnwrap(sandbox.skill(named: "one")), workspace: sandbox.workspace)

    XCTAssertNotEqual(first.trashedURL.path, second.trashedURL.path)
    let items = sandbox.center.trash(workspace: sandbox.workspace)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(Set(items.map(\.name)), ["one"])
    for item in items {
      XCTAssertTrue(FileManager.default.fileExists(atPath: item.trashedURL.appendingPathComponent("SKILL.md").path))
    }
  }
}
