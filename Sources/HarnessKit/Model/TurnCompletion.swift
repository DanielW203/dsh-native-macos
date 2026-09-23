import Foundation

/// One frame of the harness's `session/follow` stream.
///
/// The stream's durable vocabulary is two shapes — an opening `snapshot` and then a series of
/// `event` entries — plus process-local assistant frames the caller may opt out of. Only what a
/// caller can act on is modelled: the opening frame's cursor, and each record's envelope. The
/// payload of an event is kept as the raw `JSONValue` because its shape depends on the event's
/// own type, which is the reader's business rather than this type's.
///
/// Parsing is total and forward-compatible, exactly like the forwarded-event stream: a frame whose
/// `type` is unknown is `nil` rather than an error. The harness is allowed to add frame kinds, and
/// a watcher that only wants turn boundaries must not break when it does.
/// One durable event inside a snapshot page.
///
/// The page a follow stream opens with is history: the newest events the log already holds. A
/// watcher that only ever reads live frames throws that away — right for the *first* subscription,
/// and wrong for a re-subscription, where the page is precisely the gap the ended stream left. The
/// records are kept (not just the cursor) so a caller can tell those two cases apart.
public struct SessionFollowRecord: Sendable, Equatable {
  public var type: String
  public var seq: Int?
  public var turn: Int?
  public var data: JSONValue

  public init(type: String, seq: Int? = nil, turn: Int? = nil, data: JSONValue = .null) {
    self.type = type
    self.seq = seq
    self.turn = turn
    self.data = data
  }

  /// Decode one page entry.
  ///
  /// The page and the live stream use the same envelope — `{type:"event", event:{…}}` — so a record
  /// carries exactly the fields a frame's payload carries, and the two can be fed to one decoder.
  public static func parse(_ value: JSONValue) -> SessionFollowRecord? {
    guard let event = value["event"], let type = event["type"]?.stringValue else { return nil }
    return SessionFollowRecord(
      type: type,
      seq: event["seq"]?.intValue,
      turn: event["data"]?["turn"]?.intValue,
      data: event["data"] ?? .null
    )
  }
}

/// One paragraph of plain assistant text, published while its turn is still running.
///
/// The transcript's own unit, not a summary of it. `assistant/message` is committed once per model
/// step, so a turn that narrates between tool calls ("先给 C 层加进程枚举…") and then answers
/// produces one of these per step that had something to say — which is exactly the white text the
/// GUI shows, and the reason this exists separately from `TurnCompletion`: a watcher that only
/// looked at endings could only ever forward the *last* paragraph.
///
/// **Text blocks only, and reasoning is not text.** `ContentBlock.text` joins the plain `text`
/// blocks and drops `reasoning`; folding reasoning in would push the model's thinking to a phone
/// while the answer stayed behind, which is the same trap `SessionReplyExtractor` documents.
///
/// The segment is a value, not a claim about the log: it carries the cursor it was seen at, so a
/// forwarder can tell a replayed frame from a live one, and the session's display name so a message
/// on a phone can say which conversation it belongs to without a second lookup.
public struct AssistantTextSegment: Sendable, Equatable {
  public var sessionID: String
  /// The session's display name at the moment the frame arrived, when the caller knows it.
  public var sessionTitle: String?
  /// Whether the text came from a subagent's session. Carried so a forwarder can apply the same
  /// quiet-by-default rule it applies to a subagent's endings.
  public var isSubagent: Bool
  public var turn: Int?
  public var step: Int?
  /// The durable sequence of the `assistant/message` event this was read from, when there is one.
  public var seq: Int?
  public var text: String

  public init(
    sessionID: String,
    sessionTitle: String? = nil,
    isSubagent: Bool = false,
    turn: Int? = nil,
    step: Int? = nil,
    seq: Int? = nil,
    text: String
  ) {
    self.sessionID = sessionID
    self.sessionTitle = sessionTitle
    self.isSubagent = isSubagent
    self.turn = turn
    self.step = step
    self.seq = seq
    self.text = text
  }

