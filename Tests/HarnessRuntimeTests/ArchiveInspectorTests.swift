import XCTest
@testable import HarnessRuntime

final class ArchiveInspectorTests: XCTestCase {
  private let archive = URL(fileURLWithPath: "/tmp/pkg.zip")

  func testAcceptsOrdinaryEntries() throws {
    let entries = try ArchiveInspector.check(
      entries: "node_modules/@deepseek-ai/dsh/lib/bin.js\npackage.json\n",
      archive: archive
    )
    XCTAssertEqual(entries.count, 2)
  }

  func testRejectsAbsolutePaths() {
    XCTAssertThrowsError(try ArchiveInspector.check(entries: "/etc/passwd\n", archive: archive))
  }

  func testRejectsParentTraversal() {
    // The exact shape ditto would happily honour and write outside the destination.
    XCTAssertThrowsError(
      try ArchiveInspector.check(entries: "node_modules/../../Library/LaunchAgents/x.plist\n", archive: archive)
    )
  }

  func testRejectsNulBytes() {
    XCTAssertThrowsError(try ArchiveInspector.check(entries: "bad\u{0}name\n", archive: archive))
  }

  func testRejectsEmptyArchive() {
    XCTAssertThrowsError(try ArchiveInspector.check(entries: "", archive: archive))
  }

  func testRejectsAbsurdEntryCounts() {
    let huge = String(repeating: "file\n", count: ArchiveInspector.maximumEntryCount + 1)
    XCTAssertThrowsError(try ArchiveInspector.check(entries: huge, archive: archive))
  }

  func testAcceptsDirectoryEntriesWithTrailingSlash() throws {
    let entries = try ArchiveInspector.check(entries: "node_modules/\nnode_modules/@deepseek-ai/\n", archive: archive)
    XCTAssertEqual(entries.count, 2)
  }

  func testKindIsDetectedFromContentNotExtension() throws {
    let root = try TestSupport.makeRoot(self)
    let directory = root.appendingPathComponent("checkout", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    XCTAssertEqual(try ArchiveInspector.kind(of: directory), .directory)

    // A gzip payload named .zip is still gzip; the browser names these, not us.
    let gz = root.appendingPathComponent("mislabeled.zip")
    try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: gz)
    XCTAssertEqual(try ArchiveInspector.kind(of: gz), .tarGz)

    let zip = root.appendingPathComponent("real.bin")
    try Data([0x50, 0x4b, 0x03, 0x04]).write(to: zip)
    XCTAssertEqual(try ArchiveInspector.kind(of: zip), .zip)
  }

  func testUnknownPayloadWithNoRecognisedNameIsRejected() throws {
    let root = try TestSupport.makeRoot(self)
    let bogus = root.appendingPathComponent("harness.bin")
    try TestSupport.write("not an archive at all", to: bogus)
    XCTAssertThrowsError(try ArchiveInspector.kind(of: bogus))
  }

  func testExtensionIsTheFallbackWhenTheMagicIsInconclusive() throws {
    let root = try TestSupport.makeRoot(self)
    // A browser names these, so a truncated or re-wrapped file still says .zip. The
    // listing step then fails with an error naming the file, which is more useful than
    // "unknown format" would be here.
    let named = root.appendingPathComponent("harness.zip")
    try TestSupport.write("not an archive at all", to: named)
    XCTAssertEqual(try ArchiveInspector.kind(of: named), .zip)
  }

  func testMissingFileIsReported() {
    XCTAssertThrowsError(try ArchiveInspector.kind(of: URL(fileURLWithPath: "/tmp/definitely-not-here-12345.zip")))
  }

  func testSHA256MatchesTheKnownVector() throws {
    let root = try TestSupport.makeRoot(self)
    let file = root.appendingPathComponent("abc.txt")
    // SHA-256 of the ASCII string "abc".
    try TestSupport.write("abc", to: file)
    XCTAssertEqual(
      try ArchiveInspector.sha256(of: file),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
  }

  func testByteCountsAreReported() throws {
    let root = try TestSupport.makeRoot(self)
    let file = root.appendingPathComponent("payload.bin")
    try Data(repeating: 0, count: 4096).write(to: file)
    XCTAssertEqual(try ArchiveInspector.byteCount(of: file), 4096)

    let directory = root.appendingPathComponent("tree", isDirectory: true)
    try TestSupport.write(String(repeating: "x", count: 2048), to: directory.appendingPathComponent("a"))
    XCTAssertGreaterThan(ArchiveInspector.byteCount(ofDirectory: directory), 0)
  }
}
