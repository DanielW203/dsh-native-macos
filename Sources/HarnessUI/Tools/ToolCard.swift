import HarnessKit
import SwiftUI

/// Registry of tool-call renderings.
///
/// Every tool renders through here rather than through a giant `switch` inside the
/// transcript, so a new tool card is an additive change. Tools without a specialised
/// card fall back to `GenericToolCard`, which shows the arguments and the result in a
/// usable form — that fallback is what lets the catalogue grow without a blank row.
public enum ToolCardRenderer {
  @ViewBuilder
  public static func card(for invocation: ToolInvocation, session: SessionViewModel) -> some View {
    switch invocation.name {
    case "bash", "pwsh":
      ShellToolCard(invocation: invocation)
    case "read":
      ReadToolCard(invocation: invocation)
    case "write":
      WriteToolCard(invocation: invocation)
    case "edit", "str_replace_editor":
      EditToolCard(invocation: invocation)
    case "glob":
      GlobToolCard(invocation: invocation)
    case "grep":
      GrepToolCard(invocation: invocation)
    case "read_image":
      ImageToolCard(invocation: invocation)
    case "todo_write":
      TodoToolCard(invocation: invocation)
    case "subagent", "subagent_fork", "spawn_teammate":
      SubagentToolCard(invocation: invocation)
    case "web_search", "web_fetch", "advanced_search", "platform_search":
      WebToolCard(invocation: invocation)
    case "job_list", "job_output", "job_kill":
      JobToolCard(invocation: invocation)
    default:
      GenericToolCard(invocation: invocation)
    }
  }
}

// MARK: - Shared chrome

/// Frame every tool card shares: status, name, duration, expand affordance.
struct ToolCardChrome<Content: View>: View {
  let invocation: ToolInvocation
  var title: String?
  var subtitle: String?
  var symbol: String?
  @ViewBuilder var content: () -> Content

  @State private var expanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: statusIcon)
          .foregroundStyle(statusColor)
        Image(systemName: symbol ?? invocation.category.symbolName)
          .foregroundStyle(.secondary)
          .font(.callout)
        VStack(alignment: .leading, spacing: 1) {
          Text(title ?? invocation.name)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer()
        if invocation.status == .running || invocation.status == .awaitingApproval {
          ProgressView().controlSize(.small)
        }
        if let duration = invocation.duration {
          Text(String(format: "%.2fs", duration))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        Button {
          withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
        } label: {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
        }
        .buttonStyle(.borderless)
      }

      if expanded {
        content()
      }
    }
    .padding(9)
    .background(background, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(borderColor, lineWidth: 1))
  }

  private var statusIcon: String {
    switch invocation.status {
    case .pending: return "circle"
    case .awaitingApproval: return "hand.raised.fill"
    case .running: return "circle.dotted"
    case .succeeded: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    case .cancelled: return "slash.circle"
    }
  }

  private var statusColor: Color {
    switch invocation.status {
    case .pending: return .secondary
    case .awaitingApproval: return .orange
    case .running: return .accentColor
    case .succeeded: return .green
    case .failed: return .red
    case .cancelled: return .secondary
    }
  }

  private var background: Color {
    invocation.status == .failed ? Color.red.opacity(0.05) : Color.secondary.opacity(0.06)
  }

  private var borderColor: Color {
    invocation.status == .failed ? Color.red.opacity(0.30) : Color.secondary.opacity(0.18)
  }
}

/// Monospaced, capped output block with an expand toggle.
struct ToolOutputText: View {
  let text: String
  var lineLimit: Int = 18
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ScrollView(expanded ? [.horizontal, .vertical] : .horizontal, showsIndicators: expanded) {
        Text(text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .lineLimit(expanded ? nil : lineLimit)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: expanded ? 420 : nil)
      if text.split(separator: "\n").count > lineLimit {
        Button(expanded ? "Collapse" : "Show all \(text.split(separator: "\n").count) lines") {
          withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
        .buttonStyle(.borderless)
        .font(.caption2)
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
  }
}

extension ToolInvocation {
  /// A one-line summary of the arguments, for card subtitles.
  var argumentSummary: String {
    let arguments = parsedArgumentsForDisplay
    for key in ["command", "file_path", "path", "pattern", "query", "description", "prompt", "objective", "url"] {
      if let value = arguments[key]?.stringValue, !value.isEmpty { return value }
    }
    if let text = try? arguments.serialized() { return text.count > 120 ? String(text.prefix(120)) + "…" : text }
    return ""
  }

  fileprivate var parsedArgumentsForDisplay: JSONValue {
    (try? JSONValue.parse(argumentsText, context: "arguments")) ?? .object([:])
  }
}

// MARK: - Specialised cards

struct ShellToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Shell",
      subtitle: invocation.argumentSummary,
      symbol: "terminal"
    ) {
      VStack(alignment: .leading, spacing: 6) {
        if let command = invocation.parsedArgumentsForDisplay["command"]?.stringValue {
          CodeBlockView(code: command, language: "bash")
        }
        if let outcome = invocation.outcome {
          ToolOutputText(text: outcome.text.isEmpty ? "(no output)" : outcome.text)
        }
      }
    }
  }
}

struct ReadToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Read",
      subtitle: invocation.argumentSummary,
      symbol: "doc.text"
    ) {
      if let outcome = invocation.outcome {
        ToolOutputText(text: outcome.text, lineLimit: 24)
      }
    }
  }
}

