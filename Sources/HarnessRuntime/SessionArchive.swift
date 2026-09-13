import Foundation

// MARK: - Manifest

/// The header written at the root of every DSHNative session archive.
///
/// A manifest exists so that import can refuse something that merely *looks* like a
/// session tree: a zip of a project directory has the same shape at a glance, and a
/// restore that guesses would scatter unrelated directories into `$DSH_HOME/sessions`.
/// `schemaVersion` is the other half of the contract — an archive written by a newer
/// build must be refused rather than partially understood.
public struct SessionArchiveManifest: Codable, Sendable, Equatable {
  /// Discriminator that separates this archive from every other zip the app handles
  /// (harness releases, plugin bundles). Carried in the file, not in the name.
  public static let kind = "dshnative-session-archive"
  /// The only layout this build can restore. Bump when the payload shape changes.
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var kind: String
  public var createdAt: Date
  public var appVersion: String?
  public var sessionCount: Int
  public var includesAttachments: Bool
  public var projectKeys: [String]

  public init(
    schemaVersion: Int = SessionArchiveManifest.currentSchemaVersion,
    kind: String = SessionArchiveManifest.kind,
    createdAt: Date,
    appVersion: String? = nil,
    sessionCount: Int,
    includesAttachments: Bool,
    projectKeys: [String]
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.createdAt = createdAt
    self.appVersion = appVersion
    self.sessionCount = sessionCount
    self.includesAttachments = includesAttachments
    self.projectKeys = projectKeys
  }
}

// MARK: - Catalog

/// One session directory found under `$DSH_HOME/sessions`.
///
/// `projectKey` and `sessionID` are the *directory names* as they exist on disk, not
/// decoded ids: this type describes a restore target, and re-deriving the names would
/// put a second implementation of the harness's escaping rules between the two.
public struct SessionArchiveCandidate: Sendable, Equatable, Identifiable {
  public var projectKey: String
  public var sessionID: String
  public var directory: URL
  /// The newest `session*.jsonl.zstd` in the directory, or `nil` when it holds none yet.
  public var logURL: URL?
  public var logBytes: Int64
  public var modifiedAt: Date?

  public init(
    projectKey: String,
    sessionID: String,
    directory: URL,
    logURL: URL?,
    logBytes: Int64,
    modifiedAt: Date?
  ) {
    self.projectKey = projectKey
    self.sessionID = sessionID
    self.directory = directory
    self.logURL = logURL
    self.logBytes = logBytes
    self.modifiedAt = modifiedAt
  }

  public var id: String { "\(projectKey)/\(sessionID)" }
}

/// Reads the on-disk layout the harness owns.
///
/// Read-only by construction: the catalog never creates, rewrites, or locks anything
/// inside the harness home, so opening the backup window cannot perturb a running
/// harness.
public enum SessionArchiveCatalog {
  /// Every session directory under `sessions/<projectKey>/<sessionID>/`.
  ///
  /// A missing root is an empty list, not an error: a fresh install has no sessions yet,
  /// and the window must be able to say so. Ordering is newest-modified first, which is
  /// also the order the harness's own session list uses.
  public static func scan(dshHome: URL) -> [SessionArchiveCandidate] {
    let manager = FileManager.default
    let root = dshHome.appendingPathComponent("sessions", isDirectory: true)
    guard let projectNames = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }

