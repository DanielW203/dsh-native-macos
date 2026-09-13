import HarnessKit
import SwiftUI

/// Approvals, questions and plan reviews.
///
/// All three stall the run until answered, so they share one sheet rather than three
/// scattered affordances: a tool approval, an `ask_user_question` prompt and an
/// `exit_plan_mode` review are the same interaction from the engine's point of view
/// (an `approval/asked` event waiting on `POST`), and only the payload differs.
public struct ApprovalSheet: View {
  public let record: ApprovalRecord
  @ObservedObject var session: SessionViewModel
  let onDismiss: () -> Void

  @State private var freeText: String = ""
  @State private var selectedOptions: [String: Set<String>] = [:]

  public init(record: ApprovalRecord, session: SessionViewModel, onDismiss: @escaping () -> Void) {
    self.record = record
    self.session = session
    self.onDismiss = onDismiss
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .padding(18)
    .frame(minWidth: 520, idealWidth: 560)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(color)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        if let callId = record.request.callId {
          Text(callId)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospaced()
        }
      }
      Spacer()
    }
  }

  private var icon: String {
    switch record.request.kind {
    case .tool: return "hand.raised.fill"
    case .question: return "questionmark.bubble.fill"
    case .plan: return "map.fill"
    }
  }

  private var color: Color {
    switch record.request.kind {
    case .tool: return .orange
    case .question: return .accentColor
    case .plan: return .purple
    }
  }

  private var title: String {
    switch record.request.kind {
    case .tool: return "Approve \(record.request.toolName)?"
    case .question: return record.request.toolName == "exit_plan_mode" ? "Review plan" : "The model is asking"
    case .plan: return "Review plan"
    }
  }

  @ViewBuilder
  private var content: some View {
    switch record.request.kind {
    case .question:
      questionContent
    case .plan:
      planContent
    case .tool:
      toolContent
    }
  }

  private var toolContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !record.request.reason.isEmpty {
        Text(record.request.reason)
          .font(.callout)
      }
      if let callId = record.request.callId,
         let invocation = session.invocations.first(where: { $0.id == callId }) {
        Text(invocation.argumentsText)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
      }
    }
  }

  private var questionContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(record.request.questions) { question in
          VStack(alignment: .leading, spacing: 6) {
            if let header = question.header {
              Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(question.question).font(.callout)
            if !question.options.isEmpty {
              ForEach(question.options) { option in
                Button {
                  toggle(question: question, option: option.label)
                } label: {
                  HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isSelected(question: question, option: option.label)
                          ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                          : (question.multiSelect ? "square" : "circle"))
                      .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                      Text(option.label).font(.callout)
                      if let description = option.description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                      }
                    }
                    Spacer()
                  }
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
              }
            }
          }
        }
        if record.request.questions.contains(where: { $0.options.isEmpty }) {
          TextField("Your answer", text: $freeText, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...8)
        }
      }
    }
    .frame(maxHeight: 360)
  }

  private var planContent: some View {
    ScrollView {
      if let plan = session.projection.plan.plan, !plan.isEmpty {
        MarkdownText(markdown: plan)
          .textSelection(.enabled)
      } else if let callId = record.request.callId,
                let invocation = session.invocations.first(where: { $0.id == callId }),
                let plan = invocation.arguments["plan"]?.stringValue {
        MarkdownText(markdown: plan).textSelection(.enabled)
      } else {
        Text(record.request.reason.isEmpty ? "The model submitted a plan." : record.request.reason)
      }
      TextField("Feedback (optional — used when you keep planning)", text: $freeText, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(2...6)
        .padding(.top, 10)
    }
    .frame(maxHeight: 420)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button("Dismiss") { onDismiss() }
      Spacer()
      switch record.request.kind {
      case .tool:
        Button("Deny") {
          Task { await session.deny(record); onDismiss() }
        }
        .keyboardShortcut(.escape)
        Button("Approve") {
          Task { await session.approve(record); onDismiss() }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      case .question:
        Button("Cancel") {
          Task {
            await session.answer(record, answers: [:])
            onDismiss()
          }
        }
        .keyboardShortcut(.escape)
        Button("Answer") {
          Task { await session.answer(record, answers: buildAnswers()); onDismiss() }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!hasAnyAnswer)
      case .plan:
        Button("Keep planning") {
          Task { await session.reviewPlan(record, approved: false, feedback: freeText.isEmpty ? nil : freeText); onDismiss() }
        }
        .keyboardShortcut(.escape)
        Button("Approve plan") {
          Task { await session.reviewPlan(record, approved: true); onDismiss() }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      }
    }
  }

  // MARK: Selection helpers

  private func toggle(question: UserQuestion, option: String) {
    var current = selectedOptions[question.id] ?? []
    if question.multiSelect {
      if current.contains(option) { current.remove(option) } else { current.insert(option) }
    } else if current.contains(option) {
      // Single-select: clicking the chosen option clears it.
      current.removeAll()
    } else {
      current = [option]
    }
    selectedOptions[question.id] = current
  }

  private func isSelected(question: UserQuestion, option: String) -> Bool {
    selectedOptions[question.id]?.contains(option) ?? false
  }

  private var hasAnyAnswer: Bool {
    !selectedOptions.isEmpty || !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func buildAnswers() -> [String: QuestionAnswer] {
    var answers: [String: QuestionAnswer] = [:]
    for question in record.request.questions {
      let selected = Array(selectedOptions[question.id] ?? [])
      if selected.isEmpty {
        let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { answers[question.id] = QuestionAnswer(selected: [], freeText: text) }
      } else {
        answers[question.id] = QuestionAnswer(selected: selected, freeText: nil)
      }
    }
    // A question with no options at all uses the free-text field.
    if answers.isEmpty, !freeText.isEmpty {
      for question in record.request.questions where question.options.isEmpty {
        answers[question.id] = QuestionAnswer(selected: [], freeText: freeText)
      }
    }
    return answers
  }
}
