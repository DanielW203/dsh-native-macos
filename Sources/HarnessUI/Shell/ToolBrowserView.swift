import HarnessKit
import SwiftUI

/// Browser for the capability surface.
///
/// This is the pane that makes the two presentation modes legible: in direct mode the
/// list is the model's tool list; in programmatic (PTC) mode the same capabilities are
/// something else entirely — TypeScript bindings a program calls — and showing them as
/// a flat tool list would misrepresent how the model actually reaches them.
public struct ToolBrowserView: View {
  public let surface: ToolSurface
  public let isProgrammatic: Bool

  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var selected: ToolDescriptor?

  public init(surface: ToolSurface, isProgrammatic: Bool) {
    self.surface = surface
    self.isProgrammatic = isProgrammatic
  }

  public var body: some View {
    NavigationSplitView {
      List(selection: Binding(
        get: { selected?.name },
        set: { name in selected = surface.allCapabilities.first { $0.name == name } }
      )) {
        ForEach(ToolCategory.allCases, id: \.self) { category in
          let tools = filtered.filter { $0.category == category }
          if !tools.isEmpty {
            Section(category.displayName) {
              ForEach(tools) { tool in
                HStack(spacing: 6) {
                  Image(systemName: tool.category.symbolName)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                  Text(tool.name).font(.system(.callout, design: .monospaced))
                  Spacer()
                  if tool.isMutating {
                    Image(systemName: "exclamationmark.triangle")
                      .font(.caption2)
                      .foregroundStyle(.orange)
                  }
                }
                .tag(tool.name)
              }
            }
          }
        }
      }
      .searchable(text: $query, prompt: "Filter tools")
      .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    } detail: {
      if let selected {
        ToolDetailView(tool: selected)
      } else {
        ContentUnavailableView(
          "Select a tool",
          systemImage: "wrench.and.screwdriver",
          description: Text("\(surface.allCapabilities.count) capabilities in this profile.")
        )
      }
    }
    .frame(width: 860, height: 560)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Done") { dismiss() }
      }
    }
  }

  private var filtered: [ToolDescriptor] {
    let all = surface.allCapabilities
    guard !query.isEmpty else { return all }
    return all.filter {
      $0.name.localizedCaseInsensitiveContains(query)
        || $0.description.localizedCaseInsensitiveContains(query)
    }
  }
}

struct ToolDetailView: View {
  let tool: ToolDescriptor

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: tool.category.symbolName).font(.title3)
          Text(tool.name).font(.title3.monospaced())
          Spacer()
          Text(tool.origin.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
        if tool.isMutating {
          Label("This tool can change state on disk or in the running system.", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Text(tool.description)
          .font(.callout)
          .textSelection(.enabled)
        Divider()
        Text("Parameters").font(.headline)
        if let text = try? tool.parameters.serializedSorted() {
          CodeBlockView(code: text, language: "json")
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
