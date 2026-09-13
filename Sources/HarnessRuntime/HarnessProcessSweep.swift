import Darwin
import Foundation

/// Finds and stops harness servers that this app started and then lost track of.
///
/// The leak this exists to close is not a crash, it is a *shape*: the plugin market's
/// restart button does not bring its replacement up as this app's child. It spawns a
/// detached helper in a brand-new session, and that helper spawns the replacement — so
/// the process serving the UI has no process-group relationship to the app (see
/// `ProcessRunner`, which starts every child with `POSIX_SPAWN_SETPGROUP` precisely so
/// `kill(-pid)` stays surgical). Nothing in the app can reach that server afterwards:
///
///   - `stop()` terminates this app's own child process group, which the stray is not in.
///   - `takeOverStaleServer()` reads `server.json`, a single record, and the stray
///     overwrote it with its own pid/port when it booted.
///   - the installer's `remove(_:)` deletes a release directory while a process is still
///     executing the code in it, because a dead file is not a dead process.
///
/// The observable result, measured on this machine: after upgrading rc.1 → rc.2, three
/// `node` servers were alive under one home, one of them running a release directory that
/// no longer existed on disk, holding 384 MB and a session lock for two days.
///
/// So ownership is established by *what a process is running*, not by who its parent is.
/// Every harness server is `node <…>/lib/bin.js --profile …`; matching the entry point
/// against this app's own `harness/releases` tree identifies a server this app owns and
/// can therefore stop, wherever it came from and whoever spawned it.
enum HarnessProcessSweep {
  /// Every process the kernel will tell us about, paired with its argument vector.
  ///
  /// Argument lists are read with `KERN_PROCARGS2` rather than `proc_pidpath` because
  /// `proc_pidpath` returns the *executable* (`…/bin/node`), which is byte-identical
  /// across every harness server and every unrelated Node script on the machine. The
  /// argument vector is the only place the harness entry point appears.
  ///
  /// Processes owned by other users are reported by the kernel as `EPERM` and skipped:
  /// they cannot be ours, and they cannot be signalled anyway.
  static func commandLines() -> [(pid: pid_t, argv: [String])] {
    let hint = proc_listallpids(nil, 0)
    guard hint > 0 else { return [] }
    let count = max(Int(hint) + 64, 256)
    var pids = [pid_t](repeating: 0, count: count)
    let returned = proc_listallpids(&pids, Int32(count * MemoryLayout<pid_t>.size))
    guard returned > 0 else { return [] }

    var out: [(pid: pid_t, argv: [String])] = []
    for index in 0..<Int(returned) {
      let pid = pids[index]
      guard pid > 0, let argv = arguments(of: pid), !argv.isEmpty else { continue }
      out.append((pid: pid, argv: argv))
    }
    return out
  }

  /// The argument vector of one process, or `nil` when the kernel will not say.
  ///
  /// The buffer `KERN_PROCARGS2` returns is laid out as: a 4-byte `argc`, the executable
  /// path as a C string, then alignment padding, then `argc` NUL-terminated arguments.
  /// The padding is the part that bites — it can be one or more bytes and is not
  /// distinguishable from an argument by inspection, only by skipping to the first
  /// non-zero byte, which is what the second `while` below is for.
  static func arguments(of pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    guard buffer.count >= MemoryLayout<Int32>.size else { return nil }

    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    guard argc > 0 else { return [] }

    return buffer.withUnsafeBufferPointer { pointer -> [String]? in
      guard let base = pointer.baseAddress else { return nil }
      let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
      let total = pointer.count
      var offset = MemoryLayout<Int32>.size

      // Executable path, discarded: the interesting path is in argv[1].
      while offset < total, bytes[offset] != 0 { offset += 1 }
      while offset < total, bytes[offset] == 0 { offset += 1 }

      var argv: [String] = []
      while offset < total, argv.count < Int(argc) {
        let start = offset
        while offset < total, bytes[offset] != 0 { offset += 1 }
        if offset > start {
          argv.append(String(decoding: UnsafeBufferPointer(start: bytes + start, count: offset - start), as: UTF8.self))
        }
        while offset < total, bytes[offset] == 0 { offset += 1 }
      }
      return argv
    }
  }

  /// Harness servers running out of `releasesDirectory`, excluding `excluding`.
  ///
  /// The match looks for *any* argument that is a `bin.js` inside this app's release tree
  /// rather than reading `argv[1]` and trusting the position. That position is not stable:
  /// a process started through a shebang reports the interpreter as `argv[0]` and the
  /// script as `argv[1]`, while this app's own launch puts Node first and the entry point
  /// second. Scanning handles both and costs nothing — a false positive would require an
  /// unrelated process to be handed a script from inside this app's private release
  /// directory, which makes it this app's process by any reasonable definition.
  static func servers(
    under releasesDirectory: URL,
    excluding excludedPids: Set<pid_t> = []
  ) -> [(pid: pid_t, argv: [String])] {
    // Symlinks are resolved on BOTH sides before comparing. `standardizedFileURL` is not
    // enough: it only collapses `.` and `..`, so on macOS a test root under
    // `/var/folders/…` never matches the `/private/var/folders/…` the kernel reports,
    // and the sweep silently finds nothing — the worst possible failure for a reaper.
    let root = releasesDirectory.resolvingSymlinksInPath().path
    return commandLines().filter { entry in
      guard !excludedPids.contains(entry.pid) else { return false }
      return entry.argv.contains { argument in
        guard argument.hasSuffix("/lib/bin.js") || argument.hasSuffix("/bin.js") else { return false }
        let path = URL(fileURLWithPath: argument).resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
      }
    }
  }

  /// Stop the given processes: `SIGTERM`, a bounded wait, then `SIGKILL`.
  ///
  /// Signalling the pid is correct here where `ProcessRunner` signals a process *group*:
  /// a stray was deliberately started in its own session, so it is the leader of a group
  /// whose id equals its pid, and the group signal would reach exactly the same set.
  /// Never returns the current process or pid 1, which cannot be legitimately targeted.
  @discardableResult
  static func terminate(
    _ pids: [pid_t],
    grace: TimeInterval = 3,
    isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
  ) -> [pid_t] {
    let own = getpid()
    var signalled: [pid_t] = []
    for pid in Set(pids) where pid > 1 && pid != own {
      guard kill(pid, SIGTERM) == 0 || errno == EPERM else { continue }
      signalled.append(pid)
    }
    guard !signalled.isEmpty else { return [] }

    let deadline = Date().addingTimeInterval(grace)
    while Date() < deadline, signalled.contains(where: isAlive) {
      usleep(100_000)
    }
    for pid in signalled where isAlive(pid) {
      kill(pid, SIGKILL)
    }
    return signalled
  }
}
