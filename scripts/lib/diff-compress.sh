#!/usr/bin/env bash
# diff 压缩：参考 PR-Agent Compression Strategy
# (https://docs.pr-agent.ai/core-abilities/compression_strategy/)
# 超限时逐文件生成 diff chunk 落盘，未直传文件通过省略清单提供 chunk 路径，
# 由 Kiro 用 read 工具读取 chunk（而非仓库当前文件——当前文件无法体现改动，
# 删除文件更是已不存在）。路径处理用 git -z（NUL 分隔）；文件名只以 NUL 或「一名一文件」流转，
# 绝不写进按行/Tab 解析的中间文件（含空格/换行/Tab 的名字都安全，见 build_review_input 注释）。
# v1 为文件级分类：整文件删除=优先级 3；不做 hunk 级拆分。

# 取值校验在调用方（kiro-review.sh 第 1.6 步）：非纯数字会让下面的 `-le` 比较报算术错误并取假，
# 于是整份 diff 都进省略清单。校验必须在那里做，因为只有定位到 MR 之后才能把失败回写成 MR 评论（I10）。
DIFF_SIZE_LIMIT="${DIFF_SIZE_LIMIT:-307200}"

# --- 钉死 patch 形态的 git diff（与 review_changed_lines 的解析器成对）---
# 用法：_git_diff_pinned <git diff 的其余参数…>
# review_changed_lines（scripts/lib/review-render.sh）认死了 git 默认的 unified patch 形态：
# `+++ b/<路径>` 与 `@@ -a,b +c,d @@`。执行器的 gitconfig 能改掉这个形态，而改掉之后**不会报错**
# ——变更行集合会静默变成空集合或带前缀的键，于是所有问题都被判成「未定位」，一条行内评论都发不出。
# 所以凡是能改形态的开关都在命令行上钉死，一个都不能漏：
#   --no-ext-diff / -c diff.external=   外置 diff 驱动（diff.external、GIT_EXTERNAL_DIFF）输出的
#                                       是完全另一种格式
#   --src-prefix=a/ --dst-prefix=b/     实测（git 2.50.1）`-c diff.dstPrefix=DST/` 会让输出变成
#                                       `+++ DST/app.py`，而 `-c diff.noprefix=false` 拦不住它；
#                                       只有命令行的 --src-prefix/--dst-prefix 能覆盖这两个配置
#   -c diff.noprefix=false              去掉 a/ b/ 前缀后，真名以 `b/` 开头的文件会被剥错
#   -c diff.mnemonicPrefix=false        前缀会变成 c/ i/ w/ o/，`b/` 就剥不掉了
#   -c core.quotePath=false             非 ASCII 路径不被转义，键名就是真实路径
#   -c diff.relative=false              开了 diff.relative 后，从子目录调用时输出只含 cwd 之下的路径且去掉了
#                                       前缀：`+++ b/<路径>` 的键名变了，而 build_review_input 的 `:(top,literal)`
#                                       pathspec 也会对不上、每个 chunk 都是 0 字节（复审实测，票 12 ①）
# 喂给评审员的 diff（kiro-review.sh 第 4 步，经本文件）与变更行集合（第 4.5 步）共用这一个封装：
# 模型看到的行与脚本判定「可定位」的行必须出自同一次、同一形态的比较。
#   --no-color / -c color.ui=never      执行器上 color.ui=always 会给每行加 ANSI 前缀，变更行解析器一行都对不上
#                                       （CodeX 2026-09-09 P0-1 附带项）
#   --no-textconv                       执行器配置的 textconv 驱动能改写乃至清空 diff（同上，属执行器侧配置，一并钉死）
#   --text（按需）                       见下面 REVIEW_DIFF_FORCE_TEXT：树内 .gitattributes 的 `-diff` 是 MR 作者可控的
# 是否对整份 diff 强制按文本比较（--text）。默认 0；kiro-review.sh 第 4.0 步用 review_diff_attr_scan 发现业务库 Git 属性把
# 改动文件标成 -diff 或指定了自定义驱动时置 1（CodeX 2026-09-09 P0-1）。不无条件加 --text：真正的二进制文件会把大量原始字节
# 送进评审输入。四处调用（直传 / 枚举 / 逐文件 chunk / 零上下文 inline.diff）都经本封装，一次判定对整轮一致。
REVIEW_DIFF_FORCE_TEXT="${REVIEW_DIFF_FORCE_TEXT:-0}"
_git_diff_pinned() {
  local -a text=()
  [[ "${REVIEW_DIFF_FORCE_TEXT:-0}" == "1" ]] && text=(--text)
  git -c core.quotePath=false -c diff.external= -c diff.noprefix=false -c diff.mnemonicPrefix=false \
      -c diff.relative=false -c color.ui=never \
    diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "${text[@]+"${text[@]}"}" "$@"
}

