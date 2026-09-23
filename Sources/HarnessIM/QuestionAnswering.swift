import Foundation
import HarnessKit

/// One question the harness is waiting on.
///
/// The harness asks through the same waterfall carrier as approvals but with a different
/// answer shape, so this is a sibling of `PendingApproval` rather than a variant of it: the
/// two share routing, not payloads.
public struct PendingQuestion: Sendable, Equatable {
  public var eventID: String
  public var sessionID: String
  public var isBorrowed: Bool
  public var items: [QuestionItem]
  public var requestedAt: Date

  public init(
    eventID: String,
    sessionID: String,
    isBorrowed: Bool,
    items: [QuestionItem],
    requestedAt: Date = Date()
  ) {
    self.eventID = eventID
    self.sessionID = sessionID
    self.isBorrowed = isBorrowed
    self.items = items
    self.requestedAt = requestedAt
  }
}

/// One question inside a request, with the choices it offers.
public struct QuestionItem: Sendable, Equatable, Identifiable {
  public var id: String
  public var header: String?
  public var question: String
  public var detail: String?
  /// The choices, in the order the host declared them, each with the line that explains it.
  ///
  /// The order is the protocol: `/answer 2` means the second one, so it is preserved verbatim.
  /// `HarnessKit.UserQuestion.Option` rather than a second definition of the same pair: the desktop
  /// sheet already renders that `description` under that `label`, and a phone message that dropped
  /// it asked the user to choose between bare labels.
  public var options: [UserQuestion.Option]
  /// The labels alone — what `/answer 2` matches against and what the host is sent back.
  ///
  /// Derived, never stored beside `options`: two arrays of the same length are a bug waiting for the
  /// first entry to be filtered out.
  public var optionLabels: [String] { options.map(\.label) }
  public var multiSelect: Bool
  /// Set when the asker declared a plan review: this option approves the plan and every other
  /// option declines it. Named, never positional — the host rejects an approval naming nothing.
  public var approveLabel: String?

  public init(
    id: String,
    header: String? = nil,
    question: String,
    detail: String? = nil,
    options: [UserQuestion.Option] = [],
    multiSelect: Bool = false,
    approveLabel: String? = nil
  ) {
    self.id = id
    self.header = header
    self.question = question
    self.detail = detail
    self.options = options
    self.multiSelect = multiSelect
    self.approveLabel = approveLabel
  }

  /// Decode one entry of `user-questions/request`. Returns nil for an entry with no id or no
  /// question text: an unanswerable row would make the whole payload unsubmittable.
  public init?(json: JSONValue) {
    guard let id = json["id"]?.stringValue, !id.isEmpty,
          let question = json["question"]?.stringValue, !question.isEmpty else { return nil }
    self.id = id
    self.header = json["header"]?.stringValue
    self.question = question
    self.detail = json["detail"]?.stringValue
    // An option the host left unexplained is an ordinary option, not a malformed one: the schema
    // makes `description` optional, and most choices do not carry one.
    self.options = (json["options"]?.arrayValue ?? []).compactMap { value in
      guard let label = value["label"]?.stringValue else { return nil }
      let description = value["description"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return UserQuestion.Option(
        label: label,
        description: (description?.isEmpty == false ? description : nil)
      )
    }
    self.multiSelect = json["multiSelect"]?.boolValue ?? false
    self.approveLabel = json.path("intent.kind")?.stringValue == "plan-review"
      ? json.path("intent.approve")?.stringValue
      : nil
  }
}

/// What the phone is sent when the harness asks a question, and how its reply becomes answers.
///
/// Both halves are pure so the grammar — which is the only thing standing between a phone
/// keyboard and a wrong multi-select — is testable without a harness.
public enum QuestionPrompt {
  /// How much of a question's `detail` the phone is shown.
  static let detailLimit = 200
  /// A plan review's detail *is* the plan under review, so it gets room to be read: asking the
  /// user to approve a plan they can only see the first 200 characters of is asking nothing.
  /// The outbound side chunks long replies, so this is a readability bound, not a wire one.
  static let planDetailLimit = 2000

  /// Decode a `user-questions/request` payload.
  ///
  /// - Returns: nil when the payload carries no answerable question, which is the honest
  ///   outcome: forwarding an empty request would ask the user to reply to nothing.
  public static func decode(
    _ request: JSONValue,
    eventID: String,
    sessionID: String,
    isBorrowed: Bool
  ) -> PendingQuestion? {
    let items = (request["questions"]?.arrayValue ?? []).compactMap(QuestionItem.init(json:))
    guard !items.isEmpty else { return nil }
    return PendingQuestion(
      eventID: eventID, sessionID: sessionID, isBorrowed: isBorrowed, items: items
    )
  }

