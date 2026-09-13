import Foundation

// MARK: - Event type

/// Event type names, as observed in real session logs.
///
/// 29 distinct types were observed across 32 recorded sessions; the constants below
/// cover every one of them, plus the PTC dispatch pair the tool catalog documents
/// (`tool/ptc-dispatch-start` / `tool/ptc-dispatch`) which only appears when the
/// registry runs under `mode: ptc`.
public struct EventType: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }

  public static let session = EventType("session")
  public static let sessionTitle = EventType("session/title")
  public static let sessionTitleRequest = EventType("session/title-llm-request")
  public static let sessionEndSeed = EventType("session/end-seed")

  public static let userMessage = EventType("user/message")
  public static let assistantMessage = EventType("assistant/message")
  public static let assistantChunk = EventType("assistant/chunk")

  public static let textChunks = EventType("text-chunks")
  public static let reasoningChunks = EventType("reasoning-chunks")
  public static let toolCallChunks = EventType("tool-call-chunks")

  public static let toolCall = EventType("tool/call")
  public static let toolResult = EventType("tool/result")
  public static let ptcDispatchStart = EventType("tool/ptc-dispatch-start")
  public static let ptcDispatch = EventType("tool/ptc-dispatch")

  public static let turnStart = EventType("turn/start")
  public static let turnEnd = EventType("turn/end")
  public static let stepStart = EventType("step/start")
  public static let stepEnd = EventType("step/end")

  public static let requestHeader = EventType("request/header")
  public static let requestContext = EventType("request/context")

  public static let approvalAsked = EventType("approval/asked")
  public static let approvalDecided = EventType("approval/decided")
  public static let approvalPolicy = EventType("approval/policy")

  public static let planMode = EventType("plan/mode")
  public static let todoWrite = EventType("todo/write")
  public static let goalChange = EventType("goal/change")

  public static let commandRun = EventType("command/run")
  public static let commandDone = EventType("command/done")

  public static let permissionPreset = EventType("permission/preset")
  public static let sandboxMode = EventType("sandbox/mode")

  public static let inboxSpliced = EventType("agent/inbox/spliced")
  public static let agentSpawned = EventType("agent/spawned")
  public static let agentClosed = EventType("agent/closed")

  public static let jobStarted = EventType("job/started")
  public static let jobFinished = EventType("job/finished")

  public static let teamMember = EventType("team/member")
  public static let teamTask = EventType("team/task")

  public static let scheduleChange = EventType("schedule/change")
  public static let searchRequest = EventType("web/deepseek-search-llm-request")
}

// MARK: - Envelope

/// The wire envelope of one session-log line.
///
/// Two envelope shapes exist in the recorded format:
/// - ordinary events carry `seq` / `time`;
/// - **packed-line** events (`text-chunks`, `reasoning-chunks`, `tool-call-chunks`)
///   carry `seq0` / `time0` and hold *arrays* of deltas. Getting this wrong is the
///   single easiest way to lose 12,953 of the events in a real session.
///
/// `surfaceOp` / `sourceEventSeqs` mark surface events: the events a UI is meant to
/// render. Everything else is bookkeeping.
public struct EventEnvelope: Sendable, Equatable, Codable {
  public var type: EventType
  /// Sequence number for ordinary events.
  public var seq: Int?
  /// Sequence number for packed-line events.
  public var seq0: Int?
  /// Epoch milliseconds for ordinary events.
  public var time: Double?
  /// Epoch milliseconds for packed-line events.
  public var time0: Double?
  public var surfaceOp: String?
  public var sourceEventSeqs: [Int]?
  /// Explicitly marked as safely skippable by an older reader.
  public var ignorable: Bool?
  public var data: JSONValue

  public init(
    type: EventType,
    seq: Int? = nil,
    seq0: Int? = nil,
    time: Double? = nil,
    time0: Double? = nil,
    surfaceOp: String? = nil,
    sourceEventSeqs: [Int]? = nil,
    ignorable: Bool? = nil,
    data: JSONValue = .object([:])
  ) {
    self.type = type
    self.seq = seq
    self.seq0 = seq0
    self.time = time
    self.time0 = time0
    self.surfaceOp = surfaceOp
    self.sourceEventSeqs = sourceEventSeqs
    self.ignorable = ignorable
    self.data = data
  }

