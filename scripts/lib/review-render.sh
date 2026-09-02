#!/usr/bin/env bash
# 评审报告的提取、校验与渲染。
#
# 数据流：kiro-cli（--agent-engine v2 --output-format stream-json）的 JSON Lines
#   → review_stream_final_text  取 runFinished.data.finalText（Kiro 失败在这一步识别）
#   → review_extract_json       取 <<<KIRO_REVIEW_JSON>>> 标记内的契约 JSON
#   → review_validate           丢弃不合契约的问题并计数，规范化字段
#   → review_render_summary     渲染汇总评论（Markdown）
# 任一提取步骤失败 → review_render_degraded 渲染「结构化解析失败」评论（评审仍算产出）。
#
# 事件形态以实测为准（kiro-cli 2.21.0，spec §4.7.1 P1-08，原始输出见
# .scratch/codeup-kiro-v2/probe-results/kiro-headless/*/out.jsonl，裁剪样例见
# tests/fixtures/stream/real-shape.jsonl）：
#   runStarted   {data:{payloadSchema,acpProtocolVersion,engine}}
#   sessionUpdate{data:{sessionId,update:{sessionUpdate:"agent_message_chunk"|"tool_call"|"tool_call_update",...}}}
#   metadata     {data:{sessionId,contextUsagePercentage,meteringUsage?:[{value,unit}],turnDurationMs?}}
#   runFinished  {data:{sessionId,status,stopReason,finalText,finalTextTruncated}}
# finalText 就是完整最终消息，无需拼接 agent_message_chunk。
#
# 渲染是纯函数：sha / 分支 / 时间戳 / diff 说明 / 评审次数全部由参数传入，没有隐式输入
# （不读 date、不读 git），因此可以用 golden file 逐字节比对（tests/test-review-render.sh）。

# 严重级别的中文标签与排序权重。级别词汇以 CONTEXT.md 为准：P0 必须修复 / P1 应当修复 / P2 可选改进。
REVIEW_SEVERITIES="P0 P1 P2"

# --- 文本清洗：剥离 ANSI 控制序列（stdin → stdout）---
# stream-json 的 stdout 实测不含 ANSI，但降级路径要贴的是模型原文，且纯文本回退路径仍需清洗，
# 所以清洗放在公共函数里，两条路径都过一遍。
review_clean_text() {
  local esc
  esc=$(printf '\033')
  sed "s/${esc}\\[[0-9;?]*[a-zA-Z]//g"
}

# --- 从 JSON Lines 事件流取最终消息 ---
# 用法：review_stream_final_text <jsonl 文件>
#   rc 0 → stdout = finalText
#   rc 2 → 没有 runFinished 事件（Kiro 未跑完：视为 Kiro 失败）
#   rc 3 → runFinished.data.status 非 success；stdout = status 值（供失败评论写明原因）
#   rc 6 → 文件不可读
# 用 `jq -R 'fromjson?'` 逐行解析：stdout 里混进 CLI 的非 JSON 警告行时跳过该行，而不是整体失败。
review_stream_final_text() {
  local jsonl="$1" rf status
  [[ -r "$jsonl" ]] || { echo "review_stream_final_text: 事件流文件不可读：${jsonl}" >&2; return 6; }
  rf=$(jq -c -R 'fromjson? | select(type == "object" and .type == "runFinished")' "$jsonl" 2>/dev/null | tail -1)
  [[ -n "$rf" ]] || return 2
  status=$(printf '%s' "$rf" | jq -r '.data.status // ""')
  if [[ "$status" != "success" ]]; then
    printf '%s\n' "${status:-<runFinished 无 status 字段>}"
    return 3
  fi
  printf '%s' "$rf" | jq -r '.data.finalText // ""'
}

