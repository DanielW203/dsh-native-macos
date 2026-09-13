import Foundation

/// Reads and surgically edits a profile's `cordis.patch.yml`.
///
/// The file is a top-level YAML array of loader patch entries. Two facts drive this
/// design:
///
/// 1. **Comments are load-bearing.** The file on this machine carries a
///    `--- dsh-skin-manager managed (auto-generated; do not edit) ---` block written by
///    another tool. Parsing and re-rendering the document — the obvious approach, and the
///    one the official desktop app takes with serde_yaml — silently deletes those
///    comments and rewrites the user's formatting.
/// 2. **Only one operation is needed.** Enabling a plugin that another tool disabled
///    means removing the target entry, or removing just its `disabled` line when the
///    entry carries other configuration. Everything else must survive byte for byte.
///
/// So this is a line-oriented scanner, not a YAML parser. It understands block-style
/// sequences and scalar `key: value` pairs, refuses flow style outright, and never
/// rewrites a line it did not have to touch.
public enum CordisPatchEditor {
  /// One entry of the top-level array.
  public struct Entry: Sendable, Equatable {
    /// The value of the entry's `id` key, when it has a scalar one.
    public var id: String?
    /// Every `key: value` scalar found anywhere inside the entry, including keys such as
    /// `name`. Matching against all of them is what makes a rename-tolerant match
    /// possible: a bundle's loader row id and its npm package name are frequently not
    /// the same string.
    public var scalars: [String: String]
    /// A literal truthy `disabled` value. A `!!js` expression is *not* a static disable
    /// and is reported separately — treating it as disabled would make the UI offer to
    /// re-enable something that is not disabled.
    public var isDisabled: Bool
    /// True when `disabled` holds an expression rather than a literal.
    public var isConditionalDisable: Bool
    /// Zero-based, half-open range of the entry's lines within the file.
    public var lineRange: Range<Int>
    /// Line index of the `disabled` key within the file, if present.
    public var disabledLine: Int?
  }

  public enum ParseResult: Sendable, Equatable {
    case entries([Entry])
    /// The file is not a block-style top-level array. Editing is refused rather than
    /// guessed at, and the caller shows the file and asks the user to handle it by hand.
    case unsupported(String)
  }

  public enum EditError: Error, Equatable {
    case unsupported(String)
    case unparseable
  }

  // MARK: - Reading

  /// Parse the document into entries.
  public static func parse(_ text: String) -> ParseResult {
    let lines = text.components(separatedBy: "\n")
    var starts: [Int] = []
    for (index, line) in lines.enumerated() {
      guard let first = line.first, first != " ", first != "\t" else { continue }
      if line.hasPrefix("- ") || line == "-" {
        // Flow style (`- {id: x}`) has no line-per-key structure to edit safely.
        if line.contains("{") || line.contains("}") {
          return .unsupported("entry on line \(index + 1) uses flow style")
        }
        starts.append(index)
      }
    }
    guard !starts.isEmpty else { return .entries([]) }

    var entries: [Entry] = []
    for (position, start) in starts.enumerated() {
      let rawEnd = position + 1 < starts.count ? starts[position + 1] : lines.count
      let end = trimTrailingSeparators(lines: lines, start: start, end: rawEnd)
      entries.append(parseEntry(lines: lines, range: start..<end))
    }
    return .entries(entries)
  }

  /// Pull an entry's end back to its last own line.
  ///
  /// A blank line, or a comment starting in column zero, belongs to the file rather
  /// than to the entry above it. Without this an entry that happens to be last would
  /// take the closing marker of a tool-managed block with it when it is removed —
  /// deleting another tool's bookkeeping as a side effect of enabling a plugin.
  /// Comments indented inside the entry stay attached, because those document it.
  private static func trimTrailingSeparators(lines: [String], start: Int, end: Int) -> Int {
    var end = end
    while end > start + 1 {
      let line = lines[end - 1]
      let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
      let isFileLevelComment = line.first == "#"
      guard isBlank || isFileLevelComment else { break }
      end -= 1
    }
    return end
  }

