#!/usr/bin/env bash
# Codeup MR 自动 Kiro 评审 — 主编排脚本。
# 安全前提：本脚本必须从受信集成包仓库（流水线独立代码源，固定分支/tag）执行，
# 绝不从被评审的业务仓库源分支执行（源分支可被 MR 作者任意修改）。
# 业务仓库 checkout 目录由 REVIEW_REPO_DIR 指定，仅作为被分析数据；其中的 AGENTS.md/lsp.json/.kiro/
# 在 diff 生成之后、Kiro 启动之前被移除（第 5.5 步），Kiro 固定以 v2 引擎运行（ADR-0004）。
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
# 官方安装脚本 URL。来源：https://kiro.dev/docs/cli/installation/（页面命令
# `curl -fsSL https://cli.kiro.dev/install | bash`；脚本本身支持 Linux/macOS，
# Linux 下安装到 ~/.local/bin，含 glibc 检测与 musl 回退）。核实日期：2026-07-21。
KIRO_INSTALL_URL="${KIRO_INSTALL_URL:-https://cli.kiro.dev/install}"
PROMPT_FILE="${PROMPT_FILE:-${PKG_ROOT}/prompts/review-prompt.md}"
AGENT_FILE="${PKG_ROOT}/kiro/agent-codeup-reviewer.json"
REVIEW_REPO_DIR="${REVIEW_REPO_DIR:-$PWD}"
# Kiro 进程环境许可清单之外要额外透传的变量**名**（逗号分隔，只放名字不放值；自建执行机可能需要 LD_LIBRARY_PATH /
# AWS_PROFILE 这类）。固定名单与校验在 scripts/lib/kiro-agent.sh 的 kiro_env_allowlist；非法名字在第 1.6 步拒绝运行。
KIRO_ENV_PASSTHROUGH="${KIRO_ENV_PASSTHROUGH:-}"
# Kiro 引擎钉死为 v2，写在脚本里而不是 agent 配置里（ADR-0004）：实测 kiro-cli 2.21 headless 的默认
# 引擎 v1 与预览版 v3 都不阻断工作区 AGENTS.md 注入，只有 v2 配合 chat.disableInheritingDefaultResources
# 才阻断。故意不读环境变量——引擎不是可配置项，避免被流水线变量或工作区设置改掉。
KIRO_ENGINE=v2

log() { echo "[kiro-review] $*" >&2; }
die() { log "错误：$*"; exit 1; }

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

