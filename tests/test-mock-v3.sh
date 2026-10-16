#!/usr/bin/env bash
# 测试替身 tests/mockbin/kiro-cli 的 V3 模式（ADR-0008）：它产出的事件流要能被生产的 V3 解析函数读懂，V2 模式的输出逐字节不变。
# 替身是端到端套件的地基——这里先证明它说的「V3 形态」与生产函数对得上，端到端用例的绿才有意义。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
ROOT=$(cd .. && pwd)
source "$ROOT/scripts/lib/review-render.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
MOCK="$ROOT/tests/mockbin/kiro-cli"

# 一个最小的 V3 agent（替身只检查 permissions 块与 prompt 形态）放进「临时 HOME」，配置目录经 TMPDIR 指针找到
H="$tmp/kiro-home"; C="$tmp/case"; mkdir -p "$H/.kiro/agents/prompts" "$C/home"
jq -n '{name: "codeup-reviewer-0123456789abcdef", model: "gpt-5.6-sol", prompt: "file://prompts/codeup-reviewer-0123456789abcdef.md",
        tools: ["read", "grep", "glob"], permissions: {rules: [{capability: "fs_read", match: ["/x", "/y"], effect: "allow"}]}}' \
  > "$H/.kiro/agents/codeup-reviewer-0123456789abcdef.json"
printf 'p\n' > "$H/.kiro/agents/prompts/codeup-reviewer-0123456789abcdef.md"
mkdir -p "$H/.kiro/settings"; printf 'AGENTS.md\n' > "$H/.kiro/settings/kiroignore"
CT=$(mock_tmpdir_pointer "$C")
v3_run() { # [MOCK_X=值…] → stdout 事件流
  mock_config_write "$C/home" MOCK_KIRO_VERSION=2.29.1 "$@"
  printf '提示 <<<KIRO_REVIEW_JSON:0123456789abcdef>>>\n' \
    | ( cd "$tmp" && env -i PATH="$PATH" HOME="$H" TMPDIR="$CT" "$MOCK" chat --no-interactive --agent-engine v3 --output-format stream-json --agent codeup-reviewer-0123456789abcdef )
}
out="$tmp/v3.jsonl"; v3_run > "$out"
assert_eq "$(review_stream_engine "$out")" "v3" "替身 V3：runStarted.engine = v3"
assert_eq "$(review_stream_usage "$out")" "credits=0.2609 context=3.8%" "替身 V3：用量与上下文和 V2 替身同值（日志断言可以写成同一句）"
assert_eq "$(review_stream_v3_model "$out")" "gpt-5.6-sol" "替身 V3：模型取自 agent 声明"
rc=0; review_stream_v3_guard "$out" codeup-reviewer-0123456789abcdef >/dev/null || rc=$?
assert_eq "$rc" "0" "替身 V3：默认事件流不触发兜底"
rc=0; review_stream_model_switch "$out" gpt-5.6-sol >/dev/null || rc=$?
assert_eq "$rc" "1" "替身 V3：V2 的模型回退检测在 V3 形态上不误报"
assert_eq "$(review_extract_json "$out" 0123456789abcdef | jq -r .contract)" "codeup-reviewer/1" "替身 V3：契约照样能取出"
assert_eq "$(cat "$C/home/.kiro-mock/kiroignore")" "AGENTS.md" "替身 V3：按 TMPDIR 指针找到配置目录，并记下临时 HOME 的 kiroignore"
# S8 的回归守卫与 hook 注册数（复审 I-1 / I-3）：替身与真实 2.31.1 一样报 contentCollection 选项、在 HOME 的 ~/.kiro/logs 里写 hooks.reload.loaded
assert_eq "$(review_stream_v3_option "$out" contentCollection)" "disabled" "替身 V3：contentCollection 缺省是 disabled（S8 的设置生效后的样子）"
assert_eq "$(review_v3_hook_registrations "$H/.kiro/logs")" "0" "替身 V3：临时 HOME 的 Kiro 日志里 hook 注册数 0"
rm -rf "$H/.kiro/logs"; v3_run MOCK_KIRO_V3_CONTENT_COLLECTION=enabled MOCK_KIRO_V3_HOOKS_REGISTERED=2 > "$tmp/g.jsonl"
assert_eq "$(review_stream_v3_option "$tmp/g.jsonl" contentCollection)" "enabled" "替身 V3：MOCK_KIRO_V3_CONTENT_COLLECTION 可改"
assert_eq "$(review_v3_hook_registrations "$H/.kiro/logs")" "2" "替身 V3：MOCK_KIRO_V3_HOOKS_REGISTERED 可改"
rm -rf "$H/.kiro/logs"; v3_run MOCK_KIRO_V3_NO_LOGS=1 > "$tmp/g.jsonl"
assert_eq "$([[ -e "$H/.kiro/logs" ]] && echo has || echo none)" "none" "替身 V3：MOCK_KIRO_V3_NO_LOGS=1 → 不写 Kiro 日志"
for sw in STEERING HOOK CONTEXT_FILES; do
  v3_run "MOCK_KIRO_V3_${sw}=1" > "$tmp/g.jsonl"
  rc=0; review_stream_v3_guard "$tmp/g.jsonl" codeup-reviewer-0123456789abcdef >/dev/null || rc=$?
  assert_eq "$rc" "1" "替身 V3：MOCK_KIRO_V3_${sw}=1 → 兜底命中"
