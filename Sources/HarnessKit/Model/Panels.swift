import Foundation

// MARK: - Todos

/// One checklist row from `todo/write`.
public struct TodoItem: Sendable, Equatable, Identifiable, Codable {
  public enum Status: String, Sendable, Codable, CaseIterable {
    case pending
    case in_progress
    case completed

    public var displayName: String {
      switch self {
      case .pending: return "Pending"
      case .in_progress: return "In progress"
      case .completed: return "Completed"
      }
    }

    public var symbolName: String {
      switch self {
      case .pending: return "circle"
      case .in_progress: return "circle.dotted"
      case .completed: return "checkmark.circle.fill"
      }
    }
  }

  public var id: String
  public var content: String
  public var status: Status
  /// Present tense form the runtime uses while the item is active.
  public var activeForm: String?

  public init(id: String = UUID().uuidString, content: String, status: Status = .pending, activeForm: String? = nil) {
    self.id = id
    self.content = content
    self.status = status
    self.activeForm = activeForm
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.content = (try? container.decode(String.self, forKey: .content)) ?? ""
    self.status = (try? container.decode(Status.self, forKey: .status)) ?? .pending
    self.activeForm = try? container.decodeIfPresent(String.self, forKey: .activeForm)
    self.id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? content
  }

  private enum CodingKeys: String, CodingKey { case id, content, status, activeForm }

  /// The text to show: `activeForm` while running, otherwise `content`.
  public var displayText: String {
    if status == .in_progress, let activeForm, !activeForm.isEmpty { return activeForm }
    return content
  }
}

// MARK: - Plan mode

/// Plan-mode state, driven by `plan/mode` plus the plan review outcome.
public struct PlanState: Sendable, Equatable {
  public enum Review: String, Sendable, Codable {
    case none
    case presented
    case approved
    case dismissed
    case cancelled

    public var displayName: String {
      switch self {
      case .none: return "Not reviewing"
      case .presented: return "Awaiting review"
      case .approved: return "Approved"
      case .dismissed: return "Kept planning"
      case .cancelled: return "Cancelled"
      }
    }
  }

  public var isActive: Bool
  /// The plan text the model submitted through `exit_plan_mode`.
  public var plan: String?
  public var review: Review
  public var presentedAt: Date?

  public init(isActive: Bool = false, plan: String? = nil, review: Review = .none, presentedAt: Date? = nil) {
    self.isActive = isActive
    self.plan = plan
    self.review = review
    self.presentedAt = presentedAt
  }

  public static let inactive = PlanState()
}

// MARK: - Approvals

/// An approval the engine is waiting on. The product must answer these or the run
/// stalls, so they are surfaced as modal/priority UI rather than as transcript rows.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Codable {
    /// A tool call needs a yes/no before it runs.
    case tool
    /// The model asked the human a question (`ask_user_question`).
    case question
    /// The model submitted a plan for review (`exit_plan_mode`).
    case plan
  }

  public var id: String
  public var toolName: String
  public var callId: String?
  public var reason: String
  public var requestedAt: Date?
  public var kind: Kind
  /// For `.question`: the questions and their options.
  public var questions: [UserQuestion]

  public init(
    id: String,
    toolName: String,
    callId: String? = nil,
    reason: String = "",
    requestedAt: Date? = nil,
    kind: Kind = .tool,
    questions: [UserQuestion] = []
  ) {
    self.id = id
    self.toolName = toolName
    self.callId = callId
    self.reason = reason
    self.requestedAt = requestedAt
    self.kind = kind
    self.questions = questions
  }
}

/// A question inside `ask_user_question`.
public struct UserQuestion: Sendable, Equatable, Identifiable, Codable {
  public var id: String
  public var question: String
  public var header: String?
  public var options: [Option]
  public var multiSelect: Bool

  public struct Option: Sendable, Equatable, Codable, Identifiable {
    public var label: String
    public var description: String?
    public var id: String { label }

