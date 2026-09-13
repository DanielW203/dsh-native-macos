import Foundation

// MARK: - Tool descriptors

/// How a capability reaches the model.
///
/// This distinction is the single most important UI-affecting fact discovered in M0:
/// a profile can expose tools **directly** (one model-visible tool per capability) or
/// through **PTC** — programmatic tool calling — where the model sees one `run_code`
/// tool and every other capability is a TypeScript binding inside the program. The
/// two modes need different renderings, and the same shared model has to express both.
public enum ToolOrigin: String, Sendable, Codable, Equatable, CaseIterable {
  /// A model-visible tool with its own JSON Schema.
  case model
  /// A binding available only inside a PTC program (`tools.name(args)`).
  case programBinding
  /// Available both ways (a profile running `mode: both`).
  case both

  public var displayName: String {
    switch self {
    case .model: return "Direct tool"
    case .programBinding: return "Program binding"
    case .both: return "Direct + binding"
    }
  }
}

/// One model-facing tool, exactly as the model receives it.
public struct ToolDescriptor: Sendable, Equatable, Identifiable, Codable {
  public var name: String
  public var description: String
  /// JSON Schema for the arguments. Kept verbatim for byte-conformance.
  public var parameters: JSONValue
  public var category: ToolCategory
  public var origin: ToolOrigin
  /// Tools whose effects cannot be undone; the UI badges these.
  public var isMutating: Bool

  public var id: String { name }

  public init(
    name: String,
    description: String,
    parameters: JSONValue,
    category: ToolCategory,
    origin: ToolOrigin = .model,
    isMutating: Bool = false
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.category = category
    self.origin = origin
    self.isMutating = isMutating
  }

  /// The `{name, description, parameters}` triple in the order the official runtime
  /// emits it. Used by the schema conformance test.
  public var wireJSON: JSONValue {
    .object([
      "name": .string(name),
      "description": .string(description),
      "parameters": parameters,
    ])
  }
}

/// Grouping used by the tool browser, the tool-card registry, and the inspector.
public enum ToolCategory: String, Sendable, Codable, Equatable, CaseIterable {
  case filesystem
  case search
  case shell
  case terminal
  case planning
  case delegation
  case jobs
  case interaction
  case web
  case memory
  case session
  case workflow
  case team
  case media
  case code
  case editor
  case lsp
  case schedule
  case plugin
  case uncategorized

  public var displayName: String {
    switch self {
    case .filesystem: return "Filesystem"
    case .search: return "Search"
    case .shell: return "Shell"
    case .terminal: return "Terminal"
    case .planning: return "Planning"
    case .delegation: return "Delegation"
    case .jobs: return "Jobs"
    case .interaction: return "Interaction"
    case .web: return "Web"
    case .memory: return "Memory"
    case .session: return "Session"
    case .workflow: return "Workflow"
    case .team: return "Team"
    case .media: return "Media"
    case .code: return "Code runtime"
    case .editor: return "Editor"
    case .lsp: return "Language server"
    case .schedule: return "Schedule"
    case .plugin: return "Plugins"
    case .uncategorized: return "Other"
    }
  }

  public var symbolName: String {
    switch self {
    case .filesystem: return "doc.text"
    case .search: return "magnifyingglass"
    case .shell: return "terminal"
    case .terminal: return "rectangle.terminal"
    case .planning: return "checklist"
    case .delegation: return "person.2"
    case .jobs: return "gearshape.2"
    case .interaction: return "bubble.left.and.bubble.right"
    case .web: return "globe"
    case .memory: return "brain"
    case .session: return "clock.arrow.circlepath"
    case .workflow: return "point.3.connected.trianglepath.dotted"
    case .team: return "person.3"
    case .media: return "photo"
    case .code: return "chevron.left.forwardslash.chevron.right"
    case .editor: return "square.and.pencil"
    case .lsp: return "curlybraces"
    case .schedule: return "calendar.badge.clock"
    case .plugin: return "puzzlepiece.extension"
    case .uncategorized: return "questionmark.circle"
    }
  }

