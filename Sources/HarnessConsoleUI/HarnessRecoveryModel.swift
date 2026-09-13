import AppKit
import Foundation
import HarnessKit
import HarnessRuntime
import SwiftUI

/// The recovery window's state: which mode the next launch uses, what can be rolled back,
/// and the state of the plugin-free profile a rescue start depends on.
///
/// Its collaborators arrive as protocols and closures rather than as the concrete window
/// model, so this module keeps depending on `HarnessRuntime` alone — the same seam style as
/// `PluginRecovering` and `HarnessLaunching`. The interesting behaviour is which marker
/// gets written, whether a restart follows, and whether a restore is refused before it
/// touches anything; none of that needs a running harness.
@MainActor
public final class HarnessRecoveryModel: ObservableObject {
  @Published public private(set) var mode: SafeBootMode?
  @Published public private(set) var banner: SafeModeBanner?
  /// A line about the mode this launch actually resolved to, including a cleared leftover.
  @Published public private(set) var note: String?
  @Published public private(set) var checkpoints: [ProfileCheckpointRecord] = []
  @Published public private(set) var lastPreview: ProfileCheckpointPreview?
  @Published public private(set) var rescueProfileExists = false
  @Published public private(set) var isBusy = false
  @Published public private(set) var statusLine = "Ready."
  @Published public private(set) var statusIsFailure = false

  /// The real tree. Every action here edits the user's own profiles, even while the
  /// harness runs in a disposable home — repairing the throwaway one would answer nothing.
  public let base: RuntimePaths
  public let dshHome: String
  public let logsPath: String
  public let checkpointsPath: String

  private let marking: any SafeBootMarking
  private let checkpoints_: ProfileCheckpointStore
  private let rescueInstaller: (any ProfilePreparing)?
  private let stopHarness: @MainActor () async -> Void
  private let restartApp: @MainActor () -> Void

  public init(
    base: RuntimePaths,
    boot: SafeBootResolution,
    marking: any SafeBootMarking,
    checkpoints: ProfileCheckpointStore,
    rescueInstaller: (any ProfilePreparing)? = nil,
    stopHarness: @escaping @MainActor () async -> Void,
    restartApp: @escaping @MainActor () -> Void
  ) {
    self.base = base
    self.dshHome = base.dshHome.path
    self.logsPath = base.logsDirectory.path
    self.checkpointsPath = checkpoints.checkpointRoot.path
    self.marking = marking
    self.checkpoints_ = checkpoints
    self.rescueInstaller = rescueInstaller
    self.stopHarness = stopHarness
    self.restartApp = restartApp
    self.mode = boot.mode
    self.banner = SafeModeBanner.make(boot)
    self.note = boot.note
    self.rescueProfileExists = SafeBoot.rescueProfileExists(in: base)
  }

  // MARK: - Reading

  public func refresh() async {
    let resolution = marking.current()
    mode = resolution.mode
    banner = SafeModeBanner.make(resolution)
    note = resolution.note
    rescueProfileExists = SafeBoot.rescueProfileExists(in: base)
    await refreshCheckpoints()
  }

  public func refreshCheckpoints() async {
    checkpoints = checkpoints_.list()
  }

  // MARK: - Mode

  /// Switch the mode the next launch uses and restart into it.
  ///
  /// `nil` returns to a normal start. The rescue profile is created *here*, before the
  /// marker is written, so a failure is reported in a window the user is looking at rather
  /// than after a restart into a mode that cannot boot.
  public func selectMode(_ mode: SafeBootMode?) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }

    do {
      if let mode, mode == .rescue, let rescueInstaller {
        status("Preparing the plugin-free profile…")
        if let line = try await rescueInstaller.ensureProfile(
          named: SafeBoot.rescueProfileName,
          template: SafeBootResolution.normalProfile
        ) {
          status(line)
        }
      }
      if let mode {
        try marking.enter(mode)
        status("Switching to \(mode.displayName); the app will restart…")
      } else {
        try marking.leave()
        status("Returning to a normal start; the app will restart…")
      }
    } catch {
      fail("Could not change the start mode: \(error)")
      return
    }
    restartApp()
  }

  public func removeRescueProfile() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    // Leaving first is the only order that cannot strand a launch: a marker pointing at a
    // profile that no longer exists would boot nothing.
    if mode == .rescue {
      fail("Leave Safe Mode before deleting the profile it boots.")
      return
    }
    do {
      try SafeBoot.removeRescueProfile(in: base)
      rescueProfileExists = SafeBoot.rescueProfileExists(in: base)
      status("Deleted the rescue profile.")
    } catch {
      fail("Could not delete the rescue profile: \(error)")
    }
  }

  // MARK: - Rollback

  public func previewRestore(_ slot: String) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      lastPreview = try await checkpoints_.preview(slot: slot)
    } catch {
      lastPreview = nil
      fail("Could not read \(slot): \(error)")
    }
  }

  /// Put a checkpoint's declaration back.
  ///
  /// The harness is stopped first: a running server holds the profile it booted, and
  /// rewriting the files underneath it produces a state neither the user nor the harness
  /// can describe. Nothing here runs pnpm — the installed tree is left alone, which is why
  /// the result says so.
  public func restore(_ slot: String) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }

    status("Stopping the harness before restoring…")
    await stopHarness()

    do {
      let result = try await checkpoints_.restore(slot: slot)
      lastPreview = nil
      await refreshCheckpoints()
      status(
        "Restored \(result.restored.count) file(s) from \(slot)."
          + (result.skipped.isEmpty ? "" : " Skipped: \(result.skipped.joined(separator: ", ")).")
          + " Dependencies were left alone — reinstall them if the profile asks."
      )
    } catch {
      fail("Restore failed: \(error)")
    }
  }

  public func clearCheckpoints() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await checkpoints_.clear()
      lastPreview = nil
      await refreshCheckpoints()
      status("Cleared every checkpoint.")
    } catch {
      fail("Could not clear the checkpoints: \(error)")
    }
  }

  // MARK: - Data and diagnostics

  public func revealDataHome() {
    NSWorkspace.shared.activateFileViewerSelecting([base.dshHome])
  }

  public func revealLogs() {
    NSWorkspace.shared.activateFileViewerSelecting([base.logsDirectory])
  }

  public func revealCheckpoints() {
    NSWorkspace.shared.activateFileViewerSelecting([checkpoints_.checkpointRoot])
  }

  public func copyLogPath() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(logsPath, forType: .string)
    status("Copied \(logsPath) to the clipboard.")
  }

  // MARK: - Status

  private func status(_ line: String) {
    statusLine = line
    statusIsFailure = false
  }

  private func fail(_ line: String) {
    statusLine = line
    statusIsFailure = true
  }
}
