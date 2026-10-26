import Foundation
import XCTest

@testable import HarnessSkills

/// Root composition, one-level discovery, and the rank rule that decides which of two skills
/// with one name a session actually loads.
final class SkillDiscoveryTests: XCTestCase {
  func testComposesTheOfficialRootsInRankOrder() throws {
    let sandbox = try makeSandbox()
    let roots = sandbox.center.roots(workspace: sandbox.workspace)
    XCTAssertEqual(
      roots.map(\.kind),
      [.projectDsh, .projectAgents, .userDsh, .userAgents]
    )
    XCTAssertEqual(roots.map(\.rank), [100, 200, 400, 500])
    XCTAssertEqual(roots[0].url.path, sandbox.projectSkills.path)
    XCTAssertEqual(roots[1].url.path, sandbox.projectAgentsSkills.path)
    XCTAssertEqual(roots[2].url.path, sandbox.userSkills.path)
    XCTAssertEqual(roots[3].url.path, sandbox.agentsHome.appendingPathComponent("skills").path)
    // Only the user root hides `.system`, exactly as the provider's `skipSystem` does.
    XCTAssertEqual(roots.map(\.skipsSystem), [false, false, true, false])
  }

  func testProjectRootIsTheNearestGitAncestor() throws {
    let sandbox = try makeSandbox()
    let nested = sandbox.workspace.appendingPathComponent("a/b/c", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    XCTAssertEqual(SkillRoots.projectRoot(forWorkspace: nested).path, sandbox.workspace.path)

    // Without a `.git` anywhere the workspace itself is the project root, as the official
    // `findProjectRoot` falls back to the original cwd.
    let loose = sandbox.root.appendingPathComponent("loose", isDirectory: true)
    try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
    XCTAssertEqual(SkillRoots.projectRoot(forWorkspace: loose).path, loose.path)
  }

  func testDiscoversBundlesAndFlatFiles() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "animate", name: "animate")
    try sandbox.writeFlat(in: sandbox.userSkills, file: "prototype.md", name: "prototype")

