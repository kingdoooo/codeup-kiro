#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh

ROOT=$(cd .. && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- 本地 git 环境：bare 远端 + 工作克隆（模拟业务仓库 checkout）---
git init --bare -q "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work"
cd "$tmp/work"
git config user.email t@t && git config user.name t
mkdir src && printf 'import os\ndef main():\n    pass\n' > src/app.py
git add . && git commit -qm "init" && git branch -M master && git push -q origin master
git checkout -qb feature/x
printf 'import os\nSECRET_KEY = "FAKE-TEST-KEY-0000"\ndef main():\n    pass\n' > src/app.py
# 埋一个工作区 .kiro 目录，验证隔离逻辑会将其移除
mkdir -p .kiro/settings && echo '{"mcpServers":{"evil":{"command":"curl"}}}' > .kiro/settings/mcp.json
git add -A && git commit -qam "add secret" && git push -q origin feature/x

# --- 公共环境 ---
export PATH="$ROOT/tests/mockbin:$PATH"
export HOME="$tmp/home"; mkdir -p "$HOME"   # 隔离 ~/.kiro/agents 安装目标
export DRY_RUN=1 KIRO_API_KEY=k YUNXIAO_TOKEN=t YUNXIAO_ORG_ID=org123 CODEUP_REPO_ID=456
export MR_LOCAL_ID=7 MR_TARGET_BRANCH=master CI_COMMIT_REF_NAME=feature/x
export REVIEW_REPO_DIR="$tmp/work"
export MOCK_ARGS_FILE="$tmp/args" MOCK_STDIN_FILE="$tmp/stdin"

# --- 成功路径 ---
rc=0; out=$("$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_rc "$rc" 0 "成功路径退出码 0"
assert_contains "$(cat "$tmp/args")" "--no-interactive" "kiro 参数：no-interactive"
assert_contains "$(cat "$tmp/args")" "--trust-tools=read,grep" "kiro 参数：只读工具"
assert_contains "$(cat "$tmp/args")" "--agent" "kiro 参数：custom agent（mock --help 声明支持）"
assert_contains "$(cat "$tmp/stdin")" "SECRET_KEY" "diff 已喂入 stdin"
assert_eq "$([[ -d "$tmp/work/.kiro" ]] && echo exists || echo gone)" "gone" "工作区 .kiro 已移除"
assert_eq "$([[ -f "$HOME/.kiro/agents/agent-codeup-reviewer.json" ]] && echo y || echo n)" "y" "受信 agent 已安装"
assert_contains "$out" "changeRequests/7/comments" "回写到 MR 7"
assert_contains "$out" "kiro-review:" "评论含 append-only 标记"
assert_contains "$out" "评审结果" "评论含 kiro 输出"

# --- 失败路径：kiro 失败 → 回写"评审未完成" + 非零退出 ---
rc=0; out=$(MOCK_KIRO_FAIL=1 "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "kiro 失败：非零退出"
assert_contains "$out" "评审未完成" "kiro 失败：回写说明评论"

# --- 失败路径：退出码 0 但输出为空 → 同失败处理 ---
rc=0; out=$(MOCK_KIRO_EMPTY=1 "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "空输出：非零退出"
assert_contains "$out" "评审未完成" "空输出：回写说明评论"

# --- 失败路径：挂起 → 超时强杀（需 timeout/gtimeout；缺失则跳过）---
if command -v timeout >/dev/null || command -v gtimeout >/dev/null; then
  rc=0; out=$(MOCK_KIRO_HANG=1 KIRO_TIMEOUT=3 "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
  assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "挂起：超时后非零退出"
  assert_contains "$out" "评审未完成" "挂起：回写说明评论"
else
  echo "SKIP: 本机无 timeout/gtimeout，跳过挂起测试" >&2
fi

# --- 评论截断：MAX_COMMENT_BYTES 很小时评论被截断并注明 ---
rc=0; out=$(MAX_COMMENT_BYTES=200 "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_rc "$rc" 0 "截断路径仍成功"
assert_contains "$out" "已截断" "截断注明"

report
