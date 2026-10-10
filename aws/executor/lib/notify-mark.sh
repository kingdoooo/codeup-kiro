#!/usr/bin/env bash
# 飞书通知要的「本次 Kiro 评论 id」（Phase 2c issue 20，spec「组件设计 · 锁记录新增字段」）——执行器（entrypoint.sh）用，只在 FEISHU_NOTIFY=1 时。
# 只有函数定义，source 时不执行任何动作。
#
# 引擎（scripts/kiro-review.sh）不告诉执行器它发出 / 更新了哪一条评论，而 scripts/ 两个档位共用、不因 AWS 而改（I9）。所以引擎之前记一份
# MR 全局评论的快照、引擎之后再取一份：之后那份里「快照里没有，或正文变了」的评论交给引擎同一个选择器（review_select_prior_comment：
# 作者 = 机器人账号 + 正文里恰好一个 kiro-review 标记，取 run 最大的）——选中的就是本次引擎发出或原地更新的汇总 / 失败评论（失败评论与
# 最小失败评论同样出自 review_render_comment_head，带同一族标记）。只比内容、不比时间戳：不依赖两边的时钟。
# 引擎没发评论（空 diff、MR 定位之前就失败）→ 没有变化 → 不写、不通知。找到了 → 锁记录上一次写入 posted_kiro 与 comment_kiro（mark_lock），
# 通知 Lambda 只认「posted_<评审员> 从无到有、且带合法 id」的那一次变化。任何一步失败只留一行日志，不改评审结果（N-F2）。
# 引擎的库在子 shell 里 source：不把它的变量与函数带进入口。读这些全局变量：PKG、WORKROOT、MR_LOCAL_ID、CODEUP_REPO_ID、YUNXIAO_ORG_ID、
# YUNXIAO_TOKEN、CODEUP_BOT_USERNAME（以及 mark_lock 读的 LOCK_KEY、LOCK_TABLE、AWS_REGION）。

# 每次最多 45 秒：这两次请求都在持有按 MR 的租约时发。Codeup 限流时 codeup-api.sh 自己的重试（3 次、每次 curl 最长 60 秒）最坏约 195 秒，
# 两次加起来会吃掉 lease_wait_limit 留给持有者的余量（约 260 秒，见 entrypoint.sh 租约那一段），排在后面的评审就会以 93 退出。
# 超时只少一条通知。子进程的环境里有 YUNXIAO_TOKEN / YUNXIAO_ORG_ID / CODEUP_REPO_ID（ECS 注入或调度器覆盖，都已导出）。
_notify_list_comments() {  # <输出文件> → rc 0 / 1
  /usr/bin/timeout 45 /bin/bash -p -c 'REVIEW_PROFILE=kiro; source "$1/scripts/lib/review-render.sh" \
      && source "$1/scripts/lib/codeup-api.sh" && codeup_list_global_comments "$2"' notify-list "$PKG" "$MR_LOCAL_ID" \
    > "$1" 2>/dev/null
}

# 引擎之前：MR 全局评论的快照。取不到 → 不留快照（之后那一步据此不通知）
notify_kiro_snapshot() {  # <快照文件>
  _notify_list_comments "$1" && return 0
  /bin/rm -f "$1"
  echo "notify-mark reviewer=kiro result=skipped code=list-before" >&2
  return 0
}

# 引擎之后：认出本次的 Kiro 评论，写进锁记录
notify_kiro_mark() {  # <快照文件>
  local before="$1" after="$WORKROOT/notify-after.json" cid
  [[ -s "$before" ]] || { echo "notify-mark reviewer=kiro result=skipped code=no-snapshot" >&2; return 0; }
  _notify_list_comments "$after" || { echo "notify-mark reviewer=kiro result=skipped code=list-after" >&2; return 0; }
  cid=$( ( REVIEW_PROFILE=kiro
           source "$PKG/scripts/lib/review-render.sh" || exit 1
           /usr/bin/jq -c --slurpfile b "$before" '
             def rows: (if type == "object" then (.result // []) else . end) | (if type == "array" then . else [] end)
                       | map(select(type == "object"));
             ($b[0] | rows | map({key: (.comment_biz_id | tostring), value: .content}) | from_entries) as $old
             | rows | map(select($old[(.comment_biz_id | tostring)] != .content))' "$after" \
             | review_select_prior_comment "${CODEUP_BOT_USERNAME:-}" | /usr/bin/jq -r '.comment_biz_id // ""' ) 2>/dev/null ) || cid=""
  if [[ "$cid" =~ ^[0-9a-f]{32}$ ]]; then
    mark_lock posted_kiro comment_kiro "$cid"
    echo "notify-mark reviewer=kiro result=ok" >&2
  else
    echo "notify-mark reviewer=kiro result=skipped code=no-comment" >&2
  fi
  return 0
}
