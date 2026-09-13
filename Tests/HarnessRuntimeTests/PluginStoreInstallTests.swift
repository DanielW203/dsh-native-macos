import Foundation
import XCTest
@testable import HarnessRuntime

/// The install path: what `addPlugin` actually asks the harness CLI to do.
///
/// The interesting behaviour is entirely in the arguments and in what is refused before a
/// subprocess runs, so every test stubs the process boundary and asserts on the calls that
/// were made — a real install would need pnpm, the network, and a writable harness home.
final class PluginStoreInstallTests: XCTestCase {
  private var root: URL!
  private var paths: RuntimePaths!

  override func setUpWithError() throws {
    root = try TestSupport.makeRoot(self)
    paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
  }

  /// A store whose toolchain resolution is answered from the shared table and whose other
  /// subprocesses come from `responder`.
  ///
  /// The toolchain check runs through the same runner as the install, so a responder that
  /// only knows about the plugin command would fail earlier, on `node --version`.
  private func makeStore(
    entry: URL = URL(fileURLWithPath: "/fake/dsh/lib/bin.js"),
    responder: @escaping @Sendable (StubProcessRunner.Call) -> ProcessResult? = { _ in nil }
  ) -> (PluginStore, StubProcessRunner) {
    let toolchain = TestSupport.toolchainResponder()
    let runner = StubProcessRunner(realExecutables: []) { call in
      responder(call) ?? toolchain(call)
    }
    let store = PluginStore(paths: paths, entryProvider: { entry }, runner: runner)
    return (store, runner)
  }

  /// The `dsh plugin --profile <p> add <spec>` invocation, as arguments.
  ///
  /// The CLI runs as `<node> <entry> plugin …`, so the entry script the toolchain prepends
  /// is dropped: it is the toolchain's business, not this call's.
  private func addArguments(_ calls: [StubProcessRunner.Call]) -> [String]? {
    guard let call = calls.first(where: isPluginCall) else { return nil }
    return Array(call.arguments.dropFirst())
  }

  /// Whether a call is the plugin subcommand.
  private func isPluginCall(_ call: StubProcessRunner.Call) -> Bool {
    call.arguments.count >= 2 && call.arguments[1] == "plugin"
  }

  func testInstallsALocalDirectoryAsALink() async throws {
    let package = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.write("{\"name\":\"dsh-skin-manager\",\"version\":\"0.1.7\"}",
                          to: package.appendingPathComponent("package.json"))
    let (store, runner) = makeStore { call in
      self.isPluginCall(call) ? .ok("+ dsh-skin-manager 0.1.7\n") : nil
    }

    let outcome = try await store.addPlugin(.localDirectory(package), profile: "web")

    let expected = "link:\(package.standardizedFileURL.path)"
    XCTAssertEqual(outcome.spec, expected)
    XCTAssertEqual(addArguments(runner.calls), ["plugin", "--profile", "web", "add", expected])
    XCTAssertEqual(runner.calls.filter(isPluginCall).count, 1, "an install is exactly one CLI invocation")
    XCTAssertTrue(outcome.warnings.isEmpty)
  }

  func testInstallsAnArchiveAsAFile() async throws {
    let archive = try TestSupport.write("not really a tarball", to: root.appendingPathComponent("plugin.tgz"))
    let (store, runner) = makeStore()

    let outcome = try await store.addPlugin(.localArchive(archive), profile: "web")

    XCTAssertEqual(outcome.spec, "file:\(archive.standardizedFileURL.path)")
    XCTAssertEqual(
      addArguments(runner.calls)?.last,
      "file:\(archive.standardizedFileURL.path)"
    )
  }

  func testPassesASpecifierThroughVerbatim() async throws {
    let (store, runner) = makeStore()

    _ = try await store.addPlugin(.specifier("github:xiaoyangcheng84-svg/dsh-skin-manager"), profile: "rescue")

    XCTAssertEqual(
      addArguments(runner.calls),
      ["plugin", "--profile", "rescue", "add", "github:xiaoyangcheng84-svg/dsh-skin-manager"]
    )
  }

