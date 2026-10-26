import Foundation
import XCTest

@testable import HarnessUI

/// The snapshot is the panel's whole contract. These tests pin what the panel shows for
/// each boot state without a window, a launcher, or a web view.
@MainActor
final class StartupSnapshotBuilderTests: XCTestCase {
  private func input(
    phase: HarnessWindowModel.Phase = .starting,
    logs: [String] = [],
    detail: String? = nil,
    pageReady: Bool = false,
    pageFailure: String? = nil,
    elapsed: TimeInterval = 3,
    needsNode: Bool = false,
    nodeStage: String? = nil,
    safeMode: Bool = false,
    isBusy: Bool = true
  ) -> StartupSnapshotInput {
    StartupSnapshotInput(
      phase: phase,
      logs: logs,
      detail: detail,
      pageReady: pageReady,
      pageFailure: pageFailure,
      elapsed: elapsed,
      needsNode: needsNode,
      nodeStage: nodeStage,
      safeMode: safeMode,
      isBusy: isBusy,
      reduceMotion: false
    )
  }

  func testPreparingAndStartingLabels() {
    let preparing = StartupSnapshotBuilder.make(input(phase: .stopped, isBusy: false))
    XCTAssertEqual(preparing.status, .preparing)
    XCTAssertEqual(preparing.statusLabel, "INITIALIZING")
    XCTAssertEqual(preparing.hint, "正在准备启动…")

    let starting = StartupSnapshotBuilder.make(input())
    XCTAssertEqual(starting.status, .starting)
    XCTAssertEqual(starting.statusLabel, "INITIALIZING")
    XCTAssertEqual(starting.hint, "正在启动 Harness…")
  }

  func testWaitingPageAndReady() {
    let waiting = StartupSnapshotBuilder.make(input(phase: .running, pageReady: false))
    XCTAssertEqual(waiting.status, .waitingPage)
    XCTAssertEqual(waiting.statusLabel, "LOADING UI")
    XCTAssertEqual(waiting.hint, "服务已就绪，正在加载页面…")

    let ready = StartupSnapshotBuilder.make(input(phase: .running, pageReady: true))
    XCTAssertEqual(ready.status, .ready)
    XCTAssertEqual(ready.statusLabel, "READY")
    XCTAssertTrue(ready.pageReady)
  }

  func testBootFailureActionsAndDetail() {
    let snapshot = StartupSnapshotBuilder.make(input(
      phase: .failed,
      detail: "The harness exited with code 1.\ntoken=SECRET",
      needsNode: false
    ))
    XCTAssertEqual(snapshot.status, .failedBoot)
    XCTAssertEqual(snapshot.statusLabel, "FAILED")
    XCTAssertEqual(snapshot.actions.map(\.id), [
      .retryBoot, .disablePlugins, .openRecovery, .continueAnyway,
    ])
    XCTAssertTrue(snapshot.detail?.contains("<redacted>") == true)
    XCTAssertFalse(snapshot.detail?.contains("SECRET") == true)
  }

  func testMissingNodeAddsInstallAction() {
    let snapshot = StartupSnapshotBuilder.make(input(phase: .failed, needsNode: true))
    XCTAssertTrue(snapshot.actions.contains { $0.id == .installNode })
  }

  func testPageFailureActions() {
    let snapshot = StartupSnapshotBuilder.make(input(
      phase: .running,
      pageReady: false,
      pageFailure: "The page did not load"
    ))
    XCTAssertEqual(snapshot.status, .failedPage)
    XCTAssertEqual(snapshot.actions.map(\.id), [.reloadPage, .openInBrowser, .continueAnyway])
    XCTAssertEqual(snapshot.detail, "The page did not load")
  }

  func testSlowBootHint() {
    let first = StartupSnapshotBuilder.make(input(elapsed: 19.9, isBusy: true))
    XCTAssertEqual(first.hint, "正在启动 Harness…")

    let slow = StartupSnapshotBuilder.make(input(elapsed: 20, isBusy: true))
    XCTAssertEqual(slow.hint, "首次启动会创建 profile，可能需要一会儿")
  }

  func testLogTailIsBounded() {
    let lines = (0..<30).map { "line \($0)" }
    let snapshot = StartupSnapshotBuilder.make(input(logs: lines))
    XCTAssertEqual(snapshot.logs.count, StartupSnapshotBuilder.maxLogRows)
    XCTAssertEqual(snapshot.logs.last?.text, "line 29")
  }

  func testInternalWindowLineIsFiltered() {
    let snapshot = StartupSnapshotBuilder.make(input(logs: [
      "window opened; workspace /tmp/x",
      "Booting the web profile…",
    ]))
    XCTAssertEqual(snapshot.logs.map(\.text), ["Booting the web profile…"])
  }

  func testHandoffPolicyRequiresReadyPageAndMinimumTime() {
    let notReady = StartupSnapshotBuilder.make(input(phase: .running, pageReady: false, elapsed: 5))
    XCTAssertFalse(StartupHandoffPolicy.shouldHandoff(notReady))

    let tooEarly = StartupSnapshotBuilder.make(input(phase: .running, pageReady: true, elapsed: 1.39))
    XCTAssertFalse(StartupHandoffPolicy.shouldHandoff(tooEarly))

    let ready = StartupSnapshotBuilder.make(input(phase: .running, pageReady: true, elapsed: 1.4))
    XCTAssertTrue(StartupHandoffPolicy.shouldHandoff(ready))

    let failed = StartupSnapshotBuilder.make(input(phase: .failed, pageReady: true, elapsed: 5))
    XCTAssertFalse(StartupHandoffPolicy.shouldHandoff(failed))
  }

  func testSnapshotEncodesTheFieldsThePanelReads() throws {
    let snapshot = StartupSnapshotBuilder.make(input(
      phase: .running,
      logs: ["Booting the web profile…"],
      pageReady: true,
      elapsed: 2.5,
      safeMode: true
    ))
    let object = snapshot.jsonObject
    XCTAssertEqual(object["status"] as? String, "ready")
    XCTAssertEqual(object["statusLabel"] as? String, "READY")
    XCTAssertEqual(object["pageReady"] as? Bool, true)
    XCTAssertEqual(object["safeMode"] as? Bool, true)
    let logs = object["logs"] as? [[String: Any]]
    XCTAssertEqual(logs?.count, 1)
    XCTAssertEqual(logs?.first?["badge"] as? String, "完成")
    let actions = object["actions"] as? [Any]
    XCTAssertEqual(actions?.count, 0)
  }
}
