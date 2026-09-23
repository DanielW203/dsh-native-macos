import Foundation
import XCTest

@testable import HarnessMobileGateway

/// What a gateway is allowed to advertise as a reachable address.
///
/// This is a security rule, not a formatting one: the upgrade carries the device token, so a
/// plaintext public address in a pairing payload is an invitation to put a long-lived credential
/// on the open internet.
final class MobileGatewayEndpointTests: XCTestCase {
  func testPlaintextPublicAddressIsRefused() {
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("ws://8.8.8.8:3081/ws/mobile"))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("ws://gateway.example.com/ws/mobile"))
  }

  /// The same address over TLS is exactly what remote access is supposed to look like.
  func testSecurePublicAddressIsAccepted() throws {
    XCTAssertEqual(
      try MobileGatewayConfiguration.normalizeEndpoint("wss://gateway.example.com/ws/mobile"),
      "wss://gateway.example.com/ws/mobile"
    )
    // TLS on a nonstandard port is normal for a tunnel or a reverse proxy.
    XCTAssertEqual(
      try MobileGatewayConfiguration.normalizeEndpoint("wss://gateway.example.com:8443/ws/mobile"),
      "wss://gateway.example.com:8443/ws/mobile"
    )
  }

  func testPlaintextPrivateAddressIsAccepted() throws {
    XCTAssertEqual(
      try MobileGatewayConfiguration.normalizeEndpoint("ws://10.134.71.45:3081/ws/mobile"),
      "ws://10.134.71.45:3081/ws/mobile"
    )
    XCTAssertEqual(
      try MobileGatewayConfiguration.normalizeEndpoint("ws://192.168.1.10:3081/ws/mobile"),
      "ws://192.168.1.10:3081/ws/mobile"
    )
  }

  /// A tailnet address is reachable over the internet, so treating `100.64.0.0/10` as local would
  /// wave through a plaintext public endpoint. It is deliberately *not* in the private set.
  func testTailnetAddressIsNotTreatedAsPrivate() {
    XCTAssertFalse(MobileGatewayConfiguration.isPrivateNetworkHost("100.101.102.103"))
    XCTAssertFalse(MobileGatewayConfiguration.isPrivateNetworkHost("100.64.0.1"))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("ws://100.101.102.103:3081/ws/mobile"))
    // With TLS it is fine — that is how a tailnet or tunnel deployment should be configured.
    XCTAssertNoThrow(try MobileGatewayConfiguration.normalizeEndpoint("wss://mac.tailnet.ts.net/ws/mobile"))
  }

  func testHttpSchemesAreNormalized() throws {
    XCTAssertEqual(
      try MobileGatewayConfiguration.normalizeEndpoint("http://10.0.0.5:3081/ws/mobile"),
      "ws://10.0.0.5:3081/ws/mobile"
    )
    XCTAssertEqual(
      try MobileGatewayConfiguration.normalizeEndpoint("https://gateway.example.com/ws/mobile"),
      "wss://gateway.example.com/ws/mobile"
    )
  }

  func testWildcardListenAddressIsRefused() {
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("ws://0.0.0.0:3081/ws/mobile"))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("wss://[::]/ws/mobile"))
  }

  /// Credentials, query parameters, and fragments are refused because a pairing payload is copied,
  /// photographed, and pasted — none of those survive that trip intact.
  func testCredentialsQueryAndFragmentAreRefused() {
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("wss://user:pw@gateway.example.com/ws/mobile"))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("wss://gateway.example.com/ws/mobile?token=abc"))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("wss://gateway.example.com/ws/mobile#frag"))
  }

  func testGarbageIsRefused() {
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint(""))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("   "))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("not a url"))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("ftp://gateway.example.com/ws/mobile"))
  }

  func testListIsBoundedAndDeduplicated() throws {
    let endpoints = try MobileGatewayConfiguration.normalizeEndpoints([
      "wss://gateway.example.com/ws/mobile",
      "https://gateway.example.com/ws/mobile",
      "ws://10.0.0.5:3081/ws/mobile",
    ])
    // The first two are the same address once normalized.
    XCTAssertEqual(endpoints, [
      "wss://gateway.example.com/ws/mobile",
      "ws://10.0.0.5:3081/ws/mobile",
    ])

    let tooMany = (0..<17).map { "ws://10.0.0.\($0):3081/ws/mobile" }
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoints(tooMany))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoints(["wss://ok.example.com/ws/mobile", " "]))
    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoints([String(repeating: "a", count: 2049)]))
  }

  /// The service validates at construction, so a bad endpoint fails the launch instead of being
  /// discovered later by looking at a QR code.
  func testServiceRefusesToStartWithAPlaintextPublicEndpoint() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-endpoint-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configuration = MobileGatewayConfiguration(
      gatewayName: "Test Gateway",
      gatewayMode: .persistent,
      lanEnabled: false,
      deviceFile: directory.appendingPathComponent("devices.json"),
      endpoints: ["ws://gateway.example.com/ws/mobile"]
    )
    XCTAssertThrowsError(try MobileGatewayService(configuration: configuration, rpc: ScriptedRPC()))
  }

  /// A configured public endpoint is what the pairing payload offers first when no LAN listener is
  /// running — and it must survive normalization intact.
  func testConfiguredPublicEndpointIsAdvertised() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-endpoint-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configuration = MobileGatewayConfiguration(
      gatewayName: "Test Gateway",
      gatewayMode: .persistent,
      lanEnabled: false,
      requireAuth: false,
      deviceFile: directory.appendingPathComponent("devices.json"),
      endpoints: ["https://gateway.example.com/ws/mobile"]
    )
    let service = try MobileGatewayService(configuration: configuration, rpc: ScriptedRPC())
    XCTAssertEqual(service.advertisedEndpoints(includeLAN: true), ["wss://gateway.example.com/ws/mobile"])

    let offer = try service.createPairing(name: "iPhone")
    XCTAssertEqual(offer.payload["publicUrl"]?.stringValue, "wss://gateway.example.com/ws/mobile")
  }
}
