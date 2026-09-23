import Foundation
import HarnessKit
import XCTest

@testable import HarnessMobileGateway

/// The permission menu is the one verb family whose *host contract changed* between DSH versions:
/// 0.1.6 moved the candidate list out of the session projection and into a deployment-level
/// catalog. These tests pin both shapes, because getting this wrong is invisible until someone
/// upgrades and finds the menu gone.
final class MobileGatewayPermissionMenuTests: XCTestCase {
  private func makeRouter(_ rpc: ScriptedRPC, parent: XCTestCase? = nil) -> MobileGatewayQueryRouter {
    let configuration = MobileGatewayConfiguration(
      gatewayName: "Test Gateway",
      deviceFile: URL(fileURLWithPath: "/tmp/unused-devices.json")
    )
    return MobileGatewayQueryRouter(
      adapter: MobileGatewayHostAdapter(rpc: rpc),
      configuration: configuration,
      broadcast: { _ in }
    )
  }

  /// A `session/follow` opening frame with the given permission projection.
  private func scriptSnapshot(
    _ rpc: ScriptedRPC,
    sessionID: String = "session-1",
    permissions: JSONValue
  ) {
    rpc.script("session/follow", .object([
      "type": .string("snapshot"),
      "cursor": .number(3),
      "header": .object(["id": .string(sessionID), "version": .number(3)]),
      "records": .array([]),
      "hasMore": .bool(false),
      "projections": .object(["values": .object(["permissions": permissions])]),
    ]))
  }

  /// The router's `handle` is optional because a verb may legitimately answer nothing; every
  /// assertion in this file wants the frame it did produce.
  private func route(_ router: MobileGatewayQueryRouter, _ message: JSONValue) async throws -> JSONValue {
    let frame = await router.handle(message)
    return try XCTUnwrap(frame)
  }

  // MARK: - 0.1.6: the catalog is the only source of candidates

  func testCommandOptionsUsesTheCatalogWhenTheProjectionHasNoOptions() async throws {
    let rpc = ScriptedRPC()
    // The 0.1.6 projection: `currentValue` only, no `options`.
    scriptSnapshot(rpc, permissions: .object(["currentValue": .string("workspace-write")]))
    rpc.script("permissionPresets/catalog", .object([
      "options": .array([
        .object(["value": .string("read-only"), "name": .string("Read Only")]),
        .object([
          "value": .string("workspace-write"),
          "name": .string("Workspace Write"),
          "description": .string("Can edit the workspace"),
        ]),
        .object(["value": .string("auto"), "name": .string("Auto")]),
      ]),
    ]))

    let frame = try await route(makeRouter(rpc), .object([
      "type": .string("command-options"),
      "sessionId": .string("session-1"),
      "command": .string("permission"),
    ]))

    XCTAssertEqual(frame["kind"]?.stringValue, "command-options")
    let options = try XCTUnwrap(frame["options"]?.arrayValue)
    XCTAssertEqual(options.map { $0["id"]?.stringValue }, ["read-only", "workspace-write", "auto"])
    XCTAssertEqual(options.map { $0["label"]?.stringValue }, ["Read Only", "Workspace Write", "Auto"])
    XCTAssertEqual(options.map { $0["selected"]?.boolValue }, [false, true, false])
    XCTAssertEqual(options[1]["description"]?.stringValue, "Can edit the workspace")
    // No `detail` key: the protocol never carries one for permission options.
    XCTAssertNil(options[1]["detail"])
  }

  /// Selecting through the menu must reach the same `/permission <name>` write path — the catalog
  /// only fixes *finding* the option, not applying it.
  func testCommandSelectAppliesACatalogOption() async throws {
    let rpc = ScriptedRPC()
    scriptSnapshot(rpc, permissions: .object(["currentValue": .string("read-only")]))
    rpc.script("permissionPresets/catalog", .object([
      "options": .array([
        .object(["value": .string("read-only"), "name": .string("Read Only")]),
        .object(["value": .string("workspace-write"), "name": .string("Workspace Write")]),
      ]),
    ]))
    rpc.script("commands/execute", .object([
      "commandId": .string("cmd-1"),
      "result": .object(["kind": .string("ok"), "text": .string("permission set")]),
    ]))

    let frame = try await route(makeRouter(rpc), .object([
      "type": .string("command-select"),
      "sessionId": .string("session-1"),
      "command": .string("permission"),
      "optionId": .string("workspace-write"),
    ]))

    XCTAssertEqual(frame["kind"]?.stringValue, "command-selected")
    XCTAssertEqual(frame["selected"]?["id"]?.stringValue, "workspace-write")
    XCTAssertEqual(frame["selected"]?["selected"]?.boolValue, true)
    XCTAssertTrue(rpc.invoked.contains("commands/execute"))
  }

  /// An id that is not in the catalog must be refused before any write is attempted.
  func testCommandSelectRejectsAnUnknownCatalogOption() async throws {
    let rpc = ScriptedRPC()
    scriptSnapshot(rpc, permissions: .object(["currentValue": .string("read-only")]))
    rpc.script("permissionPresets/catalog", .object([
      "options": .array([.object(["value": .string("read-only"), "name": .string("Read Only")])]),
    ]))
    rpc.script("commands/execute", .object(["commandId": .string("cmd-1")]))

    let frame = try await route(makeRouter(rpc), .object([
      "type": .string("command-select"),
      "sessionId": .string("session-1"),
      "command": .string("permission"),
      "optionId": .string("yolo"),
    ]))

    XCTAssertEqual(frame["kind"]?.stringValue, "error")
    XCTAssertEqual(frame["code"]?.stringValue, "bad-request")
    XCTAssertEqual(frame["message"]?.stringValue, "unknown option for permission: yolo")
    XCTAssertFalse(rpc.invoked.contains("commands/execute"))
  }

