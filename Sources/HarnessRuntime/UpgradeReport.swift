import Foundation

/// One thing the app checked about a freshly booted harness.
///
/// A check is app-side by construction: every one of them either reads the running harness
/// over the API it already speaks, reads the harness's files the way route B already does, or
/// audits a value it already holds. None of them asks a model, which is what makes the result
/// reproducible enough to auto-roll-back on.
public protocol HarnessCheck: Sendable {
  /// Stable identifier, used as the report row's key and in assertions.
  var name: String { get }
  /// Whether a failure here is reason enough to abandon the new release.
  ///
  /// Only checks that answer "can this harness serve the app at all" set this. Everything
  /// that *could* be a transient hiccup does not, because a wrong rollback costs the user a
  /// working upgrade.
  var isBlocking: Bool { get }
  func run() async -> HarnessCheckResult
}

/// What one check concluded.
public struct HarnessCheckResult: Codable, Sendable, Equatable, Identifiable {
  /// Four verdicts, not two, because the interesting case is the third.
  ///
  /// `skipped` is "there was nothing to check" (no session exists to page), and `warn` is
  /// "this did not work, and that is not proof the release is bad". Collapsing either into
  /// `fail` would make a quiet, healthy machine look broken; collapsing `warn` into `pass`
  /// would hide exactly the silent breakage this whole feature exists to catch.
  public enum Verdict: String, Codable, Sendable, Equatable, CaseIterable {
    case pass
    case warn
    case fail
    case skipped

    public var displayName: String {
      switch self {
      case .pass: return "正常"
      case .warn: return "降级"
      case .fail: return "失败"
      case .skipped: return "跳过"
      }
    }
  }

  public var name: String
  public var verdict: Verdict
  public var detail: String
  /// Whether a `fail` here should have rolled the upgrade back. Carried on the result so a
  /// stored report explains its own outcome instead of needing the check objects that
  /// produced it.
  public var isBlocking: Bool

  public var id: String { name }

  public init(name: String, verdict: Verdict, detail: String, isBlocking: Bool) {
    self.name = name
    self.verdict = verdict
    self.detail = detail
    self.isBlocking = isBlocking
  }
}

/// The outcome of one upgrade attempt, as stored and as shown.
public struct UpgradeReport: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public enum Outcome: String, Codable, Sendable, Equatable {
    /// The new release boots and passed every blocking check; it is now active.
    case kept
    /// The new release was abandoned and the previous one is running again.
    case rolledBack
    /// Nothing was changed, or the rollback could not be completed. Either way the app did
    /// not reach a state it is willing to call good, and the marker is left in place.
    case aborted

    public var displayName: String {
      switch self {
      case .kept: return "已更新"
      case .rolledBack: return "已回退"
      case .aborted: return "未完成"
      }
    }
  }

  public var schemaVersion: Int
  /// The release that was active before this attempt, when it was known.
  public var fromReleaseID: String?
  /// The release this attempt was moving to.
  public var toReleaseID: String
  /// Where a rollback landed. Set only when a rollback completed.
  public var rolledBackTo: String?
  public var finishedAt: Date
  public var outcome: Outcome
  /// One line for the console and the window's failure panel. Never the raw process dump.
  public var summary: String
  /// The new release's own output when it failed to boot — kept verbatim because it is the
  /// only thing that explains *why*, and paraphrasing it would lose the stack.
  public var bootFailure: String?
  /// The checks that ran, in order. Empty when the boot failed before any could run.
  public var checks: [HarnessCheckResult]
  /// Extra context that does not belong in `summary` — a second failure, a cleared marker.
  public var notes: [String]

  public init(
    schemaVersion: Int = UpgradeReport.currentSchemaVersion,
    fromReleaseID: String? = nil,
    toReleaseID: String,
    rolledBackTo: String? = nil,
    finishedAt: Date = Date(),
    outcome: Outcome,
    summary: String,
    bootFailure: String? = nil,
    checks: [HarnessCheckResult] = [],
    notes: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.fromReleaseID = fromReleaseID
    self.toReleaseID = toReleaseID
    self.rolledBackTo = rolledBackTo
    self.finishedAt = finishedAt
    self.outcome = outcome
    self.summary = summary
    self.bootFailure = bootFailure
    self.checks = checks
    self.notes = notes
  }

  /// Blocking checks that failed — the ones a rollback is justified by.
  public var blockingFailures: [HarnessCheckResult] {
    checks.filter { $0.isBlocking && $0.verdict == .fail }
  }

  /// Everything that was not clean, for a one-glance count in the UI.
  public var concerns: [HarnessCheckResult] {
    checks.filter { $0.verdict == .fail || $0.verdict == .warn }
  }

  /// Whether this report is the one a relaunched app should still be told about.
  public var isWorthShowingAtLaunch: Bool {
    outcome != .kept
  }
}

