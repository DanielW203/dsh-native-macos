import Foundation

/// One line of the boot log as the startup panel shows it.
struct StartupLogRow: Equatable, Identifiable, Codable {
  enum State: String, Equatable, Codable {
    case neutral
    case done
    case active
    case failed
  }

  /// The line's index in the window's log. Stable while the log only grows, which is what
  /// lets the panel update rows in place instead of re-rendering the list on every tick.
  let id: Int
  let text: String
  let title: String
  let state: State
  let badge: String?
}

/// An action the panel can offer. The native side decides which actions exist; the panel
/// only renders them and posts the id back, so no boot-state logic lives in JavaScript.
struct StartupAction: Equatable, Identifiable, Codable {
  enum Kind: String, Equatable, Codable {
    case primary
    case secondary
    case danger
  }

  enum ID: String, Equatable, Codable {
    case retryBoot
    case openRecovery
    case disablePlugins
    case installNode
    case reloadPage
    case openInBrowser
    case continueAnyway
  }

  let id: ID
  let label: String
  let kind: Kind
}

/// The panel's phase. "preparing" is the moment before the launcher has started; "starting"
/// covers toolchain + server boot; "waitingPage" is "server up, page loading"; the two
/// failures are separate because the actions are different.
enum StartupStatus: String, Equatable, Codable {
  case preparing
  case starting
  case waitingPage
  case ready
  case failedBoot
  case failedPage
}

/// Everything the HTML panel needs for one frame. Sent as a JSON object.
struct StartupSnapshot: Equatable, Encodable {
  var status: StartupStatus
  var statusLabel: String
  var logs: [StartupLogRow]
  var detail: String?
  var elapsed: Double
  var hint: String
  var actions: [StartupAction]
  var pageReady: Bool
  var safeMode: Bool
  var preview: Bool
  var reduceMotion: Bool
  var isBusy: Bool

  /// The JSON object callAsyncJavaScript takes as an argument.
  var jsonObject: [String: Any] {
    guard let data = try? JSONEncoder().encode(self),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
      return [:]
    }
    return dictionary
  }
}

/// Plain inputs, so the builder can be tested without a window, a launcher, or a web view.
struct StartupSnapshotInput {
  var phase: HarnessWindowModel.Phase
  var logs: [String]
  var detail: String?
  var pageReady: Bool
  var pageFailure: String?
  var elapsed: TimeInterval
  var needsNode: Bool
  var nodeStage: String?
  var safeMode: Bool
  var isBusy: Bool
  var reduceMotion: Bool
  var preview: Bool = false
}

enum StartupSnapshotBuilder {
  static let maxLogRows = 9

  static func make(_ input: StartupSnapshotInput) -> StartupSnapshot {
    let status = status(for: input)
    let rows = StartupLogClassifier.rows(
      from: input.logs,
      phase: input.phase,
      pageReady: input.pageReady,
      pageFailure: input.pageFailure
    )
    let detail = sanitizedDetail(input.detail ?? input.pageFailure)
    return StartupSnapshot(
      status: status,
      statusLabel: statusLabel(for: status),
      logs: rows,
      detail: detail,
      elapsed: max(0, input.elapsed),
      hint: hint(for: status, elapsed: input.elapsed),
      actions: actions(for: status, input: input),
      pageReady: input.pageReady,
      safeMode: input.safeMode,
      preview: input.preview,
      reduceMotion: input.reduceMotion,
      isBusy: input.isBusy
    )
  }

  static func status(for input: StartupSnapshotInput) -> StartupStatus {
    if let pageFailure = input.pageFailure, !pageFailure.isEmpty {
      return .failedPage
    }
    if input.phase == .failed { return .failedBoot }
    if input.pageReady { return .ready }
    if input.phase == .running { return .waitingPage }
    if input.phase == .starting || input.isBusy { return .starting }
    return .preparing
  }

  static func statusLabel(for status: StartupStatus) -> String {
    switch status {
    case .preparing, .starting: return "INITIALIZING"
    case .waitingPage: return "LOADING UI"
    case .ready: return "READY"
    case .failedBoot, .failedPage: return "FAILED"
    }
  }

  static func hint(for status: StartupStatus, elapsed: TimeInterval) -> String {
    switch status {
    case .preparing:
      return "正在准备启动…"
    case .starting:
      return elapsed >= 20
        ? "首次启动会创建 profile，可能需要一会儿"
        : "正在启动 Harness…"
    case .waitingPage:
      return "服务已就绪，正在加载页面…"
    case .ready:
      return "页面已就绪，正在交接…"
    case .failedBoot:
      return "启动没有完成"
    case .failedPage:
      return "页面没有加载成功"
    }
  }

