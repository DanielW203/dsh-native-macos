import HarnessKit
import SwiftUI

/// Session browser.
///
/// Sessions are grouped by working directory because that is how the harness itself
/// partitions them on disk (`$DSH_HOME/sessions/<escaped-cwd>/session-<uuid>/`), so the
/// grouping the user sees matches the storage they could inspect.
public struct SessionListView: View {
  @ObservedObject var app: AppModel
  let onOpen: (SessionSummary) -> Void
  let onNewSession: () -> Void

  public init(app: AppModel, onOpen: @escaping (SessionSummary) -> Void, onNewSession: @escaping () -> Void) {
    self.app = app
    self.onOpen = onOpen
    self.onNewSession = onNewSession
  }

  public var body: some View {
    VStack(spacing: 0) {
      List(selection: Binding(
        get: { app.selectedSessionID },
        set: { id in
          guard let id, let summary = app.sessions.first(where: { $0.id == id }) else { return }
          onOpen(summary)
        }
      )) {
        ForEach(app.sessionsByDirectory, id: \.cwd) { group in
          Section {
            ForEach(group.sessions) { summary in
              SessionRow(summary: summary)
                .tag(summary.id)
                .contextMenu {
                  Button("Copy session id") { copyToPasteboard(summary.id.rawValue) }
                  Button("Reveal working directory") {
                    if let cwd = summary.cwd {
                      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                    }
                  }
                  Divider()
                  Button("Delete session", role: .destructive) {
                    Task { await app.delete(summary.id) }
                  }
                }
            }
          } header: {
            Text(group.cwd == "—" ? "No working directory" : abbreviated(group.cwd))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
      }
      .listStyle(.sidebar)
      .searchable(text: $app.sessionFilter, placement: .sidebar, prompt: "Filter sessions")
      .overlay {
        if app.sessions.isEmpty, !app.isLoadingSessions {
          ContentUnavailableView("No sessions", systemImage: "clock", description: Text("Start a new session to begin."))
        }
      }

      Divider()
      HStack(spacing: 8) {
        Button {
          onNewSession()
        } label: {
          Label("New session", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        Spacer()
        if app.isLoadingSessions {
          ProgressView().controlSize(.small)
        } else {
          Text("\(app.sessions.count)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        Button {
          Task { await app.refreshSessions() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Reload the session list")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
  }

  private func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }
}

private struct SessionRow: View {
  let summary: SessionSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(summary.displayTitle)
          .font(.callout)
          .lineLimit(1)
        if summary.isLive {
          Circle().fill(.green).frame(width: 6, height: 6)
        }
      }
      HStack(spacing: 6) {
        if let updated = summary.updatedAt {
          Text(updated, style: .relative)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        if let count = summary.eventCount {
          Text("\(count) events").font(.caption2).foregroundStyle(.tertiary)
        }
        if let depth = summary.delegationDepth, depth > 0 {
          Label("\(depth)", systemImage: "person.2")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 2)
  }
}
