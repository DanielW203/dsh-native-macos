import Foundation
import XCTest
@testable import HarnessConsoleUI
import HarnessRuntime

/// A launcher that answers from a script and remembers what it was asked to boot.
///
/// No lock around the recording, matching the stub next door: the model calls this from the
/// main actor, and the test reads the tally from the same place.
private final class StubLauncher: HarnessLaunching, @unchecked Sendable {
  /// Deliberately URL-less: a start that announced a URL would send the console to
  /// `NSWorkspace.open`, and a unit test must not open a browser on the machine running it.
  var outcome: Result<HarnessServerState, Error> = .success(HarnessServerState(phase: .running))

  /// The working directory of every start, in order.
  private(set) var workingDirectories: [URL?] = []

  func start(
    profile: String,
    host: String,
    workingDirectory: URL?,
    timeout: TimeInterval,
    onLine: @escaping @Sendable (String) -> Void,
    onStage: @escaping @Sendable (String) -> Void
  ) async throws -> HarnessServerState {
    workingDirectories.append(workingDirectory)
    return try outcome.get()
  }

  func stop(timeout: TimeInterval) async {}

  func state() async -> HarnessServerState {
    (try? outcome.get()) ?? .stopped
  }
}

/// Where the console boots the harness, now that the console is the window that shows the
/// folder.
///
/// The choice belongs to the app's main window (`HarnessWindowModel`), which owns and
/// persists it; `HarnessConsoleModel` may not reach for it — the module cannot depend on
/// `HarnessUI` — so what these tests pin down is the other half of the contract: whatever
/// the host hands in is what the launch uses. A console without a host must keep booting
/// where it always did, in the harness home.
@MainActor
final class ConsoleWorkspaceTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ConsoleWorkspaceTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
  }

  /// A loaded console. `start()` is what installs the injected launcher, so the path to
  /// `startHarness()` runs through the same setup a window would do.
  private func loadedConsole(_ launcher: StubLauncher) async -> HarnessConsoleModel {
    let model = HarnessConsoleModel(paths: RuntimePaths(root: root), launcher: launcher)
    let loaded = await model.start()
    XCTAssertTrue(loaded, "the console did not load: \(model.log.map(\.text))")
    return model
  }

  func testStartHarnessBootsInTheChosenWorkspace() async {
    let launcher = StubLauncher()
    let model = await loadedConsole(launcher)
    model.workspacePath = "/tmp/ws"

    await model.startHarness()

    XCTAssertEqual(
      launcher.workingDirectories,
      [URL(fileURLWithPath: "/tmp/ws", isDirectory: true)] as [URL?]
    )
  }

  func testAConsoleWithoutAHostWorkspaceKeepsTheOldLaunchDirectory() async {
    let launcher = StubLauncher()
    let model = await loadedConsole(launcher)

    // No host, no card: the view draws the workspace card only for a non-nil path, and the
    // picker has nothing to call until a host supplies the action.
    XCTAssertNil(model.workspacePath)
    XCTAssertNil(model.workspaceURL)
    XCTAssertNil(model.chooseWorkspace)

    await model.startHarness()

    XCTAssertEqual(launcher.workingDirectories, [nil] as [URL?])
  }

  func testTheWorkspaceURLIsThePathAsADirectory() async {
    let launcher = StubLauncher()
    let model = await loadedConsole(launcher)

    model.workspacePath = "/tmp/ws"

    XCTAssertEqual(model.workspaceURL, URL(fileURLWithPath: "/tmp/ws", isDirectory: true))
  }
}
