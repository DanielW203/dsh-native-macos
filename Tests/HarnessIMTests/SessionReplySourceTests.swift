import Foundation
import HarnessKit
import XCTest

@testable import HarnessIM

/// The reply rule is verified against a session log recorded from a real harness run
/// (isolated test home), so the fixture carries the true event shapes — including the
/// multi-frame zstd container — rather than a hand-written approximation.
final class SessionReplySourceTests: XCTestCase {
  private func fixtureLogURL() throws -> URL {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "recorded-session.v3", withExtension: "jsonl.zstd", subdirectory: "Fixtures"),
      "recorded session fixture is missing from the test bundle"
    )
    return url
  }

  func testExtractsReplyForTheSubmittedRequest() throws {
    let events = try SessionLogReader(url: try fixtureLogURL()).readEvents()
    let reply = try XCTUnwrap(SessionReplyExtractor.reply(in: events, requestId: "req-1"))
    XCTAssertEqual(reply.text, "收到")
    XCTAssertEqual(reply.turn, 1)
    XCTAssertEqual(reply.reason, "completed")
    XCTAssertTrue(reply.isComplete)
  }

  /// A session is shared: an unrelated prompt's turn must not be mistaken for this one.
  func testIgnoresOtherRequests() throws {
    let events = try SessionLogReader(url: try fixtureLogURL()).readEvents()
    XCTAssertNil(SessionReplyExtractor.reply(in: events, requestId: "req-does-not-exist"))
  }

  /// While the model is still working there is no `turn/end`; the caller gets a partial
  /// answer so a long task can be narrated instead of looking stalled.
  func testReportsPartialReplyWhileTheTurnRuns() throws {
    let events = try SessionLogReader(url: try fixtureLogURL()).readEvents()
    let truncated = Array(events.prefix { $0.kind != .turnEnd })
    let reply = try XCTUnwrap(SessionReplyExtractor.reply(in: truncated, requestId: "req-1"))
    XCTAssertEqual(reply.text, "收到")
    XCTAssertFalse(reply.isComplete)
    XCTAssertNil(reply.reason)
  }

  /// The whole chain: project-key escaping → session directory → multi-frame log → reply.
  func testReadsFromLogThroughItsRealPath() async throws {
    let dshHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-im-reply-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dshHome) }
    let cwd = "/tmp/dsh-imtest-ws"
    let sessionID = "session-2fa88c3f-515c-4170-b656-ba39887000fc"

    let directory = try SessionPaths.sessionDirectory(dshHome: dshHome, cwd: cwd, sessionID: sessionID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: try fixtureLogURL(),
      to: directory.appendingPathComponent("session.v3.jsonl.zstd")
    )

    let source = SessionReplySource(dshHome: dshHome, cwd: cwd, sessionID: sessionID, client: nil)
    let extracted = await source.readFromLog(requestId: "req-1")
    let reply = try XCTUnwrap(extracted)
    XCTAssertEqual(reply.text, "收到")
  }

  /// A workspace with no session yet must read as "nothing yet", not as an error or a crash.
  func testMissingLogReadsAsNil() async {
    let source = SessionReplySource(
      dshHome: URL(fileURLWithPath: "/tmp/harness-im-absent-\(UUID().uuidString)"),
      cwd: "/tmp/never",
      sessionID: "session-absent",
      client: nil
    )
    let reply = await source.readFromLog(requestId: "req-1")
    XCTAssertNil(reply)
  }

  func testPageFallbackFindsTheNewestAssistantText() throws {
    let page = try JSONValue.parse(#"""
    { "records": [
        { "type": "event", "event": { "type": "assistant/message", "data": { "message": { "role": "assistant", "content": [ { "type": "text", "text": "旧回答" } ] } } } },
        { "type": "event", "event": { "type": "assistant/message", "data": { "message": { "role": "assistant", "content": [ { "type": "text", "text": "新回答" } ] } } } }
    ], "hasMore": false }
    """#)
    XCTAssertEqual(SessionReplySource.lastAssistantText(in: page), "新回答")
  }

  func testPageFallbackIgnoresNonAssistantContent() throws {
    let page = try JSONValue.parse(#"""
    { "records": [ { "message": { "role": "user", "content": [ { "type": "text", "text": "用户的话" } ] } } ] }
    """#)
    XCTAssertNil(SessionReplySource.lastAssistantText(in: page))
  }
}
