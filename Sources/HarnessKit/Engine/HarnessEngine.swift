import Foundation

/// Which implementation is driving the UI.
///
/// The whole point of the two-track plan: the SwiftUI layer is written once and
/// bound to this protocol, and both engines are swappable behind it — including at
/// runtime, so the same session can be rendered by either engine side by side.
public enum EngineKind: String, Sendable, Codable, CaseIterable, Identifiable {
  /// Route A — the official engine as a hidden subprocess behind a bridge plugin.
  case embedded
  /// Route B — the Swift re-implementation.
  case native

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .embedded: return "Embedded engine"
    case .native: return "Native engine"
    }
  }

  public var detail: String {
    switch self {
    case .embedded: return "Official harness running as a hidden subprocess"
    case .native: return "Swift re-implementation of the harness core"
    }
  }
}

/// What an engine can actually do.
///
/// The UI never assumes: it asks. Route A cannot be asked to rewind a session, and
/// route B may not yet implement a panel, so features are advertised rather than
/// inferred from `kind`.
public struct EngineCapabilities: Sendable, Equatable, OptionSetConvertible {
  public var canCreateSession: Bool
  public var canResumeSession: Bool
  public var canListSessions: Bool
  public var canDeleteSession: Bool
  public var canCancel: Bool
  public var canSteerWhileRunning: Bool
  public var canApprove: Bool
  public var canAskQuestions: Bool
  public var canReviewPlans: Bool
  public var canSpawnSubagents: Bool
  public var canRunWorkflows: Bool
  public var canListJobs: Bool
  public var canSchedule: Bool
  public var canSearchSessions: Bool
  public var canEditSystemPrompt: Bool
  public var canChooseModel: Bool
  /// Engine can execute PTC programs (`run_code`).
  public var canExecutePrograms: Bool
  /// Engine can enumerate the tool surface without a live session.
  public var canEnumerateTools: Bool
  /// Engine reads sessions written by the official runtime.
  public var readsOfficialSessions: Bool
  /// Engine writes sessions the official runtime can read.
  public var writesOfficialSessions: Bool

  public init(
    canCreateSession: Bool = true,
    canResumeSession: Bool = true,
    canListSessions: Bool = true,
    canDeleteSession: Bool = false,
    canCancel: Bool = true,
    canSteerWhileRunning: Bool = false,
    canApprove: Bool = true,
    canAskQuestions: Bool = true,
    canReviewPlans: Bool = true,
    canSpawnSubagents: Bool = false,
    canRunWorkflows: Bool = false,
    canListJobs: Bool = false,
    canSchedule: Bool = false,
    canSearchSessions: Bool = false,
    canEditSystemPrompt: Bool = false,
    canChooseModel: Bool = false,
    canExecutePrograms: Bool = false,
    canEnumerateTools: Bool = true,
    readsOfficialSessions: Bool = false,
    writesOfficialSessions: Bool = false
  ) {
    self.canCreateSession = canCreateSession
    self.canResumeSession = canResumeSession
    self.canListSessions = canListSessions
    self.canDeleteSession = canDeleteSession
    self.canCancel = canCancel
    self.canSteerWhileRunning = canSteerWhileRunning
    self.canApprove = canApprove
    self.canAskQuestions = canAskQuestions
    self.canReviewPlans = canReviewPlans
    self.canSpawnSubagents = canSpawnSubagents
    self.canRunWorkflows = canRunWorkflows
    self.canListJobs = canListJobs
    self.canSchedule = canSchedule
    self.canSearchSessions = canSearchSessions
    self.canEditSystemPrompt = canEditSystemPrompt
    self.canChooseModel = canChooseModel
    self.canExecutePrograms = canExecutePrograms
    self.canEnumerateTools = canEnumerateTools
    self.readsOfficialSessions = readsOfficialSessions
    self.writesOfficialSessions = writesOfficialSessions
  }

  public static let none = EngineCapabilities(
    canCreateSession: false,
    canResumeSession: false,
    canListSessions: false,
    canCancel: false,
    canApprove: false,
    canAskQuestions: false,
    canReviewPlans: false,
    canEnumerateTools: false
  )

  /// Everything the reference implementation supports — route A's target.
  public static let full = EngineCapabilities(
    canDeleteSession: true,
    canSteerWhileRunning: true,
    canSpawnSubagents: true,
    canRunWorkflows: true,
    canListJobs: true,
    canSchedule: true,
    canSearchSessions: true,
    canEditSystemPrompt: true,
    canChooseModel: true,
    canExecutePrograms: true,
    readsOfficialSessions: true,
    writesOfficialSessions: true
  )
}

/// Marker that lets `EngineCapabilities` be described generically without pulling in
/// `OptionSet` (the fields are heterogeneous, so a real OptionSet would need a
/// separate raw value type).
public protocol OptionSetConvertible {}

