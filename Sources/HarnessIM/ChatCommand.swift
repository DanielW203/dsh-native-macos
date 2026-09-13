import Foundation
import HarnessKit

/// What one inbound chat message asks the channel to do.
///
/// A small closed grammar: every command is a line that starts with `/`, so ordinary chat is
/// never guessed at, and a typo becomes "unknown command" instead of a message submitted to a
/// running session by accident.
public enum ChatCommand: Sendable, Equatable {
  /// Drop the binding, so the next submission opens a fresh session.
  case newSession
  /// Interrupt whatever the bound session is running.
  case stop
  case list
  /// Bind this conversation to a session, by list index or id prefix.
  case use(String)
  /// Which session this conversation is bound to.
  case current
  /// The tail of the bound session's transcript. `nil` means the default depth.
  case history(Int?)
  /// Submit one line immediately, without waiting for the trigger phrase.
  case say(String)
  /// Answer the question the harness is waiting on.
  case answer(String)
  /// Which workspace the channel submits into, and which ones it could move to.
  case workspaceList
  /// Move the channel to another workspace: a list index, an id, a title, or a folder.
  case workspace(String)
  case help
}

/// One parsed inbound line: a command we know, or one we do not.
public enum ParsedChatLine: Sendable, Equatable {
  case command(ChatCommand)
  /// Starts with `/` and names nothing we know. Answered rather than submitted.
  case unknown(String)
}

public enum ChatCommandParser {
  /// Parse an inbound message.
  ///
  /// - Returns: `nil` when the text is not a command at all (`/` is the only sigil, so a
  ///   message without one keeps its existing meaning: chat content).
  public static func parse(_ text: String) -> ParsedChatLine? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }

    let body = trimmed.dropFirst()
    let verb: String
    let rest: String
    if let index = body.firstIndex(where: { $0.isWhitespace }) {
      verb = String(body[body.startIndex..<index]).lowercased()
      rest = String(body[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      verb = String(body).lowercased()
      rest = ""
    }

    switch verb {
    case "new", "新会话", "新":
      return .command(.newSession)
    case "stop", "中断", "停止":
      return .command(.stop)
    case "list", "列表", "会话":
      return .command(.list)
    case "current", "当前", "now":
      return .command(.current)
    case "use", "切换", "接管":
      guard !rest.isEmpty else { return .unknown("use") }
      return .command(.use(rest))
    case "history", "历史", "记录":
      guard !rest.isEmpty else { return .command(.history(nil)) }
      // A non-numeric argument is a typo, not a request for zero turns.
      guard let count = Int(rest), count > 0 else { return .unknown("history") }
      return .command(.history(count))
    case "say", "说", "发":
      guard !rest.isEmpty else { return .unknown("say") }
      return .command(.say(rest))
    case "answer", "答", "回答":
      guard !rest.isEmpty else { return .unknown("answer") }
      return .command(.answer(rest))
    // No argument is the *listing*, not a typo: on a phone "where am I?" is the question you
    // ask most, and `/use` and `/workspace` keep different meanings on purpose.
    case "workspace", "ws", "工作区":
      return rest.isEmpty ? .command(.workspaceList) : .command(.workspace(rest))
    case "help", "帮助", "?":
      return .command(.help)
    default:
      return .unknown(verb)
    }
  }
}

/// The texts the phone is sent.
///
/// Pure functions of their inputs so the wording and the numbering — which `/use` consumes —
/// are testable without a provider or a harness.
public enum ChatReply {
  public static let defaultListLimit = 15
  public static let defaultHistoryTurns = 6
  /// Workspaces are few, but a phone list still wants a bound.
  public static let defaultWorkspaceLimit = 15

