#!/usr/bin/env bash
# diff 压缩：参考 PR-Agent Compression Strategy
# (https://docs.pr-agent.ai/core-abilities/compression_strategy/)
# 超限时逐文件生成 diff chunk 落盘，未直传文件通过省略清单提供 chunk 路径，
# 由 Kiro 用 read 工具读取 chunk（而非仓库当前文件——当前文件无法体现改动，
# 删除文件更是已不存在）。路径处理用 git -z（NUL 分隔），支持含空格路径。
# v1 为文件级分类：整文件删除=优先级 3；不做 hunk 级拆分。

DIFF_SIZE_LIMIT="${DIFF_SIZE_LIMIT:-307200}"

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

# $1=base_sha $2=head_sha $3=输出直传diff $4=输出省略清单 $5=chunk目录
# 返回 0=未截断；10=已截断。需在业务仓库 git 目录内调用。
build_review_input() {
  local base="$1" head="$2" out_diff="$3" out_omitted="$4" chunk_dir="$5"
  : > "$out_diff"; : > "$out_omitted"
  mkdir -p "$chunk_dir"
  # 省略清单契约要求 chunk 为绝对路径（下游读取方 cwd 不一定等于调用方 cwd）
  chunk_dir=$(cd "$chunk_dir" && pwd)

  # --no-renames：重命名按删除+新增处理，保证总量与 chunk 大小口径一致
  local total
  total=$(git diff --no-renames "$base" "$head" | wc -c | tr -d ' ')
  if [[ "$total" -le "$DIFF_SIZE_LIMIT" ]]; then
    git diff --no-renames "$base" "$head" > "$out_diff"
    return 0
  fi

  # 逐文件生成 chunk（NUL 分隔读路径，含空格安全）
  local index="$chunk_dir/.index" n=0 path chunk prio size
  : > "$index"
  while IFS= read -r -d '' path; do
    n=$((n + 1))
    chunk=$(printf '%s/%04d.diff' "$chunk_dir" "$n")
    # :(literal) 防止路径中的 pathspec 魔法前缀（如冒号开头）或 glob 字符
    # 导致 chunk 为空或串入其他文件的 diff
    git diff --no-renames "$base" "$head" -- ":(literal)$path" > "$chunk"
    prio=$(_diff_priority "$path" "$chunk")
    size=$(wc -c < "$chunk" | tr -d ' ')
    printf '%s\t%s\t%s\t%s\n' "$prio" "$size" "$chunk" "$path" >> "$index"
  done < <(git diff --no-renames --name-only -z "$base" "$head")

  # 优先级升序、同级内小文件优先，逐个装填预算；整文件删除(3)永不直传
  local sorted="$chunk_dir/.index.sorted" used=0 added removed
  sort -t"$(printf '\t')" -k1,1n -k2,2n "$index" > "$sorted"
  while IFS=$'\t' read -r prio size chunk path; do
    if [[ "$prio" != "3" ]] && [[ $((used + size)) -le "$DIFF_SIZE_LIMIT" ]]; then
      cat "$chunk" >> "$out_diff"
      used=$((used + size))
    else
      added=$(grep -c '^+[^+]' "$chunk" || true)
      removed=$(grep -c '^-[^-]' "$chunk" || true)
      printf -- '- %s (+%s / -%s) => %s\n' "$path" "$added" "$removed" "$chunk" >> "$out_omitted"
    fi
  done < "$sorted"

  return 10
}
