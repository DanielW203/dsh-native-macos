import Foundation
import XCTest
@testable import HarnessRuntime

/// The self-rebuild is three shell commands and a hand-off. What is worth testing is the
/// text of those commands: the paths come from the filesystem and are executed with the
/// user's privileges, so a quoting bug is not cosmetic.
final class SelfRebuildTests: XCTestCase {
  private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

  private func service(
    root: String = "/Users/example/Documents/my-project/harness-native",
    install: String? = nil,
    runner: any ProcessRunning = StubProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "", duration: 0) }
  ) -> SelfRebuild {
    SelfRebuild(
      checkout: RebuildCheckout(root: URL(fileURLWithPath: root, isDirectory: true)),
      installDirectory: URL(fileURLWithPath: install ?? "/Users/example/Applications", isDirectory: true),
      appName: "DSHNative.app",
      logURL: URL(fileURLWithPath: "/Users/example/.nativeharness/harness/logs/rebuild.log"),
      bundle: URL(fileURLWithPath: "/Users/example/Applications/DSHNative.app", isDirectory: true),
      home: home,
      runner: runner
    )
  }

  // MARK: - release

  func testReleaseRunsTheBuildScriptInTheCheckout() {
    let request = service().releaseRequest
    XCTAssertEqual(request.executable.path, "/bin/bash")
    XCTAssertEqual(
      request.arguments,
      ["/Users/example/Documents/my-project/harness-native/Tools/build.sh", "release"]
    )
    XCTAssertEqual(request.currentDirectory?.path, "/Users/example/Documents/my-project/harness-native")
  }

  func testStepsMatchTheDocumentedCommandLine() {
    XCTAssertEqual(RebuildStep.release.arguments, ["release"])
    XCTAssertEqual(RebuildStep.install.arguments, ["install", "--no-build"])
    XCTAssertEqual(RebuildStep.verify.arguments, ["verify"])
  }

  func testEnvironmentPinsTheScratchRootAndAddsToolPaths() {
    let environment = service().environment(base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/example"])
    // The checkout path contains non-ASCII characters on some machines, which breaks
    // swift-driver; the script's scratch root is the fix and it must not be left to chance.
    XCTAssertEqual(environment["HARNESS_ASCII_TMP"], SelfRebuild.defaultScratchRoot)
    XCTAssertEqual(environment["HOME"], "/Users/example")
    let entries = environment["PATH"]!.split(separator: ":").map(String.init)
    XCTAssertTrue(entries.contains("/opt/homebrew/bin"), environment["PATH"]!)
    XCTAssertTrue(entries.contains("/usr/bin"))
    XCTAssertEqual(entries.filter { $0 == "/usr/bin" }.count, 1, "PATH must not repeat entries")
  }

  func testSearchPathDoesNotDuplicateAnAlreadyPresentEntry() {
    let path = SelfRebuild.searchPath(home: home, inherited: "/opt/homebrew/bin:/custom/bin")
    let entries = path.split(separator: ":").map(String.init)
    XCTAssertEqual(entries.filter { $0 == "/opt/homebrew/bin" }.count, 1)
    XCTAssertTrue(entries.contains("/custom/bin"))
  }

  // MARK: - hand-off

  func testHandoffWaitsForThisProcessThenInstallsVerifiesAndReopens() {
    let script = service().handoffScript(waitingFor: 4242)
    // The wait is the first thing that runs: `install` replaces the bundle this process is
    // executing from, so nothing may touch it until the pid is gone.
    XCTAssertTrue(
      script.contains("i=0; while kill -0 4242 2>/dev/null && [ \"$i\" -lt 50 ]; do i=$((i + 1)); sleep 0.2; done; mkdir -p "),
      script
    )
    // ...and the wait is bounded: an app that will not quit must not strand a good build.
    XCTAssertTrue(script.contains("kill -9 4242"), script)
    XCTAssertTrue(script.contains("install --no-build --to '/Users/example/Applications'"), script)
    XCTAssertTrue(script.contains("verify --to '/Users/example/Applications'"), script)
    XCTAssertTrue(script.contains("/usr/bin/open -n '/Users/example/Applications/DSHNative.app'"), script)
    // A failed install must still bring the app back: the previous bundle is still there.
    XCTAssertTrue(script.hasSuffix("exit ${install_status:-1}"), script)
    XCTAssertTrue(script.contains("install_status=$?"), script)
    // The script is one line, so a leading `#` would comment out everything after it.
    XCTAssertFalse(script.hasPrefix("#"), script)
  }

  /// The deadline has to be real: an app still running when the patience is up is killed,
  /// and the install and the reopen happen anyway. Before this the script waited on
  /// `kill -0` forever, so a wedged app meant a build that never got installed.
  func testHandoffKillsAnAppThatOutstaysTheDeadlineAndStillInstalls() throws {
    let sandbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("handoff-deadline-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let manager = FileManager.default
    let checkout = sandbox.appendingPathComponent("harness-native", isDirectory: true)
    try manager.createDirectory(
      at: checkout.appendingPathComponent("Tools", isDirectory: true),
      withIntermediateDirectories: true
    )
    let recorded = sandbox.appendingPathComponent("build-sh-calls.log")
    try """
    #!/bin/bash
    printf '%s\\n' "$*" >> "\(recorded.path)"
    exit 0

    """.write(to: checkout.appendingPathComponent("Tools/build.sh"), atomically: true, encoding: .utf8)

    let log = sandbox.appendingPathComponent("logs/rebuild.log")
    let rebuild = SelfRebuild(
      checkout: RebuildCheckout(root: checkout),
      installDirectory: sandbox.appendingPathComponent("Applications", isDirectory: true),
      appName: "DSHNative.app",
      logURL: log,
      bundle: checkout,
      home: sandbox,
      runner: StubProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "", duration: 0) }
    )

    // A process that is genuinely alive for longer than the patience — the stand-in for the
    // app that never quits.
    let stubborn = Process()
    stubborn.executableURL = URL(fileURLWithPath: "/bin/sleep")
    stubborn.arguments = ["30"]
    try stubborn.run()
    defer { if stubborn.isRunning { stubborn.terminate() } }
    XCTAssertTrue(stubborn.isRunning)

    let script = rebuild.handoffScript(waitingFor: stubborn.processIdentifier, patience: 1)
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", script]
    shell.standardOutput = Pipe()
    shell.standardError = Pipe()
    try shell.run()
    shell.waitUntilExit()

    // It was killed rather than waited on...
    XCTAssertFalse(stubborn.isRunning, "the hand-off must kill an app that outstays its deadline")
    // ...and the rest of the hand-off ran anyway.
    let calls = try String(contentsOf: recorded, encoding: .utf8)
    XCTAssertTrue(calls.contains("install --no-build"), calls)
    XCTAssertTrue(calls.contains("verify"), calls)
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    XCTAssertTrue(text.contains("killing it"), text)
    XCTAssertTrue(text.contains("starting install"), text)
  }

  /// The script is only correct if it *runs*: this executes it against a stub `build.sh` and
  /// asserts the two commands the user asked for were actually invoked, in order.
  func testHandoffScriptActuallyRunsInstallAndVerify() throws {
    let sandbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let manager = FileManager.default
    let checkout = sandbox.appendingPathComponent("harness-native", isDirectory: true)
    try manager.createDirectory(at: checkout.appendingPathComponent("Tools", isDirectory: true), withIntermediateDirectories: true)
    let recorded = sandbox.appendingPathComponent("build-sh-calls.log")
    try """
    #!/bin/bash
    printf '%s\\n' "$*" >> "\(recorded.path)"
    exit 0

    """.write(to: checkout.appendingPathComponent("Tools/build.sh"), atomically: true, encoding: .utf8)

    let log = sandbox.appendingPathComponent("logs/rebuild.log")
    let install = sandbox.appendingPathComponent("Applications", isDirectory: true)
    let rebuild = SelfRebuild(
      checkout: RebuildCheckout(root: checkout),
      installDirectory: install,
      appName: "DSHNative.app",
      logURL: log,
      bundle: checkout,
      home: sandbox,
      runner: StubProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "", duration: 0) }
    )

    // A pid that cannot exist on macOS (kern.maxproc is far below it), so the wait ends at
    // once without the test having to kill anything.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", rebuild.handoffScript(waitingFor: 999_999)]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    let calls = try String(contentsOf: recorded, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
    XCTAssertEqual(calls.count, 2, calls.joined(separator: " | "))
    XCTAssertTrue(calls[0].hasPrefix("install --no-build --to "), calls[0])
    XCTAssertTrue(calls[1].hasPrefix("verify --to "), calls[1])

    // The install ran before the app was reopened, and the log records the hand-off.
    let text = try String(contentsOf: log, encoding: .utf8)
    XCTAssertTrue(text.contains("starting install"), text)
    XCTAssertTrue(text.contains("install exit=0"), text)
    XCTAssertTrue(text.contains("verify exit=0"), text)
  }

  /// A log directory that cannot be written must not cost the user their app.
  ///
  /// This is why the redirect is a group rather than `exec`: a redirection error from `exec`
  /// kills a non-interactive shell on the spot, and the reopen — which is the last thing the
  /// script does — would never run. The observation here is `open`'s own complaint about a
  /// bundle that does not exist: it can only be there if the script got past the failure.
  func testHandoffStillReopensWhenTheLogCannotBeWritten() throws {
    let sandbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("handoff-log-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let manager = FileManager.default
    let checkout = sandbox.appendingPathComponent("harness-native", isDirectory: true)
    try manager.createDirectory(at: checkout.appendingPathComponent("Tools", isDirectory: true), withIntermediateDirectories: true)
    try "#!/bin/bash\nexit 0\n".write(
      to: checkout.appendingPathComponent("Tools/build.sh"),
      atomically: true,
      encoding: .utf8
    )

    // A file where the log directory should be: `mkdir -p` fails and so does the group's
    // redirection, before a single command inside it has run.
    let blocked = sandbox.appendingPathComponent("blocked", isDirectory: false)
    try "not a directory".write(to: blocked, atomically: true, encoding: .utf8)
    let rebuild = SelfRebuild(
      checkout: RebuildCheckout(root: checkout),
      installDirectory: sandbox,
      appName: "DSHNative.app",
      logURL: blocked.appendingPathComponent("rebuild.log"),
      bundle: checkout,
      home: sandbox,
      runner: StubProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "", duration: 0) }
    )
    let script = rebuild.handoffScript(waitingFor: 999_999)
    XCTAssertFalse(script.contains("exec >>"), "a failed `exec` redirect exits the shell before the reopen")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertTrue(output.contains("DSHNative.app"), "the script never reached /usr/bin/open: \(output)")
  }

  func testHandoffQuotesAPathThatContainsASingleQuote() {
    let script = service(root: "/tmp/it's here/harness-native").handoffScript(waitingFor: 1)
    XCTAssertTrue(script.contains("'/tmp/it'\\''s here/harness-native/Tools/build.sh'"), script)
    XCTAssertTrue(script.contains("cd '/tmp/it'\\''s here/harness-native'"), script)
  }

  func testHandoffExportsTheAugmentedPathAndScratchRoot() {
    let script = service().handoffScript(waitingFor: 7)
    XCTAssertTrue(script.contains("export PATH="), script)
    XCTAssertTrue(script.contains("export HARNESS_ASCII_TMP='\(SelfRebuild.defaultScratchRoot)'"), script)
  }

  func testShellQuotingSurvivesAQuoteAndASpace() {
    XCTAssertEqual(SelfRebuild.shellQuoted("/tmp/plain"), "'/tmp/plain'")
    XCTAssertEqual(SelfRebuild.shellQuoted("/tmp/it's here"), "'/tmp/it'\\''s here'")
  }

  // MARK: - destinations

  func testInstallDirectoryKeepsAnAppAlreadyInHomeApplications() {
    let directory = SelfRebuild.installDirectory(
      bundle: home.appendingPathComponent("Applications/DSHNative.app", isDirectory: true),
      home: home
    )
    XCTAssertEqual(directory.path, home.appendingPathComponent("Applications").path)
  }

  func testInstallDirectoryFallsBackToHomeApplicationsForADerivedDataBuild() {
    let directory = SelfRebuild.installDirectory(
      bundle: URL(fileURLWithPath: "/tmp/harness-native-build/DSHNative.app", isDirectory: true),
      home: home
    )
    XCTAssertEqual(directory.path, home.appendingPathComponent("Applications").path)
  }

  func testInstallDirectoryForASystemAppIsApplicationsWhenWritable() {
    let directory = SelfRebuild.installDirectory(
      bundle: URL(fileURLWithPath: "/Applications/DSHNative.app", isDirectory: true),
      home: home
    )
    let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let expected = FileManager.default.isWritableFile(atPath: system.path)
      ? system
      : home.appendingPathComponent("Applications")
    XCTAssertEqual(directory.path, expected.path)
  }

  func testAppNameFallsBackWhenTheBundleIsNotAnApp() {
    XCTAssertEqual(SelfRebuild.appName(bundle: URL(fileURLWithPath: "/Applications/DSHNative.app")), "DSHNative.app")
    XCTAssertEqual(SelfRebuild.appName(bundle: URL(fileURLWithPath: "/tmp/HarnessRuntimeTests.xctest")), "DSHNative.app")
  }

  // MARK: - log

  func testAppendToLogCreatesTheFileAndAppends() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("self-rebuild-log-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("logs/rebuild.log")
    let service = SelfRebuild(
      checkout: RebuildCheckout(root: directory),
      installDirectory: directory,
      appName: "DSHNative.app",
      logURL: log,
      bundle: directory,
      home: directory,
      runner: StubProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "", duration: 0) }
    )
    service.appendToLog("first\n")
    service.appendToLog("second\n")
    XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "first\nsecond\n")
  }
}
