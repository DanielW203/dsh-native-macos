import AppKit
import AVFoundation
import Combine
import QuartzCore
import SwiftUI

/// The startup animation: one muted pass of the chosen video, over the window's content.
///
/// Deliberately not its own `NSWindow`. The main window owns the harness process and the app
/// quits with its last window, so a separate splash window would add a window-ordering and
/// quit-semantics question to an animation that is only ever shown for a few seconds. It
/// covers the window's content instead — the same place the boot placeholder lives — while
/// the harness boots underneath it.
struct StartupAnimationView: View {
  let onFinish: () -> Void

  /// A reference box so the player is built once per view identity. A plain @State value
  /// would be initialized again on every parent re-render (the booting harness publishes
  /// log lines while the animation plays) and throw the new player away.
  @StateObject private var playback: Playback

  init(url: URL, onFinish: @escaping () -> Void) {
    self.onFinish = onFinish
    _playback = StateObject(wrappedValue: Playback(url: url))
  }

  var body: some View {
    ZStack {
      Color.black
      PlayerLayerView(player: playback.player)
        .allowsHitTesting(false)
      VStack {
        Spacer()
        HStack(spacing: 12) {
          Text("点击任意位置跳过")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.65))
          Spacer()
          Button("跳过") { onFinish() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
          LinearGradient(
            colors: [.clear, .black.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { onFinish() }
    // Best effort: when the WebView below still holds first responder, Esc may be delivered
    // there instead. Clicking anywhere always works, which is why the hint names that.
    .onExitCommand { onFinish() }
    .onAppear {
      playback.player.isMuted = true
      playback.player.play()
    }
    .onDisappear { playback.player.pause() }
    .onReceive(
      NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playback.item)
    ) { _ in
      onFinish()
    }
    .onReceive(playback.item.publisher(for: \.status).removeDuplicates()) { status in
      // A file that passed validation can still fail to decode the first frame. Treat it
      // exactly like a finished video: get out of the way instead of holding a black window.
      if status == .failed { onFinish() }
    }
  }

  /// Owns the item and the player for the life of the view.
  private final class Playback: ObservableObject {
    let item: AVPlayerItem
    let player: AVPlayer

    init(url: URL) {
      item = AVPlayerItem(url: url)
      player = AVPlayer(playerItem: item)
      player.isMuted = true
      player.actionAtItemEnd = .pause
    }
  }
}

/// An `AVPlayerLayer` with no controls or chrome. `AVKit.VideoPlayer` would bring playback
/// UI the animation must not offer.
private struct PlayerLayerView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> PlayerView {
    let view = PlayerView()
    view.player = player
    return view
  }

  func updateNSView(_ nsView: PlayerView, context: Context) {
    nsView.player = player
  }
}

private final class PlayerView: NSView {
  private let playerLayer = AVPlayerLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = CALayer()
    layer?.backgroundColor = NSColor.black.cgColor
    playerLayer.videoGravity = .resizeAspect
    playerLayer.backgroundColor = NSColor.black.cgColor
    layer?.addSublayer(playerLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("PlayerView is created by SwiftUI, never from a nib")
  }

  var player: AVPlayer? {
    get { playerLayer.player }
    set { playerLayer.player = newValue }
  }

  override var isOpaque: Bool { true }

  override func layout() {
    super.layout()
    // No implicit animation: a window resize must not slide the video's frame.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = bounds
    CATransaction.commit()
  }
}
