import CryptoKit
import Foundation
import HarnessKit

#if canImport(Darwin)
import Darwin
#endif

/// The `file-*` control family: listing a session's working directory, and streaming one regular
/// file out of it in fixed-size chunks.
///
/// There is deliberately no upload verb. The host's only inbound byte path is the inline base64
/// image attached to `message` / `command-execute`, so this layer opens files `O_RDONLY` and
/// nothing else — accepting bytes from a phone would be a write path the protocol never defined.
///
/// A manager instance **is** the connection scope: every transfer it opens is servable only
/// through the same instance, and `closeAll()` (what a socket's close handler calls) releases the
/// handles. A gateway that shares one instance across sockets passes the socket's identity as
/// `owner` instead, which is also what keeps `file-download-max-transfers` a global cap rather
/// than a per-connection one.
public struct MobileGatewayFileTransfer: Sendable {
  /// The four client message types this layer owns, and the only ones it answers.
  public static let verbs: Set<String> = [
    "file-list",
    "file-download-open",
    "file-download-read",
    "file-download-cancel",
  ]

  // The plugin's `DEFAULT_FILE_DOWNLOAD_*` values. The gateway configuration carries only the
  // feature switch (`fileDownloadsEnabled`), so these defaults are the deployed behaviour rather
  // than something a deployment can retune.
  public static let maxDownloadBytes: Int = 536_870_912
  public static let chunkBytes: Int = 524_288
  public static let idleInterval: TimeInterval = 2 * 60
  public static let maxTransfers: Int = 4

  private let store: Store

  public init(adapter: MobileGatewayHostAdapter, configuration: MobileGatewayConfiguration) {
    self.store = Store(adapter: adapter, configuration: configuration)
  }
}

// MARK: - Public surface

extension MobileGatewayFileTransfer {
  /// Handle one `file-*` message. Exactly one reply frame is passed to `reply`.
  ///
  /// `true` means the message belonged to this layer, so the caller must not fall through to the
  /// query dispatcher (which would answer `unknown message type` for a verb it never owned).
  public func handle(
    _ message: JSONValue,
    reply: @escaping @Sendable (JSONValue) -> Void
  ) async -> Bool {
    await handle(message, owner: nil, reply: reply)
  }

  /// The owner-aware form. A gateway that shares one manager between sockets passes the socket's
  /// identity here, so a `transferId` observed by another connection cannot be read or cancelled.
  public func handle(
    _ message: JSONValue,
    owner: String?,
    reply: @escaping @Sendable (JSONValue) -> Void
  ) async -> Bool {
    guard let type = message["type"]?.stringValue, Self.verbs.contains(type) else { return false }
    // A disabled feature still owns its verbs: answering the other channel's dispatcher would
    // report the verb as unknown, and the phone's UI reads the code, not the absence of a reply.
    guard store.configuration.fileDownloadsEnabled else {
      reply(transferError(
        "file-download-disabled",
        "file downloads are disabled by gateway configuration",
        type
      ))
      return true
    }
    switch type {
    case "file-list":
      reply(await store.fileList(message))
    case "file-download-open":
      reply(await store.downloadOpen(message, owner: owner))
    case "file-download-read":
      reply(store.downloadRead(message, owner: owner))
    case "file-download-cancel":
      reply(store.downloadCancel(message, owner: owner))
    default:
      // `verbs` and the switch above are the same set; this is unreachable, and returning `false`
      // is the safe direction if they ever drift apart.
      return false
    }
    return true
  }

  /// Connection teardown: close every transfer this manager opened.
  public func closeAll() {
    store.closeTransfers(owner: nil)
  }

  /// Connection teardown for the shared-instance form: close only `owner`'s transfers.
  public func closeTransfers(owner: String) {
    store.closeTransfers(owner: owner)
  }

