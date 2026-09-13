#!/usr/bin/env bash
#
# export-public.sh — 把本仓库导出成一份可以公开发布的干净副本。
#
# 设计原则：**白名单，不是黑名单。**
#
# 旧版用一长串 `! -name ...` 排除项，等于「除了我想到的，全都发」—— 每新增一份内部
# 文档（PLAN.md、M0-FINDINGS.md、以后任何 NOTES.md / REPORT.md）都是一次沉默的泄露，
# 而且只有人想起来才会去补一行。现在反过来了：**只有 PUBLISH 里列出的目录/文件会出去，
# 其余一律不发**。新增文件默认是私有的，想让它公开必须显式改 PUBLISH —— 一次刻意的
# 决定，而不是一次遗忘。
#
# 脚本做的四件事：
#   1) 按 PUBLISH 白名单收集文件
#   2) 挡住本机产物与含个人信息的参考样本（.build / 生成的工程 / prompt 快照 / meta）
#   3) 重建导出目录，并把残留的本机用户名替换成中性占位符 example
#   4) 体检：文件数 / 体积 / 个人信息残留 / **发布副本里的内部文档引用**（发现即失败）
#
# 第 4 步是硬门槛：一旦发布副本里出现指向内部文档的引用、内部文档本身、或 `Documents/`
# 这类本机路径，脚本以非零码退出，防止「导出成功、然后推送出去」。
#
# 用法：
#   Tools/export-public.sh                  # 导出到 ../harness-native-public
#   Tools/export-public.sh --dest <目录>     # 导出到指定目录
#   Tools/export-public.sh --check          # 只体检，不写任何文件
#   Tools/export-public.sh --self-test      # 用自建的临时源目录验证白名单行为
#
# 导出目录如果已经是一个 git 仓库，脚本只同步内容、保留 .git，历史不会丢。
#
# ⚠️ 不要在导出目录里改代码：它每次都会被本脚本整体重建（除 .git 外全部删除后重铺），
#    在那边做的修改下次导出就没了。要改就改源目录，然后重跑本脚本。

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$(dirname "$SRC")/harness-native-public"
CHECK_ONLY=0
SELF_TEST=0
USER_NAME="${HARNESS_USER_NAME:-$(id -un)}"

# ── 白名单：会进入发布副本的顶层条目 ─────────────────────────────────────────
# 新增顶层目录/文件时，想公开就加进来；不加的默认私有。
PUBLISH=(
  Apps
  Sources
  Tests
  Vendor
  Spec
  Tools
  Package.swift
  README.md
  CONTRACT.md
  LICENSE
  NOTICE.md
  "安装到启动台.md"
  # 仓库自带的点文件：`.gitattributes` 把 vendored 静态库标成二进制（不标的话
  # diff/行尾转换会碰它），`.gitignore` 挡住构建产物。少一个，发布副本的仓库就不干净。
  .gitattributes
  .gitignore
)

# 白名单内部仍然不发的文件（在导出的目录里属于「给维护者自己看」的样本）。
# 注意：这里只需写下「本该公开的目录里夹带的私有文件」，不必再枚举普通的内部文档 ——
# 它们根本不在白名单里。
EXCLUDE_IN_PUBLISHED=(
  "OPEN_SOURCE_CHECKLIST.md"
  "Spec/system-prompt.txt"
  "Spec/current-profile/system-prompt.txt"
  "Spec/request-header.meta.json"
  "Spec/current-profile/request-header.meta.json"
)

# 发布副本里一旦出现这些名字（无论作为文档名还是引用），就判定为「内部内容漏出去了」。
# 它们只出现在下面这一处，既用来匹配文件名，也用来匹配引用。
FORBIDDEN_INTERNAL="PLAN.md|M0-FINDINGS|OPEN_SOURCE_CHECKLIST"
# 结构模式：抓住以后新增的同类文档（白名单机制之外的第二重网）。
FORBIDDEN_NAME_PATTERNS=('*FINDINGS*.md' 'PLAN*.md' 'OPEN_SOURCE_CHECKLIST.md')
# 本机路径特征。这里刻意不写维护者的目录名 —— 本脚本自己会随仓库公开，写进来就等于
# 把私人路径又发出去一次。判据是「出现了 /Users/<某人的家目录>/，且不是下面这些
# 已经中性的占位符」。
ALLOWED_HOME_SEGMENTS='/Users/example|/Users/me/|/Users/x/|/Users/project|/Users/tester'

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

LIST="$(mktemp -t export-public)"
REPORT="$(mktemp -t export-public-report)"
trap 'rm -f "$LIST" "$REPORT"' EXIT

