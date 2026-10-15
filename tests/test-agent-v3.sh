#!/usr/bin/env bash
# V3 受信 agent（ADR-0008）：kiro/agent-codeup-reviewer.v3.json 的静态契约 + scripts/lib/kiro-agent.sh 的 V3 段
# （kiro_install_agent_v3 / kiro_agent_selfcheck_v3 / kiro_run_home_prepare / kiro_env_isolate_home）+ scripts/lib/isolation.sh 的 review_copy_to_root。
# V2 那份定义冻结（tests/test-agent-config.sh 钉 sha256），这里只测 V3。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
ROOT=$(cd .. && pwd)
A2="$ROOT/kiro/agent-codeup-reviewer.json"
A3="$ROOT/kiro/agent-codeup-reviewer.v3.json"
source "$ROOT/scripts/lib/kiro-agent.sh"
source "$ROOT/scripts/lib/isolation.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---- 定义的静态契约 ----
assert_rc "$(jq -e . "$A3" >/dev/null 2>&1 && echo 0 || echo 1)" 0 "v3 定义是合法 JSON"
assert_eq "$(jq -r .name "$A3")" "codeup-reviewer" "v3 name"
assert_eq "$(jq -r .model "$A3")" "$(jq -r .model "$A2")" "v3 与 v2 声明同一个模型"
assert_eq "$(jq -r .prompt "$A3")" "$(jq -r .prompt "$A2")" "v3 与 v2 引用同一份提示词（相对 file://）"
assert_eq "$(jq -c .tools "$A3")" '["read","grep","glob"]' "v3 tools 恰好 read / grep / glob（V3 把它们当标签）"
assert_eq "$(jq -r 'has("toolsSettings") or has("allowedTools") or has("hooks") or has("mcpServers") or has("toolAliases")' "$A3")" "false" \
  "v3 没有 toolsSettings / allowedTools / hooks / mcpServers / toolAliases"
assert_eq "$(jq -c .resources "$A3")" '[]' "v3 resources 为空"
assert_eq "$(jq -r '.includeMcpJson == false and .includePowers == false' "$A3")" "true" "v3 includeMcpJson / includePowers 为 false"
assert_eq "$(jq -r "$_KIRO_V3_RULES_JQ"' v3_shape_error' "$A3")" "" "v3 规则形状合格（与安装器、自检同一份谓词）"
assert_eq "$(jq -c '[.permissions.rules[] | select(.effect == "allow") | .match] | first' "$A3")" '["{{REVIEW_ROOT}}","{{REVIEW_CHUNKS}}"]' \
  "v3 唯一的 allow 是两个占位符（安装时结构化写成物理路径）"
# 拒绝清单与 V2 是同一份（Q24 默认做法：不加 .env / .pem，只用相对形状，V3 按任意位置匹配）
assert_eq "$(jq -c '[.permissions.rules[] | select(.capability == "fs_read" and .effect == "deny") | .match] | first' "$A3")" \
  "$(jq -c .toolsSettings.read.deniedPaths "$A2")" "v3 fs_read deny 与 v2 的 deniedPaths 逐项相同"
# 除 fs_read 之外的每一种能力都整体 deny（复审 M-3）：能力名取自 2.31.1 引擎（KAS 0.66.34）认得的全集——skill 那一类工具
# （disclose_context）不看 tools、引擎总是加进工具集，subagent / context / power / mcp / diagnostics / sandbox_network 也都不该用到
for cap in fs_write shell web_fetch web_search subagent skill power context diagnostics mcp sandbox_network; do
  assert_eq "$(jq -r --arg c "$cap" '[.permissions.rules[] | select(.capability == $c and .effect == "deny" and (has("match") | not))] | length' "$A3")" "1" \
    "v3 ${cap} 整体 deny"
done
assert_eq "$(jq -r '[.permissions.rules[] | .capability] | length' "$A3")" "13" "v3 规则恰好 13 条：fs_read 的 allow 与 deny 各一条 + 11 种能力各一条整体 deny"
# 元测试：规则谓词真能拒——把 v2 定义喂给它必须报错（v2 只有 deny 规则、没有 allow）
assert_contains "$(jq -r "$_KIRO_V3_RULES_JQ"' v3_shape_error' "$A2")" "allow 规则不是恰好一条" "元测试：v2 形状的定义过不了 v3 规则谓词"

