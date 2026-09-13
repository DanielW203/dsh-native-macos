import Foundation

/// One of the three `Tools/build.sh` invocations a self-rebuild consists of.
///
/// The steps are named rather than free-form because the window shows which one is running,
/// and because the split is what makes the hand-off possible: `release` is the long, visible
/// one that runs inside the app, while `install` and `verify` have to happen after the app
/// is gone — they replace the very bundle it is running from.
public enum RebuildStep: String, Sendable, CaseIterable, Equatable {
  case release
  case install
  case verify

  /// The arguments handed to `Tools/build.sh`.
  ///
  /// `install --no-build` deliberately reuses the bundle `release` just produced instead of
  /// building a second one: a second build would be a different binary from the one the user
  /// watched succeed, and the whole point of the hand-off is that what gets installed is
  /// exactly what was just built.
  public var arguments: [String] {
    switch self {
    case .release: return ["release"]
    case .install: return ["install", "--no-build"]
    case .verify: return ["verify"]
    }
  }

  /// A one-line description for the progress window.
  public var title: String {
    switch self {
    case .release: return "编译 Release（Tools/build.sh release）"
    case .install: return "安装到启动台（Tools/build.sh install --no-build）"
    case .verify: return "校验安装（Tools/build.sh verify）"
    }
  }
}

/// Everything one self-rebuild needs: where the sources are, where the app goes, and the
/// three commands, as concrete shell text.
///
/// The shell text is produced by pure functions on purpose. The paths involved come from the
/// filesystem and end up on a command line that is executed as an installer with the user's
/// privileges, so the quoting is the part that has to be tested rather than eyeballed.
public struct SelfRebuild: Sendable {
  /// The scratch root `Tools/build.sh` defaults to. It lives outside the checkout because
  /// the checkout's own path contains non-ASCII characters on some machines, which breaks
  /// `swift-driver`; the script pins it for the same reason.
  public static let defaultScratchRoot = "/tmp/harness-native-build"
  public static let defaultAppName = "DSHNative.app"

  public let checkout: RebuildCheckout
  /// Where `install` puts the bundle — normally `~/Applications`, which is what Launchpad
  /// scans.
  public let installDirectory: URL
  public let appName: String
  /// Where the whole rebuild is logged. The hand-off appends to it after this process is
  /// gone, so a failed install is still diagnosable from the next launch.
  public let logURL: URL
  public let home: URL
  public let runner: any ProcessRunning

  public init(
    checkout: RebuildCheckout,
    installDirectory: URL? = nil,
    appName: String? = nil,
    logURL: URL? = nil,
    bundle: URL = Bundle.main.bundleURL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    runner: any ProcessRunning = ProcessRunner()
  ) {
    self.checkout = checkout
    self.home = home
    self.installDirectory = installDirectory ?? Self.installDirectory(bundle: bundle, home: home)
    self.appName = appName ?? Self.appName(bundle: bundle)
    self.logURL = logURL ?? Self.defaultLogURL(home: home)
    self.runner = runner
  }

  /// The bundle this rebuild will install and reopen.
  public var appURL: URL {
    installDirectory.appendingPathComponent(appName, isDirectory: true)
  }

  /// The visible, long step: build the app.
  public var releaseRequest: ProcessRequest {
    ProcessRequest(
      executable: URL(fileURLWithPath: "/bin/bash"),
      arguments: [checkout.buildScript.path, RebuildStep.release.arguments.joined(separator: " ")],
      environment: environment(),
      currentDirectory: checkout.root,
      label: "build.sh release"
    )
  }

  /// Run `release` to completion, streaming every line as it arrives.
  public func runRelease(
    onLine: (@Sendable (ProcessStream, String) -> Void)?
  ) async throws -> ProcessResult {
    try await runner.run(releaseRequest, onLine: onLine)
  }

