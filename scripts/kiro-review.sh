#!/usr/bin/env bash
# Codeup MR 自动 Kiro 评审 — 主编排脚本。
# 安全前提：本脚本必须从受信集成包仓库（流水线独立代码源，固定分支/tag）执行，
# 绝不从被评审的业务仓库源分支执行（源分支可被 MR 作者任意修改）。
# 业务仓库 checkout 目录由 REVIEW_REPO_DIR 指定，仅作为被分析数据：它只出现在受信 agent 的 allowedPaths 里，
# **四处 kiro-cli 调用都在 $WORK/cwd（空目录）下运行**（15-fix4 #1）——kiro-cli 相对 cwd 发现的每一个面（.kiro/agents 顶替
# 受信 agent、.kiro/settings/cli.json 顶掉全局设置、AGENTS.md steering、lsp.json…）都落在一个没有文件的目录里；
# 第 5.5 步对业务库工作树里 AGENTS.md/lsp.json/.kiro/符号链接 的删除保留为**第二道**。Kiro 固定以 v2 引擎运行（ADR-0004）。
# 输出契约：Kiro 以 --output-format stream-json 输出事件流，评审报告是 runFinished.data.finalText 里
# 由 <<<KIRO_REVIEW_JSON>>> 包裹的一段 JSON；汇总评论由 scripts/lib/review-render.sh 渲染。
# 汇总评论生命周期：每评审员每 MR 至多一条（spec I4）。发评论前先查 MR 的全局评论，按
# 「作者 = 机器人账号 且 正文含评审标记」定位上一次那条，找到就原地更新（run:N 递增、历次表 +1），
# 找不到或更新失败就新建。成功、降级、失败三种评论都走 post_summary，形态一致、都参与原地更新。
# 退出码：0=评审完成并回写；非 0=失败（不卡合并，仅流水线标红）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# -P 解析掉符号链接：两侧都用物理路径，下面的「REVIEW_REPO_DIR 不得指向集成包自身」比较才拦得住
# `ln -s <集成包> /tmp/link; REVIEW_REPO_DIR=/tmp/link` 这种绕过（R10①）
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
source "${SCRIPT_DIR}/lib/codeup-api.sh"
source "${SCRIPT_DIR}/lib/diff-compress.sh"
source "${SCRIPT_DIR}/lib/kiro-agent.sh"
source "${SCRIPT_DIR}/lib/isolation.sh"
source "${SCRIPT_DIR}/lib/review-render.sh"

KIRO_TIMEOUT="${KIRO_TIMEOUT:-900}"
# 评论字节上限。必须校验：非整数会让下面的 `-gt` 比较在 set -e 下直接崩掉，而 0 会让每条评论
# 都被截成残片。真正的兜底在 review_truncate_comment 里——截断后如果连评审标记都没了就拒绝截断，
# 因为那份残片会被 PUT 到上一条汇总上，把上一次的完整报告与全部历次记录不可恢复地覆盖掉。
MAX_COMMENT_BYTES_DEFAULT=60000
MAX_COMMENT_BYTES="${MAX_COMMENT_BYTES:-$MAX_COMMENT_BYTES_DEFAULT}"
if ! [[ "$MAX_COMMENT_BYTES" =~ ^[0-9]+$ ]] || [[ "$MAX_COMMENT_BYTES" -lt 1 ]]; then
  echo "[kiro-review] 警告：MAX_COMMENT_BYTES=${MAX_COMMENT_BYTES} 不是 ≥1 的整数，按默认 ${MAX_COMMENT_BYTES_DEFAULT} 处理" >&2
  MAX_COMMENT_BYTES="$MAX_COMMENT_BYTES_DEFAULT"
fi
# 行内评论开关（spec §4.6）。
#   0（默认）：MR 上只有一条汇总评论，内含按 P0→P1→P2 分组的完整问题清单（I7 观感不变）。
#   1：可定位的问题按档位发成行内评论，汇总退化为状态面板 + 折叠区（spec §4.3、§4.5）。
# 取值只允许 0/1；别的取值一律拒绝运行，绝不静默按 0 跑（那样开关看起来生效了、实际什么也没发生）。
INLINE_COMMENT="${INLINE_COMMENT:-0}"
# 行内档位与单次上限（spec §4.6）。非法取值由 review_plan_inline 回落默认值并记 warning——
# 配错档位不该让整次评审失败，但必须在日志里看得见。
INLINE_PROFILE="${INLINE_PROFILE:-quiet}"
MAX_INLINE_COMMENTS="${MAX_INLINE_COMMENTS:-10}"
# 行内评论实际是否生效：版本对取不到时降为 0，并把原因写进汇总评论（INLINE_NOTICE）。
INLINE_ACTIVE=0
INLINE_NOTICE=""
# 版本列表滞后时的重查上限（票 17-fix2 B③、17-fix3 ⑥⑪：预采样与发布前采样共用同一组上限）。
# 两个上限一起生效：次数上限挡住「退避为 0 时空转」，总等待预算挡住「退避累加把流水线挂住」。
# 这两个常量是文案与文档里那些数字的唯一来源——setup-guide/ADR 不再硬写次数（票 17-fix3 ⑯）。
INLINE_LAG_MAX=3
INLINE_LAG_BUDGET=45
# from 侧探针的结果（1 = Codeup 的比较基准与本地 merge-base 不一致）。默认 0：`set -u` 下没跑过探针
# 就读它会直接崩掉整次评审。
INLINE_FROM_OFFSET=0
# 官方安装脚本 URL。来源：https://kiro.dev/docs/cli/installation/（页面命令
# `curl -fsSL https://cli.kiro.dev/install | bash`；脚本本身支持 Linux/macOS，
# Linux 下安装到 ~/.local/bin，含 glibc 检测与 musl 回退）。核实日期：2026-07-21。
KIRO_INSTALL_URL="${KIRO_INSTALL_URL:-https://cli.kiro.dev/install}"
PROMPT_FILE="${PROMPT_FILE:-${PKG_ROOT}/prompts/review-prompt.md}"
AGENT_FILE="${PKG_ROOT}/kiro/agent-codeup-reviewer.json"
REVIEW_REPO_DIR="${REVIEW_REPO_DIR:-$PWD}"
# Kiro 进程环境许可清单之外要额外透传的变量**名**（逗号分隔，只放名字不放值；自建执行机可能需要 LD_LIBRARY_PATH /
# JAVA_HOME / AWS_PROFILE 这类；凭证形状的名字按规则拒绝，AWS_PROFILE / AWS_REGION / AWS_DEFAULT_REGION 显式放行）。固定名单与校验在 scripts/lib/kiro-agent.sh 的 kiro_env_allowlist；
# 非法名字在第 1.6 步拒绝运行。
KIRO_ENV_PASSTHROUGH="${KIRO_ENV_PASSTHROUGH:-}"
# 探测 P1-15（T8：符号链接与 ../ 越界都是先解析再比对 allowedPaths）实测过的 kiro-cli 版本（空格分隔）。读取边界依赖 kiro-cli
# 的路径解析行为；本次版本不在名单里时不失败（客户 curl 装的往往是最新版），但要在日志与汇总评论里留 notice（15-fix2 #24）。
# 升级 kiro-cli 后：跑 scripts/probe/probe-kiro-allowlist.sh（至少 T8），通过后把版本加进这里。
KIRO_TESTED_VERSIONS="2.21.1"
# Kiro 引擎钉死为 v2，写在脚本里而不是 agent 配置里（ADR-0004）：实测 kiro-cli 2.21 headless 的默认
# 引擎 v1 与预览版 v3 都不阻断工作区 AGENTS.md 注入，只有 v2 配合 chat.disableInheritingDefaultResources
# 才阻断。故意不读环境变量——引擎不是可配置项，避免被流水线变量或工作区设置改掉。
KIRO_ENGINE=v2

log() { echo "[kiro-review] $*" >&2; }
# 流水线日志也是评论出口（I3）：失败原因 / 降级原因里**不受信**的那一部分（事件流的 runFinished.status、jq 报错回显、去重日志里的
# 文件名）打日志前先过脚本侧掩码（--keep-lines：文本级、保行）。脚本自己的固定文案与不受信取值分成两个参数传进来（16-fix4 第 6 条），
# 掩码程序不可用时只丢不受信部分、固定文案照打——不再用「有没有 ≥ 12 位连片」去猜哪些文案能打（那会把 INLINE_COMMENT / KIRO_TIMEOUT /
# --output-format 这类最需要运维看到的配置错误整段吞掉，也会放过短口令）。用法：_untrusted_for_log <不受信取值> → stdout（不带结尾换行）
_untrusted_for_log() {
  local s="${1-}" out
  [[ -n "$s" ]] || return 0
  if out=$(printf '%s\n' "$s" | review_redact_secrets --keep-lines 2>/dev/null) && [[ -n "$out" ]]; then printf '%s' "$out"; return 0; fi
  printf '%s' "〈不受信取值已省略〉"   # 中性占位（第 6 条修订）：不写「失败原因」一类字样，日志读者按上下文理解
}
die() { log "错误：$*"; exit 1; }
# 校验日志（review_validate 的 stderr）→ 可打日志的一行：库函数前缀的行原样（用「；」连接），其余行只报条数（第 13 条）
_validate_err_lib_lines() {
  local f="${1-}" lib="" n_other=0 line
  [[ -r "$f" ]] || { printf '%s' "（校验日志不可读）"; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    # 前缀清单就是库里 echo "<name>: …" 实际用到的四个名字（_review_normalize 以 review_validate 报错，_review_jq_inplace / _review_redact_to 用调用方的名字）
    if [[ "$line" =~ ^(review_validate|review_redact_json|review_finalize_json|review_redact_secrets):\  ]]; then
      lib="${lib:+${lib}；}${line}"
    elif [[ -n "$line" ]]; then n_other=$((n_other + 1)); fi
  done < "$f"
  printf '%s%s' "${lib:-（校验日志里没有库函数的说明行）}" "$([[ "$n_other" -gt 0 ]] && printf '；另有 %s 行 jq 诊断已省略（可能回显模型取值）' "$n_other")"
}
# 汇总评论里的一句话 notice（与行内评论的 INLINE_NOTICE 并列；评论比日志可见范围大，I10）。
# 归属（15-fix4 #3）：REVIEW_NOTICE 是版本 / 环境类提示，三种评论都带；INLINE_NOTICE 是关于分桶的提示（「全部问题都归入未定位」），
# 只对带问题清单的汇总评论有意义——降级 / 失败评论只传 REVIEW_NOTICE。all_notice() 是汇总评论那一份合成，读全局、只在这里拼一次。
REVIEW_NOTICE=""
all_notice() { printf '%s' "${REVIEW_NOTICE}${REVIEW_NOTICE:+${INLINE_NOTICE:+ }}${INLINE_NOTICE}"; }

# 定位到 MR 后的失败：best-effort 回写"评审未完成"评论再退出
MR_LOCATED=0
# 汇总评论原地更新所需的状态，由第 1.5 步填好。die_review 在第 1 步之后的任何时刻都可能被调用，
# 所以先给出安全默认值：没有旧评论、第 1 次评审、无历次记录。
PRIOR_COMMENT_ID=""
REVIEW_RUN=1
PRIOR_HISTORY_FILE=""

# 发布汇总评论：有旧评论就原地更新（评论 biz_id 不变），更新失败则退回新建。
# 成功 / 降级 / 失败三种评论都走这里——失败评论若单独新建，一次失败就会在 MR 上留下第二条汇总，
# 与 spec I4「每评审员每 MR 至多一条汇总评论」相悖。代价是：失败会覆盖上一次报告的问题清单，
# 但「历次评审」表仍保留历次的提交、结论与 P0/P1/P2 计数。
post_summary() {
  local file="$1"
  # 硬守卫：空正文一旦 PUT 上去，会把上一次的完整报告（含隐藏历史）覆盖成空白且不可恢复。
  # codeup_update_comment 里也有一道同样的检查——这是两个方向都必须堵住的失败：
  # 成功路径有 `[[ -s ]]`，而失败路径（die_review）曾经把渲染失败产出的 0 字节文件直接交过来。
  [[ -s "$file" ]] \
    || { log "错误：待发布的评论正文为空，拒绝回写（空正文会把上一条汇总覆盖成空白）"; return 1; }
  if [[ -n "$PRIOR_COMMENT_ID" ]]; then
    if codeup_update_comment "$LOCAL_ID" "$PRIOR_COMMENT_ID" "$file"; then
      log "已原地更新汇总评论 ${PRIOR_COMMENT_ID}（第 ${REVIEW_RUN} 次评审）"
      return 0
    fi
    # 最常见的原因是旧评论刚被人删掉（404）：4xx 不重试，直接退回新建
    log "警告：原地更新汇总评论 ${PRIOR_COMMENT_ID} 失败（已按既有重试策略处理），退回新建"
  fi
  codeup_post_comment "$LOCAL_ID" "$file"
}

# 最小失败评论（die_review 的两种回退形态共用一份渲染）：仍带评审标记（下次评审才找得到这条）、隐藏历史与页脚。
# 用法：_die_review_minimal <失败原因（可为空）> → stdout
#   原因非空：清洗后写进正文（失败评论渲染器 rc≠0 时的回退）；
#   原因为空：只写固定文案——给「sink 掩码本身失败」用：此时 $* 里可能带模型回显的取值（jq 报错会回显模型文本），
#   而掩不掉它，所以一个字都不带。
_die_review_minimal() {
  local reason="${1-}" mh
  mh=$(mktemp)
  # 先带上读回来的历次记录再退化（三步回退在 review_history_for_run 一处定义）：这条最小评论同样会被 PUT 到上一条汇总上，
  # 直接用 `-`（空历史）会把累积的 20 行 run/sha/结论/计数一次性抹掉。评论头（标题 + 评审标记 + 隐藏历史）与三个渲染器
  # 同一份（review_render_comment_head）——以前这里手写第三份，守卫漏掉它就会在 MR 上多出一条汇总。
  review_history_for_run "${PRIOR_HISTORY_FILE:--}" "$REVIEW_RUN" "${SHORT_SHA:-unknown}" failed die_review > "$mh"
  review_render_comment_head "$REVIEW_TITLE_FAILED" "${SHORT_SHA:-unknown}" "$REVIEW_RUN" "$mh"
  echo ""
  if [[ -n "$reason" ]]; then
    # 失败原因可能带来自事件流的取值（不受信，例如 runFinished.status）。不清洗的话，
    # 一个含 `<!-- kiro-review:… -->` 的取值就能让这条评论带上第二个评审标记 →
    # 下一次评审判它「标记不唯一」而不作为候选 → MR 上多出一条汇总（违反 I4）；
    # 含 `-->` 的取值还会把上面那行隐藏历史提前闭合、把 JSON 露成正文。
    printf '⚠️ 评审未完成（失败评论渲染异常，只保留最小信息）：'
    printf '%s' "$reason" | review_sanitize_md
    echo ""
  else
    echo "⚠️ 评审未完成（脚本侧密钥掩码不可用，为避免泄漏只保留固定文案；失败原因见流水线日志）。"
  fi
  echo ""
  echo "请查看流水线日志（构建号 ${BUILD_NUMBER:-?}）或重跑流水线。"
  echo ""
  review_render_footer "$REVIEW_RUN"
  rm -f "$mh"
}

# 用法：die_review <固定文案> [<不受信取值>]——固定文案是脚本自己写的，不受信取值（事件流 / 模型派生）单独传，日志里只对后者掩码
die_review() {
  local reason_fixed="${1-}" detail="${2-}" reason_full
  reason_full="${reason_fixed}${detail:+：$detail}"
  log "错误：${reason_fixed}${detail:+：$(_untrusted_for_log "$detail")}"
  if [[ "$MR_LOCATED" == "1" ]]; then
    local f
    local -a hist_args=()
    f=$(mktemp)
    # 失败评论的形态（标题/评审标记/历史标记/元信息表/历次表/页脚）由 review_render_failure 统一渲染，
    # 与成功、降级评论同出一源：定位旧评论靠 `<!-- kiro-review:<sha> run:N -->`，
    # 失败评论若自己手写一份、哪天与渲染器走形，就会被漏掉、于是在 MR 上多出一条汇总。
    [[ -n "$PRIOR_HISTORY_FILE" ]] && hist_args=(--history "$PRIOR_HISTORY_FILE")
    review_render_failure --reason "$reason_full" --sha "${SHORT_SHA:-unknown}" \
      --src "${SOURCE_BRANCH:-?}" --dst "${TARGET_BRANCH:-?}" \
      --ts "$(date '+%Y-%m-%d %H:%M:%S')" --diff-note "${DIFF_NOTE:-（本次未生成 diff）}" \
      --run "$REVIEW_RUN" "${hist_args[@]+"${hist_args[@]}"}" \
      --notice "$REVIEW_NOTICE" \
      --log-hint "请查看流水线日志（构建号 ${BUILD_NUMBER:-?}）或重跑流水线。" > "$f" \
      || log "警告：失败评论渲染异常（rc≠0），改用最小失败评论"
    # 渲染器在参数不合规时（例如 --ts 为空、--history 不可读）以 rc 2 提前返回，$f 就是 0 字节。
    # 那份空文件绝不能交给 post_summary：PUT 空正文会把上一条完整报告覆盖成空白且不可恢复。
    # 退回一段最小的纯文本失败评论——仍带评审标记（下次评审才找得到这条）与本次一行历史。
    if [[ ! -s "$f" ]]; then
      _die_review_minimal "$reason_full" > "$f"
      log "已退回最小失败评论（保证不 PUT 空正文）"
    fi
    # sink 掩码（票 16）：两种形态的 --reason 都可能回显模型取值（「契约 JSON 顶层结构不符」拼的是 jq 的报错，
    # jq 会把出错的取值回显在消息里）。掩码本身失败时退回**只含固定文案**的最小评论——不带 $*，
    # 绝不带着掩不掉的原因回写。
    local rrc=0
    review_redact_file "$f" || rrc=$?
    if [[ "$rrc" != "0" ]]; then
      case "$rrc" in   # rc 含义见 review_redact_file 的头注释；只区分「守卫拒绝」与其余（第 9 条）
        3) log "警告：失败评论掩码后结构守卫拒绝写回（行数或标记行变化，rc=3），改用只含固定文案的最小失败评论（不带失败原因）" ;;
        *) log "警告：失败评论掩码失败（rc=${rrc}），改用只含固定文案的最小失败评论（不带失败原因）" ;;
      esac
      _die_review_minimal "" > "$f"
    fi
    post_summary "$f" || log "回写失败评论也未成功，仅保留日志"
    rm -f "$f"
  fi
  exit 1
}

