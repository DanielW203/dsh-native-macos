import Foundation
import HarnessRuntime
import SwiftUI

/// The plugin compatibility matrix: every plugin in the selected profile, and what the harness
/// this app installed has to say about it.
///
/// Read-only on purpose, and in its own window. The plugin window mutates a profile (install,
/// enable, uninstall); this one only reports, so leaving it open next to that window cannot
/// contradict what the user is doing there — it re-reads through the same `HarnessConsoleModel`
/// and simply shows whatever the last refresh found.
///
/// The verdict vocabulary is fixed to three states and never hedges:
///
/// - **compatible** — every declared harness range is satisfied.
/// - **out of range** — a declared range is positively violated, with the field that violated it.
/// - **no version declared** — nothing checkable was declared, or a version could not be read.
///   This is not a problem state, and the window says so rather than warning about silence.
public struct PluginCompatibilityWindow: View {
  @ObservedObject var model: HarnessConsoleModel

  public init(model: HarnessConsoleModel) {
    self.model = model
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .frame(minWidth: 720, minHeight: 480)
    .task { await model.startIfNeeded() }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Plugin compatibility").font(.headline)
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if model.isBusy {
        ProgressView().controlSize(.small)
      }
      Button {
        Task { await model.refreshCompatibility() }
      } label: {
        Label("Re-check", systemImage: "arrow.clockwise")
      }
      .disabled(model.isBusy)
      .help("Re-read every plugin's declared ranges and compare them with the installed harness")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var subtitle: String {
    let harness = model.activeReleaseVersion ?? "no harness installed"
    return "profile \(model.selectedProfile) · harness \(harness)"
  }

  @ViewBuilder private var content: some View {
    if let failure = model.compatibilityFailure {
      failureView(failure)
    } else if model.plugins.isEmpty {
      emptyView
    } else {
      list
    }
  }

  private var list: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        summaryStrip
        ForEach(model.plugins) { plugin in
          CompatibilityRow(model: model, plugin: plugin)
        }
      }
      .padding(.vertical, 6)
    }
  }

  /// The three counts, so the answer is readable before any row is.
  private var summaryStrip: some View {
    HStack(spacing: 14) {
      ForEach(CompatibilityVerdictKind.allCases, id: \.self) { kind in
        HStack(spacing: 5) {
          Circle().fill(kind.colour).frame(width: 8, height: 8)
          Text("\(count(kind)) \(kind.label)").font(.caption)
        }
        .help(kind.explanation)
      }
      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private func count(_ kind: CompatibilityVerdictKind) -> Int {
    model.plugins.filter { CompatibilityVerdictKind(verdict: model.compatibility[$0.name]?.verdict) == kind }
      .count
  }

  private var emptyView: some View {
    VStack(spacing: 8) {
      Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
      Text("This profile has no plugins").font(.callout)
      Text("Install one from the Plugins window and re-check.").font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func failureView(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("The compatibility check could not run", systemImage: "exclamationmark.triangle")
        .font(.callout)
      Text(message).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
      Text("The plugin list itself is unaffected — open the Plugins window to see what is installed.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(16)
  }
}

/// The three states, as a value the view can iterate and colour in one place.
///
/// A separate enum rather than switching on `CompatibilityVerdict` at each use site: the row, the
/// summary strip, and the empty-state copy all have to agree about what "no version declared"
/// means, and the only way to keep them agreeing is to state it once.
enum CompatibilityVerdictKind: CaseIterable {
  case compatible
  case outOfRange
  case notDeclared

  init(verdict: CompatibilityVerdict?) {
    switch verdict {
    case .some(.incompatible): self = .outOfRange
    case .some(.compatible): self = .compatible
    case .some(.undeclared), .none: self = .notDeclared
    }
  }

  var label: String {
    switch self {
    case .compatible: return "compatible"
    case .outOfRange: return "out of range"
    case .notDeclared: return "no version declared"
    }
  }

  var colour: Color {
    switch self {
    case .compatible: return .green
    case .outOfRange: return .red
    case .notDeclared: return .secondary
    }
  }

  var explanation: String {
    switch self {
    case .compatible:
      return "Every dsh.engines.dsh and @deepseek-ai/dsh-* peer range the plugin declares is satisfied."
    case .outOfRange:
      return "The plugin declares a range this harness does not satisfy, or carries its own copy of a harness package."
    case .notDeclared:
      return "Nothing checkable was declared, or a version could not be read. Not a failure."
    }
  }
}

// MARK: - One row

private struct CompatibilityRow: View {
  @ObservedObject var model: HarnessConsoleModel
  let plugin: PluginRecord

  private var verdict: CompatibilityVerdict? { model.compatibility[plugin.name]?.verdict }
  private var kind: CompatibilityVerdictKind { CompatibilityVerdictKind(verdict: verdict) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Circle().fill(kind.colour).frame(width: 8, height: 8)
        Text(plugin.name).font(.callout)
        if let version = plugin.installedVersion {
          Text("v\(version)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        Spacer()
        Text(kind.label).font(.caption).foregroundStyle(kind.colour)
      }

      // The claims the verdict rests on, one line each so a reader can see which field decided.
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
        if let engines = plugin.enginesRange {
          GridRow {
            Text("dsh.engines.dsh").font(.caption2).foregroundStyle(.tertiary)
            Text(engines).font(.caption2.monospaced()).textSelection(.enabled)
          }
        }
        ForEach(plugin.dshPeerRanges.sorted(by: { $0.key < $1.key }), id: \.key) { name, range in
          GridRow {
            Text(name).font(.caption2).foregroundStyle(.tertiary)
            Text(range).font(.caption2.monospaced()).textSelection(.enabled)
          }
        }
        if plugin.enginesRange == nil && plugin.dshPeerRanges.isEmpty {
          GridRow {
            Text("declared").font(.caption2).foregroundStyle(.tertiary)
            Text(entryDescription).font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      .padding(.leading, 16)

      if case .incompatible(let violations) = verdict {
        ForEach(Array(violations.enumerated()), id: \.offset) { _, violation in
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption2)
              .foregroundStyle(.red)
            Text(violation.detail)
              .font(.caption2)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading, 16)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(kind == .outOfRange ? Color.red.opacity(0.06) : Color.clear)
  }

  /// What the package contributes, for a plugin that declares no harness range at all — so the
  /// row still says something useful instead of only "nothing".
  private var entryDescription: String {
    var parts: [String] = []
    if plugin.hasBundlePatch { parts.append("host bundle") }
    if let platform = plugin.clientPlatform { parts.append("client (\(platform))") }
    if parts.isEmpty { parts.append("plain dependency") }
    return parts.joined(separator: " · ")
  }
}
