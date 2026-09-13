import Foundation
import HarnessIM
import HarnessKit

/// A live `session/follow` stream.
///
/// A seam rather than a socket, for the same reason `RemoteEventStreaming` is one: the watcher's
/// decisions — which endings deserve a notification, when to re-subscribe, how to react to an
/// unavailable stream — are worth testing without a harness on the other end.
public protocol SessionFollowing: Sendable {
  /// Open the stream for one session and deliver frames until it ends or the task is cancelled.
  func openStream(sessionID: String) async throws -> AsyncThrowingStream<SessionFollowFrame, Error>
  /// Close the carrier. One carrier carries only one stream, so this ends that stream too.
  func close() async
}

/// `session/follow` over the harness's WebSocket multiplexer.
///
/// The mux wire protocol is the same one the approval relay uses: the client sends
/// `{type:"open", streamId, endpoint, payload}` and receives `{type:"item", streamId, value}`,
/// `{type:"end", streamId}` or `{type:"error", streamId, error}`.
///
/// One socket per session, deliberately. The mux would carry several logical streams over one
/// socket, but a per-session socket means a stream that ends cannot disturb another session's
/// subscription, and the watcher's reconnect then has exactly one thing to re-establish.
public final class HarnessSessionFollower: SessionFollowing, @unchecked Sendable {
  private let webSocketURL: URL
  private let cookie: String?
  private let session: URLSession
  private let stateLock = NSLock()
  private var socket: URLSessionWebSocketTask?

  public init(webSocketURL: URL, cookie: String?) {
    self.webSocketURL = webSocketURL
    self.cookie = cookie
    let configuration = URLSessionConfiguration.ephemeral
    // The stream is long-lived by design: a session may sit idle for hours and must not be cut by
    // a request timeout.
    configuration.timeoutIntervalForRequest = 24 * 60 * 60
    session = URLSession(configuration: configuration)
  }

  public func openStream(sessionID: String) async throws -> AsyncThrowingStream<SessionFollowFrame, Error> {
    let streamID = UUID().uuidString
    var request = URLRequest(url: webSocketURL)
    if let cookie, !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    let task = session.webSocketTask(with: request)
    stateLock.lock(); socket = task; stateLock.unlock()
    task.resume()

    // The address shape is the controller's own: a session is named by kind and id, which is the
    // same object `session/page` takes, and the stream frame's payload wrapper matches the unary
    // call's (`args`, then the method's `request`).
    let open: JSONValue = .object([
      "type": .string("open"),
      "streamId": .string(streamID),
      "endpoint": .string("session/follow"),
      "payload": .object([
        "args": .object([
          "request": .object([
            "address": .object([
              "kind": .string("session"),
              "sessionId": .string(sessionID),
            ]),
          ]),
        ]),
      ]),
    ])
    try await Self.send(task, open)

    return AsyncThrowingStream { continuation in
      let pump = Task {
        do {
          while !Task.isCancelled {
            let message = try await task.receive()
            guard let text = Self.text(of: message),
                  let envelope = try? JSONValue.parse(text, context: "harness.mux") else { continue }
            guard envelope["streamId"]?.stringValue == streamID else { continue }
            switch envelope["type"]?.stringValue {
            case "item":
              guard let value = envelope["value"], let frame = SessionFollowFrame.parse(value) else {
                // A frame we cannot read is not the stream's fault; keep following.
                continue
              }
              continuation.yield(frame)
            case "error":
              continuation.finish(throwing: HarnessAPIError(
                code: .rejected,
                message: envelope.path("error.message")?.stringValue ?? "会话流被 harness 拒绝",
                providerCode: envelope.path("error.code")?.stringValue
              ))
              return
            default:
              // `end` and anything unknown both finish this logical stream. The watcher treats a
              // finish as "re-subscribe", which is the same recovery either way.
              continuation.finish()
              return
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in pump.cancel() }
    }
  }

  public func close() async {
    stateLock.lock()
    let task = socket
    socket = nil
    stateLock.unlock()
    task?.cancel(with: .goingAway, reason: nil)
  }

  private static func send(_ task: URLSessionWebSocketTask, _ value: JSONValue) async throws {
    guard let text = try? value.serialized() else {
      throw HarnessAPIError(code: .malformedEnvelope, message: "无法编码会话流请求")
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      task.send(.string(text)) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private static func text(of message: URLSessionWebSocketTask.Message) -> String? {
    switch message {
    case .string(let text): return text
    case .data(let data): return String(data: data, encoding: .utf8)
    @unknown default: return nil
    }
  }
}
