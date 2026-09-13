import Foundation
import XCTest
@testable import HarnessRuntime

/// Session archive export/import.
///
/// The archive path runs through real `ditto`/`unzip` on purpose: the attributes, the
/// `--keepParent` layout and the lease-file exclusion are exactly the parts a stub would
/// paper over, and the round trip is the assertion that matters.
final class SessionArchiveTests: XCTestCase {
  private let runner = ProcessRunner()
  private let service = SessionArchiveService()

  // MARK: - Fixtures

  /// A `$DSH_HOME` holding the given sessions, each with a log file and a lease file.
  private func makeDshHome(
    _ testCase: XCTestCase,
    sessions: [(project: String, session: String, contents: String)],
    attachments: [String: String] = [:]
  ) throws -> URL {
    let root = try TestSupport.makeRoot(testCase)
    let home = root.appendingPathComponent("home", isDirectory: true)
    for session in sessions {
      let directory = home
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(session.project, isDirectory: true)
        .appendingPathComponent(session.session, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(session.contents.utf8).write(to: directory.appendingPathComponent("session.v3.jsonl.zstd"))
      // The lease file every real session directory carries.
      try Data().write(to: directory.appendingPathComponent("session.lock"))
    }
    for (name, contents) in attachments {
      let file = home.appendingPathComponent("attachments").appendingPathComponent(name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: file)
    }
    return home
  }

  private func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
    try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: executable), arguments: arguments), onLine: nil)
  }

  private func entries(of zip: URL) async throws -> [String] {
    let result = try await run("/usr/bin/unzip", ["-Z1", zip.path])
    XCTAssertTrue(result.succeeded, result.diagnostics())
    return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }

  // MARK: - Catalog

  func testScanFindsSessionDirectoriesAndTheirLogs() throws {
    let home = try makeDshHome(self, sessions: [
      ("--Users-me-Documents-a--", "session-1111", "one"),
      ("--Users-me-Documents-a--", "session-2222", "two"),
      ("--Users-me-Documents-b--", "session-3333", "three"),
    ])
    let candidates = SessionArchiveCatalog.scan(dshHome: home)

    XCTAssertEqual(candidates.count, 3)
    XCTAssertEqual(Set(candidates.map(\.id)), [
      "--Users-me-Documents-a--/session-1111",
      "--Users-me-Documents-a--/session-2222",
      "--Users-me-Documents-b--/session-3333",
    ])
    XCTAssertTrue(candidates.allSatisfy { $0.logURL?.lastPathComponent == "session.v3.jsonl.zstd" })
    XCTAssertTrue(candidates.allSatisfy { $0.logBytes > 0 })
  }

  func testScanOfMissingRootIsEmptyRatherThanAnError() throws {
    let root = try TestSupport.makeRoot(self)
    XCTAssertEqual(SessionArchiveCatalog.scan(dshHome: root).count, 0)
  }

  func testLogFilePrefersTheNewestGeneration() throws {
    let root = try TestSupport.makeRoot(self)
    let directory = root.appendingPathComponent("session-1", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: directory.appendingPathComponent("session.v2.jsonl.zstd"))
    try Data("new".utf8).write(to: directory.appendingPathComponent("session.v3.jsonl.zstd"))
    try Data("lease".utf8).write(to: directory.appendingPathComponent("session.lock"))

    XCTAssertEqual(SessionArchiveCatalog.logFile(inSessionDirectory: directory)?.lastPathComponent,
                   "session.v3.jsonl.zstd")
  }

  // MARK: - Export

  func testExportWritesManifestAndSessionLogsButNoLeaseFiles() async throws {
    let home = try makeDshHome(self, sessions: [
      ("--Users-me-Documents-a--", "session-1111", "one"),
    ])
    let root = try TestSupport.makeRoot(self)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let destination = root.appendingPathComponent("out.zip")

    let outcome = try await service.export(
      sessions: SessionArchiveCatalog.scan(dshHome: home),
      dshHome: home,
      stagingRoot: staging,
      to: destination,
      includeAttachments: false
    )

    XCTAssertEqual(outcome.manifest.sessionCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    let names = try await entries(of: destination)
    XCTAssertTrue(names.contains { $0.hasSuffix("/manifest.json") }, names.joined(separator: "\n"))
    XCTAssertTrue(names.contains { $0.hasSuffix("session.v3.jsonl.zstd") }, names.joined(separator: "\n"))
    // A restored lease would claim a lock the importing process does not hold.
    XCTAssertFalse(names.contains { $0.hasSuffix("session.lock") }, names.joined(separator: "\n"))
    // Staging is cleaned on the way out.
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    XCTAssertTrue(leftovers.isEmpty, leftovers.joined(separator: ", "))
  }

  func testExportIncludesAttachmentsOnlyWhenAsked() async throws {
    let home = try makeDshHome(
      self,
      sessions: [("--a--", "session-1", "log")],
      attachments: ["v1/objects/ab/CD": "image-bytes"]
    )
    let root = try TestSupport.makeRoot(self)

    let withAttachments = root.appendingPathComponent("with.zip")
    _ = try await service.export(
      sessions: SessionArchiveCatalog.scan(dshHome: home),
      dshHome: home,
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      to: withAttachments,
      includeAttachments: true
    )
    let withNames = try await entries(of: withAttachments)
    XCTAssertTrue(withNames.contains { $0.hasSuffix("v1/objects/ab/CD") }, withNames.joined(separator: "\n"))

    let without = root.appendingPathComponent("without.zip")
    _ = try await service.export(
      sessions: SessionArchiveCatalog.scan(dshHome: home),
      dshHome: home,
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      to: without,
      includeAttachments: false
    )
    let withoutNames = try await entries(of: without)
    XCTAssertFalse(withoutNames.contains { $0.contains("attachments") }, withoutNames.joined(separator: "\n"))
  }

  func testExportRefusesAnEmptySelection() async throws {
    let home = try makeDshHome(self, sessions: [])
    let root = try TestSupport.makeRoot(self)
    do {
      _ = try await service.export(
        sessions: [],
        dshHome: home,
        stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
        to: root.appendingPathComponent("out.zip"),
        includeAttachments: false
      )
      XCTFail("expected a refusal")
    } catch let error as SessionArchiveError {
      XCTAssertEqual(error, .noSessions)
    }
  }

  func testExportRefusesToReplaceAnExistingFile() async throws {
    let home = try makeDshHome(self, sessions: [("--a--", "session-1", "log")])
    let root = try TestSupport.makeRoot(self)
    let destination = root.appendingPathComponent("out.zip")
    try Data("not mine".utf8).write(to: destination)

    do {
      _ = try await service.export(
        sessions: SessionArchiveCatalog.scan(dshHome: home),
        dshHome: home,
        stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
        to: destination,
        includeAttachments: false
      )
      XCTFail("expected a refusal")
    } catch let error as SessionArchiveError {
      XCTAssertEqual(error, .destinationExists(destination.path))
      let kept = try String(contentsOf: destination, encoding: .utf8)
      XCTAssertEqual(kept, "not mine")
    }
  }

  // MARK: - Import

  func testImportRoundTripRestoresSessionLogsByteForByte() async throws {
    let sourceHome = try makeDshHome(
      self,
      sessions: [
        ("--Users-me-Documents-a--", "session-1111", "first session"),
        ("--Users-me-Documents-b--", "session-2222", "second session"),
      ],
      attachments: ["v1/objects/ab/CD": "image-bytes"]
    )
    let root = try TestSupport.makeRoot(self)
    let archive = root.appendingPathComponent("backup.zip")
    _ = try await service.export(
      sessions: SessionArchiveCatalog.scan(dshHome: sourceHome),
      dshHome: sourceHome,
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      to: archive,
      includeAttachments: true
    )

    // A machine that has lost everything.
    let targetHome = root.appendingPathComponent("home", isDirectory: true)
    let report = try await service.importArchive(
      archive,
      dshHome: targetHome,
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
    )

    XCTAssertEqual(report.imported.count, 2)
    XCTAssertTrue(report.skipped.isEmpty, report.skipped.map(\.reason).joined(separator: "; "))
    XCTAssertEqual(report.manifest?.sessionCount, 2)
    XCTAssertEqual(report.attachmentsImported, 1)

    let restored = SessionArchiveCatalog.scan(dshHome: targetHome)
    XCTAssertEqual(Set(restored.map(\.id)), [
      "--Users-me-Documents-a--/session-1111",
      "--Users-me-Documents-b--/session-2222",
    ])
    for (session, expected) in [("session-1111", "first session"), ("session-2222", "second session")] {
      let candidate = try XCTUnwrap(restored.first { $0.sessionID == session })
      let log = try XCTUnwrap(candidate.logURL)
      XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), expected)
      // The lease file is regenerated by the importing instance, never restored.
      XCTAssertFalse(FileManager.default.fileExists(
        atPath: candidate.directory.appendingPathComponent("session.lock").path
      ))
    }
    XCTAssertEqual(
      try String(contentsOf: targetHome.appendingPathComponent("attachments/v1/objects/ab/CD"), encoding: .utf8),
      "image-bytes"
    )
  }

  func testImportNeverOverwritesAnExistingSession() async throws {
    let home = try makeDshHome(self, sessions: [("--a--", "session-1", "original")])
    let root = try TestSupport.makeRoot(self)
    let archive = root.appendingPathComponent("backup.zip")
    _ = try await service.export(
      sessions: SessionArchiveCatalog.scan(dshHome: home),
      dshHome: home,
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      to: archive,
      includeAttachments: false
    )

    // The local copy moved on after the backup was taken.
    let localLog = home
      .appendingPathComponent("sessions/--a--/session-1/session.v3.jsonl.zstd")
    try Data("newer".utf8).write(to: localLog)

    let report = try await service.importArchive(
      archive,
      dshHome: home,
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
    )

    XCTAssertTrue(report.imported.isEmpty)
    XCTAssertEqual(report.skipped.count, 1)
    XCTAssertEqual(try String(contentsOf: localLog, encoding: .utf8), "newer")
  }

  func testImportFillsAMissingLogIntoAnExistingDirectory() async throws {
    let home = try makeDshHome(self, sessions: [("--a--", "session-1", "contents")])
    let root = try TestSupport.makeRoot(self)
    let archive = root.appendingPathComponent("backup.zip")
    _ = try await service.export(
      sessions: SessionArchiveCatalog.scan(dshHome: home),
      dshHome: home,
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      to: archive,
      includeAttachments: false
    )

    // An interrupted earlier run left the directory behind without a log.
    let directory = home.appendingPathComponent("sessions/--a--/session-1", isDirectory: true)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("session.v3.jsonl.zstd"))
    try FileManager.default.removeItem(at: directory.appendingPathComponent("session.lock"))

    let report = try await service.importArchive(
      archive,
      dshHome: home,
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
    )

    XCTAssertEqual(report.imported.count, 1)
    XCTAssertEqual(report.imported.first?.filledInLog, true)
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent("session.v3.jsonl.zstd"), encoding: .utf8),
      "contents"
    )
  }

  func testImportRefusesAnArchiveWithoutAManifest() async throws {
    let root = try TestSupport.makeRoot(self)
    let payload = root.appendingPathComponent("payload", isDirectory: true)
    try TestSupport.write("log", to: payload.appendingPathComponent("sessions/--a--/session-1/session.v3.jsonl.zstd"))
    let archive = root.appendingPathComponent("plain.zip")
    let result = try await run("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.path, archive.path])
    XCTAssertTrue(result.succeeded, result.diagnostics())

    do {
      _ = try await service.importArchive(
        archive,
        dshHome: root.appendingPathComponent("home", isDirectory: true),
        stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
      )
      XCTFail("expected a refusal")
    } catch let error as SessionArchiveError {
      guard case .notDshnativeArchive = error else {
        return XCTFail("unexpected error \(error)")
      }
      XCTAssertFalse(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("home/sessions").path
      ))
    }
  }

  func testImportRefusesAnArchiveWrittenByANewerBuild() async throws {
    let root = try TestSupport.makeRoot(self)
    let archive = try await makeArchive(root: root, manifest: """
      {"schemaVersion": 99, "kind": "dshnative-session-archive", "createdAt": "2026-09-12T00:00:00Z",
       "sessionCount": 1, "includesAttachments": false, "projectKeys": ["--a--"]}
      """)

    do {
      _ = try await service.importArchive(
        archive,
        dshHome: root.appendingPathComponent("home", isDirectory: true),
        stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
      )
      XCTFail("expected a refusal")
    } catch let error as SessionArchiveError {
      XCTAssertEqual(error, .unsupportedSchemaVersion(found: 99, supported: 1))
    }
  }

  func testImportRejectsATraversalArchiveBeforeWritingAnything() async throws {
    let root = try TestSupport.makeRoot(self)
    let archive = root.appendingPathComponent("evil.zip")
    // Only the magic matters: the listing comes from the stubbed `unzip`, and extraction
    // must never be reached, so the archive needs no real contents.
    try Data([0x50, 0x4b, 0x03, 0x04, 0x00, 0x00]).write(to: archive)

    let stub = StubProcessRunner { call in
      call.executable.hasSuffix("unzip") ? .ok("sessions/../../Library/LaunchAgents/x.plist\n") : nil
    }
    let guarded = SessionArchiveService(runner: stub)
    let home = root.appendingPathComponent("home", isDirectory: true)

    do {
      _ = try await guarded.importArchive(
        archive,
        dshHome: home,
        stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
      )
      XCTFail("expected a refusal")
    } catch let error as RuntimeError {
      guard case .archiveRejected = error else {
        return XCTFail("unexpected error \(error)")
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
      XCTAssertFalse(stub.calls.contains { $0.executable.hasSuffix("ditto") })
    }
  }

  func testImportOfAnArchiveWithNoSessionsPayloadIsRejected() async throws {
    let root = try TestSupport.makeRoot(self)
    let archive = try await makeArchive(root: root, manifest: """
      {"schemaVersion": 1, "kind": "dshnative-session-archive", "createdAt": "2026-09-12T00:00:00Z",
       "sessionCount": 0, "includesAttachments": false, "projectKeys": []}
      """)

    do {
      _ = try await service.importArchive(
        archive,
        dshHome: root.appendingPathComponent("home", isDirectory: true),
        stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
      )
      XCTFail("expected a refusal")
    } catch let error as SessionArchiveError {
      guard case .notDshnativeArchive = error else {
        return XCTFail("unexpected error \(error)")
      }
    }
  }

  // MARK: - Naming

  func testPayloadDirectoryNameCarriesATimestamp() {
    let name = SessionArchiveService.payloadDirectoryName(now: Date(timeIntervalSince1970: 0))
    XCTAssertTrue(name.hasPrefix("dshnative-sessions-"), name)
    XCTAssertEqual(name.count, "dshnative-sessions-".count + "yyyyMMdd-HHmm".count)
  }

  // MARK: - Helpers

  /// A zip shaped like one of ours, with the given manifest body.
  private func makeArchive(root: URL, manifest: String) async throws -> URL {
    let payload = root.appendingPathComponent("payload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    try Data(manifest.utf8).write(to: payload.appendingPathComponent("manifest.json"))
    let archive = root.appendingPathComponent("archive-\(UUID().uuidString).zip")
    let result = try await run("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.path, archive.path])
    XCTAssertTrue(result.succeeded, result.diagnostics())
    return archive
  }
}