# --- 变更文件的 Git diff 属性扫描（CodeX 2026-09-09 P0-1）---
# 树内 .gitattributes 是 MR 作者可控的：同一个 MR 里加一行 `*.sh -diff` 再改 Shell 文件，git diff 对该文件只输出
# 「Binary files a/… and b/… differ」、numstat 是 `-  -`——改动既不进评审输入也进不了变更行集合，评审在没看到代码的情况下
# 静默完成（2026-09-09 复现）。git 没有「忽略树内属性」的开关，所以按 changed paths 查 `git check-attr diff`：
#   unset（即 -diff）或任何驱动名 → 触发；unspecified / set 都是正常文本比较，不触发（set 是「明确文本」，不能误报）。
# 只统计数目、不把文件名带出（文件名不受信）。全程 NUL 分隔：文件名含空格 / Tab / 换行都安全。
# 用法：review_diff_attr_scan <base> <head> → 设置 REVIEW_DIFF_ATTR_UNSET / REVIEW_DIFF_ATTR_DRIVER，rc 0；git 失败 rc 1。
# 须在业务仓库内调用（check-attr 读的是工作树 / 索引里的属性，与随后 git diff 用的是同一套）。
REVIEW_DIFF_ATTR_UNSET=0; REVIEW_DIFF_ATTR_DRIVER=0
review_diff_attr_scan() {
  local base="$1" head="$2" names attrs path _attr val n_unset=0 n_driver=0
  names=$(mktemp) || return 1
  attrs=$(mktemp) || { rm -f "$names"; return 1; }
  if ! _git_diff_pinned --no-renames --name-only -z "$base" "$head" > "$names"; then rm -f "$names" "$attrs"; return 1; fi
  if ! git check-attr --stdin -z diff < "$names" > "$attrs"; then rm -f "$names" "$attrs"; return 1; fi
  # -z 输出：<path> NUL <attr> NUL <value> NUL，三个一组
  while IFS= read -r -d '' path && IFS= read -r -d '' _attr && IFS= read -r -d '' val; do
    case "$val" in
      unspecified|set) ;;
      unset) n_unset=$((n_unset + 1)) ;;
      *) n_driver=$((n_driver + 1)) ;;
    esac
  done < "$attrs"
  rm -f "$names" "$attrs"
  REVIEW_DIFF_ATTR_UNSET=$n_unset; REVIEW_DIFF_ATTR_DRIVER=$n_driver
  return 0
}

