import Foundation

/// User-editable gateway settings that are not identity and not credentials.
///
/// Kept in its own file rather than folded into the identity state: the identity file is read by
/// the JS plugin too, and its schema is a contract with a second implementation. This one belongs
/// to the app alone, so it can grow without asking the plugin's permission.
///
/// What lives here is exactly the set of things a user changes from the panel — today the public
/// addresses a phone can reach this gateway on, which is how a Cloudflare Tunnel, a Caddy box, or
/// any other TLS terminator is registered.
public struct MobileGatewaySettings: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  /// Public `wss://…` addresses. Validated like any other advertised endpoint, so a plaintext
  /// public `ws://` cannot get in through this door either.
  public var publicEndpoints: [String]
  /// Whether Tailscale discovery is consulted.
  public var tailscaleEnabled: Bool
  /// Seconds between protocol-level pings on an idle connection; 0 disables.
  public var keepAliveInterval: TimeInterval

  public init(
    version: Int = MobileGatewaySettings.currentVersion,
    publicEndpoints: [String] = [],
    tailscaleEnabled: Bool = true,
    keepAliveInterval: TimeInterval = 30
  ) {
    self.version = version
    self.publicEndpoints = publicEndpoints
    self.tailscaleEnabled = tailscaleEnabled
    self.keepAliveInterval = keepAliveInterval
  }
}

/// Loads and saves `MobileGatewaySettings`.
///
/// A malformed settings file is treated as empty rather than fatal: unlike the identity or the
/// device registry, nothing here is unrecoverable, and refusing to start the gateway because a
/// list of URLs got corrupted would be a worse outcome than re-asking the user for them.
public final class MobileGatewaySettingsStore: @unchecked Sendable {
  public static func defaultFile(home: URL? = nil) -> URL {
    let homeDirectory = home ?? FileManager.default.homeDirectoryForCurrentUser
    return homeDirectory
      .appendingPathComponent(".dsh", isDirectory: true)
      .appendingPathComponent("mobile-gateway-settings.json", isDirectory: false)
  }

  private let file: URL
  private let lock = NSLock()

  public init(file: URL = MobileGatewaySettingsStore.defaultFile()) {
    self.file = file
  }

  public var fileURL: URL { file }

  public func load() -> MobileGatewaySettings {
    lock.lock(); defer { lock.unlock() }
    guard let data = try? Data(contentsOf: file),
          let settings = try? JSONDecoder().decode(MobileGatewaySettings.self, from: data),
          settings.version == MobileGatewaySettings.currentVersion else {
      return MobileGatewaySettings()
    }
    return settings
  }

  public func save(_ settings: MobileGatewaySettings) throws {
    lock.lock(); defer { lock.unlock() }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    var payload = try encoder.encode(settings)
    payload.append(0x0A)
    let temporary = file.deletingLastPathComponent()
      .appendingPathComponent("\(file.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
    try payload.write(to: temporary, options: .atomic)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
  }
}

/// Finding and describing a Cloudflare Tunnel, the recommended way to obtain a public `wss://`
/// address without opening a port.
///
/// The tunnel itself is deliberately not run by the app: a named tunnel is a long-lived daemon with
/// its own login and DNS routing, and a quick tunnel publishes an unauthenticated public URL whose
/// lifetime nobody controls. Both are the user's call, so what the panel does is detect the CLI,
/// hand over the exact commands, and then advertise whatever hostname the user brings back.
public enum MobileGatewayCloudflare {
  public static let candidatePaths = [
    "/opt/homebrew/bin/cloudflared",
    "/usr/local/bin/cloudflared",
    "/usr/bin/cloudflared",
  ]

  public static let installCommand = "brew install cloudflared"
  /// Makes a throwaway public URL on `trycloudflare.com`. Fine for a first end-to-end test; the
  /// address changes on every start and Cloudflare does not consider it production.
  public static let quickTunnelCommand = "cloudflared tunnel --url http://127.0.0.1:3081"
  public static let loginCommand = "cloudflared tunnel login"
  public static let createTunnelCommand = "cloudflared tunnel create dsh"
  /// Routes a hostname you own to the local gateway listener. The hostname is what goes in the
  /// panel's address field, as `wss://`.
  public static let routeCommand = "cloudflared tunnel route dns dsh dsh.example.com"
  public static let runTunnelCommand = "cloudflared tunnel run dsh"
  public static let docsURL = "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/"

  public struct Status: Sendable, Equatable {
    public var binaryPath: String?
    public var version: String?
    public var isInstalled: Bool { binaryPath != nil }
  }

  public static func detect(
    fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> Status {
    Status(binaryPath: candidatePaths.first(where: fileExists), version: nil)
  }

  /// Turn a hostname a user typed into the `wss://…/ws/mobile` endpoint to advertise.
  ///
  /// Accepts either a bare host (`dsh.example.com`) or a full URL, because both are reasonable
  /// things to paste after configuring a tunnel.
  public static func endpoint(fromUserInput raw: String, path: String = "/ws/mobile") throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw MobileGatewayConfiguration.EndpointError.invalid("请输入隧道域名")
    }
    var candidate = trimmed
    if !candidate.contains("://") { candidate = "wss://" + candidate }
    guard var components = URLComponents(string: candidate) else {
      throw MobileGatewayConfiguration.EndpointError.invalid("无法解析的地址：\(trimmed)")
    }
    // A tunnel hostname has no path, and Cloudflare forwards the path through to the listener — so
    // leaving it empty would send the phone to `wss://host` and get a 404 from the gateway that is
    // listening on `/ws/mobile`. The path is filled in rather than left to the user to remember.
    if components.path.isEmpty || components.path == "/" {
      components.path = path
    }
    guard let url = components.url else {
      throw MobileGatewayConfiguration.EndpointError.invalid("无法解析的地址：\(trimmed)")
    }
    return try MobileGatewayConfiguration.normalizeEndpoint(url.absoluteString)
  }
}
