import Foundation

/// Where a resolved executable came from. Persisted and shown, because "why is it
/// using that Node" is the first question when an install behaves unexpectedly.
public enum ToolchainOrigin: String, Codable, Sendable {
  /// Installed by this app under `runtime/`.
  case appBundled
  /// Reused from the official Electron desktop's bundled runtime commands.
  case officialDesktop
  /// Found on the inherited `PATH`.
  case systemPath
  /// Fetched by this app because nothing usable was present.
  case fetched
}

/// A command that may need an interpreter in front of it.
///
/// `npm` is the reason this exists: in a Node distribution `npm` is a symlink to a
/// JavaScript file whose shebang says `#!/usr/bin/env node`, so executing it directly
/// resolves `node` from `PATH` and can pick a different Node than the one this app
/// resolved. Running it through the pinned Node is the only way the two agree.
public struct ToolchainExecutable: Sendable, Equatable {
  public var program: URL
  public var prefix: [String]

  public init(program: URL, prefix: [String] = []) {
    self.program = program
    self.prefix = prefix
  }

  /// Where the user should look to understand which npm this is.
  public var displayPath: String {
    prefix.last ?? program.path
  }
}

/// The executables every harness operation runs through.
public struct Toolchain: Sendable, Equatable {
  public var node: URL
  public var nodeVersion: String
  public var nodeOrigin: ToolchainOrigin

  /// An executable literally named `pnpm`, suitable as the first `PATH` entry.
  ///
  /// `dsh plugin` forwards to `pnpm` by name, so this has to be a file called
  /// `pnpm` — not `pnpm.cjs`, which is all the npm tarball ships.
  public var pnpm: URL?
  public var pnpmVersion: String?
  public var pnpmOrigin: ToolchainOrigin?

  /// `npm`, used to install a release from the registry. Resolved through the
  /// pinned Node rather than executed directly.
  public var npm: ToolchainExecutable?

  /// Human-readable notes about fallbacks that were taken, surfaced in the UI.
  public var notes: [String]

  public init(
    node: URL,
    nodeVersion: String,
    nodeOrigin: ToolchainOrigin,
    pnpm: URL? = nil,
    pnpmVersion: String? = nil,
    pnpmOrigin: ToolchainOrigin? = nil,
    npm: ToolchainExecutable? = nil,
    notes: [String] = []
  ) {
    self.node = node
    self.nodeVersion = nodeVersion
    self.nodeOrigin = nodeOrigin
    self.pnpm = pnpm
    self.pnpmVersion = pnpmVersion
    self.pnpmOrigin = pnpmOrigin
    self.npm = npm
    self.notes = notes
  }

  /// `dsh plugin` refuses to run without pnpm on `PATH`.
  public var canManagePlugins: Bool { pnpm != nil }
}

/// Finds — and, when necessary, installs — the executables the harness needs.
///
/// The order matters and is deliberate: anything this app installed wins, then the
/// official desktop's bundled runtime, then whatever the user already has. Reusing a
/// working runtime is preferred over fetching ~50 MB on first launch, but a bare
/// `node` found on `PATH` is never trusted without running `--version` against the
/// harness engine range.
public struct ToolchainResolver: Sendable {
  public let paths: RuntimePaths
  public let runner: ProcessRunning
  /// The environment children inherit before this app overwrites `DSH_HOME` / `PATH`.
  public let baseEnvironment: [String: String]

  public init(
    paths: RuntimePaths,
    runner: ProcessRunning = ProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.paths = paths
    self.runner = runner
    self.baseEnvironment = baseEnvironment
  }

  // MARK: - Resolution

  /// Resolve Node and pnpm, or throw a diagnostic naming exactly what is missing.
  public func resolve() async throws -> Toolchain {
    var notes: [String] = []
    var node: (URL, String, ToolchainOrigin)?

    for candidate in nodeCandidates() {
      guard let version = await version(of: candidate.url, argument: "--version") else { continue }
      let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "v", with: "", options: .anchored)
      guard NodeRequirement.accepts(normalized) else {
        notes.append("Ignored Node \(version) at \(candidate.url.path): needs \(NodeRequirement.display)")
        continue
      }
      node = (candidate.url, normalized, candidate.origin)
      break
    }

    guard let node else {
      throw RuntimeError.missingToolchain(
        "Node \(NodeRequirement.display). Install it with your package manager, or use "
          + "“Install Node…” in the app window, which fetches a copy into \(paths.nodeDirectory.path)."
      )
    }

    var toolchain = Toolchain(node: node.0, nodeVersion: node.1, nodeOrigin: node.2, notes: notes)