die_review() {
  log "错误：$*"
  if [[ "$MR_LOCATED" == "1" ]]; then
    local f
    local -a hist_args=()
    f=$(mktemp)
    # 失败评论的形态（标题/评审标记/历史标记/元信息表/历次表/页脚）由 review_render_failure 统一渲染，
    # 与成功、降级评论同出一源：定位旧评论靠 `<!-- kiro-review:<sha> run:N -->`，
    # 失败评论若自己手写一份、哪天与渲染器走形，就会被漏掉、于是在 MR 上多出一条汇总。
    [[ -n "$PRIOR_HISTORY_FILE" ]] && hist_args=(--history "$PRIOR_HISTORY_FILE")
    review_render_failure --reason "$*" --sha "${SHORT_SHA:-unknown}" \
      --src "${SOURCE_BRANCH:-?}" --dst "${TARGET_BRANCH:-?}" \
      --ts "$(date '+%Y-%m-%d %H:%M:%S')" --diff-note "${DIFF_NOTE:-（本次未生成 diff）}" \
      --run "$REVIEW_RUN" "${hist_args[@]+"${hist_args[@]}"}" \
      --log-hint "请查看流水线日志（构建号 ${BUILD_NUMBER:-?}）或重跑流水线。" > "$f" \
      || log "警告：失败评论渲染异常（rc≠0），改用最小失败评论"
    # 渲染器在参数不合规时（例如 --ts 为空、--history 不可读）以 rc 2 提前返回，$f 就是 0 字节。
    # 那份空文件绝不能交给 post_summary：PUT 空正文会把上一条完整报告覆盖成空白且不可恢复。
    # 退回一段最小的纯文本失败评论——仍带评审标记（下次评审才找得到这条）与本次一行历史。
    if [[ ! -s "$f" ]]; then
      local mh
      mh=$(mktemp)
      # 先带上读回来的历次记录再退化：这条最小评论同样会被 PUT 到上一条汇总上，
      # 直接用 `-`（空历史）会把累积的 20 行 run/sha/结论/计数一次性抹掉。
      review_history_append "${PRIOR_HISTORY_FILE:--}" "$REVIEW_RUN" "${SHORT_SHA:-unknown}" "" failed - - - \
        > "$mh" 2>/dev/null || true
      _review_history_ok "$mh" die_review 2>/dev/null \
        || review_history_append - "$REVIEW_RUN" "${SHORT_SHA:-unknown}" "" failed - - - > "$mh" 2>/dev/null || true
      _review_history_ok "$mh" die_review 2>/dev/null || printf '[]\n' > "$mh"
      {
        echo "$REVIEW_TITLE_FAILED"
        echo "<!-- kiro-review:${SHORT_SHA:-unknown} run:${REVIEW_RUN} -->"
        review_render_history_marker "$mh"
        echo ""
        # 失败原因可能带来自事件流的取值（不受信，例如 runFinished.status）。不清洗的话，
        # 一个含 `<!-- kiro-review:… -->` 的取值就能让这条评论带上第二个评审标记 →
        # 下一次评审判它「标记不唯一」而不作为候选 → MR 上多出一条汇总（违反 I4）；
        # 含 `-->` 的取值还会把上面那行隐藏历史提前闭合、把 JSON 露成正文。
        printf '⚠️ 评审未完成（失败评论渲染异常，只保留最小信息）：'
        printf '%s' "$*" | review_sanitize_md
        echo ""
        echo ""
        echo "请查看流水线日志（构建号 ${BUILD_NUMBER:-?}）或重跑流水线。"
        echo ""
        review_render_footer "$REVIEW_RUN"
      } > "$f"
      rm -f "$mh"
      log "已退回最小失败评论（保证不 PUT 空正文）"
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
publish_inline_comments() {
  local validated="$1"
  local pair from_ps to_ps to_commit from_commit head_full existing_rg draft_rg config_notice
  local item idx file ls le title fp cid crc ocid hits hrc n_created=0 n_existing=0 n_failed=0 submitted=0

  # 2/3/4. 变更行集合 → 可定位判定 → 排序与档位 → 上限截取。
  # 排在版本对之前：规划完全是本地计算，而「没有任何要发的行内评论」时（干净的 MR、
  # 或者所有问题都不可定位）根本不该去调那两个接口，更不该因为接口失败而在一条
  # 「未发现明显问题」的汇总上挂一句「下面是完整问题清单」。
  if ! review_plan_inline --json "$validated" --changed-lines "$WORK/changed-lines.json" \
         --profile "$INLINE_PROFILE" --max "$MAX_INLINE_COMMENTS" > "$WORK/plan.json"; then
    INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }行内评论未发出：生成行内发布计划失败，下面是完整问题清单。"
    log "警告：生成行内发布计划失败"
    return 1
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
  if ! codeup_list_patchsets "$LOCAL_ID" > "$WORK/patchsets.json"; then
    INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }行内评论未发出：查询 MR 版本列表失败（HTTP ${CODEUP_HTTP_CODE}），下面是完整问题清单。"
    log "警告：查询 MR 版本列表失败（HTTP ${CODEUP_HTTP_CODE}）"
    return 1
  fi
  if ! pair=$(codeup_select_patchset_pair < "$WORK/patchsets.json"); then
    INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }行内评论未发出：MR 版本列表里选不出「最新合并目标版本 + 最新合并源版本」这一对，下面是完整问题清单。"
    log "警告：选不出行内评论要用的版本对"
    return 1
  fi
  from_ps=$(printf '%s' "$pair" | cut -f1)
  to_ps=$(printf '%s' "$pair" | cut -f2)
  to_commit=$(printf '%s' "$pair" | cut -f3)
  from_commit=$(printf '%s' "$pair" | cut -f4)
  log "行内评论版本对：from=${from_ps}（最新合并目标版本）→ to=${to_ps}（最新合并源版本，patchset_biz_id 用它）"
  head_full=$(git rev-parse HEAD)
  # 不一致的成因通常是「评审开始后又推了一次」：Codeup 侧的版本才是评论要绑的真值，所以不改用 HEAD，
  # 但必须留痕——此时行号是按本次评审的 diff 算的，可能与那个版本对不上。
  # 两个基准都可能与 Codeup 侧不一致，而后果是同一个（行号可能有偏移）。成因分别收集、
  # 最后合成**一句**写进汇总评论：分成两句时读者会连着看到两遍「行号可能有偏移」。
  local -a offset_causes=()
  if [[ -n "$to_commit" && "$to_commit" != "$head_full" ]]; then
    log "警告：最新合并源版本的提交（${to_commit:0:12}）与当前 HEAD（${head_full:0:12}）不一致——仍以 API 给的版本为准（Codeup 侧真值），但行号可能对不上这次评审的 diff"
    # 阿里云侧开发者看不到流水线日志（I10），所以这条不确定性也必须进汇总评论
    offset_causes+=("本次评审的提交（${head_full:0:12}）不是 Codeup 侧最新的合并源版本（${to_commit:0:12}，评审开始后可能又推送过）")
  fi
  # from 侧的基准核对（R8）：我们的变更行集合来自 `merge-base(origin/<目标分支>, HEAD)..HEAD`，
  # 而 from 取的是「最新 MERGE_TARGET 版本」。目标分支在 MR 分出之后又前进过时，那个版本很可能是
  # 目标分支的**顶端**而不是 merge-base，两个基准算出来的新文件侧行号可以不一样。
  # 本票不猜 Codeup 的语义（待探测 P1-14），只做两件事：打警告 + 把不确定性写进汇总评论——
  # 让读者知道「行内评论的位置可能有偏移」，而不是默默给出一个可能错位的行号。
  if [[ -n "$from_commit" && "$from_commit" != "$BASE" ]]; then
    log "警告：最新合并目标版本的提交（${from_commit:0:12}）不等于本地 merge-base（${BASE:0:12}）——两者算出的新文件侧行号可能不同（目标分支在 MR 分出后前进过？待探测项 P1-14）"
    offset_causes+=("Codeup 侧的比较基准（合并目标版本 ${from_commit:0:12}）与本次 diff 的基准（merge-base ${BASE:0:12}）不一致")
  fi
  if [[ "${#offset_causes[@]}" -gt 0 ]]; then
    local causes
    causes=$(printf '%s；' "${offset_causes[@]}"); causes="${causes%；}"
    INLINE_NOTICE="${INLINE_NOTICE}${INLINE_NOTICE:+ }注意：行内评论的行号可能有偏移——${causes}。"
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
      log "去重：问题 #${idx}（${sev} ${file} L${ls}$([[ "$le" =~ ^[0-9]+$ && "$le" != "$ls" ]] && printf -- '–L%s' "$le")）与已有行内评论 $(printf '%s' "$hits" | tr '\n' ',') 同文件且行区间重叠/相邻、级别不低于它，视为同一问题，跳过"
      printf '{"idx":%s,"outcome":"existing"}\n' "$idx" >> "$WORK/outcomes.jsonl"; n_existing=$((n_existing + 1)); continue
    elif [[ "$hrc" != "1" ]]; then
      log "警告：问题 #${idx} 的去重判定出错（rc=${hrc}），本条按未重复处理照常发出（可能与已有评论重复）"
    fi
    if ! review_render_inline_body "$WORK/item-${idx}.json" "$SHORT_SHA" "$fp" > "$WORK/body-${idx}.md"; then
      log "警告：问题 #${idx} 的行内评论正文渲染失败，转入折叠区"
      printf '{"idx":%s,"outcome":"failed"}\n' "$idx" >> "$WORK/outcomes.jsonl"; n_failed=$((n_failed + 1)); continue
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
# KIRO_ENV_PASSTHROUGH 只收变量名：非法名字（写成 NAME=value、带空格/连字符）一律拒绝运行——静默忽略会让运维以为
# 透传生效了。die_review 的文案刻意不带取值（写成 NAME=value 的人多半把密钥放进去了，评论比日志可见范围更大）；
# 具体哪个名字非法在流水线日志里（kiro_env_allowlist 的 stderr，取值部分已打码）。
kiro_env_allowlist \
  || die_review "KIRO_ENV_PASSTHROUGH 含非法变量名（只接受逗号分隔的变量名，例如 AWS_PROFILE,LD_LIBRARY_PATH；不能带 = 或取值；具体哪个名字非法见流水线日志）。请修正该流水线变量"

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
# 读取边界（票 15 / 15-fix #3）：安装函数把 read/grep/glob 三处 allowedPaths **结构化**写成本次的两条运行时路径——
#   业务库 checkout（cwd；pwd -P 取物理路径，kiro-cli 按解析后的路径比对，symlink 写逻辑路径会全部落在 allow 之外）
#   与 diff chunk 目录 $WORK/chunks（$WORK 在第 1 步末尾已 mktemp；chunk 目录要先建好，安装函数要求路径已存在，
#   第 4 步 build_review_input 对已存在的空目录只 mkdir -p、不会另建一个）。
# 两条路径是安装函数的必填参数，缺了拒绝落盘（allow 为空在 headless 下等于每次读取都被拒，宁可不跑）。
mkdir -p "$WORK/chunks" || die_review "无法创建 diff chunk 目录：$WORK/chunks"
INSTALLED_AGENT=$(kiro_install_agent "$AGENT_FILE" "$HOME/.kiro/agents" --workspace "$(pwd -P)" --chunks "$WORK/chunks") \
  || die_review "受信 agent 安装失败：$AGENT_FILE"
