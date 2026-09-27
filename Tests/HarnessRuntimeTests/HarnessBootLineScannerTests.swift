import Foundation
import XCTest
@testable import HarnessRuntime

/// The boot-output parser, against the shapes this machine actually produced.
///
/// Every fixture line in here was copied out of `~/.nativeharness/harness/logs/window.log`
/// or a harness diagnostic — the 0.1.7 upgrade is the incident the parser exists for, and a
/// fixture invented from the shape's *documentation* would have missed the `dsh: ` prefix
/// that the window log adds to every line.
final class HarnessBootLineScannerTests: XCTestCase {
  private let known: Set<String> = [
    "dsh-memoir",
    "dsh-free-search",
    "dsh-pocket",
    "@sjhmars/pi-ai-thinking",
  ]

  // MARK: - The 0.1.7 skip

  func testReadsTheSkippedBundleAndItsPeerReason() {
    let line = #"dsh: skipping profile bundle "dsh-memoir": Error: Plugin dsh-memoir@0.7.0 is incompatible with dsh 0.1.7-rc.1: peerDependencies {"@deepseek-ai/dsh-llm":">=0.1.5-rc.1 <0.1.6-0"}. Running it may cause crashes or data loss."#

    let problems = HarnessBootLineScanner.scan(lines: [line], profile: "web", known: known)

    XCTAssertEqual(problems.map(\.kind), [.skippedBundle, .peerIncompatible])
    XCTAssertTrue(problems.allSatisfy { $0.name == "dsh-memoir" })
    XCTAssertTrue(problems.allSatisfy(\.isAttributed), "the bundle name is quoted by upstream; it is proof")
  }

  /// The shape that made a broken boot look healthy: two lines, and the first one names
  /// nobody.
  func testReadsTheCountLineAndTheEntryThatFailedToImport() {
    let lines = [
      "dsh: warning: 1 entry did not activate",
      "web-search-free (dsh-free-search): failed to import",
    ]

    let problems = HarnessBootLineScanner.scan(lines: lines, profile: "web", known: known)

    XCTAssertEqual(problems.count, 2)
    XCTAssertEqual(problems[0].name, "", "the count line blames nobody and must not invent a name")
    XCTAssertFalse(problems[0].isAttributed)
    XCTAssertEqual(problems[1].name, "dsh-free-search")
    XCTAssertEqual(problems[1].kind, .importFailed)
    XCTAssertTrue(problems[1].isAttributed)
  }

  // MARK: - The pre-0.1.7 shapes

  func testReadsALoaderEntryWithAStackFrameUnderTheProfile() {
    let lines = [
      #"Error: failed to apply loader entry dsh-pocket (dsh-pocket): cannot get property "webServer" without inject"#,
      "    at installPocketRpc (file:///Users/me/Library/Application%20Support/NativeHarness/home/profiles/web/node_modules/dsh-pocket/lib/web-rpc.js:33:29)",
    ]

    let problems = HarnessBootLineScanner.scan(lines: lines, profile: "web", known: known)

    XCTAssertEqual(problems.map(\.kind), [.loaderEntry, .importFailed])
    XCTAssertEqual(problems.map(\.name), ["dsh-pocket", "dsh-pocket"])
    XCTAssertTrue(problems.allSatisfy(\.isAttributed))
  }

  func testReadsAScopedPackageOutOfAStackFrame() {
    let line = "file:///x/home/profiles/web/node_modules/@sjhmars/pi-ai-thinking/lib/index.js:2"

    let problems = HarnessBootLineScanner.scan(lines: [line], profile: "web", known: known)

    XCTAssertEqual(problems.map(\.name), ["@sjhmars/pi-ai-thinking"])
  }

  // MARK: - Not blaming the innocent

  /// The one hard rule: a name that no profile path vouches for must never come back as
  /// *attributed*, because attribution is what licenses an automatic disable. It is still
  /// reported, and `pluginSuspects` — whose caller has already decided to repair a boot that
  /// will not come up — keeps it as a lead.
  func testDoesNotAttributeAPackageOnlyTheHarnessNames() {
    let lines = [
      "warmer (cache-warmer): failed to import",
      #"dsh: skipping profile bundle "not-installed": Error: Plugin not-installed@1.0.0 is incompatible with dsh 0.1.7-rc.1"#,
      // A frame from another profile names nobody at all, however much it looks like a path.
      "at file:///x/home/profiles/other/node_modules/dsh-pocket/lib/index.js:1",
    ]

    let problems = HarnessBootLineScanner.scan(lines: lines, profile: "web", known: known)

    XCTAssertEqual(problems.map(\.name).sorted(), ["cache-warmer", "not-installed", "not-installed"])
    XCTAssertTrue(problems.allSatisfy { !$0.isAttributed })
    XCTAssertEqual(
      HarnessBootHealth(isRunning: true, problems: problems).attributedPluginNames,
      [],
      "nothing here may be disabled by the preflight path, which requires attribution"
    )
    XCTAssertEqual(
      ProfileImporter.pluginSuspects(in: lines.joined(separator: "\n"), profile: "web", known: known),
      ["cache-warmer", "not-installed"]
    )
  }

