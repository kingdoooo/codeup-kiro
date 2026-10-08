#!/usr/bin/env bash
# 扫描任务（Task B）的受信入口（Phase 2b，spec「Task B」「S2」「F1」）。与执行器（entrypoint.sh）是同一个镜像、不同的启动命令：
# 不 clone、不碰业务库，只读执行器放在输入桶里的扫描输入；每位扫描员一个子进程，各自只拿到自己的云效令牌。
# 子进程的退出码约定（aws/reviewers/lib/reviewer.sh）：0 = 已回写（汇总或它自己的失败评论）；10 = 被新推送取代（安静）；
# 其它 = 没有终态。本入口据此在锁记录上置 posted_<评审员> / superseded_<评审员>；有任何一位没有终态 → 退出 96，
# 兜底 Lambda 以那位评审员的机器人回写（F1）。本入口自己的 fail-closed 退出码：90（N1 摘要门）、95（输入形状不对）。
set -euo pipefail

PKG=/opt/integration
WORKROOT=/tmp/scan
# 必填项一律以 95 退出（不用 `:?`：那是退出码 1，兜底按退出码给成因，同一件事两个码只会让人查错行——与 entrypoint 的 92 同一理由）
for v in CODEUP_REPO_ID MR_LOCAL_ID HEAD_SHA CI_COMMIT_REF_NAME LOCK_KEY REVIEWERS SCAN_RUN_ID SCAN_REPO_URL; do
  [[ -n "${!v:-}" ]] || { echo "缺少 ${v}（由执行器经 RunTask 环境覆盖传入），拒绝运行" >&2; exit 95; }
done
: "${MR_TARGET_BRANCH:=}"
# 入参在这里再查一次形状（执行器拼的，这是扫描任务这一侧的第二道——不假设上游一定对）。不回显取值。
# REVIEWERS 只能是扫描员（Kiro 不在扫描任务里跑），不重复。
[[ "$REVIEWERS" =~ ^(inspector|security)(,(inspector|security))?$ && "$REVIEWERS" != inspector,inspector \
   && "$REVIEWERS" != security,security ]] || { echo "REVIEWERS 形状不对（扫描任务只认 inspector / security），拒绝运行" >&2; exit 95; }
[[ "$SCAN_RUN_ID" =~ ^[0-9a-f]{32}$ && "$HEAD_SHA" =~ ^[0-9a-f]{40}$ && "$CODEUP_REPO_ID" =~ ^[0-9]+$ \
   && "$MR_LOCAL_ID" =~ ^[0-9]+$ ]] || { echo "SCAN_RUN_ID / HEAD_SHA / CODEUP_REPO_ID / MR_LOCAL_ID 形状不对，拒绝运行" >&2; exit 95; }
