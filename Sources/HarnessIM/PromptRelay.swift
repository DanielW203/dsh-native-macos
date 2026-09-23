import Foundation
import HarnessKit

/// The only grant the approval service accepts, and its refusal counterpart.
///
/// Both literals are the harness's own vocabulary (`ApprovalOutcome`), and they are exactly
/// what the GUI's two buttons send — quoting anything else would be refused by the host.
public enum ApprovalDecision: String, Sendable, Equatable {
  case allowedOnce = "allowed-once"
  case rejected = "rejected"

  public var chineseLabel: String {
    self == .allowedOnce ? "已批准（仅这一次）" : "已拒绝"
  }
}

/// Classify a chat reply as an approval decision.
///
/// Deliberately narrow: a sentence that merely contains 「可以」 must not approve a tool call,
/// so only a short reply that *is* one of the words counts. Anything else stays ordinary chat
/// and never reaches the harness as a decision.
public enum ApprovalReply {
  public static let allowWords: Set<String> = ["批准", "同意", "允许", "通过", "可以", "ok", "okay", "yes", "y", "approve"]
  public static let rejectWords: Set<String> = ["拒绝", "不同意", "不允许", "不行", "不", "no", "n", "deny", "reject"]

  public static func decide(_ text: String) -> ApprovalDecision? {
    let normalized = normalize(text)
    guard !normalized.isEmpty, normalized.count <= 12 else { return nil }
    if allowWords.contains(normalized) { return .allowedOnce }
    if rejectWords.contains(normalized) { return .rejected }
    return nil
  }

  static func normalize(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Trailing punctuation is noise on a phone keyboard; `！`/`。`/`.` must not defeat a match.
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？~～ 　"))
  }
}

/// What one phone reply means while a plan review is waiting.
public enum PlanReviewVerdict: Sendable, Equatable {
  /// Leave plan mode and carry the plan out.
  case approve
  /// Stay in plan mode; `feedback` is the revision the model is asked for, when there is one.
  case keepPlanning(feedback: String?)
}

/// The three answers a plan review has on a phone: 「批准」「拒绝」and an opinion.
///
/// The GUI puts a text field next to its two plan buttons; a phone keyboard has no such field,
/// so the opinion is spelled out — 「说 你的意见」— and a reply that is neither of the two words
/// is taken as the opinion itself: while a review is open, the turn is stalled and the phone has
/// nothing else it could mean. Nothing here is chat content, and the review stays open until one
/// of the three lands.
public enum PlanReviewReply {
  /// The words that introduce an opinion rather than answer yes or no.
  static let opinionPrefixes = ["说", "反馈", "意见", "say", "feedback"]
  /// What may sit between such a word and the words themselves.
  static let separators = CharacterSet(charactersIn: " \t\u{3000}：:，,、-—")

  /// Read one reply, or nil when it carries no answer — an empty message, or a bare 「说」 that
  /// is waiting for the words it promises.
  public static func decide(_ text: String) -> PlanReviewVerdict? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalized = ApprovalReply.normalize(trimmed)
    if normalized.count <= 12 {
      if ApprovalReply.allowWords.contains(normalized) { return .approve }
      if ApprovalReply.rejectWords.contains(normalized) { return .keepPlanning(feedback: nil) }
    }
    if let opinion = opinion(after: trimmed) {
      let body = opinion.trimmingCharacters(in: .whitespacesAndNewlines)
      return body.isEmpty ? nil : .keepPlanning(feedback: body)
    }
    return .keepPlanning(feedback: trimmed)
  }

  /// The text after a leading 「说」/「反馈」, or nil when the reply does not open with one.
  ///
  /// The prefix counts only when it is set off from the words: 「说 第二步太粗」 strips it, while
  /// 「说得好」 is an opinion that merely begins with the character and is passed through whole.
  static func opinion(after text: String) -> String? {
    let lowered = text.lowercased()
    for prefix in opinionPrefixes where lowered.hasPrefix(prefix) {
      var rest = text.dropFirst(prefix.count)
      guard let first = rest.unicodeScalars.first else { return "" }
      guard separators.contains(first) else { return nil }
      while let head = rest.unicodeScalars.first, separators.contains(head) { rest = rest.dropFirst() }
      return String(rest)
    }
    return nil
  }
}

