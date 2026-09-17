import Foundation
import HarnessKit

/// One frame of the harness's forwarded-event stream (`$events`).
///
/// The harness reaches browser clients over one WebSocket that multiplexes logical streams
/// (`/api/remote.mux`); this enum is the application-level vocabulary of the `$events`
/// stream carried inside it. Parsing is total and forward-compatible: an unknown frame is
/// ignored rather than failing the stream, because a harness that adds a frame type must not
/// break a channel that merely wants to answer approvals.
public enum RemoteEventFrame: Sendable, Equatable {
  /// First frame of a stream; carries the client identity every answer must quote.
  case ready(clientID: String)
  /// A waterfall request awaiting a decision. `agentID` identifies the session it belongs to.
  case waterfall(eventID: String, agentID: String, event: String, request: JSONValue)
  /// A broadcast event; the channel does not answer these.
  case emit(event: String, args: [JSONValue])
  /// The host withdrew a pending request.
  case cancel(eventID: String)

  public static func parse(_ value: JSONValue) -> RemoteEventFrame? {
    switch value["type"]?.stringValue {
    case "ready":
      guard let clientID = value["clientId"]?.stringValue, !clientID.isEmpty else { return nil }
      return .ready(clientID: clientID)
    case "cancel":
      guard let eventID = value["eventId"]?.stringValue, !eventID.isEmpty else { return nil }
      return .cancel(eventID: eventID)
    case "emit":
      guard let event = value["event"]?.stringValue, let args = value["args"]?.arrayValue else { return nil }
      return .emit(event: event, args: args)
    case "waterfall":
      guard let event = value["event"]?.stringValue,
            let eventID = value["eventId"]?.stringValue,
            let agentID = value["agentId"]?.stringValue,
            let request = value["request"], case .object = request else { return nil }
      return .waterfall(eventID: eventID, agentID: agentID, event: event, request: request)
    default:
      return nil
    }
  }
}

/// The protocol the approval relay needs from the host's event stream.
///
/// A seam rather than a concrete socket: the relay's decisions — whose request is this, what
/// the user is asked, and how a reply becomes an outcome — are worth testing without a
/// WebSocket or a harness.
public protocol RemoteEventStreaming: Sendable {
  /// Open the logical stream and deliver frames until it ends.
  func open() async throws -> AsyncThrowingStream<RemoteEventFrame, Error>
  /// Answer one waterfall request with a JSON value.
  ///
  /// The wire accepts any JSON here, which is what makes one carrier serve two waterfalls: a
  /// tool approval answers with its outcome string, a user question with
  /// `{"answers": [{"id":…, "selected":[…]}]}`.
  func answer(eventID: String, value: JSONValue) async throws
  /// Close the underlying carrier.
  func close() async
}

extension RemoteEventStreaming {
  /// Answer an approval with its outcome literal — the shape the GUI's two buttons send.
  public func answer(eventID: String, outcome: String) async throws {
    try await answer(eventID: eventID, value: .string(outcome))
  }
}

/// The `$events` stream over the harness's WebSocket multiplexer.
///
/// The mux wire protocol is small: the client sends `{type:"open", streamId, endpoint, payload}`
/// and receives `{type:"item", streamId, value}`, `{type:"end", streamId}` or
/// `{type:"error", streamId, error}`. Only one logical stream is opened per instance, which is
/// all an approval relay needs.
public final class RemoteEventStream: RemoteEventStreaming, @unchecked Sendable {
  private let client: HarnessAPIClient
  private let webSocketURL: URL
  private let cookie: String?
  private let session: URLSession
  /// Whether `close()` should take the session down with it.
  ///
  /// A borrowed session belongs to the transport that lent it — the channel's HTTP calls run on
  /// the same pool, so invalidating it here would break every later request.
  private let ownsSession: Bool
  private let stateLock = NSLock()
  private var socket: URLSessionWebSocketTask?
  private var clientID: String?

  public init(client: HarnessAPIClient, webSocketURL: URL, cookie: String?, session borrowed: URLSession? = nil) {
    self.client = client
    self.webSocketURL = webSocketURL
    self.cookie = cookie
    if let borrowed {
      session = borrowed
      ownsSession = false
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      // The stream is long-lived by design; no request timeout may cut it.
      configuration.timeoutIntervalForRequest = 24 * 60 * 60
      session = URLSession(configuration: configuration)
      ownsSession = true
    }
  }

  deinit {
    if ownsSession { session.invalidateAndCancel() }
  }