AGENT_NAME=$(basename "$INSTALLED_AGENT" .json)
log "已安装受信 custom agent：${AGENT_NAME}（${INSTALLED_AGENT}；includeMcpJson=false，includePowers=false）"
# 安装结果自检：read/grep/glob 三处 allowedPaths 必须相等且恰好两条——任何一处不一致（安装函数被改坏、定义被改坏）
# 都意味着某个工具没有边界，拒绝运行。然后打出安装文件里**实际**的许可路径（不是打参数）：首次联调按 setup-guide §8
# 核对它们与本次 checkout 一致。
jq -e '.toolsSettings | [.read.allowedPaths, .grep.allowedPaths, .glob.allowedPaths] | (unique | length == 1) and (.[0] | type == "array" and length == 2)' "$INSTALLED_AGENT" >/dev/null || die_review "受信 agent 安装结果异常：read/grep/glob 的 allowedPaths 三处不一致或不是两条路径——$(jq -c '.toolsSettings | {read: .read.allowedPaths, grep: .grep.allowedPaths, glob: .glob.allowedPaths}' "$INSTALLED_AGENT" 2>/dev/null)（集成包缺陷，请报告）"
log "受信 agent 许可路径：$(jq -r '.toolsSettings.read.allowedPaths | join("、")' "$INSTALLED_AGENT")（read/grep/glob 三处一致）"
# 三处 kiro-cli 调用（这里的 --help、第 5.5 步的 settings、第 6 步的 chat）都以 env -i + 许可清单启动（15-fix #8）：
# 第 2 步可能刚把 ~/.local/bin 加进 PATH，所以许可清单在这里重算一次（第 1.6 步那次只为校验 KIRO_ENV_PASSTHROUGH）。
kiro_env_allowlist || die_review "KIRO_ENV_PASSTHROUGH 含非法变量名（见流水线日志）。请修正该流水线变量"
# --help 在集成包目录下执行：此刻业务库工作树尚未隔离，不在其中运行任何 kiro-cli 子命令
KIRO_CHAT_HELP=$(cd "$PKG_ROOT" && "$TIMEOUT_BIN" 60 env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli chat --help 2>&1 || true)
grep -q -- '--agent-engine' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --agent-engine，无法钉死 ${KIRO_ENGINE} 引擎（ADR-0004：默认引擎不阻断 AGENTS.md 注入），拒绝运行。请升级 kiro-cli（≥ 2.21）"
grep -qE -- '(^|[[:space:]])--agent([[:space:]]|$)' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --agent，无法套用受信只读 agent（拒绝路径、无 MCP/shell/write/web），拒绝运行。请升级 kiro-cli"
# 结构化输出契约完全依赖 stream-json（报告从 runFinished.data.finalText 取）。不预检的话，
# 不支持该参数的版本会先把额度烧掉、再以 clap 退出码 2 失败，MR 上只剩「退出码 2」这种不可行动的信息。
grep -q -- '--output-format' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --output-format，无法取得结构化评审报告（契约在 runFinished.data.finalText 里），拒绝运行。请升级 kiro-cli（≥ 2.21）"
# 行内评论标记里的指纹要 sha1：标记是把「本评审员发的」与人工评论区分开的依据，没有它下一次评审
# 认不出自己的评论、重跑会在同一行上堆重复评论（违反 I6 幂等）。与 timeout 同理列为硬依赖。
if [[ "$INLINE_COMMENT" == "1" ]]; then
  command -v sha1sum >/dev/null || command -v shasum >/dev/null \
    || die_review "INLINE_COMMENT=1 需要 sha1sum 或 shasum 计算行内评论标记里的指纹（缺了下次评审认不出自己的评论，重跑会发重复评论）。请在构建机安装 coreutils 或 perl"
