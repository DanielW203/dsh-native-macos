import HarnessKit
import SwiftUI

/// The input area.
///
/// Handles the three things a harness composer has to do beyond typing text:
/// slash commands, `@` references, and steering a turn that is already running.
public struct ComposerView: View {
  @ObservedObject var session: SessionViewModel
  @FocusState private var focused: Bool
  @State private var showsCommandMenu = false

  /// Slash commands the harness understands. These are commands of the *runtime*, not
  /// of this app: the text is passed through verbatim so `dsh` supplies the behaviour.
  private static let commands: [(name: String, summary: String)] = [
    ("/free-search-engine", "Choose the web-search engine"),
    ("/generate-cards", "Turn the conversation into knowledge cards"),
    ("/split-topics", "Split the conversation into topics"),
    ("/regenerate-card", "Regenerate the referenced card"),
    ("/help", "List available commands"),
  ]

  public init(session: SessionViewModel) {
    self.session = session
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !session.pendingAttachments.isEmpty {
        attachmentStrip
      }
      HStack(alignment: .bottom, spacing: 8) {
        Button {
          showsCommandMenu.toggle()
        } label: {
          Image(systemName: "slash.circle")
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showsCommandMenu, arrowEdge: .top) {
          commandMenu
        }
        .help("Slash commands")

        TextField(hint, text: $session.composerText, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.body)
          .lineLimit(1...12)
          .focused($focused)
          .onSubmit {
            Task { await session.send() }
          }
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 1))

        if session.isRunning {
          Button {
            Task { await session.cancel() }
          } label: {
            Image(systemName: "stop.circle.fill")
              .font(.title2)
              .foregroundStyle(.red)
          }
          .buttonStyle(.borderless)
          .help("Cancel the running turn")
        }

        Button {
          Task { await session.send() }
        } label: {
          Image(systemName: session.isRunning ? "arrow.up.circle.fill" : "paperplane.circle.fill")
            .font(.title2)
        }
        .buttonStyle(.borderless)
        .disabled(!canSend)
        .help(session.isRunning ? "Steer the running turn" : "Send")
        .keyboardShortcut(.return, modifiers: [.command])
      }

      HStack(spacing: 8) {
        Text(session.cwd)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.head)
        Spacer()
        if session.isRunning {
          Text("Turn \(session.projection.currentTurn ?? 0) · step \(session.projection.currentStep ?? 0)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        Text(hintShort)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
    .onAppear { focused = true }
  }

  private var canSend: Bool {
    !session.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.pendingAttachments.isEmpty
  }

  private var hint: String {
    session.isRunning ? "Steer the running turn…" : "Ask, or / for commands, @ to reference"
  }

  private var hintShort: String {
    session.isRunning ? "⏎ steers · ⌘⏎ sends" : "⏎ to send · ⇧⏎ for a new line"
  }

  private var attachmentStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(session.pendingAttachments) { attachment in
          HStack(spacing: 4) {
            Image(systemName: "paperclip")
            Text(attachment.name ?? attachment.attachmentId)
              .font(.caption)
              .lineLimit(1)
            Button {
              session.pendingAttachments.removeAll { $0.id == attachment.id }
            } label: {
              Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.borderless)
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
        }
      }
    }
  }

  private var commandMenu: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Self.commands, id: \.name) { command in
        Button {
          session.composerText = command.name + " "
          showsCommandMenu = false
          focused = true
        } label: {
          VStack(alignment: .leading, spacing: 1) {
            Text(command.name).font(.callout.monospaced())
            Text(command.summary).font(.caption2).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
      }
    }
    .padding(6)
    .frame(width: 320)
  }
}
