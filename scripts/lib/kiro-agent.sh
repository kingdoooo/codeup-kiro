#!/usr/bin/env bash
# 受信 agent 安装 / 安装结果自检 + Kiro 子进程环境许可清单。
#
# ── kiro_install_agent ──────────────────────────────────────────────────────────────────────────
# 把集成包内的 agent 定义写入 kiro-cli 的 agent 目录（通常 ~/.kiro/agents/）。
#
# agent 定义里的 prompt 用相对 file:// 引用集成包内的提示词文件。kiro 按「相对 agent 文件所在目录」
# 解析相对 file://（官方文档「File URI path resolution」，kiro-cli 2.21.0 实测一致），所以定义放在
# kiro/ 下时 file://../prompts/x.md 能解析；但直接复制到 ~/.kiro/agents/ 后就会指向不存在的文件。
# 因此安装时把相对 file:// 改写为集成包内的绝对路径；绝对路径原样保留。
#
# 读取边界（票 15 / 15-fix #3 / 15-fix2 #11 #16 #20）：
#   · read/grep/glob 的 toolsSettings.allowedPaths 是**许可清单**，两条运行时路径（业务库 checkout、diff chunk 目录）
#     由 --workspace / --chunks **必填**传入，安装时用 jq **结构化**写入三处（与定义文件里写了什么无关；定义文件里的
#     占位符 {{REVIEW_WORKSPACE}} / {{REVIEW_CHUNKS}} 只是文档）。不做模板替换：靠「占位符还在不在」判断会把
#     「grep 那一处根本没写 allowedPaths」的定义照样装成功。注入的是**物理路径**（cd && pwd -P）：kiro-cli 按解析后的
#     路径比对，macOS 的 /var/folders → /private/var/folders 这类符号链接写逻辑路径会让全部读取落在 allow 之外。
#   · 三个工具的 toolsSettings.<tool>.deniedPaths 必须**存在、非空且含 `**/.git/**`**，缺一拒装（15-fix2 #11）：
#     结构化写 allowedPaths 会把不存在的 toolsSettings.<tool> 对象凭空建出来——那一处就只有 allow 没有 deny，
#     glob 能枚举 <业务库>/.git/**。
#   · --allow-none（15-fix2 #20）：探测脚本的**正控** agent 要的是「没有 allowedPaths」的旧形态。这是唯一合法的第二调用方，
#     走安装器而不是裸 cp：file:// 改写与同名旧文件清理照做，deny 检查照做；与 --workspace/--chunks 互斥。
#   · 安装结果的核对不在这里做：调用方用 kiro_agent_selfcheck 读安装文件按值比对（15-fix3 #12 删掉了与之冗余的「安装器打回路径」stdout 协议）。
# 硬规则：宁可不跑评审，也不能带一份错误的定义跑（allow 为空在 headless 下等于每次读取都被拒、烧掉额度；deny 缺失等于该工具没有边界）。
# 落盘文件名取定义中的 name（kiro 按 name 字段发现 agent；文件名与 name 一致最不易混淆）。
#
# 用法：kiro_install_agent <agent.json> <目标目录> ( --workspace <业务库目录> --chunks <chunk 目录> | --allow-none )
#   成功：stdout 打印安装后的文件路径，返回 0
#   失败（定义不可读/非法 JSON/缺 name/缺 prompt/file:// 指向不存在的文件/缺 --workspace 或 --chunks/路径参数不是已存在的目录/
#        某工具 deniedPaths 缺失、为空或不含 **/.git/**/参数互斥/未知参数）：stderr 说明原因，返回非零，且不落盘半成品。
#   安装后会清掉目标目录里其它声明同一 name 的文件。

