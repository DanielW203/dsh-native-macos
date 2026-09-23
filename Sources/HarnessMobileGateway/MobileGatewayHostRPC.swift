import Foundation
import HarnessIM
import HarnessKit

/// The gateway's view of a **running** harness.
///
/// This is the port of the plugin's `typertGateway`: a unary `invoke(namespace, method, args)`
/// plus a streaming `stream(namespace, method, args)`. Keeping the seam this narrow is what lets
/// the whole gateway be driven in tests by a scripted host, with no harness, no socket and no
/// home directory involved.
public protocol MobileGatewayRPC: Sendable {
  /// One request/response call. `endpoint` is the host's own `<namespace>/<method>` form.
  func invoke(endpoint: String, args: JSONValue) async throws -> JSONValue
  /// Open a host stream. The stream yields the host's frames and finishes when the host ends it.
  func stream(endpoint: String, args: JSONValue) async throws -> AsyncThrowingStream<JSONValue, Error>
  /// The host's forwarded-event feed, which carries the human-in-the-loop waterfalls.
  func events() async throws -> AsyncThrowingStream<MobileGatewayHostEvent, Error>
  /// Answer one waterfall request. The value's shape depends on the waterfall: a tool approval
  /// takes an outcome string, a user question takes `{answers: […]}`.
  func answer(eventID: String, value: JSONValue) async throws
  /// The real DSH version of the host behind this RPC, when it is knowable.
  var hostVersion: String? { get }
}

/// One frame of the host's forwarded-event feed.
///
/// Only the two waterfalls are modelled as first-class cases: the gateway's job is to relay the
/// approval and question requests to a phone and carry the answer back, and an `emit` frame the
/// gateway does not act on is deliberately still visible so a future feature can use it without
/// changing this seam.
public enum MobileGatewayHostEvent: Sendable, Equatable {
  case ready(clientID: String)
  case emit(event: String, args: [JSONValue])
  case waterfall(eventID: String, agentID: String, event: String, request: JSONValue)
  case cancel(eventID: String)

  /// Decode the host's raw envelope. Unknown shapes are ignored rather than guessed at.
  public static func parse(_ value: JSONValue) -> MobileGatewayHostEvent? {
    switch value["type"]?.stringValue {
    case "ready":
      return .ready(clientID: value["clientId"]?.stringValue ?? "")
    case "emit":
      guard let event = value["event"]?.stringValue, let args = value["args"]?.arrayValue else { return nil }
      return .emit(event: event, args: args)
    case "waterfall":
      guard let eventID = value["eventId"]?.stringValue,
            let agentID = value["agentId"]?.stringValue,
            let event = value["event"]?.stringValue,
            let request = value["request"], case .object = request else { return nil }
      return .waterfall(eventID: eventID, agentID: agentID, event: event, request: request)
    case "cancel":
      guard let eventID = value["eventId"]?.stringValue else { return nil }
      return .cancel(eventID: eventID)
    default:
      return nil
    }
  }
}

public extension MobileGatewayRPC {
  var hostVersion: String? { nil }
}

/// A host error carrying the DSH provider code, which the wire passes through verbatim —
/// the phone's error copy is written against those codes, so they are not translated here.
public struct MobileGatewayHostError: Error, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  /// The plugin's rule: a host error's own `code` if it has one, else `internal`.
  public init(error: Error) {
    if let error = error as? MobileGatewayHostError {
      self = error
      return
    }
    if let error = error as? HarnessAPIError {
      self.code = error.providerCode ?? "internal"
      self.message = error.message
      return
    }
    self.code = "internal"
    self.message = (error as NSError).localizedDescription
  }
}

/// The real transport: the running harness's local API.
///
/// Unary calls go over `/api/<endpoint>` exactly as the harness's own web UI sends them; streams
/// go over the WebSocket multiplexer at `/api/remote.mux`. Both are already implemented for the
/// IM channel, so the gateway reuses them rather than opening a second dialect to the same host.
public struct HarnessAPIRPC: MobileGatewayRPC {
  /// The `$events` carrier must be reachable from `answer(eventID:value:)` after `events()`
  /// returned, and this type is a value — so the one long-lived reference lives in a box that
  /// every copy of the struct shares.
  private final class EventCarrier: @unchecked Sendable {
    var stream: (any RemoteEventStreaming)?
  }

  private let client: HarnessAPIClient
  private let carrier = EventCarrier()

  public init(client: HarnessAPIClient) {
    self.client = client
  }

  public var hostVersion: String? { nil }

  public func invoke(endpoint: String, args: JSONValue) async throws -> JSONValue {
    do {
      return try await client.call(endpoint: endpoint, args: args)
    } catch {
      throw MobileGatewayHostError(error: error)
    }
  }

  public func stream(endpoint: String, args: JSONValue) async throws -> AsyncThrowingStream<JSONValue, Error> {
    // One socket per logical stream, deliberately: the mux can multiplex, but a stream that
    // ends must not be able to disturb another subscription, and reconnecting has to have
    // exactly one thing to re-establish.
    let streamer = try HarnessMuxStream(client: client, endpoint: endpoint, args: args)
    return try await streamer.open()
  }

