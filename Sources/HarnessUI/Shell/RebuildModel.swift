import AppKit
import Foundation
import HarnessRuntime
import SwiftUI

/// The Rebuild button's state: what the rebuild is doing, and what it wants to say about it.
///
/// The shape here is forced by what a self-rebuild *is*. The long step — `Tools/build.sh
/// release` — runs while the app is still alive, so the user can watch it. The last two
/// steps replace the bundle this process is executing from, so they cannot run here at all;
/// they are handed to a shell that waits for this process to exit. That split is why there
/// is a `handingOff` phase rather than a simple running/finished pair.
@MainActor
public final class RebuildModel: ObservableObject {
  public enum Phase: Equatable {
    case locating
    case running(RebuildStep)
    case handingOff
    case failed(String)
  }

  /// Whether the sheet is up. Settable so the window can drive it with a binding.
  @Published public var isPresented = false
  @Published public private(set) var phase: Phase = .locating
  @Published public private(set) var lines: [String] = []
  @Published public private(set) var checkoutPath: String?
  @Published public private(set) var logPath: String?

  /// The most output lines kept on screen. A Release build of this app prints thousands, and
  /// a view that re-lays out all of them is slower than the build it is reporting.
  public static let maxLines = 600

  private let locate: @Sendable () -> RebuildCheckout?
  private let makeService: @Sendable (RebuildCheckout) -> SelfRebuild
  private let handoff: @Sendable (SelfRebuild, Int32) throws -> Void
  private let terminate: @MainActor () -> Void
  private var runTask: Task<Void, Never>?

  /// - Parameters:
  ///   - locate: how to find the checkout. Injectable so the flow can be tested without a
  ///     real repository on disk.
  ///   - makeService: how to build the service from a checkout.
  ///   - handoff: what "let the shell finish after we are gone" means. Injectable because the
  ///     real one spawns an installer that runs `/bin/bash Tools/build.sh install`.
  ///   - terminate: what "quit and let the hand-off finish" means. Injectable so a test does
  ///     not actually quit the test host.
  ///
  /// `nonisolated` because the only thing a caller does first is *store* this object —
  /// `@StateObject private var rebuild = RebuildModel()` is evaluated as an escaping
  /// autoclosure, outside the main actor, and the type's isolation would otherwise make that
  /// a compile error rather than a lazily-created window model.
  nonisolated public init(
    locate: @escaping @Sendable () -> RebuildCheckout? = { RebuildCheckoutLocator.locate() },
    makeService: @escaping @Sendable (RebuildCheckout) -> SelfRebuild = { SelfRebuild(checkout: $0) },
    handoff: @escaping @Sendable (SelfRebuild, Int32) throws -> Void = { service, pid in
      try service.scheduleHandoff(waitingFor: pid)
    },
    terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
  ) {
    self.locate = locate
    self.makeService = makeService
    self.handoff = handoff
    self.terminate = terminate
  }

  public var isRunning: Bool {
    switch phase {
    case .locating, .running, .handingOff: return true
    case .failed: return false
    }
  }

  public var failure: String? {
    if case .failed(let message) = phase { return message }
    return nil
  }

  /// The one line under the title.
  public var stageText: String {
    switch phase {
    case .locating: return "正在定位 harness-native 源码目录…"
    case .running(let step): return step.title
    case .handingOff: return "编译完成，正在退出并交接：安装 → 校验 → 重新打开"
    case .failed(let message): return message
    }
  }

  // MARK: - Lifecycle

  /// Open the sheet. The work starts when the sheet appears, not here.
  public func present() {
    lines = []
    phase = .locating
    isPresented = true
  }

  /// Start a run, once.
  public func start() {
    guard runTask == nil else { return }
    runTask = Task { [weak self] in
      await self?.run()
      self?.runTask = nil
    }
  }

  public func retry() {
    guard runTask == nil else { return }
    start()
  }

  public func dismiss() {
    guard !isRunning else { return }
    isPresented = false
  }

  /// Pick the checkout by hand, for the machine where nothing else found it.
  public func chooseCheckout() {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "选择 harness-native 仓库根目录（含 Tools/build.sh 的那个目录）"
    panel.prompt = "选择"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    runTask = Task { [weak self] in
      await self?.useCheckout(url)
      self?.runTask = nil
    }
  }

