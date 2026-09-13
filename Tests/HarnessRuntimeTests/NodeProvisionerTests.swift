import Foundation
import XCTest
@testable import HarnessRuntime

/// A fetcher that answers from a table instead of the network.
private struct StubHTTPFetcher: HTTPFetching {
  var responses: [String: (Int, Data)] = [:]

  func fetch(_ url: URL, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
    guard let response = responses[url.absoluteString] else {
      throw RuntimeError.installFailed(step: "http", detail: "no stub response for \(url.absoluteString)")
    }
    return (data: response.1, statusCode: response.0)
  }
}

/// A downloader that copies a fixture file into place.
private struct StubFileDownloader: FileDownloading {
  var source: URL
  var bytes: Int64?

  func download(
    _ url: URL,
    to destination: URL,
    timeout: TimeInterval,
    onProgress: (@Sendable (Int64, Int64?) -> Void)?
  ) async throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: source, to: destination)
    let size = bytes ?? Int64((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int ?? 0)
    onProgress?(size, size)
  }
}

final class NodeProvisionerTests: XCTestCase {
  private let platform = PlatformAsset.Platform(os: "macos", arch: "arm64")

  // MARK: - Version discovery

  func testIndexYieldsTheNewestReleaseThatSatisfiesTheEngineRange() throws {
    let index = """
    [
      {"version":"v21.7.3","lts":"Iron","files":["osx-arm64-tar"]},
      {"version":"v22.18.0","lts":"Jod","files":["osx-arm64-tar"]},
      {"version":"v22.19.0","lts":"Jod","files":["osx-arm64-tar"]},
      {"version":"v24.10.0","lts":"Krypton","files":["osx-arm64-tar"]},
      {"version":"v26.8.2","lts":false,"files":["osx-arm64-tar"]}
    ]
    """
    let candidates = try NodeProvisioner.candidates(fromIndex: Data(index.utf8), platform: platform)

    // Newest first, and 22.18.0 / 21.7.3 are outside the range the harness declares.
    XCTAssertEqual(candidates.map(\.version), ["v26.8.2", "v24.10.0", "v22.19.0"])
    XCTAssertEqual(candidates.first?.isLTS, false)
    XCTAssertEqual(candidates.last?.isLTS, true)
  }

  func testIndexSkipsReleasesWithNoMacOSArchive() throws {
    let index = """
    [
      {"version":"v26.8.2","lts":false,"files":["linux-x64","win-x64-zip"]},
      {"version":"v24.10.0","lts":"Krypton","files":["osx-arm64-tar"]}
    ]
    """
    let candidates = try NodeProvisioner.candidates(fromIndex: Data(index.utf8), platform: platform)

    XCTAssertEqual(candidates.map(\.version), ["v24.10.0"])
  }

  func testIndexRejectsAPayloadThatIsNotAnArray() {
    XCTAssertThrowsError(try NodeProvisioner.candidates(fromIndex: Data("{}".utf8), platform: platform))
  }

  func testArchiveURLMatchesTheNameNodePublishes() {
    // Verified against nodejs.org/dist: the tarball is `darwin-arm64`, never `osx-arm64`.
    let url = NodeProvisioner.distributionArchiveURL(version: "v24.10.0", platform: platform)
    XCTAssertEqual(url.absoluteString, "https://nodejs.org/dist/v24.10.0/node-v24.10.0-darwin-arm64.tar.gz")
    XCTAssertEqual(
      NodeProvisioner.distributionArchiveURL(version: "24.10.0", platform: platform).absoluteString,
      url.absoluteString
    )
    XCTAssertEqual(
      NodeProvisioner.distributionArchiveURL(
        version: "v24.10.0",
        platform: PlatformAsset.Platform(os: "macos", arch: "x64")
      ).absoluteString,
      "https://nodejs.org/dist/v24.10.0/node-v24.10.0-darwin-x64.tar.gz"
    )
  }

  // MARK: - Digest manifest

