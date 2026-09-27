import Foundation
import HarnessKit

/// One installed skin, as the manager lists it.
///
/// The field set is the union of what `skin.json` declares and what a *market theme* — a
/// package with no registry file, recognised by convention — can be read for. The two are
/// the same shape once discovered, so the window never has to know which kind it is
/// looking at; `hasSkinManifest` is the one place the difference survives, because it is
/// worth saying out loud rather than hiding.
public struct Skin: Sendable, Equatable, Identifiable {
  /// `skin.json`'s `id`, or the loader row id for a theme that ships no registry file.
  public var id: String
  /// The display name, in the skin author's own language.
  public var name: String
  /// The English name, when the registry carries one.
  public var nameEn: String
  public var tagline: String
  /// The skin's accent colour as written in its registry (`#rrggbb`); a neutral grey when
  /// the registry or the convention reader had no better answer.
  public var accent: String
  public var author: String
  /// The longer description. Called `summary` rather than `description` so it is not
  /// mistaken for `CustomStringConvertible`.
  public var summary: String
  public var tags: [String]
  /// The `data-*` attribute the skin sets on `<body>`, when it declares one.
  public var bodyAttribute: String
  /// The npm package the loader row imports. Frequently *not* the dependency key: a nested
  /// skin inside an aggregate package is resolved through a link the manager creates.
  public var package: String
  /// Registry sort key: lower sorts first. A skin without one sorts last.
  public var order: Int
  /// The package directory — where the previews live, and what a nested skin is linked from.
  public var directory: URL
  /// `wiring.id` from the registry, when the package declares one.
  ///
  /// Read rather than derived because the row a package's own bundle patch inserts does not
  /// always match its `id`; deep-whale's registry says `maid-atelier` and its row says
  /// `ui-skin-deep-whale-day-night`, and only the row id disables the right entry.
  public var declaredRowID: String?
  /// `wiring.bundleWired`: the registry's own claim that the profile's bundle layer already
  /// inserts this skin's row.
  public var declaredBundleWired: Bool
  /// Whether the profile's bundle list *and* the package's own patch already wire this skin.
  ///
  /// Resolved by the catalog, not by the registry: it needs the profile's manifest, which a
  /// `skin.json` cannot know. When true the manager writes no `insert:` row for this skin —
  /// doing so would compose its loader entry twice.
  public var isBundleWired: Bool
  /// Whether the package carries a `skin.json`, as opposed to being recognised as a market
  /// theme by the naming convention.
  public var hasSkinManifest: Bool
  /// Preview images, resolved and confirmed to exist.
  public var previewLight: URL?
  public var previewDark: URL?

  /// The loader row id every patch entry for this skin is written under.
  public var rowID: String {
    declaredRowID ?? "\(SkinCatalog.rowIDPrefix)\(id)"
  }
}

/// Discovery of the skins installed in one profile.
///
/// Nothing is registered anywhere: the package directory *is* the registry, so a skin
/// installed by any route — the market, `dsh plugin add`, a hand-unpacked directory — shows
/// up without a manifest to regenerate. That is the whole reason this reads the filesystem
/// instead of asking the harness.
///
/// A value rather than a static namespace because everything it reads is anchored to one
/// profile directory, and a caller that had to remember to pass it every time is a caller
/// that will eventually pass the wrong one.
public struct SkinCatalog: Sendable {
  /// The registry file a skin package may carry.
  public static let manifestName = "skin.json"
  /// The row-id prefix loader entries for skins use.
  public static let rowIDPrefix = "ui-skin-"
  /// The accent used when nothing better is known.
  public static let neutralAccent = "#888888"
  /// Where a skin sorts when its registry declares no order.
  public static let defaultOrder = 1000

  /// Packages that mention skins without *being* one.
  ///
  /// Load-bearing rather than cosmetic. A theme without a `skin.json` is recognised by
  /// matching theme/skin words in its package name, so every skin *manager* in the
  /// ecosystem would otherwise be listed as a skin — and then written into the managed
  /// block as a disabled row, which switches the manager itself off. That is not
  /// hypothetical: the upstream plugin this replaces omitted `dsh-skin-market` from its
  /// copy of this list, and every skin switch turned the market off.
  ///
  /// The names are listed exactly, never by prefix: `dsh-skin` is a theme, not a manager.
  public static let nonThemePackages: Set<String> = [
    "dsh-skin-manager",
    "dsh-skin-center",
    "dsh-skin-market",
    "dsh-skin-switcher",
    "dsh-skin-studio",
    "dsh-skin-picker",
    "dsh-skin-toggle",
    "dshmarket",
    "dsh-better-sidebar",
    "dsh-web-ui-all",
    "@linxin666/dsh-skins",
    "@linxin666/dsh-web-ui-all",
    "@linxin666/dsh-client-ui-skin-center",
    "@dsh-external/dsh-super-injector",
    "@dsh-external/dsh-mode-boost",
    "@liustack/modlens",
    "dsh-vision-router",
  ]