    var candidates: [SessionArchiveCandidate] = []
    for project in projectNames.sorted() {
      let projectURL = root.appendingPathComponent(project, isDirectory: true)
      guard (try? projectURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
      guard let sessionNames = try? manager.contentsOfDirectory(atPath: projectURL.path) else { continue }
      for session in sessionNames.sorted() {
        let sessionURL = projectURL.appendingPathComponent(session, isDirectory: true)
        guard (try? sessionURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
        let log = logFile(inSessionDirectory: sessionURL)
        let logBytes = log.flatMap { try? ArchiveInspector.byteCount(of: $0) } ?? 0
        let modified = (try? sessionURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        candidates.append(SessionArchiveCandidate(
          projectKey: project,
          sessionID: session,
          directory: sessionURL,
          logURL: log,
          logBytes: logBytes,
          modifiedAt: modified
        ))
      }
    }
    return candidates.sorted { lhs, rhs in
      (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
    }
  }

  /// The append-only log inside one session directory.
  ///
  /// The same rule as `SessionPaths.logFile` in `HarnessIM`, restated here because this
  /// module may not depend on that one (CONTRACT §1). The version segment is a
  /// format-catalog concern, so matching is by shape and the newest wins.
  public static func logFile(inSessionDirectory directory: URL) -> URL? {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return nil }
    let logs = names
      .filter { $0.hasPrefix("session") && $0.hasSuffix(".jsonl.zstd") }
      .map { directory.appendingPathComponent($0) }
    return logs.max { lhs, rhs in
      let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      return left < right
    }
  }
}

// MARK: - Errors

/// Failures specific to session archive export/import.
///
/// Separate from `RuntimeError` because these are not install failures: the archive
/// codec deals in user data, and the messages it produces are read by someone deciding
/// whether to overwrite a session rather than by someone diagnosing a broken toolchain.
public enum SessionArchiveError: Error, LocalizedError, Sendable, Equatable {
  /// Export was asked for nothing.
  case noSessions
  /// Refused rather than replaced: an export must never silently eat an existing file.
  case destinationExists(String)
  /// A zip that is not one of ours — no manifest, or a manifest naming another payload.
  case notDshnativeArchive(String)
  /// Written by a newer build; refusing is safer than importing it half-way.
  case unsupportedSchemaVersion(found: Int, supported: Int)
  case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
  /// Filesystem work that failed, with the reason kept verbatim.
  case io(String)

  public var errorDescription: String? {
    switch self {
    case .noSessions:
      return "没有可导出的会话日志。"
    case .destinationExists(let path):
      return "目标文件已存在，未覆盖：\(path)"
    case .notDshnativeArchive(let detail):
      return "这不是 DSHNative 会话备份：\(detail)"
    case .unsupportedSchemaVersion(let found, let supported):
      return "备份格式版本为 \(found)，本版本最高支持 \(supported)，请升级 DSHNative 后再导入。"
    case .insufficientSpace(let required, let available):
      return "磁盘空间不足：需要约 \(Self.megabytes(required)) MB，可用 \(Self.megabytes(available)) MB。"
    case .io(let detail):
      return detail
    }
  }

  private static func megabytes(_ bytes: Int64) -> Int64 {
    max(1, bytes / (1024 * 1024))
  }
}

// MARK: - Results

public struct SessionArchiveOutcome: Sendable, Equatable {
  public var archiveURL: URL
  public var manifest: SessionArchiveManifest
  public var bytes: Int64
  public var duration: TimeInterval

  public init(archiveURL: URL, manifest: SessionArchiveManifest, bytes: Int64, duration: TimeInterval) {
    self.archiveURL = archiveURL
    self.manifest = manifest
    self.bytes = bytes
    self.duration = duration
  }
}

public struct ImportedSession: Sendable, Equatable, Identifiable {
  public var projectKey: String
  public var sessionID: String
  public var destination: URL
  /// True when the target directory already existed and only its missing log was filled
  /// in — the one case where an import writes into an existing session directory.
  public var filledInLog: Bool

  public var id: String { "\(projectKey)/\(sessionID)" }

  public init(projectKey: String, sessionID: String, destination: URL, filledInLog: Bool) {
    self.projectKey = projectKey
    self.sessionID = sessionID
    self.destination = destination
    self.filledInLog = filledInLog
  }
}

public struct SkippedSession: Sendable, Equatable, Identifiable {
  public var projectKey: String
  public var sessionID: String
  public var reason: String

  public var id: String { "\(projectKey)/\(sessionID)" }

  public init(projectKey: String, sessionID: String, reason: String) {
    self.projectKey = projectKey
    self.sessionID = sessionID
    self.reason = reason
  }
}

public struct SessionImportReport: Sendable, Equatable {
  public var archiveURL: URL
  public var manifest: SessionArchiveManifest?
  public var imported: [ImportedSession]
  public var skipped: [SkippedSession]
  public var attachmentsImported: Int
  public var attachmentsSkipped: Int
  public var duration: TimeInterval

  public init(
    archiveURL: URL,
    manifest: SessionArchiveManifest?,
    imported: [ImportedSession],
    skipped: [SkippedSession],
    attachmentsImported: Int,
    attachmentsSkipped: Int,
    duration: TimeInterval
  ) {
    self.archiveURL = archiveURL
    self.manifest = manifest
    self.imported = imported
    self.skipped = skipped
    self.attachmentsImported = attachmentsImported
    self.attachmentsSkipped = attachmentsSkipped
    self.duration = duration
  }
}

// MARK: - Service

/// Exports and restores the harness's session logs as a zip.
///
/// Two rules shape everything here:
///
/// 1. **Read-only where the harness is concerned.** Export only reads `sessions/` and
///    `attachments/`; import only writes into those same two directories. Nothing in
///    `profiles/`, `settings.yaml`, `.credentials.yaml`, or `cordis.yml` is ever included
///    — a backup that is meant to be copied to another machine must not carry credentials.
/// 2. **Never overwrite a session.** Import skips a session that already exists unless it
///    has no log at all, and the only file it will fill into an existing directory is that
///    missing log. A restore that could replace a newer log with an older one is not a
///    restore.
public struct SessionArchiveService: Sendable {
  /// Files whose names end in this suffix are runtime leases, not session data
  /// (`session.lock`, `LEASE_FILENAME` in the harness's own persistence package). They
  /// are excluded from every archive: a restored lease would describe a lock the
  /// importing process does not hold.
  public static let excludedSuffix = ".lock"

  private let runner: any ProcessRunning
  private let inspector: ArchiveInspector

  public init(runner: any ProcessRunning = ProcessRunner()) {
    self.runner = runner
    self.inspector = ArchiveInspector(runner: runner)
  }

  // MARK: Export

  /// Write `sessions` (plus `attachments/` when asked) into one zip at `destination`.
  ///
  /// The payload is assembled in staging and then archived with `ditto`, the same tool
  /// `ArchiveInspector` unpacks with, so a round trip cannot diverge on attribute
  /// handling. Staging is removed on every exit path.
  public func export(
    sessions: [SessionArchiveCandidate],
    dshHome: URL,
    stagingRoot: URL,
    to destination: URL,
    includeAttachments: Bool,
    now: Date = Date()
  ) async throws -> SessionArchiveOutcome {
    guard !sessions.isEmpty else { throw SessionArchiveError.noSessions }
    let started = Date()

    let manager = FileManager.default
    if manager.fileExists(atPath: destination.path) {
      throw SessionArchiveError.destinationExists(destination.path)
    }
    try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

    let operationID = "session-export-\(UUID().uuidString)"
    let operationRoot = stagingRoot.appendingPathComponent(operationID, isDirectory: true)
    let payloadName = Self.payloadDirectoryName(now: now)
    let payload = operationRoot.appendingPathComponent(payloadName, isDirectory: true)
    try manager.createDirectory(at: payload, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: operationRoot) }

    // 1. Session directories, one file at a time so the lease files can be left out.
    var copiedSessions = 0
    for candidate in sessions {
      let sourceFiles = (try? manager.contentsOfDirectory(atPath: candidate.directory.path)) ?? []
      let dataFiles = sourceFiles.filter { !$0.hasSuffix(Self.excludedSuffix) }
      guard !dataFiles.isEmpty else { continue }
      let targetDirectory = payload
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(candidate.projectKey, isDirectory: true)
        .appendingPathComponent(candidate.sessionID, isDirectory: true)
      try manager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
      for name in dataFiles {
        try copy(
          from: candidate.directory.appendingPathComponent(name),
          to: targetDirectory.appendingPathComponent(name)
        )
      }
      copiedSessions += 1
    }
    guard copiedSessions > 0 else { throw SessionArchiveError.noSessions }

    // 2. Attachments, kept only when asked for: they are what makes restored sessions
    //    still show their images, and also the bulk of the payload.
    if includeAttachments {
      let attachments = dshHome.appendingPathComponent("attachments", isDirectory: true)
      if manager.fileExists(atPath: attachments.path) {
        try copyTree(from: attachments, to: payload.appendingPathComponent("attachments", isDirectory: true))
      }
    }

    // 3. The manifest that makes this archive self-describing.
    let manifest = SessionArchiveManifest(
      createdAt: now,
      appVersion: Self.appVersion(),
      sessionCount: copiedSessions,
      includesAttachments: includeAttachments,
      projectKeys: Array(Set(sessions.map(\.projectKey))).sorted()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: payload.appendingPathComponent("manifest.json"))

    // 4. Space check before ditto, so a full disk is reported as such.
    let payloadBytes = ArchiveInspector.byteCount(ofDirectory: payload)
    let available = (try? ArchiveInspector.availableBytes(at: stagingRoot)) ?? Int64.max
    if available < payloadBytes {
      throw SessionArchiveError.insufficientSpace(requiredBytes: payloadBytes, availableBytes: available)
    }

    // 5. Archive. `--keepParent` is what puts the named payload directory inside the zip
    //    instead of spilling its children at the root, which is what import looks for.
    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let result = try await runner.run(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, destination.path],
        timeout: 3600,
        label: "ditto -c -k \(payloadName)"
      ),
      onLine: nil
    )
    guard result.succeeded else {
      throw SessionArchiveError.io(
        "打包失败（ditto 退出码 \(result.exitCode)）：\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }

    return SessionArchiveOutcome(
      archiveURL: destination,
      manifest: manifest,
      bytes: (try? ArchiveInspector.byteCount(of: destination)) ?? payloadBytes,
      duration: Date().timeIntervalSince(started)
    )
  }

  // MARK: Import

  /// Restore a session archive into `dshHome`, skipping anything that already exists.
  ///
  /// Validation happens before extraction, extraction into staging before any move into
  /// `sessions/`, so a rejected archive leaves the harness home untouched.
  public func importArchive(
    _ archive: URL,
    dshHome: URL,
    stagingRoot: URL
  ) async throws -> SessionImportReport {
    let started = Date()
    let manager = FileManager.default

    // 1. Refuse traversal, absolute entries, NUL bytes and absurd entry counts before
    //    anything is written. `ArchiveInspector` owns that rule; this only calls it.
    try await inspector.validateEntries(of: archive)

    try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    let operationRoot = stagingRoot.appendingPathComponent("session-import-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: operationRoot, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: operationRoot) }

    // 2. Unpack into staging. `extract` refuses directories, so `kind` is checked first.
    let kind = try ArchiveInspector.kind(of: archive)
    guard kind != .directory else {
      throw SessionArchiveError.notDshnativeArchive("\(archive.lastPathComponent) 是一个目录")
    }
    try await inspector.extract(archive, to: operationRoot)

    // 3. Find the payload root. `ditto --keepParent` leaves exactly one directory, but a
    //    hand-made zip may put `manifest.json` at the root; both are accepted.
    guard let payload = Self.findPayloadRoot(in: operationRoot) else {
      throw SessionArchiveError.notDshnativeArchive("压缩包里没有 manifest.json")
    }
    let manifest: SessionArchiveManifest?
    do {
      let data = try Data(contentsOf: payload.appendingPathComponent("manifest.json"))
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let decoded = try decoder.decode(SessionArchiveManifest.self, from: data)
      guard decoded.kind == SessionArchiveManifest.kind else {
        throw SessionArchiveError.notDshnativeArchive("manifest.json 的 kind 是 \(decoded.kind)")
      }
      guard decoded.schemaVersion <= SessionArchiveManifest.currentSchemaVersion else {
        throw SessionArchiveError.unsupportedSchemaVersion(
          found: decoded.schemaVersion,
          supported: SessionArchiveManifest.currentSchemaVersion
        )
      }
      manifest = decoded
    } catch let error as SessionArchiveError {
      throw error
    } catch {
      throw SessionArchiveError.notDshnativeArchive("manifest.json 无法解析：\(error.localizedDescription)")
    }

    let payloadSessions = payload.appendingPathComponent("sessions", isDirectory: true)
    guard manager.fileExists(atPath: payloadSessions.path) else {
      throw SessionArchiveError.notDshnativeArchive("压缩包里没有 sessions/ 目录")
    }

    // 4. Merge. Everything below this line writes only inside `$DSH_HOME/sessions`.
    let sessionsRoot = dshHome.appendingPathComponent("sessions", isDirectory: true)
    try manager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

    var imported: [ImportedSession] = []
    var skipped: [SkippedSession] = []
    for project in (try? manager.contentsOfDirectory(atPath: payloadSessions.path))?.sorted() ?? [] {
      let projectURL = payloadSessions.appendingPathComponent(project, isDirectory: true)
      guard (try? projectURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
      for session in (try? manager.contentsOfDirectory(atPath: projectURL.path))?.sorted() ?? [] {
        let sourceURL = projectURL.appendingPathComponent(session, isDirectory: true)
        guard (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
        let targetURL = sessionsRoot
          .appendingPathComponent(project, isDirectory: true)
          .appendingPathComponent(session, isDirectory: true)
        do {
          if !manager.fileExists(atPath: targetURL.path) {
            try manager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Same volume as staging, so this is a rename, not a copy: a partially
            // written session directory cannot appear.
            try manager.moveItem(at: sourceURL, to: targetURL)
            imported.append(ImportedSession(
              projectKey: project, sessionID: session, destination: targetURL, filledInLog: false
            ))
          } else if SessionArchiveCatalog.logFile(inSessionDirectory: targetURL) == nil,
                    let sourceLog = SessionArchiveCatalog.logFile(inSessionDirectory: sourceURL) {
            // The one sanctioned write into an existing session directory: it has no log
            // yet, so filling in the archived one cannot destroy anything.
            try manager.moveItem(at: sourceLog, to: targetURL.appendingPathComponent(sourceLog.lastPathComponent))
            imported.append(ImportedSession(
              projectKey: project, sessionID: session, destination: targetURL, filledInLog: true
            ))
          } else {
            skipped.append(SkippedSession(
              projectKey: project, sessionID: session, reason: "本机已有同名会话，未覆盖"
            ))
          }
        } catch {
          skipped.append(SkippedSession(
            projectKey: project, sessionID: session, reason: error.localizedDescription
          ))
        }
      }
    }

    // 5. Attachments, added only where a file of that name does not already exist.
    var attachmentsImported = 0
    var attachmentsSkipped = 0
    let payloadAttachments = payload.appendingPathComponent("attachments", isDirectory: true)
    if manager.fileExists(atPath: payloadAttachments.path) {
      let targetAttachments = dshHome.appendingPathComponent("attachments", isDirectory: true)
      let files = Self.relativeFiles(under: payloadAttachments)
      for relative in files {
        let source = payloadAttachments.appendingPathComponent(relative)
        let target = targetAttachments.appendingPathComponent(relative)
        if manager.fileExists(atPath: target.path) {
          attachmentsSkipped += 1
          continue
        }
        do {
          try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          try manager.copyItem(at: source, to: target)
          attachmentsImported += 1
        } catch {
          attachmentsSkipped += 1
        }
      }
    }

    return SessionImportReport(
      archiveURL: archive,
      manifest: manifest,
      imported: imported,
      skipped: skipped,
      attachmentsImported: attachmentsImported,
      attachmentsSkipped: attachmentsSkipped,
      duration: Date().timeIntervalSince(started)
    )
  }

  // MARK: Helpers

  /// The directory the archive names inside itself, e.g. `dshnative-sessions-20260912-1800`.
  public static func payloadDirectoryName(now: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmm"
    return "dshnative-sessions-\(formatter.string(from: now))"
  }

  /// The bundle version, recorded for forensics. Absent in a test runner and in the CLI.
  static func appVersion() -> String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  /// The first directory (or the root itself) that carries a `manifest.json`.
  static func findPayloadRoot(in root: URL) -> URL? {
    let manager = FileManager.default
    if manager.fileExists(atPath: root.appendingPathComponent("manifest.json").path) { return root }
    let children = (try? manager.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
    for child in children {
      let candidate = root.appendingPathComponent(child, isDirectory: true)
      guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
      if manager.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) { return candidate }
    }
    return nil
  }

  /// Every regular file under `root`, as paths relative to `root`.
  ///
  /// `subpathsOfDirectory` rather than an enumerator plus prefix arithmetic: the
  /// enumerator hands back URLs whose `/var` prefix may already be resolved to
  /// `/private/var` (a measured difference between the URL this app constructs and the
  /// ones `FileManager` returns on this machine), and subtracting two such paths
  /// silently eats leading characters. This API returns relative paths directly, so
  /// there is no prefix to get wrong.
  static func relativeFiles(under root: URL) -> [String] {
    let manager = FileManager.default
    guard let subpaths = try? manager.subpathsOfDirectory(atPath: root.path) else { return [] }
    var files: [String] = []
    for relative in subpaths {
      let url = root.appendingPathComponent(relative)
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      files.append(relative)
    }
    return files.sorted()
  }

  private func copy(from source: URL, to destination: URL) throws {
    do {
      try FileManager.default.copyItem(at: source, to: destination)
    } catch {
      throw SessionArchiveError.io("复制 \(source.lastPathComponent) 失败：\(error.localizedDescription)")
    }
  }

  /// Copy a whole directory tree.
  ///
  /// One `copyItem` on the root rather than a per-entry walk: the attachment tree is
  /// content-addressed in sharded subdirectories, and the destination does not exist yet
  /// (it is inside a fresh staging payload), so there is nothing to merge. Walking it by
  /// hand would also repeat the relative-path arithmetic that `relativeFiles` avoids.
  private func copyTree(from source: URL, to destination: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.copyItem(at: source, to: destination)
    } catch {
      throw SessionArchiveError.io("复制 \(source.lastPathComponent) 失败：\(error.localizedDescription)")
    }
  }
}
