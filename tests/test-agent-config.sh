#!/usr/bin/env bash
# 受信 agent 定义（kiro/agent-codeup-reviewer.json）的静态契约 + 安装函数（scripts/lib/kiro-agent.sh）。
# 双兼容：V2 引擎读 toolsSettings.*.deniedPaths / allowedPaths，V3 引擎读 permissions.rules；deny 两套必须同组路径（ADR-0004）。
# 读取边界（票 15 / 15-fix #3）：allowedPaths 是**许可清单**——业务库 checkout 与 diff chunk 目录两个运行时路径，定义里的
# 占位符只是文档；安装时由 kiro_install_agent --workspace/--chunks（必填）把 read/grep/glob 三处结构化写成物理路径，
# 与定义里写了什么无关；缺路径参数就拒绝安装、不落盘。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
ROOT=$(cd .. && pwd)
A="$ROOT/kiro/agent-codeup-reviewer.json"
source "$ROOT/scripts/lib/kiro-agent.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 安装用的两条运行时路径：目录名带空格，且 mktemp 在 macOS 上给的是 /var/folders（→ /private/var/folders 的符号链接），
# 所以 WS_P/CH_P 取物理路径，安装结果必须与之逐字相等。
WS="$tmp/ws dir"; CH="$tmp/work/chunks"; mkdir -p "$WS" "$CH"
WS_P=$(cd "$WS" && pwd -P); CH_P=$(cd "$CH" && pwd -P)
PH_WS='{{REVIEW_WORKSPACE}}'; PH_CH='{{REVIEW_CHUNKS}}'
# 安装后的定义里不得残留任何占位符（任何字符串值里都不能有 {{ ）
leftover_count() { jq '[.. | strings | select(contains("{{"))] | length' "$1"; }

# --- 基本形态 ---
assert_rc "$(jq -e . "$A" >/dev/null 2>&1 && echo 0 || echo 1)" 0 "agent JSON 合法（占位符是合法字符串）"
assert_eq "$(jq -r .name "$A")" "codeup-reviewer" "name"
# 三个工具名已在 v2 stream-json 事件的 _meta.kiro.toolName 实证（kiro-cli 对未知名字静默接受，agent validate 也不报）：
#   read → probe-results/kiro-headless/kiro-probe-t01-v2-iso、kiro-probe-t01-v2-forced-read
#   grep、glob → probe-results/kiro-headless/kiro-probe-t01r-toolnames（kind=search，两者均 completed）
assert_eq "$(jq -c .tools "$A")" '["read","grep","glob"]' "tools 只有 read/grep/glob（V2 工具名，已实证；V3 把 read 当标签）"
# allowedTools 清空：免确认只能来自 allowedPaths（路径边界），不能来自「整个工具免审」——
# 否则 allowedPaths 形同虚设（票 15 / P1-15）。
assert_eq "$(jq -c .allowedTools "$A")" '[]' "allowedTools 为空（免确认只来自 allowedPaths）"
for t in read grep glob; do
  assert_not_contains "$(jq -r '.allowedTools[]?' "$A")" "$t" "allowedTools 不含 $t"
done
assert_eq "$(jq -c .resources "$A")" '[]' "resources 为空（不自动载入任何工作区文件）"
assert_eq "$(jq -r .includeMcpJson "$A")" "false" "includeMcpJson=false"
assert_eq "$(jq -r .includePowers "$A")" "false" "includePowers=false"
assert_eq "$(jq -r '.mcpServers // {} | length' "$A")" "0" "不内联任何 MCP server"
assert_eq "$(jq -r '.hooks // {} | length' "$A")" "0" "不内联任何 hook"

# --- V2：三种只读工具的 allowedPaths 同组，恰好是两个占位符（目录本身，不带 /**：P1-15 T1 实测目录路径即匹配子路径）---
for t in read grep glob; do
  assert_eq "$(jq -c --arg t "$t" '.toolsSettings[$t].allowedPaths' "$A")" "[\"$PH_WS\",\"$PH_CH\"]" \
    "V2 ${t}.allowedPaths 恰好是业务库与 chunks 两个占位符"
