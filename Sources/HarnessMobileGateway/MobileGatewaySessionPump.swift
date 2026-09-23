import Foundation
import HarnessKit

// This file holds the *conversation* half of the mobile gateway's push path: the wire
// encoder for durable session events, the conversation-view history sizer, the
// `session/follow` decoder, and the pump that ties them to one subscribed connection.
// The three shared helpers (`MobileGatewayStreamError`, `MobileGatewayFollowPolicy`,
// `MobileGatewayPumpRun`) are also used by `MobileGatewayControlPump.swift`.

// MARK: - Faults

/// One fault from a host stream, reduced to the two fields the wire actually needs.
///
/// `code` is `nil` for a *protocol* fault the decoder itself raised — the plugin's
/// `new Error('…')` carries no `code`, and that absence is load-bearing: it is what makes
/// a continuity break transient (`code: "stream-interrupted"`, `retrying: true`) instead
/// of a permanent refusal the follower must stop retrying.
struct MobileGatewayStreamError: Error, Sendable, Equatable, CustomStringConvertible {
  var code: String?
  var message: String

  init(code: String? = nil, message: String) {
    self.code = code
    self.message = message
  }

  var description: String {
    guard let code else { return message }
    return "\(code): \(message)"
  }
}

/// Reported to `MobileGatewaySessionPump.onFailure`.
///
/// The matching `session-stream-reset` frame has **already** been handed to `onFrame` by
/// the time this arrives — the pump, not the service, owns the reset frame because
/// `streamId` only exists for the duration of one upstream opening. This error exists so
/// the service can log the reason and tear down a subscription that will never recover.
struct MobileGatewaySessionFailure: Error, Sendable, Equatable, CustomStringConvertible {
  var code: String
  var message: String
  var sessionID: String
  var subscriptionID: String
  var streamID: String
  /// Always `false`: a transient fault is retried with backoff and is not reported here.
  var retrying: Bool

  var description: String {
    "session follow failed for \(sessionID) stream \(streamID): \(code) — \(message)"
  }
}

/// The plugin's permanent/transient split for a failed follow opening (spec 03 §B.6.4).
enum MobileGatewayFollowPolicy {
  static func code(of error: Error) -> String? {
    if let error = error as? MobileGatewayStreamError { return error.code }
    if let error = error as? MobileGatewayHostError { return error.code }
    return nil
  }

  static func message(of error: Error) -> String {
    if let error = error as? MobileGatewayStreamError { return error.message }
    if let error = error as? MobileGatewayHostError { return error.message }
    return (error as NSError).localizedDescription
  }

  /// The wire `code`, defaulting exactly the way `error.code || 'stream-interrupted'` does.
  static func wireCode(of error: Error) -> String {
    code(of: error) ?? "stream-interrupted"
  }

  /// A refusal the follower must not retry: three fixed codes, plus the one persistence
  /// failure whose *message* is the only thing separating "the host hiccuped" from "this
  /// Session format will never be readable by this adapter".
  static func isPermanent(_ error: Error) -> Bool {
    let code = code(of: error)
    if let code, ["unsupported-session-format", "session/not-found", "gateway/bad-request"].contains(code) {
      return true
    }
    guard code == "SESSION_QUERY_PERSISTENCE_FAILED" else { return false }
    return message(of: error).range(of: "refuses this format .*Session", options: .regularExpression) != nil
  }
}

// MARK: - JS number semantics

/// `Number.isSafeInteger`, which `JSONValue.intValue` deliberately is not.
///
/// `intValue` truncates (3.7 ⇒ 3) and accepts numeric strings, so a fractional `seq` or a
/// quoted revision would slip past a validity gate that the reference implementation
/// closes. Every numeric guard in the follow decoder goes through here.
enum MobileGatewayNumbers {
  static let maxSafeInteger = 9_007_199_254_740_991.0

  static func safeInteger(_ value: JSONValue?) -> Int? {
    guard case .number(let number)? = value, number.isFinite,
          number.rounded(.towardZero) == number,
          abs(number) <= maxSafeInteger,
          let integer = Int(exactly: number) else { return nil }
    return integer
  }

  /// `integer(value, minimum = 0)` from `session-follower.mjs`.
  static func integer(_ value: JSONValue?, minimum: Int = 0) -> Int? {
    guard let integer = safeInteger(value), integer >= minimum else { return nil }
    return integer
  }
}

// MARK: - JS string semantics

/// `String.prototype.length` / `String.prototype.slice` — both count UTF-16 code units.
///
/// Counting grapheme clusters instead would disagree with the reference implementation for
/// anything outside the BMP, and the two caps in this file (400 preview, 2000 tool text)
/// are contract numbers the phone's client is written against.
enum MobileGatewayJSText {
  static func codeUnitCount(_ text: String) -> Int {
    text.utf16.count
  }

