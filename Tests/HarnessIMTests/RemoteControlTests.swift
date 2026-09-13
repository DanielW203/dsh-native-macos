import Foundation
import HarnessKit
import XCTest

@testable import HarnessIM

// MARK: - Command grammar

final class ChatCommandParserTests: XCTestCase {
  func testParsesEveryDocumentedForm() {
    XCTAssertEqual(ChatCommandParser.parse("/list"), .command(.list))
    XCTAssertEqual(ChatCommandParser.parse("/列表"), .command(.list))
    XCTAssertEqual(ChatCommandParser.parse("/use 2"), .command(.use("2")))
    XCTAssertEqual(ChatCommandParser.parse("/接管 2"), .command(.use("2")))
    XCTAssertEqual(ChatCommandParser.parse("/current"), .command(.current))
    XCTAssertEqual(ChatCommandParser.parse("/history"), .command(.history(nil)))
    XCTAssertEqual(ChatCommandParser.parse("/history 10"), .command(.history(10)))
    XCTAssertEqual(ChatCommandParser.parse("/say 跑一下测试"), .command(.say("跑一下测试")))
    XCTAssertEqual(ChatCommandParser.parse("/stop"), .command(.stop))
    XCTAssertEqual(ChatCommandParser.parse("/中断"), .command(.stop))
    XCTAssertEqual(ChatCommandParser.parse("/answer 1"), .command(.answer("1")))
    XCTAssertEqual(ChatCommandParser.parse("/new"), .command(.newSession))
    XCTAssertEqual(ChatCommandParser.parse("/新会话"), .command(.newSession))
    XCTAssertEqual(ChatCommandParser.parse("/help"), .command(.help))
  }

  /// The sigil is the whole contract: without it a message is content, however command-like.
  func testTextWithoutTheSigilIsNotACommand() {
    XCTAssertNil(ChatCommandParser.parse("看看这个文件"))
    XCTAssertNil(ChatCommandParser.parse("list"))
    XCTAssertNil(ChatCommandParser.parse(""))
    XCTAssertNil(ChatCommandParser.parse("  "))
  }

  /// A typo must be answered, not submitted to a running session.
  func testUnknownVerbIsReportedRatherThanIgnored() {
    XCTAssertEqual(ChatCommandParser.parse("/nope"), .unknown("nope"))
    // Verbs are case-folded, so an upper-case spelling is the command, not a typo.
    XCTAssertEqual(ChatCommandParser.parse("/USE 2"), .command(.use("2")))
  }

  func testMissingOrUnusableArgumentsBecomeUnknown() {
    XCTAssertEqual(ChatCommandParser.parse("/use"), .unknown("use"))
    XCTAssertEqual(ChatCommandParser.parse("/say"), .unknown("say"))
    XCTAssertEqual(ChatCommandParser.parse("/answer"), .unknown("answer"))
    // A history depth that is not a positive number is a typo, not "zero turns".
    XCTAssertEqual(ChatCommandParser.parse("/history abc"), .unknown("history"))
    XCTAssertEqual(ChatCommandParser.parse("/history 0"), .unknown("history"))
  }

  func testFullWidthSpaceSeparatesTheVerb() {
    XCTAssertEqual(ChatCommandParser.parse("/say　你好"), .command(.say("你好")))
  }

  /// `/workspace` is the one verb where "no argument" is a real request — "where am I?" — so
  /// it lists instead of reporting a typo, and its short spellings mean the same thing.
  func testParsesWorkspaceForms() {
    XCTAssertEqual(ChatCommandParser.parse("/workspace"), .command(.workspaceList))
    XCTAssertEqual(ChatCommandParser.parse("/工作区"), .command(.workspaceList))
    XCTAssertEqual(ChatCommandParser.parse("/WS"), .command(.workspaceList))
    XCTAssertEqual(ChatCommandParser.parse("/workspace 2"), .command(.workspace("2")))
    XCTAssertEqual(ChatCommandParser.parse("/ws ~/Projects/x"), .command(.workspace("~/Projects/x")))
    XCTAssertEqual(ChatCommandParser.parse("/工作区 /tmp/a"), .command(.workspace("/tmp/a")))
  }
}

// MARK: - Reply text

final class ChatReplyTests: XCTestCase {
  private func summary(
    _ id: String,
    title: String? = nil,
    cwd: String? = "/tmp/project",
    updatedAt: Date? = Date(),
    running: Bool = false
  ) -> SessionSummary {
    SessionSummary(id: SessionID(id), title: title, cwd: cwd, updatedAt: updatedAt, isLive: running)
  }

