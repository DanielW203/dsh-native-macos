import HarnessRuntime
import SwiftUI

/// The application window: the harness Web UI, in a native frame.
///
/// The harness ships its own complete Web application — sessions, tool cards, approvals,
/// plan mode — so this window hosts it rather than reimplementing it. That choice is
/// deliberate and reversible: the native transcript built on `HarnessUI` is untouched and
/// replaces this view the day a bridge engine exists.
public struct HarnessWebWindow: View {
  @ObservedObject var model: HarnessWindowModel
  /// What to say about the mode this launch was started in, or `nil` for a normal start.
  let banner: SafeModeBanner?
  /// The WeChat channel, when this window was opened by the app that owns one. Absent in a
  /// preview or a test host, where the switch would have nothing to switch.
  let channel: WeChatChannelModel?
  @Environment(\.openWindow) private var openWindow
  /// The rebuild-and-restart sheet. Owned by this window because the button that opens it is
  /// here, and because the hand-off needs *this* process to be the one that quits.
  @StateObject private var rebuild = RebuildModel()

  public init(model: HarnessWindowModel, banner: SafeModeBanner? = nil, channel: WeChatChannelModel? = nil) {
    self.model = model
    self.banner = banner
    self.channel = channel
  }

  public var body: some View {
    VStack(spacing: 0) {
      if let banner {
        safeModeBanner(banner)
        Divider()
      }
      toolbar
      Divider()
      if let web = model.webModel, model.isRunning {
        HarnessWebContent(model: web)
      } else {
        placeholder
      }
    }
    .frame(minWidth: 920, minHeight: 640)
    .task { await model.startIfNeeded() }
    .sheet(isPresented: $rebuild.isPresented) {
      RebuildSheet(model: rebuild)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.refresh() }
    }
  }

  // MARK: - Safe Mode

  /// The one line that explains why this window is not the usual one.
  ///
  /// Above the toolbar rather than inside the placeholder, because it has to be readable
  /// while the harness is running: "why is my plugin missing" and "why is my session list
  /// empty" are questions asked of a window that is working perfectly.
  private func safeModeBanner(_ banner: SafeModeBanner) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "shield.lefthalf.filled")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(banner.title)
          .font(.callout.weight(.medium))
        Text(banner.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      Button("打开恢复模式…") {
        openWindow(id: HarnessWindowID.recovery)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color.orange.opacity(0.10))
  }


  // MARK: - Toolbar

  private var toolbar: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(phaseColour)
        .frame(width: 9, height: 9)
      Text(phaseLabel)
        .font(.callout)

      if let url = model.displayURL, model.isRunning {
        Text(url)
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .help("The local address of the running harness. The access token the page needs is not shown.")
      }

      Spacer()

      // First on the right because it is the only control here that can be *waiting* on the
      // user: a question parked on the phone blocks a running turn until it is answered.
      if let channel {
        PhoneRemoteControlButton(channel: channel)
      }

      // Left of Reload because it is the heavier version of it: a reload re-fetches the
      // page, while this is the only thing that applies a workspace change, picks up a
      // runtime that was just installed, or frees a port a stuck harness is holding.
      Button {
        model.restartApplication()
      } label: {
        Label("Restart", systemImage: "arrow.triangle.2.circlepath")
      }
      .help("Quit and reopen this app, so the harness starts fresh")

      // Right of Restart because it *is* Restart, one level up: it recompiles the checkout
      // before bringing the app back, so the window that returns is the code that was just
      // built rather than the code that was already running. It is the only control here
      // that needs to know where the sources are, which is why it can also be the one that
      // asks.
      Button {
        rebuild.present()
      } label: {
        Label("Rebuild", systemImage: "hammer")
      }
      .help("Rebuild DSHNative from its source checkout, then quit and reopen the installed app")

      if model.isRunning {
        Button {
          model.reload()
        } label: {
          Label("Reload", systemImage: "arrow.clockwise")
        }
        Button {
          model.openInBrowser()
        } label: {
          Label("Open in Browser", systemImage: "safari")
        }
        .help("Open the same session in your default browser")
        Button {
          Task { await model.stop() }
        } label: {
          Label("Stop", systemImage: "stop.circle")
        }
        .disabled(model.isBusy)
      } else {
        Button {
          Task { await model.start() }
        } label: {
          Label("Start", systemImage: "play.circle")
        }
        .disabled(model.isBusy)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  private var phaseLabel: String {
    switch model.phase {
    case .stopped: return "Harness stopped"
    case .starting: return "Starting the harness…"
    case .running: return "Harness running"
    case .failed: return "The harness failed to start"
    }
  }

  private var phaseColour: Color {
    switch model.phase {
    case .stopped: return .secondary
    case .starting: return .yellow
    case .running: return .green
    case .failed: return .red
    }
  }

  // MARK: - Not running

  private var placeholder: some View {
    VStack(spacing: 16) {
      if model.isBusy || model.phase == .starting {
        ProgressView()
        Text("Booting the harness in \(model.workspacePath)")
          .font(.callout)
        Text("The first launch creates the profile, which takes a moment.")
          .font(.caption)
          .foregroundStyle(.secondary)
        logView
      } else {
        Image(systemName: "shippingbox")
          .font(.system(size: 40))
          .foregroundStyle(.tint)
        Text(model.phase == .failed ? "The harness could not start" : "The harness is not running")
          .font(.title3.weight(.semibold))

        if let detail = model.detail {
          ScrollView {
            Text(detail)
              .font(.caption.monospaced())
              .foregroundStyle(.orange)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: 640, maxHeight: 160)
        }

        // Why there is no harness can be answered by a version change: an upgrade that failed
        // and rolled back leaves the runtime on the *other* release, and a plain boot failure
        // would hide that the app moved anything at all.
        if let report = model.upgradeReport, report.isWorthShowingAtLaunch {
          upgradeBanner(report)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Once it is running, the harness asks for two things:")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("1.  Settings → Models — paste a DeepSeek API key. It applies without a restart.")
          Text("2.  Choose workspace — pick the folder the agent may read and edit.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        Text("Workspace: \(model.workspacePath)")
          .font(.caption2)
          .foregroundStyle(.tertiary)

        HStack(spacing: 8) {
          Button {
            Task { await model.start() }
          } label: {
            Label("Start", systemImage: "play.circle")
          }
          .keyboardShortcut("r", modifiers: [.command])
          Button("Choose Workspace…") { model.chooseWorkspace() }
        }

        // A machine with no Node cannot boot anything, and the harness's own UI — the only
        // other surface a runtime could be installed from — is exactly what never appears.
        // This is the one way out that needs neither a terminal nor knowing what Node is.
        if model.needsNode {
          VStack(spacing: 6) {
            Button {
              Task { await model.installNode() }
            } label: {
              Label("Install Node…", systemImage: "arrow.down.circle")
            }
            .disabled(model.isBusy)
            Text(
              "The harness runs on Node, and this machine does not have one it can use. "
                + "This downloads the current stable Node from nodejs.org, checks it against the digest "
                + "Node publishes, and unpacks it into this app's own folder — nothing outside the app "
                + "is touched. The harness is started again as soon as it lands."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            if let stage = model.nodeStage {
              Text(stage)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            }
          }
        }

        // Only after a failure, because that is the one state this can fix: a plugin the
        // loader cannot apply takes the whole boot down, and the Web UI — where a plugin is
        // normally turned off — is exactly what is missing. Nothing here needs the page.
        if model.phase == .failed {
          VStack(spacing: 6) {
            Button {
              Task { await model.quarantineAndRestart() }
            } label: {
              Label("Disable Broken Plugins and Retry", systemImage: "wrench.and.screwdriver")
            }
            .disabled(model.isBusy)
            Text(
              "Stops the harness, turns off only the plugins the boot output blames, then starts it again. "
                + "What it turns off is listed in the log and can be re-enabled in the Plugin window."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)

            // The repair above only knows how to blame a plugin. The recovery window is
            // where the other answers live — start without plugins, start in a clean home,
            // roll the configuration back — and it is reachable from here because the panel
            // that is failing is the one place a user looks first.
            Button {
              openWindow(id: HarnessWindowID.recovery)
            } label: {
              Label("打开恢复模式…", systemImage: "cross.case")
            }
            .disabled(model.isBusy)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  /// What the last version change did, when it is still something the user needs to know.
  ///
  /// Shown on the panel that explains why there is no harness, because that is the question it
  /// answers: the runtime is on the *other* release now, and the console's report is behind a
  /// window the user may not have open.
  @ViewBuilder
  private func upgradeBanner(_ report: UpgradeReport) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("上次更新：\(report.outcome.displayName)")
        .font(.callout.weight(.semibold))
      Text(report.summary)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let failure = report.bootFailure {
        Text(failure)
          .font(.caption2.monospaced())
          .foregroundStyle(.orange)
          .lineLimit(6)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: 640, alignment: .leading)
    .padding(10)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  /// What the boot is saying right now, with nothing to scroll.
  ///
  /// A boot log only ever grows at the bottom, so the one line worth guaranteeing is the
  /// last one. Two shapes carry that: while everything still fits, the lines are an
  /// ordinary block starting at the top of the box; once they don't, the block is anchored
  /// to the box's bottom edge inside a fixed height, so the newest line stays in place and
  /// the oldest ones are cut off the top. The panel slides down by itself, and there is no
  /// ScrollView left to hide the tail behind a scroll bar or a rubber band. This panel is
  /// for reading where the boot is now, not for browsing what it said a minute ago.
  ///
  /// `fixedSize(vertical:)` on every line is load-bearing, and it is not there to stop
  /// wrapping: a stack that is allowed to shrink silently squashes each line into the
  /// height the box has left and truncates it, so nothing is ever oversized, the overflow
  /// case never happens, and the panel shows the *oldest* lines. With it, a long line wraps
  /// and costs a row — the panel drops lines off the top, never text inside a line. The
  /// fallback also needs a real height rather than `maxHeight`, for the same reason.
  ///
  /// `suffix` bounds the work; the model keeps 200 lines.
  private var logView: some View {
    ViewThatFits(in: .vertical) {
      logLines
      logLines.frame(height: Self.logBoxHeight - Self.logInset * 2, alignment: .bottom)
    }
    .padding(Self.logInset)
    .frame(maxWidth: 640, alignment: .leading)
    .frame(height: Self.logBoxHeight, alignment: .top)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
  }

  /// The box the boot log lives in, tall enough for the stages of a start to be readable.
  private static let logBoxHeight: CGFloat = 180
  private static let logInset: CGFloat = 8

  private var logLines: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(model.log.suffix(40).enumerated()), id: \.offset) { _, line in
        Text(line)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// The loaded harness, with its own progress and failure reporting.
///
/// Separate from the window so the web view's published state drives only this subtree —
/// a progress tick should not re-render the toolbar.
private struct HarnessWebContent: View {
  @ObservedObject var model: HarnessWebModel

  var body: some View {
    ZStack(alignment: .top) {
      HarnessWebView(model: model)

      if model.isLoading {
        ProgressView(value: model.progress)
          .progressViewStyle(.linear)
          .frame(height: 2)
      }

      if let failure = model.failure {
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("The harness page could not be loaded")
            .font(.callout)
          Text(failure)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Try Again") { model.reload() }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 60)
      }
    }
  }
}
