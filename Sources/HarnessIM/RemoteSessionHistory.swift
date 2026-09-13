import Foundation
import HarnessKit

/// Turns a session log into the short transcript the phone can read.
///
/// Pure over `[SessionEvent]` for the same reason `SessionReplyExtractor` is: the rules —
/// which turns, whose text, how much of it — are worth testing against a recorded log rather
/// than against a live model.
public enum RemoteSessionHistory {
  /// One user turn and the assistant text that answered it.
  public struct Turn: Sendable, Equatable {
    public var user: String
    public var assistant: String
    /// True when the log holds no `turn/end` for this turn yet.
    public var isRunning: Bool

    public init(user: String, assistant: String, isRunning: Bool) {
      self.user = user
      self.assistant = assistant
      self.isRunning = isRunning
    }
  }

  /// Pair each turn with the human prompt that opened it and the answer it produced.
  ///
  /// A turn is bounded by `turn/start`/`turn/end`, not by `user/message`: one turn carries
  /// several of those, because the harness appends its own runtime-context message beside the
  /// prompt the human submitted. Treating each `user/message` as a turn would render a
  /// conversation of context dumps and answers with no questions in it. The human's own message
  /// is the one stamped with the prompt's `rpcId`; anything else is context and is only shown
  /// when a log has no stamped message at all.
  ///
  /// Only the **last** assistant text of a turn is kept: a turn that called tools produced
  /// several, and the earlier ones are narration ("let me look at X") rather than the answer.
  public static func turns(in events: [SessionEvent]) -> [Turn] {
    var result: [Turn] = []
    var prompt: String?
    var context: String?
    var assistant = ""
    var inTurn = false

    func close(running: Bool) {
      let text = prompt ?? context ?? ""
      if inTurn, !text.isEmpty || !assistant.isEmpty {
        result.append(Turn(user: text, assistant: assistant, isRunning: running))
      }
      prompt = nil
      context = nil
      assistant = ""
      inTurn = false
    }

    for event in events {
      switch event.kind {
      case .turnStart:
        // A turn that never ended (a crash, a truncated log) is still a turn.
        close(running: false)
        inTurn = true
      case .turnEnd:
        close(running: false)
      case .userMessage:
        guard let message = event.userMessage else { continue }
        if !inTurn { inTurn = true }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        if message.source?.rpcId?.isEmpty == false {
          if prompt == nil { prompt = text }
        } else if context == nil {
          context = text
        }
      case .assistantMessage:
        guard let message = event.assistantMessage else { continue }
        let rendered = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rendered.isEmpty { assistant = rendered }
      default:
        break
      }
    }
    // Whatever is still open never saw its `turn/end`: the turn is still running.
    close(running: inTurn)
    return result
  }

  /// Render the last `limit` turns, oldest first.
  ///
  /// Both sides are clipped: a phone screen shows a few lines, and a 4,000-character answer
  /// would arrive as twenty messages. `maxCharacters` is the whole budget, decided by the
  /// caller so it can follow the channel's own reply chunking.
  public static func render(turns list: [Turn], limit: Int, maxCharacters: Int) -> String {
    let selected = list.suffix(max(1, limit))
    guard !selected.isEmpty else { return "这个会话还没有对话记录。" }

    // Split the budget across what is present, so one long answer cannot starve the rest.
    let perSide = max(120, maxCharacters / max(1, selected.count * 2))
    var lines: [String] = []
    for turn in selected {
      let who = turn.isRunning ? "…" : "🤖"
      lines.append("🧑 " + clip(turn.user, to: perSide))
      if !turn.assistant.isEmpty {
        lines.append("\(who) " + clip(turn.assistant, to: perSide))
      } else if turn.isRunning {
        lines.append("\(who) （还在进行中）")
      }
      lines.append("")
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Collapse whitespace and cut at a character budget, marking the cut.
  public static func clip(_ text: String, to limit: Int) -> String {
    let collapsed = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)) + "…"
  }
}

/// Reads one session's log off disk.
///
/// The log is the harness's own durable record, so reading it costs no protocol and works
/// whether or not a web view is open. `cwd` is part of the address because the harness stores
/// logs under a path derived from the working directory.
public struct SessionLogLocator: Sendable {
  public var dshHome: URL

  public init(dshHome: URL) {
    self.dshHome = dshHome
  }

  /// Every event of one session, or nil when the log cannot be located or read.
  public func events(cwd: String, sessionID: String) -> [SessionEvent]? {
    guard let directory = try? SessionPaths.sessionDirectory(
      dshHome: dshHome, cwd: cwd, sessionID: sessionID
    ), let log = SessionPaths.logFile(inSessionDirectory: directory) else { return nil }
    return try? SessionLogReader(url: log).readEvents()
  }
}