  static func actions(for status: StartupStatus, input: StartupSnapshotInput) -> [StartupAction] {
    switch status {
    case .failedBoot:
      var result: [StartupAction] = [
        StartupAction(id: .retryBoot, label: "重试", kind: .primary),
      ]
      if input.needsNode {
        result.append(StartupAction(id: .installNode, label: "安装 Node…", kind: .primary))
      }
      result.append(StartupAction(id: .disablePlugins, label: "禁用可疑插件并重试", kind: .danger))
      result.append(StartupAction(id: .openRecovery, label: "打开恢复模式…", kind: .secondary))
      result.append(StartupAction(id: .continueAnyway, label: "仍然进入", kind: .secondary))
      return result
    case .failedPage:
      return [
        StartupAction(id: .reloadPage, label: "重新加载页面", kind: .primary),
        StartupAction(id: .openInBrowser, label: "在浏览器打开", kind: .secondary),
        StartupAction(id: .continueAnyway, label: "仍然进入", kind: .secondary),
      ]
    default:
      return []
    }
  }

  /// The error text is shown to the user and written into a web view; redact it again even
  /// though the window's log is already redacted on the way in.
  static func sanitizedDetail(_ detail: String?) -> String? {
    guard let detail, !detail.isEmpty else { return nil }
    let safe = HarnessWindowModel.redacting(detail)
    return safe.isEmpty ? nil : safe
  }
}

enum StartupHandoffPolicy {
  /// The brand moment is allowed to finish before the page takes over, but never delays the
  /// boot itself: once the page is ready this is the only remaining wait.
  static let minimumOnScreen: TimeInterval = 1.4

  static func shouldHandoff(_ snapshot: StartupSnapshot) -> Bool {
    guard snapshot.pageReady else { return false }
    guard snapshot.status != .failedBoot, snapshot.status != .failedPage else { return false }
    return snapshot.elapsed >= minimumOnScreen
  }
}

/// Turns the raw boot log into panel rows. The only intelligence here is stage recognition:
/// the panel shows the real text, and only adds a badge when a line is a known launch stage.
enum StartupLogClassifier {
  private enum Stage: Int {
    case profile
    case toolchain
    case runtime
    case server
    case waiting
    case listening
    case page
  }

  private struct Candidate {
    let index: Int
    let text: String
    let stage: Stage?
  }

  static func rows(
    from lines: [String],
    phase: HarnessWindowModel.Phase,
    pageReady: Bool,
    pageFailure: String?
  ) -> [StartupLogRow] {
    let candidates: [Candidate] = lines.enumerated().compactMap { index, line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      guard !isNoise(trimmed) else { return nil }
      return Candidate(index: index, text: trimmed, stage: stage(for: trimmed))
    }
    let tail = candidates.suffix(StartupSnapshotBuilder.maxLogRows)
    let lastStageIndex = tail.lastIndex { $0.stage != nil }.map { $0 - tail.startIndex }
    let failed = phase == .failed || (pageFailure?.isEmpty == false)
    let activeIndex: Int? = {
      guard !failed, !pageReady else { return nil }
      guard phase == .starting || phase == .running || phase == .stopped else { return nil }
      return lastStageIndex
    }()

    return tail.enumerated().map { offset, candidate in
      var state: StartupLogRow.State = .neutral
      if let stage = candidate.stage {
        _ = stage
        if failed, offset == (lastStageIndex ?? offset) {
          state = .failed
        } else if failed {
          state = .done
        } else if pageReady || (lastStageIndex != nil && offset < lastStageIndex!) {
          state = .done
        } else if activeIndex == offset {
          state = .active
        } else if candidate.stage == .page, phase == .running, !pageReady {
          state = .active
        } else {
          state = .neutral
        }
      } else if failed, offset == (lastStageIndex ?? -1) {
        state = .failed
      }

      let badge: String? = {
        switch state {
        case .done: return "完成"
        case .active: return "运行中"
        case .failed: return "失败"
        case .neutral: return candidate.stage == nil ? nil : "等待"
        }
      }()

      return StartupLogRow(
        id: candidate.index,
        text: candidate.text,
        title: candidate.text,
        state: state,
        badge: badge
      )
    }
  }

  private static func isNoise(_ line: String) -> Bool {
    line.hasPrefix("window opened; workspace ")
      || line.hasPrefix("window opened;")
  }

  private static func stage(for line: String) -> Stage? {
    if line.hasPrefix("Booting the ") && line.contains(" profile") { return .profile }
    if line.hasPrefix("Resolving the Node toolchain") { return .toolchain }
    if line.hasPrefix("Node ") && line.contains(" at ") { return .toolchain }
    if line.hasPrefix("Locating the installed harness") { return .runtime }
    if line.hasPrefix("Harness entry:") { return .runtime }
    if line.hasPrefix("Starting:") { return .server }
    if line.hasPrefix("Waiting for the harness to announce") { return .waiting }
    if line.hasPrefix("harness is listening on port") { return .listening }
    if line.hasPrefix("Loading the harness page") { return .page }
    if line.hasPrefix("page loaded:") { return .page }
    if line.hasPrefix("page ready") { return .page }
    return nil
  }
}
