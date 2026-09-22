#!/usr/bin/env bash
# AWS 档位的受信 entrypoint。属于 aws/，不属于 scripts/——scripts/ 对 AWS 一无所知（I9）。
# 与 Flow 的 run block 一一对应：那边由平台检出业务库，这边由我们自己 clone，
# 因此不受信的树在被任何进程看到之前，位置就已经由受信代码决定了。
set -euo pipefail

PKG=/opt/integration
WORKROOT=/tmp/review
: "${CODEUP_REPO_ID:?缺少 CODEUP_REPO_ID（由调度器经 RunTask 环境覆盖传入）}"
: "${MR_LOCAL_ID:?缺少 MR_LOCAL_ID}"
: "${CI_COMMIT_REF_NAME:?缺少 CI_COMMIT_REF_NAME（业务库源分支）}"
: "${BUSINESS_REPO_URL:?缺少 BUSINESS_REPO_URL}"

# ── N1 镜像摘要门：在任何评审动作之前 ────────────────────────────────
: "${KIRO_IMAGE_DIGESTS:?缺少 KIRO_IMAGE_DIGESTS（已探测镜像摘要名单，必配无默认）}"
meta=$(/usr/bin/curl -sf "${ECS_CONTAINER_METADATA_URI_V4}/task" || true)
self_digest=$(printf '%s' "$meta" | /usr/bin/jq -r '.Containers[0].ImageID // empty')
case " $KIRO_IMAGE_DIGESTS " in
  *" $self_digest "*) : ;;
  *) echo "镜像摘要不在已探测名单内，拒绝评审：${self_digest:-<读不到>}" >&2; exit 90 ;;
esac

# ── clone 业务库（受信代码决定不受信的树落在哪里）────────────────────
/bin/rm -rf "$WORKROOT"; /bin/mkdir -p "$WORKROOT"
# 令牌只经 credential helper 回调时从环境读取，不拼进 URL 或任何命令行参数——
# 命令行参数经 /proc/<pid>/cmdline、ps 等对同机其他进程可见，比日志更容易泄露。
# `-c credential.helper='...'` 这段值在本行单引号内不会被外层 bash 展开，
# 传给 git 的 argv 里只有字面的 `$YUNXIAO_TOKEN` 四个字符；git 稍后把它交给 `sh -c` 子进程
# 执行时才真正展开（该子进程继承本脚本的环境），密文从未出现在任何进程的启动参数里。
cred_helper='!f() { echo "username=oauth2"; echo "password=$YUNXIAO_TOKEN"; }; f'
/usr/bin/git -c credential.helper="$cred_helper" \
  clone --no-tags "https://${BUSINESS_REPO_URL#https://}" \
  "$WORKROOT/business" >/dev/null 2>&1 \
  || { echo "clone 业务库失败（凭证、网络或仓库权限）" >&2; exit 91; }
/usr/bin/git -C "$WORKROOT/business" -c credential.helper="$cred_helper" \
  fetch --no-tags origin "$MR_TARGET_BRANCH" >/dev/null 2>&1 || true

# ── 与 Flow run block 完全相同的环境变量契约（I9 的裁判就看这一段）──
export REVIEW_REPO_DIR="$WORKROOT/business"
export CI_COMMIT_REF_NAME="$CI_COMMIT_REF_NAME"
# 两条语句分开写（而不是 `: "...:="; export ...` 一行两句）：这段的 `export` 必须单独占一行、
# 顶格出现，才能被 tests/test-aws-entrypoint.sh 断言 ① 的锚定正则（`^[[:space:]]*export`）当作
# “本文件导出的变量”收进 entry_vars——那条正则就是 I9 的裁判，写成一行会让它读不到 MR_TARGET_BRANCH。
: "${MR_TARGET_BRANCH:=}"
export MR_TARGET_BRANCH
export KIRO_INSTALL_PROFILE=pinned
export KIRO_PINNED_ARTIFACT=/opt/kiro/kirocli-x86_64-linux-musl.zip

exec /bin/bash -p "$PKG/scripts/kiro-review.sh"