  public static func help() -> String {
    """
    🕹 手机远控命令
    /list（/列表）— 列出所有会话
    /use 1（/接管 1）— 把本对话接到第 1 个会话
    /current（/当前）— 看当前接到哪个会话
    /history 10（/历史 10）— 看最近 10 轮对话
    /say 内容 — 直接发一句，不用等触发词
    /stop（/中断）— 中断正在跑的任务
    /answer 1（/答 1）— 回答 harness 的提问
    /new（/新会话）— 解除绑定，下一条消息开新会话
    /workspace（/工作区）— 看有哪些工作区
    /workspace 2 — 切到第 2 个工作区（会解绑当前会话）
    /help — 这条帮助

    审批：需要你允许时机器人会直接问你，回复「批准」或「拒绝」。
    计划评审（plan mode）：回复「批准」开始执行，「拒绝」让它继续改，
    或「说 你的意见」把修改意见带回去。
    """
  }

  public static func unknownCommand(_ verb: String) -> String {
    let name = verb.isEmpty ? "（空）" : "/\(verb)"
    return "不认识的命令 \(name)。发送 /help 看全部命令。"
  }

  /// The numbered list `/use` indexes into. The numbers are 1-based and belong to *this*
  /// listing — the service keeps it so a later `/use 3` resolves against what was shown.
  public static func sessionList(
    _ sessions: [SessionSummary],
    boundID: String?,
    limit: Int = defaultListLimit
  ) -> String {
    guard !sessions.isEmpty else {
      return "📋 还没有任何会话。发一条内容 + 触发词「开始」就能开一个。"
    }
    var lines = ["📋 会话（共 \(sessions.count) 个，按最近活动排序）", ""]
    for (offset, summary) in sessions.prefix(limit).enumerated() {
      let bound = summary.id.rawValue == boundID ? "●" : " "
      let running = summary.isLive ? "▶" : " "
      let title = RemoteSessionHistory.clip(summary.displayTitle, to: 24)
      let time = relative(summary.updatedAt)
      lines.append("\(offset + 1). \(bound)\(running) \(title) · \(shortID(summary.id.rawValue)) · \(time)")
    }
    if sessions.count > limit {
      lines.append("")
      lines.append("只显示了最近 \(limit) 个，共 \(sessions.count) 个。")
    }
    lines.append("")
    lines.append("● = 本对话当前绑定，▶ = 正在运行")
    lines.append("/use 1 接管 · /history 看历史 · /help 全部命令")
    return lines.joined(separator: "\n")
  }

  public static func bound(_ summary: SessionSummary) -> String {
    """
    已接管：\(RemoteSessionHistory.clip(summary.displayTitle, to: 40))
    \(summary.id.rawValue)
    \(summary.displayPath)

    之后发内容 + 触发词「开始」就会发到这个会话。/say 可以跳过触发词，/history 看历史，/stop 中断。
    这个会话的审批与提问从现在起也会发到你微信（不必打开「手机远控」开关，因为是你主动接管的）。
    """
  }

  public static func current(_ summary: SessionSummary?, boundID: String?) -> String {
    guard let boundID, !boundID.isEmpty else {
      return "当前没有绑定会话。发送 /list 选一个，或直接发内容 + 触发词「开始」开一个新会话。"
    }
    guard let summary else {
      return "当前绑定 \(boundID)，但它已经不在会话列表里了（可能被删除）。发送 /list 重新选一个。"
    }
    return "当前绑定：\(RemoteSessionHistory.clip(summary.displayTitle, to: 40)) · \(shortID(boundID))\n\(summary.displayPath)"
  }

  // MARK: - Workspaces

  /// How far the harness got with registering the folder `/workspace` just chose.
  ///
  /// Three honest answers rather than one boolean: `registered` can name the id, `unsupported`
  /// is a host without `workspace/create` (sessions still run, the sidebar just will not list
  /// them), and `pending` is "the harness was not reachable right now" — the next submission
  /// registers the folder anyway, so it is a note, not a failure.
  public enum WorkspaceRegistration: Sendable, Equatable {
    case registered(String)
    case unsupported
    case pending
  }

