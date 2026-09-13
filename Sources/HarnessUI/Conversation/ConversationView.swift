import HarnessKit
import SwiftUI

/// The transcript.
///
/// Renders `TranscriptEntry` values in order, so a PTC turn — one assistant message
/// that drives dozens of nested tool calls — draws as message → program tree → next
/// message rather than as an undifferentiated list of cards.
public struct ConversationView: View {
  @ObservedObject var session: SessionViewModel
  @State private var autoScroll = true

  public init(session: SessionViewModel) {
    self.session = session
  }

  public var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(session.transcript) { entry in
            TranscriptRow(entry: entry, session: session)
              .id(entry.id)
          }
          if !session.projection.streaming.isEmpty {
            StreamingRow(streaming: session.projection.streaming, session: session)
              .id("streaming")
          }
          if let error = session.errorMessage {
            ErrorBanner(message: error)
          }
          Color.clear
            .frame(height: 1)
            .id("bottom")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onChange(of: session.projection.eventCount) { _, _ in
        guard autoScroll else { return }
        withAnimation(.linear(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
      }
      .onChange(of: session.projection.streaming.text) { _, _ in
        guard autoScroll else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
      }
      .overlay(alignment: .bottomTrailing) {
        if !autoScroll {
          Button {
            autoScroll = true
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
          } label: {
            Label("Jump to latest", systemImage: "arrow.down.circle.fill")
              .labelStyle(.iconOnly)
              .font(.title2)
              .padding(6)
          }
          .buttonStyle(.plain)
          .padding(12)
        }
      }
      .onAppear {
        autoScroll = true
        proxy.scrollTo("bottom", anchor: .bottom)
      }
    }
  }
}

// MARK: - Rows

struct TranscriptRow: View {
  let entry: TranscriptEntry
  @ObservedObject var session: SessionViewModel

  var body: some View {
    switch entry {
    case .message(let message):
      MessageView(message: message, session: session)
    case .invocation(let invocation):
      ToolCardRenderer.card(for: invocation, session: session)
    case .program(let program):
      ProgramRunView(program: program, expanded: session.expandsPrograms)
    case .activityIndicator(let activity):
      ActivityRow(activity: activity)
    case .notice(_, let text):
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

/// The live, partial assistant turn.
struct StreamingRow: View {
  let streaming: StreamingState
  @ObservedObject var session: SessionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if session.showsReasoning, !streaming.reasoning.isEmpty {
        ReasoningBlock(text: streaming.reasoning, isStreaming: true)
      }
      if !streaming.text.isEmpty {
        MarkdownText(markdown: streaming.text)
          .textSelection(.enabled)
      }
      ForEach(streaming.pendingToolCalls) { call in
        HStack(spacing: 8) {
          Image(systemName: ToolCategory(name: call.name).symbolName)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(call.name)
              .font(.callout.weight(.medium))
            if !call.argumentsText.isEmpty {
              Text(call.argumentsText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
          Spacer()
          ProgressView().controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .padding(.leading, 2)
  }
}

struct ActivityRow: View {
  let activity: SessionActivity

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(activity.detail ?? activity.phase.displayName)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

struct ErrorBanner: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.callout)
        .textSelection(.enabled)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Message

/// One conversation message.
///
/// Injected context (system reminders, agent instructions, plugin reminders — the
/// second and third user messages of every real session) collapses by default: it is
/// not something the human typed, and the official transcripts drown in it otherwise.
struct MessageView: View {
  let message: ConversationMessage
  @ObservedObject var session: SessionViewModel
  @State private var expandedContext = false

  var body: some View {
    if message.role == .user, message.isInjectedContext {
      injectedContext
    } else {
      normalMessage
    }
  }

  private var injectedContext: some View {
    DisclosureGroup(isExpanded: $expandedContext) {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array((message.source?.sections ?? []).enumerated()), id: \.offset) { _, section in
          if let name = section.name {
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          }
          Text(section.text ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        if (message.source?.sections ?? []).isEmpty {
          Text(message.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      .padding(.top, 4)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "info.circle")
        Text(contextLabel)
          .font(.caption)
          .lineLimit(1)
      }
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  private var contextLabel: String {
    if let plugin = message.source?.plugin { return "Injected context · \(plugin)" }
    if let kind = message.source?.kind { return "Injected context · \(kind)" }
    return "Injected context"
  }

  private var normalMessage: some View {
    VStack(alignment: .leading, spacing: 8) {
      if session.showsReasoning, !message.reasoning.isEmpty {
        ReasoningBlock(text: message.reasoning, isStreaming: false)
      }
      if !message.text.isEmpty {
        MarkdownText(markdown: message.text)
          .textSelection(.enabled)
      }
      if !message.toolUses.isEmpty, message.text.isEmpty {
        // A pure tool-call message: the calls themselves are rendered as cards by the
        // transcript; keep the row quiet rather than repeating the names.
        EmptyView()
      }
      HStack(spacing: 8) {
        Label(message.role.rawValue.capitalized, systemImage: icon)
          .font(.caption2)
          .foregroundStyle(.tertiary)
        if let usage = message.usage, message.role == .assistant {
          Text(usageSummary(usage))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        if message.interrupted {
          Text("interrupted").font(.caption2).foregroundStyle(.orange)
        }
        if let time = message.time {
          Text(time, style: .time).font(.caption2).foregroundStyle(.tertiary)
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(background, in: RoundedRectangle(cornerRadius: 10))
  }

  private var icon: String {
    switch message.role {
    case .user: return "person"
    case .assistant: return "sparkles"
    case .system: return "gearshape"
    case .tool: return "wrench.and.screwdriver"
    }
  }

  private var background: some ShapeStyle {
    message.role == .user ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(Color.secondary.opacity(0.06))
  }

  private func usageSummary(_ usage: Usage) -> String {
    var parts: [String] = []
    if let input = usage.inputTokens { parts.append("in \(input)") }
    if let output = usage.outputTokens { parts.append("out \(output)") }
    if let reasoning = usage.reasoningTokens, reasoning > 0 { parts.append("reasoning \(reasoning)") }
    if let cache = usage.cacheReadTokens, cache > 0 { parts.append("cache \(cache)") }
    return parts.joined(separator: " · ")
  }
}

/// A reasoning block. Collapsed by default: reasoning dominated a real session's event
/// stream (12,953 of 23,631 events) and buries the actual answer.
struct ReasoningBlock: View {
  let text: String
  let isStreaming: Bool
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      Text(text)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.top, 4)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "brain")
        Text(isStreaming ? "Reasoning…" : "Reasoning")
          .font(.caption)
        if !expanded {
          Text(summary)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
  }

  private var summary: String {
    let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
    return firstLine.count > 90 ? String(firstLine.prefix(90)) + "…" : firstLine
  }
}
