import Foundation
import HarnessKit

/// The query half of the mobile wire: every client `type` the plugin's `handleQuery` owns, plus
/// the conversation lane's `message` send path (`admitMessage`).
///
/// This is the one place where the phone's vocabulary meets the host adapter's operation names,
/// and it is deliberately the only place that validates a request. Two rules drive the shape of
/// the code below:
///
/// - **Validation never reaches the host.** A malformed frame is answered here, with the exact
///   `code` / `message` the plugin produced, because the phone's error copy is written against
///   them — a host round trip would only turn a precise error into a generic one.
/// - **Host payloads pass through unnormalized.** `workspaces`, `sessions`, `search`, `models`,
///   `providers` and `host` carry host-defined field sets, so the router spreads the host object
///   into `{ kind: <type>, ...value }` and never re-models it. Re-modelling is how a port silently
///   loses a field the phone already renders.
///
/// The struct is stateless: `MobileGatewayService` builds one per request. Anything that needs to
/// remember state between frames (the session/control pumps, the file-transfer manager) lives
/// elsewhere, which is why no verb here pushes a frame of its own — see `broadcast` below.
public struct MobileGatewayQueryRouter: Sendable {
  /// The host sizing defaults from the plugin. `history` keeps at most 4 MiB of events per frame
  /// and, in conversation view, shortens one tool-result text block to 2000 characters so a single
  /// huge tool output cannot dominate the page.
  public static let historyDefaultMaxBytes = 4 * 1024 * 1024
  public static let historyToolResultMaxChars = 2_000

  /// Every client `type` this router answers.
  ///
  /// The conversation lane owns `message` / `subscribe` / `unsubscribe` (the service handles
  /// those), `ping` and the `question-*` / `approval-*` waterfalls belong to the interaction
  /// layer, and the `file-*` family belongs to `MobileGatewayFileTransfer`. What remains is the
  /// plugin's `handleQuery` list, verbatim.
  public static let verbs: Set<String> = [
    "workspaces",
    "sessions",
    "history",
    "attachment",
    "search",
    "host",
    "directories",
    "directory-create",
    "workspace-create",
    "session-create",
    "models",
    "commands",
    "command-execute",
    "command-options",
    "command-select",
    "select-model",
    "permission-options",
    "permission",
    "context-usage",
    "session-stats",
    "tasks",
    "goal",
    "goal-edit",
    "goal-pause",
    "goal-resume",
    "goal-clear",
    "agent-presets",
    "session-agent-preset",
    "select-agent-preset",
    "defaults",
    "set-default",
    "default-model",
    "save-default-model",
    "fork",
    "session-cancel",
    "queue-update",
    "session-archive",
    "session-rename",
    "providers",
  ]

  /// The four media types the wire accepts. Image *bytes* are the host's business (signature,
  /// dimensions, per-image and total size); the gateway only refuses a shape the host could not
  /// have produced, so an unsupported type fails here with the plugin's own message.
  private static let imageMediaTypes: Set<String> = ["image/png", "image/jpeg", "image/webp", "image/gif"]
  private static let maxImagesPerRequest = 20
  private static let maxImageNameLength = 255

  /// The DSH settings section that owns the default model selection. The plugin reads it through
  /// the injected `agentDefaultModel` service, whose `currentSelection()`/`saveSelection()` are
  /// exactly a read and a write of this section — so the native port talks to the same storage
  /// instead of inventing a second home for the value.
  private static let agentDefaultModelNamespace = "agent-default-model"

  private let adapter: MobileGatewayHostAdapter
  private let configuration: MobileGatewayConfiguration
  /// The metadata-lane push closure. The plugin's query handlers broadcast nothing: every push
  /// (`session-queue`, `session-archives`, `tasks-updated`, …) is produced by the background
  /// stream listeners, which the service's pumps own. The closure is therefore held, not called,
  /// and it is also the routing rule those pumps must use — metadata frames skip conversation
  /// clients and ignore `filterSessionId`.
  private let broadcast: @Sendable (JSONValue) -> Void

  public init(
    adapter: MobileGatewayHostAdapter,
    configuration: MobileGatewayConfiguration,
    broadcast: @escaping @Sendable (JSONValue) -> Void
  ) {
    self.adapter = adapter
    self.configuration = configuration
    self.broadcast = broadcast
  }

  /// Handle one query verb. Returns the frame to send back, or `nil` when nothing should be sent.
  ///
  /// `nil` is reserved for a verb this router does not own, so a caller that already checked
  /// `verbs` can treat it as an internal inconsistency rather than a protocol answer.
  public func handle(_ message: JSONValue) async -> JSONValue? {
    guard let type = message["type"]?.stringValue, Self.verbs.contains(type) else { return nil }
    switch type {
    case "workspaces":
      return await proxy("workspaces") { try await self.adapter.listWorkspaces() }
    case "sessions":
      return await proxy("sessions") { try await self.adapter.listSessions() }
    case "history":
      return await historyVerb(message)
    case "attachment":
      return await attachmentVerb(message)
    case "search":
      return await searchVerb(message)
    case "host":
      return await proxy("host") { try await self.adapter.describeHost() }
    case "directories":
      return listServerDirectory(trimmedString(message["path"]))
    case "directory-create":
      return createServerDirectory(message)
    case "workspace-create":
      return await workspaceCreateVerb(message)
    case "session-create":
      return await sessionCreateVerb(message)
    case "models":
      return await modelsVerb(message)
    case "providers":
      return await proxy("providers") { try await self.adapter.providers() }
    case "default-model":
      return await defaultModelVerb()
    case "save-default-model":
      return await saveDefaultModelVerb(message)
    case "fork":
      return await forkVerb(message)
    case "session-cancel":
      return await sessionCancelVerb(message)
    case "queue-update":
      return await queueUpdateVerb(message)
    case "session-archive":
      return await sessionArchiveVerb(message)
    case "session-rename":
      return await sessionRenameVerb(message)
    case "commands":
      return await commandsVerb(message)
    case "command-execute":
      return await commandExecuteVerb(message)
    case "command-options":
      return await commandOptionsVerb(message)
    case "command-select":
      return await commandSelectVerb(message)
    case "select-model":
      return await selectModelVerb(message)
    case "permission-options":
      return await permissionOptionsVerb(message)
    case "permission":
      return await permissionVerb(message)
    case "context-usage", "session-stats":
      return await projectionVerb(message, type: type)
    case "tasks":
      return await sessionProjectionVerb(message, type: type, key: "todos")
    case "goal":
      return await sessionProjectionVerb(message, type: type, key: "goal")
    case "goal-edit":
      return await goalEditVerb(message)
    case "goal-pause", "goal-resume", "goal-clear":
      return await goalMutationVerb(message, type: type)
    case "agent-presets":
      return await proxy("agent-presets") { try await self.adapter.agentPresets() }
    case "session-agent-preset", "select-agent-preset":
      return await agentPresetVerb(message, type: type)
    case "defaults":
      return await defaultsVerb()
    case "set-default":
      return await setDefaultVerb(message)
    default:
      return nil
    }
  }
}

// MARK: - The `message` send path

