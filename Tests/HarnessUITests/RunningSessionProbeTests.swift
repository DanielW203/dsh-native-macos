import Foundation
import HarnessIM
import XCTest

@testable import HarnessUI

private func sessionListResponse(_ items: String) -> HarnessAPIResponse {
  let body = "{\"type\":\"server-response\",\"rpcId\":\"x\",\"result\":{\"ok\":true,\"value\":{\"items\":[" + items + "]}}}"
  return HarnessAPIResponse(status: 200, body: Data(body.utf8))
}

/// The quit guard asks one question — "is a turn still running?" — and the launch token is
/// spent by the page before this ever runs. These tests pin the two halves of that contract:
/// prefer the page's cookie, and never mistake an auth failure for "nothing is running".
final class RunningSessionProbeTests: XCTestCase {
  private final class RecordingTransport: HarnessAPITransport, @unchecked Sendable {
    struct Call: Sendable, Equatable {
      var method: String
      var path: String
      var cookie: String?
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
      let call = Call(
        method: request.method,
        path: request.path,
        cookie: request.headers.first { $0.key.lowercased() == "cookie" }?.value
      )
      lock.lock(); recorded.append(call); lock.unlock()
      return responder(call)
    }
  }

  private func harnessURL() throws -> URL {
    try XCTUnwrap(URL(string: "http://127.0.0.1:64019/?token=SPENT"))
  }

  /// The page has already exchanged the token. Re-authenticating would spend nothing and
  /// fail with 401; the probe has to go straight to the API with the existing cookie.
  func testUsesProvidedCookieWithoutHandshake() async throws {
    let items = #"{"sessionId":"s1","running":true},{"sessionId":"s2","running":false},{"sessionId":"s3","running":true,"parentSessionId":"s1"},{"sessionId":"s4","running":true,"origin":"subagent"}"#
    let transport = RecordingTransport { _ in sessionListResponse(items) }

    let count = await RunningSessionProbe.liveSessionCount(
      authenticatedURL: try harnessURL(),
      sessionCookie: "dsh-auth-abc=payload.sig",
      transport: transport
    )

    XCTAssertEqual(count, 1, "only the live top-level session counts")
    XCTAssertEqual(transport.calls.map(\.method), ["POST"], "no token handshake when a cookie is available")
    XCTAssertEqual(transport.calls.first?.path, "http://127.0.0.1:64019/api/session/list")
    XCTAssertEqual(transport.calls.first?.cookie, "dsh-auth-abc=payload.sig")
  }

  /// Before the page has a cookie (or when a restart left a cookie for the old port), one
  /// token handshake is still the right fallback.
  func testFallsBackToHandshakeWithoutCookie() async throws {
    let transport = RecordingTransport { call in
      if call.method == "GET" {
        return HarnessAPIResponse(
          status: 303,
          headers: ["set-cookie": "dsh-auth-abc=fresh.sig; Path=/; HttpOnly"],
          body: Data()
        )
      }
      return sessionListResponse(#"{"sessionId":"s1","running":true}"#)
    }

    let count = await RunningSessionProbe.liveSessionCount(
      authenticatedURL: try harnessURL(),
      transport: transport
    )

    XCTAssertEqual(count, 1)
    XCTAssertEqual(transport.calls.map(\.method), ["GET", "POST"])
    XCTAssertTrue(transport.calls[0].path.contains("token=SPENT"))
    XCTAssertEqual(transport.calls[1].cookie, "dsh-auth-abc=fresh.sig")
  }

  /// A failed lookup must stay `nil` ("could not tell"), never become zero sessions: the
  /// guard treats zero as proof that it may quit without asking.
  func testReturnsNilWhenTheServerRejectsTheCookie() async throws {
    let transport = RecordingTransport { _ in
      HarnessAPIResponse(status: 401, body: Data())
    }

    let count = await RunningSessionProbe.liveSessionCount(
      authenticatedURL: try harnessURL(),
      sessionCookie: "dsh-auth-abc=stale.sig",
      transport: transport
    )

    XCTAssertNil(count)
  }
}
