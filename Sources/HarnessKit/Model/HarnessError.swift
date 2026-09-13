import Foundation

/// Every failure that can cross a module boundary in NativeHarness.
///
/// The engines have very different failure surfaces — route A spawns Node and talks
/// HTTP, route B owns sockets and file handles directly — so the error type is
/// deliberately rich enough that the UI can render a diagnostic without knowing
/// which engine produced it.
public enum HarnessError: Error, LocalizedError, Sendable, Equatable {
  /// A payload could not be parsed. `context` names the event or endpoint.
  case malformedPayload(context: String, detail: String)
  /// The requested capability exists in the harness but not in this build.
  case unsupported(String)
  /// The engine process/library is not reachable.
  case engineUnavailable(String)
  /// The engine returned a structured failure.
  case engineFailed(code: String, message: String)
  case sessionNotFound(String)
  case toolNotFound(String)
  /// A tool ran and failed. Mirrors the official `ToolCallError` shape.
  case toolFailed(name: String, code: String, message: String)
  /// The engine asked for approval and none is pending under this id.
  case approvalNotFound(String)
  case cancelled
  case io(path: String, detail: String)
  case zstd(code: Int32, message: String)
  case notImplemented(String)

  public var errorDescription: String? {
    switch self {
    case .malformedPayload(let context, let detail):
      return "Malformed payload in \(context): \(detail)"
    case .unsupported(let what):
      return "Unsupported: \(what)"
    case .engineUnavailable(let detail):
      return "Engine unavailable: \(detail)"
    case .engineFailed(let code, let message):
      return "Engine failed [\(code)]: \(message)"
    case .sessionNotFound(let id):
      return "Session not found: \(id)"
    case .toolNotFound(let name):
      return "Tool not found: \(name)"
    case .toolFailed(let name, let code, let message):
      return "Tool \(name) failed [\(code)]: \(message)"
    case .approvalNotFound(let id):
      return "No pending approval with id \(id)"
    case .cancelled:
      return "Cancelled"
    case .io(let path, let detail):
      return "I/O error at \(path): \(detail)"
    case .zstd(let code, let message):
      return "zstd error \(code): \(message)"
    case .notImplemented(let what):
      return "Not implemented: \(what)"
    }
  }

  /// Stable machine-readable code, used in conformance reports.
  public var code: String {
    switch self {
    case .malformedPayload: return "MALFORMED_PAYLOAD"
    case .unsupported: return "UNSUPPORTED"
    case .engineUnavailable: return "ENGINE_UNAVAILABLE"
    case .engineFailed(let code, _): return code
    case .sessionNotFound: return "SESSION_NOT_FOUND"
    case .toolNotFound: return "TOOL_NOT_FOUND"
    case .toolFailed(_, let code, _): return code
    case .approvalNotFound: return "APPROVAL_NOT_FOUND"
    case .cancelled: return "CANCELLED"
    case .io: return "IO_ERROR"
    case .zstd: return "ZSTD_ERROR"
    case .notImplemented: return "NOT_IMPLEMENTED"
    }
  }
}

/// A stable, comparable identifier for a session.
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
  public var rawValue: String

  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }
  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.rawValue = try container.decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
