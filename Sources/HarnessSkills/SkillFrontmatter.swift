import Foundation

/// A SKILL.md split at its frontmatter delimiters.
///
/// The two halves are kept apart rather than re-serialized from a dictionary: the whole
/// point of the editing path is that every line the user did not ask to change survives
/// byte for byte, including keys this app has never heard of.
public struct SkillDocument: Sendable, Equatable {
  /// The lines between the delimiters, right-trimmed of `\r` so a CRLF file compares equal
  /// to its LF twin (the Web plugin's field rewrite normalizes the block the same way).
  public var frontmatterLines: [String]
  /// Everything from the closing delimiter's line terminator onwards, verbatim — the Web
  /// plugin's `match[2]` has exactly this extent, which is what makes re-serializing a file
  /// round-trip including its line endings.
  public var body: String

  public init(frontmatterLines: [String], body: String) {
    self.frontmatterLines = frontmatterLines
    self.body = body
  }
}

/// The fields of a SKILL.md the skill registry actually acts on.
public struct SkillMetadata: Sendable, Equatable {
  public var name: String
  public var description: String
  public var whenToUse: String?
  /// `disable-model-invocation != true` — the official default is that a model may invoke it.
  public var modelInvocable: Bool
  /// `user-invocable != false` — the official default is that a human may invoke it.
  public var userInvocable: Bool

  public init(
    name: String,
    description: String,
    whenToUse: String? = nil,
    modelInvocable: Bool = true,
    userInvocable: Bool = true
  ) {
    self.name = name
    self.description = description
    self.whenToUse = whenToUse
    self.modelInvocable = modelInvocable
    self.userInvocable = userInvocable
  }
}

/// Why the official provider would refuse a SKILL.md.
///
/// Surfaced instead of silently dropping the entry: a skill that exists on disk but never
/// loads is exactly the thing a user opens a skill centre to find out about.
public enum SkillFrontmatterIssue: Sendable, Equatable {
  case missingFrontmatter
  case notAMapping
  case missingName
  case missingDescription
  case invalidName(String)
  case legacyKey(String)
  case invalidBoolean(String)
  /// The file exists but is not UTF-8 text, so nothing can be read out of it.
  case unreadableFile

  public var message: String {
    switch self {
    case .missingFrontmatter:
      return "没有 frontmatter：文件必须以 `---` 开头并有闭合的 `---`。"
    case .notAMapping:
      return "frontmatter 不是键值映射。"
    case .missingName:
      return "frontmatter 缺少 name。"
    case .missingDescription:
      return "frontmatter 缺少 description。"
    case .invalidName(let name):
      return "name「\(name)」不符合 kebab-case 规则。"
    case .legacyKey(let key):
      return "使用了已废弃的字段「\(key)」：官方要求写成 disable-model-invocation / user-invocable。"
    case .invalidBoolean(let key):
      return "字段「\(key)」不是布尔值。"
    case .unreadableFile:
      return "文件不是 UTF-8 文本。"
    }
  }
}

/// The outcome of reading a SKILL.md: usable metadata, or the reason it would be ignored.
public enum SkillFrontmatterRead: Sendable, Equatable {
  case loaded(SkillMetadata)
  case issue(SkillFrontmatterIssue)
}

/// Frontmatter reading and line-level rewriting for SKILL.md files.
///
/// Mirrors `@deepseek-ai/dsh-skill-filesystem`'s acceptance rules and
/// `@linxin666/dsh-client-ui-skill-explorer`'s `setFrontmatterField` write algorithm, so a
/// file this app edits stays loadable by the official provider and a file the Web plugin
/// wrote stays readable here.
///
/// Scope, stated plainly because it is a deliberate limit: the official provider parses the
/// block with a full YAML library. This parser understands the shapes real SKILL.md files
/// use — `key: value`, single/double-quoted scalars, and `|`/`>` block scalars — plus the
/// two booleans and the legacy keys it has to reject. Anything else is reported as
/// `notAMapping` rather than guessed at.
public enum SkillFrontmatter {
  /// The official `SKILL_NAME` grammar from `@deepseek-ai/dsh-skill`.
  public static let namePattern = "\\A[a-z0-9]+(?:-[a-z0-9]+)*\\z"
  /// Keys the official parser rejects outright, with the canonical spelling to use instead.
  public static let legacyKeys: [String: String] = [
    "disableModelInvocation": "disable-model-invocation",
    "modelInvocable": "disable-model-invocation",
    "userInvocable": "user-invocable",
  ]
  /// The Web plugin's create-form cap, kept so a skill made here is a skill made there.
  public static let contentByteLimit = 64 * 1024

