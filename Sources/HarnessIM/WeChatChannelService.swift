import Foundation
import HarnessKit

/// What the channel window renders.
public struct ChannelStatus: Sendable, Equatable {
  public enum Phase: String, Sendable {
    case stopped
    case loggingIn
    case connecting
    case online
    /// Running, but something is missing (harness down, capability lost, …).
    case degraded
    case needsLogin
  }

  public var phase: Phase
  public var botID: String?
  public var ownerUserID: String?
  /// QR content during login, for the window to render.
  public var loginQRContent: String?
  public var loginExpiresAt: Date?
  public var loginNeedsVerifyCode: Bool
  public var detail: String?
  public var lastError: String?
  public var capabilities: HarnessCapabilities?
  /// Buffered batches keyed by sender, for the preview list.
  public var batches: [String: BatchSnapshot]
  public var lastReplyAt: Date?
  /// Whether approvals from *every* session — desktop ones included — are routed to the phone.
  /// In-memory on purpose: it is a decision about this run, not a setting that should survive
  /// a restart and quietly reroute approvals the user is no longer watching for.
  public var forwardsAllPrompts: Bool
  /// Questions the phone is still holding an answer for, across every address.
  public var pendingPrompts: Int

  public init(
    phase: Phase = .stopped,
    botID: String? = nil,
    ownerUserID: String? = nil,
    loginQRContent: String? = nil,
    loginExpiresAt: Date? = nil,
    loginNeedsVerifyCode: Bool = false,
    detail: String? = nil,
    lastError: String? = nil,
    capabilities: HarnessCapabilities? = nil,
    batches: [String: BatchSnapshot] = [:],
    lastReplyAt: Date? = nil,
    forwardsAllPrompts: Bool = false,
    pendingPrompts: Int = 0
  ) {
    self.phase = phase
    self.botID = botID
    self.ownerUserID = ownerUserID
    self.loginQRContent = loginQRContent
    self.loginExpiresAt = loginExpiresAt
    self.loginNeedsVerifyCode = loginNeedsVerifyCode
    self.detail = detail
    self.lastError = lastError
    self.capabilities = capabilities
    self.batches = batches
    self.lastReplyAt = lastReplyAt
    self.forwardsAllPrompts = forwardsAllPrompts
    self.pendingPrompts = pendingPrompts
  }

  public var canSubmit: Bool { phase == .online || phase == .degraded }
}

