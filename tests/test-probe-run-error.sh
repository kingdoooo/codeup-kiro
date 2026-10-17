#!/usr/bin/env bash
# 探测遇到「Kiro 自己没跑完」（runError 限流 / 服务端暂时故障 / 额度或账号问题）时的判定（spec：.scratch/probe-transient-errors，维护者本地）。
# 用一个按模式产出事件流的假 kiro-cli 跑**真实**的 scripts/probe/probe-kiro-allowlist.sh 与 probe-kiro-headless.sh，断言退出码、
# stderr 上的结论行与 summary.json。判据函数本身（review_stream_run_error_class）的单元测试在 test-review-render.sh。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
ROOT=$(cd .. && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
PROBE="$ROOT/scripts/probe/probe-kiro-allowlist.sh"
HEADLESS="$ROOT/scripts/probe/probe-kiro-headless.sh"
if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null; then
  echo "SKIP: 本机无 timeout/gtimeout（GNU coreutils），跳过 test-probe-run-error.sh" >&2
  exit 0
fi

# ---------- 假 kiro-cli ----------
# 第一行写死本目录（v3 与 allowenv 用例经 env -i 许可清单启动，环境变量传不进来）；模式读 <目录>/mode，每次 chat 记进 <目录>/calls。
# chat 先打 runStarted（engine 取 --agent-engine 的值）与一行约 600 字符的元数据（真实 v3 失败前也先写十几 KB 元数据），再按模式输出。
make_probe_fake() { # <目录>
  mkdir -p "$1"
  { printf '#!/usr/bin/env bash\nFAKE_DIR=%q\n' "$1"
    cat <<'SH'
case "${1:-}" in
  whoami) echo "Logged in with fake"; exit 0 ;;
  --version) echo "kiro-cli 9.9.9"; exit 0 ;;
  chat) ;;
  *) exit 0 ;;