# 取目录的物理绝对路径。$1=路径 $2=参数名（报错用）
_kiro_agent_physical_dir() {
  local p
  [[ -n "$1" ]] || { echo "kiro_install_agent: $2 取值为空" >&2; return 1; }
  [[ -d "$1" ]] || { echo "kiro_install_agent: $2 不是已存在的目录：$1" >&2; return 1; }
  p=$(cd "$1" && pwd -P) || { echo "kiro_install_agent: 无法进入 $2 目录：$1" >&2; return 1; }
  printf '%s\n' "$p"
}
# 三个工具的 deniedPaths 是否都合格（存在、非空、含 **/.git/**）——一次 jq 查完三处（15-fix3 #13）。
# $1=定义文件；stdout 打出第一个不合格的工具名（都合格则为空）；文件不是合法 JSON 时返回非零
_kiro_agent_deny_missing() {
  jq -r '[("read","grep","glob") as $t | select((.toolsSettings[$t].deniedPaths | type == "array" and length > 0 and index("**/.git/**") != null) | not) | $t] | first // ""' "$1" 2>/dev/null
}

kiro_install_agent() {
  local src="$1" dest_dir="$2"; shift 2
  local ws="" ch="" ws_set=0 ch_set=0 allow_none=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace) [[ $# -ge 2 ]] || { echo "kiro_install_agent: --workspace 缺少取值" >&2; return 1; }; ws="$2"; ws_set=1; shift 2 ;;
      --chunks)    [[ $# -ge 2 ]] || { echo "kiro_install_agent: --chunks 缺少取值" >&2; return 1; };    ch="$2"; ch_set=1; shift 2 ;;
      --allow-none)  allow_none=1; shift ;;
      *) echo "kiro_install_agent: 未知参数：$1（只接受 --workspace <目录> / --chunks <目录> / --allow-none）" >&2; return 1 ;;
    esac
  done
  local src_dir name prompt dest rel abs prompt_new rendered stale stale_name deny_missing
  [[ -r "$src" ]] || { echo "kiro_install_agent: agent 定义不可读：${src}" >&2; return 1; }
  if [[ "$allow_none" == "1" ]]; then
    [[ "$ws_set" == "0" && "$ch_set" == "0" ]] || { echo "kiro_install_agent: --allow-none 与 --workspace/--chunks 互斥（正控 agent 不能同时有 allowedPaths）：${src}" >&2; return 1; }
  else
    # 两条运行时路径必填（写成一行：变异测试删掉这一行即模拟「忘了校验」）
    if [[ "$ws_set" != "1" || "$ch_set" != "1" ]]; then echo "kiro_install_agent: 缺少必填参数——必须同时给出 --workspace <业务库目录> 与 --chunks <chunk 目录>（allowedPaths 由此注入；缺了等于 allow 为空，headless 下每次读取都被拒），或显式 --allow-none（仅探测正控）：${src}" >&2; return 1; fi
    ws=$(_kiro_agent_physical_dir "$ws" "--workspace") || return 1
    ch=$(_kiro_agent_physical_dir "$ch" "--chunks") || return 1
  fi
  src_dir=$(cd "$(dirname "$src")" && pwd) || return 1
  name=$(jq -r '.name // empty' "$src" 2>/dev/null) \
    || { echo "kiro_install_agent: agent 定义不是合法 JSON：${src}" >&2; return 1; }
  [[ -n "$name" ]] || { echo "kiro_install_agent: agent 定义缺少 name：${src}" >&2; return 1; }
  prompt=$(jq -r '.prompt // empty' "$src")
  # prompt 是只读角色约束所在，缺失就等于让默认系统提示词跑评审——拒绝安装
  [[ -n "$prompt" ]] || { echo "kiro_install_agent: agent 定义缺少 prompt：${src}" >&2; return 1; }
  # deniedPaths 三处都必须合格（15-fix2 #11）：写成一行，变异测试删掉即模拟「忘了检查」
  deny_missing=$(_kiro_agent_deny_missing "$src") || { echo "kiro_install_agent: 读取定义失败：${src}" >&2; return 1; }; [[ -z "$deny_missing" ]] || { echo "kiro_install_agent: 定义里 toolsSettings.${deny_missing}.deniedPaths 缺失、为空或不含 **/.git/**——该工具没有拒绝清单，拒绝安装：${src}" >&2; return 1; }
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
  # 一次 jq 渲染：改写 prompt（如需）+ 三处 allowedPaths 结构化覆盖（--allow-none 则三处删除）
  rendered=$(jq --arg p "$prompt_new" --arg ws "$ws" --arg ch "$ch" --argjson none "$allow_none" '
      (if $p != "" then .prompt = $p else . end)
      | if $none == 1 then del(.toolsSettings[].allowedPaths)
        else .toolsSettings.read.allowedPaths = [$ws, $ch]
           | .toolsSettings.grep.allowedPaths = [$ws, $ch]
           | .toolsSettings.glob.allowedPaths = [$ws, $ch]
        end
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

# ── kiro_agent_selfcheck ────────────────────────────────────────────────────────────────────────
# 安装结果的**值比对 + 安全字段**（15-fix2 #16）：$1=安装后的定义文件 $2=业务库物理路径 $3=chunks 物理路径。
#   · read/grep/glob 三处 allowedPaths 逐字等于 [$2, $3]（顺序、物理形态都算）
#   · 三处 deniedPaths 存在、非空、含 **/.git/**
#   · allowedTools == []（免确认只来自 allowedPaths）、includeMcpJson == false、includePowers == false
# 失败返回 1，原因放进 KIRO_AGENT_SELFCHECK_ERROR。执行器第 3 步用它把「日志声称的事实」变成断言；单测直接对篡改过的定义调用。
# 全部检查在**一次** jq 里完成（15-fix3 #13），输出第一条不符的原因（都符合则为空）。
KIRO_AGENT_SELFCHECK_ERROR=""
kiro_agent_selfcheck() {
  local f="$1" ws="$2" ch="$3" reason
  KIRO_AGENT_SELFCHECK_ERROR=""
  [[ -r "$f" ]] || { KIRO_AGENT_SELFCHECK_ERROR="安装后的定义文件不可读：${f}"; return 1; }
  reason=$(jq -r --arg ws "$ws" --arg ch "$ch" '
      def want: [$ws, $ch];
      def deny_ok($t): (.toolsSettings[$t].deniedPaths | type == "array" and length > 0 and index("**/.git/**") != null);
      [ ("read","grep","glob") as $t
        | ( if .toolsSettings[$t].allowedPaths != want
            then "\($t).allowedPaths 写入的是 \(.toolsSettings[$t].allowedPaths | tojson)，预期 \(want | tojson)（业务库 checkout 物理路径 + chunks 物理路径，顺序固定）"
            elif (deny_ok($t) | not) then "\($t).deniedPaths 缺失、为空或不含 **/.git/**"
            else null end ),
        (if .allowedTools != [] then "allowedTools 不为空（\(.allowedTools | tojson)）——免确认只能来自 allowedPaths" else null end),
        (if .includeMcpJson != false then "includeMcpJson 不是 false" else null end),
        (if .includePowers != false then "includePowers 不是 false" else null end)
      ] | map(select(. != null)) | first // ""' "$f" 2>/dev/null) || { KIRO_AGENT_SELFCHECK_ERROR="定义不是合法 JSON：${f}"; return 1; }
  [[ -z "$reason" ]] || { KIRO_AGENT_SELFCHECK_ERROR="$reason"; return 1; }
  return 0
}

# ── kiro_env_allowlist ──────────────────────────────────────────────────────────────────────────
# Kiro 子进程环境的许可清单（票 15，spec §4.2 修订；15-fix #11/#12；15-fix2 #12 #13 #14 #17）：填充数组 KIRO_ENV_ALLOW，
# 每个元素是 `VAR=value`，供 `env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli …` 使用（用数组而不是按行输出：取值里若有换行，
# 按行读回去会把半个取值当成 env 的命令名）。
# **固定名单**（不做形状匹配：KIRO_* / *_PROXY / XDG_* 这类模式会放行 CORP_SECRET_PROXY、客户自定义的 KIRO_…）：
#   PATH、HOME（登录态与 ~/.kiro/agents 都靠它）、USER、TERM、TMPDIR、LANG、LANGUAGE、LC_ALL、LC_CTYPE、LC_MESSAGES、
#   KIRO_API_KEY、KIRO_LOG_NO_COLOR、HTTP_PROXY/HTTPS_PROXY/FTP_PROXY/ALL_PROXY/NO_PROXY 与小写五个、
#   SSL_CERT_FILE、SSL_CERT_DIR、CURL_CA_BUNDLE、XDG_CONFIG_HOME、XDG_DATA_HOME、XDG_CACHE_HOME、XDG_STATE_HOME、XDG_RUNTIME_DIR。
# **逃生口** KIRO_ENV_PASSTHROUGH：逗号分隔的变量**名**（自建执行机可能需要 LD_LIBRARY_PATH / JAVA_HOME 这类；AWS_* 按凭证形状拒绝），
#   只放名字不放值。两道校验，任一不过 → 返回 1、原因放进 KIRO_ENV_ALLOW_ERROR，调用方必须拒绝运行而不是静默忽略：
#   ① 语法：不是 [A-Za-z_][A-Za-z0-9_]*（例如写成 NAME=value）→ 拒绝。
#   ② 凭证形状的名字 → 拒绝（15-fix2 #13 / 15-fix3 #6）：YUNXIAO_*、CODEUP_*、AWS_*、*TOKEN*、*SECRET*、*PASSWORD*、*CREDENTIAL*、
#      *_KEY，以及常见令牌前缀 GHP_*、GHO_*、GITHUB_PAT_*、AKIA*、XOX*（大小写不敏感；`ghp_<36 位>` 是合法标识符，没有这几条会被静默接受）。
#      固定名单刚把云效令牌关在门外，运维写一个 YUNXIAO_TOKEN 就又开了——只靠文档一句话拦不住。
#   两条路径的报错都**无条件掩码**（15-fix2 #17 / 15-fix3 #6）：只留首段（第一个 _ 之前；没有 _ 就前 4 个字符）+ ****——
#   `svc_SECRET_9f3ab21c7de4` 这种合法标识符形态的密钥会进 MR 失败评论，不能原样出现；取值从不出现在任何输出里。
#   名字对应的变量未设置 → 跳过。KIRO_ENV_PASSTHROUGH 自己不透传。
# YUNXIAO_* / CODEUP_* 以及 Flow 注入的一切都不进 Kiro 进程（/proc 已在拒绝清单里，这是零成本的第二道）。
# KIRO_LOG_NO_COLOR=1 固定追加（用户设成别的值也被覆盖）。只透传**已导出**的变量：未导出的本来也到不了子进程。
#   导出判定看 `declare -p` 的属性段里有没有 x（`declare -rx` / `-ix` / `-ax` 都算，15-fix2 #12——只认 `declare -x` 前缀会把
#   `declare -rx TMPDIR` 这类丢掉，env -i 起 kiro 时没有 TMPDIR/PATH/HOME）。
# 四处 kiro-cli 调用（chat --help / --version / settings / chat）都用同一份清单；探测脚本 probe-kiro-allowlist.sh 也复用——规则只有一份。
KIRO_ENV_FIXED_NAMES=(PATH HOME USER TERM TMPDIR LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES KIRO_API_KEY KIRO_LOG_NO_COLOR HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy ftp_proxy all_proxy no_proxy SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR)
KIRO_ENV_ALLOW=()
KIRO_ENV_ALLOW_ERROR=""
# 被拒 token / 名字的掩码：先取开头的合法标识符字符段（没有就只有 ****），再只留它的首段——第一个 _ 之前，
# 没有 _ 就前 4 个字符——加 ****。`KIRO_FOO=s3cr3t`→KIRO****，`ghp-liveSecret123`→ghp****，`svc_SECRET_9f3a`→svc****，`1ABC`→****
_kiro_env_mask_token() {
  local id
  if [[ "$1" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then id="${BASH_REMATCH[1]}"; else printf '****'; return 0; fi
  if [[ "$id" == *_* ]]; then printf '%s****' "${id%%_*}"; else printf '%s****' "${id:0:4}"; fi
}
kiro_env_allowlist() {
  KIRO_ENV_ALLOW=(); KIRO_ENV_ALLOW_ERROR=""
  local n tok rest up seen=" "
  local -a names=("${KIRO_ENV_FIXED_NAMES[@]}") bad=() cred=()
  if [[ -n "${KIRO_ENV_PASSTHROUGH:-}" ]]; then
    rest="${KIRO_ENV_PASSTHROUGH},"
    while [[ -n "$rest" ]]; do
      tok="${rest%%,*}"; rest="${rest#*,}"
      tok="${tok#"${tok%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"   # 去首尾空白
      [[ -z "$tok" ]] && continue
      if [[ ! "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then bad+=("$(_kiro_env_mask_token "$tok")"); continue; fi
      up=$(printf '%s' "$tok" | tr '[:lower:]' '[:upper:]')
      case "$up" in
        YUNXIAO_*|CODEUP_*|AWS_*|*TOKEN*|*SECRET*|*PASSWORD*|*CREDENTIAL*|*_KEY|GHP_*|GHO_*|GITHUB_PAT_*|AKIA*|XOX*) cred+=("$(_kiro_env_mask_token "$tok")") ;;
        *) names+=("$tok") ;;
      esac
    done
    if [[ ${#bad[@]} -gt 0 ]]; then KIRO_ENV_ALLOW_ERROR="KIRO_ENV_PASSTHROUGH 含非法变量名：${bad[*]}（只接受逗号分隔的变量名，例如 LD_LIBRARY_PATH,JAVA_HOME；不能带 = 或取值；非法部分已掩码）"; echo "kiro_env_allowlist: ${KIRO_ENV_ALLOW_ERROR}" >&2; return 1; fi
    if [[ ${#cred[@]} -gt 0 ]]; then KIRO_ENV_ALLOW_ERROR="KIRO_ENV_PASSTHROUGH 含凭证形状的变量名，拒绝透传：${cred[*]}（已掩码；YUNXIAO_*、CODEUP_*、AWS_*、*TOKEN*、*SECRET*、*PASSWORD*、*CREDENTIAL*、*_KEY 与 GHP_*/GHO_*/GITHUB_PAT_*/AKIA*/XOX* 前缀一律不放行——这些正是固定名单要关在 Kiro 进程之外的东西）"; echo "kiro_env_allowlist: ${KIRO_ENV_ALLOW_ERROR}" >&2; return 1; fi
  fi
  for n in "${names[@]}"; do
    [[ "$seen" == *" $n "* ]] && continue
    seen+="$n "
    [[ "$n" == KIRO_LOG_NO_COLOR ]] && continue          # 下面固定追加 =1
    [[ -n "${!n+x}" ]] || continue                       # 未设置（含 `export FOO` 未赋值）：没东西可透传
    [[ "$(declare -p "$n" 2>/dev/null)" =~ ^declare\ -[a-zA-Z]*x ]] || continue   # 属性段含 x = 已导出（-x / -rx / -ix / -ax …）
    KIRO_ENV_ALLOW+=("${n}=${!n}")
  done
  KIRO_ENV_ALLOW+=("KIRO_LOG_NO_COLOR=1")
}
# 日志用：只打变量名、不打取值。按数组元素取 `%%=*`，绝不按行切——取值含换行时按行 cut 会把半个取值当成名字放出来（15-fix #7）。
kiro_env_allowlist_names() { printf '%s\n' "${KIRO_ENV_ALLOW[@]%%=*}"; }
