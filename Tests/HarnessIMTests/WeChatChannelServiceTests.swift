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
  private var polls = 0

  /// When set, every `getupdates` answers this body instead of the script — the provider
  /// refusing the call rather than the account.
  var pollRejection: String?

  /// When set, `sendmessage` refuses with this body and nothing is recorded as sent. Used to prove
  /// that text a refused send dropped is not mistaken for text the phone received.
  var sendRejection: String?

  /// How long `sendmessage` takes to answer. Lets a test observe the world while a send is in
  /// flight, which is the only way to assert on what the *user* sees during a network round trip.
  var sendDelay: TimeInterval = 0

  /// Whether a `sendmessage` has been received at all, set before any delay.
  var sendReached: Bool {
    lock.lock(); defer { lock.unlock() }
    return reachedSend
  }
  private var reachedSend = false

  /// - Parameter batches: successive `getupdates` payloads; afterwards the poll is empty.
  init(batches: [[String]]) {
    self.queue = batches
  }

  var pollCount: Int {
    lock.lock(); defer { lock.unlock() }
    return polls
  }

  var sentMessages: [String] {
    lock.lock(); defer { lock.unlock() }
    return sentTexts
  }

  /// Drop what has been recorded so far, so a test can assert on the messages its own scenario
  /// produced without having to name the connectivity self-check in every expectation.
  func forgetSentMessages() {
    lock.lock(); sentTexts.removeAll(); lock.unlock()
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
      lock.lock(); reachedSend = true; let delay = sendDelay; lock.unlock()
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      let body = request.body.flatMap { try? JSONValue.parse($0) }
      let text = body?.path("msg.item_list.0.text_item.text")?.stringValue ?? ""
      lock.lock()
      let rejection = sendRejection
      if rejection == nil { sentTexts.append(text) }
      lock.unlock()
      if let rejection { return ILinkHTTPResponse(status: 200, body: Data(rejection.utf8)) }
      return ILinkHTTPResponse(status: 200, body: Data(#"{"ret":0}"#.utf8))
    }
    if url.contains("getupdates") {
      lock.lock()
      polls += 1
      let rejection = pollRejection
      // A refusal must not consume the script: the messages still belong to the next poll that
      // actually succeeds.
      let next = (rejection == nil && !queue.isEmpty) ? queue.removeFirst() : nil
      lock.unlock()
      if let rejection { return ILinkHTTPResponse(status: 200, body: Data(rejection.utf8)) }
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
    narration: WeChatChannelService.NarrationConfiguration = .init(interval: 0.05),
    config: ChannelConfig? = nil,
    approvalStream: StubRemoteEventStream? = nil,
    sessionList: String? = nil,
    modelCatalog: String? = nil,
    selectModelResult: String? = nil,
    onHarnessTransportCreate: (@Sendable () -> Void)? = nil
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
      if let modelCatalog, call.path.hasSuffix("session/modelCatalog") {
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":\#(modelCatalog)}}"#.utf8
        ))
      }
      if call.path.hasSuffix("session/selectModel") {
        if let selectModelResult {
          return HarnessAPIResponse(status: 200, body: Data(
            #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":\#(selectModelResult)}}"#.utf8
          ))
        }
        // The host's answer, defaulted to echoing what it was asked for: the selection it
        // installs is what `/model` reports back, so the test asserts on the real read-back.
        let request = call.body.flatMap { try? JSONValue.parse($0) }?.path("payload.args.request")
        let provider = request?["provider"]?.stringValue ?? ""
        let model = request?["model"]?.stringValue ?? ""
        let effort = request?["reasoningEffort"]?.stringValue
        let selected = effort.map {
          #"{"provider":"\#(provider)","model":"\#(model)","reasoningEffort":"\#($0)"}"#
        } ?? #"{"provider":"\#(provider)","model":"\#(model)"}"#
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":{"selected":\#(selected)}}}"#.utf8
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
      narrationConfiguration: narration,
      harnessTransport: {
        onHarnessTransportCreate?()
        return harnessTransport
      },
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
    /// The `request` half of every `session/selectModel` call, in order.
    var modelSelections: [JSONValue] {
      all.filter { $0.path.hasSuffix("session/selectModel") }.compactMap { call in
        call.body.flatMap { try? JSONValue.parse($0) }?.path("payload.args.request")
      }
    }
  }

  /// Turn 手机远控 on the way the app does, then drop the connectivity self-check from the record.
  ///
  /// The self-check has tests of its own; every other test that enables the switch is about the
  /// messages its own scenario produces, and naming the probe in each of those expectations would
  /// bury what they are actually asserting. The wait is what makes this honest — the probe is a real
  /// send, and the test only moves on once it has happened.
  private func enablePhoneControl(
    _ service: WeChatChannelService,
    _ provider: ScriptedILinkTransport
  ) async throws {
    await service.setForwardsAllPrompts(true)
    try await waitUntil { !provider.sentMessages.isEmpty }
    provider.forgetSentMessages()
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("condition not met within \(timeout)s")
  }

  /// Counts calls from any thread, for the "how many times did this happen" assertions.
  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  }

  // MARK: - Provider rejections

  /// The measured failure: the provider answered `ret -2` (a refused *request*), the channel
  /// read it as an expired binding, the badge said "未绑定" over a perfectly live session, and
  /// the poll stopped for good. A refusal is not an expiry.
  func testRefusedPollKeepsPollingAndShowsWhatTheProviderSaid() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    provider.pollRejection = #"{"ret":-2,"errmsg":"参数错误：context_token 无效"}"#
    await service.start()
    try await waitUntil {
      let status = await service.currentStatus()
      return status.lastError?.contains("context_token 无效") == true
    }

    let refused = await service.currentStatus()
    XCTAssertEqual(refused.phase, .degraded, "a refused request must not look like a dead binding")
    XCTAssertEqual(refused.lastError?.contains("参数错误"), true)

    // A second poll is the proof the loop survived; the first backoff is one second.
    try await waitUntil { provider.pollCount >= 2 }
    await service.stop()
  }

  /// The other half of the same distinction: `-14` really is an expired session, so polling stops
  /// and the badge asks for a new scan instead of retrying forever.
  func testExpiredSessionIsTerminalAndAsksForANewBind() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    provider.pollRejection = #"{"ret":-14,"errmsg":"session expired"}"#

    await service.start()
    try await waitUntil {
      await service.currentStatus().phase == .needsLogin
    }

    let expired = await service.currentStatus()
    XCTAssertEqual(expired.lastError?.contains("过期"), true)
    XCTAssertEqual(provider.pollCount, 1, "an expired session is terminal, not retried")
    await service.stop()
  }

  /// One transport for the channel's whole life.
  ///
  /// The factory used to run per operation; each run built a `URLSession` whose connections
  /// outlived the call, until the process ran out of descriptors (`EMFILE`) and could no longer
  /// write its own state file. Two commands must therefore build it exactly once.
  func testHarnessTransportIsBuiltOnceForTheWholeChannel() async throws {
    let creations = Counter()
    let (service, provider, _, _) = try await makeService(
      batches: [[inboundText("1", "/list")], [inboundText("2", "/list")]],
      sessionList: #"{"items":[]}"#,
      onHarnessTransportCreate: { creations.increment() }
    )

    await service.start()
    try await waitUntil { provider.sentMessages.count >= 2 }
    XCTAssertEqual(creations.value, 1, "the transport must be reused, not rebuilt per command")
    await service.stop()
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

  // MARK: - Information forwarding

  /// Write a two-turn session log into the channel's own `$DSH_HOME`, so the forwarder's lookup goes
  /// through the real path escaping rather than a shortcut that would pass even if it broke.
  private func writeSessionLog(cwd: String, sessionID: String, turns: [(turn: Int, text: String)]) throws {
    var lines = [#"{"type":"session","id":"\#(sessionID)"}"#]
    for entry in turns {
      lines.append(#"{"type":"turn/start","data":{"turn":\#(entry.turn)}}"#)
      lines.append(
        #"{"type":"assistant/message","data":{"turn":\#(entry.turn),"step":1,"message":{"id":"m\#(entry.turn)","role":"assistant","content":[{"type":"text","text":"\#(entry.text)"}]}}}"#
      )
      lines.append(#"{"type":"turn/end","data":{"turn":\#(entry.turn),"reason":{"kind":"completed"}}}"#)
    }
    let raw = Data((lines.joined(separator: "\n") + "\n").utf8)
    let directory = try SessionPaths.sessionDirectory(
      dshHome: root.appendingPathComponent("home"),
      cwd: cwd,
      sessionID: sessionID
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Zstd.compress(raw).write(to: directory.appendingPathComponent("session.v3.jsonl.zstd"))
  }

  /// The wording is the whole message on a phone, so it is pinned rather than eyeballed.
  func testTurnHeadlineNamesTheSessionAndTheOutcome() {
    func headline(_ kind: TurnEndKind, title: String? = "报告", turn: Int? = 3) -> String {
      WeChatChannelService.turnHeadline(
        TurnCompletion(sessionID: "session-x", sessionTitle: title, turn: turn, kind: kind)
      )
    }
    XCTAssertEqual(headline(.completed), "✅ 报告 · 第 3 轮完成")
    XCTAssertEqual(headline(.maxTokens), "⚠️ 报告 · 第 3 轮达到输出上限后停止")
    XCTAssertEqual(headline(.blocked), "⛔️ 报告 · 第 3 轮被拒绝执行")
    XCTAssertEqual(headline(.aborted), "🛑 报告 · 第 3 轮已中断")
    // A missing title falls back to the id rather than producing an empty name, and a missing turn
    // number to "本轮" rather than to "第 nil 轮".
    XCTAssertEqual(headline(.completed, title: "   ", turn: nil), "✅ session-x · 本轮完成")
  }

  func testTurnHeadlineCarriesTheStructuredFailure() {
    let completion = TurnCompletion(
      sessionID: "session-x",
      sessionTitle: "报告",
      turn: 2,
      kind: .error,
      failureCode: "quota-exceeded",
      failureMessage: "余额不足"
    )
    XCTAssertEqual(WeChatChannelService.turnHeadline(completion), "❌ 报告 · 第 2 轮失败（quota-exceeded：余额不足）")
    // A failure with no detail still names the outcome; the parentheses are dropped rather than
    // rendered empty.
    let bare = TurnCompletion(sessionID: "session-x", turn: 2, kind: .error)
    XCTAssertEqual(WeChatChannelService.turnHeadline(bare), "❌ session-x · 第 2 轮失败")
  }

  /// The shared switch is the only gate: with 手机远控 off, nothing about a finished turn goes out.
  func testForwardingIsSilentUntilTheSwitchIsOn() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    try writeSessionLog(cwd: workspace.path, sessionID: "session-desk", turns: [(1, "桌面会话的答案")])

    await service.forwardTurnInfo(TurnCompletion(
      sessionID: "session-desk", sessionTitle: "报告", turn: 1, kind: .completed, cwd: workspace.path
    ))

    XCTAssertTrue(provider.sentMessages.isEmpty, "未开启手机远控时不应发出任何东西：\(provider.sentMessages)")
    await service.stop()
  }

  /// With the switch on, one finished turn becomes two messages: what happened, and what it said.
  func testForwardingSendsTheHeadlineAndTheTurnsAnswer() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    try await enablePhoneControl(service, provider)
    try writeSessionLog(cwd: workspace.path, sessionID: "session-desk", turns: [
      (1, "第一轮的答案"),
      (2, "第二轮的答案"),
    ])

    await service.forwardTurnInfo(TurnCompletion(
      sessionID: "session-desk", sessionTitle: "报告", turn: 2, kind: .completed, cwd: workspace.path
    ))

    let sent = provider.sentMessages
    XCTAssertEqual(sent, ["✅ 报告 · 第 2 轮完成", "第二轮的答案"])
    await service.stop()
  }

  /// The answer comes from the turn the ending names, not from whatever the log ends with.
  func testForwardingReadsOnlyTheNamedTurn() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    try await enablePhoneControl(service, provider)
    try writeSessionLog(cwd: workspace.path, sessionID: "session-desk", turns: [
      (1, "旧的答案"),
      (2, "新的答案"),
    ])

    await service.forwardTurnInfo(TurnCompletion(
      sessionID: "session-desk", sessionTitle: "报告", turn: 1, kind: .completed, cwd: workspace.path
    ))

    XCTAssertEqual(provider.sentMessages, ["✅ 报告 · 第 1 轮完成", "旧的答案"])
    await service.stop()
  }

  /// A log that cannot be found is ordinary — a workspace that moved, a path convention that changed
  /// — and the headline still has to go out, because "it finished" is the part the user needs.
  func testForwardingStillSendsTheHeadlineWithoutALoggableAnswer() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    try await enablePhoneControl(service, provider)

    await service.forwardTurnInfo(TurnCompletion(
      sessionID: "session-nowhere", sessionTitle: "报告", turn: 1, kind: .completed, cwd: workspace.path
    ))

    XCTAssertEqual(provider.sentMessages, ["✅ 报告 · 第 1 轮完成"])
    await service.stop()
  }

  /// A bound, not the whole answer: a long turn would otherwise arrive as a dozen phone messages,
  /// which is the failure mode that gets a forwarding feature switched off.
  func testForwardedReplyIsBoundedAndSaysSo() {
    let short = String(repeating: "短", count: 10)
    XCTAssertEqual(WeChatChannelService.bounded(short, limit: 600), short)

    let marker = "\n…（内容较长，完整内容在 app 里）"
    let long = String(repeating: "长", count: 700)
    let bounded = WeChatChannelService.bounded(long, limit: 600)
    XCTAssertTrue(bounded.hasPrefix(String(repeating: "长", count: 600)))
    XCTAssertTrue(bounded.hasSuffix(marker), bounded)
    XCTAssertEqual(bounded.count, 600 + marker.count)
  }

  /// Exactly at the limit is not "too long", so a reply that fits is not marked as clipped.
  func testBoundedLeavesAReplyAtTheLimitAlone() {
    let exact = String(repeating: "x", count: 600)
    XCTAssertEqual(WeChatChannelService.bounded(exact, limit: 600), exact)
  }

  func testBoundedCollapsesWhitespaceOnlyText() {
    XCTAssertEqual(WeChatChannelService.bounded("   \n  ", limit: 10), "")
  }

  // MARK: - Connectivity self-check

  /// Switching the phone on says so *to the phone*, so "远控开着却什么都收不到" has an answer: either
  /// the self-check arrives or the window explains why it did not.
  func testTurningTheSwitchOnSendsAConnectivityProbe() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()

    await service.setForwardsAllPrompts(true)

    try await waitUntil { !provider.sentMessages.isEmpty }
    let sent = provider.sentMessages
    XCTAssertEqual(sent.count, 1, "开启时只应有一条自检消息：\(sent)")
    XCTAssertTrue(sent[0].contains("连通性自检"), sent[0])
    // The wording tells the user what seeing it means, and what will follow.
    XCTAssertTrue(sent[0].contains("通道是通的"), sent[0])
    XCTAssertTrue(sent[0].contains("不需要回复"), sent[0])
    await service.stop()
  }

  /// It reports the outcome where the user is actually looking, and a send that worked clears an
  /// error left over from before — the strongest evidence there is that the link is back.
  func testASuccessfulProbeSaysSoAndClearsAStaleError() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    provider.sendRejection = #"{"ret":-2,"errmsg":"参数错误：context_token 无效"}"#
    await service.setForwardsAllPrompts(true)
    try await waitUntil { await service.currentStatus().lastError != nil }

    let failed = await service.currentStatus()
    XCTAssertTrue(failed.detail?.contains("没能送达") == true, failed.detail ?? "无")

    // A second attempt with the provider answering normally: the detail flips, the error clears.
    provider.sendRejection = nil
    await service.setForwardsAllPrompts(false)
    await service.setForwardsAllPrompts(true)

    try await waitUntil { await service.currentStatus().lastError == nil }
    let recovered = await service.currentStatus()
    XCTAssertTrue(recovered.detail?.contains("已送达手机") == true, recovered.detail ?? "无")
    XCTAssertEqual(provider.sentMessages, [WeChatChannelService.phoneLinkProbeText])
    await service.stop()
  }

  /// The button flips on the user's click, not when the provider answers. The self-check is a network
  /// round trip, and a switch that looks dead for its duration is a worse bug than the silence it was
  /// meant to remove.
  func testTheSwitchIsPublishedWhileTheSelfCheckIsStillInFlight() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    provider.sendDelay = 0.5

    let toggling = Task { await service.setForwardsAllPrompts(true) }
    try await waitUntil(timeout: 2) { provider.sendReached }

    let inFlight = await service.currentStatus()
    XCTAssertTrue(inFlight.forwardsAllPrompts, "自检还在路上时，开关就应该已经显示为开启")
    XCTAssertTrue(provider.sentMessages.isEmpty, "自检尚未返回，不该已经记成送达")

    await toggling.value
    try await waitUntil { !provider.sentMessages.isEmpty }
    await service.stop()
  }

  /// Switching **off** is not a moment to send anything: the phone is being taken off the hook, and a
  /// message arriving to announce that would be the last thing the user expects.
  func testTurningTheSwitchOffSendsNothing() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    await service.setForwardsAllPrompts(true)
    try await waitUntil { provider.sentMessages.count == 1 }

    await service.setForwardsAllPrompts(false)
    try await Task.sleep(for: .milliseconds(150))

    XCTAssertEqual(provider.sentMessages.count, 1, "关闭开关不应发消息：\(provider.sentMessages)")
    await service.stop()
  }

  /// Every time it goes on, not just the first: the switch is a decision the user may be re-taking
  /// after changing the bot, and a check that only ran once would not check the new one.
  func testEverySwitchOnIsChecked() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()

    await service.setForwardsAllPrompts(true)
    try await waitUntil { provider.sentMessages.count == 1 }
    await service.setForwardsAllPrompts(false)
    await service.setForwardsAllPrompts(true)
    try await waitUntil { provider.sentMessages.count == 2 }

    XCTAssertEqual(provider.sentMessages, [
      WeChatChannelService.phoneLinkProbeText,
      WeChatChannelService.phoneLinkProbeText,
    ])
    await service.stop()
  }

  // MARK: - Running narration
  /// The wording of a narration batch, pinned because it is what the user reads on a phone: the
  /// conversation and the turn first, so two sessions narrating at once stay tellable apart.
  func testNarrationHeadlineNamesTheSessionAndTheTurn() {
    XCTAssertEqual(
      WeChatChannelService.narrationHeadline(sessionTitle: "报告", sessionID: "session-x", turn: 4),
      "📝 报告 · 第 4 轮"
    )
    // The same fallbacks as the turn headline: a blank title falls back to the id, a missing turn
    // number to "本轮" rather than to "第 nil 轮".
    XCTAssertEqual(
      WeChatChannelService.narrationHeadline(sessionTitle: "   ", sessionID: "session-x", turn: nil),
      "📝 session-x · 本轮"
    )
  }

  /// The feature: a paragraph written mid-turn goes out while the turn is still running, instead of
  /// waiting for the ending — which only ever forwards the *last* paragraph.
  func testNarrationIsForwardedWhileTheTurnRuns() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    try await enablePhoneControl(service, provider)

    await service.forwardAssistantText(AssistantTextSegment(
      sessionID: "session-desk", sessionTitle: "报告", turn: 4, step: 3, text: "这个要分两步验证。"
    ))

    try await waitUntil { !provider.sentMessages.isEmpty }
    XCTAssertEqual(provider.sentMessages, ["📝 报告 · 第 4 轮\n这个要分两步验证。"])
    await service.stop()
  }

  /// The volume rule: paragraphs written in one burst leave as one message, in order, separated so a
  /// phone keeps the paragraph breaks the transcript had.
  func testNarrationParagraphsInABurstBecomeOneMessage() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    try await enablePhoneControl(service, provider)

    for text in ["先看 C 层。", "再看 B 层。", "结论是两边都被挡住了。"] {
      await service.forwardAssistantText(AssistantTextSegment(
        sessionID: "session-desk", sessionTitle: "报告", turn: 4, text: text
      ))
    }

    try await waitUntil { !provider.sentMessages.isEmpty }
    XCTAssertEqual(
      provider.sentMessages,
      ["📝 报告 · 第 4 轮\n先看 C 层。\n\n再看 B 层。\n\n结论是两边都被挡住了。"]
    )
    // One message, not three, and no second one arriving late.
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(provider.sentMessages.count, 1)
    await service.stop()
  }

  /// The other half of the bound: narration that arrives faster than the interval must not build an
  /// arbitrarily long message, so a batch that is already big enough leaves immediately.
  func testNarrationOverTheBatchLimitIsSentWithoutWaiting() async throws {
    let (service, provider, _, _) = try await makeService(
      batches: [],
      narration: .init(interval: 30, batchLimit: 10)
    )
    await service.start()
    try await enablePhoneControl(service, provider)

    await service.forwardAssistantText(AssistantTextSegment(
      sessionID: "session-desk", sessionTitle: "报告", turn: 1, text: "这一段的长度已经超过了批次上限。"
    ))

    // No wait for the (30 second) interval: the size is what triggered it.
    try await waitUntil(timeout: 2) { !provider.sentMessages.isEmpty }
    XCTAssertEqual(provider.sentMessages.count, 1)
    await service.stop()
  }

  /// The switch is the only gate for narration as well: with 手机远控 off, nothing goes out and
  /// nothing is left buffered to leak when it is switched on later.
  func testNarrationIsSilentUntilTheSwitchIsOn() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()

    await service.forwardAssistantText(AssistantTextSegment(
      sessionID: "session-desk", sessionTitle: "报告", turn: 1, text: "开关没开时说的一句话"
    ))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(provider.sentMessages.isEmpty, "未开启手机远控时不应发出任何东西：\(provider.sentMessages)")

    // Switching on later must not flush what was written while it was off.
    try await enablePhoneControl(service, provider)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(provider.sentMessages.isEmpty, "开关打开后不应补发开关关闭期间的内容")
    await service.stop()
  }

  /// Switching off drops the buffer: a paragraph collected a moment before the switch went off is
  /// not a reason to keep sending after it.
  func testSwitchingOffDropsBufferedNarration() async throws {
    let (service, provider, _, _) = try await makeService(
      batches: [],
      narration: .init(interval: 2)
    )
    await service.start()
    try await enablePhoneControl(service, provider)

    await service.forwardAssistantText(AssistantTextSegment(
      sessionID: "session-desk", sessionTitle: "报告", turn: 1, text: "还没发出去的一段"
    ))
    await service.setForwardsAllPrompts(false)
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertTrue(provider.sentMessages.isEmpty, "关闭远控后不应再有过程正文发出：\(provider.sentMessages)")
    await service.stop()
  }

  /// The duplicate this exists to prevent: a turn's answer *is* its last paragraph, so once that
  /// paragraph has gone out as narration the ending must not send it a second time.
  func testTheTurnsAnswerIsNotForwardedTwiceWhenItWasNarrated() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    try await enablePhoneControl(service, provider)
    try writeSessionLog(cwd: workspace.path, sessionID: "session-desk", turns: [(2, "第二轮的答案")])

    await service.forwardAssistantText(AssistantTextSegment(
      sessionID: "session-desk", sessionTitle: "报告", turn: 2, text: "第二轮的答案"
    ))
    try await waitUntil { !provider.sentMessages.isEmpty }

    await service.forwardTurnInfo(TurnCompletion(
      sessionID: "session-desk", sessionTitle: "报告", turn: 2, kind: .completed, cwd: workspace.path
    ))

    XCTAssertEqual(provider.sentMessages, [
      "📝 报告 · 第 2 轮\n第二轮的答案",
      "✅ 报告 · 第 2 轮完成",
    ])
    await service.stop()
  }

  /// The other side of that rule: narration that was *not* the answer does not suppress it. The
  /// phone still gets the answer under the headline.
  func testTheTurnsAnswerIsStillForwardedWhenNarrationWasSomethingElse() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    try await enablePhoneControl(service, provider)
    try writeSessionLog(cwd: workspace.path, sessionID: "session-desk", turns: [(2, "第二轮的答案")])

    await service.forwardAssistantText(AssistantTextSegment(
      sessionID: "session-desk", sessionTitle: "报告", turn: 2, text: "先看看这个报告。"
    ))
    try await waitUntil { !provider.sentMessages.isEmpty }

    await service.forwardTurnInfo(TurnCompletion(
      sessionID: "session-desk", sessionTitle: "报告", turn: 2, kind: .completed, cwd: workspace.path
    ))

    XCTAssertEqual(provider.sentMessages, [
      "📝 报告 · 第 2 轮\n先看看这个报告。",
      "✅ 报告 · 第 2 轮完成",
      "第二轮的答案",
    ])
    await service.stop()
  }

  /// A paragraph the provider refused is not remembered as sent, so the answer it carried still goes
  /// out under the headline instead of being silently swallowed by the dedupe.
  func testARefusedNarrationDoesNotSuppressTheAnswer() async throws {
    let (service, provider, _, _) = try await makeService(batches: [])
    await service.start()
    try await enablePhoneControl(service, provider)
    try writeSessionLog(cwd: workspace.path, sessionID: "session-desk", turns: [(2, "第二轮的答案")])
    provider.sendRejection = #"{"ret":-2,"errmsg":"参数错误：context_token 无效"}"#

    await service.forwardAssistantText(AssistantTextSegment(
      sessionID: "session-desk", sessionTitle: "报告", turn: 2, text: "第二轮的答案"
    ))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(provider.sentMessages.isEmpty, "发送被拒绝时不应记成已送达：\(provider.sentMessages)")

    provider.sendRejection = nil
    await service.forwardTurnInfo(TurnCompletion(
      sessionID: "session-desk", sessionTitle: "报告", turn: 2, kind: .completed, cwd: workspace.path
    ))

    // The turn-end flush retries the refused paragraph first, then the headline; the answer itself is
    // already on the phone as that paragraph, so it is not sent a third time.
    XCTAssertEqual(provider.sentMessages, [
      "📝 报告 · 第 2 轮\n第二轮的答案",
      "✅ 报告 · 第 2 轮完成",
    ])
    await service.stop()
  }

  /// Narration follows the same ownership rule as the ending: a session the chat already answers for
  /// must not have its paragraphs pushed back into the conversation they came from.
  func testNarrationSkipsASessionTheChatAlreadyAnswersFor() async throws {
    let (service, provider, _, _) = try await makeService(batches: [[
      inboundText("1", "看看这个报告"),
      inboundText("2", "开始"),
    ]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    await service.setForwardsAllPrompts(true)
    let before = provider.sentMessages.count

    await service.forwardAssistantText(AssistantTextSegment(
      sessionID: "session-test", sessionTitle: "微信会话", turn: 1, text: "渠道自己的会话在说的话"
    ))
    try await Task.sleep(for: .milliseconds(150))

    XCTAssertEqual(provider.sentMessages.count, before, "渠道自己的会话不应被播报")
    await service.stop()
  }

  /// An unowned session is a desk session and always forwarded.
  func testUnownedSessionsAreForwarded() {
    XCTAssertTrue(WeChatChannelService.shouldForward(
      sessionID: "session-desk", owner: nil, adoptedSessionID: nil
    ))
  }
  /// A session the channel created already delivers its answer into the chat, so forwarding it again
  /// would send the same text twice.
  func testCreatedSessionsAreNotForwardedTwice() {
    XCTAssertFalse(WeChatChannelService.shouldForward(
      sessionID: "session-test", owner: "owner@im.wechat", adoptedSessionID: nil
    ))
  }

  /// A session the phone merely took over is different: the chat borrowed its approvals, and nothing
  /// else pushes its output there. Skipping it would silently lose every result of a taken-over
  /// session.
  func testAdoptedSessionsAreStillForwarded() {
    XCTAssertTrue(WeChatChannelService.shouldForward(
      sessionID: "session-adopted", owner: "owner@im.wechat", adoptedSessionID: "session-adopted"
    ))
  }

  /// Adopting a *different* session must not unlock forwarding for the created one.
  func testAdoptionOfAnotherSessionDoesNotUnlockTheCreatedOne() {
    XCTAssertFalse(WeChatChannelService.shouldForward(
      sessionID: "session-test", owner: "owner@im.wechat", adoptedSessionID: "session-other"
    ))
  }

  /// A session the chat already answers for must not be forwarded: the reply source delivers that
  /// same text into the conversation it came from, and receiving it twice is the visible bug.
  func testForwardingSkipsASessionTheChatAlreadyAnswersFor() async throws {
    let (service, provider, _, _) = try await makeService(batches: [[
      inboundText("1", "看看这个报告"),
      inboundText("2", "开始"),
    ]])
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    await service.setForwardsAllPrompts(true)
    let before = provider.sentMessages.count

    await service.forwardTurnInfo(TurnCompletion(
      sessionID: "session-test", sessionTitle: "微信会话", turn: 1, kind: .completed, cwd: workspace.path
    ))

    XCTAssertEqual(provider.sentMessages.count, before, "渠道自己的会话不应重复转发")
    await service.stop()
  }

  // MARK: - Models and reasoning effort

  /// Two models that both take `high`/`low`, which is the shape a phone actually sees.
  private static let modelCatalogJSON = #"""
  {"default":{"provider":"deepseek","model":"deepseek-chat"},"routableProviders":["deepseek"],
   "groups":[{"id":"deepseek","name":"DeepSeek","models":[
     {"id":"deepseek-chat","name":"DeepSeek Chat",
      "reasoning":{"efforts":[{"id":"high","name":"高"},{"id":"low","name":"低"}],"defaultEffort":"high"}},
     {"id":"deepseek-reasoner","name":"DeepSeek Reasoner",
      "reasoning":{"efforts":[{"id":"high","name":"高"},{"id":"low","name":"低"}],"defaultEffort":"high"}}]}],
   "failures":[]}
  """#

  /// One model with no reasoning block at all.
  private static let noTierCatalogJSON = #"""
  {"default":{"provider":"deepseek","model":"deepseek-chat"},"routableProviders":["deepseek"],
   "groups":[{"id":"deepseek","name":"DeepSeek","models":[
     {"id":"deepseek-chat","name":"DeepSeek Chat"}]}],
   "failures":[]}
  """#

  /// A `session/list` answer whose one row is the session the channel creates, running on `model`.
  ///
  /// That projection is where `/model` reads what is in force, so a test controls the "current"
  /// line by answering with the state it wants.
  private func sessionListRunning(_ model: String, effort: String? = nil) -> String {
    let selection = effort.map {
      #"{"provider":"deepseek","model":"\#(model)","reasoningEffort":"\#($0)"}"#
    } ?? #"{"provider":"deepseek","model":"\#(model)"}"#
    return #"""
    {"items":[{"sessionId":"session-test","cwd":"\#(workspace.path)","updatedAt":1700000000000,
      "running":false,"projections":{"values":{"title":"微信 · owner",
      "modelSelection":{"lastUsed":null,"next":\#(selection)}}}}]}
    """#
  }

  private func choice(_ model: String) -> HarnessModelChoice {
    HarnessModelChoice(provider: "deepseek", providerName: "DeepSeek", model: model, name: model)
  }

  func testModelCommandListsTheCatalogAndMarksTheCurrentModel() async throws {
    let (service, provider, _, _) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/model")],
      ],
      sessionList: sessionListRunning("deepseek-chat", effort: "high"),
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { provider.sentMessages.contains { $0.contains("模型（共 2 个）") } }
    await service.stop()

    let text = try XCTUnwrap(provider.sentMessages.last { $0.contains("模型（共 2 个）") })
    XCTAssertTrue(text.contains("当前：deepseek-chat · high"), text)
    XCTAssertTrue(text.contains("1. ● DeepSeek Chat（deepseek-chat）"), text)
    XCTAssertTrue(text.contains("2.   DeepSeek Reasoner（deepseek-reasoner）"), text)
    XCTAssertTrue(text.contains("/model 2 high"), text)
  }

  /// The point of the feature: the switch reaches the bound session, with the effort, for the
  /// *next* turn — not a note that something might have changed.
  func testModelSwitchPinsModelAndEffortOnTheBoundSession() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/model 2 high")],
      ],
      sessionList: sessionListRunning("deepseek-chat"),
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { provider.sentMessages.contains { $0.contains("模型已切换") } }
    await service.stop()

    let request = try XCTUnwrap(harness.modelSelections.last)
    XCTAssertEqual(request["sessionId"]?.stringValue, "session-test")
    XCTAssertEqual(request["provider"]?.stringValue, "deepseek")
    XCTAssertEqual(request["model"]?.stringValue, "deepseek-reasoner")
    XCTAssertEqual(request["reasoningEffort"]?.stringValue, "high")

    let text = try XCTUnwrap(provider.sentMessages.last { $0.contains("模型已切换") })
    XCTAssertTrue(text.contains("deepseek-reasoner"), text)
    XCTAssertTrue(text.contains("思考强度：high"), text)
    XCTAssertTrue(text.contains("下一条消息就会用它"), text)
  }

  /// Naming no effort installs the model's *own* default, not the previous model's tier — the same
  /// choice the desktop model menu makes.
  func testModelSwitchWithoutAnEffortUsesThatModelsDefault() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/model 2")],
      ],
      sessionList: sessionListRunning("deepseek-chat", effort: "low"),
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { !harness.modelSelections.isEmpty }
    await service.stop()

    let request = try XCTUnwrap(harness.modelSelections.last)
    XCTAssertEqual(request["model"]?.stringValue, "deepseek-reasoner")
    XCTAssertEqual(request["reasoningEffort"]?.stringValue, "high")
  }

  /// `/model 2 high` is validated against that model's tiers: an effort it does not have is a
  /// typo to report, not something to forward and let the host reject.
  func testModelSwitchRejectsAnEffortTheModelDoesNotHave() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/model 2 特高")],
      ],
      sessionList: sessionListRunning("deepseek-chat"),
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { provider.sentMessages.contains { $0.contains("没有找到思考强度") } }
    await service.stop()

    XCTAssertTrue(harness.modelSelections.isEmpty, "a rejected effort must not reach the harness")
    let text = try XCTUnwrap(provider.sentMessages.last { $0.contains("没有找到思考强度") })
    XCTAssertTrue(text.contains("high、low"), text)
  }

  func testUnknownModelIsAnsweredWithoutTouchingTheHarness() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/model gpt-5")],
      ],
      sessionList: sessionListRunning("deepseek-chat"),
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { provider.sentMessages.contains { $0.contains("没有找到模型") } }
    await service.stop()

    XCTAssertTrue(harness.modelSelections.isEmpty)
    XCTAssertTrue(provider.sentMessages.contains { $0.contains("没有找到模型「gpt-5」") })
  }

  /// `/effort` is the second half of the feature: change the tier without changing the model.
  func testEffortCommandSwitchesTheTierOfTheCurrentModel() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/effort low")],
      ],
      sessionList: sessionListRunning("deepseek-reasoner", effort: "high"),
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { !harness.modelSelections.isEmpty }
    await service.stop()

    let request = try XCTUnwrap(harness.modelSelections.last)
    XCTAssertEqual(request["model"]?.stringValue, "deepseek-reasoner", "the model must be left alone")
    XCTAssertEqual(request["reasoningEffort"]?.stringValue, "low")
  }

  /// "默认" clears the tier: the request then carries no effort field at all, which is a different
  /// request from naming one.
  func testEffortDefaultClearsTheTier() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/effort 默认")],
      ],
      sessionList: sessionListRunning("deepseek-reasoner", effort: "high"),
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { !harness.modelSelections.isEmpty }
    await service.stop()

    let request = try XCTUnwrap(harness.modelSelections.last)
    XCTAssertEqual(request["model"]?.stringValue, "deepseek-reasoner")
    XCTAssertNil(request["reasoningEffort"], "no preference is an absent field, not an empty one")
  }

  /// The listing numbers the tiers, and a later `/effort 1` means the row the user read.
  func testEffortListingNumbersTiersAndTheIndexResolvesAgainstIt() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/effort")],
        [inboundText("4", "/effort 1")],
      ],
      sessionList: sessionListRunning("deepseek-reasoner", effort: "low"),
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("的思考强度") } }
    try await waitUntil { !harness.modelSelections.isEmpty }
    await service.stop()

    let listing = try XCTUnwrap(provider.sentMessages.first { $0.contains("的思考强度") })
    XCTAssertTrue(listing.contains("当前：low"), listing)
    XCTAssertTrue(listing.contains("1.   high（高）"), listing)
    XCTAssertTrue(listing.contains("2. ● low（低）"), listing)
    XCTAssertEqual(harness.modelSelections.last?["reasoningEffort"]?.stringValue, "high")
  }

  /// When the host does not project a selection, `/effort` must ask rather than guess: installing
  /// an effort on the harness default would move a session the channel could not read.
  func testEffortCommandAsksWhenTheCurrentModelIsUnknown() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/effort high")],
      ],
      sessionList: #"{"items":[{"sessionId":"session-test","cwd":"/tmp/x","updatedAt":1700000000000,"running":false}]}"#,
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { provider.sentMessages.contains { $0.contains("还不知道当前用的是哪个模型") } }
    await service.stop()

    XCTAssertTrue(harness.modelSelections.isEmpty, "an unknown model must not be retargeted by guess")
  }

  func testEffortCommandExplainsAModelWithoutTiers() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "看看这个报告"), inboundText("2", "开始")],
        [inboundText("3", "/effort high")],
      ],
      sessionList: sessionListRunning("deepseek-chat"),
      modelCatalog: Self.noTierCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains("结果是 42") }
    try await waitUntil { provider.sentMessages.contains { $0.contains("不支持调思考强度") } }
    await service.stop()

    XCTAssertTrue(harness.modelSelections.isEmpty)
  }

  /// A model chosen before the first message has no session to live on, so the channel remembers
  /// it — and the session it creates next starts on it, from its very first turn.
  func testModelChosenBeforeAnySessionAppliesToTheNextOne() async throws {
    let (service, provider, _, harness) = try await makeService(
      batches: [
        [inboundText("1", "/model 2")],
        [inboundText("2", "看看这个报告"), inboundText("3", "开始")],
      ],
      sessionList: sessionListRunning("deepseek-chat"),
      modelCatalog: Self.modelCatalogJSON
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("模型已选好") } }
    try await waitUntil { !harness.modelSelections.isEmpty }
    await service.stop()

    let confirmation = try XCTUnwrap(provider.sentMessages.first { $0.contains("模型已选好") })
    XCTAssertTrue(confirmation.contains("还没有绑定会话"), confirmation)
    XCTAssertTrue(confirmation.contains("下一条消息开的新会话上生效"), confirmation)

    let request = try XCTUnwrap(harness.modelSelections.last)
    XCTAssertEqual(request["sessionId"]?.stringValue, "session-test")
    XCTAssertEqual(request["model"]?.stringValue, "deepseek-reasoner")
    XCTAssertEqual(request["reasoningEffort"]?.stringValue, "high")
  }

  /// A harness too old to have the endpoint answers 404, which is a problem the user can fix —
  /// so it gets its own sentence instead of a bare "HTTP 404".
  func testHarnessWithoutTheModelCatalogSaysWhichEndpointIsMissing() async throws {
    let (service, provider, _, _) = try await makeService(
      batches: [[inboundText("1", "/model")]],
      harnessResponders: { call in
        if call.method == "GET" {
          return HarnessAPIResponse(status: 303, headers: ["set-cookie": "dsh-auth-k=v; Path=/"], body: Data())
        }
        if call.path.hasSuffix("session/modelCatalog") {
          return HarnessAPIResponse(status: 404, body: Data("not found".utf8))
        }
        return HarnessAPIResponse(status: 200, body: Data(
          #"{"type":"server-response","rpcId":"x","result":{"ok":false,"error":{"code":"gateway/arguments-invalid","message":"args","details":{}}}}"#.utf8
        ))
      }
    )
    await service.start()
    try await waitUntil { provider.sentMessages.contains { $0.contains("没有模型目录") } }
    await service.stop()

    let text = try XCTUnwrap(provider.sentMessages.last { $0.contains("没有模型目录") })
    XCTAssertTrue(text.contains("session/modelCatalog"), text)
  }

  /// An index is only meaningful against the listing it came from, so the row the user read wins
  /// over a fresh catalog read that may have reordered or regrown underneath them.
  func testModelIndexResolvesAgainstTheListingTheUserRead() {
    let catalog = HarnessModelCatalog(choices: [choice("a"), choice("b"), choice("c")])
    let shown = [choice("c"), choice("a")]

    XCTAssertEqual(WeChatChannelService.resolveModel(target: "1", shown: shown, catalog: catalog)?.model, "c")
    XCTAssertEqual(WeChatChannelService.resolveModel(target: "2", shown: shown, catalog: catalog)?.model, "a")
    // Beyond the shown listing the fresh catalog still answers, in the same order.
    XCTAssertEqual(WeChatChannelService.resolveModel(target: "3", shown: shown, catalog: catalog)?.model, "c")
    XCTAssertEqual(WeChatChannelService.resolveModel(target: "b", shown: shown, catalog: catalog)?.model, "b")
    XCTAssertNil(WeChatChannelService.resolveModel(target: "9", shown: shown, catalog: catalog))
    XCTAssertNil(WeChatChannelService.resolveModel(target: "zzz", shown: shown, catalog: catalog))
  }

  func testEffortResolutionSeparatesUnknownFromProviderDefault() {
    let model = HarnessModelChoice(
      provider: "deepseek", providerName: "DeepSeek", model: "m", name: "M",
      efforts: [HarnessModelEffort(id: "high", name: "高")],
      defaultEffort: "high"
    )
    XCTAssertEqual(WeChatChannelService.resolveEffort("高", choice: model), .tier("high"))
    XCTAssertEqual(WeChatChannelService.resolveEffort("HIGH", choice: model), .tier("high"))
    XCTAssertEqual(WeChatChannelService.resolveEffort("默认", choice: model), .providerDefault)
    XCTAssertEqual(WeChatChannelService.resolveEffort("特高", choice: model), .unknown)
  }
}
