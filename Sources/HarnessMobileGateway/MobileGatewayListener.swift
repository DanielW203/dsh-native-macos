import Foundation
import Network

/// The TCP listener that accepts phone connections.
///
/// One listener serves everything: a phone on the same Wi-Fi, the loopback client the
/// Mac itself runs, and (through a TLS reverse proxy) a phone on the public internet.
/// The port is fixed rather than ephemeral because the pairing payload the phone scans
/// has to name an address that is still valid after a restart.
public final class MobileGatewayListener: @unchecked Sendable {
  public struct Status: Equatable, Sendable {
    public var isListening: Bool
    public var port: UInt16?
    public var host: String
    public var error: String?
  }

  public enum BindError: Error, Equatable {
    case invalidPort(UInt16)
    case failed(String)
  }

  /// Notified whenever the listener's state changes, so the window can show
  /// "listening on 0.0.0.0:3081" or the exact reason it is not.
  public var onStatusChange: (@Sendable (Status) -> Void)?

  private let queue = DispatchQueue(label: "ai.deepseek.nativeharness.mobile-gateway.listener")
  private let connectionsQueue = DispatchQueue(label: "ai.deepseek.nativeharness.mobile-gateway.socket", attributes: .concurrent)
  private var listener: NWListener?
  private let requestedPort: UInt16
  private let host: String?
  private weak var delegate: MobileGatewaySocketDelegate?
  private var status: Status
  private var liveConnections: [UUID: MobileGatewaySocketConnection] = [:]
  private let lock = NSLock()

  public init(port: UInt16, host: String? = nil, delegate: MobileGatewaySocketDelegate) {
    self.requestedPort = port
    self.host = host
    self.delegate = delegate
    self.status = Status(isListening: false, port: nil, host: host ?? "0.0.0.0", error: nil)
  }

  public var currentStatus: Status {
    lock.lock(); defer { lock.unlock() }
    return status
  }

  /// Number of sockets currently attached, including ones still completing a handshake.
  public var connectionCount: Int {
    lock.lock(); defer { lock.unlock() }
    return liveConnections.count
  }

  /// Bind and start accepting. Throws synchronously for an unusable port so the caller
  /// can report it without waiting for an async callback.
  public func start() throws {
    guard requestedPort > 0 else { throw BindError.invalidPort(requestedPort) }
    guard listener == nil else { return }

    let parameters = NWParameters.tcp
    // A restart must rebind immediately; without this, a gateway toggled off and on
    // fails with "address already in use" for as long as the old socket lingers in
    // TIME_WAIT.
    parameters.allowLocalEndpointReuse = true
    parameters.acceptLocalOnly = false
    if let host {
      parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: requestedPort)!)
    }

    let listener: NWListener
    do {
      listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: requestedPort)!)
    } catch {
      throw BindError.failed(error.localizedDescription)
    }
    self.listener = listener

    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        let bound = listener.port?.rawValue ?? self.requestedPort
        self.update(status: Status(isListening: true, port: bound, host: self.host ?? "0.0.0.0", error: nil))
      case .failed(let error):
        self.update(status: Status(isListening: false, port: nil, host: self.host ?? "0.0.0.0", error: error.localizedDescription))
        self.tearDown()
      case .cancelled:
        self.update(status: Status(isListening: false, port: nil, host: self.host ?? "0.0.0.0", error: self.currentStatus.error))
      default:
        break
      }
    }

    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }

    listener.start(queue: queue)
  }

  /// Stop accepting and drop every live socket.
  public func stop() {
    tearDown()
    update(status: Status(isListening: false, port: nil, host: host ?? "0.0.0.0", error: nil))
  }

  private func tearDown() {
    listener?.stateUpdateHandler = nil
    listener?.newConnectionHandler = nil
    listener?.cancel()
    listener = nil
    lock.lock()
    let connections = liveConnections
    liveConnections.removeAll()
    lock.unlock()
    for (_, connection) in connections {
      connection.close(code: 1001, reason: "gateway stopping")
    }
  }

  private func accept(_ connection: NWConnection) {
    guard let delegate else {
      connection.cancel()
      return
    }
    let transport = NetworkTransport(connection: connection, queue: queue)
    let remote = Self.description(of: connection.endpoint)
    let socket = MobileGatewaySocketConnection(
      transport: transport,
      isLoopback: Self.isLoopback(connection.endpoint),
      remoteDescription: remote,
      delegate: delegate,
      queue: connectionsQueue
    )
    // The transport must forward inbound bytes and notice teardown; wiring it after
    // construction keeps the connection object free of Network types.
    transport.onReceive = { [weak socket] data in socket?.receive(data) }
    transport.onClosed = { [weak self, weak socket] error in
      guard let socket else { return }
      self?.forget(socket, error: error)
    }
    lock.lock()
    liveConnections[socket.id] = socket
    lock.unlock()
    socket.start()
  }

  private func forget(_ socket: MobileGatewaySocketConnection, error: String?) {
    lock.lock()
    liveConnections.removeValue(forKey: socket.id)
    lock.unlock()
  }

  private func update(status: Status) {
    lock.lock()
    let changed = self.status != status
    self.status = status
    lock.unlock()
    if changed { onStatusChange?(status) }
  }

  // MARK: - Endpoint inspection

  static func description(of endpoint: NWEndpoint) -> String {
    switch endpoint {
    case .hostPort(let host, let port):
      return "\(host):\(port)"
    default:
      return String(describing: endpoint)
    }
  }

  /// Whether a peer address is the loopback interface.
  ///
  /// This decides whether the "device authentication off" debug path is available at
  /// all: a LAN peer must never be treated as local, so the check is on the actual
  /// address, not on a header the peer could set.
  static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    switch host {
    case .ipv4(let address):
      return address.isLoopback
    case .ipv6(let address):
      return address.isLoopback
    case .name(let name, _):
      return name == "localhost"
    @unknown default:
      return false
    }
  }
}

/// Bridges one `NWConnection` to the transport protocol.
final class NetworkTransport: MobileGatewayTransport, @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private var started = false
  private var cancelled = false
  var onReceive: (@Sendable (Data) -> Void)?
  var onClosed: (@Sendable (String?) -> Void)?

  init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  func start() {
    guard !started else { return }
    started = true
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .failed(let error):
        self.finish(error.localizedDescription)
      case .cancelled:
        self.finish(nil)
      default:
        break
      }
    }
    connection.start(queue: queue)
    read()
  }

  private func read() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty { self.onReceive?(data) }
      if let error {
        self.finish(error.localizedDescription)
        return
      }
      if isComplete {
        self.finish(nil)
        return
      }
      self.read()
    }
  }

  func send(_ data: Data) {
    connection.send(content: data, completion: .contentProcessed { _ in })
  }

  func cancel() {
    finish(nil)
  }

  private func finish(_ error: String?) {
    guard !cancelled else { return }
    cancelled = true
    connection.stateUpdateHandler = nil
    connection.cancel()
    onClosed?(error)
  }
}
