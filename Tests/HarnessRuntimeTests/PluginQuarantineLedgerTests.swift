import Foundation
import HarnessKit
import XCTest
@testable import HarnessRuntime

/// The quarantine ledger: what the app writes when *it* decided to disable a plugin.
///
/// The distinction under test is the one the interface depends on. A plugin the user turned
/// off must stay off; a plugin the app turned off to get a release to boot is a repair that
/// has to be findable, explainable, and reversible — and only for the release it was made for.
final class PluginQuarantineLedgerTests: XCTestCase {
  private var root: URL!
  private var paths: RuntimePaths!

  override func setUpWithError() throws {
    root = try TestSupport.makeRoot(self)
    paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
  }

  private func makeStore() -> PluginStore {
    let toolchain = TestSupport.toolchainResponder()
    let runner = StubProcessRunner(realExecutables: []) { call in toolchain(call) }
    return PluginStore(
      paths: paths,
      entryProvider: { URL(fileURLWithPath: "/fake/dsh/lib/bin.js") },
      runner: runner
    )
  }

  private func writeProfile(_ dependencies: [String: String], bundles: [String]) throws {
    try TestSupport.makePluginHome(
      at: paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base"] + bundles,
      dependencies: dependencies,
      installed: dependencies
    )
  }

  private var ledgerURL: URL {
    paths.profilesDirectory.appendingPathComponent("web/native-plugin-state.json")
  }

  private func ledgerJSON() -> [String: [String: String]] {
    guard let data = try? Data(contentsOf: ledgerURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
    else { return [:] }
    return object
  }

  // MARK: - Writing

  func testAQuarantineIsRecordedWithItsRelease() async throws {
    try writeProfile(["dsh-memoir": "0.7.0"], bundles: ["dsh-memoir"])
    let store = makeStore()

    let result = try await store.setEnabled(
      "dsh-memoir",
      enabled: false,
      profile: "web",
      quarantinedDuring: "0.1.7-rc.1-registry-npm"
    )

    XCTAssertTrue(result.changes.contains { $0.contains("quarantined for 0.1.7-rc.1-registry-npm") })
    XCTAssertEqual(ledgerJSON()["dsh-memoir"]?["reason"], "quarantine:0.1.7-rc.1-registry-npm")
    let quarantined = store.quarantinedPlugins(profile: "web")
    XCTAssertEqual(quarantined.map(\.name), ["dsh-memoir"])
    XCTAssertEqual(quarantined.first?.releaseID, "0.1.7-rc.1-registry-npm")
    XCTAssertEqual(quarantined.first?.disabledAt.isEmpty, false)
  }

  /// The user's own disable is still written as `"user"`, so a ledger this build reads and one
  /// an older build wrote agree.
  func testAUserDisableIsStillRecordedAsUser() async throws {
    try writeProfile(["dsh-emoji": "0.3.3"], bundles: ["dsh-emoji"])
    let store = makeStore()

    _ = try await store.setEnabled("dsh-emoji", enabled: false, profile: "web")

    XCTAssertEqual(ledgerJSON()["dsh-emoji"]?["reason"], "user")
    XCTAssertTrue(store.quarantinedPlugins(profile: "web").isEmpty)
  }

  /// An older build's ledger has no quarantine reason anywhere in it, and must read fine.
  func testAnOlderLedgerStillReads() throws {
    try writeProfile(["dsh-emoji": "0.3.3"], bundles: [])
    try FileManager.default.createDirectory(
      at: ledgerURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(#"{"dsh-emoji":{"disabledAt":"2026-09-01T00:00:00Z","reason":"user"}}"#.utf8)
      .write(to: ledgerURL)
    let store = makeStore()

    XCTAssertEqual(store.disabledLedger(profile: "web")["dsh-emoji"], "2026-09-01T00:00:00Z")
    XCTAssertTrue(store.quarantinedPlugins(profile: "web").isEmpty)
  }

  // MARK: - Reading and restoring

  func testQuarantineIsFilterableByRelease() async throws {
    try writeProfile(["a": "1.0.0", "b": "1.0.0", "c": "1.0.0"], bundles: ["a", "b", "c"])
    let store = makeStore()

    _ = try await store.setEnabled("a", enabled: false, profile: "web", quarantinedDuring: "0.1.6")
    _ = try await store.setEnabled("b", enabled: false, profile: "web", quarantinedDuring: "0.1.7")
    _ = try await store.setEnabled("c", enabled: false, profile: "web")

    XCTAssertEqual(store.quarantinedPlugins(profile: "web", releaseID: "0.1.7").map(\.name), ["b"])
    XCTAssertEqual(store.quarantinedPlugins(profile: "web").map(\.name), ["a", "b"])
  }

  /// The one operation that makes an automatic disable acceptable: put back exactly what was
  /// taken out for this release, and nothing else.
  func testClearingAReleaseRestoresOnlyItsOwnQuarantine() async throws {
    try writeProfile(["a": "1.0.0", "b": "1.0.0"], bundles: ["a"])
    let store = makeStore()
    _ = try await store.setEnabled("a", enabled: false, profile: "web", quarantinedDuring: "0.1.7")
    _ = try await store.setEnabled("b", enabled: false, profile: "web")

    let restored = try await store.clearQuarantine(profile: "web", releaseID: "0.1.7")

    XCTAssertEqual(restored, ["a"])
    let manifest = try ProfileManifest.read(
      paths.profilesDirectory.appendingPathComponent("web/package.json")
    )
    let bundles = ProfileManifest.bundleList(manifest)
    XCTAssertTrue(bundles.contains("a"), "the quarantined plugin is back in the layer stack")
    XCTAssertFalse(bundles.contains("b"), "the user's own disable is not touched")
    XCTAssertTrue(store.quarantinedPlugins(profile: "web").isEmpty)
    XCTAssertEqual(store.disabledLedger(profile: "web")["b"] != nil, true)
  }

  func testClearingAReleaseWithNothingQuarantinedChangesNothing() async throws {
    try writeProfile(["a": "1.0.0"], bundles: ["a"])
    let store = makeStore()

    let restored = try await store.clearQuarantine(profile: "web", releaseID: "0.1.7")

    XCTAssertTrue(restored.isEmpty)
    let manifest = try ProfileManifest.read(
      paths.profilesDirectory.appendingPathComponent("web/package.json")
    )
    XCTAssertTrue(ProfileManifest.bundleList(manifest).contains("a"))
  }
}