    toolchain.npm = resolveNpm(node: node.0)
    if toolchain.npm == nil {
      notes.append("npm was not found; installing a release from the registry needs it.")
    }

    if let pnpm = try? await resolvePnpm(node: node.0) {
      toolchain.pnpm = pnpm.0
      toolchain.pnpmVersion = pnpm.1
      toolchain.pnpmOrigin = pnpm.2
    } else {
      notes.append("pnpm was not found; installing the harness still works, but plugin management needs it.")
      toolchain.notes = notes
    }
    return toolchain
  }

  private func nodeCandidates() -> [(url: URL, origin: ToolchainOrigin)] {
    var candidates: [(URL, ToolchainOrigin)] = []

    // 1. What this app provisioned itself.
    if FileManager.default.isExecutableFile(atPath: paths.nodeBinary.path) {
      candidates.append((paths.nodeBinary, .appBundled))
    }

    // 2. A standalone Node on `PATH`, widened with the directories a Finder-launched app
    //    never inherits.
    var searchPaths = (baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
    searchPaths.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
    for directory in searchPaths where !directory.isEmpty {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent("node")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        candidates.append((candidate, .systemPath))
      }
    }

    // 3. The Electron desktop's bundled runtime, tried last.
    let desktopHome = baseEnvironment["HOME"].map {
      URL(fileURLWithPath: $0).appendingPathComponent("Library/Application Support/DSH Desktop", isDirectory: true)
    }
    if let desktopHome {
      let bundled = desktopHome
        .appendingPathComponent("runtime-commands/private/node-bin/node", isDirectory: false)
      if FileManager.default.isExecutableFile(atPath: bundled.path) {
        candidates.append((bundled, .officialDesktop))
      }
    }

    // Anything backed by an application bundle sinks to the bottom.
    //
    // macOS gives a process whose executable lives inside a `.app` a Dock tile, because
    // LaunchServices reads that bundle's `Info.plist` and concludes the process is an
    // application. The desktop's `node` is a shell shim that execs
    // `DSH Desktop.app/Contents/MacOS/DSH Desktop`, so using it as the runtime's Node put
    // a bouncing generic executable icon in the Dock for the whole of a two-minute npm
    // install: the child was working, but macOS was still trying to finish launching it
    // as an app. A standalone Node has no bundle and never appears there.
    let standalone = candidates.filter { !isBackedByApplicationBundle($0.0) }
    let appBundled = candidates.filter { isBackedByApplicationBundle($0.0) }
    return standalone + appBundled
  }

  /// Whether running this executable would start a process macOS considers an
  /// application, directly or through a wrapper script.
  ///
  /// Both shapes are checked because the desktop's `node` is the second one: a `sh` script
  /// that `exec`s a binary inside `.app/Contents/MacOS`. Testing only the candidate's own
  /// path would call that script harmless.
  func isBackedByApplicationBundle(_ url: URL) -> Bool {
    let resolved = url.resolvingSymlinksInPath()
    if resolved.path.contains(".app/Contents/") { return true }
    guard let handle = try? FileHandle(forReadingFrom: resolved),
          let head = try? handle.read(upToCount: 4096),
          let script = String(data: head, encoding: .utf8) else { return false }
    defer { try? handle.close() }
    guard script.hasPrefix("#!") else { return false }
    return script.contains(".app/Contents/")
  }

  /// Find `npm` beside Node first, then on `PATH`.
  ///
  /// Beside-first is not sufficient on its own: the bundled Electron runtime on this
  /// machine ships a bare `node` shim with no `npm` next to it, so the sibling lookup
  /// fails and `PATH` is the only source. Both candidates go through the same rule — a
  /// JavaScript entry point is run by the pinned Node, an executable is run directly —
  /// so the two paths cannot disagree about which interpreter wins.
  func resolveNpm(node: URL) -> ToolchainExecutable? {
    var candidates: [URL] = [node.deletingLastPathComponent().appendingPathComponent("npm")]
    var searchPaths = (baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
    searchPaths.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
    for directory in searchPaths where !directory.isEmpty {
      candidates.append(URL(fileURLWithPath: directory).appendingPathComponent("npm"))
    }

    for candidate in candidates {
      guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
      let resolved = candidate.resolvingSymlinksInPath()
      let name = resolved.lastPathComponent.lowercased()
      if name.hasSuffix(".js") || name.hasSuffix(".cjs") || name.hasSuffix(".mjs") {
        return ToolchainExecutable(program: node, prefix: [resolved.path])
      }
      return ToolchainExecutable(program: candidate)
    }
    return nil
  }

  private func resolvePnpm(node: URL) async throws -> (URL, String?, ToolchainOrigin) {
    // The shim this app owns: a file named `pnpm` that execs our `pnpm.cjs` through a
    // known-good Node. It wins because it is the only candidate whose Node is pinned.
    if FileManager.default.isReadableFile(atPath: paths.pnpmEntry.path) {
      try writePnpmShim(node: node)
      return (paths.pnpmShim, nil, .appBundled)
    }
    // A standalone pnpm is preferred over the desktop's shim for the same reason Node is:
    // the shim is an Electron wrapper, and an Electron child can surface a Dock tile.
    var searchPaths = (baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
    searchPaths.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
    for directory in searchPaths where !directory.isEmpty {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent("pnpm")
      if FileManager.default.isExecutableFile(atPath: candidate.path),
         !isBackedByApplicationBundle(candidate) {
        return (candidate, nil, .systemPath)
      }
    }
    let desktopShim = URL(fileURLWithPath: baseEnvironment["HOME"] ?? "/")
      .appendingPathComponent("Library/Application Support/DSH Desktop/runtime-commands/bin/pnpm")
    if FileManager.default.isExecutableFile(atPath: desktopShim.path) {
      return (desktopShim, nil, .officialDesktop)
    }
    throw RuntimeError.missingToolchain("pnpm")
  }

  /// Write `<root>/runtime/bin/pnpm`.
  ///
  /// Absolute paths are baked in on purpose: this file is executed by the harness with
  /// an environment this app controls, and depending on the user's shell configuration
  /// to supply a `node` would make plugin installs fail only for some users.
  public func writePnpmShim(node: URL) throws {
    try paths.createDirectories()
    let script = """
      #!/bin/sh
      # Generated by NativeHarness. Points at this app's own Node and pnpm.
      exec '\(node.path)' '\(paths.pnpmEntry.path)' "$@"
      """
    try script.write(to: paths.pnpmShim, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.pnpmShim.path)
  }

  // MARK: - Environment

  /// The environment every harness subprocess runs with.
  ///
  /// `DSH_HOME` is set here and nowhere else, which is what keeps this app's profiles,
  /// sessions, and plugins out of the official desktop's `~/.dsh`.
  ///
  /// `PATH` is built rather than inherited. An application launched from Finder receives
  /// only `/usr/bin:/bin:/usr/sbin:/sbin`, so a dependency's install script — koffi's
  /// `sh -c node ./cnoke.cjs …` is the one measured here — cannot find `node` at all,
  /// even though the install that spawned it is using a perfectly good one. The Node in
  /// use goes first so the script and the installer agree, then the usual tool
  /// directories so `make`, `python` and `git` are reachable too.
  ///
  /// - Parameter toolchain: the resolved toolchain, when the caller has one. Its Node
  ///   directory is what gets prepended.
  public func harnessEnvironment(
    for toolchain: Toolchain? = nil,
    extra: [String: String] = [:]
  ) -> [String: String] {
    var environment = baseEnvironment
    environment["DSH_HOME"] = paths.dshHome.path
    environment["DSH_TELEMETRY_DISABLED"] = "1"

    var pathEntries: [String] = []
    if let pnpm = currentPnpmDirectory { pathEntries.append(pnpm) }
    pathEntries.append(
      toolchain?.node.deletingLastPathComponent().path
        ?? paths.nodeBinary.deletingLastPathComponent().path
    )
    pathEntries.append(contentsOf: [
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ])
    pathEntries.append(contentsOf: (baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init))
    environment["PATH"] = pathEntries.filter { !$0.isEmpty }.joined(separator: ":")
    for (key, value) in extra { environment[key] = value }
    return environment
  }

  public var currentPnpmDirectory: String? {
    FileManager.default.isExecutableFile(atPath: paths.pnpmShim.path)
      ? paths.binDirectory.path
      : nil
  }

  /// Run `executable --version`, returning `nil` when it cannot be executed at all.
  public func version(of executable: URL, argument: String = "--version") async -> String? {
    var environment = baseEnvironment
    environment["PATH"] = [executable.deletingLastPathComponent().path, baseEnvironment["PATH"] ?? ""]
      .joined(separator: ":")
    let request = ProcessRequest(
      executable: executable,
      arguments: [argument],
      environment: environment,
      timeout: 30,
      label: "\(executable.lastPathComponent) \(argument)"
    )
    guard let result = try? await runner.run(request, onLine: nil), result.succeeded else { return nil }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