  /// Decode one durable session event, or `nil` when it is not assistant text worth forwarding.
  ///
  /// Total and forward-compatible, like the rest of this file: a step that only called tools has an
  /// `assistant/message` with no text blocks, and that is an ordinary `nil` rather than an error —
  /// it is most steps. The text is trimmed here, once, so every consumer compares the same string:
  /// the turn-end reply this is deduplicated against comes from the same blocks.
  public static func decode(
    sessionID: String,
    eventType: String,
    seq: Int? = nil,
    data: JSONValue
  ) -> AssistantTextSegment? {
    guard eventType == EventType.assistantMessage.rawValue else { return nil }
    let blocks = (data.path("message.content")?.arrayValue ?? []).map(ContentBlock.init(json:))
    let text = blocks.compactMap { block -> String? in
      if case .text(let value) = block { return value }
      return nil
    }.joined()
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return AssistantTextSegment(
      sessionID: sessionID,
      turn: data.int(at: "turn"),
      step: data.int(at: "step"),
      seq: seq,
      text: trimmed
    )
  }
}

public enum SessionFollowFrame: Sendable, Equatable {
  /// The opening frame. `cursor` is the log cut the snapshot was taken at, so a reader can page
  /// history with `session/page` without racing the live stream. `records` is that cut's own page of
  /// history, which a reconnecting reader needs in order not to lose what happened while it was
  /// away.
  case snapshot(cursor: Int, records: [SessionFollowRecord])
  /// One durable session event.
  case event(type: String, seq: Int?, turn: Int?, data: JSONValue)
  /// One process-local assistant presentation frame, which this client never asks for.
  case assistantStream
  /// A frame this version does not know: recognised as a frame, but not as one of ours.
  case unrecognized(type: String)

  public static func parse(_ value: JSONValue) -> SessionFollowFrame? {
    guard let type = value["type"]?.stringValue else { return nil }
    switch type {
    case "snapshot":
      // `cursor` is documented as a number and is the only field this frame needs; a snapshot
      // without it still opens the stream, so it defaults rather than failing the frame.
      return .snapshot(
        cursor: value["cursor"]?.intValue ?? 0,
        records: (value["records"]?.arrayValue ?? []).compactMap { SessionFollowRecord.parse($0) }
      )
    case "event":
      guard let event = value["event"] else { return nil }
      guard let eventType = event["type"]?.stringValue else { return nil }
      return .event(
        type: eventType,
        seq: event["seq"]?.intValue,
        turn: event["data"]?["turn"]?.intValue,
        data: event["data"] ?? .null
      )
    case "assistant-stream":
      return .assistantStream
    default:
      return .unrecognized(type: type)
    }
  }

  /// The event type, for the frames that carry one.
  public var eventType: String? {
    if case .event(let type, _, _, _) = self { return type }
    return nil
  }
}

/// Why a turn ended, as the harness reports it.
///
/// The vocabulary is `TurnEndReason` from the session package, and it is a merge-extensible sum
/// type: a plugin may add a variant. Everything not recognised is `.unknown`, which is deliberately
/// *not* a failure state — a newer harness with a new reason must not make this app report an error.
public enum TurnEndKind: String, Sendable, Equatable {
  /// The turn finished normally.
  case completed
  /// At least one step hit the output-token ceiling.
  case maxTokens = "max-tokens"
  /// The turn was refused rather than run.
  case blocked
  /// A cancellation interrupted the live turn. Classified apart from the two failure kinds because
  /// the user asked for it: a notification would be announcing their own action back to them.
  case aborted
  /// The turn failed, and `error` carries the structured failure.
  case error
  /// A crash-orphaned turn closed after the fact on resume. Not a live ending.
  case interrupted
  /// A reason this version does not know.
  case unknown