extension MobileGatewayQueryRouter {
  /// One phone message end to end: validate, decode images, create a session when the phone did
  /// not name one, submit the prompt, answer `sent`.
  ///
  /// Errors on this path mostly carry **no** `requestType`: the plugin's `message` replies predate
  /// the lane split, and PROTOCOL.md documents the omission, so only the preset-conflict error
  /// names its type.
  public func admitMessage(_ message: JSONValue) async -> JSONValue? {
    // 1. A preset may only accompany a *new* session: an existing session's preset is fixed the
    //    moment its first prompt is admitted, and silently re-mounting one would change the agent
    //    under a running conversation.
    let preset = parseAgentPreset(message, requestType: "message", required: false)
    var presetValue: String?
    switch preset {
    case .failure(let frame):
      return frame
    case .success(let value):
      presetValue = value
    }
    if presetValue != nil, trimmedString(message["sessionId"]) != nil {
      return wireError(
        "bad-request",
        "use select-agent-preset before sending a message to an existing session",
        requestType: "message"
      )
    }

    // 2. Text is trimmed; a non-string becomes empty rather than an error, so a client that sends
    //    `text: null` with a valid image still works.
    let text = (message["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    // 3. Images.
    let images: [JSONValue]
    switch parseWireImages(message["images"], requestType: "message") {
    case .failure(let frame):
      return frame
    case .success(let parts):
      images = parts
    }

    // 4. An empty message is an error, and this frame has no `requestType`.
    if text.isEmpty, images.isEmpty {
      return wireError("bad-request", "message requires non-empty text or at least one image")
    }

    // 5. Mode is coerced, never rejected: anything but the exact string `steer` queues.
    let mode = message["mode"]?.stringValue == "steer" ? "steer" : "queue"

    var sessionID = trimmedString(message["sessionId"])
    do {
      if sessionID == nil {
        var createPayload: [String: JSONValue] = [:]
        if let presetValue { createPayload["agentPreset"] = .string(presetValue) }
        if let workspaceID = trimmedString(message["workspaceId"]) {
          createPayload["workspaceId"] = .string(workspaceID)
        }
        if let cwd = trimmedString(message["cwd"]) {
          // At most one placement, and the workspace id wins: the host create contract rejects
          // both, and a phone that sent both meant the workspace.
          if createPayload["workspaceId"] == nil { createPayload["cwd"] = .string(cwd) }
        }
        let created = try await adapter.createSession(.object(createPayload))
        sessionID = created["sessionId"]?.stringValue
      }

      // Content ordering is normative: image blocks first, then one optional text block.
      var content = images
      if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
      var prompt: [String: JSONValue] = [
        "mode": .string(mode),
        "content": .array(content),
      ]
      if let sessionID { prompt["sessionId"] = .string(sessionID) }
      if let timeZone = trimmedString(message["clientTimeZone"]) {
        prompt["clientTimeZone"] = .string(timeZone)
      }
      let response = try await adapter.prompt(.object(prompt))
      return JSONValue.object([
        ("kind", .string("sent")),
        ("sessionId", sessionID.map { JSONValue.string($0) }),
        ("mode", .string(mode)),
        ("command", response["command"]),
      ])
    } catch {
      // `sessionId` is echoed when one was resolved — including an auto-created one — so the phone
      // can attach the failure to the bubble it just drew.
      let mapped = MobileGatewayHostError(error: error)
      return wireError(mapped.code, mapped.message, sessionID: sessionID)
    }
  }
}

// MARK: - Session queries

private extension MobileGatewayQueryRouter {
  /// `history` with the plugin's byte capping. The client pages backwards with `nextBeforeSeq`, so
  /// a page must always fit the WebSocket frame limit while still making progress.
  func historyVerb(_ message: JSONValue) async -> JSONValue {
    guard let sessionID = trimmedString(message["sessionId"]) else {
      return wireError("bad-request", "history requires a sessionId", requestType: "history")
    }
    if let cursorError = validateHistoryCursor(message, sessionID: sessionID, field: "beforeSeq") {
      return cursorError
    }
    var payload: [String: JSONValue] = ["sessionId": .string(sessionID)]
    // The payload copy is looser than the cursor validator on purpose (mirrors the plugin): by the
    // time we get here a non-integer or negative `beforeSeq` is already gone.
    if let beforeSeq = finiteNumber(message["beforeSeq"]) { payload["beforeSeq"] = .number(beforeSeq) }
    if let maxMessages = finiteNumber(message["maxMessages"]) {
      payload["maxMessages"] = .number(maxMessages)
    }
    let frame = await proxy("history") { try await self.adapter.history(.object(payload)) }
    guard frame["kind"]?.stringValue == "history" else { return frame }
    return Self.historyPage(frame, message: message, sessionID: sessionID)
  }

  /// `{ ...hostValue, kind: 'history', sessionId, events, bytes, hasMore, view?, nextBeforeSeq? }`.
  static func historyPage(_ value: JSONValue, message: JSONValue, sessionID: String) -> JSONValue {
    // The host delivers `{ event }` envelopes; only the inner event is part of the wire contract.
    let rawEvents = (value["events"]?.arrayValue ?? []).map { $0["event"] ?? $0 }
    let maxBytes = safeInteger(message["maxBytes"]).flatMap { $0 > 0 ? Int($0) : nil }
      ?? historyDefaultMaxBytes
    let trim = message["view"]?.stringValue == "conversation"
    let capped = capHistoryEvents(rawEvents, maxBytes: maxBytes, trim: trim)
    let hasMore = value["hasMore"]?.boolValue == true || capped.dropped > 0
    // An all-hidden page still needs a cursor, so the oldest raw event is the fallback.
    let oldest = capped.events.first?["seq"] ?? rawEvents.first?["seq"]

    var fields: [String: JSONValue]
    if case .object(let hostFields) = value { fields = hostFields } else { fields = [:] }
    fields["kind"] = .string("history")
    fields["sessionId"] = .string(sessionID)
    fields["events"] = .array(capped.events)
    fields["bytes"] = .number(Double(capped.bytes))
    fields["hasMore"] = .bool(hasMore)
    if trim { fields["view"] = .string("conversation") }
    if hasMore, let oldest, !oldest.isNull { fields["nextBeforeSeq"] = oldest }
    return .object(fields)
  }

  /// Keep the newest suffix within `maxBytes`; the newest event is always kept, because an event
  /// cannot be split and a page that drops it makes no forward progress.
  static func capHistoryEvents(
    _ events: [JSONValue],
    maxBytes: Int,
    trim: Bool
  ) -> (events: [JSONValue], bytes: Int, dropped: Int) {
    let processed = trim ? events.compactMap { trimConversationEvent($0) } : events
    guard !processed.isEmpty else { return ([], 0, 0) }
    var total = 0
    var keptStart = processed.count
    var index = processed.count - 1
    while index >= 0 {
      let size = eventBytes(processed[index])
      if keptStart == processed.count {
        total = size
        keptStart = index
        index -= 1
        continue
      }
      if total + size > maxBytes { break }
      total += size
      keptStart = index
      index -= 1
    }
    return (Array(processed[keptStart...]), total, keptStart)
  }

  /// Conversation view drops what the chat page never renders: token-level chunks and
  /// system-prompt headers, the streaming scratch space, and oversized tool-result text.
  static func trimConversationEvent(_ event: JSONValue) -> JSONValue? {
    switch event["type"]?.stringValue {
    case "assistant/chunk", "request/header", "request/context", "system/message":
      return nil
    case "assistant/message", "assistant/attempt":
      var data = event["data"]?.objectValue ?? [:]
      data.removeValue(forKey: "stream")
      return event.merging(["data": .object(data)])
    case "tool/result":
      guard var data = event["data"]?.objectValue,
            let message = data["message"],
            var messageFields = message.objectValue,
            let content = messageFields["content"]?.arrayValue else { return event }
      var changed = false
      let truncated = content.map { truncateTextBlocks($0, changed: &changed) }
      guard changed else { return event }
      messageFields["content"] = .array(truncated)
      data["message"] = .object(messageFields)
      return event.merging(["data": .object(data)])
    default:
      return event
    }
  }

  /// Recursive so a text block nested under `block.content` is shortened too.
  static func truncateTextBlocks(_ block: JSONValue, changed: inout Bool) -> JSONValue {
    guard case .object(var fields) = block else { return block }
    if fields["type"]?.stringValue == "text", let text = fields["text"]?.stringValue {
      // `String.length` in the plugin counts UTF-16 units; matching that keeps the byte budget
      // identical for astral-plane text instead of cutting at a grapheme boundary.
      let units = Array(text.utf16)
      if units.count > historyToolResultMaxChars {
        changed = true
        fields["text"] = .string(String(decoding: units.prefix(historyToolResultMaxChars), as: UTF16.self) + "…")
        return .object(fields)
      }
    }
    if let content = fields["content"]?.arrayValue {
      fields["content"] = .array(content.map { truncateTextBlocks($0, changed: &changed) })
      return .object(fields)
    }
    return block
  }

  /// `JSON.stringify(event)` byte length. The project's compact serializer is used rather than a
  /// second encoder so the number the client sees matches the frame it is budgeting for.
  static func eventBytes(_ event: JSONValue) -> Int {
    (try? event.serialized())?.utf8.count ?? 0
  }

  /// `attachment` re-reads nothing: the host is the only authority on whether this session's
  /// history actually referenced the attachment.
  func attachmentVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    guard let attachmentID = trimmedString(message["attachmentId"]) else {
      return wireError(
        "bad-request",
        "attachment requires an attachmentId",
        requestType: "attachment",
        sessionID: sessionID
      )
    }
    let frame = await proxy("attachment") {
      try await self.adapter.attachment(sessionID: sessionID, attachmentID: attachmentID)
    }
    guard frame["kind"]?.stringValue == "attachment" else { return frame }
    // The response is keyed by the trimmed session id, not by whatever the client sent.
    return frame.merging(["sessionId": .string(sessionID)])
  }

  func searchVerb(_ message: JSONValue) async -> JSONValue {
    guard let query = trimmedString(message["query"]) else {
      return wireError("bad-request", "search requires a query", requestType: "search")
    }
    return await proxy("search") { try await self.adapter.search(query) }
  }

  func modelsVerb(_ message: JSONValue) async -> JSONValue {
    // A session id switches the host path: the per-session catalog adds `current` and `routable`
    // on top of the global groups, which is what the input menu needs.
    if let sessionID = trimmedString(message["sessionId"]) {
      return await proxy("models") { try await self.adapter.sessionModels(sessionID: sessionID) }
    }
    return await proxy("models") { try await self.adapter.models() }
  }
}

// MARK: - Workspaces, sessions and directories

private extension MobileGatewayQueryRouter {
  func workspaceCreateVerb(_ message: JSONValue) async -> JSONValue {
    guard let path = trimmedString(message["path"]) else {
      return wireError("bad-request", "workspace-create requires a path", requestType: "workspace-create")
    }
    // No absolute-path check here: the host validates and answers `workspace-invalid-path`, and
    // duplicating the rule on this side is how the two drift apart.
    return await proxy("workspace-create") { try await self.adapter.createWorkspace(path: path) }
  }