  /// The event's own sequence number, whichever field carries it.
  public var effectiveSeq: Int { seq ?? seq0 ?? -1 }

  /// The event's own timestamp in milliseconds, whichever field carries it.
  public var effectiveTime: Double? { time ?? time0 }

  public var timestamp: Date? {
    guard let milliseconds = effectiveTime else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  /// True when this is one of the packed-line events.
  public var isPackedLine: Bool { seq == nil && seq0 != nil }

  /// True when the runtime intends a UI to render this event.
  public var isSurface: Bool { surfaceOp != nil || sourceEventSeqs != nil }

  private enum CodingKeys: String, CodingKey {
    case type, seq, seq0, time, time0, surfaceOp, sourceEventSeqs, ignorable, data
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.type = EventType((try? container.decode(String.self, forKey: .type)) ?? "unknown")
    self.seq = Self.flexibleInt(container, .seq)
    self.seq0 = Self.flexibleInt(container, .seq0)
    self.time = Self.flexibleDouble(container, .time)
    self.time0 = Self.flexibleDouble(container, .time0)
    self.surfaceOp = try? container.decodeIfPresent(String.self, forKey: .surfaceOp)
    self.sourceEventSeqs = try? container.decodeIfPresent([Int].self, forKey: .sourceEventSeqs)
    self.ignorable = try? container.decodeIfPresent(Bool.self, forKey: .ignorable)
    self.data = (try? container.decodeIfPresent(JSONValue.self, forKey: .data)) ?? .object([:])
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type.rawValue, forKey: .type)
    // Preserve which of the two sequence/timestamp pairs the event used: emitting
    // `seq` for a packed-line event would be a format change, not a convenience.
    try container.encodeIfPresent(seq, forKey: .seq)
    try container.encodeIfPresent(seq0, forKey: .seq0)
    try container.encodeIfPresent(time, forKey: .time)
    try container.encodeIfPresent(time0, forKey: .time0)
    try container.encodeIfPresent(surfaceOp, forKey: .surfaceOp)
    try container.encodeIfPresent(sourceEventSeqs, forKey: .sourceEventSeqs)
    try container.encodeIfPresent(ignorable, forKey: .ignorable)
    try container.encode(data, forKey: .data)
  }

  private static func flexibleInt(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
    return nil
  }

  private static func flexibleDouble(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
    return nil
  }
}

// MARK: - Session header

/// The first line of every session log.
public struct SessionHeader: Sendable, Equatable, Codable {
  public var id: SessionID
  public var version: Int
  public var createdAt: Double?
  public var cwd: String?
  public var delegationDepth: Int?
  public var agentPreset: String?

  public init(
    id: SessionID,
    version: Int = 3,
    createdAt: Double? = nil,
    cwd: String? = nil,
    delegationDepth: Int? = nil,
    agentPreset: String? = nil
  ) {
    self.id = id
    self.version = version
    self.createdAt = createdAt
    self.cwd = cwd
    self.delegationDepth = delegationDepth
    self.agentPreset = agentPreset
  }

  public static let currentFormatVersion = 3

  public init(json: JSONValue) {
    self.id = SessionID(json.string(at: "id") ?? "unknown")
    self.version = json.int(at: "version") ?? 0
    self.createdAt = json.doubleValue(at: "createdAt") ?? json.path("createdAt")?.doubleValue
    self.cwd = json.string(at: "cwd")
    self.delegationDepth = json.int(at: "delegationDepth")
    self.agentPreset = json.string(at: "agentPreset")
  }

  public var json: JSONValue {
    .object([
      "type": "session",
      "version": .number(Double(version)),
      "id": .string(id.rawValue),
      "createdAt": createdAt.map { .number($0) } ?? .null,
      "cwd": cwd.map { .string($0) } ?? .null,
      "delegationDepth": delegationDepth.map { .number(Double($0)) } ?? .null,
      "agentPreset": agentPreset.map { .string($0) } ?? .null,
    ])
  }
}

