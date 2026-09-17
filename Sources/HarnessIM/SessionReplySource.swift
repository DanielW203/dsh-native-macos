import Foundation
import HarnessKit

/// The assistant's answer to one submitted turn.
public struct HarnessReply: Sendable, Equatable {
  public var text: String
  public var turn: Int?
  /// `turn/end.reason.kind` — `completed`, `error`, `aborted`, …
  public var reason: String?
  /// Whether a `turn/end` for this turn has been recorded yet.
  public var isComplete: Bool

  public init(text: String, turn: Int? = nil, reason: String? = nil, isComplete: Bool) {
    self.text = text
    self.turn = turn
    self.reason = reason
    self.isComplete = isComplete
  }
}

/// Turns a session log into the answer for one submitted prompt.
///
/// Kept pure and separate from polling so the whole rule — "which turn is mine, and what did
/// it answer" — is testable against a recorded session log rather than against a live model.
public enum SessionReplyExtractor {
  /// Extract the reply belonging to `requestId`.
  ///
  /// The host stamps the accepted user message with the `requestId` the client sent, so the
  /// turn is identified by identity rather than by "the next thing that happens". That
  /// matters because a session is shared: another window can inject a turn at any moment.
  ///
  /// - Returns: `nil` while the prompt has not reached the log yet.
  public static func reply(in events: [SessionEvent], requestId: String) -> HarnessReply? {
    guard let start = events.firstIndex(where: { event in
      guard event.kind == .userMessage, let message = event.userMessage else { return false }
      return message.source?.rpcId == requestId
    }) else { return nil }

    var text = ""
    var turn: Int?
    for event in events[start...] {
      if let message = event.assistantMessage {
        turn = message.turn ?? turn
        // `message.text` is the plain text blocks only. Joining `textValue` instead would fold the
        // model's reasoning in — the harness writes that block first, so the reply that reached the
        // phone would be its thinking.
        let rendered = message.text
        if !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          text = rendered
        }
        continue
      }
      if event.kind == .turnEnd {
        return HarnessReply(text: text, turn: messageTurn(event) ?? turn,
                            reason: event.turnEndReason, isComplete: true)
      }
    }
    // The turn is still running: report what exists so far so a long task can be narrated.
    return HarnessReply(text: text, turn: turn, reason: nil, isComplete: false)
  }

  static func messageTurn(_ event: SessionEvent) -> Int? {
    event.data.path("turn")?.intValue
  }

  /// What one turn answered, read out of a session's own log.
  ///
  /// **Bounded to a single turn**, which is the whole difficulty: a session log is append-only and
  /// holds every turn that ever ran, so a scan that merely collects assistant text would forward a
  /// conversation rather than an answer. The window runs from the turn's own `turn/end` back to the
  /// nearest boundary before it.
  ///
  /// The **last** non-empty message in that window, not every message: a turn narrates as it goes
  /// and then answers, and pushing three partial paragraphs to a phone for one result is worse than
  /// pushing none. That matches `reply(in:requestId:)`, which settles on the last one for the same
  /// reason.
  ///
  /// - Parameter turn: the turn to read, or `nil` for "the newest ending in this log" — what a
  ///   caller that only holds a session id can ask for.
  public static func turnReply(in events: [SessionEvent], turn: Int?) -> String? {
    let end: Int
    if let turn {
      // A turn that never ended has no answer to forward, and guessing "the newest one" here would
      // attribute an older turn's text to the turn that just failed to end.
      guard let index = events.lastIndex(where: { $0.kind == .turnEnd && messageTurn($0) == turn }) else {
        return nil
      }
      end = index
    } else {
      end = events.count - 1
    }
    guard end >= 0 else { return nil }

    var start = 0
    var index = end - 1
    while index >= 0 {
      let kind = events[index].kind
      if kind == .turnStart || kind == .turnEnd {
        start = index + 1
        break
      }
      index -= 1
    }

    var found: String?
    for event in events[start...end] {
      guard let message = event.assistantMessage else { continue }
      // Plain text only, for the same reason as `reply(in:requestId:)`: reasoning is not the answer,
      // and a length cap applied to "reasoning + answer" would spend itself on the reasoning.
      let rendered = message.text
      if !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found = rendered }
    }
    return found
  }
}

/// The seam a reply source must satisfy.
///
/// Production reads the session log; a test answers from a script. Declaring it here (rather
/// than in the service) keeps the service's factory type public without leaking a test type
/// into the module's API.
public protocol SessionReplyProducing: Sendable {
  func waitForReply(requestId: String, timeout: Duration?) async -> HarnessReply?
}

