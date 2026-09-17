import Foundation
import HarnessKit

/// Wire constants and header rules for the WeChat iLink bot protocol.
///
/// Every value here was read out of `@xmanrui/dsh-im` 4.18.1's
/// `src/channels/weixin/weixin-api.mjs`, which is the only working implementation of
/// this protocol on this machine. The native channel speaks the same protocol against a
/// **different bot account**, so the two integrations never poll the same account:
/// iLink delivers each account's messages to exactly one long-poll holder.
public enum ILinkProtocol {
  /// QR/login host. `get_qrcode_status` is the only unauthenticated endpoint.
  public static let qrBaseURL = "https://ilinkai.weixin.qq.com/"
  /// Media CDN. Downloads and uploads are separate hosts from the message API.
  public static let cdnBaseURL = "https://novac2c.cdn.weixin.qq.com/c2c"
  public static let cdnHost = "novac2c.cdn.weixin.qq.com"
  /// Fixed protocol generation the client advertises.
  public static let channelVersion = "2.4.6"
  /// Bot type used when creating a QR login (`bot_type=3`).
  public static let defaultBotType = "3"
  public static let appID = "bot"
  /// `(2 << 16) | (4 << 8) | 6`, matching the shipped client version integer.
  public static let clientVersion = 132_102
  public static let botAgent = "DeepSeekHarness/1.1.0"
  /// Long poll hold time; the server answers earlier when a message arrives.
  public static let longPollTimeout: TimeInterval = 35
  public static let defaultTimeout: TimeInterval = 15
  /// Outbound text is split at this many characters, matching the channel's own splitter.
  public static let maxMessageCharacters = 1_800
  /// Per-image ceiling the harness accepts for inline image parts.
  public static let maxImageBytes = 5 * 1024 * 1024
  /// Whole-batch attachment ceiling enforced before a submission is attempted.
  public static let maxBatchBytes = 20 * 1024 * 1024

  /// `message_type` the bot itself sends; inbound sync echoes them back.
  public static let outboundMessageType = 2
  /// `message_state` used for a fully delivered outbound message.
  public static let deliveredMessageState = 2

  /// Login states the QR endpoint can report.
  ///
  /// Unknown values are surfaced rather than mapped to a default: a future protocol
  /// revision adding a state must not silently look like "waiting".
  public enum LoginStatus: Sendable, Equatable {
    case wait
    case scanned
    case confirmed
    case expired
    case scannedButRedirect
    case needVerifyCode
    case verifyCodeBlocked
    case boundRedirect
    case unknown(String)

    public init(raw: String) {
      switch raw {
      case "wait": self = .wait
      case "scaned": self = .scanned
      case "confirmed": self = .confirmed
      case "expired": self = .expired
      case "scaned_but_redirect": self = .scannedButRedirect
      case "need_verifycode": self = .needVerifyCode
      case "verify_code_blocked": self = .verifyCodeBlocked
      case "binded_redirect": self = .boundRedirect
      default: self = .unknown(raw)
      }
    }

    public var rawValue: String {
      switch self {
      case .wait: return "wait"
      case .scanned: return "scaned"
      case .confirmed: return "confirmed"
      case .expired: return "expired"
      case .scannedButRedirect: return "scaned_but_redirect"
      case .needVerifyCode: return "need_verifycode"
      case .verifyCodeBlocked: return "verify_code_blocked"
      case .boundRedirect: return "binded_redirect"
      case .unknown(let raw): return raw
      }
    }

    /// Whether polling should continue for this state.
    public var isTerminal: Bool {
      switch self {
      case .expired, .verifyCodeBlocked, .unknown: return true
      default: return false
      }
    }
  }

  /// Headers every request carries, authenticated or not.
  public static func commonHeaders() -> [String: String] {
    [
      "iLink-App-Id": appID,
      "iLink-App-ClientVersion": String(clientVersion),
    ]
  }

  /// Headers for an authenticated request.
  ///
  /// `X-WECHAT-UIN` is four random bytes rendered as their decimal uint32 and then
  /// base64-encoded; it identifies one client instance, so it is regenerated per request
  /// exactly as the reference client does.
  public static func authenticatedHeaders(token: String, randomUIN: () -> UInt32 = { .random(in: 0...UInt32.max) }) -> [String: String] {
    var headers = commonHeaders()
    headers["content-type"] = "application/json"
    headers["AuthorizationType"] = "ilink_bot_token"
    let decimal = String(randomUIN(), radix: 10)
    headers["X-WECHAT-UIN"] = Data(decimal.utf8).base64EncodedString()
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { headers["Authorization"] = "Bearer \(trimmed)" }
    return headers
  }