extension EngineCapabilities: CustomStringConvertible {
  public var description: String {
    var names: [String] = []
    if canCreateSession { names.append("create-session") }
    if canResumeSession { names.append("resume") }
    if canListSessions { names.append("list-sessions") }
    if canDeleteSession { names.append("delete-session") }
    if canCancel { names.append("cancel") }
    if canSteerWhileRunning { names.append("steer") }
    if canApprove { names.append("approve") }
    if canAskQuestions { names.append("questions") }
    if canReviewPlans { names.append("plan-review") }
    if canSpawnSubagents { names.append("subagents") }
    if canRunWorkflows { names.append("workflows") }
    if canListJobs { names.append("jobs") }
    if canSchedule { names.append("schedule") }
    if canSearchSessions { names.append("session-search") }
    if canEditSystemPrompt { names.append("system-prompt") }
    if canChooseModel { names.append("model-choice") }
    if canExecutePrograms { names.append("programs") }
    if canEnumerateTools { names.append("tool-enumeration") }
    if readsOfficialSessions { names.append("read-official-sessions") }
    if writesOfficialSessions { names.append("write-official-sessions") }
    return names.joined(separator: ",")
  }
}

// MARK: - Prompt input

/// One user turn.
public struct PromptInput: Sendable, Equatable {
  /// The typed text, including slash commands and `@` references verbatim.
  public var text: String
  /// Explicit references resolved by the composer (`@file`, `@session`).
  public var references: [Reference]
  /// Attachments by attachment id, already stored by the session store.
  public var attachmentIDs: [String]
  /// Whether this turn should be delivered while a turn is already running.
  public var steer: Bool

  public struct Reference: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
      case file
      case directory
      case session
      case symbol
      case skill
    }

    public var id: String { "\(kind.rawValue):\(value)" }
    public var kind: Kind
    public var value: String
    public var range: Range<Int>?

    public init(kind: Kind, value: String, range: Range<Int>? = nil) {
      self.kind = kind
      self.value = value
      self.range = range
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .file
      self.value = (try? container.decode(String.self, forKey: .value)) ?? ""
      self.range = nil
    }

    private enum CodingKeys: String, CodingKey { case kind, value }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(kind, forKey: .kind)
      try container.encode(value, forKey: .value)
    }
  }

  public init(text: String, references: [Reference] = [], attachmentIDs: [String] = [], steer: Bool = false) {
    self.text = text
    self.references = references
    self.attachmentIDs = attachmentIDs
    self.steer = steer
  }

  public static func text(_ text: String) -> PromptInput { PromptInput(text: text) }
}

// MARK: - Engine protocol

/// The seam between the UI and whichever engine drives it.
///
/// Everything above this line is written once; everything below is swappable.
/// Implementations must be safe to call from any task and must not block the main
/// actor: the UI calls these from `Task` contexts throughout.
public protocol HarnessEngine: AnyObject, Sendable {
  /// Identifies which implementation this is.
  var kind: EngineKind { get }

  /// Feature advertisement; call once at startup and cache.
  func capabilities() async -> EngineCapabilities

  /// Compact status for the title bar without loading any session.
  func status() async -> EngineStatus

  // MARK: Sessions

  func listSessions(limit: Int) async throws -> [SessionSummary]
  func createSession(cwd: String, preset: String?) async throws -> SessionID
  func resume(_ id: SessionID) async throws
  func close(_ id: SessionID) async throws
  func delete(_ id: SessionID) async throws

  /// Historical events for a session, oldest first. Route A reads them from the
  /// engine's stream; route B reads them from the session log directly.
  func events(_ id: SessionID) -> AsyncStream<SessionEvent>

  /// Live events for a running session, including the backlog.
  func subscribe(_ id: SessionID) -> AsyncStream<SessionEvent>

  // MARK: Turns

  func prompt(_ id: SessionID, _ input: PromptInput) async throws
  func cancel(_ id: SessionID) async throws

  // MARK: Interaction

  func respond(to approval: String, _ decision: ApprovalDecision) async throws

  // MARK: Capabilities

  func toolSurface() async throws -> ToolSurface
  func models() async throws -> [ModelOption]
}

/// A model the engine can route to.
public struct ModelOption: Sendable, Equatable, Identifiable, Codable {
  public var id: String
  public var provider: String
  public var displayName: String
  public var contextWindow: Int?
  public var supportsImages: Bool
  public var supportsReasoning: Bool
  public var reasoningEfforts: [String]

  public init(
    id: String,
    provider: String,
    displayName: String? = nil,
    contextWindow: Int? = nil,
    supportsImages: Bool = false,
    supportsReasoning: Bool = false,
    reasoningEfforts: [String] = []
  ) {
    self.id = "\(provider)/\(id)"
    self.provider = provider
    self.displayName = displayName ?? id
    self.contextWindow = contextWindow
    self.supportsImages = supportsImages
    self.supportsReasoning = supportsReasoning
    self.reasoningEfforts = reasoningEfforts
  }
}

/// Cheap engine-level status for the shell.
public struct EngineStatus: Sendable, Equatable {
  public var kind: EngineKind
  public var isReady: Bool
  public var detail: String?
  public var version: String?
  public var sessionCount: Int?
  public var cwd: String?
  /// How the engine reaches its tools — surfaced because it changes the UI mode.
  public var toolMode: ToolSurface.PresentationMode?
  /// Set when the engine is running but degraded (e.g. bridge unreachable).
  public var warning: String?

  public init(
    kind: EngineKind,
    isReady: Bool,
    detail: String? = nil,
    version: String? = nil,
    sessionCount: Int? = nil,
    cwd: String? = nil,
    toolMode: ToolSurface.PresentationMode? = nil,
    warning: String? = nil
  ) {
    self.kind = kind
    self.isReady = isReady
    self.detail = detail
    self.version = version
    self.sessionCount = sessionCount
    self.cwd = cwd
    self.toolMode = toolMode
    self.warning = warning
  }
}
