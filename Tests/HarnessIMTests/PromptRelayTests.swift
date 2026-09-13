import Foundation
import HarnessKit
import XCTest

@testable import HarnessIM

/// A scripted event stream: it yields the frames a test hands it and records every answer.
final class StubRemoteEventStream: RemoteEventStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var frames: [RemoteEventFrame]
  private var answers: [(eventID: String, outcome: String)] = []
  private var continuation: AsyncThrowingStream<RemoteEventFrame, Error>.Continuation?
  private(set) var closed = false
  /// When true, `open()` throws — the "harness restarted / stream refused" path.
  var failsToOpen = false
  /// When true, `answer` throws — the "somebody already answered this" path.
  var failsToAnswer = false
  /// Frames handed to each successive `open()`, for tests that reconnect. Longer than the
  /// number of opens means later connections see nothing new, which is what a quiet host does.
  /// When empty, `frames` keeps its original one-shot semantics.
  var framesPerOpen: [[RemoteEventFrame]] = []
  /// The first `n` opens throw; later ones succeed. Resets with `failsToOpen`.
  var failFirstOpens = 0
  private(set) var openCount = 0

  init(frames: [RemoteEventFrame]) {
    self.frames = frames
  }

  /// Push one frame after the stream is open, for tests that must wait for state to exist.
  func emit(_ frame: RemoteEventFrame) {
    lock.lock()
    let sink = continuation
    lock.unlock()
    sink?.yield(frame)
  }

  /// End the current connection without stopping the relay — the harness-restart shape. The
  /// relay is expected to reopen and the stub then serves the next `framesPerOpen` entry.
  func emitEnd() {
    lock.lock()
    let sink = continuation
    continuation = nil
    lock.unlock()
    sink?.finish()
  }

  var isOpen: Bool {
    lock.lock(); defer { lock.unlock() }
    return continuation != nil
  }

  var recordedAnswers: [(eventID: String, outcome: String)] {
    lock.lock(); defer { lock.unlock() }
    return answers
  }

  func open() async throws -> AsyncThrowingStream<RemoteEventFrame, Error> {
    lock.lock()
    openCount += 1
    let attempt = openCount
    let shouldFail = failsToOpen || attempt <= failFirstOpens
    var scripted: [RemoteEventFrame] = []
    // A refused open must not consume the script: the script belongs to the connection that
    // actually carries frames, and the relay is expected to retry after a refusal.
    if !shouldFail {
      if framesPerOpen.isEmpty {
        scripted = frames
        frames = []
      } else {
        let index = attempt - 1
        scripted = index < framesPerOpen.count ? framesPerOpen[index] : []
      }
    }
    lock.unlock()

    if shouldFail {
      throw HarnessAPIError(code: .http, message: "stream refused", status: 503)
    }
    return AsyncThrowingStream { continuation in
      self.lock.lock(); self.continuation = continuation; self.lock.unlock()
      for frame in scripted { continuation.yield(frame) }
      // Stay open after the script: the relay is a long-lived consumer.
    }
  }

  func answer(eventID: String, value: JSONValue) async throws {
    if failsToAnswer {
      throw HarnessAPIError(code: .rejected, message: "该请求已被处理")
    }
    // The carrier takes any JSON now, so the recorded "outcome" is the string form of the
    // value: an approval's outcome literal, or a question's `answers` payload.
    let rendered = value.stringValue ?? (try? value.serialized()) ?? ""
    lock.lock(); answers.append((eventID, rendered)); lock.unlock()
  }

  func close() async {
    lock.lock(); closed = true; lock.unlock()
  }
}

private func waterfallFrame(
  eventID: String = "evt-1",
  agentID: String = "session-ours",
  event: String = "approval/request",
  tool: String = "bash",
  reason: String? = "命令会写入工作区"
) -> RemoteEventFrame {
  var request: [String: JSONValue] = ["toolName": .string(tool)]
  if let reason { request["reason"] = .string(reason) }
  return .waterfall(eventID: eventID, agentID: agentID, event: event, request: .object(request))
}

