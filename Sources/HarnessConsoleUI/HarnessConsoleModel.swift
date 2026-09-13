import AppKit
import Foundation
import HarnessKit
import HarnessRuntime
import SwiftUI

/// One line of the operation log.
public struct ConsoleLogLine: Identifiable, Sendable, Equatable {
  public enum Kind: String, Sendable {
    case info
    case progress
    case success
    case warning
    case failure
  }

  public let id = UUID()
  public var kind: Kind
  public var text: String
  public var time: Date

  public init(kind: Kind = .info, text: String, time: Date = Date()) {
    self.kind = kind
    self.text = text
    self.time = time
  }
}

/// An install pnpm refused because the profile's lockfile holds a release younger than its
/// age gate, held until the user answers.
///
/// pnpm 11.21+ verifies every lockfile entry against `minimumReleaseAge` (24 hours by
/// default) before any change, so one plugin released yesterday blocks the whole profile —
/// including a command that names an unrelated package. Lifting that gate is the user's
/// decision, so it is a question here rather than a silent retry: the prompt carries
/// everything needed to repeat the same command if they agree.
public struct YoungReleasePrompt: Sendable, Equatable, Identifiable {
  /// The install that was refused, kept whole so "go ahead" repeats exactly that request
  /// rather than re-reading the sheet's text field, which may have been edited. `nil` when
  /// the refused command was a *removal*, which is named by package rather than by
  /// specifier.
  public var source: PluginInstallSource?
  /// The package a refused removal named. `nil` for a refused install.
  public var removalName: String?
  /// What the sheet calls this operation, for the log and the buttons.
  public var label: String
  public var profile: String
  /// The `name@version` entries pnpm named as too young. May be empty: pnpm reports the
  /// same refusal by a second code that carries no list.
  public var packages: [String]
  /// pnpm's own output, so the user can read the refusal rather than a summary of it.
  public var detail: String

  public init(
    source: PluginInstallSource? = nil,
    removalName: String? = nil,
    label: String,
    profile: String,
    packages: [String],
    detail: String
  ) {
    self.source = source
    self.removalName = removalName
    self.label = label
    self.profile = profile
    self.packages = packages
    self.detail = detail
  }

  public var id: String { "\(profile)|\(label)|\(packages.joined(separator: ","))" }
}

/// Drives the runtime and plugin console.
///
/// Everything the console can do is a method here, and every method reports through the
/// same log — so the window never has to guess at what happened, and a failure that a
/// background task hit is visible in the same place as a success.
@MainActor
public final class HarnessConsoleModel: ObservableObject {
  // Runtime
  @Published public private(set) var runtimeRoot: String = ""
  @Published public private(set) var dshHome: String = ""
  @Published public private(set) var toolchain: Toolchain?
  @Published public private(set) var releases: [HarnessRelease] = []
  @Published public private(set) var activeReleaseID: String?
  /// The version of the release `activeReleaseID` names, for the compatibility window's header.
  ///
  /// Derived rather than stored: the id and the list are published separately, and a second copy
  /// of the version would be one more thing to keep in step with them.
  public var activeReleaseVersion: String? {
    releases.first { $0.id == activeReleaseID }?.version
  }
  @Published public private(set) var candidates: [HarnessUpdateCandidate] = []
  @Published public private(set) var channelNotes: [String] = []
  // Plugins
  @Published public private(set) var profiles: [ProfileSummary] = []
  @Published public var selectedProfile: String = "web"
  @Published public private(set) var plugins: [PluginRecord] = []
  /// Each plugin judged against the harness this app installed, by package name.
  ///
  /// A missing entry means "not judged" — an empty profile, or a harness release the audit could
  /// not read — so consumers must not treat absence as compatibility.
  @Published public private(set) var compatibility: [String: PluginCompatibility] = [:]
  /// Why the audit could not run at all. A missing release is not such a reason: it leaves the
  /// engines claims unjudged on purpose, which is a normal state.
  @Published public private(set) var compatibilityFailure: String?
  /// Why the plugin list is empty, when the reason is a failure rather than an empty
  /// profile. A profile that has not been created yet is a normal state and leaves this
  /// `nil` — the window offers to create it instead of shouting.
  @Published public private(set) var pluginsFailure: String?
  /// When the plugin list was last read, for the window's footer.
  @Published public private(set) var pluginsRefreshedAt: Date?
  /// Set when an install was refused by pnpm's release-age gate. The install sheet shows a
  /// confirmation and clears it; nothing proceeds until the user answers.
  @Published public private(set) var youngReleasePrompt: YoungReleasePrompt?
  /// The newest install this app recorded for the selected profile, when that package is
  /// still installed. What "Undo Last Install" would remove, and `nil` when there is
  /// nothing honest to offer.
  @Published public private(set) var lastInstalled: InstalledPluginRecord?

  // Importing a plugin set from another Harness home
  @Published public private(set) var importHomes: [PluginHome] = []
  @Published public private(set) var importHomePath: String = ""
  @Published public private(set) var importProfile: String = ""
  @Published public var conflictPolicy: PluginConflictPolicy = .preferSource
  @Published public private(set) var importPlan: PluginImportPlan?
  @Published public private(set) var lastImport: PluginImportOutcome?
  @Published public private(set) var importVerification: PluginImportVerification?

