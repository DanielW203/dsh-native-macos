import Foundation
import XCTest
@testable import HarnessKit

/// Decoding `session/follow` frames and the turn endings inside them.
///
/// The frames here are the two shapes a real stream produces — an opening `snapshot` and `event`
/// entries — written the way the controller types them (`{type:'event', event: {type, seq, data}}`).
/// The turn reasons are the six the session package declares.
///
/// The bar these tests hold: a frame this version does not understand must be ignored, never
/// reported as a failure, because the harness is allowed to add frame kinds and a watcher that
/// announces "unknown ending" for a newer harness would be worse than one that stays quiet.
final class TurnCompletionTests: XCTestCase {
  private func json(_ text: String) throws -> JSONValue {
    try JSONValue.parse(Data(text.utf8), context: "test")
  }

  // MARK: - Frame parsing

  func testSnapshotFrameCarriesTheCursor() throws {
    let frame = SessionFollowFrame.parse(try json(#"{"type":"snapshot","cursor":128,"hasMore":false}"#))
    XCTAssertEqual(frame, .snapshot(cursor: 128, records: []))
  }

  func testSnapshotWithoutACursorStillOpensTheStream() throws {
    // The cursor is the only field this client reads, and a stream that opened is still usable.
    // Failing the frame here would drop the boundary that separates history from live events.
    let frame = SessionFollowFrame.parse(try json(#"{"type":"snapshot","hasMore":true}"#))
    XCTAssertEqual(frame, .snapshot(cursor: 0, records: []))
  }

  /// The page a snapshot opens with is the gap a reconnecting reader has to catch up on, so its
  /// records are decoded through the same envelope the live frames use.
  func testSnapshotDecodesItsHistoryPage() throws {
    let frame = SessionFollowFrame.parse(try json("""
    {"type":"snapshot","cursor":50,"records":[
      {"type":"event","event":{"seq":48,"time":1,"type":"turn/end","data":{"turn":3,"reason":{"kind":"completed"}}}},
      {"type":"event","event":{"seq":49,"time":1,"type":"turn/start","data":{"turn":4}}}
    ]}
    """))
    guard case .snapshot(let cursor, let records) = frame else {
      return XCTFail("expected a snapshot frame, got \(String(describing: frame))")
    }
    XCTAssertEqual(cursor, 50)
    XCTAssertEqual(records.map(\.seq), [48, 49])
    XCTAssertEqual(records.map(\.type), ["turn/end", "turn/start"])
    XCTAssertEqual(records[0].turn, 3)

    // A record with no sequence number cannot be placed on the log; one that is not an event
    // envelope is not a record at all.
    let unnumbered = SessionFollowFrame.parse(
      try json(#"{"type":"snapshot","records":[{"type":"event","event":{"type":"turn/end"}}]}"#)
    )
    guard case .snapshot(_, let partial) = unnumbered else { return XCTFail("expected a snapshot") }
    XCTAssertEqual(partial.count, 1)
    XCTAssertNil(partial[0].seq)

    let junk = SessionFollowFrame.parse(try json(#"{"type":"snapshot","records":[{"nope":true}]}"#))
    guard case .snapshot(_, let empty) = junk else { return XCTFail("expected a snapshot") }
    XCTAssertTrue(empty.isEmpty)
  }

  func testEventFrameCarriesTypeSeqAndTurn() throws {
    let frame = SessionFollowFrame.parse(try json("""
    {"type":"event","event":{"seq":42,"time":1,"type":"turn/end","data":{"turn":7,"reason":{"kind":"completed"}}}}
    """))
    guard case .event(let type, let seq, let turn, _) = frame else {
      return XCTFail("expected an event frame, got \(String(describing: frame))")
    }
    XCTAssertEqual(type, "turn/end")
    XCTAssertEqual(seq, 42)
    XCTAssertEqual(turn, 7)
  }

  func testAssistantStreamFrameIsRecognisedAndIgnored() throws {
    XCTAssertEqual(SessionFollowFrame.parse(try json(#"{"type":"assistant-stream","frame":{}}"#)), .assistantStream)
  }

  func testUnknownFrameTypeIsRecognisedButNotInterpreted() throws {
    let frame = SessionFollowFrame.parse(try json(#"{"type":"some-future-frame","payload":{}}"#))
    XCTAssertEqual(frame, .unrecognized(type: "some-future-frame"))
  }

  func testFramesWithoutATypeAreDropped() throws {
    XCTAssertNil(SessionFollowFrame.parse(try json(#"{"cursor":1}"#)))
    XCTAssertNil(SessionFollowFrame.parse(try json("""
    {"type":"event"}
    """)))
    XCTAssertNil(SessionFollowFrame.parse(try json("""
    {"type":"event","event":{"seq":1}}
    """)))
  }

  // MARK: - Turn endings

  func testEveryDeclaredTurnReasonMapsToItsKind() throws {
    for (wire, expected) in [
      ("completed", TurnEndKind.completed),
      ("max-tokens", TurnEndKind.maxTokens),
      ("blocked", TurnEndKind.blocked),
      ("aborted", TurnEndKind.aborted),
      ("error", TurnEndKind.error),
      ("interrupted", TurnEndKind.interrupted),
    ] {
      XCTAssertEqual(TurnEndKind.fromWire(wire), expected, wire)
    }
  }

  func testReasonsThisVersionDoesNotKnowBecomeUnknown() {
    // `TurnEndReason` is merge-extensible: a plugin can add a variant, so an unrecognised reason is
    // expected rather than exceptional.
    XCTAssertEqual(TurnEndKind.fromWire("paused-by-plugin"), .unknown)
    XCTAssertEqual(TurnEndKind.fromWire(""), .unknown)
  }

  func testCompletedTurnDecodes() throws {
    let completion = try XCTUnwrap(TurnCompletion.decode(
      sessionID: "session-1",
      eventType: "turn/end",
      data: try json(#"{"turn":3,"reason":{"kind":"completed"}}"#),
      sessionTitle: "Refactor the parser"
    ))
    XCTAssertEqual(completion.sessionID, "session-1")
    XCTAssertEqual(completion.sessionTitle, "Refactor the parser")
    XCTAssertEqual(completion.turn, 3)
    XCTAssertEqual(completion.kind, .completed)
    XCTAssertNil(completion.failureCode)
  }

  func testFailedTurnCarriesTheStructuredFailure() throws {
    let completion = try XCTUnwrap(TurnCompletion.decode(
      sessionID: "session-1",
      eventType: "turn/end",
      data: try json("""
      {"turn":4,"reason":{"kind":"error","error":{"code":"RATE_LIMITED","message":"slow down"}}}
      """)
    ))
    XCTAssertEqual(completion.kind, .error)
    XCTAssertEqual(completion.failureCode, "RATE_LIMITED")
    XCTAssertEqual(completion.failureMessage, "slow down")
  }

  func testAnyOtherEventTypeIsNotATurnEnding() throws {
    XCTAssertNil(TurnCompletion.decode(
      sessionID: "session-1",
      eventType: "tool/call",
      data: try json(#"{"turn":1}"#)
    ))
    XCTAssertNil(TurnCompletion.decode(
      sessionID: "session-1",
      eventType: "assistant/message",
      data: try json(#"{"turn":1}"#)
    ))
  }

  /// A `turn/end` whose payload cannot be read is still a turn that ended. Reporting it as an
  /// unnamed ending is better than dropping the fact, which is what a `nil` here would do.
  func testUnreadableTurnEndPayloadBecomesUnknown() throws {
    let completion = try XCTUnwrap(TurnCompletion.decode(
      sessionID: "session-1",
      eventType: "turn/end",
      data: try json(#"{"reason":{"kind":42}}"#)
    ))
    XCTAssertEqual(completion.kind, .unknown)
    XCTAssertNil(completion.turn)
  }

  func testTurnEndWithoutAReasonBecomesUnknown() throws {
    let completion = try XCTUnwrap(TurnCompletion.decode(
      sessionID: "session-1",
      eventType: "turn/end",
      data: try json(#"{"turn":9}"#)
    ))
    XCTAssertEqual(completion.kind, .unknown)
    XCTAssertEqual(completion.turn, 9)
  }

  // MARK: - Which endings deserve a notification

  /// The classification the notification switches are built on. It is asserted as a table because
  /// it is a product decision rather than an implementation detail: `aborted` is the user's own
  /// stop and `interrupted` is a recovery artifact, so neither is news.
  func testWhichEndingsDeserveNotification() {
    XCTAssertTrue(TurnEndKind.completed.deservesNotification)
    XCTAssertTrue(TurnEndKind.maxTokens.deservesNotification)
    XCTAssertTrue(TurnEndKind.error.deservesNotification)
    XCTAssertTrue(TurnEndKind.blocked.deservesNotification)
    XCTAssertFalse(TurnEndKind.aborted.deservesNotification)
    XCTAssertFalse(TurnEndKind.interrupted.deservesNotification)
    XCTAssertFalse(TurnEndKind.unknown.deservesNotification)
  }

  func testCompletionAndFailurePartitions() {
    XCTAssertTrue(TurnEndKind.completed.isCompletion)
    XCTAssertTrue(TurnEndKind.maxTokens.isCompletion)
    XCTAssertFalse(TurnEndKind.error.isCompletion)

    XCTAssertTrue(TurnEndKind.error.isFailure)
    XCTAssertTrue(TurnEndKind.blocked.isFailure)
    XCTAssertFalse(TurnEndKind.completed.isFailure)
    XCTAssertFalse(TurnEndKind.aborted.isFailure)
    XCTAssertFalse(TurnEndKind.aborted.isCompletion)
  }

  // MARK: - Running narration

  /// The white text in the transcript, decoded from the event the harness commits for it.
  ///
  /// Plain text blocks only. The reasoning block is written *first* in a real step, so folding it in
  /// would forward the model's thinking while the paragraph the user read stayed behind.
  func testAssistantTextIsDecodedFromItsTextBlocks() throws {
    let segment = try XCTUnwrap(AssistantTextSegment.decode(
      sessionID: "session-1",
      eventType: "assistant/message",
      seq: 42,
      data: try json("""
      {"turn":4,"step":9,"message":{"id":"m1","role":"assistant","content":[
        {"type":"reasoning","text":"让我先想一下"},
        {"type":"text","text":"这个要分两步验证。"}
      ]}}
      """)
    ))

    XCTAssertEqual(segment.sessionID, "session-1")
    XCTAssertEqual(segment.text, "这个要分两步验证。")
    XCTAssertEqual(segment.turn, 4)
    XCTAssertEqual(segment.step, 9)
    XCTAssertEqual(segment.seq, 42)
    // The title and the subagent flag are the caller's, not the event's: only the caller holds the
    // session list they come from.
    XCTAssertNil(segment.sessionTitle)
    XCTAssertFalse(segment.isSubagent)
  }

  /// Several text blocks in one step are one paragraph, in the order the model wrote them.
  func testSeveralTextBlocksBecomeOneParagraph() throws {
    let segment = try XCTUnwrap(AssistantTextSegment.decode(
      sessionID: "session-1",
      eventType: "assistant/message",
      data: try json(#"{"message":{"content":[{"type":"text","text":"前半句，"},{"type":"text","text":"后半句。"}]}}"#)
    ))
    XCTAssertEqual(segment.text, "前半句，后半句。")
  }

  /// Most steps are tool calls with no text at all, and an empty paragraph is not worth a phone
  /// message — `nil` here is the ordinary case, not a failure.
  func testStepsWithoutTextAreNotSegments() throws {
    XCTAssertNil(AssistantTextSegment.decode(
      sessionID: "session-1",
      eventType: "assistant/message",
      data: try json(#"{"turn":1,"step":2,"message":{"content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#)
    ))
    // Whitespace is not text either: a step that emitted only a newline would otherwise reach a
    // phone as an empty message.
    XCTAssertNil(AssistantTextSegment.decode(
      sessionID: "session-1",
      eventType: "assistant/message",
      data: try json(#"{"message":{"content":[{"type":"text","text":"   \n "}]}}"#)
    ))
    XCTAssertNil(AssistantTextSegment.decode(
      sessionID: "session-1",
      eventType: "assistant/message",
      data: try json(#"{"turn":1}"#)
    ))
  }

  /// Only the one event type is narration. A `user/message` quoting the same shapes is not, and
  /// neither is the process-local chunk stream.
  func testOtherEventTypesAreNotNarration() throws {
    XCTAssertNil(AssistantTextSegment.decode(
      sessionID: "session-1",
      eventType: "user/message",
      data: try json(#"{"message":{"content":[{"type":"text","text":"我写的话"}]}}"#)
    ))
    XCTAssertNil(AssistantTextSegment.decode(
      sessionID: "session-1",
      eventType: "assistant/chunk",
      data: try json(#"{"message":{"content":[{"type":"text","text":"流式片段"}]}}"#)
    ))
  }
}
