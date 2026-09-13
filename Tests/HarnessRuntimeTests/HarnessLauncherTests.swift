import XCTest
@testable import HarnessRuntime

final class HarnessLauncherTests: XCTestCase {
  // MARK: - Command line

  func testLaunchArgumentsOmitTheWebSubcommand() {
    // Measured against the real CLI: "dsh --profile web web ..." is rejected with
    // "web takes none of parent --profile...", because a leading "web" is a subcommand
    // that already means --profile web.
    let arguments = HarnessLauncher.launchArguments(
      entry: URL(fileURLWithPath: "/opt/dsh/lib/bin.js"),
      profile: "web",
      host: "127.0.0.1",
      port: 39001
    )
    // Exactly one occurrence: the value of --profile, never a bare subcommand token.
    XCTAssertEqual(arguments.filter { $0 == "web" }.count, 1)
    XCTAssertEqual(Array(arguments.prefix(3)), ["/opt/dsh/lib/bin.js", "--profile", "web"])
    XCTAssertEqual(arguments, [
      "/opt/dsh/lib/bin.js",
      "--profile", "web",
      "--host", "127.0.0.1",
      "--port", "39001",
      "--no-open",
    ])
  }

  func testLaunchArgumentsKeepTheProfileBeforeTheAppArguments() {
    let arguments = HarnessLauncher.launchArguments(
      entry: URL(fileURLWithPath: "/opt/dsh/lib/bin.js"),
      profile: "rescue",
      host: "127.0.0.1",
      port: 3080
    )
    // Launcher flags must precede app arguments, or the launcher hands them to the app.
    let profileIndex = arguments.firstIndex(of: "--profile") ?? .max
    let hostIndex = arguments.firstIndex(of: "--host") ?? .min
    XCTAssertLessThan(profileIndex, hostIndex)
    XCTAssertTrue(arguments.contains("rescue"))
  }

  // MARK: - Readiness detection

  func testDetectsTheFullURLIncludingTheAccessToken() {
    // The real banner, captured from a live boot. The query string is required: the same
    // URL without it is answered with 401.
    let detector = URLDetector(host: "127.0.0.1", port: 39003)
    detector.observe("dsh web: http://127.0.0.1:39003/?token=Rp7q3idc9FgaCTInT3nP-42BcaeNe01")
    XCTAssertEqual(detector.url, "http://127.0.0.1:39003/?token=Rp7q3idc9FgaCTInT3nP-42BcaeNe01")
  }

  func testIgnoresAURLOnADifferentPort() {
    let detector = URLDetector(host: "127.0.0.1", port: 39003)
    detector.observe("some other service at http://127.0.0.1:8080/?token=abc")
    XCTAssertNil(detector.url)
  }

  func testIgnoresLinesWithoutAURL() {
    let detector = URLDetector(host: "127.0.0.1", port: 39003)
    detector.observe("dsh web: opening the default browser; pass --no-open to disable")
    detector.observe("")
    XCTAssertNil(detector.url)
  }

  func testFirstURLWins() {
    let detector = URLDetector(host: "127.0.0.1", port: 39003)
    detector.observe("dsh web: http://127.0.0.1:39003/?token=first")
    detector.observe("dsh web: http://127.0.0.1:39003/?token=second")
    XCTAssertEqual(detector.url, "http://127.0.0.1:39003/?token=first")
  }

  // MARK: - Port selection

  func testFreePortReturnsSomethingBindable() throws {
    let port = try HarnessLauncher.freePort()
    XCTAssertGreaterThan(port, 0)
    XCTAssertLessThan(port, 65536)
  }
}
