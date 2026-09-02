#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
source fixture-repo.sh

# kiro-review.sh 把 timeout/gtimeout 当强制依赖（无超时能力时拒绝运行），
# 本机缺失时它在第一步就退出，本套件的每条断言都测不到真实行为。
# 与其让成功路径断言炸掉（macOS 默认无 timeout），整体跳过并说明原因。
if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null; then
  echo "SKIP: 本机无 timeout/gtimeout（GNU coreutils），跳过 test-kiro-review.sh" >&2
  exit 0
fi

ROOT=$(cd .. && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- 本地 git 环境：bare 远端 + 工作克隆（模拟业务库 checkout，含四类注入面文件）---
make_fixture_repo "$tmp"

# --- 公共环境 ---
export PATH="$ROOT/tests/mockbin:$PATH"
export HOME="$tmp/home"; mkdir -p "$HOME"   # 隔离 ~/.kiro/agents 安装目标与 settings
export DRY_RUN=1 KIRO_API_KEY=k YUNXIAO_TOKEN=t YUNXIAO_ORG_ID=org123 CODEUP_REPO_ID=456
export MR_LOCAL_ID=7 MR_TARGET_BRANCH=master CI_COMMIT_REF_NAME=feature/x
export REVIEW_REPO_DIR="$tmp/work"
export MOCK_ARGS_FILE="$tmp/args" MOCK_STDIN_FILE="$tmp/stdin"
export MOCK_SETTINGS_FILE="$tmp/settings" MOCK_CWD_SCAN_FILE="$tmp/cwdscan" MOCK_CALLS_FILE="$tmp/calls"

# --- 成功路径 ---
rc=0; out=$("$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_rc "$rc" 0 "成功路径退出码 0"
assert_contains "$(cat "$tmp/args")" "--no-interactive" "kiro 参数：no-interactive"
# 参数文件每行一个参数：用整行精确匹配，避免 --trust-tools=read,grep,glob,shell 或 --agent-engine 也能蒙混过关
assert_eq "$(grep -c -x -- '--trust-tools=read,grep,glob' "$tmp/args")" "1" "kiro 参数：--trust-tools 精确等于 read,grep,glob"
assert_eq "$(grep -c -- '^--trust-tools=' "$tmp/args")" "1" "kiro 参数：只有一个 --trust-tools"
assert_contains "$(paste -sd' ' "$tmp/args")" "--agent codeup-reviewer" "kiro 参数：套用受信 custom agent codeup-reviewer"
assert_contains "$(cat "$tmp/stdin")" "SECRET_KEY" "diff 已喂入 stdin"
assert_eq "$([[ -d "$tmp/work/.kiro" ]] && echo exists || echo gone)" "gone" "工作区 .kiro 已移除"
assert_contains "$out" "changeRequests/7/comments" "回写到 MR 7"
assert_contains "$out" "kiro-review:" "评论含 append-only 标记"
assert_contains "$out" "代码评审报告" "评论含清洗后报告正文（锚点标题）"
assert_contains "$out" "硬编码密钥" "评论含报告内容"
assert_not_contains "$out" "using tool: read" "清洗：不含工具调用轨迹"
assert_not_contains "$out" "Successfully read directory" "清洗：不含工具执行轨迹"
assert_contains "$out" "# 代码评审报告" "清洗：锚点行引用前缀已剥离"
esc=$(printf '\033')
assert_not_contains "$out" "${esc}[" "清洗：不含 ANSI 控制序列"

# --- 引擎钉死为 v2（ADR-0004：v1 是 2.21 headless 默认引擎，不阻断 AGENTS.md 注入）---
args_line=$(paste -sd' ' "$tmp/args")
assert_contains "$args_line" "--agent-engine v2" "kiro 参数：固定 --agent-engine v2"
assert_contains "$out" "引擎：v2" "日志显式记录所用引擎为 v2"

# --- 隔离：diff 先算好，随后业务库工作树中的注入面文件在 Kiro 启动前被移除 ---
assert_contains "$(cat "$tmp/stdin")" "CANARY-AGENTSMD-ROOT" "diff 先算：stdin 仍含根 AGENTS.md 的改动"
assert_contains "$(cat "$tmp/stdin")" "CANARY-AGENTSMD-NESTED" "diff 先算：stdin 仍含子目录 AGENTS.md 的改动"
assert_contains "$(cat "$tmp/stdin")" "+++ b/lsp.json" "diff 先算：stdin 仍含 lsp.json 的改动"
assert_contains "$(cat "$tmp/stdin")" "mcpServers" "diff 先算：stdin 仍含 .kiro/settings/mcp.json 的改动"
assert_eq "$(cat "$tmp/cwdscan")" "" "Kiro 启动时工作区已无 AGENTS.md（任意深度）/根 lsp.json/根 .kiro"
assert_eq "$([[ -e "$tmp/work/AGENTS.md" ]] && echo exists || echo gone)" "gone" "根 AGENTS.md 已移除"
assert_eq "$([[ -e "$tmp/work/src/sub/AGENTS.md" ]] && echo exists || echo gone)" "gone" "子目录 AGENTS.md 已移除"
assert_eq "$([[ -e "$tmp/work/lsp.json" ]] && echo exists || echo gone)" "gone" "根 lsp.json 已移除"
assert_eq "$([[ -e "$tmp/work/src/sub/.kiro" ]] && echo exists || echo gone)" "gone" "子目录 .kiro/ 已移除"
assert_eq "$([[ -f "$tmp/work/src/app.py" ]] && echo y || echo n)" "y" "其余业务文件未被误删"
assert_eq "$([[ -d "$tmp/work/.git" ]] && echo y || echo n)" "y" ".git 未被触碰"
diff_ln=$(printf '%s\n' "$out" | grep -n 'diff 已生成' | head -1 | cut -d: -f1)
iso_ln=$(printf '%s\n' "$out" | grep -n '隔离：' | head -1 | cut -d: -f1)
assert_eq "$([[ -n "$diff_ln" && -n "$iso_ln" && "$iso_ln" -gt "$diff_ln" ]] && echo ok || echo bad)" "ok" \
  "隔离步骤的日志出现在 diff 生成之后（diff_ln=${diff_ln:-?} iso_ln=${iso_ln:-?}）"

# --- 隔离：执行环境禁止继承工作区默认资源，且在 Kiro 启动前生效 ---
assert_contains "$(cat "$tmp/settings")" "chat.disableInheritingDefaultResources true" "Kiro 启动前设置 chat.disableInheritingDefaultResources=true"
assert_eq "$(awk '/^settings$/{s=NR} /^chat$/{c=NR} END{print (s && c && s<c) ? "ok" : "bad"}' "$tmp/calls")" "ok" \
  "调用顺序：settings 先于 chat"

# --- 受信 agent 安装：按 name 落盘，prompt 改写为集成包内提示词的绝对 file:// 路径 ---
inst="$HOME/.kiro/agents/codeup-reviewer.json"
assert_eq "$([[ -f "$inst" ]] && echo y || echo n)" "y" "受信 agent 已安装到 ~/.kiro/agents/codeup-reviewer.json"
inst_prompt=$(jq -r .prompt "$inst")
assert_eq "$([[ "$inst_prompt" == file:///*/prompts/review-agent-prompt.md ]] && echo abs || echo other)" "abs" \
  "安装后的 prompt 为绝对 file:// 路径（实际：${inst_prompt}）"
assert_eq "$([[ -r "${inst_prompt#file://}" ]] && echo y || echo n)" "y" "prompt 引用的提示词文件存在且可读"
assert_eq "$(jq -c '[.includeMcpJson, .includePowers]' "$inst")" "[false,false]" "安装后的 agent 不含 MCP/Powers"
assert_eq "$(jq -c 'del(.prompt)' "$inst")" "$(jq -c 'del(.prompt)' "$ROOT/kiro/agent-codeup-reviewer.json")" "安装只改写 prompt，其余字段与集成包一致"

# --- 同名目录不是注入面，但也不能让它卡死评审：lsp.json/ 与 .kiro 为普通文件时照样清掉、照样成功 ---
mkdir -p "$tmp/work/lsp.json/sub" && echo x > "$tmp/work/lsp.json/sub/f"; echo notadir > "$tmp/work/.kiro"
rc=0; out=$(MOCK_CWD_SCAN_FILE="$tmp/cwdscan2" "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_rc "$rc" 0 "lsp.json 为目录 / .kiro 为文件：评审仍成功"
assert_eq "$([[ -e "$tmp/work/lsp.json" || -e "$tmp/work/.kiro" ]] && echo exists || echo gone)" "gone" "lsp.json 目录与 .kiro 文件都已移除"
assert_eq "$(cat "$tmp/cwdscan2")" "" "Kiro 启动时工作区仍干净"

# --- 失败路径：kiro 失败 → 回写"评审未完成" + 非零退出 ---
rc=0; out=$(MOCK_KIRO_FAIL=1 "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "kiro 失败：非零退出"
assert_contains "$out" "评审未完成" "kiro 失败：回写说明评论"

# --- 失败路径：退出码 0 但输出为空 → 同失败处理 ---
rc=0; out=$(MOCK_KIRO_EMPTY=1 "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "空输出：非零退出"
assert_contains "$out" "评审未完成" "空输出：回写说明评论"

# --- 失败路径：挂起 → 超时强杀（timeout/gtimeout 已由文件开头的前置检查保证）---
rc=0; out=$(MOCK_KIRO_HANG=1 KIRO_TIMEOUT=3 "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "挂起：超时后非零退出"
assert_contains "$out" "评审未完成" "挂起：回写说明评论"

# --- 失败路径：settings 设置失败 → 隔离不成立，不启动 Kiro，回写"评审未完成" ---
rc=0; out=$(MOCK_SETTINGS_FAIL=1 MOCK_ARGS_FILE="$tmp/args-settings-fail" "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "settings 失败：非零退出"
assert_contains "$out" "评审未完成" "settings 失败：回写说明评论"
assert_contains "$out" "disableInheritingDefaultResources" "settings 失败：日志点名失败的设置项"
assert_eq "$([[ -e "$tmp/args-settings-fail" ]] && echo launched || echo not-launched)" "not-launched" "settings 失败：Kiro 未被启动"

# --- 失败路径：kiro-cli 不支持 --agent-engine（旧版）→ 拒绝以不受控引擎运行 ---
rc=0; out=$(MOCK_KIRO_NO_ENGINE_FLAG=1 MOCK_ARGS_FILE="$tmp/args-old-cli" "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "旧版 kiro-cli：非零退出"
assert_contains "$out" "--agent-engine" "旧版 kiro-cli：报错点名 --agent-engine"
assert_eq "$([[ -e "$tmp/args-old-cli" ]] && echo launched || echo not-launched)" "not-launched" "旧版 kiro-cli：Kiro 未被启动"

# --- 评论截断：MAX_COMMENT_BYTES 很小时评论被截断并注明 ---
rc=0; out=$(MAX_COMMENT_BYTES=200 "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_rc "$rc" 0 "截断路径仍成功"
assert_contains "$out" "已截断" "截断注明"

# --- 失败路径：提示词文件不可读 → 立即失败，不带空提示词跑 Kiro ---
rc=0; out=$(PROMPT_FILE=/nonexistent "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "提示词缺失：非零退出"
assert_contains "$out" "提示词文件不可读" "提示词缺失：报错说明"

report
