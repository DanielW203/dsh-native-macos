import Foundation
import HarnessKit
import XCTest
@testable import HarnessRuntime

/// The removal path: what `removePlugin` asks the harness CLI to do, what it refuses before
/// any subprocess runs, and the install log that makes "undo the last install" possible.
///
/// The process boundary is stubbed for the same reason the install tests stub it: a real
/// removal needs pnpm, a network, and a writable harness home, and none of those change the
/// things worth asserting — the argument shape, the refusals, and the bookkeeping this app
/// keeps on either side of the call.
final class PluginStoreRemovalTests: XCTestCase {
  private var root: URL!
  private var paths: RuntimePaths!

  override func setUpWithError() throws {
    root = try TestSupport.makeRoot(self)
    paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
  }

  // MARK: - Fixtures

  private func makeStore(
    responder: @escaping @Sendable (StubProcessRunner.Call) -> ProcessResult? = { _ in nil }
  ) -> (PluginStore, StubProcessRunner) {
    let toolchain = TestSupport.toolchainResponder()
    let runner = StubProcessRunner(realExecutables: []) { call in
      responder(call) ?? toolchain(call)
    }
    let store = PluginStore(
      paths: paths,
      entryProvider: { URL(fileURLWithPath: "/fake/dsh/lib/bin.js") },
      runner: runner
    )
    return (store, runner)
  }

  private var profileDirectory: URL {
    paths.profilesDirectory.appendingPathComponent("web", isDirectory: true)
  }

  private var manifestURL: URL { profileDirectory.appendingPathComponent("package.json") }

  /// Write the manifest the harness CLI would have created.
  private func writeManifest(dependencies: [String: String], bundles: [String] = []) throws {
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    let manifest = JSONValue.object([
      "name": .string("dsh-profile-web"),
      "private": .bool(true),
      "dependencies": .object(dependencies.mapValues { .string($0) }),
      "dsh": .object([
        "profile": .object(["bundles": .array(bundles.map { .string($0) })]),
      ]),
    ])
    try ProfileManifest.write(manifest, to: manifestURL)
  }

  /// Whether a call is the plugin subcommand, and which one it is.
  private func isPluginCall(_ call: StubProcessRunner.Call, subcommand: String? = nil) -> Bool {
    guard call.arguments.count >= 2, call.arguments[1] == "plugin" else { return false }
    guard let subcommand else { return true }
    return call.arguments.contains(subcommand)
  }

  /// The `dsh plugin …` arguments, with the toolchain's entry script dropped.
  private func pluginArguments(_ call: StubProcessRunner.Call) -> [String] {
    Array(call.arguments.dropFirst())
  }

  // MARK: - Argument shape

  func testRemovesThroughTheHarnessCLI() async throws {
    try writeManifest(dependencies: ["dsh-e2e": "1.0.0"], bundles: ["dsh-e2e"])
    let (store, runner) = makeStore { call in
      self.isPluginCall(call, subcommand: "remove") ? .ok("- dsh-e2e 1.0.0\n") : nil
    }

    let outcome = try await store.removePlugin("dsh-e2e", profile: "web")

    XCTAssertEqual(outcome.name, "dsh-e2e")
    guard let call = runner.calls.first(where: { isPluginCall($0, subcommand: "remove") }) else {
      return XCTFail("no plugin remove call was made")
    }
    XCTAssertEqual(pluginArguments(call), ["plugin", "--profile", "web", "remove", "dsh-e2e"])
    XCTAssertEqual(runner.calls.filter { isPluginCall($0) }.count, 1, "a removal is exactly one CLI invocation")
  }

  func testLiftsTheReleaseAgeGateOnlyWhenAsked() {
    XCTAssertEqual(
      PluginStore.removeArguments(name: "dsh-e2e", profile: "web", policy: .standard),
      ["plugin", "--profile", "web", "remove", "dsh-e2e"]
    )
    XCTAssertEqual(
      PluginStore.removeArguments(name: "dsh-e2e", profile: "web", policy: .allowYoungReleases),
      ["plugin", "--profile", "web", "remove", PluginStore.releaseAgeOverride, "dsh-e2e"]
    )
  }

  // MARK: - Refusals

  func testRefusesAPackageTheProfileDoesNotDependOn() async throws {
    try writeManifest(dependencies: ["dsh-other": "1.0.0"], bundles: ["dsh-other"])
    let (store, runner) = makeStore()

    do {
      _ = try await store.removePlugin("dsh-e2e", profile: "web")
      XCTFail("expected a refusal")
    } catch let error as RuntimeError {
      guard case .unsupported = error else { return XCTFail("unexpected \(error)") }
    }
    XCTAssertTrue(runner.calls.filter { isPluginCall($0) }.isEmpty, "nothing was run for a package that is not installed")
  }

  func testRefusesToRemoveTheHarnessItself() async throws {
    try writeManifest(
      dependencies: ["@deepseek-ai/dsh-base": "0.1.5", "@deepseek-ai/dsh-web-app": "0.1.5"],
      bundles: ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]
    )
    let (store, runner) = makeStore()

