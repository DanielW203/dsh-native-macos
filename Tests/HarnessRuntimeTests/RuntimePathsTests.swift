import Foundation
import XCTest
@testable import HarnessRuntime

/// Which root the app, `harnessctl`, and the console pick.
///
/// The decision has one job beyond "use the new default": an existing install that still
/// lives under Application Support must keep being used until it is migrated, because
/// silently switching to an empty `~/.nativeharness` would look like every release,
/// profile, and session was deleted.
final class RuntimePathsTests: XCTestCase {
  private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
  private let applicationSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support", isDirectory: true)

  private let homeRoot = "/Users/example/.nativeharness"
  private let legacyRoot = "/Users/example/Library/Application Support/NativeHarness"

  private func resolve(populated: Set<String>) -> String {
    RuntimePaths.resolveRoot(
      home: home,
      applicationSupport: applicationSupport,
      isPopulated: { populated.contains($0) }
    ).path
  }

  func testFreshInstallUsesTheHomeDirectoryRoot() {
    XCTAssertEqual(resolve(populated: []), homeRoot)
  }

  func testHomeRootWinsOnceItHoldsATree() {
    XCTAssertEqual(resolve(populated: [homeRoot]), homeRoot)
  }

  /// The upgrade path: nothing has been migrated yet, so the data that exists must win.
  func testUnmigratedInstallKeepsTheLegacyRoot() {
    XCTAssertEqual(resolve(populated: [legacyRoot]), legacyRoot)
  }

  func testBothRootsPopulatedPrefersHomeAndLeavesTheLegacyTreeAlone() {
    XCTAssertEqual(resolve(populated: [homeRoot, legacyRoot]), homeRoot)
  }

  /// A stray empty `~/.nativeharness` (mkdir, aborted experiment) must not shadow the
  /// tree the user actually has.
  func testEmptyHomeRootDoesNotShadowAPopulatedLegacyTree() {
    XCTAssertEqual(resolve(populated: [legacyRoot]), legacyRoot)
  }

  func testIsPopulatedRequiresATreeThisSubsystemOwns() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("runtime-paths-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    XCTAssertFalse(RuntimePaths.isPopulated(root: directory), "an empty directory is not an install")
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("home", isDirectory: true),
      withIntermediateDirectories: true
    )
    XCTAssertTrue(RuntimePaths.isPopulated(root: directory))
  }

  /// A machine where Application Support cannot be resolved must still get a root rather
  /// than a crash: the new default does not depend on it.
  func testMissingApplicationSupportStillResolvesTheHomeRoot() {
    let root = RuntimePaths.resolveRoot(home: home, applicationSupport: nil, isPopulated: { _ in false })
    XCTAssertEqual(root.path, homeRoot)
  }

  func testEnvironmentOverrideWins() throws {
    let paths = try RuntimePaths.standard(environment: ["NATIVE_HARNESS_ROOT": "/scratch/native-harness"])
    XCTAssertEqual(paths.root.path, "/scratch/native-harness")
  }

  /// Without an override the root is one of the two supported locations — never a
  /// third surprise under some other directory.
  func testStandardRootIsTheHomeRootOrTheLegacyRoot() throws {
    let paths = try RuntimePaths.standard(environment: [:])
    let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let candidates = [
      "\(homePath)/\(RuntimePaths.directoryName)",
      "\(homePath)/Library/Application Support/\(RuntimePaths.legacyDirectoryName)",
    ]
    XCTAssertTrue(candidates.contains(paths.root.path), "unexpected root: \(paths.root.path)")
  }

  func testLayoutUnderTheDefaultRoot() {
    let paths = RuntimePaths(root: home.appendingPathComponent(RuntimePaths.directoryName, isDirectory: true))
    XCTAssertEqual(paths.dshHome.path, "\(homeRoot)/home")
    XCTAssertEqual(paths.installsIndex.path, "\(homeRoot)/harness/installs.json")
    XCTAssertEqual(paths.profilesDirectory.path, "\(homeRoot)/home/profiles")
  }
}
