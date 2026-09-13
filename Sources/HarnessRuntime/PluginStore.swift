import Foundation
import HarnessKit

/// One installed plugin as the console shows it.
public struct PluginRecord: Sendable, Equatable, Identifiable {
  /// The dependency key. pnpm records the package's real name here even when the user
  /// asked for a git URL or a local path.
  public var name: String
  public var spec: String
  /// The version materialized in `node_modules`, which is the truth: a specifier may be
  /// a range or a URL and says nothing about what was installed.
  public var installedVersion: String?
  /// Whether the package declares `dsh.bundle`, i.e. whether it joins the layer stack.
  /// A dependency without it is installed but inert; saying so beats offering a toggle
  /// that would do nothing.
  public var isBundle: Bool
  /// Present in `dsh.profile.bundles`.
  public var isEnabled: Bool
  /// Disabled by a literal entry in `cordis.patch.yml` — usually written by another tool,
  /// which is why re-enabling asks first.
  public var isConfigDisabled: Bool
  /// Gated by an expression such as a platform check rather than a literal.
  public var isConditionallyDisabled: Bool
  public var repository: String?
  /// The `name` the installed manifest declares.
  ///
  /// Not always equal to `name`: an aliased dependency (`"foo": "npm:bar@1"`) and a `link:`
  /// install both make the dependency key differ from the package's own name, and the audit
  /// reports the package's name because that is what a user recognises.
  public var moduleName: String?
  /// The version the profile's `package.json` *asked for*. A range or URL says nothing about
  /// what was installed — that is `installedVersion` — but it does say what the user pinned.
  public var declaredVersion: String?
  /// `dsh.engines.dsh`, the ecosystem's own compatibility declaration.
  ///
  /// An optional convention, not a harness-enforced field: `DshManifest` does not type it and
  /// nothing in the harness validates it. It is honoured here because plugins write it, and
  /// an unparseable value is reported rather than judged.
  public var enginesRange: String?
  /// Whether the package declares `dsh.bundle.patch`, i.e. it contributes a Cordis layer.
  /// Kept beside `isBundle` so a reader does not have to infer which field was meant.
  public var hasBundlePatch: Bool
  /// `dsh.client.platform` for a package with a browser half, otherwise nil.
  public var clientPlatform: String?
  /// How many `dsh.client.inject` entries the package declares.
  public var clientInjectCount: Int
  /// The `@deepseek-ai/dsh-*` entries of `peerDependencies`, by package name.
  ///
  /// The second compatibility signal, and a more reliable one than `engines`: it names the
  /// exact harness packages the plugin was built against, and each one's actual version is
  /// readable from the active release.
  public var dshPeerRanges: [String: String]

  public var id: String { name }

  public init(
    name: String,
    spec: String,
    installedVersion: String? = nil,
    isBundle: Bool = false,
    isEnabled: Bool = false,
    isConfigDisabled: Bool = false,
    isConditionallyDisabled: Bool = false,
    repository: String? = nil,
    moduleName: String? = nil,
    declaredVersion: String? = nil,
    enginesRange: String? = nil,
    hasBundlePatch: Bool = false,
    clientPlatform: String? = nil,
    clientInjectCount: Int = 0,
    dshPeerRanges: [String: String] = [:]
  ) {
    self.name = name
    self.spec = spec
    self.installedVersion = installedVersion
    self.isBundle = isBundle
    self.isEnabled = isEnabled
    self.isConfigDisabled = isConfigDisabled
    self.isConditionallyDisabled = isConditionallyDisabled
    self.repository = repository
    self.moduleName = moduleName
    self.declaredVersion = declaredVersion
    self.enginesRange = enginesRange
    self.hasBundlePatch = hasBundlePatch
    self.clientPlatform = clientPlatform
    self.clientInjectCount = clientInjectCount
    self.dshPeerRanges = dshPeerRanges
  }
}

/// One profile under `$DSH_HOME/profiles`.
public struct ProfileSummary: Sendable, Equatable, Identifiable {
  public var name: String
  public var directory: URL
  public var bundles: [String]
  public var dependencyCount: Int
  /// A profile directory without a manifest has not been initialized by the harness yet.
  public var isInitialized: Bool

  public var id: String { name }
}

/// What a plugin mutation did.
public struct PluginOperationResult: Sendable, Equatable {
  public var changes: [String]
  public var warnings: [String]

  public init(changes: [String] = [], warnings: [String] = []) {
    self.changes = changes
    self.warnings = warnings
  }
}

/// Where an install gets its package from.
public enum PluginInstallSource: Sendable, Equatable {
  /// A directory on this machine — a checkout or an unpacked package. Installed as
  /// `link:<absolute path>`, so pnpm symlinks it and edits in the checkout are live.
  case localDirectory(URL)
  /// A packed tarball (`.tgz` / `.tar.gz`). Installed as `file:<absolute path>`.
  case localArchive(URL)
  /// A specifier passed through verbatim: a registry name, `pkg@1.2.3`, `github:owner/repo`,
  /// or a `file:`/`link:` URL. This is also the escape hatch for a relative path, which the
  /// harness anchors against the directory `dsh` was invoked from.
  case specifier(String)
}

