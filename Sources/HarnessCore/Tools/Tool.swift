import Foundation
import HarnessKit

// MARK: - Services

/// Filesystem seam.
///
/// Every filesystem tool goes through this, never through `FileManager` directly, so
/// that the same tool implementations work against the local disk, a sandboxed
/// scratch tree in tests, or a future remote workspace.
public protocol FileSystemService: Sendable {
  func read(path: String) async throws -> FileContent
  func write(path: String, content: String, createDirectories: Bool) async throws -> FileWriteReceipt
  func replace(path: String, old: String, new: String, replaceAll: Bool) async throws -> FileWriteReceipt
  func writeLines(path: String, insertLine: Int?, content: String) async throws -> FileWriteReceipt
  func stat(path: String) async throws -> FileStat
  func list(directory: String, depth: Int) async throws -> [FileEntry]
  /// Glob match relative to `directory`.
  func glob(pattern: String, directory: String, limit: Int) async throws -> [FileEntry]
  /// Content search.
  func grep(_ query: GrepQuery) async throws -> GrepResult
  /// Read a binary attachment by id (produced by a previous read).
  func readAttachment(id: String) async throws -> Data
}

public struct FileContent: Sendable, Equatable {
  public var path: String
  public var text: String
  /// True when the file was truncated to fit `maxBytes`.
  public var truncated: Bool
  public var bytes: Int
  public var lineCount: Int
  public var modifiedAt: Date?
  /// 1-based first line of the returned slice.
  public var firstLine: Int

  public init(
    path: String,
    text: String,
    truncated: Bool = false,
    bytes: Int = 0,
    lineCount: Int = 0,
    modifiedAt: Date? = nil,
    firstLine: Int = 1
  ) {
    self.path = path
    self.text = text
    self.truncated = truncated
    self.bytes = bytes
    self.lineCount = lineCount
    self.modifiedAt = modifiedAt
    self.firstLine = firstLine
  }
}

public struct FileWriteReceipt: Sendable, Equatable {
  public var path: String
  public var bytesWritten: Int
  public var linesWritten: Int
  public var created: Bool
  public var diff: String?

  public init(path: String, bytesWritten: Int = 0, linesWritten: Int = 0, created: Bool = false, diff: String? = nil) {
    self.path = path
    self.bytesWritten = bytesWritten
    self.linesWritten = linesWritten
    self.created = created
    self.diff = diff
  }
}

public struct FileStat: Sendable, Equatable {
  public var path: String
  public var exists: Bool
  public var isDirectory: Bool
  public var bytes: Int
  public var modifiedAt: Date?
  public var kind: String

  public init(path: String, exists: Bool, isDirectory: Bool = false, bytes: Int = 0, modifiedAt: Date? = nil, kind: String = "file") {
    self.path = path
    self.exists = exists
    self.isDirectory = isDirectory
    self.bytes = bytes
    self.modifiedAt = modifiedAt
    self.kind = kind
  }
}

public struct FileEntry: Sendable, Equatable, Identifiable {
  public var path: String
  public var isDirectory: Bool
  public var bytes: Int
  public var modifiedAt: Date?
  /// Line number of a match, for grep results.
  public var line: Int?
  public var preview: String?

  public var id: String { "\(path):\(line ?? 0)" }

  public init(path: String, isDirectory: Bool = false, bytes: Int = 0, modifiedAt: Date? = nil, line: Int? = nil, preview: String? = nil) {
    self.path = path
    self.isDirectory = isDirectory
    self.bytes = bytes
    self.modifiedAt = modifiedAt
    self.line = line
    self.preview = preview
  }
}

public struct GrepQuery: Sendable, Equatable {
  public var pattern: String
  public var path: String
  public var glob: String?
  public var caseSensitive: Bool
  public var fixedStrings: Bool
  public var contextLines: Int
  public var maxResults: Int
  public var outputMode: OutputMode

  public enum OutputMode: String, Sendable, Codable {
    case content
    case filesWithMatches
    case count
  }

  public init(
    pattern: String,
    path: String = ".",
    glob: String? = nil,
    caseSensitive: Bool = true,
    fixedStrings: Bool = false,
    contextLines: Int = 0,
    maxResults: Int = 250,
    outputMode: OutputMode = .content
  ) {
    self.pattern = pattern
    self.path = path
    self.glob = glob
    self.caseSensitive = caseSensitive
    self.fixedStrings = fixedStrings
    self.contextLines = contextLines
    self.maxResults = maxResults
    self.outputMode = outputMode
  }
}

public struct GrepResult: Sendable, Equatable {
  public var matches: [FileEntry]
  /// True when the match set was capped; the full list was spilled to `spillPath`.
  public var capped: Bool
  public var spillPath: String?