  // The running harness server
  @Published public private(set) var server: HarnessServerState = .stopped

  // Shared
  @Published public private(set) var log: [ConsoleLogLine] = []
  @Published public private(set) var isBusy = false
  @Published public private(set) var busyLabel: String?
  @Published public var importVersion: String = ""
  /// One line describing the most recent thing that happened. Always visible, on every
  /// tab: the operation log lives on its own tab, and feedback the user has to go looking
  /// for is indistinguishable from no feedback at all.
  @Published public private(set) var statusLine: String = "Ready."
  @Published public private(set) var statusKind: ConsoleLogLine.Kind = .info
  /// Where the log is mirrored on disk, so a failure can be read without the UI.
  @Published public private(set) var logFilePath: String = ""
  /// The outcome of the most recent install, for the sheet that started it.
  ///
  /// The operation log holds the same information, but a sheet that closes onto "nothing
  /// appeared to happen" is indistinguishable from a sheet that failed, so the install
  /// sheet carries its own result line.
  @Published public private(set) var lastInstallMessage: String?

  private var installer: HarnessInstaller?
  private var pluginStore: PluginStore?
  private var importer: ProfileImporter?
  private var launcher: (any HarnessLaunching)?
  /// A launcher the caller supplied, in place of the one built from `paths`.
  ///
  /// Production leaves it `nil`. It exists so a test can see what the console asks the
  /// harness to boot with — the working directory in particular — without a real server.
  private let injectedLauncher: (any HarnessLaunching)?
  /// Homes the user added by hand, kept across refreshes so the picker does not forget them.
  private var extraImportHomes: [URL] = []
  private var fetcher: HTTPFetching = URLSessionFetcher(userAgent: "NativeHarness")
  private var logFile: FileHandle?

  /// The runtime root this model operates on.
  ///
  /// Injected by its host — DSHNative hands the console and plugin windows the same
  /// `RuntimePaths` its other windows use, so the two can never drift onto a second home.
  private let paths: RuntimePaths

  /// Whether this surface is presented as a window inside DSHNative.
  ///
  /// Set by the host window before it appears. It changes wording and which controls are
  /// meaningful — the app's main window owns the harness server's lifecycle there — not
  /// what the console is able to read.
  public var presentedAsEmbeddedWindow = false

  /// The folder the harness is launched in, when the host knows one.
  ///
  /// The app's main window owns this choice: it persists it and hands it to its own launcher
  /// as the harness process's working directory, which is what the Web UI offers as the
  /// workspace a new session lands in. The console only reflects it here and forwards the
  /// picker through `chooseWorkspace` — a second copy of the choice in this model would let
  /// the two windows disagree about where the harness runs.
  ///
  /// `nil` means the host has no such notion, and the workspace card is not drawn at all.
  @Published public var workspacePath: String?

  /// Ask the host to pick a new workspace folder. `nil` until a host provides one.
  ///
  /// Main-actor isolated because the only thing it does is drive the host's own picker,
  /// which lives on the main actor like every other window here.
  public var chooseWorkspace: (@MainActor () -> Void)?

