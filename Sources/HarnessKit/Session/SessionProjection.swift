import Foundation

/// Derived session state — everything the UI renders, computed from the event log
/// alone.
///
/// This type is deliberately engine-agnostic and deterministic: `project(events)`
/// must produce identical results for the same event list no matter which engine
/// produced it. That property is what makes differential conformance testable: the
/// same recorded session is replayed through both engines' projection paths and the
/// two results are compared field by field.
///
/// It also carries both shapes a turn can take. A session running in **PTC mode**
/// contains one `run_code` call whose *children* are the real tool calls, so the
/// projection keeps both `invocations` (flat, direct calls) and `programs` (nested
/// call trees). A UI that only knows how to draw one card per tool call cannot
/// represent a PTC turn at all.
public struct SessionProjection: Sendable, Equatable {
  // Identity
  public var sessionID: SessionID?
  public var header: SessionHeader?
  public var title: String?

  // Transcript
  public var messages: [ConversationMessage] = []
  public var streaming = StreamingState.empty

  // Tool activity
  public var invocations: [ToolInvocation] = []
  public var programs: [ProgramRun] = []

  // Panels
  public var todos: [TodoItem] = []
  public var plan = PlanState.inactive
  public var approvals: [ApprovalRecord] = []
  public var goals: [GoalRecord] = []
  public var agents: [AgentNode] = []
  public var jobs: [JobRecord] = []
  public var teamMembers: [TeamMember] = []
  public var teamTasks: [TeamTask] = []
  public var schedules: [ScheduleEntry] = []

  // Routing and policy
  public var model: String?
  public var provider: String?
  public var contextWindow: Int?
  public var permissionPreset: PermissionPreset?
  public var sandboxMode: SandboxMode?
  public var approvalPolicy: ApprovalPolicy?
  public var reasoningEffort: String?

  // Progress
  public var activity = SessionActivity.idle
  public var usage = Usage.zero
  public var currentTurn: Int?
  public var currentStep: Int?
  public var lastEventSeq: Int = -1
  public var eventCount: Int = 0
  /// Events this build could not interpret, kept for the diagnostics panel.
  public var unrecognizedEventTypes: [String: Int] = [:]
  /// The most recent `request/header` — the exact specification sent to the model.
  public var lastRequestHeader: RequestHeaderPayload?

  public init(sessionID: SessionID? = nil) {
    self.sessionID = sessionID
  }

  // MARK: Projection

  /// Project a whole event list.
  public static func project(_ events: [SessionEvent], sessionID: SessionID? = nil) -> SessionProjection {
    var projection = SessionProjection(sessionID: sessionID)
    for event in events { projection.apply(event) }
    return projection
  }