  /// Map a wire `kind` onto the vocabulary.
  ///
  /// A explicit switch rather than `init?(rawValue:)`: `TurnEndKind` conforms to
  /// `RawRepresentable`, so `TurnEndKind(rawValue:)` looks like the synthesised failable
  /// initializer while actually being shadowed by this enum's own `rawValue` case, which is a
  /// recursion waiting to happen. Naming the mapping removes the question.
  public static func fromWire(_ wire: String) -> TurnEndKind {
    switch wire {
    case "completed": return .completed
    case "max-tokens": return .maxTokens
    case "blocked": return .blocked
    case "aborted": return .aborted
    case "error": return .error
    case "interrupted": return .interrupted
    default: return .unknown
    }
  }

  /// A turn that reached an end the user was waiting for.
  ///
  /// `max-tokens` counts: the turn stopped for a reason worth telling the user about, and the
  /// alternative is silence on a real "your work stopped early" event.
  public var isCompletion: Bool { self == .completed || self == .maxTokens }

  /// A turn that failed.
  public var isFailure: Bool { self == .error || self == .blocked }

  /// Whether this ending is worth a system notification at all.
  ///
  /// `aborted` and `interrupted` are excluded: the first is the user's own stop, and the second is
  /// a recovery artifact rather than something that just happened. `unknown` is excluded because
  /// announcing a state this version cannot name would be guessing.
  public var deservesNotification: Bool { isCompletion || isFailure }
}

/// One turn ending, as far as a notification needs to know about it.
public struct TurnCompletion: Sendable, Equatable {
  /// The session the turn belongs to.
  public var sessionID: String
  /// The session's title when the caller had one, for the notification body.
  public var sessionTitle: String?
  /// The turn number the harness assigned.
  public var turn: Int?
  public var kind: TurnEndKind
  /// `reason.error.code` when the turn failed with a structured failure.
  public var failureCode: String?
  /// `reason.error.message` when the turn failed.
  public var failureMessage: String?
  /// Whether the session is a subagent's, which the caller decides from the session list.
  public var isSubagent: Bool
  /// The session's working directory, when the caller had one.
  ///
  /// Carried for one reason: a session's log is found under a path derived from this value, so
  /// anything that wants to read what a finished turn *said* — the phone forwarder does — cannot
  /// locate it without it. Optional because a notification does not need it, and a caller with no
  /// session list (a test, a decode from a bare frame) must still be able to make one.
  public var cwd: String?

  public init(
    sessionID: String,
    sessionTitle: String? = nil,
    turn: Int? = nil,
    kind: TurnEndKind,
    failureCode: String? = nil,
    failureMessage: String? = nil,
    isSubagent: Bool = false,
    cwd: String? = nil
  ) {
    self.sessionID = sessionID
    self.sessionTitle = sessionTitle
    self.turn = turn
    self.kind = kind
    self.failureCode = failureCode
    self.failureMessage = failureMessage
    self.isSubagent = isSubagent
    self.cwd = cwd
  }

  /// Decode one `turn/end` event.
  ///
  /// Returns `nil` for any other event type so a caller can hand every frame straight in. A
  /// `turn/end` whose payload is unreadable becomes `.unknown` rather than nil: the turn did end,
  /// and dropping that fact silently is worse than reporting an unnamed ending.
  public static func decode(
    sessionID: String,
    eventType: String,
    data: JSONValue,
    sessionTitle: String? = nil,
    isSubagent: Bool = false,
    cwd: String? = nil
  ) -> TurnCompletion? {
    guard eventType == EventType.turnEnd.rawValue else { return nil }
    let reason = data["reason"]
    let rawKind = reason?["kind"]?.stringValue ?? ""
    let kind = TurnEndKind.fromWire(rawKind)
    let failure = reason?["error"]
    return TurnCompletion(
      sessionID: sessionID,
      sessionTitle: sessionTitle,
      turn: data["turn"]?.intValue,
      kind: kind,
      failureCode: failure?["code"]?.stringValue,
      failureMessage: failure?["message"]?.stringValue,
      isSubagent: isSubagent,
      cwd: cwd
    )
  }
}
