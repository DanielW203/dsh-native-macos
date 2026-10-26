import Foundation
import XCTest

@testable import HarnessSkills

/// The frontmatter reader and writer, checked against the rules the official provider and the
/// Web plugin's skill centre enforce.
///
/// The fixtures are the shapes real SKILL.md files use, including the ones that make the
/// official provider drop a file without saying so.
final class SkillFrontmatterTests: XCTestCase {
  // MARK: - Reading

  func testReadsNameDescriptionAndBooleans() {
    let raw = """
      ---
      name: pick-ui-library
      description: "从清单里挑库"
      whenToUse: 需要挑库时
      disable-model-invocation: true
      user-invocable: false
      ---

      # Body
      """

    guard case .loaded(let metadata) = SkillFrontmatter.read(raw) else {
      return XCTFail("expected the fixture to load")
    }
    XCTAssertEqual(metadata.name, "pick-ui-library")
    XCTAssertEqual(metadata.description, "从清单里挑库")
    XCTAssertEqual(metadata.whenToUse, "需要挑库时")
    XCTAssertFalse(metadata.modelInvocable)
    XCTAssertFalse(metadata.userInvocable)
  }

  func testDefaultsAreInvocableWhenTheKeysAreAbsent() {
    let raw = "---\nname: animate\ndescription: x\n---\n\nbody\n"
    guard case .loaded(let metadata) = SkillFrontmatter.read(raw) else {
      return XCTFail("expected the fixture to load")
    }
    XCTAssertTrue(metadata.modelInvocable)
    XCTAssertTrue(metadata.userInvocable)
  }

  /// Every literal the official `frontmatterBoolean` accepts, in both spellings.
  func testBooleanLiterals() {
    let accepted = ["true": true, "yes": true, "on": true, "1": true,
                    "false": false, "no": false, "off": false, "0": false]
    for (literal, expected) in accepted {
      let raw = "---\nname: x\ndescription: d\ndisable-model-invocation: \(literal)\n---\n"
      guard case .loaded(let metadata) = SkillFrontmatter.read(raw) else {
        return XCTFail("expected \(literal) to be a boolean")
      }
      XCTAssertEqual(metadata.modelInvocable, !expected, "literal \(literal)")
    }
    // Case-insensitive, as the official parser is.
    let raw = "---\nname: x\ndescription: d\nuser-invocable: FALSE\n---\n"
    guard case .loaded(let metadata) = SkillFrontmatter.read(raw) else {
      return XCTFail("expected FALSE to be a boolean")
    }
    XCTAssertFalse(metadata.userInvocable)
  }

  func testEmptyBooleanValueIsInvalid() {
    // YAML parses `key:` as null, and the official parser throws on null rather than
    // treating it as false.
    let raw = "---\nname: x\ndescription: d\ndisable-model-invocation:\n---\n"
    guard case .issue(let issue) = SkillFrontmatter.read(raw) else {
      return XCTFail("expected an issue")
    }
    XCTAssertEqual(issue, .invalidBoolean("disable-model-invocation"))
  }

  func testLegacyKeysAreRejected() {
    for legacy in ["disableModelInvocation", "modelInvocable", "userInvocable"] {
      let raw = "---\nname: x\ndescription: d\n\(legacy): true\n---\n"
      guard case .issue(let issue) = SkillFrontmatter.read(raw) else {
        return XCTFail("expected \(legacy) to be rejected")
      }
      XCTAssertEqual(issue, .legacyKey(legacy))
    }
  }

  func testMissingFrontmatterAndMissingFields() {
    XCTAssertEqual(
      SkillFrontmatter.read("# no frontmatter\n"),
      .issue(.missingFrontmatter)
    )
    XCTAssertEqual(
      SkillFrontmatter.read("---\nname: x\n---\n"),
      .issue(.missingDescription)
    )
    XCTAssertEqual(
      SkillFrontmatter.read("---\ndescription: d\n---\n"),
      .issue(.missingName)
    )
  }

