import Foundation
import HarnessKit

/// The native mobile gateway: a `dsh-mobile-v1` WebSocket server for paired phones.
///
/// This is the Swift counterpart of the `dsh-plugin-mobile-gateway` host plugin. It owns the
/// listener, the paired-device registry, the run-mode state machine and the connection
/// bookkeeping, and it drives a *running* harness through `MobileGatewayHostAdapter`.
///
/// Concurrency model: connection callbacks arrive on socket queues, so all shared state is
/// guarded by one lock held only for the length of a table update — never across an `await`.
/// Anything that talks to the harness runs in a `Task` and re-enters through the lock.
public final class MobileGatewayService: MobileGatewaySocketDelegate, @unchecked Sendable {
  /// Which logical channel a connection is. The iOS client opens two: a conversation channel
  /// for one session's transcript, and a control channel for the cross-session state.
  public enum Channel: String, Sendable {
    case conversation
    case control
    case legacy
  }

  /// The protocol's endpoint path. Anything else on this listener is a 404.
  public static let webSocketPath = "/ws/mobile"

  /// Everything the management window renders.
  public struct Status: Sendable, Equatable {
    public var mode: MobileGatewayMode
    public var isListening: Bool
    public var port: UInt16?
    public var listenHost: String
    public var listenError: String?
    public var clients: Int
    public var gatewayID: String
    public var gatewayName: String
    public var requireAuth: Bool
    public var waitExpiresAt: Double?
    public var lanURLs: [String]
    public var endpoints: [String]
    public var devices: [MobileGatewayDeviceRegistry.DeviceSummary]
    public var dshVersion: String
    public var lastError: String?
    /// The Tailscale reading, and the endpoints it contributes.
    public var tailscale: MobileGatewayTailscaleStatus
    public var tailscaleEndpoints: [String]

    public init(
      mode: MobileGatewayMode,
      isListening: Bool = false,
      port: UInt16? = nil,
      listenHost: String = "0.0.0.0",
      listenError: String? = nil,
      clients: Int = 0,
      gatewayID: String = "",
      gatewayName: String = "",
      requireAuth: Bool = true,
      waitExpiresAt: Double? = nil,
      lanURLs: [String] = [],
      endpoints: [String] = [],
      devices: [MobileGatewayDeviceRegistry.DeviceSummary] = [],
      dshVersion: String = MobileGatewayConfiguration.dshVersion,
      lastError: String? = nil,
      tailscale: MobileGatewayTailscaleStatus = MobileGatewayTailscaleStatus(),
      tailscaleEndpoints: [String] = []
    ) {
      self.mode = mode
      self.isListening = isListening
      self.port = port
      self.listenHost = listenHost
      self.listenError = listenError
      self.clients = clients
      self.gatewayID = gatewayID
      self.gatewayName = gatewayName
      self.requireAuth = requireAuth
      self.waitExpiresAt = waitExpiresAt
      self.lanURLs = lanURLs
      self.endpoints = endpoints
      self.devices = devices
      self.dshVersion = dshVersion
      self.lastError = lastError
      self.tailscale = tailscale
      self.tailscaleEndpoints = tailscaleEndpoints
    }
  }

  /// A pairing offer: the payload a QR encodes, and the same text for manual entry.
  public struct PairingOffer: Sendable, Equatable {
    public var id: String
    public var name: String
    public var expiresAt: Double
    /// Base64URL (unpadded) of the JSON payload — the only format the client accepts.
    public var qrText: String
    /// The decoded payload, for display and for the `endpoints` merge.
    public var payload: JSONValue
  }

  public enum ServiceError: Error, Equatable {
    case invalidMode(String)
    case notStarted
    case state(String)
  }

  public var onStatusChange: (@Sendable (Status) -> Void)?

  private let configuration: MobileGatewayConfiguration
  private let rpc: MobileGatewayRPC
  private let identity: MobileGatewayIdentity
  private let registry: MobileGatewayDeviceRegistry
  private let adapter: MobileGatewayHostAdapter
  /// One instance for the process, not one per message: an open download is state that the
  /// `file-download-read` chunks must find again, and a fresh manager would report every
  /// transfer as unknown.
  private let fileTransfer: MobileGatewayFileTransfer
  /// The configured public addresses, already normalized and vetted at init: an endpoint that
  /// would put a device token on the open internet must fail the launch, not be discovered later
  /// by looking at a QR code.
  private var configuredEndpoints: [String]
  /// The last Tailscale reading, refreshed on demand. Cached rather than queried per frame: the
  /// status call spawns a process, and the pairing payload is built from it.
  private var tailscaleStatus = MobileGatewayTailscaleStatus()
  /// Set when the user changes the setting at runtime; `nil` means "use the configuration".
  private var tailscaleEnabledOverride: Bool?
  /// Injectable so the discovery path is exercised without a Tailscale install on the test machine.
  private let tailscaleDiscovery: MobileGatewayTailscaleDiscovery

  private let lock = NSLock()
  private var listener: MobileGatewayListener?
  private var clients: [UUID: ClientRecord] = [:]
  private var pendingUpgrades: [UUID: PendingUpgrade] = [:]
  private var mode: MobileGatewayMode = .disabled
  private var waitExpiresAt: Double?
  private var waitTask: Task<Void, Never>?
  private var connectedSinceEnabled = false
  private var lastError: String?
  private var started = false

  /// Human-in-the-loop requests the host is still holding open, keyed by the host's own
  /// correlation id (which is what `answer(eventID:)` needs).
  private var pendingQuestions: [String: PendingQuestion] = [:]
  private var pendingApprovals: [String: PendingApproval] = [:]
  private var eventPump: Task<Void, Never>?
  /// Sends a protocol-level ping to every connected phone on an interval, so an idle connection is
  /// not silently reaped by a proxy or a NAT table.
  private var keepAliveTask: Task<Void, Never>?

  // MARK: - Records

  private final class ClientRecord {
    let socket: MobileGatewaySocketConnection
    var channel: Channel
    var deviceID: String?
    var deviceName: String?
    var authenticated = false
    var filterSessionID: String?
    var assistantStream = false
    var subscriptionID: String?
    var sessionPump: MobileGatewaySessionPump?
    var controlPump: MobileGatewayControlPump?

    init(socket: MobileGatewaySocketConnection, channel: Channel) {
      self.socket = socket
      self.channel = channel
    }
  }

  private struct PendingUpgrade {
    var deviceID: String?
    var deviceName: String?
    var paired: MobileGatewayDeviceRegistry.PairedDevice?
    var channel: Channel
    var authenticated: Bool
  }

