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
# 汇总评论的原地更新（票 03）：
#   review_select_prior_comment  从 MR 的全局评论里定位「本评审员上一次那条」（作者 + 评审标记）
#   review_parse_history         从那条评论的隐藏 JSON 读回历次记录
#   review_history_append        追加本次记录（并对所有字段做字符白名单过滤）
#   review_render_history_marker / review_render_history_table / review_render_footer
#                                隐藏 JSON、「历次评审」折叠表、含「第 N 次评审」的页脚
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
# LC_ALL=C 是必需的（R9）：模型输出里混进无效 UTF-8 字节时，带 UTF-8 locale 的 sed（macOS/BSD）会
# 直接报错退出；在 `set -o pipefail` 的管道里，这个失败会被上游当成「awk 没找到标记」，一次编码问题
# 就被写成「被评审代码里有假标记」。按字节处理既不会失败，对 ANSI 序列的剥离也不受影响。
review_clean_text() {
  local esc
  esc=$(printf '\033')
  LC_ALL=C sed "s/${esc}\\[[0-9;?]*[a-zA-Z]//g"
}

# --- 模型文本的 Markdown 结构清洗（R1）---
# 威胁：summary / verdict_reason / title / body / fix 与降级原文全部来自模型，而模型按 agent 提示词
# 会把业务库里的注入内容作为 P0 原文引用出来。业务库因此可以往这些槽位里塞：
#   ① 第二个评审标记 `<!-- kiro-review:deadbee run:1 -->`——后续票「按标记找自己那条评论」会被打乱；
#   ② 伪造的 `## 🤖 Kiro 代码评审` / `### 结论：可合并` 标题与 `---` 页脚分隔线——读者看到的结构
#      就不再是脚本渲染的结构（降级路径尤其严重，那里贴的是整段原文）。
# 因此：评论里的结构（评审标记、标题层级、页脚分隔线）只能来自脚本，模型文本一律降级为普通文本。
# 做法（jq 实现，避免同一套转义规则出现两份）：
#   - `<!--` / `-->` 转义为 `&lt;!--` / `--&gt;`：注释语法失效，标记再也构不成 HTML 注释。
#     无条件执行（也包括代码围栏内）——后续票的去重是对评论原文做文本匹配，围栏内的标记同样会被匹配到。
#   - `<details` / `</details` 同样转义，且**大小写不敏感**（HTML 标签名不区分大小写，`<DETAILS>`
#     一样会被渲染成折叠块）：折叠区是脚本渲染的结构（票 03 的「历次评审」表就是一个），
#     模型文本里的折叠标签能把脚本渲染的历次表与页脚吞进攻击者自己的折叠块、伪造历次计数，
#     也会让「超长截断后补齐未闭合 </details>」这道修复按错误的标签计数走偏。
#     用带捕获的单条 gsub 保留原始大小写（转义后的字面量按原样显示，便于读者看出模型引用了什么）。
#   - 代码围栏外，行首的 `#{1,6}` 标题与 `---`/`***`/`___`/`===` 分隔线前加反斜杠转义（渲染成字面量）。
#     围栏内不动：那里的 `#` 是代码注释，转义会破坏代码，而围栏内的 `#` 本来也不会渲染成标题。
#   - 围栏数为奇数时补一个闭合围栏：否则模型开一个不闭合的围栏就能把后面脚本渲染的章节与页脚一起吞掉。
_REVIEW_JQ_SANITIZE='
  def _sanitize_md:
    if type != "string" then "" else
    (gsub("<!--"; "&lt;!--") | gsub("-->"; "--&gt;")
     | gsub("<(?<tag>/?details)"; "&lt;\(.tag)"; "i"))
    | split("\n")
    | reduce .[] as $l ({fence: false, out: []};
        if ($l | test("^[[:space:]]{0,3}(```|~~~)")) then
          {fence: (.fence | not), out: (.out + [$l])}
        elif .fence then
          {fence: .fence, out: (.out + [$l])}
        elif ($l | test("^[[:space:]]{0,3}#{1,6}([[:space:]]|$)")) then
          {fence: .fence, out: (.out + [($l | sub("^(?<sp>[[:space:]]{0,3})(?<h>#{1,6})"; .sp + "\\" + .h))])}
        elif ($l | test("^[[:space:]]{0,3}[-*_=]{3,}[[:space:]]*$")) then
          {fence: .fence, out: (.out + [($l | sub("^(?<sp>[[:space:]]{0,3})"; .sp + "\\"))])}
        else
          {fence: .fence, out: (.out + [$l])}
        end)
    | (if .fence then (.out + ["```"]) else .out end)
    | join("\n")
    end;
'

# 用法：review_sanitize_md < 文件 → stdout（降级原文走这条；契约字段在 review_validate 里用同一个 jq def）
# -j（join output，不额外补换行）：输入文件末尾本来就有换行，split/join 会原样保留它；
# 用 -r 的话 jq 还会再补一个，降级评论的正文与页脚之间就多出一个空行。
review_sanitize_md() {
  jq -Rjs "${_REVIEW_JQ_SANITIZE} _sanitize_md"
}

