import Foundation
import HarnessKit
import XCTest

@testable import HarnessIM

/// A reply source that answers immediately with a canned reply.
struct StubReplySource: SessionReplyProducing {
  var replies: [HarnessReply]
  var onCall: (@Sendable (String) -> Void)?

  func waitForReply(requestId: String, timeout: Duration?) async -> HarnessReply? {
    onCall?(requestId)
    return replies.first
  }
}

/// An iLink transport that serves a script: one batch of inbound messages, then silence.
final class ScriptedILinkTransport: ILinkHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [[String]]
  private var sentTexts: [String] = []
  private var started = false
  private var stopped = false

  /// - Parameter batches: successive `getupdates` payloads; afterwards the poll is empty.
  init(batches: [[String]]) {
    self.queue = batches
  }

  var sentMessages: [String] {
    lock.lock(); defer { lock.unlock() }
    return sentTexts
  }

  var didStart: Bool {
    lock.lock(); defer { lock.unlock() }
    return started
  }

  var didStop: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopped
  }

  /// Queue one more inbound message, delivered on the next poll. Lets a test answer a question
  /// that only existed after the first batch ran.
  func enqueueInbound(_ id: String, _ text: String) {
    let json = #"{"message_id":"\#(id)","from_user_id":"owner@im.wechat","message_type":1,"item_list":[{"type":1,"text_item":{"text":"\#(text)"}}]}"#
    lock.lock(); queue.append([json]); lock.unlock()
  }

  func send(_ request: ILinkHTTPRequest) async throws -> ILinkHTTPResponse {
    let url = request.url.absoluteString
    if url.contains("notifystart") {
      lock.lock(); started = true; lock.unlock()
      return ILinkHTTPResponse(status: 200, body: Data(#"{"ret":0}"#.utf8))
    }
    if url.contains("notifystop") {
      lock.lock(); stopped = true; lock.unlock()
      return ILinkHTTPResponse(status: 200, body: Data(#"{"ret":0}"#.utf8))
    }
    if url.contains("sendmessage") {
      let body = request.body.flatMap { try? JSONValue.parse($0) }
      let text = body?.path("msg.item_list.0.text_item.text")?.stringValue ?? ""
      lock.lock(); sentTexts.append(text); lock.unlock()
      return ILinkHTTPResponse(status: 200, body: Data(#"{"ret":0}"#.utf8))
    }
    if url.contains("getupdates") {
      lock.lock()
      let next = queue.isEmpty ? nil : queue.removeFirst()
      lock.unlock()
      let messages = next ?? []
      let payload = #"{"ret":0,"msgs":[\#(messages.joined(separator: ","))],"get_updates_buf":"buf"}"#
      return ILinkHTTPResponse(status: 200, body: Data(payload.utf8))
    }
    return ILinkHTTPResponse(status: 200, body: Data(#"{"ret":0}"#.utf8))
  }
}

/// Drives the whole feature with no network and no harness process: inbound messages in,
/// one prompt out, one answer back — which is exactly what the user asked for.
final class WeChatChannelServiceTests: XCTestCase {
  private var root: URL!
  private var workspace: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-im-svc-\(UUID().uuidString)")
    workspace = FileManager.default.temporaryDirectory.appendingPathComponent("harness-im-ws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: workspace)
  }

  private func inboundText(_ id: String, _ text: String) -> String {
    #"{"message_id":"\#(id)","from_user_id":"owner@im.wechat","message_type":1,"item_list":[{"type":1,"text_item":{"text":"\#(text)"}}]}"#
  }

  /// Build a service wired to scripted provider and harness transports.
  private func makeService(
    batches: [[String]],
    harnessURL: URL? = URL(string: "http://127.0.0.1:59995/?token=test-token"),
    harnessResponders: ((StubHarnessTransport.Call) -> HarnessAPIResponse)? = nil,
    reply: HarnessReply? = HarnessReply(text: "结果是 42", turn: 1, reason: "completed", isComplete: true),
    config: ChannelConfig? = nil,
    approvalStream: StubRemoteEventStream? = nil,
    sessionList: String? = nil
  ) async throws -> (WeChatChannelService, ScriptedILinkTransport, StubHarnessTransport, Box) {
    let providerTransport = ScriptedILinkTransport(batches: batches)
    let recorder = Box()
    let harnessTransport = StubHarnessTransport { call in
      recorder.record(call)
      if let harnessResponders { return harnessResponders(call) }
      if call.method == "GET" {
        return HarnessAPIResponse(status: 303, headers: ["set-cookie": "dsh-auth-k=v; Path=/"], body: Data())
      }
      if let sessionList, call.path.hasSuffix("session/list") {
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":\#(sessionList)}}"#.utf8
        ))
      }
      if call.path.hasSuffix("workspace/create") {
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"workspace":{"workspaceId":"ws-test","path":"/ws","title":"ws","sessionIds":[],"createdAt":"","updatedAt":""},"created":true}}}"#.utf8
        ))
      }
      if call.path.hasSuffix("session/create") {
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"sessionId":"session-test"}}}"#.utf8
        ))
      }
      if call.path.hasSuffix("session/rename") {
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{}}}"#.utf8
        ))
      }
      if call.path.hasSuffix("session/prompt") {
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"accepted":true}}}"#.utf8
        ))
      }
      // Anything else (the capability probe) exists but rejects empty args.
      return HarnessAPIResponse(status: 200, body: Data(
        #"{"type":"server-response","rpcId":"x","result":{"ok":false,"error":{"code":"gateway/arguments-invalid","message":"args","details":{}}}}"#.utf8
      ))
    }

    var effectiveConfig = config ?? ChannelConfig()
    effectiveConfig.workspacePath = effectiveConfig.workspacePath ?? workspace.path

    // Writing the credential through the channel's own store keeps the test on the
    // production path: `start()` refuses to sync without a bound bot.
    let store = ChannelStateStore.standard(appRoot: root)
    try store.save(credential: ChannelCredential(
      botID: "wx_test", accountID: "wx_test", ownerUserID: "owner@im.wechat",
      token: "provider-token", baseURL: ILinkProtocol.qrBaseURL
    ))
    try store.save(config: effectiveConfig)

    let service = WeChatChannelService(
      appRoot: root,
      harnessURL: { harnessURL },
      dshHome: { self.root.appendingPathComponent("home") },
      client: ILinkClient(transport: providerTransport),
      replyConfiguration: .init(pollInterval: .milliseconds(20), timeout: .seconds(5)),
      harnessTransport: { harnessTransport },
      replySourceFactory: { _, _, _ in StubReplySource(replies: reply.map { [$0] } ?? []) },
      approvalStreamFactory: { _ in approvalStream ?? StubRemoteEventStream(frames: []) }
    )
    await service.update(config: effectiveConfig)
    return (service, providerTransport, harnessTransport, recorder)
  }

  /// Collect harness calls from the test's own thread.
  final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [StubHarnessTransport.Call] = []
    func record(_ call: StubHarnessTransport.Call) {
      lock.lock(); calls.append(call); lock.unlock()
    }
    var all: [StubHarnessTransport.Call] {
      lock.lock(); defer { lock.unlock() }
      return calls
    }
    var workspaceCreates: [JSONValue] {
      all.filter { $0.path.hasSuffix("workspace/create") }.compactMap { call in
        call.body.flatMap { try? JSONValue.parse($0) }
      }
    }
    /// Registrations only: the capability probe also calls `workspace/create`, with no arguments.
    var workspaceRegistrations: [JSONValue] {
      workspaceCreates.filter { $0.path("payload.args.request.path")?.stringValue != nil }
    }
    var sessionCreates: [JSONValue] {
      all.filter { $0.path.hasSuffix("session/create") }.compactMap { call in
        call.body.flatMap { try? JSONValue.parse($0) }
      }
    }
    var prompts: [JSONValue] {
      all.filter { $0.path.hasSuffix("session/prompt") }.compactMap { call in
        call.body.flatMap { try? JSONValue.parse($0) }
      }
    }
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("condition not met within \(timeout)s")
  }

  func testTriggerSubmitsOneBatchAndReplies() async throws {
    let (service, provider, _, harness) = try await makeService(batches: [[
      inboundText("1", "看看这个报告"),
      inboundText("2", "开始"),
    ]])
    await service.start()

    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    await service.stop()

    let sent = provider.sentMessages
    XCTAssertTrue(sent.contains { $0.contains("已收纳 1 条消息") }, "first item is acknowledged once: \(sent)")
    XCTAssertTrue(sent.contains { $0.contains("已提交") && $0.contains("正在处理") }, "submission is acknowledged: \(sent)")
    XCTAssertEqual(sent.last, "结果是 42")

    // Exactly one turn reached the harness, carrying the user's text.
    let prompts = harness.prompts
    XCTAssertEqual(prompts.count, 1)
    let text = prompts[0].path("payload.args.request.content.0.text")?.stringValue ?? ""
    XCTAssertTrue(text.contains("[消息 1]\n看看这个报告"), text)
    XCTAssertEqual(prompts[0].path("payload.args.request.sessionId")?.stringValue, "session-test")
  }

  /// Without the trigger phrase the harness must not hear anything at all.
  func testBufferedContentIsNotSubmittedWithoutTheTrigger() async throws {
    let (service, provider, _, harness) = try await makeService(batches: [[
      inboundText("1", "先发一段"),
      inboundText("2", "再发一段"),
    ]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("已收纳 1 条消息") } }
    try await Task.sleep(for: .milliseconds(200))
    await service.stop()

    XCTAssertTrue(harness.prompts.isEmpty, "no prompt may be sent before the trigger")
    XCTAssertEqual(provider.sentMessages.count, 1, "only the first-item acknowledgement is expected")
  }

  /// The batch is handed over exactly once; a second delivery of the same message must not
  /// resubmit it (the provider replays from its cursor).
  func testDuplicateMessagesAreIgnored() async throws {
    let (service, provider, _, harness) = try await makeService(batches: [
      [inboundText("1", "内容"), inboundText("2", "开始")],
      [inboundText("1", "内容"), inboundText("2", "开始")],
    ])
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await Task.sleep(for: .milliseconds(200))
    await service.stop()

    XCTAssertEqual(harness.prompts.count, 1)
  }

  func testCancelPhraseClearsTheBatch() async throws {
    let (service, provider, _, harness) = try await makeService(batches: [[
      inboundText("1", "一段话"),
      inboundText("2", "取消"),
    ]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("已清空本批") } }
    await service.stop()
    XCTAssertTrue(harness.prompts.isEmpty)
  }

  /// A trigger with nothing buffered must explain itself rather than submit an empty turn.
  func testTriggerWithEmptyBufferIsExplained() async throws {
    let (service, provider, _, harness) = try await makeService(batches: [[inboundText("1", "开始")]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("当前没有待提交的内容") } }
    await service.stop()
    XCTAssertTrue(harness.prompts.isEmpty)
  }

  /// Messages from anyone but the bound owner are ignored when no allowlist is configured.
  func testIgnoresOtherSenders() async throws {
    let stranger = #"{"message_id":"9","from_user_id":"someone-else","message_type":1,"item_list":[{"type":1,"text_item":{"text":"你好"}}]}"#
    let (service, provider, _, harness) = try await makeService(batches: [[stranger]])
    await service.start()
    try await Task.sleep(for: .milliseconds(200))
    await service.stop()
    XCTAssertTrue(provider.sentMessages.isEmpty)
    XCTAssertTrue(harness.prompts.isEmpty)
  }

  /// A harness that cannot create sessions must say so and keep the user's content.
  func testSubmissionFailureKeepsTheBatch() async throws {
    let (service, provider, _, _) = try await makeService(
      batches: [[inboundText("1", "重要内容"), inboundText("2", "开始")]],
      harnessURL: nil
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("提交失败") } }
    let status = await service.currentStatus()
    await service.stop()

    XCTAssertTrue(provider.sentMessages.contains { $0.contains("内容已保留") })
    XCTAssertEqual(status.batches.values.first?.items.first?.text, "重要内容",
                   "the batch must survive a failed hand-off")
  }

  func testStopNotifiesTheProvider() async throws {
    let (service, provider, _, _) = try await makeService(batches: [[]])
    await service.start()
    try await waitUntil { provider.didStart }
    await service.stop()
    try await waitUntil { provider.didStop }
  }

  // MARK: - Workspace registration (the fix for "session is invisible in the GUI")

  /// A config written before the channel knew about workspaces must still work: the folder is
  /// registered on first use, and the session is addressed by workspace so the GUI lists it.
  func testRegistersWorkspaceAndCreatesSessionInIt() async throws {
    let (service, provider, _, harness) = try await makeService(batches: [[
      inboundText("1", "看看这个"),
      inboundText("2", "开始"),
    ]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    await service.stop()

    let registrations = harness.workspaceRegistrations
    XCTAssertEqual(registrations.count, 1, "the folder is registered exactly once")
    XCTAssertEqual(registrations[0].path("payload.args.request.path")?.stringValue, workspace.path)

    let creates = harness.sessionCreates
    XCTAssertFalse(creates.isEmpty)
    let request = try XCTUnwrap(creates.last?.path("payload.args.request"))
    XCTAssertEqual(request["workspaceId"]?.stringValue, "ws-test")
    XCTAssertNil(request["cwd"], "cwd and workspaceId are mutually exclusive on the wire")

    // The registration is remembered, so later batches do not repeat it.
    let stored = await service.currentConfig()
    XCTAssertEqual(stored.workspaceID, "ws-test")
  }

  func testSkipsRegistrationWhenTheWorkspaceIsAlreadyKnown() async throws {
    var config = ChannelConfig()
    config.workspaceID = "ws-cached"
    let (service, provider, _, harness) = try await makeService(
      batches: [[inboundText("1", "内容"), inboundText("2", "开始")]],
      config: config
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    await service.stop()

    XCTAssertTrue(harness.workspaceRegistrations.isEmpty, "a cached workspace id needs no re-registration")
    XCTAssertEqual(harness.sessionCreates.last?.path("payload.args.request.workspaceId")?.stringValue, "ws-cached")
  }

  /// The repair path: a session recorded before the channel registered a workspace is adopted
  /// into it, which is what makes it appear in the sidebar without resending anything.
  func testStartAdoptsRecordedSessions() async throws {
    let store = ChannelStateStore.standard(appRoot: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var state = ChannelPersistedState()
    state.sessions["owner@im.wechat"] = "session-old"
    try store.save(state: state)

    let (service, _, _, harness) = try await makeService(batches: [[]])
    await service.start()
    try await waitUntil { harness.sessionCreates.contains { $0.path("payload.args.request.sessionId")?.stringValue == "session-old" } }
    await service.stop()

    let adoption = try XCTUnwrap(harness.sessionCreates.first { $0.path("payload.args.request.sessionId")?.stringValue == "session-old" })
    XCTAssertEqual(adoption.path("payload.args.request.workspaceId")?.stringValue, "ws-test")
    XCTAssertNil(adoption.path("payload.args.request.cwd"))
  }

  /// Hosts without `workspace/create` must still submit, and say why nothing appears in the
  /// sidebar rather than failing the batch.
  func testDegradesWhenWorkspaceRegistrationIsUnavailable() async throws {
    var config = ChannelConfig()
    config.workspacePath = workspace.path
    let (service, provider, _, harness) = try await makeService(
      batches: [[inboundText("1", "内容"), inboundText("2", "开始")]],
      harnessResponders: { call in
        if call.path.hasSuffix("workspace/create") {
          return HarnessAPIResponse(status: 404, body: Data("not found".utf8))
        }
        if call.method == "GET" {
          return HarnessAPIResponse(status: 303, headers: ["set-cookie": "dsh-auth-k=v; Path=/"], body: Data())
        }
        if call.path.hasSuffix("session/create") {
          return HarnessAPIResponse(status: 200, body: Data(
            #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"sessionId":"session-cwd"}}}"#.utf8
          ))
        }
        if call.path.hasSuffix("session/prompt") {
          return HarnessAPIResponse(status: 200, body: Data(
            #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"accepted":true}}}"#.utf8
          ))
        }
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":false,"error":{"code":"gateway/arguments-invalid","message":"args","details":{}}}}"#.utf8
        ))
      },
      config: config
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    await service.stop()

    // Fell back to a cwd session so the user still gets an answer …
    let request = try XCTUnwrap(harness.sessionCreates.last?.path("payload.args.request"))
    XCTAssertEqual(request["cwd"]?.stringValue, workspace.path)
    XCTAssertNotNil(harness.sessionCreates.last)
    // … and the window can explain the sidebar gap.
    let status = await service.currentStatus()
    XCTAssertEqual(status.capabilities?.canCreateWorkspace, false)
    XCTAssertTrue(status.capabilities?.notes.contains { $0.contains("workspace/create") } == true)
  }

  /// A recorded session whose stored cwd is spelled differently from the registered workspace
  /// cannot be adopted (the host answers `session/conflict`); the batch must still submit on a
  /// fresh session instead of failing.
  func testFallsBackToAFreshSessionWhenAdoptionConflicts() async throws {
    let store = ChannelStateStore.standard(appRoot: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var state = ChannelPersistedState()
    state.sessions["owner@im.wechat"] = "session-mismatched"
    try store.save(state: state)

    let (service, provider, _, harness) = try await makeService(
      batches: [[inboundText("1", "内容"), inboundText("2", "开始")]],
      harnessResponders: { call in
        if call.method == "GET" {
          return HarnessAPIResponse(status: 303, headers: ["set-cookie": "dsh-auth-k=v; Path=/"], body: Data())
        }
        if call.path.hasSuffix("workspace/create") {
          return HarnessAPIResponse(status: 200, body: Data(
            #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"workspace":{"workspaceId":"ws-test","path":"/ws","title":"ws","sessionIds":[]},"created":true}}}"#.utf8
          ))
        }
        if call.path.hasSuffix("session/create") {
          let body = call.body.flatMap { try? JSONValue.parse($0) }
          if body?.path("payload.args.request.sessionId")?.stringValue == "session-mismatched" {
            return HarnessAPIResponse(status: 200, body: Data(
              #"{"type":"server-response","rpcId":"x","result":{"ok":false,"error":{"code":"session/conflict","message":"session session-mismatched belongs to /tmp/a, not /private/tmp/a","details":{}}}}"#.utf8
            ))
          }
          return HarnessAPIResponse(status: 200, body: Data(
            #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"sessionId":"session-fresh"}}}"#.utf8
          ))
        }
        if call.path.hasSuffix("session/prompt") {
          return HarnessAPIResponse(status: 200, body: Data(
            #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"accepted":true}}}"#.utf8
          ))
        }
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":false,"error":{"code":"gateway/arguments-invalid","message":"args","details":{}}}}"#.utf8
        ))
      }
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    await service.stop()

    // The recorded session was attempted first …
    let attempted = harness.sessionCreates.compactMap { $0.path("payload.args.request.sessionId")?.stringValue }
    XCTAssertTrue(attempted.contains("session-mismatched"))
    // … and a brand-new session was created (no `sessionId` in the request means "create").
    XCTAssertTrue(harness.sessionCreates.contains { $0.path("payload.args.request.sessionId") == nil })
    let promptSessions = harness.prompts.compactMap { $0.path("payload.args.request.sessionId")?.stringValue }
    XCTAssertTrue(promptSessions.contains("session-fresh"), "prompt sessions were: \(promptSessions)")
    // … and the mapping moved forward.
    let stored = ChannelStateStore.standard(appRoot: root).loadState().sessions
    XCTAssertEqual(stored["owner@im.wechat"], "session-fresh")
  }

  // MARK: - Approvals (forwarded to the chat and answered from it)

  /// The whole approval loop: a question for a session this channel owns reaches the chat, and
  /// a 「批准」 reply answers it — without being collected into the next batch.
  func testApprovalQuestionReachesChatAndReplyAnswersIt() async throws {
    let stream = StubRemoteEventStream(frames: [])
    let (service, provider, _, harness) = try await makeService(
      batches: [[inboundText("1", "跑个命令"), inboundText("2", "开始")]],
      approvalStream: stream
    )
    await service.start()
    // First a real submission, so the chat owns the session the approval will name.
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    await service.startPromptRelay()
    try await waitUntil { stream.isOpen }

    stream.emit(.ready(clientID: "client-1"))
    stream.emit(.waterfall(
      eventID: "evt-9", agentID: "session-test", event: "approval/request",
      request: .object(["toolName": .string("bash"), "reason": .string("会写入文件")])
    ))

    try await waitUntil { provider.sentMessages.contains { $0.contains("需要你的允许") } }
    let question = try XCTUnwrap(provider.sentMessages.first { $0.contains("需要你的允许") })
    XCTAssertTrue(question.contains("bash"))
    XCTAssertTrue(question.contains("会写入文件"))

    // The reply is a decision, not content: it must answer the harness and stop there.
    let promptsBefore = harness.prompts.count
    stream.emit(.emit(event: "session/created", args: [.null]))
    provider.enqueueInbound("3", "批准")
    try await waitUntil { stream.recordedAnswers.contains { $0.eventID == "evt-9" } }
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["allowed-once"])
    try await waitUntil { provider.sentMessages.contains { $0.contains("已批准") } }
    await service.stop()

    XCTAssertEqual(harness.prompts.count, promptsBefore, "a decision must not start a new turn")
  }

  /// A question for a session the channel does not own is left for the browser.
  func testForeignApprovalIsNotForwarded() async throws {
    let stream = StubRemoteEventStream(frames: [])
    let (service, provider, _, _) = try await makeService(
      batches: [[inboundText("1", "内容"), inboundText("2", "开始")]],
      approvalStream: stream
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    await service.startPromptRelay()
    try await waitUntil { stream.isOpen }

    stream.emit(.waterfall(
      eventID: "evt-foreign", agentID: "session-not-ours", event: "approval/request",
      request: .object(["toolName": .string("bash")])
    ))
    try await Task.sleep(for: .milliseconds(200))
    await service.stop()

    XCTAssertFalse(provider.sentMessages.contains { $0.contains("需要你的允许") })
    XCTAssertTrue(stream.recordedAnswers.isEmpty)
  }

  // MARK: - Phone approvals (the toolbar switch)

  /// The switch is what makes a *desktop* session's approval reachable from the phone; the
  /// test above pins the other end (the same frame is left alone while it is off).
  func testPhoneApprovalsSendADesktopSessionsRequestAndAcceptTheReply() async throws {
    let stream = StubRemoteEventStream(frames: [])
    let (service, provider, _, harness) = try await makeService(batches: [], approvalStream: stream)
    await service.start()
    // Deliberately no chat submission first: the switch itself has to open the stream, or a
    // user who only ever works in the desktop app would never be reachable from the phone.
    await service.setForwardsAllPrompts(true)
    try await waitUntil { stream.isOpen }

    stream.emit(.waterfall(
      eventID: "evt-desktop", agentID: "session-desktop", event: "approval/request",
      request: .object(["toolName": .string("bash"), "reason": .string("会写入文件")])
    ))
    try await waitUntil { provider.sentMessages.contains { $0.contains("需要你的允许") } }

    let question = try XCTUnwrap(provider.sentMessages.last { $0.contains("需要你的允许") })
    XCTAssertTrue(question.contains("来自桌面会话"), question)
    XCTAssertTrue(question.contains("bash"))

    // The count is republished after the message goes out, so wait for it instead of reading
    // once: a single read races the bookkeeping that runs after the prompt is sent.
    try await waitUntil { await service.currentStatus().pendingPrompts == 1 }
    let asked = await service.currentStatus()
    XCTAssertTrue(asked.forwardsAllPrompts)

    let promptsBefore = harness.prompts.count
    provider.enqueueInbound("9", "批准")
    try await waitUntil { stream.recordedAnswers.contains { $0.eventID == "evt-desktop" } }
    XCTAssertEqual(stream.recordedAnswers.map(\.outcome), ["allowed-once"])
    XCTAssertEqual(harness.prompts.count, promptsBefore, "a decision must not start a new turn")

    try await waitUntil { await service.currentStatus().pendingPrompts == 0 }
    await service.stop()
  }

  /// Switching off has to restore the old behaviour exactly: a session that is not the
  /// channel's goes back to being the GUI's business.
  func testSwitchingPhoneApprovalsOffStopsBorrowingForeignSessions() async throws {
    let stream = StubRemoteEventStream(frames: [])
    let (service, provider, _, _) = try await makeService(batches: [], approvalStream: stream)
    await service.start()
    await service.setForwardsAllPrompts(true)
    try await waitUntil { stream.isOpen }
    await service.setForwardsAllPrompts(false)

    stream.emit(.waterfall(
      eventID: "evt-after-off", agentID: "session-desktop", event: "approval/request",
      request: .object(["toolName": .string("bash")])
    ))
    try await Task.sleep(for: .milliseconds(200))
    await service.stop()

    XCTAssertFalse(provider.sentMessages.contains { $0.contains("需要你的允许") })
    XCTAssertTrue(stream.recordedAnswers.isEmpty)
  }

  /// A borrowed question may only be sent to an address the channel accepts a reply from,
  /// or the user would be asked something whose answer is dropped at the door.
  func testBorrowedPromptAddressFollowsTheAllowlist() async throws {
    var allowlisted = ChannelConfig()
    allowlisted.allowedSenders = ["someone@im.wechat"]
    let (service, _, _, _) = try await makeService(batches: [], config: allowlisted)

    let address = await service.phonePromptAddress()
    XCTAssertEqual(address, "someone@im.wechat", "the owner is not allowed, so the allowed sender is used")
  }

  /// The default (empty allowlist) means owner-only, which is also who a borrowed question
  /// is sent to.
  func testBorrowedQuestionDefaultsToTheOwner() async throws {
    let (service, _, _, _) = try await makeService(batches: [])

    let address = await service.phonePromptAddress()
    XCTAssertEqual(address, "owner@im.wechat")
  }

  // MARK: - Remote control over chat commands

  /// A listing whose second session lives in `secondCwd`.
  ///
  /// The directory is passed in rather than hard-coded so a test can point the binding at one
  /// that really exists: taking over a session whose directory is gone is refused on purpose.
  private func listing(secondCwd: String) -> String {
    #"""
    {"items":[
      {"sessionId":"session-1a2b3c4d-0000","updatedAt":1700000000000,"running":true,"blank":false,
       "cwd":"/tmp/one","projections":{"asOfSeq":3,"values":{"title":"修 bug"}}},
      {"sessionId":"session-9f8e7d6c-1111","updatedAt":1700000000000,"running":false,"blank":false,
       "cwd":"\#(secondCwd)","projections":{"asOfSeq":2,"values":{"title":"别的项目"}}}
    ]}
    """#
  }

  /// A temporary directory that lives for the duration of one test.
  private func temporaryProject() throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsh-remote-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url.path
  }

  func testListCommandRepliesWithTheNumberedSessions() async throws {
    let (service, provider, _, _) = try await makeService(
      batches: [[inboundText("1", "/list")]],
      sessionList: listing(secondCwd: "/tmp/other-project")
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("修 bug") } }
    await service.stop()

    let text = try XCTUnwrap(provider.sentMessages.last { $0.contains("修 bug") })
    XCTAssertTrue(text.contains("1. "), text)
    XCTAssertTrue(text.contains("2. "), text)
    XCTAssertTrue(text.contains("1a2b3c4d"), text)
    XCTAssertTrue(text.contains("/use 1"), text)
  }

  func testUnknownCommandIsAnsweredAndNotSubmitted() async throws {
    let (service, provider, _, harness) = try await makeService(batches: [[inboundText("1", "/nope")]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("不认识的命令") } }
    await service.stop()

    XCTAssertTrue(harness.prompts.isEmpty, "a command must never reach the model")
  }

  func testUseCommandAdoptsASessionAndRemembersItsDirectory() async throws {
    let project = try temporaryProject()
    let (service, provider, _, _) = try await makeService(
      batches: [[inboundText("1", "/list"), inboundText("2", "/use 2")]],
      sessionList: listing(secondCwd: project)
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("已接管") } }
    await service.stop()

    let text = try XCTUnwrap(provider.sentMessages.last { $0.contains("已接管") })
    XCTAssertTrue(text.contains("别的项目"), text)

    let state = ChannelStateStore.standard(appRoot: root).loadState()
    XCTAssertEqual(state.sessions["owner@im.wechat"], "session-9f8e7d6c-1111")
    // The working directory travels with the binding: without it the phone could talk to the
    // session but never read its history.
    XCTAssertEqual(state.adoptedSessions["owner@im.wechat"]?.cwd, project)
  }

  /// A session whose directory is gone must be refused at binding time, not on the first
  /// message: both the agent's cwd and the log's address depend on it.
  func testUseRefusesASessionWhoseDirectoryIsGone() async throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsh-gone-\(UUID().uuidString)", isDirectory: true).path
    let (service, provider, _, _) = try await makeService(
      batches: [[inboundText("1", "/list"), inboundText("2", "/use 2")]],
      sessionList: listing(secondCwd: missing)
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("工作目录不存在") } }
    await service.stop()

    let state = ChannelStateStore.standard(appRoot: root).loadState()
    XCTAssertNil(state.sessions["owner@im.wechat"], "a refused binding must not be recorded")
  }

  /// The reason adopted bindings are tracked separately: a session that already belongs to a
  /// workspace must be prompted directly, not re-registered into the channel's own.
  func testSayPromptsTheAdoptedSessionWithoutReattachingIt() async throws {
    let project = try temporaryProject()
    let (service, provider, _, harness) = try await makeService(
      batches: [[
        inboundText("1", "/list"),
        inboundText("2", "/use 2"),
        inboundText("3", "/say 你好"),
      ]],
      sessionList: listing(secondCwd: project)
    )
    await service.start()
    try await waitUntil {
      harness.prompts.contains { $0.path("payload.args.request.sessionId")?.stringValue == "session-9f8e7d6c-1111" }
    }
    await service.stop()

    let prompted = harness.prompts.compactMap { $0.path("payload.args.request.sessionId")?.stringValue }
    XCTAssertEqual(prompted, ["session-9f8e7d6c-1111"])
    // The capability probe also calls `session/create`, with empty arguments; only a call that
    // carries a request would actually create or adopt something.
    let creations = harness.sessionCreates.filter { $0.path("payload.args.request") != nil }
    XCTAssertTrue(creations.isEmpty, "an adopted session must not be created or re-attached")
    let text = try XCTUnwrap(harness.prompts.first)
      .path("payload.args.request.content.0.text")?.stringValue ?? ""
    XCTAssertTrue(text.contains("你好"), text)
  }

  /// `/new` must drop the adopted binding too, or the next message would keep talking to a
  /// session the user just walked away from.
  func testNewCommandClearsTheAdoptedBinding() async throws {
    let project = try temporaryProject()
    let (service, provider, _, _) = try await makeService(
      batches: [[
        inboundText("1", "/list"),
        inboundText("2", "/use 2"),
        inboundText("3", "/new"),
      ]],
      sessionList: listing(secondCwd: project)
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("已解除绑定") } }
    await service.stop()

    let state = ChannelStateStore.standard(appRoot: root).loadState()
    XCTAssertNil(state.sessions["owner@im.wechat"])
    XCTAssertNil(state.adoptedSessions["owner@im.wechat"])
  }

  /// `/history` reads the session's own log, addressed by the directory the binding carries.
  func testHistoryCommandRendersTheSessionLog() async throws {
    let sessionID = "session-9f8e7d6c-1111"
    let project = try temporaryProject()
    let dshHome = root.appendingPathComponent("home")
    let directory = try SessionPaths.sessionDirectory(dshHome: dshHome, cwd: project, sessionID: sessionID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = try XCTUnwrap(Bundle.module.url(
      forResource: "recorded-session.v3", withExtension: "jsonl.zstd", subdirectory: "Fixtures"
    ))
    try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("session.v3.jsonl.zstd"))

    let (service, provider, _, _) = try await makeService(
      batches: [[
        inboundText("1", "/list"),
        inboundText("2", "/use 2"),
        inboundText("3", "/history 3"),
      ]],
      sessionList: listing(secondCwd: project)
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("收到") } }
    await service.stop()

    let text = try XCTUnwrap(provider.sentMessages.last { $0.contains("收到") })
    XCTAssertTrue(text.contains("最近 3 轮"), text)
    XCTAssertTrue(text.contains(sessionID), text)
  }

  /// The repair pass exists for sessions the channel created. A session the phone took over is
  /// already registered in its own workspace, and asking the harness to adopt it into ours
  /// raises `session/conflict` — reported as a directory-spelling problem for a binding that is
  /// working perfectly.
  func testAttachStoredSessionsSkipsAdoptedBindings() async throws {
    let project = try temporaryProject()
    let store = ChannelStateStore.standard(appRoot: root)
    var seeded = store.loadState()
    seeded.sessions["channel@im.wechat"] = "session-mine"
    seeded.sessions["owner@im.wechat"] = "session-foreign"
    seeded.adoptedSessions["owner@im.wechat"] = AdoptedSession(
      sessionID: "session-foreign", cwd: project, title: "别的项目"
    )
    try store.save(state: seeded)

    let (service, _, _, harness) = try await makeService(batches: [])
    await service.attachStoredSessions()
    await service.stop()

    let adopted = harness.sessionCreates.compactMap { $0.path("payload.args.request.sessionId")?.stringValue }
    XCTAssertFalse(adopted.contains("session-foreign"), "an adopted session must not be re-attached")
    XCTAssertTrue(adopted.contains("session-mine"), "a channel-created session still is")
  }

  /// A question is forwarded like an approval, and `/answer` is what distinguishes a real
  /// answer from ordinary chat.
  func testQuestionIsForwardedAndAnsweredWithTheAnswerCommand() async throws {
    let stream = StubRemoteEventStream(frames: [])
    let (service, provider, _, _) = try await makeService(batches: [], approvalStream: stream)
    await service.start()
    await service.setForwardsAllPrompts(true)
    try await waitUntil { stream.isOpen }

    stream.emit(.waterfall(
      eventID: "evt-q", agentID: "session-desktop", event: "user-questions/request",
      request: .object(["questions": .array([
        .object([
          "id": .string("q1"),
          "question": .string("要继续吗"),
          "options": .array([.object(["label": .string("继续")]), .object(["label": .string("停下")])]),
        ])
      ])])
    ))
    try await waitUntil { provider.sentMessages.contains { $0.contains("需要你回答") } }

    // Ordinary chat first: it must not be swallowed as an answer to a multiple-choice question.
    provider.enqueueInbound("9", "我看看")
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(stream.recordedAnswers.isEmpty, "plain chat is not an answer")

    provider.enqueueInbound("10", "/answer 2")
    try await waitUntil { stream.recordedAnswers.contains { $0.eventID == "evt-q" } }
    await service.stop()

    let sent = try XCTUnwrap(stream.recordedAnswers.first?.outcome)
    XCTAssertTrue(sent.contains("停下"), sent)
    XCTAssertTrue(provider.sentMessages.contains { $0.contains("已回答") })
  }

  // MARK: - Switching the workspace from WeChat

  /// Write the harness's own workspace registry where the channel reads it.
  ///
  /// `updatedAt` is explicit because the registry is sorted by activity: without it the row
  /// order — and therefore what `/workspace 2` means — would depend on title collation.
  private func writeRegistry(
    _ entries: [(id: String, path: String, title: String, updatedAt: String)]
  ) throws {
    let directory = root.appendingPathComponent("home/storages", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let rows = entries.map { entry in
      #""\#(entry.id)":{"path":"\#(entry.path)","title":"\#(entry.title)","sessionIds":[],"updatedAt":"\#(entry.updatedAt)"}"#
    }
    let json = #"{"global":{"workspaceIds":[]},"tables":{"workspaces":{\#(rows.joined(separator: ","))}}}"#
    try Data(json.utf8).write(to: directory.appendingPathComponent("workspace.json"))
  }

  private func missingFolder() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("dsh-moved-\(UUID().uuidString)", isDirectory: true).path
  }

  /// `/workspace` reads the same registry the sidebar does — including folders that are gone.
  func testWorkspaceCommandListsTheHarnessRegistry() async throws {
    try writeRegistry([
      (id: "ws-live", path: workspace.path, title: "微信用的",
       updatedAt: "2026-09-13T04:04:49.235Z"),
      (id: "ws-gone", path: missingFolder(), title: "搬走的",
       updatedAt: "2026-09-10T12:45:25.252Z"),
    ])
    let (service, provider, _, _) = try await makeService(batches: [[inboundText("1", "/workspace")]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("工作区（共 2 个") } }
    await service.stop()

    let text = try XCTUnwrap(provider.sentMessages.last { $0.contains("工作区（共 2 个") })
    XCTAssertTrue(text.contains("1. ● 微信用的"), text)
    XCTAssertTrue(text.contains("2.   搬走的"), text)
    XCTAssertTrue(text.contains("（目录不存在）"), text)
    XCTAssertTrue(text.contains("/workspace 1 切换"), text)
  }

  /// The switch is a real change of setting, persisted the same way the app window persists it.
  func testWorkspaceSwitchRepointsTheChannelAndUnbinds() async throws {
    let other = try temporaryProject()
    try writeRegistry([
      (id: "ws-live", path: workspace.path, title: "微信用的",
       updatedAt: "2026-09-13T04:04:49.235Z"),
      (id: "ws-other", path: other, title: "另一个",
       updatedAt: "2026-09-10T12:45:25.252Z"),
    ])
    let (service, provider, _, harness) = try await makeService(batches: [
      [inboundText("1", "旧内容"), inboundText("2", "开始")],
      [inboundText("3", "/workspace 2")],
    ])
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { provider.sentMessages.contains { $0.contains("已切换工作区") } }
    await service.stop()

    let text = try XCTUnwrap(provider.sentMessages.last { $0.contains("已切换工作区") })
    XCTAssertTrue(text.contains("已切换工作区：另一个"), text)
    XCTAssertTrue(text.contains(other), text)
    XCTAssertTrue(text.contains("本对话已解绑旧会话"), text)

    let store = ChannelStateStore.standard(appRoot: root)
    XCTAssertEqual(store.loadConfig().workspacePath, other, "the folder is persisted for the next launch")
    XCTAssertEqual(store.loadConfig().workspaceID, "ws-test", "the new folder is registered right away")
    XCTAssertNil(store.loadState().sessions["owner@im.wechat"], "the old binding belongs to the old folder")
    XCTAssertEqual(harness.workspaceRegistrations.last?.path("payload.args.request.path")?.stringValue, other)
  }

  /// The point of the feature: after a switch, the next batch lands in the new folder.
  func testSubmissionsAfterASwitchUseTheNewWorkspace() async throws {
    let other = try temporaryProject()
    try writeRegistry([
      (id: "ws-live", path: workspace.path, title: "微信用的",
       updatedAt: "2026-09-13T04:04:49.235Z"),
      (id: "ws-other", path: other, title: "另一个",
       updatedAt: "2026-09-10T12:45:25.252Z"),
    ])
    let (service, provider, _, harness) = try await makeService(batches: [
      [inboundText("1", "旧内容"), inboundText("2", "开始")],
      [inboundText("3", "/workspace 2")],
      [inboundText("4", "新内容"), inboundText("5", "开始")],
    ])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("已切换工作区") } }
    try await waitUntil { harness.prompts.count >= 2 }
    await service.stop()

    let creations = harness.sessionCreates.filter { $0.path("payload.args.request") != nil }
    XCTAssertEqual(creations.count, 2, "a new session is opened instead of reusing the old folder's")
    let request = try XCTUnwrap(creations.last?.path("payload.args.request"))
    XCTAssertEqual(request["workspaceId"]?.stringValue, "ws-test")
    XCTAssertNil(request["cwd"], "cwd and workspaceId are mutually exclusive on the wire")

    // The new folder was registered after the switch, and only then.
    XCTAssertEqual(harness.workspaceRegistrations.count, 2)
    XCTAssertEqual(harness.workspaceRegistrations.last?.path("payload.args.request.path")?.stringValue, other)
  }

  /// A folder that is not there is refused, and refusing must not move anything.
  func testWorkspaceSwitchRefusesAMissingFolder() async throws {
    try writeRegistry([
      (id: "ws-live", path: workspace.path, title: "微信用的",
       updatedAt: "2026-09-13T04:04:49.235Z"),
    ])
    let (service, provider, _, harness) = try await makeService(batches: [
      [inboundText("1", "/workspace \(missingFolder())")],
    ])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("不存在或不是文件夹") } }
    await service.stop()

    XCTAssertEqual(
      ChannelStateStore.standard(appRoot: root).loadConfig().workspacePath,
      workspace.path,
      "a refused switch must leave the channel where it was"
    )
    XCTAssertTrue(harness.workspaceRegistrations.isEmpty, "nothing to register for a folder that is not there")
  }

  func testWorkspaceSwitchReportsAnUnknownTarget() async throws {
    try writeRegistry([
      (id: "ws-live", path: workspace.path, title: "微信用的",
       updatedAt: "2026-09-13T04:04:49.235Z"),
    ])
    let (service, provider, _, _) = try await makeService(batches: [[inboundText("1", "/workspace 9")]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("没有找到工作区") } }
    await service.stop()

    XCTAssertEqual(
      ChannelStateStore.standard(appRoot: root).loadConfig().workspacePath,
      workspace.path
    )
  }

  /// Re-pointing at the folder already in use is a no-op: it must not silently drop a binding
  /// the user is in the middle of.
  func testWorkspaceSwitchToTheSameFolderKeepsTheBinding() async throws {
    try writeRegistry([
      (id: "ws-live", path: workspace.path, title: "微信用的",
       updatedAt: "2026-09-13T04:04:49.235Z"),
    ])
    let (service, provider, _, _) = try await makeService(batches: [[
      inboundText("1", "内容"), inboundText("2", "开始"), inboundText("3", "/workspace 1"),
    ]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("已经在这个工作区") } }
    await service.stop()

    XCTAssertEqual(
      ChannelStateStore.standard(appRoot: root).loadState().sessions["owner@im.wechat"],
      "session-test"
    )
  }

  /// Before there is any registry (or any chosen folder) the phone can still pick one: this is
  /// the first-run path that used to dead-end at "请在 app 的微信渠道窗口里设置".
  func testWorkspaceSwitchAcceptsAPathTheRegistryDoesNotKnow() async throws {
    let fresh = try temporaryProject()
    let (service, provider, _, harness) = try await makeService(batches: [
      [inboundText("1", "/workspace \(fresh)")],
    ])
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("已切换工作区") } }
    await service.stop()

    XCTAssertEqual(ChannelStateStore.standard(appRoot: root).loadConfig().workspacePath, fresh)
    XCTAssertEqual(
      harness.workspaceRegistrations.last?.path("payload.args.request.path")?.stringValue,
      fresh
    )
  }

  /// The harness being down must not block the switch: the folder is saved, and the reply says
  /// what will happen on the next submission instead of pretending it was registered.
  func testWorkspaceSwitchWorksWhileTheHarnessIsDown() async throws {
    let fresh = try temporaryProject()
    let (service, provider, _, _) = try await makeService(
      batches: [[inboundText("1", "/workspace \(fresh)")]],
      harnessURL: nil
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("harness 暂时不可用") } }
    await service.stop()

    XCTAssertEqual(
      ChannelStateStore.standard(appRoot: root).loadConfig().workspacePath,
      fresh
    )
  }

  /// A session the phone took over belongs to another folder; switching has to let it go too.
  func testWorkspaceSwitchDropsAnAdoptedBinding() async throws {
    let project = try temporaryProject()
    let other = try temporaryProject()
    try writeRegistry([
      (id: "ws-live", path: workspace.path, title: "微信用的",
       updatedAt: "2026-09-13T04:04:49.235Z"),
      (id: "ws-other", path: other, title: "另一个",
       updatedAt: "2026-09-10T12:45:25.252Z"),
    ])
    let (service, provider, _, _) = try await makeService(
      batches: [[
        inboundText("1", "/list"),
        inboundText("2", "/use 2"),
        inboundText("3", "/workspace 2"),
      ]],
      sessionList: listing(secondCwd: project)
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("已切换工作区") } }
    await service.stop()

    let state = ChannelStateStore.standard(appRoot: root).loadState()
    XCTAssertNil(state.sessions["owner@im.wechat"])
    XCTAssertNil(state.adoptedSessions["owner@im.wechat"])
  }
}