# ---- 安装 + 自检（物理路径：目录名带空格；macOS 的 mktemp 在 /var/folders → /private/var/folders 符号链接下）----
RD="$tmp/root dir"; CH="$tmp/work/chunks"; KH="$tmp/kiro-home"; RH="$tmp/real home"; mkdir -p "$RD" "$CH" "$KH/.kiro/agents" "$RH"
RD_P=$(cd "$RD" && pwd -P); CH_P=$(cd "$CH" && pwd -P)
NAME=codeup-reviewer-0123456789abcdef
inst=$(kiro_install_agent_v3 "$A3" "$KH/.kiro/agents" --root "$RD" --chunks "$CH" --name "$NAME" --real-home "$RH")
assert_eq "$inst" "$KH/.kiro/agents/${NAME}.json" "安装路径 = <agent 目录>/<名字>.json"
assert_eq "$(jq -r .name "$inst")" "$NAME" "安装后 name = --name"
assert_eq "$(jq -r .prompt "$inst")" "file://prompts/${NAME}.md" "安装后 prompt 是相对 file://prompts/<名字>.md"
assert_eq "$(cmp -s "$KH/.kiro/agents/prompts/${NAME}.md" "$ROOT/prompts/review-agent-prompt.md" && echo same)" "same" "提示词原样复制到 agent 目录的 prompts/ 下"
assert_eq "$(jq -c '[.permissions.rules[] | select(.effect == "allow") | .match] | first' "$inst")" "$(jq -nc --arg a "$RD_P" --arg b "$CH_P" '[$a, $b]')" \
  "allow 写成评审根目录与 chunks 的物理路径"
n_home=$(jq -r '[.toolsSettings.read.deniedPaths[] | select(startswith("~/"))] | length' "$A2")
assert_eq "$(jq -r --arg rh "$RH" '[.permissions.rules[] | select(.capability == "fs_read" and .effect == "deny") | .match[] | select(startswith($rh + "/"))] | length' "$inst")" "$n_home" \
  "每条 ~/ 形状都按真实 HOME 补了一份绝对副本"
