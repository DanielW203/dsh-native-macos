import AppKit
import CoreImage
import Foundation
import HarnessIM
import SwiftUI

/// The channel window's view model.
///
/// A thin main-actor shell over `WeChatChannelService`: the service owns the provider loop
/// and never touches SwiftUI, and this type turns its status pushes into `@Published` state.
@MainActor
public final class WeChatChannelModel: ObservableObject {
  @Published public private(set) var status = ChannelStatus()
  @Published public var config: ChannelConfig
  @Published public var verificationCode = ""
  @Published public private(set) var lastSavedAt: Date?
  @Published public private(set) var notice: String?

  private let service: WeChatChannelService
  private var terminationObserver: NSObjectProtocol?
  /// The folder the app itself works in, so the channel can land its sessions in the same
  /// workspace the user already has open instead of inventing a second one.
  private let appWorkspace: () -> String

  /// - Parameter appWorkspace: answers "which folder does the app itself work in". Required
  ///   rather than defaulted because the app's own answer lives behind MainActor state that a
  ///   default argument cannot reach.
  public init(
    service: WeChatChannelService,
    initialConfig: ChannelConfig,
    appWorkspace: @escaping () -> String
  ) {
    self.service = service
    self.config = initialConfig
    self.appWorkspace = appWorkspace
    Task { [service] in
      await service.setStatusHandler { [weak self] status in
        Task { @MainActor in
          self?.status = status
          // `/workspace` in WeChat moves the same setting this window edits. Without pulling it
          // back, the card would keep showing the old folder and the next 保存 would silently
          // undo the switch.
          self?.refreshWorkspaceFromService()
        }
      }
      // The service loads the persisted configuration itself; showing the defaults instead
      // would let a save silently overwrite settings the user had already made.
      var stored = await service.currentConfig()
      if stored.workspacePath == nil {
        // First run: default to the folder the app already works in.
        stored.workspacePath = self.appWorkspace()
        await service.update(config: stored)
      }
      self.config = stored
      await service.start()
    }
    // A quit is the one moment the provider is told this client is going away; without it the
    // account can stay marked busy for the next launch.
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [service] _ in
      Task { await service.stop() }
    }
  }

  deinit {
    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
    }
  }

  public var isBound: Bool { status.botID != nil }

  public var phaseLabel: String {
    switch status.phase {
    case .stopped: return "已停止"
    case .loggingIn: return "等待扫码"
    case .connecting: return "连接中"
    case .online: return "在线"
    case .degraded: return "降级运行"
    case .needsLogin: return "未绑定"
    }
  }

  public var phaseTint: Color {
    switch status.phase {
    case .online: return .green
    case .degraded: return .orange
    case .loggingIn, .connecting: return .blue
    default: return .secondary
    }
  }

  public func beginLogin() {
    verificationCode = ""
    Task { await service.beginLogin() }
  }

  public func cancelLogin() {
    Task { await service.cancelLogin() }
  }

  public func submitVerificationCode() {
    let code = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else { return }
    verificationCode = ""
    Task { await service.submitVerificationCode(code) }
  }

  public func disconnect() {
    Task { await service.disconnect() }
  }

  public func restart() {
    Task {
      await service.stop()
      await service.start()
    }
  }

  /// Point the channel at a folder. The cached workspace id belongs to the old path, so it is
  /// dropped here rather than trusted — the next submission re-registers the new folder.
  public func setWorkspace(path: String) {
    config.workspacePath = path
    config.workspaceID = nil
    saveConfig()
  }

  /// Pull back the folder the channel is actually using.
  ///
  /// Only these two fields: they are the ones the service can change behind the window's back
  /// (a `/workspace` command from the phone). The trigger/cancel/ack fields are the user's
  /// in-progress edits and must not be clobbered by a status push.
  private func refreshWorkspaceFromService() {
    Task { @MainActor [service, weak self] in
      let stored = await service.currentConfig()
      guard let self else { return }
      if self.config.workspacePath != stored.workspacePath {
        self.config.workspacePath = stored.workspacePath
      }
      if self.config.workspaceID != stored.workspaceID {
        self.config.workspaceID = stored.workspaceID
      }
    }
  }

  public func useAppWorkspace() {
    notice = nil
    setWorkspace(path: appWorkspace())
  }

  /// Whether the harness has been told about this folder yet.
  public var workspaceRegistrationLabel: String {
    guard config.workspacePath != nil else { return "未选择" }
    guard let id = config.workspaceID, !id.isEmpty else { return "保存后自动登记" }
    return "已登记（\(id.prefix(8))…）"
  }

  public func saveConfig() {
    let issues = config.validationIssues()
    guard issues.isEmpty else {
      notice = issues.joined(separator: "；")
      return
    }
    notice = nil
    lastSavedAt = Date()
    Task { await service.update(config: config) }
  }

  /// The app just learned the harness's address: re-run the repair pass, which is how a
  /// session recorded before the workspace existed becomes visible in the sidebar.
  public func harnessBecameAvailable() {
    Task {
      await service.attachStoredSessions()
      // Approvals can only be answered while the event stream is open, so it is opened with
      // the same trigger that repairs workspace registration.
      await service.startPromptRelay()
    }
  }

  /// Re-attach on demand from the window (after the user fixes a workspace choice, say).
  public func reattachSessions() {
    Task { await service.attachStoredSessions() }
  }

  public func clearBatch(sender: String) {
    Task { _ = await service.clearBatch(sender: sender) }
  }

  // MARK: - Phone remote control

  /// Whether approvals and questions from *every* session — desktop ones included — are going
  /// to the phone.
  ///
  /// Read through `status` rather than mirrored into a second `@Published`: the service is the
  /// one place that knows, and two copies would drift the moment the channel stops or unbinds.
  public var forwardsAllPrompts: Bool { status.forwardsAllPrompts }

  /// How many requests the phone is still holding an answer for.
  public var pendingPromptCount: Int { status.pendingPrompts }

  /// Whether the switch can do anything right now: without a bound bot there is no phone to
  /// ask, so the button explains that instead of pretending to work.
  public var canForwardPromptsToPhone: Bool { isBound }

  public func setForwardsAllPrompts(_ on: Bool) {
    Task { await service.setForwardsAllPrompts(on) }
  }

  public func toggleForwardsAllPrompts() {
    setForwardsAllPrompts(!forwardsAllPrompts)
  }

  /// The button's tooltip: what the switch controls, and what works without it.
  ///
  /// The distinction matters because the two surfaces are independent — the commands are
  /// ordinary chat messages and the switch only governs what the harness pushes *at* the phone.
  public var phoneControlHelp: String {
    guard isBound else {
      return "手机远控：需要先绑定微信机器人（Harness 菜单 → WeChat Channel）"
    }
    let commands = "会话命令（/list 列表、/use 接管、/history 历史、/say 续聊、/stop 中断）随时可用，发 /help 看全部。"
    if forwardsAllPrompts {
      // The switch is intent; delivery needs the bot online. Claiming "已开启" while nothing
      // can go out would leave the user waiting on a request that was never sent.
      var text = """
      手机远控已开启：任何会话需要你批准或回答时都会发到微信，直接回「批准」/「拒绝」，或按提示 /answer 作答。桌面弹窗仍然可用，先答的先生效。
      \(commands)
      点击关闭。
      """
      if !status.canSubmit { text += "（微信当前未在线，恢复后才会送出。）" }
      return text
    }
    return """
    手机远控已关闭：桌面会话的审批与提问只在 app 里回答；来自微信的会话仍会照旧转发到微信。
    \(commands)
    点击开启后，所有会话的审批与提问都会推到手机。
    """
  }

  /// Buffered batches, newest activity first, for the preview list.
  public var batches: [(sender: String, snapshot: BatchSnapshot)] {
    status.batches
      .filter { !$0.value.isEmpty }
      .map { (sender: $0.key, snapshot: $0.value) }
      .sorted { $0.sender < $1.sender }
  }
}