/// The result of one install.
public struct PluginInstallOutcome: Sendable, Equatable {
  /// The specifier handed to `pnpm add`.
  public var spec: String
  /// Non-fatal findings, e.g. a build script pnpm refused to run.
  public var warnings: [String]
  /// Tail of the install's output, for the log.
  public var output: String
  /// The dependency keys this install added, in name order.
  ///
  /// A successful `dsh plugin add` does not say what it changed — it reconciles
  /// `dsh.profile.bundles` and exits — so the store diffs the profile's own dependencies
  /// around the command and reports the difference here. Empty means the command added
  /// nothing new (an install of something the profile already declared).
  public var installed: [String]

  public init(spec: String, warnings: [String] = [], output: String = "", installed: [String] = []) {
    self.spec = spec
    self.warnings = warnings
    self.output = output
    self.installed = installed
  }
}

/// What removing one plugin did.
public struct PluginRemovalOutcome: Sendable, Equatable {
  /// The dependency key that was removed.
  public var name: String
  /// Tail of the CLI's own output, for the log.
  public var output: String

  public init(name: String, output: String = "") {
    self.name = name
    self.output = output
  }
}

/// One package an install added, as this app remembers it.
///
/// The harness keeps no record of what a `dsh plugin add` changed: the CLI reconciles
/// `dsh.profile.bundles` and exits. So "undo the last install" needs a history of its own.
/// It lives beside the disabled ledger and is written in the app's own format — the harness
/// never reads it — and it is per profile, so a rollback cannot reach into another
/// profile's plugins. Installing and uninstalling stay the harness CLI's job; this is only
/// the note of what to name in the next `remove`.
public struct InstalledPluginRecord: Codable, Sendable, Equatable {
  /// The dependency key, which is what `dsh plugin … remove` takes.
  public var name: String
  /// The specifier the user asked for, so the confirmation can show it.
  public var spec: String
  /// ISO-8601, so the log can say when this happened.
  public var installedAt: String

  public init(name: String, spec: String, installedAt: String) {
    self.name = name
    self.spec = spec
    self.installedAt = installedAt
  }
}

/// How one install treats pnpm's release-age gate.
///
/// pnpm 11.21+ verifies *every* entry in the profile's lockfile against `minimumReleaseAge`
/// before it will change anything, and pnpm's own default for that gate is 24 hours. So a
/// single plugin released in the last day makes the whole profile refuse installs,
/// removals, and updates alike — including a command that names a completely unrelated
/// package. `dshmarket` meets this by retrying once with the override below; the console
/// asks the user first, because lifting a supply-chain gate is their call, not a retry
/// policy's.
public enum PluginInstallPolicy: Sendable, Equatable {
  /// pnpm's own policy, unmodified. This is the default, because the gate is protection
  /// the user already has by running a current pnpm.
  case standard
  /// Pass `--config.minimumReleaseAge=0` for this one command. Nothing is relaxed
  /// permanently: it is a flag on this run, and pnpm's default applies again to the next.
  case allowYoungReleases
}