fi

# --- 4. 生成 diff（merge-base 三点比较；浅克隆自动加深）---
git fetch -q origin "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}" \
  || die_review "无法 fetch 目标分支 ${TARGET_BRANCH}"
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
# 业务库内容一律不受信。下面三类文件 Kiro 会从工作区自动读取，MR 作者可借此操纵评审员：
#   AGENTS.md（任意深度；V3 把子目录 AGENTS.md 也当 steering）、根 lsp.json（可指定任意可执行文件）、
#   .kiro/（MCP/hooks/steering/agents/settings；任意深度——Kiro 是否只看 cwd 下的 .kiro/ 无官方保证，多删无害）。
# 删 .kiro/ 是后面两道措施的前提，不是可选项（kiro-cli 2.21 实测）：
#   ① `.kiro/settings/cli.json`（`settings --workspace` 写入）会覆盖全局设置——业务库放一份
#      {"chat.disableInheritingDefaultResources": false} 就能把下面设置的 true 顶掉；
#   ② `agent list` 显示 Workspace（$CWD/.kiro/agents）优先于 Global（~/.kiro/agents）——业务库放一份
#      .kiro/agents/codeup-reviewer.json 就能顶替受信 agent（拒绝路径、只读工具集全部失效）。
# 所以三道措施的依赖关系是：删 .kiro/ → 全局设置与受信 agent 才可信；删 AGENTS.md 独立于引擎与设置。
# diff 已从 git 对象算好并写入 $WORK，删工作树文件不影响评审输入。
# 用 -iname：大小写不敏感文件系统（macOS/Windows 执行器）上 agents.md 同样会被当作 AGENTS.md 读到。
# 同名目录（如 lsp.json/）不是注入面，但也一并删除：rm -f 遇到目录会失败，让 MR 作者能用一个目录名卡死评审。
: > "$WORK/removed-agents-md.txt"; : > "$WORK/removed-kiro-dirs.txt"
find . -not -path './.git/*' -iname AGENTS.md -not -type d -print -delete >> "$WORK/removed-agents-md.txt" || die_review "隔离失败：无法移除业务库中的 AGENTS.md"
# `\( -type d -o -type l \)`：`.kiro` 也可能是指向别处的**符号链接**（R10②）。原来只匹配 -type d，
# 业务库提交 `src/sub/.kiro -> ../../evilcfg` 就能让一份工作区配置在隔离之后依然可读。
find . -path ./.git -prune -o -name .kiro \( -type d -o -type l \) -print -prune -exec rm -rf {} + >> "$WORK/removed-kiro-dirs.txt" || die_review "隔离失败：无法移除业务库中的 .kiro/"
rm -rf ./.kiro || die_review "隔离失败：无法移除业务库根目录 .kiro"
rm -rf ./lsp.json || die_review "隔离失败：无法移除业务库根目录 lsp.json"
# 符号链接（15-fix #1）：业务库提交 `payload -> /root/.aws/credentials`，请求路径字面上就在 allowedPaths[0] 里；
# kiro-cli 是否先解析链接再比对 allowedPaths 未经实测（探测 P1-15 T8 只记录事实，生产不依赖它）。diff 已从 git 对象
# 算好，删链接不影响评审输入（链接本身的改动在 diff 里照样可见），所以任意深度的符号链接（含指向目录的）一律删除，
# .git 不碰。用 -exec rm 而不是 -delete：-delete 隐含 -depth，而 -depth 下 -prune 失效，会把 .git 里的链接也删掉。
: > "$WORK/removed-symlinks.txt"
find . -path ./.git -prune -o -type l -print -exec rm -f {} + >> "$WORK/removed-symlinks.txt" || die_review "隔离失败：无法移除业务库中的符号链接"
log "隔离：已移除业务库工作树中 $(wc -l < "$WORK/removed-agents-md.txt" | tr -d ' ') 个 AGENTS.md、$(wc -l < "$WORK/removed-kiro-dirs.txt" | tr -d ' ') 个 .kiro/、$(wc -l < "$WORK/removed-symlinks.txt" | tr -d ' ') 个符号链接（均任意深度）与根 lsp.json"
# 执行环境：禁止 Kiro 继承工作区默认资源（AGENTS.md/README.md 等），只对 v2 引擎有效（ADR-0004）。
# 它依赖上面对 .kiro/ 的删除（见 ①），本身只覆盖「AGENTS.md 没删干净 / 藏在别处」这一种漏网情形。
# 写入的是执行器 $HOME 的全局设置且刻意不回滚（spec I1）：常驻构建机上它保持为 true 只会更严格。
"$TIMEOUT_BIN" 60 env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli settings chat.disableInheritingDefaultResources true || die_review "隔离失败：无法设置 kiro-cli chat.disableInheritingDefaultResources=true"
log "隔离：已设置 chat.disableInheritingDefaultResources=true"

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
# agent 目录）/ USER / TERM / TMPDIR / LANG / LC_ALL / LC_CTYPE / KIRO_API_KEY / KIRO_LOG_NO_COLOR / 代理六个 / 证书三个 /
# XDG 四个）加 KIRO_ENV_PASSTHROUGH 点名的变量。Kiro 进程看不到 YUNXIAO_* / CODEUP_* 与 Flow 注入的其它变量。
# "$TIMEOUT_BIN" 放在 env -i **外面**（timeout 自身不需要清洗，PATH 已透传）。许可清单让 kiro-cli 起不来时走下面的
# 退出码路径（I10 失败可见），绝不回退到继承完整环境。第 3 步的 --help 与第 5.5 步的 settings 用的是同一份清单。
# --output-format stream-json 只在 v2/v3 引擎上被接受（v1 直接报错），结构化输出契约依赖它：
# 评审报告要从 runFinished.data.finalText 里取（spec §4.1、§4.7.1 P1-08）。
# 本次运行的契约标记随机串。固定字面量标记可被业务库利用：提示词要求把注入企图作为 P0 报出来，
# 模型常常直接原文引用那行标记，标记计数变 2 → 每次评审都降级。nonce 让攻击者无法预先提交。
REVIEW_NONCE=$(review_new_nonce)
[[ "$REVIEW_NONCE" =~ ^[0-9a-f]{16}$ ]] || die_review "生成契约标记随机串失败（得到：${REVIEW_NONCE}）"
grep -q '{{REVIEW_NONCE}}' "$PROMPT_FILE" \
  || die_review "运行时提示词缺少 {{REVIEW_NONCE}} 占位符：模型拿不到本次标记，每次评审都会降级。请同步更新 ${PROMPT_FILE}"