final class RemoteEventFrameTests: XCTestCase {
  /// The frame vocabulary measured against the shipped gateway client.
  func testParsesEveryFrameTheHostSends() throws {
    XCTAssertEqual(
      RemoteEventFrame.parse(try JSONValue.parse(#"{"type":"ready","clientId":"c-1","host":{"home":"/h"}}"#)),
      .ready(clientID: "c-1")
    )
    XCTAssertEqual(
      RemoteEventFrame.parse(try JSONValue.parse(#"{"type":"cancel","eventId":"e-1"}"#)),
      .cancel(eventID: "e-1")
    )
    XCTAssertEqual(
      RemoteEventFrame.parse(try JSONValue.parse(#"{"type":"emit","event":"session/created","args":[{"a":1}]}"#)),
      .emit(event: "session/created", args: [.object(["a": .number(1)])])
    )
    XCTAssertEqual(
      RemoteEventFrame.parse(try JSONValue.parse(
        #"{"type":"waterfall","event":"approval/request","eventId":"e-2","agentId":"session-1","request":{"toolName":"bash","reason":"why"}}"#
      )),
      .waterfall(eventID: "e-2", agentID: "session-1", event: "approval/request",
                 request: .object(["toolName": .string("bash"), "reason": .string("why")]))
    )
  }

  /// A harness that grows a new frame type must not break the channel: unknown shapes are
  /// ignored, malformed ones are dropped rather than crashing the stream.
  func testIgnoresUnknownAndMalformedFrames() throws {
    for text in [
      #"{"type":"brand-new","whatever":1}"#,
      #"{"type":"ready"}"#,
      #"{"type":"waterfall","event":"approval/request"}"#,
      #"{"type":"cancel"}"#,
      #"[]"#,
    ] {
      XCTAssertNil(RemoteEventFrame.parse(try JSONValue.parse(text)), "parsed \(text)")
    }
  }
}

final class ApprovalReplyTests: XCTestCase {
  func testRecognisesBothDecisions() {
    for text in ["批准", " 批准 ", "同意", "OK", "yes", "Approve", "批准！", "可以"] {
      XCTAssertEqual(ApprovalReply.decide(text), .allowedOnce, text)
    }
    for text in ["拒绝", "不同意", "no", "Deny", "不行", "拒绝。"] {
      XCTAssertEqual(ApprovalReply.decide(text), .rejected, text)
    }
  }

  /// Ordinary chat must never be mistaken for a decision, or a sentence containing 「可以」
  /// would approve a tool call.
  func testIgnoresOrdinaryChat() {
    for text in ["", "  ", "可以帮我看看这个文件吗", "我觉得这个不太行，改成方案二", "批准一下那个东西", "hello world"] {
      XCTAssertNil(ApprovalReply.decide(text), text)
    }
  }
}

/// The third answer a plan review has on a phone: an opinion, with or without its keyword.
final class PlanReviewReplyTests: XCTestCase {
  func testReadsTheTwoWords() {
    for text in ["批准", " 批准 ", "同意", "OK", "Approve", "批准！"] {
      XCTAssertEqual(PlanReviewReply.decide(text), .approve, text)
    }
    for text in ["拒绝", "不同意", "no", "Deny", "不行", "拒绝。"] {
      XCTAssertEqual(PlanReviewReply.decide(text), .keepPlanning(feedback: nil), text)
    }
  }

  func testReadsAnOpinionWithItsKeyword() {
    for text in ["说 第二步拆成两轮", "说：第二步拆成两轮", "说，第二步拆成两轮", "反馈 第二步拆成两轮"] {
      XCTAssertEqual(PlanReviewReply.decide(text), .keepPlanning(feedback: "第二步拆成两轮"), text)
    }
    // An ASCII keyword strips with its separator and keeps the words that follow.
    XCTAssertEqual(PlanReviewReply.decide("say: split step 2"), .keepPlanning(feedback: "split step 2"))
  }

  /// An opinion that merely begins with 「说」 is not a keyword: it is passed through whole.
  func testReadsAnOpinionWithoutItsKeyword() {
    XCTAssertEqual(PlanReviewReply.decide("说得好，但第二步太粗"), .keepPlanning(feedback: "说得好，但第二步太粗"))
    XCTAssertEqual(PlanReviewReply.decide("意见是第二步太粗"), .keepPlanning(feedback: "意见是第二步太粗"))
  }

  /// A bare keyword promises words it does not have; guessing would send an empty opinion.
  func testRefusesAnEmptyKeyword() {
    for text in ["", "  ", "说", "说：", "反馈 ", "say:"] {
      XCTAssertNil(PlanReviewReply.decide(text), text)
    }
  }
}

final class PromptRelayTests: XCTestCase {
  private func makeRelay(
    frames: [RemoteEventFrame],
    routes: [String: PromptRelay.Route] = ["session-ours": .owned("owner@im.wechat")],
    prompts: Box,
    reconnect: PromptRelayReconnect = PromptRelayReconnect(
      initialDelay: .milliseconds(5),
      maximumDelay: .milliseconds(20)
    )
  ) -> (PromptRelay, StubRemoteEventStream) {
    let stream = StubRemoteEventStream(frames: frames)
    let relay = PromptRelay(
      stream: stream,
      route: { sessionID in routes[sessionID] },
      prompt: { sender, text in prompts.append(sender: sender, text: text) },
      reconnect: reconnect
    )
    return (relay, stream)
  }

  final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(sender: String, text: String)] = []
    func append(sender: String, text: String) {
      lock.lock(); entries.append((sender, text)); lock.unlock()
    }
    var all: [(sender: String, text: String)] {
      lock.lock(); defer { lock.unlock() }
      return entries
    }
  }

  /// Records every carrier transition the relay reports, in order.
  final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [PromptRelayConnection] = []
    func append(_ state: PromptRelayConnection) {
      lock.lock(); entries.append(state); lock.unlock()
    }
    var all: [PromptRelayConnection] {
      lock.lock(); defer { lock.unlock() }
      return entries
    }
  }

  private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("condition not met within \(timeout)s")
  }

  func testForwardsAnOwnedRequestAndAnswersIt() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [.ready(clientID: "c-1"), waterfallFrame()], prompts: prompts)
    Task { await relay.run() }

    try await waitUntil { prompts.all.count == 1 }
    let question = try XCTUnwrap(prompts.all.first)
    XCTAssertEqual(question.sender, "owner@im.wechat")
    XCTAssertTrue(question.text.contains("bash"))
    XCTAssertTrue(question.text.contains("命令会写入工作区"))
    XCTAssertTrue(question.text.contains("批准"))

    let decision = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(decision, .approval(.allowedOnce))
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-1"])
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["allowed-once"])
    let remaining = await relay.pendingCount
    XCTAssertEqual(remaining, 0)
  }

  func testRejectionIsForwardedAsRejected() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [waterfallFrame()], prompts: prompts)
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let decision = await relay.submit(sender: "owner@im.wechat", text: "拒绝")
    XCTAssertEqual(decision, .approval(.rejected))
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["rejected"])
  }

  /// A request for a session this channel does not own belongs to the browser; touching it
  /// would make the channel a second, conflicting answerer.
  func testLeavesForeignRequestsAlone() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [waterfallFrame(agentID: "session-someone-else")], prompts: prompts)
    Task { await relay.run() }
    try await Task.sleep(for: .milliseconds(150))

    XCTAssertTrue(prompts.all.isEmpty)
    let pending = await relay.pendingCount
    XCTAssertEqual(pending, 0)
    XCTAssertTrue(stream.recordedAnswers.isEmpty)
  }

  func testNonApprovalWaterfallsAreIgnored() async throws {
    let prompts = Box()
    let (relay, _) = makeRelay(
      frames: [waterfallFrame(event: "user-question/request", tool: "ask_user")],
      prompts: prompts
    )
    Task { await relay.run() }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(prompts.all.isEmpty)
  }

  /// Cancellation drops the pending question so a later 「批准」 cannot answer a dead request.
  func testCancellationClearsThePendingQuestion() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [waterfallFrame(), .cancel(eventID: "evt-1")], prompts: prompts)
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let pending = await relay.pendingApproval(for: "owner@im.wechat")
    XCTAssertNil(pending)
    let decision = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(decision, .notADecision)
    XCTAssertTrue(stream.recordedAnswers.isEmpty)
  }

  /// While a question is pending, unrelated chat is not swallowed.
  func testNonDecisionTextIsNotAnswered() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [waterfallFrame()], prompts: prompts)
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let decision = await relay.submit(sender: "owner@im.wechat", text: "顺便帮我查个东西")
    XCTAssertEqual(decision, .notADecision)
    let stillPending = await relay.pendingApproval(for: "owner@im.wechat")
    XCTAssertNotNil(stillPending, "the question stays answerable")
    XCTAssertTrue(stream.recordedAnswers.isEmpty)
  }

  func testStopClosesTheStream() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [waterfallFrame()], prompts: prompts)
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }
    await relay.stop()
    XCTAssertTrue(stream.closed)
  }

  // MARK: - Carrier lifetime (the "answered but the GUI never changed" report)

  /// The reported failure: the harness was restarted, its port changed, and the carrier died.
  /// The relay kept a `clientId` the host no longer knew, so `/answer` reported success while
  /// the host dropped the result on the floor — no error, no GUI change. The relay must
  /// reconnect instead of staying dead.
  func testRefusedCarrierIsRetriedUntilItOpens() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [waterfallFrame()], prompts: prompts)
    stream.failFirstOpens = 1

    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    XCTAssertGreaterThanOrEqual(stream.openCount, 2, "the relay must reopen a refused carrier")
    let state = await relay.connectionState
    XCTAssertEqual(state, .connected)

    // And the question that arrived on the *second* connection is answerable.
    let decision = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(decision, .approval(.allowedOnce))
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-1"])
  }

  /// The host re-delivers every still-pending request to a reconnecting client, so the same
  /// `eventId` arrives again. Asking the user twice, with the second copy unanswerable, is the
  /// obvious way to get this wrong.
  func testRedeliveredRequestIsNotAskedTwice() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [.ready(clientID: "c-1")], prompts: prompts)
    stream.framesPerOpen = [
      [.ready(clientID: "c-1"), waterfallFrame()],
      // The reconnect: the host replays the same pending request before the new one.
      [.ready(clientID: "c-2"), waterfallFrame(), waterfallFrame(eventID: "evt-2", tool: "write")],
    ]

    let running = Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    stream.emitEnd()
    try await waitUntil { stream.openCount == 2 }
    try await waitUntil { prompts.all.count == 2 }

    // evt-1 must not be asked a second time; only the genuinely new evt-2 is.
    XCTAssertEqual(prompts.all.count, 2, "the replayed request must not be re-asked")
    let answered = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(answered, .approval(.allowedOnce))
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-1"])

    await relay.stop()
    running.cancel()
  }

  /// A reconnect must not silently discard a question the user can still answer: the host
  /// replays it, and the answer has to reach the host on the new connection.
  func testQuestionSurvivesAReconnect() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [], prompts: prompts)
    stream.framesPerOpen = [
      [.ready(clientID: "c-1")],
      [.ready(clientID: "c-2"), waterfallFrame()],
    ]

    let running = Task { await relay.run() }
    // First connection: nothing pending yet.
    try await waitUntil { stream.openCount == 1 }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(prompts.all.isEmpty)

    // The stream ends (harness restart); the relay reconnects and the host replays the request.
    stream.emitEnd()
    try await waitUntil { prompts.all.count == 1 }
    let state = await relay.connectionState
    XCTAssertEqual(state, .connected)

    let decision = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(decision, .approval(.allowedOnce))
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-1"])

    await relay.stop()
    running.cancel()
  }

  /// The distinction the user needed: a broken carrier is reported as broken, not as
  /// "nothing is waiting".
  func testConnectionStateReportsReconnectingThenConnected() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [], prompts: prompts)
    stream.failFirstOpens = 1

    let seen = Seen()
    await relay.setConnectionHandler { state in seen.append(state) }
    Task { await relay.run() }
    try await waitUntil { prompts.all.isEmpty && stream.openCount >= 2 }
    try await waitUntil { seen.all.contains(.connected) }

    XCTAssertTrue(seen.all.contains(.reconnecting(attempt: 1)), "\(seen.all)")
    XCTAssertEqual(seen.all.last, .connected)
    await relay.stop()
  }

  // MARK: - Borrowed questions (phone approvals on)

  /// A desktop session's request is borrowed for the owner, and the question says where it
  /// came from: answering it grants a tool call the user never started from chat.
  func testBorrowedRequestIsForwardedAndLabelled() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [waterfallFrame(agentID: "session-desktop")],
      routes: ["session-desktop": .borrowed("owner@im.wechat")],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let question = try XCTUnwrap(prompts.all.first)
    XCTAssertEqual(question.sender, "owner@im.wechat")
    XCTAssertTrue(question.text.contains("来自桌面会话"), question.text)
    XCTAssertTrue(question.text.contains("bash"), question.text)

    let decision = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(decision, .approval(.allowedOnce))
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-1"])
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["allowed-once"])
  }

  /// Two questions on one phone must both survive. A single slot per address would let the
  /// second overwrite the first and leave its turn blocked with nothing left to answer.
  func testSeveralQuestionsOnOnePhoneAreAnsweredOldestFirst() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [
        waterfallFrame(eventID: "evt-1", agentID: "session-desktop"),
        waterfallFrame(eventID: "evt-2", agentID: "session-other"),
      ],
      routes: [
        "session-desktop": .borrowed("owner@im.wechat"),
        "session-other": .borrowed("owner@im.wechat"),
      ],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 2 }

    let second = try XCTUnwrap(prompts.all.last)
    XCTAssertTrue(second.text.contains("排队"), second.text)
    let queued = await relay.pendingCount
    XCTAssertEqual(queued, 2)

    _ = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-1"])
    let afterFirst = await relay.pendingCount
    XCTAssertEqual(afterFirst, 1)
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["allowed-once"])

    // The second reply must answer the *next* question, not the one already answered.
    _ = await relay.submit(sender: "owner@im.wechat", text: "拒绝")
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-1", "evt-2"])
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["allowed-once", "rejected"])
    let drained = await relay.pendingCount
    XCTAssertEqual(drained, 0)
  }

  /// Cancelling the older of two borrowed questions must leave the newer one answerable.
  func testCancellingOneOfTwoQuestionsKeepsTheOther() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [
        waterfallFrame(eventID: "evt-1", agentID: "session-desktop"),
        waterfallFrame(eventID: "evt-2", agentID: "session-other"),
        .cancel(eventID: "evt-1"),
      ],
      routes: [
        "session-desktop": .borrowed("owner@im.wechat"),
        "session-other": .borrowed("owner@im.wechat"),
      ],
      prompts: prompts
    )
    Task { await relay.run() }
    // The cancel is scripted after both requests, so the second prompt only appears before it
    // is consumed; the sleep is the room the consumer needs to reach the third frame.
    try await waitUntil { prompts.all.count == 2 }
    try await Task.sleep(for: .milliseconds(200))

    let remaining = await relay.pendingCount
    XCTAssertEqual(remaining, 1)
    let survivor = await relay.pendingApproval(for: "owner@im.wechat")
    XCTAssertEqual(survivor?.eventID, "evt-2", "the cancelled question goes, not the queue")

    let decision = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(decision, .approval(.allowedOnce))
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-2"])
  }

  // MARK: - Questions

  /// A `user-questions/request` frame, with the option labels and optional plan-review intent.
  private func questionFrame(
    eventID: String = "evt-q1",
    agentID: String = "session-ours",
    options: [String] = ["甲", "乙"],
    approve: String? = nil,
    detail: String? = nil
  ) -> RemoteEventFrame {
    let labels = options.map { #"{"label":"\#($0)"}"# }.joined(separator: ",")
    let intent = approve.map { #","intent":{"kind":"plan-review","approve":"\#($0)"}"# } ?? ""
    let body = detail.map { #","detail":"\#($0)""# } ?? ""
    let json = #"{"questions":[{"id":"q1","question":"选一个","options":[\#(labels)]\#(intent)\#(body)}]}"#
    return .waterfall(
      eventID: eventID, agentID: agentID, event: "user-questions/request",
      request: (try? JSONValue.parse(json)) ?? .object([:])
    )
  }

  func testForwardsAQuestionAndAnswersItFromTheChat() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [questionFrame()], prompts: prompts)
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let delivered = try XCTUnwrap(prompts.all.first)
    XCTAssertEqual(delivered.sender, "owner@im.wechat")
    XCTAssertTrue(delivered.text.contains("需要你回答"), delivered.text)
    XCTAssertTrue(delivered.text.contains("1) 甲"), delivered.text)
    XCTAssertTrue(delivered.text.contains("/answer 1"), delivered.text)

    let outcome = await relay.answer(sender: "owner@im.wechat", text: "2")
    XCTAssertEqual(outcome, .answered("已回答。"))
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-q1"])
    let sent = try XCTUnwrap(stream.recordedAnswers.first?.outcome)
    XCTAssertTrue(sent.contains("乙"), sent)
    let remaining = await relay.pendingCount
    XCTAssertEqual(remaining, 0)
  }

  /// A bad answer must leave the question answerable rather than dropping it.
  func testAProblemAnswerKeepsTheQuestionAnswerable() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [questionFrame()], prompts: prompts)
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    guard case .problem(let message) = await relay.answer(sender: "owner@im.wechat", text: "9") else {
      return XCTFail("an out-of-range option must be reported")
    }
    XCTAssertTrue(message.contains("甲"), message)
    XCTAssertTrue(stream.recordedAnswers.isEmpty)

    let stillPending = await relay.pendingQuestion(for: "owner@im.wechat")
    XCTAssertNotNil(stillPending, "the question stays answerable")
  }

  /// Plain chat is not an answer to a multiple-choice question — it is also good content.
  func testBareTextDoesNotAnswerAQuestion() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [questionFrame()], prompts: prompts)
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let outcome = await relay.submit(sender: "owner@im.wechat", text: "2")
    XCTAssertEqual(outcome, .notADecision)
    XCTAssertTrue(stream.recordedAnswers.isEmpty)
  }

  /// A plan review reads 「批准」 as naturally as a tool approval does, and the approving
  /// option is the one the host named.
  func testPlanReviewIsApprovedByTheBareWord() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [questionFrame(options: ["开始执行", "继续修改"], approve: "开始执行")],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }
    let delivered = try XCTUnwrap(prompts.all.first).text
    XCTAssertTrue(delivered.contains("「批准」"), delivered)
    XCTAssertTrue(delivered.contains("「拒绝」"), delivered)
    XCTAssertTrue(delivered.contains("「说 你的意见」"), delivered)

    let outcome = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(outcome, .answered("已批准这个计划"))
    let sent = try XCTUnwrap(stream.recordedAnswers.first?.outcome)
    XCTAssertTrue(sent.contains("开始执行"), sent)
  }

  /// 「说 意见」 is the third answer: it stays in plan mode and carries the words back, in the
  /// `custom` field the GUI's own feedback field fills.
  func testPlanReviewCarriesAnOpinionBackAsFeedback() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [questionFrame(options: ["开始执行", "继续修改"], approve: "开始执行")],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let outcome = await relay.submit(sender: "owner@im.wechat", text: "说 第二步拆成两轮")
    XCTAssertEqual(outcome, .answered("已把意见发回给它（继续改计划）"))
    let sent = try XCTUnwrap(stream.recordedAnswers.first?.outcome)
    XCTAssertTrue(sent.contains("第二步拆成两轮"), sent)
    XCTAssertTrue(sent.contains("\"custom\""), sent)
    // Feedback is the selection-less shape the GUI sends, not an option plus text.
    XCTAssertTrue(sent.contains("\"selected\":[]"), sent)
    let remaining = await relay.pendingCount
    XCTAssertEqual(remaining, 0)
  }

  /// Without the keyword the opinion is still an opinion: while a review is open nothing the
  /// phone types can be chat content.
  func testPlanReviewTreatsPlainTextAsFeedback() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [questionFrame(options: ["开始执行", "继续修改"], approve: "开始执行")],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let outcome = await relay.submit(sender: "owner@im.wechat", text: "第二步太粗，拆细一点")
    XCTAssertEqual(outcome, .answered("已把意见发回给它（继续改计划）"))
    let sent = try XCTUnwrap(stream.recordedAnswers.first?.outcome)
    XCTAssertTrue(sent.contains("第二步太粗，拆细一点"), sent)
    let remaining = await relay.pendingCount
    XCTAssertEqual(remaining, 0)
  }

  /// A keyword with nothing after it explains what is missing instead of sending an empty
  /// opinion, and leaves the review answerable.
  func testPlanReviewBareKeywordAsksForTheWords() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [questionFrame(options: ["开始执行", "继续修改"], approve: "开始执行")],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    guard case .problem(let message) = await relay.submit(sender: "owner@im.wechat", text: "说") else {
      return XCTFail("a bare 「说」 must be reported, not guessed at")
    }
    XCTAssertTrue(message.contains("批准"), message)
    XCTAssertTrue(stream.recordedAnswers.isEmpty)
    let remaining = await relay.pendingCount
    XCTAssertEqual(remaining, 1, "the review stays answerable")
  }

  /// `/answer 1` still names the first printed option of a plan review.
  func testPlanReviewAnswersTheFirstOptionThroughSlashAnswer() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [questionFrame(options: ["开始执行", "继续修改"], approve: "开始执行")],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let outcome = await relay.answer(sender: "owner@im.wechat", text: "1")
    XCTAssertEqual(outcome, .answered("已批准这个计划"))
    let sent = try XCTUnwrap(stream.recordedAnswers.first?.outcome)
    XCTAssertTrue(sent.contains("开始执行"), sent)
  }

  /// The plan is the thing being decided, so the phone is shown all of it rather than the
  /// 200-character prefix other questions get — approving a plan you cannot read is a guess.
  func testPlanReviewShowsTheWholePlan() async throws {
    let prompts = Box()
    let plan = String(repeating: "背景说明。", count: 80) + "最后一步：校验。"
    XCTAssertGreaterThan(plan.count, 400, "the fixture must exceed the ordinary detail limit")
    let (relay, _) = makeRelay(
      frames: [questionFrame(options: ["开始执行", "继续修改"], approve: "开始执行", detail: plan)],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let delivered = try XCTUnwrap(prompts.all.first).text
    XCTAssertTrue(delivered.contains("最后一步：校验。"), "the tail of the plan must reach the phone")
  }

  func testPlanReviewIsDeclinedByTheBareWord() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [questionFrame(options: ["开始执行", "继续修改"], approve: "开始执行")],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    let outcome = await relay.submit(sender: "owner@im.wechat", text: "拒绝")
    XCTAssertEqual(outcome, .answered("已拒绝这个计划（让它继续改）"))
    // Declining means any option that is not the approving one.
    let sent = try XCTUnwrap(stream.recordedAnswers.first?.outcome)
    XCTAssertTrue(sent.contains("继续修改"), sent)
  }

  /// Approvals and questions share one queue, so the phone answers what it read first.
  func testApprovalAndQuestionQueueTogether() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(
      frames: [waterfallFrame(eventID: "evt-a"), questionFrame(eventID: "evt-q")],
      prompts: prompts
    )
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 2 }

    // The approval came first, so an approval word settles it and the question survives.
    let first = await relay.submit(sender: "owner@im.wechat", text: "批准")
    XCTAssertEqual(first, .approval(.allowedOnce))
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-a"])

    let second = await relay.answer(sender: "owner@im.wechat", text: "1")
    XCTAssertEqual(second, .answered("已回答。"))
    XCTAssertEqual(stream.recordedAnswers.map(\.eventID), ["evt-a", "evt-q"])
    let remaining = await relay.pendingCount
    XCTAssertEqual(remaining, 0)
  }

  /// An answer carrier failure must say so instead of looking like success.
  func testAnswerTransportFailureIsReported() async throws {
    let prompts = Box()
    let (relay, stream) = makeRelay(frames: [questionFrame()], prompts: prompts)
    stream.failsToAnswer = true
    Task { await relay.run() }
    try await waitUntil { prompts.all.count == 1 }

    guard case .problem(let message) = await relay.answer(sender: "owner@im.wechat", text: "1") else {
      return XCTFail("a refused delivery must be reported")
    }
    XCTAssertTrue(message.contains("没能送到"), message)
    let stillPending = await relay.pendingQuestion(for: "owner@im.wechat")
    XCTAssertNotNil(stillPending, "a failed send keeps the question answerable")
  }
}