# --- 行内评论管线（INLINE_COMMENT=1；spec §4.5 第 1–7 步）---
# 入参 $1 = 规范化契约（review_validate 的输出）
# 产出 $WORK/plan.json：已按发布结果回填，可直接交给 review_render_summary --inline-comment 1
# rc 0 = 计划就绪（INLINE_ACTIVE=1）
# rc 1 = 本次发不了行内评论，原因写进 INLINE_NOTICE；调用方回落 INLINE_COMMENT=0 渲染，
#        让这条汇总带上完整问题清单——问题一条都不能因为「行内发不出去」而消失（I4/I10）。
# 注意：本函数被写成 `if publish_inline_comments …`，`if` 会让整个函数体不受 errexit 约束，
# 所以每一步都显式判退出码，绝不依赖 set -e。
# 每个 fail-closed 出口的 `return 1` 后面带一个 `# fail-closed:<名字>` 标签：变异测试按标签精确锚定
# （票 17-fix3；此前锚 notice 文案，文案挪进 inline_bail_to 之后就失配了）。改名字要同步 test-mutations.sh。
# fail-closed / 发不出去的统一出口（票 17-fix2 C⑤）：原因既要进汇总评论（阿里云侧看不到流水线日志，I10），
# 又要进日志。六个出口原先各抄一份「拼 notice + log + return 1」，改一处文案就得同步六处。
# 本函数自身 return 1（票 17-fix3 ⑬）：调用点写 `inline_bail "<notice>" "<log>" || return 1`。
# 之前 rc 由调用点自己拼，漏一处就变成「notice 写了、却继续往下发」，而 e2e 只看最终结果、照样绿。
inline_bail() {
  INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }$1"
  log "$2"
  return 1   # 票 17-fix3 ⑬：rc 由本函数给，调用点写 `… || return 1`——漏掉 rc 时不会「说明了原因却继续往下发」
}

# 把 Codeup 给的提交号规范化成本地克隆里的全 sha（票 17-fix2 B③）：接受缩写与大写。
# 真实 API 只观察到 40 位全 sha（acceptance 留档）；规范化是对**未观察到的形态**保守——万一哪天返回缩写，
# 字面比较会把它误判成「不一致」并把行内评论永久关掉。
# **先锚形状再 rev-parse**（票 17-fix3 ①）：`git rev-parse --verify "<x>^{commit}"` 接受任意 revision 表达式，
# 不锚形状的话 `HEAD` / `@` / 一个 refname 都能解析成克隆里的分支顶端、恰好等于 HEAD，于是「版本已证明」
# 这条结论建立在一个从未核对过内容的取值上（fail-open，比误判成不一致严重得多）。
# rc 0 + stdout 全 sha = 该提交在克隆里；rc 1 = 不是 sha 形状、或解析不出（对象不在克隆里 / 不是提交对象）。
inline_resolve_commit() {
  local raw="${1//[[:space:]]/}" full
  # 7 位是 git 的短 sha 下限；上限 40 位（SHA-1）。纯十六进制且长度在此区间才继续。
  [[ "$raw" =~ ^[0-9a-fA-F]{7,40}$ ]] || return 1
  full=$(git rev-parse --verify --quiet "${raw}^{commit}" 2>/dev/null) || return 1
  [[ -n "$full" ]] || return 1
  printf '%s' "$full"
}

# to 侧提交号的四分类（票 17-fix3 ②③）：初次核对与重查收尾都走这一份，避免「重查完只会说滞后」。
# 结果放**全局**：`st=$(inline_classify_to …)` 那种写法会让函数跑在子 shell 里，规范化后的 sha 传不回来
# （codeup-api.sh 里对 CODEUP_HTTP_CODE 踩过同一个坑），于是 notice 里的提交号渲染成空。
#   INLINE_TO_STATUS = 状态词；INLINE_TO_NORM = 规范化后的全 sha（ok/lag/pushed_known/diverged 时非空）。
#   noid          空 / 全空白 / 不是 sha 形状 —— 没有可核对的提交号
#   pushed_known  是 HEAD 的**后代**（对象已在克隆里，多半是 fetch 时被一起带下来的）⇒ 评审期间有新推送
#   pushed_dark   解析不出、且克隆不是浅的（或加深之后仍解析不出）⇒ 同样是评审期间有新推送
#   unknown_shallow 浅克隆且加深失败 ⇒ 无从判定（既可能是新推送，也可能是 graft 边界之下的旧提交）
#   lag           是 HEAD 的**祖先** ⇒ Codeup 版本列表尚未包含本次提交
#   diverged      两向都不是祖先 ⇒ 历史分叉（force-push / rebase 改写）
# 「后代」这一支不能落到 diverged（票 17-fix3 ③）：同一个「评审期间新推送」事件，浅克隆下对象不在本地、
# 非浅克隆或 fetch 过之后对象在本地，两种情形若给出两种结论，运维会按错误的方向排查。
inline_classify_to() {
  local raw="${1//[[:space:]]/}" head="$2"
  INLINE_TO_NORM=""; INLINE_TO_STATUS=""
  [[ -n "$raw" ]] || { INLINE_TO_STATUS=noid; return 0; }
  if ! INLINE_TO_NORM=$(inline_resolve_commit "$raw"); then
    INLINE_TO_NORM=""
    # 形状就不对（refname/HEAD/@/带非法字符）时按「没有可核对的提交号」处理：把它说成新推送会给出
    # 「等下一轮」这条永远等不到的建议。
    if [[ ! "$raw" =~ ^[0-9a-fA-F]{7,40}$ ]]; then INLINE_TO_STATUS=noid; return 0; fi
    # 形状对但解析不出：**浅克隆上这不足以断言「新推送」**（票 17-fix3 ⑩）——graft 边界之下的旧提交
    # 一样解析不出，而那种情形永远不会自愈（没有新推送去触发下一轮）。所以先加深再判。
    if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
      log "注意：提交 ${raw:0:12} 在本地解析不出，而这是一个浅克隆——先加深再判定（否则 graft 边界之下的旧提交会被误报成「新推送」）"
      git fetch --unshallow --quiet 2>/dev/null || git fetch --deepen 100 --quiet 2>/dev/null || true
      if INLINE_TO_NORM=$(inline_resolve_commit "$raw"); then
        log "加深后解析成功：${INLINE_TO_NORM:0:12}"
      else
        INLINE_TO_NORM=""
        if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
          # 仍是浅克隆（加深失败：网络受限 / 服务端不允许）⇒ 无从判定，不能给任何一种自愈承诺
          INLINE_TO_STATUS=unknown_shallow; return 0
        fi
        INLINE_TO_STATUS=pushed_dark; return 0
      fi
    else
      INLINE_TO_STATUS=pushed_dark; return 0
    fi
  fi
  if [[ "$INLINE_TO_NORM" == "$head" ]]; then INLINE_TO_STATUS=ok; return 0; fi
  if git merge-base --is-ancestor "$INLINE_TO_NORM" "$head" 2>/dev/null; then INLINE_TO_STATUS=lag; return 0; fi
  if git merge-base --is-ancestor "$head" "$INLINE_TO_NORM" 2>/dev/null; then INLINE_TO_STATUS=pushed_known; return 0; fi
  INLINE_TO_STATUS=diverged
}

# 把状态词渲染成 notice + 日志（票 17-fix3 ②：初次与重查收尾共用一套文案）。
# 调用方写成 `inline_bail_to "<状态>" …; return 1`。
inline_bail_to() { # <状态> <to_ps> <to_commit 原值> <head 全 sha>
  local st="$1" ps="$2" raw="$3" head="$4"
  case "$st" in
    noid)
      inline_bail "行内评论未发出：Codeup 版本列表未给出该版本（${ps}）的提交号，无法确认行内评论会绑到本次评审的提交上，下面是完整问题清单。" \
        "警告：版本列表里最新合并源版本（${ps}）没有可用的提交号（空/空白/不是 sha 形状：「${raw:0:20}」）——本次不发任何行内评论（fail-closed，ADR-0005）：绑不上就不能发" ;;
    pushed_dark)
      inline_bail "行内评论未发出：评审期间源分支有新推送（Codeup 侧最新合并源版本是 ${raw:0:12}，本次评审的是 ${head:0:12}），下面是完整问题清单；新推送触发的评审会补上行内评论。" \
        "警告：最新合并源版本的提交（${raw:0:12}）不在本地克隆里——判定为评审期间有新推送，本次不发任何行内评论（fail-closed，ADR-0005）；新推送触发的那次评审会补上" ;;
    pushed_known)
      inline_bail "行内评论未发出：评审期间源分支有新推送（Codeup 侧最新合并源版本是 ${INLINE_TO_NORM:0:12}，本次评审的是 ${head:0:12}），下面是完整问题清单；新推送触发的评审会补上行内评论。" \
        "警告：最新合并源版本的提交（${INLINE_TO_NORM:0:12}）是当前 HEAD（${head:0:12}）的后代（对象已在克隆里）——判定为评审期间有新推送，本次不发任何行内评论（fail-closed，ADR-0005）；新推送触发的那次评审会补上" ;;
    lag)
      inline_bail "行内评论未发出：Codeup 版本列表尚未包含本次提交（${head:0:12}，版本列表滞后），下面是完整问题清单；重跑流水线即可。" \
        "警告：Codeup 版本列表仍未包含本次提交（${head:0:12}），最新合并源版本是它的祖先（${INLINE_TO_NORM:0:12}）——本次不发任何行内评论（fail-closed，ADR-0005）：绑到旧版本上会挂错位置；重跑流水线即可" ;;
    unknown_shallow)
      inline_bail "行内评论未发出：无法确认 Codeup 侧最新合并源版本（${raw:0:12}）与本次评审的提交（${head:0:12}）的关系——构建机上是浅克隆且加深失败，下面是完整问题清单；放开克隆深度后重跑流水线即可。" \
        "警告：最新合并源版本的提交（${raw:0:12}）在浅克隆里解析不出、加深也失败——无从判定成因（可能是新推送，也可能是 graft 边界之下的旧提交），本次不发任何行内评论（fail-closed，ADR-0005）" ;;
    diverged)
      inline_bail "行内评论未发出：Codeup 侧最新合并源版本（${INLINE_TO_NORM:0:12}）与本次评审的提交（${head:0:12}）不在同一条历史上（源分支被改写或强推），下面是完整问题清单；新推送触发的评审会补上行内评论。" \
        "警告：最新合并源版本的提交（${INLINE_TO_NORM:0:12}）与当前 HEAD（${head:0:12}）分属两条历史（force-push？）——本次不发任何行内评论（fail-closed，ADR-0005）" ;;
    *)
      inline_bail "行内评论未发出：版本对核对得到未知状态，下面是完整问题清单。" \
        "警告：版本对核对得到未知状态「${st}」（这是脚本自身的缺陷，请报告）——本次不发任何行内评论（fail-closed）" ;;
  esac
}