sed "s/{{REVIEW_NONCE}}/${REVIEW_NONCE}/g" "$PROMPT_FILE" > "$WORK/prompt.txt" \
  || die_review "运行时提示词渲染失败"
# 只打随机串、不打完整标记：日志里出现标记字面量会干扰「评论/日志里不该有契约标记」这类断言，
# 排查时有随机串就够了（标记模板是固定的）。
log "本次契约标记随机串：${REVIEW_NONCE}"

log "Kiro 引擎：${KIRO_ENGINE}（--agent-engine ${KIRO_ENGINE}；ADR-0004：v1/v3 不阻断 AGENTS.md 注入，不得使用）"
# 只打变量名、不打取值（KIRO_API_KEY 在清单里）。名字按数组元素取，不按行切：取值含换行时按行 cut 会把半个取值当成名字
# 放出来（15-fix #7）。
log "Kiro 进程环境许可清单（只透传这些变量）：$(kiro_env_allowlist_names | paste -sd' ' -)"
log "开始 Kiro 评审（超时 ${KIRO_TIMEOUT}s，输出格式 stream-json）……"
kiro_rc=0
"$TIMEOUT_BIN" -k 30 "$KIRO_TIMEOUT" env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli chat --no-interactive \
  --agent-engine "$KIRO_ENGINE" --output-format stream-json \
  --agent "$AGENT_NAME" \
  "$(cat "$WORK/prompt.txt")" \
  < "$WORK/input.txt" > "$WORK/stream.jsonl" 2> "$WORK/kiro-stderr.log" || kiro_rc=$?

