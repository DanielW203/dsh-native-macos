import AppKit
import Foundation
import HarnessKit
import HarnessRuntime
import SwiftUI

/// The plugin window: every plugin in the selected profile, and every operation that
/// changes it.
///
/// This is the merge of two surfaces that used to exist separately — the console's
/// `Plugins` tab (profile switching, install, import, verify, enable/disable) and the
/// read-only `Installed Plugins` window (filter, counts, repository links, last-refreshed
/// stamp). The console keeps its Runtime and Log tabs, and both windows drive the same
/// `HarnessConsoleModel`, so an install started here still reports into the console's log
/// and status line.
public struct HarnessPluginWindow: View {
  @ObservedObject var model: HarnessConsoleModel

  public init(model: HarnessConsoleModel) {
    self.model = model
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      PluginsPane(model: model)
      Divider()
      ConsoleStatusStrip(model: model)
    }
    .frame(minWidth: 820, minHeight: 560)
    // Opening this window before the console must leave a fully loaded surface behind it.
    // `startIfNeeded` is what makes that safe when both windows are open at once: the model
    // is started once, by whichever window got there first.
    .task { await model.startIfNeeded() }
  }

  /// The window's chrome. The profile picker and the operations live in `PluginsPane`, next
  /// to the list they act on; this is only what names the window and says whose home it is.
  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Plugins").font(.headline)
        Text("profile \(model.selectedProfile) · DSH_HOME \(model.dshHome)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer()
      if model.isBusy {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(model.busyLabel ?? "Working")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Button {
        Task { await model.refresh() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(model.isBusy)
      .help("Re-read the profiles, the plugin list, and the Harness homes Import… can copy from")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

// MARK: - The plugin surface

/// Filtering, shared by the window and its tests.
///
/// A free function rather than a model property: the needle is presentation state, and a
/// pure predicate is the part worth testing — it needs no runtime, no profile, and no
/// window to exercise.
enum PluginFilter {
  /// Case-insensitive match over a plugin's name and specifier. An empty (or whitespace
  /// only) needle matches everything.
  static func visible(_ plugins: [PluginRecord], needle: String) -> [PluginRecord] {
    let trimmed = needle.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return plugins }
    return plugins.filter {
      $0.name.lowercased().contains(trimmed) || $0.spec.lowercased().contains(trimmed)
    }
  }

  /// Whether a verdict is something the user should look at.
  ///
  /// Only a real out-of-range finding counts. `undeclared` is deliberately not a problem: most
  /// of the ecosystem declares nothing, so flagging silence would leave the switch showing
  /// almost every plugin — which is the same as showing none.
  static func isProblem(_ compatibility: PluginCompatibility?) -> Bool {
    guard case .incompatible = compatibility?.verdict else { return false }
    return true
  }

  /// The needle plus the "only problems" switch, applied together.
  ///
  /// Both are presentation state, so both are filtered here and the predicate stays a pure
  /// function the tests can drive without a model or a window.
  static func visible(
    _ plugins: [PluginRecord],
    needle: String,
    onlyProblems: Bool,
    compatibility: [String: PluginCompatibility]
  ) -> [PluginRecord] {
    let matching = visible(plugins, needle: needle)
    guard onlyProblems else { return matching }
    return matching.filter { isProblem(compatibility[$0.name]) }
  }
}

/// The plugin surface: the toolbar that changes the profile, the filter, the list, and the
/// counts.
///
/// Kept apart from `HarnessPluginWindow` so the window's chrome is not tangled up with the
/// list it shows; the install and import sheets it presents live in `PluginSheets.swift`.
struct PluginsPane: View {
  @ObservedObject var model: HarnessConsoleModel
  @State private var showingImport = false
  @State private var showingInstall = false
  @State private var confirmingUndo = false
  @State private var filter = ""
  /// Whether the list hides everything that is not an out-of-range finding.
  @State private var onlyProblems = false

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      filterBar
      Divider()
      content
      Divider()
      footer
    }
    .sheet(isPresented: $showingImport) {
      ImportPluginsSheet(model: model)
    }
    .sheet(isPresented: $showingInstall) {
      InstallPluginSheet(model: model)
    }
    .confirmationDialog(
      "Uninstall \(model.lastInstalled?.name ?? "")?",
      isPresented: $confirmingUndo
    ) {
      Button("Uninstall", role: .destructive) {
        Task { await model.undoLastInstall() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if let record = model.lastInstalled {
        Text(
          "This is the newest install this app recorded in \(model.selectedProfile): \(record.name) "
            + "(asked for as \(record.spec)). Installing the same specifier again is the way back."
        )
      }
    }
  }

  /// What the filter currently shows.
  private var visible: [PluginRecord] {
    PluginFilter.visible(
      model.plugins,
      needle: filter,
      onlyProblems: onlyProblems,
      compatibility: model.compatibility
    )
  }

  /// How many plugins the audit found something to say about.
  private var problemCount: Int {
    model.plugins.filter { PluginFilter.isProblem(model.compatibility[$0.name]) }.count
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      Text("Profile").font(.caption).foregroundStyle(.secondary)
      Picker("", selection: Binding(
        get: { model.selectedProfile },
        set: { value in Task { await model.selectProfile(value) } }
      )) {
        ForEach(model.profiles) { profile in
          Text(profile.name).tag(profile.name)
        }
        if model.profiles.isEmpty {
          Text(model.selectedProfile).tag(model.selectedProfile)
        }
      }
      .labelsHidden()
      .frame(width: 200)

      Button("Create") { Task { await model.initializeProfile() } }
        .disabled(model.isBusy)
        .help("Create this profile from the shipped web template without booting it")

      Button("Install…") { showingInstall = true }
        .disabled(model.isBusy)
        .help("Install a package into this profile: a local checkout, a tarball, or a registry / git specifier")

      Button("Import…") { showingImport = true }
        .disabled(model.isBusy)
        .help("Copy another Harness home's plugin tree into this profile, without re-downloading anything")

      Button("Verify") { Task { await model.verifyImportedProfile() } }
        .disabled(model.isBusy || model.plugins.isEmpty)
        .help("Compose this profile once and report what would not load")

      // The rollback for a plugin that broke something after it was installed. It only
      // appears as possible when this app has a record of the install *and* the package is
      // still there: offering to undo something it cannot name would be an empty promise.
      Button("Undo Last Install…") { confirmingUndo = true }
        .disabled(model.isBusy || model.lastInstalled == nil)
        .help(
          model.lastInstalled.map { "Uninstall \($0.name), the newest install this app recorded for this profile" }
            ?? "No install on record for this profile"
        )

      Spacer()
      Text("\(model.plugins.filter(\.isEnabled).count) enabled of \(model.plugins.count)")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  /// The filter row. The needle is local state on purpose: it says what this window is
  /// showing, not what the profile holds.
  private var filterBar: some View {
    HStack(spacing: 8) {
      TextField("Filter by name or specifier", text: $filter)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
      if !filter.isEmpty {
        Button {
          filter = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Clear the filter")
      }
      Toggle("Only problems", isOn: $onlyProblems)
        .toggleStyle(.checkbox)
        .disabled(problemCount == 0)
        .help(
          problemCount == 0
            ? "No plugin in this profile is out of range for the installed harness"
            : "\(problemCount) plugin(s) declare a version this harness does not satisfy"
        )
      Spacer()
      if !model.plugins.isEmpty {
        Text("\(visible.count) of \(model.plugins.count) shown")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
  }

  @ViewBuilder private var content: some View {
    if let message = model.pluginsFailure {
      failure(message)
    } else if model.plugins.isEmpty {
      empty
    } else if visible.isEmpty {
      noMatch
    } else {
      list
    }
  }

  private var list: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(visible) { plugin in
          PluginRow(model: model, plugin: plugin)
          Divider()
        }
      }
    }
  }

  private var empty: some View {
    VStack(spacing: 10) {
      Image(systemName: "puzzlepiece.extension").font(.system(size: 34)).foregroundStyle(.tertiary)
      Text("No plugins in this profile.").font(.callout).foregroundStyle(.secondary)
      Text("Use Install… to add a package here — a local checkout, a tarball, or a registry name — or Import… to copy an existing profile's plugins from another Harness home. This window reads and toggles what is installed.")
        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 460)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var noMatch: some View {
    VStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
      Text("No plugin matches “\(filter)”.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func failure(_ message: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text("The plugin list could not be read").font(.callout)
      Text(message)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      // Says where the rest of the plugin lifecycle lives. This window installs, imports,
      // removes, and rolls back the last install; browsing and updating are DSH Market's job.
      Text("Install, remove, and roll back here; browse and update in DSH Market.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Text(summary)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
      if let at = model.pluginsRefreshedAt {
        Text(at.formatted(date: .omitted, time: .standard))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
  }

  private var summary: String {
    let bundle = model.plugins.filter(\.isBundle).count
    let plain = model.plugins.count - bundle
    let patchDisabled = model.plugins.filter(\.isConfigDisabled).count
    return "\(model.plugins.filter(\.isEnabled).count) enabled · \(bundle) bundle · \(plain) plain"
      + (patchDisabled > 0 ? " · \(patchDisabled) disabled in patch" : "")
  }
}

// MARK: - One row

private struct PluginRow: View {
  @ObservedObject var model: HarnessConsoleModel
  let plugin: PluginRecord
  @State private var confirmingOverride = false
  @State private var confirmingRemoval = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: plugin.isEnabled ? "checkmark.circle.fill" : "circle.dashed")
        .foregroundStyle(plugin.isEnabled ? Color.green : Color.secondary)

      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(plugin.name).font(.callout)
          if !plugin.isBundle {
            badge("plain dependency", .secondary)
              .help("Installed, but declares no dsh.bundle, so it does not join the profile layer stack.")
          }
          if plugin.isConfigDisabled {
            badge("disabled in cordis.patch.yml", .orange)
          }
          if plugin.isConditionallyDisabled {
            badge("platform-conditional", .secondary)
          }
          if !plugin.isEnabled {
            badge("not in layer stack", .secondary)
          }
          compatibilityBadge
        }
        HStack(spacing: 8) {
          if let version = plugin.installedVersion {
            Text("v\(version)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
          } else {
            Text("not materialized").font(.caption2).foregroundStyle(.orange)
          }
          Text(plugin.spec)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if case .incompatible(let violations) = model.compatibility[plugin.name]?.verdict {
          Text(violations.map(\.detail).joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.red)
            .lineLimit(2)
        }
      }

      Spacer()

      if let repository = plugin.repository, let url = URL(string: repository) {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(.borderless)
        .help(repository)
      }

      // Disabled rather than hidden for the harness's own packages: a missing button reads
      // as a missing feature, where a disabled one explains why.
      Button {
        confirmingRemoval = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .disabled(model.isBusy || PluginStore.isHarnessPackage(plugin.name))
      .help(
        PluginStore.isHarnessPackage(plugin.name)
          ? "\(plugin.name) is part of the harness itself."
          : "Uninstall \(plugin.name) from this profile"
      )

      Toggle("", isOn: Binding(
        get: { plugin.isEnabled },
        set: { newValue in
          if newValue && plugin.isConfigDisabled {
            // The patch entry belongs to another tool, so removing it is confirmed rather
            // than done silently.
            confirmingOverride = true
          } else {
            Task { await model.setEnabled(plugin.name, enabled: newValue) }
          }
        }
      ))
      .labelsHidden()
      .toggleStyle(.switch)
      .disabled(model.isBusy || !plugin.isBundle)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .confirmationDialog(
      "\(plugin.name) is also disabled by cordis.patch.yml",
      isPresented: $confirmingOverride
    ) {
      Button("Remove that entry and enable") {
        Task { await model.setEnabled(plugin.name, enabled: true, stripConfigOverride: true) }
      }
      Button("Enable without touching it") {
        Task { await model.setEnabled(plugin.name, enabled: true) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("That entry was written by another tool. Removing it edits your cordis.patch.yml; leaving it keeps the plugin disabled.")
    }
    .confirmationDialog(
      "Uninstall \(plugin.name)?",
      isPresented: $confirmingRemoval
    ) {
      Button("Uninstall", role: .destructive) {
        Task { await model.uninstall(plugin.name) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This runs `dsh plugin --profile \(model.selectedProfile) remove \(plugin.name)`, which uninstalls the package "
          + "and drops it from the profile's layer stack. A checkout installed with `link:` stays on disk; "
          + "anything from a registry needs the network to come back."
      )
    }
  }

  /// The compatibility verdict, as one capsule.
  ///
  /// `undeclared` renders grey and says "no version declared" rather than a warning: most of
  /// the ecosystem says nothing, and a warning for silence would train the user to ignore the
  /// badge that does matter. A plugin the audit has not reached yet renders nothing at all,
  /// because "not judged" is not a claim about the plugin.
  @ViewBuilder private var compatibilityBadge: some View {
    switch model.compatibility[plugin.name]?.verdict {
    case .incompatible(let violations):
      badge(violations.count == 1 ? "out of range" : "out of range (\(violations.count))", .red)
        .help(violations.map(\.detail).joined(separator: "\n"))
    case .compatible:
      badge("compatible", .green)
        .help(
          plugin.enginesRange.map { "Declares dsh \($0), which this harness satisfies." }
            ?? "Every declared harness peer range is satisfied."
        )
    case .undeclared:
      badge("no version declared", .secondary)
        .help(
          model.compatibility[plugin.name]?.isUnjudged == true
            ? "The declared range could not be judged against this harness — the range or the installed version was unreadable."
            : "This plugin declares no dsh.engines or @deepseek-ai/dsh-* peer range to check."
        )
    case nil:
      EmptyView()
    }
  }

  private func badge(_ text: String, _ colour: Color) -> some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(colour)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(colour.opacity(0.14), in: Capsule())
  }
}