  public static func isSkillName(_ value: String) -> Bool {
    value.range(of: namePattern, options: [.regularExpression]) != nil
  }

  /// Split a file at its frontmatter delimiters.
  ///
  /// - Returns: `nil` when the first line is not exactly `---` (after a trailing `\r`) or
  ///   when no closing `---` line exists — both cases the official parser also rejects.
  public static func document(in raw: String) -> SkillDocument? {
    let lines = raw.components(separatedBy: "\n")
    guard let first = lines.first, stripCarriageReturn(first) == "---" else { return nil }
    guard let closing = lines.dropFirst().firstIndex(where: { stripCarriageReturn($0) == "---" }) else {
      return nil
    }
    let frontmatter = lines[1..<closing].map(stripCarriageReturn)
    // The terminator belongs to the body: `components(separatedBy:)` consumes it, and a body
    // that silently lost the newline after the closing `---` is how a rewrite glues the
    // delimiter onto the first line of prose.
    let terminator: String
    if closing == lines.count - 1 {
      terminator = ""
    } else {
      terminator = lines[closing].hasSuffix("\r") ? "\r\n" : "\n"
    }
    let body = terminator + lines[(closing + 1)...].joined(separator: "\n")
    return SkillDocument(frontmatterLines: Array(frontmatter), body: body)
  }

  /// Read the fields the registry acts on, or the reason the file would be ignored.
  public static func read(_ raw: String) -> SkillFrontmatterRead {
    guard let document = document(in: raw) else { return .issue(.missingFrontmatter) }

    var values: [String: String] = [:]
    var sawMappingLine = false
    var index = 0
    while index < document.frontmatterLines.count {
      let line = document.frontmatterLines[index]
      guard let pair = keyValue(line) else {
        // A YAML sequence is the one non-mapping shape worth naming: everything else on its
        // own line (indented continuation, comment, blank) is simply not a field we act on.
        if line == "-" || line.hasPrefix("- ") { return .issue(.notAMapping) }
        index += 1
        continue
      }
      sawMappingLine = true
      let value = pair.value.trimmingCharacters(in: .whitespaces)
      if isBlockScalar(value) {
        var collected: [String] = []
        var next = index + 1
        while next < document.frontmatterLines.count {
          let candidate = document.frontmatterLines[next]
          guard candidate.isEmpty || candidate.hasPrefix(" ") || candidate.hasPrefix("\t") else { break }
          collected.append(candidate.trimmingCharacters(in: .whitespaces))
          next += 1
        }
        values[pair.key] = collected.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        index = next
        continue
      }
      values[pair.key] = unquote(value)
      index += 1
    }

    if !sawMappingLine, !document.frontmatterLines.isEmpty { return .issue(.notAMapping) }

    for legacy in legacyKeys.keys where values[legacy] != nil {
      return .issue(.legacyKey(legacy))
    }

    guard let name = nonEmpty(values["name"]) else { return .issue(.missingName) }
    guard isSkillName(name) else { return .issue(.invalidName(name)) }
    guard let description = nonEmpty(values["description"]) else { return .issue(.missingDescription) }

    let disableModelInvocation: Bool
    switch boolean(values["disable-model-invocation"]) {
    case .absent: disableModelInvocation = false
    case .value(let flag): disableModelInvocation = flag
    case .invalid: return .issue(.invalidBoolean("disable-model-invocation"))
    }
    let userInvocable: Bool
    switch boolean(values["user-invocable"]) {
    case .absent: userInvocable = true
    case .value(let flag): userInvocable = flag
    case .invalid: return .issue(.invalidBoolean("user-invocable"))
    }

    return .loaded(
      SkillMetadata(
        name: name,
        description: description,
        whenToUse: nonEmpty(values["whenToUse"]),
        modelInvocable: !disableModelInvocation,
        userInvocable: userInvocable
      )
    )
  }

