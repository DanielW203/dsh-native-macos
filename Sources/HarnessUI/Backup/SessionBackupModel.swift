import AppKit
import Foundation
import HarnessRuntime
import SwiftUI
import UniformTypeIdentifiers

/// One line of the backup window's log.
public struct BackupLogLine: Identifiable, Sendable, Equatable {
  public let id = UUID()
  public var text: String
  public var isError: Bool
  public var time: Date

  public init(text: String, isError: Bool = false, time: Date = Date()) {
    self.text = text
    self.isError = isError
    self.time = time
  }
}

/// The backup window's view model.
///
/// Export and import are the only two operations, and both are deliberately *manual*:
/// no timer, no launch agent, nothing that runs while the user is not looking. A backup
/// that appears on its own schedule in a directory the user did not choose is a file
/// nobody knows to check.
///
/// The model never touches the archive format itself — `SessionArchiveService` owns that —
/// and never asks the harness: it reads the session directories directly, so it works
/// with the harness stopped, which is exactly when a restore is most likely to be needed.
@MainActor
public final class SessionBackupModel: ObservableObject {
  @Published public private(set) var candidates: [SessionArchiveCandidate] = []
  /// Identifiers (`projectKey/sessionID`) of the sessions to export.
  @Published public var selected: Set<String> = []
  @Published public var includeAttachments: Bool
  @Published public private(set) var isBusy = false
  @Published public private(set) var progressText: String?
  @Published public private(set) var lines: [BackupLogLine] = []
  @Published public private(set) var lastExport: SessionArchiveOutcome?
  @Published public private(set) var lastReport: SessionImportReport?
  @Published public private(set) var errorMessage: String?

  /// Where the archive payload is assembled. Injected so a test can point it at a
  /// scratch tree instead of the real one.
  public let dshHome: URL
  public let stagingRoot: URL

  private let service: SessionArchiveService
  private let defaults: UserDefaults
  private let onImported: (() -> Void)?
  /// Whether the default selection has been seeded. Without it, "全不选" followed by a
  /// rescan would silently select everything again.
  private var didSeedSelection = false

  /// Whether the last export should be remembered for the next save panel.
  public static let includeAttachmentsDefaultsKey = "NativeHarness.backup.includeAttachments"

  public init(
    dshHome: URL,
    stagingRoot: URL,
    defaults: UserDefaults = .standard,
    runner: any ProcessRunning = ProcessRunner(),
    onImported: (() -> Void)? = nil
  ) {
    self.dshHome = dshHome
    self.stagingRoot = stagingRoot
    self.defaults = defaults
    self.service = SessionArchiveService(runner: runner)
    self.onImported = onImported
    self.includeAttachments = defaults.object(forKey: Self.includeAttachmentsDefaultsKey) as? Bool ?? true
    // No scan here: this model is built during app launch, and walking every session
    // directory on the main thread before the first window draws is I/O the user would
    // feel. The window refreshes on appear, and the menu entry refreshes before it needs
    // a selection.
  }

  // MARK: Derived state

