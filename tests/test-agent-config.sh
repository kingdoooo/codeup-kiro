#!/usr/bin/env bash
# 受信 agent 定义（kiro/agent-codeup-reviewer.json）的静态契约 + 安装函数（scripts/lib/kiro-agent.sh）。
# 双兼容：V2 引擎读 toolsSettings.*.deniedPaths，V3 引擎读 permissions.rules；两套必须同组路径（ADR-0004）。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
ROOT=$(cd .. && pwd)
A="$ROOT/kiro/agent-codeup-reviewer.json"
source "$ROOT/scripts/lib/kiro-agent.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- 基本形态 ---
assert_rc "$(jq -e . "$A" >/dev/null 2>&1 && echo 0 || echo 1)" 0 "agent JSON 合法"
assert_eq "$(jq -r .name "$A")" "codeup-reviewer" "name"
# 三个工具名已在 v2 stream-json 事件的 _meta.kiro.toolName 实证（kiro-cli 对未知名字静默接受，agent validate 也不报）：
#   read → probe-results/kiro-headless/kiro-probe-t01-v2-iso、kiro-probe-t01-v2-forced-read
#   grep、glob → probe-results/kiro-headless/kiro-probe-t01r-toolnames（kind=search，两者均 completed）
assert_eq "$(jq -c .tools "$A")" '["read","grep","glob"]' "tools 只有 read/grep/glob（V2 工具名，已实证；V3 把 read 当标签）"
assert_eq "$(jq -c .allowedTools "$A")" '["read","grep","glob"]' "allowedTools 与 tools 一致"
assert_eq "$(jq -c .resources "$A")" '[]' "resources 为空（不自动载入任何工作区文件）"
assert_eq "$(jq -r .includeMcpJson "$A")" "false" "includeMcpJson=false"
assert_eq "$(jq -r .includePowers "$A")" "false" "includePowers=false"
assert_eq "$(jq -r '.mcpServers // {} | length' "$A")" "0" "不内联任何 MCP server"
assert_eq "$(jq -r '.hooks // {} | length' "$A")" "0" "不内联任何 hook"

# --- V2：三种只读工具的 deniedPaths 同组且覆盖凭证路径 ---
denied=$(jq -c .toolsSettings.read.deniedPaths "$A")
assert_eq "$(jq -r '.toolsSettings.read.deniedPaths | length > 0' "$A")" "true" "V2 deniedPaths 非空"
assert_eq "$(jq -c .toolsSettings.grep.deniedPaths "$A")" "$denied" "V2 grep.deniedPaths 与 read 同组"
assert_eq "$(jq -c .toolsSettings.glob.deniedPaths "$A")" "$denied" "V2 glob.deniedPaths 与 read 同组"
for p in '~/.aws' '~/.aws/**' '~/.ssh' '~/.ssh/**' '~/.kiro' '~/.kiro/**' '~/.config/**' '~/.git-credentials' '/root/.aws/**' '**/.netrc' '**/.git/config'; do
  assert_contains "$(jq -r '.toolsSettings.read.deniedPaths[]' "$A")" "$p" "V2 deniedPaths 含 $p"
done

# --- V3：permissions.rules 全部为 deny，fs_read 与 V2 同组路径，shell/fs_write/web_* 整体拒绝 ---
assert_eq "$(jq -r '.permissions.rules | length > 0' "$A")" "true" "V3 permissions.rules 非空"
assert_eq "$(jq -r '[.permissions.rules[] | select(.effect != "deny")] | length' "$A")" "0" "V3 只有 deny 规则（不放行任何能力）"
assert_eq "$(jq -c '[.permissions.rules[] | select(.capability == "fs_read" and .effect == "deny") | .match] | first' "$A")" "$denied" \
  "V3 fs_read deny 的 match 与 V2 deniedPaths 同组"
for cap in shell fs_write web_fetch web_search; do
  assert_eq "$(jq -r --arg c "$cap" '[.permissions.rules[] | select(.capability == $c and .effect == "deny" and (.match | not))] | length' "$A")" "1" \
    "V3 ${cap} 整体 deny（不带 match 限定）"
