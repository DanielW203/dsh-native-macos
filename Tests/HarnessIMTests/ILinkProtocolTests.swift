import Foundation
import HarnessKit
import XCTest

@testable import HarnessIM

/// Protocol constants and header rules copied from the reference client. They are pinned
/// because the provider validates them: a wrong app id or client version is answered with
/// a refusal that looks like an empty inbox.
final class ILinkProtocolTests: XCTestCase {
  func testCommonHeadersMatchTheReferenceClient() {
    let headers = ILinkProtocol.commonHeaders()
    XCTAssertEqual(headers["iLink-App-Id"], "bot")
    XCTAssertEqual(headers["iLink-App-ClientVersion"], "132102")
  }

  func testAuthenticatedHeadersCarryBearerTokenAndUIN() {
    let headers = ILinkProtocol.authenticatedHeaders(token: "  tok-1  ", randomUIN: { 4_294_967_295 })
    XCTAssertEqual(headers["Authorization"], "Bearer tok-1", "the token is trimmed")
    XCTAssertEqual(headers["AuthorizationType"], "ilink_bot_token")
    XCTAssertEqual(headers["content-type"], "application/json")
    // Four bytes rendered as their decimal value, then base64 — the reference client's shape.
    let expected = Data("4294967295".utf8).base64EncodedString()
    XCTAssertEqual(headers["X-WECHAT-UIN"], expected)
  }

  func testAuthenticatedHeadersOmitAuthorizationWithoutToken() {
    let headers = ILinkProtocol.authenticatedHeaders(token: "   ", randomUIN: { 1 })
    XCTAssertNil(headers["Authorization"])
    XCTAssertEqual(headers["AuthorizationType"], "ilink_bot_token")
  }

  func testBaseInfoCarriesProtocolAndAgent() {
    let info = ILinkProtocol.baseInfo()
    XCTAssertEqual(info["channel_version"]?.stringValue, "2.4.6")
    XCTAssertEqual(info["bot_agent"]?.stringValue, "DeepSeekHarness/1.1.0")
  }

  func testTrustedHostsRejectLookalikes() {
    XCTAssertTrue(ILinkProtocol.isTrustedHost("novac2c.cdn.weixin.qq.com"))
    XCTAssertTrue(ILinkProtocol.isTrustedHost("ilinkai.weixin.qq.com"))
    XCTAssertFalse(ILinkProtocol.isTrustedHost("weixin.qq.com.evil.example"))
    XCTAssertFalse(ILinkProtocol.isTrustedHost("evil.example"))
  }

  func testLoginStatusesRoundTripAndFlagTerminalStates() {
    for raw in ["wait", "scaned", "confirmed", "expired", "scaned_but_redirect",
                "need_verifycode", "verify_code_blocked", "binded_redirect"] {
      XCTAssertEqual(ILinkProtocol.LoginStatus(raw: raw).rawValue, raw)
    }
    XCTAssertFalse(ILinkProtocol.LoginStatus(raw: "wait").isTerminal)
    XCTAssertFalse(ILinkProtocol.LoginStatus(raw: "confirmed").isTerminal)
    XCTAssertTrue(ILinkProtocol.LoginStatus(raw: "expired").isTerminal)
    // An unknown state must not be mistaken for "still waiting".
    XCTAssertEqual(ILinkProtocol.LoginStatus(raw: "brand_new"),
                   .unknown("brand_new"))
    XCTAssertTrue(ILinkProtocol.LoginStatus(raw: "brand_new").isTerminal)
  }

  /// HTTP 200 carries application failures in `ret`, so the client must read both shapes.
  func testRejectionCodeHandlesBothRETShapes() throws {
    XCTAssertNil(ILinkResponse.rejectionCode(try JSONValue.parse(#"{ "ret": 0 }"#)))
    XCTAssertNil(ILinkResponse.rejectionCode(try JSONValue.parse(#"{ "ret": "0" }"#)))
    XCTAssertNil(ILinkResponse.rejectionCode(try JSONValue.parse(#"{ "msgs": [] }"#)))
    XCTAssertEqual(ILinkResponse.rejectionCode(try JSONValue.parse(#"{ "ret": -3 }"#)), "-3")
    XCTAssertEqual(ILinkResponse.rejectionCode(try JSONValue.parse(#"{ "ret": "token-expired" }"#)), "token-expired")
  }

  /// An expired session is reported as `errcode: -14`, not as `ret`, and it can arrive beside a
  /// `ret` that says nothing. Reading only `ret` is how a dead session looks like a healthy one.
  func testRejectionCodeAlsoReadsERRCODE() throws {
    XCTAssertEqual(ILinkResponse.rejectionCode(try JSONValue.parse(#"{ "errcode": -14 }"#)), "-14")
    XCTAssertEqual(
      ILinkResponse.rejectionCode(try JSONValue.parse(#"{ "ret": 0, "errcode": -14 }"#)),
      "-14"
    )
    XCTAssertNil(ILinkResponse.rejectionCode(try JSONValue.parse(#"{ "ret": 0, "errcode": 0 }"#)))
    // `ret` still wins when both are set: it is the per-call verdict.
    XCTAssertEqual(
      ILinkResponse.rejectionCode(try JSONValue.parse(#"{ "ret": -2, "errcode": -14 }"#)),
      "-2"
    )
  }

  /// The two codes that need different handling, and the rule that an unknown one is carried
  /// verbatim rather than guessed at.
  func testRejectionClassification() {
    XCTAssertEqual(ILinkRejection(rawCode: "-14"), .sessionExpired)
    XCTAssertEqual(ILinkRejection(rawCode: "-2"), .invalidRequest)
    XCTAssertEqual(ILinkRejection(rawCode: "-3"), .other("-3"))
    XCTAssertEqual(ILinkRejection(rawCode: "token-expired"), .other("token-expired"))
  }

  /// A rejection's own sentence is the only thing that says *which* parameter was wrong.
  func testRejectionDetailIsReadFromTheProviderBody() throws {
    XCTAssertEqual(
      ILinkResponse.errorDetail(try JSONValue.parse(#"{ "ret": -2, "errmsg": "text too long" }"#)),
      "：text too long"
    )
    XCTAssertEqual(
      ILinkResponse.errorDetail(try JSONValue.parse(#"{ "ret": -2, "msg": "bad token" }"#)),
      "：bad token"
    )
    XCTAssertEqual(ILinkResponse.errorDetail(try JSONValue.parse(#"{ "ret": -2, "errmsg": "  " }"#)), "")
    XCTAssertEqual(ILinkResponse.errorDetail(try JSONValue.parse(#"{ "ret": -2 }"#)), "")
  }
}