  func testListNumbersRowsAndMarksTheBoundOne() {
    let sessions = [
      summary("session-aaaaaaaa-1", title: "修 bug", running: true),
      summary("session-bbbbbbbb-2", title: "写文档"),
    ]
    let text = ChatReply.sessionList(sessions, boundID: "session-bbbbbbbb-2")

    XCTAssertTrue(text.contains("1. "), text)
    XCTAssertTrue(text.contains("2. ● "), text)
    // The running marker belongs to the first row only.
    XCTAssertTrue(text.contains("1.  ▶"), text)
    XCTAssertTrue(text.contains("修 bug"), text)
    XCTAssertTrue(text.contains("aaaaaaaa"), text)
    XCTAssertTrue(text.contains("/use 1"), text)
  }

  /// A session with no title still has to be choosable.
  func testListFallsBackToTheDirectoryName() {
    let text = ChatReply.sessionList(
      [summary("session-cccccccc-3", title: nil, cwd: "/tmp/my-project")], boundID: nil
    )
    XCTAssertTrue(text.contains("my-project"), text)
  }

  func testEmptyListSaysHowToMakeOne() {
    XCTAssertTrue(ChatReply.sessionList([], boundID: nil).contains("还没有任何会话"))
  }

  func testShortIDStripsTheProtocolPrefix() {
    XCTAssertEqual(ChatReply.shortID("session-1a2b3c4d-5e6f"), "1a2b3c4d")
    XCTAssertEqual(ChatReply.shortID("1a2b"), "1a2b")
  }

  func testRelativeTime() {
    let now = Date()
    XCTAssertEqual(ChatReply.relative(now, now: now), "刚刚")
    XCTAssertEqual(ChatReply.relative(now.addingTimeInterval(-120), now: now), "2分钟前")
    XCTAssertEqual(ChatReply.relative(now.addingTimeInterval(-7200), now: now), "2小时前")
    XCTAssertEqual(ChatReply.relative(now.addingTimeInterval(-172_800), now: now), "2天前")
    XCTAssertEqual(ChatReply.relative(nil), "未知时间")
  }

  // MARK: - Workspaces

  private func workspace(
    _ id: String,
    path: String,
    title: String,
    reachable: Bool = true
  ) -> HarnessWorkspace {
    HarnessWorkspace(id: id, path: path, title: title, isReachable: reachable)
  }

  func testWorkspaceListMarksCurrentAndUnreachable() {
    let text = ChatReply.workspaceList(
      [
        workspace("bda58903-facd", path: "/Users/project/my-project", title: "my-project"),
        workspace("47a02c72-442d", path: "/Users/project/gone", title: "gone", reachable: false),
      ],
      current: "/Users/project/my-project"
    )

    XCTAssertTrue(text.contains("1. ● my-project"), text)
    XCTAssertTrue(text.contains("2.   gone"), text)
    XCTAssertTrue(text.contains("（目录不存在）"), text)
    XCTAssertTrue(text.contains("● = 当前工作区"), text)
    XCTAssertTrue(text.contains("/workspace 1 切换"), text)
  }

  /// The numbers belong to the whole listing even when the phone only sees the head of it.
  func testWorkspaceListTruncatesButKeepsNumbering() {
    let many = (1...18).map { workspace("id-\($0)", path: "/tmp/ws-\($0)", title: "ws-\($0)") }
    let text = ChatReply.workspaceList(many, current: "/tmp/ws-1")

    XCTAssertTrue(text.contains("只显示了最近 15 个，共 18 个。"), text)
    XCTAssertFalse(text.contains("16. "), text)
  }

  func testEmptyWorkspaceListExplainsThePathForm() {
    let text = ChatReply.workspaceList([], current: nil)
    XCTAssertTrue(text.contains("还没有任何工作区"), text)
    XCTAssertTrue(text.contains("/workspace /绝对/路径"), text)
  }

  func testWorkspaceSwitchedNamesTheFolderAndTheRegistration() {
    let picked = workspace("bda58903-facd-4faa", path: "/tmp/ws", title: "ws")

    let registered = ChatReply.workspaceSwitched(picked, registration: .registered("bda58903-facd"))
    XCTAssertTrue(registered.contains("已切换工作区：ws"), registered)
    XCTAssertTrue(registered.contains("bda58903"), registered)
    XCTAssertTrue(registered.contains("本对话已解绑旧会话"), registered)

    XCTAssertTrue(
      ChatReply.workspaceSwitched(picked, registration: .unsupported).contains("不支持登记工作区")
    )
    XCTAssertTrue(
      ChatReply.workspaceSwitched(picked, registration: .pending).contains("自动登记")
    )
  }

