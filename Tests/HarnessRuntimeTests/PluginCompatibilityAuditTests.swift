import Foundation
import XCTest
@testable import HarnessRuntime

/// The compatibility verdict itself.
///
/// The inputs are the manifests of the seven plugins actually installed on this machine, with
/// the harness version this machine runs (`0.1.5-rc.2`). That choice is the point: the audit's
/// failure mode is not "crashes on a fixture" but "tells the user a working plugin is broken",
/// and only real manifests can show whether that happens.
///
/// The asymmetry being tested throughout: a wrong `incompatible` costs the user a working
/// plugin, so every uncertain case must come back `undeclared`.
final class PluginCompatibilityAuditTests: XCTestCase {
  private let harness = "0.1.5-rc.2"

  /// The versions `0.1.5-rc.2` ships for the packages the real plugins reference.
  private let bundled = [
    "@deepseek-ai/dsh-llm": "0.1.5-rc.2",
    "@deepseek-ai/dsh-tools": "0.1.5-rc.2",
    "@deepseek-ai/dsh-settings": "0.1.5-rc.2",
  ]

  private func record(
    _ name: String,
    engines: String? = nil,
    peers: [String: String] = [:],
    hasBundlePatch: Bool = true,
    clientPlatform: String? = "web"
  ) -> PluginRecord {
    PluginRecord(
      name: name,
      spec: "1.0.0",
      installedVersion: "1.0.0",
      isBundle: hasBundlePatch,
      isEnabled: true,
      enginesRange: engines,
      hasBundlePatch: hasBundlePatch,
      clientPlatform: clientPlatform,
      dshPeerRanges: peers
    )
  }

  private func audit(_ records: [PluginRecord], shadowed: [String: [String]] = [:]) -> [PluginCompatibility] {
    PluginCompatibilityAudit.audit(
      records: records,
      harnessVersion: harness,
      bundledVersions: bundled,
      shadowed: shadowed
    )
  }

  // MARK: - The real installed set

  /// `dsh-memoir` is the only installed plugin whose claims are judgeable, and they hold:
  /// `>=0.1.5-rc.1 <0.1.6-0` contains `0.1.5-rc.2` even though the upper bound names the
  /// *next* triple. If this test ever fails, the audit has started crying wolf.
  func testMemoirIsCompatibleWithTheInstalledHarness() {
    let memoir = record(
      "dsh-memoir",
      engines: ">=0.1.5-rc.1 <0.1.6-0",
      peers: [
        "@deepseek-ai/dsh-llm": ">=0.1.5-rc.1 <0.1.6-0",
        "@deepseek-ai/dsh-tools": ">=0.1.5-rc.1 <0.1.6-0",
      ]
    )
    XCTAssertEqual(audit([memoir]).first?.verdict, .compatible)
  }

  /// `dsh-free-search` declares only a floor, with a prerelease.
  func testFreeSearchIsCompatible() {
    let freeSearch = record(
      "dsh-free-search",
      engines: ">=0.1.1-rc.1",
      peers: [
        "@deepseek-ai/dsh-settings": ">=0.1.0-rc.6",
        "@deepseek-ai/dsh-tools": ">=0.1.0-rc.6",
      ]
    )
    XCTAssertEqual(audit([freeSearch]).first?.verdict, .compatible)
  }

  /// Five of the seven installed plugins declare nothing checkable. They must read as
  /// `undeclared` — not compatible, not broken.
  func testPluginsWithNoDeclarationAreUndeclared() {
    let silent = [
      record("dsh-skin-manager", clientPlatform: "web"),
      record("dsh-token-optimizer"),
      record("dshmarket"),
      record("dsh-pocket"),
      record("@tt-a1i/archify-dsh", clientPlatform: nil),
    ]
    for compatibility in audit(silent) {
      XCTAssertEqual(compatibility.verdict, .undeclared, compatibility.record.name)
      XCTAssertFalse(compatibility.isUnjudged, "silence is not the same as an unreadable version")
    }
  }

  // MARK: - Real breakage

  /// A one-sided range that the harness plainly fails. One-sided matters: a two-sided range can
  /// reach the ambiguous "cannot tell" state, and a test that expects a failure must not sit on
  /// that boundary.
  func testEnginesRangeBelowTheHarnessIsIncompatible() {
    let old = record("legacy-plugin", engines: ">=1.0.0")
    guard case .incompatible(let violations) = audit([old]).first?.verdict else {
      return XCTFail("a range that excludes the harness must be incompatible")
    }
    XCTAssertEqual(violations.count, 1)
    XCTAssertEqual(violations[0].basis, .engines)
    XCTAssertEqual(violations[0].subject, "dsh")
    XCTAssertEqual(violations[0].declared, ">=1.0.0")
    XCTAssertEqual(violations[0].actual, harness)
  }

