import XCTest
@testable import HarnessRuntime

final class SemverTests: XCTestCase {
  func testParsesPlainAndPrefixedVersions() throws {
    XCTAssertEqual(try XCTUnwrap(Semver("1.2.3")).description, "1.2.3")
    XCTAssertEqual(try XCTUnwrap(Semver("v1.2.3")).description, "1.2.3")
    XCTAssertEqual(try XCTUnwrap(Semver("=1.2.3")).major, 1)
  }

  func testParsesPrereleaseAndBuildMetadata() throws {
    let parsed = try XCTUnwrap(Semver("0.1.5-rc.1+build.7"))
    XCTAssertEqual(parsed.prerelease, ["rc", "1"])
    XCTAssertEqual(parsed.build, "build.7")
    XCTAssertTrue(parsed.isPrerelease)
  }

  func testRejectsMalformedVersions() {
    XCTAssertNil(Semver(""))
    XCTAssertNil(Semver("abc"))
    XCTAssertNil(Semver("1.2"))
    XCTAssertNil(Semver("1.2.3.4"))
    XCTAssertNil(Semver("v1.x.3"))
    XCTAssertNil(Semver("1.2.3-"))
  }

  func testReleaseOutranksItsOwnPrerelease() throws {
    let rc = try XCTUnwrap(Semver("0.1.5-rc.1"))
    let release = try XCTUnwrap(Semver("0.1.5"))
    XCTAssertLessThan(rc, release)
  }

  func testPrereleaseIdentifiersCompareNumerically() throws {
    let first = try XCTUnwrap(Semver("0.1.5-rc.1"))
    let second = try XCTUnwrap(Semver("0.1.5-rc.2"))
    XCTAssertLessThan(first, second)

    // semver 2.0.0 rule 11.4.3: numeric identifiers rank below alphanumeric ones.
    let numeric = try XCTUnwrap(Semver("1.0.0-1"))
    let alpha = try XCTUnwrap(Semver("1.0.0-alpha"))
    XCTAssertLessThan(numeric, alpha)
  }

  func testBuildMetadataIsIgnoredForOrdering() throws {
    let a = try XCTUnwrap(Semver("1.0.0+build.1"))
    let b = try XCTUnwrap(Semver("1.0.0+build.2"))
    XCTAssertEqual(a, b)
    XCTAssertFalse(a < b)
    XCTAssertFalse(b < a)
  }

  func testNodeRequirementMatchesTheHarnessEngineRange() {
    // "^22.19.0 || >=24.0.0" — the range the shipped package declares.
    XCTAssertTrue(NodeRequirement.accepts("22.19.0"))
    XCTAssertTrue(NodeRequirement.accepts("22.22.0"))
    XCTAssertTrue(NodeRequirement.accepts("24.18.1"))
    XCTAssertTrue(NodeRequirement.accepts("26.7.0"))

    XCTAssertFalse(NodeRequirement.accepts("22.18.9"))
    XCTAssertFalse(NodeRequirement.accepts("20.11.0"))
    XCTAssertFalse(NodeRequirement.accepts("23.0.0"))
    XCTAssertFalse(NodeRequirement.accepts("not a version"))
  }
}
