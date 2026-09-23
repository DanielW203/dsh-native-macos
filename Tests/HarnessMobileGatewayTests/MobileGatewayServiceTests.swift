import Foundation
import HarnessKit
import XCTest

@testable import HarnessMobileGateway

/// The gateway's decisions and its connection behaviour, driven directly: a scripted host, a
/// recording transport, and no socket, no port and no harness.
final class MobileGatewayServiceTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: - Fixtures

  /// `requireAuth: false` by default so a loopback test connection is accepted without a
  /// credential; the tests that are *about* authentication pass their own value.
  private func configuration(
    mode: MobileGatewayMode = .persistent,
    requireAuth: Bool = false,
    lanEnabled: Bool = false,
    lanAdvertiseHost: String? = nil,
    endpoints: [String] = ["ws://10.0.0.9:3081/ws/mobile"]
  ) -> MobileGatewayConfiguration {
    MobileGatewayConfiguration(
      gatewayName: "Test Gateway",
      gatewayMode: mode,
      lanHost: "127.0.0.1",
      lanPort: 3081,
      // No listener in tests: binding a real port would make the suite depend on the machine's
      // network state, and the decisions under test are the upgrade and dispatch rules.
      lanEnabled: lanEnabled,
      requireAuth: requireAuth,
      deviceFile: directory.appendingPathComponent("devices.json"),
      stateFile: directory.appendingPathComponent("devices.json.gateway.json"),
      endpoints: endpoints,
      lanAdvertiseHost: lanAdvertiseHost
    )
  }

  private func makeService(
    configuration: MobileGatewayConfiguration? = nil,
    rpc: ScriptedRPC = ScriptedRPC()
  ) throws -> MobileGatewayService {
    try MobileGatewayService(configuration: configuration ?? self.configuration(), rpc: rpc)
  }

  private func upgradeRequest(
    path: String = MobileGatewayService.webSocketPath,
    headers: [String: String] = ["Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="],
    query: [String: String] = [:],
    subprotocols: [String] = ["dsh-mobile-v1"]
  ) -> WebSocketHandshakeRequest {
    var allHeaders = headers
    allHeaders["sec-websocket-protocol"] = subprotocols.joined(separator: ", ")
    return WebSocketHandshakeRequest(
      method: "GET",
      path: path,
      query: query,
      headers: allHeaders,
      subprotocols: subprotocols
    )
  }

  /// A bare connection whose delegate is a no-op: used by the tests that call the service's
  /// delegate methods directly to assert a decision.
  private func makeSocket(_ transport: RecordingTransport) -> MobileGatewaySocketConnection {
    MobileGatewaySocketConnection(
      transport: transport,
      isLoopback: false,
      remoteDescription: "192.168.1.20:5000",
      delegate: NullDelegate(),
      queue: DispatchQueue(label: "test.socket.direct")
    )
  }

  // MARK: - Driving a real connection

  /// Perform the real HTTP upgrade through the connection state machine, with the *service* as
  /// the delegate — so the frames under test travel the same path a phone's do.
  ///
  /// The connection is retained on the test, which mirrors what the listener does in production:
  /// nothing else owns an accepted socket, so a test that dropped the reference would let the
  /// connection go away mid-handshake.
  @discardableResult
  private func connect(
    _ service: MobileGatewayService,
    transport: RecordingTransport,
    isLoopback: Bool = true,
    headers: [String: String] = [:],
    path: String = MobileGatewayService.webSocketPath,
    subprotocols: [String] = ["dsh-mobile-v1"]
  ) -> MobileGatewaySocketConnection {
    let socket = MobileGatewaySocketConnection(
      transport: transport,
      isLoopback: isLoopback,
      remoteDescription: isLoopback ? "127.0.0.1:52000" : "192.168.1.20:5000",
      delegate: service,
      queue: DispatchQueue(label: "test.socket.\(UUID().uuidString)")
    )
    socket.start()
    var lines = [
      "Host: 192.168.1.10:3081",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Version: 13",
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
    ]
    for (name, value) in headers { lines.append("\(name): \(value)") }
    lines.append("Sec-WebSocket-Protocol: \(subprotocols.joined(separator: ", "))")
    let request = "GET \(path) HTTP/1.1\r\n" + lines.joined(separator: "\r\n") + "\r\n\r\n"
    socket.receive(Data(request.utf8))
    liveSockets.append(socket)
    return socket
  }

  /// Keeps every connection this test opened alive, the way the listener's table does.
  private var liveSockets: [MobileGatewaySocketConnection] = []

  /// A masked client text frame, the way a browser or URLSession sends one.
  private func clientFrame(_ text: String) -> Data {
    let payload = Data(text.utf8)
    let mask: [UInt8] = [7, 11, 13, 17]
    var frame = Data([0x81])
    let count = payload.count
    if count <= 125 {
      frame.append(UInt8(0x80 | count))
    } else if count <= 0xFFFF {
      frame.append(0x80 | 126)
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
    for (index, byte) in payload.enumerated() { frame.append(byte ^ mask[index & 3]) }
    return frame
  }

  private func send(_ json: String, to socket: MobileGatewaySocketConnection) {
    socket.receive(clientFrame(json))
  }

  // MARK: - Upgrade decisions

  func testDisabledGatewayRefusesWith503() throws {
    let service = try makeService(configuration: configuration(mode: .disabled))
    let decision = service.socket(makeSocket(RecordingTransport()), decideUpgrade: upgradeRequest(), isLoopback: true)
    XCTAssertEqual(decision, .reject(status: 503, code: "service-unavailable", message: "mobile gateway is disabled"))
  }

  func testUnknownPathIs404() throws {
    let service = try makeService()
    let decision = service.socket(
      makeSocket(RecordingTransport()),
      decideUpgrade: upgradeRequest(path: "/ws/other"),
      isLoopback: true
    )
    XCTAssertEqual(decision, .reject(status: 404, code: "not-found", message: "not found"))
  }

  /// A pairing request without a stable installation id would mint a new trusted device on
  /// every reconnect, so the outdated client is refused instead of accommodated.
  func testPairingWithoutInstallationIDIs400() throws {
    let service = try makeService()
    let decision = service.socket(
      makeSocket(RecordingTransport()),
      decideUpgrade: upgradeRequest(subprotocols: ["dsh-mobile-v1", "dsh-pair.SOMECODE"]),
      isLoopback: false
    )
    XCTAssertEqual(
      decision,
      .reject(status: 400, code: "bad-request", message: "pairing requires X-DSH-Device-ID; update the iOS client")
    )
  }

  func testBadPairingCodeIs401() throws {
    let service = try makeService()
    let request = upgradeRequest(
      headers: ["Sec-WebSocket-Key": "k", "x-dsh-device-id": "ABCDEFGH12345678"],
      subprotocols: ["dsh-mobile-v1", "dsh-pair.NOPE"]
    )
    let decision = service.socket(makeSocket(RecordingTransport()), decideUpgrade: request, isLoopback: false)
    XCTAssertEqual(decision, .reject(status: 401, code: "unauthorized", message: "invalid or expired pairing code"))
  }

  func testMissingCredentialIs401OnTheLAN() throws {
    let service = try makeService(configuration: configuration(requireAuth: false))
    let decision = service.socket(makeSocket(RecordingTransport()), decideUpgrade: upgradeRequest(), isLoopback: false)
    XCTAssertEqual(
      decision,
      .reject(status: 401, code: "unauthorized", message: "missing or invalid device credential")
    )
  }

  /// With authentication on, even a loopback peer must present a credential.
  func testMissingCredentialIs401OnLoopbackWhenAuthIsOn() throws {
    let service = try makeService(configuration: configuration(requireAuth: true))
    let decision = service.socket(makeSocket(RecordingTransport()), decideUpgrade: upgradeRequest(), isLoopback: true)
    XCTAssertEqual(
      decision,
      .reject(status: 401, code: "unauthorized", message: "missing or invalid device credential")
    )
  }

  // MARK: - Opening frames

  /// The debug switch relaxes authentication only for loopback peers: a LAN peer is a different
  /// machine, and no toggle may turn that into an open control plane.
  func testLoopbackWithoutAuthIsAcceptedButUnauthenticated() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    connect(service, transport: transport)
    let hello = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    XCTAssertEqual(hello["protocol"]?.intValue, 3)
    XCTAssertEqual(hello["authenticated"]?.boolValue, false)
    XCTAssertEqual(hello["historyFormatVersion"]?.intValue, 3)
    XCTAssertEqual(hello["gatewayName"]?.stringValue, "Test Gateway")
    XCTAssertNil(hello["device"])
    XCTAssertEqual(hello["port"]?.intValue, 3081)
    XCTAssertEqual(hello["clients"]?.intValue, 1)
  }

  func testHelloAdvertisesTheDocumentedCapabilities() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    connect(service, transport: transport)
    let hello = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    let capabilities = (hello["capabilities"]?.arrayValue ?? []).compactMap { $0.stringValue }
    XCTAssertEqual(capabilities, [
      "split-channels", "assistant-stream-v1", "history-format-version", "projection-baseline",
      "images", "session-create", "session-agent-preset", "commands", "tasks", "goals",
      "session-cancel", "queue-control", "session-archive", "session-rename", "file-downloads",
    ])
  }

  func testPairingDeliversTheTokenOnceAndThenHello() throws {
    let service = try makeService()
    let offer = try service.createPairing(name: "iPhone")
    let code = try XCTUnwrap(offer.payload["pairingCode"]?.stringValue)
    let transport = RecordingTransport()
    let socket = connect(
      service,
      transport: transport,
      headers: ["x-dsh-device-id": "ABCDEFGH12345678"],
      subprotocols: ["dsh-mobile-v1", "dsh-pair.\(code)"]
    )

    let paired = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "paired" })
    let token = try XCTUnwrap(paired["token"]?.stringValue)
    XCTAssertEqual(token.count, 43)
    XCTAssertEqual(paired["gatewayId"]?.stringValue, service.status().gatewayID)
    XCTAssertEqual(paired["device"]?["name"]?.stringValue, "iPhone")

    let hello = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    XCTAssertEqual(hello["authenticated"]?.boolValue, true)
    XCTAssertEqual(hello["device"]?["name"]?.stringValue, "iPhone")
    XCTAssertEqual(service.devices().count, 1)

    // The code is spent: replaying it is refused, and the token is what works now.
    let replayRequest = upgradeRequest(
      headers: ["Sec-WebSocket-Key": "k", "x-dsh-device-id": "ABCDEFGH12345678"],
      subprotocols: ["dsh-mobile-v1", "dsh-pair.\(code)"]
    )
    XCTAssertEqual(
      service.socket(makeSocket(RecordingTransport()), decideUpgrade: replayRequest, isLoopback: true),
      .reject(status: 401, code: "unauthorized", message: "invalid or expired pairing code")
    )
    let tokenRequest = upgradeRequest(
      headers: ["Sec-WebSocket-Key": "k", "Authorization": "Bearer \(token)"]
    )
    XCTAssertEqual(
      service.socket(makeSocket(RecordingTransport()), decideUpgrade: tokenRequest, isLoopback: true),
      .accept(subprotocol: "dsh-mobile-v1")
    )
    _ = socket
  }

  /// The pairing payload is UTF-8 JSON in unpadded Base64URL, because that is the only encoding
  /// the client decodes and the only one that survives a QR code and a copy/paste.
  func testPairingPayloadIsBase64URL() throws {
    let service = try makeService()
    let offer = try service.createPairing(name: "iPhone")
    XCTAssertFalse(offer.qrText.contains("+"))
    XCTAssertFalse(offer.qrText.contains("/"))
    XCTAssertFalse(offer.qrText.contains("="))
    XCTAssertEqual(offer.payload["version"]?.intValue, 2)
    XCTAssertEqual(offer.payload["gatewayId"]?.stringValue, service.status().gatewayID)
    XCTAssertFalse(offer.payload["pairingCode"]?.stringValue?.isEmpty ?? true)
    let decoded = try XCTUnwrap(String(data: try XCTUnwrap(base64URLDecode(offer.qrText)), encoding: .utf8))
    XCTAssertTrue(decoded.contains("\"pairingCode\""))
  }

  func testPairingIsRefusedWhileTheGatewayIsClosed() throws {
    let service = try makeService(configuration: configuration(mode: .disabled))
    XCTAssertThrowsError(try service.createPairing(name: nil))
  }

  /// The address in a pairing payload is what the phone dials first, and a loopback address there
  /// is indistinguishable from a dead server: the phone resolves `127.0.0.1` to *itself* and
  /// reports "cannot connect to host". The plugin derives this value from the Web UI request's
  /// Host header, which is loopback for this app, so the trap is a real one to pin.
  func testPairingPayloadNeverPointsAtLoopback() throws {
    let service = try makeService(configuration: configuration(
      lanEnabled: true,
      lanAdvertiseHost: "10.134.71.45"
    ))
    let offer = try service.createPairing(name: "iPhone")
    let publicUrl = try XCTUnwrap(offer.payload["publicUrl"]?.stringValue)
    XCTAssertEqual(publicUrl, "ws://10.134.71.45:3081/ws/mobile")
    XCTAssertFalse(publicUrl.contains("127.0.0.1"))

    let endpoints = (offer.payload["endpoints"]?.arrayValue ?? []).compactMap { $0.stringValue }
    XCTAssertEqual(endpoints.first, publicUrl)
    XCTAssertFalse(endpoints.contains { $0.contains("127.0.0.1") })
    XCTAssertFalse(endpoints.contains { $0.contains("localhost") })
  }

  /// No reachable address means no usable code, so none is issued — better a clear refusal in the
  /// panel than a QR that can only fail on the phone.
  func testPairingRefusesWhenNothingIsReachable() throws {
    let service = try makeService(configuration: configuration(lanEnabled: false, endpoints: []))
    XCTAssertThrowsError(try service.createPairing(name: "iPhone")) { error in
      guard case MobileGatewayService.ServiceError.state(let message) = error else {
        return XCTFail("expected a state error, got \(error)")
      }
      XCTAssertTrue(message.contains("没有手机可到达的地址"), message)
    }
  }

  // MARK: - Mode machine

  func testDisablingClosesConnectionsWith4004() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })

    try service.setMode(.disabled)
    XCTAssertEqual(service.currentMode, .disabled)
    XCTAssertTrue(
      waitUntil { transport.closeCodes().contains(4004) },
      "expected a 4004 close, got \(transport.closeCodes())"
    )
  }

  func testTemporaryModeArmsAWaitWindowOnlyWithNoClients() throws {
    let service = try makeService(configuration: configuration(mode: .disabled))
    try service.setMode(.temporary)
    XCTAssertNotNil(service.status().waitExpiresAt)

    // With a connection open, the window is not armed: the first device is already here.
    let transport = RecordingTransport()
    connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    try service.setMode(.temporary)
    XCTAssertNil(service.status().waitExpiresAt)
  }

  func testTheSavedChoiceOutranksTheLaunchConfiguration() throws {
    let service = try makeService(configuration: configuration(mode: .persistent))
    XCTAssertEqual(service.currentMode, .persistent)
    try service.setMode(.disabled)

    // A restart with the same configuration must come back disabled: the user's choice is the
    // input, not the launch default.
    let restarted = try makeService(configuration: configuration(mode: .persistent))
    restarted.start()
    XCTAssertEqual(restarted.currentMode, .disabled)
    restarted.stop()
  }

  func testTurningAuthenticationOnDisconnectsUnauthenticatedSockets() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })

    try service.setRequireAuth(true)
    XCTAssertTrue(
      waitUntil { transport.closeCodes().contains(4003) },
      "expected a 4003 close, got \(transport.closeCodes())"
    )
  }

  // MARK: - Dispatch

  func testPingIsAnswered() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    let socket = connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    transport.reset()

    send(#"{"type":"ping"}"#, to: socket)
    let pong = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "pong" })
    XCTAssertNotNil(pong["at"]?.doubleValue)
  }

  func testInvalidJSONUsesTheLegacyFrameWithoutACode() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    let socket = connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    transport.reset()

    send("not json", to: socket)
    let frame = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "error" })
    XCTAssertEqual(frame["message"]?.stringValue, "invalid json")
    XCTAssertNil(frame["code"])
  }

  func testUnknownTypeReportsTheTypeWithoutACode() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    let socket = connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    transport.reset()

    send(#"{"type":"wat"}"#, to: socket)
    let frame = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "error" })
    XCTAssertEqual(frame["message"]?.stringValue, "unknown message type: wat")
    XCTAssertNil(frame["code"])
  }

  /// The two channels exist so one phone can hold a transcript and a control plane at once; a
  /// request on the wrong one must be told so rather than silently half-served.
  func testConversationVerbOnTheControlChannelIsRefused() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    let socket = connect(service, transport: transport, headers: ["x-dsh-channel": "control"])
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    transport.reset()

    send(#"{"type":"history","sessionId":"s-1"}"#, to: socket)
    let frame = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "error" })
    XCTAssertEqual(frame["code"]?.stringValue, "wrong-channel")
    XCTAssertEqual(frame["requestType"]?.stringValue, "history")
  }

  func testSubscribeConfirmsThePumpsSubscriptionIdentity() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    let socket = connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    transport.reset()

    send(#"{"type":"subscribe","sessionId":"session-1","assistantStream":true}"#, to: socket)
    let frame = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "subscribed" })
    XCTAssertEqual(frame["sessionId"]?.stringValue, "session-1")
    XCTAssertEqual(frame["assistantStream"]?.boolValue, true)
    XCTAssertFalse(frame["subscriptionId"]?.stringValue?.isEmpty ?? true)
  }

  func testAssistantStreamWithoutASessionIsRefused() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    let socket = connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    transport.reset()

    send(#"{"type":"subscribe","assistantStream":true}"#, to: socket)
    let frame = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "error" })
    XCTAssertEqual(frame["code"]?.stringValue, "bad-request")
    XCTAssertEqual(frame["message"]?.stringValue, "assistantStream requires a sessionId")
  }

  // MARK: - Human in the loop

  func testQuestionAnswerRequiresRpcIdAndSession() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    let socket = connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    transport.reset()

    send(#"{"type":"question-answer","rpcId":"r-1"}"#, to: socket)
    let frame = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "error" })
    XCTAssertEqual(frame["code"]?.stringValue, "bad-request")
    XCTAssertEqual(frame["message"]?.stringValue, "question-answer requires rpcId and sessionId")
  }

  /// Answering a request the host is no longer holding is a `not-pending` receipt, not an error:
  /// the phone raced a cancellation, and that is not a protocol violation.
  func testAnsweringAnUnknownQuestionIsNotPending() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    let socket = connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    transport.reset()

    send(#"{"type":"question-answer","rpcId":"r-1","sessionId":"s-1","answers":[]}"#, to: socket)
    let frame = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "question-response" })
    XCTAssertEqual(frame["accepted"]?.boolValue, false)
    XCTAssertEqual(frame["reason"]?.stringValue, "not-pending")
  }

  func testApprovalOutcomeIsValidated() throws {
    let service = try makeService()
    let transport = RecordingTransport()
    let socket = connect(service, transport: transport)
    XCTAssertNotNil(waitForFrame(in: transport) { $0["kind"]?.stringValue == "hello" })
    transport.reset()

    send(
      #"{"type":"approval-response","rpcId":"r-1","sessionId":"s-1","approvalId":"a-1","outcome":"maybe"}"#,
      to: socket
    )
    let frame = try XCTUnwrap(waitForFrame(in: transport) { $0["kind"]?.stringValue == "error" })
    XCTAssertEqual(frame["code"]?.stringValue, "bad-response")
    XCTAssertEqual(frame["message"]?.stringValue, "outcome must be allowed-once or rejected")
  }

  // MARK: - Wire encoding

  /// The encoder is the one boundary every frame crosses, so it must produce text the client can
  /// parse even for content that is awkward rather than illegal (astral emoji, a replacement
  /// character left by a host summary truncation).
  func testEncoderProducesParseableTextForAwkwardContent() throws {
    let awkward = "ok \u{FFFD} \u{1F600}\u{200D}\u{1F4BB} end"
    let text = MobileGatewayService.encode(.object(["kind": .string("event"), "text": .string(awkward)]))
    let parsed = try JSONValue.parse(text, context: "test")
    XCTAssertEqual(parsed["text"]?.stringValue, awkward)
    // Valid text is returned untouched: the boundary guard must not rewrite ordinary content.
    XCTAssertEqual(MobileGatewayService.sanitizeLoneSurrogates(awkward), awkward)
  }

  // MARK: - Helpers

  private func base64URLDecode(_ value: String) -> Data? {
    var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    return Data(base64Encoded: text)
  }

  /// Frames are delivered from a `Task`, so the assertion polls briefly instead of assuming a
  /// scheduling point.
  private func waitForFrame(
    in transport: RecordingTransport,
    timeout: TimeInterval = 3,
    _ predicate: (JSONValue) -> Bool
  ) -> JSONValue? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let match = transport.frames().first(where: predicate) { return match }
      usleep(5_000)
    }
    return transport.frames().first(where: predicate)
  }

  private func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return true }
      usleep(5_000)
    }
    return predicate()
  }
}

