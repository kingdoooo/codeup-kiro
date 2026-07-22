#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
ROOT=$(cd .. && pwd)
source "$ROOT/scripts/lib/diff-compress.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- 构造 git 仓库 ---
cd "$tmp" && git init -q repo && cd repo
git config user.email t@t && git config user.name t
mkdir -p src docs
printf 'package main\nfunc main() {}\n' > src/main.go
printf '# 说明\n旧文档\n' > docs/readme.md
printf 'line1\nline2\n' > old.txt
printf 'k=v\n' > "conf file.yaml"
git add -A && git commit -qm base
BASE=$(git rev-parse HEAD)
printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("x") }\n' > src/main.go
printf '# 说明\n新文档内容第一行\n新文档内容第二行\n' > docs/readme.md
printf 'k=v2\nk2=v3\n' > "conf file.yaml"
rm old.txt
git add -A && git commit -qm change
HEAD_SHA=$(git rev-parse HEAD)

# --- 阈值内：全量直传 ---
rc=0
build_review_input "$BASE" "$HEAD_SHA" "$tmp/out.diff" "$tmp/omitted.txt" "$tmp/chunks1" || rc=$?
assert_rc "$rc" 0 "small: 返回 0"
assert_contains "$(cat "$tmp/out.diff")" "src/main.go" "small: 含全部文件"
assert_eq "$(wc -c < "$tmp/omitted.txt" | tr -d ' ')" "0" "small: 无省略清单"

# --- 超限：预算 120 字节，只装得下部分 ---
rc=0
DIFF_SIZE_LIMIT=120 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out2.diff" "$tmp/omitted2.txt" "$tmp/chunks2" || rc=$?
assert_rc "$rc" 10 "big: 返回 10（已截断）"
omitted=$(cat "$tmp/omitted2.txt")
assert_contains "$omitted" "=> " "big: 清单含 chunk 路径"
assert_contains "$omitted" "(+" "big: 清单含增删行数"
# 省略清单里的每个 chunk 文件必须真实存在且含对应 diff
while IFS= read -r line; do
  chunk_path="${line##*=> }"
  [[ -s "$chunk_path" ]] || { echo "FAIL: chunk 不存在 $chunk_path" >&2; exit 1; }
done < "$tmp/omitted2.txt"
TESTS_PASSED=$((TESTS_PASSED + 1))
# 删除文件（old.txt）必须出现在省略清单且其 chunk 保留删除 diff
assert_contains "$omitted" "old.txt" "big: 删除文件列入清单"
del_chunk=$(grep "old.txt" "$tmp/omitted2.txt" | sed 's/.*=> //')
assert_contains "$(cat "$del_chunk")" "deleted file mode" "big: 删除文件 chunk 保留删除 diff"
assert_contains "$(cat "$del_chunk")" "-line1" "big: 删除内容可读"
# 含空格路径正常处理
assert_contains "$(cat "$tmp/out2.diff")$omitted" "conf file.yaml" "big: 含空格路径被处理"

