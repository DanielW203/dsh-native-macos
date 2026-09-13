import HarnessKit
import SwiftUI

/// The inspector: everything about a session that is not the transcript.
///
/// Panels are driven by `SessionProjection`, which derives all of this from the event
/// log, so a panel is populated identically whether the events came from the embedded
/// engine or the Swift one.
public struct InspectorPanelView: View {
  @ObservedObject var session: SessionViewModel
  @ObservedObject var app: AppModel

  public init(session: SessionViewModel, app: AppModel) {
    self.session = session
    self.app = app
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(visiblePanels) { kind in
            PanelContainer(kind: kind, session: session, app: app)
          }
        }
        .padding(12)
      }
    }
    .background(.background)
  }

  /// Panels worth showing for this session and engine: an empty panel is noise, and a
  /// capability the engine does not advertise (PRD §7) should not appear at all.
  private var visiblePanels: [PanelKind] {
    var kinds: [PanelKind] = [.todos, .plan]
    if !session.projection.agents.isEmpty || app.capabilities.canSpawnSubagents { kinds.append(.agents) }
    if !session.projection.jobs.isEmpty || app.capabilities.canListJobs { kinds.append(.jobs) }
    if !session.projection.goals.isEmpty { kinds.append(.goals) }
    if !session.projection.schedules.isEmpty || app.capabilities.canSchedule { kinds.append(.schedule) }
    kinds.append(.tools)
    kinds.append(.request)
    return kinds
  }
}

/// One collapsible panel with a summary in its header.
struct PanelContainer: View {
  let kind: PanelKind
  @ObservedObject var session: SessionViewModel
  @ObservedObject var app: AppModel
  @State private var expanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: kind.symbolName)
          Text(kind.title).font(.callout.weight(.semibold))
          Spacer()
          Text(summary)
            .font(.caption2)
            .foregroundStyle(.secondary)
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .buttonStyle(.plain)

      if expanded {
        content
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
  }

  private var summary: String {
    switch kind {
    case .todos:
      let done = session.projection.todos.filter { $0.status == .completed }.count
      return "\(done)/\(session.projection.todos.count)"
    case .plan:
      return session.projection.plan.isActive ? "active" : session.projection.plan.review.displayName
    case .agents:
      return "\(session.projection.agents.count)"
    case .jobs:
      let running = session.projection.jobs.filter { $0.status == .running }.count
      return "\(running) running / \(session.projection.jobs.count)"
    case .tools:
      return app.capabilitySummary
    case .goals:
      return "\(session.projection.goals.count)"
    case .schedule:
      return "\(session.projection.schedules.count)"
    case .request:
      return session.projection.lastRequestHeader == nil ? "—" : "sent"
    }
  }

  @ViewBuilder
  private var content: some View {
    switch kind {
    case .todos:
      TodosPanel(items: session.projection.todos)
    case .plan:
      PlanPanel(plan: session.projection.plan)
    case .agents:
      AgentsPanel(agents: session.projection.agents, members: session.projection.teamMembers)
    case .jobs:
      JobsPanel(jobs: session.projection.jobs)
    case .tools:
      ToolsPanel(surface: app.toolSurface, invocations: session.invocations)
    case .goals:
      GoalsPanel(goals: session.projection.goals)
    case .schedule:
      SchedulePanel(entries: session.projection.schedules)
    case .request:
      RequestPanel(header: session.projection.lastRequestHeader)
    }
  }
}

// MARK: - Panels

struct TodosPanel: View {
  let items: [TodoItem]

  var body: some View {
    if items.isEmpty {
      Text("No todos yet").font(.caption).foregroundStyle(.tertiary)
    } else {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(items) { item in
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: item.status.symbolName)
              .foregroundStyle(item.status == .completed ? .green : (item.status == .in_progress ? .accentColor : .secondary))
              .font(.caption)
            Text(item.displayText)
              .font(.caption)
              .strikethrough(item.status == .completed, color: .secondary)
              .foregroundStyle(item.status == .completed ? .secondary : .primary)
            Spacer()
          }
        }
      }
    }
  }
}

struct PlanPanel: View {
  let plan: PlanState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: plan.isActive ? "map.fill" : "map")
          .foregroundStyle(plan.isActive ? .purple : .secondary)
        Text(plan.isActive ? "Plan mode active" : "Plan mode inactive")
          .font(.caption)
        Spacer()
        Text(plan.review.displayName).font(.caption2).foregroundStyle(.tertiary)
      }
      if let text = plan.plan, !text.isEmpty {
        ScrollView {
          MarkdownText(markdown: text, baseFont: .caption)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 240)
      }
    }
  }
}

