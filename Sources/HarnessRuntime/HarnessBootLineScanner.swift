import Foundation

/// Reads a boot's output for the plugins that did not make it into the process.
///
/// **Why this has to be a parser and not a status check.** The harness reports three
/// different things on this machine's real logs, and none of them changes its exit code or
/// its announced URL:
///
/// - `dsh: warning: 1 entry did not activate`
///   `web-search-free (dsh-free-search): failed to import`
/// - `dsh: skipping profile bundle "dsh-memoir": Error: Plugin dsh-memoir@0.7.0 is
///   incompatible with dsh 0.1.7-rc.1: peerDependencies …`
/// - `dsh-pocket (dsh-pocket): cannot get property "webServer"` under
///   `failed to apply loader entry dsh-pocket (dsh-pocket): …`
///
/// The 0.1.7 release changed the plugin loader's contract *and* its wording: the old app
/// only knew the third shape, so the first two booted into a "healthy" verdict with the
/// user's plugins missing. A parser that knows one shape is a parser that will be wrong
/// again the next time upstream renames a message — so this one reads several shapes at
/// once, reports what it could not attribute rather than dropping it, and leaves the
/// decision about disabling anything to the caller that can see the profile.
public enum HarnessBootLineScanner {
  /// What the output says about the plugins, given what the caller already knows is
  /// installed.
  ///
  /// - Parameters:
  ///   - lines: every non-empty line the harness printed, in order. Order matters because
  ///     the two-line import shape puts the count and the names on separate lines.
  ///   - profile: the profile the boot used, for matching package paths inside it.
  ///   - known: the package names that profile declares. A name that appears in the output
  ///     but not here is still reported — with `isAttributed == false` — because dropping it
  ///     would reproduce the silent failure this exists to end.
  public static func scan(
    lines: [String],
    profile: String,
    known: Set<String>
  ) -> [BootPluginProblem] {
    var problems: [BootPluginProblem] = []
    var seen = Set<String>()

    func append(_ problem: BootPluginProblem) {
      // The page log repeats the same failure for every reload, and the harness itself
      // repeats its banner on every child the profile spawns. Keying on the whole line keeps
      // two genuinely different errors from collapsing into one.
      let key = "\(problem.kind.rawValue)|\(problem.name)|\(problem.line)"
      guard seen.insert(key).inserted else { return }
      problems.append(problem)
    }

    for line in lines {
      let trimmed = normalizing(line)
      guard !trimmed.isEmpty else { continue }

      // Shape 2: the new skip. Quoted, so the name survives even when it is not a declared
      // dependency of this profile — which is exactly the drift worth reporting.
      if let range = trimmed.range(of: "skipping profile bundle") {
        let name = quotedName(in: trimmed[range.upperBound...])
        let attributed = isCredible(name: name, known: known)
        append(BootPluginProblem(
          name: name,
          kind: .skippedBundle,
          isAttributed: attributed,
          line: trimmed
        ))
        // The same line usually names the peer it disagrees about; recording it separately
        // is what lets a report say *why* rather than only *who*.
        if trimmed.contains("incompatible with dsh") {
          append(BootPluginProblem(
            name: name,
            kind: .peerIncompatible,
            isAttributed: attributed,
            line: trimmed
          ))
        }
        continue
      }

      // Shape 3: the loader refused the row. The token is a loader row id that usually *is*
      // the package name, but not always — `RescueProfile` and the patch stack can name
      // rows that no profile dependency matches.
      if let range = trimmed.range(of: "failed to apply loader entry ") {
        let token = String(trimmed[range.upperBound...].prefix { !$0.isWhitespace && $0 != "(" && $0 != ":" && $0 != "\"" })
        guard !token.isEmpty else { continue }
        append(BootPluginProblem(
          name: token,
          kind: .loaderEntry,
          isAttributed: known.contains(token),
          line: trimmed
        ))
        continue
      }

      // Shape 1a/3b: a stack frame or a `file://` reference under the profile's own plugin
      // tree. The most reliable attribution there is — the name came out of the profile's
      // directory listing, so it holds even when the profile no longer declares the package,
      // which is the drift case worth knowing about.
      //
      // Gated on the line looking like a frame. The marker also appears in the harness's own
      // error text (`Cannot find package '/…/profiles/web/node_modules/@x/y' imported from …`),
      // and reading that as a stack frame would both invent a package name and swallow the
      // `failed to import` attribution on the same line.
      if trimmed.contains("file://") || trimmed.hasPrefix("at ") {
        var seenNames: Set<String> = []
        for name in packageNames(inProfilePathsOf: trimmed, profile: profile) {
          guard seenNames.insert(name).inserted else { continue }
          append(BootPluginProblem(name: name, kind: .importFailed, isAttributed: true, line: trimmed))
        }
      }

      // The count line on its own names nobody. It is recorded so a boot whose second line
      // never arrived still shows that the harness itself said something did not activate —
      // and so `bootedCleanly` is false, which is what keeps the verdict honest.
      if trimmed.contains("entry did not activate") || trimmed.contains("entries did not activate") {
        append(BootPluginProblem(name: "", kind: .importFailed, isAttributed: false, line: trimmed))
        continue
      }

      // Shape 1b: the entry failed to load, and the harness attributes it in parentheses.
      guard trimmed.contains(": failed to import") else { continue }
      let named = parenthesizedName(in: trimmed)
      append(BootPluginProblem(
        name: named,
        kind: .importFailed,
        isAttributed: isCredible(name: named, known: known),
        line: trimmed
      ))
    }

    return problems
  }

