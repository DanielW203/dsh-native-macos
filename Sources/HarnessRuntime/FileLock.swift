import Darwin
import Foundation

/// An advisory lock guarding every mutation of the harness directory.
///
/// `flock(2)` rather than an in-process lock because the subsystem is reachable from
/// three places at once — the SwiftUI console, `harnessctl`, and a background install
/// kicked off before the window opened — and each of them may be a separate process.
/// `LOCK_NB` is used so a second attempt reports "another operation is in progress"
/// instead of silently queueing behind a build that may take ten minutes.
final class FileLock: @unchecked Sendable {
  private let descriptor: Int32
  private var held = false

  init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else {
      throw RuntimeError.installFailed(step: "lock", detail: "cannot open \(url.path): \(String(cString: strerror(errno)))")
    }
    self.descriptor = fd
  }

  deinit {
    release()
  }

  /// Take the lock, or throw `operationInProgress` naming the holder when taken.
  func acquire(holderDescription: String) throws {
    guard !held else { return }
    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let detail = errno == EWOULDBLOCK
        ? "\(holderDescription) holds the runtime lock"
        : String(cString: strerror(errno))
      throw RuntimeError.operationInProgress(detail)
    }
    held = true
    // Best effort, purely so a human reading the file sees who has it. Never load-bearing.
    let stamp = "\(ProcessInfo.processInfo.processIdentifier) \(holderDescription)\n"
    ftruncate(descriptor, 0)
    _ = stamp.withCString { pointer in
      write(descriptor, pointer, strlen(pointer))
    }
  }

  func release() {
    guard held else { return }
    flock(descriptor, LOCK_UN)
    held = false
  }
}
