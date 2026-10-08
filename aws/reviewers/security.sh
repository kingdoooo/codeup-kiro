#!/usr/bin/env bash
# Security Agent 评审员（Phase 2b spec「Security Agent 评审员」，issue 12）。扫描任务的子进程：scan-entrypoint.sh 以白名单环境
# exec 它（只有本评审员的令牌）。退出码约定见 lib/reviewer.sh（0 = 已回写；10 = 被取代；其它 = 兜底接手）。
# 流程：L7 租约 + 核对最新提交 → 定位上一条汇总 → 读执行器准备的计数与文件清单 → Q1 取/建本仓库的 code review →
#   Q2 临界区（按仓库租约：重指向 → Start → 核对作业记下的源，秒级；R12）→ 轮询作业 status（每 30 s，上限 security_agent_timeout，R8）
#   → 取发现 → 归一 → 渲染 → 掩码、截断 → 原地更新或新建。任何一步失败都发本评审员自己的失败评论（固定文案 + 代号，F3）。
# 只读评审员（I2）：code review 一律 codeRemediationStrategy=DISABLED、validationMode=DISABLED；只做差分扫描（D1）：唯一一处
# StartCodeReviewJob 的请求带 diffSource。事实依据是 issue 09 的 sandbox 实测（spec「SA 探测结论」10–19）。
set -euo pipefail
PKG=/opt/integration
REVIEW_PROFILE=security
source "$PKG/reviewers/lib/reviewer.sh"
source "$PKG/reviewers/lib/security-lib.sh"
source "$PKG/reviewers/lib/security-render.sh"

SA_POLL_INTERVAL="${SA_POLL_INTERVAL:-30}"            # 轮询间隔（秒）；作业约 10 分钟，30 s 一次足够
SA_START_RETRY_EVERY="${SA_START_RETRY_EVERY:-60}"    # 并发满时每隔多久再试（R9）
SA_START_RETRY_MAX="${SA_START_RETRY_MAX:-900}"       # 并发满时最多排多久（R9：15 分钟，计入总预算）
SA_SUPERSEDE_EVERY="${SA_SUPERSEDE_EVERY:-5}"         # 每几次轮询核对一次最新提交（被取代就停掉作业，免得新提交的那次等满一个作业）
SA_LOCK_WAIT="${SA_LOCK_WAIT:-300}"                   # 等按仓库租约 / 映射表认领的上限（两者都是秒级临界区）
SA_FINDINGS_BATCH=50                                  # BatchGetFindings 每批的 id 数
# L7 的等待上限：同一 MR 的上一次 SA 评审可能持有按 MR 的租约一整个作业（含排队），缺省的 900 秒不够。
# SECURITY_AGENT_TIMEOUT 这时还没查形状（下面 sa-config 那一道）：先过正则再进算术——bash 算术会执行 `NAME[$(cmd)]` 里的 cmd
# （终审 I-1）。形状不对的按缺省算，随后照样被 sa-config 拒绝。
_sa_timeout="${SECURITY_AGENT_TIMEOUT:-3600}"; [[ "$_sa_timeout" =~ ^[0-9]{3,4}$ ]] || _sa_timeout=3600
REVIEWER_LEASE_WAIT="${REVIEWER_LEASE_WAIT:-$(( 10#$_sa_timeout + 600 ))}"
# 只读与幂等的调用交给 AWS CLI 的 standard 重试；CreateCodeReview 与 StartCodeReviewJob 没有幂等令牌，这两处单独设 AWS_MAX_ATTEMPTS=1（Q3）
export AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=4

reviewer_lease_and_check
# 两把租约的键与持有者各存一份（终审 I-9）：EXIT 陷阱在被打断的那个函数的作用域里跑，sa_repo_lease 的局部 lease_key / lease_me
# 会遮住全局的那一对——陷阱按这里的名字各放各的，不读当时可见的 lease_key
SA_L7_KEY="$lease_key"; SA_L7_ME="$lease_me"
SA_REPO_KEY=$(jq -cn --arg k "lease#${CODEUP_REPO_ID}#security-repo" '{pk: {S: $k}}'); SA_REPO_ME="${lease_me}|repo"; SA_REPO_HELD=0
summary_locate_prior

