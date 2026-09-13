// swift-tools-version: 6.0
//
// NativeHarness — a Swift-native harness for the DeepSeek Harness.
//
// Module graph:
//
//   HarnessUI ──► HarnessKit ◄── HarnessEmbedded   (route A: embedded official engine)
//                     ▲
//                     └──────── HarnessCore          (route B: Swift re-implementation)
//
//   CZstd is the single place that links the vendored libzstd.
//
// Language mode is Swift 5 (`swiftLanguageMode(.v5)`): the UI layer is a large
// SwiftUI surface and the engine layer is concurrent by design, so strict Swift 6
// checking is adopted per-module as each module is audited rather than
// repo-wide on day one.

import PackageDescription
import Foundation

/// Absolute path of this manifest's directory, resolved at manifest-evaluation time.
///
/// The vendored static library cannot be expressed as a SwiftPM `binaryTarget`
/// (which expects an artifact bundle) and relative `unsafeFlags` resolve against an
/// unpredictable build working directory, so the manifest bakes in the absolute
/// path. This makes the package intentionally non-relocatable: it is a local
/// package inside this checkout, not a published dependency.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let zstdVendor = "\(packageDirectory)/Vendor/zstd"
let zstdInclude = "\(zstdVendor)/include"
let zstdLibrary = "\(zstdVendor)/lib/libzstd.a"

let commonSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5),
  .define("HARNESS_NATIVE"),
]

let package = Package(
  name: "NativeHarness",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "HarnessKit", targets: ["HarnessKit"]),
    .library(name: "HarnessCore", targets: ["HarnessCore"]),
    // Runtime provisioning: install/update the harness, and manage a profile's plugins.
    .library(name: "HarnessRuntime", targets: ["HarnessRuntime"]),
    .library(name: "HarnessUI", targets: ["HarnessUI"]),
    // The console and plugin windows DSHNative opens from its Harness menu.
    .library(name: "HarnessConsoleUI", targets: ["HarnessConsoleUI"]),
    // The app-owned native IM channel (provider protocol + batching + running-harness client).
    .library(name: "HarnessIM", targets: ["HarnessIM"]),
    .executable(name: "harnessctl", targets: ["harnessctl"]),
  ],
  targets: [
    // MARK: - Vendored compression
    .target(
      name: "CZstd",
      path: "Sources/CZstd",
      publicHeadersPath: "include",
      cSettings: [
        // Relative to the target directory (`Sources/CZstd`); SwiftPM rejects
        // absolute paths here.
        .headerSearchPath("../../Vendor/zstd/include"),
        .define("ZSTD_STATIC_LINKING_ONLY"),
      ],
      linkerSettings: [
        .unsafeFlags([zstdLibrary]),
        .linkedLibrary("c++"),
      ]
    ),

    // MARK: - Domain model and engine contract (no UI, no platform dependency)
    .target(
      name: "HarnessKit",
      dependencies: ["CZstd"],
      path: "Sources/HarnessKit",
      swiftSettings: commonSwiftSettings
    ),

    // MARK: - Route B: Swift re-implementation of the harness core
    .target(
      name: "HarnessCore",
      dependencies: ["HarnessKit", "CZstd"],
      path: "Sources/HarnessCore",
      swiftSettings: commonSwiftSettings
    ),

    // MARK: - Runtime provisioning (install / update / plugins for the harness itself)
    .target(
      name: "HarnessRuntime",
      dependencies: ["HarnessKit"],
      path: "Sources/HarnessRuntime",
      swiftSettings: commonSwiftSettings
    ),

    // MARK: - Shared SwiftUI surface
    .target(
      name: "HarnessUI",
      dependencies: ["HarnessKit", "HarnessRuntime", "HarnessIM"],
      path: "Sources/HarnessUI",
      swiftSettings: commonSwiftSettings
    ),

    // MARK: - Runtime / plugin console surface
    //
    // Its own module rather than a pane of HarnessUI: it manages the runtime and a
    // profile's plugins and needs nothing from the transcript UI. One host — the DSHNative
    // app opens it twice, as the console window and as the plugin window, both driven by
    // one `HarnessConsoleModel`.
    .target(
      name: "HarnessConsoleUI",
      dependencies: ["HarnessKit", "HarnessRuntime"],
      path: "Sources/HarnessConsoleUI",
      swiftSettings: commonSwiftSettings
    ),

    // MARK: - Native IM channel
    //
    // A channel the app owns end to end: it speaks the provider's protocol, buffers what
    // the user sends, and submits one batch to a *running* harness over that harness's
    // local API. It deliberately depends on nothing but HarnessKit — it never installs,
    // patches, or writes anything inside the harness home, which is what keeps existing
    // harness behaviour and future harness upgrades untouched.
    .target(
      name: "HarnessIM",
      dependencies: ["HarnessKit"],
      path: "Sources/HarnessIM",
      swiftSettings: commonSwiftSettings
    ),

    // MARK: - Headless driver (route B), used by the conformance suite
    .executableTarget(
      name: "harnessctl",
      dependencies: ["HarnessKit", "HarnessCore", "HarnessRuntime", "HarnessIM"],
      path: "Sources/harnessctl",
      swiftSettings: commonSwiftSettings
    ),

    // MARK: - Tests
    .testTarget(
      name: "HarnessKitTests",
      dependencies: ["HarnessKit"],
      path: "Tests/HarnessKitTests",
      resources: [.copy("Fixtures")],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "HarnessRuntimeTests",
      dependencies: ["HarnessRuntime"],
      path: "Tests/HarnessRuntimeTests",
      resources: [.copy("Fixtures")],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "HarnessUITests",
      dependencies: ["HarnessUI", "HarnessRuntime"],
      path: "Tests/HarnessUITests",
      swiftSettings: commonSwiftSettings
    ),
    // The console/plugin windows are one host now (DSHNative), but the predicate their
    // filter uses is plain logic and belongs in a test like any other.
    .testTarget(
      name: "HarnessConsoleUITests",
      dependencies: ["HarnessConsoleUI", "HarnessRuntime"],
      path: "Tests/HarnessConsoleUITests",
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "HarnessIMTests",
      dependencies: ["HarnessIM"],
      path: "Tests/HarnessIMTests",
      resources: [.copy("Fixtures")],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "ConformanceTests",
      dependencies: ["HarnessKit", "HarnessCore"],
      path: "Tests/ConformanceTests",
      swiftSettings: commonSwiftSettings
    ),
  ]
)
