import Foundation

/// A `harness-native` source checkout the running app can rebuild itself from.
///
/// The installed app is a bundle: nothing in its ordinary runtime says where the sources it
/// was built from live, because `Tools/build.sh` only knows `$ROOT` while it runs. A
/// self-rebuild therefore has to *find* the checkout — and it has to do so on a machine
/// whose layout nobody promised. The lookup below is deliberately layered: the exact
/// answers first (what the user picked, the environment, the marker `install` writes into
/// the app's own runtime tree), then a bounded search of the places a checkout is usually
/// kept, then Spotlight.
public struct RebuildCheckout: Sendable, Equatable {
  /// The directory that holds `Tools/build.sh`, `Package.swift`, and the Xcode project.
  public let root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  public var buildScript: URL {
    root.appendingPathComponent("Tools/build.sh", isDirectory: false)
  }

  public var project: URL {
    root.appendingPathComponent("NativeHarness.xcodeproj", isDirectory: true)
  }

  public var manifest: URL {
    root.appendingPathComponent("Package.swift", isDirectory: false)
  }

  /// Whether `directory` is a checkout this app can actually build from.
  ///
  /// The marker is `Tools/build.sh` plus *one* of the two project descriptions. Checking for
  /// the project directory alone would accept a stray folder someone named the same way;
  /// checking for `build.sh` alone would accept any repository that happens to have one.
  public static func looksLikeCheckout(
    _ directory: URL,
    fileManager: FileManager = .default
  ) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(
      atPath: directory.appendingPathComponent("Tools/build.sh").path,
      isDirectory: &isDirectory
    ), !isDirectory.boolValue else {
      return false
    }
    return fileManager.fileExists(
      atPath: directory.appendingPathComponent("NativeHarness.xcodeproj").path
    ) || fileManager.fileExists(
      atPath: directory.appendingPathComponent("Package.swift").path
    )
  }
}

/// Finds the checkout a self-rebuild should run in.
///
/// Every source of truth is injectable so the ordering — which is the behaviour that
/// matters — is covered by tests without a real home directory or a real `mdfind`.
public enum RebuildCheckoutLocator {
  /// Where a checkout the user picked by hand is remembered.
  ///
  /// A user default rather than a file this app owns: the choice is a preference about this
  /// machine, and it should travel with the app's other preferences.
  public static let defaultsKey = "NativeHarness.rebuildSourceRoot"

  /// An override for a launcher, a test, or a shell (`open -a` cannot set it, but a script
  /// that starts the app with `env` can).
  public static let environmentKey = "NATIVE_HARNESS_SOURCE_ROOT"

  /// The file `Tools/build.sh install` writes, holding the checkout that produced the
  /// installed bundle. It is what makes a second Mac work with no configuration at all: the
  /// app was installed from *that* Mac's checkout, and the install recorded which one.
  public static let markerFileName = "rebuild-source-root"

  /// The lookup order: remembered choice, environment, install marker, local search,
  /// Spotlight.
  ///
  /// - Parameters:
  ///   - userDefaultsRoot: the remembered checkout, if any.
  ///   - environment: the process environment.
  ///   - markerRoots: directories that may hold the install marker (the app's runtime root
  ///     and the conventional `~/.nativeharness`).
  ///   - home: the user's home directory.
  ///   - searchRoots: an explicit search plan; `nil` uses the usual places.
  ///   - maxDepth: how deep the search descends below each root.
  ///   - spotlight: whether to fall back to Spotlight when everything else missed. Off in
  ///     tests, which must not depend on the machine's index.
  public static func locate(
    userDefaultsRoot: String? = UserDefaults.standard.string(forKey: defaultsKey),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    markerRoots: [URL]? = nil,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    searchRoots: [(url: URL, depth: Int)]? = nil,
    maxDepth: Int = 2,
    spotlight: Bool = true,
    fileManager: FileManager = .default
  ) -> RebuildCheckout? {
    var candidates: [URL] = []

    if let remembered = userDefaultsRoot, !remembered.isEmpty {
      candidates.append(URL(fileURLWithPath: remembered, isDirectory: true))
    }
    if let override = environment[environmentKey], !override.isEmpty {
      candidates.append(URL(fileURLWithPath: override, isDirectory: true))
    }
    let markers = markerRoots ?? defaultMarkerRoots(home: home)
    for markerRoot in markers {
      if let value = markerValue(at: markerRoot.appendingPathComponent(markerFileName, isDirectory: false)) {
        candidates.append(URL(fileURLWithPath: value, isDirectory: true))
      }
    }

    for candidate in candidates {
      if RebuildCheckout.looksLikeCheckout(candidate, fileManager: fileManager) {
        return RebuildCheckout(root: candidate)
      }
    }

    let plan = searchRoots ?? defaultSearchPlan(home: home, maxDepth: maxDepth)
    for candidate in search(plan, fileManager: fileManager) {
      if RebuildCheckout.looksLikeCheckout(candidate, fileManager: fileManager) {
        return RebuildCheckout(root: candidate)
      }
    }

    if spotlight {
      for candidate in spotlightCandidates() {
        if RebuildCheckout.looksLikeCheckout(candidate, fileManager: fileManager) {
          return RebuildCheckout(root: candidate)
        }
      }
    }
    return nil
  }

