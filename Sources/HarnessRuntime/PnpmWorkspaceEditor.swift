import Foundation

/// Adds pnpm build allowances to a profile's `pnpm-workspace.yaml`.
///
/// pnpm will not run a dependency's install scripts unless the consumer allows it, and
/// it rejects the request outright rather than warning. The key differs by version —
/// pnpm 10 reads `onlyBuiltDependencies` (a list), pnpm 11 reads `allowBuilds` (a map) —
/// and neither accepts the other's spelling, so both are written. That redundancy is
/// deliberate and is what makes one profile work with whichever pnpm the machine has.
///
/// Like `CordisPatchEditor` this edits lines rather than round-tripping the document,
/// because the file is user-owned and may carry comments.
public enum PnpmWorkspaceEditor {
  /// Return `text` with `names` allowed for building.
  ///
  /// Idempotent: names already present are not duplicated. Returns `nil` when nothing
  /// needed to change.
  public static func applyAllowBuilds(_ text: String, names: [String]) -> String? {
    let wanted = names.filter { !$0.isEmpty }
    guard !wanted.isEmpty else { return nil }

    var lines = text.components(separatedBy: "\n")
    let hadTrailingNewline = text.hasSuffix("\n")
    if hadTrailingNewline, lines.last == "" { lines.removeLast() }

    let allowBuildsIndex = topLevelKeyIndex(lines, key: "allowBuilds")
    let onlyBuiltIndex = topLevelKeyIndex(lines, key: "onlyBuiltDependencies")

    var changed = false
    // Insert deepest-first so earlier insertions do not shift later indices.
    if let index = onlyBuiltIndex {
      let (end, existing) = block(lines, from: index, indent: "  ")
      let missing = wanted.filter { !existing.contains($0) }
      if !missing.isEmpty {
        let inserted = missing.map { "  - \($0)" }
        lines.insert(contentsOf: inserted, at: end)
        changed = true
      }
    } else {
      lines.append("onlyBuiltDependencies:")
      lines.append(contentsOf: wanted.map { "  - \($0)" })
      changed = true
    }

    if let index = allowBuildsIndex {
      let (end, existing) = block(lines, from: index, indent: "  ")
      let missing = wanted.filter { !existing.contains($0) }
      if !missing.isEmpty {
        lines.insert(contentsOf: missing.map { "  \($0): true" }, at: end)
        changed = true
      }
    } else {
      lines.append("allowBuilds:")
      lines.append(contentsOf: wanted.map { "  \($0): true" })
      changed = true
    }

    guard changed else { return nil }
    var result = lines.joined(separator: "\n")
    if hadTrailingNewline || !result.hasSuffix("\n") { result += "\n" }
    return result
  }

  /// Package names already allowed to build, from either spelling of the key.
  ///
  /// Read side of the same two keys `applyAllowBuilds` writes, so a caller merging one
  /// profile's allowances into another can report what it added instead of re-writing an
  /// identical list.
  public static func allowedBuildNames(in text: String) -> Set<String> {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    var names: Set<String> = []
    for key in ["allowBuilds", "onlyBuiltDependencies"] {
      guard let index = topLevelKeyIndex(lines, key: key) else { continue }
      let (_, existing) = block(lines, from: index, indent: "  ")
      names.formUnion(existing)
    }
    return names
  }

  private static func topLevelKeyIndex(_ lines: [String], key: String) -> Int? {
    lines.firstIndex { $0 == "\(key):" || $0.hasPrefix("\(key): ") || $0.hasPrefix("\(key):\t") }
  }

  /// The end of a block and the names already listed in it.
  private static func block(_ lines: [String], from index: Int, indent: String) -> (Int, Set<String>) {
    var end = index + 1
    var names: Set<String> = []
    while end < lines.count {
      let line = lines[end]
      if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
      guard line.hasPrefix(indent) else { break }
      let entry = line.trimmingCharacters(in: .whitespaces)
      if entry.hasPrefix("- ") {
        names.insert(String(entry.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
      } else if let separator = entry.firstIndex(of: ":") {
        names.insert(String(entry[entry.startIndex..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
      }
      end += 1
    }
    return (end, names)
  }
}
