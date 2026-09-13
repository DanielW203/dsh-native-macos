import Foundation

/// How chatty the channel is while it collects a batch.
public enum AckPolicy: String, Sendable, Codable, CaseIterable {
  /// Answer every collected message. Useful while debugging, noisy in daily use.
  case everyMessage
  /// One acknowledgement when the first item of a batch lands, then silence until the
  /// trigger. The default: the user learns the channel is collecting without being
  /// pinged for every photo.
  case oncePerBatch
  /// Never acknowledge; only the submission result is sent.
  case silent
}

/// The channel's user-facing configuration.
///
/// Phrases are validated rather than free-form: a phrase that starts with `/` would
/// shadow a harness command, and identical trigger/cancel phrases would make one of them
/// unreachable. Both are rejected in the UI instead of failing at runtime.
public struct ChannelConfig: Sendable, Equatable, Codable {
  public var triggerPhrase: String
  public var cancelPhrase: String
  public var ackPolicy: AckPolicy
  /// Working directory handed to `session/create`. Nil means "not chosen yet" and the
  /// channel refuses to submit rather than guessing a directory.
  ///
  /// The path is what the user picks and what the reply watcher uses to locate the session
  /// log; it is **not** what the session is created against — see `workspaceID`.
  public var workspacePath: String?
  /// The harness's own workspace registration for `workspacePath`.
  ///
  /// `session/create` only attaches a session to a workspace when it is addressed by
  /// `workspaceId`; creating one with `cwd` leaves the session unaccounted for, and a session
  /// no workspace accounts for never appears in the harness sidebar. Cached here after a
  /// successful `workspace/create`, and nil for a config written before this field existed —
  /// in which case the service registers the path on first use.
  public var workspaceID: String?
  public var agentPreset: String?
  /// Empty means "only the bot owner may talk to it".
  public var allowedSenders: [String]
  public var maxBatchItems: Int
  public var maxBatchAttachments: Int
  public var maxBatchAttachmentBytes: Int
  public var replyChunkCharacters: Int

  public init(
    triggerPhrase: String = "开始",
    cancelPhrase: String = "取消",
    ackPolicy: AckPolicy = .oncePerBatch,
    workspacePath: String? = nil,
    workspaceID: String? = nil,
    agentPreset: String? = nil,
    allowedSenders: [String] = [],
    maxBatchItems: Int = 20,
    maxBatchAttachments: Int = 20,
    maxBatchAttachmentBytes: Int = ILinkProtocol.maxBatchBytes,
    replyChunkCharacters: Int = ILinkProtocol.maxMessageCharacters
  ) {
    self.triggerPhrase = triggerPhrase
    self.cancelPhrase = cancelPhrase
    self.ackPolicy = ackPolicy
    self.workspacePath = workspacePath
    self.workspaceID = workspaceID
    self.agentPreset = agentPreset
    self.allowedSenders = allowedSenders
    self.maxBatchItems = maxBatchItems
    self.maxBatchAttachments = maxBatchAttachments
    self.maxBatchAttachmentBytes = maxBatchAttachmentBytes
    self.replyChunkCharacters = replyChunkCharacters
  }

  /// Human-readable problems with the current phrases; empty means valid.
  public func validationIssues() -> [String] {
    var issues: [String] = []
    let trigger = triggerPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
    let cancel = cancelPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
    if trigger.isEmpty { issues.append("触发词不能为空") }
    if cancel.isEmpty { issues.append("取消词不能为空") }
    if trigger.hasPrefix("/") { issues.append("触发词不能以 / 开头（会与 harness 命令冲突）") }
    if cancel.hasPrefix("/") { issues.append("取消词不能以 / 开头（会与 harness 命令冲突）") }
    if !trigger.isEmpty && trigger == cancel { issues.append("触发词与取消词不能相同") }
    if maxBatchItems <= 0 { issues.append("单批消息上限必须为正数") }
    if maxBatchAttachments <= 0 { issues.append("单批附件上限必须为正数") }
    if maxBatchAttachmentBytes <= 0 { issues.append("单批附件容量上限必须为正数") }
    if replyChunkCharacters <= 0 { issues.append("回复分段长度必须为正数") }
    return issues
  }

  public var isValid: Bool { validationIssues().isEmpty }