  static func prefixCodeUnits(_ text: String, _ limit: Int) -> String {
    let units = Array(text.utf16)
    guard units.count > limit else { return text }
    // A cut through a surrogate pair becomes U+FFFD: Swift's `String` cannot hold the lone
    // half that JS keeps and `JSON.stringify` would have escaped.
    return String(decoding: units[0..<limit], as: UTF16.self)
  }

  /// `String(value)`.
  ///
  /// `session/control` names its projection session with whatever the host put there, and
  /// the plugin stringifies it blind — including the `"undefined"` a missing id produces.
  /// Reproducing that here keeps the frame's `sessionId` and the pump's internal key
  /// identical in every case.
  static func string(_ value: JSONValue?) -> String {
    switch value {
    case .none: return "undefined"
    case .some(.null): return "null"
    case .some(.string(let text)): return text
    case .some(.bool(let flag)): return flag ? "true" : "false"
    case .some(.number(let number)):
      if let integer = MobileGatewayNumbers.safeInteger(value) { return String(integer) }
      return String(number)
    case .some(.array(let items)): return items.map { string($0) }.joined(separator: ",")
    case .some(.object): return "[object Object]"
    }
  }
}

// MARK: - Wire event construction

/// `buildWireEvent(session, event)` (spec 03 §B.2).
///
/// Reads only *leaf* fields of the host event and builds an owned JSON record: the live
/// host event is never re-serialized. That is not tidiness — the durable event is the one
/// thing the phone persists, so any host-side field that leaked through would become
/// protocol surface by accident.
///
/// There is no dropping and no coalescing on this path. Every event yields exactly one
/// frame; reduction happens only as field-level trimming (an unknown event type becomes
/// `{ type }` and nothing else).
enum MobileGatewayWireEvent {
  /// `MAX_PREVIEW` — how much tool-result text the chat bubble will ever show.
  static let maxToolResultPreview = 400

  static func build(sessionID: String, event: JSONValue) -> JSONValue {
    var base: [String: JSONValue] = [
      "kind": .string("event"),
      "sessionId": .string(sessionID),
    ]
    // `seq` and `time` are copied verbatim and are always present on a real event; an
    // absent one stays absent, the way an `undefined` key vanishes from `JSON.stringify`.
    if let seq = event["seq"] { base["seq"] = seq }
    if let time = event["time"] { base["time"] = time }
    if let surfaceOp = event["surfaceOp"] { base["surfaceOp"] = surfaceOp }
    if let sourceEventSeqs = event["sourceEventSeqs"] { base["sourceEventSeqs"] = sourceEventSeqs }
    let data = event["data"]?.objectValue ?? [:]
    base["event"] = payload(type: event["type"]?.stringValue, data: data)
    return .object(base)
  }