# 取一次版本对并分类（票 17-fix3 ⑥：预采样与发布前采样共用这一份）。
# rc 0 = 已分类（INLINE_TO_STATUS / INLINE_TO_NORM 有效）；rc 1 = 查询接口失败；rc 2 = 选不出版本对。
# 版本对本身放进 SAMPLE_* 全局：命令替换会开子 shell，全局传不回来（同 inline_classify_to 的理由）。
inline_sample_pair() { # <head 全 sha>
  local head="$1" pairv
  SAMPLE_FROM_PS=""; SAMPLE_TO_PS=""; SAMPLE_TO_COMMIT=""; SAMPLE_FROM_COMMIT=""
  codeup_list_patchsets "$LOCAL_ID" > "$WORK/patchsets.json" || return 1
  pairv=$(codeup_select_patchset_pair < "$WORK/patchsets.json") || return 2
  SAMPLE_FROM_PS=$(printf '%s' "$pairv" | cut -f1)
  SAMPLE_TO_PS=$(printf '%s' "$pairv" | cut -f2)
  SAMPLE_TO_COMMIT=$(printf '%s' "$pairv" | cut -f3)
  SAMPLE_FROM_COMMIT=$(printf '%s' "$pairv" | cut -f4)
  inline_classify_to "$SAMPLE_TO_COMMIT" "$head"
}

# 滞后重查：按既有退避（CODEUP_RETRY_BACKOFF）重取版本对至多 <max> 次。
# 收尾状态写进 INLINE_END_STATE（四分类之一，或 http / nopair）——调用方按它选 notice（票 17-fix3 ②）。
inline_requery_lag() { # <head 全 sha> <次数上限>
  local head="$1" max="$2" attempt rc waited=0 nap
  INLINE_END_STATE="$INLINE_TO_STATUS"
  # 不用 `seq`（票 17-fix3 ⑭）：那是个未在预检里声明的外部依赖，缺失时 `$(seq …)` 展开为空、
  # 循环一次都不跑，日志却还说「重查至多 N 次」。
  for ((attempt = 1; attempt <= max; attempt++)); do
    # **先查再睡**（票 17-fix3 ⑪）：原先每轮开头先睡，第一次重查白等一个退避，而 codeup_list_patchsets
    # 内部本来就带 3 次重试各自的退避——最坏耗时因此接近 75 秒而不是 ADR 写的 30 秒。
    # 退避只发生在两次尝试之间，且总等待受 INLINE_LAG_BUDGET 约束（超预算就不再等、直接收尾）。
    if [[ "$attempt" -gt 1 ]]; then
      nap=$(( (attempt - 1) * $(_codeup_retry_backoff) ))
      if [[ $((waited + nap)) -gt "$INLINE_LAG_BUDGET" ]]; then
        log "重查：再等 ${nap} 秒会超过总预算 ${INLINE_LAG_BUDGET} 秒（已等 ${waited} 秒），停止重查"
        break
      fi
      [[ "$nap" -gt 0 ]] && sleep "$nap"
      waited=$((waited + nap))
    fi
    rc=0; inline_sample_pair "$head" || rc=$?
    if [[ "$rc" == "1" ]]; then
      INLINE_END_STATE=http
      log "警告：重查 MR 版本列表失败（HTTP ${CODEUP_HTTP_CODE}），第 ${attempt}/${max} 次"
      continue
    fi
    if [[ "$rc" == "2" ]]; then
      INLINE_END_STATE=nopair
      log "警告：重查后仍选不出版本对，第 ${attempt}/${max} 次"
      continue
    fi
    INLINE_END_STATE="$INLINE_TO_STATUS"
    if [[ "$INLINE_TO_STATUS" == "ok" ]]; then
      log "重查命中：版本列表已包含本次提交，改用 to=${SAMPLE_TO_PS}（第 ${attempt}/${max} 次）"
      return 0
    fi
    log "重查第 ${attempt}/${max} 次：最新合并源版本仍不是本次评审的提交（判定：${INLINE_TO_STATUS}）"
  done
  return 0
}

# 接口失败 / 选不出版本对这两种收尾的 notice（两处采样共用）
inline_bail_pair() { # <http|nopair>
  case "$1" in
    http)
      inline_bail "行内评论未发出：查询 MR 版本列表失败（HTTP ${CODEUP_HTTP_CODE}），下面是完整问题清单。" \
        "警告：查询 MR 版本列表失败（HTTP ${CODEUP_HTTP_CODE}）——本次不发任何行内评论（fail-closed）" ;;
    *)
      inline_bail "行内评论未发出：MR 版本列表里选不出「最新合并目标版本 + 最新合并源版本」这一对，下面是完整问题清单。" \
        "警告：选不出行内评论要用的版本对——本次不发任何行内评论（fail-closed）" ;;
  esac
}

# from 侧核对（R8 探针）：两处采样都要走它，所以收成顶层函数（票 17-fix3 ⑤）。
# 结果写 INLINE_FROM_OFFSET（1 = 基准不一致，发布时要在汇总里带一句「行号可能有偏移」）。
# 只打日志、不碰 notice：fail-closed 那条路径一条行内评论都没发，那时把偏移写进汇总只会让读者
# 去找不存在的行内评论。<标签> 用来区分两次采样的日志。
inline_check_from() { # <from_ps> <from_commit> [标签]
  local ps="$1" raw="${2//[[:space:]]/}" tag="${3:-}" norm
  INLINE_FROM_OFFSET=0
  if [[ -z "$raw" ]]; then
    # 去空白之后为空同样走这里：空白串落到下面那条分支会在日志与汇总里渲染出一对空括号
    log "警告：${tag}版本列表里最新合并目标版本（${ps}）没有提交号——P1-14 的探针（MERGE_TARGET 是否仍冻结在 merge-base）本次失效；行号是新文件侧的（P1-02），不影响发布"
    return 0
  fi
  # 先字面比、比不上再规范化（缩写/大写不该触发探针），规范化仍不等或解析不出才算异常
  if [[ "$raw" == "$BASE" ]] || { norm=$(inline_resolve_commit "$raw") && [[ "$norm" == "$BASE" ]]; }; then
    return 0
  fi
  INLINE_FROM_OFFSET=1
  log "警告：${tag}最新合并目标版本的提交（${raw:0:12}）不等于本地 merge-base（${BASE:0:12}）——按 P1-14 的结论 MERGE_TARGET 应冻结在 merge-base，这不该发生；行号是新文件侧的（P1-02），所以这条只留痕、不拒发（ADR-0005）"
}

# --- 预采样：checkout 之后、Kiro 之前先核对一次版本对（票 17-fix3 ⑥，方案 (a)）---
# 为什么：不预采样的话，所有分类/重查/notice 都只能在模型跑完 900 秒之后解释「为什么什么都没发」，
# 而滞后的重查成本只有几秒——把它挪到前面，多数滞后在评审开始前就自愈了。
# 两次采样还把成因从**推断**变成**证明**：checkout 时一致、发布前不一致 = 评审期间确实有新推送；
# checkout 时就不一致且重查后仍不一致 = 滞后或配置错（不是新推送）。
# 采样失败**不**跳过 Kiro（协调者裁定）：评审的价值在问题清单，行内只是增强，跳过会让这条 MR 本轮零评审。
# INLINE_COMMENT=0 时整个跳过，不多打一次 API。
INLINE_PRE_STATUS=""      # "" = 没做预采样（INLINE_COMMENT=0 或还没走到）
INLINE_PRE_TO_PS=""; INLINE_PRE_TO_COMMIT=""; INLINE_PRE_DECIDED=0
inline_presample() {
  local head_full rc=0
  [[ "$INLINE_COMMENT" == "1" ]] || return 0
  head_full=$(git rev-parse HEAD)
  inline_sample_pair "$head_full" || rc=$?
  case "$rc" in
    1) INLINE_PRE_STATUS=http ;;
    2) INLINE_PRE_STATUS=nopair ;;
    *) INLINE_PRE_STATUS="$INLINE_TO_STATUS" ;;
  esac
  INLINE_PRE_TO_PS="$SAMPLE_TO_PS"; INLINE_PRE_TO_COMMIT="$SAMPLE_TO_COMMIT"
  log "行内评论预采样（Kiro 之前）：to=${INLINE_PRE_TO_PS:-?} 提交=${INLINE_PRE_TO_COMMIT:0:12} HEAD=${head_full:0:12} 判定=${INLINE_PRE_STATUS}"
  # from 侧的探针在这里就要打（票 17-fix3 ⑤）：预采样一旦判定绑不上，发布路径会直接 fail-closed、
  # 不再采样，那时探针就永远进不了日志——而「P1-14 的结论失效了」比「推送太频繁」要紧得多。
  [[ "$rc" == "0" ]] && inline_check_from "$SAMPLE_FROM_PS" "$SAMPLE_FROM_COMMIT" "预采样："
  if [[ "$INLINE_PRE_STATUS" == "lag" ]]; then
    log "注意：预采样判定版本列表滞后——最新合并源版本的提交（${INLINE_TO_NORM:0:12}）是当前 HEAD（${head_full:0:12}）的祖先；现在就按退避重查（至多 ${INLINE_LAG_MAX} 次，总等待不超过 ${INLINE_LAG_BUDGET} 秒；此时重查成本是几秒，评审跑完再重查要等一轮模型）"
    inline_requery_lag "$head_full" "$INLINE_LAG_MAX"
    INLINE_PRE_STATUS="$INLINE_END_STATE"
    INLINE_PRE_TO_PS="$SAMPLE_TO_PS"; INLINE_PRE_TO_COMMIT="$SAMPLE_TO_COMMIT"
    log "行内评论预采样（重查后）：判定=${INLINE_PRE_STATUS}"
  fi
  if [[ "$INLINE_PRE_STATUS" != "ok" ]]; then
    # 已经确定绑不上：发布前不必再采样一次（省下那次重查），到时直接按这个成因 fail-closed。
    INLINE_PRE_DECIDED=1
    log "行内评论：预采样已判定本轮发不出行内评论（${INLINE_PRE_STATUS}），评审照常进行、汇总将带完整问题清单；发布前不再重查"
  fi
  return 0
}