# --- 成本与上下文可观测指标（写流水线日志；spec §4.1「metadata.meteringUsage 写入日志」）---
# 用法：review_stream_usage <jsonl 文件> → stdout "credits=0.2609 context=3.8%"
# credits 累加所有 metadata 事件里 unit=credit 的 value（实测一次评审会分多笔计量）；
# context 取最后一个 contextUsagePercentage。缺数据时对应字段为 -，永不失败（日志不该拖垮评审）。
review_stream_usage() {
  local jsonl="$1" credits ctx
  if [[ ! -r "$jsonl" ]]; then printf 'credits=- context=-\n'; return 0; fi
  credits=$(jq -R 'fromjson? | select(type == "object" and .type == "metadata")
                   | .data.meteringUsage // empty | .[] | select(.unit == "credit") | .value' \
              "$jsonl" 2>/dev/null | awk '{s += $1; n++} END {if (n) printf "%.4f", s; else printf "-"}')
  ctx=$(jq -r -R 'fromjson? | select(type == "object" and .type == "metadata")
                  | .data.contextUsagePercentage // empty' "$jsonl" 2>/dev/null \
        | tail -1 | awk 'NF {printf "%.1f%%", $1; f = 1} END {if (!f) printf "-"}')
  printf 'credits=%s context=%s\n' "${credits:--}" "${ctx:--}"
}

# --- 从最终消息里截出标记包裹的那段 JSON（stdin → stdout）---
# 取「最后一个起始标记」到「其后第一个结束标记」之间的内容：模型有时先复述一遍格式示例再给真结果，
# 取最后一组才拿到真结果。整段缓冲后按字符定位，因此标记与 JSON 同行也能截取。
# rc 1 = 没有成对标记。
_review_slice_marker() {
  awk -v S='<<<KIRO_REVIEW_JSON>>>' -v E='<<<END_KIRO_REVIEW_JSON>>>' '
    { buf = buf $0 "\n" }
    END {
      last = 0
      while ((p = index(substr(buf, last + 1), S)) > 0) last = last + p
      if (last == 0) exit 1
      rest = substr(buf, last + length(S))
      q = index(rest, E)
      if (q == 0) exit 1
      printf "%s", substr(rest, 1, q - 1)
    }'
}

# --- 提取契约 JSON ---
# 用法：review_extract_json <jsonl 文件>
#   rc 0 → stdout = 契约 JSON（compact）
#   rc 2/3 → 透传 review_stream_final_text：Kiro 失败，调用方走失败评论路径（不是降级）
#   rc 4 → 没有成对的契约标记 → 降级
#   rc 5 → 标记内不是合法 JSON 对象 → 降级
review_extract_json() {
  local jsonl="$1" final slice rc=0
  final=$(review_stream_final_text "$jsonl") || rc=$?
  if [[ "$rc" != "0" ]]; then
    # rc 3 时 review_stream_final_text 把 status 值写在 stdout；透传给调用方，让失败评论能写明原因
    [[ "$rc" == "3" ]] && printf '%s\n' "$final"
    return "$rc"
  fi
  slice=$(printf '%s\n' "$final" | review_clean_text | _review_slice_marker) || return 4
  printf '%s' "$slice" | jq -e 'type == "object"' >/dev/null 2>&1 || return 5
  printf '%s' "$slice" | jq -c .
}

