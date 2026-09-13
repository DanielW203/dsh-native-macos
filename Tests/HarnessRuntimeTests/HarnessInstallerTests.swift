import XCTest
@testable import HarnessRuntime

final class HarnessInstallerTests: XCTestCase {
  // MARK: - Pure helpers

  func testPayloadRootAcceptsAPrebuiltLayoutAtTheRoot() throws {
    let root = try TestSupport.makeRoot(self)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try TestSupport.makePrebuiltTree(at: staging, version: "1.0.0")
    XCTAssertEqual(try HarnessInstaller.payloadRoot(in: staging, kind: .prebuiltArchive).lastPathComponent, "staging")
  }

  func testPayloadRootDescendsIntoASingleTopLevelFolder() throws {
    let root = try TestSupport.makeRoot(self)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    // What a GitHub "Download ZIP" produces: one wrapper folder, no stray files.
    try TestSupport.makeSourceTree(at: staging.appendingPathComponent("deepseek-harness-master"), version: "1.0.0")
    XCTAssertEqual(
      try HarnessInstaller.payloadRoot(in: staging, kind: .sourceArchive).lastPathComponent,
      "deepseek-harness-master"
    )
  }

  func testPayloadRootRefusesAnAmbiguousArchive() throws {
    let root = try TestSupport.makeRoot(self)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try TestSupport.makeSourceTree(at: staging.appendingPathComponent("one"), version: "1.0.0")
    try TestSupport.makeSourceTree(at: staging.appendingPathComponent("two"), version: "1.0.0")
    XCTAssertThrowsError(try HarnessInstaller.payloadRoot(in: staging, kind: .sourceArchive))
  }

