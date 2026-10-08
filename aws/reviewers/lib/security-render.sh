#!/usr/bin/env bash
# Security Agent 汇总评论的渲染（Phase 2b spec「Security Agent 评审员」R10、R11：2b 只发汇总，不发行内评论）。
# 评论头、历次表、页脚出自 scripts/lib/review-render.sh 的同一份代码（档案 = security）；发现的内容来自 Security Agent 的模型输出——
# 名字、说明、位置标签、总结都是不受信文本（模型读的是不受信的业务库，可能被库里的文字诱导），只经两个既有的清洗函数进评论：
#   _review_meta_cell（code span 里的单元格：去掉 `<>|`、反引号、反斜杠与控制字符）与 _review_sanitize_oneline（结构清洗 + 折成单行）；
#   多行的总结（overview）走 review_sanitize_md（同一套结构清洗，保留换行）。tests/test-security.sh 的注入用例守着它们。
# **不渲染** attackScript / verificationScript / customerNote（F3 与 spec：攻击脚本、验证脚本、人工备注都不进 MR）。
# 调用方先 source 渲染库与 security-lib.sh，并设好 SHORT_SHA、REVIEW_RUN、PRIOR_HISTORY_FILE、CI_COMMIT_REF_NAME、MR_TARGET_BRANCH。

SA_DESC_MAX=800        # 每条说明的码点上限（issue 09 实测差分作业的说明 300–550 字符）
SA_LABEL_MAX=80        # 每个位置标签的码点上限（全库扫描的标签长达上百字符）
SA_OVERVIEW_MAX=3000   # 作业总结（overview）的码点上限，进折叠区
SA_SERVICE_CAP=30      # 服务上限：每次差分扫描最多 30 条发现（run-diff-scan-s3.html）
SA_NONDETERMINISM_NOTE="Security Agent 的结论非确定：同一提交重跑，条数与位置可能不同。"

# 按码点截断（jq 的字符串切片按码点，不会切出半个 UTF-8 字符）
_sa_cut() {  # <取值> <上限>
  jq -nr --arg v "$1" --argjson m "$2" '$v | if length > $m then .[0:$m] + "…" else . end'
}

# 一条发现（compact JSON）→ 一段 Markdown
_sa_render_finding() {  # <序号> <发现 JSON>
  local n="$1" f="$2" name loc path start end label known range desc
  name=$(_review_sanitize_oneline "$(_sa_cut "$(jq -r '.name' <<< "$f")" 200)")
  printf '%s. **%s** · `%s` · 置信度 %s\n' "$n" "$name" "$(jq -r '.riskType' <<< "$f")" "$(jq -r '.confidence' <<< "$f")"
  while IFS= read -r loc; do
    path=$(_review_meta_cell "$(jq -r '.path' <<< "$loc")")
    start=$(jq -r '.start // ""' <<< "$loc"); end=$(jq -r '.end // ""' <<< "$loc")
    if [[ -n "$start" && -n "$end" && "$start" != "$end" ]]; then range=":${start}–${end}"
    elif [[ -n "$start" ]]; then range=":${start}"
    else range=""; fi
    known=$(jq -r '.known' <<< "$loc")
    label=$(jq -r '.label' <<< "$loc")
    printf '   - `%s%s`%s%s\n' "$path" "$range" "$([[ "$known" == true ]] || printf '（路径未能对应）')" \
      "${label:+ — $(_review_sanitize_oneline "$(_sa_cut "$label" "$SA_LABEL_MAX")")}"
  done < <(jq -c '.locations[]' <<< "$f")
  desc=$(jq -r '.description' <<< "$f")
  [[ -n "$desc" ]] && printf '   %s\n' "$(_review_sanitize_oneline "$(_sa_cut "$desc" "$SA_DESC_MAX")")"
  return 0
}

# 元信息表（四列，第四列是「差分」）
_sa_render_meta() {  # <第四格>
  echo "| Commit | 分支 | 时间 | ${REVIEW_META_NOTE_HEADER} |"
  echo "|---|---|---|---|"
  echo "| \`${SHORT_SHA}\` | \`$(_review_meta_cell "$CI_COMMIT_REF_NAME")\` → \`$(_review_meta_cell "${MR_TARGET_BRANCH:-?}")\` | $(date '+%Y-%m-%d %H:%M:%S') | $1 |"
}

