import Foundation
import XCTest

@testable import HarnessSkills

/// Adding a skill to a root: from a directory, from a single markdown file, and from a packed
/// archive.
final class SkillImportTests: XCTestCase {
  /// Write a source bundle at `relativePath` under the sandbox root and return it.
  private func makeSourceBundle(
    _ sandbox: SkillSandbox,
    at relativePath: String,
    name: String,
    resources: [String: String] = [:]
  ) throws -> URL {
    let url = sandbox.root.appendingPathComponent(relativePath, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let text = try sandbox.bundleText(name: name, description: "导入描述", extraLines: [], body: "\n# B\n")
    try text.write(to: url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    for (name, contents) in resources {
      try contents.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return url
  }

  func testImportDirectoryBundleIsRenamedAfterItsFrontmatter() throws {
    let sandbox = try makeSandbox()
    let source = try makeSourceBundle(
      sandbox,
      at: "incoming/My Skill (1)",
      name: "my-skill",
      resources: ["RECIPES.md": "# 配方\n"]
    )

    let record = try sandbox.center.importSkill(from: source, into: .user, workspace: sandbox.workspace)
    XCTAssertEqual(record.name, "my-skill")
    XCTAssertEqual(record.entryURL.path, sandbox.userSkills.appendingPathComponent("my-skill/SKILL.md").path)
    // The destination is named after the frontmatter, not after whatever the folder was
    // called — `My Skill (1)` must not become a skill's identity.
    XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.userSkills.appendingPathComponent("My Skill (1)").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.userSkills.appendingPathComponent("my-skill/RECIPES.md").path))
    XCTAssertNotNil(sandbox.skill(named: "my-skill"))
  }

  func testImportSingleMarkdownFile() throws {
    let sandbox = try makeSandbox()
    let source = try sandbox.writeFlat(
      in: sandbox.root.appendingPathComponent("incoming"),
      file: "prototype.md",
      name: "prototype"
    )
    let record = try sandbox.center.importSkill(from: source, into: .user, workspace: sandbox.workspace)
    XCTAssertEqual(record.form, .flat)
    XCTAssertEqual(record.entryURL.path, sandbox.userSkills.appendingPathComponent("prototype.md").path)
  }

  func testImportFromAnArchiveLikeLayoutWithOneTopLevelFolder() throws {
    let sandbox = try makeSandbox()
    let staging = sandbox.root.appendingPathComponent("unpacked", isDirectory: true)
    _ = try makeSourceBundle(sandbox, at: "unpacked/office-xlsx", name: "office-xlsx")

    let record = try sandbox.center.importSkill(from: staging, into: .user, workspace: sandbox.workspace)
    XCTAssertEqual(record.name, "office-xlsx")
    XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.userSkills.appendingPathComponent("office-xlsx/SKILL.md").path))
  }

  func testImportIntoTheProjectRoot() throws {
    let sandbox = try makeSandbox()
    let source = try makeSourceBundle(sandbox, at: "incoming/cro", name: "cro")
    let record = try sandbox.center.importSkill(from: source, into: .project, workspace: sandbox.workspace)
    XCTAssertEqual(
      record.entryURL.path,
      sandbox.projectSkills.appendingPathComponent("cro/SKILL.md").path
    )
  }

  func testImportRefusesASourceThatIsNotASkill() throws {
    let sandbox = try makeSandbox()
    let empty = sandbox.root.appendingPathComponent("incoming/empty", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    XCTAssertThrowsError(try sandbox.center.importSkill(from: empty, into: .user, workspace: sandbox.workspace)) {
      guard case .sourceNotSkill(_, let reason)? = $0 as? SkillCenterError else {
        return XCTFail("expected a source complaint, got \($0)")
      }
      XCTAssertTrue(reason.contains("SKILL.md"))
    }

    // Two candidate skills in one folder is ambiguous and refused rather than guessed.
    _ = try makeSourceBundle(sandbox, at: "incoming/many/one", name: "one")
    _ = try makeSourceBundle(sandbox, at: "incoming/many/two", name: "two")
    XCTAssertThrowsError(
      try sandbox.center.importSkill(
        from: sandbox.root.appendingPathComponent("incoming/many"),
        into: .user,
        workspace: sandbox.workspace
      )
    ) { error in
      guard case .sourceNotSkill(_, let reason)? = error as? SkillCenterError else {
        return XCTFail("expected a source complaint, got \(error)")
      }
      XCTAssertTrue(reason.contains("2"), reason)
    }

    // A file that exists but that the provider would ignore is not importable either.
    let broken = sandbox.root.appendingPathComponent("incoming/broken", isDirectory: true)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try "---\nname: broken\n---\n".write(
      to: broken.appendingPathComponent("SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
    XCTAssertThrowsError(try sandbox.center.importSkill(from: broken, into: .user, workspace: sandbox.workspace)) {
      guard case .sourceNotSkill(_, let reason)? = $0 as? SkillCenterError else {
        return XCTFail("expected a source complaint, got \($0)")
      }
      XCTAssertTrue(reason.contains("description"), reason)
    }
  }

  func testImportRefusesAnExistingName() throws {
    let sandbox = try makeSandbox()
    try sandbox.writeBundle(in: sandbox.userSkills, directory: "cro", name: "cro")
    let source = try makeSourceBundle(sandbox, at: "incoming/cro-incoming", name: "cro")
    XCTAssertThrowsError(try sandbox.center.importSkill(from: source, into: .user, workspace: sandbox.workspace)) {
      guard case .nameTaken(let name, _)? = $0 as? SkillCenterError else {
        return XCTFail("expected a taken name, got \($0)")
      }
      XCTAssertEqual(name, "cro")
    }
  }

  // MARK: - Archives

  func testArchiveCommandLines() throws {
    let sandbox = try makeSandbox()
    let stub = StubSkillRunner()
    stub.onRun = { destination in
      // Stand in for what `ditto` / `tar` would have written.
      let bundle = destination.appendingPathComponent("office-pptx", isDirectory: true)
      try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
      try "---\nname: office-pptx\ndescription: 包\n---\n\n# B\n".write(
        to: bundle.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
      )
    }
    let center = SkillCenter(dshHome: sandbox.dshHome, agentsHome: sandbox.agentsHome, runner: stub)

    let zip = sandbox.root.appendingPathComponent("incoming/office-pptx.zip")
    try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a real zip".utf8).write(to: zip)
    let record = try center.importSkill(from: zip, into: .user, workspace: sandbox.workspace)
    XCTAssertEqual(record.name, "office-pptx")
    XCTAssertEqual(stub.calls.count, 1)
    XCTAssertEqual(stub.calls[0].executable, "/usr/bin/ditto")
    XCTAssertEqual(stub.calls[0].arguments[0...1], ["-x", "-k"])
    XCTAssertEqual(stub.calls[0].arguments[2], zip.path)
    XCTAssertTrue(stub.calls[0].arguments[3].hasSuffix("/expanded"))

    let tarball = sandbox.root.appendingPathComponent("incoming/office-pptx.tgz")
    try Data("not a real tarball".utf8).write(to: tarball)
    _ = try center.importSkill(from: tarball, into: .project, workspace: sandbox.workspace)
    XCTAssertEqual(stub.calls.count, 2)
    XCTAssertEqual(stub.calls[1].executable, "/usr/bin/tar")
    XCTAssertEqual(stub.calls[1].arguments[0], "-xzf")
    XCTAssertEqual(stub.calls[1].arguments[1], tarball.path)
    XCTAssertEqual(stub.calls[1].arguments[2], "-C")
    XCTAssertTrue(stub.calls[1].arguments[3].hasSuffix("/expanded"))
  }

  func testArchiveFailureIsReportedWithTheCommandOutput() throws {
    let sandbox = try makeSandbox()
    let stub = StubSkillRunner()
    stub.status = 1
    stub.standardError = "ditto: Cannot extract"
    let center = SkillCenter(dshHome: sandbox.dshHome, agentsHome: sandbox.agentsHome, runner: stub)
    let zip = sandbox.root.appendingPathComponent("incoming/broken.zip")
    try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: zip)

    XCTAssertThrowsError(try center.importSkill(from: zip, into: .user, workspace: sandbox.workspace)) {
      guard case .commandFailed(let label, let status, let message)? = $0 as? SkillCenterError else {
        return XCTFail("expected a command failure, got \($0)")
      }
      XCTAssertTrue(label.contains("zip"))
      XCTAssertEqual(status, 1)
      XCTAssertTrue(message.contains("Cannot extract"))
    }
  }

  /// The end-to-end archive path with the real tools, because the command line above is only
  /// half of it: the expanded layout has to be found and copied too.
  func testRealZipRoundTrip() throws {
    let sandbox = try makeSandbox()
    let source = try makeSourceBundle(
      sandbox,
      at: "incoming/zip-source/office-docx",
      name: "office-docx",
      resources: ["REFERENCE.md": "# 参考\n"]
    )
    let zip = sandbox.root.appendingPathComponent("incoming/office-docx.zip")
    let runner = SystemSkillCommandRunner()
    let packed = try runner.run(
      executable: URL(fileURLWithPath: "/usr/bin/ditto"),
      arguments: ["-c", "-k", "--keepParent", source.path, zip.path],
      currentDirectory: nil
    )
    XCTAssertEqual(packed.status, 0, packed.standardError)

    let record = try sandbox.center.importSkill(from: zip, into: .user, workspace: sandbox.workspace)
    XCTAssertEqual(record.name, "office-docx")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: sandbox.userSkills.appendingPathComponent("office-docx/REFERENCE.md").path)
    )
  }
}
