import CZstd
import Foundation

/// Multi-frame zstd, the format the official runtime writes session logs in.
///
/// Session logs are **concatenated zstd frames** — one frame per append — and a
/// 6.5 MB sample was measured to contain 19,263 frame magics. That shape breaks the
/// obvious implementations:
/// - `ZSTD_decompress` (one-shot) stops at the first frame end;
/// - Node's `zstdDecompressSync` has the same limitation, and its streaming API
///   fails outright with `Unknown frame descriptor`;
/// - Apple's Compression framework has no `COMPRESSION_ZSTD` at all — which is why
///   libzstd is vendored under `Vendor/zstd` instead of being taken from the system.
///
/// This wrapper is therefore built on `ZSTD_decompressStream`, which walks frame
/// boundaries transparently, and counts frames so callers can assert the behaviour
/// rather than assume it.
public enum Zstd {
  /// Decompress every concatenated frame in `data`.
  public static func decompressAll(_ data: Data) throws -> Data {
    guard !data.isEmpty else { return Data() }
    var written: Int = 0
    let pointer: UnsafeMutableRawPointer? = data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return nil }
      return czstd_decompress_all(base, raw.count, &written)
    }
    guard let pointer else {
      throw HarnessError.zstd(code: -1, message: String(cString: czstd_last_error()))
    }
    defer { czstd_free(pointer) }
    return Data(bytes: pointer, count: written)
  }

  /// Compress one payload into a single frame.
  public static func compress(_ data: Data, level: Int = 3) throws -> Data {
    var written: Int = 0
    let pointer: UnsafeMutableRawPointer? = data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return nil }
      return czstd_compress(base, raw.count, Int32(level), &written)
    }
    guard let pointer else {
      throw HarnessError.zstd(code: -1, message: String(cString: czstd_last_error()))
    }
    defer { czstd_free(pointer) }
    return Data(bytes: pointer, count: written)
  }

  /// Compress one payload into a checksummed frame.
  ///
  /// The official JSONL persistence writer sets `ZSTD_c_checksumFlag` on every durable
  /// batch, so frames this build appends to a session log carry the same flag and are
  /// integrity-checkable by the same readers.
  public static func compressChecksummed(_ data: Data, level: Int = 3) throws -> Data {
    var written: Int = 0
    let pointer: UnsafeMutableRawPointer? = data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return nil }
      return czstd_compress_checksummed(base, raw.count, Int32(level), &written)
    }
    guard let pointer else {
      throw HarnessError.zstd(code: -1, message: String(cString: czstd_last_error()))
    }
    defer { czstd_free(pointer) }
    return Data(bytes: pointer, count: written)
  }

  /// True when `data` starts with the zstd frame magic (`28 B5 2F FD`).
  public static func hasFrameMagic(_ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      return czstd_is_frame_magic(base, raw.count) == 1
    }
  }

  /// Count frame magics in a buffer. Frames are also allowed to start immediately
  /// after compressed payload bytes, so this counts candidate positions the same
  /// way the M0 probe did — it is a diagnostic, not a parser.
  public static func countFrameMagics(_ data: Data) -> Int {
    let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    guard data.count >= 4 else { return 0 }
    var count = 0
    let bytes = [UInt8](data)
    var index = 0
    while index <= bytes.count - 4 {
      if bytes[index] == magic[0], bytes[index + 1] == magic[1], bytes[index + 2] == magic[2], bytes[index + 3] == magic[3] {
        count += 1
      }
      index += 1
    }
    return count
  }

  /// Incremental decoder for streams fed in chunks (a log being tailed).
  ///
  /// `czstd_dstream` is an opaque C type, so Swift imports it as `OpaquePointer`;
  /// the lifetime is owned here and released in `deinit`.
  public final class Decompressor {
    private let stream: OpaquePointer

    public init() throws {
      guard let created = czstd_dstream_new() else {
        throw HarnessError.zstd(code: -1, message: String(cString: czstd_last_error()))
      }
      self.stream = created
    }

    deinit {
      czstd_dstream_free(stream)
    }

    /// Number of frames decoded so far — the proof that concatenation is handled.
    public var frameCount: Int {
      Int(czstd_dstream_frame_count(stream))
    }

    /// Feed a chunk, receiving whatever output that chunk completes.
    ///
    /// A chunk that ends mid-frame produces no output; the decoder holds the partial
    /// frame until enough bytes arrive.
    public func feed(_ chunk: Data, maximumOutput: Int = 1 << 22) throws -> Data {
      guard !chunk.isEmpty else { return Data() }
      var output = Data()
      try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var consumed = 0
        var buffer = [UInt8](repeating: 0, count: maximumOutput)
        while consumed < raw.count {
          let outcome = buffer.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> czstd_outcome in
            czstd_decompress_stream(
              stream,
              base.advanced(by: consumed),
              raw.count - consumed,
              out.baseAddress,
              out.count
            )
          }
          if outcome.written < 0 {
            throw HarnessError.zstd(code: -1, message: String(cString: czstd_last_error()))
          }
          if outcome.written > 0 {
            output.append(contentsOf: buffer[0..<Int(outcome.written)])
          }
          if outcome.consumed == 0 && outcome.written == 0 {
            // No forward progress: the frame needs more input.
            break
          }
          consumed += outcome.consumed
        }
      }
      return output
    }

    /// Rewind to the start of a new stream.
    public func reset() {
      czstd_dstream_reset(stream)
    }
  }
}