  /// The extension-derived media type the client uses to decide how to open a download.
  public static func mediaType(forPath path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "apk": return "application/vnd.android.package-archive"
    case "doc": return "application/msword"
    case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "ipa": return "application/octet-stream"
    case "json": return "application/json"
    case "pdf": return "application/pdf"
    case "ppt": return "application/vnd.ms-powerpoint"
    case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    case "txt": return "text/plain"
    case "xls": return "application/vnd.ms-excel"
    case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    case "zip": return "application/zip"
    default: return "application/octet-stream"
    }
  }

  /// The wire form of `target` relative to `root`, or `nil` when `target` is not under `root`.
  ///
  /// This is the whole containment rule: it is **lexical** here, and the caller re-runs it after
  /// resolving symlinks, because a path that stays inside lexically can still leave through a
  /// symlinked directory.
  public static func relativePath(root: String, target: String) -> String? {
    let rootComponents = lexicalComponents(root)
    let targetComponents = lexicalComponents(target)
    guard targetComponents.count >= rootComponents.count,
          targetComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
      return nil
    }
    let rest = targetComponents.dropFirst(rootComponents.count)
    return rest.isEmpty ? "." : rest.joined(separator: "/")
  }
}

// MARK: - State

extension MobileGatewayFileTransfer {
  /// A resolution that failed with the frame to send back.
  ///
  /// `Result` is not usable here: its failure type must conform to `Error`, and the failure *is*
  /// the wire frame, which the protocol layer must not have to unwrap.
  enum Resolution<Value> {
    case success(Value)
    case failure(JSONValue)
  }

  /// A workspace target that passed both containment checks.
  struct Target {
    let root: String
    let path: String
    let mode: mode_t
    let size: Int64

    var isDirectory: Bool { isDirectoryMode(mode) }
    var isRegularFile: Bool { isRegularMode(mode) }
  }

  /// One open download.
  ///
  /// Fields are mutated under `Store.lock`; the `FileHandle` is deliberately touched *outside*
  /// the lock so a slow disk read cannot stall an expiry sweep or another connection's listing.
  final class Transfer {
    let handle: FileHandle
    let owner: String?
    let sessionID: String
    let path: String
    let name: String
    let mediaType: String
    let size: Int64
    var offset: Int64 = 0
    var hasher = SHA256()
    var reading = false
    var closed = false
    var lastActiveAt = Date()

    init(
      handle: FileHandle,
      owner: String?,
      sessionID: String,
      path: String,
      name: String,
      mediaType: String,
      size: Int64
    ) {
      self.handle = handle
      self.owner = owner
      self.sessionID = sessionID
      self.path = path
      self.name = name
      self.mediaType = mediaType
      self.size = size
    }
  }

  final class Store: @unchecked Sendable {
    let adapter: MobileGatewayHostAdapter
    let configuration: MobileGatewayConfiguration

    private let lock = NSLock()
    private var transfers: [String: Transfer] = [:]
    private var reaper: Task<Void, Never>?

    init(adapter: MobileGatewayHostAdapter, configuration: MobileGatewayConfiguration) {
      self.adapter = adapter
      self.configuration = configuration
    }

    deinit {
      // No other reference can exist here, so the map is read without the lock.
      reaper?.cancel()
      for transfer in transfers.values where !transfer.closed {
        transfer.closed = true
        try? transfer.handle.close()
      }
    }

    // MARK: Lifecycle

    func closeTransfers(owner: String?) {
      var closing: [Transfer] = []
      lock.lock()
      for (id, transfer) in transfers where owner == nil || transfer.owner == owner {
        closing.append(transfer)
        transfers.removeValue(forKey: id)
      }
      lock.unlock()
      for transfer in closing { closeHandle(transfer) }
    }

    /// The handle is closed exactly once, wherever the transfer was retired from. Closing it
    /// twice is not merely wasteful: the descriptor number may already belong to another file.
    private func closeHandle(_ transfer: Transfer) {
      guard !transfer.closed else { return }
      transfer.closed = true
      try? transfer.handle.close()
    }

