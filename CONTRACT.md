# NativeHarness — implementation contract

> 记号约定：`official-dsh/` 指官方 DeepSeek Harness monorepo（**不在本仓库内**，
> 仅作来源标注），本仓库不包含其代码。

**Read this before writing any code in this checkout.** It is the frozen interface
between modules so that independent work composes without a merge step.

Source of truth for *what the official runtime does*: `Spec/` (extracted fixtures) and
`official-dsh/` (the official monorepo, read-only reference). This file is
self-contained: the plan and the measurement record behind it are internal development
documents that are kept out of the published copy, and nothing here points at them.

---

## 1. Hard rules

1. **Only create or edit files inside your assigned directory.** Never edit
   `Package.swift`, `Sources/HarnessKit/**`, or another module's files. If you believe
   an interface is wrong, write the problem in your final report instead of changing
   it.
2. **Build before you report.** Run the build and make your own files compile:
   ```bash
   HARNESS_ASCII_TMP=/tmp/hn-build-<yourname> Tools/build.sh
   ```
   `HARNESS_ASCII_TMP` isolates your scratch tree from other agents' concurrent
   builds — always set it to a unique value. A plain `swift build` **will fail** on
   this machine; see the header comment in `Tools/build.sh` for why.
3. **Swift 5 language mode.** No `async` in initializers, no global-actor tricks.
   Prefer `struct`/`final class` + explicit locks where shared state exists.
4. **No new package dependencies.** Foundation, SwiftUI, AppKit, JavaScriptCore,
   Network, and the vendored `CZstd` only. No network fetching.
5. **Comment the *why*, not the *what*.** Where behaviour mirrors the official
   runtime, name the file/behaviour it mirrors. Where an observed fact drove a
   decision, state the fact in the comment — a reason a reader cannot check is not a
   reason.
6. **No placeholder stubs.** If something is genuinely out of scope, do not create an
   empty type for it; say so in the report.

---

## 2. Module graph

```
HarnessUI ──► HarnessKit ◄── HarnessEmbedded      (route A: embedded official engine)
                  ▲
                  └────────── HarnessCore           (route B: Swift re-implementation)
HarnessConsoleUI ──► HarnessRuntime ──► HarnessKit   (runtime/plugin console surface)
HarnessUI ──► HarnessIM ──► HarnessKit              (app-owned WeChat channel)
HarnessUI ──► HarnessRuntime ──► HarnessKit          (session archives; approval alerts)
CZstd ──► HarnessKit, HarnessCore                  (vendored libzstd, multi-frame)
harnessctl ──► HarnessCore, HarnessIM               (headless CLI)
```

`HarnessIM` is the app-owned WeChat channel: it speaks the provider's iLink protocol, buffers
what the user sends, and submits one batch to a **running** harness over that harness's local
`/api` channel. It depends on `HarnessKit` alone on purpose — it never installs, patches,
restarts, or writes inside the harness home, so harness behaviour and harness upgrades are
unaffected. Its state lives under the app's own root (`~/.nativeharness/im/`), never inside
`DSH_HOME`. `harnessctl im selftest` exercises the harness half end to end.

The workspace the channel submits into is a channel-wide setting (one bot, one folder) stored
in its own `config.json`. It is also editable from the phone: `/workspace` lists the folders by
**reading** the harness's `storages/workspace.json` — the same rows the desktop sidebar shows,
so the two cannot disagree — and `/workspace <n|id|path|title>` re-points the setting, drops
the cached `workspaceID`, and unbinds the asking conversation. Registering the chosen folder
still goes through the harness's own `workspace/create` RPC; nothing is written under
`DSH_HOME`.

Model and reasoning effort are editable from the phone the same way — by asking the harness, not
by keeping a second copy of the truth. `/model` reads `session/modelCatalog` (the same catalog the
desktop model menu renders), and `/model <n|id|provider/model>` plus `/effort <n|tier|默认>` call
`session/selectModel`, whose selection the host validates against the live adapters and records
durably on the session. The *current* value always comes back from the session list's
`modelSelection` projection, so a change made in the desktop window shows up on the phone instead
of being contradicted by it. A selection made before the conversation has a session is remembered
in memory and installed on the next session the channel creates; nothing about it is persisted
under `DSH_HOME`, and an existing session is never retargeted behind the user's back.

Two app-level surfaces live in `HarnessUI`/`HarnessRuntime` rather than in their own modules,
because each is a thin layer over a service that already exists:

