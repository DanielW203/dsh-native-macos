import Foundation

/// One file a checkpoint kept a copy of, identified by content rather than by time.
///
/// A digest rather than "was it modified after the checkpoint" because the question the
/// preview answers is "what would restore change", and a file rewritten with the same
/// bytes is not a change worth reporting.
public struct ProfileCheckpointFile: Codable, Sendable, Equatable {
  /// Relative to the runtime root, e.g. `home/profiles/web/package.json`.
  public var path: String
  public var sha256: String
  public var bytes: Int

  public init(path: String, sha256: String, bytes: Int) {
    self.path = path
    self.sha256 = sha256
    self.bytes = bytes
  }
}

/// What one slot holds.
public struct ProfileCheckpointRecord: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var createdAt: String
  /// `healthy-start` for a checkpoint taken by a successful boot, `restored` for the first
  /// one written after a restore.
  public var reason: String
  public var profile: String
  public var harnessRelease: String?
  public var files: [ProfileCheckpointFile]

  public init(
    id: String,
    createdAt: String,
    reason: String,
    profile: String,
    harnessRelease: String? = nil,
    files: [ProfileCheckpointFile]
  ) {
    self.id = id
    self.createdAt = createdAt
    self.reason = reason
    self.profile = profile
    self.harnessRelease = harnessRelease
    self.files = files
  }
}

/// What restoring a slot would change, computed before anything is written.
public struct ProfileCheckpointPreview: Sendable, Equatable {
  public var slot: String
  public var createdAt: String
  public var profile: String
  /// Files whose bytes on disk differ from the checkpoint.
  public var changed: [String]
  /// Files the checkpoint kept that are no longer on disk.
  public var missing: [String]

  public init(slot: String, createdAt: String, profile: String, changed: [String], missing: [String]) {
    self.slot = slot
    self.createdAt = createdAt
    self.profile = profile
    self.changed = changed
    self.missing = missing
  }

  public var isEmpty: Bool { changed.isEmpty && missing.isEmpty }
}

/// What a restore actually wrote.
public struct ProfileCheckpointRestore: Sendable, Equatable {
  public var slot: String
  public var restored: [String]
  /// Files the checkpoint had no copy of. Recorded rather than hidden, because a restored
  /// configuration with a missing file is not the configuration that was saved.
  public var skipped: [String]

  public init(slot: String, restored: [String], skipped: [String]) {
    self.slot = slot
    self.restored = restored
    self.skipped = skipped
  }
}

/// What a window needs to record a boot that worked.
public protocol HealthyStartRecording: Sendable {
  /// - Returns: a line for the window's log, or `nil` when there was nothing to record.
  func recordHealthyStart(profile: String) async -> String?
}

