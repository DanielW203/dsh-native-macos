import Foundation
import XCTest

@testable import HarnessMobileGateway

/// The registry is the only thing between a phone and the harness's tool surface, so the tests
/// here are about what it refuses as much as what it accepts.
final class MobileGatewayDeviceRegistryTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func registryFile() -> URL {
    directory.appendingPathComponent("mobile-gateway-devices.json")
  }

  func testPairThenAuthenticate() throws {
    let registry = try MobileGatewayDeviceRegistry(file: registryFile())
    let pairing = registry.createPairing(name: "iPhone")
    XCTAssertEqual(pairing.name, "iPhone")
    XCTAssertTrue(registry.hasPairing(code: pairing.code))

    let paired = try XCTUnwrap(registry.claimPairing(code: pairing.code, clientDeviceID: "ABCDEFGH12345678"))
    XCTAssertEqual(paired.device.name, "iPhone")
    XCTAssertEqual(registry.count(), 1)

    let authenticated = try XCTUnwrap(registry.authenticate(token: paired.token, clientDeviceID: "ABCDEFGH12345678"))
    XCTAssertEqual(authenticated.id, paired.device.id)
    XCTAssertEqual(registry.authenticate(token: "not-a-token", clientDeviceID: nil), nil)
  }

  /// A pairing code is single-use: a screenshot of the QR must not be a permanent credential.
  func testPairingCodeIsSingleUse() throws {
    let registry = try MobileGatewayDeviceRegistry(file: registryFile())
    let pairing = registry.createPairing(name: "iPhone")
    XCTAssertNotNil(registry.claimPairing(code: pairing.code, clientDeviceID: nil))
    XCTAssertFalse(registry.hasPairing(code: pairing.code))
    XCTAssertNil(registry.claimPairing(code: pairing.code, clientDeviceID: nil))
    XCTAssertEqual(registry.count(), 1)
  }

  func testPairingCodeExpires() throws {
    let registry = try MobileGatewayDeviceRegistry(file: registryFile(), pairingTTL: 0.01)
    let pairing = registry.createPairing(name: "iPhone")
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertFalse(registry.hasPairing(code: pairing.code))
    XCTAssertNil(registry.claimPairing(code: pairing.code, clientDeviceID: nil))
  }

  /// Re-pairing one installation must rotate its token, not add a second row: otherwise a phone
  /// that re-pairs after a reinstall fills the device list with ghosts.
  func testRepairRotatesTheExistingDevice() throws {
    let registry = try MobileGatewayDeviceRegistry(file: registryFile())
    let first = try XCTUnwrap(registry.claimPairing(
      code: registry.createPairing(name: "iPhone").code,
      clientDeviceID: "ABCDEFGH12345678"
    ))
    let second = try XCTUnwrap(registry.claimPairing(
      code: registry.createPairing(name: "iPhone 15").code,
      clientDeviceID: "ABCDEFGH12345678"
    ))
    XCTAssertEqual(registry.count(), 1)
    XCTAssertEqual(second.device.id, first.device.id)
    XCTAssertEqual(second.device.name, "iPhone 15")
    // The rotated token is the live one; the old one is dead.
    XCTAssertNotNil(registry.authenticate(token: second.token, clientDeviceID: nil))
    XCTAssertNil(registry.authenticate(token: first.token, clientDeviceID: nil))
  }

  func testRevokeRemovesTheDeviceAndItsToken() throws {
    let registry = try MobileGatewayDeviceRegistry(file: registryFile())
    let paired = try XCTUnwrap(registry.claimPairing(code: registry.createPairing(name: "iPhone").code, clientDeviceID: nil))
    XCTAssertTrue(registry.revoke(deviceID: paired.device.id))
    XCTAssertEqual(registry.count(), 0)
    XCTAssertNil(registry.authenticate(token: paired.token, clientDeviceID: nil))
    XCTAssertFalse(registry.revoke(deviceID: paired.device.id))
  }

  func testConnectionAccountingIsVisibleInTheList() throws {
    let registry = try MobileGatewayDeviceRegistry(file: registryFile())
    let paired = try XCTUnwrap(registry.claimPairing(code: registry.createPairing(name: "iPhone").code, clientDeviceID: nil))
    XCTAssertTrue(registry.connected(deviceID: paired.device.id))
    XCTAssertTrue(registry.connected(deviceID: paired.device.id))
    var device = try XCTUnwrap(registry.list().first)
    XCTAssertEqual(device.connections, 2)
    XCTAssertTrue(device.online)

    registry.disconnected(deviceID: paired.device.id)
    device = try XCTUnwrap(registry.list().first)
    XCTAssertEqual(device.connections, 1)
    registry.disconnected(deviceID: paired.device.id)
    device = try XCTUnwrap(registry.list().first)
    XCTAssertEqual(device.connections, 0)
    XCTAssertFalse(device.online)
  }

  /// Only digests are persisted. The plaintext token must never reach the disk.
  func testTokensArePersistedOnlyAsDigests() throws {
    let registry = try MobileGatewayDeviceRegistry(file: registryFile())
    let paired = try XCTUnwrap(registry.claimPairing(code: registry.createPairing(name: "iPhone").code, clientDeviceID: nil))
    let contents = try String(contentsOf: registryFile(), encoding: .utf8)
    XCTAssertFalse(contents.contains(paired.token))
    XCTAssertTrue(contents.contains(MobileGatewayDeviceRegistry.digest(paired.token)))

    let attributes = try FileManager.default.attributesOfItem(atPath: registryFile().path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }

  func testSurvivesAReload() throws {
    let token: String
    do {
      let registry = try MobileGatewayDeviceRegistry(file: registryFile())
      token = try XCTUnwrap(registry.claimPairing(code: registry.createPairing(name: "iPhone").code, clientDeviceID: nil)).token
    }
    let reopened = try MobileGatewayDeviceRegistry(file: registryFile())
    XCTAssertEqual(reopened.count(), 1)
    XCTAssertNotNil(reopened.authenticate(token: token, clientDeviceID: nil))
  }

  /// The v1 store wrote the token in plaintext; an upgrade must adopt it rather than unpair a
  /// working phone.
  func testMigratesThePlaintextTokenFormat() throws {
    let token = "legacy-token-value"
    let legacy = """
    {
      "version": 1,
      "devices": [
        { "id": "device-1", "name": "Old iPhone", "token": "\(token)", "createdAt": 1700000000000 }
      ]
    }
    """
    try Data(legacy.utf8).write(to: registryFile())
    let registry = try MobileGatewayDeviceRegistry(file: registryFile())
    XCTAssertEqual(registry.count(), 1)
    XCTAssertNotNil(registry.authenticate(token: token, clientDeviceID: nil))
    // The migration must rewrite the file in the digest-only format, and the plaintext token
    // must be gone from it.
    let contents = try String(contentsOf: registryFile(), encoding: .utf8)
    XCTAssertFalse(contents.contains(token))
    let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any])
    XCTAssertEqual(rewritten["version"] as? Int, 3)
    let rows = try XCTUnwrap(rewritten["devices"] as? [[String: Any]])
    XCTAssertEqual(rows.first?["tokenHash"] as? String, MobileGatewayDeviceRegistry.digest(token))
  }

  /// A corrupt registry must fail loudly. Silently starting empty would revoke every phone and
  /// destroy the evidence of why.
  func testCorruptRegistryThrows() throws {
    try Data("{ this is not json".utf8).write(to: registryFile())
    XCTAssertThrowsError(try MobileGatewayDeviceRegistry(file: registryFile()))
  }

  func testInstallationIDNormalization() {
    XCTAssertEqual(
      MobileGatewayDeviceRegistry.normalizeClientDeviceID("  ABCDEFGH12345678  "),
      "ABCDEFGH12345678"
    )
    XCTAssertNil(MobileGatewayDeviceRegistry.normalizeClientDeviceID("short"))
    XCTAssertNil(MobileGatewayDeviceRegistry.normalizeClientDeviceID("has spaces here"))
    XCTAssertNil(MobileGatewayDeviceRegistry.normalizeClientDeviceID(String(repeating: "a", count: 200)))
  }
}
