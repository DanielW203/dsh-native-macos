import AppKit
import Foundation
import HarnessRuntime
import SwiftUI

/// The backup window: export every conversation log as one zip, and restore one.
///
/// Deliberately manual. There is no schedule, no clock, and nothing runs while this
/// window is closed — an archive that materialises on its own in a directory the user
/// never chose is a file nobody knows to look for, and a restore is the only moment it
/// would have mattered.
public struct SessionBackupWindow: View {
  @ObservedObject private var model: SessionBackupModel

  public init(model: SessionBackupModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      sessionList
      Divider()
      actions
      Divider()
      status
    }
    .frame(minWidth: 720, minHeight: 560)
    .onAppear { model.refresh() }
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("会话备份").font(.headline)
        Spacer()
        Button {
          model.refresh()
        } label: {
          Label("重新扫描", systemImage: "arrow.clockwise")
        }
        .disabled(model.isBusy)
      }
      Text(model.dshHome.path)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
      Text("导出只读会话日志与附件；导入只写入 sessions/ 与 attachments/，已存在的会话绝不覆盖。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(14)
  }

  // MARK: List

  private var sessionList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Text(model.summary).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("全选") { model.selected = Set(model.candidates.map(\.id)) }
          .buttonStyle(.link)
        Button("全不选") { model.selected = [] }
          .buttonStyle(.link)
        Toggle("包含附件", isOn: Binding(
          get: { model.includeAttachments },
          set: { model.setIncludeAttachments($0) }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)

      if model.candidates.isEmpty {
        VStack(spacing: 6) {
          Text("没有找到会话日志").font(.callout)
          Text("这个 harness home 下还没有 sessions/ 目录，或目录里还没有会话。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $model.selected) {
          ForEach(model.candidates) { candidate in
            row(candidate).tag(candidate.id)
          }
        }
        .listStyle(.inset)
      }
    }
  }

  private func row(_ candidate: SessionArchiveCandidate) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(candidate.sessionID).font(.callout).monospaced()
        Text(candidate.projectKey).font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
      Text(SessionBackupModel.format(candidate.logBytes))
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
      Text(Self.dateText(candidate.modifiedAt))
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }
    .padding(.vertical, 2)
  }

  private static func dateText(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: date)
  }

  // MARK: Actions

  private var actions: some View {
    HStack(spacing: 10) {
      Button("导出全部对话日志…") { model.exportAllWithPanel() }
        .keyboardShortcut("e", modifiers: [.command, .shift])
      Button("导出选中…") { model.exportSelectedWithPanel() }
        .disabled(model.selected.isEmpty)
      Button("从备份导入…") { model.importWithPanel() }
      Spacer()
      if let last = model.lastExport {
        Button("打开所在文件夹") {
          NSWorkspace.shared.activateFileViewerSelecting([last.archiveURL])
        }
        .buttonStyle(.link)
      }
    }
    .disabled(model.isBusy)
    .padding(14)
  }

  // MARK: Status

  private var status: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let progress = model.progressText {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(progress).font(.caption)
        }
      }
      if let error = model.errorMessage {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      if let report = model.lastReport {
        Text(importSummary(report))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(model.lines.suffix(200)) { line in
            Text(line.text)
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(line.isError ? Color.red : Color.secondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.horizontal, 14)
      }
      .frame(height: 110)
    }
    .padding(.vertical, 10)
  }

  private func importSummary(_ report: SessionImportReport) -> String {
    var parts = ["导入结果：新增 \(report.imported.count) 个会话"]
    if !report.skipped.isEmpty { parts.append("跳过 \(report.skipped.count) 个") }
    if report.attachmentsImported > 0 || report.attachmentsSkipped > 0 {
      parts.append("附件 \(report.attachmentsImported) 新增 / \(report.attachmentsSkipped) 已存在")
    }
    if !report.imported.isEmpty {
      // The harness enumerates its sessions directory on every list call, so the restored
      // conversation is already on disk; a page reload is enough to see it.
      parts.append("若侧栏没出现，按 ⌘R 刷新 Web UI")
    }
    return parts.joined(separator: "，")
  }
}
