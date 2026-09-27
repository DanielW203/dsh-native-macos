import Foundation

/// One thing a boot printed that says a plugin did not make it.
///
/// A value, not a verdict: the scanner that produces it never decides whether the plugin is
/// at fault, because the two shapes it reads carry different amounts of proof. A name read
/// out of a package path under the profile's own `node_modules` is proof; a name read out of
/// `failed to apply loader entry dsh-pocket` is a loader row id that *usually* is the
/// package. `isAttributed` keeps that difference, so a caller that is about to disable
/// something (which is a destructive act, however reversible) can require proof while a
/// caller that is only reporting can show both.
public struct BootPluginProblem: Codable, Sendable, Equatable {
  /// Which shape in the output produced this problem.
  public enum Kind: String, Codable, Sendable, Equatable {
    /// `<id> (<name>): failed to import` — the entry did not even load.
    case importFailed
    /// `skipping profile bundle "<name>": … incompatible with dsh <version> …`
    case skippedBundle
    /// `failed to apply loader entry <id> (<id>): …`
    case loaderEntry
    /// The same skip, seen through its peer ranges.
    case peerIncompatible
  }

  /// The package name, when the line named one. Empty when it only held a loader row id.
  public var name: String
  public var kind: Kind
  /// Whether `name` is provably a package of this profile (from a path, a quoted bundle
  /// name, or a name the caller already knew) rather than a loader row id that merely looks
  /// like one.
  public var isAttributed: Bool
  /// The line itself, already redacted by the caller.
  public var line: String

  public init(name: String, kind: Kind, isAttributed: Bool, line: String) {
    self.name = name
    self.kind = kind
    self.isAttributed = isAttributed
    self.line = line
  }
}

/// What the app can say about a boot that has already produced a server.
///
/// The gap this exists for: a harness that is listening is not a harness that works. On
/// 0.1.7 the loader began *skipping* bundles it considers incompatible and booting anyway,
/// so every existing readiness signal — the process is alive, the URL was announced, the
/// endpoints answer — reports success while the user's plugins are quietly missing. That is
/// the state that used to cost fifteen minutes of hand-toggling, and it is not detectable
/// from the process state at all; only the output says it.
public struct HarnessBootHealth: Sendable, Equatable {
  public enum Verdict: String, Sendable, Equatable {
    /// The profile booted and the output names nothing that failed.
    case healthy
    /// A server is up, but something it printed says a plugin did not load.
    case degraded
    /// No server: the boot failed, timed out, or exited.
    case failed
  }

  public var isRunning: Bool
  public var problems: [BootPluginProblem]
  public var diagnostic: String?

  public init(isRunning: Bool, problems: [BootPluginProblem] = [], diagnostic: String? = nil) {
    self.isRunning = isRunning
    self.problems = problems
    self.diagnostic = diagnostic
  }

  public static let failed = HarnessBootHealth(isRunning: false)

  public var verdict: Verdict {
    if !isRunning { return .failed }
    return problems.isEmpty ? .healthy : .degraded
  }

  /// Whether the output said nothing at all about a plugin failing. Distinct from
  /// `verdict == .healthy`, which also requires a running server: a boot that failed before
  /// it printed anything about plugins never got the chance to disagree.
  public var bootedCleanly: Bool { problems.isEmpty }

  /// The names a caller may act on, i.e. the ones backed by proof. Deduplicated and sorted
  /// so a progress line or a report reads the same every time.
  public var attributedPluginNames: [String] {
    Array(Set(problems.filter(\.isAttributed).map(\.name).filter { !$0.isEmpty })).sorted()
  }

  /// Everything the output blamed, proof or not. For the interface, where showing a loader
  /// row id is still more useful than showing nothing.
  public var blamedNames: [String] {
    Array(Set(problems.map(\.name).filter { !$0.isEmpty })).sorted()
  }

  /// One line for a report or a banner.
  public var summary: String {
    switch verdict {
    case .healthy:
      return "启动输出没有插件加载问题"
    case .degraded:
      let names = blamedNames
      let listed = names.isEmpty ? "输出里有条目未激活" : names.joined(separator: ", ")
      return "\(problems.count) 处插件加载问题：\(listed)"
    case .failed:
      return diagnostic ?? "harness 没有启动"
    }
  }
}
