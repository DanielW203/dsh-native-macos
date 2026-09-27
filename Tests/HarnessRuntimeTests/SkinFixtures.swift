import Foundation
import XCTest

@testable import HarnessRuntime

/// Synthetic profiles for the skin tests.
///
/// Directories rather than mocks, because the filesystem *is* the registry: a skin is
/// discovered by being a package with the right files in the right place, and every rule
/// worth testing — which scopes are walked, what counts as a theme, what the patch file has
/// to end up saying — is a statement about that tree.
enum SkinFixtures {
  /// A profile directory under a fixture root, so `RuntimePaths(root:)` resolves to it.
  static func makeProfile(
    _ testCase: XCTestCase,
    bundles: [String] = []
  ) throws -> (root: URL, profile: URL) {
    let root = try TestSupport.makeRoot(testCase)
    let profile = root.appendingPathComponent("home/profiles/web", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try writeManifest(profile, bundles: bundles)
    return (root, profile)
  }

  static func writeManifest(_ profile: URL, bundles: [String]) throws {
    let manifest: [String: Any] = [
      "name": "dsh-profile-web",
      "private": true,
      "dsh": ["profile": ["bundles": bundles, "patchReload": "live"]],
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
      .write(to: profile.appendingPathComponent("package.json"))
  }

  /// Where a package lives — folding the `/` so scoped names land at
  /// `node_modules/@scope/name` rather than in one directory named `@scope/name`.
  static func packageDirectory(_ profile: URL, _ package: String) -> URL {
    package.split(separator: "/").reduce(profile.appendingPathComponent("node_modules", isDirectory: true)) {
      $0.appendingPathComponent(String($1), isDirectory: true)
    }
  }

  /// Write one package into the profile's `node_modules`.
  @discardableResult
  static func install(
    _ package: String,
    into profile: URL,
    skin: [String: Any]? = nil,
    manifest: [String: Any] = [:],
    patch: String? = nil,
    clientBundle: Bool = true
  ) throws -> URL {
    let directory = packageDirectory(profile, package)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var record = manifest
    record["name"] = record["name"] ?? package
    try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
      .write(to: directory.appendingPathComponent("package.json"))
    if let skin {
      try JSONSerialization.data(withJSONObject: skin, options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("skin.json"))
    }
    if let patch {
      try TestSupport.write(patch, to: directory.appendingPathComponent("cordis.patch.yml"))
    }
    if clientBundle {
      try TestSupport.write("export default {}\n", to: directory.appendingPathComponent("lib/client.js"))
    }
    return directory
  }

  /// A package that declares itself with a `skin.json`, the way a real skin does.
  ///
  /// The manifest declares `dsh.bundle.patch` because a skin package normally does — it is
  /// how a skin wires itself in when it is listed as a bundle. A package whose patch file
  /// does not exist, or does not insert its row, is simply not bundle-wired.
  @discardableResult
  static func installDeclared(
    _ package: String,
    into profile: URL,
    id: String,
    rowID: String? = nil,
    order: Int = 1000,
    name: String? = nil,
    declaresPackage: Bool = true
  ) throws -> URL {
    var wiring: [String: Any] = [:]
    if let rowID { wiring["id"] = rowID }
    var skin: [String: Any] = [
      "id": id,
      "name": name ?? id,
      "order": order,
      "accent": "#123456",
    ]
    if declaresPackage { skin["package"] = package }
    if !wiring.isEmpty { skin["wiring"] = wiring }
    return try install(
      package,
      into: profile,
      skin: skin,
      manifest: ["dsh": ["bundle": ["patch": "./cordis.patch.yml"]]]
    )
  }

  /// A package recognised as a market theme: no `skin.json`, a client bundle, and an
  /// `insert:` row of its own.
  @discardableResult
  static func installTheme(
    _ package: String,
    into profile: URL,
    rowID: String,
    description: String? = nil,
    immediately: Bool = false
  ) throws -> URL {
    var client: [String: Any] = ["platform": "web"]
    if immediately { client["immediately"] = true }
    var manifest: [String: Any] = [
      "dsh": ["client": client, "bundle": ["patch": "./cordis.patch.yml"]],
    ]
    if let description { manifest["description"] = description }
    return try install(
      package,
      into: profile,
      manifest: manifest,
      patch: "- insert:\n    - id: \(rowID)\n      name: \(package)\n"
    )
  }

  static func patchURL(_ profile: URL) -> URL {
    profile.appendingPathComponent("cordis.patch.yml")
  }

  static func writePatch(_ text: String, to profile: URL) throws {
    try TestSupport.write(text, to: patchURL(profile))
  }

  static func readPatch(_ profile: URL) throws -> String {
    try String(contentsOf: patchURL(profile), encoding: .utf8)
  }

  static func manager(_ root: URL) -> SkinManager {
    SkinManager(paths: RuntimePaths(root: root))
  }
}

// MARK: - The shape of a real profile

extension SkinFixtures {
  /// Two installed skins and a plugin row that is nobody's skin, mirroring this machine's
  /// own profile closely enough for the switching tests to mean something.
  ///
  /// `deep-whale` is standalone (the manager has to write its insert row); `maid-whale` is
  /// bundle-wired (its bundle patch already inserts the row, so the manager must not).
  @discardableResult
  static func installTwoSkins(_ profile: URL) throws -> (standalone: Skin, wired: Skin) {
    try installDeclared(
      "@dsh-external/deep-whale",
      into: profile,
      id: "maid-atelier",
      rowID: "ui-skin-deep-whale-day-night",
      order: 5,
      name: "鲸鱼娘昼夜工坊"
    )
    try installDeclared(
      "@yunxii/maid-whale",
      into: profile,
      id: "maid-whale-webui",
      rowID: "ui-skin-maid-whale-webui",
      order: 10,
      name: "云鲸纸面"
    )
    let wiredDirectory = packageDirectory(profile, "@yunxii/maid-whale")
    try TestSupport.write(
      "- insert:\n    - id: ui-skin-maid-whale-webui\n      name: '@yunxii/maid-whale'\n",
      to: wiredDirectory.appendingPathComponent("cordis.patch.yml")
    )
    let skins = SkinCatalog(profileDirectory: profile).skins()
    return (skins[0], skins[1])
  }
}
