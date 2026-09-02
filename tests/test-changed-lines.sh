#!/usr/bin/env bash
# review_changed_lines 的单元测试：把零上下文 diff 解析成「每个文件新文件侧的变更行集合」。
#
# 为什么必须单测到这个粒度：行内评论的行号只有落在这个集合里才允许发出（spec I5「定位可信」），
# 集合算错的两种后果都很糟——算大了会把评论挂到没改过的行上（Codeup 侧 can_located 为假、
# 读者看到莫名其妙的评论），算小了会把真问题全部挤进折叠区、行内评论形同没开。
#
# 每个用例都用真的 git 仓库产出真的 diff（不手写 diff 文本）：解析器的输入形态必须是 git 的实际输出，
# 手写样例会漏掉 `\ No newline at end of file`、二进制提示行、路径转义这些真实存在的形态。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
ROOT=$(cd .. && pwd)
source "$ROOT/scripts/lib/review-render.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 建一个只有两次提交的仓库（BASE=HEAD~1，HEAD=第二次提交），stdout=仓库目录。
# 用法：mk_repo <名字> <第一次提交的内容函数> <第二次提交的内容函数>
# 两条 local 分开写：bash 3.2（macOS 自带）在同一条 local 里引用前面刚声明的变量会拿到未绑定值。
mk_repo() {
  local name="$1" first="$2" second="$3"
  local d="$tmp/$name"
  mkdir -p "$d"
  (
    cd "$d"
    git init -q .
    git config user.email t@t; git config user.name t
    git config core.quotePath false
    "$first"
    git add -A; git commit -qm base
    "$second"
    git add -A; git commit -qm head
  )
  printf '%s' "$d"
}
# 在仓库里跑「生产用的那条 diff 命令」并解析。命令必须与 kiro-review.sh 里一致。
changed_json() {
  local d="$1"
  (cd "$d" && git -c core.quotePath=false diff --no-renames -U0 HEAD~1 HEAD) | review_changed_lines
}
lines_of() { # <json> <path> → "30,31" 形式的行号列表（展开区间，便于断言）
  printf '%s' "$1" | jq -r --arg p "$2" '
    (.[$p] // null)
    | if . == null then "<缺该文件>"
      else [.[] | range(.[0]; .[1] + 1)] | join(",") end'
}

# ============ 新增文件：新文件侧全部行都算变更行 ============
a_first()  { printf 'x\n' > keep.txt; }
a_second() { printf 'l1\nl2\nl3\n' > added.py; }
d=$(mk_repo newfile a_first a_second)
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" added.py)" "1,2,3" "新增文件：整份内容都是变更行"
assert_eq "$(printf '%s' "$j" | jq -r 'keys | join(",")')" "added.py" "新增文件：只有它一个键"

# ============ 删除文件：新文件侧不存在 → 不进集合（被删行的问题只能进折叠区，P1-02 实测）============
b_first()  { printf 'l1\nl2\n' > gone.py; printf 'x\n' > keep.txt; }
b_second() { rm gone.py; }
d=$(mk_repo delfile b_first b_second)
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" gone.py)" "<缺该文件>" "删除文件：不出现在变更行集合里（新文件侧没有这个文件）"
assert_eq "$(printf '%s' "$j" | jq -r 'length')" "0" "删除文件：集合为空"

# ============ 修改：多 hunk，只取新文件侧的新增/修改行 ============
c_first() {
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > m.py
}
c_second() {
  # 第 2 行改写；第 5 行后插入两行；第 9 行删掉
  printf 'l1\nL2\nl3\nl4\nl5\nnew6\nnew7\nl6\nl7\nl8\nl10\n' > m.py
}
d=$(mk_repo multihunk c_first c_second)
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" m.py)" "2,6,7" "多 hunk：改写行 + 插入行都在集合里（新文件侧行号）"
assert_not_contains "$(lines_of "$j" m.py)" "9" "多 hunk：被删除的行不在集合里"

# ============ 纯删除的 hunk：文件在变更文件集合里，但该 hunk 不贡献任何新文件侧行号 ============
e_first()  { printf 'l1\nl2\nl3\nl4\n' > onlydel.py; }
e_second() { printf 'l1\nl4\n' > onlydel.py; }
d=$(mk_repo onlydel e_first e_second)
j=$(changed_json "$d")
assert_eq "$(printf '%s' "$j" | jq -r 'has("onlydel.py")')" "true" "纯删除：文件仍在变更文件集合里"
assert_eq "$(lines_of "$j" onlydel.py)" "" "纯删除：没有可定位的新文件侧行号（区间集合为空）"

# ============ 重命名：--no-renames 下表现为删 + 增 ============
f_first()  { printf 'l1\nl2\nl3\n' > old_name.py; }
f_second() { git mv old_name.py new_name.py; }
d=$(mk_repo rename f_first f_second)
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" new_name.py)" "1,2,3" "重命名：新路径按新增文件处理，整份内容可定位"
assert_eq "$(lines_of "$j" old_name.py)" "<缺该文件>" "重命名：旧路径不在集合里"

# ============ 二进制文件：没有 hunk，也没有 ---/+++ 头 → 不可定位 ============
g_first()  { printf 'x\n' > keep.txt; }
g_second() { printf '\000\001\002\003bin\000' > blob.bin; }
d=$(mk_repo binary g_first g_second)
raw=$( (cd "$d" && git diff --no-renames -U0 HEAD~1 HEAD) )
assert_contains "$raw" "Binary files" "前置：git 对二进制文件输出的是 Binary files 提示行（不是 hunk）"
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" blob.bin)" "<缺该文件>" "二进制：不可定位（Codeup 也无法把评论挂到二进制文件的行上）"

# ============ 无换行结尾：`\ No newline at end of file` 不能被当成 diff 行 ============
h_first()  { printf 'l1\nl2\n' > nonl.py; }
h_second() { printf 'l1\nl2\nl3-no-newline' > nonl.py; }
d=$(mk_repo nonewline h_first h_second)
raw=$( (cd "$d" && git diff --no-renames -U0 HEAD~1 HEAD) )
assert_contains "$raw" "No newline at end of file" "前置：diff 里确实有「无换行结尾」标记行"
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" nonl.py)" "3" "无换行结尾：只算真实新增的第 3 行，标记行不算"

# ============ 路径含空格 ============
i_first()  { printf 'x\n' > keep.txt; }
i_second() { mkdir -p "dir with space"; printf 'l1\nl2\n' > "dir with space/a b.py"; }
d=$(mk_repo spacepath i_first i_second)
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" "dir with space/a b.py")" "1,2" "路径含空格：键名保留完整路径"

# ============ 路径含双引号：git 会 C 风格转义整个路径，解析必须还原 ============
j_first()  { printf 'x\n' > keep.txt; }
j_second() { printf 'l1\n' > 'q"uote.py'; }
d=$(mk_repo quotepath j_first j_second)
raw=$( (cd "$d" && git -c core.quotePath=false diff --no-renames -U0 HEAD~1 HEAD) )
assert_contains "$raw" '+++ "b/q\"uote.py"' "前置：git 对含引号的路径输出被引号包裹的转义形式"
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" 'q"uote.py')" "1" "路径含双引号：还原成真实路径后仍能定位"

# ============ 路径含中文：core.quotePath=false 下不转义 ============
k_first()  { printf 'x\n' > keep.txt; }
k_second() { printf 'l1\nl2\n' > '中文文件.py'; }
d=$(mk_repo cjkpath k_first k_second)
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" '中文文件.py')" "1,2" "路径含中文：键名是真实路径"

# ============ 内容行本身以 +++ / --- / @@ 开头：绝不能被当成 diff 头 ============
# 这是解析器最容易错的地方：新文件里有一行 `++ b/evil.py`，diff 里就是 `+++ b/evil.py`，
# 与文件头逐字节一致。只有「一个文件里第一个 @@ 之后不再认 ---/+++ 头」才分得开。
l_first()  { printf 'x\n' > real.py; }
l_second() {
  {
    printf 'x\n'
    printf '++ b/evil.py\n'
    printf -- '-- a/evil.py\n'
    printf '@@ -1 +999 @@\n'
    printf 'diff --git a/evil.py b/evil.py\n'
  } > real.py
}
d=$(mk_repo fakeheaders l_first l_second)
raw=$( (cd "$d" && git diff --no-renames -U0 HEAD~1 HEAD) )
assert_contains "$raw" '+++ b/evil.py' "前置：diff 正文里确实出现了与文件头同形的行"
j=$(changed_json "$d")
assert_eq "$(printf '%s' "$j" | jq -r 'keys | join(",")')" "real.py" "伪造头：只认真实文件 real.py，不凭空造出 evil.py"
assert_eq "$(lines_of "$j" real.py)" "2,3,4,5" "伪造头：正文里的 @@ 行不被当成 hunk 头（不产生第 999 行）"
assert_not_contains "$(lines_of "$j" real.py)" "999" "伪造头：伪造的 hunk 头没有污染行号集合"

# ============ 空 diff → 空对象（不是空串、不是 null）============
assert_eq "$(printf '' | review_changed_lines)" "{}" "空输入 → {}"
assert_eq "$(printf '%s' "$(printf '' | review_changed_lines)" | jq -r 'type')" "object" "空输入的输出仍是合法 JSON 对象"

# ============ 同一文件多次出现（多个 diff --git 段）：区间累加，不互相覆盖 ============
two=$(printf 'diff --git a/x.py b/x.py\n--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n-a\n+A\n')
two=$(printf '%s\n' "$two" && printf 'diff --git a/y.py b/y.py\n--- a/y.py\n+++ b/y.py\n@@ -0,0 +5,2 @@\n+p\n+q\n')
j=$(printf '%s\n' "$two" | review_changed_lines)
assert_eq "$(lines_of "$j" x.py)" "1" "两个文件段：第一个文件的行号正确"
assert_eq "$(lines_of "$j" y.py)" "5,6" "两个文件段：第二个文件的行号正确（+5,2 → 5..6）"

# ============ 畸形 hunk 头不能让解析崩，也不能产生行号 ============
bad=$(printf 'diff --git a/z.py b/z.py\n--- a/z.py\n+++ b/z.py\n@@ 这不是 hunk 头 @@\n+a\n@@ -1,0 +0,0 @@\n@@ -1 +2 @@\n+b\n')
j=$(printf '%s\n' "$bad" | review_changed_lines)
assert_eq "$(lines_of "$j" z.py)" "2" "畸形 hunk 头被忽略，+0,0 不产生行号，合法的 @@ -1 +2 @@ 仍解析为第 2 行"

report
