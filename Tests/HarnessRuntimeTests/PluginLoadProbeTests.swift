import XCTest
@testable import HarnessRuntime

/// The pre-upgrade load probe.
///
/// The decision this feature makes is *which plugins get disabled before the user ever sees
/// the new version*, so the tests are all about the boundary between "the module refused to
/// load" and "the probe could not tell" — the first may disable something, the second may not.
final class PluginLoadProbeTests: XCTestCase {
  private struct Fixture {
    var paths: RuntimePaths
    var root: URL
  }

  private func makeFixture(function: String = #function) throws -> Fixture {
    let root = try TestSupport.makeRoot(self, function: function)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()
    try TestSupport.installFakeToolchain(into: paths)
    return Fixture(paths: paths, root: root)
  }

  private func provider(_ entry: URL?) -> ReleaseEntryProviding {
    StubReleaseProvider(entry: entry)
  }

  private func makeProbe(
    _ fixture: Fixture,
    entry: URL? = URL(fileURLWithPath: "/fake/harness/bin.js"),
    responder: @escaping @Sendable (StubProcessRunner.Call) -> ProcessResult? = { _ in nil }
  ) -> (PluginLoadProbe, StubProcessRunner) {
    let toolchain = TestSupport.toolchainResponder()
    let runner = StubProcessRunner(realExecutables: []) { call in
      responder(call) ?? toolchain(call)
    }
    let probe = PluginLoadProbe(paths: fixture.paths, provider: provider(entry), runner: runner)
    return (probe, runner)
  }

