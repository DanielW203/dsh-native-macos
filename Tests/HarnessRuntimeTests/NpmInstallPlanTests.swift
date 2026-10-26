import Foundation
import XCTest
@testable import HarnessRuntime

final class NpmInstallPlanTests: XCTestCase {
  /// The shape npm 11.19 prints for `npm install --dry-run --json`: one diff line per package,
  /// then the document. Copied from a real run rather than invented, because the `add` lines
  /// before the JSON are exactly what a naive parser trips on.
  private static let dryRunOutput = """
  add @deepseek-ai/dsh 0.1.5-rc.1
  add alpha 1.0.0
  add @scope/beta 2.0.0
  add nested 3.0.0
  {
    "add": [
      {
        "name": "@deepseek-ai/dsh",
        "version": "0.1.5-rc.1",
        "path": "/private/tmp/staging/node_modules/@deepseek-ai/dsh"
      },
      {
        "name": "alpha",
        "version": "1.0.0",
        "path": "/private/tmp/staging/node_modules/alpha"
      },
      {
        "name": "@scope/beta",
        "version": "2.0.0",
        "path": "/private/tmp/staging/node_modules/@scope/beta"
      },
      {
        "name": "nested",
        "version": "3.0.0",
        "path": "/private/tmp/staging/node_modules/alpha/node_modules/nested"
      }
    ],
    "added": 4,
    "audited": 0,
    "change": [],
    "changed": 0,
    "funding": 0,
    "remove": [],
    "removed": 0
  }
  """

  func testParsesTheDryRunSummaryAfterNpmsDiffLines() throws {
    let plan = try XCTUnwrap(NpmInstallPlan.parse(Self.dryRunOutput))
    XCTAssertEqual(plan.totalCount, 3 + 1)
    XCTAssertEqual(plan.packages.map(\.name), ["@deepseek-ai/dsh", "alpha", "@scope/beta", "nested"])
    // Top level is the denominator the counter can observe: the nested duplicate lives under
    // another `node_modules` and is deliberately left out of it.
    XCTAssertEqual(plan.topLevelCount, 3)
  }

  func testEmptyOutputHasNoPlan() {
    XCTAssertNil(NpmInstallPlan.parse("npm ERR! network request failed"))
    XCTAssertNil(NpmInstallPlan.parse(""))
    XCTAssertNil(NpmInstallPlan.parse("{\"added\": 0}"))
    XCTAssertNil(NpmInstallPlan.parse("{\"add\": []}"))
    XCTAssertNil(NpmInstallPlan.parse("{\"add\": [{\"name\": \"alpha\"}]}"))
  }

  func testPathsWithoutNodeModulesAreNotTopLevel() {
    let output = """
    {"add": [{"name": "alpha", "version": "1.0.0", "path": "/tmp/checkout/alpha"}]}
    """
    let plan = NpmInstallPlan.parse(output)
    XCTAssertEqual(plan?.totalCount, 1)
    XCTAssertEqual(plan?.topLevelCount, 0)
  }

  // MARK: - Counting what npm has materialized

  func testCounterCountsTopLevelAndScopedPackages() throws {
    let root = try TestSupport.makeRoot(self)
    let modules = root.appendingPathComponent("node_modules", isDirectory: true)
    try TestSupport.write("{}", to: modules.appendingPathComponent("alpha/package.json"))
    try TestSupport.write("{}", to: modules.appendingPathComponent("@scope/beta/package.json"))
    try TestSupport.write("{}", to: modules.appendingPathComponent("@scope/gamma/package.json"))
    // Neither of these is a package the counter should report.
    try TestSupport.write("", to: modules.appendingPathComponent(".package-lock.json"))
    try TestSupport.write("{}", to: modules.appendingPathComponent("alpha/node_modules/nested/package.json"))

    XCTAssertEqual(NpmPackageCounter.materialized(inNodeModules: modules), 3)
  }

  func testCounterIsZeroWhenTheInstallHasNotWrittenAnything() throws {
    let root = try TestSupport.makeRoot(self)
    XCTAssertEqual(NpmPackageCounter.materialized(inNodeModules: root.appendingPathComponent("node_modules")), 0)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("node_modules", isDirectory: true),
      withIntermediateDirectories: true
    )
    XCTAssertEqual(NpmPackageCounter.materialized(inNodeModules: root.appendingPathComponent("node_modules")), 0)
  }
}