private extension JSONValue {
  func doubleValue(at path: String) -> Double? { self.path(path)?.doubleValue }
}

// MARK: - Session event

/// One decoded session-log event: the raw envelope plus typed accessors.
///
/// The raw `data` is always retained, so an event from a newer engine survives a
/// read/write cycle unchanged. Typed accessors are pure functions of `data` and
/// never fail.
public struct SessionEvent: Sendable, Equatable, Identifiable {
  public var envelope: EventEnvelope

  /// The exact log line this event was read from, when it came from a log. Kept so
  /// that a read/write cycle is byte-identical despite `JSONValue` objects not
  /// preserving key order (see `SessionLogCodec`).
  public var rawLine: String?

  public init(envelope: EventEnvelope, rawLine: String? = nil) {
    self.envelope = envelope
    self.rawLine = rawLine
  }

  public var type: EventType { envelope.type }
  public var data: JSONValue { envelope.data }
  public var seq: Int { envelope.effectiveSeq }
  public var timestamp: Date? { envelope.timestamp }

  /// Stable identity for list rendering. Falls back to a content hash for
  /// sequence-less synthetic events.
  public var id: String {
    if envelope.effectiveSeq >= 0 { return "\(envelope.effectiveSeq)-\(type.rawValue)" }
    return "\(type.rawValue)-\(data.hashValue)"
  }

  /// The typed discriminator the UI switches on.
  public var kind: EventKind { EventKind(type: type) }

  /// The event re-serialized in log form: the envelope plus `data`, with the header
  /// event flattened back to its top-level shape.
  public var json: JSONValue {
    if kind == .sessionHeader {
      var value = data
      if var object = value.objectValue {
        object["type"] = .string("session")
        value = .object(object)
      }
      return value
    }
    var object: [String: JSONValue] = ["type": .string(type.rawValue)]
    if let seq = envelope.seq { object["seq"] = .number(Double(seq)) }
    if let seq0 = envelope.seq0 { object["seq0"] = .number(Double(seq0)) }
    if let time = envelope.time { object["time"] = .number(time) }
    if let time0 = envelope.time0 { object["time0"] = .number(time0) }
    if let surfaceOp = envelope.surfaceOp { object["surfaceOp"] = .string(surfaceOp) }
    if let sourceEventSeqs = envelope.sourceEventSeqs {
      object["sourceEventSeqs"] = .array(sourceEventSeqs.map { .number(Double($0)) })
    }
    if let ignorable = envelope.ignorable { object["ignorable"] = .bool(ignorable) }
    object["data"] = data
    return .object(object)
  }

  public enum EventKind: Sendable, Equatable {
    case sessionHeader
    case userMessage
    case assistantMessage
    case assistantChunk
    case textChunk
    case reasoningChunk
    case toolCallChunk
    case toolCall
    case toolResult
    case ptcDispatchStart
    case ptcDispatch
    case turnStart
    case turnEnd
    case stepStart
    case stepEnd
    case requestHeader
    case requestContext
    case approvalAsked
    case approvalDecided
    case approvalPolicy
    case planMode
    case todoWrite
    case goalChange
    case sessionTitle
    case commandRun
    case commandDone
    case permissionPreset
    case sandboxMode
    case inboxSpliced
    case agentLifecycle
    case jobLifecycle
    case teamChange
    case scheduleChange
    case unknown(String)