done

# --- V2：三种只读工具的 deniedPaths 同组且覆盖凭证路径与 .git ---
denied=$(jq -c .toolsSettings.read.deniedPaths "$A")
assert_eq "$(jq -r '.toolsSettings.read.deniedPaths | length > 0' "$A")" "true" "V2 deniedPaths 非空"
assert_eq "$(jq -c .toolsSettings.grep.deniedPaths "$A")" "$denied" "V2 grep.deniedPaths 与 read 同组"
assert_eq "$(jq -c .toolsSettings.glob.deniedPaths "$A")" "$denied" "V2 glob.deniedPaths 与 read 同组"
# `**/.git` 与 `**/.git/**`：.git/FETCH_HEAD、.git/logs/* 可能带凭证 URL；diff 已在输入里，模型没有理由读 .git（票 15）
for p in '~/.aws' '~/.aws/**' '~/.ssh' '~/.ssh/**' '~/.kiro' '~/.kiro/**' '~/.config/**' '~/.git-credentials' '/root/.aws/**' '**/.netrc' '**/.git/config' '**/.git' '**/.git/**'; do
  assert_eq "$(jq -r --arg p "$p" '.toolsSettings.read.deniedPaths | index($p) != null' "$A")" "true" "V2 deniedPaths 含 $p"
done

# --- V3：permissions.rules 全部为 deny，fs_read 与 V2 同组路径，shell/fs_write/web_* 整体拒绝 ---
# V3 不上生产（ADR-0004），不为它设计 allow 规则：只保证 deny 同组（含 .git 两条）。
assert_eq "$(jq -r '.permissions.rules | length > 0' "$A")" "true" "V3 permissions.rules 非空"
assert_eq "$(jq -r '[.permissions.rules[] | select(.effect != "deny")] | length' "$A")" "0" "V3 只有 deny 规则（不放行任何能力）"
assert_eq "$(jq -c '[.permissions.rules[] | select(.capability == "fs_read" and .effect == "deny") | .match] | first' "$A")" "$denied" \
  "V3 fs_read deny 的 match 与 V2 deniedPaths 同组（含 .git 两条）"
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

# --- 安装函数：按 name 落盘、prompt 改写为绝对路径、allowedPaths 三处结构化写入、其余字段不变 ---
# 15-fix #3：不再做模板替换。--workspace/--chunks **必填**，安装时用 jq 把 .toolsSettings.read/grep/glob.allowedPaths
# 三处一律写成 [<workspace 物理路径>, <chunks 物理路径>]，与定义文件里写了什么无关；定义文件里的占位符只是文档。
INJECTED=$(jq -nc --arg a "$WS_P" --arg b "$CH_P" '[$a, $b]')
allowed_of() { jq -c --arg t "$2" '.toolsSettings[$t].allowedPaths' "$1"; }
dest=$(kiro_install_agent "$A" "$tmp/agents" --workspace "$WS" --chunks "$CH")
assert_eq "$dest" "$tmp/agents/codeup-reviewer.json" "安装路径 = <dest>/<name>.json"
assert_rc "$(jq -e . "$dest" >/dev/null 2>&1 && echo 0 || echo 1)" 0 "安装后 JSON 合法（路径带空格）"
assert_eq "$(jq -r .prompt "$dest")" "file://$ROOT/prompts/review-agent-prompt.md" "安装后 prompt 为绝对 file:// 路径"
for t in read grep glob; do
  assert_eq "$(allowed_of "$dest" "$t")" "$INJECTED" "安装后 ${t}.allowedPaths = 业务库物理路径 + chunks 物理路径"
done
assert_eq "$(jq -c '.toolsSettings | [.read.allowedPaths, .grep.allowedPaths, .glob.allowedPaths] | unique | length' "$dest")" "1" "安装后三处 allowedPaths 相等"
assert_eq "$(leftover_count "$dest")" "0" "安装后没有残留占位符"
assert_eq "$(jq -c 'del(.prompt) | del(.toolsSettings[].allowedPaths)' "$dest")" "$(jq -c 'del(.prompt) | del(.toolsSettings[].allowedPaths)' "$A")" \
  "安装只改写 prompt 与三处 allowedPaths，其余字段不变"