  func testNameGrammarMatchesTheOfficialPattern() {
    XCTAssertTrue(SkillFrontmatter.isSkillName("animate"))
    XCTAssertTrue(SkillFrontmatter.isSkillName("li-writer"))
    XCTAssertTrue(SkillFrontmatter.isSkillName("a1-b2"))
    XCTAssertFalse(SkillFrontmatter.isSkillName("Animate"))
    XCTAssertFalse(SkillFrontmatter.isSkillName("animate-"))
    XCTAssertFalse(SkillFrontmatter.isSkillName("-animate"))
    XCTAssertFalse(SkillFrontmatter.isSkillName("animate--expo"))
    XCTAssertFalse(SkillFrontmatter.isSkillName("animate_expo"))
    XCTAssertFalse(SkillFrontmatter.isSkillName(""))
  }

  func testBlockScalarAndQuoting() {
    let raw = """
      ---
      name: x
      description: >
        第一行
        第二行
      whenToUse: 'it''s here'
      ---
      """
    guard case .loaded(let metadata) = SkillFrontmatter.read(raw) else {
      return XCTFail("expected the fixture to load")
    }
    XCTAssertEqual(metadata.description, "第一行 第二行")
    XCTAssertEqual(metadata.whenToUse, "it''s here".replacingOccurrences(of: "''", with: "'"))
  }

  func testSequenceFrontmatterIsNotAMapping() {
    XCTAssertEqual(
      SkillFrontmatter.read("---\n- a\n- b\n---\n"),
      .issue(.notAMapping)
    )
  }

  // MARK: - Writing

  func testSettingReplacesTheLineAndKeepsEverythingElse() {
    let raw = "---\nname: x\ndescription: d\n---\n\nBody line 1\nBody line 2\n"
    let updated = try? SkillFrontmatter.setting("disable-model-invocation", to: true, in: raw)
    XCTAssertEqual(
      updated,
      "---\nname: x\ndescription: d\ndisable-model-invocation: true\n---\n\nBody line 1\nBody line 2\n"
    )
  }

  func testSettingAppendsWhenAbsentAndIsIdempotent() throws {
    let raw = "---\nname: x\ndescription: d\n---\nbody\n"
    let once = try SkillFrontmatter.setting("user-invocable", to: false, in: raw)
    let twice = try SkillFrontmatter.setting("user-invocable", to: false, in: once)
    XCTAssertEqual(once, twice)
    XCTAssertEqual(once, "---\nname: x\ndescription: d\nuser-invocable: false\n---\nbody\n")
  }

  func testSettingWithoutFrontmatterThrows() {
    XCTAssertThrowsError(try SkillFrontmatter.setting("user-invocable", to: false, in: "no frontmatter")) {
      XCTAssertEqual($0 as? SkillCenterError, .missingFrontmatter("SKILL.md"))
    }
  }

  /// A CRLF file keeps its body line endings and normalizes the block, exactly as the Web
  /// plugin's line-level rewrite does.
  func testSettingNormalizesFrontmatterLineEndingsOnly() throws {
    let raw = "---\r\nname: x\r\ndescription: d\r\n---\r\nbody\r\n"
    let updated = try SkillFrontmatter.setting("disable-model-invocation", to: false, in: raw)
    XCTAssertEqual(updated, "---\nname: x\ndescription: d\ndisable-model-invocation: false\n---\r\nbody\r\n")
  }

  func testCreateTemplateMatchesTheWebPlugin() {
    let text = SkillFrontmatter.created(
      name: "my-skill",
      description: "一个'技能'",
      whenToUse: "需要时",
      content: "  # 标题\n\n正文  "
    )
    XCTAssertEqual(
      text,
      """
      ---
      name: my-skill
      description: '一个''技能'''
      whenToUse: '需要时'
      ---

      # 标题

      正文

      """
    )
  }

  func testCreateTemplateOmitsEmptyWhenToUse() {
    let text = SkillFrontmatter.created(name: "x", description: "d", whenToUse: "  ", content: "c")
    XCTAssertFalse(text.contains("whenToUse"))
    // The template round-trips through the reader.
    guard case .loaded(let metadata) = SkillFrontmatter.read(text) else {
      return XCTFail("template must be readable")
    }
    XCTAssertEqual(metadata.name, "x")
    XCTAssertEqual(metadata.description, "d")
  }
}
