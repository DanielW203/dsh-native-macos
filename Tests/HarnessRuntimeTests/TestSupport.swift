import Foundation
import XCTest
@testable import HarnessRuntime

/// A runner that answers from a script instead of executing anything.
///
/// Toolchain resolution and the install pipeline are built out of subprocess calls, so
/// testing them without a real Node, a real pnpm, and a network is only possible if the
/// process boundary is itself substitutable. Commands listed in `realExecutables` still
/// run for real — `ditto` is how a source checkout gets copied into staging, and faking
/// that would make the test assert against an empty directory rather than a copied tree.
final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
  struct Call: Sendable, Equatable {
    var executable: String
    var arguments: [String]
    var currentDirectory: String?
  }

  private let lock = NSLock()
  private var recordedCalls: [Call] = []
  private let real = ProcessRunner()
  private let realExecutables: Set<String>
  private let responder: @Sendable (Call) -> ProcessResult?

  init(
    realExecutables: Set<String> = [],
    responder: @escaping @Sendable (Call) -> ProcessResult?
  ) {
    self.realExecutables = realExecutables
    self.responder = responder
  }

  var calls: [Call] {
    lock.lock(); defer { lock.unlock() }
    return recordedCalls
  }

  func calls(matching executableSuffix: String) -> [Call] {
    calls.filter { $0.executable.hasSuffix(executableSuffix) }
  }

  func run(
    _ request: ProcessRequest,
    onLine: (@Sendable (ProcessStream, String) -> Void)?
  ) async throws -> ProcessResult {
    let call = Call(
      executable: request.executable.path,
      arguments: request.arguments,
      currentDirectory: request.currentDirectory?.path
    )
    lock.lock()
    recordedCalls.append(call)
    lock.unlock()

    if realExecutables.contains(request.executable.lastPathComponent) {
      return try await real.run(request, onLine: onLine)
    }
    if let result = responder(call) {
      if let onLine {
        for line in result.stdout.split(separator: "\n") { onLine(.stdout, String(line)) }
      }
      return result
    }
    return ProcessResult(exitCode: 0, stdout: "", stderr: "", duration: 0)
  }
}

extension ProcessResult {
  static func ok(_ stdout: String = "") -> ProcessResult {
    ProcessResult(exitCode: 0, stdout: stdout, stderr: "", duration: 0)
  }

  static func failure(_ code: Int32 = 1, stderr: String = "") -> ProcessResult {
    ProcessResult(exitCode: code, stdout: "", stderr: stderr, duration: 0)
  }
}