/// Healthy-start checkpoints of a profile's declarative configuration.
///
/// **Why only declarative files.** The failure this exists for is a profile that no longer
/// boots after something edited its configuration — a plugin install that left the bundle
/// list broken, a patch layer written by a tool that no longer applies. Restoring that is
/// a handful of small text files. Restoring `node_modules` would be copying hundreds of
/// megabytes to undo something that re-installing four files fixes, and it would make the
/// rollback path slower than the Web UI it is meant to be available without.
///
/// Nothing here runs pnpm. A restore therefore puts the declaration back and leaves the
/// installed tree alone; the recovery window says so, because "dependencies may need to be
/// reinstalled" is part of the answer rather than an edge case.
public actor ProfileCheckpointStore: HealthyStartRecording {
  /// Exactly three rotating slots, newest wins.
  public static let slots = ["slot-1", "slot-2", "slot-3"]
  static let manifestVersion = 1

  private let paths: RuntimePaths
  private let now: @Sendable () -> Date

  public init(
    paths: RuntimePaths,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.paths = paths
    self.now = now
  }

  // MARK: - Layout

  public nonisolated var checkpointRoot: URL {
    paths.harnessRoot.appendingPathComponent("checkpoints", isDirectory: true)
  }

  /// Pure path arithmetic, so a reader does not have to hop onto the actor to find a slot.
  public nonisolated func directory(_ slot: String) -> URL {
    checkpointRoot.appendingPathComponent(slot, isDirectory: true)
  }

  nonisolated func manifestURL(_ slot: String) -> URL {
    directory(slot).appendingPathComponent("manifest.json", isDirectory: false)
  }

  nonisolated func storedFileURL(_ slot: String, path: String) -> URL {
    directory(slot).appendingPathComponent("files", isDirectory: true).appendingPathComponent(path)
  }

  /// The files a checkpoint covers, relative to the runtime root.
  ///
  /// `cordis.yml` is deliberately absent: the harness rewrites it to an empty entry list on
  /// every boot, so it can never be the thing that broke a start, and restoring a stale one
  /// would be restoring a file the harness ignores. `node_modules`, the plugin disable
  /// ledger, and every backup copy are excluded for the same reason — none of them is
  /// consulted before the boot that fails.
  public static func coveredPaths(profile: String) -> [String] {
    [
      "home/profiles/\(profile)/package.json",
      "home/profiles/\(profile)/pnpm-lock.yaml",
      "home/profiles/\(profile)/pnpm-workspace.yaml",
      "home/profiles/\(profile)/cordis.patch.yml",
      "home/settings.yaml",
      "home/cordis.patch.yml",
    ]
  }

  // MARK: - Recording

  /// Save the current declarative configuration into one slot.
  @discardableResult
  public func record(
    profile: String,
    reason: String = "healthy-start",
    at date: Date? = nil
  ) throws -> ProfileCheckpointRecord {
    let stamp = ISO8601DateFormatter().string(from: date ?? now())
    let slot = try nextSlot()
    let slotDirectory = directory(slot)

    // Replaced wholesale rather than merged: a file the previous checkpoint kept but this
    // one does not would otherwise survive inside the slot, and a restore would put back
    // something this configuration never had.
    if FileManager.default.fileExists(atPath: slotDirectory.path) {
      try FileManager.default.removeItem(at: slotDirectory)
    }

    var files: [ProfileCheckpointFile] = []
    for path in Self.coveredPaths(profile: profile) {
      let source = paths.root.appendingPathComponent(path)
      guard FileManager.default.fileExists(atPath: source.path) else { continue }
      let destination = storedFileURL(slot, path: path)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.copyItem(at: source, to: destination)
      let digest = try ArchiveInspector.sha256(of: destination)
      let bytes = Int(try ArchiveInspector.byteCount(of: destination))
      files.append(ProfileCheckpointFile(path: path, sha256: digest, bytes: bytes))
    }

    let record = ProfileCheckpointRecord(
      id: slot,
      createdAt: stamp,
      reason: reason,
      profile: profile,
      harnessRelease: Self.activeRelease(in: paths),
      files: files
    )
    try write(record)
    return record
  }

  /// The first empty slot, or the one whose manifest is unreadable, or the oldest.
  ///
  /// Empty first matters: for the first three healthy starts nothing should be thrown away.
  /// An unreadable manifest counts as reusable — it is already lost, and leaving it in place
  /// would shrink the pool to two slots forever.
  private func nextSlot() throws -> String {
    let readable = list()
    if readable.count < Self.slots.count {
      let known = Set(readable.map(\.id))
      if let free = Self.slots.first(where: { !known.contains($0) }) { return free }
    }
    return readable.last?.id ?? Self.slots[0]
  }

  private func write(_ record: ProfileCheckpointRecord) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(record)
    try FileManager.default.createDirectory(at: directory(record.id), withIntermediateDirectories: true)
    try data.write(to: manifestURL(record.id), options: .atomic)
  }

  // MARK: - Reading

  /// Every readable slot, newest first.
  ///
  /// A slot whose manifest cannot be decoded is skipped rather than reported as an error:
  /// one unreadable checkpoint must not hide the two good ones behind it.
  public nonisolated func list() -> [ProfileCheckpointRecord] {
    Self.slots
      .compactMap { readManifest(directory($0).appendingPathComponent("manifest.json", isDirectory: false)) }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private nonisolated func readManifest(_ url: URL) -> ProfileCheckpointRecord? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let record = try? JSONDecoder().decode(ProfileCheckpointRecord.self, from: data) else { return nil }
    return record
  }

  public nonisolated func record(for slot: String) -> ProfileCheckpointRecord? {
    readManifest(manifestURL(slot))
  }

  // MARK: - Restoring

  /// What a restore would change, computed without writing anything.
  public func preview(slot: String) throws -> ProfileCheckpointPreview {
    let record = try requireRecord(slot)
    var changed: [String] = []
    var missing: [String] = []
    for file in record.files {
      let current = paths.root.appendingPathComponent(file.path)
      guard let digest = try? ArchiveInspector.sha256(of: current) else {
        missing.append(file.path)
        continue
      }
      if digest != file.sha256 { changed.append(file.path) }
    }
    return ProfileCheckpointPreview(
      slot: slot,
      createdAt: record.createdAt,
      profile: record.profile,
      changed: changed,
      missing: missing
    )
  }

  /// Copy a slot's files back.
  ///
  /// Every stored file is verified before the first byte is written, so a corrupt
  /// checkpoint cannot leave a half-restored configuration behind — a profile that is
  /// neither the saved one nor the current one would be worse than either.
  @discardableResult
  public func restore(slot: String) throws -> ProfileCheckpointRestore {
    let record = try requireRecord(slot)

    var payload: [(file: ProfileCheckpointFile, data: Data)] = []
    var skipped: [String] = []
    for file in record.files {
      let stored = storedFileURL(slot, path: file.path)
      guard let data = try? Data(contentsOf: stored) else {
        skipped.append(file.path)
        continue
      }
      guard data.count == file.bytes, try ArchiveInspector.sha256(of: stored) == file.sha256 else {
        throw RuntimeError.unsupported(
          "checkpoint \(slot) is damaged: \(file.path) does not match its recorded digest"
        )
      }
      payload.append((file, data))
    }

    var restored: [String] = []
    for entry in payload {
      let destination = paths.root.appendingPathComponent(entry.file.path)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try entry.data.write(to: destination, options: .atomic)
      restored.append(entry.file.path)
    }
    return ProfileCheckpointRestore(slot: slot, restored: restored, skipped: skipped)
  }

  public func clear() throws {
    guard FileManager.default.fileExists(atPath: checkpointRoot.path) else { return }
    try FileManager.default.removeItem(at: checkpointRoot)
  }

  private func requireRecord(_ slot: String) throws -> ProfileCheckpointRecord {
    guard let record = readManifest(manifestURL(slot)) else {
      throw RuntimeError.unsupported("no checkpoint in \(slot)")
    }
    return record
  }

  // MARK: - Healthy start

  /// Record the configuration a boot just proved works.
  ///
  /// Failures are reported rather than thrown: never being able to roll back is a missing
  /// safety net, while failing a start that already succeeded would be a regression the
  /// user cannot act on.
  public func recordHealthyStart(profile: String) async -> String? {
    do {
      let record = try record(profile: profile)
      return "Saved a healthy-start checkpoint in \(record.id) (\(record.files.count) file(s))."
    } catch {
      return "Could not save a healthy-start checkpoint: \(error)"
    }
  }

  static func activeRelease(in paths: RuntimePaths) -> String? {
    (try? InstallsIndex.load(from: paths.installsIndex))?.activeRelease?.id
  }
}
