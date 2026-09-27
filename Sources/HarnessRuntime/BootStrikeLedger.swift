import Foundation

/// How many launches in a row a release has failed to come up, per release.
///
/// **Why this is a file and not a counter.** The failure this exists for happens *between*
/// launches: a release that cannot boot is a release whose app may not be around long enough
/// to remember anything. `HarnessUpgradeCoordinator.resumeIfNeeded()` runs once per launch and
/// is the only thing that decides what an interrupted upgrade means — but on its own it would
/// make that decision from scratch every time, which is how a broken release produces an
/// infinite "isolate, retry, fail" loop instead of a conclusion. A ledger on disk is what lets
/// the second failure be treated differently from the first.
///
/// **Why a strike and not an immediate fallback.** Entering Safe Mode on the first failure
/// would take a user whose plugins simply need disabling on a detour they did not need;
/// falling back immediately would throw away a release that a single quarantine could have
/// saved. Two strikes is the smallest count that tells "this needs a repair" apart from "this
/// is not going to work".
public struct BootStrikeLedger: Sendable, Equatable {
  /// Bumped when the persisted shape changes. A newer file is treated as absent, because
  /// misreading it could escalate a healthy runtime into Safe Mode.
  public static let currentSchemaVersion = 1

  /// After this many consecutive unhealthy launches of one release, the app stops trying to
  /// repair it and says so.
  public static let escalationLimit = 3

  public struct Entry: Codable, Sendable, Equatable {
    public var count: Int
    public var firstAt: Date
    public var lastAt: Date
    /// What the last attempt got to, for the report that explains the escalation.
    public var lastStage: String?

    public init(count: Int, firstAt: Date, lastAt: Date, lastStage: String? = nil) {
      self.count = count
      self.firstAt = firstAt
      self.lastAt = lastAt
      self.lastStage = lastStage
    }
  }

  private struct Payload: Codable {
    var schemaVersion: Int
    var strikes: [String: Entry]
  }

  public let url: URL

  public init(paths: RuntimePaths) {
    self.url = paths.harnessRoot.appendingPathComponent("boot-strikes.json", isDirectory: false)
  }

  public init(url: URL) {
    self.url = url
  }

  /// Every release's count, keyed by release id. Never throws: a ledger that cannot be read
  /// must not be a reason a launch refuses to happen.
  public func entries() -> [String: Entry] {
    guard let data = try? Data(contentsOf: url),
          let payload = try? AtomicFile.makeDecoder().decode(Payload.self, from: data),
          payload.schemaVersion <= Self.currentSchemaVersion
    else { return [:] }
    return payload.strikes
  }

  public func count(forReleaseID id: String) -> Int {
    entries()[id]?.count ?? 0
  }

  /// Record one unhealthy launch of `id`, and return the new count.
  @discardableResult
  public func recordStrike(forReleaseID id: String, stage: String? = nil, at date: Date = Date()) -> Int {
    var payload = Payload(schemaVersion: Self.currentSchemaVersion, strikes: entries())
    var entry = payload.strikes[id] ?? Entry(count: 0, firstAt: date, lastAt: date)
    entry.count += 1
    entry.lastAt = date
    entry.lastStage = stage
    payload.strikes[id] = entry
    try? AtomicFile.write(try AtomicFile.makeEncoder().encode(payload), to: url)
    return entry.count
  }

  /// This release is working: it has no strikes any more.
  public func clear(_ id: String) {
    var payload = Payload(schemaVersion: Self.currentSchemaVersion, strikes: entries())
    guard payload.strikes.removeValue(forKey: id) != nil else { return }
    try? AtomicFile.write(try AtomicFile.makeEncoder().encode(payload), to: url)
  }

  /// Every count is stale, whatever happened: a user who chose a version is the authority on
  /// whether it is worth another try.
  public func clearAll() {
    try? FileManager.default.removeItem(at: url)
  }
}
