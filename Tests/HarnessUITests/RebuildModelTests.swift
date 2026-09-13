import XCTest
@testable import HarnessRuntime
@testable import HarnessUI

/// A runner that answers with a fixed result instead of compiling anything.
private final class FixedRunner: ProcessRunning, @unchecked Sendable {
  private let result: ProcessResult
  private let lines: [String]

  init(result: ProcessResult, lines: [String] = []) {
    self.result = result
    self.lines = lines
  }

  func run(
    _ request: ProcessRequest,
    onLine: (@Sendable (ProcessStream, String) -> Void)?
  ) async throws -> ProcessResult {
    for line in lines { onLine?(.stdout, line) }
    return result
  }
}

/// What the injected side effects did, written from inside `@Sendable` closures.
private final class Recorder: @unchecked Sendable {
  var terminated = false
  var handedOff = false
  var handedOffPid: Int32?
}

private struct HandoffFailure: Error {}

private func succeeded() -> ProcessResult {
  ProcessResult(exitCode: 0, stdout: "", stderr: "", duration: 1)
}

private func failed(_ code: Int32) -> ProcessResult {
  ProcessResult(exitCode: code, stdout: "", stderr: "error: nope", duration: 1)
}

private func makeSandbox() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("rebuild-model-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func service(in sandbox: URL, runner: ProcessRunning) -> SelfRebuild {
  SelfRebuild(
    checkout: RebuildCheckout(root: sandbox),
    installDirectory: sandbox,
    appName: "DSHNative.app",
    logURL: sandbox.appendingPathComponent("rebuild.log"),
    bundle: sandbox,
    home: sandbox,
    runner: runner
  )
}

@MainActor
final class RebuildModelTests: XCTestCase {
  /// The button on a machine where nothing can be found must explain what to do, not fail
  /// silently, and must not quit the app it could not rebuild.
  func testMissingCheckoutExplainsItselfAndKeepsTheAppAlive() async {
    let recorder = Recorder()
    let model = RebuildModel(
      locate: { nil },
      terminate: { recorder.terminated = true }
    )
    await model.run()

    XCTAssertFalse(recorder.terminated)
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(
      model.failure,
      "没有找到 harness-native 源码目录。请点「选择源码目录…」手动指定包含 Tools/build.sh 的仓库根目录。"
    )
    XCTAssertTrue(model.stageText.contains("选择源码目录"))
  }

  /// A failed build is a dead end for the hand-off: there is no new bundle to install, and
  /// quitting would leave the user with no app and no explanation.
  func testAFailedReleaseDoesNotQuitOrHandOff() async throws {
    let sandbox = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let recorder = Recorder()
    let model = RebuildModel(
      locate: { RebuildCheckout(root: sandbox) },
      makeService: { _ in service(in: sandbox, runner: FixedRunner(result: failed(65))) },
      handoff: { _, _ in recorder.handedOff = true },
      terminate: { recorder.terminated = true }
    )
    await model.run()

    XCTAssertFalse(recorder.handedOff)
    XCTAssertFalse(recorder.terminated)
    XCTAssertTrue(model.failure?.contains("release 失败") == true, model.failure ?? "nil")
    XCTAssertTrue(model.lines.contains { $0.contains("Tools/build.sh release") })
  }

  /// The happy path: compile here, hand the install to a shell, then quit so it can replace
  /// the bundle this process is running from.
  func testASuccessfulReleaseHandsOffThenQuits() async throws {
    let sandbox = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let recorder = Recorder()
    let model = RebuildModel(
      locate: { RebuildCheckout(root: sandbox) },
      makeService: { _ in
        service(in: sandbox, runner: FixedRunner(result: succeeded(), lines: ["** BUILD SUCCEEDED **"]))
      },
      handoff: { _, pid in recorder.handedOffPid = pid },
      terminate: { recorder.terminated = true }
    )
    await model.run()

    XCTAssertEqual(recorder.handedOffPid, ProcessInfo.processInfo.processIdentifier)
    XCTAssertTrue(recorder.terminated)
    XCTAssertNil(model.failure)
    XCTAssertTrue(model.lines.contains("** BUILD SUCCEEDED **"))
    XCTAssertEqual(model.phase, .handingOff)
    XCTAssertEqual(model.checkoutPath, sandbox.standardizedFileURL.path)
  }

  /// A hand-off that cannot start must not quit either: the compiled bundle is still in
  /// scratch, and the app that could rerun the install is still the right place to say so.
  func testAFailedHandOffDoesNotQuit() async throws {
    let sandbox = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let recorder = Recorder()
    let model = RebuildModel(
      locate: { RebuildCheckout(root: sandbox) },
      makeService: { _ in service(in: sandbox, runner: FixedRunner(result: succeeded())) },
      handoff: { _, _ in throw HandoffFailure() },
      terminate: { recorder.terminated = true }
    )
    await model.run()

    XCTAssertFalse(recorder.terminated)
    XCTAssertTrue(model.failure?.contains("后台安装脚本") == true, model.failure ?? "nil")
  }

  /// Choosing a directory by hand must validate it: pointing the rebuild at a folder that is
  /// not the repository would run somebody else's `build.sh`.
  func testChoosingANonCheckoutIsRejectedWithoutRememberingIt() async throws {
    let sandbox = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let empty = sandbox.appendingPathComponent("not-a-repo", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let model = RebuildModel(locate: { nil }, terminate: {})
    await model.useCheckout(empty)

    XCTAssertTrue(model.failure?.contains("不是 harness-native 仓库") == true, model.failure ?? "nil")
    XCTAssertNil(UserDefaults.standard.string(forKey: RebuildCheckoutLocator.defaultsKey))
  }

  /// A checkout that validates is remembered, so the next click does not have to search.
  func testChoosingACheckoutRemembersIt() async throws {
    let sandbox = try makeSandbox()
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let checkout = sandbox.appendingPathComponent("harness-native", isDirectory: true)
    try FileManager.default.createDirectory(
      at: checkout.appendingPathComponent("Tools", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "#!/usr/bin/env bash\n".write(
      to: checkout.appendingPathComponent("Tools/build.sh"),
      atomically: true,
      encoding: .utf8
    )
    try "// manifest\n".write(
      to: checkout.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )
    defer { UserDefaults.standard.removeObject(forKey: RebuildCheckoutLocator.defaultsKey) }

    let model = RebuildModel(
      locate: { nil },
      makeService: { _ in service(in: sandbox, runner: FixedRunner(result: succeeded())) },
      handoff: { _, _ in },
      terminate: {}
    )
    await model.useCheckout(checkout)

    XCTAssertEqual(
      UserDefaults.standard.string(forKey: RebuildCheckoutLocator.defaultsKey),
      checkout.standardizedFileURL.path
    )
  }

  /// The sheet opens before the work starts, so a rebuild is never a click that does nothing
  /// until the search finishes.
  func testPresentResetsTheSheetWithoutRunning() {
    let model = RebuildModel(locate: { nil }, terminate: {})
    model.present()
    XCTAssertTrue(model.isPresented)
    XCTAssertEqual(model.phase, .locating)
  }
}
