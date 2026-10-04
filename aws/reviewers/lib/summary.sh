#!/usr/bin/env bash
# 扫描员汇总评论的定位与发布（Phase 2b，spec「Task B」「I4」）。语义与 scripts/kiro-review.sh 的「1.5 定位本评审员上一次的
# 汇总评论」与 post_summary **逐条相同**——tests/test-aws-scan.sh 把 Kiro 那一段原样抽出来，与这里用同一批 fixture 跑、逐项比对
# 结果（PRIOR_COMMENT_ID / REVIEW_RUN / 读回的历史）。不改 kiro-review.sh（Flow 档位也在用它，I9），所以这里是第二份调用胶水，
# 由那条对拍测试保证不分叉；被它调用的全部原语（选择器、历史解析、掩码、截断、Codeup 请求）都是 scripts/lib 的同一份。
# 调用方先 source scripts/lib/review-render.sh（REVIEW_PROFILE 已设）与 codeup-api.sh，并定义 log 与 reviewer_fail；设好 WORK、LOCAL_ID。

# 定位本评审员上一次的汇总 → PRIOR_COMMENT_ID / PRIOR_HISTORY_FILE / REVIEW_RUN / BOT_USERNAME（全局）
summary_locate_prior() {
  local sel_rc prior_run _sel_line
  _SUMMARY_LOCATED=1
  PRIOR_COMMENT_ID=""; REVIEW_RUN=1; PRIOR_HISTORY_FILE=""
  if BOT_USERNAME=$(codeup_bot_username); then
    log "机器人账号用户名：${BOT_USERNAME}"
  else
    BOT_USERNAME=""
    log "未取得机器人账号用户名（CODEUP_BOT_USERNAME 未配置，令牌身份接口也不可用）：本次只能新建汇总评论，不做原地更新"
  fi
  if codeup_list_global_comments "$LOCAL_ID" > "$WORK/comments.json"; then
    sel_rc=0
    review_select_prior_comment "$BOT_USERNAME" < "$WORK/comments.json" > "$WORK/prior.json" 2> "$WORK/prior-select.log" || sel_rc=$?
    while IFS= read -r _sel_line || [[ -n "$_sel_line" ]]; do [[ -n "$_sel_line" ]] && log "$_sel_line"; done < "$WORK/prior-select.log"
    case "$sel_rc" in
      0) PRIOR_COMMENT_ID=$(jq -r '.comment_biz_id // ""' "$WORK/prior.json")
         prior_run=$(jq -r '.run // 1' "$WORK/prior.json")
         if [[ -z "$PRIOR_COMMENT_ID" ]]; then
           log "警告：旧汇总评论没有 comment_biz_id，无法原地更新，本次按新建处理"
         else
           jq -r '.content // ""' "$WORK/prior.json" > "$WORK/prior.md"
           PRIOR_HISTORY_FILE="$WORK/prior-history.json"
           # 历史标记来自上一条评论、人可手改：重发前先过一遍保行掩码（与 Kiro 同一理由，合并后复审第 4 条）
           review_parse_history "$WORK/prior.md" | review_redact_secrets --keep-lines > "$PRIOR_HISTORY_FILE" \
             || reviewer_fail "历史标记掩码失败（掩码程序不可用）"
           REVIEW_RUN=$((prior_run + 1))
           log "找到本评审员的旧汇总评论 ${PRIOR_COMMENT_ID}（上次为第 ${prior_run} 次评审，读回历次记录 $(jq -r 'length' "$PRIOR_HISTORY_FILE") 行），本次原地更新为第 ${REVIEW_RUN} 次"
         fi ;;
      3) log "未配置 CODEUP_BOT_USERNAME，本次新建汇总评论" ;;
      *) log "未找到本评审员的旧汇总评论，本次新建（第 ${REVIEW_RUN} 次评审）" ;;
    esac
  else
    log "警告：查询 MR 全局评论失败，本次按新建处理（可能在 MR 上留下第二条汇总）"
  fi
}

# 发布：有旧评论就原地更新，更新失败退回新建（与 kiro-review.sh 的 post_summary 相同；空正文硬拒绝）
summary_post() {  # <评论文件>
  local file="$1"
  [[ -s "$file" ]] || { log "错误：待发布的评论正文为空，拒绝回写（空正文会把上一条汇总覆盖成空白）"; return 1; }
  if [[ -n "$PRIOR_COMMENT_ID" ]]; then
    if codeup_update_comment "$LOCAL_ID" "$PRIOR_COMMENT_ID" "$file"; then
      log "已原地更新汇总评论 ${PRIOR_COMMENT_ID}（第 ${REVIEW_RUN} 次评审）"
      return 0
    fi
    log "警告：原地更新汇总评论 ${PRIOR_COMMENT_ID} 失败（已按既有重试策略处理），退回新建"
  fi
  codeup_post_comment "$LOCAL_ID" "$file" "${BOT_USERNAME:-}"
}

# 文档级兜底掩码 + 截断（顺序与 kiro-review.sh 第 7 步相同：先掩码、后截断）。rc 0 = 可以发；其余 = 不得发（调用方走失败评论）。
summary_finalize() {  # <评论文件>
  local file="$1" rrc=0
  review_redact_file "$file" || rrc=$?
  [[ "$rrc" == 0 ]] || { log "错误：评论掩码失败或结构守卫拒绝写回（rc=${rrc}）"; return 1; }
  if [[ "$(wc -c < "$file" | tr -d ' ')" -gt "${MAX_COMMENT_BYTES:-60000}" ]]; then
    review_truncate_comment "$file" "${MAX_COMMENT_BYTES:-60000}" || { log "错误：评论截断失败"; return 1; }
    log "评论超长已截断"
  fi
}
