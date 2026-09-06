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
# 读取边界（票 15 / 15-fix #3）：read/grep/glob 的 toolsSettings.allowedPaths 是**许可清单**，两条运行时路径
# （业务库 checkout、diff chunk 目录）由 --workspace / --chunks **必填**传入，安装时用 jq **结构化**写入
#   .toolsSettings.read.allowedPaths = .toolsSettings.grep.allowedPaths = .toolsSettings.glob.allowedPaths = [<ws>, <chunks>]
# 三处一律覆盖，与定义文件里写了什么无关（toolsSettings 或某个工具的对象不存在就建出来）。定义文件里的
# allowedPaths 只是文档：保留占位符字面量 {{REVIEW_WORKSPACE}} / {{REVIEW_CHUNKS}}，说明这两个位置由安装时注入。
# 不做模板替换：靠「占位符字符串还在不在」判断，会把「grep 那一处根本没写 allowedPaths」的定义照样装成功——
# grep 就没有边界；结构化写入不依赖定义文件的形态。
# 注入的是**物理路径**（cd && pwd -P）：kiro-cli 按解析后的路径与 allowedPaths 比对，macOS 的 /var/folders →
# /private/var/folders、/tmp → /private/tmp 这类符号链接写逻辑路径会让全部读取落在 allow 之外（探测 P1-15）。
# 经 jq 转义，路径含空格、引号、反斜杠、非 ASCII 时 JSON 仍合法。
# 硬规则：--workspace 与 --chunks 缺任一 → 拒绝安装、不落盘。allow 为空在 headless 下等于每次读取都被拒，
# 评审会在读第一个文件时失败并烧掉额度——宁可不跑。
# 落盘文件名取定义中的 name（kiro 按 name 字段发现 agent；文件名与 name 一致最不易混淆）。
#
# 用法：kiro_install_agent <agent.json> <目标目录> --workspace <业务库目录> --chunks <chunk 目录>
#   成功：stdout 打印安装后的文件路径，返回 0
#   失败（定义不可读/非法 JSON/缺 name/缺 prompt/file:// 指向不存在的文件/缺 --workspace 或 --chunks/
#        路径参数不是已存在的目录/未知参数）：stderr 说明原因，返回非零，且不落盘半成品——目标目录也不会被创建。
#   安装后会清掉目标目录里其它声明同一 name 的文件。

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
  local src_dir name prompt dest rel abs prompt_new rendered stale stale_name
  [[ -r "$src" ]] || { echo "kiro_install_agent: agent 定义不可读：${src}" >&2; return 1; }
  # 两条运行时路径必填（写成一行：变异测试删掉这一行即模拟「忘了校验」）
  if [[ "$ws_set" != "1" || "$ch_set" != "1" ]]; then echo "kiro_install_agent: 缺少必填参数——必须同时给出 --workspace <业务库目录> 与 --chunks <chunk 目录>（allowedPaths 由此注入；缺了等于 allow 为空，headless 下每次读取都被拒）：${src}" >&2; return 1; fi
  if [[ "$ws_set" == "1" ]]; then ws=$(_kiro_agent_physical_dir "$ws" "--workspace") || return 1; fi
  if [[ "$ch_set" == "1" ]]; then ch=$(_kiro_agent_physical_dir "$ch" "--chunks") || return 1; fi
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
  # 一次 jq 渲染：改写 prompt（如需）+ 三处 allowedPaths 结构化覆盖（对象不存在时 jq 会建出来）
  rendered=$(jq --arg p "$prompt_new" --arg ws "$ws" --arg ch "$ch" '
      (if $p != "" then .prompt = $p else . end)
      | .toolsSettings.read.allowedPaths = [$ws, $ch]
      | .toolsSettings.grep.allowedPaths = [$ws, $ch]
      | .toolsSettings.glob.allowedPaths = [$ws, $ch]
    ' "$src") || { echo "kiro_install_agent: 渲染 agent 定义失败：${src}" >&2; return 1; }
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
# Kiro 子进程环境的许可清单（票 15，spec §4.2 修订；15-fix #11/#12）：填充数组 KIRO_ENV_ALLOW，每个元素是
# `VAR=value`，供 `env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli …` 使用（用数组而不是按行输出：取值里若有换行，
# 按行读回去会把半个取值当成 env 的命令名）。
# **固定名单**（不做形状匹配：KIRO_* / *_PROXY / XDG_* 这类模式会放行 CORP_SECRET_PROXY、客户自定义的 KIRO_…）：
#   PATH、HOME（登录态与 ~/.kiro/agents 都靠它）、USER、TERM、TMPDIR、LANG、LC_ALL、LC_CTYPE、
#   KIRO_API_KEY、KIRO_LOG_NO_COLOR、HTTP_PROXY/HTTPS_PROXY/NO_PROXY 与小写三个、
#   SSL_CERT_FILE、SSL_CERT_DIR、CURL_CA_BUNDLE、XDG_CONFIG_HOME、XDG_DATA_HOME、XDG_CACHE_HOME、XDG_STATE_HOME。
# **逃生口** KIRO_ENV_PASSTHROUGH：逗号分隔的变量**名**（自建执行机可能需要 LD_LIBRARY_PATH / AWS_PROFILE 这类），
#   只放名字不放值；任一名字不合法（不是 [A-Za-z_][A-Za-z0-9_]*，例如写成 NAME=value）→ 返回非零，调用方必须
#   拒绝运行而不是静默忽略。名字对应的变量未设置 → 跳过。KIRO_ENV_PASSTHROUGH 自己不透传。
# YUNXIAO_* / CODEUP_* 以及 Flow 注入的一切都不进 Kiro 进程（/proc 已在拒绝清单里，这是零成本的第二道）。
# KIRO_LOG_NO_COLOR=1 固定追加（用户设成别的值也被覆盖）。只透传**已导出**的变量：未导出的本来也到不了子进程。
# 三处 kiro-cli 调用（chat --help / settings / chat）都用同一份清单；探测脚本 probe-kiro-allowlist.sh 也复用——规则只有一份。
KIRO_ENV_FIXED_NAMES=(PATH HOME USER TERM TMPDIR LANG LC_ALL LC_CTYPE KIRO_API_KEY KIRO_LOG_NO_COLOR HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME)
KIRO_ENV_ALLOW=()
kiro_env_allowlist() {
  KIRO_ENV_ALLOW=()
  local n tok rest seen=" "
  local -a names=("${KIRO_ENV_FIXED_NAMES[@]}") bad=()
  if [[ -n "${KIRO_ENV_PASSTHROUGH:-}" ]]; then
    rest="${KIRO_ENV_PASSTHROUGH},"
    while [[ -n "$rest" ]]; do
      tok="${rest%%,*}"; rest="${rest#*,}"
      tok="${tok#"${tok%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"   # 去首尾空白
      [[ -z "$tok" ]] && continue
      if [[ "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then names+=("$tok"); else bad+=("${tok%%=*}${tok/#"${tok%%=*}"/}"); fi
    done
    # 非法名字点名时把 = 之后的部分打码：写成 NAME=value 的人多半把密钥放进去了，不能原样进日志
    if [[ ${#bad[@]} -gt 0 ]]; then local shown=(); for tok in "${bad[@]}"; do if [[ "$tok" == *=* ]]; then shown+=("${tok%%=*}=…"); else shown+=("$tok"); fi; done; echo "kiro_env_allowlist: KIRO_ENV_PASSTHROUGH 含非法变量名：${shown[*]}（只接受逗号分隔的变量名，例如 AWS_PROFILE,LD_LIBRARY_PATH；不能带 = 或取值）" >&2; return 1; fi
  fi
  for n in "${names[@]}"; do
    [[ "$seen" == *" $n "* ]] && continue
    seen+="$n "
    [[ "$n" == KIRO_LOG_NO_COLOR ]] && continue          # 下面固定追加 =1
    [[ -n "${!n+x}" ]] || continue                       # 未设置（含 `export FOO` 未赋值）：没东西可透传
    [[ "$(declare -p "$n" 2>/dev/null)" == "declare -x"* ]] || continue   # 未导出的 shell 变量不算环境
    KIRO_ENV_ALLOW+=("${n}=${!n}")
  done
  KIRO_ENV_ALLOW+=("KIRO_LOG_NO_COLOR=1")
}
# 日志用：只打变量名、不打取值。按数组元素取 `%%=*`，绝不按行切——取值含换行时按行 cut 会把半个取值当成名字放出来（15-fix #7）。
kiro_env_allowlist_names() { printf '%s\n' "${KIRO_ENV_ALLOW[@]%%=*}"; }