    public init(label: String, description: String? = nil) {
      self.label = label
      self.description = description
    }
  }

  public init(id: String, question: String, header: String? = nil, options: [Option] = [], multiSelect: Bool = false) {
    self.id = id
    self.question = question
    self.header = header
    self.options = options
    self.multiSelect = multiSelect
  }
}

/// How an approval was settled.
public struct ApprovalDecision: Sendable, Equatable, Identifiable {
  public enum Outcome: Sendable, Equatable {
    case approved
    case denied
    /// A human answer to a question, keyed by question id.
    case answered([String: QuestionAnswer])
    /// A plan review verdict.
    case planApproved
    case planKeptPlanning(feedback: String?)
    case cancelled
    case unknown(String)

    public init(rawValue: String) {
      switch rawValue {
      case "approved", "approve", "allow": self = .approved
      case "denied", "deny", "reject": self = .denied
      case "cancelled", "canceled": self = .cancelled
      default: self = .unknown(rawValue)
      }
    }

    public var rawValue: String {
      switch self {
      case .approved: return "approved"
      case .denied: return "denied"
      case .answered: return "answered"
      case .planApproved: return "plan-approved"
      case .planKeptPlanning: return "plan-kept-planning"
      case .cancelled: return "cancelled"
      case .unknown(let raw): return raw
      }
    }
  }

  public var id: String
  public var outcome: Outcome
  public var decidedAt: Date?

  public init(id: String, outcome: Outcome, decidedAt: Date? = nil) {
    self.id = id
    self.outcome = outcome
    self.decidedAt = decidedAt
  }

  public var displayName: String {
    switch outcome {
    case .approved: return "Approved"
    case .denied: return "Denied"
    case .answered: return "Answered"
    case .planApproved: return "Plan approved"
    case .planKeptPlanning: return "Kept planning"
    case .cancelled: return "Cancelled"
    case .unknown(let raw): return raw
    }
  }
}

/// One answer to one question.
public struct QuestionAnswer: Sendable, Equatable, Codable {
  public var selected: [String]
  public var freeText: String?

  public init(selected: [String] = [], freeText: String? = nil) {
    self.selected = selected
    self.freeText = freeText
  }
}

/// An approval with its lifecycle folded in — what the UI lists.
public struct ApprovalRecord: Sendable, Equatable, Identifiable {
  public var request: ApprovalRequest
  public var decision: ApprovalDecision?

  public var id: String { request.id }
  public var isPending: Bool { decision == nil }

  public init(request: ApprovalRequest, decision: ApprovalDecision? = nil) {
    self.request = request
    self.decision = decision
  }
}

// MARK: - Permission and sandbox

/// What the harness is allowed to do without asking.
public struct PermissionPreset: Sendable, Equatable, RawRepresentable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }

  public static let readOnly = PermissionPreset("read-only")
  public static let workspaceWrite = PermissionPreset("workspace-write")
  public static let dangerFullAccess = PermissionPreset("danger-full-access")

  public var displayName: String {
    switch self {
    case .readOnly: return "Read only"
    case .workspaceWrite: return "Workspace write"
    case .dangerFullAccess: return "Full access"
    default: return rawValue
    }
  }

  public var symbolName: String {
    switch self {
    case .readOnly: return "eye"
    case .workspaceWrite: return "folder.badge.gearshape"
    case .dangerFullAccess: return "exclamationmark.shield"
    default: return "shield"
    }
  }
}

/// Filesystem sandbox mode.
public struct SandboxMode: Sendable, Equatable, RawRepresentable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }

  public static let strict = SandboxMode("strict")
  public static let workspaceWrite = SandboxMode("workspace-write")
  public static let off = SandboxMode("off")

  public var displayName: String {
    switch self {
    case .strict: return "Strict"
    case .workspaceWrite: return "Workspace write"
    case .off: return "Disabled"
    default: return rawValue
    }
  }
}

