import Foundation
import HarnessKit
import HarnessRuntime

/// The headless half of the runtime subsystem.
///
/// Every capability the SwiftUI console offers is reachable here first, which is what
/// makes the install pipeline testable on a machine with no window server and lets the
/// acceptance criteria be checked with one command instead of a walkthrough.
enum HarnessCtl {
  static func run(arguments: [String]) async -> Int32 {
    guard let command = arguments.first else {
      print(usage)
      return 1
    }
    let rest = Array(arguments.dropFirst())
    do {
      switch command {
      case "runtime":
        return try await runtime(rest)
      case "plugins":
        return try await plugins(rest)
      case "im":
        return try await HarnessIMCtl.run(rest)
      case "help", "-h", "--help":
        print(usage)
        return 0
      default:
        FileHandle.standardError.write(Data("unknown command: \(command)\n\n\(usage)".utf8))
        return 1
      }
    } catch {
      let detail = (error as? RuntimeError)?.errorDescription ?? String(describing: error)
      FileHandle.standardError.write(Data("harnessctl: \(detail)\n".utf8))
      return 1
    }
  }

  static var usage: String {
    """
    harnessctl — headless native harness runtime management

    USAGE
      harnessctl runtime root
      harnessctl runtime toolchain
      harnessctl runtime list
      harnessctl runtime use <release-id>
      harnessctl runtime remove <release-id>
      harnessctl runtime install <path> [--source|--prebuilt] [--sha256 <hex>] [--no-activate]
      harnessctl runtime install --registry <version>
      harnessctl runtime node [--install]

    harnessctl plugins homes
    harnessctl plugins list [--profile <name>]
    harnessctl plugins enable <package> [--profile <name>]
    harnessctl plugins disable <package> [--profile <name>]
    harnessctl plugins quarantine [--profile <name>]
    harnessctl plugins import --from-home <path> --from-profile <name> --profile <name>
                            [--dry-run] [--keep-existing] [--verify]
    harnessctl plugins verify [--profile <name>] [--no-boot]

    harnessctl im selftest --url <url> [--dsh-home <path>] [--cwd <dir>] [--text <prompt>]

    The runtime root is taken from NATIVE_HARNESS_ROOT when set, and otherwise defaults to
    ~/.nativeharness. An install still living at the pre-2026-09 location
    (~/Library/Application Support/NativeHarness) keeps using it until it is migrated with
    Tools/relocate-root.sh. Importing reads another home — the
    official desktop's ~/.dsh by default — and never writes to it.
    """
  }

  // MARK: - runtime

  private static func runtime(_ arguments: [String]) async throws -> Int32 {
    guard let subcommand = arguments.first else {
      print(usage)
      return 1
    }
    let rest = Array(arguments.dropFirst())

    switch subcommand {
    case "root":
      let paths = try RuntimePaths.standard()
      print(paths.root.path)
      return 0

    case "toolchain":
      return try await printToolchain()

    case "list":
      return try await list()

    case "use":
      guard let id = rest.first else { throw RuntimeError.unsupported("runtime use needs a release id") }
      let installer = try makeInstaller()
      try await installer.activate(id)
      print("active: \(id)")
      return 0

    case "remove":
      guard let id = rest.first else { throw RuntimeError.unsupported("runtime remove needs a release id") }
      let installer = try makeInstaller()
      try await installer.remove(id)
      print("removed: \(id)")
      return 0

    case "install":
      return try await install(rest)

    case "node":
      return try await node(rest)

    default:
      FileHandle.standardError.write(Data("unknown runtime subcommand: \(subcommand)\n".utf8))
      return 1
    }
  }

  /// `runtime node` — inspect or install the Node this app runs the harness on.
  ///
  /// The window's "Install Node…" button and this subcommand run the same provisioner, so
  /// the download-and-verify path can be exercised on a machine with no window server.
  private static func node(_ arguments: [String]) async throws -> Int32 {
    let paths = try RuntimePaths.standard()
    let provisioner = NodeProvisioner(paths: paths)

    if arguments.contains("--install") {
      let outcome = try await provisioner.installNode { progress in
        FileHandle.standardError.write(Data("\(progress.message)\n".utf8))
      }
      print("node      \(outcome.version)")
      print("          \(outcome.binary.path)")
      print("archive   \(outcome.archive) (\(NodeProvisioner.megabytes(outcome.bytes)) MB)")
      for note in outcome.notes { print("note      \(note)") }
      return 0
    }

    let availability = await provisioner.describeInstalledNode()
    if availability.isInstalled, let version = availability.version, let binary = availability.binary {
      print("node      \(version)")
      print("          \(binary.path)")
      return 0
    }
    print("node      not found — run `harnessctl runtime node --install`")
    return 1
  }

