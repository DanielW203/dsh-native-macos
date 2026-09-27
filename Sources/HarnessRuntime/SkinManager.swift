import Foundation
import HarnessKit

/// The markers around the block this manager owns inside a profile's `cordis.patch.yml`.
///
/// Byte-identical to the plugin this replaces, on purpose: they are a handover protocol
/// rather than an implementation detail. Keeping them means the native manager recognises
/// and replaces a block the plugin wrote — so switching over never leaves two owners of the
/// same rows — and a user who goes back to the plugin finds a block it still understands.
public enum SkinManagedBlock {
  public static let start = "# --- dsh-skin-manager managed (auto-generated; do not edit) ---"
  public static let end = "# --- end dsh-skin-manager managed ---"
}

/// What one switch did, so the window reports rather than assumes.
public struct SkinSwitchReport: Sendable, Equatable {
  /// The skin now active, or `nil` for the official look.
  public var active: Skin?
  /// The profile's patch file was rewritten. False means it already said exactly this —
  /// worth knowing, because a rewrite is what the harness's config watcher reacts to.
  public var patchChanged: Bool
  /// The market's own disabled list was brought into line.
  public var marketStateUpdated: Bool
  /// Things the user should hear about: a link that could not be made, a market state file
  /// that could not be written, patch rows left in place that could override the switch.
  public var warnings: [String]

  public init(
    active: Skin?,
    patchChanged: Bool = false,
    marketStateUpdated: Bool = false,
    warnings: [String] = []
  ) {
    self.active = active
    self.patchChanged = patchChanged
    self.marketStateUpdated = marketStateUpdated
    self.warnings = warnings
  }
}

/// The skin manager: what is installed, what is active, and how to change that.
///
/// Switching works the way the plugin's did, because the mechanism belongs to the harness
/// rather than to either tool: the profile's `cordis.patch.yml` is rewritten so exactly one
/// skin is inserted and every other one is disabled. The profile declares
/// `patchReload: live`, so the running harness picks the change up within seconds and the
/// Web UI only needs a page reload — no restart, and no second server.
///
/// Everything here acts on the *real* home. A Safe Mode launch runs the harness against a
/// disposable one, but a skin the user picks must survive that process ending.
public struct SkinManager: Sendable {
  /// The id the UI sends for "no skin": DeepSeek Harness' own appearance.
  public static let officialID = "official"

  public let paths: RuntimePaths

  public init(paths: RuntimePaths) {
    self.paths = paths
  }

  public func profileDirectory(_ profile: String) -> URL {
    paths.profilesDirectory.appendingPathComponent(profile, isDirectory: true)
  }

  /// Every profile this home holds, by name.
  public func profiles() -> [String] {
    ProfileCatalog.summaries(inProfilesDirectory: paths.profilesDirectory).map(\.name)
  }

  public func skins(profile: String) -> [Skin] {
    SkinCatalog(profileDirectory: profileDirectory(profile)).skins()
  }

  public func patchURL(profile: String) -> URL {
    profileDirectory(profile).appendingPathComponent("cordis.patch.yml")
  }

  /// The profile's patch document, or `nil` when there is not one yet.
  public func patchText(profile: String) -> String? {
    SkinCatalog.readText(patchURL(profile: profile))
  }

  /// Which skin the patch file currently composes, or `nil` for the official look.
  ///
  /// Read from the file rather than remembered in a state file: the patch document is what
  /// the loader actually consults, so a state file that disagreed with it would be a lie
  /// the user can see through — the Web UI would show a skin the harness is not composing.
  public func activeSkinID(profile: String, in skins: [Skin]) -> String? {
    let facts = SkinPatch.facts(patchText(profile: profile) ?? "")
    // Skins order, last one wins, matching the plugin: with the mutual-exclusion
    // invariant only one insert row should exist, and if an older hand-written row
    // survives beside it the one the user applied later is the one to believe.
    let enabled = skins.filter { facts.ids.contains($0.rowID) && !facts.disabledIDs.contains($0.rowID) }
    if let last = enabled.last { return last.id }
    // No insert row of ours: a bundle-wired skin may already be active through its own
    // bundle patch, which is a legitimate way for a skin to be on.
    return skins.first { $0.isBundleWired && !facts.disabledIDs.contains($0.rowID) }?.id
  }

