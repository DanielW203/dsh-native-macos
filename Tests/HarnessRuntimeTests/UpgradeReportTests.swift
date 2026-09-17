import XCTest
@testable import HarnessRuntime

final class UpgradeReportTests: XCTestCase {
  private func makeStore(_ testCase: XCTestCase) throws -> UpgradeReportStore {
    let root = try TestSupport.makeRoot(testCase)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()
    return UpgradeReportStore(paths: paths)
  }

  private func makeReport(
    outcome: UpgradeReport.Outcome = .kept,
    checks: [HarnessCheckResult] = []
  ) -> UpgradeReport {
    UpgradeReport(
      fromReleaseID: "0.1.5-rc.1-registry-npm",
      toReleaseID: "0.1.5-rc.2-registry-npm",
      finishedAt: Date(timeIntervalSince1970: 1_780_000_000),
      outcome: outcome,
      summary: "summary text",
      bootFailure: outcome == .rolledBack ? "the harness exited with code 1" : nil,
      checks: checks,
      notes: ["a note"]
    )
  }

  func testMissingReportLoadsAsNil() throws {
    let store = try makeStore(self)
    XCTAssertNil(store.loadLatest())
  }

  func testRoundTripPreservesEveryField() throws {
    let store = try makeStore(self)
    let report = makeReport(
      outcome: .rolledBack,
      checks: [
        HarnessCheckResult(name: "boot", verdict: .fail, detail: "exited 1", isBlocking: true),
        HarnessCheckResult(name: "session-log", verdict: .warn, detail: "no log", isBlocking: false),
      ]
    )
    try store.save(report)

    guard let loaded = store.loadLatest() else { return XCTFail("expected a report") }
    XCTAssertEqual(loaded, report)
  }

  /// A corrupt *report* costs nothing to ignore: the ledger still records which release is
  /// active, and this file only explains how it got there.
  func testCorruptReportLoadsAsNilRatherThanThrowing() throws {
    let store = try makeStore(self)
    try Data("not json at all".utf8).write(to: store.latestURL)
    XCTAssertNil(store.loadLatest())
  }

  func testNewerSchemaVersionIsRefused() throws {
    let store = try makeStore(self)
    var report = makeReport()
    report.schemaVersion = UpgradeReport.currentSchemaVersion + 1
    // Written through the encoder directly so `save`'s own validation is not what is tested.
    try AtomicFile.write(try AtomicFile.makeEncoder().encode(report), to: store.latestURL)
    XCTAssertNil(store.loadLatest())
  }

  func testBlockingFailuresAndConcernsAreSeparated() throws {
    let report = makeReport(
      checks: [
        HarnessCheckResult(name: "boot", verdict: .pass, detail: "", isBlocking: true),
        HarnessCheckResult(name: "plugins", verdict: .fail, detail: "", isBlocking: false),
        HarnessCheckResult(name: "rpc", verdict: .fail, detail: "", isBlocking: true),
        HarnessCheckResult(name: "log", verdict: .warn, detail: "", isBlocking: false),
      ]
    )
    XCTAssertEqual(report.blockingFailures.map(\.name), ["rpc"])
    XCTAssertEqual(report.concerns.map(\.name), ["plugins", "rpc", "log"])
  }

  func testSavingKeepsAHistoryAndPrunesIt() throws {
    let store = try makeStore(self)
    for offset in 0..<(UpgradeReportStore.keepCount + 4) {
      var report = makeReport()
      report.finishedAt = Date(timeIntervalSince1970: 1_780_000_000 + Double(offset))
      report.summary = "report \(offset)"
      try store.save(report)
    }

    let names = try FileManager.default.contentsOfDirectory(atPath: store.historyDirectory.path)
      .filter { $0.hasSuffix(".json") }
    XCTAssertEqual(names.count, UpgradeReportStore.keepCount)
    // The newest is the one still addressable by name, and it must not have been pruned.
    XCTAssertEqual(store.loadLatest()?.summary, "report \(UpgradeReportStore.keepCount + 3)")
  }

  func testKeptReportIsNotWorthShowingAtLaunch() {
    XCTAssertFalse(makeReport(outcome: .kept).isWorthShowingAtLaunch)
    XCTAssertTrue(makeReport(outcome: .rolledBack).isWorthShowingAtLaunch)
    XCTAssertTrue(makeReport(outcome: .aborted).isWorthShowingAtLaunch)
  }
}