/// The app-owned WeChat channel.
///
/// Everything the feature rests on lives here: the provider loop, the per-conversation
/// buffers, the trigger rule, and the hand-off to a **running** harness. It never installs,
/// patches, restarts, or writes inside the harness home — if the harness is down the channel
/// degrades and says so, and harness behaviour is unchanged either way.
public actor WeChatChannelService {
  /// How the service reaches the harness the app is already running.
  public typealias HarnessURLProvider = @Sendable () async -> URL?
  /// Where the harness keeps its session logs (read-only use).
  public typealias DSHHomeProvider = @Sendable () -> URL?
  /// HTTP seam for the harness host, so the whole submission path can be driven offline.
  public typealias HarnessTransportFactory = @Sendable () -> HarnessAPITransport
  /// Reply seam: production reads the session log, tests answer from a script.
  public typealias ReplySourceFactory = @Sendable (URL, String, String) -> any SessionReplyProducing
  /// Approval-stream seam: production opens the host's WebSocket event stream, tests script it.
  public typealias ApprovalStreamFactory = @Sendable (HarnessAPIClient) async throws -> any RemoteEventStreaming

  private let store: ChannelStateStore
  private let harnessURL: HarnessURLProvider
  private let dshHome: DSHHomeProvider
  private let client: ILinkClient
  private let replyConfiguration: SessionReplySource.Configuration
  private let makeHarnessTransport: HarnessTransportFactory
  private let replySourceFactory: ReplySourceFactory
  private let approvalStreamFactory: ApprovalStreamFactory
  /// The one transport this channel talks to the harness through.
  ///
  /// The factory used to be called per operation, so every `/list`, submission and repair pass
  /// built its own `URLSession`. A session keeps its connections — and their descriptors — until
  /// it is invalidated, and none of them were: two hours of use left ~4 800 dead sockets in the
  /// process, after which even writing `state.json` failed with a bare Cocoa 512 (the write needs
  /// a descriptor too) and the harness looked unreachable because `open()` answered `EMFILE`.
  private var sharedHarnessTransport: HarnessAPITransport?
  private var promptRelay: PromptRelay?
  /// Whether all sessions' approvals go to the phone. Never persisted: see `ChannelStatus`.
  private var forwardsAllPrompts = false

  private var config: ChannelConfig
  private var state: ChannelPersistedState
  /// The bound bot, or nil when the channel still needs a QR scan. Owned as a single value
  /// so "is the channel bound?" has exactly one answer.
  private var credential: ChannelCredential?
  private var buffers: [String: InboundBatchBuffer] = [:]
  /// WeChat sender → the listing it was last shown by `/list`.
  ///
  /// Kept so `/use 3` binds the row the user actually read. Re-fetching would be simpler and
  /// wrong: a session that finished a turn in between moves to the top, and the phone would
  /// silently take over a different conversation. In-memory on purpose — a stale list after a
  /// restart is exactly the mis-binding this is here to prevent.
  private var listings: [String: [SessionSummary]] = [:]
  /// WeChat sender → the workspace listing it was last shown by `/workspace`.
  ///
  /// Same reasoning as `listings`: rows are ordered by activity, so resolving `/workspace 3`
  /// against a fresh read could move the channel to a folder the user never saw. In-memory on
  /// purpose — a stale list after a restart is exactly the mis-switch this is here to prevent.
  private var workspaceListings: [String: [HarnessWorkspace]] = [:]
  /// WeChat sender → the model rows it was last shown by `/model`.
  ///
  /// Same reasoning again: `/model 2` must mean the second row the user read, not the second row
  /// of a catalog that a provider enumerated differently a moment later.
  private var modelListings: [String: [HarnessModelChoice]] = [:]
  /// WeChat sender → what it was last shown by `/effort`, as (the model those tiers belong to,
  /// the tiers). Kept per sender for the same reason as `modelListings`.
  private var effortListings: [String: (choice: HarnessModelChoice, efforts: [HarnessModelEffort])] = [:]
  /// WeChat sender → the model/effort it asked for, kept so a session created *later* still starts
  /// on it.
  ///
  /// A selection lives on a session, so a `/model` typed before the first message has nothing to
  /// attach to. Remembering it here is what makes "先选模型，再开会话" work; in-memory on purpose,
  /// because the harness itself is the durable record for every session that exists.
  private var preferredSelections: [String: HarnessModelSelection] = [:]
  /// Downloaded attachment bytes, keyed by batch item, so a batch survives the wait between
  /// "file received" and "trigger phrase received".
  private var attachmentData: [String: Data] = [:]

  private var loopTask: Task<Void, Never>?
  private var loginTask: Task<Void, Never>?
  private var deliveries: [String: Task<Void, Never>] = [:]
  private var status: ChannelStatus
  private var statusHandler: (@Sendable (ChannelStatus) -> Void)?

  /// Backoff for the provider loop: a broken network must not turn into a busy loop.
  private var backoff: TimeInterval = 1
  private static let maximumBackoff: TimeInterval = 60

  public init(
    appRoot: URL,
    harnessURL: @escaping HarnessURLProvider,
    dshHome: @escaping DSHHomeProvider,
    client: ILinkClient = ILinkClient(),
    replyConfiguration: SessionReplySource.Configuration = .init(),
    harnessTransport: @escaping HarnessTransportFactory = { URLSessionHarnessTransport() },
    replySourceFactory: @escaping ReplySourceFactory = { home, cwd, sessionID in
      SessionReplySource(dshHome: home, cwd: cwd, sessionID: sessionID, client: nil)
    },
    approvalStreamFactory: @escaping ApprovalStreamFactory = { client in
      try await client.makeRemoteEventStream()
    }
  ) {
    self.store = ChannelStateStore.standard(appRoot: appRoot)
    self.harnessURL = harnessURL
    self.dshHome = dshHome
    self.client = client
    self.replyConfiguration = replyConfiguration
    self.makeHarnessTransport = harnessTransport
    self.replySourceFactory = replySourceFactory
    self.approvalStreamFactory = approvalStreamFactory
    self.config = Self.canonicalized(store.loadConfig())
    self.state = store.loadState()
    let storedCredential = store.loadCredential()
    self.credential = storedCredential
    self.status = ChannelStatus(
      phase: storedCredential == nil ? .stopped : .connecting,
      botID: storedCredential?.botID,
      ownerUserID: storedCredential?.ownerUserID,
      lastError: state.lastError
    )
  }

  // MARK: - Observation

  public func setStatusHandler(_ handler: (@Sendable (ChannelStatus) -> Void)?) {
    statusHandler = handler
    handler?(status)
  }

  public func currentStatus() -> ChannelStatus { status }

  public func currentConfig() -> ChannelConfig { config }

  private func publish(_ mutate: (inout ChannelStatus) -> Void) {
    mutate(&status)
    status.batches = buffers.mapValues(\.snapshot)
    statusHandler?(status)
  }

  // MARK: - Lifecycle

  /// Start syncing. Safe to call repeatedly; a live loop is left alone.
  public func start() {
    guard loopTask == nil else { return }
    guard let credential else {
      publish { $0.phase = .needsLogin; $0.detail = "尚未绑定微信机器人" }
      return
    }
    publish { $0.phase = .connecting; $0.botID = credential.botID; $0.ownerUserID = credential.ownerUserID }
    loopTask = Task { [weak self] in
      await self?.runLoop()
    }
    // Repair pass: sessions recorded before the channel registered a workspace would otherwise
    // stay invisible in the harness GUI forever. The harness may still be starting, so this is
    // attempted in the background and retried on each configuration change.
    Task { [weak self] in
      for attempt in 0..<6 {
        guard let self else { return }
        if await self.harnessURL() != nil {
          await self.attachStoredSessions()
          return
        }
        try? await Task.sleep(for: .seconds(5 + Double(attempt) * 5))
      }
    }
  }

  public func stop() {
    loopTask?.cancel()
    loopTask = nil
    loginTask?.cancel()
    loginTask = nil
    for task in deliveries.values { task.cancel() }
    deliveries.removeAll()
    let relay = promptRelay
    promptRelay = nil
    Task { await relay?.stop() }
    let credential = self.credential
    Task { [client] in
      guard let credential else { return }
      // Best effort: going away quietly keeps the provider from holding the account busy.
      try? await client.notifyStop(token: credential.token, baseURL: credential.baseURL)
    }
    publish { $0.phase = .stopped; $0.detail = nil; $0.pendingPrompts = 0 }
  }

  /// Drop whatever one conversation has buffered, reporting how many messages went away.
  ///
  /// Exposed so the channel window can clear a batch the user decided against without
  /// waiting for the cancel phrase.
  @discardableResult
  public func clearBatch(sender: String) -> Int {
    let dropped = buffer(for: sender).cancel()
    persistBuffers()
    publish { _ in }
    return dropped
  }

  public func update(config newConfig: ChannelConfig) {
    let normalized = Self.canonicalized(newConfig)
    let workspaceChanged = normalized.workspacePath != config.workspacePath
    config = normalized
    // A workspace the user changed by hand must be re-resolved, not trusted from the old path.
    if workspaceChanged { config.workspaceID = normalized.workspaceID }
    for buffer in buffers.values { buffer.updateConfig(newConfig) }
    try? store.save(config: config)
    publish { _ in }
    // Registering a freshly chosen folder is what makes its sessions appear in the sidebar, so
    // do it as soon as the choice is saved rather than waiting for the next WeChat batch.
    Task { [weak self] in await self?.attachStoredSessions() }
  }

  public func disconnect() {
    stop()
    credential = nil
    // There is no phone to answer from without a bound bot, so the switch cannot stay on.
    forwardsAllPrompts = false
    store.clearCredential()
    publish {
      $0.phase = .needsLogin
      $0.botID = nil
      $0.ownerUserID = nil
      $0.detail = nil
      $0.forwardsAllPrompts = false
      $0.pendingPrompts = 0
    }
  }

  // MARK: - Login

  /// Begin a QR login. The window renders `status.loginQRContent` and polls the status.
  public func beginLogin() {
    loginTask?.cancel()
    publish {
      $0.phase = .loggingIn
      $0.loginNeedsVerifyCode = false
      $0.lastError = nil
      $0.detail = "二维码已生成，请用微信扫码"
    }
    loginTask = Task { [weak self] in
      await self?.runLogin()
    }
  }

  public func cancelLogin() {
    loginTask?.cancel()
    loginTask = nil
    publish { $0.phase = self.credential == nil ? .needsLogin : .stopped; $0.loginQRContent = nil }
  }

  /// Answer the provider's pairing-code challenge when it asks for one.
  public func submitVerificationCode(_ code: String) async {
    guard let attempt = loginAttempt else { return }
    attempt.verifyCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
    attempt.verifyContinuation?.resume()
  }

  private final class LoginAttempt: @unchecked Sendable {
    var verifyCode: String?
    var verifyContinuation: CheckedContinuation<Void, Never>?
    var qrcode: String = ""
  }

  private var loginAttempt: LoginAttempt?

  private func runLogin() async {
    let attempt = LoginAttempt()
    loginAttempt = attempt
    do {
      let qr = try await client.beginLogin()
      attempt.qrcode = qr.code
      publish {
        $0.loginQRContent = qr.content.isEmpty ? qr.code : qr.content
        $0.loginExpiresAt = Date().addingTimeInterval(300)
      }
    } catch {
      failLogin(error)
      return
    }

    let deadline = Date().addingTimeInterval(300)
    while !Task.isCancelled, Date() < deadline {
      // A pairing code is asked for interactively: park until the window supplies one.
      if attempt.verifyCode == nil, status.loginNeedsVerifyCode {
        await withCheckedContinuation { continuation in
          attempt.verifyContinuation = continuation
        }
        attempt.verifyContinuation = nil
      }
      do {
        let result = try await client.pollLogin(qrcode: attempt.qrcode, verifyCode: attempt.verifyCode)
        switch result.status {
        case .confirmed:
          guard let token = result.token, let botID = result.botID, let owner = result.ownerUserID else {
            failLogin(ILinkError(.invalidResponse, "微信授权成功，但返回的账号凭据不完整"))
            return
          }
          let credential = ChannelCredential(
            botID: botID,
            accountID: botID,
            ownerUserID: owner,
            token: token,
            baseURL: result.baseURL ?? ILinkProtocol.qrBaseURL
          )
          self.credential = credential
          persistCredential()
          publish {
            $0.phase = .connecting
            $0.loginQRContent = nil
            $0.loginExpiresAt = nil
            $0.botID = botID
            $0.ownerUserID = owner
            $0.detail = "已绑定，正在连接"
          }
          loginAttempt = nil
          start()
          return
        case .expired, .verifyCodeBlocked:
          failLogin(ILinkError(.invalidLoginStatus, result.status == .expired ? "二维码已过期，请重新生成" : "配对码多次错误，请重新生成二维码"))
          return
        case .needVerifyCode:
          attempt.verifyCode = nil
          publish { $0.loginNeedsVerifyCode = true; $0.detail = "请输入微信提示的配对码" }
        case .unknown(let raw):
          failLogin(ILinkError(.invalidLoginStatus, "微信服务返回了无法识别的扫码状态：\(raw)"))
          return
        default:
          break
        }
      } catch {
        failLogin(error)
        return
      }
      try? await Task.sleep(for: .seconds(1))
    }
    if !Task.isCancelled {
      failLogin(ILinkError(.timeout, "二维码已超时，请重新生成"))
    }
  }

  private func failLogin(_ error: Error) {
    let message = (error as? ILinkError)?.message ?? String(describing: error)
    loginAttempt = nil
    state.lastError = message
    persist()
    publish {
      $0.phase = self.credential == nil ? .needsLogin : .stopped
      $0.loginQRContent = nil
      $0.lastError = message
    }
  }

  // MARK: - Sync loop

  private func runLoop() async {
    while !Task.isCancelled {
      guard let credential else { return }
      do {
        try await client.notifyStart(token: credential.token, baseURL: credential.baseURL)
        backoff = 1
        publish { $0.phase = .online; $0.detail = "已连接"; $0.lastError = nil }

        while !Task.isCancelled {
          let updates = try await client.getUpdates(
            token: credential.token,
            baseURL: credential.baseURL,
            buffer: state.getUpdatesBuffer
          )
          if updates.buffer != state.getUpdatesBuffer {
            state.getUpdatesBuffer = updates.buffer
            persist()
          }
          for raw in updates.messages {
            await handle(raw)
          }
        }
      } catch is CancellationError {
        return
      } catch {
        let failure = error as? ILinkError
        let message = failure?.message ?? String(describing: error)
        state.lastError = message
        // An expired session is the one rejection a re-bind can fix. A refused *request* (a
        // wrong parameter, say) is not: treating every non-zero `ret` as terminal is what
        // stopped the poll for good and told the user to re-bind a perfectly healthy channel.
        let terminal = failure?.code == .sessionExpired
        if terminal {
          // Protocol rule: the cached conversation tokens belong to the session that ended.
          state.contextTokens.removeAll()
        }
        persist()
        publish {
          $0.phase = terminal ? .needsLogin : .degraded
          $0.lastError = message
        }
        if terminal { return }
        try? await Task.sleep(for: .seconds(backoff))
        backoff = min(backoff * 2, Self.maximumBackoff)
      }
    }
  }

  // MARK: - Inbound handling

  private func handle(_ raw: JSONValue) async {
    guard let message = WeChatMessageParser.parse(raw) else { return }
    // The sync stream echoes this bot's own replies; answering them would loop.
    guard !message.isOutbound else { return }
    guard !state.hasSeen(message.messageID) else { return }
    guard config.allowsSender(message.sender, owner: credential?.ownerUserID) else { return }

    state.remember(messageID: message.messageID)
    if let token = message.contextToken, !token.isEmpty {
      state.contextTokens[message.sender] = token
    }
    persist()

    // Commands the channel owns, independent of the buffer. Everything starting with `/` is
    // decided here and never reaches a session as content: on a phone the difference between
    // "run /list" and "send /list to the model" is exactly the difference between working and
    // embarrassing.
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let line = ChatCommandParser.parse(trimmed) {
      await run(line, from: message)
      return
    }

    // An approval answer must never be collected into a batch: it is a decision about work
    // already running, not content for the next one.
    if let relay = promptRelay, !trimmed.isEmpty {
      switch await relay.submit(sender: message.sender, text: trimmed) {
      case .approval(let decision):
        await reply(to: message, text: decision.chineseLabel + "。")
        publish { $0.detail = decision.chineseLabel }
        // The badge counts what the phone still owes an answer for, so it has to shrink the
        // moment one is answered rather than on the next unrelated status push.
        await refreshPendingPrompts()
        return
      case .answered(let confirmation):
        await reply(to: message, text: confirmation)
        await refreshPendingPrompts()
        return
      case .problem(let text):
        await reply(to: message, text: text)
        return
      case .notADecision:
        break
      }
    }

    var attachments: [BatchAttachment] = []
    for attachment in message.attachments {
      let bytes = await download(attachment)
      if let bytes {
        attachmentData[attachmentKey(sender: message.sender, messageID: message.messageID, name: attachment.name)] = bytes
      }
      attachments.append(BatchAttachment(
        kind: attachment.kind,
        name: attachment.name,
        byteCount: bytes?.count ?? attachment.byteCount
      ))
    }

    let buffer = buffer(for: message.sender)
    let outcome = buffer.ingest(
      text: message.text,
      attachments: attachments,
      messageID: message.messageID
    )
    persistBuffers()
    publish { _ in }

    switch outcome {
    case .ignored:
      return
    case .notice(let notice):
      await reply(to: message, text: notice)
    case .emptyBatch:
      await reply(to: message, text: "当前没有待提交的内容，直接发文字、文件或图片即可。")
    case .cancelled(let dropped):
      await reply(to: message, text: "已清空本批（\(dropped) 条）。")
    case .buffered(let snapshot):
      guard config.ackPolicy == .everyMessage || (config.ackPolicy == .oncePerBatch && snapshot.messageCount == 1) else {
        return
      }
      await reply(to: message, text: acknowledgement(snapshot))
    case .trigger:
      guard let submission = buffer.takeSubmission() else { return }
      persistBuffers()
      publish { _ in }
      await submit(submission, from: message)
    }
  }

  private func acknowledgement(_ snapshot: BatchSnapshot) -> String {
    var parts = ["已收纳 \(snapshot.messageCount) 条消息"]
    if snapshot.attachmentCount > 0 { parts.append("\(snapshot.attachmentCount) 个附件") }
    if snapshot.attachmentBytes > 0 {
      parts.append(ByteCountFormatter.string(fromByteCount: Int64(snapshot.attachmentBytes), countStyle: .file))
    }
    return parts.joined(separator: "、") + "。发「\(config.triggerPhrase)」提交，发「\(config.cancelPhrase)」清空。"
  }

  private func download(_ attachment: WeChatAttachment) async -> Data? {
    do {
      let limit = attachment.kind == .image ? ILinkProtocol.maxImageBytes : ILinkProtocol.maxBatchBytes
      return try await client.loadMedia(attachment.descriptor, maxBytes: limit)
    } catch {
      return nil
    }
  }

  // MARK: - Remote control

  /// Run one parsed command from the phone.
  private func run(_ line: ParsedChatLine, from message: WeChatInboundMessage) async {
    let sender = message.sender
    switch line {
    case .unknown(let verb):
      await reply(to: message, text: ChatReply.unknownCommand(verb))
    case .command(.help):
      await reply(to: message, text: ChatReply.help())
    case .command(.newSession):
      state.sessions[sender] = nil
      state.adoptedSessions[sender] = nil
      listings[sender] = nil
      persist()
      await reply(to: message, text: "已解除绑定，下一条消息会开一个新会话。")
    case .command(.stop):
      await stopActiveTurn(for: sender, message: message)
    case .command(.current):
      await reportCurrent(sender: sender, message: message)
    case .command(.list):
      await listSessions(sender: sender, message: message)
    case .command(.use(let target)):
      await bind(sender: sender, target: target, message: message)
    case .command(.history(let turns)):
      await history(sender: sender, turns: turns ?? ChatReply.defaultHistoryTurns, message: message)
    case .command(.say(let text)):
      await say(sender: sender, text: text, message: message)
    case .command(.answer(let text)):
      await answerQuestion(sender: sender, text: text, message: message)
    case .command(.workspaceList):
      await listWorkspaces(sender: sender, message: message)
    case .command(.workspace(let target)):
      await switchWorkspace(sender: sender, target: target, message: message)
    case .command(.model(let target, let effort)):
      await model(sender: sender, target: target, effort: effort, message: message)
    case .command(.effort(let target)):
      await effort(sender: sender, target: target, message: message)
    }
  }

  private func listSessions(sender: String, message: WeChatInboundMessage) async {
    do {
      let sessions = try await fetchSessions()
      listings[sender] = sessions
      await reply(to: message, text: ChatReply.sessionList(sessions, boundID: state.sessions[sender]))
    } catch {
      await reply(to: message, text: "读不到会话列表：\(describe(error))")
    }
  }

  private func reportCurrent(sender: String, message: WeChatInboundMessage) async {
    guard let boundID = state.sessions[sender], !boundID.isEmpty else {
      await reply(to: message, text: ChatReply.current(nil, boundID: nil))
      return
    }
    // The cached listing answers this for free; a binding that predates a restart needs a fetch.
    var known = listings[sender]?.first { $0.id.rawValue == boundID }
    if known == nil {
      known = (try? await fetchSessions())?.first { $0.id.rawValue == boundID }
    }
    await reply(to: message, text: ChatReply.current(known, boundID: boundID))
  }

  // MARK: - Workspaces

  /// The workspaces the harness has on file, with the channel's own folder merged in.
  ///
  /// The registry is the same `storages/workspace.json` the desktop sidebar reads, so the
  /// phone and the sidebar cannot disagree about which folders exist. `nil` means the harness
  /// home itself is unknown, which is a different answer from "nothing registered yet".
  private func workspaceListing() -> [HarnessWorkspace]? {
    guard let home = dshHome() else { return nil }
    var listing = WorkspaceCatalog.load(home: home)
    // A folder chosen but never registered (or registered under a spelling the registry does
    // not have) still has to appear: otherwise the list would omit where the channel actually
    // is, and the current-row marker would point at nothing.
    if let current = config.workspacePath, !current.isEmpty,
       !listing.contains(where: { ChatReply.samePath($0.path, current) }) {
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory)
      listing.insert(HarnessWorkspace(
        id: config.workspaceID ?? "",
        path: current,
        title: (current as NSString).lastPathComponent,
        isReachable: exists && isDirectory.boolValue
      ), at: 0)
    }
    return listing
  }

  private func listWorkspaces(sender: String, message: WeChatInboundMessage) async {
    guard let listing = workspaceListing() else {
      await reply(to: message, text: ChatReply.workspaceListingUnavailable())
      return
    }
    workspaceListings[sender] = listing
    await reply(to: message, text: ChatReply.workspaceList(listing, current: config.workspacePath))
  }

  /// `/workspace <index|id|id-prefix|path|title>` — move the channel to another folder.
  ///
  /// A workspace is a channel-wide setting (one bot, one folder), exactly like the choice in
  /// the app's channel window — so this is the same edit, made from the phone.
  private func switchWorkspace(sender: String, target: String, message: WeChatInboundMessage) async {
    guard let home = dshHome() else {
      await reply(to: message, text: ChatReply.workspaceListingUnavailable())
      return
    }
    guard let picked = WorkspaceCatalog.resolve(
      target: target,
      in: workspaceListings[sender] ?? workspaceListing() ?? [],
      home: home
    ) else {
      await reply(to: message, text: ChatReply.workspaceNotFound(target))
      return
    }
    // A registered row whose folder is gone is still worth *showing* — the user needs to see
    // where the channel is pointing — but never worth moving to: the next submission would
    // fail with a directory error the user did not ask for.
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDirectory)
    guard exists, isDirectory.boolValue else {
      await reply(to: message, text: ChatReply.workspaceFolderMissing(picked.path))
      return
    }
    let canonical = URL(fileURLWithPath: picked.path).resolvingSymlinksInPath().path
    if let current = config.workspacePath, ChatReply.samePath(current, canonical) {
      await reply(to: message, text: ChatReply.alreadyInWorkspace(picked))
      return
    }

    // Deliberately not `update(config:)`: that path also kicks `attachStoredSessions()`, which
    // would try to drag every *other* conversation's session into the new workspace and report
    // a misleading `session/conflict` for bindings that are working perfectly well.
    config.workspacePath = canonical
    // The cached id belongs to the folder we just left; re-registering is what makes the new
    // sessions appear in the sidebar.
    config.workspaceID = nil
    for buffer in buffers.values { buffer.updateConfig(config) }
    try? store.save(config: config)

    // The bound session lives in the folder we are leaving, so the switch only takes effect
    // once this conversation is unbound — `/new` semantics, said out loud in the reply. The
    // session itself stays on disk and can be picked up again with /list + /use.
    state.sessions[sender] = nil
    state.adoptedSessions[sender] = nil
    listings[sender] = nil
    workspaceListings[sender] = nil
    persist()

    var applied = picked
    applied.path = canonical
    applied.isReachable = true
    let registration = await register(workspace: canonical)
    publish { $0.detail = "已切换工作区：\(applied.displayTitle)" }
    await reply(to: message, text: ChatReply.workspaceSwitched(applied, registration: registration))
  }

  /// Best-effort registration of a freshly chosen folder, so the switch can report what
  /// actually happened instead of implying a sidebar entry that is not there yet.
  ///
  /// Unreachable harness, no `workspace/create`, or a failing RPC all degrade to a note: the
  /// folder is already saved and the next submission registers it anyway.
  private func register(workspace: String) async -> ChatReply.WorkspaceRegistration {
    do {
      let (client, capabilities) = try await harnessClient()
      publish { $0.capabilities = capabilities }
      guard capabilities.canCreateWorkspace else { return .unsupported }
      return .registered(try await ensureWorkspaceID(client: client, path: workspace))
    } catch let error as HarnessAPIError {
      // A host that cannot create sessions at all is not "temporarily unavailable": saying so
      // beats promising a retry that cannot work.
      return error.code == .rejected ? .unsupported : .pending
    } catch {
      return .pending
    }
  }

  /// `/use <index|id-prefix>` — take over any session the harness lists.
  private func bind(sender: String, target: String, message: WeChatInboundMessage) async {
    let sessions: [SessionSummary]
    do {
      sessions = try await fetchSessions()
    } catch {
      await reply(to: message, text: "读不到会话列表：\(describe(error))")
      return
    }
    guard let picked = Self.resolve(target: target, shown: listings[sender], fresh: sessions) else {
      await reply(to: message, text: "没有找到「\(target)」。先发 /list 看编号，或用 id 的前几位。")
      return
    }
    guard let cwd = picked.cwd, !cwd.isEmpty else {
      // The log is addressed by working directory, so a session without one could be talked to
      // but never read back. Refusing now beats a binding that half works.
      await reply(to: message, text: "这个会话没有记录工作目录，无法接管（历史也读不到）。")
      return
    }
    guard FileManager.default.fileExists(atPath: cwd) else {
      // The session's directory is its cwd for the agent and the address of its log. Both are
      // broken without it, so say so now rather than failing on the first message.
      await reply(to: message, text: "这个会话的工作目录不存在：\(cwd)。可能已被移动或删除，换一个会话试试。")
      return
    }
    state.sessions[sender] = picked.id.rawValue
    state.adoptedSessions[sender] = AdoptedSession(
      sessionID: picked.id.rawValue, cwd: cwd, title: picked.title
    )
    persist()
    listings[sender] = sessions
    await reply(to: message, text: ChatReply.bound(picked))
  }

  /// Resolve `/use`'s argument against the listing the user was shown, then a fresh one.
  ///
  /// A 1-based index is the phone-friendly form and the dangerous one, so it prefers the shown
  /// listing: rows reorder by activity, and resolving against a fresh fetch would bind a
  /// different session than the one the user pointed at.
  static func resolve(
    target: String,
    shown: [SessionSummary]?,
    fresh: [SessionSummary]
  ) -> SessionSummary? {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    if let index = Int(trimmed), index >= 1 {
      if let shown, index <= shown.count { return shown[index - 1] }
      return index <= fresh.count ? fresh[index - 1] : nil
    }
    let needle = trimmed.lowercased()
    guard !needle.isEmpty else { return nil }
    let bare = needle.hasPrefix("session-") ? String(needle.dropFirst("session-".count)) : needle
    guard !bare.isEmpty else { return nil }
    let candidates = (shown ?? []) + fresh
    return candidates.first { summary in
      let id = summary.id.rawValue.lowercased()
      return id == needle || id.hasPrefix("session-" + bare) || ChatReply.shortID(id).hasPrefix(bare)
    }
  }

  // MARK: - Models and reasoning effort

  /// What a typed effort matched.
  enum EffortResolution: Sendable, Equatable {
    /// An adapter-owned tier id.
    case tier(String)
    /// "No preference" — the request carries no effort at all and the host resolves the provider's
    /// own default. Distinct from every named tier, including one that happens to be the default.
    case providerDefault
    case unknown
  }

  /// `/model` — the catalog, or a switch, optionally pinning an effort at the same time.
  private func model(
    sender: String,
    target: String?,
    effort: String?,
    message: WeChatInboundMessage
  ) async {
    let client: HarnessAPIClient
    let catalog: HarnessModelCatalog
    do {
      (client, catalog) = try await modelContext()
    } catch {
      await reply(to: message, text: modelCatalogFailure(error))
      return
    }
    let bound = binding(for: sender) != nil
    let current = await currentSelection(client: client, sender: sender)

    guard let target, !target.isEmpty else {
      modelListings[sender] = catalog.choices
      await reply(to: message, text: ChatReply.modelList(catalog, current: current, bound: bound))
      return
    }
    guard let picked = Self.resolveModel(target: target, shown: modelListings[sender], catalog: catalog) else {
      await reply(to: message, text: ChatReply.modelNotFound(target))
      return
    }
    guard let effort, !effort.isEmpty else {
      await install(picked.defaultSelection, sender: sender, client: client, message: message)
      return
    }
    // A named effort is validated against *this* model's tiers: sending "high" to an adapter that
    // spells it "HIGH", or has no such tier, would be rejected by the host with a much less
    // actionable error than the list this reports.
    switch Self.resolveEffort(effort, choice: picked) {
    case .unknown:
      await reply(to: message, text: ChatReply.effortNotFound(effort, choice: picked))
    case .tier(let id):
      await install(
        HarnessModelSelection(provider: picked.provider, model: picked.model, reasoningEffort: id),
        sender: sender, client: client, message: message
      )
    case .providerDefault:
      await install(
        HarnessModelSelection(provider: picked.provider, model: picked.model, reasoningEffort: nil),
        sender: sender, client: client, message: message
      )
    }
  }

  /// `/effort` — the tiers of the model in force, or a switch to one of them.
  private func effort(sender: String, target: String?, message: WeChatInboundMessage) async {
    let client: HarnessAPIClient
    let catalog: HarnessModelCatalog
    do {
      (client, catalog) = try await modelContext()
    } catch {
      await reply(to: message, text: modelCatalogFailure(error))
      return
    }
    let current = await currentSelection(client: client, sender: sender)
    // Only *known* models are acceptable here. The model in force wins; the last listing answers
    // when the host did not project one; whatever the conversation asked for earlier is the last
    // fallback. The catalog's own default is deliberately **not** a candidate: installing an effort
    // on it would silently move a session whose model the channel could not read — including one
    // whose model is pinned by an agent preset — so that case asks the user to choose instead.
    guard let choice = catalog.choice(for: current)
      ?? effortListings[sender]?.choice
      ?? catalog.choice(for: preferredSelections[sender]) else {
      await reply(to: message, text: ChatReply.effortNeedsModel())
      return
    }
    guard !choice.efforts.isEmpty else {
      await reply(to: message, text: ChatReply.effortUnsupported(choice))
      return
    }

    guard let target, !target.isEmpty else {
      effortListings[sender] = (choice, choice.efforts)
      await reply(to: message, text: ChatReply.effortList(choice, current: current))
      return
    }

    // An index only means something against the listing it came from, and only while that listing
    // is about the same model — otherwise "2" would silently pick a tier of a different model.
    let shown = effortListings[sender].flatMap { listing in
      listing.choice.provider == choice.provider && listing.choice.model == choice.model
        ? listing.efforts
        : nil
    } ?? []
    let resolution: EffortResolution
    if let index = Int(target.trimmingCharacters(in: .whitespacesAndNewlines)), index >= 1, index <= shown.count {
      resolution = .tier(shown[index - 1].id)
    } else if indexLike(target) {
      resolution = .unknown
    } else {
      resolution = Self.resolveEffort(target, choice: choice)
    }

    switch resolution {
    case .unknown:
      await reply(to: message, text: ChatReply.effortNotFound(target, choice: choice))
    case .tier(let id):
      await install(
        HarnessModelSelection(provider: choice.provider, model: choice.model, reasoningEffort: id),
        sender: sender, client: client, message: message
      )
    case .providerDefault:
      await install(
        HarnessModelSelection(provider: choice.provider, model: choice.model, reasoningEffort: nil),
        sender: sender, client: client, message: message
      )
    }
  }

  /// Whether the text was meant as a row number that named nothing.
  private func indexLike(_ target: String) -> Bool {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let index = Int(trimmed) else { return false }
    return index >= 1
  }

  /// The authenticated client plus the catalog, which every model command needs together.
  private func modelContext() async throws -> (HarnessAPIClient, HarnessModelCatalog) {
    let (client, capabilities) = try await harnessClient()
    publish { $0.capabilities = capabilities }
    return (client, try await client.modelCatalog())
  }

  /// The selection the bound session's next turn will use.
  ///
  /// Asked of the host rather than remembered locally: the same session can be retargeted from the
  /// desktop window, and `/model` reporting a stale answer would be worse than reporting none. The
  /// local memory only answers for the stretch before any session exists.
  private func currentSelection(client: HarnessAPIClient, sender: String) async -> HarnessModelSelection? {
    guard let sessionID = state.sessions[sender], !sessionID.isEmpty else {
      return preferredSelections[sender]
    }
    let sessions = (try? await client.listSessions()) ?? []
    if let row = sessions.first(where: { $0.id.rawValue == sessionID }), let selection = row.modelSelection {
      return selection
    }
    return preferredSelections[sender]
  }

  /// Install a selection on the bound session, or remember it for the next new one.
  private func install(
    _ selection: HarnessModelSelection,
    sender: String,
    client: HarnessAPIClient,
    message: WeChatInboundMessage
  ) async {
    preferredSelections[sender] = selection
    guard let sessionID = state.sessions[sender], !sessionID.isEmpty else {
      await reply(to: message, text: ChatReply.modelSelected(selection, bound: false))
      return
    }
    do {
      let applied = try await client.selectModel(
        sessionID: sessionID,
        provider: selection.provider,
        model: selection.model,
        reasoningEffort: selection.reasoningEffort
      )
      // The host's provider/model are authoritative — it may canonicalize what it was asked for —
      // but an adapter is also free to answer a "no preference" request with the tier it resolved
      // to, and remembering *that* would turn "默认" into a permanent choice for the next session.
      let remembered = HarnessModelSelection(
        provider: applied.provider,
        model: applied.model,
        reasoningEffort: selection.reasoningEffort == nil
          ? nil
          : (applied.reasoningEffort ?? selection.reasoningEffort)
      )
      preferredSelections[sender] = remembered
      publish { $0.detail = "模型：\(remembered.displayName)" }
      await reply(to: message, text: ChatReply.modelSelected(remembered, bound: true))
    } catch {
      await reply(to: message, text: modelSwitchFailure(error))
    }
  }

  /// Resolve `/model`'s argument against the listing the user was shown, then the fresh catalog.
  ///
  /// The shown listing is preferred for exactly the reason `/use` prefers it: the catalog can
  /// change between two reads (a provider that was down comes back), and the user pointed at a row.
  static func resolveModel(
    target: String,
    shown: [HarnessModelChoice]?,
    catalog: HarnessModelCatalog
  ) -> HarnessModelChoice? {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    if let index = Int(trimmed), index >= 1 {
      if let shown, index <= shown.count { return shown[index - 1] }
      return index <= catalog.choices.count ? catalog.choices[index - 1] : nil
    }
    return catalog.choice(matching: trimmed)
  }

  /// Match a typed effort against a model's own tiers.
  static func resolveEffort(_ target: String, choice: HarnessModelChoice) -> EffortResolution {
    if ChatReply.isDefaultEffort(target) { return .providerDefault }
    guard let tier = choice.effort(matching: target) else { return .unknown }
    return .tier(tier.id)
  }

  private func history(sender: String, turns: Int, message: WeChatInboundMessage) async {
    guard let binding = binding(for: sender) else {
      await reply(to: message, text: "还没有绑定会话。发送 /list 选一个，或直接发内容 + 触发词「开始」开一个新的。")
      return
    }
    guard let home = dshHome() else {
      await reply(to: message, text: "读不到 harness 目录，无法读取历史。")
      return
    }
    guard let events = SessionLogLocator(dshHome: home)
      .events(cwd: binding.cwd, sessionID: binding.sessionID) else {
      await reply(to: message, text: "读不到这个会话的日志（工作目录可能已经变了）。可以发 /current 确认绑定。")
      return
    }
    let depth = min(max(turns, 1), 30)
    let transcript = RemoteSessionHistory.render(
      turns: RemoteSessionHistory.turns(in: events),
      limit: depth,
      maxCharacters: 2_000
    )
    await reply(to: message, text: ChatReply.history(
      title: binding.title, sessionID: binding.sessionID, transcript: transcript, turns: depth
    ))
  }

  /// `/say <text>` — submit one line without the trigger phrase.
  ///
  /// Goes through the same submission path as a triggered batch so it inherits the attachment
  /// staging, the reply watcher and the error recovery; only the collecting step is skipped.
  private func say(sender: String, text: String, message: WeChatInboundMessage) async {
    let item = BatchItem(
      messageID: message.messageID,
      text: text,
      attachments: [],
      receivedAt: Date()
    )
    await submit(BatchSubmission(items: [item]), from: message)
  }

  private func answerQuestion(sender: String, text: String, message: WeChatInboundMessage) async {
    guard let relay = promptRelay else {
      await reply(to: message, text: "现在没有待回答的问题（审批与提问转发未开启）。")
      return
    }
    // A dropped carrier is the difference between "nothing is waiting" and "your answer would
    // be thrown away". Naming which one it is stops the user retyping into a dead pipe.
    switch await relay.connectionState {
    case .connected:
      break
    case .reconnecting:
      await reply(to: message, text: "审批转发正在重连 harness，请等几秒后重发 /answer。")
      return
    case .stopped:
      await reply(to: message, text: "审批转发未连接（harness 可能已重启）。请先提交一条消息以恢复转发。")
      return
    }
    switch await relay.answer(sender: sender, text: text) {
    case .approval(let decision):
      await reply(to: message, text: decision.chineseLabel + "。")
      publish { $0.detail = decision.chineseLabel }
    case .answered(let confirmation):
      await reply(to: message, text: confirmation)
    case .problem(let problem):
      await reply(to: message, text: problem)
    case .notADecision:
      await reply(to: message, text: "现在没有待回答的问题。")
    }
    await refreshPendingPrompts()
  }

  /// Every session the harness knows about.
  private func fetchSessions() async throws -> [SessionSummary] {
    let (client, capabilities) = try await harnessClient()
    publish { $0.capabilities = capabilities }
    return try await client.listSessions()
  }

  /// The session this conversation talks to, with the directory its log lives under.
  ///
  /// One accessor for both origins so prompting, stopping and history never disagree about
  /// which session "current" means.
  private func binding(for sender: String) -> (sessionID: String, cwd: String, title: String?)? {
    guard let sessionID = state.sessions[sender], !sessionID.isEmpty else { return nil }
    if let adopted = state.adoptedSessions[sender], adopted.sessionID == sessionID {
      return (sessionID, adopted.cwd, adopted.title)
    }
    guard let workspace = config.workspacePath, !workspace.isEmpty else { return nil }
    return (sessionID, workspace, nil)
  }

  /// The binding only when the phone took the session over, which is what makes the workspace
  /// attachment step unnecessary.
  private func adoptedBinding(for sender: String) -> AdoptedSession? {
    guard let adopted = state.adoptedSessions[sender],
          state.sessions[sender] == adopted.sessionID else { return nil }
    return adopted
  }

  private func describe(_ error: Error) -> String {
    (error as? HarnessAPIError)?.message ?? (error as? ILinkError)?.message ?? String(describing: error)
  }

  /// A 404 is a host too old to have an endpoint — a different problem from a harness that is
  /// down, and one the user can actually act on.
  private func isMissingEndpoint(_ error: Error) -> Bool {
    guard let api = error as? HarnessAPIError else { return false }
    return api.code == .http && api.status == 404
  }

  private func modelCatalogFailure(_ error: Error) -> String {
    isMissingEndpoint(error)
      ? "这台 harness 没有模型目录（session/modelCatalog），升级 harness 后可用。"
      : "读不到模型列表：\(describe(error))"
  }

  private func modelSwitchFailure(_ error: Error) -> String {
    isMissingEndpoint(error)
      ? "这台 harness 没有切换模型的接口（session/selectModel），升级 harness 后可用。"
      : "切换失败：\(describe(error))"
  }

  // MARK: - Submission

  private func submit(_ submission: BatchSubmission, from message: WeChatInboundMessage) async {
    // A session taken over from the phone carries its own working directory and already
    // belongs to a workspace, so the channel's own workspace is neither required nor consulted
    // for it: routing it through `ensureSession` would try to re-register somebody else's
    // session into our workspace and raise `session/conflict`.
    let adopted = adoptedBinding(for: message.sender)

    let workspace: String
    if let adopted {
      workspace = adopted.cwd
    } else if let configured = config.workspacePath, !configured.isEmpty {
      workspace = configured
    } else {
      await reply(to: message, text: "还没有选择工作区，请在 app 的微信渠道窗口里设置后再提交。")
      return
    }
    guard FileManager.default.fileExists(atPath: workspace) else {
      // Different diagnosis for the two origins: an adopted session's directory is not the
      // channel's workspace, and telling the user to "re-pick the workspace in the app" would
      // send them to a setting that has nothing to do with the failure.
      let text = adopted == nil
        ? "工作区不存在：\(workspace)。请在 app 里重新选择。"
        : "这个会话的工作目录不存在：\(workspace)。可能已被移动或删除，发 /list 换一个。"
      await reply(to: message, text: text)
      return
    }

    await reply(to: message, text: "已提交 \(submission.items.count) 条消息、\(submission.attachments.count) 个附件，正在处理…")

    do {
      let (client, capabilities) = try await harnessClient()
      publish { $0.capabilities = capabilities }
      if promptRelay == nil { await startPromptRelay() }

      let sessionID: String
      if let adopted {
        // Already named: no create, no attach, no rename. The user picked this session and
        // any adoption step would either fail or move it.
        sessionID = adopted.sessionID
      } else {
        // A session created against a bare `cwd` is accounted for by no workspace, so the
        // harness sidebar never lists it. Register the folder first and address the session by
        // workspace — unless the host cannot register workspaces at all, in which case the
        // session still runs and the window explains why it is not in the sidebar.
        let workspaceID = capabilities.canCreateWorkspace
          ? try await ensureWorkspaceID(client: client, path: workspace)
          : config.workspaceID
        sessionID = try await ensureSession(sender: message.sender, workspace: workspace, workspaceID: workspaceID, client: client)
      }

      var content: [JSONValue] = []
      var stagedPaths: [String: String] = [:]
      let staged = await stageAttachments(submission, sender: message.sender, sessionID: sessionID, client: client, capabilities: capabilities)
      content.append(contentsOf: staged.content)
      stagedPaths = staged.paths
      content.append(.object([
        "type": .string("text"),
        "text": .string(BatchPrompt.composeText(submission, stagedPaths: stagedPaths)),
      ]))

      let requestId = try await client.prompt(sessionID: sessionID, content: content)
      if !staged.directory.isEmpty {
        deliveries[message.sender] = Task { [weak self] in
          await self?.cleanedUp(directory: staged.directory)
        }
      }
      watchReply(sender: message.sender, sessionID: sessionID, requestId: requestId, target: message, workspace: workspace)
    } catch {
      let text = (error as? HarnessAPIError)?.message ?? (error as? ILinkError)?.message ?? String(describing: error)
      // Nothing is lost: the batch goes back so the user can trigger again.
      buffer(for: message.sender).restore(items: submission.items)
      persistBuffers()
      publish { _ in }
      await reply(to: message, text: "提交失败：\(text)。内容已保留，稍后再发「\(config.triggerPhrase)」重试。")
    }
  }

  /// The channel's transport, created once and then reused.
  ///
  /// Reuse is the point, not an optimisation: one transport means one connection pool for the
  /// whole run, instead of a pool per command whose connections outlive the call that made them.
  /// It is never invalidated while the app runs — a later `/start` or re-bind has to keep talking
  /// to the same harness — so the pool is deliberately as long-lived as the channel itself.
  func harnessTransport() -> HarnessAPITransport {
    if let sharedHarnessTransport { return sharedHarnessTransport }
    let transport = makeHarnessTransport()
    sharedHarnessTransport = transport
    return transport
  }

  private func harnessClient() async throws -> (HarnessAPIClient, HarnessCapabilities) {
    guard let url = await harnessURL() else {
      throw HarnessAPIError(code: .unauthorized, message: "harness 未运行")
    }
    let parsed = try HarnessAPIClient.parse(authenticatedURL: url)
    let client = HarnessAPIClient(baseURL: parsed.origin, transport: harnessTransport())
    try await client.authenticate(token: parsed.token)
    let capabilities = await HarnessAPICompatibility.probe(client: client)
    guard capabilities.canCreateSession else {
      throw HarnessAPIError(code: .rejected, message: "这台 harness 不支持创建会话")
    }
    return (client, capabilities)
  }

  /// Resolve symlinks in the configured folder.
  ///
  /// The harness canonicalizes the path it registers (`/tmp/x` becomes `/private/tmp/x` on
  /// macOS) and refuses to adopt a session whose stored cwd is spelled differently, so the
  /// channel must speak the canonical spelling everywhere: the workspace, the session, and the
  /// `projectKey` the reply watcher derives from it. Verified against a live harness, where the
  /// raw spelling produced `session/conflict`.
  static func canonicalized(_ config: ChannelConfig) -> ChannelConfig {
    var copy = config
    if let path = copy.workspacePath, !path.isEmpty {
      copy.workspacePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    return copy
  }

  /// Resolve the harness's workspace registration for the configured folder.
  ///
  /// Cached in the config so the registration happens once per folder rather than once per
  /// batch, and invalidated (then redone) when the host answers `workspace/not-found` — which
  /// is what a workspace deleted from the GUI looks like from here.
  private func ensureWorkspaceID(client: HarnessAPIClient, path: String) async throws -> String {
    if let cached = config.workspaceID, !cached.isEmpty { return cached }
    do {
      let (workspaceID, created) = try await client.createWorkspace(path: path)
      config.workspaceID = workspaceID
      try? store.save(config: config)
      publish {
        $0.detail = created ? "已把工作区登记到 harness" : "工作区已在 harness 中"
      }
      return workspaceID
    } catch let error as HarnessAPIError where error.providerCode == "workspace/not-found" {
      // A stale id: forget it and let the next call re-register the path.
      config.workspaceID = nil
      try? store.save(config: config)
      let (workspaceID, _) = try await client.createWorkspace(path: path)
      config.workspaceID = workspaceID
      try? store.save(config: config)
      return workspaceID
    }
  }

  /// Create the sender's session inside the workspace, or adopt the one already recorded.
  private func ensureSession(
    sender: String,
    workspace: String,
    workspaceID: String?,
    client: HarnessAPIClient
  ) async throws -> String {
    guard let workspaceID, !workspaceID.isEmpty else {
      // No registration available: fall back to a cwd session so the feature still works, and
      // say so once rather than silently producing an invisible session. (`??` cannot carry an
      // `await`, so the fallback is spelled out.)
      if let existing = state.sessions[sender], !existing.isEmpty { return existing }
      let sessionID = try await client.createSession(cwd: workspace, agentPreset: config.agentPreset)
      state.sessions[sender] = sessionID
      persist()
      await adoptPreferredSelection(sender: sender, sessionID: sessionID, client: client)
      return sessionID
    }
    if let existing = state.sessions[sender], !existing.isEmpty {
      // Re-attach on every use: cheap, idempotent, and it repairs a session recorded before
      // the workspace existed (the case this fix was written for).
      do {
        let repaired = try await client.createSession(
          inWorkspace: workspaceID, agentPreset: config.agentPreset, adopting: existing
        )
        return repaired
      } catch {
        // The recorded session no longer attaches: a moved/deleted folder, or a session whose
        // stored cwd is spelled differently from the registered workspace. Make a new one
        // rather than failing the submission, and leave the old session untouched on disk.
        let reason = (error as? HarnessAPIError)?.providerCode == "session/conflict"
          ? "旧会话的工作目录拼写与当前工作区不一致，无法登记（旧内容仍在磁盘上）"
          : "旧会话无法继续使用（工作目录可能已变），已新建会话"
        publish { $0.detail = reason }
        let fresh = try await client.createSession(inWorkspace: workspaceID, agentPreset: config.agentPreset)
        state.sessions[sender] = fresh
        persist()
        await titleSession(fresh, sender: sender, client: client)
        await adoptPreferredSelection(sender: sender, sessionID: fresh, client: client)
        return fresh
      }
    }
    let sessionID = try await client.createSession(inWorkspace: workspaceID, agentPreset: config.agentPreset)
    state.sessions[sender] = sessionID
    persist()
    await titleSession(sessionID, sender: sender, client: client)
    await adoptPreferredSelection(sender: sender, sessionID: sessionID, client: client)
    return sessionID
  }

  /// Install the selection this conversation asked for before its session existed.
  ///
  /// Deliberately confined to *freshly created* sessions. An existing session may have been
  /// retargeted from the desktop window since the phone last spoke, and re-applying a remembered
  /// choice on every use would silently undo that.
  private func adoptPreferredSelection(sender: String, sessionID: String, client: HarnessAPIClient) async {
    guard let preferred = preferredSelections[sender] else { return }
    do {
      let applied = try await client.selectModel(
        sessionID: sessionID,
        provider: preferred.provider,
        model: preferred.model,
        reasoningEffort: preferred.reasoningEffort
      )
      preferredSelections[sender] = HarnessModelSelection(
        provider: applied.provider,
        model: applied.model,
        reasoningEffort: preferred.reasoningEffort
      )
      publish { $0.detail = "模型：\(applied.displayName)" }
    } catch {
      // Best effort by design: the turn still runs on the harness default, and a later `/model`
      // repairs it. Failing the submission over a preference would be the worse trade.
      publish { $0.detail = "模型设置失败：\(describe(error))" }
    }
  }

  /// Give a freshly created channel session a recognizable name in the sidebar.
  ///
  /// Only on creation: renaming on every use would overwrite a title the user set in the GUI.
  private func titleSession(_ sessionID: String, sender: String, client: HarnessAPIClient) async {
    let handle = sender.split(separator: "@").first.map(String.init) ?? sender
    let short = handle.count > 12 ? String(handle.prefix(12)) : handle
    try? await client.rename(sessionID: sessionID, title: "微信 · \(short)")
  }

  /// Open the host's forwarded-event stream so approval questions reach this chat.
  ///
  /// Idempotent: a live relay is kept, and the caller may retry freely as the harness starts
  /// and stops. Without it a turn that needs approval would wait for a browser that may not be
  /// looking at that session.
  public func startPromptRelay() async {
    guard promptRelay == nil else { return }
    do {
      let (client, capabilities) = try await harnessClient()
      publish { $0.capabilities = capabilities }
      let stream = try await approvalStreamFactory(client)
      let relay = PromptRelay(
        stream: stream,
        route: { [weak self] sessionID in
          await self?.route(sessionID: sessionID)
        },
        prompt: { [weak self] sender, text in
          await self?.notify(sender: sender, text: text)
          await self?.refreshPendingPrompts()
        },
        onCancelled: { [weak self] sender, tool in
          await self?.notify(sender: sender, text: "这次请求已被取消（\(tool)），无需回复。")
          await self?.refreshPendingPrompts()
        }
      )
      // The window has to show a broken carrier as broken: a channel that says "转发已开启"
      // while every answer is being dropped is worse than one that admits it is reconnecting.
      await relay.setConnectionHandler { [weak self] connection in
        Task { await self?.publishConnection(connection) }
      }
      promptRelay = relay
      Task { await relay.run() }
      publish {
        $0.detail = "审批与提问转发已开启"
        $0.forwardsAllPrompts = self.forwardsAllPrompts
      }
    } catch {
      // Not fatal: submissions keep working, and the relay is retried on the next trigger.
      publish { $0.detail = "审批与提问转发未开启：\((error as? HarnessAPIError)?.message ?? String(describing: error))" }
    }
  }

  /// Reflect one carrier transition in the published status.
  private func publishConnection(_ connection: PromptRelayConnection) async {
    switch connection {
    case .connected:
      publish { $0.detail = self.forwardsAllPrompts
        ? "手机远控已开启：所有会话的审批与提问都会发到手机"
        : "审批与提问转发已连接" }
    case .reconnecting(let attempt):
      publish { $0.detail = "审批转发已断开，正在重连 harness（第 \(attempt) 次）…" }
    case .stopped:
      // Nothing will be forwarded until a new submission reopens the carrier, so the stale
      // relay must not stay in place pretending otherwise.
      promptRelay = nil
      publish { $0.detail = "审批转发已停止，请重新提交一条消息以恢复。" }
    }
    await refreshPendingPrompts()
  }

  /// Route approvals from **every** session — desktop ones included — to the phone, or stop.
  ///
  /// Switching off restores the previous behaviour exactly: the conversation's own sessions
  /// keep forwarding, and a session this channel does not own goes back to being the GUI's
  /// business. The relay itself is deliberately left running when the switch goes off — a
  /// submission may already have opened it, and tearing the stream down would change
  /// approvals the user never asked to change.
  public func setForwardsAllPrompts(_ on: Bool) async {
    forwardsAllPrompts = on
    if on {
      await startPromptRelay()
      // A relay that refused to open has already published why; claiming it is on would
      // contradict the line the user is reading.
      if promptRelay != nil {
        publish { $0.detail = "手机远控已开启：所有会话的审批与提问都会发到手机，桌面会话的轮次结果与回复也会转发" }
      }
    } else {
      publish { $0.detail = "手机远控已关闭：不推送也不转发；只有微信会话自己的审批、提问与回复照旧" }
    }
    await refreshPendingPrompts()
  }

  public func currentForwardsAllPrompts() -> Bool { forwardsAllPrompts }

  /// Republish how many questions the phone is still holding an answer for.
  func refreshPendingPrompts() async {
    let count = await promptRelay?.pendingCount ?? 0
    let on = forwardsAllPrompts
    publish {
      $0.pendingPrompts = count
      $0.forwardsAllPrompts = on
    }
  }

  /// Where one session's approvals should go, or nil to leave it to the GUI.
  func route(sessionID: String) -> PromptRelay.Route? {
    if let sender = owner(ofSession: sessionID), !sender.isEmpty { return .owned(sender) }
    guard forwardsAllPrompts else { return nil }
    // A borrowed question is answered from the phone, so it may only be sent to an address
    // the channel will accept a reply from — otherwise the user would be asked a question
    // whose answer is dropped at the door.
    guard let address = phonePromptAddress() else { return nil }
    return .borrowed(address)
  }

  /// Who a borrowed question goes to: the bot owner when the allowlist permits them (the
  /// default owner-only case), otherwise the first sender the user explicitly allowed.
  func phonePromptAddress() -> String? {
    guard let owner = credential?.ownerUserID, !owner.isEmpty else { return nil }
    if config.allowsSender(owner, owner: owner) { return owner }
    return config.allowedSenders.first
  }

  /// The chat sender that owns a session, or nil when the session is not this channel's.
  func owner(ofSession sessionID: String) -> String? {
    state.sessions.first { $0.value == sessionID }?.key
  }

  /// Send a message to a sender outside a reply context (approval questions).
  func notify(sender: String, text: String) async {
    guard let credential else { return }
    for chunk in WeChatMessageParser.splitText(text, maxCharacters: config.replyChunkCharacters) {
      do {
        try await client.sendText(
          token: credential.token,
          toUserID: sender,
          text: chunk,
          contextToken: state.contextTokens[sender],
          baseURL: credential.baseURL
        )
      } catch {
        let failure = error as? ILinkError
        // The message now carries the provider's own `errmsg`, so a refused request says which
        // parameter it disliked instead of only "ret -2". An expired session still has to change
        // the badge: a push that cannot go out is what the user notices first.
        publish {
          $0.lastError = failure?.message ?? String(describing: error)
          if failure?.code == .sessionExpired { $0.phase = .needsLogin }
        }
        return
      }
    }
  }

  // MARK: - Information forwarding

  /// Push one finished turn to the phone: what happened, and what it answered.
  ///
  /// Gated by the same switch as the approval push, because "手机远控" is one decision about what
  /// the phone is for — being asked *and* being told. Reusing that flag rather than adding a second
  /// one is the point: two switches would drift, and "远控开着却什么都收不到" is exactly the state a
  /// user cannot diagnose from the phone.
  ///
  /// **Sessions this channel owns are skipped.** A WeChat-originated turn already has its answer
  /// delivered into the conversation it came from, so forwarding it here would send the same text
  /// twice. What this is *for* is the other case: a turn started at the desk, which the phone would
  /// otherwise never hear about.
  public func forwardTurnInfo(_ completion: TurnCompletion) async {
    guard forwardsAllPrompts else { return }
    // The switch can be on with nowhere to send: no bound bot, or an allowlist that excludes the
    // owner. Saying so beats the silence a user cannot diagnose from the phone — and it is the one
    // guard on this path that no other surface reports.
    guard let sender = phonePromptAddress() else {
      publish { $0.lastError = "手机远控已开启，但没有可发送的微信会话：先给机器人发一条消息，或在渠道窗口里确认绑定与允许的发送者。" }
      return
    }

    let owner = owner(ofSession: completion.sessionID)
    let adopted = owner.flatMap { state.adoptedSessions[$0]?.sessionID }
    guard Self.shouldForward(
      sessionID: completion.sessionID,
      owner: owner,
      adoptedSessionID: adopted
    ) else { return }

    await notify(sender: sender, text: Self.turnHeadline(completion))

    // Best-effort, and deliberately not gated on the turn having succeeded: a failed turn can still
    // hold the partial answer that explains it. No text means the headline was the whole message.
    let reply = Self.bounded(
      turnReplyText(for: completion) ?? "",
      limit: Self.forwardedReplyLimit
    )
    if !reply.isEmpty {
      await notify(sender: sender, text: reply)
    }
  }

  /// Whether one session's finished turn should be forwarded, given who owns the conversation.
  ///
  /// Two kinds of ownership, and they answer differently:
  ///
  /// - **Created by this channel** (a trigger-phrase submission). The chat is that session's home, so
  ///   its answer is already delivered into the conversation it came from — forwarding it again would
  ///   send the same text twice, which is the visible bug this check exists to prevent.
  /// - **Adopted from the phone** (`/use`). The chat only *borrowed* that session's approvals; the
  ///   desk still owns its output and nothing pushes it to the chat, so it is forwarded. Treating the
  ///   two the same would silently lose every result of a session the user took over.
  ///
  /// Pure so both answers are assertable without a bound bot or a live conversation.
  public static func shouldForward(
    sessionID: String,
    owner: String?,
    adoptedSessionID: String?
  ) -> Bool {
    guard owner != nil else { return true }
    return adoptedSessionID == sessionID
  }

  /// How much of a forwarded answer is sent, in characters.
  ///
  /// A bound rather than the whole thing. This is a courtesy for a turn the user started at the desk,
  /// so a long answer would otherwise arrive as a dozen consecutive messages on a phone — the failure
  /// mode that gets a forwarding feature switched off. The headline already says the turn finished, so
  /// the rest is one tap away in the app.
  public static let forwardedReplyLimit = 600

  /// A reply clipped for a phone, with a note that it was clipped.
  ///
  /// Pure, like the headline, so the bound and its wording are assertable without a bot.
  public static func bounded(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit)) + "\n…（内容较长，完整内容在 app 里）"
  }

  /// The one-line "what just happened" — the shape a phone message is for.
  ///
  /// A pure function so the wording is assertable without a bot, a socket, or a log file.
  public static func turnHeadline(_ completion: TurnCompletion) -> String {
    let trimmed = completion.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = (trimmed?.isEmpty == false ? trimmed : nil) ?? completion.sessionID
    let turn = completion.turn.map { "第 \($0) 轮" } ?? "本轮"
    switch completion.kind {
    case .completed:
      return "✅ \(name) · \(turn)完成"
    case .maxTokens:
      return "⚠️ \(name) · \(turn)达到输出上限后停止"
    case .blocked:
      return "⛔️ \(name) · \(turn)被拒绝执行"
    case .error:
      return "❌ \(name) · \(turn)失败\(failureSuffix(completion))"
    case .aborted:
      return "🛑 \(name) · \(turn)已中断"
    case .interrupted:
      return "↩️ \(name) · \(turn)在恢复后被补记结束"
    case .unknown:
      return "ℹ️ \(name) · \(turn)结束（未识别的原因）"
    }
  }

  /// `（code：message）` when the harness carried a structured failure, empty otherwise.
  static func failureSuffix(_ completion: TurnCompletion) -> String {
    let parts = [completion.failureCode, completion.failureMessage]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !parts.isEmpty else { return "" }
    return "（\(parts.joined(separator: "："))）"
  }

  /// What the finished turn answered, read from the session's own log.
  ///
  /// `nil` whenever the log cannot be located or the turn produced no text — all ordinary cases
  /// (a workspace that moved, a turn that only ran tools), and none of which should stop the
  /// headline from going out.
  private func turnReplyText(for completion: TurnCompletion) -> String? {
    guard let home = dshHome(), let cwd = completion.cwd, !cwd.isEmpty else { return nil }
    guard let events = SessionLogLocator(dshHome: home)
      .events(cwd: cwd, sessionID: completion.sessionID)
    else { return nil }
    return SessionReplyExtractor.turnReply(in: events, turn: completion.turn)
  }

  /// Attach every already-recorded conversation to the configured workspace.
  ///
  /// Runs after the channel starts and whenever the configuration changes, so a session
  /// created before this channel learned about workspaces becomes visible without the user
  /// resending anything. Silent when the harness is not running: it is retried, not reported.
  public func attachStoredSessions() async {
    guard let workspace = config.workspacePath, !workspace.isEmpty else { return }
    // Never race a live turn for its own session.
    guard deliveries.isEmpty else { return }
    // Only sessions this channel created need the channel's workspace to account for them.
    // A session the phone took over from the list is already registered in its own workspace,
    // and asking the harness to adopt it into ours raises `session/conflict` and reports a
    // misleading "directory spelling" problem for a binding that is working perfectly.
    let sessions = state.sessions.filter { entry in
      !entry.value.isEmpty && adoptedBinding(for: entry.key) == nil
    }
    guard !sessions.isEmpty else { return }
    guard let url = await harnessURL() else { return }
    do {
      let parsed = try HarnessAPIClient.parse(authenticatedURL: url)
      let client = HarnessAPIClient(baseURL: parsed.origin, transport: harnessTransport())
      try await client.authenticate(token: parsed.token)
      let capabilities = await HarnessAPICompatibility.probe(client: client)
      publish { $0.capabilities = capabilities }
      guard capabilities.canCreateWorkspace else { return }
      let workspaceID = try await ensureWorkspaceID(client: client, path: workspace)
      for (sender, sessionID) in sessions {
        do {
          _ = try await client.createSession(
            inWorkspace: workspaceID, agentPreset: config.agentPreset, adopting: sessionID
          )
        } catch {
          let providerCode = (error as? HarnessAPIError)?.providerCode
          publish {
            $0.detail = providerCode == "session/conflict"
              ? "会话 \(sessionID) 的工作目录拼写与工作区不一致，无法登记；下次提交会新建会话"
              : "会话 \(sessionID) 无法登记进工作区（可能目录已变），下次提交会新建会话"
          }
          _ = sender
        }
      }
      publish { $0.detail = "历史会话已登记到工作区" }
    } catch {
      // Best effort by design: the next successful submission repairs it anyway.
      publish { $0.detail = "历史会话登记待重试：\((error as? HarnessAPIError)?.message ?? String(describing: error))" }
    }
  }

  /// Turn the batch's attachments into prompt blocks.
  ///
  /// Files go through the harness's own upload so the bytes live where the model can see
  /// them; when that endpoint is missing the channel degrades to writing them inside the
  /// workspace and naming the paths, which the model can read with its file tools.
  private func stageAttachments(
    _ submission: BatchSubmission,
    sender: String,
    sessionID: String,
    client: HarnessAPIClient,
    capabilities: HarnessCapabilities
  ) async -> (content: [JSONValue], paths: [String: String], directory: String) {
    var content: [JSONValue] = []
    var paths: [String: String] = [:]
    var directory = ""
    var index = 0

    for item in submission.items {
      for attachment in item.attachments {
        index += 1
        let key = attachmentKey(sender: sender, messageID: item.messageID, name: attachment.name)
        let bytes = attachmentData.removeValue(forKey: key)
        guard let bytes else { continue }

        if attachment.kind == .image, bytes.count <= ILinkProtocol.maxImageBytes,
           let mediaType = imageMediaType(for: attachment.name, bytes: bytes) {
          content.append(.object([
            "type": .string("image"),
            "mediaType": .string(mediaType),
            "name": .string(attachment.name),
            "data": .string(bytes.base64EncodedString()),
          ]))
          continue
        }

        if capabilities.canUploadFiles, let receipt = try? await client.uploadFile(
          sessionID: sessionID, data: bytes, name: attachment.name
        ) {
          content.append(.object(["type": .string("file"), "receiptId": .string(receipt)]))
          continue
        }

        if directory.isEmpty {
          directory = (config.workspacePath ?? NSTemporaryDirectory())
            .appending("/.dsh-wechat-inbound/\(Int(Date().timeIntervalSince1970))")
          try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let path = "\(directory)/\(sanitized(attachment.name, fallback: "file-\(index)"))"
        if (try? bytes.write(to: URL(fileURLWithPath: path))) != nil {
          paths[attachment.name] = path
        }
      }
    }
    return (content, paths, directory)
  }

  private func imageMediaType(for name: String, bytes: Data) -> String? {
    switch (name as NSString).pathExtension.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    default:
      // WeChat sends JPEG for photos; sniffing the magic bytes covers a renamed file too.
      if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
      if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
      return nil
    }
  }

  private func sanitized(_ name: String, fallback: String) -> String {
    let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
    return cleaned.isEmpty ? fallback : cleaned
  }

  private func cleanedUp(directory: String) async {
    // The staged copy exists only so the model can read it during this turn.
    try? await Task.sleep(for: .seconds(600))
    try? FileManager.default.removeItem(atPath: directory)
  }

  /// Wait for the answer and deliver it, keeping a long task from looking dead.
  private func watchReply(sender: String, sessionID: String, requestId: String, target: WeChatInboundMessage, workspace: String) {
    deliveries[sender]?.cancel()
    deliveries[sender] = Task { [weak self] in
      guard let self else { return }
      await self.deliverReply(sender: sender, sessionID: sessionID, requestId: requestId, target: target, workspace: workspace)
      await self.clearDelivery(sender: sender)
    }
  }

  private func clearDelivery(sender: String) {
    deliveries[sender] = nil
  }

  private func deliverReply(sender: String, sessionID: String, requestId: String, target: WeChatInboundMessage, workspace: String) async {
    guard let home = dshHome() else {
      await reply(to: target, text: "已提交，但无法读取会话日志，请到 app 里查看结果。")
      return
    }
    let source = replySourceFactory(home, workspace, sessionID)
    var notifiedSlow = false
    while !Task.isCancelled {
      // Named `answer`, not `reply`: the method below is also called `reply`, and shadowing
      // it here would turn the delivery into a call on a value.
      guard let answer = await source.waitForReply(requestId: requestId, timeout: replyConfiguration.timeout) else { break }
      if answer.isComplete {
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.isEmpty ? "这一轮没有输出文本（reason：\(answer.reason ?? "unknown")）。" : text
        await sendChunks(body, to: target)
        publish { $0.lastReplyAt = Date() }
        return
      }
      if !notifiedSlow {
        notifiedSlow = true
        await reply(to: target, text: "这一步跑得比较久，完成后会补发结果；需要中止可以发 /stop。")
      }
    }
  }

  private func stopActiveTurn(for sender: String, message: WeChatInboundMessage) async {
    guard let sessionID = state.sessions[sender] else {
      await reply(to: message, text: "当前没有正在运行的会话。")
      return
    }
    do {
      let (client, _) = try await harnessClient()
      try await client.cancel(sessionID: sessionID)
      await reply(to: message, text: "已请求停止当前任务。")
    } catch {
      let text = (error as? HarnessAPIError)?.message ?? String(describing: error)
      await reply(to: message, text: "停止失败：\(text)")
    }
  }

  // MARK: - Outbound

  private func sendChunks(_ text: String, to message: WeChatInboundMessage) async {
    guard let credential else { return }
    for chunk in WeChatMessageParser.splitText(text, maxCharacters: config.replyChunkCharacters) {
      do {
        try await client.sendText(
          token: credential.token,
          toUserID: message.sender,
          text: chunk,
          contextToken: message.contextToken,
          runID: message.runID,
          baseURL: credential.baseURL
        )
      } catch {
        let failure = error as? ILinkError
        let detail = failure?.message ?? String(describing: error)
        state.lastError = detail
        if failure?.code == .sessionExpired {
          // Same protocol rule as the poll loop: the tokens belong to the session that ended.
          state.contextTokens.removeAll()
        }
        persist()
        publish {
          $0.lastError = detail
          if failure?.code == .sessionExpired { $0.phase = .needsLogin }
        }
        return
      }
    }
  }

  private func reply(to message: WeChatInboundMessage, text: String) async {
    await sendChunks(text, to: message)
  }

  // MARK: - Buffers and persistence

  private func buffer(for sender: String) -> InboundBatchBuffer {
    if let existing = buffers[sender] { return existing }
    let restored = state.batches[sender] ?? []
    let buffer = InboundBatchBuffer(key: sender, config: config, items: restored)
    buffers[sender] = buffer
    return buffer
  }

  private func attachmentKey(sender: String, messageID: String, name: String) -> String {
    "\(sender)|\(messageID)|\(name)"
  }

  private func persistBuffers() {
    state.batches = buffers.mapValues(\.items).filter { !$0.value.isEmpty }
    persist()
  }

  private func persistCredential() {
    guard let credential else { return }
    do {
      try store.save(credential: credential)
    } catch {
      publish { $0.lastError = "保存微信凭据失败：\(error.localizedDescription)" }
    }
  }

  private func persist() {
    do {
      try store.save(state: state)
    } catch {
      // Persisting is best effort: losing the cursor is survivable, crashing the loop is not.
      publish { $0.lastError = "保存渠道状态失败：\(error.localizedDescription)" }
    }
  }
}