    init(type: EventType) {
      switch type {
      case .session: self = .sessionHeader
      case .userMessage: self = .userMessage
      case .assistantMessage: self = .assistantMessage
      case .assistantChunk: self = .assistantChunk
      case .textChunks: self = .textChunk
      case .reasoningChunks: self = .reasoningChunk
      case .toolCallChunks: self = .toolCallChunk
      case .toolCall: self = .toolCall
      case .toolResult: self = .toolResult
      case .ptcDispatchStart: self = .ptcDispatchStart
      case .ptcDispatch: self = .ptcDispatch
      case .turnStart: self = .turnStart
      case .turnEnd: self = .turnEnd
      case .stepStart: self = .stepStart
      case .stepEnd: self = .stepEnd
      case .requestHeader: self = .requestHeader
      case .requestContext: self = .requestContext
      case .approvalAsked: self = .approvalAsked
      case .approvalDecided: self = .approvalDecided
      case .approvalPolicy: self = .approvalPolicy
      case .planMode: self = .planMode
      case .todoWrite: self = .todoWrite
      case .goalChange: self = .goalChange
      case .sessionTitle: self = .sessionTitle
      case .commandRun: self = .commandRun
      case .commandDone: self = .commandDone
      case .permissionPreset: self = .permissionPreset
      case .sandboxMode: self = .sandboxMode
      case .inboxSpliced: self = .inboxSpliced
      case .agentSpawned, .agentClosed: self = .agentLifecycle
      case .jobStarted, .jobFinished: self = .jobLifecycle
      case .teamMember, .teamTask: self = .teamChange
      case .scheduleChange: self = .scheduleChange
      default: self = .unknown(type.rawValue)
      }
    }
  }
}

// MARK: - Typed payload views

extension SessionEvent {
  public var header: SessionHeader? {
    guard kind == .sessionHeader else { return nil }
    return SessionHeader(json: data.merging(["type": .string("session")]))
  }

  /// `user/message` → one rendered message.
  public var userMessage: ConversationMessage? {
    guard kind == .userMessage else { return nil }
    let blocks = (data.path("content")?.arrayValue ?? []).map(ContentBlock.init(json:))
    let source = try? data.path("source")?.decoded(as: MessageSource.self)
    return ConversationMessage(
      id: data.string(at: "id") ?? "user-\(seq)",
      role: .user,
      content: blocks,
      seq: envelope.seq,
      time: timestamp,
      source: source ?? nil
    )
  }

  /// `assistant/message` → one rendered message, with usage and step/turn.
  public var assistantMessage: ConversationMessage? {
    guard kind == .assistantMessage else { return nil }
    let messageValue = data.path("message")
    let blocks = (messageValue?.path("content")?.arrayValue ?? []).map(ContentBlock.init(json:))
    let usage = try? data.path("usage")?.decoded(as: Usage.self)
    let source = try? messageValue?.path("source")?.decoded(as: MessageSource.self)
    return ConversationMessage(
      id: messageValue?.string(at: "id") ?? "assistant-\(seq)",
      role: .assistant,
      content: blocks,
      seq: envelope.seq,
      time: timestamp,
      turn: data.int(at: "turn"),
      step: data.int(at: "step"),
      usage: usage ?? nil,
      source: source ?? nil,
      interrupted: data.bool(at: "interrupted") ?? false
    )
  }

  /// `tool/call`. Note `arguments` is a **string** on the wire, not an object.
  public var toolCall: ToolCallPayload? {
    guard kind == .toolCall else { return nil }
    guard let callId = data.string(at: "callId"), let name = data.string(at: "name") else { return nil }
    return ToolCallPayload(
      callId: callId,
      name: name,
      arguments: data.string(at: "arguments") ?? "{}",
      turn: data.int(at: "turn"),
      step: data.int(at: "step"),
      time: timestamp
    )
  }

  /// `tool/result`.
  public var toolResult: ToolResultPayload? {
    guard kind == .toolResult else { return nil }
    let callId = data.string(at: "message.source.callId")
      ?? data.string(at: "callId")
      ?? ""
    let blocks = (data.path("message.content")?.arrayValue ?? []).map(ContentBlock.init(json:))
    let errorCode = data.string(at: "error.code")
    let errorName = data.string(at: "error.name")
    return ToolResultPayload(
      callId: callId,
      content: blocks,
      isError: errorCode != nil || errorName != nil,
      errorCode: errorCode,
      errorName: errorName,
      kind: data.string(at: "message.source.kind"),
      time: timestamp
    )
  }

