import Foundation

/// The bound bot account.
///
/// The token is a credential, so this type redacts itself in every string context: Swift
/// prints values into logs through `String(describing:)` and `debugPrint` implicitly, and
/// a channel that leaks its token into a log file has leaked it permanently. Nothing in
/// this module ever logs `token` directly.
public struct ChannelCredential: Sendable, Equatable, Codable {
  public var botID: String
  public var accountID: String?
  public var ownerUserID: String?
  public var token: String
  public var baseURL: String

  public init(botID: String, accountID: String? = nil, ownerUserID: String? = nil, token: String, baseURL: String) {
    self.botID = botID
    self.accountID = accountID
    self.ownerUserID = ownerUserID
    self.token = token
    self.baseURL = baseURL
  }

  private enum CodingKeys: String, CodingKey {
    case botID, accountID, ownerUserID, token, baseURL
  }
}

extension ChannelCredential: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    "ChannelCredential(botID: \(botID), accountID: \(accountID ?? "-"), owner: \(ownerUserID ?? "-"), token: <redacted>)"
  }

  public var debugDescription: String { description }
}

/// Everything the channel remembers across launches, minus the configuration and the
/// credential.
///
/// A session the phone took over with `/use`.
///
/// `cwd` travels with the id because the harness addresses a session's log by working
/// directory: without it the phone could talk to the session but never read its history.
public struct AdoptedSession: Sendable, Equatable, Codable {
  public var sessionID: String
  public var cwd: String
  public var title: String?

  public init(sessionID: String, cwd: String, title: String? = nil) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.title = title
  }
}

/// The credential is deliberately **not** part of this record: it lives in its own
/// owner-only file so routine state writes never rewrite a secret, and so there is exactly
/// one place that can say whether the channel is bound.
public struct ChannelPersistedState: Sendable, Equatable, Codable {
  /// Opaque sync cursor. Dropping it loses only messages the provider has not re-sent.
  public var getUpdatesBuffer: String
  /// Recently handled message ids, oldest first, capped like the reference client.
  public var seenMessageIDs: [String]
  /// WeChat sender → harness Session, so a conversation keeps its context across batches.
  public var sessions: [String: String]
  /// WeChat sender → last context token, so the channel can open a new message with a sender
  /// it is not currently replying to (an approval question, say) and still land in the same
  /// conversation.
  public var contextTokens: [String: String]
  /// Unsubmitted buffers, so a quit/reboot does not throw away what the user sent.
  public var batches: [String: [BatchItem]]
  /// WeChat sender → the session the phone took over with `/use`.
  ///
  /// Deliberately separate from `sessions`: a session the channel created must be re-attached
  /// to the channel's workspace on every use, while a session picked out of the phone's list
  /// already belongs to a workspace of its own — running it through the same attachment would
  /// raise `session/conflict` and silently strand the conversation in a brand-new session.
  public var adoptedSessions: [String: AdoptedSession]
  public var lastError: String?

  public init(
    getUpdatesBuffer: String = "",
    seenMessageIDs: [String] = [],
    sessions: [String: String] = [:],
    contextTokens: [String: String] = [:],
    batches: [String: [BatchItem]] = [:],
    adoptedSessions: [String: AdoptedSession] = [:],
    lastError: String? = nil
  ) {
    self.getUpdatesBuffer = getUpdatesBuffer
    self.seenMessageIDs = seenMessageIDs
    self.sessions = sessions
    self.contextTokens = contextTokens
    self.batches = batches
    self.adoptedSessions = adoptedSessions
    self.lastError = lastError
  }

  private enum CodingKeys: String, CodingKey {
    case getUpdatesBuffer, seenMessageIDs, sessions, contextTokens, batches, adoptedSessions, lastError
  }

