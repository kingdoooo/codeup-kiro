#!/usr/bin/env bash
# 锁记录上的状态标记与扫描任务（Task B）派发——执行器（entrypoint.sh）用（Phase 2b，spec「Task A」「F1」「F2」）。
# 只有函数定义，source 时不执行任何动作。读这些全局变量：LOCK_KEY、LOCK_TABLE、AWS_REGION、CODEUP_REPO_ID、MR_LOCAL_ID、
# HEAD_SHA、CI_COMMIT_REF_NAME、MR_TARGET_BRANCH、clone_url（按仓库 id 查到、过了检查的地址），以及任务定义给的
# SCAN_CLUSTER、SCAN_TASK_DEFINITION、SCAN_CONTAINER_NAME、SCAN_SUBNETS、SCAN_SECURITY_GROUPS（逗号分隔）。

# 在本次投递的锁记录上置一个 BOOL true 属性。只给调度器抢锁时建好的那条记录置（attribute_exists，N4：绝不新建一条没有
# expires_at 的记录）。失败只留一行代号、不中断：标记缺了的后果是兜底多发一条（重复好于沉默），不该因此连 Kiro 都不评。
# 可选的后两个参数：同一次写入再置一个字符串属性（飞书通知的评论 id，Phase 2c issue 20）——posted_<评审员> 与 comment_<评审员> 一起落地，
# 通知 Lambda 看不到「有 posted、还没有 id」的半截状态。
mark_lock() {  # <属性名> [<字符串属性名> <取值>]
  local err update='SET #a = :t' names values='{":t":{"BOOL":true}}'
  names=$(/usr/bin/jq -cn --arg a "$1" '{"#a": $a}')
  if [[ $# -ge 3 ]]; then
    update='SET #a = :t, #c = :c'
    names=$(/usr/bin/jq -cn --arg a "$1" --arg c "$2" '{"#a": $a, "#c": $c}')
    values=$(/usr/bin/jq -cn --arg v "$3" '{":t": {BOOL: true}, ":c": {S: $v}}')
  fi
  if ! err=$(/usr/local/bin/aws dynamodb update-item --region "$AWS_REGION" --table-name "$LOCK_TABLE" \
        --key "$(/usr/bin/jq -cn --arg k "$LOCK_KEY" '{pk: {S: $k}}')" \
        --condition-expression 'attribute_exists(pk)' \
        --update-expression "$update" \
        --expression-attribute-names "$names" \
        --expression-attribute-values "$values" 2>&1 >/dev/null); then
    echo "mark-lock attr=${1} result=failed code=$(aws_err_code "$err")" >&2
  fi
  return 0
}

# 扫描员的输入准备：scan_prep_<评审员> 由 lib/scan-input.sh 定义（Inspector 在 issue 06）。没定义 = 这位扫描员还没实现，
# 输入状态记成 failed:not-implemented，扫描任务据此发一条失败评论——不在执行器里静默丢掉它。
# 输出一行输入状态：ok / skipped:<代号> / failed:<代号>（代号只含 [a-z0-9-]）。
scan_prep() {  # <评审员>
  local rid="$1" st
  if declare -F "scan_prep_${rid}" >/dev/null; then
    st=$("scan_prep_${rid}") || st="failed:prep-error"
  else
    st="failed:not-implemented"
  fi
  [[ "$st" =~ ^(ok|(skipped|failed):[a-z0-9-]{1,40})$ ]] || st="failed:bad-status"
  printf '%s' "$st"
}

# 派发扫描任务：每位扫描员各准备输入 → 一次 RunTask（clientToken = 本次 run_id，两次尝试同一个 token，服务端已起而应答丢了时
# 不会起第二个，issue 02 的教训）→ 成功后给每位扫描员置 dispatched_<评审员>。任何一步失败返回 1，调用方只留一行日志（F2）。
# 环境覆盖只放标量、不放任何密钥（I3：RunTask 入参进 CloudTrail），总长受 ECS 的 8,192 字符上限约束。
scan_dispatch() {  # <逗号分隔的扫描员>
  local rids="$1" rid st run_id overrides netcfg out tries=0 arn
  run_id=$(/usr/bin/od -An -tx1 -N16 /dev/urandom 2>/dev/null | /usr/bin/tr -d ' \n') || return 1
  [[ "$run_id" =~ ^[0-9a-f]{32}$ ]] || { echo "scan-dispatch result=failed code=no-random" >&2; return 1; }
  SCAN_RUN_ID="$run_id"   # 输入准备（scan_prep_<评审员>）按它拼不可变的对象键
  local -a env_pairs=(REVIEWERS "$rids" TASK_KIND scan CODEUP_REPO_ID "$CODEUP_REPO_ID" MR_LOCAL_ID "$MR_LOCAL_ID"
                      HEAD_SHA "$HEAD_SHA" CI_COMMIT_REF_NAME "$CI_COMMIT_REF_NAME" LOCK_KEY "$LOCK_KEY"
                      SCAN_RUN_ID "$run_id" SCAN_REPO_URL "$clone_url")
  [[ -z "${MR_TARGET_BRANCH:-}" ]] || env_pairs+=(MR_TARGET_BRANCH "$MR_TARGET_BRANCH")
  for rid in ${rids//,/ }; do
    st=$(scan_prep "$rid")
    echo "scan-prep reviewer=${rid} status=${st}" >&2
    case "$rid" in
      inspector) env_pairs+=(INSPECTOR_INPUT "$st") ;;
      security)  env_pairs+=(SECURITY_INPUT "$st") ;;
    esac
  done
  # 键值对经 jq 的 --args 交给它（jq ≥ 1.6）：不拼 JSON 字符串、不经 NUL 分隔（jq 对原始输入里的 NUL 字节各版本行为不一）
  overrides=$(/usr/bin/jq -cn --arg name "$SCAN_CONTAINER_NAME" '
    $ARGS.positional as $kv
    | {containerOverrides: [{name: $name,
        environment: [range(0; $kv | length; 2) as $i | {name: $kv[$i], value: $kv[$i + 1]}]}]}' \
    --args "${env_pairs[@]}") || return 1
  (( ${#overrides} < 8192 )) || { echo "scan-dispatch result=failed code=overrides-too-long" >&2; return 1; }
  netcfg=$(/usr/bin/jq -cn --arg s "$SCAN_SUBNETS" --arg g "$SCAN_SECURITY_GROUPS" \
    '{awsvpcConfiguration: {subnets: ($s | split(",")), securityGroups: ($g | split(",")), assignPublicIp: "ENABLED"}}') || return 1
  while (( tries < 2 )); do
    tries=$((tries + 1))
    if out=$(/usr/local/bin/aws ecs run-task --region "$AWS_REGION" --cluster "$SCAN_CLUSTER" \
          --task-definition "$SCAN_TASK_DEFINITION" --launch-type FARGATE --count 1 \
          --client-token "$run_id" --network-configuration "$netcfg" --overrides "$overrides" \
          --output json 2>&1); then
      arn=$(printf '%s' "$out" | /usr/bin/jq -r 'if ((.failures // []) | length) == 0 then (.tasks[0].taskArn // "") else "" end' 2>/dev/null || true)
      if [[ -n "$arn" ]]; then
        echo "scan-dispatch result=ok reviewers=${rids} run=${run_id}" >&2
        for rid in ${rids//,/ }; do mark_lock "dispatched_${rid}"; done
        return 0
      fi
      echo "scan-dispatch attempt=${tries} result=failed code=$(printf '%s' "$out" | /usr/bin/jq -r '(.failures // [])[0].reason // "no-task"' 2>/dev/null | LC_ALL=C /usr/bin/tr -cd 'A-Za-z0-9:_-' | LC_ALL=C /usr/bin/cut -c1-40)" >&2
    else
      echo "scan-dispatch attempt=${tries} result=failed code=$(aws_err_code "$out")" >&2
    fi
  done
  return 1
}