  private struct PendingQuestion {
    var rpcId: String
    var sessionID: String
    var questions: JSONValue
    var claimedBy: UUID?
  }

  private struct PendingApproval {
    var rpcId: String
    var sessionID: String
    var approvalID: String
    var toolName: String
    var claimedBy: UUID?
  }

  // MARK: - Lifecycle

  public init(
    configuration: MobileGatewayConfiguration,
    rpc: MobileGatewayRPC,
    tailscaleDiscovery: MobileGatewayTailscaleDiscovery? = nil
  ) throws {
    self.configuration = configuration
    self.rpc = rpc
    self.identity = try MobileGatewayIdentity(file: configuration.stateFile)
    self.registry = try MobileGatewayDeviceRegistry(
      file: configuration.deviceFile,
      pairingTTL: configuration.pairingTTL
    )
    self.adapter = MobileGatewayHostAdapter(rpc: rpc)
    self.fileTransfer = MobileGatewayFileTransfer(adapter: adapter, configuration: configuration)
    self.configuredEndpoints = try MobileGatewayConfiguration.normalizeEndpoints(configuration.endpoints)
    self.tailscaleDiscovery = tailscaleDiscovery
      ?? MobileGatewayTailscaleDiscovery(overridePath: configuration.tailscaleBinary)
    // Resolved here rather than in `start()`: the mode is a property of the service, not of the
    // listener, and a management window (or a test) that asks before the listener is bound must
    // get the real mode instead of a placeholder `disabled`.
    self.mode = identity.mode ?? configuration.configuredStartupMode
  }

  /// Resolve the startup mode and bind the listener.
  ///
  /// The listener is bound whenever the LAN listener is enabled, even in `disabled` mode: a
  /// phone that connects to a closed gateway must receive a clean HTTP 503 that tells it to
  /// stop retrying, not a connection refusal it cannot distinguish from a network problem.
  public func start() {
    lock.lock()
    if started { lock.unlock(); return }
    started = true
    let resolved = mode
    lock.unlock()

    // `persist: false` — a restart never rewrites the file, so a temporary gateway gets a fresh
    // first-connection window each launch instead of inheriting a stale deadline.
    apply(mode: resolved, persist: false)
    // Bound even while the gateway is `disabled`: a phone that connects to a closed gateway
    // must get an HTTP 503 that tells it to stop retrying, not a connection refusal it cannot
    // tell apart from bad Wi-Fi. Only the user's own "no LAN listener" choice skips the bind.
    if configuration.lanEnabled { _ = try? ensureListener() }
    startEventPump()
    startKeepAlive()
    publishStatus()
  }

  public func stop() {
    lock.lock()
    guard started else { lock.unlock(); return }
    started = false
    waitTask?.cancel()
    waitTask = nil
    eventPump?.cancel()
    eventPump = nil
    keepAliveTask?.cancel()
    keepAliveTask = nil
    let records = clients
    clients.removeAll()
    let listener = self.listener
    self.listener = nil
    lock.unlock()
    for (_, record) in records {
      record.sessionPump?.stop()
      record.controlPump?.stop()
      record.socket.close(code: 1001, reason: "gateway stopping")
    }
    listener?.stop()
    publishStatus()
  }

  /// The mode the gateway is actually in.
  public var currentMode: MobileGatewayMode {
    lock.lock(); defer { lock.unlock() }
    return mode
  }

  /// Change the run mode. The saved choice outranks the launch configuration from then on, so
  /// the write happens *before* the live change: a failed save must never report success.
  public func setMode(_ newMode: MobileGatewayMode) throws {
    try identity.setMode(newMode)
    apply(mode: newMode, persist: false)
    publishStatus()
  }

  /// Turn device authentication on or off.
  ///
  /// Turning it *on* disconnects every unauthenticated connection with close code 4003, which is
  /// the only way a debug connection learns that the rule changed underneath it.
  public func setRequireAuth(_ enabled: Bool) throws {
    lock.lock()
    requireAuthValue = enabled
    let toClose = enabled ? clients.values.filter { $0.deviceID == nil } : []
    lock.unlock()
    for record in toClose {
      record.socket.close(code: 4003, reason: "authentication enabled")
    }
    publishStatus()
  }

  /// Device authentication as currently configured.
  public var requireAuth: Bool {
    lock.lock(); defer { lock.unlock() }
    return requireAuthValue
  }

  private var requireAuthValue: Bool {
    get { _requireAuthValue ?? configuration.requireAuth }
    set { _requireAuthValue = newValue }
  }
  private var _requireAuthValue: Bool?

  // MARK: - Management API (the native window)

  public func status() -> Status {
    lock.lock()
    let records = clients
    let currentMode = mode
    let wait = waitExpiresAt
    let error = lastError
    let auth = _requireAuthValue ?? configuration.requireAuth
    let listenerStatus = listener?.currentStatus
    let tailscaleReading = tailscaleStatus
    lock.unlock()

    return Status(
      mode: currentMode,
      isListening: listenerStatus?.isListening ?? false,
      port: listenerStatus?.port ?? (configuration.lanEnabled ? configuration.lanPort : nil),
      listenHost: listenerStatus?.host ?? configuration.lanHost,
      listenError: listenerStatus?.error,
      clients: records.count,
      gatewayID: identity.gatewayID,
      gatewayName: configuration.effectiveGatewayName,
      requireAuth: auth,
      waitExpiresAt: wait,
      lanURLs: lanWebSocketURLs(port: listenerStatus?.port ?? configuration.lanPort),
      endpoints: advertisedEndpoints(includeLAN: true),
      devices: registry.list(),
      dshVersion: adapter.hostVersion ?? MobileGatewayConfiguration.dshVersion,
      lastError: error,
      tailscale: tailscaleReading,
      tailscaleEndpoints: tailscaleURLs()
    )
  }

