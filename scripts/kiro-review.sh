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
MAX_COMMENT_BYTES="${MAX_COMMENT_BYTES:-60000}"
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
      review_history_append - "$REVIEW_RUN" "${SHORT_SHA:-unknown}" "" failed - - - > "$mh" 2>/dev/null || true
      _review_history_ok "$mh" die_review 2>/dev/null || printf '[]\n' > "$mh"
      {
        echo "## 🤖 Kiro 代码评审 · ⚠️ 评审未完成"
        echo "<!-- kiro-review:${SHORT_SHA:-unknown} run:${REVIEW_RUN} -->"
        review_render_history_marker "$mh"
        echo ""
        echo "⚠️ 评审未完成（失败评论渲染异常，只保留最小信息）：$*"
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
  local pair from_ps to_ps to_commit head_full existing_fp
  local item idx file ls title fp cid n_created=0 n_existing=0 n_failed=0 submitted=0

  # 1. 版本对（spec §4.5 第 1 步、Q6）
  if ! codeup_list_patchsets "$LOCAL_ID" > "$WORK/patchsets.json"; then
    INLINE_NOTICE="行内评论未发出：查询 MR 版本列表失败（HTTP ${CODEUP_HTTP_CODE}），下面是完整问题清单。"
    log "警告：${INLINE_NOTICE}"
    return 1
  fi
  if ! pair=$(codeup_select_patchset_pair < "$WORK/patchsets.json"); then
    INLINE_NOTICE="行内评论未发出：MR 版本列表里选不出「最新合并目标版本 + 最新合并源版本」这一对，下面是完整问题清单。"
    log "警告：${INLINE_NOTICE}"
    return 1
  fi
  from_ps=$(printf '%s' "$pair" | cut -f1)
  to_ps=$(printf '%s' "$pair" | cut -f2)
  to_commit=$(printf '%s' "$pair" | cut -f3)
  log "行内评论版本对：from=${from_ps}（最新合并目标版本）→ to=${to_ps}（最新合并源版本，patchset_biz_id 用它）"
  head_full=$(git rev-parse HEAD)
  # 不一致的成因通常是「评审开始后又推了一次」：Codeup 侧的版本才是评论要绑的真值，所以不改用 HEAD，
  # 但必须留痕——此时行号是按本次评审的 diff 算的，可能与那个版本对不上。
  if [[ -n "$to_commit" && "$to_commit" != "$head_full" ]]; then
    log "警告：最新合并源版本的提交（${to_commit:0:12}）与当前 HEAD（${head_full:0:12}）不一致——仍以 API 给的版本为准（Codeup 侧真值），但行号可能对不上这次评审的 diff"
  fi

  # 2/3/4. 变更行集合 → 可定位判定 → 排序与档位 → 上限截取
  if ! review_plan_inline --json "$validated" --changed-lines "$WORK/changed-lines.json" \
         --profile "$INLINE_PROFILE" --max "$MAX_INLINE_COMMENTS" > "$WORK/plan.json"; then
    INLINE_NOTICE="行内评论未发出：生成行内发布计划失败，下面是完整问题清单。"
    log "警告：${INLINE_NOTICE}"
    return 1
  fi

  # 5. 去重：拉现有行内评论，按正文里的指纹标记跳过
  existing_fp="$WORK/existing-fp.txt"
  : > "$existing_fp"
  if [[ -z "${BOT_USERNAME:-}" ]]; then
    log "警告：未配置 CODEUP_BOT_USERNAME（令牌身份接口也不可用——P1-00 实测 403），行内评论去重无法按作者过滤，只能按评论正文里的指纹标记去重。重跑仍不会重复，但任何 MR 参与者发一条带同样指纹标记的评论就能让对应问题不再发出。建议配置该变量"
  fi
  if codeup_list_inline_comments "$LOCAL_ID" > "$WORK/inline-comments.json"; then
    review_inline_existing_fingerprints "${BOT_USERNAME:-}" < "$WORK/inline-comments.json" > "$existing_fp" \
      || : > "$existing_fp"
    log "行内评论去重：MR 上已有 $(grep -c . "$existing_fp" || true) 条带指纹标记的行内评论"
  else
    log "警告：查询 MR 现有行内评论失败（HTTP ${CODEUP_HTTP_CODE}），本次跳过去重（重跑可能在同一行上留下重复评论）"
  fi

  # 6. 逐条创建草稿
  : > "$WORK/draft-ids.txt"; : > "$WORK/drafted.tsv"; : > "$WORK/outcomes.tsv"
  while IFS= read -r item; do
    printf '%s' "$item" > "$WORK/item.json"
    idx=$(jq -r '.idx' "$WORK/item.json")
    file=$(jq -r '.file' "$WORK/item.json")
    ls=$(jq -r '.line_start' "$WORK/item.json")
    title=$(jq -r '.title' "$WORK/item.json")
    if ! fp=$(review_fingerprint "$file" "$ls" "$title"); then
      log "警告：算不出问题 #${idx} 的去重指纹，转入折叠区（宁可不发，也不发一条重跑会重复的评论）"
      printf '%s\tfailed\n' "$idx" >> "$WORK/outcomes.tsv"; n_failed=$((n_failed + 1)); continue
    fi
    if grep -qxF "$fp" "$existing_fp"; then
      # 已经挂在那一行上了：算「已标注」而不是折叠区，否则同一条问题在 MR 上出现两次（I4）
      printf '%s\texisting\n' "$idx" >> "$WORK/outcomes.tsv"; n_existing=$((n_existing + 1)); continue
    fi
    if ! review_render_inline_body "$WORK/item.json" "$SHORT_SHA" "$fp" > "$WORK/body-${idx}.md"; then
      log "警告：问题 #${idx} 的行内评论正文渲染失败，转入折叠区"
      printf '%s\tfailed\n' "$idx" >> "$WORK/outcomes.tsv"; n_failed=$((n_failed + 1)); continue
    fi
    # 必须用文件式接口而不是 `cid=$(codeup_create_inline_comment …)`：命令替换在子 shell 里跑，
    # CODEUP_HTTP_CODE 与 DRY_RUN 的 fixture 序号都传不回来（codeup-api.sh 里写明了这条约定）
    if codeup_create_inline_comment "$LOCAL_ID" "$WORK/body-${idx}.md" "$file" "$ls" \
         "$from_ps" "$to_ps" true "$WORK/created.json"; then
      cid=$(codeup_comment_biz_id "$WORK/created.json")
      if [[ -n "$cid" ]]; then
        printf '%s\n' "$cid" >> "$WORK/draft-ids.txt"
        printf '%s\t%s\t%s\t%s\n' "$idx" "$cid" "$file" "$ls" >> "$WORK/drafted.tsv"
      else
        log "警告：问题 #${idx} 的草稿建好了但响应里没有 comment_biz_id，无法纳入一次提交，转入折叠区（那条草稿只有机器人自己看得见，需人工清理）"
        printf '%s\tfailed\n' "$idx" >> "$WORK/outcomes.tsv"; n_failed=$((n_failed + 1))
      fi
    else
      log "警告：问题 #${idx} 的行内评论草稿创建失败（HTTP ${CODEUP_HTTP_CODE}），转入折叠区"
      printf '%s\tfailed\n' "$idx" >> "$WORK/outcomes.tsv"; n_failed=$((n_failed + 1))
    fi
  done < <(jq -c '.inline[]' "$WORK/plan.json")

  # 7. 一次提交（不带 reviewOpinion）；失败则退回逐条非草稿发布
  if [[ -s "$WORK/draft-ids.txt" ]]; then
    if codeup_submit_drafts "$LOCAL_ID" "$WORK/draft-ids.txt"; then
      submitted=1
      log "行内评论：$(grep -c . "$WORK/draft-ids.txt" || true) 条草稿已一次提交（不带评审意见，不卡合并）"
    else
      log "警告：草稿一次提交失败（HTTP ${CODEUP_HTTP_CODE}），退回逐条非草稿发布"
      # 先删掉已建的草稿：不删的话同一条问题会同时留下一条草稿（只有机器人自己看得见）
      # 与一条正式评论，而下一次评审看到的是同一个指纹，两条都不会被清理
      while IFS=$'\t' read -r idx cid file ls; do
        codeup_delete_comment "$LOCAL_ID" "$cid" \
          || log "警告：删除草稿 ${cid} 失败（HTTP ${CODEUP_HTTP_CODE}），需人工清理该草稿"
      done < "$WORK/drafted.tsv"
      while IFS=$'\t' read -r idx cid file ls; do
        if codeup_create_inline_comment "$LOCAL_ID" "$WORK/body-${idx}.md" "$file" "$ls" \
             "$from_ps" "$to_ps" false "$WORK/created.json"; then
          n_created=$((n_created + 1)); printf '%s\tcreated\n' "$idx" >> "$WORK/outcomes.tsv"
        else
          log "警告：问题 #${idx} 的非草稿回退发布也失败（HTTP ${CODEUP_HTTP_CODE}），转入折叠区"
          n_failed=$((n_failed + 1)); printf '%s\tfailed\n' "$idx" >> "$WORK/outcomes.tsv"
        fi
      done < "$WORK/drafted.tsv"
    fi
  fi
  if [[ "$submitted" == "1" ]]; then
    while IFS=$'\t' read -r idx cid file ls; do
      n_created=$((n_created + 1)); printf '%s\tcreated\n' "$idx" >> "$WORK/outcomes.tsv"
    done < "$WORK/drafted.tsv"
  fi

  # 发布结果回填：发失败的问题必须落到折叠区，否则它在 MR 上一条都看不到
  jq -Rs --arg sep "$(printf '\t')" '
    split("\n") | map(select(length > 0) | split($sep) | {idx: (.[0] | tonumber), outcome: .[1]})' \
    "$WORK/outcomes.tsv" > "$WORK/outcomes.json" 2>/dev/null || printf '[]\n' > "$WORK/outcomes.json"
  if ! review_plan_apply_outcomes "$WORK/plan.json" "$WORK/outcomes.json" > "$WORK/plan.final.json"; then
    # 回填算不出来时不能拿未回填的计划去渲染：那会把发失败的问题算成「已标注在对应行」而彻底藏起来。
    # 回落到完整清单：已经发出去的行内评论会与清单里的条目重复一次，但没有任何问题被藏起来。
    INLINE_NOTICE="行内评论已发出，但统计口径回填失败，因此下面仍给出完整问题清单（可能与行内评论重复）。"
    log "警告：${INLINE_NOTICE}"
    return 1
  fi
  mv "$WORK/plan.final.json" "$WORK/plan.json"
  log "行内评论：新发 ${n_created} 条、已存在跳过 ${n_existing} 条、失败 ${n_failed} 条；折叠区 $(jq -r '.folded_count' "$WORK/plan.json") 条（档位 $(jq -r '.inline_profile' "$WORK/plan.json")，上限 $(jq -r '.max_inline' "$WORK/plan.json")）"
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
INSTALLED_AGENT=$(kiro_install_agent "$AGENT_FILE" "$HOME/.kiro/agents") || die_review "受信 agent 安装失败：$AGENT_FILE"
AGENT_NAME=$(basename "$INSTALLED_AGENT" .json)
log "已安装受信 custom agent：${AGENT_NAME}（${INSTALLED_AGENT}；includeMcpJson=false，includePowers=false）"
# --help 在集成包目录下执行：此刻业务库工作树尚未隔离，不在其中运行任何 kiro-cli 子命令
KIRO_CHAT_HELP=$(cd "$PKG_ROOT" && "$TIMEOUT_BIN" 60 kiro-cli chat --help 2>&1 || true)
grep -q -- '--agent-engine' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --agent-engine，无法钉死 ${KIRO_ENGINE} 引擎（ADR-0004：默认引擎不阻断 AGENTS.md 注入），拒绝运行。请升级 kiro-cli（≥ 2.21）"
grep -qE -- '(^|[[:space:]])--agent([[:space:]]|$)' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --agent，无法套用受信只读 agent（拒绝路径、无 MCP/shell/write/web），拒绝运行。请升级 kiro-cli"
# 结构化输出契约完全依赖 stream-json（报告从 runFinished.data.finalText 取）。不预检的话，
# 不支持该参数的版本会先把额度烧掉、再以 clap 退出码 2 失败，MR 上只剩「退出码 2」这种不可行动的信息。
grep -q -- '--output-format' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --output-format，无法取得结构化评审报告（契约在 runFinished.data.finalText 里），拒绝运行。请升级 kiro-cli（≥ 2.21）"
# 开关校验放在 MR 定位之后：配错开关也要在 MR 上看得见，而不是只让流水线标红
[[ "$INLINE_COMMENT" == "0" || "$INLINE_COMMENT" == "1" ]] \
  || die_review "INLINE_COMMENT=${INLINE_COMMENT} 不是 0 或 1。行内评论开关只接受这两个取值（静默按 0 跑会让开关看起来生效了）。请修正该流水线变量"
# 去重指纹要 sha1：拿不到就没法去重，重跑会在同一行上堆重复评论（违反 I6 幂等）。
# 与 timeout 同理列为硬依赖，而不是「取不到就不去重」。
if [[ "$INLINE_COMMENT" == "1" ]]; then
  command -v sha1sum >/dev/null || command -v shasum >/dev/null \
    || die_review "INLINE_COMMENT=1 需要 sha1sum 或 shasum 计算行内评论去重指纹（缺了会在重跑时发重复评论）。请在构建机安装 coreutils 或 perl"
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
if [[ ! -s "$WORK/review.diff" && ! -s "$WORK/omitted.txt" ]]; then
  log "diff 为空，跳过评审。"
  exit 0
fi
log "diff 已生成：$(wc -c < "$WORK/review.diff" | tr -d ' ') 字节（merge-base ${BASE:0:12}..HEAD，$([[ "$truncated" == "10" ]] && echo 已按阈值截断 || echo 完整直传)）"

# --- 4.5 变更行集合（spec §4.5 第 2 步）---
# 放在这里而不是发布前：读的是 git 对象（与评审输入同源），且必须在隔离步骤删工作树文件之前
# 就算出来，才能保证「行内评论的行号」与「喂给评审员的 diff」出自同一次比较。
# 零上下文（-U0）：只要新增/修改行，不要上下文行——上下文行没改过，把评论挂上去是噪音。
# core.quotePath=false：非 ASCII 路径不被转义，键名就是真实路径。
if [[ "$INLINE_COMMENT" == "1" ]]; then
  git -c core.quotePath=false diff --no-renames -U0 "$BASE" HEAD > "$WORK/inline.diff" \
    || die_review "生成零上下文 diff 失败（行内评论要靠它算变更行集合）"
  review_changed_lines < "$WORK/inline.diff" > "$WORK/changed-lines.json" \
    || die_review "解析变更行集合失败"
  jq -e 'type == "object"' "$WORK/changed-lines.json" >/dev/null 2>&1 \
    || die_review "变更行集合不是合法 JSON 对象（行号校验完全依赖它，宁可失败也不能把评论发到错的行上）"
  log "变更行集合：$(jq -r 'length' "$WORK/changed-lines.json") 个文件、$(jq -r '[.[][] | (.[1] - .[0] + 1)] | add // 0' "$WORK/changed-lines.json") 行可定位"
fi

# --- 5. 组装评审输入 ---
{
  echo "=== 变更元信息 ==="
  echo "源分支: ${SOURCE_BRANCH}"
  echo "目标分支: ${TARGET_BRANCH}"
  echo "Commit: $(git rev-parse HEAD)"
  if [[ "$truncated" == "10" ]]; then
    echo ""
    echo "=== 未直传的变更文件索引（每项 => 后为该文件完整 diff 的本地路径，请用 read 工具读取）==="
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
log "隔离：已移除业务库工作树中 $(wc -l < "$WORK/removed-agents-md.txt" | tr -d ' ') 个 AGENTS.md、$(wc -l < "$WORK/removed-kiro-dirs.txt" | tr -d ' ') 个 .kiro/（均任意深度）与根 lsp.json"
# 执行环境：禁止 Kiro 继承工作区默认资源（AGENTS.md/README.md 等），只对 v2 引擎有效（ADR-0004）。
# 它依赖上面对 .kiro/ 的删除（见 ①），本身只覆盖「AGENTS.md 没删干净 / 藏在别处」这一种漏网情形。
# 写入的是执行器 $HOME 的全局设置且刻意不回滚（spec I1）：常驻构建机上它保持为 true 只会更严格。
"$TIMEOUT_BIN" 60 kiro-cli settings chat.disableInheritingDefaultResources true || die_review "隔离失败：无法设置 kiro-cli chat.disableInheritingDefaultResources=true"
log "隔离：已设置 chat.disableInheritingDefaultResources=true"

# --- 6. 执行 Kiro headless 评审（强制超时）---
# --trust-tools 用 V2 短名（read/grep/glob）：kiro-cli 对未知名字静默接受，所以名字靠实测而非 --help
# （--help 示例里的 fs_read/fs_write 已过期：--trust-tools=fs_write 不生效，=write 生效）。三个名字都在 v2
# stream-json 事件的 _meta.kiro.toolName 里实证过（probe-results/kiro-headless/kiro-probe-t01-v2-iso、
# kiro-probe-t01r-toolnames、kiro-probe-t01r-trusttools）。
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
log "开始 Kiro 评审（超时 ${KIRO_TIMEOUT}s，输出格式 stream-json）……"
kiro_rc=0
KIRO_LOG_NO_COLOR=1 "$TIMEOUT_BIN" -k 30 "$KIRO_TIMEOUT" kiro-cli chat --no-interactive \
  --agent-engine "$KIRO_ENGINE" --output-format stream-json \
  --trust-tools=read,grep,glob --agent "$AGENT_NAME" \
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
