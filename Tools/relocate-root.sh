#!/usr/bin/env bash
#
# relocate-root.sh — 把**已有**的 NativeHarness 运行时根目录从
#   ~/Library/Application Support/NativeHarness
# 搬到 ~/.nativeharness（新版本 App 的默认 root），并在原位置留一个符号链接。
#
# 新安装不需要这个脚本：`RuntimePaths.standard()` 现在默认就是 `~/.nativeharness`。
# 它服务于升级前已经装过的机器 —— 旧位置的数据不会被自动搬（避免看起来像数据丢失），
# 而搬的时候又不能让树内那些写死绝对路径的符号链接失效。
#
# 为什么留符号链接而不是只改环境变量：目录内部有大量**绝对路径**符号链接
# （profiles/web/.dsh-module-fallback/node_modules/* 等，实测 500+ 条）以及
# harness/current，它们写死了旧路径。留一个指向新位置的链接，这些路径全部继续
# 可解析，不需要改代码、改环境变量、也不需要重装 runtime 或重装插件。
# 代码侧同时保留"旧 root 存在就用旧的"回退，所以万一链接被删，也只是换回旧路径，
# 不会丢数据。
#
# 用法：
#   Tools/relocate-root.sh --dry-run              # 只看会做什么，不动任何东西
#   Tools/relocate-root.sh                        # 搬到 ~/.nativeharness
#   Tools/relocate-root.sh ~/NativeHarness        # 搬到指定目录
#   Tools/relocate-root.sh --relaunch             # 搬完顺便重新打开 DSH Native
#   Tools/relocate-root.sh --no-quit              # 不自动退出 App（你自己负责先退出）
#
# 回滚（把一切还原）：
#   rm ~/Library/Application\ Support/NativeHarness && \
#     mv ~/.nativeharness ~/Library/Application\ Support/NativeHarness
set -euo pipefail

OLD="${HOME}/Library/Application Support/NativeHarness"
NEW_DEFAULT="${HOME}/.nativeharness"
APP_ID="ai.deepseek.nativeharness.DSHNative"

NEW=""
DRY_RUN=0
QUIT_APP=1
RELAUNCH=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
act() { if (( DRY_RUN )); then printf '  [dry-run] %s\n' "$*"; else printf '  %s\n' "$*"; fi; }

while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-quit) QUIT_APP=0; shift ;;
    --relaunch) RELAUNCH=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$NEW" ] || die "only one target directory is accepted"; NEW="$1"; shift ;;
  esac
done
[ -n "$NEW" ] || NEW="$NEW_DEFAULT"

# ~ 与 .. 展开、去掉尾部斜杠，便于比较
NEW="$(cd "$(dirname "$NEW")" 2>/dev/null && pwd)/$(basename "$NEW")" 2>/dev/null || NEW="${NEW%/}"

say "native harness root relocation"
say "  from : ${OLD}"
say "  to   : ${NEW}"
(( DRY_RUN )) && say "  mode : dry-run（不会改动任何文件）"

# ---------------------------------------------------------------- 前置检查
[ -e "$OLD" ] || die "source does not exist: $OLD"

if [ -L "$OLD" ]; then
  say ""
  say "already relocated: ${OLD} -> $(readlink "$OLD")"
  exit 0
fi

