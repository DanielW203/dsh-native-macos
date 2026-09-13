import HarnessKit
import SwiftUI

/// The application window.
///
/// Layout: session browser on the left, transcript in the middle, inspector panels on
/// the right, composer pinned to the bottom. Everything is driven by `AppModel` and a
/// per-session `SessionViewModel`; no view talks to an engine directly.
public struct HarnessShellView: View {
  @StateObject private var app: AppModel
  @State private var session: SessionViewModel?
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var inspectorVisible = true
  @State private var showsSettings = false
  @State private var showsToolBrowser = false
  @State private var pendingApproval: ApprovalRecord?

  public init(app: AppModel) {
    _app = StateObject(wrappedValue: app)
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SessionListView(app: app) { summary in
        Task { await open(summary) }
      } onNewSession: {
        Task { await createSession() }
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      VStack(spacing: 0) {
        if let session {
          SessionHeaderBar(session: session, app: app, inspectorVisible: $inspectorVisible)
          Divider()
          HSplitView {
            VStack(spacing: 0) {
              ConversationView(session: session)
              Divider()
              ComposerView(session: session)
            }
            .frame(minWidth: 420)

            if inspectorVisible {
              InspectorPanelView(session: session, app: app)
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
            }
          }
        } else {
          EmptyStateView(app: app) { await createSession() }
        }
      }
      .toolbar { toolbarContent }
    }
    .task { await app.start() }
    .sheet(isPresented: $showsSettings) {
      SettingsView(app: app)
    }
    .sheet(isPresented: $showsToolBrowser) {
      ToolBrowserView(surface: app.toolSurface, isProgrammatic: app.isProgrammaticMode)
    }
    .sheet(item: $pendingApproval) { record in
      if let session {
        ApprovalSheet(record: record, session: session) {
          pendingApproval = nil
        }
      }
    }
    .onChange(of: app.selectedEngineKind) { _, _ in
      Task { await rebind() }
    }
    .onChange(of: session?.pendingApprovals.first?.id) { _, _ in
      // Approvals block the run, so they surface immediately rather than waiting for
      // the user to notice a panel.
      pendingApproval = session?.pendingApprovals.first
    }
    .onChange(of: session?.pendingQuestions.first?.id) { _, _ in
      if let question = session?.pendingQuestions.first { pendingApproval = question }
    }
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      EnginePicker(app: app)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if let session {
        Button {
          session.showsReasoning.toggle()
        } label: {
          Label("Reasoning", systemImage: session.showsReasoning ? "brain.fill" : "brain")
        }
        .help("Show or hide the model's reasoning blocks")

        Button {
          session.expandsPrograms.toggle()
        } label: {
          Label("Programs", systemImage: session.expandsPrograms ? "chevron.down.square.fill" : "chevron.right.square")
        }
        .help("Expand or collapse programmatic tool calls")
        .disabled(!session.isProgrammatic)
      }
      Button {
        showsToolBrowser = true
      } label: {
        Label("Tools", systemImage: "wrench.and.screwdriver")
      }
      .help("Browse the capability surface this profile exposes")
      Button {
        inspectorVisible.toggle()
      } label: {
        Label("Inspector", systemImage: "sidebar.right")
      }
      Button {
        showsSettings = true
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    }
  }

  // MARK: Actions

  private func open(_ summary: SessionSummary) async {
    app.selectedSessionID = summary.id
    session?.stop()
    let model = SessionViewModel(
      engine: app.engine,
      sessionID: summary.id,
      cwd: summary.cwd ?? FileManager.default.currentDirectoryPath
    )
    session = model
    await model.loadHistory()
    model.start()
  }

  private func createSession() async {
    let cwd = session?.cwd ?? FileManager.default.currentDirectoryPath
    guard let id = await app.createSession(cwd: cwd) else { return }
    let model = SessionViewModel(engine: app.engine, sessionID: id, cwd: cwd)
    session?.stop()
    session = model
    model.start()
  }

