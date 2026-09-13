#!/usr/bin/env bash
#
# publish.sh — 把源目录的改动同步到公开发布副本，并推送到 GitHub。
#
# 这是给日常更新用的：改完 harness-native/ 里的代码，跑这一条就行。
#
# 用法:
#   Tools/publish.sh                    # 只同步并在副本里列出改动，不提交
#   Tools/publish.sh "提交说明"          # 同步 + 提交 + 推送
#
# 前提: ../harness-native-public 已经是一个 git 仓库并且配好了 origin。
# 说明: 同步由 Tools/export-public.sh 完成（它会保留副本的 .git，其余内容按源目录重建）。

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$(dirname "$SRC")/harness-native-public"
MESSAGE="${1:-}"

if [ ! -d "$DEST/.git" ]; then
  echo "error: $DEST 还不是 git 仓库。" >&2
  echo "       先在发布副本里初始化并关联 origin：git init -b main && git add -A && git commit && git remote add origin <URL>" >&2
  exit 1
fi

# ── ① 同步（含脱敏与体检）────────────────────────────────────────────────────
"$SRC/Tools/export-public.sh"

cd "$DEST"

# ── ② 有没有改动 ─────────────────────────────────────────────────────────────
if [ -z "$(git status --porcelain)" ]; then
  echo
  echo "源目录与发布副本一致，没有需要提交的改动。"
  exit 0
fi

echo
echo "── 改动清单 ──────────────────────────────────────────────────"
git status --short

if [ -z "$MESSAGE" ]; then
  echo
  echo "（已同步到发布副本，但还没提交。）"
  echo "  确认上面的清单没问题后，带上提交说明再跑一次："
  echo "      Tools/publish.sh \"你改了什么\""
  echo
  echo "  想先看具体改了什么，可以在这里跑：git diff"
  exit 0
fi

# ── ③ 提交并推送 ─────────────────────────────────────────────────────────────
git add -A
git commit -m "$MESSAGE"
echo
echo "── 推送到 GitHub ─────────────────────────────────────────────"
git push
echo
echo "完成。仓库地址：$(git remote get-url origin)"
