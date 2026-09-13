import HarnessKit
import SwiftUI

/// A programmatic tool call (`run_code`) drawn as a program.
///
/// This view exists because of M0 finding #3: the running desktop profile uses PTC
/// mode, where the model sees exactly one tool — `run_code` — and reaches every other
/// capability as a `tools.name(args)` binding inside the program. The transcript
/// therefore cannot render "one card per tool call": it has to show the program, the
/// nested calls it made, and the (deliberately curated) output.
///
/// Nesting is expressed with `ProgramNode.depth` and numbered the way the runtime's own
/// dispatch order produced it, so a reader can map a line of code to the call it made.
public struct ProgramRunView: View {
  public let program: ProgramRun
  public var expanded: Bool

  @State private var showsCode: Bool
  @State private var expandedNodes: Set<String> = []

  public init(program: ProgramRun, expanded: Bool = true) {
    self.program = program
    self.expanded = expanded
    _showsCode = State(initialValue: false)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if expanded {
        if showsCode, !program.code.isEmpty {
          CodeBlockView(code: program.code, language: "typescript")
        }
        if !program.nodes.isEmpty {
          nodeTree
        }
        if let output = program.output, !output.isEmpty {
          outputSection(output)
        }
        if let error = program.error, !error.isEmpty {
          errorSection(error)
        }
      }
    }
    .padding(10)
    .background(background, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(borderColor, lineWidth: 1)
    )
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: statusIcon)
        .foregroundStyle(statusColor)
      VStack(alignment: .leading, spacing: 2) {
        Text(program.description.isEmpty ? "Program" : program.description)
          .font(.callout.weight(.medium))
          .lineLimit(2)
        HStack(spacing: 8) {
          Text("run_code")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospaced()
          if !program.code.isEmpty {
            Text("\(program.code.split(separator: "\n").count) lines")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          if !program.nodes.isEmpty {
            Text("\(program.nodes.count) call\(program.nodes.count == 1 ? "" : "s")")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          if program.failedNodeCount > 0 {
            Text("\(program.failedNodeCount) failed")
              .font(.caption2)
              .foregroundStyle(.red)
          }
          if let duration = program.duration {
            Text(String(format: "%.2fs", duration))
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .monospacedDigit()
          }
        }
      }
      Spacer()
      if program.status == .running {
        ProgressView().controlSize(.small)
      }
      if !program.code.isEmpty {
        Button {
          withAnimation(.easeInOut(duration: 0.15)) { showsCode.toggle() }
        } label: {
          Label(showsCode ? "Hide code" : "Show code", systemImage: showsCode ? "chevron.down" : "chevron.right")
            .font(.caption2)
        }
        .buttonStyle(.borderless)
      }
    }
  }

  // MARK: Node tree

  private var nodeTree: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(program.numberedNodes(), id: \.node.id) { numbered in
        ProgramNodeRow(
          number: numbered.index,
          node: numbered.node,
          isExpanded: Binding(
            get: { expandedNodes.contains(numbered.node.id) },
            set: { isExpanded in
              if isExpanded { expandedNodes.insert(numbered.node.id) } else { expandedNodes.remove(numbered.node.id) }
            }
          )
        )
      }
    }
    .padding(.leading, 2)
  }

  private func outputSection(_ output: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Output", systemImage: "arrow.turn.down.right")
        .font(.caption2)
        .foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        Text(output)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .padding(6)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
  }

  private func errorSection(_ error: String) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
      Text(error).font(.caption).textSelection(.enabled)
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
  }

  // MARK: Styling

  private var statusIcon: String {
    switch program.status {
    case .running: return "ellipsis.circle"
    case .succeeded: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    case .cancelled: return "slash.circle"
    }
  }

  private var statusColor: Color {
    switch program.status {
    case .running: return .accentColor
    case .succeeded: return .green
    case .failed: return .red
    case .cancelled: return .secondary
    }
  }

  private var background: Color {
    program.status == .failed ? Color.red.opacity(0.06) : Color.accentColor.opacity(0.06)
  }

  private var borderColor: Color {
    program.status == .failed ? Color.red.opacity(0.35) : Color.accentColor.opacity(0.25)
  }
}

/// One nested call inside a program.
struct ProgramNodeRow: View {
  let number: String
  let node: ProgramNode
  @Binding var isExpanded: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(number)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          .frame(minWidth: 34, alignment: .trailing)
        Image(systemName: node.category.symbolName)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(node.toolName)
          .font(.system(.caption, design: .monospaced))
        if node.status == .running {
          ProgressView().controlSize(.mini)
        }
        if let duration = node.outcome?.duration {
          Text(String(format: "%.2fs", duration))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        if node.status == .failed, let description = node.outcome?.shortErrorDescription {
          Text(description)
            .font(.caption2)
            .foregroundStyle(.red)
            .lineLimit(1)
        }
        Spacer()
        Button {
          withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
        } label: {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
        }
        .buttonStyle(.borderless)
      }

      if isExpanded {
        VStack(alignment: .leading, spacing: 4) {
          if !node.argumentsText.isEmpty, node.argumentsText != "{}" {
            CodeBlockView(code: prettyJSON(node.argumentsText), language: "json")
          }
          if let outcome = node.outcome {
            if outcome.isError {
              HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(outcome.text.isEmpty ? (outcome.shortErrorDescription ?? "failed") : outcome.text)
                  .font(.caption)
                  .textSelection(.enabled)
              }
            } else if !outcome.text.isEmpty {
              ScrollView(.horizontal, showsIndicators: false) {
                Text(outcome.text)
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
                  .lineLimit(24)
              }
            }
          }
        }
        .padding(.leading, 40)
      }
    }
    .padding(.vertical, 2)
    .background(node.depth > 0 ? Color.secondary.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
  }

  /// Pretty-print arguments when they are valid JSON; otherwise show them verbatim.
  private func prettyJSON(_ text: String) -> String {
    guard let value = try? JSONValue.parse(text, context: "node.arguments"),
          let data = try? JSONEncoder(.prettyPrinted).encode(value),
          let pretty = String(data: data, encoding: .utf8) else { return text }
    return pretty
  }
}

extension JSONEncoder {
  convenience init(_ formatting: OutputFormatting) {
    self.init()
    self.outputFormatting = formatting
  }
}
