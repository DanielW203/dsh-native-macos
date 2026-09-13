#!/bin/bash
#
# `dsh` CLI shim for app-provisioned harness installs.
#
# Source of this file — install it with `Tools/build.sh shim`, which copies it to a
# directory on PATH (/opt/homebrew/bin here) as `dsh`.
#
# Why it is needed: the DSH Native app provisions its runtime by downloading a release
# package and running it with the system Node, instead of installing a global npm
# package. Nothing therefore puts a `dsh` executable on PATH, and every code path that
# shells out to the CLI — the plugin manager behind the Settings → Plugins screen, for
# one — dies with "spawn dsh ENOENT" before it does anything.
#
# Why it delegates instead of pinning a version: it reads the active release from the
# app's own installs.json at run time, so the shim keeps working across app upgrades and
# never runs a CLI different from the runtime the app is actually serving.
set -euo pipefail

# Root resolution mirrors RuntimePaths.standard(): `~/.nativeharness` wins once it holds
# a tree, and the pre-2026-09 Application Support location is used while it is the only
# populated one — an empty ~/.nativeharness must not shadow a real install.
# DSH_APP_HOME still overrides both.
populated() { [[ -d "$1/harness" || -d "$1/home" ]]; }

if [[ -n "${DSH_APP_HOME:-}" ]]; then
  ROOT="${DSH_APP_HOME%/}"
elif populated "${HOME}/.nativeharness"; then
  ROOT="${HOME}/.nativeharness"
elif populated "${HOME}/Library/Application Support/NativeHarness"; then
  ROOT="${HOME}/Library/Application Support/NativeHarness"
else
  ROOT="${HOME}/.nativeharness"
fi

HARNESS_DIR="${ROOT}/harness"
ACTIVE_JSON="${HARNESS_DIR}/installs.json"

active=""
if [[ -r "${ACTIVE_JSON}" ]]; then
  active="$(/usr/bin/plutil -extract active raw -o - "${ACTIVE_JSON}" 2>/dev/null || true)"
fi

candidates=()
if [[ -n "${active}" ]]; then
  candidates+=("${HARNESS_DIR}/releases/${active}/node_modules/@deepseek-ai/dsh/lib/bin.js")
fi
candidates+=("${HARNESS_DIR}/current/node_modules/@deepseek-ai/dsh/lib/bin.js")

# Last resort: whatever release directory exists. This keeps the shim alive if
# installs.json is absent or names a release that was pruned.
shopt -s nullglob
for release in "${HARNESS_DIR}"/releases/*/node_modules/@deepseek-ai/dsh/lib/bin.js; do
  candidates+=("${release}")
done
shopt -u nullglob

for candidate in "${candidates[@]}"; do
  if [[ -f "${candidate}" ]]; then
    exec node "${candidate}" "$@"
  fi
done

echo "dsh: no installed harness release under ${HARNESS_DIR}/releases" >&2
echo "dsh: start DSH Native once (it installs the release), or set DSH_APP_HOME." >&2
exit 127
