import Foundation
import HarnessIM
import HarnessKit

/// Watches live sessions for what is worth telling the user about: turn endings, and the plain
/// assistant text a running turn commits as it goes.
///
/// **Why this exists at all.** The harness's forwarded-event stream (`$events`) carries only the
/// events the host assembly selects for forwarding — approvals and user questions — and that
/// selection is declared host-side, so no client can add `turn/end` to it. Turn endings are durable
/// session events instead, which means reading them requires subscribing to `session/follow` per
/// session. That is what this actor does, and it is the only reason it holds sockets of its own.
/// The running narration (`assistant/message`) rides the same durable stream, so it costs no
/// second subscription.
///
/// **Two rules that keep it from being annoying:**
///
/// 1. *Only live frames notify.* A follow stream opens with a `snapshot` of everything already in
///    the log. Those turns ended before this subscription existed, so reporting them would replay
///    history as notifications — worst of all right after a restart. The snapshot frame is the
///    boundary: frames after it are live, and only those are reported.
/// 2. *A bounded number of subscriptions.* Only the most recently active sessions are followed, and
///    subagent sessions are followed only when the user asked for them. A long session history must
///    not turn into a hundred open sockets.
public actor TurnCompletionWatcher {
  /// The sessions currently worth following, most recent first.
  public struct WatchTarget: Sendable, Equatable {
    public var sessionID: String
    public var title: String?
    /// Whether this session is a subagent's. Decided by the caller from `SessionSummary.parentID`,
    /// because only the caller has the session list.
    public var isSubagent: Bool
    /// When the session was last active, used to choose which targets survive the cap.
    public var updatedAt: Date?
    /// The session's working directory.
    ///
    /// Carried through to the completion because a session's log is located by it: a forwarder that
    /// wants to say what the turn *answered* cannot find the log without it, and re-reading the
    /// session list at that moment would race the very turn that just ended.
    public var cwd: String?

    public init(
      sessionID: String,
      title: String? = nil,
      isSubagent: Bool = false,
      updatedAt: Date? = nil,
      cwd: String? = nil
    ) {
      self.sessionID = sessionID
      self.title = title
      self.isSubagent = isSubagent
      self.updatedAt = updatedAt
      self.cwd = cwd
    }
  }

  /// Why a session is not being followed, for a caller that wants to say so.
  public enum SubscriptionState: Sendable, Equatable {
    case stopped
    case connecting
    case live
    /// The harness refused the stream, which is what an older harness that has no
    /// `session/follow` does. Retrying cannot help, so this is terminal for the session.
    case unavailable(String)
  }

  /// How many sessions are followed at once.
  ///
  /// Eight is a presentation choice: it covers the sessions a user is plausibly watching without
  /// making the app hold a socket per session in a long history.
  public static let defaultSessionLimit = 8
  /// Consecutive refusals before a session is declared unavailable rather than retried.
  static let refusalLimit = 3

  private let followerFactory: @Sendable (String) async throws -> any SessionFollowing
  private let onCompletion: @Sendable (TurnCompletion) async -> Void
  /// Called once per assistant step that produced plain text, before its turn ends.
  ///
  /// A separate channel from `onCompletion` because it is a separate fact: the same follow stream
  /// carries both, but a caller may want the running narration without the endings, or the endings
  /// without the narration. Defaults to a no-op so a caller that only wants endings — and every
  /// test written before this existed — is unaffected.
  private let onAssistantText: @Sendable (AssistantTextSegment) async -> Void
  private let sessionLimit: Int
  private let retryBase: TimeInterval
  private let retryCeiling: TimeInterval

  private var subscriptions: [String: Task<Void, Never>] = [:]
  private var states: [String: SubscriptionState] = [:]
  private var targets: [String: WatchTarget] = [:]
  private var includeSubagents = false
  private var isStopped = false
  /// Sessions whose stream ended and which should not be re-subscribed until they are named again.
  private var blocked: Set<String> = []
  /// The highest durable sequence accounted for, per session.
  ///
  /// `nil` means "no baseline yet": that session's first snapshot is history and must not be
  /// announced. Dropped whenever a subscription is cancelled or written off, so a session that
  /// returns to the target set re-baselines instead of replaying everything since it left.
  private var watermark: [String: Int] = [:]

  public init(
    sessionLimit: Int = TurnCompletionWatcher.defaultSessionLimit,
    retryBase: TimeInterval = 1,
    retryCeiling: TimeInterval = 60,
    followerFactory: @escaping @Sendable (String) async throws -> any SessionFollowing,
    onCompletion: @escaping @Sendable (TurnCompletion) async -> Void,
    onAssistantText: @escaping @Sendable (AssistantTextSegment) async -> Void = { _ in }
  ) {
    self.sessionLimit = max(1, sessionLimit)
    self.retryBase = retryBase
    self.retryCeiling = retryCeiling
    self.followerFactory = followerFactory
    self.onCompletion = onCompletion
    self.onAssistantText = onAssistantText
  }

  // MARK: - Targets

  /// Replace the set of sessions that should be followed.
  ///
  /// Idempotent by design: the caller pushes the session list whenever it changes, which may be
  /// once per event, and a session already being followed is left alone rather than restarted.
  public func setTargets(_ next: [WatchTarget], includeSubagents: Bool) {
    guard !isStopped else { return }
    self.includeSubagents = includeSubagents

    var kept: [String: WatchTarget] = [:]
    for target in next where includeSubagents || !target.isSubagent {
      kept[target.sessionID] = target
    }
    targets = kept

    // Cull to the cap by recency. A session with no timestamp sorts last rather than first: an
    // unknown age is not evidence of recent activity.
    let ordered = kept.values.sorted { left, right in
      (left.updatedAt ?? .distantPast) > (right.updatedAt ?? .distantPast)
    }
    let wanted = Set(ordered.prefix(sessionLimit).map(\.sessionID))

    for (id, task) in subscriptions where !wanted.contains(id) {
      task.cancel()
      subscriptions[id] = nil
      states[id] = nil
      // Its baseline goes with it: a session that comes back later must not replay everything that
      // happened while it was outside the target set.
      watermark[id] = nil
    }
    for id in wanted where subscriptions[id] == nil && !blocked.contains(id) {
      start(id)
    }
  }

  /// The state of one session's subscription, for a caller that reports it.
  public func state(of sessionID: String) -> SubscriptionState {
    states[sessionID] ?? .stopped
  }

  /// Whether any session's stream was refused by the harness.
  public var hasUnavailableSubscription: Bool {
    states.values.contains { if case .unavailable = $0 { return true } else { return false } }
  }

  /// Stop every subscription. The watcher cannot be restarted afterwards, which matches how the
  /// app uses it: a stopped watcher belongs to a torn-down harness connection.
  public func stop() async {
    isStopped = true
    for task in subscriptions.values { task.cancel() }
    subscriptions.removeAll()
    states.removeAll()
    watermark.removeAll()
  }

  // MARK: - Subscription lifecycle

  private func start(_ sessionID: String) {
    states[sessionID] = .connecting
    let task = Task { [weak self] in
      guard let self else { return }
      await self.run(sessionID: sessionID)
    }
    subscriptions[sessionID] = task
  }

  /// Follow one session until it is cancelled, reconnecting on a dropped stream.
  ///
  /// A stream that *ends* is normal — the harness closes a follow stream when the session goes
  /// away, for instance — so ending means re-subscribe, backing off so a session that cannot be
  /// followed does not become a busy loop. A *refusal* is different: the harness answered, and the
  /// answer was no. After a few of those the session is written off, because what the harness lacks
  /// is the capability rather than the connection.
  ///
  /// Two rules make a reconnect survivable, and both come from watching a live harness:
  ///
  /// 1. **Catch up from the opening page.** Measured against a session that is actually running, the
  ///    harness closes a subscription taken mid-turn almost immediately, so a re-subscription's
  ///    snapshot is exactly the gap the dead stream left. Ignoring it (as "the past") swallows every
  ///    ending of any session in use — the failure this used to have: the phone got nothing at all.
  /// 2. **Only a stream that carried something earns a fast retry.** Resetting the backoff on a
  ///    successful *open* turns that immediate close into a storm: one session was re-snapshotting
  ///    roughly 1.9 MB every 12 seconds, for hours.
  private func run(sessionID: String) async {
    var backoff = retryBase
    var refusals = 0

    while !Task.isCancelled && !isStopped {
      var carriedLiveFrame = false
      do {
        let follower = try await followerFactory(sessionID)
        let stream = try await follower.openStream(sessionID: sessionID)
        states[sessionID] = .live

        var sawSnapshot = false
        for try await frame in stream {
          if Task.isCancelled { break }
          switch frame {
          case .snapshot(let cursor, let records):
            sawSnapshot = true
            await catchUp(sessionID: sessionID, cursor: cursor, records: records)
          case .event(let type, let seq, let turn, let data):
            guard sawSnapshot else { continue }
            carriedLiveFrame = true
            // The catch-up may already have delivered this one: the page can overlap frames the
            // previous stream had in flight. Announcing a turn twice is worse than missing it.
            guard isNewer(seq, for: sessionID) else { continue }
            await report(sessionID: sessionID, type: type, seq: seq, turn: turn, data: data)
          case .assistantStream, .unrecognized:
            continue
          }
        }
        await follower.close()
        if Task.isCancelled || isStopped { break }
        states[sessionID] = .connecting
      } catch is CancellationError {
        break
      } catch {
        if Task.isCancelled || isStopped { break }
        if Self.isCapabilityRefusal(error) {
          refusals += 1
          if refusals >= Self.refusalLimit {
            states[sessionID] = .unavailable(Self.describe(error))
            blocked.insert(sessionID)
            subscriptions[sessionID] = nil
            watermark[sessionID] = nil
            return
          }
        }
        states[sessionID] = .connecting
      }

      if carriedLiveFrame {
        backoff = retryBase
        refusals = 0
      } else {
        backoff = min(backoff * 2, retryCeiling)
      }

      do {
        try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
      } catch {
        break
      }
    }
    if !isStopped { states[sessionID] = .stopped }
  }

  /// Whether a live frame is newer than everything already accounted for, recording it if so.
  ///
  /// A frame without a sequence number cannot be placed, so it is reported: the alternative is to
  /// drop an ending because the harness stopped numbering its events.
  private func isNewer(_ seq: Int?, for sessionID: String) -> Bool {
    guard let seq else { return true }
    if let accounted = watermark[sessionID], seq <= accounted { return false }
    watermark[sessionID] = seq
    return true
  }

  /// Announce the endings a re-subscription's opening page contains.
  ///
  /// The page is history on the *first* subscription — no baseline yet — and the gap on every
  /// reconnect after it. Only the second case is news; the first is what keeps an app restart from
  /// replaying yesterday's turns as notifications.
  private func catchUp(sessionID: String, cursor: Int, records: [SessionFollowRecord]) async {
    let baseline = watermark[sessionID]
    var highest = cursor
    for record in records {
      if let seq = record.seq, seq > highest { highest = seq }
      guard let baseline, let seq = record.seq, seq > baseline else { continue }
      await report(sessionID: sessionID, type: record.type, seq: record.seq, turn: record.turn, data: record.data)
    }
    watermark[sessionID] = highest
  }

  /// Announce one durable event, if it is one the caller asked to hear about.
  ///
  /// Two kinds qualify and they do not overlap: `turn/end` becomes a completion, and any step that
  /// committed `assistant/message` with plain text becomes a segment. Everything else — tool calls,
  /// results, approvals, reasoning — is either already relayed elsewhere or deliberately not the
  /// phone's business.
  private func report(sessionID: String, type: String, seq: Int?, turn: Int?, data: JSONValue) async {
    let target = targets[sessionID]
    if var segment = AssistantTextSegment.decode(
      sessionID: sessionID,
      eventType: type,
      seq: seq,
      data: data
    ) {
      segment.sessionTitle = target?.title
      segment.isSubagent = target?.isSubagent ?? false
      if segment.turn == nil { segment.turn = turn }
      await onAssistantText(segment)
      return
    }

    guard var completion = TurnCompletion.decode(
      sessionID: sessionID,
      eventType: type,
      data: data,
      sessionTitle: target?.title,
      isSubagent: target?.isSubagent ?? false,
      cwd: target?.cwd
    ) else { return }
    if completion.turn == nil { completion.turn = turn }
    guard completion.kind.deservesNotification else { return }
    await onCompletion(completion)
  }

  // MARK: - Failure classification

  /// Whether an error means "this harness does not serve the stream" rather than "the connection
  /// had a bad moment".
  ///
  /// The gateway reports an unmounted service as `gateway/service-unavailable`, which is the shape
  /// an older harness without `session/follow` would produce. Anything else is treated as transient,
  /// because guessing wrong about a transient error would silently stop watching a session.
  static func isCapabilityRefusal(_ error: Error) -> Bool {
    guard let apiError = error as? HarnessAPIError else { return false }
    guard let providerCode = apiError.providerCode else { return false }
    return providerCode == "gateway/service-unavailable"
      || providerCode == "gateway/arguments-invalid"
      || providerCode == "gateway/unknown-endpoint"
  }

  static func describe(_ error: Error) -> String {
    if let apiError = error as? HarnessAPIError {
      return apiError.message + (apiError.providerCode.map { " (\($0))" } ?? "")
    }
    return error.localizedDescription
  }
}
