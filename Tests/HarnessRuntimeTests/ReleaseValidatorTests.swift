import XCTest
@testable import HarnessRuntime

final class ReleaseValidatorTests: XCTestCase {
  private let validator = ReleaseValidator(runner: StubProcessRunner { _ in nil })

  func testEntryPathDependsOnSourceKind() {
    // The two layouts genuinely differ; guessing here would produce an install that
    // cannot start.
    XCTAssertEqual(ReleaseValidator.entryPath(for: .prebuiltArchive), "node_modules/@deepseek-ai/dsh/lib/bin.js")
    XCTAssertEqual(ReleaseValidator.entryPath(for: .registry), "node_modules/@deepseek-ai/dsh/lib/bin.js")
    XCTAssertEqual(ReleaseValidator.entryPath(for: .githubRelease), "node_modules/@deepseek-ai/dsh/lib/bin.js")
    XCTAssertEqual(ReleaseValidator.entryPath(for: .sourceArchive), "apps/cli/lib/bin.js")
    XCTAssertEqual(ReleaseValidator.entryPath(for: .sourceDirectory), "apps/cli/lib/bin.js")
  }

  func testReadsVersionFromAPrebuiltTree() throws {
    let root = try TestSupport.makeRoot(self)
    try TestSupport.makePrebuiltTree(at: root, version: "0.1.1-rc.2")
    XCTAssertEqual(try validator.validate(directory: root, kind: .prebuiltArchive), "0.1.1-rc.2")
  }

  func testReadsVersionFromASourceTree() throws {
    let root = try TestSupport.makeRoot(self)
    try TestSupport.makeSourceTree(at: root, version: "0.1.5-rc.1")
    XCTAssertEqual(try validator.validate(directory: root, kind: .sourceArchive), "0.1.5-rc.1")
  }

  func testMissingEntryIsNamedPrecisely() throws {
    let root = try TestSupport.makeRoot(self)
    try TestSupport.write("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"1.0.0\"}",
                          to: root.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json"))
    XCTAssertThrowsError(try validator.validate(directory: root, kind: .prebuiltArchive)) { error in
      guard case RuntimeError.archiveMissingEntry(let path) = error else {
        return XCTFail("expected archiveMissingEntry, got \(error)")
      }
      XCTAssertEqual(path, ReleaseValidator.prebuiltEntry)
    }
  }

  func testEmptyEntryFileIsRejected() throws {
    let root = try TestSupport.makeRoot(self)
    try TestSupport.makePrebuiltTree(at: root, version: "1.0.0")
    try TestSupport.write("", to: root.appendingPathComponent(ReleaseValidator.prebuiltEntry))
    XCTAssertThrowsError(try validator.validate(directory: root, kind: .prebuiltArchive))
  }

  func testManifestWithoutVersionIsRejected() throws {
    let root = try TestSupport.makeRoot(self)
    try TestSupport.write("{\"name\":\"@deepseek-ai/dsh\"}",
                          to: root.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json"))
    try TestSupport.write("// entry", to: root.appendingPathComponent(ReleaseValidator.prebuiltEntry))
    XCTAssertThrowsError(try validator.validate(directory: root, kind: .prebuiltArchive))
  }

  func testSmokeTestSurfacesAFailureWithDiagnostics() async throws {
    let root = try TestSupport.makeRoot(self)
    try TestSupport.makePrebuiltTree(at: root, version: "1.0.0")
    let runner = StubProcessRunner { _ in .failure(1, stderr: "Cannot find module") }
    let failing = ReleaseValidator(runner: runner)

    do {
      _ = try await failing.smokeTest(
        directory: root,
        kind: .prebuiltArchive,
        node: URL(fileURLWithPath: "/usr/bin/true"),
        environment: [:]
      )
      XCTFail("a runtime that cannot start must not validate")
    } catch let error as RuntimeError {
      XCTAssertEqual(error.code, "INSTALL_FAILED")
    }
  }
}
