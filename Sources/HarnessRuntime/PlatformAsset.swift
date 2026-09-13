import Foundation

/// Which prebuilt harness asset belongs on this machine.
///
/// The repackaging repository publishes one archive per platform under a fixed naming
/// scheme. Getting this wrong is not a cosmetic failure — installing the x64 archive on
/// arm64 produces a runtime whose native modules refuse to load — so the mapping is a
/// pure function with its own tests rather than a string built at the call site.
public enum PlatformAsset {
  public struct Platform: Sendable, Equatable {
    public var os: String
    public var arch: String

    public init(os: String, arch: String) {
      self.os = os
      self.arch = arch
    }

    /// The host platform, normalized to the names used in asset filenames.
    public static var current: Platform {
      #if os(macOS)
      let os = "macos"
      #elseif os(Linux)
      let os = "linux"
      #else
      let os = "windows"
      #endif
      #if arch(arm64)
      let arch = "arm64"
      #else
      let arch = "x64"
      #endif
      return Platform(os: os, arch: arch)
    }
  }

  /// The asset filename for a platform, or `nil` when none is published for it.
  public static func assetName(for platform: Platform) -> String? {
    switch (platform.os, platform.arch) {
    case ("macos", "arm64"): return "deepseek-harness-pkg-macos-arm64.zip"
    case ("macos", "x64"): return "deepseek-harness-pkg-macos-x64.zip"
    case ("windows", _): return "deepseek-harness-pkg-windows.zip"
    case ("linux", _): return "deepseek-harness-pkg-linux.zip"
    default: return nil
    }
  }

  /// Pick the asset for this platform out of a release's asset list.
  public static func pick(from assets: [String], platform: Platform = .current) -> String? {
    guard let wanted = assetName(for: platform) else { return nil }
    return assets.first { $0 == wanted }
  }
}
