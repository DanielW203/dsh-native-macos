import Foundation
import XCTest

@testable import HarnessIM

/// The buffering rules are the whole feature: they decide when the harness is bothered
/// and in what order the user's words reach it. Every rule is asserted here because the
/// service around them is network-bound and hard to test end to end.
final class InboundBatchBufferTests: XCTestCase {
  private func attachment(_ name: String, kind: WeChatAttachment.Kind = .file, bytes: Int? = nil) -> BatchAttachment {
    BatchAttachment(kind: kind, name: name, byteCount: bytes)
  }

  func testBuffersTextInArrivalOrder() {
    let buffer = InboundBatchBuffer(key: "direct:a", config: ChannelConfig())
    XCTAssertEqual(buffer.ingest(text: "第一段", attachments: [], messageID: "1"),
                   .buffered(BatchSnapshot(items: buffer.items)))
    buffer.ingest(text: "第二段", attachments: [], messageID: "2")
    XCTAssertEqual(buffer.snapshot.messageCount, 2)
    let submission = buffer.takeSubmission()
    XCTAssertEqual(submission?.mergedText, "第一段\n\n第二段")
  }

  func testTriggerWithoutContentReportsEmptyBatch() {
    let buffer = InboundBatchBuffer(key: "direct:a", config: ChannelConfig())
    XCTAssertEqual(buffer.ingest(text: "开始", attachments: [], messageID: "1"), .emptyBatch)
    XCTAssertTrue(buffer.isEmpty)
  }

  func testTriggerSubmitsEverythingCollected() {
    let buffer = InboundBatchBuffer(key: "direct:a", config: ChannelConfig())
    buffer.ingest(text: "看这个", attachments: [attachment("report.pdf", bytes: 100)], messageID: "1")
    buffer.ingest(text: nil, attachments: [attachment("image", kind: .image)], messageID: "2")

    guard case .trigger(let submission) = buffer.ingest(text: " 开始 ", attachments: [], messageID: "3") else {
      return XCTFail("expected the trigger phrase to submit")
    }
    XCTAssertEqual(submission.items.count, 2)
    XCTAssertEqual(submission.attachments.map(\.name), ["report.pdf", "image"])
    // The trigger message itself is not content.
    XCTAssertEqual(submission.mergedText, "看这个")

    // Taking the submission is what clears the buffer, so a failed hand-off can be retried.
    XCTAssertNotNil(buffer.takeSubmission())
    XCTAssertNil(buffer.takeSubmission())
  }

  func testCancelDropsContentAndReportsCount() {
    let buffer = InboundBatchBuffer(key: "direct:a", config: ChannelConfig())
    buffer.ingest(text: "一", attachments: [], messageID: "1")
    buffer.ingest(text: "二", attachments: [], messageID: "2")
    XCTAssertEqual(buffer.ingest(text: "取消", attachments: [], messageID: "3"), .cancelled(dropped: 2))
    XCTAssertTrue(buffer.isEmpty)
    XCTAssertEqual(buffer.ingest(text: "取消", attachments: [], messageID: "4"), .emptyBatch)
  }

  func testEmptyMessageIsIgnored() {
    let buffer = InboundBatchBuffer(key: "direct:a", config: ChannelConfig())
    XCTAssertEqual(buffer.ingest(text: "   ", attachments: [], messageID: "1"), .ignored)
    XCTAssertTrue(buffer.isEmpty)
  }

  func testMessageCapRejectsWithoutDestroyingTheBatch() {
    let config = ChannelConfig(maxBatchItems: 2)
    let buffer = InboundBatchBuffer(key: "direct:a", config: config)
    buffer.ingest(text: "一", attachments: [], messageID: "1")
    buffer.ingest(text: "二", attachments: [], messageID: "2")

    guard case .notice = buffer.ingest(text: "三", attachments: [], messageID: "3") else {
      return XCTFail("expected the third message to be refused")
    }
    // The two accepted messages survive: one photo too many must not lose the batch.
    XCTAssertEqual(buffer.snapshot.messageCount, 2)
  }

