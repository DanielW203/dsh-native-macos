import Foundation
import XCTest
@testable import HarnessConsoleUI
import HarnessRuntime

/// The recovery window's state: which marker gets written, whether a restart follows, and
/// whether a restore is refused before it touches anything.
private final class StubMarking: SafeBootMarking, @unchecked Sendable {
  let base: RuntimePaths
  var resolutions: [SafeBootMode?] = []
  var failure: Error?
  private(set) var entered: [SafeBootMode] = []
  private(set) var leaveCount = 0

  init(base: RuntimePaths) { self.base = base }

  func current() -> SafeBootResolution {
    let mode = resolutions.first ?? nil
    return SafeBootResolution(
      mode: mode,
      paths: mode == .cleanHome ? base.withSafeModeHome() : base,
      profile: mode == .rescue ? SafeBoot.rescueProfileName : "web"
    )
  }

  func enter(_ mode: SafeBootMode) throws {
    if let failure { throw failure }
    entered.append(mode)
  }

  func leave() throws {
    if let failure { throw failure }
    leaveCount += 1
  }
}

private final class StubPreparer: ProfilePreparing, @unchecked Sendable {
  var note: String? = "Created profile rescue from the shipped web template."
  var failure: Error?
  private(set) var requests: [String] = []

  func ensureProfile(named name: String, template: String) async throws -> String? {
    requests.append("\(name):\(template)")
    if let failure { throw failure }
    return note
  }
}

@MainActor
final class HarnessRecoveryModelTests: XCTestCase {
  private var root: URL!
  private var base: RuntimePaths!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessConsoleUITests", isDirectory: true)
      .appendingPathComponent("\(#function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
    base = RuntimePaths(root: root)
    try base.createDirectories()
  }

  private func makeModel(
    marking: StubMarking,
    preparer: (any ProfilePreparing)? = nil,
    boot: SafeBootResolution? = nil,
    events: Events? = nil
  ) -> HarnessRecoveryModel {
    let resolved = boot ?? SafeBootResolution(mode: nil, paths: base, profile: "web")
    return HarnessRecoveryModel(
      base: base,
      boot: resolved,
      marking: marking,
      checkpoints: ProfileCheckpointStore(paths: base),
      rescueInstaller: preparer,
      stopHarness: { events?.append("stop") },
      restartApp: { events?.append("restart") }
    )
  }