  /// Mint a one-time pairing code and the payload a QR encodes.
  public func createPairing(name: String?) throws -> PairingOffer {
    guard currentMode != .disabled else {
      throw ServiceError.state("enable the mobile gateway before creating a pairing code")
    }
    // A code is only worth issuing if it carries an address the phone can actually dial. The
    // plugin derives the payload's primary address from the *request's* Host header when no public
    // URL is configured — and the harness Web UI is reached over loopback, so a QR minted from it
    // can name `127.0.0.1`, which the phone resolves to itself and reports as "cannot connect to
    // host". Rather than reproduce that trap, this implementation refuses to hand out a code that
    // has nowhere to point.
    let reachable = advertisedEndpoints(includeLAN: true)
    guard let primary = reachable.first else {
      throw ServiceError.state("没有手机可到达的地址：请确认已开启局域网监听，或为该网关配置 endpoints")
    }
    let grant = registry.createPairing(name: name)
    let payload: [String: JSONValue] = [
      "version": .number(2),
      "pairingCode": .string(grant.code),
      "expiresAt": .number(grant.expiresAt),
      "gatewayId": .string(identity.gatewayID),
      "gatewayName": .string(configuration.effectiveGatewayName),
      // The primary address is the first *reachable* one, never a loopback shortcut: it is what
      // the client tries first, so a bad value here looks exactly like a dead server.
      "publicUrl": .string(primary),
      "endpoints": .array(reachable.map { .string($0) }),
    ]
    let encoded = try Self.encodePairingPayload(.object(payload))
    return PairingOffer(id: grant.id, name: grant.name, expiresAt: grant.expiresAt, qrText: encoded, payload: .object(payload))
  }

  @discardableResult
  public func revoke(deviceID: String) -> Bool {
    let index = registry.list().firstIndex { $0.id == deviceID }
    guard index != nil else { return false }
    lock.lock()
    let victims = clients.values.filter { $0.deviceID == deviceID }
    lock.unlock()
    let revoked = registry.revoke(deviceID: deviceID)
    if revoked {
      for record in victims { record.socket.close(code: 4003, reason: "device revoked") }
    }
    publishStatus()
    return revoked
  }

  public func devices() -> [MobileGatewayDeviceRegistry.DeviceSummary] {
    registry.list()
  }

  /// Re-read Tailscale and republish. Called when the window opens and after the user changes the
  /// setting, rather than on a timer: the answer only changes when a human changes it.
  public func refreshTailscale() async {
    guard tailscaleIsEnabled else {
      lock.lock()
      tailscaleStatus = MobileGatewayTailscaleStatus(state: .notInstalled)
      lock.unlock()
      publishStatus()
      return
    }
    let reading = await tailscaleDiscovery.discover()
    lock.lock()
    tailscaleStatus = reading
    lock.unlock()
    publishStatus()
  }

  /// Replace the public addresses this gateway advertises.
  ///
  /// Updating in place rather than rebuilding the service: the listener keeps its port and every
  /// connected phone keeps its session, which matters because the alternative is dropping the
  /// connection of the user who is right then configuring remote access.
  public func updatePublicEndpoints(_ raw: [String]) throws {
    let normalized = try MobileGatewayConfiguration.normalizeEndpoints(raw)
    lock.lock()
    configuredEndpoints = normalized
    lock.unlock()
    publishStatus()
  }

  /// Turn Tailscale discovery on or off at runtime.
  public func setTailscaleEnabled(_ enabled: Bool) async {
    lock.lock()
    tailscaleEnabledOverride = enabled
    lock.unlock()
    await refreshTailscale()
  }

  /// Whether Tailscale discovery is consulted, honouring a runtime change.
  public var tailscaleIsEnabled: Bool {
    lock.lock(); defer { lock.unlock() }
    return tailscaleEnabledOverride ?? configuration.tailscaleEnabled
  }

  /// The tailnet endpoints currently on offer.
  public func tailscaleURLs() -> [String] {
    lock.lock()
    let reading = tailscaleStatus
    lock.unlock()
    guard tailscaleIsEnabled else { return [] }
    return MobileGatewayTailscaleDiscovery.endpoints(
      for: reading,
      port: listener?.currentStatus.port ?? configuration.lanPort,
      path: Self.webSocketPath
    )
  }

  /// Encode the pairing payload exactly the way the client decodes it: UTF-8 JSON as unpadded
  /// Base64URL. Base64URL is copy-safe and QR-safe (`+`, `/`, `=` never appear), but it is
  /// encoding rather than encryption — secrecy comes from the short TTL and single use.
  static func encodePairingPayload(_ payload: JSONValue) throws -> String {
    let text = try payload.serialized()
    return Data(text.utf8).base64URLEncodedString()
  }

  // MARK: - Mode machine

