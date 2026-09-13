import Foundation
import HarnessKit

/// One attachment the user sent over WeChat, before it is downloaded.
///
/// The raw provider descriptor is kept opaque on purpose: the image and file items use
/// different key encodings (hex `aeskey` vs base64 `media.aes_key`) and different size
/// fields, and interpreting them belongs to the media loader in one place rather than
/// being smeared across the parser.
public struct WeChatAttachment: Sendable, Equatable {
  public enum Kind: String, Sendable, Codable {
    case image
    case file
  }

  public let kind: Kind
  /// Display name for the model. Images get a synthetic `image`/`image-2` name, files
  /// keep the provider's `file_name` — the same naming the reference client uses.
  public let name: String
  /// Declared size when the provider reports one.
  public let byteCount: Int?
  /// The `image_item` / `file_item` object, verbatim.
  public let descriptor: JSONValue

  public init(kind: Kind, name: String, byteCount: Int?, descriptor: JSONValue) {
    self.kind = kind
    self.name = name
    self.byteCount = byteCount
    self.descriptor = descriptor
  }
}

/// One normalized inbound WeChat message.
public struct WeChatInboundMessage: Sendable, Equatable {
  /// Provider message id, or the client id when the provider omitted one.
  public let messageID: String
  public let sender: String
  public let sequence: Int?
  public let timestampMs: Double?
  public let contextToken: String?
  public let runID: String?
  /// First non-empty text or voice-to-text payload; empty when the message is media-only.
  public let text: String
  public let attachments: [WeChatAttachment]
  /// `message_type == 2`, i.e. the bot's own outbound message echoed by the sync stream.
  public let isOutbound: Bool

  public init(
    messageID: String,
    sender: String,
    sequence: Int? = nil,
    timestampMs: Double? = nil,
    contextToken: String? = nil,
    runID: String? = nil,
    text: String = "",
    attachments: [WeChatAttachment] = [],
    isOutbound: Bool = false
  ) {
    self.messageID = messageID
    self.sender = sender
    self.sequence = sequence
    self.timestampMs = timestampMs
    self.contextToken = contextToken
    self.runID = runID
    self.text = text
    self.attachments = attachments
    self.isOutbound = isOutbound
  }

  public var hasContent: Bool { !text.isEmpty || !attachments.isEmpty }
}

/// Parsing of the provider's `msgs[]` entries into `WeChatInboundMessage`.
public enum WeChatMessageParser {
  /// Shift that turns the timestamp embedded in a 64-bit iLink message id into
  /// milliseconds. Mirrors `WEIXIN_MESSAGE_ID_TIMESTAMP_SHIFT` in the reference client.
  static let messageIDTimestampShift: UInt64 = 22

  /// Parse one entry. Returns `nil` for anything without both an id and a sender: such
  /// an entry cannot be deduplicated or answered, so dropping it is safer than inventing
  /// an identity for it.
  public static func parse(_ value: JSONValue) -> WeChatInboundMessage? {
    guard let messageID = messageID(of: value), let sender = nonEmpty(value["from_user_id"]) else {
      return nil
    }
    let isOutbound = value["message_type"]?.intValue == ILinkProtocol.outboundMessageType
    let items = value["item_list"]?.arrayValue ?? []
    let text = firstText(in: items) ?? ""
    let attachments = attachments(in: items)
    // Spelled out rather than chained: the alternative spellings make one `??`-chain the
    // compiler gives up on, and an explicit lookup says exactly which keys are honoured.
    var explicitTimestamp: Double? = value["create_time_ms"]?.doubleValue
    if explicitTimestamp == nil { explicitTimestamp = value["createTimeMs"]?.doubleValue }
    if explicitTimestamp == nil { explicitTimestamp = value["update_time_ms"]?.doubleValue }
    return WeChatInboundMessage(
      messageID: messageID,
      sender: sender,
      sequence: value["seq"]?.intValue,
      timestampMs: explicitTimestamp ?? messageTimestampMs(messageID),
      contextToken: nonEmpty(value["context_token"]),
      runID: nonEmpty(value["run_id"]),
      text: text,
      attachments: attachments,
      isOutbound: isOutbound
    )
  }

