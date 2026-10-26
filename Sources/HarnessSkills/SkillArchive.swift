import Foundation

/// The result of one helper command.
public struct SkillCommandOutcome: Sendable, Equatable {
  public var status: Int32
  public var standardError: String

  public init(status: Int32, standardError: String) {
    self.status = status
    self.standardError = standardError
  }
}

/// The seam for running `ditto` / `tar` during an archive import.
///
/// A protocol rather than a direct `Process` call so the argument construction — the part
/// that decides which directory an archive is expanded into — is asserted in tests without
/// shelling out, and so the window can report a failed command instead of crashing on it.
public protocol SkillCommandRunning: Sendable {
  func run(executable: URL, arguments: [String], currentDirectory: URL?) throws -> SkillCommandOutcome
}

/// The real runner, backed by `Process`.
///
/// `Process` rather than `posix_spawn` (which `HarnessRuntime.ProcessRunner` uses for the
/// harness): these commands are short, synchronous, and their whole output is discarded
/// except for stderr, so the extra machinery there would buy nothing.
public struct SystemSkillCommandRunner: SkillCommandRunning {
  public init() {}

  public func run(executable: URL, arguments: [String], currentDirectory: URL?) throws -> SkillCommandOutcome {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = Pipe()
    do {
      try process.run()
    } catch {
      throw SkillCenterError.commandFailed(
        label: "\(executable.lastPathComponent) \(arguments.joined(separator: " "))",
        status: -1,
        message: error.localizedDescription
      )
    }
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return SkillCommandOutcome(
      status: process.terminationStatus,
      standardError: String(decoding: errorData, as: UTF8.self)
    )
  }
}

/// Which packed form an import source is.
public enum SkillArchiveKind: Sendable, Equatable {
  case zip
  case tarGzip

  /// Detect by extension, matching what the file picker offers.
  public static func detect(_ url: URL) -> SkillArchiveKind? {
    let name = url.lastPathComponent.lowercased()
    if name.hasSuffix(".zip") { return .zip }
    if name.hasSuffix(".tgz") || name.hasSuffix(".tar.gz") { return .tarGzip }
    return nil
  }

  public var title: String {
    switch self {
    case .zip: return "zip"
    case .tarGzip: return "tar.gz"
    }
  }

  /// The command that expands this archive into `directory`.
  ///
  /// `ditto -x -k` rather than `unzip`: it is the macOS tool that also restores resource
  /// forks and permission bits, and the project already uses it for session archives.
  public func extractionCommand(archive: URL, into directory: URL) -> (executable: URL, arguments: [String]) {
    switch self {
    case .zip:
      return (URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, directory.path])
    case .tarGzip:
      return (URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", directory.path])
    }
  }
}
