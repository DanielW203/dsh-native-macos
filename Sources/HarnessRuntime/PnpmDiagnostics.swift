import Foundation

/// Reading pnpm's refusals.
///
/// pnpm does not run a dependency's lifecycle scripts unless the consumer allows them,
/// and when it refuses it prints what it skipped. Two properties make this module
/// necessary rather than nice:
///
/// - The allow-list key differs between pnpm 10 (`onlyBuiltDependencies`, a list) and
///   pnpm 11 (`allowBuilds`, a map), and neither version accepts the other's key.
/// - pnpm 11 can exit **0** while having skipped a build, so a zero exit code is not
///   evidence that an install worked. Verification of the produced files is what decides.
///
/// The parser extracts only what it can prove. When a refusal is recognized but the
/// package names cannot be located, it says so instead of inventing a key — writing a
/// guessed allow-list into a user's profile is worse than reporting the raw output.
public enum PnpmDiagnostics {
  public struct AllowList: Sendable, Equatable {
    public var packages: [String]
    public init(packages: [String] = []) { self.packages = packages }
    public var isEmpty: Bool { packages.isEmpty }
  }

  public enum Failure: Sendable, Equatable {
    case ignoredBuilds(AllowList)
    case gitPrepareNotAllowed(AllowList)
    /// Recognized as an allow-list refusal, but no package names could be extracted.
    case unrecognized(String)
    case unrelated

    public var isAllowListFailure: Bool {
      switch self {
      case .ignoredBuilds, .gitPrepareNotAllowed: return true
      default: return false
      }
    }
  }

  /// Remove ANSI colour sequences.
  ///
  /// pnpm colours its warnings, and the escapes land in the middle of the text this
  /// parser matches on often enough that parsing without stripping them is unreliable.
  public static func stripANSI(_ text: String) -> String {
    var output = ""
    output.reserveCapacity(text.count)
    var iterator = text.makeIterator()

    while let character = iterator.next() {
      guard character == "\u{1B}" else {
        output.append(character)
        continue
      }
      // A CSI sequence: ESC [ parameters... final-byte, where the final byte is 0x40-0x7E.
      guard iterator.next() == "[" else { continue }
      while let current = iterator.next() {
        if let scalar = current.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) { break }
      }
    }
    return output
  }

  /// Classify an install's output.
  public static func classify(_ output: String) -> Failure {
    let clean = stripANSI(output)

    if clean.contains("ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED") {
      let list = gitPrepareCandidates(in: clean)
      return list.isEmpty ? .unrecognized(clean) : .gitPrepareNotAllowed(list)
    }
    if clean.contains("ERR_PNPM_IGNORED_BUILDS") || clean.contains("Ignored build scripts") {
      let list = ignoredBuildScripts(in: clean)
      return list.isEmpty ? .unrecognized(clean) : .ignoredBuilds(list)
    }
    return .unrelated
  }

  /// `Ignored build scripts: a, b, c.`
  static func ignoredBuildScripts(in text: String) -> AllowList {
    var packages: [String] = []
    for line in text.components(separatedBy: "\n") {
      guard let range = line.range(of: "Ignored build scripts:") else { continue }
      packages.append(contentsOf: splitPackageList(String(line[range.upperBound...])))
    }
    return AllowList(packages: Array(Set(packages)).sorted())
  }

  /// Package names found on a line that names the allow-list key.
  ///
  /// pnpm's git-dependency refusal tells the user which key to add and prints the
  /// offending dependency in the same message. Only tokens with a plausible package-name
  /// shape are accepted, so a sentence cannot be mistaken for a dependency.
  static func gitPrepareCandidates(in text: String) -> AllowList {
    // Only quoted strings are considered. pnpm quotes the offending dependency, and
    // scanning bare words would pull "in", "to" and "it" out of the surrounding
    // sentence — an allow-list full of English words is worse than none, because it
    // gets written into the user's profile.
    let lines = text.components(separatedBy: "\n")
    let relevant = lines.filter {
      $0.contains("allowBuilds") || $0.contains("onlyBuiltDependencies")
    }
    var packages = candidates(in: relevant.joined(separator: "\n"))
    if packages.isEmpty { packages = candidates(in: text) }
    return AllowList(packages: Array(Set(packages)).sorted())
  }

  private static func candidates(in text: String) -> [String] {
    quotedStrings(in: text).filter { isPackageName($0) && !isNoise($0) }
  }

  /// Double- and single-quoted substrings.
  private static func quotedStrings(in text: String) -> [String] {
    var found: [String] = []
    var current = ""
    var quote: Character?
    for character in text {
      if let open = quote {
        if character == open {
          found.append(current)
          current = ""
          quote = nil
        } else {
          current.append(character)
        }
      } else if character == "\"" || character == "'" {
        quote = character
      }
    }
    return found
  }

  /// Words that appear quoted in pnpm's advisory but are never dependency names.
  private static let noise: Set<String> = [
    "allowbuilds", "onlybuiltdependencies", "pnpm-workspace.yaml", "pnpm-workspace",
    "yaml", "true", "false", "package.json", "pnpm-lock.yaml",
  ]

  private static func isNoise(_ candidate: String) -> Bool {
    noise.contains(candidate.lowercased())
  }

  private static func splitPackageList(_ text: String) -> [String] {
    // Token-based rather than comma-split: pnpm draws its warnings inside a box, so the
    // last name in the list is followed by box-drawing characters rather than only a
    // period, and a comma split leaves them glued to the name.
    tokens(in: text).map(normalizing).filter(isPackageName)
  }

  /// Drop sentence punctuation from the end of a token: §esbuild.§ is §esbuild§.
  private static func normalizing(_ token: String) -> String {
    var value = token
    while let last = value.last, last == "." || last == "," { value.removeLast() }
    return value
  }

  private static func tokens(in line: String) -> [String] {
    line
      .components(separatedBy: CharacterSet(charactersIn: " \t\"'\u{60},()[]{}:"))
      .filter { !$0.isEmpty }
  }

  /// A conservative npm package-name check: lowercase, optionally scoped, no spaces, and
  /// at least one letter so bare numbers and version strings are rejected.
  static func isPackageName(_ candidate: String) -> Bool {
    guard !candidate.isEmpty, candidate.count < 214 else { return false }
    guard !candidate.hasPrefix("."), !candidate.hasPrefix("/"), !candidate.hasPrefix("-") else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789@/._-")
    guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
    return candidate.contains { $0.isLetter }
  }
}
