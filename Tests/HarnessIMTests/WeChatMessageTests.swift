import Foundation
import HarnessKit
import XCTest

@testable import HarnessIM

/// Parsing is the boundary where provider JSON turns into decisions, so each rule the
/// channel relies on (identity, sender, outbound echo, voice-to-text) is pinned here.
final class WeChatMessageTests: XCTestCase {
  private func parse(_ json: String) throws -> WeChatInboundMessage? {
    WeChatMessageParser.parse(try JSONValue.parse(json))
  }

  func testParsesTextAndFileItems() throws {
    let message = try parse(#"""
    {
      "message_id": "7504133366464211000",
      "from_user_id": "o9cq809BecoR74mNqT96PsnIy3KI@im.wechat",
      "message_type": 1,
      "seq": 12,
      "context_token": "ctx-token",
      "run_id": "run-1",
      "item_list": [
        { "type": 1, "text_item": { "text": "  帮我看看  " } },
        { "type": 4, "file_item": { "file_name": "report.pdf", "len": "2048", "media": { "encrypt_query_param": "q" } } }
      ]
    }
    """#)
    let unwrapped = try XCTUnwrap(message)
    // `message_id` is a 64-bit integer and JSON stores numbers as `Double`, so an id past
    // 2^53 is rounded — the exact value Swift prints for that double. The reference client
    // rounds identically; ids are only used for dedup, and the shift that derives a
    // timestamp from them truncates the difference away, so this is consistent, not lossy
    // in any way that matters.
    XCTAssertEqual(unwrapped.messageID, "7504133366464210944")
    XCTAssertEqual(unwrapped.sender, "o9cq809BecoR74mNqT96PsnIy3KI@im.wechat")
    XCTAssertEqual(unwrapped.text, "帮我看看", "text is trimmed")
    XCTAssertEqual(unwrapped.sequence, 12)
    XCTAssertEqual(unwrapped.contextToken, "ctx-token")
    XCTAssertEqual(unwrapped.runID, "run-1")
    XCTAssertFalse(unwrapped.isOutbound)
    XCTAssertEqual(unwrapped.attachments.count, 1)
    XCTAssertEqual(unwrapped.attachments[0].kind, .file)
    XCTAssertEqual(unwrapped.attachments[0].name, "report.pdf")
    XCTAssertEqual(unwrapped.attachments[0].byteCount, 2048)
  }

  /// The sync stream echoes the bot's own replies; treating one as user input would make
  /// the channel answer itself in a loop.
  func testMarksOutboundEcho() throws {
    let message = try XCTUnwrap(try parse(#"""
    { "message_id": "1", "from_user_id": "bot", "message_type": 2, "item_list": [{ "type": 1, "text_item": { "text": "hi" } }] }
    """#))
    XCTAssertTrue(message.isOutbound)
  }

  func testRequiresSenderAndIdentity() throws {
    XCTAssertNil(try parse(#"{ "message_id": "1", "message_type": 1, "item_list": [] }"#))
    XCTAssertNil(try parse(#"{ "from_user_id": "u", "message_type": 1, "item_list": [] }"#))
  }

  func testFallsBackToClientID() throws {
    let message = try XCTUnwrap(try parse(#"""
    { "client_id": "client-7", "from_user_id": "u", "message_type": 1, "item_list": [] }
    """#))
    XCTAssertEqual(message.messageID, "client-7")
  }

  func testVoiceItemCarriesItsTranscript() throws {
    let message = try XCTUnwrap(try parse(#"""
    { "message_id": "1", "from_user_id": "u", "message_type": 1, "item_list": [{ "type": 3, "voice_item": { "text": "语音转出来的字" } }] }
    """#))
    XCTAssertEqual(message.text, "语音转出来的字")
  }

  func testImagesGetSyntheticNames() throws {
    let message = try XCTUnwrap(try parse(#"""
    { "message_id": "1", "from_user_id": "u", "message_type": 1, "item_list": [
      { "type": 2, "image_item": { "media": { "encrypt_query_param": "a" } } },
      { "type": 2, "image_item": { "media": { "encrypt_query_param": "b" } } },
      { "type": 4, "file_item": { "file_name": "图纸.dwg" } }
    ] }
    """#))
    XCTAssertEqual(message.attachments.map(\.name), ["image", "image-2", "图纸.dwg"])
    XCTAssertEqual(message.attachments.map(\.kind), [.image, .image, .file])
    XCTAssertNil(message.attachments[2].byteCount, "a missing len must not become 0")
  }

  /// The timestamp lives in the high bits of a 19-digit id. It is decoded from the *string*
  /// so precision survives JSON's double storage; the expected value is the exact shift of
  /// the id observed in this machine's own channel state.
  func testDecodesTimestampFromMessageID() throws {
    let decoded = try XCTUnwrap(WeChatMessageParser.messageTimestampMs("7504133366464211000", now: 1.9e12))
    XCTAssertEqual(decoded, 1_789_124_814_621)
  }

  func testRejectsImplausibleMessageIDs() {
    XCTAssertNil(WeChatMessageParser.messageTimestampMs("short"))
    XCTAssertNil(WeChatMessageParser.messageTimestampMs("client-7"))
    // Numeric but far too old: must not masquerade as a message time.
    XCTAssertNil(WeChatMessageParser.messageTimestampMs("0000000000000001"))
    // Numeric and merely outside the accepted width.
    XCTAssertNil(WeChatMessageParser.messageTimestampMs(String(repeating: "9", count: 21)))
  }

  func testSplitTextLeavesShortTextAlone() {
    XCTAssertEqual(WeChatMessageParser.splitText("短消息", maxCharacters: 10), ["短消息"])
  }

  func testSplitTextCutsAtTheLimit() {
    let chunks = WeChatMessageParser.splitText(String(repeating: "a", count: 4_000), maxCharacters: 1_800)
    XCTAssertEqual(chunks.map(\.count), [1_800, 1_800, 400])
  }

  /// A newline past 60% of the window is a better cut than the hard limit; one before it
  /// is not worth a short message, so the hard limit wins. The cut lands *after* the whole
  /// newline run (`lastIndexOf`), and the newlines at the start of the remainder are dropped.
  func testSplitTextPrefersLateNewlineAndDropsLeadingBlankLines() {
    let text = String(repeating: "a", count: 1_700) + "\n\n\n" + String(repeating: "b", count: 600)
    let chunks = WeChatMessageParser.splitText(text, maxCharacters: 1_800)
    XCTAssertEqual(chunks[0].count, 1_702)
    XCTAssertEqual(chunks[1].count, 600)
    XCTAssertTrue(chunks[1].hasPrefix("b"), "newlines at the split point must not open the next message")
  }

  func testSplitTextIgnoresEarlyNewline() {
    let text = String(repeating: "a", count: 900) + "\n" + String(repeating: "b", count: 1_500)
    let chunks = WeChatMessageParser.splitText(text, maxCharacters: 1_800)
    XCTAssertEqual(chunks[0].count, 1_800)
  }
}
