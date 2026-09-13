import Foundation
import HarnessIM
import HarnessKit
import XCTest

@testable import HarnessUI

/// A scripted `$events` subscriber: it yields the frames a test hands it and records the
/// outcomes that come back out.
private final class StubRemoteEventStream: RemoteEventStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [RemoteEventFrame]
  private var answers: [(eventID: String, outcome: String)] = []
  private var continuation: AsyncThrowingStream<RemoteEventFrame, Error>.Continuation?
  private(set) var closed = false
  /// When true, answering fails — what "the browser already answered" looks like.
  var failsToAnswer = false

  init(frames: [RemoteEventFrame] = []) {
    self.pending = frames
  }

  /// True once the centre has actually opened the stream. Tests wait for this instead of
  /// assuming the consumer's task has been scheduled.
  var isOpen: Bool {
    lock.lock(); defer { lock.unlock() }
    return continuation != nil
  }

  /// Yield a frame, or hold it until the stream is opened. The real socket would drop a
  /// pre-open frame; here that would only turn every test into a race with the consumer's
  /// task, which is not the behaviour under test.
  func emit(_ frame: RemoteEventFrame) {
    lock.lock()
    let sink = continuation
    if sink == nil { pending.append(frame) }
    lock.unlock()
    sink?.yield(frame)
  }

  var recordedAnswers: [(eventID: String, outcome: String)] {
    lock.lock(); defer { lock.unlock() }
    return answers
  }

  var isClosed: Bool {
    lock.lock(); defer { lock.unlock() }
    return closed
  }

  func open() async throws -> AsyncThrowingStream<RemoteEventFrame, Error> {
    lock.lock()
    let scripted = pending
    pending = []
    lock.unlock()
    return AsyncThrowingStream { continuation in
      self.lock.lock(); self.continuation = continuation; self.lock.unlock()
      for frame in scripted { continuation.yield(frame) }
      // Stay open after the script: the centre is a long-lived consumer.
    }
  }

  func answer(eventID: String, value: JSONValue) async throws {
    if failsToAnswer {
      throw HarnessAPIError(code: .rejected, message: "该审批已被处理")
    }
    let rendered = value.stringValue ?? (try? value.serialized()) ?? ""
    lock.lock(); answers.append((eventID, rendered)); lock.unlock()
  }

  func close() async {
    lock.lock(); closed = true; lock.unlock()
  }
}

/// Answers the token handshake without a server, so the model's whole connection path is
/// exercised instead of stubbed away.
private struct StubTransport: HarnessAPITransport {
  func send(_ request: HarnessAPIRequest) async throws -> HarnessAPIResponse {
    HarnessAPIResponse(
      status: 303,
      headers: ["set-cookie": "dsh_session=test"],
      body: Data()
    )
  }
}

private func waterfallFrame(
  eventID: String = "evt-1",
  agentID: String = "session-1",
  event: String = "approval/request",
  tool: String = "bash",
  reason: String? = "命令会写入工作区"
) -> RemoteEventFrame {
  var request: [String: JSONValue] = ["toolName": .string(tool)]
  if let reason { request["reason"] = .string(reason) }
  return .waterfall(eventID: eventID, agentID: agentID, event: event, request: .object(request))
}

private func harnessURL() -> URL? {
  URL(string: "http://127.0.0.1:9/?token=TESTTOKEN")
}