/// Whether the engine asks before acting.
public struct ApprovalPolicy: Sendable, Equatable, RawRepresentable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }

  public static let ask = ApprovalPolicy("ask")
  public static let never = ApprovalPolicy("never")
  public static let always = ApprovalPolicy("always")

  public var displayName: String {
    switch self {
    case .ask: return "Ask"
    case .never: return "Never ask"
    case .always: return "Always ask"
    default: return rawValue
    }
  }
}

// MARK: - Goals

/// A persisted completion objective, from `goal/change` and the goal tools.
public struct GoalRecord: Sendable, Equatable, Identifiable, Codable {
  public enum Phase: String, Sendable, Codable {
    case active
    case paused
    case completed
    case blocked

    public var displayName: String { rawValue.capitalized }

    public var symbolName: String {
      switch self {
      case .active: return "target"
      case .paused: return "pause.circle"
      case .completed: return "checkmark.seal"
      case .blocked: return "exclamationmark.octagon"
      }
    }
  }

  public var id: String
  public var title: String
  public var objective: String
  public var phase: Phase
  public var revision: Int?
  public var roundsStarted: Int?
  public var maxGoalRounds: Int?
  public var blockedReason: String?
  public var continuationArmed: Bool?

  public init(
    id: String,
    title: String = "",
    objective: String,
    phase: Phase = .active,
    revision: Int? = nil,
    roundsStarted: Int? = nil,
    maxGoalRounds: Int? = nil,
    blockedReason: String? = nil,
    continuationArmed: Bool? = nil
  ) {
    self.id = id
    self.title = title
    self.objective = objective
    self.phase = phase
    self.revision = revision
    self.roundsStarted = roundsStarted
    self.maxGoalRounds = maxGoalRounds
    self.blockedReason = blockedReason
    self.continuationArmed = continuationArmed
  }

  public var progress: Double? {
    guard let roundsStarted, let maxGoalRounds, maxGoalRounds > 0 else { return nil }
    return min(1, Double(roundsStarted) / Double(maxGoalRounds))
  }
}

// MARK: - Agents

/// One node of the subagent tree.
///
/// The harness's delegation is a tree of sessions, not a flat list: a child can
/// delegate further, and the UI shows depth. `status` distinguishes a live child
/// from one that is resumable-but-idle, which is a real distinction in the runtime.
public struct AgentNode: Sendable, Equatable, Identifiable {
  public enum Status: String, Sendable, Codable {
    case running
    case idle
    case ready
    case finished
    case failed
    case killed

    public var displayName: String {
      switch self {
      case .running: return "Running"
      case .idle: return "Idle"
      case .ready: return "Ready"
      case .finished: return "Finished"
      case .failed: return "Failed"
      case .killed: return "Killed"
      }
    }

    public var symbolName: String {
      switch self {
      case .running: return "circle.fill"
      case .idle: return "circle.dotted"
      case .ready: return "circle"
      case .finished: return "checkmark.circle"
      case .failed: return "xmark.circle"
      case .killed: return "slash.circle"
      }
    }

    public var isLive: Bool { self == .running || self == .idle }
  }

  public var id: SessionID
  public var label: String
  public var parentID: SessionID?
  public var depth: Int
  public var status: Status
  public var agentType: String?
  public var model: String?
  public var provider: String?
  public var startedAt: Date?
  public var endedAt: Date?
  public var lastMessage: String?
  public var toolCallCount: Int

  public init(
    id: SessionID,
    label: String,
    parentID: SessionID? = nil,
    depth: Int = 0,
    status: Status = .running,
    agentType: String? = nil,
    model: String? = nil,
    provider: String? = nil,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    lastMessage: String? = nil,
    toolCallCount: Int = 0
  ) {
    self.id = id
    self.label = label
    self.parentID = parentID
    self.depth = depth
    self.status = status
    self.agentType = agentType
    self.model = model
    self.provider = provider
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.lastMessage = lastMessage
    self.toolCallCount = toolCallCount
  }

