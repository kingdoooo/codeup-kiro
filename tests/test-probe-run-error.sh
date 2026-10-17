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
assert_contains "$OUT" "[probe] Kiro 自己报错没跑完的用例：T1 T1b T1c T2 T3 T4 T8a T8b T9a T9b T9c T9d T5（暂时性 13 / 需人处理 0，见 summary.json 的 kiro_errors）。补跑确认：PROBE_CASES='T1 T1b T1c T2 T3 T4 T8a T8b T9a T9b T9c T9d T5' bash -p scripts/probe/probe-kiro-allowlist.sh——子集以 4 退出、不作发布判定；发布证据要完整跑一次。" "E2：结尾汇总"
assert_contains "$OUT" "结论：有 INCONCLUSIVE 项（门禁用例证据不全、Kiro 自己报错没跑完、或正控/INFO 用例不成立即探测本身不可信）" "E2：结论行提到 Kiro 自己报错没跑完"
E2_OUT="$OUT"
# E16（RF4）：结尾提示里的 PROBE_CASES 原样粘贴回去能跑
pc=""; [[ "$E2_OUT" =~ PROBE_CASES=\'([^\']*)\' ]] && pc="${BASH_REMATCH[1]}"
assert_eq "$([[ -n "$pc" ]] && echo got)" "got" "E16：（准备）从结尾提示里截出了 PROBE_CASES"
run_probe v2 "$pc" throttle
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
# E14（I2）：跑完的运行照原次序判——兜底函数先报
run_probe v3 T10 hook-finished
assert_eq "$RC" "1" "E14：V3 T10 跑完了、hook 执行过、没有 mode 信息 → FAIL"
assert_contains "$OUT" "兜底信号：" "E14：跑完的运行仍由兜底函数先报（次序与改动前相同）"
# E18：超时、没跑完、没有失效证据、没有 runError → 原文案
run_probe v3 T10 timeout
assert_eq "$RC" "3" "E18：V3 T10 超时且无证据 → INCONCLUSIVE"
assert_contains "$OUT" "[T10] INCONCLUSIVE  超时，无法判定" "E18：超时文案照旧"

# ============ S-I3：错误类名单只有一份 ============
errclass_sites() { # <树根> → 空格分隔的相对路径（scripts/ 下含错误类名的 *.sh）
  ( cd "$1" && { LC_ALL=C grep -rlE 'ModelThrottleError|UsageLimitReachedError' --include='*.sh' scripts || true; } | LC_ALL=C sort | LC_ALL=C paste -sd' ' - )
}
assert_eq "$(errclass_sites "$ROOT")" "scripts/lib/review-render.sh" "I3：错误类名只出现在 review-render.sh（review_stream_run_error_class）"
mkdir -p "$tmp/i3root"; cp -R "$ROOT/scripts" "$tmp/i3root/"; printf '# ModelThrottleError\n' >> "$tmp/i3root/scripts/probe/probe-kiro-allowlist.sh"
assert_eq "$(errclass_sites "$tmp/i3root")" "scripts/lib/review-render.sh scripts/probe/probe-kiro-allowlist.sh" "I3 元测试：别处再写一份名单会被这条守卫抓到"

report
