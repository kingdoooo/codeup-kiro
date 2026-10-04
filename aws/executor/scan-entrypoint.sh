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
/bin/rm -rf "$WORKROOT"; /bin/mkdir -p "$WORKROOT"
pids=""
for rid in ${REVIEWERS//,/ }; do
  case "$rid" in
    inspector) tok=YUNXIAO_TOKEN_INSPECTOR; bot=INSPECTOR_BOT_USERNAME; hint=INSPECTOR_RERUN_HINT ;;
    security)  tok=YUNXIAO_TOKEN_SECURITY;  bot=SECURITY_BOT_USERNAME;  hint=SECURITY_RERUN_HINT ;;
  esac
  # S2：子进程只看得见自己的令牌。值经 export 进子 shell 的环境（不进任何 argv：`env NAME=值 …` 会把它放进 env 的 argv，
  # issue 10 的教训），其它评审员的令牌在 exec 之前 unset。
  (
    export YUNXIAO_TOKEN="${!tok:-}" CODEUP_BOT_USERNAME="${!bot:-}" REVIEW_RERUN_HINT="${!hint:-}" REVIEWER_WORKDIR="$WORKROOT/$rid"
    unset YUNXIAO_TOKEN_INSPECTOR YUNXIAO_TOKEN_SECURITY
    /bin/mkdir -p "$REVIEWER_WORKDIR"
    exec /bin/bash -p "$PKG/reviewers/${rid}.sh"
  ) &
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