# ── 收集：只走白名单 ─────────────────────────────────────────────────────────
collect_publishable() {
  local root="$1"
  local -a paths=()
  local entry abs

  for entry in "${PUBLISH[@]}"; do
    abs="$root/$entry"
    if [ ! -e "$abs" ]; then
      echo "warning: 白名单项不存在，已跳过: $entry" >&2
      continue
    fi
    paths+=("./$entry")
  done

  local -a find_excludes=()
  for entry in "${EXCLUDE_IN_PUBLISHED[@]}"; do
    find_excludes+=(! -path "./$entry")
  done

  cd "$root"
  # 注意：SwiftPM 依赖 bash 3.2（macOS 自带），空数组在 `set -u` 下展开会报错，
  # 所以这里按长度分支，而不是直接展开。
  if [ "${#find_excludes[@]}" -gt 0 ]; then
    find "${paths[@]}" -type f ! -name ".DS_Store" "${find_excludes[@]}" -print \
      | LC_ALL=C sort
  else
    find "${paths[@]}" -type f ! -name ".DS_Store" -print | LC_ALL=C sort
  fi
}

# ── 体检：发布副本里有没有不该出现的东西 ─────────────────────────────────────
# 每命中一条就把行号与文件名写进 REPORT，返回命中数。
inspect_published_tree() {
  local dest="$1"
  local fails=0

  : > "$REPORT"

  # 1) 内部文档本身（按名字模式，抓以后新增的同类文档）
  local pattern f hit
  for pattern in "${FORBIDDEN_NAME_PATTERNS[@]}"; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      echo "内部文档出现在发布副本: ${f#"$dest"/}" >> "$REPORT"
      fails=$((fails + 1))
    done < <(find "$dest" -name "$pattern" -not -path "*/.git/*" 2>/dev/null || true)
  done

  # 2) 指向内部文档的引用（只扫文本；本脚本自己的规则表不算引用）
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    echo "内部文档引用: ${hit#"$dest"/}" >> "$REPORT"
    fails=$((fails + 1))
  done < <(grep -rInE "$FORBIDDEN_INTERNAL" "$dest" 2>/dev/null \
             | grep -v "/\.git/" \
             | grep -v "^${dest}/Tools/export-public.sh:" || true)

  # 3) 本机家目录路径：允许值（测试占位符）之外出现的 /Users/... 一律算残留
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    printf '%s\n' "$hit" | grep -qE "$ALLOWED_HOME_SEGMENTS" && continue
    echo "本机路径: ${hit#"$dest"/}" >> "$REPORT"
    fails=$((fails + 1))
  done < <(grep -rInE '/Users/[A-Za-z0-9._-]+/' "$dest" 2>/dev/null \
             | grep -v "/\.git/" \
             | grep -v "^${dest}/Tools/export-public.sh:" || true)

  [ "$fails" -gt 255 ] && fails=255
  return "$fails"
}

# ── 自检：白名单真的挡得住吗 ─────────────────────────────────────────────────
# 造一个最小源目录，扔进一个内部文档，要求导出结果里没有它。
run_self_test() {
  local tmp src
  tmp="$(mktemp -d -t export-public-selftest)"
  src="$tmp/src"
  # 让白名单里的每一项都存在，否则自检会打印一堆「已跳过」的噪声。
  mkdir -p "$src/Apps" "$src/Tools" "$src/Spec" "$src/Sources" "$src/Tests" "$src/Vendor"
  : > "$src/Package.swift"
  : > "$src/CONTRACT.md"
  : > "$src/LICENSE"
  : > "$src/NOTICE.md"
  : > "$src/安装到启动台.md"
  cp "${BASH_SOURCE[0]}" "$src/Tools/export-public.sh"
  printf 'let x = 1\n' > "$src/Apps/App.swift"
  printf '# readme\n' > "$src/README.md"
  printf '# internal\n' > "$src/NOTES.md"
  printf '# plan\n' > "$src/PLAN.md"
  printf 'secret\n' > "$src/Spec/system-prompt.txt"

  local out
  out="$(collect_publishable "$src")"
  local fails=0

  check_present() {
    if printf '%s\n' "$out" | grep -qx "$1"; then
      echo "  [ok]   在发布列表里: $1"
    else
      echo "  [FAIL] 应当在发布列表里却没有: $1" >&2
      fails=$((fails + 1))
    fi
  }
  check_absent() {
    if printf '%s\n' "$out" | grep -qx "$1"; then
      echo "  [FAIL] 不该发布却发布了: $1" >&2
      fails=$((fails + 1))
    else
      echo "  [ok]   已挡在列表外: $1"
    fi
  }

  check_present "./Apps/App.swift"
  check_present "./README.md"
  check_present "./Tools/export-public.sh"
  check_absent "./NOTES.md"            # 白名单里没有 → 不发布
  check_absent "./PLAN.md"             # 白名单里没有 → 不发布
  check_absent "./Spec/system-prompt.txt"  # 白名单内但显式排除

  rm -rf "$tmp"
  echo
  if [ "$fails" -eq 0 ]; then
    echo "自检通过：白名单按预期工作（$fails 个失败）"
    return 0
  fi
  echo "自检失败：$fails 项不符合预期" >&2
  return 1
}

