import XCTest
@testable import HarnessRuntime

final class CordisPatchEditorTests: XCTestCase {
  /// The exact shape this machine's profile carries: a commented, tool-managed block.
  private let managedProfile = """
    # Your patch layer for this dsh profile, applied after every bundle layer:
    # a top-level YAML array of loader patch entries (id-targeted config
    # overrides, disables, and insert lists; !!js expressions allowed).

    # --- dsh-skin-manager managed (auto-generated; do not edit) ---
    - id: ui-skin-deep-whale-day-night
      disabled: true
    - id: dsh-skin-market
      disabled: true
    # --- end dsh-skin-manager managed ---
    """

  func testParsesIDAndLiteralDisable() {
    guard case .entries(let entries) = CordisPatchEditor.parse(managedProfile) else {
      return XCTFail("expected a block-style array")
    }
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].id, "ui-skin-deep-whale-day-night")
    XCTAssertTrue(entries[0].isDisabled)
    XCTAssertFalse(entries[0].isConditionalDisable)
    XCTAssertEqual(entries[1].id, "dsh-skin-market")
  }

  func testDisabledTargetsCollectsKeysAndValues() {
    let targets = CordisPatchEditor.disabledTargets(managedProfile)
    XCTAssertTrue(targets.contains("dsh-skin-market"))
    XCTAssertTrue(targets.contains("id"))
    XCTAssertTrue(CordisPatchEditor.hasDisable(managedProfile, named: ["dsh-skin-market"]))
    XCTAssertFalse(CordisPatchEditor.hasDisable(managedProfile, named: ["dsh-memoir"]))
  }

  func testExpressionDisableIsConditionalNotDisabled() {
    // The shipped desktop patch uses this form. Counting it as disabled would make the
    // UI offer to enable something that is not disabled on this platform.
    let text = """
      - insert:
          - id: desktop-terminal
            name: dsh-plugin-desktop/terminal
            disabled: !!js process.platform === 'linux'
      """
    guard case .entries(let entries) = CordisPatchEditor.parse(text) else {
      return XCTFail("expected entries")
    }
    XCTAssertEqual(entries.count, 1)
    XCTAssertFalse(entries[0].isDisabled)
    XCTAssertTrue(entries[0].isConditionalDisable)
    XCTAssertTrue(CordisPatchEditor.disabledTargets(text).isEmpty)
    XCTAssertTrue(CordisPatchEditor.hasConditionalDisable(text, named: ["dsh-plugin-desktop/terminal"]))
  }

  func testStrippingAPureDisableEntryRemovesItEntirely() throws {
    let result = try XCTUnwrap(CordisPatchEditor.stripDisable(managedProfile, named: ["dsh-skin-market"]))
    XCTAssertFalse(result.contains("dsh-skin-market"))
    // The other entry is untouched...
    XCTAssertTrue(result.contains("ui-skin-deep-whale-day-night"))
    // ...and so is every comment the other tool wrote.
    XCTAssertTrue(result.contains("# --- dsh-skin-manager managed (auto-generated; do not edit) ---"))
    XCTAssertTrue(result.contains("# --- end dsh-skin-manager managed ---"))
    XCTAssertTrue(result.contains("# Your patch layer for this dsh profile"))
  }

  func testStrippingKeepsTheOtherBackslashConfigurationOfAMixedEntry() throws {
    let text = """
      # a comment
      - id: my-plugin
        disabled: true
        config:
          port: 3080
      - id: other
        disabled: true
      """
    let result = try XCTUnwrap(CordisPatchEditor.stripDisable(text, named: ["my-plugin"]))
    // Exactly one §disabled§ remains, and it belongs to the unrelated entry.
    XCTAssertEqual(result.components(separatedBy: "disabled").count - 1, 1)
    XCTAssertTrue(result.contains("config:"))
    XCTAssertTrue(result.contains("port: 3080"))
    XCTAssertTrue(result.contains("- id: my-plugin"))
    // The unrelated entry survives.
    XCTAssertTrue(result.contains("- id: other"))
  }

  func testStrippingIsIdempotentAndReportsNoMatch() throws {
    XCTAssertNil(try CordisPatchEditor.stripDisable(managedProfile, named: ["not-present"]))
    let once = try XCTUnwrap(CordisPatchEditor.stripDisable(managedProfile, named: ["dsh-skin-market"]))
    XCTAssertNil(try CordisPatchEditor.stripDisable(once, named: ["dsh-skin-market"]))
  }

  func testFinalNewlineIsNeitherAddedNorRemoved() throws {
    // The contract is "do not change it", not "it must be present": a file that ends
    // without one must still end without one after an edit.
    for text in [managedProfile, managedProfile + "\n"] {
      let result = try XCTUnwrap(CordisPatchEditor.stripDisable(text, named: ["dsh-skin-market"]))
      XCTAssertEqual(result.hasSuffix("\n"), text.hasSuffix("\n"), "the edit changed the final newline")
      XCTAssertFalse(result.hasSuffix("\n\n"), "the edit added a blank line")
    }
  }

  func testFlowStyleIsRefusedRatherThanGuessedAt() throws {
    let text = "- {id: my-plugin, disabled: true}\n"
    guard case .unsupported = CordisPatchEditor.parse(text) else {
      return XCTFail("flow style must be reported as unsupported")
    }
    XCTAssertThrowsError(try CordisPatchEditor.stripDisable(text, named: ["my-plugin"])) { error in
      XCTAssertEqual(error as? CordisPatchEditor.EditError, .unsupported("entry on line 1 uses flow style"))
    }
  }

  func testDisabledFalseIsNotTreatedAsDisabled() {
    let text = """
      - id: my-plugin
        disabled: false
      """
    XCTAssertTrue(CordisPatchEditor.disabledTargets(text).isEmpty)
    XCTAssertNil(try? CordisPatchEditor.stripDisable(text, named: ["my-plugin"]))
  }

  func testInlineCommentAfterDisabledIsIgnored() {
    let text = """
      - id: my-plugin
        disabled: true # turned off while debugging
      """
    XCTAssertTrue(CordisPatchEditor.hasDisable(text, named: ["my-plugin"]))
  }

  func testEmptyOrCommentOnlyFileHasNoEntries() {
    for text in ["", "\n", "# just a comment\n", "\n\n"] {
      guard case .entries(let entries) = CordisPatchEditor.parse(text) else {
        return XCTFail("expected entries for \(text.debugDescription)")
      }
      XCTAssertTrue(entries.isEmpty)
    }
  }

  // MARK: - Merging another profile's entries

  func testBlocksCarryEntriesVerbatimWithTheirIndentedLines() {
    let text = """
      # a comment that belongs to the file
      - id: first
        disabled: true
        config:
          nested: value

      - id: second
        disabled: !!js process.platform === 'linux'
      """
    let blocks = CordisPatchEditor.blocks(text)
    XCTAssertEqual(blocks.map(\.id), ["first", "second"])
    XCTAssertEqual(blocks[0].lines.count, 4, "the indented config belongs to the entry above it")
    XCTAssertTrue(blocks[0].text.contains("nested: value"))
    XCTAssertFalse(blocks[0].text.contains("# a comment"))
  }

  func testMergingAppendsOnceAndIsIdempotent() throws {
    let template = "# Your patch layer for this dsh profile\n[]\n"
    let source = """
      - id: dsh-skin-market
        disabled: true
      """
    let first = try XCTUnwrap(CordisPatchEditor.mergeEntries(source, into: template, marker: "# --- imported ---"))
    XCTAssertEqual(first.appended, ["dsh-skin-market"])
    XCTAssertTrue(first.text.contains("# Your patch layer for this dsh profile"))
    XCTAssertTrue(first.text.contains("# --- imported ---"))
    XCTAssertTrue(first.text.hasSuffix("\n"))

    XCTAssertNil(
      try CordisPatchEditor.mergeEntries(source, into: first.text, marker: "# --- imported ---"),
      "merging the same entry twice must report no change"
    )
  }

  func testMergingIntoTheShippedTemplateReplacesItsEmptyArray() throws {
    let template = """
      # Your patch layer for this dsh profile, applied after every bundle layer:
      # a top-level YAML array of loader patch entries.
      []
      """
    let source = "- id: dsh-skin-market\n  disabled: true\n"
    let result = try XCTUnwrap(CordisPatchEditor.mergeEntries(source, into: template, marker: "# --- imported ---"))

    XCTAssertTrue(result.text.contains("# Your patch layer for this dsh profile"))
    XCTAssertTrue(result.text.contains("id: dsh-skin-market"))
    XCTAssertFalse(result.text.contains("[]"), "a block sequence below an empty array is not parseable")
    // What the merge produces has to be a document the harness can read, and the only way to
    // be sure of that here is that a second merge finds the entry already present.
    XCTAssertNil(try CordisPatchEditor.mergeEntries(source, into: result.text, marker: "# --- imported ---"))
  }

  func testMergingRepairsAnArrayLeftAboveEntries() throws {
    // The exact shape a merge into the shipped template produced before this rule existed.
    let broken = "# comment\n[]\n\n# --- imported ---\n- id: dsh-skin-market\n  disabled: true\n"
    let result = try XCTUnwrap(
      CordisPatchEditor.mergeEntries("- id: dsh-skin-market\n  disabled: true\n", into: broken)
    )
    XCTAssertTrue(result.repaired)
    XCTAssertEqual(result.text, "# comment\n\n# --- imported ---\n- id: dsh-skin-market\n  disabled: true\n")
  }

  func testMergingRefusesANonEmptyFlowArray() {
    XCTAssertThrowsError(
      try CordisPatchEditor.mergeEntries("- id: other\n  disabled: true\n", into: "[{id: x}]\n")
    )
  }

  func testMergingReplacesAnEntryWithTheSameID() throws {
    let destination = "# managed\n- id: dsh-skin-market\n  disabled: false\n"
    let source = "- id: dsh-skin-market\n  disabled: true\n"
    let result = try XCTUnwrap(CordisPatchEditor.mergeEntries(source, into: destination))
    XCTAssertEqual(result.replaced, ["dsh-skin-market"])
    XCTAssertTrue(result.appended.isEmpty)
    XCTAssertEqual(result.text, "# managed\n- id: dsh-skin-market\n  disabled: true\n")
  }

  func testMergingKeepsFlowStyleRefused() {
    XCTAssertThrowsError(
      try CordisPatchEditor.mergeEntries("- id: other\n  disabled: true\n", into: "- {id: x, disabled: true}\n")
    ) { error in
      XCTAssertEqual(error as? CordisPatchEditor.EditError, .unsupported("entry on line 1 uses flow style"))
    }
  }

  func testMergingFromAnEmptySourceIsANoOp() {
    XCTAssertNil(try? CordisPatchEditor.mergeEntries("", into: "# nothing here\n[]\n"))
  }

  func testAllowedBuildNamesReadsBothSpellings() {
    let text = """
      packages:
        - .

      nodeLinker: hoisted
      onlyBuiltDependencies:
        - esbuild
        - koffi
      allowBuilds:
        koffi: true
        sharp: true
      """
    XCTAssertEqual(PnpmWorkspaceEditor.allowedBuildNames(in: text), ["esbuild", "koffi", "sharp"])
  }
}