  /// Fold one event in.
  ///
  /// Every branch is written to be idempotent-safe: replaying a log twice must
  /// produce the same projection, so events that "replace" state (todos, plan mode,
  /// policy) overwrite rather than accumulate.
  public mutating func apply(_ event: SessionEvent) {
    eventCount += 1
    lastEventSeq = max(lastEventSeq, event.seq)

    switch event.kind {
    case .sessionHeader:
      if let header = event.header {
        self.header = header
        self.sessionID = self.sessionID ?? header.id
      }

    case .userMessage:
      if let message = event.userMessage { messages.append(message) }

    case .assistantMessage:
      if let message = event.assistantMessage {
        messages.append(message)
        if let messageUsage = message.usage { usage = usage + messageUsage }
        if let turn = message.turn { currentTurn = turn }
        if let step = message.step { currentStep = step }
      }
      // A finalized message ends the deltas that produced it.
      streaming.text = ""
      streaming.reasoning = ""
      streaming.pendingToolCalls = []

    case .assistantChunk:
      applyAssistantChunk(event)

    case .textChunk:
      // Packed line: `data.texts` is an array of deltas, `data.dt` their timings.
      let texts = event.data.array(at: "texts")?.compactMap(\.stringValue) ?? []
      streaming.text += texts.joined()
      streaming.turn = event.data.int(at: "turn") ?? streaming.turn
      streaming.step = event.data.int(at: "step") ?? streaming.step

    case .reasoningChunk:
      let texts = event.data.array(at: "texts")?.compactMap(\.stringValue) ?? []
      streaming.reasoning += texts.joined()
      streaming.turn = event.data.int(at: "turn") ?? streaming.turn
      streaming.step = event.data.int(at: "step") ?? streaming.step

    case .toolCallChunk:
      let args = event.data.array(at: "args")?.compactMap(\.stringValue) ?? []
      let id = event.data.string(at: "id") ?? "stream-\(event.seq)"
      let name = event.data.string(at: "name") ?? ""
      let index = event.data.int(at: "index")
      if let existing = streaming.pendingToolCalls.firstIndex(where: { $0.id == id }) {
        streaming.pendingToolCalls[existing].argumentsText += args.joined()
        if !name.isEmpty { streaming.pendingToolCalls[existing].name = name }
      } else {
        streaming.pendingToolCalls.append(
          StreamingState.PendingToolCall(id: id, name: name, argumentsText: args.joined(), index: index)
        )
      }

    case .toolCall:
      applyToolCall(event)

    case .toolResult:
      applyToolResult(event)

    case .ptcDispatchStart:
      if let dispatch = event.ptcDispatch, !dispatch.callId.isEmpty {
        openProgramNode(callID: dispatch.callId, toolName: dispatch.toolName ?? "", at: event.timestamp)
      }

    case .ptcDispatch:
      if let dispatch = event.ptcDispatch, !dispatch.callId.isEmpty {
        closeProgramNode(callID: dispatch.callId, at: event.timestamp)
      }

    case .turnStart:
      currentTurn = event.data.int(at: "turn") ?? currentTurn
      activity = SessionActivity(phase: .waiting, turn: currentTurn, step: currentStep)
      streaming = StreamingState(turn: currentTurn, step: currentStep)

    case .turnEnd:
      currentTurn = event.data.int(at: "turn") ?? currentTurn
      let reason = event.turnEndReason
      activity = SessionActivity(phase: .idle, detail: reason, turn: currentTurn)
      streaming = StreamingState.empty

    case .stepStart:
      currentStep = event.data.int(at: "step") ?? currentStep
      activity = SessionActivity(phase: .thinking, turn: currentTurn, step: currentStep)

    case .stepEnd:
      currentStep = event.data.int(at: "step") ?? currentStep

    case .requestContext:
      if let context = event.requestContext {
        contextWindow = context.contextWindow ?? contextWindow
        model = context.model ?? model
        provider = context.provider ?? provider
      }

    case .requestHeader:
      lastRequestHeader = event.requestHeader

    case .approvalAsked:
      guard let request = event.approvalAsked else { break }
      if let index = approvals.firstIndex(where: { $0.id == request.id }) {
        approvals[index].request = request
      } else {
        approvals.append(ApprovalRecord(request: request))
      }
      if request.kind == .question {
        activity = SessionActivity(phase: .awaitingQuestion, detail: request.toolName)
      } else if request.kind == .plan {
        activity = SessionActivity(phase: .reviewingPlan, detail: request.toolName)
      } else {
        activity = SessionActivity(phase: .awaitingApproval, detail: request.toolName)
        if let callId = request.callId, let index = invocations.firstIndex(where: { $0.id == callId }) {
          invocations[index].status = .awaitingApproval
          invocations[index].approvalID = request.id
        }
      }

    case .approvalDecided:
      guard let decision = event.approvalDecided else { break }
      if let index = approvals.firstIndex(where: { $0.id == decision.id }) {
        approvals[index].decision = decision
        switch decision.outcome {
        case .planApproved:
          plan.review = .approved
          plan.isActive = false
        case .planKeptPlanning:
          plan.review = .dismissed
        case .cancelled:
          plan.review = .cancelled
        default:
          break
        }
      }
      if let index = invocations.firstIndex(where: { $0.approvalID == decision.id }) {
        if case .denied = decision.outcome {
          invocations[index].status = .cancelled
        } else if invocations[index].status == .awaitingApproval {
          invocations[index].status = .pending
        }
      }
      if activity.phase == .awaitingApproval || activity.phase == .awaitingQuestion || activity.phase == .reviewingPlan {
        activity = SessionActivity(phase: .thinking, turn: currentTurn, step: currentStep)
      }

    case .approvalPolicy:
      approvalPolicy = ApprovalPolicy(event.data.string(at: "policy") ?? "")

    case .permissionPreset:
      permissionPreset = PermissionPreset(event.data.string(at: "preset") ?? "")

    case .sandboxMode:
      sandboxMode = SandboxMode(event.data.string(at: "mode") ?? "")

    case .planMode:
      plan.isActive = event.planModeActive ?? plan.isActive
      if plan.isActive && plan.review == .approved { plan.review = .none }

    case .todoWrite:
      if let items = event.todoWrite { todos = items }

    case .goalChange:
      applyGoalChange(event)

    case .sessionTitle:
      title = event.sessionTitle ?? title

    case .agentLifecycle:
      applyAgentEvent(event)

    case .jobLifecycle:
      applyJobEvent(event)

    case .teamChange:
      applyTeamEvent(event)

    case .scheduleChange:
      applyScheduleEvent(event)

    case .commandRun, .commandDone:
      // Slash commands appear as injected user messages; nothing extra to derive.
      break

    case .inboxSpliced:
      // Queued input merged into the running turn — the messages it splices are
      // already present as `user/message` events.
      break

    case .unknown(let type):
      unrecognizedEventTypes[type, default: 0] += 1
    }
  }

