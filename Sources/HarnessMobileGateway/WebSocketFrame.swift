import Foundation

/// RFC 6455 framing for the mobile gateway's own listener.
///
/// The gateway cannot use `NWProtocolWebSocket`: the protocol requires reading the
/// upgrade request itself (the `Authorization` header, `X-DSH-Device-ID`, and the
/// `dsh-pair.<code>` / `dsh-auth.<token>` subprotocols) and answering a rejected
/// upgrade with 401/403/503 — decisions the framework's opaque handshake does not
/// expose. So the TCP connection is plain bytes and the framing lives here.
///
/// This type is deliberately a pure state machine over bytes: every peer on a LAN
/// can hand us arbitrary input, including frames that are truncated mid-header, and
/// a pure decoder is the only version of that logic a unit test can drive off the
/// network.

/// The opcodes this server understands. Reserved control opcodes (0x3-0x7, 0xB-0xF)
/// are rejected rather than ignored: silently dropping them would leave the peer
/// waiting for a reply that can never come.
public enum WebSocketOpcode: UInt8, Sendable {
  case continuation = 0x0
  case text = 0x1
  case binary = 0x2
  case close = 0x8
  case ping = 0x9
  case pong = 0xA

  var isControl: Bool { rawValue >= 0x8 }
}

/// A complete, de-fragmented message or control frame.
public enum WebSocketFrame: Equatable, Sendable {
  case text(String)
  case binary(Data)
  case ping(Data)
  case pong(Data)
  case close(code: UInt16?, reason: String)
}

/// Every way a peer can send something that is not a valid frame.
///
/// The distinctions matter to the caller: a protocol violation is a 1002 close,
/// an oversized payload is a 1009 close, and invalid UTF-8 in a text frame is a
/// 1007 close. Collapsing them into one error would make the server lie about why
/// it hung up.
public enum WebSocketFrameError: Error, Equatable {
  case reservedOpcode(UInt8)
  case controlFrameFragmented
  case controlFrameTooLarge(Int)
  case nonMinimalLength
  case payloadTooLarge(Int)
  case unexpectedContinuation
  case newMessageDuringFragmentation
  case invalidUTF8
  case invalidCloseCode(UInt16)
  case protocolViolation(String)
}

/// Incremental decoder: feed it bytes, pull frames out.
public struct WebSocketFrameDecoder {
  /// Largest single frame payload accepted. The wire's biggest legitimate frame is a
  /// base64 image batch; 100 MiB (the `ws` default the iOS client was written against)
  /// is far more than any phone sends and would let one peer exhaust memory, so the
  /// bound is lower but still comfortably above a 20-image message.
  public static let defaultMaxPayload = 32 * 1024 * 1024

  private var buffer = Data()
  private let maxPayload: Int
  /// Set while a fragmented message is being reassembled.
  private var fragmentOpcode: WebSocketOpcode?
  private var fragmentPayload = Data()
  /// Close frames carry the peer's reason; a decoder that threw here would lose it.
  private var peerCloseCode: UInt16?
  private var peerCloseReason = ""

  public init(maxPayload: Int = WebSocketFrameDecoder.defaultMaxPayload) {
    self.maxPayload = maxPayload
  }

  /// The close frame's code, once one has been decoded.
  public var closeCode: UInt16? { peerCloseCode }
  public var closeReason: String { peerCloseReason }

  public mutating func append(_ data: Data) {
    buffer.append(data)
  }

  /// Number of bytes buffered but not yet forming a complete frame.
  public var bufferedByteCount: Int { buffer.count }

  /// Decode the next complete frame, or `nil` when more bytes are needed.
  public mutating func next() throws -> WebSocketFrame? {
    // A frame needs at least two bytes before the length is even known.
    guard buffer.count >= 2 else { return nil }

    let first = buffer[buffer.startIndex]
    let second = buffer[buffer.startIndex + 1]
    let fin = (first & 0x80) != 0
    let rsv = first & 0x70
    // Extensions were never negotiated, so any RSV bit set is a protocol violation.
    guard rsv == 0 else { throw WebSocketFrameError.protocolViolation("reserved bits set") }
    guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
      throw WebSocketFrameError.reservedOpcode(first & 0x0F)
    }
    let masked = (second & 0x80) != 0
    // RFC 6455 §5.1: a client must mask. An unmasked frame is either a broken client
    // or an attacker probing cache assumptions, so both are refused.
    guard masked else { throw WebSocketFrameError.protocolViolation("client frame is not masked") }