case "$NEW" in
  "$OLD"|"$OLD"/*) die "target is inside the source; pick a directory outside ${OLD}" ;;
esac
case "$NEW" in
  "${HOME}/Desktop"|"${HOME}/Desktop/"*|"${HOME}/Documents"|"${HOME}/Documents/"*|"${HOME}/Downloads"|"${HOME}/Downloads/"*)
    say "warning: ${NEW} 位于 Desktop/Documents/Downloads —— 这些目录受 macOS TCC 保护，App 首次访问会弹权限请求。"
    say "warning: 建议直接用 ~/.nativeharness 或 ~/NativeHarness 这种主目录直属位置。"
    ;;
esac

if [ -e "$NEW" ]; then
  die "target already exists: $NEW（先自己确认/移走它，本脚本绝不覆盖已有数据）"
fi

# 必须同一个卷，mv 才是原子的 rename；跨卷要复制 652MB 且失败会留半个树
src_dev="$(stat -f %d "$OLD")"
dst_dev="$(stat -f %d "$(dirname "$NEW")" 2>/dev/null || stat -f %d "$HOME")"
[ "$src_dev" = "$dst_dev" ] || die "target is on a different volume; this script only does an atomic same-volume rename"

size="$(du -sh "$OLD" 2>/dev/null | awk '{print $1}')"
say "  size : ${size:-unknown}"

# ------------------------------------------------------- 确认没有进程在写
harness_pid=""
if [ -r "$OLD/harness/server.json" ]; then
  harness_pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$OLD/harness/server.json" | head -1)"
fi

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

if alive "$harness_pid"; then
  say ""
  say "harness 正在运行（pid ${harness_pid}）"
  if (( QUIT_APP )); then
    act "请求退出 DSH Native（bundle id ${APP_ID}）"
    if (( ! DRY_RUN )); then
      osascript -e "tell application id \"${APP_ID}\" to quit" >/dev/null 2>&1 || true
      for _ in $(seq 1 30); do alive "$harness_pid" || break; sleep 1; done
      alive "$harness_pid" && die "harness (pid ${harness_pid}) still alive after 30s; 手动退出 App 后加 --no-quit 重跑"
      say "  已退出"
    fi
  else
    (( DRY_RUN )) || die "harness still running (pid ${harness_pid}); 先退出 DSH Native"
  fi
else
  say "  no running harness detected (server.json 无存活 pid)"
fi

# ----------------------------------------------------------------- 执行
say ""
act "mv \"${OLD}\" \"${NEW}\""
act "ln -s \"${NEW}\" \"${OLD}\""

if (( ! DRY_RUN )); then
  # 中途任何写入都会在旧路径上重建目录，导致 ln -s 失败 —— 先摆好父目录，失败即中止
  mkdir -p "$(dirname "$NEW")"
  mv "$OLD" "$NEW"
  if ! ln -s "$NEW" "$OLD"; then
    printf 'error: failed to create symlink; rolling back\n' >&2
    mv "$NEW" "$OLD"
    exit 1
  fi
fi

# ----------------------------------------------------------------- 验证
say ""
say "verification"
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then printf '  [ok]   %s\n' "$1"; else printf '  [FAIL] %s\n' "$1"; fail=1; fi; }

if (( DRY_RUN )); then
  say "  [dry-run] 跳过验证（未做任何改动）"
else
  chk "旧路径现在是符号链接" "[ -L \"$OLD\" ]"
  chk "installs.json 可读" "[ -r \"$NEW/harness/installs.json\" ]"

  active="$(sed -n 's/.*"active"[[:space:]]*:[[:space:]]*"\([^\"]*\)".*/\1/p' "$NEW/harness/installs.json" | head -1)"
  if [ -n "$active" ]; then
    entry="$NEW/harness/releases/${active}/node_modules/@deepseek-ai/dsh/lib/bin.js"
    chk "active release ${active} 入口存在" "[ -f \"$entry\" ]"
    chk "旧的绝对路径仍能解析到同一入口" \
      "[ -f \"\$HOME/Library/Application Support/NativeHarness/harness/releases/${active}/node_modules/@deepseek-ai/dsh/lib/bin.js\" ]"
  else
    say "  [warn] installs.json 里没有 active（尚未装过 runtime）"
  fi

  broken="$(find "$NEW" -xtype l 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$broken" = "0" ]; then
    printf '  [ok]   树内无失效符号链接（绝对路径链接全部仍可解析）\n'
  else
    printf '  [warn] 树内 %s 条失效符号链接（多为 pnpm/模块回退目录，可在 App 内重装插件修复）\n' "$broken"
  fi

  if command -v dsh >/dev/null 2>&1; then
    chk "dsh --version（走 PATH 上的 shim）" "dsh --version"
  fi

  say ""
  say "完成：${NEW}"
  say "  回滚： rm \"${OLD}\" && mv \"${NEW}\" \"${OLD}\""
  say "  注意：别删掉 ${OLD} 这个符号链接，否则 App 会在旧路径重新建一个空根目录，看起来像数据丢了（数据仍在 ${NEW}）。"
fi

if (( RELAUNCH )); then
  act "重新打开 DSH Native"
  (( DRY_RUN )) || open -b "$APP_ID" || true
fi

exit "$fail"