  public var children: [AgentNode] = []
}

// MARK: - Jobs

/// A background job: a backgrounded shell command, a PTY send, or a subagent.
public struct JobRecord: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Codable {
    case command
    case terminal
    case subagent
    case workflow
    case unknown
  }

  public enum Status: String, Sendable, Codable {
    case running
    case finished
    case failed
    case killed

    public var displayName: String { rawValue.capitalized }

    public var symbolName: String {
      switch self {
      case .running: return "arrow.triangle.2.circlepath"
      case .finished: return "checkmark.circle"
      case .failed: return "xmark.circle"
      case .killed: return "stop.circle"
      }
    }
  }

  public var id: String
  public var kind: Kind
  public var status: Status
  public var label: String
  public var command: String?
  public var startedAt: Date?
  public var endedAt: Date?
  public var tail: String?
  public var sessionID: SessionID?

  public init(
    id: String,
    kind: Kind = .command,
    status: Status = .running,
    label: String = "",
    command: String? = nil,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    tail: String? = nil,
    sessionID: SessionID? = nil
  ) {
    self.id = id
    self.kind = kind
    self.status = status
    self.label = label
    self.command = command
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.tail = tail
    self.sessionID = sessionID
  }
}

// MARK: - Teams

/// A member of an agent team.
public struct TeamMember: Sendable, Equatable, Identifiable {
  public var id: String
  public var sessionID: SessionID?
  public var name: String
  public var role: String?
  public var status: AgentNode.Status
  public var joinedAt: Date?

  public init(
    id: String,
    sessionID: SessionID? = nil,
    name: String,
    role: String? = nil,
    status: AgentNode.Status = .running,
    joinedAt: Date? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.name = name
    self.role = role
    self.status = status
    self.joinedAt = joinedAt
  }
}

/// A shared team task.
public struct TeamTask: Sendable, Equatable, Identifiable {
  public enum Status: String, Sendable, Codable, CaseIterable {
    case pending
    case claimed
    case in_progress
    case blocked
    case completed
    case failed

    public var displayName: String {
      switch self {
      case .pending: return "Pending"
      case .claimed: return "Claimed"
      case .in_progress: return "In progress"
      case .blocked: return "Blocked"
      case .completed: return "Completed"
      case .failed: return "Failed"
      }
    }
  }

  public var id: String
  public var title: String
  public var detail: String?
  public var status: Status
  public var owner: String?
  public var dependsOn: [String]
  public var createdAt: Date?
  public var updatedAt: Date?

  public init(
    id: String,
    title: String,
    detail: String? = nil,
    status: Status = .pending,
    owner: String? = nil,
    dependsOn: [String] = [],
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.status = status
    self.owner = owner
    self.dependsOn = dependsOn
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

// MARK: - Schedules

/// A scheduled prompt delivery.
public struct ScheduleEntry: Sendable, Equatable, Identifiable {
  public enum Trigger: Sendable, Equatable {
    case afterSeconds(Double)
    case at(Date)
    case everySeconds(Double)
  }

  public var id: String
  public var prompt: String
  public var trigger: Trigger
  public var sessionID: SessionID?
  public var nextFireAt: Date?
  public var createdAt: Date?

  public init(
    id: String,
    prompt: String,
    trigger: Trigger,
    sessionID: SessionID? = nil,
    nextFireAt: Date? = nil,
    createdAt: Date? = nil
  ) {
    self.id = id
    self.prompt = prompt
    self.trigger = trigger
    self.sessionID = sessionID
    self.nextFireAt = nextFireAt
    self.createdAt = createdAt
  }

  public var displayTrigger: String {
    switch trigger {
    case .afterSeconds(let seconds): return "in \(Int(seconds))s"
    case .at(let date): return "at \(date.formatted(date: .abbreviated, time: .shortened))"
    case .everySeconds(let seconds): return "every \(Int(seconds))s"
    }
  }
}