  private func rebind() async {
    guard let current = session else { return }
    session?.stop()
    let model = SessionViewModel(engine: app.engine, sessionID: current.sessionID, cwd: current.cwd)
    session = model
    await model.loadHistory()
    model.start()
  }
}

// MARK: - Header

/// Title bar strip: session identity, activity, model route and context usage.
struct SessionHeaderBar: View {
  @ObservedObject var session: SessionViewModel
  @ObservedObject var app: AppModel
  @Binding var inspectorVisible: Bool

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(session.title)
          .font(.headline)
          .lineLimit(1)
        Text(session.cwd)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer()
      ActivityBadge(activity: session.activity)
      if let model = session.projection.model {
        Label(model, systemImage: "cpu")
          .font(.caption)
          .foregroundStyle(.secondary)
          .labelStyle(.titleAndIcon)
      }
      if let window = session.projection.contextWindow {
        ContextMeter(used: session.projection.usage.inputTokens ?? 0, window: window)
      }
      Button {
        inspectorVisible.toggle()
      } label: {
        Image(systemName: "sidebar.right")
      }
      .buttonStyle(.borderless)
      .help("Toggle the inspector")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

/// Live activity indicator; distinguishes "thinking" from "running a tool" because the
/// two need different affordances (cancel vs. wait).
struct ActivityBadge: View {
  let activity: SessionActivity

  var body: some View {
    HStack(spacing: 6) {
      switch activity.phase {
      case .thinking, .waiting, .runningTool:
        ProgressView()
          .controlSize(.small)
      case .awaitingApproval, .awaitingQuestion, .reviewingPlan:
        Image(systemName: "exclamationmark.bubble")
          .foregroundStyle(.orange)
      default:
        Image(systemName: "moon.zzz")
          .foregroundStyle(.secondary)
      }
      Text(activity.detail ?? activity.phase.displayName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(.quaternary, in: Capsule())
  }
}

/// Shows input tokens against the model's context window.
struct ContextMeter: View {
  let used: Int
  let window: Int

  private var fraction: Double {
    guard window > 0 else { return 0 }
    return min(1, Double(used) / Double(window))
  }

  var body: some View {
    HStack(spacing: 4) {
      ProgressView(value: fraction)
        .frame(width: 60)
      Text("\(format(used))/\(format(window))")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .help("Context used: \(used) of \(window) tokens")
  }

  private func format(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.0fk", Double(value) / 1_000) }
    return "\(value)"
  }
}

// MARK: - Shared pieces

/// Engine switcher, showing availability and mode at a glance.
struct EnginePicker: View {
  @ObservedObject var app: AppModel

  var body: some View {
    Menu {
      ForEach(app.availableEngines) { kind in
        Button {
          Task { await app.selectEngine(kind) }
        } label: {
          if kind == app.selectedEngineKind {
            Label(kind.displayName, systemImage: "checkmark")
          } else {
            Text(kind.displayName)
          }
        }
      }
      Divider()
      Text(app.capabilitySummary)
    } label: {
      Label(app.selectedEngineKind.displayName, systemImage: app.selectedEngineKind == .native ? "swift" : "shippingbox")
        .font(.callout)
    }
    .menuStyle(.borderlessButton)
    .help(app.selectedEngineKind.detail)
  }
}

/// What the window shows before a session exists.
struct EmptyStateView: View {
  @ObservedObject var app: AppModel
  let onCreate: () async -> Void

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "swift")
        .font(.system(size: 42))
        .foregroundStyle(.tint)
      Text("NativeHarness")
        .font(.title2.weight(.semibold))
      Text(app.selectedEngineKind.detail)
        .font(.callout)
        .foregroundStyle(.secondary)
      if let diagnostic = app.engineDiagnostics[app.selectedEngineKind] {
        Text(diagnostic)
          .font(.caption)
          .foregroundStyle(.orange)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
      }
      Text(app.capabilitySummary)
        .font(.caption)
        .foregroundStyle(.tertiary)
      Button("New session") {
        Task { await onCreate() }
      }
      .keyboardShortcut("n", modifiers: [.command])
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}
