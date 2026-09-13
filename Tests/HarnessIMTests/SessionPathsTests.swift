import Foundation
import XCTest

@testable import HarnessIM

/// The escaping must match the harness byte for byte: a divergence points the reply
/// watcher at a directory that never exists, and the failure mode is silence rather
/// than an error.
final class SessionPathsTests: XCTestCase {
  /// A realistic mixed ASCII/non-ASCII working directory. The expected key is spelled out
  /// by hand rather than computed, so the test fails if the port ever drifts from the
  /// JavaScript it was copied from.
  func testProjectKeyMatchesObservedDirectoryName() throws {
    let key = try SessionPaths.projectKey("/Users/example/Documents/我的项目")
    XCTAssertEqual(key, "--Users-example-Documents-~6211~7684~9879~76EE--")
  }

  func testProjectKeyCollapsesSeparatorRuns() throws {
    XCTAssertEqual(try SessionPaths.projectKey("/Users//example"), "--Users-example--")
    XCTAssertEqual(try SessionPaths.projectKey("C:\\Users\\me"), "--C-Users-me--")
    // A leading separator is stripped, not kept as an empty first segment.
    XCTAssertEqual(try SessionPaths.projectKey("relative/dir"), "--relative-dir--")
  }

  func testProjectKeyEscapesTildeAndSpaces() throws {
    // `~` itself must be escaped, or the escape sequence would be ambiguous.
    XCTAssertEqual(try SessionPaths.projectKey("/a~b"), "--a~007Eb--")
    XCTAssertEqual(try SessionPaths.projectKey("/a b"), "--a~0020b--")
  }

  func testProjectKeyRejectsEmptyPath() {
    XCTAssertThrowsError(try SessionPaths.projectKey("")) { error in
      XCTAssertEqual(error as? SessionPaths.PathError, .emptyProjectPath)
    }
  }

  func testEncodeSegmentMatchesSessionIDRules() throws {
    XCTAssertEqual(try SessionPaths.encodeSegment("."), "~002E")
    XCTAssertEqual(try SessionPaths.encodeSegment(".."), "~002E~002E")
    XCTAssertEqual(try SessionPaths.encodeSegment("c69708af-260f-42b4-bb6b-e9474287ea0b"),
                   "c69708af-260f-42b4-bb6b-e9474287ea0b")
    XCTAssertEqual(try SessionPaths.encodeSegment("a b"), "a~0020b")
  }

  func testEncodeSegmentRejectsEmptyInput() {
    XCTAssertThrowsError(try SessionPaths.encodeSegment(""))
  }

  /// The live API returns ids that already carry the `session-` prefix, and that id *is* the
  /// directory name — so the path must not add a second prefix.
  func testSessionDirectoryUsesTheIDVerbatim() throws {
    let dshHome = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
    let directory = try SessionPaths.sessionDirectory(
      dshHome: dshHome,
      cwd: "/tmp/dsh-imtest-ws",
      sessionID: "session-2fa88c3f-515c-4170-b656-ba39887000fc"
    )
    XCTAssertEqual(directory.path,
                   "/tmp/home/sessions/--tmp-dsh-imtest-ws--/session-2fa88c3f-515c-4170-b656-ba39887000fc")
  }

  func testLogFileMatchesVersionedName() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-im-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    XCTAssertNil(SessionPaths.logFile(inSessionDirectory: directory))

    // The version segment is a format-catalog concern, not a frozen name: match by shape.
    let log = directory.appendingPathComponent("session.v4.jsonl.zstd")
    try Data("x".utf8).write(to: log)
    XCTAssertEqual(SessionPaths.logFile(inSessionDirectory: directory)?.lastPathComponent,
                   "session.v4.jsonl.zstd")

    // Unrelated neighbours must never be mistaken for the log.
    try Data("x".utf8).write(to: directory.appendingPathComponent("session.lock"))
    XCTAssertEqual(SessionPaths.logFile(inSessionDirectory: directory)?.lastPathComponent,
                   "session.v4.jsonl.zstd")
  }
}