    var length = Int(second & 0x7F)
    var offset = 2
    if length == 126 {
      guard buffer.count >= offset + 2 else { return nil }
      let raw = buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + 2))
      length = Int(raw[raw.startIndex]) << 8 | Int(raw[raw.startIndex + 1])
      offset += 2
      // The shortest encoding is mandatory: a 16-bit length under 126 is malformed.
      guard length >= 126 else { throw WebSocketFrameError.nonMinimalLength }
    } else if length == 127 {
      guard buffer.count >= offset + 8 else { return nil }
      var value: UInt64 = 0
      for index in 0..<8 {
        value = value << 8 | UInt64(buffer[buffer.startIndex + offset + index])
      }
      offset += 8
      guard value > 0xFFFF else { throw WebSocketFrameError.nonMinimalLength }
      guard value <= UInt64(Int.max) else { throw WebSocketFrameError.payloadTooLarge(Int.max) }
      length = Int(value)
    }

    if opcode.isControl {
      // Control frames can never be fragmented or exceed 125 bytes of payload.
      guard fin else { throw WebSocketFrameError.controlFrameFragmented }
      guard length <= 125 else { throw WebSocketFrameError.controlFrameTooLarge(length) }
    } else {
      guard length <= maxPayload else { throw WebSocketFrameError.payloadTooLarge(length) }
    }

    guard buffer.count >= offset + 4 + length else { return nil }
    let maskStart = buffer.startIndex + offset
    let mask = buffer.subdata(in: maskStart..<(maskStart + 4))
    let payloadStart = maskStart + 4
    var payload = buffer.subdata(in: payloadStart..<(payloadStart + length))
    buffer.removeSubrange(buffer.startIndex..<(payloadStart + length))

    // Unmask in place; XOR is its own inverse.
    let maskBytes = [UInt8](mask)
    payload.withUnsafeMutableBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      for index in 0..<raw.count { base[index] ^= maskBytes[index & 3] }
    }

    switch opcode {
    case .ping: return .ping(payload)
    case .pong: return .pong(payload)
    case .close:
      let parsed = try Self.parseClose(payload)
      peerCloseCode = parsed.code
      peerCloseReason = parsed.reason
      return .close(code: parsed.code, reason: parsed.reason)

    case .text, .binary:
      guard fragmentOpcode == nil else { throw WebSocketFrameError.newMessageDuringFragmentation }
      guard !fin else { return try Self.completeMessage(opcode: opcode, payload: payload) }
      fragmentOpcode = opcode
      fragmentPayload = payload
      return nil

    case .continuation:
      guard let started = fragmentOpcode else { throw WebSocketFrameError.unexpectedContinuation }
      // A reassembled message is still one frame's worth of memory, so the bound
      // applies to the total, not only to each fragment.
      guard fragmentPayload.count + payload.count <= maxPayload else {
        throw WebSocketFrameError.payloadTooLarge(fragmentPayload.count + payload.count)
      }
      fragmentPayload.append(payload)
      guard fin else { return nil }
      let assembled = fragmentPayload
      fragmentOpcode = nil
      fragmentPayload = Data()
      return try Self.completeMessage(opcode: started, payload: assembled)
    }
  }

  private static func completeMessage(opcode: WebSocketOpcode, payload: Data) throws -> WebSocketFrame {
    switch opcode {
    case .text:
      // The wire is defined as UTF-8; a decoder that substituted replacement
      // characters would hand the router a frame the peer never sent.
      guard let text = String(data: payload, encoding: .utf8) else { throw WebSocketFrameError.invalidUTF8 }
      return .text(text)
    case .binary: return .binary(payload)
    default: throw WebSocketFrameError.protocolViolation("continuation of a non-message frame")
    }
  }

  private static func parseClose(_ payload: Data) throws -> (code: UInt16?, reason: String) {
    guard payload.count > 0 else { return (nil, "") }
    guard payload.count >= 2 else { throw WebSocketFrameError.protocolViolation("1-byte close payload") }
    let start = payload.startIndex
    let code = UInt16(payload[start]) << 8 | UInt16(payload[start + 1])
    // 1005/1006/1015 are reserved for local use and must never appear on the wire.
    let validRange = (code >= 1000 && code <= 4999)
      && code != 1005 && code != 1006 && code != 1015
    guard validRange else { throw WebSocketFrameError.invalidCloseCode(code) }
    guard let reason = String(data: payload.subdata(in: (start + 2)..<payload.endIndex), encoding: .utf8) else {
      throw WebSocketFrameError.invalidUTF8
    }
    return (code, reason)
  }
}

/// Server-to-client framing. Server frames are never masked (RFC 6455 §5.1).
public enum WebSocketFrameEncoder {
  public static let closeGoingAway: UInt16 = 1001
  public static let closeProtocolError: UInt16 = 1002
  public static let closeUnsupportedData: UInt16 = 1003
  public static let closeInvalidPayload: UInt16 = 1007
  public static let closePolicyViolation: UInt16 = 1008
  public static let closeTooLarge: UInt16 = 1009
  public static let closeInternalError: UInt16 = 1011

  public static func text(_ string: String) -> Data {
    encode(opcode: .text, payload: Data(string.utf8))
  }

  public static func binary(_ data: Data) -> Data {
    encode(opcode: .binary, payload: data)
  }

  public static func ping(_ payload: Data = Data()) -> Data {
    encode(opcode: .ping, payload: payload)
  }

  public static func pong(_ payload: Data = Data()) -> Data {
    encode(opcode: .pong, payload: payload)
  }

  /// A close frame. RFC 6455 caps a control frame's payload at 125 bytes, so the
  /// reason is truncated rather than allowed to produce an illegal frame — and it is
  /// truncated on a character boundary so the bytes stay valid UTF-8.
  public static func close(code: UInt16, reason: String = "") -> Data {
    var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
    var reasonData = Data(reason.utf8)
    if reasonData.count > 123 {
      reasonData = Data(String(decoding: reasonData.prefix(123), as: UTF8.self).utf8)
      while reasonData.count > 123 { reasonData.removeLast() }
    }
    payload.append(reasonData)
    return encode(opcode: .close, payload: payload)
  }

  /// An empty TCP-level close: the peer sent a bare close frame, so we answer with a
  /// bare one rather than inventing a status code the peer did not send.
  public static func emptyClose() -> Data {
    encode(opcode: .close, payload: Data())
  }

  private static func encode(opcode: WebSocketOpcode, payload: Data) -> Data {
    var frame = Data([0x80 | opcode.rawValue])
    let count = payload.count
    if count <= 125 {
      frame.append(UInt8(count))
    } else if count <= 0xFFFF {
      frame.append(126)
      frame.append(UInt8((count >> 8) & 0xFF))
      frame.append(UInt8(count & 0xFF))
    } else {
      frame.append(127)
      let value = UInt64(count)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((value >> UInt64(shift)) & 0xFF))
      }
    }
    frame.append(payload)
    return frame
  }
}
