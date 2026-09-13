import AppKit
import HarnessKit
import HarnessRuntime
import SwiftUI
import UniformTypeIdentifiers

/// The harness console: a native window for installing, updating, and inspecting the
/// harness runtime, and for reading the operation log.
///
/// This is deliberately its own surface rather than a pane inside the transcript window.
/// Managing the runtime is a different task from holding a conversation — it happens
/// before there is anything to talk to, and it is the only thing the app can do when no
/// runtime is installed at all.
///
/// Plugin work used to be a tab here. It is now its own window (`HarnessPluginWindow`,
/// opened from Harness ▸ Plugin…), which drives this same model — so the log tab and the
/// status line below still report what that window did.
public struct HarnessConsoleView: View {
  @ObservedObject var model: HarnessConsoleModel

  public init(model: HarnessConsoleModel) {
    self.model = model
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      TabView {
        RuntimePane(model: model)
          .tabItem { Label("Runtime", systemImage: "shippingbox") }
        LogPane(model: model)
          .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
      }
      .padding(.top, 6)
      Divider()
      ConsoleStatusStrip(model: model)
    }
    .frame(minWidth: 880, minHeight: 620)
    .task { await model.startIfNeeded() }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Harness Console").font(.headline)
        Text("DSH_HOME \(model.dshHome)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer()
      if model.presentedAsEmbeddedWindow {
        Text("This window is inside DSHNative; the harness itself is started and stopped by the main window.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if model.isBusy {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(model.busyLabel ?? "Working")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Button {
        Task { await model.refresh() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(model.isBusy)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

/// The always-visible line describing what just happened.
///
/// Every action reports here as well as into the log tab. Without it, an operation that
/// refuses to start — an empty version field, an operation already running, a rejected
/// archive — looks exactly like a button that does nothing.
///
/// Shared by the console window and `HarnessPluginWindow`: both drive the same model, so
/// both must be able to say that a plugin install refused to start while the console
/// window is the one showing the log.
struct ConsoleStatusStrip: View {
  @ObservedObject var model: HarnessConsoleModel

  var body: some View {
    HStack(spacing: 8) {
      if model.isBusy {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: model.statusKind == .failure ? "exclamationmark.triangle.fill" : "info.circle")
          .foregroundStyle(consoleColour(for: model.statusKind))
      }
      Text(model.statusLine)
        .font(.caption)
        .foregroundStyle(model.statusKind == .failure ? Color.red : Color.primary)
        .lineLimit(2)
        .textSelection(.enabled)
      Spacer()
      if model.isBusy, let label = model.busyLabel {
        Text(label).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(.bar)
  }
}

/// How a status kind is drawn. File scope so the status strip the console window and the
/// plugin window both present cannot drift apart. (The log list keeps its own mapping: a
/// log line is read as text, where `.primary` for `info` is right, while a status icon on
/// the bar wants `.secondary`.)
func consoleColour(for kind: ConsoleLogLine.Kind) -> Color {
  switch kind {
  case .info: return .secondary
  case .progress: return .secondary
  case .success: return .green
  case .warning: return .orange
  case .failure: return .red
  }
}

// MARK: - Runtime

private struct RuntimePane: View {
  @ObservedObject var model: HarnessConsoleModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        harnessCard
        workspaceCard
        toolchainCard
        activeCard
        actionsCard
        candidatesCard
        releasesCard
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }


  /// Start and stop the harness itself.
  ///
  /// This is the difference between a tool that manages an installation and one that uses
  /// it: everything else on this page exists so this button has something to start.
  private var harnessCard: some View {
    GroupBox("Run the harness") {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Circle()
            .fill(phaseColour)
            .frame(width: 9, height: 9)
          Text(phaseLabel).font(.callout)
          if model.server.isRunning, let pid = model.server.pid {
            Text("pid \(pid)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
          }
          Spacer()
          if model.server.isRunning {
            Button {
              model.openHarness()
            } label: {
              Label("Open", systemImage: "safari")
            }
            Button {
              Task { await model.stopHarness() }
            } label: {
              Label("Stop", systemImage: "stop.circle")
            }
            .disabled(model.isBusy)
          } else {
            Button {
              Task { await model.startHarness() }
            } label: {
              Label("Start", systemImage: "play.circle")
            }
            .disabled(model.isBusy || model.releases.isEmpty)
            .help(model.releases.isEmpty ? "Install a runtime first" : "Boot the harness and open it")
          }
        }

        if let url = model.server.url {
          HStack(spacing: 6) {
            Text(url).font(.callout.monospaced()).textSelection(.enabled)
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(url, forType: .string)
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the URL")
          }
        }

        if model.server.phase == .failed, let detail = model.server.detail {
          Text(detail)
            .font(.caption2.monospaced())
            .foregroundStyle(.orange)
            .lineLimit(8)
            .textSelection(.enabled)
        }

        Text("Boots the \(model.selectedProfile) profile in this app's own harness home and opens its Web UI. That home is separate from DSH Desktop, so credentials and sessions do not carry over.")
          .font(.caption)
          .foregroundStyle(.secondary)

        if model.presentedAsEmbeddedWindow {
          Text("The main window already runs this profile, so use its menu to restart or quit; starting another server here would fight it for the port.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(6)
    }
  }

  /// The folder the harness is launched in — the one thing the app's main window used to
  /// show, as a folder button, in its own toolbar.
  ///
  /// It belongs here rather than there: changing it decides where *new* sessions land, only
  /// takes effect on the next boot, and is meaningless without the explanation the old
  /// toolbar tooltip had no room for. The console is already the window that starts and
  /// stops the harness, so the folder it starts in is part of the same subject.
  ///
  /// Drawn only when a host supplies a folder: this module knows nothing about the choice
  /// itself (it cannot — see the target's dependencies), so an empty path would be a card
  /// about a value that does not exist.
  @ViewBuilder
  private var workspaceCard: some View {
    if let path = model.workspacePath {
      GroupBox("工作区（harness 的启动目录）") {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Image(systemName: "folder")
              .foregroundStyle(.secondary)
            Text(path)
              .font(.callout.monospaced())
              .textSelection(.enabled)
              .lineLimit(1)
              .truncationMode(.head)
            Spacer()
            Button("更改…") {
              model.chooseWorkspace?()
            }
            .disabled(model.chooseWorkspace == nil)
            .help("选一个新的启动目录")
          }

          Text("这个文件夹就是启动 harness 时传给它的「当前目录」。harness 把它当作默认位置，所以 Web 界面里新建的会话默认也落在这个工作区。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          Text("它不会改动已有的会话，也不影响你在 Web 界面侧栏里选的会话工作区。改完要重启 harness 才生效：回主窗口点 Restart，或者在本窗口 Stop 之后再 Start。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
      }
    }
  }

  private var phaseLabel: String {
    switch model.server.phase {
    case .stopped: return "Stopped"
    case .starting: return "Starting…"
    case .running: return "Running"
    case .failed: return "Failed to start"
    }
  }

  private var phaseColour: Color {
    switch model.server.phase {
    case .stopped: return .secondary
    case .starting: return .yellow
    case .running: return .green
    case .failed: return .red
    }
  }

  private var toolchainCard: some View {
    GroupBox("Toolchain") {
      VStack(alignment: .leading, spacing: 4) {
        if let toolchain = model.toolchain {
          row("Node", "\(toolchain.nodeVersion)  ·  \(toolchain.nodeOrigin.rawValue)", toolchain.node.path)
          if let npm = toolchain.npm {
            row("npm", "derived from Node", npm.displayPath)
          } else {
            row("npm", "not found", "installing from the registry needs it")
          }
          if let pnpm = toolchain.pnpm {
            row("pnpm", toolchain.pnpmOrigin?.rawValue ?? "unknown", pnpm.path)
          } else {
            row("pnpm", "not found", "plugin work needs it")
          }
        } else {
          Text("Resolving…").font(.callout).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(6)
    }
  }

  private var activeCard: some View {
    GroupBox("Active runtime") {
      VStack(alignment: .leading, spacing: 4) {
        if let release = model.releases.first(where: { $0.id == model.activeReleaseID }) {
          HStack(spacing: 8) {
            Text(release.version).font(.title3.weight(.semibold)).monospacedDigit()
            Text(release.source.kind.displayName)
              .font(.caption2)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(.quaternary, in: Capsule())
            if release.integrity.verified {
              Label(release.integrity.origin.rawValue, systemImage: "checkmark.seal")
                .font(.caption2).foregroundStyle(.green)
            } else {
              Label("unverified local import", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
            }
          }
          row("entry", "", release.entry)
          row("from", "", release.source.spec)
          row("installed", release.installedAt.formatted(date: .abbreviated, time: .shortened), "")
        } else {
          Text("No runtime is installed. Import a harness archive, or install a version from the registry.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(6)
    }
  }

  private var actionsCard: some View {
    GroupBox("Install or update") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Button {
            chooseImport()
          } label: {
            Label("Import harness…", systemImage: "square.and.arrow.down")
          }
          .disabled(model.isBusy)
          Text("A prebuilt package (.zip / .tar.gz) or an unpacked source checkout.")
            .font(.caption).foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          TextField("latest", text: $model.importVersion)
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
          Button {
            Task { await model.fillLatestVersion() }
          } label: {
            Label("Latest", systemImage: "questionmark.circle")
          }
          .disabled(model.isBusy)
          .help("Ask the registry which version is tagged latest")
          Button {
            Task { await model.installFromRegistry() }
          } label: {
            Label("Install from npm", systemImage: "arrow.down.circle")
          }
          .disabled(model.isBusy)
          Text("The official publication channel. Leave the field empty to install whatever is tagged latest.")
            .font(.caption).foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          Button {
            Task { await model.checkForUpdates() }
          } label: {
            Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(model.isBusy)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(6)
    }
  }

  @ViewBuilder
  private var candidatesCard: some View {
    if !model.candidates.isEmpty || !model.channelNotes.isEmpty {
      GroupBox("Available versions") {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(model.candidates) { candidate in
            HStack(spacing: 8) {
              Text(candidate.version).monospacedDigit().font(.callout)
              Text(candidate.channelID)
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
              if let note = candidate.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Install") {
                Task { await model.install(source: candidate.source) }
              }
              .disabled(model.isBusy)
            }
          }
          ForEach(model.channelNotes, id: \.self) { note in
            Text(note).font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
      }
    }
  }

  private var releasesCard: some View {
    GroupBox("Installed runtimes") {
      VStack(alignment: .leading, spacing: 6) {
        if model.releases.isEmpty {
          Text("Nothing installed yet.").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(model.releases) { release in
          HStack(spacing: 8) {
            Image(systemName: release.id == model.activeReleaseID ? "largecircle.fill.circle" : "circle")
              .foregroundStyle(release.id == model.activeReleaseID ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
              Text("\(release.version)  ·  \(release.source.kind.displayName)").font(.callout)
              Text(release.id).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if let bytes = release.byteCount {
              Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.caption2).foregroundStyle(.tertiary)
            }
            if release.id != model.activeReleaseID {
              Button("Activate") { Task { await model.activate(release.id) } }
                .disabled(model.isBusy)
              Button("Remove") { Task { await model.remove(release.id) } }
                .disabled(model.isBusy)
            } else {
              Text("active").font(.caption2).foregroundStyle(.secondary)
            }
          }
          Divider()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(6)
    }
  }

  private func chooseImport() {
    // Without this the panel can open behind the active application, which looks exactly
    // like the button having done nothing at all.
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose a harness package (.zip / .tar.gz) or an unpacked checkout"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.install(path: url.path) }
  }

  private func row(_ label: String, _ value: String, _ detail: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
      Text(value).font(.callout)
      if !detail.isEmpty {
        Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
      }
      Spacer()
    }
  }
}

// MARK: - Log

private struct LogPane: View {
  @ObservedObject var model: HarnessConsoleModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("\(model.log.count) lines").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Clear") { model.clearLog() }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(model.log) { line in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.time.formatted(date: .omitted, time: .standard))
                  .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                Text(line.text)
                  .font(.caption.monospaced())
                  .foregroundStyle(colour(for: line.kind))
                  .textSelection(.enabled)
                Spacer()
              }
              .id(line.id)
            }
          }
          .padding(10)
        }
        .onChange(of: model.log.count) { _, _ in
          if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
    }
  }

  private func colour(for kind: ConsoleLogLine.Kind) -> Color {
    switch kind {
    case .info: return .primary
    case .progress: return .secondary
    case .success: return .green
    case .warning: return .orange
    case .failure: return .red
    }
  }
}
