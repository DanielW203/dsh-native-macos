import Foundation
import HarnessIM
import HarnessKit
import HarnessRuntime

/// The app's own answer to "does this harness release still work for us?".
///
/// Every check here is something the app already knows how to do for its own reasons — probe
/// the endpoints the channel needs, page a session, read a log off disk, audit a profile's
/// plugins. Nothing is added for the sake of the check, so a failure means a real feature is
/// broken rather than that a test harness disagrees with the app.
///
/// **The asymmetry rule.** A check reports `warn` whenever it cannot tell, and only `fail`
/// when it positively observed the breakage. The reason is the same one
/// `PluginCompatibilityAudit` spells out for its own verdicts: a wrong "incompatible" makes
/// the user destroy something that works. Here a wrong `fail` would roll back a release that
/// was fine, which is worse — the user loses an upgrade they already made.
public enum HarnessUpgradeChecks {
  /// How long a stream check waits for its first frame before calling it a warning.
  ///
  /// Generous, because the cost of being wrong is asymmetric in the other direction here: a
  /// harness that is merely slow must not be reported as a harness that cannot stream.
  public static let streamTimeout: TimeInterval = 10

  /// Build the checks for a runtime that just came up.
  ///
  /// Authentication happens once, here. The launch token is exchanged for a signed cookie by
  /// `authenticate`, and every check afterwards rides that one cookie — a per-check handshake
  /// would be both wasteful and, against a single-use token, wrong.
  public static func make(
    announcedURL: String,
    paths: RuntimePaths,
    profile: String,
    activeReleaseID: String?
  ) async -> [any HarnessCheck] {
    let context: CheckContext
    do {
      context = try await CheckContext(
        announcedURL: announcedURL,
        paths: paths,
        profile: profile,
        activeReleaseID: activeReleaseID
      )
    } catch {
      // A harness the app cannot even authenticate against is unusable, so this is the one
      // place a single failure stands in for the whole suite — every other check would only
      // repeat the same error under a different name.
      return [UnreachableCheck(detail: describe(error))]
    }

    return [
      EndpointsCheck(context: context),
      SessionListCheck(context: context),
      SessionLogCheck(context: context),
      EventsStreamCheck(context: context),
      TurnFollowCheck(context: context),
      ToolVocabularyCheck(context: context),
      PluginCompatibilityCheck(context: context),
    ]
  }

  /// The shared, already-authenticated state every check reads.
  struct CheckContext: Sendable {
    let client: HarnessAPIClient
    let paths: RuntimePaths
    let profile: String
    let activeReleaseID: String?

    init(
      announcedURL: String,
      paths: RuntimePaths,
      profile: String,
      activeReleaseID: String?
    ) async throws {
      guard let url = URL(string: announcedURL) else {
        throw HarnessAPIError(code: .invalidURL, message: "harness 播报的地址无法解析：\(announcedURL)")
      }
      let parsed = try HarnessAPIClient.parse(authenticatedURL: url)
      let client = HarnessAPIClient(baseURL: parsed.origin)
      try await client.authenticate(token: parsed.token)
      self.client = client
      self.paths = paths
      self.profile = profile
      self.activeReleaseID = activeReleaseID
    }

    /// Sessions, newest activity first, or the error that stopped us asking.
    func sessions() async -> Result<[SessionSummary], Error> {
      do { return .success(try await client.listSessions()) } catch { return .failure(error) }
    }

    /// The newest session that names a working directory, which is what the log path needs.
    func newestAddressedSession() async -> SessionSummary? {
      guard case .success(let list) = await sessions() else { return nil }
      return list.first { $0.cwd?.isEmpty == false }
    }
  }

  static func describe(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
      return description
    }
    return String(describing: error)
  }

  /// Tool names this build cannot classify.
  ///
  /// Pure and separate from the check that calls it because this *is* the judgement the
  /// feature exists to make — a renamed or newly added tool does not throw, it silently
  /// becomes "uncategorized" — and a judgement worth acting on is worth testing without a
  /// session on disk.
  public static func unrecognizedToolNames(_ names: some Sequence<String>) -> [String] {
    Set(names.filter { !$0.isEmpty && ToolCategory(name: $0) == .uncategorized }).sorted()
  }
}

// MARK: - Authentication

/// Stands in for the whole suite when the handshake failed.
private struct UnreachableCheck: HarnessCheck {
  let name = "http-auth"
  let isBlocking = true
  let detail: String

  func run() async -> HarnessCheckResult {
    HarnessCheckResult(name: name, verdict: .fail, detail: detail, isBlocking: isBlocking)
  }
}

