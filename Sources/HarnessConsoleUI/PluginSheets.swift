import AppKit
import HarnessKit
import HarnessRuntime
import SwiftUI
import UniformTypeIdentifiers

// The plugin sheets: installing one package, and importing a home's plugin tree.
//
// Kept apart from the window that presents them so each file stays the size of one
// job. Both are presented by `HarnessPluginWindow`.

// MARK: - Installing one plugin

/// Installing a package into the selected profile through the harness CLI.
///
/// The field is deliberately one field rather than a source-type picker: "the thing I
/// want" is a path, a name, or a git URL, and which of those it is can be read off the
/// text — an existing path is installed as a link or a tarball, anything else goes to pnpm
/// verbatim. The two Choose buttons exist because a path is the case where typing is pure
/// friction.
struct InstallPluginSheet: View {
  @ObservedObject var model: HarnessConsoleModel
  @Environment(\.dismiss) private var dismiss

  @State private var sourceText = ""
  @State private var resolvedPath = ""
  /// Mirrors the model's pending refusal into a presentation flag. The alert must not write
  /// back to `model.youngReleasePrompt`: dismissing it is the answer's business, and a
  /// binding that cleared the prompt on dismissal would race the button that reads it.
  @State private var showingReleaseAgeOverride = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Install a plugin").font(.headline)
      Text("Installs into profile \(model.selectedProfile) with this app's harness home and pinned toolchain. A local directory is linked, so later edits to it are picked up without reinstalling. The harness must be restarted afterwards.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        TextField("Package directory, .tgz, npm name, or github:owner/repo", text: $sourceText)
          .textFieldStyle(.roundedBorder)
        Button("Folder…") { chooseFolder() }
        Button("Archive…") { chooseArchive() }
      }

      if !resolvedPath.isEmpty {
        Text("Detected a local path: \(resolvedPath)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.head)
      }

      if let message = model.lastInstallMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(Self.resultColor(for: message))
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      if model.isBusy {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(model.busyLabel ?? "Working").font(.caption).foregroundStyle(.secondary)
        }
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Install") { install() }
          .keyboardShortcut(.defaultAction)
          .disabled(model.isBusy || sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(18)
    .frame(width: 560)
    .onAppear { model.clearLastInstallMessage() }
    .onDisappear { model.discardYoungReleasePrompt() }
    // pnpm's release-age gate is a supply-chain control, so overriding it is a question
    // rather than a retry: the alert exists only because the model has a refusal waiting on
    // an answer, and both buttons go back through the model to give it.
    .onChange(of: model.youngReleasePrompt) { _, prompt in
      showingReleaseAgeOverride = prompt != nil
    }
    .alert(
      "pnpm's release-age policy blocked this change",
      isPresented: $showingReleaseAgeOverride,
      presenting: model.youngReleasePrompt
    ) { prompt in
      // The refused command can be an install or a removal; both are repeated with the same
      // one-shot override, so only the verb differs.
      Button(prompt.removalName == nil ? "Install anyway" : "Remove anyway") {
        Task { await model.answerYoungReleasePrompt(installAnyway: true) }
      }
      Button("Cancel", role: .cancel) {
        Task { await model.answerYoungReleasePrompt(installAnyway: false) }
      }
    } message: { prompt in
      Text(Self.overrideExplanation(for: prompt))
    }
  }

  /// How a result line reads at a glance: a refusal awaiting an answer is neither the
  /// success colour nor the failure one, because acting on it can still end in success.
  private static func resultColor(for message: String) -> Color {
    if message.hasPrefix("Failed") { return .red }
    if message.hasPrefix("Blocked") { return .orange }
    return .green
  }

  /// What the alert says: which release tripped the gate, why it blocks an install that
  /// names a different package, and exactly what "anyway" does — and does not — change.
  private static func overrideExplanation(for prompt: YoungReleasePrompt) -> String {
    let named: String
    switch prompt.packages.count {
    case 0:
      named = "A package in this profile was published within the last day."
    case 1:
      named = "\(prompt.packages[0]) was published within the last day."
    default:
      named = "\(prompt.packages.joined(separator: ", ")) were published within the last day."
    }
    return """
    \(named)

    pnpm checks every entry in the profile's lockfile against its 24-hour minimum release age before it changes anything, so one recent release blocks all installs and removals — including this one, whatever it names.

    This change passes \(PluginStore.releaseAgeOverride) for this command only. pnpm's gate applies again to the next one, and nothing about the profile is changed permanently.
    """
  }

  /// Install whatever the field holds: a path when one exists, a specifier otherwise.
  private func install() {
    let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = resolvedPath.isEmpty ? text : resolvedPath
    if FileManager.default.fileExists(atPath: path) {
      let lower = path.lowercased()
      if lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.gz") {
        Task { await model.installPlugin(archivePath: path) }
      } else {
        Task { await model.installPlugin(directoryPath: path) }
      }
    } else {
      Task { await model.installPlugin(specifier: text) }
    }
  }

