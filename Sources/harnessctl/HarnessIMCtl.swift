import Foundation
import HarnessKit
import HarnessIM

/// The `harnessctl im` command group: verification for the native IM channel's harness side.
///
/// The channel's contract with the harness is a private API, so "does this still work?" has
/// to be answerable with one command. This tool creates its own session in its own working
/// directory and never touches an existing session, which is what makes it safe to run
/// against a harness someone is actively using.
enum HarnessIMCtl {
  static let usage = """
  harnessctl im selftest --url <url> [--dsh-home <path>] [--cwd <dir>] [--text <prompt>] [--timeout <seconds>]
  harnessctl im attach --url <url> --workspace <dir> [--session <id>]
  harnessctl im approvals --url <url> [--seconds <n>] [--auto-allow|--auto-reject]

    Exercises the running harness the way the WeChat channel does: authenticate with the
    harness's own launch token, probe which endpoints exist, create a session, submit one
    prompt, and read the answer back from the session log.

    `im attach` registers a folder as a harness workspace and, with `--session`, attaches that
    session to it — the repair for a channel session that exists on disk but never appeared in
    the sidebar. It prints the workspace's session ids so the result can be checked by eye.

    The URL is the token-bearing address the harness prints (or the one the app loads).
    It is a credential: these commands never echo it.
  """

  static func run(_ arguments: [String]) async throws -> Int32 {
    guard let subcommand = arguments.first else {
      print(usage)
      return 1
    }
    switch subcommand {
    case "selftest":
      return try await selftest(Array(arguments.dropFirst()))
    case "attach":
      return try await attach(Array(arguments.dropFirst()))
    case "approvals":
      return try await approvals(Array(arguments.dropFirst()))
    case "help", "-h", "--help":
      print(usage)
      return 0
    default:
      FileHandle.standardError.write(Data("unknown im subcommand: \(subcommand)\n\n\(usage)\n".utf8))
      return 1
    }
  }

  /// Register a workspace and optionally attach one session to it.
  ///
  /// This is the same pair of calls the channel makes; it exists so a session created before
  /// the channel registered workspaces can be made visible without resending anything from
  /// WeChat.
  private static func attach(_ arguments: [String]) async throws -> Int32 {
    guard let urlText = value("--url", in: arguments), let url = URL(string: urlText) else {
      FileHandle.standardError.write(Data("im attach: --url is required\n".utf8))
      return 1
    }
    guard let workspacePath = value("--workspace", in: arguments) else {
      FileHandle.standardError.write(Data("im attach: --workspace is required\n".utf8))
      return 1
    }
    let sessionID = value("--session", in: arguments)
    let parsed = try HarnessAPIClient.parse(authenticatedURL: url)
    print("origin: \(parsed.origin.absoluteString) (token redacted)")

    let client = HarnessAPIClient(baseURL: parsed.origin)
    try await client.authenticate(token: parsed.token)

    let (workspaceID, created) = try await client.createWorkspace(path: workspacePath)
    print("workspace: \(workspaceID) (\(created ? "newly registered" : "already registered"))")
    if let sessionID, !sessionID.isEmpty {
      let attached = try await client.createSession(inWorkspace: workspaceID, adopting: sessionID)
      print("attached session: \(attached)")
    }
    let value = try await client.call(
      endpoint: "workspace/create",
      args: .object(["request": .object(["path": .string(workspacePath)])])
    )
    let ids = value.path("workspace.sessionIds")?.arrayValue?.compactMap(\.stringValue) ?? []
    print("sessions in workspace: \(ids.count)")
    for id in ids { print("  \(id)") }
    return 0
  }