if [ "$SELF_TEST" = 1 ]; then
  echo "── export-public.sh 自检 ──────────────────────────────"
  run_self_test
  exit $?
fi

# ── 1. 收集要发布哪些文件 ─────────────────────────────────────────────────────
collect_publishable "$SRC" > "$LIST"

COUNT="$(wc -l < "$LIST" | tr -d ' ')"
echo "源目录:   $SRC"
echo "待发布:   $COUNT 个文件（白名单：${PUBLISH[*]}）"
echo "导出目录: $DEST"

# 白名单存在但源目录里没有 = 名单写错了，别装作没事。
MISSING=0
for entry in "${PUBLISH[@]}"; do
  [ -e "$SRC/$entry" ] || MISSING=$((MISSING + 1))
done
if [ "$MISSING" != "0" ]; then
  echo "error: 白名单有 $MISSING 项在源目录里不存在，请先修正 PUBLISH。" >&2
  exit 1
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo
  echo "(--check：只体检，没有写任何文件)"
  exit 0
fi

# ── 2. 重建导出目录（已存在的 git 历史保留）──────────────────────────────────
mkdir -p "$DEST"
find "$DEST" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
tar -cf - -T "$LIST" | (cd "$DEST" && tar -xf -)

# ── 3. 文本文件脱敏：本机用户名 → example ────────────────────────────────────
# macOS 的 sed 不接受空匹配串，用户名恰好为空时直接跳过。
if [ -n "$USER_NAME" ] && [ "$USER_NAME" != "example" ]; then
  find "$DEST" -type f -print0 \
    | xargs -0 grep -lI -- "$USER_NAME" 2>/dev/null \
    | while IFS= read -r f; do
        LC_ALL=C sed -i '' "s|${USER_NAME}|example|g" "$f"
        echo "  已脱敏: ${f#"$DEST"/}"
      done || true
fi

# ── 4. 补上游 MIT 归属声明（幂等）────────────────────────────────────────────
# 注：文档与脚本里的本机路径、上游仓库目录名已经由仓库自身保持中性
# （README 用 /path/to/... ，上游统一用 official-dsh/ 记号），此处不再改写文档。
LICENSE="$DEST/LICENSE"
if [ -f "$LICENSE" ] && ! grep -q 'Derived specification files' "$LICENSE"; then
  cat >> "$LICENSE" <<'EOF'

---

## Derived specification files

The following files contain material derived from the official DeepSeek Harness
(`@deepseek-ai/dsh`, MIT License, Copyright (c) 2026 DeepSeek) and are
redistributed here under the same MIT terms with this attribution:

- `Spec/**` — specification fixtures extracted from the official runtime
- `Sources/HarnessCore/Tools/Generated/ToolSchemas.swift` — generated from the
  official tool catalog
EOF
  echo "  已补充: LICENSE 的上游 MIT 归属声明"
fi

# ── 5. 体检报告 ─────────────────────────────────────────────────────────────
# 先清掉 Finder 在导出后可能生成的 .DS_Store（.git 内部的不动）
find "$DEST" -name ".DS_Store" -not -path "*/.git/*" -delete 2>/dev/null || true

echo
echo "── 体检 ──────────────────────────────────────────────"
FILES="$(find "$DEST" -type f -not -path "*/.git/*" | wc -l | tr -d ' ')"
BYTES="$(find "$DEST" -type f -not -path "*/.git/*" -print0 | xargs -0 stat -f%z | awk '{s+=$1} END {printf "%.1f", s/1048576}')"
echo "文件数:        $FILES"
echo "体积:          ${BYTES} MB"
echo "构建产物残留:  $(find "$DEST" \( -name ".build" -o -name "NativeHarness.xcodeproj" -o -name ".DS_Store" \) -not -path "*/.git/*" | wc -l | tr -d ' ') 处（应为 0）"

PII_FILES="$( { grep -rIl -- "$USER_NAME" "$DEST" 2>/dev/null || true; } | grep -v "/\.git/" || true )"
PII="$(printf '%s' "$PII_FILES" | grep -c . || true)"
echo "个人信息残留:  $PII 处（应为 0）"
if [ "$PII" != "0" ]; then
  printf '%s\n' "$PII_FILES" | sed "s|$DEST/|  → |"
fi

set +e
inspect_published_tree "$DEST"
FORBIDDEN="$?"
set -e
echo "内部内容残留:  $FORBIDDEN 处（应为 0）"
if [ "$FORBIDDEN" != "0" ]; then
  sed 's|^|  → |' "$REPORT"
  echo
  echo "error: 发布副本里出现了不该出现的内容（见上）。" >&2
  echo "       要么把它们从源目录移出白名单，要么清掉引用，然后重跑。" >&2
  exit 1
fi

echo
echo "完成，且体检全通过。"
echo "下一步：cd \"$DEST\" && git status --short   # 确认改动清单，再提交并推送"