  /// Whether a message body is the trigger phrase.
  ///
  /// Comparison is on the trimmed body, so a phrase typed with trailing spaces (routine
  /// on a phone keyboard) still triggers, while a sentence that merely contains the
  /// phrase does not.
  public func isTrigger(_ text: String) -> Bool {
    matches(text, phrase: triggerPhrase)
  }

  public func isCancel(_ text: String) -> Bool {
    matches(text, phrase: cancelPhrase)
  }

  func matches(_ text: String, phrase: String) -> Bool {
    let needle = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty, !needle.hasPrefix("/") else { return false }
    return text.trimmingCharacters(in: .whitespacesAndNewlines) == needle
  }

  /// Whether a sender may use the channel. An empty allowlist means owner-only, which
  /// the service enforces by comparing against the bound account's owner id.
  public func allowsSender(_ sender: String, owner: String?) -> Bool {
    if !allowedSenders.isEmpty { return allowedSenders.contains(sender) }
    return owner != nil && sender == owner
  }
}

/// One collected message.
public struct BatchItem: Sendable, Equatable, Codable {
  public let messageID: String
  public let text: String?
  public let attachments: [BatchAttachment]
  public let receivedAt: Date

  public init(messageID: String, text: String?, attachments: [BatchAttachment], receivedAt: Date) {
    self.messageID = messageID
    self.text = text
    self.attachments = attachments
    self.receivedAt = receivedAt
  }
}

/// A buffered attachment, described only by what the prompt needs.
public struct BatchAttachment: Sendable, Equatable, Codable {
  public let kind: WeChatAttachment.Kind
  public let name: String
  public let byteCount: Int?

  public init(kind: WeChatAttachment.Kind, name: String, byteCount: Int?) {
    self.kind = kind
    self.name = name
    self.byteCount = byteCount
  }
}

/// Counts describing what is currently held.
public struct BatchSnapshot: Sendable, Equatable, Codable {
  public let items: [BatchItem]

  public init(items: [BatchItem]) { self.items = items }

  public var messageCount: Int { items.count }
  public var attachmentCount: Int { items.reduce(0) { $0 + $1.attachments.count } }
  public var attachmentBytes: Int { items.reduce(0) { $0 + $1.attachments.reduce(0) { $0 + ($1.byteCount ?? 0) } } }
  public var isEmpty: Bool { items.isEmpty }
  public var textCount: Int { items.filter { ($0.text?.isEmpty == false) }.count }
}

/// A batch that has been handed to the submitter.
public struct BatchSubmission: Sendable, Equatable {
  public let items: [BatchItem]

  public init(items: [BatchItem]) { self.items = items }

  /// All text in arrival order, blank-line separated.
  public var mergedText: String {
    items.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  public var attachments: [BatchAttachment] {
    items.flatMap(\.attachments)
  }

  public var snapshot: BatchSnapshot { BatchSnapshot(items: items) }
}

/// What one inbound message did to the buffer.
public enum BatchIngestOutcome: Sendable, Equatable {
  /// Stored and waiting. The snapshot drives the (optional) acknowledgement.
  case buffered(BatchSnapshot)
  /// The trigger phrase arrived with content waiting: submit now.
  case trigger(BatchSubmission)
  /// The cancel phrase cleared a non-empty buffer.
  case cancelled(dropped: Int)
  /// Nothing collectable in this message.
  case ignored
  /// The trigger/cancel phrase arrived with nothing buffered.
  case emptyBatch
  /// Rejected or informational; the string is meant for the chat.
  case notice(String)
}

/// Per-conversation collection of inbound WeChat content.
///
/// Deliberately a plain, synchronous, dependency-free state machine: all of the decisions
/// the feature rests on (what counts as a trigger, when a batch is full, what order text
/// lands in) are testable without a network, a clock, or the harness.
public final class InboundBatchBuffer {
  public let key: String
  public private(set) var config: ChannelConfig
  public private(set) var items: [BatchItem]

  public init(key: String, config: ChannelConfig, items: [BatchItem] = []) {
    self.key = key
    self.config = config
    self.items = items
  }

  public var snapshot: BatchSnapshot { BatchSnapshot(items: items) }
  public var isEmpty: Bool { items.isEmpty }

  public func updateConfig(_ config: ChannelConfig) { self.config = config }

  /// Replace the held items wholesale — used when restoring persisted state.
  public func restore(items: [BatchItem]) { self.items = items }

