import AppKit
import Combine
import SwiftUI

/// The running harness, as seen by the windows that did not start it.
///
/// The main window owns the server: it resolves the toolchain, picks the port, spawns the
/// process and stops it again. A second harness would be a second server on one home, so
/// an extra window must never start one — it shows the server that already exists. That
/// makes the URL a piece of app-wide state rather than a property of one window, which is
/// what this object is: the main window publishes the address here, and every extra
/// window reads it.
@MainActor
public final class HarnessPageHost: ObservableObject {
  /// The address the running harness announced, token included. `nil` until it is up.
  @Published public private(set) var url: URL?
  /// Whether that address is currently being served, so a window can tell "not started
  /// yet" from "stopped a moment ago" without guessing.
  @Published public private(set) var isRunning = false

  public init() {}

  /// Called by the main window when its harness reaches (or loses) a running state.
  public func update(url: String?, isRunning: Bool) {
    self.isRunning = isRunning
    guard isRunning, let url, let parsed = URL(string: url) else {
      self.url = nil
      return
    }
    self.url = parsed
  }
}

/// One more view of the harness that is already running.
///
/// Every window here hosts its own web view against the same server, which is what makes
/// this "the same harness in two windows" rather than two harnesses: sessions, workspace
/// and running turns all live on the server, and each window is only a surface onto them.
/// Navigating one window therefore leaves every other window where it was — the active
/// session, the open dialog and the scroll position are all per-window page state.
///
/// Lifecycle stays with the main window on purpose: there is no Start, Stop or Restart
/// here, because pressing those in two windows would be two owners for one process.
public struct HarnessPageWindow: View {
  @ObservedObject private var host: HarnessPageHost
  @State private var page: HarnessWebModel?

  public init(host: HarnessPageHost) {
    self.host = host
  }

  public var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if let page {
        HarnessWebView(model: page)
      } else {
        placeholder
      }
    }
    .frame(minWidth: 900, minHeight: 620)
    // Three ways in, and all three are needed: the harness may already be up (onAppear),
    // it may come up while this window waits (onChange), and a restart replaces the
    // address under a window that is already showing a page (the second onChange).
    .onAppear { attach() }
    .onChange(of: host.url) { _, _ in attach() }
    .onChange(of: host.isRunning) { _, _ in attach() }
  }

  // MARK: - Toolbar

  /// Deliberately thinner than the main window's: everything here is about *this* view of
  /// the page. Status, Start/Stop, Restart and Rebuild belong to the window that owns the
  /// server and are not duplicated.
  private var toolbar: some View {
    HStack(spacing: 10) {
      Image(systemName: "macwindow.on.rectangle")
        .foregroundStyle(.tint)
      Text("Harness Window")
        .font(.callout.weight(.medium))
      Circle()
        .fill(host.isRunning ? Color.green : Color.secondary)
        .frame(width: 8, height: 8)
      Spacer()
      Button {
        page?.reload()
      } label: {
        Label("Reload", systemImage: "arrow.clockwise")
      }
      .disabled(page == nil)
      Button {
        if let url = host.url { NSWorkspace.shared.open(url) }
      } label: {
        Label("Open in Browser", systemImage: "safari")
      }
      .disabled(!host.isRunning)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  // MARK: - Not running

  private var placeholder: some View {
    VStack(spacing: 12) {
      Image(systemName: "macwindow.on.rectangle")
        .font(.system(size: 38))
        .foregroundStyle(.tertiary)
      Text(host.isRunning ? "The harness is not reachable" : "The harness is not running")
        .font(.title3.weight(.semibold))
      Text("This window shows the harness the main window started, so start it there first.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  // MARK: - Attach

  /// Give this window its own web view once an address exists, and follow that address
  /// when it changes.
  ///
  /// The first attach is latched by `page != nil`, because a page that is already open
  /// must not be thrown away by a redraw. A *different* address is a different server,
  /// though, and a window still pointing at the old port after a restart can only fail,
  /// so the loaded URL itself is what decides.
  private func attach() {
    guard let url = host.url else { return }
    guard page?.webView.url != url else { return }
    let model = HarnessWebModel(
      baseURL: url,
      onExternal: { NSWorkspace.shared.open($0) }
    )
    model.load(url)
    page = model
  }
}
