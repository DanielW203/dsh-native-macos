import Foundation
import HarnessKit

// The *control plane* half of the push path: the two background host streams the plugin
// keeps for the whole gateway, here scoped to one control/legacy connection.
//
// The control stream carries `todos`/`goal` projections and session queues; the workspace
// stream carries the archived-session set. Both are baseline-then-increment streams, and
// both are lossy-tolerant: a reconnect re-reads the baseline, so a frame missed during a
// disconnect is repaired rather than lost.

// MARK: - Faults

/// Which background stream a failure came from.
enum MobileGatewayControlStream: String, Sendable {
  case control
  case workspace
}

/// Reported to `MobileGatewayControlPump.onFailure`.
///
/// Purely informational. The plugin's two background loops only log, and they retry
/// forever on a fixed one-second delay, so a transient host or network fault is expected
/// rather than terminal — the service must not tear the connection down on this.
struct MobileGatewayControlStreamFailure: Error, Sendable, Equatable, CustomStringConvertible {
  var stream: MobileGatewayControlStream
  var message: String

  var description: String { "\(stream.rawValue) stream: \(message)" }
}

// MARK: - Control pump

/// Follows the control plane (`session/control` + `workspace/follow`) and emits the wire
/// frames a control/legacy channel receives. One instance per such connection.
///
/// The two streams are independent loops, exactly as they are in the plugin, and each
/// one keeps the state its frames are derived from: an *empty* baseline is meaningful
/// (it clears the client), so the pump never invents a frame from a stream it has not
/// heard from yet.
public final class MobileGatewayControlPump: @unchecked Sendable {
  private let adapter: MobileGatewayHostAdapter
  private let onFrame: @Sendable (JSONValue) -> Void
  private let onFailure: @Sendable (Error) -> Void

  private let lock = NSLock()
  private var run: MobileGatewayPumpRun?
  private var task: Task<Void, Never>?

  public init(
    adapter: MobileGatewayHostAdapter,
    onFrame: @escaping @Sendable (JSONValue) -> Void,
    onFailure: @escaping @Sendable (Error) -> Void
  ) {
    self.adapter = adapter
    self.onFrame = onFrame
    self.onFailure = onFailure
  }

  /// Start both background loops.
  ///
  /// Idempotent while running: the plugin owns exactly one control pair for the whole
  /// gateway, so a second `start()` here must not open a second pair against the host.
  public func start() {
    lock.lock()
    if run != nil {
      lock.unlock()
      return
    }
    let next = MobileGatewayPumpRun()
    run = next
    lock.unlock()

    let task = Task { [adapter, onFrame, onFailure] in
      await MobileGatewayControlPump.run(
        run: next,
        adapter: adapter,
        onFrame: onFrame,
        onFailure: onFailure
      )
    }
    lock.lock()
    if run === next {
      self.task = task
    } else {
      // `stop()` won the race.
      next.cancel()
      task.cancel()
    }
    lock.unlock()
  }

  /// Idempotent and synchronous: both loops (and any host stream they are blocked on) are
  /// released, and no frame is produced after it returns.
  public func stop() {
    lock.lock()
    let run = self.run
    let task = self.task
    self.run = nil
    self.task = nil
    lock.unlock()
    run?.cancel()
    task?.cancel()
  }

  // MARK: - Loops