    /// Idle sweeps are what release a handle when the phone simply stops asking. The plugin ticks
    /// on `setInterval(…, min(fileDownloadIdleMs, 30_000))`; the same cap is used here so the
    /// sweep never runs more often than the default idle window would ever need.
    private func startReaperIfNeeded() {
      guard reaper == nil else { return }
      let tick = min(MobileGatewayFileTransfer.idleInterval, 30)
      reaper = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
          if Task.isCancelled { return }
          guard let self else { return }
          self.expireIdle()
        }
      }
    }

    private func expireIdle() {
      let cutoff = Date().addingTimeInterval(-MobileGatewayFileTransfer.idleInterval)
      var expired: [Transfer] = []
      lock.lock()
      for (id, transfer) in transfers where !transfer.reading && transfer.lastActiveAt < cutoff {
        expired.append(transfer)
        transfers.removeValue(forKey: id)
      }
      lock.unlock()
      for transfer in expired { closeHandle(transfer) }
    }

    // MARK: Session root and target resolution

    /// Resolve the session's working directory the way the plugin does: through the host's session
    /// list, then through `realpath`, so a `cwd` that is itself a symlink cannot widen the
    /// workspace the caller thinks it is confined to.
    private func resolveSessionRoot(
      sessionID: String,
      requestType: String
    ) async -> Resolution<String> {
      let payload: JSONValue
      do {
        payload = try await adapter.listSessions()
      } catch {
        // A failing `session/list` is an error of the *caller's* request type, not its own: the
        // phone correlates frames by `requestType`, and it never sent a `sessions` request.
        let hostError = MobileGatewayHostError(error: error)
        return .failure(transferError(hostError.code, hostError.message, requestType))
      }
      let items = payload["items"]?.arrayValue ?? []
      guard let item = items.first(where: { sessionIdentifier($0["sessionId"]) == sessionID }) else {
        return .failure(transferError("session-not-found", "no such session", requestType, sessionID))
      }
      guard let raw = item["cwd"]?.stringValue,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .failure(transferError(
          "file-workspace-unavailable",
          "the session has no working directory",
          requestType,
          sessionID
        ))
      }
      guard let root = posixRealpath(raw) else {
        return .failure(transferError(
          "file-workspace-unavailable",
          "the session working directory is unavailable",
          requestType,
          sessionID
        ))
      }
      var attributes = stat()
      guard stat(root, &attributes) == 0, isDirectoryMode(attributes.st_mode) else {
        return .failure(transferError(
          "file-workspace-unavailable",
          "the session working directory is unavailable",
          requestType,
          sessionID
        ))
      }
      return .success(root)
    }

    private func resolveTarget(
      sessionID: String,
      raw: JSONValue?,
      requestType: String,
      allowEmpty: Bool
    ) async -> Resolution<Target> {
      guard let requested = normalizedWorkspaceInput(raw, allowEmpty: allowEmpty) else {
        return .failure(transferError(
          "bad-request",
          "\(requestType) requires a relative workspace path",
          requestType,
          sessionID
        ))
      }
      let rootResult = await resolveSessionRoot(sessionID: sessionID, requestType: requestType)
      let root: String
      switch rootResult {
      case .failure(let frame): return .failure(frame)
      case .success(let value): root = value
      }

      let joined = root.hasSuffix("/") ? root + requested : root + "/" + requested
      let candidate = lexicalPath(joined)
      guard MobileGatewayFileTransfer.relativePath(root: root, target: candidate) != nil else {
        return .failure(pathNotAllowed(requestType, sessionID))
      }
      // The lexical check above cannot see a symlinked *directory* in the middle of the path, so
      // the resolved form is re-checked before anything is opened.
      guard let target = posixRealpath(candidate) else {
        return .failure(statFailure(requestType, sessionID))
      }
      guard MobileGatewayFileTransfer.relativePath(root: root, target: target) != nil else {
        return .failure(pathNotAllowed(requestType, sessionID))
      }
      var attributes = stat()
      guard stat(target, &attributes) == 0 else {
        return .failure(statFailure(requestType, sessionID))
      }
      return .success(Target(
        root: root,
        path: target,
        mode: attributes.st_mode,
        size: Int64(attributes.st_size)
      ))
    }

    private func pathNotAllowed(_ requestType: String, _ sessionID: String) -> JSONValue {
      transferError(
        "file-not-allowed",
        "path must stay inside the session working directory",
        requestType,
        sessionID
      )
    }

    /// `errno` is read here, immediately after the failing call that set it.
    private func statFailure(_ requestType: String, _ sessionID: String) -> JSONValue {
      if errno == ENOENT {
        return transferError("file-not-found", "file does not exist", requestType, sessionID)
      }
      return transferError("file-unreadable", "file cannot be read", requestType, sessionID)
    }

    // MARK: file-list

    func fileList(_ message: JSONValue) async -> JSONValue {
      let requestType = "file-list"
      let sessionID: String
      switch requireSessionID(message) {
      case .failure(let frame): return frame
      case .success(let value): sessionID = value
      }

      let resolution = await resolveTarget(
        sessionID: sessionID,
        raw: message["path"],
        requestType: requestType,
        allowEmpty: true
      )
      let target: Target
      switch resolution {
      case .failure(let frame): return frame
      case .success(let value): target = value
      }
      guard target.isDirectory else {
        return transferError("file-not-directory", "path is not a directory", requestType, sessionID)
      }
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: target.path) else {
        return transferError("file-unreadable", "directory cannot be read", requestType, sessionID)
      }

      var entries: [(kind: String, name: String, value: JSONValue)] = []
      for name in names {
        let child = (target.path as NSString).appendingPathComponent(name)
        var attributes = stat()
        // `lstat`, not `stat`: a symlink must be recognised as one so it can be dropped rather
        // than followed. A listing that cannot be stat'd is a listing the client must not see
        // half of, so the whole request fails.
        guard lstat(child, &attributes) == 0 else {
          return transferError("file-unreadable", "directory cannot be read", requestType, sessionID)
        }
        if isSymlinkMode(attributes.st_mode) { continue }
        guard let relative = MobileGatewayFileTransfer.relativePath(root: target.root, target: child)
        else { continue }
        if isDirectoryMode(attributes.st_mode) {
          entries.append((kind: "directory", name: name, value: .object([
            "name": .string(name),
            "path": .string(relative),
            "kind": .string("directory"),
          ])))
        } else if isRegularMode(attributes.st_mode) {
          entries.append((kind: "file", name: name, value: .object([
            "name": .string(name),
            "path": .string(relative),
            "kind": .string("file"),
            "bytes": .number(Double(attributes.st_size)),
            "modifiedAt": .number(epochMilliseconds(attributes)),
            "mediaType": .string(MobileGatewayFileTransfer.mediaType(forPath: child)),
          ])))
        }
        // Anything else (fifo, socket, device) is skipped: none of them are downloadable and the
        // client has no representation for them.
      }
      entries.sort { lhs, rhs in
        if lhs.kind == rhs.kind {
          let order = lhs.name.localizedCompare(rhs.name)
          if order != .orderedSame { return order == .orderedAscending }
          // A locale-aware comparison can call two distinct names equal; the tiebreak keeps the
          // order total so the same directory always lists the same way.
          return lhs.name < rhs.name
        }
        return lhs.kind == "directory"
      }

      var frame: [String: JSONValue] = [
        "kind": .string("file-list"),
        "sessionId": .string(sessionID),
        "path": .string(
          MobileGatewayFileTransfer.relativePath(root: target.root, target: target.path) ?? "."
        ),
        "entries": .array(entries.map { $0.value }),
      ]
      // Echoed only when the client supplied a non-blank one; a blank echo would look like a
      // correlation the client never asked for.
      if let requestID = trimmedString(message["requestId"]) {
        frame["requestId"] = .string(requestID)
      }
      return .object(frame)
    }

    // MARK: file-download-open

    func downloadOpen(_ message: JSONValue, owner: String?) async -> JSONValue {
      let requestType = "file-download-open"
      let requestID = trimmedString(message["requestId"])
      // The requestId check runs before the sessionId check, and its frame carries no sessionId:
      // the request was rejected before any session was named, so naming one would be a lie.
      guard let requestID else {
        return transferError("bad-request", "file-download-open requires a requestId", requestType)
      }
      let sessionID: String
      switch requireSessionID(message) {
      case .failure(let frame): return frame
      case .success(let value): sessionID = value
      }

      lock.lock()
      startReaperIfNeeded()
      let active = transfers.count
      lock.unlock()
      guard active < MobileGatewayFileTransfer.maxTransfers else {
        return transferError(
          "file-transfer-limit",
          "too many active file downloads",
          requestType,
          sessionID
        )
      }

      let resolution = await resolveTarget(
        sessionID: sessionID,
        raw: message["path"],
        requestType: requestType,
        allowEmpty: false
      )
      let target: Target
      switch resolution {
      case .failure(let frame): return frame
      case .success(let value): target = value
      }
      guard target.isRegularFile else {
        return transferError(
          "file-not-regular",
          "only regular files can be downloaded",
          requestType,
          sessionID
        )
      }
      guard target.size <= Int64(MobileGatewayFileTransfer.maxDownloadBytes) else {
        return transferError(
          "file-too-large",
          "file exceeds the configured download limit",
          requestType,
          sessionID
        )
      }

      // `O_NOFOLLOW` on the leaf closes the window between the containment checks and the open:
      // without it a symlink swapped in for the file would be followed straight out of the
      // workspace. The size re-check catches a file replaced, not merely re-pointed.
      let descriptor = open(target.path, O_RDONLY | O_NOFOLLOW)
      guard descriptor >= 0 else {
        return transferError("file-unreadable", "file cannot be opened", requestType, sessionID)
      }
      var attributes = stat()
      guard fstat(descriptor, &attributes) == 0 else {
        close(descriptor)
        return transferError("file-unreadable", "file cannot be opened", requestType, sessionID)
      }
      guard isRegularMode(attributes.st_mode), Int64(attributes.st_size) == target.size else {
        close(descriptor)
        return transferError(
          "file-changed",
          "file changed before download could start",
          requestType,
          sessionID
        )
      }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

      // Lower-cased because `crypto.randomUUID()` is lower-case hex; a client that pattern-matches
      // transfer ids should not see two spellings of the same UUID.
      let transferID = UUID().uuidString.lowercased()
      let relative = MobileGatewayFileTransfer.relativePath(root: target.root, target: target.path)
        ?? target.path
      let name = (target.path as NSString).lastPathComponent
      let mediaType = MobileGatewayFileTransfer.mediaType(forPath: target.path)
      let transfer = Transfer(
        handle: handle,
        owner: owner,
        sessionID: sessionID,
        path: relative,
        name: name,
        mediaType: mediaType,
        size: target.size
      )
      lock.lock()
      transfers[transferID] = transfer
      lock.unlock()

      return .object([
        "kind": .string("file-download-opened"),
        "requestId": .string(requestID),
        "transferId": .string(transferID),
        "sessionId": .string(sessionID),
        "path": .string(relative),
        "name": .string(name),
        "mediaType": .string(mediaType),
        "size": .number(Double(target.size)),
        "chunkBytes": .number(Double(MobileGatewayFileTransfer.chunkBytes)),
      ])
    }

    // MARK: file-download-read

    func downloadRead(_ message: JSONValue, owner: String?) -> JSONValue {
      let requestType = "file-download-read"
      guard let transferID = trimmedString(message["transferId"]) else {
        return transferError("bad-request", "file-download-read requires a transferId", requestType)
      }

      lock.lock()
      guard let transfer = transfers[transferID], transfer.owner == owner else {
        lock.unlock()
        return transferError("file-transfer-not-found", "file download is no longer active", requestType)
      }
      // Offsets are absolute and must equal the next unread byte exactly: this version has no
      // random access and no resume, so a mismatched offset is a client bug, not a seek.
      guard let offset = safeInteger(message["offset"]), offset == transfer.offset else {
        let sessionID = transfer.sessionID
        lock.unlock()
        return transferError(
          "file-transfer-offset",
          "offset must match the next unread byte",
          requestType,
          sessionID
        )
      }
      guard !transfer.reading else {
        let sessionID = transfer.sessionID
        lock.unlock()
        return transferError(
          "file-transfer-busy",
          "a chunk read is already in progress",
          requestType,
          sessionID
        )
      }
      transfer.reading = true
      transfer.lastActiveAt = Date()
      let sessionID = transfer.sessionID
      let start = transfer.offset
      let size = transfer.size
      lock.unlock()

      let bytesToRead = min(Int64(MobileGatewayFileTransfer.chunkBytes), size - start)
      var payload = Data()
      var failure: String?
      if bytesToRead > 0 {
        do {
          _ = try transfer.handle.seek(toOffset: UInt64(start))
          let chunk = try transfer.handle.read(upToCount: Int(bytesToRead)) ?? Data()
          if Int64(chunk.count) == bytesToRead {
            payload = chunk
          } else {
            // Short of a full chunk before EOF means the file shrank under us.
            failure = "file-changed"
          }
        } catch {
          failure = "file-unreadable"
        }
      }

      lock.lock()
      if let failure {
        transfers.removeValue(forKey: transferID)
        transfer.reading = false
        lock.unlock()
        closeHandle(transfer)
        if failure == "file-changed" {
          return transferError("file-changed", "file changed during download", requestType, sessionID)
        }
        return transferError("file-unreadable", "file cannot be read", requestType, sessionID)
      }
      transfer.hasher.update(data: payload)
      let chunkOffset = transfer.offset
      transfer.offset += Int64(payload.count)
      transfer.lastActiveAt = Date()
      let eof = transfer.offset == transfer.size
      transfer.reading = false
      var digest: String?
      if eof {
        digest = hexString(transfer.hasher.finalize())
        transfers.removeValue(forKey: transferID)
      }
      lock.unlock()
      if eof { closeHandle(transfer) }

      var frame: [String: JSONValue] = [
        "kind": .string("file-download-chunk"),
        "transferId": .string(transferID),
        "offset": .number(Double(chunkOffset)),
        "data": .string(payload.base64EncodedString()),
        "eof": .bool(eof),
      ]
      // The digest covers every chunk, so it can only be sent with the last one.
      if let digest { frame["sha256"] = .string(digest) }
      return .object(frame)
    }

    // MARK: file-download-cancel

    func downloadCancel(_ message: JSONValue, owner: String?) -> JSONValue {
      let requestType = "file-download-cancel"
      guard let transferID = trimmedString(message["transferId"]) else {
        return transferError("bad-request", "file-download-cancel requires a transferId", requestType)
      }
      lock.lock()
      guard let transfer = transfers[transferID], transfer.owner == owner else {
        lock.unlock()
        return transferError("file-transfer-not-found", "file download is no longer active", requestType)
      }
      transfers.removeValue(forKey: transferID)
      lock.unlock()
      closeHandle(transfer)
      return .object([
        "kind": .string("file-download-cancelled"),
        "transferId": .string(transferID),
      ])
    }

    // MARK: Message helpers

    /// `requireSessionId` in the plugin: the error carries no `sessionId`, because the request did
    /// not get far enough to have one.
    private func requireSessionID(_ message: JSONValue) -> Resolution<String> {
      if let sessionID = trimmedString(message["sessionId"]) {
        return .success(sessionID)
      }
      let type = message["type"]?.stringValue ?? "query"
      return .failure(transferError("bad-request", "this request requires a sessionId", type))
    }
  }
}

