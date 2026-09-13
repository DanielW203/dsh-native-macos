import SwiftUI

/// Minimal Markdown renderer.
///
/// Deliberately not a general Markdown engine: the transcript only needs fenced code
/// blocks, headings, lists, block quotes and inline emphasis/links, and pulling in a
/// third-party renderer is out of scope (CONTRACT.md §1 rule 4). Inline formatting uses
/// Foundation's Markdown support through `AttributedString`; block structure is parsed
/// here so that code blocks can be rendered as real code views with copy buttons.
public struct MarkdownText: View {
  public let markdown: String
  public var baseFont: Font

  public init(markdown: String, baseFont: Font = .body) {
    self.markdown = markdown
    self.baseFont = baseFont
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
        switch block {
        case .paragraph(let text):
          InlineMarkdown(text: text, font: baseFont)
        case .heading(let level, let text):
          InlineMarkdown(text: text, font: headingFont(level))
            .padding(.top, 4)
        case .bulletList(let items):
          VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
              HStack(alignment: .top, spacing: 6) {
                Text(item.ordered ? "\(item.marker)." : "•")
                  .font(baseFont)
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
                  .frame(minWidth: 14, alignment: .trailing)
                InlineMarkdown(text: item.text, font: baseFont)
              }
              .accessibilityElement(children: .combine)
              .id(index)
            }
          }
        case .code(let language, let code):
          CodeBlockView(code: code, language: language)
        case .quote(let text):
          HStack(alignment: .top, spacing: 8) {
            Rectangle()
              .fill(Color.secondary.opacity(0.35))
              .frame(width: 3)
            InlineMarkdown(text: text, font: baseFont)
              .foregroundStyle(.secondary)
          }
        case .rule:
          Divider()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: return .title2.weight(.semibold)
    case 2: return .title3.weight(.semibold)
    case 3: return .headline
    default: return .subheadline.weight(.semibold)
    }
  }
}

/// Inline Markdown through `AttributedString`.
///
/// Falls back to plain text whenever Foundation cannot parse the fragment — which
/// happens for streaming partials — so a half-arrived `**bold` never blanks a line.
struct InlineMarkdown: View {
  let text: String
  let font: Font

  var body: some View {
    if let attributed = try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
      Text(attributed).font(font).textSelection(.enabled)
    } else {
      Text(text).font(font).textSelection(.enabled)
    }
  }
}

/// A fenced code block with a copy affordance.
public struct CodeBlockView: View {
  public let code: String
  public var language: String?
  @State private var copied = false

  public init(code: String, language: String? = nil) {
    self.code = code
    self.language = language
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        if let language, !language.isEmpty {
          Text(language)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          copyToPasteboard(code)
          copied = true
          Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
          }
        } label: {
          Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.secondary.opacity(0.12))

      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1)
    )
  }
}

/// Parsed Markdown block.
enum MarkdownBlock: Equatable {
  case paragraph(String)
  case heading(Int, String)
  case bulletList([ListItem])
  case code(language: String?, code: String)
  case quote(String)
  case rule

  struct ListItem: Equatable {
    var marker: Int
    var ordered: Bool
    var text: String
  }

  /// Block-level parse. Fence-aware, so a `#` inside a code block is not a heading.
  static func parse(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var index = 0

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        index += 1
        var code: [String] = []
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          code.append(lines[index])
          index += 1
        }
        index += 1 // closing fence
        blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
        continue
      }

      if trimmed.isEmpty {
        index += 1
        continue
      }

      if trimmed == "---" || trimmed == "***" {
        blocks.append(.rule)
        index += 1
        continue
      }

      if let heading = parseHeading(trimmed) {
        blocks.append(.heading(heading.0, heading.1))
        index += 1
        continue
      }

      if trimmed.hasPrefix("> ") {
        var quoted: [String] = []
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("> ") {
          quoted.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst(2)))
          index += 1
        }
        blocks.append(.quote(quoted.joined(separator: " ")))
        continue
      }

      if isListLine(trimmed) {
        var items: [ListItem] = []
        var counter = 0
        while index < lines.count, isListLine(lines[index].trimmingCharacters(in: .whitespaces)) {
          let itemLine = lines[index].trimmingCharacters(in: .whitespaces)
          counter += 1
          if let ordered = orderedListMarker(itemLine) {
            items.append(ListItem(marker: ordered.0, ordered: true, text: ordered.1))
          } else {
            items.append(ListItem(marker: counter, ordered: false, text: String(itemLine.dropFirst(2))))
          }
          index += 1
        }
        blocks.append(.bulletList(items))
        continue
      }

      // Paragraph: consume until a blank line or another block start.
      var paragraph: [String] = []
      while index < lines.count {
        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
        if candidate.isEmpty || candidate.hasPrefix("```") || isListLine(candidate)
          || candidate.hasPrefix("> ") || parseHeading(candidate) != nil {
          break
        }
        paragraph.append(lines[index])
        index += 1
      }
      let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { blocks.append(.paragraph(joined)) }
    }
    return blocks
  }

  private static func parseHeading(_ line: String) -> (Int, String)? {
    guard line.hasPrefix("#") else { return nil }
    let hashes = line.prefix { $0 == "#" }.count
    guard hashes <= 6 else { return nil }
    let content = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
    guard !content.isEmpty else { return nil }
    return (hashes, content)
  }

  private static func isListLine(_ line: String) -> Bool {
    if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
    return orderedListMarker(line) != nil
  }

  private static func orderedListMarker(_ line: String) -> (Int, String)? {
    var digits = ""
    var rest = Substring(line)
    while let first = rest.first, first.isNumber {
      digits.append(first)
      rest = rest.dropFirst()
    }
    guard !digits.isEmpty, rest.hasPrefix(". ") else { return nil }
    let number = Int(digits) ?? 1
    return (number, String(rest.dropFirst(2)))
  }
}

/// Copy helper shared by code blocks and tool output.
@MainActor
func copyToPasteboard(_ text: String) {
  #if canImport(AppKit)
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()
  pasteboard.setString(text, forType: .string)
  #endif
}
