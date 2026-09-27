import XCTest

@testable import HarnessKit
@testable import HarnessRuntime

/// Switching skins: what the profile's `cordis.patch.yml` has to end up saying, and what
/// must survive the rewrite untouched.
final class SkinManagerTests: XCTestCase {
  private let managedStart = SkinManagedBlock.start
  private let managedEnd = SkinManagedBlock.end

  /// A profile with both kinds of skin: one the manager has to insert, one its bundle
  /// already wires.
  private func makeTwoSkinProfile() throws -> (root: URL, profile: URL, standalone: Skin, wired: Skin) {
    let (root, profile) = try SkinFixtures.makeProfile(self, bundles: ["@yunxii/maid-whale"])
    let (standalone, wired) = try SkinFixtures.installTwoSkins(profile)
    XCTAssertFalse(standalone.isBundleWired)
    XCTAssertTrue(wired.isBundleWired)
    return (root, profile, standalone, wired)
  }

  private func activeID(_ root: URL, _ profile: URL) -> String? {
    let manager = SkinFixtures.manager(root)
    return manager.activeSkinID(profile: "web", in: manager.skins(profile: "web"))
  }

  // MARK: - Rendering the managed block

  func testSwitchingInsertsTheActiveSkinAndDisablesEveryOtherOne() throws {
    let (root, profile, standalone, _) = try makeTwoSkinProfile()
    let report = try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")

    XCTAssertEqual(report.active?.id, standalone.id)
    XCTAssertTrue(report.patchChanged)
    XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")
    XCTAssertEqual(
      try SkinFixtures.readPatch(profile),
      """
      \(managedStart)
      - id: ui-skin-maid-whale-webui
        disabled: true
      - insert:
          - id: ui-skin-deep-whale-day-night
            name: '@dsh-external/deep-whale'
      \(managedEnd)\n
      """
    )
    XCTAssertEqual(activeID(root, profile), standalone.id)
  }

  func testOfficialLookDisablesEverySkinAndInsertsNothing() throws {
    let (root, profile, standalone, _) = try makeTwoSkinProfile()
    try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")

    let report = try SkinFixtures.manager(root).switchTo(nil, profile: "web")
    XCTAssertNil(report.active)
    XCTAssertNil(activeID(root, profile))
    let patch = try SkinFixtures.readPatch(profile)
    XCTAssertFalse(patch.contains("- insert:"))
    XCTAssertTrue(patch.contains("- id: ui-skin-deep-whale-day-night\n  disabled: true"))
    XCTAssertTrue(patch.contains("- id: ui-skin-maid-whale-webui\n  disabled: true"))
  }

  /// The row already exists in the bundle layer, so writing a second one here would compose
  /// the loader entry twice.
  func testBundleWiredSkinGetsNoInsertRow() throws {
    let (root, profile, _, wired) = try makeTwoSkinProfile()
    try SkinFixtures.manager(root).switchTo(wired.id, profile: "web")

    let patch = try SkinFixtures.readPatch(profile)
    XCTAssertFalse(patch.contains("- insert:"), patch)
    XCTAssertFalse(patch.contains("ui-skin-maid-whale-webui\n  disabled"), patch)
    XCTAssertTrue(patch.contains("- id: ui-skin-deep-whale-day-night\n  disabled: true"), patch)
    XCTAssertEqual(activeID(root, profile), wired.id)
  }

  func testSwitchingReplacesThePreviousManagedBlockRatherThanAppending() throws {
    let (root, profile, standalone, wired) = try makeTwoSkinProfile()
    let manager = SkinFixtures.manager(root)
    try manager.switchTo(standalone.id, profile: "web")
    try manager.switchTo(wired.id, profile: "web")

    let patch = try SkinFixtures.readPatch(profile)
    XCTAssertEqual(patch.components(separatedBy: managedStart).count - 1, 1, "one managed block, not two")
    XCTAssertEqual(patch.components(separatedBy: managedEnd).count - 1, 1)
    XCTAssertFalse(patch.contains("- insert:"))
    XCTAssertEqual(activeID(root, profile), wired.id)
  }