publish_inline_comments() {
  local validated="$1"
  local pair from_ps to_ps to_commit from_commit head_full existing_rg draft_rg config_notice
  # INLINE_TO_NORM / INLINE_TO_STATUS / INLINE_FROM_OFFSET 都是全局（函数间共享，命令替换会丢）
  local item idx file ls le title fp cid crc ocid hits hrc n_created=0 n_existing=0 n_failed=0 submitted=0

  # 2/3/4. 变更行集合 → 可定位判定 → 排序与档位 → 上限截取。
  # 排在版本对之前：规划完全是本地计算，而「没有任何要发的行内评论」时（干净的 MR、
  # 或者所有问题都不可定位）根本不该去调那两个接口，更不该因为接口失败而在一条
  # 「未发现明显问题」的汇总上挂一句「下面是完整问题清单」。
  if ! review_plan_inline --json "$validated" --changed-lines "$WORK/changed-lines.json" \
         --profile "$INLINE_PROFILE" --max "$MAX_INLINE_COMMENTS" > "$WORK/plan.json"; then
    inline_bail "行内评论未发出：生成行内发布计划失败，下面是完整问题清单。" "警告：生成行内发布计划失败" || return 1  # fail-closed:plan
  fi
  # 档位/上限被回落时的说明要上到汇总评论：流水线日志阿里云侧看不到（I10）
  config_notice=$(jq -r '.config_notice // ""' "$WORK/plan.json")
  [[ -n "$config_notice" ]] && INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }${config_notice}"
  if [[ "$(jq -r '.inline | length' "$WORK/plan.json")" == "0" ]]; then
    log "行内评论：本次没有可发的行内评论（可定位且档位覆盖的问题为 0），跳过版本查询与发布；折叠区 $(jq -r '.folded_count' "$WORK/plan.json") 条"
    INLINE_ACTIVE=1
    return 0
  fi

  # 1. 版本对（spec §4.5 第 1 步、Q6）
  head_full=$(git rev-parse HEAD)
  # 预采样已经判定「绑不上」时不再多打一次接口（票 17-fix3 ⑥）：成因在 Kiro 之前就确定了，
  # 而且那时已经按退避重查过——发布前再查一次只会多一次 API 调用与一段重复日志。
  if [[ "$INLINE_PRE_DECIDED" == "1" ]]; then
    log "行内评论：沿用预采样的判定（${INLINE_PRE_STATUS}），不再重查版本列表"
    # 两支都只负责「说明原因」，rc 由 case 之后那一行统一给：写成每支各自 return 的话，漏一支就变成
    # 「说明了原因却继续往下发」，而端到端只看最终结果、照样绿（票 17-fix3 ⑬ 的同一条教训）。
    case "$INLINE_PRE_STATUS" in
      http|nopair) inline_bail_pair "$INLINE_PRE_STATUS" ;;
      *) inline_bail_to "$INLINE_PRE_STATUS" "$INLINE_PRE_TO_PS" "$INLINE_PRE_TO_COMMIT" "$head_full" ;;
    esac
    return 1  # fail-closed:pre
  fi
  local rc=0
  inline_sample_pair "$head_full" || rc=$?
  if [[ "$rc" == "1" ]]; then inline_bail_pair http || return 1; fi   # fail-closed:pair-http
  if [[ "$rc" == "2" ]]; then inline_bail_pair nopair || return 1; fi  # fail-closed:pair-nopair
  from_ps="$SAMPLE_FROM_PS"; to_ps="$SAMPLE_TO_PS"
  to_commit="$SAMPLE_TO_COMMIT"; from_commit="$SAMPLE_FROM_COMMIT"
  log "行内评论版本对：from=${from_ps}（最新合并目标版本）→ to=${to_ps}（最新合并源版本，patchset_biz_id 用它）"
  # --- to 侧 / from 侧的版本核对（ADR-0005：行内评论只绑定它所评审的那个提交）---
  # 依据都在 docs/adr/0005-inline-comments-bind-to-reviewed-commit.md：为什么 to 侧绑不上就不发、
  # 各种成因怎么处置、为什么 from 侧只留痕（P1-02 行号是新文件侧的、P1-14 目标版本冻结在 merge-base）。
  # 判定全部在草稿创建之前、也在拉现有行内评论（第 5 步）之前：除了版本列表查询，不留任何副作用。
  #
  # from 侧先打日志（探针不能被 to 侧的 fail-closed 吞掉）：两者同时异常时运维只看到「推送太频繁」，
  # 就查不到「P1-14 的结论失效了」这件更要紧的事。
  inline_check_from "$from_ps" "$from_commit"

  # to 侧：四分类（inline_classify_to 已在 inline_sample_pair 里跑过）。只有 ok 才继续发布。
  local to_status="$INLINE_TO_STATUS"
  # 两次采样比对（票 17-fix3 ⑥）：预采样一致、发布前不一致 ⇒ 成因是**评审期间的新推送**，这是证明而不是
  # 靠 git 拓扑推断；两次都不一致（且中间重查过）⇒ 滞后或配置错。结论只进日志，notice 仍按最终成因写。
  if [[ -n "$INLINE_PRE_STATUS" && "$to_status" != "ok" ]]; then
    log "两次采样：checkout 时判定=${INLINE_PRE_STATUS}（to=${INLINE_PRE_TO_PS:-?}）、发布前判定=${to_status}（to=${to_ps}）$([[ "$INLINE_PRE_STATUS" == "ok" ]] && printf '%s' " ⇒ 评审期间源分支确实有新推送（两次采样即证据）" || printf '%s' " ⇒ 与评审期间的推送无关")"
  fi
  if [[ "$to_status" == "lag" ]]; then
    log "注意：最新合并源版本的提交（${INLINE_TO_NORM:0:12}）是当前 HEAD（${head_full:0:12}）的祖先——Codeup 版本列表可能尚未包含本次提交，按退避重查（至多 ${INLINE_LAG_MAX} 次，总等待不超过 ${INLINE_LAG_BUDGET} 秒）"
    inline_requery_lag "$head_full" "$INLINE_LAG_MAX"
    to_status="$INLINE_TO_STATUS"
    from_ps="$SAMPLE_FROM_PS"; to_ps="$SAMPLE_TO_PS"
    to_commit="$SAMPLE_TO_COMMIT"; from_commit="$SAMPLE_FROM_COMMIT"
    # 收尾必须**重新分类**（票 17-fix3 ②）：重查期间可能来了新推送、可能返回空 commitId、可能接口失败或
    # 选不出版本对。全部说成「滞后，重跑流水线即可」是错的——重跑在同一份陈旧 checkout 上只会复现。
    if [[ "$INLINE_END_STATE" != "ok" ]]; then
      case "$INLINE_END_STATE" in
        http|nopair) inline_bail_pair "$INLINE_END_STATE" ;;
        *) inline_bail_to "$INLINE_END_STATE" "$to_ps" "$to_commit" "$head_full" ;;
      esac
      return 1  # fail-closed:lag-end
    fi
    inline_check_from "$from_ps" "$from_commit"   # 重查换了版本对，探针按新值重走一遍
  fi
  if [[ "$to_status" != "ok" ]]; then
    inline_bail_to "$to_status" "$to_ps" "$to_commit" "$head_full" || return 1  # fail-closed:to
  fi
  # from 侧的 notice 留到这里（警告已在上面打过）：它说的是「**发出去的**行内评论的行号可能有偏移」，
  # 而 fail-closed 那条路径一条都没发，那时写进汇总只会让读者去找不存在的行内评论。
  if [[ "$INLINE_FROM_OFFSET" == "1" ]]; then
    INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }注意：行内评论的行号可能有偏移——Codeup 侧的比较基准（合并目标版本 ${from_commit:0:12}）与本次 diff 的基准（merge-base ${BASE:0:12}）不一致。"
  fi

  # 5. 去重：拉现有行内评论，按「同文件、行区间重叠或相邻」跳过（实测澄清 2026-09-03）
  #    spec Q8 的「文件+行+标题」指纹在真实重跑里全部不命中（标题措辞全变、行号漂移 1 行、一条拆成两条），
  #    行内评论 4 → 9。改为区间匹配：候选 = 本机器人、未过期、非草稿/删除的行内评论；
  #    命中 = 同一文件且区间重叠或相距 ≤ REVIEW_INLINE_DEDUP_TOLERANCE 行，且已有评论的级别不低于新问题
  #    （一条旧 P2 不能压掉重跑时新出现的 P0）。标题不再参与判定。
  existing_rg="$WORK/existing-ranges.json"
  draft_rg="$WORK/draft-ranges.json"
  echo '[]' > "$existing_rg"; echo '[]' > "$draft_rg"
  if [[ -z "${BOT_USERNAME:-}" ]]; then
    log "警告：未配置 CODEUP_BOT_USERNAME（令牌身份接口也不可用——P1-00 实测 403），行内评论去重无法按作者过滤，只能按评论正文里的隐藏标记识别本评审员的评论。重跑仍不会重复，**但任何 MR 参与者只要在同一处贴一条带同样标记的评论，就能压制掉对应那条问题（连 P0 也发不出去）**。强烈建议配置该变量"
  fi
  if codeup_list_inline_comments "$LOCAL_ID" > "$WORK/inline-comments.json"; then
    review_inline_existing_ranges "${BOT_USERNAME:-}" < "$WORK/inline-comments.json" > "$existing_rg" \
      || echo '[]' > "$existing_rg"
    review_inline_draft_ranges "${BOT_USERNAME:-}" < "$WORK/inline-comments.json" > "$draft_rg" \
      || echo '[]' > "$draft_rg"
    log "行内评论去重：MR 上已有 $(jq -r 'length' "$existing_rg" 2>/dev/null || echo 0) 条本评审员的未过期行内评论、$(jq -r 'length' "$draft_rg" 2>/dev/null || echo 0) 条残留草稿；判定 = 同文件且行区间重叠或相距 ≤ ${REVIEW_INLINE_DEDUP_TOLERANCE} 行、已有评论级别不低于新问题"
  else
    log "警告：查询 MR 现有行内评论失败（HTTP ${CODEUP_HTTP_CODE}），本次跳过去重（重跑可能在同一行上留下重复评论）"
  fi

  # 6.0 先把每条问题的指纹算出来（一条 jq 取三个字段，用换行分隔——file 与 title 都不可能含换行：
  #     review_validate 拒掉了 file 里的换行，title 又被折叠成单行）。
  #     指纹不再参与去重判定，只写进标记供人工核对；算不出来仍按失败处理——标记没有指纹就
  #     没法把「本评审员发的」与人工评论区分开。
  : > "$WORK/fps.tsv"; : > "$WORK/outcomes.jsonl"
  while IFS= read -r item; do
    idx=$(printf '%s' "$item" | jq -r '.idx')
    # 每条问题的 JSON 单独落盘并按 idx 命名：回退发布那一轮要再读一次它的 file/line_start，
    # 而**不能**把路径塞进制表符分隔的中间文件——文件名里允许出现制表符（review_validate 只挡了
    # 换行/回车/竖线/反引号），那样一条带制表符的路径会让字段错位、把评论发到别的位置上。
    printf '%s' "$item" > "$WORK/item-${idx}.json"
    { read -r ls; read -r file; read -r title; } < <(jq -r '.line_start, .file, .title' "$WORK/item-${idx}.json")
    if ! fp=$(review_fingerprint "$file" "$ls" "$title"); then
      log "警告：算不出问题 #${idx} 的指纹，转入折叠区（标记里没有指纹，下次评审无法把它认成本评审员发的）"
      printf '{"idx":%s,"outcome":"failed"}\n' "$idx" >> "$WORK/outcomes.jsonl"; n_failed=$((n_failed + 1)); continue
    fi
    printf '%s\t%s\n' "$idx" "$fp" >> "$WORK/fps.tsv"
  done < <(jq -c '.inline[]' "$WORK/plan.json")

  # 6.1 清理孤儿草稿：本次要发的问题里，如果某条的草稿还留在 MR 上（上一次运行断在了
  #     「建好草稿」与「一次提交」之间），必须先删掉再建。不删就会在同一行上留两份，
  #     而旧那条草稿只有机器人自己看得见、永远提交不了（提交要带 id 列表，那个列表随上次运行没了）。
  #     id 本身是拿得到的——就在 draft_rg 里（review_inline_draft_ranges 会列出 .id），下面就是按它删的。
  #     刻意按**指纹精确匹配**而不是按区间：同一 MR 上可能有另一次运行正在进行中，按区间会把它
  #     刚建好的草稿删掉、让它那条问题被迫进折叠区；按指纹只在同一模型输出重放时命中，命不中的
  #     孤儿草稿只有机器人自己看得见、无害。只删对得上的那些，不动别的草稿。
  #     指纹含标题，而模型每次措辞都不同，所以重跑时这条清理**实际上几乎不命中**（真实验收 MR #2
  #     运行 #18/#21 都没命中过）：它只挡「同一次模型输出被重放」这一种情况。真正的并发安全要靠
  #     草稿带执行归属标识（Phase 2，spec I6）＋ 流水线并发运行实例数 = 1（setup-guide 第 4 节第 4 步）。
  if [[ "$(jq -r 'length' "$draft_rg" 2>/dev/null || echo 0)" != "0" ]]; then
    while IFS=$'\t' read -r idx fp; do
      while IFS= read -r ocid; do
        [[ -n "$ocid" ]] || continue
        log "清理：MR 上有一条本次要发的问题 #${idx} 的残留草稿（${ocid}，上次运行未完成提交），先删除再重发"
        codeup_delete_comment "$LOCAL_ID" "$ocid" \
          || log "警告：删除残留草稿 ${ocid} 失败（HTTP ${CODEUP_HTTP_CODE}），本次仍会新建一条，那条残留需人工清理"
      done < <(jq -r --arg fp "$fp" '.[] | select(.fp == $fp) | .id' "$draft_rg" 2>/dev/null || true)
    done < "$WORK/fps.tsv"
  fi

  # 6.2 逐条创建草稿
  : > "$WORK/draft-ids.txt"; : > "$WORK/drafted.tsv"
  while IFS=$'\t' read -r idx fp; do
    { read -r ls; read -r le; read -r file; read -r sev; } < <(jq -r '.line_start, .line_end, .file, .severity' "$WORK/item-${idx}.json")
    # 去重判定：rc 0 命中 → 同一处已有一条级别不低于它的评论，算「已标注」而不是折叠区（否则同一条问题在 MR 上出现两次，I4）；
    # rc 1 未命中 → 照常发；rc 2 参数/文件错误 → 打警告后照常发（宁可重复，绝不因为一个坏文件吞掉一条 P0）
    hrc=0; hits=$(review_inline_overlaps "$existing_rg" "$file" "$ls" "$le" "$sev") || hrc=$?
    if [[ "$hrc" == "0" ]]; then
      # file 是模型控制的取值（fpath 只拒空/禁用字符/控制字符）：它不在字段级掩码清单里（要与变更文件集合逐字比对，
      # 掩了就定位不到），只在这个日志出口掩（第 25 条）
      log "去重：问题 #${idx}（${sev} $(_untrusted_for_log "$file") L${ls}$([[ "$le" =~ ^[0-9]+$ && "$le" != "$ls" ]] && printf -- '–L%s' "$le")）与已有行内评论 $(printf '%s' "$hits" | tr '\n' ',') 同文件且行区间重叠/相邻、级别不低于它，视为同一问题，跳过"
      printf '{"idx":%s,"outcome":"existing"}\n' "$idx" >> "$WORK/outcomes.jsonl"; n_existing=$((n_existing + 1)); continue
    elif [[ "$hrc" != "1" ]]; then
      log "警告：问题 #${idx} 的去重判定出错（rc=${hrc}），本条按未重复处理照常发出（可能与已有评论重复）"
    fi
    # 渲染成功后立刻过文档级兜底掩码（票 16 / 16-fix2 方案 C）：title/body/fix 已在 validated.json 字段级掩过，这一遍
    # 兜住绕过 validated.json 的文本、严格保行。这份 body-<idx>.md 是草稿创建与「一次提交失败退回逐条发布」两条路径
    # 共用的唯一正文文件（回退路径不重新渲染），掩一次即可。掩码失败按渲染失败处理 → 该条进折叠区（不发出）。
    if ! review_render_inline_body "$WORK/item-${idx}.json" "$SHORT_SHA" "$fp" > "$WORK/body-${idx}.md" \
       || ! review_redact_file "$WORK/body-${idx}.md"; then
      log "警告：问题 #${idx} 的行内评论正文渲染或掩码失败，转入折叠区"
      printf '{"idx":%s,"outcome":"failed"}\n' "$idx" >> "$WORK/outcomes.jsonl"; n_failed=$((n_failed + 1)); continue
    fi
    # 行内正文没有截断逻辑（review_truncate_comment 只用于汇总）：字段上限让它正常情况下落在评论上限之内，但清洗 / 掩码的
    # 膨胀不是零，这里加硬守卫——超过 MAX_COMMENT_BYTES 的正文不发（Codeup 会 4xx），按 failed 进折叠区（第 7 条）。
    local body_bytes
    body_bytes=$(wc -c < "$WORK/body-${idx}.md" | tr -d ' ') || body_bytes=""
    if ! [[ "$body_bytes" =~ ^[0-9]+$ ]] || [[ "$body_bytes" -gt "$MAX_COMMENT_BYTES" ]]; then   # 量不出字节数按超限处理（第 30 条）
      log "警告：问题 #${idx} 的行内评论正文 ${body_bytes} 字节超过 MAX_COMMENT_BYTES=${MAX_COMMENT_BYTES}，转入折叠区（只展示标题）"
      # 记下原因与字节数（第 38 条）：折叠区的「行内发布失败」桶默认渲染 body + fix 全文，超大正文照搬进汇总只会让汇总也超限、
      # 把其它问题的文本一起截掉；带 reason=oversize 的条目只渲染标题 + 一句说明
      printf '{"idx":%s,"outcome":"failed","reason":"oversize","bytes":%s,"limit":%s}\n' "$idx" "$([[ "$body_bytes" =~ ^[0-9]+$ ]] && printf '%s' "$body_bytes" || printf 0)" "$MAX_COMMENT_BYTES" >> "$WORK/outcomes.jsonl"
      n_failed=$((n_failed + 1)); continue
    fi
    # 必须用文件式接口而不是 `cid=$(codeup_create_inline_comment …)`：命令替换在子 shell 里跑，
    # CODEUP_HTTP_CODE 与 DRY_RUN 的 fixture 序号都传不回来（codeup-api.sh 里写明了这条约定）
    if codeup_create_inline_comment "$LOCAL_ID" "$WORK/body-${idx}.md" "$file" "$ls" \
         "$from_ps" "$to_ps" true "$WORK/created.json"; then
      cid=$(codeup_comment_biz_id "$WORK/created.json")
      if [[ -n "$cid" ]]; then
        printf '%s\n' "$cid" >> "$WORK/draft-ids.txt"
        # 只记 idx 与草稿 id（两者都不可能含制表符）；file/line 回退时从 item-<idx>.json 再读
        printf '%s\t%s\n' "$idx" "$cid" >> "$WORK/drafted.tsv"
      else
        log "警告：问题 #${idx} 的草稿建好了但响应里没有 comment_biz_id，无法纳入一次提交，转入折叠区（那条草稿只有机器人自己看得见；下次评审会按指纹认出它并先删掉）"
        printf '{"idx":%s,"outcome":"failed"}\n' "$idx" >> "$WORK/outcomes.jsonl"; n_failed=$((n_failed + 1))
      fi
    else
      # rc 2 = 本地前置校验拒绝（正文为空、行号不合法……），一个请求都没发过，此时
      # CODEUP_HTTP_CODE 是上一次别的请求留下的旧值（通常 200）。把它当成 HTTP 结果打出来，
      # 会让运维照着一个不存在的接口问题去排查。
      crc=$?
      if [[ "$crc" == "2" ]]; then
        log "警告：问题 #${idx} 的行内评论被本地前置校验拒绝（参数不合规，原因见上一行；未发出任何请求），转入折叠区"
      else
        log "警告：问题 #${idx} 的行内评论草稿创建失败（HTTP ${CODEUP_HTTP_CODE}；创建不幂等，000/5xx 一律不重试），转入折叠区，下次评审会重发"
      fi
      printf '{"idx":%s,"outcome":"failed"}\n' "$idx" >> "$WORK/outcomes.jsonl"; n_failed=$((n_failed + 1))
    fi
  done < "$WORK/fps.tsv"

  # 7. 一次提交（不带 reviewOpinion）；失败则退回逐条非草稿发布
  if [[ -s "$WORK/draft-ids.txt" ]]; then
    if codeup_submit_drafts "$LOCAL_ID" "$WORK/draft-ids.txt"; then
      submitted=1
      log "行内评论：$(grep -c . "$WORK/draft-ids.txt" || true) 条草稿已一次提交（不带评审意见，不卡合并）"
    else
      log "警告：草稿一次提交失败（HTTP ${CODEUP_HTTP_CODE}），退回逐条非草稿发布"
      # 先删掉已建的草稿：不删的话同一条问题会同时留下一条草稿（只有机器人自己看得见）
      # 与一条正式评论，而下一次评审会把公开那条认成「已存在」跳过，草稿则再也没人清理
      while IFS=$'\t' read -r idx cid; do
        codeup_delete_comment "$LOCAL_ID" "$cid" \
          || log "警告：删除草稿 ${cid} 失败（rc=$?，HTTP ${CODEUP_HTTP_CODE}），需人工清理该草稿"
      done < "$WORK/drafted.tsv"
      while IFS=$'\t' read -r idx cid; do
        { read -r ls; read -r file; } < <(jq -r '.line_start, .file' "$WORK/item-${idx}.json")
        if codeup_create_inline_comment "$LOCAL_ID" "$WORK/body-${idx}.md" "$file" "$ls" \
             "$from_ps" "$to_ps" false "$WORK/created.json"; then
          n_created=$((n_created + 1)); printf '{"idx":%s,"outcome":"created"}\n' "$idx" >> "$WORK/outcomes.jsonl"
        else
          crc=$?
          if [[ "$crc" == "2" ]]; then
            log "警告：问题 #${idx} 的非草稿回退发布被本地前置校验拒绝（未发出任何请求），转入折叠区"
          else
            log "警告：问题 #${idx} 的非草稿回退发布也失败（HTTP ${CODEUP_HTTP_CODE}），转入折叠区"
          fi
          n_failed=$((n_failed + 1)); printf '{"idx":%s,"outcome":"failed"}\n' "$idx" >> "$WORK/outcomes.jsonl"
        fi
      done < "$WORK/drafted.tsv"
    fi
  fi
  # 7.1 提交成功后必须回读（R6）：2xx 只说明请求被受理，**不保证每个 id 都真的转成了 OPENED**。
  # 服务端拒掉其中一个（版本过期、超上限）时那条仍是草稿——只有机器人自己看得见，而汇总却会
  # 报「已标注在对应行」，下次重跑还会再发一条。回读不到就全部按发布失败处理（fail-closed，
  # 与 review_plan_apply_outcomes 的兜底方向一致）：宁可在折叠区重复一次，绝不藏起一条 P0。
  if [[ "$submitted" == "1" ]]; then
    if codeup_list_inline_comments "$LOCAL_ID" > "$WORK/inline-after.json"; then
      review_inline_draft_ranges "${BOT_USERNAME:-}" < "$WORK/inline-after.json" | jq -r '.[].id' \
        > "$WORK/still-draft.txt" || : > "$WORK/still-draft.txt"
      while IFS=$'\t' read -r idx cid; do
        if grep -qxF "$cid" "$WORK/still-draft.txt"; then
          log "警告：草稿 ${cid}（问题 #${idx}）在一次提交返回 2xx 之后仍是草稿——服务端应是拒掉了这个 id。删除该草稿并转入折叠区"
          codeup_delete_comment "$LOCAL_ID" "$cid" \
            || log "警告：删除仍为草稿的 ${cid} 失败（HTTP ${CODEUP_HTTP_CODE}），需人工清理"
          n_failed=$((n_failed + 1)); printf '{"idx":%s,"outcome":"failed"}\n' "$idx" >> "$WORK/outcomes.jsonl"
        else
          n_created=$((n_created + 1)); printf '{"idx":%s,"outcome":"created"}\n' "$idx" >> "$WORK/outcomes.jsonl"
        fi
      done < "$WORK/drafted.tsv"
    else
      log "警告：提交后回读行内评论列表失败（HTTP ${CODEUP_HTTP_CODE}），无法确认草稿是否都已转为公开评论——全部按发布失败处理（问题会在折叠区完整列出，可能与已发出的行内评论重复）"
      while IFS=$'\t' read -r idx cid; do
        n_failed=$((n_failed + 1)); printf '{"idx":%s,"outcome":"failed"}\n' "$idx" >> "$WORK/outcomes.jsonl"
      done < "$WORK/drafted.tsv"
    fi
  fi

  # 发布结果回填：发失败的问题必须落到折叠区，否则它在 MR 上一条都看不到。
  # 结果直接就是 JSON 行（不再经 TSV 再解析）：少一道容易出错的转换。
  if ! jq -s '.' "$WORK/outcomes.jsonl" > "$WORK/outcomes.json"; then
    INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }行内评论已发出，但发布结果的统计口径算不出来，因此下面仍给出完整问题清单（可能与行内评论重复）。"
    log "警告：发布结果文件解析失败，回落成完整问题清单"
    return 1
  fi
  if ! review_plan_apply_outcomes "$WORK/plan.json" "$WORK/outcomes.json" > "$WORK/plan.final.json"; then
    # 回填算不出来时不能拿未回填的计划去渲染：那会把发失败的问题算成「已标注在对应行」而彻底藏起来。
    # 回落到完整清单：已经发出去的行内评论会与清单里的条目重复一次，但没有任何问题被藏起来。
    INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }行内评论已发出，但统计口径回填失败，因此下面仍给出完整问题清单（可能与行内评论重复）。"
    log "警告：发布结果回填失败，回落成完整问题清单"
    return 1
  fi
  # 这一步也必须判退出码：本函数跑在 `if` 条件里，errexit 不生效，mv 失败会让后面拿**未回填**的
  # 计划去渲染——那正是 M29 要抓的缺陷（发失败的问题被算成「已标注」而从 MR 上消失）。
  if ! mv "$WORK/plan.final.json" "$WORK/plan.json"; then
    INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }行内评论已发出，但发布结果的统计口径写不回去，因此下面仍给出完整问题清单（可能与行内评论重复）。"
    log "警告：回填后的计划文件落盘失败，回落成完整问题清单"
    return 1
  fi
  log "行内评论：新发 ${n_created} 条、已存在跳过 ${n_existing} 条（同一处已有本评审员的行内评论，计入「已标注」）、失败 ${n_failed} 条；折叠区 $(jq -r '.folded_count' "$WORK/plan.json") 条（档位 $(jq -r '.inline_profile' "$WORK/plan.json")，上限 $(jq -r '.max_inline' "$WORK/plan.json")）"
  INLINE_ACTIVE=1
  return 0
}

