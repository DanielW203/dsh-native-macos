import Foundation

/// A semantic version (semver 2.0.0).
///
/// Hand-written because the package takes no external dependencies, and because the
/// only two uses here — comparing harness versions for updates and testing Node
/// against the harness' `^22.19.0 || >=24.0.0` engine range — need exact
/// pre-release ordering that an ad-hoc integer compare gets wrong. The live harness
/// ships pre-releases (this machine runs `0.1.5-rc.1`), so `rc` ordering is not
/// hypothetical.
public struct Semver: Sendable, Equatable, Comparable, CustomStringConvertible {
  public var major: Int
  public var minor: Int
  public var patch: Int
  /// Dot-separated identifiers; empty for a release version.
  public var prerelease: [String]
  /// Build metadata. Ignored for comparison, per semver 2.0.0 rule 10.
  public var build: String?

  public init(major: Int, minor: Int, patch: Int, prerelease: [String] = [], build: String? = nil) {
    self.major = major
    self.minor = minor
    self.patch = patch
    self.prerelease = prerelease
    self.build = build
  }

  /// Parse `v1.2.3`, `1.2.3-rc.1`, `0.1.5-rc.1+build.7`. A leading `v` or `=` is
  /// tolerated because release tags on GitHub carry one and this is the only parser
  /// between a tag and a comparison.
  public init?(_ text: String) {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("v") || body.hasPrefix("V") || body.hasPrefix("=") {
      body.removeFirst()
    }
    guard !body.isEmpty else { return nil }

    var buildMetadata: String?
    if let plus = body.firstIndex(of: "+") {
      buildMetadata = String(body[body.index(after: plus)...])
      body = String(body[body.startIndex..<plus])
    }

    var identifiers: [String] = []
    if let dash = body.firstIndex(of: "-") {
      let suffix = String(body[body.index(after: dash)...])
      body = String(body[body.startIndex..<dash])
      identifiers = suffix.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
      if identifiers.contains(where: \.isEmpty) { return nil }
    }

    let components = body.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }
    var numbers: [Int] = []
    for component in components {
      guard !component.isEmpty,
            component.allSatisfy(\.isNumber),
            let value = Int(component) else { return nil }
      numbers.append(value)
    }
    self.init(major: numbers[0], minor: numbers[1], patch: numbers[2],
              prerelease: identifiers, build: buildMetadata)
  }

  public var isPrerelease: Bool { !prerelease.isEmpty }

  public var description: String {
    var text = "\(major).\(minor).\(patch)"
    if !prerelease.isEmpty { text += "-" + prerelease.joined(separator: ".") }
    if let build { text += "+" + build }
    return text
  }

  public static func < (lhs: Semver, rhs: Semver) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
    // A release outranks any pre-release of the same triple (rule 11).
    if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
    if lhs.prerelease.isEmpty { return false }
    if rhs.prerelease.isEmpty { return true }
    for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
      let left = lhs.prerelease[index]
      let right = rhs.prerelease[index]
      if left == right { continue }
      switch (Int(left), Int(right)) {
      case (let l?, let r?): return l < r
      case (_?, nil): return true       // numeric ranks below alphanumeric (rule 11.4.3)
      case (nil, _?): return false
      default: return left < right
      }
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }

  public static func == (lhs: Semver, rhs: Semver) -> Bool {
    lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
      && lhs.prerelease == rhs.prerelease
  }
}

/// The Node engine range the harness declares: `^22.19.0 || >=24.0.0`.
///
/// Hard-coded rather than read from the package manifest because the check has to run
/// *before* a candidate release is trusted enough to read a manifest from.
public enum NodeRequirement {
  public static let display = "^22.19.0 || >=24.0.0"

  /// True when `version` satisfies the harness engine range.
  public static func accepts(_ version: String) -> Bool {
    guard let parsed = Semver(version) else { return false }
    if parsed.major == 22 { return parsed >= Semver(major: 22, minor: 19, patch: 0) }
    if parsed.major >= 24 { return true }
    return false
  }
}
