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
assert_eq "$(jq -r 'has("chunk") and has("file") and has("added") and has("removed")' "$tmp/omitted2.txt" | sort -u)" "true" "big: 清单每行是含 chunk/file/added/removed 的 JSON"
assert_eq "$(jq -r '(.added|type) + "/" + (.removed|type)' "$tmp/omitted2.txt" | sort -u)" "number/number" "big: 增删行数是数字"
# 省略清单里的每个 chunk 文件必须真实存在且含对应 diff
while IFS= read -r line; do
  chunk_path=$(printf '%s' "$line" | jq -r .chunk)
  [[ -s "$chunk_path" ]] || { echo "FAIL: chunk 不存在 $chunk_path" >&2; exit 1; }
done < "$tmp/omitted2.txt"
TESTS_PASSED=$((TESTS_PASSED + 1))
# 删除文件（old.txt）必须出现在省略清单且其 chunk 保留删除 diff
assert_contains "$omitted" "old.txt" "big: 删除文件列入清单"
del_chunk=$(jq -r 'select(.file == "old.txt") | .chunk' "$tmp/omitted2.txt")
assert_contains "$(cat "$del_chunk")" "deleted file mode" "big: 删除文件 chunk 保留删除 diff"
assert_contains "$(cat "$del_chunk")" "-line1" "big: 删除内容可读"
# 含空格路径正常处理
assert_contains "$(cat "$tmp/out2.diff")$omitted" "conf file.yaml" "big: 含空格路径被处理"

# --- 超限 + 通过符号链接给出的 chunk 目录：清单里的 chunk 路径必须是**物理路径**（票 15）---
# 执行器把 $WORK/chunks 的物理路径注入受信 agent 的 allowedPaths（探测 P1-15 T1 只验证过「按物理路径读」可读）；
# 索引里喂给模型的 chunk 路径若是逻辑路径（macOS 的 /var/folders → /private/var/folders，或 TMPDIR 本身是符号链接），
# 模型按索引去读时路径形态与 allowedPaths 不一致——kiro-cli 是否会先解析符号链接再比对未经实测，不能依赖它。
mkdir -p "$tmp/real-chunks-dir"; ln -s "$tmp/real-chunks-dir" "$tmp/chunks-link"
rc=0
DIFF_SIZE_LIMIT=120 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out2s.diff" "$tmp/omitted2s.txt" "$tmp/chunks-link" || rc=$?
assert_rc "$rc" 10 "symlink chunk dir: 返回 10（已截断）"
chunks_phys=$(cd "$tmp/real-chunks-dir" && pwd -P)
assert_eq "$(jq -r '.chunk | sub("/[^/]*$"; "")' "$tmp/omitted2s.txt" | sort -u)" "$chunks_phys" \
  "symlink chunk dir: 清单里每条 chunk 的目录都是物理路径（与执行器注入 allowedPaths 的形态一致）"
assert_eq "$(jq -r '.chunk | test("chunks-link")' "$tmp/omitted2s.txt" | sort -u)" "false" "symlink chunk dir: 清单里不出现符号链接形态的路径"
while IFS= read -r line; do
  chunk_path=$(printf '%s' "$line" | jq -r .chunk)
  [[ -s "$chunk_path" ]] || { echo "FAIL: symlink chunk dir: chunk 不存在 $chunk_path" >&2; exit 1; }
done < "$tmp/omitted2s.txt"
TESTS_PASSED=$((TESTS_PASSED + 1))

# --- 超限 + 相对 chunk 目录：省略清单必须给出绝对路径 ---
cd "$tmp/repo"
rc=0
DIFF_SIZE_LIMIT=120 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out3.diff" "$tmp/omitted3.txt" "chunks_rel" || rc=$?
assert_rc "$rc" 10 "relative: 返回 10（已截断）"
[[ -s "$tmp/omitted3.txt" ]] || { echo "FAIL: relative: 省略清单为空" >&2; exit 1; }
while IFS= read -r line; do
  chunk_path=$(printf '%s' "$line" | jq -r .chunk)
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
bracket_chunk=$(jq -r 'select(.file == "pages/[id].tsx") | .chunk' "$tmp/omitted5.txt")
[[ -s "$bracket_chunk" ]] || { echo "FAIL: special: 方括号文件 chunk 为空" >&2; exit 1; }
TESTS_PASSED=$((TESTS_PASSED + 1))
assert_contains "$(cat "$bracket_chunk")" "bracket_changed" "special: 方括号 chunk 含自身改动"
# glob 展开会把 pages/i.tsx 的 diff 串进来；literal 后 chunk 只含一个文件
assert_not_contains "$(cat "$bracket_chunk")" "plain_changed" "special: 方括号 chunk 不串入他文件"
assert_eq "$(grep -c '^diff --git' "$bracket_chunk")" "1" "special: 方括号 chunk 仅一个 diff 头"
# 冒号前缀文件：旧代码 pathspec 解析为空导致 chunk 为空
evil_chunk=$(jq -r 'select(.file == ":evil.go") | .chunk' "$tmp/omitted5.txt")
[[ -s "$evil_chunk" ]] || { echo "FAIL: special: 冒号前缀文件 chunk 为空（pathspec 未按字面处理）" >&2; exit 1; }
TESTS_PASSED=$((TESTS_PASSED + 1))
assert_contains "$(cat "$evil_chunk")" "evil_changed" "special: 冒号前缀 chunk 含自身改动"