  public let profileDirectory: URL

  public init(profileDirectory: URL) {
    self.profileDirectory = profileDirectory
  }

  public var nodeModulesDirectory: URL {
    profileDirectory.appendingPathComponent("node_modules", isDirectory: true)
  }

  /// The bundle list from the profile manifest — the layer set the loader composes.
  public func profileBundles() -> Set<String> {
    guard let manifest = Self.readJSON(profileDirectory.appendingPathComponent("package.json")) else {
      return []
    }
    return Set(ProfileManifest.bundleList(manifest))
  }

  /// Every installed skin, sorted the way the registry asks to be shown.
  ///
  /// Never throws: a profile that has never been initialized has no `node_modules`, and
  /// "no skins" is the honest answer for it rather than a failure the window has to render.
  public func skins() -> [Skin] {
    guard let entries = listing(nodeModulesDirectory) else { return [] }

    let bundles = profileBundles()
    var found: [Skin] = []
    var seen: Set<String> = []

    for entry in entries {
      let name = entry.lastPathComponent
      // `.bin`, `.pnpm`, `.modules.yaml`: the package manager's own bookkeeping. The store
      // in particular is walked once per scope if it is not skipped, for nothing.
      guard !name.hasPrefix(".") else { continue }
      guard isDirectoryOrSymlink(entry) else { continue }

      if name.hasPrefix("@") {
        // A scope is a container, not a package. Scoped packages live at
        // `node_modules/@scope/name`, and there is no `node_modules/@` to enumerate —
        // probing that one path is exactly how the plugin this replaces hid every skin
        // outside the single scope it knew about.
        for child in contents(of: entry) where isDirectoryOrSymlink(child) {
          collect(child, package: "\(name)/\(child.lastPathComponent)", bundles: bundles, into: &found, seen: &seen)
        }
        continue
      }

      collect(entry, package: name, bundles: bundles, into: &found, seen: &seen)
    }

    return found.sorted { ($0.order, $0.name, $0.package) < ($1.order, $1.name, $1.package) }
  }

  // MARK: - Collecting one package

