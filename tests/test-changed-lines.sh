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
# _git_diff_pinned：解析器与「怎么产出 diff」是成对的，所以两边共用生产里的那一个封装
source "$ROOT/scripts/lib/diff-compress.sh"
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
# 在仓库里跑「生产用的那条 diff 命令」并解析。用的就是生产的 _git_diff_pinned，
# 不是在测试里另抄一份参数——抄一份的话，生产漏钉某个配置时这里照样全绿。
changed_json() {
  local d="$1"
  (cd "$d" && _git_diff_pinned --no-renames -U0 HEAD~1 HEAD) | review_changed_lines
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

# ============ 执行器的 git 配置不能改变解析结果（_git_diff_pinned 的职责）============
# 这些配置都能悄悄改掉 patch 的形态，而改掉之后**不报错**：变更行集合会变成空集合或带前缀的键，
# 于是所有问题都被判成「未定位」，一条行内评论都发不出，日志里也看不出是配置问题。
m_first()  { printf 'l1\nl2\n' > cfg.py; }
m_second() { printf 'l1\nl2\nl3\n' > cfg.py; }
d=$(mk_repo gitconfig m_first m_second)
assert_eq "$(lines_of "$(changed_json "$d")" cfg.py)" "3" "前置：默认配置下第 3 行可定位"
# ① diff.dstPrefix / diff.srcPrefix：实测（git 2.50.1）会让输出变成 `+++ DST/cfg.py`，
#    而 `-c diff.noprefix=false` 拦不住它——只有命令行的 --dst-prefix 能覆盖
raw=$( (cd "$d" && git -c diff.dstPrefix=DST/ diff --no-ext-diff --no-renames -U0 HEAD~1 HEAD) )
assert_contains "$raw" "+++ DST/cfg.py" "前置：diff.dstPrefix 确实会改掉 +++ 行的前缀"
# GIT_CONFIG_COUNT/KEY/VALUE 模拟「执行器的 gitconfig 里就写着这些」，比 -c 更贴近真实场景
for cfg in diff.dstPrefix=DST/ diff.srcPrefix=SRC/ diff.noprefix=true diff.mnemonicPrefix=true; do
  j=$( (cd "$d" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="${cfg%%=*}" GIT_CONFIG_VALUE_0="${cfg#*=}" \
        _git_diff_pinned --no-renames -U0 HEAD~1 HEAD) | review_changed_lines )
  assert_eq "$(printf '%s' "$j" | jq -r 'keys | join(",")')" "cfg.py" "钉死配置：${cfg} 下键名仍是裸路径"
  assert_eq "$(lines_of "$j" cfg.py)" "3" "钉死配置：${cfg} 下行号仍解析正确"
done
# ② 外置 diff 驱动：输出完全另一种格式，不钉死的话集合直接为空
cat > "$tmp/extdiff.sh" <<'SH'
#!/usr/bin/env bash
echo "external diff driver output for $1"
SH
chmod +x "$tmp/extdiff.sh"
raw=$( (cd "$d" && GIT_EXTERNAL_DIFF="$tmp/extdiff.sh" git diff --no-renames -U0 HEAD~1 HEAD) )
assert_contains "$raw" "external diff driver output" "前置：外置 diff 驱动确实会顶掉 patch 输出"
j=$( (cd "$d" && GIT_EXTERNAL_DIFF="$tmp/extdiff.sh" _git_diff_pinned --no-renames -U0 HEAD~1 HEAD) | review_changed_lines )
assert_eq "$(lines_of "$j" cfg.py)" "3" "钉死配置：GIT_EXTERNAL_DIFF 被 --no-ext-diff 挡住"
j=$( (cd "$d" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0="$tmp/extdiff.sh" _git_diff_pinned --no-renames -U0 HEAD~1 HEAD) | review_changed_lines )
assert_eq "$(lines_of "$j" cfg.py)" "3" "钉死配置：diff.external 同样被挡住"
# ③ 反向确认这些断言不是恒真的：不钉死时确实会解析错（否则上面全是空转）
j=$( (cd "$d" && git -c diff.dstPrefix=DST/ diff --no-ext-diff --no-renames -U0 HEAD~1 HEAD) | review_changed_lines )
assert_eq "$(printf '%s' "$j" | jq -r 'keys | join(",")')" "DST/cfg.py" "正控：不钉死 --dst-prefix 时键名带上了前缀（所有问题会变「未定位」）"
j=$( (cd "$d" && GIT_EXTERNAL_DIFF="$tmp/extdiff.sh" git diff --no-renames -U0 HEAD~1 HEAD) | review_changed_lines )
assert_eq "$j" "{}" "正控：不加 --no-ext-diff 时集合为空"

# ============ 文件名含换行/Tab/控制字符：不能伪造出别的文件的键，也不能把自己丢掉（票 09）============
# git 对控制字符一律 C 转义（core.quotePath=false 也不例外），解析器还原后的换行若原样进入按行切分的
# 中间流，第二行 `src/untouched.py<US>1<US>2` 字段数正好合法——一个 MR 没碰的文件就出现在变更行集合里，
# 行内评论可以被引到它的任意行上（而带换行文件名自己的问题全部落进「未定位」）。
n_first()  { mkdir -p src; printf 'a\nb\nc\n' > src/untouched.py; printf 'x\n' > keep.txt; }
n_second() {
  local nl_name tab_name us_name
  nl_name=$(printf 'x\nsrc/untouched.py'); tab_name=$(printf 't\tab.py'); us_name=$(printf 'u\037src/untouched.py\0371\0373.py')
  mkdir -p "$(dirname "$nl_name")" "$(dirname "$us_name")"
  printf 'l1\nl2\n' > "$nl_name"
  printf 'l1\n' > "$tab_name"
  printf 'l1\nl2\nl3\n' > "$us_name"
}
d=$(mk_repo ctrlpath n_first n_second)
raw=$( (cd "$d" && _git_diff_pinned --no-renames -U0 HEAD~1 HEAD) )
assert_contains "$raw" '+++ "b/x\nsrc/untouched.py"' "前置：core.quotePath=false 下 git 仍对控制字符做 C 转义"
j=$(changed_json "$d")
assert_eq "$(printf '%s' "$j" | jq -r 'has("src/untouched.py")')" "false" "控制字符路径：没碰过的 src/untouched.py 不得出现在集合里"
assert_eq "$(lines_of "$j" "$(printf 'x\nsrc/untouched.py')")" "1,2" "控制字符路径：带换行的文件名本身是键、行号正确"
assert_eq "$(lines_of "$j" "$(printf 't\tab.py')")" "1" "控制字符路径：Tab 文件名是键"
assert_eq "$(lines_of "$j" "$(printf 'u\037src/untouched.py\0371\0373.py')")" "1,2,3" "控制字符路径：含 0x1f 的文件名不被字段分隔符吃掉"
assert_eq "$(printf '%s' "$j" | jq -r 'length')" "3" "控制字符路径：恰好三个键"


# ============ git 的全部 C 转义都必须按表还原（票 09 复审）============
# git quote.c 会输出 \a \b \f \n \r \t \v \" \\ 与 \NNN 八进制。解析器若对不认识的转义
# 「丢掉反斜杠、留下字母」，`src/<BEL>pp.py`（git 写成 `+++ "b/src/\app.py"`）就会被还原成
# `src/app.py`——一个 MR 没碰过的文件，行内评论可以挂到它任意行上（I5「定位可信」）。
o_first()  { mkdir -p src; printf 'real\n' > src/app.py; printf 'real\n' > src/back.py; printf 'x\n' > keep.txt; }
o_second() {
  mkdir -p src
  printf 'l1\nl2\n' > "$(printf 'src/\007pp.py')"    # \a → 若丢反斜杠会变成 src/app.py
  printf 'l1\n'     > "$(printf 'src/\010ack.py')"   # \b → src/back.py
  printf 'l1\n'     > "$(printf 'src/\014f.py')"     # \f → src/ff.py
  printf 'l1\n'     > "$(printf 'src/\013t.py')"     # \v → src/vt.py
}
d=$(mk_repo cescapes o_first o_second)
raw=$( (cd "$d" && _git_diff_pinned --no-renames -U0 HEAD~1 HEAD) )
assert_contains "$raw" '+++ "b/src/\app.py"' "前置：git 用 \\a 转义 BEL 字节"
j=$(changed_json "$d")
for forged in src/app.py src/back.py src/ff.py src/vt.py; do
  assert_eq "$(printf '%s' "$j" | jq -r --arg p "$forged" 'has($p)')" "false" "C 转义：不得伪造出未改动文件 ${forged} 的键"
done
assert_eq "$(lines_of "$j" "$(printf 'src/\007pp.py')")" "1,2" "C 转义：\\a 还原为 BEL，键是真实文件名"
assert_eq "$(lines_of "$j" "$(printf 'src/\010ack.py')")" "1" "C 转义：\\b 还原为 BS"
assert_eq "$(lines_of "$j" "$(printf 'src/\014f.py')")" "1" "C 转义：\\f 还原为 FF"
assert_eq "$(lines_of "$j" "$(printf 'src/\013t.py')")" "1" "C 转义：\\v 还原为 VT"
assert_eq "$(printf '%s' "$j" | jq -r 'length')" "4" "C 转义：恰好四个键"

# 表外转义（git 不会产出）必须硬失败，绝不能猜：猜错就是把评论发到别的文件上
rc=0
printf 'diff --git a/x b/x\n--- a/x\n+++ "b/x\\qy.py"\n@@ -0,0 +1 @@\n+a\n' | review_changed_lines >/dev/null 2>&1 || rc=$?
assert_eq "$([[ "$rc" != "0" ]] && echo failed || echo ok)" "failed" "表外转义 \\q → 解析失败（调用方据此终止评审），不静默猜路径"
# 失败必须不依赖调用方的 pipefail，且**先解析成功的文件也不能漏出去**：
# 部分集合 + 成功返回 = 行内评论照发、失败的那些文件静默进「未定位」，比整次失败更糟
partial=$(printf 'diff --git a/g b/g\n--- a/g\n+++ b/good.py\n@@ -0,0 +1 @@\n+a\ndiff --git a/x b/x\n--- a/x\n+++ "b/x\\qy.py"\n@@ -0,0 +1 @@\n+a\n')
rc=0
out_partial=$(set +o pipefail; printf '%s' "$partial" | review_changed_lines 2>/dev/null) || rc=$?
assert_eq "$([[ "$rc" != "0" ]] && echo failed || echo ok)" "failed" "表外转义：没开 pipefail 时仍失败（awk 的 rc 被显式检查）"
assert_eq "$out_partial" "" "表外转义：失败时不输出部分集合（前面已解析成功的 good.py 也不许漏出去）"


# ============ 引号形式的路径后面还跟着一个 TAB（票 09 复审残留）============
# git 对需要转义的路径输出 `+++ "b/…"` **并在后面补一个 TAB**。按「去掉首尾各一个字符」剥引号时
# 剥掉的是那个 TAB 而不是结尾引号，键上就多一个 `"`：
#   ① 该文件的所有问题都判为「未定位」（键对不上），静默进折叠区；
#   ② `<真名>"` 本身也是合法文件名——攻击者再加一个那样命名的文件，就能让它拿到别的文件的行号区间。
# 空格路径（引号但无转义字符）与 Tab 路径（有转义字符）分别测过，**组合**从没测过。
p_first()  { printf 'x\n' > keep.txt; }
p_second() {
  printf 'l1\nl2\n' > "$(printf 'has space\tand tab.py')"
  printf 'l1\n'     > "$(printf 'has space\tand tab.py"')"
}
d=$(mk_repo quotedtab p_first p_second)
raw=$( (cd "$d" && _git_diff_pinned --no-renames -U0 HEAD~1 HEAD) )
assert_contains "$raw" '+++ "b/has space\tand tab.py"' "前置：引号形式的路径确实出现"
j=$(changed_json "$d")
assert_eq "$(lines_of "$j" "$(printf 'has space\tand tab.py')")" "1,2" "引号+TAB：键是真实路径，不多一个引号"
assert_eq "$(lines_of "$j" "$(printf 'has space\tand tab.py"')")" "1" "引号+TAB：真的以引号结尾的文件名是它自己的键"
assert_eq "$(printf '%s' "$j" | jq -r 'length')" "2" "引号+TAB：恰好两个键（两个文件互不串位）"

report
