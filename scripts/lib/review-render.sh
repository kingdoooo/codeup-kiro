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
              "$jsonl" 2>/dev/null | LC_ALL=C awk '{s += $1; n++} END {if (n) printf "%.4f", s; else printf "-"}')
  ctx=$(jq -r -R 'fromjson? | select(type == "object" and .type == "metadata")
                  | .data.contextUsagePercentage // empty' "$jsonl" 2>/dev/null \
        | tail -1 | LC_ALL=C awk 'NF {printf "%.1f%%", $1; f = 1} END {if (!f) printf "-"}')
  printf 'credits=%s context=%s\n' "${credits:--}" "${ctx:--}"
}

# --- 最终消息是否被 kiro-cli 自己截断（runFinished.data.finalTextTruncated）---
# 用法：review_stream_final_truncated <jsonl 文件> → rc 0 = 被截断；rc 1 = 未截断或读不到。
# 截断会让契约 JSON 缺尾巴，表现成「没有结束标记」或「JSON 非法」。不读这个字段的话，
# 降级评论会把 Kiro 自己的截断说成模型不守契约，运维只会一遍遍重跑同一个必然失败的评审。
review_stream_final_truncated() {
  local jsonl="$1" v
  [[ -r "$jsonl" ]] || return 1
  v=$(jq -r -R 'fromjson? | select(type == "object" and .type == "runFinished")
                | .data.finalTextTruncated // false' "$jsonl" 2>/dev/null | tail -1)
  [[ "$v" == "true" ]]
}

# --- 从最终消息里截出标记包裹的那段 JSON（stdin → stdout）---
# 安全要求：业务库内容不受信，而 agent 提示词要求评审员把注入企图作为 P0 报告出来——也就是说
# **被评审代码里的假契约块很可能被评审员原文引用到最终消息里**。此时输出中会出现两对标记，
# 无法从文本本身判断哪一段是评审员的结论。取「最后一对」会让伪造块直接顶掉真结论
# （伪造 `verdict: MERGE / findings: []` 就能把「不建议合并」变成「可合并」）；取「第一对」同样可被
# 先引用后作答的顺序绕过。因此：**标记不唯一就拒绝解析**，交给降级路径贴出原文，让人来看。
# rc 1 = 没有成对标记；rc 2 = 标记出现多于一对（起始或结束标记计数 != 1）。
_review_slice_marker() {
  awk -v S='<<<KIRO_REVIEW_JSON>>>' -v E='<<<END_KIRO_REVIEW_JSON>>>' '
    # 统计 hay 中 needle 出现的次数
    function count(hay, needle,   c, p) {
      c = 0
      while ((p = index(hay, needle)) > 0) { c++; hay = substr(hay, p + length(needle)) }
      return c
    }
    { buf = buf $0 "\n" }
    END {
      ns = count(buf, S); ne = count(buf, E)
      if (ns == 0 || ne == 0) exit 1
      if (ns > 1 || ne > 1) exit 2
      start = index(buf, S)
      rest = substr(buf, start + length(S))
      q = index(rest, E)
      if (q == 0) exit 1
      printf "%s", substr(rest, 1, q - 1)
    }'
}

# --- 去掉契约 JSON 外面可能包着的 Markdown 代码围栏（stdin → stdout）---
# 模型很容易把 JSON 放进 ```json 围栏里（提示词里的 schema 本身就是围栏形式）。
# 围栏不是契约的一部分，但它会让 jq 解析失败、把每一次评审都推进降级路径，所以这里宽容处理。
_review_strip_code_fence() {
  awk '
    { line[NR] = $0 }
    END {
      first = 1; last = NR
      while (first <= last && line[first] ~ /^[[:space:]]*$/) first++
      while (last >= first && line[last] ~ /^[[:space:]]*$/) last--
      if (first <= last && line[first] ~ /^[[:space:]]*```/ && line[last] ~ /^[[:space:]]*```[[:space:]]*$/) {
        first++; last--
      }
      for (i = first; i <= last; i++) print line[i]
    }'
}

# --- 提取契约 JSON ---
# 用法：review_extract_json <jsonl 文件>
#   rc 0 → stdout = 契约 JSON（compact，单个对象）
#   rc 2/3 → 透传 review_stream_final_text：Kiro 失败，调用方走失败评论路径（不是降级）
#   rc 4 → 没有成对的契约标记 → 降级
#   rc 5 → 标记内不是「恰好一个」JSON 对象 → 降级
#   rc 6 → 输出里出现多于一对契约标记（很可能是被评审内容里的假标记被引用）→ 降级
review_extract_json() {
  local jsonl="$1" final slice rc=0 slice_rc=0
  final=$(review_stream_final_text "$jsonl") || rc=$?
  if [[ "$rc" != "0" ]]; then
    # rc 3 时 review_stream_final_text 把 status 值写在 stdout；透传给调用方，让失败评论能写明原因
    [[ "$rc" == "3" ]] && printf '%s\n' "$final"
    return "$rc"
  fi
  slice=$(printf '%s\n' "$final" | review_clean_text | _review_slice_marker) || slice_rc=$?
  case "$slice_rc" in
    0) ;;
    2) return 6 ;;
    *) return 4 ;;
  esac
  slice=$(printf '%s\n' "$slice" | _review_strip_code_fence)
  # -s 把输入读成数组：jq 默认接受 JSON 流，`{...}{...}` 两个对象也能通过 `type == "object"`，
  # 之后 review_validate 会把两行 JSON 一起吐出来，渲染出「P0 0\n0」这种垃圾。必须恰好一个对象。
  printf '%s\n' "$slice" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || return 5
  printf '%s\n' "$slice" | jq -c -s '.[0]'
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
  # 刻意不写「第 N 次评审」：本版本 run 号固定为 1（原地更新属后续票），第二次评审时那句话就是假的。
  # 标记里的 run:N 仍然保留，供后续票做原地更新与历次记录。
  echo "P0 必须修复 · P1 应当修复 · P2 可选改进 · 评论 \`/kiro review\` 可重新评审"
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

  # --json 必须是 review_validate 的输出。不校验的话：空文件/非 JSON 会让每个 jq -r 都吐空串，
  # 渲染出一条「结论：评审员未给出结论 / P0 · P1 · P2 全空 / 问题清单里什么也没有」的空壳评论并返回 0；
  # 缺 dropped_findings 时 `[[ "$dropped" -gt 0 ]]` 还会在 set -u 下直接崩（null: unbound variable）。
  jq -e '(type == "object")
         and ((.dropped_findings | type) == "number")
         and ((.findings | type) == "array")' "$_RR_JSON" >/dev/null 2>&1 \
    || { echo "review_render_summary: --json 不是 review_validate 的输出（需要对象 + 数值 dropped_findings + 数组 findings）：${_RR_JSON}" >&2; return 2; }

  local summary verdict verdict_cn verdict_reason dropped n0 n1 n2 total
  summary=$(jq -r '.summary // ""' "$_RR_JSON")
  verdict=$(jq -r '.verdict // ""' "$_RR_JSON")
  verdict_reason=$(jq -r '.verdict_reason // ""' "$_RR_JSON")
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
  # 模型给的字符串一律用 printf：值恰好是 -n / -e / -E 时 echo 会当成选项吃掉，正文直接消失
  if [[ -n "$summary" ]]; then printf '%s\n' "$summary"; else echo "（评审员未给出变更摘要）"; fi
  echo ""
  echo "### 结论：${verdict_cn}"
  echo ""
  if [[ -n "$verdict_reason" ]]; then printf '%s\n' "$verdict_reason"; else echo "（评审员未给出结论理由）"; fi
  # 契约要求「有 P0 时不要给 MERGE」。模型违约时不改写它的结论（那是评审员的判断），
  # 但必须把矛盾摆在结论旁边——否则只看标题的人会合并一份自己都说有 P0 的代码。
  if [[ "$verdict" == "MERGE" && "$n0" -gt 0 ]]; then
    echo ""
    echo "> ⚠️ 评审员给出「可合并」，但同时报了 ${n0} 条 P0（必须修复）。两者矛盾，请以下方 P0 清单为准。"
  fi
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