// MARK: - Endpoints

/// The five endpoints the app's own features call.
///
/// Blocking, because this is the closest thing to "can this harness serve DSHNative at all".
private struct EndpointsCheck: HarnessCheck {
  let name = "rpc-endpoints"
  let isBlocking = true
  let context: HarnessUpgradeChecks.CheckContext

  func run() async -> HarnessCheckResult {
    let capabilities = await HarnessAPICompatibility.probe(client: context.client)
    var missing: [String] = []
    if !capabilities.canCreateSession { missing.append("session/create") }
    if !capabilities.canCreateWorkspace { missing.append("workspace/create") }
    if !capabilities.canUploadFiles { missing.append("fileUploads/upload") }
    if !capabilities.canCancelSession { missing.append("session/cancel") }
    if !capabilities.canPageSession { missing.append("session/page") }

    guard missing.isEmpty else {
      return HarnessCheckResult(
        name: name,
        verdict: .fail,
        detail: "缺少端点：\(missing.joined(separator: ", "))",
        isBlocking: isBlocking
      )
    }
    // A note is not a failure: an inconclusive probe deliberately keeps the capability
    // enabled, and reporting it as a pass with a caveat is exactly what that design asks for.
    let detail = capabilities.notes.isEmpty ? "5 个端点都在" : capabilities.notes.joined(separator: "；")
    return HarnessCheckResult(name: name, verdict: .pass, detail: detail, isBlocking: isBlocking)
  }
}

// MARK: - Sessions

/// `session/list` still answers a shape this build can read.
private struct SessionListCheck: HarnessCheck {
  let name = "session-list"
  let isBlocking = false
  let context: HarnessUpgradeChecks.CheckContext

  func run() async -> HarnessCheckResult {
    switch await context.sessions() {
    case .success(let list):
      return HarnessCheckResult(
        name: name,
        verdict: .pass,
        detail: "\(list.count) 个会话可读",
        isBlocking: isBlocking
      )
    case .failure(let error):
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "读取会话列表失败：\(HarnessUpgradeChecks.describe(error))",
        isBlocking: isBlocking
      )
    }
  }
}

// MARK: - Session log (route B)

/// The on-disk half of the integration: our path convention and the log format.
///
/// This is the check that catches a persistence backend change. The app only ever *reads*
/// these files, and it finds them by reproducing the harness's own escaping character for
/// character — so a divergence does not error, it silently returns nothing. That silence is
/// what makes the three failure modes worth naming separately here.
private struct SessionLogCheck: HarnessCheck {
  let name = "session-log"
  let isBlocking = false
  let context: HarnessUpgradeChecks.CheckContext

  func run() async -> HarnessCheckResult {
    guard let session = await context.newestAddressedSession(), let cwd = session.cwd else {
      return HarnessCheckResult(
        name: name,
        verdict: .skipped,
        detail: "还没有带工作目录的会话可供验证",
        isBlocking: isBlocking
      )
    }

    guard let directory = try? SessionPaths.sessionDirectory(
      dshHome: context.paths.dshHome,
      cwd: cwd,
      sessionID: session.id.rawValue
    ) else {
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "会话目录路径算不出来（cwd=\(cwd)）",
        isBlocking: isBlocking
      )
    }
    guard let log = SessionPaths.logFile(inSessionDirectory: directory) else {
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "按本机路径约定找不到会话日志：\(directory.path)",
        isBlocking: isBlocking
      )
    }
    do {
      let events = try SessionLogReader(url: log).readEvents(limit: 50)
      return HarnessCheckResult(
        name: name,
        verdict: .pass,
        detail: "\(log.lastPathComponent)，读到 \(events.count) 条事件",
        isBlocking: isBlocking
      )
    } catch {
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "日志解不开（\(log.lastPathComponent)）：\(HarnessUpgradeChecks.describe(error))",
        isBlocking: isBlocking
      )
    }
  }
}

// MARK: - Forwarded events

/// The `$events` mux still opens and sends its `ready` frame.
///
/// Approvals ride this stream. Without it the GUI keeps working and only the app's own
/// approval cards and notifications stop — the quietest breakage of the set.
private struct EventsStreamCheck: HarnessCheck {
  let name = "events-stream"
  let isBlocking = false
  let context: HarnessUpgradeChecks.CheckContext

  func run() async -> HarnessCheckResult {
    let stream: RemoteEventStream
    do {
      stream = try await context.client.makeRemoteEventStream()
    } catch {
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "建不出事件流：\(HarnessUpgradeChecks.describe(error))",
        isBlocking: isBlocking
      )
    }
    defer { Task { await stream.close() } }