// MARK: - Doubles

/// Records everything the server sends, and decodes it back into frames so a test can assert on
/// the wire form rather than on internals.
final class RecordingTransport: MobileGatewayTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [Data] = []
  private var decodedFrames: [JSONValue] = []
  private var decodedCloseCodes: [UInt16] = []
  private var decodedBytes = 0
  /// Every opcode seen, in order. The frame list below keeps only text frames (the useful ones for
  /// assertions) and the close codes, so protocol pings need their own record.
  private var decodedOpcodes: [UInt8] = []
  private var skippedUpgradeResponse = false
  private(set) var didCancel = false

  func start() {}

  func send(_ data: Data) {
    lock.lock()
    sent.append(data)
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    didCancel = true
    lock.unlock()
  }

  func reset() {
    lock.lock()
    sent.removeAll()
    decodedFrames.removeAll()
    decodedCloseCodes.removeAll()
    decodedOpcodes.removeAll()
    decodedBytes = 0
    skippedUpgradeResponse = true // the upgrade already happened; keep framing from here
    lock.unlock()
  }

  /// Decode every complete server frame received so far. Server frames are unmasked, so this is
  /// a small reader rather than a general parser.
  ///
  /// The upgrade response arrives on this same transport as raw HTTP, so framing only starts
  /// after its header terminator — otherwise the reader would take `HTTP/1.1 101` for a frame
  /// header and desynchronise on every subsequent byte.
  private func decodeLocked() {
    var buffer = Data()
    for chunk in sent { buffer.append(chunk) }
    if !skippedUpgradeResponse {
      guard let terminator = Self.headerTerminator(in: buffer) else { return }
      skippedUpgradeResponse = true
      decodedBytes = terminator
    }
    var offset = decodedBytes
    while offset + 2 <= buffer.count {
      let first = buffer[offset]
      let opcode = first & 0x0F
      var length = Int(buffer[offset + 1] & 0x7F)
      var headerLength = 2
      if length == 126 {
        guard offset + 4 <= buffer.count else { break }
        length = Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
        headerLength = 4
      } else if length == 127 {
        guard offset + 10 <= buffer.count else { break }
        var value = 0
        for index in 0..<8 { value = value << 8 | Int(buffer[offset + 2 + index]) }
        length = value
        headerLength = 10
      }
      guard offset + headerLength + length <= buffer.count else { break }
      let payload = buffer.subdata(in: (offset + headerLength)..<(offset + headerLength + length))
      decodedOpcodes.append(opcode)
      if opcode == 0x8, payload.count >= 2 {
        decodedCloseCodes.append(UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]))
      }
      if opcode == 0x1, let text = String(data: payload, encoding: .utf8),
         let value = try? JSONValue.parse(text, context: "test") {
        decodedFrames.append(value)
      }
      offset += headerLength + length
      decodedBytes = offset
    }
  }

  /// Index just past the `\r\n\r\n` of the first HTTP header block, if it has arrived.
  private static func headerTerminator(in data: Data) -> Int? {
    let bytes = [UInt8](data)
    guard bytes.count >= 4 else { return nil }
    var index = 0
    while index + 3 < bytes.count {
      if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
        return index + 4
      }
      index += 1
    }
    return nil
  }

  func frames() -> [JSONValue] {
    lock.lock(); defer { lock.unlock() }
    decodeLocked()
    return decodedFrames
  }

  func closeCodes() -> [UInt16] {
    lock.lock(); defer { lock.unlock() }
    decodeLocked()
    return decodedCloseCodes
  }

  /// Whether the 101 response has been written. The upgrade is raw HTTP, not a frame, so it is
  /// tracked separately from the frame list.
  var didCompleteUpgrade: Bool {
    lock.lock(); defer { lock.unlock() }
    decodeLocked()
    return skippedUpgradeResponse
  }

  /// Whether a frame with this opcode has arrived (0x1 text, 0x8 close, 0x9 ping, 0xA pong).
  func hasFrame(withOpcode opcode: UInt8) -> Bool {
    lock.lock(); defer { lock.unlock() }
    decodeLocked()
    return decodedOpcodes.contains(opcode)
  }
}

