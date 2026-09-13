import Foundation

/// What a window needs from something that can boot the harness.
///
/// A protocol rather than the concrete actor so the window's state machine can be tested
/// without starting a real server: the interesting behaviour is what the window does when
/// a start succeeds, fails, or times out — none of which needs Node.
public protocol HarnessLaunching: Sendable {
  func start(
    profile: String,
    host: String,
    workingDirectory: URL?,
    timeout: TimeInterval,
    onLine: @escaping @Sendable (String) -> Void,
    onStage: @escaping @Sendable (String) -> Void
  ) async throws -> HarnessServerState

  func stop(timeout: TimeInterval) async
  func state() async -> HarnessServerState
}

// The concrete signatures already match the requirements, defaults included — defaults
// are a property of the witness, not of the requirement — so conformance needs no
// forwarding and there is nothing to drift.
extension HarnessLauncher: HarnessLaunching {}
