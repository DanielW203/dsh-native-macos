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
  /// Which models this harness can route to. `nil` target is the listing; the effort is the
  /// optional second half of `/model 2 high`.
  case model(String?, effort: String?)
  /// The reasoning tiers of the current model. `nil` is the listing.
  case effort(String?)
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
    // `/model` carries at most two words — a target and an effort. A third is a typo, not a
    // model name, and answering it as unknown keeps a stray sentence out of the model resolver.
    case "model", "模型", "换模型":
      let words = Self.words(rest)
      guard words.count <= 2 else { return .unknown("model") }
      return .command(.model(words.first, effort: words.count == 2 ? words[1] : nil))
    case "effort", "thinking", "思考", "思考强度", "推理强度":
      let words = Self.words(rest)
      guard words.count <= 1 else { return .unknown("effort") }
      return .command(.effort(words.first))
    case "help", "帮助", "?":
      return .command(.help)
    default:
      return .unknown(verb)
    }
  }

  /// Whitespace-separated words, so `/model　2　high` (an ideographic space from a phone
  /// keyboard) parses like the ASCII spelling.
  private static func words(_ text: String) -> [String] {
    text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
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
    /model（/模型）— 看有哪些模型，以及当前用的是哪个
    /model 2 — 切到第 2 个模型（用它的默认思考强度）
    /model 2 high — 切模型并顺便指定思考强度
    /effort（/思考）— 看当前模型支持哪些思考强度
    /effort high — 只调思考强度（/effort 默认 恢复默认）
    /help — 这条帮助

    审批：需要你允许时机器人会直接问你，回复「批准」或「拒绝」。
    计划评审（plan mode）：回复「批准」开始执行，「拒绝」让它继续改，
    或「说 你的意见」把修改意见带回去。

    手机远控开关（app 工具栏或微信渠道窗口）：开着时，上面这些审批与提问
    会从任何会话推给你，并且桌面会话每轮结束时把结果和回复正文也转发过来。
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

  // MARK: - Models and reasoning effort

  /// How many catalog rows a phone listing shows before it stops numbering them.
  public static let defaultModelLimit = 12

  /// One catalog row: the number `/model <n>` uses, the current-marker, and the model id the
  /// user would type if they preferred the explicit form.
  static func modelRow(_ choice: HarnessModelChoice, index: Int, current: HarnessModelSelection?) -> String {
    let isCurrent = choice.isSameModel(as: current)
    let marker = isCurrent ? "●" : " "
    var row = "\(index). \(marker) \(RemoteSessionHistory.clip(choice.name, to: 24))（\(choice.model)）"
    if isCurrent, let pinned = current?.reasoningEffort, !pinned.isEmpty {
      row += " · 强度 \(pinned)"
    } else if !choice.efforts.isEmpty {
      row += " · 强度 \(choice.efforts.map(\.id).joined(separator: "/"))"
    }
    return row
  }

  /// The numbered list `/model <n>` indexes into.
  ///
  /// Numbers are 1-based over *this* listing — the service keeps it, so a later `/model 2`
  /// resolves against the rows the user actually read, exactly like `/use` and `/workspace`.
  ///
  /// - Parameter bound: whether the conversation already has a session. Without one the switch is
  ///   still worth making (it is remembered for the next new session), so the footer says which
  ///   of the two things will happen.
  public static func modelList(
    _ catalog: HarnessModelCatalog,
    current: HarnessModelSelection?,
    bound: Bool = true,
    limit: Int = defaultModelLimit
  ) -> String {
    guard !catalog.choices.isEmpty else {
      var text = "🤖 这个 harness 现在没有可用模型。"
      if !catalog.failures.isEmpty {
        text += "\n" + providerFailureNote(catalog)
      }
      text += "\n在桌面窗口的模型菜单里确认一下 provider 配置。"
      return text
    }

    var lines = ["🤖 模型（共 \(catalog.choices.count) 个）"]
    if let current {
      lines.append("当前：\(RemoteSessionHistory.clip(current.model, to: 32)) · \(current.reasoningEffort ?? "默认强度")")
    }
    lines.append("")

    var seenProvider: String?
    for (offset, choice) in catalog.choices.prefix(limit).enumerated() {
      if catalog.choices.contains(where: { $0.provider != choice.provider }) {
        if seenProvider != choice.provider {
          lines.append("【\(choice.providerName)】")
          seenProvider = choice.provider
        }
      }
      lines.append(modelRow(choice, index: offset + 1, current: current))
    }
    if catalog.choices.count > limit {
      lines.append("")
      lines.append("只显示了前 \(limit) 个，共 \(catalog.choices.count) 个；也可以直接发 /model 模型id。")
    }
    if !catalog.failures.isEmpty {
      lines.append("")
      lines.append(providerFailureNote(catalog))
    }
    lines.append("")
    lines.append("● = 当前模型")
    lines.append("/model 2 切换（用它默认的强度）· /model 2 high 同时指定强度")
    lines.append(bound
      ? "/effort 只调思考强度"
      : "还没有绑定会话：切换会记下来，在下一条消息开的新会话上生效。")
    return lines.joined(separator: "\n")
  }

  /// The numbered list `/effort <n>` indexes into.
  public static func effortList(_ choice: HarnessModelChoice, current: HarnessModelSelection?) -> String {
    guard !choice.efforts.isEmpty else {
      return """
      🧠 \(RemoteSessionHistory.clip(choice.name, to: 24))（\(choice.model)）不支持调思考强度。
      它用的是 provider 指定的默认值，换一个支持推理的模型才能调。
      """
    }
    var lines = ["🧠 \(RemoteSessionHistory.clip(choice.name, to: 24)) 的思考强度"]
    lines.append(current?.reasoningEffort.map { "当前：\($0)" } ?? "当前：默认强度（provider 默认）")
    lines.append("")
    for (offset, effort) in choice.efforts.enumerated() {
      let marker = current?.reasoningEffort == effort.id ? "●" : " "
      var row = "\(offset + 1). \(marker) \(effort.id)"
      if effort.name.lowercased() != effort.id.lowercased() { row += "（\(effort.name)）" }
      if let detail = effort.detail, !detail.isEmpty {
        row += " · \(RemoteSessionHistory.clip(detail.replacingOccurrences(of: "\n", with: " "), to: 24))"
      }
      lines.append(row)
    }
    lines.append("")
    lines.append("● = 当前强度")
    lines.append("/effort 2 或 /effort high 切换 · /effort 默认 恢复 provider 默认")
    return lines.joined(separator: "\n")
  }

  /// A provider that could not enumerate its models. Reported rather than hidden: a short list
  /// with a reason beats a short list that looks complete.
  static func providerFailureNote(_ catalog: HarnessModelCatalog) -> String {
    let names = catalog.failures.map { $0.name.isEmpty ? $0.id : $0.name }
    return "⚠️ \(catalog.failures.count) 个 provider 枚举失败：\(names.joined(separator: "、"))"
  }

  public static func modelSelected(_ selection: HarnessModelSelection, bound: Bool) -> String {
    let tail = bound
      ? "下一条消息就会用它。"
      : "还没有绑定会话：已经记下，会在下一条消息开的新会话上生效。"
    return """
    \(bound ? "✅ 模型已切换：" : "✅ 模型已选好：")\(RemoteSessionHistory.clip(selection.model, to: 32))
    思考强度：\(selection.reasoningEffort ?? "默认强度")
    \(tail)
    """
  }

  public static func modelNotFound(_ target: String) -> String {
    """
    没有找到模型「\(RemoteSessionHistory.clip(target, to: 40))」。
    发 /model 看编号，或直接发模型 id（例如 /model deepseek-chat）。
    """
  }

  /// A model the catalog lists, but which exposes no reasoning tiers at all.
  public static func effortUnsupported(_ choice: HarnessModelChoice) -> String {
    "\(RemoteSessionHistory.clip(choice.name, to: 24))（\(choice.model)）不支持调思考强度，用的是 provider 默认值。"
  }

  public static func effortNotFound(_ target: String, choice: HarnessModelChoice) -> String {
    """
    没有找到思考强度「\(RemoteSessionHistory.clip(target, to: 24))」。
    \(RemoteSessionHistory.clip(choice.name, to: 24)) 支持：\(choice.efforts.map(\.id).joined(separator: "、"))
    也可以发 /effort 看编号，或 /effort 默认 恢复默认。
    """
  }

  /// `/effort` when the model in force is not knowable — no session yet, or a host that does not
  /// project the session's selection.
  ///
  /// Guessing the harness default here would be worse than asking: it would install an effort on a
  /// model the user never chose, and a session whose model is pinned by an agent preset would be
  /// silently retargeted.
  public static func effortNeedsModel() -> String {
    """
    还不知道当前用的是哪个模型，列不出思考强度。
    先发 /model 看清单并选一个模型，再发 /effort。
    """
  }

  /// Whether a typed effort means "go back to whatever the provider defaults to".
  ///
  /// Clearing is a real operation, not a no-op: without the field the host resolves the model
  /// again from scratch, while naming a tier pins it.
  public static func isDefaultEffort(_ target: String) -> Bool {
    ["默认", "默认强度", "default", "auto", "自动", "none", "无"].contains(
      target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
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
