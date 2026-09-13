import Foundation

/// A semver range — the subset of npm's `node-semver` the plugin ecosystem actually writes.
///
/// Hand-written for the same reason `Semver` is: this package takes no external
/// dependencies. It exists so the compatibility audit can answer "does this harness
/// version satisfy what the plugin asked for" without guessing.
///
/// The grammar accepted here is deliberately smaller than node-semver's. Every form in the
/// table below was taken from a manifest installed on this machine (measured), so the
/// parser is sized to the ecosystem rather than to the specification:
///
/// | Form                 | Real example            | Meaning              |
/// |----------------------|-------------------------|----------------------|
/// | `>=`, `<=`, `>`, `<` | `>=0.1.5-rc.1`          | comparator           |
/// | `^`                  | `^4.0.1`, `^0.1.0-rc.6` | caret                |
/// | `~`                  | `~0.1.5`                | tilde                |
/// | bare version         | `0.1.5`                 | exact                |
/// | `*`                  | `*`                     | any                  |
/// | space                | `>=0.1.5-rc.1 <0.1.6-0` | AND                  |
/// | `\|\|`                 | `^22.19.0 \|\| >=24.0.0`  | OR                   |
/// | partial + prerelease | `0.1.6-0`               | two components, prerelease
///
/// **Anything outside that grammar makes `init?` fail.** A caller that cannot parse a range
/// must report "undeclared", never "incompatible": a false "this plugin is broken" is worse
/// than an honest "the plugin did not say".
public struct SemverRange: Sendable, Equatable {
  /// One OR branch: every comparator in it must hold.
  public let alternatives: [[Comparator]]
  /// True when the range was written as a wildcard rather than as comparators.
  private let isAny: Bool

  public struct Comparator: Sendable, Equatable {
    public enum Op: String, Sendable, Equatable {
      case greaterOrEqual = ">="
      case lessOrEqual = "<="
      case greater = ">"
      case less = "<"
    }

    public var op: Op
    public var version: Semver
    /// The `major.minor.patch` triple this comparator was written against.
    ///
    /// Kept separately from `version` because node-semver's prerelease rule is stated in
    /// terms of the triple, not the prerelease: a prerelease candidate is only eligible when
    /// *some* comparator in the branch carries a prerelease on the same triple.
    public var tuple: (major: Int, minor: Int, patch: Int)
    public var hasPrerelease: Bool
    /// One half of a bare-version pin (`1.2.3` becomes `>=1.2.3 <=1.2.3`).
    ///
    /// Flagged so the prerelease gate can tell a real bound (`<0.1.6-0`, which admits a
    /// candidate's prerelease) from a pin, which must not.
    public var isExactPin: Bool

    public init(
      op: Op,
      version: Semver,
      tuple: (major: Int, minor: Int, patch: Int),
      hasPrerelease: Bool,
      isExactPin: Bool = false
    ) {
      self.op = op
      self.version = version
      self.tuple = tuple
      self.hasPrerelease = hasPrerelease
      self.isExactPin = isExactPin
    }

    public static func == (lhs: Comparator, rhs: Comparator) -> Bool {
      lhs.op == rhs.op && lhs.version == rhs.version && lhs.hasPrerelease == rhs.hasPrerelease
    }
  }

  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var parsed: [[Comparator]] = []
    var everyBranchWasWildcard = true
    for branch in trimmed.components(separatedBy: "||") {
      let tokens = branch
        .split(whereSeparator: { $0 == " " || $0 == "\t" })
        .map(String.init)
      // A branch this parser cannot read sinks the whole range rather than being dropped.
      // "Drop what you do not know" would let the understood half of `>=1.0.0 || garbage`
      // answer for the whole expression, which is exactly the guess this type exists to
      // avoid: the caller must fall back to "undeclared", not to a partial judgement.
      if tokens.isEmpty { return nil }

      var comparators: [Comparator] = []
      for token in tokens {
        // `Self.` on both calls on purpose: `isWildcard` and `comparators` are also member
        // names on this type, and the unqualified forms would resolve to the property and to
        // the local array instead of the helpers.
        if Self.isWildcard(token) { continue }
        everyBranchWasWildcard = false
        guard let desugared = Self.comparators(for: token) else { return nil }
        comparators.append(contentsOf: desugared)
      }
      parsed.append(comparators)
    }