  /// The two PTC dispatch envelopes. `start` opens a nested sub-call, `dispatch`
  /// closes it — this pair is what builds the program-call tree.
  public var ptcDispatch: PTCDispatchPayload? {
    switch kind {
    case .ptcDispatchStart:
      return PTCDispatchPayload(
        callId: data.string(at: "callId") ?? data.string(at: "id") ?? "",
        parentCallId: data.string(at: "parentCallId"),
        toolName: data.string(at: "toolName") ?? data.string(at: "name"),
        phase: .start,
        time: timestamp
      )
    case .ptcDispatch:
      return PTCDispatchPayload(
        callId: data.string(at: "callId") ?? data.string(at: "id") ?? "",
        parentCallId: data.string(at: "parentCallId"),
        toolName: data.string(at: "toolName") ?? data.string(at: "name"),
        phase: .finish,
        time: timestamp
      )
    default:
      return nil
    }
  }

  public var approvalAsked: ApprovalRequest? {
    guard kind == .approvalAsked else { return nil }
    return ApprovalRequest(
      id: data.string(at: "id") ?? "approval-\(seq)",
      toolName: data.string(at: "toolName") ?? "unknown",
      callId: data.string(at: "callId"),
      reason: data.string(at: "reason") ?? "",
      requestedAt: timestamp
    )
  }

  public var approvalDecided: ApprovalDecision? {
    guard kind == .approvalDecided else { return nil }
    return ApprovalDecision(
      id: data.string(at: "id") ?? "",
      outcome: ApprovalDecision.Outcome(rawValue: data.string(at: "outcome") ?? ""),
      decidedAt: timestamp
    )
  }

  public var todoWrite: [TodoItem]? {
    guard kind == .todoWrite else { return nil }
    return (data.path("todos")?.arrayValue ?? []).map { value in
      TodoItem(
        content: value.string(at: "content") ?? "",
        status: TodoItem.Status(rawValue: value.string(at: "status") ?? "") ?? .pending,
        activeForm: value.string(at: "activeForm")
      )
    }
  }

  public var planModeActive: Bool? {
    guard kind == .planMode else { return nil }
    return data.bool(at: "active")
  }

  public var requestContext: RequestContextPayload? {
    guard kind == .requestContext else { return nil }
    return RequestContextPayload(
      contextWindow: data.int(at: "contextWindow"),
      model: data.string(at: "model"),
      provider: data.string(at: "provider")
    )
  }

  /// `request/header` — the exact specification sent to the model.
  ///
  /// This is the consistency baseline: `system` is the fully rendered system
  /// prompt, `tools` the exact schema array the model saw.
  public var requestHeader: RequestHeaderPayload? {
    guard kind == .requestHeader else { return nil }
    let header = data.path("header") ?? data
    let tools = (header.path("tools")?.arrayValue ?? []).compactMap { value -> ToolDescriptor? in
      guard let name = value.string(at: "name") else { return nil }
      return ToolDescriptor(
        name: name,
        description: value.string(at: "description") ?? "",
        parameters: value.path("parameters") ?? .object([:]),
        category: ToolCategory(name: name),
        origin: .model
      )
    }
    let config = header.path("config")
    return RequestHeaderPayload(
      system: header.string(at: "system") ?? "",
      tools: tools,
      config: ModelConfig(
        model: config?.string(at: "model"),
        provider: config?.string(at: "provider"),
        reasoningEffort: config?.string(at: "reasoningEffort"),
        maxTokens: config?.int(at: "maxTokens")
      ),
      adapterDefaults: header.path("adapterDefaults")
    )
  }

  public var sessionTitle: String? {
    guard kind == .sessionTitle else { return nil }
    return data.string(at: "title")
  }

  public var commandRun: CommandPayload? {
    guard kind == .commandRun else { return nil }
    return CommandPayload(
      name: data.string(at: "name") ?? data.string(at: "command") ?? "",
      arguments: data.string(at: "arguments") ?? "",
      phase: .start
    )
  }

  public var commandDone: CommandPayload? {
    guard kind == .commandDone else { return nil }
    return CommandPayload(
      name: data.string(at: "name") ?? data.string(at: "command") ?? "",
      arguments: data.string(at: "arguments") ?? "",
      phase: .finish
    )
  }

  public var turnNumber: Int? {
    switch kind {
    case .turnStart, .turnEnd, .stepStart, .stepEnd, .assistantMessage:
      return data.int(at: "turn")
    default:
      return nil
    }
  }