/// Reads and toggles a profile's plugins, and installs new ones through the harness CLI.
///
/// **Scope of this type.** Reading, enabling, and disabling are implemented here because
/// they need nothing but the profile's own manifest, which is the only place the loader
/// looks. Installing a package is a subprocess — `dsh plugin --profile <p> add <spec>`,
/// which the harness forwards to pnpm and then reconciles `dsh.profile.bundles` against
/// the installed state — so `addPlugin` runs exactly that CLI rather than writing the
/// manifest itself: the reconciliation stays in one place, and every specifier the CLI
/// understands (registry, git, `file:`, `link:`, tarball) works here for free. Its output
/// is read back with `PnpmDiagnostics` so a refusal to run a build script is reported
/// instead of surfacing as a plugin that installed but does not work.
///
/// Disabling is expressed entirely as removal from `dsh.profile.bundles` — the only list
/// the loader consults — and the app keeps its own ledger so it can restore the entry.
/// That ledger is deliberately not a format the harness has to understand.
public actor PluginStore {
  public let paths: RuntimePaths
  private let runner: ProcessRunning
  private let baseEnvironment: [String: String]
  private let invocation: HarnessInvocation
  private let entryProvider: @Sendable () async throws -> URL

  public init(
    paths: RuntimePaths,
    entryProvider: @escaping @Sendable () async throws -> URL,
    runner: ProcessRunning = ProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.paths = paths
    self.entryProvider = entryProvider
    self.runner = runner
    self.baseEnvironment = baseEnvironment
    self.invocation = HarnessInvocation(paths: paths, runner: runner, baseEnvironment: baseEnvironment)
  }

  // MARK: - Installing

  /// Install one package into a profile through the harness CLI.
  ///
  /// Runs `dsh plugin --profile <profile> add <spec>`, which forwards to pnpm inside the
  /// profile and then reconciles `dsh.profile.bundles` against the installed state. The
  /// profile does not have to exist beforehand: the CLI initializes it on first use.
  ///
  /// - Parameters:
  ///   - source: where the package comes from.
  ///   - profile: the profile to install into.
  ///   - timeout: how long the install may run. The default is generous because a package
  ///     with native code compiles during install.
  ///   - policy: how to treat pnpm's release-age gate. The default leaves it in force; the
  ///     override exists for the one case where the gate refuses a command for a reason
  ///     the user can see and accept — a profile lockfile holding a release younger than
  ///     the gate blocks every change, whatever package it names.
  /// - Returns: the specifier that was used, plus anything pnpm refused to do.
  /// - Throws: `RuntimeError.installFailed` when the input is unusable or the CLI exits
  ///   non-zero. Nothing partial is left behind: on failure the message carries pnpm's own
  ///   output, and the caller re-reads the profile to see the real state.
  ///   `RuntimeError.youngReleaseBlocked` — under the standard policy — when the non-zero
  ///   exit was that gate, so the caller can offer the override instead of a dead end.
  @discardableResult
  public func addPlugin(
    _ source: PluginInstallSource,
    profile: String,
    timeout: TimeInterval = 3600,
    policy: PluginInstallPolicy = .standard
  ) async throws -> PluginInstallOutcome {
    let spec = try resolveSpec(source)
    // One profile mutation at a time, under the same lock the enable/disable path takes:
    // the CLI rewrites the very manifest this app writes. The lock is non-blocking, so a
    // second operation is told "another operation is in progress" rather than queueing
    // behind a build that may take ten minutes.
    let lock = try FileLock(url: paths.lockFile)
    defer { lock.release() }
    try lock.acquire(holderDescription: "plugin install into \(profile)")

    // Read the profile's dependencies around the command: the CLI reconciles the bundle
    // list but returns nothing this app can remember, and "undo the last install" needs
    // to know what was added.
    let before = installedNames(profile: profile)
    let entry = try await entryProvider()
    let request = try await invocation.request(
      entry: entry,
      arguments: Self.addArguments(spec: spec, profile: profile, policy: policy),
      timeout: timeout
    )
    let result = try await runner.run(request, onLine: nil)
    let output = result.diagnostics(maxLines: 40)

    guard result.succeeded else {
      // The gate is the one refusal worth separating out: its cause is visible in the
      // output, it is not about the package the user asked for, and the user can decide to
      // lift it. Everything else stays a plain install failure.
      if policy == .standard, Self.isYoungReleaseRefusal(output) {
        throw RuntimeError.youngReleaseBlocked(
          packages: Self.youngReleasePackages(in: output),
          detail: output
        )
      }
      throw RuntimeError.installFailed(
        step: "install \(spec) into \(profile)",
        detail: output
      )
    }

    // pnpm 11 can exit 0 after having skipped a dependency's build scripts, so a zero exit
    // code is not evidence that the install works. Reading the output is what turns "it
    // installed" into "it installed and here is what was skipped".
    let installed = installedNames(profile: profile).subtracting(before).sorted()
    if !installed.isEmpty {
      try recordInstalls(installed, spec: spec, profile: profile)
    }
    return PluginInstallOutcome(
      spec: spec,
      warnings: allowListWarnings(in: output),
      output: output,
      installed: installed
    )
  }

  /// The one-shot flag that lifts pnpm's release-age gate for a single command.
  ///
  /// Byte-for-byte the override `dshmarket` already uses (`RELEASE_AGE_OVERRIDE`): a
  /// different spelling would be a second thing to keep in step with pnpm, and both
  /// callers must relax exactly the same setting.
  public static let releaseAgeOverride = "--config.minimumReleaseAge=0"

  /// The `dsh plugin … add …` argument list for one install.
  ///
  /// The override sits between `add` and the specifier — pnpm accepts `--config.*` anywhere,
  /// and this is the order `dshmarket` uses, so a profile mangled by either caller gets the
  /// same command shape. `--profile <name>` is the CLI's own flag, consumed before pnpm.
  static func addArguments(spec: String, profile: String, policy: PluginInstallPolicy) -> [String] {
    var arguments = ["plugin", "--profile", profile, "add"]
    if policy == .allowYoungReleases { arguments.append(releaseAgeOverride) }
    arguments.append(spec)
    return arguments
  }

  /// The `dsh plugin … remove …` argument list for one uninstall.
  ///
  /// The same shape as `addArguments`, minus the specifier: pnpm takes the package name it
  /// recorded in the manifest, which is the dependency key the list is built from. The
  /// release-age gate refuses removals as readily as installs — one young lockfile entry
  /// blocks every change — so the override has to travel here too.
  static func removeArguments(name: String, profile: String, policy: PluginInstallPolicy) -> [String] {
    var arguments = ["plugin", "--profile", profile, "remove"]
    if policy == .allowYoungReleases { arguments.append(releaseAgeOverride) }
    arguments.append(name)
    return arguments
  }

  /// Whether a failed run was pnpm refusing the change because the profile holds a release
  /// younger than its release-age gate.
  ///
  /// Two codes, because the same cause reaches the user by two routes: the lockfile
  /// verification pass pnpm 11.21+ runs before any mutation, and the resolver's own
  /// "nothing old enough" error, which is what a re-resolution or an update reports.
  public static func isYoungReleaseRefusal(_ output: String) -> Bool {
    output.contains("ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION")
      || output.contains("ERR_PNPM_NO_MATURE_MATCHING_VERSION")
  }

  /// The `name@version` entries pnpm named as too young, in pnpm's own order.
  ///
  /// Read off the indented list pnpm prints under its `N lockfile entries failed
  /// verification:` header, and only from the lines that carry the reason — a bare package
  /// name elsewhere in the output is not evidence, so nothing is guessed from context. An
  /// empty result is legitimate: the second code above can arrive without the list, and the
  /// caller must still be able to offer the override.
  public static func youngReleasePackages(in output: String) -> [String] {
    var found: [String] = []
    for rawLine in output.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.contains("within the minimumReleaseAge cutoff") else { continue }
      guard let entry = line.split(separator: " ").first.map(String.init) else { continue }
      // `name@version`, and the version has to look like one: that is what keeps a bare
      // word or a stray URL from being read as a package.
      guard let separator = entry.lastIndex(of: "@"), separator != entry.startIndex,
            entry[entry.index(after: separator)...].first?.isNumber == true,
            !found.contains(entry) else { continue }
      found.append(entry)
    }
    return found
  }

  /// The specifier a source turns into, or a throw explaining why it cannot be one.
  private func resolveSpec(_ source: PluginInstallSource) throws -> String {
    switch source {
    case .localDirectory(let url):
      let path = url.standardizedFileURL.path
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw RuntimeError.installFailed(step: "install from \(path)", detail: "not a directory")
      }
      guard FileManager.default.fileExists(atPath: url.appendingPathComponent("package.json").path) else {
        throw RuntimeError.installFailed(
          step: "install from \(path)",
          detail: "no package.json — pick a package directory, not its parent or a source folder"
        )
      }
      return "link:\(path)"

    case .localArchive(let url):
      let path = url.standardizedFileURL.path
      guard FileManager.default.fileExists(atPath: path) else {
        throw RuntimeError.installFailed(step: "install from \(path)", detail: "no such file")
      }
      let lower = path.lowercased()
      guard lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.gz") else {
        throw RuntimeError.installFailed(step: "install from \(path)", detail: "expected a .tgz or .tar.gz")
      }
      return "file:\(path)"

    case .specifier(let raw):
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        throw RuntimeError.installFailed(step: "install", detail: "empty specifier")
      }
      guard !text.contains(where: \.isWhitespace) else {
        throw RuntimeError.installFailed(step: "install \(text)", detail: "a specifier cannot contain whitespace")
      }
      return text
    }
  }

  /// What pnpm skipped, phrased as something the user can act on.
  ///
  /// The allow-list key differs between pnpm 10 and 11, and writing one of them into the
  /// user's `pnpm-workspace.yaml` on a guess is worse than saying what to add — the same
  /// position `PnpmDiagnostics` takes.
  private func allowListWarnings(in output: String) -> [String] {
    var warnings: [String] = []
    switch PnpmDiagnostics.classify(output) {
    case .ignoredBuilds(let list):
      guard !list.isEmpty else {
        warnings.append("pnpm skipped at least one build script but did not name the package; see the console log.")
        return warnings
      }
      warnings.append(
        "pnpm skipped build scripts for \(list.packages.joined(separator: ", ")). If the plugin needs them, "
          + "add those names to pnpm-workspace.yaml (pnpm 10: onlyBuiltDependencies, pnpm 11: allowBuilds), "
          + "then install again."
      )
    case .gitPrepareNotAllowed(let list):
      guard !list.isEmpty else {
        warnings.append("pnpm refused a git dependency's prepare script but did not name it; see the console log.")
        return warnings
      }
      warnings.append(
        "pnpm refused the prepare script of \(list.packages.joined(separator: ", ")), which git-hosted packages "
          + "build with. Add those names to pnpm-workspace.yaml (pnpm 10: onlyBuiltDependencies, pnpm 11: allowBuilds), "
          + "then install again."
      )
    case .unrecognized(let text):
      warnings.append("pnpm reported a refusal this app could not attribute: \(text.suffix(200))")
    case .unrelated:
      break
    }
    return warnings
  }

  // MARK: - Removing

  /// Uninstall one package from a profile through the harness CLI.
  ///
  /// `dsh plugin --profile <p> remove <name>` forwards to pnpm and then reconciles
  /// `dsh.profile.bundles` against what is left, so the layer stack stays the CLI's
  /// business here too — this app never hand-edits the manifest an uninstall rewrites.
  ///
  /// Two refusals happen before any subprocess: the harness's own packages (removing
  /// `@deepseek-ai/dsh-base` leaves a profile that cannot boot at all, and nothing in this
  /// app could put it back), and a name the profile does not depend on.
  ///
  /// - Throws: `RuntimeError.unsupported` for either refusal;
  ///   `RuntimeError.youngReleaseBlocked` when pnpm's release-age gate refused the command;
  ///   `RuntimeError.installFailed` otherwise, carrying pnpm's own output.
  @discardableResult
  public func removePlugin(
    _ name: String,
    profile: String,
    timeout: TimeInterval = 600,
    policy: PluginInstallPolicy = .standard
  ) async throws -> PluginRemovalOutcome {
    guard !Self.isHarnessPackage(name) else {
      throw RuntimeError.unsupported(
        "\(name) is part of the harness itself; removing it would leave \(profile) unable to start"
      )
    }

    let lock = try FileLock(url: paths.lockFile)
    defer { lock.release() }
    try lock.acquire(holderDescription: "plugin remove from \(profile)")

    let manifestURL = profileDirectory(profile).appendingPathComponent("package.json")
    let manifest = try ProfileManifest.read(manifestURL)
    guard ProfileManifest.dependencies(manifest)[name] != nil else {
      throw RuntimeError.unsupported("\(name) is not installed in profile \(profile)")
    }

    let entry = try await entryProvider()
    let request = try await invocation.request(
      entry: entry,
      arguments: Self.removeArguments(name: name, profile: profile, policy: policy),
      timeout: timeout
    )
    let result = try await runner.run(request, onLine: nil)
    let output = result.diagnostics(maxLines: 40)

    guard result.succeeded else {
      if policy == .standard, Self.isYoungReleaseRefusal(output) {
        throw RuntimeError.youngReleaseBlocked(
          packages: Self.youngReleasePackages(in: output),
          detail: output
        )
      }
      throw RuntimeError.installFailed(step: "remove \(name) from \(profile)", detail: output)
    }

    // The package is gone, so this app's bookkeeping must not outlive it: a disabled mark
    // left behind would silently disable a future reinstall, and an install-log entry would
    // offer to "undo" something that is no longer installed.
    try clearDisabledLedger(profile: profile, name: name)
    try forgetInstalls(named: [name], profile: profile)
    return PluginRemovalOutcome(name: name, output: output)
  }

  /// Whether a package belongs to the harness rather than to the user.
  ///
  /// Checked by prefix, not by a list: the core bundle and everything that ships with a
  /// release share `@deepseek-ai/dsh-`, and a hard-coded list would drift with the next
  /// release. A third-party package that borrows the scope is refused too, which is the
  /// safe side for an uninstall button.
  public static func isHarnessPackage(_ name: String) -> Bool {
    name.hasPrefix("@deepseek-ai/dsh-")
  }

  /// Undo the newest recorded install that is still installed.
  ///
  /// - Returns: what was removed, or `nil` when there is nothing on record to undo — a
  ///   profile filled before this app started keeping the log, or one whose plugins arrived
  ///   some other way. Nothing is guessed from package names.
  @discardableResult
  public func undoLastInstall(
    profile: String,
    timeout: TimeInterval = 600,
    policy: PluginInstallPolicy = .standard
  ) async throws -> PluginRemovalOutcome? {
    guard let record = lastInstalledPlugin(profile: profile) else { return nil }
    return try await removePlugin(record.name, profile: profile, timeout: timeout, policy: policy)
  }

  // MARK: - Profiles

  public nonisolated func profileDirectory(_ profile: String) -> URL {
    paths.profilesDirectory.appendingPathComponent(profile, isDirectory: true)
  }

  public func profiles() throws -> [ProfileSummary] {
    ProfileCatalog.summaries(inProfilesDirectory: paths.profilesDirectory)
  }

  /// Create a profile from a shipped template without booting it.
  ///
  /// `--dump-config` is used on purpose: the documented contract is that it initializes a
  /// missing profile, prints the composed tree, and does not boot it — so no server is
  /// started and nothing is left running afterwards.
  public func initializeProfile(_ profile: String, template: String = "web") async throws -> PluginOperationResult {
    let entry = try await entryProvider()
    let request = try await invocation.request(
      entry: entry,
      arguments: ["--profile", profile, "--from-default-profile", template, "--dump-config"]
    )
    let result = try await runner.run(request, onLine: nil)
    guard result.succeeded else {
      throw RuntimeError.installFailed(
        step: "initialize profile \(profile)",
        detail: result.diagnostics(maxLines: 40)
      )
    }
    return PluginOperationResult(changes: ["initialized \(profile) from the \(template) template"])
  }

  // MARK: - Reading

  public nonisolated func plugins(profile: String) throws -> [PluginRecord] {
    let directory = profileDirectory(profile)
    let manifest = try ProfileManifest.read(directory.appendingPathComponent("package.json"))
    let dependencies = ProfileManifest.dependencies(manifest)
    let bundles = Set(ProfileManifest.bundleList(manifest))
    let patch = (try? String(contentsOf: directory.appendingPathComponent("cordis.patch.yml"), encoding: .utf8)) ?? ""

    var records: [PluginRecord] = []
    for (name, spec) in dependencies {
      let installed = try? ProfileManifest.read(directory.appendingPathComponent("node_modules/\(name)/package.json"))
      // The installed manifest's own `name` can differ from the dependency key after an
      // alias, so both are offered to the patch matcher.
      let aliases = [name, installed?["name"]?.stringValue].compactMap { $0 }
      let clientInject = installed?.path("dsh.client.inject")?.arrayValue ?? []
      records.append(
        PluginRecord(
          name: name,
          spec: spec,
          installedVersion: installed?["version"]?.stringValue,
          isBundle: installed?.path("dsh.bundle.patch")?.stringValue != nil,
          isEnabled: bundles.contains(name),
          isConfigDisabled: CordisPatchEditor.hasDisable(patch, named: aliases),
          isConditionallyDisabled: CordisPatchEditor.hasConditionalDisable(patch, named: aliases),
          repository: installed?.path("repository.url")?.stringValue ?? installed?["repository"]?.stringValue,
          moduleName: installed?["name"]?.stringValue,
          declaredVersion: Self.declaredVersion(fromSpec: spec),
          enginesRange: installed?.path("dsh.engines.dsh")?.stringValue,
          hasBundlePatch: installed?.path("dsh.bundle.patch")?.stringValue != nil,
          clientPlatform: installed?.path("dsh.client.platform")?.stringValue,
          clientInjectCount: clientInject.count,
          dshPeerRanges: Self.dshPeerRanges(installed)
        )
      )
    }
    return records.sorted { $0.name < $1.name }
  }

  /// The version part of a dependency specifier, when it is a plain version.
  ///
  /// Deliberately narrow: `link:`, `file:`, `github:` and bare ranges all answer nil. The
  /// point of showing this beside `installedVersion` is to surface "you asked for 0.1.5 and
  /// got 0.1.7"; pretending a URL has a version would defeat that.
  static func declaredVersion(fromSpec spec: String) -> String? {
    if spec.hasPrefix("link:") || spec.hasPrefix("file:") || spec.hasPrefix("git")
      || spec.hasPrefix("http") || spec.hasPrefix("npm:") || spec.hasPrefix("workspace:")
      || spec.contains("/") {
      return nil
    }
    // A compound range (`>=0.1.5-rc.1 <0.1.6-0`) is not a version, and the space is the
    // cheapest way to tell: stripping the leading operator first would otherwise leave a tail
    // that looks parseable.
    if spec.contains(" ") || spec.contains("||") { return nil }
    let trimmed = spec.hasPrefix("^") || spec.hasPrefix("~") || spec.hasPrefix(">")
      || spec.hasPrefix("<") || spec.hasPrefix("=")
      ? String(spec.dropFirst(spec.hasPrefix(">=") || spec.hasPrefix("<=") ? 2 : 1))
      : spec
    return Semver(trimmed) == nil ? nil : trimmed
  }

  /// The `@deepseek-ai/dsh-*` entries of an installed manifest's `peerDependencies`.
  ///
  /// Scoped to `@deepseek-ai/dsh-` on purpose: `@deepseek-ai/cordis` is a runtime dependency
  /// of the plugin system rather than of the harness version under test, and comparing it to
  /// a harness release would be meaningless.
  static func dshPeerRanges(_ manifest: JSONValue?) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in manifest?.path("peerDependencies")?.objectValue ?? [:] {
      guard key.hasPrefix("@deepseek-ai/dsh-") else { continue }
      guard let range = value.stringValue, !range.isEmpty else { continue }
      result[key] = range
    }
    return result
  }

  /// Which `@deepseek-ai/dsh-*` packages a profile's plugins declare as peers.
  ///
  /// The audit only needs the versions of packages that some plugin actually references, so
  /// this keeps `bundledDshVersions` from walking all ~241 packages of a release.
  public nonisolated func referencedDshPackages(profile: String) throws -> Set<String> {
    var names: Set<String> = []
    for record in try plugins(profile: profile) {
      names.formUnion(record.dshPeerRanges.keys)
    }
    return names
  }

  /// The versions of `@deepseek-ai/dsh-*` packages inside an installed release.
  ///
  /// The release is the truth for "what version of `@deepseek-ai/dsh-tools` is actually
  /// loaded", because a profile's `node_modules` only receives a copy when pnpm could not
  /// share the release's instance — which is itself a finding (`versionShadow`).
  public nonisolated func bundledDshVersions(
    releaseID: String?,
    packages: Set<String>
  ) throws -> [String: String] {
    guard let releaseID, !packages.isEmpty else { return [:] }
    let modules = paths.releaseDirectory(releaseID)
      .appendingPathComponent("node_modules", isDirectory: true)
    var result: [String: String] = [:]
    for name in packages {
      let manifest = try? ProfileManifest.read(modules.appendingPathComponent("\(name)/package.json"))
      guard let version = manifest?["version"]?.stringValue else { continue }
      result[name] = version
    }
    return result
  }

  /// The versions of `@deepseek-ai/dsh-*` packages inside an installed release, by release
  /// directory name rather than by release id.
  ///
  /// A second entry point because the audit has the active release id in one place
  /// (`installs.json`) and the directory in another; both resolve to `releases/<id>`, and
  /// keeping the join in one function is what stops the two callers from disagreeing.
  public nonisolated func bundledDshVersions(
    release: HarnessRelease?,
    packages: Set<String>
  ) throws -> [String: String] {
    try bundledDshVersions(releaseID: release?.id, packages: packages)
  }

  /// The `@deepseek-ai/dsh-*` packages a plugin carries a private copy of.
  /// A copy inside the plugin's own `node_modules` means pnpm could not satisfy the peer from
  /// the release, which is how a version mismatch shows up on disk rather than in a manifest.
  /// Returned per plugin so the audit can name both sides.
  public nonisolated func shadowedDshPackages(profile: String, records: [PluginRecord]) -> [String: [String]] {
    let directory = profileDirectory(profile)
    var result: [String: [String]] = [:]
    for record in records where !record.dshPeerRanges.isEmpty {
      let nested = directory
        .appendingPathComponent("node_modules", isDirectory: true)
        .appendingPathComponent(record.name, isDirectory: true)
        .appendingPathComponent("node_modules", isDirectory: true)
      var shadowed: [String] = []
      for name in record.dshPeerRanges.keys.sorted() {
        var isDirectory: ObjCBool = false
        let path = nested.appendingPathComponent(name, isDirectory: true).path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { continue }
        shadowed.append(name)
      }
      if !shadowed.isEmpty { result[record.name] = shadowed }
    }
    return result
  }

  /// Judge every plugin in a profile against the harness this app installed.
  ///
  /// The one place the audit's inputs are gathered, so a caller never has to remember that the
  /// harness version comes from `installs.json` while the package versions come from the release
  /// directory. Read-only and tolerant: a missing release leaves the engines claims unjudged
  /// rather than failing the whole list, because a profile's plugin list is worth showing even
  /// when no harness is installed.
  public nonisolated func compatibility(
    profile: String,
    activeReleaseID: String?
  ) throws -> [PluginCompatibility] {
    let records = try plugins(profile: profile)
    let referenced = records.reduce(into: Set<String>()) { names, record in
      names.formUnion(record.dshPeerRanges.keys)
    }
    let bundled = (try? bundledDshVersions(releaseID: activeReleaseID, packages: referenced)) ?? [:]
    let harnessVersion = activeReleaseID.flatMap { id in
      (try? InstallsIndex.load(from: paths.installsIndex))?.release(id: id)?.version
    }
    return PluginCompatibilityAudit.audit(
      records: records,
      harnessVersion: harnessVersion,
      bundledVersions: bundled,
      shadowed: shadowedDshPackages(profile: profile, records: records)
    )
  }

  // MARK: - Enable and disable

  /// Add or remove a plugin from the profile's layer stack, keeping its files on disk.
  ///
  /// This is the reversible operation, which is why it is the page's default action:
  /// re-enabling costs no network fetch.
  ///
  /// - Parameter stripConfigOverride: remove a `cordis.patch.yml` entry that also disables
  ///   the plugin. Off by default, because that entry was written by another tool and the
  ///   user should confirm before it is edited.
  public func setEnabled(
    _ name: String,
    enabled: Bool,
    profile: String,
    stripConfigOverride: Bool = false
  ) async throws -> PluginOperationResult {
    let lock = try FileLock(url: paths.lockFile)
    defer { lock.release() }
    try lock.acquire(holderDescription: enabled ? "plugin enable" : "plugin disable")

    let directory = profileDirectory(profile)
    let manifestURL = directory.appendingPathComponent("package.json")
    var manifest = try ProfileManifest.read(manifestURL)
    guard ProfileManifest.dependencies(manifest)[name] != nil else {
      throw RuntimeError.unsupported("\(name) is not installed in profile \(profile)")
    }

    var changes: [String] = []
    var warnings: [String] = []

    if enabled {
      var bundles = ProfileManifest.bundleList(manifest)
      if !bundles.contains(name) {
        // Appended, not re-sorted: layer order is meaningful and the harness itself
        // appends when it reconciles.
        bundles.append(name)
        manifest = ProfileManifest.setBundleList(manifest, bundles)
        changes.append("added \(name) to dsh.profile.bundles")
      }
      try ProfileManifest.write(manifest, to: manifestURL)
      if try clearDisabledLedger(profile: profile, name: name) {
        changes.append("cleared the disabled mark")
      }
      let aliases = try aliases(for: name, in: directory)
      if stripConfigOverride {
        if let text = try patchText(profile: profile),
           let updated = try CordisPatchEditor.stripDisable(text, named: aliases) {
          try updated.write(
            to: directory.appendingPathComponent("cordis.patch.yml"),
            atomically: true,
            encoding: .utf8
          )
          changes.append("removed the cordis.patch.yml disable entry")
        }
      } else if try hasPatchDisable(profile: profile, names: aliases) {
        warnings.append("\(name) is still disabled by cordis.patch.yml, so it will not load until that entry is removed.")
      }
    } else {
      let bundles = ProfileManifest.bundleList(manifest).filter { $0 != name }
      manifest = ProfileManifest.setBundleList(manifest, bundles)
      try ProfileManifest.write(manifest, to: manifestURL)
      try recordDisabled(profile: profile, name: name)
      changes.append("removed \(name) from dsh.profile.bundles")
    }

    // A running profile keeps the bundle set it started with, so saying so is part of
    // doing this correctly rather than a nicety.
    warnings.append("Restart the harness for this to take effect.")
    return PluginOperationResult(changes: changes, warnings: warnings)
  }

  // MARK: - The app's own disabled ledger

  private struct DisabledEntry: Codable, Sendable {
    var disabledAt: String
    var reason: String
  }

  private func ledgerURL(profile: String) -> URL {
    profileDirectory(profile).appendingPathComponent("native-plugin-state.json")
  }

  private func readLedger(profile: String) -> [String: DisabledEntry] {
    guard let data = try? Data(contentsOf: ledgerURL(profile: profile)) else { return [:] }
    return (try? JSONDecoder().decode([String: DisabledEntry].self, from: data)) ?? [:]
  }

  private func writeLedger(profile: String, _ ledger: [String: DisabledEntry]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(ledger)
    data.append(0x0A)
    try data.write(to: ledgerURL(profile: profile), options: .atomic)
  }

  @discardableResult
  private func recordDisabled(profile: String, name: String) throws -> Bool {
    var ledger = readLedger(profile: profile)
    ledger[name] = DisabledEntry(disabledAt: ISO8601DateFormatter().string(from: Date()), reason: "user")
    try writeLedger(profile: profile, ledger)
    return true
  }

  @discardableResult
  private func clearDisabledLedger(profile: String, name: String) throws -> Bool {
    var ledger = readLedger(profile: profile)
    guard ledger.removeValue(forKey: name) != nil else { return false }
    try writeLedger(profile: profile, ledger)
    return true
  }

  /// Names this app disabled, mapped to when.
  public func disabledLedger(profile: String) -> [String: String] {
    readLedger(profile: profile).mapValues { $0.disabledAt }
  }

  // MARK: - The app's install log

  /// How many installs to remember: long enough to undo a mistake the user made
  /// yesterday, short enough that the file stays something a person can read.
  private static let installLogLimit = 50

  private func installLogURL(profile: String) -> URL {
    profileDirectory(profile).appendingPathComponent("native-install-log.json")
  }

  /// Every install this app recorded for a profile, oldest first.
  public func installLog(profile: String) -> [InstalledPluginRecord] {
    guard let data = try? Data(contentsOf: installLogURL(profile: profile)) else { return [] }
    return (try? JSONDecoder().decode([InstalledPluginRecord].self, from: data)) ?? []
  }

  /// The newest recorded install that is still a dependency of the profile.
  ///
  /// Membership is checked against the manifest rather than trusted from the log, because
  /// the log is this app's memory and the manifest is the truth: a package removed by
  /// `dshmarket` or by hand must not be offered as something to undo.
  public func lastInstalledPlugin(profile: String) -> InstalledPluginRecord? {
    let installed = installedNames(profile: profile)
    return installLog(profile: profile).last { installed.contains($0.name) }
  }

  /// The dependency keys the profile declares right now.
  ///
  /// A missing or unreadable manifest reads as "nothing installed": the harness CLI creates
  /// a profile on first use, so an empty answer is a legitimate state, and guessing would be
  /// worse than an empty diff.
  private func installedNames(profile: String) -> Set<String> {
    let url = profileDirectory(profile).appendingPathComponent("package.json")
    guard let manifest = try? ProfileManifest.read(url) else { return [] }
    return Set(ProfileManifest.dependencies(manifest).keys)
  }

  private func recordInstalls(_ names: [String], spec: String, profile: String) throws {
    let stamp = ISO8601DateFormatter().string(from: Date())
    var log = installLog(profile: profile)
    // One entry per package, because a removal names one package.
    for name in names {
      log.append(InstalledPluginRecord(name: name, spec: spec, installedAt: stamp))
    }
    try writeInstallLog(log, profile: profile)
  }

  private func forgetInstalls(named names: [String], profile: String) throws {
    let log = installLog(profile: profile)
    let kept = log.filter { !names.contains($0.name) }
    guard kept.count != log.count else { return }
    try writeInstallLog(kept, profile: profile)
  }

  private func writeInstallLog(_ log: [InstalledPluginRecord], profile: String) throws {
    // Trimmed on write rather than on read: the file is the memory, and the newest records
    // have to be the ones that survive.
    let trimmed = log.count > Self.installLogLimit ? Array(log.suffix(Self.installLogLimit)) : log
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(trimmed)
    data.append(0x0A)
    try data.write(to: installLogURL(profile: profile), options: .atomic)
  }

  // MARK: - Patch helpers

  private func aliases(for name: String, in directory: URL) throws -> [String] {
    var result = [name]
    if let installed = try? ProfileManifest.read(directory.appendingPathComponent("node_modules/\(name)/package.json")),
       let declared = installed["name"]?.stringValue, declared != name {
      result.append(declared)
    }
    return result
  }

  private func patchText(profile: String) throws -> String? {
    let url = profileDirectory(profile).appendingPathComponent("cordis.patch.yml")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func hasPatchDisable(profile: String, names: [String]) throws -> Bool {
    guard let text = try patchText(profile: profile) else { return false }
    return CordisPatchEditor.hasDisable(text, named: names)
  }

}
