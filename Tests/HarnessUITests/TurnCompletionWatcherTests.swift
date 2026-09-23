import Foundation
import HarnessIM
import HarnessKit
import XCTest

@testable import HarnessUI

/// A scripted `session/follow` subscriber.
///
/// The same idea as `ApprovalAlertCenterTests`'s event-stream stub: frames are handed in by the
/// test, and frames sent before the stream is opened are held rather than dropped, so a test never
/// has to race the consumer's task. The socket is not under test — the watcher's decisions are.
private final class StubSessionFollower: SessionFollowing, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [SessionFollowFrame] = []
  private var continuation: AsyncThrowingStream<SessionFollowFrame, Error>.Continuation?
  private(set) var closed = false
  /// Set to make `openStream` throw instead of opening, which is how a harness that does not serve
  /// `session/follow` behaves.
  var openError: Error?

  init(frames: [SessionFollowFrame] = []) {
    self.pending = frames
  }

  var isOpen: Bool {
    lock.lock(); defer { lock.unlock() }
    return continuation != nil
  }

  func emit(_ frame: SessionFollowFrame) {
    lock.lock()
    let sink = continuation
    if sink == nil { pending.append(frame) }
    lock.unlock()
    sink?.yield(frame)
  }

  /// End the stream the way the harness does, which the watcher must treat as "re-subscribe".
  func finish() {
    lock.lock()
    let sink = continuation
    continuation = nil
    lock.unlock()
    sink?.finish()
  }

  func openStream(sessionID: String) async throws -> AsyncThrowingStream<SessionFollowFrame, Error> {
    if let openError { throw openError }
    lock.lock()
    let scripted = pending
    pending = []
    lock.unlock()
    return AsyncThrowingStream { continuation in
      self.lock.lock(); self.continuation = continuation; self.lock.unlock()
      for frame in scripted { continuation.yield(frame) }
      // Stay open after the script: a follow stream is long-lived.
    }
  }

  func close() async {
    lock.lock(); closed = true; lock.unlock()
  }
}

/// Collects the completions the watcher reports, across the actor boundary.
private actor CompletionRecorder {
  private(set) var completions: [TurnCompletion] = []
  func record(_ completion: TurnCompletion) { completions.append(completion) }
}

/// Collects the running narration the watcher reports, across the actor boundary.
private actor NarrationRecorder {
  private(set) var segments: [AssistantTextSegment] = []
  func record(_ segment: AssistantTextSegment) { segments.append(segment) }
}

/// Counts how often a session's stream was opened.
private actor OpenCounter {
  private(set) var count = 0
  func record() { count += 1 }
}

/// A thread-safe place for the factory to hand each stub to the test.
private final class FollowerRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var stubs: [String: StubSessionFollower] = [:]

  func store(_ stub: StubSessionFollower, for sessionID: String) {
    lock.lock(); stubs[sessionID] = stub; lock.unlock()
  }

  func stub(for sessionID: String) -> StubSessionFollower? {
    lock.lock(); defer { lock.unlock() }
    return stubs[sessionID]
  }
}

final class TurnCompletionWatcherTests: XCTestCase {
  private var registry: FollowerRegistry!
  private var recorder: CompletionRecorder!
  private var narration: NarrationRecorder!

  override func setUp() {
    super.setUp()
    registry = FollowerRegistry()
    recorder = CompletionRecorder()
    narration = NarrationRecorder()
  }

  /// A watcher whose streams come from stubs, plus the registry those stubs land in.
  private func makeWatcher(
    sessionLimit: Int = TurnCompletionWatcher.defaultSessionLimit,
    retryBase: TimeInterval = 0.01,
    retryCeiling: TimeInterval = 0.05,
    openError: @escaping @Sendable (String) -> Error? = { _ in nil }
  ) -> TurnCompletionWatcher {
    let registry = registry!
    let recorder = recorder!
    let narration = narration!
    return TurnCompletionWatcher(
      sessionLimit: sessionLimit,
      retryBase: retryBase,
      retryCeiling: retryCeiling,
      followerFactory: { sessionID in
        if let error = openError(sessionID) { throw error }
        let stub = StubSessionFollower()
        registry.store(stub, for: sessionID)
        return stub
      },
      onCompletion: { completion in
        await recorder.record(completion)
      },
      onAssistantText: { segment in
        await narration.record(segment)
      }
    )
  }

