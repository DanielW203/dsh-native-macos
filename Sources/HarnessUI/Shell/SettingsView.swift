import HarnessKit
import SwiftUI

/// Settings: which engine drives the app, what it can do, and where sessions live.
///
/// The engine section is the honest one. The two engines are not interchangeable in
/// capability, so the pane reports the advertised capability set rather than implying
/// parity: the embedded engine is the reference, and the Swift core catches up module
/// by module.
public struct SettingsView: View {
  @ObservedObject var app: AppModel
  @Environment(\.dismiss) private var dismiss

  public init(app: AppModel) {
    self.app = app
  }

  public var body: some View {
    TabView {
      enginesTab
        .tabItem { Label("Engines", systemImage: "cpu") }
      capabilitiesTab
        .tabItem { Label("Capabilities", systemImage: "checklist") }
      aboutTab
        .tabItem { Label("About", systemImage: "info.circle") }
    }
    .frame(width: 620, height: 460)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
  }

  // MARK: Engines

  private var enginesTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(EngineKind.allCases) { kind in
          EngineCard(
            kind: kind,
            isSelected: app.selectedEngineKind == kind,
            isAvailable: app.engines[kind] != nil,
            diagnostic: app.engineDiagnostics[kind],
            status: app.selectedEngineKind == kind ? app.status : nil
          ) {
            Task { await app.selectEngine(kind) }
          }
        }
        Text("Both engines implement the same protocol, so the interface above is identical. Switching re-reads the session through the newly selected engine — that is the dual-engine comparison.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(16)
    }
  }

  // MARK: Capabilities

  private var capabilitiesTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        GroupBox("Selected engine") {
          VStack(alignment: .leading, spacing: 6) {
            Text(app.selectedEngineKind.displayName).font(.headline)
            Text(app.capabilitySummary).font(.caption).foregroundStyle(.secondary)
            if let status = app.status {
              if let version = status.version {
                Text("version \(version)").font(.caption2).foregroundStyle(.tertiary)
              }
              if let detail = status.detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
        }

        GroupBox("Advertised capabilities") {
          VStack(alignment: .leading, spacing: 4) {
            CapabilityRow("Create sessions", app.capabilities.canCreateSession)
            CapabilityRow("Resume sessions", app.capabilities.canResumeSession)
            CapabilityRow("List sessions", app.capabilities.canListSessions)
            CapabilityRow("Delete sessions", app.capabilities.canDeleteSession)
            CapabilityRow("Cancel a turn", app.capabilities.canCancel)
            CapabilityRow("Steer while running", app.capabilities.canSteerWhileRunning)
            CapabilityRow("Approvals", app.capabilities.canApprove)
            CapabilityRow("Ask user questions", app.capabilities.canAskQuestions)
            CapabilityRow("Plan review", app.capabilities.canReviewPlans)
            CapabilityRow("Subagents", app.capabilities.canSpawnSubagents)
            CapabilityRow("Workflows", app.capabilities.canRunWorkflows)
            CapabilityRow("Background jobs", app.capabilities.canListJobs)
            CapabilityRow("Scheduled prompts", app.capabilities.canSchedule)
            CapabilityRow("Session search", app.capabilities.canSearchSessions)
            CapabilityRow("Programmatic calls (PTC)", app.capabilities.canExecutePrograms)
            CapabilityRow("Reads official session logs", app.capabilities.readsOfficialSessions)
            CapabilityRow("Writes official session logs", app.capabilities.writesOfficialSessions)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
        }

        if !app.models.isEmpty {
          GroupBox("Models") {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(app.models) { model in
                HStack(spacing: 6) {
                  Text(model.displayName).font(.callout)
                  Spacer()
                  if let window = model.contextWindow {
                    Text("\(window) ctx").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                  }
                  if model.supportsImages {
                    Image(systemName: "photo").font(.caption2).foregroundStyle(.tertiary)
                  }
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
          }
        }
      }
      .padding(16)
    }
  }

  private var aboutTab: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("NativeHarness").font(.title2.weight(.semibold))
      Text("A Swift-native front end for the DeepSeek Harness.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Divider()
      Text("Two engines, one interface: route A embeds the official harness as a hidden subprocess behind a bridge; route B re-implements the harness core in Swift. Sessions are read and written in the official V3 log format, so both engines see the same history.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct EngineCard: View {
  let kind: EngineKind
  let isSelected: Bool
  let isAvailable: Bool
  let diagnostic: String?
  let status: EngineStatus?
  let onSelect: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: kind == .native ? "swift" : "shippingbox")
        .font(.title2)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(kind.displayName).font(.headline)
          if isSelected {
            Text("active").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
              .background(Color.accentColor.opacity(0.2), in: Capsule())
          }
          if !isAvailable {
            Text("unavailable").font(.caption2).foregroundStyle(.orange)
          }
        }
        Text(kind.detail).font(.caption).foregroundStyle(.secondary)
        if let diagnostic {
          Text(diagnostic).font(.caption2).foregroundStyle(.orange).lineLimit(3)
        } else if let status, let detail = status.detail {
          Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
        }
      }
      Spacer()
      if isAvailable, !isSelected {
        Button("Use", action: onSelect)
      }
    }
    .padding(12)
    .background(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
  }
}

struct CapabilityRow: View {
  let name: String
  let available: Bool

  init(_ name: String, _ available: Bool) {
    self.name = name
    self.available = available
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: available ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(available ? .green : .secondary)
        .font(.caption)
      Text(name).font(.caption)
      Spacer()
    }
  }
}
