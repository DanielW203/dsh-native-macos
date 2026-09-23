import Foundation
import XCTest

@testable import HarnessMobileGateway

/// Gateway identity is what makes one machine distinguishable from another in a phone's gateway
/// list, so the rules about when it may and may not change get their own tests.
final class MobileGatewayIdentityTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-identity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func stateFile() -> URL {
    directory.appendingPathComponent("devices.json.gateway.json")
  }

  func testCreatesAndReusesIdentity() throws {
    let first = try MobileGatewayIdentity(file: stateFile())
    XCTAssertTrue(MobileGatewayIdentity.isUUIDv4(first.gatewayID))
    XCTAssertNil(first.mode)

    let second = try MobileGatewayIdentity(file: stateFile())
    XCTAssertEqual(second.gatewayID, first.gatewayID)
  }

  func testPersistsAndClearsTheMode() throws {
    let identity = try MobileGatewayIdentity(file: stateFile())
    try identity.setMode(.temporary)
    XCTAssertEqual(try MobileGatewayIdentity(file: stateFile()).mode, .temporary)

    try identity.clearMode()
    XCTAssertNil(try MobileGatewayIdentity(file: stateFile()).mode)
    // The identity survives a mode change: revoking a choice must not re-identify the gateway.
    XCTAssertEqual(try MobileGatewayIdentity(file: stateFile()).gatewayID, identity.gatewayID)
  }

  /// A malformed identity file must fail the start. Minting a fresh `gatewayId` would orphan
  /// every phone that paired with this gateway, and the reason would be invisible.
  func testMalformedFileThrowsInsteadOfBeingReplaced() throws {
    try Data("{ not json".utf8).write(to: stateFile())
    XCTAssertThrowsError(try MobileGatewayIdentity(file: stateFile()))

    try Data(#"{"version":1,"gatewayId":"not-a-uuid","mode":null}"#.utf8).write(to: stateFile())
    XCTAssertThrowsError(try MobileGatewayIdentity(file: stateFile()))

    try Data(#"{"version":1,"gatewayId":"c98dfa65-a88b-401d-a8c2-693c0d067735","mode":"sometimes"}"#.utf8).write(to: stateFile())
    XCTAssertThrowsError(try MobileGatewayIdentity(file: stateFile()))
  }

  func testAdoptsThePluginWrittenFile() throws {
    let pluginFile = """
    {
      "version": 1,
      "gatewayId": "c98dfa65-a88b-401d-a8c2-693c0d067735",
      "mode": null
    }
    """
    try Data(pluginFile.utf8).write(to: stateFile())
    let identity = try MobileGatewayIdentity(file: stateFile())
    XCTAssertEqual(identity.gatewayID, "c98dfa65-a88b-401d-a8c2-693c0d067735")
    XCTAssertNil(identity.mode)
  }

  func testFileIsPrivate() throws {
    _ = try MobileGatewayIdentity(file: stateFile())
    let attributes = try FileManager.default.attributesOfItem(atPath: stateFile().path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }

  func testUUIDv4Validation() {
    XCTAssertTrue(MobileGatewayIdentity.isUUIDv4("c98dfa65-a88b-401d-a8c2-693c0d067735"))
    XCTAssertFalse(MobileGatewayIdentity.isUUIDv4("c98dfa65-a88b-101d-a8c2-693c0d067735")) // not version 4
    XCTAssertFalse(MobileGatewayIdentity.isUUIDv4("c98dfa65-a88b-401d-c8c2-693c0d067735")) // bad variant
    XCTAssertFalse(MobileGatewayIdentity.isUUIDv4("C98DFA65-A88B-401D-A8C2-693C0D067735")) // uppercase
    XCTAssertFalse(MobileGatewayIdentity.isUUIDv4("nope"))
  }
}

/// The configuration decides which files the gateway adopts and what it advertises, and both
/// have consequences the user cannot see until something breaks.
final class MobileGatewayConfigurationTests: XCTestCase {
  func testStandardPathsMatchThePluginLayout() {
    let home = URL(fileURLWithPath: "/Users/example")
    let configuration = MobileGatewayConfiguration.standard(home: home)
    XCTAssertEqual(
      configuration.deviceFile.path,
      "/Users/example/.dsh/mobile-gateway-devices.json"
    )
    XCTAssertEqual(
      configuration.stateFile.path,
      "/Users/example/.dsh/mobile-gateway-devices.json.gateway.json"
    )
  }

  func testGatewayNameFallsBackAndIsBounded() {
    let blank = MobileGatewayConfiguration(gatewayName: "   ", deviceFile: URL(fileURLWithPath: "/tmp/d.json"))
    XCTAssertFalse(blank.effectiveGatewayName.isEmpty)
    XCTAssertLessThanOrEqual(blank.effectiveGatewayName.count, 80)

    let long = MobileGatewayConfiguration(
      gatewayName: String(repeating: "x", count: 200),
      deviceFile: URL(fileURLWithPath: "/tmp/d.json")
    )
    XCTAssertEqual(long.effectiveGatewayName.count, 80)
  }

  /// The legacy boolean is honoured only when no explicit mode is configured, and `true` means
  /// persistent — the mapping the plugin documented.
  func testStartupModePrecedence() {
    let explicit = MobileGatewayConfiguration(
      gatewayName: "g", gatewayMode: .temporary, legacyGatewayEnabled: true,
      deviceFile: URL(fileURLWithPath: "/tmp/d.json")
    )
    XCTAssertEqual(explicit.configuredStartupMode, .temporary)

    let legacy = MobileGatewayConfiguration(
      gatewayName: "g", legacyGatewayEnabled: true, deviceFile: URL(fileURLWithPath: "/tmp/d.json")
    )
    XCTAssertEqual(legacy.configuredStartupMode, .persistent)

    let off = MobileGatewayConfiguration(
      gatewayName: "g", legacyGatewayEnabled: false, deviceFile: URL(fileURLWithPath: "/tmp/d.json")
    )
    XCTAssertEqual(off.configuredStartupMode, .disabled)

    let unset = MobileGatewayConfiguration(gatewayName: "g", deviceFile: URL(fileURLWithPath: "/tmp/d.json"))
    XCTAssertEqual(unset.configuredStartupMode, .disabled)
  }

  func testPrivateAddressClassification() {
    XCTAssertTrue(MobileGatewayService.isPrivateNetworkHostname("192.168.1.10"))
    XCTAssertTrue(MobileGatewayService.isPrivateNetworkHostname("10.0.0.5"))
    XCTAssertTrue(MobileGatewayService.isPrivateNetworkHostname("172.16.4.4"))
    XCTAssertTrue(MobileGatewayService.isPrivateNetworkHostname("172.31.0.1"))
    XCTAssertTrue(MobileGatewayService.isPrivateNetworkHostname("169.254.1.1"))
    XCTAssertTrue(MobileGatewayService.isPrivateNetworkHostname("127.0.0.1"))
    XCTAssertTrue(MobileGatewayService.isPrivateNetworkHostname("mac.local"))
    XCTAssertTrue(MobileGatewayService.isPrivateNetworkHostname("fd12:3456::1"))
    XCTAssertTrue(MobileGatewayService.isPrivateNetworkHostname("fe80::1"))

    // A public address must never be advertised as a LAN endpoint: a phone cannot reach it
    // without a TLS proxy, and offering it produces a connection that only times out.
    XCTAssertFalse(MobileGatewayService.isPrivateNetworkHostname("8.8.8.8"))
    XCTAssertFalse(MobileGatewayService.isPrivateNetworkHostname("172.32.0.1"))
    XCTAssertFalse(MobileGatewayService.isPrivateNetworkHostname("example.com"))
  }
}
