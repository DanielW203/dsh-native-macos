import Foundation
import HarnessKit

/// What one plugin's declared compatibility says about the harness installed here.
public enum CompatibilityVerdict: Sendable, Equatable {
  /// Every readable claim holds. A plugin with no claim is *not* this — see `undeclared`.
  case compatible
  /// At least one claim is positively violated.
  case incompatible([CompatibilityViolation])
  /// The plugin declares nothing this app knows how to check.
  ///
  /// Kept separate from `compatible` because the two mean different things to a user: "the
  /// author says this works with your version" versus "the author did not say". Collapsing
  /// them would turn silence into a promise.
  case undeclared
}

/// One concrete reason a plugin and this harness disagree.
public struct CompatibilityViolation: Sendable, Equatable {
  /// Which declaration the disagreement came from.
  public enum Basis: String, Sendable, Equatable {
    /// `dsh.engines.dsh` against the harness release version.
    case engines
    /// A `@deepseek-ai/dsh-*` peer range against that package's version in the release.
    case peerDependency
    /// A private copy of a harness package inside the plugin's own `node_modules`.
    case versionShadow
  }

  public var basis: Basis
  /// The name the range was about: `dsh` for engines, the package name for a peer.
  public var subject: String
  public var declared: String
  public var actual: String
  /// One line a user can act on.
  public var detail: String
}

/// The audit result for one installed plugin.
public struct PluginCompatibility: Sendable, Equatable, Identifiable {
  public var record: PluginRecord
  public var verdict: CompatibilityVerdict
  /// True only when the verdict is `undeclared` *and* a declaration existed that could not be
  /// judged, as opposed to the plugin declaring nothing at all.
  ///
  /// Gated on the verdict on purpose: a plugin with one judgeable claim and one unreadable claim
  /// is `compatible`, and reporting "unjudged" beside that verdict would contradict it.
  public var isUnjudged: Bool
  /// Declared peers the release does not ship at all, so there was nothing to compare against.
  ///
  /// Named separately from an unreadable range because the two are different facts about the
  /// plugin ecosystem: a peer the harness no longer publishes is usually a package that was
  /// renamed or folded into another, while an unreadable range is a syntax this parser does not
  /// know yet.
  public var missingPeers: [String]
  /// Declared ranges this parser could not read, so the detail view can name what it could not
  /// check instead of only saying that it could not check something.
  public var unreadableClaims: [String]

  public var id: String { record.name }
}

/// Decide whether each installed plugin still agrees with the harness this app installed.
///
/// A pure function over values with no file I/O, because this judgement is the whole feature:
/// it has to be exercisable against the real manifests of a real profile, and a reader that
/// touched the filesystem would only be testable on the machine that wrote it.
///
/// **The design rule is asymmetry.** A wrong "incompatible" makes the user uninstall a plugin
/// that works, so every uncertain case degrades to `undeclared`:
///
/// - an unparseable range is not a violation,
/// - a prerelease candidate against a range that only names release bounds is not a violation,
///   because npm's prerelease rule is subtle enough that a false alarm is more likely than a
///   true one (see `SemverRange.accepts`),
/// - a missing actual version leaves the claim unjudged rather than failed.
public enum PluginCompatibilityAudit {
  public static func audit(
    records: [PluginRecord],
    harnessVersion: String?,
    bundledVersions: [String: String],
    shadowed: [String: [String]] = [:]
  ) -> [PluginCompatibility] {
    records.map { record in
      judge(record, harnessVersion: harnessVersion, bundledVersions: bundledVersions, shadowed: shadowed)
    }
  }

