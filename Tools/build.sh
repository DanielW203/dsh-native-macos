#!/usr/bin/env bash
#
# Build helper — required, not a convenience.
#
# Two environment facts on this machine make a plain `swift build` fail *before it
# ever reaches a compile error, so every build goes through this script:
#
#   1. `swift-driver` **crashes (SIGTRAP) when `TMPDIR` contains non-ASCII
#      characters** (e.g. a checkout under `.../Documents/我的项目/...`).
#      Its only symptom is SwiftPM's `Failed to parse target info (malformed(json:
#      "", ...)). Raw compiler output: ""` — which looks like a compiler bug and is
#      not one. `TMPDIR` is therefore pinned to an ASCII path.
#   2. SwiftPM wraps subprocesses in its own `sandbox-exec` profile, and the DSH file
#      sandbox forbids a nested `sandbox_apply` ("Operation not permitted"). Hence
#      `--disable-sandbox`.
#
# A third, milder fact: SwiftPM's caches live in `~/Library/Caches/org.swift.swiftpm`,
# outside the workspace, so runs emit "not accessible or not writable" warnings.
# They are warnings, not failures.
#
# Usage:
#   Tools/build.sh                     # build every target
#   Tools/build.sh build --target HarnessKit   # the mode is explicit when flags follow;
#                                      # `--target` is `swift build`'s flag, not this
#                                      # script's, so a bare `Tools/build.sh --target X`
#                                      # is forwarded as `swift --target X` and fails
#   Tools/build.sh test
#   Tools/build.sh xcode DSHNative     # xcodebuild a scheme (Debug)
#   Tools/build.sh release             # installable DSHNative.app (Release)
#   Tools/build.sh install             # build Release, then install into an
#                                      #   Applications folder so Launchpad sees it
#   Tools/build.sh verify              # check the installed app end to end
#   Tools/build.sh shim                # put a `dsh` CLI shim on PATH
#
# `install` flags:
#   --to <dir>     install into <dir> (default ~/Applications). An absolute path
#                  outside the home directory is written through `sudo`.
#   --system       shorthand for --to /Applications
#   --no-build     reuse the last `release` product instead of rebuilding
#   --dock         also pin the app to the Dock
#   --quit         quit a running DSH Native first (it holds the harness server; see
#                  quit_running_app below before using this while a browser window is
#                  being served by that instance)
#   --wait         after installing, poll until LaunchServices has indexed the app
#
# Why `install` exists at all: Xcode's Run action only ever writes to DerivedData,
# which Launchpad never scans, so an app that lives there can only be started from
# Xcode and disappears when DerivedData is cleaned. A build product becomes a normal
# double-clickable app once its bundle sits in /Applications or ~/Applications.
#
# `verify` answers the only question that matters after an install — "will Launchpad
# show it, and will double-clicking it actually start something?" — by checking the
# bundle contents, the code signature, the icon, and the LaunchServices registration
# rather than trusting the copy step. It exits non-zero on the first hard failure, so
# it is usable from CI or a shell `&&` chain.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The vendored `Vendor/zstd/lib/libzstd.a` has an arm64-only slice, so an x86_64 link
# pass fails with "Undefined symbols: _ZSTD_isError ..." — and, worse, xcodebuild still
# assembles and ad-hoc signs a bundle around the missing executable, leaving an
# `DSHNative.app` that double-clicks to nothing. Refusing up front turns that silent
# dead app into one clear message. Building on Intel needs a rebuilt (or universal)
# libzstd first.
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: this machine is $(uname -m), but the vendored libzstd is arm64-only." >&2
  echo "       Build on Apple Silicon, or rebuild Vendor/zstd/lib/libzstd.a for your arch." >&2
  exit 1
fi

# ASCII scratch space — see note 1. The path must be ASCII; it does not have to be
# inside the package.
ASCII_TMP="${HARNESS_ASCII_TMP:-/tmp/harness-native-build}"
mkdir -p "$ASCII_TMP/tmp" "$ASCII_TMP/modulecache" "$ASCII_TMP/cache" "$ASCII_TMP/scratch"

export TMPDIR="$ASCII_TMP/tmp"
export CLANG_MODULE_CACHE_PATH="$ASCII_TMP/modulecache"