assert_eq "$(jq -c .allowedTools "$dest")" '[]' "安装后 allowedTools 仍为空"
# 幂等：重复安装覆盖同一文件
dest2=$(kiro_install_agent "$A" "$tmp/agents" --workspace "$WS" --chunks "$CH")
assert_eq "$dest2" "$dest" "重复安装落到同一路径"

# --- 结构化写入不依赖定义文件的形态（15-fix #3 / #13：靠「占位符字符串还在不在」会漏掉 grep 没写 allowedPaths 的定义）---
ABS_PROMPT="file://$ROOT/prompts/review-agent-prompt.md"   # 派生定义落在 $tmp 下，相对 file:// 会失去解析基准
# ① 定义里 grep 那一处根本没有 allowedPaths → 安装后三处照样都是注入值（旧实现：装成功、grep 无边界）
jq --arg p "$ABS_PROMPT" '.prompt = $p | del(.toolsSettings.grep.allowedPaths)' "$A" > "$tmp/no-grep-allow.json"
dest_ng=$(kiro_install_agent "$tmp/no-grep-allow.json" "$tmp/agents-ng" --workspace "$WS" --chunks "$CH")
assert_eq "$(allowed_of "$dest_ng" grep)" "$INJECTED" "定义缺 grep.allowedPaths：安装后 grep 仍被写成注入值"
assert_eq "$(jq -c '.toolsSettings | [.read.allowedPaths, .grep.allowedPaths, .glob.allowedPaths] | unique | length' "$dest_ng")" "1" "定义缺 grep.allowedPaths：三处相等"
# ② 定义里三处都没有 allowedPaths → 同样注入（安装器不信任定义文件的形态）
jq --arg p "$ABS_PROMPT" '.prompt = $p | del(.toolsSettings[].allowedPaths)' "$A" > "$tmp/no-allow.json"
dest_na=$(kiro_install_agent "$tmp/no-allow.json" "$tmp/agents-na" --workspace "$WS" --chunks "$CH")
for t in read grep glob; do
  assert_eq "$(allowed_of "$dest_na" "$t")" "$INJECTED" "定义无任何 allowedPaths：安装后 ${t} 仍是注入值"
done
# ③ 定义里 allowedPaths 写了别的东西（多一条 /**、或干脆是 "/"）→ 整个数组被覆盖，不残留
jq --arg p "$ABS_PROMPT" --arg s "${PH_WS}/**" '.prompt = $p | .toolsSettings.read.allowedPaths += [$s] | .toolsSettings.glob.allowedPaths = ["/"]' "$A" > "$tmp/junk-allow.json"
dest_j=$(kiro_install_agent "$tmp/junk-allow.json" "$tmp/agents-junk" --workspace "$WS" --chunks "$CH")
assert_eq "$(allowed_of "$dest_j" read)" "$INJECTED" "定义多写一条 /**：安装后 read 恰好两条注入值"
assert_eq "$(allowed_of "$dest_j" glob)" "$INJECTED" "定义把 glob 写成 /：安装后 glob 仍是注入值（不是 /）"
assert_eq "$(leftover_count "$dest_j")" "0" "覆盖后没有残留占位符"
# ④ 定义里没有 toolsSettings 对象 → 安装器把它建出来
jq --arg p "$ABS_PROMPT" '.prompt = $p | del(.toolsSettings)' "$A" > "$tmp/no-ts.json"
dest_nt=$(kiro_install_agent "$tmp/no-ts.json" "$tmp/agents-nt" --workspace "$WS" --chunks "$CH")
assert_eq "$(allowed_of "$dest_nt" grep)" "$INJECTED" "定义无 toolsSettings：安装后 grep.allowedPaths 仍是注入值"

