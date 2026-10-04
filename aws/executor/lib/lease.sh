#!/usr/bin/env bash
# 按 MR（或按评审员按 MR）的租约与「核对最新提交」——执行器（entrypoint.sh）与扫描任务（scan-entrypoint.sh）共用（Phase 2b L7）。
# 只有函数定义，source 时不执行任何动作。不变式 L1–L6 与设计理由见 entrypoint.sh 租约那一段开头的注释。
# 调用方在调用之前设好：lease_key（`{pk: {S: …}}` 的 JSON）、lease_me（持有者标识）、LEASE_TTL、LEASE_RENEW_EVERY、LOCK_TABLE、
# AWS_REGION、HEAD_SHA、CI_COMMIT_REF_NAME、CODEUP_REPO_ID、MR_LOCAL_ID；head_check_superseded 还要一个能 ls-remote origin 的
# git 目录：LEASE_GIT_DIR，缺省 $WORKROOT/business（执行器 clone 出来的业务库）。
# lease_acquire 失败时把错误代号写进全局 lease_err。

# AWS CLI 报错里的错误码（固定枚举，`An error occurred (<代号>) when calling …`），不打错误正文：正文带表 ARN 与
# 账号 ID。连不上端点之类没有代号的错误记成 unknown。
aws_err_code() {
  if [[ "$1" =~ An\ error\ occurred\ \(([A-Za-z]+)\) ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf unknown; fi
}
# 返回 0 = 拿到；1 = 别人持有（ConditionalCheckFailedException）；2 = 别的错误（代号放进 lease_err）。
# 每次写都带 expires_at（N4：锁表里不许有不带 TTL 的记录）。
lease_acquire() {
  local now until_ts err
  now=$(/bin/date +%s); until_ts=$((now + LEASE_TTL))
  if err=$(/usr/local/bin/aws dynamodb update-item --region "$AWS_REGION" \
        --table-name "$LOCK_TABLE" --key "$lease_key" \
        --condition-expression 'attribute_not_exists(pk) OR #u < :now OR #h = :me' \
        --update-expression 'SET #h = :me, #u = :until, #e = :exp' \
        --expression-attribute-names '{"#h":"holder","#u":"lease_until","#e":"expires_at"}' \
        --expression-attribute-values "$(/usr/bin/jq -cn --arg me "$lease_me" --arg now "$now" \
          --arg until "$until_ts" --arg exp "$((until_ts + 86400))" \
          '{":me":{S:$me},":now":{N:$now},":until":{N:$until},":exp":{N:$exp}}')" \
        2>&1 >/dev/null); then
    return 0
  fi
  if [[ "$err" == *ConditionalCheckFailedException* ]]; then return 1; fi
  lease_err=$(aws_err_code "$err")
  return 2
}
# 续期循环（后台跑）：**先立刻续一次**，之后每 LEASE_RENEW_EVERY 秒以「持有者还是我」为条件把 lease_until 续到
# now + LEASE_TTL。先续一次是因为拿租约那次调用用的是 CLI 缺省超时：它慢慢成功时，租约可能已经所剩无几（复审 Minor）。
# 单独用短的 CLI 超时：CLI 缺省连接/读各 60 秒、共 3 次，一次续期就可能比租期还长；这样最坏约 25 秒。
# 条件失败 = 已被接管（我续期失败了太久）：停止续期、引擎照跑——中途杀掉评审只会留下半截评论，
# 并发是加租约之前的行为，不会更糟。别的错误（限流等）打代号、下一轮再试。
lease_renew_loop() {
  local now until_ts err
  while :; do
    now=$(/bin/date +%s); until_ts=$((now + LEASE_TTL))
    if err=$(/usr/local/bin/aws dynamodb update-item --cli-connect-timeout 2 --cli-read-timeout 5 \
          --region "$AWS_REGION" --table-name "$LOCK_TABLE" --key "$lease_key" \
          --condition-expression '#h = :me' \
          --update-expression 'SET #u = :until, #e = :exp' \
          --expression-attribute-names '{"#h":"holder","#u":"lease_until","#e":"expires_at"}' \
          --expression-attribute-values "$(/usr/bin/jq -cn --arg me "$lease_me" \
            --arg until "$until_ts" --arg exp "$((until_ts + 86400))" \
            '{":me":{S:$me},":until":{N:$until},":exp":{N:$exp}}')" \
          2>&1 >/dev/null); then
      :
    elif [[ "$err" == *ConditionalCheckFailedException* ]]; then
      echo "MR 租约已被别的任务接管，停止续期（本次评审照常跑完，可能与接管者并发）" >&2; return 0
    else
      echo "续期 MR 租约失败（code=$(aws_err_code "$err")），下一轮再试" >&2
    fi
    /bin/sleep "$LEASE_RENEW_EVERY"
  done
}
# 释放 = lease_until 清零**并抹掉持有者**，条件是持有者还是我（L3）：我挂住期间被接管的话，这一步什么也不写。
# 抹掉持有者是 L6 承重的：被 kill 的续期循环可能留下一个正在路上的 aws 调用，它晚于释放到达时条件
# `#h = :me` 必然失败，不会把已释放的租约续活。
lease_release() {
  /usr/local/bin/aws dynamodb update-item --region "$AWS_REGION" \
    --table-name "$LOCK_TABLE" --key "$lease_key" \
    --condition-expression '#h = :me' \
    --update-expression 'SET #u = :zero REMOVE #h' \
    --expression-attribute-names '{"#h":"holder","#u":"lease_until"}' \
    --expression-attribute-values "$(/usr/bin/jq -cn --arg me "$lease_me" \
      '{":me":{S:$me},":zero":{N:"0"}}')" >/dev/null 2>&1 || true
}
# 核对源分支的最新提交（L5）：打一行 `head-check result=…`，本任务已被取代时返回 0，其余返回 1（照常评审）。
# 等租约期间源分支可能又被推过。最新提交不是 HEAD_SHA、**且**调度器已经为它抢过锁（有新任务在路上
# 或已经评过），这个任务就被取代了：退出 0、不发任何评论（退出 0 兜底 Lambda 也不吭声），由新任务
# 评审最新提交。新提交**没有**抢锁记录（那次投递丢了，比如撞上 503）时照常评自己的提交——
# 否则最新的推送就没人评了。ls-remote 或读抢锁记录失败时同样照常评审：退化成加租约之前的行为。
# ls-remote 经上面导出的凭证 helper 访问 origin（即按仓库 id 查到、过了检查的那个地址），不需要任何新 API；
# 包在 30 秒上限里（issue 04：挂住的连接会让任务永远不结束），超时同样算「核对未知」；撞上 429 按 issue 03 重试——
# 限流下核对失败会让本任务照常评审旧提交，那正是会把汇总评论改回旧结论的场景。
# 新提交的抢锁键是调度器 lock_key() 对 MR 事件的形状（仓库#MR#提交，不带评论 id）；
# aws/tests/test_lock_key_contract.py 用真实的 lock_key() 核对这一行，两边不会各写各的。
head_check_superseded() {
  local ls_out tip="" ls_sha ls_ref tip_key claim_rc=0 claim_out claim_pk
  ls_out=$(retry_git_429 /usr/bin/timeout 30 /usr/bin/git -C "${LEASE_GIT_DIR:-$WORKROOT/business}" ls-remote origin \
           "refs/heads/${CI_COMMIT_REF_NAME}" 2>/dev/null) || ls_out=""
  while IFS=$'\t' read -r ls_sha ls_ref; do
    if [[ "$ls_ref" == "refs/heads/${CI_COMMIT_REF_NAME}" ]]; then tip="$ls_sha"; fi
  done <<< "$ls_out"
  if [[ ! "$tip" =~ ^[0-9a-f]{40}$ ]]; then
    echo "head-check result=unknown sha=${HEAD_SHA:0:7}" >&2; return 1
  fi
  if [[ "$tip" == "$HEAD_SHA" ]]; then
    echo "head-check result=current sha=${HEAD_SHA:0:7}" >&2; return 1
  fi
  tip_key="${CODEUP_REPO_ID}#${MR_LOCAL_ID}#${tip}"
  claim_out=$(/usr/local/bin/aws dynamodb get-item --region "$AWS_REGION" \
      --table-name "$LOCK_TABLE" --consistent-read --projection-expression pk \
      --key "$(/usr/bin/jq -cn --arg k "$tip_key" '{pk: {S: $k}}')" 2>/dev/null) || claim_rc=$?
  claim_pk=$(printf '%s' "$claim_out" | /usr/bin/jq -r '.Item.pk.S // empty' 2>/dev/null || true)
  if [[ "$claim_rc" -ne 0 ]]; then
    echo "head-check result=claim-unknown sha=${HEAD_SHA:0:7} tip=${tip:0:7}" >&2; return 1
  fi
  if [[ "$claim_pk" == "$tip_key" ]]; then
    echo "head-check result=superseded sha=${HEAD_SHA:0:7} tip=${tip:0:7}" >&2; return 0
  fi
  echo "head-check result=moved-unclaimed sha=${HEAD_SHA:0:7} tip=${tip:0:7}" >&2; return 1
}
