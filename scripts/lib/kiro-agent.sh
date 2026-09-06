#!/usr/bin/env bash
# 受信 agent 安装 + Kiro 子进程环境许可清单。
#
# ── kiro_install_agent ──────────────────────────────────────────────────────────────────────────
# 把集成包内的 agent 定义写入 kiro-cli 的 agent 目录（通常 ~/.kiro/agents/）。
#
# agent 定义里的 prompt 用相对 file:// 引用集成包内的提示词文件。kiro 按「相对 agent 文件所在目录」
# 解析相对 file://（官方文档「File URI path resolution」，kiro-cli 2.21.0 实测一致），所以定义放在
# kiro/ 下时 file://../prompts/x.md 能解析；但直接复制到 ~/.kiro/agents/ 后就会指向不存在的文件。
# 因此安装时把相对 file:// 改写为集成包内的绝对路径；绝对路径原样保留。
#
# 读取边界（票 15）：定义里 read/grep/glob 的 toolsSettings.allowedPaths 是**许可清单**，两条运行时路径
# （业务库 checkout、diff chunk 目录）在定义文件里只能是占位符 {{REVIEW_WORKSPACE}} / {{REVIEW_CHUNKS}}，
# 安装时由 --workspace / --chunks 注入。注入的是 **物理路径**（cd && pwd -P）：kiro-cli 按解析后的路径与
# allowedPaths 比对，macOS 的 /var/folders → /private/var/folders、/tmp → /private/tmp 这类符号链接写逻辑路径
# 会让全部读取落在 allow 之外（探测 P1-15）。替换按子串进行（`{{REVIEW_WORKSPACE}}/**` 这种写法同样能注入），
# 经 jq 转义，路径含空格、引号、反斜杠、非 ASCII 时 JSON 仍合法。
# 两条硬规则（宁可不跑评审，也不能带一份错误的定义跑）：
#   ① 替换后定义里任何字符串值仍含 `{{` → 拒绝安装、不落盘。allow 里留着一个字面量占位符等于 allow 为空：
#      headless 下每次读取都被拒，评审会在读第一个文件时失败并烧掉额度。
#   ② 给了 --workspace / --chunks 但定义里没有对应占位符 → 同样拒绝：说明定义被改坏成「没有 allow」。
#   不含占位符的定义、也不传路径参数 → 按原样安装（探测脚本的正控 agent 就是这种形态）。
# 落盘文件名取定义中的 name（kiro 按 name 字段发现 agent；文件名与 name 一致最不易混淆）。
#
# 用法：kiro_install_agent <agent.json> <目标目录> [--workspace <业务库目录>] [--chunks <chunk 目录>]
#   成功：stdout 打印安装后的文件路径，返回 0
#   失败（定义不可读/非法 JSON/缺 name/缺 prompt/file:// 指向不存在的文件/路径参数不是已存在的目录/
#        占位符未替换/未知参数）：stderr 说明原因，返回非零，且不落盘半成品——目标目录也不会被创建。
#   安装后会清掉目标目录里其它声明同一 name 的文件。
KIRO_AGENT_PH_WORKSPACE='{{REVIEW_WORKSPACE}}'
KIRO_AGENT_PH_CHUNKS='{{REVIEW_CHUNKS}}'

# 取目录的物理绝对路径。$1=路径 $2=参数名（报错用）
_kiro_agent_physical_dir() {
  local p
  [[ -n "$1" ]] || { echo "kiro_install_agent: $2 取值为空" >&2; return 1; }
  [[ -d "$1" ]] || { echo "kiro_install_agent: $2 不是已存在的目录：$1" >&2; return 1; }
  p=$(cd "$1" && pwd -P) || { echo "kiro_install_agent: 无法进入 $2 目录：$1" >&2; return 1; }
  printf '%s\n' "$p"
}