  func sessionCreateVerb(_ message: JSONValue) async -> JSONValue {
    guard let requestID = message["requestId"]?.stringValue,
          !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return wireError("bad-request", "session-create requires a requestId", requestType: "session-create")
    }
    let preset = parseAgentPreset(message, requestType: "session-create", required: false)
    switch preset {
    case .failure(let frame):
      // The bad `requestId` itself is not echoed, but a valid one is: the phone matches replies to
      // optimistic rows by it, and the untrimmed value is what it sent.
      return frame.merging(["requestId": .string(requestID)])
    case .success:
      break
    }
    var payload: [String: JSONValue] = [:]
    if case .success(let value) = preset, let value { payload["agentPreset"] = .string(value) }
    if let workspaceID = trimmedString(message["workspaceId"]) {
      payload["workspaceId"] = .string(workspaceID)
    } else if let cwd = trimmedString(message["cwd"]) {
      payload["cwd"] = .string(cwd)
    }
    // The type label is `session-created`, so a success frame answers `kind: 'session-created'`
    // while a failure is rewritten to name the request the phone sent.
    let frame = await proxy("session-created") { try await self.adapter.createSession(.object(payload)) }
    if frame["kind"]?.stringValue == "error" {
      return frame.merging([
        "requestType": .string("session-create"),
        "requestId": .string(requestID),
      ])
    }
    return frame.merging(["requestId": .string(requestID)])
  }

  /// One directory level, answered locally.
  ///
  /// This is deliberately *not* a host RPC: the plugin lists the gateway process's own filesystem
  /// because the picker capability would otherwise gate browsing behind a composed `browse`
  /// service that several deployments never mount.
  func listServerDirectory(_ target: String?) -> JSONValue {
    do {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      let requested = target.map(resolvePath) ?? home

      // Root -> leaf breadcrumbs, so the phone can render a path bar without walking parents.
      var crumbs: [JSONValue] = []
      var cursor = requested
      while true {
        let name = cursor == "/" ? cursor : (cursor as NSString).lastPathComponent
        crumbs.append(JSONValue.object([
          ("name", .string(name)),
          ("path", .string(cursor)),
          ("hidden", .bool(false)),
        ]))
        let parent = (cursor as NSString).deletingLastPathComponent
        if parent == cursor { break }
        cursor = parent
      }
      crumbs.reverse()

      // Directories *and* symlinks: a symlinked project directory is a normal thing to open, and
      // the plugin's `readdir` check keeps it for the same reason.
      let urls = try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: requested),
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: []
      )
      var entries: [JSONValue] = []
      for url in urls {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true || values.isSymbolicLink == true else { continue }
        let name = url.lastPathComponent
        entries.append(JSONValue.object([
          ("name", .string(name)),
          ("path", .string(joinPath(requested, name))),
          ("hidden", .bool(name.hasPrefix("."))),
        ]))
      }
      entries.sort { ($0["name"]?.stringValue ?? "").localizedCompare($1["name"]?.stringValue ?? "") == .orderedAscending }
      return JSONValue.object([
        ("kind", .string("directories")),
        ("path", .string(requested)),
        ("home", .string(home)),
        ("crumbs", .array(crumbs)),
        ("entries", .array(entries)),
        // The plugin never truncates; the field exists so the client's paging UI has one shape.
        ("truncated", .bool(false)),
      ])
    } catch {
      // ENOENT, EACCES, ENOTDIR and friends all land here with the system's own message.
      let message = (error as NSError).localizedDescription
      return wireError("directory-unreadable", message, requestType: "directories")
    }
  }

  /// Create exactly one child directory. `mkdir` is non-recursive on purpose — a phone asking for
  /// a folder means that folder, and silently creating a tree is how typos become directories.
  func createServerDirectory(_ message: JSONValue) -> JSONValue {
    guard let rawPath = message["path"]?.stringValue, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return directoryCreateError("bad-request", "directory-create requires an absolute parent path")
    }
    let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedPath.hasPrefix("/") else {
      return directoryCreateError("bad-request", "directory-create path must be absolute")
    }
    guard let rawName = message["name"]?.stringValue else {
      return directoryCreateError("bad-request", "directory-create requires a folder name")
    }
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
      return directoryCreateError("bad-request", "directory-create name must be a single non-empty folder name")
    }

    let parent = resolvePath(trimmedPath)
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: parent)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        return directoryCreateError("directory-create-failed", "parent path is not a directory")
      }
    } catch {
      return directoryCreateError("directory-create-failed", (error as NSError).localizedDescription)
    }

    let target = joinPath(parent, name)
    do {
      try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
      return .object(["kind": .string("directory-create"), "path": .string(target)])
    } catch {
      let failure = error as NSError
      if failure.domain == NSCocoaErrorDomain, failure.code == NSFileWriteFileExistsError {
        return directoryCreateError("directory-exists", "directory already exists")
      }
      return directoryCreateError("directory-create-failed", failure.localizedDescription)
    }
  }

  func directoryCreateError(_ code: String, _ message: String) -> JSONValue {
    wireError(code, message, requestType: "directory-create")
  }
}

// MARK: - Default model

private extension MobileGatewayQueryRouter {
  /// The default selection new sessions start from.
  ///
  /// The plugin reads it from the injected `agentDefaultModel` service. Natively the same value is
  /// the host's `agent-default-model` settings section; when a deployment mounts no settings
  /// provider the service would fall back to its composition entry, whose closest observable
  /// equivalent is the model catalog's own `default`.
  func defaultModelVerb() async -> JSONValue {
    do {
      let described = try await adapter.settingsDescribe()
      if let section = Self.settingSection(described, namespace: Self.agentDefaultModelNamespace) {
        return .object(["kind": .string("default-model"), "selection": section])
      }
      let catalog = try await adapter.modelCatalog()
      return JSONValue.object([
        ("kind", .string("default-model")),
        ("selection", catalog["default"]),
      ])
    } catch {
      return hostError(error, requestType: "default-model")
    }
  }

  func saveDefaultModelVerb(_ message: JSONValue) async -> JSONValue {
    guard let provider = trimmedString(message["provider"]), let model = trimmedString(message["model"]) else {
      return wireError(
        "bad-request",
        "save-default-model requires provider and model",
        requestType: "save-default-model"
      )
    }
    var selection: [String: JSONValue] = ["provider": .string(provider), "model": .string(model)]
    if let effort = trimmedString(message["reasoningEffort"]) {
      selection["reasoningEffort"] = .string(effort)
    }
    do {
      // The plugin's `saveSelection` replaces the whole section; this section's schema is exactly
      // the three keys below, so patching all of them is the same write.
      _ = try await adapter.settingsUpdate(namespace: Self.agentDefaultModelNamespace, patch: .object(selection))
      return .object(["kind": .string("save-default-model"), "saved": .object(selection)])
    } catch {
      // This path reports `internal` regardless of the host code, matching the plugin.
      return wireError(
        "internal",
        MobileGatewayHostError(error: error).message,
        requestType: "save-default-model"
      )
    }
  }

  /// The `value` of one `settings/describe` namespace, when the host reported one.
  static func settingSection(_ described: JSONValue, namespace: String) -> JSONValue? {
    guard let namespaces = described["namespaces"]?.arrayValue else { return nil }
    for entry in namespaces where entry["ns"]?.stringValue == namespace {
      guard let value = entry["value"], case .object = value else { return nil }
      return value
    }
    return nil
  }
}

// MARK: - Fork, cancel, queue, archive, rename