# --- 占位符注入：路径规范化与 JSON 转义 ---
# 相对路径 → 绝对（安装函数自己 cd && pwd -P，不信任调用方给的形态）
dest_rel=$(cd "$tmp" && kiro_install_agent "$A" "$tmp/agents-rel" --workspace "./ws dir" --chunks "./work/chunks")
assert_eq "$(allowed_of "$dest_rel" read)" "$INJECTED" "相对路径注入后为绝对物理路径"
# 符号链接 → 物理路径（kiro-cli 按解析后的路径比对，写逻辑路径会全部落在 allow 之外：P1-15）
ln -s "$WS" "$tmp/wslink"
dest_ln=$(kiro_install_agent "$A" "$tmp/agents-ln" --workspace "$tmp/wslink" --chunks "$CH")
assert_eq "$(jq -r '.toolsSettings.read.allowedPaths[0]' "$dest_ln")" "$WS_P" "符号链接路径注入后为物理路径"
# 含引号、反斜杠、美元号、非 ASCII 的目录名：经 jq 转义后 JSON 仍合法且逐字相等
WEIRD="$tmp/ws \"q\" back\\slash \$d 中文"
mkdir -p "$WEIRD"; WEIRD_P=$(cd "$WEIRD" && pwd -P)
dest_w=$(kiro_install_agent "$A" "$tmp/agents-weird" --workspace "$WEIRD" --chunks "$CH")
assert_rc "$(jq -e . "$dest_w" >/dev/null 2>&1 && echo 0 || echo 1)" 0 "特殊字符路径：安装后 JSON 合法"
assert_eq "$(jq -r '.toolsSettings.read.allowedPaths[0]' "$dest_w")" "$WEIRD_P" "特殊字符路径：逐字注入"
assert_eq "$(jq -r '.toolsSettings.glob.allowedPaths[0]' "$dest_w")" "$WEIRD_P" "特殊字符路径：三个工具同样注入（glob）"