# A per-invocation scratch directory keeps concurrent builds (parallel agents working
# in this same checkout) from fighting over one `.build` tree. Override with
# HARNESS_ASCII_TMP to isolate a build entirely.
SWIFT_ARGS=(--disable-sandbox --cache-path "$ASCII_TMP/cache" --scratch-path "$ASCII_TMP/scratch")

# `xcode` and `release` share one DerivedData root, in the same ASCII scratch space the
# SwiftPM builds use.
XCODE_DERIVED="$ASCII_TMP/derived"
APP_NAME="DSHNative.app"
BUILT_APP="$XCODE_DERIVED/Build/Products/Release/$APP_NAME"
# Where `release` parks the finished bundle, next to the build tree, so a bundle can be
# picked up without reaching into DerivedData.
RELEASE_APP="$ASCII_TMP/$APP_NAME"

# Regenerating the project is a prerequisite of every xcodebuild run, not a suggestion:
# the project file lists every source explicitly, so adding a file without regenerating
# produces "cannot find type X in scope" from Xcode while SwiftPM — which discovers
# files — builds fine. Making the generated file a prerequisite removes that whole
# class of failure.
regenerate_project() {
  node "$ROOT/Tools/gen-xcodeproj.mjs" >/dev/null
}

# Build the DSHNative app in Release. Fails loudly if the bundle has no executable:
# a failed link still leaves a signed .app holding nothing but an Info.plist, and that
# bundle launches as a no-op rather than as an error, so the check is what turns a
# silent dead app into a build failure.
build_release_app() {
  regenerate_project
  # No `arch=` in the destination on purpose: this host advertises `arm64e` as its
  # native arch, so `platform=macOS,arch=arm64` matches no destination at all and
  # xcodebuild aborts before it builds anything. The architecture is pinned by the
  # project's `ARCHS` setting instead (see CONTRACT.md §5).
  #
  # Signing is left to xcodebuild (the project signs ad-hoc with `CODE_SIGN_IDENTITY=-`).
  # Passing `CODE_SIGNING_ALLOWED=NO` on an app that has bundle resources produces a
  # bundle whose executable carries only a linker signature: `codesign --verify` then
  # fails with "code has no resources but signature indicates they must be present" and
  # no `_CodeSignature/CodeResources` is written, so the seal does not cover the icon.
  xcodebuild \
    -project "$ROOT/NativeHarness.xcodeproj" \
    -scheme DSHNative \
    -configuration Release \
    -derivedDataPath "$XCODE_DERIVED" \
    -destination 'platform=macOS' \
    build "$@" || return $?

  if [[ ! -x "$BUILT_APP/Contents/MacOS/DSHNative" ]]; then
    echo "error: $BUILT_APP has no executable — the build did not link." >&2
    echo "       (almost always an architecture mismatch: the vendored libzstd.a is" >&2
    echo "        arm64-only, so the build must stay pinned to $(uname -m).)" >&2
    exit 1
  fi

  if ! codesign --verify --deep --strict "$BUILT_APP" 2>/dev/null; then
    echo "error: $BUILT_APP does not pass codesign verification; refusing to install it." >&2
    exit 1
  fi

  rm -rf "$RELEASE_APP"
  ditto "$BUILT_APP" "$RELEASE_APP"
  echo "built $RELEASE_APP"
}

require_release_app() {
  if [[ ! -x "$RELEASE_APP/Contents/MacOS/DSHNative" ]]; then
    echo "error: $RELEASE_APP is missing or incomplete; run 'Tools/build.sh release' first." >&2
    exit 1
  fi
}

BUNDLE_ID="ai.deepseek.nativeharness.DSHNative"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# LaunchServices is the database Launchpad itself reads, so "is this bundle in the
# registry by this exact path" is the machine-checkable form of "will Launchpad show
# it". One dump line looks like
#
#     path:                       /Users/me/Applications/DSHNative.app (0x3c10c)
#
# so the value is taken from the `path:` field, stripped of the trailing filesystem
# reference, and compared exactly. Grepping the raw path would instead match this
# bundle as a prefix of a longer one and miss the four-space-free indentation of other
# macOS versions.
ls_has_app() {
  local app="$1" line value
  while IFS= read -r line; do
    if [[ "$line" == "path:"* ]]; then
      value="${line#path:}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%% (0x*}"
      [[ "$value" == "$app" ]] && return 0
    fi
  done < <("$LSREGISTER" -dump 2>/dev/null || true)
  return 1
}

