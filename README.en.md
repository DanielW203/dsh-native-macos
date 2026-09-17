# NativeHarness (DSH Native)

**English** · [简体中文](README.md)

**A native macOS client for DeepSeek Harness — any version installable, upgrades self-checked, rollback when something breaks; phone remote control behind a single switch.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B%20%C2%B7%20arm64-lightgrey.svg)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](Package.swift)

It puts the [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) Web UI inside a native macOS
window: a SwiftUI shell plus a harness runtime the app manages for you. Installing harness releases, switching
versions, provisioning Node and managing plugins are all the app's job — open it and go, with no manual
`npm install` and no browser tab to keep around.

> ⚠️ **Unofficial project.** This is a third-party client shell with no affiliation with, or endorsement by,
> DeepSeek. The `@deepseek-ai/dsh` package it downloads and runs is an official project; its license and terms
> are the official ones. The app icon contains DeepSeek brand marks and is **not covered by the MIT license** —
> see [NOTICE.md](NOTICE.md).

## Highlights

- **Native window**: the harness Web UI runs in an app window, not a browser; if Node is missing the app installs a private copy and leaves your system alone
- **Version management**: works across official versions, self-checks every upgrade, and can roll back to an older release whenever you need to fix something (next section)
- **Multiple windows**: several views of the same harness, opened repeatedly with ⌥⌘N; only the main window can start or stop the server
- **WeChat IM + phone remote control**: `/list`, `/use`, `/history`, `/say`, `/stop`, `/answer`, `/workspace`,
  `/model`, `/effort`; with remote control on, approvals and questions go to WeChat, and each desktop turn forwards
  its result plus the reply text
- **Plugin management**: install / remove / import / repair profile plugins, with a compatibility verdict per plugin
- **Safe start and recovery**: two levels of escape — drop the plugins first, then the whole home — plus a recovery window that can roll configuration back
- **Local only**: everything lives under your own home directory; no telemetry, no account

## Screenshots

| Main window: the harness Web UI | Console: version update + 8-item self-check |
|---|---|
| ![Main window](docs/screenshots/main-window.png) | ![Console](docs/screenshots/console-upgrade.png) |

| WeChat channel: phone remote control | Recovery mode: config rollback |
|---|---|
| ![WeChat channel](docs/screenshots/wechat-channel.png) | ![Recovery mode](docs/screenshots/recovery.png) |

| Plugin management: enable / install / repair | Plugin compatibility: per-package declared ranges |
|---|---|
| ![Plugin management](docs/screenshots/plugins.png) | ![Plugin compatibility](docs/screenshots/plugin-compatibility.png) |

## How it differs from the other desktop clients