/// One approval the channel has forwarded and is waiting on.
public struct PendingApproval: Sendable, Equatable {
  public var eventID: String
  public var sessionID: String
  public var toolName: String
  public var reason: String?
  public var requestedAt: Date
  /// True when the session is not the chat's own — a desktop session the user asked to be
  /// able to answer from the phone. Kept so the question can say so: answering 「批准」 for
  /// work the user never started from chat needs a visible difference.
  public var isBorrowed: Bool

  public init(
    eventID: String,
    sessionID: String,
    toolName: String,
    reason: String?,
    requestedAt: Date = Date(),
    isBorrowed: Bool = false
  ) {
    self.eventID = eventID
    self.sessionID = sessionID
    self.toolName = toolName
    self.reason = reason
    self.requestedAt = requestedAt
    self.isBorrowed = isBorrowed
  }
}

/// One thing the harness is waiting on the phone for.
///
/// Approvals and questions arrive on the same waterfall carrier with different answer shapes.
/// They share one queue per address on purpose: the phone answers what it read first, and a
/// single slot per address would let the second request overwrite the first and strand the
/// turn that asked for it.
public enum PendingPrompt: Sendable, Equatable {
  case approval(PendingApproval)
  case question(PendingQuestion)

  public var eventID: String {
    switch self {
    case .approval(let value): return value.eventID
    case .question(let value): return value.eventID
    }
  }

  public var sessionID: String {
    switch self {
    case .approval(let value): return value.sessionID
    case .question(let value): return value.sessionID
    }
  }

  public var isBorrowed: Bool {
    switch self {
    case .approval(let value): return value.isBorrowed
    case .question(let value): return value.isBorrowed
    }
  }

  /// How a cancellation names what went away.
  public var kindLabel: String {
    switch self {
    case .approval(let value): return value.toolName
    case .question: return "提问"
    }
  }
}

/// What one phone reply did.
public enum PromptOutcome: Sendable, Equatable {
  /// An approval was answered.
  case approval(ApprovalDecision)
  /// A question (or an explicit `/answer` for an approval) was answered; the text is the
  /// confirmation to send back.
  case answered(String)
  /// An answer was attempted and could not be used. The text explains, and is sent back.
  case problem(String)
  /// Not a decision at all: the caller keeps the text as ordinary chat content.
  case notADecision
}

/// Whether the relay is currently holding a live carrier.
///
/// Published because a dead relay used to be indistinguishable from a healthy one: the actor
/// reference stayed non-nil, so `/answer` was accepted and then answered "no question is
/// waiting" forever. The distinction matters to the user, not just to the code.
public enum PromptRelayConnection: Sendable, Equatable {
  /// Carrying frames; questions and approvals arrive.
  case connected
  /// Retrying after a dropped or refused carrier. Between attempts, and right after a drop,
  /// nothing the host is waiting on can be answered from the chat.
  case reconnecting(attempt: Int)
  /// Gave up after `maximumAttempts`. Only produced when a retry cap was configured.
  case stopped
}

/// How hard the relay tries to keep a carrier open.
///
/// The carrier is a long-lived WebSocket that dies whenever the harness is restarted (which
/// also changes its port), so reconnecting is the normal case rather than an error path.
public struct PromptRelayReconnect: Sendable, Equatable {
  /// Delay before the first retry; doubled per consecutive failure.
  public var initialDelay: Duration
  /// Ceiling for the doubling.
  public var maximumDelay: Duration
  /// `nil` retries forever, which is what production wants: the harness may come back hours later.
  public var maximumAttempts: Int?

  public init(
    initialDelay: Duration = .seconds(1),
    maximumDelay: Duration = .seconds(30),
    maximumAttempts: Int? = nil
  ) {
    self.initialDelay = initialDelay
    self.maximumDelay = maximumDelay
    self.maximumAttempts = maximumAttempts
  }