private extension MobileGatewayQueryRouter {
  func forkVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    // Session first, cursor second: a missing session is the more useful error.
    if let cursorError = validateHistoryCursor(message, sessionID: sessionID, field: "atSeq") {
      return cursorError
    }
    var payload: [String: JSONValue] = ["sessionId": .string(sessionID)]
    if let atSeq = finiteNumber(message["atSeq"]) {
      payload["atSeq"] = .number(atSeq.rounded(.down))
    }
    return await proxy("fork") { try await self.adapter.fork(.object(payload)) }
  }

  func sessionCancelVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    let frame = await proxy("session-cancel") { try await self.adapter.cancel(sessionID: sessionID) }
    if frame["kind"]?.stringValue == "error" {
      return frame.merging(["sessionId": .string(sessionID)])
    }
    // The host's own kind is overwritten so the client sees one vocabulary.
    return frame.merging(["kind": .string("session-cancelled"), "sessionId": .string(sessionID)])
  }

  /// Queue control is expressed here, never as separate verbs: `edit` replaces the text, `remove`
  /// deletes a pending item, `steer` moves an item still `queued` into the current turn.
  ///
  /// The reply is only an acknowledgement. The authoritative queue arrives as a `session-queue`
  /// push from the host's control stream, which may land before or after this frame.
  func queueUpdateVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    let itemID = trimmedString(message["itemId"])
    let actionKind = trimmedString(message["action"]) ?? ""
    guard let itemID, ["edit", "remove", "steer"].contains(actionKind) else {
      return wireError(
        "bad-request",
        "queue-update requires itemId and action edit, remove, or steer",
        requestType: "queue-update",
        sessionID: sessionID
      )
    }
    let action: JSONValue
    if actionKind == "edit" {
      // The trim above is only a gate: the host receives the client's text verbatim.
      guard let text = message["text"]?.stringValue,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return wireError(
          "bad-request",
          "queue-update edit requires non-empty text",
          requestType: "queue-update",
          sessionID: sessionID,
          itemID: itemID
        )
      }
      action = .object([
        "kind": .string("edit"),
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
      ])
    } else {
      action = .object(["kind": .string(actionKind)])
    }
    let payload = JSONValue.object([
      ("sessionId", .string(sessionID)),
      ("itemId", .string(itemID)),
      ("action", action),
    ])
    let frame = await proxy("queue-update") { try await self.adapter.updateQueue(payload) }
    if frame["kind"]?.stringValue == "error" {
      return frame.merging(["sessionId": .string(sessionID), "itemId": .string(itemID)])
    }
    return frame.merging([
      "kind": .string("queue-item-updated"),
      "sessionId": .string(sessionID),
      "itemId": .string(itemID),
      "action": .string(actionKind),
    ])
  }

  func sessionArchiveVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    // The verb is "archive"; the adapter's `archived` flag exists for the host's symmetric API.
    let frame = await proxy("session-archive") {
      try await self.adapter.archiveSession(sessionID: sessionID, archived: true)
    }
    if frame["kind"]?.stringValue == "error" {
      return frame.merging(["sessionId": .string(sessionID)])
    }
    return frame.merging(["kind": .string("session-archived"), "sessionId": .string(sessionID)])
  }

  func sessionRenameVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    guard let title = message["title"]?.stringValue,
          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return wireError(
        "bad-request",
        "session-rename requires a non-empty title",
        requestType: "session-rename",
        sessionID: sessionID
      )
    }
    let frame = await proxy("session-rename") {
      try await self.adapter.rename(sessionID: sessionID, title: title)
    }
    if frame["kind"]?.stringValue == "error" {
      return frame.merging(["sessionId": .string(sessionID)])
    }
    return frame.merging(["kind": .string("session-renamed"), "sessionId": .string(sessionID)])
  }
}

// MARK: - Agent presets, defaults

private extension MobileGatewayQueryRouter {
  /// `session-agent-preset` (read) and `select-agent-preset` (write) share one shape: a session id
  /// error outranks a preset error, and `requestId` is echoed only when it was a string.
  func agentPresetVerb(_ message: JSONValue, type: String) async -> JSONValue {
    let session = requireSessionID(message)
    let preset = parseAgentPreset(message, requestType: type, required: type == "select-agent-preset")
    var requestID: [String: JSONValue] = [:]
    if let raw = message["requestId"]?.stringValue { requestID["requestId"] = .string(raw) }

    if case .failure(let frame) = session { return frame.merging(requestID) }
    if case .failure(let frame) = preset { return frame.merging(requestID) }
    guard case .success(let sessionID) = session else { return nil }

    let frame: JSONValue
    if type == "session-agent-preset" {
      // A read: the host snapshot decides `locked`, and the adapter's admitted-prompt marker makes
      // the answer true from the instant a prompt was accepted, before `turn/start` lands.
      frame = await proxy(type) { try await self.adapter.agentPresetState(sessionID: sessionID) }
    } else {
      guard case .success(let presetValue) = preset, let presetValue else {
        return wireError(
          "bad-request",
          "agentPreset must be a non-empty preset ID",
          requestType: type
        ).merging(requestID)
      }
      frame = await proxy(type) {
        try await self.adapter.selectAgentPreset(sessionID: sessionID, preset: presetValue)
      }
    }
    return frame.merging(["sessionId": .string(sessionID)]).merging(requestID)
  }

  /// `defaults` is a view, not a payload: only the two default keys are exposed, and the raw
  /// settings namespaces never cross the wire.
  func defaultsVerb() async -> JSONValue {
    let frame = await proxy("defaults") { try await self.adapter.settingsDescribe() }
    guard frame["kind"]?.stringValue == "defaults" else { return frame }
    let namespaces = frame["namespaces"]?.arrayValue ?? []
    let agentPresetNs = namespaces.first { $0["ns"]?.stringValue == "agent-presets" }
    let permissionNs = namespaces.first { $0["ns"]?.stringValue == "permission" }
    return JSONValue.object([
      ("kind", .string("defaults")),
      // Note the asymmetric keys: the agent-presets section stores `default`, the permission
      // section stores `defaultPreset`.
      ("agentPresetDefault", agentPresetNs?["value"]?["default"] ?? .null),
      ("permissionDefault", permissionNs?["value"]?["defaultPreset"] ?? .null),
    ])
  }

  func setDefaultVerb(_ message: JSONValue) async -> JSONValue {
    let target = trimmedString(message["target"])
    let value = trimmedString(message["value"])
    guard let target, target == "agent-preset" || target == "permission" else {
      return wireError(
        "bad-request",
        "set-default target must be \"agent-preset\" or \"permission\"",
        requestType: "set-default"
      )
    }
    guard let value else {
      return wireError("bad-request", "set-default requires a value", requestType: "set-default")
    }
    let namespace = target == "agent-preset" ? "agent-presets" : "permission"
    let patch: JSONValue = target == "agent-preset"
      ? .object(["default": .string(value)])
      : .object(["defaultPreset": .string(value)])
    let updated = await proxy("set-default") {
      try await self.adapter.settingsUpdate(namespace: namespace, patch: patch)
    }
    guard updated["kind"]?.stringValue == "set-default" else { return updated }
    return JSONValue.object([
      ("kind", .string("set-default")),
      ("target", .string(target)),
      ("value", .string(value)),
      ("applied", .bool(true)),
      // The nested frame keeps the host's fields; the phone shows them in a diagnostics sheet.
      ("namespace", updated),
    ])
  }
}

// MARK: - Commands and the input menu