  private static func payload(type: String?, data d: [String: JSONValue]) -> JSONValue {
    guard let type else { return .object([:]) }
    switch type {
    case "user/message":
      let blocks = d["content"]?.arrayValue ?? []
      var wire: [String: JSONValue] = ["type": .string(type), "text": .string(textOf(blocks))]
      // `d.source && d.source.kind`: absent owner ⇒ key gone, present owner ⇒ its leaf.
      if let source = shortCircuitLeaf(d["source"], "kind") { wire["source"] = source }
      if let id = d["id"]?.stringValue, !id.isEmpty { wire["raw"] = .object(["id": .string(id)]) }
      let images = imagesOf(blocks)
      if !images.isEmpty { wire["images"] = .array(images) }
      return .object(wire)

    case "assistant/message":
      let blocks = d["message"]?["content"]?.arrayValue ?? []
      var text = ""
      var reasoning = ""
      var toolCalls: [JSONValue] = []
      let images = imagesOf(blocks)
      for block in blocks {
        switch block["type"]?.stringValue {
        case "text":
          if let piece = block["text"]?.stringValue { text += piece }
        case "reasoning":
          if let piece = block["text"]?.stringValue { reasoning += piece }
        case "tool-call":
          var call: [String: JSONValue] = [:]
          if let id = block["id"] { call["id"] = id }
          if let name = block["name"] { call["name"] = name }
          if let arguments = block["arguments"] { call["arguments"] = arguments }
          toolCalls.append(.object(call))
        default:
          break
        }
      }
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let turn = d["turn"] { wire["turn"] = turn }
      if let step = d["step"] { wire["step"] = step }
      wire["text"] = .string(text)
      wire["reasoning"] = .string(reasoning)
      wire["toolCalls"] = .array(toolCalls)
      // Only a literal `true` marks the message interrupted.
      if d["interrupted"]?.boolValue == true { wire["interrupted"] = .bool(true) }
      // `usage` is copied when the key exists at all, so an explicit null survives.
      if let usage = d["usage"] { wire["usage"] = usage }
      if !images.isEmpty { wire["images"] = .array(images) }
      return .object(wire)

    case "assistant/attempt":
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let turn = d["turn"] { wire["turn"] = turn }
      if let step = d["step"] { wire["step"] = step }
      // The whole stream array is copied verbatim here; the *conversation* view is where
      // it gets stripped, not the live durable event.
      if let stream = d["stream"] { wire["stream"] = stream }
      return .object(wire)

    case "session/title":
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let title = d["title"] { wire["title"] = title }
      if let source = d["source"], jsTruthy(source) { wire["source"] = source }
      return .object(wire)

    case "agent-preset/selected":
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let preset = d["agentPreset"] { wire["agentPreset"] = preset }
      return .object(wire)

    case "tool/call":
      var wire: [String: JSONValue] = ["type": .string(type)]
      for key in ["turn", "step", "callId", "name", "arguments"] {
        if let value = d[key] { wire[key] = value }
      }
      return .object(wire)

    case "tool/result":
      var preview = ""
      for block in d["message"]?["content"]?.arrayValue ?? [] {
        for inner in block["content"]?.arrayValue ?? [] {
          if inner["type"]?.stringValue == "text", let piece = inner["text"]?.stringValue {
            preview += piece
          }
        }
      }
      if MobileGatewayJSText.codeUnitCount(preview) > maxToolResultPreview {
        preview = MobileGatewayJSText.prefixCodeUnits(preview, maxToolResultPreview) + "…"
      }
      let isError = jsTruthy(d["error"])
        || (d["message"]?["content"]?.arrayValue ?? []).contains { block in
          block["type"]?.stringValue == "tool-result" && block["isError"]?.boolValue == true
        }
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let turn = d["turn"] { wire["turn"] = turn }
      if let step = d["step"] { wire["step"] = step }
      // `d.message && d.message.source && d.message.source.callId` — a chained short-circuit,
      // where a falsy link (an explicit null) survives into the output.
      if let callId = shortCircuitLeaf(shortCircuitLeaf(d["message"], "source"), "callId") {
        wire["callId"] = callId
      }
      wire["isError"] = .bool(isError)
      wire["preview"] = .string(preview)
      return .object(wire)

    case "command/run":
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let commandId = d["commandId"] { wire["commandId"] = commandId }
      if let name = d["name"] { wire["name"] = name }
      if let args = d["args"]?.stringValue { wire["args"] = .string(args) }
      if let source = d["source"], jsTruthy(source) { wire["source"] = source }
      return .object(wire)

    case "command/done":
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let commandId = d["commandId"] { wire["commandId"] = commandId }
      if let outcome = d["kind"] { wire["outcome"] = outcome }
      if let text = d["text"]?.stringValue { wire["text"] = .string(text) }
      if case .number(let seq)? = d["sourceEventSeq"] { wire["sourceEventSeq"] = .number(seq) }
      return .object(wire)

    case "compaction/start":
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let compactionId = d["compactionId"] { wire["compactionId"] = compactionId }
      if let sourceCommandId = d["sourceCommandId"], jsTruthy(sourceCommandId) {
        wire["sourceCommandId"] = sourceCommandId
      }
      wire["turn"] = d["turn"] ?? .null
      return .object(wire)

    case "compaction/summary":
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let compactionId = d["compactionId"] { wire["compactionId"] = compactionId }
      if let sourceCommandId = d["sourceCommandId"], jsTruthy(sourceCommandId) {
        wire["sourceCommandId"] = sourceCommandId
      }
      wire["shadowedItemCount"] = d["shadowedSeqs"]?.arrayValue.map { .number(Double($0.count)) } ?? .null
      if case .number(let tokens)? = d["shadowedTokenCount"] {
        wire["shadowedTokenCount"] = .number(tokens)
      } else {
        wire["shadowedTokenCount"] = .null
      }
      return .object(wire)

    case "compaction/end":
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let compactionId = d["compactionId"] { wire["compactionId"] = compactionId }
      if let sourceCommandId = d["sourceCommandId"], jsTruthy(sourceCommandId) {
        wire["sourceCommandId"] = sourceCommandId
      }
      wire["turn"] = d["turn"] ?? .null
      if let error = d["error"]?.stringValue { wire["error"] = .string(error) }
      return .object(wire)

    case "turn/start", "turn/end", "step/start", "step/end":
      var wire: [String: JSONValue] = ["type": .string(type)]
      if let turn = d["turn"] { wire["turn"] = turn }
      if let step = d["step"] { wire["step"] = step }
      if let reason = shortCircuitLeaf(d["reason"], "kind") { wire["reason"] = reason }
      return .object(wire)

    default:
      // Token-level replay (`assistant/chunk`), prompt headers and system messages reach
      // here: a seq-bearing shell with no payload. Real-time tokens travel on the
      // independent `assistant-stream` path instead.
      return .object(["type": .string(type)])
    }
  }

  // MARK: Leaf readers

  private static func textOf(_ blocks: [JSONValue]) -> String {
    var text = ""
    for block in blocks where block["type"]?.stringValue == "text" {
      if let piece = block["text"]?.stringValue { text += piece }
    }
    return text
  }

