import AppKit
import SwiftUI
import WebKit

/// DSH Market, in its own window.
///
/// It is not a separate application: DSH Market is a client plugin that registers a
/// settings section inside the harness Web UI, so this window hosts the harness and walks
/// it to that section. The harness has no URL routing — the active tab lives in React
/// state and no client package touches the hash or history — so the only way in from
/// outside is to click through the interface, which is what the script below does.
public struct HarnessMarketWindow: View {
  @ObservedObject var harness: HarnessWindowModel
  @State private var market: HarnessWebModel?

  public init(harness: HarnessWindowModel) {
    self.harness = harness
  }

  public var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if let market {
        HarnessWebView(model: market)
      } else {
        placeholder
      }
    }
    .frame(minWidth: 900, minHeight: 620)
    .task { attach() }
    .onChange(of: harness.url) { _, _ in attach() }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Image(systemName: "bag")
        .foregroundStyle(.tint)
      Text("DSH Market").font(.callout.weight(.medium))
      if harness.isRunning {
        Circle().fill(.green).frame(width: 8, height: 8)
      } else {
        Circle().fill(.secondary).frame(width: 8, height: 8)
      }
      Spacer()
      Button {
        market?.evaluate(Self.navigationScript)
      } label: {
        Label("Go to Market", systemImage: "arrow.right.circle")
      }
      .disabled(market == nil)
      .help("Open the market section again if you navigated away")
      Button {
        market?.reload()
      } label: {
        Label("Reload", systemImage: "arrow.clockwise")
      }
      .disabled(market == nil)
      Button {
        if let url = harness.url, let parsed = URL(string: url) {
          NSWorkspace.shared.open(parsed)
        }
      } label: {
        Label("Open in Browser", systemImage: "safari")
      }
      .disabled(!harness.isRunning)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  private var placeholder: some View {
    VStack(spacing: 12) {
      Image(systemName: "bag").font(.system(size: 38)).foregroundStyle(.tertiary)
      Text("The harness is not running").font(.title3.weight(.semibold))
      Text("DSH Market is served by the harness, so start it in the main window first.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private func attach() {
    guard market == nil else { return }
    guard let address = harness.url, let parsed = URL(string: address) else { return }
    let model = HarnessWebModel(
      baseURL: parsed,
      onExternal: { NSWorkspace.shared.open($0) },
      postLoadScript: Self.navigationScript
    )
    model.load(parsed)
    market = model
  }

  /// Walks the loaded harness to the market section, then reduces the window to just it.
  ///
  /// The harness has no URL routing — the active tab lives in React state and no client
  /// package touches the hash or history — so reaching the section from outside means
  /// clicking through the interface. And because DSH Market is a settings *section* rather
  /// than a page, arriving there still leaves the whole harness around it: sidebar,
  /// transcript, and the settings tab strip. The second half of this script strips that
  /// away so the window shows the market and nothing else.
  ///
  /// Targets are structural on purpose — an ARIA role and an element name, never a
  /// hashed CSS-module class, which changes between harness builds. Both halves are
  /// best-effort: if either hook disappears the window still shows the harness with the
  /// market open, and Go to Market retries.
  static let navigationScript = #"""
  (function () {
    var LABELS = ['插件市场', 'Plugin Market'];
    var attempts = 0;
    function findLabel(nodes) {
      for (var i = 0; i < nodes.length; i++) {
        var text = (nodes[i].textContent || '').trim();
        if (LABELS.indexOf(text) >= 0) { return nodes[i]; }
      }
      return null;
    }
    function findSettingsTrigger() {
      var slot = document.querySelector('[data-slot="sidebar.settings"]');
      if (slot) { return slot; }
      var buttons = document.querySelectorAll('button');
      for (var i = 0; i < buttons.length; i++) {
        var text = (buttons[i].textContent || '').trim();
        if (text === '设置' || text === 'Settings') { return buttons[i]; }
      }
      return null;
    }
    // Blow the settings dialog up to the whole window, drop its tab strip, and make the
    // backdrop opaque so the harness behind it is not visible around the edges.
    function stripChrome(dialog) {
      // The dialog is the only thing that should be visible, so whatever is behind it has
      // to stop showing through. The backdrop is the dialog's previous sibling — that is
      // how the harness renders it — and it is made fully opaque.
      var mask = dialog.previousElementSibling;
      if (mask && mask.getAttribute('aria-hidden') === 'true') {
        var surface = getComputedStyle(document.body).backgroundColor;
        // A transparent body means the surface colour lives elsewhere; Canvas is the
        // system colour and follows the page's colour scheme, light or dark.
        if (!surface || surface === 'transparent' || surface.indexOf('rgba(0, 0, 0, 0)') === 0) {
          surface = 'Canvas';
        }
        mask.style.setProperty('background', surface, 'important');
        mask.style.setProperty('backdrop-filter', 'none', 'important');
        mask.style.setProperty('opacity', '1', 'important');
      }
      var full = [
        'position:fixed', 'inset:0', 'width:100vw', 'height:100vh',
        'max-width:none', 'max-height:none', 'margin:0',
        'border-radius:0', 'box-shadow:none'
      ].join(' !important;') + ' !important';
      dialog.style.cssText = dialog.style.cssText + ';' + full;
      var strip = dialog.querySelector(':scope > nav');
      if (strip) { strip.style.setProperty('display', 'none', 'important'); }
      return true;
    }
    var timer = setInterval(function () {
      attempts += 1;
      if (attempts > 120) { clearInterval(timer); return; }
      var dialog = document.querySelector('[role=dialog][aria-modal="true"]');
      if (!dialog) {
        var trigger = findSettingsTrigger();
        if (trigger) { trigger.click(); }
        return;
      }
      var tab = findLabel(dialog.querySelectorAll('button'));
      // Only touch the layout once the market tab is known and active: stripping the
      // chrome on whatever section happened to be open would show the wrong thing full
      // screen, which is worse than showing the whole harness.
      if (!tab) { return; }
      if (tab.getAttribute('aria-current') !== 'true') { tab.click(); return; }
      stripChrome(dialog);
    }, 300);
  })();
  """#
}