# --- 文件名注入（票 06 P0）：Git 文件名允许换行与 Tab。带换行的文件名第二行伪装成一条
#     `优先级\t大小\tchunk\t路径` 索引记录，chunk 指向 chunk 目录外的哨兵文件；
#     build_review_input 绝不能把 chunk 目录外的任何文件读进直传 diff。
cd "$tmp" && git init -q repo3 && cd repo3
git config user.email t@t && git config user.name t
printf 'FAKE-SENTINEL-DO-NOT-LEAK\n' > "$tmp/sentinel.txt"
git commit -q --allow-empty -m inj-base
INJ_BASE=$(git rev-parse HEAD)
EVIL=$(printf 'evil.py\n0\t1\t%s\tz.py' "$tmp/sentinel.txt")
mkdir -p "$(dirname "$EVIL")"
printf 'x = 1\n' > "$EVIL"
printf 'k = 2\n' > "$(printf 'tab\tname.go')"
printf 'p = 3\n' > 'pipe|tick`.go'
# 旧清单格式 `- 名字 (+a / -b) => chunk` 下，这个合法文件名会在同一行伪造出第二个 `=> 路径`
mkdir -p 'forge (+1 / -0) => /etc'
printf 'q = 4\n' > 'forge (+1 / -0) => /etc/passwd'
seq 1 200 > big.go
git add -A && git commit -qm inj-change
INJ_HEAD=$(git rev-parse HEAD)
rc=0
DIFF_SIZE_LIMIT=50 build_review_input "$INJ_BASE" "$INJ_HEAD" "$tmp/out6.diff" "$tmp/omitted6.txt" "$tmp/chunks6" || rc=$?
assert_rc "$rc" 10 "inject: 返回 10（已截断）"
assert_not_contains "$(cat "$tmp/out6.diff")" "FAKE-SENTINEL" "inject: chunk 目录外的文件不得进入直传 diff"
# 清单里每条的 chunk 都在 chunk 目录内且非空（chunk 路径是物理路径，比较基准同样取 pwd -P）
chunks6_p=$(cd "$tmp/chunks6" && pwd -P)
while IFS= read -r line; do
  chunk_path=$(printf '%s' "$line" | jq -r .chunk)
  case "$chunk_path" in
    "$chunks6_p"/*) ;;
    *) echo "FAIL: inject: 清单 chunk 路径不在 chunk 目录内 [$chunk_path]" >&2; exit 1 ;;
  esac
  [[ -s "$chunk_path" ]] || { echo "FAIL: inject: chunk 不存在 $chunk_path" >&2; exit 1; }
done < "$tmp/omitted6.txt"
TESTS_PASSED=$((TESTS_PASSED + 1))
# 直传 diff 头数 + 清单条数 == git 报告的变更文件数：一个不多（伪造记录）一个不少（被截断的名字）
# 基线必须用生产的 _git_diff_pinned --no-renames（与 build_review_input 同一条枚举命令）：
# 裸 git diff 默认开重命名检测，fixture 一旦出现删+增配对就会与生产口径不一致，断言会因无关原因失败
n_files=$(_git_diff_pinned --no-renames --name-only -z "$INJ_BASE" "$INJ_HEAD" | tr -cd '\0' | wc -c | tr -d ' ')
n_direct=$(grep -c '^diff --git' "$tmp/out6.diff" || true)
n_omitted=$(jq -r .chunk "$tmp/omitted6.txt" | wc -l | tr -d ' ')
assert_eq "$((n_direct + n_omitted))" "$n_files" "inject: 直传 diff 头数 + 清单条数 == 变更文件数"
assert_eq "$(wc -l < "$tmp/omitted6.txt" | tr -d ' ')" "$n_omitted" "inject: 清单每条恰好一行 JSON"
omitted6=$(cat "$tmp/omitted6.txt")
# 文件名里的换行/Tab 由 jq 转义为 \n \t（字面反斜杠），竖线与反引号原样保留
assert_contains "$omitted6" 'evil.py\n0\t1\t' "inject: 换行与 Tab 转义为 \\n \\t"
assert_contains "$omitted6" 'tab\tname.go' "inject: Tab 文件名转义显示"
assert_contains "$omitted6" 'pipe|tick`.go' "inject: 竖线与反引号原样保留"
# 转义后的名字仍指向自己的 chunk
evil_chunk6=$(jq -r 'select(.file | startswith("evil.py\n0\t1\t")) | .chunk' "$tmp/omitted6.txt")
assert_contains "$(cat "$evil_chunk6")" "+x = 1" "inject: 带换行文件名的 chunk 是它自己的 diff"
# 分隔符伪造：file 字段原样保留名字，chunk 字段仍是它自己的 chunk（JSON 里不存在「第二个路径」）
forge_chunk6=$(jq -r 'select(.file == "forge (+1 / -0) => /etc/passwd") | .chunk' "$tmp/omitted6.txt")
assert_eq "$(printf '%s\n' "$forge_chunk6" | grep -c .)" "1" "inject: 分隔符伪造文件名恰好一条记录"
assert_contains "$(cat "$forge_chunk6")" "+q = 4" "inject: 分隔符伪造文件名的 chunk 是它自己的 diff"

# --- 落盘失败：chunk 目录建不出来必须 rc 1，绝不能带着空输出 return 10（调用方会当成「diff 为空」跳过评审）---
printf 'x' > "$tmp/notadir"
rc=0
DIFF_SIZE_LIMIT=1 build_review_input "$INJ_BASE" "$INJ_HEAD" "$tmp/out7.diff" "$tmp/omitted7.txt" "$tmp/notadir/chunks" 2>/dev/null || rc=$?
assert_rc "$rc" 1 "ioerr: chunk 目录建不出来 → rc 1"
assert_eq "$(cat "$tmp/out7.diff" "$tmp/omitted7.txt" | wc -c | tr -d ' ')" "0" "ioerr: 两个输出都为空且 rc 不是 0/10"

# ============ 票 12 ============
# --- ① 从仓库子目录调用：--name-only 给的是仓库根相对路径，`:(literal)` 却按 cwd 解析 → 每个 chunk 都是
#     0 字节 → 文件既不进直传也不进清单，从评审范围里消失且无日志。pathspec 改用 `:(top,literal)`。
cd "$tmp/repo/src"
rc=0
DIFF_SIZE_LIMIT=1 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out8.diff" "$tmp/omitted8.txt" "$tmp/chunks8" || rc=$?
assert_rc "$rc" 10 "subdir: 返回 10（已截断）"
n_files=$(_git_diff_pinned --no-renames --name-only -z "$BASE" "$HEAD_SHA" | tr -cd '\0' | wc -c | tr -d ' ')
n_direct=$(grep -c '^diff --git' "$tmp/out8.diff" || true)
n_omitted=$(jq -r .chunk "$tmp/omitted8.txt" | wc -l | tr -d ' ')
assert_eq "$((n_direct + n_omitted))" "$n_files" "subdir: 子目录下调用，直传 + 清单仍等于变更文件数（一个都没消失）"
while IFS= read -r line; do
  chunk_path=$(printf '%s' "$line" | jq -r .chunk)
  [[ -s "$chunk_path" ]] || { echo "FAIL: subdir: chunk 为 0 字节 $chunk_path（pathspec 按 cwd 解析了）" >&2; exit 1; }
done < "$tmp/omitted8.txt"
TESTS_PASSED=$((TESTS_PASSED + 1))
main_chunk8=$(jq -r 'select(.file == "src/main.go") | .chunk' "$tmp/omitted8.txt")
assert_contains "$(cat "$main_chunk8")" 'fmt.Println' "subdir: src/main.go 的 chunk 是它自己的 diff"
[[ ! -e "$tmp/chunks8/.full.diff" && ! -e "$tmp/chunks8/.names" ]] || { echo "FAIL: subdir: 临时文件 .full.diff/.names 没清掉" >&2; exit 1; }
TESTS_PASSED=$((TESTS_PASSED + 1))
[[ ! -e "$tmp/chunks1/.full.diff" ]] || { echo "FAIL: small: 未超限路径也不该留下 .full.diff" >&2; exit 1; }
TESTS_PASSED=$((TESTS_PASSED + 1))
cd "$tmp/repo"

# --- ① 复审补充：gitconfig 里开了 diff.relative，从子目录调用时输出只含 cwd 之下的路径且去掉前缀，
#     `:(top,literal)` 也对不上 → 每个 chunk 又是 0 字节。这个开关必须钉死在 _git_diff_pinned 里。
git config diff.relative true
cd "$tmp/repo/src"
rc=0
DIFF_SIZE_LIMIT=1 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out8r.diff" "$tmp/omitted8r.txt" "$tmp/chunks8r" || rc=$?
assert_rc "$rc" 10 "relative-cfg: diff.relative=true + 子目录 → 仍返回 10"
n_omitted=$(jq -r .chunk "$tmp/omitted8r.txt" | wc -l | tr -d ' ')
n_direct=$(grep -c '^diff --git' "$tmp/out8r.diff" || true)
assert_eq "$((n_direct + n_omitted))" "$n_files" "relative-cfg: 文件一个都没消失"
assert_contains "$(cat "$tmp/omitted8r.txt")" '"file":"src/main.go"' "relative-cfg: 文件名仍是仓库根相对路径（不是 main.go）"
cd "$tmp/repo" && git config --unset diff.relative

# --- ① 守卫：枚举列出了文件、逐文件 diff 却是 0 字节 → 内部错误，整次失败（而不是静默漏掉那个文件）---
# 正常输入到不了这条分支（上面已证明 top 魔法下 chunk 非空），用替身让某一个文件的 diff 为空来证明守卫会响。
eval "$(declare -f _git_diff_pinned | sed '1s/^_git_diff_pinned/_orig_git_diff_pinned/')"
_git_diff_pinned() {
  case " $* " in
    *" :(top,literal)docs/readme.md "*) return 0 ;;   # 这个文件的逐文件 diff 假装为空
    *) _orig_git_diff_pinned "$@" ;;
  esac
}
rc=0; err=$(DIFF_SIZE_LIMIT=1 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out9.diff" "$tmp/omitted9.txt" "$tmp/chunks9" 2>&1) || rc=$?
assert_rc "$rc" 1 "emptychunk: 某文件 chunk 为 0 字节 → rc 1（内部错误）"
assert_contains "$err" "docs/readme.md" "emptychunk: 报错点名是哪个文件"
assert_contains "$err" "0 字节" "emptychunk: 报错说明是 chunk 为空"
# 正控：同一替身下把「假装为空」去掉就正常
_git_diff_pinned() { _orig_git_diff_pinned "$@"; }
rc=0; DIFF_SIZE_LIMIT=1 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out9b.diff" "$tmp/omitted9b.txt" "$tmp/chunks9b" || rc=$?
assert_rc "$rc" 10 "emptychunk 正控：替身透传时照常 rc 10"

# --- ② 枚举命令的退出码要检查：git 中途死掉不能变成「部分索引 + rc 10」被当成成功 ---
_git_diff_pinned() {
  case " $* " in
    *" --name-only "*) echo "fatal: 模拟 git 中途死掉" >&2; return 128 ;;
    *) _orig_git_diff_pinned "$@" ;;
  esac
}
rc=0; DIFF_SIZE_LIMIT=1 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out10.diff" "$tmp/omitted10.txt" "$tmp/chunks10" 2>/dev/null || rc=$?
assert_rc "$rc" 1 "enumrc: 枚举失败 → rc 1（不是 10）"
assert_eq "$(cat "$tmp/out10.diff" "$tmp/omitted10.txt" | wc -c | tr -d ' ')" "0" "enumrc: 两个输出都为空（没有半份索引）"
# 总量那一步的 git 失败也一样
_git_diff_pinned() {
  case " $* " in
    *" --name-only "*|*" -- "*) _orig_git_diff_pinned "$@" ;;
    *) echo "fatal: 模拟总量 diff 失败" >&2; return 128 ;;
  esac
}
rc=0; build_review_input "$BASE" "$HEAD_SHA" "$tmp/out11.diff" "$tmp/omitted11.txt" "$tmp/chunks11" 2>/dev/null || rc=$?
assert_rc "$rc" 1 "totalrc: 算总量的 diff 失败 → rc 1（原先 \$(… | wc -c | tr) 报的是 tr 的退出码）"
# 空文件名守卫：--name-only -z 不会给出空名，用替身证明守卫会响（空名对应的 pathspec `:(top,literal)` 会匹配整个
# 仓库，chunk 反而非空，靠「chunk 为 0 字节」那条守卫拦不住它）
_git_diff_pinned() {
  case " $* " in
    *" --name-only "*) printf 'src/main.go\0\0docs/readme.md\0' ;;
    *) _orig_git_diff_pinned "$@" ;;
  esac
}
rc=0; err=$(DIFF_SIZE_LIMIT=1 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out10b.diff" "$tmp/omitted10b.txt" "$tmp/chunks10b" 2>&1) || rc=$?
assert_rc "$rc" 1 "emptyname: 枚举给出空文件名 → rc 1"
assert_contains "$err" "空文件名" "emptyname: 报错点名原因"
# numstat 没给出该文件（pathspec 没对上）→ 内部错误，不能折成 0/0（那和「只改模式」的真 0/0 分不开）
_git_diff_pinned() {
  case " $* " in
    *" --numstat "*" :(top,literal)docs/readme.md "*) return 0 ;;
    *) _orig_git_diff_pinned "$@" ;;
  esac
}
rc=0; err=$(DIFF_SIZE_LIMIT=1 build_review_input "$BASE" "$HEAD_SHA" "$tmp/out10c.diff" "$tmp/omitted10c.txt" "$tmp/chunks10c" 2>&1) || rc=$?
assert_rc "$rc" 1 "numstat-empty: numstat 输出为空 → rc 1（不折成 0/0）"
assert_contains "$err" "docs/readme.md" "numstat-empty: 报错点名文件"
unset -f _git_diff_pinned; eval "$(declare -f _orig_git_diff_pinned | sed '1s/^_orig_git_diff_pinned/_git_diff_pinned/')"
# 二进制文件：numstat 给 `-`，按 0 计
assert_eq "$(_chunk_numstat "$BASE" "$HEAD_SHA" "src/main.go")" "2 1" "numstat: 文本文件的增删行数"

# --- ③ 增删行计数：只插入空行的文件、以 `++` 开头的内容行，原先 grep '^+[^+]' 都数成 0 ---
cd "$tmp" && git init -q repo4 && cd repo4
git config user.email t@t && git config user.name t
printf 'line\n' > blank.txt
printf 'i = 0\n' > inc.c
printf 'a\n\n\nb\n' > shrink.txt
git add -A && git commit -qm cnt-base
CNT_BASE=$(git rev-parse HEAD)
printf 'line\n\n\n' > blank.txt          # 只加两个空行
printf 'i = 0\n++i;\n' > inc.c           # 内容行以 ++ 开头
printf 'a\nb\n' > shrink.txt             # 只删两个空行
git add -A && git commit -qm cnt-change
CNT_HEAD=$(git rev-parse HEAD)
rc=0
DIFF_SIZE_LIMIT=1 build_review_input "$CNT_BASE" "$CNT_HEAD" "$tmp/out12.diff" "$tmp/omitted12.txt" "$tmp/chunks12" || rc=$?
assert_rc "$rc" 10 "count: 返回 10"
cnt() { jq -r --arg f "$1" 'select(.file == $f) | "\(.added)/\(.removed)"' "$tmp/omitted12.txt"; }
assert_eq "$(cnt blank.txt)" "2/0" "count: 只插入两个空行 → added=2（原先 0）"
assert_eq "$(cnt inc.c)" "1/0" "count: 以 ++ 开头的内容行也算一行（原先 0）"
assert_eq "$(cnt shrink.txt)" "0/2" "count: 只删两个空行 → removed=2（原先 0）"

# --- ④ sidecar 守卫：缺失或 0 字节都必须硬失败，不能输出 "file":"" ---
printf 'src/a.py' > "$tmp/side.ok"; : > "$tmp/side.empty"
rc=0; _check_path_sidecar "$tmp/side.ok" || rc=$?;      assert_rc "$rc" 0 "sidecar: 正常 sidecar → rc 0"
rc=0; _check_path_sidecar "$tmp/side.empty" 2>/dev/null || rc=$?;   assert_rc "$rc" 1 "sidecar: 0 字节 → rc 1（原先读成空串、输出 file:\"\"）"
rc=0; _check_path_sidecar "$tmp/side.missing" 2>/dev/null || rc=$?; assert_rc "$rc" 1 "sidecar: 缺失 → rc 1"
err=$(_check_path_sidecar "$tmp/side.empty" 2>&1 || true)
assert_contains "$err" "内部错误" "sidecar: 报错标明内部错误"

report
