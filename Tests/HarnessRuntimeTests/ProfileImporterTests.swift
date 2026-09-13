import XCTest
@testable import HarnessRuntime

/// The profile importer, exercised against fixture homes.
///
/// Every case here is a decision the feature makes that the user could be surprised by:
/// what gets copied, what gets deliberately left behind, who wins a conflict, and what the
/// source home looks like afterwards.
final class ProfileImporterTests: XCTestCase {
  private static let entryPath = "/nonexistent/harness/bin.js"

  private struct Fixture {
    var paths: RuntimePaths
    var sourceHome: URL
    var root: URL
  }

  private func makeFixture(function: String = #function) throws -> Fixture {
    let root = try TestSupport.makeRoot(self, function: function)
    let paths = RuntimePaths(root: root.appendingPathComponent("NativeHarness", isDirectory: true))
    try paths.createDirectories()
    return Fixture(paths: paths, sourceHome: root.appendingPathComponent("desktop-home", isDirectory: true), root: root)
  }

  private func makeImporter(
    _ fixture: Fixture,
    responder: @escaping @Sendable (StubProcessRunner.Call) -> ProcessResult? = { _ in nil }
  ) -> (ProfileImporter, StubProcessRunner) {
    let runner = StubProcessRunner(realExecutables: ["ditto"], responder: responder)
    let importer = ProfileImporter(
      paths: fixture.paths,
      entryProvider: { URL(fileURLWithPath: Self.entryPath) },
      runner: runner
    )
    return (importer, runner)
  }

  private func request(
    _ fixture: Fixture,
    policy: PluginConflictPolicy = .preferSource
  ) -> PluginImportRequest {
    PluginImportRequest(
      sourceHome: fixture.sourceHome,
      sourceProfile: "desktop",
      destinationProfile: "web",
      conflictPolicy: policy
    )
  }

  private func destinationProfileDirectory(_ fixture: Fixture) -> URL {
    fixture.paths.profilesDirectory.appendingPathComponent("web", isDirectory: true)
  }

  private func installedVersion(_ name: String, in directory: URL) throws -> String? {
    try ProfileManifest.read(directory.appendingPathComponent("node_modules/\(name)/package.json"))["version"]?.stringValue
  }