  private func event(_ type: String, turn: Int? = nil, seq: Int? = nil, reason: String? = nil) -> SessionFollowFrame {
    var data: [String: JSONValue] = [:]
    if let turn { data["turn"] = .number(Double(turn)) }
    if let reason { data["reason"] = .object(["kind": .string(reason)]) }
    return .event(type: type, seq: seq, turn: turn, data: .object(data))
  }

  /// Wait until a condition holds, failing the test rather than hanging.
  private func wait(
    _ description: String,
    timeout: TimeInterval = 2,
    until condition: @escaping () async -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(description)")
  }

  private func waitUntilLive(_ watcher: TurnCompletionWatcher, sessionID: String) async {
    await wait("\(sessionID) to go live") { await watcher.state(of: sessionID) == .live }
  }

  private func waitForCompletions(_ count: Int) async {
    await wait("\(count) completion(s)") { await self.recorder.completions.count >= count }
  }

  /// End a session's stream and wait for the *replacement* one.
  ///
  /// Waiting on `state == .live` is not enough: the state is still `.live` from the stream that just
  /// ended, so a frame emitted at that moment goes to a closed stub. The factory hands out a fresh
  /// stub per open, so identity is the reliable signal.
  @discardableResult
  private func reconnect(_ sessionID: String) async -> StubSessionFollower? {
    let previous = registry.stub(for: sessionID)
    previous?.finish()
    await wait("a new subscription for \(sessionID)") {
      guard let current = self.registry.stub(for: sessionID) else { return false }
      return current !== previous
    }
    return registry.stub(for: sessionID)
  }

  // MARK: - The history rule

  /// The boundary rule: frames that arrive **before** the opening snapshot are not live and must
  /// never be announced.
  ///
  /// This is what keeps a re-subscription — after a stream ends, a restart, or a reconnect — from
  /// replaying turns the user already saw. A turn ending that arrives afterwards is a different
  /// thing and is reported, which the second half of the test pins down so the first half cannot
  /// pass by reporting nothing at all.
  func testFramesBeforeTheSnapshotAreNotReported() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    let stub = registry.stub(for: "s1")
    stub?.emit(event("turn/end", turn: 1, reason: "completed"))
    stub?.emit(event("turn/end", turn: 2, reason: "error"))
    try? await Task.sleep(nanoseconds: 60_000_000)
    var reported = await recorder.completions
    XCTAssertTrue(reported.isEmpty, "frames before the snapshot are not live: \(reported)")

    // The boundary, then one live ending.
    stub?.emit(.snapshot(cursor: 100, records: []))
    stub?.emit(event("turn/end", turn: 3, reason: "completed"))
    await waitForCompletions(1)