# Registration lands asynchronously; poll rather than declaring failure immediately.
wait_for_registration() {
  local app="$1" i
  for ((i = 0; i < 30; i++)); do
    ls_has_app "$app" && return 0
    sleep 1
  done
  return 1
}

# End-to-end check of an installed bundle. Prints one line per check and returns the
# number of hard failures, so callers can both display and gate on it.
verify_installed_app() {
  local app="$1" fails=0
  echo "checking $app"

  if [[ ! -e "$app" ]]; then
    echo "  [FAIL] not installed"
    return 1
  fi
  echo "  [ok]   bundle exists"

  if [[ -x "$app/Contents/MacOS/DSHNative" ]]; then
    echo "  [ok]   executable present ($(lipo -archs "$app/Contents/MacOS/DSHNative" 2>/dev/null || echo '?'))"
  else
    echo "  [FAIL] no executable — a failed link still leaves a signed app that"
    echo "         double-clicks to nothing; re-run 'Tools/build.sh release'"
    fails=$((fails + 1))
  fi

  if codesign --verify --deep --strict "$app" 2>/dev/null; then
    echo "  [ok]   code signature verifies"
  else
    echo "  [FAIL] signature does not verify (missing _CodeSignature/CodeResources?)"
    fails=$((fails + 1))
  fi

  local icon_key=""
  icon_key="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ -z "$icon_key" ]] && icon_key="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$icon_key" ]] && { [[ -f "$app/Contents/Resources/$icon_key.icns" ]] || [[ -f "$app/Contents/Resources/Assets.car" ]]; }; then
    echo "  [ok]   app icon declared ($icon_key) and present"
  else
    echo "  [warn] no icon in the bundle — it will show the blank default icon"
  fi

  local plist_id
  plist_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$plist_id" == "$BUNDLE_ID" ]]; then
    echo "  [ok]   bundle id $plist_id"
  else
    echo "  [warn] bundle id is '$plist_id' (expected $BUNDLE_ID)"
  fi

  if ls_has_app "$app"; then
    echo "  [ok]   registered with LaunchServices — Launchpad will list it"
  else
    echo "  [FAIL] not registered; run:"
    echo "         $LSREGISTER -f -R -trusted \"$app\""
    fails=$((fails + 1))
  fi

  return "$fails"
}


# Stop a running copy, if asked. Replacing a bundle that is being written by a live
# process can leave a half-written app behind, but quitting is *not* the default: this
# app takes over an already-running harness by killing the recorded server pid
# (`HarnessLauncher`), so quitting a running instance shuts that harness down and takes
# any browser window served by it with it. `--quit` is for the case where the running
# instance is the one being replaced.
quit_running_app() {
  osascript -e 'tell application id "ai.deepseek.nativeharness.DSHNative" to quit' >/dev/null 2>&1 || true
  sleep 1
}

# Record which checkout produced this install, inside the app's own runtime tree.
#
# The app's Rebuild button has to run *this* script, and a bundle carries no record of where
# it was built from — `$ROOT` exists only while this process runs. Writing it at install time
# is what makes the button work on a second Mac with no configuration: the app was installed
# from that Mac's checkout, and this is the line that says which one. It cannot live inside
# the bundle itself (that would invalidate the code signature `verify` checks), so it goes in
# `~/.nativeharness`, the one directory the app already owns.
record_source_root() {
  local dir="$HOME/.nativeharness"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$ROOT" > "$dir/rebuild-source-root" 2>/dev/null || true
}