  // MARK: - Assistant chunks

  private mutating func applyAssistantChunk(_ event: SessionEvent) {
    let chunk = event.data.path("chunk")
    streaming.turn = event.data.int(at: "turn") ?? streaming.turn
    streaming.step = event.data.int(at: "step") ?? streaming.step
    if let chunkUsage = try? chunk?.path("usage")?.decoded(as: Usage.self) {
      streaming.latestUsage = chunkUsage
    }
    guard let chunk else { return }
    switch chunk.string(at: "type") {
    case "text":
      streaming.text += chunk.string(at: "text") ?? ""
      activity = SessionActivity(phase: .thinking, turn: streaming.turn, step: streaming.step)
    case "reasoning":
      streaming.reasoning += chunk.string(at: "text") ?? ""
      activity = SessionActivity(phase: .thinking, turn: streaming.turn, step: streaming.step)
    case "tool_call":
      let id = chunk.string(at: "id") ?? chunk.string(at: "block.id") ?? "chunk-\(event.seq)"
      let name = chunk.string(at: "name") ?? chunk.string(at: "block.name") ?? ""
      let delta = chunk.string(at: "argumentsDelta") ?? ""
      if let index = streaming.pendingToolCalls.firstIndex(where: { $0.id == id }) {
        streaming.pendingToolCalls[index].argumentsText += delta
        if !name.isEmpty { streaming.pendingToolCalls[index].name = name }
      } else {
        streaming.pendingToolCalls.append(
          StreamingState.PendingToolCall(id: id, name: name, argumentsText: delta, index: chunk.int(at: "index"))
        )
      }
      activity = SessionActivity(phase: .runningTool, detail: name, turn: streaming.turn, step: streaming.step)
    case "usage":
      if let chunkUsage = try? chunk.decoded(as: Usage.self) { streaming.latestUsage = chunkUsage }
    default:
      break
    }
  }

  // MARK: - Tool calls