# --- git 自身判定的二进制变更扫描（CodeX 2026-09-11 复审 P1）---
# review_diff_attr_scan 只覆盖「树内 .gitattributes 把文件标成 -diff」这一条路。**git 的二进制判定并不依赖属性**：
# 前 8000 字节里有一个 NUL 就够（`git help diff` 的 --text 一节）。于是 MR 作者连 .gitattributes 都不用碰——
# 在注释里塞一个 NUL 字节、同时改可执行代码，`git diff` 就只输出「Binary files a/… and b/… differ」、numstat 是 `-  -`：
# 改动既不进评审输入也进不了变更行集合，而文件照样能被 bash 执行（2026-09-11 复现：`printf '#!/bin/bash\n# note:\000 x\necho NEW\n'`
# 改动后 diff 全无、bash 正常输出 NEW）。这和 2026-09-09 那条 P0 是同一个 fail-open，只是触发器不同。
#
# 判定分两类，因为处置不同：
#   textlike  git 说是二进制、但内容压倒性可读（掺了几个 NUL 的源码）→ 对整轮强制 --text，改动照常进评审
#   opaque    真二进制（图片、压缩包、UTF-16）→ 展示原始字节没有意义，**明确写进汇总说这些文件的改动未被评审**，
#             不能让它们静默消失在「评审完成」里
# 判据是「控制字节占比」：删掉 \t \n \r、可打印 ASCII 与全部高位字节（≥0x80，中文源码要算可读）之后剩下的就是
# 0x00-0x08 / 0x0B / 0x0C / 0x0E-0x1F / 0x7F 这 30 个码位。均匀随机数据落在 30/256 ≈ 117‰ 附近（实测 PNG 129‰、
# gzip 114‰），掺 NUL 的源码在 27‰ 附近（实测 1 NUL/37 字节的 shell、200 NUL/7409 字节的中文 py 都是 26–27‰）。
# 阈值取 50‰（5%），两边各有一倍以上余量。攻击者当然可以把 NUL 撒密到越过阈值——那时该文件被判 opaque，
# 于是**在汇总里被点名「未评审」**，拿不到静默隐藏，fail-open 已经关掉。
# 判据算在该文件的**单文件 --text patch** 上（两侧内容都在里面），而不是去 cat-file 取 blob：路径可能含换行/Tab，
# `:(top,literal)` pathspec 是本文件既有的 NUL 安全做法，cat-file --batch 的行协议不是。
# 只统计数目、不把文件名带出（文件名不受信，票 06/07/09 同一理由）。
REVIEW_DIFF_BIN_TEXTLIKE=0; REVIEW_DIFF_BIN_OPAQUE=0
REVIEW_DIFF_BIN_CTL_PERMILLE_MAX="${REVIEW_DIFF_BIN_CTL_PERMILLE_MAX:-50}"   # 控制字节 ≤ 50‰ 判 textlike
REVIEW_DIFF_BIN_SAMPLE_BYTES="${REVIEW_DIFF_BIN_SAMPLE_BYTES:-8000}"        # 与 git 自己的判定窗口同宽
# 单文件 --text patch 的控制字节千分比 → stdout 整数；rc 1 = git 真的失败
# **样本必须落盘、不能进 bash 变量**（CodeX 2026-09-12 复审 P1，两条独立缺陷，都已复现）：
#   ① 命令替换 `$(…)` **丢弃 NUL 字节**——而 NUL 正是这里要数的那个字节。32 KiB 全零文件因此算出 0‰、
#      被判 textlike、整轮强制 --text，32768 个原始 NUL 直接进模型 stdin，正好违背「真二进制不展开」的设计目标。
#   ② `git … | head -c N` 在 patch 超过管道缓冲区时让 git 收到 SIGPIPE、退出码 141，而脚本是 `set -o pipefail`：
#      整条管道 141 → 旧写法的 `|| return 1` 把它当成 git 失败 → 第 4.0b 步 die_review → **一个普通大图片就能让
#      整次评审失败**（128 KiB 全零文件复现：git rc=141、scan rc=1、评审 rc=1）。
# 做法：git 的退出码单独写进文件（它不写管道，不会跟着被 SIGPIPE 打断），样本经 head 截断后落盘，
# 计数用 tr/wc 直接读文件——tr 与 wc 都能正确处理 NUL。git 的 141 是**预期**的（截断是我们主动的），
# 别的非零才是真错误，仍然 return 1。
_diff_ctl_permille() {
  local base="$1" head="$2" path="$3" sample rcf win ctl rc_git
  sample=$(mktemp) || return 1
  rcf=$(mktemp) || { rm -f "$sample"; return 1; }
  # 显式 --text：本函数要的是「如果按文本比会看到什么」，不能受 REVIEW_DIFF_FORCE_TEXT 影响（它可能已被属性扫描置 1）
  { git -c core.quotePath=false -c diff.external= -c diff.noprefix=false -c diff.mnemonicPrefix=false \
        -c diff.relative=false -c color.ui=never \
        diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --text \
        --no-renames "$base" "$head" -- ":(top,literal)${path}"
    printf '%s' "$?" > "$rcf"
  } 2>/dev/null | head -c "$REVIEW_DIFF_BIN_SAMPLE_BYTES" > "$sample" || true
  rc_git=$(cat "$rcf" 2>/dev/null || true); rm -f "$rcf"
  case "$rc_git" in
    0|141) ;;                                     # 0 = patch 读完；141 = 我们主动截断，git 收 SIGPIPE（预期）
    *) rm -f "$sample"; return 1 ;;               # 别的非零：git 真的失败了
  esac
  win=$(wc -c < "$sample" | tr -d ' ')
  if ! [[ "$win" =~ ^[0-9]+$ ]] || [[ "$win" -le 0 ]]; then rm -f "$sample"; printf '0'; return 0; fi   # 空 patch（只改模式）没有可疑内容
  ctl=$(LC_ALL=C tr -d '\11\12\15\40-\176\200-\377' < "$sample" | wc -c | tr -d ' ')
  rm -f "$sample"
  [[ "$ctl" =~ ^[0-9]+$ ]] || return 1
  printf '%s' $(( ctl * 1000 / win ))
}
# review_diff_binary_scan <base> <head> → 设置 REVIEW_DIFF_BIN_TEXTLIKE / REVIEW_DIFF_BIN_OPAQUE；rc 0；git 失败 rc 1
# 须在业务仓库内调用（与随后的 git diff 同一套配置）。
review_diff_binary_scan() {
  local base="$1" head="$2" ns add rem path n_text=0 n_opaque=0 permille
  ns=$(mktemp) || return 1
  # 显式不带 --text：要的是 git 的原生判定（`-  -` = 它认为这是二进制）
  if ! git -c core.quotePath=false -c diff.external= -c diff.relative=false -c color.ui=never \
        diff --no-color --no-ext-diff --no-textconv --no-renames --numstat -z "$base" "$head" > "$ns"; then
    rm -f "$ns"; return 1
  fi
  # -z 的 numstat 形态：<added> TAB <removed> TAB <path> NUL（--no-renames 下没有额外的双路径记录）
  while IFS= read -r -d '' rec; do
    add=${rec%%$'\t'*}; rem=${rec#*$'\t'}; rem=${rem%%$'\t'*}; path=${rec#*$'\t'}; path=${path#*$'\t'}
    [[ "$add" == "-" && "$rem" == "-" ]] || continue
    [[ -n "$path" ]] || continue
    permille=$(_diff_ctl_permille "$base" "$head" "$path") || { rm -f "$ns"; return 1; }
    if [[ "$permille" -le "$REVIEW_DIFF_BIN_CTL_PERMILLE_MAX" ]]; then n_text=$((n_text + 1)); else n_opaque=$((n_opaque + 1)); fi
  done < "$ns"
  rm -f "$ns"
  REVIEW_DIFF_BIN_TEXTLIKE=$n_text; REVIEW_DIFF_BIN_OPAQUE=$n_opaque
  return 0
}

# $1=文件路径 $2=该文件的 diff chunk 文件；输出优先级 0-3
_diff_priority() {
  local path="$1" chunk_file="$2"
  if grep -q '^deleted file mode' "$chunk_file"; then echo 3; return; fi
  case "$path" in
    *.md|*.markdown|*.txt|*.rst|*.adoc) echo 2 ;;
    *.json|*.yaml|*.yml|*.toml|*.ini|*.lock|*.xml|*.cfg) echo 1 ;;
    *) echo 0 ;;
  esac
}

