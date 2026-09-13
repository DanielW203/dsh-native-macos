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
  /// Option labels in the order the host declared them. The order is the protocol: `/answer 2`
  /// means the second label, so it is preserved verbatim.
  public var options: [String]
  public var multiSelect: Bool
  /// Set when the asker declared a plan review: this option approves the plan and every other
  /// option declines it. Named, never positional — the host rejects an approval naming nothing.
  public var approveLabel: String?

  public init(
    id: String,
    header: String? = nil,
    question: String,
    detail: String? = nil,
    options: [String] = [],
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
    self.options = (json["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }
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
        lines.append("   \(index + 1)) \(option)")
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
    for token in tokens {
      if let index = Int(token), index >= 1, index <= item.options.count {
        selected.append(item.options[index - 1])
      } else if item.options.contains(token) {
        // The full label is also accepted: it is what a user copies from the question.
        selected.append(token)
      } else {
        let options = item.options.enumerated()
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