  /// One phone-sized folder name, with the home directory folded back to `~`.
  static func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  /// Whether two spellings name the same folder, for the "you are already here" check and the
  /// current-row marker. Symlinks are left alone: the service canonicalizes before storing.
  static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
  }

  /// The numbered list `/workspace <n>` indexes into.
  ///
  /// Numbers are 1-based over *this* listing — the service keeps it, so a later `/workspace 3`
  /// resolves against the rows the user actually read.
  public static func workspaceList(
    _ workspaces: [HarnessWorkspace],
    current: String?,
    limit: Int = defaultWorkspaceLimit
  ) -> String {
    guard !workspaces.isEmpty else {
      return "📁 还没有任何工作区。先发 /workspace /绝对/路径 指定一个，或在 harness 窗口里建一个。"
    }
    var lines = ["📁 工作区（共 \(workspaces.count) 个，按最近活动排序）", ""]
    for (offset, workspace) in workspaces.prefix(limit).enumerated() {
      let marker = current.map { samePath($0, workspace.path) } == true ? "●" : " "
      let title = RemoteSessionHistory.clip(workspace.displayTitle, to: 24)
      let unreachable = workspace.isReachable ? "" : "（目录不存在）"
      lines.append("\(offset + 1). \(marker) \(title) · \(abbreviated(workspace.path))\(unreachable)")
    }
    if workspaces.count > limit {
      lines.append("")
      lines.append("只显示了最近 \(limit) 个，共 \(workspaces.count) 个。")
    }
    lines.append("")
    lines.append("● = 当前工作区")
    lines.append("/workspace 1 切换 · 也可发 /workspace /绝对/路径")
    lines.append("切换后本对话会解绑，下一条内容会在新工作区开新会话。")
    return lines.joined(separator: "\n")
  }

  public static func workspaceSwitched(
    _ workspace: HarnessWorkspace,
    registration: WorkspaceRegistration
  ) -> String {
    let registrationLine: String
    switch registration {
    case .registered(let id):
      registrationLine = id.isEmpty
        ? "已登记到 harness"
        : "已登记到 harness（\(String(id.prefix(8)))…）"
    case .unsupported:
      registrationLine = "这台 harness 不支持登记工作区：会话仍能提交，但侧栏里看不到它们"
    case .pending:
      registrationLine = "harness 暂时不可用，第一次提交时会自动登记"
    }
    return """
    ✅ 已切换工作区：\(RemoteSessionHistory.clip(workspace.displayTitle, to: 40))
    \(abbreviated(workspace.path))
    \(registrationLine)
    本对话已解绑旧会话。发内容 + 触发词「开始」就会在新工作区新建会话。
    """
  }

  public static func alreadyInWorkspace(_ workspace: HarnessWorkspace) -> String {
    "当前已经在这个工作区：\(abbreviated(workspace.path))。想换会话发 /new。"
  }

  public static func workspaceNotFound(_ target: String) -> String {
    """
    没有找到工作区「\(RemoteSessionHistory.clip(target, to: 40))」。
    先发 /workspace 看编号，或直接发 /workspace /绝对/路径。
    """
  }

  public static func workspaceFolderMissing(_ path: String) -> String {
    "这个工作区目录不存在或不是文件夹：\(abbreviated(path))。可能已经被移动或删除。"
  }

  public static func workspaceListingUnavailable() -> String {
    "读不到 harness 的工作区列表（harness 目录不可用）。可以直接发 /workspace /绝对/路径 指定。"
  }

  public static func history(
    title: String?,
    sessionID: String,
    transcript: String,
    turns: Int
  ) -> String {
    let name = title?.isEmpty == false ? title! : sessionID
    return """
    📜 \(RemoteSessionHistory.clip(name, to: 30))（最近 \(turns) 轮）
    \(sessionID)

    \(transcript)
    """
  }

  /// `session-1a2b3c4d…` is unreadable on a phone and unnecessary; eight characters are
  /// enough to tell two rows apart and to paste back into `/use`.
  public static func shortID(_ sessionID: String) -> String {
    let withoutPrefix = sessionID.hasPrefix("session-") ? String(sessionID.dropFirst("session-".count)) : sessionID
    return String(withoutPrefix.prefix(8))
  }

  /// A phone-sized "how long ago".
  public static func relative(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "未知时间" }
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(Int(seconds / 60))分钟前" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))小时前" }
    if seconds < 86_400 * 30 { return "\(Int(seconds / 86_400))天前" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}