[[ "${YUNXIAO_ORG_ID:-}" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "YUNXIAO_ORG_ID 没配或形状不对，拒绝运行" >&2; exit 95; }
# 白名单放行的数值设置（终审 I-1）：扫描员把它们放进 bash 算术（$(( ))、[[ -gt ]]），而 bash 算术会对 `NAME[$(cmd)]` 的下标求值、
# 执行 cmd——被攻破的 Task A 经 RunTask 环境覆盖就能在持有扫描员令牌的进程里跑命令。不是十进制整数就拒绝（空 = 未设置，扫描员用缺省）。
for v in MAX_COMMENT_BYTES SECURITY_AGENT_TIMEOUT INSPECTOR_MAX_SCAN_CALLS; do
  [[ -z "${!v:-}" || "${!v}" =~ ^[0-9]{1,9}$ ]] || { echo "${v} 不是十进制整数，拒绝运行（取值不回显）" >&2; exit 95; }
done
# 仓库地址：执行器按仓库 id 查到、过了检查的那一个（只拿来 ls-remote 核对最新提交）。规则与 entrypoint 的同一道一致。
[[ "$SCAN_REPO_URL" == "https://codeup.aliyun.com/${YUNXIAO_ORG_ID}/"*.git \
   && "$SCAN_REPO_URL" != *[[:space:][:cntrl:]@?#%]* && "$SCAN_REPO_URL" != *..* ]] \
  || { echo "SCAN_REPO_URL 形状不对，拒绝运行" >&2; exit 95; }
for b in "$CI_COMMIT_REF_NAME" "$MR_TARGET_BRANCH"; do
  [[ -z "$b" || ( "$b" != -* && ! "$b" =~ [[:space:]] && ! "$b" =~ [[:cntrl:]] ) ]] \
    || { echo "分支名以 - 开头或含空白/控制字符，拒绝运行（取值不回显）" >&2; exit 95; }
done

# ── N1 镜像摘要门：在任何评审动作之前 ────────────────────────────────
# 查【容器级】端点、取顶层 .ImageID——不是 `${...}/task`（任务级，返回本任务下全部容器的列表，
# 无自证身份、无顺序保证）。任务里一旦加一个日志路由/X-Ray sidecar，`.Containers[0]` 就可能读到
# 别的容器，N1 会悄悄校验错误的镜像而评审容器本身的摘要从未被核对——这就废了本任务唯一要守的不变式。
: "${KIRO_IMAGE_DIGESTS:?缺少 KIRO_IMAGE_DIGESTS（已探测镜像摘要名单，必配无默认）}"
: "${ECS_CONTAINER_METADATA_URI_V4:?缺少 ECS_CONTAINER_METADATA_URI_V4（ECS 容器级元数据端点），无法核对镜像摘要}"
meta=$(/usr/bin/curl -sf --max-time 10 "${ECS_CONTAINER_METADATA_URI_V4}" || true)
raw_digest=$(printf '%s' "$meta" | /usr/bin/jq -r '.ImageID // empty' 2>/dev/null || true)
# ECS 返回的 ImageID 带 `sha256:` 前缀（如 `sha256:25f3...`）；约定 KIRO_IMAGE_DIGESTS 里存的是
# 去掉这个前缀之后的裸十六进制串，所以这里核对前也剥一次前缀，两边口径才对得上。
self_digest="${raw_digest#sha256:}"
# 读不到摘要（端点瞬时失败、返回形状变了）必须当场拒绝，不交给下面的名单比对去「碰巧」拒绝：原先的
# `case " $名单 " in *" $self_digest "*)` 在摘要为空时退化成「名单里有两个连续空格」，名单首尾多一个
# 空格就放行——N1 失败在放行方向（全分支复审 I3 在 shell 里复现过）。
[[ -n "$self_digest" ]] || { echo "读不到本容器镜像摘要（ECS 容器级元数据端点），拒绝评审" >&2; exit 90; }
# 名单按空白切成数组后逐项全等比较：空格、制表符、换行怎么混都不改变名单的含义。
read -r -a allowed_digests -d '' <<< "$KIRO_IMAGE_DIGESTS" || true
digest_ok=0
for d in ${allowed_digests[@]+"${allowed_digests[@]}"}; do
  if [[ "$d" == "$self_digest" ]]; then digest_ok=1; fi
done
[[ "$digest_ok" -eq 1 ]] || { echo "镜像摘要不在已探测名单内，拒绝评审：${self_digest}" >&2; exit 90; }

# ── 按评审员的子进程 ─────────────────────────────────────────────
# N1 那一段与 entrypoint.sh 逐字节相同（tests/test-aws-scan.sh 比对）：同一个镜像、同一份已探测摘要名单。
source "$PKG/lib/lease.sh"          # aws_err_code（mark_lock 要用）
source "$PKG/lib/scan-dispatch.sh"  # mark_lock
source "$PKG/scripts/lib/kiro-agent.sh"   # KIRO_ENV_EXEC_SHIM（「恰好一份清单」的环境，取值不进 argv）
/bin/rm -rf "$WORKROOT"; /bin/mkdir -p "$WORKROOT"
# 扫描子进程的环境是白名单（issue 14，复审 M-3）：不继承 Task B 的环境。Task A 能以任意 containerOverrides.environment 调 RunTask
# （IAM 对 override 的内容没有条件键）；被攻破的 Task A 一旦能把 GIT_CONFIG_PARAMETERS（credential helper、http.proxy +
# sslVerify=false）、GIT_SSH_COMMAND、*_PROXY、LD_PRELOAD 之类塞进子进程，就能在 L7 的 ls-remote 时截获扫描员的云效令牌。
# 名单只放扫描员与它调用的库实际读到的变量（aws/reviewers/、scripts/lib/{review-render,codeup-api}.sh、lib/lease.sh），加上
# Fargate 给 AWS CLI 找任务角色凭证用的两个（AWS_CONTAINER_CREDENTIALS_RELATIVE_URI、AWS_EXECUTION_ENV）。未设置的名字跳过。
SCAN_CHILD_COMMON=(PATH HOME LANG LC_ALL TZ AWS_REGION AWS_DEFAULT_REGION AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_EXECUTION_ENV
                   ECS_CONTAINER_METADATA_URI_V4 CODEUP_REPO_ID MR_LOCAL_ID HEAD_SHA CI_COMMIT_REF_NAME MR_TARGET_BRANCH LOCK_KEY
                   LOCK_TABLE SCAN_RUN_ID SCAN_REPO_URL YUNXIAO_ORG_ID SCAN_BUCKET SCAN_BUCKET_OWNER MAX_COMMENT_BYTES)
pids=""
# StopTask 时及时停下（issue 15）：任务定义开了 initProcessEnabled，PID 1 是 init（tini），本入口不再是 PID 1，SIGTERM 能到达；
# 但 init 只把信号转给它的直接子进程（就是本入口），扫描员子进程收不到——它们的租约要在各自的 EXIT 陷阱里释放。所以本入口
# 收到 TERM 就转给每位扫描员、等它们退出、以 143 退出（没有终态的评审员由兜底 Lambda 回写，F1 不变）。
# 扫描员（bash，没有 TERM 陷阱）收到 TERM 立刻退出 143，EXIT 陷阱照常执行（integration-local + integration-remote 实测，issue 15）。
_scan_on_term() {
  local pr
  echo "scan-entrypoint 收到 TERM：转给各扫描员子进程并等它们退出" >&2
  for pr in $pids; do kill -TERM "${pr#*:}" 2>/dev/null || true; done
  for pr in $pids; do wait "${pr#*:}" 2>/dev/null || true; done
  exit 143
}
trap _scan_on_term TERM
for rid in ${REVIEWERS//,/ }; do
  case "$rid" in
    inspector) tok=YUNXIAO_TOKEN_INSPECTOR; bot=INSPECTOR_BOT_USERNAME; hint=INSPECTOR_RERUN_HINT
               own=(INSPECTOR_INPUT INSPECTOR_MAX_SCAN_CALLS) ;;
    security)  tok=YUNXIAO_TOKEN_SECURITY;  bot=SECURITY_BOT_USERNAME;  hint=SECURITY_RERUN_HINT
               own=(SECURITY_INPUT SA_AGENT_SPACE_ID SA_SERVICE_ROLE_ARN SA_MAPPING_TABLE SECURITY_AGENT_TIMEOUT) ;;
  esac
  child_env=()
  for n in "${SCAN_CHILD_COMMON[@]}" "${own[@]}"; do
    [[ -n "${!n+x}" ]] && child_env+=("${n}=${!n}")
  done
  # S2：子进程只拿到自己的令牌（改名成 YUNXIAO_TOKEN），别的评审员的令牌与 Kiro 的密钥根本不在名单里
  child_env+=("YUNXIAO_TOKEN=${!tok:-}" "CODEUP_BOT_USERNAME=${!bot:-}" "REVIEW_RERUN_HINT=${!hint:-}"
              "REVIEWER_WORKDIR=$WORKROOT/$rid")
  /bin/mkdir -p "$WORKROOT/$rid"
  # 与 kiro_env_exec 同一个垫片：清单按 NUL 分隔从 fd 3 读进空环境（printf 是内建，令牌不进任何进程的 argv——issue 10 的教训），
  # 名字非法的环境项（`a-b=`、`BASH_FUNC_x%%`）与 bash 自己补的 SHLVL 都不会漏进去。**直接写在这里、不经 kiro_env_exec 函数**：
  # 函数放后台时 `$!` 是包着它的子 shell，这样写则 env → bash → env → 评审员一路 exec，`$!` 就是评审员进程本身（issue 15 要往它转发 TERM）。
  /usr/bin/env -i /bin/bash --norc --noprofile -c "$KIRO_ENV_EXEC_SHIM" kiro-env /bin/bash -p "$PKG/reviewers/${rid}.sh" \
    3< <(printf '%s\0' "${child_env[@]}") &
  pids="${pids}${rid}:$! "
done
all_terminal=1
for pr in $pids; do
  rid="${pr%%:*}"; pid="${pr#*:}"; rc=0
  wait "$pid" || rc=$?
  case "$rc" in
    0)  echo "scan-reviewer reviewer=${rid} result=posted" >&2; mark_lock "posted_${rid}" ;;
    10) echo "scan-reviewer reviewer=${rid} result=superseded" >&2; mark_lock "superseded_${rid}" ;;
    *)  echo "scan-reviewer reviewer=${rid} result=failed rc=${rc}（兜底 Lambda 会以这位评审员的机器人回写）" >&2; all_terminal=0 ;;
  esac
done
[[ "$all_terminal" == 1 ]] || exit 96
exit 0