  /// Categorise by name. Used when a descriptor arrives without metadata
  /// (`request/header`, bridge payloads) so cards still route correctly.
  public init(name: String) {
    switch name {
    case "read", "write", "edit", "read_image", "str_replace_editor", "present":
      self = name == "str_replace_editor" ? .editor : (name == "read_image" ? .media : .filesystem)
    case "glob", "grep":
      self = .search
    case "bash", "pwsh":
      self = .shell
    case "run_code":
      self = .code
    case "terminal_open", "terminal_close", "terminal_read", "terminal_send", "terminal_list", "terminal_signal":
      self = .terminal
    case "todo_write", "exit_plan_mode", "update_goal", "get_goal", "create_goal":
      self = .planning
    case "subagent", "subagent_fork", "list_agents", "send_message", "interrupt_agent",
         "ralph", "list_subagent_models", "wait_agent":
      self = .delegation
    case "job_list", "job_output", "job_kill":
      self = .jobs
    case "ask_user_question":
      self = .interaction
    case "web_search", "web_fetch", "advanced_search", "free_search_test", "platform_search":
      self = .web
    case "memoir_read", "memoir_record", "memoir_update":
      self = .memory
    case "session_search", "session_trace", "session_event_read", "session_event_search", "session_event_trace":
      self = .session
    case "workflow":
      self = .workflow
    case "spawn_teammate", "team_task_create", "team_task_get", "team_task_list", "team_task_update":
      self = .team
    case "lsp":
      self = .lsp
    case "schedule_create", "schedule_delete", "schedule_list":
      self = .schedule
    case "skill":
      self = .planning
    case "plugin_install", "plugin_uninstall", "plugin_toggle", "plugin_search", "plugin_status",
         "cordis_define", "cordis_run", "cordis_stop", "cordis_undefine", "cordis_inspect_list",
         "cordis_inspect_query", "cordis_inspect_self":
      self = .plugin
    default:
      self = .uncategorized
    }
  }
}

extension ToolDescriptor {
  /// Name-based guess for tools whose descriptor did not carry metadata.
  public static func inferredCategory(for name: String) -> ToolCategory {
    ToolCategory(name: name)
  }

  public static func isMutatingTool(_ name: String) -> Bool {
    switch name {
    case "write", "edit", "bash", "pwsh", "str_replace_editor", "terminal_send",
         "terminal_open", "terminal_close", "terminal_signal", "plugin_install",
         "plugin_uninstall", "plugin_toggle", "memoir_record", "memoir_update",
         "subagent", "subagent_fork", "ralph", "workflow", "spawn_teammate",
         "team_task_create", "team_task_update", "job_kill", "interrupt_agent",
         "send_message", "send_wechat", "dsh_im_return_file", "schedule_create",
         "schedule_delete", "cordis_run", "cordis_stop", "cordis_define", "cordis_undefine":
      return true
    default:
      return false
    }
  }
}

// MARK: - Tool invocations

