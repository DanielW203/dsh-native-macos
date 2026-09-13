import XCTest
@testable import HarnessUI

/// The contract the extra windows depend on: one harness, one address, and never a stale
/// one. Getting this wrong is not a cosmetic bug — an extra window that keeps an address
/// after the server stopped shows a page that cannot work, and one that *starts* a server
/// is a second harness on one home.
@MainActor
final class HarnessPageHostTests: XCTestCase {
  func testAPublishedAddressBecomesTheWindowsURL() throws {
    let host = HarnessPageHost()

    host.update(url: "http://127.0.0.1:52373/?token=SECRET", isRunning: true)

    let url = try XCTUnwrap(host.url)
    XCTAssertEqual(url.host, "127.0.0.1")
    XCTAssertEqual(url.port, 52373)
    // The token is what authenticates the window, so it must survive the hop intact.
    XCTAssertEqual(url.query, "token=SECRET")
    XCTAssertTrue(host.isRunning)
  }

  func testAnAddressIsIgnoredWhileTheHarnessIsNotRunning() {
    let host = HarnessPageHost()

    host.update(url: "http://127.0.0.1:52373/?token=SECRET", isRunning: false)

    XCTAssertNil(host.url)
    XCTAssertFalse(host.isRunning)
  }

  func testStoppingClearsTheAddressTheWindowsWouldLoad() {
    let host = HarnessPageHost()
    host.update(url: "http://127.0.0.1:52373/?token=SECRET", isRunning: true)
    XCTAssertNotNil(host.url)

    // A stop leaves the window model's `url` in place while the server is down, which is
    // exactly the state that must not be mistaken for a loadable page.
    host.update(url: "http://127.0.0.1:52373/?token=SECRET", isRunning: false)

    XCTAssertNil(host.url)
    XCTAssertFalse(host.isRunning)
  }

  func testARunningHarnessWithNoAddressYetLeavesNothingToLoad() {
    let host = HarnessPageHost()

    // The window between "the phase says running" and "the URL was parsed" is real, and a
    // window opened inside it must wait rather than load something invented.
    host.update(url: nil, isRunning: true)

    XCTAssertNil(host.url)
    XCTAssertTrue(host.isRunning)
  }
}
