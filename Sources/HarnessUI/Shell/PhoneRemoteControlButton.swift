import SwiftUI

/// The toolbar switch that lets the phone answer what the harness is waiting on.
///
/// The state lives in the channel service, not in this view: the button is only a face on "is
/// the phone on the hook right now". When it is on it is tinted and carries the number of
/// requests still waiting, so work that is blocked on the phone stays visible from the window
/// the user is actually looking at.
///
/// It is deliberately in-memory in the service: switching it on is a decision about this run,
/// and a setting that survived a restart would silently reroute requests the user has stopped
/// watching for. The session commands (`/list`, `/use`, `/history`, `/say`, `/stop`,
/// `/answer`) do **not** depend on it — they are ordinary chat messages, gated by the
/// channel's sender allowlist — so remote control works with the switch off.
struct PhoneRemoteControlButton: View {
  @ObservedObject var channel: WeChatChannelModel

  var body: some View {
    Button {
      channel.toggleForwardsAllPrompts()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: channel.forwardsAllPrompts ? "iphone.radiowaves.left.and.right" : "iphone")
        Text("手机远控")
        if channel.pendingPromptCount > 0 {
          Text("\(channel.pendingPromptCount)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.orange))
        }
      }
    }
    .foregroundStyle(channel.forwardsAllPrompts ? Color.accentColor : Color.primary)
    .help(channel.phoneControlHelp)
    .disabled(!channel.canForwardPromptsToPhone)
    .accessibilityIdentifier("phone-remote-control-button")
    .accessibilityLabel("手机远控")
    .accessibilityValue(channel.forwardsAllPrompts ? "已开启" : "已关闭")
  }
}
