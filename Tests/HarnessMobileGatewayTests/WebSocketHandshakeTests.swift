import Foundation
import XCTest

@testable import HarnessMobileGateway

/// The upgrade is where every security decision is made, so all of it is asserted as plain
/// functions on bytes — no listener, no phone, no network.
final class WebSocketHandshakeTests: XCTestCase {
  private func request(_ lines: [String], path: String = "/ws/mobile") -> Data {
    var text = "GET \(path) HTTP/1.1\r\n"
    text += lines.joined(separator: "\r\n")
    text += "\r\n\r\n"
    return Data(text.utf8)
  }

  private func parsed(_ data: Data) throws -> WebSocketHandshakeRequest {
    switch WebSocketHandshake.parse(data) {
    case .request(let request, _): return request
    case .incomplete: throw XCTSkip("parser said incomplete")
    case .malformed(let reason): throw XCTSkip("malformed: \(reason)")
    }
  }

  func testParsesRequestLineAndHeaders() throws {
    let data = request([
      "Host: 192.168.1.10:3081",
      "Upgrade: websocket",
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
      "Sec-WebSocket-Protocol: dsh-mobile-v1, dsh-auth.TOKEN",
    ])
    let request = try parsed(data)
    XCTAssertEqual(request.method, "GET")
    XCTAssertEqual(request.path, "/ws/mobile")
    XCTAssertEqual(request.host, "192.168.1.10:3081")
    XCTAssertEqual(request.subprotocols, ["dsh-mobile-v1", "dsh-auth.TOKEN"])
    XCTAssertEqual(request.authSubprotocol, "TOKEN")
  }

  /// The RFC 6455 example: this exact key maps to this exact accept value, and every client
  /// verifies that we computed it right.
  func testComputesTheRfcAcceptValue() {
    XCTAssertEqual(
      WebSocketHandshake.accept(for: "dGhlIHNhbXBsZSBub25jZQ=="),
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    )
  }

  func testParsesQueryAndPairingCode() throws {
    let data = request(["Host: x", "Sec-WebSocket-Key: k"], path: "/ws/mobile?pairingCode=abc-123&channel=control")
    let request = try parsed(data)
    XCTAssertEqual(request.path, "/ws/mobile")
    XCTAssertEqual(request.query["pairingCode"], "abc-123")
    XCTAssertEqual(request.query["channel"], "control")
  }

  /// Header names are case-insensitive, and the iOS client's casing is not something the
  /// server may depend on.
  func testHeaderLookupIsCaseInsensitive() throws {
    let data = request([
      "X-DSH-DEVICE-ID: ABCDEFGH12345678",
      "AUTHORIZATION: Bearer abc",
    ])
    let request = try parsed(data)
    XCTAssertEqual(request.clientDeviceID, "ABCDEFGH12345678")
    XCTAssertEqual(request.bearerToken, "abc")
  }

  func testRejectsNonUpgradeMethods() {
    let data = Data("POST /ws/mobile HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
    XCTAssertEqual(WebSocketHandshake.parse(data), .malformed("upgrade requires GET"))
  }

  func testWaitsForTheHeaderTerminator() {
    let partial = Data("GET /ws/mobile HTTP/1.1\r\nHost: x\r\n".utf8)
    XCTAssertEqual(WebSocketHandshake.parse(partial), .incomplete)
  }

  /// An unterminated header block must be refused, not buffered forever.
  func testRejectsOversizedHeaderBlock() {
    var text = "GET /ws/mobile HTTP/1.1\r\n"
    text += "X-Pad: " + String(repeating: "a", count: WebSocketHandshake.maxHeaderBytes) + "\r\n"
    XCTAssertEqual(WebSocketHandshake.parse(Data(text.utf8)), .malformed("header block too large"))
  }

  func testUpgradeResponseEchoesOnlyTheAgreedSubprotocol() {
    let response = String(
      data: WebSocketHandshake.upgradeResponse(accept: "ACC", subprotocol: "dsh-mobile-v1"),
      encoding: .utf8
    ) ?? ""
    XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
    XCTAssertTrue(response.contains("Sec-WebSocket-Accept: ACC\r\n"))
    XCTAssertTrue(response.contains("Sec-WebSocket-Protocol: dsh-mobile-v1\r\n"))
    XCTAssertTrue(response.hasSuffix("\r\n\r\n"))
  }

  func testRefusalCarriesTheReasonAsJson() {
    let response = String(
      data: WebSocketHandshake.refusalResponse(
        status: 401,
        code: "unauthorized",
        message: "missing or invalid device credential"
      ),
      encoding: .utf8
    ) ?? ""
    XCTAssertTrue(response.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    XCTAssertTrue(response.contains("\"error\":\"unauthorized\""))
    XCTAssertTrue(response.contains("missing or invalid device credential"))
    // A response the browser must not cache or sniff.
    XCTAssertTrue(response.contains("Cache-Control: no-store"))
    XCTAssertTrue(response.contains("X-Content-Type-Options: nosniff"))
    XCTAssertTrue(response.hasSuffix("\n"))
  }

  func testRefusalEscapesTheMessage() {
    let response = String(
      data: WebSocketHandshake.refusalResponse(status: 400, code: "bad-request", message: "he said \"no\"\n"),
      encoding: .utf8
    ) ?? ""
    XCTAssertTrue(response.contains("he said \\\"no\\\"\\n"))
  }
}
