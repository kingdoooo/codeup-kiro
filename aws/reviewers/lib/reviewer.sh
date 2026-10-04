#!/usr/bin/env bash
# 扫描员子进程的公共骨架（Phase 2b，spec「Task B」「L7」「F3」）。每位扫描员的驱动（aws/reviewers/<评审员>.sh）先设好
# PKG 与 REVIEW_PROFILE，再 source 本文件；然后依次调 reviewer_lease_and_check → summary_locate_prior → 自己的工作 →
# reviewer_publish（或 reviewer_fail）。
# 退出码约定（scan-entrypoint.sh 据此置锁记录标记）：0 = 已回写（汇总或本评审员的失败评论）；10 = 被新推送取代（安静）；
# 其它 = 没有终态（兜底 Lambda 以本评审员的机器人回写）。
# 由 scan-entrypoint.sh 给的环境：YUNXIAO_TOKEN（只有本评审员的那一个，S2）、CODEUP_BOT_USERNAME、REVIEW_RERUN_HINT、REVIEWER_WORKDIR，
# 以及任务的 CODEUP_REPO_ID / MR_LOCAL_ID / HEAD_SHA / CI_COMMIT_REF_NAME / MR_TARGET_BRANCH / LOCK_KEY / SCAN_RUN_ID / SCAN_REPO_URL /
# YUNXIAO_ORG_ID / LOCK_TABLE / AWS_REGION / ECS_CONTAINER_METADATA_URI_V4。
: "${PKG:?驱动必须先设 PKG}" "${REVIEW_PROFILE:?驱动必须先设 REVIEW_PROFILE}"
source "$PKG/scripts/lib/review-render.sh"
source "$PKG/scripts/lib/codeup-api.sh"
source "$PKG/scripts/lib/git-retry.sh"
source "$PKG/lib/lease.sh"
source "$PKG/reviewers/lib/summary.sh"

REVIEWER_ID="$REVIEW_PROFILE"
WORK="${REVIEWER_WORKDIR:?缺少 REVIEWER_WORKDIR}"
LOCAL_ID="$MR_LOCAL_ID"
SHORT_SHA="${HEAD_SHA:0:7}"
log() { echo "[${REVIEWER_ID}] $*" >&2; }
# 还没定位过上一条汇总时的初值（set -u 下 summary_post 要读它们）
PRIOR_COMMENT_ID=""; PRIOR_HISTORY_FILE=""; REVIEW_RUN=1; BOT_USERNAME=""

# 本评审员的失败评论（同一渲染器、同一标记族）。固定文案 + 枚举代号（F3）：调用方不得把服务端自由文本拼进来。
# 发出去 → exit 0（这也是终态：MR 上有这位评审员自己的说明）；发不出去 → exit 1（兜底接手）。
reviewer_fail() {  # <固定文案>
  local f hist_args=() rrc=0
  log "错误：$1"
  # 还没定位过上一条汇总（租约那一步就失败了）：先定位，失败评论才能原地更新**那一条**，而不是在 MR 上多出一条（I4）。
  # summary_locate_prior 自己失败时会再调 reviewer_fail——_SUMMARY_LOCATED 在它开头就置位，不会递归。
  [[ "${_SUMMARY_LOCATED:-0}" == 1 ]] || summary_locate_prior
  f=$(mktemp)
  [[ -n "${PRIOR_HISTORY_FILE:-}" ]] && hist_args=(--history "$PRIOR_HISTORY_FILE")
  review_render_failure --reason "$1" --sha "$SHORT_SHA" --src "$CI_COMMIT_REF_NAME" --dst "${MR_TARGET_BRANCH:-?}" \
    --ts "$(date '+%Y-%m-%d %H:%M:%S')" --diff-note "${REVIEW_META_NOTE:-—}" --run "${REVIEW_RUN:-1}" \
    "${hist_args[@]+"${hist_args[@]}"}" --log-hint "扫描任务的日志在 CloudWatch（执行器日志组，流前缀 scan/）。" > "$f" || true
  [[ -s "$f" ]] || { log "失败评论渲染异常，改用最小失败评论"; _reviewer_minimal "$1" > "$f"; }
  review_redact_file "$f" || rrc=$?
  [[ "$rrc" == 0 ]] || _reviewer_minimal "" > "$f"
  if summary_post "$f"; then exit 0; fi
  log "回写失败评论也未成功，仅保留日志"
  exit 1
}
# 最小失败评论：仍带评论头（下一次才找得到这一条）与页脚；原因为空时只写固定文案（掩码失败时不带任何可能未掩的取值）
_reviewer_minimal() {  # <原因或空>
  local mh; mh=$(mktemp)
  review_history_for_run "${PRIOR_HISTORY_FILE:--}" "${REVIEW_RUN:-1}" "$SHORT_SHA" failed reviewer_fail > "$mh"
  review_render_comment_head "$REVIEW_TITLE_FAILED" "$SHORT_SHA" "${REVIEW_RUN:-1}" "$mh"
  echo ""
  if [[ -n "$1" ]]; then printf '⚠️ 评审未完成：'; _review_sanitize_oneline "$1"; echo ""
  else echo "⚠️ 评审未完成（脚本侧掩码不可用，为避免泄漏只保留固定文案；原因见扫描任务日志）。"; fi
  echo ""
  review_render_footer "${REVIEW_RUN:-1}"
  rm -f "$mh"
}