  private static func printToolchain() async throws -> Int32 {
    let installer = try makeInstaller()
    let toolchain = try await installer.toolchain()
    print("node      \(toolchain.nodeVersion)  [\(toolchain.nodeOrigin.rawValue)]")
    print("          \(toolchain.node.path)")
    if let npm = toolchain.npm {
      print("npm       \(npm.displayPath)")
    }
    if let pnpm = toolchain.pnpm {
      print("pnpm      [\(toolchain.pnpmOrigin?.rawValue ?? "unknown")]")
      print("          \(pnpm.path)")
    } else {
      print("pnpm      not found — plugin management is unavailable")
    }
    for note in toolchain.notes { print("note      \(note)") }
    return 0
  }

  private static func list() async throws -> Int32 {
    let paths = try RuntimePaths.standard()
    let installer = try makeInstaller()
    let index = try await installer.index()
    let releases = try await installer.releases()

    print("root: \(paths.root.path)")
    print("home: \(paths.dshHome.path)")
    if releases.isEmpty {
      print("no releases installed")
      return 0
    }
    for release in releases {
      let marker = release.id == index.active ? "*" : " "
      let verified = release.integrity.verified ? release.integrity.origin.rawValue : "unverified"
      let size = release.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
      print("\(marker) \(release.id)")
      print("    version \(release.version)   \(release.source.kind.rawValue)   \(verified)   \(size)")
      print("    entry   \(release.entry)")
      print("    from    \(release.source.spec)")
    }
    return 0
  }

  private static func install(_ arguments: [String]) async throws -> Int32 {
    // The registry path takes a version instead of a path, and is how "update through
    // the official channel" is exercised without a browser download.
    if let index = arguments.firstIndex(of: "--registry") {
      guard arguments.count > index + 1 else {
        throw RuntimeError.unsupported("--registry needs a version, for example --registry 0.1.5-rc.1")
      }
      let version = arguments[index + 1]
      let installer = try makeInstaller()
      let outcome = try await installer.install(.registry(version: version)) { progress in
        let suffix = progress.message.isEmpty ? "" : " — \(progress.message)"
        FileHandle.standardError.write(Data("[\(progress.phase.rawValue)]\(suffix)\n".utf8))
      }
      print("\(outcome.reused ? "reused" : "installed"): \(outcome.release.id)")
      print("version \(outcome.release.version)   entry \(outcome.release.entry)")
      return 0
    }

    guard let path = arguments.first else {
      throw RuntimeError.unsupported("runtime install needs a path to an archive or a source checkout")
    }
    guard !path.hasPrefix("-") else {
      throw RuntimeError.unsupported("the path must come first, before any flags")
    }
    let flags = Set(arguments.dropFirst())
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

    var digest: String?
    if let index = arguments.firstIndex(of: "--sha256"), arguments.count > index + 1 {
      digest = arguments[index + 1]
    }

    let kind = try ArchiveInspector.kind(of: url)
    let source: InstallSource
    switch kind {
    case .directory:
      source = .sourceDirectory(url: url)
    case .zip, .tarGz:
      // An archive defaults to the prebuilt path, which is what a downloaded release
      // asset is. --source forces the build path instead, for the case where someone
      // zipped a checkout.
      source = flags.contains("--source")
        ? .sourceArchive(url: url, expectedDigest: digest)
        : .prebuiltArchive(url: url, expectedDigest: digest)
    }

    let installer = try makeInstaller()
    let outcome = try await installer.install(source, activate: !flags.contains("--no-activate")) { progress in
      let suffix = progress.message.isEmpty ? "" : " — \(progress.message)"
      FileHandle.standardError.write(Data("[\(progress.phase.rawValue)]\(suffix)\n".utf8))
    }

    print("\(outcome.reused ? "reused" : "installed"): \(outcome.release.id)")
    print("version \(outcome.release.version)   entry \(outcome.release.entry)")
    for warning in outcome.warnings { print("warning: \(warning)") }
    return 0
  }

  // MARK: - plugins

