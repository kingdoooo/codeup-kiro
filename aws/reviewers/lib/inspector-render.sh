#!/usr/bin/env bash
# Inspector 汇总评论的渲染（Phase 2b spec「Inspector 评审员」，R3：「本 MR 引入」为主 + 存量折叠；API 性质决定只有汇总、没有行内）。
# 评论头、历次表、页脚出自 scripts/lib/review-render.sh 的同一份代码（档案 = inspector）；漏洞内容来自 SBOM 与 Inspector 的输出——
# 包名、版本、路径、说明都是不受信文本（SBOM 由不受信的业务库派生），只经两个既有的清洗函数进评论：
#   _review_meta_cell（code span 里的单元格：去掉 `<>|`、反引号、反斜杠与控制字符）与 _review_sanitize_oneline（结构清洗 + 折成单行）。
# 这两个是 review-render.sh 的内部函数；tests/test-inspector.sh 的注入用例守着「它们换了行为时这里不会悄悄放行」。
# 调用方先 source 渲染库，并设好 SHORT_SHA、REVIEW_RUN、PRIOR_HISTORY_FILE、CI_COMMIT_REF_NAME、MR_TARGET_BRANCH。

INSPECTOR_EXISTING_SHOWN=10      # 折叠区里列出的存量漏洞条数（其余只计数）
INSPECTOR_DESC_MAX=300           # 每条说明的字符上限（按码点，jq 里截）

_insp_sev_label() { case "$1" in critical) echo CRITICAL ;; high) echo HIGH ;; medium) echo MEDIUM ;; low) echo LOW ;; *) echo 其它 ;; esac; }

# 一条漏洞（compact JSON）→ 一段 Markdown
_insp_render_vuln() {  # <序号> <漏洞 JSON>
  local n="$1" v="$2" id badges comp line desc adv
  id=$(_review_meta_cell "$(jq -r '.id' <<< "$v")")
  badges=$(jq -r '[(if .kev then "CISA KEV" else empty end), (if .exploit then "有公开利用" else empty end),
                   (if .malicious then "恶意包" else empty end),
                   (if (.epss | type) == "number" then "EPSS \(.epss)" else empty end)] | join(" · ")' <<< "$v")
  printf '%s. **`%s`**%s\n' "$n" "$id" "${badges:+ · ${badges}}"
  while IFS= read -r comp; do
    line="   - \`$(_review_meta_cell "$(jq -r '"\(.name)@\(.version)"' <<< "$comp")")\`"
    [[ -n "$(jq -r '.fixed' <<< "$comp")" ]] && line+=" → 修复版本 \`$(_review_meta_cell "$(jq -r '.fixed' <<< "$comp")")\`"
    [[ -n "$(jq -r '.path' <<< "$comp")" ]] && line+=" · 清单 \`$(_review_meta_cell "$(jq -r '.path' <<< "$comp")")\`"
    printf '%s\n' "$line"
  done < <(jq -c '.components[]' <<< "$v")
  desc=$(jq -r --argjson m "$INSPECTOR_DESC_MAX" '.description | if length > $m then .[0:$m] + "…" else . end' <<< "$v")
  [[ -n "$desc" ]] && printf '   %s\n' "$(_review_sanitize_oneline "$desc")"
  adv=$(jq -r '.advisory' <<< "$v")
  # 公告链接只认 https://，其余（javascript:、带空白或尖括号的）一律不渲染
  if [[ "$adv" =~ ^https://[A-Za-z0-9./?=_%:#~+-]+$ ]]; then printf '   %s\n' "$adv"; fi
}

# 汇总评论：<报告 JSON> <head 组件数> <base 组件数> <调用次数> <被丢下的存量组件数> → stdout
inspector_render_summary() {
  local report="$1" nhead="$2" nbase="$3" calls="$4" dropped="$5" hist ts intro_total exist_total n v sev
  hist=$(mktemp)
  # 历次表的三个计数槽（档案 inspector 的表头「引入 高/中/低」）：critical+high / medium / low+其它，只数本 MR 引入的
  review_history_append "${PRIOR_HISTORY_FILE:--}" "$REVIEW_RUN" "$SHORT_SHA" "" "" \
    "$(jq '.counts.introduced | .critical + .high' "$report")" "$(jq '.counts.introduced.medium' "$report")" \
    "$(jq '.counts.introduced | .low + .other' "$report")" > "$hist" || return 2
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  review_render_comment_head "$REVIEW_TITLE" "$SHORT_SHA" "$REVIEW_RUN" "$hist"
  echo ""
  echo "| Commit | 分支 | 时间 | ${REVIEW_META_NOTE_HEADER} |"
  echo "|---|---|---|---|"
  echo "| \`${SHORT_SHA}\` | \`$(_review_meta_cell "$CI_COMMIT_REF_NAME")\` → \`$(_review_meta_cell "${MR_TARGET_BRANCH:-?}")\` | ${ts} | head ${nhead} / base ${nbase} · ScanSbom ${calls} 次 |"
  echo ""
  intro_total=$(jq '[.counts.introduced[]] | add' "$report"); exist_total=$(jq '[.counts.existing[]] | add' "$report")
  echo "## 结论"
  echo ""
  if [[ "$intro_total" == 0 ]]; then
    echo "本 MR 未引入新的依赖漏洞。"
  else
    printf '本 MR 引入 %s 个依赖漏洞（%s）。\n' "$intro_total" \
      "$(jq -r '.counts.introduced | "critical \(.critical) · high \(.high) · medium \(.medium) · low \(.low) · 其它 \(.other)"' "$report")"
    echo ""
    echo "## 本 MR 引入的漏洞"
    for sev in critical high medium low other; do
      n=$(jq --arg s "$sev" '[.vulns[] | select(.introduced) | select((if .rank < 4 then .severity else "other" end) == $s)] | length' "$report")
      [[ "$n" == 0 ]] && continue
      echo ""
      printf '**%s（%s）**\n\n' "$(_insp_sev_label "$sev")" "$n"
      local i=0
      while IFS= read -r v; do
        i=$((i + 1)); _insp_render_vuln "$i" "$v"
      done < <(jq -c --arg s "$sev" '.vulns[] | select(.introduced) | select((if .rank < 4 then .severity else "other" end) == $s)' "$report")
    done
  fi
  echo ""
  printf '<details><summary>存量依赖漏洞（%s，不是本 MR 引入的）</summary>\n\n' "$exist_total"
  printf '%s\n' "$(jq -r '.counts.existing | "critical \(.critical) · high \(.high) · medium \(.medium) · low \(.low) · 其它 \(.other)"' "$report")"
  if [[ "$exist_total" != 0 ]]; then
    echo ""
    local i=0
    while IFS= read -r v; do
      i=$((i + 1)); _insp_render_vuln "$i" "$v"
    done < <(jq -c --argjson k "$INSPECTOR_EXISTING_SHOWN" '[.vulns[] | select(.introduced | not)][0:$k][]' "$report")
    (( exist_total > INSPECTOR_EXISTING_SHOWN )) && printf '\n其余 %s 条只计数、不列出。\n' "$((exist_total - INSPECTOR_EXISTING_SHOWN))"
  fi
  if [[ "$dropped" != 0 ]]; then
    printf '\n存量只扫了一部分：%s 个组件超出本次调用上限（inspector_max_scan_calls）没有送检。本 MR 引入的组件总是全部送检。\n' "$dropped"
  fi
  echo ""
  echo "</details>"
  echo ""
  review_render_history_table "$hist"
  rm -f "$hist"
  echo ""
  review_render_footer "$REVIEW_RUN"
}