kiro_install_agent() {
  local src="$1" dest_dir="$2"; shift 2
  local ws="" ch="" ws_set=0 ch_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace) [[ $# -ge 2 ]] || { echo "kiro_install_agent: --workspace 缺少取值" >&2; return 1; }; ws="$2"; ws_set=1; shift 2 ;;
      --chunks)    [[ $# -ge 2 ]] || { echo "kiro_install_agent: --chunks 缺少取值" >&2; return 1; };    ch="$2"; ch_set=1; shift 2 ;;
      *) echo "kiro_install_agent: 未知参数：$1（只接受 --workspace <目录> / --chunks <目录>）" >&2; return 1 ;;
    esac
  done
  local src_dir name prompt dest rel abs prompt_new rendered left stale stale_name
  [[ -r "$src" ]] || { echo "kiro_install_agent: agent 定义不可读：${src}" >&2; return 1; }
  src_dir=$(cd "$(dirname "$src")" && pwd) || return 1
  name=$(jq -r '.name // empty' "$src" 2>/dev/null) \
    || { echo "kiro_install_agent: agent 定义不是合法 JSON：${src}" >&2; return 1; }
  [[ -n "$name" ]] || { echo "kiro_install_agent: agent 定义缺少 name：${src}" >&2; return 1; }
  prompt=$(jq -r '.prompt // empty' "$src")
  # prompt 是只读角色约束所在，缺失就等于让默认系统提示词跑评审——拒绝安装
  [[ -n "$prompt" ]] || { echo "kiro_install_agent: agent 定义缺少 prompt：${src}" >&2; return 1; }
  dest="${dest_dir}/${name}.json"
  # prompt：相对 file:// 改写为绝对；绝对 file:// 与内联文本原样保留（prompt_new 为空 = 不改写）
  prompt_new=""
  if [[ "$prompt" == file:///* ]]; then
    abs="${prompt#file://}"
    [[ -r "$abs" ]] || { echo "kiro_install_agent: prompt 引用的文件不可读：${abs}（来自 ${prompt}）" >&2; return 1; }
  elif [[ "$prompt" == file://* ]]; then
    rel="${prompt#file://}"
    abs="${src_dir}/${rel}"
    [[ -r "$abs" ]] || { echo "kiro_install_agent: prompt 引用的文件不可读：${abs}（来自 ${prompt}）" >&2; return 1; }
    abs="$(cd "$(dirname "$abs")" && pwd)/$(basename "$abs")"
    prompt_new="file://${abs}"
  fi
  # 占位符：路径参数先落成物理路径；给了参数但定义里没有对应占位符 → 拒绝（规则 ②）
  if [[ "$ws_set" == "1" ]]; then
    ws=$(_kiro_agent_physical_dir "$ws" "--workspace") || return 1
    [[ "$(jq --arg ph "$KIRO_AGENT_PH_WORKSPACE" '[.. | strings | select(contains($ph))] | length' "$src")" != "0" ]] \
      || { echo "kiro_install_agent: 定义里没有 ${KIRO_AGENT_PH_WORKSPACE} 占位符，--workspace 无处注入（allowedPaths 被改掉了？）：${src}" >&2; return 1; }
  fi
  if [[ "$ch_set" == "1" ]]; then
    ch=$(_kiro_agent_physical_dir "$ch" "--chunks") || return 1
    [[ "$(jq --arg ph "$KIRO_AGENT_PH_CHUNKS" '[.. | strings | select(contains($ph))] | length' "$src")" != "0" ]] \
      || { echo "kiro_install_agent: 定义里没有 ${KIRO_AGENT_PH_CHUNKS} 占位符，--chunks 无处注入（allowedPaths 被改掉了？）：${src}" >&2; return 1; }
  fi
  # 一次 jq 渲染：改写 prompt（如需）+ 对所有字符串值做占位符子串替换（split/join 是字面量匹配，不是正则）
  rendered=$(jq --arg p "$prompt_new" \
                --arg ph_ws "$KIRO_AGENT_PH_WORKSPACE" --arg ws "$ws" --argjson ws_set "$ws_set" \
                --arg ph_ch "$KIRO_AGENT_PH_CHUNKS" --arg ch "$ch" --argjson ch_set "$ch_set" '
      (if $p != "" then .prompt = $p else . end)
      | (.. | strings) |= ( (if $ws_set == 1 then (split($ph_ws) | join($ws)) else . end)
                          | (if $ch_set == 1 then (split($ph_ch) | join($ch)) else . end) )
    ' "$src") || { echo "kiro_install_agent: 渲染 agent 定义失败：${src}" >&2; return 1; }
  # 规则 ①：残留占位符 → 拒绝安装、不落盘
  left=$(printf '%s\n' "$rendered" | jq -r '[.. | strings | select(contains("{{"))] | unique | join(" | ")')
  if [[ -n "$left" ]]; then echo "kiro_install_agent: 占位符未替换（请传 --workspace/--chunks）：${left}" >&2; return 1; fi
  mkdir -p "$dest_dir" || return 1
  printf '%s\n' "$rendered" > "$dest" || { rm -f "$dest"; return 1; }
  # 常驻执行器的 agent 目录里可能留着旧版本集成包按别的文件名装的同名 agent（如 agent-codeup-reviewer.json）；
  # kiro 按 name 发现 agent，同名两份会二选一或报错，因此把其它声明同一 name 的文件清掉。
  for stale in "$dest_dir"/*.json; do
    [[ -f "$stale" && "$stale" != "$dest" ]] || continue
    stale_name=$(jq -r '.name // empty' "$stale" 2>/dev/null || true)
    if [[ "$stale_name" == "$name" ]]; then
      rm -f "$stale" || return 1
      echo "kiro_install_agent: 已移除同名旧 agent 文件：${stale}" >&2
    fi
  done
  printf '%s\n' "$dest"
}

# ── kiro_env_allowlist ──────────────────────────────────────────────────────────────────────────
# Kiro 子进程环境的许可清单（票 15，spec §4.2 修订）：填充数组 KIRO_ENV_ALLOW，每个元素是 `VAR=value`，
# 供 `env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli …` 使用（用数组而不是按行输出：取值里若有换行，按行读回去会把
# 半个取值当成 env 的命令名）。只透传 kiro-cli 启动与联网所需的变量：
#   PATH、HOME（登录态与 ~/.kiro/agents 都靠它）、USER、LANG、LC_*、TERM、TMPDIR、
#   KIRO_*（含 KIRO_API_KEY）、*_PROXY / *_proxy、SSL_CERT_FILE、SSL_CERT_DIR、CURL_CA_BUNDLE、XDG_*。
# YUNXIAO_* / CODEUP_* 以及 Flow 注入的一切都不进 Kiro 进程（/proc 已在拒绝清单里，这是零成本的第二道）。
# KIRO_LOG_NO_COLOR=1 固定追加（原来是调用行的行内前缀；重复时 env 取后者，语义不变）。
# 只看**已导出**的变量（compgen -e）：未导出的本来也到不了子进程。
# 探测脚本 scripts/probe/probe-kiro-allowlist.sh 复用同一份函数——规则只在这里有一份。
KIRO_ENV_ALLOW=()
kiro_env_allowlist() {
  KIRO_ENV_ALLOW=()
  local n
  while IFS= read -r n; do
    [[ -n "${!n+x}" ]] || continue   # `export FOO` 而未赋值的名字：compgen 列得出来，取值不存在，跳过
    case "$n" in
      PATH|HOME|USER|LANG|TERM|TMPDIR|SSL_CERT_FILE|SSL_CERT_DIR|CURL_CA_BUNDLE) ;;
      LC_*|KIRO_*|XDG_*|*_PROXY|*_proxy) ;;
      *) continue ;;
    esac
    KIRO_ENV_ALLOW+=("${n}=${!n}")
  done < <(compgen -e)
  KIRO_ENV_ALLOW+=("KIRO_LOG_NO_COLOR=1")
}
