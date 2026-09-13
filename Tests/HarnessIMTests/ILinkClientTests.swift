import Foundation
import HarnessKit
import XCTest

@testable import HarnessIM

/// A transport that answers provider calls from a script.
final class StubILinkTransport: ILinkHTTPTransport, @unchecked Sendable {
  struct Call: Sendable, Equatable {
    var method: String
    var url: String
    var headers: [String: String]
    var body: String?
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  private let responder: @Sendable (Call) -> ILinkHTTPResponse

  init(responder: @escaping @Sendable (Call) -> ILinkHTTPResponse) {
    self.responder = responder
  }

  var calls: [Call] {
    lock.lock(); defer { lock.unlock() }
    return recorded
  }

  func send(_ request: ILinkHTTPRequest) async throws -> ILinkHTTPResponse {
    let call = Call(
      method: request.method,
      url: request.url.absoluteString,
      headers: request.headers,
      body: request.body.flatMap { String(data: $0, encoding: .utf8) }
    )
    lock.lock(); recorded.append(call); lock.unlock()
    return responder(call)
  }
}

/// A transport that always fails the way a long poll does when nothing happens.
final class TimingOutILinkTransport: ILinkHTTPTransport, @unchecked Sendable {
  func send(_ request: ILinkHTTPRequest) async throws -> ILinkHTTPResponse {
    throw ILinkError(.timeout, "微信服务请求超时")
  }
}

private func json(_ text: String) -> ILinkHTTPResponse {
  ILinkHTTPResponse(status: 200, body: Data(text.utf8))
}

final class ILinkClientTests: XCTestCase {
  func testBeginLoginRequestsABotQRCode() async throws {
    let transport = StubILinkTransport { _ in
      json(#"{"qrcode":"qr-1","qrcode_img_content":"https://liteapp.weixin.qq.com/q/x"}"#)
    }
    let client = ILinkClient(transport: transport)
    let qr = try await client.beginLogin(localTokens: ["old-token"])
    XCTAssertEqual(qr.code, "qr-1")
    XCTAssertEqual(qr.content, "https://liteapp.weixin.qq.com/q/x")

    let call = try XCTUnwrap(transport.calls.first)
    XCTAssertEqual(call.method, "POST")
    XCTAssertTrue(call.url.contains("bot_type=3"))
    XCTAssertEqual(call.headers["iLink-App-Id"], "bot")
    XCTAssertNil(call.headers["Authorization"], "login is unauthenticated")
    XCTAssertEqual(try JSONValue.parse(try XCTUnwrap(call.body)).path("local_token_list.0")?.stringValue, "old-token")
  }

  func testBeginLoginRejectsMissingCode() async throws {
    let client = ILinkClient(transport: StubILinkTransport { _ in json("{}") })
    do {
      _ = try await client.beginLogin()
      XCTFail("expected invalid response")
    } catch {
      XCTAssertEqual((error as? ILinkError)?.code, .invalidResponse)
    }
  }

  /// A confirmed login carries the credential triple the channel persists.
  func testPollLoginDecodesConfirmation() async throws {
    let transport = StubILinkTransport { _ in
      json(#"{"status":"confirmed","bot_token":"tok","ilink_bot_id":"wx_1","ilink_user_id":"owner@im.wechat","baseurl":"https://ilinkai.weixin.qq.com/"}"#)
    }
    let client = ILinkClient(transport: transport)
    let result = try await client.pollLogin(qrcode: "qr-1")
    XCTAssertEqual(result.status, .confirmed)
    XCTAssertEqual(result.token, "tok")
    XCTAssertEqual(result.botID, "wx_1")
    XCTAssertEqual(result.ownerUserID, "owner@im.wechat")
    XCTAssertEqual(result.baseURL, "https://ilinkai.weixin.qq.com/")

    let call = try XCTUnwrap(transport.calls.first)
    XCTAssertEqual(call.method, "GET")
    XCTAssertTrue(call.url.contains("qrcode=qr-1"))
  }

  func testPollLoginCarriesVerifyCodeWhenSupplied() async throws {
    let transport = StubILinkTransport { _ in json(#"{"status":"wait"}"#) }
    let client = ILinkClient(transport: transport)
    _ = try await client.pollLogin(qrcode: "qr-1", verifyCode: "1234")
    XCTAssertTrue(try XCTUnwrap(transport.calls.first).url.contains("verify_code=1234"))
  }

  /// An unrecognised status must survive as itself, not be coerced into "waiting".
  func testPollLoginPreservesUnknownStatus() async throws {
    let client = ILinkClient(transport: StubILinkTransport { _ in json(#"{"status":"brand_new"}"#) })
    let result = try await client.pollLogin(qrcode: "qr")
    XCTAssertEqual(result.status, .unknown("brand_new"))
    XCTAssertTrue(result.status.isTerminal)
  }

  func testPollLoginReportsMissingStatus() async throws {
    let client = ILinkClient(transport: StubILinkTransport { _ in json("{}") })
    do {
      _ = try await client.pollLogin(qrcode: "qr")
      XCTFail("expected invalid login status")
    } catch {
      XCTAssertEqual((error as? ILinkError)?.code, .invalidLoginStatus)
    }
  }

  func testGetUpdatesReturnsMessagesAndNewCursor() async throws {
    let transport = StubILinkTransport { _ in
      json(#"{"ret":0,"msgs":[{"message_id":"1","from_user_id":"u"}],"get_updates_buf":"buf-2"}"#)
    }
    let client = ILinkClient(transport: transport)
    let updates = try await client.getUpdates(token: "tok", buffer: "buf-1")
    XCTAssertEqual(updates.messages.count, 1)
    XCTAssertEqual(updates.buffer, "buf-2")
    let body = try JSONValue.parse(try XCTUnwrap(transport.calls.first?.body))
    XCTAssertEqual(body["get_updates_buf"]?.stringValue, "buf-1")
    XCTAssertEqual(body.path("base_info.channel_version")?.stringValue, "2.4.6")
  }

  /// The long poll ends in a timeout whenever nothing happens; that must not lose the cursor.
  func testGetUpdatesTreatsTimeoutAsNoMessages() async throws {
    let client = ILinkClient(transport: TimingOutILinkTransport())
    let updates = try await client.getUpdates(token: "tok", buffer: "buf-1")
    XCTAssertTrue(updates.messages.isEmpty)
    XCTAssertEqual(updates.buffer, "buf-1")
  }

  /// HTTP 200 with a non-zero `ret` is a provider-level failure and must not look like success.
  func testProviderRejectionIsSurfaced() async throws {
    let client = ILinkClient(transport: StubILinkTransport { _ in json(#"{"ret":-3,"msgs":[]}"#) })
    do {
      _ = try await client.getUpdates(token: "tok", buffer: "b")
      XCTFail("expected provider rejection")
    } catch {
      let error = error as? ILinkError
      XCTAssertEqual(error?.code, .providerRejected)
      XCTAssertTrue(try XCTUnwrap(error?.message).contains("-3"))
    }
  }

  func testSendTextBuildsTheProviderMessage() async throws {
    let transport = StubILinkTransport { _ in json(#"{"ret":0}"#) }
    let client = ILinkClient(transport: transport)
    let clientId = try await client.sendText(
      token: "tok", toUserID: "owner@im.wechat", text: "  收到了  ", contextToken: "ctx", runID: "run"
    )

    let call = try XCTUnwrap(transport.calls.first)
    XCTAssertEqual(call.headers["Authorization"], "Bearer tok")
    XCTAssertEqual(call.url, "https://ilinkai.weixin.qq.com/ilink/bot/sendmessage")

    let body = try JSONValue.parse(try XCTUnwrap(call.body))
    XCTAssertEqual(body.path("msg.to_user_id")?.stringValue, "owner@im.wechat")
    XCTAssertEqual(body.path("msg.message_type")?.intValue, 2)
    XCTAssertEqual(body.path("msg.message_state")?.intValue, 2)
    XCTAssertEqual(body.path("msg.item_list.0.text_item.text")?.stringValue, "收到了")
    XCTAssertEqual(body.path("msg.context_token")?.stringValue, "ctx")
    XCTAssertEqual(body.path("msg.run_id")?.stringValue, "run")
    XCTAssertEqual(body.path("msg.client_id")?.stringValue, clientId)
    XCTAssertEqual(body.path("base_info.bot_agent")?.stringValue, "DeepSeekHarness/1.1.0")
  }

  func testSendTextRefusesEmptyContent() async throws {
    let client = ILinkClient(transport: StubILinkTransport { _ in json("{}") })
    do {
      _ = try await client.sendText(token: "t", toUserID: "u", text: "   ")
      XCTFail("expected refusal")
    } catch {
      XCTAssertEqual((error as? ILinkError)?.code, .invalidResponse)
    }
  }

  func testSendTypingValidatesStatus() async throws {
    let client = ILinkClient(transport: StubILinkTransport { _ in json(#"{"ret":0}"#) })
    do {
      try await client.sendTyping(token: "t", toUserID: "u", typingTicket: "ticket", status: 7)
      XCTFail("expected refusal")
    } catch {
      XCTAssertEqual((error as? ILinkError)?.code, .invalidResponse)
    }
  }

  /// Every call is fenced to WeChat hosts, so a tampered base URL cannot redirect traffic.
  func testRejectsUntrustedBaseURL() async throws {
    let client = ILinkClient(transport: StubILinkTransport { _ in json("{}") })
    do {
      _ = try await client.getUpdates(token: "t", baseURL: "https://evil.example/", buffer: "")
      XCTFail("expected refusal")
    } catch {
      XCTAssertEqual((error as? ILinkError)?.code, .untrustedEndpoint)
    }
  }
}

final class ILinkMediaTests: XCTestCase {
  /// Vector produced with `openssl enc -aes-128-ecb -K 000102…0f` over
  /// `wechat-media-test-payload`, i.e. the same construction the provider uses.
  func testDecryptsAES128ECBWithPKCS7() throws {
    let key = try XCTUnwrap(Data(hexString: "000102030405060708090a0b0c0d0e0f"))
    let ciphertext = try XCTUnwrap(Data(hexString:
      "318be9871887e6570e0c04806efbe97ce6df172ba1131961ec499096909f52b6"))
    let plaintext = try ILinkMedia.decrypt(ciphertext, key: key)
    XCTAssertEqual(String(data: plaintext, encoding: .utf8), "wechat-media-test-payload")
  }

  func testDecryptRejectsBadInput() throws {
    let key = Data(repeating: 1, count: 16)
    XCTAssertThrowsError(try ILinkMedia.decrypt(Data(repeating: 0, count: 10), key: key))
    XCTAssertThrowsError(try ILinkMedia.decrypt(Data(repeating: 0, count: 16), key: Data(repeating: 1, count: 8)))
  }

  func testParsesHexAESKey() throws {
    let descriptor = try JSONValue.parse(#"{"aeskey":"000102030405060708090A0B0C0D0E0F"}"#)
    XCTAssertEqual(try ILinkMedia.aesKey(from: descriptor), Data(hexString: "000102030405060708090a0b0c0d0e0f"))
  }

  func testParsesBase64RawKeyAndBase64HexKey() throws {
    let raw = Data(hexString: "000102030405060708090a0b0c0d0e0f")!
    let rawDescriptor = try JSONValue.parse(#"{"media":{"aes_key":"\#(raw.base64EncodedString())"}}"#)
    XCTAssertEqual(try ILinkMedia.aesKey(from: rawDescriptor), raw)

    let hexText = "000102030405060708090a0b0c0d0e0f"
    let hexDescriptor = try JSONValue.parse(
      #"{"media":{"aes_key":"\#(Data(hexText.utf8).base64EncodedString())"}}"#
    )
    XCTAssertEqual(try ILinkMedia.aesKey(from: hexDescriptor), raw)
  }

  func testRejectsInvalidKeyMaterial() throws {
    let descriptor = try JSONValue.parse(#"{"aeskey":"not-hex"}"#)
    XCTAssertThrowsError(try ILinkMedia.aesKey(from: descriptor))
  }

  func testBuildsCDNDownloadURLFromQueryParameter() throws {
    let descriptor = try JSONValue.parse(#"{"media":{"encrypt_query_param":"abc+/="}}"#)
    let url = try ILinkMedia.downloadURL(for: descriptor)
    XCTAssertEqual(url.host, "novac2c.cdn.weixin.qq.com")
    XCTAssertTrue(url.query?.contains("encrypted_query_param=abc") == true)
    XCTAssertFalse(url.query?.contains("+") == true, "the parameter must be percent-encoded")
  }

  func testAcceptsTrustedFullURLOnly() throws {
    let trusted = try JSONValue.parse(
      #"{"media":{"full_url":"https://novac2c.cdn.weixin.qq.com/c2c/download?x=1"}}"#
    )
    XCTAssertEqual(try ILinkMedia.downloadURL(for: trusted).host, "novac2c.cdn.weixin.qq.com")

    for hostile in [
      #"{"media":{"full_url":"https://evil.example/c2c/download"}}"#,
      #"{"media":{"full_url":"http://novac2c.cdn.weixin.qq.com/c2c/download"}}"#,
      #"{"media":{"full_url":"https://novac2c.cdn.weixin.qq.com/other/download"}}"#,
      #"{"media":{}}"#,
    ] {
      XCTAssertThrowsError(try ILinkMedia.downloadURL(for: try JSONValue.parse(hostile)), "accepted \(hostile)")
    }
  }

  func testLoadEnforcesSizeCeiling() async throws {
    let key = Data(hexString: "000102030405060708090a0b0c0d0e0f")!
    let descriptor = try JSONValue.parse(
      #"{"aeskey":"000102030405060708090a0b0c0d0e0f","media":{"encrypt_query_param":"q"}}"#
    )
    let tooBig = Data(repeating: 0, count: 64)
    let transport = StubILinkTransport { _ in ILinkHTTPResponse(status: 200, body: tooBig) }
    do {
      _ = try await ILinkMedia.load(descriptor: descriptor, transport: transport, maxBytes: 16)
      XCTFail("expected size refusal")
    } catch {
      XCTAssertEqual((error as? ILinkError)?.code, .mediaTooLarge)
    }
    // Guard the vector used above stays the one the parser accepts.
    XCTAssertEqual(try ILinkMedia.aesKey(from: descriptor), key)
  }
}