/// Scratch-space helpers. Every test gets its own root so the suite is safe to run in
/// parallel and never touches the real application-support directory.
enum TestSupport {
  static func makeRoot(_ testCase: XCTestCase, function: String = #function) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessRuntimeTests", isDirectory: true)
      .appendingPathComponent("\(function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  @discardableResult
  static func write(_ contents: String, to url: URL, executable: Bool = false) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    if executable {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    return url
  }

  /// A directory shaped like a prebuilt `@deepseek-ai/dsh` installation, which is what
  /// the validator keys on.
  @discardableResult
  static func makePrebuiltTree(at root: URL, version: String) throws -> URL {
    try write("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(version)\"}",
              to: root.appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json"))
    try write("// dsh entry", to: root.appendingPathComponent(ReleaseValidator.prebuiltEntry))
    return root
  }

  /// A directory shaped like a source checkout.
  ///
  /// `built: false` is the interesting case: it is what a GitHub source download looks
  /// like before `pnpm run build` has run, and it forces the installer down the path
  /// that has to produce the entry point itself.
  @discardableResult
  static func makeSourceTree(at root: URL, version: String, built: Bool = true) throws -> URL {
    try write("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(version)\"}",
              to: root.appendingPathComponent("apps/cli/package.json"))
    try write("{}", to: root.appendingPathComponent("package.json"))
    if built {
      try write("// dsh entry", to: root.appendingPathComponent(ReleaseValidator.sourceEntry))
    }
    return root
  }

  /// Make the toolchain resolvable without depending on the host's Node install.
  static func installFakeToolchain(into paths: RuntimePaths, nodeVersion: String = "v24.18.1") throws {
    try paths.createDirectories()
    try write("#!/bin/sh\necho \(nodeVersion)\n", to: paths.nodeBinary, executable: true)
    try write("// pnpm entry", to: paths.pnpmEntry)
  }

  /// The response table a stubbed *source* install needs.
  ///
  /// It also materializes the entry point when `pnpm run build` is invoked, because
  /// producing that file is what a real build does and the validator checks for it.
  /// Without this the test would exercise the "already built" shortcut by accident.
  static func sourceBuildResponder(nodeVersion: String = "v24.18.1", dshVersion: String = "0.1.5-rc.1")
    -> @Sendable (StubProcessRunner.Call) -> ProcessResult? {
    let base = toolchainResponder(nodeVersion: nodeVersion, dshVersion: dshVersion)
    return { call in
      if call.arguments == ["run", "build"], let directory = call.currentDirectory {
        try? write("// built by the stubbed toolchain",
                   to: URL(fileURLWithPath: directory).appendingPathComponent(ReleaseValidator.sourceEntry))
      }
      return base(call)
    }
  }

  /// A Harness home shaped like a real one: one initialized profile, its node_modules, and
  /// whatever bookkeeping the test needs around it.
  ///
  /// - Parameters:
  ///   - dependencies: written to the profile manifest, name to spec.
  ///   - installed: name to version, each becoming a package directory. A name present here
  ///     but absent from `dependencies` models a hoisted transitive dependency.
  ///   - bundleDeclarations: installed names that declare `dsh.bundle`, i.e. the ones that
  ///     would actually join the layer stack.
  ///   - profileFiles: relative path to contents, for the patch layer, the pnpm workspace
  ///     file, and anything else a case needs.
  ///   - fallbackLinks: name to an absolute target, written into
  ///     `node_modules/.dsh-module-fallback/node_modules` the way the harness writes them.
  @discardableResult
  static func makePluginHome(
    at home: URL,
    profile: String,
    bundles: [String] = [],
    dependencies: [String: String] = [:],
    installed: [String: String] = [:],
    bundleDeclarations: Set<String> = [],
    profileFiles: [String: String] = [:],
    fallbackLinks: [String: String] = [:],
    harnessVersion: String? = nil
  ) throws -> URL {
    let directory = home.appendingPathComponent("profiles/\(profile)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
      "name": "dsh-profile-\(profile)",
      "private": true,
      "dependencies": dependencies,
      "dsh": ["profile": ["bundles": bundles, "patchReload": "live"]],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: directory.appendingPathComponent("package.json"))

    for (name, version) in installed {
      var package: [String: Any] = ["name": name, "version": version, "main": "index.js"]
      if bundleDeclarations.contains(name) {
        package["dsh"] = ["bundle": ["patch": "cordis.patch.yml"]]
      }
      let packageData = try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
      let packageDirectory = directory.appendingPathComponent("node_modules/\(name)", isDirectory: true)
      try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
      try packageData.write(to: packageDirectory.appendingPathComponent("package.json"))
      try write("module.exports = {}\n", to: packageDirectory.appendingPathComponent("index.js"))
    }

    for (name, target) in fallbackLinks {
      let linkDirectory = directory
        .appendingPathComponent("node_modules/.dsh-module-fallback/node_modules", isDirectory: true)
      try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: linkDirectory.appendingPathComponent(name),
        withDestinationURL: URL(fileURLWithPath: target)
      )
    }

    for (path, contents) in profileFiles {
      try write(contents, to: directory.appendingPathComponent(path))
    }

    if let harnessVersion {
      try write(
        "{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(harnessVersion)\"}",
        to: home.appendingPathComponent("profiles/node_modules/@deepseek-ai/dsh/package.json")
      )
    }
    return directory
  }

  /// A fingerprint of everything under a directory: every directory, file digest and
  /// symlink destination, sorted.
  ///
  /// Used to prove that an import reads the source home and never writes to it.
  static func treeFingerprint(_ root: URL) throws -> String {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [],
      errorHandler: { _, _ in true }
    ) else { return "" }

    var lines: [String] = []
    for case let url as URL in enumerator {
      let relative = url.path.hasPrefix(root.path + "/")
        ? String(url.path.dropFirst(root.path.count + 1))
        : url.path
      if let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
        lines.append("link \(relative) -> \(destination)")
        continue
      }
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
      if values?.isDirectory == true {
        lines.append("dir  \(relative)")
        continue
      }
      let digest = (try? ArchiveInspector.sha256(of: url)) ?? "?"
      lines.append("file \(relative) \(digest)")
    }
    return lines.sorted().joined(separator: "\n")
  }

  /// The response table a stubbed harness install needs.
  static func toolchainResponder(nodeVersion: String = "v24.18.1", dshVersion: String = "0.1.5-rc.1")
    -> @Sendable (StubProcessRunner.Call) -> ProcessResult? {
    { call in
      let name = (call.executable as NSString).lastPathComponent
      switch name {
      case "node":
        if call.arguments == ["--version"] { return .ok("\(nodeVersion)\n") }
        if call.arguments.last == "--version" { return .ok("\(dshVersion)\n") }
        return .ok()
      case "pnpm":
        if call.arguments == ["--version"] { return .ok("11.7.0\n") }
        return .ok("ok\n")
      case "npm":
        return .ok()
      default:
        return nil
      }
    }
  }
}
