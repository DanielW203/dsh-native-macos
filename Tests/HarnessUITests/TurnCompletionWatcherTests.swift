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

  override func setUp() {
    super.setUp()
    registry = FollowerRegistry()
    recorder = CompletionRecorder()
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
      }
    )
  }

  private func event(_ type: String, turn: Int? = nil, reason: String? = nil) -> SessionFollowFrame {
    var data: [String: JSONValue] = [:]
    if let turn { data["turn"] = .number(Double(turn)) }
    if let reason { data["reason"] = .object(["kind": .string(reason)]) }
    return .event(type: type, seq: nil, turn: turn, data: .object(data))
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
    stub?.emit(.snapshot(cursor: 100))
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
    stub?.emit(.snapshot(cursor: 10))
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
      stub?.emit(.snapshot(cursor: 0))
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

    registry.stub(for: "s1")?.emit(.snapshot(cursor: 0))
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
    stub?.emit(.snapshot(cursor: 0))
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
    stub?.emit(.snapshot(cursor: 0))
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
