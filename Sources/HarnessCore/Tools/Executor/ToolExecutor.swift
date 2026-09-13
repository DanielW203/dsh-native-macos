import Foundation
import HarnessKit

/// Shared execution helpers for the npm-compatible tool set in this module.
///
/// Two seams are centralised here so every tool behaves identically:
///
/// 1. **Permission gate.** `ToolExecutionContext.permissions == .readOnly` must refuse a
///    mutating tool with `PERMISSION_DENIED` before any work happens. Approval prompting
///    belongs to the loop (`InteractionService.requestApproval`), so a tool never asks —
///    it either runs or refuses.
/// 2. **Spill.** The official runtime caps tool output and writes the complete text to
///    its spill store, naming the path in the returned text (`docs/tool-catalog.md`
///    § `@deepseek-ai/dsh-tool-bash`, § `@deepseek-ai/dsh-tool-fs-search`). Here the spill
///    lives under `ToolExecutionContext.scratchDirectory` and is written through
///    `FileSystemService`, never through `FileManager` directly.
public enum ToolExecutor {
  // MARK: - Permissions

  /// Refuse a mutating call under the read-only preset.
  public static func requireWrite(_ context: ToolExecutionContext, tool: String) throws {
    guard context.permissions == .readOnly else { return }
    throw ToolCallError(
      code: ToolArgs.permissionDenied,
      message: "\(tool) is not permitted under the read-only permission preset; "
        + "switch the session to workspace-write or full access to run it."
    )
  }

  /// Whether a refusable mutation should instead be treated as a no-op. Kept for
  /// symmetry with the loop's policy hook; no tool in this module uses it today.
  public static func isReadOnly(_ context: ToolExecutionContext) -> Bool {
    context.permissions == .readOnly
  }

  // MARK: - Paths

  /// Resolve a model-supplied path and return both the absolute URL (for services that
  /// key attachments by path) and the display path used in rendered output.
  ///
  /// Display prefers the caller's own spelling when the argument was relative: the
  /// official tools echo the backend's resolved path, but a Swift-native service cannot
  /// report a display path, and echoing the caller's spelling keeps the text stable and
  /// diff-friendly across cwd changes.
  public static func resolve(_ rawPath: String, context: ToolExecutionContext) -> (url: URL, displayPath: String) {
    let url = context.resolve(rawPath)
    return (url, displayPath(rawPath: rawPath, url: url, cwd: context.cwd))
  }

  public static func displayPath(rawPath: String, url: URL, cwd: URL) -> String {
    if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") { return url.path }
    let absolute = url.path
    let root = cwd.standardizedFileURL.path
    if absolute.hasPrefix(root + "/") { return String(absolute.dropFirst(root.count + 1)) }
    return absolute
  }

  /// A copy of `path` with `count` trailing lines replaced by nothing. Used by the
  /// tail-cap formatters.
  public static func tailLines(_ text: String, _ count: Int) -> String {
    guard count > 0 else { return "" }
    var lines = text.components(separatedBy: "\n")
    // A trailing newline produces one empty final element; it is not a line of content.
    if lines.last == "" { lines.removeLast() }
    guard lines.count > count else { return text }
    return lines.suffix(count).joined(separator: "\n")
  }

  public static func utf8Bytes(_ text: String) -> Int {
    text.lengthOfBytes(using: .utf8)
  }

  // MARK: - Spill

  /// Provenance of one spilled artifact: where it was written, what it holds, and how
  /// to read it back.
  public struct Spill: Sendable, Equatable {
    /// Absolute path of the spill file (the locator the model sees).
    public var path: String
    /// Human sentence naming what the file holds.
    public var summary: String

    public init(path: String, summary: String) {
      self.path = path
      self.summary = summary
    }

    /// The `spillPath` recorded on `GrepResult` and friends.
    public var locator: String { path }

    /// The official retrieval hint (`dsh-spill`): read the locator, or search it.
    public var retrievalHint: String {
      "Use read with file_path=\(path) (offset/limit to page), or grep path=\(path) to search within it."
    }
  }

  /// Write `content` into the session scratch directory through `FileSystemService`.
  ///
  /// Returns `nil` when the spill could not be written: every caller then renders the
  /// official "complete result could not be saved" wording instead of a dangling path.
  public static func spill(
    _ content: String,
    name: String,
    summary: String,
    context: ToolExecutionContext
  ) async -> Spill? {
    let directory = spillDirectory(context)
    let file = directory.appendingPathComponent(sanitize(name))
    do {
      _ = try await context.filesystem.write(
        path: file.path,
        content: content,
        createDirectories: true
      )
      return Spill(path: file.path, summary: summary)
    } catch {
      return nil
    }
  }

  /// `<scratch>/spill`. Kept stable across calls in one session so repeated capped
  /// results overwrite rather than accumulate.
  public static func spillDirectory(_ context: ToolExecutionContext) -> URL {
    context.scratchDirectory.appendingPathComponent("spill", isDirectory: true)
  }

  /// Flatten a descriptive name into a single safe path component: no separators, no
  /// `..`, no empty component, and a bounded length.
  public static func sanitize(_ name: String) -> String {
    var cleaned = name.replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .replacingOccurrences(of: "\0", with: "-")
    while cleaned.contains("..") { cleaned = cleaned.replacingOccurrences(of: "..", with: ".") }
    cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
    if cleaned.isEmpty { cleaned = "spill.txt" }
    if cleaned.count > 120 { cleaned = String(cleaned.suffix(120)) }
    return cleaned
  }

  // MARK: - Shared formatters

  /// The official "the complete result could not be saved" sentence
  /// (`dsh-tool-fs-search` `formatGrepOutput` / `formatGlobPage`), parameterised by the
  /// advice that follows it.
  public static func unsavedNotice(_ advice: String) -> String {
    "The complete result could not be saved; \(advice)"
  }
}
