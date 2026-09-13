import Foundation
import XCTest
@testable import HarnessRuntime

/// The range parser behind the plugin compatibility audit.
///
/// Two things are under test, and the second matters more than the first:
///
/// 1. The real ranges the ecosystem writes (`>=0.1.5-rc.1 <0.1.6-0` and friends) parse and
///    judge correctly.
/// 2. A range this parser does *not* understand must come back unusable, never "satisfied".
///    The audit's worst possible bug is telling the user a working plugin is broken, or
///    telling them a broken one is fine; both start with a parser that guesses.
final class SemverRangeTests: XCTestCase {
  private func version(_ text: String) -> Semver {
    guard let parsed = Semver(text) else {
      XCTFail("fixture version \(text) should parse")
      return Semver(major: 0, minor: 0, patch: 0)
    }
    return parsed
  }

  private func accepts(_ range: String, _ candidate: String) throws -> Bool {
    let parsed = try XCTUnwrap(SemverRange(range), "\(range) should parse")
    return parsed.accepts(version(candidate))
  }

  // MARK: - The ranges this machine actually has installed

  /// `dsh-memoir` declares `>=0.1.5-rc.1 <0.1.6-0` in both `dsh.engines.dsh` and its
  /// `@deepseek-ai/dsh-tools` / `dsh-llm` peers. The installed harness is `0.1.5-rc.2`, so
  /// this must be a pass — and it is the case that a naive reading of the upper bound gets
  /// wrong, because `0.1.6-0` names a triple the candidate does not have.
  func testMemoirRangeAcceptsTheInstalledHarness() throws {
    let range = ">=0.1.5-rc.1 <0.1.6-0"
    XCTAssertTrue(try accepts(range, "0.1.5-rc.2"))
    XCTAssertTrue(try accepts(range, "0.1.5-rc.1"))
    XCTAssertTrue(try accepts(range, "0.1.5"), "a final 0.1.5 release is above 0.1.5-rc.1")
  }

  func testMemoirRangeRejectsVersionsOutsideIt() throws {
    let range = ">=0.1.5-rc.1 <0.1.6-0"
    XCTAssertFalse(try accepts(range, "0.1.4"), "below the floor")
    XCTAssertFalse(try accepts(range, "0.1.5-rc.0"), "below the prerelease floor")
    XCTAssertFalse(try accepts(range, "0.1.6"), "above the ceiling")
    XCTAssertFalse(try accepts(range, "0.1.6-rc.1"), "0.1.6-0 is the floor of the next triple")
    XCTAssertFalse(try accepts(range, "0.2.0"), "far above")
  }

  /// `dsh-free-search` declares `>=0.1.1-rc.1` with no ceiling.
  func testFreeSearchRangeHasNoCeiling() throws {
    let range = ">=0.1.1-rc.1"
    XCTAssertTrue(try accepts(range, "0.1.1-rc.1"))
    XCTAssertTrue(try accepts(range, "0.1.5-rc.2"))
    XCTAssertTrue(try accepts(range, "0.9.0"))
    XCTAssertTrue(try accepts(range, "1.0.0"))
    XCTAssertFalse(try accepts(range, "0.1.1-rc.0"))
  }

  /// The `peerDependencies` on `@deepseek-ai/cordis`: caret on a major.
  func testCaretOnMajor() throws {
    let range = "^4.0.1"
    XCTAssertTrue(try accepts(range, "4.0.1"))
    XCTAssertTrue(try accepts(range, "4.9.9"))
    XCTAssertFalse(try accepts(range, "5.0.0"))
    XCTAssertFalse(try accepts(range, "4.0.0"))
  }