  private static func imagesOf(_ blocks: [JSONValue]) -> [JSONValue] {
    var images: [JSONValue] = []
    for block in blocks {
      guard block["type"]?.stringValue == "image",
            let attachment = block["attachment"], jsTruthy(attachment) else { continue }
      var image: [String: JSONValue] = [:]
      for key in ["attachmentId", "mediaType", "bytes", "width", "height"] {
        if let value = attachment[key] { image[key] = value }
      }
      if let name = attachment["name"], jsTruthy(name) { image["name"] = name }
      images.append(.object(image))
    }
    return images
  }

  /// JS truthiness of a JSON value: `null`, `false`, `0` and `""` are falsy, and both
  /// empty arrays and empty objects are truthy.
  static func jsTruthy(_ value: JSONValue?) -> Bool {
    switch value {
    case .none, .some(.null): return false
    case .some(.bool(let flag)): return flag
    case .some(.number(let number)): return number != 0
    case .some(.string(let text)): return !text.isEmpty
    case .some(.array), .some(.object): return true
    }
  }

  /// `owner && owner[key]`: a missing owner drops the key, a falsy owner evaluates to
  /// itself (so an explicit `null` survives into the JSON), and a truthy owner yields its
  /// leaf — which is dropped when the leaf is missing.
  private static func shortCircuitLeaf(_ owner: JSONValue?, _ key: String) -> JSONValue? {
    guard let owner else { return nil }
    return jsTruthy(owner) ? owner[key] : owner
  }
}

// MARK: - History sizing

/// The conversation-view sizer (spec 03 §B.5).
enum MobileGatewayHistory {
  /// `HISTORY_DEFAULT_MAX_BYTES` — the per-frame budget for an ordinary `history`
  /// response; a client may raise or lower it with `maxBytes`.
  static let defaultMaxBytes = 4 * 1024 * 1024
  /// `HISTORY_OPENING_MAX_BYTES` — an opening snapshot must be readable on a phone
  /// before older history is paged in.
  static let openingMaxBytes = 256 * 1024
  /// `HISTORY_TOOL_RESULT_MAX_CHARS` — per text block in the conversation view.
  static let toolResultMaxCharacters = 2000

  /// `eventBytes`: UTF-8 length of the compact serialization — the same JSON the host
  /// delivered, measured rather than estimated.
  static func eventBytes(_ event: JSONValue) -> Int {
    guard let text = try? event.serialized() else { return 0 }
    return text.utf8.count
  }

  /// `trimConversationEvent`: `nil` drops the event, everything else is what the chat page
  /// is allowed to see.
  static func trimConversationEvent(_ event: JSONValue) -> JSONValue? {
    switch event["type"]?.stringValue {
    case "assistant/chunk", "request/header", "request/context", "system/message":
      // Token-level replay and system-prompt headers are not rendered on the chat page.
      return nil

    case "assistant/message", "assistant/attempt":
      var wire = event
      if case .object(var fields) = wire {
        var data = fields["data"]?.objectValue ?? [:]
        data.removeValue(forKey: "stream")
        fields["data"] = .object(data)
        wire = .object(fields)
      }
      return wire

    case "tool/result":
      let d = event["data"]?.objectValue ?? [:]
      guard let message = d["message"], message.objectValue != nil,
            let content = message["content"]?.arrayValue else { return event }
      var changed = false
      let truncated = content.map { truncateToolResultBlock($0, changed: &changed) }
      guard changed else { return event }
      var fields = event.objectValue ?? [:]
      var data = d
      var messageFields = message.objectValue ?? [:]
      messageFields["content"] = .array(truncated)
      data["message"] = .object(messageFields)
      fields["data"] = .object(data)
      return .object(fields)

    default:
      return event
    }
  }

  private static func truncateToolResultBlock(_ block: JSONValue, changed: inout Bool) -> JSONValue {
    guard case .object(var fields) = block else { return block }
    if fields["type"]?.stringValue == "text", let text = fields["text"]?.stringValue,
       MobileGatewayJSText.codeUnitCount(text) > toolResultMaxCharacters {
      changed = true
      fields["text"] = .string(MobileGatewayJSText.prefixCodeUnits(text, toolResultMaxCharacters) + "…")
      return .object(fields)
    }
    if let content = fields["content"]?.arrayValue {
      fields["content"] = .array(content.map { truncateToolResultBlock($0, changed: &changed) })
      return .object(fields)
    }
    return block
  }