  public init(matches: [FileEntry] = [], capped: Bool = false, spillPath: String? = nil) {
    self.matches = matches
    self.capped = capped
    self.spillPath = spillPath
  }
}

/// Shell seam.
public protocol ShellService: Sendable {
  /// Run a command to completion.
  func run(_ request: ShellRequest) async throws -> ShellResult
  /// Start a command in the background and return its job handle.
  func start(_ request: ShellRequest, label: String) async throws -> ShellJobHandle
}

public struct ShellRequest: Sendable, Equatable {
  public var command: String
  public var cwd: String?
  public var environment: [String: String]
  public var timeoutSeconds: Double?
  public var stdin: String?
  /// Removes the command's own environment instead of inheriting the app's.
  public var cleanEnvironment: Bool

  public init(
    command: String,
    cwd: String? = nil,
    environment: [String: String] = [:],
    timeoutSeconds: Double? = nil,
    stdin: String? = nil,
    cleanEnvironment: Bool = false
  ) {
    self.command = command
    self.cwd = cwd
    self.environment = environment
    self.timeoutSeconds = timeoutSeconds
    self.stdin = stdin
    self.cleanEnvironment = cleanEnvironment
  }
}

public struct ShellResult: Sendable, Equatable {
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32
  public var duration: TimeInterval
  public var timedOut: Bool

  public init(stdout: String, stderr: String, exitCode: Int32, duration: TimeInterval = 0, timedOut: Bool = false) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
    self.duration = duration
    self.timedOut = timedOut
  }

  public var isSuccess: Bool { exitCode == 0 && !timedOut }

  /// The text a tool returns to the model: stdout, then stderr, then exit status.
  public var rendered: String {
    var parts: [String] = []
    if !stdout.isEmpty { parts.append(stdout) }
    if !stderr.isEmpty { parts.append(stderr) }
    if timedOut { parts.append("(command timed out)") }
    else if exitCode != 0 { parts.append("(exit code \(exitCode))") }
    return parts.joined(separator: "\n")
  }
}

public struct ShellJobHandle: Sendable, Equatable {
  public var id: String
  public var pid: Int32?

  public init(id: String, pid: Int32? = nil) {
    self.id = id
    self.pid = pid
  }
}

/// Background job seam.
public protocol JobService: Sendable {
  func list() async -> [JobRecord]
  func output(_ id: String, tail: Int) async throws -> String
  func kill(_ id: String, reason: String) async throws
  func startCommand(_ request: ShellRequest, label: String) async throws -> JobRecord
}

/// Human-in-the-loop seam.
///
/// Tools call into this; the UI answers it. Both engines implement the same seam, so
/// a tool implementation never knows which engine is driving it.
public protocol InteractionService: Sendable {
  /// Ask permission before a mutating tool runs. Returns `false` to deny.
  func requestApproval(toolName: String, callID: String, reason: String) async -> Bool
  /// Ask the human a question (`ask_user_question`).
  func ask(_ questions: [UserQuestion], callID: String) async -> [String: QuestionAnswer]
  /// Present a plan for review (`exit_plan_mode`).
  func reviewPlan(_ plan: String, callID: String) async -> ApprovalDecision.Outcome
  /// Stream a notice into the transcript (used by background jobs).
  func notify(_ text: String) async
}

/// Events the loop publishes while a tool runs, so long tools are visible live.
public protocol ToolEventSink: Sendable {
  func emit(_ event: SessionEvent) async
}

// MARK: - Tool protocol

/// One capability.
///
/// Implementations are stateless and `Sendable`: everything per-call arrives in the
/// context, which is what lets the registry hand the same instance to concurrent
/// sub-calls.
public protocol HarnessTool: Sendable {
  /// The model-facing schema. This must be byte-identical to the official tool's
  /// schema — the conformance suite asserts it against `Spec/tool-catalog.schemas.json`.
  var descriptor: ToolDescriptor { get }
  /// Execute with already-parsed arguments.
  func run(_ arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutcome
}

extension HarnessTool {
  /// Convenience for tools that always succeed with plain text.
  func text(_ value: String) -> ToolOutcome {
    ToolOutcome(content: [.text(value)])
  }

