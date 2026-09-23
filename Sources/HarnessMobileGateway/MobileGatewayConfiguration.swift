import Foundation

/// Everything the native gateway needs to know about where it lives and what it may do.
///
/// The defaults deliberately point at the *plugin's* files (`~/.dsh/mobile-gateway-devices.json`
/// and its `.gateway.json` sibling). That is not an accident of history: the identity and the
/// paired phones already live there, so the native gateway inherits them and a phone that was
/// paired against the JS gateway keeps working — with the same `gatewayId`, so one app can tell
/// this machine apart from another.
public struct MobileGatewayConfiguration: Sendable {
  /// Protocol constants the phone negotiates against.
  public static let protocolVersion = 3
  public static let historyFormatVersion = 3
  /// The DSH host this port is written against, reported in `hello` for the client's benefit.
  public static let dshVersion = "0.1.5-rc.2"

  /// Human-readable name; falls back to the hostname, capped at 80 characters because it is
  /// shown in the phone's gateway picker.
  public var gatewayName: String
  /// Startup mode from configuration. A saved UI choice outranks it.
  public var gatewayMode: MobileGatewayMode?
  /// `true` maps to `persistent`, anything else to `disabled` — the legacy key the plugin still
  /// honours.
  public var legacyGatewayEnabled: Bool?
  /// Interface the listener binds. `0.0.0.0` serves the LAN; `127.0.0.1` keeps it local.
  public var lanHost: String
  public var lanPort: UInt16
  public var lanEnabled: Bool
  /// Whether an unauthenticated connection is refused. Only ever relaxed for loopback peers —
  /// a LAN peer is authenticated or dropped, regardless of this switch.
  public var requireAuth: Bool
  /// How long a pairing QR code stays valid.
  public var pairingTTL: TimeInterval
  /// How long a `temporary` gateway waits for its first device before switching itself off.
  public var gatewayWaitTimeout: TimeInterval
  public var deviceFile: URL
  public var stateFile: URL
  /// Whether the `file-downloads` capability is advertised.
  public var fileDownloadsEnabled: Bool
  /// Extra reachable addresses advertised in the pairing payload (public WSS URLs, typically).
  public var endpoints: [String]
  /// Name advertised when `lanHost` is the wildcard: the machine's private LAN addresses are
  /// discovered and offered instead.
  public var lanAdvertiseHost: String?
  /// Whether a running Tailscale is discovered and its address advertised. On by default: it is
  /// the only remote path that needs neither a public port nor a certificate.
  public var tailscaleEnabled: Bool
  /// Explicit CLI path, for a Tailscale installed somewhere the default search does not cover.
  public var tailscaleBinary: String?
  /// How often to send a WebSocket protocol ping on an idle connection; 0 disables it.
  public var keepAliveInterval: TimeInterval

  public init(
    gatewayName: String,
    gatewayMode: MobileGatewayMode? = nil,
    legacyGatewayEnabled: Bool? = nil,
    lanHost: String = "0.0.0.0",
    lanPort: UInt16 = 3081,
    lanEnabled: Bool = true,
    requireAuth: Bool = true,
    pairingTTL: TimeInterval = 5 * 60,
    gatewayWaitTimeout: TimeInterval = 5 * 60,
    deviceFile: URL,
    stateFile: URL? = nil,
    fileDownloadsEnabled: Bool = true,
    endpoints: [String] = [],
    lanAdvertiseHost: String? = nil,
    tailscaleEnabled: Bool = true,
    tailscaleBinary: String? = nil,
    keepAliveInterval: TimeInterval = 30
  ) {
    self.gatewayName = gatewayName
    self.gatewayMode = gatewayMode
    self.legacyGatewayEnabled = legacyGatewayEnabled
    self.lanHost = lanHost
    self.lanPort = lanPort
    self.lanEnabled = lanEnabled
    self.requireAuth = requireAuth
    self.pairingTTL = pairingTTL
    self.gatewayWaitTimeout = gatewayWaitTimeout
    self.deviceFile = deviceFile
    self.stateFile = stateFile ?? URL(fileURLWithPath: deviceFile.path + ".gateway.json")
    self.fileDownloadsEnabled = fileDownloadsEnabled
    self.endpoints = endpoints
    self.lanAdvertiseHost = lanAdvertiseHost
    self.tailscaleEnabled = tailscaleEnabled
    self.tailscaleBinary = tailscaleBinary
    self.keepAliveInterval = keepAliveInterval
  }

  /// The default layout, matching the plugin's file locations under the real home directory.
  ///
  /// `_NSHomeDirectory()`-style paths are used rather than the app's private root on purpose:
  /// the device registry is not app data, it is the gateway's identity, and moving it would
  /// silently unpair every phone.
  public static func standard(home: URL? = nil) -> MobileGatewayConfiguration {
    let homeDirectory = home ?? FileManager.default.homeDirectoryForCurrentUser
    let deviceFile = homeDirectory
      .appendingPathComponent(".dsh", isDirectory: true)
      .appendingPathComponent("mobile-gateway-devices.json", isDirectory: false)
    return MobileGatewayConfiguration(
      gatewayName: MobileGatewayConfiguration.defaultGatewayName(),
      deviceFile: deviceFile
    )
  }

