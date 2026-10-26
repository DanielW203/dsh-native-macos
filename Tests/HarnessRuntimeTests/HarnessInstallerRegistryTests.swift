import Foundation
import XCTest
@testable import HarnessRuntime

/// The registry path end to end against a stubbed npm: the dry run, the install, and the
/// progress it reports. No network, no real npm, no real Node.
final class HarnessInstallerRegistryTests: XCTestCase {
  /// A progress sink that can be called from the installer's executor.
  private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [InstallProgress] = []

    func append(_ item: InstallProgress) {
      lock.lock(); defer { lock.unlock() }
      items.append(item)
    }

    var all: [InstallProgress] {
      lock.lock(); defer { lock.unlock() }
      return items
    }
  }

  private static let dryRunJSON = """
  add @deepseek-ai/dsh 0.1.5-rc.1
  add alpha 1.0.0
  add @scope/beta 2.0.0
  {
    "add": [
      {"name": "@deepseek-ai/dsh", "version": "0.1.5-rc.1", "path": "/tmp/staging/node_modules/@deepseek-ai/dsh"},
      {"name": "alpha", "version": "1.0.0", "path": "/tmp/staging/node_modules/alpha"},
      {"name": "@scope/beta", "version": "2.0.0", "path": "/tmp/staging/node_modules/@scope/beta"}
    ],
    "added": 3,
    "audited": 0,
    "change": [],
    "changed": 0,
    "funding": 0,
    "remove": [],
    "removed": 0
  }
  """

  /// What the stubbed dry run answers. `String` is not an `Error`, so a `Result` cannot
  /// express the failing case here.
  private enum DryRun {
    case output(String)
    case failure(String)
  }

  /// Build an installer whose npm is a real executable file (so the resolver finds it) but
  /// whose every invocation is answered by the stub.
  private func makeInstaller(
    root: URL,
    dryRun: DryRun
  ) throws -> (HarnessInstaller, StubProcessRunner, ProgressLog) {
    let paths = RuntimePaths(root: root)
    try TestSupport.installFakeToolchain(into: paths)
    try TestSupport.write(
      "#!/bin/sh\n",
      to: paths.nodeBinary.deletingLastPathComponent().appendingPathComponent("npm"),
      executable: true
    )

    let base = TestSupport.toolchainResponder()
    let responder: @Sendable (StubProcessRunner.Call) -> ProcessResult? = { call in
      guard call.executable.hasSuffix("/npm") else { return base(call) }
      if call.arguments.contains("--dry-run") {
        switch dryRun {
        case .output(let text): return .ok(text)
        case .failure(let detail): return .failure(1, stderr: detail)
        }
      }
      guard let directory = call.currentDirectory else { return .ok() }
      let staging = URL(fileURLWithPath: directory)
      try? TestSupport.write(
        "{\"name\":\"@deepseek-ai/dsh\",\"version\":\"0.1.5-rc.1\"}",
        to: staging.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
      )
      try? TestSupport.write(
        "// entry",
        to: staging.appendingPathComponent(ReleaseValidator.prebuiltEntry)
      )
      return .ok()
    }

    let runner = StubProcessRunner(responder: responder)
    let installer = HarnessInstaller(
      paths: paths,
      runner: runner,
      baseEnvironment: ["HOME": root.path, "PATH": ""]
    )
    return (installer, runner, ProgressLog())
  }

  func testRegistryInstallRunsADryRunThenReportsPackageProgress() async throws {
    let root = try TestSupport.makeRoot(self)
    let (installer, runner, log) = try makeInstaller(root: root, dryRun: .output(Self.dryRunJSON))

    let outcome = try await installer.install(
      .registry(version: "0.1.5-rc.1"),
      progress: { log.append($0) }
    )
    XCTAssertEqual(outcome.release.version, "0.1.5-rc.1")

    let events = log.all.filter { $0.phase == .installingDependencies }
    XCTAssertTrue(
      events.contains { $0.fraction == 0 && $0.message.contains("packages to install") },
      "missing the planned-package count: \(events.map(\.message))"
    )
    XCTAssertTrue(
      events.contains { $0.fraction == 1 && $0.message.contains("Downloaded 3 / 3") },
      "missing the finished count: \(events.map(\.message))"
    )

    // The plan must come from a dry run, and the real install must not carry --dry-run.
    let npmCalls = runner.calls(matching: "npm")
    XCTAssertEqual(npmCalls.count, 2, "expected a dry run plus one install: \(npmCalls.map(\.arguments))")
    XCTAssertTrue(npmCalls[0].arguments.contains("--dry-run"))
    XCTAssertFalse(npmCalls[1].arguments.contains("--dry-run"))
    XCTAssertTrue(npmCalls[1].arguments.contains("@deepseek-ai/dsh@0.1.5-rc.1"))
  }

  func testUnparseablePlanLeavesTheInstallWorkingWithoutFractions() async throws {
    let root = try TestSupport.makeRoot(self)
    let (installer, _, log) = try makeInstaller(
      root: root,
      dryRun: .output("npm WARN registry returned a warning with no JSON\n")
    )

    let outcome = try await installer.install(.registry(version: "0.1.5-rc.1"), progress: { log.append($0) })
    XCTAssertEqual(outcome.release.version, "0.1.5-rc.1")
    XCTAssertTrue(
      log.all.allSatisfy { $0.fraction == nil },
      "a plan that cannot be read must not invent a fraction: \(log.all.map(\.fraction))"
    )
  }

  func testFailedDryRunIsNotFatal() async throws {
    let root = try TestSupport.makeRoot(self)
    let (installer, runner, log) = try makeInstaller(
      root: root,
      dryRun: .failure("npm ERR! network unreachable")
    )

    let outcome = try await installer.install(.registry(version: "0.1.5-rc.1"), progress: { log.append($0) })
    XCTAssertEqual(outcome.release.version, "0.1.5-rc.1")
    XCTAssertTrue(log.all.allSatisfy { $0.fraction == nil })
    XCTAssertTrue(runner.calls(matching: "npm").contains { !$0.arguments.contains("--dry-run") })
  }
}