  /// Fold one inbound message into the buffer.
  ///
  /// Order of decisions matters and mirrors the feature's contract: cancel beats trigger,
  /// trigger beats collection, and a rejected message leaves the buffer untouched so a
  /// user who sends one photo too many does not lose the batch.
  @discardableResult
  public func ingest(
    text: String?,
    attachments: [BatchAttachment],
    messageID: String,
    at receivedAt: Date = Date()
  ) -> BatchIngestOutcome {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let hasText = !trimmed.isEmpty

    if hasText, config.isCancel(trimmed) {
      guard !items.isEmpty else { return .emptyBatch }
      let dropped = items.count
      items.removeAll()
      return .cancelled(dropped: dropped)
    }

    if hasText, config.isTrigger(trimmed) {
      guard !items.isEmpty else { return .emptyBatch }
      return .trigger(BatchSubmission(items: items))
    }

    guard hasText || !attachments.isEmpty else { return .ignored }

    let prospectiveMessages = items.count + 1
    if prospectiveMessages > config.maxBatchItems {
      return .notice("本批已收满 \(config.maxBatchItems) 条消息，这条未收录。请先发「\(config.triggerPhrase)」提交，或发「\(config.cancelPhrase)」清空。")
    }
    let prospectiveAttachments = snapshot.attachmentCount + attachments.count
    if prospectiveAttachments > config.maxBatchAttachments {
      return .notice("本批附件已达上限 \(config.maxBatchAttachments) 个，这条未收录。请先发「\(config.triggerPhrase)」提交，或发「\(config.cancelPhrase)」清空。")
    }
    let prospectiveBytes = snapshot.attachmentBytes + attachments.reduce(0) { $0 + ($1.byteCount ?? 0) }
    if prospectiveBytes > config.maxBatchAttachmentBytes {
      let limit = ByteCountFormatter.string(fromByteCount: Int64(config.maxBatchAttachmentBytes), countStyle: .file)
      return .notice("本批附件总量已超过 \(limit)，这条未收录。请先发「\(config.triggerPhrase)」提交，或发「\(config.cancelPhrase)」清空。")
    }

    items.append(BatchItem(
      messageID: messageID,
      text: hasText ? trimmed : nil,
      attachments: attachments,
      receivedAt: receivedAt
    ))
    return .buffered(snapshot)
  }

  /// Drop everything and report how many messages went away.
  @discardableResult
  public func cancel() -> Int {
    let dropped = items.count
    items.removeAll()
    return dropped
  }

  /// Take the current batch and clear the buffer.
  ///
  /// Separate from `ingest` so a submission that fails to reach the harness can be
  /// retried by the service while the buffer's ownership stays unambiguous.
  public func takeSubmission() -> BatchSubmission? {
    guard !items.isEmpty else { return nil }
    let submission = BatchSubmission(items: items)
    items.removeAll()
    return submission
  }
}

/// The text block one batch becomes.
///
/// Text is presented in arrival order with explicit `[消息 N]` markers, because the model
/// must be able to tell "two separate thoughts" from "one thought split by the phone's
/// input box" — the same reason the plugin's own batch mode labels its sections.
public enum BatchPrompt {
  public static let header = "以下是用户通过微信分批发送的内容，请按顺序作为同一次输入统一处理。"

  public static func composeText(_ submission: BatchSubmission, stagedPaths: [String: String] = [:]) -> String {
    var sections: [String] = [header]
    var index = 0
    for item in submission.items {
      guard let text = item.text, !text.isEmpty else { continue }
      index += 1
      sections.append("[消息 \(index)]\n\(text)")
    }
    let manifest = attachmentManifest(submission.attachments, stagedPaths: stagedPaths)
    if !manifest.isEmpty { sections.append(manifest) }
    return sections.joined(separator: "\n\n")
  }

  /// Describe attachments the same way the reference integration does: a plain list the
  /// model can read, whether the bytes arrived as real attachments or as workspace files.
  static func attachmentManifest(_ attachments: [BatchAttachment], stagedPaths: [String: String]) -> String {
    guard !attachments.isEmpty else { return "" }
    var lines = ["[附件]"]
    for attachment in attachments {
      var parts: [String] = [attachment.kind == .image ? "图片" : "文件"]
      if let bytes = attachment.byteCount {
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
      }
      if let path = stagedPaths[attachment.name] {
        parts.append("路径：\(path)")
      } else {
        parts.append("已作为本条消息的附件一并提供")
      }
      lines.append("- \(attachment.name)（\(parts.joined(separator: "，"))）")
    }
    return lines.joined(separator: "\n")
  }
}