/// Persisted upgrade reports at `<root>/harness/upgrade-report.json`.
///
/// Two homes rather than one: the newest report is a fixed, obviously-named file so a later
/// launch can find it without listing anything, and a bounded history exists so "it worked
/// last time and does not now" has something to compare against.
public struct UpgradeReportStore: Sendable, Equatable {
  /// How many historical reports are kept. Small on purpose: these are diagnostic, and a
  /// directory that grows without limit inside the runtime tree is its own bug.
  public static let keepCount = 10

  public let latestURL: URL
  public let historyDirectory: URL

  public init(paths: RuntimePaths) {
    self.latestURL = paths.harnessRoot.appendingPathComponent("upgrade-report.json", isDirectory: false)
    self.historyDirectory = paths.harnessRoot.appendingPathComponent("upgrade-reports", isDirectory: true)
  }

  public init(latestURL: URL, historyDirectory: URL) {
    self.latestURL = latestURL
    self.historyDirectory = historyDirectory
  }

  /// Never throws: a report that cannot be read is simply not shown.
  ///
  /// Unlike `InstallsIndex`, whose corruption is an error because guessing would orphan every
  /// installed release, a corrupt *report* costs nothing to ignore — the upgrade itself is
  /// recorded in the ledger, and this file only explains it.
  public func loadLatest() -> UpgradeReport? {
    guard let data = try? Data(contentsOf: latestURL) else { return nil }
    guard let report = try? AtomicFile.makeDecoder().decode(UpgradeReport.self, from: data) else { return nil }
    guard report.schemaVersion <= UpgradeReport.currentSchemaVersion else { return nil }
    return report
  }

  /// Write the report, then a dated copy, then prune the history.
  ///
  /// The order matters: the fixed-name file is what a relaunched app reads, so it is written
  /// first and a failure to write the history copy is not allowed to take it down.
  public func save(_ report: UpgradeReport) throws {
    let data = try AtomicFile.makeEncoder().encode(report)
    try AtomicFile.write(data, to: latestURL)
    try? AtomicFile.write(data, to: historyURL(for: report))
    pruneHistory()
  }

  /// One history file per report, named so that lexical order is chronological and two
  /// reports in the same second cannot overwrite each other.
  private func historyURL(for report: UpgradeReport) -> URL {
    let stamp = Self.stampFormatter.string(from: report.finishedAt)
    let token = UUID().uuidString.prefix(6)
    return historyDirectory.appendingPathComponent("\(stamp)-\(token).json", isDirectory: false)
  }

  private static let stampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }()

  /// Keep the newest `keepCount`. A missing directory is not worth reporting.
  private func pruneHistory() {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: historyDirectory.path) else {
      return
    }
    let sorted = names.filter { $0.hasSuffix(".json") }.sorted()
    guard sorted.count > Self.keepCount else { return }
    for name in sorted.prefix(sorted.count - Self.keepCount) {
      try? FileManager.default.removeItem(at: historyDirectory.appendingPathComponent(name, isDirectory: false))
    }
  }
}