  public var stepNumber: Int? {
    switch kind {
    case .stepStart, .stepEnd, .assistantMessage:
      return data.int(at: "step")
    default:
      return nil
    }
  }

  /// `turn/end` reason, flattened from the nested `{kind: {kind: ...}}` shape.
  public var turnEndReason: String? {
    guard kind == .turnEnd else { return nil }
    if let nested = data.string(at: "reason.kind") { return nested }
    if let flat = data.string(at: "reason") { return flat }
    return nil
  }
}

// MARK: - Payload types

public struct ToolCallPayload: Sendable, Equatable {
  public var callId: String
  public var name: String
  /// Raw argument JSON text as it arrived.
  public var arguments: String
  public var turn: Int?
  public var step: Int?
  public var time: Date?

  public init(callId: String, name: String, arguments: String, turn: Int? = nil, step: Int? = nil, time: Date? = nil) {
    self.callId = callId
    self.name = name
    self.arguments = arguments
    self.turn = turn
    self.step = step
    self.time = time
  }

  public var parsedArguments: JSONValue {
    (try? JSONValue.parse(arguments, context: "tool/call.arguments")) ?? .object([:])
  }
}

public struct ToolResultPayload: Sendable, Equatable {
  public var callId: String
  public var content: [ContentBlock]
  public var isError: Bool
  public var errorCode: String?
  public var errorName: String?
  /// `message.source.kind` — e.g. the name of the tool that produced it.
  public var kind: String?
  public var time: Date?

  public init(
    callId: String,
    content: [ContentBlock],
    isError: Bool,
    errorCode: String? = nil,
    errorName: String? = nil,
    kind: String? = nil,
    time: Date? = nil
  ) {
    self.callId = callId
    self.content = content
    self.isError = isError
    self.errorCode = errorCode
    self.errorName = errorName
    self.kind = kind
    self.time = time
  }

  public var text: String {
    content.compactMap(\.textValue).joined()
  }

  public var attachments: [Attachment] {
    content.compactMap { block -> Attachment? in
      if case .image(let attachment) = block { return attachment }
      return nil
    }
  }
}

/// One step of a PTC (programmatic tool calling) dispatch pair.
public struct PTCDispatchPayload: Sendable, Equatable {
  public enum Phase: String, Sendable { case start, finish }
  public var callId: String
  public var parentCallId: String?
  public var toolName: String?
  public var phase: Phase
  public var time: Date?

  public init(callId: String, parentCallId: String? = nil, toolName: String? = nil, phase: Phase, time: Date? = nil) {
    self.callId = callId
    self.parentCallId = parentCallId
    self.toolName = toolName
    self.phase = phase
    self.time = time
  }
}

public struct RequestContextPayload: Sendable, Equatable {
  public var contextWindow: Int?
  public var model: String?
  public var provider: String?

  public init(contextWindow: Int? = nil, model: String? = nil, provider: String? = nil) {
    self.contextWindow = contextWindow
    self.model = model
    self.provider = provider
  }
}

public struct RequestHeaderPayload: Sendable, Equatable {
  public var system: String
  public var tools: [ToolDescriptor]
  public var config: ModelConfig
  public var adapterDefaults: JSONValue?

  public init(system: String, tools: [ToolDescriptor], config: ModelConfig, adapterDefaults: JSONValue? = nil) {
    self.system = system
    self.tools = tools
    self.config = config
    self.adapterDefaults = adapterDefaults
  }
}

public struct ModelConfig: Sendable, Equatable, Codable {
  public var model: String?
  public var provider: String?
  public var reasoningEffort: String?
  public var maxTokens: Int?

  public init(model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil, maxTokens: Int? = nil) {
    self.model = model
    self.provider = provider
    self.reasoningEffort = reasoningEffort
    self.maxTokens = maxTokens
  }
}

public struct CommandPayload: Sendable, Equatable {
  public enum Phase: String, Sendable { case start, finish }
  public var name: String
  public var arguments: String
  public var phase: Phase

  public init(name: String, arguments: String, phase: Phase) {
    self.name = name
    self.arguments = arguments
    self.phase = phase
  }
}