    do {
      let frames = try await stream.open()
      let outcome = await FrameWaiter.waitForFrame(
        frames,
        seconds: HarnessUpgradeChecks.streamTimeout,
        matching: { if case .ready = $0 { return true } else { return false } }
      )
      switch outcome {
      case .success(let frame):
        guard case .ready(let clientID) = frame else { break }
        return HarnessCheckResult(
          name: name,
          verdict: .pass,
          detail: "收到 ready 帧（client \(clientID.prefix(8))）",
          isBlocking: isBlocking
        )
      case .failure(let failure):
        return HarnessCheckResult(
          name: name,
          verdict: .warn,
          detail: "没有拿到 ready 帧：\(failure.description)",
          isBlocking: isBlocking
        )
      }
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "收到的是意外帧",
        isBlocking: isBlocking
      )
    } catch {
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "打开事件流失败：\(HarnessUpgradeChecks.describe(error))",
        isBlocking: isBlocking
      )
    }
  }
}

// MARK: - Turn follow

/// One `session/follow` stream still opens with a `snapshot`.
///
/// The turn-completion notifier reads endings from this stream rather than from `$events`,
/// because the forwarded-event roster is declared host-side and no client can add `turn/end`
/// to it. If this breaks, notifications stop and nothing else does.
private struct TurnFollowCheck: HarnessCheck {
  let name = "turn-follow"
  let isBlocking = false
  let context: HarnessUpgradeChecks.CheckContext

  func run() async -> HarnessCheckResult {
    guard let session = await context.newestAddressedSession() else {
      return HarnessCheckResult(
        name: name,
        verdict: .skipped,
        detail: "还没有会话可供订阅",
        isBlocking: isBlocking
      )
    }
    guard let url = context.client.muxWebSocketURL else {
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "算不出 mux 地址",
        isBlocking: isBlocking
      )
    }

    let cookie = await context.client.sessionCookie
    let follower = HarnessSessionFollower(webSocketURL: url, cookie: cookie)
    defer { Task { await follower.close() } }

    do {
      let frames = try await follower.openStream(sessionID: session.id.rawValue)
      let outcome = await FrameWaiter.waitForFrame(
        frames,
        seconds: HarnessUpgradeChecks.streamTimeout,
        matching: { if case .snapshot = $0 { return true } else { return false } }
      )
      switch outcome {
      case .success(let frame):
        guard case .snapshot(let cursor, _) = frame else { break }
        return HarnessCheckResult(
          name: name,
          verdict: .pass,
          detail: "收到 snapshot 帧（cursor \(cursor)）",
          isBlocking: isBlocking
        )
      case .failure(let failure):
        return HarnessCheckResult(
          name: name,
          verdict: .warn,
          detail: "\(session.id) 没有拿到 snapshot：\(failure.description)",
          isBlocking: isBlocking
        )
      }
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "收到的是意外帧",
        isBlocking: isBlocking
      )
    } catch {
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "订阅失败：\(HarnessUpgradeChecks.describe(error))",
        isBlocking: isBlocking
      )
    }
  }
}

// MARK: - Tool vocabulary

/// Tool names the app does not recognise.
///
/// The app classifies tools by name to draw the right card and to decide what needs a
/// confirmation, so a renamed or newly added tool does not error — it quietly becomes
/// "uncategorized", and a mutating one may stop being treated as mutating. Reading the names
/// back out of a real session is the cheapest way to notice, and it needs no endpoint.
private struct ToolVocabularyCheck: HarnessCheck {
  let name = "tool-vocabulary"
  let isBlocking = false
  let context: HarnessUpgradeChecks.CheckContext

  func run() async -> HarnessCheckResult {
    guard let session = await context.newestAddressedSession(), let cwd = session.cwd else {
      return HarnessCheckResult(
        name: name,
        verdict: .skipped,
        detail: "还没有会话可供观察工具名",
        isBlocking: isBlocking
      )
    }
    guard let events = SessionLogLocator(dshHome: context.paths.dshHome)
      .events(cwd: cwd, sessionID: session.id.rawValue)
    else {
      // The log check reports this properly; repeating it here would double-count one fault.
      return HarnessCheckResult(
        name: name,
        verdict: .skipped,
        detail: "读不到会话事件（由 session-log 报告）",
        isBlocking: isBlocking
      )
    }

    var seen = Set<String>()
    for event in events {
      guard let call = event.toolCall, !call.name.isEmpty else { continue }
      seen.insert(call.name)
    }
    guard !seen.isEmpty else {
      return HarnessCheckResult(
        name: name,
        verdict: .skipped,
        detail: "这个会话里还没有工具调用",
        isBlocking: isBlocking
      )
    }

    let unknown = HarnessUpgradeChecks.unrecognizedToolNames(seen)
    guard unknown.isEmpty else {
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "\(unknown.count)/\(seen.count) 个工具名不认识：\(unknown.joined(separator: ", "))",
        isBlocking: isBlocking
      )
    }
    return HarnessCheckResult(
      name: name,
      verdict: .pass,
      detail: "\(seen.count) 个工具名都认识",
      isBlocking: isBlocking
    )
  }
}