  private static func judge(
    _ record: PluginRecord,
    harnessVersion: String?,
    bundledVersions: [String: String],
    shadowed: [String: [String]]
  ) -> PluginCompatibility {
    var violations: [CompatibilityViolation] = []
    var sawReadableClaim = false
    var sawUnjudgedClaim = false
    var missingPeers: [String] = []
    var unreadableClaims: [String] = []

    // 1. `dsh.engines.dsh` against the installed release version.
    if let engines = record.enginesRange {
      if let range = SemverRange(engines) {
        if let actual = harnessVersion, let parsed = Semver(actual) {
          switch range.eligibility(for: parsed) {
          case .judgeable:
            sawReadableClaim = true
            if !range.isWildcard, !range.accepts(parsed) {
              violations.append(CompatibilityViolation(
                basis: .engines,
                subject: "dsh",
                declared: engines,
                actual: actual,
                detail: "declares dsh \(engines), this harness is \(actual)"
              ))
            }
          case .notEligible:
            // npm's prerelease rule excludes this candidate because the range never speaks to
            // prereleases. `accepts` would say false; the honest answer is "cannot judge",
            // because a false "your plugin is broken" is the failure this audit must avoid.
            sawUnjudgedClaim = true
          }
        } else {
          sawUnjudgedClaim = true
        }
      } else {
        sawUnjudgedClaim = true
        unreadableClaims.append("dsh.engines.dsh \(engines)")
      }
    }

    // 2. Each `@deepseek-ai/dsh-*` peer against that package's version in the release.
    for (name, declared) in record.dshPeerRanges.sorted(by: { $0.key < $1.key }) {
      guard let range = SemverRange(declared) else {
        sawUnjudgedClaim = true
        unreadableClaims.append("\(name) \(declared)")
        continue
      }
      guard let actual = bundledVersions[name], let parsed = Semver(actual) else {
        // The release does not ship this package, so there is nothing to compare against.
        sawUnjudgedClaim = true
        missingPeers.append(name)
        continue
      }
      guard range.eligibility(for: parsed) == .judgeable else {
        sawUnjudgedClaim = true
        unreadableClaims.append("\(name) \(declared) vs \(actual)")
        continue
      }
      sawReadableClaim = true
      if !range.isWildcard, !range.accepts(parsed) {
        violations.append(CompatibilityViolation(
          basis: .peerDependency,
          subject: name,
          declared: declared,
          actual: actual,
          detail: "peer \(name) \(declared), this harness ships \(actual)"
        ))
      }
    }

    // 3. A private copy of a harness package inside the plugin.
    for name in shadowed[record.name] ?? [] {
      let actual = bundledVersions[name] ?? "unknown"
      violations.append(CompatibilityViolation(
        basis: .versionShadow,
        subject: name,
        declared: record.dshPeerRanges[name] ?? "no declared range",
        actual: actual,
        detail: "bundles its own copy of \(name), so the shared \(actual) was not used"
      ))
    }

    let verdict: CompatibilityVerdict
    if !violations.isEmpty {
      verdict = .incompatible(violations)
    } else if sawReadableClaim {
      verdict = .compatible
    } else {
      verdict = .undeclared
    }
    return PluginCompatibility(
      record: record,
      verdict: verdict,
      isUnjudged: verdict == .undeclared && sawUnjudgedClaim,
      missingPeers: missingPeers,
      unreadableClaims: unreadableClaims
    )
  }

  /// The one-line summary the plugin list shows.
  public static func summary(for compatibility: PluginCompatibility) -> String {
    switch compatibility.verdict {
    case .compatible:
      return "compatible"
    case .incompatible(let violations):
      let first = violations[0]
      return violations.count == 1
        ? "out of range: \(first.detail)"
        : "out of range (\(violations.count) findings): \(first.detail)"
    case .undeclared:
      guard compatibility.isUnjudged else { return "no version declared" }
      if !compatibility.missingPeers.isEmpty {
        return "peer not shipped: \(compatibility.missingPeers.joined(separator: ", "))"
      }
      if !compatibility.unreadableClaims.isEmpty {
        return "range not readable: \(compatibility.unreadableClaims.joined(separator: ", "))"
      }
      return "not judgeable"
    }
  }
}