# 发布本评审员的汇总：掩码、截断、原地更新或新建。成功 exit 0；不能发 → 失败评论。
reviewer_publish() {  # <评论文件>
  [[ -s "$1" ]] || reviewer_fail "渲染后的评论为空"
  summary_finalize "$1" || reviewer_fail "评论掩码或截断失败"
  if summary_post "$1"; then log "已回写 MR #${LOCAL_ID}"; exit 0; fi
  log "OpenAPI 回写失败（已按策略重试）"
  exit 1
}

# L7：按评审员按 MR 的租约（键 lease#<仓库>#<MR>#<评审员>，与 Kiro 的 lease#<仓库>#<MR>、抢锁键都不相交）+ 核对最新提交。
# 被取代 → exit 10（安静）。等租约超过 REVIEWER_LEASE_WAIT 秒 → 先再核对一次（排在后面的旧任务多半已被取代），否则失败评论。
# 拿到租约后挂 EXIT 陷阱：先停续期循环、再释放（L6，与 entrypoint 同一顺序）。
reviewer_lease_and_check() {
  local task_meta task_arn deadline waiting=0 lrc
  LEASE_TTL=120; LEASE_RENEW_EVERY=30
  lease_key=$(jq -cn --arg k "lease#${CODEUP_REPO_ID}#${MR_LOCAL_ID}#${REVIEWER_ID}" '{pk: {S: $k}}')
  task_meta=$(/usr/bin/curl -sf --max-time 10 "${ECS_CONTAINER_METADATA_URI_V4}/task" || true)
  task_arn=$(printf '%s' "$task_meta" | jq -r '.TaskARN // empty' 2>/dev/null || true)
  [[ "$task_arn" =~ ^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:task/[A-Za-z0-9_/-]+$ ]] \
    || reviewer_fail "读不到扫描任务的 ARN（ECS 任务级元数据端点），无法确定评审租约的持有者"
  lease_me="${LOCK_KEY}|${task_arn}|${REVIEWER_ID}"
  # head_check_superseded 要一个能 ls-remote origin 的目录：空仓库 + origin = 执行器核对过的地址；凭证与 entrypoint 同一手法
  # （按 URL 限定的 credential helper，令牌只在 helper 回调时从环境读，单引号承重——见 entrypoint.sh）。
  LEASE_GIT_DIR="$WORK/remote"
  /usr/bin/git init -q "$LEASE_GIT_DIR" && /usr/bin/git -C "$LEASE_GIT_DIR" remote add origin "$SCAN_REPO_URL" \
    || reviewer_fail "准备核对最新提交用的本地仓库失败"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0='credential.https://codeup.aliyun.com.helper'
  export GIT_CONFIG_VALUE_0='!f() { echo "username=oauth2"; echo "password=$YUNXIAO_TOKEN"; }; f'
  deadline=$(( $(/bin/date +%s) + ${REVIEWER_LEASE_WAIT:-900} ))
  while :; do
    lrc=0; lease_acquire || lrc=$?
    [[ "$lrc" == 0 ]] && break
    [[ "$lrc" == 1 ]] || reviewer_fail "读写评审租约失败（code=${lease_err}）"
    if (( $(/bin/date +%s) >= deadline )); then
      if head_check_superseded; then exit 10; fi
      reviewer_fail "等待同一 MR 的上一次评审超过 ${REVIEWER_LEASE_WAIT:-900} 秒仍未结束"
    fi
    [[ "$waiting" == 1 ]] || { log "同一 MR 的上一次评审仍在进行，等待租约"; waiting=1; }
    /bin/sleep 10
  done
  lease_renewer_pid=""
  trap '_reviewer_lease_exit' EXIT
  lease_renew_loop &
  lease_renewer_pid=$!
  if head_check_superseded; then exit 10; fi
}
_reviewer_lease_exit() {
  if [[ -n "${lease_renewer_pid:-}" ]]; then
    kill "$lease_renewer_pid" 2>/dev/null || true
    wait "$lease_renewer_pid" 2>/dev/null || true
  fi
  lease_release
}