- **Approval alerts** (`Sources/HarnessUI/Approval/`). `ApprovalAlertCenter` is the same
  `$events` subscriber as `HarnessIM.ApprovalRelay` with one deliberate difference: it
  **never answers on its own**. Only a human action — a notification action button, the
  floating panel, or the approval-centre window — produces an `allowed-once`/`rejected`
  outcome. `ApprovalPresenting` is the substitution seam for the notification centre (a test
  process has no bundle and no user to grant permission), and `SystemApprovalPresenter` adds
  the macOS category, the panel, and the delegate.
- **Turn notifications and phone forwarding** (`Sources/HarnessUI/Approval/TurnCompletionWatcher.swift`,
  `HarnessIM.WeChatChannelService.forwardTurnInfo`). `$events` carries approvals but never turn
  endings, so endings come from `session/follow` — one socket per session, capped at the most
  recently active eight. Two rules there are load-bearing, not cosmetic:
  - *A snapshot is a baseline, not news.* The opening page is history on the **first** subscription
    (an app restart must not replay yesterday's turns) and the **gap** on every reconnect. Measured
    against a live harness: a subscription taken while a turn is running is closed almost immediately
    (`session event stream skipped seq`), so a reconnect's page is exactly the ending that would
    otherwise be lost — ignoring it made the phone receive nothing at all for any session in use.
  - *Only a stream that carried a live frame earns a fast retry.* Resetting the backoff on a
    successful *open* turns that immediate close into a storm: one session was re-snapshotting
    ~160 KB/s of loopback traffic (2.3 GB in a few hours) while its log grew 25 B/s.
  The forwarded text is the turn's plain text blocks only — never its reasoning, which the harness
  writes first — and the session's `cwd`, carried on the watch target, is what locates the log.
  The same subscription also carries the *running* narration: every `assistant/message` a turn commits
  becomes an `AssistantTextSegment` and is forwarded as it is written, because the ending alone can
  only ever carry the turn's **last** paragraph. Volume is bounded twice over —
  `WeChatChannelService.narrationInterval` (5 s of collection) and `narrationBatchLimit` (400 chars,
  flushed immediately) — and the last paragraph sent is remembered, so a turn's answer, which *is* its
  last paragraph, is not delivered a second time under the headline.
  `WeChatChannelService.probePhoneLink` is the one message triggered by the user's own action rather
  than by a session: switching 手机远控 on sends a self-check, because every other message on this path
  is caused by something invisible from the phone, which makes a broken link and a quiet session look
  identical from WeChat. Its wording is phrased as "seeing this means the link works" — the sender
  learns the provider accepted the request, not that a human read it.
- **Session archives** (`Sources/HarnessRuntime/SessionArchive.swift`, UI in
  `Sources/HarnessUI/Backup/`). Export reads `$DSH_HOME/sessions` + `attachments` and writes
  one zip through `ditto`; import validates through `ArchiveInspector` before extracting, and
  never overwrites a session that already exists. Nothing under `profiles/`, `settings.yaml`,
  `.credentials.yaml` or `cordis.yml` is ever included: a backup meant to be copied elsewhere
  must not carry credentials.

`HarnessConsoleUI` is the console's SwiftUI surface (runtime install/update, plugin list,
plugin install/import). It is its own module rather than a pane of `HarnessUI` because it
needs nothing from the transcript UI. Its host is the DSHNative app, which opens it twice
from the Harness menu — the Harness Console window and the plugin window — over one shared
`HarnessConsoleModel`.

`HarnessKit` is written and frozen. It contains:

| File | Contents |
|---|---|
| `Model/JSONValue.swift` | `JSONValue` (lossless-ish JSON tree), `path(_:)` dotted lookup, `serialized()` |
| `Model/HarnessError.swift` | `HarnessError`, `SessionID` |
| `Model/Content.swift` | `ContentBlock` (`.text/.reasoning/.image/.toolUse/.toolResult/.unknown`), `Attachment`, `Usage`, `MessageSource`, `ConversationMessage` |
| `Model/SessionEvent.swift` | `EventType`, `EventEnvelope`, `SessionHeader`, `SessionEvent` + typed accessors (`toolCall`, `toolResult`, `approvalAsked`, `requestHeader`, …), payload structs |
| `Model/Tools.swift` | `ToolDescriptor`, `ToolCategory`, `ToolOrigin`, `ToolInvocation`, `ToolOutcome`, `ProgramRun`, `ProgramNode`, `ToolSurface` |
| `Model/Panels.swift` | `TodoItem`, `PlanState`, `ApprovalRequest/Decision/Record`, `UserQuestion`, `GoalRecord`, `AgentNode`, `JobRecord`, `TeamMember`, `TeamTask`, `ScheduleEntry`, `PermissionPreset`, `SandboxMode`, `ApprovalPolicy` |
| `Model/SessionSummary.swift` | `SessionSummary`, `SessionActivity`, `StreamingState` |
| `Engine/HarnessEngine.swift` | `HarnessEngine` protocol, `EngineKind`, `EngineCapabilities`, `PromptInput`, `ModelOption`, `EngineStatus` |
| `Session/SessionLogCodec.swift` | line ↔ `SessionEvent`, `SessionLogReader` (streaming, multi-frame) |
| `Session/SessionProjection.swift` | `SessionProjection` — all UI state derived from events, incl. the PTC call tree |
| `Zstd.swift` | `Zstd.decompressAll/compress/Decompressor` over the vendored libzstd |

