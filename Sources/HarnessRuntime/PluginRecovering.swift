import Foundation

/// What a window needs from something that can repair a profile the harness will not boot.
///
/// A protocol rather than the concrete actor, for the same reason `HarnessLaunching` is one:
/// the interesting behaviour is what the window does when a repair finds nothing, turns
/// plugins off, or fails outright — and none of that needs Node, a profile, or a real boot.
///
/// The only requirement is the quarantine loop. Starting the repaired harness afterwards is
/// the window's job, not the repairer's: the window owns the server's lifecycle, and a
/// second component that could start one would be a second answer to "is the harness up".
public protocol PluginRecovering: Sendable {
  /// Disable whatever this runtime cannot load, one provable failure at a time, until the
  /// profile boots — or until `maxRounds` is spent.
  func quarantine(
    profile: String,
    maxRounds: Int,
    progress: @escaping @Sendable (PluginImportProgress) -> Void
  ) async throws -> PluginQuarantineOutcome
}

// The concrete signature already matches the requirement, defaults included — defaults are a
// property of the witness, not of the requirement — so conformance needs no forwarding and
// there is nothing to drift.
extension ProfileImporter: PluginRecovering {}