# --- 从 JSON Lines 事件流取最终消息 ---
# 用法：review_stream_final_text <jsonl 文件>
#   rc 0 → stdout = finalText
#   rc 2 → 没有 runFinished 事件（Kiro 未跑完：视为 Kiro 失败）
#   rc 3 → runFinished.data.status 非 success；stdout = status 值（供失败评论写明原因）
#   rc 7 → 事件流文件不可读（**不能**与 review_extract_json 的「标记不唯一」rc 6 复用同一个码：
#          那会把一次 I/O 故障在 MR 上写成「被评审代码里有假标记」）
# 用 `jq -R 'fromjson?'` 逐行解析：stdout 里混进 CLI 的非 JSON 警告行时跳过该行，而不是整体失败。
review_stream_final_text() {
  local jsonl="$1" rf status
  [[ -r "$jsonl" ]] || { echo "review_stream_final_text: 事件流文件不可读：${jsonl}" >&2; return 7; }
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
# context 取**峰值**而不是最后一个：实测事件流里这个值不单调（real-shape.jsonl 是 12.02 → 1.30，
# 取最后一个会把「上下文最高用到 12%」记成 1.3%，这个指标本来就是为了看离上限还有多远）。
# 缺数据时对应字段为 -，永不失败（日志不该拖垮评审）。
review_stream_usage() {
  local jsonl="$1" credits ctx
  if [[ ! -r "$jsonl" ]]; then printf 'credits=- context=-\n'; return 0; fi
  credits=$(jq -R 'fromjson? | select(type == "object" and .type == "metadata")
                   | .data.meteringUsage // empty | .[] | select(.unit == "credit") | .value' \
              "$jsonl" 2>/dev/null | LC_ALL=C awk '{s += $1; n++} END {if (n) printf "%.4f", s; else printf "-"}')
  ctx=$(jq -r -R 'fromjson? | select(type == "object" and .type == "metadata")
                  | .data.contextUsagePercentage // empty' "$jsonl" 2>/dev/null \
        | LC_ALL=C awk 'NF { if (!f || $1 > m) m = $1; f = 1 } END {if (f) printf "%.1f%%", m; else printf "-"}')
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

# --- 本次运行的标记随机串（R4）---
# 固定字面量标记是可被业务库利用的：提示词要求把注入企图作为 P0 报出来，模型常常直接原文引用
# 那行 `<<<KIRO_REVIEW_JSON>>>`，于是标记计数变成 2、每次评审都被打成「标记不唯一」而降级——
# 业务库提交一行文本就能让评审永久失去结构化输出。改成每次运行生成随机 nonce、标记里带上它，
# 攻击者无法预先把本次的 nonce 提交进仓库。
review_new_nonce() {
  # 优先 /dev/urandom（Linux/macOS 都有）；取不到时退回 PID + 纳秒/秒级时间戳，仍然不可预测到「提前提交」
  od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n' | grep -qE '^[0-9a-f]{16}$' \
    && od -An -tx1 -N8 /dev/urandom | tr -d ' \n' \
    || printf '%08x%08x' "$$" "$(date +%s)"
}

# 用法：review_marker_start <nonce> / review_marker_end <nonce>
review_marker_start() { printf '<<<KIRO_REVIEW_JSON:%s>>>' "$1"; }
review_marker_end()   { printf '<<<END_KIRO_REVIEW_JSON:%s>>>' "$1"; }

# --- 从最终消息里截出标记包裹的那段 JSON（stdin → stdout）---
# 安全要求：业务库内容不受信，而 agent 提示词要求评审员把注入企图作为 P0 报告出来——也就是说
# **被评审代码里的假契约块很可能被评审员原文引用到最终消息里**。带 nonce 之后攻击者已经无法预先
# 造出「本次」标记，但模型自己复述一遍本次标记仍然可能发生，此时输出里会出现两对标记、无法判定
# 哪一段是结论。取「最后一对」会让后一段顶掉前一段，取「第一对」也只是换一种被绕过的顺序。
# 因此：**本次标记不唯一就拒绝解析**，交给降级路径贴出原文，让人来看。
# LC_ALL=C：按字节处理，模型输出里的无效 UTF-8 不会让 awk 罢工（与 review_clean_text 同理）。
# 用法：_review_slice_marker <起始标记> <结束标记>
# rc 1 = 没有成对标记；rc 2 = 起始或结束标记出现多于一次。
_review_slice_marker() {
  LC_ALL=C awk -v S="$1" -v E="$2" '
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
# 用法：review_extract_json <jsonl 文件> <本次运行的 nonce>
#   rc 0 → stdout = 契约 JSON（compact，单个对象）
#   rc 2/3/7 → 透传 review_stream_final_text：Kiro 失败或事件流不可读，调用方走失败评论路径（不是降级）
#   rc 4 → 没有成对的契约标记 → 降级
#   rc 5 → 标记内不是「恰好一个」JSON 对象 → 降级
#   rc 6 → 输出里出现多于一对契约标记 → 降级
#   rc 8 → 用法错误（没传 nonce）：绝不退回固定标记，否则 R4 的防护就白做了
review_extract_json() {
  local jsonl="$1" nonce="${2:-}" final slice rc=0 slice_rc=0 ms me
  [[ -n "$nonce" ]] || { echo "review_extract_json: 缺少 nonce 参数（标记必须带本次运行的随机串）" >&2; return 8; }
  ms=$(review_marker_start "$nonce"); me=$(review_marker_end "$nonce")
  final=$(review_stream_final_text "$jsonl") || rc=$?
  if [[ "$rc" != "0" ]]; then
    # rc 3 时 review_stream_final_text 把 status 值写在 stdout；透传给调用方，让失败评论能写明原因
    [[ "$rc" == "3" ]] && printf '%s\n' "$final"
    return "$rc"
  fi
  slice=$(printf '%s\n' "$final" | review_clean_text | _review_slice_marker "$ms" "$me") || slice_rc=$?
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

# --- 受信 agent 的契约标识（R3）---
# 这个字段**只**写在 agent 提示词里，运行时提示词绝不提它。kiro-cli 对 `--agent` 的未知名字是静默接受的，
# runStarted 事件也不含 agent 名，所以「受信 agent 到底有没有生效」在事件流里看不出来。
# 一旦 agent 没加载（文件改名、安装回归、CLI 行为变化），模型拿到的是裸提示词：拒绝路径全部失效，
# 输出也不合契约——而降级路径会把那份输出贴到 MR 上。有了这个字段，缺失/不符就能判定为
# 「不是受信 agent 的产出」，走失败评论而**不是**降级（不能把非受信产出贴出去）。
REVIEW_CONTRACT_ID="codeup-reviewer/1"

# --- 契约校验（stdin = 契约 JSON → stdout = 规范化 JSON）---
# 规范化后的形态：
#   {summary, verdict, verdict_reason, findings:[…], dropped_findings:N, delocated_findings:N}
# 丢弃规则（spec §4.1「字段校验失败的 finding 丢弃并计数」）：
#   - 不是 JSON 对象
#   - severity 规范化（去首尾空白 + 大写）后不是 P0/P1/P2
#   - title 或 body 去空白后为空（缺字段同样算空）
# 置空（不丢弃）的情形：
#   - file 为空/非字符串 → null（仓库级意见）
#   - file 含换行/回车/`|`/反引号 → null 并计入 delocated_findings（R2）：file 会被渲染进
#     「重点关注文件」表格的单元格（`|` 会造出幻影列、截断表格）和被反引号包裹的定位串（反引号会破坏配对），
#     换行更是直接把表格截断、给攻击者一个塞伪造章节的位置。这类路径本来也不可能是真实文件名。
#   - line_start/line_end 不是 ≥1 的整数 → null；file 为 null 时行号一并置 null
# 文本清洗：summary / verdict_reason / title / body / fix 全部过 _sanitize_md（见 R1 说明）；
#   title 与 verdict 额外把空白折叠成单空格——它们要渲染进单行（`##### …` 标题行与 `### 结论：…`），
#   带换行就会把标题行截断。
# body/fix 不做 trim：它们是 Markdown，可能以缩进代码块开头，裁掉缩进会破坏渲染。
# dropped_findings 直接写进输出 JSON 而不是回传全局变量：调用方普遍用 $(…) 取结果，
# 命令替换在子 shell 里跑，全局变量传不回来（codeup-api.sh 里踩过同一个坑）。
# rc 1 = 顶层不是对象 / findings 不是数组 / 不是合法 JSON（调用方走降级）
# rc 3 = contract 字段缺失或不等于 REVIEW_CONTRACT_ID（调用方走失败评论，**不得**贴出模型内容）
review_validate() {
  local input
  input=$(cat)
  printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { echo "review_validate: 契约不是 JSON 对象" >&2; return 1; }
  printf '%s' "$input" | jq -e '(.findings // []) | type == "array"' >/dev/null 2>&1 \
    || { echo "review_validate: 契约的 findings 不是数组" >&2; return 1; }
  printf '%s' "$input" | jq -e --arg id "$REVIEW_CONTRACT_ID" '(.contract // "") == $id' >/dev/null 2>&1 \
    || { echo "review_validate: 契约缺少 contract=\"${REVIEW_CONTRACT_ID}\" 字段（该字段只在受信 agent 提示词里要求，说明受信 agent 未生效）" >&2; return 3; }
  printf '%s' "$input" | jq -c "${_REVIEW_JQ_SANITIZE}"'
    # \A / \z 是显式的「字符串首/尾」锚点：jq 的 ^ / $ 在不同版本可能被当行锚点，
    # 那会连多行字符串里每一行的缩进都裁掉。
    def tr(v): if (v | type) == "string"
               then (v | gsub("\\A[[:space:]]+"; "") | gsub("[[:space:]]+\\z"; ""))
               else "" end;
    # 单行槽位：折叠所有空白（含换行）为单空格，再做 Markdown 结构清洗
    def oneline(v): (tr(v) | gsub("[[:space:]]+"; " ") | _sanitize_md);
    def lineno(v): if (v | type) == "number" and (v | floor) == v and v >= 1 then (v | floor) else null end;
    # 文件路径：非空字符串，且不含换行/回车/`|`/反引号（否则按未定位处理）
    def fpath(v): (tr(v)) as $t
                  | if ($t | length) == 0 then null
                    elif ($t | test("[\n\r|`]")) then null
                    else $t end;
    . as $root
    | ((.findings // []) | length) as $total
    | [ (.findings // [])[]
        | select(type == "object")
        | (tr(.severity) | ascii_upcase) as $sev
        | (oneline(.title)) as $title
        | select(($sev == "P0" or $sev == "P1" or $sev == "P2")
                 and ($title | length) > 0
                 and ((tr(.body)) | length) > 0)
        | fpath(.file) as $file
        | ((tr(.file) | length) > 0 and $file == null) as $delocated
        | (if $file == null then null else lineno(.line_start) end) as $ls
        | (if $ls == null then null
           else (lineno(.line_end)) as $le | (if $le == null or $le < $ls then $ls else $le end) end) as $le
        | { id: (oneline(.id)), severity: $sev, category: (oneline(.category)), title: $title,
            file: $file, line_start: $ls, line_end: $le, delocated: $delocated,
            body: (if (.body | type) == "string" then (.body | _sanitize_md) else "" end),
            fix: (if (.fix | type) == "string" then (.fix | _sanitize_md) else "" end) }
      ] as $kept
    | { summary: (tr($root.summary) | _sanitize_md),
        verdict: (tr($root.verdict) | ascii_upcase | gsub("[[:space:]]+"; " ") | _sanitize_md),
        verdict_reason: (tr($root.verdict_reason) | _sanitize_md),
        findings: ($kept | map(del(.delocated))),
        dropped_findings: ($total - ($kept | length)),
        delocated_findings: ([$kept[] | select(.delocated)] | length) }'
}

# ============================================================================
# 票 04：行内评论管线（spec §4.5 第 2–7 步）
# ============================================================================
#
#   review_changed_lines        零上下文 diff → 每个文件「新文件侧」的变更行区间集合
#   review_plan_inline          规范化契约 + 变更行集合 + 档位 + 上限 → 本次的行内发布计划
#   review_fingerprint          行内评论去重指纹 sha1(file + line + title)
#   review_render_inline_marker / review_inline_existing_fingerprints
#                               指纹在评论正文里的隐藏标记；从 MR 现有行内评论里读回指纹
#   review_render_inline_body   一条行内评论的正文（spec §4.4）
#   review_plan_apply_outcomes  发布结果回填计划（发失败的问题必须落到折叠区，不能凭空消失）
#
# 为什么行号集合必须自己算而不是信模型：`line_start` 完全由模型给出，而 Codeup 只接受
# **新文件侧**的行号（spec §4.7.1 P1-02 实测），挂到未改动行上的评论对读者是噪音。
# 集合来自 git 对象（`git diff --no-renames -U0 BASE HEAD`），与评审输入同源。

# --- 零上下文 diff → 变更行集合（stdin = diff 文本 → stdout = JSON）---
# 输出形态：{"src/app.py":[[30,31],[45,45]], "docs/x.md":[]}
#   - 键 = 本次变更中**新文件侧存在**的文件路径（相对仓库根）
#   - 值 = 该文件新增/修改行的行号区间（闭区间，升序按 diff 出现次序）
#   - 值为 `[]`：文件确实变了但没有新文件侧的新增行（纯删除行的改动）→ 无处可挂行内评论
#   - 被删除的文件、二进制文件不出现在键里：新文件侧没有可评论的行
#     （P1-02 实测「只能对新文件侧的行评论」，被删除行的问题只能进折叠区）
#
# 解析要点（都是 git 真实输出里存在、且容易解析错的形态）：
#   ① 正文行可能与文件头逐字节同形：新文件里一行 `++ b/evil.py` 在 diff 里就是 `+++ b/evil.py`。
#      因此「一个文件段内出现第一个 @@ 之后不再认 ---/+++ 头」，段边界用 `^diff --git ` 判定
#      （正文行永远带 +/-/空格前缀，不可能顶到行首的 `diff --git `、`@@ `）。
#   ② 路径含空格/引号/控制字符时 git 用 C 风格转义并整体加引号（`+++ "b/q\"uote.py"`），必须还原；
#      非 ASCII 由调用方的 `-c core.quotePath=false` 保证不转义，八进制转义仍作兜底还原。
#   ③ `@@ -1,2 +3,4 @@` 的新侧计数为 0（`+0,0` / `+4,0`）表示纯删除 hunk，不贡献任何行号。
#      省略计数（`@@ -5 +5 @@`）等价于计数 1。
#   ④ `\ No newline at end of file` 行既不是头也不是 hunk，天然被忽略。
# LC_ALL=C：按字节处理，diff 里的无效 UTF-8 字节不会让 awk 罢工（与 review_clean_text 同理）。
review_changed_lines() {
  local sep
  sep=$(printf '\037')
  LC_ALL=C awk -v SEP="$sep" '
    # C 风格转义还原（git 对含特殊字符的路径会整体加引号）
    function unquote(s,   body, out, i, c, n, oct, v) {
      body = substr(s, 2, length(s) - 2)
      out = ""; i = 1
      while (i <= length(body)) {
        c = substr(body, i, 1)
        if (c != "\\") { out = out c; i++; continue }
        n = substr(body, i + 1, 1)
        if (n == "n")       { out = out "\n"; i += 2 }
        else if (n == "t")  { out = out "\t"; i += 2 }
        else if (n == "r")  { out = out "\r"; i += 2 }
        else if (n == "\"") { out = out "\""; i += 2 }
        else if (n == "\\") { out = out "\\"; i += 2 }
        else if (n >= "0" && n <= "7") {
          oct = substr(body, i + 1, 3)
          v = (substr(oct, 1, 1) + 0) * 64 + (substr(oct, 2, 1) + 0) * 8 + (substr(oct, 3, 1) + 0)
          out = out sprintf("%c", v); i += 4
        }
        else { out = out n; i += 2 }
      }
      return out
    }
    # `+++ ` 之后那一段 → 真实路径（去掉 b/ 前缀）
    function newpath(raw,   p, t) {
      p = raw
      if (substr(p, 1, 1) == "\"") p = unquote(p)
      else { t = index(p, "\t"); if (t > 0) p = substr(p, 1, t - 1) }
      if (substr(p, 1, 2) == "b/") p = substr(p, 3)
      return p
    }
    BEGIN { cur = ""; in_hunks = 0 }
    /^diff --git / { cur = ""; in_hunks = 0; next }
    !in_hunks && /^\+\+\+ / {
      raw = substr($0, 5)
      if (raw == "/dev/null") { cur = ""; next }
      cur = newpath(raw)
      if (cur != "") print cur SEP 0 SEP 0     # 文件出现过（即使没有可定位行）
      next
    }
    /^@@ / {
      in_hunks = 1
      if (cur == "") next
      if (match($0, /\+[0-9]+(,[0-9]+)?/) == 0) next
      spec = substr($0, RSTART + 1, RLENGTH - 1)
      ci = index(spec, ",")
      if (ci > 0) { start = substr(spec, 1, ci - 1) + 0; cnt = substr(spec, ci + 1) + 0 }
      else        { start = spec + 0; cnt = 1 }
      if (start < 1 || cnt < 1) next
      print cur SEP start SEP (start + cnt - 1)
      next
    }
  ' | jq -Rs --arg sep "$sep" '
      split("\n") | map(select(length > 0))
      | reduce .[] as $line ({};
          ($line | split($sep)) as $f
          | (if ($f | length) == 3 then $f[0] else "" end) as $p
          | if $p == "" then .
            else ($f[1] | tonumber) as $s | ($f[2] | tonumber) as $e
                 | .[$p] = ((.[$p] // []) + (if $s >= 1 and $e >= $s then [[$s, $e]] else [] end))
            end)'
}

# --- 行内档位（CONTEXT.md「行内档位」）---
# quiet=P0+P1（默认）· balanced=全部 · critical=仅 P0。
# 非法取值由 review_plan_inline 回落 quiet 并记 warning（配错开关不该让评审失败，但必须留痕）。
REVIEW_INLINE_PROFILE_DEFAULT=quiet
REVIEW_MAX_INLINE_DEFAULT=10
_review_profile_levels() {
  case "$1" in
    quiet)    echo "P0 P1" ;;
    balanced) echo "P0 P1 P2" ;;
    critical) echo "P0" ;;
    *)        return 1 ;;
  esac
}

# --- 行内发布计划 ---
# 用法：review_plan_inline --json <review_validate 的输出> --changed-lines <review_changed_lines 的输出>
#                          [--profile quiet] [--max 10]
# stdout = 在输入 JSON 上追加以下字段：
#   inline_profile / max_inline            实际生效的档位与上限（非法取值已回落）
#   config_notice                          档位/上限被回落时的一句话说明（正常为空串），
#                                          由调用方接到汇总评论的 --notice 上（I10 失败可见）
#   inline: [问题…]                        本次要发成行内评论的问题（已排序、已截取）
#   folded: {profile,overflow,unlocated,failed}
#       profile   = 可定位但档位不覆盖其级别（quiet 下就是 P2）
#       overflow  = 可定位、档位覆盖，但超出 max_inline
#       unlocated = 不可定位（无 file/行号，或行号不在该文件的变更行集合内）
#       failed    = 行内发布失败（由 review_plan_apply_outcomes 回填）
#   inline_count / folded_count
# 每个问题都带 `idx`（在 findings 里的原始下标）：发布结果靠它回填，不靠内容比对。
# 排序：P0→P1→P2，同级按文件路径升序、再按起始行、再按原始次序（`idx` 兜底，保证逐字节确定）。
# rc 2 = 参数错误（缺参数 / 文件不可读）——绝不静默按默认值规划，那会让开关看起来生效了。
review_plan_inline() {
  local json="" changed="" profile="${REVIEW_INLINE_PROFILE_DEFAULT}" max="${REVIEW_MAX_INLINE_DEFAULT}" levels
  local notice=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json|--changed-lines|--profile|--max)
        [[ $# -ge 2 ]] || { echo "review_plan_inline: 参数 $1 缺少取值" >&2; return 2; }
        case "$1" in
          --json) json="$2" ;;
          --changed-lines) changed="$2" ;;
          --profile) profile="$2" ;;
          --max) max="$2" ;;
        esac
        shift 2 ;;
      *) echo "review_plan_inline: 未知参数：$1" >&2; return 2 ;;
    esac
  done
  [[ -n "$json" && -r "$json" ]] || { echo "review_plan_inline: --json 不可读：${json:-<未提供>}" >&2; return 2; }
  [[ -n "$changed" && -r "$changed" ]] || { echo "review_plan_inline: --changed-lines 不可读：${changed:-<未提供>}" >&2; return 2; }
  # 档位与上限来自流水线变量，配错不该让评审失败，但必须回落到默认值并留痕。
  # 留痕不能只在 stderr：阿里云侧开发者看不到流水线日志（I10），所以同时写进 config_notice，
  # 由调用方接到汇总评论的 --notice 上——否则「档位配错了」这件事在 MR 上完全看不出来，
  # 而评论看起来一切正常（只是覆盖范围不是运维以为的那个）。
  if ! levels=$(_review_profile_levels "$profile"); then
    echo "review_plan_inline: INLINE_PROFILE=${profile} 不是 quiet/balanced/critical，按默认 ${REVIEW_INLINE_PROFILE_DEFAULT} 处理" >&2
    notice="INLINE_PROFILE=${profile} 不是 quiet/balanced/critical，本次已按默认 ${REVIEW_INLINE_PROFILE_DEFAULT} 处理。"
    profile="$REVIEW_INLINE_PROFILE_DEFAULT"
    levels=$(_review_profile_levels "$profile")
  fi
  if ! [[ "$max" =~ ^[0-9]+$ ]]; then
    echo "review_plan_inline: MAX_INLINE_COMMENTS=${max} 不是非负整数，按默认 ${REVIEW_MAX_INLINE_DEFAULT} 处理" >&2
    notice="${notice}${notice:+ }MAX_INLINE_COMMENTS=${max} 不是非负整数，本次已按默认 ${REVIEW_MAX_INLINE_DEFAULT} 处理。"
    max="$REVIEW_MAX_INLINE_DEFAULT"
  fi
  jq -c --slurpfile changed "$changed" --argjson max "$max" \
        --arg profile "$profile" --arg levels "$levels" --arg notice "$notice" '
    def sevrank: {"P0":0,"P1":1,"P2":2}[.] // 3;
    def ordered: sort_by([(.severity | sevrank), (.file // ""), (.line_start // 0), .idx]);
    ($changed[0] // {}) as $cl
    | ($levels | split(" ")) as $elig
    | . as $root
    | [ ($root.findings // []) | to_entries[] | (.value + {idx: .key}) ] as $all
    | [ $all[]
        | . as $f
        | $f + { located:
            ( if ($f.file == null or $f.line_start == null) then false
              else (($cl[$f.file] // []) | any(.[0] <= $f.line_start and $f.line_start <= .[1]))
              end ) } ] as $ann
    # 注意 index() 里的 `.` 是 $elig 本身，所以级别必须先绑成变量再查（否则是「用字符串索引数组」）
    | def eligible: (.severity) as $s | (($elig | index($s)) != null);
      [ $ann[] | select(.located and eligible) | del(.located) ] as $cand0
    | ($cand0 | ordered) as $cand
    | ($cand[0:$max]) as $inline
    | ($cand[$max:]) as $overflow
    | [ $ann[] | select(.located and (eligible | not)) | del(.located) ] as $prof
    | [ $ann[] | select(.located | not) | del(.located) ] as $unloc
    | $root + {
        inline_profile: $profile,
        max_inline: $max,
        config_notice: $notice,
        inline: $inline,
        folded: { profile: ($prof | ordered), overflow: $overflow,
                  unlocated: ($unloc | ordered), failed: [] },
        inline_count: ($inline | length),
        folded_count: (($prof | length) + ($overflow | length) + ($unloc | length))
      }' "$json"
}

# --- 发布结果回填 ---
# 用法：review_plan_apply_outcomes <计划 JSON> <结果 JSON>
#   结果 JSON = [{"idx":0,"outcome":"created"|"existing"|"failed"}, …]
#   created  = 本次新发出的行内评论
#   existing = 指纹命中、MR 上已有同一条 → 仍算「已标注在对应行」（spec §4.5 第 5 步「跳过并计数」）
#   failed   = 没发出去 → 必须移进折叠区，否则这条问题在 MR 上一条都看不到（违反 I4「同一问题只出现一次」）
# **缺失的结果按 failed 处理**（fail-closed）。这里绝不能按 created 兜底：调用方给每一条 inline 项
# 都会记一个结果，所以「查不到结果」只有一种含义——结果文件出了问题。此时按 created 兜底会把
# 一条根本没发出去的 P0 算成「已标注在对应行」，而 INLINE_COMMENT=1 的汇总不展开问题清单，
# 那条 P0 就在 MR 上彻底消失了。按 failed 兜底最坏只是让一条已经发出去的评论在折叠区里重复一次。
review_plan_apply_outcomes() {
  local plan="$1" outcomes="$2"
  [[ -r "$plan" ]] || { echo "review_plan_apply_outcomes: 计划文件不可读：${plan}" >&2; return 2; }
  [[ -r "$outcomes" ]] || { echo "review_plan_apply_outcomes: 结果文件不可读：${outcomes}" >&2; return 2; }
  jq -c --slurpfile oc "$outcomes" '
    (($oc[0] // []) | map(select(type == "object" and (.idx | type) == "number"))
                    | map({key: (.idx | tostring), value: (.outcome // "failed")}) | from_entries) as $o
    | def status(f): ($o[(f.idx | tostring)] // "failed");
      (.inline // []) as $in
    | [ $in[] | select(status(.) != "failed") ] as $kept
    | [ $in[] | select(status(.) == "failed") ] as $failed
    | .inline = $kept
    | .folded.failed = $failed
    | .inline_count = ($kept | length)
    | .folded_count = (((.folded.profile // []) | length) + ((.folded.overflow // []) | length)
                       + ((.folded.unlocated // []) | length) + ($failed | length))' "$plan"
}

# --- 去重指纹（spec §4.5 第 5 步）---
# 指纹 = sha1(file + line + title)。三段之间插 \x1f 分隔符：不分隔时
# ("a.py", 1, "2x") 与 ("a.py", 12, "x") 会撞成同一个指纹，两条不同的问题互相顶掉。
# sha1sum（GNU）与 shasum（macOS）二选一；两者都没有时 rc 1——调用方必须把它当硬依赖，
# 因为拿不到指纹就没法去重，重跑会在同一行上堆重复评论（违反 I6 幂等）。
review_fingerprint() {
  local payload
  payload=$(printf '%s\037%s\037%s' "${1-}" "${2-}" "${3-}")
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha1sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$payload" | shasum -a 1 | cut -d' ' -f1
  else
    echo "review_fingerprint: 缺少 sha1sum/shasum，算不出行内评论指纹" >&2
    return 1
  fi
}

# --- 指纹在行内评论正文里的隐藏标记 ---
# 为什么要写进正文而不是「从正文里反解 ### P0 · 标题 再算指纹」：反解要依赖渲染格式，
# 任何模板微调都会让去重静默失效、在同一行上堆重复评论。标记是稳定的解析契约（与汇总评论的
# kiro-history 同一思路）。模型文本里的 `<!--` 已被 _sanitize_md 转义，伪造不出这一行。
REVIEW_INLINE_MARKER_PREFIX="<!-- kiro-inline:"
REVIEW_INLINE_MARKER_SUFFIX=" -->"
REVIEW_INLINE_MARKER_RE='^<!-- kiro-inline:([0-9a-f]{40}) -->[[:space:]]*$'
review_render_inline_marker() {
  printf '%s%s%s\n' "$REVIEW_INLINE_MARKER_PREFIX" "$1" "$REVIEW_INLINE_MARKER_SUFFIX"
}

# --- 从 MR 现有行内评论里读回指纹（stdin = ListMergeRequestComments 响应）---
# 用法：review_inline_existing_fingerprints <机器人账号用户名或空串> → stdout 每行一个指纹
# 作者过滤：给了用户名就只认本机器人发的（别人复制一条带标记的评论不能压掉本评审员的问题）；
# 用户名未知时退化为「只按标记去重」——重跑重复是必然会发生的伤害，而伪造标记需要一个
# 已认证的 MR 参与者主动发评论（可见、可追溯），两害相权取轻，并由调用方打警告提示配置。
# 状态过滤在脚本侧做：接口只实测过 comment_type 过滤（P1-06），state 参数名未实测，
# 凭记忆传一个可能 400 的参数会让整条去重通路挂掉。
# 状态判定用**黑名单**（排除 DELETED 与 DRAFT）而不是白名单（只认 OPENED）：实测只见过这三个取值，
# 万一 Codeup 对「已被开发者解决」的行内评论返回别的状态（如 RESOLVED），白名单会漏收它的指纹，
# 于是每次重跑都在同一行上再发一条（违反 I6 幂等）。与 review_select_prior_comment 的判定一致。
# out_dated 的评论一律**不算**已发出：它绑的是被取代的旧版本，Codeup 会把它折叠/隐藏在 diff 视图里。
# 把它算作已发出，就等于汇总里那句「已标注在「文件改动」对应行」在说谎——读者在当前 diff 上看不到它。
# 重跑（没有新推送）时 out_dated 为 false，去重照常生效，A3「重跑不重复」不受影响。
# 字段类型守卫与 review_select_prior_comment 同理：任何一条评论字段不合形都不能废掉整批。
review_inline_existing_fingerprints() {
  local bot="${1-}"
  jq -r --arg bot "$bot" --arg re "$REVIEW_INLINE_MARKER_RE" '
    def str(v): if (v | type) == "string" then v else "" end;
    def author_name: if (.author | type) == "object" then str(.author.username) else "" end;
    (if type == "object" then (.result // []) else . end)
    | (if type == "array" then . else [] end)
    | map(select(type == "object"))
    | map(select(str(.comment_type) == "" or str(.comment_type) == "INLINE_COMMENT"))
    | map(select((str(.state) | ascii_upcase) as $s | $s != "DELETED" and $s != "DRAFT"))
    | map(select((.draft == true) | not))
    | map(select((.out_dated == true) | not))
    | map(select(if $bot == "" then true else author_name == $bot end))
    | .[] | str(.content) | split("\n")[] | match($re) | .captures[0].string' 2>/dev/null \
    | LC_ALL=C sort -u
}

# --- 一条行内评论的正文（spec §4.4）---
# 用法：review_render_inline_body <单条问题的 JSON 文件> <短 sha> <指纹>
# 模板：
#   ### {P0} · {title}[（L{起}–L{止}）]
#   <!-- kiro-inline:{指纹} -->
#
#   {body}
#
#   **修复建议**
#
#   {fix}
#
#   — Kiro 评审 · 提交 `{sha}`
# 多行区间在标题后附 `（L起–L止）`，锚点仍取 line_start（Codeup 的行内评论只能锚一行）。
# body/fix 已在 review_validate 里过 _sanitize_md：这里不再二次转义（会把代码块弄坏）。
review_render_inline_body() {
  local item="$1" sha="$2" fp="$3" sev title body fix ls le
  [[ -r "$item" ]] || { echo "review_render_inline_body: 问题 JSON 不可读：${item}" >&2; return 2; }
  [[ -n "$sha" ]] || { echo "review_render_inline_body: 缺少短 sha" >&2; return 2; }
  [[ "$fp" =~ ^[0-9a-f]{40}$ ]] || { echo "review_render_inline_body: 指纹不是 40 位十六进制：${fp}" >&2; return 2; }
  jq -e 'type == "object" and (.severity | type) == "string" and (.title | type) == "string"' "$item" >/dev/null 2>&1 \
    || { echo "review_render_inline_body: 问题 JSON 缺 severity/title：${item}" >&2; return 2; }
  sev=$(jq -r '.severity' "$item")
  title=$(jq -r '.title' "$item")
  body=$(jq -r '.body // ""' "$item")
  fix=$(jq -r '.fix // ""' "$item")
  ls=$(jq -r '.line_start // ""' "$item")
  le=$(jq -r '.line_end // ""' "$item")
  if [[ -n "$ls" && -n "$le" && "$le" != "$ls" ]]; then
    title="${title}（L${ls}–L${le}）"
  fi
  printf '### %s · %s\n' "$sev" "$title"
  review_render_inline_marker "$fp"
  echo ""
  if [[ -n "$body" ]]; then printf '%s\n' "$body"; else echo "（评审员未给出说明）"; fi
  if [[ -n "$fix" ]]; then
    echo ""
    echo "**修复建议**"
    echo ""
    printf '%s\n' "$fix"
  fi
  echo ""
  printf -- '— Kiro 评审 · 提交 `%s`\n' "$sha"
}

# --- 评审标记（原地更新的定位依据）---
# 形态必须与 _review_render_header 渲染出的那一行严格一致：
#   <!-- kiro-review:{sha} run:{n} -->
# 同一条正则同时给 jq（Oniguruma）与 grep/sed（POSIX ERE）用，两个引擎都支持这里用到的字符类。
# 注意：jq 的 ^/$ 默认锚定整个字符串而不是行，所以在 jq 里必须先 split("\n") 再逐行 match
# （见 review_select_prior_comment）。
# run 限 1–9 位：汇总评论在 Codeup 上是人可编辑的，`run:99999999999999999999` 这种手改值会让
# `$((prior_run + 1))` 静默溢出成负数、渲染出一个再也匹配不上的标记。位数上限让这类值直接不算候选
# （于是新建一条正常的汇总），而不是把 run 号搞坏。
REVIEW_MARKER_LINE_RE='^<!-- kiro-review:[0-9a-zA-Z._-]+ run:([0-9]{1,9}) -->[[:space:]]*$'

# --- 历次评审记录 ---
# 汇总评论里嵌一行隐藏 JSON 作为机器可读的历次记录，「历次评审」表只是它的人类可读投影：
#   <!-- kiro-history:[{"run":1,"sha":"90fcb05","verdict":"MERGE","status":"","p0":0,"p1":1,"p2":2}] -->
# 为什么不反解表格：表格要把结论中文化、要把三个计数合成一列，反解需要一套反向映射，
# 任何渲染微调都会让历史读不出来。隐藏 JSON 与渲染解耦，是稳定的解析契约。
# status：""=正常评审；failed=评审未完成；degraded=结构化解析失败（此时计数为 null）。
# 注入面：这一行会被下一次评审读回来，所以写入时对每个字符串字段做白名单过滤
# （review_history_append 的 safe()），保证正文里不可能出现 `-->` 而提前闭合注释。
REVIEW_HISTORY_PREFIX="<!-- kiro-history:"
REVIEW_HISTORY_SUFFIX=" -->"
# 行数上限：历史无限增长会把汇总评论撑到 Codeup 的长度上限
REVIEW_HISTORY_MAX=20

# 用法：review_parse_history <旧评论正文文件> → stdout = JSON 数组（读不到/不合法一律 []）
# 永不失败：拿不到历史只会让「历次评审」表少几行，不该拖垮评审。
review_parse_history() {
  local file="$1" n line json out
  [[ -r "$file" ]] || { echo '[]'; return 0; }
  n=$(grep -c "^${REVIEW_HISTORY_PREFIX}" "$file" 2>/dev/null || true)
  n=${n:-0}
  if [[ "$n" != "1" ]]; then
    [[ "$n" == "0" ]] \
      || echo "review_parse_history: 历史标记出现 ${n} 次（预期 1），无法判定哪一份是自己的，忽略历史" >&2
    echo '[]'; return 0
  fi
  line=$(grep "^${REVIEW_HISTORY_PREFIX}" "$file" | head -1)
  # 剥掉行尾**所有**空白，不只是 \r：评审标记的正则以 [[:space:]]*$ 结尾，所以行尾多一个空格或
  # 制表符（Codeup 网页编辑很常见）的评论**照样**会被选中并被原地更新；而这里若剥不掉 " -->"
  # 后缀，历史就会静默清空，那条评论被 PUT 成只剩本次一行——「历次评审」表悄悄丢掉全部历史。
  # 容忍度必须与选择器一致。
  line=$(printf '%s' "$line" | LC_ALL=C sed -E 's/[[:space:]]+$//')
  json=${line#"$REVIEW_HISTORY_PREFIX"}
  json=${json%"$REVIEW_HISTORY_SUFFIX"}
  # 必须 -s 读成数组并要求「恰好一个 JSON 值」：
  #   ① payload 尾巴上有多余字节时，jq 会先输出一份合法结果、再报错退出，而 `|| echo '[]'` 是
  #      **追加**不是替换——下游就拿到两个 JSON 值，历次表会渲染出重复行与断成两行的 <summary>；
  #   ② payload 为空（`<!-- kiro-history: -->`）时，不带 -s 的 jq 无输入即无输出且退出码 0，
  #      本函数会返回空串而不是 []，把「拿不到历史」升级成整条评论渲染失败。
  out=$(printf '%s' "$json" | jq -c -s '
          if length == 1 and (.[0] | type == "array")
          then [.[0][] | select(type == "object" and (.run | type) == "number")]
          else [] end' 2>/dev/null) || out=""
  if [[ -z "$out" ]]; then
    echo "review_parse_history: 历史标记内不是恰好一个 JSON 数组，忽略历史" >&2
    out='[]'
  fi
  printf '%s\n' "$out"
}

# 用法：review_history_append <历史 JSON 文件或 -> <run> <sha> <verdict> <status> <p0> <p1> <p2>
#   p0/p1/p2 传 "-"（或任何非数字）表示未知 → 记为 null
# stdout = 追加本次记录后的 JSON 数组（只保留最近 REVIEW_HISTORY_MAX 行）
review_history_append() {
  local hist="$1" run="$2" sha="$3" verdict="$4" status="$5" p0="$6" p1="$7" p2="$8" base
  if [[ "$hist" == "-" || ! -r "$hist" ]]; then base='[]'; else base=$(cat "$hist"); fi
  printf '%s' "$base" | jq -c --argjson max "$REVIEW_HISTORY_MAX" \
    --arg run "$run" --arg sha "$sha" --arg verdict "$verdict" --arg status "$status" \
    --arg p0 "$p0" --arg p1 "$p1" --arg p2 "$p2" '
    def num(v): if (v | test("^[0-9]+$")) then (v | tonumber) else null end;
    def numj(v): if (v | type) == "number" then (v | floor) else null end;
    # 字符白名单：剔掉 < 与 >，过滤后的取值不可能构成 `-->`／`<!--`，隐藏注释不会被提前闭合；
    # 剔掉 | 与反引号，历次表的单元格不会被撑出幻影列、定位串的反引号不会失配；
    # 剔掉控制字符，历次表的行渲染用 \x1f 作字段分隔符，混进控制字符会错位。
    # 非 ASCII 一律保留（中文结论要能显示）。
    def safe(v; n): ((v // "") | tostring | gsub("[<>|`\\\\]"; "") | gsub("[[:cntrl:]]"; "") | .[0:n]);
    # 旧记录同样过一遍过滤与字段规范化：汇总评论在 Codeup 上是人可编辑的，隐藏 JSON 里的取值
    # 不能当作可信输入（只做「追加时过滤新行」的话，被手工改过的历史会原样渲染进表格）。
    (if type == "array" then . else [] end)
    | map(select(type == "object" and (.run | type) == "number")
          | { run: (.run | floor), sha: safe(.sha; 40), verdict: safe(.verdict; 40),
              status: safe(.status; 16), p0: numj(.p0), p1: numj(.p1), p2: numj(.p2) })
    + [{ run: (num($run) // 1), sha: safe($sha; 40), verdict: safe($verdict; 40),
         status: safe($status; 16), p0: num($p0), p1: num($p1), p2: num($p2) }]
    | .[-$max:]'
}

# --- 定位「本评审员上一次的汇总评论」（stdin = ListMergeRequestComments 响应）---
# 用法：review_select_prior_comment <机器人账号用户名或空串>
#   rc 0 → stdout = 选中的评论对象（compact JSON，额外带 run 字段＝从评审标记解析出的次数）
#   rc 1 → 没有候选（首次评审，或旧评论已被人删除）
#   rc 3 → 有候选，但机器人账号用户名未知 → **不得**原地更新，调用方新建（见下）
#
# 判定 = 作者用户名匹配 **且** 正文含本集成包渲染的评审标记（票 03 验收项）。缺任何一半都不行：
#   只看作者 → 机器人发的行内评论/状态评论会被当成汇总改掉；
#   只看标记 → 有人把整条报告原文复制一份留档，就会去改别人的评论。
# 机器人用户名只接受两个来源：① CODEUP_BOT_USERNAME 显式配置（推荐）；② 令牌身份接口
# （spec §4.7.1 P1-00 实测 403，生产上大概率不可用）。
# **刻意不再**用「带评审标记的评论作者」作为更新依据：评审标记是明文可复制的，任何 MR 参与者
# 发一条正文含 `<!-- kiro-review:… run:1 -->` 的评论，就能把本评审员的报告引到他自己那条评论上
# （覆盖其内容，且他之后仍可编辑我们的报告）。「每评审员至多一条汇总」不能建立在可伪造的推断上。
# 用户名未知时推断值仍会算出来，但**只用于日志提示**（告诉运维该把哪个值配进 CODEUP_BOT_USERNAME）。
# 多条候选时取 run 最大的那条（上一次更新失败退回新建会留下两条，此后应继续更新最新那条）。
review_select_prior_comment() {
  local bot="${1-}" input out status inferred
  input=$(cat)
  out=$(printf '%s' "$input" | jq -c --arg bot "$bot" --arg re "$REVIEW_MARKER_LINE_RE" '
    # 字段类型守卫：响应形态只在一次探测里见过，不能假定每一行的每个字段都规整。
    # 任何一条评论里 .content 非字符串（split 报错）、.state 非字符串（ascii_upcase 报错）、
    # .author 非对象（索引字符串报错）都会让**整个** jq 程序失败 → 调用方按「未找到」处理 →
    # 这个 MR 从此每次评审都新建一条汇总。不合形的字段一律按缺省值处理，只影响那一行。
    def str(v): if (v | type) == "string" then v else "" end;
    def author_name: if (.author | type) == "object" then str(.author.username) else "" end;
    def marker_runs:
      [ (str(.content) | split("\n")[] | match($re) | .captures[0].string | tonumber) ];
    (if type == "object" then (.result // []) else . end)
    | (if type == "array" then . else [] end)
    | map(select(type == "object"))
    # content 必须是非空字符串才可能带评审标记
    | map(select((.content | type) == "string"))
    # comment_type 缺失或不合形 → 按 GLOBAL_COMMENT 处理（接口已按类型过滤过，这里只是纵深防御）
    | map(select(str(.comment_type) == "" or str(.comment_type) == "GLOBAL_COMMENT"))
    | map(select((str(.state) | ascii_upcase) != "DELETED"))
    # 只有布尔真才算草稿；其它取值按「不是草稿」处理
    | map(select((.draft == true) | not))
    | map(. + {_runs: marker_runs})
    # 一条评论里有两个评审标记时无法判定次数，不作为候选（与「契约标记必须唯一」同一个原则）
    | map(select((._runs | length) == 1))
    | map(. + {run: ._runs[0], _author: author_name} | del(._runs))
    | . as $cands
    | ([$cands[] | ._author] | unique) as $authors
    | if ($cands | length) == 0 then {status: "none"}
      elif $bot == "" then
        {status: "no-identity",
         inferred: (if ($authors | length) == 1 then $authors[0] else "" end),
         authors: $authors}
      else
        ([$cands[] | select(._author == $bot)] | sort_by(.run) | last) as $sel
        | if $sel == null then {status: "none"} else {status: "ok", comment: ($sel | del(._author))} end
      end' 2>/dev/null) \
    || { echo "review_select_prior_comment: 评论列表不是合法 JSON，按「未找到」处理" >&2; return 1; }
  status=$(printf '%s' "$out" | jq -r '.status // ""')
  case "$status" in
    ok)
      printf '%s' "$out" | jq -c '.comment'
      return 0 ;;
    no-identity)
      inferred=$(printf '%s' "$out" | jq -r '.inferred // ""')
      echo "review_select_prior_comment: 未配置 CODEUP_BOT_USERNAME、令牌身份接口也不可用，不以「带评审标记的评论作者」作为原地更新依据（评审标记可被任何 MR 参与者复制，那样就会把报告写进别人的评论）" >&2
      [[ -n "$inferred" ]] \
        && echo "review_select_prior_comment: 带评审标记的评论作者是 ${inferred}——若确认那是本评审员的机器人账号，把它配进 CODEUP_BOT_USERNAME 即可启用原地更新" >&2
      return 3 ;;
    *) return 1 ;;
  esac
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
  _RR_DIFF_NOTE=""; _RR_RUN=1; _RR_INLINE=0; _RR_REASON=""; _RR_HISTORY=""; _RR_LOG_HINT=""
  _RR_NOTICE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json|--text|--sha|--src|--dst|--ts|--diff-note|--run|--inline-comment|--reason|--history|--log-hint|--notice)
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
          --history) _RR_HISTORY="$2" ;;
          --log-hint) _RR_LOG_HINT="$2" ;;
          --notice) _RR_NOTICE="$2" ;;
        esac
        shift 2 ;;
      *) echo "review 渲染：未知参数：$1" >&2; return 2 ;;
    esac
  done
  local v
  for v in _RR_SHA _RR_SRC _RR_DST _RR_TS _RR_DIFF_NOTE; do
    [[ -n "${!v}" ]] || { echo "review 渲染：缺少必填参数 --$(echo "${v#_RR_}" | tr 'A-Z_' 'a-z-')" >&2; return 2; }
  done
  [[ "$_RR_RUN" =~ ^[0-9]+$ && "$_RR_RUN" -ge 1 ]] || { echo "review 渲染：默认 --run 必须是 ≥1 的整数（实际：${_RR_RUN}）" >&2; return 2; }
  # --history 拼错路径不能静默按「无历史」渲染：那会把历次表悄悄清空，而评论上看不出异常
  [[ -z "$_RR_HISTORY" || -r "$_RR_HISTORY" ]] \
    || { echo "review 渲染：--history 指定的历史文件不可读：${_RR_HISTORY}" >&2; return 2; }
}

# --- 内部：追加后的历次记录必须是合法 JSON 数组 ---
# 两个渲染函数都被调用方写成 `review_render_… || die_review …`，而 `||` 会让整个函数体不受 errexit
# 约束：review_history_append 万一失败（jq 报错、--history 内容不合法），历史文件会是空的，
# 渲染出来的评论带一行 `<!-- kiro-history: -->` 与一张空表，而调用方看到的仍是退出码 0。
# 所以在这里显式拦一次：宁可整条评论渲染失败（调用方回写「评审未完成」），也不发一条坏掉的汇总。
# -s（读成数组后判断「恰好一个」）：不带 -s 时 jq 逐个 JSON 值套用过滤器、退出码取最后一个，
# 于是 `[…]\n[]` 这种「两个值」的文件会输出 true true 且退出 0——正是本守卫要拦的那种损坏。
_review_history_ok() {
  jq -e -s 'length == 1 and (.[0] | type == "array")' "$1" >/dev/null 2>&1 \
    || { echo "$2: 历次记录渲染失败（review_history_append 未产出恰好一个 JSON 数组）" >&2; return 1; }
}

# --- 历次记录的隐藏 JSON（下一次评审的解析入口）---
# 用法：review_render_history_marker <历史 JSON 文件>
# 刻意紧跟评审标记放在评论开头：MAX_COMMENT_BYTES 的截断是从尾部砍的，放在末尾的话
# 一条超长评论被截断之后，下一次评审就再也读不回历史了。
review_render_history_marker() {
  printf '%s%s%s\n' "$REVIEW_HISTORY_PREFIX" "$(jq -c '.' "$1")" "$REVIEW_HISTORY_SUFFIX"
}

# --- 「历次评审」折叠区（人类可读投影；spec §4.3）---
# 用法：review_render_history_table <历史 JSON 文件>
# 结论的中文化复用 _review_verdict_cn（不在 jq 里再写一份映射），所以行渲染走 bash 循环：
# 历史最多 REVIEW_HISTORY_MAX 行，成本可忽略。
review_render_history_table() {
  local hist="$1" n run sha status verdict p0 p1 p2 label
  n=$(jq -r 'length' "$hist")
  echo "<details><summary>历次评审（${n}）</summary>"
  echo ""
  echo "| 次 | 提交 | 结论 | P0/P1/P2 |"
  echo "|---|---|---|---|"
  # 分隔符用 \x1f 而不是制表符：制表符属于 IFS 空白，bash 会把连续分隔符并成一个，
  # status 或 verdict 为空串时字段就整体错位（实测把 verdict 读成了计数）。
  while IFS=$'\x1f' read -r run sha status verdict p0 p1 p2; do
    case "$status" in
      failed)   label="评审未完成" ;;
      degraded) label="结构化解析失败" ;;
      *)        label=$(_review_verdict_cn "$verdict") ;;
    esac
    printf '| %s | `%s` | %s | %s/%s/%s |\n' "$run" "$sha" "$label" "$p0" "$p1" "$p2"
  done < <(jq -r --arg sep "$(printf '\037')" '.[] | [ (.run | tostring), (.sha // ""), (.status // ""), (.verdict // ""),
                          (if .p0 == null then "-" else (.p0 | tostring) end),
                          (if .p1 == null then "-" else (.p1 | tostring) end),
                          (if .p2 == null then "-" else (.p2 | tostring) end) ] | join($sep)' "$hist")
  echo "</details>"
}

# --- 页脚（第 N 次评审 + 图例 + 重新评审提示）---
# 用法：review_render_footer <run>（公开：kiro-review.sh 的失败评论也要用同一份页脚）
review_render_footer() {
  echo "---"
  printf '第 %s 次评审 · P0 必须修复 · P1 应当修复 · P2 可选改进 · 评论 `/kiro review` 可重新评审\n' "$1"
}

# --- 内部：评论头（标题 + 评审标记 + 历史标记 + 元信息表）---
# $2 = 历史 JSON 文件（已含本次那一行）
_review_render_header() {
  local title="$1" hist="$2"
  echo "$title"
  echo "<!-- kiro-review:${_RR_SHA} run:${_RR_RUN} -->"
  review_render_history_marker "$hist"
  echo ""
  echo "| Commit | 分支 | 时间 | diff |"
  echo "|---|---|---|---|"
  echo "| \`${_RR_SHA}\` | \`${_RR_SRC}\` → \`${_RR_DST}\` | ${_RR_TS} | ${_RR_DIFF_NOTE} |"
}

# --- 折叠区（INLINE_COMMENT=1；spec §4.3）---
# 小节标题里的级别列表按实际内容生成，而不是写死 spec 模板里的字面量：
#   - 档位桶在 quiet 下就是 P2（渲染成 `#### P2 建议（n）`，与 spec 模板一致），
#     但在 critical 下还包含 P1——写死「P2 建议」会把 P1 问题标成 P2，那是改写评审员的判级。
#   - 超限桶在 quiet 下是 P0/P1（与 spec 模板一致），balanced 下可能含 P2。
# _review_render_fold_section <计划文件> <标题模板> <桶名> <是否未定位桶 0|1>
# 标题模板里的 `{levels}` 会替换成该桶里实际出现的级别列表（`P0/P1`）。替换刻意放在
# 「桶为空就直接返回」之后：空桶时那个标题根本不会渲染，先算它等于白跑一个 jq。
_review_render_fold_section() {
  local plan="$1" title="$2" bucket="$3" unloc="${4:-0}" n
  n=$(jq -r --arg b "$bucket" '(.folded[$b] // []) | length' "$plan")
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || return 0
  if [[ "$title" == *'{levels}'* ]]; then
    title="${title//\{levels\}/$(_review_fold_levels "$plan" "$bucket")}"
  fi
  echo ""
  printf '#### %s（%s）\n' "$title" "$n"
  echo ""
  # body 首句：取第一个「非空且不是代码围栏」的行，句号处截断，再按 120 字符封顶。
  # 折叠区是「一眼扫过去」的清单，整段 body（可能带代码块）会把折叠区撑成第二份报告。
  # 跳过围栏行是必需的：评审员的 body 很常以 ```python 开头，取到那一行的话这个条目
  # 就只剩一串反引号、什么信息都没有。
  # 反引号还要再处理两道，否则这一行会把后面的条目一起吞掉：
  #   ① 连续 2 个以上的反引号折叠成 1 个——`​``​` 这种 3 连是 Markdown 的行内代码定界符，
  #      它会一直找下一个 3 连来配对，于是两个条目之间的定位串与标题全被吃进代码span；
  #   ② 折叠后若反引号个数为奇数（120 字符封顶很容易切在代码span中间），末尾补一个闭合。
  jq -r --arg b "$bucket" --arg unloc "$unloc" '
    def _lines: (. // "") | split("\n");
    # 整段代码围栏（含围栏内的代码行）都不算「说明」：取到围栏内的第一行代码同样什么都说明不了
    def _outside_fence:
      _lines
      | reduce .[] as $l ({fence: false, out: []};
          if ($l | test("^[[:space:]]{0,3}(```|~~~)")) then {fence: (.fence | not), out: .out}
          elif .fence then .
          else {fence: .fence, out: (.out + [$l])} end)
      | .out;
    def firstsent:
      (_outside_fence | map(select(test("[^[:space:]]"))) | (.[0] // "")) as $outside
      # 整段 body 就是一个代码块时退回「围栏外没有、就取围栏内第一行」，总比留一个空说明好
      | (if ($outside | length) > 0 then $outside
         else (_lines
               | map(select(test("[^[:space:]]") and (test("^[[:space:]]{0,3}(```|~~~)") | not)))
               | (.[0] // "")) end) as $l
      | ($l | sub("^[[:space:]]+"; "")) as $t
      | ($t | index("。")) as $i
      | (if $i != null then $t[0:$i + 1] else $t end) as $s0
      | (if ($s0 | length) > 120 then $s0[0:120] + "…" else $s0 end) as $s1
      | ($s1 | gsub("`{2,}"; "`")) as $s
      | if ((($s | split("`") | length) - 1) % 2) == 1 then $s + "`" else $s end;
    def loc:
      if .file == null then "（未定位）"
      elif $unloc == "1" then "`\(.file)`（无法定位到变更行）"
      elif .line_start == null then "`\(.file)`"
      elif (.line_end != null and .line_end > .line_start) then "`\(.file):\(.line_start)-\(.line_end)`"
      else "`\(.file):\(.line_start)`" end;
    (.folded[$b] // [])[]
    | "- \(loc) **\(.title)** — \(.body | firstsent)"' "$plan"
}

# 档位桶/超限桶里实际出现的级别，升序连成 `P0/P1`
_review_fold_levels() {
  jq -r --arg b "$2" '[(.folded[$b] // [])[] | .severity] | unique
                      | sort_by({"P0":0,"P1":1,"P2":2}[.] // 3) | join("/")' "$1"
}

# _review_render_folded <计划文件>：折叠区整块（为空时整体省略，不发一个空折叠块）
_review_render_folded() {
  local plan="$1" n
  n=$(jq -r '.folded_count // 0' "$plan")
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || return 0
  echo ""
  printf '<details><summary>折叠区：未展开的问题（%s）</summary>\n' "$n"
  _review_render_fold_section "$plan" '{levels} 建议'          profile   0
  _review_render_fold_section "$plan" '超出行内上限的 {levels}' overflow  0
  _review_render_fold_section "$plan" '未定位问题'              unlocated 1
  _review_render_fold_section "$plan" '行内发布失败'            failed    0
  echo "</details>"
}

# --- 汇总评论 ---
# 用法：review_render_summary --json <契约 JSON 文件> --sha X --src A --dst B \
#                            --ts "YYYY-mm-dd HH:MM:SS" --diff-note N [--run 1] \
#                            [--inline-comment 0|1] [--history …] [--notice "一句话"]
# INLINE_COMMENT=0（spec §4.3 的 0 变体）：问题清单**完整展开**、不用折叠区、不提行内计数，
#   观感对齐 v1（I7：默认关闭 = 观感不变）。--json 收 review_validate 的输出。
# INLINE_COMMENT=1（spec §4.3、§4.5 第 8 步）：明细已经作为行内评论挂在「文件改动」对应行上，
#   汇总退化为状态面板——统计行注明已标注到行的条数，未发行内的问题进折叠区。
#   --json 必须收 review_plan_inline（经 review_plan_apply_outcomes 回填）的输出：
#   拿 review_validate 的输出硬渲染会得到一条「什么都没有折叠区、看不出行内发了几条」的评论。
# --notice：一句话警告，渲染成统计行下方的引用块。行内评论整体发不出去时由调用方回落到
#   INLINE_COMMENT=0 渲染并带上原因——阿里云侧开发者看不到流水线日志（I10 失败可见）。
review_render_summary() {
  _review_parse_render_args "$@" || return $?
  [[ -n "$_RR_JSON" ]] || { echo "review_render_summary: 缺少必填参数 --json" >&2; return 2; }
  [[ -r "$_RR_JSON" ]] || { echo "review_render_summary: 契约 JSON 不可读：${_RR_JSON}" >&2; return 2; }
  if [[ "$_RR_INLINE" != "0" && "$_RR_INLINE" != "1" ]]; then
    echo "review_render_summary: INLINE_COMMENT=${_RR_INLINE} 不是 0 或 1，拒绝渲染（静默按 0 渲染会让开关看起来生效了）" >&2
    return 3
  fi

  # --json 必须是 review_validate 的输出。不校验的话：空文件/非 JSON 会让每个 jq -r 都吐空串，
  # 渲染出一条「结论：评审员未给出结论 / P0 · P1 · P2 全空 / 问题清单里什么也没有」的空壳评论并返回 0；
  # 缺 dropped_findings 时 `[[ "$dropped" -gt 0 ]]` 还会在 set -u 下直接崩（null: unbound variable）。
  jq -e '(type == "object")
         and ((.dropped_findings | type) == "number")
         and ((.delocated_findings | type) == "number")
         and ((.findings | type) == "array")' "$_RR_JSON" >/dev/null 2>&1 \
    || { echo "review_render_summary: --json 不是 review_validate 的输出（需要对象 + 数值 dropped_findings/delocated_findings + 数组 findings）：${_RR_JSON}" >&2; return 2; }
  # INLINE_COMMENT=1 还需要发布计划的字段：缺了就说明调用方没走 review_plan_inline，
  # 硬渲染只会得到一条没有折叠区、行内计数恒为 0 的评论——那比报错更难发现。
  if [[ "$_RR_INLINE" == "1" ]]; then
    jq -e '((.inline | type) == "array") and ((.folded | type) == "object")
           and ((.folded.profile | type) == "array") and ((.folded.overflow | type) == "array")
           and ((.folded.unlocated | type) == "array") and ((.folded.failed | type) == "array")
           and ((.inline_count | type) == "number") and ((.folded_count | type) == "number")' \
       "$_RR_JSON" >/dev/null 2>&1 \
      || { echo "review_render_summary: --inline-comment 1 需要 review_plan_inline 的输出（缺 inline/folded/inline_count/folded_count 字段）：${_RR_JSON}" >&2; return 2; }
  fi

  local summary verdict verdict_cn verdict_reason dropped delocated n0 n1 n2 total stat hist
  summary=$(jq -r '.summary // ""' "$_RR_JSON")
  verdict=$(jq -r '.verdict // ""' "$_RR_JSON")
  verdict_reason=$(jq -r '.verdict_reason // ""' "$_RR_JSON")
  dropped=$(jq -r '.dropped_findings' "$_RR_JSON")
  delocated=$(jq -r '.delocated_findings' "$_RR_JSON")
  total=$(jq -r '.findings | length' "$_RR_JSON")
  n0=$(jq -r '[.findings[] | select(.severity == "P0")] | length' "$_RR_JSON")
  n1=$(jq -r '[.findings[] | select(.severity == "P1")] | length' "$_RR_JSON")
  n2=$(jq -r '[.findings[] | select(.severity == "P2")] | length' "$_RR_JSON")
  verdict_cn=$(_review_verdict_cn "$verdict")

  # 历次记录：把本次这一行追加到 --history 给的旧记录上。由渲染器统一追加（而不是让调用方传全量），
  # 保证表格里的本次那一行与评审标记里的 run:N、与统计行的计数永远出自同一份输入。
  hist=$(mktemp)
  review_history_append "${_RR_HISTORY:--}" "$_RR_RUN" "$_RR_SHA" "$verdict" "" "$n0" "$n1" "$n2" > "$hist"
  _review_history_ok "$hist" review_render_summary || { rm -f "$hist"; return 2; }

  _review_render_header "## 🤖 Kiro 代码评审" "$hist"
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
  stat="P0 ${n0} · P1 ${n1} · P2 ${n2}"
  # INLINE_COMMENT=1：注明其中多少条已经作为行内评论挂在「文件改动」对应行上（spec §4.3）。
  # 这个数只算「真的在那一行上」的：本次新发的 + 指纹命中已存在的；发布失败的不算（它们在折叠区）。
  [[ "$_RR_INLINE" == "1" ]] \
    && stat="${stat} —— 其中 $(jq -r '.inline_count' "$_RR_JSON") 条已标注在「文件改动」对应行"
  [[ "$dropped" -gt 0 ]] && stat="${stat}（另有 ${dropped} 条不合契约已丢弃）"
  [[ "$delocated" -gt 0 ]] && stat="${stat}（${delocated} 条的文件路径不合规，已按未定位处理）"
  echo "$stat"
  if [[ -n "$_RR_NOTICE" ]]; then
    echo ""
    # 取值由脚本自己拼（可能带 HTTP 状态码之类），仍过一遍结构清洗：评论的结构只能来自渲染器
    printf '> ⚠️ '
    printf '%s' "$_RR_NOTICE" | review_sanitize_md
    echo ""
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

  if [[ "$_RR_INLINE" == "1" ]]; then
    # 明细由行内评论承载：汇总里不再展开问题清单，否则同一条问题在 MR 上出现两次（违反 I4）
    if [[ "$total" == "0" ]]; then
      echo ""
      echo "未发现明显问题。"
    fi
    _review_render_folded "$_RR_JSON"
    echo ""
    review_render_history_table "$hist"
    rm -f "$hist"
    echo ""
    review_render_footer "$_RR_RUN"
    return 0
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
  review_render_history_table "$hist"
  rm -f "$hist"
  echo ""
  review_render_footer "$_RR_RUN"
}

# --- 超长评论的截断（Codeup 的 content 有长度上限）---
# 用法：review_truncate_comment <评论文件（就地改写）> <字节上限>
#   rc 0 = 已截断并追加提示；rc 1 = 未超限（文件不变）；rc 2 = 用法错误
# 放在库里而不是内联在 kiro-review.sh：这段逻辑的正确性取决于「切在哪个字节上」，
# 只有能在库层面对几十个截断窗口做扫描式回归，才谈得上验证过（见 tests/test-review-render.sh）。
review_truncate_comment() {
  local file="$1" max="$2" size dir had_marker
  [[ -r "$file" ]] || { echo "review_truncate_comment: 文件不可读：${file}" >&2; return 2; }
  [[ "$max" =~ ^[0-9]+$ && "$max" -ge 1 ]] || { echo "review_truncate_comment: 字节上限必须是 ≥1 的整数（实际：${max}）" >&2; return 2; }
  size=$(wc -c < "$file" | tr -d ' ')
  [[ "$size" -gt "$max" ]] || return 1
  # 截断前记下有没有评审标记：截断是从尾部砍的，标记在开头，正常情况一定保得住；
  # 但上限小到连头部都放不下时会截出一份没有标记的残片，而调用方随后会把它 PUT 到上一条汇总上。
  had_marker=0
  grep -qE "$REVIEW_MARKER_LINE_RE" "$file" && had_marker=1
  dir=$(mktemp -d)
  head -c "$max" "$file" > "$dir/cut"
  # **先退到最后一个完整行**（丢掉那半行），再做任何补齐：
  #   ① 半行会让后面追加的闭合围栏/闭合标签接在半行后面，而它们不在行首就不起作用
  #      （实测截断后得到的是 `    row_2 = fetc``` `，围栏没闭合）；
  #   ② 半个标签（切在 `<deta|ils>` 或 `</d|etails>` 中间）会让行首标签计数判断错——
  #      对 golden summary-full.md，1730 与 1882 这两个上限正好落在这两处；
  #   ③ 行边界不会落在多字节字符中间，所以退到完整行同时消掉了「截出半个 UTF-8 字符」。
  # awk 逐行打印时把最后一条记录留在 prev 不输出，正好等于「丢掉末尾那半行」，且输出以换行结尾。
  if [[ $(tail -c1 "$dir/cut" | wc -l | tr -d ' ') -eq 1 ]]; then
    cp "$dir/cut" "$dir/out"
  else
    awk 'NR > 1 { print prev } { prev = $0 }' "$dir/cut" > "$dir/out"
  fi
  # iconv 只作兜底（清掉输入本身可能带的非法字节），且**只看输出是否可用，不看退出码**：
  # 实测（macOS）`iconv -f UTF-8 -t UTF-8 -c` 对「EOF 处不完整的字符」以 1 退出，同时照样写出
  # 清理好的前缀。原先写成 `head -c … | iconv -c || head -c …`，这个回退恰好在 iconv 清理成功时
  # 触发，把干净结果覆盖回带半个字符的原文，评论末尾就出现 U+FFFD。
  iconv -f UTF-8 -t UTF-8 -c < "$dir/out" > "$dir/iconv" 2>/dev/null || true
  if [[ -s "$dir/iconv" || ! -s "$dir/out" ]]; then
    mv "$dir/iconv" "$dir/out"
  else
    rm -f "$dir/iconv"
  fi
  # 空文件（上限小于第一行）时补一个换行，保证后面追加的内容仍在行首
  [[ $(tail -c1 "$dir/out" | wc -l | tr -d ' ') -eq 1 ]] || printf '\n' >> "$dir/out"
  # fix 字段里会带 ```代码块```：截断点落在围栏中间时，随后追加的截断提示会被 Markdown 当成
  # 代码块内容渲染掉，读者只看到评论突然结束、完全看不到「已截断」。所以先补闭合围栏，再写提示。
  if [[ $(( $(grep -c '^```' "$dir/out" || true) % 2 )) -eq 1 ]]; then
    echo '```' >> "$dir/out"
  fi
  # 同理对「历次评审」折叠区：截断点落在 <details> 里面时，未闭合的标签会把随后追加的截断提示
  # 一起吞进折叠块（甚至吞掉页脚）。补齐缺的闭合标签，提示才落在折叠块外面。
  # 只数**行首**的标签：脚本渲染的折叠块都是行首整行，而模型文本里的折叠标签已被 _sanitize_md
  # （大小写不敏感地）转义成 `&lt;details`——所以这里数到的一定是脚本自己的标签。用无锚点的 grep
  # 会把模型原文引用的 `</details>` 也算进闭合数，于是该补的时候反而不补。
  # 计数用 -i：HTML 标签名不区分大小写。
  local det_open det_close
  det_open=$(grep -ci '^<details' "$dir/out" || true)
  det_close=$(grep -ci '^</details>[[:space:]]*$' "$dir/out" || true)
  while [[ "$det_open" -gt "$det_close" ]]; do
    echo '</details>' >> "$dir/out"
    det_close=$((det_close + 1))
  done
  {
    echo ""
    echo "> ⚠️ 报告超长已截断（上限 ${max} 字节），完整内容见流水线日志。"
  } >> "$dir/out"
  # 硬守卫：截断结果里必须还留着评审标记。丢了标记的残片一旦被 PUT 上去，
  #   ① 上一次的完整报告与隐藏的历次记录当场不可恢复地消失；
  #   ② 下一次评审再也定位不到这条评论，会在 MR 上新建第二条汇总（违反 I4）。
  # 宁可让截断失败（调用方回写失败评论，形态完整、历史仍在），也不发这种残片。
  if [[ "$had_marker" == "1" ]] && ! grep -qE "$REVIEW_MARKER_LINE_RE" "$dir/out"; then
    echo "review_truncate_comment: 上限 ${max} 字节太小，截断后连评审标记都没了——拒绝截断（那份残片会覆盖掉上一条汇总的全部内容与历次记录）。请调大 MAX_COMMENT_BYTES" >&2
    rm -rf "$dir"
    return 3
  fi
  cp "$dir/out" "$file"
  rm -rf "$dir"
  return 0
}

# --- 疑似密钥的脚本侧掩码（stdin → stdout）---
# 只用在降级路径上。正常路径的掩码由评审员按 agent 提示词完成（前 4 后 4），但降级恰恰意味着
# 评审员没有遵守输出契约——此时再假设它遵守了掩码规则是不成立的，而降级评论会把原文整段贴到
# 组织内可见的 MR 上。所以这里按已知凭证形态做一次脚本侧掩码。
# 掩码规则与提示词一致：长度 ≥ 12 保留前 4 后 4，其余整体替换为 ****。
#
# 精度要求（R7）：降级评论正是人要**手读**的那一份。早先的 key=value 规则只看键名，把
#   `password: os.environ.get("PW")`、`token = request.headers.get("Authorization")`、
#   `private_key=/etc/ssl/private/server.key`
# 一并掩成乱码——这些是表达式和路径，不是凭证，掩掉只会让人读不懂而毫无安全收益。
# 所以 key=value 只对「看起来像字面量凭证」的取值生效：引号里的字符串，或不含调用/属性访问/
# 路径特征的高熵 token。有明确前缀的形态（AWS/GitHub/Slack/JWT/PEM/Bearer/URL 内嵌凭证）另走白名单，
# 不受这条限制。
review_redact_secrets() {
  LC_ALL=C awk '
    # 注意：本函数整体在 LC_ALL=C 下运行（按字节），所以**所有取值的字符类都必须是显式 ASCII 白名单**，
    # 不能用 [^…] 这种否定类——中文标点等高位字节不属于 [[:space:]]/[[:punct:]]，取值会一路吞进中文正文，
    # 掩码还会从多字节字符中间切断（输出 U+FFFD）。
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
    # 取值像不像「字面量凭证」。排除表达式与路径，避免把可读的代码掩成乱码。
    function looks_literal(v) {
      if (length(v) < 12) return 0
      if (v ~ /[(){}$<>[:space:]]/) return 0            # 函数调用 / 变量展开 / 模板
      if (v ~ /^[\/.~\-]/) return 0                      # 绝对路径、./ 相对路径、~/、选项
      if (v ~ /[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_]/) return 0  # 属性访问（os.environ、server.key）
      if (v ~ /[0-9]/) return 1                          # 含数字：当作高熵
      if (v ~ /[a-z]/ && v ~ /[A-Z]/) return 1           # 大小写混合：当作高熵
      return 0
    }
    # 形如 SECRET_KEY = "xxx" / token: xxx 的赋值：只掩码取值部分，保留键名（键名是排查线索）
    # 大小写不敏感靠 tolower 副本定位——tolower 不改变长度，下标可以直接套回原串
    function redact_assign(line,   lo, out, seg, vstart, val, i, ch) {
      out = ""
      while (1) {
        lo = tolower(line)
        if (match(lo, /(secret|token|passwd|password|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|credential)[a-z0-9_-]*[[:space:]]*[:=][[:space:]]*"?'"'"'?[A-Za-z0-9._~+\/=-]+/) == 0) break
        seg = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1)
        line = substr(line, RSTART + RLENGTH)
        vstart = 0
        for (i = length(seg); i >= 1; i--) {
          ch = substr(seg, i, 1)
          if (ch == ":" || ch == "=") { vstart = i + 1; break }
        }
        if (vstart == 0) { out = out seg; continue }
        while (vstart <= length(seg) && substr(seg, vstart, 1) ~ /[[:space:]"'"'"']/) vstart++
        val = substr(seg, vstart)
        if (looks_literal(val)) out = out substr(seg, 1, vstart - 1) mask(val)
        else                    out = out seg
      }
      return out line
    }
    # Authorization: Bearer <token> / Authorization: Basic <b64>：掩码方案后面的那一段
    function redact_bearer(line,   lo, out, seg, p, val) {
      out = ""
      while (1) {
        lo = tolower(line)
        if (match(lo, /(bearer|basic)[[:space:]]+[A-Za-z0-9._~+\/=-]{8,}/) == 0) break
        seg = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1)
        line = substr(line, RSTART + RLENGTH)
        p = match(seg, /[[:space:]]+/)
        val = substr(seg, p + RLENGTH)
        out = out substr(seg, 1, p + RLENGTH - 1) mask(val)
      }
      return out line
    }
    # 自定义令牌头（云效令牌走这条：x-yunxiao-token: xxx）
    function redact_header(line,   lo, out, seg, vstart, val, i, ch) {
      out = ""
      while (1) {
        lo = tolower(line)
        if (match(lo, /(x-yunxiao-token|x-api-key|x-auth-token|private-token|authorization)[[:space:]]*:[[:space:]]*[A-Za-z0-9._~+\/=-]+/) == 0) break
        seg = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1)
        line = substr(line, RSTART + RLENGTH)
        vstart = index(seg, ":") + 1
        while (vstart <= length(seg) && substr(seg, vstart, 1) ~ /[[:space:]]/) vstart++
        val = substr(seg, vstart)
        # 值本身是 Bearer/Basic 方案时交给 redact_bearer，别把方案名掩掉
        if (tolower(val) ~ /^(bearer|basic)/) out = out seg
        else out = out substr(seg, 1, vstart - 1) mask(val)
      }
      return out line
    }
    # URL 内嵌凭证 scheme://user:pass@host：只掩 pass
    function redact_url(line,   out, seg, p, q, user, pass) {
      out = ""
      while (match(line, /[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[A-Za-z0-9._~+-]+:[A-Za-z0-9._~+\/=%-]+@/) > 0) {
        seg = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1)
        line = substr(line, RSTART + RLENGTH)
        p = index(seg, "://") + 3
        q = index(substr(seg, p), ":")
        user = substr(seg, p, q - 1)
        pass = substr(seg, p + q, length(seg) - (p + q))   # 去掉结尾的 @
        out = out substr(seg, 1, p - 1) user ":" mask(pass) "@"
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
      pat[++n] = "eyJ[0-9A-Za-z_-]{8,}\\.[0-9A-Za-z_-]{8,}\\.[0-9A-Za-z_-]{8,}" # JWT
    }
    # PEM 私钥整块屏蔽：这种内容没有「保留前 4 后 4」的意义
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/ { inpem = 1; print "**** （脚本已屏蔽一段 PRIVATE KEY 内容）"; next }
    inpem && /-----END [A-Z ]*PRIVATE KEY-----/ { inpem = 0; next }
    inpem { next }
    {
      line = $0
      for (i = 1; i <= n; i++) line = redact(line, pat[i])
      line = redact_url(line)
      line = redact_bearer(line)
      line = redact_header(line)
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
  local hist
  # 降级时没有可信的分级计数（正是因为解析失败），历次表这一行记 status=degraded、计数为 -
  hist=$(mktemp)
  review_history_append "${_RR_HISTORY:--}" "$_RR_RUN" "$_RR_SHA" "" degraded - - - > "$hist"
  _review_history_ok "$hist" review_render_degraded || { rm -f "$hist"; return 2; }
  _review_render_header "## 🤖 Kiro 代码评审 · ⚠️ 结构化解析失败" "$hist"
  echo ""
  echo "> ⚠️ 评审已完成，但输出不符合结构化契约（${_RR_REASON:-未说明原因}），无法给出分级问题清单与统计。"
  echo "> 下面是评审员输出的原文（已由脚本对疑似凭证再做一次掩码，并把其中的 Markdown 标题、分隔线与"
  echo "> HTML 注释降级为普通文本——评论的结构只能来自脚本，否则原文里可以伪造标题与评审标记）。"
  echo "> 重跑评审（评论 \`/kiro review\`）通常可恢复结构化输出。"
  echo ""
  echo "---"
  echo ""
  review_redact_secrets < "$_RR_TEXT" | review_sanitize_md
  echo ""
  review_render_history_table "$hist"
  rm -f "$hist"
  echo ""
  review_render_footer "$_RR_RUN"
}

# --- 失败评论：评审没跑完时唯一能到达 MR 的信息通道（spec I10 失败可见）---
# 用法：review_render_failure --reason <失败说明> --sha X --src A --dst B --ts T --diff-note N
#                            [--run N] [--history <历史 JSON 文件>] [--log-hint <一句话>]
# 与成功/降级评论**同形**：标题、评审标记、历史标记、元信息表、历次表、页脚全部出自同一份代码。
# 早先这段是在 kiro-review.sh 里手写第二份的，结果是「形态一致」这个不变量靠人肉维护，
# 而给两个渲染函数加的历次记录守卫漏掉了第三份拷贝。
# 本函数刻意**不因历次记录异常而失败**：历史算不出来就退化成「只有本次一行」，
# 绝不能出现「评审失败 + 失败评论也发不出去」的组合。
# --reason 里可能带上 runFinished.status 之类来自事件流的取值（不受信），所以过一遍结构清洗。
review_render_failure() {
  _review_parse_render_args "$@" || return $?
  [[ -n "$_RR_REASON" ]] || { echo "review_render_failure: 缺少必填参数 --reason" >&2; return 2; }
  local hist
  hist=$(mktemp)
  review_history_append "${_RR_HISTORY:--}" "$_RR_RUN" "$_RR_SHA" "" failed - - - > "$hist" 2>/dev/null || true
  _review_history_ok "$hist" review_render_failure \
    || review_history_append - "$_RR_RUN" "$_RR_SHA" "" failed - - - > "$hist" 2>/dev/null || true
  _review_history_ok "$hist" review_render_failure || printf '[]\n' > "$hist"
  _review_render_header "## 🤖 Kiro 代码评审 · ⚠️ 评审未完成" "$hist"
  echo ""
  printf '⚠️ 评审未完成：'
  printf '%s' "$_RR_REASON" | review_sanitize_md
  echo ""
  if [[ -n "$_RR_LOG_HINT" ]]; then
    echo ""
    printf '%s' "$_RR_LOG_HINT" | review_sanitize_md
    echo ""
  fi
  echo ""
  review_render_history_table "$hist"
  rm -f "$hist"
  echo ""
  review_render_footer "$_RR_RUN"
}
