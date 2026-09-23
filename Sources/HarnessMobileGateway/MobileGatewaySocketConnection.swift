import Foundation
import Network

/// The TCP/WebSocket listener behind the mobile gateway.
///
/// Network.framework is used for the raw byte transport, but its WebSocket protocol
/// implementation is **not** used: the upgrade has to be answered by this server
/// (401/403/503, subprotocol negotiation, `X-DSH-Device-ID`), and `NWProtocolWebSocket`
/// performs an opaque handshake that exposes none of it. So the connection is a plain
/// TCP stream, the handshake is parsed here, and frames are produced by
/// `WebSocketFrameDecoder`.
///
/// Every peer decision is delegated. This layer knows how to move bytes and nothing
/// about who is allowed to connect — which is why it can be tested with a fake
/// transport and no network at all.

/// What the acceptor decides about one upgrade request.
public enum MobileGatewayUpgradeDecision: Equatable, Sendable {
  /// Complete the upgrade, optionally agreeing a subprotocol.
  case accept(subprotocol: String?)
  /// Refuse with an HTTP status and a JSON error body.
  case reject(status: Int, code: String, message: String)
}

/// The seams a connection needs from the network, so tests can drive it directly.
public protocol MobileGatewayTransport: AnyObject, Sendable {
  func start()
  func send(_ data: Data)
  func cancel()
}

/// Receives the bytes that arrive on an accepted connection.
public protocol MobileGatewaySocketDelegate: AnyObject, Sendable {
  /// The header block arrived intact. The delegate authenticates here and decides.
  func socket(
    _ socket: MobileGatewaySocketConnection,
    decideUpgrade request: WebSocketHandshakeRequest,
    isLoopback: Bool
  ) -> MobileGatewayUpgradeDecision
  /// The 101 response has been written. Async work (the `paired` and `hello` frames) starts here,
  /// after the client can actually receive it.
  func socketDidUpgrade(_ socket: MobileGatewaySocketConnection)
  /// A complete frame arrived on an upgraded connection.
  func socket(_ socket: MobileGatewaySocketConnection, didReceive frame: WebSocketFrame)
  /// The connection ended, for any reason. Called exactly once per connection.
  func socketDidClose(_ socket: MobileGatewaySocketConnection, error: String?)
}

/// One accepted WebSocket connection: handshake, framing, and lifetime.
public final class MobileGatewaySocketConnection: @unchecked Sendable {
  /// Stable identity for logging and for the service's client table.
  public let id: UUID
  /// `true` when the peer reached us over the loopback interface.
  public let isLoopback: Bool
  public let remoteDescription: String

  private let transport: MobileGatewayTransport
  private weak var delegate: MobileGatewaySocketDelegate?
  private let queue: DispatchQueue
  private var decoder: WebSocketFrameDecoder
  private var handshakeBuffer = Data()
  private var upgraded = false
  private var closed = false
  private var closeCode: UInt16?
  private var closeReason: String?
  /// The credential the upgrade presented, kept for the duration of the connection so
  /// the service can attribute it without re-parsing the request.
  private var authenticatedDeviceID: String?
  private var authenticatedDeviceName: String?
  private var authenticated = false

  public init(
    id: UUID = UUID(),
    transport: MobileGatewayTransport,
    isLoopback: Bool,
    remoteDescription: String,
    delegate: MobileGatewaySocketDelegate,
    queue: DispatchQueue,
    maxPayload: Int = WebSocketFrameDecoder.defaultMaxPayload
  ) {
    self.id = id
    self.transport = transport
    self.isLoopback = isLoopback
    self.remoteDescription = remoteDescription
    self.delegate = delegate
    self.queue = queue
    self.decoder = WebSocketFrameDecoder(maxPayload: maxPayload)
  }

  /// The device this connection authenticated as, once the upgrade was accepted.
  public private(set) var deviceID: String?
  public private(set) var deviceName: String?
  /// Whether the connection presented a device credential. A debug connection over
  /// loopback with authentication switched off is authenticated == false.
  public private(set) var isAuthenticated = false
  /// Whether this connection is the phone's control channel rather than its
  /// conversation channel (the `?channel=control` split the iOS client uses).
  public private(set) var channel = "conversation"
  /// The agreed subprotocol, for logging.
  public private(set) var subprotocol: String?

  public func start() {
    transport.start()
  }

  /// Feed received bytes. Public so a test can replay a recorded exchange.
  public func receive(_ data: Data) {
    queue.async {
      guard !self.closed else { return }
      if self.upgraded {
        self.decoder.append(data)
        self.drainFrames()
      } else {
        self.handshakeBuffer.append(data)
        self.advanceHandshake()
      }
    }
  }

  /// Send a JSON text frame. Silently ignored after close: a broadcast that races a
  /// disconnect must not trap.
  public func send(text: String) {
    queue.async {
      guard !self.closed, self.upgraded else { return }
      self.transport.send(WebSocketFrameEncoder.text(text))
    }
  }

  /// Send a WebSocket protocol-level ping.
  ///
  /// This exists for the paths in front of the gateway, not for the gateway itself: Cloudflare
  /// closes an idle proxied WebSocket, and a home router drops an idle NAT mapping. The phone does
  /// not ping on its own while it sits idle in the foreground, so a connection that carries no
  /// traffic for long enough is torn down somewhere in the middle — and the cost is a reconnect, a
  /// fresh subscribe and a re-sent snapshot. A ping every interval is traffic in both directions
  /// (the peer's WebSocket stack answers the pong automatically), which is all those middleboxes
  /// need to keep the path open.
  public func sendPing() {
    queue.async {
      guard !self.closed, self.upgraded else { return }
      self.transport.send(WebSocketFrameEncoder.ping())
    }
  }