  /// `capHistoryEvents`: keep the newest suffix that fits, always keeping the newest event
  /// even when it alone exceeds the budget (an event cannot be split).
  static func capHistoryEvents(
    _ events: [JSONValue],
    maxBytes: Int,
    trim: Bool
  ) -> (events: [JSONValue], bytes: Int, dropped: Int) {
    let processed = trim ? events.compactMap { trimConversationEvent($0) } : events
    guard !processed.isEmpty else { return ([], 0, 0) }
    var total = 0
    var keptStart = processed.count
    var index = processed.count - 1
    while index >= 0 {
      let size = eventBytes(processed[index])
      if keptStart == processed.count {
        total = size
        keptStart = index
      } else if total + size > maxBytes {
        break
      } else {
        total += size
        keptStart = index
      }
      index -= 1
    }
    return (Array(processed[keptStart...]), total, keptStart)
  }

  /// `historyPage`: the response body both `history` and `session-snapshot` are built from.
  ///
  /// `events` are the adapter's `{ event: … }` wrappers, because that is what the host
  /// hands over; only the inner event reaches the wire.
  static func page(
    events: [JSONValue],
    hasMore: Bool,
    projections: JSONValue,
    historyFormatVersion: Int,
    cursor: Int,
    sessionID: String?,
    view: String?,
    maxBytes: Int?
  ) -> JSONValue {
    let rawEvents = events.map { $0["event"] ?? .null }
    let budget: Int
    if let maxBytes, maxBytes > 0 {
      budget = maxBytes
    } else {
      budget = defaultMaxBytes
    }
    let trim = view == "conversation"
    let capped = capHistoryEvents(rawEvents, maxBytes: budget, trim: trim)
    let hasMoreOut = hasMore || capped.dropped > 0
    // An all-hidden page still needs a cursor so callers can reach older text.
    let oldest = MobileGatewayNumbers.safeInteger(capped.events.first?["seq"])
      ?? MobileGatewayNumbers.safeInteger(rawEvents.first?["seq"])

    var frame: [String: JSONValue] = [
      "events": .array(capped.events),
      "hasMore": .bool(hasMoreOut),
      "projections": projections,
      "historyFormatVersion": .number(Double(historyFormatVersion)),
      "cursor": .number(Double(cursor)),
      "kind": .string("history"),
      "bytes": .number(Double(capped.bytes)),
    ]
    if let sessionID { frame["sessionId"] = .string(sessionID) }
    if trim { frame["view"] = .string("conversation") }
    if hasMoreOut, let oldest { frame["nextBeforeSeq"] = .number(Double(oldest)) }
    return .object(frame)
  }
}

// MARK: - Follow decoder

/// `createFollowDecoder` (spec 03 §B.6.3).
///
/// Validates the two independent clocks. The durable `seq` clock must advance by exactly
/// one per event; the transient `revision` clock must advance by exactly one per stream
/// frame, across attempt boundaries. No transient frame ever owns a Session `seq`, and a
/// gap on either clock is fatal to the opening — the follower reports it and re-opens with
/// a fresh snapshot rather than papering over a hole the phone would have to guess at.
struct MobileGatewayFollowDecoder {
  enum Frame {
    case snapshot(history: MobileGatewayHostAdapter.SessionSnapshot, assistantStream: JSONValue)
    case event(JSONValue)
    case assistantStream(JSONValue)
  }

  private struct ActiveAttempt {
    var attemptID: String
    var turn: Int
    var step: Int
    var startedAfterSeq: Int
    var nextIndex: Int
  }

  private let sessionID: String
  private var cursor: Int?
  private var revision: Int?
  private var active: ActiveAttempt?

  init(sessionID: String) {
    self.sessionID = sessionID
  }

  mutating func decode(_ frame: JSONValue) throws -> Frame {
    guard let cursor else { return try open(frame) }

    if frame["type"]?.stringValue == "event" {
      guard let event = frame["event"],
            let seq = MobileGatewayNumbers.integer(event["seq"]),
            seq == cursor + 1 else {
        throw MobileGatewayStreamError(message: "session event sequence gap")
      }
      self.cursor = seq
      return .event(frame)
    }

    guard frame["type"]?.stringValue == "assistant-stream" else {
      // An unknown follow frame type is a continuity break, not something to skip: the
      // phone would silently lose whatever it carried.
      throw MobileGatewayStreamError(message: "unexpected session follow frame")
    }
    guard let next = frame["frame"],
          let nextRevision = MobileGatewayNumbers.integer(next["revision"]),
          nextRevision == revision.map({ $0 + 1 }) else {
      throw MobileGatewayStreamError(message: "assistant stream revision gap")
    }

    if next["type"]?.stringValue == "start" {
      _ = try Self.requireAttempt(next)
      guard active == nil,
            let startedAfterSeq = MobileGatewayNumbers.integer(next["startedAfterSeq"], minimum: -1),
            startedAfterSeq <= cursor else {
        throw MobileGatewayStreamError(message: "unexpected assistant start")
      }
      active = ActiveAttempt(
        attemptID: next["attemptId"]?.stringValue ?? "",
        turn: MobileGatewayNumbers.integer(next["turn"]) ?? 0,
        step: MobileGatewayNumbers.integer(next["step"]) ?? 0,
        startedAfterSeq: startedAfterSeq,
        nextIndex: 0
      )
    } else {
      guard let current = active,
            next["attemptId"]?.stringValue == current.attemptID,
            MobileGatewayNumbers.integer(next["index"]) == current.nextIndex else {
        throw MobileGatewayStreamError(message: "assistant stream attempt/index gap")
      }
      switch next["type"]?.stringValue {
      case "chunk":
        guard MobileGatewayNumbers.integer(next["time"]) != nil,
              let chunk = next["chunk"], chunk.objectValue != nil,
              chunk["type"]?.stringValue != nil else {
          throw MobileGatewayStreamError(message: "invalid assistant chunk")
        }
        active?.nextIndex += 1
      case "end":
        try Self.validateSettlement(next["outcome"], cursor: cursor, after: current.startedAfterSeq)
      default:
        throw MobileGatewayStreamError(message: "unexpected assistant frame")
      }
    }

    self.revision = nextRevision
    guard let settled = active else {
      throw MobileGatewayStreamError(message: "unexpected assistant frame")
    }
    // The decoder injects the active attempt's `turn`/`step` onto every transient frame,
    // so a client never has to remember them from `start`.
    var normalized = next
    if case .object(var fields) = normalized {
      fields["turn"] = .number(Double(settled.turn))
      fields["step"] = .number(Double(settled.step))
      normalized = .object(fields)
    }
    if next["type"]?.stringValue == "end" { active = nil }
    return .assistantStream(normalized)
  }