assert_eq "$(jq -r '[.. | strings | select(contains("{{"))] | length' "$inst")" "0" "安装后没有任何占位符残留"
if kiro_agent_selfcheck_v3 "$inst" "$RD_P" "$CH_P" "$RH"; then TESTS_PASSED=$((TESTS_PASSED + 1)); else echo "FAIL: 自检应通过：${KIRO_AGENT_SELFCHECK_ERROR}" >&2; exit 1; fi
# 自检的每一条都有一个能触发它的反例（原因文案逐条点名）
neg() { # <名字> <jq 改写> <原因里应出现的片段>
  jq "$2" "$inst" > "$tmp/neg-$1.json"
  if kiro_agent_selfcheck_v3 "$tmp/neg-$1.json" "$RD_P" "$CH_P" "$RH"; then echo "FAIL: 自检反例 $1 竟然通过" >&2; exit 1; fi
  assert_contains "$KIRO_AGENT_SELFCHECK_ERROR" "$3" "自检反例 $1"
}
cp "$KH/.kiro/agents/prompts/${NAME}.md" "$tmp/prompts-keep.md"; mkdir -p "$tmp/prompts"; cp "$tmp/prompts-keep.md" "$tmp/prompts/${NAME}.md"
neg two-allow '.permissions.rules += [{capability: "fs_read", match: ["/"], effect: "allow"}]' "allow 规则不是恰好一条"
neg allow-shell '.permissions.rules |= map(if .effect == "allow" then .capability = "shell" else . end)' "唯一的 allow 规则不是 fs_read"
neg allow-exclude '.permissions.rules |= map(if .effect == "allow" then .exclude = ["x"] else . end)' "capability / match / effect 之外的键"
neg allow-wrong '.permissions.rules |= map(if .effect == "allow" then .match = ["/"] else . end)' "fs_read allow 的 match 写入的是"
neg ask '.permissions.rules += [{capability: "shell", effect: "ask"}]' "allow / deny 之外的 effect"
neg no-shell-deny '.permissions.rules |= map(select(.capability != "shell"))' "整体 deny"
neg shell-match '.permissions.rules |= map(if .capability == "shell" then .match = ["git *"] else . end)' "整体 deny"
neg extra-cap '.permissions.rules += [{capability: "codeup_unknown_cap", effect: "deny"}]' "之外的能力"
neg group-cap '.permissions.rules += [{capability: "all", effect: "deny"}]' "之外的能力"
neg dup-skill '.permissions.rules += [{capability: "skill", effect: "deny"}]' "整体 deny"
neg no-skill-deny '.permissions.rules |= map(select(.capability != "skill"))' "整体 deny"
neg subagent-match '.permissions.rules |= map(if .capability == "subagent" then .match = ["x"] else . end)' "整体 deny"
neg no-gitdeny '.permissions.rules |= map(if .capability == "fs_read" and .effect == "deny" then .match -= ["**/.git/**"] else . end)' "必需的拒绝形状"
neg no-realhome '.permissions.rules |= map(if .capability == "fs_read" and .effect == "deny" then .match |= map(select(startswith("'"$RH"'") | not)) else . end)' "按真实 HOME 展开"
neg toolssettings '.toolsSettings = {read: {allowedPaths: ["/"]}}' "V3 不该有的键"
neg allowedtools '.allowedTools = []' "V3 不该有的键"
neg hooks '.hooks = []' "V3 不该有的键"
neg mcpservers '.mcpServers = {}' "V3 不该有的键"
neg toolaliases '.toolAliases = {}' "V3 不该有的键"
neg tools '.tools = ["read", "grep", "glob", "shell"]' "tools 不是恰好"
neg resources '.resources = ["file://README.md"]' "resources 不为空"
neg mcpjson '.includeMcpJson = true' "includeMcpJson"
neg powers '.includePowers = true' "includePowers"
neg absprompt '.prompt = "file:///etc/passwd"' "相对 file://prompts/"
neg noperm 'del(.permissions)' "缺少 permissions 对象"
jq '.prompt = "file://prompts/missing.md"' "$inst" > "$tmp/neg-missing.json"
if kiro_agent_selfcheck_v3 "$tmp/neg-missing.json" "$RD_P" "$CH_P" "$RH"; then echo "FAIL: prompt 指向不存在的文件竟然通过" >&2; exit 1; fi
assert_contains "$KIRO_AGENT_SELFCHECK_ERROR" "不存在" "自检反例：prompt 指向不存在的文件"
printf '' > "$tmp/empty.json"
if kiro_agent_selfcheck_v3 "$tmp/empty.json" "$RD_P" "$CH_P" "$RH"; then echo "FAIL: 空文件竟然通过" >&2; exit 1; fi
assert_contains "$KIRO_AGENT_SELFCHECK_ERROR" "为空" "自检反例：0 字节文件"
# 安装器的拒绝：不落盘半成品
rc=0; kiro_install_agent_v3 "$A3" "$KH/.kiro/agents" --root "$RD" --chunks "$CH" --name x1 --real-home rel 2>/dev/null || rc=$?
assert_eq "$rc" "1" "安装器：--real-home 不是绝对路径 → 拒绝"
rc=0; kiro_install_agent_v3 "$A3" "$KH/.kiro/agents" --root "$RD" --chunks "$CH" --name x2 2>/dev/null || rc=$?
assert_eq "$rc" "1" "安装器：缺 --real-home → 拒绝"
mkdir -p "$tmp/kiro"; jq '.prompt = "file:///abs.md"' "$A3" > "$tmp/kiro/abs.json"
rc=0; kiro_install_agent_v3 "$tmp/kiro/abs.json" "$KH/.kiro/agents" --root "$RD" --chunks "$CH" --name x3 --real-home "$RH" 2>/dev/null || rc=$?
assert_eq "$rc" "1" "安装器：绝对 file:// prompt → 拒绝（V3 不接受）"
rc=0; kiro_install_agent_v3 "$A2" "$KH/.kiro/agents" --root "$RD" --chunks "$CH" --name x4 --real-home "$RH" 2>/dev/null || rc=$?
assert_eq "$rc" "1" "安装器：v2 形状的定义 → 拒绝（V3 下它会静默什么都读不到，S3 实测）"
rc=0; kiro_install_agent_v3 "$A3" "$KH/.kiro/agents" --root "$tmp/nope" --chunks "$CH" --name x5 --real-home "$RH" 2>/dev/null || rc=$?
assert_eq "$rc" "1" "安装器：评审根目录不存在 → 拒绝"
assert_eq "$(ls "$KH/.kiro/agents" | grep -c '^x[0-9]' || true)" "0" "安装器拒绝时不落盘半成品"

# ---- 临时 HOME + 许可清单 ----
mkdir -p "$tmp/bin"; for b in kiro-cli kiro-cli-chat kiro-cli-term 'bash (kiro-cli-term)'; do printf '#!/bin/sh\n' > "$tmp/bin/$b"; chmod +x "$tmp/bin/$b"; done
KH2="$tmp/kh2"; mkdir "$KH2"
kiro_run_home_prepare "$KH2" "$tmp/bin/kiro-cli"
assert_eq "$(ls "$KH2/.local/bin" | paste -sd, -)" "kiro-cli,kiro-cli-chat,kiro-cli-term" "兄弟程序都链接进临时 HOME（名字带空格的不算）"
assert_eq "$(readlink "$KH2/.local/bin/kiro-cli-chat")" "$tmp/bin/kiro-cli-chat" "链接指向入口同目录的那个文件"
assert_eq "$(cat "$KH2/.kiro/settings/kiroignore")" "AGENTS.md" "kiroignore 排除 AGENTS.md"
for d in .kiro/agents .config .local/share .cache .local/state; do
  assert_eq "$([[ -d "$KH2/$d" ]] && echo y)" "y" "临时 HOME 里建好了 $d"
done
rc=0; kiro_run_home_prepare "relative" "$tmp/bin/kiro-cli" 2>/dev/null || rc=$?; assert_eq "$rc" "1" "临时 HOME 不是绝对路径 → 拒绝"
rc=0; kiro_run_home_prepare "$KH2" "kiro-cli" 2>/dev/null || rc=$?; assert_eq "$rc" "1" "入口不是绝对路径 → 拒绝"
(
  export HOME="$RH" XDG_RUNTIME_DIR=/run/x XDG_CONFIG_HOME=/c TMPDIR="${TMPDIR:-/tmp}"
  kiro_env_allowlist
  kiro_env_isolate_home "$KH2"
  assert_eq "$(printf '%s\n' "${KIRO_ENV_ALLOW[@]}" | grep -c '^HOME=')" "1" "许可清单里只有一个 HOME"
  assert_eq "$(printf '%s\n' "${KIRO_ENV_ALLOW[@]}" | grep '^HOME=')" "HOME=$KH2" "HOME 换成临时 HOME"
  for kv in "XDG_CONFIG_HOME=$KH2/.config" "XDG_DATA_HOME=$KH2/.local/share" "XDG_CACHE_HOME=$KH2/.cache" "XDG_STATE_HOME=$KH2/.local/state"; do
    assert_eq "$(printf '%s\n' "${KIRO_ENV_ALLOW[@]}" | grep -c -x -F -- "$kv")" "1" "许可清单：$kv"
  done
  assert_eq "$(printf '%s\n' "${KIRO_ENV_ALLOW[@]}" | grep -c '^XDG_RUNTIME_DIR=' || true)" "0" "许可清单：去掉 XDG_RUNTIME_DIR"
  assert_eq "$(printf '%s\n' "${KIRO_ENV_ALLOW[@]}" | grep -c -x 'KIRO_LOG_NO_COLOR=1')" "1" "许可清单：其余条目原样保留"
  for kv in KIRO_DISABLE_EXPERIMENT_CONFIG=true KIRO_DISABLE_SESSION_TITLE_LLM=true; do
    assert_eq "$(printf '%s\n' "${KIRO_ENV_ALLOW[@]}" | grep -c -x -F -- "$kv")" "1" "许可清单：V3 固定带上 ${kv}（S8：只有环境变量能关的通道）"
  done
  # 经 kiro_env_exec 真正启动的子进程看到的就是这份（不经替身，真 env）
  seen=$(cd "$tmp" && kiro_env_exec KIRO_ENV_ALLOW env)
  assert_contains "$seen" "HOME=$KH2" "子进程的 HOME 是临时 HOME"
  assert_not_contains "$seen" "XDG_RUNTIME_DIR=" "子进程没有 XDG_RUNTIME_DIR"
  rc=0; kiro_env_isolate_home "$tmp/nope" 2>/dev/null || rc=$?; assert_eq "$rc" "1" "临时 HOME 不存在 → 拒绝、不改清单"
  report >/dev/null
)

# ---- 评审根目录：复制已隔离的业务库 ----
SRC="$tmp/biz"; mkdir -p "$SRC/src/sub" "$SRC/.git/objects" "$SRC/vendor/x/.git"
printf 'a\n' > "$SRC/src/app.py"; printf 'b\n' > "$SRC/a b.py"; printf 'c\n' > "$SRC/-dash.py"; printf 'd\n' > "$SRC/ünï.py"; printf 'e\n' > "$SRC/src/sub/x.txt"
printf 'gitfile\n' > "$SRC/vendor/x/.git/HEAD"; printf 'gitdir: ../.git\n' > "$SRC/src/.git"
P="$tmp/review-root"; mkdir "$P"
n=$(review_copy_to_root "$SRC" "$P")
assert_eq "$([[ -f "$P/repo/a b.py" && -f "$P/repo/-dash.py" && -f "$P/repo/ünï.py" && -f "$P/repo/src/sub/x.txt" ]] && echo y)" "y" "带空格 / 以 - 开头 / 非 ASCII 的文件名都复制了"
assert_eq "$([[ -e "$P/repo/.git" || -e "$P/repo/vendor/x/.git" || -e "$P/repo/src/.git" ]] && echo has-git || echo no-git)" "no-git" "任意深度的 .git（目录与文件）都不复制"
assert_eq "$n" "$(cd "$P/repo" && find . -print | wc -l | tr -d ' ')" "stdout 是副本条目数"
assert_eq "$(ls -A "$P")" "repo" "评审根目录下只有 repo/"
rc=0; review_copy_to_root "$SRC" "$P" >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1" "repo/ 已存在 → 拒绝（评审根目录必须是新建的）"
rc=0; review_copy_to_root "$tmp/nope" "$tmp" >/dev/null 2>&1 || rc=$?; assert_eq "$rc" "1" "业务库目录不存在 → 拒绝"
# 复制失败（假 tar 打包时报错）→ 返回 1
mkdir -p "$tmp/badtar"; printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == -cf ]] && exit 1; done\nexec %q "$@"\n' "$(command -v tar)" > "$tmp/badtar/tar"; chmod +x "$tmp/badtar/tar"
P2="$tmp/review-root2"; mkdir "$P2"
rc=0; ( PATH="$tmp/badtar:$PATH"; review_copy_to_root "$SRC" "$P2" ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "tar 打包失败 → 返回 1（不依赖调用方的 pipefail）"
# 复制到一半失败（假 tar 解包端先写出一个文件再报错，模拟磁盘写满）→ 返回 1，且不留半个副本：
# 真实磁盘满时失败评论也渲染在同一个 TMPDIR 里，半个副本占着空间，评论可能写不出来（复审 I-4）
mkdir -p "$tmp/halftar"; printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == -xf ]] && { cat > /dev/null; mkdir -p a; echo x > a/f1; echo "tar: write error: No space left on device" >&2; exit 1; }; done\nexec %q "$@"\n' "$(command -v tar)" > "$tmp/halftar/tar"; chmod +x "$tmp/halftar/tar"
P3="$tmp/review-root3"; mkdir "$P3"
rc=0; ( PATH="$tmp/halftar:$PATH"; review_copy_to_root "$SRC" "$P3" ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "解包到一半失败 → 返回 1"
assert_eq "$([[ -e "$P3/repo" ]] && echo left || echo removed)" "removed" "解包到一半失败 → 半个副本已删（不占着 TMPDIR 的空间）"

report