  public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.logBytes } }

  public var selectedCandidates: [SessionArchiveCandidate] {
    candidates.filter { selected.contains($0.id) }
  }

  public var summary: String {
    let attachments = includeAttachments ? "，含附件" : ""
    return "\(candidates.count) 个会话 · \(Self.format(totalBytes))\(attachments)"
  }

  public static func format(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: bytes)
  }

  // MARK: Actions

  /// Re-read the session directories. Safe while the harness is running: read-only.
  public func refresh() {
    let scanned = SessionArchiveCatalog.scan(dshHome: dshHome)
    candidates = scanned
    let ids = Set(scanned.map(\.id))
    if didSeedSelection {
      // Sessions that disappeared drop out; a new one is not silently added to a
      // selection the user has already shaped.
      selected = selected.intersection(ids)
    } else {
      selected = ids
      didSeedSelection = true
    }
  }

  public func setIncludeAttachments(_ value: Bool) {
    includeAttachments = value
    defaults.set(value, forKey: Self.includeAttachmentsDefaultsKey)
  }

  /// The name the save panel should propose for a full export.
  public func suggestedFileName() -> String {
    "dshnative-sessions-\(Self.stamp()).zip"
  }

  public static func suggestedFileName() -> String {
    "dshnative-sessions-\(stamp()).zip"
  }

  private static func stamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmm"
    return formatter.string(from: Date())
  }

  /// Export every session the catalog found.
  public func exportAll(to destination: URL) async {
    await export(sessions: candidates, to: destination)
  }

  /// Export the current selection.
  public func exportSelected(to destination: URL) async {
    let chosen = selectedCandidates
    guard !chosen.isEmpty else {
      errorMessage = "没有勾选任何会话。"
      return
    }
    await export(sessions: chosen, to: destination)
  }

  private func export(sessions: [SessionArchiveCandidate], to destination: URL) async {
    guard !isBusy else { return }
    guard !sessions.isEmpty else {
      errorMessage = "没有可导出的会话日志。"
      return
    }
    isBusy = true
    errorMessage = nil
    progressText = "正在打包 \(sessions.count) 个会话…"
    let attachments = includeAttachments
    let service = self.service
    let dshHome = self.dshHome
    let stagingRoot = self.stagingRoot
    defer { isBusy = false; progressText = nil }

    do {
      let outcome = try await service.export(
        sessions: sessions,
        dshHome: dshHome,
        stagingRoot: stagingRoot,
        to: destination,
        includeAttachments: attachments
      )
      lastExport = outcome
      append("已导出 \(outcome.manifest.sessionCount) 个会话（\(Self.format(outcome.bytes))，"
             + String(format: "%.1fs", outcome.duration) + "）→ \(outcome.archiveURL.path)")
    } catch {
      fail(error)
    }
  }

  /// Restore an archive, then tell the host so it can refresh the Web UI.
  public func importArchive(_ archive: URL) async {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = nil
    progressText = "正在校验并导入…"
    let service = self.service
    let dshHome = self.dshHome
    let stagingRoot = self.stagingRoot
    defer { isBusy = false; progressText = nil }

    do {
      let report = try await service.importArchive(archive, dshHome: dshHome, stagingRoot: stagingRoot)
      lastReport = report
      append("已导入 \(report.imported.count) 个会话"
             + (report.skipped.isEmpty ? "" : "，跳过 \(report.skipped.count) 个")
             + (report.attachmentsImported > 0 ? "，附件 \(report.attachmentsImported) 个" : "")
             + "（\(archive.lastPathComponent)）")
      for skipped in report.skipped {
        append("跳过 \(skipped.sessionID)：\(skipped.reason)", isError: true)
      }
      refresh()
      // The harness lists sessions by scanning the directory it owns, so the restore is
      // already visible on the next list call; this only makes the open page re-read it.
      if !report.imported.isEmpty { onImported?() }
    } catch {
      fail(error)
    }
  }

  // MARK: File panels

  /// The three entry points the menu and the window share.
  ///
  /// The panels live here rather than in the view so that "导出全部对话日志…" in the Harness
  /// menu behaves identically to the button in the window — a second copy of the panel
  /// setup is how the two drift apart.

  public func exportAllWithPanel() {
    if candidates.isEmpty { refresh() }
    guard let url = Self.saveDestination(
      message: "导出全部对话日志（\(candidates.count) 个会话）",
      suggestedName: Self.suggestedFileName()
    ) else { return }
    Task { await exportAll(to: url) }
  }

  public func exportSelectedWithPanel() {
    if candidates.isEmpty { refresh() }
    guard let url = Self.saveDestination(
      message: "导出选中的 \(selected.count) 个会话",
      suggestedName: Self.suggestedFileName()
    ) else { return }
    Task { await exportSelected(to: url) }
  }

  public func importWithPanel() {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.zip, .gzip]
    panel.message = "选择 DSHNative 会话备份（.zip）"
    panel.prompt = "导入"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await importArchive(url) }
  }

  private static func saveDestination(message: String, suggestedName: String) -> URL? {
    // Without this the panel can open behind the active application, which looks exactly
    // like the button having done nothing at all.
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.zip]
    panel.nameFieldStringValue = suggestedName
    panel.message = message
    panel.prompt = "导出"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url
  }

  // MARK: Log

  public func append(_ text: String, isError: Bool = false) {
    lines.append(BackupLogLine(text: text, isError: isError))
    if lines.count > 500 { lines.removeFirst(lines.count - 500) }
  }

  private func fail(_ error: Error) {
    let message = describe(error)
    errorMessage = message
    append(message, isError: true)
  }

  private func describe(_ error: Error) -> String {
    if let archive = error as? SessionArchiveError { return archive.errorDescription ?? "\(archive)" }
    if let runtime = error as? RuntimeError { return runtime.errorDescription ?? "\(runtime)" }
    return error.localizedDescription
  }
}