    let catalog = sandbox.catalog()
    XCTAssertEqual(catalog.skills.map(\.name), ["animate", "prototype"])
    let animate = try XCTUnwrap(sandbox.skill(named: "animate"))
    XCTAssertEqual(animate.form, .bundle)
    XCTAssertEqual(animate.entryURL.lastPathComponent, "SKILL.md")
    XCTAssertEqual(animate.resourceURL.lastPathComponent, "animate")
    let prototype = try XCTUnwrap(sandbox.skill(named: "prototype"))
    XCTAssertEqual(prototype.form, .flat)
    XCTAssertEqual(prototype.entryURL.lastPathComponent, "prototype.md")
    // A flat skill's resources resolve against the root it lives in.
    XCTAssertEqual(prototype.resourceURL.path, sandbox.userSkills.path)
    XCTAssertTrue(animate.isLoadable)
  }

  /// The provider scans one level and matches two exact names; everything else is invisible,
  /// which is also what keeps a `.trash` directory from resurrecting deleted skills.
  func testDiscoveryIsOneLevelDeepAndNameExact() throws {
    let sandbox = try makeSandbox()
    // A nested skill two levels down is not a skill.
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "group/inner", name: "inner")
    // A flat skill is only recognised by the lower-case extension: that half of the rule is a
    // string test, so it holds on any volume.
    try sandbox.writeFlat(in: sandbox.userSkills, file: "notes.MD", name: "notes")
    try sandbox.writeFlat(in: sandbox.userSkills, file: "readme.txt", name: "readme")
    XCTAssertTrue(sandbox.catalog().skills.isEmpty, "found \(sandbox.catalog().skills.map(\.name))")

    // The directory half asks the file system for `SKILL.md`, so whether `skill.md` counts is
    // the volume's case sensitivity talking — and the official provider asks the same question
    // in the same way. Asserted against a probe rather than against an assumption.
    let probe = sandbox.userSkills.appendingPathComponent("CaseProbe")
    try "x".write(to: probe, atomically: true, encoding: .utf8)
    let caseInsensitive = FileManager.default.fileExists(atPath: sandbox.userSkills.appendingPathComponent("caseprobe").path)
    try FileManager.default.removeItem(at: probe)

    try sandbox.writeBundle(in: sandbox.userSkills, directory: "lower", name: "lower")
    try FileManager.default.moveItem(
      at: sandbox.userSkills.appendingPathComponent("lower/SKILL.md"),
      to: sandbox.userSkills.appendingPathComponent("lower/skill.md")
    )
    XCTAssertEqual(sandbox.catalog().skills.contains { $0.name == "lower" }, caseInsensitive)
  }

  func testSystemDirectoryIsSkippedOnlyInTheUserRoot() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: ".system", name: "system-skill")
    try sandbox.writeBundle(in: sandbox.projectSkills, directory: ".system", name: "project-system")

    let names = sandbox.catalog().skills.map(\.name)
    XCTAssertFalse(names.contains("system-skill"))
    XCTAssertTrue(names.contains("project-system"))
  }

  func testSymlinkedSkillIsFollowedAndFlagged() throws {
    let sandbox = try makeSandbox()
    let external = sandbox.root.appendingPathComponent("external/my-skill", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let text = try sandbox.bundleText(name: "my-skill", description: "外链技能", extraLines: [], body: "\n# B\n")
    try text.write(to: external.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: sandbox.userSkills.appendingPathComponent("my-skill", isDirectory: true),
      withDestinationURL: external
    )

    let skill = try XCTUnwrap(sandbox.skill(named: "my-skill"))
    XCTAssertTrue(skill.isLinked)
    // Editable in place, but never deletable: a move would take the link target with it.
    XCTAssertTrue(skill.isEditable)
    XCTAssertFalse(skill.isDeletable)
    XCTAssertThrowsError(try sandbox.center.delete(skill, workspace: sandbox.workspace)) {
      XCTAssertEqual($0 as? SkillCenterError, .linkedSkill("my-skill"))
    }
  }

  func testDanglingSymlinkIsIgnored() throws {
    let sandbox = try makeSandbox()
    try FileManager.default.createSymbolicLink(
      at: sandbox.userSkills.appendingPathComponent("ghost", isDirectory: true),
      withDestinationURL: sandbox.root.appendingPathComponent("nowhere", isDirectory: true)
    )
    XCTAssertTrue(sandbox.catalog().skills.isEmpty)
  }

  func testBrokenFrontmatterIsListedButDoesNotShadowAGoodSkill() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "animate", name: "animate")
    // Same name, lower-priority root, unusable frontmatter: the provider drops it before
    // ranking, so it must not hide the good one — and the user still needs to see it.
    let broken = sandbox.projectSkills.appendingPathComponent("animate", isDirectory: true)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try "---\nname: animate\n---\n".write(
      to: broken.appendingPathComponent("SKILL.md"),
      atomically: true,
      encoding: .utf8
    )

    let catalog = sandbox.catalog()
    let brokenRecord = try XCTUnwrap(catalog.skills.first { $0.rootKind == .projectDsh })
    XCTAssertEqual(brokenRecord.issue, .missingDescription)
    XCTAssertNil(brokenRecord.shadowedBy)
    XCTAssertFalse(brokenRecord.isLoadable)
    let winner = try XCTUnwrap(catalog.skills.first { $0.rootKind == .userDsh })
    XCTAssertNil(winner.issue)
    XCTAssertNil(winner.shadowedBy)
    XCTAssertTrue(winner.isLoadable)
  }

  func testHigherRankRootWinsADuplicateNameAndTheLoserSaysSo() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "shared", name: "shared", description: "用户版")
    try sandbox.writeBundle(in: sandbox.projectSkills, directory: "shared", name: "shared", description: "项目版")

    let catalog = sandbox.catalog()
    let project = try XCTUnwrap(catalog.skills.first { $0.rootKind == .projectDsh })
    let user = try XCTUnwrap(catalog.skills.first { $0.rootKind == .userDsh })
    XCTAssertNil(project.shadowedBy)
    XCTAssertTrue(project.isLoadable)
    XCTAssertEqual(user.shadowedBy, .projectDsh)
    XCTAssertFalse(user.isLoadable)
  }

  func testCustomRootsSitBetweenProjectAndUser() throws {
    let sandbox = try makeSandbox()
    let custom = sandbox.root.appendingPathComponent("custom", isDirectory: true)
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    try sandbox.writeBundle(in: custom, directory: "extra", name: "extra")
    let center = SkillCenter(dshHome: sandbox.dshHome, agentsHome: sandbox.agentsHome, customSkillDirs: [custom])

    let catalog = center.catalog(workspace: sandbox.workspace)
    XCTAssertEqual(catalog.roots.map(\.kind), [.projectDsh, .projectAgents, .custom, .userDsh, .userAgents])
    XCTAssertEqual(catalog.skills.first?.rootKind, .custom)
    // A custom root's skills are its own, but they are not written to: create only offers the
    // user root and the project root.
    XCTAssertEqual(SkillWriteRoot.allCases, [.user, .project])
  }

  func testGroupsOnlyIncludeRootsThatExist() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "animate", name: "animate")
    let catalog = sandbox.catalog()
    XCTAssertEqual(catalog.groups.map(\.root.kind), [.userDsh])
    XCTAssertEqual(catalog.groups.first?.skills.map(\.name), ["animate"])

    try sandbox.writeBundle(in: sandbox.projectSkills, directory: "cro", name: "cro")
    XCTAssertEqual(sandbox.catalog().groups.map(\.root.kind), [.projectDsh, .userDsh])
  }

  func testSearchRanksNameHitsAheadOfDescriptionHits() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "seo-audit", name: "seo-audit", description: "审计")
    try sandbox.writeBundle(
      in: sandbox.userSkills,
      directory: "copywriting",
      name: "copywriting",
      description: "写文案时提到 seo 也要用"
    )
    let all = sandbox.catalog().skills
    XCTAssertEqual(SkillSearch.match(all, query: "SEO").map(\.name), ["seo-audit", "copywriting"])
    XCTAssertEqual(SkillSearch.match(all, query: "  ").count, 2)
  }
}