  private mutating func applyToolCall(_ event: SessionEvent) {
    guard let call = event.toolCall else { return }
    currentTurn = call.turn ?? currentTurn
    currentStep = call.step ?? currentStep

    // A `run_code` call opens a program. Every later call until its result closes
    // is one of its children — that is the PTC nesting rule.
    if call.name == "run_code" {
      let description = call.parsedArguments.string(at: "description") ?? ""
      let code = call.parsedArguments.string(at: "code") ?? ""
      if let index = programs.firstIndex(where: { $0.id == call.callId }) {
        programs[index].code = code
        programs[index].description = description
        programs[index].status = .running
      } else {
        programs.append(
          ProgramRun(
            id: call.callId,
            description: description,
            code: code,
            status: .running,
            startedAt: call.time ?? event.timestamp
          )
        )
      }
      openPrograms.append(call.callId)
      openProgramNodeStack.append(OpenFrame(programID: call.callId, nodeID: nil))
      activity = SessionActivity(phase: .runningTool, detail: description.isEmpty ? "run_code" : description)
      return
    }

    if let programID = openPrograms.last {
      // Nested call inside a program.
      let parent = openProgramNodeStack.last(where: { $0.programID == programID })?.nodeID
      let depth = openProgramNodeStack.filter { $0.programID == programID && $0.nodeID != nil }.count
      let node = ProgramNode(
        id: call.callId,
        toolName: call.name,
        argumentsText: call.arguments,
        status: .running,
        depth: depth,
        parentNodeID: parent,
        startedAt: call.time ?? event.timestamp
      )
      appendNode(node, toProgram: programID)
      openProgramNodeStack.append(OpenFrame(programID: programID, nodeID: call.callId))
      activity = SessionActivity(phase: .runningTool, detail: call.name)
      return
    }

    let invocation = ToolInvocation(
      id: call.callId,
      name: call.name,
      argumentsText: call.arguments,
      status: .running,
      turn: call.turn,
      step: call.step,
      startedAt: call.time ?? event.timestamp,
      programDescription: nil
    )
    if let index = invocations.firstIndex(where: { $0.id == call.callId }) {
      invocations[index] = invocation
    } else {
      invocations.append(invocation)
    }
    activity = SessionActivity(phase: .runningTool, detail: call.name)
  }

  private mutating func applyToolResult(_ event: SessionEvent) {
    guard let result = event.toolResult else { return }
    let outcome = ToolOutcome(
      content: result.content,
      isError: result.isError,
      errorCode: result.errorCode,
      errorName: result.errorName,
      duration: nil
    )

    // Program result?
    if let index = programs.firstIndex(where: { $0.id == result.callId }) {
      programs[index].status = result.isError ? .failed : .succeeded
      programs[index].output = result.text
      programs[index].error = result.isError ? (result.errorName ?? result.errorCode ?? "failed") : nil
      programs[index].endedAt = event.timestamp ?? result.time
      if let index = openPrograms.lastIndex(of: result.callId) { openPrograms.remove(at: index) }
      openProgramNodeStack.removeAll { $0.programID == result.callId }
      activity = SessionActivity(phase: .thinking)
      return
    }

    // Nested node result?
    for programIndex in programs.indices {
      if let nodeIndex = programs[programIndex].nodes.firstIndex(where: { $0.id == result.callId }) {
        programs[programIndex].nodes[nodeIndex].status = result.isError ? .failed : .succeeded
        programs[programIndex].nodes[nodeIndex].outcome = outcome
        programs[programIndex].nodes[nodeIndex].endedAt = event.timestamp ?? result.time
        // Pop the node stack back to its parent.
        if let stackIndex = openProgramNodeStack.lastIndex(where: { $0.nodeID == result.callId }) {
          openProgramNodeStack.removeSubrange(stackIndex...)
        }
        activity = SessionActivity(phase: .thinking)
        return
      }
    }

    // Direct invocation.
    if let index = invocations.firstIndex(where: { $0.id == result.callId }) {
      invocations[index].status = result.isError ? .failed : .succeeded
      invocations[index].outcome = outcome
      invocations[index].endedAt = event.timestamp ?? result.time
    } else {
      // A result with no observed call (log started mid-turn): keep it visible.
      invocations.append(
        ToolInvocation(
          id: result.callId.isEmpty ? "orphan-\(event.seq)" : result.callId,
          name: result.kind ?? "unknown",
          status: result.isError ? .failed : .succeeded,
          endedAt: event.timestamp ?? result.time,
          outcome: outcome
        )
      )
    }
    activity = SessionActivity(phase: .thinking)
  }

  private mutating func appendNode(_ node: ProgramNode, toProgram programID: String) {
    guard let index = programs.firstIndex(where: { $0.id == programID }) else { return }
    if let existing = programs[index].nodes.firstIndex(where: { $0.id == node.id }) {
      programs[index].nodes[existing] = node
    } else {
      programs[index].nodes.append(node)
    }
  }

