#!/usr/bin/env bash
# scripts/lib/review-render.sh 的单元测试：stream-json 提取、契约校验、汇总评论渲染（golden file）。
# 渲染是纯函数：sha/分支/时间戳/diff 说明/评审次数全部由参数传入，所以 golden 可逐字节比对。
# golden 更新必须有意为之：GOLDEN_UPDATE=1 bash tests/test-review-render.sh 会重写 tests/fixtures/golden/，
# 重写后必须人工读 diff 并在提交信息里说明改了什么、为什么。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
ROOT=$(cd .. && pwd)
source "$ROOT/scripts/lib/review-render.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

GOLDEN=fixtures/golden
# assert_golden <实际文件> <golden 文件名> <说明>
assert_golden() {
  local actual="$1" name="$2" desc="$3" expect="$GOLDEN/$2"
  if [[ "${GOLDEN_UPDATE:-0}" == "1" ]]; then
    cp "$actual" "$expect"; echo "GOLDEN UPDATED: $expect" >&2
  fi
  if [[ ! -f "$expect" ]]; then
    echo "FAIL: $desc — golden 文件不存在：${expect}（确认渲染正确后用 GOLDEN_UPDATE=1 生成）" >&2; exit 1
  fi
  if diff -u "$expect" "$actual" >"$tmp/golden.diff" 2>&1; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $desc — 与 golden 不一致（${expect}）：" >&2
    cat "$tmp/golden.diff" >&2
    exit 1
  fi
}

# make_stream <输出文件> <finalText> [status] [flags...]
#   flags: no-runfinished | no-metadata | noise
# 事件形态照抄真实 kiro-cli 2.21 v2 输出（见 fixtures/stream/real-shape.jsonl 与
# .scratch/.../probe-results/kiro-headless/*/out.jsonl）：runStarted / sessionUpdate / metadata / runFinished。
make_stream() {
  local out="$1" final="$2" status="${3:-success}"; shift 3 2>/dev/null || shift $#
  local flags=" $* "
  local sid="6fa61ba1-1c6d-432d-9892-fb5b6d0e876b"
  {
    jq -nc '{type:"runStarted",data:{payloadSchema:"acp",acpProtocolVersion:1,engine:"v2"}}'
    jq -nc --arg s "$sid" '{type:"sessionUpdate",data:{sessionId:$s,update:{sessionUpdate:"tool_call",toolCallId:"call_1",title:"Reading app.py:1-2000",kind:"read",locations:[{path:"src/app.py"}],_meta:{kiro:{toolName:"read"}}}}}'
    jq -nc --arg s "$sid" '{type:"sessionUpdate",data:{sessionId:$s,update:{sessionUpdate:"agent_message_chunk",content:{type:"text",text:"<<<"}}}}'
    [[ "$flags" == *" noise "* ]] && echo 'kiro-cli: warning: this line is not JSON'
    if [[ "$flags" != *" no-metadata "* ]]; then
      jq -nc --arg s "$sid" '{type:"metadata",data:{sessionId:$s,contextUsagePercentage:1.1242647171020508}}'
      jq -nc --arg s "$sid" '{type:"metadata",data:{sessionId:$s,contextUsagePercentage:3.7519,meteringUsage:[{value:0.0669794503482587,unit:"credit",unitPlural:"credits"},{value:0.19391594945273632,unit:"credit",unitPlural:"credits"}],turnDurationMs:10134}}'
    fi
    if [[ "$flags" != *" no-runfinished "* ]]; then
      jq -nc --arg s "$sid" --arg st "$status" --arg f "$final" \
        '{type:"runFinished",data:{sessionId:$s,status:$st,stopReason:"end_turn",finalText:$f,finalTextTruncated:false}}'
    fi
  } > "$out"
}

CONTRACT_FULL=$(cat fixtures/contract/full.json)
wrap() { printf '好的，我已完成评审。\n\n<<<KIRO_REVIEW_JSON>>>\n%s\n<<<END_KIRO_REVIEW_JSON>>>\n' "$1"; }

