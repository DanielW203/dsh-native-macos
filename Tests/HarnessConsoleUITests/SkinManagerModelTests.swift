import XCTest

@testable import HarnessConsoleUI

/// The part of the skin window that is plain logic: which installed plugins this window
/// replaces.
///
/// The list is a view, but "is the old manager still loading?" is a decision made from the
/// profile manifest — and getting it wrong is the difference between one owner of the
/// managed block and two.
final class SkinManagerModelTests: XCTestCase {
  private func makeProfile(dependencies: [String: String], bundles: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SkinManagerModelTests-\(UUID().uuidString)", isDirectory: true)
    let profile = root.appendingPathComponent("profiles/web", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let manifest: [String: Any] = [
      "name": "dsh-profile-web",
      "dependencies": dependencies,
      "dsh": ["profile": ["bundles": bundles]],
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
      .write(to: profile.appendingPathComponent("package.json"))
    return profile
  }

  @MainActor
  func testFindsTheReplacedManagerStillInTheBundleList() throws {
    let profile = try makeProfile(
      dependencies: ["dsh-skin-manager": "link:/tmp/skin-manager"],
      bundles: ["@deepseek-ai/dsh-base", "dsh-skin-manager"]
    )
    XCTAssertEqual(
      SkinManagerModel.legacyPlugins(inProfile: profile),
      [LegacySkinPlugin(name: "dsh-skin-manager", isEnabled: true)]
    )
  }

  /// Installed but switched off: still worth naming, because the dependency is what a user
  /// has to remove to be rid of it, and the window should not silently forget it.
  @MainActor
  func testFindsTheReplacedManagerInstalledButDisabled() throws {
    let profile = try makeProfile(
      dependencies: ["dsh-skin-manager": "0.1.7"],
      bundles: ["@deepseek-ai/dsh-base"]
    )
    XCTAssertEqual(
      SkinManagerModel.legacyPlugins(inProfile: profile),
      [LegacySkinPlugin(name: "dsh-skin-manager", isEnabled: false)]
    )
  }

  /// `dsh-skin` is a theme, not a manager: offering to disable it would be offering to
  /// disable the thing the window exists to manage.
  @MainActor
  func testDoesNotTreatASkinNamedLikeAManagerAsOne() throws {
    let profile = try makeProfile(
      dependencies: ["dsh-skin": "1.0.0", "dsh-skin-market": "0.1.51"],
      bundles: ["dsh-skin", "dsh-skin-market"]
    )
    XCTAssertTrue(SkinManagerModel.legacyPlugins(inProfile: profile).isEmpty)
  }

  @MainActor
  func testProfileWithoutAManifestYieldsNothing() throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("SkinManagerModelTests-missing-\(UUID().uuidString)", isDirectory: true)
    XCTAssertTrue(SkinManagerModel.legacyPlugins(inProfile: missing).isEmpty)
  }
}
