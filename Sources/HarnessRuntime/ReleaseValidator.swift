import Foundation
import HarnessKit

/// Confirms that an extracted directory really is a usable harness, and reads its
/// version out of the manifest rather than trusting a directory name or a release tag.
///
/// The entry point differs by source kind, which is why it is an explicit input rather
/// than a constant: a prebuilt package puts the CLI under `node_modules`, a source build
/// under `apps/cli`. Guessing here would mean a successful install that cannot start.
public struct ReleaseValidator: Sendable {
  /// Entry point inside a prebuilt harness package.
  public static let prebuiltEntry = "node_modules/@deepseek-ai/dsh/lib/bin.js"
  /// Entry point inside a built source checkout.
  public static let sourceEntry = "apps/cli/lib/bin.js"

  public let runner: ProcessRunning

  public init(runner: ProcessRunning = ProcessRunner()) {
    self.runner = runner
  }

  /// Where the `@deepseek-ai/dsh` manifest lives, relative to the release directory.
  private static func manifestPath(for kind: InstallSourceKind) -> String {
    switch kind {
    case .prebuiltArchive, .registry, .githubRelease:
      return "node_modules/@deepseek-ai/dsh/package.json"
    case .sourceArchive, .sourceDirectory:
      return "apps/cli/package.json"
    }
  }

  /// The entry point to record for a release of the given source kind.
  public static func entryPath(for kind: InstallSourceKind) -> String {
    switch kind {
    case .prebuiltArchive, .registry, .githubRelease: return prebuiltEntry
    case .sourceArchive, .sourceDirectory: return sourceEntry
    }
  }

  /// Read the harness version from an installed tree.
  public func version(ofDirectory directory: URL, kind: InstallSourceKind) throws -> String {
    let manifest = directory.appendingPathComponent(Self.manifestPath(for: kind))
    guard FileManager.default.isReadableFile(atPath: manifest.path) else {
      throw RuntimeError.archiveMissingEntry(Self.manifestPath(for: kind))
    }
    let data = try Data(contentsOf: manifest)
    let json = try JSONValue.parse(data, context: manifest.lastPathComponent)
    guard let version = json.string(at: "version"), !version.isEmpty else {
      throw RuntimeError.archiveRejected(reason: "\(manifest.lastPathComponent) declares no version")
    }
    return version
  }

  /// Verify structure and that the entry point exists.
  public func validate(directory: URL, kind: InstallSourceKind) throws -> String {
    let entry = Self.entryPath(for: kind)
    let entryURL = directory.appendingPathComponent(entry)
    guard FileManager.default.isReadableFile(atPath: entryURL.path) else {
      throw RuntimeError.archiveMissingEntry(entry)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: entryURL.path)
    guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
      throw RuntimeError.archiveMissingEntry("\(entry) (file is empty)")
    }
    return try version(ofDirectory: directory, kind: kind)
  }

  /// The strongest check available: actually start the CLI.
  ///
  /// `dsh --version` is used rather than `--help` because it exits without touching the
  /// filesystem or the network, and it is the one command that proves the Node runtime,
  /// the dependency tree, and the entry point agree with each other.
  public func smokeTest(
    directory: URL,
    kind: InstallSourceKind,
    node: URL,
    environment: [String: String],
    timeout: TimeInterval = 120
  ) async throws -> String {
    let entryURL = directory.appendingPathComponent(Self.entryPath(for: kind))
    let request = ProcessRequest(
      executable: node,
      arguments: [entryURL.path, "--version"],
      environment: environment,
      currentDirectory: directory,
      timeout: timeout,
      label: "dsh --version"
    )
    let result: ProcessResult
    do {
      result = try await runner.run(request, onLine: nil)
    } catch {
      throw RuntimeError.installFailed(step: "smoke test", detail: String(describing: error))
    }
    guard result.succeeded else {
      throw RuntimeError.installFailed(
        step: "smoke test",
        detail: "dsh --version exited \(result.exitCode)\n\(result.diagnostics())"
      )
    }
    let reported = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reported.isEmpty else {
      throw RuntimeError.installFailed(step: "smoke test", detail: "dsh --version printed nothing")
    }
    return reported
  }
}