case "${SECURITY_INPUT:-}" in
  ok) ;;
  skipped:*)
    security_render_skipped "${SECURITY_INPUT#skipped:}" > "$WORK/comment.md" || reviewer_fail "Security Agent 说明汇总渲染失败"
    reviewer_publish "$WORK/comment.md" ;;
  failed:*) reviewer_fail "执行器没能准备 Security Agent 的扫描输入（代号 ${SECURITY_INPUT#failed:}）" ;;
  *) reviewer_fail "Security Agent 的扫描输入状态不合法" ;;
esac
[[ "${SA_AGENT_SPACE_ID:-}" =~ ^as-[0-9a-f-]{8,64}$ && "${SA_SERVICE_ROLE_ARN:-}" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ \
   && "${SA_MAPPING_TABLE:-}" =~ ^[A-Za-z0-9_.-]{3,255}$ && "${SECURITY_AGENT_TIMEOUT:-}" =~ ^[0-9]{3,4}$ ]] \
  && (( 10#$SECURITY_AGENT_TIMEOUT >= 600 && 10#$SECURITY_AGENT_TIMEOUT <= 7200 )) \
  || reviewer_fail "Security Agent 的部署配置不完整（代号 sa-config）"

SA_PREFIX="security/${CODEUP_REPO_ID}/${HEAD_SHA}/${SCAN_RUN_ID}"
SA_SRC_URI="s3://${SCAN_BUCKET}/${SA_PREFIX}/source.zip"
SA_PATCH_URI="s3://${SCAN_BUCKET}/${SA_PREFIX}/changes.patch"
SA_DEADLINE=$(( $(/bin/date +%s) + 10#$SECURITY_AGENT_TIMEOUT ))
SA_JOB_ID=""; SA_JOB_ACTIVE=0

# 一次 securityagent 调用：<操作> <请求 JSON> → stdout 应答；失败时错误代号（AWS 错误码；没有代号 = unknown）写进 $WORK/sa.code，
# 用 sa_err 读——不放全局变量：调用方几乎都是 `out=$(sa_call …)`，那是子 shell，全局赋值回不到调用方。
# 请求经 --cli-input-json 文件传（不拼命令行参数：取值不进 argv，也不受 shell 引号影响）。
sa_call() {  # <操作> <请求 JSON>
  local op="$1" req="$WORK/sa-req.json" out rc=0
  printf '%s' "$2" > "$req"
  out=$(/usr/local/bin/aws securityagent "$op" --region "$AWS_REGION" --cli-input-json "file://$req" --output json \
        2>"$WORK/sa.err") || rc=$?
  if [[ "$rc" != 0 ]]; then aws_err_code "$(cat "$WORK/sa.err")" > "$WORK/sa.code"; return 1; fi
  : > "$WORK/sa.code"
  printf '%s' "$out"
}
sa_err() { local c; c=$(cat "$WORK/sa.code" 2>/dev/null) || c=""; printf '%s' "${c:-unknown}"; }
# 非幂等的两个操作（CreateCodeReview、StartCodeReviewJob）：只试一次，重试由调用方按 Q3 的规则自己做
sa_call_once() { AWS_MAX_ATTEMPTS=1 sa_call "$@"; }

# 退出时作业还在跑（被 TERM、被取代、轮询出错之外的意外退出）：先停掉它（不占并发名额、不白跑），再走 reviewer.sh 的租约释放
_sa_exit() {
  if [[ "$SA_JOB_ACTIVE" == 1 && -n "$SA_JOB_ID" ]]; then
    sa_call stop-code-review-job "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --arg j "$SA_JOB_ID" '{agentSpaceId: $s, codeReviewJobId: $j}')" \
      >/dev/null 2>&1 || true
    log "退出时作业 ${SA_JOB_ID} 仍在运行，已请求停止"
  fi
  if [[ "${SA_REPO_HELD:-0}" == 1 ]]; then
    local lease_key="$SA_REPO_KEY" lease_me="$SA_REPO_ME"; lease_release
  fi
  local lease_key="$SA_L7_KEY" lease_me="$SA_L7_ME"
  _reviewer_lease_exit
}
trap '_sa_exit' EXIT

# 读执行器准备的计数与文件清单（source.zip 与 changes.patch 由 SA 自己读，这里不下载）
for f in meta.json files.txt; do
  /usr/local/bin/aws s3api get-object --region "$AWS_REGION" --bucket "$SCAN_BUCKET" --key "${SA_PREFIX}/${f}" \
    --expected-bucket-owner "$SCAN_BUCKET_OWNER" "$WORK/${f}" >/dev/null 2>"$WORK/s3.err" \
    || reviewer_fail "读取 Security Agent 的扫描输入失败（代号 $(aws_err_code "$(cat "$WORK/s3.err")")）"
done
jq -e '(.files | type) == "number" and (.diff_files | type) == "number" and (.symlinks | type) == "number"' "$WORK/meta.json" >/dev/null 2>&1 \
  || reviewer_fail "Security Agent 的扫描输入格式不对（代号 meta）"

# ── Q1：本仓库的 code review（spec Q1：每仓库一个、映射表永不过期；CreateCodeReview 没有幂等令牌——按标题收编让重试收敛）──
# 标题只许字母、数字、连字符、下划线，最多 100 个字符（sandbox 实测，2026-10-08：带冒号的 `codeup-kiro:<id>` 被 CreateCodeReview 拒收）
SA_TITLE="codeup-kiro-${CODEUP_REPO_ID}"
SA_MAP_KEY=$(jq -cn --arg r "$CODEUP_REPO_ID" '{repo_id: {S: $r}}')
sa_map_get() {  # → stdout 映射记录（Item 或 {}）
  /usr/local/bin/aws dynamodb get-item --region "$AWS_REGION" --table-name "$SA_MAPPING_TABLE" --consistent-read \
    --key "$SA_MAP_KEY" --output json 2>/dev/null | jq -c '.Item // {}'
}
# 属性名占位符只给表达式里真用到的那几个：DynamoDB 拒绝没用到的 ExpressionAttributeNames / Values（ValidationException）
sa_map_update() {  # <条件表达式> <更新表达式> <取值 JSON> → rc 0 / 1（条件不满足）/ 2（别的错误）
  local err names
  names=$(jq -cn --arg e "$1 $2" '{"#s":"status","#c":"code_review_id","#a":"agent_space_id","#h":"holder","#u":"until"}
                                  | with_entries(select(.key as $k | $e | contains($k)))')
  if err=$(/usr/local/bin/aws dynamodb update-item --region "$AWS_REGION" --table-name "$SA_MAPPING_TABLE" --key "$SA_MAP_KEY" \
        --condition-expression "$1" --update-expression "$2" \
        --expression-attribute-names "$names" \
        --expression-attribute-values "$3" 2>&1 >/dev/null); then return 0; fi
  [[ "$err" == *ConditionalCheckFailedException* ]] && return 1
  return 2
}
# 按标题收编已存在的 code review（多个时取最早建的那个：结果与调用顺序无关，多进程会收敛到同一个）
sa_adopt_by_title() {
  local out
  out=$(sa_call list-code-reviews "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" '{agentSpaceId: $s}')") || return 1
  jq -r --arg t "$SA_TITLE" '[.codeReviewSummaries[]? | select(.title == $t)] | sort_by(.createdAt) | .[0].codeReviewId // empty' <<< "$out"
}
sa_ensure_code_review() {  # → 全局 SA_CR_ID
  local item status cr space now deadline rc out
  deadline=$(( $(/bin/date +%s) + SA_LOCK_WAIT ))
  while :; do
    item=$(sa_map_get) || item='{}'
    status=$(jq -r '.status.S // ""' <<< "$item"); cr=$(jq -r '.code_review_id.S // ""' <<< "$item")
    space=$(jq -r '.agent_space_id.S // ""' <<< "$item")
    if [[ "$status" == ready && "$space" == "$SA_AGENT_SPACE_ID" && "$cr" =~ ^cr-[0-9a-f-]{8,64}$ ]]; then SA_CR_ID="$cr"; return 0; fi
    # 认领：没有记录、不是「正在建」（例如 Agent Space 换过之后留下的旧记录、stale）、认领已过期，或本来就是我——但**不覆盖**本 Space
    # 已 ready 的记录（终审 I-3：上面读到的可能是别人置 ready 之前的样子；条件不满足就回去再读一次，用表里那个）
    now=$(/bin/date +%s); rc=0
    sa_map_update 'attribute_not_exists(repo_id) OR ((#s <> :ready OR #a <> :space) AND (#s <> :creating OR #u < :now OR #h = :me))' \
      'SET #s = :creating, #u = :until, #h = :me' \
      "$(jq -cn --arg me "$lease_me" --arg now "$now" --arg until "$((now + 120))" --arg sp "$SA_AGENT_SPACE_ID" \
         '{":creating": {S: "creating"}, ":ready": {S: "ready"}, ":space": {S: $sp}, ":now": {N: $now}, ":until": {N: $until}, ":me": {S: $me}}')" \
      || rc=$?
    [[ "$rc" == 0 ]] && break
    [[ "$rc" == 1 ]] || reviewer_fail "读写 code review 映射表失败（代号 sa-mapping）"
    (( $(/bin/date +%s) < deadline )) || reviewer_fail "等别的任务建本仓库的 code review 超过 ${SA_LOCK_WAIT} 秒（代号 sa-mapping-wait）"
    /bin/sleep 5
  done
  SA_CR_ID=$(sa_adopt_by_title) || reviewer_fail "列出 code review 失败（代号 $(sa_err)）"
  if [[ -z "$SA_CR_ID" ]]; then
    out=$(sa_call_once create-code-review "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --arg t "$SA_TITLE" --arg src "$SA_SRC_URI" \
            --arg role "$SA_SERVICE_ROLE_ARN" \
            '{agentSpaceId: $s, title: $t, assets: {sourceCode: [{s3Location: $src}]}, serviceRole: $role,
              codeRemediationStrategy: "DISABLED", validationMode: "DISABLED"}')") \
      && SA_CR_ID=$(jq -r '.codeReviewId // empty' <<< "$out") \
      || { local code; code=$(sa_err); SA_CR_ID=$(sa_adopt_by_title || true)
           [[ -n "$SA_CR_ID" ]] || reviewer_fail "建本仓库的 code review 失败（代号 ${code}）"; }
  fi
  [[ "$SA_CR_ID" =~ ^cr-[0-9a-f-]{8,64}$ ]] || reviewer_fail "code review id 的形状不对（代号 sa-create）"
  rc=0
  sa_map_update '#h = :me' 'SET #s = :ready, #c = :cr, #a = :space' \
    "$(jq -cn --arg me "$lease_me" --arg cr "$SA_CR_ID" --arg sp "$SA_AGENT_SPACE_ID" \
       '{":me": {S: $me}, ":ready": {S: "ready"}, ":cr": {S: $cr}, ":space": {S: $sp}}')" || rc=$?
  if [[ "$rc" != 0 ]]; then
    # 认领被别人接管了（我卡得太久）：以表里的为准（它若已 ready，大家都用同一个）；否则仍用我收编/建出的这个
    item=$(sa_map_get) || item='{}'
    cr=$(jq -r 'if .status.S == "ready" then .code_review_id.S else "" end' <<< "$item")
    [[ "$cr" =~ ^cr-[0-9a-f-]{8,64}$ ]] && SA_CR_ID="$cr"
    log "登记 code review 映射时认领已被接管（rc=${rc}），使用 ${SA_CR_ID}"
  fi
  log "本仓库的 code review：${SA_CR_ID}"
}

# ── Q2 + Q3：按仓库租约下的「重指向 → Start → 核对作业记下的源」（R12：秒级临界区，核对完立刻释放）──
# 租约复用 lib/lease.sh 的函数，但键、持有者、租期都是局部的（bash 动态作用域：被调函数读到的是这里的 local），
# 不碰 reviewer.sh 那把按 MR 的租约。SA_REPO_HELD 记下是否持有：退出时（_sa_exit）按另存的键各放各的（终审 I-9）。
sa_repo_lease() {  # <acquire|release>
  local lease_key="$SA_REPO_KEY" lease_me="$SA_REPO_ME" LEASE_TTL=60 lrc deadline
  if [[ "$1" == release ]]; then lease_release; SA_REPO_HELD=0; return 0; fi
  deadline=$(( $(/bin/date +%s) + SA_LOCK_WAIT ))
  while :; do
    lrc=0; lease_acquire || lrc=$?
    [[ "$lrc" == 0 ]] && { SA_REPO_HELD=1; return 0; }
    [[ "$lrc" == 1 ]] || return 2
    (( $(/bin/date +%s) < deadline )) || return 1
    /bin/sleep 2
  done
}
sa_job_source() {  # <作业 id> → stdout 作业记下的第一个 sourceCode 位置
  local out
  out=$(sa_call batch-get-code-review-jobs "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --arg j "$1" '{agentSpaceId: $s, codeReviewJobIds: [$j]}')") \
    || return 1
  jq -r '.codeReviewJobs[0].sourceCode[0].s3Location // empty' <<< "$out"
}
# 含糊失败（5xx、超时、没有错误码）之后：本次的作业可能已经建了。最近的作业里 sourceCode = 本次键的就是它（键里有本次的 run_id）
sa_adopt_job() {
  local out ids j
  out=$(sa_call list-code-review-jobs-for-code-review "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --arg c "$SA_CR_ID" \
          '{agentSpaceId: $s, codeReviewId: $c}')") || return 1
  # 不按状态筛（终审 I-11）：本次的键里有 128 位的 run_id，sourceCode 对得上的就是本次的作业，不管它报什么状态（已结束的交给轮询判）
  ids=$(jq -c '[.codeReviewJobSummaries[]?] | sort_by(.createdAt) | reverse | .[0:20] | map(.codeReviewJobId)' <<< "$out")
  [[ "$ids" != "[]" ]] || return 1
  out=$(sa_call batch-get-code-review-jobs "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --argjson j "$ids" '{agentSpaceId: $s, codeReviewJobIds: $j}')") || return 1
  j=$(jq -r --arg src "$SA_SRC_URI" '[.codeReviewJobs[]? | select(.sourceCode[0].s3Location == $src)][0].codeReviewJobId // empty' <<< "$out")
  [[ -n "$j" ]] || return 1
  printf '%s' "$j"
}
sa_start_job() {  # → 全局 SA_JOB_ID
  local start_deadline out src lrc ambiguous=0 recreated=0
  start_deadline=$(( $(/bin/date +%s) + SA_START_RETRY_MAX ))
  (( start_deadline < SA_DEADLINE )) || start_deadline=$SA_DEADLINE
  while :; do
    lrc=0; sa_repo_lease acquire || lrc=$?
    [[ "$lrc" == 0 ]] || reviewer_fail "等同一仓库的另一次 Security Agent 评审启动作业超过 ${SA_LOCK_WAIT} 秒（代号 sa-repo-lease）"
    if ! sa_call update-code-review "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --arg c "$SA_CR_ID" --arg src "$SA_SRC_URI" \
           --arg role "$SA_SERVICE_ROLE_ARN" '{agentSpaceId: $s, codeReviewId: $c, assets: {sourceCode: [{s3Location: $src}]}, serviceRole: $role}')" \
           >/dev/null; then
      local code; code=$(sa_err)
      sa_repo_lease release
      # code review 在别处被删了（映射表还指着它）：把映射标成过期、重新取/建一次（只试一次）
      if [[ "$code" == ResourceNotFoundException && "$recreated" == 0 ]]; then
        recreated=1
        sa_map_update '#c = :cr' 'SET #s = :stale' "$(jq -cn --arg cr "$SA_CR_ID" '{":cr": {S: $cr}, ":stale": {S: "stale"}}')" || true
        log "code review ${SA_CR_ID} 已不存在，重新取/建"
        sa_ensure_code_review; continue
      fi
      reviewer_fail "重指向 code review 失败（代号 ${code}）"
    fi
    if out=$(sa_call_once start-code-review-job "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --arg c "$SA_CR_ID" --arg p "$SA_PATCH_URI" \
              '{agentSpaceId: $s, codeReviewId: $c, diffSource: {s3Uri: $p}}')"); then
      SA_JOB_ID=$(jq -r '.codeReviewJobId // empty' <<< "$out")
    else
      local code; code=$(sa_err)
      case "$code" in
        ThrottlingException|ServiceQuotaExceededException|ConflictException)
          # 明确拒绝、没有建作业（issue 09：第 11 个并发 Start 同步收到 ThrottlingException）：放开仓库租约、排队重试
          sa_repo_lease release
          # 排队期间同一 MR 有了新提交（终审 I-5）：不再为旧提交起作业（它会占一个本就紧缺的名额），安静退出，交给新的那次
          if head_check_superseded; then
            log "源分支已有更新的提交，不再排队启动作业，交给新的那次评审"; exit 10
          fi
          if (( $(/bin/date +%s) + SA_START_RETRY_EVERY > start_deadline )); then
            reviewer_fail "Security Agent 并发已满，排队超过上限仍未启动（代号 sa-concurrency-full）"
          fi
          log "Security Agent 并发已满（${code}），${SA_START_RETRY_EVERY} 秒后再试"
          /bin/sleep "$SA_START_RETRY_EVERY"; continue ;;
        InternalServerException|ServiceUnavailableException|RequestTimeout|unknown)
          # 含糊：作业可能已经建了（没有幂等令牌，Q3）。先收编，收编不到才重试——且只重试一次
          SA_JOB_ID=$(sa_adopt_job || true)
          if [[ -z "$SA_JOB_ID" ]]; then
            sa_repo_lease release
            [[ "$ambiguous" == 0 ]] || reviewer_fail "启动 Security Agent 作业失败（代号 ${code}）"
            ambiguous=1; log "启动作业的应答含糊（${code}），没找到本次的作业，重试一次"; continue
          fi
          log "启动作业的应答含糊（${code}），收编了本次的作业 ${SA_JOB_ID}" ;;
        *) sa_repo_lease release; reviewer_fail "启动 Security Agent 作业失败（代号 ${code}）" ;;
      esac
    fi
    [[ "$SA_JOB_ID" =~ ^cj-[0-9a-f-]{8,64}$ ]] || { sa_repo_lease release; reviewer_fail "作业 id 的形状不对（代号 sa-start）"; }
    SA_JOB_ACTIVE=1
    # 核对作业记下的源 = 本次键（R12 / Q2 的守卫：作业在 Start 时记下 code review 当时的 sourceCode，issue 09 J3b）
    # 读不到 ≠ 源不符（终审 I-6）：只读、幂等，再读两次；仍读不到就停掉作业、用单独的代号，不把一次读失败说成「作业读了别人的源」
    src=""
    for _ in 1 2 3; do
      src=$(sa_job_source "$SA_JOB_ID" || true)
      [[ -n "$src" ]] && break
      /bin/sleep 2
    done
    sa_repo_lease release
    [[ -n "$src" ]] || reviewer_fail "读不到 Security Agent 作业记下的源，已停止（代号 sa-source-unknown）"
    if [[ "$src" != "$SA_SRC_URI" ]]; then
      reviewer_fail "Security Agent 作业记下的源与本次不符，已停止（代号 sa-source-mismatch）"
    fi
    log "已启动作业 ${SA_JOB_ID}（code review ${SA_CR_ID}）"
    return 0
  done
}

sa_ensure_code_review
sa_start_job

# ── 轮询：只看作业 status（COMPLETED 的作业 steps[] 里 FINALIZING 可能仍是 NOT_STARTED，issue 09）──
polls=0; errs=0
while :; do
  if (( $(/bin/date +%s) >= SA_DEADLINE )); then
    reviewer_fail "Security Agent 作业超过 ${SECURITY_AGENT_TIMEOUT} 秒仍未结束，已停止（代号 sa-timeout）"
  fi
  /bin/sleep "$SA_POLL_INTERVAL"
  if ! job=$(sa_call batch-get-code-review-jobs "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --arg j "$SA_JOB_ID" \
               '{agentSpaceId: $s, codeReviewJobIds: [$j]}')"); then
    errs=$((errs + 1))
    (( errs <= 10 )) || reviewer_fail "查询 Security Agent 作业状态连续失败（代号 $(sa_err)）"
    continue
  fi
  errs=0
  status=$(jq -r '.codeReviewJobs[0].status // ""' <<< "$job")
  code=$(jq -r '.codeReviewJobs[0].errorInformation.code // ""' <<< "$job")
  [[ "$code" =~ ^[A-Z_]{1,40}$ ]] || code=UNKNOWN
  case "$status" in
    COMPLETED) SA_JOB_ACTIVE=0; break ;;
    # 不回显 errorInformation.message（F3：里面有桶名与对象键），只给枚举代号
    FAILED) SA_JOB_ACTIVE=0; reviewer_fail "Security Agent 作业失败（代号 ${code}）" ;;
    STOPPED|STOPPING) SA_JOB_ACTIVE=0; reviewer_fail "Security Agent 作业被停止（代号 ${code}）" ;;
  esac
  polls=$((polls + 1))
  if (( polls % SA_SUPERSEDE_EVERY == 0 )) && head_check_superseded; then
    sa_call stop-code-review-job "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --arg j "$SA_JOB_ID" '{agentSpaceId: $s, codeReviewJobId: $j}')" \
      >/dev/null || true
    SA_JOB_ACTIVE=0
    log "源分支已有更新的提交，停止作业 ${SA_JOB_ID}，交给新的那次评审"
    exit 10
  fi