if [[ "$kiro_rc" -ne 0 ]]; then
  tail -20 "$WORK/kiro-stderr.log" >&2 || true
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
  3) die_review "Kiro 自报运行失败（runFinished.status=$(tr -d '\n' < "$WORK/contract.json")）" ;;
  # rc 7/8 是本地故障，绝不能和「被评审代码里有假标记」（rc 6）共用一个文案
  7) die_review "读不到 Kiro 事件流文件（本地 I/O 故障，不是评审内容问题）：${WORK}/stream.jsonl" ;;
  8) die_review "内部错误：提取契约时没有传入本次标记随机串（集成包缺陷，请报告）" ;;
esac

DEGRADE_REASON=""
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
    0) ;;
    # 受信 agent 未生效：contract 字段只在 agent 提示词里要求，缺了就说明模型拿的是裸提示词——
    # 拒绝路径与掩码规则都没生效，这份输出不能贴到 MR 上，所以走失败评论而不是降级。
    3) die_review "受信 agent 未生效：评审输出缺少 contract=\"${REVIEW_CONTRACT_ID}\" 标识（只在受信 agent 提示词里要求）。这份输出不是受信只读 agent 的产出，已拒绝回写其内容。请检查 ${AGENT_FILE} 的安装与 --agent ${AGENT_NAME} 是否生效" ;;
    *) DEGRADE_REASON="契约 JSON 顶层结构不符（$(tail -1 "$WORK/validate-err.log")）" ;;
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
  log "警告：结构化解析失败（${DEGRADE_REASON}），降级为贴出评审员输出原文"
  final_rc=0
  review_stream_final_text "$WORK/stream.jsonl" > "$WORK/final.txt" || final_rc=$?
  [[ "$final_rc" == "0" ]] || die_review "结构化解析失败，且取评审员原文也失败（rc=${final_rc}）"
  review_clean_text < "$WORK/final.txt" > "$WORK/raw.md"
  [[ -s "$WORK/raw.md" ]] || die_review "结构化解析失败，且评审员输出为空"
  review_render_degraded --text "$WORK/raw.md" --reason "$DEGRADE_REASON" "${render_args[@]}" \
    > "$WORK/comment.md" || die_review "降级评论渲染失败"
