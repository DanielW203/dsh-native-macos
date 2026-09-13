import Foundation

/// The harness's own on-disk conventions for a Session log.
///
/// The channel only ever **reads** what it finds here. Session files belong to the
/// harness, and a native channel that rewrote one would turn a read-only integration
/// into a second writer racing the runtime — exactly the kind of interference the
/// zero-intrusion constraint forbids.
///
/// The escaping mirrors `@deepseek-ai/dsh-session-persistence-jsonl`'s `encodeSegment`
/// and `projectKey` character for character, including the deliberate lossiness of the
/// human-readable project key. A divergence here would silently point the reply watcher
/// at a directory that never exists, so it is covered by tests that spell out the
/// expected key for a realistic mixed ASCII/non-ASCII working directory.
public enum SessionPaths {
  public enum PathError: Error, Equatable {
    /// `encodeSegment` refuses an empty input, exactly as the harness does.
    case emptySegment
    /// `projectKey` refuses an empty working directory.
    case emptyProjectPath
  }

  /// Longest readable key the harness keeps before truncating for filesystem limits.
  static let projectKeyLimit = 251

  /// Whether one UTF-16 code unit survives unescaped.
  ///
  /// Matching is done on code units rather than `Character`s because JavaScript's
  /// `charCodeAt` — which produced every existing directory name — indexes UTF-16 code
  /// units, so an astral character becomes two `~XXXX` escapes, not one.
  static func isSafeUnit(_ unit: UInt16) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    if scalar == "~" { return false }
    switch scalar {
    case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-":
      return true
    default:
      return false
    }
  }

  /// Escape one path segment the way session ids are escaped (`~XXXX`, uppercase hex).
  ///
  /// - Parameter raw: the segment to encode; must not be empty.
  /// - Returns: a single filesystem-safe segment, decodable back to `raw`.
  public static func encodeSegment(_ raw: String) throws -> String {
    guard !raw.isEmpty else { throw PathError.emptySegment }
    if raw == "." { return "~002E" }
    if raw == ".." { return "~002E~002E" }
    var out = ""
    out.reserveCapacity(raw.utf16.count)
    for unit in raw.utf16 {
      if isSafeUnit(unit), let scalar = Unicode.Scalar(unit) {
        out.unicodeScalars.append(scalar)
      } else {
        out += escape(unit)
      }
    }
    return out
  }

  static func escape(_ unit: UInt16) -> String {
    let digits = String(unit, radix: 16, uppercase: true)
    return "~" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
  }

  /// Build the readable project-directory key for a Session's working directory.
  ///
  /// Separator runs collapse to a single `-`; anything else outside `[A-Za-z0-9._-]`
  /// becomes `~XXXX`. The result is intentionally lossy and always wrapped in `--…--`
  /// so it can never collide with a real directory name the user created.
  public static func projectKey(_ cwd: String) throws -> String {
    guard !cwd.isEmpty else { throw PathError.emptyProjectPath }
    var readable = ""
    var separatorRun = false
    readable.reserveCapacity(cwd.utf16.count)
    for unit in cwd.utf16 {
      guard let scalar = Unicode.Scalar(unit) else { continue }
      if scalar == "/" || scalar == "\\" || scalar == ":" {
        if !separatorRun { readable.append("-") }
        separatorRun = true
      } else if isSafeUnit(unit) {
        readable.unicodeScalars.append(scalar)
        separatorRun = false
      } else {
        readable += escape(unit)
        separatorRun = false
      }
    }
    var trimmed = Substring(readable)
    while trimmed.first == "-" { trimmed = trimmed.dropFirst() }
    var key = String(trimmed)
    if key.isEmpty { key = "root" }
    if key.count > projectKeyLimit { key = String(key.prefix(projectKeyLimit)) }
    return "--\(key)--"
  }

  /// `$DSH_HOME/sessions` — the root every project directory hangs under.
  public static func sessionsRoot(dshHome: URL) -> URL {
    dshHome.appendingPathComponent("sessions", isDirectory: true)
  }

  /// The directory one Session owns inside its project directory.
  ///
  /// The id is used **verbatim** (escaped only): the harness's ids already carry their
  /// `session-` prefix, so adding one would point at `session-session-…` and find nothing.
  /// Verified against a session created through the live API, whose directory is
  /// `<sessions>/<projectKey>/session-2fa88c3f-…`.
  public static func sessionDirectory(dshHome: URL, cwd: String, sessionID: String) throws -> URL {
    let key = try projectKey(cwd)
    let segment = try encodeSegment(sessionID)
    return sessionsRoot(dshHome: dshHome)
      .appendingPathComponent(key, isDirectory: true)
      .appendingPathComponent(segment, isDirectory: true)
  }

  /// The append-only log inside a Session directory, matched by shape rather than by name.
  ///
  /// The harness currently writes `session.v3.jsonl.zstd`, but the version segment is a
  /// format-catalog concern, not a contract the channel should freeze: a future harness
  /// that adds `v4` must keep working. When several match, the newest wins.
  ///
  /// - Returns: the log file, or `nil` when the directory holds none yet.
  public static func logFile(inSessionDirectory directory: URL) -> URL? {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return nil }
    let candidates = names.filter { $0.hasPrefix("session") && $0.hasSuffix(".jsonl.zstd") }
    guard !candidates.isEmpty else { return nil }
    let ranked = candidates.compactMap { name -> (URL, Date)? in
      let url = directory.appendingPathComponent(name)
      let modified = (try? manager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
      return (url, modified ?? .distantPast)
    }
    return ranked.max { lhs, rhs in lhs.1 < rhs.1 }?.0
  }
}