  /// The `$events` feed. It is a *different* stream from the per-session `session/follow`
  /// streams: the waterfalls the phone answers live here, and they arrive before any session
  /// is subscribed.
  public func events() async throws -> AsyncThrowingStream<MobileGatewayHostEvent, Error> {
    // The factory reads the client's cookie, so it is actor-isolated and needs the hop.
    let stream = try await client.makeRemoteEventStream()
    let raw = try await stream.open()
    carrier.stream = stream
    let (mapped, continuation) = AsyncThrowingStream<MobileGatewayHostEvent, Error>.makeStream()
    let pump = Task {
      do {
        for try await frame in raw {
          switch frame {
          case .ready(let clientID):
            continuation.yield(.ready(clientID: clientID))
          case .emit(let event, let args):
            continuation.yield(.emit(event: event, args: args))
          case .waterfall(let eventID, let agentID, let event, let request):
            continuation.yield(.waterfall(eventID: eventID, agentID: agentID, event: event, request: request))
          case .cancel(let eventID):
            continuation.yield(.cancel(eventID: eventID))
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: MobileGatewayHostError(error: error))
      }
    }
    continuation.onTermination = { _ in pump.cancel() }
    return mapped
  }

  public func answer(eventID: String, value: JSONValue) async throws {
    guard let stream = carrier.stream else {
      throw MobileGatewayHostError(code: "internal", message: "event stream is not open")
    }
    do {
      try await stream.answer(eventID: eventID, value: value)
    } catch {
      throw MobileGatewayHostError(error: error)
    }
  }
}

/// A single logical stream over the harness's WebSocket multiplexer.
///
/// The mux wire protocol is small: the client sends
/// `{type:"open", streamId, endpoint, payload:{args}}` and receives `{type:"item", streamId, value}`,
/// `{type:"end", streamId}` or `{type:"error", streamId, error}`.
public final class HarnessMuxStream: @unchecked Sendable {
  private let client: HarnessAPIClient
  private let endpoint: String
  private let args: JSONValue
  private let session: URLSession
  private let lock = NSLock()
  private var socket: URLSessionWebSocketTask?

  public init(client: HarnessAPIClient, endpoint: String, args: JSONValue) throws {
    self.client = client
    self.endpoint = endpoint
    self.args = args
    let configuration = URLSessionConfiguration.ephemeral
    // A subscribed session may sit idle for hours; a request timeout would kill it.
    configuration.timeoutIntervalForRequest = 24 * 60 * 60
    self.session = URLSession(configuration: configuration)
  }

  public func open() async throws -> AsyncThrowingStream<JSONValue, Error> {
    guard let url = client.muxWebSocketURL else {
      throw MobileGatewayHostError(code: "internal", message: "harness 事件流地址不可用")
    }
    let streamID = UUID().uuidString
    var request = URLRequest(url: url)
    // The cookie is actor-isolated on the client (it is mutable state), so it is read once
    // here rather than captured.
    let cookie = await client.sessionCookie
    if let cookie, !cookie.isEmpty {
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
    let task = session.webSocketTask(with: request)
    lock.lock(); socket = task; lock.unlock()
    task.resume()

    let open: JSONValue = .object([
      "type": .string("open"),
      "streamId": .string(streamID),
      "endpoint": .string(endpoint),
      "payload": .object(["args": args]),
    ])
    try await Self.send(task, open)

    let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
    let pump = Task { [weak self] in
      do {
        while !Task.isCancelled {
          let message = try await task.receive()
          guard let text = Self.text(of: message),
                let envelope = try? JSONValue.parse(text, context: "harness.mux") else { continue }
          guard envelope["streamId"]?.stringValue == streamID else { continue }
          switch envelope["type"]?.stringValue {
          case "item":
            if let value = envelope["value"] { continuation.yield(value) }
          case "end":
            continuation.finish()
            return
          case "error":
            let code = envelope["error"]?["code"]?.stringValue ?? "internal"
            let message = envelope["error"]?["message"]?.stringValue ?? "harness 事件流出错"
            continuation.finish(throwing: MobileGatewayHostError(code: code, message: message))
            return
          default:
            continue
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: MobileGatewayHostError(error: error))
      }
      _ = self // keep the stream object alive for the socket's lifetime
    }
    continuation.onTermination = { _ in
      pump.cancel()
      task.cancel(with: .goingAway, reason: nil)
    }
    return stream
  }

  public func close() {
    lock.lock()
    let task = socket
    socket = nil
    lock.unlock()
    task?.cancel(with: .goingAway, reason: nil)
  }

  private static func send(_ task: URLSessionWebSocketTask, _ value: JSONValue) async throws {
    guard let text = try? value.serialized() else {
      throw MobileGatewayHostError(code: "internal", message: "无法编码会话流请求")
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