  /// A peer pinned to a package version the release does not ship is the case `dsh.engines`
  /// cannot see: the plugin's own claim is fine, but the package it builds against moved.
  func testPeerOutsideTheShippedVersionIsIncompatible() {
    let plugin = record("peer-mismatch", peers: ["@deepseek-ai/dsh-tools": ">=0.2.0"])
    guard case .incompatible(let violations) = audit([plugin]).first?.verdict else {
      return XCTFail("a peer range that excludes the shipped version must be incompatible")
    }
    XCTAssertEqual(violations.map(\.basis), [.peerDependency])
    XCTAssertEqual(violations[0].subject, "@deepseek-ai/dsh-tools")
    XCTAssertEqual(violations[0].actual, "0.1.5-rc.2")
  }

  func testBothBasesCanFailAtOnce() {
    let plugin = record(
      "doubly-old",
      engines: "<0.1.0",
      peers: ["@deepseek-ai/dsh-tools": ">=0.2.0"]
    )
    guard case .incompatible(let violations) = audit([plugin]).first?.verdict else {
      return XCTFail("expected incompatible")
    }
    XCTAssertEqual(violations.map(\.basis), [.engines, .peerDependency])
  }

  /// A private copy inside the plugin is reported even when the declared range looks fine:
  /// the range is what the author asked for, the nested copy is what actually loaded.
  func testShadowedPackageIsReportedWithThePeerAsItsRange() {
    let plugin = record("shady", peers: ["@deepseek-ai/dsh-tools": ">=0.1.5-rc.1 <0.1.6-0"])
    guard case .incompatible(let violations) = audit(
      [plugin], shadowed: ["shady": ["@deepseek-ai/dsh-tools"]]
    ).first?.verdict else {
      return XCTFail("a nested harness copy must be reported")
    }
    XCTAssertEqual(violations.map(\.basis), [.versionShadow])
    XCTAssertEqual(violations[0].declared, ">=0.1.5-rc.1 <0.1.6-0")
    XCTAssertEqual(violations[0].actual, "0.1.5-rc.2")
  }

  /// A shadowed package with no declared peer range still reports, because the copy on disk is
  /// evidence independent of any manifest.
  func testShadowWithoutADeclaredRangeStillReports() {
    let plugin = record("shady", peers: [:])
    guard case .incompatible(let violations) = audit(
      [plugin], shadowed: ["shady": ["@deepseek-ai/dsh-tools"]]
    ).first?.verdict else {
      return XCTFail("expected incompatible")
    }
    XCTAssertEqual(violations[0].basis, .versionShadow)
    XCTAssertEqual(violations[0].declared, "no declared range")
  }

  // MARK: - The uncertain cases that must NOT be called broken

  /// A range this parser does not understand is "undeclared", never a violation. This is the
  /// single most important assertion in the file: it is what keeps an unknown future syntax
  /// from telling users to uninstall working plugins.
  func testUnparseableRangeIsUndeclaredNotIncompatible() {
    let plugin = record("future-syntax", engines: "workspace:*", peers: ["@deepseek-ai/dsh-tools": "latest-ish"])
    let compatibility = audit([plugin]).first
    XCTAssertEqual(compatibility?.verdict, .undeclared)
    XCTAssertTrue(compatibility?.isUnjudged ?? false)
  }

  /// A prerelease harness against ranges that only name releases.
  ///
  /// Four sub-cases with different correct answers, and the audit has to tell them apart:
  /// a bare floor is *satisfied*, a bare ceiling is *violated*, and a two-sided range whose
  /// comparators disagree must degrade to "unjudged" rather than to either verdict.
  func testPrereleaseHarnessAgainstReleaseOnlyRanges() {
    let floor = audit([record("release-floor", engines: ">=0.1.0")]).first
    XCTAssertEqual(floor?.verdict, .compatible, "a floor below the candidate cannot exclude it")

    let ceiling = audit([record("release-ceiling", engines: "<0.1.4")]).first
    guard case .incompatible(let ceilingViolations) = ceiling?.verdict else {
      return XCTFail("a ceiling below the candidate plainly excludes it")
    }
    XCTAssertEqual(ceilingViolations.map(\.basis), [.engines])

    // Two-sided and disagreeing: the floor holds while the ceiling fails. Silence is the
    // honest answer because the failure may only be an artifact of prerelease ordering.
    let narrow = audit([record("narrow", engines: ">=0.1.0 <0.1.4")]).first
    XCTAssertEqual(narrow?.verdict, .undeclared)
    XCTAssertTrue(narrow?.isUnjudged ?? false)

    // Not every two-sided range is ambiguous: `>=0.1.4 <0.1.5` agrees about `0.1.5-rc.2` —
    // above the floor, and below the ceiling because a prerelease ranks below its release — so
    // it is judged, and judged in range.
    let bracket = audit([record("bracket", engines: ">=0.1.4 <0.1.5")]).first
    XCTAssertEqual(bracket?.verdict, .compatible)

    // Two-sided and agreeing: the ecosystem's own idiom names the candidate's triple, so the
    // judgement is made and it is a pass.
    let explicit = audit([record("explicit", engines: ">=0.1.5-rc.1 <0.1.6-0")]).first
    XCTAssertEqual(explicit?.verdict, .compatible)
  }

