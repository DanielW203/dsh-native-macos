import Foundation
import HarnessKit
import XCTest

@testable import HarnessMobileGateway

/// Remote access through Tailscale.
///
/// The discovery call is a subprocess against a machine that may not have Tailscale at all, so the
/// parsing, the address choice, and the service's use of them are all asserted against fixtures
/// rather than against a live tailnet.
final class MobileGatewayTailscaleTests: XCTestCase {
  /// The shape `tailscale status --json` actually produces, trimmed to the fields that matter.
  private func statusJSON(
    backend: String = "Running",
    dnsName: String = "macbook-pro.tailnet-abc.ts.net.",
    ips: [String] = ["100.101.102.103", "fd7a:115c:a1e0::1"],
    tailnet: String = "tailnet-abc.ts.net"
  ) -> Data {
    let object: [String: Any] = [
      "Version": "1.60.0",
      "BackendState": backend,
      "Self": [
        "HostName": "macbook-pro",
        "DNSName": dnsName,
        "OS": "macOS",
        "TailscaleIPs": ips,
        "Online": true,
      ],
      "CurrentTailnet": ["Name": tailnet, "MagicDNSEnabled": true],
    ]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  // MARK: - Parsing

  func testParsesARunningTailnet() {
    let status = MobileGatewayTailscaleDiscovery.parseStatus(statusJSON())
    XCTAssertTrue(status.isRunning)
    // The trailing dot belongs to the FQDN form, not to a URL host.
    XCTAssertEqual(status.dnsName, "macbook-pro.tailnet-abc.ts.net")
    XCTAssertEqual(status.ipv4, "100.101.102.103")
    XCTAssertEqual(status.tailnet, "tailnet-abc.ts.net")
    XCTAssertEqual(status.preferredHost, "macbook-pro.tailnet-abc.ts.net")
  }

  /// A logged-out machine is the most common failure, and it must say so rather than read as
  /// "not installed" — the fix is different in each case.
  func testReportsLoggedOutDistinctly() {
    let status = MobileGatewayTailscaleDiscovery.parseStatus(statusJSON(backend: "NeedsLogin"))
    XCTAssertFalse(status.isRunning)
    guard case .notRunning(let reason) = status.state else { return XCTFail("expected notRunning") }
    XCTAssertTrue(reason.contains("登录"), reason)
  }

  func testReportsStopped() {
    let status = MobileGatewayTailscaleDiscovery.parseStatus(statusJSON(backend: "Stopped"))
    guard case .notRunning(let reason) = status.state else { return XCTFail("expected notRunning") }
    XCTAssertTrue(reason.contains("停止"), reason)
  }

  /// An IPv6-only tailnet still yields no `ws://` endpoint: this machine binds an IPv4 listener and
  /// the URL builder is not asked to guess at a bracketed literal.
  func testIPv6OnlyTailnetFallsBackToTheDNSName() {
    let status = MobileGatewayTailscaleDiscovery.parseStatus(statusJSON(ips: ["fd7a:115c:a1e0::1"]))
    XCTAssertNil(status.ipv4)
    XCTAssertEqual(status.preferredHost, "macbook-pro.tailnet-abc.ts.net")
  }

  func testGarbageStatusIsNotAFatalState() {
    let status = MobileGatewayTailscaleDiscovery.parseStatus(Data("not json".utf8))
    XCTAssertFalse(status.isRunning)
    guard case .notRunning = status.state else { return XCTFail("expected notRunning") }
  }

  // MARK: - Address construction

  func testEndpointPrefersTheMagicDNSName() {
    let status = MobileGatewayTailscaleDiscovery.parseStatus(statusJSON())
    XCTAssertEqual(
      MobileGatewayTailscaleDiscovery.endpoints(for: status, port: 3081, path: "/ws/mobile"),
      ["ws://macbook-pro.tailnet-abc.ts.net:3081/ws/mobile"]
    )
  }

  func testEndpointFallsBackToTheTailnetAddress() {
    let status = MobileGatewayTailscaleDiscovery.parseStatus(statusJSON(dnsName: ""))
    XCTAssertEqual(
      MobileGatewayTailscaleDiscovery.endpoints(for: status, port: 3081, path: "/ws/mobile"),
      ["ws://100.101.102.103:3081/ws/mobile"]
    )
  }

  func testNoEndpointWhenTailscaleIsDown() {
    let status = MobileGatewayTailscaleDiscovery.parseStatus(statusJSON(backend: "Stopped"))
    XCTAssertTrue(MobileGatewayTailscaleDiscovery.endpoints(for: status, port: 3081, path: "/ws/mobile").isEmpty)
  }

  /// The host is assembled from the CLI's own output, so it is re-checked before it can reach a
  /// URL: a status string carrying a slash or an `@` must not become a path or a credential.
  func testHostsThatCouldSmuggleAUrlAreRefused() {
    XCTAssertFalse(MobileGatewayTailscaleDiscovery.isSafeHost("evil/../path"))
    XCTAssertFalse(MobileGatewayTailscaleDiscovery.isSafeHost("user@host"))
    XCTAssertFalse(MobileGatewayTailscaleDiscovery.isSafeHost("host with space"))
    XCTAssertFalse(MobileGatewayTailscaleDiscovery.isSafeHost(""))
    XCTAssertTrue(MobileGatewayTailscaleDiscovery.isSafeHost("mac.tailnet.ts.net"))
    XCTAssertTrue(MobileGatewayTailscaleDiscovery.isSafeHost("100.101.102.103"))
  }

  // MARK: - Discovery

  func testMissingBinaryIsReportedAsNotInstalled() async {
    let discovery = MobileGatewayTailscaleDiscovery(
      candidatePaths: ["/nonexistent/tailscale"],
      runner: { _, _ in (0, Data()) }
    )
    let status = await discovery.discover()
    XCTAssertEqual(status.state, .notInstalled)
  }

  /// A non-zero exit is how the CLI reports "not logged in": the binary was found, so the answer is
  /// "installed but not usable", never "not installed".
  func testNonZeroExitIsNotRunningButKeepsTheBinaryPath() async {
    let discovery = MobileGatewayTailscaleDiscovery(
      candidatePaths: ["/bin/echo"],
      runner: { _, _ in (1, Data()) }
    )
    let status = await discovery.discover()
    guard case .notRunning = status.state else { return XCTFail("expected notRunning") }
    XCTAssertEqual(status.binaryPath, "/bin/echo")
  }

  func testDiscoveryParsesARealLookingStatus() async {
    let payload = statusJSON()
    let discovery = MobileGatewayTailscaleDiscovery(
      candidatePaths: ["/bin/echo"],
      runner: { _, arguments in
        XCTAssertEqual(arguments, ["status", "--json"])
        return (0, payload)
      }
    )
    let status = await discovery.discover()
    XCTAssertTrue(status.isRunning)
    XCTAssertEqual(status.binaryPath, "/bin/echo")
    XCTAssertEqual(status.ipv4, "100.101.102.103")
  }

  // MARK: - Service integration

  private func makeService(
    directory: URL,
    discovery: MobileGatewayTailscaleDiscovery,
    tailscaleEnabled: Bool = true
  ) throws -> MobileGatewayService {
    let configuration = MobileGatewayConfiguration(
      gatewayName: "Test Gateway",
      gatewayMode: .persistent,
      // No LAN listener: the point of this test is that the tailnet address alone can make the
      // gateway reachable from outside.
      lanEnabled: false,
      requireAuth: false,
      deviceFile: directory.appendingPathComponent("devices.json"),
      tailscaleEnabled: tailscaleEnabled
    )
    return try MobileGatewayService(configuration: configuration, rpc: ScriptedRPC(), tailscaleDiscovery: discovery)
  }

  func testRunningTailscaleAddsAnAdvertisedEndpoint() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-tailscale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload = statusJSON()
    let service = try makeService(
      directory: directory,
      discovery: MobileGatewayTailscaleDiscovery(candidatePaths: ["/bin/echo"], runner: { _, _ in (0, payload) })
    )
    await service.refreshTailscale()

    let status = service.status()
    XCTAssertTrue(status.tailscale.isRunning)
    XCTAssertEqual(status.tailscaleEndpoints, ["ws://macbook-pro.tailnet-abc.ts.net:3081/ws/mobile"])
    XCTAssertEqual(service.advertisedEndpoints(includeLAN: true), ["ws://macbook-pro.tailnet-abc.ts.net:3081/ws/mobile"])

    // The pairing payload must carry it: that is what makes remote access work from a QR alone.
    let offer = try service.createPairing(name: "iPhone")
    XCTAssertEqual(offer.payload["publicUrl"]?.stringValue, "ws://macbook-pro.tailnet-abc.ts.net:3081/ws/mobile")
  }