  /// Begin the closing handshake and then drop the socket. The close frame is sent
  /// before the TCP teardown so the peer learns *why* (4003 re-authenticated, 4004
  /// gateway closed) instead of seeing a bare reset.
  public func close(code: UInt16, reason: String) {
    queue.async {
      guard !self.closed else { return }
      self.closeCode = code
      self.closeReason = reason
      if self.upgraded {
        self.transport.send(WebSocketFrameEncoder.close(code: code, reason: reason))
      }
      self.finish(error: nil)
    }
  }

  private func advanceHandshake() {
    switch WebSocketHandshake.parse(handshakeBuffer) {
    case .incomplete:
      return
    case .malformed(let reason):
      transport.send(WebSocketHandshake.refusalResponse(status: 400, code: "bad-request", message: reason))
      finish(error: reason)
    case .request(let request, let headerLength):
      // Any bytes past the header block are already WebSocket frames; keep them.
      let remainder = handshakeBuffer.count > headerLength
        ? handshakeBuffer.subdata(in: (handshakeBuffer.startIndex + headerLength)..<handshakeBuffer.endIndex)
        : Data()
      handshakeBuffer = Data()
      guard let delegate else {
        finish(error: "no delegate")
        return
      }
      let decision = delegate.socket(self, decideUpgrade: request, isLoopback: isLoopback)
      switch decision {
      case .reject(let status, let code, let message):
        transport.send(WebSocketHandshake.refusalResponse(status: status, code: code, message: message))
        finish(error: "\(status) \(code)")
      case .accept(let agreed):
        guard let key = request.headers["sec-websocket-key"], !key.isEmpty else {
          transport.send(WebSocketHandshake.refusalResponse(status: 400, code: "bad-request", message: "missing Sec-WebSocket-Key"))
          finish(error: "missing key")
          return
        }
        subprotocol = agreed
        channel = request.query["channel"] == "control" ? "control" : "conversation"
        upgraded = true
        transport.send(WebSocketHandshake.upgradeResponse(accept: WebSocketHandshake.accept(for: key), subprotocol: agreed))
        // The client can receive from here; anything the delegate wants to say first is said now.
        delegate.socketDidUpgrade(self)
        if !remainder.isEmpty {
          decoder.append(remainder)
          drainFrames()
        }
      }
    }
  }

  private func drainFrames() {
    while !closed {
      let frame: WebSocketFrame?
      do {
        frame = try decoder.next()
      } catch {
        // Every framing error is a protocol error: the peer's stream can no longer be
        // resynchronised, so the connection ends rather than skipping bytes.
        let described = String(describing: error)
        let framing = error as? WebSocketFrameError
        transport.send(WebSocketFrameEncoder.close(
          code: framing?.closeCode ?? WebSocketFrameEncoder.closeProtocolError,
          reason: framing?.closeReason ?? "protocol error"
        ))
        finish(error: described)
        return
      }
      guard let frame else { return }
      handle(frame)
    }
  }

  private func handle(_ frame: WebSocketFrame) {
    switch frame {
    case .ping(let payload):
      // Answer immediately: this is the keepalive that lets a phone notice a dropped
      // Wi-Fi association without waiting for a TCP timeout.
      transport.send(WebSocketFrameEncoder.pong(payload))
    case .pong:
      break
    case .close(let code, let reason):
      if upgraded { transport.send(WebSocketFrameEncoder.close(code: code ?? 1000, reason: reason)) }
      finish(error: nil)
    case .text, .binary:
      delegate?.socket(self, didReceive: frame)
    }
  }

  /// Mark the connection as authenticated. Called by the delegate between the upgrade
  /// decision and the first business frame.
  public func markAuthenticated(deviceID: String?, deviceName: String?) {
    queue.async {
      self.authenticatedDeviceID = deviceID
      self.authenticatedDeviceName = deviceName
      self.isAuthenticated = deviceID != nil
      self.deviceID = deviceID
      self.deviceName = deviceName
    }
  }

  /// The credential the upgrade presented, if any — read by the delegate during
  /// `decideUpgrade`, before `markAuthenticated` runs.
  public func presentedCredential(from request: WebSocketHandshakeRequest) -> (token: String?, pairingCode: String?) {
    (request.bearerToken ?? request.authSubprotocol ?? request.query["token"],
     request.pairingSubprotocol ?? request.query["pairingCode"])
  }

  private func finish(error: String?) {
    guard !closed else { return }
    closed = true
    transport.cancel()
    delegate?.socketDidClose(self, error: error)
  }
}

extension WebSocketFrameError {
  /// The close code RFC 6455 pair for each framing failure.
  var closeCode: UInt16 {
    switch self {
    case .payloadTooLarge: return WebSocketFrameEncoder.closeTooLarge
    case .invalidUTF8: return WebSocketFrameEncoder.closeInvalidPayload
    case .invalidCloseCode: return WebSocketFrameEncoder.closeProtocolError
    default: return WebSocketFrameEncoder.closeProtocolError
    }
  }

  var closeReason: String {
    switch self {
    case .payloadTooLarge(let size): return "payload too large (\(size) bytes)"
    case .invalidUTF8: return "invalid utf-8"
    case .invalidCloseCode(let code): return "invalid close code \(code)"
    case .reservedOpcode(let opcode): return "reserved opcode \(opcode)"
    case .controlFrameFragmented: return "fragmented control frame"
    case .controlFrameTooLarge(let size): return "control frame too large (\(size) bytes)"
    case .nonMinimalLength: return "non-minimal length encoding"
    case .unexpectedContinuation: return "unexpected continuation frame"
    case .newMessageDuringFragmentation: return "new message during fragmentation"
    case .protocolViolation(let what): return what
    }
  }
}