# ============ review_clean_text：剥离 ANSI ============
esc=$(printf '\033')
out=$(printf '%s[38;5;141mReading%s[0m 报告正文\n' "$esc" "$esc" | review_clean_text)
assert_eq "$out" "Reading 报告正文" "clean_text：剥离 ANSI 色码保留正文"
assert_not_contains "$out" "$esc[" "clean_text：输出不含 ESC 序列"
out=$(printf '普通文本\n第二行\n' | review_clean_text)
assert_eq "$out" "$(printf '普通文本\n第二行')" "clean_text：无 ANSI 时原样通过"

# ============ review_stream_final_text ============
make_stream "$tmp/ok.jsonl" "$(wrap "$CONTRACT_FULL")"
out=$(review_stream_final_text "$tmp/ok.jsonl")
assert_contains "$out" "<<<KIRO_REVIEW_JSON>>>" "final_text：取到 runFinished.finalText"
assert_contains "$out" "用户输入直接拼接进 SQL" "final_text：含契约内容"

# 真实形态 fixture（从探测原始输出裁剪而来）也必须能取到
out=$(review_stream_final_text fixtures/stream/real-shape.jsonl)
assert_contains "$out" "<<<KIRO_REVIEW_JSON>>>" "final_text：真实形态 fixture 也能取到 finalText"

# 负向：无 runFinished → rc 2
make_stream "$tmp/norf.jsonl" "x" success no-runfinished
rc=0; out=$(review_stream_final_text "$tmp/norf.jsonl") || rc=$?
assert_rc "$rc" 2 "final_text：无 runFinished 事件 rc=2"

# 负向：status 非 success → rc 3，stdout 为 status 值（供失败评论写原因）
make_stream "$tmp/failed.jsonl" "$(wrap "$CONTRACT_FULL")" error
rc=0; out=$(review_stream_final_text "$tmp/failed.jsonl") || rc=$?
assert_rc "$rc" 3 "final_text：status 非 success rc=3"
assert_eq "$out" "error" "final_text：rc=3 时 stdout 为 status 值"

# 非 JSON 噪音行不能让解析整体失败（stdout 可能混入 CLI 警告）
make_stream "$tmp/noise.jsonl" "$(wrap "$CONTRACT_FULL")" success noise
rc=0; out=$(review_stream_final_text "$tmp/noise.jsonl") || rc=$?
assert_rc "$rc" 0 "final_text：混入非 JSON 行仍成功"
assert_contains "$out" "<<<KIRO_REVIEW_JSON>>>" "final_text：噪音行被跳过"

# 空文件 / 文件不存在
rc=0; review_stream_final_text /dev/null >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 2 "final_text：空输入 rc=2"
rc=0; review_stream_final_text "$tmp/does-not-exist.jsonl" >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "final_text：文件不存在时非零"

# ============ review_stream_usage：credits 与上下文占用（写流水线日志）============
usage=$(review_stream_usage "$tmp/ok.jsonl")
assert_contains "$usage" "credits=0.2609" "usage：累加所有 meteringUsage 得 0.2609 credit"
assert_contains "$usage" "context=3.8%" "usage：取最后一个 contextUsagePercentage"
usage=$(review_stream_usage fixtures/stream/real-shape.jsonl)
assert_contains "$usage" "credits=0.2609" "usage：真实形态 fixture 的 credits 与探测记录（约 0.26）一致"
make_stream "$tmp/nometa.jsonl" "$(wrap "$CONTRACT_FULL")" success no-metadata
usage=$(review_stream_usage "$tmp/nometa.jsonl")
assert_contains "$usage" "credits=-" "usage：无 metadata 事件时 credits 为 -（不报错）"
assert_contains "$usage" "context=-" "usage：无 metadata 事件时 context 为 -"

# ============ review_extract_json ============
json=$(review_extract_json "$tmp/ok.jsonl")
assert_eq "$(printf '%s' "$json" | jq -r .verdict)" "MERGE_AFTER_FIX" "extract：取到标记内 JSON"
assert_eq "$(printf '%s' "$json" | jq -r '.findings | length')" "4" "extract：findings 条数"
assert_not_contains "$json" "好的，我已完成评审" "extract：标记外的散文不进 JSON"

