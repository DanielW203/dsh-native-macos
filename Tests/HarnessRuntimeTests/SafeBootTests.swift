import Foundation
import XCTest
@testable import HarnessRuntime

/// Safe Mode is two axes — which home, and which profile — and the marker is the only
/// state. These tests pin the matrix, because the failure that matters is not "the wrong
/// mode" but "a mode the user cannot see and cannot leave".
final class SafeBootTests: XCTestCase {
  private func makeBase(_ testCase: XCTestCase, function: String = #function) throws -> RuntimePaths {
    RuntimePaths(root: try TestSupport.makeRoot(testCase, function: function))
  }

  // MARK: - Resolution

  func testNothingRequestedIsANormalStart() throws {
    let base = try makeBase(self)
    let resolution = SafeBoot.resolve(base)

    XCTAssertNil(resolution.mode)
    XCTAssertFalse(resolution.isSafe)
    XCTAssertEqual(resolution.paths, base)
    XCTAssertEqual(resolution.profile, "web")
    XCTAssertNil(resolution.note)
  }

  /// A `rescue` start keeps the user's home: the entire value of this mode is that
  /// credentials, sessions, and settings still work while the plugin layer is removed.
  func testRescueUsesTheRealHomeAndTheRescueProfile() throws {
    let base = try makeBase(self)
    try SafeBoot.enter(.rescue, base: base)

    let resolution = SafeBoot.resolve(base)

    XCTAssertEqual(resolution.mode, .rescue)
    XCTAssertTrue(resolution.isSafe)
    XCTAssertEqual(resolution.paths, base)
    XCTAssertEqual(resolution.paths.dshHome, base.realDshHome)
    XCTAssertFalse(resolution.paths.isSafeMode)
    XCTAssertEqual(resolution.profile, "rescue")
    XCTAssertNotNil(resolution.enteredAt)
  }

  /// The disposable home is the only thing that moves. Re-provisioning Node or releases to
  /// answer "does the harness still boot" would be a worse answer than the question.
  func testCleanHomeMovesOnlyTheHarnessHome() throws {
    let base = try makeBase(self)
    try SafeBoot.enter(.cleanHome, base: base)

    let resolution = SafeBoot.resolve(base)
    let paths = resolution.paths

    XCTAssertEqual(resolution.mode, .cleanHome)
    XCTAssertEqual(resolution.profile, "web")
    XCTAssertTrue(paths.isSafeMode)
    XCTAssertEqual(paths.dshHome, base.safeModeHome)
    XCTAssertNotEqual(paths.dshHome, base.realDshHome)

    // Everything shared stays shared.
    XCTAssertEqual(paths.root, base.root)
    XCTAssertEqual(paths.harnessRoot, base.harnessRoot)
    XCTAssertEqual(paths.releasesDirectory, base.releasesDirectory)
    XCTAssertEqual(paths.runtimeRoot, base.runtimeRoot)
    XCTAssertEqual(paths.lockFile, base.lockFile)
    XCTAssertEqual(paths.backupsRoot, base.backupsRoot)
    XCTAssertEqual(paths.logsDirectory, base.logsDirectory)
    XCTAssertEqual(paths.realDshHome, base.realDshHome)
  }