  private mutating func openProgramNode(callID: String, toolName: String, at time: Date?) {
    guard let programID = openPrograms.last else { return }
    if let index = programs.firstIndex(where: { $0.id == programID }),
       let existing = programs[index].nodes.firstIndex(where: { $0.id == callID }) {
      if !toolName.isEmpty { programs[index].nodes[existing].toolName = toolName }
      return
    }
    let parent = openProgramNodeStack.last(where: { $0.programID == programID })?.nodeID
    let depth = openProgramNodeStack.filter { $0.programID == programID && $0.nodeID != nil }.count
    appendNode(
      ProgramNode(
        id: callID,
        toolName: toolName,
        status: .running,
        depth: depth,
        parentNodeID: parent,
        startedAt: time
      ),
      toProgram: programID
    )
    openProgramNodeStack.append(OpenFrame(programID: programID, nodeID: callID))
  }

  private mutating func closeProgramNode(callID: String, at time: Date?) {
    for programIndex in programs.indices {
      if let nodeIndex = programs[programIndex].nodes.firstIndex(where: { $0.id == callID }) {
        if programs[programIndex].nodes[nodeIndex].endedAt == nil {
          programs[programIndex].nodes[nodeIndex].endedAt = time
        }
        if programs[programIndex].nodes[nodeIndex].status == .running {
          programs[programIndex].nodes[nodeIndex].status = .succeeded
        }
      }
    }
    if let stackIndex = openProgramNodeStack.lastIndex(where: { $0.nodeID == callID }) {
      openProgramNodeStack.removeSubrange(stackIndex...)
    }
  }

  /// One open frame of the PTC call tree. `nodeID == nil` marks the program's own
  /// frame, which is what makes nesting depth computable.
  private struct OpenFrame: Sendable, Equatable {
    var programID: String
    var nodeID: String?
  }

  /// Programs currently executing (used to route later calls into them).
  private var openPrograms: [String] = []
  /// Open frames of the PTC call tree.
  private var openProgramNodeStack: [OpenFrame] = []

  // MARK: - Panels

  private mutating func applyGoalChange(_ event: SessionEvent) {
    let change = event.data.path("goal") ?? event.data
    guard let id = change.string(at: "id") ?? change.string(at: "goalId") else { return }
    let record = GoalRecord(
      id: id,
      title: change.string(at: "title") ?? "",
      objective: change.string(at: "objective") ?? "",
      phase: GoalRecord.Phase(rawValue: change.string(at: "phase") ?? "active") ?? .active,
      revision: change.int(at: "revision"),
      roundsStarted: change.int(at: "roundsStarted"),
      maxGoalRounds: change.int(at: "maxGoalRounds"),
      blockedReason: change.string(at: "blockedReason"),
      continuationArmed: change.bool(at: "continuationArmed")
    )
    if let index = goals.firstIndex(where: { $0.id == id }) {
      goals[index] = record
    } else {
      goals.append(record)
    }
  }

  private mutating func applyAgentEvent(_ event: SessionEvent) {
    guard let id = event.data.string(at: "id") ?? event.data.string(at: "sessionId") else { return }
    let sessionID = SessionID(id)
    let status: AgentNode.Status = event.type == .agentClosed ? .finished : .running
    if let index = agents.firstIndex(where: { $0.id == sessionID }) {
      agents[index].status = status
      if status == .finished { agents[index].endedAt = event.timestamp }
    } else {
      agents.append(
        AgentNode(
          id: sessionID,
          label: event.data.string(at: "label") ?? event.data.string(at: "agentType") ?? id,
          parentID: event.data.string(at: "parentId").map { SessionID($0) },
          depth: event.data.int(at: "depth") ?? 0,
          status: status,
          agentType: event.data.string(at: "agentType"),
          model: event.data.string(at: "model"),
          provider: event.data.string(at: "provider"),
          startedAt: event.timestamp
        )
      )
    }
  }

  private mutating func applyJobEvent(_ event: SessionEvent) {
    guard let id = event.data.string(at: "id") ?? event.data.string(at: "jobId") else { return }
    let status: JobRecord.Status = event.type == .jobFinished
      ? (JobRecord.Status(rawValue: event.data.string(at: "status") ?? "finished") ?? .finished)
      : .running
    let record = JobRecord(
      id: id,
      kind: JobRecord.Kind(rawValue: event.data.string(at: "kind") ?? "command") ?? .unknown,
      status: status,
      label: event.data.string(at: "label") ?? event.data.string(at: "description") ?? id,
      command: event.data.string(at: "command"),
      startedAt: event.type == .jobStarted ? event.timestamp : nil,
      endedAt: event.type == .jobFinished ? event.timestamp : nil,
      tail: event.data.string(at: "tail"),
      sessionID: event.data.string(at: "sessionId").map { SessionID($0) }
    )
    if let index = jobs.firstIndex(where: { $0.id == id }) {
      jobs[index].status = record.status
      jobs[index].endedAt = record.endedAt ?? jobs[index].endedAt
      jobs[index].tail = record.tail ?? jobs[index].tail
    } else {
      jobs.append(record)
    }
  }