  /// The provider's own id for a message, falling back to the client id.
  public static func messageID(of value: JSONValue) -> String? {
    if let raw = value["message_id"], !raw.isNull {
      if let number = raw.doubleValue, number.isFinite {
        // `message_id` is a 64-bit integer. `JSONValue` stores numbers as `Double`, so
        // ids beyond 2^53 are already rounded — the same loss JSON.parse suffers here —
        // and both sides of the comparison therefore agree on the rounded value.
        return String(Int64(number))
      }
      if let text = nonEmpty(raw) { return text }
    }
    return nonEmpty(value["client_id"])
  }

  /// Decode the millisecond timestamp carried by current 64-bit iLink message ids.
  ///
  /// The id is parsed as an integer **string** rather than through `Double`, so a 19-digit
  /// id keeps its exact value where it matters. Ids outside the documented shape yield
  /// `nil` instead of a nonsense timestamp.
  public static func messageTimestampMs(_ messageID: String, now: Double = Date().timeIntervalSince1970 * 1000) -> Double? {
    let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 16, trimmed.count <= 20, trimmed.allSatisfy(\.isNumber),
          let raw = UInt64(trimmed) else { return nil }
    let timestampMs = raw >> messageIDTimestampShift
    let value = Double(timestampMs)
    // 2020-01-01 and "no more than a day into the future" bound the plausible range, so a
    // client id that merely looks numeric cannot masquerade as a message time.
    let floor = Date.UTC(year: 2020, month: 1, day: 1)
    guard value >= floor, value <= now + 24 * 60 * 60 * 1000 else { return nil }
    return value
  }

  static func firstText(in items: [JSONValue]) -> String? {
    for item in items {
      if item["type"]?.intValue == 1, let text = nonEmpty(item["text_item"]?["text"]) {
        return text
      }
      if item["type"]?.intValue == 3, let text = nonEmpty(item["voice_item"]?["text"]) {
        return text
      }
    }
    return nil
  }

  static func attachments(in items: [JSONValue]) -> [WeChatAttachment] {
    var out: [WeChatAttachment] = []
    var imageCount = 0
    for item in items {
      if let image = item["image_item"], case .object = image {
        imageCount += 1
        out.append(WeChatAttachment(
          kind: .image,
          name: imageCount == 1 ? "image" : "image-\(imageCount)",
          byteCount: nil,
          descriptor: image
        ))
        continue
      }
      if let file = item["file_item"], case .object = file {
        let fileCount = out.filter { $0.kind == .file }.count
        let declared = file["len"]?.doubleValue
        out.append(WeChatAttachment(
          kind: .file,
          name: nonEmpty(file["file_name"]) ?? (fileCount == 0 ? "file" : "file-\(fileCount + 1)"),
          byteCount: declared.flatMap { $0 >= 0 ? Int($0) : nil },
          descriptor: file
        ))
      }
    }
    return out
  }

  static func nonEmpty(_ value: JSONValue?) -> String? {
    guard let text = value?.stringValue else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Split long text the way the channel answers: prefer a newline boundary, but never
  /// split before 60% of the limit (a message that is mostly one long line must still be
  /// cut rather than sent unsplit).
  public static func splitText(_ text: String, maxCharacters: Int = ILinkProtocol.maxMessageCharacters) -> [String] {
    guard maxCharacters > 0 else { return [text] }
    if text.count <= maxCharacters { return [text] }
    var remaining = Array(text)
    var chunks: [String] = []
    while remaining.count > maxCharacters {
      let window = remaining[0..<maxCharacters]
      var splitAt = window.lastIndex(of: "\n") ?? maxCharacters
      let floor = Int(Double(maxCharacters) * 0.6)
      if splitAt < floor { splitAt = maxCharacters }
      chunks.append(String(remaining[0..<splitAt]))
      var next = splitAt
      while next < remaining.count, remaining[next] == "\n" { next += 1 }
      remaining.removeFirst(next)
    }
    if !remaining.isEmpty { chunks.append(String(remaining)) }
    return chunks
  }
}

extension Date {
  /// UTC midnight for a calendar date, used as the plausibility floor for message times.
  static func UTC(year: Int, month: Int, day: Int) -> Double {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    guard let date = calendar.date(from: components) else { return 0 }
    return date.timeIntervalSince1970 * 1000
  }
}