  public func open() async throws -> AsyncThrowingStream<RemoteEventFrame, Error> {
    let streamID = UUID().uuidString
    var request = URLRequest(url: webSocketURL)
    if let cookie, !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    // The previous socket is dead the moment a new attempt starts, and a socket nobody cancels
    // is a descriptor nobody releases: the reconnect loop is the one path that runs often enough
    // for that to exhaust the process.
    takeSocket()?.cancel(with: .goingAway, reason: nil)
    let task = session.webSocketTask(with: request)
    adopt(task)
    task.resume()

    let open: JSONValue = .object([
      "type": .string("open"),
      "streamId": .string(streamID),
      "endpoint": .string("$events"),
      "payload": .object(["args": .object([:])]),
    ])
    do {
      try await send(task, open)
    } catch {
      // The open frame never went out, so no pump will ever release this socket.
      release(task)
      throw error
    }

    return AsyncThrowingStream { continuation in
      let pump = Task { [weak self] in
        guard let self else { return }
        // Every way this stream can end — peer close, error, cancellation — releases the
        // socket, not just the explicit `close()`.
        defer { self.release(task) }
        do {
          while !Task.isCancelled {
            let message = try await task.receive()
            guard let text = Self.text(of: message),
                  let envelope = try? JSONValue.parse(text, context: "harness.mux") else { continue }
            guard envelope["streamId"]?.stringValue == streamID else { continue }
            switch envelope["type"]?.stringValue {
            case "item":
              guard let value = envelope["value"], let frame = RemoteEventFrame.parse(value) else { continue }
              if case .ready(let id) = frame {
                self.setClientID(id)
              }
              continuation.yield(frame)
            case "error":
              continuation.finish(throwing: HarnessAPIError(
                code: .rejected,
                message: envelope.path("error.message")?.stringValue ?? "事件流被 harness 拒绝",
                providerCode: envelope.path("error.code")?.stringValue
              ))
              return
            default:
              // `end` and anything unknown both terminate this logical stream.
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

  public func answer(eventID: String, value: JSONValue) async throws {
    guard let clientID = currentClientID() else {
      throw HarnessAPIError(code: .rejected, message: "事件流尚未就绪（缺少 clientId）")
    }
    let args: JSONValue = .object([
      "clientId": .string(clientID),
      "eventId": .string(eventID),
      "outcome": .object([
        "kind": .string("result"),
        "value": value,
      ]),
    ])
    _ = try await client.call(endpoint: "$events/result", args: args)
  }

  public func close() async {
    takeSocket()?.cancel(with: .goingAway, reason: nil)
    clearClientID()
    // Only a session this stream created is this stream's to take down.
    if ownsSession { session.invalidateAndCancel() }
  }

  /// Install a freshly opened socket as the current one.
  private func adopt(_ task: URLSessionWebSocketTask) {
    stateLock.lock(); socket = task; stateLock.unlock()
  }

  private func clearClientID() {
    stateLock.lock(); clientID = nil; stateLock.unlock()
  }

  private func setClientID(_ id: String) {
    stateLock.lock(); clientID = id; stateLock.unlock()
  }

  /// Remove and return the current socket, so two callers cannot both own it.
  private func takeSocket() -> URLSessionWebSocketTask? {
    stateLock.lock(); defer { stateLock.unlock() }
    let task = socket
    socket = nil
    return task
  }

  /// Cancel one socket, and forget it only while it is still the current one.
  ///
  /// The captured task is cancelled unconditionally — if a reconnect already replaced it, that
  /// replacement is the reason it is dead — but only the current socket may be cleared, or a
  /// late finish would erase its successor.
  private func release(_ task: URLSessionWebSocketTask) {
    task.cancel(with: .goingAway, reason: nil)
    stateLock.lock()
    if socket === task { socket = nil }
    stateLock.unlock()
  }

  func currentClientID() -> String? {
    stateLock.lock(); defer { stateLock.unlock() }
    return clientID
  }

  private func send(_ task: URLSessionWebSocketTask, _ value: JSONValue) async throws {
    guard let text = try? value.serialized() else {
      throw HarnessAPIError(code: .malformedEnvelope, message: "无法编码事件流请求")
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      task.send(.string(text)) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  static func text(of message: URLSessionWebSocketTask.Message) -> String? {
    switch message {
    case .string(let text): return text
    case .data(let data): return String(data: data, encoding: .utf8)
    @unknown default: return nil
    }
  }
}
