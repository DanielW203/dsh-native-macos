import Foundation

/// One row in the session browser.
public struct SessionSummary: Sendable, Equatable, Identifiable, Codable {
  public var id: SessionID
  public var title: String?
  public var cwd: String?
  public var createdAt: Date?
  public var updatedAt: Date?
  public var agentPreset: String?
  public var delegationDepth: Int?
  /// Bytes of the compressed log on disk — the browser shows this, and it is the
  /// reason the session reader never loads a whole log into one allocation.
  public var logBytes: Int?
  public var eventCount: Int?
  public var messageCount: Int?
  public var model: String?
  public var provider: String?
  /// The adapter-owned reasoning effort in force, when one is pinned. `nil` means the provider's
  /// own default, which is a different state from any named tier.
  public var reasoningEffort: String?
  public var parentID: SessionID?
  public var isLive: Bool
  /// Whether this session belongs to a subagent rather than to the human.
  ///
  /// Kept as its own flag because the two ways a harness says so are independent: a child carries
  /// the parent's id, while a session started as a subagent carries `origin: "subagent"` and may
  /// have no recorded parent at all. Anything that decides "is this the user's own work" needs
  /// both — a fan-out's sessions are exactly the ones that must not count as the user's activity.
  public var isSubagent: Bool

  public init(
    id: SessionID,
    title: String? = nil,
    cwd: String? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    agentPreset: String? = nil,
    delegationDepth: Int? = nil,
    logBytes: Int? = nil,
    eventCount: Int? = nil,
    messageCount: Int? = nil,
    model: String? = nil,
    provider: String? = nil,
    reasoningEffort: String? = nil,
    parentID: SessionID? = nil,
    isLive: Bool = false,
    isSubagent: Bool = false
  ) {
    self.id = id
    self.title = title
    self.cwd = cwd
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.agentPreset = agentPreset
    self.delegationDepth = delegationDepth
    self.logBytes = logBytes
    self.eventCount = eventCount
    self.messageCount = messageCount
    self.model = model
    self.provider = provider
    self.reasoningEffort = reasoningEffort
    self.parentID = parentID
    self.isLive = isLive
    self.isSubagent = isSubagent
  }

  /// What the browser shows as the row title.
  public var displayTitle: String {
    if let title, !title.isEmpty { return title }
    if let cwd, !cwd.isEmpty {
      return URL(fileURLWithPath: cwd).lastPathComponent
    }
    return id.rawValue
  }

  public var displayPath: String {
    guard let cwd, !cwd.isEmpty else { return "—" }
    return (cwd as NSString).abbreviatingWithTildeInPath
  }
}

/// What a session is doing right now — the difference between "idle session" and
/// "working session" is what the transcript spinner keys off.
public struct SessionActivity: Sendable, Equatable {
  public enum Phase: String, Sendable, Codable {
    case idle
    case waiting
    case thinking
    case runningTool
    case awaitingApproval
    case awaitingQuestion
    case reviewingPlan
    case finished

    public var displayName: String {
      switch self {
      case .idle: return "Idle"
      case .waiting: return "Waiting"
      case .thinking: return "Thinking"
      case .runningTool: return "Running tool"
      case .awaitingApproval: return "Awaiting approval"
      case .awaitingQuestion: return "Awaiting answer"
      case .reviewingPlan: return "Reviewing plan"
      case .finished: return "Finished"
      }
    }

    public var isBusy: Bool {
      switch self {
      case .thinking, .runningTool, .waiting: return true
      default: return false
      }
    }
  }

  public var phase: Phase
  public var detail: String?
  public var turn: Int?
  public var step: Int?

  public init(phase: Phase = .idle, detail: String? = nil, turn: Int? = nil, step: Int? = nil) {
    self.phase = phase
    self.detail = detail
    self.turn = turn
    self.step = step
  }

  public static let idle = SessionActivity()
}

/// A live, partial assistant turn.
///
/// The engine streams deltas (`assistant/chunk`, and the packed `text-chunks` /
/// `reasoning-chunks` / `tool-call-chunks` lines). The UI renders this *instead of*
/// re-rendering the transcript on every token, which is what keeps a 12,000-event
/// session responsive.
public struct StreamingState: Sendable, Equatable {
  public var turn: Int?
  public var step: Int?
  public var text: String
  public var reasoning: String
  /// Tool calls whose arguments are still arriving.
  public var pendingToolCalls: [PendingToolCall]
  public var latestUsage: Usage?

  public struct PendingToolCall: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var argumentsText: String
    public var index: Int?

    public init(id: String, name: String, argumentsText: String = "", index: Int? = nil) {
      self.id = id
      self.name = name
      self.argumentsText = argumentsText
      self.index = index
    }
  }

  public init(
    turn: Int? = nil,
    step: Int? = nil,
    text: String = "",
    reasoning: String = "",
    pendingToolCalls: [PendingToolCall] = [],
    latestUsage: Usage? = nil
  ) {
    self.turn = turn
    self.step = step
    self.text = text
    self.reasoning = reasoning
    self.pendingToolCalls = pendingToolCalls
    self.latestUsage = latestUsage
  }

  public static let empty = StreamingState()

  public var isEmpty: Bool {
    text.isEmpty && reasoning.isEmpty && pendingToolCalls.isEmpty
  }
}