The ecosystem already has two mature cross-platform desktop clients:
[`dataelement/dsh-desktop`](https://github.com/dataelement/dsh-desktop) (Electron) and
[`dsh-tauri/deepseek-harness-desktop`](https://github.com/dsh-tauri/deepseek-harness-desktop) (Tauri). They cover
Windows / Linux and "download and run". This project is macOS-only, and its differences are ordered by how
**verifiable** they are:

1. **Runtime reliability**: versions coexist; after an upgrade it runs 8 checks (`boot` and `rpc-endpoints` are
   blocking); if a blocking check fails it rolls back **once**, never in a loop; the release currently acting as
   the rollback target cannot be deleted; an upgrade interrupted mid-flight is resolved on the next launch.
   The evidence is on your disk — `~/.nativeharness/harness/upgrade-report.json` and `upgrade-reports/`, not
   marketing copy (implementation: `Sources/HarnessRuntime/HarnessUpgradeCoordinator.swift`,
   `Sources/HarnessUI/Upgrade/`).
2. **The shell *is* SwiftUI / AppKit**: not a web front end on a cross-platform runtime (the Electron client's shell
   is Electron, the Tauri client's shell is Rust + web). The harness Web UI is a web page in every client —
   Electron bundles Chromium, while Tauri and this project use the system `WKWebView`.
3. **Two more levels of failure handling than "reinstall"**: safe mode (drop plugins, keep the real home) →
   clean environment (throwaway home) → a recovery window that rolls declarative configuration back
   (3 rotating slots, never touching `node_modules`) — implementation:
   `Sources/HarnessRuntime/SafeBoot.swift`, `Sources/HarnessRuntime/ProfileCheckpoint.swift`.
4. **Many windows, one harness**: every window is a view of the same server (shared address, no second server),
   and only the main window can start or stop it — no process with two owners
   (implementation: `Sources/HarnessUI/Shell/HarnessPageWindow.swift`).
5. **Phone remote control out of the box**: the WeChat channel, approval push and per-turn forwarding are built-in
   switches rather than a bridge plugin you install yourself (implementation:
   `Sources/HarnessIM/WeChatChannelService.swift`).
   ⚠️ The ecosystem already has several comparable WeChat plugins (at least eight), so this is **neither "first"
   nor "the only"**.

The first four are differences you can trace to specific files and branches; the fifth is a packaging difference,
not a technical lead.

---

## Version upgrades: high compatibility · self-check after upgrade · rollback any time

### 1. High compatibility with different official versions

| Mechanism | How |
|---|---|
| Discovering updates | **Two channels**: the npm registry (including prereleases) and GitHub prebuilt releases; one being unreachable does not affect the other |
| Installing any version | **Five sources** are accepted: a registry version, a GitHub release, a prebuilt package, a source archive, a source checkout (built with pnpm) |
| Validating before commit | The entry point exists and `--version` actually runs; only then is the install committed (as an atomic rename on the same volume) |
| Versions side by side | Every release has its own directory and can be activated at any time; `installs.json` records where each came from |
| Tool-surface drift | The `tool-vocabulary` check verifies the app recognises every tool name the new version announces |
| Plugin compatibility | Each plugin's declared semver ranges are compared against the harness packages; verdicts show up in "Plugin Compatibility…" (⌥⌘P) and in the plugin list |

### 2. A self-check after every upgrade

"**Download and update**" (or "**Update and restart**" on an already installed release) runs **activate → restart →
self-check**. The 8 results are written to `~/.nativeharness/harness/upgrade-report.json`, with a timestamped
history copy under `~/.nativeharness/harness/upgrade-reports/`.

| Check | What it looks at | Blocking on failure |
|---|---|---|
| `boot` | The new version really came up and announced its address | **Yes** |
| `rpc-endpoints` | The expected RPC endpoints are all there | **Yes** |
| `session-list` | The session list is readable | No |
| `session-log` | The session log is readable (`session.v3.jsonl.zstd`) | No |
| `events-stream` | `$events` connects and delivers a ready frame | No |
| `turn-follow` | A turn's snapshot frame can be followed | No |
| `tool-vocabulary` | Every announced tool name is known to this app | No |
| `plugins` | No conflicting declarations among installed plugins | No |

**A blocking failure puts the old version straight back**, and the reason (failed boot / which checks did not
pass) is written into the report and shown in the UI.

### 3. Switch back to an older version whenever something breaks

- **Automatic rollback**: if the new version does not come up, or a blocking check fails, the previous version is
  restored — exactly once, never in a loop.
- **Manual rollback**: the console's "Version update" card and "Update and restart" can move the runtime to **any
  installed release**; a rollback runs the same self-check path, and the target is verified too.
- **Interruption safety**: the rollback marker is written before anything moves; a crash or quit loses no state,
  and the next launch finishes the decision (confirm if it came up, roll back if it did not).
- **Protected rollback target**: the release currently acting as the rollback target cannot be removed, so there
  is never a state with no way back.
- **Note**: the self-check only runs on "Download and update" / "Update and restart". In the list, **Install**
  means "install and activate only — no restart, no checks", and **Activate** means "switch the version only — no
  restart, no checks".

---

## Requirements

| | Requirement |
|---|---|
| OS | macOS 15 (Sequoia) or later |
| Architecture | **Apple Silicon (arm64)** — see [known limitations](#known-limitations) |
| Build tools | Xcode 16+ (with command line tools), Swift 6, Node.js (used to generate the Xcode project) |
| Network | First launch needs access to `registry.npmjs.org` and `nodejs.org` |

```bash
sw_vers && uname -m && xcodebuild -version && node --version
```

## Install into Launchpad

> There is **no prebuilt package yet**: you build it locally, starting with Apple Silicon + Xcode 16.

**No Apple Developer account needed**: the app is built locally with ad-hoc signing, so there is no certificate, no
notarization, and Gatekeeper will not block it.

```bash
cd /path/to/dsh-native-macos
Tools/build.sh release               # 1. build the Release app (product: /tmp/harness-native-build/DSHNative.app)
Tools/build.sh install --no-build    # 2. install into ~/Applications (a directory Launchpad indexes)
Tools/build.sh verify                # 3. verify: bundle, executable, signature, icon, LaunchServices registration
```

Or in one step: `Tools/build.sh install` (options: `--wait` to wait for indexing, `--system` for a global install,
`--dock` to pin to the Dock, `--quit` to quit a running copy first). After changing code, just run it again — the
Launchpad icon stays the same.

**Why you cannot just press ▶ Run in Xcode**: Xcode only writes to `DerivedData`, while Launchpad only indexes
`/Applications` and `~/Applications`; and Debug builds enable `ENABLE_DEBUG_DYLIB`, so a copied bundle will not
launch. A Release build installed into one of those two directories is what `install` does.

**Optional**: install a version-agnostic `dsh` shim (plugin install/remove in Settings needs `dsh` on `PATH`):

```bash
Tools/build.sh shim && dsh --version
```

## Runtime tree

The app keeps a runtime tree of its own under your home directory (default `~/.nativeharness`, overridable with
`NATIVE_HARNESS_ROOT`):

| Path | Contents |
|---|---|
| `harness/` | Every release, `installs.json`, `current`, logs, checkpoints, upgrade reports |
| `home/` | The `DSH_HOME` handed to the harness: profiles, sessions, settings, credentials |
| `runtime/` | npm caches and friends |
| `safe-mode/` | Only during a safe start: the mode marker and the throwaway home |

## Safe start and recovery mode

The plugin loader has no per-plugin isolation, so one bad plugin can take the whole boot down — and the interface
you would use to disable it (the Web UI) is exactly what fails to open. The **Harness** menu offers three start
modes:

| Mode | Home used | Profile used | What is isolated away |
|---|---|---|---|
| Normal start | real | `web` | — |
| **Safe mode · no plugins** | real | `rescue` (official web template) | Third-party plugins |
| **Clean environment** | throwaway | `web` | Plugins + patches + settings + credentials + sessions |

Both reuse the release and Node you already installed — nothing is downloaded or copied — so the diagnosis is
decidable: safe mode comes up → a plugin problem; only the clean environment comes up → a home-layer problem;
neither comes up → an app-side problem (the recovery window gives the verdict).

**The recovery window (⌥⌘R)** works on the real `DSH_HOME` and has four sections: start mode, configuration check
and repair, **configuration rollback** (a declarative config snapshot is taken after every confirmed listen; restore
previews first and stops the harness), and data and diagnostics. In safe mode the WeChat channel does not start and
plugin-related menu items are disabled.

## Building from source (developers)

```bash
Tools/build.sh                       # build every target
Tools/build.sh test                  # run the tests
Tools/build.sh build --target HarnessKit   # build one target
Tools/build.sh xcode DSHNative       # xcodebuild a scheme (Debug)
Tools/build.sh clean                 # clean caches and products
```

Two reasons the scripts are mandatory: `swift-driver` crashes when `TMPDIR` contains non-ASCII characters (the
script pins `TMPDIR` to an ASCII path), and a nested `sandbox_apply` is not permitted in a restricted environment
(the script passes `--disable-sandbox`). `NativeHarness.xcodeproj` is generated by `Tools/gen-xcodeproj.mjs` — after
adding source files just re-run a command, and never hand-edit the `.pbxproj`.

```
Apps/DSHNative/      @main app, windows and menus (SwiftUI)
Sources/
  HarnessKit/        Domain models and engine contracts (no UI dependency)
  HarnessCore/       Route B: a Swift reimplementation of the harness core
  HarnessRuntime/    Runtime supply: install/update harness, Node, plugins, release validation, upgrade coordination
  HarnessUI/         Shared SwiftUI interface (including the upgrade self-check)
  HarnessConsoleUI/  Console / plugin / market windows
  HarnessIM/         WeChat IM channel (protocol, batching, talking to a running harness)
  harnessctl/        Command line tool
  CZstd/             The only place that links the vendored libzstd
Vendor/zstd/         The libzstd static library shipped with the repository
Tools/               Build, install and verify scripts + project generator
Tests/               Unit tests and fixtures
Spec/                Upstream-aligned request headers, tool schemas, session event schemas
```

## Known limitations

- **Apple Silicon only**: `Vendor/zstd/lib/libzstd.a` has an arm64 slice only, so a link pass on an Intel Mac fails
  (and leaves behind a half-built `.app` that does nothing when double-clicked).
- **Not notarized, no Developer ID signature**: local builds install and run as-is, but distributing a build means
  Gatekeeper will block it for others (`xattr -dr com.apple.quarantine`, or sign and notarize it yourself).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Failed to parse target info (malformed(json: "", ...))` | You ran `swift build` directly and the path contains non-ASCII characters; use `Tools/build.sh` |
| `swift build` reports sandbox / `Operation not permitted` | The script already passes `--disable-sandbox`; do not bypass the scripts |
| Settings → Plugins reports `spawn dsh ENOENT` | Run `Tools/build.sh shim` |
| The app is missing from Launchpad, or does nothing when double-clicked | Make sure it is installed in `~/Applications` or `/Applications` and run `Tools/build.sh verify`; for a half-built bundle, re-run `install` |
| Moving the runtime tree somewhere else | Use `Tools/relocate-root.sh` (quits the app first, does a same-volume atomic `mv`, leaves a symlink at the old path) |
| Want to go back to an older version after an upgrade | The console's "Version update" card, or "Update and restart" on an installed release — see [above](#3-switch-back-to-an-older-version-whenever-something-breaks) |

`Tools/build.sh install --quit` takes over a harness that is already running, so if a browser window is being served
by that same harness, quitting it closes that window too.

## Uninstall

```bash
osascript -e 'tell application id "ai.deepseek.nativeharness.DSHNative" to quit'
rm -rf ~/Applications/DSHNative.app
rm -rf ~/.nativeharness          # sessions, settings, plugins and every installed release live here — think first
rm -f /opt/homebrew/bin/dsh      # if you installed the shim
```

## License

The code in this repository is released under [MIT](LICENSE). The upstream `@deepseek-ai/dsh` and the harness itself
are not part of this repository; their license and terms are the official ones.