esac
stdin=$(cat)
printf '%s\n' "$stdin" > "$FAKE_DIR/last.stdin"
printf 'chat %s\n' "$*" >> "$FAKE_DIR/calls"
mode=$(cat "$FAKE_DIR/mode")
engine=v2; prev=""; for a in "$@"; do [[ "$prev" == "--agent-engine" ]] && engine="$a"; prev="$a"; done
run_error() { jq -nc --arg m "$1" '{type: "runError", data: {sessionId: "s", stage: "prompt", message: $m}}'; }
tail_of() { jq -nc --arg e "$1" --arg r "$2" '{errorType: $e, retryErrorType: $r}'; }
chunk() { jq -nc --arg t "$1" '{type: "sessionUpdate", data: {sessionId: "s", update: {sessionUpdate: "agent_message_chunk", content: {type: "text", text: $t}}}}'; }
finished() { jq -nc --arg t "$1" '{type: "runFinished", data: {status: "success", finalText: $t}}'; }
paths() { printf '%s\n' "$stdin" | LC_ALL=C grep -oE '/[A-Za-z0-9._/-]+' || true; }
run_hook() { local c; c=$(jq -r '.hooks[0].action.command' repo/.kiro/hooks/probe-canary.json) && bash -c "$c"; }
THROTTLE='GPT 5.6 Sol is experiencing high traffic. Try again, or select another model. (Request ID: r) (code -32000): {"errorType":"ModelThrottleError","retryErrorType":"THROTTLING","requestId":"r"}'
jq -nc --arg e "$engine" '{type: "runStarted", data: {payloadSchema: "acp", acpProtocolVersion: 1, engine: $e}}'
jq -nc --arg p "$(printf 'x%.0s' {1..600})" '{type: "sessionUpdate", data: {sessionId: "s", update: {sessionUpdate: "session_info_update", _meta: {kiro: {kind: "padding", note: $p}}}}}'
case "$mode" in
  throttle) run_error "$THROTTLE"; exit 1 ;;
  quota) run_error "You've reached your hourly usage limit. Please return soon to continue building. (code -32000): $(tail_of UsageLimitReachedError CLIENT_ERROR)"; exit 1 ;;
  account) run_error "Access denied. Please check your authentication. (code -32000): $(tail_of AccessDeniedError CLIENT_ERROR)"; exit 1 ;;
  future-throttle) run_error "Slow down. (code -32000): $(tail_of FutureThrottleError THROTTLING)"; exit 1 ;;
  badname-throttle) run_error "Slow down. (code -32000): $(tail_of 'Bad Name' THROTTLING)"; exit 1 ;;
  other) run_error "A validation error occurred. (code -32000): $(tail_of GenericValidationError CLIENT_ERROR)"; exit 1 ;;
  notail) run_error "Internal error"; exit 1 ;;
  badtail) run_error "Something broke (code -32000): {not json"; exit 1 ;;
  other-timeout) run_error "A validation error occurred. (code -32000): $(tail_of GenericValidationError CLIENT_ERROR)"; exit 124 ;;
  reject-throttle)
    jq -nc '{type: "sessionUpdate", data: {sessionId: "s", update: {sessionUpdate: "tool_call_update", toolCallId: "t1", status: "failed",
             rawOutput: "Permission request failed: not supported in non-interactive mode"}}}'
    run_error "$THROTTLE"; exit 1 ;;
  secret) run_error "request failed: Authorization: Bearer $(cat "$FAKE_DIR/secret") (code -32000): $(tail_of ModelThrottleError THROTTLING)"; exit 1 ;;
  chunk-only) chunk "$THROTTLE"; exit 1 ;;
  timeout) exit 124 ;;
  finished-markers)
    ft=""
    while IFS= read -r p; do [[ -f "$p" ]] && ft+="$(LC_ALL=C grep -hE 'MARKER_ALLOW_IN|CHUNK-' "$p" || true)"$'\n'; done < <(paths)
    run_error "$THROTTLE"; finished "$ft"; exit 0 ;;
  leak-throttle)
    while IFS= read -r p; do [[ -f "$p" ]] && { chunk "$(cat "$p")"; break; }; done < <(paths)
    run_error "$THROTTLE"; exit 1 ;;
  hook-throttle) run_hook; run_error "$THROTTLE"; exit 1 ;;
  hook-finished) run_hook; finished "ok"; exit 0 ;;
  nofinish) exit 1 ;;
  nofinish-rc0) exit 0 ;;
  agentsmd-throttle) chunk "summary [CANARY-AGENTSMD-7f3a]"; run_error "$THROTTLE"; exit 1 ;;
  read-denied)
    # 模型照提示词去读、CLI 拒绝：一条带路径的 tool_call + 一条 failed 的 tool_call_update；读到的文件原文记进 read.log（供断言 canary 的写法）
    while IFS= read -r p; do
      [[ -f "$p" ]] || continue
      cat "$p" >> "$FAKE_DIR/read.log"
      jq -nc --arg p "$p" '{type: "sessionUpdate", data: {sessionId: "s", update: {sessionUpdate: "tool_call", toolCallId: "t1", title: "Read File", rawInput: {path: $p}}}}'
      jq -nc '{type: "sessionUpdate", data: {sessionId: "s", update: {sessionUpdate: "tool_call_update", toolCallId: "t1", status: "failed", rawOutput: "[denied] path matches a deny rule"}}}'
    done < <(paths)
    finished "读不到：工具返回 denied"; exit 0 ;;
  read-leak)
    ft=""; while IFS= read -r p; do [[ -f "$p" ]] && ft+="$(cat "$p")"$'\n'; done < <(paths)
    finished "$ft"; exit 0 ;;
  finished-review) finished $'<<<KIRO_REVIEW_JSON>>>\n{"summary":"ok","verdict":"MERGE","verdict_reason":"ok","findings":[]}\n<<<END_KIRO_REVIEW_JSON>>>'; exit 0 ;;
  *) echo "fake kiro-cli: unknown mode ${mode}" >&2; exit 99 ;;
esac
SH
  } > "$1/kiro-cli"
  chmod +x "$1/kiro-cli"
}
FAKE="$tmp/fake"; make_probe_fake "$FAKE"
mkdir -p "$tmp/t"
PN=0
run_probe() { # <v2|v3> <PROBE_CASES，空 = 默认> <模式> → RC / OUT / KEEPD
  PN=$((PN + 1)); KEEPD="$tmp/keep-$PN"; mkdir -p "$tmp/home-$PN"; printf '%s\n' "$3" > "$FAKE/mode"
  RC=0; OUT=$(env PATH="$FAKE:$PATH" HOME="$tmp/home-$PN" TMPDIR="$tmp/t" KIRO_ENGINE="$1" KIRO_API_KEY=fake PROBE_CASES="$2" \
              PROBE_KEEP_DIR="$KEEPD" bash -p "$PROBE" 2>&1) || RC=$?
}
run_headless() { # <模式> [额外环境 NAME=VALUE…] → RC / OUT / KEEPD
  local mode="$1"; shift
  PN=$((PN + 1)); KEEPD="$tmp/keep-$PN"; mkdir -p "$tmp/home-$PN"; printf '%s\n' "$mode" > "$FAKE/mode"
  RC=0; OUT=$(env PATH="$FAKE:$PATH" HOME="$tmp/home-$PN" TMPDIR="$tmp/t" KIRO_ENGINE=v3 KIRO_API_KEY=fake PROBE_KEEP_DIR="$KEEPD" "$@" \
              bash -p "$HEADLESS" 2>&1) || RC=$?
}
kerr() { jq -c "${1:-.kiro_errors}" "$KEEPD/summary.json" 2>/dev/null || echo "（没有 summary.json）"; }