# 标记与内容同行（模型不换行时）
make_stream "$tmp/inline.jsonl" "前言<<<KIRO_REVIEW_JSON>>>{\"summary\":\"s\",\"verdict\":\"MERGE\",\"findings\":[]}<<<END_KIRO_REVIEW_JSON>>>后记"
json=$(review_extract_json "$tmp/inline.jsonl")
assert_eq "$(printf '%s' "$json" | jq -r .summary)" "s" "extract：标记与 JSON 同行也能截取"

# 多组标记 → 取最后一组（模型先给示例再给结果）
make_stream "$tmp/multi.jsonl" "$(printf '示例：\n<<<KIRO_REVIEW_JSON>>>\n{"summary":"示例","verdict":"MERGE","findings":[]}\n<<<END_KIRO_REVIEW_JSON>>>\n实际结果：\n<<<KIRO_REVIEW_JSON>>>\n{"summary":"真结果","verdict":"MERGE","findings":[]}\n<<<END_KIRO_REVIEW_JSON>>>')"
json=$(review_extract_json "$tmp/multi.jsonl")
assert_eq "$(printf '%s' "$json" | jq -r .summary)" "真结果" "extract：多组标记取最后一组"

# 负向：无标记 → rc 4（降级）
make_stream "$tmp/nomarker.jsonl" "# 代码评审报告

这是没有契约标记的纯文本报告。"
rc=0; review_extract_json "$tmp/nomarker.jsonl" >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 4 "extract：无标记 rc=4（降级）"

