import Foundation

/// Line-level codec for the V3 session log.
///
/// The on-disk shape is: one JSON object per line, zstd-compressed as a stream of
/// concatenated frames. The first line is the session header; every later line is an
/// event. `SESSION_FORMAT_VERSION` is 3 in the observed logs.
///
/// **Byte fidelity.** A `JSONValue` object is backed by a Swift dictionary, so key
/// order is not preserved by a decode/encode cycle. Events read from a log therefore
/// keep their original line text and re-serialize as that exact text; only events
/// this build *creates* are serialized from the value tree. That keeps a read/write
/// cycle of an official log byte-identical while still allowing new events to be
/// appended.
public enum SessionLogCodec {
  public static let newline = UInt8(ascii: "\n")

  // MARK: Decoding

  /// Decode one log line into an event, preserving the original text for re-encoding.
  public static func decode(line: String) throws -> SessionEvent {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw HarnessError.malformedPayload(context: "session line", detail: "empty line")
    }
    let value = try JSONValue.parse(trimmed, context: "session line")
    return try decode(value: value, rawLine: trimmed)
  }

  public static func decode(value: JSONValue, rawLine: String? = nil) throws -> SessionEvent {
    guard let type = value.string(at: "type") else {
      throw HarnessError.malformedPayload(context: "session line", detail: "missing `type`")
    }
    // The header line is a flat object with no `data` envelope.
    if type == EventType.session.rawValue {
      var envelope = EventEnvelope(type: .session, data: value)
      envelope.seq = value.int(at: "seq")
      return SessionEvent(envelope: envelope, rawLine: rawLine)
    }
    var envelope = EventEnvelope(
      type: EventType(type),
      seq: value.int(at: "seq"),
      seq0: value.int(at: "seq0"),
      time: value.path("time")?.doubleValue,
      time0: value.path("time0")?.doubleValue,
      surfaceOp: value.string(at: "surfaceOp"),
      sourceEventSeqs: value.array(at: "sourceEventSeqs")?.compactMap(\.intValue),
      ignorable: value.bool(at: "ignorable"),
      data: value.path("data") ?? .object([:])
    )
    // A malformed `seq` (string) should not silently become a packed-line event.
    if envelope.seq == nil && value.path("seq") != nil {
      envelope.seq0 = envelope.seq0 ?? value.path("seq")?.intValue
    }
    return SessionEvent(envelope: envelope, rawLine: rawLine)
  }

  // MARK: Encoding

  /// Serialize one event to its single-line JSON form (no trailing newline).
  public static func encode(_ event: SessionEvent) throws -> String {
    if let raw = event.rawLine, !raw.isEmpty { return raw }
    return try encode(headerOrEventJSON: event.json)
  }

  public static func encode(header: SessionHeader) throws -> String {
    try encode(headerOrEventJSON: header.json)
  }

  private static func encode(headerOrEventJSON value: JSONValue) throws -> String {
    // Compact JSON with no spaces, matching `JSON.stringify` output.
    try value.serialized()
  }

  /// The single line a caller has to append to a log.
  public static func line(_ event: SessionEvent) throws -> Data {
    var data = Data(try encode(event).utf8)
    data.append(newline)
    return data
  }

  public static func line(_ header: SessionHeader) throws -> Data {
    var data = Data(try encode(header: header).utf8)
    data.append(newline)
    return data
  }
}

// MARK: - Streaming reader

/// Reads a session log without loading it whole.
///
/// A measured session compresses 23,631 lines into 6.5 MB; decoding it to
/// `[SessionEvent]` in one shot is fine for that size but not for a long-lived
/// session, so the primary API is a callback-based stream and the array form is
/// built on top of it.
public final class SessionLogReader {
  public let url: URL
  /// Number of zstd frames seen — assertable proof that concatenation was handled.
  public private(set) var frameCount: Int = 0

  public init(url: URL) {
    self.url = url
  }

  public convenience init(path: String) {
    self.init(url: URL(fileURLWithPath: path))
  }

  /// Decode every event, oldest first.
  public func readEvents(limit: Int? = nil) throws -> [SessionEvent] {
    var events: [SessionEvent] = []
    try forEachEvent { event in
      events.append(event)
      if let limit, events.count >= limit { return false }
      return true
    }
    return events
  }