  // MARK: - Adopting a profile the plugin used to own

  /// This machine's profile, exactly: the markers were lost and the target's disable rows
  /// were left behind three times over. Untouched, they would keep the skin the user just
  /// applied switched off.
  func testSwitchingRemovesStaleDuplicateDisableRows() throws {
    let (root, profile, standalone, _) = try makeTwoSkinProfile()
    try SkinFixtures.writePatch(
      """
      - id: ui-skin-deep-whale-day-night
        disabled: true
      - id: ui-skin-deep-whale-day-night
        disabled: true
      - id: ui-skin-deep-whale-day-night
        disabled: true
      - id: dshmarket
        disabled: true
      """,
      to: profile
    )

    try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")

    let patch = try SkinFixtures.readPatch(profile)
    XCTAssertEqual(patch.components(separatedBy: "- id: ui-skin-deep-whale-day-night").count - 1, 1)
    XCTAssertTrue(patch.contains("- insert:"))
    XCTAssertEqual(activeID(root, profile), standalone.id)
  }

  /// A row an earlier version of the manager wrote by hand, with no markers around it.
  func testSwitchingRemovesALegacyHandWrittenInsertRow() throws {
    let (root, profile, standalone, wired) = try makeTwoSkinProfile()
    try SkinFixtures.writePatch(
      """
      # imported from another profile
      - insert:
          - id: ui-skin-maid-whale-webui
            name: '@yunxii/maid-whale'
            config:
              enabled: true
              scale: 0.65
      - id: univer
        disabled: false
      """,
      to: profile
    )

    try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")

    let patch = try SkinFixtures.readPatch(profile)
    // A skin-owned insert block goes whole, config and all: leaving it would compose the
    // skin twice, and the manager is the owner of skin rows.
    XCTAssertFalse(patch.contains("scale: 0.65"), patch)
    XCTAssertTrue(patch.contains("- id: univer\n  disabled: false"), "unrelated rows survive")
    XCTAssertTrue(patch.contains("name: '@dsh-external/deep-whale'"))
  }

  /// Rows that are nobody's skin are other tools' business, and must come through byte for
  /// byte — including another tool's comments.
  func testUnrelatedPatchRowsAndCommentsSurvive() throws {
    let (root, profile, standalone, _) = try makeTwoSkinProfile()
    try SkinFixtures.writePatch(
      """
      # Your patch layer for this dsh profile.
      - id: ui-settings-general
        name: "@deepseek-ai/dsh-client-ui-settings-general"
        config:
          welcomeNoticeVersion: 2026-08-13.1
      - id: dshmarket
        disabled: true
      """,
      to: profile
    )

    try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")

    let patch = try SkinFixtures.readPatch(profile)
    XCTAssertTrue(patch.contains("# Your patch layer for this dsh profile."))
    XCTAssertTrue(patch.contains("welcomeNoticeVersion: 2026-08-13.1"))
    XCTAssertTrue(patch.contains("- id: dshmarket\n  disabled: true"))
  }

  /// A skin row carrying configuration is somebody's tuning. It is kept and reported rather
  /// than deleted to make the switch tidy.
  func testConfigCarryingSkinRowIsPreservedAndReported() throws {
    let (root, profile, standalone, _) = try makeTwoSkinProfile()
    try SkinFixtures.writePatch(
      """
      - id: ui-skin-maid-whale-webui
        config:
          scale: 0.9
      """,
      to: profile
    )

    let report = try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")
    XCTAssertTrue(
      report.warnings.contains { $0.contains("hand-written patch row") },
      "\(report.warnings)"
    )
    XCTAssertTrue(try SkinFixtures.readPatch(profile).contains("scale: 0.9"))
  }