else
  dropped=$(jq -r '.dropped_findings' "$WORK/validated.json")
  delocated=$(jq -r '.delocated_findings' "$WORK/validated.json")
  [[ "$dropped" == "0" ]] \
    || log "警告：${dropped} 条问题不符合输出契约已丢弃（级别不在 P0/P1/P2，或缺 title/body）"
  [[ "$delocated" == "0" ]] \
    || log "警告：${delocated} 条问题的 file 含换行/竖线/反引号，已按未定位处理（这类值会破坏表格与定位串）"
  log "评审报告：P0 $(jq -r '[.findings[] | select(.severity == "P0")] | length' "$WORK/validated.json") · P1 $(jq -r '[.findings[] | select(.severity == "P1")] | length' "$WORK/validated.json") · P2 $(jq -r '[.findings[] | select(.severity == "P2")] | length' "$WORK/validated.json")，结论 $(jq -r '.verdict' "$WORK/validated.json")，丢弃 ${dropped}"
  # 行内评论必须在渲染汇总之前发（spec §4.5 把汇总排在第 8 步）：统计行里「其中 N 条已标注在
  # 对应行」只能是真的发出去的条数，折叠区也只能在知道哪些发失败之后才算得准。
  SUMMARY_JSON="$WORK/validated.json"
  if [[ "$INLINE_COMMENT" == "1" ]] && publish_inline_comments "$WORK/validated.json"; then
    SUMMARY_JSON="$WORK/plan.json"
  fi
  summary_args=(--inline-comment "$INLINE_ACTIVE")
  [[ -n "$INLINE_NOTICE" ]] && summary_args+=(--notice "$INLINE_NOTICE")
  review_render_summary --json "$SUMMARY_JSON" "${summary_args[@]}" "${render_args[@]}" \
    > "$WORK/comment.md" || die_review "汇总评论渲染失败"
fi
[[ -s "$WORK/comment.md" ]] || die_review "渲染后的评论为空"

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