/// Watches a session for the answer to one prompt.
///
/// The log file is the primary source because it is the harness's own durable record: no
/// second protocol to keep in sync, and it works the same whether or not a web view is open.
/// The `/api` page endpoint is the fallback for the cases where the file cannot be located
/// (a workspace that moved, an unreadable directory, a layout change) — it is best-effort by
/// design, and the service reports "请到 GUI 查看" when even that yields nothing.
public actor SessionReplySource: SessionReplyProducing {
  public struct Configuration: Sendable {
    public var pollInterval: Duration
    public var timeout: Duration
    /// Consecutive log-read failures tolerated before falling back to the API.
    public var logFailureThreshold: Int

    public init(
      pollInterval: Duration = .seconds(1),
      timeout: Duration = .seconds(900),
      logFailureThreshold: Int = 5
    ) {
      self.pollInterval = pollInterval
      self.timeout = timeout
      self.logFailureThreshold = logFailureThreshold
    }
  }

  private let dshHome: URL
  private let cwd: String
  private let sessionID: String
  private let client: HarnessAPIClient?
  private let configuration: Configuration

  public init(
    dshHome: URL,
    cwd: String,
    sessionID: String,
    client: HarnessAPIClient?,
    configuration: Configuration = Configuration()
  ) {
    self.dshHome = dshHome
    self.cwd = cwd
    self.sessionID = sessionID
    self.client = client
    self.configuration = configuration
  }

  /// Wait for the turn identified by `requestId` to finish.
  ///
  /// - Returns: the completed reply, or the best partial one at the deadline. A timeout is
  ///   not an error here: the caller decides whether to keep watching and deliver later,
  ///   which is what makes a long task survivable.
  public func waitForReply(requestId: String, timeout: Duration? = nil) async -> HarnessReply? {
    let deadline = Date().addingTimeInterval(seconds(timeout ?? configuration.timeout))
    var consecutiveLogFailures = 0
    var latest: HarnessReply?

    while Date() < deadline {
      if let reply = readFromLog(requestId: requestId) {
        latest = reply
        consecutiveLogFailures = 0
        if reply.isComplete { return reply }
      } else {
        consecutiveLogFailures += 1
      }

      if consecutiveLogFailures >= configuration.logFailureThreshold, let client {
        if let fallback = await pageFallback() {
          latest = fallback
          if fallback.isComplete { return fallback }
        }
      }

      try? await Task.sleep(for: configuration.pollInterval)
    }
    return latest
  }

  /// Read the session log once and extract the reply, if the log is reachable.
  func readFromLog(requestId: String) -> HarnessReply? {
    guard let directory = try? SessionPaths.sessionDirectory(dshHome: dshHome, cwd: cwd, sessionID: sessionID),
          let log = SessionPaths.logFile(inSessionDirectory: directory) else { return nil }
    let reader = SessionLogReader(url: log)
    guard let events = try? reader.readEvents() else { return nil }
    return SessionReplyExtractor.reply(in: events, requestId: requestId)
  }

  /// Best-effort API fallback: scan the newest page for the last assistant text.
  ///
  /// Deliberately shallow — it looks for the shape a page record takes today and gives up
  /// quietly otherwise, because inventing an answer would be worse than telling the user to
  /// look at the GUI.
  func pageFallback() async -> HarnessReply? {
    guard let client else { return nil }
    guard let page = try? await client.page(sessionID: sessionID, throughSeq: Int.max / 2, maxMessages: 50) else {
      return nil
    }
    return Self.lastAssistantText(in: page).map {
      HarnessReply(text: $0, turn: nil, reason: nil, isComplete: true)
    }
  }

  /// Depth-first search for the newest `assistant` message text inside an arbitrary payload.
  static func lastAssistantText(in value: JSONValue) -> String? {
    var found: String?
    func walk(_ node: JSONValue) {
      switch node {
      case .object(let object):
        let role = object["role"]?.stringValue
        if role == "assistant", let content = object["content"]?.arrayValue {
          let joined = content.compactMap { $0["text"]?.stringValue }.joined()
          if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found = joined }
        }
        for key in object.keys.sorted() { walk(object[key] ?? .null) }
      case .array(let items):
        for item in items { walk(item) }
      default:
        break
      }
    }
    walk(value)
    return found
  }

  private func seconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}