private extension MobileGatewayQueryRouter {
  /// The input-menu catalog: host commands, the client-side `/model` entry, and the skill group.
  func commandsVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    let copy = Self.catalogCopy(for: message["locale"])
    do {
      let catalog = try await adapter.commands(sessionID: sessionID)
      guard let parsed = Self.commandCatalog(catalog) else {
        return wireError(
          "internal",
          "commands/list returned an invalid catalog",
          requestType: "commands",
          sessionID: sessionID
        )
      }
      var commands = parsed.commands.compactMap { Self.commandDescriptor($0, copy: copy) }
      if !commands.contains(where: { $0["name"]?.stringValue == "model" }) {
        // The official WebUI contributes `/model` client-side; the phone gets the equivalent entry
        // so both menus render the same list.
        commands.append(JSONValue.object([
          ("id", .string("command:model")),
          ("name", .string("model")),
          ("description", .string(copy.modelDescription)),
          ("source", .string("client")),
          ("action", .string("select-model")),
          ("ui", Self.commandUIDescriptor(name: "model", command: .object([:]), copy: copy)),
        ]))
      }
      let skills = parsed.skills.compactMap { Self.skillDescriptor($0, copy: copy) }
      var groups: [JSONValue] = [
        JSONValue.object([
          ("id", .string("commands")),
          ("title", .string(copy.commandsTitle)),
          ("items", .array(commands)),
        ]),
      ]
      if !skills.isEmpty {
        groups.append(JSONValue.object([
          ("id", .string("skills")),
          ("title", .string(copy.skillsTitle)),
          ("items", .array(skills)),
        ]))
      }
      // `warnings` is deliberately absent: the plugin emits it when the skills frame failed but the
      // command frame succeeded, and the native adapter folds both catalogs into a single call, so a
      // failure here fails the whole verb instead of degrading to a partial catalog.
      return JSONValue.object([
        ("kind", .string("commands")),
        ("sessionId", .string(sessionID)),
        ("locale", .string(copy.locale)),
        ("groups", .array(groups)),
      ])
    } catch {
      return hostError(error, requestType: "commands", sessionID: sessionID)
    }
  }

  /// The host catalog, as either an array of command descriptors or an object carrying `commands`
  /// and/or `skills`. The adapter prefers the modern skills catalog with `commands/list` as the
  /// fallback, so the router accepts both shapes rather than assuming one host generation.
  static func commandCatalog(_ value: JSONValue) -> (commands: [JSONValue], skills: [JSONValue])? {
    if let items = value.arrayValue { return (items, []) }
    guard case .object = value else { return nil }
    let commands = value["commands"]?.arrayValue
    let skills = value["skills"]?.arrayValue
    guard commands != nil || skills != nil else { return nil }
    return (commands ?? [], skills ?? [])
  }

  static func commandDescriptor(_ command: JSONValue, copy: CommandCatalogCopy) -> JSONValue? {
    guard let name = command["name"]?.stringValue,
          let description = command["description"]?.stringValue else { return nil }
    var fields: [String: JSONValue] = [
      "id": .string("command:\(name)"),
      "name": .string(name),
      "description": .string(description),
      "source": .string("host"),
      "action": .string("execute"),
      "ui": commandUIDescriptor(name: name, command: command, copy: copy),
    ]
    if let hint = command["input"]?["hint"]?.stringValue {
      fields["input"] = JSONValue.object([
        ("hint", .string(hint)),
        ("images", commandAcceptsAttachments(command) ? .bool(true) : nil),
      ])
    }
    return .object(fields)
  }

  static func skillDescriptor(_ skill: JSONValue, copy: CommandCatalogCopy) -> JSONValue? {
    guard let name = skill["name"]?.stringValue,
          let description = skill["description"]?.stringValue else { return nil }
    let modelInvocable = skill["modelInvocable"]?.boolValue == true
    return JSONValue.object([
      ("id", .string("skill:\(name)")),
      ("name", .string(name)),
      // A user-only skill is marked in the description the client renders; the client must not
      // branch on the name, so the marker travels with the copy.
      ("description", .string(modelInvocable ? description : "\(copy.userOnly) · \(description)")),
      ("source", .string("skill")),
      ("action", .string("insert")),
      ("modelInvocable", .bool(modelInvocable)),
      ("whenToUse", skill["whenToUse"]?.stringValue.flatMap { $0.isEmpty ? nil : .string($0) }),
      ("ui", JSONValue.object([
        ("kind", .string("input")),
        ("insertText", .string("/\(name) ")),
        ("images", .bool(true)),
        ("submitRequest", .string("message")),
      ])),
    ])
  }

  /// Precedence matters: the two overridden names render a submenu, a hint makes the entry accept
  /// typed input, and everything else submits immediately.
  static func commandUIDescriptor(name: String, command: JSONValue, copy: CommandCatalogCopy) -> JSONValue {
    if name == "permission" || name == "model" {
      // No trailing space: selecting opens a submenu rather than starting an argument.
      return JSONValue.object([
        ("kind", .string("select")),
        ("optionsRequest", .string("command-options")),
        ("selectionRequest", .string("command-select")),
        ("insertText", .string("/\(name)")),
      ])
    }
    if let hint = command["input"]?["hint"]?.stringValue {
      return JSONValue.object([
        ("kind", .string("input")),
        ("insertText", .string("/\(name) ")),
        ("hint", .string(hint)),
        ("displayHint", copy.hints[name].map { JSONValue.string($0) }),
        ("images", .bool(commandAcceptsAttachments(command))),
        ("submitRequest", .string("command-execute")),
      ])
    }
    return JSONValue.object([
      ("kind", .string("immediate")),
      ("submitRequest", .string("command-execute")),
      ("submitText", .string("/\(name)")),
    ])
  }

  /// Only `input.attachments === true` (strictly) permits images on a command.
  static func commandAcceptsAttachments(_ command: JSONValue) -> Bool {
    command["input"]?["attachments"]?.boolValue == true
  }

  static func catalogCopy(for locale: JSONValue?) -> CommandCatalogCopy {
    // A missing locale is Chinese: the plugin's default, and the gateway's primary audience.
    guard let text = locale?.stringValue, !text.lowercased().hasPrefix("zh") else { return .zh }
    return .en
  }

  /// `command-execute`: run one slash line through the host command registry.
  func commandExecuteVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    let line = (message["line"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let name = Self.commandName(of: line) else {
      return wireError(
        "bad-request",
        "command-execute requires a slash-prefixed line",
        requestType: "command-execute",
        sessionID: sessionID
      )
    }
    let images: [JSONValue]
    switch parseWireImages(message["images"], requestType: "command-execute") {
    case .failure(let frame):
      return frame.merging(["sessionId": .string(sessionID)])
    case .success(let parts):
      images = parts
    }
    do {
      let catalog = try await adapter.commands(sessionID: sessionID)
      guard let parsed = Self.commandCatalog(catalog) else {
        return wireError(
          "internal",
          "commands/list returned an invalid catalog",
          requestType: "command-execute",
          sessionID: sessionID
        )
      }
      // Skills are matched too: the adapter exposes one catalog, and the host resolves the line it
      // is given, so refusing a name that the menu just offered would be a worse failure.
      let descriptors = parsed.commands + parsed.skills
      guard let descriptor = descriptors.first(where: { $0["name"]?.stringValue == name }) else {
        return wireError(
          "unknown-command",
          "command not found: /\(name)",
          requestType: "command-execute",
          sessionID: sessionID
        )
      }
      if !images.isEmpty, !Self.commandAcceptsAttachments(descriptor) {
        return wireError(
          "bad-request",
          "/\(name) does not accept image attachments",
          requestType: "command-execute",
          sessionID: sessionID
        )
      }
      return await executeHostCommand(sessionID: sessionID, line: line, images: images, requestType: "command-execute")
    } catch {
      return hostError(error, requestType: "command-execute", sessionID: sessionID)
    }
  }

  /// `null` from the host means the line never matched a command, which is a different failure from
  /// the command running and reporting `result.kind == 'error'`.
  func executeHostCommand(
    sessionID: String,
    line: String,
    images: [JSONValue],
    requestType: String
  ) async -> JSONValue {
    do {
      let execution = try await adapter.executeCommand(sessionID: sessionID, line: line, attachments: images)
      if execution.isNull {
        return wireError(
          "unknown-command",
          "unknown or malformed command: \(line)",
          requestType: requestType,
          sessionID: sessionID
        )
      }
      return JSONValue.object([
        ("kind", .string("command-executed")),
        ("sessionId", .string(sessionID)),
        ("line", .string(line)),
        ("commandId", execution["commandId"]),
        ("result", execution["result"]),
      ])
    } catch {
      return hostError(error, requestType: requestType, sessionID: sessionID)
    }
  }

  /// `/compact now` -> `compact`, `/compact` -> `compact`, `//x` -> `/x`, `x` -> none.
  static func commandName(of line: String) -> String? {
    guard line.hasPrefix("/") else { return nil }
    let body = line.dropFirst()
    let end = body.firstIndex(where: { $0.isWhitespace }) ?? body.endIndex
    let name = String(body[body.startIndex..<end])
    return name.isEmpty ? nil : name
  }

  func commandOptionsVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    guard let command = trimmedString(message["command"]) else {
      return wireError(
        "bad-request",
        "command-options requires a command",
        requestType: "command-options",
        sessionID: sessionID
      )
    }
    return await loadCommandOptions(command: command, sessionID: sessionID)
  }

  /// Only `model` and `permission` have selectable options; every other name is a client bug, not a
  /// host error, so it is answered here.
  func loadCommandOptions(command: String, sessionID: String) async -> JSONValue {
    if command == "model" {
      let frame = await proxy("models") { try await self.adapter.sessionModels(sessionID: sessionID) }
      guard frame["kind"]?.stringValue == "models" else { return frame }
      var options: [JSONValue] = []
      for group in frame["groups"]?.arrayValue ?? [] {
        for model in group["models"]?.arrayValue ?? [] {
          let selected = jsStrictEqual(frame.path("current.provider"), group["id"])
            && jsStrictEqual(frame.path("current.model"), model["id"])
          options.append(JSONValue.object([
            ("id", .string(Self.modelCommandOptionID(provider: group["id"], model: model["id"]))),
            ("label", .string(wireText(firstTruthy(model["name"], model["id"])))),
            // Always present for a model option: the menu groups by provider.
            ("detail", .string(wireText(firstTruthy(group["name"], group["id"])))),
            ("description", model["description"].flatMap { isTruthy($0) ? .string(wireText($0)) : nil }),
            ("selected", .bool(selected)),
          ]))
        }
      }
      return JSONValue.object([
        ("kind", .string("command-options")),
        ("sessionId", .string(sessionID)),
        ("command", .string(command)),
        ("options", .array(options)),
      ])
    }
    if command == "permission" {
      switch await permissionCandidates(sessionID: sessionID) {
      case .failure(let frame):
        return frame
      case .success(let candidates):
        return JSONValue.object([
          ("kind", .string("command-options")),
          ("sessionId", .string(sessionID)),
          ("command", .string(command)),
          ("options", .array(candidates)),
        ])
      }
    }
    return wireError(
      "bad-request",
      "command does not provide selectable options: \(command)",
      requestType: "command-options",
      sessionID: sessionID
    )
  }

  func commandSelectVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    // `optionId` is opaque and deliberately not trimmed: it is a base64url token.
    guard let command = trimmedString(message["command"]),
          let optionID = message["optionId"]?.stringValue, !optionID.isEmpty else {
      return wireError(
        "bad-request",
        "command-select requires command and optionId",
        requestType: "command-select",
        sessionID: sessionID
      )
    }
    return await selectCommandOption(command: command, sessionID: sessionID, optionID: optionID)
  }

  func selectCommandOption(command: String, sessionID: String, optionID: String) async -> JSONValue {
    // The catalog is re-loaded rather than trusted from the client: an option id is only valid for
    // the state the host is in right now.
    let catalog = await loadCommandOptions(command: command, sessionID: sessionID)
    guard catalog["kind"]?.stringValue == "command-options" else { return catalog }
    guard let option = catalog["options"]?.arrayValue?.first(where: { $0["id"]?.stringValue == optionID }) else {
      return wireError(
        "bad-request",
        "unknown option for \(command): \(optionID)",
        requestType: "command-select",
        sessionID: sessionID
      )
    }

    if command == "permission" {
      do {
        // The permission command takes no attachments; the host descriptor requires the field, so
        // an empty array is sent explicitly.
        let execution = try await adapter.executeCommand(
          sessionID: sessionID,
          line: "/permission " + optionID,
          attachments: []
        )
        guard !execution.isNull, let result = execution["result"], !result.isNull else {
          throw MobileGatewayHostError(code: "internal", message: "permission command returned an invalid result")
        }
        if result["kind"]?.stringValue == "error" {
          return wireError(
            "command-error",
            result["text"]?.stringValue ?? "",
            requestType: "command-select",
            sessionID: sessionID
          )
        }
        return JSONValue.object([
          ("kind", .string("command-selected")),
          ("sessionId", .string(sessionID)),
          ("command", .string(command)),
          ("selected", option.merging(["selected": .bool(true)])),
        ])
      } catch {
        return hostError(error, requestType: "command-select", sessionID: sessionID)
      }
    }

    if command == "model" {
      guard let selection = Self.decodeModelCommandOptionID(optionID) else {
        return wireError(
          "bad-request",
          "invalid model option id",
          requestType: "command-select",
          sessionID: sessionID
        )
      }
      let models = await proxy("models") { try await self.adapter.sessionModels(sessionID: sessionID) }
      guard models["kind"]?.stringValue == "models" else { return models }
      guard let group = models["groups"]?.arrayValue?.first(where: { $0["id"]?.stringValue == selection.provider }),
            let model = group["models"]?.arrayValue?.first(where: { $0["id"]?.stringValue == selection.model }) else {
        return wireError(
          "bad-request",
          "model option is no longer available",
          requestType: "command-select",
          sessionID: sessionID
        )
      }
      var payload: [String: JSONValue] = [
        "sessionId": .string(sessionID),
        "provider": .string(selection.provider),
        "model": .string(selection.model),
      ]
      // Keep the effort the session already uses; otherwise take the model's default. Absent means
      // "let the provider decide".
      let currentMatches = jsStrictEqual(models.path("current.provider"), .string(selection.provider))
        && jsStrictEqual(models.path("current.model"), .string(selection.model))
      let effort = currentMatches
        ? models.path("current.reasoningEffort")?.stringValue
        : model.path("reasoning.defaultEffort")?.stringValue
      if let effort, !effort.isEmpty { payload["reasoningEffort"] = .string(effort) }

      let selected = await proxy("select-model") { try await self.adapter.selectModel(.object(payload)) }
      guard selected["kind"]?.stringValue == "select-model" else { return selected }
      return JSONValue.object([
        ("kind", .string("command-selected")),
        ("sessionId", .string(sessionID)),
        ("command", .string(command)),
        ("selected", option.merging(["selected": .bool(true)])),
        ("value", selected["selected"]),
      ])
    }

    return wireError(
      "bad-request",
      "command is not selectable: \(command)",
      requestType: "command-select",
      sessionID: sessionID
    )
  }

  /// `base64url(JSON.stringify([provider, model]))` — the same opaque token the plugin mints, so a
  /// token minted by either implementation decodes in the other.
  static func modelCommandOptionID(provider: JSONValue?, model: JSONValue?) -> String {
    let json = "[" + jsonStringLiteral(wireText(provider)) + "," + jsonStringLiteral(wireText(model)) + "]"
    return base64URLEncode(Data(json.utf8))
  }

  static func decodeModelCommandOptionID(_ optionID: String) -> (provider: String, model: String)? {
    guard let data = base64URLDecode(optionID),
          let parsed = try? JSONSerialization.jsonObject(with: data),
          let parts = parsed as? [Any],
          parts.count == 2,
          let provider = parts[0] as? String, !provider.isEmpty,
          let model = parts[1] as? String, !model.isEmpty else { return nil }
    return (provider, model)
  }
}