  private static func parseEntry(lines: [String], range: Range<Int>) -> Entry {
    var scalars: [String: String] = [:]
    var id: String?
    var isDisabled = false
    var isConditional = false
    var disabledLine: Int?

    for index in range {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      let body = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
      guard !body.isEmpty, !body.hasPrefix("#") else { continue }
      guard let separator = body.firstIndex(of: ":") else { continue }

      let key = String(body[body.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
      var value = String(body[body.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      // A nested block header (config:, insert:) has no scalar value on its own line.
      guard !key.isEmpty, !value.isEmpty, !key.contains(" ") else { continue }
      if value.hasPrefix("[") || value.hasPrefix("{") { continue }

      let isExpression = value.hasPrefix("!!js") || value.hasPrefix("!js")
      value = stripComment(value)
      guard !value.isEmpty, !value.hasSuffix(":") else { continue }

      scalars[key] = value
      if key == "id" { id = value }
      if key == "disabled" {
        disabledLine = index
        if isExpression {
          isConditional = true
        } else if isTruthy(value) {
          isDisabled = true
        }
      }
    }
    return Entry(
      id: id,
      scalars: scalars,
      isDisabled: isDisabled,
      isConditionalDisable: isConditional,
      lineRange: range,
      disabledLine: disabledLine
    )
  }

  /// Trim a trailing `# comment` that is not inside quotes.
  private static func stripComment(_ value: String) -> String {
    guard !value.hasPrefix("\"") && !value.hasPrefix("'") else {
      return value.trimmingCharacters(in: .whitespaces)
    }
    guard let hash = value.firstIndex(of: "#"), hash != value.startIndex else {
      return value.trimmingCharacters(in: .whitespaces)
    }
    // Only a whitespace-preceded hash starts a comment, so `a#b` survives.
    let before = value[value.index(before: hash)]
    guard before == " " || before == "\t" else {
      return value.trimmingCharacters(in: .whitespaces)
    }
    return String(value[value.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
  }

  private static func isTruthy(_ value: String) -> Bool {
    switch value.lowercased() {
    case "true", "yes", "on", "\"true\"", "'true'": return true
    default: return false
    }
  }

  /// Every scalar belonging to an entry that is literally disabled.
  ///
  /// Returned as strings rather than ids because callers match them against both the
  /// loader row id and the installed package name.
  public static func disabledTargets(_ text: String) -> Set<String> {
    guard case .entries(let entries) = parse(text) else { return [] }
    var targets: Set<String> = []
    for entry in entries where entry.isDisabled {
      for (key, value) in entry.scalars {
        targets.insert(key)
        targets.insert(value)
      }
    }
    return targets
  }

  /// Whether any literally-disabled entry refers to one of `names`.
  public static func hasDisable(_ text: String, named names: [String]) -> Bool {
    let targets = disabledTargets(text)
    return names.contains { targets.contains($0) }
  }

  /// Whether any entry gates `names` behind an expression rather than a literal.
  public static func hasConditionalDisable(_ text: String, named names: [String]) -> Bool {
    guard case .entries(let entries) = parse(text) else { return false }
    for entry in entries where entry.isConditionalDisable {
      let values = Set(entry.scalars.values).union(entry.scalars.keys)
      if names.contains(where: { values.contains($0) }) { return true }
    }
    return false
  }

  // MARK: - Editing

  /// Remove the disable override for `names`, leaving everything else untouched.
  ///
  /// Returns `nil` when nothing matched, so a caller can tell "already enabled" apart
  /// from "enabled, and the patch file changed".
  public static func stripDisable(_ text: String, named names: [String]) throws -> String? {
    switch parse(text) {
    case .unsupported(let reason):
      throw EditError.unsupported(reason)
    case .entries(let entries):
      let wanted = Set(names)
      let targets = entries.filter { entry in
        guard entry.isDisabled else { return false }
        let values = Set(entry.scalars.values).union(entry.scalars.keys)
        return !wanted.isDisjoint(with: values)
      }
      guard !targets.isEmpty else { return nil }

      let lines = text.components(separatedBy: "\n")
      let trailingNewline = lines.last == "" && text.hasSuffix("\n")
      var drop = Set<Int>()
      for entry in targets {
        // Keys beyond the ones that merely identify the target mean the entry carries
        // real configuration, so only the `disabled` line goes.
        let identifying: Set<String> = ["id", "name", "disabled"]
        let carriesConfiguration = entry.scalars.keys.contains { !identifying.contains($0) }
        if carriesConfiguration, let disabledLine = entry.disabledLine {
          drop.insert(disabledLine)
        } else {
          for index in entry.lineRange { drop.insert(index) }
        }
      }

      var kept = lines.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
      if trailingNewline, kept.last != "" { kept.append("") }
      return kept.joined(separator: "\n")
    }
  }

  // MARK: - Merging another profile's entries

  /// One entry of the top-level array, with its lines exactly as they appear in the file.
  ///
  /// Carried verbatim rather than re-rendered: an entry is frequently owned by another
  /// tool (the skin manager writes its own block), and re-serializing it would drop that
  /// tool's comments and formatting.
  public struct EntryBlock: Sendable, Equatable {
    public var id: String?
    public var lines: [String]

    public init(id: String?, lines: [String]) {
      self.id = id
      self.lines = lines
    }

    public var text: String { lines.joined(separator: "\n") }
  }

  /// What a merge changed, so a caller can report it without diffing the document.
  public struct MergeResult: Sendable, Equatable {
    /// The merged document.
    public var text: String
    /// Ids, or verbatim text for an entry without an id, that were not present before.
    public var appended: [String]
    /// Ids of entries whose lines were replaced by the incoming version.
    public var replaced: [String]
    /// True when a stray empty flow array had to be dropped for the document to parse.
    public var repaired: Bool

    public init(text: String, appended: [String] = [], replaced: [String] = [], repaired: Bool = false) {
      self.text = text
      self.appended = appended
      self.replaced = replaced
      self.repaired = repaired
    }
  }

  /// The document's top-level entries, in order.
  ///
  /// Returns an empty list for a document that is not a block-style array, because
  /// "nothing to read here" and "every entry" are the same answer for a caller that only
  /// wants to know what is present. A caller that intends to *edit* uses mergeEntries,
  /// which refuses such a document instead of guessing at it.
  public static func blocks(_ text: String) -> [EntryBlock] {
    ((try? positionedBlocks(text)) ?? []).map { EntryBlock(id: $0.id, lines: $0.lines) }
  }

  /// Fold the source profile's entries into the destination's patch layer.
  ///
  /// The rules are the ones an import needs and nothing more:
  ///
  /// - an incoming entry whose id is already present replaces that entry, because the
  ///   incoming profile is the one being adopted and its overrides are part of the
  ///   behaviour being copied;
  /// - an incoming entry that already appears verbatim is dropped, so importing twice
  ///   changes nothing;
  /// - everything else is appended, after a marker comment naming where it came from.
  ///
  /// Returns nil when nothing changed, which is what lets the caller leave the file's
  /// bytes — and its modification date — alone.
  public static func mergeEntries(
    _ source: String,
    into destination: String,
    marker: String? = nil
  ) throws -> MergeResult? {
    let incoming = try positionedBlocks(source)
    guard !incoming.isEmpty else { return nil }
    let existing = try positionedBlocks(destination)

    let existingTexts = Set(existing.map { normalized($0.text) })
    var replacements: [(range: Range<Int>, lines: [String])] = []
    var replacedIDs: [String] = []
    var pending: [EntryBlock] = []

    for block in incoming {
      if let id = block.id, let match = existing.first(where: { $0.id == id }) {
        // Comparing normalized text keeps a re-import of an unchanged entry from
        // rewriting the file.
        guard normalized(match.text) != normalized(block.text) else { continue }
        replacements.append((match.range, block.lines))
        replacedIDs.append(id)
        continue
      }
      guard !existingTexts.contains(normalized(block.text)) else { continue }
      pending.append(EntryBlock(id: block.id, lines: block.lines))
    }

    let lines = destination.components(separatedBy: "\n")
    var body = destination.hasSuffix("\n") && lines.last == "" ? Array(lines.dropLast()) : lines

    // Back to front, so the earlier indices stay valid as later ranges are rewritten.
    for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
      body.replaceSubrange(replacement.range, with: replacement.lines)
    }

    // The shipped template writes its patch layer as the empty flow array, and a block
    // sequence appended *below* that line is a document YAML refuses to parse — observed on
    // the first import into this app's own profile. So the empty array is where the incoming
    // entries belong, and one left above entries that are already there is dropped: either
    // way the file has to end up parseable.
    var repaired = false
    let flowMarkerIndex = body.firstIndex { line in
      line.trimmingCharacters(in: .whitespaces) == "[]" && !line.hasPrefix(" ") && !line.hasPrefix("\t")
    }
    if let flowMarkerIndex {
      repaired = !existing.isEmpty
      body.remove(at: flowMarkerIndex)
    }

    guard !pending.isEmpty || !replacedIDs.isEmpty || repaired else { return nil }

    if !pending.isEmpty {
      var insertion: [String] = []
      if let marker, !marker.isEmpty { insertion.append(marker) }
      for block in pending { insertion.append(contentsOf: block.lines) }

      if let flowMarkerIndex {
        if flowMarkerIndex > 0, !body[flowMarkerIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty {
          insertion.insert("", at: 0)
        }
        body.insert(contentsOf: insertion, at: flowMarkerIndex)
      } else {
        if let last = body.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
          insertion.insert("", at: 0)
        }
        body.append(contentsOf: insertion)
      }
    }

    var text = body.joined(separator: "\n")
    if !text.hasSuffix("\n") { text += "\n" }
    return MergeResult(
      text: text,
      appended: pending.map { $0.id ?? $0.text },
      replaced: replacedIDs,
      repaired: repaired
    )
  }

  /// One entry with the range it occupies, which replacement surgery needs.
  private struct PositionedBlock: Sendable, Equatable {
    var id: String?
    var lines: [String]
    var range: Range<Int>
    var text: String { lines.joined(separator: "\n") }
  }

  private static func positionedBlocks(_ text: String) throws -> [PositionedBlock] {
    // A top-level `[]` is the empty entry list and is understood; any other flow-style array
    // has no line-per-key structure to merge into, and is refused rather than guessed at.
    for (index, line) in text.components(separatedBy: "\n").enumerated() {
      guard let first = line.first, first != " ", first != "\t", first == "[" else { continue }
      guard line.trimmingCharacters(in: .whitespaces) == "[]" else {
        throw EditError.unsupported("line \(index + 1) is a flow-style array")
      }
    }
    switch parse(text) {
    case .unsupported(let reason):
      throw EditError.unsupported(reason)
    case .entries(let entries):
      let lines = text.components(separatedBy: "\n")
      return entries.compactMap { entry in
        guard entry.lineRange.lowerBound >= 0, entry.lineRange.upperBound <= lines.count else { return nil }
        return PositionedBlock(
          id: entry.id,
          lines: Array(lines[entry.lineRange]),
          range: entry.lineRange
        )
      }
    }
  }

  /// Text comparison that ignores indentation and blank lines, so a re-import recognizes
  /// its own work even when the file has been reformatted around it.
  private static func normalized(_ text: String) -> String {
    text
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }
}
