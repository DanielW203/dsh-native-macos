import AppKit
import Foundation
import HarnessSkills
import SwiftUI

/// The 技能中心 window: what the harness finds in a workspace's skill roots, the two switches
/// that decide whether a skill may be invoked, and the file operations behind them.
///
/// A native window rather than a page of the Web UI, for the same reason the skin manager is
/// one: this is a profile-level surface the menu bar owns, and it has to keep working on a page
/// some plugin or skin has rendered wrong. It manages the *file-system* skills only — a packaged
/// `bundled` skill and a `runtime` registration have no file to rewrite, and the footer says so
/// instead of pretending they are missing.
public struct SkillCenterWindow: View {
  @ObservedObject private var model: SkillCenterModel
  @State private var showingCreate = false
  @State private var showingImport = false
  @State private var showingTrash = false
  @State private var pendingDelete: SkillRecord?

  public init(model: SkillCenterModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      messageArea
      content
      Divider()
      footer
    }
    .frame(minWidth: 820, minHeight: 560)
    .onAppear { model.startIfNeeded() }
    .sheet(isPresented: $showingCreate) {
      CreateSkillSheet(model: model)
    }
    .sheet(isPresented: $showingImport) {
      ImportSkillSheet(model: model)
    }
    .sheet(isPresented: $showingTrash) {
      SkillTrashSheet(model: model)
    }
    .confirmationDialog(
      pendingDelete.map { "把「\($0.name)」移入回收站？" } ?? "",
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      ),
      presenting: pendingDelete
    ) { skill in
      Button("移入回收站", role: .destructive) { model.delete(skill) }
      Button("取消", role: .cancel) {}
    } message: { skill in
      Text("文件会被移动到 \(skill.rootURL.appendingPathComponent(".trash").path)，可以随时恢复，也可以在那里彻底删除。")
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("技能中心").font(.title2.weight(.semibold))
        Spacer()
        Button("刷新") { model.refresh() }
        Button("新建技能…") { showingCreate = true }
        Button("导入…") { showingImport = true }
        Button(model.trashCount == 0 ? "回收站" : "回收站（\(model.trashCount)）") {
          model.refreshTrash()
          showingTrash = true
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text("工作区 \(model.workspace)")
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
        Text("项目根 \(model.projectRoot) · harness home \(model.dshHome)")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
      }
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("按技能名、描述或适用场景过滤", text: $model.searchText)
          .textFieldStyle(.plain)
        if !model.searchText.isEmpty {
          Button {
            model.searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("清空过滤")
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
    }
    .padding(20)
  }

  // MARK: - Messages

  @ViewBuilder
  private var messageArea: some View {
    if model.failure != nil || model.status != nil || !model.warnings.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        if let failure = model.failure {
          banner(failure, tone: .red, icon: "exclamationmark.triangle.fill")
        } else if let status = model.status {
          banner(status, tone: .green, icon: "checkmark.circle.fill")
        }
        ForEach(model.warnings, id: \.self) { warning in
          banner(warning, tone: .orange, icon: "exclamationmark.circle")
        }
        if model.failure != nil || model.status != nil {
          Button("清除提示") { model.clearMessages() }
            .buttonStyle(.link)
            .font(.caption)
        }
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 12)
    }
  }

  private func banner(_ message: String, tone: Color, icon: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: icon).foregroundStyle(tone)
      Text(message).font(.callout).textSelection(.enabled)
      Spacer()
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10).fill(tone.opacity(0.12)))
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if model.groups.isEmpty {
      emptyState
    } else if model.visibleGroups.isEmpty {
      VStack(spacing: 6) {
        Text("没有匹配「\(model.searchText)」的技能。").foregroundStyle(.secondary)
        Button("清空过滤") { model.searchText = "" }.buttonStyle(.link)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          ForEach(model.visibleGroups) { group in
            groupSection(group)
          }
          Text(
            "系统内置（bundled）与运行时注册（runtime）的技能由 harness 的注册表直接提供，没有可以改写的文件，因此不在这个列表里；这里管理的都是技能根下的文件。"
          )
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("这个工作区还没有技能根。").font(.headline)
      Text("用户根是 \(model.dshHome)/skills，项目根是 <项目>/.dsh/skills。用「新建技能…」写第一个，或「导入…」把已有的目录 / .md / 压缩包放进来。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(20)
  }

  private func groupSection(_ group: SkillGroup) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(group.root.kind.title).font(.headline)
        Text("\(group.skills.count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        Spacer()
        Text(group.root.url.path)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
      }
      Text(group.root.kind.hint).font(.caption).foregroundStyle(.secondary)
      VStack(spacing: 6) {
        ForEach(group.skills) { skill in
          SkillRow(
            skill: skill,
            model: model,
            onDelete: { pendingDelete = skill }
          )
        }
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 12) {
      Text("\(model.allSkills.count) 个技能 · \(model.loadableCount) 个可加载")
        .font(.caption)
        .foregroundStyle(.secondary)
      if model.brokenCount > 0 {
        Text("\(model.brokenCount) 个无法加载")
          .font(.caption.weight(.medium))
          .foregroundStyle(.orange)
      }
      Spacer()
      if let refreshedAt = model.refreshedAt {
        Text("扫描于 \(SkillCenterWindow.timeFormatter.string(from: refreshedAt))")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      if let busy = model.busyLabel {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(busy).font(.caption)
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter
  }()
}

// MARK: - One skill

/// One row: what the skill is, whether it may be invoked, and the two file actions.
private struct SkillRow: View {
  let skill: SkillRecord
  @ObservedObject var model: SkillCenterModel
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(skill.name).font(.callout.weight(.semibold))
          if skill.form == .flat {
            badge("单文件", tone: .secondary)
          }
          if skill.isLinked {
            badge("链接", tone: .blue)
          }
          if let shadowedBy = skill.shadowedBy {
            badge("被 \(shadowedBy.title) 覆盖", tone: .orange)
          }
          if skill.issue != nil {
            badge("无法加载", tone: .red)
          }
        }
        Text(skill.summary)
          .font(.caption)
          .foregroundStyle(skill.issue == nil ? Color.secondary : Color.red)
          .fixedSize(horizontal: false, vertical: true)
        if let whenToUse = skill.whenToUse {
          Text("适用：\(whenToUse)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(skill.entryURL.path)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      VStack(alignment: .leading, spacing: 4) {
        Toggle(
          "模型调用",
          isOn: Binding(
            get: { skill.modelInvocable },
            set: { model.setModelInvocable(skill, to: $0) }
          )
        )
        .help("关闭后写入 disable-model-invocation: true —— 这个技能不再进入模型的技能目录")
        Toggle(
          "手动 /\(skill.name)",
          isOn: Binding(
            get: { skill.userInvocable },
            set: { model.setUserInvocable(skill, to: $0) }
          )
        )
        .help("关闭后写入 user-invocable: false —— 斜杠命令列表里不再出现它")
      }
      .toggleStyle(.switch)
      .controlSize(.mini)
      .font(.caption)
      .frame(width: 190, alignment: .leading)
      .disabled(!skill.isEditable)

      HStack(spacing: 6) {
        Button {
          model.reveal(skill.entryURL)
        } label: {
          Image(systemName: "folder")
        }
        .help("在 Finder 中显示")
        Button(role: .destructive) {
          onDelete()
        } label: {
          Image(systemName: "trash")
        }
        .disabled(!skill.isDeletable)
        .help(skill.isDeletable ? "移入回收站" : "符号链接技能不能在这里删除")
      }
      .buttonStyle(.borderless)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    .opacity(skill.isLoadable ? 1 : 0.75)
  }

  private func badge(_ text: String, tone: Color) -> some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(tone.opacity(0.16)))
      .foregroundStyle(tone)
  }
}