  func testRefusesADirectoryWithoutAPackageManifest() async throws {
    let empty = root.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let (store, runner) = makeStore()

    do {
      _ = try await store.addPlugin(.localDirectory(empty), profile: "web")
      XCTFail("expected the install to be refused")
    } catch let error as RuntimeError {
      guard case .installFailed(_, let detail) = error else {
        return XCTFail("expected installFailed, got \(error)")
      }
      XCTAssertTrue(detail.contains("package.json"), detail)
    }
    XCTAssertTrue(runner.calls.filter(isPluginCall).isEmpty, "a refusal must not run pnpm")
  }

  func testRefusesAMissingDirectory() async throws {
    let (store, runner) = makeStore()

    do {
      _ = try await store.addPlugin(.localDirectory(root.appendingPathComponent("nope")), profile: "web")
      XCTFail("expected the install to be refused")
    } catch let error as RuntimeError {
      guard case .installFailed(_, let detail) = error else {
        return XCTFail("expected installFailed, got \(error)")
      }
      XCTAssertTrue(detail.contains("not a directory"), detail)
    }
    XCTAssertTrue(runner.calls.filter(isPluginCall).isEmpty)
  }

  func testRefusesAnEmptyOrWhitespaceSpecifier() async throws {
    let (store, runner) = makeStore()

    for text in ["", "   ", "two words"] {
      do {
        _ = try await store.addPlugin(.specifier(text), profile: "web")
        XCTFail("expected \(text.debugDescription) to be refused")
      } catch let error as RuntimeError {
        guard case .installFailed = error else {
          return XCTFail("expected installFailed, got \(error)")
        }
      }
    }
    XCTAssertTrue(runner.calls.filter(isPluginCall).isEmpty)
  }

  func testReportsTheInstallOutputWhenPnpmFails() async throws {
    let package = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.write("{\"name\":\"dsh-skin-manager\"}", to: package.appendingPathComponent("package.json"))
    let (store, _) = makeStore { call in
      self.isPluginCall(call)
        ? .failure(1, stderr: "ERR_PNPM_FETCH_404  GET https://registry.npmjs.org/broken: Not Found")
        : nil
    }

    do {
      _ = try await store.addPlugin(.localDirectory(package), profile: "web")
      XCTFail("expected the install to fail")
    } catch let error as RuntimeError {
      guard case .installFailed(let step, let detail) = error else {
        return XCTFail("expected installFailed, got \(error)")
      }
      XCTAssertTrue(step.contains("install"), step)
      XCTAssertTrue(detail.contains("ERR_PNPM_FETCH_404"), detail)
    }
  }

  func testWarnsAboutBuildScriptsPnpmSkipped() async throws {
    let package = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.write("{\"name\":\"dsh-skin-manager\"}", to: package.appendingPathComponent("package.json"))
    let (store, _) = makeStore { call in
      self.isPluginCall(call) ? .ok("Ignored build scripts: koffi, better-sqlite3.\n") : nil
    }

    let outcome = try await store.addPlugin(.localDirectory(package), profile: "web")

    XCTAssertEqual(outcome.warnings.count, 1)
    let warning = try XCTUnwrap(outcome.warnings.first)
    XCTAssertTrue(warning.contains("koffi"), warning)
    XCTAssertTrue(warning.contains("better-sqlite3"), warning)
    XCTAssertTrue(warning.contains("allowBuilds"), warning)
  }

  // MARK: - pnpm's release-age gate

  func testReportsAReleaseAgeRefusalAsOverridable() async throws {
    let package = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.write("{\"name\":\"dsh-skin-manager\"}", to: package.appendingPathComponent("package.json"))
    let (store, runner) = makeStore { call in
      self.isPluginCall(call) ? .failure(1, stderr: releaseAgeRefusalOutput) : nil
    }

    do {
      _ = try await store.addPlugin(.localDirectory(package), profile: "web")
      XCTFail("expected the install to be refused")
    } catch let error as RuntimeError {
      guard case .youngReleaseBlocked(let packages, let detail) = error else {
        return XCTFail("expected youngReleaseBlocked, got \(error)")
      }
      XCTAssertEqual(packages, ["dsh-context@0.49.1", "dsh-emoji@0.3.3", "dsh-memoir@0.7.0"])
      XCTAssertTrue(detail.contains("ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION"), detail)
      XCTAssertEqual(error.code, "YOUNG_RELEASE_BLOCKED")
    }

    // A refusal nobody has answered yet is still one command with the gate in force: the
    // override is the caller's decision, never this path's.
    XCTAssertEqual(
      addArguments(runner.calls),
      ["plugin", "--profile", "web", "add", "link:\(package.standardizedFileURL.path)"]
    )
  }

