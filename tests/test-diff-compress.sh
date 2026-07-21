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

# --- 优先级函数 ---
c=$(mktemp); echo "deleted file mode 100644" > "$c"
assert_eq "$(_diff_priority "any.go" "$c")" "3" "priority: 整文件删除=3"
: > "$c"
assert_eq "$(_diff_priority "a.md" "$c")" "2" "priority: 文档=2"
assert_eq "$(_diff_priority "a.yaml" "$c")" "1" "priority: 配置=1"
assert_eq "$(_diff_priority "a.go" "$c")" "0" "priority: 代码=0"
rm -f "$c"

report