done
printf '%s' "$job" | jq -r '.codeReviewJobs[0].overview // ""' > "$WORK/overview.md"

# ── 取发现：ListFindings（CLI 自动翻页）→ BatchGetFindings 分批 → 归一 ──
lf=$(sa_call list-findings "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --arg j "$SA_JOB_ID" '{agentSpaceId: $s, codeReviewJobId: $j}')") \
  || reviewer_fail "列出 Security Agent 的发现失败（代号 $(sa_err)）"
jq -r '.findingsSummaries[]?.findingId // empty' <<< "$lf" | LC_ALL=C grep -E '^f-[0-9A-Za-z-]{1,64}$' > "$WORK/finding-ids" || true
batches=()
i=0
while IFS= read -r chunk; do
  i=$((i + 1))
  sa_call batch-get-findings "$(jq -cn --arg s "$SA_AGENT_SPACE_ID" --argjson ids "$chunk" '{agentSpaceId: $s, findingIds: $ids}')" \
    > "$WORK/findings-${i}.json" || reviewer_fail "读取 Security Agent 的发现失败（代号 $(sa_err)）"
  batches+=("$WORK/findings-${i}.json")
done < <(jq -Rnc --argjson n "$SA_FINDINGS_BATCH" '[inputs] | . as $a | range(0; length; $n) as $k | $a[$k:$k + $n]' "$WORK/finding-ids")
if (( ${#batches[@]} == 0 )); then echo '{"findings": []}' > "$WORK/findings-0.json"; batches=("$WORK/findings-0.json"); fi
sa_findings_report "$WORK/files.txt" "${batches[@]}" > "$WORK/report.json" || reviewer_fail "归一 Security Agent 的发现失败（代号 report）"
log "作业 ${SA_JOB_ID} 完成：$(jq -r '"\(.findings | length) 条（服务返回 \(.returned) 条，误报 \(.false_positives) 条，未能对应的位置 \(.unmatched) 个）"' "$WORK/report.json")"
# 完整的发现列表进扫描任务日志：评论按字节预算折叠时（终审 I-7）折叠行指向这一行。归一后的报告本来就不带 attackScript 之类（F3）
log "作业 ${SA_JOB_ID} 的 report：$(jq -c '.findings' "$WORK/report.json")"
security_render_summary "$WORK/report.json" "$WORK/meta.json" "$SA_JOB_ID" "$WORK/overview.md" > "$WORK/comment.md" \
  || reviewer_fail "Security Agent 汇总评论渲染失败"
reviewer_publish "$WORK/comment.md"
