import XCTest
@testable import HarnessRuntime

final class PendingUpgradeTests: XCTestCase {
  private func makeStore(_ testCase: XCTestCase) throws -> PendingUpgradeStore {
    let root = try TestSupport.makeRoot(testCase)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()
    return PendingUpgradeStore(paths: paths)
  }

  private func makeRecord() -> PendingUpgradeRecord {
    PendingUpgradeRecord(
      fromReleaseID: "0.1.5-rc.1-registry-npm",
      toReleaseID: "0.1.5-rc.2-registry-npm",
      profile: "web",
      startedAt: Date(timeIntervalSince1970: 1_780_000_000),
      stage: .booting
    )
  }

  func testMissingMarkerReadsAsAbsent() throws {
    let store = try makeStore(self)
    XCTAssertEqual(store.load(), .absent)
    XCTAssertNil(store.record)
  }

  func testRoundTripPreservesEveryField() throws {
    let store = try makeStore(self)
    let record = makeRecord()
    try store.save(record)

    guard case .record(let loaded) = store.load() else {
      return XCTFail("expected a record, got \(store.load())")
    }
    XCTAssertEqual(loaded, record)
  }

  /// The whole point of the marker is that a crash cannot erase it, so an unreadable one must
  /// be *reported* rather than thrown — the caller is on a launch path.
  func testCorruptMarkerIsUnreadableRatherThanThrowing() throws {
    let store = try makeStore(self)
    try Data("{ not json".utf8).write(to: store.url)

    guard case .unreadable(let detail) = store.load() else {
      return XCTFail("expected unreadable, got \(store.load())")
    }
    XCTAssertFalse(detail.isEmpty)
    XCTAssertNil(store.record)
  }

  /// A marker from a newer build is not half-understood: guessing could roll back an upgrade
  /// this build does not even know the shape of.
  func testNewerSchemaVersionIsTreatedAsUnreadable() throws {
    let store = try makeStore(self)
    var record = makeRecord()
    record.schemaVersion = PendingUpgradeRecord.currentSchemaVersion + 1
    try store.save(record)

    guard case .unreadable(let detail) = store.load() else {
      return XCTFail("expected unreadable, got \(store.load())")
    }
    XCTAssertTrue(detail.contains("schemaVersion"), detail)
  }

  func testAdvanceMovesTheStageAndKeepsTheIdentifiers() throws {
    let store = try makeStore(self)
    try store.save(makeRecord())

    store.advance(to: .verifying)

    XCTAssertEqual(store.record?.stage, .verifying)
    XCTAssertEqual(store.record?.fromReleaseID, "0.1.5-rc.1-registry-npm")
    XCTAssertEqual(store.record?.toReleaseID, "0.1.5-rc.2-registry-npm")
  }

  /// Progress is diagnostic. An upgrade must not fail because a progress note could not be
  /// written, so advancing with no marker is silently a no-op.
  func testAdvanceWithoutAMarkerIsANoOp() throws {
    let store = try makeStore(self)
    store.advance(to: .verifying)
    XCTAssertEqual(store.load(), .absent)
  }

  func testClearRemovesTheMarker() throws {
    let store = try makeStore(self)
    try store.save(makeRecord())
    store.clear()
    XCTAssertEqual(store.load(), .absent)
    // Clearing twice is not an error: a resume path may clear a marker another path already
    // removed, and neither of them can tell which went first.
    store.clear()
    XCTAssertEqual(store.load(), .absent)
  }
}
