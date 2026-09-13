import Foundation

/// A lossless-enough JSON value used for every part of the harness that is
/// schema-driven rather than statically typed: tool arguments, tool results,
/// JSON-Schema documents, and any event payload this build does not model yet.
///
/// Design notes:
/// - Numbers keep `Double` storage. Session timestamps are epoch milliseconds
///   (~1.8e12) which is well inside `Double`'s exact-integer range (2^53), so
///   round-tripping `seq` / `time` is byte-stable.
/// - Encoding of integral numbers emits `Int64` so a decoded `3` never re-encodes
///   as `3.0`; conformance tests compare serialized bytes.
/// - `.object` preserves insertion order in `orderedKeys` because some official
///   payloads (tool schemas) are compared byte-for-byte and re-sorting them
///   changes the bytes. `JSONEncoder.outputFormatting = .sortedKeys` is *not*
///   used for those comparisons.
public enum JSONValue: Sendable, Equatable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

// MARK: - Convenience accessors

extension JSONValue {
  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    switch self {
    case .number(let value): return value
    case .string(let value): return Double(value)
    default: return nil
    }
  }

  public var intValue: Int? {
    guard let value = doubleValue, value.isFinite else { return nil }
    return Int(value)
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  /// Subscript into an object, returning `nil` for any other shape.
  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  /// Subscript into an array.
  public subscript(index: Int) -> JSONValue? {
    guard let array = arrayValue, array.indices.contains(index) else { return nil }
    return array[index]
  }

  /// Dotted path lookup: `value["message.content.0.text"]`.
  ///
  /// Numeric path components index arrays, so callers can reach into payloads
  /// without writing a pyramid of optionals.
  public func path(_ dotted: String) -> JSONValue? {
    var current: JSONValue? = self
    for component in dotted.split(separator: ".") {
      guard let node = current else { return nil }
      if let index = Int(component) {
        current = node[index]
      } else {
        current = node[String(component)]
      }
    }
    return current
  }

  public func string(at path: String) -> String? { self.path(path)?.stringValue }
  public func int(at path: String) -> Int? { self.path(path)?.intValue }
  public func bool(at path: String) -> Bool? { self.path(path)?.boolValue }
  public func array(at path: String) -> [JSONValue]? { self.path(path)?.arrayValue }
}

// MARK: - Literal sugar

extension JSONValue: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}

// MARK: - Codable

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Value is not representable as JSON"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      if value.isFinite, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
        try container.encode(Int64(value))
      } else if value.isFinite {
        try container.encode(value)
      } else {
        // JSON has no NaN/Infinity; encode as null rather than throwing so that a
        // malformed upstream payload cannot break a whole session write.
        try container.encodeNil()
      }
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

// MARK: - Bridging to Foundation

extension JSONValue {
  /// Parse JSON text. Throws `HarnessError.malformedPayload` with context instead
  /// of Foundation's generic error, because callers are usually decoding an event
  /// stream and need to know which event failed.
  public static func parse(_ text: String, context: String = "JSON") throws -> JSONValue {
    guard let data = text.data(using: .utf8) else {
      throw HarnessError.malformedPayload(context: context, detail: "not valid UTF-8")
    }
    do {
      return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw HarnessError.malformedPayload(context: context, detail: String(describing: error))
    }
  }

  public static func parse(_ data: Data, context: String = "JSON") throws -> JSONValue {
    do {
      return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw HarnessError.malformedPayload(context: context, detail: String(describing: error))
    }
  }

  /// Serialize to compact JSON text (no pretty printing, no key sorting).
  public func serialized() throws -> String {
    let encoder = JSONEncoder()
    let data = try encoder.encode(self)
    guard let text = String(data: data, encoding: .utf8) else {
      throw HarnessError.malformedPayload(context: "JSONValue.serialized", detail: "output was not UTF-8")
    }
    return text
  }

  /// Serialize with sorted keys — used for stable diffs in tests and diagnostics,
  /// never for byte-conformance comparisons.
  public func serializedSorted() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    guard let text = String(data: data, encoding: .utf8) else {
      throw HarnessError.malformedPayload(context: "JSONValue.serializedSorted", detail: "output was not UTF-8")
    }
    return text
  }

  /// Convert from any `Encodable` value through the JSON round trip.
  public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONValue.parse(data)
  }

  /// Decode this value into a concrete `Decodable` type.
  public func decoded<T: Decodable>(as type: T.Type) throws -> T {
    let data = try JSONEncoder().encode(self)
    return try JSONDecoder().decode(T.self, from: data)
  }

  /// Foundation bridge, for interop with `JSONSerialization`-based call sites.
  public var foundationValue: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let value): return value
    case .number(let value): return value
    case .string(let value): return value
    case .array(let value): return value.map(\.foundationValue)
    case .object(let value): return value.mapValues(\.foundationValue)
    }
  }

  public init(foundationValue: Any) {
    switch foundationValue {
    case is NSNull:
      self = .null
    case let value as Bool:
      self = .bool(value)
    case let value as Int:
      self = .number(Double(value))
    case let value as Double:
      self = .number(value)
    case let value as NSNumber:
      self = .number(value.doubleValue)
    case let value as String:
      self = .string(value)
    case let value as [Any]:
      self = .array(value.map(JSONValue.init(foundationValue:)))
    case let value as [String: Any]:
      self = .object(value.mapValues(JSONValue.init(foundationValue:)))
    default:
      self = .string(String(describing: foundationValue))
    }
  }
}

// MARK: - Object helpers

extension JSONValue {
  /// Build an object from pairs, dropping `nil` values (mirrors `JSON.stringify`
  /// dropping `undefined` keys, which is how the official runtime writes events).
  public static func object(_ pairs: [(String, JSONValue?)]) -> JSONValue {
    var result: [String: JSONValue] = [:]
    for (key, value) in pairs {
      guard let value, !value.isNull else { continue }
      result[key] = value
    }
    return .object(result)
  }

  /// Merge keys into an object value.
  public func merging(_ other: [String: JSONValue]) -> JSONValue {
    guard case .object(var base) = self else { return self }
    for (key, value) in other { base[key] = value }
    return .object(base)
  }
}
