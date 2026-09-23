import Foundation
import HarnessKit
import XCTest

@testable import HarnessMobileGateway

/// The control pump's queue handling, driven directly.
///
/// `installSessionQueueBaseline` is the half that had to learn the 0.1.6-alpha.2 control
/// baseline: pending input stopped being a `queues` map on the baseline and became each
/// session's `inbox` projection. Both shapes have to work — the old one because a 0.1.5
/// harness is still a supported peer, the new one because its absence is what turned into
/// a once-a-second retry loop against the live harness.
final class MobileGatewayControlPumpTests: XCTestCase {
  /// A frame sink that keeps every emitted wire frame in order.
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [JSONValue] = []

    func append(_ frame: JSONValue) {
      lock.lock()
      frames.append(frame)
      lock.unlock()
    }

    var recorded: [JSONValue] {
      lock.lock()
      defer { lock.unlock() }
      return frames
    }

    var sessionQueues: JSONValue? { recorded.last { $0["kind"]?.stringValue == "session-queues" } }
  }

  private func message(
    id: String,
    text: String,
    source: JSONValue
  ) -> JSONValue {
    .object([
      "id": .string(id),
      "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
      "source": source,
    ])
  }

  private func inbox(_ nextTurn: [JSONValue], _ nextStep: [JSONValue]) -> JSONValue {
    .object(["next-turn": .array(nextTurn), "next-step": .array(nextStep)])
  }

  private func baseline(queues: JSONValue?, projections: JSONValue?) -> JSONValue {
    .object([
      "jobs": .object([:]),
      "queues": queues ?? .null,
      "projections": projections ?? .null,
    ])
  }

  /// The new shape: no `queues` key at all, the queues rebuilt from `inbox` projections.
  func testBaselineWithoutQueuesDerivesQueuesFromInboxProjections() throws {
    let recorder = Recorder()
    var state: [String: [JSONValue]]?
    let frame = baseline(queues: nil, projections: .object([
      "s1": .object([
        "asOfSeq": .number(91),
        "values": .object([
          "inbox": inbox(
            [message(id: "m1", text: "排队", source: .object(["kind": .string("user"), "rpcId": .string("p1")]))],
            [
              message(id: "m2", text: "插话", source: .object(["kind": .string("user")])),
              message(id: "m3", text: "上下文", source: .object(["kind": .string("plugin"), "plugin": .string("dsh-context")])),
            ]
          ),
        ]),
      ]),
    ]))

    try MobileGatewayControlPump.installSessionQueueBaseline(
      frame["queues"],
      projections: frame["projections"],
      state: &state,
      onFrame: { recorder.append($0) }
    )

    let emitted = try XCTUnwrap(recorder.sessionQueues)
    let items = try XCTUnwrap(emitted["queues"]?["s1"]?.arrayValue)
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(items[0]["id"]?.stringValue, "m1")
    XCTAssertEqual(items[0]["placement"]?.stringValue, "queued")
    XCTAssertEqual(items[0]["rpcId"]?.stringValue, "p1")
    XCTAssertEqual(items[0]["message"]?["content"]?.arrayValue?.count, 1)
    XCTAssertEqual(items[1]["placement"]?.stringValue, "steering")
    XCTAssertNil(items[1]["rpcId"])
    XCTAssertEqual(items[2]["placement"]?.stringValue, "context")
    XCTAssertEqual(state?["s1"]?.count, 3)
  }

  /// A session with no `inbox` block has nothing pending — and is therefore cleared, not
  /// dropped from the replacement set.
  func testSessionsWithoutInboxAreCleared() throws {
    let recorder = Recorder()
    var state: [String: [JSONValue]]? = ["stale": [.object(["id": .string("gone")])]]
    let frame = baseline(queues: nil, projections: .object([
      "with-inbox": .object([
        "asOfSeq": .number(5),
        "values": .object(["inbox": inbox([message(id: "m1", text: "a", source: .object(["kind": .string("user")]))], [])]),
      ]),
      "without-inbox": .object(["asOfSeq": .number(5), "values": .object(["todos": .array([])])]),
    ]))

    try MobileGatewayControlPump.installSessionQueueBaseline(
      frame["queues"],
      projections: frame["projections"],
      state: &state,
      onFrame: { recorder.append($0) }
    )

    XCTAssertEqual(state?.keys.sorted(), ["with-inbox"])
    let emitted = try XCTUnwrap(recorder.sessionQueues)
    XCTAssertEqual(emitted["queues"]?.objectValue?.keys.sorted(), ["with-inbox"])
  }

  /// The pre-0.1.6 shape stays authoritative when a peer still sends it, even if the same
  /// baseline also carries projection blocks.
  func testLegacyQueuesKeyWinsOverInboxProjections() throws {
    let recorder = Recorder()
    var state: [String: [JSONValue]]?
    let legacyItem: JSONValue = .object([
      "id": .string("legacy"),
      "placement": .string("queued"),
      "message": .object(["id": .string("legacy"), "content": .array([])]),
    ])
    let frame = baseline(queues: .object(["s1": .array([legacyItem])]), projections: .object([
      "s1": .object([
        "asOfSeq": .number(91),
        "values": .object(["inbox": inbox([message(id: "m1", text: "新", source: .object(["kind": .string("user")]))], [])]),
      ]),
    ]))

    try MobileGatewayControlPump.installSessionQueueBaseline(
      frame["queues"],
      projections: frame["projections"],
      state: &state,
      onFrame: { recorder.append($0) }
    )

    let emitted = try XCTUnwrap(recorder.sessionQueues)
    let items = try XCTUnwrap(emitted["queues"]?["s1"]?.arrayValue)
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items[0]["id"]?.stringValue, "legacy")
  }

  /// A `queues` key that is present but not a map is still a broken frame.
  func testMalformedLegacyQueuesStillThrow() {
    let recorder = Recorder()
    var state: [String: [JSONValue]]?
    let frame = baseline(queues: .string("not-a-map"), projections: nil)
    XCTAssertThrowsError(try MobileGatewayControlPump.installSessionQueueBaseline(
      frame["queues"],
      projections: frame["projections"],
      state: &state,
      onFrame: { recorder.append($0) }
    ))
    XCTAssertTrue(recorder.recorded.isEmpty)
  }

  /// One malformed inbox message costs that message, never the queue or the stream.
  func testInboxMessagesWithoutContentAreSkipped() {
    let items = MobileGatewayControlPump.queueItems(fromInbox: .object([
      "next-turn": .array([
        .object(["id": .string("no-content")]),
        .object(["id": .string(""), "content": .array([])]),
        message(id: "m1", text: "留下", source: .object(["kind": .string("user")])),
      ]),
    ]))
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items[0]["id"]?.stringValue, "m1")
    XCTAssertTrue(MobileGatewayControlPump.queueItems(fromInbox: nil).isEmpty)
    XCTAssertTrue(MobileGatewayControlPump.queueItems(fromInbox: .object([:])).isEmpty)
  }
}
