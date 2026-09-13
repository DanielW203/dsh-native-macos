import Foundation
import HarnessKit
import SwiftUI

/// Application-level state: which engine is driving, which sessions exist, and what
/// the shell shows around the transcript.
///
/// The window layer never talks to an engine directly — everything goes through this
/// object, which is what makes swapping engines a UI-level action rather than a
/// rebuild.
@MainActor
public final class AppModel: ObservableObject {
  /// Every engine this build can drive, keyed by kind. Route A and route B are both
  /// constructed at launch when available; an unavailable engine stays registered so
  /// the settings pane can explain *why* it is unavailable instead of hiding it.
  public let engines: [EngineKind: any HarnessEngine]

  @Published public private(set) var selectedEngineKind: EngineKind
  @Published public private(set) var status: EngineStatus?
  @Published public private(set) var capabilities: EngineCapabilities = .none
  @Published public private(set) var sessions: [SessionSummary] = []
  @Published public private(set) var toolSurface: ToolSurface = .empty
  @Published public private(set) var models: [ModelOption] = []
  @Published public private(set) var isLoadingSessions = false
  @Published public var sessionFilter: String = ""
  /// The session the window is showing; the sidebar binds its selection to this.
  @Published public var selectedSessionID: SessionID?
  @Published public var errorMessage: String?
  /// Set when an engine probed unsuccessfully at launch, so the shell can show a
  /// fixable explanation rather than an empty window.
  @Published public private(set) var engineDiagnostics: [EngineKind: String] = [:]

  private var refreshTask: Task<Void, Never>?

  public init(engines: [any HarnessEngine], preferred: EngineKind? = nil) {
    var map: [EngineKind: any HarnessEngine] = [:]
    for engine in engines { map[engine.kind] = engine }
    self.engines = map
    if let preferred, map[preferred] != nil {
      self.selectedEngineKind = preferred
    } else {
      // Prefer the native engine when it is present: it needs no Node runtime, and
      // the embedded engine is the fallback rather than the default.
      self.selectedEngineKind = map[.native] != nil ? .native : (map.keys.first ?? .native)
    }
  }

  public convenience init(engine: any HarnessEngine) {
    self.init(engines: [engine], preferred: engine.kind)
  }

  public var engine: any HarnessEngine {
    guard let engine = engines[selectedEngineKind] else {
      preconditionFailure("No engine registered for \(selectedEngineKind)")
    }
    return engine
  }

  public var availableEngines: [EngineKind] {
    EngineKind.allCases.filter { engines[$0] != nil }
  }

  // MARK: Lifecycle

  /// Probe the selected engine and load its session list. Safe to call repeatedly.
  public func start() async {
    await refreshEngine()
    await refreshSessions()
  }

  public func refreshEngine() async {
    let engine = self.engine
    capabilities = await engine.capabilities()
    let status = await engine.status()
    self.status = status
    if !status.isReady, let detail = status.warning ?? status.detail {
      engineDiagnostics[engine.kind] = detail
    } else {
      engineDiagnostics[engine.kind] = nil
    }
    toolSurface = (try? await engine.toolSurface()) ?? .empty
    models = (try? await engine.models()) ?? []
  }

  public func refreshSessions() async {
    guard capabilities.canListSessions else { return }
    isLoadingSessions = true
    defer { isLoadingSessions = false }
    do {
      sessions = try await engine.listSessions(limit: 400)
      errorMessage = nil
    } catch {
      errorMessage = (error as? HarnessError)?.errorDescription ?? String(describing: error)
    }
  }

  /// Switch engines, re-probing and reloading in place.
  public func selectEngine(_ kind: EngineKind) async {
    guard engines[kind] != nil, kind != selectedEngineKind else { return }
    selectedEngineKind = kind
    sessions = []
    await refreshEngine()
    await refreshSessions()
  }

  // MARK: Sessions

  /// Create a session rooted at `cwd` and return its id.
  public func createSession(cwd: String, preset: String? = nil) async -> SessionID? {
    do {
      let id = try await engine.createSession(cwd: cwd, preset: preset)
      await refreshSessions()
      selectedSessionID = id
      return id
    } catch {
      errorMessage = (error as? HarnessError)?.errorDescription ?? String(describing: error)
      return nil
    }
  }

  public func delete(_ id: SessionID) async {
    do {
      try await engine.delete(id)
      await refreshSessions()
    } catch {
      errorMessage = (error as? HarnessError)?.errorDescription ?? String(describing: error)
    }
  }

  /// Sessions matching the sidebar filter, most recent first.
  public var filteredSessions: [SessionSummary] {
    let query = sessionFilter.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return sessions }
    return sessions.filter { summary in
      summary.displayTitle.localizedCaseInsensitiveContains(query)
        || (summary.cwd ?? "").localizedCaseInsensitiveContains(query)
        || summary.id.rawValue.localizedCaseInsensitiveContains(query)
    }
  }

  /// Sessions grouped by working directory — the sidebar's section structure.
  public var sessionsByDirectory: [(cwd: String, sessions: [SessionSummary])] {
    let grouped = Dictionary(grouping: filteredSessions) { $0.cwd ?? "—" }
    return grouped
      .map { (cwd: $0.key, sessions: $0.value.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }) }
      .sorted { $0.cwd < $1.cwd }
  }

  // MARK: Presentation mode

  /// True when the active engine exposes programs rather than one tool per capability
  /// (M0 finding #3). The transcript switches to the program-tree renderer.
  public var isProgrammaticMode: Bool {
    toolSurface.mode == .programmatic || toolSurface.mode == .both
  }

  public var programToolName: String {
    toolSurface.programToolName ?? "run_code"
  }

  /// Capability count for the status line, phrased for the active mode.
  public var capabilitySummary: String {
    let tools = toolSurface.directTools.count
    let bindings = toolSurface.programBindings.count
    if isProgrammaticMode {
      return "\(bindings) program bindings · \(tools) direct tool\(tools == 1 ? "" : "s")"
    }
    return "\(tools) tools"
  }
}