  private static func run(
    run: MobileGatewayPumpRun,
    adapter: MobileGatewayHostAdapter,
    onFrame: @escaping @Sendable (JSONValue) -> Void,
    onFailure: @escaping @Sendable (Error) -> Void
  ) async {
    // Both loops are children of one task so `stop()` has a single handle; cancellation
    // propagates into the group.
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await workspaceLoop(run: run, adapter: adapter, onFrame: onFrame, onFailure: onFailure)
      }
      group.addTask {
        await controlLoop(run: run, adapter: adapter, onFrame: onFrame, onFailure: onFailure)
      }
    }
  }

  /// `workspace/follow` → `session-archives`.
  private static func workspaceLoop(
    run: MobileGatewayPumpRun,
    adapter: MobileGatewayHostAdapter,
    onFrame: @Sendable (JSONValue) -> Void,
    onFailure: @Sendable (Error) -> Void
  ) async {
    // The archived set is the last complete state the gateway held, kept across reconnects
    // so a baseline that matches it does not re-send the whole list.
    var archived: [String]?
    while !run.isCancelled && !Task.isCancelled {
      do {
        let stream = try await adapter.openWorkspaceStream()
        for try await frame in stream {
          if run.isCancelled || Task.isCancelled { return }
          switch frame["type"]?.stringValue {
          case "baseline":
            try installArchivedSessionIDs(
              frame["value"]?["archivedSessionIds"],
              state: &archived,
              onFrame: onFrame
            )
          case "archived":
            try installArchivedSessionIDs(frame["archivedSessionIds"], state: &archived, onFrame: onFrame)
          default:
            break
          }
        }
      } catch {
        if run.isCancelled || Task.isCancelled { return }
        onFailure(MobileGatewayControlStreamFailure(
          stream: .workspace,
          message: MobileGatewayFollowPolicy.message(of: error)
        ))
      }
      if run.isCancelled || Task.isCancelled { return }
      if await run.sleepFor(milliseconds: 1000) { return }
    }
  }

  /// `session/control` → `projection-baseline`, `session-queues`, `session-queue`,
  /// `tasks-updated`, `goal-updated`.
  private static func controlLoop(
    run: MobileGatewayPumpRun,
    adapter: MobileGatewayHostAdapter,
    onFrame: @Sendable (JSONValue) -> Void,
    onFailure: @Sendable (Error) -> Void
  ) async {
    var queues: [String: [JSONValue]]?
    var projections: [String: ProjectionState] = [:]
    while !run.isCancelled && !Task.isCancelled {
      do {
        let stream = try await adapter.openControlStream()
        for try await frame in stream {
          if run.isCancelled || Task.isCancelled { return }
          switch frame["type"]?.stringValue {
          case "baseline":
            try installProjectionBaseline(
              frame["value"]?["projections"],
              state: &projections,
              onFrame: onFrame
            )
            try installSessionQueueBaseline(
              frame["value"]?["queues"],
              projections: frame["value"]?["projections"],
              state: &queues,
              onFrame: onFrame
            )

          case "queue":
            try installSessionQueue(
              frame["sessionId"],
              items: frame["items"],
              state: &queues,
              onFrame: onFrame
            )

          case "projection":
            guard let key = frame["key"]?.stringValue else { break }
            if key == "inbox" {
              // Harness ≥ 0.1.6-alpha.2 reports pending input as this projection; the old
              // harness pushed an equivalent `queue` frame instead.
              try installSessionQueue(
                frame["sessionId"],
                items: .array(queueItems(fromInbox: frame["value"])),
                state: &queues,
                onFrame: onFrame
              )
              break
            }
            guard key == "todos" || key == "goal" else { break }
            let sessionID = MobileGatewayJSText.string(frame["sessionId"])
            var state = projections[sessionID] ?? ProjectionState()
            state.asOfSeq = frame["seq"]
            // `{ ...previous?.values, [key]: value }`: only the pushed key moves.
            if key == "todos" { state.todos = frame["value"] } else { state.goal = frame["value"] }
            projections[sessionID] = state
            onFrame(projectionFrame(
              sessionID: sessionID,
              key: key,
              value: frame["value"] ?? .null,
              seq: frame["seq"]
            ))

          default:
            break
          }
        }
      } catch {
        if run.isCancelled || Task.isCancelled { return }
        onFailure(MobileGatewayControlStreamFailure(
          stream: .control,
          message: MobileGatewayFollowPolicy.message(of: error)
        ))
      }
      if run.isCancelled || Task.isCancelled { return }
      if await run.sleepFor(milliseconds: 1000) { return }
    }
  }

  // MARK: - Archived sessions

  private static func installArchivedSessionIDs(
    _ value: JSONValue?,
    state: inout [String]?,
    onFrame: @Sendable (JSONValue) -> Void
  ) throws {
    guard let array = value?.arrayValue else {
      throw MobileGatewayStreamError(message: "workspace/follow returned invalid archivedSessionIds")
    }
    let next = array.map { MobileGatewayJSText.string($0) }
    if let state, state.count == next.count, zip(state, next).allSatisfy({ $0 == $1 }) { return }
    state = next
    // A complete replacement set, never a delta: a device that connects late receives the
    // whole current list, and every later archive produces another complete set.
    onFrame(.object([
      "kind": .string("session-archives"),
      "archivedSessionIds": .array(next.map { .string($0) }),
    ]))
  }

  // MARK: - Projections

  private struct ProjectionState {
    var asOfSeq: JSONValue?
    var todos: JSONValue?
    var goal: JSONValue?
  }

  /// `installProjectionBaseline`: a wholesale replacement of the gateway's `todos`/`goal`
  /// snapshot, followed by the per-session increments the baseline implies — a goal edited
  /// during a disconnect must not wait for the next increment to reach the phone.
  private static func installProjectionBaseline(
    _ value: JSONValue?,
    state: inout [String: ProjectionState],
    onFrame: @Sendable (JSONValue) -> Void
  ) throws {
    guard let raw = value?.objectValue else {
      throw MobileGatewayStreamError(message: "invalid projection baseline")
    }
    var next: [String: ProjectionState] = [:]
    for (sessionID, baseline) in raw {
      guard let asOfSeq = MobileGatewayNumbers.safeInteger(baseline["asOfSeq"]),
            let values = baseline["values"]?.objectValue else {
        throw MobileGatewayStreamError(message: "invalid session projection baseline")
      }
      next[sessionID] = ProjectionState(
        asOfSeq: .number(Double(asOfSeq)),
        todos: values["todos"] ?? .null,
        goal: values["goal"] ?? .null
      )
    }
    let previous = state
    state = next

    var wire: [String: JSONValue] = [:]
    for (sessionID, baseline) in next {
      wire[sessionID] = .object([
        "asOfSeq": baseline.asOfSeq ?? .null,
        "values": .object([
          "todos": baseline.todos ?? .null,
          "goal": baseline.goal ?? .null,
        ]),
      ])
    }
    // This one ignores session filters entirely: a missing session or key means "clear
    // that value", so a filtered baseline would leave stale tasks on the phone.
    onFrame(.object([
      "kind": .string("projection-baseline"),
      "projections": .object(wire),
    ]))

    for sessionID in Set(previous.keys).union(next.keys) {
      let baseline = next[sessionID]
      for key in ["todos", "goal"] {
        let value = (key == "todos" ? baseline?.todos : baseline?.goal) ?? .null
        // A session that vanished from the baseline still needs its clearing increment,
        // stamped with the seq the previous baseline reported.
        let seq = baseline?.asOfSeq ?? previous[sessionID]?.asOfSeq
        onFrame(projectionFrame(sessionID: sessionID, key: key, value: value, seq: seq))
      }
    }
  }

  /// `projectionFrame`: the two projection keys are the only ones with a wire frame of
  /// their own, and the payload key is the projection name itself.
  private static func projectionFrame(
    sessionID: String,
    key: String,
    value: JSONValue,
    seq: JSONValue?
  ) -> JSONValue {
    var frame: [String: JSONValue] = [
      "kind": .string(key == "todos" ? "tasks-updated" : "goal-updated"),
      "sessionId": .string(sessionID),
      key: value,
    ]
    if let seq { frame["asOfSeq"] = seq }
    return .object(frame)
  }

  // MARK: - Queues

  /// `installSessionQueueBaseline`: the whole queue map, which the client must apply as a
  /// replacement — sessions absent from it are cleared.
  ///
  /// Harness < 0.1.6 carried that map as the baseline's own `queues` key and pushed a
  /// `queue` frame per change. 0.1.6-alpha.2 dropped both: the same state now arrives as
  /// each session's `inbox` projection block. A present `queues` key stays authoritative,
  /// and its absence is the new shape — never a stream failure, which is what made the
  /// control pump retry once a second against a harness that no longer sends it.
  static func installSessionQueueBaseline(
    _ value: JSONValue?,
    projections: JSONValue?,
    state: inout [String: [JSONValue]]?,
    onFrame: @Sendable (JSONValue) -> Void
  ) throws {
    var next: [String: [JSONValue]] = [:]
    if let raw = value?.objectValue {
      for (sessionID, items) in raw {
        next[sessionID] = try normalizeQueueItems(items, endpoint: "session/control baseline")
      }
    } else if let value, value != .null {
      throw MobileGatewayStreamError(message: "session/control baseline returned invalid queues")
    } else {
      // Only sessions with a live Agent carry an `inbox`; an absent block is an empty
      // queue, and a session the map omits is cleared.
      for (sessionID, block) in projections?.objectValue ?? [:] {
        guard let values = block["values"]?.objectValue, values["inbox"] != nil else { continue }
        next[sessionID] = queueItems(fromInbox: values["inbox"])
      }
    }
    state = next
    var queues: [String: JSONValue] = [:]
    for (sessionID, items) in next { queues[sessionID] = .array(items) }
    onFrame(.object([
      "kind": .string("session-queues"),
      "queues": .object(queues),
    ]))
  }

  /// `queueItems(fromInbox:)`: the `queues` map the pre-0.1.6 baseline carried, rebuilt from
  /// an `inbox` projection value — `next-turn` messages are queued, `next-step` messages
  /// with a user source are steering and anything else is context, which is the rule the
  /// host itself used when it folded that same map. Malformed entries are skipped: the
  /// phone must not lose the whole queue, let alone the stream, over one bad message.
  static func queueItems(fromInbox inbox: JSONValue?) -> [JSONValue] {
    guard let value = inbox?.objectValue else { return [] }
    return queueItems(fromInboxMessages: value["next-turn"], placement: "queued")
      + queueItems(fromInboxMessages: value["next-step"], placement: nil)
  }

  private static func queueItems(
    fromInboxMessages messages: JSONValue?,
    placement fixedPlacement: String?
  ) -> [JSONValue] {
    guard let array = messages?.arrayValue else { return [] }
    return array.compactMap { message in
      guard let fields = message.objectValue,
            let id = fields["id"]?.stringValue, !id.isEmpty,
            let content = fields["content"]?.arrayValue else { return nil }
      let source = fields["source"]?.objectValue
      let isUser = source?["kind"]?.stringValue == "user"
      let placement = fixedPlacement ?? (isUser ? "steering" : "context")
      var item: [String: JSONValue] = [
        "id": .string(id),
        "placement": .string(placement),
        "message": .object(["id": .string(id), "content": .array(content)]),
      ]
      // `rpcId` is present-or-absent, never null: an unclaimed send has no receipt to route.
      if isUser, let rpcId = source?["rpcId"]?.stringValue { item["rpcId"] = .string(rpcId) }
      return .object(item)
    }
  }

  /// `installSessionQueue`: one session's whole queue, never an append.
  private static func installSessionQueue(
    _ sessionIDValue: JSONValue?,
    items itemsValue: JSONValue?,
    state: inout [String: [JSONValue]]?,
    onFrame: @Sendable (JSONValue) -> Void
  ) throws {
    guard let sessionID = sessionIDValue?.stringValue, !sessionID.isEmpty else {
      throw MobileGatewayStreamError(message: "session/control returned an invalid queue sessionId")
    }
    let items = try normalizeQueueItems(itemsValue, endpoint: "session/control queue")
    if state == nil { state = [:] }
    state?[sessionID] = items
    onFrame(.object([
      "kind": .string("session-queue"),
      "sessionId": .string(sessionID),
      "items": .array(items),
    ]))
  }

  /// `normalizeQueueItems`: the wire `QueueItem` is a *narrowed* projection of the host's
  /// queued message, so the phone never sees whatever else the host keeps alongside it —
  /// and a malformed item fails the whole frame rather than being skipped, because a
  /// partially applied queue is worse than a retried one.
  private static func normalizeQueueItems(_ value: JSONValue?, endpoint: String) throws -> [JSONValue] {
    guard let items = value?.arrayValue else {
      throw MobileGatewayStreamError(message: "\(endpoint) returned invalid queue items")
    }
    return try items.map { candidate in
      guard let fields = candidate.objectValue,
            let id = fields["id"]?.stringValue, !id.isEmpty,
            let placement = fields["placement"]?.stringValue,
            ["queued", "steering", "context"].contains(placement),
            let message = fields["message"]?.objectValue,
            let messageID = message["id"]?.stringValue, !messageID.isEmpty,
            let content = message["content"]?.arrayValue,
            fields["rpcId"] == nil || fields["rpcId"]?.stringValue != nil else {
        throw MobileGatewayStreamError(message: "\(endpoint) returned an invalid queue item")
      }
      var normalized: [String: JSONValue] = ["id": .string(id), "placement": .string(placement)]
      // `rpcId` is present-or-absent, never null: an unclaimed send has no receipt to route.
      if let rpcId = fields["rpcId"] { normalized["rpcId"] = rpcId }
      normalized["message"] = .object(["id": .string(messageID), "content": .array(content)])
      return .object(normalized)
    }
  }
}
