import XCTest
@testable import HarnessRuntime

final class InstallsIndexTests: XCTestCase {
  private func makeRelease(id: String, version: String = "0.1.5-rc.1") -> HarnessRelease {
    HarnessRelease(
      id: id,
      version: version,
      entry: ReleaseValidator.prebuiltEntry,
      source: SourceRecord(kind: .prebuiltArchive, spec: "/tmp/pkg.zip"),
      integrity: Integrity(digest: "abcdef0123456789", verified: true, origin: .sidecar),
      installedAt: Date(timeIntervalSince1970: 1_780_000_000)
    )
  }

  func testMissingFileLoadsAsEmptyIndex() throws {
    let root = try TestSupport.makeRoot(self)
    let index = try InstallsIndex.load(from: root.appendingPathComponent("installs.json"))
    XCTAssertNil(index.active)
    XCTAssertTrue(index.releases.isEmpty)
  }

  func testRoundTripPreservesEveryField() throws {
    let root = try TestSupport.makeRoot(self)
    let url = root.appendingPathComponent("harness/installs.json")
    var index = InstallsIndex()
    index.active = "a"
    index.releases = [makeRelease(id: "a")]
    try index.save(to: url)

    let reloaded = try InstallsIndex.load(from: url)
    XCTAssertEqual(reloaded, index)
    // Dates survive as ISO-8601 rather than drifting through a locale-dependent format.
    XCTAssertEqual(reloaded.releases[0].installedAt, Date(timeIntervalSince1970: 1_780_000_000))
  }

  func testSaveOverwritesAnExistingLedgerWithoutLeavingTemporaries() throws {
    let root = try TestSupport.makeRoot(self)
    let url = root.appendingPathComponent("harness/installs.json")
    try InstallsIndex(active: "a", releases: [makeRelease(id: "a")]).save(to: url)
    try InstallsIndex(active: "b", releases: [makeRelease(id: "b")]).save(to: url)

    let reloaded = try InstallsIndex.load(from: url)
    XCTAssertEqual(reloaded.active, "b")
    XCTAssertEqual(reloaded.releases.map(\.id), ["b"])

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
      .filter { $0.hasSuffix(".tmp") }
    XCTAssertTrue(leftovers.isEmpty, "atomic save left \(leftovers) behind")
  }

  func testCorruptLedgerThrowsRatherThanLookingEmpty() throws {
    let root = try TestSupport.makeRoot(self)
    let url = root.appendingPathComponent("installs.json")
    try TestSupport.write("{ this is not json", to: url)
    XCTAssertThrowsError(try InstallsIndex.load(from: url))
  }

  func testNewerSchemaIsRejected() throws {
    let root = try TestSupport.makeRoot(self)
    let url = root.appendingPathComponent("installs.json")
    try TestSupport.write("{\"schemaVersion\":99,\"releases\":[]}", to: url)
    XCTAssertThrowsError(try InstallsIndex.load(from: url))
  }

  func testActiveReleaseResolvesOnlyWhenPresent() {
    var index = InstallsIndex()
    index.active = "missing"
    XCTAssertNil(index.activeRelease)
    index.releases = [makeRelease(id: "missing")]
    XCTAssertEqual(index.activeRelease?.id, "missing")
  }

  func testReleaseIDIsDeterministicAndIdempotent() {
    let first = HarnessRelease.makeID(version: "0.1.5-rc.1", kind: .prebuiltArchive, token: "9f3a21bb")
    let second = HarnessRelease.makeID(version: "0.1.5-rc.1", kind: .prebuiltArchive, token: "9f3a21bb")
    XCTAssertEqual(first, second)
    XCTAssertEqual(first, "0.1.5-rc.1-prebuiltArchive-9f3a21")

    // A registry install has no artifact to hash, so identity is the version alone —
    // installing the same version twice must land in the same directory.
    XCTAssertEqual(
      HarnessRelease.makeID(version: "1.0.0", kind: .registry, token: HarnessRelease.idToken(kind: .registry, digest: nil)),
      HarnessRelease.makeID(version: "1.0.0", kind: .registry, token: HarnessRelease.idToken(kind: .registry, digest: nil))
    )
  }

  func testIDTokenPrefersTheDigestWhenThereIsOne() {
    XCTAssertEqual(HarnessRelease.idToken(kind: .registry, digest: "abc123"), "abc123")
    XCTAssertEqual(HarnessRelease.idToken(kind: .registry, digest: nil), "npm")
    XCTAssertEqual(HarnessRelease.idToken(kind: .sourceDirectory, digest: nil), "local")
  }
}
