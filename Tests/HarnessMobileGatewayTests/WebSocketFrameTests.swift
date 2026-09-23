import Foundation
import XCTest

@testable import HarnessMobileGateway

/// The framing layer is the gateway's whole attack surface, so it is tested directly rather
/// than through a socket: every case here is something a peer on the LAN can send.
final class WebSocketFrameTests: XCTestCase {
  /// Build a client frame the way a browser does: masked, with the given opcode and FIN bit.
  private func maskedFrame(opcode: UInt8, payload: Data, fin: Bool = true, mask: [UInt8] = [1, 2, 3, 4]) -> Data {
    var frame = Data([(fin ? 0x80 : 0x00) | opcode])
    let count = payload.count
    if count <= 125 {
      frame.append(UInt8(0x80 | count))
    } else if count <= 0xFFFF {
      frame.append(0x80 | 0x7E)
      frame.append(UInt8((count >> 8) & 0xFF))
      frame.append(UInt8(count & 0xFF))
    } else {
      frame.append(0x80 | 127)
      let value = UInt64(count)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((value >> UInt64(shift)) & 0xFF))
      }
    }
    frame.append(contentsOf: mask)
    for (index, byte) in payload.enumerated() {
      frame.append(byte ^ mask[index & 3])
    }
    return frame
  }

  func testDecodesAMaskedTextFrame() throws {
    var decoder = WebSocketFrameDecoder()
    decoder.append(maskedFrame(opcode: 0x1, payload: Data("hello".utf8)))
    XCTAssertEqual(try decoder.next(), .text("hello"))
    XCTAssertNil(try decoder.next())
  }

  /// A truncated frame must yield nothing rather than a partial message: TCP splits frames
  /// wherever it likes, so "not yet" and "malformed" have to be different answers.
  func testWaitsForTheWholeFrame() throws {
    var decoder = WebSocketFrameDecoder()
    let frame = maskedFrame(opcode: 0x1, payload: Data("hello".utf8))
    decoder.append(frame.prefix(4))
    XCTAssertNil(try decoder.next())
    decoder.append(frame.suffix(from: 4))
    XCTAssertEqual(try decoder.next(), .text("hello"))
  }

  func testReassemblesFragmentedMessage() throws {
    var decoder = WebSocketFrameDecoder()
    decoder.append(maskedFrame(opcode: 0x1, payload: Data("he".utf8), fin: false))
    XCTAssertNil(try decoder.next())
    decoder.append(maskedFrame(opcode: 0x0, payload: Data("llo".utf8)))
    XCTAssertEqual(try decoder.next(), .text("hello"))
  }

  func testRejectsUnmaskedClientFrame() {
    var decoder = WebSocketFrameDecoder()
    // FIN + text, length 1, no mask bit, unmasked payload.
    decoder.append(Data([0x81, 0x01, 0x41]))
    XCTAssertThrowsError(try decoder.next())
  }

  func testRejectsReservedOpcode() {
    var decoder = WebSocketFrameDecoder()
    decoder.append(maskedFrame(opcode: 0x3, payload: Data()))
    XCTAssertThrowsError(try decoder.next()) { error in
      XCTAssertEqual(error as? WebSocketFrameError, .reservedOpcode(0x3))
    }
  }

  /// RFC 6455 requires the shortest length encoding, and a 16-bit length under 126 is a
  /// protocol error rather than a frame that happens to be short.
  func testRejectsNonMinimalLength() {
    var decoder = WebSocketFrameDecoder()
    // FIN + text, MASK + 16-bit length, length 5, mask 1.2.3.4, then five masked bytes.
    let masked: [UInt8] = [0x41 ^ 1, 0x42 ^ 2, 0x43 ^ 3, 0x44 ^ 4, 0x45 ^ 1]
    var frame = Data([0x81, 0xFE, 0x00, 0x05, 1, 2, 3, 4])
    frame.append(contentsOf: masked)
    decoder.append(frame)
    XCTAssertThrowsError(try decoder.next()) { error in
      XCTAssertEqual(error as? WebSocketFrameError, .nonMinimalLength)
    }
  }

  func testRejectsOversizedPayload() {
    var decoder = WebSocketFrameDecoder(maxPayload: 8)
    // A 130-byte payload: large enough that the 16-bit form is the minimal encoding, so the
    // failure under test is the size cap rather than the encoding rule.
    var frame = Data([0x81, 0xFE, 0x00, 0x82, 1, 2, 3, 4])
    frame.append(Data(repeating: 0, count: 130))
    decoder.append(frame)
    XCTAssertThrowsError(try decoder.next()) { error in
      XCTAssertEqual(error as? WebSocketFrameError, .payloadTooLarge(130))
    }
  }

  func testRejectsInvalidUTF8InTextFrame() {
    var decoder = WebSocketFrameDecoder()
    decoder.append(maskedFrame(opcode: 0x1, payload: Data([0xFF, 0xFE])))
    XCTAssertThrowsError(try decoder.next()) { error in
      XCTAssertEqual(error as? WebSocketFrameError, .invalidUTF8)
    }
  }

  func testRejectsFragmentedControlFrame() {
    var decoder = WebSocketFrameDecoder()
    decoder.append(maskedFrame(opcode: 0x9, payload: Data(), fin: false))
    XCTAssertThrowsError(try decoder.next()) { error in
      XCTAssertEqual(error as? WebSocketFrameError, .controlFrameFragmented)
    }
  }

  func testParsesCloseFrameWithCodeAndReason() throws {
    var decoder = WebSocketFrameDecoder()
    var payload = Data([0x0F, 0xA4]) // 4004
    payload.append(Data("mobile gateway disabled".utf8))
    decoder.append(maskedFrame(opcode: 0x8, payload: payload))
    XCTAssertEqual(try decoder.next(), .close(code: 4004, reason: "mobile gateway disabled"))
    XCTAssertEqual(decoder.closeCode, 4004)
    XCTAssertEqual(decoder.closeReason, "mobile gateway disabled")
  }

  /// 1005 and 1006 are "no status" sentinels and must never appear on the wire.
  func testRejectsReservedCloseCodes() {
    for code in [UInt16(1005), 1006, 1015] {
      var decoder = WebSocketFrameDecoder()
      decoder.append(maskedFrame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)])))
      XCTAssertThrowsError(try decoder.next())
    }
  }

  /// A server frame is never masked, and the length prefix has to agree with the payload so a
  /// strict client can parse it.
  func testEncodesUnmaskedTextFrame() {
    let data = WebSocketFrameEncoder.text("hi")
    XCTAssertEqual([UInt8](data), [0x81, 0x02, 0x68, 0x69])
    // No mask bit anywhere in the second byte.
    XCTAssertEqual(data[data.startIndex + 1] & 0x80, 0)
  }

  func testEncodesLongPayloadWith16BitLength() {
    let payload = String(repeating: "a", count: 300)
    let data = WebSocketFrameEncoder.text(payload)
    XCTAssertEqual(data[data.startIndex], 0x81)
    XCTAssertEqual(data[data.startIndex + 1], 126)
    XCTAssertEqual(data.count, 4 + 300)
  }

  /// The close reason is capped at 123 bytes by the control-frame limit, and truncating must
  /// not split a character and produce an invalid frame.
  func testTruncatesCloseReasonOnCharacterBoundary() {
    let reason = String(repeating: "汉", count: 100)
    let data = WebSocketFrameEncoder.close(code: 1000, reason: reason)
    let payloadLength = Int(data[data.startIndex + 1] & 0x7F)
    XCTAssertLessThanOrEqual(payloadLength, 125)
    let payload = data.subdata(in: (data.startIndex + 2)..<data.endIndex)
    XCTAssertNotNil(String(data: payload.dropFirst(2), encoding: .utf8))
  }
}