  func testSwitchingDropsAByteOrderMark() throws {
    let (root, profile, standalone, _) = try makeTwoSkinProfile()
    try SkinFixtures.writePatch("\u{FEFF}- id: dshmarket\n  disabled: true\n", to: profile)
    try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")
    XCTAssertFalse(try SkinFixtures.readPatch(profile).hasPrefix("\u{FEFF}"))
  }

  // MARK: - Refusals and no-ops

  func testSwitchingToAnUninstalledSkinThrows() throws {
    let (root, _, _, _) = try makeTwoSkinProfile()
    XCTAssertThrowsError(try SkinFixtures.manager(root).switchTo("not-installed", profile: "web")) { error in
      guard case RuntimeError.unsupported(let detail) = error else {
        return XCTFail("expected .unsupported, got \(error)")
      }
      XCTAssertTrue(detail.contains("not-installed"), detail)
    }
  }

  /// Applying the skin that is already on must not touch the file: the harness reloads its
  /// plugin tree whenever the patch changes, and a no-op rewrite would reload it for nothing.
  func testReapplyingTheSameSkinLeavesTheFileAlone() throws {
    let (root, profile, standalone, _) = try makeTwoSkinProfile()
    let manager = SkinFixtures.manager(root)
    try manager.switchTo(standalone.id, profile: "web")
    let first = try SkinFixtures.readPatch(profile)

    let report = try manager.switchTo(standalone.id, profile: "web")
    XCTAssertFalse(report.patchChanged)
    XCTAssertEqual(try SkinFixtures.readPatch(profile), first)
  }

  /// The id survives a round trip through a fresh manager, which is what the window does on
  /// every refresh.
  func testActiveSkinIDReadsTheInsertRowAndSkipsDisabledOnes() throws {
    let (root, profile, standalone, wired) = try makeTwoSkinProfile()
    // Nothing has been switched yet, and the bundle-wired skin is composed by its own bundle
    // layer — so that one, not the official look, is what is on.
    XCTAssertEqual(activeID(root, profile), wired.id)

    try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")
    XCTAssertEqual(activeID(root, profile), standalone.id)

    try SkinFixtures.manager(root).switchTo(nil, profile: "web")
    XCTAssertNil(activeID(root, profile))
  }

  /// A skin wired by the profile's bundle layer, with no managed block at all, is still on —
  /// that is what `bundleWired` means, and reporting it as "official look" would offer the
  /// user a switch they do not need.
  func testActiveSkinIDFindsABundleWiredSkinWithNoManagedBlock() throws {
    let (root, profile) = try SkinFixtures.makeProfile(self, bundles: ["@alpha/one"])
    let directory = try SkinFixtures.installDeclared("@alpha/one", into: profile, id: "one", rowID: "ui-skin-one")
    try TestSupport.write(
      "- insert:\n    - id: ui-skin-one\n      name: '@alpha/one'\n",
      to: directory.appendingPathComponent("cordis.patch.yml")
    )
    XCTAssertEqual(activeID(root, profile), "one")
  }

  func testActiveSkinIDIgnoresADisabledBundleWiredSkin() throws {
    let (root, profile) = try SkinFixtures.makeProfile(self, bundles: ["@alpha/one"])
    let directory = try SkinFixtures.installDeclared("@alpha/one", into: profile, id: "one", rowID: "ui-skin-one")
    try TestSupport.write(
      "- insert:\n    - id: ui-skin-one\n      name: '@alpha/one'\n",
      to: directory.appendingPathComponent("cordis.patch.yml")
    )
    try SkinFixtures.writePatch("- id: ui-skin-one\n  disabled: true\n", to: profile)
    XCTAssertNil(activeID(root, profile))
  }

  // MARK: - Nested skins

