import Foundation
import HarnessKit

/// Tolerant argument reading for the `HarnessTool` conformances.
///
/// Why this exists: the official schemas are not uniform. `read`/`write`/`edit`/
/// `read_image` name their path field `file_path`, while `glob`/`grep` name it `path`.
/// Tool arguments also arrive from three different producers — the model, a PTC
/// program calling `tools.read(args)`, and replayed `tool/call.arguments` from a
/// session log — so a missing or slightly-styled key must produce an actionable
/// `ToolCallError`, never a silent default.
public enum ToolArgs {
  /// Codes shared by every tool in this module. `INVALID_ARGUMENTS` is the code the
  /// loop renders as `data.error.code`; `PERMISSION_DENIED` is the read-only refusal
  /// (approval prompting belongs to the loop, not to a tool).
  public static let invalidArguments = "INVALID_ARGUMENTS"
  public static let permissionDenied = "PERMISSION_DENIED"

  /// The error text the report/spec asks for: name the missing field, list the aliases
  /// that would have worked, and show the tool's canonical key.
  public static func missing(_ tool: String, field: String, aliases: [String] = []) -> ToolCallError {
    let accepted = ([field] + aliases).map { "`\($0)`" }.joined(separator: " or ")
    return ToolCallError(
      code: invalidArguments,
      message: "\(tool) requires \(accepted); \(accepted) is missing from the arguments."
    )
  }

  public static func invalid(_ tool: String, field: String, detail: String) -> ToolCallError {
    ToolCallError(code: invalidArguments, message: "invalid \(field) for \(tool): \(detail)")
  }

  /// First present, non-null value among `keys`, in order.
  public static func raw(_ arguments: JSONValue, _ keys: String...) -> JSONValue? {
    raw(arguments, keys)
  }

  public static func raw(_ arguments: JSONValue, _ keys: [String]) -> JSONValue? {
    guard let object = arguments.objectValue else { return nil }
    for key in keys {
      if let value = object[key], !value.isNull { return value }
    }
    return nil
  }

  /// Required string. Programs occasionally pass a number where a string is declared;
  /// scalars are stringified rather than rejected, so a slightly-loose call still works.
  public static func requiredString(
    _ tool: String,
    _ arguments: JSONValue,
    keys: [String],
    allowEmpty: Bool = false
  ) throws -> String {
    guard let value = raw(arguments, keys) else {
      throw missing(tool, field: keys[0], aliases: Array(keys.dropFirst()))
    }
    let text: String
    switch value {
    case .string(let string): text = string
    case .number(let number):
      text = number == number.rounded() ? String(Int64(number)) : String(number)
    case .bool(let flag): text = flag ? "true" : "false"
    default:
      throw invalid(tool, field: keys[0], detail: "expected a string, got \(value.kindName)")
    }
    if !allowEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw invalid(tool, field: keys[0], detail: "expected a non-empty string")
    }
    return text
  }

  /// Optional string; a blank string counts as absent (mirrors the official validators,
  /// which treat a whitespace-only `path`/`include` as an argument error).
  public static func optionalString(
    _ tool: String,
    _ arguments: JSONValue,
    keys: [String],
    allowEmpty: Bool = false
  ) throws -> String? {
    guard raw(arguments, keys) != nil else { return nil }
    let text = try requiredString(tool, arguments, keys: keys, allowEmpty: allowEmpty)
    if !allowEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw invalid(tool, field: keys[0], detail: "expected a non-empty string when given")
    }
    return text
  }

  public static func optionalBool(_ tool: String, _ arguments: JSONValue, keys: [String]) throws -> Bool? {
    guard let value = raw(arguments, keys) else { return nil }
    if let flag = value.boolValue { return flag }
    throw invalid(tool, field: keys[0], detail: "expected a boolean, got \(value.kindName)")
  }

  /// Optional positive integer. Accepts a JSON number or a numeric string because the
  /// official schemas declare `integer` but PTC programs routinely pass strings.
  public static func optionalPositiveInt(_ tool: String, _ arguments: JSONValue, keys: [String]) throws -> Int? {
    guard let value = raw(arguments, keys) else { return nil }
    guard let number = value.doubleValue, number.isFinite, number == number.rounded(), number >= 1 else {
      throw invalid(tool, field: keys[0], detail: "expected a positive integer, got \(value.displayText)")
    }
    return Int(number)
  }

  /// Optional non-negative integer (context lines may be `0`).
  public static func optionalNonNegativeInt(_ tool: String, _ arguments: JSONValue, keys: [String]) throws -> Int? {
    guard let value = raw(arguments, keys) else { return nil }
    guard let number = value.doubleValue, number.isFinite, number == number.rounded(), number >= 0 else {
      throw invalid(tool, field: keys[0], detail: "expected a non-negative integer, got \(value.displayText)")
    }
    return Int(number)
  }

  /// Optional positive number (`timeoutMs`).
  public static func optionalPositiveDouble(_ tool: String, _ arguments: JSONValue, keys: [String]) throws -> Double? {
    guard let value = raw(arguments, keys) else { return nil }
    guard let number = value.doubleValue, number.isFinite, number > 0 else {
      throw invalid(tool, field: keys[0], detail: "expected a positive number, got \(value.displayText)")
    }
    return number
  }

  public static func requiredArray(_ tool: String, _ arguments: JSONValue, keys: [String]) throws -> [JSONValue] {
    guard let value = raw(arguments, keys) else {
      throw missing(tool, field: keys[0], aliases: Array(keys.dropFirst()))
    }
    guard let array = value.arrayValue else {
      throw invalid(tool, field: keys[0], detail: "expected an array, got \(value.kindName)")
    }
    return array
  }

  public static func requiredObject(_ tool: String, _ arguments: JSONValue, keys: [String]) throws -> JSONValue {
    guard let value = raw(arguments, keys) else {
      throw missing(tool, field: keys[0], aliases: Array(keys.dropFirst()))
    }
    guard value.objectValue != nil else {
      throw invalid(tool, field: keys[0], detail: "expected an object, got \(value.kindName)")
    }
    return value
  }
}

extension JSONValue {
  /// Short type label used in error text (JSON `type` names, not Swift names).
  public var kindName: String {
    switch self {
    case .null: return "null"
    case .bool: return "boolean"
    case .number: return "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
  }

  /// Compact rendering for an error message; scalars print bare, containers as JSON.
  public var displayText: String {
    switch self {
    case .string(let value): return "\"\(value)\""
    case .number(let value):
      return value == value.rounded() && abs(value) < 9_007_199_254_740_992 ? String(Int64(value)) : String(value)
    case .bool(let value): return value ? "true" : "false"
    case .null: return "null"
    case .array, .object: return (try? serialized()) ?? "<unprintable>"
    }
  }
}
