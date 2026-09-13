import HarnessRuntime
import SwiftUI

/// The sheet behind the Rebuild button.
///
/// It exists for one reason: the interesting part of a rebuild is minutes of compiler output,
/// and a button that silently quits the app for minutes is indistinguishable from a crash.
/// The sheet stays up while `release` runs, then the app quits itself and the hand-off
/// finishes in the background.
struct RebuildSheet: View {
  @ObservedObject var model: RebuildModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if let checkout = model.checkoutPath {
        Text("源码：\(checkout)")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .help(checkout)
      }
      logView
      footer
    }
    .padding(18)
    .frame(width: 780, height: 560)
    .onAppear { model.start() }
    // The build owns a compiler process and a socket to the harness; letting the sheet be
    // dismissed mid-flight would leave both behind with nothing to explain them.
    .interactiveDismissDisabled(model.isRunning)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "hammer.fill")
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 3) {
        Text("重新构建并重启 DSHNative")
          .font(.headline)
        Text(model.stageText)
          .font(.callout)
          .foregroundStyle(model.failure == nil ? .secondary : .primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      if model.isRunning {
        ProgressView()
          .controlSize(.small)
      }
    }
  }

  private var logView: some View {
    ScrollView {
      Text(model.lines.joined(separator: "\n"))
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.secondary.opacity(0.25))
    )
    // Follows the tail of the build without fighting a user who scrolled back.
    .defaultScrollAnchor(.bottom)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button("选择源码目录…") { model.chooseCheckout() }
        .disabled(model.isRunning)
        .help("这台机器上源码不在常见位置时，手动指定仓库根目录；选择会被记住")
      Button("打开构建日志") { model.openLog() }
      Spacer()
      if model.failure != nil {
        Button("重试") { model.retry() }
      }
      Button(model.isRunning ? "进行中…" : "关闭") { model.dismiss() }
        .keyboardShortcut(.cancelAction)
        .disabled(model.isRunning)
    }
  }
}
