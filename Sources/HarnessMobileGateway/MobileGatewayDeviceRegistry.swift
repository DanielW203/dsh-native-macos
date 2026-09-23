import CryptoKit
import Foundation

/// The paired-device registry: the only thing standing between a phone on the LAN and
/// the harness's full tool surface.
///
/// Two credential kinds live here, and they are deliberately different:
/// - **Pairing codes** are one-time, short-lived, and memory-only. A restart throws
///   every outstanding QR code away without touching already-paired devices, which is
///   exactly the behaviour a screenshot of a QR code deserves.
/// - **Device tokens** are 256 bits of entropy, single-use per connection, and are
///   never written to disk — only their SHA-256 digest is persisted. A stolen
///   registry file therefore does not yield a usable credential.
///
/// The on-disk format is byte-compatible with `dsh-plugin-mobile-gateway`'s
/// `devices.js` (`version: 3`), so a phone paired against the JS gateway keeps working
/// after the native gateway takes over — and vice versa, should the plugin be
/// re-enabled. The JS side's v1 plaintext-token migration is honoured on read.
public final class MobileGatewayDeviceRegistry: @unchecked Sendable {
  /// Store format version, matching `devices.js`'s `STORE_VERSION`.
  public static let storeVersion = 3
  public static let defaultPairingTTL: TimeInterval = 5 * 60
  /// The name given to a pairing that the manager did not name.
  public static let unnamedDevice = "未命名设备"

  /// One row of the registry file.
  struct StoredDevice: Codable, Equatable {
    var id: String
    var name: String
    var clientDeviceId: String?
    var tokenHash: String
    var createdAt: Double
    var lastSeenAt: Double?
    var revokedAt: Double?
  }

  private struct Store: Codable {
    var version: Int
    var devices: [StoredDevice]
  }

  /// A pairing code that has not yet been claimed. Memory-only by construction.
  private struct Pairing {
    var id: String
    var name: String
    var expiresAt: Double
  }

  /// The shape handed to clients and to the management window.
  public struct DeviceSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Double
    public var lastSeenAt: Double?
    public var online: Bool
    public var connections: Int

