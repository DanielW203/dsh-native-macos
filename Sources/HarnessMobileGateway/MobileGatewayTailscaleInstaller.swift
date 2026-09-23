import Foundation

/// Getting Tailscale onto the Mac from inside the app.
///
/// What this deliberately does **not** do is install anything itself. Three paths exist, and the
/// honest ranking of them is:
///
/// 1. **Download the official package and hand it to Installer.app.** This is the default. The
///    package needs root, and macOS already has exactly the right prompt for that — driving it
///    ourselves would mean either asking for an administrator password in our own dialog (which
///    trains users to hand credentials to whichever app asks) or running Homebrew as root, which
///    breaks Homebrew's own file ownership and is unsupported.
/// 2. **The Mac App Store**, via a deep link that lands on Tailscale's page instead of a search
///    box. A third-party app cannot install an App Store app, and there is no private API worth
///    using to pretend otherwise.
/// 3. **Homebrew**, offered as a copyable command rather than something we execute, for the same
///    reason as (1): the cask's artifact is a `.pkg`.
///
/// Everything here is pure decision-making — where files live, which URL, whether a signature looks
/// right — so the parts that could be wrong are testable without installing anything.
public enum MobileGatewayTailscaleInstaller {
  /// Apple's identifier for Tailscale, confirmed against the App Store lookup API:
  /// `trackName: Tailscale`, `sellerName: Tailscale Inc.`, `bundleId: io.tailscale.ipn.macos`.
  public static let appStoreAppID = "1475387142"
  public static let appStoreDeepLink = "macappstore://apps.apple.com/app/id1475387142"
  public static let appStoreWebURL = "https://apps.apple.com/app/tailscale/id1475387142"
  public static let downloadPageURL = "https://tailscale.com/download/mac"

  /// The vendor's "latest" alias, which 302s to the current versioned package. Pinning a version
  /// here would hand out a stale installer the moment Tailscale ships.
  public static let standalonePackageURL = "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg"

  /// The cask is `tailscale-app`, **not** `tailscale`: the latter is the CLI-only formula, which
  /// installs no application and no system extension.
  public static let homebrewCommand = "brew install --cask tailscale-app"

  /// Where the downloaded installer is parked. The app's own cache is used rather than `~/Downloads`
  /// so that opening the installer does not require a Downloads-folder permission prompt.
  public static func packageDestination(caches: URL? = nil) -> URL {
    let base = caches
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("ai.deepseek.nativeharness.DSHNative", isDirectory: true)
      .appendingPathComponent("Tailscale-latest-macos.pkg", isDirectory: false)
  }

  public enum Method: String, Sendable, Equatable {
    case package
    case appStore
    case homebrew
  }

  public struct Plan: Sendable, Equatable {
    public var appInstalled: Bool
    public var brewPath: String?
    public var recommended: Method
    /// Whether a one-click path exists at all. Always true: the package download needs no
    /// preinstalled tooling.
    public var canInstallFromHere: Bool { true }
  }

  /// Look at the machine and decide what to offer.
  ///
  /// `brew` being present does not promote Homebrew to the recommendation — it only decides whether
  /// the command is worth showing.
  public static func plan(
    fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    appInstalled: Bool
  ) -> Plan {
    let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: fileExists)
    return Plan(
      appInstalled: appInstalled,
      brewPath: brew,
      recommended: appInstalled ? .package : .package
    )
  }

  public enum InstallError: Error, Equatable {
    case downloadFailed(String)
    case notAPackage(String)
    case signatureRejected(String)

    public var message: String {
      switch self {
      case .downloadFailed(let text): return "下载失败：\(text)"
      case .notAPackage(let text): return "下载到的文件不是安装包：\(text)"
      case .signatureRejected(let text): return "安装包签名校验未通过：\(text)"
      }
    }
  }

  /// Download the official package, checking as we go.
  ///
  /// A signed check runs before the file is handed to Installer.app. It is a sanity net rather than
  /// the real defence — Gatekeeper evaluates the package again when it is opened — but it means a
  /// hijacked download is rejected by us rather than depending on that second look.
  public static func downloadPackage(
    destination: URL = packageDestination(),
    verify: (URL) async -> String? = { await packageSignatureDescription($0) },
    onProgress: @Sendable (Double) -> Void = { _ in }
  ) async throws -> URL {
    var request = URLRequest(url: URL(string: standalonePackageURL)!)
    request.timeoutInterval = 30
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw InstallError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
    }
    let expected = max(http.expectedContentLength, 0)
    var data = Data()
    data.reserveCapacity(expected > 0 ? Int(expected) : 1 << 20)
    for try await byte in bytes {
      data.append(byte)
      if expected > 0 {
        onProgress(min(1, Double(data.count) / Double(expected)))
      }
    }
    guard data.count > 1_000_000 else {
      // A package this small is an error page or a truncated download, not an installer.
      throw InstallError.notAPackage("\(data.count) bytes")
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destination, options: .atomic)
    if let rejection = await verify(destination) {
      try? FileManager.default.removeItem(at: destination)
      throw InstallError.signatureRejected(rejection)
    }
    onProgress(1)
    return destination
  }

  /// `pkgutil --check-signature`, reduced to "is this plausibly Tailscale's installer".
  ///
  /// Returns `nil` when the package is acceptable, or the reason it is not. The vendor name is
  /// checked because a valid signature by *someone else* is not a reason to open an installer.
  public static func packageSignatureDescription(_ package: URL) async -> String? {
    let output = await runProcess("/usr/sbin/pkgutil", ["--check-signature", package.path])
    guard output.status == 0 else {
      return "pkgutil exited \(output.status)"
    }
    let text = String(decoding: output.stdout, as: UTF8.self)
    // Verified against the real thing: the tool prints
    // `Developer ID Installer: Tailscale Inc. (W5364U7YZB)` plus a notarization line. Requiring the
    // "Developer ID Installer:" prefix as well as the vendor name rejects a valid signature that
    // belongs to somebody else, without pinning the legal entity's exact spelling.
    guard text.contains("Developer ID Installer:"), text.contains("Tailscale") else {
      return "签名者不是 Tailscale 的 Developer ID Installer"
    }
    return nil
  }

  /// Run a helper and collect its output. Exposed so the signature check is testable.
  public static func runProcess(_ executable: String, _ arguments: [String]) async -> (status: Int32, stdout: Data) {
    await Task.detached(priority: .utility) { () -> (Int32, Data) in
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
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, data)
    }.value
  }
}