  /// Rewrite one boolean field, preserving every other line and the body verbatim.
  ///
  /// The value is always written, never deleted: an absent `disable-model-invocation` means
  /// the same thing as `false`, and writing it out is what makes the panel's switch and the
  /// file agree on a reading. The field is appended to the block when it is missing, which is
  /// where the Web plugin puts it too.
  public static func setting(_ field: String, to value: Bool, in raw: String) throws -> String {
    guard let document = document(in: raw) else {
      throw SkillCenterError.missingFrontmatter("SKILL.md")
    }
    let prefix = field + ":"
    var replaced = false
    var lines = document.frontmatterLines.map { line -> String in
      guard line.hasPrefix(prefix) else { return line }
      replaced = true
      return "\(field): \(value)"
    }
    if !replaced { lines.append("\(field): \(value)") }
    return "---\n" + lines.joined(separator: "\n") + "\n---" + document.body
  }

  /// The create-form template, byte for byte the one the Web plugin writes.
  public static func created(name: String, description: String, whenToUse: String?, content: String) -> String {
    var lines = ["---", "name: \(name)", "description: \(quote(description))"]
    if let whenToUse = nonEmpty(whenToUse?.trimmingCharacters(in: .whitespacesAndNewlines)) {
      lines.append("whenToUse: \(quote(whenToUse))")
    }
    lines.append("---")
    lines.append("")
    lines.append(content.trimmingCharacters(in: .whitespacesAndNewlines))
    lines.append("")
    return lines.joined(separator: "\n")
  }

  // MARK: - Scalars

  /// Single-quote a YAML scalar, doubling embedded quotes.
  ///
  /// Quoted rather than bare because descriptions are Chinese prose containing `：` and `，`;
  /// a bare scalar with a colon inside is the classic way to write a file that stops loading.
  public static func quote(_ value: String) -> String {
    let flattened = value.replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    return "'" + flattened.replacingOccurrences(of: "'", with: "''") + "'"
  }

  enum BooleanRead: Equatable {
    case absent
    case value(Bool)
    case invalid
  }

  /// The official `frontmatterBoolean` literal set, case-insensitive.
  static func boolean(_ text: String?) -> BooleanRead {
    guard let text else { return .absent }
    switch text.trimmingCharacters(in: .whitespaces).lowercased() {
    case "true", "yes", "on", "1": return .value(true)
    case "false", "no", "off", "0": return .value(false)
    default: return .invalid
    }
  }

  static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func stripCarriageReturn(_ line: String) -> String {
    line.hasSuffix("\r") ? String(line.dropLast()) : line
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, let last = value.last, first == last,
      first == "\"" || first == "'"
    else { return value }
    let inner = String(value.dropFirst().dropLast())
    // YAML's two escaping rules, as the official parser would apply them: a single-quoted
    // scalar doubles its quote, a double-quoted one backslash-escapes it.
    if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
    return inner
      .replacingOccurrences(of: "\\\"", with: "\"")
      .replacingOccurrences(of: "\\\\", with: "\\")
  }

  private static func isBlockScalar(_ value: String) -> Bool {
    guard let first = value.first, first == "|" || first == ">" else { return false }
    let rest = value.dropFirst()
    return rest.isEmpty || (rest.count == 1 && (rest.first == "-" || rest.first == "+"))
  }

  /// A top-level `key: value` line. Indented lines never match, which is what keeps a nested
  /// `input:` block's children out of the field table.
  private static func keyValue(_ line: String) -> (key: String, value: String)? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let key = String(line[line.startIndex..<colon])
    guard let first = key.first, first.isASCII, first.isLetter else { return nil }
    guard key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
      return nil
    }
    return (key, String(line[line.index(after: colon)...]))
  }
}