  private mutating func applyTeamEvent(_ event: SessionEvent) {
    switch event.type {
    case .teamMember:
      guard let id = event.data.string(at: "id") ?? event.data.string(at: "memberId") else { return }
      let member = TeamMember(
        id: id,
        sessionID: event.data.string(at: "sessionId").map { SessionID($0) },
        name: event.data.string(at: "name") ?? id,
        role: event.data.string(at: "role"),
        status: AgentNode.Status(rawValue: event.data.string(at: "status") ?? "running") ?? .running,
        joinedAt: event.timestamp
      )
      if let index = teamMembers.firstIndex(where: { $0.id == id }) {
        teamMembers[index] = member
      } else {
        teamMembers.append(member)
      }
    case .teamTask:
      guard let id = event.data.string(at: "id") ?? event.data.string(at: "taskId") else { return }
      let task = TeamTask(
        id: id,
        title: event.data.string(at: "title") ?? id,
        detail: event.data.string(at: "detail"),
        status: TeamTask.Status(rawValue: event.data.string(at: "status") ?? "pending") ?? .pending,
        owner: event.data.string(at: "owner"),
        dependsOn: event.data.array(at: "dependsOn")?.compactMap(\.stringValue) ?? [],
        updatedAt: event.timestamp
      )
      if let index = teamTasks.firstIndex(where: { $0.id == id }) {
        teamTasks[index] = task
      } else {
        teamTasks.append(task)
      }
    default:
      break
    }
  }

  private mutating func applyScheduleEvent(_ event: SessionEvent) {
    guard let id = event.data.string(at: "id") ?? event.data.string(at: "scheduleId") else { return }
    if event.data.string(at: "action") == "delete" {
      schedules.removeAll { $0.id == id }
      return
    }
    let entry = ScheduleEntry(
      id: id,
      prompt: event.data.string(at: "prompt") ?? "",
      trigger: .afterSeconds(event.data.path("afterSeconds")?.doubleValue ?? 0),
      sessionID: event.data.string(at: "sessionId").map { SessionID($0) },
      nextFireAt: event.data.path("nextFireAt")?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) },
      createdAt: event.timestamp
    )
    if let index = schedules.firstIndex(where: { $0.id == id }) {
      schedules[index] = entry
    } else {
      schedules.append(entry)
    }
  }

  // MARK: - Derived

  /// Invocations that are not nested inside a program.
  public var topLevelInvocations: [ToolInvocation] {
    invocations
  }

  /// Pending approvals, newest first — what the approval sheet lists.
  public var pendingApprovals: [ApprovalRecord] {
    approvals.filter(\.isPending).reversed()
  }

  public var pendingQuestions: [ApprovalRecord] {
    approvals.filter { $0.isPending && $0.request.kind == .question }.reversed()
  }

  public var isBusy: Bool {
    activity.phase.isBusy
  }

  /// Count of tool calls that actually executed, including nested program calls.
  public var toolCallCount: Int {
    invocations.count + programs.reduce(0) { $0 + $1.nodes.count }
  }

  /// Total number of direct tools the model invoked this session (for stats panes).
  public var directCallCount: Int { invocations.count }

  public var programmaticCallCount: Int {
    programs.reduce(0) { $0 + $1.nodes.count }
  }

  /// Does this session use the programmatic presentation mode?
  public var usesProgrammaticCalls: Bool { !programs.isEmpty }

  /// The most recent activity for the session list row.
  public var lastMessagePreview: String? {
    for message in messages.reversed() where message.role == .assistant {
      let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { return text }
      if let firstTool = message.toolUses.first { return "→ \(firstTool.name)" }
    }
    return messages.last?.text
  }
}
