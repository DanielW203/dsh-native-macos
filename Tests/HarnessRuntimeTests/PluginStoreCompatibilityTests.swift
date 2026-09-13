import Foundation
import XCTest
@testable import HarnessRuntime

/// Reading the compatibility signals out of a profile's installed plugins.
///
/// Every fixture here is a trimmed copy of a manifest this machine actually has installed,
/// taken from `~/Library/Application Support/NativeHarness/home/profiles/web/node_modules`.
/// Real manifests rather than invented ones on purpose: the whole audit turns on which
/// fields the ecosystem writes, and made-up manifests would let the reader pass while the
/// real ones said something else.
final class PluginStoreCompatibilityTests: XCTestCase {
  private var root: URL!
  private var paths: RuntimePaths!

  override func setUpWithError() throws {
    root = try TestSupport.makeRoot(self)
    paths = RuntimePaths(root: root)
  }

  private func makeStore() -> PluginStore {
    PluginStore(
      paths: paths,
      entryProvider: { URL(fileURLWithPath: "/fake/dsh/lib/bin.js") },
      runner: StubProcessRunner(realExecutables: []) { _ in nil }
    )
  }

  /// Write one package into `profiles/<profile>/node_modules/<name>/package.json`.
  private func install(_ name: String, manifest: String, profile: String = "web") throws {
    let url = paths.profilesDirectory
      .appendingPathComponent(profile, isDirectory: true)
      .appendingPathComponent("node_modules", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
      .appendingPathComponent("package.json")
    try TestSupport.write(manifest, to: url)
  }

  /// Write the profile manifest with the given dependency map and bundle list.
  private func writeProfile(
    dependencies: [String: String],
    bundles: [String],
    profile: String = "web"
  ) throws {
    let url = paths.profilesDirectory
      .appendingPathComponent(profile, isDirectory: true)
      .appendingPathComponent("package.json")
    var lines: [String] = ["{"]
    lines.append("  \"name\": \"dsh-profile-\(profile)\",")
    lines.append("  \"dependencies\": {")
    lines.append(dependencies.keys.sorted().map { key in
      "    \"\(key)\": \"\(dependencies[key]!)\""
    }.joined(separator: ",\n"))
    lines.append("  },")
    lines.append("  \"dsh\": { \"profile\": { \"bundles\": ["
      + bundles.map { "\"\($0)\"" }.joined(separator: ", ") + "] } }")
    lines.append("}")
    try TestSupport.write(lines.joined(separator: "\n"), to: url)
  }

  // MARK: - Real manifests

  /// `dsh-memoir` is the richest real fixture: it declares `dsh.engines.dsh`, two
  /// `@deepseek-ai/dsh-*` peers with the same range, a bundle patch, and a client half.
  func testReadsEveryCompatibilityFieldFromARealManifest() async throws {
    try writeProfile(dependencies: ["dsh-memoir": "^0.7.0"], bundles: ["dsh-memoir"])
    try install("dsh-memoir", manifest: """
    {
      "name": "dsh-memoir",
      "version": "0.7.0",
      "repository": { "url": "git+https://github.com/example/dsh-memoir.git" },
      "peerDependencies": {
        "@deepseek-ai/dsh-llm": ">=0.1.5-rc.1 <0.1.6-0",
        "@deepseek-ai/dsh-tools": ">=0.1.5-rc.1 <0.1.6-0",
        "@deepseek-ai/cordis": "^4.0.1"
      },
      "dsh": {
        "engines": { "dsh": ">=0.1.5-rc.1 <0.1.6-0" },
        "bundle": { "patch": "./cordis.patch.yml" },
        "client": { "inject": ["@deepseek-ai/dsh-client-connection"], "platform": "web" }
      }
    }
    """)

    let record = try XCTUnwrap(try makeStore().plugins(profile: "web").first)

    XCTAssertEqual(record.name, "dsh-memoir")
    XCTAssertEqual(record.moduleName, "dsh-memoir")
    XCTAssertEqual(record.installedVersion, "0.7.0")
    XCTAssertEqual(record.enginesRange, ">=0.1.5-rc.1 <0.1.6-0")
    XCTAssertTrue(record.hasBundlePatch)
    XCTAssertTrue(record.isBundle, "hasBundlePatch and isBundle answer the same question")
    XCTAssertEqual(record.clientPlatform, "web")
    XCTAssertEqual(record.clientInjectCount, 1)
    XCTAssertEqual(record.dshPeerRanges, [
      "@deepseek-ai/dsh-llm": ">=0.1.5-rc.1 <0.1.6-0",
      "@deepseek-ai/dsh-tools": ">=0.1.5-rc.1 <0.1.6-0",
    ], "@deepseek-ai/cordis is a plugin-runtime dep, not a harness-version claim")
    XCTAssertEqual(record.repository, "git+https://github.com/example/dsh-memoir.git")
  }

  /// Most of the ecosystem declares nothing: this is the `undeclared` path, and it must read
  /// as "no claim" rather than as a missing/broken install.
  func testPluginWithoutAnyDeclarationIsReadCleanly() async throws {
    try writeProfile(dependencies: ["dshmarket": "^1.45.1"], bundles: ["dshmarket"])
    try install("dshmarket", manifest: """
    {
      "name": "dshmarket",
      "version": "1.45.1",
      "peerDependencies": { "@deepseek-ai/cordis": "^4.0.1" },
      "dsh": { "bundle": { "patch": "./cordis.patch.yml" }, "client": { "platform": "web" } }
    }
    """)

    let record = try XCTUnwrap(try makeStore().plugins(profile: "web").first)
    XCTAssertNil(record.enginesRange)
    XCTAssertTrue(record.dshPeerRanges.isEmpty)
    XCTAssertEqual(record.clientPlatform, "web")
    XCTAssertEqual(record.clientInjectCount, 0)
  }

  /// A host-only plugin has a bundle patch but no client half.
  func testHostOnlyPluginHasNoClientFields() async throws {
    try writeProfile(dependencies: ["host-only": "1.0.0"], bundles: ["host-only"])
    try install("host-only", manifest: """
    { "name": "host-only", "version": "1.0.0", "dsh": { "bundle": { "patch": "./cordis.patch.yml" } } }
    """)

    let record = try XCTUnwrap(try makeStore().plugins(profile: "web").first)
    XCTAssertTrue(record.hasBundlePatch)
    XCTAssertNil(record.clientPlatform)
    XCTAssertEqual(record.clientInjectCount, 0)
  }

  /// A dependency that is installed but declares no `dsh.bundle.patch` is inert; the record
  /// has to say so, or the UI would offer a toggle that does nothing.
  func testDependencyWithoutABundleIsNotABundle() async throws {
    try writeProfile(dependencies: ["inert-lib": "^2.0.0"], bundles: [])
    try install("inert-lib", manifest: #"{ "name": "inert-lib", "version": "2.0.0" }"#)

    let record = try XCTUnwrap(try makeStore().plugins(profile: "web").first)
    XCTAssertFalse(record.isBundle)
    XCTAssertFalse(record.hasBundlePatch)
    XCTAssertFalse(record.isEnabled)
  }

  // MARK: - Declared version

  func testDeclaredVersionIsOnlyReadFromAPlainVersionSpec() async throws {
    XCTAssertEqual(PluginStore.declaredVersion(fromSpec: "0.7.0"), "0.7.0")
    XCTAssertEqual(PluginStore.declaredVersion(fromSpec: "^0.7.0"), "0.7.0")
    XCTAssertEqual(PluginStore.declaredVersion(fromSpec: "~0.7.0"), "0.7.0")
    XCTAssertEqual(PluginStore.declaredVersion(fromSpec: ">=0.7.0"), "0.7.0")
    // A URL, a range, or a link says nothing about the installed version, and guessing would
    // defeat the point of showing it beside `installedVersion`.
    XCTAssertNil(PluginStore.declaredVersion(fromSpec: "link:/Users/example/checkout"))
    XCTAssertNil(PluginStore.declaredVersion(fromSpec: "file:./plugin.tgz"))
    XCTAssertNil(PluginStore.declaredVersion(fromSpec: "github:owner/repo"))
    XCTAssertNil(PluginStore.declaredVersion(fromSpec: "npm:other@1.0.0"))
    XCTAssertNil(PluginStore.declaredVersion(fromSpec: ">=0.1.5-rc.1 <0.1.6-0"))
  }

  // MARK: - Bundled versions

  func testBundledVersionsReadOnlyTheReferencedPackages() async throws {
    let release = paths.releaseDirectory("0.1.5-rc.2-registry-npm")
    let modules = release.appendingPathComponent("node_modules/@deepseek-ai", isDirectory: true)
    try TestSupport.write(#"{ "name": "@deepseek-ai/dsh-tools", "version": "0.1.5-rc.2" }"#,
                          to: modules.appendingPathComponent("dsh-tools/package.json"))
    try TestSupport.write(#"{ "name": "@deepseek-ai/dsh-llm", "version": "0.1.5-rc.2" }"#,
                          to: modules.appendingPathComponent("dsh-llm/package.json"))

    let versions = try makeStore().bundledDshVersions(
      releaseID: "0.1.5-rc.2-registry-npm",
      packages: ["@deepseek-ai/dsh-tools", "@deepseek-ai/dsh-not-installed"]
    )

    XCTAssertEqual(versions, ["@deepseek-ai/dsh-tools": "0.1.5-rc.2"])
    XCTAssertNil(versions["@deepseek-ai/dsh-not-installed"], "an absent package is absent, not empty")
  }

  func testBundledVersionsWithoutAReleaseIsEmpty() async throws {
    let versions = try makeStore().bundledDshVersions(releaseID: nil, packages: ["@deepseek-ai/dsh-tools"])
    XCTAssertTrue(versions.isEmpty)
  }

  // MARK: - Shadowing

  /// A nested `node_modules/@deepseek-ai/dsh-*` inside the plugin is the on-disk evidence
  /// that pnpm could not share the release's instance — the one mismatch a manifest cannot
  /// show, because the peer range still looks fine.
  func testNestedDshCopyIsReportedAsShadowed() async throws {
    try writeProfile(dependencies: ["dsh-memoir": "^0.7.0"], bundles: ["dsh-memoir"])
    try install("dsh-memoir", manifest: """
    {
      "name": "dsh-memoir",
      "version": "0.7.0",
      "peerDependencies": { "@deepseek-ai/dsh-tools": ">=0.1.5-rc.1 <0.1.6-0" }
    }
    """)
    let nested = paths.profilesDirectory
      .appendingPathComponent("web/node_modules/dsh-memoir/node_modules/@deepseek-ai/dsh-tools/package.json")
    try TestSupport.write(#"{ "name": "@deepseek-ai/dsh-tools", "version": "0.1.4" }"#, to: nested)

    let store = makeStore()
    let records = try store.plugins(profile: "web")
    XCTAssertEqual(store.shadowedDshPackages(profile: "web", records: records),
                   ["dsh-memoir": ["@deepseek-ai/dsh-tools"]])
  }

  func testNoShadowingWhenThePeerIsSatisfiedFromTheRelease() async throws {
    try writeProfile(dependencies: ["dsh-memoir": "^0.7.0"], bundles: ["dsh-memoir"])
    try install("dsh-memoir", manifest: """
    {
      "name": "dsh-memoir",
      "version": "0.7.0",
      "peerDependencies": { "@deepseek-ai/dsh-tools": ">=0.1.5-rc.1 <0.1.6-0" }
    }
    """)

    let store = makeStore()
    let records = try store.plugins(profile: "web")
    XCTAssertTrue(store.shadowedDshPackages(profile: "web", records: records).isEmpty)
  }

  func testReferencedPackagesIsTheUnionOfPeerNames() async throws {
    try writeProfile(dependencies: ["a": "1.0.0", "b": "1.0.0"], bundles: [])
    try install("a", manifest: """
    { "name": "a", "version": "1.0.0",
      "peerDependencies": { "@deepseek-ai/dsh-tools": ">=0.1.0", "@deepseek-ai/cordis": "^4.0.1" } }
    """)
    try install("b", manifest: """
    { "name": "b", "version": "1.0.0",
      "peerDependencies": { "@deepseek-ai/dsh-llm": ">=0.1.0", "@deepseek-ai/dsh-tools": ">=0.1.0" } }
    """)

    XCTAssertEqual(try makeStore().referencedDshPackages(profile: "web"),
                   ["@deepseek-ai/dsh-llm", "@deepseek-ai/dsh-tools"])
  }
}
