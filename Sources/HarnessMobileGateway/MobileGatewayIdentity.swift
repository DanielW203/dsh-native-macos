import Foundation

/// The gateway's stable identity and the user's saved run-mode choice.
///
/// Identity is kept in its own file, separate from the device registry, so that
/// revoking every paired phone does not also change who this gateway *is* — a phone
/// keeps seeing the same `gatewayId`, which is what lets one app hold pairings to
/// several machines at once.
///
/// The format is byte-compatible with the plugin's `gateway-state.mjs` so the native
/// gateway adopts the identity an installation already has, instead of appearing as a
/// second machine.
public enum MobileGatewayMode: String, Codable, CaseIterable, Sendable {
  /// No listener accepts connections.
  case disabled
  /// Open now, but closes itself if no device connects within the wait window.
  case temporary
  /// Open until the user says otherwise.
  case persistent

  public var localizedName: String {
    switch self {
    case .disabled: return "关闭"
    case .temporary: return "临时开启"
    case .persistent: return "常驻开启"
    }
  }
}

/// Reads and writes `<deviceFile>.gateway.json`.
public final class MobileGatewayIdentity: @unchecked Sendable {
  public enum IdentityError: Error, Equatable {
    /// The file exists but is not a valid identity. Startup must fail rather than
    /// mint a new `gatewayId`, because a silently replaced identity orphans every
    /// phone that paired with this gateway.
    case invalid(String)
    case ioFailure(String)
  }

  /// Saved mode, or `nil` when the user has never chosen one and the launch
  /// configuration still applies.
  private var storedMode: MobileGatewayMode?
  private let file: URL
  private let lock = NSLock()

  public let gatewayID: String

  public init(file: URL) throws {
    self.file = file
    let state = try Self.loadOrCreate(file: file)
    self.gatewayID = state.gatewayId
    self.storedMode = state.mode
  }

  /// The mode the user saved, if any.
  public var mode: MobileGatewayMode? {
    lock.lock(); defer { lock.unlock() }
    return storedMode
  }

  /// Persist a mode choice. This is a user decision, so it outranks the launch
  /// configuration from then on.
  public func setMode(_ mode: MobileGatewayMode) throws {
    lock.lock(); defer { lock.unlock() }
    let next = State(version: 1, gatewayId: gatewayID, mode: mode)
    try Self.write(next, to: file, exclusive: false)
    storedMode = mode
  }

  /// Clear the saved choice, returning the gateway to its configured startup mode.
  public func clearMode() throws {
    lock.lock(); defer { lock.unlock() }
    let next = State(version: 1, gatewayId: gatewayID, mode: nil)
    try Self.write(next, to: file, exclusive: false)
    storedMode = nil
  }

  struct State: Codable, Equatable {
    var version: Int
    var gatewayId: String
    var mode: MobileGatewayMode?
  }

  static func loadOrCreate(file: URL) throws -> State {
    do {
      let data = try Data(contentsOf: file)
      let state = try decode(data)
      // Re-assert 0600 every start: this file is the gateway's identity.
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return state
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
      let fresh = State(version: 1, gatewayId: UUID().uuidString.lowercased(), mode: nil)
      do {
        try write(fresh, to: file, exclusive: true)
        return fresh
      } catch let writeError as NSError where writeError.domain == NSCocoaErrorDomain && writeError.code == NSFileWriteFileExistsError {
        // Another process created the identity between our read and our write. Theirs
        // is authoritative: two gateways with one reported identity is worse than a
        // second read.
        return try decode(try Data(contentsOf: file))
      } catch {
        throw IdentityError.ioFailure("failed to create gateway state \(file.path): \(error.localizedDescription)")
      }
    } catch let error as IdentityError {
      throw error
    } catch {
      throw IdentityError.ioFailure("failed to load gateway state \(file.path): \(error.localizedDescription)")
    }
  }

  static func decode(_ data: Data) throws -> State {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw IdentityError.invalid("gateway state is not a JSON object")
    }
    guard let version = object["version"] as? Int, version == 1 else {
      throw IdentityError.invalid("unsupported gateway state version")
    }
    guard let gatewayId = object["gatewayId"] as? String, isUUIDv4(gatewayId) else {
      throw IdentityError.invalid("invalid gateway identity")
    }
    var mode: MobileGatewayMode?
    if let raw = object["mode"], !(raw is NSNull) {
      guard let text = raw as? String, let parsed = MobileGatewayMode(rawValue: text) else {
        throw IdentityError.invalid("invalid gateway mode")
      }
      mode = parsed
    }
    return State(version: 1, gatewayId: gatewayId, mode: mode)
  }

  static func write(_ state: State, to file: URL, exclusive: Bool) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    var payload = try encoder.encode(state)
    payload.append(0x0A)

    if exclusive {
      // `O_EXCL` is what makes "never overwrite a concurrently created identity" true
      // rather than a race we usually win.
      let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
      guard descriptor >= 0 else {
        if errno == EEXIST {
          throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        }
        throw IdentityError.ioFailure("failed to create \(file.path): \(String(cString: strerror(errno)))")
      }
      defer { close(descriptor) }
      try payload.withUnsafeBytes { raw in
        var written = 0
        while written < raw.count {
          // Qualified because `write` is also an instance method on this type.
          let result = Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
          if result <= 0 { throw IdentityError.ioFailure("short write to \(file.path)") }
          written += result
        }
      }
      return
    }

    let temporary = directory.appendingPathComponent("\(file.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
    do {
      try payload.write(to: temporary, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw IdentityError.ioFailure("failed to write \(file.path): \(error.localizedDescription)")
    }
  }

  /// RFC 4122 version-4 shape, checked by hand so the failure names the field.
  ///
  /// The check is on the original spelling: an uppercase UUID is a different string, and the
  /// identity file the plugin writes is lowercase, so accepting both would let two spellings of
  /// one id compare unequal.
  static func isUUIDv4(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 5, parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
    guard parts[2].first == "4" else { return false }
    guard let variant = parts[3].first, "89ab".contains(variant) else { return false }
    return parts.allSatisfy { part in part.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
  }
}