  private func apply(mode newMode: MobileGatewayMode, persist: Bool) {
    lock.lock()
    if persist { try? identity.setMode(newMode) }
    waitTask?.cancel()
    waitTask = nil
    mode = newMode
    waitExpiresAt = nil
    let openClients = clients.count
    connectedSinceEnabled = openClients > 0
    let shouldArmWait = newMode == .temporary && !connectedSinceEnabled
    let shouldCloseAll = newMode == .disabled
    let records = shouldCloseAll ? Array(clients.values) : []
    if shouldArmWait {
      let deadline = Self.now() + configuration.gatewayWaitTimeout * 1000
      waitExpiresAt = deadline
      waitTask = Task { [weak self] in
        let nanos = UInt64(configuration.gatewayWaitTimeout * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        guard !Task.isCancelled else { return }
        self?.waitWindowExpired()
      }
    }
    lock.unlock()

    for record in records {
      record.socket.close(code: 4004, reason: "mobile gateway disabled")
    }
    if !shouldCloseAll { connectedSinceEnabled = connectedSinceEnabled || openClients > 0 }
  }

  /// The temporary window's three guards, in the plugin's order: an already-disabled gateway,
  /// a device that connected in the meantime, and a socket that is open right now all cancel
  /// the automatic shutdown.
  private func waitWindowExpired() {
    lock.lock()
    let shouldDisable = mode == .temporary && !connectedSinceEnabled && clients.isEmpty
    if shouldDisable {
      mode = .disabled
      waitExpiresAt = nil
      waitTask = nil
    }
    lock.unlock()
    guard shouldDisable else { return }
    try? identity.setMode(.disabled)
    publishStatus()
  }

  private func completeWaitWindow() {
    lock.lock()
    let wasWaiting = !connectedSinceEnabled
    connectedSinceEnabled = true
    if waitExpiresAt != nil {
      waitExpiresAt = nil
      waitTask?.cancel()
      waitTask = nil
    }
    lock.unlock()
    _ = wasWaiting
  }

  // MARK: - Listener

  private func ensureListener() throws -> MobileGatewayListener {
    lock.lock()
    if let listener {
      lock.unlock()
      return listener
    }
    lock.unlock()

    let created = MobileGatewayListener(port: configuration.lanPort, host: configuration.lanHost, delegate: self)
    created.onStatusChange = { [weak self] status in
      guard let self else { return }
      self.lock.lock()
      self.lastError = status.error
      self.lock.unlock()
      self.publishStatus()
    }
    try created.start()
    lock.lock()
    listener = created
    lock.unlock()
    return created
  }

  private func publishStatus() {
    onStatusChange?(status())
  }

  // MARK: - Upgrade decisions

  public func socket(
    _ socket: MobileGatewaySocketConnection,
    decideUpgrade request: WebSocketHandshakeRequest,
    isLoopback: Bool
  ) -> MobileGatewayUpgradeDecision {
    guard request.path == Self.webSocketPath else {
      return .reject(status: 404, code: "not-found", message: "not found")
    }
    guard isEnabled else {
      return .reject(status: 503, code: "service-unavailable", message: "mobile gateway is disabled")
    }

    var device: MobileGatewayDeviceRegistry.DeviceSummary?
    var paired: MobileGatewayDeviceRegistry.PairedDevice?
    switch extractCredential(request) {
    case .pairing(let code):
      // A pairing request without a stable installation id would mint a new trusted device on
      // every reconnect, so an outdated client is refused rather than accommodated.
      guard MobileGatewayDeviceRegistry.normalizeClientDeviceID(request.clientDeviceID) != nil else {
        return .reject(status: 400, code: "bad-request", message: "pairing requires X-DSH-Device-ID; update the iOS client")
      }
      guard let claimed = registry.claimPairing(code: code, clientDeviceID: request.clientDeviceID) else {
        return .reject(status: 401, code: "unauthorized", message: "invalid or expired pairing code")
      }
      paired = claimed
      device = claimed.device
    case .token(let token):
      device = registry.authenticate(token: token, clientDeviceID: request.clientDeviceID)
    case .none:
      break
    }

    // The debug switch relaxes authentication only for loopback peers. A LAN peer is a
    // different machine on the network, and no toggle may turn that into an open control plane.
    let authRequired = isLoopback ? requireAuth : true
    if authRequired && device == nil {
      return .reject(status: 401, code: "unauthorized", message: "missing or invalid device credential")
    }

    let requestedChannel = request.headers["x-dsh-channel"]
    let channel = requestedChannel.flatMap(Channel.init(rawValue:)) ?? .legacy
    lock.lock()
    pendingUpgrades[socket.id] = PendingUpgrade(
      deviceID: device?.id,
      deviceName: device?.name,
      paired: paired,
      channel: channel,
      authenticated: device != nil
    )
    lock.unlock()

    // The agreed subprotocol is always the protocol name; the credential subprotocols are
    // inputs and must never be echoed as the selection.
    return .accept(subprotocol: "dsh-mobile-v1")
  }

  private enum Credential {
    case pairing(String)
    case token(String)
  }

  /// Credential precedence, in the protocol's order: `Authorization: Bearer`, then the
  /// `dsh-auth.` subprotocol, then `dsh-pair.`, then `?pairingCode=`, and only when query tokens
  /// are explicitly allowed, `?token=`. Headers and subprotocols are preferred because a URL
  /// lands in access logs and a query string does not survive a copy/paste intact.
  private func extractCredential(_ request: WebSocketHandshakeRequest) -> Credential? {
    if let token = request.bearerToken, isWellFormedToken(token) { return .token(token) }
    if let token = request.authSubprotocol { return .token(token) }
    if let code = request.pairingSubprotocol { return .pairing(code) }
    if let code = request.query["pairingCode"], !code.isEmpty { return .pairing(code) }
    return nil
  }

  private func isWellFormedToken(_ value: String) -> Bool {
    value.count == 43 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
  }

  private var isEnabled: Bool {
    lock.lock(); defer { lock.unlock() }
    return mode != .disabled
  }

  public func socketDidUpgrade(_ socket: MobileGatewaySocketConnection) {
    lock.lock()
    let pending = pendingUpgrades.removeValue(forKey: socket.id)
    guard let pending else {
      lock.unlock()
      socket.close(code: 1011, reason: "connection state lost")
      return
    }
    let record = ClientRecord(socket: socket, channel: pending.channel)
    record.deviceID = pending.deviceID
    record.deviceName = pending.deviceName
    record.authenticated = pending.authenticated
    clients[socket.id] = record
    lock.unlock()

    if let deviceID = pending.deviceID { _ = registry.connected(deviceID: deviceID) }
    completeWaitWindow()
    publishStatus()

    Task { [weak self] in
      await self?.sendOpeningFrames(to: record, pending: pending)
    }
  }

  public func socket(_ socket: MobileGatewaySocketConnection, didReceive frame: WebSocketFrame) {
    guard case .text(let text) = frame else { return }
    Task { [weak self] in
      await self?.dispatch(text: text, from: socket)
    }
  }

  public func socketDidClose(_ socket: MobileGatewaySocketConnection, error: String?) {
    lock.lock()
    let record = clients.removeValue(forKey: socket.id)
    pendingUpgrades.removeValue(forKey: socket.id)
    // A pending question or approval that this socket had claimed is released so another
    // connection (or the desktop UI) can answer it.
    for (id, question) in pendingQuestions where question.claimedBy == socket.id {
      pendingQuestions[id]?.claimedBy = nil
    }
    for (id, approval) in pendingApprovals where approval.claimedBy == socket.id {
      pendingApprovals[id]?.claimedBy = nil
    }
    lock.unlock()

    record?.sessionPump?.stop()
    record?.controlPump?.stop()
    // An open download belongs to the socket that opened it: without this its file handle
    // would stay open until the idle sweep, which is two minutes of a leaked descriptor per
    // phone that walked out of Wi-Fi range.
    fileTransfer.closeTransfers(owner: socket.id.uuidString)
    if let deviceID = record?.deviceID { registry.disconnected(deviceID: deviceID) }
    publishStatus()
  }

  // MARK: - Opening frames

  private func sendOpeningFrames(to record: ClientRecord, pending: PendingUpgrade) async {
    if let paired = pending.paired {
      let frame: [String: JSONValue] = [
        "kind": .string("paired"),
        "token": .string(paired.token),
        "device": Self.deviceObject(paired.device),
        "gatewayId": .string(identity.gatewayID),
        "gatewayName": .string(configuration.effectiveGatewayName),
      ]
      record.socket.send(text: Self.encode(.object(frame)))
    }

    var capabilities: [JSONValue] = [
      "split-channels", "assistant-stream-v1", "history-format-version", "projection-baseline",
      "images", "session-create", "session-agent-preset", "commands", "tasks", "goals",
      "session-cancel", "queue-control", "session-archive", "session-rename",
    ].map { .string($0) }
    if configuration.fileDownloadsEnabled { capabilities.append(.string("file-downloads")) }

    var hello: [String: JSONValue] = [
      "kind": .string("hello"),
      "gatewayId": .string(identity.gatewayID),
      "gatewayName": .string(configuration.effectiveGatewayName),
      "protocol": .number(Double(MobileGatewayConfiguration.protocolVersion)),
      "dshVersion": .string(adapter.hostVersion ?? MobileGatewayConfiguration.dshVersion),
      "historyFormatVersion": .number(Double(MobileGatewayConfiguration.historyFormatVersion)),
      "capabilities": .array(capabilities),
      "port": .number(Double(listener?.currentStatus.port ?? configuration.lanPort)),
      "clients": .number(Double(currentClientCount())),
      "authenticated": .bool(pending.authenticated),
    ]
    if let deviceID = pending.deviceID {
      hello["device"] = .object([
        "id": .string(deviceID),
        "name": .string(pending.deviceName ?? ""),
      ])
    }
    record.socket.send(text: Self.encode(.object(hello)))

    if record.channel != .conversation {
      startControlPump(for: record)
      replayPendingInteractions(to: record, replay: true)
    }
  }

  static func deviceObject(_ device: MobileGatewayDeviceRegistry.DeviceSummary) -> JSONValue {
    .object([
      "id": .string(device.id),
      "name": .string(device.name),
      "createdAt": .number(device.createdAt),
      "lastSeenAt": device.lastSeenAt.map { JSONValue.number($0) } ?? .null,
      "online": .bool(device.online),
      "connections": .number(Double(device.connections)),
    ])
  }

  // MARK: - Dispatch

  private static let conversationVerbs: Set<String> = ["message", "history", "subscribe", "unsubscribe"]

  private func dispatch(text: String, from socket: MobileGatewaySocketConnection) async {
    let message: JSONValue
    do {
      message = try JSONValue.parse(text, context: "mobile.wire")
    } catch {
      // The exact legacy frame: no `code`, because clients written against it key off the
      // message text.
      socket.send(text: Self.encode(.object([
        "kind": .string("error"),
        "message": .string("invalid json"),
      ])))
      return
    }
    guard let type = message["type"]?.stringValue else { return }

    guard let record = clientRecord(for: socket.id) else { return }

    let isConversation = Self.conversationVerbs.contains(type)
    if record.channel == .control && isConversation {
      sendWrongChannel(type, to: socket)
      return
    }
    if record.channel == .conversation && !isConversation && type != "ping" {
      sendWrongChannel(type, to: socket)
      return
    }

    switch type {
    case "ping":
      socket.send(text: Self.encode(.object([
        "kind": .string("pong"),
        "at": .number(Self.now()),
      ])))
    case "subscribe":
      await handleSubscribe(message, record: record, socket: socket)
    case "unsubscribe":
      handleUnsubscribe(message, record: record, socket: socket)
    case "question-answer", "question-cancel":
      socket.send(text: Self.encode(await respondToQuestion(message, cancel: type == "question-cancel")))
    case "approval-response":
      socket.send(text: Self.encode(await respondToApproval(message)))
    case "message":
      if let frame = await router.admitMessage(message) { socket.send(text: Self.encode(frame)) }
    default:
      if MobileGatewayFileTransfer.verbs.contains(type) {
        // The socket's id is the transfer owner: a `transferId` another connection happens to
        // observe must not be readable or cancellable from here.
        _ = await fileTransfer.handle(message, owner: socket.id.uuidString) { [weak socket] frame in
          socket?.send(text: Self.encode(frame))
        }
        return
      }
      if MobileGatewayQueryRouter.verbs.contains(type) {
        if let frame = await router.handle(message) { socket.send(text: Self.encode(frame)) }
        return
      }
      socket.send(text: Self.encode(.object([
        "kind": .string("error"),
        "message": .string("unknown message type: \(type)"),
      ])))
    }
  }

  private func sendWrongChannel(_ type: String, to socket: MobileGatewaySocketConnection) {
    socket.send(text: Self.encode(.object([
      "kind": .string("error"),
      "code": .string("wrong-channel"),
      "requestType": .string(type),
      "message": .string("Request belongs to the other mobile channel"),
    ])))
  }

  private func clientRecord(for id: UUID) -> ClientRecord? {
    lock.lock(); defer { lock.unlock() }
    return clients[id]
  }

  private func currentClientCount() -> Int {
    lock.lock(); defer { lock.unlock() }
    return clients.count
  }

  // MARK: - Subscribe / unsubscribe

  private func handleSubscribe(_ message: JSONValue, record: ClientRecord, socket: MobileGatewaySocketConnection) async {
    if let assistantStream = message["assistantStream"], assistantStream.boolValue == nil {
      socket.send(text: Self.encode(.object([
        "kind": .string("error"), "code": .string("bad-request"),
        "message": .string("assistantStream must be a boolean"),
        "requestType": .string("subscribe"),
      ])))
      return
    }
    let assistantStream = message["assistantStream"]?.boolValue ?? false
    let sessionID: String?
    if let raw = message["sessionId"]?.stringValue, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
      sessionID = raw
    } else {
      sessionID = nil
    }
    if assistantStream && sessionID == nil {
      socket.send(text: Self.encode(.object([
        "kind": .string("error"), "code": .string("bad-request"),
        "message": .string("assistantStream requires a sessionId"),
        "requestType": .string("subscribe"),
      ])))
      return
    }

    record.sessionPump?.stop()
    record.sessionPump = nil
    record.filterSessionID = sessionID
    record.assistantStream = assistantStream

    // The pump mints the subscription identity, and the client discards frames whose
    // `subscriptionId` it has not seen confirmed — so the pump is built first and its id is
    // what the confirmation carries. Starting it before that would race the first frame
    // against the confirmation that legitimises it.
    var pump: MobileGatewaySessionPump?
    if let sessionID {
      pump = MobileGatewaySessionPump(
        adapter: adapter,
        sessionID: sessionID,
        onFrame: { [weak self, weak socket] frame in
          socket?.send(text: Self.encode(frame))
          self?.observeDurableEvent(frame)
        },
        onFailure: { [weak self, weak socket] error in
          // A follower that cannot start is not recoverable at this layer: the client needs to
          // know its subscription is dead rather than silently receive nothing.
          socket?.close(code: 1011, reason: "session follower failed")
          self?.recordError(String(describing: error))
        }
      )
    }
    let subscriptionID = pump?.subscriptionID ?? UUID().uuidString
    record.subscriptionID = subscriptionID

    socket.send(text: Self.encode(.object([
      "kind": .string("subscribed"),
      "sessionId": sessionID.map { JSONValue.string($0) } ?? .null,
      "subscriptionId": .string(subscriptionID),
      "assistantStream": .bool(assistantStream),
    ])))

    if let pump {
      record.sessionPump = pump
      pump.start()
    }
    replayPendingInteractions(to: record, replay: true)
  }