  /// Stream events to `body` in order. Return `false` from `body` to stop early.
  public func forEachEvent(_ body: (SessionEvent) throws -> Bool) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw HarnessError.io(path: url.path, detail: "session log not found")
    }
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw HarnessError.io(path: url.path, detail: "cannot open for reading")
    }
    defer { try? handle.close() }

    let decompressor = try Zstd.Decompressor()
    var pending = Data()
    var stopped = false

    while !stopped {
      let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
      if chunk.isEmpty { break }
      let decoded = try decompressor.feed(chunk)
      if decoded.isEmpty { continue }
      pending.append(decoded)

      var start = pending.startIndex
      while let newlineIndex = pending[start...].firstIndex(of: SessionLogCodec.newline) {
        let lineData = pending[start..<newlineIndex]
        start = pending.index(after: newlineIndex)
        guard let line = String(data: lineData, encoding: .utf8) else { continue }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        // Unknown-future-event tolerance: a line this build cannot parse is reported
        // to the caller as an `.unknown` event rather than aborting the whole read,
        // because the official format is explicitly extensible.
        let event: SessionEvent
        do {
          event = try SessionLogCodec.decode(line: trimmed)
        } catch {
          event = SessionEvent(
            envelope: EventEnvelope(
              type: EventType("unparsed"),
              data: .object(["line": .string(trimmed), "error": .string(String(describing: error))])
            ),
            rawLine: trimmed
          )
        }
        if try !body(event) {
          stopped = true
          break
        }
      }
      pending.removeSubrange(pending.startIndex..<start)
    }

    self.frameCount = decompressor.frameCount

    // Trailing line without a newline (a log written by a crashed process).
    if !stopped {
      let trimmed = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, let event = try? SessionLogCodec.decode(line: trimmed) {
        _ = try body(event)
      }
    }
  }

  /// The session header, without decoding any event.
  public func readHeader() throws -> SessionHeader? {
    var header: SessionHeader?
    try forEachEvent { event in
      if event.kind == .sessionHeader {
        header = event.header
        return false
      }
      return true
    }
    return header
  }
}

// MARK: - Writer

/// Appends to a session log the way the official runtime does.
///
/// The official backend (`@deepseek-ai/dsh-session-persistence-jsonl`) does not write a
/// single zstd stream: it compresses **one independently decodable frame per durable
/// batch** and concatenates them — a header frame at creation, then one frame per
/// event batch. Measured on a real 6.5 MB log that yields 19,263 frames.
///
/// Reproducing that shape matters for more than cosmetics: a reader that assumes one
/// stream stops after the first frame, and the official `scanZstdFrames` walks frame
/// boundaries explicitly. This writer therefore emits one frame per append call, with
/// the frame checksum flag set, matching `compressZstdFrame` byte-for-byte in
/// structure.
public final class SessionLogWriter {
  public let url: URL

  /// Total frame count written, so callers can assert the framing.
  public private(set) var frameCount = 0
  public private(set) var bytesWritten = 0

  private let handle: FileHandle
  private let lock = NSLock()

  /// Opens (creating directories and file) for appending.
  public init(url: URL) throws {
    self.url = url
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else {
      throw HarnessError.io(path: url.path, detail: "cannot open for appending")
    }
    try handle.seekToEnd()
    self.handle = handle
    self.bytesWritten = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
  }

  deinit {
    try? handle.close()
  }

  /// Write the session header as the first frame. Must be called once, before events.
  public func writeHeader(_ header: SessionHeader) throws {
    try writeFrame(Data(try SessionLogCodec.encode(header: header).utf8) + Data("\n".utf8))
  }

  /// Append one event as its own frame.
  public func append(_ event: SessionEvent) throws {
    try writeFrame(try SessionLogCodec.line(event))
  }

  /// Append a batch of events as one frame — the shape the official writer uses for a
  /// durable event batch.
  public func append(contentsOf events: [SessionEvent]) throws {
    guard !events.isEmpty else { return }
    var payload = Data()
    for event in events { payload.append(try SessionLogCodec.line(event)) }
    try writeFrame(payload)
  }

  public func close() {
    try? handle.close()
  }

  private func writeFrame(_ payload: Data) throws {
    let frame = try Zstd.compressChecksummed(payload)
    lock.lock()
    defer { lock.unlock() }
    do {
      try handle.write(contentsOf: frame)
    } catch {
      throw HarnessError.io(path: url.path, detail: String(describing: error))
    }
    frameCount += 1
    bytesWritten += frame.count
  }
}
