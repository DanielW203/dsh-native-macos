import Foundation
import HarnessKit

/// What the running harness actually supports.
///
/// The harness's `/api` is not a published contract, so the channel negotiates instead of
/// assuming. Probing costs one cheap call per endpoint and turns a future rename into a
/// named degradation ("本轮降级为文件路径清单") instead of a mysterious failure.
public struct HarnessCapabilities: Sendable, Equatable {
  public var canCreateSession: Bool
  /// Whether the host can register a working directory as a workspace. Without it a
  /// channel-created session exists on disk but never appears in the harness sidebar.
  public var canCreateWorkspace: Bool
  public var canUploadFiles: Bool
  public var canCancelSession: Bool
  public var canPageSession: Bool
  /// Human-readable degradations to surface in the channel window.
  public var notes: [String]

  public init(
    canCreateSession: Bool = true,
    canCreateWorkspace: Bool = true,
    canUploadFiles: Bool = true,
    canCancelSession: Bool = true,
    canPageSession: Bool = true,
    notes: [String] = []
  ) {
    self.canCreateSession = canCreateSession
    self.canCreateWorkspace = canCreateWorkspace
    self.canUploadFiles = canUploadFiles
    self.canCancelSession = canCancelSession
    self.canPageSession = canPageSession
    self.notes = notes
  }

  /// Everything available — used before a probe has run.
  public static let assumed = HarnessCapabilities()
}

/// Endpoint existence probing.
public enum HarnessAPICompatibility {
  /// Endpoints the channel depends on, with the phrase the UI shows when one is gone.
  static let required: [(endpoint: String, note: String)] = [
    ("session/create", "这台 harness 没有 session/create，渠道无法新建会话"),
    ("workspace/create", "这台 harness 没有 workspace/create，微信会话不会被登记进任何工作区，侧栏里看不到"),
    ("fileUploads/upload", "这台 harness 没有 fileUploads/upload，附件将退化为工作区文件路径"),
    ("session/cancel", "这台 harness 没有 session/cancel，渠道无法停止正在跑的任务"),
    ("session/page", "这台 harness 没有 session/page，回复只能通过会话日志读取"),
  ]

  /// Classify one probe result.
  ///
  /// An endpoint that exists rejects empty arguments with a *gateway* error (`gateway/arguments-invalid`);
  /// an endpoint that does not exist is answered with HTTP 404. Both were measured against
  /// a live harness, and the distinction is what makes probing side-effect free: no session
  /// is created and nothing is written just to ask "do you have this?".
  public enum Availability: Sendable, Equatable {
    case available
    case missing
    case unknown(String)
  }

  public static func classify(_ error: Error) -> Availability {
    if let apiError = error as? HarnessAPIError {
      switch apiError.code {
      case .rejected: return .available
      case .http:
        if apiError.status == 404 { return .missing }
        return .unknown(apiError.message)
      case .unauthorized: return .unknown(apiError.message)
      case .malformedEnvelope, .invalidURL, .transport:
        return .unknown(apiError.message)
      }
    }
    return .unknown(String(describing: error))
  }

  /// Probe every endpoint the channel uses. Never throws: an unreachable harness yields
  /// "unknown" capabilities and notes, which the UI renders as "harness 未运行".
  ///
  /// An endpoint counts as missing **only** on an explicit 404. Anything else (a timeout, a
  /// 401, a shape this build cannot parse) leaves the capability enabled and records a note:
  /// refusing to submit because a probe was inconclusive would turn a transient hiccup into
  /// "the channel does not work".
  public static func probe(client: HarnessAPIClient) async -> HarnessCapabilities {
    var results: [String: Availability] = [:]
    for entry in required {
      do {
        _ = try await client.call(endpoint: entry.endpoint, args: .object([:]))
        // Empty arguments were accepted, which no endpoint here does — treat it as available.
        results[entry.endpoint] = .available
      } catch {
        results[entry.endpoint] = classify(error)
      }
    }

    var notes: [String] = []
    func unavailable(_ endpoint: String) -> Bool {
      guard case .missing = results[endpoint] ?? .unknown("not probed") else {
        if case .unknown(let detail) = results[endpoint] ?? .unknown("not probed") {
          notes.append("无法确认 \(endpoint) 是否可用：\(detail)")
        }
        return false
      }
      notes.append(required.first { $0.endpoint == endpoint }?.note ?? "缺少 \(endpoint)")
      return true
    }

    let missingCreate = unavailable("session/create")
    let missingWorkspace = unavailable("workspace/create")
    let missingUpload = unavailable("fileUploads/upload")
    let missingCancel = unavailable("session/cancel")
    let missingPage = unavailable("session/page")

    return HarnessCapabilities(
      canCreateSession: !missingCreate,
      canCreateWorkspace: !missingWorkspace,
      canUploadFiles: !missingUpload,
      canCancelSession: !missingCancel,
      canPageSession: !missingPage,
      notes: notes
    )
  }
}