  func testOverridePolicyPassesTheOneShotFlag() async throws {
    let package = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.write("{\"name\":\"dsh-skin-manager\",\"version\":\"0.1.7\"}",
                          to: package.appendingPathComponent("package.json"))
    let (store, runner) = makeStore { call in
      self.isPluginCall(call) ? .ok("+ dsh-skin-manager 0.1.7\n") : nil
    }

    let outcome = try await store.addPlugin(
      .localDirectory(package),
      profile: "web",
      policy: .allowYoungReleases
    )

    let spec = "link:\(package.standardizedFileURL.path)"
    XCTAssertEqual(outcome.spec, spec)
    XCTAssertEqual(
      addArguments(runner.calls),
      ["plugin", "--profile", "web", "add", "--config.minimumReleaseAge=0", spec]
    )
  }

  func testOverridePolicyReportsALingeringRefusalAsAPlainFailure() async throws {
    // The override can fail too. It must not come back as another overridable refusal, or
    // the console would ask the same question forever.
    let package = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.write("{\"name\":\"dsh-skin-manager\"}", to: package.appendingPathComponent("package.json"))
    let (store, _) = makeStore { call in
      self.isPluginCall(call) ? .failure(1, stderr: releaseAgeRefusalOutput) : nil
    }

    do {
      _ = try await store.addPlugin(.localDirectory(package), profile: "web", policy: .allowYoungReleases)
      XCTFail("expected the install to fail")
    } catch let error as RuntimeError {
      guard case .installFailed(_, let detail) = error else {
        return XCTFail("expected installFailed, got \(error)")
      }
      XCTAssertTrue(detail.contains("MINIMUM_RELEASE_AGE"), detail)
    }
  }

  func testReportsTheResolverRefusalWithoutAListAsOverridable() async throws {
    // The second code pnpm reports for the same cause, and it names no entries: the console
    // still has to be able to offer the override, so the package list may legitimately be
    // empty and the parse must not invent names for it.
    let (store, _) = makeStore { call in
      self.isPluginCall(call)
        ? .failure(1, stderr: "ERR_PNPM_NO_MATURE_MATCHING_VERSION  No matching version found for dsh-context@^0.49.0")
        : nil
    }

    do {
      _ = try await store.addPlugin(.specifier("dsh-context@^0.49.0"), profile: "web")
      XCTFail("expected the install to be refused")
    } catch let error as RuntimeError {
      guard case .youngReleaseBlocked(let packages, _) = error else {
        return XCTFail("expected youngReleaseBlocked, got \(error)")
      }
      XCTAssertTrue(packages.isEmpty, "\(packages)")
    }
  }
}

/// pnpm's release-age refusal, verbatim from a real run against a profile whose lockfile
/// held three releases younger than pnpm 11.22's built-in 24-hour gate.
///
/// The shape matters: the entries are an indented list under a header, one line each, and
/// the package is named at the start of its reason. The console reads names out of this, so
/// the fixture is the real text rather than a paraphrase of it.
private let releaseAgeRefusalOutput = """
? Verifying lockfile against supply-chain policies (152 entries)...
✗ Lockfile failed supply-chain policy check (152 entries in 2s)
[ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION] 3 lockfile entries failed verification:
  dsh-context@0.49.1 was published at 2026-09-10T10:02:24.000Z, within the minimumReleaseAge cutoff (2026-09-10T05:05:48.505Z)
  dsh-emoji@0.3.3 was published at 2026-09-10T09:32:23.000Z, within the minimumReleaseAge cutoff (2026-09-10T05:05:48.505Z)
  dsh-memoir@0.7.0 was published at 2026-09-10T09:10:18.000Z, within the minimumReleaseAge cutoff (2026-09-10T05:05:48.505Z)
"""
