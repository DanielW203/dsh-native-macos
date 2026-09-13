import Foundation
import XCTest

@testable import HarnessIM

/// The channel's own storage is what makes a batch survive a restart, and it is also the
/// only place a credential is written — so both the round trip and the file permissions
/// are asserted.
final class ChannelStateStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-im-state-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func testLoadsEmptyStateBeforeAnythingIsStored() {
    let store = ChannelStateStore(directory: directory)
    let state = store.loadState()
    XCTAssertEqual(state.getUpdatesBuffer, "")
    XCTAssertTrue(state.sessions.isEmpty)
    // Bound-ness is answered by the credential file, not by the state record.
    XCTAssertNil(ChannelStateStore(directory: directory).loadCredential())
  }

  func testRoundTripsStateIncludingBatches() throws {
    let store = ChannelStateStore(directory: directory)
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    var state = ChannelPersistedState(getUpdatesBuffer: "buf-1")
    state.remember(messageID: "m-1")
    state.sessions["direct:user"] = "session-1"
    state.batches["direct:user"] = [
      BatchItem(messageID: "m-2", text: "重启前", attachments: [
        BatchAttachment(kind: .file, name: "a.pdf", byteCount: 12),
      ], receivedAt: at)
    ]
    try store.save(state: state)

    let loaded = store.loadState()
    XCTAssertEqual(loaded.getUpdatesBuffer, "buf-1")
    XCTAssertTrue(loaded.hasSeen("m-1"))
    XCTAssertEqual(loaded.sessions["direct:user"], "session-1")
    XCTAssertEqual(loaded.batches["direct:user"]?.first?.text, "重启前")
    XCTAssertEqual(loaded.batches["direct:user"]?.first?.attachments.first?.name, "a.pdf")
  }

  func testSeenListStaysBounded() {
    var state = ChannelPersistedState()
    for index in 0..<(ChannelPersistedState.seenLimit + 50) {
      state.remember(messageID: "m-\(index)")
    }
    XCTAssertEqual(state.seenMessageIDs.count, ChannelPersistedState.seenLimit)
    XCTAssertTrue(state.hasSeen("m-\(ChannelPersistedState.seenLimit + 49)"))
    XCTAssertFalse(state.hasSeen("m-0"), "the oldest ids are dropped first")
  }

  /// A truncated file must degrade to a usable empty state: refusing to load would leave
  /// the user unable to even re-bind the channel.
  func testCorruptStateFallsBackToEmptyState() throws {
    let store = ChannelStateStore(directory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: store.stateURL)
    let state = store.loadState()
    XCTAssertTrue(state.sessions.isEmpty)
    XCTAssertNotNil(state.lastError)
  }

  func testConfigDefaultsAndRoundTrip() throws {
    let store = ChannelStateStore(directory: directory)
    XCTAssertEqual(store.loadConfig().triggerPhrase, "开始")

    var config = store.loadConfig()
    config.triggerPhrase = "发送"
    config.workspacePath = "/ws"
    config.ackPolicy = .silent
    try store.save(config: config)

    let reloaded = store.loadConfig()
    XCTAssertEqual(reloaded.triggerPhrase, "发送")
    XCTAssertEqual(reloaded.workspacePath, "/ws")
    XCTAssertEqual(reloaded.ackPolicy, .silent)
  }

  func testCredentialIsWrittenOwnerOnlyAndRedactedInLogs() throws {
    let store = ChannelStateStore(directory: directory)
    let credential = ChannelCredential(
      botID: "wx_test",
      accountID: "1234@im.bot",
      ownerUserID: "owner@im.wechat",
      token: "super-secret-token",
      baseURL: ILinkProtocol.qrBaseURL
    )
    try store.save(credential: credential)

    XCTAssertEqual(store.loadCredential(), credential)

    let attributes = try FileManager.default.attributesOfItem(atPath: store.credentialURL.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

    // Printing the value must never reveal the token, because Swift prints values into logs.
    XCTAssertFalse(String(describing: credential).contains("super-secret-token"))
    XCTAssertFalse(String(reflecting: credential).contains("super-secret-token"))
    XCTAssertTrue(String(describing: credential).contains("<redacted>"))
  }

  func testClearCredentialRemovesTheFile() throws {
    let store = ChannelStateStore(directory: directory)
    try store.save(credential: ChannelCredential(
      botID: "wx_test", token: "t", baseURL: ILinkProtocol.qrBaseURL
    ))
    store.clearCredential()
    XCTAssertNil(store.loadCredential())
  }
}