// MARK: - Projection-backed queries

private extension MobileGatewayQueryRouter {
  /// `context-usage` and `session-stats` share the projection shape; only the keys differ.
  func projectionVerb(_ message: JSONValue, type: String) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    let history = await querySessionProjection(requestType: type, sessionID: sessionID)
    guard history["kind"]?.stringValue == "history" else { return history }
    let projections = history["projections"]
    let values = projections?["values"]?.objectValue ?? [:]
    var fields: [String: JSONValue] = [
      "kind": .string(type),
      "sessionId": .string(sessionID),
    ]
    if let asOfSeq = projections?["asOfSeq"] { fields["asOfSeq"] = asOfSeq }
    if type == "session-stats" { fields["sessionStats"] = jsOrNull(values["sessionStats"]) }
    fields["tokenUsage"] = jsOrNull(values["tokenUsage"])
    fields["contextPressure"] = jsOrNull(values["contextPressure"])
    return .object(fields)
  }

  /// `tasks` and `goal` read one projection key and keep the raw `history` error identity: the
  /// caller asked for a projection, so a failure is reported as the history read that failed.
  func sessionProjectionVerb(_ message: JSONValue, type: String, key: String) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    let history = await proxy("history") {
      try await self.adapter.history(.object(["sessionId": .string(sessionID)]))
    }
    guard history["kind"]?.stringValue == "history" else { return history }
    let projections = history["projections"]
    let values = projections?["values"]?.objectValue ?? [:]
    return JSONValue.object([
      ("kind", .string(type)),
      ("sessionId", .string(sessionID)),
      ("asOfSeq", projections?["asOfSeq"]),
      // An explicit null (never a missing key) so the phone can hide the card.
      (key, values[key] ?? .null),
    ])
  }

  /// A one-message snapshot carries the projections without the conversation body, which is all a
  /// projection query needs.
  func querySessionProjection(requestType: String, sessionID: String) async -> JSONValue {
    let history = await proxy("history") {
      try await self.adapter.history(.object([
        "sessionId": .string(sessionID),
        "maxMessages": .number(1),
      ]))
    }
    guard history["kind"]?.stringValue == "error" else { return history }
    // Projection queries keep the caller's request identity on failure.
    return history.merging([
      "requestType": .string(requestType),
      "sessionId": .string(sessionID),
    ])
  }
}

// MARK: - Goals

private extension MobileGatewayQueryRouter {
  func goalEditVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    let ref: JSONValue
    switch requireGoalRef(message, sessionID: sessionID) {
    case .failure(let frame): return frame
    case .success(let value): ref = value
    }
    var objective: String?
    if let text = trimmedString(message["objective"]) { objective = text }
    var maxGoalRounds: Int?
    if let rounds = safeInteger(message["maxGoalRounds"]), rounds > 0 { maxGoalRounds = Int(rounds) }
    guard objective != nil || maxGoalRounds != nil else {
      return wireError(
        "bad-request",
        "goal-edit requires a non-empty objective or a positive maxGoalRounds",
        requestType: "goal-edit",
        sessionID: sessionID
      )
    }
    return await proxy("goal-edit") {
      try await self.adapter.goalEdit(
        sessionID: sessionID,
        ref: ref,
        objective: objective,
        maxGoalRounds: maxGoalRounds
      )
    }
  }

  /// Pause/resume/clear are one shape: compare-and-set on `ref`, and `clear` discards the host's
  /// goal payload in favour of a bare acknowledgement.
  func goalMutationVerb(_ message: JSONValue, type: String) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    let ref: JSONValue
    switch requireGoalRef(message, sessionID: sessionID) {
    case .failure(let frame): return frame
    case .success(let value): ref = value
    }
    switch type {
    case "goal-pause":
      return await proxy("goal-pause") { try await self.adapter.goalPause(sessionID: sessionID, ref: ref) }
    case "goal-resume":
      return await proxy("goal-resume") { try await self.adapter.goalResume(sessionID: sessionID, ref: ref) }
    default:
      return await proxy("goal-clear") { try await self.adapter.goalClear(sessionID: sessionID, ref: ref) }
    }
  }
}

// MARK: - Permission switch

private extension MobileGatewayQueryRouter {
  /// `permission-options`: the namespace from settings, plus this session's current value when a
  /// session was named.
  func permissionOptionsVerb(_ message: JSONValue) async -> JSONValue {
    let frame = await proxy("permission-options") { try await self.adapter.settingsDescribe() }
    guard frame["kind"]?.stringValue == "permission-options" else { return frame }
    let namespaces = frame["namespaces"]?.arrayValue ?? []
    var fields: [String: JSONValue] = [
      "kind": .string("permission-options"),
      // `null` (not a missing key) when the permission namespace is not mounted.
      "namespace": namespaces.first { $0["ns"]?.stringValue == "permission" } ?? .null,
    ]
    if let sessionID = trimmedString(message["sessionId"]) {
      fields["sessionId"] = .string(sessionID)
      let history = await querySessionProjection(requestType: "permission-options", sessionID: sessionID)
      if history["kind"]?.stringValue == "error" { return history }
      if history["kind"]?.stringValue == "history", let values = history.path("projections.values") {
        fields["sessionPermissions"] = await filledSessionPermissions(values["permissions"])
      }
    }
    return .object(fields)
  }