  /// A source home with two plugins and one hoisted transitive dependency, and a
  /// destination profile that has a plugin of its own.
  @discardableResult
  private func makeStandardPair(_ fixture: Fixture) throws -> URL {
    try TestSupport.makePluginHome(
      at: fixture.sourceHome,
      profile: "desktop",
      bundles: ["@deepseek-ai/dsh-base", "dsh-memoir", "dsh-emoji"],
      dependencies: ["dsh-memoir": "0.6.1", "dsh-emoji": "0.3.2"],
      installed: ["dsh-memoir": "0.6.1", "dsh-emoji": "0.3.2", "zod": "3.23.8"],
      bundleDeclarations: ["dsh-memoir", "dsh-emoji"],
      profileFiles: [
        "pnpm-workspace.yaml": "packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\n",
        "pnpm-lock.yaml": "lockfileVersion: '9.0'\n",
        "native-plugin-state.json": "{}\n",
      ]
    )
    // Real homes keep the installation's closure beside the profiles; it must not be offered
    // as a profile of its own.
    try TestSupport.write("{}\n", to: fixture.paths.profilesDirectory.appendingPathComponent("node_modules/.modules.yaml"))
    return try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "keep-me"],
      dependencies: ["keep-me": "1.0.0"],
      installed: ["keep-me": "1.0.0"],
      bundleDeclarations: ["keep-me"],
      profileFiles: ["pnpm-workspace.yaml": "packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\n"]
    )
  }

  // MARK: - Planning

  func testPlanListsTheSourcePackagesAndWritesNothing() async throws {
    let fixture = try makeFixture()
    try makeStandardPair(fixture)
    let (importer, _) = makeImporter(fixture)

    let before = try TestSupport.treeFingerprint(fixture.paths.root)
    let plan = try await importer.plan(request(fixture))

    XCTAssertEqual(
      plan.items.filter { $0.location == .nodeModules && !$0.name.hasPrefix(".") }.map(\.name),
      ["dsh-emoji", "dsh-memoir", "zod"]
    )
    XCTAssertTrue(plan.items.contains { $0.name == "pnpm-lock.yaml" && $0.location == .profileRoot })
    XCTAssertTrue(plan.items.allSatisfy { $0.action == .copy })
    XCTAssertGreaterThan(plan.totalBytes, 0)
    XCTAssertEqual(plan.dependencyChanges.count, 2)
    XCTAssertTrue(plan.bundleChanges.contains("enable dsh-memoir"))
    XCTAssertTrue(plan.bundleChanges.contains("enable dsh-emoji"))
    // The one thing a plan may never do.
    XCTAssertEqual(try TestSupport.treeFingerprint(fixture.paths.root), before)
  }

  func testUndeclaredHoistedPackagesAreCopiedAndExplained() async throws {
    let fixture = try makeFixture()
    try makeStandardPair(fixture)
    let (importer, _) = makeImporter(fixture)

    let plan = try await importer.plan(request(fixture))
    XCTAssertTrue(plan.items.contains { $0.name == "zod" })
    XCTAssertTrue(
      plan.warnings.contains { $0.contains("not declared in the source profile's dependencies") },
      "the hoisted closure has to be explained, not silently copied"
    )
  }

  func testBundleUnionKeepsDestinationOnlyBundles() async throws {
    let fixture = try makeFixture()
    try makeStandardPair(fixture)
    let (importer, _) = makeImporter(fixture)

    let plan = try await importer.plan(request(fixture))
    _ = try await importer.apply(plan)

    let manifest = try ProfileManifest.read(destinationProfileDirectory(fixture).appendingPathComponent("package.json"))
    // The destination's order survives and the incoming bundles are appended, which is the
    // rule the plan previews and the operation writes.
    XCTAssertEqual(
      ProfileManifest.bundleList(manifest),
      ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "keep-me", "dsh-memoir", "dsh-emoji"]
    )
    XCTAssertEqual(plan.bundleChanges, ["enable dsh-memoir", "enable dsh-emoji"])
  }

  // MARK: - Applying

  func testApplyCopiesTheTreeAndMergesTheManifest() async throws {
    let fixture = try makeFixture()
    try makeStandardPair(fixture)
    let (importer, _) = makeImporter(fixture)

    let plan = try await importer.plan(request(fixture))
    let outcome = try await importer.apply(plan)
    let directory = destinationProfileDirectory(fixture)

    XCTAssertTrue(["dsh-emoji", "dsh-memoir", "zod"].allSatisfy { outcome.copied.contains($0) })
    XCTAssertTrue(outcome.copied.contains("pnpm-lock.yaml"), "the lockfile follows the tree it describes")
    XCTAssertEqual(try installedVersion("dsh-memoir", in: directory), "0.6.1")
    XCTAssertEqual(try installedVersion("zod", in: directory), "3.23.8")

    let manifest = try ProfileManifest.read(directory.appendingPathComponent("package.json"))
    XCTAssertEqual(ProfileManifest.dependencies(manifest)["dsh-memoir"], "0.6.1")
    XCTAssertEqual(ProfileManifest.dependencies(manifest)["keep-me"], "1.0.0")
    XCTAssertNotNil(outcome.backupDirectory)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: outcome.backupDirectory!.appendingPathComponent("manifest.json").path
      ),
      "an operation that can replace files has to record what it did"
    )
  }

  func testPreferSourceReplacesAndKeepsTheOldDirectoryInTheBackup() async throws {
    let fixture = try makeFixture()
    try makeStandardPair(fixture)
    let directory = destinationProfileDirectory(fixture)
    // The destination already has an older dsh-memoir.
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base", "dsh-memoir"],
      dependencies: ["dsh-memoir": "0.5.0"],
      installed: ["dsh-memoir": "0.5.0"],
      bundleDeclarations: ["dsh-memoir"],
      profileFiles: ["pnpm-workspace.yaml": "packages:\n  - .\n"]
    )
    let (importer, _) = makeImporter(fixture)

    let plan = try await importer.plan(request(fixture))
    let memoir = try XCTUnwrap(plan.items.first { $0.name == "dsh-memoir" })
    XCTAssertEqual(memoir.action, .replace)
    XCTAssertEqual(memoir.destinationVersion, "0.5.0")
    XCTAssertEqual(plan.backupBytes, memoir.byteCount)

    let outcome = try await importer.apply(plan)
    XCTAssertEqual(outcome.replaced, ["dsh-memoir"])
    XCTAssertEqual(try installedVersion("dsh-memoir", in: directory), "0.6.1")

    let backup = try XCTUnwrap(outcome.backupDirectory)
    let saved = try ProfileManifest.read(backup.appendingPathComponent("node_modules/dsh-memoir/package.json"))
    XCTAssertEqual(saved["version"]?.stringValue, "0.5.0", "the replaced directory has to survive the replacement")
    XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("package.json.before").path))
  }

  func testKeepDestinationSkipsTheConflict() async throws {
    let fixture = try makeFixture()
    try makeStandardPair(fixture)
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base", "dsh-memoir"],
      dependencies: ["dsh-memoir": "0.5.0"],
      installed: ["dsh-memoir": "0.5.0"],
      bundleDeclarations: ["dsh-memoir"],
      profileFiles: ["pnpm-workspace.yaml": "packages:\n  - .\n"]
    )
    let (importer, _) = makeImporter(fixture)

    let plan = try await importer.plan(request(fixture, policy: .keepDestination))
    let memoir = try XCTUnwrap(plan.items.first { $0.name == "dsh-memoir" })
    XCTAssertEqual(memoir.action, .skipExisting)

    let outcome = try await importer.apply(plan)
    XCTAssertTrue(outcome.replaced.isEmpty)
    XCTAssertEqual(try installedVersion("dsh-memoir", in: destinationProfileDirectory(fixture)), "0.5.0")
  }

  func testIdenticalVersionsAreNotRewritten() async throws {
    let fixture = try makeFixture()
    try makeStandardPair(fixture)
    let (importer, _) = makeImporter(fixture)

    let first = try await importer.plan(request(fixture))
    _ = try await importer.apply(first)

    let second = try await importer.plan(request(fixture))
    XCTAssertTrue(second.isNoop, "a second import must not rewrite what the first one wrote")
    XCTAssertFalse(second.items.contains { $0.action == .replace || $0.action == .copy })
    let outcome = try await importer.apply(second)
    XCTAssertTrue(outcome.copied.isEmpty)
    XCTAssertTrue(outcome.replaced.isEmpty)
  }

  // MARK: - What is deliberately left behind

  func testFallbackLinksAndSourceOnlyFilesAreNeverCopied() async throws {
    let fixture = try makeFixture()
    try TestSupport.makePluginHome(
      at: fixture.sourceHome,
      profile: "desktop",
      bundles: ["dsh-memoir"],
      dependencies: ["dsh-memoir": "0.6.1"],
      installed: ["dsh-memoir": "0.6.1"],
      bundleDeclarations: ["dsh-memoir"],
      profileFiles: [
        "cordis.yml": "[]\n",
        "native-plugin-state.json": "{\"disabled\":true}\n",
        "node_modules/.DS_Store": "junk\n",
        ".dsh-market/state.json": "{\"installed\":true}\n",
      ],
      fallbackLinks: ["ansi-regex": "\(fixture.sourceHome.path)/profiles/desktop/node_modules/ansi-regex"]
    )
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base"]
    )
    let (importer, _) = makeImporter(fixture)

    let plan = try await importer.plan(request(fixture))
    XCTAssertFalse(plan.items.contains { $0.name == ".dsh-module-fallback" })
    XCTAssertFalse(plan.items.contains { $0.name == ".DS_Store" })

    _ = try await importer.apply(plan)
    let directory = destinationProfileDirectory(fixture)
    for relative in [
      "node_modules/.dsh-module-fallback",
      "node_modules/.DS_Store",
      "native-plugin-state.json",
      "cordis.yml",
      ".dsh-market",
    ] {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path),
        "\(relative) belongs to the source home, not to the plugins"
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("node_modules/dsh-memoir").path))
  }

  func testSourceHomeIsOnlyRead() async throws {
    let fixture = try makeFixture()
    try makeStandardPair(fixture)
    let (importer, _) = makeImporter(fixture)

    let before = try TestSupport.treeFingerprint(fixture.sourceHome)
    let plan = try await importer.plan(request(fixture))
    _ = try await importer.apply(plan)
    XCTAssertEqual(try TestSupport.treeFingerprint(fixture.sourceHome), before)
  }

  // MARK: - The patch layer

  func testPatchEntriesAreMergedOnceAndReplacedById() async throws {
    let fixture = try makeFixture()
    try TestSupport.makePluginHome(
      at: fixture.sourceHome,
      profile: "desktop",
      bundles: ["dsh-skin-market"],
      dependencies: ["dsh-skin-market": "0.1.47"],
      installed: ["dsh-skin-market": "0.1.47"],
      bundleDeclarations: ["dsh-skin-market"],
      profileFiles: [
        "cordis.patch.yml": "# --- dsh-skin-manager managed (auto-generated; do not edit) ---\n- id: dsh-skin-market\n  disabled: true\n# --- end dsh-skin-manager managed ---\n- id: only-in-source\n  disabled: true\n",
      ]
    )
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base"],
      profileFiles: [
        "cordis.patch.yml": "# Your patch layer for this dsh profile\n[]\n",
      ]
    )
    let (importer, _) = makeImporter(fixture)

    let plan = try await importer.plan(request(fixture))
    XCTAssertEqual(plan.patchChanges.count, 2)
    _ = try await importer.apply(plan)

    let text = try String(
      contentsOf: destinationProfileDirectory(fixture).appendingPathComponent("cordis.patch.yml"),
      encoding: .utf8
    )
    XCTAssertTrue(text.contains("# Your patch layer for this dsh profile"))
    XCTAssertTrue(text.contains("id: only-in-source"))
    XCTAssertTrue(CordisPatchEditor.hasDisable(text, named: ["dsh-skin-market"]))

    let second = try await importer.plan(request(fixture))
    XCTAssertTrue(second.patchChanges.isEmpty, "merging the same entries twice must change nothing")
  }

  func testPatchEntriesThatDifferByIDAreReplaced() async throws {
    let fixture = try makeFixture()
    try TestSupport.makePluginHome(
      at: fixture.sourceHome,
      profile: "desktop",
      bundles: [],
      dependencies: ["dsh-skin-market": "0.1.47"],
      installed: ["dsh-skin-market": "0.1.47"],
      profileFiles: ["cordis.patch.yml": "- id: dsh-skin-market\n  disabled: true\n"]
    )
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base"],
      profileFiles: ["cordis.patch.yml": "- id: dsh-skin-market\n  disabled: false\n"]
    )
    let (importer, _) = makeImporter(fixture)

    let plan = try await importer.plan(request(fixture))
    XCTAssertEqual(plan.patchChanges, ["replace patch entry dsh-skin-market"])
    _ = try await importer.apply(plan)

    let text = try String(
      contentsOf: destinationProfileDirectory(fixture).appendingPathComponent("cordis.patch.yml"),
      encoding: .utf8
    )
    XCTAssertEqual(text, "- id: dsh-skin-market\n  disabled: true\n")
  }

  // MARK: - Refusals

  func testUninitializedDestinationIsRefused() async throws {
    let fixture = try makeFixture()
    try TestSupport.makePluginHome(
      at: fixture.sourceHome,
      profile: "desktop",
      dependencies: ["dsh-memoir": "0.6.1"],
      installed: ["dsh-memoir": "0.6.1"]
    )
    let (importer, _) = makeImporter(fixture)

    await XCTAssertThrowsRuntimeError {
      try await importer.plan(self.request(fixture))
    }
  }

  func testSourceAndDestinationBeingTheSameProfileIsRefused() async throws {
    let fixture = try makeFixture()
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      dependencies: ["dsh-memoir": "0.6.1"],
      installed: ["dsh-memoir": "0.6.1"]
    )
    let (importer, _) = makeImporter(fixture)
    let same = PluginImportRequest(
      sourceHome: fixture.paths.dshHome,
      sourceProfile: "web",
      destinationProfile: "web"
    )

    await XCTAssertThrowsRuntimeError {
      try await importer.plan(same)
    }
  }

  // MARK: - Verification

  func testVerifyNamesWhatWouldNotLoadAndReportsAFailedCompose() async throws {
    let fixture = try makeFixture()
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base", "dsh-memoir"],
      dependencies: ["dsh-memoir": "0.6.1", "ghost": "1.0.0"],
      installed: ["dsh-memoir": "0.6.1"],
      bundleDeclarations: ["dsh-memoir"]
    )
    try TestSupport.installFakeToolchain(into: fixture.paths)

    let toolchain = TestSupport.toolchainResponder()
    let (importer, runner) = makeImporter(fixture) { call in
      // The import check: one module loads, one imports a name this runtime no longer has.
      if call.arguments.first == "--input-type=module" {
        return .ok("""
        ok|dsh-memoir
        fail|ghost|The requested module '@deepseek-ai/dsh-settings' does not provide an export named 'settingsNamespace'

        """)
      }
      if call.arguments.first == Self.entryPath {
        return .failure(1, stderr: "boom: dsh-memoir failed to activate")
      }
      return toolchain(call)
    }

    let verification = try await importer.verify(profile: "web", expecting: ["missing-one"])
    XCTAssertFalse(verification.isHealthy)
    XCTAssertFalse(verification.composeSucceeded)
    XCTAssertTrue(
      verification.composeDiagnostic?.contains("boom") ?? false,
      "the compose check reports what the harness said"
    )
    XCTAssertEqual(
      verification.importFailures["ghost"],
      "The requested module '@deepseek-ai/dsh-settings' does not provide an export named 'settingsNamespace'"
    )
    XCTAssertEqual(
      verification.entries.first { $0.name == "ghost" }?.problem,
      "cannot be imported by this runtime: The requested module '@deepseek-ai/dsh-settings' does not provide an export named 'settingsNamespace'"
    )
    XCTAssertEqual(
      verification.entries.first { $0.name == "missing-one" }?.problem,
      "imported but absent from profile web"
    )
    XCTAssertTrue(
      runner.calls.contains { $0.arguments == [Self.entryPath, "--profile", "web", "--dump-config"] },
      "the compose check must not boot a server"
    )
  }

  // MARK: - Reading a failed boot

  func testPluginSuspectsReadsWhatAFailedBootBlames() {
    let known: Set<String> = ["dsh-pocket", "@sjhmars/pi-ai-thinking", "dsh-memoir"]
    // The exact shapes this machine produced, one per failure mode.
    let applyFailure = """
      Error: failed to apply loader entry dsh-pocket (dsh-pocket): cannot get property "webServer" without inject
          at installPocketRpc (file:///Users/me/Library/Application%20Support/NativeHarness/home/profiles/web/node_modules/dsh-pocket/lib/web-rpc.js:33:29)
      """
    XCTAssertEqual(
      ProfileImporter.pluginSuspects(in: applyFailure, profile: "web", known: known),
      ["dsh-pocket"]
    )

    let importFailure = """
      file:///Users/me/Library/Application%20Support/NativeHarness/home/profiles/web/node_modules/@sjhmars/pi-ai-thinking/lib/index.js:2
      import { SettingsConflictError, settingsNamespace } from "@deepseek-ai/dsh-settings";
      SyntaxError: The requested module '@deepseek-ai/dsh-settings' does not provide an export named 'settingsNamespace'
      """
    XCTAssertEqual(
      ProfileImporter.pluginSuspects(in: importFailure, profile: "web", known: known),
      ["@sjhmars/pi-ai-thinking"]
    )

    // Nothing that is not in this profile may be named: the caller disables what is returned.
    XCTAssertTrue(
      ProfileImporter.pluginSuspects(
        in: "at file:///x/profiles/web/node_modules/some-other-plugin/lib/index.js:1",
        profile: "web",
        known: known
      ).isEmpty
    )
    XCTAssertTrue(ProfileImporter.pluginSuspects(in: "plain failure", profile: "web", known: known).isEmpty)
  }

  func testQuarantineDisablesNothingItCannotProveGuilty() async throws {
    let fixture = try makeFixture()
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/base", "dsh-memoir"],
      dependencies: ["dsh-memoir": "0.6.1"],
      installed: ["dsh-memoir": "0.6.1"],
      bundleDeclarations: ["dsh-memoir"]
    )
    try TestSupport.installFakeToolchain(into: fixture.paths)

    // The stub runner cannot start a child, so the boot check fails without blaming anyone.
    let toolchain = TestSupport.toolchainResponder()
    let (importer, _) = makeImporter(fixture) { call in toolchain(call) }

    let outcome = try await importer.quarantine(profile: "web", maxRounds: 2)
    XCTAssertFalse(outcome.started)
    XCTAssertTrue(outcome.disabled.isEmpty, "a boot that cannot even be attempted is not a plugin's fault")

    let manifest = try ProfileManifest.read(destinationProfileDirectory(fixture).appendingPathComponent("package.json"))
    XCTAssertTrue(ProfileManifest.bundleList(manifest).contains("dsh-memoir"), "nothing may be disabled on a guess")
  }

  // MARK: - Homes

  func testHomesFindsTheDesktopHomeAndItsProfiles() async throws {
    let fixture = try makeFixture()
    try makeStandardPair(fixture)
    let (importer, _) = makeImporter(fixture)

    let homes = await importer.homes()
    let console = try XCTUnwrap(homes.first { $0.kind == .console })
    XCTAssertEqual(console.url.standardizedFileURL, fixture.paths.dshHome.standardizedFileURL)
    XCTAssertEqual(console.initializedProfiles.map(\.name), ["web"])
    XCTAssertFalse(
      console.profiles.contains { $0.name == "node_modules" },
      "the installation's closure lives in that directory and is not a profile"
    )

    let custom = await importer.homes(extra: [fixture.sourceHome])
    XCTAssertEqual(custom.filter { $0.kind == .custom }.map(\.url), [fixture.sourceHome.standardizedFileURL])
    let desktop = try XCTUnwrap(custom.first { $0.kind == .custom })
    XCTAssertEqual(desktop.initializedProfiles.map(\.name), ["desktop"])
    XCTAssertEqual(desktop.initializedProfiles.first?.dependencyCount, 2)
  }
}

/// Assert that an async expression throws a RuntimeError, without the ceremony of
/// unwrapping it in every call site.
func XCTAssertThrowsRuntimeError<T>(
  _ expression: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("expected a RuntimeError", file: file, line: line)
  } catch is RuntimeError {
    return
  } catch {
    XCTFail("expected a RuntimeError, got \(error)", file: file, line: line)
  }
}