  func testDigestIsFoundInTheManifest() {
    let manifest = """
    fbc3d6e1e1d962450d058e918214373872cc4c46e08673f31c35932afac4a8c5  node-v24.10.0-darwin-arm64.tar.xz
    1d721c81deac26a511a1fde66d76be73d608be5d5320680828edd0176c686ae1  ./node-v24.10.0-darwin-arm64.tar.gz
    """
    XCTAssertEqual(
      NodeProvisioner.digest(of: "node-v24.10.0-darwin-arm64.tar.gz", inManifest: manifest),
      "1d721c81deac26a511a1fde66d76be73d608be5d5320680828edd0176c686ae1"
    )
    XCTAssertNil(NodeProvisioner.digest(of: "node-v24.10.0-linux-x64.tar.gz", inManifest: manifest))
  }

  // MARK: - Is it needed

  func testNodeIsMissingWhenNoCandidateReportsAVersion() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()
    // A binary exists but is not a Node: resolution must fail, and the offer must appear.
    try TestSupport.write("#!/bin/sh\necho not-node\n", to: paths.nodeBinary, executable: true)

    let runner = StubProcessRunner { _ in nil }
    let provisioner = NodeProvisioner(paths: paths, runner: runner)

    let missing = await provisioner.isNodeMissing()
    XCTAssertTrue(missing)
  }

  func testNodeIsPresentWhenTheFetchedCopyWorks() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    try paths.createDirectories()
    try TestSupport.write("#!/bin/sh\necho v24.10.0\n", to: paths.nodeBinary, executable: true)

    let runner = StubProcessRunner { call in
      call.arguments == ["--version"] ? .ok("v24.10.0\n") : nil
    }
    let provisioner = NodeProvisioner(paths: paths, runner: runner)

    let missing = await provisioner.isNodeMissing()
    XCTAssertFalse(missing)
  }

  // MARK: - End to end

  func testInstallDownloadsVerifiesUnpacksAndPublishes() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    let fixture = try await makeNodeArchive(in: root, version: "v24.10.0")

    let digest = try ArchiveInspector.sha256(of: fixture.archive)
    let tag = "v24.10.0"
    let name = "node-\(tag)-darwin-arm64.tar.gz"
    let archiveURL = "https://nodejs.org/dist/\(tag)/\(name)"
    let fetcher = StubHTTPFetcher(responses: [
      NodeProvisioner.indexURL.absoluteString: (
        200,
        Data("""
        [{"version":"\(tag)","lts":"Krypton","files":["osx-arm64-tar"]}]
        """.utf8)
      ),
      "https://nodejs.org/dist/\(tag)/SHASUMS256.txt": (200, Data("\(digest)  \(name)\n".utf8)),
    ])

    // Only the version probe is scripted: extraction runs for real so the test asserts on
    // an actual unpacked tree rather than on a directory the stub pretended to fill.
    let runner = StubProcessRunner(realExecutables: ["tar"]) { call in
      if call.arguments == ["--version"], call.executable.contains("node.staged-") {
        return .ok("v24.10.0\n")
      }
      return nil
    }

    let provisioner = NodeProvisioner(
      paths: paths,
      fetcher: fetcher,
      downloader: StubFileDownloader(source: fixture.archive),
      runner: runner,
      archiveURLProvider: { _, _ in URL(string: archiveURL)! }
    )

    var stages: [NodeInstallProgress.Phase] = []
    let outcome = try await provisioner.installNode { progress in stages.append(progress.phase) }

    XCTAssertEqual(outcome.version, "24.10.0")
    XCTAssertEqual(outcome.archive, name)
    XCTAssertEqual(outcome.binary.path, paths.nodeBinary.path)

    // Published where the resolver looks first, and it really is the unpacked tree.
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.nodeBinary.path, isDirectory: &isDirectory))
    XCTAssertFalse(isDirectory.boolValue)
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.nodeDirectory.appendingPathComponent("lib/node_modules").path))

    // The staging it came through is gone, and no half-published copy is left beside it.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.runtimeRoot.path)
      .filter { $0.hasPrefix("node.staged-") }
    XCTAssertEqual(leftovers, [])

    XCTAssertEqual(stages.first, .resolving)
    XCTAssertTrue(stages.contains(.downloading))
    XCTAssertTrue(stages.contains(.extracting))
    XCTAssertTrue(stages.contains(.verifying))
  }

  func testInstallRefusesAnArchiveWhoseDigestDoesNotMatch() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    let fixture = try await makeNodeArchive(in: root, version: "v24.10.0")

    let tag = "v24.10.0"
    let name = "node-\(tag)-darwin-arm64.tar.gz"
    let fetcher = StubHTTPFetcher(responses: [
      NodeProvisioner.indexURL.absoluteString: (
        200,
        Data("""
        [{"version":"\(tag)","lts":"Krypton","files":["osx-arm64-tar"]}]
        """.utf8)
      ),
      // The published digest of a file this is not.
      "https://nodejs.org/dist/\(tag)/SHASUMS256.txt": (200, Data("\(String(repeating: "a", count: 64))  \(name)\n".utf8)),
    ])

    let runner = StubProcessRunner(realExecutables: ["tar"]) { _ in nil }
    let provisioner = NodeProvisioner(
      paths: paths,
      fetcher: fetcher,
      downloader: StubFileDownloader(source: fixture.archive),
      runner: runner,
      archiveURLProvider: { _, _ in URL(string: "https://nodejs.org/dist/\(tag)/\(name)")! }
    )

    do {
      _ = try await provisioner.installNode { _ in }
      XCTFail("an archive with the wrong digest must not be installed")
    } catch let error as RuntimeError {
      guard case .integrityMismatch = error else {
        return XCTFail("expected an integrity mismatch, got \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.nodeBinary.path))
  }

  func testInstallRefusesWhenTheManifestDoesNotListTheArchive() async throws {
    let root = try TestSupport.makeRoot(self)
    let paths = RuntimePaths(root: root)
    let fixture = try await makeNodeArchive(in: root, version: "v24.10.0")

    let tag = "v24.10.0"
    let name = "node-\(tag)-darwin-arm64.tar.gz"
    let fetcher = StubHTTPFetcher(responses: [
      NodeProvisioner.indexURL.absoluteString: (
        200,
        Data("""
        [{"version":"\(tag)","lts":"Krypton","files":["osx-arm64-tar"]}]
        """.utf8)
      ),
      "https://nodejs.org/dist/\(tag)/SHASUMS256.txt": (200, Data("deadbeef  node-v22.19.0-darwin-arm64.tar.gz\n".utf8)),
    ])

    let runner = StubProcessRunner(realExecutables: ["tar"]) { _ in nil }
    let provisioner = NodeProvisioner(
      paths: paths,
      fetcher: fetcher,
      downloader: StubFileDownloader(source: fixture.archive),
      runner: runner,
      archiveURLProvider: { _, _ in URL(string: "https://nodejs.org/dist/\(tag)/\(name)")! }
    )

    do {
      _ = try await provisioner.installNode { _ in }
      XCTFail("an unlisted archive must not be installed")
    } catch let error as RuntimeError {
      guard case .integrityUnavailable = error else {
        return XCTFail("expected a missing-digest failure, got \(error)")
      }
    }
  }

  // MARK: - Fixture

  /// A tarball shaped exactly like the one nodejs.org publishes, holding a script that
  /// answers `--version` instead of a real runtime — the shape is what extraction and
  /// publication are tested against.
  private func makeNodeArchive(in root: URL, version: String) async throws -> (archive: URL, tree: URL) {
    let staging = root.appendingPathComponent("fixture-build", isDirectory: true)
    let tree = staging.appendingPathComponent("node-\(version)-darwin-arm64", isDirectory: true)
    try TestSupport.write("#!/bin/sh\necho \(version)\n", to: tree.appendingPathComponent("bin/node"), executable: true)
    try FileManager.default.createDirectory(
      at: tree.appendingPathComponent("lib/node_modules", isDirectory: true),
      withIntermediateDirectories: true
    )
    try TestSupport.write("#!/bin/sh\n", to: tree.appendingPathComponent("bin/npm"), executable: true)
    try TestSupport.write("11.19.1\n", to: tree.appendingPathComponent("lib/node_modules/npm-version"))

    let archive = root.appendingPathComponent("node-\(version)-darwin-arm64.tar.gz")
    let runner = ProcessRunner()
    let result = try await runner.run(
      ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-czf", archive.path, "-C", staging.path, tree.lastPathComponent],
        timeout: 120,
        label: "tar -czf fixture"
      ),
      onLine: nil
    )
    guard result.succeeded else {
      throw XCTSkip("could not build the tarball fixture: \(result.stderr)")
    }
    return (archive, tree)
  }
}