struct WriteToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Write",
      subtitle: invocation.argumentSummary,
      symbol: "square.and.pencil"
    ) {
      VStack(alignment: .leading, spacing: 6) {
        if let content = invocation.parsedArgumentsForDisplay["content"]?.stringValue {
          CodeBlockView(code: content, language: nil)
        }
        if let outcome = invocation.outcome {
          ToolOutputText(text: outcome.text, lineLimit: 8)
        }
      }
    }
  }
}

struct EditToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Edit",
      subtitle: invocation.argumentSummary,
      symbol: "square.and.pencil"
    ) {
      VStack(alignment: .leading, spacing: 6) {
        DiffView(
          old: invocation.parsedArgumentsForDisplay["old_string"]?.stringValue
            ?? invocation.parsedArgumentsForDisplay["old_str"]?.stringValue ?? "",
          new: invocation.parsedArgumentsForDisplay["new_string"]?.stringValue
            ?? invocation.parsedArgumentsForDisplay["new_str"]?.stringValue ?? ""
        )
        if let outcome = invocation.outcome {
          ToolOutputText(text: outcome.text, lineLimit: 8)
        }
      }
    }
  }
}

/// Two-tone before/after rendering for an edit.
struct DiffView: View {
  let old: String
  let new: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !old.isEmpty {
        ForEach(Array(old.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
          Text("- " + line)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
        }
      }
      if !new.isEmpty {
        ForEach(Array(new.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
          Text("+ " + line)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08))
        }
      }
    }
    .textSelection(.enabled)
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

struct GlobToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Glob",
      subtitle: invocation.argumentSummary,
      symbol: "magnifyingglass"
    ) {
      VStack(alignment: .leading, spacing: 6) {
        if let outcome = invocation.outcome {
          let lines = outcome.text.split(separator: "\n").count
          HStack(spacing: 6) {
            Text("\(lines) path\(lines == 1 ? "" : "s")")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          ToolOutputText(text: outcome.text, lineLimit: 14)
        }
      }
    }
  }
}

struct GrepToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Grep",
      subtitle: invocation.argumentSummary,
      symbol: "text.magnifyingglass"
    ) {
      if let outcome = invocation.outcome {
        let lines = outcome.text.split(separator: "\n").count
        VStack(alignment: .leading, spacing: 6) {
          Text("\(lines) line\(lines == 1 ? "" : "s")")
            .font(.caption2)
            .foregroundStyle(.secondary)
          ToolOutputText(text: outcome.text, lineLimit: 16)
        }
      }
    }
  }
}

struct ImageToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Image",
      subtitle: invocation.argumentSummary,
      symbol: "photo"
    ) {
      VStack(alignment: .leading, spacing: 6) {
        if let attachment = invocation.outcome?.attachments.first {
          HStack(spacing: 6) {
            Image(systemName: "photo")
            Text(attachment.name ?? attachment.attachmentId)
              .font(.caption)
            if let width = attachment.width, let height = attachment.height {
              Text("\(width)×\(height)").font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
        if let outcome = invocation.outcome {
          ToolOutputText(text: outcome.text, lineLimit: 6)
        }
      }
    }
  }
}

struct TodoToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Todos updated",
      subtitle: invocation.argumentSummary,
      symbol: "checklist"
    ) {
      if let outcome = invocation.outcome, !outcome.text.isEmpty {
        ToolOutputText(text: outcome.text, lineLimit: 20)
      }
    }
  }
}

struct SubagentToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Delegate",
      subtitle: invocation.argumentSummary,
      symbol: "person.2"
    ) {
      VStack(alignment: .leading, spacing: 6) {
        if let description = invocation.parsedArgumentsForDisplay["description"]?.stringValue {
          Text(description).font(.caption).foregroundStyle(.secondary)
        }
        if let outcome = invocation.outcome {
          ToolOutputText(text: outcome.text, lineLimit: 18)
        }
      }
    }
  }
}

struct WebToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: invocation.name == "web_fetch" ? "Fetch" : "Search",
      subtitle: invocation.argumentSummary,
      symbol: "globe"
    ) {
      if let outcome = invocation.outcome {
        ToolOutputText(text: outcome.text, lineLimit: 20)
      }
    }
  }
}

struct JobToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: "Jobs",
      subtitle: invocation.argumentSummary,
      symbol: "gearshape.2"
    ) {
      if let outcome = invocation.outcome {
        ToolOutputText(text: outcome.text, lineLimit: 16)
      }
    }
  }
}

/// The fallback card: arguments and result, no assumptions about the tool.
struct GenericToolCard: View {
  let invocation: ToolInvocation

  var body: some View {
    ToolCardChrome(
      invocation: invocation,
      title: invocation.name,
      subtitle: invocation.argumentSummary
    ) {
      VStack(alignment: .leading, spacing: 6) {
        if !invocation.argumentsText.isEmpty, invocation.argumentsText != "{}" {
          ToolOutputText(text: invocation.argumentsText, lineLimit: 6)
        }
        if let outcome = invocation.outcome {
          if outcome.isError, outcome.text.isEmpty {
            Text(outcome.shortErrorDescription ?? "Tool failed")
              .font(.caption)
              .foregroundStyle(.red)
          } else if !outcome.text.isEmpty {
            ToolOutputText(text: outcome.text, lineLimit: 16)
          }
        }
      }
    }
  }
}