  /// The permission menu's candidates for one session, or the error frame that replaces them.
  ///
  /// DSH 0.1.6 moved the candidate list out of the session projection: the projection keeps only
  /// `currentValue`, and the selectable presets come from the deployment-level
  /// `permissionPresets/catalog`. Reading the projection alone is exactly what made the whole
  /// permission menu unreachable on an upgraded harness, so the catalog is preferred and the
  /// projection's legacy `options` is kept as the 0.1.5 path.
  func permissionCandidates(sessionID: String) async -> Resolution<[JSONValue]> {
    let history = await proxy("history") {
      try await self.adapter.history(.object(["sessionId": .string(sessionID)]))
    }
    guard history["kind"]?.stringValue == "history" else { return .failure(history) }
    let permissions = history.path("projections.values.permissions")
    let current = permissions?["currentValue"]?.stringValue

    if let candidates = await catalogCandidates(current: current) {
      return .success(candidates)
    }
    guard let legacy = permissions?["options"]?.arrayValue, let current else {
      return .failure(wireError(
        "command-options-unavailable",
        "permission options are unavailable for this session",
        requestType: "command-options",
        sessionID: sessionID
      ))
    }
    return .success(legacy.map { permissionOption(from: $0, current: current) })
  }

  /// The catalog's options, mapped for the wire, or `nil` when this host has no catalog endpoint.
  ///
  /// `custom` is appended when it is the session's current value and the catalog does not list
  /// it: the host reserves that name for "the current sandbox and approval knobs match no
  /// preset", so it is a state worth showing as selected — and deliberately not something this
  /// method pretends is selectable, because the host rejects it as a preset name.
  private func catalogCandidates(current: String?) async -> [JSONValue]? {
    guard let catalog = await adapter.permissionCatalog() else { return nil }
    var options = catalog.map { permissionOption(from: $0, current: current) }
    if let current, current == "custom", !catalog.contains(where: { $0["value"]?.stringValue == current }) {
      options.append(.object([
        ("id", .string("custom")),
        ("label", .string("Custom")),
        ("description", .string("Current sandbox and approval settings do not match a preset.")),
        ("selected", .bool(true)),
      ]))
    }
    return options
  }

  /// Map one host preset onto the wire option.
  private func permissionOption(from option: JSONValue, current: String?) -> JSONValue {
    .object([
      ("id", .string(wireText(option["value"]))),
      ("label", .string(wireText(firstTruthy(option["name"], option["value"])))),
      // `detail` is never present for permission options.
      ("description", option["description"].flatMap { isTruthy($0) ? .string(wireText($0)) : nil }),
      ("selected", .bool(option["value"]?.stringValue == current)),
    ])
  }

  /// The projection's `permissions` value with its candidate list restored when the projection no
  /// longer carries one.
  ///
  /// The response keeps its documented shape — `sessionPermissions` is still the projection's own
  /// object — so a client that reads the list from here is not broken by an upgrade that moved
  /// the list elsewhere. Without this the field still resolves but carries no candidates, which
  /// renders as a permission menu with nothing in it.
  private func filledSessionPermissions(_ permissions: JSONValue?) async -> JSONValue {
    guard let permissions, case .object(var fields) = permissions else { return jsOrNull(permissions) }
    if fields["options"]?.arrayValue == nil,
       let candidates = await catalogCandidates(current: fields["currentValue"]?.stringValue) {
      fields["options"] = .array(candidates)
    }
    return .object(fields)
  }

  /// Run `/permission <name>` through the command registry. This mounts the preset on the host
  /// without sending anything to the model.
  func permissionVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    guard let name = trimmedString(message["name"]) else {
      return wireError("bad-request", "permission requires a name", requestType: "permission")
    }
    do {
      let execution = try await adapter.executeCommand(
        sessionID: sessionID,
        line: "/permission " + name,
        attachments: []
      )
      if execution.isNull {
        return wireError(
          "unknown-command",
          "command not found: /permission",
          requestType: "permission",
          sessionID: sessionID
        )
      }
      return JSONValue.object([
        ("kind", .string("permission")),
        ("sessionId", .string(sessionID)),
        ("set", .string(name)),
        ("commandId", execution["commandId"]),
        ("result", execution["result"]),
      ])
    } catch {
      return hostError(error, requestType: "permission", sessionID: sessionID)
    }
  }

  func selectModelVerb(_ message: JSONValue) async -> JSONValue {
    let sessionID: String
    switch requireSessionID(message) {
    case .failure(let frame): return frame
    case .success(let value): sessionID = value
    }
    guard let provider = trimmedString(message["provider"]), let model = trimmedString(message["model"]) else {
      return wireError("bad-request", "select-model requires provider and model", requestType: "select-model")
    }
    var payload: [String: JSONValue] = [
      "sessionId": .string(sessionID),
      "provider": .string(provider),
      "model": .string(model),
    ]
    if let effort = trimmedString(message["reasoningEffort"]) {
      payload["reasoningEffort"] = .string(effort)
    }
    return await proxy("select-model") { try await self.adapter.selectModel(.object(payload)) }
  }
}

// MARK: - Shared validation

private extension MobileGatewayQueryRouter {
  /// `requireSessionId`: the error carries no `sessionId`, because the request never got far enough
  /// to have one.
  func requireSessionID(_ message: JSONValue) -> Resolution<String> {
    if let sessionID = trimmedString(message["sessionId"]) { return .success(sessionID) }
    let type = message["type"]?.stringValue ?? "query"
    return .failure(wireError("bad-request", "this request requires a sessionId", requestType: type))
  }

  /// `parseAgentPreset`. Absent and not required is a success with no value, which is what lets
  /// `message` distinguish "no preset given" from "a blank preset was given".
  func parseAgentPreset(
    _ message: JSONValue,
    requestType: String,
    required: Bool = false
  ) -> Resolution<String?> {
    guard let raw = message["agentPreset"] else {
      if required {
        return .failure(wireError(
          "bad-request",
          "agentPreset must be a non-empty preset ID",
          requestType: requestType
        ))
      }
      return .success(nil)
    }
    guard let text = raw.stringValue,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failure(wireError(
        "bad-request",
        "agentPreset must be a non-empty preset ID",
        requestType: requestType
      ))
    }
    return .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// `parseWireImages`: everything except the bytes, which only the host can judge.
  func parseWireImages(_ raw: JSONValue?, requestType: String) -> Resolution<[JSONValue]> {
    // Only an *absent* field means "no images": an explicit null is a malformed request, exactly
    // as `rawImages === undefined ? [] : rawImages` then `Array.isArray(null)` decides.
    var images: [JSONValue] = []
    if let raw = raw {
      guard let array = raw.arrayValue else {
        return .failure(wireError("bad-request", "images must be an array", requestType: requestType))
      }
      images = array
    }
    guard images.count <= Self.maxImagesPerRequest else {
      return .failure(wireError(
        "bad-request",
        "a request can contain at most \(Self.maxImagesPerRequest) images",
        requestType: requestType
      ))
    }
    var parts: [JSONValue] = []
    for (index, image) in images.enumerated() {
      guard let fields = image.objectValue else {
        return .failure(wireError(
          "bad-request",
          "images[\(index)] must be an object",
          requestType: requestType
        ))
      }
      guard let mediaType = fields["mediaType"]?.stringValue,
            Self.imageMediaTypes.contains(mediaType) else {
        return .failure(wireError(
          "bad-request",
          "images[\(index)].mediaType is unsupported",
          requestType: requestType
        ))
      }
      guard let data = fields["data"]?.stringValue, !data.isEmpty else {
        return .failure(wireError(
          "bad-request",
          "images[\(index)].data must be a non-empty base64 string",
          requestType: requestType
        ))
      }
      var name: JSONValue?
      // Present-but-null is invalid, so the check must distinguish "absent" from "null".
      if let rawName = fields["name"] {
        guard let text = rawName.stringValue, text.utf16.count <= Self.maxImageNameLength else {
          return .failure(wireError(
            "bad-request",
            "images[\(index)].name must be a string of at most \(Self.maxImageNameLength) characters",
            requestType: requestType
          ))
        }
        // An empty name is valid but meaningless, and the plugin omits it from the block.
        if !text.isEmpty { name = .string(text) }
      }
      parts.append(JSONValue.object([
        ("type", .string("image")),
        ("mediaType", .string(mediaType)),
        ("data", .string(data)),
        ("name", name),
      ]))
    }
    return .success(parts)
  }