# --- 疑似密钥的脚本侧掩码（stdin → stdout）---
# 只用在降级路径上。正常路径的掩码由评审员按 agent 提示词完成（前 4 后 4），但降级恰恰意味着
# 评审员没有遵守输出契约——此时再假设它遵守了掩码规则是不成立的，而降级评论会把原文整段贴到
# 组织内可见的 MR 上。所以这里按已知凭证形态做一次保守的脚本侧掩码：
#   宁可把不是密钥的长串也掩掉（降级评论本就是兜底形态），也不要漏一个真凭证。
# 掩码规则与提示词一致：长度 ≥ 12 保留前 4 后 4，其余整体替换为 ****。
# 注意这不是完备的密钥检测，只覆盖有明确前缀/形态的常见类型 + key=value 赋值。
review_redact_secrets() {
  LC_ALL=C awk '
    function mask(s) {
      if (length(s) >= 12) return substr(s, 1, 4) "****" substr(s, length(s) - 3)
      return "****"
    }
    # 把 line 中所有匹配 re 的片段替换成掩码后的自身
    function redact(line, re,   out, m, pre) {
      out = ""
      while (match(line, re) > 0) {
        pre = substr(line, 1, RSTART - 1)
        m = substr(line, RSTART, RLENGTH)
        out = out pre mask(m)
        line = substr(line, RSTART + RLENGTH)
      }
      return out line
    }
    # 形如 SECRET_KEY = "xxx" / token: xxx 的赋值：只掩码取值部分，保留键名（键名是排查线索）
    # 大小写不敏感靠 tolower 副本定位——tolower 不改变长度，下标可以直接套回原串
    function redact_assign(line,   lo, out, seg, vstart, val, i, ch) {
      out = ""
      while (1) {
        lo = tolower(line)
        if (match(lo, /(secret|token|passwd|password|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|credential)[a-z0-9_-]*[[:space:]]*[:=][[:space:]]*"?'"'"'?[a-za-z0-9\/+_=.-]{12,}/) == 0) break
        seg = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1)
        line = substr(line, RSTART + RLENGTH)
        # 在 seg 里找最后一个 : 或 = 之后的取值起点（跳过空白与引号）
        vstart = 0
        for (i = length(seg); i >= 1; i--) {
          ch = substr(seg, i, 1)
          if (ch == ":" || ch == "=") { vstart = i + 1; break }
        }
        if (vstart == 0) { out = out seg; continue }
        while (vstart <= length(seg) && substr(seg, vstart, 1) ~ /[[:space:]"'"'"']/) vstart++
        val = substr(seg, vstart)
        out = out substr(seg, 1, vstart - 1) mask(val)
      }
      return out line
    }
    BEGIN {
      n = 0
      pat[++n] = "(AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[0-9A-Z]{16}"   # AWS 访问密钥 ID
      pat[++n] = "ghp_[0-9A-Za-z]{20,}"                                      # GitHub PAT（classic）
      pat[++n] = "github_pat_[0-9A-Za-z_]{20,}"                              # GitHub PAT（fine-grained）
      pat[++n] = "gh[opsu]_[0-9A-Za-z]{20,}"                                 # 其余 GitHub 令牌
      pat[++n] = "xox[baprs]-[0-9A-Za-z-]{10,}"                              # Slack
      pat[++n] = "AIza[0-9A-Za-z_-]{30,}"                                    # Google API key
      pat[++n] = "sk-[0-9A-Za-z]{20,}"                                       # OpenAI 风格
      pat[++n] = "eyJ[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}" # JWT
    }
    # PEM 私钥整块屏蔽：这种内容没有「保留前 4 后 4」的意义
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/ { inpem = 1; print "**** （脚本已屏蔽一段 PRIVATE KEY 内容）"; next }
    inpem && /-----END [A-Z ]*PRIVATE KEY-----/ { inpem = 0; next }
    inpem { next }
    {
      line = $0
      for (i = 1; i <= n; i++) line = redact(line, pat[i])
      print redact_assign(line)
    }'
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
  echo "> 下面是评审员输出的原文（已由脚本对疑似凭证再做一次掩码）；重跑评审（评论 \`/kiro review\`）通常可恢复结构化输出。"
  echo ""
  echo "---"
  echo ""
  review_redact_secrets < "$_RR_TEXT"
  echo ""
  _review_render_footer
}
