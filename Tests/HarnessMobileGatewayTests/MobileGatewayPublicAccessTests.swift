import Foundation
import XCTest

@testable import HarnessMobileGateway

/// Public access: a Cloudflare Tunnel, or any other TLS terminator the user already runs.
///
/// The gateway never starts the tunnel — that stays the user's decision and their terminal — so
/// what is asserted here is the join between the two halves: the address a hostname becomes, the
/// settings that survive a restart, and the keepalive that stops a proxy reaping an idle socket.
final class MobileGatewayPublicAccessTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-public-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: - Hostname to endpoint

  /// A tunnel hands the user a hostname, so a bare hostname has to be the accepted input.
  func testBareHostnameBecomesAWebSocketEndpoint() throws {
    XCTAssertEqual(
      try MobileGatewayCloudflare.endpoint(fromUserInput: "dsh.example.com"),
      "wss://dsh.example.com/ws/mobile"
    )
    XCTAssertEqual(
      try MobileGatewayCloudflare.endpoint(fromUserInput: "  dsh.example.com  "),
      "wss://dsh.example.com/ws/mobile"
    )
  }

  /// A pasted URL is also reasonable, and must not be double-wrapped.
  func testFullURLIsKeptAndNormalized() throws {
    XCTAssertEqual(
      try MobileGatewayCloudflare.endpoint(fromUserInput: "wss://dsh.example.com/ws/mobile"),
      "wss://dsh.example.com/ws/mobile"
    )
    XCTAssertEqual(
      try MobileGatewayCloudflare.endpoint(fromUserInput: "https://dsh.example.com/ws/mobile"),
      "wss://dsh.example.com/ws/mobile"
    )
  }

  /// A quick tunnel prints an https URL, which is what a user will paste.
  func testQuickTunnelStyleURLIsAccepted() throws {
    XCTAssertEqual(
      try MobileGatewayCloudflare.endpoint(fromUserInput: "https://calm-river-1234.trycloudflare.com"),
      "wss://calm-river-1234.trycloudflare.com/ws/mobile"
    )
    // cloudflared prints the host bare, with no path: the gateway's own path has to be filled in,
    // or the phone would dial `wss://host` and get a 404 from a listener waiting on `/ws/mobile`.
    XCTAssertEqual(
      try MobileGatewayCloudflare.endpoint(fromUserInput: "calm-river-1234.trycloudflare.com"),
      "wss://calm-river-1234.trycloudflare.com/ws/mobile"
    )
    // A deliberate path is preserved rather than overwritten.
    XCTAssertEqual(
      try MobileGatewayCloudflare.endpoint(fromUserInput: "wss://dsh.example.com/custom/ws/mobile"),
      "wss://dsh.example.com/custom/ws/mobile"
    )
  }

  /// The plaintext-public refusal applies here too, so a hostname cannot be entered as `ws://` and
  /// quietly put the device token on the open internet.
  func testPlaintextPublicInputIsRefused() {
    XCTAssertThrowsError(try MobileGatewayCloudflare.endpoint(fromUserInput: "ws://dsh.example.com/ws/mobile"))
    XCTAssertThrowsError(try MobileGatewayCloudflare.endpoint(fromUserInput: "http://dsh.example.com"))
    XCTAssertThrowsError(try MobileGatewayCloudflare.endpoint(fromUserInput: ""))
  }

  // MARK: - Settings persistence

  func testSettingsRoundTrip() throws {
    let store = MobileGatewaySettingsStore(file: directory.appendingPathComponent("settings.json"))
    XCTAssertTrue(store.load().publicEndpoints.isEmpty)

    var settings = store.load()
    settings.publicEndpoints = ["wss://dsh.example.com/ws/mobile"]
    settings.tailscaleEnabled = false
    settings.keepAliveInterval = 45
    try store.save(settings)

    let reloaded = MobileGatewaySettingsStore(file: store.fileURL).load()
    XCTAssertEqual(reloaded.publicEndpoints, ["wss://dsh.example.com/ws/mobile"])
    XCTAssertFalse(reloaded.tailscaleEnabled)
    XCTAssertEqual(reloaded.keepAliveInterval, 45)
  }

  /// Corrupt settings must not stop the gateway: nothing in this file is unrecoverable, and
  /// refusing to serve phones over a damaged list of URLs would be the worse outcome.
  func testCorruptSettingsFallBackToDefaults() throws {
    let file = directory.appendingPathComponent("settings.json")
    try Data("{ not json".utf8).write(to: file)
    let store = MobileGatewaySettingsStore(file: file)
    XCTAssertTrue(store.load().publicEndpoints.isEmpty)
    XCTAssertTrue(store.load().tailscaleEnabled)
  }

  // MARK: - Service

  private func makeService(endpoints: [String]) throws -> MobileGatewayService {
    let configuration = MobileGatewayConfiguration(
      gatewayName: "Test Gateway",
      gatewayMode: .persistent,
      lanEnabled: false,
      requireAuth: false,
      deviceFile: directory.appendingPathComponent("devices.json"),
      endpoints: endpoints
    )
    return try MobileGatewayService(configuration: configuration, rpc: ScriptedRPC())
  }

  /// The point of the whole feature: a tunnel hostname ends up in the pairing payload.
  func testTunnelHostnameReachesThePairingPayload() throws {
    let service = try makeService(endpoints: ["wss://dsh.example.com/ws/mobile"])
    XCTAssertEqual(service.advertisedEndpoints(includeLAN: true), ["wss://dsh.example.com/ws/mobile"])
    let offer = try service.createPairing(name: "iPhone")
    XCTAssertEqual(offer.payload["publicUrl"]?.stringValue, "wss://dsh.example.com/ws/mobile")
  }

  /// Updating in place keeps the listener bound, so configuring remote access does not drop the
  /// phone that is already connected.
  func testPublicEndpointsCanBeUpdatedWithoutRebuildingTheService() throws {
    let service = try makeService(endpoints: [])
    XCTAssertTrue(service.advertisedEndpoints(includeLAN: true).isEmpty)

    // The service layer takes complete endpoints; the panel's field is what adds the path.
    try service.updatePublicEndpoints(["https://dsh.example.com/ws/mobile"])
    XCTAssertEqual(service.advertisedEndpoints(includeLAN: true), ["wss://dsh.example.com/ws/mobile"])
    XCTAssertEqual(service.status().endpoints, ["wss://dsh.example.com/ws/mobile"])

    try service.updatePublicEndpoints([])
    XCTAssertTrue(service.advertisedEndpoints(includeLAN: true).isEmpty)
  }

  func testRuntimeUpdateStillRefusesAPlaintextPublicAddress() throws {
    let service = try makeService(endpoints: [])
    XCTAssertThrowsError(try service.updatePublicEndpoints(["ws://dsh.example.com/ws/mobile"]))
    XCTAssertTrue(service.advertisedEndpoints(includeLAN: true).isEmpty)
  }

  // MARK: - Cloudflare specifics

  func testCloudflareDetectionPrefersTheHomebrewPaths() {
    let detected = MobileGatewayCloudflare.detect(fileExists: { $0 == "/opt/homebrew/bin/cloudflared" })
    XCTAssertEqual(detected.binaryPath, "/opt/homebrew/bin/cloudflared")
    XCTAssertTrue(detected.isInstalled)

    let missing = MobileGatewayCloudflare.detect(fileExists: { _ in false })
    XCTAssertNil(missing.binaryPath)
    XCTAssertFalse(missing.isInstalled)
  }

  /// The commands are shown to the user verbatim, so they are pinned: a wrong flag here is a
  /// support burden that never shows up as a test failure anywhere else.
  func testCloudflareCommandsAreTheDocumentedOnes() {
    XCTAssertEqual(MobileGatewayCloudflare.installCommand, "brew install cloudflared")
    XCTAssertEqual(MobileGatewayCloudflare.quickTunnelCommand, "cloudflared tunnel --url http://127.0.0.1:3081")
    XCTAssertTrue(MobileGatewayCloudflare.loginCommand.hasPrefix("cloudflared tunnel login"))
    XCTAssertTrue(MobileGatewayCloudflare.routeCommand.contains("route dns"))
    XCTAssertTrue(MobileGatewayCloudflare.runTunnelCommand.hasSuffix("tunnel run dsh"))
  }

  // MARK: - Keepalive

  /// Cloudflare closes idle WebSockets and the iOS client sends nothing while it sits idle in the
  /// foreground, so the gateway has to be the one keeping the path open.
  func testIdleConnectionReceivesAProtocolPing() throws {
    let transport = RecordingTransport()
    let queue = DispatchQueue(label: "keepalive.test")
    // The connection holds its delegate weakly, exactly as it does in production — where the
    // listener's table is what keeps one alive. A temporary stub would deallocate before the
    // queued handshake ran, and the connection would close itself for want of a delegate.
    let delegate = ServiceStub()
    let socket = MobileGatewaySocketConnection(
      transport: transport,
      isLoopback: true,
      remoteDescription: "127.0.0.1:5000",
      delegate: delegate,
      queue: queue
    )
    socket.start()
    let request = "GET /ws/mobile HTTP/1.1\r\nHost: x\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
    socket.receive(Data(request.utf8))
    XCTAssertTrue(waitUntil { transport.didCompleteUpgrade }, "handshake did not complete")

    socket.sendPing()
    XCTAssertTrue(waitUntil { transport.hasFrame(withOpcode: 0x9) }, "no protocol ping was sent")
    withExtendedLifetime(delegate) {}
  }
}

private func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if predicate() { return true }
    usleep(5_000)
  }
  return predicate()
}

/// A delegate that accepts every upgrade and does nothing else.
private final class ServiceStub: MobileGatewaySocketDelegate, @unchecked Sendable {
  func socket(
    _ socket: MobileGatewaySocketConnection,
    decideUpgrade request: WebSocketHandshakeRequest,
    isLoopback: Bool
  ) -> MobileGatewayUpgradeDecision {
    .accept(subprotocol: "dsh-mobile-v1")
  }

  func socketDidUpgrade(_ socket: MobileGatewaySocketConnection) {}
  func socket(_ socket: MobileGatewaySocketConnection, didReceive frame: WebSocketFrame) {}
  func socketDidClose(_ socket: MobileGatewaySocketConnection, error: String?) {}
}
