import XCTest
@testable import HarnessRuntime

final class PnpmDiagnosticsTests: XCTestCase {
  func testStripsANSIColourSequences() {
    let coloured = "\u{1B}[33mIgnored\u{1B}[39m build scripts: node-pty."
    XCTAssertEqual(PnpmDiagnostics.stripANSI(coloured), "Ignored build scripts: node-pty.")
  }

  func testExtractsIgnoredBuildScripts() {
    // The real warning pnpm prints when it skips a native build.
    let output = """
      \u{1B}[33m╭ Warning ─────────────────────────────────╮\u{1B}[39m
      │   Ignored build scripts: node-pty, esbuild.   │
      │   Run "pnpm approve-builds" to pick which…    │
      """
    guard case .ignoredBuilds(let list) = PnpmDiagnostics.classify(output) else {
      return XCTFail("expected an ignored-builds refusal")
    }
    XCTAssertEqual(list.packages, ["esbuild", "node-pty"])
  }

  func testClassifiesGitPrepareRefusal() {
    let output = """
      ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED  The git-hosted package failed
      Add "my-git-plugin" to "allowBuilds" in pnpm-workspace.yaml to allow it
      """
    guard case .gitPrepareNotAllowed(let list) = PnpmDiagnostics.classify(output) else {
      return XCTFail("expected a git prepare refusal, got \(PnpmDiagnostics.classify(output))")
    }
    XCTAssertTrue(list.packages.contains("my-git-plugin"))
  }

  func testReportsRecognizedRefusalWithoutInventingNames() {
    // No package names anywhere. Guessing here would write a wrong allow-list into the
    // user's profile, so the classifier refuses to guess.
    let output = "ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED something went wrong"
    guard case .unrecognized = PnpmDiagnostics.classify(output) else {
      return XCTFail("expected unrecognized")
    }
  }

  func testUnrelatedOutputIsNotMisclassified() {
    XCTAssertEqual(PnpmDiagnostics.classify("Done in 12.3s"), .unrelated)
    XCTAssertEqual(PnpmDiagnostics.classify(""), .unrelated)
  }

  func testPackageNameShapeIsConservative() {
    XCTAssertTrue(PnpmDiagnostics.isPackageName("node-pty"))
    XCTAssertTrue(PnpmDiagnostics.isPackageName("@deepseek-ai/dsh-base"))
    XCTAssertTrue(PnpmDiagnostics.isPackageName("better-sqlite3"))

    XCTAssertFalse(PnpmDiagnostics.isPackageName(""))
    XCTAssertFalse(PnpmDiagnostics.isPackageName("2"))
    XCTAssertFalse(PnpmDiagnostics.isPackageName("-flag"))
    XCTAssertFalse(PnpmDiagnostics.isPackageName("./relative"))
    XCTAssertFalse(PnpmDiagnostics.isPackageName("/absolute/path"))
    XCTAssertFalse(PnpmDiagnostics.isPackageName("has space"))
    XCTAssertFalse(PnpmDiagnostics.isPackageName("Upper.Case"))
  }

  func testIgnoredBuildScriptsDropsTrailingPunctuation() {
    guard case .ignoredBuilds(let list) = PnpmDiagnostics.classify("Ignored build scripts: a-pkg, b-pkg.") else {
      return XCTFail("expected ignored builds")
    }
    XCTAssertEqual(list.packages, ["a-pkg", "b-pkg"])
  }
}