`HarnessCore/Tools/Tool.swift` is the tool contract: `HarnessTool` protocol,
`ToolExecutionContext`, `ToolRegistry`, and the service protocols
(`FileSystemService`, `ShellService`, `JobService`, `InteractionService`,
`ToolEventSink`).

---

## 3. Facts that must not be re-derived

- **Session log** = `$DSH_HOME/sessions/<escaped-cwd>/session-<uuid>/session.jsonl.zstd`,
  a **concatenation of independently-compressed zstd frames** (one per append; 19,263
  frames measured in a 6.5 MB sample). Always go through `Zstd.Decompressor` /
  `SessionLogReader` — one-shot decompression silently returns only the first frame.
- **Two envelope shapes.** Ordinary events carry `seq`/`time`; the packed-line events
  `text-chunks`, `reasoning-chunks`, `tool-call-chunks` carry `seq0`/`time0` and hold
  *arrays* of deltas. Surface events add `surfaceOp` + `sourceEventSeqs`.
- **`tool/call.arguments` is a JSON string**, not an object — parse it.
- **Two tool presentation modes.** `direct` (every capability is a model tool) and
  `programmatic`/PTC (the model sees only `run_code`; the rest are TypeScript bindings
  called as `tools.name(args)` inside a sandbox). The user's live profile is PTC. The
  UI must render a *program tree*, not just per-call cards.
- **Tool schemas** are authoritative in `Spec/tool-catalog.schemas.json` (58 tools
  booted from `ctx.tools.schemas()` by the official generator). Copy `description` and
  `parameters` **verbatim**; never paraphrase a schema.
- **System prompt** baseline: `Spec/current-profile/system-prompt.txt` (55,644 chars,
  PTC mode) and `Spec/system-prompt.txt` (direct mode).
- **Event vocabulary**: 29 types, enumerated in `Spec/session-v3/event-schema.json`.
- **Tool approvals are one waterfall event, `approval/request`**, carrying
  `{agent, toolName, callId?, reason?}` — and nothing else (measured in
  `official-dsh/packages/interaction/user-approval/src/types.ts`). The two
  accepted outcomes are the literals `allowed-once` and `rejected`; a late answer from a
  second client fails, which is what "already handled in the browser" looks like.
  `user-questions/request` is a *different* waterfall with a structured answer shape and is
  deliberately not rendered by the native channel.
- **`session.lock` is a lease, not data** (`LEASE_FILENAME` in the harness's own
  persistence package). Archives exclude it; a restored lease would claim a lock the
  importing process does not hold.
- **The harness re-scans `sessions/` on every list call** (`list()` → `listArtifacts()` →
  `listProjectDirs`/`listSessionDirs`, all `readdir`). Imported conversations therefore
  appear after a page refresh — no harness restart is needed.
- **`FileManager.enumerator` may return `/private/var/...` for a directory built from
  `/var/...`** on this machine. Path arithmetic that subtracts such a URL's `path` from an
  enumerated child silently eats leading characters; use `subpathsOfDirectory(atPath:)`
  when relative names are needed (this bug shipped once in `SessionArchive` and was caught
  by the attachment round-trip test).

---

## 4. Conventions

- Paths in tool arguments may be relative (resolve against `ToolExecutionContext.cwd`
  via `context.resolve(_:)`), absolute, or `~`-prefixed.
- Long tool output is capped and spilled to `ToolExecutionContext.scratchDirectory`;
  the returned text names the spill path (the official runtime does the same through
  its spill store and `Tools/extract-*` shows the convention).
- Errors inside a tool should throw `ToolCallError(code:message:)`; the loop converts
  it into a `tool/result` with `data.error = {code, name}` and `isError: true`.