  /// Remember a checkout the user chose by hand.
  public static func remember(_ root: URL, defaults: UserDefaults = .standard) {
    defaults.set(root.standardizedFileURL.path, forKey: defaultsKey)
  }

  /// The trimmed contents of the install marker, or `nil` when it is absent or empty.
  public static func markerValue(at url: URL) -> String? {
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The directories that may hold the install marker.
  ///
  /// Two entries on purpose: `RuntimePaths` is the authority on this app's tree (it honors
  /// the legacy Application Support root), while `~/.nativeharness` is where the build
  /// script writes without linking against the app's own resolution logic.
  public static func defaultMarkerRoots(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [URL] {
    var roots: [URL] = []
    if let standard = try? RuntimePaths.standard() {
      roots.append(standard.root)
    }
    let conventional = home.appendingPathComponent(RuntimePaths.directoryName, isDirectory: true)
    if !roots.contains(where: { $0.standardizedFileURL == conventional.standardizedFileURL }) {
      roots.append(conventional)
    }
    return roots
  }

  /// The usual places a checkout is kept, with the depth each one deserves.
  ///
  /// `home` itself is searched one level deep — a checkout directly in `~` is common, and
  /// walking two levels of everything under `~` is not. Directories whose names are already
  /// banned by ``skipNames`` (`Library`, `Applications`, …) do the rest.
  public static func defaultSearchPlan(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    maxDepth: Int = 2
  ) -> [(url: URL, depth: Int)] {
    [
      (home, 1),
      (home.appendingPathComponent("Documents", isDirectory: true), maxDepth),
      (home.appendingPathComponent("Developer", isDirectory: true), maxDepth),
      (home.appendingPathComponent("Developer/Projects", isDirectory: true), maxDepth),
      (home.appendingPathComponent("src", isDirectory: true), maxDepth),
      (home.appendingPathComponent("Sources", isDirectory: true), maxDepth),
      (home.appendingPathComponent("Projects", isDirectory: true), maxDepth),
      (home.appendingPathComponent("code", isDirectory: true), maxDepth),
      (home.appendingPathComponent("Code", isDirectory: true), maxDepth),
      (home.appendingPathComponent("Desktop", isDirectory: true), maxDepth),
      (home.appendingPathComponent("Downloads", isDirectory: true), maxDepth),
      (URL(fileURLWithPath: "/Users/Shared", isDirectory: true), maxDepth),
    ]
  }

  /// Directory names a checkout search never descends into.
  ///
  /// Hidden directories are skipped separately. These are the visible ones that are either
  /// huge, not source, or both.
  static let skipNames: Set<String> = [
    "Library", "Applications", "Movies", "Music", "Pictures", "Public",
    "node_modules", "DerivedData", "Pods", "build", "Build", "Vendor",
  ]

  /// Breadth-first walk of the search plan, capped so a pathological tree cannot hang the
  /// window.
  static func search(_ plan: [(url: URL, depth: Int)], fileManager: FileManager = .default) -> [URL] {
    var found: [URL] = []
    var visited = 0
    for entry in plan {
      var queue: [(url: URL, depth: Int)] = [(entry.url, 0)]
      while !queue.isEmpty {
        let (directory, depth) = queue.removeFirst()
        visited += 1
        if visited > 4000 { return found }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { continue }
        found.append(directory)
        guard depth < entry.depth else { continue }
        guard let children = try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsPackageDescendants]
        ) else { continue }
        for child in children {
          let name = child.lastPathComponent
          if name.hasPrefix(".") || skipNames.contains(name) { continue }
          var childIsDirectory: ObjCBool = false
          guard fileManager.fileExists(atPath: child.path, isDirectory: &childIsDirectory),
                childIsDirectory.boolValue else { continue }
          // A bundle is never a checkout, and descending into one can be slow.
          if name.hasSuffix(".app") || name.hasSuffix(".xcodeproj") { continue }
          queue.append((child, depth + 1))
        }
      }
    }
    return found
  }

  /// Spotlight as a last resort: it knows about checkouts this app's search plan never
  /// guessed, wherever they are on the machine.
  ///
  /// `mdfind` is killed at the deadline rather than waited on: a hung Spotlight query must
  /// degrade to "not found here" instead of freezing the window that asked.
  public static func spotlightCandidates(timeout: TimeInterval = 6) -> [URL] {
    let executable = URL(fileURLWithPath: "/usr/bin/mdfind")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return [] }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["-name", "NativeHarness.xcodeproj"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return []
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      usleep(50_000)
    }
    if process.isRunning {
      process.terminate()
      usleep(200_000)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      return []
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)
    var seen = Set<String>()
    var candidates: [URL] = []
    for line in output.split(separator: "\n") {
      let path = line.trimmingCharacters(in: .whitespaces)
      guard !path.isEmpty else { continue }
      let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
      guard seen.insert(parent.path).inserted else { continue }
      candidates.append(parent)
    }
    return candidates
  }
}