/// The WeChat channel window: binding, buffering state, and the knobs that shape a batch.
public struct WeChatChannelWindow: View {
  @ObservedObject private var model: WeChatChannelModel

  public init(model: WeChatChannelModel) {
    _model = ObservedObject(wrappedValue: model)
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        statusCard
        if model.status.phase == .loggingIn { loginCard }
        if model.isBound { configCard; batchCard; capabilityCard }
        if let notice = model.notice {
          Label(notice, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .font(.callout)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 620, minHeight: 620)
  }

  private var statusCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Circle().fill(model.phaseTint).frame(width: 10, height: 10)
          Text(model.phaseLabel).font(.headline)
          Spacer()
          if model.isBound {
            Button("重新连接") { model.restart() }
            Button("断开绑定") { model.disconnect() }
          } else if model.status.phase == .loggingIn {
            Button("取消") { model.cancelLogin() }
          } else {
            Button("扫码绑定微信") { model.beginLogin() }
              .keyboardShortcut(.defaultAction)
          }
        }
        if let botID = model.status.botID {
          labelled("机器人", botID)
        }
        if let owner = model.status.ownerUserID {
          labelled("使用者", owner)
        }
        if model.isBound {
          // The same switch the window toolbar carries: this is the settings home for the
          // channel, and a state only one of the two surfaces could show would drift.
          Toggle("手机远控推送（所有会话的审批与提问都发到微信）", isOn: Binding(
            get: { model.forwardsAllPrompts },
            set: { model.setForwardsAllPrompts($0) }
          ))
          .toggleStyle(.switch)
          .help(model.phoneControlHelp)
          Text("会话远控命令（/list、/use、/history、/say、/stop、/answer）不需要这个开关，在微信里直接发即可。")
            .font(.caption)
            .foregroundStyle(.secondary)
          if model.pendingPromptCount > 0 {
            Text("有 \(model.pendingPromptCount) 条请求等你在微信里回答。")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        if let detail = model.status.detail {
          labelled("状态", detail)
        }
        if let error = model.status.lastError {
          labelled("最近错误", error)
        }
        Text("这个渠道跑在 app 内，只向正在运行的 harness 提交会话；它不安装、不修改、也不重启 harness。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(6)
    } label: {
      Label("微信渠道", systemImage: "message")
    }
  }

  private var loginCard: some View {
    GroupBox {
      HStack(alignment: .top, spacing: 16) {
        if let content = model.status.loginQRContent, let image = QRCodeImage.image(for: content) {
          Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .frame(width: 180, height: 180)
            .background(Color.white)
            .cornerRadius(6)
        } else {
          ProgressView().frame(width: 180, height: 180)
        }
        VStack(alignment: .leading, spacing: 10) {
          Text("用微信扫描二维码，把这个 bot 绑定到 app。").font(.callout)
          Text("绑定用的是**新的**机器人账号：dsh-im 里那个微信渠道可以继续用，两边不会抢消息。")
            .font(.caption)
            .foregroundStyle(.secondary)
          if let expiresAt = model.status.loginExpiresAt {
            Text("二维码有效期至 \(expiresAt.formatted(date: .omitted, time: .standard))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if model.status.loginNeedsVerifyCode {
            HStack {
              TextField("配对码", text: $model.verificationCode)
                .frame(width: 120)
              Button("提交") { model.submitVerificationCode() }
            }
          }
        }
        Spacer()
      }
      .padding(6)
    } label: {
      Label("扫码绑定", systemImage: "qrcode")
    }
  }

  private var configCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("工作区")
          Text(model.config.workspacePath ?? "未选择")
            .foregroundStyle(model.config.workspacePath == nil ? .orange : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(model.workspaceRegistrationLabel)
            .font(.caption)
            .foregroundStyle(model.config.workspaceID == nil ? Color.secondary : Color.green)
          Spacer()
          Button("使用 app 当前工作区") { model.useAppWorkspace() }
          Button("重新登记会话") { model.reattachSessions() }
          Button("选择…") { chooseWorkspace() }
        }
        Text("微信会话会登记到所选工作区；登记后可在 harness 侧栏看到这些会话与推理过程。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("也可以直接在微信里发 /workspace 查看和切换工作区（会解绑当前的微信会话）。")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 12) {
          labelledField("触发词", text: $model.config.triggerPhrase)
          labelledField("取消词", text: $model.config.cancelPhrase)
        }
        HStack(spacing: 12) {
          Picker("回执", selection: $model.config.ackPolicy) {
            Text("每批一次").tag(AckPolicy.oncePerBatch)
            Text("每条").tag(AckPolicy.everyMessage)
            Text("不回执").tag(AckPolicy.silent)
          }
          .frame(width: 220)
          Spacer()
          if let saved = model.lastSavedAt {
            Text("已保存 \(saved.formatted(date: .omitted, time: .standard))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Button("保存") { model.saveConfig() }
            .disabled(!model.config.isValid)
        }
        Text("在微信里发「\(model.config.triggerPhrase)」提交整批内容；发「\(model.config.cancelPhrase)」清空。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(6)
    } label: {
      Label("提交设置", systemImage: "slider.horizontal.3")
    }
  }

  private var batchCard: some View {
    GroupBox {
      if model.batches.isEmpty {
        Text("当前没有等待提交的内容。")
          .foregroundStyle(.secondary)
          .font(.callout)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.batches, id: \.sender) { entry in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.sender).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(describe(entry.snapshot))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button("清空") { model.clearBatch(sender: entry.sender) }
            }
          }
        }
      }
    } label: {
      Label("待提交缓冲", systemImage: "tray.full")
    }
  }

  @ViewBuilder
  private var capabilityCard: some View {
    if let capabilities = model.status.capabilities {
      GroupBox {
        VStack(alignment: .leading, spacing: 6) {
          capabilityRow("创建会话", capabilities.canCreateSession)
          capabilityRow("登记工作区", capabilities.canCreateWorkspace)
          capabilityRow("上传附件", capabilities.canUploadFiles)
          capabilityRow("停止任务", capabilities.canCancelSession)
          capabilityRow("分页读取", capabilities.canPageSession)
          ForEach(capabilities.notes, id: \.self) { note in
            Label(note, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        .padding(6)
      } label: {
        Label("harness 能力（启动提交时探测）", systemImage: "wand.and.stars")
      }
    }
  }

  private func labelled(_ name: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
      Text(value).font(.callout).textSelection(.enabled)
    }
  }

  private func labelledField(_ name: String, text: Binding<String>) -> some View {
    HStack(spacing: 6) {
      Text(name).font(.caption).foregroundStyle(.secondary)
      TextField(name, text: text).frame(width: 110)
    }
  }

  private func capabilityRow(_ name: String, _ available: Bool) -> some View {
    HStack(spacing: 6) {
      Image(systemName: available ? "checkmark.circle" : "xmark.circle")
        .foregroundStyle(available ? .green : .orange)
      Text(name).font(.callout)
    }
  }

  private func describe(_ snapshot: BatchSnapshot) -> String {
    var parts = ["\(snapshot.messageCount) 条消息"]
    if snapshot.attachmentCount > 0 {
      parts.append("\(snapshot.attachmentCount) 个附件")
      parts.append(ByteCountFormatter.string(fromByteCount: Int64(snapshot.attachmentBytes), countStyle: .file))
    }
    return parts.joined(separator: " · ")
  }

  private func chooseWorkspace() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "选择微信渠道提交任务时使用的工作区"
    if let current = model.config.workspacePath {
      panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.setWorkspace(path: url.path)
  }
}

/// Renders the provider's QR content.
enum QRCodeImage {
  static func image(for content: String) -> NSImage? {
    guard !content.isEmpty, let data = content.data(using: .utf8) else { return nil }
    let filter = CIFilter(name: "CIQRCodeGenerator")
    filter?.setValue(data, forKey: "inputMessage")
    filter?.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter?.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let context = CIContext()
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
  }
}
