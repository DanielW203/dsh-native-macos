import Foundation
import HarnessKit

/// One HTTP exchange with the harness host.
///
/// The transport is a seam, not ceremony: the channel's contract with the harness is a
/// private API, and pinning it down with tests requires being able to answer requests from
/// a script rather than from a running server.
public struct HarnessAPIRequest: Sendable {
  public var method: String
  public var path: String
  public var headers: [String: String]
  public var body: Data?

  public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.path = path
    self.headers = headers
    self.body = body
  }
}

public struct HarnessAPIResponse: Sendable {
  public var status: Int
  public var headers: [String: String]
  public var body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

public protocol HarnessAPITransport: Sendable {
  func send(_ request: HarnessAPIRequest) async throws -> HarnessAPIResponse

  /// Release whatever outlives one request: connection pools, sockets, descriptors.
  ///
  /// A requirement with a default implementation rather than an extension-only method. Callers
  /// hold `any HarnessAPITransport`, and a method that is not a requirement dispatches
  /// statically — the concrete transport's own implementation would never run and the pool it
  /// exists to release would leak. Stateless transports (every test double) inherit the default.
  func invalidate()
}

extension HarnessAPITransport {
  /// Nothing to release.
  public func invalidate() {}
}

/// Refuse redirects so the caller sees the response that carried the credential.
///
/// The harness answers the token-bearing root request with `303 See Other` plus
/// `Set-Cookie`. Following it is not just unnecessary — `URLSession`'s automatic follow-up
/// did **not** carry the fresh cookie in testing, so the client observed a 401 and could not
/// tell it apart from a rejected token. Reading the `303` and keeping the cookie explicitly
/// is both simpler and observable.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// `URLSession` transport.
///
/// The harness cookie is held by this session's ephemeral storage, and the client also keeps
/// its own copy so a handshake works with any transport.
public final class URLSessionHarnessTransport: HarnessAPITransport, @unchecked Sendable {
  private let session: URLSession

  public init(timeout: TimeInterval = 30) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.httpCookieStorage = HTTPCookieStorage()
    configuration.httpCookieAcceptPolicy = .always
    configuration.httpShouldSetCookies = true
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }

  /// The session itself, so a caller that also needs a WebSocket (the `$events` stream) shares
  /// one connection pool instead of standing up a second pool that nothing ever tears down.
  var connectionSession: URLSession { session }

  /// Close every connection this transport owns.
  ///
  /// Foundation keeps a session's connections — and therefore its descriptors — alive until the
  /// session is invalidated, so "the transport went out of scope" is not enough. Measured on
  /// this app: an evening of per-operation transports left ~4 800 closed-but-open sockets in the
  /// process, which is what `EMFILE` (and a state file that could no longer be written) looked
  /// like from the outside.
  public func invalidate() {
    session.invalidateAndCancel()
  }

  deinit {
    // Backstop for a transport dropped without an explicit `invalidate()`.
    session.invalidateAndCancel()
  }

  public func send(_ request: HarnessAPIRequest) async throws -> HarnessAPIResponse {
    guard let url = URL(string: request.path) else {
      throw HarnessAPIError(code: .invalidURL, message: "请求地址无效：\(request.path)")
    }
    var urlRequest = URLRequest(url: url)
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
      return HarnessAPIResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    } catch {
      throw HarnessAPIError(code: .transport, message: "无法连接 harness：\(error.localizedDescription)")
    }
  }
}

/// A failure from the harness host.
public struct HarnessAPIError: Error, Equatable, Sendable {
  public enum Code: String, Sendable {
    case invalidURL
    case transport
    case unauthorized
    case http
    /// The host answered, but not with the RPC envelope this client speaks.
    case malformedEnvelope
    /// The host rejected the call; `providerCode` carries its own error code.
    case rejected
  }

  public let code: Code
  public let message: String
  public let providerCode: String?
  public let status: Int?

  public init(code: Code, message: String, providerCode: String? = nil, status: Int? = nil) {
    self.code = code
    self.message = message
    self.providerCode = providerCode
    self.status = status
  }
}

extension HarnessAPIError: LocalizedError {
  public var errorDescription: String? { message }
}