# $1=chunk 目录（绝对路径） $2=序号 → stdout=该文件的 chunk 路径。索引与省略清单都只认这个形态。
_chunk_file() { printf '%s/%04d.diff' "$1" "$2"; }

# $1=文件名 sidecar（NNNN.path）。缺失或 0 字节都是内部错误：`read -d ''` 读 0 字节文件会得到空串而不报错，
# 省略清单里就会出现 "file":""，读清单的模型不知道那是哪个文件。所以先查再读（票 12 ④）。
_check_path_sidecar() {
  local side="$1"
  [[ -f "$side" ]] || { echo "build_review_input: 缺少 ${side}（内部错误）" >&2; return 1; }
  [[ -s "$side" ]] || { echo "build_review_input: ${side} 为 0 字节（内部错误：文件名不可能为空）" >&2; return 1; }
}

# $1=base $2=head $3=仓库根相对路径 → stdout "added removed"；rc 1 = git 失败或 numstat 没给出这个文件。
# 用 --numstat 而不是 `grep -c '^+[^+]'`：后者要求 `+` 后还有字符，只插入空行的文件、以 `++` 开头的
# 内容行（C 的 `++i;`）都数成 0——而这两个数正是提示词让模型用来排优先级的信号（票 12 ③）。
# 每个未直传文件多起一次 git（几毫秒）；换 awk 数 chunk 又回到自己解析 patch 形态的老路，不值。
# 只有二进制文件的 `-` 按 0 计（numstat 的约定形态）；输出为空或字段不够两个说明 pathspec 没对上文件，
# 是内部错误——不能把它折成 0/0，那和「改了模式没改内容」的真 0/0 分不开（复审指出）。
_chunk_numstat() {
  local ns added removed
  ns=$(_git_diff_pinned --no-renames --numstat "$1" "$2" -- ":(top,literal)$3") || return 1
  [[ "$ns" == *$'\t'*$'\t'* ]] \
    || { echo "build_review_input: numstat 没有给出 ${3} 的增删行数（内部错误）：[${ns}]" >&2; return 1; }
  added=${ns%%$'\t'*}; removed=${ns#*$'\t'}; removed=${removed%%$'\t'*}
  # 强制文本比较时（CodeX 2026-09-09 P0-1）：--numstat 对 -diff 属性的文件仍按二进制给 `-  -`（--text 只改 patch 输出，实测 git 2.50），
  # 而这些正是被藏起来的文件，清单里写 0/0 会让模型把它们排到最后。此时按该文件的 patch 数 +/- 行（单文件 patch 恰好各有一行
  # +++ / --- 头，减掉即可；`++i` 这类内容行在这里数得对，因为数的是 ^+ 而不是 ^+[^+]）。
  if [[ "$added" == "-" && "$removed" == "-" && "${REVIEW_DIFF_FORCE_TEXT:-0}" == "1" ]]; then
    local patch
    patch=$(_git_diff_pinned --no-renames "$1" "$2" -- ":(top,literal)$3") || return 1
    added=$(printf '%s\n' "$patch" | LC_ALL=C grep -c '^+' || true); removed=$(printf '%s\n' "$patch" | LC_ALL=C grep -c '^-' || true)
    added=$(( added > 0 ? added - 1 : 0 )); removed=$(( removed > 0 ? removed - 1 : 0 ))
  fi
  [[ "$added" == "-" ]] && added=0
  [[ "$removed" == "-" ]] && removed=0
  [[ "$added" =~ ^[0-9]+$ && "$removed" =~ ^[0-9]+$ ]] \
    || { echo "build_review_input: numstat 给出的增删行数不是数字（内部错误）：[${ns}]" >&2; return 1; }
  printf '%s %s\n' "$added" "$removed"
}

# $1=base_sha $2=head_sha $3=输出直传diff $4=输出省略清单 $5=chunk目录
# 返回 0=未截断；10=已截断；1=内部错误（落盘失败、索引损坏等——调用方按 rc≠0/10 回写「评审未完成」）。
# 需在业务仓库内调用（仓库根或任意子目录都行：pathspec 用 `:(top,…)` 按仓库根解析，不依赖 cwd，票 12 ①）。
# 省略清单形态：每行一个 compact JSON 对象 {"chunk":<该文件完整 diff 的绝对路径>,"file":<文件名>,
# "added":N,"removed":N}。用 JSON 而不是 `- 文件名 (+a / -b) => chunk` 这类分隔文本：文件名是 MR 作者
# 可控的，任何靠分隔符切分的行都能被名字里的同款分隔符伪造出第二个「chunk 路径」，让读清单的模型去
# read 别的文件（`foo (+1 / -0) => /etc/passwd` 是合法文件名）；JSON 字符串里换行/Tab/引号/控制字符
# 都由 jq 转义，chunk 字段无二义。清单只喂给模型，不进 Markdown。
build_review_input() {
  local base="$1" head="$2" out_diff="$3" out_omitted="$4" chunk_dir="$5"
  # 每一步落盘都要检查：调用方写成 `build_review_input … || rc=$?`，函数体不受 errexit 保护；
  # 磁盘满/只读目录时不检查就会带着空输出 return 10，而「两个输出都空」在调用方意味着「diff 为空，跳过评审」。
  : > "$out_diff" || return 1
  : > "$out_omitted" || return 1
  mkdir -p "$chunk_dir" || return 1
  # 省略清单契约要求 chunk 为绝对路径（下游读取方 cwd 不一定等于调用方 cwd）。
  # 且必须是**物理路径**（pwd -P，票 15）：执行器把同一个目录的物理路径注入受信 agent 的 allowedPaths，模型按索引
  # 去读时路径形态要与之一致；写逻辑路径（macOS 的 /var/folders → /private/var/folders、TMPDIR 是符号链接）就落在
  # allow 之外——kiro-cli 会不会先解析符号链接再比对未经实测（探测 P1-15 T1 只按物理路径读过），不能依赖它。
  chunk_dir=$(cd "$chunk_dir" && pwd -P) || return 1

  # --no-renames：重命名按删除+新增处理，保证总量与 chunk 大小口径一致。
  # 整份 diff 先落盘再量大小：`$(git … | wc -c | tr …)` 报的是管道最后一个命令的退出码，git 中途死掉会得到
  # total=0、当成「未超限」再跑一次（票 12 ②）。落盘一次也免得同一份 diff 算两遍。
  # .full.diff 与下面的 .names 都是临时文件，用完即删：chunk 目录的契约只有 NNNN.diff / NNNN.path / .index*，
  # 超限的大 MR 也不该在磁盘上留两份整 diff。
  local full="$chunk_dir/.full.diff" total
  _git_diff_pinned --no-renames "$base" "$head" > "$full" || return 1
  total=$(wc -c < "$full") || return 1
  total=${total// /}
  [[ "$total" =~ ^[0-9]+$ ]] || { echo "build_review_input: 量不出 diff 大小（内部错误）：[${total}]" >&2; return 1; }
  if [[ "$total" -le "$DIFF_SIZE_LIMIT" ]]; then
    cat "$full" > "$out_diff" || return 1
    rm -f "$full"
    return 0
  fi
  rm -f "$full"

  # 逐文件生成 chunk（NUL 分隔读路径，含空格/换行/Tab 安全）。
  # 枚举先落盘、检查退出码，再逐行读：`done < <(git …)` 拿不到进程替换的退出码，git 中途死掉（OOM、对象
  # 读错）会得到「部分索引 + 部分清单 + rc 10」，调用方当成功（票 12 ②）。
  # 索引只存脚本自己产生的三个数字字段：优先级、大小、序号。**文件名不进索引**——Git 文件名允许
  # 换行与 Tab，写进按行/Tab 解析的中间文件就等于让 MR 作者伪造索引记录、把下面的 `cat` 指向
  # 评审机上的任意可读文件（票 06 P0：伪造记录 `0\t1\t/root/.aws/credentials` 曾能把凭证读进评审输入）。
  # 文件名一名一文件落在 NNNN.path 里（printf '%s'，无分隔符），只在渲染省略清单时读出。
  local index="$chunk_dir/.index" names="$chunk_dir/.names" n=0 path chunk prio size
  : > "$index" || return 1
  _git_diff_pinned --no-renames --name-only -z "$base" "$head" > "$names" || return 1
  while IFS= read -r -d '' path; do
    n=$((n + 1))
    [[ -n "$path" ]] || { echo "build_review_input: 枚举给出空文件名（内部错误）" >&2; return 1; }
    chunk=$(_chunk_file "$chunk_dir" "$n")
    # :(top,literal)：top 让 pathspec 按仓库根解析（--name-only 给的就是仓库根相对路径；只用 literal 时
    # 按 cwd 解析，从子目录调用每个 chunk 都是 0 字节），literal 防止路径中的魔法前缀（冒号开头）或
    # glob 字符导致 chunk 为空或串入其他文件的 diff。
    _git_diff_pinned --no-renames "$base" "$head" -- ":(top,literal)$path" > "$chunk" || return 1
    # 枚举列出了它，逐文件 diff 却为空：只能是 pathspec 解析走偏（内部错误）。不能静默放过——0 字节的 chunk
    # 永远「装得下」，cat 进直传什么都不加，文件就从评审范围里消失且无日志；函数末尾那条「两个输出都空」
    # 只在**全部**文件都掉的时候才响（票 12 ①）。
    [[ -s "$chunk" ]] || { echo "build_review_input: ${path} 的 chunk 为 0 字节（内部错误：枚举列出了它，逐文件 diff 却为空）" >&2; return 1; }
    printf '%s' "$path" > "${chunk%.diff}.path" || return 1
    prio=$(_diff_priority "$path" "$chunk")
    size=$(wc -c < "$chunk"); size=${size// /}
    printf '%s\t%s\t%s\n' "$prio" "$size" "$n" >> "$index" || return 1
  done < "$names"
  rm -f "$names"

  # 优先级升序、同级内小文件优先、同级同大小按 git 顺序，逐个装填预算；整文件删除(3)永不直传。
  # chunk 路径永远由序号重建，绝不从索引读回；三个字段必须是纯数字——索引是本函数刚写的，
  # 出现别的东西只能是内部错误，宁可整次评审失败也不能猜。
  local sorted="$chunk_dir/.index.sorted" used=0 added removed ns
  sort -t"$(printf '\t')" -k1,1n -k2,2n -k3,3n "$index" > "$sorted" || return 1
  while IFS=$'\t' read -r prio size n; do
    [[ "$prio" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ && "$n" =~ ^[0-9]+$ ]] \
      || { echo "build_review_input: chunk 索引出现非数字字段（内部错误）：[$prio] [$size] [$n]" >&2; return 1; }
    chunk=$(_chunk_file "$chunk_dir" "$n")
    if [[ "$prio" != "3" ]] && [[ $((used + size)) -le "$DIFF_SIZE_LIMIT" ]]; then
      cat "$chunk" >> "$out_diff" || return 1
      used=$((used + size))
    else
      # 文件名从 NNNN.path 读回：read -d '' 而不是 $(cat)（命令替换会吃掉文件名末尾的换行）；
      # 先清空再读，sidecar 缺失或 0 字节时绝不能沿用上一个文件的名字或写出空名——那是内部错误，直接失败。
      path=""
      _check_path_sidecar "${chunk%.diff}.path" || return 1
      IFS= read -r -d '' path < "${chunk%.diff}.path" || true
      ns=$(_chunk_numstat "$base" "$head" "$path") || return 1     # 不用 < <(…)：进程替换拿不到退出码
      read -r added removed <<< "$ns"
      jq -nc --arg chunk "$chunk" --arg file "$path" --argjson added "$added" --argjson removed "$removed" \
        '{chunk: $chunk, file: $file, added: $added, removed: $removed}' >> "$out_omitted" || return 1
    fi
  done < "$sorted"

  # rc 10 意味着 total > DIFF_SIZE_LIMIT、至少有一个文件，两个输出不可能同时为空；同时为空只能是内部错误
  [[ -s "$out_diff" || -s "$out_omitted" ]] \
    || { echo "build_review_input: 已截断却没有任何输出（内部错误）" >&2; return 1; }
  return 10
}