struct AgentsPanel: View {
  let agents: [AgentNode]
  let members: [TeamMember]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if agents.isEmpty, members.isEmpty {
        Text("No subagents").font(.caption).foregroundStyle(.tertiary)
      }
      ForEach(agents) { agent in
        HStack(spacing: 6) {
          Image(systemName: agent.status.symbolName)
            .foregroundStyle(agent.status == .running ? .green : .secondary)
            .font(.caption)
          VStack(alignment: .leading, spacing: 1) {
            Text(agent.label).font(.caption).lineLimit(1)
            HStack(spacing: 6) {
              if let type = agent.agentType { Text(type).font(.caption2).foregroundStyle(.tertiary) }
              if let model = agent.model { Text(model).font(.caption2).foregroundStyle(.tertiary) }
              Text("depth \(agent.depth)").font(.caption2).foregroundStyle(.tertiary)
            }
          }
          Spacer()
          Text(agent.status.displayName).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(min(agent.depth, 6)) * 10)
      }
      ForEach(members) { member in
        HStack(spacing: 6) {
          Image(systemName: "person.crop.circle")
          Text(member.name).font(.caption)
          if let role = member.role { Text(role).font(.caption2).foregroundStyle(.tertiary) }
          Spacer()
          Text(member.status.displayName).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct JobsPanel: View {
  let jobs: [JobRecord]

  var body: some View {
    if jobs.isEmpty {
      Text("No background jobs").font(.caption).foregroundStyle(.tertiary)
    } else {
      VStack(alignment: .leading, spacing: 5) {
        ForEach(jobs) { job in
          HStack(spacing: 6) {
            Image(systemName: job.status.symbolName)
              .foregroundStyle(job.status == .running ? Color.accentColor : Color.secondary)
              .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
              Text(job.label.isEmpty ? job.id : job.label)
                .font(.caption)
                .lineLimit(1)
              if let command = job.command {
                Text(command)
                  .font(.system(.caption2, design: .monospaced))
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
            }
            Spacer()
            if let started = job.startedAt {
              Text(started, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
          }
        }
      }
    }
  }
}

/// The capability surface, split by how the model reaches each capability.
struct ToolsPanel: View {
  let surface: ToolSurface
  let invocations: [ToolInvocation]

  private var usage: [String: Int] {
    Dictionary(grouping: invocations, by: \.name).mapValues(\.count)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(surface.mode.rawValue).font(.caption2).foregroundStyle(.secondary)
        Spacer()
        Text("\(surface.allCapabilities.count) capabilities").font(.caption2).foregroundStyle(.tertiary)
      }
      ForEach(usedTools, id: \.name) { tool in
        HStack(spacing: 6) {
          Image(systemName: tool.category.symbolName).font(.caption2).foregroundStyle(.secondary)
          Text(tool.name).font(.system(.caption, design: .monospaced))
          Spacer()
          if let count = usage[tool.name] {
            Text("\(count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
          }
        }
      }
      if usedTools.isEmpty {
        Text("No tool calls yet").font(.caption).foregroundStyle(.tertiary)
      }
    }
  }

  /// Tools the model actually used, plus the bindings, so the panel reflects real use
  /// rather than dumping the whole catalogue.
  private var usedTools: [ToolDescriptor] {
    let used = Set(invocations.map(\.name))
    let relevant = surface.allCapabilities.filter { used.contains($0.name) }
    return relevant.sorted { $0.name < $1.name }
  }
}

struct GoalsPanel: View {
  let goals: [GoalRecord]

  var body: some View {
    if goals.isEmpty {
      Text("No goals").font(.caption).foregroundStyle(.tertiary)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(goals) { goal in
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Image(systemName: goal.phase.symbolName).font(.caption)
              Text(goal.title.isEmpty ? goal.id : goal.title).font(.caption.weight(.medium))
              Spacer()
              Text(goal.phase.displayName).font(.caption2).foregroundStyle(.secondary)
            }
            Text(goal.objective)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(4)
            if let progress = goal.progress {
              ProgressView(value: progress).controlSize(.small)
            }
            if let reason = goal.blockedReason {
              Text(reason).font(.caption2).foregroundStyle(.orange)
            }
          }
        }
      }
    }
  }
}

struct SchedulePanel: View {
  let entries: [ScheduleEntry]

  var body: some View {
    if entries.isEmpty {
      Text("Nothing scheduled").font(.caption).foregroundStyle(.tertiary)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(entries) { entry in
          HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.caption)
            VStack(alignment: .leading, spacing: 1) {
              Text(entry.prompt).font(.caption).lineLimit(2)
              Text(entry.displayTrigger).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
          }
        }
      }
    }
  }
}

/// The last `request/header` — the exact specification sent to the model.
///
/// Worth a panel of its own: it is the single most useful object for explaining what a
/// session actually did, and it is the baseline the conformance suite compares against.
struct RequestPanel: View {
  let header: RequestHeaderPayload?

  var body: some View {
    if let header {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(header.config.model ?? "—").font(.caption)
          Spacer()
          if let effort = header.config.reasoningEffort {
            Text(effort).font(.caption2).foregroundStyle(.secondary)
          }
        }
        HStack(spacing: 6) {
          Text("\(header.tools.count) tools").font(.caption2).foregroundStyle(.tertiary)
          if let maxTokens = header.config.maxTokens {
            Text("max \(maxTokens)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
          }
          Text("system \(header.system.count) chars").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        DisclosureGroup("System prompt") {
          ScrollView {
            Text(header.system)
              .font(.system(.caption2, design: .monospaced))
              .textSelection(.enabled)
          }
          .frame(maxHeight: 260)
        }
        .font(.caption)
        ForEach(header.tools.prefix(12)) { tool in
          Text(tool.name).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
        }
        if header.tools.count > 12 {
          Text("+ \(header.tools.count - 12) more")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    } else {
      Text("No request recorded yet").font(.caption).foregroundStyle(.tertiary)
    }
  }
}