done
assert_eq "$(jq -r '[.permissions.rules[] | .capability] | map(select(. == "all" or . == "builtin" or . == "filesystem")) | length' "$A")" "0" \
  "V3 不使用会误放行的元能力"

# --- prompt：相对 file://，相对 agent 文件所在目录可解析到集成包内的提示词 ---
prompt=$(jq -r .prompt "$A")
assert_eq "$([[ "$prompt" == file://* ]] && echo y || echo n)" "y" "prompt 是 file:// 引用（实际：${prompt}）"
assert_eq "$([[ "$prompt" == file:///* ]] && echo abs || echo rel)" "rel" "集成包内的 prompt 引用是相对路径（安装时再改写为绝对）"
rel_target="$ROOT/kiro/${prompt#file://}"
assert_eq "$([[ -r "$rel_target" ]] && echo y || echo n)" "y" "相对路径按 agent 文件目录解析后指向存在的文件：$rel_target"
assert_eq "$(cd "$(dirname "$rel_target")" && pwd)/$(basename "$rel_target")" "$ROOT/prompts/review-agent-prompt.md" "指向 prompts/review-agent-prompt.md"
assert_contains "$(cat "$ROOT/prompts/review-agent-prompt.md")" "只读" "agent 提示词含只读角色描述"

# --- 安装函数：按 name 落盘、prompt 改写为绝对路径、其余字段不变 ---
dest=$(kiro_install_agent "$A" "$tmp/agents")
assert_eq "$dest" "$tmp/agents/codeup-reviewer.json" "安装路径 = <dest>/<name>.json"
assert_eq "$(jq -r .prompt "$dest")" "file://$ROOT/prompts/review-agent-prompt.md" "安装后 prompt 为绝对 file:// 路径"
assert_eq "$(jq -c 'del(.prompt)' "$dest")" "$(jq -c 'del(.prompt)' "$A")" "安装只改写 prompt"
# 幂等：重复安装覆盖同一文件
dest2=$(kiro_install_agent "$A" "$tmp/agents")
assert_eq "$dest2" "$dest" "重复安装落到同一路径"
# 负向：prompt 指向不存在的文件 → 安装失败（宁可不跑评审也不能带空提示词/默认 agent 跑）
jq '.prompt = "file://../prompts/does-not-exist.md"' "$A" > "$tmp/bad-prompt.json"
rc=0; err=$(kiro_install_agent "$tmp/bad-prompt.json" "$tmp/agents-bad" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "prompt 文件缺失：安装失败"
assert_contains "$err" "does-not-exist.md" "prompt 文件缺失：报错点名文件"
assert_eq "$([[ -e "$tmp/agents-bad/codeup-reviewer.json" ]] && echo written || echo none)" "none" "prompt 文件缺失：不落盘半成品"
# 负向：缺 name → 失败
jq 'del(.name)' "$A" > "$tmp/no-name.json"
rc=0; kiro_install_agent "$tmp/no-name.json" "$tmp/agents-noname" >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "缺 name：安装失败"
# 负向：缺 prompt → 失败（只读角色约束就在 prompt 里，缺了等于用默认系统提示词跑）
jq 'del(.prompt)' "$A" > "$tmp/no-prompt.json"
rc=0; err=$(kiro_install_agent "$tmp/no-prompt.json" "$tmp/agents-noprompt" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "缺 prompt：安装失败"
assert_contains "$err" "prompt" "缺 prompt：报错点名 prompt"
assert_eq "$([[ -e "$tmp/agents-noprompt/codeup-reviewer.json" ]] && echo written || echo none)" "none" "缺 prompt：不落盘"
# 负向：绝对 file:// 指向不存在的文件 → 失败
jq '.prompt = "file:///nonexistent/dir/nope.md"' "$A" > "$tmp/abs-missing.json"
rc=0; err=$(kiro_install_agent "$tmp/abs-missing.json" "$tmp/agents-absmissing" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "绝对 prompt 文件缺失：安装失败"
assert_contains "$err" "/nonexistent/dir/nope.md" "绝对 prompt 文件缺失：报错点名文件"
assert_eq "$([[ -e "$tmp/agents-absmissing/codeup-reviewer.json" ]] && echo written || echo none)" "none" "绝对 prompt 文件缺失：不落盘"
# 绝对路径 prompt 原样保留
jq --arg p "file://$ROOT/prompts/review-agent-prompt.md" '.prompt = $p' "$A" > "$tmp/abs-prompt.json"
dest3=$(kiro_install_agent "$tmp/abs-prompt.json" "$tmp/agents-abs")
assert_eq "$(jq -r .prompt "$dest3")" "file://$ROOT/prompts/review-agent-prompt.md" "绝对 prompt 原样保留"
# 内联文本 prompt 原样保留
jq '.prompt = "你是只读评审助手。"' "$A" > "$tmp/inline-prompt.json"
dest4=$(kiro_install_agent "$tmp/inline-prompt.json" "$tmp/agents-inline")
assert_eq "$(jq -r .prompt "$dest4")" "你是只读评审助手。" "内联 prompt 原样保留"
# 清理同名旧文件：常驻执行器上旧版集成包按 agent-codeup-reviewer.json 装过同名 agent
mkdir -p "$tmp/agents-stale"
jq '.prompt = "旧版内联提示词"' "$A" > "$tmp/agents-stale/agent-codeup-reviewer.json"
jq '.name = "someone-else"' "$A" > "$tmp/agents-stale/other.json"
dest5=$(kiro_install_agent "$A" "$tmp/agents-stale" 2>/dev/null)
assert_eq "$([[ -e "$tmp/agents-stale/agent-codeup-reviewer.json" ]] && echo kept || echo removed)" "removed" "同名旧 agent 文件被移除"
assert_eq "$([[ -e "$tmp/agents-stale/other.json" ]] && echo kept || echo removed)" "kept" "不同 name 的文件不受影响"
assert_eq "$(ls "$tmp/agents-stale" | sort | paste -sd, -)" "codeup-reviewer.json,other.json" "安装目录只剩新文件与无关文件"

# --- 真实 kiro-cli（若本机有）：集成包内与安装后的定义都通过 agent validate ---
# 注意：kiro-cli 2.21 的 agent validate 无论结果如何都 exit 0，错误只打印在输出里（实测），所以看输出而不是退出码，
# 并用一个必然出错的文件做正控，证明这个检查真的会失败。
if command -v kiro-cli >/dev/null 2>&1 && kiro-cli agent validate --help >/dev/null 2>&1; then
  esc=$(printf '\033')
  vout=$(kiro-cli agent validate --path "$A" 2>&1 | sed "s/${esc}\[[0-9;]*m//g" || true)
  assert_not_contains "$vout" "Error" "kiro-cli agent validate：集成包内定义无错误（输出：${vout:-<空>}）"
  vout=$(kiro-cli agent validate --path "$dest" 2>&1 | sed "s/${esc}\[[0-9;]*m//g" || true)
  assert_not_contains "$vout" "Error" "kiro-cli agent validate：安装后定义无错误（输出：${vout:-<空>}）"
  vout=$(kiro-cli agent validate --path "$tmp/no-name.json" 2>&1 | sed "s/${esc}\[[0-9;]*m//g" || true)
  assert_contains "$vout" "Error" "正控：缺 name 的定义 validate 输出含 Error（证明上面的检查能失败）"
  vout=$(kiro-cli agent validate --path "$tmp/abs-missing.json" 2>&1 | sed "s/${esc}\[[0-9;]*m//g" || true)
  assert_contains "$vout" "Error" "正控：prompt 指向不存在文件的定义 validate 输出含 Error"
else
  echo "INFO: 本机无 kiro-cli，跳过 agent validate 断言" >&2
fi

report
