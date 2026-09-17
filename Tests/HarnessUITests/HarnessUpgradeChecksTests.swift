import Foundation
import HarnessIM
import HarnessKit
import HarnessRuntime
import XCTest

@testable import HarnessUI

/// The parts of the self-check that are decisions rather than plumbing.
///
/// What is deliberately *not* here: the checks that need a live harness. Those are covered by
/// the manual acceptance run against two installed releases, because faking a harness well
/// enough to test them would be testing the fake. What can be pinned down without one is
/// pinned down here — the timeout that stops a silent socket from hanging the suite, and the
/// tool-name judgement that is the whole reason the check exists.
final class HarnessUpgradeChecksTests: XCTestCase {

  // MARK: - Tool vocabulary

  /// The failure this check is for: the harness renames a tool, nothing throws, and the app
  /// quietly files it as "uncategorized".
  func testRenamedToolIsReportedAsUnrecognized() {
    let unknown = HarnessUpgradeChecks.unrecognizedToolNames(["read", "bash", "report"])
    XCTAssertEqual(unknown, ["report"])
  }

  func testKnownToolsAreAllRecognized() {
    let unknown = HarnessUpgradeChecks.unrecognizedToolNames([
      "read", "write", "edit", "glob", "grep", "bash", "todo_write",
      "subagent", "send_message", "job_list", "web_search", "memoir_read", "skill",
    ])
    XCTAssertTrue(unknown.isEmpty, "\(unknown)")
  }

  /// A renamed *mutating* tool is the dangerous half: `isMutatingTool` drives which calls get
  /// a confirmation, and a name it does not know stops being one.
  func testUnrecognizedNamesIncludeOnesTheMutationTableWouldMiss() {
    let names = ["report", "notify_user"]
    let unknown = HarnessUpgradeChecks.unrecognizedToolNames(names)
    XCTAssertEqual(unknown, names.sorted())
    for name in unknown {
      XCTAssertFalse(ToolDescriptor.isMutatingTool(name), "\(name) is already in the mutation table")
    }
  }

  func testEmptyAndDuplicateNamesAreCollapsed() {
    let unknown = HarnessUpgradeChecks.unrecognizedToolNames(["", "mystery", "mystery"])
    XCTAssertEqual(unknown, ["mystery"])
  }

  // MARK: - Stream timeout

  /// The reason `FrameWaiter` exists: a server that opens a socket and then says nothing would
  /// leave a plain `for await` suspended forever, and the check would hang instead of warning.
  func testWaitingOnASilentStreamTimesOut() async {
    let stream = AsyncThrowingStream<RemoteEventFrame, Error> { _ in
      // Never yields and never finishes.
    }
    let outcome = await FrameWaiter.waitForFrame(
      stream,
      seconds: 0.2,
      matching: { _ in true }
    )
    guard case .failure(let failure) = outcome else {
      return XCTFail("expected a timeout, got \(outcome)")
    }
    XCTAssertEqual(failure, .timedOut)
  }

  func testWaitingOnAStreamThatEndsIsReportedAsEndedNotAsATimeout() async {
    let stream = AsyncThrowingStream<RemoteEventFrame, Error> { continuation in
      continuation.finish()
    }
    let outcome = await FrameWaiter.waitForFrame(
      stream,
      seconds: 5,
      matching: { _ in true }
    )
    guard case .failure(let failure) = outcome else {
      return XCTFail("expected a failure, got \(outcome)")
    }
    // Different findings, because "slow" and "broken" call for different actions.
    XCTAssertEqual(failure, .ended)
  }

  func testAMatchingFrameWinsBeforeTheDeadline() async {
    let stream = AsyncThrowingStream<RemoteEventFrame, Error> { continuation in
      continuation.yield(.ready(clientID: "client-1"))
      continuation.finish()
    }
    let outcome = await FrameWaiter.waitForFrame(
      stream,
      seconds: 5,
      matching: { if case .ready = $0 { return true } else { return false } }
    )
    guard case .success(let frame) = outcome else {
      return XCTFail("expected the frame, got \(outcome)")
    }
    XCTAssertEqual(frame, .ready(clientID: "client-1"))
  }

  /// Non-matching frames are skipped rather than ending the wait: the mux interleaves streams,
  /// so the first frame on the socket is routinely not the one being waited for.
  func testUnrelatedFramesAreSkippedRatherThanFailingTheWait() async {
    let stream = AsyncThrowingStream<RemoteEventFrame, Error> { continuation in
      continuation.yield(.emit(event: "other", args: []))
      continuation.yield(.ready(clientID: "client-2"))
      continuation.finish()
    }
    let outcome = await FrameWaiter.waitForFrame(
      stream,
      seconds: 5,
      matching: { if case .ready = $0 { return true } else { return false } }
    )
    guard case .success(let frame) = outcome else {
      return XCTFail("expected the ready frame, got \(outcome)")
    }
    XCTAssertEqual(frame, .ready(clientID: "client-2"))
  }

  // MARK: - An unreachable harness

  /// A harness the app cannot even hand-shake with is unusable, so the suite collapses to one
  /// blocking failure instead of repeating the same error under seven names.
  func testAnUnparseableAddressYieldsExactlyOneBlockingFailure() async {
    let checks = await HarnessUpgradeChecks.make(
      announcedURL: "not a url",
      paths: RuntimePaths(root: FileManager.default.temporaryDirectory),
      profile: "web",
      activeReleaseID: nil
    )
    XCTAssertEqual(checks.count, 1)
    XCTAssertEqual(checks[0].name, "http-auth")
    XCTAssertTrue(checks[0].isBlocking)

    let result = await checks[0].run()
    XCTAssertEqual(result.verdict, .fail)
    XCTAssertTrue(result.isBlocking)
    XCTAssertFalse(result.detail.isEmpty)
  }

  /// Same collapse for an address with no launch token: `parse` rejects it, and a harness that
  /// cannot be authenticated is not one whose other checks mean anything.
  func testAnAddressWithoutATokenAlsoCollapses() async {
    let checks = await HarnessUpgradeChecks.make(
      announcedURL: "http://127.0.0.1:1/",
      paths: RuntimePaths(root: FileManager.default.temporaryDirectory),
      profile: "web",
      activeReleaseID: nil
    )
    XCTAssertEqual(checks.map(\.name), ["http-auth"])
    let result = await checks[0].run()
    XCTAssertEqual(result.verdict, .fail)
  }

  // MARK: - Report shape

  /// The verdicts a report is read by, including the one the asymmetry rule depends on.
  func testVerdictDisplayNamesCoverEveryCase() {
    for verdict in HarnessCheckResult.Verdict.allCases {
      XCTAssertFalse(verdict.displayName.isEmpty)
    }
    XCTAssertEqual(HarnessCheckResult.Verdict.warn.displayName, "降级")
    XCTAssertEqual(HarnessCheckResult.Verdict.skipped.displayName, "跳过")
  }
}
