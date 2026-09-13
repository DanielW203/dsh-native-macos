import Foundation
import HarnessIM
import HarnessKit

/// One approval the harness is waiting on.
///
/// The payload mirrors the harness's own contract for `approval/request`
/// (`packages/interaction/user-approval/src/types.ts`): an id to answer by, the session
/// it belongs to, the tool being asked about, the exact call when the asker had one, and
/// the asker's human-readable reason. Nothing else is on the wire, so nothing else is
/// invented here — in particular the tool *arguments* are not part of a waterfall request
/// and must not be guessed at.
public struct ApprovalAlert: Identifiable, Sendable, Equatable {
  public enum State: Sendable, Equatable {
    case pending
    /// Settled, with the harness's own outcome vocabulary.
    case answered(HarnessIM.ApprovalDecision)
    /// The answer could not be delivered; the alert stays until the user gives up on it.
    case failed(String)
  }

  /// The waterfall `eventId`. Unique per request, and the only thing an answer names.
  public var id: String
  /// The waterfall `agentId`, which is the session the request belongs to.
  public var sessionID: String
  public var toolName: String
  public var callId: String?
  public var reason: String?
  public var receivedAt: Date
  public var state: State

  public init(
    id: String,
    sessionID: String,
    toolName: String,
    callId: String? = nil,
    reason: String? = nil,
    receivedAt: Date = Date(),
    state: State = .pending
  ) {
    self.id = id
    self.sessionID = sessionID
    self.toolName = toolName
    self.callId = callId
    self.reason = reason
    self.receivedAt = receivedAt
    self.state = state
  }

  /// What the notification and the panel both show as the second line.
  public var detail: String {
    let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "没有说明原因" : trimmed
  }
}

/// Consumes the harness's forwarded-event stream and republishes tool approvals.
///
/// The same seam and the same wire frames as `HarnessIM.PromptRelay`, with one
/// deliberate difference: **this centre never answers on its own**. The chat relay
/// answers for the sender who owns the session; here a human clicks a button, and only
/// then is an outcome sent. That is what keeps a second likely answerer (the browser is
/// already one) from settling a request the user has not looked at.
public actor ApprovalAlertCenter {
  public typealias AlertHandler = @Sendable (ApprovalAlert) async -> Void
  public typealias WithdrawalHandler = @Sendable (String) async -> Void

  private let stream: any RemoteEventStreaming
  private let onAlert: AlertHandler
  private let onWithdraw: WithdrawalHandler
  private var runTask: Task<Void, Never>?

  public init(
    stream: any RemoteEventStreaming,
    onAlert: @escaping AlertHandler,
    onWithdraw: @escaping WithdrawalHandler
  ) {
    self.stream = stream
    self.onAlert = onAlert
    self.onWithdraw = onWithdraw
  }

  /// Consume until the stream ends or the centre is stopped. Safe to call once.
  public func run() async {
    runTask?.cancel()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.consume()
    }
    runTask = task
    await task.value
  }

  /// Stop consuming and close the carrier.
  public func stop() async {
    runTask?.cancel()
    runTask = nil
    await stream.close()
  }

  /// Send one decision. A failure is reported to the caller rather than swallowed:
  /// "the browser already answered this" and "the harness restarted" need different
  /// messages in the UI, and only the caller knows which one it can explain.
  public func answer(eventID: String, decision: HarnessIM.ApprovalDecision) async throws {
    try await stream.answer(eventID: eventID, outcome: decision.rawValue)
  }

  private func consume() async {
    do {
      let frames = try await stream.open()
      for try await frame in frames {
        if Task.isCancelled { break }
        switch frame {
        case .ready:
          continue
        case .waterfall(let eventID, let agentID, let event, let request):
          // Only tool approvals are surfaced. `user-questions/request` and every future
          // waterfall are ignored rather than half-rendered: the harness may add one at
          // any time, and a channel that guesses at an unknown payload is worse than one
          // that stays quiet.
          guard event == "approval/request" else { continue }
          let alert = ApprovalAlert(
            id: eventID,
            sessionID: agentID,
            toolName: request["toolName"]?.stringValue ?? "未知工具",
            callId: request["callId"]?.stringValue,
            reason: request["reason"]?.stringValue
          )
          await onAlert(alert)
        case .cancel(let eventID):
          await onWithdraw(eventID)
        case .emit:
          continue
        }
      }
    } catch {
      // A dead stream ends the centre quietly. The model owns reconnection, because only
      // it knows whether the harness URL is still available.
    }
  }
}