  /// Make one skin active — or, with `nil` / ``officialID``, none of them.
  ///
  /// Throws rather than returning a report when the request cannot be honoured at all, so
  /// a caller cannot mistake "the skin you named is not installed" for a successful switch
  /// to the official look.
  @discardableResult
  public func switchTo(_ skinID: String?, profile: String) throws -> SkinSwitchReport {
    let directory = profileDirectory(profile)
    let skins = SkinCatalog(profileDirectory: directory).skins()

    var target: Skin?
    if let skinID, skinID != Self.officialID {
      guard let match = skins.first(where: { $0.id == skinID || $0.package == skinID }) else {
        throw RuntimeError.unsupported("skin \(skinID) is not installed in profile \(profile)")
      }
      target = match
    }

    // The same lock every other profile mutation takes. The harness does not take it, but
    // the app's own plugin operations do, and a switch racing an install would rewrite a
    // patch file the install is midway through editing.
    let lock = try FileLock(url: paths.lockFile)
    defer { lock.release() }
    try lock.acquire(holderDescription: "skin switch")

    var warnings: [String] = []
    if let target { link(target, into: directory, warnings: &warnings) }

    let url = patchURL(profile: profile)
    let original = SkinCatalog.readText(url) ?? ""
    let stripped = SkinPatch.strip(original, skins: skins, warnings: &warnings)
    let rewritten = SkinPatch.compose(stripped, active: target, skins: skins)

    // Left alone when the document already says exactly this: the harness reloads on the
    // file changing, and a no-op rewrite would reload a running server's plugin tree for
    // nothing.
    var patchChanged = false
    if rewritten != original {
      try AtomicFile.write(Data(rewritten.utf8), to: url)
      patchChanged = true
    }

    let marketUpdated = syncMarketState(
      profileDirectory: directory,
      skins: skins,
      active: target,
      warnings: &warnings
    )

    return SkinSwitchReport(
      active: target,
      patchChanged: patchChanged,
      marketStateUpdated: marketUpdated,
      warnings: warnings
    )
  }

  // MARK: - Making a nested skin importable

  /// Put the skin's package where the loader's `name:` can resolve it.
  ///
  /// Standalone skins are already in `node_modules`. A skin discovered inside an aggregate
  /// package (`<package>/skins/<id>`) is not, and the loader imports it by bare specifier —
  /// so without this link the row would name a package that does not exist. A failure is a
  /// warning rather than an error: the switch may still work if the package is linked some
  /// other way, and refusing to write the row would be the worse answer.
  private func link(_ skin: Skin, into profileDirectory: URL, warnings: inout [String]) {
    let base = profileDirectory
      .appendingPathComponent("node_modules", isDirectory: true)
      .appendingPathComponent(skin.package, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: base.path) else { return }
    guard skin.directory.standardizedFileURL != base.standardizedFileURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: base.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(at: base, withDestinationURL: skin.directory)
    } catch {
      warnings.append("could not link \(skin.package) into node_modules: \(error.localizedDescription)")
    }
  }

  // MARK: - The market's parallel state

  /// Keep dsh-market's own disabled list in step with the switch.
  ///
  /// The market keeps a second opinion about which skins are off, and it acts on it at
  /// boot: a skin this manager enables while the market still lists it as disabled gets
  /// switched back off. Only the state file is written — the market's live hot mounts
  /// belong to its own process, which this app cannot reach — and only the one key, so
  /// every other choice in that file (region, groups, notes) is carried through untouched.
  ///
  /// A profile without that file has no market installed, which is not a failure.
  private func syncMarketState(
    profileDirectory: URL,
    skins: [Skin],
    active: Skin?,
    warnings: inout [String]
  ) -> Bool {
    let url = profileDirectory.appendingPathComponent(".dsh-market/state.json")
    guard let data = try? Data(contentsOf: url) else { return false }
    var root: [String: JSONValue]
    do {
      guard let object = try JSONValue.parse(data, context: "state.json").objectValue else {
        return false
      }
      root = object
    } catch {
      warnings.append("could not read the market's state file: \(error.localizedDescription)")
      return false
    }

    // `disabled` is the current key; `disabledSkins` is the pre-#60 theme-only one the
    // market still reads, so a state file carrying only the old key is seeded from it.
    var disabled = Set(
      (root["disabled"] ?? root["disabledSkins"])?.arrayValue?.compactMap { $0.stringValue } ?? []
    )
    for skin in skins {
      if let active, skin.package == active.package {
        disabled.remove(skin.package)
      } else {
        disabled.insert(skin.package)
      }
    }
    root["disabled"] = .array(disabled.sorted().map { .string($0) })
    // Written under the current key only: leaving the legacy one behind would keep a second,
    // stale answer in the same file for the market to read if the new key ever went missing.
    root.removeValue(forKey: "disabledSkins")

    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try AtomicFile.write(try encoder.encode(JSONValue.object(root)), to: url)
      return true
    } catch {
      warnings.append("could not update the market's state file: \(error.localizedDescription)")
      return false
    }
  }
}

/// Reading and rewriting the parts of a patch document the skin manager owns.
///
/// Line-oriented on purpose, for the reason `CordisPatchEditor` documents at length: these
/// files carry other tools' comments and formatting, and a parse-and-re-render would delete
/// them. The two operations here are the ones a switch needs, and neither rewrites a line
/// it did not have to touch.
enum SkinPatch {
  /// The ids a patch document mentions, split by whether they are switched off.
  struct Facts: Sendable, Equatable {
    var ids: Set<String> = []
    var disabledIDs: Set<String> = []
  }

