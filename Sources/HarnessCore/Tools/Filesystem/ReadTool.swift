import Foundation
import HarnessKit

/// `read` — read a UTF-8 text file and return line-numbered content.
///
/// Mirrors `@deepseek-ai/dsh-tool-fs` `src/read.ts` + `src/read-render.ts`:
/// - one `stat` for existence and type, then one read through `FileSystemService.read`;
/// - a bounded window (`offset` defaults to 1, `limit` defaults to 2000) rendered as an
///   OpenCode-style `<path>/<type>/<content>` envelope with numbered lines and a footer;
/// - absence is `FS_NOT_FOUND` and a non-regular file is `FS_NOT_REGULAR_FILE`.
///
/// Argument keys: `file_path` (official; `path` is accepted as a tolerant alias),
/// `offset`, `limit`.
public struct ReadTool: HarnessTool {
  /// Default and maximum number of lines returned by one call (the official
  /// `readLimit` config default, `READ_LIMIT = 2000`).
  public static let readLimit = 2000

  public init() {}

  public var descriptor: ToolDescriptor {
    OfficialToolSchemas.descriptor(for: "read", isMutating: false)
  }

  public func run(_ arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutcome {
    let tool = "read"
    let rawPath = try ToolArgs.requiredString(tool, arguments, keys: ["file_path", "path"])
    let offset = try ToolArgs.optionalPositiveInt(tool, arguments, keys: ["offset"]) ?? 1
    let limit = try ToolArgs.optionalPositiveInt(tool, arguments, keys: ["limit"]) ?? Self.readLimit
    guard limit <= Self.readLimit else {
      throw ToolArgs.invalid(tool, field: "limit", detail: "must be less than or equal to \(Self.readLimit)")
    }

    let target = ToolExecutor.resolve(rawPath, context: context)
    let stat = try await statOrThrow(target.url, displayPath: target.displayPath, context: context, tool: tool)
    guard !stat.isDirectory else {
      throw ToolCallError(
        code: "FS_NOT_REGULAR_FILE",
        message: "cannot read \"\(target.displayPath)\": not a regular file"
      )
    }

    let content: FileContent
    do {
      content = try await context.filesystem.read(path: target.url.path)
    } catch let error as ToolCallError {
      throw error
    } catch {
      throw ToolCallError(
        code: "FS_NOT_FOUND",
        message: "cannot read \"\(target.displayPath)\": \(error.localizedDescription)"
      )
    }

    // The service applies the window; `offset` only selects the slice.
    return text(format(content: content, requestedOffset: offset, displayPath: target.displayPath))
  }

  private func statOrThrow(
    _ url: URL,
    displayPath: String,
    context: ToolExecutionContext,
    tool: String
  ) async throws -> FileStat {
    let stat: FileStat
    do {
      stat = try await context.filesystem.stat(path: url.path)
    } catch {
      throw ToolCallError(
        code: "FS_NOT_FOUND",
        message: "cannot read \"\(displayPath)\": not found"
      )
    }
    guard stat.exists else {
      throw ToolCallError(code: "FS_NOT_FOUND", message: "cannot read \"\(displayPath)\": not found")
    }
    return stat
  }

  /// Render one read result as the official envelope.
  ///
  /// `FileContent.firstLine` is the 1-based first line of the returned slice, so the
  /// window's line numbers start there. `truncated` means the service hit its byte cap,
  /// which selects the official "Output capped…" footer instead of "Showing lines…".
  private func format(content: FileContent, requestedOffset: Int, displayPath: String) -> String {
    let firstLine = max(1, content.firstLine)
    var lines = content.text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    let endLine = lines.isEmpty ? max(0, firstLine - 1) : firstLine + lines.count - 1
    let totalLines = max(content.lineCount, endLine)
    let truncatedByBytes = content.truncated

    var footer: String
    if truncatedByBytes {
      footer = "(Output capped. Showing lines \(firstLine)-\(endLine). Use offset=\(endLine + 1) to continue.)"
    } else if endLine < totalLines {
      footer = "(Showing lines \(firstLine)-\(endLine) of \(totalLines). Use offset=\(endLine + 1) to continue.)"
    } else {
      footer = "(End of file - total \(totalLines) lines)"
    }

    let body: String
    if lines.isEmpty {
      body = footer
    } else {
      let numbered = lines.enumerated()
        .map { "\(firstLine + $0.offset): \($0.element)" }
        .joined(separator: "\n")
      body = "\(numbered)\n\n\(footer)"
    }

    return """
    <path>\(displayPath)</path>
    <type>file</type>
    <content>
    \(body)
    </content>
    """
  }
}
