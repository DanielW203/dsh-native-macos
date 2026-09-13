import XCTest
@testable import HarnessConsoleUI
import HarnessRuntime

/// The plugin window's filter.
///
/// The list itself is a view, but the needle that decides what it shows is a plain
/// predicate — so it is the part of the merge that gets a test rather than a screenshot.
final class PluginFilterTests: XCTestCase {
  private let plugins = [
    PluginRecord(name: "@dsh/market", spec: "^1.2.0", isBundle: true, isEnabled: true),
    PluginRecord(name: "dsh-pocket", spec: "github:owner/dsh-pocket", isBundle: true, isEnabled: false),
    PluginRecord(name: "left-pad", spec: "file:../left-pad", isBundle: false, isEnabled: false),
  ]

  func testEmptyNeedleShowsEverything() {
    XCTAssertEqual(PluginFilter.visible(plugins, needle: "").map(\.name), plugins.map(\.name))
  }

  func testWhitespaceOnlyNeedleShowsEverything() {
    XCTAssertEqual(PluginFilter.visible(plugins, needle: "   ").map(\.name), plugins.map(\.name))
  }

  func testNeedleIsTrimmedBeforeMatching() {
    XCTAssertEqual(PluginFilter.visible(plugins, needle: "  pocket  ").map(\.name), ["dsh-pocket"])
  }

  func testMatchesNameCaseInsensitively() {
    XCTAssertEqual(PluginFilter.visible(plugins, needle: "DSH-").map(\.name), ["dsh-pocket"])
  }

  func testMatchesSpecifier() {
    // `github:` appears in one specifier and in no name.
    XCTAssertEqual(PluginFilter.visible(plugins, needle: "github:").map(\.name), ["dsh-pocket"])
  }

  func testScopedNameMatchesWithoutTheScope() {
    XCTAssertEqual(PluginFilter.visible(plugins, needle: "market").map(\.name), ["@dsh/market"])
  }

  func testNoMatchReturnsEmpty() {
    XCTAssertTrue(PluginFilter.visible(plugins, needle: "nothing-like-this").isEmpty)
  }
}