    public init(id: String, name: String, createdAt: Double, lastSeenAt: Double?, online: Bool, connections: Int) {
      self.id = id
      self.name = name
      self.createdAt = createdAt
      self.lastSeenAt = lastSeenAt
      self.online = online
      self.connections = connections
    }
  }

  public struct PairingGrant: Equatable, Sendable {
    public var id: String
    public var name: String
    public var expiresAt: Double
    /// The code itself, returned exactly once — it is stored only as a digest.
    public var code: String
  }

  public struct PairedDevice: Equatable, Sendable {
    public var device: DeviceSummary
    /// The long-lived token, returned exactly once, to be stored in the phone's Keychain.
    public var token: String
  }

  public enum RegistryError: Error, Equatable {
    case unreadable(String)
    case unwritable(String)
  }

  private let file: URL
  private let pairingTTL: TimeInterval
  private let lock = NSLock()
  private var devices: [StoredDevice] = []
  private var pairings: [String: Pairing] = [:]
  private var online: [String: Int] = [:]

  /// Loads (or initialises) the registry at `file`.
  ///
  /// A malformed file throws rather than being silently replaced: overwriting it would
  /// revoke every paired phone, and a corruption that self-heals is a corruption whose
  /// cause is never found.
  public init(file: URL, pairingTTL: TimeInterval = MobileGatewayDeviceRegistry.defaultPairingTTL) throws {
    self.file = file
    self.pairingTTL = pairingTTL > 0 ? pairingTTL : MobileGatewayDeviceRegistry.defaultPairingTTL
    try load()
  }

  // MARK: - Reading

  /// Paired, non-revoked devices with their live connection counts.
  public func list() -> [DeviceSummary] {
    lock.lock(); defer { lock.unlock() }
    return devices
      .filter { $0.revokedAt == nil }
      .map { summary(of: $0) }
  }

  public func count() -> Int {
    lock.lock(); defer { lock.unlock() }
    return devices.filter { $0.revokedAt == nil }.count
  }

  /// Whether a pairing code is currently outstanding.
  public func hasPairing(code: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    prunePairings()
    return pairings[Self.digest(code)] != nil
  }

  // MARK: - Pairing

  /// Create a one-time pairing code.
  public func createPairing(name: String?) -> PairingGrant {
    lock.lock(); defer { lock.unlock() }
    prunePairings()
    let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = trimmed.isEmpty ? Self.unnamedDevice : String(trimmed.prefix(80))
    let code = Self.randomToken()
    let pairing = Pairing(
      id: UUID().uuidString.lowercased(),
      name: resolved,
      expiresAt: Self.now() + pairingTTL * 1000
    )
    pairings[Self.digest(code)] = pairing
    return PairingGrant(id: pairing.id, name: pairing.name, expiresAt: pairing.expiresAt, code: code)
  }

  /// Claim a pairing code, issuing a long-lived token.
  ///
  /// The code is consumed before anything else happens, so a claim is single-use even
  /// if the socket upgrade that follows fails. A client that presents its stable
  /// `clientDeviceId` rotates that installation's existing record instead of creating a
  /// duplicate, which is what stops a phone that re-pairs from filling the list.
  public func claimPairing(code: String, clientDeviceID: String?) -> PairedDevice? {
    lock.lock(); defer { lock.unlock() }
    prunePairings()
    guard !code.isEmpty else { return nil }
    let key = Self.digest(code)
    guard let pairing = pairings[key] else { return nil }
    pairings.removeValue(forKey: key)

    let token = Self.randomToken()
    let normalizedClientID = Self.normalizeClientDeviceID(clientDeviceID)

    if let normalizedClientID,
       let index = devices.firstIndex(where: { $0.revokedAt == nil && $0.clientDeviceId == normalizedClientID }) {
      devices[index].name = pairing.name
      devices[index].tokenHash = Self.digest(token)
      devices[index].clientDeviceId = normalizedClientID
      try? save()
      return PairedDevice(device: summary(of: devices[index]), token: token)
    }

    let device = StoredDevice(
      id: pairing.id,
      name: pairing.name,
      clientDeviceId: normalizedClientID,
      tokenHash: Self.digest(token),
      createdAt: Self.now(),
      lastSeenAt: nil,
      revokedAt: nil
    )
    devices.append(device)
    try? save()
    return PairedDevice(device: summary(of: device), token: token)
  }

  // MARK: - Authentication

  /// Verify a long-lived token. Returns the device, or `nil` when the token is unknown
  /// or revoked.
  ///
  /// A device paired before installation IDs existed is bound to the client's stable ID
  /// on first successful use — a valid token already proves ownership of the record, so
  /// this avoids a duplicate row without weakening anything.
  public func authenticate(token: String, clientDeviceID: String?) -> DeviceSummary? {
    guard !token.isEmpty else { return nil }
    lock.lock(); defer { lock.unlock() }
    let hash = Self.digest(token)
    guard let index = devices.firstIndex(where: { $0.revokedAt == nil && Self.constantTimeEquals($0.tokenHash, hash) }) else {
      return nil
    }
    if let normalizedClientID = Self.normalizeClientDeviceID(clientDeviceID), devices[index].clientDeviceId == nil {
      let conflict = devices.indices.contains { other in
        other != index && devices[other].revokedAt == nil && devices[other].clientDeviceId == normalizedClientID
      }
      if !conflict {
        devices[index].clientDeviceId = normalizedClientID
        try? save()
      }
    }
    return summary(of: devices[index])
  }

  /// Record a successful connection. Returns `false` for an unknown or revoked device,
  /// which the caller treats as an authentication failure rather than a bookkeeping
  /// detail.
  @discardableResult
  public func connected(deviceID: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard let index = devices.firstIndex(where: { $0.id == deviceID && $0.revokedAt == nil }) else { return false }
    online[deviceID, default: 0] += 1
    devices[index].lastSeenAt = Self.now()
    try? save()
    return true
  }

  public func disconnected(deviceID: String) {
    lock.lock(); defer { lock.unlock() }
    let current = online[deviceID] ?? 0
    if current <= 1 { online.removeValue(forKey: deviceID) } else { online[deviceID] = current - 1 }
  }

  /// Revoke a device. Revocation deletes the row outright (matching `devices.js`), so
  /// the token hash cannot be replayed and the list stays a list of what is trusted.
  @discardableResult
  public func revoke(deviceID: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard let index = devices.firstIndex(where: { $0.id == deviceID && $0.revokedAt == nil }) else { return false }
    devices.remove(at: index)
    online.removeValue(forKey: deviceID)
    try? save()
    return true
  }

  // MARK: - Storage

  private func load() throws {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch let error as NSError {
      // A missing file is the normal first-run state, not a failure.
      if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return }
      throw RegistryError.unreadable(error.localizedDescription)
    }

    let decoded: Store
    do {
      decoded = try JSONDecoder().decode(Store.self, from: data)
    } catch {
      // Try the v1 shape, which stored a plaintext `token` per row instead of
      // `tokenHash`. Decoding it structurally keeps the migration in one place.
      if let legacy = try? JSONDecoder().decode(LegacyStore.self, from: data) {
        devices = legacy.devices.compactMap { row in
          guard let token = row.token, !token.isEmpty else { return nil }
          return StoredDevice(
            id: row.id,
            name: String(row.name.prefix(80)),
            clientDeviceId: Self.normalizeClientDeviceID(row.clientDeviceId),
            tokenHash: Self.digest(token),
            createdAt: row.createdAt ?? Self.now(),
            lastSeenAt: row.lastSeenAt,
            revokedAt: row.revokedAt ?? (row.revoked == true ? Self.now() : nil)
          )
        }
        try save()
        return
      }
      throw RegistryError.unreadable("failed to load device registry: \(error.localizedDescription)")
    }

    var migrated = false
    devices = decoded.devices.compactMap { row in
      guard !row.id.isEmpty, !row.name.isEmpty else { return nil }
      guard Self.isDigest(row.tokenHash) else { return nil }
      return StoredDevice(
        id: row.id,
        name: String(row.name.prefix(80)),
        clientDeviceId: Self.normalizeClientDeviceID(row.clientDeviceId),
        tokenHash: row.tokenHash,
        createdAt: row.createdAt.isFinite ? row.createdAt : Self.now(),
        lastSeenAt: row.lastSeenAt?.isFinite == true ? row.lastSeenAt : nil,
        revokedAt: row.revokedAt?.isFinite == true ? row.revokedAt : nil
      )
    }
    if decoded.version != Self.storeVersion { migrated = true }
    if migrated {
      try save()
    } else {
      // Re-assert the mode: the file holds token digests and a group-readable bit would
      // expose them to every account on the machine.
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
  }

  private func save() throws {
    let directory = file.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw RegistryError.unwritable(error.localizedDescription)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    var payload = try encoder.encode(Store(version: Self.storeVersion, devices: devices))
    payload.append(0x0A)

    // Write-then-rename: a reader either sees the previous registry or the complete new
    // one, never a half-written list of trusted devices.
    let temporary = directory.appendingPathComponent("\(file.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
    do {
      try payload.write(to: temporary, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw RegistryError.unwritable(error.localizedDescription)
    }
  }

  // MARK: - Helpers

  private func summary(of device: StoredDevice) -> DeviceSummary {
    let connections = online[device.id] ?? 0
    return DeviceSummary(
      id: device.id,
      name: device.name,
      createdAt: device.createdAt,
      lastSeenAt: device.lastSeenAt,
      online: connections > 0,
      connections: connections
    )
  }

  private func prunePairings() {
    let now = Self.now()
    for (key, pairing) in pairings where pairing.expiresAt <= now {
      pairings.removeValue(forKey: key)
    }
  }

  static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

  /// A SHA-256 digest as lowercase hex — the only form a token ever takes on disk.
  static func digest(_ secret: String) -> String {
    let hash = SHA256.hash(data: Data(secret.utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  static func isDigest(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  /// 32 random bytes, Base64URL, unpadded — the encoding both pairing codes and device
  /// tokens use on the wire.
  static func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
    return Data(bytes).base64URLEncodedString()
  }

  /// The client's installation identifier. Bounded and character-restricted because it
  /// is echoed into device rows and compared on every reconnect.
  static func normalizeClientDeviceID(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 8, trimmed.count <= 128 else { return nil }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return trimmed
  }

  /// Length-independent, branch-free comparison of two hex digests.
  static func constantTimeEquals(_ left: String, _ right: String) -> Bool {
    let a = Array(left.utf8)
    let b = Array(right.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in a.indices { difference |= a[index] ^ b[index] }
    return difference == 0
  }
}

/// The `version: 1` registry shape, kept solely so an existing installation's devices
/// survive the upgrade with their tokens re-hashed instead of revoked.
private struct LegacyStore: Codable {
  struct Row: Codable {
    var id: String
    var name: String
    var clientDeviceId: String?
    var token: String?
    var createdAt: Double?
    var lastSeenAt: Double?
    var revokedAt: Double?
    var revoked: Bool?
  }
  var version: Int
  var devices: [Row]
}

extension Data {
  /// Base64URL without padding — the one encoding the pairing payload and device
  /// tokens use, chosen because `+`, `/`, and `=` survive neither a QR code nor a
  /// double-click copy.
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