  private func handleUnsubscribe(_ message: JSONValue, record: ClientRecord, socket: MobileGatewaySocketConnection) {
    record.sessionPump?.stop()
    record.sessionPump = nil
    record.filterSessionID = nil
    record.assistantStream = false
    record.subscriptionID = nil
    var frame: [String: JSONValue] = ["kind": .string("unsubscribed")]
    if let sessionID = message["sessionId"]?.stringValue { frame["sessionId"] = .string(sessionID) }
    socket.send(text: Self.encode(.object(frame)))
  }

  private func startControlPump(for record: ClientRecord) {    let pump = MobileGatewayControlPump(
      adapter: adapter,
      onFrame: { [weak record] frame in record?.socket.send(text: Self.encode(frame)) },
      onFailure: { [weak self] error in self?.recordError(String(describing: error)) }
    )
    record.controlPump = pump
    pump.start()
  }

  // MARK: - Human in the loop

  private func startEventPump() {
    lock.lock()
    if eventPump != nil { lock.unlock(); return }
    lock.unlock()
    let task = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        do {
          let stream = try await self.adapter.events()
          for try await event in stream {
            if Task.isCancelled { return }
            await self.consume(hostEvent: event)
          }
        } catch {
          self.recordError(String(describing: error))
        }
        // The carrier dies with the harness; back off before re-establishing it rather than
        // spinning against a harness that is not there yet.
        if (try? await Task.sleep(nanoseconds: 2_000_000_000)) == nil { return }
      }
    }
    lock.lock()
    eventPump = task
    lock.unlock()
  }

  /// Ping every connection on an interval.
  ///
  /// The phone does not ping while it sits idle in the foreground, and an idle proxied WebSocket is
  /// closed by Cloudflare, by most reverse proxies, and by home routers' NAT tables. One ping every
  /// interval is traffic in both directions — the peer's WebSocket stack answers the pong without
  /// the app being involved — which is all those middleboxes ask for.
  private func startKeepAlive() {
    let interval = configuration.keepAliveInterval
    guard interval > 0 else { return }
    let task = Task { [weak self] in
      while !Task.isCancelled {
        if (try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))) == nil { return }
        guard let self else { return }
        self.lock.lock()
        let sockets = self.clients.values.map(\.socket)
        self.lock.unlock()
        for socket in sockets { socket.sendPing() }
      }
    }
    lock.lock()
    keepAliveTask?.cancel()
    keepAliveTask = task
    lock.unlock()
  }

  private func consume(hostEvent: MobileGatewayHostEvent) async {
    switch hostEvent {
    case .ready, .emit:
      return
    case .cancel(let eventID):
      let removedQuestion = takePendingQuestion(eventID)
      let removedApproval = takePendingApproval(eventID)
      if let removedQuestion {
        broadcast(.object([
          "kind": .string("question-resolved"),
          "rpcId": .string(removedQuestion.rpcId),
          "sessionId": .string(removedQuestion.sessionID),
          "outcome": .string("cancelled"),
        ]))
      }
      if let removedApproval {
        broadcast(.object([
          "kind": .string("approval-resolved"),
          "rpcId": .string(removedApproval.rpcId),
          "sessionId": .string(removedApproval.sessionID),
          "approvalId": .string(removedApproval.approvalID),
          "outcome": .string("cancelled"),
        ]))
      }
    case .waterfall(let eventID, let agentID, let event, let request):
      switch event {
      case "approval/request":
        let approval = PendingApproval(
          rpcId: eventID,
          sessionID: agentID,
          approvalID: request["approvalId"]?.stringValue ?? eventID,
          toolName: request["toolName"]?.stringValue ?? "未知工具",
          claimedBy: nil
        )
        lock.lock()
        pendingApprovals[eventID] = approval
        lock.unlock()
        var frame: [String: JSONValue] = [
          "kind": .string("approval-requested"),
          "rpcId": .string(approval.rpcId),
          "sessionId": .string(approval.sessionID),
          "approvalId": .string(approval.approvalID),
          "toolName": .string(approval.toolName),
        ]
        if let callID = request["callId"] { frame["callId"] = callID }
        if let reason = request["reason"] { frame["reason"] = reason }
        broadcastInteractions(.object(frame), sessionID: approval.sessionID)
      case "user-questions/request":
        let questions = request["questions"] ?? .array([])
        let pending = PendingQuestion(rpcId: eventID, sessionID: agentID, questions: questions, claimedBy: nil)
        lock.lock()
        pendingQuestions[eventID] = pending
        lock.unlock()
        let frame: JSONValue = .object([
          "kind": .string("question-requested"),
          "rpcId": .string(pending.rpcId),
          "sessionId": .string(pending.sessionID),
          "questions": questions,
        ])
        broadcastInteractions(frame, sessionID: pending.sessionID)
      default:
        return
      }
    }
  }

  private func takePendingQuestion(_ eventID: String) -> PendingQuestion? {
    lock.lock(); defer { lock.unlock() }
    return pendingQuestions.removeValue(forKey: eventID)
  }

  private func takePendingApproval(_ eventID: String) -> PendingApproval? {
    lock.lock(); defer { lock.unlock() }
    return pendingApprovals.removeValue(forKey: eventID)
  }

  /// Re-send every still-pending request to one connection. Without this, a phone that
  /// reconnects would never learn about a question the host is still holding open.
  private func replayPendingInteractions(to record: ClientRecord, replay: Bool) {
    lock.lock()
    let questions = pendingQuestions.values.filter { matches(record, sessionID: $0.sessionID) }
    let approvals = pendingApprovals.values.filter { matches(record, sessionID: $0.sessionID) }
    lock.unlock()
    guard record.channel != .conversation else { return }
    for question in questions {
      var frame: [String: JSONValue] = [
        "kind": .string("question-requested"),
        "rpcId": .string(question.rpcId),
        "sessionId": .string(question.sessionID),
        "questions": question.questions,
      ]
      if replay { frame["replay"] = .bool(true) }
      record.socket.send(text: Self.encode(.object(frame)))
    }
    for approval in approvals {
      var frame: [String: JSONValue] = [
        "kind": .string("approval-requested"),
        "rpcId": .string(approval.rpcId),
        "sessionId": .string(approval.sessionID),
        "approvalId": .string(approval.approvalID),
        "toolName": .string(approval.toolName),
      ]
      if replay { frame["replay"] = .bool(true) }
      record.socket.send(text: Self.encode(.object(frame)))
    }
  }

  private func matches(_ record: ClientRecord, sessionID: String) -> Bool {
    guard let filter = record.filterSessionID else { return true }
    return filter == sessionID
  }

  private func respondToQuestion(_ message: JSONValue, cancel: Bool) async -> JSONValue {
    let type = cancel ? "question-cancel" : "question-answer"
    let rpcId = message["rpcId"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    let sessionId = message["sessionId"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !rpcId.isEmpty, !sessionId.isEmpty else {
      return .object([
        "kind": .string("error"), "code": .string("bad-request"),
        "message": .string("\(type) requires rpcId and sessionId"),
        "requestType": .string(type),
      ])
    }
    guard let pending = takePendingQuestion(rpcId) else {
      return .object([
        "kind": .string("question-response"), "rpcId": .string(rpcId), "sessionId": .string(sessionId),
        "action": .string(cancel ? "cancel" : "answer"), "accepted": .bool(false),
        "reason": .string("not-pending"),
      ])
    }
    guard pending.sessionID == sessionId else {
      lock.lock(); pendingQuestions[rpcId] = pending; lock.unlock()
      return .object([
        "kind": .string("error"), "code": .string("bad-request"),
        "message": .string("sessionId does not match the pending question"),
        "requestType": .string(type), "sessionId": .string(sessionId),
      ])
    }

    var value: JSONValue = .object([:])
    if !cancel {
      guard let answers = message["answers"]?.arrayValue else {
        lock.lock(); pendingQuestions[rpcId] = pending; lock.unlock()
        return .object([
          "kind": .string("error"), "code": .string("bad-request"),
          "message": .string("question-answer requires an answers array"),
          "requestType": .string(type), "sessionId": .string(sessionId),
        ])
      }
      switch Self.normalizeQuestionAnswers(pending, answers: answers) {
      case .failure(let error):
        lock.lock(); pendingQuestions[rpcId] = pending; lock.unlock()
        return .object([
          "kind": .string("error"), "code": .string("bad-response"), "message": .string(error.message),
          "requestType": .string(type), "sessionId": .string(sessionId),
        ])
      case .success(let normalized):
        value = normalized
      }
    }

    do {
      try await adapter.answer(eventID: rpcId, value: value)
    } catch {
      // The host is gone: the request can never be answered, so it is dropped rather than
      // re-queued forever.
      recordError(String(describing: error))
    }
    broadcast(.object([
      "kind": .string("question-resolved"), "rpcId": .string(rpcId),
      "sessionId": .string(sessionId), "outcome": .string(cancel ? "cancelled" : "answered"),
    ]))
    return .object([
      "kind": .string("question-response"), "rpcId": .string(rpcId), "sessionId": .string(sessionId),
      "action": .string(cancel ? "cancel" : "answer"), "accepted": .bool(true),
    ])
  }

  /// Validate answers exactly as the protocol specifies. Every failure is a `bad-response`
  /// whose message is the contract the client's UI was written against.
  ///
  /// A `Result` rather than a throwing function because the failure is data: the exact string
  /// travels back to the phone as the error's `message`.
  private static func normalizeQuestionAnswers(
    _ pending: PendingQuestion,
    answers: [JSONValue]
  ) -> Result<JSONValue, QuestionAnswerError> {
    guard let questions = pending.questions.arrayValue else {
      return .failure(.init(message: "answers must cover every question exactly once"))
    }
    guard answers.count == questions.count else {
      return .failure(.init(message: "answers must cover every question exactly once"))
    }
    var normalized: [JSONValue] = []
    for index in questions.indices {
      let question = questions[index]
      let answer = answers[index]
      guard let questionID = question["id"]?.stringValue,
            answer["id"]?.stringValue == questionID,
            let selected = answer["selected"]?.arrayValue else {
        return .failure(.init(message: "answers must preserve question order, ids, and selected arrays"))
      }
      var labels: [String] = []
      for value in selected {
        guard let label = value.stringValue else {
          return .failure(.init(message: "selected values must be strings"))
        }
        labels.append(label)
      }
      guard Set(labels).count == labels.count else {
        return .failure(.init(message: "selected values must not repeat"))
      }
      let offered = Set((question["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue })
      guard labels.allSatisfy({ offered.contains($0) }) else {
        return .failure(.init(message: "selected values must match offered option labels"))
      }
      let multiSelect = question["multiSelect"]?.boolValue == true
      if !multiSelect && labels.count > 1 {
        return .failure(.init(message: "single-select questions accept at most one selection"))
      }
      var entry: [String: JSONValue] = [
        "id": .string(questionID),
        "selected": .array(labels.map { .string($0) }),
      ]
      if let custom = answer["custom"], !custom.isNull {
        guard let text = custom.stringValue, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
          return .failure(.init(message: "custom answers must be non-empty strings"))
        }
        if !multiSelect && !labels.isEmpty {
          return .failure(.init(message: "single-select custom answers cannot accompany a selection"))
        }
        entry["custom"] = .string(text.trimmingCharacters(in: .whitespaces))
      }
      normalized.append(.object(entry))
    }
    return .success(.object(["answers": .array(normalized)]))
  }

  /// The validation message, wrapped so it can be a `Result` failure. `String` is not an
  /// `Error`, and making the message its own error type keeps the wording in one place.
  struct QuestionAnswerError: Error, Equatable {
    var message: String
  }

  private func respondToApproval(_ message: JSONValue) async -> JSONValue {
    let rpcId = message["rpcId"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    let sessionId = message["sessionId"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    let approvalId = message["approvalId"]?.stringValue?.trimmingCharacters(in: .whitespaces)
    let outcome = message["outcome"]?.stringValue ?? ""
    guard !rpcId.isEmpty, !sessionId.isEmpty, let approvalId, !approvalId.isEmpty else {
      return .object([
        "kind": .string("error"), "code": .string("bad-request"),
        "message": .string("approval-response requires rpcId, sessionId and approvalId"),
        "requestType": .string("approval-response"),
      ])
    }
    guard outcome == "allowed-once" || outcome == "rejected" else {
      return .object([
        "kind": .string("error"), "code": .string("bad-response"),
        "message": .string("outcome must be allowed-once or rejected"),
        "requestType": .string("approval-response"), "sessionId": .string(sessionId),
      ])
    }
    guard let pending = takePendingApproval(rpcId) else {
      return .object([
        "kind": .string("approval-response"), "rpcId": .string(rpcId), "sessionId": .string(sessionId),
        "approvalId": .string(approvalId), "accepted": .bool(false), "reason": .string("not-pending"),
      ])
    }
    guard pending.sessionID == sessionId else {
      lock.lock(); pendingApprovals[rpcId] = pending; lock.unlock()
      return .object([
        "kind": .string("error"), "code": .string("bad-request"),
        "message": .string("sessionId does not match the pending approval"),
        "requestType": .string("approval-response"), "sessionId": .string(sessionId),
      ])
    }
    do {
      try await adapter.answer(eventID: rpcId, value: .string(outcome))
    } catch {
      recordError(String(describing: error))
    }
    broadcast(.object([
      "kind": .string("approval-resolved"), "rpcId": .string(rpcId), "sessionId": .string(sessionId),
      "approvalId": .string(pending.approvalID), "outcome": .string(outcome),
    ]))
    return .object([
      "kind": .string("approval-response"), "rpcId": .string(rpcId), "sessionId": .string(sessionId),
      "approvalId": .string(pending.approvalID), "accepted": .bool(true),
    ])
  }

  // MARK: - Broadcasting

  /// Send a frame to every connection, or to one session's conversation channel.
  ///
  /// The conversation channel deliberately does not receive interaction broadcasts: a phone
  /// showing one transcript must not be interrupted by another session's approval.
  public func broadcast(_ frame: JSONValue) {
    let text = Self.encode(frame)
    lock.lock()
    let targets = Array(clients.values).filter { $0.channel != .conversation }
    lock.unlock()
    for record in targets { record.socket.send(text: text) }
  }

  private func broadcastInteractions(_ frame: JSONValue, sessionID: String) {
    let text = Self.encode(frame)
    lock.lock()
    let targets = Array(clients.values).filter { record in
      record.channel != .conversation && matches(record, sessionID: sessionID)
    }
    lock.unlock()
    for record in targets { record.socket.send(text: text) }
  }

  // MARK: - Helpers

  private var router: MobileGatewayQueryRouter {
    MobileGatewayQueryRouter(
      adapter: adapter,
      configuration: configuration,
      broadcast: { [weak self] frame in self?.broadcast(frame) }
    )
  }

  private func recordError(_ message: String) {
    lock.lock()
    lastError = message
    lock.unlock()
  }

  /// Feed one durable `event` frame back into the adapter.
  ///
  /// The adapter locks a session's agent preset from the moment a prompt is admitted until
  /// `turn/start` proves the turn began. Without this the marker would never retire, and a
  /// session that had been prompted once could never change its preset again — a lock that
  /// outlives its reason is worse than no lock.
  private func observeDurableEvent(_ frame: JSONValue) {
    guard frame["kind"]?.stringValue == "event",
          let sessionID = frame["sessionId"]?.stringValue,
          frame["type"]?.stringValue != nil else { return }
    Task { [adapter] in
      await adapter.observeSessionEvent(sessionID: sessionID, event: frame)
    }
  }

  static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

  /// Serialize a frame for the wire.
  ///
  /// The Node plugin normalises lone UTF-16 surrogates here because a JavaScript string can
  /// hold one and `JSON.stringify` will happily emit it. A Swift `String` cannot represent a
  /// lone surrogate at all, so this is a boundary assertion rather than a repair: it exists so
  /// the invariant is stated where every frame crosses, and so a future path that builds a
  /// string from raw UTF-16 code units has one obvious place to be caught.
  static func encode(_ frame: JSONValue) -> String {
    guard let text = try? frame.serialized() else { return "{\"kind\":\"error\",\"message\":\"encoding failed\"}" }
    return sanitizeLoneSurrogates(text)
  }

  static func sanitizeLoneSurrogates(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: { (0xD800...0xDFFF).contains($0.value) }) else { return text }
    return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
      (0xD800...0xDFFF).contains(scalar.value) ? Unicode.Scalar(0xFFFD)! : scalar
    }))
  }

  // MARK: - Endpoint advertisement

  /// Every address a phone could use, in the order the pairing payload should offer them.
  public func advertisedEndpoints(includeLAN: Bool) -> [String] {
    var result: [String] = []
    if includeLAN && configuration.lanEnabled {
      result.append(contentsOf: lanWebSocketURLs(port: listener?.currentStatus.port ?? configuration.lanPort))
    }
    lock.lock()
    let publicEndpoints = configuredEndpoints
    lock.unlock()
    result.append(contentsOf: publicEndpoints)
    // A tailnet address is additive and additive only: it can extend the reach of a pairing code,
    // never replace a LAN address that is faster and works with Tailscale switched off.
    result.append(contentsOf: tailscaleURLs())
    var seen = Set<String>()
    return result.filter { seen.insert($0).inserted }.prefix(16).map { $0 }
  }

  func lanWebSocketURLs(port: UInt16) -> [String] {
    guard configuration.lanEnabled else { return [] }
    let hosts: [String]
    if let advertised = configuration.lanAdvertiseHost?.trimmingCharacters(in: .whitespaces), !advertised.isEmpty {
      hosts = [advertised]
    } else if configuration.lanHost != "0.0.0.0" && configuration.lanHost != "::" {
      hosts = [configuration.lanHost]
    } else {
      hosts = MobileGatewayService.privateLanAddresses()
    }
    return hosts
      .filter { MobileGatewayService.isPrivateNetworkHostname($0) }
      .prefix(16)
      .map { host in
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return "ws://\(bracketed):\(port)\(Self.webSocketPath)"
      }
  }

  /// IPv4 addresses on up interfaces, narrowed to the private ranges a phone on the same Wi-Fi
  /// can actually reach.
  static func privateLanAddresses() -> [String] {
    var addresses: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
      defer { pointer = current.pointee.ifa_next }
      let flags = Int32(current.pointee.ifa_flags)
      guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
      guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
        nil, 0, NI_NUMERICHOST
      )
      guard result == 0 else { continue }
      let host = String(cString: buffer)
      if isPrivateNetworkHostname(host) { addresses.append(host) }
    }
    return addresses
  }

  /// Loopback, link-local, and the private IPv4/IPv6 ranges. A public address is never offered
  /// as a LAN endpoint: a phone cannot reach it without a TLS proxy, and advertising it would
  /// only produce a connection that times out.
  static func isPrivateNetworkHostname(_ host: String) -> Bool {
    MobileGatewayConfiguration.isPrivateNetworkHost(host)
  }
}
