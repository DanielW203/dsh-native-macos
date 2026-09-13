import Foundation
import XCTest
@testable import HarnessRuntime

/// The lookup order is the whole feature: the button has to find a checkout whose location
/// nobody promised, on a machine this app has never seen.
final class RebuildCheckoutTests: XCTestCase {
  private var sandbox: URL!

  override func setUpWithError() throws {
    sandbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("rebuild-checkout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
  }

  @discardableResult
  private func makeCheckout(at url: URL, project: Bool = true, manifest: Bool = true) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(at: url.appendingPathComponent("Tools", isDirectory: true), withIntermediateDirectories: true)
    try "#!/usr/bin/env bash\n".write(
      to: url.appendingPathComponent("Tools/build.sh"),
      atomically: true,
      encoding: .utf8
    )
    if project {
      try manager.createDirectory(
        at: url.appendingPathComponent("NativeHarness.xcodeproj", isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    if manifest {
      try "// swift-tools-version: 6.0\n".write(
        to: url.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
      )
    }
    return url
  }

  private func writeMarker(_ root: URL, pointingAt checkout: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try (checkout.path + "\n").write(
      to: root.appendingPathComponent(RebuildCheckoutLocator.markerFileName),
      atomically: true,
      encoding: .utf8
    )
  }

  // MARK: - Recognition

  func testRecognisesACheckoutWithAnXcodeProject() throws {
    let checkout = try makeCheckout(at: sandbox.appendingPathComponent("harness-native"), manifest: false)
    XCTAssertTrue(RebuildCheckout.looksLikeCheckout(checkout))
  }

  func testRecognisesACheckoutWithOnlyAPackageManifest() throws {
    let checkout = try makeCheckout(at: sandbox.appendingPathComponent("harness-native"), project: false)
    XCTAssertTrue(RebuildCheckout.looksLikeCheckout(checkout))
  }

  func testRejectsADirectoryWithoutBuildScript() throws {
    let directory = sandbox.appendingPathComponent("not-a-checkout", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    XCTAssertFalse(RebuildCheckout.looksLikeCheckout(directory))
  }

  func testRejectsABuildScriptWithoutAProjectDescription() throws {
    // A stray `build.sh` is common; a third project description is not a checkout this app
    // can build, and treating it as one would run somebody else's build.
    let directory = try makeCheckout(
      at: sandbox.appendingPathComponent("stray"),
      project: false,
      manifest: false
    )
    XCTAssertFalse(RebuildCheckout.looksLikeCheckout(directory))
  }

  // MARK: - Lookup order

  func testExplicitOverrideBeatsEverythingElse() throws {
    let remembered = try makeCheckout(at: sandbox.appendingPathComponent("documented"))
    let fromEnvironment = try makeCheckout(at: sandbox.appendingPathComponent("environment"))
    let found = RebuildCheckoutLocator.locate(
      userDefaultsRoot: remembered.path,
      environment: [RebuildCheckoutLocator.environmentKey: fromEnvironment.path],
      markerRoots: [],
      searchRoots: [],
      spotlight: false
    )
    XCTAssertEqual(found?.root.path, remembered.standardizedFileURL.path)
  }

  func testEnvironmentOverrideBeatsTheInstallMarker() throws {
    let fromEnvironment = try makeCheckout(at: sandbox.appendingPathComponent("environment"))
    let marked = try makeCheckout(at: sandbox.appendingPathComponent("marked"))
    let markerRoot = sandbox.appendingPathComponent("runtime", isDirectory: true)
    try writeMarker(markerRoot, pointingAt: marked)
    let found = RebuildCheckoutLocator.locate(
      userDefaultsRoot: nil,
      environment: [RebuildCheckoutLocator.environmentKey: fromEnvironment.path],
      markerRoots: [markerRoot],
      searchRoots: [],
      spotlight: false
    )
    XCTAssertEqual(found?.root.path, fromEnvironment.standardizedFileURL.path)
  }

  func testInstallMarkerIsUsedWithoutAnyConfiguration() throws {
    // The cross-machine case: a fresh app on a Mac whose checkout is somewhere this app's
    // search plan has never heard of. The only thing that can find it is the marker the
    // install wrote.
    let elsewhere = try makeCheckout(at: sandbox.appendingPathComponent("Volumes/External/work/harness-native"))
    let markerRoot = sandbox.appendingPathComponent("runtime", isDirectory: true)
    try writeMarker(markerRoot, pointingAt: elsewhere)
    let found = RebuildCheckoutLocator.locate(
      userDefaultsRoot: nil,
      environment: [:],
      markerRoots: [markerRoot],
      searchRoots: [],
      spotlight: false
    )
    XCTAssertEqual(found?.root.path, elsewhere.standardizedFileURL.path)
  }

  func testAStaleMarkerIsIgnoredRatherThanFatal() throws {
    let markerRoot = sandbox.appendingPathComponent("runtime", isDirectory: true)
    try writeMarker(markerRoot, pointingAt: sandbox.appendingPathComponent("deleted"))
    let real = try makeCheckout(at: sandbox.appendingPathComponent("found/search"))
    let found = RebuildCheckoutLocator.locate(
      userDefaultsRoot: nil,
      environment: [:],
      markerRoots: [markerRoot],
      searchRoots: [(sandbox, 2)],
      spotlight: false
    )
    XCTAssertEqual(found?.root.path, real.standardizedFileURL.path)
  }

  func testSearchFindsADeeplyNestedCheckout() throws {
    // A realistic shape: ~/Documents/<something>/harness-native.
    let thirdParty = try makeCheckout(at: sandbox.appendingPathComponent("Documents/my-project/harness-native"))
    let found = RebuildCheckoutLocator.locate(
      userDefaultsRoot: nil,
      environment: [:],
      markerRoots: [],
      searchRoots: [(sandbox.appendingPathComponent("Documents", isDirectory: true), 2)],
      spotlight: false
    )
    XCTAssertEqual(found?.root.path, thirdParty.standardizedFileURL.path)
  }

  func testSearchDoesNotDescendIntoHiddenOrHugeDirectories() throws {
    try makeCheckout(at: sandbox.appendingPathComponent("node_modules/harness-native"))
    try makeCheckout(at: sandbox.appendingPathComponent(".hidden/harness-native"))
    try makeCheckout(at: sandbox.appendingPathComponent("Library/harness-native"))
    let found = RebuildCheckoutLocator.locate(
      userDefaultsRoot: nil,
      environment: [:],
      markerRoots: [],
      searchRoots: [(sandbox, 3)],
      spotlight: false
    )
    XCTAssertNil(found)
  }

  func testNothingFoundIsNilRatherThanAnError() {
    let found = RebuildCheckoutLocator.locate(
      userDefaultsRoot: nil,
      environment: [:],
      markerRoots: [],
      searchRoots: [],
      spotlight: false
    )
    XCTAssertNil(found)
  }

  func testMarkerValueTrimsWhitespace() throws {
    let marker = sandbox.appendingPathComponent("rebuild-source-root")
    try "  /tmp/harness-native  \n".write(to: marker, atomically: true, encoding: .utf8)
    XCTAssertEqual(RebuildCheckoutLocator.markerValue(at: marker), "/tmp/harness-native")
    XCTAssertNil(RebuildCheckoutLocator.markerValue(at: sandbox.appendingPathComponent("absent")))
  }
}