// MARK: - File-private helpers

/// The shared error frame. `sessionId` is present only when there is one to name — the phone
/// distinguishes "this session has no workspace" from "you never told me the session".
private func transferError(
  _ code: String,
  _ message: String,
  _ requestType: String,
  _ sessionID: String? = nil
) -> JSONValue {
  var frame: [String: JSONValue] = [
    "kind": .string("error"),
    "code": .string(code),
    "message": .string(message),
    "requestType": .string(requestType),
  ]
  if let sessionID, !sessionID.isEmpty { frame["sessionId"] = .string(sessionID) }
  return .object(frame)
}

private func trimmedString(_ value: JSONValue?) -> String? {
  guard let raw = value?.stringValue else { return nil }
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

/// `Number.isSafeInteger`: rejects a JSON string that merely looks numeric, a fraction, and a
/// value past 2^53 where `Double` can no longer name every integer.
private func safeInteger(_ value: JSONValue?) -> Int64? {
  guard case .number(let raw) = value ?? .null else { return nil }
  guard raw.isFinite, raw.rounded() == raw, abs(raw) <= 9_007_199_254_740_992 else { return nil }
  return Int64(raw)
}

/// The plugin compares `String(entry.sessionId) === sessionId`, so a numeric id must still match.
private func sessionIdentifier(_ value: JSONValue?) -> String? {
  guard let value else { return nil }
  if let text = value.stringValue { return text }
  guard case .number(let raw) = value, raw.isFinite, raw.rounded() == raw,
        abs(raw) <= 9_007_199_254_740_992 else { return nil }
  return String(Int64(raw))
}

/// A client path, or `nil` when it is not one this layer will resolve.
///
/// POSIX-absolute, NUL-bearing, and any `..` segment are refused outright; `allowEmpty` is what
/// makes "list the root" expressible while "download the root" stays an error.
private func normalizedWorkspaceInput(_ raw: JSONValue?, allowEmpty: Bool) -> String? {
  guard let value = raw, !value.isNull else { return allowEmpty ? "." : nil }
  guard let text = value.stringValue else { return nil }
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return allowEmpty ? "." : nil }
  if trimmed.contains("\0") { return nil }
  if trimmed.hasPrefix("/") { return nil }
  if trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..") { return nil }
  return trimmed
}