# ============ allowlist 探测：V2 / V3 共有的判定点 ============
# E1：限流 → INCONCLUSIVE（不是边界 FAIL），summary.json 记一条
run_probe v2 T1 throttle
assert_eq "$RC" "3" "E1：T1 被 Kiro 限流 → 退出码 3（不是 1）"
assert_contains "$OUT" "[T1] INCONCLUSIVE  Kiro 没跑完：暂时性服务端错误 ModelThrottleError（THROTTLING；Kiro 已经自己退避重试过）——不是边界结论，等一会儿补跑。Kiro 原文：runError（prompt）：GPT 5.6 Sol is experiencing high traffic" "E1：结论行点名错误类与原文"
assert_not_contains "$OUT" "[T1] FAIL" "E1：不记 FAIL"
assert_not_contains "$OUT" "[T1] PASS" "E1：也绝不记 PASS"
assert_eq "$(kerr)" '[{"case":"T1","kind":"transient","errorType":"ModelThrottleError","retryErrorType":"THROTTLING"}]' "E1：summary.json 的 kiro_errors"
assert_eq "$(kerr '[.any_fail, .any_inconclusive, .ran]')" '[false,true,["T1"]]' "E1：summary.json 原有字段语义不变"
# E2：默认 13 个全被限流 → 结尾汇总与可直接粘贴的补跑命令
run_probe v2 "" throttle
assert_eq "$RC" "3" "E2：默认用例全被限流 → 退出码 3"
assert_eq "$(kerr '.kiro_errors | length')" "13" "E2：kiro_errors 13 条"
assert_contains "$OUT" "[probe] Kiro 自己报错没跑完的用例：T1 T1b T1c T2 T3 T4 T8a T8b T9a T9b T9c T9d T5（暂时性 13 / 需人处理 0，见 summary.json 的 kiro_errors）。补跑确认：KIRO_ENGINE=v2 PROBE_CASES='T1 T1b T1c T2 T3 T4 T8a T8b T9a T9b T9c T9d T5' bash -p scripts/probe/probe-kiro-allowlist.sh——只补跑这几个用例时以 4 退出、不作发布判定（列表含全部门禁用例时除外）；发布证据要完整跑一次。" "E2：结尾汇总（补跑命令带上本次的引擎，spec 修订 R5）"
assert_contains "$OUT" "结论：有 INCONCLUSIVE 项（门禁用例证据不全、Kiro 自己报错没跑完、或正控/INFO 用例不成立即探测本身不可信）" "E2：结论行提到 Kiro 自己报错没跑完"
E2_OUT="$OUT"
# E16（RF4）：结尾提示里的 KIRO_ENGINE 与 PROBE_CASES 原样粘贴回去能跑（引擎也来自提示本身，不是测试自己记的）
pe=""; pc=""; [[ "$E2_OUT" =~ KIRO_ENGINE=([a-z0-9]+)\ PROBE_CASES=\'([^\']*)\' ]] && { pe="${BASH_REMATCH[1]}"; pc="${BASH_REMATCH[2]}"; }
assert_eq "$([[ -n "$pc" && "$pe" == v2 ]] && echo got)" "got" "E16：（准备）从结尾提示里截出了 KIRO_ENGINE=v2 与 PROBE_CASES"
run_probe "$pe" "$pc" throttle
assert_eq "$RC" "3" "E16：照提示补跑 → 正常跑到结论（不退 2、不在启动时静默退 1）"
assert_eq "$(kerr '.ran | sort')" "$(jq -cn --arg s "$pc" '$s | split(" ") | sort')" "E16：summary.json 的 ran 正好是提示里的用例（ran 按用例表顺序、提示按执行顺序，比集合）"
# E3 / E4：额度、账号 → 需人处理
run_probe v2 T1 quota
assert_eq "$RC" "3" "E3：用量上限 → 退出码 3"
assert_contains "$OUT" "[T1] INCONCLUSIVE  Kiro 拒绝服务：UsageLimitReachedError（CLIENT_ERROR）——额度或账号问题，补跑前要人处理（用量上限：等原文所说的时间窗口重置，或买 add-on credits / 升级套餐，企业版看 overage 上限；账号 / 鉴权：核对 KIRO_API_KEY 与 Kiro 账号状态）；不是边界结论。Kiro 原文：runError（prompt）：You've reached your hourly usage limit" "E3：需人处理的文案，原文带出时间窗口"
assert_eq "$(kerr '.kiro_errors[0].kind')" '"needs_human"' "E3：kind = needs_human"
run_probe v2 T1 account
assert_contains "$OUT" "[T1] INCONCLUSIVE  Kiro 拒绝服务：AccessDeniedError（CLIENT_ERROR）——额度或账号问题" "E4：鉴权错误 → 需人处理"
# E5 / E19：名单外类名 + THROTTLING → 暂时性；类名不合形记 null
run_probe v2 T1 future-throttle
assert_eq "$(kerr '.kiro_errors[0] | [.kind, .errorType]')" '["transient","FutureThrottleError"]' "E5：名单外类名 + THROTTLING → 暂时性"
run_probe v2 T1 badname-throttle
assert_contains "$OUT" "暂时性服务端错误 （类型名解析不出）（THROTTLING" "E19：类名不合形时文案说「解析不出」"
assert_eq "$(kerr '.kiro_errors[0].errorType')" "null" "E19：kiro_errors 里不合形的类名是 null"
# E6 / E7：名单外 runError 仍是 FAIL，FAIL 行点名原因
run_probe v2 T1 other
assert_eq "$RC" "1" "E6：名单外 runError → 仍是门禁 FAIL"
assert_contains "$OUT" "[T1] FAIL    没有 runFinished 事件（kiro-cli 未正常跑完，见 stderr）；Kiro runError：GenericValidationError；原文：runError（prompt）：A validation error occurred." "E6：FAIL 行带 Kiro runError 的类名与原文"
assert_eq "$(kerr)" "[]" "E6：kiro_errors 为空数组（FAIL 不记）"
run_probe v2 T1 notail
assert_eq "$RC" "1" "E7：解析不出类型（V2 的形状）→ FAIL"
assert_contains "$OUT" "；Kiro runError：解析不出类型；原文：runError（prompt）：Internal error" "E7：FAIL 行说「解析不出类型」"
# E21（终审 F1）：runError 的 JSON 尾巴解析不了 → 仍 FAIL，FAIL 行照样附上「解析不出类型」与原文
run_probe v2 T1 badtail
assert_eq "$RC" "1" "E21：JSON 尾巴解析不了 → FAIL"
assert_contains "$OUT" "；Kiro runError：解析不出类型；原文：runError（prompt）：Something broke" "E21：FAIL 行仍附上 Kiro runError 的原因"
# E20（终审 F2，I1）：allow 内读取已经留下拒绝痕迹，之后 Kiro 才被限流 → 失效证据优先，仍是 FAIL
run_probe v2 T1 reject-throttle
assert_eq "$RC" "1" "E20：T1 有拒绝痕迹 + 限流 → FAIL（拒绝痕迹就是 allow 内读取的失效证据）"
assert_not_contains "$OUT" "[T1] INCONCLUSIVE" "E20：不因为后来的限流改判成 INCONCLUSIVE"
assert_eq "$(kerr)" "[]" "E20：kiro_errors 为空"
run_probe v2 T1b reject-throttle
assert_eq "$RC" "1" "E20：T1b（grep）有拒绝痕迹 + 限流 → 同样 FAIL"
# E22（spec 修订 R4）：名单外 runError 落到 INCONCLUSIVE 的地方也点名原因——「没有读取尝试」「正控无效」不该在 Kiro 已经报错时让人去查模型
run_probe v2 T3 other
assert_contains "$OUT" "[T3] INCONCLUSIVE" "E22：T3 名单外 runError、没读 → INCONCLUSIVE（原判定不变）"
assert_contains "$OUT" "；Kiro runError：GenericValidationError；原文：runError（prompt）：A validation error occurred." "E22：judge_rejected 的 INCONCLUSIVE 行附上 Kiro runError"
# E23（spec 修订 R6）：judge_rejected 的超时 FAIL 行同样附上名单外 runError（Kiro 报了未知错误、之后挂住到被我们的 timeout 杀掉）
run_probe v2 T3 other-timeout
assert_eq "$RC" "1" "E23：T3 名单外 runError + 超时 → 仍是 FAIL"
assert_contains "$OUT" "[T3] FAIL    超时——读取在等待确认而不是被拒绝（headless 下这等于烧掉整个 KIRO_TIMEOUT）；Kiro runError：GenericValidationError" "E23：超时 FAIL 行附上 Kiro runError"
run_probe v2 T5 other
assert_contains "$OUT" "[T5] INCONCLUSIVE  正控无效：模型没有尝试读取" "E22：T5 正控没读到 → 原判定不变"
assert_contains "$OUT" "；Kiro runError：GenericValidationError" "E22：T5 的 INCONCLUSIVE 行附上 Kiro runError"
# E8 / E9：没有 runError 的没跑完与超时 → 照旧 FAIL
run_probe v2 T1 chunk-only
assert_eq "$RC" "1" "E8：限流文字只在模型文本里、没有 runError → FAIL"
assert_contains "$OUT" "[T1] FAIL    没有 runFinished 事件" "E8：FAIL 文案照旧"
assert_not_contains "$OUT" "Kiro runError：" "E8：没有 runError 就不附原因"
run_probe v2 T1 timeout
assert_eq "$RC" "1" "E9：超时且没有 runError → FAIL"
assert_contains "$OUT" "[T1] FAIL    超时——allow 内读取仍在等待确认" "E9：超时文案照旧"
assert_eq "$(kerr)" "[]" "E9：kiro_errors 为空数组"
# E10（I2）：跑完的运行照常判，runError 不起作用
run_probe v2 T1 finished-markers
assert_eq "$RC" "4" "E10：有 runFinished、两处标记都在 → PASS（子集运行退 4）"
assert_contains "$OUT" "[T1] PASS" "E10：T1 PASS"
assert_eq "$(kerr)" "[]" "E10：跑完的运行不记 kiro_errors"
# E11（I1）：泄漏优先于限流
run_probe v2 T2 leak-throttle
assert_eq "$RC" "1" "E11：canary 出现在输出里 + 限流 → 仍是 FAIL"
assert_contains "$OUT" "[T2] FAIL    canary的内容出现在输出中——边界未生效" "E11：泄漏文案"
assert_eq "$(kerr)" "[]" "E11：kiro_errors 为空"
# E15（I4）：原文经过清洗与掩码
_ghp=ghp; printf '%s' "${_ghp}_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890" > "$FAKE/secret"
run_probe v2 T1 secret
assert_contains "$OUT" "[T1] INCONCLUSIVE  Kiro 没跑完：暂时性服务端错误 ModelThrottleError" "E15：带令牌的原文仍按限流判"
assert_not_contains "$OUT" "${_ghp}_ABCDEF" "E15：令牌原文不进 stderr（原文走 review_stream_run_error 的掩码）"
rm -f "$FAKE/secret"
# E17：其它判定点（judge_tool_ok、judge_rejected、T6 INFO）同样点名
for c in T1b T3 T6; do
  run_probe v2 "$c" throttle
  assert_contains "$OUT" "[$c] INCONCLUSIVE  Kiro 没跑完：暂时性服务端错误 ModelThrottleError" "E17：${c} 被限流时点名 Kiro 的错误类"
done

# ============ allowlist 探测：V3 专有的判定点（T10–T14）============
# E12（I1）：没跑完，但业务库的 hook 已经执行了 → 失效证据优先，FAIL
run_probe v3 T10 hook-throttle
assert_eq "$RC" "1" "E12：V3 T10 被限流、但业务库 hook 已执行 → FAIL（失效证据不等 runFinished）"
assert_contains "$OUT" "[T10] FAIL" "E12：T10 FAIL"
assert_contains "$OUT" "hook 日志非空：业务库的 SessionStart hook 在本机执行了" "E12：点名 hook 日志"
assert_eq "$(kerr)" "[]" "E12：FAIL 不记 kiro_errors"
# E13：V3 默认 18 个全被限流 → T10–T14、T5 都点名 Kiro 的错误类，没有任何 PASS
run_probe v3 "" throttle
assert_eq "$RC" "3" "E13：V3 默认用例全被限流 → 退出码 3"
assert_eq "$(kerr '.kiro_errors | length')" "18" "E13：kiro_errors 18 条"
for c in T10 T13 T14 T5; do
  assert_contains "$OUT" "[$c] INCONCLUSIVE  Kiro 没跑完：暂时性服务端错误" "E13：${c} 点名 Kiro 的错误类"
done
assert_not_contains "$OUT" "] PASS" "E13：被限流的运行一个 PASS 都没有"
assert_contains "$OUT" "补跑确认：KIRO_ENGINE=v3 PROBE_CASES='" "E13：V3 运行的补跑命令写明 KIRO_ENGINE=v3"
# E14（I2）：跑完的运行照原次序判——兜底函数先报
run_probe v3 T10 hook-finished
assert_eq "$RC" "1" "E14：V3 T10 跑完了、hook 执行过、没有 mode 信息 → FAIL"
assert_contains "$OUT" "兜底信号：" "E14：跑完的运行仍由兜底函数先报（次序与改动前相同）"
# E22（V3）：v3_judge 无法判定的分支同样附上名单外 runError
run_probe v3 T10 other
assert_contains "$OUT" "[T10] INCONCLUSIVE" "E22：V3 T10 名单外 runError → INCONCLUSIVE（原判定不变）"
assert_contains "$OUT" "；Kiro runError：GenericValidationError" "E22：v3_judge 的 INCONCLUSIVE 行附上 Kiro runError"
# E18：超时、没跑完、没有失效证据、没有 runError → 原文案
run_probe v3 T10 timeout
assert_eq "$RC" "3" "E18：V3 T10 超时且无证据 → INCONCLUSIVE"
assert_contains "$OUT" "[T10] INCONCLUSIVE  超时，无法判定" "E18：超时文案照旧"

# ============ headless 探测（V3）：没有 runFinished 就是「未成功运行」============
# V3 失败前先写十几 KB 元数据，旧的「rc≠0 且输出 < 400 字符」从不触发，P1-10 打出假 PASS（2026-10-15 注册表错误那次实测）
run_headless throttle
assert_eq "$RC" "2" "H1：headless 被限流 → 退出码 2（未成功运行）"
assert_contains "$OUT" "[P1-08 ] INFO    没有 runFinished，最终消息所在的事件没核到" "H1：P1-08 补一行 INFO"
assert_contains "$OUT" "[P1-10 ] INCONCLUSIVE  Kiro 没跑完：暂时性服务端错误 ModelThrottleError（THROTTLING）" "H1：P1-10 点名 Kiro 的错误类"
assert_contains "$OUT" "[P1-11 ] INCONCLUSIVE  同上" "H1：P1-11 同上"
assert_contains "$OUT" "完成（未成功运行）" "H1：走未成功运行分支"
assert_not_contains "$OUT" "[P1-10 ] PASS" "H1：不再打出假 PASS"
run_headless nofinish
assert_eq "$RC" "2" "H2：没跑完、没有 runError（元数据超过 400 字符）→ 退出码 2"
assert_contains "$OUT" "[P1-10 ] INCONCLUSIVE  Kiro 没跑完（没有 runFinished，见 out.jsonl / err.log）" "H2：说清没跑完"
run_headless agentsmd-throttle
assert_eq "$RC" "1" "H3：没跑完但 AGENTS.md canary 出现 → FAIL（失效证据优先）"
assert_contains "$OUT" "[P1-10 ] FAIL" "H3：P1-10 FAIL"
run_headless nofinish-rc0
assert_eq "$RC" "2" "H4：rc 0 但没有 runFinished → 退出码 2（不管 rc）"
run_headless finished-review
assert_eq "$RC" "3" "H5：正常跑完 → 与改动前相同（P1-11 没有读取尝试 → INCONCLUSIVE）"
assert_contains "$OUT" "[P1-10 ] PASS" "H5：跑完的运行 P1-10 照常 PASS"
assert_contains "$OUT" "[P1-11 ] INCONCLUSIVE" "H5：P1-11 照常判"
run_headless throttle PROBE_NO_ISOLATION=1
assert_eq "$RC" "2" "H6（RF5）：正控模式下没跑完 → 退出码 2"
assert_not_contains "$OUT" "[P1-10 ] PASS" "H6：正控模式下不打出 P1-10 PASS（那会读成「正控没咬人」）"
# H8（spec 修订 R7）：P1-11 的 canary 不能写成「令牌」——2026-10-17 kiro-cli 2.32.0 上评审员 agent 对「把 token= 后面的值原样输出」直接拒读
# （零工具调用），默认与强制读取两种模式都只能 INCONCLUSIVE。canary 改成 allowlist T9 那样的无害形状：「# MARKER …」+「原样输出含 MARKER 的那一行」
rm -f "$FAKE/read.log"
run_headless read-denied PROBE_FORCE_READ=1
assert_eq "$RC" "0" "H8：强制读取模式、读取被拒 → P1-11 PASS，退出码 0"
assert_contains "$OUT" "[P1-11 ] PASS" "H8：P1-11 PASS"
assert_not_contains "$(cat "$FAKE/last.stdin")" "token" "H8：强制读取的提示词不再要「token= 后面的值」"
assert_contains "$(cat "$FAKE/last.stdin")" "含 MARKER 的那一行" "H8：提示词要的是含 MARKER 的那一行"
assert_contains "$(cat "$FAKE/read.log" 2>/dev/null)" "# MARKER " "H8：canary 文件写成「# MARKER …」"
assert_not_contains "$(cat "$FAKE/read.log" 2>/dev/null)" "token=" "H8：canary 文件里没有 token="
rm -f "$FAKE/read.log"
run_headless read-denied
assert_not_contains "$(cat "$FAKE/last.stdin")" "token" "H8：默认模式的提示词同样不再要 token"
# H9（正控）：canary 内容出现在输出里 → P1-11 FAIL（改了写法之后这条判定仍然咬人）
run_headless read-leak PROBE_FORCE_READ=1
assert_eq "$RC" "1" "H9：canary 内容出现在输出里 → 退出码 1"
assert_contains "$OUT" "[P1-11 ] FAIL" "H9：P1-11 FAIL"
# 结尾的「P1-11 正控」提示要能照着做：安装器按 KIRO_AGENT_REQUIRED_DENY_JQ 拒装缺 **/.git 的定义（2026-10-17 实测：照旧提示改仓库只会「安装 agent 失败」）
assert_contains "$OUT" "KIRO_AGENT_REQUIRED_DENY_JQ" "H9：正控提示点名安装器的必需拒绝清单（照旧提示做只会装不上）"
assert_contains "$OUT" "一次性副本" "H9：正控提示要求在一次性副本里做，不改仓库"
assert_not_contains "$OUT" "git checkout 还原" "H9：正控提示不再让人改仓库再还原"
run_headless quota
assert_eq "$RC" "2" "H7：用量上限 → 退出码 2"
assert_contains "$OUT" "Kiro 拒绝服务（额度或账号问题）：UsageLimitReachedError（CLIENT_ERROR）" "H7：需人处理的说法"

# ============ 文档：README 与 ADR-0008 跟上判定 ============
PR="$ROOT/scripts/probe/README.md"; ADR8="$ROOT/docs/adr/0008-default-v3-engine.md"
assert_contains "$(cat "$PR")" "只有 v3 的 runError 带错误类型" "文档：README 写明 V2 照旧判定"
assert_contains "$(cat "$PR")" "没跑完（事件流里没有 runFinished：限流、额度用完、启动失败等）→ 2" "文档：README 的 headless 退出码说明换成「没有 runFinished」"
assert_eq "$(LC_ALL=C grep -c '运行本身没跑起来 → 2' "$PR" || true)" "0" "文档：README 不再保留旧说法「运行本身没跑起来 → 2」"
assert_contains "$(cat "$PR")" "kiro_errors" "文档：README 讲到 summary.json 的 kiro_errors"
assert_contains "$(cat "$PR")" "重新提取 Kiro 错误类名单" "文档：README 的升级步骤要求重新提取错误类名单"
assert_contains "$(cat "$ADR8")" "重新提取 Kiro 错误类名单" "文档：ADR-0008 的 3.x 清单要求重新提取错误类名单"
assert_contains "$(cat "$PR")" "KIRO_AGENT_REQUIRED_DENY_JQ" "文档：README 的 P1-11 正控写明安装器的必需拒绝清单也要在副本里拿掉"
assert_eq "$(LC_ALL=C grep -c '看完务必 .git checkout' "$PR" || true)" "0" "文档：README 不再让人改仓库里的 agent 定义再 git checkout 还原"
# 终审 minor #2：2026-10-16 那次 runError 是在 271 s 写出来的（300 s 之内），改成 600 的理由是余量太薄，不是「300 s 一定先杀掉」
for _f in "$PR" "$PROBE"; do
  assert_eq "$(LC_ALL=C grep -c '会先把.*杀掉、runError 来不及写' "$_f" || true)" "0" "文档：$(basename "$_f") 不再说 300 s「会先把 Kiro 杀掉」"
  assert_contains "$(cat "$_f")" "300 s 只剩约 30 s 余量" "文档：$(basename "$_f") 说清 600 的理由是余量"
done
unset _f

# ============ S-I3：错误类名单只有一份 ============
# 类名直接从 review_stream_run_error_class 的两个 jq 名单里取：名单加了名字，守卫自动跟上（不在测试里另抄一份）。
# 名单区 = 函数里从 `jq -R -n -r '` 那一行到名单之后那一行（`[inputs | fromjson? | objects] as $ev`）——在 $transient 后面再加名单也在区里；
# 取区里**每个**带引号的串，再按判据函数自己的类名形状筛——不按后缀（Error / Exception）认，否则名单里加一个形状不同的名字时守卫会悄悄漏掉它
errclass_tokens() { # <树根> → 名单区里每个带引号的串（去掉引号），一行一个
  LC_ALL=C sed -n '/^review_stream_run_error_class() {/,/^}/p' "$1/scripts/lib/review-render.sh" \
    | LC_ALL=C sed -n "/jq -R -n -r '/,/\\[inputs | fromjson? | objects\\] as \\\$ev/p" | LC_ALL=C grep -oE '"[^"]*"' | LC_ALL=C tr -d '"'
}
errclass_names() { # <树根> → 每行一个类名（合形、去重）
  errclass_tokens "$1" | { LC_ALL=C grep -E '^[A-Za-z][A-Za-z0-9]{0,63}$' || true; } | LC_ALL=C sort -u
}
errclass_sites() { # <树根> → 空格分隔的相对路径（scripts/ 下含任一错误类名的 *.sh）
  local pat; pat=$(errclass_names "$1" | LC_ALL=C paste -sd'|' -)
  [[ -n "$pat" ]] || { echo "（没取到类名）"; return 0; }
  ( cd "$1" && { LC_ALL=C grep -rlwE "$pat" --include='*.sh' scripts || true; } | LC_ALL=C sort | LC_ALL=C paste -sd' ' - )
}
assert_eq "$(errclass_names "$ROOT" | grep -c .)" "19" "I3 正控：从 review_stream_run_error_class 的两个名单里取出了 19 个类名（取不出时守卫会空转）"
assert_eq "$(errclass_sites "$ROOT")" "scripts/lib/review-render.sh" "I3：错误类名只出现在 review-render.sh（review_stream_run_error_class）"
mkdir -p "$tmp/i3root"; cp -R "$ROOT/scripts" "$tmp/i3root/"; printf '# OverageLimitReachedError\n' >> "$tmp/i3root/scripts/probe/probe-kiro-allowlist.sh"
assert_eq "$(errclass_sites "$tmp/i3root")" "scripts/lib/review-render.sh scripts/probe/probe-kiro-allowlist.sh" "I3 元测试：别处再写任一个类名（这里是名单里的 OverageLimitReachedError）会被守卫抓到"
# 不以 Error 结尾的类名（AWS SDK 的 ThrottlingException 这类）加进名单后同样被守卫覆盖
mkdir -p "$tmp/i3exc"; cp -R "$ROOT/scripts" "$tmp/i3exc/"
LC_ALL=C sed -i.bak 's/"StreamIdleTimeoutError", /"StreamIdleTimeoutError", "ThrottlingException", /' "$tmp/i3exc/scripts/lib/review-render.sh"
printf '# ThrottlingException\n' >> "$tmp/i3exc/scripts/probe/probe-kiro-allowlist.sh"
assert_eq "$(errclass_names "$tmp/i3exc" | grep -c .)" "20" "I3 元测试：名单里加一个不以 Error 结尾的类名 → 取出 20 个（不被提取规则悄悄漏掉）"
assert_eq "$(errclass_sites "$tmp/i3exc")" "scripts/lib/review-render.sh scripts/probe/probe-kiro-allowlist.sh" "I3 元测试：那个类名在别处出现同样被抓到"
# 名单区里每个带引号的串都必须是合形的类名：混进不合形的（比如带空格）时一致性断言变红，而不是被提取规则跳过
assert_eq "$(errclass_tokens "$ROOT" | grep -c .)" "$(errclass_names "$ROOT" | grep -c .)" "I3：名单区里每个带引号的串都是合形、不重复的类名"
mkdir -p "$tmp/i3bad"; cp -R "$ROOT/scripts" "$tmp/i3bad/"
LC_ALL=C sed -i.bak 's/"StreamIdleTimeoutError", /"StreamIdleTimeoutError", "Bad Name", /' "$tmp/i3bad/scripts/lib/review-render.sh"
assert_eq "$([[ "$(errclass_tokens "$tmp/i3bad" | grep -c .)" != "$(errclass_names "$tmp/i3bad" | grep -c .)" ]] && echo caught)" "caught" \
  "I3 元测试：名单区里混进不合形的串 → 上面那条一致性断言会红"
# 将来在 $transient 后面再加一个名单：名单区一直到「名单之后那一行」，新名单里的类名同样被提取
mkdir -p "$tmp/i3third"; cp -R "$ROOT/scripts" "$tmp/i3third/"
LC_ALL=C sed -i.bak 's/"OutputParseError"\] as \$transient/"OutputParseError"] as $transient\
    | ["ThirdListError"] as $third/' "$tmp/i3third/scripts/lib/review-render.sh"
printf '# ThirdListError\n' >> "$tmp/i3third/scripts/probe/probe-kiro-allowlist.sh"
assert_eq "$(errclass_names "$tmp/i3third" | grep -c .)" "20" "I3 元测试：\$transient 之后新加的名单同样被提取（取出 20 个）"
assert_eq "$(errclass_sites "$tmp/i3third")" "scripts/lib/review-render.sh scripts/probe/probe-kiro-allowlist.sh" "I3 元测试：新名单里的类名在别处出现同样被抓到"

report
