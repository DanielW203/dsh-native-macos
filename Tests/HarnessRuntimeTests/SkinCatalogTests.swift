import XCTest

@testable import HarnessRuntime

/// Discovery, exercised against synthetic profiles — see `SkinFixtures`.
final class SkinCatalogTests: XCTestCase {
  private func catalog(_ profile: URL) -> SkinCatalog {
    SkinCatalog(profileDirectory: profile)
  }

  // MARK: - Scopes

  /// The regression this whole implementation exists for: the plugin it replaces probed
  /// `node_modules/@`, which does not exist, and so never saw a skin outside the one scope
  /// it hard-coded.
  func testDiscoversSkinsInEveryScopeAndAtTopLevel() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.installDeclared("@alpha/one", into: profile, id: "one", order: 1)
    try SkinFixtures.installDeclared("@beta/two", into: profile, id: "two", order: 2)
    try SkinFixtures.installDeclared("@dsh-external/three", into: profile, id: "three", order: 3)
    try SkinFixtures.installDeclared("plain-skin", into: profile, id: "four", order: 4)

    let found = catalog(profile).skins()
    XCTAssertEqual(found.map(\.id), ["one", "two", "three", "four"])
    XCTAssertEqual(
      found.map(\.package),
      ["@alpha/one", "@beta/two", "@dsh-external/three", "plain-skin"]
    )
  }

  // MARK: - What is not a skin

  func testIgnoresPackageWithoutClientBundle() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.installDeclared("@alpha/nobundle", into: profile, id: "nobundle")
    try FileManager.default.removeItem(
      at: SkinFixtures.packageDirectory(profile, "@alpha/nobundle").appendingPathComponent("lib")
    )
    XCTAssertTrue(catalog(profile).skins().isEmpty)
  }

  /// A registry file the author wrote but that cannot be read is not a reason to guess at the
  /// package from its name — the author declared a skin, and the honest answer is none.
  func testIgnoresSkinManifestThatCannotBeRead() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    let directory = try SkinFixtures.install("@alpha/broken", into: profile)
    try TestSupport.write("{ not json", to: directory.appendingPathComponent("skin.json"))
    XCTAssertTrue(catalog(profile).skins().isEmpty)
  }

  /// The bug that made the replaced plugin disable the market on every switch: a skin
  /// *manager* matches the theme convention by name, so the exclusion list is what keeps it
  /// out of the managed block.
  func testKnownManagersAreNeverListedAsSkins() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.install(
      "dsh-skin-market",
      into: profile,
      manifest: [
        "description": "Native skin marketplace and lifecycle manager",
        "dsh": [
          "client": ["platform": "web"],
          "bundle": ["patch": "./cordis.patch.yml"],
        ],
      ],
      patch: "- insert:\n    - id: dsh-skin-market\n      name: dsh-skin-market\n"
    )
    XCTAssertTrue(catalog(profile).skins().isEmpty)
  }

  /// A market theme: no `skin.json`, but a client bundle and an `insert:` row, recognised by
  /// its name saying what it is.
  func testRecognisesThemeWithoutSkinManifest() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.install(
      "dsh-kimino-theme",
      into: profile,
      manifest: [
        "description": "Kimino Theme: a soft pastel look",
        "keywords": ["theme"],
        "dsh": [
          "client": ["platform": "web"],
          "bundle": ["patch": "./cordis.patch.yml"],
        ],
      ],
      patch: "- insert:\n    - id: ui-skin-kimino\n      name: dsh-kimino-theme\n"
    )

    let found = catalog(profile).skins()
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(found[0].id, "kimino")
    XCTAssertEqual(found[0].rowID, "ui-skin-kimino")
    XCTAssertEqual(found[0].package, "dsh-kimino-theme")
    XCTAssertFalse(found[0].hasSkinManifest, "a convention theme has to be labelled as one")
  }

  /// A utility that merely mentions the word is not a theme. This is the rule that keeps the
  /// list from filling up with unrelated plugins.
  func testDoesNotRecogniseUtilityThatOnlyMentionsSkinInItsDescription() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.install(
      "dsh-whatever",
      into: profile,
      manifest: [
        "description": "Adds a skin switcher button to the sidebar",
        "dsh": [
          "client": ["platform": "web"],
          "bundle": ["patch": "./cordis.patch.yml"],
        ],
      ],
      patch: "- insert:\n    - id: ui-whatever\n      name: dsh-whatever\n"
    )
    XCTAssertTrue(catalog(profile).skins().isEmpty)
  }

  /// …unless the client declares itself immediately-loaded, which is how a market ships a
  /// theme whose package name says nothing.
  func testRecognisesImmediatelyLoadedClientDescribedAsATheme() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.installTheme(
      "acme-aurora",
      into: profile,
      rowID: "ui-skin-aurora",
      description: "Aurora theme for the harness web GUI",
      immediately: true
    )
    XCTAssertEqual(catalog(profile).skins().map(\.id), ["aurora"])
  }

  func testIgnoresPackageWhosePatchInsertsNothing() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.install(
      "dsh-plain-theme",
      into: profile,
      manifest: [
        "description": "A theme",
        "dsh": [
          "client": ["platform": "web"],
          "bundle": ["patch": "./cordis.patch.yml"],
        ],
      ],
      patch: "# nothing to insert\n"
    )
    XCTAssertTrue(catalog(profile).skins().isEmpty)
  }

  // MARK: - Registry fields

  func testReadsRegistryFieldsAndHonoursWiringRowID() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.install(
      "@dsh-external/deep-whale",
      into: profile,
      skin: [
        "id": "maid-atelier",
        "name": "鲸鱼娘昼夜工坊",
        "nameEn": "Deep Whale Day & Night",
        "tagline": "白昼与月潮",
        "author": "Small-tailqwq",
        "description": "一套完整皮肤。",
        "tags": ["anime", "whale"],
        "accent": "#c5a468",
        "bodyAttr": "data-dsh-maid-atelier",
        "order": 5,
        "wiring": ["id": "ui-skin-deep-whale-day-night", "bundleWired": false],
      ]
    )

    let skin = try XCTUnwrap(catalog(profile).skins().first)
    XCTAssertEqual(skin.id, "maid-atelier")
    XCTAssertEqual(skin.name, "鲸鱼娘昼夜工坊")
    XCTAssertEqual(skin.author, "Small-tailqwq")
    XCTAssertEqual(skin.bodyAttribute, "data-dsh-maid-atelier")
    XCTAssertEqual(skin.tags, ["anime", "whale"])
    // The row id comes from `wiring`, not from the skin's id: they differ here, and only
    // the row id disables the right loader entry.
    XCTAssertEqual(skin.rowID, "ui-skin-deep-whale-day-night")
    XCTAssertFalse(skin.isBundleWired)
  }

  func testDerivesRowIDFromSkinIDWhenRegistryDeclaresNone() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.installDeclared("@alpha/one", into: profile, id: "one")
    XCTAssertEqual(try XCTUnwrap(catalog(profile).skins().first).rowID, "ui-skin-one")
  }

  // MARK: - Bundle wiring

  func testSkinInBundleListWhoseOwnPatchInsertsItsRowIsBundleWired() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self, bundles: ["@alpha/one"])
    let directory = try SkinFixtures.installDeclared("@alpha/one", into: profile, id: "one", rowID: "ui-skin-one")
    try TestSupport.write(
      "- insert:\n    - id: ui-skin-one\n      name: '@alpha/one'\n",
      to: directory.appendingPathComponent("cordis.patch.yml")
    )
    XCTAssertTrue(try XCTUnwrap(catalog(profile).skins().first).isBundleWired)
  }

  /// In the bundle list, but its own patch does not insert a row: the manager has to write
  /// the insert itself, or the skin would be composed with nothing to compose.
  func testSkinInBundleListWithoutItsOwnInsertRowIsNotBundleWired() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self, bundles: ["@alpha/one"])
    let directory = try SkinFixtures.installDeclared("@alpha/one", into: profile, id: "one", rowID: "ui-skin-one")
    try TestSupport.write(
      "- id: ui-skin-one\n  config:\n    enabled: true\n",
      to: directory.appendingPathComponent("cordis.patch.yml")
    )
    XCTAssertFalse(try XCTUnwrap(catalog(profile).skins().first).isBundleWired)
  }

  // MARK: - Nested skins

  func testDiscoversSkinsNestedInsideAnAggregatePackage() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.install(
      "@linxin666/dsh-skins",
      into: profile,
      manifest: [
        "description": "A collection of skins",
        "dsh": [
          "client": ["platform": "web"],
          "bundle": ["patch": "./cordis.patch.yml"],
        ],
      ],
      patch: "- insert:\n    - id: ui-skin-aggregate\n      name: '@linxin666/dsh-skins'\n"
    )
    try SkinFixtures.installDeclared(
      "@linxin666/dsh-skins/skins/aurora",
      into: profile,
      id: "aurora",
      name: "Aurora",
      declaresPackage: false
    )

    let found = catalog(profile).skins()
    XCTAssertEqual(found.map(\.id), ["aurora"])
    // The nested skin is imported by its own directory name, which is what the manager links
    // into `node_modules` when it is applied.
    XCTAssertEqual(found[0].package, "aurora")
  }

  // MARK: - Ordering

  func testSortsByRegistryOrderThenName() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    try SkinFixtures.installDeclared("@alpha/late", into: profile, id: "late", order: 20, name: "Late")
    try SkinFixtures.installDeclared("@alpha/early-b", into: profile, id: "early-b", order: 1, name: "Beta")
    try SkinFixtures.installDeclared("@alpha/early-a", into: profile, id: "early-a", order: 1, name: "Alpha")
    XCTAssertEqual(catalog(profile).skins().map(\.name), ["Alpha", "Beta", "Late"])
  }

  func testMissingProfileYieldsNoSkinsRatherThanFailing() throws {
    let root = try TestSupport.makeRoot(self)
    XCTAssertTrue(SkinCatalog(profileDirectory: root.appendingPathComponent("nowhere")).skins().isEmpty)
  }

  /// A `node_modules` that is itself a symlink — a shared store, or a profile directory
  /// reached through a link, as this machine's `~/.dsh/profiles/web` used to be.
  ///
  /// `FileManager.contentsOfDirectory(at:)` returns an empty list for such a directory
  /// rather than an error, so discovery here has to enumerate by path or a profile with
  /// every skin installed would look like a profile with none.
  func testDiscoversSkinsThroughASymlinkedNodeModules() throws {
    let (_, profile) = try SkinFixtures.makeProfile(self)
    let real = profile.deletingLastPathComponent().appendingPathComponent("shared-node_modules", isDirectory: true)
    try SkinFixtures.installDeclared("@alpha/one", into: profile, id: "one", declaresPackage: false)
    // Move the populated tree aside and link it back under the profile.
    try FileManager.default.moveItem(at: profile.appendingPathComponent("node_modules"), to: real)
    try FileManager.default.createSymbolicLink(
      at: profile.appendingPathComponent("node_modules"),
      withDestinationURL: real
    )

    XCTAssertEqual(catalog(profile).skins().map(\.id), ["one"])
  }
}