/// `fsp.realpath`. Returns `nil` and leaves `errno` set, which is what callers branch on.
private func posixRealpath(_ path: String) -> String? {
  guard let buffer = realpath(path, nil) else { return nil }
  defer { free(buffer) }
  return String(cString: buffer)
}

/// Split into components with `.` and `..` applied lexically.
///
/// This deliberately does not use `URL.standardizedFileURL`: on macOS that call is
/// filesystem-dependent — it rewrites `/private/tmp` to `/tmp` — so a containment check built on
/// it disagrees with the raw `realpath` output it is compared against, and a legitimate path under
/// a `realpath`-resolved root is rejected. Purely lexical also means a path that does not exist is
/// normalised exactly as the `path.resolve` this ports.
private func lexicalComponents(_ path: String) -> [String] {
  let isAbsolute = path.hasPrefix("/")
  var stack: [String] = []
  for component in path.split(separator: "/", omittingEmptySubsequences: true) {
    switch component {
    case ".":
      continue
    case "..":
      if let last = stack.last, last != ".." {
        stack.removeLast()
      } else if !isAbsolute {
        // Only a relative path can be pushed above its own start; an absolute one stays at "/".
        stack.append("..")
      }
    default:
      stack.append(String(component))
    }
  }
  return isAbsolute ? ["/"] + stack : stack
}

private func lexicalPath(_ path: String) -> String {
  let components = lexicalComponents(path)
  if components.first == "/" {
    return "/" + components.dropFirst().joined(separator: "/")
  }
  return components.isEmpty ? "." : components.joined(separator: "/")
}

private func isDirectoryMode(_ mode: mode_t) -> Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
private func isRegularMode(_ mode: mode_t) -> Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
private func isSymlinkMode(_ mode: mode_t) -> Bool { mode & mode_t(S_IFMT) == mode_t(S_IFLNK) }

/// Epoch **milliseconds**, matching `stat.mtimeMs` on the wire.
private func epochMilliseconds(_ attributes: stat) -> Double {
  #if canImport(Darwin)
  let stamp = attributes.st_mtimespec
  #else
  let stamp = attributes.st_mtim
  #endif
  return Double(stamp.tv_sec) * 1000 + Double(stamp.tv_nsec) / 1_000_000
}

private func hexString(_ digest: SHA256.Digest) -> String {
  digest.map { String(format: "%02x", $0) }.joined()
}