  /// `validateHistoryCursor`. Both `history` and `fork` gate their cursor on the session format
  /// version, because a cursor is a byte offset into a format the host and phone must agree on.
  func validateHistoryCursor(_ message: JSONValue, sessionID: String, field: String) -> JSONValue? {
    let cursorPresent = message[field] != nil
    guard cursorPresent || message["historyFormatVersion"] != nil else { return nil }
    let requestType = message["type"]?.stringValue ?? "query"
    guard safeInteger(message["historyFormatVersion"]) == Int64(MobileGatewayConfiguration.historyFormatVersion) else {
      return wireError(
        "history-format-mismatch",
        "Reload the Session baseline before using a history or fork cursor; historyFormatVersion must be 3",
        requestType: requestType,
        sessionID: sessionID,
        extra: [
          "historyFormatVersion": .number(Double(MobileGatewayConfiguration.historyFormatVersion)),
          "resetRequired": .bool(true),
        ]
      )
    }
    if cursorPresent, (safeInteger(message[field]) ?? -1) < 0 {
      return wireError(
        "bad-request",
        "\(field) must be a non-negative safe integer",
        requestType: requestType,
        sessionID: sessionID
      )
    }
    return nil
  }

  /// `requireGoalRef`: goal mutations are compare-and-set, so a stale revision must be refused
  /// rather than allowed to clobber a newer update.
  func requireGoalRef(_ message: JSONValue, sessionID: String) -> Resolution<JSONValue> {
    let ref = message["ref"]
    let id = trimmedString(ref?["id"])
    let revision = safeInteger(ref?["revision"]).flatMap { $0 > 0 ? $0 : nil }
    guard let id, let revision else {
      let type = message["type"]?.stringValue
      let label = type ?? "goal mutation"
      return .failure(wireError(
        "bad-request",
        "\(label) requires ref.id and a positive integer ref.revision",
        requestType: type ?? "goal",
        sessionID: sessionID
      ))
    }
    return .success(JSONValue.object([
      ("id", .string(id)),
      ("revision", .number(Double(revision))),
    ]))
  }
}

// MARK: - Host call plumbing

private extension MobileGatewayQueryRouter {
  /// `proxyQuery`: spread the host object into `{ kind: <type>, ...value }`, or answer the uniform
  /// error frame.
  ///
  /// A host value that is not an object is treated as a failed call, not as a payload — spreading a
  /// scalar would produce a frame with no fields and no way for the phone to tell why.
  func proxy(
    _ type: String,
    requestType: String? = nil,
    _ body: () async throws -> JSONValue
  ) async -> JSONValue {
    do {
      let value = try await body()
      guard case .object = value else {
        return wireError(
          "internal",
          "\(type) returned an invalid response",
          requestType: requestType ?? type
        )
      }
      var fields = value.objectValue ?? [:]
      // `{ kind: type, ...value }`: a host-supplied `kind` wins, matching the plugin's spread.
      if fields["kind"] == nil { fields["kind"] = .string(type) }
      return .object(fields)
    } catch {
      return hostError(error, requestType: requestType ?? type)
    }
  }

  /// The plugin's error-mapping rule lives in `MobileGatewayHostError`: a host error's own `code`,
  /// else `internal`, with the host message passed through verbatim.
  func hostError(
    _ error: Error,
    requestType: String?,
    sessionID: String? = nil,
    itemID: String? = nil
  ) -> JSONValue {
    let mapped = MobileGatewayHostError(error: error)
    return wireError(
      mapped.code,
      mapped.message,
      requestType: requestType,
      sessionID: sessionID,
      itemID: itemID
    )
  }
}

// MARK: - File-private helpers

/// A resolution whose failure already *is* the frame to send back.
private enum Resolution<Value> {
  case success(Value)
  case failure(JSONValue)
}

/// The uniform error frame. `requestType`/`sessionId`/`itemId` are attached by the caller because
/// the protocol is not uniform about them: `message` errors omit `requestType`, `tasks`/`goal`
/// errors keep `history`, and only the `queue-update edit` error carries `itemId`.
private func wireError(
  _ code: String,
  _ message: String,
  requestType: String? = nil,
  sessionID: String? = nil,
  itemID: String? = nil,
  extra: [String: JSONValue] = [:]
) -> JSONValue {
  var frame: [String: JSONValue] = [
    "kind": .string("error"),
    "code": .string(code),
    "message": .string(message),
  ]
  if let requestType { frame["requestType"] = .string(requestType) }
  if let sessionID, !sessionID.isEmpty { frame["sessionId"] = .string(sessionID) }
  if let itemID, !itemID.isEmpty { frame["itemId"] = .string(itemID) }
  for (key, value) in extra { frame[key] = value }
  return .object(frame)
}

/// A trimmed, non-empty string, or `nil`. The plugin treats whitespace-only as absent everywhere a
/// string is validated, which is why this never returns `""`.
private func trimmedString(_ value: JSONValue?) -> String? {
  guard let raw = value?.stringValue else { return nil }
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

/// `Number.isSafeInteger`: rejects a JSON string that merely looks numeric, a fraction, and a value
/// past 2^53 where `Double` can no longer name every integer.
private func safeInteger(_ value: JSONValue?) -> Int64? {
  guard case .number(let raw) = value ?? .null else { return nil }
  guard raw.isFinite, raw.rounded() == raw, abs(raw) <= 9_007_199_254_740_992 else { return nil }
  return Int64(raw)
}

/// `typeof value === 'number' && Number.isFinite(value)` — the looser test the history payload uses.
private func finiteNumber(_ value: JSONValue?) -> Double? {
  guard case .number(let raw) = value ?? .null, raw.isFinite else { return nil }
  return raw
}

private func isTruthy(_ value: JSONValue) -> Bool {
  switch value {
  case .null: return false
  case .bool(let flag): return flag
  case .number(let number): return number != 0 && !number.isNaN
  case .string(let text): return !text.isEmpty
  case .array, .object: return true
  }
}

/// `a || b` for wire values, then `String(...)` at the call site.
private func firstTruthy(_ values: JSONValue?...) -> JSONValue? {
  for value in values {
    if let value, isTruthy(value) { return value }
  }
  return nil
}

/// `value || null`: a falsy projection (an empty string, a zero) means "nothing to show".
private func jsOrNull(_ value: JSONValue?) -> JSONValue {
  guard let value, isTruthy(value) else { return .null }
  return value
}

/// `String(value)` as JavaScript would render it, including `undefined` for an absent field.
private func wireText(_ value: JSONValue?) -> String {
  guard let value, !value.isNull else { return "undefined" }
  if let text = value.stringValue { return text }
  if let flag = value.boolValue { return flag ? "true" : "false" }
  if case .number(let number) = value {
    return number == number.rounded() && abs(number) < 9_007_199_254_740_992
      ? String(Int64(number))
      : String(number)
  }
  return (try? value.serialized()) ?? "null"
}

/// JavaScript's `===` for the two cases the wire actually contains: equal strings, equal numbers,
/// or equal booleans. A number never equals its string form.
private func jsStrictEqual(_ lhs: JSONValue?, _ rhs: JSONValue?) -> Bool {
  guard let lhs, let rhs else { return false }
  switch (lhs, rhs) {
  case (.string(let a), .string(let b)): return a == b
  case (.number(let a), .number(let b)): return a == b
  case (.bool(let a), .bool(let b)): return a == b
  case (.null, .null): return true
  default: return false
  }
}

/// `JSON.stringify` of a single string: escapes only what JSON requires, so the base64url option id
/// matches the plugin's byte for byte.
private func jsonStringLiteral(_ text: String) -> String {
  var out = "\""
  for scalar in text.unicodeScalars {
    switch scalar {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    case "\u{08}": out += "\\b"
    case "\u{0C}": out += "\\f"
    default:
      if scalar.value < 0x20 {
        out += String(format: "\\u%04x", scalar.value)
      } else {
        out.unicodeScalars.append(scalar)
      }
    }
  }
  return out + "\""
}

private func base64URLEncode(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private func base64URLDecode(_ text: String) -> Data? {
  var padded = text
    .replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  while padded.count % 4 != 0 { padded += "=" }
  return Data(base64Encoded: padded)
}

/// `path.resolve` for one path: absolute stays absolute, relative resolves against the process's
/// working directory (which is the harness's working directory).
private func resolvePath(_ path: String) -> String {
  let url = path.hasPrefix("/")
    ? URL(fileURLWithPath: path)
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
  return url.standardizedFileURL.path
}

/// `path.join(parent, name)`, without letting a leading slash in `name` escape the parent.
private func joinPath(_ parent: String, _ name: String) -> String {
  (parent as NSString).appendingPathComponent(name)
}

/// One language's copy for the input-menu catalog, exactly as the plugin ships it.
private struct CommandCatalogCopy: Sendable {
  let locale: String
  let commandsTitle: String
  let skillsTitle: String
  let userOnly: String
  let modelDescription: String
  let hints: [String: String]

  static let zh = CommandCatalogCopy(
    locale: "zh-CN",
    commandsTitle: "命令",
    skillsTitle: "技能",
    userOnly: "仅用户",
    modelDescription: "选择本会话使用的模型",
    hints: [
      "plan": "描述你的任务以生成计划",
      "goal": "输入目标，智能体将持续执行",
    ]
  )

  static let en = CommandCatalogCopy(
    locale: "en",
    commandsTitle: "Commands",
    skillsTitle: "Skills",
    userOnly: "user-only",
    modelDescription: "Select the model for this conversation",
    hints: [
      "plan": "describe your task to generate plan",
      "goal": "describe the objective for a long-running task",
    ]
  )
}