  /// That rule must not hide a real failure: a prerelease floor above the harness still fails.
  func testPrereleaseRangeThatExcludesTheHarnessStillFails() {
    let plugin = record("rc-range", engines: ">=0.1.5-rc.3")
    guard case .incompatible(let violations) = audit([plugin]).first?.verdict else {
      return XCTFail("0.1.5-rc.3 is above 0.1.5-rc.2 and must fail")
    }
    XCTAssertEqual(violations[0].basis, .engines)
  }

  /// A one-sided range is never ambiguous, so a prerelease harness the range excludes is
  /// reported rather than hidden behind "cannot tell".
  func testCeilingAloneStillReportsThePrereleaseHarness() {
    let plugin = record("old-ceiling", engines: "<0.1.4")
    guard case .incompatible(let violations) = audit([plugin]).first?.verdict else {
      return XCTFail("0.1.5-rc.2 is above 0.1.4 and must fail")
    }
    XCTAssertEqual(violations[0].basis, .engines)
  }

  /// Without a known harness version the engines claim cannot be judged, but a peer claim
  /// still can — the two have different data sources on purpose.
  func testMissingHarnessVersionLeavesEnginesUnjudgedButPeersJudged() {
    let plugin = record("mixed", engines: ">=0.1.5-rc.1", peers: ["@deepseek-ai/dsh-tools": ">=0.2.0"])
    let compatibility = PluginCompatibilityAudit.audit(
      records: [plugin], harnessVersion: nil, bundledVersions: bundled
    ).first
    guard case .incompatible(let violations) = compatibility?.verdict else {
      return XCTFail("the peer claim is still judgeable")
    }
    XCTAssertEqual(violations.map(\.basis), [.peerDependency])
  }

  /// A peer the release does not contain cannot be judged — an absent version is not a zero.
  func testPeerAbsentFromTheReleaseIsUnjudged() {
    let plugin = record("unknown-peer", peers: ["@deepseek-ai/dsh-nonexistent": ">=0.1.0"])
    XCTAssertEqual(audit([plugin]).first?.verdict, .undeclared)
  }

  /// A wildcard claim is a readable claim that always holds, not silence.
  func testWildcardEnginesCountsAsCompatible() {
    XCTAssertEqual(audit([record("any", engines: "*")]).first?.verdict, .compatible)
  }

  // MARK: - Shape of the result

  func testAuditPreservesInputOrderAndIdentity() {
    let records = [record("b"), record("a"), record("c")]
    XCTAssertEqual(audit(records).map(\.id), ["b", "a", "c"],
                   "the list is the caller's order; sorting is a UI decision")
  }

  func testSummaryNamesTheFirstViolation() {
    let plugin = record("legacy", engines: ">=1.0.0")
    let compatibility = audit([plugin])[0]
    let summary = PluginCompatibilityAudit.summary(for: compatibility)
    XCTAssertTrue(summary.contains("out of range"), summary)
    XCTAssertTrue(summary.contains("1.0.0"), summary)

    XCTAssertEqual(PluginCompatibilityAudit.summary(for: audit([record("silent")])[0]),
                   "no version declared")
    XCTAssertEqual(PluginCompatibilityAudit.summary(for: audit([record("ok", engines: "*")])[0]),
                   "compatible")
  }

  func testSummaryCountsMultipleFindings() {
    let plugin = record("doubly-old", engines: ">=1.0.0", peers: ["@deepseek-ai/dsh-tools": ">=0.2.0"])
    let summary = PluginCompatibilityAudit.summary(for: audit([plugin])[0])
    XCTAssertTrue(summary.contains("2 findings"), summary)
  }
}
