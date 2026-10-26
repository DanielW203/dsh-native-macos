import Foundation
import XCTest

@testable import HarnessUI

/// The launch experience's presentation rules: once per process, default on, custom video
/// wins, and a preview is always available.
@MainActor
final class StartupExperienceModelTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    suite = "StartupExperienceModelTests-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suite)
  }

  private func makeModel() -> StartupExperienceModel {
    StartupExperienceModel(defaults: defaults)
  }

  func testIsOnByDefault() {
    let model = makeModel()
    XCTAssertTrue(model.isEnabled)
    XCTAssertFalse(model.isPresenting)
    XCTAssertFalse(model.isPreview)
  }

  func testPresentsOncePerProcess() {
    let model = makeModel()
    model.presentAtLaunch(customVideoPlaying: false)
    XCTAssertTrue(model.isPresenting)
    XCTAssertFalse(model.isPreview)

    model.dismiss()
    model.presentAtLaunch(customVideoPlaying: false)
    XCTAssertFalse(model.isPresenting)
  }

  func testCustomVideoSuppressesTheBuiltInExperience() {
    let model = makeModel()
    model.presentAtLaunch(customVideoPlaying: true)
    XCTAssertFalse(model.isPresenting)

    // The launch decision is spent even though nothing was shown: a later window is not a
    // second launch.
    model.presentAtLaunch(customVideoPlaying: false)
    XCTAssertFalse(model.isPresenting)
  }

  func testDisabledSwitchSuppressesLaunchButNotPreview() {
    let model = makeModel()
    model.setEnabled(false)
    XCTAssertFalse(model.isEnabled)

    model.presentAtLaunch(customVideoPlaying: false)
    XCTAssertFalse(model.isPresenting)

    model.presentPreview()
    XCTAssertTrue(model.isPresenting)
    XCTAssertTrue(model.isPreview)
    model.dismiss()
    XCTAssertFalse(model.isPresenting)
    XCTAssertFalse(model.isPreview)
  }

  func testPreferencePersists() {
    let first = makeModel()
    first.setEnabled(false)

    let second = makeModel()
    XCTAssertFalse(second.isEnabled)

    second.setEnabled(true)
    let third = makeModel()
    XCTAssertTrue(third.isEnabled)
  }

  func testPreviewDoesNotConsumeTheLaunchDecision() {
    let model = makeModel()
    model.presentPreview()
    model.dismiss()

    model.presentAtLaunch(customVideoPlaying: false)
    XCTAssertTrue(model.isPresenting)
  }
}
