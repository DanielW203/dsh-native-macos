import Foundation
import XCTest
@testable import HarnessRuntime

/// Creating the plugin-free profile a `rescue` start boots.
///
/// The behaviour worth pinning is the "create once" rule: the harness refuses to
/// initialize into an existing directory, and re-creating a profile a user has since
/// edited would silently undo their change.
final class RescueProfileInstallerTests: XCTestCase {
  private var root: URL!
  private var paths: RuntimePaths!

  override func setUpWithError() throws {
    root = try TestSupport.makeRoot(self)
    paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
  }

  private func makeInstaller(
    entry: URL = URL(fileURLWithPath: "/fake/dsh/lib/bin.js"),
    responder: @escaping @Sendable (StubProcessRunner.Call) -> ProcessResult? = { _ in nil }
  ) -> (RescueProfileInstaller, StubProcessRunner) {
    let toolchain = TestSupport.toolchainResponder()
    let runner = StubProcessRunner(realExecutables: []) { call in
      responder(call) ?? toolchain(call)
    }
    let installer = RescueProfileInstaller(
      paths: paths,
      entryProvider: { entry },
      runner: runner,
      baseEnvironment: [:]
    )
    return (installer, runner)
  }

  /// The `--from-default-profile` invocation, as arguments, entry script dropped.
  private func initializeArguments(_ calls: [StubProcessRunner.Call]) -> [String]? {
    guard let call = calls.first(where: { $0.arguments.contains("--from-default-profile") }) else {
      return nil
    }
    return Array(call.arguments.dropFirst())
  }

  private func writeProfileManifest(_ name: String) throws {
    try TestSupport.write("{}", to: paths.profilesDirectory
      .appendingPathComponent(name, isDirectory: true)
      .appendingPathComponent("package.json"))
  }

  func testCreatesAMissingProfileFromTheShippedTemplate() async throws {
    let (installer, runner) = makeInstaller { call in
      call.arguments.contains("--from-default-profile") ? .ok("composed tree\n") : nil
    }

    let note = try await installer.ensureProfile(named: "rescue", template: "web")

    XCTAssertEqual(
      initializeArguments(runner.calls),
      ["--profile", "rescue", "--from-default-profile", "web", "--dump-config"]
    )
    // `--dump-config` is what makes this an initialization that boots nothing: the real
    // contract is "initialize a missing profile, print the composed tree, exit".
    XCTAssertNil(runner.calls.first(where: { $0.arguments.contains("--no-open") }))
    XCTAssertEqual(runner.calls.filter { $0.arguments.contains("--from-default-profile") }.count, 1)
    XCTAssertNotNil(note)
    XCTAssertTrue(try XCTUnwrap(note).contains("rescue"))
  }

  func testAnExistingProfileIsLeftAlone() async throws {
    try writeProfileManifest("rescue")
    let (installer, runner) = makeInstaller()

    let note = try await installer.ensureProfile(named: "rescue", template: "web")

    XCTAssertNil(note)
    XCTAssertTrue(runner.calls.isEmpty, "an existing profile must not be re-initialized")
  }

  /// An empty directory is not a profile: the harness keys on `package.json`, and skipping
  /// creation here would surface much later as a boot error with no visible cause.
  func testAnEmptyProfileDirectoryIsStillInitialized() async throws {
    try FileManager.default.createDirectory(
      at: paths.profilesDirectory.appendingPathComponent("rescue", isDirectory: true),
      withIntermediateDirectories: true
    )
    let (installer, runner) = makeInstaller { call in
      call.arguments.contains("--from-default-profile") ? .ok("") : nil
    }

    let note = try await installer.ensureProfile(named: "rescue", template: "web")

    XCTAssertNotNil(note)
    XCTAssertEqual(runner.calls.filter { $0.arguments.contains("--from-default-profile") }.count, 1)
  }

  /// Losing a race with a second launch is not a failure: if the CLI refused because the
  /// profile appeared underneath it, the profile is ready and this must not throw.
  func testAFailedRunThatLeftAProfileBehindIsTolerated() async throws {
    let (installer, _) = makeInstaller { call in
      guard call.arguments.contains("--from-default-profile") else { return nil }
      try? self.writeProfileManifest("rescue")
      return .failure(1, stderr: "profile \"rescue\" already exists")
    }

    let note = try await installer.ensureProfile(named: "rescue", template: "web")

    XCTAssertNotNil(note)
  }

  func testAFailedRunWithoutAProfileIsReported() async throws {
    let (installer, _) = makeInstaller { call in
      call.arguments.contains("--from-default-profile")
        ? .failure(1, stderr: "no space left on device")
        : nil
    }

    do {
      _ = try await installer.ensureProfile(named: "rescue", template: "web")
      XCTFail("expected the failure to be reported")
    } catch {
      XCTAssertTrue(String(describing: error).contains("no space left"))
    }
  }

  func testProfileExistsKeysOnTheManifest() throws {
    XCTAssertFalse(RescueProfileInstaller.profileExists("rescue", in: paths))
    try FileManager.default.createDirectory(
      at: paths.profilesDirectory.appendingPathComponent("rescue", isDirectory: true),
      withIntermediateDirectories: true
    )
    XCTAssertFalse(RescueProfileInstaller.profileExists("rescue", in: paths))
    try writeProfileManifest("rescue")
    XCTAssertTrue(RescueProfileInstaller.profileExists("rescue", in: paths))
  }
}