  /// The message the phone receives.
  public static func text(for question: PendingQuestion, queuePosition: Int = 1) -> String {
    let planReview = question.items.count == 1
      && !(question.items.first?.approveLabel ?? "").isEmpty
    // A plan review is not a question with an answer: it is a plan to be read and judged, so
    // the message says so from its first line.
    var lines = [planReview ? "📋 harness 提交了计划，等你定夺" : "❓ harness 需要你回答"]
    if question.isBorrowed, !question.sessionID.isEmpty {
      lines.append("（来自桌面会话 \(shortSessionID(question.sessionID))）")
    }
    if queuePosition > 1 {
      lines.append("（还有 \(queuePosition - 1) 条在你之后排队）")
    }
    lines.append("")

    let many = question.items.count > 1
    for (offset, item) in question.items.enumerated() {
      var heading = many ? "第 \(offset + 1) 题" : "问题"
      if let header = item.header, !header.isEmpty { heading += "（\(header)）" }
      lines.append("\(heading)：\(item.question)")
      if let detail = item.detail, !detail.isEmpty {
        let limit = item.approveLabel == nil ? detailLimit : planDetailLimit
        lines.append("   \(RemoteSessionHistory.clip(detail, to: limit))")
      }
      for (index, option) in item.options.enumerated() {
        lines.append("   \(index + 1)) \(option.label)")
        // The explanation is half of what a choice means — the sheet on the desk shows it under the
        // label, so a phone message that showed only labels made the user answer blind. Indented
        // rather than run together on one line, which is the shape the GUI uses and the shape that
        // keeps a four-option question readable. Clipped by the same rule as the question's own
        // detail: it is a sentence to read, not the question itself.
        if let description = option.description, !description.isEmpty {
          lines.append("      \(RemoteSessionHistory.clip(description, to: detailLimit))")
        }
      }
      if item.options.isEmpty {
        lines.append("   （这题没有选项，回答一段话即可）")
      } else if item.multiSelect {
        lines.append("   （可多选，用逗号：/answer 1,3）")
      }
      lines.append("")
    }

    if planReview {
      lines.append("这是计划评审，三种回复：")
      lines.append("「批准」— 同意，退出 plan mode 开始执行；")
      lines.append("「拒绝」— 不同意，让它留在 plan mode 继续改；")
      lines.append("「说 你的意见」— 把修改意见带回去（直接发意见也算）。")
    }
    if question.items.count == 1 {
      lines.append("回复 /answer 1 选第 1 项；没有选项时 /answer 你的答复。")
    } else {
      lines.append("回复 /answer 1 | 2 —— 用 | 按题号顺序分段，同一题多选用逗号。")
      lines.append("想跳过某一题，该段写 -。")
    }
    return lines.joined(separator: "\n")
  }

  static func shortSessionID(_ sessionID: String) -> String {
    let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "未知" : String(trimmed.prefix(8))
  }
}

/// Turns one `/answer …` argument into the `answers` payload the host expects.
public enum QuestionAnswerParser {
  public enum Outcome: Sendable, Equatable {
    case answers(JSONValue)
    /// Understood as an answer attempt but unusable; the text is sent back to the phone.
    case problem(String)
  }

  /// Parse the argument of `/answer`, in the grammar `QuestionPrompt.text` teaches.
  ///
  /// Segment-per-question, comma-per-multi-select: positional rather than id-based because a
  /// phone user answers what they just read, in the order they read it.
  public static func parse(_ text: String, for question: PendingQuestion) -> Outcome {
    let segments = text.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    if question.items.count > 1, segments.count != question.items.count {
      return .problem("这里有 \(question.items.count) 个问题，请按题号用 | 分段回答，例如 /answer 1 | 2；跳过写 -。")
    }
    let expanded = question.items.count == 1 ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : segments

    var answers: [JSONValue] = []
    for (item, segment) in zip(question.items, expanded) {
      switch answerObject(for: item, segment: segment) {
      case .problem(let message):
        return .problem(message)
      case .value(let value):
        answers.append(value)
      }
    }
    return .answers(.object(["answers": .array(answers)]))
  }

  /// One question's answer payload, or why it could not be built.
  private enum One {
    case value(JSONValue)
    case problem(String)
  }

  /// Answer one question from its own segment.
  private static func answerObject(for item: QuestionItem, segment: String) -> One {
    let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "-" || trimmed == "跳过" || trimmed.isEmpty {
      return .value(.object(["id": .string(item.id), "selected": .array([])]))
    }
    if item.options.isEmpty {
      return .value(.object([
        "id": .string(item.id),
        "selected": .array([]),
        "custom": .string(trimmed),
      ]))
    }

    let tokens = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !tokens.isEmpty else {
      return .problem("第 \(item.question) 题没看懂，请回复 /answer 1 这种选项编号。")
    }
    if !item.multiSelect, tokens.count > 1 {
      return .problem("「\(item.question)」只能选一个，回复一个编号即可。")
    }

    var selected: [String] = []
    let labels = item.optionLabels
    for token in tokens {
      if let index = Int(token), index >= 1, index <= labels.count {
        selected.append(labels[index - 1])
      } else if labels.contains(token) {
        // The full label is also accepted: it is what a user copies from the question.
        selected.append(token)
      } else {
        let options = labels.enumerated()
          .map { "\($0.offset + 1)) \($0.element)" }
          .joined(separator: "  ")
        return .problem("「\(item.question)」没有「\(token)」这个选项。可选：\(options)")
      }
    }
    return .value(.object([
      "id": .string(item.id),
      "selected": .array(selected.map { .string($0) }),
    ]))
  }
}