  /// The chosen folder as a URL, or `nil` when the host supplied none.
  ///
  /// `nil` is what this model passed before it knew about workspaces, so a console without a
  /// host still boots the harness exactly where it used to: in the harness home.
  public var workspaceURL: URL? {
    workspacePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  private static let logLimit = 500

  /// Whether `start()` has run. The console window and the plugin window are both hosts of
  /// this one model, so "start" has to mean "start once": the second window to open must
  /// join the loaded state rather than re-resolve the toolchain into the shared log.
  private var hasStarted = false

  /// - Parameters:
  ///   - paths: the runtime root to operate on — resolved by the host so the model
  ///     cannot drift onto a second home.
  ///   - launcher: the thing that boots the harness, when the caller has one to hand in.
  ///     The app leaves it `nil` and gets the real launcher built from `paths`; a test uses
  ///     it to read back what the console asks for without starting a server.
  public init(paths: RuntimePaths, launcher: (any HarnessLaunching)? = nil) {
    self.paths = paths
    self.injectedLauncher = launcher
  }

  // MARK: - Lifecycle

  /// Load the model if it is not loaded yet. Every window calls this, and only the first
  /// call does work.
  ///
  /// A start that failed is not latched: the next window to open tries again, because the
  /// usual failure is a directory that is not there yet and the fix is something the user
  /// just did outside the app.
  public func startIfNeeded() async {
    guard !hasStarted else { return }
    hasStarted = await start()
  }

  /// - Returns: whether the model was set up. `false` means everything below stayed empty
  ///   and the reason is in the log.
  @discardableResult
  public func start() async -> Bool {
    do {
      try paths.createDirectories()
      runtimeRoot = paths.root.path
      dshHome = paths.dshHome.path
      let installer = HarnessInstaller(paths: paths)
      self.installer = installer
      openLogFile(in: paths)
      // A staging directory only ever belongs to a process that is still running: the
      // one that created it renames it into place or leaves it behind on failure. So
      // anything found when this process first loads the console is debris from an
      // interrupted install — which on this machine was several hundred megabytes of
      // half-downloaded packages each time the app was killed mid-install.
      //
      // This used to be conditional, because a standalone console app could be installing
      // in *its* process while DSHNative had live staging in its own. There is one host
      // now, and `startIfNeeded` runs the sweep before either window can start an install,
      // so anything here can only be debris.
      let pruned = await installer.pruneStaging()
      if pruned > 0 {
        append(.info, "Cleaned \(pruned) leftover staging director\(pruned == 1 ? "y" : "ies") from interrupted installs.")
      }
      // The plugin store resolves the active release lazily so installing a runtime and
      // then managing plugins works without restarting the app.
      self.pluginStore = PluginStore(paths: paths) { try await installer.activeEntryURL() }
      self.importer = ProfileImporter(paths: paths) { try await installer.activeEntryURL() }
      self.launcher = injectedLauncher
        ?? HarnessLauncher(paths: paths) { try await installer.activeEntryURL() }
    } catch {
      append(.failure, String(describing: error))
      return false
    }
    await refresh()
    return true
  }

  /// Reload everything that can change without a long-running operation.
  public func refresh() async {
    await refreshToolchain()
    await refreshReleases()
    await refreshProfiles()
    await refreshPlugins()
    await refreshImportHomes()
    await refreshServer()
  }

  /// Re-read the server state, so a harness that exited on its own stops looking running.
  public func refreshServer() async {
    guard let launcher else { return }
    server = await launcher.state()
  }

  public func refreshToolchain() async {
    guard let installer else { return }
    do {
      let resolved = try await installer.toolchain()
      toolchain = resolved
      append(.info, "Node \(resolved.nodeVersion) [\(resolved.nodeOrigin.rawValue)]")
      if let pnpm = resolved.pnpm {
        append(.info, "pnpm [\(resolved.pnpmOrigin?.rawValue ?? "unknown")] \(pnpm.path)")
      } else {
        append(.warning, "pnpm was not found; plugin work needs it.")
      }
      for note in resolved.notes { append(.warning, note) }
    } catch {
      toolchain = nil
      append(.failure, describe(error))
    }
  }

  public func refreshReleases() async {
    guard let installer else { return }
    do {
      let index = try await installer.index()
      releases = try await installer.releases()
      activeReleaseID = index.active
    } catch {
      append(.failure, describe(error))
    }
  }

  public func refreshProfiles() async {
    guard let pluginStore else { return }
    do {
      profiles = try await pluginStore.profiles()
      if !profiles.contains(where: { $0.name == selectedProfile }), let first = profiles.first {
        selectedProfile = first.name
      }
    } catch {
      append(.failure, describe(error))
    }
  }

  public func refreshPlugins() async {
    guard let pluginStore else { return }
    do {
      plugins = try await pluginStore.plugins(profile: selectedProfile)
      lastInstalled = await pluginStore.lastInstalledPlugin(profile: selectedProfile)
      pluginsFailure = nil
      pluginsRefreshedAt = Date()
    } catch {
      plugins = []
      lastInstalled = nil
      // A profile that does not exist yet is a normal state, not an error worth shouting
      // about; the window offers to create it. Anything else is a failure the list must
      // show, because a silently empty list reads as "no plugins installed".
      let exists = profiles.contains { $0.name == selectedProfile }
      pluginsFailure = exists ? describe(error) : nil
    }
    await refreshCompatibility()
  }

  /// Re-read the compatibility verdicts for the selected profile.
  ///
  /// Separate from `refreshPlugins` so a failure here cannot empty the plugin list: the two read
  /// the same profile but answer different questions, and "which plugins exist" must survive
  /// "can I judge them".
  public func refreshCompatibility() async {
    guard let pluginStore else { return }
    do {
      let verdicts = try await pluginStore.compatibility(
        profile: selectedProfile,
        activeReleaseID: activeReleaseID
      )
      compatibility = Dictionary(uniqueKeysWithValues: verdicts.map { ($0.record.name, $0) })
      compatibilityFailure = nil
    } catch {
      compatibility = [:]
      compatibilityFailure = describe(error)
    }
  }

  /// The judgement for one plugin, or nil when the audit has not run for it.
  public func compatibility(for plugin: PluginRecord) -> PluginCompatibility? {
    compatibility[plugin.name]
  }

  public func selectProfile(_ name: String) async {
    selectedProfile = name
    await refreshPlugins()
  }

  // MARK: - Runtime operations

  /// Install from a local artifact or source checkout the user picked.
  public func install(source: InstallSource) async {
    guard let installer else { return }
    await run("Installing \(source.kind.displayName)") {
      let outcome = try await installer.install(source, progress: self.progressReporter)
      for warning in outcome.warnings { self.append(.warning, warning) }
      self.append(
        outcome.reused ? .info : .success,
        outcome.reused
          ? "\(outcome.release.id) is already installed and was reused."
          : "Installed \(outcome.release.id) (\(outcome.release.version))."
      )
      await self.refreshReleases()
    }
  }

  /// Classify a user-picked path and install it.
  public func install(path: String) async {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    do {
      switch try ArchiveInspector.kind(of: url) {
      case .directory:
        await install(source: .sourceDirectory(url: url))
      case .zip, .tarGz:
        // A downloaded release asset is a prebuilt package; anything else the user can
        // force through the source path by zipping a checkout instead.
        await install(source: .prebuiltArchive(url: url, expectedDigest: nil))
      }
    } catch {
      append(.failure, describe(error))
    }
  }

  /// Install a version from the npm registry — the official publication channel.
  ///
  /// An empty version field means "the published latest", not "do nothing": requiring the
  /// user to know a version number before the button does anything is the kind of silent
  /// refusal that reads as a broken button.
  public func installFromRegistry() async {
    var version = importVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    if version.isEmpty {
      append(.info, "No version given; asking the registry for the latest.")
      guard let latest = await latestPublishedVersion() else {
        append(.failure, "Could not read the latest version from the registry. Type a version, for example 0.1.5-rc.1.")
        return
      }
      version = latest
      importVersion = latest
    }
    await install(source: .registry(version: version))
  }

  /// §dist-tags.latest§ from the registry, or §nil§ when it cannot be read.
  public func latestPublishedVersion() async -> String? {
    guard let url = URL(string: "https://registry.npmjs.org/@deepseek-ai/dsh") else { return nil }
    guard let response = try? await fetcher.fetch(url, timeout: 15), response.statusCode == 200 else {
      return nil
    }
    let json = try? JSONValue.parse(response.data, context: "npm registry document")
    return json?["dist-tags"]?["latest"]?.stringValue
  }

  /// Fill the version field with the published latest.
  public func fillLatestVersion() async {
    await run("Reading the latest published version") {
      guard let latest = await self.latestPublishedVersion() else {
        throw RuntimeError.unsupported("the registry did not return a latest version")
      }
      self.importVersion = latest
      self.append(.success, "Latest published version is \(latest).")
    }
  }

  /// Ask both update channels what is newer than what is installed.
  public func checkForUpdates() async {
    let current = activeReleaseVersion
    candidates = []
    channelNotes = []
    await run("Checking for updates") {
      let channels: [any HarnessUpdateChannel] = [
        RegistryChannel(includePrereleases: true),
        GitHubChannel(),
      ]
      for channel in channels {
        let result = await channel.check(current: current, fetcher: self.fetcher)
        switch result {
        case .candidates(let list):
          self.candidates.append(contentsOf: list)
          self.append(.success, "\(channel.displayName): \(list.count) newer version(s).")
        case .upToDate(let version):
          self.channelNotes.append("\(channel.displayName): up to date (\(version ?? "unknown")).")
        case .unreachable(let detail):
          self.channelNotes.append("\(channel.displayName): unreachable — \(detail)")
        case .failed(let detail):
          self.channelNotes.append("\(channel.displayName): \(detail)")
        }
      }
      for note in self.channelNotes { self.append(.info, note) }
    }
  }

  public func activate(_ id: String) async {
    guard let installer else { return }
    await run("Activating \(id)") {
      try await installer.activate(id)
      self.append(.success, "\(id) is now active.")
      await self.refreshReleases()
      await self.refreshPlugins()
    }
  }

  public func remove(_ id: String) async {
    guard let installer else { return }
    await run("Removing \(id)") {
      try await installer.remove(id)
      self.append(.success, "Removed \(id).")
      await self.refreshReleases()
    }
  }

  // MARK: - Running the harness

  /// Boot the harness Web surface and open it.
  ///
  /// The chosen workspace is handed over as the harness's working directory, exactly as the
  /// main window does it: without it, a harness started here would come up in the harness
  /// home and quietly register a *second* workspace that the toolbar never named.
  public func startHarness() async {
    guard let launcher else { return }
    let profile = selectedProfile
    let workspace = workspaceURL
    await run("Starting the harness (\(profile) profile)") {
      let state = try await launcher.start(
        profile: profile,
        host: "127.0.0.1",
        workingDirectory: workspace,
        timeout: 120,
        onLine: { line in Task { @MainActor in self.append(.progress, line) } },
        onStage: { _ in }
      )
      self.server = state
      let address = state.url ?? "an unknown URL"
      self.append(.success, "Harness is listening on \(address)")
      if let url = state.url { self.openInBrowser(url) }
    }
    await refreshServer()
  }

  /// Stop the server without the busy guard.
  ///
  /// A quit must not be skipped because an install happened to be running: the harness
  /// runs in its own process group, so nothing else will stop it and the next launch
  /// would find a server nobody owns.
  public func stopServerForTermination() async {
    guard let launcher else { return }
    await launcher.stop(timeout: 15)
    server = .stopped
  }

  /// Stop the server.
  public func stopHarness() async {
    guard let launcher else { return }
    await run("Stopping the harness") {
      await launcher.stop(timeout: 15)
      self.server = .stopped
      self.append(.success, "Harness stopped.")
    }
  }

  /// Open the running harness in the default browser.
  public func openHarness() {
    guard let url = server.url else { return }
    openInBrowser(url)
  }

  private func openInBrowser(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
  }

  // MARK: - Plugin operations

  public func setEnabled(_ name: String, enabled: Bool, stripConfigOverride: Bool = false) async {
    guard let pluginStore else { return }
    await run(enabled ? "Enabling \(name)" : "Disabling \(name)") {
      let result = try await pluginStore.setEnabled(
        name,
        enabled: enabled,
        profile: self.selectedProfile,
        stripConfigOverride: stripConfigOverride
      )
      for change in result.changes { self.append(.success, change) }
      for warning in result.warnings { self.append(.warning, warning) }
      await self.refreshPlugins()
    }
  }

  public func initializeProfile() async {
    guard let pluginStore else { return }
    let name = selectedProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    await run("Creating profile \(name)") {
      let result = try await pluginStore.initializeProfile(name)
      for change in result.changes { self.append(.success, change) }
      await self.refreshProfiles()
      await self.refreshPlugins()
    }
  }

  // MARK: - Removing plugins

  /// Uninstall one plugin from the selected profile.
  ///
  /// The harness CLI does the work (`dsh plugin … remove`), so the lockfile, `node_modules`,
  /// and `dsh.profile.bundles` all stay the CLI's business: this app names the package and
  /// reports what happened. The undo for a removal is the same install the user just did, so
  /// nothing here keeps a copy of the package.
  public func uninstall(_ name: String) async {
    await removePlugin(name, profile: selectedProfile, policy: .standard)
  }

  /// Roll back the newest install this app recorded, by uninstalling that package.
  ///
  /// Named after what it does rather than "undo", because the package is not restored from
  /// anywhere: `link:` checkouts stay on disk, registry packages need the network again.
  public func undoLastInstall() async {
    guard let record = lastInstalled else {
      append(.warning, "No install on record to undo in \(selectedProfile).")
      return
    }
    await removePlugin(record.name, profile: selectedProfile, policy: .standard)
  }

  /// Remove one package, with pnpm's release-age gate either enforced or lifted.
  ///
  /// A refusal by the gate is not a dead end here either: it fills the same prompt an
  /// install fills, and only the user's answer decides whether the gate is lifted for this
  /// one command.
  private func removePlugin(_ name: String, profile: String, policy: PluginInstallPolicy) async {
    guard let pluginStore else {
      append(.failure, "The runtime is not resolved yet; no harness release is active.")
      return
    }
    if policy == .allowYoungReleases {
      append(.warning, "Lifting pnpm's release-age gate for this removal only (\(PluginStore.releaseAgeOverride)).")
    }
    await run("Removing \(name) from \(profile)") {
      do {
        let outcome = try await pluginStore.removePlugin(name, profile: profile, policy: policy)
        self.append(.success, "Removed \(outcome.name) from \(profile).")
        if let tail = Self.lastMeaningfulLine(of: outcome.output) {
          self.append(.progress, tail)
        }
        await self.refreshPlugins()
        self.append(.warning, "Restart the harness for this to take effect.")
      } catch RuntimeError.youngReleaseBlocked(let packages, let detail) where policy == .standard {
        self.youngReleasePrompt = YoungReleasePrompt(
          removalName: name,
          label: name,
          profile: profile,
          packages: packages,
          detail: detail
        )
        self.append(.info, detail)
        self.append(.warning, Self.releaseAgeBlockedLine(packages: packages, profile: profile))
      } catch {
        self.append(.failure, self.describeError(error))
      }
    }
  }

  // MARK: - Installing plugins

  /// Install a plugin from a directory on this machine.
  ///
  /// The directory must be the package itself (the one holding `package.json`), and it is
  /// installed as a link, so an edit in the checkout is live after a harness restart
  /// rather than a reinstall.
  public func installPlugin(directoryPath: String) async {
    let text = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      append(.warning, "Choose a package directory first.")
      return
    }
    let url = URL(fileURLWithPath: text, isDirectory: true).standardizedFileURL
    await installPlugin(.localDirectory(url), label: url.lastPathComponent)
  }