# 汇总评论：<报告 JSON> <meta.json> <作业 id> <overview 文件（可为空串）> → stdout
security_render_summary() {
  local report="$1" meta="$2" job="$3" ovf="$4" hist total lvl n f i counts note head_f head_bytes tail_f max budget used shown cur \
        chunk bytes
  hist=$(mktemp)
  read -r -a counts < <(sa_history_counts "$report")
  review_history_append "${PRIOR_HISTORY_FILE:--}" "$REVIEW_RUN" "$SHORT_SHA" "" "" "${counts[0]}" "${counts[1]}" "${counts[2]}" \
    > "$hist" || return 2
  head_f=$(mktemp)
  {  # 评论头部到结论（先写进文件：发现的字节预算要扣掉它的长度）
  review_render_comment_head "$REVIEW_TITLE" "$SHORT_SHA" "$REVIEW_RUN" "$hist"
  echo ""
  note="$(jq -r '.diff_files' "$meta") 个文件 · 归档 $(jq -r '.files' "$meta") 个文件"
  [[ "$(jq -r '.symlinks' "$meta")" != 0 ]] && note+="（剔除 $(jq -r '.symlinks' "$meta") 个符号链接）"
  note+=" · 作业 \`$(_review_meta_cell "$job")\`"
  _sa_render_meta "$note"
  echo ""
  echo "> ${SA_NONDETERMINISM_NOTE}"
  echo ""
  echo "## 结论"
  echo ""
  total=$(jq '.findings | length' "$report")
  if [[ "$total" == 0 ]]; then
    printf '未发现安全问题（差分扫描 · 提交 `%s`）。\n' "$SHORT_SHA"
  else
    printf '差分扫描发现 %s 个安全问题（%s）。\n' "$total" \
      "$(jq -r '.counts | "CRITICAL \(.CRITICAL) · HIGH \(.HIGH) · MEDIUM \(.MEDIUM) · LOW \(.LOW) · 其它 \(.INFORMATIONAL + .UNKNOWN)"' "$report")"
  fi
  if [[ "$(jq '.returned' "$report")" -ge "$SA_SERVICE_CAP" ]]; then
    echo ""
    printf '本次返回 %s 条，达到服务上限（每次差分扫描最多 %s 条），可能还有未报出的问题。\n' "$(jq '.returned' "$report")" "$SA_SERVICE_CAP"
  fi
  if [[ "$(jq '.false_positives' "$report")" != 0 ]]; then
    echo ""
    printf '另有 %s 条被 Security Agent 判为误报，未列出。\n' "$(jq '.false_positives' "$report")"
  fi
  if [[ "$(jq '.unmatched' "$report")" != 0 ]]; then
    echo ""
    printf '有 %s 个位置不在本次归档里（标「路径未能对应」）。\n' "$(jq '.unmatched' "$report")"
  fi
  } > "$head_f"
  head_bytes=$(wc -c < "$head_f" | tr -d ' ')
  cat "$head_f"; rm -f "$head_f"
  # 评论尾部（总结折叠区、历次表、页脚）先渲染好：发现要按它剩下的字节预算来排
  tail_f=$(mktemp)
  {
    if [[ -n "$ovf" && -s "$ovf" ]]; then
      echo ""
      echo "<details><summary>Security Agent 的总结</summary>"
      echo ""
      jq -Rrs --argjson m "$SA_OVERVIEW_MAX" 'if length > $m then .[0:$m] + "…" else . end' "$ovf" | review_sanitize_md
      echo ""
      echo "</details>"
    fi
    echo ""
    review_render_history_table "$hist"
    echo ""
    review_render_footer "$REVIEW_RUN"
  } > "$tail_f"
  rm -f "$hist"
  if [[ "$total" != 0 ]]; then
    echo ""
    echo "## 发现"
    # 发现按字节预算渲染（终审 I-7）：截断上限按码点算，中文说明换成字节翻三倍，30 条长发现能远超 MAX_COMMENT_BYTES；那时尾部截断会
    # 砍掉历次表与页脚。预算 = 上限 − 已输出的头部 − 尾部 − 余量（「## 发现」、折叠行、发布时加的标记）。放不下的（排在最后、最不严重的）
    # 折成一行计数；完整列表在扫描任务日志里（security.sh 记下 report）。
    max="${MAX_COMMENT_BYTES:-60000}"; [[ "$max" =~ ^[0-9]{1,9}$ ]] || max=60000
    budget=$(( max - head_bytes - $(wc -c < "$tail_f") - 600 ))
    used=0; shown=0; cur=""; i=0
    while IFS= read -r f; do
      lvl=$(jq -r '.riskLevel' <<< "$f"); chunk=""
      if [[ "$lvl" != "$cur" ]]; then
        n=$(jq --arg l "$lvl" '[.findings[] | select(.riskLevel == $l)] | length' "$report")
        chunk=$'\n'"**${lvl}（${n}）**"$'\n\n'; i=0
      fi
      chunk+="$(_sa_render_finding "$((i + 1))" "$f")"$'\n'
      bytes=$(printf '%s' "$chunk" | wc -c | tr -d ' ')
      (( used + bytes <= budget )) || break
      printf '%s' "$chunk"; used=$((used + bytes)); shown=$((shown + 1)); cur="$lvl"; i=$((i + 1))
    done < <(jq -c '.findings[]' "$report")
    if (( shown < total )); then
      echo ""
      printf '另有 %s 条发现因评论长度上限（%s 字节）未展开（按严重级别排在最后的先省略），完整列表见扫描任务日志里本次作业的 report 一行。\n' \
        "$((total - shown))" "$max"
    fi
  fi
  cat "$tail_f"
  rm -f "$tail_f"
}

# 输入状态 skipped:<代号> → 说明汇总（不起作业；spec「Task A」SA 一项：Task B 照常发一条说明）
security_render_skipped() {  # <代号>
  local code="$1" hist reason
  case "$code" in
    empty-diff)        reason="MR 相对目标分支没有改动（空 diff），没有可扫描的内容" ;;
    diff-too-large)    reason="改动超过 Security Agent 差分扫描的上限（3,000 个文件或 5 MB）" ;;
    archive-too-large) reason="仓库归档超过 Security Agent 的上限（2 GB）" ;;
    *)                 reason="代号 $(_review_meta_cell "$code")" ;;
  esac
  hist=$(mktemp)
  review_history_append "${PRIOR_HISTORY_FILE:--}" "$REVIEW_RUN" "$SHORT_SHA" "" "" - - - > "$hist" || return 2
  review_render_comment_head "$REVIEW_TITLE" "$SHORT_SHA" "$REVIEW_RUN" "$hist"
  echo ""
  _sa_render_meta "未扫描"
  echo ""
  echo "## 结论"
  echo ""
  printf '本次没有执行差分扫描：%s。\n' "$reason"
  echo ""
  review_render_history_table "$hist"
  rm -f "$hist"
  echo ""
  review_render_footer "$REVIEW_RUN"
}