# --- 契约校验（stdin = 契约 JSON → stdout = 规范化 JSON）---
# 规范化后的形态：{summary, verdict, verdict_reason, findings:[…], dropped_findings:N}
# 丢弃规则（spec §4.1「字段校验失败的 finding 丢弃并计数」）：
#   - 不是 JSON 对象
#   - severity 规范化（去首尾空白 + 大写）后不是 P0/P1/P2
#   - title 或 body 去空白后为空（缺字段同样算空）
# 保留但置空的情形：file 为空/非字符串 → null（仓库级意见）；line_start/line_end 不是 ≥1 的整数 → null。
# file 为 null 时行号一并置 null（没有文件的行号无意义）；line_end 缺失或小于 line_start 时取 line_start。
# body/fix 原样保留（不做 trim）：它们是 Markdown，可能以缩进代码块开头，裁掉缩进会破坏渲染。
# dropped_findings 直接写进输出 JSON 而不是回传全局变量：调用方普遍用 $(…) 取结果，
# 命令替换在子 shell 里跑，全局变量传不回来（codeup-api.sh 里踩过同一个坑）。
# rc 1 = 顶层不是对象 / findings 不是数组 / 不是合法 JSON（调用方走降级）。
review_validate() {
  local input
  input=$(cat)
  printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { echo "review_validate: 契约不是 JSON 对象" >&2; return 1; }
  printf '%s' "$input" | jq -e '(.findings // []) | type == "array"' >/dev/null 2>&1 \
    || { echo "review_validate: 契约的 findings 不是数组" >&2; return 1; }
  printf '%s' "$input" | jq -c '
    # \A / \z 是显式的「字符串首/尾」锚点：jq 的 ^ / $ 在不同版本可能被当行锚点，
    # 那会连多行字符串里每一行的缩进都裁掉。
    def tr(v): if (v | type) == "string"
               then (v | gsub("\\A[[:space:]]+"; "") | gsub("[[:space:]]+\\z"; ""))
               else "" end;
    def lineno(v): if (v | type) == "number" and (v | floor) == v and v >= 1 then (v | floor) else null end;
    def fpath(v): (tr(v)) as $t | if ($t | length) > 0 then $t else null end;
    . as $root
    | ((.findings // []) | length) as $total
    | [ (.findings // [])[]
        | select(type == "object")
        | (tr(.severity) | ascii_upcase) as $sev
        | (tr(.title)) as $title
        | select(($sev == "P0" or $sev == "P1" or $sev == "P2")
                 and ($title | length) > 0
                 and ((tr(.body)) | length) > 0)
        | fpath(.file) as $file
        | (if $file == null then null else lineno(.line_start) end) as $ls
        | (if $ls == null then null
           else (lineno(.line_end)) as $le | (if $le == null or $le < $ls then $ls else $le end) end) as $le
        | { id: (tr(.id)), severity: $sev, category: (tr(.category)), title: $title,
            file: $file, line_start: $ls, line_end: $le,
            body: (if (.body | type) == "string" then .body else "" end),
            fix: (if (.fix | type) == "string" then .fix else "" end) }
      ] as $kept
    | { summary: (tr($root.summary)),
        verdict: (tr($root.verdict) | ascii_upcase),
        verdict_reason: (tr($root.verdict_reason)),
        findings: $kept,
        dropped_findings: ($total - ($kept | length)) }'
}

# --- 内部：总体结论的中文化（CONTEXT.md 的「总体结论」词汇）---
_review_verdict_cn() {
  case "$1" in
    MERGE) echo "可合并" ;;
    MERGE_AFTER_FIX) echo "建议修改后合并" ;;
    DO_NOT_MERGE) echo "不建议合并" ;;
    "") echo "评审员未给出结论" ;;
    # 契约外的值原样带出：宁可评论上难看，也不能把评审员的结论静默改写成别的意思
    *) echo "$1（非契约取值）" ;;
  esac
}