/// One tool execution: the unit a tool card renders.
///
/// `parentCallID` and `programDescription` are what make the PTC tree expressible:
/// a nested `tools.read(...)` inside a program is an invocation whose parent is the
/// `run_code` invocation, not a sibling of it.
public struct ToolInvocation: Sendable, Equatable, Identifiable {
  public enum Status: String, Sendable, Codable {
    case pending
    case awaitingApproval
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
      switch self {
      case .succeeded, .failed, .cancelled: return true
      default: return false
      }
    }
  }

  public var id: String
  public var name: String
  /// Raw argument text exactly as received.
  public var argumentsText: String
  public var status: Status
  public var turn: Int?
  public var step: Int?
  public var startedAt: Date?
  public var endedAt: Date?
  public var outcome: ToolOutcome?
  /// Invocation that owns this one — set for PTC sub-calls.
  public var parentCallID: String?
  /// For a `run_code` invocation: the model's human-readable summary.
  public var programDescription: String?
  /// Approval request attached to this call, when the engine asked.
  public var approvalID: String?

  public init(
    id: String,
    name: String,
    argumentsText: String = "{}",
    status: Status = .pending,
    turn: Int? = nil,
    step: Int? = nil,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    outcome: ToolOutcome? = nil,
    parentCallID: String? = nil,
    programDescription: String? = nil,
    approvalID: String? = nil
  ) {
    self.id = id
    self.name = name
    self.argumentsText = argumentsText
    self.status = status
    self.turn = turn
    self.step = step
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.outcome = outcome
    self.parentCallID = parentCallID
    self.programDescription = programDescription
    self.approvalID = approvalID
  }

  public var arguments: JSONValue {
    (try? JSONValue.parse(argumentsText, context: "invocation.arguments")) ?? .object([:])
  }

  public var category: ToolCategory { ToolCategory(name: name) }

  public var duration: TimeInterval? {
    guard let startedAt, let endedAt else { return nil }
    return endedAt.timeIntervalSince(startedAt)
  }

  public var isProgrammatic: Bool { name == "run_code" || name == "workflow" || name == "ralph" }
}

/// What a tool produced.
public struct ToolOutcome: Sendable, Equatable {
  public var content: [ContentBlock]
  public var isError: Bool
  public var errorCode: String?
  public var errorName: String?
  public var duration: TimeInterval?

  public init(
    content: [ContentBlock],
    isError: Bool = false,
    errorCode: String? = nil,
    errorName: String? = nil,
    duration: TimeInterval? = nil
  ) {
    self.content = content
    self.isError = isError
    self.errorCode = errorCode
    self.errorName = errorName
    self.duration = duration
  }

  public var text: String { content.compactMap(\.textValue).joined() }

  public var attachments: [Attachment] {
    content.compactMap { block -> Attachment? in
      if case .image(let attachment) = block { return attachment }
      return nil
    }
  }

  public var shortErrorDescription: String? {
    guard isError else { return nil }
    if let errorName, let errorCode { return "\(errorName) (\(errorCode))" }
    return errorName ?? errorCode ?? "failed"
  }
}

// MARK: - PTC program tree

/// A `run_code` execution rendered as a program rather than as a card.
///
/// In PTC mode the model writes one TypeScript program and calls every capability
/// through `tools.name(args)`. The transcript therefore has to answer "what did the
/// program do" and "which of its calls failed" — not just "what did the tool return".
public struct ProgramRun: Sendable, Equatable, Identifiable {
  public enum Status: String, Sendable, Codable {
    case running
    case succeeded
    case failed
    case cancelled
  }

  /// The `run_code` invocation id.
  public var id: String
  public var description: String
  public var code: String
  public var status: Status
  /// Nested tool calls, in dispatch order.
  public var nodes: [ProgramNode]
  /// What the program printed or returned. Intermediate results are not in the
  /// transcript — only this.
  public var output: String?
  public var error: String?
  public var startedAt: Date?
  public var endedAt: Date?
  public var usage: Usage?

  public init(
    id: String,
    description: String = "",
    code: String = "",
    status: Status = .running,
    nodes: [ProgramNode] = [],
    output: String? = nil,
    error: String? = nil,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    usage: Usage? = nil
  ) {
    self.id = id
    self.description = description
    self.code = code
    self.status = status
    self.nodes = nodes
    self.output = output
    self.error = error
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.usage = usage
  }

  public var duration: TimeInterval? {
    guard let startedAt, let endedAt else { return nil }
    return endedAt.timeIntervalSince(startedAt)
  }

  public var failedNodeCount: Int { nodes.filter { $0.status == .failed }.count }