  /// The environment the build needs that a Finder-launched app does not have.
  ///
  /// A window-server app inherits a minimal `PATH` — no Homebrew, and none of the Node this
  /// app provisions for itself — while `Tools/build.sh` shells out to `node` to regenerate
  /// the Xcode project. Passing the augmented `PATH` explicitly is what turns "works from a
  /// terminal" into "works from the button".
  public func environment(base: [String: String]? = nil) -> [String: String] {
    var environment = base ?? ProcessInfo.processInfo.environment
    if environment["HARNESS_ASCII_TMP"]?.isEmpty ?? true {
      environment["HARNESS_ASCII_TMP"] = Self.defaultScratchRoot
    }
    environment["PATH"] = Self.searchPath(home: home, inherited: environment["PATH"])
    return environment
  }

  /// `PATH` for a build: the app-managed Node first, then the usual tool locations, then
  /// whatever was inherited.
  ///
  /// Both possible homes of the app-managed Node are listed — the conventional
  /// `~/.nativeharness` and whatever `RuntimePaths` resolved to, which is the legacy
  /// Application Support tree on an un-migrated install. Whichever exists wins; the other is
  /// simply a directory that is not there.
  public static func searchPath(home: URL, inherited: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
    var entries: [String] = []
    let conventional = home.appendingPathComponent(RuntimePaths.directoryName, isDirectory: true)
    entries.append(conventional.appendingPathComponent("runtime/node/bin", isDirectory: true).path)
    if let standard = try? RuntimePaths.standard() {
      entries.append(standard.nodeDirectory.appendingPathComponent("bin", isDirectory: true).path)
      entries.append(standard.binDirectory.path)
    }
    entries.append(contentsOf: [
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ])
    if let inherited {
      entries.append(contentsOf: inherited.split(separator: ":").map(String.init))
    }
    var seen = Set<String>()
    return entries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
  }

