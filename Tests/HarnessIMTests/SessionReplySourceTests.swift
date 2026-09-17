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

  // MARK: - What one turn answered

  /// Two turns in one log. This is the case the window in `turnReply` exists for: a session log is
  /// append-only and holds every turn that ever ran, so "collect the assistant text" would forward a
  /// conversation rather than an answer.
  func testTurnReplyIsBoundedToOneTurn() {
    let events = [
      turnStart(1), assistant(1, "第一轮的答案"), turnEnd(1),
      turnStart(2), assistant(2, "第二轮的答案"), turnEnd(2),
    ]
    XCTAssertEqual(SessionReplyExtractor.turnReply(in: events, turn: 1), "第一轮的答案")
    XCTAssertEqual(SessionReplyExtractor.turnReply(in: events, turn: 2), "第二轮的答案")
  }

  /// A turn narrates before it answers. Only the answer should reach a phone.
  func testTurnReplyKeepsOnlyTheLastMessageOfTheTurn() {
    let events = [
      turnStart(7),
      assistant(7, "我先看一下。"),
      assistant(7, "   \n  "),
      assistant(7, "结论是这样的。"),
      turnEnd(7),
      turnStart(8),
      assistant(8, "下一轮的开场白"),
    ]
    XCTAssertEqual(SessionReplyExtractor.turnReply(in: events, turn: 7), "结论是这样的。")
  }

  /// A turn that never ended has nothing to attribute. Falling back to the newest turn would pin an
  /// older answer on the turn that just failed to end.
  func testTurnWithoutAnEndHasNoAnswer() {
    let events = [turnStart(1), assistant(1, "旧答案"), turnEnd(1), turnStart(2), assistant(2, "进行中")]
    XCTAssertNil(SessionReplyExtractor.turnReply(in: events, turn: 2))
  }

  /// `nil` means "the newest ending in this log", which is what a caller holding only a session id
  /// can ask for.
  func testNilTurnReadsTheNewestEnding() {
    let events = [
      turnStart(1), assistant(1, "第一轮"), turnEnd(1),
      turnStart(2), assistant(2, "第二轮"), turnEnd(2),
    ]
    XCTAssertEqual(SessionReplyExtractor.turnReply(in: events, turn: nil), "第二轮")
  }

  func testUnknownOrEmptyLogReadsAsNil() {
    let events = [turnStart(1), assistant(1, "只有这一轮"), turnEnd(1)]
    XCTAssertNil(SessionReplyExtractor.turnReply(in: events, turn: 9))
    XCTAssertNil(SessionReplyExtractor.turnReply(in: [], turn: nil))
    XCTAssertNil(SessionReplyExtractor.turnReply(in: [], turn: 1))
  }

  /// A turn that only ran tools has no text, and that is an ordinary outcome rather than a failure.
  func testToolOnlyTurnHasNoAnswer() {
    let events = [turnStart(3), turnEnd(3)]
    XCTAssertNil(SessionReplyExtractor.turnReply(in: events, turn: 3))
  }

  /// And the rule holds against the recorded log the rest of this file uses.
  func testTurnReplyReadsTheRecordedFixture() throws {
    let events = try SessionLogReader(url: try fixtureLogURL()).readEvents()
    XCTAssertEqual(SessionReplyExtractor.turnReply(in: events, turn: 1), "收到")
  }

  // MARK: - Reasoning is not the answer

  /// The harness records the model's reasoning *before* its answer, in the same message. Only the
  /// answer may leave: a phone that received both would be reading the model's thinking, and the
  /// length cap on a forwarded result would then spend itself before reaching the answer at all.
  func testReasoningIsNotPartOfTheTurnReply() {
    let events = [
      turnStart(1),
      assistant(1, text: "答案是 42。", reasoning: String(repeating: "先想一下。", count: 200)),
      turnEnd(1),
    ]
    XCTAssertEqual(SessionReplyExtractor.turnReply(in: events, turn: 1), "答案是 42。")
  }

  /// The same for the reply a chat submission waits on — this is the text the WeChat conversation
  /// itself receives, so a leak here is visible in the channel's own answers too.
  func testReasoningIsNotPartOfTheRequestedReply() {
    let events = [
      user(requestId: "req-1"),
      turnStart(1),
      assistant(1, text: "结果是 42", reasoning: String(repeating: "推理。", count: 100)),
      turnEnd(1),
    ]
    let reply = try? XCTUnwrap(SessionReplyExtractor.reply(in: events, requestId: "req-1"))
    XCTAssertEqual(reply?.text, "结果是 42")
  }

  /// A step that only thought has nothing to forward, even when it is the last thing in the turn.
  func testATrailingReasoningOnlyStepDoesNotBecomeTheAnswer() {
    let events = [
      turnStart(3),
      assistant(3, text: "先看一下。"),
      assistant(3, text: "", reasoning: "再想想……"),
      turnEnd(3),
    ]
    XCTAssertEqual(SessionReplyExtractor.turnReply(in: events, turn: 3), "先看一下。")
  }

  /// A turn that only ever thought has no answer, rather than a thinking block sent as one.
  func testAThinkingOnlyTurnHasNoAnswer() {
    let events = [
      turnStart(4),
      assistant(4, text: "", reasoning: "只有推理，没有回答。"),
      turnEnd(4),
    ]
    XCTAssertNil(SessionReplyExtractor.turnReply(in: events, turn: 4))
  }

  // MARK: - Synthetic events

  private func user(requestId: String) -> SessionEvent {
    SessionEvent(envelope: EventEnvelope(
      type: .userMessage,
      data: .object([
        "id": .string("user-\(requestId)"),
        "content": .array([.object(["type": .string("text"), "text": .string("跑一下")])]),
        "source": .object(["kind": .string("user"), "rpcId": .string(requestId)]),
      ])
    ))
  }

  private func turnStart(_ turn: Int) -> SessionEvent {
    SessionEvent(envelope: EventEnvelope(
      type: .turnStart,
      data: .object(["turn": .number(Double(turn))])
    ))
  }

  private func assistant(_ turn: Int, _ text: String) -> SessionEvent {
    assistant(turn, text: text)
  }

  /// One `assistant/message` with the block order the harness actually writes: reasoning, then the
  /// answer. Recording both in one message is what makes the "which block is the answer" question
  /// load-bearing rather than academic.
  private func assistant(_ turn: Int, text: String, reasoning: String = "") -> SessionEvent {
    var blocks: [JSONValue] = []
    if !reasoning.isEmpty {
      blocks.append(.object(["type": .string("reasoning"), "text": .string(reasoning)]))
    }
    blocks.append(.object(["type": .string("text"), "text": .string(text)]))
    return SessionEvent(envelope: EventEnvelope(
      type: .assistantMessage,
      data: .object([
        "turn": .number(Double(turn)),
        "step": .number(1),
        "message": .object([
          "id": .string("assistant-\(turn)-\(text.count)-\(reasoning.count)"),
          "role": .string("assistant"),
          "content": .array(blocks),
        ]),
      ])
    ))
  }

  private func turnEnd(_ turn: Int) -> SessionEvent {
    SessionEvent(envelope: EventEnvelope(
      type: .turnEnd,
      data: .object([
        "turn": .number(Double(turn)),
        "reason": .object(["kind": .string("completed")]),
      ])
    ))
  }
}