  /// Reading, verifying, and importing a profile's plugins.
  ///
  /// The import is the reason this exists as a command rather than only as a button: it is
  /// a copy of a hundred and fifty directories, and whoever decides whether to run it
  /// wants the plan printed before anything is written.
  private static func plugins(_ arguments: [String]) async throws -> Int32 {
    guard let subcommand = arguments.first else {
      throw RuntimeError.unsupported("plugins needs a subcommand: homes, list, verify, import")
    }
    let rest = Array(arguments.dropFirst())

    switch subcommand {
    case "homes":
      let importer = try makeImporter()
      let homes = await importer.homes()
      if homes.isEmpty {
        print("no harness home found")
        return 0
      }
      for home in homes {
        print("\(home.kind.displayName)   \(home.url.path)")
        if home.profiles.isEmpty {
          print("    no profiles")
        }
        for profile in home.profiles {
          let state = profile.isInitialized ? "initialized" : "not initialized"
          print("    \(profile.name)   \(profile.dependencyCount) dependencies   \(profile.bundles.count) bundles   \(state)")
        }
      }
      return 0

    case "list":
      let profile = value(after: "--profile", in: rest) ?? "web"
      let store = try makePluginStore()
      let records = try await store.plugins(profile: profile)
      if records.isEmpty {
        print("profile \(profile) has no plugins")
        return 0
      }
      for record in records {
        let state = record.isEnabled ? "enabled " : "disabled"
        let kind = record.isBundle ? "bundle" : "plain "
        let version = record.installedVersion ?? "not materialized"
        print("\(state)  \(kind)  \(record.name)  \(version)  \(record.spec)")
      }
      return 0

    case "verify":
      let profile = value(after: "--profile", in: rest) ?? "web"
      let importer = try makeImporter()
      // Booting is the default because it is the only check that catches a plugin whose
      // application throws; skipping it is for a fast look, not for a verdict.
      let verification = try await importer.verify(profile: profile, booting: !rest.contains("--no-boot"))
      printVerification(verification, profile: profile)
      return verification.isHealthy ? 0 : 1

    case "enable", "disable":
      guard let name = rest.first, !name.hasPrefix("--") else {
        throw RuntimeError.unsupported("plugins \(subcommand) needs a package name, for example dsh-memoir")
      }
      let profile = value(after: "--profile", in: rest) ?? "web"
      let store = try makePluginStore()
      let result = try await store.setEnabled(name, enabled: subcommand == "enable", profile: profile)
      for change in result.changes { print("change \(change)") }
      for warning in result.warnings { print("warning \(warning)") }
      return 0

    case "quarantine":
      return try await quarantine(rest)

    case "import":
      return try await importPlugins(rest)

    default:
      FileHandle.standardError.write(Data("unknown plugins subcommand: \(subcommand)\n".utf8))
      return 1
    }
  }

  private static func importPlugins(_ arguments: [String]) async throws -> Int32 {
    guard let homeArgument = value(after: "--from-home", in: arguments) else {
      throw RuntimeError.unsupported("plugins import needs --from-home <path>")
    }
    guard let sourceProfile = value(after: "--from-profile", in: arguments) else {
      throw RuntimeError.unsupported("plugins import needs --from-profile <name>")
    }
    let destinationProfile = value(after: "--profile", in: arguments) ?? "web"
    let request = PluginImportRequest(
      sourceHome: URL(fileURLWithPath: (homeArgument as NSString).expandingTildeInPath).standardizedFileURL,
      sourceProfile: sourceProfile,
      destinationProfile: destinationProfile,
      conflictPolicy: arguments.contains("--keep-existing") ? .keepDestination : .preferSource
    )

    let importer = try makeImporter()
    let plan = try await importer.plan(request)
    printPlan(plan)

    if arguments.contains("--dry-run") {
      print("dry run: nothing was written")
      return 0
    }
    guard !plan.isNoop else {
      print("nothing to do")
      return 0
    }

    let outcome = try await importer.apply(plan) { progress in
      FileHandle.standardError.write(Data("[import] \(progress.message)\n".utf8))
    }
    print("copied \(outcome.copied.count)   replaced \(outcome.replaced.count)   skipped \(outcome.skipped.count)")
    print("bytes  \(outcome.bytesCopied)")
    if let backup = outcome.backupDirectory { print("backup \(backup.path)") }
    for change in outcome.changes { print("change \(change)") }
    for warning in outcome.warnings { print("warning \(warning)") }

    guard arguments.contains("--verify") else { return 0 }
    let verification = try await importer.verify(profile: destinationProfile)
    printVerification(verification, profile: destinationProfile)
    return verification.isHealthy ? 0 : 1
  }