  public func openLog() {
    guard let logPath else { return }
    let manager = FileManager.default
    if manager.fileExists(atPath: logPath) {
      NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: (logPath as NSString).deletingLastPathComponent)
    } else {
      NSWorkspace.shared.open(URL(fileURLWithPath: (logPath as NSString).deletingLastPathComponent, isDirectory: true))
    }
  }

  // MARK: - The work

  /// Run the whole rebuild in order.
  public func run() async {
    phase = .locating
    lines = []
    append("准备重新构建 DSHNative。")
    append("查找源码目录（依次尝试：手动指定 → 环境变量 → 安装时写入的标记 → 常见位置 → Spotlight）…")

    // Off the main actor: the search touches the filesystem, and its last resort shells out
    // to `mdfind`, which must never be able to freeze the window that started it.
    let locator = locate
    let found = await Task.detached(priority: .userInitiated) { locator() }.value
    guard let checkout = found else {
      checkoutPath = nil
      phase = .failed("没有找到 harness-native 源码目录。请点「选择源码目录…」手动指定包含 Tools/build.sh 的仓库根目录。")
      return
    }
    await build(checkout)
  }

  /// Use a checkout the user picked in the open panel, remembering it for next time.
  public func useCheckout(_ url: URL) async {
    guard RebuildCheckout.looksLikeCheckout(url) else {
      phase = .failed("\(url.path) 不是 harness-native 仓库：找不到 Tools/build.sh，或找不到 Package.swift / NativeHarness.xcodeproj。")
      return
    }
    RebuildCheckoutLocator.remember(url)
    await build(RebuildCheckout(root: url))
  }

  private func build(_ checkout: RebuildCheckout) async {
    let service = makeService(checkout)
    checkoutPath = checkout.root.path
    logPath = service.logURL.path
    append("源码目录：\(checkout.root.path)")
    append("安装位置：\(service.appURL.path)")
    append("构建日志：\(service.logURL.path)")
    append("")

    phase = .running(.release)
    append("$ cd \(checkout.root.path) && Tools/build.sh release")
    let result: ProcessResult
    do {
      result = try await service.runRelease { _, line in
        Task { @MainActor [weak self] in self?.append(line) }
      }
    } catch {
      service.appendToLog(lines.joined(separator: "\n") + "\n")
      phase = .failed("无法运行 Tools/build.sh：\(error)")
      return
    }
    append("")
    append("release 结束：退出码 \(result.exitCode)，用时 \(Int(result.duration.rounded()))s")
    // The log gets the full capture, not the window's capped tail: the window is allowed to
    // forget the first 500 lines of a build, the file that explains a failure is not.
    service.appendToLog(Self.logEntry(for: result, checkout: checkout))

    guard result.succeeded else {
      phase = .failed("Tools/build.sh release 失败（退出码 \(result.exitCode)）。完整输出见日志：\(service.logURL.path)")
      return
    }

    // The rest cannot run here: `install` moves and replaces this very bundle. Hand it to a
    // shell that waits for this pid to disappear, then quits so the shell can proceed.
    phase = .handingOff
    append("")
    append("安装与校验交给后台脚本执行（它会等待本进程退出，再 install --no-build → verify → 重新打开 app）。")
    do {
      try handoff(service, ProcessInfo.processInfo.processIdentifier)
    } catch {
      phase = .failed("无法启动后台安装脚本：\(error)")
      return
    }
    append("正在退出 DSHNative…")
    terminate()
  }

  /// The full capture of one step, as it goes into the log file.
  static func logEntry(for result: ProcessResult, checkout: RebuildCheckout) -> String {
    var text = "\n=== Tools/build.sh release in \(checkout.root.path) ===\n"
    text += result.stdout
    if !result.stderr.isEmpty {
      text += "\n--- stderr ---\n" + result.stderr
    }
    text += "\n=== release exit=\(result.exitCode) duration=\(Int(result.duration.rounded()))s ===\n"
    return text
  }

  /// Append one line of build output, newest last, capped.
  private func append(_ raw: String) {
    var line = raw
    while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
    lines.append(line)
    if lines.count > Self.maxLines {
      lines.removeFirst(lines.count - Self.maxLines)
    }
  }
}