// MARK: - Plugins

/// Whether the profile's plugins still agree with the release now installed.
///
/// Judged against the release that is active *now* — which, at this point in the upgrade, is
/// the new one. This is the same audit the Plugin Compatibility window shows, asked at the
/// only moment its answer can still change a decision.
private struct PluginCompatibilityCheck: HarnessCheck {
  let name = "plugins"
  let isBlocking = false
  let context: HarnessUpgradeChecks.CheckContext

  func run() async -> HarnessCheckResult {
    guard let releaseID = context.activeReleaseID else {
      return HarnessCheckResult(
        name: name,
        verdict: .skipped,
        detail: "不知道当前版本，无法判断插件声明",
        isBlocking: isBlocking
      )
    }
    let installer = HarnessInstaller(paths: context.paths)
    let store = PluginStore(
      paths: context.paths,
      entryProvider: { try await installer.activeEntryURL() }
    )
    do {
      let results = try store.compatibility(profile: context.profile, activeReleaseID: releaseID)
      let violations = results.filter {
        if case .incompatible = $0.verdict { return true }
        return false
      }
      guard violations.isEmpty else {
        let named = violations.prefix(5).map(\.record.name).joined(separator: ", ")
        return HarnessCheckResult(
          name: name,
          verdict: .warn,
          detail: "\(violations.count) 个插件声明与新版本不符：\(named)",
          isBlocking: isBlocking
        )
      }
      return HarnessCheckResult(
        name: name,
        verdict: .pass,
        detail: "\(results.count) 个插件没有声明冲突",
        isBlocking: isBlocking
      )
    } catch {
      return HarnessCheckResult(
        name: name,
        verdict: .warn,
        detail: "插件审计跑不起来：\(HarnessUpgradeChecks.describe(error))",
        isBlocking: isBlocking
      )
    }
  }
}

// MARK: - Waiting on a stream

/// Why waiting for a frame did not produce one.
enum FrameWaitFailure: Error, Equatable, Sendable {
  /// The stream closed before a matching frame arrived.
  case ended
  /// The deadline passed first. Distinguished from `ended` because a slow harness and a
  /// broken one are different findings.
  case timedOut
  case failed(String)

  var description: String {
    switch self {
    case .ended: return "流已关闭"
    case .timedOut: return "等待超时（\(Int(HarnessUpgradeChecks.streamTimeout))s）"
    case .failed(let detail): return detail
    }
  }
}

/// Race a stream against a deadline.
///
/// Exists because the alternative — iterating the stream — cannot honour a timeout at all: a
/// server that opens a socket and then says nothing leaves the `for await` suspended forever,
/// which is exactly the failure this check is supposed to notice.
enum FrameWaiter {
  enum Outcome<T: Sendable>: Sendable {
    case success(T)
    case failure(FrameWaitFailure)
  }

  static func waitForFrame<T: Sendable>(
    _ stream: AsyncThrowingStream<T, Error>,
    seconds: TimeInterval,
    matching: @escaping @Sendable (T) -> Bool
  ) async -> Outcome<T> {
    let box = StreamBox(stream)
    return await withTaskGroup(of: Outcome<T>?.self) { group in
      group.addTask {
        do {
          for try await frame in box.stream where matching(frame) {
            return .success(frame)
          }
          return .failure(.ended)
        } catch {
          return .failure(.failed(HarnessUpgradeChecks.describe(error)))
        }
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return .failure(.timedOut)
      }
      let first = await group.next() ?? .failure(.timedOut)
      group.cancelAll()
      return first ?? .failure(.timedOut)
    }
  }
}

/// Carries the stream into the racing task.
///
/// The stream is a value over shared storage and only ever consumed by one task, so the
/// compiler's caution about handing it across is not a real hazard here; the alternative was
/// giving up on the timeout entirely.
private final class StreamBox<T: Sendable>: @unchecked Sendable {
  let stream: AsyncThrowingStream<T, Error>
  init(_ stream: AsyncThrowingStream<T, Error>) { self.stream = stream }
}