  func testAttachmentCountCap() {
    let config = ChannelConfig(maxBatchAttachments: 1)
    let buffer = InboundBatchBuffer(key: "direct:a", config: config)
    buffer.ingest(text: nil, attachments: [attachment("a.pdf")], messageID: "1")
    guard case .notice = buffer.ingest(text: nil, attachments: [attachment("b.pdf")], messageID: "2") else {
      return XCTFail("expected the second attachment to be refused")
    }
    XCTAssertEqual(buffer.snapshot.attachmentCount, 1)
  }

  func testAttachmentByteCap() {
    let config = ChannelConfig(maxBatchAttachmentBytes: 1_000)
    let buffer = InboundBatchBuffer(key: "direct:a", config: config)
    buffer.ingest(text: nil, attachments: [attachment("a.pdf", bytes: 800)], messageID: "1")
    guard case .notice = buffer.ingest(text: nil, attachments: [attachment("b.pdf", bytes: 400)], messageID: "2") else {
      return XCTFail("expected the oversized batch to be refused")
    }
    XCTAssertEqual(buffer.snapshot.attachmentBytes, 800)
  }

  /// A phrase that looks like a harness command must stay ordinary text, or the channel
  /// would shadow `/stop` and friends.
  func testSlashPhrasesNeverTrigger() {
    let config = ChannelConfig(triggerPhrase: "/开始", cancelPhrase: "/取消")
    XCTAssertFalse(config.isTrigger("/开始"))
    XCTAssertFalse(config.isCancel("/取消"))
    let buffer = InboundBatchBuffer(key: "direct:a", config: config)
    buffer.ingest(text: "/开始", attachments: [], messageID: "1")
    XCTAssertEqual(buffer.snapshot.messageCount, 1, "a slash phrase must be buffered as text, not acted on")
  }

  func testConfigValidation() {
    XCTAssertTrue(ChannelConfig().isValid)
    XCTAssertFalse(ChannelConfig(triggerPhrase: "").isValid)
    XCTAssertFalse(ChannelConfig(triggerPhrase: "/go").isValid)
    XCTAssertFalse(ChannelConfig(triggerPhrase: "开始", cancelPhrase: "开始").isValid)
    XCTAssertFalse(ChannelConfig(maxBatchItems: 0).isValid)
  }

  func testComposeTextLabelsMessagesAndListsAttachments() {
    let submission = BatchSubmission(items: [
      BatchItem(messageID: "1", text: "帮我看看这个文件", attachments: [
        attachment("report.pdf", bytes: 2_048),
      ], receivedAt: Date()),
      BatchItem(messageID: "2", text: "重点看第二页", attachments: [
        attachment("image", kind: .image),
      ], receivedAt: Date()),
    ])
    let text = BatchPrompt.composeText(submission, stagedPaths: ["report.pdf": "/ws/.dsh-wechat-inbound/1/report.pdf"])
    XCTAssertTrue(text.hasPrefix(BatchPrompt.header))
    XCTAssertTrue(text.contains("[消息 1]\n帮我看看这个文件"))
    XCTAssertTrue(text.contains("[消息 2]\n重点看第二页"))
    XCTAssertTrue(text.contains("[附件]"))
    XCTAssertTrue(text.contains("路径：/ws/.dsh-wechat-inbound/1/report.pdf"))
    XCTAssertTrue(text.contains("已作为本条消息的附件一并提供"))
  }

  func testComposeTextWithoutAttachmentsOmitsManifest() {
    let submission = BatchSubmission(items: [
      BatchItem(messageID: "1", text: "只有文字", attachments: [], receivedAt: Date()),
    ])
    XCTAssertFalse(BatchPrompt.composeText(submission).contains("[附件]"))
  }

  func testBufferRestoresPersistedItems() {
    let items = [BatchItem(messageID: "9", text: "重启前发的", attachments: [], receivedAt: Date())]
    let buffer = InboundBatchBuffer(key: "direct:a", config: ChannelConfig(), items: items)
    XCTAssertEqual(buffer.snapshot.messageCount, 1)
    XCTAssertEqual(buffer.takeSubmission()?.mergedText, "重启前发的")
    XCTAssertTrue(buffer.isEmpty)
  }
}