# --- 0. 依赖与必填变量检查（timeout 为强制依赖，不允许无超时运行）---
for cmd in git curl jq; do
  command -v "$cmd" >/dev/null || die "缺少依赖：${cmd}（请在构建机安装）"
done
TIMEOUT_BIN=""
command -v timeout >/dev/null && TIMEOUT_BIN=timeout
[[ -z "$TIMEOUT_BIN" ]] && command -v gtimeout >/dev/null && TIMEOUT_BIN=gtimeout
[[ -n "$TIMEOUT_BIN" ]] || die "缺少依赖：timeout/gtimeout（GNU coreutils）。无超时能力时 Kiro 挂起会永久占用流水线，拒绝运行"
: "${KIRO_API_KEY:?缺少 KIRO_API_KEY}"
: "${YUNXIAO_TOKEN:?缺少 YUNXIAO_TOKEN}"
: "${YUNXIAO_ORG_ID:?缺少 YUNXIAO_ORG_ID}"
: "${CODEUP_REPO_ID:?缺少 CODEUP_REPO_ID}"
REVIEW_REPO_DIR=$(cd "$REVIEW_REPO_DIR" >/dev/null 2>&1 && pwd -P) || die "REVIEW_REPO_DIR 不存在或不可进入：${REVIEW_REPO_DIR}"
# 第 5.5 步会删掉业务库工作树里的 AGENTS.md/.kiro/lsp.json，而 DRY_RUN 并不拦删除：
# 本地把集成包自身（或它的上级目录）误当业务库跑，会把集成包自己的文件删掉，直接拒绝。
[[ "$PKG_ROOT" != "$REVIEW_REPO_DIR" && "$PKG_ROOT" != "$REVIEW_REPO_DIR"/* && "$REVIEW_REPO_DIR" != "$PKG_ROOT"/* ]] \
  || die "REVIEW_REPO_DIR（${REVIEW_REPO_DIR}）与集成包（${PKG_ROOT}）互相包含，拒绝运行：隔离步骤会删除集成包内的文件"
[[ -d "$REVIEW_REPO_DIR/.git" ]] || die "REVIEW_REPO_DIR 不是 git 仓库：$REVIEW_REPO_DIR"
[[ -r "$PROMPT_FILE" ]] || die "评审提示词文件不可读：$PROMPT_FILE"
[[ -r "$AGENT_FILE" ]] || die "custom agent 配置文件不可读：$AGENT_FILE"

cd "$REVIEW_REPO_DIR"

# --- 1. 定位 MR（放在最前面：此后任何失败都能回写「评审未完成」评论，spec I10 失败可见。
#        定位只需要 git 与 Codeup OpenAPI，不需要 kiro-cli，所以安装排在它后面）---
SOURCE_BRANCH="${CI_COMMIT_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
if [[ -n "${MR_LOCAL_ID:-}" && -n "${MR_TARGET_BRANCH:-}" ]]; then
  LOCAL_ID="$MR_LOCAL_ID"; TARGET_BRANCH="$MR_TARGET_BRANCH"
  log "使用环境变量指定的 MR：#${LOCAL_ID}（${SOURCE_BRANCH} → ${TARGET_BRANCH}）"
else
  log "环境变量未提供 MR 信息，按源分支 ${SOURCE_BRANCH} 反查 OpenAPI……"
  mr_rc=0; mr_out=$(codeup_find_mr "$SOURCE_BRANCH") || mr_rc=$?
  case "$mr_rc" in
    0) LOCAL_ID=$(printf '%s' "$mr_out" | cut -f1)
       TARGET_BRANCH=$(printf '%s' "$mr_out" | cut -f2)
       log "反查到唯一 MR：#${LOCAL_ID}（${SOURCE_BRANCH} → ${TARGET_BRANCH}）" ;;
    3) log "同源分支存在多个打开的 MR，无法自动判定："
       printf '%s\n' "$mr_out" >&2
       die "MR 定位歧义。请在流水线变量中显式配置 MR_LOCAL_ID 与 MR_TARGET_BRANCH" ;;
    *) die "无法定位 MR（源分支 ${SOURCE_BRANCH}）。请确认 MR 处于开启状态，或显式配置 MR_LOCAL_ID/MR_TARGET_BRANCH" ;;
  esac
fi
SHORT_SHA=$(git rev-parse --short HEAD)
MR_LOCATED=1
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# --- 1.5 定位本评审员上一次的汇总评论（spec §4.5 第 8 步、I4；票 03）---
# 放在这里而不是「发评论前」：此后任何失败都要能带着正确的 run 号与历次记录去更新**同一条**评论，
# 否则每次失败都会在 MR 上新增一条汇总。任一步失败只降级为「按新建处理」，绝不因此中断评审。
# 机器人账号用户名是原地更新的**前置条件**：只接受显式配置或令牌身份接口两个来源。
# 取不到就一律新建——「按带评审标记的评论作者推断」会让任何 MR 参与者用一条带标记的评论
# 把本评审员的报告引到他自己那条评论上（见 review_select_prior_comment 的说明）。
if BOT_USERNAME=$(codeup_bot_username); then
  log "机器人账号用户名：${BOT_USERNAME}"
else
  BOT_USERNAME=""
  log "未取得机器人账号用户名（CODEUP_BOT_USERNAME 未配置，令牌身份接口也不可用——P1-00 实测 403）：本次只能新建汇总评论，不做原地更新"
fi
if codeup_list_global_comments "$LOCAL_ID" > "$WORK/comments.json"; then
  sel_rc=0
  review_select_prior_comment "$BOT_USERNAME" < "$WORK/comments.json" > "$WORK/prior.json" || sel_rc=$?
  case "$sel_rc" in
    0) PRIOR_COMMENT_ID=$(jq -r '.comment_biz_id // ""' "$WORK/prior.json")
       prior_run=$(jq -r '.run // 1' "$WORK/prior.json")
       if [[ -z "$PRIOR_COMMENT_ID" ]]; then
         log "警告：旧汇总评论没有 comment_biz_id，无法原地更新，本次按新建处理"
       else
         jq -r '.content // ""' "$WORK/prior.json" > "$WORK/prior.md"
         PRIOR_HISTORY_FILE="$WORK/prior-history.json"
         review_parse_history "$WORK/prior.md" > "$PRIOR_HISTORY_FILE"
         REVIEW_RUN=$((prior_run + 1))
         log "找到本评审员的旧汇总评论 ${PRIOR_COMMENT_ID}（上次为第 ${prior_run} 次评审，读回历次记录 $(jq -r 'length' "$PRIOR_HISTORY_FILE") 行），本次原地更新为第 ${REVIEW_RUN} 次"
       fi ;;
    3) log "未配置 CODEUP_BOT_USERNAME，本次新建汇总评论（见上一行：新建后日志会打出评论的作者用户名，配置该变量即可启用原地更新）" ;;
    *) log "未找到本评审员的旧汇总评论，本次新建（第 ${REVIEW_RUN} 次评审）" ;;
  esac
else
  log "警告：查询 MR 全局评论失败，本次按新建处理（可能在 MR 上留下第二条汇总）"
fi

# --- 1.6 流水线变量的取值校验（紧跟 MR 定位：失败要在 MR 上看得见，I10）---
# 放在安装 kiro-cli **之前**：这些错都是一眼可辨的配置错误，不该先花最多 300 秒装 CLI、
# 再花 60 秒跑一次 --help 才失败。
[[ "$INLINE_COMMENT" == "0" || "$INLINE_COMMENT" == "1" ]] \
  || die_review "INLINE_COMMENT=${INLINE_COMMENT} 不是 0 或 1。行内评论开关只接受这两个取值（静默按 0 跑会让开关看起来生效了）。请修正该流水线变量"
# 两个「秒数/字节数」变量只接受纯数字。口径统一为纯数字的理由：
#   DIFF_SIZE_LIMIT=300KB → 与字节数比较时是 bash 算术错误、取假，于是**整份 diff 都进省略清单**
#                       （评审员只拿到一份索引），而评论里的说明还会写成「超出阈值（300KBB）」；
#   KIRO_TIMEOUT=15m  → GNU timeout **本身认**这个后缀（15 分钟），所以它不会报错，但脚本的日志会
#                       写成「超时 15ms」这种误导文案，而 `-k 30` 之外的语义也不再一眼可读。
#                       与其让两个变量一个认后缀一个不认，统一只收秒数/字节数。
#                       **这是行为变更**：之前 `KIRO_TIMEOUT=15m` 能跑通，升级后会被拒绝并要求改成 900。
# 与 MAX_COMMENT_BYTES 的处理不同（那个回落默认值）：截断阈值配错只影响评论长度，而这两个直接
# 决定「评审有没有真的看到代码」「会不会白跑一次额度」，宁可失败并说清楚。
# 先按十进制归一化（`10#`）再比较：带前导零的 `0900` 是纯数字、意图明确，但直接拿去做 `-ge 1`
# 会被 bash 当八进制解析并报「value too great for base」——那行报错既噪声又误导。
for _v in KIRO_TIMEOUT DIFF_SIZE_LIMIT; do
  [[ "${!_v}" =~ ^[0-9]+$ ]] \
    || die_review "${_v}=${!_v} 不是纯数字（KIRO_TIMEOUT 单位是秒、DIFF_SIZE_LIMIT 单位是字节，例如 900 与 307200；不支持 15m / 300KB 这类带单位的写法）。请修正该流水线变量"
  eval "${_v}=\$(( 10#\${${_v}} ))"
  [[ "${!_v}" -ge 1 ]] \
    || die_review "${_v}=0 不合法（必须 ≥1；0 会让超时形同不限时、让 diff 阈值变成「全部省略」）。请修正该流水线变量"
done
unset _v
# KIRO_ENV_PASSTHROUGH 只收变量名：非法名字（写成 NAME=value、带空格/连字符）与凭证形状的名字（规则表 KIRO_ENV_CRED_RULES，
# AWS_PROFILE / AWS_REGION / AWS_DEFAULT_REGION 显式放行）一律拒绝运行——静默忽略会让运维以为透传生效了。这份黑名单是防运维手滑、
# 不是安全边界（受信 agent 没有 shell / env 工具）。原因文案只有一处（kiro_env_allowlist 的 KIRO_ENV_ALLOW_ERROR：MR 评论按条目序号 +
# 掩码 + 命中规则；完整名字只在流水线日志；取值从不出现）。
env_allowlist_or_die() { kiro_env_allowlist || die_review "KIRO_ENV_PASSTHROUGH 不合法：${KIRO_ENV_ALLOW_ERROR}。请修正该流水线变量"; }
env_allowlist_or_die

# --- 2. 安装/检测 kiro-cli（失败用 die_review：网络受限的构建机上这是最常见的失败，
#        原来用 die 会让 MR 上什么都看不到、只有流水线标红，违反 I10）---
if ! command -v kiro-cli >/dev/null; then
  log "kiro-cli 不存在，尝试安装（云托管构建机场景）……"
  curl -fsSL --connect-timeout 10 --max-time 300 "$KIRO_INSTALL_URL" | bash \
    || die_review "kiro-cli 安装失败。网络受限时请使用自建构建机预装固定版本，或配置 HTTP_PROXY/HTTPS_PROXY（见 pipeline/setup-guide.md）"
  command -v kiro-cli >/dev/null || export PATH="$HOME/.local/bin:$PATH"
  command -v kiro-cli >/dev/null || die_review "安装后仍找不到 kiro-cli，请检查安装日志中的 PATH 提示"
fi

# --- 3. 安装受信 agent + kiro-cli 能力检查（放在 MR 定位之后：失败用 die_review 回写评论，而不是只让流水线标红）---
# agent 定义里的 prompt 是相对 file:// 引用（kiro 相对 agent 文件所在目录解析），复制到 ~/.kiro/agents/
# 后会失效；kiro_install_agent 在安装时把它改写为集成包内提示词文件的绝对路径。
# 读取边界（票 15 / 15-fix #3 / 15-fix2 #16）：安装函数把 read/grep/glob 三处 allowedPaths **结构化**写成本次的两条运行时路径——
#   业务库 checkout（cwd；pwd -P 取物理路径，kiro-cli 按解析后的路径比对，symlink 写逻辑路径会全部落在 allow 之外）
#   与 diff chunk 目录 $WORK/chunks（$WORK 在第 1 步末尾已 mktemp；chunk 目录要先建好，安装函数要求路径已存在，
#   第 4 步 build_review_input 对已存在的空目录只 mkdir -p、不会另建一个）。
# 两条路径是安装函数的必填参数，缺了拒绝落盘（allow 为空在 headless 下等于每次读取都被拒，宁可不跑）；
# 三个工具的 deniedPaths 缺失/为空/不含 **/.git/** 同样拒装（否则结构化写入会凭空造出只有 allow 没有 deny 的工具）。
# Kiro 运行目录（15-fix4 #1）：四处 kiro-cli 调用（下面的 --help / --version、第 5.5 步的 settings、第 6 步的 chat）都在这个**空目录**下运行，
# 业务库只在 allowedPaths 里、由模型用绝对路径读取（运行时提示词把 $WS_P 穿进去）。kiro-cli 相对 cwd 发现的每一个面——
# $CWD/.kiro/agents/<同名>.json 顶替受信 agent（工作区优先于全局）、$CWD/.kiro/settings/cli.json 顶掉全局设置、AGENTS.md steering、
# lsp.json——都落在一个没有文件的目录里；第 5.5 步的删除从承重措施变成第二道。
mkdir -p "$WORK/chunks" "$WORK/cwd" || die_review "无法创建工作目录：$WORK/chunks、$WORK/cwd"
KIRO_CWD=$(cd "$WORK/cwd" && pwd -P) || die_review "无法进入 Kiro 运行目录：$WORK/cwd"   # 物理路径：与日志、替身记录逐字一致
WS_P=$(pwd -P); CH_P=$(cd "$WORK/chunks" && pwd -P) || die_review "无法进入 diff chunk 目录：$WORK/chunks"
INSTALLED_AGENT=$(kiro_install_agent "$AGENT_FILE" "$HOME/.kiro/agents" --workspace "$WS_P" --chunks "$WORK/chunks") \
  || die_review "受信 agent 安装失败：$AGENT_FILE"
# 安装器 stdout 单行只是约定（15-fix4 #15）：将来多一行 debug 就让 AGENT_NAME 拿到多行串、传给 --agent
[[ "$INSTALLED_AGENT" != *$'\n'* ]] || die_review "内部错误：安装器输出不是单行（集成包缺陷，请报告）"
AGENT_NAME=$(basename "$INSTALLED_AGENT" .json)
log "已安装受信 custom agent：${AGENT_NAME}（${INSTALLED_AGENT}）"
# 安装结果自检 = **值比对 + 安全字段**，不是只看形状：读安装文件本身，三处 allowedPaths 的值必须逐字等于本次的 pwd -P 与
# $WORK/chunks 物理路径（参数顺序反了、丢了 pwd -P、写成逻辑路径都过不了）、三处 deniedPaths 非空且含 **/.git/**、
# allowedTools=[]、includeMcpJson/includePowers=false（kiro_agent_selfcheck，一次 jq）。任何一项不符都拒绝运行——某个工具
# 没有边界的 agent 不能拿去跑。if/else 而不是 `a && log || die`：log 写 stderr 失败时后者会带着空原因走 die 分支（15-fix3 #7）。
if kiro_agent_selfcheck "$INSTALLED_AGENT" "$WS_P" "$CH_P"; then
  log "受信 agent 自检通过：allowedPaths 值比对（read/grep/glob 三处 = 业务库 checkout + chunks 物理路径）、allowedTools=[]、includeMcpJson/includePowers=false、deniedPaths 三处含 **/.git/** 且仓库相对形状已按两条 allow 根注入绝对副本（$(jq -r '[.toolsSettings.read.deniedPaths[] | select(startswith("**/"))] | length' "$INSTALLED_AGENT") 条 × 2）"
else
  die_review "受信 agent 安装结果异常：${KIRO_AGENT_SELFCHECK_ERROR}（集成包缺陷，请报告）"
fi
# 打出安装文件里**实际**的许可路径（不是打参数）：首次联调按 setup-guide §8 核对它们与本次 checkout 一致
log "受信 agent 许可路径：$(jq -r '.toolsSettings.read.allowedPaths | join("、")' "$INSTALLED_AGENT")（read/grep/glob 三处一致）"
# 四处 kiro-cli 调用（这里的 --help 与 --version、第 5.5 步的 settings、第 6 步的 chat）都以 env -i + 许可清单启动（15-fix #8）：
# 第 2 步可能刚把 ~/.local/bin 加进 PATH，所以许可清单在这里重算一次（第 1.6 步那次只为校验 KIRO_ENV_PASSTHROUGH）。
env_allowlist_or_die
# 所有 kiro-cli 子命令都在 $KIRO_CWD（空目录）下执行，绝不在业务库工作树里（15-fix4 #1）
log "Kiro 运行目录：${KIRO_CWD}（空目录；业务库 ${WS_P} 只在 allowedPaths 里，模型按绝对路径读取）"
KIRO_CHAT_HELP=$(cd "$KIRO_CWD" && "$TIMEOUT_BIN" 60 env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli chat --help 2>&1 || true)
grep -q -- '--agent-engine' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --agent-engine，无法钉死 ${KIRO_ENGINE} 引擎（ADR-0004：默认引擎不阻断 AGENTS.md 注入），拒绝运行。请升级 kiro-cli（≥ 2.21）"
grep -qE -- '(^|[[:space:]])--agent([[:space:]]|$)' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --agent，无法套用受信只读 agent（拒绝路径、无 MCP/shell/write/web），拒绝运行。请升级 kiro-cli"
# 结构化输出契约完全依赖 stream-json（报告从 runFinished.data.finalText 取）。不预检的话，
# 不支持该参数的版本会先把额度烧掉、再以 clap 退出码 2 失败，MR 上只剩「退出码 2」这种不可行动的信息。
grep -q -- '--output-format' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --output-format，无法取得结构化评审报告（契约在 runFinished.data.finalText 里），拒绝运行。请升级 kiro-cli（≥ 2.21）"
# kiro-cli 版本 vs 探测过的版本（15-fix2 #24）：读取边界（allowedPaths 之外的符号链接、../ 越界）靠 kiro-cli 先解析再比对，
# 这是 P1-15 T8 在 KIRO_TESTED_VERSIONS 上实测的行为，不是文档承诺。版本不在名单里**不失败**（客户 curl 装的往往是最新版），
# 但日志与汇总评论都要留一句 notice；取不到版本号同样 notice。生产的兜底不变：符号链接在隔离步骤里全部删除。
# 取法在 kiro_cli_version（scripts/lib/kiro-agent.sh，探测脚本共用，15-fix4 #7）：stdout / stderr 分开捕获、按程序名锚定——stderr 上先到的
# 升级提示「A new version (2.30.0) …」不能被当成已装版本；版本打到 stderr 的 CLI 仍取得到（15-fix3 #8）。--version 退出码非零 → 失败评论：
# 连 --version 都跑不起来的 CLI，不该再在 chat 上烧掉整个 KIRO_TIMEOUT。
kiro_cli_version "$TIMEOUT_BIN" "$KIRO_CWD" || die_review "${KIRO_CLI_VERSION_ERROR}。kiro-cli 无法运行，拒绝评审；请检查构建机上的 kiro-cli 安装"
if [[ -z "$KIRO_CLI_VERSION" || " $KIRO_TESTED_VERSIONS " != *" $KIRO_CLI_VERSION "* ]]; then
  REVIEW_NOTICE="注意：本次 kiro-cli 版本 ${KIRO_CLI_VERSION:-未知} 未经 P1-15 探测（已探测：${KIRO_TESTED_VERSIONS}），读取边界依赖未验证的路径解析行为（符号链接 / ../ 是否先解析再比对 allowedPaths）；请按 scripts/probe/README.md「升级 kiro-cli 之后」跑一次探测。"
  log "警告：${REVIEW_NOTICE}"
else
  log "kiro-cli 版本 ${KIRO_CLI_VERSION}：在 P1-15 探测过的版本名单内（${KIRO_TESTED_VERSIONS}）"
fi
# 行内评论标记里的指纹要 sha1：标记是把「本评审员发的」与人工评论区分开的依据，没有它下一次评审
# 认不出自己的评论、重跑会在同一行上堆重复评论（违反 I6 幂等）。与 timeout 同理列为硬依赖。
if [[ "$INLINE_COMMENT" == "1" ]]; then
  command -v sha1sum >/dev/null || command -v shasum >/dev/null \
    || die_review "INLINE_COMMENT=1 需要 sha1sum 或 shasum 计算行内评论标记里的指纹（缺了下次评审认不出自己的评论，重跑会发重复评论）。请在构建机安装 coreutils 或 perl"
fi

# --- 4. 生成 diff（merge-base 三点比较；浅克隆自动加深）---
git fetch -q origin "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}" \
  || die_review "无法 fetch 目标分支" "$TARGET_BRANCH"   # 分支名是 MR 作者可控的不受信取值，走 die_review 的第二个参数（日志里掩码）
if ! BASE=$(git merge-base "origin/${TARGET_BRANCH}" HEAD 2>/dev/null); then
  log "浅克隆缺少历史，尝试 --unshallow……"
  git fetch -q --unshallow origin 2>/dev/null || true
  BASE=$(git merge-base "origin/${TARGET_BRANCH}" HEAD) || die_review "无法计算 merge-base"
fi
truncated=0
build_review_input "$BASE" "HEAD" "$WORK/review.diff" "$WORK/omitted.txt" "$WORK/chunks" || truncated=$?
[[ "$truncated" == "0" || "$truncated" == "10" ]] || die_review "diff 压缩失败（rc=${truncated}）"
# 只有 rc 0 才可能是真的「diff 为空」：rc 10 时 build_review_input 保证至少一个输出非空（否则它自己返回 1）
if [[ "$truncated" == "0" && ! -s "$WORK/review.diff" && ! -s "$WORK/omitted.txt" ]]; then
  log "diff 为空，跳过评审。"
  exit 0
fi
log "diff 已生成：$(wc -c < "$WORK/review.diff" | tr -d ' ') 字节（merge-base ${BASE:0:12}..HEAD，$([[ "$truncated" == "10" ]] && echo 已按阈值截断 || echo 完整直传)）"

# --- 4.5 变更行集合（spec §4.5 第 2 步）---
# 放在这里而不是发布前：读的是 git 对象（与评审输入同源），且必须在隔离步骤删工作树文件之前
# 就算出来，才能保证「行内评论的行号」与「喂给评审员的 diff」出自同一次比较。
# 零上下文（-U0）：只要新增/修改行，不要上下文行——上下文行没改过，把评论挂上去是噪音。
# 形态钉死在 _git_diff_pinned 里（scripts/lib/diff-compress.sh）：第 4 步喂给评审员的 diff 走的是
# 同一个封装，模型看到的行与脚本判定「可定位」的行必须出自同一次、同一形态的比较。
if [[ "$INLINE_COMMENT" == "1" ]]; then
  _git_diff_pinned --no-renames -U0 "$BASE" HEAD > "$WORK/inline.diff" \
    || die_review "生成零上下文 diff 失败（行内评论要靠它算变更行集合）"
  review_changed_lines < "$WORK/inline.diff" > "$WORK/changed-lines.json" \
    || die_review "解析变更行集合失败"
  jq -e 'type == "object"' "$WORK/changed-lines.json" >/dev/null 2>&1 \
    || die_review "变更行集合不是合法 JSON 对象（行号校验完全依赖它，宁可失败也不能把评论发到错的行上）"
  log "变更行集合：$(jq -r 'length' "$WORK/changed-lines.json") 个文件、$(jq -r '[.[][] | (.[1] - .[0] + 1)] | add // 0' "$WORK/changed-lines.json") 行可定位"
  # diff 非空却一个可定位行都没算出来：正常改动不会这样（纯删除的 MR 会，但那时也确实无处可挂）。
  # 更常见的成因是构建机上还有别的 diff 配置改了输出形态。此时所有问题都会落进「未定位」，
  # 而阿里云侧开发者看不到上面那行日志，所以必须在汇总评论里说明（I10）。
  if [[ -s "$WORK/inline.diff" && "$(jq -r 'length' "$WORK/changed-lines.json")" == "0" ]]; then
    INLINE_NOTICE="本次没能从 diff 里算出任何可定位的新增/修改行，因此全部问题都归入「未定位问题」。若本次改动确有新增行，请检查构建机的 git diff 配置。"
    log "警告：${INLINE_NOTICE}"
  fi
fi

# --- 5. 组装评审输入 ---
{
  echo "=== 变更元信息 ==="
  echo "源分支: ${SOURCE_BRANCH}"
  echo "目标分支: ${TARGET_BRANCH}"
  echo "Commit: $(git rev-parse HEAD)"
  if [[ "$truncated" == "10" ]]; then
    echo ""
    echo "=== 未直传的变更文件索引（每行一个 JSON：chunk 是该文件完整 diff 的本地路径，请用 read 工具读取；file 只是文件名，不是路径）==="
    cat "$WORK/omitted.txt"
  fi
  echo ""
  echo "=== DIFF ==="
  cat "$WORK/review.diff"
} > "$WORK/input.txt"

# --- 5.5 工作区隔离：必须在 diff 生成之后、Kiro 启动之前 ---
# 业务库内容一律不受信。删什么、为什么、怎么一次遍历删干净，见 scripts/lib/isolation.sh（review_isolate_workspace）：
# 任意深度的 AGENTS.md / .kiro（任何类型、不分大小写）/ 符号链接，以及根 lsp.json；任意深度的 .git 目录内部不动。
# 这一步是**第二道**（15-fix4 #1）：kiro-cli 相对 cwd 发现的面——`.kiro/settings/cli.json` 覆盖全局设置、`$CWD/.kiro/agents/`
# 顶替同名受信 agent（工作区优先于全局，kiro-cli 2.21 实测）、AGENTS.md steering、lsp.json——第一道是四处 kiro-cli 调用都在
# $KIRO_CWD（空目录）下运行，业务库从来不是 cwd。删除仍做：业务库在 allowedPaths 里，AGENTS.md 之类若被 kiro-cli 按别的途径
# 发现（未来版本、v3 的子目录 steering）仍不该在；且这份清单永远关不上，第一道才是承重的。
# 符号链接（15-fix #1）：`payload -> /root/.aws/credentials` 的请求路径字面上在 allowedPaths 之内，kiro-cli 是否先解析再比对
# 是它的实现细节（探测 P1-15 T8 记录事实，见上面的 KIRO_TESTED_VERSIONS）；删掉是确定性、零依赖的兜底。
# diff 已从 git 对象算好并写入 $WORK，删工作树文件不影响评审输入。**这一步会改动业务库工作树**：本流水线只有评审一个任务，
# 若要在同一工作区追加别的任务，必须先重新 checkout（setup-guide §7/§12）。
# 删除清单 isolation-removed.zlist：`class<TAB>path<NUL>`，先写清单再删（15-fix4 #6）
ISOLATION_COUNTS=$(review_isolate_workspace "$WORK/isolation-removed.zlist") \
  || die_review "隔离失败：无法移除业务库中的注入面文件（AGENTS.md / .kiro / 符号链接 / lsp.json），见流水线日志"
read -r _iso_agents _iso_kiro _iso_links _iso_lsp <<<"$ISOLATION_COUNTS"
log "隔离：已移除业务库工作树中 ${_iso_agents} 个 AGENTS.md、${_iso_kiro} 个 .kiro、${_iso_links} 个符号链接（均任意深度）与根 lsp.json（${_iso_lsp} 个，任何类型）；工作树自己的 .git 不动"
unset _iso_agents _iso_kiro _iso_links _iso_lsp
# 执行环境：禁止 Kiro 继承工作区默认资源（AGENTS.md/README.md 等），只对 v2 引擎有效（ADR-0004）。
# 它依赖上面对 .kiro/ 的删除（见 ①），本身只覆盖「AGENTS.md 没删干净 / 藏在别处」这一种漏网情形。
# 写入的是执行器 $HOME 的全局设置且刻意不回滚（spec I1）：常驻构建机上它保持为 true 只会更严格。
( cd "$KIRO_CWD" && "$TIMEOUT_BIN" 60 env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli settings chat.disableInheritingDefaultResources true ) || die_review "隔离失败：无法设置 kiro-cli chat.disableInheritingDefaultResources=true"
log "隔离：已设置 chat.disableInheritingDefaultResources=true"

# --- 5.6 行内评论的版本对预采样（票 17-fix3 ⑥；只在 INLINE_COMMENT=1 时打这一次接口）---
# 放在这里而不是发布前：滞后的重查只要几秒，挪到模型之前多数滞后在评审开始前就自愈了；
# 采样结果还会与发布前那次比对，把「评审期间有新推送」从推断变成证明。核对失败**不**跳过评审。
inline_presample

# --- 6. 执行 Kiro headless 评审（强制超时）---
# 读取边界由受信 agent 的 allowedPaths 决定（业务库 checkout + $WORK/chunks，第 3 步注入；deniedPaths 仍在且先于
# allow 判定）。kiro-cli 2.21.1 v2 headless 实测（探测 P1-15）：allowedPaths 内的读取免确认；之外的读取被 CLI 直接
# 拒绝（tool_call_update.status=failed，「Permission request failed … not supported in non-interactive mode」），
# 运行正常结束、不等待到超时。所以：
#   · **不传 --trust-tools**：allowedTools 已清空，免确认只来自 allowedPaths；trust 与 allow 叠加语义不透明，
#     读者会以为 trust 才是免确认的来源（实测它不覆盖 allow 之外的路径，P1-15 T6，但仍去掉）。
#   · **绝不传 --trust-all-tools**：拒绝信息里推荐的这个开关实测**绕过** allowedPaths（P1-15 T7）。
#     端到端测试断言参数里没有任何 --trust-*。
# 子进程环境：env -i + 许可清单（kiro_env_allowlist，scripts/lib/kiro-agent.sh）——**固定名单**（PATH / HOME（登录态与
# agent 目录）/ USER / TERM / TMPDIR / LANG / LANGUAGE / LC_ALL / LC_CTYPE / LC_MESSAGES / KIRO_API_KEY / KIRO_LOG_NO_COLOR /
# 代理十个 / 证书三个 / XDG 五个，名单以 KIRO_ENV_FIXED_NAMES 为准）加 KIRO_ENV_PASSTHROUGH 点名的变量（凭证形状的名字硬拒绝）。
# Kiro 进程看不到 YUNXIAO_* / CODEUP_* 与 Flow 注入的其它变量。
# "$TIMEOUT_BIN" 放在 env -i **外面**（timeout 自身不需要清洗，PATH 已透传）。许可清单让 kiro-cli 起不来时走下面的
# 退出码路径（I10 失败可见），绝不回退到继承完整环境。第 3 步的 --help 与 --version、第 5.5 步的 settings 用的是同一份清单。
# --output-format stream-json 只在 v2/v3 引擎上被接受（v1 直接报错），结构化输出契约依赖它：
# 评审报告要从 runFinished.data.finalText 里取（spec §4.1、§4.7.1 P1-08）。
# 本次运行的契约标记随机串。固定字面量标记可被业务库利用：提示词要求把注入企图作为 P0 报出来，
# 模型常常直接原文引用那行标记，标记计数变 2 → 每次评审都降级。nonce 让攻击者无法预先提交。
REVIEW_NONCE=$(review_new_nonce)
[[ "$REVIEW_NONCE" =~ ^[0-9a-f]{16}$ ]] || die_review "生成契约标记随机串失败（得到：${REVIEW_NONCE}）"
grep -q '{{REVIEW_NONCE}}' "$PROMPT_FILE" \
  || die_review "运行时提示词缺少 {{REVIEW_NONCE}} 占位符：模型拿不到本次标记，每次评审都会降级。请同步更新 ${PROMPT_FILE}"
# 业务库**绝对路径**穿进运行时提示词（15-fix4 #1）：kiro-cli 在空目录下运行，模型写相对路径会落在 cwd 之外被拒、静默降低评审质量。
grep -q '{{REVIEW_WORKSPACE}}' "$PROMPT_FILE" \
  || die_review "运行时提示词缺少 {{REVIEW_WORKSPACE}} 占位符：模型拿不到业务库的绝对路径，相对路径读取会全部被拒。请同步更新 ${PROMPT_FILE}"
# 用 jq 做字面替换而不是 sed：路径里的 / & \ 会撞上 sed 的定界符与替换元字符；jq 的 $ws 是已求值的字符串，不再解释
jq -Rsj --arg ws "$WS_P" --arg nonce "$REVIEW_NONCE" 'gsub("\\{\\{REVIEW_WORKSPACE\\}\\}"; $ws) | gsub("\\{\\{REVIEW_NONCE\\}\\}"; $nonce)' "$PROMPT_FILE" > "$WORK/prompt.txt" \
  || die_review "运行时提示词渲染失败"
grep -qF '{{' "$WORK/prompt.txt" && die_review "运行时提示词渲染后仍有占位符残留（集成包缺陷，请报告）"
# 只打随机串、不打完整标记：日志里出现标记字面量会干扰「评论/日志里不该有契约标记」这类断言，
# 排查时有随机串就够了（标记模板是固定的）。
log "本次契约标记随机串：${REVIEW_NONCE}"

log "Kiro 引擎：${KIRO_ENGINE}（--agent-engine ${KIRO_ENGINE}；ADR-0004：v1/v3 不阻断 AGENTS.md 注入，不得使用）"
# 只打变量名、不打取值（KIRO_API_KEY 在清单里）。名字按数组元素取，不按行切：取值含换行时按行 cut 会把半个取值当成名字
# 放出来（15-fix #7）。
log "Kiro 进程环境许可清单（只透传这些变量）：$(kiro_env_allowlist_names | paste -sd' ' -)"
log "开始 Kiro 评审（超时 ${KIRO_TIMEOUT}s，输出格式 stream-json）……"
kiro_rc=0
# 在 $KIRO_CWD（空目录）下运行（15-fix4 #1）；业务库路径只在 allowedPaths 与提示词里
( cd "$KIRO_CWD" && "$TIMEOUT_BIN" -k 30 "$KIRO_TIMEOUT" env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli chat --no-interactive \
  --agent-engine "$KIRO_ENGINE" --output-format stream-json \
  --agent "$AGENT_NAME" \
  "$(cat "$WORK/prompt.txt")" ) \
  < "$WORK/input.txt" > "$WORK/stream.jsonl" 2> "$WORK/kiro-stderr.log" || kiro_rc=$?

if [[ "$kiro_rc" -ne 0 ]]; then
  # kiro-cli 自己的 stderr 会引用被评审文件内容、失败请求（含 bearer）——也是评论出口，过掩码再打（第 24 条）；
  # 掩码程序不可用时宁可不打
  tail -20 "$WORK/kiro-stderr.log" 2>/dev/null | review_clean_text | review_redact_secrets --keep-lines >&2 || true
  [[ "$kiro_rc" == "124" ]] && die_review "Kiro 评审超时（${KIRO_TIMEOUT}s）"
  die_review "Kiro 评审失败（kiro-cli 退出码 ${kiro_rc}）"
fi
[[ -s "$WORK/stream.jsonl" ]] || die_review "Kiro 退出码为 0 但事件流为空"

# --- 6.1 成本与上下文可观测指标写流水线日志（spec §4.1：metadata.meteringUsage 作为成本指标）---
# 阿里云侧开发者看不到 CloudWatch，用量只能靠流水线日志留痕；取不到时打 - 而不是让评审失败。
log "Kiro 用量：$(review_stream_usage "$WORK/stream.jsonl")"

# --- 6.2 提取契约 JSON ---
# rc 2/3 是「Kiro 没跑完 / 自报失败」——不是解析问题，走既有失败评论路径。
# rc 4/5 是「跑完了但输出不合契约」——评审已产出，降级为贴出原文（退出码仍为 0）。
extract_rc=0
review_extract_json "$WORK/stream.jsonl" "$REVIEW_NONCE" > "$WORK/contract.json" || extract_rc=$?
case "$extract_rc" in
  2) die_review "Kiro 事件流中没有 runFinished 事件（评审未跑完；确认 --agent-engine ${KIRO_ENGINE} 与 --output-format stream-json 被接受）" ;;
  3) die_review "Kiro 自报运行失败（runFinished.status 取值见后）" "status=$(tr -d '\n' < "$WORK/contract.json")" ;;
  # rc 7/8 是本地故障，绝不能和「被评审代码里有假标记」（rc 6）共用一个文案
  7) die_review "读不到 Kiro 事件流文件（本地 I/O 故障，不是评审内容问题）：${WORK}/stream.jsonl" ;;
  8) die_review "内部错误：提取契约时没有传入本次标记随机串（集成包缺陷，请报告）" ;;