  func failure(_ message: String, code: String = "TOOL_FAILED") -> ToolOutcome {
    ToolOutcome(content: [.text(message)], isError: true, errorCode: code, errorName: "ToolCallError")
  }
}

/// Everything a tool may touch for one call.
public struct ToolExecutionContext: Sendable {
  public var sessionID: SessionID
  /// Resolved working directory for the session.
  public var cwd: URL
  public var filesystem: any FileSystemService
  public var shell: any ShellService
  public var jobs: any JobService
  public var interaction: any InteractionService
  public var events: (any ToolEventSink)?
  /// Sandbox and permission policy in force for this call.
  public var permissions: PermissionPreset
  public var sandbox: SandboxMode
  /// Scratch space for spill files and temporary artifacts.
  public var scratchDirectory: URL
  /// Environment variables injected into commands (`DSH_*` in the official runtime).
  public var managedEnvironment: [String: String]
  /// Called for progress the user should see but the model should not.
  public var log: @Sendable (String) -> Void
  /// Registry lookup, so composite tools (workflow, subagent, run_code) can call others.
  public var registry: ToolRegistry?

  public init(
    sessionID: SessionID,
    cwd: URL,
    filesystem: any FileSystemService,
    shell: any ShellService,
    jobs: any JobService,
    interaction: any InteractionService,
    events: (any ToolEventSink)? = nil,
    permissions: PermissionPreset = .workspaceWrite,
    sandbox: SandboxMode = .workspaceWrite,
    scratchDirectory: URL,
    managedEnvironment: [String: String] = [:],
    log: @escaping @Sendable (String) -> Void = { _ in },
    registry: ToolRegistry? = nil
  ) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.filesystem = filesystem
    self.shell = shell
    self.jobs = jobs
    self.interaction = interaction
    self.events = events
    self.permissions = permissions
    self.sandbox = sandbox
    self.scratchDirectory = scratchDirectory
    self.managedEnvironment = managedEnvironment
    self.log = log
    self.registry = registry
  }

  /// Resolve a possibly-relative path against the session cwd.
  public func resolve(_ path: String) -> URL {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
    if path.hasPrefix("~") {
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    return cwd.appendingPathComponent(path).standardizedFileURL
  }

  /// Convenience: run a lookup through the registry.
  public func tool(named name: String) -> (any HarnessTool)? {
    registry?.tool(named: name)
  }
}

// MARK: - Registry

/// Name → tool, plus the surface metadata the UI and the model-facing declaration need.
public final class ToolRegistry: @unchecked Sendable {
  private var tools: [String: any HarnessTool] = [:]
  private let lock = NSLock()

  public init() {}

  public func register(_ tool: any HarnessTool) {
    lock.lock()
    defer { lock.unlock() }
    tools[tool.descriptor.name] = tool
  }

  public func register(_ list: [any HarnessTool]) {
    for tool in list { register(tool) }
  }

  public func tool(named name: String) -> (any HarnessTool)? {
    lock.lock()
    defer { lock.unlock() }
    return tools[name]
  }

  public var allTools: [any HarnessTool] {
    lock.lock()
    defer { lock.unlock() }
    return tools.values.sorted { $0.descriptor.name < $1.descriptor.name }
  }

  public var descriptors: [ToolDescriptor] {
    allTools.map(\.descriptor)
  }

  /// The surface as the model sees it.
  ///
  /// `mode` decides the shape: `.direct` offers every descriptor as a tool;
  /// `.programmatic` offers only `run_code` and declares the rest as bindings
  /// (M0 finding #3 — the mode the running desktop profile actually uses).
  public func surface(mode: ToolSurface.PresentationMode, excluding: Set<String> = []) -> ToolSurface {
    let available = descriptors.filter { !excluding.contains($0.name) }
    switch mode {
    case .direct:
      return ToolSurface(mode: .direct, directTools: available, bindingLanguage: nil)
    case .programmatic:
      let programTools = available.filter { $0.name == "run_code" }
      let bindings = available
        .filter { $0.name != "run_code" }
        .map { descriptor -> ToolDescriptor in
          var copy = descriptor
          copy.origin = .programBinding
          return copy
        }
      return ToolSurface(
        mode: .programmatic,
        directTools: programTools,
        programBindings: bindings,
        programToolName: programTools.first?.name,
        bindingLanguage: "typescript",
        notes: "Capabilities are declared as TypeScript bindings in the system prompt."
      )
    case .both:
      let programTools = available.filter { $0.name == "run_code" }
      let bindings = available.map { descriptor -> ToolDescriptor in
        var copy = descriptor
        copy.origin = descriptor.name == "run_code" ? .both : .programBinding
        return copy
      }
      return ToolSurface(
        mode: .both,
        directTools: available,
        programBindings: bindings,
        programToolName: programTools.first?.name,
        bindingLanguage: "typescript"
      )
    }
  }
}

// MARK: - Errors

/// A tool-level failure carrying the official error code shape.
public struct ToolCallError: Error, LocalizedError, Sendable {
  public var code: String
  public var name: String
  public var message: String

  public init(code: String, name: String = "ToolCallError", message: String) {
    self.code = code
    self.name = name
    self.message = message
  }

  public var errorDescription: String? { message }
}
