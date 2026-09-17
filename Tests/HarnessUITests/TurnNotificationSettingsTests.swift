import Foundation
import HarnessKit
import XCTest

@testable import HarnessUI

/// The turn-notification switches and what they gate.
///
/// The model's `deliver` is the single place those decisions are made, so these tests call it
/// directly instead of standing up a watcher and a socket: what is under test is "which endings
/// reach the presenter", not "how does a frame get here" — that second question belongs to
/// `TurnCompletionWatcherTests`.
///
/// The master switch is the reason this file exists. A second notification path that ignores it
/// would be a switch that reads as off and behaves as on.
@MainActor
final class TurnNotificationSettingsTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    let suite = "TurnNotificationSettingsTests-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  private func makeModel(defaults: UserDefaults? = nil) -> (ApprovalAlertModel, RecordingApprovalPresenter) {
    let presenter = RecordingApprovalPresenter(authorization: .authorized)
    let model = ApprovalAlertModel(
      urlProvider: { nil },
      defaults: defaults ?? self.defaults,
      presenter: presenter
    )
    return (model, presenter)
  }

  private func completion(
    kind: TurnEndKind,
    isSubagent: Bool = false,
    turn: Int = 1
  ) -> TurnCompletion {
    TurnCompletion(
      sessionID: "session-1",
      sessionTitle: "Refactor",
      turn: turn,
      kind: kind,
      isSubagent: isSubagent
    )
  }

  // MARK: - Defaults

  /// Fresh install behaviour: completions and failures announced, subagent chatter not.
  func testDefaultsAnnounceTurnsButNotSubagents() {
    let (model, _) = makeModel()
    XCTAssertTrue(model.turnCompletionEnabled)
    XCTAssertTrue(model.turnFailureEnabled)
    XCTAssertFalse(model.subagentNotificationsEnabled)
    XCTAssertTrue(model.notificationsEnabled)
  }

  func testSwitchesPersistAcrossModels() async {
    let (first, _) = makeModel()
    first.turnCompletionEnabled = false
    first.turnFailureEnabled = false
    first.subagentNotificationsEnabled = true

    let (second, _) = makeModel()
    XCTAssertFalse(second.turnCompletionEnabled)
    XCTAssertFalse(second.turnFailureEnabled)
    XCTAssertTrue(second.subagentNotificationsEnabled)
  }

  // MARK: - Which endings are announced

  func testCompletedAndFailedTurnsAreAnnounced() async {
    let (model, presenter) = makeModel()
    await model.deliver(completion(kind: .completed, turn: 1))
    await model.deliver(completion(kind: .maxTokens, turn: 2))
    await model.deliver(completion(kind: .error, turn: 3))
    await model.deliver(completion(kind: .blocked, turn: 4))
    XCTAssertEqual(presenter.turnCompletions.map(\.kind), [.completed, .maxTokens, .error, .blocked])
  }

  /// The user's own stop, and a recovery artifact, are not news. Announcing them would be telling
  /// the user about their own button press, or about a crash the app already reported.
  func testAbortedInterruptedAndUnknownAreNeverAnnounced() async {
    let (model, presenter) = makeModel()
    await model.deliver(completion(kind: .aborted, turn: 1))
    await model.deliver(completion(kind: .interrupted, turn: 2))
    await model.deliver(completion(kind: .unknown, turn: 3))
    XCTAssertTrue(presenter.turnCompletions.isEmpty)
  }

  // MARK: - The switches

  func testMasterSwitchSilencesEverything() async {
    let (model, presenter) = makeModel()
    model.notificationsEnabled = false
    await model.deliver(completion(kind: .completed, turn: 1))
    await model.deliver(completion(kind: .error, turn: 2))
    XCTAssertTrue(presenter.turnCompletions.isEmpty,
                  "the master switch must gate the turn path too")
  }

  func testCompletionSwitchIsIndependentOfTheFailureSwitch() async {
    let (model, presenter) = makeModel()
    model.turnCompletionEnabled = false

    await model.deliver(completion(kind: .completed, turn: 1))
    await model.deliver(completion(kind: .maxTokens, turn: 2))
    XCTAssertTrue(presenter.turnCompletions.isEmpty, "completions are switched off")

    await model.deliver(completion(kind: .error, turn: 3))
    XCTAssertEqual(presenter.turnCompletions.map(\.kind), [.error],
                   "failures are still announced")
  }

  func testFailureSwitchIsIndependentOfTheCompletionSwitch() async {
    let (model, presenter) = makeModel()
    model.turnFailureEnabled = false

    await model.deliver(completion(kind: .error, turn: 1))
    await model.deliver(completion(kind: .blocked, turn: 2))
    XCTAssertTrue(presenter.turnCompletions.isEmpty, "failures are switched off")

    await model.deliver(completion(kind: .completed, turn: 3))
    XCTAssertEqual(presenter.turnCompletions.map(\.kind), [.completed])
  }

  // MARK: - Subagents

  /// A parent turn that spawns three subagents would otherwise produce three extra notifications.
  func testSubagentEndingsAreSilentWhileTheSwitchIsOff() async {
    let (model, presenter) = makeModel()
    await model.deliver(completion(kind: .completed, isSubagent: true, turn: 1))
    await model.deliver(completion(kind: .error, isSubagent: true, turn: 2))
    XCTAssertTrue(presenter.turnCompletions.isEmpty)
  }

  func testSubagentEndingsArriveWhenTheSwitchIsOn() async {
    let (model, presenter) = makeModel()
    model.subagentNotificationsEnabled = true
    await model.deliver(completion(kind: .completed, isSubagent: true, turn: 1))
    XCTAssertEqual(presenter.turnCompletions.count, 1)
    XCTAssertTrue(presenter.turnCompletions[0].isSubagent)
  }

  /// The subagent switch is a filter, not an override: it still respects the kind switches and the
  /// master switch.
  func testSubagentSwitchStillObeysTheKindSwitches() async {
    let (model, presenter) = makeModel()
    model.subagentNotificationsEnabled = true
    model.turnCompletionEnabled = false
    await model.deliver(completion(kind: .completed, isSubagent: true, turn: 1))
    XCTAssertTrue(presenter.turnCompletions.isEmpty)

    model.notificationsEnabled = false
    model.turnFailureEnabled = true
    await model.deliver(completion(kind: .error, isSubagent: true, turn: 2))
    XCTAssertTrue(presenter.turnCompletions.isEmpty)
  }

  // MARK: - The notification's text

  func testPostedTurnNotificationNamesTheOutcome() {
    XCTAssertEqual(SystemApprovalPresenter.title(for: completion(kind: .completed)), "轮次完成")
    XCTAssertEqual(SystemApprovalPresenter.title(for: completion(kind: .maxTokens)), "轮次结束（达到 token 上限）")
    XCTAssertEqual(SystemApprovalPresenter.title(for: completion(kind: .error)), "轮次失败")
    XCTAssertEqual(SystemApprovalPresenter.title(for: completion(kind: .blocked)), "轮次被阻断")
  }

  func testNotificationBodyPrefersTheFailureMessageThenTheTurn() {
    var failed = completion(kind: .error, turn: 7)
    failed.failureCode = "RATE_LIMITED"
    failed.failureMessage = "slow down"
    XCTAssertEqual(SystemApprovalPresenter.body(for: failed), "[RATE_LIMITED] slow down")

    var coded = completion(kind: .error, turn: 7)
    coded.failureCode = "RATE_LIMITED"
    XCTAssertEqual(SystemApprovalPresenter.body(for: coded), "RATE_LIMITED")

    XCTAssertEqual(SystemApprovalPresenter.body(for: completion(kind: .completed, turn: 7)), "第 7 轮")
    XCTAssertEqual(SystemApprovalPresenter.body(for: completion(kind: .completed, turn: 0)), "第 0 轮")
  }

  /// Each turn is its own piece of news, so several in a row stack rather than replacing one another.
  func testNotificationIdentifiersDistinguishTurnsWithinASession() {
    let first = SystemApprovalPresenter.turnNotificationIdentifier(for: completion(kind: .completed, turn: 1))
    let second = SystemApprovalPresenter.turnNotificationIdentifier(for: completion(kind: .completed, turn: 2))
    XCTAssertNotEqual(first, second)
    XCTAssertTrue(first.contains("session-1"), first)

    // A turn number the harness did not give collapses to one slot, which is correct: there is
    // nothing to tell two such endings apart by.
    var anonymous = completion(kind: .unknown)
    anonymous.turn = nil
    XCTAssertTrue(
      SystemApprovalPresenter.turnNotificationIdentifier(for: anonymous).hasSuffix(".unknown")
    )
  }

  /// The turn category carries no actions: a report must not present Approve/Reject.
  func testTurnCategoryIsSeparateFromApprovals() {
    XCTAssertNotEqual(
      SystemApprovalPresenter.categoryIdentifier,
      SystemApprovalPresenter.turnCategoryIdentifier
    )
  }

  // MARK: - Watch state

  func testWatchStateLabels() {
    XCTAssertNil(TurnWatchState.idle.label)
    XCTAssertEqual(TurnWatchState.watching.label, "轮次通知已就绪")
    XCTAssertEqual(TurnWatchState.note("nope").label, "nope")
  }

  // MARK: - No connection

  /// With no harness there is nothing to follow, and the footer must not imply otherwise. The
  /// sessions themselves are read from the harness on a poll, so there is no caller-supplied list
  /// that could be followed before the connection exists.
  func testNothingIsWatchedWithoutAConnection() {
    let (model, _) = makeModel()
    XCTAssertEqual(model.turnWatch, .idle)
    XCTAssertNil(model.turnWatch.label)
  }

  // MARK: - Forwarding to the phone

  /// Records what the phone was told, so the forwarding decision is assertable without a channel,
  /// a bot, or a socket.
  private actor RecordingPhoneForwarder: PhoneInfoForwarding {
    private(set) var forwarded: [TurnCompletion] = []
    func forwardTurn(_ completion: TurnCompletion) async {
      forwarded.append(completion)
    }
  }

  /// The same ending that produces a notification is offered to the phone.
  func testTurnEndingsAreForwardedToThePhone() async {
    let (model, _) = makeModel()
    let forwarder = RecordingPhoneForwarder()
    model.phoneForwarder = forwarder

    await model.deliver(completion(kind: .completed, turn: 1))
    await model.deliver(completion(kind: .error, turn: 2))

    let forwarded = await forwarder.forwarded
    XCTAssertEqual(forwarded.map(\.kind), [.completed, .error])
    XCTAssertEqual(forwarded.map(\.turn), [1, 2])
    // The session's working directory rides along, because the forwarder locates the log by it.
    XCTAssertEqual(forwarded.first?.sessionID, "session-1")
  }

  /// Forwarding is the phone's own outlet. Silencing the Mac's popups is a statement about this Mac,
  /// and a user who did that while leaving 手机远控 on is asking for exactly this split — which is
  /// also why the phone's switch, not these, is what turns it off.
  func testForwardingSurvivesTheLocalNotificationSwitches() async {
    let (model, presenter) = makeModel()
    let forwarder = RecordingPhoneForwarder()
    model.phoneForwarder = forwarder
    model.notificationsEnabled = false
    model.turnCompletionEnabled = false
    model.turnFailureEnabled = false

    await model.deliver(completion(kind: .completed, turn: 1))
    await model.deliver(completion(kind: .error, turn: 2))

    XCTAssertTrue(presenter.turnCompletions.isEmpty, "the local path is off")
    let forwarded = await forwarder.forwarded
    XCTAssertEqual(forwarded.count, 2, "the phone path is not")
  }

  /// The one local preference that does gate it. Subagent chatter is worse on a phone than in a
  /// notification centre, and the existing switch is already the place that decides it.
  func testSubagentForwardingFollowsTheSubagentSwitch() async {
    let (model, _) = makeModel()
    let forwarder = RecordingPhoneForwarder()
    model.phoneForwarder = forwarder

    await model.deliver(completion(kind: .completed, isSubagent: true))
    var forwarded = await forwarder.forwarded
    XCTAssertTrue(forwarded.isEmpty, "subagent chatter is off by default")

    model.subagentNotificationsEnabled = true
    await model.deliver(completion(kind: .completed, isSubagent: true))
    forwarded = await forwarder.forwarded
    XCTAssertEqual(forwarded.count, 1)
  }

  /// A build with no channel — and every test above before the forwarder is set — simply has no
  /// phone path. Absence must not be an error, and must not change the local one.
  func testWithoutAForwarderTheNotificationPathIsUnchanged() async {
    let (model, presenter) = makeModel()
    await model.deliver(completion(kind: .completed, turn: 1))
    XCTAssertEqual(presenter.turnCompletions.map(\.kind), [.completed])
  }
}
