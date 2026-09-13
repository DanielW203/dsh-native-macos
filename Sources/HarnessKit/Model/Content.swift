import Foundation

// MARK: - Attachments

/// An image (or other binary) attached to a message or produced by a tool.
///
/// The field set mirrors the official `attachment` payload exactly so that a
/// session written by route B is byte-comparable with one written by route A.
public struct Attachment: Sendable, Equatable, Codable, Hashable, Identifiable {
  public var attachmentId: String
  public var bytes: Int?
  public var mediaType: String?
  public var name: String?
  public var width: Int?
  /// Optional: some producers omit the height for non-image attachments.
  public var height: Int?
  public var originalDimensions: Dimensions?

  public var id: String { attachmentId }

  public struct Dimensions: Sendable, Equatable, Codable, Hashable {
    public var width: Int?
    public var height: Int?
    public init(width: Int? = nil, height: Int? = nil) {
      self.width = width
      self.height = height
    }
  }

  public init(
    attachmentId: String,
    bytes: Int? = nil,
    mediaType: String? = nil,
    name: String? = nil,
    width: Int? = nil,
    height: Int? = nil,
    originalDimensions: Dimensions? = nil
  ) {
    self.attachmentId = attachmentId
    self.bytes = bytes
    self.mediaType = mediaType
    self.name = name
    self.width = width
    self.height = height
    self.originalDimensions = originalDimensions
  }
}

// MARK: - Content blocks

/// One element of a message body.
///
/// The official runtime serialises these as tagged objects (`{type: "text", text}`),
/// including for tool calls (`{type: "tool_use", id, name, arguments}`). Persisting
/// the original `raw` JSON for unknown tags is what lets this build read a session
/// produced by a newer engine without losing data.
public enum ContentBlock: Sendable, Equatable {
  case text(String)
  case reasoning(String)
  case image(Attachment)
  case toolUse(ToolUse)
  case toolResult(ToolResult)
  case unknown(type: String, raw: JSONValue)

  public struct ToolUse: Sendable, Equatable {
    /// Provider-assigned call id; the join key with `tool/result`.
    public var id: String
    public var name: String
    /// Tool arguments **as JSON text** — `tool/call` carries a string, not an object.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
      self.id = id
      self.name = name
      self.arguments = arguments
    }

    /// Best-effort parse of `arguments` into a JSON value.
    public var parsedArguments: JSONValue? {
      guard !arguments.isEmpty else { return nil }
      return try? JSONValue.parse(arguments, context: "tool_use.arguments")
    }
  }

  public struct ToolResult: Sendable, Equatable {
    public var toolUseId: String
    public var text: String
    public var isError: Bool

    public init(toolUseId: String, text: String, isError: Bool = false) {
      self.toolUseId = toolUseId
      self.text = text
      self.isError = isError
    }
  }

  public var textValue: String? {
    if case .text(let value) = self { return value }
    if case .reasoning(let value) = self { return value }
    return nil
  }

  public var typeName: String {
    switch self {
    case .text: return "text"
    case .reasoning: return "reasoning"
    case .image: return "image"
    case .toolUse: return "tool_use"
    case .toolResult: return "tool_result"
    case .unknown(let type, _): return type
    }
  }
}

extension ContentBlock: Codable {
  /// Blocks are decoded through `JSONValue` rather than a keyed container: the
  /// tagged-union shape varies with block type, and going through a value keeps
  /// unknown tags lossless instead of dropping them.
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(JSONValue.self)
    self = ContentBlock(json: value)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(json)
  }

  /// Interpret one wire block.
  public init(json value: JSONValue) {
    guard let type = value.string(at: "type") else {
      self = .unknown(type: "unknown", raw: value)
      return
    }
    switch type {
    case "text":
      self = .text(value.string(at: "text") ?? "")
    case "reasoning", "thinking":
      self = .reasoning(value.string(at: "text") ?? "")
    case "image":
      let attachment = (try? value.path("attachment")?.decoded(as: Attachment.self)) ?? nil
      self = .image(attachment ?? Attachment(attachmentId: ""))
    case "tool_use", "tool_call":
      let id = value.string(at: "id") ?? ""
      let name = value.string(at: "name") ?? ""
      let arguments: String
      if let text = value.string(at: "arguments") {
        arguments = text
      } else if let raw = value.path("arguments") {
        arguments = (try? raw.serialized()) ?? "{}"
      } else {
        arguments = "{}"
      }
      self = .toolUse(ToolUse(id: id, name: name, arguments: arguments))
    case "tool_result":
      self = .toolResult(
        ToolResult(
          toolUseId: value.string(at: "toolUseId") ?? value.string(at: "tool_use_id") ?? "",
          text: value.string(at: "text") ?? "",
          isError: value.bool(at: "isError") ?? false
        )
      )
    default:
      self = .unknown(type: type, raw: value)
    }
  }

  /// Serialise back to the wire shape.
  public var json: JSONValue {
    switch self {
    case .text(let text):
      return .object(["type": "text", "text": .string(text)])
    case .reasoning(let text):
      return .object(["type": "reasoning", "text": .string(text)])
    case .image(let attachment):
      return .object([
        "type": "image",
        "attachment": (try? JSONValue.from(attachment)) ?? .null,
      ])
    case .toolUse(let use):
      return .object([
        "type": "tool_use",
        "id": .string(use.id),
        "name": .string(use.name),
        "arguments": .string(use.arguments),
      ])
    case .toolResult(let result):
      return .object([
        "type": "tool_result",
        "toolUseId": .string(result.toolUseId),
        "text": .string(result.text),
        "isError": .bool(result.isError),
      ])
    case .unknown(_, let raw):
      return raw
    }
  }
}