  /// Because the address is built from this machine's own status output rather than typed in, it is
  /// exempt from the "no plaintext public ws://" rule — the tunnel is already encrypted. The
  /// exemption must not extend to a hand-typed tailnet address, which is what the endpoint
  /// validator still refuses.
  func testTailnetAddressIsAllowedButATypedOneIsNot() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-tailscale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload = statusJSON()
    let service = try makeService(
      directory: directory,
      discovery: MobileGatewayTailscaleDiscovery(candidatePaths: ["/bin/echo"], runner: { _, _ in (0, payload) })
    )
    await service.refreshTailscale()
    XCTAssertFalse(service.advertisedEndpoints(includeLAN: true).isEmpty)

    XCTAssertThrowsError(try MobileGatewayConfiguration.normalizeEndpoint("ws://100.101.102.103:3081/ws/mobile"))
  }

  func testDisabledTailscaleAdvertisesNothing() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-tailscale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload = statusJSON()
    let service = try makeService(
      directory: directory,
      discovery: MobileGatewayTailscaleDiscovery(candidatePaths: ["/bin/echo"], runner: { _, _ in (0, payload) }),
      tailscaleEnabled: false
    )
    await service.refreshTailscale()
    XCTAssertFalse(service.status().tailscale.isRunning)
    XCTAssertTrue(service.advertisedEndpoints(includeLAN: true).isEmpty)
  }

  /// With no reachable address at all the gateway refuses to mint a code rather than hand out one
  /// that can only fail.
  func testNoPairingCodeWithoutAnyReachableAddress() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-gateway-tailscale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let service = try makeService(
      directory: directory,
      discovery: MobileGatewayTailscaleDiscovery(candidatePaths: ["/nonexistent/tailscale"], runner: { _, _ in (0, Data()) })
    )
    await service.refreshTailscale()
    XCTAssertThrowsError(try service.createPairing(name: "iPhone"))
  }
}