/// A delegate that ignores everything: used by the tests that call the service's delegate methods
/// directly to assert a decision.
private final class NullDelegate: MobileGatewaySocketDelegate, @unchecked Sendable {
  func socket(
    _ socket: MobileGatewaySocketConnection,
    decideUpgrade request: WebSocketHandshakeRequest,
    isLoopback: Bool
  ) -> MobileGatewayUpgradeDecision {
    .reject(status: 500, code: "unused", message: "unused")
  }

  func socketDidUpgrade(_ socket: MobileGatewaySocketConnection) {}
  func socket(_ socket: MobileGatewaySocketConnection, didReceive frame: WebSocketFrame) {}
  func socketDidClose(_ socket: MobileGatewaySocketConnection, error: String?) {}
}

/// A host that answers nothing unless a test scripts it, so the gateway's own logic is what is
/// under test.
final class ScriptedRPC: MobileGatewayRPC, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [String: JSONValue] = [:]
  private(set) var invoked: [String] = []
  var hostVersion: String? { "0.1.6-alpha.1-test" }

  func script(_ endpoint: String, _ value: JSONValue) {
    lock.lock()
    responses[endpoint] = value
    lock.unlock()
  }

  func invoke(endpoint: String, args: JSONValue) async throws -> JSONValue {
    lock.lock()
    invoked.append(endpoint)
    let value = responses[endpoint]
    lock.unlock()
    guard let value else {
      throw MobileGatewayHostError(code: "internal", message: "no scripted response for \(endpoint)")
    }
    return value
  }

  func stream(endpoint: String, args: JSONValue) async throws -> AsyncThrowingStream<JSONValue, Error> {
    lock.lock()
    invoked.append(endpoint)
    let value = responses[endpoint]
    lock.unlock()
    guard let value else {
      throw MobileGatewayHostError(code: "internal", message: "no scripted stream for \(endpoint)")
    }
    return AsyncThrowingStream { continuation in
      continuation.yield(value)
      continuation.finish()
    }
  }

  /// An event feed that never finishes, so the gateway's reconnect loop is not what these tests
  /// are measuring.
  func events() async throws -> AsyncThrowingStream<MobileGatewayHostEvent, Error> {
    AsyncThrowingStream { _ in }
  }

  func answer(eventID: String, value: JSONValue) async throws {}
}
