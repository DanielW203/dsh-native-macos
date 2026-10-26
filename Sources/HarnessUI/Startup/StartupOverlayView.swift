import SwiftUI
import WebKit

/// The launch surface: a dark, local HTML/SVG/CSS animation in a dedicated web view,
/// layered above the real harness page while it boots.
struct StartupOverlayView: View {
  let boot: HarnessWindowModel
  @ObservedObject var experience: StartupExperienceModel
  let mode: StartupOverlayController.Mode
  let safeMode: Bool
  let onOpenRecovery: () -> Void

  @StateObject private var controller: StartupOverlayController

  init(
    boot: HarnessWindowModel,
    experience: StartupExperienceModel,
    mode: StartupOverlayController.Mode,
    safeMode: Bool,
    onOpenRecovery: @escaping () -> Void
  ) {
    self.boot = boot
    self.experience = experience
    self.mode = mode
    self.safeMode = safeMode
    self.onOpenRecovery = onOpenRecovery
    _controller = StateObject(wrappedValue: StartupOverlayController(
      boot: boot,
      mode: mode,
      safeMode: safeMode,
      onHandoff: {
        experience.dismiss()
      },
      onUnavailable: { reason in
        boot.recordBootNote("启动动画降级：\(reason)")
        experience.dismiss()
      },
      onOpenRecovery: {
        experience.dismiss()
        onOpenRecovery()
      }
    ))
  }

  var body: some View {
    ZStack {
      // The dark backdrop covers the web view's first frame, but it must be gone before the
      // handoff fade: a persistent opaque SwiftUI layer behind the web view would hide the
      // real page and make the fade look like an abrupt swap.
      if !controller.hasLoaded {
        LinearGradient(
          colors: [
            Color(red: 0.031, green: 0.051, blue: 0.086),
            Color(red: 0.027, green: 0.043, blue: 0.071),
            Color(red: 0.016, green: 0.027, blue: 0.047),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
      }

      StartupWebView(webView: controller.webView)
        .accessibilityLabel("DeepSeek Harness 正在启动")
    }
    .onAppear { controller.start() }
    .onDisappear { controller.stop() }
  }
}

/// SwiftUI wrapper for the launch web view. The instance is owned by the controller so a
/// re-render never reloads the page.
private struct StartupWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView { webView }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
