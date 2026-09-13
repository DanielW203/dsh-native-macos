import Foundation
import XCTest

@testable import HarnessIM

/// The reader for the harness's own workspace registry.
///
/// Everything here is deliberately hostile to the file it reads: the registry belongs to the
/// harness, so a version bump there has to degrade to "no workspaces to offer" rather than to a
/// crashed WeChat loop, and every parse step is checked against a malformed input.
final class WorkspaceCatalogTests: XCTestCase {
  // MARK: - Decoding

  private let registry = """
  {
    "unit": {"name": "workspace", "version": 2},
    "global": {"initialized": true, "workspaceIds": ["id-a", "id-b"]},
    "tables": {
      "workspaces": {
        "id-a": {
          "path": "/tmp/a", "title": "A", "sessionIds": ["s1", "s2"],
          "updatedAt": "2026-09-13T04:04:49.235Z"
        },
        "id-b": {
          "path": "/tmp/b", "title": "B", "sessionIds": [],
          "updatedAt": "2026-09-10T12:45:25.252Z"
        },
        "id-c": {"path": "/tmp/c", "title": "C", "sessionIds": []},
        "id-bad": {"title": "没有 path"}
      }
    }
  }
  """

  func testDecodeKeepsEveryUsableRowNewestFirst() {
    let workspaces = WorkspaceCatalog.decode(Data(registry.utf8))

    // `id-c` is not named in `global.workspaceIds`; it is still a workspace the sidebar shows,
    // and a row without a `path` cannot be a folder at all.
    XCTAssertEqual(workspaces.map(\.id), ["id-a", "id-b", "id-c"])
    XCTAssertEqual(workspaces[0].sessionCount, 2)
    XCTAssertEqual(workspaces[0].title, "A")
  }

  func testRowsWithoutActivityFallBackToTitleOrder() {
    let json = """
    {"tables":{"workspaces":{
      "id-1":{"path":"/tmp/1","title":"B","sessionIds":[]},
      "id-2":{"path":"/tmp/2","title":"A","sessionIds":[]}
    }}}
    """
    XCTAssertEqual(WorkspaceCatalog.decode(Data(json.utf8)).map(\.title), ["A", "B"])
  }

  /// A registry we cannot understand is "nothing to offer", never a thrown error.
  func testGarbageDecodesToNothing() {
    XCTAssertTrue(WorkspaceCatalog.decode(Data("not json".utf8)).isEmpty)
    XCTAssertTrue(WorkspaceCatalog.decode(Data("[]".utf8)).isEmpty)
    XCTAssertTrue(WorkspaceCatalog.decode(Data("{}".utf8)).isEmpty)
  }

  func testDisplayTitleFallsBackToTheFolderName() {
    let unnamed = HarnessWorkspace(id: "i", path: "/tmp/my-project", title: "")
    XCTAssertEqual(unnamed.displayTitle, "my-project")
    XCTAssertEqual(HarnessWorkspace(id: "", path: "/tmp/x", title: "").shortID, nil)
    XCTAssertEqual(HarnessWorkspace(id: "bda58903-facd", path: "/x", title: "x").shortID, "bda58903")
  }

  // MARK: - Reachability

  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-im-catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func writeRegistry(home: URL, _ body: String) throws {
    let directory = home.appendingPathComponent("storages", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(body.utf8).write(to: directory.appendingPathComponent("workspace.json"))
  }

  func testLoadMarksFoldersThatAreGone() throws {
    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let live = scratch.appendingPathComponent("live", isDirectory: true)
    let gone = scratch.appendingPathComponent("gone", isDirectory: true)
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: gone)
    try writeRegistry(home: home, """
    {"global":{"workspaceIds":["live","gone"]},"tables":{"workspaces":{
      "live":{"path":"\(live.path)","title":"live","sessionIds":[]},
      "gone":{"path":"\(gone.path)","title":"gone","sessionIds":[]}
    }}}
    """)

    let loaded = WorkspaceCatalog.load(home: home)
    XCTAssertEqual(loaded.first { $0.id == "live" }?.isReachable, true)
    XCTAssertEqual(loaded.first { $0.id == "gone" }?.isReachable, false)
  }

  func testLoadWithoutARegistryIsEmpty() {
    let home = scratch.appendingPathComponent("empty-home", isDirectory: true)
    XCTAssertTrue(WorkspaceCatalog.load(home: home).isEmpty)
    XCTAssertEqual(
      WorkspaceCatalog.storageURL(home: home).path,
      home.appendingPathComponent("storages/workspace.json").path
    )
  }

  // MARK: - Resolving a `/workspace` argument

  private let listing = [
    HarnessWorkspace(id: "bda58903-facd", path: "/Users/x/Documents/my-project", title: "my-project"),
    HarnessWorkspace(id: "47a02c72-1b2c", path: "/Users/x/Documents/wechat-bridge", title: "微信桥接"),
  ]

  func testResolveAcceptsEveryPhoneFriendlyForm() {
    XCTAssertEqual(WorkspaceCatalog.resolve(target: "2", in: listing)?.id, "47a02c72-1b2c")
    XCTAssertEqual(WorkspaceCatalog.resolve(target: "bda58903-facd", in: listing)?.id, "bda58903-facd")
    XCTAssertEqual(WorkspaceCatalog.resolve(target: "bda58903", in: listing)?.id, "bda58903-facd")
    XCTAssertEqual(
      WorkspaceCatalog.resolve(target: "/Users/x/Documents/my-project", in: listing)?.id,
      "bda58903-facd"
    )
    XCTAssertEqual(WorkspaceCatalog.resolve(target: "my-project", in: listing)?.id, "bda58903-facd")
    XCTAssertEqual(WorkspaceCatalog.resolve(target: "微信桥接", in: listing)?.id, "47a02c72-1b2c")
  }

  /// A path the registry has never seen is still a legitimate answer: the service registers it
  /// on demand, which is how the very first workspace gets chosen from the phone.
  func testResolveTurnsAPathIntoAnUnregisteredWorkspace() {
    let absolute = WorkspaceCatalog.resolve(target: "/tmp/new-folder", in: listing)
    XCTAssertEqual(absolute?.path, "/tmp/new-folder")
    XCTAssertEqual(absolute?.id, "")
    XCTAssertEqual(absolute?.title, "new-folder")

    let tilde = WorkspaceCatalog.resolve(
      target: "~/x", in: [], home: URL(fileURLWithPath: "/Users/tester")
    )
    XCTAssertEqual(tilde?.path, "/Users/tester/x")
  }

  func testResolveRefusesWhatIsNotAWorkspace() {
    XCTAssertNil(WorkspaceCatalog.resolve(target: "", in: listing))
    XCTAssertNil(WorkspaceCatalog.resolve(target: "   ", in: listing))
    // A bare number is an index or nothing — it must never be read as a folder name.
    XCTAssertNil(WorkspaceCatalog.resolve(target: "0", in: listing))
    XCTAssertNil(WorkspaceCatalog.resolve(target: "99", in: listing))
    XCTAssertNil(WorkspaceCatalog.resolve(target: "zzz", in: listing))
  }
}
