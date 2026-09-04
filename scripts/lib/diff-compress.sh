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
# `+++ b/<路径>` 与 `@@ -a,b +c,d @@`。构建机的 gitconfig 能改掉这个形态，而改掉之后**不会报错**
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
# 喂给评审员的 diff（kiro-review.sh 第 4 步，经本文件）与变更行集合（第 4.5 步）共用这一个封装：
# 模型看到的行与脚本判定「可定位」的行必须出自同一次、同一形态的比较。
_git_diff_pinned() {
  git -c core.quotePath=false -c diff.external= -c diff.noprefix=false -c diff.mnemonicPrefix=false \
    diff --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$@"
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

# $1=base_sha $2=head_sha $3=输出直传diff $4=输出省略清单 $5=chunk目录
# 返回 0=未截断；10=已截断；1=内部错误（落盘失败、索引损坏等——调用方按 rc≠0/10 回写「评审未完成」）。
# 需在业务仓库 git 目录内调用。
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
  # 省略清单契约要求 chunk 为绝对路径（下游读取方 cwd 不一定等于调用方 cwd）
  chunk_dir=$(cd "$chunk_dir" && pwd) || return 1

  # --no-renames：重命名按删除+新增处理，保证总量与 chunk 大小口径一致
  local total
  total=$(_git_diff_pinned --no-renames "$base" "$head" | wc -c | tr -d ' ') || return 1
  if [[ "$total" -le "$DIFF_SIZE_LIMIT" ]]; then
    _git_diff_pinned --no-renames "$base" "$head" > "$out_diff" || return 1
    return 0
  fi

  # 逐文件生成 chunk（NUL 分隔读路径，含空格/换行/Tab 安全）。
  # 索引只存脚本自己产生的三个数字字段：优先级、大小、序号。**文件名不进索引**——Git 文件名允许
  # 换行与 Tab，写进按行/Tab 解析的中间文件就等于让 MR 作者伪造索引记录、把下面的 `cat` 指向
  # 评审机上的任意可读文件（票 06 P0：伪造记录 `0\t1\t/root/.aws/credentials` 曾能把凭证读进评审输入）。
  # 文件名一名一文件落在 NNNN.path 里（printf '%s'，无分隔符），只在渲染省略清单时读出。
  local index="$chunk_dir/.index" n=0 path chunk prio size
  : > "$index" || return 1
  while IFS= read -r -d '' path; do
    n=$((n + 1))
    chunk=$(_chunk_file "$chunk_dir" "$n")
    # :(literal) 防止路径中的 pathspec 魔法前缀（如冒号开头）或 glob 字符
    # 导致 chunk 为空或串入其他文件的 diff
    _git_diff_pinned --no-renames "$base" "$head" -- ":(literal)$path" > "$chunk" || return 1
    printf '%s' "$path" > "${chunk%.diff}.path" || return 1
    prio=$(_diff_priority "$path" "$chunk")
    size=$(wc -c < "$chunk" | tr -d ' ')
    printf '%s\t%s\t%s\n' "$prio" "$size" "$n" >> "$index" || return 1
  done < <(_git_diff_pinned --no-renames --name-only -z "$base" "$head")

  # 优先级升序、同级内小文件优先、同级同大小按 git 顺序，逐个装填预算；整文件删除(3)永不直传。
  # chunk 路径永远由序号重建，绝不从索引读回；三个字段必须是纯数字——索引是本函数刚写的，
  # 出现别的东西只能是内部错误，宁可整次评审失败也不能猜。
  local sorted="$chunk_dir/.index.sorted" used=0 added removed
  sort -t"$(printf '\t')" -k1,1n -k2,2n -k3,3n "$index" > "$sorted" || return 1
  while IFS=$'\t' read -r prio size n; do
    [[ "$prio" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ && "$n" =~ ^[0-9]+$ ]] \
      || { echo "build_review_input: chunk 索引出现非数字字段（内部错误）：[$prio] [$size] [$n]" >&2; return 1; }
    chunk=$(_chunk_file "$chunk_dir" "$n")
    if [[ "$prio" != "3" ]] && [[ $((used + size)) -le "$DIFF_SIZE_LIMIT" ]]; then
      cat "$chunk" >> "$out_diff" || return 1
      used=$((used + size))
    else
      added=$(grep -c '^+[^+]' "$chunk" || true)
      removed=$(grep -c '^-[^-]' "$chunk" || true)
      # 文件名从 NNNN.path 读回：read -d '' 而不是 $(cat)（命令替换会吃掉文件名末尾的换行）；
      # 先清空再读，sidecar 缺失时绝不能沿用上一个文件的名字——那是内部错误，直接失败。
      path=""
      [[ -f "${chunk%.diff}.path" ]] \
        || { echo "build_review_input: 缺少 ${chunk%.diff}.path（内部错误）" >&2; return 1; }
      IFS= read -r -d '' path < "${chunk%.diff}.path" || true
      jq -nc --arg chunk "$chunk" --arg file "$path" --argjson added "$added" --argjson removed "$removed" \
        '{chunk: $chunk, file: $file, added: $added, removed: $removed}' >> "$out_omitted" || return 1
    fi
  done < "$sorted"

  # rc 10 意味着 total > DIFF_SIZE_LIMIT、至少有一个文件，两个输出不可能同时为空；同时为空只能是内部错误
  [[ -s "$out_diff" || -s "$out_omitted" ]] \
    || { echo "build_review_input: 已截断却没有任何输出（内部错误）" >&2; return 1; }
  return 10
}
