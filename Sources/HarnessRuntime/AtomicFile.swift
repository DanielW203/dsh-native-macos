import Foundation

/// Write a whole file, or leave the previous one exactly as it was.
///
/// The same write `InstallsIndex.save` performs, factored out because the upgrade marker
/// and its report need it too: a crash in the middle of writing one of them must not leave a
/// truncated file behind. The readers of all three are deliberately non-throwing, so a
/// half-written marker would be silently indistinguishable from a corrupt one — and for the
/// upgrade marker that means forgetting an upgrade was in flight.
enum AtomicFile {
  static func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: .atomic)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }

  /// The encoder every one of these files is written with: sorted keys so a diff of two
  /// markers is readable, ISO-8601 dates so a marker written by one build is legible to the
  /// next.
  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