// MARK: - Create

/// The create form. Generates the same SKILL.md the Web plugin's skill centre does, so a skill
/// written here is a skill written there.
private struct CreateSkillSheet: View {
  @ObservedObject var model: SkillCenterModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft = SkillDraft()
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("新建技能").font(.headline)
      Text("写出标准 SKILL.md：name 必须是 kebab-case，description 决定模型能不能判断该用这个技能。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      field("技能名") {
        TextField("my-skill", text: $draft.name)
          .textFieldStyle(.roundedBorder)
      }
      field("描述") {
        TextField("一句话说明它能做什么、什么时候用", text: $draft.summary)
          .textFieldStyle(.roundedBorder)
      }
      field("适用场景（可选）") {
        TextField("whenToUse，写进 frontmatter", text: $draft.whenToUse)
          .textFieldStyle(.roundedBorder)
      }
      field("写入位置") {
        VStack(alignment: .leading, spacing: 3) {
          Picker("", selection: $draft.root) {
            ForEach(SkillWriteRoot.allCases) { root in
              Text(root.title).tag(root)
            }
          }
          .labelsHidden()
          Text("\(draft.root.hint) · \(model.writeRootDirectory(draft.root))")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("正文（Markdown）").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $draft.content)
          .font(.system(.callout, design: .monospaced))
          .frame(height: 150)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
      }

