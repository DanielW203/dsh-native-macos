import Foundation
import XCTest

@testable import HarnessUI

/// The startup animation's rules: what gets copied where, when it plays, and what happens
/// when the file behind it disappears. Playback itself is AVFoundation's job; this asserts
/// the decisions around it.
@MainActor
final class StartupAnimationModelTests: XCTestCase {
  private var root: URL!
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("StartupAnimationModelTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { [root] in
      if let root { try? FileManager.default.removeItem(at: root) }
    }
    suite = "StartupAnimationModelTests-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  private func makeModel(
    validator: @escaping StartupAnimationModel.VideoValidator = { _ in true }
  ) -> StartupAnimationModel {
    StartupAnimationModel(root: root, defaults: defaults, validator: validator)
  }

  @discardableResult
  private func writeVideo(named name: String, in directory: URL? = nil) throws -> URL {
    let base: URL = directory ?? root
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let url = base.appendingPathComponent(name)
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
    return url
  }

  private func startupDirectory() -> URL {
    root.appendingPathComponent("startup", isDirectory: true)
  }

  func testChoosingAVideoCopiesItIntoTheAppTreeAndEnablesTheAnimation() async throws {
    let model = makeModel()
    let source = try writeVideo(named: "intro.mp4")

    try await model.chooseVideo(from: source)

    let copied = try XCTUnwrap(model.videoURL)
    XCTAssertEqual(copied.deletingLastPathComponent().standardizedFileURL, startupDirectory().standardizedFileURL)
    XCTAssertEqual(copied.lastPathComponent, "intro.mp4")
    XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    XCTAssertTrue(model.isEnabled)
    XCTAssertTrue(model.playsAtLaunch)
    XCTAssertEqual(defaults.string(forKey: StartupAnimationModel.Keys.videoFile), "intro.mp4")
    XCTAssertTrue(defaults.bool(forKey: StartupAnimationModel.Keys.isEnabled))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the source is copied, not moved")
  }

  func testChoosingASecondVideoReplacesTheFirstCopy() async throws {
    let model = makeModel()
    let first = try writeVideo(named: "intro.mp4")
    try await model.chooseVideo(from: first)
    let firstCopy = try XCTUnwrap(model.videoURL)

    let second = try writeVideo(named: "opening.mov")
    try await model.chooseVideo(from: second)

    let copied = try XCTUnwrap(model.videoURL)
    XCTAssertEqual(copied.lastPathComponent, "opening.mov")
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstCopy.path), "the old copy must not linger")
    let contents = try FileManager.default.contentsOfDirectory(atPath: startupDirectory().path)
    XCTAssertEqual(contents.count, 1, "one active video: \(contents)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
  }

  func testRejectedVideoKeepsThePreviousChoice() async throws {
    let source = try writeVideo(named: "good.mp4")
    let model = makeModel()
    try await model.chooseVideo(from: source)
    let accepted = try XCTUnwrap(model.videoURL)

    let other = try writeVideo(named: "broken.mp4")
    let rejecting = StartupAnimationModel(root: root, defaults: defaults, validator: { _ in false })
    do {
      try await rejecting.chooseVideo(from: other)
      XCTFail("a file the validator rejects must not be accepted")
    } catch let error as StartupAnimationModel.StartupVideoError {
      guard case .notPlayable = error else {
        return XCTFail("expected notPlayable, got \(error)")
      }
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    XCTAssertEqual(rejecting.videoURL?.standardizedFileURL, accepted.standardizedFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: accepted.path))
    let contents = try FileManager.default.contentsOfDirectory(atPath: startupDirectory().path)
    XCTAssertEqual(contents, ["good.mp4"])
  }

  func testPresentAtLaunchWithoutAVideoIsANoOp() {
    let model = makeModel()
    model.presentAtLaunch()
    XCTAssertFalse(model.isPresenting)
  }

  func testPresentAtLaunchPlaysOnlyOncePerProcess() async throws {
    let model = makeModel()
    try await model.chooseVideo(from: writeVideo(named: "intro.mp4"))
    model.presentAtLaunch()
    XCTAssertTrue(model.isPresenting)

    model.dismiss()
    model.presentAtLaunch()
    // The launch decision is spent once: re-showing the main window is not a second launch.
    XCTAssertFalse(model.isPresenting)
  }

  func testDisabledAnimationDoesNotPlayAtLaunch() async throws {
    let model = makeModel()
    try await model.chooseVideo(from: writeVideo(named: "intro.mp4"))
    model.setEnabled(false)

    model.presentAtLaunch()
    XCTAssertFalse(model.isPresenting)
    XCTAssertFalse(model.playsAtLaunch)
  }

  func testPreviewPlaysEvenWhenTheLaunchSwitchIsOff() async throws {
    let model = makeModel()
    try await model.chooseVideo(from: writeVideo(named: "intro.mp4"))
    model.setEnabled(false)

    model.presentPreview()
    XCTAssertTrue(model.isPresenting)
    model.dismiss()
    XCTAssertFalse(model.isPresenting)
  }

  func testRemovingTheVideoDeletesOnlyTheCopyAndClearsTheSettings() async throws {
    let model = makeModel()
    let source = try writeVideo(named: "intro.mp4")
    try await model.chooseVideo(from: source)
    let copied = try XCTUnwrap(model.videoURL)

    model.removeVideo()

    XCTAssertNil(model.videoURL)
    XCTAssertFalse(model.isEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertNil(defaults.string(forKey: StartupAnimationModel.Keys.videoFile))

    let reloaded = makeModel()
    XCTAssertNil(reloaded.videoURL)
    reloaded.presentAtLaunch()
    XCTAssertFalse(reloaded.isPresenting)
  }

  func testAVideoDeletedBehindTheModelsBackIsSilentlyIgnored() async throws {
    let model = makeModel()
    try await model.chooseVideo(from: writeVideo(named: "intro.mp4"))
    let copied = try XCTUnwrap(model.videoURL)
    try FileManager.default.removeItem(at: copied)

    let reloaded = makeModel()
    XCTAssertNil(reloaded.videoURL)
    reloaded.presentAtLaunch()
    XCTAssertFalse(reloaded.isPresenting)
  }

  func testAStaleDefaultPointingNowhereDoesNotPlay() throws {
    defaults.set("gone.mp4", forKey: StartupAnimationModel.Keys.videoFile)
    defaults.set(true, forKey: StartupAnimationModel.Keys.isEnabled)

    let model = makeModel()
    XCTAssertNil(model.videoURL)
    XCTAssertFalse(model.playsAtLaunch)
    model.presentAtLaunch()
    XCTAssertFalse(model.isPresenting)
  }
}