  /// The app's own log, inside the tree this app owns.
  public static func defaultLogURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    let root = (try? RuntimePaths.standard())?.root
      ?? home.appendingPathComponent(RuntimePaths.directoryName, isDirectory: true)
    return root
      .appendingPathComponent("harness/logs", isDirectory: true)
      .appendingPathComponent("rebuild.log", isDirectory: false)
  }

  /// Where to install, derived from where the app is running now.
  ///
  /// The default is `~/Applications` — the destination `Tools/build.sh install` uses and the
  /// one Launchpad scans without administrator rights. An app already living in
  /// `/Applications` keeps living there, but only while that directory is writable: the
  /// alternative is a `sudo` prompt from a background script that has no terminal to ask on,
  /// which fails worse than installing a second copy in `~/Applications`.
  public static func installDirectory(
    bundle: URL = Bundle.main.bundleURL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) -> URL {
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let parent = bundle.deletingLastPathComponent().standardizedFileURL
    if parent == system.standardizedFileURL {
      return fileManager.isWritableFile(atPath: system.path) ? system : applications
    }
    if parent == applications.standardizedFileURL { return applications }
    return applications
  }

  /// The bundle name to install, taken from the bundle that is running.
  ///
  /// A preview, a test host, or `harnessctl` is not an `.app`; naming the product explicitly
  /// is the only honest answer there.
  public static func appName(bundle: URL = Bundle.main.bundleURL) -> String {
    let name = bundle.lastPathComponent
    return name.hasSuffix(".app") ? name : defaultAppName
  }

  /// The shell that finishes the job once this process is gone.
  ///
  /// Waiting on the pid is not politeness: `install` moves and replaces the bundle this
  /// process is executing from, and reopening the app before the old instance exits would
  /// race it for the harness's port. The wait is *bounded*, though, for the reason the
  /// whole hand-off exists: a build that succeeded must not be stranded behind an app that
  /// will not quit. Past the deadline the old process is killed and the install proceeds —
  /// killing it is exactly what gives `install` the quiet bundle it needs.
  ///
  /// The script opens the app whatever the install did — a failed install leaves the
  /// previous bundle in place, and a user staring at a window that never came back is a
  /// worse outcome than a user staring at the old version.
  ///
  /// The output redirect is wrapped around a *group* rather than `exec`ed. A redirection
  /// error from `exec` kills a non-interactive shell outright (it is a special built-in), and
  /// the last thing a rebuild may do is refuse to reopen the app because a log directory was
  /// not writable.
  ///
  /// - Parameters:
  ///   - pid: the app process that must exit before the bundle can be replaced.
  ///   - patience: seconds to wait for it before killing it.
  /// - Returns: a single line, ready for `/bin/sh -c`. It is one line on purpose — but it must
  ///   not *start* with `#`, because a comment on this line would swallow all of it.
  public func handoffScript(waitingFor pid: Int32, patience: TimeInterval = 10) -> String {
    let quote = Self.shellQuoted
    let logDirectory = logURL.deletingLastPathComponent().path
    let attempts = max(1, Int((patience / 0.2).rounded()))
    return [
      "i=0; while kill -0 \(pid) 2>/dev/null && [ \"$i\" -lt \(attempts) ]; do i=$((i + 1)); sleep 0.2; done",
      "mkdir -p \(quote(logDirectory))",
      "if kill -0 \(pid) 2>/dev/null; then echo \"[rebuild] $(date '+%Y-%m-%d %H:%M:%S') app pid \(pid) was still alive after \(Int(patience))s; killing it\" >> \(quote(logURL.path)); kill -9 \(pid) 2>/dev/null; j=0; while kill -0 \(pid) 2>/dev/null && [ \"$j\" -lt 10 ]; do j=$((j + 1)); sleep 0.2; done; fi",
      "{ echo \"[rebuild] $(date '+%Y-%m-%d %H:%M:%S') starting install (app pid \(pid) exited)\"",
      "export PATH=\(quote(Self.searchPath(home: home, inherited: nil)))",
      "export HARNESS_ASCII_TMP=\(quote(Self.defaultScratchRoot))",
      "cd \(quote(checkout.root.path)) || echo \"[rebuild] could not enter the checkout\"",
      "/bin/bash \(quote(checkout.buildScript.path)) install --no-build --to \(quote(installDirectory.path))",
      "install_status=$?",
      "echo \"[rebuild] install exit=$install_status\"",
      "/bin/bash \(quote(checkout.buildScript.path)) verify --to \(quote(installDirectory.path))",
      "verify_status=$?",
      "echo \"[rebuild] verify exit=$verify_status\"",
      "echo \"[rebuild] reopening \(appURL.path)\"",
      "} >> \(quote(logURL.path)) 2>&1",
      "/usr/bin/open -n \(quote(appURL.path))",
      "exit ${install_status:-1}",
    ].joined(separator: "; ")
  }

  /// Start the hand-off and return immediately.
  ///
  /// The child is deliberately not waited on and not tracked: this process is about to call
  /// `NSApp.terminate`, and a helper that dies with its parent would never finish the
  /// install. Its progress goes to the log file, not to a pipe nobody is left to read.
  @discardableResult
  public func scheduleHandoff(waitingFor pid: Int32) throws -> Int32 {
    try? FileManager.default.createDirectory(
      at: logURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", handoffScript(waitingFor: pid)]
    try process.run()
    return process.processIdentifier
  }

  /// Append already-collected output to the rebuild log.
  public func appendToLog(_ text: String) {
    guard !text.isEmpty else { return }
    let manager = FileManager.default
    try? manager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data(text.utf8)
    if let handle = try? FileHandle(forWritingTo: logURL) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: logURL, options: .atomic)
    }
  }

  /// Single-quote a value for `/bin/sh`.
  ///
  /// The POSIX rule: a single quote cannot appear inside single quotes, so it is closed,
  /// escaped outside them, and reopened. Every path in the hand-off script comes from the
  /// filesystem and can contain spaces or quotes.
  public static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