  /// Watch the host's forwarded-event stream and report (or answer) approval questions.
  ///
  /// This exists to verify the approval path without a phone: it opens the same WebSocket
  /// stream the channel opens, prints every question the harness asks, and with `--auto-allow`
  /// answers them, which is what lets a blocked tool call finish.
  private static func approvals(_ arguments: [String]) async throws -> Int32 {
    guard let urlText = value("--url", in: arguments), let url = URL(string: urlText) else {
      FileHandle.standardError.write(Data("im approvals: --url is required\n".utf8))
      return 1
    }
    let parsed = try HarnessAPIClient.parse(authenticatedURL: url)
    let seconds = TimeInterval(value("--seconds", in: arguments) ?? "") ?? 120
    let autoAllow = arguments.contains("--auto-allow")
    let autoReject = arguments.contains("--auto-reject")

    print("origin: \(parsed.origin.absoluteString) (token redacted)")
    let client = HarnessAPIClient(baseURL: parsed.origin)
    try await client.authenticate(token: parsed.token)
    let stream = try await client.makeRemoteEventStream()
    print("event stream: opening (watching for \(Int(seconds))s)")

    let deadline = Date().addingTimeInterval(seconds)
    let frames = try await stream.open()
    for try await frame in frames {
      if Date() > deadline { break }
      switch frame {
      case .ready(let clientID):
        print("stream ready (clientId \(clientID.prefix(8))…)")
      case .waterfall(let eventID, let agentID, let event, let request):
        let tool = request["toolName"]?.stringValue ?? "-"
        let reason = request["reason"]?.stringValue ?? "-"
        print("request: \(event) tool=\(tool) session=\(agentID.prefix(18))… reason=\(reason)")
        if event == "approval/request", autoAllow || autoReject {
          let outcome = autoAllow ? "allowed-once" : "rejected"
          do {
            try await stream.answer(eventID: eventID, outcome: outcome)
            print("answered \(eventID.prefix(8))… with \(outcome)")
          } catch {
            print("answer failed: \((error as? HarnessAPIError)?.message ?? String(describing: error))")
          }
        }
      case .cancel(let eventID):
        print("cancelled: \(eventID.prefix(8))…")
      case .emit(let event, _):
        if event == "approval/asked" { print("emit: \(event)") }
      }
    }
    await stream.close()
    return 0
  }

  private static func value(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  private static func selftest(_ arguments: [String]) async throws -> Int32 {
    guard let urlText = value("--url", in: arguments), let url = URL(string: urlText) else {
      FileHandle.standardError.write(Data("im selftest: --url is required\n".utf8))
      return 1
    }
    let parsed = try HarnessAPIClient.parse(authenticatedURL: url)
    let cwd = value("--cwd", in: arguments) ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-im-selftest", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    let text = value("--text", in: arguments) ?? "只回复两个字：收到"
    let timeout = TimeInterval(value("--timeout", in: arguments) ?? "") ?? 180
    let dshHome = value("--dsh-home", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }

    print("origin: \(parsed.origin.absoluteString) (token redacted)")
    let client = HarnessAPIClient(baseURL: parsed.origin)
    try await client.authenticate(token: parsed.token)
    print("handshake: ok")

    let capabilities = await HarnessAPICompatibility.probe(client: client)
    print("capabilities: create=\(capabilities.canCreateSession) workspace=\(capabilities.canCreateWorkspace) "
          + "upload=\(capabilities.canUploadFiles) cancel=\(capabilities.canCancelSession) "
          + "page=\(capabilities.canPageSession)")
    for note in capabilities.notes { print("note: \(note)") }
    guard capabilities.canCreateSession else {
      FileHandle.standardError.write(Data("im selftest: this harness cannot create sessions\n".utf8))
      return 1
    }

    let sessionID = try await client.createSession(cwd: cwd)
    print("session: \(sessionID)")
    let requestId = try await client.prompt(sessionID: sessionID, content: [
      .object(["type": .string("text"), "text": .string(text)]),
    ])
    print("prompt accepted (requestId \(requestId))")

    guard let home = dshHome else {
      print("result: prompt accepted; pass --dsh-home to read the reply from the session log")
      return 0
    }
    let source = SessionReplySource(
      dshHome: home,
      cwd: cwd,
      sessionID: sessionID,
      client: client,
      configuration: .init(pollInterval: .seconds(1), timeout: .seconds(timeout))
    )
    guard let reply = await source.waitForReply(requestId: requestId) else {
      FileHandle.standardError.write(Data("im selftest: no reply within \(Int(timeout))s\n".utf8))
      return 1
    }
    print("reply complete=\(reply.isComplete) reason=\(reply.reason ?? "-") turn=\(reply.turn.map(String.init) ?? "-")")
    print("reply text: \(reply.text)")
    return reply.isComplete ? 0 : 1
  }
}