esac

DEGRADE_REASON=""; DEGRADE_DETAIL=""
case "$extract_rc" in
  0) ;;
  4) DEGRADE_REASON="评审员输出中没有成对的 <<<KIRO_REVIEW_JSON>>> 契约标记" ;;
  5) DEGRADE_REASON="契约标记内不是恰好一个 JSON 对象" ;;
  6) DEGRADE_REASON="输出里出现多于一对契约标记（很可能是被评审代码里的假标记被评审员原文引用），无法判定哪一段是评审结果" ;;
  *) DEGRADE_REASON="提取契约 JSON 失败（rc=${extract_rc}）" ;;
esac
# kiro-cli 自己截断了最终消息时，契约必然缺尾巴。不点明这一点，运维只会照着评论里的
# 「重跑评审」提示一遍遍重跑同一个必然失败的评审。
if [[ -n "$DEGRADE_REASON" ]] && review_stream_final_truncated "$WORK/stream.jsonl"; then
  DEGRADE_REASON="${DEGRADE_REASON}；且 kiro-cli 标记 finalTextTruncated=true（最终消息被其自身截断，重跑同样会截断，需要缩小 diff 或调高 kiro-cli 输出上限）"
fi

# --- 6.3 字段校验：不合契约的问题丢弃并计数 ---
if [[ -z "$DEGRADE_REASON" ]]; then
  validate_rc=0
  review_validate < "$WORK/contract.json" > "$WORK/validated.json" 2> "$WORK/validate-err.log" || validate_rc=$?
  case "$validate_rc" in
    0)
      # review_validate 内部已按 归一化 → 字段级掩码 → 清洗 → 上限 的顺序处理（16-fix3 第 15 条）：validated.json 是结构化路径全部
      # 模型文本的唯一收口点（方案 C），渲染器、行内正文、折叠区、截断副本与下面「评审报告：…」那行日志拿到的都是掩码后的文本。
      [[ -s "$WORK/validated.json" ]] || die_review "review_validate 以 0 退出但 validated.json 为空（输出被截断或写失败）"   # 第 20 条
      truncated_fields=$(jq -r '.truncated_fields // 0' "$WORK/validated.json") || die_review "读取 validated.json 失败（jq rc=$?）"
      [[ "$truncated_fields" =~ ^[0-9]+$ ]] || die_review "validated.json 的 truncated_fields 不是数字" "$truncated_fields"   # 第 20 条
      [[ "$truncated_fields" == "0" ]] \
        || log "警告：${truncated_fields} 个模型字段超出上限已截断（summary/verdict_reason ${REVIEW_CAP_SUMMARY}、title ${REVIEW_CAP_TITLE}、body ${REVIEW_CAP_BODY}、fix ${REVIEW_CAP_FIX} 字节）"
      overflow=$(jq -r '.overflow_findings // 0' "$WORK/validated.json") || die_review "读取 validated.json 失败（jq rc=$?）"
      [[ "$overflow" =~ ^[0-9]+$ && "$overflow" -gt 0 ]] \
        && log "警告：问题数 $((overflow + REVIEW_MAX_FINDINGS)) 超过上限 ${REVIEW_MAX_FINDINGS}，仅展示前 ${REVIEW_MAX_FINDINGS} 条"   # 第 28 条
      ;;
    # 字段级掩码或清洗失败：既不能把未掩码的字段往下送，也不能当「解析失败」把原文贴出去 → 失败评论。
    # 校验日志里只有**库函数自己**写的行（`review_redact_json: …` 一类，脚本文案 + 文件路径）能进日志与失败评论；jq 的诊断会回显
    # 出错的取值（模型文本），只报条数（第 13 条）
    4) die_review "契约字段级掩码或清洗失败（rc=4）：$(_validate_err_lib_lines "$WORK/validate-err.log")" ;;
    # 受信 agent 未生效：contract 字段只在 agent 提示词里要求，缺了就说明模型拿的是裸提示词——
    # 拒绝路径与掩码规则都没生效，这份输出不能贴到 MR 上，所以走失败评论而不是降级。
    3) die_review "受信 agent 未生效：评审输出缺少 contract=\"${REVIEW_CONTRACT_ID}\" 标识（只在受信 agent 提示词里要求）。这份输出不是受信只读 agent 的产出，已拒绝回写其内容。请检查 ${AGENT_FILE} 的安装与 --agent ${AGENT_NAME} 是否生效" ;;
    *) DEGRADE_REASON="契约 JSON 顶层结构不符"; DEGRADE_DETAIL="$(tail -1 "$WORK/validate-err.log")" ;;   # 校验器的最后一行 stderr 当不受信取值处理
  esac