# --- 负向：--workspace / --chunks 缺任一 → 拒绝安装、不落盘（allow 空在 headless 下等于每次读取都被拒，宁可不跑）---
rc=0; err=$(kiro_install_agent "$A" "$tmp/agents-nows" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "缺 --workspace 与 --chunks：安装失败"
assert_contains "$err" "--workspace" "缺参数：报错点名 --workspace"
assert_contains "$err" "--chunks" "缺参数：报错点名 --chunks"
assert_eq "$([[ -e "$tmp/agents-nows" ]] && echo written || echo none)" "none" "缺参数：目标目录连半成品都没有"
rc=0; err=$(kiro_install_agent "$A" "$tmp/agents-noch" --workspace "$WS" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "只给 --workspace 缺 --chunks：安装失败"
assert_eq "$([[ -e "$tmp/agents-noch" ]] && echo written || echo none)" "none" "缺 --chunks：不落盘"
rc=0; err=$(kiro_install_agent "$A" "$tmp/agents-nows2" --chunks "$CH" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "只给 --chunks 缺 --workspace：安装失败"
assert_eq "$([[ -e "$tmp/agents-nows2" ]] && echo written || echo none)" "none" "缺 --workspace：不落盘"
# 定义没有任何 allowedPaths 也一样必填（旧实现允许「无占位符 + 无参数 → 原样安装」，那会装出一份没有边界的 agent）
rc=0; kiro_install_agent "$tmp/no-allow.json" "$tmp/agents-na-noargs" >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "定义无 allowedPaths 且不传路径参数：同样拒绝安装"
assert_eq "$([[ -e "$tmp/agents-na-noargs" ]] && echo written || echo none)" "none" "定义无 allowedPaths 且不传路径参数：不落盘"
# 负向：目录不存在 / 不是目录 / 取值为空 → 失败（路径必须能 cd 进去取物理路径）
rc=0; err=$(kiro_install_agent "$A" "$tmp/agents-nodir" --workspace "$tmp/does-not-exist" --chunks "$CH" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "--workspace 目录不存在：安装失败"
assert_contains "$err" "does-not-exist" "--workspace 目录不存在：报错点名路径"
assert_eq "$([[ -e "$tmp/agents-nodir" ]] && echo written || echo none)" "none" "--workspace 目录不存在：不落盘"
: > "$tmp/a-file"
rc=0; kiro_install_agent "$A" "$tmp/agents-file" --workspace "$WS" --chunks "$tmp/a-file" >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "--chunks 指向文件而非目录：安装失败"
rc=0; kiro_install_agent "$A" "$tmp/agents-empty" --workspace "" --chunks "$CH" >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "--workspace 取值为空：安装失败"
# 负向：未知参数 → 失败（拼错 --workspce 不能静默变成「没给」）
rc=0; err=$(kiro_install_agent "$A" "$tmp/agents-typo" --workspce "$WS" --chunks "$CH" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "未知参数：安装失败"
assert_contains "$err" "--workspce" "未知参数：报错点名"

# --- 负向：prompt 相关（传全路径参数，确保失败原因就是 prompt 本身）---
# prompt 指向不存在的文件 → 安装失败（宁可不跑评审也不能带空提示词/默认 agent 跑）
jq '.prompt = "file://../prompts/does-not-exist.md"' "$A" > "$tmp/bad-prompt.json"
rc=0; err=$(kiro_install_agent "$tmp/bad-prompt.json" "$tmp/agents-bad" --workspace "$WS" --chunks "$CH" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "prompt 文件缺失：安装失败"
assert_contains "$err" "does-not-exist.md" "prompt 文件缺失：报错点名文件"
assert_eq "$([[ -e "$tmp/agents-bad/codeup-reviewer.json" ]] && echo written || echo none)" "none" "prompt 文件缺失：不落盘半成品"
# 缺 name → 失败
jq 'del(.name)' "$A" > "$tmp/no-name.json"
rc=0; kiro_install_agent "$tmp/no-name.json" "$tmp/agents-noname" --workspace "$WS" --chunks "$CH" >/dev/null 2>&1 || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "缺 name：安装失败"
# 缺 prompt → 失败（只读角色约束就在 prompt 里，缺了等于用默认系统提示词跑）
jq 'del(.prompt)' "$A" > "$tmp/no-prompt.json"
rc=0; err=$(kiro_install_agent "$tmp/no-prompt.json" "$tmp/agents-noprompt" --workspace "$WS" --chunks "$CH" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "缺 prompt：安装失败"
assert_contains "$err" "prompt" "缺 prompt：报错点名 prompt"
assert_eq "$([[ -e "$tmp/agents-noprompt/codeup-reviewer.json" ]] && echo written || echo none)" "none" "缺 prompt：不落盘"
# 绝对 file:// 指向不存在的文件 → 失败
jq '.prompt = "file:///nonexistent/dir/nope.md"' "$A" > "$tmp/abs-missing.json"
rc=0; err=$(kiro_install_agent "$tmp/abs-missing.json" "$tmp/agents-absmissing" --workspace "$WS" --chunks "$CH" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "绝对 prompt 文件缺失：安装失败"
assert_contains "$err" "/nonexistent/dir/nope.md" "绝对 prompt 文件缺失：报错点名文件"
assert_eq "$([[ -e "$tmp/agents-absmissing/codeup-reviewer.json" ]] && echo written || echo none)" "none" "绝对 prompt 文件缺失：不落盘"
# 绝对路径 prompt 原样保留（allowedPaths 照样注入）
jq --arg p "$ABS_PROMPT" '.prompt = $p' "$A" > "$tmp/abs-prompt.json"
dest3=$(kiro_install_agent "$tmp/abs-prompt.json" "$tmp/agents-abs" --workspace "$WS" --chunks "$CH")
assert_eq "$(jq -r .prompt "$dest3")" "$ABS_PROMPT" "绝对 prompt 原样保留"
assert_eq "$(allowed_of "$dest3" read)" "$INJECTED" "绝对 prompt 分支同样注入 allowedPaths"
# 内联文本 prompt 原样保留（allowedPaths 照样注入）
jq '.prompt = "你是只读评审助手。"' "$A" > "$tmp/inline-prompt.json"
dest4=$(kiro_install_agent "$tmp/inline-prompt.json" "$tmp/agents-inline" --workspace "$WS" --chunks "$CH")
assert_eq "$(jq -r .prompt "$dest4")" "你是只读评审助手。" "内联 prompt 原样保留"
assert_eq "$(allowed_of "$dest4" grep)" "$INJECTED" "内联 prompt 分支同样注入 allowedPaths"
# 清理同名旧文件：常驻执行器上旧版集成包按 agent-codeup-reviewer.json 装过同名 agent
mkdir -p "$tmp/agents-stale"
jq '.prompt = "旧版内联提示词"' "$A" > "$tmp/agents-stale/agent-codeup-reviewer.json"
jq '.name = "someone-else"' "$A" > "$tmp/agents-stale/other.json"
dest5=$(kiro_install_agent "$A" "$tmp/agents-stale" --workspace "$WS" --chunks "$CH" 2>/dev/null)
assert_eq "$([[ -e "$tmp/agents-stale/agent-codeup-reviewer.json" ]] && echo kept || echo removed)" "removed" "同名旧 agent 文件被移除"
assert_eq "$([[ -e "$tmp/agents-stale/other.json" ]] && echo kept || echo removed)" "kept" "不同 name 的文件不受影响"
assert_eq "$(ls "$tmp/agents-stale" | sort | paste -sd, -)" "codeup-reviewer.json,other.json" "安装目录只剩新文件与无关文件"

# --- 子进程环境许可清单 kiro_env_allowlist：**固定名单** + KIRO_ENV_PASSTHROUGH 逃生口（15-fix #11/#12）---
# 不做形状匹配：KIRO_* / *_PROXY 会放行 CORP_SECRET_PROXY、客户自定义的 KIRO_…；额外需要的变量走 KIRO_ENV_PASSTHROUGH（只放名字）。
LIB="$ROOT/scripts/lib/kiro-agent.sh"
names_under() { # 在可控环境里跑 kiro_env_allowlist，输出透传的变量名（每行一个）；$@ = VAR=值
  env -i PATH="$PATH" "$@" bash -c 'set -euo pipefail; source "$1"; kiro_env_allowlist; kiro_env_allowlist_names' _ "$LIB"
}
env_names=$(names_under HOME="$tmp/h" USER=u TERM=dumb TMPDIR="$tmp" LANG=C.UTF-8 LC_ALL=C LC_CTYPE=C.UTF-8 LC_TIME=C \
  KIRO_API_KEY=k KIRO_FOO=1 KIRO_LOG_NO_COLOR=0 \
  HTTP_PROXY=http://p:1 HTTPS_PROXY=http://p:1 NO_PROXY=localhost http_proxy=http://p:1 https_proxy=http://p:1 no_proxy=localhost \
  CORP_SECRET_PROXY=s PROXY_USER=pu SSL_CERT_FILE=/c.pem SSL_CERT_DIR=/certs CURL_CA_BUNDLE=/b.pem \
  XDG_CONFIG_HOME=/x1 XDG_DATA_HOME=/x2 XDG_CACHE_HOME=/x3 XDG_STATE_HOME=/x4 XDG_RUNTIME_DIR=/x5 \
  YUNXIAO_TOKEN=t YUNXIAO_ORG_ID=o CODEUP_REPO_ID=r CODEUP_BOT_USERNAME=b AWS_SECRET_ACCESS_KEY=a GIT_ASKPASS=/g CI_COMMIT_REF_NAME=x LD_LIBRARY_PATH=/l)
for v in PATH HOME USER TERM TMPDIR LANG LC_ALL LC_CTYPE KIRO_API_KEY HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy \
         SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME KIRO_LOG_NO_COLOR; do
  assert_eq "$(printf '%s\n' "$env_names" | grep -c -x -- "$v")" "1" "固定名单透传 ${v}（恰好一次）"
done
for v in LC_TIME KIRO_FOO CORP_SECRET_PROXY PROXY_USER XDG_RUNTIME_DIR LD_LIBRARY_PATH \
         YUNXIAO_TOKEN YUNXIAO_ORG_ID CODEUP_REPO_ID CODEUP_BOT_USERNAME AWS_SECRET_ACCESS_KEY GIT_ASKPASS CI_COMMIT_REF_NAME; do
  assert_eq "$(printf '%s\n' "$env_names" | grep -c -x -- "$v")" "0" "固定名单不透传 ${v}（名单之外，即使形状像 KIRO_* / *_PROXY / XDG_*）"
done
# 取值原样；KIRO_LOG_NO_COLOR 固定为 1（用户设成 0 也被覆盖）
env_pairs=$(env -i PATH="$PATH" HOME="$tmp/h" KIRO_API_KEY='k=with=equals and space' KIRO_LOG_NO_COLOR=0 \
  bash -c 'set -euo pipefail; source "$1"; kiro_env_allowlist; printf "%s\n" "${KIRO_ENV_ALLOW[@]}"' _ "$LIB")
assert_contains "$env_pairs" "KIRO_API_KEY=k=with=equals and space" "取值原样（含等号与空格）"
assert_eq "$(printf '%s\n' "$env_pairs" | grep -c '^KIRO_LOG_NO_COLOR=')" "1" "KIRO_LOG_NO_COLOR 只出现一次"
assert_contains "$env_pairs" "KIRO_LOG_NO_COLOR=1" "KIRO_LOG_NO_COLOR 固定为 1"
assert_not_contains "$env_pairs" "KIRO_LOG_NO_COLOR=0" "用户设的 KIRO_LOG_NO_COLOR=0 被覆盖"
assert_contains "$env_pairs" "HOME=$tmp/h" "HOME 原样透传（登录态与 agent 目录都靠它）"
# 只透传已导出的变量：未导出的 shell 变量本来也到不了子进程
seen_unexported=$(env -i PATH="$PATH" HOME="$tmp/h" bash -c 'set -euo pipefail; source "$1"; KIRO_API_KEY=notexported; kiro_env_allowlist; kiro_env_allowlist_names' _ "$LIB")
assert_eq "$(printf '%s\n' "$seen_unexported" | grep -c -x KIRO_API_KEY)" "0" "未导出的同名 shell 变量不透传"
# 真跑一次 env -i：子进程只看得到清单里的变量
seen=$(env -i PATH="$PATH" HOME="$tmp/h" KIRO_API_KEY=k YUNXIAO_TOKEN=t KIRO_FOO=1 \
  bash -c 'set -euo pipefail; source "$1"; kiro_env_allowlist; env -i "${KIRO_ENV_ALLOW[@]}" bash -c "compgen -e" | sort' _ "$LIB")
assert_eq "$(printf '%s\n' "$seen" | grep -c -x -- "KIRO_API_KEY")" "1" "env -i 后子进程看得到 KIRO_API_KEY"
assert_eq "$(printf '%s\n' "$seen" | grep -c -x -- "YUNXIAO_TOKEN")" "0" "env -i 后子进程看不到 YUNXIAO_TOKEN"
assert_eq "$(printf '%s\n' "$seen" | grep -c -x -- "KIRO_FOO")" "0" "env -i 后子进程看不到 KIRO_FOO（不在固定名单）"

# --- KIRO_ENV_PASSTHROUGH：逗号分隔的变量名，只放名字不放值 ---
pt_names=$(names_under HOME="$tmp/h" KIRO_FOO=1 LD_LIBRARY_PATH=/opt/lib AWS_PROFILE=dev YUNXIAO_TOKEN=t \
  KIRO_ENV_PASSTHROUGH=' KIRO_FOO, LD_LIBRARY_PATH ,,AWS_PROFILE,NOT_SET_ANYWHERE,')
for v in KIRO_FOO LD_LIBRARY_PATH AWS_PROFILE; do
  assert_eq "$(printf '%s\n' "$pt_names" | grep -c -x -- "$v")" "1" "KIRO_ENV_PASSTHROUGH 透传 ${v}（空白与空项被忽略）"
done
assert_eq "$(printf '%s\n' "$pt_names" | grep -c -x -- "NOT_SET_ANYWHERE")" "0" "KIRO_ENV_PASSTHROUGH 里未设置的名字：跳过、不报错"
assert_eq "$(printf '%s\n' "$pt_names" | grep -c -x -- "YUNXIAO_TOKEN")" "0" "KIRO_ENV_PASSTHROUGH 不影响名单外的其它变量"
assert_eq "$(printf '%s\n' "$pt_names" | grep -c -x -- "KIRO_ENV_PASSTHROUGH")" "0" "KIRO_ENV_PASSTHROUGH 自己不透传"
# 名字重复（固定名单里已有 / 列了两次）→ 只透传一次
dup_names=$(names_under HOME="$tmp/h" KIRO_API_KEY=k KIRO_FOO=1 KIRO_ENV_PASSTHROUGH='KIRO_API_KEY,KIRO_FOO,KIRO_FOO')
assert_eq "$(printf '%s\n' "$dup_names" | grep -c -x -- "KIRO_API_KEY")" "1" "与固定名单重复的名字只透传一次"
assert_eq "$(printf '%s\n' "$dup_names" | grep -c -x -- "KIRO_FOO")" "1" "列两次的名字只透传一次"
# 非法名字 → 返回非零并点名（取值部分打码：写成 NAME=value 的人多半把密钥放进去了，不能原样进日志）
for bad in 'KIRO_FOO=1' 'bad-name' '1ABC' 'A B' 'KIRO_FOO,$HOME'; do
  rc=0; err=$(env -i PATH="$PATH" HOME="$tmp/h" KIRO_FOO=1 KIRO_ENV_PASSTHROUGH="KIRO_MOCK_DIR,${bad}" \
    bash -c 'set -uo pipefail; source "$1"; kiro_env_allowlist' _ "$LIB" 2>&1 >/dev/null) || rc=$?
  assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "KIRO_ENV_PASSTHROUGH 含非法名字 [${bad}]：返回非零"
  assert_contains "$err" "非法变量名" "KIRO_ENV_PASSTHROUGH 含非法名字 [${bad}]：报错说明"
done
rc=0; err=$(env -i PATH="$PATH" HOME="$tmp/h" KIRO_ENV_PASSTHROUGH='KIRO_FOO=s3cr3t' \
  bash -c 'set -uo pipefail; source "$1"; kiro_env_allowlist' _ "$LIB" 2>&1 >/dev/null) || rc=$?
assert_contains "$err" "KIRO_FOO=" "非法名字 NAME=value：报错点名到名字"
assert_not_contains "$err" "s3cr3t" "非法名字 NAME=value：取值不进报错"
# 空值 / 只有空白 → 等于没配
empty_names=$(names_under HOME="$tmp/h" KIRO_FOO=1 KIRO_ENV_PASSTHROUGH='  ')
assert_eq "$(printf '%s\n' "$empty_names" | grep -c -x -- "KIRO_FOO")" "0" "KIRO_ENV_PASSTHROUGH 只有空白：等于没配"

# --- 日志用的变量名列表：按数组元素取 %%=*，不按行切（15-fix #7：取值含换行时半个取值会进日志）---
nl_names=$(env -i PATH="$PATH" HOME="$tmp/h" KIRO_API_KEY="$(printf 'k\nSECRETFRAG=leaked')" \
  bash -c 'set -euo pipefail; source "$1"; kiro_env_allowlist; kiro_env_allowlist_names' _ "$LIB")
assert_eq "$(printf '%s\n' "$nl_names" | grep -c -x -- "KIRO_API_KEY")" "1" "取值含换行：名字列表里有 KIRO_API_KEY"
assert_not_contains "$nl_names" "SECRETFRAG" "取值含换行：换行后的半个取值不进名字列表"
# 正控：旧写法（按行 cut）确实会把半个取值当成名字放出来——证明上面这条断言测得到东西
nl_old=$(env -i PATH="$PATH" HOME="$tmp/h" KIRO_API_KEY="$(printf 'k\nSECRETFRAG=leaked')" \
  bash -c 'set -euo pipefail; source "$1"; kiro_env_allowlist; printf "%s\n" "${KIRO_ENV_ALLOW[@]}" | cut -d= -f1' _ "$LIB")
assert_contains "$nl_old" "SECRETFRAG" "正控：按行 cut 的旧写法会泄出换行后的半个取值"

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