  /// A skin discovered inside an aggregate package is not resolvable from `node_modules`,
  /// and the loader imports it by bare specifier — so switching to it has to make it
  /// resolvable first.
  func testSwitchingToANestedSkinLinksItIntoNodeModules() throws {
    let (root, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.install(
      "@linxin666/dsh-skins",
      into: profile,
      manifest: ["dsh": ["bundle": ["patch": "./cordis.patch.yml"]]],
      patch: "- insert:\n    - id: ui-skin-aggregate\n      name: '@linxin666/dsh-skins'\n"
    )
    let nested = try SkinFixtures.installDeclared(
      "@linxin666/dsh-skins/skins/aurora",
      into: profile,
      id: "aurora",
      declaresPackage: false
    )

    let manager = SkinFixtures.manager(root)
    let skins = manager.skins(profile: "web")
    XCTAssertEqual(skins.map(\.id), ["aurora"])
    try manager.switchTo("aurora", profile: "web")

    let link = SkinFixtures.packageDirectory(profile, "aurora")
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    XCTAssertEqual(
      URL(fileURLWithPath: destination).standardizedFileURL,
      nested.standardizedFileURL
    )
    XCTAssertTrue(try SkinFixtures.readPatch(profile).contains("name: 'aurora'"))
  }

  // MARK: - The market's parallel state

  /// The market keeps its own opinion and acts on it at boot, so a switch that ignored it
  /// would be undone a moment later. Only that one key may move.
  func testMarketDisabledListIsBroughtIntoLineAndOtherKeysSurvive() throws {
    let (root, profile, standalone, wired) = try makeTwoSkinProfile()
    let stateURL = profile.appendingPathComponent(".dsh-market/state.json")
    try TestSupport.write(
      """
      {"disabled":["other-plugin"],"groups":{"g":["a"]},"region":"china","regionAuto":true}
      """,
      to: stateURL
    )

    let report = try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")
    XCTAssertTrue(report.marketStateUpdated)

    let state = try XCTUnwrap(
      try JSONValue.parse(try Data(contentsOf: stateURL), context: "state.json").objectValue
    )
    XCTAssertEqual(
      state["disabled"]?.arrayValue?.compactMap(\.stringValue),
      ["@yunxii/maid-whale", "other-plugin"]
    )
    XCTAssertEqual(state["groups"]?.objectValue?["g"]?.arrayValue?.compactMap(\.stringValue), ["a"])
    XCTAssertEqual(state["region"]?.stringValue, "china")
    XCTAssertEqual(state["regionAuto"]?.boolValue, true)

    // …and switching away puts the other skin back in the market's enabled set.
    try SkinFixtures.manager(root).switchTo(wired.id, profile: "web")
    let updated = try XCTUnwrap(
      try JSONValue.parse(try Data(contentsOf: stateURL), context: "state.json").objectValue
    )
    XCTAssertEqual(
      updated["disabled"]?.arrayValue?.compactMap(\.stringValue),
      ["@dsh-external/deep-whale", "other-plugin"]
    )
  }

  func testProfileWithoutAMarketLeavesNoStateFileBehind() throws {
    let (root, profile, standalone, _) = try makeTwoSkinProfile()
    let report = try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")
    XCTAssertFalse(report.marketStateUpdated)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: profile.appendingPathComponent(".dsh-market").path)
    )
  }

  /// A state file the market wrote before #60 carries the theme-only key; it still has to be
  /// read, or every skin it lists would look enabled.
  func testLegacyMarketDisabledKeyIsRead() throws {
    let (root, profile, standalone, _) = try makeTwoSkinProfile()
    let stateURL = profile.appendingPathComponent(".dsh-market/state.json")
    try TestSupport.write(
      "{\"disabledSkins\":[\"@yunxii/maid-whale\",\"kept\"]}",
      to: stateURL
    )
    try SkinFixtures.manager(root).switchTo(standalone.id, profile: "web")

    let state = try XCTUnwrap(
      try JSONValue.parse(try Data(contentsOf: stateURL), context: "state.json").objectValue
    )
    XCTAssertEqual(
      state["disabled"]?.arrayValue?.compactMap(\.stringValue),
      ["@yunxii/maid-whale", "kept"]
    )
    XCTAssertNil(state["disabledSkins"], "the stale key must not be left as a second answer")
  }
}
