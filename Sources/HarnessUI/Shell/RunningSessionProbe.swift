import Foundation
import HarnessIM

/// Answers one question the window model cannot: is a turn still running on the harness?
///
/// The app owns the server process, not the sessions — those live in the harness the web page
/// talks to. Quitting stops that server and therefore kills every running turn, so "are there
/// unfinished sessions" has to be asked of the same authenticated API the page uses rather than
/// guessed from the native side.
///
/// `nil` means "could not tell" (the address has no token, authentication failed, or the
/// server did not answer). A caller must not turn that into "no sessions": the confirmation
/// dialog is an interruption, and inventing one for a stopped harness would be worse than
/// missing it for an unreachable one.
public enum RunningSessionProbe {
  /// Number of live top-level sessions, or `nil` when the harness could not answer.
  ///
  /// Subagents are excluded: a child session's `running` flag follows its parent turn, and
  /// counting both would report one piece of work as two.
  public static func liveSessionCount(
    authenticatedURL: URL,
    // Short on purpose: this runs while the user is trying to quit, so an unresponsive
    // harness must not hold the app open for the transport's usual 30 seconds.
    transport: HarnessAPITransport = URLSessionHarnessTransport(timeout: 3)
  ) async -> Int? {
    do {
      let parsed = try HarnessAPIClient.parse(authenticatedURL: authenticatedURL)
      let client = HarnessAPIClient(baseURL: parsed.origin, transport: transport)
      defer { client.invalidate() }
      try await client.authenticate(token: parsed.token)
      let sessions = try await client.listSessions()
      return sessions.filter { $0.isLive && !$0.isSubagent }.count
    } catch {
      return nil
    }
  }
}