// MARK: - Usage

/// Token accounting, mirroring the official `usage` payload.
public struct Usage: Sendable, Equatable, Codable, Hashable {
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var reasoningTokens: Int?
  public var cacheReadTokens: Int?

  public init(
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    cacheReadTokens: Int? = nil
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
    self.cacheReadTokens = cacheReadTokens
  }

  public static let zero = Usage(inputTokens: 0, outputTokens: 0, reasoningTokens: 0, cacheReadTokens: 0)

  public var total: Int {
    (inputTokens ?? 0) + (outputTokens ?? 0)
  }

  public static func + (lhs: Usage, rhs: Usage) -> Usage {
    Usage(
      inputTokens: (lhs.inputTokens ?? 0) + (rhs.inputTokens ?? 0),
      outputTokens: (lhs.outputTokens ?? 0) + (rhs.outputTokens ?? 0),
      reasoningTokens: (lhs.reasoningTokens ?? 0) + (rhs.reasoningTokens ?? 0),
      cacheReadTokens: (lhs.cacheReadTokens ?? 0) + (rhs.cacheReadTokens ?? 0)
    )
  }
}

// MARK: - Message source

/// Provenance of a message. The official runtime stamps plugin-injected context as
/// `kind: "plugin"` with a `sections` breakdown, which the UI surfaces as
/// collapsible "injected context" rather than as user text.
public struct MessageSource: Sendable, Equatable, Codable, Hashable {
  public var kind: String?
  public var plugin: String?
  public var form: String?
  public var summary: String?
  public var rpcId: String?
  public var clientTimeZone: String?
  public var model: ModelRef?
  public var provider: String?
  public var sections: [Section]?

  public struct Section: Sendable, Equatable, Codable, Hashable {
    public var name: String?
    public var text: String?
    public init(name: String? = nil, text: String? = nil) {
      self.name = name
      self.text = text
    }
  }

  public struct ModelRef: Sendable, Equatable, Codable, Hashable {
    public var model: String?
    public var provider: String?
    public init(model: String? = nil, provider: String? = nil) {
      self.model = model
      self.provider = provider
    }
  }

  public init(
    kind: String? = nil,
    plugin: String? = nil,
    form: String? = nil,
    summary: String? = nil,
    rpcId: String? = nil,
    clientTimeZone: String? = nil,
    model: ModelRef? = nil,
    provider: String? = nil,
    sections: [Section]? = nil
  ) {
    self.kind = kind
    self.plugin = plugin
    self.form = form
    self.summary = summary
    self.rpcId = rpcId
    self.clientTimeZone = clientTimeZone
    self.model = model
    self.provider = provider
    self.sections = sections
  }
}

// MARK: - Conversation message

/// A rendered turn-level message: what the conversation stream draws.
public struct ConversationMessage: Sendable, Equatable, Identifiable {
  public enum Role: String, Sendable, Codable {
    case system
    case user
    case assistant
    case tool
  }

  public var id: String
  public var role: Role
  public var content: [ContentBlock]
  public var seq: Int?
  public var time: Date?
  public var turn: Int?
  public var step: Int?
  public var usage: Usage?
  public var source: MessageSource?
  public var interrupted: Bool
  /// True while the engine is still appending to this message.
  public var isStreaming: Bool

  public init(
    id: String,
    role: Role,
    content: [ContentBlock],
    seq: Int? = nil,
    time: Date? = nil,
    turn: Int? = nil,
    step: Int? = nil,
    usage: Usage? = nil,
    source: MessageSource? = nil,
    interrupted: Bool = false,
    isStreaming: Bool = false
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.seq = seq
    self.time = time
    self.turn = turn
    self.step = step
    self.usage = usage
    self.source = source
    self.interrupted = interrupted
    self.isStreaming = isStreaming
  }

  /// Concatenated text blocks — what the transcript shows for a text message.
  public var text: String {
    content.compactMap { block -> String? in
      if case .text(let value) = block { return value }
      return nil
    }.joined()
  }

  public var reasoning: String {
    content.compactMap { block -> String? in
      if case .reasoning(let value) = block { return value }
      return nil
    }.joined()
  }

  public var toolUses: [ContentBlock.ToolUse] {
    content.compactMap { block -> ContentBlock.ToolUse? in
      if case .toolUse(let value) = block { return value }
      return nil
    }
  }

  /// Injected context (plugin/agent-instruction/system-reminder) rather than
  /// something the human typed. The transcript folds these by default.
  public var isInjectedContext: Bool {
    guard let source else { return false }
    if source.kind == "user" { return false }
    return source.kind != nil
  }
}
