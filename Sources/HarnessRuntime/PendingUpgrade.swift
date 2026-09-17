import Foundation

/// An upgrade this app is in the middle of.
///
/// The marker exists for the same reason `SafeBoot`'s does: the moment between "the new
/// release is now active" and "the new release has been proven to boot" is the one window a
/// crash must not erase. A file says the upgrade is in flight; deleting it says the upgrade
/// reached a conclusion. Nothing is inferred from the presence of a directory, because a
/// directory can be left behind by a crash while a file cannot be left behind by a clean
/// exit.
public struct PendingUpgradeRecord: Codable, Sendable, Equatable {
  /// Bumped when the persisted shape changes. A newer marker is treated as absent rather
  /// than half-understood, so an older build cannot roll a newer upgrade back wrongly.
  public static let currentSchemaVersion = 1

  /// How far the upgrade got. Used to describe an interrupted upgrade honestly: "died before
  /// it activated" and "died while verifying the new version" call for different actions.
  public enum Stage: String, Codable, Sendable, Equatable {
    case activating
    case booting
    case verifying
  }

  public var schemaVersion: Int
  /// The release that was active before this upgrade started — the rollback target.
  public var fromReleaseID: String
  /// The release being moved to.
  public var toReleaseID: String
  /// The profile the runtime was booted with, so a resumed upgrade boots the same one.
  public var profile: String
  public var startedAt: Date
  public var stage: Stage

  public init(
    schemaVersion: Int = PendingUpgradeRecord.currentSchemaVersion,
    fromReleaseID: String,
    toReleaseID: String,
    profile: String,
    startedAt: Date = Date(),
    stage: Stage = .activating
  ) {
    self.schemaVersion = schemaVersion
    self.fromReleaseID = fromReleaseID
    self.toReleaseID = toReleaseID
    self.profile = profile
    self.startedAt = startedAt
    self.stage = stage
  }
}

/// The upgrade marker at `<root>/harness/upgrade-pending.json`.
///
/// Deliberately a value type with non-throwing reads rather than an actor: the console reads
/// it to decide whether a release may be removed, the installer reads it to refuse to delete
/// a rollback target, and the coordinator writes it — and all three would be worse for having
/// to hop through a shared lock to ask a yes/no question.
public struct PendingUpgradeStore: Sendable, Equatable {
  public let url: URL

  public init(paths: RuntimePaths) {
    self.url = paths.harnessRoot.appendingPathComponent("upgrade-pending.json", isDirectory: false)
  }

  public init(url: URL) {
    self.url = url
  }

  /// What reading the marker produced.
  ///
  /// Three outcomes rather than an optional because "there is no marker" and "there is a
  /// marker this build cannot read" are different facts: the second one means a previous run
  /// was interrupted by something this build does not understand, and swallowing it would
  /// leave that unexplained.
  public enum LoadOutcome: Sendable, Equatable {
    case absent
    case record(PendingUpgradeRecord)
    case unreadable(String)
  }

  /// Never throws. A marker that cannot be read is reported, not raised — the caller is
  /// usually on a launch path where the one outcome that must be impossible is a window that
  /// refuses to open because a marker file went bad.
  public func load() -> LoadOutcome {
    guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
    do {
      let data = try Data(contentsOf: url)
      let record = try AtomicFile.makeDecoder().decode(PendingUpgradeRecord.self, from: data)
      guard record.schemaVersion <= PendingUpgradeRecord.currentSchemaVersion else {
        return .unreadable(
          "upgrade-pending.json schemaVersion \(record.schemaVersion) is newer than "
            + "\(PendingUpgradeRecord.currentSchemaVersion)"
        )
      }
      return .record(record)
    } catch {
      return .unreadable(String(describing: error))
    }
  }

  /// The marker, when there is a readable one.
  public var record: PendingUpgradeRecord? {
    if case .record(let record) = load() { return record }
    return nil
  }

  public func save(_ record: PendingUpgradeRecord) throws {
    try AtomicFile.write(try AtomicFile.makeEncoder().encode(record), to: url)
  }

  /// Move the marker forward. A marker that cannot be updated is not fatal — the stage is
  /// diagnostic, and refusing to continue an upgrade because a progress note failed to write
  /// would be the marker deciding the outcome instead of describing it.
  public func advance(to stage: PendingUpgradeRecord.Stage) {
    guard case .record(var record) = load() else { return }
    record.stage = stage
    try? save(record)
  }

  /// The upgrade reached a conclusion. Absent is the same as cleared.
  public func clear() {
    try? FileManager.default.removeItem(at: url)
  }
}