    reported = await recorder.completions
    XCTAssertEqual(reported.map(\.turn), [3], "exactly the post-snapshot ending is live")
    await watcher.stop()
  }

  func testTurnsAfterTheSnapshotAreReported() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1", title: "Ship it")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    let stub = registry.stub(for: "s1")
    stub?.emit(.snapshot(cursor: 10, records: []))
    stub?.emit(event("turn/end", turn: 1, reason: "completed"))

    await waitForCompletions(1)
    let reported = await recorder.completions
    XCTAssertEqual(reported.count, 1)
    XCTAssertEqual(reported[0].sessionID, "s1")
    XCTAssertEqual(reported[0].sessionTitle, "Ship it")
    XCTAssertEqual(reported[0].kind, .completed)
    XCTAssertEqual(reported[0].turn, 1)
    await watcher.stop()
  }

  // MARK: - Running narration

  /// A `assistant/message` frame with text in it, the way the harness writes one per model step.
  private func assistantText(
    _ text: String,
    turn: Int? = 1,
    step: Int = 1,
    seq: Int? = nil
  ) -> SessionFollowFrame {
    var data: [String: JSONValue] = [
      "message": .object([
        "id": .string("m-\(step)"),
        "role": .string("assistant"),
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
      ]),
      "step": .number(Double(step)),
    ]
    if let turn { data["turn"] = .number(Double(turn)) }
    return .event(type: "assistant/message", seq: seq, turn: turn, data: .object(data))
  }

  private func waitForNarration(_ count: Int) async {
    await wait("\(count) narration segment(s)") { await self.narration.segments.count >= count }
  }

  /// The feature: the white text a running turn commits reaches the forwarder as it is written, with
  /// the session it belongs to and the turn and cursor it came from.
  func testRunningNarrationIsReportedAsItArrives() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1", title: "报告")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    let stub = registry.stub(for: "s1")
    stub?.emit(.snapshot(cursor: 10, records: []))
    stub?.emit(assistantText("这个要分两步验证。", turn: 4, step: 3, seq: 11))

    await waitForNarration(1)
    let reported = await narration.segments
    XCTAssertEqual(reported.count, 1)
    XCTAssertEqual(reported[0].sessionID, "s1")
    XCTAssertEqual(reported[0].sessionTitle, "报告")
    XCTAssertEqual(reported[0].text, "这个要分两步验证。")
    XCTAssertEqual(reported[0].turn, 4)
    XCTAssertEqual(reported[0].step, 3)
    XCTAssertEqual(reported[0].seq, 11)
    XCTAssertFalse(reported[0].isSubagent)
    await watcher.stop()
  }

  /// A step that only called a tool has no text, and must not become an empty phone message.
  func testStepsWithoutTextReportNoNarration() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    let stub = registry.stub(for: "s1")
    stub?.emit(.snapshot(cursor: 0, records: []))
    stub?.emit(.event(type: "assistant/message", seq: 1, turn: 1, data: .object([
      "turn": .number(1),
      "message": .object([
        "content": .array([.object(["type": .string("tool_use"), "id": .string("t"), "name": .string("Bash")])]),
      ]),
    ])))
    stub?.emit(event("tool/result", turn: 1, seq: 2))
    try? await Task.sleep(nanoseconds: 60_000_000)

    let reported = await narration.segments
    XCTAssertTrue(reported.isEmpty, "只有正文才算播报：\(reported)")
    await watcher.stop()
  }

  /// The baseline rule applies to narration too: the first snapshot is history, and replaying it
  /// would push yesterday's paragraphs to a phone on every app launch.
  func testTheFirstSnapshotDoesNotReplayNarration() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    registry.stub(for: "s1")?.emit(.snapshot(cursor: 12, records: [
      SessionFollowRecord(type: "assistant/message", seq: 11, turn: 2, data: .object([
        "turn": .number(2),
        "message": .object([
          "content": .array([.object(["type": .string("text"), "text": .string("昨天说过的话")])]),
        ]),
      ])),
    ]))
    try? await Task.sleep(nanoseconds: 60_000_000)

    let reported = await narration.segments
    XCTAssertTrue(reported.isEmpty, "首次订阅的页面是历史，不是新闻：\(reported)")
    await watcher.stop()
  }

  /// The other half: a paragraph missed while the stream was down arrives in the next snapshot's
  /// page, and that one *is* news — the phone never heard it.
  func testAReconnectCatchesUpOnTheParagraphsItMissed() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1", title: "报告")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    registry.stub(for: "s1")?.emit(.snapshot(cursor: 10, records: []))
    registry.stub(for: "s1")?.emit(assistantText("流还活着时说的话", turn: 4, step: 1, seq: 11))
    await waitForNarration(1)

    let reconnected = await reconnect("s1")
    reconnected?.emit(.snapshot(cursor: 20, records: [
      SessionFollowRecord(type: "assistant/message", seq: 15, turn: 4, data: .object([
        "turn": .number(4),
        "message": .object([
          "content": .array([.object(["type": .string("text"), "text": .string("断线期间说的话")])]),
        ]),
      ])),
    ]))

    await waitForNarration(2)
    let reported = await narration.segments
    XCTAssertEqual(reported.map(\.text), ["流还活着时说的话", "断线期间说的话"])
    XCTAssertEqual(reported.map(\.sessionTitle), ["报告", "报告"], "标题来自目标，不是事件")
    await watcher.stop()
  }

  // MARK: - Catching up across a reconnect

  /// The failure this watcher used to have, reproduced: a harness closes a subscription taken
  /// mid-turn almost immediately, and the ending lands in the *next* snapshot rather than on a live
  /// frame. Treating that page as pure history meant a session in use never reported anything at all.
  func testAReconnectCatchesUpOnEndingsFromTheOpeningPage() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    // First subscription: the baseline, then one ending that arrived live.
    registry.stub(for: "s1")?.emit(.snapshot(cursor: 10, records: []))
    registry.stub(for: "s1")?.emit(event("turn/end", turn: 1, seq: 11, reason: "completed"))
    await waitForCompletions(1)

    // The stream dies mid-turn — what a live harness does — and the ending it missed is now only in
    // the page the re-subscription opens with.
    let reconnected = await reconnect("s1")
    reconnected?.emit(.snapshot(cursor: 20, records: [
      SessionFollowRecord(type: "turn/end", seq: 15, turn: 2, data: .object([
        "turn": .number(2), "reason": .object(["kind": .string("completed")]),
      ])),
      SessionFollowRecord(type: "turn/start", seq: 16, turn: 3, data: .object(["turn": .number(3)])),
    ]))

    await waitForCompletions(2)
    let reported = await recorder.completions
    XCTAssertEqual(reported.map(\.turn), [1, 2], "the missed ending is reported exactly once: \(reported)")
    await watcher.stop()
  }

  /// The other half of that rule: the *first* snapshot is still a baseline. Nothing in it may be
  /// announced, or every app launch would replay the turns the user already saw.
  func testTheFirstSnapshotIsOnlyABaseline() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    registry.stub(for: "s1")?.emit(.snapshot(cursor: 30, records: [
      SessionFollowRecord(type: "turn/end", seq: 29, turn: 7, data: .object([
        "turn": .number(7), "reason": .object(["kind": .string("completed")]),
      ])),
    ]))
    try? await Task.sleep(nanoseconds: 80_000_000)

    let reported = await recorder.completions
    XCTAssertTrue(reported.isEmpty, "history is never replayed: \(reported)")

    // …and an ending that arrives live after it still is.
    registry.stub(for: "s1")?.emit(event("turn/end", turn: 8, seq: 31, reason: "completed"))
    await waitForCompletions(1)
    let turns = await recorder.completions.map(\.turn)
    XCTAssertEqual(turns, [8])
    await watcher.stop()
  }

  /// A page whose records were already delivered live must not be announced again — a reconnect can
  /// re-send events the previous stream had in flight.
  func testCatchUpDoesNotRepeatWhatWasAlreadyReported() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    registry.stub(for: "s1")?.emit(.snapshot(cursor: 10, records: []))
    registry.stub(for: "s1")?.emit(event("turn/end", turn: 1, seq: 11, reason: "completed"))
    await waitForCompletions(1)

    let reconnected = await reconnect("s1")
    // The same ending, this time inside the page.
    reconnected?.emit(.snapshot(cursor: 12, records: [
      SessionFollowRecord(type: "turn/end", seq: 11, turn: 1, data: .object([
        "turn": .number(1), "reason": .object(["kind": .string("completed")]),
      ])),
      SessionFollowRecord(type: "turn/end", seq: 12, turn: 2, data: .object([
        "turn": .number(2), "reason": .object(["kind": .string("completed")]),
      ])),
    ]))
    await waitForCompletions(2)

    let reported = await recorder.completions
    XCTAssertEqual(reported.map(\.turn), [1, 2], "seq 11 was already announced: \(reported)")
    await watcher.stop()
  }

  /// A session that leaves the target set and comes back gets a fresh baseline: replaying everything
  /// that happened while it was out would be a burst of stale notifications.
  func testASessionThatLeavesAndReturnsReBaselines() async {
    let watcher = makeWatcher(sessionLimit: 1)
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")
    registry.stub(for: "s1")?.emit(.snapshot(cursor: 10, records: []))
    registry.stub(for: "s1")?.emit(event("turn/end", turn: 1, seq: 11, reason: "completed"))
    await waitForCompletions(1)

    // Culled by a newer session, then named again.
    await watcher.setTargets([.init(sessionID: "s2")], includeSubagents: false)
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await wait("s1 to be followed again") { await watcher.state(of: "s1") == .live }
    registry.stub(for: "s1")?.emit(.snapshot(cursor: 40, records: [
      SessionFollowRecord(type: "turn/end", seq: 39, turn: 9, data: .object([
        "turn": .number(9), "reason": .object(["kind": .string("completed")]),
      ])),
    ]))
    try? await Task.sleep(nanoseconds: 80_000_000)

    let reported = await recorder.completions
    XCTAssertEqual(reported.map(\.turn), [1], "only the turn reported while it was followed: \(reported)")
    await watcher.stop()
  }

  /// A stream that carries nothing and ends immediately must back off instead of hammering the
  /// harness: measured in production, one session re-snapshotted ~1.9 MB every 12 seconds for hours.
  func testAStreamThatCarriesNothingBacksOff() async {
    let opens = OpenCounter()
    let watcher = TurnCompletionWatcher(
      retryBase: 0.05,
      retryCeiling: 0.5,
      followerFactory: { _ in
        await opens.record()
        let stub = StubSessionFollower()
        stub.finish()  // opens, snapshots nothing, ends — every time
        return stub
      },
      onCompletion: { _ in }
    )
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    try? await Task.sleep(nanoseconds: 300_000_000)

    let count = await opens.count
    // Without the backoff this is one open per retryBase (≈6 in 300 ms); with it, 0 / +100 / +200 ms.
    XCTAssertLessThanOrEqual(count, 4, "an empty, instantly-ending stream must back off, not spin (\(count) opens)")
    await watcher.stop()
  }

  // MARK: - Which endings reach the user
  /// One table, because this is a product decision rather than an implementation detail.
  func testOnlyEndingsWorthAnnouncingAreReported() async {
    let cases: [(reason: String, expected: [TurnEndKind])] = [
      ("completed", [.completed]),
      ("max-tokens", [.maxTokens]),
      ("error", [.error]),
      ("blocked", [.blocked]),
      ("aborted", []),
      ("interrupted", []),
      ("something-new", []),
    ]
    for (reason, expected) in cases {
      let registry = FollowerRegistry()
      let recorder = CompletionRecorder()
      let watcher = TurnCompletionWatcher(
        retryBase: 0.01,
        retryCeiling: 0.05,
        followerFactory: { _ in
          let stub = StubSessionFollower()
          registry.store(stub, for: "s1")
          return stub
        },
        onCompletion: { await recorder.record($0) }
      )
      await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
      await wait("\(reason) to go live") { await watcher.state(of: "s1") == .live }

      let stub = registry.stub(for: "s1")
      stub?.emit(.snapshot(cursor: 0, records: []))
      stub?.emit(event("turn/end", turn: 1, reason: reason))
      // Wait for the frame to be processed by waiting for a following, never-reported frame.
      stub?.emit(event("turn/start", turn: 2))
      try? await Task.sleep(nanoseconds: 60_000_000)

      let reported = await recorder.completions.map(\.kind)
      XCTAssertEqual(reported, expected, reason)
      await watcher.stop()
    }
  }

  func testFailureCarriesTheStructuredError() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    registry.stub(for: "s1")?.emit(.snapshot(cursor: 0, records: []))
    registry.stub(for: "s1")?.emit(.event(
      type: "turn/end",
      seq: nil,
      turn: nil,
      data: .object([
        "turn": .number(4),
        "reason": .object([
          "kind": .string("error"),
          "error": .object([
            "code": .string("RATE_LIMITED"),
            "message": .string("slow down"),
          ]),
        ]),
      ])
    ))

    await waitForCompletions(1)
    let reported = await recorder.completions
    XCTAssertEqual(reported[0].failureCode, "RATE_LIMITED")
    XCTAssertEqual(reported[0].failureMessage, "slow down")
    XCTAssertEqual(reported[0].turn, 4)
    await watcher.stop()
  }

  func testNonTurnEventsAreIgnored() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    let stub = registry.stub(for: "s1")
    stub?.emit(.snapshot(cursor: 0, records: []))
    stub?.emit(event("tool/call", turn: 1))
    stub?.emit(event("assistant/message", turn: 1))
    stub?.emit(.assistantStream)
    stub?.emit(.unrecognized(type: "future-frame"))
    stub?.emit(event("turn/start", turn: 2))
    try? await Task.sleep(nanoseconds: 60_000_000)

    let reported = await recorder.completions
    XCTAssertTrue(reported.isEmpty)
    await watcher.stop()
  }

  // MARK: - Target management

  func testSubagentsAreSkippedUnlessAskedFor() async {
    let watcher = makeWatcher()
    let targets = [
      TurnCompletionWatcher.WatchTarget(sessionID: "parent"),
      TurnCompletionWatcher.WatchTarget(sessionID: "child", isSubagent: true),
    ]

    await watcher.setTargets(targets, includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "parent")
    try? await Task.sleep(nanoseconds: 30_000_000)
    var childState = await watcher.state(of: "child")
    XCTAssertEqual(childState, .stopped, "a subagent must not be followed while the switch is off")

    await watcher.setTargets(targets, includeSubagents: true)
    await waitUntilLive(watcher, sessionID: "child")
    childState = await watcher.state(of: "child")
    XCTAssertEqual(childState, .live)
    await watcher.stop()
  }

  /// A long session history must not become one socket per session.
  func testOnlyTheMostRecentSessionsWithinTheLimitAreFollowed() async {
    let watcher = makeWatcher(sessionLimit: 2)
    let now = Date()
    let targets = (0..<5).map { index in
      TurnCompletionWatcher.WatchTarget(
        sessionID: "s\(index)",
        updatedAt: now.addingTimeInterval(TimeInterval(-index))
      )
    }
    await watcher.setTargets(targets, includeSubagents: false)

    await waitUntilLive(watcher, sessionID: "s0")
    await waitUntilLive(watcher, sessionID: "s1")
    try? await Task.sleep(nanoseconds: 40_000_000)

    let followed = await ["s0", "s1", "s2", "s3", "s4"].asyncMap { await watcher.state(of: $0) }
    XCTAssertEqual(followed, [.live, .live, .stopped, .stopped, .stopped])
    await watcher.stop()
  }

  func testDroppingATargetStopsItsSubscription() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    await watcher.setTargets([], includeSubagents: false)
    try? await Task.sleep(nanoseconds: 40_000_000)
    let state = await watcher.state(of: "s1")
    XCTAssertEqual(state, .stopped)
    await watcher.stop()
  }

  func testSetTargetsIsIdempotentAndDoesNotRestartALiveStream() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")
    let stub = registry.stub(for: "s1")

    // Push the same list again, the way a caller refreshing the session list does.
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    try? await Task.sleep(nanoseconds: 30_000_000)

    XCTAssertFalse(stub?.closed ?? true, "an already-followed session must keep its stream")
    stub?.emit(.snapshot(cursor: 0, records: []))
    stub?.emit(event("turn/end", turn: 1, reason: "completed"))
    await waitForCompletions(1)
    await watcher.stop()
  }

  // MARK: - Stream lifecycle

  /// A stream that ends is normal; the watcher re-subscribes. Without this a session would go
  /// quiet for the rest of the app's life the first time the harness closed a stream.
  func testAnEndedStreamIsReSubscribed() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")

    registry.stub(for: "s1")?.finish()
    // The factory hands out a fresh stub on every open, so the watcher going live again is the
    // evidence that it reconnected.
    await wait("a re-subscription") { await watcher.state(of: "s1") == .live }
    await watcher.stop()
  }

  /// A harness that does not serve `session/follow` answers with a capability refusal. Retrying
  /// cannot help, so the session is written off and the caller can say so.
  func testACapabilityRefusalMarksTheSessionUnavailable() async {
    let refusal = HarnessAPIError(
      code: .rejected,
      message: "service unavailable",
      providerCode: "gateway/service-unavailable"
    )
    let watcher = makeWatcher(openError: { _ in refusal })
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)

    await wait("the session to be written off") {
      if case .unavailable = await watcher.state(of: "s1") { return true }
      return false
    }
    let unavailable = await watcher.hasUnavailableSubscription
    XCTAssertTrue(unavailable)
    await watcher.stop()
  }

  /// A transient failure must not write a session off: guessing "unsupported" from a network blip
  /// would silently stop watching a session that works.
  func testATransientFailureKeepsRetrying() async {
    let blip = HarnessAPIError(code: .http, message: "connection reset", status: 503)
    let registry = self.registry!
    let recorder = self.recorder!
    let watcher = TurnCompletionWatcher(
      retryBase: 0.01,
      retryCeiling: 0.02,
      followerFactory: { _ in
        // Fail the first two attempts, then serve a real stream.
        let stub = StubSessionFollower()
        registry.store(stub, for: "s1")
        throw blip
      },
      onCompletion: { await recorder.record($0) }
    )
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)

    try? await Task.sleep(nanoseconds: 120_000_000)
    let unavailable = await watcher.hasUnavailableSubscription
    XCTAssertFalse(unavailable, "a transient failure must not be treated as unsupported")
    await watcher.stop()
  }

  /// After `stop()` the watcher must not resurrect subscriptions, because the app calls it when the
  /// harness connection is being torn down.
  func testStopIsTerminal() async {
    let watcher = makeWatcher()
    await watcher.setTargets([.init(sessionID: "s1")], includeSubagents: false)
    await waitUntilLive(watcher, sessionID: "s1")
    await watcher.stop()

    await watcher.setTargets([.init(sessionID: "s2")], includeSubagents: false)
    try? await Task.sleep(nanoseconds: 40_000_000)
    let state = await watcher.state(of: "s2")
    XCTAssertEqual(state, .stopped)
    XCTAssertNil(registry.stub(for: "s2"))
  }

  // MARK: - Failure classification

  func testCapabilityRefusalsAreRecognisedAndTransientErrorsAreNot() {
    XCTAssertTrue(TurnCompletionWatcher.isCapabilityRefusal(HarnessAPIError(
      code: .rejected, message: "x", providerCode: "gateway/service-unavailable"
    )))
    XCTAssertFalse(TurnCompletionWatcher.isCapabilityRefusal(HarnessAPIError(
      code: .http, message: "x", status: 503
    )))
    XCTAssertFalse(TurnCompletionWatcher.isCapabilityRefusal(HarnessAPIError(
      code: .unauthorized, message: "x", status: 401
    )))
    XCTAssertFalse(TurnCompletionWatcher.isCapabilityRefusal(URLError(.timedOut)))
  }
}

private extension Array {
  /// `asyncMap` over the five fixed states above; small enough that a real concurrency helper would
  /// be more machinery than the test needs.
  func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
    var result: [T] = []
    for element in self { result.append(await transform(element)) }
    return result
  }
}