  private func collect(
    _ directory: URL,
    package: String,
    bundles: Set<String>,
    into found: inout [Skin],
    seen: inout Set<String>
  ) {
    let key = directory.standardizedFileURL.path
    guard !seen.contains(key) else { return }

    // Aggregate packages ship their skins under `<package>/skins/<id>` (the convention
    // `@linxin666/dsh-skins` uses). Scanned *before* the aggregate is judged, and even when
    // it is not a skin itself: the aggregate is usually not one — that is the point of it —
    // and its whole value is the skins underneath.
    for child in contents(of: directory.appendingPathComponent("skins", isDirectory: true))
    where isDirectoryOrSymlink(child) {
      collect(child, package: child.lastPathComponent, bundles: bundles, into: &found, seen: &seen)
    }

    var skin = readSkinManifest(at: directory, fallbackPackage: package)
    // A package that ships a registry file that could not be read is not retried as a
    // convention theme: the author declared a skin, and guessing at it from the package
    // name would list something the author did not describe.
    if skin == nil,
       !FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.manifestName).path) {
      skin = readThemeManifest(at: directory, fallbackPackage: package)
    }
    guard var skin else { return }
    // A skin with no client half has nothing to show: the loader row would import nothing.
    guard hasClientBundle(at: directory) else { return }

    seen.insert(key)
    skin.isBundleWired = skin.declaredBundleWired
      || (bundles.contains(skin.package) && bundlePatchInsertsRow(skin, at: directory))
    found.append(skin)
  }

  // MARK: - Registry readers

  /// A package that declares itself with `skin.json`.
  private func readSkinManifest(at directory: URL, fallbackPackage: String) -> Skin? {
    guard let registry = Self.readJSON(directory.appendingPathComponent(Self.manifestName)) else {
      return nil
    }
    guard let id = registry["id"]?.stringValue, !id.isEmpty else { return nil }
    return Skin(
      id: id,
      name: registry["name"]?.stringValue ?? id,
      nameEn: registry["nameEn"]?.stringValue ?? id,
      tagline: registry["tagline"]?.stringValue ?? "",
      accent: registry["accent"]?.stringValue ?? Self.neutralAccent,
      author: registry["author"]?.stringValue ?? "",
      summary: registry["description"]?.stringValue ?? "",
      tags: Self.strings(registry["tags"]),
      bodyAttribute: registry["bodyAttr"]?.stringValue ?? "",
      package: registry["package"]?.stringValue ?? fallbackPackage,
      order: registry["order"]?.intValue ?? Self.defaultOrder,
      directory: directory,
      declaredRowID: registry.path("wiring.id")?.stringValue,
      declaredBundleWired: registry.path("wiring.bundleWired")?.boolValue == true,
      isBundleWired: false,
      hasSkinManifest: true,
      previewLight: previewURL(registry, key: "light", in: directory),
      previewDark: previewURL(registry, key: "dark", in: directory)
    )
  }

  /// A market theme: a client bundle whose Cordis patch inserts a loader row, with no
  /// `skin.json` to describe it.
  ///
  /// The convention is deliberately narrow, because the alternative is listing plugins as
  /// skins and disabling them. A package qualifies on its *name* (or its row id) saying
  /// theme/skin; failing that, on its description saying so **and** the client declaring
  /// itself immediately-loaded, which is how a market ships a theme it expects to run on
  /// boot. Utilities that merely mention the word do not qualify either way.
  private func readThemeManifest(at directory: URL, fallbackPackage: String) -> Skin? {
    guard let manifest = Self.readJSON(directory.appendingPathComponent("package.json")) else {
      return nil
    }
    let package = manifest["name"]?.stringValue ?? fallbackPackage
    guard !package.isEmpty, !Self.nonThemePackages.contains(package) else { return nil }
    guard manifest["dsh"]?["client"] != nil,
          let patchRelative = manifest.path("dsh.bundle.patch")?.stringValue
    else { return nil }
    guard let patch = Self.readText(directory.appendingPathComponent(patchRelative)),
          let rowID = Self.insertedRowIDs(in: patch).first
    else { return nil }

    let description = manifest["description"]?.stringValue ?? ""
    let keywords = Self.strings(manifest["keywords"]).joined(separator: " ")
    let immediately = manifest.path("dsh.client.immediately")?.boolValue == true
    guard Self.mentionsTheme(package) || Self.mentionsTheme(rowID)
      || (immediately && Self.mentionsTheme("\(description) \(keywords)"))
    else { return nil }

    let id = rowID.hasPrefix(Self.rowIDPrefix)
      ? String(rowID.dropFirst(Self.rowIDPrefix.count))
      : rowID
    // The first clause of the description reads like a name ("Kimino Theme: …"), so it is
    // used as one; a theme author who wants a different label ships a skin.json.
    let shortName = description
      .split(whereSeparator: { ":：—-".contains($0) })
      .first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    return Skin(
      id: id,
      name: shortName.isEmpty ? package : shortName,
      nameEn: package,
      tagline: description,
      accent: Self.neutralAccent,
      author: "",
      summary: description,
      tags: Self.strings(manifest["keywords"]),
      bodyAttribute: "",
      package: package,
      order: Self.defaultOrder,
      directory: directory,
      declaredRowID: rowID,
      declaredBundleWired: false,
      isBundleWired: false,
      hasSkinManifest: false,
      previewLight: nil,
      previewDark: nil
    )
  }

  /// Whether the package's own patch inserts its loader row.
  ///
  /// Only `insert:` blocks count. A bare `- id: <row>` is an *override* of an existing
  /// entry — which is how this manager disables a skin — and reading it as an insertion
  /// would make a skin that merely happens to be disabled look wired.
  private func bundlePatchInsertsRow(_ skin: Skin, at directory: URL) -> Bool {
    guard let manifest = Self.readJSON(directory.appendingPathComponent("package.json")),
          let patchRelative = manifest.path("dsh.bundle.patch")?.stringValue,
          let patch = Self.readText(directory.appendingPathComponent(patchRelative))
    else { return false }
    let wanted = skin.rowID
    return Self.insertedRowIDs(in: patch).contains(wanted)
  }

  /// Whether a package ships a browser half the loader could actually load.
  private func hasClientBundle(at directory: URL) -> Bool {
    let fallback = directory.appendingPathComponent("lib/client.js")
    guard let manifest = Self.readJSON(directory.appendingPathComponent("package.json")) else {
      return FileManager.default.fileExists(atPath: fallback.path)
    }
    if let client = manifest["exports"]?["./client"] {
      if let path = client.stringValue { return Self.exists(directory, path) }
      if let path = client["default"]?.stringValue { return Self.exists(directory, path) }
    }
    return FileManager.default.fileExists(atPath: fallback.path)
  }

  private func previewURL(_ registry: JSONValue, key: String, in directory: URL) -> URL? {
    guard let relative = registry.path("preview.\(key)")?.stringValue, !relative.isEmpty else {
      return nil
    }
    let url = directory.appendingPathComponent(relative)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  // MARK: - Shared readers

  /// Every loader row id a patch document inserts, in file order.
  ///
  /// A hand-rolled scan rather than a YAML parse for the same reason `CordisPatchEditor`
  /// is one: these files carry other tools' comments and formatting, and the only question
  /// asked here is "which ids does an `insert:` block name".
  static func insertedRowIDs(in patch: String) -> [String] {
    var ids: [String] = []
    var insideInsert = false
    for line in patch.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      if trimmed.hasPrefix("- insert:") {
        insideInsert = true
        continue
      }
      let isIndented = line.first == " " || line.first == "\t"
      if !isIndented {
        // Any new top-level entry closes the block. A top-level `- id:` is an override,
        // not an insertion, which is why it is skipped rather than recorded.
        insideInsert = false
        continue
      }
      guard insideInsert, let id = idRowValue(trimmed) else { continue }
      ids.append(id)
    }
    return ids
  }

  /// The id on a `- id: …` line, or nil when the line is something else.
  ///
  /// Takes an already-trimmed line so the same reader serves both the patch scan above and
  /// the entry surgery in `SkinPatch`, which sees lines from `CordisPatchEditor`.
  static func idRowValue(_ trimmedLine: String) -> String? {
    guard trimmedLine.hasPrefix("- id:") else { return nil }
    var value = String(trimmedLine.dropFirst("- id:".count))
    if let hash = value.firstIndex(of: "#") { value = String(value[value.startIndex..<hash]) }
    value = value.trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    return value.isEmpty ? nil : value
  }

  static func mentionsTheme(_ text: String) -> Bool {
    text.range(of: "skin|theme", options: [.regularExpression, .caseInsensitive]) != nil
  }

  static func strings(_ value: JSONValue?) -> [String] {
    (value?.arrayValue ?? []).compactMap { $0.stringValue }
  }

  /// Read JSON, tolerating the UTF-8 BOM that Windows-authored packages carry — `JSONDecoder`
  /// rejects it, and a skin that is merely BOM-prefixed is still installed.
  static func readJSON(_ url: URL) -> JSONValue? {
    guard var data = try? Data(contentsOf: url) else { return nil }
    if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
    return try? JSONValue.parse(data, context: url.lastPathComponent)
  }

  static func readText(_ url: URL) -> String? {
    guard var text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    return text
  }

  static func exists(_ directory: URL, _ relativePath: String) -> Bool {
    let url = URL(fileURLWithPath: relativePath, relativeTo: directory).standardizedFileURL
    return FileManager.default.fileExists(atPath: url.path)
  }

  // MARK: - Directory helpers

  private func contents(of directory: URL) -> [URL] {
    listing(directory) ?? []
  }

  /// The entries of a directory, following a symlinked directory.
  ///
  /// `contentsOfDirectory(at:…)` — the URL-taking overload — returns an empty list for a
  /// *symlinked* directory rather than an error, which would make a profile whose
  /// `node_modules` is a link look like a profile with nothing installed. The path-taking
  /// overload has no such blind spot, so the URLs are derived from it.
  private func listing(_ directory: URL) -> [URL]? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return nil
    }
    return names.map { directory.appendingPathComponent($0) }
  }

  /// Whether `url` is a directory, following symlinks — `node_modules` is full of them,
  /// because that is how `link:` installs are materialized.
  ///
  /// A symlink whose target is missing still counts, so the reader reports the failure
  /// instead of a silent skip.
  private func isDirectoryOrSymlink(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      return isDirectory.boolValue
    }
    return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
  }
}
