import Foundation
import XCTest
@testable import HarnessRuntime

/// Thread-safe line sink for the streaming callback.
private final class LineBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var lines: [String] {
    lock.lock(); defer { lock.unlock() }
    return storage
  }

  func append(_ line: String) {
    lock.lock(); defer { lock.unlock() }
    storage.append(line)
  }
}

final class ProcessRunnerTests: XCTestCase {
  private let runner = ProcessRunner()

  func testSpawnReturnsAHandleToALiveProcess() async throws {
    let process = try await runner.spawn(ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["30"],
      label: "sleep 30"
    ))
    XCTAssertGreaterThan(process.pid, 0)
    XCTAssertTrue(process.isRunning)

    XCTAssertTrue(process.terminate())
    let result = await process.wait(timeout: 10)
    XCTAssertFalse(process.isRunning)
    // Terminated, not exited: the point of the group signal is that it does not run to
    // completion on its own.
    XCTAssertTrue(result.signalled || result.exitCode != 0)
  }

  func testSpawnStreamsLinesAndAggregatesOutput() async throws {
    let box = LineBox()
    let process = try await runner.spawn(ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["hello", "world"],
      label: "echo"
    )) { _, line in
      box.append(line)
    }
    let result = await process.wait(timeout: 10)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("hello world"))
    XCTAssertEqual(box.lines, ["hello world"])
  }

  func testWaitAppliesTheTimeoutAndStopsTheProcess() async throws {
    let started = Date()
    let process = try await runner.spawn(ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["60"],
      label: "sleep 60"
    ))
    let result = await process.wait(timeout: 1)
    XCTAssertTrue(result.timedOut)
    XCTAssertFalse(process.isRunning)
    XCTAssertLessThan(Date().timeIntervalSince(started), 15)
  }

  /// A grandchild that keeps the pipe open must not be able to hold `wait` open with it.
  ///
  /// `perl` calls `setsid()` here on purpose: it leaves the process group, so the group
  /// signal that stops the child cannot reach it, and it inherits the stdout pipe, so the
  /// reader sees no EOF for as long as it lives. A quit path that waited for the readers
  /// would never come back — which is exactly what a wedged "Restarting the app…" was.
  func testWaitIsBoundedWhenAGrandchildOutlivesTheGroupAndHoldsThePipe() async throws {
    let process = try await runner.spawn(ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c",
        "/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); sleep 8' & echo started",
      ],
      label: "detached grandchild"
    ))
    let started = Date()
    _ = await process.wait(timeout: 1)
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertLessThan(
      elapsed,
      5,
      "wait(timeout:) took \(elapsed)s: the reader join must be bounded, not unconditional"
    )
  }

  /// The delayed `SIGKILL` in `terminate` has to be able to tell its own process from a
  /// recycled pid. The command line is the identity; a pid that is alive but is running
  /// something else must not be signalled, and neither must one that is simply gone.
  func testIdentityCheckDistinguishesItsOwnProcessFromAnother() async throws {
    let mine = try await runner.spawn(ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["30"],
      label: "sleep 30"
    ))
    defer { _ = mine.terminate() }

    XCTAssertTrue(RunningProcess.isStill(pid: mine.pid, executable: "/bin/sleep"))
    XCTAssertFalse(RunningProcess.isStill(pid: mine.pid, executable: "/bin/cat"))
    XCTAssertFalse(RunningProcess.isStill(pid: 999_999, executable: "/bin/sleep"))
  }

  /// The identity check must not weaken the escalation it guards: a child of ours that
  /// ignores `SIGTERM` is still killed, on schedule.
  func testEscalationStillKillsAChildThatIgnoresSigterm() async throws {
    let started = Date()
    let process = try await runner.spawn(ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "trap '' TERM; sleep 30"],
      label: "ignores SIGTERM"
    ))
    XCTAssertTrue(process.terminate())
    let result = await process.wait(timeout: 20)
    XCTAssertFalse(process.isRunning)
    XCTAssertTrue(result.signalled, "it must have been killed, not waited out")
    XCTAssertLessThan(Date().timeIntervalSince(started), 20)
  }

  func testRunningSomethingStillReturnsItsResult() async throws {
    // The old entry point has to keep working unchanged for every existing caller.
    let result = try await runner.run(ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["ok"],
      label: "echo"
    ))
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
  }

  func testTerminateReportsFalseOnceTheProcessIsGone() async throws {
    let process = try await runner.spawn(ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["done"],
      label: "echo"
    ))
    _ = await process.wait(timeout: 10)
    XCTAssertFalse(process.terminate())
  }

  func testFailureToExecuteIsReported() async {
    do {
      _ = try await runner.spawn(ProcessRequest(
        executable: URL(fileURLWithPath: "/definitely/not/a/program"),
        label: "missing"
      ))
      XCTFail("spawning a nonexistent executable must fail")
    } catch let error as RuntimeError {
      XCTAssertEqual(error.code, "INSTALL_FAILED")
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }
}
