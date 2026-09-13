import Foundation
import HarnessKit
import XCTest

@testable import HarnessIM

/// A transport that answers from a script and records what it was asked.
///
/// The harness `/api` is a private contract: these tests are the regression fence around
/// the envelope, the auth handshake, and the endpoint argument names, so a future harness
/// that renames something fails here instead of in the user's chat.
final class StubHarnessTransport: HarnessAPITransport, @unchecked Sendable {
  struct Call: Sendable, Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data?
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  private let responder: @Sendable (Call) -> HarnessAPIResponse

  init(responder: @escaping @Sendable (Call) -> HarnessAPIResponse) {
    self.responder = responder
  }

  var calls: [Call] {
    lock.lock(); defer { lock.unlock() }
    return recorded
  }

  func send(_ request: HarnessAPIRequest) async throws -> HarnessAPIResponse {
    let call = Call(method: request.method, path: request.path, headers: request.headers, body: request.body)
    lock.lock(); recorded.append(call); lock.unlock()
    return responder(call)
  }
}

private func okResponse(_ value: String) -> HarnessAPIResponse {
  HarnessAPIResponse(status: 200, body: Data(#"{"type":"server-response","rpcId":"x","result":{"ok":true,"value":\#(value)}}"#.utf8))
}

private func errorResponse(_ code: String, _ message: String = "nope") -> HarnessAPIResponse {
  HarnessAPIResponse(status: 200, body: Data(
    #"{"type":"server-response","rpcId":"x","result":{"ok":false,"error":{"code":"\#(code)","message":"\#(message)","details":{}}}}"#.utf8
  ))
}

final class HarnessAPIClientTests: XCTestCase {
  // MARK: - URL parsing

  func testParsesOriginAndTokenFromAuthenticatedURL() throws {
    let parsed = try HarnessAPIClient.parse(
      authenticatedURL: try XCTUnwrap(URL(string: "http://127.0.0.1:59995/?token=abc123"))
    )
    XCTAssertEqual(parsed.origin.absoluteString, "http://127.0.0.1:59995")
    XCTAssertEqual(parsed.token, "abc123")
  }

  func testRejectsURLWithoutToken() throws {
    XCTAssertThrowsError(try HarnessAPIClient.parse(
      authenticatedURL: try XCTUnwrap(URL(string: "http://127.0.0.1:59995/"))
    )) { error in
      XCTAssertEqual((error as? HarnessAPIError)?.code, .unauthorized)
    }
  }

  // MARK: - Handshake

  /// The live harness answers `303 See Other` with `Set-Cookie`; the cookie — the whole
  /// `name=value` pair — is what every later call must carry.
  func testHandshakeKeepsCookieFromRedirect() async throws {
    let transport = StubHarnessTransport { call in
      XCTAssertEqual(call.method, "GET")
      XCTAssertEqual(call.path, "http://127.0.0.1:59995/?token=tok")
      return HarnessAPIResponse(
        status: 303,
        headers: ["set-cookie": "dsh-auth-abc=payload.sig; Max-Age=2592000; Path=/; HttpOnly"],
        body: Data()
      )
    }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:59995")), transport: transport)
    try await client.authenticate(token: "tok")
    let authenticated = await client.hasAuthenticated
    XCTAssertTrue(authenticated)

    let calls = transport.calls
    XCTAssertEqual(calls.count, 1)
  }

  func testHandshakeReportsRejectedToken() async throws {
    let transport = StubHarnessTransport { _ in HarnessAPIResponse(status: 401, body: Data()) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    do {
      try await client.authenticate(token: "bad")
      XCTFail("expected unauthorized")
    } catch {
      XCTAssertEqual((error as? HarnessAPIError)?.code, .unauthorized)
    }
  }

  // MARK: - Envelope

  func testCallBuildsTheWireEnvelope() async throws {
    let transport = StubHarnessTransport { _ in okResponse(#"{"sessionId":"session-1"}"#) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:59995")), transport: transport)
    _ = try await client.call(endpoint: "session/create", args: .object(["request": .object(["cwd": .string("/ws")])]))

    let call = try XCTUnwrap(transport.calls.first)
    XCTAssertEqual(call.method, "POST")
    XCTAssertEqual(call.path, "http://127.0.0.1:59995/api/session/create")
    XCTAssertEqual(call.headers["content-type"], "application/json")

    let body = try JSONValue.parse(try XCTUnwrap(call.body))
    XCTAssertEqual(body["type"]?.stringValue, "client-request")
    XCTAssertEqual(body["method"]?.stringValue, "session/create")
    XCTAssertFalse(try XCTUnwrap(body["rpcId"]?.stringValue).isEmpty)
    XCTAssertEqual(body.path("payload.args.request.cwd")?.stringValue, "/ws")
  }

  func testCallSendsTheStoredCookie() async throws {
    let transport = StubHarnessTransport { call in
      if call.method == "GET" {
        return HarnessAPIResponse(status: 303, headers: ["set-cookie": "dsh-auth-k=v; Path=/"], body: Data())
      }
      XCTAssertEqual(call.headers["cookie"], "dsh-auth-k=v")
      return okResponse("{}")
    }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    try await client.authenticate(token: "t")
    _ = try await client.call(endpoint: "session/cancel", args: .object([:]))
  }

  func testCallSurfacesProviderRejection() async throws {
    let transport = StubHarnessTransport { _ in errorResponse("session/agent-busy", "prompt rejected") }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    do {
      _ = try await client.call(endpoint: "session/prompt", args: .object([:]))
      XCTFail("expected rejection")
    } catch {
      let apiError = error as? HarnessAPIError
      XCTAssertEqual(apiError?.code, .rejected)
      XCTAssertEqual(apiError?.providerCode, "session/agent-busy")
      XCTAssertEqual(apiError?.message, "prompt rejected")
    }
  }

  func testCallRejectsMalformedEnvelope() async throws {
    let transport = StubHarnessTransport { _ in HarnessAPIResponse(status: 200, body: Data("<html>".utf8)) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    do {
      _ = try await client.call(endpoint: "session/create", args: .object([:]))
      XCTFail("expected malformed")
    } catch {
      XCTAssertEqual((error as? HarnessAPIError)?.code, .malformedEnvelope)
    }
  }

  func testCallReportsUnauthorizedSeparately() async throws {
    let transport = StubHarnessTransport { _ in HarnessAPIResponse(status: 401, body: Data()) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    do {
      _ = try await client.call(endpoint: "session/create", args: .object([:]))
      XCTFail("expected unauthorized")
    } catch {
      XCTAssertEqual((error as? HarnessAPIError)?.code, .unauthorized)
    }
  }

  // MARK: - Endpoints

  func testCreateSessionReturnsTheHostIDAndPassesPreset() async throws {
    let transport = StubHarnessTransport { _ in okResponse(#"{"sessionId":"session-abc","agentPreset":"standard"}"#) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    let sessionID = try await client.createSession(cwd: "/ws", agentPreset: "standard")
    XCTAssertEqual(sessionID, "session-abc")
    let body = try JSONValue.parse(try XCTUnwrap(transport.calls.first?.body))
    XCTAssertEqual(body.path("payload.args.request.cwd")?.stringValue, "/ws")
    XCTAssertEqual(body.path("payload.args.request.agentPreset")?.stringValue, "standard")
  }

  func testCreateSessionRejectsMissingID() async throws {
    let transport = StubHarnessTransport { _ in okResponse("{}") }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    do {
      _ = try await client.createSession(cwd: "/ws")
      XCTFail("expected malformed")
    } catch {
      XCTAssertEqual((error as? HarnessAPIError)?.code, .malformedEnvelope)
    }
  }

  /// `fileUploads/upload` is agent-scoped: the argument names are `agentId` and `request`.
  func testUploadFileSendsAgentScopedBase64() async throws {
    let transport = StubHarnessTransport { _ in okResponse(#"{"receiptId":"receipt-9","file":{}}"#) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    let receipt = try await client.uploadFile(sessionID: "session-1", data: Data("hello".utf8), name: "a.txt")
    XCTAssertEqual(receipt, "receipt-9")
    let body = try JSONValue.parse(try XCTUnwrap(transport.calls.first?.body))
    XCTAssertEqual(body.path("payload.args.agentId")?.stringValue, "session-1")
    XCTAssertEqual(body.path("payload.args.request.name")?.stringValue, "a.txt")
    XCTAssertEqual(body.path("payload.args.request.data")?.stringValue, Data("hello".utf8).base64EncodedString())
  }

  /// The prompt's `requestId` is returned because it is how the reply watcher finds its turn.
  func testPromptReturnsRequestIDAndSendsContentBlocks() async throws {
    let transport = StubHarnessTransport { _ in okResponse(#"{"accepted":true}"#) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    let requestId = try await client.prompt(sessionID: "session-1", content: [
      .object(["type": .string("text"), "text": .string("你好")]),
    ])
    XCTAssertFalse(requestId.isEmpty)
    let body = try JSONValue.parse(try XCTUnwrap(transport.calls.first?.body))
    XCTAssertEqual(body.path("payload.args.request.sessionId")?.stringValue, "session-1")
    XCTAssertEqual(body.path("payload.args.request.mode")?.stringValue, "queue")
    XCTAssertEqual(body.path("payload.args.request.requestId")?.stringValue, requestId)
    XCTAssertEqual(body.path("payload.args.request.content.0.text")?.stringValue, "你好")
  }

  // MARK: - Workspace registration

  /// `workspace/create` is the call that makes a folder appear in the harness sidebar, and it
  /// is idempotent — the host answers `created: false` for a folder it already knows.
  func testCreateWorkspaceParsesIDAndCreatedFlag() async throws {
    let transport = StubHarnessTransport { call in
      XCTAssertEqual(call.path, "http://127.0.0.1:1/api/workspace/create")
      return okResponse(#"{"workspace":{"workspaceId":"ws-1","path":"/ws","title":"ws","sessionIds":[]},"created":false}"#)
    }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    let result = try await client.createWorkspace(path: "/ws")
    XCTAssertEqual(result.workspaceID, "ws-1")
    XCTAssertFalse(result.created)
    let body = try JSONValue.parse(try XCTUnwrap(transport.calls.first?.body))
    XCTAssertEqual(body.path("payload.args.request.path")?.stringValue, "/ws")
  }

  func testCreateWorkspaceRejectsMissingID() async throws {
    let transport = StubHarnessTransport { _ in okResponse(#"{"workspace":{},"created":true}"#) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    do {
      _ = try await client.createWorkspace(path: "/ws")
      XCTFail("expected malformed")
    } catch {
      XCTAssertEqual((error as? HarnessAPIError)?.code, .malformedEnvelope)
    }
  }

  /// Addressing a session by workspace is what attaches it; `cwd` must be absent because the
  /// host rejects the pair outright.
  func testCreateSessionInWorkspaceSendsOnlyWorkspaceID() async throws {
    let transport = StubHarnessTransport { _ in okResponse(#"{"sessionId":"session-1"}"#) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    let sessionID = try await client.createSession(inWorkspace: "ws-1")
    XCTAssertEqual(sessionID, "session-1")
    let request = try XCTUnwrap(
      try JSONValue.parse(try XCTUnwrap(transport.calls.first?.body)).path("payload.args.request")
    )
    XCTAssertEqual(request["workspaceId"]?.stringValue, "ws-1")
    XCTAssertNil(request["cwd"])
  }

  /// Adoption is the repair for a session that predates the registration.
  func testCreateSessionAdoptsAnExistingSession() async throws {
    let transport = StubHarnessTransport { _ in okResponse(#"{"sessionId":"session-old"}"#) }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    let sessionID = try await client.createSession(inWorkspace: "ws-1", adopting: "session-old")
    XCTAssertEqual(sessionID, "session-old")
    let request = try XCTUnwrap(
      try JSONValue.parse(try XCTUnwrap(transport.calls.first?.body)).path("payload.args.request")
    )
    XCTAssertEqual(request["sessionId"]?.stringValue, "session-old")
    XCTAssertEqual(request["workspaceId"]?.stringValue, "ws-1")
  }

  func testRenameSendsTitleAndIgnoresBlank() async throws {
    let transport = StubHarnessTransport { _ in okResponse("{}") }
    let client = HarnessAPIClient(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), transport: transport)
    try await client.rename(sessionID: "session-1", title: "  微信 · owner  ")
    let request = try XCTUnwrap(
      try JSONValue.parse(try XCTUnwrap(transport.calls.first?.body)).path("payload.args.request")
    )
    XCTAssertEqual(request["title"]?.stringValue, "微信 · owner")
    XCTAssertEqual(request["sessionId"]?.stringValue, "session-1")

    try await client.rename(sessionID: "session-1", title: "   ")
    XCTAssertEqual(transport.calls.count, 1, "a blank title is not worth a round trip")
  }
}

final class HarnessAPICompatibilityTests: XCTestCase {
  private func client(_ responder: @escaping @Sendable (StubHarnessTransport.Call) -> HarnessAPIResponse) throws -> HarnessAPIClient {
    HarnessAPIClient(
      baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")),
      transport: StubHarnessTransport(responder: responder)
    )
  }

  /// Measured against a live harness: an existing endpoint rejects empty args with a gateway
  /// error, a missing one answers 404. That difference is what makes probing side-effect free.
  func testClassifiesGatewayRejectionAsAvailable() {
    let error = HarnessAPIError(code: .rejected, message: "args", providerCode: "gateway/arguments-invalid")
    XCTAssertEqual(HarnessAPICompatibility.classify(error), .available)
  }

  func testClassifies404AsMissing() {
    let error = HarnessAPIError(code: .http, message: "not found", status: 404)
    XCTAssertEqual(HarnessAPICompatibility.classify(error), .missing)
  }

  func testClassifiesUnauthorizedAsUnknown() {
    let error = HarnessAPIError(code: .unauthorized, message: "auth", status: 401)
    XCTAssertEqual(HarnessAPICompatibility.classify(error), .unknown("auth"))
  }

  func testProbeReportsEverythingAvailable() async throws {
    let probing = try client { _ in errorResponse("gateway/arguments-invalid") }
    let capabilities = await HarnessAPICompatibility.probe(client: probing)
    XCTAssertTrue(capabilities.canCreateSession)
    XCTAssertTrue(capabilities.canUploadFiles)
    XCTAssertTrue(capabilities.canCancelSession)
    XCTAssertTrue(capabilities.canPageSession)
    XCTAssertTrue(capabilities.notes.isEmpty)
  }

  /// A harness that lost `fileUploads/upload` must degrade to a named note, not to a failed
  /// submission discovered halfway through.
  func testProbeNamesMissingUploadCapability() async throws {
    let probing = try client { call in
      if call.path.hasSuffix("fileUploads/upload") {
        return HarnessAPIResponse(status: 404, body: Data("not found".utf8))
      }
      return errorResponse("gateway/arguments-invalid")
    }
    let capabilities = await HarnessAPICompatibility.probe(client: probing)
    XCTAssertFalse(capabilities.canUploadFiles)
    XCTAssertTrue(capabilities.canCreateSession)
    XCTAssertTrue(capabilities.notes.contains { $0.contains("fileUploads/upload") })
  }
}