  func testCreateDirectoriesMakesTheDisposableHome() throws {
    let base = try makeBase(self)
    let paths = base.withSafeModeHome()

    try paths.createDirectories()

    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.dshHome.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.profilesDirectory.path))
  }

  // MARK: - Leftovers

  /// A tree with no marker is garbage from a crash: the file said "start in Safe Mode" and
  /// it is gone, so the directory has no authority.
  func testLeftoverTreeWithoutAMarkerIsClearedOnANormalStart() throws {
    let base = try makeBase(self)
    try FileManager.default.createDirectory(at: base.safeModeHome, withIntermediateDirectories: true)

    let resolution = SafeBoot.resolve(base)

    XCTAssertNil(resolution.mode)
    XCTAssertFalse(FileManager.default.fileExists(atPath: base.safeModeDirectory.path))
    XCTAssertNotNil(resolution.note)
  }

  /// A user trapped in a mode nothing on screen explains is the one outcome that must be
  /// impossible, so an unreadable marker degrades to a normal start.
  func testUnreadableMarkerStartsNormallyAndClearsTheTree() throws {
    let base = try makeBase(self)
    try FileManager.default.createDirectory(at: base.safeModeDirectory, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: base.safeModeMarker)

    let resolution = SafeBoot.resolve(base)

    XCTAssertNil(resolution.mode)
    XCTAssertEqual(resolution.paths, base)
    XCTAssertFalse(FileManager.default.fileExists(atPath: base.safeModeDirectory.path))
    XCTAssertNotNil(resolution.note)
  }

  func testMarkerFromAFutureVersionIsIgnored() throws {
    let base = try makeBase(self)
    try FileManager.default.createDirectory(at: base.safeModeDirectory, withIntermediateDirectories: true)
    let record = SafeBootRecord(version: 99, mode: .cleanHome, enteredAt: "now", profile: "web")
    try JSONEncoder().encode(record).write(to: base.safeModeMarker)

    let resolution = SafeBoot.resolve(base)

    XCTAssertNil(resolution.mode)
    XCTAssertNotNil(resolution.note)
  }

  // MARK: - Entering and leaving

  func testEnterWritesAVersionedMarker() throws {
    let base = try makeBase(self)
    try SafeBoot.enter(.cleanHome, base: base)

    let record = try XCTUnwrap(SafeBoot.record(base))

    XCTAssertEqual(record.version, SafeBoot.markerVersion)
    XCTAssertEqual(record.mode, .cleanHome)
    XCTAssertEqual(record.profile, "web")
    XCTAssertNotNil(ISO8601DateFormatter().date(from: record.enteredAt))
  }

  func testLeaveRemovesTheMarkerAndTheDisposableHome() throws {
    let base = try makeBase(self)
    try SafeBoot.enter(.cleanHome, base: base)
    try FileManager.default.createDirectory(at: base.safeModeHome, withIntermediateDirectories: true)

    try SafeBoot.leave(base)

    XCTAssertNil(SafeBoot.record(base))
    XCTAssertFalse(FileManager.default.fileExists(atPath: base.safeModeHome.path))
    XCTAssertNil(SafeBoot.resolve(base).mode)
  }

  /// Leaving Safe Mode keeps the rescue profile — it is three small files, it is useful
  /// next time, and deleting a profile belongs behind an explicit confirmation.
  func testLeaveKeepsTheRescueProfile() throws {
    let base = try makeBase(self)
    try TestSupport.write("{}", to: base.profilesDirectory
      .appendingPathComponent("rescue/package.json"))
    try SafeBoot.enter(.rescue, base: base)

    try SafeBoot.leave(base)

    XCTAssertNil(SafeBoot.record(base))
    XCTAssertTrue(SafeBoot.rescueProfileExists(in: base))
  }

  /// Switching `cleanHome` → `rescue` leaves the disposable home unused. It must not be
  /// left on disk waiting for a launch that will never remove it.
  func testSwitchingFromCleanHomeToRescueDropsTheDisposableHome() throws {
    let base = try makeBase(self)
    try SafeBoot.enter(.cleanHome, base: base)
    try FileManager.default.createDirectory(at: base.safeModeHome, withIntermediateDirectories: true)
    try SafeBoot.enter(.rescue, base: base)

    let resolution = SafeBoot.resolve(base)

    XCTAssertEqual(resolution.mode, .rescue)
    XCTAssertFalse(FileManager.default.fileExists(atPath: base.safeModeHome.path))
  }

  func testRescueProfileExistsLooksForTheManifest() throws {
    let base = try makeBase(self)
    XCTAssertFalse(SafeBoot.rescueProfileExists(in: base))

    // A bare directory is not a profile: the harness keys on package.json, and an empty
    // directory would make the app skip the initialization that actually creates it.
    try FileManager.default.createDirectory(
      at: base.profilesDirectory.appendingPathComponent("rescue"),
      withIntermediateDirectories: true
    )
    XCTAssertFalse(SafeBoot.rescueProfileExists(in: base))

    try TestSupport.write("{}", to: base.profilesDirectory.appendingPathComponent("rescue/package.json"))
    XCTAssertTrue(SafeBoot.rescueProfileExists(in: base))
  }

  // MARK: - The seam

  func testMarkerSeamRoundTripsThroughTheProtocol() throws {
    let base = try makeBase(self)
    let marking = SafeBootMarker(base: base, now: { Date(timeIntervalSince1970: 1_700_000_000) })

    XCTAssertNil(marking.current().mode)
    try marking.enter(.rescue)
    XCTAssertEqual(marking.current().mode, .rescue)
    XCTAssertEqual(SafeBoot.record(base)?.enteredAt, "2023-11-14T22:13:20Z")
    try marking.leave()
    XCTAssertNil(marking.current().mode)
  }
}