  private static func printPlan(_ plan: PluginImportPlan) {
    print("from    \(plan.request.sourceHome.path)   profile \(plan.request.sourceProfile)")
    print("into    \(plan.destinationDirectory.path)")
    print("policy  \(plan.request.conflictPolicy.displayName)")
    print("entries \(plan.items.count)   to write \(plan.writes.count)   bytes \(plan.totalBytes)   backup \(plan.backupBytes)")
    for item in plan.items where item.action.writes {
      let versions = [
        item.sourceVersion.map { "source \($0)" },
        item.destinationVersion.map { "here \($0)" },
      ].compactMap { $0 }.joined(separator: ", ")
      print("  \(item.action.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(item.name)   \(versions)")
    }
    for change in plan.dependencyChanges { print("dependency \(change)") }
    for change in plan.bundleChanges { print("bundle \(change)") }
    for change in plan.patchChanges { print("patch \(change)") }
    if !plan.allowBuildAdditions.isEmpty {
      print("allowBuilds \(plan.allowBuildAdditions.joined(separator: ", "))")
    }
    for warning in plan.warnings { print("warning \(warning)") }
    if plan.isNoop { print("plan is a no-op") }
  }

  /// Disable every plugin this runtime cannot import, so the profile boots.
  ///
  /// The point of the check is that the loader has no per-plugin isolation: one plugin built
  /// against another harness release takes the entire boot down, so the only way to keep the
  /// rest of an imported set is to stop asking the harness to load that one.
  private static func quarantine(_ arguments: [String]) async throws -> Int32 {
    let profile = value(after: "--profile", in: arguments) ?? "web"
    let importer = try makeImporter()
    let outcome = try await importer.quarantine(profile: profile) { progress in
      FileHandle.standardError.write(Data("[\(progress.message.isEmpty ? "quarantine" : progress.message)]\n".utf8))
    }

    if outcome.disabled.isEmpty {
      print("every plugin in \(profile) loads")
    } else {
      print("disabled \(outcome.disabled.count) plugin(s): \(outcome.disabled.joined(separator: ", "))")
    }
    print("rounds \(outcome.rounds)   starts \(outcome.started ? "yes" : "no")")
    if let diagnostic = outcome.diagnostic, !outcome.started {
      for line in diagnostic.components(separatedBy: "\n").suffix(12) { print("  \(line)") }
    }
    return outcome.started ? 0 : 1
  }

  private static func printVerification(_ verification: PluginImportVerification, profile: String) {
    print("profile \(profile): \(verification.entries.count) plugins")
    for entry in verification.entries {
      let version = entry.installedVersion ?? "not materialized"
      let state = entry.isEnabled ? "enabled" : "disabled"
      let problem = entry.problem.map { "   \($0)" } ?? ""
      print("  \(entry.name)  \(version)  \(state)\(problem)")
    }
    if !verification.importFailures.isEmpty {
      print("import check: \(verification.importFailures.count) plugin(s) cannot be loaded by this runtime — quarantine disables them")
    }
    if let boot = verification.boot {
      if boot.started {
        print("boot check: started (\(boot.url ?? "no url reported"))")
      } else {
        let blamed = boot.suspects.isEmpty ? "no plugin identified" : boot.suspects.joined(separator: ", ")
        print("boot check: FAILED — blamed: \(blamed)")
      }
    }
    if verification.composeSucceeded {
      print("compose check: ok")
    } else {
      print("compose check: FAILED")
      for line in (verification.composeDiagnostic ?? "").components(separatedBy: "\n") {
        print("  \(line)")
      }
    }
  }

  /// The value following a flag, when one is present and is not another flag.
  private static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
    let candidate = arguments[index + 1]
    return candidate.hasPrefix("--") ? nil : candidate
  }

  private static func makeImporter() throws -> ProfileImporter {
    let paths = try RuntimePaths.standard()
    let installer = HarnessInstaller(paths: paths)
    return ProfileImporter(paths: paths) { try await installer.activeEntryURL() }
  }

  private static func makePluginStore() throws -> PluginStore {
    let paths = try RuntimePaths.standard()
    let installer = HarnessInstaller(paths: paths)
    return PluginStore(paths: paths) { try await installer.activeEntryURL() }
  }

  private static func makeInstaller() throws -> HarnessInstaller {
    HarnessInstaller(paths: try RuntimePaths.standard())
  }
}