    if parsed.isEmpty && !everyBranchWasWildcard { return nil }
    // Every branch was a wildcard: the range is "any" and holds no comparators.
    self.alternatives = parsed.filter { !$0.isEmpty }
    self.isAny = everyBranchWasWildcard
  }

  /// True when the range is a bare wildcard, i.e. it constrains nothing.
  public var isWildcard: Bool { isAny }

  /// Whether `version` is in the range.
  ///
  /// Returns `false` only for a version the range positively excludes. Prerelease handling
  /// follows node-semver: a prerelease candidate is eligible only inside a branch that also
  /// names a prerelease on the same `major.minor.patch` triple. Callers that see a prerelease
  /// candidate and a range without one should treat that as "cannot judge" rather than
  /// "rejected" — `PluginCompatibilityAudit` owns that decision.
  public func accepts(_ version: Semver) -> Bool {
    if isWildcard { return true }
    return alternatives.contains { accepts(version, in: $0) }
  }

  /// Whether the range can judge this candidate at all, before any comparison happens.
  ///
  /// This is npm's *eligibility* rule, separated from `accepts` so a caller can tell the two
  /// very different answers apart:
  ///
  /// - `.judgeable` — compare normally.
  /// - `.notEligible` — npm's prerelease gate excludes the candidate because the range never
  ///   mentions prereleases on its triple. `accepts` returns false, but the honest reading is
  ///   "the range does not speak to prereleases", not "your version is wrong". A caller that
  ///   shows a user a verdict must degrade this to "undeclared"; `accepts` alone would turn
  ///   every `>=0.1.0` against a `-rc` harness into a false failure.
  public enum PrereleaseEligibility: Sendable, Equatable {
    case judgeable
    case notEligible
  }

  public func eligibility(for candidate: Semver) -> PrereleaseEligibility {
    guard candidate.isPrerelease else { return .judgeable }
    if isWildcard { return .judgeable }
    let eligible = alternatives.contains { branch in
      isEligiblePrerelease(candidate, in: branch)
    }
    return eligible ? .judgeable : .notEligible
  }

  /// Whether this branch can judge a prerelease candidate.
  ///
  /// A candidate is judged when the branch's comparators **agree** about it — every one holds, or
  /// none does — and refused judgement only when they disagree. Disagreement is the one case where
  /// the author's intent cannot be read off the text: for `>=0.1.4 <0.1.5` against `0.1.5-rc.2`
  /// the floor holds while the ceiling appears to fail, purely because a prerelease ranks below
  /// the release that follows it. That is the situation npm's exemption exists for, so the audit
  /// says "cannot tell" rather than guessing. An unjudged candidate must never surface as
  /// "out of range".
  ///
  /// This rule was arrived at by measurement, not by transcribing npm's spec, and two earlier
  /// versions of it were wrong in opposite directions on this machine's real plugins:
  ///
  /// - Demanding an interval test made `>=0.1.5-rc.1 <0.1.6-0` ineligible against `0.1.5-rc.2`,
  ///   so `dsh-memoir` — a working, correctly-declared plugin — reported "cannot tell".
  /// - Refusing *all* disagreement made the exact union `0.1.1-rc.2 || 0.1.2-rc.1` ineligible
  ///   against a shipped `0.1.5-rc.2`, hiding a real mismatch the audit had the evidence to
  ///   report.
  ///
  /// Agreement is the only statement that satisfies both, so it is the rule.
  private func isEligiblePrerelease(_ candidate: Semver, in branch: [Comparator]) -> Bool {
    var satisfied = 0
    for comparator in branch where Self.satisfies(comparator, candidate) {
      satisfied += 1
    }
    return satisfied == branch.count || satisfied == 0
  }

  /// Whether one comparator holds for `version`, ignoring the prerelease gate above.
  ///
  /// A single predicate shared by `accepts` and the eligibility analysis, so the two can never
  /// drift into disagreeing about what a comparator means.
  private static func satisfies(_ comparator: Comparator, _ version: Semver) -> Bool {
    let ordering: ComparisonResult
    if version == comparator.version {
      ordering = .orderedSame
    } else if version < comparator.version {
      ordering = .orderedAscending
    } else {
      ordering = .orderedDescending
    }
    switch comparator.op {
    case .greater: return ordering == .orderedDescending
    case .greaterOrEqual: return ordering != .orderedAscending
    case .less: return ordering == .orderedAscending
    case .lessOrEqual: return ordering != .orderedDescending
    }
  }

  private func accepts(_ version: Semver, in branch: [Comparator]) -> Bool {
    guard !branch.isEmpty else { return true }

    if version.isPrerelease, !isEligiblePrerelease(version, in: branch) { return false }
    return branch.allSatisfy { Self.satisfies($0, version) }
  }

  // MARK: - Tokenizing

  private static func isWildcard(_ token: String) -> Bool {
    token == "*" || token.lowercased() == "x"
  }

  /// Desugar one token into the comparators it means. `^` and `~` produce two; everything
  /// else produces one.
  private static func comparators(for token: String) -> [Comparator]? {
    var body = token
    if body.hasPrefix("^") {
      body.removeFirst()
      guard let bound = version(body) else { return nil }
      return caret(bound)
    }
    if body.hasPrefix("~") {
      body.removeFirst()
      guard let bound = version(body) else { return nil }
      return tilde(bound)
    }

    var op = Comparator.Op.greaterOrEqual
    var foundPrefix = false
    var isPin = false
    for (prefix, candidate) in [(">=", Comparator.Op.greaterOrEqual),
                                ("<=", Comparator.Op.lessOrEqual)] {
      if body.hasPrefix(prefix) {
        op = candidate
        body.removeFirst(prefix.count)
        foundPrefix = true
        break
      }
    }
    if !foundPrefix {
      for (prefix, candidate) in [(">", Comparator.Op.greater),
                                  ("<", Comparator.Op.less),
                                  ("=", Comparator.Op.greaterOrEqual)] {
        if body.hasPrefix(prefix) {
          op = candidate
          // `=1.2.3` is a pin, exactly like a bare `1.2.3`: it must not admit a neighbouring
          // prerelease, so it takes the same two-comparator path below.
          isPin = candidate == .greaterOrEqual
          body.removeFirst(prefix.count)
          foundPrefix = true
          break
        }
      }
    }

    guard let bound = version(body) else { return nil }
    if !foundPrefix || isPin {
      // A bare version — or an explicit `=` — is an exact pin. Two comparators rather than a
      // dedicated op because `Semver` comparison already ignores build metadata, and
      // spreading a pin over its two bounds lets the prerelease gate above tell a pin from a
      // real bound.
      return [
        make(.greaterOrEqual, bound, isExactPin: true),
        make(.lessOrEqual, bound, isExactPin: true),
      ]
    }
    return [make(op, bound)]
  }

  /// `^1.2.3` → `>=1.2.3 <2.0.0`; `^0.1.2` → `>=0.1.2 <0.2.0`; `^0.0.3` → `>=0.0.3 <0.0.4`.
  ///
  /// The leading-zero rules are node-semver's and are the reason a caret on `0.1.x` is not
  /// the same as a caret on `1.x`.
  private static func caret(_ bound: Parsed) -> [Comparator] {
    let upper: Semver
    if bound.tuple.major > 0 {
      upper = Semver(major: bound.tuple.major + 1, minor: 0, patch: 0)
    } else if bound.tuple.minor > 0 {
      upper = Semver(major: 0, minor: bound.tuple.minor + 1, patch: 0)
    } else {
      upper = Semver(major: 0, minor: 0, patch: bound.tuple.patch + 1)
    }
    return [make(.greaterOrEqual, bound), make(.less, Parsed(version: upper, tuple: (upper.major, upper.minor, upper.patch), hasPrerelease: false))]
  }

  /// `~1.2.3` → `>=1.2.3 <1.3.0`; `~0.1` → `>=0.1.0 <0.2.0`.
  private static func tilde(_ bound: Parsed) -> [Comparator] {
    let upper = Semver(major: bound.tuple.major, minor: bound.tuple.minor + 1, patch: 0)
    return [make(.greaterOrEqual, bound), make(.less, Parsed(version: upper, tuple: (upper.major, upper.minor, upper.patch), hasPrerelease: false))]
  }

  private static func make(_ op: Comparator.Op, _ bound: Parsed, isExactPin: Bool = false) -> Comparator {
    Comparator(
      op: op,
      version: bound.version,
      tuple: bound.tuple,
      hasPrerelease: bound.hasPrerelease,
      isExactPin: isExactPin
    )
  }

  /// A parsed endpoint: the version plus the triple it was written against.
  ///
  /// Not `Equatable`: its `tuple` is a tuple, which Swift will not synthesize equality for,
  /// and nothing compares two parsed endpoints.
  struct Parsed: Sendable {
    var version: Semver
    var tuple: (major: Int, minor: Int, patch: Int)
    var hasPrerelease: Bool
  }

  /// Parse one endpoint, tolerating a missing patch (`0.1` and `0.1.6-0` both appear).
  ///
  /// `Semver.init?` requires all three components, so this deliberately does not reuse it for
  /// the split: the ecosystem writes `0.1.6-0` — two components carrying a prerelease — which
  /// `Semver` rejects by design, and rejecting a real range is exactly the false "broken
  /// plugin" this file exists to avoid.
  static func version(_ text: String) -> Parsed? {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
    guard !body.isEmpty else { return nil }

    // Split the prerelease first: everything after the first `-` is the prerelease, so the
    // numeric part can be split on `.` without swallowing `rc.1`.
    var numeric = body
    var prereleaseText: String?
    if let dash = body.firstIndex(of: "-") {
      numeric = String(body[body.startIndex..<dash])
      prereleaseText = String(body[body.index(after: dash)...])
    }
    // Build metadata is ignored for comparison (semver 2.0.0 rule 10).
    if let plus = numeric.firstIndex(of: "+") {
      numeric = String(numeric[numeric.startIndex..<plus])
    }

    let parts = numeric.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard (1...3).contains(parts.count) else { return nil }
    var numbers: [Int] = []
    for part in parts {
      // `1.x` inside a caret is not supported: no installed manifest writes it, and guessing
      // would be worse than reporting "undeclared".
      guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
      numbers.append(value)
    }
    while numbers.count < 3 { numbers.append(0) }

    var prerelease: [String] = []
    if let prereleaseText, !prereleaseText.isEmpty {
      prerelease = prereleaseText
        .split(separator: ".", omittingEmptySubsequences: false)
        .map(String.init)
      if prerelease.contains(where: \.isEmpty) { return nil }
    }

    return Parsed(
      version: Semver(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease),
      tuple: (numbers[0], numbers[1], numbers[2]),
      hasPrerelease: !prerelease.isEmpty
    )
  }
}