  /// The `base_info` envelope every authenticated body carries.
  public static func baseInfo() -> JSONValue {
    .object([
      "channel_version": .string(channelVersion),
      "bot_agent": .string(botAgent),
    ])
  }

  /// Reject any host that is not the WeChat service the client is pinned to.
  ///
  /// Download URLs arrive inside messages, so this is the fence that keeps a crafted
  /// message from turning the channel into a request forwarder.
  public static func isTrustedHost(_ host: String) -> Bool {
    let lowered = host.lowercased()
    return lowered == cdnHost
      || lowered == "weixin.qq.com"
      || lowered.hasSuffix(".weixin.qq.com")
      || lowered == "wechat.com"
      || lowered.hasSuffix(".wechat.com")
  }

  /// Characters that survive unescaped inside a query value (RFC 3986 unreserved).
  ///
  /// `.alphanumerics` is *not* enough here: it escapes `-`, `_` and `.`, which are exactly
  /// the base64url characters the CDN's encrypted query parameter can contain — escaping
  /// them corrupts the download token rather than making it safer.
  public static let queryValueAllowed: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }()

  /// Percent-encode one query value.
  public static func queryEncoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
  }
}

/// Failures the iLink client surfaces to the channel.
public struct ILinkError: Error, Equatable, Sendable {
  public enum Code: String, Sendable {
    case http
    case network
    case timeout
    case invalidResponse
    case invalidLoginStatus
    case untrustedEndpoint
    case providerRejected
    /// The provider says the session is over (`-14`): a new QR scan is the only way back.
    case sessionExpired
    /// The provider refused the request itself (`-2`): the call was wrong, the binding is fine.
    case invalidRequest
    case notConfigured
    case mediaTooLarge
    case decryptionFailed
  }

  public let code: Code
  public let message: String
  public let status: Int?

  public init(_ code: Code, _ message: String, status: Int? = nil) {
    self.code = code
    self.message = message
    self.status = status
  }
}

extension ILinkError: LocalizedError {
  public var errorDescription: String? { message }
}

/// Whether a provider response body reports success.
///
/// iLink answers HTTP 200 for application-level failures and puts the verdict in
/// `ret`, so a client that only checks the status code would treat "not logged in"
/// as a successful long poll forever. An expired session is reported separately as
/// `errcode: -14` (that is the code the provider's own SDKs re-login on), so both
/// spellings are read rather than assuming one and spinning on the other.
public enum ILinkResponse {
  public static func rejectionCode(_ value: JSONValue) -> String? {
    if let code = code(value["ret"]) { return code }
    return code(value["errcode"])
  }

  /// The provider's own sentence about a rejection, when it sent one.
  ///
  /// `ret` alone cannot tell "you sent a field I do not accept" from "your session is over";
  /// the body is the only place that can, and dropping it makes a diagnosable failure look like
  /// an unexplained "拒绝".
  public static func errorDetail(_ value: JSONValue) -> String {
    for key in ["errmsg", "err_msg", "msg", "message"] {
      if let text = value[key]?.stringValue,
         !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "：\(text)"
      }
    }
    return ""
  }

  private static func code(_ raw: JSONValue?) -> String? {
    guard let raw else { return nil }
    if let number = raw.doubleValue {
      return number == 0 ? nil : String(Int(number))
    }
    if let text = raw.stringValue {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty || trimmed == "0" ? nil : trimmed
    }
    return nil
  }
}

/// What a rejected provider response means for the channel.
///
/// The distinction is not cosmetic: a session that expired needs a new QR scan, while a request
/// the provider refused over its parameters means the *call* was wrong. Collapsing both into
/// "provider rejected" is what turned a bad parameter into "微信需要重新绑定" and stopped the
/// long poll for good.
public enum ILinkRejection: Equatable, Sendable {
  /// `-14`: the session is over; only a new login can help.
  case sessionExpired
  /// `-2`: the request body was not accepted.
  case invalidRequest
  /// Anything else, carried verbatim so an unknown code is never guessed at.
  case other(String)

  public init(rawCode: String) {
    switch rawCode {
    case "-14": self = .sessionExpired
    case "-2": self = .invalidRequest
    default: self = .other(rawCode)
    }
  }
}
