import Foundation
import HarnessKit

/// Reading a set of profiles out of any Harness home.
///
/// `PluginStore` owns the profiles under this app's own `DSH_HOME`; this type is the same
/// reading applied to *another* home — the official desktop's `~/.dsh` — which is what
/// makes importing plugins from there possible without a second implementation of the
/// manifest rules.
public enum ProfileCatalog {
  /// One summary per profile directory under `directory`.
  ///
  /// A missing directory is an empty catalog rather than an error: a home that has never
  /// been booted legitimately has no profiles, and that is a state the UI shows, not a
  /// failure it reports.
  public static func summaries(inProfilesDirectory directory: URL) -> [ProfileSummary] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    var summaries: [ProfileSummary] = []
    for entry in entries {
      // The profiles directory also holds the installation's node_modules. It is a directory
      // like any other, and the harness refuses it as a profile name, so listing it as one
      // would offer the user a profile that cannot exist.
      guard entry.lastPathComponent != "node_modules" else { continue }
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values?.isDirectory == true || values?.isSymbolicLink == true else { continue }
      let manifest = try? ProfileManifest.read(entry.appendingPathComponent("package.json"))
      summaries.append(
        ProfileSummary(
          name: entry.lastPathComponent,
          directory: entry,
          bundles: manifest.map { ProfileManifest.bundleList($0) } ?? [],
          dependencyCount: manifest.map { ProfileManifest.dependencies($0).count } ?? 0,
          isInitialized: manifest != nil
        )
      )
    }
    return summaries.sorted { $0.name < $1.name }
  }
}

/// Reading and writing a profile's `package.json`.
///
/// The profile manifest is the only place the loader looks for the bundle list and the
/// dependency set, so both the plugin store and the importer edit it through these four
/// rules rather than each spelling them out.
public enum ProfileManifest {
  public static func read(_ url: URL) throws -> JSONValue {
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      throw RuntimeError.unsupported("no profile manifest at \(url.path)")
    }
    return try JSONValue.parse(try Data(contentsOf: url), context: url.lastPathComponent)
  }

  /// The declared dependencies, keyed by the name pnpm records.
  public static func dependencies(_ manifest: JSONValue) -> [String: String] {
    var result: [String: String] = [:]
    for (name, spec) in manifest["dependencies"]?.objectValue ?? [:] {
      result[name] = spec.stringValue ?? String(describing: spec)
    }
    return result
  }

  public static func setDependencies(_ manifest: JSONValue, _ dependencies: [String: String]) -> JSONValue {
    guard case .object(var root) = manifest else { return manifest }
    root["dependencies"] = .object(dependencies.mapValues { .string($0) })
    return .object(root)
  }

  public static func bundleList(_ manifest: JSONValue) -> [String] {
    (manifest.path("dsh.profile.bundles")?.arrayValue ?? []).compactMap { $0.stringValue }
  }

  public static func setBundleList(_ manifest: JSONValue, _ bundles: [String]) -> JSONValue {
    guard case .object(var root) = manifest else { return manifest }
    var dsh = root["dsh"]?.objectValue ?? [:]
    var profile = dsh["profile"]?.objectValue ?? [:]
    profile["bundles"] = .array(bundles.map { .string($0) })
    dsh["profile"] = .object(profile)
    root["dsh"] = .object(dsh)
    return .object(root)
  }

  /// Write a profile manifest with sorted keys.
  ///
  /// Sorting keeps repeated edits byte-stable; `bundles` is an array and keeps its
  /// order, which is the part that carries meaning.
  public static func write(_ manifest: JSONValue, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(manifest)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
  }
}

/// One harness invocation with the managed home and the pinned toolchain.
///
/// Two callers run the CLI — the plugin store, to initialize a profile, and the importer,
/// to compose one without booting it — and both must hand it the same environment, or a
/// check would be made against a different home than the one being edited.
public struct HarnessInvocation: Sendable {
  public let paths: RuntimePaths
  private let baseEnvironment: [String: String]
  private let toolchainResolver: ToolchainResolver

  public init(
    paths: RuntimePaths,
    runner: ProcessRunning = ProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.paths = paths
    self.baseEnvironment = baseEnvironment
    self.toolchainResolver = ToolchainResolver(paths: paths, runner: runner, baseEnvironment: baseEnvironment)
  }

  /// A Node invocation whose bare specifiers resolve from `directory`.
  ///
  /// `-e` rather than a script file on purpose: Node resolves a bare specifier from the
  /// evaluating module's URL, and for `--input-type=module -e` that URL sits in the working
  /// directory — so a check can import the profile's plugins through exactly the chain the
  /// loader uses, without leaving a file in the user's profile.
  public func nodeRequest(
    script: String,
    arguments: [String] = [],
    currentDirectory: URL,
    timeout: TimeInterval = 120,
    label: String
  ) async throws -> ProcessRequest {
    let toolchain = try await toolchainResolver.resolve()
    return ProcessRequest(
      executable: toolchain.node,
      arguments: ["--input-type=module", "-e", script] + arguments,
      environment: toolchainResolver.harnessEnvironment(for: toolchain),
      currentDirectory: currentDirectory,
      timeout: timeout,
      label: label
    )
  }

  /// Build a harness invocation with the managed home, the pinned Node, and pnpm first
  /// on `PATH`.
  ///
  /// The working directory is left alone so that a user-typed relative path is anchored
  /// where the user is, not inside the profile.
  public func request(entry: URL, arguments: [String], timeout: TimeInterval = 3600) async throws -> ProcessRequest {
    let toolchain = try await toolchainResolver.resolve()
    guard let pnpm = toolchain.pnpm else {
      throw RuntimeError.missingToolchain("pnpm, which the harness forwards plugin work to")
    }
    var environment = toolchainResolver.harnessEnvironment(for: toolchain)
    let pathEntries = [
      pnpm.deletingLastPathComponent().path,
      toolchain.node.deletingLastPathComponent().path,
      environment["PATH"] ?? "",
    ]
    environment["PATH"] = pathEntries.filter { !$0.isEmpty }.joined(separator: ":")
    return ProcessRequest(
      executable: toolchain.node,
      arguments: [entry.path] + arguments,
      environment: environment,
      timeout: timeout,
      label: "harness \(arguments.joined(separator: " "))"
    )
  }
}