# 负向：只有起始标记（输出被截断）→ rc 4
make_stream "$tmp/halfmarker.jsonl" "<<<KIRO_REVIEW_JSON>>>
{\"summary\":\"被截断"
rc=0; review_extract_json "$tmp/halfmarker.jsonl" >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 4 "extract：缺结束标记 rc=4（降级）"

# 负向：标记内非法 JSON → rc 5（降级）
make_stream "$tmp/badjson.jsonl" "<<<KIRO_REVIEW_JSON>>>
{\"summary\": \"缺右括号\",
<<<END_KIRO_REVIEW_JSON>>>"
rc=0; review_extract_json "$tmp/badjson.jsonl" >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 5 "extract：标记内非法 JSON rc=5（降级）"

# 负向：标记内是合法 JSON 但不是对象 → rc 5（不能当契约用）
make_stream "$tmp/notobj.jsonl" "<<<KIRO_REVIEW_JSON>>>
[1,2,3]
<<<END_KIRO_REVIEW_JSON>>>"
rc=0; review_extract_json "$tmp/notobj.jsonl" >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 5 "extract：标记内不是 JSON 对象 rc=5（降级）"

# 负向：Kiro 失败的两种情形透传（不降级，交给失败评论路径）
rc=0; review_extract_json "$tmp/norf.jsonl" >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 2 "extract：无 runFinished 透传 rc=2"
rc=0; review_extract_json "$tmp/failed.jsonl" >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 3 "extract：status 非 success 透传 rc=3"

# ============ review_validate ============
v=$(review_validate < fixtures/contract/full.json)
assert_eq "$(printf '%s' "$v" | jq -r .dropped_findings)" "0" "validate：合法契约 dropped=0"
assert_eq "$(printf '%s' "$v" | jq -r '.findings | length')" "4" "validate：合法契约保留 4 条"
assert_eq "$(printf '%s' "$v" | jq -r '.findings[2].file')" "null" "validate：file 允许为 null"
assert_eq "$(printf '%s' "$v" | jq -r '.findings[2].line_start')" "null" "validate：line_start 允许为 null"
assert_eq "$(printf '%s' "$v" | jq -r '.findings[2].fix')" "" "validate：fix 允许为空字符串"

v=$(review_validate < fixtures/contract/dirty.json)
assert_eq "$(printf '%s' "$v" | jq -r '.findings | length')" "3" "validate：脏契约只保留 3 条合法问题"
assert_eq "$(printf '%s' "$v" | jq -r .dropped_findings)" "7" "validate：丢弃 7 条并计数（P3/中文灯/null 级别/缺标题/空 body/缺 body 字段/非对象）"
assert_eq "$(printf '%s' "$v" | jq -r '[.findings[].title] | join("|")')" "合法的 P0|级别大小写与空格需规范化|行号非法应归为未定位" "validate：保留哪几条（顺序不变）"
assert_eq "$(printf '%s' "$v" | jq -r '.findings[1].severity')" "P2" "validate：级别做去空格与大写规范化（' p2 ' → P2）"
assert_eq "$(printf '%s' "$v" | jq -r '.findings[2].line_start')" "null" "validate：行号 ≤ 0 归为 null（未定位）"
assert_eq "$(printf '%s' "$v" | jq -r '.findings[2].file')" "a.py" "validate：行号非法不影响 file"

# 缺 body 字段本身应被丢弃 —— 用一条更小的输入单独证明（上面的 G9 缺 body 字段）
assert_eq "$(printf '%s' "$v" | jq -r '[.findings[] | select(.title == "缺 body 字段本身")] | length')" "0" "validate：缺 body 字段的问题被丢弃"

# 顶层字段缺失时的兜底
v=$(printf '{"findings":[]}' | review_validate)
assert_eq "$(printf '%s' "$v" | jq -r .summary)" "" "validate：缺 summary → 空字符串"
assert_eq "$(printf '%s' "$v" | jq -r .verdict)" "" "validate：缺 verdict → 空字符串"
assert_eq "$(printf '%s' "$v" | jq -r .dropped_findings)" "0" "validate：无 findings → dropped=0"
v=$(printf '{"summary":"s","verdict":"MERGE"}' | review_validate)
assert_eq "$(printf '%s' "$v" | jq -r '.findings | length')" "0" "validate：缺 findings 字段 → 空数组"

# 负向：findings 不是数组 / 顶层不是对象 → rc 非零（走降级）
rc=0; printf '{"findings":"nope"}' | review_validate >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "validate：findings 非数组 → 非零"
rc=0; printf '[1,2]' | review_validate >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "validate：顶层非对象 → 非零"
rc=0; printf 'not json' | review_validate >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "validate：非法 JSON → 非零"

# ============ review_render_summary（INLINE_COMMENT=0）：golden 比对 ============
render() { # <契约文件> <输出文件> [额外参数...]
  local src="$1" out="$2"; shift 2
  review_validate < "$src" > "$tmp/validated.json"
  review_render_summary --json "$tmp/validated.json" \
    --sha 90fcb05 --src feature/user-search --dst master \
    --ts "2026-09-02 20:10:02" --diff-note "完整直传" "$@" > "$out"
}

render fixtures/contract/full.json "$tmp/full.md"
assert_golden "$tmp/full.md" summary-full.md "渲染：P0/P1/P2 完整清单"
body=$(cat "$tmp/full.md")
assert_contains "$body" "<!-- kiro-review:90fcb05 run:1 -->" "渲染：评审标记含 sha 与 run"
assert_contains "$body" "P0 必须修复 · P1 应当修复 · P2 可选改进" "渲染：页脚图例"
assert_contains "$body" '`/kiro review`' "渲染：页脚含重新评审提示"
assert_contains "$body" "建议修改后合并" "渲染：verdict 中文化"
assert_contains "$body" "src/app.py:30-31" "渲染：多行区间用 起-止"
assert_contains "$body" "src/app.py:27" "渲染：单行只显示行号"
assert_contains "$body" "未定位" "渲染：file/line 为 null 标注未定位"
assert_not_contains "$body" "🔴" "渲染：不再出现红灯"
assert_not_contains "$body" "🟡" "渲染：不再出现黄灯"
assert_not_contains "$body" "🔵" "渲染：不再出现蓝灯"
assert_not_contains "$body" "折叠区" "渲染：INLINE_COMMENT=0 无折叠区（清单全部展开）"
assert_not_contains "$body" "<details>" "渲染：INLINE_COMMENT=0 不折叠"
assert_not_contains "$body" "已标注在" "渲染：INLINE_COMMENT=0 不提行内计数"

render fixtures/contract/empty.json "$tmp/empty.md"
assert_golden "$tmp/empty.md" summary-empty.md "渲染：无问题"
body=$(cat "$tmp/empty.md")
assert_contains "$body" "未发现" "渲染：无问题时明确说明"
assert_not_contains "$body" "重点关注文件" "渲染：无问题时省略重点关注文件表"
assert_contains "$body" "可合并" "渲染：MERGE → 可合并"

render fixtures/contract/dirty.json "$tmp/dirty.md"
assert_golden "$tmp/dirty.md" summary-dropped.md "渲染：含丢弃计数与 DO_NOT_MERGE"
body=$(cat "$tmp/dirty.md")
assert_contains "$body" "不建议合并" "渲染：DO_NOT_MERGE → 不建议合并"
assert_contains "$body" "7 条不合契约已丢弃" "渲染：dropped_findings 可见"

# 第 2 次评审：run 参数进入标记与页脚
render fixtures/contract/full.json "$tmp/run2.md" --run 2
body=$(cat "$tmp/run2.md")
assert_contains "$body" "<!-- kiro-review:90fcb05 run:2 -->" "渲染：run 参数进入标记"
assert_contains "$body" "第 2 次评审" "渲染：run 参数进入页脚"

# 未知 verdict 不能被静默吞掉
printf '{"summary":"s","verdict":"LGTM","verdict_reason":"r","findings":[]}' > "$tmp/badverdict.json"
render "$tmp/badverdict.json" "$tmp/badverdict.md"
assert_contains "$(cat "$tmp/badverdict.md")" "LGTM" "渲染：未知 verdict 原样显示（不静默吞掉）"

# 渲染确定性：同参数两次渲染逐字节一致（无时间戳等隐式输入）
render fixtures/contract/full.json "$tmp/det1.md"
render fixtures/contract/full.json "$tmp/det2.md"
assert_eq "$(cmp -s "$tmp/det1.md" "$tmp/det2.md" && echo same || echo differ)" "same" "渲染：纯函数，两次结果一致"

# 必填参数缺失 → 非零（不能渲染出半成品评论）
rc=0; review_render_summary --sha x --src a --dst b --ts t --diff-note n >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "渲染：缺 --json 非零"
rc=0; review_render_summary --json "$tmp/validated.json" --src a --dst b --ts t --diff-note n >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "渲染：缺 --sha 非零"
rc=0; review_render_summary --json "$tmp/validated.json" --sha x --src a --dst b --ts t --diff-note n --bogus 1 >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "渲染：未知参数非零（拼错不静默）"

# INLINE_COMMENT=1 是票 04 的渲染：本票留扩展点但明确未实现，不能悄悄按 0 渲染
rc=0; err=$(review_render_summary --json "$tmp/validated.json" --sha x --src a --dst b --ts t \
      --diff-note n --inline-comment 1 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "渲染：--inline-comment 1 尚未实现 → 非零"
assert_contains "$err" "04" "渲染：--inline-comment 1 报错点名后续票号"
rc=0; review_render_summary --json "$tmp/validated.json" --sha x --src a --dst b --ts t \
      --diff-note n --inline-comment 0 >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 0 "渲染：--inline-comment 0 与默认一致"

# ============ review_render_degraded：结构化解析失败的降级评论 ============
printf '# 代码评审报告\n\n发现硬编码密钥 src/app.py:2（值已掩码：FAKE****0000）。\n\n总体结论：建议修改后合并。\n' > "$tmp/raw.md"
review_render_degraded --text "$tmp/raw.md" --sha 90fcb05 --src feature/user-search --dst master \
  --ts "2026-09-02 20:10:02" --diff-note "完整直传" --reason "输出中未找到契约标记" > "$tmp/degraded.md"
assert_golden "$tmp/degraded.md" summary-degraded.md "渲染：降级评论"
body=$(cat "$tmp/degraded.md")
assert_contains "$body" "结构化解析失败" "降级：标题含「结构化解析失败」"
assert_contains "$body" "FAKE****0000" "降级：正文为原文全文（掩码由评审员按提示词完成，此处不改写）"
assert_contains "$body" "输出中未找到契约标记" "降级：写明失败原因"
assert_contains "$body" "<!-- kiro-review:90fcb05 run:1 -->" "降级：仍带评审标记（便于原地更新）"
rc=0; review_render_degraded --sha x --src a --dst b --ts t --diff-note n >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "降级：缺 --text 非零"

report