  private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
  }

  private func write(_ contents: String, _ relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - Mode switching

  func testEnteringRescueCreatesTheProfileThenWritesTheMarkerAndRestarts() async throws {
    let marking = StubMarking(base: base)
    let preparer = StubPreparer()
    let model = makeModel(marking: marking, preparer: preparer)

    await model.selectMode(.rescue)

    // The profile is created here, before the marker: a marker pointing at a profile that
    // cannot boot would strand the next launch in a mode the user asked for and cannot use.
    XCTAssertEqual(preparer.requests, ["rescue:web"])
    XCTAssertEqual(marking.entered, [.rescue])
    // `mode` deliberately keeps reporting what *this* launch resolved to: the switch takes
    // effect in the next one, which is what the restart is for.
    XCTAssertNil(model.mode)
    XCTAssertTrue(model.statusLine.contains("安全模式"))
  }

  func testLeavingSafeModeRemovesTheMarker() async throws {
    let marking = StubMarking(base: base)
    marking.resolutions = [.cleanHome]
    let model = makeModel(marking: marking)

    await model.selectMode(nil)

    XCTAssertEqual(marking.leaveCount, 1)
    XCTAssertTrue(marking.entered.isEmpty)
    XCTAssertNil(model.mode)
  }

  func testAFailedProfilePreparationWritesNoMarker() async throws {
    let marking = StubMarking(base: base)
    let preparer = StubPreparer()
    preparer.failure = RuntimeError.unsupported("no space left on device")
    let model = makeModel(marking: marking, preparer: preparer)

    await model.selectMode(.rescue)

    XCTAssertTrue(marking.entered.isEmpty)
    XCTAssertTrue(model.statusIsFailure)
    XCTAssertTrue(model.statusLine.contains("no space left"))
  }

  func testAFailedMarkerWriteIsReported() async throws {
    let marking = StubMarking(base: base)
    marking.failure = RuntimeError.unsupported("read-only")
    let model = makeModel(marking: marking)

    await model.selectMode(.cleanHome)

    XCTAssertTrue(model.statusIsFailure)
    XCTAssertTrue(model.statusLine.contains("read-only"))
  }

  // MARK: - Rollback

  func testRestoreStopsTheHarnessBeforeWriting() async throws {
    try write("{\"dsh\":{\"profile\":{\"bundles\":[]}}}", "home/profiles/web/package.json")
    let store = ProfileCheckpointStore(paths: base)
    let record = try await store.record(profile: "web")
    try write("{\"dsh\":{\"profile\":{\"bundles\":[\"broken\"]}}}", "home/profiles/web/package.json")
    let events = Events()
    let model = makeModel(marking: StubMarking(base: base), events: events)

    await model.restore(record.id)

    // Order matters: rewriting the profile of a server that is still running leaves a state
    // neither the user nor the harness can describe.
    XCTAssertEqual(events.all, ["stop"])
    XCTAssertFalse(model.statusIsFailure, model.statusLine)
    XCTAssertTrue(model.statusLine.contains("Restored 1 file(s)"))
    let restored = try String(contentsOf: root.appendingPathComponent("home/profiles/web/package.json"))
    XCTAssertTrue(restored.contains("\"bundles\":[]"))
  }

  func testRestoreWithoutACheckpointFailsCleanly() async throws {
    let model = makeModel(marking: StubMarking(base: base))

    await model.restore("slot-1")

    XCTAssertTrue(model.statusIsFailure)
    XCTAssertTrue(model.statusLine.contains("Restore failed"))
  }

  func testPreviewWithoutACheckpointFailsCleanly() async throws {
    let model = makeModel(marking: StubMarking(base: base))

    await model.previewRestore("slot-1")

    XCTAssertNil(model.lastPreview)
    XCTAssertTrue(model.statusIsFailure)
  }

  func testClearingCheckpointsEmptiesTheList() async throws {
    try write("{\"dsh\":{}}", "home/profiles/web/package.json")
    let store = ProfileCheckpointStore(paths: base)
    _ = try await store.record(profile: "web")
    let model = makeModel(marking: StubMarking(base: base))
    await model.refreshCheckpoints()
    XCTAssertEqual(model.checkpoints.count, 1)

    await model.clearCheckpoints()

    XCTAssertTrue(model.checkpoints.isEmpty)
    XCTAssertTrue(model.statusLine.contains("Cleared"))
  }

  // MARK: - The rescue profile

  func testDeletingTheRescueProfileIsRefusedWhileItIsTheBootTarget() async throws {
    try write("{}", "home/profiles/rescue/package.json")
    let marking = StubMarking(base: base)
    marking.resolutions = [.rescue]
    let model = makeModel(marking: marking)
    await model.refresh()

    await model.removeRescueProfile()

    XCTAssertTrue(FileManager.default.fileExists(
      atPath: base.profilesDirectory.appendingPathComponent("rescue").path
    ))
    XCTAssertTrue(model.statusIsFailure)
  }

  func testDeletingTheRescueProfileFromANormalStartWorks() async throws {
    try write("{}", "home/profiles/rescue/package.json")
    try write("{}", "home/profiles/web/package.json")
    let model = makeModel(marking: StubMarking(base: base))
    await model.refresh()
    XCTAssertTrue(model.rescueProfileExists)

    await model.removeRescueProfile()

    XCTAssertFalse(model.rescueProfileExists)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: base.profilesDirectory.appendingPathComponent("rescue").path
    ))
    // The user's own profile is untouched.
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: base.profilesDirectory.appendingPathComponent("web").path
    ))
  }

  func testTheBannerAndNoteComeFromTheResolvedMode() async throws {
    let marking = StubMarking(base: base)
    marking.resolutions = [.rescue]
    let model = makeModel(
      marking: marking,
      boot: SafeBootResolution(mode: .rescue, paths: base, profile: "rescue", note: "cleared a leftover")
    )

    XCTAssertEqual(model.banner?.title, "安全模式 · 无插件")
    XCTAssertEqual(model.note, "cleared a leftover")

    await model.refresh()

    XCTAssertEqual(model.banner?.title, "安全模式 · 无插件")
  }
}
