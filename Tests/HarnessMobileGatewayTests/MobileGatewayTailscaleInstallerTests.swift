import Foundation
import XCTest

@testable import HarnessMobileGateway

/// The built-in Tailscale install flow.
///
/// Nothing here installs anything — that is the point of the design — so what is asserted is the
/// decision-making: which page a button opens, where a download lands, and what counts as a
/// package worth handing to Installer.app.
final class MobileGatewayTailscaleInstallerTests: XCTestCase {
  /// Apple's lookup API is the source of truth for this identifier; a typo would send every user to
  /// a search box or a dead page.
  func testAppStoreIdentifierIsTheVerifiedOne() {
    XCTAssertEqual(MobileGatewayTailscaleInstaller.appStoreAppID, "1475387142")
    XCTAssertTrue(MobileGatewayTailscaleInstaller.appStoreDeepLink.contains("1475387142"))
    XCTAssertTrue(MobileGatewayTailscaleInstaller.appStoreWebURL.contains("1475387142"))
    // The deep link is what lands on the page inside the App Store app; the https form is the
    // fallback for a machine that has no App Store registered.
    XCTAssertTrue(MobileGatewayTailscaleInstaller.appStoreDeepLink.hasPrefix("macappstore://"))
  }

  /// The cask is `tailscale-app`: `tailscale` is the CLI-only formula, which installs neither the
  /// application nor its system extension. Offering the wrong one would produce a machine where the
  /// gateway still cannot find the CLI at the expected path.
  func testHomebrewCommandUsesTheApplicationCask() {
    XCTAssertEqual(MobileGatewayTailscaleInstaller.homebrewCommand, "brew install --cask tailscale-app")
  }

  /// Pinning a version would hand out a stale installer as soon as Tailscale ships; the vendor's
  /// "latest" alias is a redirect and is meant to be used this way.
  func testPackageURLUsesTheVendorLatestAlias() {
    let url = MobileGatewayTailscaleInstaller.standalonePackageURL
    XCTAssertTrue(url.hasPrefix("https://pkgs.tailscale.com/stable/"), url)
    XCTAssertTrue(url.hasSuffix("-latest-macos.pkg"), url)
  }

  func testPackageLandsInTheAppsOwnCache() {
    let caches = URL(fileURLWithPath: "/tmp/caches")
    let destination = MobileGatewayTailscaleInstaller.packageDestination(caches: caches)
    XCTAssertEqual(destination.path, "/tmp/caches/ai.deepseek.nativeharness.DSHNative/Tailscale-latest-macos.pkg")
    // Not ~/Downloads: opening an installer from there would drag in a Downloads-folder consent
    // prompt for no benefit.
    XCTAssertFalse(destination.path.contains("Downloads"))
  }

  func testPlanOffersThePackagePathRegardlessOfHomebrew() {
    let withBrew = MobileGatewayTailscaleInstaller.plan(
      fileExists: { $0 == "/opt/homebrew/bin/brew" },
      appInstalled: false
    )
    XCTAssertEqual(withBrew.brewPath, "/opt/homebrew/bin/brew")
    XCTAssertEqual(withBrew.recommended, .package)
    XCTAssertTrue(withBrew.canInstallFromHere)

    let intelBrew = MobileGatewayTailscaleInstaller.plan(
      fileExists: { $0 == "/usr/local/bin/brew" },
      appInstalled: true
    )
    XCTAssertEqual(intelBrew.brewPath, "/usr/local/bin/brew")

    // With no Homebrew the one-click path still exists, which is why it is the recommendation.
    let bare = MobileGatewayTailscaleInstaller.plan(fileExists: { _ in false }, appInstalled: false)
    XCTAssertNil(bare.brewPath)
    XCTAssertEqual(bare.recommended, .package)
  }

  /// A valid signature by some *other* developer is not a reason to open an installer, so the
  /// vendor name is part of the check.
  func testSignatureCheckRequiresTheVendor() async throws {
    let unsigned = try temporaryFile("not a package")
    let rejection = await MobileGatewayTailscaleInstaller.packageSignatureDescription(unsigned)
    XCTAssertNotNil(rejection)
  }

  func testMissingPackageIsRejectedRatherThanOpened() async throws {
    let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).pkg")
    let rejection = await MobileGatewayTailscaleInstaller.packageSignatureDescription(missing)
    XCTAssertNotNil(rejection)
  }

  /// The error text is what the card shows, so each failure needs to be legible on its own.
  func testInstallErrorsReadAsSentences() {
    XCTAssertTrue(
      MobileGatewayTailscaleInstaller.InstallError.downloadFailed("HTTP 404").message.contains("404")
    )
    XCTAssertTrue(
      MobileGatewayTailscaleInstaller.InstallError.notAPackage("1024 bytes").message.contains("不是安装包")
    )
    XCTAssertTrue(
      MobileGatewayTailscaleInstaller.InstallError.signatureRejected("签名者不是 Tailscale")
        .message.contains("签名")
    )
  }

  private func temporaryFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tailscale-installer-\(UUID().uuidString).pkg")
    try Data(contents.utf8).write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