  private func makeProfile(_ fixture: Fixture, plugins: [String: String]) throws {
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base"] + plugins.keys.sorted(),
      dependencies: plugins,
      installed: plugins,
      bundleDeclarations: Set(plugins.keys)
    )
  }

  // MARK: - The happy path

  func testReportsNothingWhenEveryPluginImports() async throws {
    let fixture = try makeFixture()
    try makeProfile(fixture, plugins: ["dsh-memoir": "0.7.0", "dsh-emoji": "0.3.3"])
    let (probe, runner) = makeProbe(fixture) { call in
      guard call.arguments.contains("-e") else { return nil }
      return ProcessResult(
        exitCode: 0,
        stdout: "ok|dsh-memoir\nok|dsh-emoji\n",
        stderr: "",
        duration: 0
      )
    }

    let result = await probe.probe(profile: "web", releaseID: "0.1.7-rc.1-registry-npm")

    XCTAssertTrue(result.unloadable.isEmpty)
    XCTAssertTrue(result.notes.isEmpty)
    XCTAssertTrue(result.summary.contains("没有插件加载失败"))
    // One process per plugin: a plugin that hangs must not be able to hold the others up.
    XCTAssertEqual(runner.calls.filter { $0.arguments.contains("-e") }.count, 2)
  }

  func testCarriesTheFailedImportReasonThrough() async throws {
    let fixture = try makeFixture()
    try makeProfile(fixture, plugins: ["dsh-memoir": "0.7.0", "dsh-emoji": "0.3.3"])
    let (probe, _) = makeProbe(fixture) { call in
      guard call.arguments.contains("-e") else { return nil }
      let askingAboutMemoir = call.arguments.contains("dsh-memoir")
      return ProcessResult(
        exitCode: 0,
        stdout: askingAboutMemoir
          ? "fail|dsh-memoir|Cannot find package '@deepseek-ai/dsh-llm' imported from /x\n"
          : "ok|dsh-emoji\n",
        stderr: "",
        duration: 0
      )
    }

    let result = await probe.probe(profile: "web", releaseID: "0.1.7-rc.1-registry-npm")

    XCTAssertEqual(result.unloadable.keys.sorted(), ["dsh-memoir"])
    XCTAssertTrue(result.unloadable["dsh-memoir"]?.contains("Cannot find package") == true)
    XCTAssertTrue(result.notes.isEmpty)
  }

  // MARK: - What may never disable anything

  /// A check process that died produced no verdict about any plugin. The sentinel must land
  /// in `notes`, because putting it in `unloadable` would quarantine a plugin the probe never
  /// even loaded.
  func testAProcessThatDiedIsANoteNotAVerdict() async throws {
    let fixture = try makeFixture()
    try makeProfile(fixture, plugins: ["dsh-memoir": "0.7.0"])
    let (probe, _) = makeProbe(fixture) { call in
      guard call.arguments.contains("-e") else { return nil }
      return ProcessResult(exitCode: 7, stdout: "", stderr: "node: bad option", duration: 0)
    }

    let result = await probe.probe(profile: "web", releaseID: "0.1.7-rc.1-registry-npm")

    XCTAssertTrue(result.unloadable.isEmpty, "no plugin may be disabled by a probe that never ran")
    XCTAssertEqual(result.notes.count, 1)
    XCTAssertTrue(result.notes[0].contains("无法判定 dsh-memoir"))
  }

  func testAReleaseWhoseEntryIsMissingIsANote() async throws {
    let fixture = try makeFixture()
    try makeProfile(fixture, plugins: ["dsh-memoir": "0.7.0"])
    let (probe, runner) = makeProbe(fixture, entry: nil) { _ in nil }

    let result = await probe.probe(profile: "web", releaseID: "0.1.7-rc.1-registry-npm")

    XCTAssertTrue(result.unloadable.isEmpty)
    XCTAssertEqual(result.notes.count, 1)
    XCTAssertTrue(result.notes[0].contains("入口不可用"), result.notes[0])
    XCTAssertTrue(
      runner.calls.filter { $0.arguments.contains("-e") }.isEmpty,
      "nothing may be probed through an entry that does not exist"
    )
  }

  func testAProfileWithNoPluginsIsANote() async throws {
    let fixture = try makeFixture()
    try TestSupport.makePluginHome(
      at: fixture.paths.dshHome,
      profile: "web",
      bundles: ["@deepseek-ai/dsh-base"],
      dependencies: [:],
      installed: [:]
    )
    let (probe, _) = makeProbe(fixture) { _ in nil }

    let result = await probe.probe(profile: "web", releaseID: "0.1.7-rc.1-registry-npm")

    XCTAssertTrue(result.unloadable.isEmpty)
    XCTAssertEqual(result.notes.count, 1)
  }

  // MARK: - The entry resolver

  func testInstallerResolvesThePrebuiltEntryOfAnInstalledRelease() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()
    let directory = paths.releaseDirectory("0.1.7-rc.1-registry-npm")
    try TestSupport.write("// stub entry", to: directory.appendingPathComponent(ReleaseValidator.prebuiltEntry))

    let installer = HarnessInstaller(paths: paths, runner: StubProcessRunner { _ in nil })
    let entry = try await installer.entryURL(forReleaseID: "0.1.7-rc.1-registry-npm")

    XCTAssertEqual(entry, directory.appendingPathComponent(ReleaseValidator.prebuiltEntry))
  }

  func testInstallerFallsBackToASourceCheckoutEntry() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()
    let directory = paths.releaseDirectory("source-build")
    try TestSupport.write("// stub entry", to: directory.appendingPathComponent(ReleaseValidator.sourceEntry))

    let installer = HarnessInstaller(paths: paths, runner: StubProcessRunner { _ in nil })
    let entry = try await installer.entryURL(forReleaseID: "source-build")

    XCTAssertEqual(entry, directory.appendingPathComponent(ReleaseValidator.sourceEntry))
  }

  func testInstallerRefusesAReleaseWithNoEntry() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()
    let installer = HarnessInstaller(paths: paths, runner: StubProcessRunner { _ in nil })

    do {
      _ = try await installer.entryURL(forReleaseID: "empty")
      XCTFail("a release with no entry must not resolve")
    } catch {
      XCTAssertTrue(String(describing: error).contains("没有可用的入口"), String(describing: error))
    }
  }

  /// The probe hands the chosen release to the process it spawns, or "against that release"
  /// would mean "against what is currently active".
  func testTheProbedReleaseIsHandedToTheChildProcess() async throws {
    let fixture = try makeFixture()
    try makeProfile(fixture, plugins: ["dsh-memoir": "0.7.0"])
    let requested = URL(fileURLWithPath: "/fake/releases/0.1.7-rc.1/node_modules/@deepseek-ai/dsh/lib/bin.js")
    let (probe, runner) = makeProbe(fixture, entry: requested) { call in
      guard call.arguments.contains("-e") else { return nil }
      return ProcessResult(exitCode: 0, stdout: "ok|dsh-memoir\n", stderr: "", duration: 0)
    }

    _ = await probe.probe(profile: "web", releaseID: "0.1.7-rc.1-registry-npm")

    XCTAssertTrue(runner.calls.contains { $0.arguments.contains("-e") }, "the check ran")
  }
}

/// An entry resolver that answers with one path, or refuses.
private struct StubReleaseProvider: ReleaseEntryProviding {
  var entry: URL?

  func entryURL(forReleaseID id: String) async throws -> URL {
    guard let entry else {
      throw RuntimeError.archiveMissingEntry("\(id) 没有入口")
    }
    return entry
  }
}