# --- 内部：参数解析（两个渲染函数共用）---
# 解析结果写入 _RR_* 变量；未知参数或缺值 → rc 2（拼错参数不能静默按默认值渲染）。
_review_parse_render_args() {
  _RR_JSON=""; _RR_TEXT=""; _RR_SHA=""; _RR_SRC=""; _RR_DST=""; _RR_TS=""
  _RR_DIFF_NOTE=""; _RR_RUN=1; _RR_INLINE=0; _RR_REASON=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json|--text|--sha|--src|--dst|--ts|--diff-note|--run|--inline-comment|--reason)
        [[ $# -ge 2 ]] || { echo "review 渲染：参数 $1 缺少取值" >&2; return 2; }
        case "$1" in
          --json) _RR_JSON="$2" ;;
          --text) _RR_TEXT="$2" ;;
          --sha) _RR_SHA="$2" ;;
          --src) _RR_SRC="$2" ;;
          --dst) _RR_DST="$2" ;;
          --ts) _RR_TS="$2" ;;
          --diff-note) _RR_DIFF_NOTE="$2" ;;
          --run) _RR_RUN="$2" ;;
          --inline-comment) _RR_INLINE="$2" ;;
          --reason) _RR_REASON="$2" ;;
        esac
        shift 2 ;;
      *) echo "review 渲染：未知参数：$1" >&2; return 2 ;;
    esac
  done
  local v
  for v in _RR_SHA _RR_SRC _RR_DST _RR_TS _RR_DIFF_NOTE; do
    [[ -n "${!v}" ]] || { echo "review 渲染：缺少必填参数 --$(echo "${v#_RR_}" | tr 'A-Z_' 'a-z-')" >&2; return 2; }
  done
  [[ "$_RR_RUN" =~ ^[0-9]+$ && "$_RR_RUN" -ge 1 ]] || { echo "review 渲染：--run 必须是 ≥1 的整数（实际：${_RR_RUN}）" >&2; return 2; }
}

# --- 内部：评论头（标题 + 评审标记 + 元信息表）---
_review_render_header() {
  local title="$1"
  echo "$title"
  echo "<!-- kiro-review:${_RR_SHA} run:${_RR_RUN} -->"
  echo ""
  echo "| Commit | 分支 | 时间 | diff |"
  echo "|---|---|---|---|"
  echo "| \`${_RR_SHA}\` | \`${_RR_SRC}\` → \`${_RR_DST}\` | ${_RR_TS} | ${_RR_DIFF_NOTE} |"
}

# --- 内部：页脚（图例 + 重新评审提示）---
_review_render_footer() {
  echo "---"
  echo "第 ${_RR_RUN} 次评审 · P0 必须修复 · P1 应当修复 · P2 可选改进 · 评论 \`/kiro review\` 可重新评审"
}

# --- 汇总评论（INLINE_COMMENT=0）---
# 用法：review_render_summary --json <规范化后的契约 JSON 文件> --sha X --src A --dst B \
#                            --ts "YYYY-mm-dd HH:MM:SS" --diff-note N [--run 1] [--inline-comment 0]
# INLINE_COMMENT=0 的形态（spec §4.3 的 0 变体）：问题清单**完整展开**、不用折叠区、不提行内计数，
# 观感对齐 v1。--inline-comment 1 的渲染（折叠区、行内计数、历次评审表）属票 04，这里显式拒绝，
# 避免把 1 静默当 0 渲染、让开关看起来生效了。
review_render_summary() {
  _review_parse_render_args "$@" || return $?
  [[ -n "$_RR_JSON" ]] || { echo "review_render_summary: 缺少必填参数 --json" >&2; return 2; }
  [[ -r "$_RR_JSON" ]] || { echo "review_render_summary: 契约 JSON 不可读：${_RR_JSON}" >&2; return 2; }
  if [[ "$_RR_INLINE" != "0" ]]; then
    echo "review_render_summary: --inline-comment=${_RR_INLINE} 的渲染（行内评论 + 折叠区）属票 04，本票只实现 0" >&2
    return 3
  fi

  local summary verdict verdict_cn verdict_reason dropped n0 n1 n2 total
  summary=$(jq -r '.summary' "$_RR_JSON")
  verdict=$(jq -r '.verdict' "$_RR_JSON")
  verdict_reason=$(jq -r '.verdict_reason' "$_RR_JSON")
  dropped=$(jq -r '.dropped_findings' "$_RR_JSON")
  total=$(jq -r '.findings | length' "$_RR_JSON")
  n0=$(jq -r '[.findings[] | select(.severity == "P0")] | length' "$_RR_JSON")
  n1=$(jq -r '[.findings[] | select(.severity == "P1")] | length' "$_RR_JSON")
  n2=$(jq -r '[.findings[] | select(.severity == "P2")] | length' "$_RR_JSON")
  verdict_cn=$(_review_verdict_cn "$verdict")

  _review_render_header "## 🤖 Kiro 代码评审"
  echo ""
  echo "### 变更摘要"
  echo ""
  if [[ -n "$summary" ]]; then echo "$summary"; else echo "（评审员未给出变更摘要）"; fi
  echo ""
  echo "### 结论：${verdict_cn}"
  echo ""
  if [[ -n "$verdict_reason" ]]; then echo "$verdict_reason"; else echo "（评审员未给出结论理由）"; fi
  echo ""
  echo "### 问题统计"
  echo ""
  if [[ "$dropped" -gt 0 ]]; then
    echo "P0 ${n0} · P1 ${n1} · P2 ${n2}（另有 ${dropped} 条不合契约已丢弃）"
  else
    echo "P0 ${n0} · P1 ${n1} · P2 ${n2}"
  fi

  # 重点关注文件：按 P0→P1→P2 计数降序、同计数按路径升序，最多 10 行；无可归属文件时整节省略。
  if [[ "$(jq -r '[.findings[] | select(.file != null)] | length' "$_RR_JSON")" -gt 0 ]]; then
    echo ""
    echo "### 重点关注文件"
    echo ""
    echo "| 文件 | P0 | P1 | P2 |"
    echo "|---|---|---|---|"
    jq -r '
      [.findings[] | select(.file != null)]
      | group_by(.file)
      | map({ file: .[0].file,
              p0: ([.[] | select(.severity == "P0")] | length),
              p1: ([.[] | select(.severity == "P1")] | length),
              p2: ([.[] | select(.severity == "P2")] | length) })
      | sort_by(.file) | sort_by([-.p0, -.p1, -.p2])
      | .[0:10][]
      | "| `\(.file)` | \(.p0) | \(.p1) | \(.p2) |"' "$_RR_JSON"
  fi

  echo ""
  echo "### 问题清单"
  if [[ "$total" == "0" ]]; then
    echo ""
    echo "未发现明显问题。"
  else
    # 分组与编号都在 jq 里做，保证同一输入逐字节一致：
    # 组内先按原始次序编号（to_entries 固定索引），再按 文件 → 起始行 → 原始次序 排序。
    jq -r --arg sevs "$REVIEW_SEVERITIES" '
      def loc:
        if .file == null then "（未定位）"
        elif .line_start == null then "`\(.file)`"
        elif .line_end > .line_start then "`\(.file):\(.line_start)-\(.line_end)`"
        else "`\(.file):\(.line_start)`" end;
      def sevlabel: { "P0": "P0 必须修复", "P1": "P1 应当修复", "P2": "P2 可选改进" }[.] // .;
      (.findings | to_entries | map(.value + {idx: .key})) as $all
      | ($sevs | split(" "))[] as $sev
      | [$all[] | select(.severity == $sev)] as $grp
      | select(($grp | length) > 0)
      | "\n#### \($sev | sevlabel)（\($grp | length)）",
        ( $grp
          | sort_by([(.file == null), (.file // ""), (.line_start // 0), .idx])
          | to_entries[]
          | .value as $f
          | "\n##### \(.key + 1). \($f | loc) — \($f.title)\n\n\($f.body)"
            + (if ($f.fix | length) > 0 then "\n\n**修复建议**\n\n\($f.fix)" else "" end) )' "$_RR_JSON"
  fi
  echo ""
  _review_render_footer
}

# --- 降级评论：结构化解析失败时贴出评审员原文 ---
# 用法：review_render_degraded --text <清洗后的原文文件> --sha X --src A --dst B --ts T --diff-note N \
#                             [--run 1] [--reason 原因]
# 标题含「结构化解析失败」（票 02 验收项），正文是原文全文——原文里的疑似密钥掩码由评审员按
# agent 提示词的掩码规则完成，这里不二次改写（改写会破坏代码块，也会给出"已脱敏"的假保证）。
review_render_degraded() {
  _review_parse_render_args "$@" || return $?
  [[ -n "$_RR_TEXT" ]] || { echo "review_render_degraded: 缺少必填参数 --text" >&2; return 2; }
  [[ -r "$_RR_TEXT" ]] || { echo "review_render_degraded: 原文文件不可读：${_RR_TEXT}" >&2; return 2; }
  _review_render_header "## 🤖 Kiro 代码评审 · ⚠️ 结构化解析失败"
  echo ""
  echo "> ⚠️ 评审已完成，但输出不符合结构化契约（${_RR_REASON:-未说明原因}），无法给出分级问题清单与统计。"
  echo "> 下面是评审员输出的原文；重跑评审（评论 \`/kiro review\`）通常可恢复结构化输出。"
  echo ""
  echo "---"
  echo ""
  cat "$_RR_TEXT"
  echo ""
  _review_render_footer
}