  /// The `peerDependencies` on `@deepseek-ai/dsh-settings`: caret with a prerelease floor,
  /// and a leading zero — so the ceiling is the *minor*, not the major.
  func testCaretWithLeadingZeroAndPrereleaseFloor() throws {
    let range = "^0.1.0-rc.6"
    XCTAssertTrue(try accepts(range, "0.1.0-rc.6"))
    XCTAssertTrue(try accepts(range, "0.1.0-rc.7"))
    XCTAssertTrue(try accepts(range, "0.1.0"), "the release outranks its prereleases")
    XCTAssertTrue(try accepts(range, "0.1.5"))
    XCTAssertFalse(try accepts(range, "0.2.0"), "caret on 0.x pins the minor")
    XCTAssertFalse(try accepts(range, "0.0.9"))
  }

  /// `0.0.x` caret pins the patch. Not present in a manifest on this machine, but it is the
  /// third leading-zero branch and the one a hand-rolled implementation most often misses.
  func testCaretOnZeroZero() throws {
    let range = "^0.0.3"
    XCTAssertTrue(try accepts(range, "0.0.3"))
    XCTAssertFalse(try accepts(range, "0.0.4"))
    XCTAssertFalse(try accepts(range, "0.1.0"))
  }

  func testTilde() throws {
    let range = "~1.2.3"
    XCTAssertTrue(try accepts(range, "1.2.3"))
    XCTAssertTrue(try accepts(range, "1.2.9"))
    XCTAssertFalse(try accepts(range, "1.3.0"))
    XCTAssertFalse(try accepts(range, "1.2.2"))
  }

  /// The shape `NodeRequirement` already hard-codes, used here to keep the general parser
  /// honest against the one-off it was written next to.
  func testUnionsMatchTheHardCodedNodeRequirement() throws {
    let range = "^22.19.0 || >=24.0.0"
    for accepted in ["22.19.0", "22.20.1", "24.0.0", "25.1.0"] {
      XCTAssertTrue(try accepts(range, accepted), "\(accepted) should satisfy \(range)")
    }
    for rejected in ["22.18.0", "22.0.0", "23.9.0", "24.0.0-rc.1"] {
      XCTAssertFalse(try accepts(range, rejected), "\(rejected) should not satisfy \(range)")
    }
  }

  // MARK: - Prerelease handling

  /// The prerelease rule this parser implements, stated as the table the compatibility audit
  /// relies on. Every row was measured against the running implementation, not derived from
  /// npm's text, because the audit's only obligation is a self-consistent user-facing answer.
  ///
  /// | range                   | candidate     | verdict     | why                                   |
  /// |-------------------------|---------------|-------------|---------------------------------------|
  /// | `>=0.1.0`               | `0.1.5-rc.2`  | in range    | the only comparator holds             |
  /// | `>=1.0.0`               | `1.0.0-rc.1`  | out of range| the only comparator fails             |
  /// | `^1.0.0`                | `1.5.0-rc.1`  | in range    | both comparators hold                 |
  /// | `>=0.1.4 <0.1.5`        | `0.1.5-rc.2`  | in range    | both hold: a prerelease ranks low      |
  /// | `>=0.1.5-rc.1 <0.1.6-0` | `0.1.5-rc.2`  | in range    | both hold, the ecosystem's own idiom  |
  /// | `<0.1.4`                | `0.1.5-rc.2`  | out of range| the only comparator fails             |
  /// | `=0.1.5`                | `0.1.5-rc.2`  | not judged  | the pin disagrees, so the branch does |
  func testPrereleaseTable() throws {
    let table: [(String, String, SemverRange.PrereleaseEligibility, Bool)] = [
      (">=0.1.0", "0.1.5-rc.2", .judgeable, true),
      (">=1.0.0", "1.0.0-rc.1", .judgeable, false),
      ("^1.0.0", "1.5.0-rc.1", .judgeable, true),
      (">=0.1.4 <0.1.5", "0.1.5-rc.2", .judgeable, true),
      (">=0.1.5-rc.1 <0.1.6-0", "0.1.5-rc.2", .judgeable, true),
      ("<0.1.4", "0.1.5-rc.2", .judgeable, false),
      ("=0.1.5", "0.1.5-rc.2", .notEligible, false),
    ]
    for (text, candidateText, expectedEligibility, expectedAccepts) in table {
      let range = try XCTUnwrap(SemverRange(text), text)
      let candidate = version(candidateText)
      XCTAssertEqual(range.eligibility(for: candidate), expectedEligibility,
                     "\(text) vs \(candidateText) eligibility")
      XCTAssertEqual(range.accepts(candidate), expectedAccepts,
                     "\(text) vs \(candidateText) accepts")
    }
  }