  /// The verdict for a boot that produced a server, from its output.
  public static func health(
    isRunning: Bool,
    lines: [String],
    profile: String,
    known: Set<String>
  ) -> HarnessBootHealth {
    let problems = scan(lines: lines, profile: profile, known: known)
    return HarnessBootHealth(isRunning: isRunning, problems: problems)
  }

  // MARK: - Reading names out of one line

  /// One line, without the decorations different callers put around it.
  ///
  /// Two sources feed this parser and they are not the same string: the launcher hands over
  /// the process's raw output, while `HarnessWindowModel` mirrors it with
  /// `"dsh: …"` prefixes (see the window log). Normalizing here means one parser, one set of
  /// shapes, and no second copy that drifts.
  static func normalizing(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("dsh: ") else { return trimmed }
    return String(trimmed.dropFirst("dsh: ".count))
  }

  /// The name after `skipping profile bundle`, which upstream writes quoted.
  static func quotedName(in text: Substring) -> String {
    guard let open = text.firstIndex(of: "\"") else { return "" }
    let rest = text[text.index(after: open)...]
    guard let close = rest.firstIndex(of: "\"") else { return "" }
    return String(rest[rest.startIndex..<close])
  }

  /// The name inside the parentheses of `web-search-free (dsh-free-search): failed to import`.
  static func parenthesizedName(in line: String) -> String {
    guard let open = line.firstIndex(of: "("),
          let close = line[open...].firstIndex(of: ")")
    else { return "" }
    return String(line[line.index(after: open)..<close])
  }

  /// Package names in every `profiles/<profile>/node_modules/…` path the line mentions.
  ///
  /// Scoped packages take two components (`@scope/name`), which is why the split keeps empty
  /// subsequences: without that, `@scope//name` would silently become `@scope`.
  static func packageNames(inProfilePathsOf line: String, profile: String) -> [String] {
    let marker = "/profiles/\(profile)/node_modules/"
    var names: [String] = []
    var remainder = Substring(line)
    while let range = remainder.range(of: marker) {
      let after = remainder[range.upperBound...]
      let components = after.split(separator: "/", omittingEmptySubsequences: false)
      if let first = components.first {
        var name = String(first)
        if name.hasPrefix("@"), components.count > 1 {
          name += "/" + String(components[1])
        }
        if !name.isEmpty { names.append(name) }
      }
      remainder = after
    }
    return names
  }

  /// Whether a name read out of the output is a package this profile actually has.
  ///
  /// Used only for the `isAttributed` flag, never to drop a problem: a name that is not
  /// declared is more interesting than one that is, because it means the plugin tree the
  /// profile loads has drifted from what it declares.
  static func isCredible(name: String, known: Set<String>) -> Bool {
    guard !name.isEmpty else { return false }
    return known.contains(name)
  }
}
