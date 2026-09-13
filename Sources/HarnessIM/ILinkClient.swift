import Foundation
import HarnessKit

/// One HTTP exchange with the messaging provider.
///
/// A seam, like the harness client's: the provider protocol is undocumented and its login
/// flow needs a phone, so the request shapes have to be assertable without a live account.
public struct ILinkHTTPRequest: Sendable {
  public var method: String
  public var url: URL
  public var headers: [String: String]
  public var body: Data?
  public var timeout: TimeInterval

  public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
  }
}

public struct ILinkHTTPResponse: Sendable {
  public var status: Int
  public var body: Data
  public var headers: [String: String]

  public init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
    self.status = status
    self.body = body
    self.headers = headers
  }
}

public protocol ILinkHTTPTransport: Sendable {
  func send(_ request: ILinkHTTPRequest) async throws -> ILinkHTTPResponse
}

/// `URLSession` transport with a per-request timeout (the long poll needs its own).
public final class URLSessionILinkTransport: ILinkHTTPTransport, @unchecked Sendable {
  private let session: URLSession

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = ILinkProtocol.longPollTimeout + 10
    configuration.httpAdditionalHeaders = [:]
    session = URLSession(configuration: configuration)
  }

  public func send(_ request: ILinkHTTPRequest) async throws -> ILinkHTTPResponse {
    var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
    urlRequest.httpMethod = request.method
    for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
    urlRequest.httpBody = request.body
    do {
      let (data, response) = try await session.data(for: urlRequest)
      let http = response as? HTTPURLResponse
      var headers: [String: String] = [:]
      for (key, value) in http?.allHeaderFields ?? [:] {
        if let name = key as? String, let text = value as? String { headers[name.lowercased()] = text }
      }
      return ILinkHTTPResponse(status: http?.statusCode ?? 0, body: data, headers: headers)
    } catch let error as URLError where error.code == .timedOut {
      throw ILinkError(.timeout, "微信服务请求超时")
    } catch {
      throw ILinkError(.network, "暂时无法访问微信服务：\(error.localizedDescription)")
    }
  }
}

/// A QR login in progress.
public struct ILinkQRCode: Sendable, Equatable {
  /// Opaque token the status endpoint polls with.
  public let code: String
  /// Content to render as a QR image.
  public let content: String
}

/// One login poll's outcome.
public struct ILinkLoginResult: Sendable, Equatable {
  public let status: ILinkProtocol.LoginStatus
  public let token: String?
  public let botID: String?
  public let ownerUserID: String?
  public let baseURL: String?
  public let verificationRequiredURL: String?
}

/// The provider's message sync result.
public struct ILinkUpdates: Sendable, Equatable {
  public let messages: [JSONValue]
  public let buffer: String

  public static func empty(buffer: String) -> ILinkUpdates { ILinkUpdates(messages: [], buffer: buffer) }
}

