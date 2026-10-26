import Foundation
import XCTest

@testable import HarnessUI

/// The classifier only adds badges to known launch stages; the text itself always comes
/// from the real boot log.
final class StartupLogClassifierTests: XCTestCase {
  private let lines = [
    "Booting the web profile…",
    "Resolving the Node toolchain…",
    "Node v24.10.0 at /tmp/node",
    "Harness entry: /tmp/dsh",
    "Starting: node --profile web",
    "Waiting for the harness to announce its address (up to 120s)…",
    "harness is listening on port 51234",
    "Loading the harness page…",
  ]

  func testKnownStagesGetBadgesAndTheLastOneIsActive() {
    let rows = StartupLogClassifier.rows(
      from: lines,
      phase: .starting,
      pageReady: false,
      pageFailure: nil
    )
    XCTAssertEqual(rows.count, lines.count)
    XCTAssertEqual(rows.map(\.text), lines)
    XCTAssertEqual(rows.last?.state, .active)
    XCTAssertEqual(rows.last?.badge, "运行中")
    XCTAssertEqual(rows.first?.state, .done)
    XCTAssertEqual(rows.first?.badge, "完成")
  }

  func testPageReadyMarksEveryKnownStageDone() {
    let rows = StartupLogClassifier.rows(
      from: lines,
      phase: .running,
      pageReady: true,
      pageFailure: nil
    )
    XCTAssertTrue(rows.allSatisfy { $0.state == .done })
    XCTAssertTrue(rows.allSatisfy { $0.badge == "完成" })
  }

  func testFailureMarksTheLastKnownStageFailed() {
    let rows = StartupLogClassifier.rows(
      from: lines,
      phase: .failed,
      pageReady: false,
      pageFailure: nil
    )
    XCTAssertEqual(rows.last?.state, .failed)
    XCTAssertEqual(rows.last?.badge, "失败")
    XCTAssertEqual(rows.first?.state, .done)
  }

  func testUnknownLinesStayNeutral() {
    let rows = StartupLogClassifier.rows(
      from: ["some harness output", "another line"],
      phase: .starting,
      pageReady: false,
      pageFailure: nil
    )
    XCTAssertEqual(rows.map(\.state), [.neutral, .neutral])
    XCTAssertEqual(rows.compactMap(\.badge), [])
  }

  func testWindowOpenedNoiseIsDropped() {
    let rows = StartupLogClassifier.rows(
      from: ["window opened; workspace /tmp/x", "Booting the web profile…"],
      phase: .starting,
      pageReady: false,
      pageFailure: nil
    )
    XCTAssertEqual(rows.map(\.text), ["Booting the web profile…"])
  }

  func testIdsRemainStableWhenTheLogGrows() {
    let before = StartupLogClassifier.rows(
      from: ["Booting the web profile…"],
      phase: .starting,
      pageReady: false,
      pageFailure: nil
    )
    let after = StartupLogClassifier.rows(
      from: ["Booting the web profile…", "Resolving the Node toolchain…"],
      phase: .starting,
      pageReady: false,
      pageFailure: nil
    )
    XCTAssertEqual(before.first?.id, after.first?.id)
    XCTAssertNotEqual(after.first?.id, after.last?.id)
  }
}
