import Foundation

/// Failures raised by the runtime-provisioning layer.
///
/// Deliberately separate from `HarnessError`: that type describes engine failures the
/// UI renders inside a conversation, while everything here happens *before* an engine
/// exists — installing, verifying, and updating the harness itself.
public enum RuntimeError: Error, LocalizedError, Sendable, Equatable {
  case missingToolchain(String)
  case unsupportedPlatform(String)
  case incompatibleNode(found: String, requirement: String)
  case archiveRejected(reason: String)
  case archiveMissingEntry(String)
  case integrityMismatch(expected: String, actual: String)
  case integrityUnavailable(String)
  case installFailed(step: String, detail: String)
  /// pnpm refused a lockfile change because the profile holds a release younger than its
  /// `minimumReleaseAge` gate. Distinct from `installFailed` because it is the one refusal
  /// the user can lift — for a single command — so the caller can ask instead of
  /// presenting pnpm's text as a dead end.
  case youngReleaseBlocked(packages: [String], detail: String)
  case noActiveRelease
  case releaseNotFound(String)
  case releaseInUse(String)
  /// A removal was refused because an in-flight upgrade needs this release to fall back to.
  ///
  /// Distinct from `releaseInUse` because the remedy is different: the fix is not "stop the
  /// harness", it is "let the upgrade finish". Telling the user the wrong remedy is worse than
  /// the refusal itself.
  case releaseIsRollbackTarget(String)
  /// An upgrade was asked for with nothing to fall back to.
  ///
  /// Its own case rather than a reuse of `releaseInUse` because it is a precondition the user
  /// can act on *before* anything changes — "keep a second version installed" — and the
  /// upgrade must refuse before it moves the active pointer, not after.
  case noRollbackTarget(String)
  case operationInProgress(String)
  case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
  case unsupported(String)

  public var errorDescription: String? {
    switch self {
    case .missingToolchain(let what):
      return "Missing toolchain: \(what)"
    case .unsupportedPlatform(let detail):
      return "Unsupported platform: \(detail)"
    case .incompatibleNode(let found, let requirement):
      return "Node \(found) does not satisfy \(requirement)"
    case .archiveRejected(let reason):
      return "Archive rejected: \(reason)"
    case .archiveMissingEntry(let path):
      return "Imported harness is missing \(path)"
    case .integrityMismatch(let expected, let actual):
      return "Integrity mismatch: expected \(expected), got \(actual)"
    case .integrityUnavailable(let detail):
      return "No trusted digest available: \(detail)"
    case .installFailed(let step, let detail):
      return "Install failed at \(step): \(detail)"
    case .youngReleaseBlocked(let packages, let detail):
      let named = packages.isEmpty
        ? "a release published in the last day"
        : packages.joined(separator: ", ")
      return "Blocked by pnpm's release-age policy: \(named) is younger than its minimumReleaseAge "
        + "(24 hours by default). pnpm verifies every entry in the profile's lockfile before it "
        + "changes anything, so one recent release blocks installs and removals alike, whatever "
        + "package the command names. Detail: \(detail)"
    case .noActiveRelease:
      return "No harness runtime is installed"
    case .releaseNotFound(let id):
      return "No installed harness release with id \(id)"
    case .releaseInUse(let id):
      return "Release \(id) is in use; stop the running harness first"
    case .releaseIsRollbackTarget(let id):
      return "Release \(id) is the rollback target of an upgrade in progress; "
        + "finish or resolve that upgrade before removing it"
    case .noRollbackTarget(let detail):
      return "No release to roll back to: \(detail)"
    case .operationInProgress(let detail):
      return "Another runtime operation is in progress: \(detail)"
    case .insufficientSpace(let requiredBytes, let availableBytes):
      return "Not enough disk space: need \(requiredBytes) bytes, \(availableBytes) available"
    case .unsupported(let what):
      return "Unsupported: \(what)"
    }
  }

  /// Stable machine-readable code, mirroring `HarnessError.code`.
  public var code: String {
    switch self {
    case .missingToolchain: return "MISSING_TOOLCHAIN"
    case .unsupportedPlatform: return "UNSUPPORTED_PLATFORM"
    case .incompatibleNode: return "INCOMPATIBLE_NODE"
    case .archiveRejected: return "ARCHIVE_REJECTED"
    case .archiveMissingEntry: return "ARCHIVE_MISSING_ENTRY"
    case .integrityMismatch: return "INTEGRITY_CHECK_FAILED"
    case .integrityUnavailable: return "INTEGRITY_UNAVAILABLE"
    case .installFailed: return "INSTALL_FAILED"
    case .youngReleaseBlocked: return "YOUNG_RELEASE_BLOCKED"
    case .noActiveRelease: return "NO_ACTIVE_RELEASE"
    case .releaseNotFound: return "RELEASE_NOT_FOUND"
    case .releaseInUse: return "RELEASE_IN_USE"
    case .releaseIsRollbackTarget: return "RELEASE_IS_ROLLBACK_TARGET"
    case .noRollbackTarget: return "NO_ROLLBACK_TARGET"
    case .operationInProgress: return "OPERATION_IN_PROGRESS"
    case .insufficientSpace: return "INSUFFICIENT_SPACE"
    case .unsupported: return "UNSUPPORTED"
    }
  }
}