/// The WeChat iLink client.
///
/// Deliberately a thin, transport-injected protocol layer: no state, no retry policy, no
/// session bookkeeping. The channel service owns the loop and its backoff, which keeps this
/// type assertable against recorded request/response shapes.
public actor ILinkClient {
  private let transport: ILinkHTTPTransport

  public init(transport: ILinkHTTPTransport = URLSessionILinkTransport()) {
    self.transport = transport
  }

  // MARK: - Login

  /// Ask the provider for a QR code scannable by the phone that will own this bot.
  ///
  /// The body echoes previously seen local tokens so a re-login can reuse a binding instead
  /// of creating a second bot; an empty list is the honest "first time" value.
  public func beginLogin(botType: String = ILinkProtocol.defaultBotType, localTokens: [String] = []) async throws -> ILinkQRCode {
    let endpoint = "ilink/bot/get_bot_qrcode?bot_type=\(percentEncoded(botType))"
    let body: JSONValue = .object([
      "local_token_list": .array(localTokens.suffix(10).map { .string($0) }),
    ])
    let value = try await request(
      method: "POST",
      baseURL: ILinkProtocol.qrBaseURL,
      endpoint: endpoint,
      body: body,
      timeout: ILinkProtocol.defaultTimeout,
      authenticated: false
    )
    guard let code = value["qrcode"]?.stringValue, !code.isEmpty else {
      throw ILinkError(.invalidResponse, "微信服务没有返回二维码令牌")
    }
    return ILinkQRCode(code: code, content: value["qrcode_img_content"]?.stringValue ?? "")
  }

  /// Poll one login attempt.
  public func pollLogin(qrcode: String, verifyCode: String? = nil, baseURL: String = ILinkProtocol.qrBaseURL) async throws -> ILinkLoginResult {
    var endpoint = "ilink/bot/get_qrcode_status?qrcode=\(percentEncoded(qrcode))"
    if let verifyCode, !verifyCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      endpoint += "&verify_code=\(percentEncoded(verifyCode))"
    }
    let value = try await request(
      method: "GET",
      baseURL: baseURL,
      endpoint: endpoint,
      body: nil,
      timeout: ILinkProtocol.longPollTimeout,
      authenticated: false
    )
    guard let raw = value["status"]?.stringValue else {
      throw ILinkError(.invalidLoginStatus, "微信服务返回了无法识别的扫码状态")
    }
    let status = ILinkProtocol.LoginStatus(raw: raw)
    return ILinkLoginResult(
      status: status,
      token: value["bot_token"]?.stringValue,
      botID: value["ilink_bot_id"]?.stringValue,
      ownerUserID: value["ilink_user_id"]?.stringValue,
      baseURL: value["baseurl"]?.stringValue ?? value["redirect_host"]?.stringValue,
      // `need_verifycode` may hand back a page the user must open to read the pairing code.
      verificationRequiredURL: value["verify_code_url"]?.stringValue ?? value["verification_url"]?.stringValue
    )
  }

  // MARK: - Connection lifecycle

  /// Announce that this client is online. The provider expects it before a long poll.
  public func notifyStart(token: String, baseURL: String = ILinkProtocol.qrBaseURL) async throws {
    _ = try await request(
      method: "POST", baseURL: baseURL, endpoint: "ilink/bot/msg/notifystart",
      body: .object(["base_info": ILinkProtocol.baseInfo()]),
      timeout: ILinkProtocol.defaultTimeout, authenticated: true, token: token
    )
  }

  /// Best-effort "going away" notice; the channel calls it on quit and ignores failure.
  public func notifyStop(token: String, baseURL: String = ILinkProtocol.qrBaseURL) async throws {
    _ = try await request(
      method: "POST", baseURL: baseURL, endpoint: "ilink/bot/msg/notifystop",
      body: .object(["base_info": ILinkProtocol.baseInfo()]),
      timeout: ILinkProtocol.defaultTimeout, authenticated: true, token: token
    )
  }

  // MARK: - Messages

  /// Long-poll for new messages.
  ///
  /// A timeout is a normal outcome, not a failure: the provider holds the request open until
  /// something happens. Returning the buffer unchanged keeps the cursor exactly where it was.
  public func getUpdates(
    token: String,
    baseURL: String = ILinkProtocol.qrBaseURL,
    buffer: String,
    timeout: TimeInterval = ILinkProtocol.longPollTimeout
  ) async throws -> ILinkUpdates {
    do {
      let value = try await request(
        method: "POST", baseURL: baseURL, endpoint: "ilink/bot/getupdates",
        body: .object([
          "get_updates_buf": .string(buffer),
          "base_info": ILinkProtocol.baseInfo(),
        ]),
        timeout: timeout, authenticated: true, token: token
      )
      let messages = value["msgs"]?.arrayValue ?? []
      let next = value["get_updates_buf"]?.stringValue ?? buffer
      return ILinkUpdates(messages: messages, buffer: next)
    } catch let error as ILinkError where error.code == .timeout {
      return .empty(buffer: buffer)
    }
  }

  /// Fetch the ticket required before the provider accepts a typing indicator.
  public func getConfig(
    token: String,
    toUserID: String,
    contextToken: String?,
    baseURL: String = ILinkProtocol.qrBaseURL
  ) async throws -> String? {
    var body: [String: JSONValue] = [
      "ilink_user_id": .string(toUserID),
      "base_info": ILinkProtocol.baseInfo(),
    ]
    if let contextToken, !contextToken.isEmpty { body["context_token"] = .string(contextToken) }
    let value = try await request(
      method: "POST", baseURL: baseURL, endpoint: "ilink/bot/getconfig",
      body: .object(body), timeout: ILinkProtocol.defaultTimeout, authenticated: true, token: token
    )
    return value["typing_ticket"]?.stringValue
  }

  /// Show or clear the "typing" bubble. `status` is 1 (start) or 2 (stop).
  public func sendTyping(
    token: String,
    toUserID: String,
    typingTicket: String,
    status: Int,
    baseURL: String = ILinkProtocol.qrBaseURL
  ) async throws {
    guard status == 1 || status == 2 else {
      throw ILinkError(.invalidResponse, "输入状态取值无效")
    }
    _ = try await request(
      method: "POST", baseURL: baseURL, endpoint: "ilink/bot/sendtyping",
      body: .object([
        "ilink_user_id": .string(toUserID),
        "typing_ticket": .string(typingTicket),
        "status": .number(Double(status)),
        "base_info": ILinkProtocol.baseInfo(),
      ]),
      timeout: ILinkProtocol.defaultTimeout, authenticated: true, token: token
    )
  }

  /// Send one text message.
  ///
  /// - Returns: the client-side id the provider echoes back, which is what lets the channel
  ///   recognise its own outbound message in the sync stream.
  @discardableResult
  public func sendText(
    token: String,
    toUserID: String,
    text: String,
    contextToken: String? = nil,
    runID: String? = nil,
    baseURL: String = ILinkProtocol.qrBaseURL
  ) async throws -> String {
    let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !toUserID.isEmpty, !content.isEmpty else {
      throw ILinkError(.invalidResponse, "回复内容或接收方为空")
    }
    let clientId = "dsh-native-im-\(UUID().uuidString)"
    var message: [String: JSONValue] = [
      "from_user_id": .string(""),
      "to_user_id": .string(toUserID),
      "client_id": .string(clientId),
      "message_type": .number(Double(ILinkProtocol.outboundMessageType)),
      "message_state": .number(Double(ILinkProtocol.deliveredMessageState)),
      "item_list": .array([.object(["type": .number(1), "text_item": .object(["text": .string(content)])])]),
    ]
    if let contextToken, !contextToken.isEmpty { message["context_token"] = .string(contextToken) }
    if let runID, !runID.isEmpty { message["run_id"] = .string(runID) }
    _ = try await request(
      method: "POST", baseURL: baseURL, endpoint: "ilink/bot/sendmessage",
      body: .object(["msg": .object(message), "base_info": ILinkProtocol.baseInfo()]),
      timeout: ILinkProtocol.defaultTimeout, authenticated: true, token: token
    )
    return clientId
  }

  /// Download and decrypt the bytes behind one inbound attachment.
  public func loadMedia(_ descriptor: JSONValue, maxBytes: Int = ILinkProtocol.maxImageBytes) async throws -> Data {
    try await ILinkMedia.load(descriptor: descriptor, transport: transport, maxBytes: maxBytes)
  }

  // MARK: - Plumbing

  /// Build, send, and validate one provider call.
  ///
  /// The provider answers HTTP 200 for application failures and reports the verdict in `ret`,
  /// so a client that only checked the status code would spin on "not logged in" forever.
  private func request(
    method: String,
    baseURL: String,
    endpoint: String,
    body: JSONValue?,
    timeout: TimeInterval,
    authenticated: Bool,
    token: String? = nil
  ) async throws -> JSONValue {
    guard let base = URL(string: baseURL), let url = URL(string: endpoint, relativeTo: base)?.absoluteURL else {
      throw ILinkError(.untrustedEndpoint, "微信服务地址无效")
    }
    guard ILinkProtocol.isTrustedHost(url.host ?? "") else {
      throw ILinkError(.untrustedEndpoint, "拒绝访问不受信任的微信服务地址")
    }
    var headers = authenticated
      ? ILinkProtocol.authenticatedHeaders(token: token ?? "")
      : ILinkProtocol.commonHeaders()
    if body != nil { headers["content-type"] = "application/json" }
    let encoded = try body.map { try JSONEncoder().encode($0) }
    let response = try await transport.send(ILinkHTTPRequest(
      method: method, url: url, headers: headers, body: encoded, timeout: timeout
    ))
    guard (200..<300).contains(response.status) else {
      throw ILinkError(.http, "微信服务请求失败（HTTP \(response.status)）", status: response.status)
    }
    guard let value = try? JSONValue.parse(response.body, context: "ilink") else {
      throw ILinkError(.invalidResponse, "微信服务返回了无法解析的响应")
    }
    if let rejection = ILinkResponse.rejectionCode(value) {
      throw ILinkError(.providerRejected, "微信服务拒绝了这次请求（ret \(rejection)）")
    }
    return value
  }

  private func percentEncoded(_ value: String) -> String {
    ILinkProtocol.queryEncoded(value)
  }
}