  /// Nested calls are numbered the way the transcript presents them: `3`, `3.1`, `3.1.1`.
  public func numberedNodes() -> [(index: String, node: ProgramNode)] {
    var counters: [Int: Int] = [:]
    var result: [(String, ProgramNode)] = []
    for node in nodes {
      let depth = node.depth
      counters[depth, default: 0] += 1
      for key in counters.keys where key > depth { counters[key] = 0 }
      let prefix = (0..<depth).compactMap { level -> String? in
        guard let value = counters[level], value > 0 else { return nil }
        return String(value)
      }
      let parts = prefix + [String(counters[depth] ?? 1)]
      result.append((parts.joined(separator: "."), node))
    }
    return result
  }
}

/// One nested tool call made by a program.
public struct ProgramNode: Sendable, Equatable, Identifiable {
  public var id: String
  public var toolName: String
  public var argumentsText: String
  public var status: ToolInvocation.Status
  /// 0 == called directly by the program body; 1+ == called by a nested helper.
  public var depth: Int
  public var parentNodeID: String?
  public var outcome: ToolOutcome?
  public var startedAt: Date?
  public var endedAt: Date?
  /// Set when the call was scheduled as a concurrent job by the runtime.
  public var jobID: String?

  public init(
    id: String,
    toolName: String,
    argumentsText: String = "{}",
    status: ToolInvocation.Status = .pending,
    depth: Int = 0,
    parentNodeID: String? = nil,
    outcome: ToolOutcome? = nil,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    jobID: String? = nil
  ) {
    self.id = id
    self.toolName = toolName
    self.argumentsText = argumentsText
    self.status = status
    self.depth = depth
    self.parentNodeID = parentNodeID
    self.outcome = outcome
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.jobID = jobID
  }

  public var arguments: JSONValue {
    (try? JSONValue.parse(argumentsText, context: "programNode.arguments")) ?? .object([:])
  }

  public var category: ToolCategory { ToolCategory(name: toolName) }
}

// MARK: - Tool availability

/// The capability surface of a running harness.
///
/// Two shapes, one type: `directTools` is what the model can call as tools, and
/// `programBindings` is the declared binding set inside a PTC program. A profile in
/// `mode: ptc` fills only `programBindings` plus the single `run_code` entry in
/// `directTools`.
public struct ToolSurface: Sendable, Equatable {
  public enum PresentationMode: String, Sendable, Codable {
    /// Every capability is a model-visible tool.
    case direct
    /// The model sees one program-execution tool; capabilities are bindings.
    case programmatic
    /// Both are offered.
    case both
  }

  public var mode: PresentationMode
  public var directTools: [ToolDescriptor]
  public var programBindings: [ToolDescriptor]
  /// The tool that executes programs (`run_code` in the shipped registry).
  public var programToolName: String?
  /// Language the embedded bindings are declared in (`typescript` in the observed profile).
  public var bindingLanguage: String?
  public var notes: String?

  public init(
    mode: PresentationMode,
    directTools: [ToolDescriptor] = [],
    programBindings: [ToolDescriptor] = [],
    programToolName: String? = nil,
    bindingLanguage: String? = nil,
    notes: String? = nil
  ) {
    self.mode = mode
    self.directTools = directTools
    self.programBindings = programBindings
    self.programToolName = programToolName
    self.bindingLanguage = bindingLanguage
    self.notes = notes
  }

  /// Every capability the harness can execute, regardless of how it is reached.
  public var allCapabilities: [ToolDescriptor] {
    var seen = Set<String>()
    var result: [ToolDescriptor] = []
    for descriptor in directTools + programBindings where !seen.contains(descriptor.name) {
      seen.insert(descriptor.name)
      result.append(descriptor)
    }
    return result
  }

  public func descriptor(named name: String) -> ToolDescriptor? {
    directTools.first { $0.name == name } ?? programBindings.first { $0.name == name }
  }

  public static let empty = ToolSurface(mode: .direct)
}