  /// The opening frame: a format-3 snapshot plus the assistant-stream baseline that makes
  /// the two clocks independent from the very first frame.
  private mutating func open(_ frame: JSONValue) throws -> Frame {
    let history = try MobileGatewayHostAdapter.readSnapshot(frame, sessionID: sessionID)
    guard let baseline = frame["assistantStream"], baseline.objectValue != nil,
          let revision = MobileGatewayNumbers.integer(baseline["revision"]) else {
      throw MobileGatewayStreamError(message: "missing assistant stream baseline")
    }
    if let rawAttempt = baseline["activeAttempt"] {
      let attempt = try Self.requireAttempt(rawAttempt)
      guard let nextIndex = MobileGatewayNumbers.integer(attempt["nextIndex"]),
            attempt["stream"]?.arrayValue != nil,
            let startedAfterSeq = MobileGatewayNumbers.integer(attempt["startedAfterSeq"], minimum: -1),
            startedAfterSeq <= history.cursor else {
        throw MobileGatewayStreamError(message: "invalid assistant baseline")
      }
      active = ActiveAttempt(
        attemptID: attempt["attemptId"]?.stringValue ?? "",
        turn: MobileGatewayNumbers.integer(attempt["turn"]) ?? 0,
        step: MobileGatewayNumbers.integer(attempt["step"]) ?? 0,
        startedAfterSeq: startedAfterSeq,
        nextIndex: nextIndex
      )
    }
    cursor = history.cursor
    self.revision = revision
    return .snapshot(history: history, assistantStream: baseline)
  }

  /// `requireAttempt`: a non-empty attempt id, non-negative `turn`/`step`, and a
  /// `startedAfterSeq` that may be `-1` to mean "nothing was committed before this".
  private static func requireAttempt(_ attempt: JSONValue) throws -> JSONValue {
    guard let attemptID = attempt["attemptId"]?.stringValue, !attemptID.isEmpty,
          MobileGatewayNumbers.integer(attempt["turn"]) != nil,
          MobileGatewayNumbers.integer(attempt["step"]) != nil,
          MobileGatewayNumbers.integer(attempt["startedAfterSeq"], minimum: -1) != nil else {
      throw MobileGatewayStreamError(message: "invalid assistant attempt")
    }
    return attempt
  }

  /// `end.outcome`: `{ kind: 'abandoned' }` is always valid; `committed` must name a
  /// durable event that has *already* been delivered (`seq <= cursor`) and that belongs to
  /// this attempt (`seq > startedAfterSeq`).
  private static func validateSettlement(_ outcome: JSONValue?, cursor: Int, after startedAfterSeq: Int) throws {
    let kind = outcome?["kind"]?.stringValue
    if kind == "abandoned" { return }
    if kind == "committed" {
      let eventType = outcome?["eventType"]?.stringValue
      let seq = MobileGatewayNumbers.integer(outcome?["seq"])
      if let eventType, ["assistant/message", "assistant/attempt"].contains(eventType),
         let seq, seq <= cursor, seq > startedAfterSeq {
        return
      }
    }
    throw MobileGatewayStreamError(message: "invalid assistant settlement")
  }
}

// MARK: - Pump lifetime

