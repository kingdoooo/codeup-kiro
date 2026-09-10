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
#   · **仓库相对拒绝形状按 allow 根注入绝对副本**（15-fix4 #1 补，探测 kiro-probe-P1-15-t15fix4-4b30a00 实测）：kiro-cli 2.21.1 把 `**/…`
#     开头的 deniedPaths 按 **cwd** 解析——kiro-cli 改在空目录 $WORK/cwd 下运行后，`**/.git/**`、`**/.ssh/**` 这些形状只覆盖那个空目录，
#     allow 内的 .git/logs/HEAD、.ssh/config 被 completed 读出（T3 / T9a–T9d FAIL）；加上 `<业务库物理路径>/**/.git/**` 后恢复被拒。
#     所以安装时对定义里每条以 `**/` 开头的 deny 形状，按两条 allow 根各写一份 `<根>/<形状>`（原相对条目保留：cwd 恰好等于某个根时它仍有效），
#     三个工具各自注入；--allow-none 不注入（正控 agent 要的是旧形态）。自检按值核对两组注入条目都在。
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
# deny 谓词、工具三元组与 deny 报错文案**各只有一份**（15-fix4 #5）：安装器的 _kiro_agent_deny_missing 与 kiro_agent_selfcheck 都把
# 这段 jq 前导拼进自己的程序。两份谓词只改一处的两种后果都是静默的——安装器放行而自检拒绝（每次评审都失败），或反过来（自检形同虚设）。
KIRO_AGENT_TOOLS_JQ='("read","grep","glob")'
# 必需的仓库相对拒绝形状（合并后复审第 5 条）：这份清单是 deny 门的定义，不再只查字面 **/.git/**——探测 P1-15 证明每一条都是保护
# checkout 所必需的（.aws/.ssh/id_rsa 等）；少任何一条拒装 / 自检拒绝。与 kiro/agent-codeup-reviewer.json 里的相对条目同源，
# tests/test-agent-config.sh 断言两者一致。
KIRO_AGENT_REQUIRED_DENY_JQ='["**/.git","**/.git/**","**/.git/config","**/.netrc","**/.aws/**","**/.ssh/**","**/id_rsa*","**/id_ed25519*"]'
_KIRO_DENY_OK_JQ='def deny_ok($t): (.toolsSettings[$t].deniedPaths as $d | ($d | type == "array") and ($d | length > 0) and (('"$KIRO_AGENT_REQUIRED_DENY_JQ"' - $d) == []));'
# 按 allow 根注入的绝对拒绝形状（15-fix4 #1 补）：deny_abs($root) = 数组里每条以 **/ 开头的形状前面接上 <根>/；
# deny_abs_missing($t; $ws; $ch) = 安装后该工具的 deniedPaths 里缺的注入条目（空数组 = 齐全）。安装器与自检共用这一份定义。
# 绝对副本覆盖**每一条非绝对路径**的形状（合并后复审第 5 条）：不只 **/ 开头——`.env`、`secrets/**`、`*/.git/**` 在空 cwd 下同样只覆盖 cwd。
# 以 / 开头的绝对路径与 ~/ 开头的家目录形状不需要副本（kiro-cli 自己展开）。
_KIRO_DENY_ABS_JQ='def deny_abs($root): [ .[] | select(type == "string" and (startswith("/") or startswith("~/") | not)) | $root + "/" + . ];
  def deny_abs_missing($t; $ws; $ch): (.toolsSettings[$t].deniedPaths // []) as $d | [ ($d | deny_abs($ws)), ($d | deny_abs($ch)) | .[] | . as $e | select(($d | index($e)) == null) ];'
KIRO_AGENT_DENY_MSG='deniedPaths 缺失、为空或不含全部必需的拒绝形状（**/.git/**、**/.aws/**、**/.ssh/**、**/id_rsa* 等，见 KIRO_AGENT_REQUIRED_DENY_JQ）'
# 三个工具的 deniedPaths 是否都合格（存在、非空、含 **/.git/**）——一次 jq 查完三处（15-fix3 #13）。
# $1=定义文件；stdout 打出第一个不合格的工具名（都合格则为空）；文件为空 / 不是恰好一个 JSON 对象 / 不是合法 JSON 时返回非零。
# fail-closed（15-fix4 #13）：单次 jq 对空 / 纯空白输入**不输出且退出 0**，"" 会被调用方当成「三处都合格」；两个对象拼在一个文件里
# 也只会各打一行。所以 ① 先 `-s` 拒 0 字节；② `--slurp` 把整个文件读成数组、要求恰好一个元素且是对象——「恰好一个 JSON 值」
# 是被检查的条件而不是数输出行数；不满足输出 empty → `-e` 无结果退 4。
_kiro_agent_deny_missing() {
  [[ -s "$1" ]] || return 1
  jq -e -r --slurp "$_KIRO_DENY_OK_JQ"'
      if length != 1 or (.[0] | type) != "object" then empty
      else .[0] | first('"$KIRO_AGENT_TOOLS_JQ"' as $t | select(deny_ok($t) | not) | $t) // "" end' "$1" 2>/dev/null
}

kiro_install_agent() {
  local src="$1" dest_dir="$2"; shift 2
  local ws="" ch="" ws_set=0 ch_set=0 allow_none=0 run_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace) [[ $# -ge 2 ]] || { echo "kiro_install_agent: --workspace 缺少取值" >&2; return 1; }; ws="$2"; ws_set=1; shift 2 ;;
      --chunks)    [[ $# -ge 2 ]] || { echo "kiro_install_agent: --chunks 缺少取值" >&2; return 1; };    ch="$2"; ch_set=1; shift 2 ;;
      --allow-none)  allow_none=1; shift ;;
      # --name：覆盖定义里的 name（同时决定落盘文件名）。执行器每次运行独占一个名字（codeup-reviewer-<nonce>），避免共享 HOME 上
      # 并发运行互相覆盖同一个 agent 文件（CodeX 2026-09-09 P1-2）。只接受 kiro-cli 能当文件名与 --agent 取值的形状。
      --name)      [[ $# -ge 2 ]] || { echo "kiro_install_agent: --name 缺少取值" >&2; return 1; }; run_name="$2"; shift 2 ;;
      *) echo "kiro_install_agent: 未知参数：$1（只接受 --workspace <目录> / --chunks <目录> / --allow-none / --name <agent 名>）" >&2; return 1 ;;
    esac
  done
  if [[ -n "$run_name" ]]; then
    [[ "$run_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
      || { echo "kiro_install_agent: --name 只接受字母数字开头、[A-Za-z0-9._-]、不超过 64 字符：${run_name}" >&2; return 1; }
  fi
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
  [[ -z "$run_name" ]] || name="$run_name"   # 定义里的 name 只是默认值；--name 给了就整份用它（文件名与 JSON 里的 name 一致）
  prompt=$(jq -r '.prompt // empty' "$src")
  # prompt 是只读角色约束所在，缺失就等于让默认系统提示词跑评审——拒绝安装
  [[ -n "$prompt" ]] || { echo "kiro_install_agent: agent 定义缺少 prompt：${src}" >&2; return 1; }
  # deniedPaths 三处都必须合格（15-fix2 #11）。第一行的失败分支不是死代码：本函数跑在调用方的 `$(…) || die_review` 里，errexit 对
  # 命令替换体不生效，_kiro_agent_deny_missing 非零（空 / 多值 / 非对象 / 非法 JSON）若不在这里接住，deny_missing="" 会被当成「三处都合格」。
  # 第二行是检查本身（写成一行，变异测试 M5n 删掉即模拟「忘了检查」）。
  deny_missing=$(_kiro_agent_deny_missing "$src") || { echo "kiro_install_agent: 定义为空、不是恰好一个 JSON 对象或不是合法 JSON：${src}" >&2; return 1; }
  [[ -z "$deny_missing" ]] || { echo "kiro_install_agent: 定义里 toolsSettings.${deny_missing}.${KIRO_AGENT_DENY_MSG}——该工具没有拒绝清单，拒绝安装：${src}" >&2; return 1; }
  # tools 必须恰好是 [read, grep, glob]（15-fix4 #19）：带 execute_bash 的定义装出去，自检会拒，但安装器不该先落盘
  [[ "$(jq -c '.tools' "$src" 2>/dev/null)" == "$(jq -nc "[$KIRO_AGENT_TOOLS_JQ]")" ]] || { echo "kiro_install_agent: 定义 tools 不是恰好 [read, grep, glob]（$(jq -c '.tools' "$src" 2>/dev/null)），拒绝安装：${src}" >&2; return 1; }
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
  # 一次 jq 渲染：改写 prompt（如需）+ 三处 allowedPaths 结构化覆盖 + 三处 deniedPaths 追加按 allow 根注入的绝对形状（--allow-none 则只删 allowedPaths）
  # V3 的 fs_read deny 规则（permissions.rules）与 toolsSettings.*.deniedPaths **同源**（票 18 ⑫）：两处都有 `**/…` 形状，
  # 而 kiro-cli 把它们按 cwd 解析（15-fix4 #1 补）。V3 不上生产（ADR-0004），但定义是 V2/V3 双兼容的，切引擎时不该只有一半形状
  # 拿到绝对副本——那种「一半生效」的边界比明确不支持更危险。--allow-none 同样不注入（正控 agent 要旧形态）。
  rendered=$(jq --arg p "$prompt_new" --arg ws "$ws" --arg ch "$ch" --arg nm "$name" --argjson none "$allow_none" "$_KIRO_DENY_ABS_JQ"'
      .name = $nm
      | (if $p != "" then .prompt = $p else . end)
      | if $none == 1 then del(.toolsSettings[].allowedPaths)
        else reduce '"$KIRO_AGENT_TOOLS_JQ"' as $t (.;
               .toolsSettings[$t].allowedPaths = [$ws, $ch]
               | .toolsSettings[$t].deniedPaths as $d
               | .toolsSettings[$t].deniedPaths = ($d + ($d | deny_abs($ws)) + ($d | deny_abs($ch))))
          | (if ((.permissions // {}).rules | type) == "array"
             then .permissions.rules |= map(
                    if (.capability == "fs_read") and ((.match | type) == "array")
                    then .match as $m | .match = ($m + ($m | deny_abs($ws)) + ($m | deny_abs($ch)))
                    else . end)
             else . end)
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
#   · 三处 deniedPaths 存在、非空、含 **/.git/**，且定义里每条 **/ 形状都有按 $2、$3 两条 allow 根注入的绝对副本（15-fix4 #1 补）
#   · allowedTools == []（免确认只来自 allowedPaths）、includeMcpJson == false、includePowers == false
#   · tools 恰好 == [read, grep, glob]、toolsSettings 的键 ⊆ {read, grep, glob}（多出的键其 allowedPaths 从不被改写）、resources 缺失或 []
#     （非空 resources 会把隔离步骤要阻止的工作区文件重新自动载入）、permissions.rules 只含 deny 规则（V3 deny 是设计的一部分，
#     ADR-0004；放宽成 allow 的规则不放行）——15-fix4 #19：README 把「工具仅 read/grep/glob」当成被强制的性质，自检要按值核对
# 失败返回 1，原因放进 KIRO_AGENT_SELFCHECK_ERROR。执行器第 3 步用它把「日志声称的事实」变成断言；单测直接对篡改过的定义调用。
# 全部检查在**一次** jq 里完成（15-fix3 #13），输出第一条不符的原因（都符合则为空）。
# fail-closed（15-fix4 #13）：这是安装器「打回路径」stdout 交叉核对删掉后（15-fix3 #12）**唯一**的一道门。单次 jq 对空 / 纯空白文件不输出且
# 退出 0 → reason="" → 自检通过——长驻执行器上一份被截断 / 清零 / 误编辑的 ~/.kiro/agents/codeup-reviewer.json 会放行，评审带着
# kiro-cli 回退的 agent 跑（没有 allowedPaths、没有 deniedPaths）；两个各自合格的定义拼在一个文件里也放行（两行空 reason 被 $(…) 吃掉）。
# 三道：① `-s` 拒 0 字节（固定文案）；② `--slurp` 把整个文件读成数组，要求恰好一个元素且是对象（固定文案点明个数 / 类型）——
# 「恰好一个 JSON 值」是被检查的条件，不是数输出行数；③ `-e`：任何无输出的路径都退 4 而不是 0（有 --slurp 时不会发生，防有人删掉 --slurp）。
KIRO_AGENT_SELFCHECK_ERROR=""
kiro_agent_selfcheck() {
  local f="$1" ws="$2" ch="$3" reason
  KIRO_AGENT_SELFCHECK_ERROR=""
  [[ -r "$f" ]] || { KIRO_AGENT_SELFCHECK_ERROR="安装后的定义文件不可读：${f}"; return 1; }
  [[ -s "$f" ]] || { KIRO_AGENT_SELFCHECK_ERROR="安装后的定义文件为空（0 字节）：${f}"; return 1; }
  # 原因顺序固定（15-fix4 #11）：read/grep/glob 逐工具（allowedPaths → deniedPaths），再 allowedTools、includeMcpJson、includePowers。
  # jq 里 `,` 比 `|` 绑定更紧：`… as $t | A, B, C` 会把尾部检查也放进 $t 的作用域（对每个工具各发一次、与逐工具条目交错，first 可能先取到
  # 尾部检查——MR 失败评论把运维指向错的字段），所以 `as $t` 的体用括号收住只包逐工具检查。first(...) 取第一条不符（15-fix4 #5 补）。
  reason=$(jq -e -r --slurp --arg ws "$ws" --arg ch "$ch" --arg deny_msg "$KIRO_AGENT_DENY_MSG" "$_KIRO_DENY_OK_JQ""$_KIRO_DENY_ABS_JQ"'
      def want: [$ws, $ch];
      if length != 1 then "安装后的定义文件里不是恰好一个 JSON 值（\(length) 个；纯空白文件算 0 个）"
      elif (.[0] | type) != "object" then "安装后的定义顶层不是 JSON 对象（是 \(.[0] | type)）"
      else .[0] | first(
        ( '"$KIRO_AGENT_TOOLS_JQ"' as $t
          | ( select(.toolsSettings[$t].allowedPaths != want)
              | "\($t).allowedPaths 写入的是 \(.toolsSettings[$t].allowedPaths | tojson)，预期 \(want | tojson)（业务库 checkout 物理路径 + chunks 物理路径，顺序固定）" ),
            ( select(deny_ok($t) | not) | "\($t).\($deny_msg)" ),
            ( select(deny_abs_missing($t; $ws; $ch) != []) | "\($t).deniedPaths 缺少按 allow 根注入的绝对拒绝形状 \(deny_abs_missing($t; $ws; $ch) | tojson)（kiro-cli 把 **/ 形状按 cwd 解析，空 cwd 下只有绝对副本能护住业务库里的 .git / .ssh / .aws / id_rsa*）" ) ),
        ( select(.allowedTools != []) | "allowedTools 不为空（\(.allowedTools | tojson)）——免确认只能来自 allowedPaths" ),
        ( select(.tools != ['"$KIRO_AGENT_TOOLS_JQ"']) | "tools 不是恰好 [read, grep, glob]（\(.tools | tojson)）" ),
        ( select((((.toolsSettings // {}) | keys) - ['"$KIRO_AGENT_TOOLS_JQ"']) != []) | "toolsSettings 多出工具键 \((((.toolsSettings // {}) | keys) - ['"$KIRO_AGENT_TOOLS_JQ"']) | tojson)——其 allowedPaths 从不被改写" ),
        ( select((.resources // []) != []) | "resources 不为空（\(.resources | tojson)）——工作区文件会被自动载入" ),
        ( select([((.permissions // {}).rules // [])[] | select(.effect != "deny")] != []) | "permissions.rules 含非 deny 规则（V3 只同步 deny）" ),
        ( select(((.permissions // {}) | keys) - ["rules"] != []) | "permissions 含 rules 之外的键（\((.permissions | keys) | tojson)）" ),
        ( select(.includeMcpJson != false) | "includeMcpJson 不是 false" ),
        ( select(.includePowers != false) | "includePowers 不是 false" ),
        # prompt 是只读角色约束的所在（票 18 ⑫）：安装器只在「相对 file://」时改写，绝对 file:// 与内联文本原样保留——
        # 但装完之后它必须是**非空**、且是 file:// **绝对**路径（相对 file:// 复制到 agent 目录后指向不存在的文件，
        # kiro-cli 会静默用默认系统提示词跑评审：拒绝路径与掩码规则全部失效，而事件流里看不出来）
        ( select(((.prompt // "") | type) != "string" or ((.prompt // "") | length) == 0) | "prompt 缺失或为空——那等于让默认系统提示词跑评审" ),
        ( select(((.prompt // "") | startswith("file:///")) | not) | "prompt 不是 file:// 绝对路径（\((.prompt // "") | tojson)）——相对 file:// 在 agent 目录下指向不存在的文件，kiro-cli 会静默回退默认提示词" ),
        # V3 的 fs_read deny 也要有按两条 allow 根注入的绝对副本（与 toolsSettings 同源）
        ( select([((.permissions // {}).rules // [])[] | select(.capability == "fs_read")] as $fr
                 | ($fr | length) > 0
                   and (($fr[0].match // []) as $m
                        | [ ($m | deny_abs($ws)), ($m | deny_abs($ch)) | .[] | . as $e | select(($m | index($e)) == null) ] != []))
          | "permissions.rules 里 fs_read 的 match 缺少按 allow 根注入的绝对拒绝形状（V3 引擎读的是这一处，与 toolsSettings.deniedPaths 同源）" )
      ) // ""
      end' "$f" 2>/dev/null) || { KIRO_AGENT_SELFCHECK_ERROR="定义不是合法 JSON（或 jq 没有产出任何结果）：${f}"; return 1; }
  [[ -z "$reason" ]] || { KIRO_AGENT_SELFCHECK_ERROR="$reason"; return 1; }
  return 0
}

# ── kiro_cli_version ────────────────────────────────────────────────────────────────────────────
# 取**已装** kiro-cli 的版本号（15-fix4 #7 / A6）。用法：kiro_cli_version <timeout 程序名> <运行目录> [超时秒，默认 60]
# 前提：调用方已跑过 kiro_env_allowlist（KIRO_ENV_ALLOW 已填）——与另外三处 kiro-cli 调用同一份 env -i 许可清单。
# 结果：KIRO_CLI_VERSION（取不到为空）；返回 0 = --version 跑通（版本取不到只是 notice，不是失败）；返回 1 = --version 退出码非零，
#   KIRO_CLI_VERSION_ERROR 带退出码与 stderr 尾部（调用方 die_review；--version 都跑不起来的 CLI 不该再在 chat 上烧掉整个 KIRO_TIMEOUT）。
# 取法：stdout 与 stderr **分开捕获**。`2>&1 | head -1` 取到的是先 flush 的那个流的第一行：stderr 无缓冲、stdout 进管道是块缓冲，
#   升级提示「A new version (2.30.0) …」先到 → 报告并据以判定的是**可用**版本而不是已装版本；等 2.30.0 进 KIRO_TESTED_VERSIONS，
#   装着未探测 2.21.x 的机器反而不再告警。先在 stdout 里按程序名锚定 `kiro-cli<空白>X.Y[.Z…]`，取不到再看 stderr（有的 CLI 把版本
#   打到 stderr，15-fix3 #8）；两个流里都没有这个形态就当未知（宁可 notice，不猜）。
# 执行器第 3 步与探测脚本（summary.json 的 kiro_cli 字段——人工抄进 KIRO_TESTED_VERSIONS 的来源）都调这一个函数。
KIRO_CLI_VERSION=""
KIRO_CLI_VERSION_ERROR=""
# 按程序名锚定取版本：程序名前面不能粘着标识符字符（mykiro-cli 9.9.9 不算），后面只能是空白 + 数字点串；取第一个匹配
_kiro_cli_version_pick() {
  if [[ "$1" =~ (^|[^A-Za-z0-9_-])kiro-cli[[:space:]]+([0-9]+(\.[0-9]+)+) ]]; then printf '%s' "${BASH_REMATCH[2]}"; fi
  return 0
}
kiro_cli_version() {
  local tbin="$1" cwd="$2" secs="${3:-60}" out err errf rc=0
  KIRO_CLI_VERSION=""; KIRO_CLI_VERSION_ERROR=""
  errf=$(mktemp) || { KIRO_CLI_VERSION_ERROR="无法创建临时文件"; return 1; }
  out=$(cd "$cwd" && "$tbin" "$secs" env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli --version 2>"$errf") || rc=$?
  err=$(cat "$errf" 2>/dev/null || true); rm -f "$errf"
  if [[ "$rc" -ne 0 ]]; then
    KIRO_CLI_VERSION_ERROR="kiro-cli --version 失败（退出码 ${rc}$([[ "$rc" == "124" ]] && printf '，超时 %ss' "$secs")）；stderr 尾部：$(printf '%s\n' "$err" | tail -n 3 | tr '\n' ' ')"
    return 1
  fi
  KIRO_CLI_VERSION=$(_kiro_cli_version_pick "$out")
  [[ -n "$KIRO_CLI_VERSION" ]] || KIRO_CLI_VERSION=$(_kiro_cli_version_pick "$err")
  return 0
}

# --- kiro-cli 二进制摘要钉死（CodeX 2026-09-10 复审 P1：版本字符串不是完整性边界——任何打印 2.21.1 的二进制都过得了版本门）---
# 三个函数都**不执行 kiro-cli**：核对要发生在第一次执行它之前（kiro-review.sh 第 2.1 步，早于第 3 步的 chat --help / settings / --version）。
# 只钉 `command -v kiro-cli` 解析符号链接后的**入口文件**（macOS 装的是指向 Kiro CLI.app 内部的符号链接；Linux 安装脚本装到 ~/.local/bin）；
# 入口文件再拉起的别的文件不在核对范围内，文档写明。
# kiro_cli_resolve → stdout 入口文件的物理路径；rc 1 = PATH 里没有 kiro-cli / 符号链接断了 / 链太长
kiro_cli_resolve() {
  local p t n=0
  p=$(command -v kiro-cli) || return 1
  while [[ -L "$p" && $n -lt 40 ]]; do
    t=$(readlink "$p") || return 1
    [[ "$t" == /* ]] || t="$(cd "$(dirname "$p")" && pwd -P)/$t"
    p="$t"; n=$((n + 1))
  done
  [[ -f "$p" && ! -L "$p" ]] || return 1
  printf '%s/%s' "$(cd "$(dirname "$p")" && pwd -P)" "$(basename "$p")"   # 物理路径（消掉相对链接带进来的 ..）
}
# kiro_cli_sha256 <文件> → stdout 64 位十六进制；rc 2 = 执行器既没有 sha256sum 也没有 shasum；rc 1 = 文件读不了
kiro_cli_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then out=$(sha256sum "$1" 2>/dev/null) || return 1
  elif command -v shasum >/dev/null 2>&1; then out=$(shasum -a 256 "$1" 2>/dev/null) || return 1
  else return 2; fi
  printf '%s' "${out%% *}"
}
# kiro_cli_sha256_check <期望的 64 位小写十六进制> → 全局 KIRO_CLI_BIN / KIRO_CLI_SHA256_ACTUAL；rc 0 = 一致；rc 1 = 不一致；rc 2 = 算不出
KIRO_CLI_BIN=""; KIRO_CLI_SHA256_ACTUAL=""
kiro_cli_sha256_check() {
  local want="$1" have
  KIRO_CLI_BIN=""; KIRO_CLI_SHA256_ACTUAL=""
  KIRO_CLI_BIN=$(kiro_cli_resolve) || return 2
  have=$(kiro_cli_sha256 "$KIRO_CLI_BIN") || return 2
  [[ "$have" =~ ^[0-9a-f]{64}$ ]] || return 2
  KIRO_CLI_SHA256_ACTUAL="$have"
  [[ "$have" == "$want" ]]
}

# ── kiro_env_allowlist ──────────────────────────────────────────────────────────────────────────
# Kiro 子进程环境的许可清单（票 15，spec §4.2 修订；15-fix #11/#12；15-fix2 #12 #13 #14 #17）：填充数组 KIRO_ENV_ALLOW，
# 每个元素是 `VAR=value`，供 `env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli …` 使用（用数组而不是按行输出：取值里若有换行，
# 按行读回去会把半个取值当成 env 的命令名）。
# **固定名单**（不做形状匹配：KIRO_* / *_PROXY / XDG_* 这类模式会放行 CORP_SECRET_PROXY、客户自定义的 KIRO_…）：
#   PATH、HOME（登录态与 ~/.kiro/agents 都靠它）、USER、TERM、TMPDIR、LANG、LANGUAGE、LC_ALL、LC_CTYPE、LC_MESSAGES、
#   KIRO_API_KEY、KIRO_LOG_NO_COLOR、HTTP_PROXY/HTTPS_PROXY/FTP_PROXY/ALL_PROXY/NO_PROXY 与小写五个、
#   SSL_CERT_FILE、SSL_CERT_DIR、CURL_CA_BUNDLE、XDG_CONFIG_HOME、XDG_DATA_HOME、XDG_CACHE_HOME、XDG_STATE_HOME、XDG_RUNTIME_DIR。
# **逃生口** KIRO_ENV_PASSTHROUGH：逗号分隔的变量**名**（自建执行器可能需要 LD_LIBRARY_PATH / JAVA_HOME / AWS_PROFILE 这类），
#   只放名字不放值。两道校验，任一不过 → 返回 1、原因放进 KIRO_ENV_ALLOW_ERROR，调用方必须拒绝运行而不是静默忽略：
#   ① 语法：不是 [A-Za-z_][A-Za-z0-9_]*（例如写成 NAME=value）→ 拒绝。
#   ② 凭证形状的名字 → 拒绝（15-fix2 #13 / 15-fix3 #6 / 15-fix4 #4）：规则表 KIRO_ENV_CRED_RULES（YUNXIAO_*、CODEUP_*、AWS_*、*TOKEN*、
#      *SECRET*、*PASSWORD*、*CREDENTIAL*、*_KEY、*_PAT、*_PAT_*、DCKR_PAT_*，以及令牌前缀 GHP_*、GHO_*、GITHUB_PAT_*、AKIA*、ASIA*；大小写不敏感），
#      显式放行 KIRO_ENV_CRED_ALLOW（AWS_PROFILE / AWS_REGION / AWS_DEFAULT_REGION：它们是配置不是凭证；AWS_* 其余仍拒）。
#      这份拒绝清单是**防运维手滑**、不是安全边界：受信 agent 没有 shell / env 工具，变量到不了模型手里；逃生口存在的意义就是客户不改代码
#      也能放行自家构建变量。`XOX*` 已删（死代码：真实 Slack 令牌带连字符，先被 ① 拒）。
#   诊断（15-fix4 #4 ③ / A8）：MR 失败评论（KIRO_ENV_ALLOW_ERROR）按**条目序号 + 掩码名 + 命中规则**列出（「第 2 项 AWS****（命中 AWS_*）」），
#   同一首段的几个名字才分得开；**流水线日志**（stderr）对命中名字类规则的条目打完整名字 + 规则（名字是运维自己写的配置，不是模型文本），
#   命中令牌前缀规则（GHP_* / GHO_* / GITHUB_PAT_* / AKIA* / ASIA*）的条目在日志里也只留掩码——那更像是贴了个真令牌。
#   凭证形状分支的掩码 = 首段（第一个 _ 之前；首段为空——名字以 _ 开头——或没有 _ 时取前 4 个字符）+ ****；语法错误分支打完整标识符 + ****
#   （`LD_LIBRARY_PATH=/opt/lib` 是手误不是秘密，只隐藏 = 后面的取值）。取值从不出现在任何输出里。
#   名字对应的变量未设置 → 跳过。KIRO_ENV_PASSTHROUGH 自己不透传。
# YUNXIAO_* / CODEUP_* 以及 Flow 注入的一切都不进 Kiro 进程（/proc 已在拒绝清单里，这是零成本的第二道）。
# KIRO_LOG_NO_COLOR=1 固定追加（用户设成别的值也被覆盖）。只透传**已导出**的变量：未导出的本来也到不了子进程。
#   导出判定看 `declare -p` 的属性段里有没有 x（`declare -rx` / `-ix` / `-ax` 都算，15-fix2 #12——只认 `declare -x` 前缀会把
#   `declare -rx TMPDIR` 这类丢掉，env -i 起 kiro 时没有 TMPDIR/PATH/HOME）。
# 四处 kiro-cli 调用（chat --help / --version / settings / chat）都用同一份清单；探测脚本 probe-kiro-allowlist.sh 也复用——规则只有一份。
KIRO_ENV_FIXED_NAMES=(PATH HOME USER TERM TMPDIR LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES KIRO_API_KEY KIRO_LOG_NO_COLOR HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy ftp_proxy all_proxy no_proxy SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR)
KIRO_ENV_ALLOW=()
KIRO_ENV_ALLOW_ERROR=""
# 被拒 token / 名字的掩码：先取开头的合法标识符字符段（没有就只有 ****），再只留它的首段——第一个 _ 之前；首段为空（以 _ 开头，A8）
# 或没有 _ 时取前 4 个字符——加 ****。`KIRO_FOO=s3cr3t`→KIRO****，`ghp-liveSecret123`→ghp****，`svc_SECRET_9f3a`→svc****，`_FOO_SECRET`→_FOO****，`1ABC`→****
# 语法错误分支的掩码（15-fix4 #4 补 / 主报告第 8 条）：`LD_LIBRARY_PATH=/opt/lib` 是名字带了 = 的手误、不是秘密——打**完整标识符** + ****，
# 只隐藏 = 后面的取值；掩到首段只在凭证形状分支
_kiro_env_mask_syntax() {
  if [[ "$1" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then printf '%s****' "${BASH_REMATCH[1]}"; else printf '****'; fi
}
_kiro_env_mask_token() {
  local id seg
  if [[ "$1" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then id="${BASH_REMATCH[1]}"; else printf '****'; return 0; fi
  seg="${id%%_*}"; [[ "$id" == *_* && -n "$seg" ]] || seg="${id:0:4}"
  printf '%s****' "$seg"
}
# 凭证形状规则表与显式放行（15-fix4 #4）。_kiro_env_cred_rule <大写名字> → stdout 命中的规则（空 = 放行）；
# 令牌前缀类规则（更像贴了真令牌）在流水线日志里也只留掩码，其余名字类规则日志给全名
# 顺序即优先级：先具体（令牌前缀、DCKR_PAT_*）再泛（*_PAT_* 也匹配 GITHUB_PAT_…），命中的规则名要能说明「为什么」
KIRO_ENV_CRED_RULES=('GHP_*' 'GHO_*' 'GITHUB_PAT_*' 'AKIA*' 'ASIA*' 'DCKR_PAT_*' 'YUNXIAO_*' 'CODEUP_*' 'AWS_*' '*TOKEN*' '*SECRET*' '*PASSWORD*' '*CREDENTIAL*' '*_KEY' '*_PAT' '*_PAT_*')
KIRO_ENV_CRED_TOKEN_RULES=('GHP_*' 'GHO_*' 'GITHUB_PAT_*' 'AKIA*' 'ASIA*')
KIRO_ENV_CRED_ALLOW=(AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION)
# 用「、」拼接条目（IFS 只认单字节，不能塞多字节分隔符）
_kiro_env_join() { local sep="$1" out="" x; shift; for x in "$@"; do out+="${out:+$sep}$x"; done; printf '%s' "$out"; }
_kiro_env_cred_rule() {
  local r
  for r in "${KIRO_ENV_CRED_ALLOW[@]}"; do [[ "$1" == "$r" ]] && return 0; done
  for r in "${KIRO_ENV_CRED_RULES[@]}"; do [[ "$1" == $r ]] && { printf '%s' "$r"; return 0; }; done
  return 0
}
kiro_env_allowlist() {
  KIRO_ENV_ALLOW=(); KIRO_ENV_ALLOW_ERROR=""
  local n tok rest up rule seen=" " idx=0 tr_ tok_rule
  local -a names=("${KIRO_ENV_FIXED_NAMES[@]}") bad=() cred=() cred_log=()
  if [[ -n "${KIRO_ENV_PASSTHROUGH:-}" ]]; then
    rest="${KIRO_ENV_PASSTHROUGH},"
    while [[ -n "$rest" ]]; do
      tok="${rest%%,*}"; rest="${rest#*,}"
      tok="${tok#"${tok%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"   # 去首尾空白
      [[ -z "$tok" ]] && continue
      idx=$((idx + 1))
      if [[ ! "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then bad+=("第 ${idx} 项 $(_kiro_env_mask_syntax "$tok")"); continue; fi
      up=$(printf '%s' "$tok" | tr '[:lower:]' '[:upper:]')
      rule=$(_kiro_env_cred_rule "$up")
      if [[ -n "$rule" ]]; then
        cred+=("第 ${idx} 项 $(_kiro_env_mask_token "$tok")（命中 ${rule}）")
        tok_rule=0; for tr_ in "${KIRO_ENV_CRED_TOKEN_RULES[@]}"; do [[ "$rule" == "$tr_" ]] && tok_rule=1; done
        if [[ "$tok_rule" == "1" ]]; then cred_log+=("第 ${idx} 项 $(_kiro_env_mask_token "$tok")（命中 ${rule}，像贴了令牌，日志也只留掩码）")
        else cred_log+=("第 ${idx} 项 ${tok}（命中 ${rule}）"); fi
      else
        names+=("$tok")
      fi
    done
    if [[ ${#bad[@]} -gt 0 ]]; then KIRO_ENV_ALLOW_ERROR="KIRO_ENV_PASSTHROUGH 含非法变量名：$(_kiro_env_join 、 "${bad[@]}")（只接受逗号分隔的变量名，例如 LD_LIBRARY_PATH,JAVA_HOME；不能带 = 或取值；非法部分已掩码）"; echo "kiro_env_allowlist: ${KIRO_ENV_ALLOW_ERROR}" >&2; return 1; fi
    if [[ ${#cred[@]} -gt 0 ]]; then
      # 规则清单从规则表派生（票 18 ⑫）：原先这句散文把 16 条规则又抄了一遍，加一条规则忘了改文案时，MR 上那句
      # 「规则：…」就会漏掉真正命中的那一条，运维照着它排查会得出「这个名字不该被拒」的结论。
      KIRO_ENV_ALLOW_ERROR="KIRO_ENV_PASSTHROUGH 含凭证形状的变量名，拒绝透传：$(_kiro_env_join 、 "${cred[@]}")（已掩码；规则：$(_kiro_env_join 、 "${KIRO_ENV_CRED_RULES[@]}")，其中 $(_kiro_env_join 、 "${KIRO_ENV_CRED_TOKEN_RULES[@]}") 是令牌前缀；显式放行 $(_kiro_env_join 、 "${KIRO_ENV_CRED_ALLOW[@]}")——固定名单刚把令牌关在门外，不能被一个变量名重新打开；完整名字见流水线日志）"
      echo "kiro_env_allowlist: KIRO_ENV_PASSTHROUGH 含凭证形状的变量名，拒绝透传：$(_kiro_env_join 、 "${cred_log[@]}")" >&2
      return 1
    fi
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