  static func facts(_ text: String) -> Facts {
    guard case .entries(let entries) = CordisPatchEditor.parse(text) else { return Facts() }
    var facts = Facts()
    for entry in entries {
      guard let id = entry.id else { continue }
      facts.ids.insert(id)
      if entry.isDisabled { facts.disabledIDs.insert(id) }
    }
    return facts
  }

  /// Remove everything this manager owns, leaving every other tool's rows alone.
  ///
  /// Three things go:
  ///
  /// 1. the managed block itself;
  /// 2. an `insert:` block that names a discovered skin — the manager owns those rows now,
  ///    and a surviving duplicate would compose the same loader entry twice;
  /// 3. a state row (`id`, `name`, `disabled` and nothing else) for a discovered skin's row
  ///    id. Left in place, one of these is what makes an applied skin stay off: this
  ///    machine's profile carries three stale `disabled: true` rows for one skin.
  ///
  /// A row that carries anything else — configuration written by hand or by another tool —
  /// is preserved and reported, because deleting a user's tuning to make a switch tidy
  /// would be the wrong trade.
  static func strip(_ text: String, skins: [Skin], warnings: inout [String]) -> String {
    var content = text
    if let start = content.range(of: SkinManagedBlock.start) {
      if let end = content.range(of: SkinManagedBlock.end, range: start.upperBound..<content.endIndex) {
        content.removeSubrange(start.lowerBound..<end.upperBound)
      } else {
        // An unterminated block: everything from the marker on is the manager's, which is
        // also the only reading under which the remainder can be parsed again afterwards.
        content.removeSubrange(start.lowerBound..<content.endIndex)
      }
    }

    guard case .entries(let entries) = CordisPatchEditor.parse(content) else { return content }
    let rowIDs = Set(skins.map(\.rowID))
    let packages = Set(skins.map(\.package))
    let lines = content.components(separatedBy: "\n")

    var drop = Set<Int>()
    var preserved = 0
    for entry in entries {
      let ownLines = entry.lineRange.compactMap { index -> String? in
        guard lines.indices.contains(index) else { return nil }
        return lines[index].trimmingCharacters(in: .whitespaces)
      }
      // Read from the lines rather than from `entry.id`: an `insert:` block with several
      // rows keeps only the last one in `scalars`, and the first is as likely to be the skin.
      let embeddedIDs = Set(ownLines.compactMap(SkinCatalog.idRowValue))
      let names = Set(entry.scalars.values).union(entry.scalars.keys)
      let namesSkin = !embeddedIDs.isDisjoint(with: rowIDs) || !names.isDisjoint(with: packages)
      guard namesSkin else { continue }

      let isInsertBlock = ownLines.first?.hasPrefix("- insert:") == true
      let identifying: Set<String> = ["id", "name", "disabled"]
      let isStateRow = entry.scalars.keys.allSatisfy { identifying.contains($0) }
      guard isInsertBlock || isStateRow else {
        preserved += 1
        continue
      }
      for index in entry.lineRange { drop.insert(index) }
    }

    if preserved > 0 {
      warnings.append(
        "\(preserved) hand-written patch row(s) still name a skin and were left in place; "
          + "they may override this switch."
      )
    }
    guard !drop.isEmpty else { return content }

    let kept = lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    return kept.joined(separator: "\n")
  }

  /// The strip result plus a freshly rendered managed block.
  ///
  /// Canonical by construction — no leading blank line, exactly one between whatever
  /// survived and the block, one trailing newline — because that is what makes applying the
  /// skin that is already on a byte-for-byte no-op. Leaving the whitespace where the removal
  /// found it made every application grow the file by a blank line, which the harness's
  /// config watcher then reloaded the plugin tree for.
  static func compose(_ stripped: String, active: Skin?, skins: [Skin]) -> String {
    var head = stripped
    if let trailing = head.range(of: "\\s+$", options: .regularExpression) {
      head.removeSubrange(trailing)
    }
    let block = render(active: active, skins: skins)
    return head.isEmpty ? block + "\n" : head + "\n\n" + block + "\n"
  }

  /// The managed block for one active skin — or, with `nil`, for the official look: every
  /// discovered skin disabled and no insert row.
  static func render(active: Skin?, skins: [Skin]) -> String {
    var lines = [SkinManagedBlock.start]
    var written: Set<String> = []
    for skin in skins {
      if let active, skin.rowID == active.rowID || skin.id == active.id { continue }
      guard written.insert(skin.rowID).inserted else { continue }
      lines.append("- id: \(skin.rowID)")
      lines.append("  disabled: true")
    }
    // A bundle-wired skin is already inserted by its own bundle patch; a second row here
    // would compose its loader entry twice, which the loader treats as a conflict rather
    // than as the same skin twice.
    if let active, !active.isBundleWired {
      lines.append("- insert:")
      lines.append("    - id: \(active.rowID)")
      lines.append("      name: '\(active.package)'")
    }
    lines.append(SkinManagedBlock.end)
    return lines.joined(separator: "\n")
  }
}