  /// A prerelease candidate below a range's floor is outside the range. The candidate is
  /// judged, so the audit reports a real failure rather than hiding behind "cannot judge" —
  /// which is the whole reason the prerelease exemption was given up.
  func testPrereleaseCandidateBelowTheFloorIsOutsideTheRange() throws {
    let range = try XCTUnwrap(SemverRange(">=0.2.0"))
    XCTAssertEqual(range.eligibility(for: version("0.1.5-rc.2")), .judgeable)
    XCTAssertFalse(range.accepts(version("0.1.5-rc.2")))
  }

  /// A prerelease candidate is eligible on the triple the branch names.
  func testPrereleaseCandidateIsAcceptedOnItsOwnTriple() throws {
    XCTAssertTrue(try accepts(">=0.1.5-rc.1", "0.1.5-rc.2"))
    XCTAssertTrue(try accepts("=0.1.5-rc.2", "0.1.5-rc.2"))
  }

  /// A bare version is a pin: it must not admit a neighbouring prerelease.
  func testBareVersionIsAPin() throws {
    XCTAssertTrue(try accepts("0.1.5", "0.1.5"))
    XCTAssertFalse(try accepts("0.1.5", "0.1.5-rc.2"), "a prerelease is below the release it precedes")
    XCTAssertFalse(try accepts("0.1.5", "0.1.6"))
  }

  /// Two-component endpoints with a prerelease are the reason `Semver` alone is not enough
  /// here: `Semver("0.1.6-0")` fails, but the range is real and must parse.
  func testTwoComponentPrereleaseEndpoint() throws {
    let parsed = try XCTUnwrap(SemverRange("<0.1.6-0"))
    XCTAssertTrue(parsed.accepts(version("0.1.5")))
    XCTAssertFalse(parsed.accepts(version("0.1.6")))
  }

  // MARK: - Wildcards

  func testWildcardConstrainNothing() throws {
    for text in ["*", "x", "X"] {
      let parsed = try XCTUnwrap(SemverRange(text), "\(text) should parse")
      XCTAssertTrue(parsed.isWildcard)
      XCTAssertTrue(parsed.accepts(version("0.0.1")))
      XCTAssertTrue(parsed.accepts(version("99.0.0-rc.1")))
    }
  }

  // MARK: - Refusal

  /// The heart of the anti-false-positive design: an unsupported form is not a pass.
  func testUnsupportedFormsAreRefusedRatherThanSatisfied() {
    for text in ["latest", "1.x", ">=1.0.0 <2.0.0 || nonsense", ">=", "", "   "] {
      XCTAssertNil(SemverRange(text), "\(text) must not parse")
    }
  }

  /// A union where *any* branch is unreadable is refused whole. Dropping the bad branch
  /// would let the understood half answer for the entire expression, which is the guess this
  /// design exists to prevent: the audit must say "undeclared", never a partial verdict.
  func testUnionWithOneUnreadableBranchIsRefused() {
    XCTAssertNil(SemverRange(">=1.0.0 || garbage"))
    XCTAssertNil(SemverRange("garbage || >=1.0.0"))
    XCTAssertNil(SemverRange(">=1.0.0 ||"))
  }

  /// An explicit `=` is a pin, exactly like a bare version — including for prereleases.
  func testExplicitEqualsIsAPin() throws {
    XCTAssertTrue(try accepts("=0.1.5", "0.1.5"))
    XCTAssertFalse(try accepts("=0.1.5", "0.1.6"))
    XCTAssertFalse(try accepts("=0.1.5", "0.1.5-rc.2"))
    XCTAssertTrue(try accepts("=0.1.5-rc.2", "0.1.5-rc.2"))
  }

}