  /// A plugin directory that is still under the profile but no longer declared is proof:
  /// the path is the profile's own tree. That is the drift case — removed from `bundles`,
  /// left on disk, still loaded.
  func testAPathUnderTheProfileIsProofEvenWhenNoLongerDeclared() {
    let problems = HarnessBootLineScanner.scan(
      lines: ["at file:///x/home/profiles/web/node_modules/left-behind/lib/index.js:1"],
      profile: "web",
      known: known
    )

    XCTAssertEqual(problems.map(\.name), ["left-behind"])
    XCTAssertTrue(problems[0].isAttributed)
    XCTAssertEqual(HarnessBootHealth(isRunning: true, problems: problems).attributedPluginNames, ["left-behind"])
  }

  /// The count line names nobody, and a bare count must never turn into a name.
  func testABareCountLineIsNeverTreatedAsAPluginName() {
    let line = "dsh: warning: 2 entries did not activate"

    let problems = HarnessBootLineScanner.scan(lines: [line], profile: "web", known: known)

    XCTAssertEqual(problems.map(\.name), [""])
    XCTAssertTrue(ProfileImporter.pluginSuspects(in: line, profile: "web", known: known).isEmpty)
  }

  /// The path parser is the pre-existing one, so its two old behaviours stay covered: a
  /// profile name that is not this boot's, and a name that only looks like a package path.
  func testIgnoresPathsFromAnotherProfile() {
    let line = "at file:///x/home/profiles/other/node_modules/dsh-pocket/lib/index.js:1"

    let problems = HarnessBootLineScanner.scan(lines: [line], profile: "web", known: known)

    XCTAssertTrue(problems.isEmpty)
  }

  func testDeduplicatesRepeatedLines() {
    let line = #"dsh: skipping profile bundle "dsh-memoir": Error: Plugin dsh-memoir@0.7.0 is incompatible with dsh 0.1.7-rc.1"#

    let problems = HarnessBootLineScanner.scan(
      lines: [line, line, line],
      profile: "web",
      known: known
    )

    // One skip and one peer finding, however many times the harness said it.
    XCTAssertEqual(problems.count, 2)
  }

  // MARK: - Verdicts

  func testVerdictDistinguishesRunningFromWorking() {
    let skip = #"dsh: skipping profile bundle "dsh-memoir": Error: Plugin dsh-memoir@0.7.0 is incompatible with dsh 0.1.7-rc.1"#

    let degraded = HarnessBootLineScanner.health(
      isRunning: true,
      lines: [skip],
      profile: "web",
      known: known
    )
    XCTAssertEqual(degraded.verdict, .degraded)
    XCTAssertFalse(degraded.bootedCleanly)
    XCTAssertEqual(degraded.attributedPluginNames, ["dsh-memoir"])
    XCTAssertTrue(degraded.summary.contains("dsh-memoir"))

    let healthy = HarnessBootLineScanner.health(
      isRunning: true,
      lines: ["dsh web: http://127.0.0.1:60014/?token=<redacted>", "Node 26.7.0 at /opt/homebrew/bin/node"],
      profile: "web",
      known: known
    )
    XCTAssertEqual(healthy.verdict, .healthy)
    XCTAssertTrue(healthy.bootedCleanly)
    XCTAssertTrue(healthy.problems.isEmpty)

    let failed = HarnessBootLineScanner.health(
      isRunning: false,
      lines: [],
      profile: "web",
      known: known
    )
    XCTAssertEqual(failed.verdict, .failed)
    XCTAssertTrue(failed.bootedCleanly, "it never printed anything about plugins")
  }

  /// The loader row id is not always a package name, so it is reported without proof — and
  /// `pluginSuspects` still keeps it as the last lead a failing boot left behind.
  func testKeepsAnUnmatchedLoaderEntryAsALeadButNotAsProof() {
    let line = "Error: failed to apply loader entry dsh-pocket-internal (dsh-pocket-internal): boom"

    let problems = HarnessBootLineScanner.scan(lines: [line], profile: "web", known: known)

    XCTAssertEqual(problems.map(\.kind), [.loaderEntry])
    XCTAssertFalse(problems[0].isAttributed)
    XCTAssertEqual(
      ProfileImporter.pluginSuspects(in: line, profile: "web", known: known),
      ["dsh-pocket-internal"],
      "the pre-0.1.7 behaviour is preserved: the row id is returned when nothing else is"
    )
  }
}
