import Foundation
import HarnessKit

/// Tailscale as the remote-access path for the mobile gateway.
///
/// The gateway itself only ever speaks plain `ws://`: it has no TLS of its own, and the protocol
/// requires `wss://` for anything a phone reaches over the public internet. A tailnet is the one
/// way to get remote access *without* standing up a TLS reverse proxy or exposing a port, because
/// Tailscale already carries every packet inside WireGuard.
///
/// That combination is why a tailnet address is allowed to keep the `ws://` scheme here, and the
/// exception is deliberately narrow: the address is **constructed from what this machine reports
/// about itself**, never parsed from a string a user or peer supplied, it is not routable from the
/// public internet, and the transport is encrypted end to end. The device token therefore never
/// crosses a network in the clear even though the URL scheme says `ws`.
public struct MobileGatewayTailscaleStatus: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    case notInstalled
    /// Installed but not usable — logged out, stopped, or starting.
    case notRunning(String)
    case running
  }

  public var state: State
  /// MagicDNS name without its trailing dot, e.g. `macbook-pro.tailnet.ts.net`.
  public var dnsName: String?
  public var ipv4: String?
  /// The tailnet's own name, for display so a user can tell two networks apart.
  public var tailnet: String?
  public var binaryPath: String?
  public var lastError: String?

  public init(
    state: State = .notInstalled,
    dnsName: String? = nil,
    ipv4: String? = nil,
    tailnet: String? = nil,
    binaryPath: String? = nil,
    lastError: String? = nil
  ) {
    self.state = state
    self.dnsName = dnsName
    self.ipv4 = ipv4
    self.tailnet = tailnet
    self.binaryPath = binaryPath
    self.lastError = lastError
  }

  public var isRunning: Bool { state == .running }

  /// The address a phone should dial. The MagicDNS name is preferred over the raw address: it
  /// survives the machine's tailnet address changing, and it is the name the user sees in the
  /// Tailscale app, so a mismatch is diagnosable.
  public var preferredHost: String? { dnsName ?? ipv4 }
}

/// Finds Tailscale and reports what it says about this machine.
///
/// The binary is looked for at fixed paths rather than through `PATH`: a GUI app launched from
/// Finder inherits a minimal environment, so `tailscale` is almost never on it, and a silent
/// "not installed" would be indistinguishable from a broken install.
public struct MobileGatewayTailscaleDiscovery: Sendable {
  public typealias Runner = @Sendable (_ executable: String, _ arguments: [String]) async -> (status: Int32, stdout: Data)

  /// Where the CLI lives, in the order worth trying: the standalone app bundle first (that is what
  /// installing Tailscale on macOS actually produces), then the two Homebrew prefixes.
  public static let candidatePaths = [
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/usr/local/bin/tailscale",
    "/opt/homebrew/bin/tailscale",
  ]

  private let candidatePaths: [String]
  private let overridePath: String?
  private let runner: Runner

  public init(
    candidatePaths: [String] = Self.candidatePaths,
    overridePath: String? = nil,
    runner: Runner? = nil
  ) {
    self.candidatePaths = candidatePaths
    self.overridePath = overridePath
    self.runner = runner ?? Self.runProcess
  }

  /// Locate and interrogate Tailscale. Never throws: "not installed" and "not running" are both
  /// ordinary states for the window to display, not errors to propagate.
  public func discover() async -> MobileGatewayTailscaleStatus {
    guard let binary = locate() else {
      return MobileGatewayTailscaleStatus(state: .notInstalled)
    }
    let result = await runner(binary, ["status", "--json"])
    guard result.status == 0, !result.stdout.isEmpty else {
      // A non-zero exit is how the CLI reports "not logged in" or "not running"; its stderr is
      // not captured here, so the state says what is true without inventing a reason.
      return MobileGatewayTailscaleStatus(
        state: .notRunning("Tailscale 未在运行或未登录"),
        binaryPath: binary
      )
    }
    var status = Self.parseStatus(result.stdout)
    status.binaryPath = binary
    return status
  }

  private func locate() -> String? {
    if let overridePath, FileManager.default.isExecutableFile(atPath: overridePath) { return overridePath }
    return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  // MARK: - Parsing

  /// Read `tailscale status --json`. Pure, so the window's behaviour on a logged-out machine or a
  /// renamed tailnet is a test rather than a hope.
  public static func parseStatus(_ data: Data) -> MobileGatewayTailscaleStatus {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return MobileGatewayTailscaleStatus(state: .notRunning("无法解析 Tailscale 状态"), lastError: "invalid status json")
    }
    let backend = root["BackendState"] as? String ?? ""
    let selfNode = root["Self"] as? [String: Any] ?? [:]
    // `DNSName` is reported FQDN-style with a trailing dot; a URL host must not carry it.
    let dnsName = (selfNode["DNSName"] as? String)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let addresses = selfNode["TailscaleIPs"] as? [String] ?? []
    let ipv4 = addresses.first { address in
      address.contains(".") && address.split(separator: ".").count == 4
    }
    let tailnet = (root["CurrentTailnet"] as? [String: Any])?["Name"] as? String

    guard backend == "Running" else {
      let reason: String
      switch backend {
      case "NeedsLogin": reason = "Tailscale 已安装，但还没有登录"
      case "Stopped": reason = "Tailscale 已停止"
      case "Starting": reason = "Tailscale 正在启动"
      case "": reason = "Tailscale 状态不可用"
      default: reason = "Tailscale 状态：\(backend)"
      }
      return MobileGatewayTailscaleStatus(
        state: .notRunning(reason),
        dnsName: dnsName?.isEmpty == true ? nil : dnsName,
        ipv4: ipv4,
        tailnet: tailnet
      )
    }
    return MobileGatewayTailscaleStatus(
      state: .running,
      dnsName: dnsName?.isEmpty == true ? nil : dnsName,
      ipv4: ipv4,
      tailnet: tailnet
    )
  }

  /// The endpoints a tailnet makes reachable, or none when Tailscale is not up.
  ///
  /// Built rather than parsed: the host comes from this machine's own status output and is
  /// re-checked against the character set a hostname may legally use, so a hostile or corrupted
  /// status string cannot smuggle a URL (or a path, or credentials) into a pairing payload.
  public static func endpoints(
    for status: MobileGatewayTailscaleStatus,
    port: UInt16,
    path: String
  ) -> [String] {
    guard status.isRunning, let host = status.preferredHost, isSafeHost(host) else { return [] }
    return ["ws://\(host):\(port)\(path)"]
  }

  /// Hosts are DNS labels or IP literals; anything else (a slash, an `@`, a colon, whitespace) is
  /// refused before it can reach a URL.
  static func isSafeHost(_ host: String) -> Bool {
    guard !host.isEmpty, host.count <= 253 else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
    return host.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  // MARK: - Default runner

  /// Run the CLI and read its stdout, with a watchdog so a wedged daemon cannot hang the window.
  public static let runProcess: Runner = { executable, arguments in
    await Task.detached(priority: .utility) { () -> (status: Int32, stdout: Data) in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()
      do {
        try process.run()
      } catch {
        return (-1, Data())
      }
      // `tailscale status` is normally instant; a daemon that never answers must not keep a
      // continuation alive forever.
      let watchdog = DispatchWorkItem { [weak process] in
        if process?.isRunning == true { process?.terminate() }
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      watchdog.cancel()
      return (process.terminationStatus, data)
    }.value
  }
}
