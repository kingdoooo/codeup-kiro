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
# 锁键由调度器算好传进来，与抢锁时写入的是同一个字符串（评论命令还多一段评论 id）——本文件绝不自己拼（I1）。
: "${LOCK_KEY:?缺少 LOCK_KEY（由调度器经 RunTask 环境覆盖传入，与抢锁写入的键是同一个字符串）}"

# ── N1 镜像摘要门：在任何评审动作之前 ────────────────────────────────
# 查【容器级】端点、取顶层 .ImageID——不是 `${...}/task`（任务级，返回本任务下全部容器的列表，
# 无自证身份、无顺序保证）。任务里一旦加一个日志路由/X-Ray sidecar，`.Containers[0]` 就可能读到
# 别的容器，N1 会悄悄校验错误的镜像而评审容器本身的摘要从未被核对——这就废了本任务唯一要守的不变式。
: "${KIRO_IMAGE_DIGESTS:?缺少 KIRO_IMAGE_DIGESTS（已探测镜像摘要名单，必配无默认）}"
meta=$(/usr/bin/curl -sf "${ECS_CONTAINER_METADATA_URI_V4}" || true)
raw_digest=$(printf '%s' "$meta" | /usr/bin/jq -r '.ImageID // empty')
# ECS 返回的 ImageID 带 `sha256:` 前缀（如 `sha256:25f3...`）；约定 KIRO_IMAGE_DIGESTS 里存的是
# 去掉这个前缀之后的裸十六进制串，所以这里核对前也剥一次前缀，两边口径才对得上。
self_digest="${raw_digest#sha256:}"
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

rc=0
/bin/bash -p "$PKG/scripts/kiro-review.sh" || rc=$?
# 标记只在脚本干净退出（rc=0）时才置位——不能不分退出码都置位。脚本在 MR 定位
# 之前有三类路径会以非零退出却什么评论都没写：path-gate 的裸 exit、die() 里的
# 依赖/环境校验、MR 定位歧义（Phase 1 的 I10 契约只保证「MR 定位之后」的失败必定
# 写过评论，定位之前这几类根本没保证）。不分退出码都置位的话，兜底 Lambda 会被
# 这些「没发过评论」的失败静默拦下——这正是本任务要堵住的 I10 缺口，不能自己开一个。
# rc=0 时脚本已经跑完：要么真的发了评论，要么是空 diff 跳过（这种情况 should_post
# 自己会靠容器 exitCode==0 挡住，不依赖这个标记），置位是安全的。rc 非零一律不置位，
# 宁可让兜底 Lambda 在「脚本其实已经发过评论」的失败上多发一条重复评论——这是已知
# 可接受的权衡（重复好于沉默）——也不要在那三类沉默失败上再次沉默。
# 条件 attribute_exists(pk)：只给调度器抢锁时建好的那条记录置位。记录不在（TTL 已清、键不对）时条件
# 失败、什么也不写——绝不新建一条没有 expires_at 的记录：锁表的 TTL 看 expires_at，缺了它永不过期，
# 这个 MR 之后的每次投递都会被当成重复（N4）。键的 JSON 交给 jq 生成，不手拼引号。
if [[ "$rc" -eq 0 ]]; then
  /usr/local/bin/aws dynamodb update-item --region "$AWS_REGION" \
    --table-name "$LOCK_TABLE" \
    --key "$(/usr/bin/jq -cn --arg k "$LOCK_KEY" '{pk: {S: $k}}')" \
    --condition-expression 'attribute_exists(pk)' \
    --update-expression 'SET #p = :t' \
    --expression-attribute-names '{"#p":"posted"}' \
    --expression-attribute-values '{":t":{"BOOL":true}}' >/dev/null 2>&1 || true
fi
exit "$rc"
