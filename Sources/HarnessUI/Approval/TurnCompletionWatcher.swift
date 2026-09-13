import Foundation
import HarnessIM
import HarnessKit

/// Watches live sessions for turn endings and reports the ones worth telling the user about.
///
/// **Why this exists at all.** The harness's forwarded-event stream (`$events`) carries only the
/// events the host assembly selects for forwarding — approvals and user questions — and that
/// selection is declared host-side, so no client can add `turn/end` to it. Turn endings are durable
/// session events instead, which means reading them requires subscribing to `session/follow` per
/// session. That is what this actor does, and it is the only reason it holds sockets of its own.
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

    public init(sessionID: String, title: String? = nil, isSubagent: Bool = false, updatedAt: Date? = nil) {
      self.sessionID = sessionID
      self.title = title
      self.isSubagent = isSubagent
      self.updatedAt = updatedAt
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

  public init(
    sessionLimit: Int = TurnCompletionWatcher.defaultSessionLimit,
    retryBase: TimeInterval = 1,
    retryCeiling: TimeInterval = 60,
    followerFactory: @escaping @Sendable (String) async throws -> any SessionFollowing,
    onCompletion: @escaping @Sendable (TurnCompletion) async -> Void
  ) {
    self.sessionLimit = max(1, sessionLimit)
    self.retryBase = retryBase
    self.retryCeiling = retryCeiling
    self.followerFactory = followerFactory
    self.onCompletion = onCompletion
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
  private func run(sessionID: String) async {
    var backoff = retryBase
    var refusals = 0

    while !Task.isCancelled && !isStopped {
      do {
        let follower = try await followerFactory(sessionID)
        let stream = try await follower.openStream(sessionID: sessionID)
        states[sessionID] = .live
        backoff = retryBase
        refusals = 0

        var sawSnapshot = false
        for try await frame in stream {
          if Task.isCancelled { break }
          switch frame {
          case .snapshot:
            // Everything before this belongs to the past; only what follows is live.
            sawSnapshot = true
          case .event(let type, _, let turn, let data):
            guard sawSnapshot else { continue }
            await report(sessionID: sessionID, type: type, turn: turn, data: data)
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
            return
          }
        }
        states[sessionID] = .connecting
      }

      do {
        try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
      } catch {
        break
      }
      backoff = min(backoff * 2, retryCeiling)
    }
    if !isStopped { states[sessionID] = .stopped }
  }

  private func report(sessionID: String, type: String, turn: Int?, data: JSONValue) async {
    let target = targets[sessionID]
    guard var completion = TurnCompletion.decode(
      sessionID: sessionID,
      eventType: type,
      data: data,
      sessionTitle: target?.title,
      isSubagent: target?.isSubagent ?? false
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