      if let error {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
          Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("创建") {
          if model.create(draft) {
            dismiss()
          } else {
            error = model.failure
          }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 560)
  }

  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      content()
    }
  }
}

// MARK: - Import

/// Importing an existing skill: a directory bundle, a single `.md`, or a `.zip` / `.tar.gz`.
private struct ImportSkillSheet: View {
  @ObservedObject var model: SkillCenterModel
  @Environment(\.dismiss) private var dismiss
  @State private var source: URL?
  @State private var root: SkillWriteRoot = .user
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("导入技能").font(.headline)
      Text("支持：含 SKILL.md 的目录、单个 .md、.zip、.tar.gz / .tgz。压缩包会先解到临时目录再定位技能；目标目录按 frontmatter 的 name 命名。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        Button("选择文件夹、.md 或压缩包…") { chooseSource() }
        if let source {
          Text(source.path)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }

      VStack(alignment: .leading, spacing: 3) {
        Picker("写入位置", selection: $root) {
          ForEach(SkillWriteRoot.allCases) { choice in
            Text(choice.title).tag(choice)
          }
        }
        Text("\(root.hint) · \(model.writeRootDirectory(root))")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
      }

      if let error {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
          Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("导入") {
          guard let source else { return }
          if model.importSkill(from: source, into: root) {
            dismiss()
          } else {
            error = model.failure
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(source == nil)
      }
    }
    .padding(20)
    .frame(width: 560)
  }

  private func chooseSource() {
    // Without this the panel can open behind the active application, which looks exactly like
    // the button having done nothing at all.
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "选择含 SKILL.md 的目录、单个 .md，或 .zip / .tar.gz"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    source = url
    error = nil
  }
}

// MARK: - Trash

/// The recoverable half of delete: what is in the roots' `.trash`, and how to put it back.
private struct SkillTrashSheet: View {
  @ObservedObject var model: SkillCenterModel
  @Environment(\.dismiss) private var dismiss
  @State private var pendingPurge: TrashedSkill?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("回收站").font(.headline)
        Spacer()
        Button("清空回收站") { model.emptyTrash() }
          .disabled(model.trash.isEmpty)
      }
      Text("删除会把技能整体移到技能根下的 .trash 目录（harness 只扫描根目录一层，不会加载它），frontmatter 和资源文件都保持原样，可以随时恢复。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if model.trash.isEmpty {
        VStack {
          Spacer()
          Text("回收站是空的。").foregroundStyle(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(model.trash) { item in
              row(item)
            }
          }
        }
      }

      HStack {
        if let status = model.status {
          Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer()
        Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 640, height: 520)
    .onAppear { model.refreshTrash() }
    .confirmationDialog(
      pendingPurge.map { "彻底删除「\($0.name)」？" } ?? "",
      isPresented: Binding(
        get: { pendingPurge != nil },
        set: { if !$0 { pendingPurge = nil } }
      ),
      presenting: pendingPurge
    ) { item in
      Button("彻底删除", role: .destructive) { model.purge(item) }
      Button("取消", role: .cancel) {}
    } message: { _ in
      Text("这一步不可恢复。")
    }
  }

  private func row(_ item: TrashedSkill) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.name).font(.callout.weight(.semibold))
          Text(item.rootKind.title)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
          if item.isInferred {
            Text("由其它工具删除")
              .font(.caption2)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(Color.orange.opacity(0.16)))
              .foregroundStyle(.orange)
          }
        }
        Text("还原到 \(item.originalURL.path)")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Text(detail(item))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      Button("恢复") { model.restore(item) }
      Button("彻底删除", role: .destructive) { pendingPurge = item }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
  }

  private func detail(_ item: TrashedSkill) -> String {
    var parts: [String] = [item.form == .flat ? "单文件" : "目录包"]
    if let deletedAt = item.deletedAt {
      parts.append("删除于 \(SkillCenterWindow.timeFormatter.string(from: deletedAt))")
    }
    parts.append(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
    return parts.joined(separator: " · ")
  }
}
