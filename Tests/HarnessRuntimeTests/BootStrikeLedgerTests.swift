import XCTest
@testable import HarnessRuntime

/// The consecutive-failure ledger.
///
/// It exists because the failure it counts happens *between* launches, so the tests are about
/// what survives a process: an increment that is there next time, a clear that really clears,
/// and a file this build cannot read being treated as nothing rather than as a reason to
/// escalate.
final class BootStrikeLedgerTests: XCTestCase {
  private func makeLedger(_ testCase: XCTestCase) throws -> (BootStrikeLedger, RuntimePaths) {
    let root = try TestSupport.makeRoot(testCase)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()
    return (BootStrikeLedger(paths: paths), paths)
  }

  func testCountsConsecutiveFailuresPerRelease() throws {
    let (ledger, _) = try makeLedger(self)

    XCTAssertEqual(ledger.count(forReleaseID: "a"), 0)
    XCTAssertEqual(ledger.recordStrike(forReleaseID: "a"), 1)
    XCTAssertEqual(ledger.recordStrike(forReleaseID: "a"), 2)
    XCTAssertEqual(ledger.recordStrike(forReleaseID: "b"), 1)

    // A fresh reader — the next launch — sees the same numbers.
    let reopened = BootStrikeLedger(url: ledger.url)
    XCTAssertEqual(reopened.count(forReleaseID: "a"), 2)
    XCTAssertEqual(reopened.count(forReleaseID: "b"), 1)
  }

  func testRecordsWhatTheLastAttemptGotTo() throws {
    let (ledger, _) = try makeLedger(self)

    _ = ledger.recordStrike(forReleaseID: "a", stage: "booting")
    _ = ledger.recordStrike(forReleaseID: "a", stage: "verifying")

    XCTAssertEqual(ledger.entries()["a"]?.lastStage, "verifying")
    XCTAssertNotNil(ledger.entries()["a"]?.firstAt)
  }

  func testClearingOneReleaseLeavesTheOthers() throws {
    let (ledger, _) = try makeLedger(self)
    _ = ledger.recordStrike(forReleaseID: "a")
    _ = ledger.recordStrike(forReleaseID: "b")

    ledger.clear("a")

    XCTAssertEqual(ledger.count(forReleaseID: "a"), 0)
    XCTAssertEqual(ledger.count(forReleaseID: "b"), 1)
  }

  func testClearAllRemovesTheFile() throws {
    let (ledger, _) = try makeLedger(self)
    _ = ledger.recordStrike(forReleaseID: "a")

    ledger.clearAll()

    XCTAssertTrue(ledger.entries().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.url.path))
  }

  /// A ledger that cannot be read must not become an escalation: misparsing would send a
  /// user to Safe Mode for a healthy runtime.
  func testAnUnreadableFileReadsAsNoStrikes() throws {
    let (ledger, _) = try makeLedger(self)
    try Data("{ not json".utf8).write(to: ledger.url)

    XCTAssertTrue(ledger.entries().isEmpty)
    XCTAssertEqual(ledger.count(forReleaseID: "a"), 0)

    // And it recovers: the next strike writes a readable file.
    XCTAssertEqual(ledger.recordStrike(forReleaseID: "a"), 1)
    XCTAssertEqual(ledger.count(forReleaseID: "a"), 1)
  }

  func testANewerSchemaReadsAsNoStrikes() throws {
    let (ledger, _) = try makeLedger(self)
    try Data(#"{"schemaVersion":99,"strikes":{"a":{"count":2,"firstAt":0,"lastAt":0}}}"#.utf8)
      .write(to: ledger.url)

    XCTAssertEqual(ledger.count(forReleaseID: "a"), 0)
  }
}
