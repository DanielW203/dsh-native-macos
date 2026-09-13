import Foundation
import XCTest
@testable import HarnessRuntime

/// Healthy-start checkpoints: what gets saved, how slots rotate, and what a restore is
/// allowed to touch.
///
/// The rules these pin are the ones that decide whether a rollback is a way out or a
/// second way to lose the configuration: declarative files only, verified before the first
/// write, and never `node_modules`.
final class ProfileCheckpointTests: XCTestCase {
  private var root: URL!
  private var paths: RuntimePaths!

  override func setUpWithError() throws {
    root = try TestSupport.makeRoot(self)
    paths = RuntimePaths(root: root)
    try paths.createDirectories()
  }

  private func makeStore() -> ProfileCheckpointStore {
    ProfileCheckpointStore(paths: paths)
  }

  private func write(_ contents: String, _ relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  /// A profile directory shaped like a real one, plus the two files that must be excluded.
  private func seedProfile(_ name: String = "web") throws {
    try write("{\"dsh\":{\"profile\":{\"bundles\":[]}}}", "home/profiles/\(name)/package.json")
    try write("lockfileVersion: 9", "home/profiles/\(name)/pnpm-lock.yaml")
    try write("packages: []", "home/profiles/\(name)/pnpm-workspace.yaml")
    try write("[]", "home/profiles/\(name)/cordis.patch.yml")
    try write("model: deepseek-flash", "home/settings.yaml")
    // Excluded on purpose.
    try write("[]", "home/profiles/\(name)/cordis.yml")
    try write("{}", "home/profiles/\(name)/native-plugin-state.json")
    try write("{}", "home/profiles/\(name)/node_modules/left-pad/package.json")
  }

  private func date(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
  }

  // MARK: - Recording

  func testRecordKeepsTheDeclarativeFilesAndNothingElse() async throws {
    try seedProfile()
    let store = makeStore()

    let record = try await store.record(profile: "web", at: date(0))

    XCTAssertEqual(record.files.map(\.path).sorted(), [
      "home/profiles/web/cordis.patch.yml",
      "home/profiles/web/package.json",
      "home/profiles/web/pnpm-lock.yaml",
      "home/profiles/web/pnpm-workspace.yaml",
      "home/settings.yaml",
    ])
    XCTAssertFalse(record.files.contains { $0.path.hasSuffix("cordis.yml") })
    XCTAssertFalse(record.files.contains { $0.path.contains("node_modules") })
    XCTAssertFalse(record.files.contains { $0.path.contains("native-plugin-state") })
    // The copies really exist, keyed by the same relative path.
    for file in record.files {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: store.storedFileURL(record.id, path: file.path).path),
        "\(file.path) should have been copied into the slot"
      )
    }
  }

  func testRecordedDigestMatchesTheFile() async throws {
    try seedProfile()
    let store = makeStore()

    let record = try await store.record(profile: "web", at: date(0))
    let entry = try XCTUnwrap(record.files.first { $0.path.hasSuffix("package.json") })

    XCTAssertEqual(
      entry.sha256,
      try ArchiveInspector.sha256(of: root.appendingPathComponent(entry.path))
    )
    XCTAssertGreaterThan(entry.bytes, 0)
  }

  func testAMissingFileIsSimplyNotRecorded() async throws {
    try write("{\"dsh\":{}}", "home/profiles/web/package.json")
    let store = makeStore()

    let record = try await store.record(profile: "web", at: date(0))

    // `home/cordis.patch.yml` and the lock file never existed; a checkpoint that recorded
    // them as empty would restore an empty file over nothing.
    XCTAssertEqual(record.files.map(\.path), ["home/profiles/web/package.json"])
  }

  func testTheFirstThreeRecordsFillTheSlotsInOrder() async throws {
    try seedProfile()
    let store = makeStore()

    for index in 0..<3 {
      let record = try await store.record(profile: "web", at: date(TimeInterval(index)))
      XCTAssertEqual(record.id, ProfileCheckpointStore.slots[index])
    }

    XCTAssertEqual(store.list().map(\.id), ["slot-3", "slot-2", "slot-1"])
  }

  func testAFourthRecordReplacesTheOldest() async throws {
    try seedProfile()
    let store = makeStore()
    for index in 0..<3 {
      try await store.record(profile: "web", at: date(TimeInterval(index)))
    }

    let record = try await store.record(profile: "web", at: date(10))

    XCTAssertEqual(record.id, "slot-1")
    XCTAssertEqual(store.list().map(\.id), ["slot-1", "slot-3", "slot-2"])
    XCTAssertEqual(store.list().count, 3, "rotation keeps exactly three slots")
  }

  /// A stale file inside a reused slot would be restored as if this configuration had it.
  func testReusingASlotDropsFilesTheNewRecordDoesNotCover() async throws {
    try seedProfile()
    let store = makeStore()
    for index in 0..<3 {
      try await store.record(profile: "web", at: date(TimeInterval(index)))
    }
    let stale = store.storedFileURL("slot-1", path: "home/settings.yaml")
    XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
    try FileManager.default.removeItem(at: root.appendingPathComponent("home/settings.yaml"))

    let record = try await store.record(profile: "web", at: date(10))

    XCTAssertEqual(record.id, "slot-1")
    XCTAssertFalse(record.files.contains { $0.path == "home/settings.yaml" })
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: stale.path),
      "the old slot contents must be replaced wholesale"
    )
  }

  func testAnUnreadableSlotIsSkippedRatherThanHidingTheRest() async throws {
    try seedProfile()
    let store = makeStore()
    for index in 0..<3 {
      try await store.record(profile: "web", at: date(TimeInterval(index)))
    }
    try Data("not json".utf8).write(to: store.manifestURL("slot-3"))

    XCTAssertEqual(store.list().map(\.id), ["slot-2", "slot-1"])
    XCTAssertNil(store.record(for: "slot-3"))
  }

  /// A manifest that cannot be read is already lost. Leaving it in place would shrink the
  /// pool to two slots forever, so the next record reuses it rather than rotating a good one.
  func testAnUnreadableSlotIsReusedRatherThanSkippedForever() async throws {
    try seedProfile()
    let store = makeStore()
    for index in 0..<3 {
      try await store.record(profile: "web", at: date(TimeInterval(index)))
    }
    try Data("not json".utf8).write(to: store.manifestURL("slot-3"))

    let record = try await store.record(profile: "web", at: date(10))

    XCTAssertEqual(record.id, "slot-3")
    XCTAssertEqual(store.list().count, 3)
  }

  // MARK: - Restoring

  func testPreviewSeparatesChangedFromMissing() async throws {
    try seedProfile()
    let store = makeStore()
    let record = try await store.record(profile: "web", at: date(0))
    try write("{\"dsh\":{\"profile\":{\"bundles\":[\"broken\"]}}}", "home/profiles/web/package.json")
    try FileManager.default.removeItem(at: root.appendingPathComponent("home/settings.yaml"))

    let preview = try await store.preview(slot: record.id)

    XCTAssertEqual(preview.changed, ["home/profiles/web/package.json"])
    XCTAssertEqual(preview.missing, ["home/settings.yaml"])
    XCTAssertEqual(preview.profile, "web")
    XCTAssertFalse(preview.isEmpty)
  }

  func testPreviewOfAnUnchangedProfileIsEmpty() async throws {
    try seedProfile()
    let store = makeStore()
    let record = try await store.record(profile: "web", at: date(0))

    let preview = try await store.preview(slot: record.id)

    XCTAssertTrue(preview.isEmpty)
  }

  func testRestoreWritesTheBytesBack() async throws {
    try seedProfile()
    let store = makeStore()
    let record = try await store.record(profile: "web", at: date(0))
    let original = try Data(contentsOf: root.appendingPathComponent("home/settings.yaml"))
    try write("model: something-else", "home/settings.yaml")

    let result = try await store.restore(slot: record.id)

    XCTAssertTrue(result.restored.contains("home/settings.yaml"))
    XCTAssertTrue(result.skipped.isEmpty)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("home/settings.yaml")), original)
  }

  func testRestoreLeavesNodeModulesAlone() async throws {
    try seedProfile()
    let store = makeStore()
    let record = try await store.record(profile: "web", at: date(0))
    let installed = root.appendingPathComponent("home/profiles/web/node_modules/left-pad/package.json")
    let before = try Data(contentsOf: installed)

    _ = try await store.restore(slot: record.id)

    XCTAssertEqual(try Data(contentsOf: installed), before)
  }

  /// A profile that is neither the saved one nor the current one would be worse than
  /// either, so a damaged slot is refused before the first byte is written.
  func testADamagedSlotIsRefusedWithoutWritingAnything() async throws {
    try seedProfile()
    let store = makeStore()
    let record = try await store.record(profile: "web", at: date(0))
    let broken = try XCTUnwrap(record.files.first { $0.path.hasSuffix("package.json") })
    let stored = store.storedFileURL(record.id, path: broken.path)
    // Same length, different bytes: the size check passes and the digest check must not.
    try Data(repeating: 0x20, count: broken.bytes).write(to: stored)
    try write("{\"dsh\":{\"profile\":{\"bundles\":[\"current\"]}}}", "home/profiles/web/package.json")
    let current = try Data(contentsOf: root.appendingPathComponent("home/profiles/web/package.json"))

    do {
      _ = try await store.restore(slot: record.id)
      XCTFail("a slot whose bytes do not match its digest must be refused")
    } catch {
      XCTAssertTrue(String(describing: error).contains("damaged"))
    }

    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("home/profiles/web/package.json")),
      current,
      "a refused restore must not have touched the profile"
    )
  }

  func testRestoreOfAnUnknownSlotIsReported() async throws {
    try seedProfile()
    let store = makeStore()

    do {
      _ = try await store.restore(slot: "slot-9")
      XCTFail("an unknown slot must be reported")
    } catch {
      XCTAssertTrue(String(describing: error).contains("no checkpoint"))
    }
    do {
      _ = try await store.preview(slot: "slot-9")
      XCTFail("an unknown slot must be reported")
    } catch {
      XCTAssertTrue(String(describing: error).contains("no checkpoint"))
    }
  }

  func testClearRemovesEverySlot() async throws {
    try seedProfile()
    let store = makeStore()
    try await store.record(profile: "web", at: date(0))

    try await store.clear()

    XCTAssertTrue(store.list().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.checkpointRoot.path))
  }

  // MARK: - The healthy-start seam

  func testRecordHealthyStartSavesAProfileScopedCheckpoint() async throws {
    try seedProfile("rescue")
    let store = makeStore()

    let note = await store.recordHealthyStart(profile: "rescue")

    XCTAssertTrue(try XCTUnwrap(note).contains("healthy-start checkpoint"))
    let record = try XCTUnwrap(store.list().first)
    XCTAssertEqual(record.profile, "rescue")
    XCTAssertEqual(record.reason, "healthy-start")
    XCTAssertTrue(record.files.allSatisfy { $0.path.contains("rescue") || $0.path.hasPrefix("home/settings") || $0.path == "home/cordis.patch.yml" })
    XCTAssertFalse(record.files.contains { $0.path.contains("/web/") })
  }

  /// Never being able to roll back is a missing safety net; failing a start that already
  /// succeeded is a regression the user cannot act on.
  func testRecordHealthyStartReportsRatherThanThrows() async throws {
    try seedProfile()
    // A file where the checkpoint directory must be: every write inside it now fails.
    try write("not a directory", "harness/checkpoints")
    let store = makeStore()

    let note = await store.recordHealthyStart(profile: "web")

    XCTAssertTrue(store.list().isEmpty)
    XCTAssertTrue(
      try XCTUnwrap(note).contains("Could not save a healthy-start checkpoint"),
      "the failure must be reported to the caller rather than thrown"
    )
  }
}