- Time is epoch **milliseconds** on the wire; `Date` in memory.
- Prefer `async`/`await` throughout; no completion handlers, no `DispatchQueue.main`
  (SwiftUI views hop to the main actor themselves).

---

## 5. Packaging: making DSHNative.app behave like a normal app

Xcode's Run action writes only to DerivedData, which Launchpad never scans, so an app
built and run that way can only ever be started from Xcode. To get a double-clickable
app that survives DerivedData being cleaned:

```bash
Tools/build.sh install              # Release build, then install into ~/Applications
Tools/build.sh install --system     # same, into /Applications (prompts for admin)
Tools/build.sh install --dock       # also pin it to the Dock
Tools/build.sh release              # just produce $HARNESS_ASCII_TMP/DSHNative.app
```

Facts that constrain this path, and that must not be re-derived:

- **Release must stay arm64-only.** `Vendor/zstd/lib/libzstd.a` carries an arm64-only
  slice, while Xcode's default Release target list is `arm64 x86_64` (Release does not
  set `ONLY_ACTIVE_ARCH`). The x86_64 pass fails to link, and a failed link still leaves
  a *signed* `DSHNative.app` containing nothing but an `Info.plist` — an app that
  double-clicks to nothing instead of reporting an error. The project therefore pins
  `ARCHS = $(NATIVE_ARCH_ACTUAL)`; regenerating without that setting brings the empty
  bundle back.
- `ENABLE_DEBUG_DYLIB` is `YES` in Debug: there `DSHNative` is a stub that loads
  `DSHNative.debug.dylib`, which only resolves under Xcode. Release sets it to `NO` so
  the installed bundle is a single self-contained executable.
- The app icon goes through an **asset catalog**:
  `Apps/DSHNative/Resources/Assets.xcassets/AppIcon.appiconset`, declared in
  `Tools/gen-xcodeproj.mjs` (`apps[].resources`, emitted as `folder.assetcatalog`) and
  selected by `ASSETCATALOG_COMPILER_APPICON_NAME`. Setting
  `INFOPLIST_KEY_CFBundleIconFile` instead is silently ignored under
  `GENERATE_INFOPLIST_FILE=YES`: the `.icns` lands in `Contents/Resources` but no icon
  key reaches the plist, and Finder/Launchpad still draw the blank default icon
  (measured). The catalog is also the source of `CFBundleIconName` + `CFBundleIconFile`.
  Icon PNGs were extracted from the shipped `DSH Desktop.app` icon with `iconutil`.
- **The app bundle must be signed as a whole.** `Tools/build.sh release` deliberately does
  *not* pass `CODE_SIGNING_ALLOWED=NO` (the Debug path still does): on a bundle with
  resources that flag leaves only a linker signature on the executable, no
  `_CodeSignature/CodeResources`, and `codesign --verify` fails with "code has no
  resources but signature indicates they must be present". The project's
  `CODE_SIGN_IDENTITY=-` ad-hoc identity needs no certificate.
- `Tools/build.sh release` refuses to report success unless the bundle has an executable
  **and** passes `codesign --verify --deep --strict`, so a broken build cannot be
  installed as a silently dead app.
- `~/Applications` and `/Applications` are both indexed by Launchpad; `~` needs no
  admin rights, `/Applications` does (no group write for the admin group on this
  machine). `Tools/build.sh install` re-registers the bundle with `lsregister` so the
  new location supersedes any stale registration pointing into `/tmp` or DerivedData.

### Notifications: what the installed bundle actually carries (measured 2026-09-12)

- The Release bundle links `UserNotifications.framework` (autolinked by
  `import UserNotifications`) and carries **no sandbox entitlement** — only
  `com.apple.security.get-task-allow`. Notifications therefore depend on nothing but the
  user granting permission for bundle id `ai.deepseek.nativeharness.DSHNative`.
- `UNUserNotificationCenter.current()` **traps** in a process with no bundle id (the
  SwiftPM test runner, a bare executable), so every entry point is guarded by
  `Bundle.main.bundleIdentifier != nil` and degrades to `authorization == .unavailable`.
  The floating panel and the approval-centre window are then the only surfaces — which is
  why the two are wired through one `ApprovalPresenting` seam instead of the notification
  centre being called directly.
- The notification delegate must be installed **before the app finishes launching**
  (`DSHNativeApp.init` does it) or macOS drops the action buttons of every notification.
- Action buttons appear on hover for the default "banners" style and always for "alerts";
  that is a user setting, not something the app can request.
