import Foundation
import XCTest

@testable import HarnessSkills

/// A throwaway harness home plus a throwaway project, so no test reads or writes the user's
/// real `~/.nativeharness`.
///
/// The layout mirrors the real one on purpose: `home/skills` is the user root, `project/.git`
/// makes the project root resolvable the way `findProjectRoot` resolves it, and `agentsHome`
/// is redirected so `~/.agents/skills` on the machine running the tests can never be touched.
final class SkillSandbox {
  let root: URL
  let dshHome: URL
  let agentsHome: URL
  let workspace: URL
  let center: SkillCenter

  init(runner: (any SkillCommandRunning)? = nil) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsh-skill-tests-\(UUID().uuidString)", isDirectory: true)
    dshHome = root.appendingPathComponent("home", isDirectory: true)
    agentsHome = root.appendingPathComponent("agents", isDirectory: true)
    workspace = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(
      at: dshHome.appendingPathComponent("skills", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: workspace.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    center = SkillCenter(dshHome: dshHome, agentsHome: agentsHome, runner: runner)
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }

  var userSkills: URL { dshHome.appendingPathComponent("skills", isDirectory: true) }
  var projectSkills: URL { workspace.appendingPathComponent(".dsh/skills", isDirectory: true) }
  var projectAgentsSkills: URL { workspace.appendingPathComponent(".agents/skills", isDirectory: true) }

  /// Write a directory-bundle skill and return its `SKILL.md`.
  @discardableResult
  func writeBundle(
    in root: URL,
    directory: String,
    name: String,
    description: String = "描述",
    extraLines: [String] = [],
    body: String = "\n# Body\n",
    resources: [String: String] = [:]
  ) throws -> URL {
    let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let text = try bundleText(name: name, description: description, extraLines: extraLines, body: body)
    let entry = directoryURL.appendingPathComponent("SKILL.md", isDirectory: false)
    try text.write(to: entry, atomically: true, encoding: .utf8)
    for (name, contents) in resources {
      try contents.write(
        to: directoryURL.appendingPathComponent(name, isDirectory: false),
        atomically: true,
        encoding: .utf8
      )
    }
    return entry
  }

  /// Write a flat `<file>.md` skill and return it.
  @discardableResult
  func writeFlat(
    in root: URL,
    file: String,
    name: String,
    description: String = "描述",
    extraLines: [String] = [],
    body: String = "\n# Body\n"
  ) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let text = try bundleText(name: name, description: description, extraLines: extraLines, body: body)
    let url = root.appendingPathComponent(file, isDirectory: false)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func bundleText(
    name: String,
    description: String,
    extraLines: [String],
    body: String
  ) throws -> String {
    (["---", "name: \(name)", "description: \(description)"] + extraLines + ["---"])
      .joined(separator: "\n") + "\n" + body
  }

  func catalog() -> SkillCatalog {
    center.catalog(workspace: workspace)
  }

  func skill(named name: String) -> SkillRecord? {
    catalog().skills.first { $0.name == name }
  }
}

extension XCTestCase {
  /// Build a sandbox that is removed even when the test fails.
  func makeSandbox(runner: (any SkillCommandRunning)? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> SkillSandbox {
    let sandbox = try SkillSandbox(runner: runner)
    addTeardownBlock { sandbox.cleanUp() }
    return sandbox
  }
}

/// A command runner that records the command line and can fabricate what a real one would
/// have produced, so the archive import's argument construction is asserted without a shell.
final class StubSkillRunner: SkillCommandRunning, @unchecked Sendable {
  struct Call: Equatable {
    var executable: String
    var arguments: [String]
  }

  private let lock = NSLock()
  private var recorded: [Call] = []

  var status: Int32 = 0
  var standardError = ""
  /// Called with the directory the command was asked to expand into.
  var onRun: ((URL) throws -> Void)?

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func run(executable: URL, arguments: [String], currentDirectory: URL?) throws -> SkillCommandOutcome {
    lock.lock()
    recorded.append(Call(executable: executable.path, arguments: arguments))
    lock.unlock()
    // `ditto -x -k <archive> <dir>` puts the destination last; `tar -xzf <archive> -C <dir>`
    // puts it after `-C`. Both are read here rather than in the test so a wrong command line
    // shows up as a failed assertion on the arguments instead of a crash.
    if let onRun {
      let destination: URL
      if let index = arguments.firstIndex(of: "-C"), arguments.indices.contains(index + 1) {
        destination = URL(fileURLWithPath: arguments[index + 1])
      } else if let last = arguments.last {
        destination = URL(fileURLWithPath: last)
      } else {
        destination = URL(fileURLWithPath: "/")
      }
      try onRun(destination)
    }
    return SkillCommandOutcome(status: status, standardError: standardError)
  }
}