fi

# --- 7. 渲染汇总评论并回写 ---
DIFF_NOTE="完整直传"
[[ "$truncated" == "10" ]] && DIFF_NOTE="超出阈值（${DIFF_SIZE_LIMIT}B）已按优先级截断，其余变更 Kiro 通过 diff 索引自主读取"
REVIEW_TS=$(date '+%Y-%m-%d %H:%M:%S')
render_args=(--sha "$SHORT_SHA" --src "$SOURCE_BRANCH" --dst "$TARGET_BRANCH"
             --ts "$REVIEW_TS" --diff-note "$DIFF_NOTE" --run "$REVIEW_RUN")
# 上一条汇总里读回的历次记录：渲染器会在它后面追加本次那一行
[[ -n "$PRIOR_HISTORY_FILE" ]] && render_args+=(--history "$PRIOR_HISTORY_FILE")

if [[ -n "$DEGRADE_REASON" ]]; then
  # 降级：评审已经产出、只是没按契约输出——贴清洗后的原文并在标题标明，退出码仍为 0。
  log "警告：结构化解析失败（${DEGRADE_REASON}${DEGRADE_DETAIL:+：$(_untrusted_for_log "$DEGRADE_DETAIL")}），降级为贴出评审员输出原文"
  final_rc=0
  review_stream_final_text "$WORK/stream.jsonl" > "$WORK/final.txt" || final_rc=$?
  [[ "$final_rc" == "0" ]] || die_review "结构化解析失败，且取评审员原文也失败（rc=${final_rc}）"
  review_clean_text < "$WORK/final.txt" > "$WORK/raw.md"
  [[ -s "$WORK/raw.md" ]] || die_review "结构化解析失败，且评审员输出为空"
  # 降级评论只带 REVIEW_NOTICE（版本 / 环境类）：INLINE_NOTICE 是关于分桶的提示，放进一份没有问题清单的评论里没有意义（15-fix4 #3 / A7）。
  # --notice "" 是已验证的 no-op（解析器接受空值、渲染器按 [[ -n ]] 判断），不需要一次性数组与空数组守卫。
  review_render_degraded --text "$WORK/raw.md" --reason "${DEGRADE_REASON}${DEGRADE_DETAIL:+（${DEGRADE_DETAIL}）}" --notice "$REVIEW_NOTICE" "${render_args[@]}" \
    > "$WORK/comment.md" || die_review "降级评论渲染失败"