  func testSwapSymlinkRepointsAtomically() throws {
    let root = try TestSupport.makeRoot(self)
    let first = root.appendingPathComponent("a", isDirectory: true)
    let second = root.appendingPathComponent("b", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("current")

    try HarnessInstaller.swapSymlink(at: link, to: first)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), first.path)
    try HarnessInstaller.swapSymlink(at: link, to: second)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), second.path)

    // The replacement must not leave scratch links behind.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".current.") }
    XCTAssertTrue(leftovers.isEmpty, "left \(leftovers) behind")
  }

  // MARK: - End to end

  /// The whole pipeline against a stubbed toolchain: copy, validate, smoke test, commit,
  /// ledger, and the `current` symlink. This is the cheapest test that would catch a
  /// regression in any of them.
  func testSourceDirectoryInstallCommitsAndActivates() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)

    let checkout = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.makeSourceTree(at: checkout, version: "0.1.5-rc.1", built: false)

    let runner = StubProcessRunner(
      realExecutables: ["ditto"],
      responder: TestSupport.sourceBuildResponder()
    )
    let installer = HarnessInstaller(paths: paths, runner: runner, baseEnvironment: ["HOME": root.path, "PATH": ""])

    let outcome = try await installer.install(.sourceDirectory(url: checkout))
    XCTAssertEqual(outcome.release.version, "0.1.5-rc.1")
    XCTAssertFalse(outcome.reused)
    XCTAssertEqual(outcome.release.entry, ReleaseValidator.sourceEntry)
    XCTAssertEqual(outcome.release.id, "0.1.5-rc.1-sourceDirectory-local")

    let active = try await installer.activeRelease()
    XCTAssertEqual(active?.id, outcome.release.id)
    let entry = try await installer.activeEntryURL()
    XCTAssertTrue(FileManager.default.isReadableFile(atPath: entry.path), "entry missing at \(entry.path)")

    // The ledger is the authority after a restart, so it must already agree.
    let reloaded = try InstallsIndex.load(from: paths.installsIndex)
    XCTAssertEqual(reloaded.active, outcome.release.id)
    XCTAssertEqual(reloaded.releases.count, 1)

    // A source install must run pnpm in staging, never in the user's checkout.
    let installs = runner.calls(matching: "pnpm").filter { $0.arguments.contains("install") }
    XCTAssertEqual(installs.count, 1)
    XCTAssertTrue(installs[0].currentDirectory?.contains("/harness/staging/") == true)
    XCTAssertTrue(runner.calls(matching: "pnpm").contains { $0.arguments == ["run", "build"] })
  }

  func testAlreadyBuiltCheckoutSkipsPnpm() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
    let checkout = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.makeSourceTree(at: checkout, version: "0.1.5-rc.1", built: true)

    let runner = StubProcessRunner(realExecutables: ["ditto"], responder: TestSupport.toolchainResponder())
    let installer = HarnessInstaller(paths: paths, runner: runner, baseEnvironment: ["HOME": root.path, "PATH": ""])
    let outcome = try await installer.install(.sourceDirectory(url: checkout))

    XCTAssertEqual(outcome.release.version, "0.1.5-rc.1")
    // A tree the user already built must not be rebuilt: it would take ten minutes to
    // arrive at the same bytes.
    XCTAssertTrue(runner.calls(matching: "pnpm").isEmpty, "an already-built checkout must not run pnpm")
  }

  func testReinstallingTheSameSourceReusesTheExistingRelease() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
    let checkout = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.makeSourceTree(at: checkout, version: "0.1.5-rc.1", built: false)

    let runner = StubProcessRunner(realExecutables: ["ditto"], responder: TestSupport.sourceBuildResponder())
    let installer = HarnessInstaller(paths: paths, runner: runner, baseEnvironment: ["HOME": root.path, "PATH": ""])

    let first = try await installer.install(.sourceDirectory(url: checkout))
    let second = try await installer.install(.sourceDirectory(url: checkout))
    XCTAssertFalse(first.reused)
    XCTAssertTrue(second.reused, "an identical version must not be installed twice")
    XCTAssertEqual(first.release.id, second.release.id)
    let installed = try await installer.releases()
    XCTAssertEqual(installed.count, 1)
  }

  func testPrebuiltArchiveInstallVerifiesTheDigest() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)

    // Build a real zip with the system tool so the zip path is exercised end to end.
    let tree = root.appendingPathComponent("payload", isDirectory: true)
    try TestSupport.makePrebuiltTree(at: tree, version: "0.1.1-rc.2")
    let zip = root.appendingPathComponent("pkg.zip")
    let real = ProcessRunner()
    let zipResult = try await real.run(ProcessRequest(
      executable: URL(fileURLWithPath: "/usr/bin/ditto"),
      arguments: ["-c", "-k", "--keepParent", tree.path, zip.path],
      timeout: 120,
      label: "ditto -c -k"
    ))
    try XCTSkipUnless(zipResult.succeeded, "ditto could not build a fixture zip: \(zipResult.diagnostics())")

    let digest = try ArchiveInspector.sha256(of: zip)
    let runner = StubProcessRunner(
      realExecutables: ["ditto", "unzip"],
      responder: TestSupport.toolchainResponder(dshVersion: "0.1.1-rc.2")
    )
    let installer = HarnessInstaller(paths: paths, runner: runner, baseEnvironment: ["HOME": root.path, "PATH": ""])

    let outcome = try await installer.install(.prebuiltArchive(url: zip, expectedDigest: "sha256:\(digest)"))
    XCTAssertTrue(outcome.release.integrity.verified)
    XCTAssertEqual(outcome.release.integrity.origin, .sidecar)
    XCTAssertEqual(outcome.release.entry, ReleaseValidator.prebuiltEntry)
    XCTAssertTrue(outcome.warnings.isEmpty)

    // The wrapper folder is stripped, so the entry sits at the release root.
    let entry = try await installer.activeEntryURL()
    XCTAssertTrue(entry.path.hasSuffix(ReleaseValidator.prebuiltEntry))
    XCTAssertTrue(FileManager.default.isReadableFile(atPath: entry.path))
  }

  func testDigestMismatchAbortsBeforeExtraction() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
    let tree = root.appendingPathComponent("payload", isDirectory: true)
    try TestSupport.makePrebuiltTree(at: tree, version: "0.1.1-rc.2")
    let zip = root.appendingPathComponent("pkg.zip")
    let real = ProcessRunner()
    let zipResult = try await real.run(ProcessRequest(
      executable: URL(fileURLWithPath: "/usr/bin/ditto"),
      arguments: ["-c", "-k", "--keepParent", tree.path, zip.path],
      timeout: 120,
      label: "ditto -c -k"
    ))
    try XCTSkipUnless(zipResult.succeeded, "ditto could not build a fixture zip")

    let runner = StubProcessRunner(realExecutables: ["ditto", "unzip"], responder: TestSupport.toolchainResponder())
    let installer = HarnessInstaller(paths: paths, runner: runner, baseEnvironment: ["HOME": root.path, "PATH": ""])

    do {
      _ = try await installer.install(.prebuiltArchive(url: zip, expectedDigest: String(repeating: "0", count: 64)))
      XCTFail("a digest mismatch must not install")
    } catch let error as RuntimeError {
      XCTAssertEqual(error.code, "INTEGRITY_CHECK_FAILED")
    }
    let activeAfterFailure = try await installer.activeRelease()
    XCTAssertNil(activeAfterFailure)
    let installedAfterFailure = try await installer.releases()
    XCTAssertEqual(installedAfterFailure.count, 0)
  }

  func testMaliciousArchiveIsRejectedBeforeAnyWrite() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)

    let tree = root.appendingPathComponent("payload", isDirectory: true)
    try TestSupport.makePrebuiltTree(at: tree, version: "0.1.1-rc.2")
    let zip = root.appendingPathComponent("evil.zip")
    let real = ProcessRunner()
    let zipResult = try await real.run(ProcessRequest(
      executable: URL(fileURLWithPath: "/usr/bin/ditto"),
      arguments: ["-c", "-k", "--keepParent", tree.path, zip.path],
      timeout: 120,
      label: "ditto -c -k"
    ))
    try XCTSkipUnless(zipResult.succeeded, "ditto could not build a fixture zip")

    let runner = StubProcessRunner(realExecutables: ["ditto"]) { call in
      // Pretend unzip lists an escaping entry; extraction must never be reached.
      if call.executable.hasSuffix("unzip") {
        return .ok("../escaped\nnode_modules/@deepseek-ai/dsh/lib/bin.js\n")
      }
      return TestSupport.toolchainResponder()(call)
    }
    let installer = HarnessInstaller(paths: paths, runner: runner, baseEnvironment: ["HOME": root.path, "PATH": ""])

    do {
      _ = try await installer.install(.prebuiltArchive(url: zip, expectedDigest: nil))
      XCTFail("an archive with a traversal entry must not install")
    } catch let error as RuntimeError {
      XCTAssertEqual(error.code, "ARCHIVE_REJECTED")
    }
    XCTAssertFalse(runner.calls.contains { $0.executable.hasSuffix("ditto") && $0.arguments.contains("-x") },
                   "extraction must not run for a rejected archive")
  }

  // MARK: - Ledger operations

  func testActiveReleaseCannotBeRemoved() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
    let checkout = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.makeSourceTree(at: checkout, version: "0.1.5-rc.1", built: false)

    let runner = StubProcessRunner(realExecutables: ["ditto"], responder: TestSupport.sourceBuildResponder())
    let installer = HarnessInstaller(paths: paths, runner: runner, baseEnvironment: ["HOME": root.path, "PATH": ""])
    let outcome = try await installer.install(.sourceDirectory(url: checkout))

    do {
      try await installer.remove(outcome.release.id)
      XCTFail("removing the active release would leave current dangling")
    } catch let error as RuntimeError {
      XCTAssertEqual(error.code, "RELEASE_IN_USE")
    }
  }

  func testActivatingAnUnknownReleaseIsRejected() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    let installer = HarnessInstaller(paths: paths, runner: StubProcessRunner { _ in nil }, baseEnvironment: [:])
    do {
      try await installer.activate("nope")
      XCTFail("activating a release that is not installed must fail")
    } catch let error as RuntimeError {
      XCTAssertEqual(error.code, "RELEASE_NOT_FOUND")
    }
  }

  func testActiveReleaseIsAbsentWhenItsDirectoryWasDeletedByHand() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
    let checkout = root.appendingPathComponent("checkout", isDirectory: true)
    try TestSupport.makeSourceTree(at: checkout, version: "0.1.5-rc.1", built: false)

    let runner = StubProcessRunner(realExecutables: ["ditto"], responder: TestSupport.sourceBuildResponder())
    let installer = HarnessInstaller(paths: paths, runner: runner, baseEnvironment: ["HOME": root.path, "PATH": ""])
    let outcome = try await installer.install(.sourceDirectory(url: checkout))
    try FileManager.default.removeItem(at: paths.releaseDirectory(outcome.release.id))

    // Reported as absent rather than handed back as a path that cannot be executed.
    let active = try await installer.activeRelease()
    XCTAssertNil(active)
    do {
      _ = try await installer.activeEntryURL()
      XCTFail("a release whose directory is gone must not yield an entry point")
    } catch let error as RuntimeError {
      XCTAssertEqual(error.code, "NO_ACTIVE_RELEASE")
    }
  }
}