    do {
      _ = try await store.removePlugin("@deepseek-ai/dsh-base", profile: "web")
      XCTFail("expected a refusal")
    } catch let error as RuntimeError {
      guard case .unsupported = error else { return XCTFail("unexpected \(error)") }
    }
    XCTAssertTrue(runner.calls.filter { isPluginCall($0) }.isEmpty, "the harness's own packages are never removed")
  }

  func testReportsTheReleaseAgeGateSoTheCallerCanOfferTheOverride() async throws {
    try writeManifest(dependencies: ["dsh-e2e": "1.0.0"], bundles: ["dsh-e2e"])
    let (store, _) = makeStore { call in
      guard self.isPluginCall(call) else { return nil }
      return .failure(
        1,
        stderr: "ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION  1 lockfile entries failed verification:\n"
          + "  dsh-e2e@1.0.0 is within the minimumReleaseAge cutoff\n"
      )
    }

    do {
      _ = try await store.removePlugin("dsh-e2e", profile: "web")
      XCTFail("expected the gate to be reported")
    } catch let error as RuntimeError {
      guard case .youngReleaseBlocked(let packages, _) = error else { return XCTFail("unexpected \(error)") }
      XCTAssertEqual(packages, ["dsh-e2e@1.0.0"])
    }
  }

  // MARK: - Bookkeeping

  func testRemovingClearsThisAppsOwnRecords() async throws {
    try writeManifest(dependencies: ["dsh-e2e": "1.0.0"], bundles: ["dsh-e2e"])
    // The records as a previous install and a previous disable would have left them.
    try TestSupport.write(
      "{\n  \"dsh-e2e\" : {\n    \"disabledAt\" : \"2026-09-11T00:00:00Z\",\n    \"reason\" : \"user\"\n  }\n}\n",
      to: profileDirectory.appendingPathComponent("native-plugin-state.json")
    )
    try TestSupport.write(
      "[{\"installedAt\":\"2026-09-11T00:00:00Z\",\"name\":\"dsh-e2e\",\"spec\":\"dsh-e2e\"}]\n",
      to: profileDirectory.appendingPathComponent("native-install-log.json")
    )
    let (store, _) = makeStore { call in self.isPluginCall(call) ? .ok("") : nil }

    _ = try await store.removePlugin("dsh-e2e", profile: "web")

    let ledger = await store.disabledLedger(profile: "web")
    let log = await store.installLog(profile: "web")
    XCTAssertTrue(ledger.isEmpty, "a disabled mark must not outlive the package it names")
    XCTAssertTrue(log.isEmpty, "an install record must not outlive the package it names")
  }

  func testRecordsWhatAnInstallAddedAndUndoRemovesTheNewestOne() async throws {
    try writeManifest(
      dependencies: ["@deepseek-ai/dsh-base": "0.1.5"],
      bundles: ["@deepseek-ai/dsh-base"]
    )
    let manifest = manifestURL
    let (store, runner) = makeStore { call in
      guard self.isPluginCall(call) else { return nil }
      if call.arguments.contains("add") {
        // Stand in for the CLI: pnpm records the package it added in the manifest.
        guard let existing = try? ProfileManifest.read(manifest) else { return .ok("") }
        var dependencies = ProfileManifest.dependencies(existing)
        dependencies["dsh-e2e"] = "1.0.0"
        try? ProfileManifest.write(ProfileManifest.setDependencies(existing, dependencies), to: manifest)
      }
      return .ok("")
    }

    let outcome = try await store.addPlugin(.specifier("dsh-e2e"), profile: "web")
    XCTAssertEqual(outcome.installed, ["dsh-e2e"])

    let recorded = await store.lastInstalledPlugin(profile: "web")
    XCTAssertEqual(recorded?.name, "dsh-e2e")
    XCTAssertEqual(recorded?.spec, "dsh-e2e")

    let undone = try await store.undoLastInstall(profile: "web")
    XCTAssertEqual(undone?.name, "dsh-e2e")
    guard let call = runner.calls.first(where: { isPluginCall($0, subcommand: "remove") }) else {
      return XCTFail("undo did not reach the CLI")
    }
    XCTAssertEqual(pluginArguments(call), ["plugin", "--profile", "web", "remove", "dsh-e2e"])
    let remaining = await store.installLog(profile: "web")
    XCTAssertTrue(remaining.isEmpty)
  }

  func testUndoOffersNothingWhenThereIsNoHistory() async throws {
    try writeManifest(dependencies: ["dsh-e2e": "1.0.0"], bundles: ["dsh-e2e"])
    let (store, runner) = makeStore()

    let undone = try await store.undoLastInstall(profile: "web")

    XCTAssertNil(undone)
    XCTAssertTrue(runner.calls.filter { isPluginCall($0) }.isEmpty)
  }

  func testUndoIgnoresRecordsForPackagesThatAreGone() async throws {
    try writeManifest(dependencies: ["dsh-e2e": "1.0.0"], bundles: ["dsh-e2e"])
    // A record for something the profile no longer depends on (removed by dshmarket, say).
    try TestSupport.write(
      "[{\"installedAt\":\"2026-09-11T00:00:00Z\",\"name\":\"dsh-vanished\",\"spec\":\"dsh-vanished\"}]\n",
      to: profileDirectory.appendingPathComponent("native-install-log.json")
    )
    let (store, runner) = makeStore()

    let undone = try await store.undoLastInstall(profile: "web")

    XCTAssertNil(undone, "the manifest is the truth, not the log")
    XCTAssertTrue(runner.calls.filter { isPluginCall($0) }.isEmpty)
  }
}