else
  dropped=$(jq -r '.dropped_findings' "$WORK/validated.json")
  delocated=$(jq -r '.delocated_findings' "$WORK/validated.json")
  [[ "$dropped" == "0" ]] \
    || log "警告：${dropped} 条问题不符合输出契约已丢弃（级别不在 P0/P1/P2，或缺 title/body）"
  [[ "$delocated" == "0" ]] \
    || log "警告：${delocated} 条问题的 file 含换行/竖线/反引号，已按未定位处理（这类值会破坏表格与定位串）"
  # 票 17 C：同一轮里逐字段相同的问题已在 review_validate 里合并（只留首条），这里只留痕
  duplicates=$(jq -r '.duplicate_findings // 0' "$WORK/validated.json")
  [[ "$duplicates" == "0" ]] \
    || log "警告：${duplicates} 条完全重复的问题已合并（逐字段相同：文件、行区间、级别、标题、说明、修复建议；只保留首条）"
  # 票 17 B：契约外的结论已被 review_validate 置空（评论里渲染固定文案），原值**只**出现在这行日志里
  verdict_raw=$(jq -r '.verdict_raw // ""' "$WORK/validated.json")
  [[ -z "$verdict_raw" ]] \
    || log "警告：评审员结论不在契约内（已按未给出结论处理）：$(_untrusted_for_log "$verdict_raw")"   # 模型文本：不经掩码不进日志（票 16）
  log "评审报告：P0 $(jq -r '[.findings[] | select(.severity == "P0")] | length' "$WORK/validated.json") · P1 $(jq -r '[.findings[] | select(.severity == "P1")] | length' "$WORK/validated.json") · P2 $(jq -r '[.findings[] | select(.severity == "P2")] | length' "$WORK/validated.json")，结论 $(jq -r '.verdict' "$WORK/validated.json")，丢弃 ${dropped}"
  # 行内评论必须在渲染汇总之前发（spec §4.5 把汇总排在第 8 步）：统计行里「其中 N 条已标注在
  # 对应行」只能是真的发出去的条数，折叠区也只能在知道哪些发失败之后才算得准。
  SUMMARY_JSON="$WORK/validated.json"
  if [[ "$INLINE_COMMENT" == "1" ]] && publish_inline_comments "$WORK/validated.json"; then
    SUMMARY_JSON="$WORK/plan.json"
  fi
  # 汇总评论带合成的 notice（版本 notice 在前，行内评论的 notice 在后）；all_notice 读全局，INLINE_NOTICE 可能在 publish_inline_comments 里刚被追加
  review_render_summary --json "$SUMMARY_JSON" --inline-comment "$INLINE_ACTIVE" --notice "$(all_notice)" "${render_args[@]}" \
    > "$WORK/comment.md" || die_review "汇总评论渲染失败"
fi
[[ -s "$WORK/comment.md" ]] || die_review "渲染后的评论为空"
# 文档级兜底掩码（票 16 / 16-fix2 方案 C，spec I3 修订）：validated.json 派生的文本已在字段级掩过，这一遍严格保行地兜住
# 绕过 validated.json 的输出面（元信息表里的分支名、由 API 字符串拼出的 notice、降级原文）。放在渲染之后、**截断之前**：
# comment.full.md（截断前副本）与下面两处打进流水线日志的全文因此天然是掩码后的，截断量的是掩码后的字节数——依赖的是
# 这个**顺序**，不是「掩码只会变短」（1 字节的值会掩成 `****`、降级原文里的 PEM 会多出占位与提示行，掩码可能变长）。
# 降级评论在渲染时已掩过一次，这里再过一遍是幂等的（golden 断言过）。掩码失败 → 失败评论：绝不能把未掩码的原文继续往下送；
# rc 3（守卫拒绝：行数或标记行变化）与其余失败分开报（第 27 条）。
rrc=0
review_redact_file "$WORK/comment.md" || rrc=$?
case "$rrc" in   # rc 含义见 review_redact_file 的头注释；只区分「守卫拒绝」与其余（第 9 条）
  0) ;;
  3) die_review "评论掩码后结构守卫拒绝写回（行数或标记行变化）" ;;
  *) die_review "评论掩码失败（rc=${rrc}）" ;;
esac

# Codeup content 上限 65535 字符；按字节截断留足余量，iconv 清理截断产生的残缺 UTF-8 序列
if [[ "$(wc -c < "$WORK/comment.md" | tr -d ' ')" -gt "$MAX_COMMENT_BYTES" ]]; then
  cp "$WORK/comment.md" "$WORK/comment.full.md"
  # 截断逻辑在 scripts/lib/review-render.sh（review_truncate_comment）：它的正确性取决于
  # 「切在哪个字节上」，放在库里才能对几十个截断窗口做扫描式回归测试。
  review_truncate_comment "$WORK/comment.md" "$MAX_COMMENT_BYTES" \
    || die_review "评论截断失败（上限 ${MAX_COMMENT_BYTES} 字节）"
  log "评审报告超长已截断；完整内容如下："
  cat "$WORK/comment.full.md" >&2
fi

if post_summary "$WORK/comment.md"; then
  log "评审完成，已回写 MR #${LOCAL_ID}"
else
  log "OpenAPI 回写失败（已按策略重试）。评审结果如下："
  cat "$WORK/comment.md" >&2
  exit 1
fi