  /// The delay before attempt `n` (1-based), capped at `maximumDelay`.
  func delay(beforeAttempt attempt: Int) -> Duration {
    var seconds = initialDelay.secondsValue
    for _ in 1..<max(attempt, 1) {
      seconds *= 2
      if seconds >= maximumDelay.secondsValue { return maximumDelay }
    }
    return .seconds(min(seconds, maximumDelay.secondsValue))
  }
}

extension Duration {
  /// This duration in seconds, for the exponential backoff arithmetic above.
  var secondsValue: Double {
    let components = self.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}

/// Forwards the harness's approval and question requests to the chat, and answers them there.
///
/// Ownership is the rule that keeps this from interfering with the GUI: the host broadcasts a
/// waterfall request to every connected client, and only the client that owns the session is
/// expected to answer. A request for a session this channel does not own is left untouched —
/// the browser answers it as usual — unless the user has switched phone approvals on, in
/// which case the request is *borrowed* for the bot owner and the GUI still gets its chance:
/// the first answer to reach the host wins, exactly as when two windows are open.
///
/// The carrier is reconnected rather than abandoned. This is not a nicety: an answer is only
/// accepted from a client the host still knows (`clientId`), and the host hands out a fresh
/// one per connection. A relay that kept a stale `clientId` had its answers dropped in
/// silence — the RPC reported success while the question stayed pending, so the GUI showed
/// no change. Reconnecting also repairs the queue for free: `openRemoteEvents` re-delivers
/// every still-pending request to the new client.
public actor PromptRelay {
  /// Where one request should be sent, or nil to leave it to the GUI.
  public enum Route: Sendable, Equatable {
    /// The chat conversation that owns the session.
    case owned(String)
    /// A session the channel does not own; only produced while the user has phone approvals on.
    case borrowed(String)

    public var address: String {
      switch self {
      case .owned(let address), .borrowed(let address): return address
      }
    }

    public var isBorrowed: Bool {
      if case .borrowed = self { return true }
      return false
    }
  }

  /// Session id → where its requests should go, or nil when this channel should stay out of it.
  public typealias Router = @Sendable (String) async -> Route?
  /// Deliver one question to the chat.
  public typealias Prompt = @Sendable (String, String) async -> Void
  /// Called when a forwarded question disappears without an answer.
  public typealias Cancellation = @Sendable (String, String) async -> Void

  private let stream: any RemoteEventStreaming
  private let router: Router
  private let prompt: Prompt
  private let onCancelled: Cancellation?
  private let reconnect: PromptRelayReconnect
  /// Address → its requests, oldest first.
  private var pending: [String: [PendingPrompt]] = [:]
  private var runTask: Task<Void, Never>?
  private var clientID: String?
  private var connection: PromptRelayConnection = .reconnecting(attempt: 0)

  public init(
    stream: any RemoteEventStreaming,
    route: @escaping Router,
    prompt: @escaping Prompt,
    onCancelled: Cancellation? = nil,
    reconnect: PromptRelayReconnect = PromptRelayReconnect()
  ) {
    self.stream = stream
    self.router = route
    self.prompt = prompt
    self.onCancelled = onCancelled
    self.reconnect = reconnect
  }

  /// The current carrier state. `connected` is the only state in which an answer can land.
  public var connectionState: PromptRelayConnection { connection }

  /// Called on every carrier transition, so the UI can say "转发已断开，正在重连…" instead of
  /// looking healthy while nothing is being forwarded.
  private var connectionHandler: (@Sendable (PromptRelayConnection) -> Void)?

  public func setConnectionHandler(_ handler: (@Sendable (PromptRelayConnection) -> Void)?) {
    connectionHandler = handler
    handler?(connection)
  }

  private func publish(connection next: PromptRelayConnection) {
    guard connection != next else { return }
    connection = next
    connectionHandler?(next)
  }

  public var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }

  /// The oldest approval waiting on one address, or nil when the next thing is not one.
  public func pendingApproval(for sender: String) -> PendingApproval? {
    guard case .approval(let value) = pending[sender]?.first else { return nil }
    return value
  }

  /// The oldest question waiting on one address, or nil when the next thing is not one.
  public func pendingQuestion(for sender: String) -> PendingQuestion? {
    guard case .question(let value) = pending[sender]?.first else { return nil }
    return value
  }

  /// Consume the stream, reconnecting until the relay is stopped or the retry budget runs out.
  public func run() async {
    runTask?.cancel()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.consume()
    }
    runTask = task
    await task.value
  }

  /// Stop consuming and close the carrier.
  public func stop() async {
    runTask?.cancel()
    runTask = nil
    pending.removeAll()
    publish(connection: .stopped)
    await stream.close()
  }

  private func consume() async {
    var attempt = 0
    while !Task.isCancelled {
      // Did this connection carry anything at all? A carrier that opens and immediately ends is
      // not the success worth a fresh backoff: resetting the counter on `open()` alone means a
      // flapping host is retried once a second forever, at one socket per lap.
      var carried = false
      do {
        let frames = try await stream.open()
        publish(connection: .connected)
        for try await frame in frames {
          if Task.isCancelled { break }
          carried = true
          await handle(frame)
        }
      } catch {
        // The carrier died. Whatever the host was waiting on can no longer be answered from
        // here: every pending entry names an `eventId` that only the dead `clientId` could
        // settle, and the host silently ignores a result from a client it no longer knows.
        // Dropping them is the honest move — the reconnect re-delivers the still-pending ones
        // with fresh ids.
        pending.removeAll()
        clientID = nil
      }
      if Task.isCancelled { break }
      if carried { attempt = 0 }

      attempt += 1
      if let maximum = reconnect.maximumAttempts, attempt > maximum {
        publish(connection: .stopped)
        return
      }
      publish(connection: .reconnecting(attempt: attempt))
      if (try? await Task.sleep(for: reconnect.delay(beforeAttempt: attempt))) == nil { break }
    }
    clientID = nil
  }

  /// Fold one frame into the pending queues.
  private func handle(_ frame: RemoteEventFrame) async {
    switch frame {
    case .ready(let id):
      clientID = id
    case .waterfall(let eventID, let agentID, let event, let request):
      // Two waterfalls are ours; everything else belongs to another UI and is left alone
      // rather than half-rendered.
      guard event == "approval/request" || event == "user-questions/request" else { return }
      guard let route = await router(agentID) else { return }

      let entry: PendingPrompt
      if event == "approval/request" {
        entry = .approval(PendingApproval(
          eventID: eventID,
          sessionID: agentID,
          toolName: request["toolName"]?.stringValue ?? "未知工具",
          reason: request["reason"]?.stringValue,
          isBorrowed: route.isBorrowed
        ))
      } else {
        guard let question = QuestionPrompt.decode(
          request, eventID: eventID, sessionID: agentID, isBorrowed: route.isBorrowed
        ) else { return }
        entry = .question(question)
      }

      // A reconnect re-delivers every request the host still holds. Without this guard the
      // user would be asked the same question twice and the second copy would be unanswerable.
      if pending[route.address]?.contains(where: { $0.eventID == eventID }) == true { return }

      pending[route.address, default: []].append(entry)
      let queued = pending[route.address]?.count ?? 1
      await prompt(route.address, Self.text(for: entry, queuePosition: queued))
    case .cancel(let eventID):
      guard let removed = remove(eventID: eventID) else { return }
      await onCancelled?(removed.address, removed.prompt.kindLabel)
    case .emit:
      return
    }
  }

  /// Drop one request wherever it is queued, reporting the address it belonged to.
  private func remove(eventID: String) -> (address: String, prompt: PendingPrompt)? {
    guard let address = pending.first(where: { $0.value.contains { $0.eventID == eventID } })?.key,
          let index = pending[address]?.firstIndex(where: { $0.eventID == eventID }),
          let removed = pending[address]?.remove(at: index)
    else { return nil }
    if pending[address]?.isEmpty == true { pending[address] = nil }
    return (address, removed)
  }

  /// Answer from a bare reply — the words a phone user types without a command.
  ///
  /// Only approvals and plan reviews are recognised this way. A plain 「2」 is not an answer to
  /// a multiple-choice question, because it is also perfectly good chat content; the explicit
  /// `/answer 2` is what tells the two apart. A plan review is the exception: it is *only*
  /// answered in bare words — 批准, 拒绝 or an opinion — so while it is open, nothing the phone
  /// types can be content.
  @discardableResult
  public func submit(sender: String, text: String) async -> PromptOutcome {
    guard let first = pending[sender]?.first else { return .notADecision }
    switch first {
    case .approval:
      guard let decision = ApprovalReply.decide(text) else { return .notADecision }
      return await settle(
        sender: sender,
        value: .string(decision.rawValue),
        as: { .approval(decision) }
      )
    case .question(let question):
      // A plan review is the one question a phone answers without `/answer`: its answers are
      // 批准 / 拒绝 / an opinion, and none of them is chat content while the review is open.
      guard let review = PlanReview(question: question) else { return .notADecision }
      guard let verdict = review.verdict(naming: text) ?? PlanReviewReply.decide(text) else {
        return .problem(Self.planReviewHint)
      }
      return await settlePlanReview(sender: sender, review: review, verdict: verdict)
    }
  }

  /// Answer from an explicit `/answer …`.
  @discardableResult
  public func answer(sender: String, text: String) async -> PromptOutcome {
    guard let first = pending[sender]?.first else {
      return .problem("现在没有等待回答的问题。")
    }
    switch first {
    case .approval:
      // `/answer 批准` is a reasonable thing to type at an approval; say what works instead of
      // treating it as content and submitting it to the session.
      guard let decision = ApprovalReply.decide(text) else {
        return .problem("这是一条审批请求，回复「批准」或「拒绝」即可。")
      }
      return await settle(
        sender: sender,
        value: .string(decision.rawValue),
        as: { .approval(decision) }
      )
    case .question(let question):
      if let review = PlanReview(question: question) {
        // `/answer 1` still names the first printed option; anything else is the third answer.
        guard let verdict = review.verdict(naming: text) ?? PlanReviewReply.decide(text) else {
          return .problem(Self.planReviewHint)
        }
        return await settlePlanReview(sender: sender, review: review, verdict: verdict)
      }
      switch QuestionAnswerParser.parse(text, for: question) {
      case .problem(let message):
        return .problem(message)
      case .answers(let value):
        return await settle(sender: sender, value: value, as: { .answered("已回答。") })
      }
    }
  }

  /// What a plan review says when the reply was none of its three answers.
  static let planReviewHint =
    "这是计划评审：回复「批准」开始执行，「拒绝」让它继续改，或「说 你的意见」把意见带回去。"

  /// What a plan review needs to be answered: the question it belongs to, the option the host
  /// named as approval, and the option that means "keep planning" — the one that is not it.
  private struct PlanReview {
    var item: QuestionItem
    var approveLabel: String
    var declineLabel: String?

    init?(question: PendingQuestion) {
      guard question.items.count == 1,
            let item = question.items.first,
            let approve = item.approveLabel, !approve.isEmpty
      else { return nil }
      self.item = item
      self.approveLabel = approve
      self.declineLabel = item.optionLabels.first { $0 != approve }
    }

    /// The verdict a printed option — its number or its label — names, if the reply used one.
    func verdict(naming text: String) -> PlanReviewVerdict? {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if let index = Int(trimmed) {
        guard index >= 1, index <= item.optionLabels.count else { return nil }
        return verdict(forLabel: item.optionLabels[index - 1])
      }
      return verdict(forLabel: trimmed)
    }

    private func verdict(forLabel label: String) -> PlanReviewVerdict? {
      if label == approveLabel { return .approve }
      if label == declineLabel { return .keepPlanning(feedback: nil) }
      return nil
    }

    /// One verdict as the host's `answers` payload.
    ///
    /// Approving names the option the host named. Declining without words picks the declining
    /// option; declining *with* words sends no selection and the words in `custom` — the shape
    /// the GUI's own text field produces, and the one the host reads as feedback.
    func value(for verdict: PlanReviewVerdict) -> JSONValue {
      switch verdict {
      case .approve:
        return answer(selected: [approveLabel], custom: nil)
      case .keepPlanning(let feedback):
        guard let feedback, !feedback.isEmpty else {
          return answer(selected: declineLabel.map { [$0] } ?? [], custom: nil)
        }
        return answer(selected: [], custom: feedback)
      }
    }

    private func answer(selected: [String], custom: String?) -> JSONValue {
      var entry: [String: JSONValue] = [
        "id": .string(item.id),
        "selected": .array(selected.map { .string($0) }),
      ]
      if let custom, !custom.isEmpty { entry["custom"] = .string(custom) }
      return .object(["answers": .array([.object(entry)])])
    }
  }

  /// Send one plan review verdict, then say what it did.
  private func settlePlanReview(
    sender: String,
    review: PlanReview,
    verdict: PlanReviewVerdict
  ) async -> PromptOutcome {
    let value = review.value(for: verdict)
    let confirmation: String
    switch verdict {
    case .approve:
      confirmation = "已批准这个计划"
    case .keepPlanning(let feedback):
      confirmation = feedback == nil
        ? "已拒绝这个计划（让它继续改）"
        : "已把意见发回给它（继续改计划）"
    }
    return await settle(sender: sender, value: value, as: { .answered(confirmation) })
  }

  /// Send one answer, then drop the request it settled.
  private func settle(
    sender: String,
    value: JSONValue,
    as transform: () -> PromptOutcome
  ) async -> PromptOutcome {
    guard let entry = pending[sender]?.first else { return .notADecision }
    do {
      try await stream.answer(eventID: entry.eventID, value: value)
      pending[sender]?.removeFirst()
      if pending[sender]?.isEmpty == true { pending[sender] = nil }
      return transform()
    } catch {
      // Keep the request pending so the user can try again, and say why it did not land.
      let reason = (error as? HarnessAPIError)?.message ?? String(describing: error)
      return .problem("答复没能送到 harness：\(reason)")
    }
  }

  /// The text the user sees for one forwarded request.
  public static func text(for prompt: PendingPrompt, queuePosition: Int = 1) -> String {
    switch prompt {
    case .approval(let approval):
      return questionText(for: approval, queuePosition: queuePosition)
    case .question(let question):
      return QuestionPrompt.text(for: question, queuePosition: queuePosition)
    }
  }

  /// The text the user sees for one approval. Names the tool and, when the asker gave one,
  /// the reason.
  public static func questionText(for entry: PendingApproval, queuePosition: Int = 1) -> String {
    var lines = ["⚠️ harness 需要你的允许"]
    if entry.isBorrowed {
      // Answering this grants a tool call that the user never started from chat, so the
      // desktop origin is stated rather than left to be inferred.
      lines.append("（来自桌面会话 \(shortSessionID(entry.sessionID))）")
    }
    lines.append("")
    lines.append("工具：\(entry.toolName)")
    if let reason = entry.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("原因：\(reason.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    lines.append("")
    if queuePosition > 1 {
      lines.append("还有 \(queuePosition - 1) 条在你之后排队；回复只作用于这一条。")
      lines.append("")
    }
    lines.append("回复「批准」放行这一次，或「拒绝」不执行。")
    return lines.joined(separator: "\n")
  }

  /// The same text for a caller that only has the two fields.
  public static func questionText(toolName: String, reason: String?) -> String {
    questionText(
      for: PendingApproval(eventID: "", sessionID: "", toolName: toolName, reason: reason)
    )
  }

  /// Sessions are long uuids; the phone only needs enough to tell two of them apart.
  static func shortSessionID(_ sessionID: String) -> String {
    let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "未知" }
    return String(trimmed.prefix(8))
  }
}
