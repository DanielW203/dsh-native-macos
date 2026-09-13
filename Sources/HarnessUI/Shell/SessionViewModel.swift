import Foundation
import HarnessKit
import SwiftUI

/// Panels the window can show beside the transcript.
public enum PanelKind: String, CaseIterable, Identifiable, Sendable {
  case todos
  case plan
  case agents
  case jobs
  case tools
  case goals
  case schedule
  case request

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .todos: return "Todos"
    case .plan: return "Plan"
    case .agents: return "Subagents"
    case .jobs: return "Jobs"
    case .tools: return "Tools"
    case .goals: return "Goals"
    case .schedule: return "Schedule"
    case .request: return "Request"
    }
  }

  public var symbolName: String {
    switch self {
    case .todos: return "checklist"
    case .plan: return "map"
    case .agents: return "person.2"
    case .jobs: return "gearshape.2"
    case .tools: return "wrench.and.screwdriver"
    case .goals: return "target"
    case .schedule: return "calendar.badge.clock"
    case .request: return "doc.text.magnifyingglass"
    }
  }
}

/// One open session: owns the event subscription and republishes the projection.
///
/// The projection is rebuilt incrementally — `SessionProjection.apply` folds one event
/// at a time — because a long session carries tens of thousands of events (one
/// measured session had 23,631 lines); reprojecting the whole list per delta would be
/// quadratic in the worst case.
@MainActor
public final class SessionViewModel: ObservableObject {
  public let engine: any HarnessEngine
  public let sessionID: SessionID
  public let cwd: String

  @Published public private(set) var projection: SessionProjection
  @Published public private(set) var isRunning = false
  @Published public var composerText: String = ""
  @Published public var pendingAttachments: [Attachment] = []
  @Published public var activePanels: Set<PanelKind> = []
  @Published public var errorMessage: String?
  /// Whether the transcript shows the program tree inline (`true`) or as a collapsed
  /// summary per program (`false`).
  @Published public var expandsPrograms = true
  /// Reasoning is hidden by default: 12,953 of a measured session's events were
  /// reasoning chunks, and showing them by default drowns the transcript.
  @Published public var showsReasoning = false

  private var subscription: Task<Void, Never>?
  private var eventBuffer: [SessionEvent] = []

  public init(engine: any HarnessEngine, sessionID: SessionID, cwd: String, initialProjection: SessionProjection? = nil) {
    self.engine = engine
    self.sessionID = sessionID
    self.cwd = cwd
    self.projection = initialProjection ?? SessionProjection(sessionID: sessionID)
  }

  deinit {
    subscription?.cancel()
  }

  // MARK: Lifecycle

  /// Begin consuming the session's event stream. Idempotent.
  public func start() {
    guard subscription == nil else { return }
    subscription = Task { [weak self] in
      guard let self else { return }
      for await event in self.engine.subscribe(self.sessionID) {
        if Task.isCancelled { return }
        self.apply(event)
      }
      self.isRunning = false
    }
  }

  public func stop() {
    subscription?.cancel()
    subscription = nil
  }

  private func apply(_ event: SessionEvent) {
    projection.apply(event)
    isRunning = projection.isBusy
  }

  /// Load history before subscribing, so the transcript is complete.
  public func loadHistory() async {
    var loaded = SessionProjection(sessionID: sessionID)
    var count = 0
    for await event in engine.events(sessionID) {
      loaded.apply(event)
      count += 1
      if count % 2_000 == 0 {
        // Keep the UI responsive while a long backlog streams in.
        projection = loaded
        await Task.yield()
      }
    }
    projection = loaded
  }

  // MARK: Derived state

  public var title: String { projection.title ?? sessionID.rawValue }

  public var messages: [ConversationMessage] { projection.messages }

  public var programs: [ProgramRun] { projection.programs }

  public var invocations: [ToolInvocation] { projection.invocations }

  public var pendingApprovals: [ApprovalRecord] { projection.pendingApprovals }

  public var pendingQuestions: [ApprovalRecord] { projection.pendingQuestions }

  public var activity: SessionActivity { projection.activity }

  public var isProgrammatic: Bool { projection.usesProgrammaticCalls }

  /// The transcript entries in render order: user and assistant messages interleaved
  /// with the tool work each produced.
  public var transcript: [TranscriptEntry] {
    TranscriptEntry.build(projection)
  }

  // MARK: Actions

