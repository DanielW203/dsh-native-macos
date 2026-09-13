import CryptoKit
import Foundation

/// Inspects and unpacks an imported harness artifact.
///
/// Extraction shells out to the system's `ditto` and `tar` rather than linking a zip
/// library. Two reasons: the package takes no external dependencies (CONTRACT `1.4),
/// and `ditto` is the only unzip on macOS that reproduces a `node_modules` tree
/// faithfully — symlinks, executable bits, and @-prefixed resource forks all matter
/// for a Node runtime, and a naive unzip silently flattens `.bin` shims into copies.
///
/// `CryptoKit` is used for digests. It is a system framework that ships with the OS,
/// not a package dependency, so the no-new-dependencies rule is intact.
public struct ArchiveInspector: Sendable {
  /// Refuse absurd archives before listing them; a harness package has tens of
  /// thousands of entries, so this is roughly 10x headroom.
  public static let maximumEntryCount = 500_000

  public enum Kind: Equatable, Sendable {
    case zip
    case tarGz
    case directory
  }

  public let runner: ProcessRunning

  public init(runner: ProcessRunning = ProcessRunner()) {
    self.runner = runner
  }

  // MARK: - Kind

  /// Classify by both extension and content, because a "GitHub source download" is
  /// whatever the browser named it and the extension is not authoritative.
  public static func kind(of url: URL) throws -> Kind {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw RuntimeError.installFailed(step: "inspect", detail: "\(url.path) does not exist")
    }
    if isDirectory.boolValue { return .directory }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let magic = (try? handle.read(upToCount: 4)) ?? Data()
    // PK\x03\x04 — a zip local file header.
    if magic.count >= 4, magic[magic.startIndex] == 0x50, magic[magic.startIndex + 1] == 0x4b {
      return .zip
    }
    // \x1f\x8b — gzip, i.e. a .tar.gz.
    if magic.count >= 2, magic[magic.startIndex] == 0x1f, magic[magic.startIndex + 1] == 0x8b {
      return .tarGz
    }
    let name = url.lastPathComponent.lowercased()
    if name.hasSuffix(".zip") { return .zip }
    if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
    throw RuntimeError.archiveRejected(reason: "\(name) is neither a zip nor a gzip archive")
  }

  // MARK: - Validation

  /// List an archive's entries and reject anything that would escape the destination.
  ///
  /// This runs *before* extraction. `ditto` will happily honour an entry named
  /// `../../Library/LaunchAgents/x.plist`, and a harness archive is untrusted input
  /// whenever it came from a browser download.
  @discardableResult
  public func validateEntries(of url: URL) async throws -> [String] {
    let kind = try Self.kind(of: url)
    switch kind {
    case .directory:
      return []
    case .zip:
      let result = try await runner.run(
        ProcessRequest(
          executable: URL(fileURLWithPath: "/usr/bin/unzip"),
          arguments: ["-Z1", url.path],
          timeout: 300,
          label: "unzip -Z1 \(url.lastPathComponent)"
        ),
        onLine: nil
      )
      guard result.succeeded else {
        throw RuntimeError.archiveRejected(reason: "cannot list zip: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
      return try Self.check(entries: result.stdout, archive: url)
    case .tarGz:
      let result = try await runner.run(
        ProcessRequest(
          executable: URL(fileURLWithPath: "/usr/bin/tar"),
          arguments: ["-tzf", url.path],
          timeout: 300,
          label: "tar -tzf \(url.lastPathComponent)"
        ),
        onLine: nil
      )
      guard result.succeeded else {
        throw RuntimeError.archiveRejected(reason: "cannot list archive: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
      return try Self.check(entries: result.stdout, archive: url)
    }
  }

  /// The path-safety rule, kept as a pure function so it is unit-testable without a
  /// real archive.
  static func check(entries output: String, archive: URL) throws -> [String] {
    let entries = output.split(separator: "\n").map { String($0) }
    guard entries.count <= maximumEntryCount else {
      throw RuntimeError.archiveRejected(
        reason: "\(archive.lastPathComponent) declares \(entries.count) entries, more than the \(maximumEntryCount) allowed"
      )
    }
    guard !entries.isEmpty else {
      throw RuntimeError.archiveRejected(reason: "\(archive.lastPathComponent) is empty")
    }
    for entry in entries {
      let trimmed = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
      if trimmed.isEmpty { continue }
      if trimmed.hasPrefix("/") {
        throw RuntimeError.archiveRejected(reason: "entry \(entry) uses an absolute path")
      }
      let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
      if components.contains("..") {
        throw RuntimeError.archiveRejected(reason: "entry \(entry) escapes the extraction directory")
      }
      if entry.contains("\u{0}") {
        throw RuntimeError.archiveRejected(reason: "entry contains a NUL byte")
      }
    }
    return entries
  }

  // MARK: - Extraction

  /// Unpack `url` into `destination`, which must not already contain the payload.
  public func extract(_ url: URL, to destination: URL) async throws {
    let kind = try Self.kind(of: url)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let request: ProcessRequest
    switch kind {
    case .directory:
      throw RuntimeError.unsupported("extract() called on a directory")
    case .zip:
      request = ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: ["-x", "-k", url.path, destination.path],
        timeout: 3600,
        label: "ditto -x -k \(url.lastPathComponent)"
      )
    case .tarGz:
      request = ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-xzf", url.path, "-C", destination.path],
        timeout: 3600,
        label: "tar -xzf \(url.lastPathComponent)"
      )
    }
    let result = try await runner.run(request, onLine: nil)
    guard result.succeeded else {
      throw RuntimeError.installFailed(
        step: "extract",
        detail: "\(request.label) exited \(result.exitCode)\n\(result.diagnostics())"
      )
    }
  }

  /// Copy a source checkout into staging. `ditto` is used rather than
  /// `FileManager.copyItem` so that symlinks inside `node_modules` are preserved if the
  /// user reuses a tree that has already been installed.
  public func copyDirectory(_ source: URL, to destination: URL) async throws {
    let result = try await runner.run(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: [source.path, destination.path],
        timeout: 3600,
        label: "ditto \(source.lastPathComponent)"
      ),
      onLine: nil
    )
    guard result.succeeded else {
      throw RuntimeError.installFailed(
        step: "copy",
        detail: "ditto exited \(result.exitCode)\n\(result.diagnostics())"
      )
    }
  }

  // MARK: - Measurement

  /// Streaming SHA-256. The digest identifies a release directory, so it has to be
  /// computed over the whole artifact rather than a prefix.
  public static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func byteCount(of url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }

  /// Bytes a directory occupies, walking it once.
  public static func byteCount(ofDirectory url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
      options: [],
      errorHandler: { _, _ in true }
    ) else { return 0 }
    var total: Int64 = 0
    for case let item as URL in enumerator {
      let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
    return total
  }

  /// Free space at `url`, in bytes.
  public static func availableBytes(at url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    if let capacity = values.volumeAvailableCapacityForImportantUsage { return Int64(capacity) }
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
    return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
  }
}