/// The latch a running pump shares with `stop()`.
///
/// The plugin compares object identity (`current === state`) and aborts an
/// `AbortController`. Those two facts become one lock-protected flag plus the handle of
/// the in-flight *attempt*: an attempt needs its own handle because a reconnect must
/// release a producer blocked on the next host event and then keep looping, which
/// cancelling the outer task could not express.
final class MobileGatewayPumpRun: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var attempt: Task<MobileGatewayFollowAttempt, Never>?

  var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelled
  }

  func setAttempt(_ task: Task<MobileGatewayFollowAttempt, Never>?) {
    lock.lock()
    if cancelled {
      lock.unlock()
      task?.cancel()
      return
    }
    attempt = task
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let attempt = self.attempt
    self.attempt = nil
    lock.unlock()
    attempt?.cancel()
  }

  /// `delay(ms, signal)`: `true` when `stop()` cut the wait short, so a stop never has to
  /// sit out a 30-second backoff.
  func sleepFor(milliseconds: Int) async -> Bool {
    if isCancelled { return true }
    do {
      try await Task.sleep(for: .milliseconds(max(0, milliseconds)))
    } catch {
      return true
    }
    return isCancelled
  }
}

/// The result of one upstream opening, reduced to something `Sendable` before it crosses
/// back to the outer loop.
enum MobileGatewayFollowAttempt: Sendable {
  /// `stop()` landed mid-opening; nothing is reported.
  case stopped
  /// The opening failed. `code` is `nil` for a protocol fault the decoder raised itself.
  case failed(code: String?, message: String, permanent: Bool)
}

// MARK: - Session pump

/// Follows ONE session over `session/follow` and emits the wire frames a subscribed
/// conversation-channel phone receives. One instance per subscribed connection.
///
/// This is `createSessionFollower` plus the plugin's per-connection wiring (spec 03 §B.3):
/// the follower itself does not send anything, so the frame shapes it feeds are built here.
/// The two push paths stay independent — a durable `event` frame always carries the real
/// Session `seq`, and an `assistant-stream` frame never carries one.
public final class MobileGatewaySessionPump: @unchecked Sendable {
  private let adapter: MobileGatewayHostAdapter
  private let sessionID: String
  private let onFrame: @Sendable (JSONValue) -> Void
  private let onFailure: @Sendable (Error) -> Void

  /// The subscription identity stamped on every frame this pump emits.
  ///
  /// It is minted here because the pump is created per `subscribe`, and the plugin mints
  /// the id at exactly that moment. The service must echo this value in its `subscribed`
  /// frame **before** calling `start()`: a phone discards frames whose `subscriptionId`
  /// it has not seen confirmed.
  public let subscriptionID: String

  private let lock = NSLock()
  private var run: MobileGatewayPumpRun?
  private var task: Task<Void, Never>?

  public init(
    adapter: MobileGatewayHostAdapter,
    sessionID: String,
    onFrame: @escaping @Sendable (JSONValue) -> Void,
    onFailure: @escaping @Sendable (Error) -> Void
  ) {
    self.adapter = adapter
    self.sessionID = sessionID
    self.onFrame = onFrame
    self.onFailure = onFailure
    self.subscriptionID = UUID().uuidString
  }

  /// Begin — or restart — the follow.
  ///
  /// A restart is deliberate: only one follow may exist per connection, and a second
  /// `subscribe` must not leave the previous socket feeding the same conversation. Every
  /// opening after that owns a fresh `streamId` and a fresh decoder, so nothing survives a
  /// reset except the subscription identity.
  public func start() {
    lock.lock()
    let previous = run
    let previousTask = task
    let next = MobileGatewayPumpRun()
    run = next
    task = nil
    lock.unlock()
    previous?.cancel()
    previousTask?.cancel()

    let task = Task { [adapter, sessionID, subscriptionID, onFrame, onFailure] in
      await MobileGatewaySessionPump.follow(
        run: next,
        adapter: adapter,
        sessionID: sessionID,
        subscriptionID: subscriptionID,
        onFrame: onFrame,
        onFailure: onFailure
      )
    }
    lock.lock()
    if run === next {
      self.task = task
    } else {
      // `stop()` won the race; the follow must not outlive it.
      next.cancel()
      task.cancel()
    }
    lock.unlock()
  }

  /// Idempotent and synchronous: it clears the latch and cancels both the outer loop and
  /// the in-flight opening, so a producer blocked on the next host event is released
  /// rather than left holding a socket. Frames already produced are dropped by the
  /// cancellation checks before they reach `onFrame`.
  public func stop() {
    lock.lock()
    let run = self.run
    let task = self.task
    self.run = nil
    self.task = nil
    lock.unlock()
    run?.cancel()
    task?.cancel()
  }

  // MARK: - Follow loop

