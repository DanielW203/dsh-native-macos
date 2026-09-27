import Foundation

/// Resolves the entry point of an installed harness release.
///
/// A seam rather than a direct dependency on `HarnessInstaller`, for the reason every other
/// capability in this module is one: the interesting behaviour — what the app does when a
/// release's entry is missing or a probe times out — has to be testable without an installed
/// harness on the machine.
public protocol ReleaseEntryProviding: Sendable {
  /// The CLI entry point of one installed release, by ledger id.
  func entryURL(forReleaseID id: String) async throws -> URL
}

extension HarnessInstaller: ReleaseEntryProviding {
  /// The entry point of `id`, materialized or not.
  ///
  /// Deliberately does not consult the ledger: this is the *probe* path, and the question it
  /// answers — "would these plugins load under that release?" — is exactly the question a
  /// caller asks before the ledger has been told to switch to it.
  public func entryURL(forReleaseID id: String) async throws -> URL {
    let directory = paths.releaseDirectory(id)
    let manifest = directory.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
    let entry = directory.appendingPathComponent(ReleaseValidator.prebuiltEntry)
    // Two source kinds exist on disk (a prebuilt package and a built source checkout), so the
    // entry is chosen by what is actually there rather than by what the ledger says the
    // release's kind is. Getting this wrong is a probe that reports every plugin as broken.
    if FileManager.default.isReadableFile(atPath: entry.path) { return entry }
    let sourceEntry = directory.appendingPathComponent(ReleaseValidator.sourceEntry)
    if FileManager.default.isReadableFile(atPath: sourceEntry.path) { return sourceEntry }
    throw RuntimeError.archiveMissingEntry(
      "\(id) 里没有可用的入口（\(ReleaseValidator.prebuiltEntry) / \(ReleaseValidator.sourceEntry)）"
    )
  }
}

/// What a probe run found, and what it could not decide.
public struct PluginLoadProbeResult: Sendable, Equatable {
  /// Package name → the first line of the error importing it produced.
  ///
  /// Only ever filled for names the profile actually declares: a probe that reported a name
  /// the caller cannot disable would produce an instruction nobody can follow.
  public var unloadable: [String: String]
  /// Things the probe could not attribute — a timed-out batch, a check process that died, a
  /// release whose entry is missing. Kept separate from `unloadable` because "I could not
  /// tell" and "this plugin is broken" lead to different actions, and only the second one
  /// may disable anything.
  public var notes: [String]

  public init(unloadable: [String: String] = [:], notes: [String] = []) {
    self.unloadable = unloadable
    self.notes = notes
  }

  /// One line for the console or a report.
  public var summary: String {
    var parts: [String] = []
    if unloadable.isEmpty {
      parts.append("没有插件加载失败")
    } else {
      parts.append("\(unloadable.count) 个插件无法加载：\(unloadable.keys.sorted().joined(separator: ", "))")
    }
    parts.append(contentsOf: notes)
    return parts.joined(separator: "；")
  }
}

/// Loads a profile's plugins against a *specific* release, without activating it.
///
/// **Why not the declared ranges.** The existing audit reads what a plugin's manifest claims
/// and compares it to what the release ships. That is a good filter and a bad answer: on this
/// machine `dsh-memoir@0.7.0` declares `>=0.1.5-rc.1 <0.1.6-0`, so the audit called it
/// out-of-range — and the upgrade proceeded anyway, because a warning is not a decision. The
/// plugin the audit called *compatible* is the more dangerous case: a range says nothing about
/// whether the module still imports, and Node does not check ranges at load time.
///
/// This probe imports every declared package in a throwaway Node process run from the
/// profile's own directory, so the resolution a real boot would do is the resolution the probe
/// does. It runs against a release that is *not* active yet, which is what makes it possible
/// before the switch rather than after.
public struct PluginLoadProbe: Sendable {
  public let paths: RuntimePaths
  private let provider: ReleaseEntryProviding
  private let invoker: ProfileImporter

  public init(
    paths: RuntimePaths,
    provider: ReleaseEntryProviding,
    runner: ProcessRunning = ProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.paths = paths
    self.provider = provider
    self.invoker = ProfileImporter(
      paths: paths,
      entryProvider: {
        guard let active = try? InstallsIndex.load(from: paths.installsIndex).active else {
          throw RuntimeError.archiveMissingEntry("没有正在使用的版本，读不到入口")
        }
        return try await provider.entryURL(forReleaseID: active)
      },
      runner: runner,
      baseEnvironment: baseEnvironment,
      releaseProvider: provider
    )
  }

  /// How long one plugin may take to import before it is reported as undecided.
  ///
  /// A plugin that hangs is not a plugin that is broken, and the difference decides whether
  /// the user loses a feature — so a timeout goes to `notes`, never to `unloadable`.
  public static let perPluginTimeout: TimeInterval = 20

  /// Probe every plugin the profile declares against `releaseID`.
  public func probe(profile: String, releaseID: String) async -> PluginLoadProbeResult {
    let names: [String]
    do {
      names = try await invoker.declaredPluginNames(profile: profile)
    } catch {
      return PluginLoadProbeResult(notes: ["读不到 \(profile) 的插件清单：\(describe(error))"])
    }
    guard !names.isEmpty else {
      return PluginLoadProbeResult(notes: ["\(profile) 没有声明任何插件"])
    }

    let entry: URL
    do {
      entry = try await provider.entryURL(forReleaseID: releaseID)
    } catch {
      // A release that cannot be probed has not been called broken. Saying "cannot tell"
      // keeps the upgrade moving, which is the whole point of not trusting the audit.
      return PluginLoadProbeResult(notes: ["\(releaseID) 的入口不可用，跳过插件预检：\(describe(error))"])
    }

    var unloadable: [String: String] = [:]
    var notes: [String] = []
    for name in names {
      do {
        let failures = try await withTimeout(Self.perPluginTimeout, label: "\(releaseID) 下 import \(name)") {
          try await invoker.importFailures(profile: profile, names: [name], entry: entry)
        }
        for (key, reason) in failures {
          // The check process dying prints a sentinel instead of a package name; it is a
          // failure of the probe, not of a plugin.
          if key == name {
            unloadable[name] = reason
          } else {
            notes.append("\(releaseID) 下无法判定 \(name)：\(reason)")
          }
        }
      } catch {
        notes.append("\(releaseID) 下无法判定 \(name)：\(describe(error))")
      }
    }
    return PluginLoadProbeResult(unloadable: unloadable, notes: notes)
  }

  private func describe(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
      return description
    }
    return String(describing: error)
  }

  /// Run `body`, or give up after `seconds` and throw.
  ///
  /// A task group rather than an unstructured race: the loser is cancelled, and
  /// `ProcessRunner` stops its child on cancellation, so a plugin that hangs for a minute does
  /// not keep a Node process alive behind the probe.
  private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    label: String,
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await body() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw RuntimeError.unsupported("\(label) 超过 \(Int(seconds))s 没有结果")
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw RuntimeError.unsupported("\(label) 没有返回结果")
      }
      return first
    }
  }
}