  /// Install a plugin from a packed tarball.
  public func installPlugin(archivePath: String) async {
    let text = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      append(.warning, "Choose a .tgz or .tar.gz first.")
      return
    }
    let url = URL(fileURLWithPath: text, isDirectory: false).standardizedFileURL
    await installPlugin(.localArchive(url), label: url.lastPathComponent)
  }

  /// Install from a specifier typed by the user: a registry name, `pkg@version`,
  /// `github:owner/repo`, or a `file:` / `link:` URL.
  public func installPlugin(specifier: String) async {
    let text = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      append(.warning, "Type a package name or specifier first.")
      return
    }
    await installPlugin(.specifier(text), label: text)
  }

  private func installPlugin(_ source: PluginInstallSource, label: String) async {
    await performInstall(source, label: label, profile: selectedProfile, policy: .standard)
  }

  /// Install one package, with pnpm's release-age gate either enforced or lifted for this
  /// one command.
  ///
  /// The only caller that passes `.allowYoungReleases` is
  /// `answerYoungReleasePrompt(installAnyway:)`, so the override is never applied on its
  /// own: a supply-chain gate is relaxed only by a decision the user made, and only for the
  /// command they answered about.
  private func performInstall(
    _ source: PluginInstallSource,
    label: String,
    profile: String,
    policy: PluginInstallPolicy
  ) async {
    guard let pluginStore else {
      append(.failure, "The runtime is not resolved yet; no harness release is active.")
      return
    }
    lastInstallMessage = nil
    if policy == .allowYoungReleases {
      append(.warning, "Lifting pnpm's release-age gate for this install only (\(PluginStore.releaseAgeOverride)). The next install enforces it again.")
    }
    await run("Installing \(label) into \(profile)") {
      do {
        let outcome = try await pluginStore.addPlugin(source, profile: profile, policy: policy)
        self.append(.success, "Added \(outcome.spec)")
        for warning in outcome.warnings { self.append(.warning, warning) }
        if outcome.warnings.isEmpty, let tail = Self.lastMeaningfulLine(of: outcome.output) {
          self.append(.progress, tail)
        }
        await self.refreshPlugins()
        self.append(.info, "Installed into \(profile). Restart the harness for the profile to load it.")
        self.lastInstallMessage = outcome.warnings.isEmpty
          ? "Installed \(outcome.spec). Restart the harness to load it."
          : "Installed \(outcome.spec) with warnings — see the Log tab. Restart the harness to load it."
      } catch RuntimeError.youngReleaseBlocked(let packages, let detail) where policy == .standard {
        // Not a dead end, so it is not reported as one: the sheet asks whether to lift the
        // gate, and only the answer decides. The request itself reached pnpm, so nothing
        // here is a failure to log as such — the warning line carries pnpm's own reason.
        self.youngReleasePrompt = YoungReleasePrompt(
          source: source,
          label: label,
          profile: profile,
          packages: packages,
          detail: detail
        )
        // pnpm's own words are logged before the summary line, so the status line settles
        // on the explanation while anyone who wants the exact entries and cutoffs has them
        // verbatim in the Log tab.
        self.append(.info, detail)
        self.append(.warning, Self.releaseAgeBlockedLine(packages: packages, profile: profile))
        self.lastInstallMessage = Self.releaseAgeBlockedSummary(packages: packages)
      } catch {
        self.lastInstallMessage = "Failed: \(self.describeError(error))"
        throw error
      }
    }
  }

  /// Answer the release-age prompt. `true` repeats the command with the one-shot override.
  ///
  /// Both answers go through here so the prompt cannot outlive the decision: the sheet reads
  /// it for its copy, and a stale prompt would ask about an operation that already happened.
  public func answerYoungReleasePrompt(installAnyway: Bool) async {
    guard let prompt = youngReleasePrompt else { return }
    youngReleasePrompt = nil
    guard installAnyway else {
      lastInstallMessage = "Cancelled. Nothing changed."
      append(.info, "Did not lift pnpm's release-age gate; nothing changed in \(prompt.profile).")
      return
    }
    // A removal is repeated by package name; an install by the specifier it was asked for.
    if let name = prompt.removalName {
      await removePlugin(name, profile: prompt.profile, policy: .allowYoungReleases)
      return
    }
    guard let source = prompt.source else { return }
    await performInstall(
      source,
      label: prompt.label,
      profile: prompt.profile,
      policy: .allowYoungReleases
    )
  }

  /// Forget a pending prompt without answering it — the sheet was closed, so there is
  /// nothing left to ask.
  public func discardYoungReleasePrompt() {
    youngReleasePrompt = nil
  }

  /// One log line explaining a release-age refusal in the terms the user can act on.
  ///
  /// The important half is what the refusal is *not*: pnpm checks the whole lockfile, so
  /// the named package is not the plugin the user asked for, and changing the specifier
  /// would not help.
  private static func releaseAgeBlockedLine(packages: [String], profile: String) -> String {
    let named = packages.isEmpty ? "a release from the last day" : packages.joined(separator: ", ")
    return "pnpm refused this install: \(profile)'s lockfile holds \(named), younger than its 24-hour release-age gate. pnpm verifies every entry in that lockfile before any change, so this is about the profile, not about the package being installed."
  }

  /// The sheet's result line for a refusal, phrased as the question it is waiting on.
  private static func releaseAgeBlockedSummary(packages: [String]) -> String {
    let named = packages.isEmpty
      ? "a plugin released in the last day"
      : packages.joined(separator: ", ")
    return "Blocked: \(named) is younger than pnpm's 24-hour release-age gate, which it checks across the whole profile. Confirm to install anyway."
  }

  /// The last non-empty line of an install's output, which is pnpm's own summary.
  private static func lastMeaningfulLine(of text: String) -> String? {
    text
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last { !$0.isEmpty && !$0.hasPrefix("stdout:") && !$0.hasPrefix("stderr:") }
  }

  /// One line naming a failure, in the form the log uses.
  public func describeError(_ error: Error) -> String {
    describe(error)
  }

  /// Reset the install sheet's result line, so a reopened sheet does not show the previous
  /// attempt's outcome as if it had just happened.
  public func clearLastInstallMessage() {
    lastInstallMessage = nil
  }

  // MARK: - Importing plugins from another home

  /// Re-read the Harness homes this app can see.
  public func refreshImportHomes() async {
    guard let importer else { return }
    importHomes = await importer.homes(extra: extraImportHomes)
    if !importHomes.contains(where: { $0.url.path == importHomePath }) {
      // The desktop's home is what this feature exists for, so it is the default whenever
      // it is there.
      importHomePath = importHomes.first { $0.kind == .desktop }?.url.path
        ?? importHomes.first?.url.path
        ?? ""
      refreshImportProfiles()
    }
  }

  /// A home the user picked, remembered for the rest of the session.
  public func addImportHome(_ url: URL) async {
    let standardized = Self.normalizedHomeURL(url)
    if !extraImportHomes.contains(where: { $0.standardizedFileURL.path == standardized.path }) {
      extraImportHomes.append(standardized)
    }
    await refreshImportHomes()
    if let match = importHomes.first(where: { $0.url.path == standardized.resolvingSymlinksInPath().path }) {
      selectImportHome(match.url.path)
    }
  }

  /// Accept whatever the user actually clicked: a home, its profiles directory, or a
  /// profile inside it.
  static func normalizedHomeURL(_ url: URL) -> URL {
    let standardized = url.standardizedFileURL
    if standardized.lastPathComponent == "profiles" {
      return standardized.deletingLastPathComponent()
    }
    let parent = standardized.deletingLastPathComponent()
    if parent.lastPathComponent == "profiles" {
      return parent
    }
    return standardized
  }

  public var selectedImportHome: PluginHome? {
    importHomes.first { $0.url.path == importHomePath }
  }

  /// The profiles in the chosen home that can actually be read.
  public var importSourceProfiles: [ProfileSummary] {
    selectedImportHome?.initializedProfiles ?? []
  }

  public func selectImportHome(_ path: String) {
    importHomePath = path
    refreshImportProfiles()
  }

  public func selectImportProfile(_ name: String) {
    importProfile = name
    importPlan = nil
  }

  public func selectConflictPolicy(_ policy: PluginConflictPolicy) {
    conflictPolicy = policy
    importPlan = nil
  }

  private func refreshImportProfiles() {
    let profiles = importSourceProfiles
    if !profiles.contains(where: { $0.name == importProfile }) {
      importProfile = profiles.first?.name ?? ""
    }
    importPlan = nil
  }

  /// Work out what an import would do, without writing anything.
  public func previewImport() async {
    guard let importer else { return }
    guard let request = importRequest() else { return }
    await run("Previewing an import from \(request.sourceProfile)") {
      let plan = try await importer.plan(request)
      self.importPlan = plan
      self.lastImport = nil
      self.importVerification = nil
      self.append(
        .info,
        plan.isNoop
          ? "Nothing to do: \(self.selectedProfile) already matches \(request.sourceProfile)."
          : "\(plan.writes.count) of \(plan.items.count) entries would be written, \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)) in total."
      )
      for warning in plan.warnings { self.append(.warning, warning) }
    }
  }

  /// Copy the previewed plan into this app's profile.
  ///
  /// Refused while the harness is running: the running server holds the profile whose
  /// node_modules this rewrites, and a half-replaced tree is exactly what its next reload
  /// would pick up.
  public func runImport() async {
    guard let importer else { return }
    guard let request = importRequest() else { return }
    guard !server.isRunning else {
      append(.warning, "Stop the harness first: it is running the profile this would rewrite.")
      return
    }
    await run("Importing plugins from \(request.sourceProfile)") {
      let plan: PluginImportPlan
      if let previewed = self.importPlan, previewed.request == request {
        plan = previewed
      } else {
        plan = try await importer.plan(request)
        self.importPlan = plan
      }
      guard !plan.isNoop else {
        self.append(.info, "Nothing to do: the destination already matches the source.")
        return
      }
      let outcome = try await importer.apply(plan) { progress in
        Task { @MainActor in self.append(.progress, progress.message) }
      }
      self.lastImport = outcome
      self.importPlan = nil
      self.append(
        .success,
        "Copied \(outcome.copied.count), replaced \(outcome.replaced.count), skipped \(outcome.skipped.count)."
      )
      for change in outcome.changes { self.append(.info, change) }
      for warning in outcome.warnings { self.append(.warning, warning) }
      await self.refreshProfiles()
      await self.refreshPlugins()
      await self.verifyImportedProfile(
        expecting: plan.items
          .filter { $0.action.writes && $0.location == .nodeModules && !$0.name.hasPrefix(".") }
          .map(\.name)
      )
    }
  }

  /// Compose the profile and import its plugins, then report what would not load.
  ///
  /// Two questions, because they have different answers: the tree composition catches
  /// configuration errors, and importing each plugin's entry module is what catches a plugin
  /// built against another harness release — a mismatch that composes perfectly and then
  /// fails the whole boot when the loader reaches it.
  public func verifyImportedProfile(expecting: [String] = []) async {
    guard let importer else { return }
    let profile = selectedProfile
    do {
      // Booting once is the point: a plugin whose application throws composes and imports
      // perfectly and still takes the whole profile down.
      let verification = try await importer.verify(profile: profile, expecting: expecting, booting: !server.isRunning)
      importVerification = verification
      if !verification.importFailures.isEmpty {
        append(
          .failure,
          "\(verification.importFailures.count) plugin(s) cannot be loaded by this runtime; the harness will not start while they are enabled."
        )
      }
      if verification.composeSucceeded {
        append(.success, "Compose check passed for \(profile): \(verification.entries.count) plugins.")
      } else {
        append(.failure, "The harness could not compose \(profile).")
        if let diagnostic = verification.composeDiagnostic { append(.failure, diagnostic) }
      }
      for entry in verification.problems {
        append(.warning, "\(entry.name): \(entry.problem ?? "")")
      }
      if !verification.importFailures.isEmpty {
        append(.warning, "Turn those plugins off in the list below — or use Harness ▸ Disable Broken Plugins and Retry, which turns off what the boot output blames and starts the harness again.")
      }
    } catch {
      append(.failure, describe(error))
    }
  }

  /// Composition and imports, without starting anything.
  ///
  /// The recovery window's first question is "would this profile boot", and the answer it
  /// wants is a list of plugins that cannot load — not a two-minute server start. This is
  /// `verify` with `booting: false`, and it is safe to run while the harness is up.
  public func inspectProfile() async {
    guard let importer else { return }
    let profile = selectedProfile
    do {
      let verification = try await importer.inspect(profile: profile)
      importVerification = verification
      if verification.entries.isEmpty {
        append(.success, "Profile \(profile) has no plugins beyond the official bundles.")
      }
      if verification.composeSucceeded {
        append(.success, "Compose check passed for \(profile): \(verification.entries.count) plugin(s).")
      } else {
        append(.failure, "The harness could not compose \(profile).")
        if let diagnostic = verification.composeDiagnostic { append(.failure, diagnostic) }
      }
      for entry in verification.problems {
        append(.warning, "\(entry.name): \(entry.problem ?? "")")
      }
      if verification.importFailures.isEmpty {
        append(.success, "Every installed plugin's entry module imports on this runtime.")
      } else {
        for (name, reason) in verification.importFailures.sorted(by: { $0.key < $1.key }) {
          append(.failure, "\(name) cannot be imported: \(reason)")
        }
        append(.warning, "Turn those off in the list, or use 停用坏插件并重试 below.")
      }
    } catch {
      append(.failure, describe(error))
    }
  }

  /// Disable whatever this runtime cannot load, one provable failure at a time.
  ///
  /// The same loop the main window's "Disable Broken Plugins and Retry" runs, exposed here
  /// because the recovery window is the other place a user looks when the harness will not
  /// boot — and because it is the only repair that needs no boot output to read.
  public func quarantineProfile(maxRounds: Int = 8) async {
    guard let importer else { return }
    let profile = selectedProfile
    do {
      let outcome = try await importer.quarantine(profile: profile, maxRounds: maxRounds) { progress in
        Task { @MainActor in self.append(.progress, progress.message) }
      }
      for name in outcome.disabled {
        append(.warning, "Turned off \(name): the boot output blames it.")
      }
      if outcome.started {
        append(.success, "Profile \(profile) boots with \(outcome.disabled.count) plugin(s) turned off.")
      } else {
        append(.failure, "The profile still does not start with every plugin turned off that the boot output named.")
        if let diagnostic = outcome.diagnostic { append(.failure, diagnostic) }
      }
      await refreshPlugins()
    } catch {
      append(.failure, describe(error))
    }
  }

  private func importRequest() -> PluginImportRequest? {
    guard let home = selectedImportHome else {
      append(.warning, "Choose a source home first.")
      return nil
    }
    let profile = importProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !profile.isEmpty else {
      append(.warning, "Choose a source profile first.")
      return nil
    }
    return PluginImportRequest(
      sourceHome: home.url,
      sourceProfile: profile,
      destinationProfile: selectedProfile,
      conflictPolicy: conflictPolicy
    )
  }

  // MARK: - Plumbing

  /// The progress sink handed to the installer.
  ///
  /// It hops back to the main actor because the installer reports from a background
  /// executor, and appending to a published array from there would be a data race.
  private var progressReporter: @Sendable (InstallProgress) -> Void {
    { progress in
      Task { @MainActor in
        self.append(.progress, "\(progress.phase.displayName): \(progress.message)")
      }
    }
  }

  /// Run one operation with the busy flag, the log, and error handling in one place.
  private func run(_ label: String, _ body: @escaping @MainActor () async throws -> Void) async {
    guard !isBusy else {
      append(.warning, "Another operation is already running.")
      return
    }
    isBusy = true
    busyLabel = label
    append(.info, label)
    do {
      try await body()
    } catch {
      append(.failure, describe(error))
    }
    isBusy = false
    busyLabel = nil
  }

  public func append(_ kind: ConsoleLogLine.Kind, _ text: String) {
    for line in text.components(separatedBy: "\n") where !line.isEmpty {
      log.append(ConsoleLogLine(kind: kind, text: line))
      writeToLogFile(kind, line)
      // The status line only follows the interesting lines, so a stray informational
      // message cannot hide the failure that came before it.
      if kind != .progress || statusKind != .failure {
        statusLine = line
        statusKind = kind
      }
    }
    if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
  }

  // MARK: - Log file

  private func openLogFile(in paths: RuntimePaths) {
    let url = paths.logsDirectory.appendingPathComponent("console.log")
    logFilePath = url.path
    try? FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    logFile = try? FileHandle(forWritingTo: url)
    _ = try? logFile?.seekToEnd()
    append(.info, "Harness Console started. Log file: \(url.path)")
  }

  private func writeToLogFile(_ kind: ConsoleLogLine.Kind, _ line: String) {
    guard let logFile else { return }
    let stamp = ISO8601DateFormatter().string(from: Date())
    let entry = "[\(stamp)] [\(kind.rawValue)] \(line)\n"
    try? logFile.write(contentsOf: Data(entry.utf8))
  }

  public func clearLog() {
    log.removeAll()
  }

  private func describe(_ error: Error) -> String {
    if let runtime = error as? RuntimeError { return "\(runtime.code): \(runtime.errorDescription ?? "")" }
    return String(describing: error)
  }
}