  private static func follow(
    run: MobileGatewayPumpRun,
    adapter: MobileGatewayHostAdapter,
    sessionID: String,
    subscriptionID: String,
    onFrame: @escaping @Sendable (JSONValue) -> Void,
    onFailure: @escaping @Sendable (Error) -> Void
  ) async {
    var failures = 0
    while !run.isCancelled && !Task.isCancelled {
      // Every iteration is a new opening: fresh stream identity, fresh decoder, fresh
      // snapshot. That is what makes a reset safe to hand to the phone.
      let streamID = UUID().uuidString
      let attempt = Task {
        await open(
          run: run,
          adapter: adapter,
          sessionID: sessionID,
          subscriptionID: subscriptionID,
          streamID: streamID,
          onFrame: onFrame
        )
      }
      run.setAttempt(attempt)
      let outcome = await attempt.value
      run.setAttempt(nil)
      if run.isCancelled || Task.isCancelled { return }

      switch outcome {
      case .stopped:
        return

      case .failed(let code, let message, let permanent):
        let wireCode = code ?? "stream-interrupted"
        onFrame(.object([
          "kind": .string("session-stream-reset"),
          "sessionId": .string(sessionID),
          "subscriptionId": .string(subscriptionID),
          "streamId": .string(streamID),
          "code": .string(wireCode),
          "message": .string(message),
          "retrying": .bool(!permanent),
        ]))
        if permanent {
          // The only moment the service can be told the subscription is dead: the follow
          // is not re-opened. A transient fault is *not* reported here — it is retried
          // with backoff, and the phone already learned about it from the reset frame.
          onFailure(MobileGatewaySessionFailure(
            code: wireCode,
            message: message,
            sessionID: sessionID,
            subscriptionID: subscriptionID,
            streamID: streamID,
            retrying: false
          ))
          return
        }
        // min(retryMs * 2^min(failures, 5), 30_000): 1000, 2000, 4000, 8000, 16000, 30000…
        let backoff = min(1000 * (1 << min(failures, 5)), 30_000)
        failures += 1
        if await run.sleepFor(milliseconds: backoff) { return }
      }
    }
  }

  /// Consume one upstream opening to completion. Runs in its own task so that a reconnect
  /// can release it without disturbing the loop that schedules the reconnect.
  private static func open(
    run: MobileGatewayPumpRun,
    adapter: MobileGatewayHostAdapter,
    sessionID: String,
    subscriptionID: String,
    streamID: String,
    onFrame: @Sendable (JSONValue) -> Void
  ) async -> MobileGatewayFollowAttempt {
    var decoder = MobileGatewayFollowDecoder(sessionID: sessionID)
    do {
      let stream = try await adapter.openSessionStream(sessionID: sessionID)
      for try await frame in stream {
        if run.isCancelled || Task.isCancelled { return .stopped }
        let decoded = try decoder.decode(frame)
        emit(decoded, sessionID: sessionID, subscriptionID: subscriptionID, streamID: streamID, onFrame: onFrame)
      }
      if run.isCancelled || Task.isCancelled { return .stopped }
      // The host ended the follow without an error. The plugin treats that as a fault:
      // the phone is now waiting for events that will never arrive.
      return .failed(code: nil, message: "session follow ended", permanent: false)
    } catch {
      if run.isCancelled || Task.isCancelled { return .stopped }
      return .failed(
        code: MobileGatewayFollowPolicy.code(of: error),
        message: MobileGatewayFollowPolicy.message(of: error),
        permanent: MobileGatewayFollowPolicy.isPermanent(error)
      )
    }
  }

  // MARK: - Frame construction

  private static func emit(
    _ frame: MobileGatewayFollowDecoder.Frame,
    sessionID: String,
    subscriptionID: String,
    streamID: String,
    onFrame: @Sendable (JSONValue) -> Void
  ) {
    var context: [String: JSONValue] = [
      "sessionId": .string(sessionID),
      "subscriptionId": .string(subscriptionID),
      "streamId": .string(streamID),
    ]
    switch frame {
    case .snapshot(let history, let assistantStream):
      // The opening window is `maxMessages: 12` upstream and 256 KiB locally; `cursor`
      // survives the trimming untouched, because it is the host's atomic cut point and
      // not the seq of the newest event that happened to fit.
      let page = MobileGatewayHistory.page(
        events: history.events,
        hasMore: history.hasMore,
        projections: history.projections,
        historyFormatVersion: history.historyFormatVersion,
        cursor: history.cursor,
        sessionID: sessionID,
        view: "conversation",
        maxBytes: MobileGatewayHistory.openingMaxBytes
      )
      context["kind"] = .string("session-snapshot")
      context["assistantStream"] = assistantStream
      context["replace"] = .bool(true)
      onFrame(page.merging(context))

    case .event(let raw):
      // Spread order matters in the plugin: the context is applied *after* the wire event,
      // so `sessionId` is re-set to the subscribed id and the stream identity is appended.
      onFrame(MobileGatewayWireEvent.build(sessionID: sessionID, event: raw["event"] ?? .null).merging(context))

    case .assistantStream(let normalized):
      onFrame(.object([
        "kind": .string("assistant-stream"),
        "sessionId": .string(sessionID),
        "subscriptionId": .string(subscriptionID),
        "streamId": .string(streamID),
        "frame": normalized,
      ]))
    }
  }
}