  /// `permission-options` keeps its documented shape; only the empty candidate list is filled.
  func testPermissionOptionsFillsTheCandidateList() async throws {
    let rpc = ScriptedRPC()
    scriptSnapshot(rpc, permissions: .object(["currentValue": .string("auto")]))
    rpc.script("settings/describe", .object([
      "namespaces": .array([.object(["ns": .string("permission")])]),
    ]))
    rpc.script("permissionPresets/catalog", .object([
      "options": .array([
        .object(["value": .string("read-only"), "name": .string("Read Only")]),
        .object(["value": .string("auto"), "name": .string("Auto")]),
      ]),
    ]))

    let frame = try await route(makeRouter(rpc), .object([
      "type": .string("permission-options"),
      "sessionId": .string("session-1"),
    ]))

    XCTAssertEqual(frame["kind"]?.stringValue, "permission-options")
    let permissions = try XCTUnwrap(frame["sessionPermissions"])
    XCTAssertEqual(permissions["currentValue"]?.stringValue, "auto")
    let options = try XCTUnwrap(permissions["options"]?.arrayValue)
    XCTAssertEqual(options.map { $0["id"]?.stringValue }, ["read-only", "auto"])
    XCTAssertEqual(options.map { $0["selected"]?.boolValue }, [false, true])
  }

  /// `custom` is the host's reserved "matches no preset" state. It is not a catalog entry and not
  /// selectable, but the session's current value must still be visible or the menu would show
  /// nothing selected.
  func testCustomIsSurfacedAsTheSelectedState() async throws {
    let rpc = ScriptedRPC()
    scriptSnapshot(rpc, permissions: .object(["currentValue": .string("custom")]))
    rpc.script("permissionPresets/catalog", .object([
      "options": .array([.object(["value": .string("read-only"), "name": .string("Read Only")])]),
    ]))

    let frame = try await route(makeRouter(rpc), .object([
      "type": .string("command-options"),
      "sessionId": .string("session-1"),
      "command": .string("permission"),
    ]))

    let options = try XCTUnwrap(frame["options"]?.arrayValue)
    XCTAssertEqual(options.map { $0["id"]?.stringValue }, ["read-only", "custom"])
    XCTAssertEqual(options.last?["selected"]?.boolValue, true)
    XCTAssertEqual(options.last?["label"]?.stringValue, "Custom")
  }

  // MARK: - 0.1.5: the projection is still the source

  func testFallsBackToTheProjectionWhenThereIsNoCatalog() async throws {
    let rpc = ScriptedRPC()
    // The 0.1.5 projection still carries its candidate list, and the catalog endpoint does not
    // exist — which is exactly what an unscripted endpoint models here.
    scriptSnapshot(rpc, permissions: .object([
      "currentValue": .string("workspace-write"),
      "options": .array([
        .object(["value": .string("read-only"), "name": .string("Read Only")]),
        .object(["value": .string("workspace-write"), "name": .string("Workspace Write")]),
      ]),
    ]))

    let frame = try await route(makeRouter(rpc), .object([
      "type": .string("command-options"),
      "sessionId": .string("session-1"),
      "command": .string("permission"),
    ]))

    XCTAssertEqual(frame["kind"]?.stringValue, "command-options")
    let options = try XCTUnwrap(frame["options"]?.arrayValue)
    XCTAssertEqual(options.map { $0["id"]?.stringValue }, ["read-only", "workspace-write"])
    XCTAssertEqual(options.map { $0["selected"]?.boolValue }, [false, true])
  }

  /// Neither catalogue nor legacy list: the documented unavailability error, unchanged.
  func testReportsUnavailableWhenThereIsNoSourceAtAll() async throws {
    let rpc = ScriptedRPC()
    scriptSnapshot(rpc, permissions: .object(["currentValue": .string("read-only")]))

    let frame = try await route(makeRouter(rpc), .object([
      "type": .string("command-options"),
      "sessionId": .string("session-1"),
      "command": .string("permission"),
    ]))

    XCTAssertEqual(frame["kind"]?.stringValue, "error")
    XCTAssertEqual(frame["code"]?.stringValue, "command-options-unavailable")
    XCTAssertEqual(frame["message"]?.stringValue, "permission options are unavailable for this session")
    XCTAssertEqual(frame["requestType"]?.stringValue, "command-options")
  }

  /// The direct write path never depended on the menu, and must keep working on either version.
  func testDirectPermissionWriteStillWorks() async throws {
    let rpc = ScriptedRPC()
    rpc.script("commands/execute", .object([
      "commandId": .string("cmd-9"),
      "result": .object(["kind": .string("ok")]),
    ]))

    let frame = try await route(makeRouter(rpc), .object([
      "type": .string("permission"),
      "sessionId": .string("session-1"),
      "name": .string("workspace-write"),
    ]))

    XCTAssertEqual(frame["kind"]?.stringValue, "permission")
    XCTAssertEqual(frame["set"]?.stringValue, "workspace-write")
  }
}