  private func chooseFolder() {
    // Without this the panel can open behind the active application, which looks exactly
    // like the button having done nothing at all.
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose the package directory (the one containing package.json)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    resolvedPath = url.standardizedFileURL.path
    sourceText = resolvedPath
  }

  private func chooseArchive() {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.gzip, .archive]
    panel.message = "Choose a packed plugin (.tgz / .tar.gz)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    resolvedPath = url.standardizedFileURL.path
    sourceText = resolvedPath
  }
}

// MARK: - Importing from another home

/// Copying another Harness home's plugin tree into this app's profile.
///
/// The sheet is built around the plan rather than around a button: the copy is a hundred
/// and fifty directories and one policy decision about what happens to a package both
/// sides have, so the numbers and the conflicts are shown before anything is written.
struct ImportPluginsSheet: View {
  @ObservedObject var model: HarnessConsoleModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Import plugins").font(.headline)
        Text("Copies another Harness home's profile into \(model.selectedProfile). The source home is only read from, plugin settings and credentials are not copied, and the imported plugins load after the harness is restarted.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      sourcePicker
      policyPicker

      Divider()
      planSummary
      Divider()
      resultSummary

      Spacer(minLength: 0)
      footer
    }
    .padding(16)
    .frame(width: 780, height: 640)
  }

  private var sourcePicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        label("From")
        Picker("", selection: Binding(
          get: { model.importHomePath },
          set: { model.selectImportHome($0) }
        )) {
          ForEach(model.importHomes) { home in
            Text(home.displayName).tag(home.url.path)
          }
        }
        .labelsHidden()
        Button("Choose…") { chooseHome() }
          .disabled(model.isBusy)
      }

      HStack(spacing: 8) {
        label("Profile")
        Picker("", selection: Binding(
          get: { model.importProfile },
          set: { model.selectImportProfile($0) }
        )) {
          ForEach(model.importSourceProfiles) { profile in
            Text("\(profile.name)   \(profile.dependencyCount) plugins").tag(profile.name)
          }
        }
        .labelsHidden()
        .frame(width: 340)
        if model.importProfile.isEmpty {
          Text("This home has no initialized profile.")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }

      HStack(spacing: 8) {
        label("Into")
        Text(model.selectedProfile).font(.callout)
        Text(model.server.isRunning ? "the harness is running — stop it first" : "the harness is stopped")
          .font(.caption2)
          .foregroundStyle(model.server.isRunning ? Color.orange : Color.secondary)
      }
    }
  }

  private var policyPicker: some View {
    HStack(alignment: .top, spacing: 8) {
      label("Conflict")
      VStack(alignment: .leading, spacing: 4) {
        Picker("", selection: Binding(
          get: { model.conflictPolicy },
          set: { model.selectConflictPolicy($0) }
        )) {
          ForEach(PluginConflictPolicy.allCases, id: \.self) { policy in
            Text(policy.displayName).tag(policy)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280)
        Text(model.conflictPolicy == .preferSource
             ? "A package this profile already has is replaced by the source's copy; the old directory is moved into the backup first."
             : "A package this profile already has is kept, and the source's copy is skipped.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var planSummary: some View {
    if let plan = model.importPlan {
      VStack(alignment: .leading, spacing: 6) {
        Text("Plan").font(.callout.weight(.semibold))
        Text("\(plan.writes.count) of \(plan.items.count) entries written   ·   \(bytes(plan.totalBytes)) to copy   ·   \(bytes(plan.backupBytes)) to back up")
          .font(.caption)
          .foregroundStyle(.secondary)
        if !plan.dependencyChanges.isEmpty {
          Text("\(plan.dependencyChanges.count) dependency change(s), \(plan.bundleChanges.count) bundle(s) enabled")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(plan.writes.prefix(300)) { item in
              HStack(spacing: 8) {
                Text(item.action.displayName)
                  .font(.caption2.monospaced())
                  .foregroundStyle(item.action == .replace ? Color.orange : Color.secondary)
                  .frame(width: 92, alignment: .leading)
                Text(item.name).font(.caption.monospaced()).lineLimit(1)
                Spacer()
                Text(item.sourceVersion ?? "").font(.caption2).foregroundStyle(.tertiary)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 150)
        ForEach(plan.warnings, id: \.self) { warning in
          Text(warning)
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if plan.isNoop {
          Text("Nothing to do: this profile already matches the source.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Text("Plan").font(.callout.weight(.semibold))
        Text("Press Preview to see exactly what would be copied, replaced, or kept — nothing is written until Import.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var resultSummary: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let outcome = model.lastImport {
        Text("Result").font(.callout.weight(.semibold))
        Text("copied \(outcome.copied.count)   ·   replaced \(outcome.replaced.count)   ·   skipped \(outcome.skipped.count)   ·   \(bytes(outcome.bytesCopied))")
          .font(.caption)
        if let backup = outcome.backupDirectory {
          HStack(spacing: 6) {
            Text("backup \(backup.path)")
              .font(.caption2.monospaced())
              .lineLimit(1)
              .truncationMode(.head)
              .textSelection(.enabled)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
              .buttonStyle(.borderless)
              .font(.caption2)
          }
        }
      }
      if let verification = model.importVerification {
        Label(verificationHeadline(verification), systemImage: verification.isHealthy ? "checkmark.seal" : "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(verification.isHealthy ? Color.green : Color.red)
        ForEach(verification.problems) { entry in
          Text("\(entry.name): \(entry.problem ?? "")")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
      if model.lastImport == nil, model.importVerification == nil {
        Text("Result").font(.callout.weight(.semibold))
        Text("Nothing has been imported in this session yet.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if model.isBusy {
        ProgressView().controlSize(.small)
        Text(model.busyLabel ?? "Working").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Preview") { Task { await model.previewImport() } }
        .disabled(model.isBusy || model.importProfile.isEmpty)
      Button("Import") { Task { await model.runImport() } }
        .disabled(
          model.isBusy
          || model.importProfile.isEmpty
          || model.server.isRunning
          || (model.importPlan?.isNoop ?? false)
        )
      Button("Done") { dismiss() }
    }
  }

  /// The one line that says whether this profile would start.
  ///
  /// Composing the tree and loading the plugins are different questions: a plugin built
  /// against another harness release composes fine and then takes the whole boot down when
  /// the loader imports it, so the two are reported apart.
  private func verificationHeadline(_ verification: PluginImportVerification) -> String {
    if !verification.importFailures.isEmpty {
      return "\(verification.importFailures.count) plugin(s) cannot be loaded by this runtime and would stop the harness from starting"
    }
    if !verification.composeSucceeded {
      return "The harness could not compose this profile"
    }
    return "This profile loads: \(verification.entries.count) plugins"
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(width: 64, alignment: .leading)
  }

  private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }

  private func chooseHome() {
    // Without this the panel can open behind the active application, which looks exactly
    // like the button having done nothing at all.
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose a Harness home: the directory that contains profiles"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.addImportHome(url) }
  }
}
