import AppKit
import HarnessKit
import HarnessRuntime
import SwiftUI

/// The recovery window: what to do when the harness will not boot.
///
/// It is a window rather than a startup interception because this app cannot be broken by a
/// plugin: a plugin only affects whether the harness process starts, and the menu bar — the
/// thing that opens this window — is drawn by the shell before any of that. What was
/// missing was a surface that acts on the *real* profile while the Web UI is unavailable,
/// which is exactly what this is: every action here edits the user's own home, even when
/// the running harness is in a disposable one.
public struct HarnessRecoveryWindow: View {
  @ObservedObject var recovery: HarnessRecoveryModel
  @ObservedObject var console: HarnessConsoleModel

  @State private var pending: PendingSwitch?
  @State private var confirmDeleteRescue = false
  @State private var confirmRestore: String?
  @State private var confirmClear = false

  public init(recovery: HarnessRecoveryModel, console: HarnessConsoleModel) {
    self.recovery = recovery
    self.console = console
  }

  /// A mode change that is waiting for confirmation. Restarting the app is the disruptive
  /// part, so it is the part that gets asked about.
  private struct PendingSwitch: Identifiable {
    let id = UUID()
    let mode: SafeBootMode?
    var title: String

    /// What the restart will and will not isolate, restated at the moment of consent.
    var message: String {
      switch mode {
      case nil:
        return "会用 profile web + 真实 home 重启，和你平时使用完全一致。"
      case .rescue:
        return "会用 profile \(SafeBoot.rescueProfileName) + 真实 home 重启：只加载官方 bundle，"
          + "凭据、会话和设置保持可用。"
      case .cleanHome:
        return "会用一次性 home 重启：不读你的插件、会话、凭据、settings 和 cordis.patch.yml。"
          + "诊断期间产生的会话不会保留。"
      }
    }
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          modeSection
          Divider()
          repairSection
          Divider()
          rollbackSection
          Divider()
          dataSection
        }
        .padding(16)
      }
      Divider()
      ConsoleStatusStrip(model: console)
    }
    .frame(minWidth: 860, minHeight: 640)
    .task { await recovery.refresh() }
    .confirmationDialog(
      pending?.title ?? "",
      isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
      presenting: pending
    ) { request in
      Button("重启并切换") {
        let mode = request.mode
        pending = nil
        Task { await recovery.selectMode(mode) }
      }
      Button("取消", role: .cancel) { pending = nil }
    } message: { request in
      Text(request.message)
    }
    .confirmationDialog(
      "删除 rescue profile？",
      isPresented: $confirmDeleteRescue
    ) {
      Button("删除", role: .destructive) {
        Task { await recovery.removeRescueProfile() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只会删除 home/profiles/rescue（三个声明文件），不会动会话、设置或其它 profile。")
    }
    .confirmationDialog(
      "还原检查点 \(confirmRestore ?? "")？",
      isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })
    ) {
      Button("停止 harness 并还原", role: .destructive) {
        let slot = confirmRestore
        confirmRestore = nil
        Task { if let slot { await recovery.restore(slot) } }
      }
      Button("取消", role: .cancel) { confirmRestore = nil }
    } message: {
      Text("会先停止 harness，再把声明式配置写回。不会运行 pnpm，也不会改 node_modules——依赖可能需要自行重装。")
    }
    .confirmationDialog("清除所有检查点？", isPresented: $confirmClear) {
      Button("清除", role: .destructive) {
        Task { await recovery.clearCheckpoints() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("三个槽都会被删除；之后只有新的健康启动才会重新记录。")
    }
  }

  // MARK: - Chrome

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "cross.case")
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("恢复模式").font(.headline)
        Text("真实 DSH_HOME \(recovery.dshHome)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer()
      if recovery.isBusy {
        ProgressView().controlSize(.small)
      }
      Button {
        Task { await recovery.refresh() }
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
      }
      .disabled(recovery.isBusy)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: - Mode

  private var modeSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("启动模式").font(.title3.weight(.semibold))
      Text("三个模式隔离的东西不同，顺序就是诊断顺序：先摘插件，再摘整个 home。")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let banner = recovery.banner {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(banner.title).font(.callout.weight(.medium))
            Text(banner.detail).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
      }

      if let note = recovery.note {
        Text(note).font(.caption).foregroundStyle(.secondary)
      }

      modeRow(
        title: "正常启动",
        body: "profile web，真实 home。和你平时用的一模一样。",
        selected: recovery.mode == nil,
        action: { ask(.init(mode: nil, title: "返回正常启动？")) }
      )
      modeRow(
        title: "安全模式 · 无插件（\(SafeBoot.rescueProfileName)）",
        body: "真实 home + 只含官方 bundle 的 profile。API key、会话、设置都还在；第三方插件不会载入。"
          + (recovery.rescueProfileExists ? "" : "该 profile 还不存在，切换时会用官方 web 模板创建。"),
        selected: recovery.mode == .rescue,
        action: { ask(.init(mode: .rescue, title: "以安全模式重启？")) }
      )
      modeRow(
        title: "干净环境",
        body: "一次性 home：没有插件、会话、凭据，也不读你的 cordis.patch.yml 和 settings。退出后自动删除。",
        selected: recovery.mode == .cleanHome,
        action: { ask(.init(mode: .cleanHome, title: "以干净环境重启？")) }
      )
    }
  }

  private func modeRow(
    title: String,
    body: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: selected ? "largecircle.fill.circle" : "circle")
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(selected ? .semibold : .regular))
        Text(body).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      Button(selected ? "当前" : "切换…", action: action)
        .disabled(selected || recovery.isBusy)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.2))
    )
  }

  private func ask(_ request: PendingSwitch) {
    pending = request
  }

  // MARK: - Repair

  private var repairSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("配置检查与修复").font(.title3.weight(.semibold))
      Text("对 profile \(console.selectedProfile) 生效。检查只组合并试导入，不启动任何进程；修复会一轮轮真实启动，直到找出起不来的插件。")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Button {
          Task { await console.inspectProfile() }
        } label: {
          Label("检查（不启动）", systemImage: "stethoscope")
        }
        .disabled(console.isBusy)

        Button {
          Task { await console.quarantineProfile() }
        } label: {
          Label("停用坏插件并重试", systemImage: "wrench.and.screwdriver")
        }
        .disabled(console.isBusy)
      }

      if let failure = console.pluginsFailure {
        Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
      }

      HStack(alignment: .top, spacing: 8) {
        Image(systemName: recovery.rescueProfileExists ? "checkmark.seal" : "seal")
          .foregroundStyle(recovery.rescueProfileExists ? Color.green : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(recovery.rescueProfileExists ? "rescue profile 已存在" : "rescue profile 尚未创建")
            .font(.callout)
          Text("它是安全模式启动的 profile：只含官方 bundle，创建时是三个声明文件，不含你改过的内容。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Button("删除…") { confirmDeleteRescue = true }
          .disabled(!recovery.rescueProfileExists || recovery.isBusy)
      }
      .padding(8)
      .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  // MARK: - Rollback

  private var rollbackSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("回滚").font(.title3.weight(.semibold))
      Text("每次 harness 确认在监听之后会记录一份声明式配置的快照。还原只写回这些文件，不运行 pnpm、不动 node_modules。")
        .font(.caption)
        .foregroundStyle(.secondary)

      if recovery.checkpoints.isEmpty {
        Text("还没有检查点：成功启动一次 harness 之后就会出现。")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(recovery.checkpoints) { record in
          checkpointRow(record)
        }
      }

      if let preview = recovery.lastPreview {
        VStack(alignment: .leading, spacing: 2) {
          Text("预览 \(preview.slot)（\(preview.profile)，\(preview.createdAt)）").font(.callout.weight(.medium))
          if preview.isEmpty {
            Text("和当前配置完全一致，没有需要还原的内容。").font(.caption).foregroundStyle(.secondary)
          } else {
            if !preview.changed.isEmpty {
              Text("将被改回：\(preview.changed.joined(separator: "、"))")
                .font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !preview.missing.isEmpty {
              Text("将重新创建：\(preview.missing.joined(separator: "、"))")
                .font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled)
            }
          }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
      }

      HStack(spacing: 8) {
        Button("清除全部检查点…") { confirmClear = true }
          .disabled(recovery.checkpoints.isEmpty || recovery.isBusy)
        Spacer()
        Button("在 Finder 中显示检查点") { recovery.revealCheckpoints() }
          .disabled(!FileManager.default.fileExists(atPath: recovery.checkpointsPath))
      }
    }
  }

  private func checkpointRow(_ record: ProfileCheckpointRecord) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(record.id) · \(record.reason)").font(.callout.weight(.medium))
        Text("\(record.createdAt) · profile \(record.profile) · \(record.files.count) 个文件"
          + (record.harnessRelease.map { " · harness \($0)" } ?? ""))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      Button("预览") {
        Task { await recovery.previewRestore(record.id) }
      }
      .disabled(recovery.isBusy)
      Button("还原…") { confirmRestore = record.id }
        .disabled(recovery.isBusy)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - Data

  private var dataSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("数据与诊断").font(.title3.weight(.semibold))
      labelled("DSH_HOME", recovery.dshHome)
      labelled("日志", recovery.logsPath)
      if let release = console.activeReleaseID {
        labelled("harness release", release)
      }
      if let toolchain = console.toolchain {
        labelled("Node", "\(toolchain.nodeVersion) [\(toolchain.nodeOrigin.rawValue)]")
      }
      HStack(spacing: 8) {
        Button("打开数据目录") { recovery.revealDataHome() }
        Button("打开日志目录") { recovery.revealLogs() }
        Button("复制日志路径") { recovery.copyLogPath() }
      }
    }
  }

  private func labelled(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
      Text(value).font(.caption.monospaced()).textSelection(.enabled)
        .lineLimit(1).truncationMode(.middle)
    }
  }
}