/// A client for the harness host's local `/api` channel.
///
/// This is the same transport the harness's own browser front-end uses, so a session the
/// channel creates behaves exactly like one created in the GUI — it appears in the session
/// list, streams to any open window, and inherits the host's permissions. Nothing here
/// writes to the harness home: the client only calls RPC endpoints.
///
/// The API is private to the harness, so every call is written to survive *shape* drift:
/// unknown fields are ignored and an unknown error code is surfaced verbatim instead of
/// being mapped onto a guess.
public actor HarnessAPIClient {
  private let baseURL: URL
  private let transport: HarnessAPITransport
  private var cookie: String?

  public init(baseURL: URL, transport: HarnessAPITransport = URLSessionHarnessTransport()) {
    self.baseURL = baseURL
    self.transport = transport
  }

  /// Release the transport's connections.
  ///
  /// Only the owner of the transport may call this: a pool shared by several clients has to
  /// outlive all of them, and invalidating it turns every later call into a transport error.
  public nonisolated func invalidate() {
    transport.invalidate()
  }

  /// Split the token-bearing URL the harness prints into an origin and a launch token.
  ///
  /// The app already holds this exact URL for its web view, so reusing it means the channel
  /// never needs the user to paste a credential.
  public static func parse(authenticatedURL url: URL) throws -> (origin: URL, token: String) {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw HarnessAPIError(code: .invalidURL, message: "harness 地址无法解析")
    }
    let token = components.queryItems?.first { $0.name == "token" }?.value
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let origin = components.url, let token, !token.isEmpty else {
      throw HarnessAPIError(code: .unauthorized, message: "harness 地址里没有可用的访问令牌")
    }
    return (origin, token)
  }

  /// Exchange the launch token for the host's signed session cookie.
  ///
  /// The token only authenticates the root request; every `/api` call afterwards answers
  /// `unauthorized` unless the cookie came back with it. Re-authentication is explicit so a
  /// restart of the harness is reported as "需要重新握手" rather than as a mysterious 401.
  public func authenticate(token: String) async throws {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw HarnessAPIError(code: .invalidURL, message: "harness 地址无法解析")
    }
    components.path = "/"
    components.queryItems = [URLQueryItem(name: "token", value: token)]
    guard let url = components.url else {
      throw HarnessAPIError(code: .invalidURL, message: "harness 地址无法解析")
    }
    let response = try await transport.send(HarnessAPIRequest(method: "GET", path: url.absoluteString))
    // 2xx and 3xx both mean the token was accepted: the host answers the plain root request
    // with an HTML index, and the token-bearing one with a redirect to clean `/`.
    guard (200..<400).contains(response.status) else {
      if response.status == 401 {
        throw HarnessAPIError(code: .unauthorized, message: "harness 拒绝了访问令牌，可能已重启", status: 401)
      }
      throw HarnessAPIError(code: .http, message: "harness 认证失败（HTTP \(response.status)）", status: response.status)
    }
    // `URLSession`'s cookie storage already holds it; keeping a copy makes the client usable
    // with a transport that does not persist cookies (tests, and any future non-URLSession
    // path). The whole `name=value` pair is kept — a bare name authenticates nothing.
    if let header = response.headers["set-cookie"] {
      cookie = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
    }
  }

  /// Whether the handshake has happened (or been carried by the transport's cookie store).
  public var hasAuthenticated: Bool { cookie != nil }

  /// The signed session cookie, for a caller that has to open a WebSocket of its own.
  ///
  /// The mux socket authenticates with this cookie rather than with a request header, so a
  /// component that needs its own logical stream — the turn watcher does, one socket per followed
  /// session — cannot go through this client's session and needs the credential. Handing it out is
  /// deliberate rather than incidental: the alternative is a second authentication round trip per
  /// stream, against a launch token that is single-use.
  public var sessionCookie: String? { cookie }

  /// The `ws(s)://…/api/remote.mux` URL, which every logical stream is opened over.
  ///
  /// `nonisolated` because it is derived from the immutable base URL alone, so a caller can build it
  /// without hopping onto the actor; the cookie beside it is mutable and is not.
  public nonisolated var muxWebSocketURL: URL? {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.path = "/api/remote.mux"
    components.query = nil
    return components.url
  }

  /// Build the host's forwarded-event stream (`$events`) over its WebSocket multiplexer.
  ///
  /// The upgrade route is fenced by the same cookie as `/api`, so the same credential that
  /// authorises a call authorises the stream; an `http` origin becomes `ws`, `https` becomes
  /// `wss`.
  public func makeRemoteEventStream() throws -> RemoteEventStream {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw HarnessAPIError(code: .invalidURL, message: "harness 地址无法解析")
    }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.path = "/api/remote.mux"
    components.query = nil
    guard let url = components.url else {
      throw HarnessAPIError(code: .invalidURL, message: "无法构造事件流地址")
    }
    return RemoteEventStream(
      client: self,
      webSocketURL: url,
      cookie: cookie,
      // Borrow the transport's pool when there is one. A stream that brings its own session
      // would add a second pool per reconnect — the relay reconnects on every dropped socket,
      // so that is the difference between one pool and thousands.
      session: (transport as? URLSessionHarnessTransport)?.connectionSession
    )
  }

  public func call(endpoint: String, args: JSONValue) async throws -> JSONValue {
    let rpcId = UUID().uuidString
    let envelope: JSONValue = .object([
      "type": .string("client-request"),
      "rpcId": .string(rpcId),
      "method": .string(endpoint),
      "payload": .object(["args": args]),
    ])
    var headers = ["content-type": "application/json"]
    if let cookie { headers["cookie"] = cookie }
    let url = baseURL.appendingPathComponent("api").appendingPathComponent(endpoint)
    let body = try JSONEncoder().encode(envelope)
    let response = try await transport.send(HarnessAPIRequest(
      method: "POST",
      path: url.absoluteString,
      headers: headers,
      body: body
    ))
    if response.status == 401 {
      throw HarnessAPIError(code: .unauthorized, message: "harness 未授权（需要重新握手）", status: 401)
    }
    guard response.status == 200 else {
      throw HarnessAPIError(code: .http, message: "harness 返回 HTTP \(response.status)", status: response.status)
    }
    guard let decoded = try? JSONValue.parse(response.body, context: "harness.api"),
          let type = decoded["type"]?.stringValue, type == "server-response",
          let result = decoded["result"] else {
      throw HarnessAPIError(code: .malformedEnvelope, message: "harness 返回了无法识别的响应")
    }
    guard result["ok"]?.boolValue == true else {
      let error = result["error"]
      let providerCode = error?["code"]?.stringValue
      let message = error?["message"]?.stringValue ?? "harness 拒绝了这个请求"
      throw HarnessAPIError(code: .rejected, message: message, providerCode: providerCode)
    }
    return result["value"] ?? .null
  }

  // MARK: - Session endpoints

  /// Create a session in a working directory. The id the host returns already carries its
  /// `session-` prefix and is the same string used for the Session's directory name.
  ///
  /// A session created this way is **not accounted for by any workspace**, so the harness
  /// sidebar will not list it. Use `createSession(inWorkspace:…)` whenever the session is
  /// meant to be visible in the GUI.
  public func createSession(cwd: String, agentPreset: String? = nil) async throws -> String {
    var request: [String: JSONValue] = ["cwd": .string(cwd)]
    if let agentPreset, !agentPreset.isEmpty { request["agentPreset"] = .string(agentPreset) }
    return try await createSession(request: request)
  }

  /// Create — or idempotently adopt — a session **inside a workspace**.
  ///
  /// The host resolves the working directory from the workspace and, crucially, attaches the
  /// session to it (`workspace.attachSession`), which is what puts it in the sidebar. Passing
  /// `adopting` takes over an existing session instead of making a new one, which is how a
  /// session created before this distinction existed is repaired.
  ///
  /// `cwd` and `workspaceId` are mutually exclusive on the wire: the host rejects both with
  /// `gateway/bad-request`. Splitting this out of `createSession(cwd:)` makes that impossible
  /// to get wrong at a call site.
  public func createSession(
    inWorkspace workspaceID: String,
    agentPreset: String? = nil,
    adopting sessionID: String? = nil
  ) async throws -> String {
    var request: [String: JSONValue] = ["workspaceId": .string(workspaceID)]
    if let agentPreset, !agentPreset.isEmpty { request["agentPreset"] = .string(agentPreset) }
    if let sessionID, !sessionID.isEmpty { request["sessionId"] = .string(sessionID) }
    return try await createSession(request: request)
  }

  private func createSession(request: [String: JSONValue]) async throws -> String {
    let value = try await call(endpoint: "session/create", args: .object(["request": .object(request)]))
    guard let sessionId = value["sessionId"]?.stringValue, !sessionId.isEmpty else {
      throw HarnessAPIError(code: .malformedEnvelope, message: "session/create 没有返回会话 id")
    }
    return sessionId
  }

  /// Register a working directory as a workspace, or resolve the existing registration.
  ///
  /// Idempotent: the host looks the path up first and answers `created: false` when it is
  /// already registered. This is the same operation the sidebar's "add workspace" performs,
  /// and it is what makes a channel folder show up in the GUI at all.
  public func createWorkspace(path: String) async throws -> (workspaceID: String, created: Bool) {
    let value = try await call(
      endpoint: "workspace/create",
      args: .object(["request": .object(["path": .string(path)])])
    )
    guard let workspaceID = value.path("workspace.workspaceId")?.stringValue, !workspaceID.isEmpty else {
      throw HarnessAPIError(code: .malformedEnvelope, message: "workspace/create 没有返回工作区 id")
    }
    return (workspaceID, value["created"]?.boolValue ?? false)
  }

  /// Set a session's title, so a channel-created conversation is identifiable in the sidebar.
  public func rename(sessionID: String, title: String) async throws {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    _ = try await call(
      endpoint: "session/rename",
      args: .object(["request": .object([
        "sessionId": .string(sessionID),
        "title": .string(trimmed),
      ])])
    )
  }

  /// Submit one user turn. `content` is the same block array the GUI sends.
  ///
  /// - Returns: the `requestId` stamped on the accepted message. The host echoes it back on
  ///   the durable `user/message` event, which is how the reply watcher identifies *this*
  ///   turn instead of guessing from timing.
  @discardableResult
  public func prompt(sessionID: String, content: [JSONValue], mode: String = "queue") async throws -> String {
    let requestId = UUID().uuidString
    let request: JSONValue = .object([
      "requestId": .string(requestId),
      "sessionId": .string(sessionID),
      "mode": .string(mode),
      "content": .array(content),
    ])
    _ = try await call(endpoint: "session/prompt", args: .object(["request": request]))
    return requestId
  }

  /// Every model the host will route to, with the reasoning tiers each one accepts.
  ///
  /// This is the same catalog the desktop model menu reads, so a model that is missing here is a
  /// model the GUI does not offer either, and a provider that failed to enumerate itself comes back
  /// in `failures` instead of silently shrinking the list.
  public func modelCatalog() async throws -> HarnessModelCatalog {
    let value = try await call(endpoint: "session/modelCatalog", args: .object([:]))
    return HarnessModelCatalog.decode(value)
  }

  /// Pin one session's model and reasoning effort for its next turn.
  ///
  /// The host validates the triple against the live adapters and records it durably on the
  /// session, so this works on an idle session, on one that has never been prompted, and on a
  /// session that is currently running (the change lands on the next request).
  ///
  /// - Parameter reasoningEffort: an adapter-owned tier id, or `nil` to fall back to the
  ///   provider's own default. Omitting the field is how the host is told "no preference" — it is
  ///   not the same request as naming a tier.
  /// - Returns: the normalized selection the host actually installed, which is authoritative:
  ///   an adapter may canonicalize what it was asked for.
  @discardableResult
  public func selectModel(
    sessionID: String,
    provider: String,
    model: String,
    reasoningEffort: String? = nil
  ) async throws -> HarnessModelSelection {
    var request: [String: JSONValue] = [
      "sessionId": .string(sessionID),
      "provider": .string(provider),
      "model": .string(model),
    ]
    if let reasoningEffort, !reasoningEffort.isEmpty {
      request["reasoningEffort"] = .string(reasoningEffort)
    }
    let value = try await call(
      endpoint: "session/selectModel",
      args: .object(["request": .object(request)])
    )
    guard let selected = HarnessModelSelection.decode(value["selected"]) else {
      throw HarnessAPIError(code: .malformedEnvelope, message: "session/selectModel 没有返回生效的模型")
    }
    return selected
  }

  /// Every session the harness knows about, newest activity first.
  ///
  /// The wire parameter of this one endpoint is literally `_request` (every other Session RPC
  /// declares `request`), so the envelope is spelled out here rather than going through the
  /// shared shape — sending the wrong key is rejected by the gateway, not ignored.
  public func listSessions() async throws -> [SessionSummary] {
    let value = try await call(endpoint: "session/list", args: .object(["_request": .object([:])]))
    return Self.sessionSummaries(from: value)
  }

  /// Decode a `session/list` payload into the browser's own row type.
  ///
  /// `updatedAt` is epoch **milliseconds** on this wire. The magnitude check keeps a payload
  /// that switched to seconds from rendering as 1970.
  ///
  /// The model fields come from the `modelSelection` projection: `next` is the pending choice when
  /// one is installed and otherwise the model the last request used, which is exactly "what this
  /// session will run next". Rows from a host too old to project it simply carry no model.
  public static func sessionSummaries(from value: JSONValue) -> [SessionSummary] {
    (value["items"]?.arrayValue ?? []).compactMap { item in
      guard let id = item["sessionId"]?.stringValue, !id.isEmpty else { return nil }
      let projection = item.path("projections.values.modelSelection")
      let selection = HarnessModelSelection.decode(projection?["next"])
        ?? HarnessModelSelection.decode(projection?["lastUsed"])
      // Subagent-ness travels as two independent signals and either one is enough: a child names its
      // parent, while a session launched as a subagent carries `origin` and may name no parent.
      // Missing this is not cosmetic — the turn watcher picks which sessions to follow by recency,
      // so a fan-out's sessions would take the user's own slots *and* push their turns to the phone.
      let parentID = item["parentSessionId"]?.stringValue.flatMap { value -> SessionID? in
        value.isEmpty ? nil : SessionID(value)
      }
      let isSubagent = parentID != nil || item["origin"]?.stringValue == "subagent"
      return SessionSummary(
        id: SessionID(id),
        title: item.path("projections.values.title")?.stringValue,
        cwd: item["cwd"]?.stringValue,
        updatedAt: epochDate(item["updatedAt"]?.doubleValue),
        model: selection?.model,
        provider: selection?.provider,
        reasoningEffort: selection?.reasoningEffort,
        parentID: parentID,
        isLive: item["running"]?.boolValue ?? false,
        isSubagent: isSubagent
      )
    }
  }

  /// Epoch milliseconds (or seconds, if the value is too small to be milliseconds) → `Date`.
  static func epochDate(_ raw: Double?) -> Date? {
    guard let raw, raw > 0 else { return nil }
    return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
  }

  /// Cancel whatever the session is running.
  public func cancel(sessionID: String) async throws {
    let request: JSONValue = .object(["sessionId": .string(sessionID)])
    _ = try await call(endpoint: "session/cancel", args: .object(["request": request]))
  }

  /// Stage one file with the host and return the receipt that a prompt can reference.
  ///
  /// The host owns the bytes from here on, so the channel never has to write into the
  /// session's workspace for the model to see an attachment.
  public func uploadFile(sessionID: String, data: Data, name: String) async throws -> String {
    let args: JSONValue = .object([
      "agentId": .string(sessionID),
      "request": .object([
        "data": .string(data.base64EncodedString()),
        "name": .string(name),
      ]),
    ])
    let value = try await call(endpoint: "fileUploads/upload", args: args)
    guard let receipt = value["receiptId"]?.stringValue, !receipt.isEmpty else {
      throw HarnessAPIError(code: .malformedEnvelope, message: "fileUploads/upload 没有返回 receiptId")
    }
    return receipt
  }

  /// Read a page of a session's durable log — the fallback reply source when the log file
  /// cannot be located (a moved workspace, a layout change, an unreadable file).
  public func page(sessionID: String, throughSeq: Int, maxMessages: Int = 50) async throws -> JSONValue {
    let request: JSONValue = .object([
      "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
      "throughSeq": .number(Double(throughSeq)),
      "maxMessages": .number(Double(maxMessages)),
    ])
    return try await call(endpoint: "session/page", args: .object(["request": request]))
  }
}
