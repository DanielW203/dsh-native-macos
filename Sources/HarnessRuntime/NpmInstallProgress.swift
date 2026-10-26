import Foundation

/// What `npm install --dry-run --json` says a registry install is about to add.
///
/// Why this exists: `InstallProgress.fraction` is part of the installer's API but nothing
/// ever set it, so a registry install looked frozen for as long as npm was downloading.
/// npm exposes no machine-readable byte progress — its progress renderer is a TTY spinner
/// with no percentage — and its http log format is coupled to the npm version. The one
/// number that is both exact and stable is the count of packages: a dry run resolves the
/// same tree the install will materialize on *this* machine and platform, and the
/// materialized count can be read back from the staging directory with two levels of
/// `readdir`.
struct NpmInstallPlan: Sendable, Equatable {
  struct Package: Sendable, Equatable {
    var name: String
    var version: String
    /// Absolute path npm reports for the package, e.g.
    /// `/…/harness/staging/<id>/node_modules/@scope/name`.
    var path: String
  }

  var packages: [Package]

  /// How many packages will occupy `node_modules/<name>` or `node_modules/@scope/<name>`.
  ///
  /// This is the denominator `NpmPackageCounter` can actually observe; nested duplicate
  /// versions sit under another `node_modules` and are deliberately not part of it.
  var topLevelCount: Int

  var totalCount: Int { packages.count }

  /// Parse the JSON summary out of npm's output, or `nil` when there is nothing usable.
  ///
  /// `--json` still prints one `add <name> <version>` line per package before the document
  /// (npm's diff output), so the document starts at the first `{`; those lines contain no
  /// braces. A missing or empty `add` array is not an error worth surfacing — it only means
  /// the caller falls back to an indeterminate bar.
  static func parse(_ output: String) -> NpmInstallPlan? {
    guard let start = output.firstIndex(of: "{") else { return nil }
    guard let data = String(output[start...]).data(using: .utf8) else { return nil }
    guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
    let packages = (document.add ?? []).compactMap { entry -> Package? in
      guard let path = entry.path else { return nil }
      return Package(name: entry.name, version: entry.version ?? "", path: path)
    }
    guard !packages.isEmpty else { return nil }
    return NpmInstallPlan(
      packages: packages,
      topLevelCount: packages.filter { isTopLevel($0.path) }.count
    )
  }

  private struct Document: Decodable {
    var add: [Entry]?

    struct Entry: Decodable {
      var name: String
      var version: String?
      var path: String?
    }
  }

  /// `node_modules/foo` and `node_modules/@scope/foo` are top-level. A second
  /// `node_modules` segment means npm nested the package under another one, and the
  /// counter — which only looks two levels deep — would never see it.
  private static func isTopLevel(_ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    guard let marker = components.firstIndex(of: "node_modules") else { return false }
    let relative = components[(marker + 1)...]
    guard !relative.isEmpty else { return false }
    if relative.dropFirst().contains("node_modules") { return false }
    if relative.count == 1 { return true }
    // `relative` is an ArraySlice whose startIndex is the position after "node_modules", so
    // its first element is at `startIndex`, not 0.
    return relative.count == 2 && relative[relative.startIndex].hasPrefix("@")
  }
}

/// Counts the packages a running `npm install` has already put in place.
///
/// Deliberately shallow: npm hoists almost everything into `node_modules` and
/// `node_modules/@scope`, so listing the top level plus each scope directory is enough to
/// track progress and is cheap enough to run a few times a second. A nested duplicate is
/// invisible to it — the fraction caps at 0.99 until the install legitimately finishes.
enum NpmPackageCounter {
  static func materialized(inNodeModules directory: URL) -> Int {
    let manager = FileManager.default
    guard let entries = try? manager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey]
    ) else {
      return 0
    }
    var count = 0
    for entry in entries {
      let name = entry.lastPathComponent
      guard !name.hasPrefix("."), name != "node_modules" else { continue }
      guard isDirectory(entry, manager: manager) else { continue }
      count += name.hasPrefix("@") ? childDirectoryCount(of: entry, manager: manager) : 1
    }
    return count
  }

  private static func childDirectoryCount(of scope: URL, manager: FileManager) -> Int {
    guard let entries = try? manager.contentsOfDirectory(
      at: scope,
      includingPropertiesForKeys: [.isDirectoryKey]
    ) else {
      return 0
    }
    return entries.filter { entry in
      !entry.lastPathComponent.hasPrefix(".") && isDirectory(entry, manager: manager)
    }.count
  }

  private static func isDirectory(_ url: URL, manager: FileManager) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}