  public func send() async {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
    let input = PromptInput(
      text: text,
      attachmentIDs: pendingAttachments.map(\.attachmentId),
      steer: isRunning
    )
    composerText = ""
    pendingAttachments = []
    await submit(input)
  }

  public func submit(_ input: PromptInput) async {
    do {
      try await engine.prompt(sessionID, input)
      errorMessage = nil
    } catch {
      errorMessage = (error as? HarnessError)?.errorDescription ?? String(describing: error)
    }
  }

  public func cancel() async {
    do {
      try await engine.cancel(sessionID)
    } catch {
      errorMessage = (error as? HarnessError)?.errorDescription ?? String(describing: error)
    }
  }

  public func respond(to approval: String, _ decision: ApprovalDecision) async {
    do {
      try await engine.respond(to: approval, decision)
      errorMessage = nil
    } catch {
      errorMessage = (error as? HarnessError)?.errorDescription ?? String(describing: error)
    }
  }

  public func approve(_ record: ApprovalRecord) async {
    await respond(to: record.id, ApprovalDecision(id: record.id, outcome: .approved))
  }

  public func deny(_ record: ApprovalRecord) async {
    await respond(to: record.id, ApprovalDecision(id: record.id, outcome: .denied))
  }

  public func answer(_ record: ApprovalRecord, answers: [String: QuestionAnswer]) async {
    await respond(to: record.id, ApprovalDecision(id: record.id, outcome: .answered(answers)))
  }

  public func reviewPlan(_ record: ApprovalRecord, approved: Bool, feedback: String? = nil) async {
    let outcome: ApprovalDecision.Outcome = approved ? .planApproved : .planKeptPlanning(feedback: feedback)
    await respond(to: record.id, ApprovalDecision(id: record.id, outcome: outcome))
  }

  public func togglePanel(_ kind: PanelKind) {
    if activePanels.contains(kind) { activePanels.remove(kind) } else { activePanels.insert(kind) }
  }
}

// MARK: - Transcript model

/// One row of the transcript.
///
/// Messages and tool work interleave, and in PTC mode a single assistant message can
/// own a whole program whose nodes each produced output — so the row carries both the
/// flat invocation and the program tree rather than the UI reconstructing the
/// relationship per render pass.
public enum TranscriptEntry: Identifiable, Sendable {
  case message(ConversationMessage)
  case invocation(ToolInvocation)
  case program(ProgramRun)
  case activityIndicator(SessionActivity)
  case notice(id: String, text: String)

  public var id: String {
    switch self {
    case .message(let message): return "msg:\(message.id)"
    case .invocation(let invocation): return "call:\(invocation.id)"
    case .program(let program): return "program:\(program.id)"
    case .activityIndicator(let activity): return "activity:\(activity.phase.rawValue)"
    case .notice(let id, _): return "notice:\(id)"
    }
  }

  /// Interleave messages with the tool work that belongs to them.
  ///
  /// Ordering rule: a tool invocation appears after the message that requested it,
  /// which is the order the events were produced in. Programs replace their own
  /// `run_code` invocation, so the same work is never drawn twice.
  public static func build(_ projection: SessionProjection) -> [TranscriptEntry] {
    var entries: [TranscriptEntry] = []
    let programIDs = Set(projection.programs.map(\.id))
    let nestedNodeIDs = Set(projection.programs.flatMap { $0.nodes.map(\.id) })

    // Merge by ascending sequence where known; unknown-sequence entries keep their
    // relative order at the end.
    struct Item {
      var seq: Int
      var order: Int
      var entry: TranscriptEntry
    }
    var items: [Item] = []
    var order = 0
    func append(_ entry: TranscriptEntry, seq: Int) {
      items.append(Item(seq: seq, order: order, entry: entry))
      order += 1
    }

    for message in projection.messages {
      append(.message(message), seq: message.seq ?? Int.max)
    }
    for invocation in projection.invocations where !programIDs.contains(invocation.id) {
      append(.invocation(invocation), seq: invocation.startedAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? Int.max)
    }
    for program in projection.programs {
      append(.program(program), seq: program.startedAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? Int.max)
    }
    _ = nestedNodeIDs

    items.sort { lhs, rhs in
      if lhs.seq == rhs.seq { return lhs.order < rhs.order }
      return lhs.seq < rhs.seq
    }
    entries = items.map(\.entry)

    // Trailing activity row while the turn is live.
    if projection.isBusy, !projection.streaming.isEmpty || !projection.messages.isEmpty {
      entries.append(.activityIndicator(projection.activity))
    }
    return entries
  }
}