  /// The hostname, capped to the 80-character bound the protocol places on `gatewayName`.
  public static func defaultGatewayName() -> String {
    let name = ProcessInfo.processInfo.hostName
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "DSH" }
    return String(trimmed.prefix(80))
  }

  /// The name actually reported: configured value if non-blank, else the default.
  public var effectiveGatewayName: String {
    let trimmed = gatewayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? Self.defaultGatewayName() : String(trimmed.prefix(80))
  }

  /// The startup mode, resolved with the plugin's precedence:
  /// saved choice is applied later by the service; here the configured value wins over the
  /// legacy boolean.
  public var configuredStartupMode: MobileGatewayMode {
    if let gatewayMode { return gatewayMode }
    return legacyGatewayEnabled == true ? .persistent : .disabled
  }

  // MARK: - Reachability rules

  public enum EndpointError: Error, Equatable {
    case invalid(String)

    public var message: String {
      switch self {
      case .invalid(let text): return text
      }
    }
  }

  public static let maxEndpoints = 16
  public static let maxEndpointLength = 2048

  /// Normalize one advertised WebSocket address, refusing anything a phone could not reach
  /// *safely*.
  ///
  /// The `ws://`-only-on-a-private-LAN rule is the important one: the device token travels in the
  /// upgrade, so advertising a plaintext public address invites the phone to put a long-lived
  /// credential on the open internet. This mirrors the plugin's `normalizePublicUrl` so both
  /// halves of the system agree on what may be offered.
  public static func normalizeEndpoint(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maxEndpointLength else {
      throw EndpointError.invalid("endpoint must be a nonempty URL of at most \(maxEndpointLength) characters")
    }
    guard var components = URLComponents(string: trimmed), let rawScheme = components.scheme?.lowercased() else {
      throw EndpointError.invalid("invalid WebSocket endpoint URL: \(trimmed)")
    }
    switch rawScheme {
    case "https": components.scheme = "wss"
    case "http": components.scheme = "ws"
    case "ws", "wss": break
    default: throw EndpointError.invalid("endpoint must use ws:// or wss://: \(trimmed)")
    }
    guard components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil else {
      throw EndpointError.invalid("endpoint must not contain credentials, query parameters, or a fragment: \(trimmed)")
    }
    guard let host = components.host, !host.isEmpty else {
      throw EndpointError.invalid("invalid WebSocket endpoint URL: \(trimmed)")
    }
    // A wildcard listen address is not an address: a phone that dials it reaches nothing, and a
    // QR carrying one looks correct while being unusable.
    if host == "0.0.0.0" || host == "::" || host == "[::]" {
      throw EndpointError.invalid("endpoint must not use an unspecified listen address: \(trimmed)")
    }
    if components.scheme == "ws", !isPrivateNetworkHost(host) {
      throw EndpointError.invalid(
        "public endpoints must use wss:// (ws:// is allowed only for localhost and private LAN addresses): \(trimmed)"
      )
    }
    guard let url = components.url else {
      throw EndpointError.invalid("invalid WebSocket endpoint URL: \(trimmed)")
    }
    return url.absoluteString
  }

  /// Normalize a configured list: bounded, deduplicated, and in the order given.
  public static func normalizeEndpoints(_ values: [String]) throws -> [String] {
    guard values.count <= maxEndpoints,
          !values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
      throw EndpointError.invalid(
        "endpoints must hold at most \(maxEndpoints) nonempty URLs (\(maxEndpointLength) characters each)"
      )
    }
    var seen = Set<String>()
    return try values.map { try normalizeEndpoint($0) }.filter { seen.insert($0).inserted }
  }

  /// Loopback, link-local, and the private ranges a phone on the same network can reach.
  ///
  /// Note what is deliberately *not* here: `100.64.0.0/10`, the carrier-grade NAT block Tailscale
  /// hands out. A tailnet address is reachable over the internet, so a plaintext `ws://` to it
  /// must not be advertised as if it were local.
  public static func isPrivateNetworkHost(_ host: String) -> Bool {
    if host == "localhost" || host == "::1" { return true }
    if host.hasSuffix(".local") { return true }
    let lowered = host.lowercased()
    if lowered.hasPrefix("fc") || lowered.hasPrefix("fd") || lowered.hasPrefix("fe8") || lowered.hasPrefix("fe9")
      || lowered.hasPrefix("fea") || lowered.hasPrefix("feb") {
      return true
    }
    if lowered.hasPrefix("127.") { return true }
    let parts = lowered.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    let octets = parts.compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return false }
    if octets[0] == 10 { return true }
    if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
    if octets[0] == 192 && octets[1] == 168 { return true }
    if octets[0] == 169 && octets[1] == 254 { return true }
    return false
  }
}