done
v3_run MOCK_KIRO_V3_AGENT_SOURCE=workspace > "$tmp/g.jsonl"
assert_contains "$(review_stream_v3_guard "$tmp/g.jsonl" codeup-reviewer-0123456789abcdef || true)" "来源 workspace" "替身 V3：agent 来源可改"
v3_run MOCK_KIRO_ENGINE_REPORT=none > "$tmp/g.jsonl"
rc=0; review_stream_engine "$tmp/g.jsonl" >/dev/null || rc=$?
assert_eq "$rc" "1" "替身 V3：MOCK_KIRO_ENGINE_REPORT=none → runStarted 不带 engine"
v3_run MOCK_KIRO_V3_POLICY_WARN=1 > "$tmp/g.jsonl"
assert_eq "$(review_v3_policy_warnings "$H/.kiro/logs")" "1" "替身 V3：MOCK_KIRO_V3_POLICY_WARN=1 → Kiro 日志里多一行规则被跳过的警告"
rm -rf "$H/.kiro/logs"; v3_run > "$tmp/g.jsonl"
assert_eq "$(review_v3_policy_warnings "$H/.kiro/logs")" "0" "替身 V3：默认没有规则被跳过"
rc=0; review_stream_v3_tools_outside "$tmp/g.jsonl" >/dev/null || rc=$?; assert_eq "$rc" "0" "替身 V3：默认 usedTools 在名单内"
v3_run MOCK_KIRO_V3_USED_TOOLS=read_file,disclose_context > "$tmp/g.jsonl"
assert_eq "$(review_stream_v3_tools_outside "$tmp/g.jsonl" || true)" "disclose_context" "替身 V3：MOCK_KIRO_V3_USED_TOOLS 可改"
v3_run MOCK_KIRO_V3_USED_TOOLS=none > "$tmp/g.jsonl"
rc=0; review_stream_v3_tools "$tmp/g.jsonl" >/dev/null || rc=$?; assert_eq "$rc" "1" "替身 V3：MOCK_KIRO_V3_USED_TOOLS=none → 没有 usedTools"
assert_eq "$(review_stream_usage "$tmp/g.jsonl")" "credits=0.2609 context=3.8%" "替身 V3：改 usedTools 不影响用量"
# V2 模式同一个开关同一个意思（复审 M-1 之前 V2 分支把 none 当成取值写进 engine："none" 是「不合形」，不是「缺字段」）
v2_run() { # [MOCK_X=值…] → stdout 事件流
  mock_config_write "$C/home" MOCK_KIRO_VERSION=2.29.0 "$@"
  printf '提示 <<<KIRO_REVIEW_JSON:0123456789abcdef>>>\n' \
    | ( cd "$tmp" && env -i PATH="$PATH" HOME="$H" TMPDIR="$CT" "$MOCK" chat --no-interactive --agent-engine v2 --output-format stream-json --agent codeup-reviewer-0123456789abcdef )
}
v2_run > "$tmp/g.jsonl"
assert_eq "$(review_stream_engine "$tmp/g.jsonl")" "v2" "替身 V2：runStarted.engine = v2"
v2_run MOCK_KIRO_ENGINE_REPORT=none > "$tmp/g.jsonl"
rc=0; review_stream_engine "$tmp/g.jsonl" >/dev/null || rc=$?
assert_eq "$rc" "1" "替身 V2：MOCK_KIRO_ENGINE_REPORT=none → runStarted 不带 engine"
v2_run MOCK_KIRO_ENGINE_REPORT=v3.1 > "$tmp/g.jsonl"
rc=0; review_stream_engine "$tmp/g.jsonl" >/dev/null || rc=$?
assert_eq "$rc" "3" "替身 V2：MOCK_KIRO_ENGINE_REPORT=v3.1 → 取值原样写进 engine（不合形）"
# 真实 V3 的加载行为：v2 形状（没有 permissions）→ exit 4；绝对 file:// prompt → exit 4
jq 'del(.permissions)' "$H/.kiro/agents/codeup-reviewer-0123456789abcdef.json" > "$H/.kiro/agents/old.json"; jq '.name = "old"' "$H/.kiro/agents/old.json" > "$H/.kiro/agents/old2.json"; mv "$H/.kiro/agents/old2.json" "$H/.kiro/agents/old.json"
rc=0; printf 'x\n' | ( cd "$tmp" && env -i PATH="$PATH" HOME="$H" TMPDIR="$CT" "$MOCK" chat --no-interactive --agent-engine v3 --output-format stream-json --agent old ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "替身 V3：没有 permissions 的 2.x 定义 → exit 4（needs upgrading）"
jq '.name = "abs" | .prompt = "file:///etc/hosts"' "$H/.kiro/agents/codeup-reviewer-0123456789abcdef.json" > "$H/.kiro/agents/abs.json"
rc=0; printf 'x\n' | ( cd "$tmp" && env -i PATH="$PATH" HOME="$H" TMPDIR="$CT" "$MOCK" chat --no-interactive --agent-engine v3 --output-format stream-json --agent abs ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "替身 V3：绝对 file:// prompt → exit 4（PromptFileError）"
# 指针目录不存在 → 仍 fail-closed 退 97
mkdir -p "$tmp/ptr"; printf '%s\n' "$tmp/nope" > "$tmp/ptr/kiro-mock-dir"
rc=0; ( cd "$tmp" && env -i PATH="$PATH" HOME="$H" TMPDIR="$tmp/ptr" "$MOCK" --version ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "97" "替身：TMPDIR 指针指向不存在的目录 → 退 97（漏配要变成红测试）"
report