  func testWorkspaceFailuresSayWhatToDoNext() {
    let notFound = ChatReply.workspaceNotFound("9")
    XCTAssertTrue(notFound.contains("没有找到工作区「9」"), notFound)
    XCTAssertTrue(notFound.contains("/workspace 看编号"), notFound)
    XCTAssertTrue(ChatReply.workspaceFolderMissing("/tmp/gone").contains("/tmp/gone"))
    XCTAssertTrue(ChatReply.workspaceListingUnavailable().contains("/绝对/路径"))
    XCTAssertTrue(
      ChatReply.alreadyInWorkspace(workspace("i", path: "/tmp/ws", title: "ws"))
        .contains("已经在这个工作区")
    )
  }
}

// MARK: - Questions

final class QuestionDecodingTests: XCTestCase {
  private func request(_ json: String) throws -> JSONValue {
    try JSONValue.parse(json)
  }

  func testDecodesOptionsAndThePlanReviewIntent() throws {
    let question = try XCTUnwrap(QuestionPrompt.decode(
      try request(#"""
      {"questions":[
        {"id":"q1","header":"计划","question":"执行这个计划吗？","detail":"第一步……",
         "options":[{"label":"开始执行"},{"label":"继续修改"}],
         "intent":{"kind":"plan-review","approve":"开始执行"}}
      ]}
      """#),
      eventID: "evt-1", sessionID: "session-x", isBorrowed: true
    ))

    XCTAssertEqual(question.eventID, "evt-1")
    XCTAssertEqual(question.items.count, 1)
    let item = question.items[0]
    XCTAssertEqual(item.id, "q1")
    XCTAssertEqual(item.header, "计划")
    XCTAssertEqual(item.options, ["开始执行", "继续修改"])
    XCTAssertEqual(item.approveLabel, "开始执行")
    XCTAssertFalse(item.multiSelect)
    XCTAssertTrue(question.isBorrowed)
  }

  /// An entry we cannot address or show must not make the whole payload unanswerable.
  func testDropsEntriesWithoutAnIdOrQuestion() throws {
    let question = QuestionPrompt.decode(
      try request(#"{"questions":[{"question":"没有 id"},{"id":"q2","question":""},{"id":"q3","question":"好的？"}]}"#),
      eventID: "e", sessionID: "s", isBorrowed: false
    )
    XCTAssertEqual(question?.items.map(\.id), ["q3"])
  }

  func testAnEmptyRequestIsNotForwarded() throws {
    XCTAssertNil(QuestionPrompt.decode(
      try request(#"{"questions":[]}"#), eventID: "e", sessionID: "s", isBorrowed: false
    ))
  }

  func testPromptTextTeachesTheGrammar() {
    let question = PendingQuestion(eventID: "e", sessionID: "session-12345678", isBorrowed: true, items: [
      QuestionItem(id: "q1", question: "选一个", options: ["甲", "乙"], multiSelect: false),
    ])
    let text = QuestionPrompt.text(for: question)
    XCTAssertTrue(text.contains("需要你回答"), text)
    XCTAssertTrue(text.contains("来自桌面会话 session-"), text)
    XCTAssertTrue(text.contains("1) 甲"), text)
    XCTAssertTrue(text.contains("/answer 1"), text)
  }
}

final class QuestionAnswerParserTests: XCTestCase {
  private func single(options: [String], multiSelect: Bool = false) -> PendingQuestion {
    PendingQuestion(eventID: "e", sessionID: "s", isBorrowed: false, items: [
      QuestionItem(id: "q1", question: "选一个", options: options, multiSelect: multiSelect),
    ])
  }

  private func selected(_ value: JSONValue) -> [String] {
    (value["answers"]?.arrayValue?.first?["selected"]?.arrayValue ?? []).compactMap(\.stringValue)
  }

  func testSelectsByOneBasedIndex() throws {
    let outcome = QuestionAnswerParser.parse("2", for: single(options: ["甲", "乙", "丙"]))
    guard case .answers(let value) = outcome else { return XCTFail("expected answers, got \(outcome)") }
    XCTAssertEqual(selected(value), ["乙"])
  }

  /// The label is accepted too: it is what the user copies from the question.
  func testSelectsByExactLabel() throws {
    let outcome = QuestionAnswerParser.parse("丙", for: single(options: ["甲", "乙", "丙"]))
    guard case .answers(let value) = outcome else { return XCTFail("expected answers") }
    XCTAssertEqual(selected(value), ["丙"])
  }

  func testMultiSelectTakesCommaSeparatedIndices() throws {
    let outcome = QuestionAnswerParser.parse("1,3", for: single(options: ["甲", "乙", "丙"], multiSelect: true))
    guard case .answers(let value) = outcome else { return XCTFail("expected answers") }
    XCTAssertEqual(selected(value), ["甲", "丙"])
  }

  /// A single-select question must not silently take the first of two picks.
  func testRejectsTwoIndicesForASingleSelectQuestion() {
    guard case .problem(let message) = QuestionAnswerParser.parse("1,2", for: single(options: ["甲", "乙"])) else {
      return XCTFail("expected a problem")
    }
    XCTAssertTrue(message.contains("只能选一个"), message)
  }

  func testOutOfRangeIndexNamesTheOptions() {
    guard case .problem(let message) = QuestionAnswerParser.parse("9", for: single(options: ["甲", "乙"])) else {
      return XCTFail("expected a problem")
    }
    XCTAssertTrue(message.contains("1) 甲"), message)
    XCTAssertTrue(message.contains("2) 乙"), message)
  }

  func testFreeTextBecomesTheCustomAnswer() throws {
    let question = PendingQuestion(eventID: "e", sessionID: "s", isBorrowed: false, items: [
      QuestionItem(id: "q1", question: "叫什么名字？", options: []),
    ])
    let outcome = QuestionAnswerParser.parse("阿黄", for: question)
    guard case .answers(let value) = outcome else { return XCTFail("expected answers") }
    let answer = value["answers"]?.arrayValue?.first
    XCTAssertEqual(answer?["custom"]?.stringValue, "阿黄")
    XCTAssertEqual(answer?["selected"]?.arrayValue?.count, 0)
  }

  func testSkipIsRepresentable() throws {
    let outcome = QuestionAnswerParser.parse("-", for: single(options: ["甲"]))
    guard case .answers(let value) = outcome else { return XCTFail("expected answers") }
    XCTAssertEqual(selected(value), [])
  }

  func testMultipleQuestionsAreAnsweredPositionally() throws {
    let question = PendingQuestion(eventID: "e", sessionID: "s", isBorrowed: false, items: [
      QuestionItem(id: "q1", question: "一", options: ["甲", "乙"]),
      QuestionItem(id: "q2", question: "二", options: ["丙", "丁"]),
    ])
    let outcome = QuestionAnswerParser.parse("2 | 1", for: question)
    guard case .answers(let value) = outcome else { return XCTFail("expected answers") }
    let answers = value["answers"]?.arrayValue ?? []
    XCTAssertEqual(answers.count, 2)
    XCTAssertEqual(answers[0]["id"]?.stringValue, "q1")
    XCTAssertEqual((answers[0]["selected"]?.arrayValue ?? []).compactMap(\.stringValue), ["乙"])
    XCTAssertEqual(answers[1]["id"]?.stringValue, "q2")
    XCTAssertEqual((answers[1]["selected"]?.arrayValue ?? []).compactMap(\.stringValue), ["丙"])
  }

  /// Too few segments must not silently answer only the first question.
  func testWrongSegmentCountIsRejected() {
    let question = PendingQuestion(eventID: "e", sessionID: "s", isBorrowed: false, items: [
      QuestionItem(id: "q1", question: "一", options: ["甲"]),
      QuestionItem(id: "q2", question: "二", options: ["乙"]),
    ])
    guard case .problem(let message) = QuestionAnswerParser.parse("1", for: question) else {
      return XCTFail("expected a problem")
    }
    XCTAssertTrue(message.contains("按题号"), message)
  }
}

// MARK: - History

final class RemoteSessionHistoryTests: XCTestCase {
  private func fixtureEvents() throws -> [SessionEvent] {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "recorded-session.v3", withExtension: "jsonl.zstd", subdirectory: "Fixtures"),
      "recorded session fixture is missing from the test bundle"
    )
    return try SessionLogReader(url: url).readEvents()
  }

  /// The pair rule against a real log: one user turn, the assistant text that answered it.
  func testPairsATurnWithItsAnswer() throws {
    let turns = RemoteSessionHistory.turns(in: try fixtureEvents())
    XCTAssertEqual(turns.count, 1)
    XCTAssertEqual(turns[0].assistant, "收到")
    XCTAssertFalse(turns[0].user.isEmpty)
    XCTAssertFalse(turns[0].isRunning)
  }

  /// A partial log has no `turn/end`, and the phone should see that the turn is still going.
  func testMarksATurnWithoutAnEndAsRunning() throws {
    let truncated = try fixtureEvents().prefix { $0.kind != .turnEnd }
    let turns = RemoteSessionHistory.turns(in: Array(truncated))
    XCTAssertEqual(turns.count, 1)
    XCTAssertTrue(turns[0].isRunning)
  }

  func testRenderClipsBothSidesAndKeepsTheNewestTurns() {
    let turns = [
      RemoteSessionHistory.Turn(user: String(repeating: "旧", count: 400), assistant: "旧答", isRunning: false),
      RemoteSessionHistory.Turn(user: "新", assistant: String(repeating: "长", count: 400), isRunning: false),
    ]
    let text = RemoteSessionHistory.render(turns: turns, limit: 1, maxCharacters: 400)
    XCTAssertTrue(text.contains("新"), text)
    XCTAssertFalse(text.contains("旧"), "only the last turn was requested")
    XCTAssertTrue(text.contains("…"), text)
  }

  func testRenderSaysWhenThereIsNothing() {
    XCTAssertTrue(
      RemoteSessionHistory.render(turns: [], limit: 5, maxCharacters: 500).contains("还没有对话记录")
    )
  }

  private func home() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-history-\(UUID().uuidString)", isDirectory: true)
  }

  /// The whole read path, through the harness's own directory layout.
  func testLocatorReadsTheLogThroughItsRealPath() throws {
    let dshHome = home()
    defer { try? FileManager.default.removeItem(at: dshHome) }
    let cwd = "/tmp/dsh-imtest-ws"
    let sessionID = "session-2fa88c3f-515c-4170-b656-ba39887000fc"

    let directory = try SessionPaths.sessionDirectory(dshHome: dshHome, cwd: cwd, sessionID: sessionID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = try XCTUnwrap(Bundle.module.url(
      forResource: "recorded-session.v3", withExtension: "jsonl.zstd", subdirectory: "Fixtures"
    ))
    try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("session.v3.jsonl.zstd"))

    let events = try XCTUnwrap(SessionLogLocator(dshHome: dshHome).events(cwd: cwd, sessionID: sessionID))
    XCTAssertEqual(RemoteSessionHistory.turns(in: events).first?.assistant, "收到")
  }

  func testLocatorReturnsNilForAnUnknownSession() {
    let dshHome = home()
    defer { try? FileManager.default.removeItem(at: dshHome) }
    XCTAssertNil(SessionLogLocator(dshHome: dshHome).events(cwd: "/tmp/nope", sessionID: "session-missing"))
  }
}

// MARK: - Session list payload

final class SessionListDecodingTests: XCTestCase {
  func testDecodesTheListPayload() throws {
    let value = try JSONValue.parse(#"""
    {"items":[
      {"sessionId":"session-1a2b3c4d","updatedAt":1700000000000,"running":true,"blank":false,
       "cwd":"/Users/x/proj","projections":{"asOfSeq":3,"values":{"title":"修 bug"}}},
      {"sessionId":"session-5e6f7a8b","updatedAt":1700000600,"running":false,"blank":true,
       "projections":{"asOfSeq":0,"values":{"title":null}}}
    ]}
    """#)

    let sessions = HarnessAPIClient.sessionSummaries(from: value)
    XCTAssertEqual(sessions.count, 2)
    XCTAssertEqual(sessions[0].id.rawValue, "session-1a2b3c4d")
    XCTAssertEqual(sessions[0].title, "修 bug")
    XCTAssertEqual(sessions[0].cwd, "/Users/x/proj")
    XCTAssertTrue(sessions[0].isLive)
    XCTAssertNil(sessions[1].title)
  }

  /// Epoch milliseconds are the wire's unit; a seconds-based payload must not land in 1970.
  func testEpochUnitsAreDetectedByMagnitude() {
    let millis = try? XCTUnwrap(HarnessAPIClient.epochDate(1_700_000_000_000))
    XCTAssertEqual(millis?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.5)

    let seconds = try? XCTUnwrap(HarnessAPIClient.epochDate(1_700_000_000))
    XCTAssertEqual(seconds?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.5)

    XCTAssertNil(HarnessAPIClient.epochDate(nil))
    XCTAssertNil(HarnessAPIClient.epochDate(0))
  }

  func testRowsWithoutAnIDAreDropped() throws {
    let value = try JSONValue.parse(#"{"items":[{"updatedAt":1},{"sessionId":"session-ok"}]}"#)
    XCTAssertEqual(HarnessAPIClient.sessionSummaries(from: value).map(\.id.rawValue), ["session-ok"])
  }
}

// MARK: - Binding resolution

final class SessionBindingResolutionTests: XCTestCase {
  private func summary(_ id: String) -> SessionSummary {
    SessionSummary(id: SessionID(id), cwd: "/tmp/x")
  }

  /// The dangerous case: rows reorder by activity, so an index must resolve against what the
  /// user was shown, not against a list fetched a moment later.
  func testIndexPrefersTheShownListing() {
    let shown = [summary("session-shown-1"), summary("session-shown-2")]
    let fresh = [summary("session-new-9"), summary("session-shown-1"), summary("session-shown-2")]

    XCTAssertEqual(WeChatChannelService.resolve(target: "1", shown: shown, fresh: fresh)?.id.rawValue,
                   "session-shown-1")
    XCTAssertEqual(WeChatChannelService.resolve(target: "2", shown: shown, fresh: fresh)?.id.rawValue,
                   "session-shown-2")
  }

  func testIndexFallsBackToAFreshListing() {
    XCTAssertEqual(
      WeChatChannelService.resolve(target: "2", shown: nil, fresh: [summary("a"), summary("b")])?.id.rawValue,
      "b"
    )
    XCTAssertNil(WeChatChannelService.resolve(target: "9", shown: nil, fresh: [summary("a")]))
  }

  func testResolvesByFullIDOrPrefix() {
    let fresh = [summary("session-1a2b3c4d-5e6f")]
    XCTAssertEqual(WeChatChannelService.resolve(target: "session-1a2b3c4d-5e6f", shown: nil, fresh: fresh)?.id.rawValue,
                   "session-1a2b3c4d-5e6f")
    XCTAssertEqual(WeChatChannelService.resolve(target: "1a2b3c", shown: nil, fresh: fresh)?.id.rawValue,
                   "session-1a2b3c4d-5e6f")
    XCTAssertNil(WeChatChannelService.resolve(target: "zzzz", shown: nil, fresh: fresh))
  }
}

// MARK: - State migration

final class ChannelPersistedStateMigrationTests: XCTestCase {
  private func store() -> ChannelStateStore {
    ChannelStateStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-state-\(UUID().uuidString)", isDirectory: true))
  }

  /// A file written before a field existed must keep everything it does carry.
  ///
  /// `loadState` answers a decode failure by starting from empty, so a stricter decoder would
  /// silently discard every session binding the user had.
  func testLoadsAFileWrittenBeforeAdoptedSessionsExisted() throws {
    let store = store()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let legacy = #"""
    {"getUpdatesBuffer":"buf","seenMessageIDs":["m1"],
     "sessions":{"owner@im.wechat":"session-keep"},
     "contextTokens":{"owner@im.wechat":"ctx"},"batches":{},"lastError":null}
    """#
    try Data(legacy.utf8).write(to: store.stateURL)

    let state = store.loadState()
    XCTAssertNil(state.lastError, "the file must decode, not be discarded")
    XCTAssertEqual(state.sessions["owner@im.wechat"], "session-keep")
    XCTAssertEqual(state.contextTokens["owner@im.wechat"], "ctx")
    XCTAssertEqual(state.getUpdatesBuffer, "buf")
    XCTAssertTrue(state.adoptedSessions.isEmpty)
  }

  func testRoundTripsAdoptedSessions() throws {
    let store = store()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    var state = ChannelPersistedState()
    state.sessions["owner@im.wechat"] = "session-abc"
    state.adoptedSessions["owner@im.wechat"] = AdoptedSession(
      sessionID: "session-abc", cwd: "/tmp/proj", title: "修 bug"
    )
    try store.save(state: state)

    let loaded = store.loadState()
    XCTAssertEqual(loaded.adoptedSessions["owner@im.wechat"]?.cwd, "/tmp/proj")
    XCTAssertEqual(loaded.adoptedSessions["owner@im.wechat"]?.title, "修 bug")
  }
}
