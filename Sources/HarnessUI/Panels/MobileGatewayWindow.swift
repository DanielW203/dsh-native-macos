import AppKit
import Foundation
import HarnessMobileGateway
import SwiftUI

/// The 移动设备 window: run the native mobile gateway, pair a phone, and manage what is trusted.
///
/// This is the native counterpart of the plugin's WebUI sidebar panel. It is a window rather than
/// a sidebar entry on purpose: the gateway is an *app-level* service — it must keep serving while
/// no harness page is open — so its controls belong beside the other app-level surfaces in the
/// Harness menu, not inside one page's chrome.
public struct MobileGatewayWindow: View {
  @ObservedObject private var model: MobileGatewayModel
  @State private var now = Date()
  @State private var copied = false
  @State private var publicEndpointInput = ""
  @State private var copiedCommand: String?

  private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  public init(model: MobileGatewayModel) {
    self.model = model
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if let error = model.setupError { banner(error) }
        gatewayCard
        pairingCard
        devicesCard
        addressesCard
        remoteAccessCard
        publicAccessCard
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 620, minHeight: 560)
    .onReceive(ticker) { now = $0 }
    .onAppear {
      model.refresh()
      model.refreshTailscale()
    }
  }

  // MARK: - Sections

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("移动设备").font(.title2.weight(.semibold))
        Spacer()
        statusPill
      }
      Text("ds-mobile-v1 · \(model.status.gatewayName)")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(model.status.gatewayID)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
  }

  private var statusPill: some View {
    let listening = model.status.isListening
    let tone: Color = model.status.mode == .disabled ? .secondary : (listening ? .green : .orange)
    let label: String = model.status.mode == .disabled ? "已关闭" : (listening ? "监听中" : "未监听")
    return HStack(spacing: 6) {
      Circle().fill(tone).frame(width: 8, height: 8)
      Text(label).font(.caption.weight(.medium))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Capsule().fill(Color.secondary.opacity(0.12)))
  }

  private func banner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(message).font(.callout).textSelection(.enabled)
      Spacer()
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
  }

  private var gatewayCard: some View {
    card("网关") {
      VStack(alignment: .leading, spacing: 12) {
        Picker("运行模式", selection: Binding(
          get: { model.status.mode },
          set: { model.setMode($0) }
        )) {
          ForEach(MobileGatewayMode.allCases, id: \.self) { mode in
            Text(mode.localizedName).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        Text(modeExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)

        Divider()

        Toggle("设备鉴权", isOn: Binding(
          get: { model.status.requireAuth },
          set: { model.setRequireAuth($0) }
        ))
        Text("关闭后只有本机连接可以免凭证接入；局域网连接始终必须配对。")
          .font(.caption)
          .foregroundStyle(.secondary)

        Divider()

        labeled("监听地址", listenDescription)
        labeled("已连接设备", "\(model.status.clients) 个连接")
        labeled("harness", model.harnessState)
      }
    }
  }

  private var modeExplanation: String {
    switch model.status.mode {
    case .disabled: return "不接收任何移动端连接。已连接的设备会以 4004 断开。"
    case .temporary:
      if let expiry = model.status.waitExpiresAt, expiry > now.timeIntervalSince1970 * 1000 {
        let seconds = Int((expiry - now.timeIntervalSince1970 * 1000) / 1000)
        return "临时开启中：\(seconds) 秒内没有设备成功连接就会自动关闭。"
      }
      return "临时开启：一旦有设备连接，本次运行将保持开启。"
    case .persistent: return "常驻开启：重启后仍然保持开启，除非手动关闭。"
    }
  }

  private var listenDescription: String {
    if let error = model.status.listenError { return "监听失败：\(error)" }
    guard model.status.mode != .disabled else { return "网关已关闭，连接会收到 503" }
    guard let port = model.status.port else { return "未监听" }
    return "\(model.status.listenHost):\(port)\(MobileGatewayService.webSocketPath)"
  }

  private var pairingCard: some View {
    card("配对") {
      VStack(alignment: .leading, spacing: 12) {
        if let pairing = model.pairing, model.pairingIsLive(now: now) {
          HStack(alignment: .top, spacing: 18) {
            if let image = QRCodeImage.image(for: pairing.qrText) {
              Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 190, height: 190)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white))
            } else {
              RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 190, height: 190)
                .overlay(Text("无法生成二维码").font(.caption))
            }
            VStack(alignment: .leading, spacing: 8) {
              Text(pairing.name).font(.headline)
              Text("用 DeepSeek Harness Mobile 扫描二维码，或手动粘贴下面的内容。配对码只能使用一次。")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(pairing.qrText)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
              HStack(spacing: 8) {
                Button(copied ? "已复制" : "复制配对内容") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(pairing.qrText, forType: .string)
                  copied = true
                  Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                  }
                }
                Button("完成") { model.dismissPairing() }
              }
              Text("剩余有效期 \(remaining(pairing.expiresAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
              Text("设备名称").font(.caption).foregroundStyle(.secondary)
              TextField("例如 iPhone", text: $model.pairingName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
            Button("生成配对码") { model.createPairing() }
              .disabled(model.status.mode == .disabled || !model.isConnectedToHarness)
            if model.status.mode == .disabled {
              Text("先开启网关").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
          }
        }
      }
    }
  }

  private var devicesCard: some View {
    card("可信设备") {
      if model.status.devices.isEmpty {
        Text("还没有已配对的设备。")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(model.status.devices, id: \.id) { device in
            HStack(alignment: .center, spacing: 12) {
              Circle()
                .fill(device.online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
              VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body.weight(.medium))
                Text(lastSeenText(device))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button("撤销") { model.revoke(device.id) }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            .padding(.vertical, 8)
            if device.id != model.status.devices.last?.id { Divider() }
          }
        }
      }
    }
  }

  private var addressesCard: some View {
    card("可用地址") {
      VStack(alignment: .leading, spacing: 6) {
        if model.status.lanURLs.isEmpty && model.status.endpoints.isEmpty {
          Text("没有可广播的地址。").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(model.status.lanURLs, id: \.self) { url in
          Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        ForEach(model.status.endpoints, id: \.self) { url in
          Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
      }
    }
  }

  /// Remote access, which for this gateway means Tailscale: it is the only path that needs
  /// neither a public port nor a certificate, because the tunnel is already encrypted.
  private var remoteAccessCard: some View {
    card("远程访问（Tailscale）") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 8) {
          Circle()
            .fill(model.status.tailscale.isRunning ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 8, height: 8)
            .padding(.top, 5)
          VStack(alignment: .leading, spacing: 4) {
            Text(remoteAccessHeadline).font(.callout.weight(.medium))
            Text(remoteAccessDetail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Button("重新检测") { model.refreshTailscale() }
            .buttonStyle(.borderless)
        }
        installControls
        if let tailnet = model.status.tailscale.tailnet, !tailnet.isEmpty {
          labeled("Tailnet", tailnet)
        }
        ForEach(model.status.tailscaleEndpoints, id: \.self) { url in
          Text(url)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        }
      }
    }
  }

  /// Public access through a Cloudflare Tunnel — or any other TLS terminator the user already has.
  ///
  /// The gateway never runs the tunnel itself: a named tunnel is a long-lived daemon with its own
  /// login and DNS routing, and a quick tunnel publishes an unauthenticated public URL that nobody
  /// controls. What this card does is hand over the exact commands and then advertise whatever
  /// hostname the user brings back.
  private var publicAccessCard: some View {
    card("公网访问（Cloudflare Tunnel）") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 8) {
          Circle()
            .fill(model.cloudflare.isInstalled ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 8, height: 8)
            .padding(.top, 5)
          VStack(alignment: .leading, spacing: 3) {
            Text(model.cloudflare.isInstalled ? "已检测到 cloudflared" : "未安装 cloudflared")
              .font(.callout.weight(.medium))
            Text(model.cloudflare.isInstalled
              ? "隧道由你在终端启动；这里只需要填它的域名。"
              : "安装后即可用一个固定域名从任何网络访问，手机端不需要装任何东西。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
        }

        VStack(alignment: .leading, spacing: 4) {
          commandRow(MobileGatewayCloudflare.installCommand, note: "安装 cloudflared")
          commandRow(MobileGatewayCloudflare.quickTunnelCommand, note: "快速隧道（临时地址，适合先试通）")
          commandRow(MobileGatewayCloudflare.loginCommand, note: "固定域名：登录")
          commandRow(MobileGatewayCloudflare.createTunnelCommand + "  →  " + MobileGatewayCloudflare.routeCommand + "  →  " + MobileGatewayCloudflare.runTunnelCommand,
                     note: "固定域名：建隧道 → 绑定域名 → 运行")
        }

        Divider()

        HStack(alignment: .bottom, spacing: 8) {
          VStack(alignment: .leading, spacing: 4) {
            Text("隧道域名").font(.caption).foregroundStyle(.secondary)
            TextField("dsh.example.com 或 wss://dsh.example.com/ws/mobile", text: $publicEndpointInput)
              .textFieldStyle(.roundedBorder)
              .frame(width: 320)
              .onSubmit { addEndpoint() }
          }
          Button("添加") { addEndpoint() }
          Spacer()
        }
        if let error = model.settingsError {
          Text(error).font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !model.settings.publicEndpoints.isEmpty {
          ForEach(model.settings.publicEndpoints, id: \.self) { endpoint in
            HStack(spacing: 8) {
              Text(endpoint)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
              Spacer()
              Button("移除") { model.removePublicEndpoint(endpoint) }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .font(.caption)
            }
            .padding(.vertical, 4)
          }
        }

        Text("Cloudflare 会在空闲时关闭 WebSocket，所以网关每 \(Int(model.settings.keepAliveInterval)) 秒发一次协议级 ping 保活；这也是家用路由器 NAT 表不把连接丢掉所需要的。代理需要允许较大的 WebSocket 帧（图片经 Base64 后可达上百 MB）。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func addEndpoint() {
    model.addPublicEndpoint(publicEndpointInput)
    if model.settingsError == nil { publicEndpointInput = "" }
  }

  private func commandRow(_ command: String, note: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(note).font(.caption2).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        Text(command)
          .font(.system(.caption2, design: .monospaced))
          .textSelection(.enabled)
          .lineLimit(2)
        Button(copiedCommand == command ? "已复制" : "复制") {
          model.copyCloudflareCommand(command)
          copiedCommand = command
          Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedCommand == command { copiedCommand = nil }
          }
        }
        .buttonStyle(.borderless)
        .font(.caption2)
      }
    }
  }

  /// The built-in install flow, shown only while there is something to install or launch.
  ///
  /// The app never collects an administrator password: the package installs a system extension, and
  /// macOS owns that authorization. Everything here either hands the job to the system or points at
  /// the vendor's own page.
  @ViewBuilder
  private var installControls: some View {
    switch model.status.tailscale.state {
    case .notInstalled:
      VStack(alignment: .leading, spacing: 8) {
        Divider()
        Text("一键安装（需要管理员密码，由 macOS 弹窗询问）")
          .font(.caption.weight(.medium))
        HStack(spacing: 8) {
          Button("下载并打开安装包") { model.installTailscale() }
            .disabled(model.tailscaleInstall == .opened || isDownloading)
          Button("在 App Store 中打开") { model.openTailscaleAppStore() }
          Button("官方下载页") { model.openTailscaleDownloadPage() }
        }
        switch model.tailscaleInstall {
        case .downloading(let progress):
          ProgressView(value: progress)
            .frame(maxWidth: 260)
          Text("正在下载官方安装包… \(Int(progress * 100))%")
            .font(.caption)
            .foregroundStyle(.secondary)
        case .opened:
          Text("已把安装包交给「安装器」。装完请在 系统设置 → 通用 → 登录项与扩展 里允许 Tailscale 的系统扩展，然后登录账号。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
          Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        case .idle:
          Text("也可以用终端安装：")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if model.tailscaleInstall == .idle || isFailed {
          HStack(spacing: 6) {
            Text(MobileGatewayTailscaleInstaller.homebrewCommand)
              .font(.system(.caption2, design: .monospaced))
              .textSelection(.enabled)
            Button("复制") { model.copyHomebrewCommand() }
              .buttonStyle(.borderless)
              .font(.caption)
          }
        }
        Divider()
        Text("安装顺序：1) 装好并打开 Tailscale → 2) 登录 → 3) 允许系统扩展 → 4) 回到这里点「重新检测」→ 5) 手机的 Tailscale 也登录同一账号并打开 VPN。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    case .notRunning:
      VStack(alignment: .leading, spacing: 8) {
        Divider()
        HStack(spacing: 8) {
          Button("打开 Tailscale") { model.openTailscaleApp() }
          Button("在 App Store 中打开") { model.openTailscaleAppStore() }
        }
        Text("登录完成后回到这里点「重新检测」；手机端要登录同一个账号并打开 VPN。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    case .running:
      EmptyView()
    }
  }

  private var isDownloading: Bool {
    if case .downloading = model.tailscaleInstall { return true }
    return false
  }

  private var isFailed: Bool {
    if case .failed = model.tailscaleInstall { return true }
    return false
  }

  private var remoteAccessHeadline: String {
    switch model.status.tailscale.state {
    case .running: return "已接入 tailnet，配对地址已包含远程地址"
    case .notRunning(let reason): return reason
    case .notInstalled: return "未检测到 Tailscale"
    }
  }

  private var remoteAccessDetail: String {
    switch model.status.tailscale.state {
    case .running:
      return "手机端 Tailscale 打开后，用上面的地址即可在任何网络下连接，不需要公网 IP 或证书。"
    case .notRunning:
      return "在 Mac 上打开 Tailscale 并登录后点「重新检测」；手机端也要登录同一个账号并打开。"
    case .notInstalled:
      return "安装 Tailscale（Mac 与 iPhone 登录同一账号）即可获得远程连接；它是唯一不需要公网端口和证书的方式。"
    }
  }

  // MARK: - Building blocks

  private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
  }

  private func labeled(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
      Text(value).font(.callout).textSelection(.enabled)
      Spacer()
    }
  }

  private func remaining(_ expiresAt: Double) -> String {
    let seconds = Int(max(0, (expiresAt - now.timeIntervalSince1970 * 1000) / 1000))
    return seconds >= 60 ? "\(seconds / 60) 分 \(seconds % 60) 秒" : "\(seconds) 秒"
  }

  private func lastSeenText(_ device: MobileGatewayDeviceRegistry.DeviceSummary) -> String {
    guard let lastSeen = device.lastSeenAt else { return "尚未连接过" }
    let date = Date(timeIntervalSince1970: lastSeen / 1000)
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.unitsStyle = .short
    return "最后连接：\(formatter.localizedString(for: date, relativeTo: Date()))"
  }
}
