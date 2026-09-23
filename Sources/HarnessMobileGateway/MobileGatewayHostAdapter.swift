import Foundation
import HarnessKit

/// The only module that knows DSH Remote endpoint names and argument shapes.
///
/// Its methods are named after mobile-gateway *operations*, not upstream envelopes, so the
/// protocol layer above never learns that `history` is really `session/follow` plus
/// `session/page`, or that only `session/list` spells its argument `_request`.
///
/// This is an actor because it keeps two pieces of cross-call state the plugin also keeps:
/// per-session serialisation of prompt/preset operations, and the "a prompt was admitted but
/// `turn/start` has not arrived yet" marker that locks a session's agent preset.
public actor MobileGatewayHostAdapter {
  /// A session snapshot: the format-3 opening frame of `session/follow`.
  public struct SessionSnapshot: Sendable {
    /// History records, each already wrapped as `{ event: … }` the way the wire expects.
    public var events: [JSONValue]
    public var hasMore: Bool
    public var projections: JSONValue
    public var historyFormatVersion: Int
    public var cursor: Int
  }

  private let rpc: MobileGatewayRPC
  /// Per-session tails, reproducing the plugin's promise chain: a preset switch and a prompt
  /// admitted at the same moment must not race each other into the session.
  private var sessionOperations: [String: Task<Void, Never>] = [:]
  private var admittedPrompts: Set<String> = []

  public init(rpc: MobileGatewayRPC) {
    self.rpc = rpc
  }

  /// The DSH version to report in `hello`; nil means "use the compatibility declaration".
  public nonisolated var hostVersion: String? { rpc.hostVersion }

  // MARK: - Envelope helpers

  private func invoke(_ endpoint: String, _ args: JSONValue) async throws -> JSONValue {
    try await rpc.invoke(endpoint: endpoint, args: args)
  }

  /// The plugin wraps most host arguments in `{ request: … }`; `session/list` is the sole
  /// endpoint that names it `_request`, because the host preserves source parameter names.
  private static func requestArgs(_ request: JSONValue) -> JSONValue {
    .object(["request": request])
  }

  private static func sessionListArgs(_ request: JSONValue) -> JSONValue {
    .object(["_request": request])
  }

  /// Open a host stream and take only its first frame, then let it go.
  ///
  /// Several "queries" are streams that answer with an opening Baseline and then keep talking;
  /// reading one frame and aborting is what keeps them queries.
  private func firstStreamFrame(endpoint: String, args: JSONValue) async throws -> JSONValue {
    let stream = try await rpc.stream(endpoint: endpoint, args: args)
    var iterator = stream.makeAsyncIterator()
    guard let first = try await iterator.next() else {
      throw MobileGatewayHostError(code: "internal", message: "\(endpoint) ended before its opening frame")
    }
    return first
  }

  // MARK: - Sessions

  public func snapshot(sessionID: String, maxMessages: Int? = nil, assistantStream: Bool? = nil) async throws -> SessionSnapshot {
    var request: [String: JSONValue] = [
      "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
    ]
    if let maxMessages { request["maxMessages"] = .number(Double(maxMessages)) }
    if let assistantStream { request["assistantStream"] = .bool(assistantStream) }
    let frame = try await firstStreamFrame(
      endpoint: "session/follow",
      args: Self.requestArgs(.object(request))
    )
    return try Self.readSnapshot(frame, sessionID: sessionID)
  }

  /// Decode the format-3 snapshot, refusing anything older: the mobile protocol's history
  /// contract is defined against format 3, and silently downgrading would corrupt the phone's
  /// cache rather than fail it.
  static func readSnapshot(_ frame: JSONValue, sessionID: String) throws -> SessionSnapshot {
    guard frame["type"]?.stringValue == "snapshot",
          let cursor = frame["cursor"]?.intValue, cursor >= -1,
          frame["header"]?["id"]?.stringValue == sessionID else {
      throw MobileGatewayHostError(code: "internal", message: "session/follow returned an invalid snapshot")
    }
    guard frame["header"]?["version"]?.intValue == MobileGatewayConfiguration.historyFormatVersion else {
      throw MobileGatewayHostError(
        code: "unsupported-session-format",
        message: "mobile-gateway requires DSH Session format 3"
      )
    }
    let events = try readHistoryRecords(frame["records"] ?? .null)
    return SessionSnapshot(
      events: events.map { .object(["event": $0]) },
      hasMore: frame["hasMore"]?.boolValue == true,
      projections: frame["projections"] ?? .object([:]),
      historyFormatVersion: MobileGatewayConfiguration.historyFormatVersion,
      cursor: cursor
    )
  }

  /// History records are delivered as `{type:'event', event:{…}}` envelopes; only the inner
  /// event is part of the wire contract.
  static func readHistoryRecords(_ value: JSONValue) throws -> [JSONValue] {
    guard let records = value.arrayValue else {
      throw MobileGatewayHostError(code: "internal", message: "session history returned an invalid array")
    }
    return try records.map { record in
      guard record["type"]?.stringValue == "event" else {
        throw MobileGatewayHostError(code: "internal", message: "DSH history requires event records")
      }
      guard let event = record["event"], let seq = event["seq"]?.intValue, seq >= 0 else {
        throw MobileGatewayHostError(code: "internal", message: "invalid history sequence")
      }
      return event
    }
  }

  public func history(_ payload: JSONValue) async throws -> JSONValue {
    guard let sessionID = payload["sessionId"]?.stringValue, !sessionID.isEmpty else {
      throw MobileGatewayHostError(code: "bad-request", message: "history requires a sessionId")
    }
    let beforeSeq = payload["beforeSeq"]?.intValue
    // An older-page request needs only the opening cursor and projections, not another full
    // latest page; asking for one message is the cheapest way to get both.
    let openingMax = beforeSeq != nil ? 1 : payload["maxMessages"]?.intValue
    let snapshot = try await snapshot(sessionID: sessionID, maxMessages: openingMax)
    guard let beforeSeq else {
      return snapshotFrame(snapshot, requestType: "history", sessionID: sessionID)
    }
    let page = try await invoke("session/page", Self.requestArgs(.object([
      "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
      "throughSeq": .number(Double(snapshot.cursor)),
      "beforeSeq": .number(Double(beforeSeq)),
      "maxMessages": .number(Double(payload["maxMessages"]?.intValue ?? 50)),
    ])))
    var adjusted = snapshot
    adjusted.events = try Self.readHistoryRecords(page["records"] ?? .null).map { .object(["event": $0]) }
    adjusted.hasMore = page["hasMore"]?.boolValue == true
    return snapshotFrame(adjusted, requestType: "history", sessionID: sessionID)
  }

  private func snapshotFrame(_ snapshot: SessionSnapshot, requestType: String, sessionID: String?) -> JSONValue {
    var frame: [String: JSONValue] = [
      "kind": .string("history"),
      "events": .array(snapshot.events),
      "hasMore": .bool(snapshot.hasMore),
      "projections": snapshot.projections,
      "historyFormatVersion": .number(Double(snapshot.historyFormatVersion)),
      "cursor": .number(Double(snapshot.cursor)),
    ]
    if let sessionID { frame["sessionId"] = .string(sessionID) }
    _ = requestType
    return .object(frame)
  }

  public func listSessions() async throws -> JSONValue {
    try await invoke("session/list", Self.sessionListArgs(.object([:])))
  }

  public func search(_ query: String) async throws -> JSONValue {
    try await invoke("session/search", Self.requestArgs(.object(["query": .string(query)])))
  }

  public func createSession(_ payload: JSONValue) async throws -> JSONValue {
    try await invoke("session/create", Self.requestArgs(payload))
  }

  public func attachment(sessionID: String, attachmentID: String) async throws -> JSONValue {
    try await invoke("session/attachment", Self.requestArgs(.object([
      "sessionId": .string(sessionID),
      "attachmentId": .string(attachmentID),
    ])))
  }

  public func fork(_ payload: JSONValue) async throws -> JSONValue {
    try await invoke("session/fork", Self.requestArgs(payload))
  }

  public func cancel(sessionID: String) async throws -> JSONValue {
    try await invoke("session/cancel", Self.requestArgs(.object(["sessionId": .string(sessionID)])))
  }

  public func updateQueue(_ payload: JSONValue) async throws -> JSONValue {
    try await invoke("session/updateQueue", Self.requestArgs(payload))
  }

  public func rename(sessionID: String, title: String) async throws -> JSONValue {
    try await invoke("session/rename", Self.requestArgs(.object([
      "sessionId": .string(sessionID),
      "title": .string(title),
    ])))
  }

  public func selectModel(_ payload: JSONValue) async throws -> JSONValue {
    try await invoke("session/selectModel", Self.requestArgs(payload))
  }

  public func modelCatalog() async throws -> JSONValue {
    try await invoke("session/modelCatalog", .object([:]))
  }

  public func sessionModels(sessionID: String) async throws -> JSONValue {
    async let catalogTask = modelCatalog()
    async let snapshotTask = snapshot(sessionID: sessionID, maxMessages: 1)
    let catalog = try await catalogTask
    let snapshot = try await snapshotTask
    // The projection is the live truth; the catalog's default is only the fallback for a
    // session that has never selected a model.
    let current = snapshot.projections["values"]?["modelSelection"]?["next"] ?? catalog["default"] ?? .null
    let routable = current["provider"]?.stringValue.map { provider in
      (catalog["routableProviders"]?.arrayValue ?? []).contains { $0.stringValue == provider }
    } ?? false
    return .object([
      "kind": .string("models"),
      "current": current,
      "routable": .bool(routable),
      "groups": catalog["groups"] ?? .array([]),
      "failures": catalog["failures"] ?? .array([]),
    ])
  }

  // MARK: - Prompting

  /// Submit a prompt, serialised behind any earlier operation on the same session.
  ///
  /// The marker is set before the call and only cleared if the call itself failed: accepted
  /// input may not have reached `turn/start` yet, and during that gap the session's agent
  /// preset must stay locked.
  public func prompt(_ payload: JSONValue) async throws -> JSONValue {
    guard let sessionID = payload["sessionId"]?.stringValue else {
      throw MobileGatewayHostError(code: "bad-request", message: "prompt requires a sessionId")
    }
    return try await serialized(sessionID) { [weak self] in
      guard let self else { throw MobileGatewayHostError(code: "internal", message: "adapter released") }
      let alreadyAdmitted = await self.isAdmitted(sessionID)
      await self.markAdmitted(sessionID)
      do {
        var request = payload
        if case .object(var fields) = request {
          fields["requestId"] = .string(UUID().uuidString)
          request = .object(fields)
        }
        return try await self.invoke("session/prompt", Self.requestArgs(request))
      } catch {
        if !alreadyAdmitted { await self.clearAdmitted(sessionID) }
        throw error
      }
    }
  }

  /// Run `operation` after every operation already queued for this session.
  private func serialized(_ sessionID: String, _ operation: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
    let previous = sessionOperations[sessionID]
    let task = Task { () -> JSONValue in
      await previous?.value
      return try await operation()
    }
    sessionOperations[sessionID] = Task { _ = try? await task.value }
    defer { }
    let value = try await task.value
    // Only the tail is retained; earlier entries retire themselves as they complete.
    if sessionOperations[sessionID]?.isCancelled != false { sessionOperations.removeValue(forKey: sessionID) }
    return value
  }

  private func isAdmitted(_ sessionID: String) -> Bool { admittedPrompts.contains(sessionID) }
  private func markAdmitted(_ sessionID: String) { admittedPrompts.insert(sessionID) }
  private func clearAdmitted(_ sessionID: String) { admittedPrompts.remove(sessionID) }

  /// A durable `turn/start` (or any read that shows the turn began) retires the admitted marker.
  public func observeSessionEvent(sessionID: String, event: JSONValue) {
    if event["type"]?.stringValue == "turn/start" { admittedPrompts.remove(sessionID) }
  }

  // MARK: - Agent presets

  public func agentPresets() async throws -> JSONValue {
    try await invoke("agentPresets/list", .object([:]))
  }

  public func agentPresetState(sessionID: String) async throws -> JSONValue {
    try await serialized(sessionID) { [weak self] in
      guard let self else { throw MobileGatewayHostError(code: "internal", message: "adapter released") }
      return try await self.presetState(sessionID)
    }
  }

  private func presetState(_ sessionID: String) async throws -> JSONValue {
    let snapshot = try await snapshot(sessionID: sessionID, maxMessages: 1)
    let values = snapshot.projections["values"]
    let metadata = values?["sessionListMetadata"]
    // `lastPromptAt` is valid only as `null` or a finite number; anything else means the
    // projection has not settled and the lock state cannot be trusted.
    let lastPromptAt = metadata?["lastPromptAt"]
    let lastPromptAtValid = lastPromptAt.map { $0.isNull || $0.doubleValue != nil } ?? false
    guard let agentPreset = values?["agentPreset"]?.stringValue,
          let blank = metadata?["blank"]?.boolValue,
          lastPromptAtValid else {
      throw MobileGatewayHostError(code: "agent-preset/unavailable", message: "session preset state is unavailable")
    }
    let durableLock = !blank || !(lastPromptAt?.isNull ?? true)
    if durableLock { admittedPrompts.remove(sessionID) }
    return .object([
      "sessionId": .string(sessionID),
      "agentPreset": .string(agentPreset),
      "locked": .bool(durableLock || admittedPrompts.contains(sessionID)),
    ])
  }

  public func selectAgentPreset(sessionID: String, preset: String) async throws -> JSONValue {
    try await serialized(sessionID) { [weak self] in
      guard let self else { throw MobileGatewayHostError(code: "internal", message: "adapter released") }
      let state = try await self.presetState(sessionID)
      if state["locked"]?.boolValue == true {
        throw MobileGatewayHostError(
          code: "agent-preset/locked",
          message: "session has already started; its agent preset is fixed"
        )
      }
      let selected = try await self.invoke("agentPresets/select", .object([
        "agentId": .string(sessionID),
        "agentPreset": .string(preset),
      ]))
      guard let value = selected.stringValue, !value.isEmpty else {
        throw MobileGatewayHostError(code: "internal", message: "agentPresets/select returned an invalid preset")
      }
      return .object(["sessionId": .string(sessionID), "agentPreset": .string(value)])
    }
  }

  // MARK: - Commands and skills

  public func commands(sessionID: String) async throws -> JSONValue {
    // Skills are the modern catalog; `commands/list` is the fallback for a host that has not
    // mounted the skills service yet.
    if let skills = try? await invoke("skills/list", Self.requestArgs(.object(["sessionId": .string(sessionID)]))) {
      return skills
    }
    return try await invoke("commands/list", .object(["agentId": .string(sessionID)]))
  }

  public func executeCommand(sessionID: String, line: String, attachments: [JSONValue]) async throws -> JSONValue {
    try await invoke("commands/execute", .object([
      "agentId": .string(sessionID),
      "line": .string(line),
      "submittedAttachments": .array(attachments),
    ]))
  }

  // MARK: - Workspaces, settings, providers

  public func listWorkspaces() async throws -> JSONValue {
    let frame = try await firstStreamFrame(endpoint: "workspace/follow", args: .object([:]))
    guard frame["type"]?.stringValue == "baseline", let value = frame["value"] else {
      throw MobileGatewayHostError(code: "internal", message: "workspace/follow returned an invalid opening baseline")
    }
    return value
  }

  public func createWorkspace(path: String) async throws -> JSONValue {
    try await invoke("workspace/create", Self.requestArgs(.object(["path": .string(path)])))
  }

  public func archiveSession(sessionID: String, archived: Bool) async throws -> JSONValue {
    try await invoke("workspace/archiveSession", Self.requestArgs(.object([
      "sessionId": .string(sessionID),
      "archived": .bool(archived),
    ])))
  }

  public func settingsDescribe() async throws -> JSONValue {
    try await invoke("settings/describe", .object([:]))
  }

  public func settingsUpdate(namespace: String, patch: JSONValue) async throws -> JSONValue {
    try await invoke("settings/update", .object([
      "ns": .string(namespace),
      "patch": patch,
    ]))
  }

  public func providers() async throws -> JSONValue {
    let value = try await invoke("llm/listConfigurableProviders", .object([:]))
    guard let providers = value.arrayValue else {
      throw MobileGatewayHostError(code: "internal", message: "llm/listConfigurableProviders returned an invalid array")
    }
    return .object(["providers": .array(providers)])
  }

  public func models() async throws -> JSONValue {
    let catalog = try await modelCatalog()
    return .object([
      "groups": catalog["groups"] ?? .array([]),
      "failures": catalog["failures"] ?? .array([]),
    ])
  }

  // MARK: - Goals

  public func goalEdit(sessionID: String, ref: JSONValue, objective: String?, maxGoalRounds: Int?) async throws -> JSONValue {
    var request: [String: JSONValue] = [:]
    if let objective { request["objective"] = .string(objective) }
    if let maxGoalRounds { request["maxGoalRounds"] = .number(Double(maxGoalRounds)) }
    let value = try await invoke("goals/edit", .object([
      "agentId": .string(sessionID),
      "ref": ref,
      "request": .object(request),
    ]))
    return try Self.goalRef(value, endpoint: "goals/edit")
  }

  public func goalPause(sessionID: String, ref: JSONValue) async throws -> JSONValue {
    try Self.goalRef(await invoke("goals/pause", .object([
      "agentId": .string(sessionID), "ref": ref,
    ])), endpoint: "goals/pause")
  }

  public func goalResume(sessionID: String, ref: JSONValue) async throws -> JSONValue {
    try Self.goalRef(await invoke("goals/resume", .object([
      "agentId": .string(sessionID), "ref": ref,
    ])), endpoint: "goals/resume")
  }

  public func goalClear(sessionID: String, ref: JSONValue) async throws -> JSONValue {
    _ = try await invoke("goals/clear", .object(["agentId": .string(sessionID), "ref": ref]))
    return .object(["cleared": .bool(true)])
  }

  /// The compare-and-set reference the phone must echo back: an edit against a stale revision
  /// must fail rather than clobber a goal the agent advanced meanwhile.
  static func goalRef(_ value: JSONValue, endpoint: String) throws -> JSONValue {
    guard let id = value["id"]?.stringValue, let revision = value["revision"]?.intValue else {
      throw MobileGatewayHostError(code: "internal", message: "\(endpoint) returned an invalid goal")
    }
    return .object(["ref": .object(["id": .string(id), "revision": .number(Double(revision))])])
  }

  // MARK: - Host description

  public func describeHost() async throws -> JSONValue {
    async let sessionsTask = invoke("session/list", Self.sessionListArgs(.object([:])))
    async let catalogTask = modelCatalog()
    async let canOpenTask = invoke("session/canOpenWorkspacePath", .object([:]))
    let sessions = try? await sessionsTask
    let catalog = try? await catalogTask
    let canOpen = (try? await canOpenTask)?.boolValue ?? false
    return .object([
      "kind": .string("host"),
      "version": .string("remote-gateway"),
      "dshVersion": .string(hostVersion ?? MobileGatewayConfiguration.dshVersion),
      "historyFormatVersion": .number(Double(MobileGatewayConfiguration.historyFormatVersion)),
      "cwd": .string(FileManager.default.homeDirectoryForCurrentUser.path),
      "attachedSessions": .number(Double(sessions?["items"]?.arrayValue?.count ?? 0)),
      "canOpenPath": .bool(canOpen),
      "defaultProvider": catalog?["default"]?["provider"] ?? .null,
      "defaultModel": catalog?["default"]?["model"] ?? .null,
    ])
  }

  // MARK: - Streams

  public func openSessionStream(sessionID: String) async throws -> AsyncThrowingStream<JSONValue, Error> {
    try await rpc.stream(endpoint: "session/follow", args: Self.requestArgs(.object([
      "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
      // Bound the opening window at the host; older records stay reachable through session/page.
      "maxMessages": .number(12),
      "assistantStream": .bool(true),
    ])))
  }

  public func openControlStream() async throws -> AsyncThrowingStream<JSONValue, Error> {
    try await rpc.stream(endpoint: "session/control", args: .object([:]))
  }

  public func openWorkspaceStream() async throws -> AsyncThrowingStream<JSONValue, Error> {
    try await rpc.stream(endpoint: "workspace/follow", args: .object([:]))
  }

  /// Read one projection value out of a fresh snapshot.
  public func projection(sessionID: String, key: String) async throws -> JSONValue? {
    let snapshot = try await snapshot(sessionID: sessionID, maxMessages: 1)
    return snapshot.projections["values"]?[key]
  }

  // MARK: - Permissions

  /// The process-level permission catalog (DSH 0.1.6 and later).
  ///
  /// The candidate list used to live in the session projection (`values.permissions.options`);
  /// 0.1.6 keeps only `currentValue` there and exposes the selectable presets from this
  /// deployment-level catalog instead. Returns `nil` when the host has no such endpoint, which is
  /// the 0.1.5 case — the caller then falls back to the projection's legacy list rather than
  /// failing the menu.
  public func permissionCatalog() async -> [JSONValue]? {
    guard let value = try? await invoke("permissionPresets/catalog", .object([:])),
          let options = value["options"]?.arrayValue else {
      return nil
    }
    // A catalog that is present but empty is still a catalog: falling back to a projection that
    // no longer has options would turn "no presets configured" into "the menu is broken".
    return options
  }

  // MARK: - Human-in-the-loop

  /// The forwarded-event feed that carries the approval and question waterfalls.
  public func events() async throws -> AsyncThrowingStream<MobileGatewayHostEvent, Error> {
    try await rpc.events()
  }

  /// Carry one answer back to the host promise the waterfall is holding open.
  public func answer(eventID: String, value: JSONValue) async throws {
    try await rpc.answer(eventID: eventID, value: value)
  }
}