/// Poll until `condition` holds. The centre consumes on its own task, so every assertion
/// about "the model saw this frame" has to wait rather than assume.
private func waitUntil(
  timeout: TimeInterval = 3,
  _ condition: @MainActor () -> Bool
) async {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if await condition() { return }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
final class ApprovalAlertCenterTests: XCTestCase {
  private func makeModel(
    stream: StubRemoteEventStream,
    presenter: RecordingApprovalPresenter,
    appActive: Bool = false,
    url: URL? = harnessURL()
  ) -> ApprovalAlertModel {
    let defaults = UserDefaults(suiteName: "ApprovalAlertCenterTests-\(UUID().uuidString)")!
    return ApprovalAlertModel(
      urlProvider: { url },
      defaults: defaults,
      transport: StubTransport(),
      presenter: presenter,
      streamFactory: { _ in stream },
      isAppActive: { appActive }
    )
  }

  /// Connect and wait until the centre has really opened the stream, so a frame emitted
  /// right after is delivered rather than raced.
  private func connect(_ model: ApprovalAlertModel, _ stream: StubRemoteEventStream) async {
    await model.refreshConnection()
    await waitUntil { stream.isOpen }
  }

  // MARK: Frames

  func testAnApprovalRequestBecomesAnAlertAndANotification() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)

    await connect(model, stream)
    XCTAssertEqual(model.connection, .live)

    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }

    let alert = try XCTUnwrap(model.alerts.first)
    XCTAssertEqual(alert.id, "evt-1")
    XCTAssertEqual(alert.sessionID, "session-1")
    XCTAssertEqual(alert.toolName, "bash")
    XCTAssertEqual(alert.detail, "命令会写入工作区")
    XCTAssertEqual(presenter.posted.map(\.id), ["evt-1"])
    XCTAssertEqual(model.pending.count, 1)
  }

  func testUnknownWaterfallsAreIgnored() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)
    await model.refreshConnection()

    // The question waterfall is a different payload with a different answer shape; a
    // channel that guessed at it would answer with the wrong vocabulary.
    stream.emit(waterfallFrame(event: "user-questions/request"))
    stream.emit(.emit(event: "notice", args: []))
    try? await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertTrue(model.alerts.isEmpty)
    XCTAssertTrue(presenter.posted.isEmpty)
  }

  func testRepeatedEventIDDoesNotStack() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)
    await connect(model, stream)

    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }
    stream.emit(waterfallFrame())
    try? await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertEqual(model.alerts.count, 1)
  }

  func testCancelWithdrawsTheAlertAndTheBanner() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)
    await connect(model, stream)

    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }
    stream.emit(.cancel(eventID: "evt-1"))
    await waitUntil { model.alerts.isEmpty }

    XCTAssertTrue(presenter.withdrawn.contains("evt-1"))
  }

  // MARK: Answering

  func testDecideSendsTheHarnessOutcomeVocabulary() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)
    await connect(model, stream)
    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }

    let alert = try XCTUnwrap(model.alerts.first)
    await model.decide(alert, decision: .allowedOnce)

    // Exactly the two literals the harness's ApprovalOutcome accepts.
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["allowed-once"])
    XCTAssertTrue(presenter.withdrawn.contains("evt-1"))
  }

  func testRejectSendsRejected() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)
    await connect(model, stream)
    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }

    await model.decide(try XCTUnwrap(model.alerts.first), decision: .rejected)
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["rejected"])
  }

  func testANotificationActionRoutesThroughTheSamePath() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)
    await connect(model, stream)
    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }

    // What `UNNotificationResponse` handling and the floating panel both end up calling.
    presenter.onDecision?("evt-1", .allowedOnce)
    await waitUntil { !stream.recordedAnswers.isEmpty }
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["allowed-once"])
  }

  func testAnAnswerThatFailsIsReportedAsAlreadyHandled() async throws {
    let stream = StubRemoteEventStream()
    stream.failsToAnswer = true
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)
    await connect(model, stream)
    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }

    await model.decide(try XCTUnwrap(model.alerts.first), decision: .allowedOnce)

    // The request is gone either way, so the alert must not stay as a button that can
    // only fail again.
    XCTAssertTrue(model.alerts.isEmpty)
    XCTAssertEqual(model.notice, "这条审批已经无法答复（可能已在浏览器或微信里处理）。")
    XCTAssertEqual(model.lastError, "该审批已被处理")
  }

  func testDecisionForAnUnknownEventJustClearsTheBanner() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)
    await connect(model, stream)

    presenter.onDecision?("evt-gone", .allowedOnce)
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertTrue(stream.recordedAnswers.isEmpty)
    XCTAssertTrue(presenter.withdrawn.contains("evt-gone"))
  }

  // MARK: Background presentation rules

  func testBackgroundApprovalUsesSoundAndPanel() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter, appActive: false)
    await connect(model, stream)

    stream.emit(waterfallFrame())
    await waitUntil { !presenter.posts.isEmpty }

    let post = try XCTUnwrap(presenter.posts.first)
    XCTAssertTrue(post.sound)
    XCTAssertEqual(presenter.panelVisibility.last, true)
  }

  func testForegroundApprovalIsPosterOnly() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter, appActive: true)
    await connect(model, stream)

    stream.emit(waterfallFrame())
    await waitUntil { !presenter.posts.isEmpty }

    // The user is already looking at the Web UI's own approval sheet; a floating
    // duplicate would cover it.
    let post = try XCTUnwrap(presenter.posts.first)
    XCTAssertFalse(post.sound)
    XCTAssertEqual(presenter.panelVisibility.last, false)
  }

  func testNotificationsOffStillUsesThePanelWhenTheAppIsInTheBackground() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter, appActive: false)
    model.notificationsEnabled = false
    await connect(model, stream)

    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }

    // With no notification and the app hidden, the panel is the only surface left.
    XCTAssertTrue(presenter.posted.isEmpty)
    XCTAssertFalse(presenter.panels.isEmpty)
    XCTAssertEqual(presenter.panelVisibility.last, true)
  }

  // MARK: Connection lifecycle

  func testNoHarnessMeansIdleAndNoAlerts() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter, url: nil)

    await model.refreshConnection()

    XCTAssertEqual(model.connection, .idle)
    XCTAssertTrue(model.alerts.isEmpty)
  }

  func testLosingTheHarnessWithdrawsEverything() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    // The URL is read through the closure, so the harness can "go away" mid-test.
    let box = URLBox(harnessURL())
    let defaults = UserDefaults(suiteName: "ApprovalAlertCenterTests-\(UUID().uuidString)")!
    let model = ApprovalAlertModel(
      urlProvider: { box.value },
      defaults: defaults,
      transport: StubTransport(),
      presenter: presenter,
      streamFactory: { _ in stream },
      isAppActive: { false }
    )

    await connect(model, stream)
    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }

    box.value = nil
    await model.refreshConnection()

    XCTAssertEqual(model.connection, .idle)
    XCTAssertTrue(model.alerts.isEmpty)
    XCTAssertTrue(stream.isClosed)
    XCTAssertTrue(presenter.withdrawn.contains("evt-1"))
  }

  func testDisconnectAndReconnectIsNotARestartLoop() async throws {
    let stream = StubRemoteEventStream()
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = makeModel(stream: stream, presenter: presenter)

    await connect(model, stream)
    // A second call while the stream is live must not open a second subscriber: the
    // harness would then deliver every request twice.
    await connect(model, stream)

    stream.emit(waterfallFrame())
    await waitUntil { model.alerts.count == 1 }
    stream.emit(waterfallFrame())
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(model.alerts.count, 1)
  }
}

/// A mutable URL holder for the "harness went away" test.
private final class URLBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: URL?
  init(_ value: URL?) { self.stored = value }
  var value: URL? {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); stored = newValue; lock.unlock() }
  }
}

/// The real presenter cannot be exercised in a test process (no user to grant
/// notification permission, no app to attach a panel to), but its non-bundle path is
/// still worth pinning: it is what keeps a CLI-like process from trapping.
@MainActor
final class SystemApprovalPresenterTests: XCTestCase {
  func testNonBundleProcessReportsNotificationsUnavailable() async throws {
    guard Bundle.main.bundleIdentifier == nil else {
      throw XCTSkip("this test runner runs inside a bundle; the non-bundle branch cannot be reached here")
    }
    let presenter = SystemApprovalPresenter(usesPanel: false)
    XCTAssertEqual(presenter.authorization, .unavailable)
    let status = await presenter.ensureAuthorization()
    XCTAssertEqual(status, .unavailable)

    // Neither call may trap or throw when there is no notification centre.
    presenter.post(
      ApprovalAlert(id: "evt-1", sessionID: "s", toolName: "bash", reason: "why"),
      sound: false
    )
    presenter.withdrawAll()
  }
}