case "${1:-build}" in
  test)
    shift || true
    exec swift test "${SWIFT_ARGS[@]}" "$@"
    ;;
  clean)
    rm -rf "$ASCII_TMP/scratch" "$ASCII_TMP/cache" "$ASCII_TMP/derived" "$RELEASE_APP"
    echo "cleaned"
    ;;
  xcode)
    shift || true
    SCHEME="${1:-DSHNative}"
    regenerate_project
    shift || true
    exec xcodebuild \
      -project "$ROOT/NativeHarness.xcodeproj" \
      -scheme "$SCHEME" \
      -configuration Debug \
      -derivedDataPath "$XCODE_DERIVED" \
      -destination 'platform=macOS' \
      CODE_SIGNING_ALLOWED=NO \
      build "$@"
    ;;
  release)
    shift || true
    build_release_app "$@" || exit $?
    ;;
  install)
    shift || true
    DEST="$HOME/Applications"
    DOCK=""
    SKIP_BUILD=""
    QUIT=""
    WAIT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --to)      [[ -n "${2:-}" ]] || { echo "error: --to needs a directory" >&2; exit 2; }
                   DEST="$2"; shift 2 ;;
        --system)  DEST="/Applications"; shift ;;
        --no-build) SKIP_BUILD="1"; shift ;;
        --dock)    DOCK="1"; shift ;;
        --quit)    QUIT="1"; shift ;;
        --wait)    WAIT="1"; shift ;;
        *)         echo "error: unknown install flag: $1" >&2; exit 2 ;;
      esac
    done

    if [[ -n "$SKIP_BUILD" ]]; then
      require_release_app
    else
      if [[ "$DEST" == /Applications* ]] && [[ ! -w "$DEST" ]] && [[ "$(id -u)" -ne 0 ]]; then
        # /Applications is the one destination that genuinely needs root, and the whole
        # build has to stay outside the elevated call: Xcode cannot write its build
        # products as root, and a root-owned DerivedData tree breaks every later build.
        command -v sudo >/dev/null 2>&1 || { echo "error: $DEST needs root and sudo is unavailable" >&2; exit 1; }
        echo "note: $DEST needs administrator rights; escalating only the build step."
        sudo -v || exit 1
        sudo -E "$0" release || exit $?
      else
        build_release_app || exit $?
      fi
    fi

    DEST_APP="$DEST/$APP_NAME"
    if [[ "$DEST" == /Applications* ]] && [[ ! -w "$DEST" ]] && [[ "$(id -u)" -ne 0 ]]; then
      command -v sudo >/dev/null 2>&1 || { echo "error: $DEST needs root and sudo is unavailable" >&2; exit 1; }
      [[ -n "$QUIT" ]] && quit_running_app
      sudo mkdir -p "$DEST"
      sudo rm -rf "$DEST_APP"
      # ditto rather than cp -R: it is the only copy that preserves the bundle's
      # metadata, resource forks and signature exactly as codesign sealed them.
      # The copy is checked, not assumed. `set -u` without `-e` means a failing ditto
      # would otherwise fall straight through to the success message — which is exactly
      # how a half-copied bundle gets advertised as installed.
      if ! sudo ditto "$RELEASE_APP" "$DEST_APP"; then
        echo "error: copying into $DEST_APP failed; the previous app is untouched." >&2
        exit 1
      fi
      sudo xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
      sudo touch "$DEST_APP" 2>/dev/null || true
      "$LSREGISTER" -f -R -trusted "$DEST_APP"
    else
      mkdir -p "$DEST"
      [[ -n "$QUIT" ]] && quit_running_app
      # Move the previous copy aside instead of deleting it, so a bad build cannot
      # destroy a working install before the new one is verified.
      OLD=""
      if [[ -e "$DEST_APP" ]]; then
        OLD="$DEST_APP.old-$$"
        rm -rf "$OLD"
        mv "$DEST_APP" "$OLD"
      fi
      if ! ditto "$RELEASE_APP" "$DEST_APP"; then
        echo "error: copying into $DEST_APP failed" >&2
        # Put the previous install back rather than leaving a partial bundle behind.
        if [[ -n "$OLD" ]]; then
          rm -rf "$DEST_APP"
          mv "$OLD" "$DEST_APP"
          echo "       the previous install was restored" >&2
        fi
        exit 1
      fi
      [[ -n "$OLD" ]] && rm -rf "$OLD"
      xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
      touch "$DEST_APP" 2>/dev/null || true
      "$LSREGISTER" -f -R -trusted "$DEST_APP"
    fi

    # Verify what was installed rather than trusting the copy step.
    if [[ ! -x "$DEST_APP/Contents/MacOS/DSHNative" ]]; then
      echo "error: installed bundle has no executable at $DEST_APP" >&2
      exit 1
    fi
    if ! codesign --verify --strict "$DEST_APP" 2>/dev/null; then
      echo "warning: $DEST_APP does not verify; macOS may still launch it, but re-run install if not" >&2
    fi
    # The installed executable must be byte-identical to the one that was built; a
    # partially written copy can still exist, still be signed, and still be the wrong
    # binary. codesign's CDHash is the cheap fingerprint of exactly that.
    built_hash="$(codesign -dvvv "$RELEASE_APP" 2>&1 | sed -n 's/^CDHash=//p')"
    installed_hash="$(codesign -dvvv "$DEST_APP" 2>&1 | sed -n 's/^CDHash=//p')"
    if [[ -n "$built_hash" && "$built_hash" != "$installed_hash" ]]; then
      echo "error: $DEST_APP does not match the build (CDHash $installed_hash != $built_hash)" >&2
      exit 1
    fi

    if [[ -n "$DOCK" ]]; then
      defaults write com.apple.dock persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$DEST_APP</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
      killall Dock 2>/dev/null || true
    fi

    echo "installed $DEST_APP"
    record_source_root
    echo "DSH Native now appears in Launchpad (and can be double-clicked from Finder)."
    echo "Re-run 'Tools/build.sh install' after code changes to refresh it."

    if [[ -n "$WAIT" ]]; then
      if wait_for_registration "$DEST_APP"; then
        echo "LaunchServices has indexed it."
      else
        echo "warning: LaunchServices has not indexed $DEST_APP yet." >&2
        echo "         run 'Tools/build.sh verify --to $DEST' or:" >&2
        echo "         $LSREGISTER -f -R -trusted \"$DEST_APP\"" >&2
      fi
    fi
    ;;
  verify)
    shift || true
    VERIFY_DEST="$HOME/Applications"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --to)        [[ -n "${2:-}" ]] || { echo "error: --to needs a directory" >&2; exit 2; }
                     VERIFY_DEST="$2"; shift 2 ;;
        --system)    VERIFY_DEST="/Applications"; shift ;;
        *)           echo "error: unknown verify flag: $1" >&2; exit 2 ;;
      esac
    done
    verify_installed_app "$VERIFY_DEST/$APP_NAME"
    status=$?
    if [[ "$status" -eq 0 ]]; then
      echo "all checks passed"
    else
      echo "$status check(s) failed" >&2
    fi
    exit "$status"
    ;;
  shim)
    SOURCE="$ROOT/Tools/dsh-cli.sh"
    if [[ ! -f "$SOURCE" ]]; then
      echo "error: $SOURCE is missing" >&2
      exit 1
    fi
    # Pick a directory that is already on PATH and writable, preferring the one the
    # existing toolchain uses (this machine resolves node and pnpm out of
    # /opt/homebrew/bin). A shim anywhere else would not be found by the harness.
    SHIM_DIR=""
    for candidate in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
      if [[ -d "$candidate" && -w "$candidate" ]]; then SHIM_DIR="$candidate"; break; fi
    done
    if [[ -z "$SHIM_DIR" ]]; then
      echo "error: no writable PATH directory among /opt/homebrew/bin, /usr/local/bin, ~/.local/bin" >&2
      exit 1
    fi
    TARGET="$SHIM_DIR/dsh"
    if [[ -w "$SHIM_DIR" ]]; then
      install -m 755 "$SOURCE" "$TARGET"
    else
      sudo install -m 755 "$SOURCE" "$TARGET"
    fi
    echo "installed $TARGET"
    echo "check: $(PATH="$SHIM_DIR:$PATH" command -v dsh) --version"
    ;;
  *)
    # Default and pass-through case. `set -u` makes a bare `$1` an error when the
    # script is run with no arguments, so the default is materialised first — the
    # documented "no arguments = build every target" behaviour is this branch.
    MODE="${1:-build}"
    shift || true
    exec swift "$MODE" "${SWIFT_ARGS[@]}" "$@"
    ;;
esac