  /// Decode tolerantly: every field is optional on the wire and falls back to its default.
  ///
  /// The synthesized decoder would reject a file written before a field existed, and
  /// `loadState` answers a decode failure by starting from empty — so one added property would
  /// quietly throw away every session binding and context token the user had. Spelling the
  /// container out makes that class of loss impossible.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    getUpdatesBuffer = try container.decodeIfPresent(String.self, forKey: .getUpdatesBuffer) ?? ""
    seenMessageIDs = try container.decodeIfPresent([String].self, forKey: .seenMessageIDs) ?? []
    sessions = try container.decodeIfPresent([String: String].self, forKey: .sessions) ?? [:]
    contextTokens = try container.decodeIfPresent([String: String].self, forKey: .contextTokens) ?? [:]
    batches = try container.decodeIfPresent([String: [BatchItem]].self, forKey: .batches) ?? [:]
    adoptedSessions = try container
      .decodeIfPresent([String: AdoptedSession].self, forKey: .adoptedSessions) ?? [:]
    lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
  }

  /// Cap on remembered ids; the same 1000 the reference client keeps.
  public static let seenLimit = 1_000

  /// Record an id, keeping the list bounded.
  public mutating func remember(messageID: String) {
    guard !messageID.isEmpty else { return }
    seenMessageIDs.append(messageID)
    if seenMessageIDs.count > Self.seenLimit {
      seenMessageIDs.removeFirst(seenMessageIDs.count - Self.seenLimit)
    }
  }

  public func hasSeen(_ messageID: String) -> Bool {
    seenMessageIDs.contains(messageID)
  }
}

/// The channel's own storage.
///
/// Lives under the **app's** root (`~/.nativeharness/im/`), never inside `DSH_HOME`.
/// The harness owns `~/.nativeharness/home`; a second tool writing state there could
/// collide with the runtime's own files, and the zero-intrusion constraint rules that out.
public struct ChannelStateStore: Sendable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory.standardizedFileURL
  }

  /// The conventional location under an app root.
  public static func standard(appRoot: URL) -> ChannelStateStore {
    ChannelStateStore(directory: appRoot.appendingPathComponent("im", isDirectory: true))
  }

  public var stateURL: URL { directory.appendingPathComponent("state.json", isDirectory: false) }
  public var configURL: URL { directory.appendingPathComponent("config.json", isDirectory: false) }
  public var credentialURL: URL { directory.appendingPathComponent("credentials.json", isDirectory: false) }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  // MARK: - State

  /// Load persisted state, or an empty state when nothing is stored yet.
  ///
  /// A corrupt file is reported by returning empty state with the parse error recorded:
  /// refusing to start because one JSON file was truncated would strand the user with a
  /// channel that cannot even be re-bound.
  public func loadState() -> ChannelPersistedState {
    guard let data = try? Data(contentsOf: stateURL) else { return ChannelPersistedState() }
    do {
      var state = try Self.decoder().decode(ChannelPersistedState.self, from: data)
      if state.seenMessageIDs.count > ChannelPersistedState.seenLimit {
        state.seenMessageIDs.removeFirst(state.seenMessageIDs.count - ChannelPersistedState.seenLimit)
      }
      return state
    } catch {
      return ChannelPersistedState(lastError: "已忽略损坏的渠道状态文件：\(error.localizedDescription)")
    }
  }

  public func save(state: ChannelPersistedState) throws {
    try writeAtomically(try Self.encoder().encode(state), to: stateURL)
  }

  // MARK: - Config

  public func loadConfig() -> ChannelConfig {
    guard let data = try? Data(contentsOf: configURL),
          let config = try? Self.decoder().decode(ChannelConfig.self, from: data) else {
      return ChannelConfig()
    }
    return config
  }

  public func save(config: ChannelConfig) throws {
    try writeAtomically(try Self.encoder().encode(config), to: configURL)
  }

  // MARK: - Credential

  public func loadCredential() -> ChannelCredential? {
    guard let data = try? Data(contentsOf: credentialURL) else { return nil }
    return try? Self.decoder().decode(ChannelCredential.self, from: data)
  }

  public func save(credential: ChannelCredential) throws {
    try writeAtomically(try Self.encoder().encode(credential), to: credentialURL)
  }

  public func clearCredential() {
    try? FileManager.default.removeItem(at: credentialURL)
  }

  // MARK: - Plumbing

  /// Write a file with owner-only permissions, creating the directory owner-only too.
  ///
  /// The permissions are set explicitly because the process umask is not a contract: a
  /// world-readable credentials file would outlive the app.
  func writeAtomically(_ data: Data, to url: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: url, options: [.atomic])
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