# --- 超限 + 相对 chunk 目录：省略清单必须给出绝对路径 ---
cd "$tmp/repo"
rc=0
DIFF_SIZE_LIMIT=120 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out3.diff" "$tmp/omitted3.txt" "chunks_rel" || rc=$?
assert_rc "$rc" 10 "relative: 返回 10（已截断）"
[[ -s "$tmp/omitted3.txt" ]] || { echo "FAIL: relative: 省略清单为空" >&2; exit 1; }
while IFS= read -r line; do
  chunk_path=$(printf '%s' "$line" | sed 's/.*=> //')
  case "$chunk_path" in
    /*) ;;
    *) echo "FAIL: relative: 清单 chunk 路径非绝对 [$chunk_path]" >&2; exit 1 ;;
  esac
done < "$tmp/omitted3.txt"
TESTS_PASSED=$((TESTS_PASSED + 1))

# --- 超限 + 预算恰好装下最小代码 chunk：直传与省略清单互斥 ---
# 预算动态取自目标 chunk 实际大小，避免 git 版本间 diff 字节数差异
main_size=$(git diff --no-renames "$BASE" "$HEAD_SHA" -- src/main.go | wc -c | tr -d ' ')
rc=0
DIFF_SIZE_LIMIT="$main_size" build_review_input "$BASE" "$HEAD_SHA" "$tmp/out4.diff" "$tmp/omitted4.txt" "$tmp/chunks4" || rc=$?
assert_rc "$rc" 10 "pack: 返回 10（部分直传仍截断）"
assert_contains "$(cat "$tmp/out4.diff")" "src/main.go" "pack: 代码 chunk 被直传"
assert_not_contains "$(cat "$tmp/omitted4.txt")" "src/main.go" "pack: 直传文件不再列入省略清单"
assert_contains "$(cat "$tmp/omitted4.txt")" "conf file.yaml" "pack: 其余文件仍在省略清单"

# --- 优先级函数 ---
c=$(mktemp); echo "deleted file mode 100644" > "$c"
assert_eq "$(_diff_priority "any.go" "$c")" "3" "priority: 整文件删除=3"
: > "$c"
assert_eq "$(_diff_priority "a.md" "$c")" "2" "priority: 文档=2"
assert_eq "$(_diff_priority "a.yaml" "$c")" "1" "priority: 配置=1"
assert_eq "$(_diff_priority "a.go" "$c")" "0" "priority: 代码=0"
rm -f "$c"

# --- pathspec 特殊字符文件名：glob 方括号与冒号前缀（新仓库，避免 chunks_rel 污染） ---
cd "$tmp" && git init -q repo2 && cd repo2
git config user.email t@t && git config user.name t
mkdir pages
printf 'export default 1\n' > 'pages/[id].tsx'
printf 'export default 2\n' > 'pages/i.tsx'
printf 'package evil\n' > ':evil.go'
git add -A && git commit -qm special-base
SP_BASE=$(git rev-parse HEAD)
printf 'export default 1\nbracket_changed\n' > 'pages/[id].tsx'
printf 'export default 2\nplain_changed\n' > 'pages/i.tsx'
printf 'package evil\nevil_changed\n' > ':evil.go'
git add -A && git commit -qm special-change
SP_HEAD=$(git rev-parse HEAD)
rc=0
DIFF_SIZE_LIMIT=1 build_review_input "$SP_BASE" "$SP_HEAD" "$tmp/out5.diff" "$tmp/omitted5.txt" "$tmp/chunks5" || rc=$?
assert_rc "$rc" 10 "special: 返回 10（已截断）"
# 方括号文件在直传+清单中恰好出现一次
n_bracket=$(cat "$tmp/out5.diff" "$tmp/omitted5.txt" | grep -cF 'pages/[id].tsx' || true)
assert_eq "$n_bracket" "1" "special: 方括号文件恰好出现一次"
bracket_chunk=$(grep -F 'pages/[id].tsx' "$tmp/omitted5.txt" | sed 's/.*=> //')
[[ -s "$bracket_chunk" ]] || { echo "FAIL: special: 方括号文件 chunk 为空" >&2; exit 1; }
TESTS_PASSED=$((TESTS_PASSED + 1))
assert_contains "$(cat "$bracket_chunk")" "bracket_changed" "special: 方括号 chunk 含自身改动"
# glob 展开会把 pages/i.tsx 的 diff 串进来；literal 后 chunk 只含一个文件
assert_not_contains "$(cat "$bracket_chunk")" "plain_changed" "special: 方括号 chunk 不串入他文件"
assert_eq "$(grep -c '^diff --git' "$bracket_chunk")" "1" "special: 方括号 chunk 仅一个 diff 头"
# 冒号前缀文件：旧代码 pathspec 解析为空导致 chunk 为空
evil_chunk=$(grep -F ':evil.go' "$tmp/omitted5.txt" | sed 's/.*=> //')
[[ -s "$evil_chunk" ]] || { echo "FAIL: special: 冒号前缀文件 chunk 为空（pathspec 未按字面处理）" >&2; exit 1; }
TESTS_PASSED=$((TESTS_PASSED + 1))
assert_contains "$(cat "$evil_chunk")" "evil_changed" "special: 冒号前缀 chunk 含自身改动"

report
