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
# 目标分支可选（调度器对缺失值不传；未设置时评审脚本按源分支经 OpenAPI 反查），缺省必须在任何使用之前——
# `set -u` 下 `|| true` 救不了未绑定变量的展开，放在使用之后的缺省是死代码。
: "${MR_TARGET_BRANCH:=}"

# ── N1 镜像摘要门：在任何评审动作之前 ────────────────────────────────
# 查【容器级】端点、取顶层 .ImageID——不是 `${...}/task`（任务级，返回本任务下全部容器的列表，
# 无自证身份、无顺序保证）。任务里一旦加一个日志路由/X-Ray sidecar，`.Containers[0]` 就可能读到
# 别的容器，N1 会悄悄校验错误的镜像而评审容器本身的摘要从未被核对——这就废了本任务唯一要守的不变式。
: "${KIRO_IMAGE_DIGESTS:?缺少 KIRO_IMAGE_DIGESTS（已探测镜像摘要名单，必配无默认）}"
: "${ECS_CONTAINER_METADATA_URI_V4:?缺少 ECS_CONTAINER_METADATA_URI_V4（ECS 容器级元数据端点），无法核对镜像摘要}"
meta=$(/usr/bin/curl -sf "${ECS_CONTAINER_METADATA_URI_V4}" || true)
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

# ── clone 业务库（受信代码决定不受信的树落在哪里）────────────────────
/bin/rm -rf "$WORKROOT"; /bin/mkdir -p "$WORKROOT"
# clone 地址来自 webhook 报文（`repository.git_http_url`），而 webhook 鉴权只是一个共享密钥：
# 谁拿到它就能把地址改成任意主机，凭证 helper 随后会把云效组织令牌交给那台主机——弱密钥就此
# 升级成组织令牌。调度器的 classify 已经校验过前缀，这里再查一次是深度防御：执行器不假设
# 上游一定校验过（今天同一个仓库，明天可能不是）。
repo_url="https://${BUSINESS_REPO_URL#https://}"
repo_host="${repo_url#https://}"; repo_host="${repo_host%%/*}"
# 主机必须**逐字**等于 codeup.aliyun.com：`user@evil.com`、`codeup.aliyun.com@evil.com`、
# `codeup.aliyun.com.evil.com` 都不等，因此全被挡。
# 消息里绝不回显地址或主机：BUSINESS_REPO_URL 是外部可控的，真被写成
# `https://oauth2:<令牌>@…` 时回显就等于把令牌打进日志（与 ⑤ 同一条理由）。
[[ "$repo_host" == "codeup.aliyun.com" ]] || {
  echo "业务库地址的主机不是 codeup.aliyun.com，拒绝 clone" >&2; exit 91; }
# 令牌只经 credential helper 回调时从环境读取，不拼进 URL 或任何命令行参数——
# 命令行参数经 /proc/<pid>/cmdline、ps 等对同机其他进程可见，比日志更容易泄露。
# 这一行的**单引号**是承重的：`$YUNXIAO_TOKEN` 在这里不被外层 bash 展开，cred_helper 里存的只是
# 字面的 `$YUNXIAO_TOKEN` 十四个字符；git 稍后把这段交给 `sh -c` 子进程执行时才真正展开（该子进程
# 继承本脚本的环境）。改成双引号就会把密文展开进下面那个导出的环境变量，等于把它摊给容器里每一个
# 进程（/proc/<pid>/environ）——tests/test-aws-entrypoint.sh 有一条行为断言守着这件事。
cred_helper='!f() { echo "username=oauth2"; echo "password=$YUNXIAO_TOKEN"; }; f'
# helper 经**环境变量**下发给所有子进程（`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` /
# `GIT_CONFIG_VALUE_<n>`），不是 `-c`：`-c` 只作用于本进程发起的那一次 git 调用，而评审引擎
# （`scripts/kiro-review.sh` 第 4 步）自己还要在业务库里 `git fetch` 目标分支、必要时再
# `git fetch --unshallow`。Flow 档位由平台检出业务库并留下可用凭证，AWS 档位得由执行器提供。
# 真实 Fargate 运行实测过这个坑（Task 14 验收阻塞）：装机、摘要、自检、版本门全过，到引擎那次
# fetch 才报 `fatal: could not read Username for 'https://codeup.aliyun.com'`，评审整轮失败。
# scripts/ 是两个档位共用的引擎、不因 AWS 而改（I9），所以凭证必须以「任何子进程都能用」的形式给。
#
# helper 仍然**按 URL 限定**（`credential.<url>.helper`），不是全局的 `credential.helper`：全局
# helper 对任何主机的凭证询问都会作答，所以一次重定向（或上面那道主机检查将来被绕过）就足以把
# 令牌交出去。限定之后 git 只在向 codeup.aliyun.com 询问凭证时才调它，别的主机拿不到任何东西。
#
# 这三个变量**不会**进 Kiro 进程：kiro-cli 一律以 `env -i` + 固定许可清单启动
# （scripts/lib/kiro-agent.sh:387 的 KIRO_ENV_FIXED_NAMES，里面没有 GIT_CONFIG_*，也没有
# YUNXIAO_TOKEN；逃生口 KIRO_ENV_PASSTHROUGH 另有 `YUNXIAO_*` 这条拒绝规则，:412）。
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0='credential.https://codeup.aliyun.com.helper'
export GIT_CONFIG_VALUE_0="$cred_helper"
# 本文件自己的 clone/fetch 因此不再需要 `-c`：凭证只有这一处来源，两种写法并存迟早分叉。
/usr/bin/git clone --no-tags "$repo_url" \
  "$WORKROOT/business" >/dev/null 2>&1 \
  || { echo "clone 业务库失败（凭证、网络或仓库权限）" >&2; exit 91; }
[[ -z "$MR_TARGET_BRANCH" ]] || /usr/bin/git -C "$WORKROOT/business" \
  fetch --no-tags origin "$MR_TARGET_BRANCH" >/dev/null 2>&1 || true

# ── 检出 MR 的那个提交（clone 给的是仓库默认分支）────────────────────
# `git clone` 检出的是**仓库默认分支**；Flow 那侧是平台按 MR 事件检出**源分支**。引擎从
# `git rev-parse HEAD` 取「本次评审的提交」（scripts/kiro-review.sh:602 / :653 / :1513，还有 :975 的
# 短 sha），自己不做任何 checkout——所以不补这一步，AWS 档位每次评审的都是默认分支。真实 Fargate
# 运行实测过（Task 14 验收，Codeup-Demo MR !4）：汇总标记写成 `<!-- kiro-review:f29435f run:1 -->`，
# f29435f 是 master 的头，而 MR 的头是 7baa0cd。
#
# 两个入参在这里**再查一次形状**（调度器的 classify 已经查过同样的规则，这是执行器侧的第二道，
# 与主机检查同一条理由：执行器不假设上游一定校验过）。它们随后会成为 git 的参数：`HEAD_SHA` 只认
# 40 位小写十六进制，分支名不得以 `-` 开头（会被当成选项）、不得含空白或控制字符。
# 消息里**不回显取值**：分支名是 MR 作者可控的不受信取值（引擎侧同样只在掩码后记录）。
: "${HEAD_SHA:?缺少 HEAD_SHA（由调度器经 RunTask 环境覆盖传入，评审哪个提交全靠它）}"
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "HEAD_SHA 不是 40 位小写十六进制，拒绝评审（取值不回显）" >&2; exit 92; }
[[ -n "$CI_COMMIT_REF_NAME" && "$CI_COMMIT_REF_NAME" != -* \
   && ! "$CI_COMMIT_REF_NAME" =~ [[:space:]] && ! "$CI_COMMIT_REF_NAME" =~ [[:cntrl:]] ]] \
  || { echo "CI_COMMIT_REF_NAME 为空、以 - 开头或含空白/控制字符，拒绝评审（取值不回显）" >&2; exit 92; }
# 全量 clone 后 HEAD_SHA 通常已在本地；不在就再取一次源分支（评审期间源分支被推过、或将来支持
# 跨 fork 时都会走到这里）。取不到不在这里判死：下面的 checkout 会给出同一个结论。
/usr/bin/git -C "$WORKROOT/business" rev-parse --verify --quiet "${HEAD_SHA}^{commit}" >/dev/null 2>&1 \
  || /usr/bin/git -C "$WORKROOT/business" fetch --no-tags origin \
       "+refs/heads/${CI_COMMIT_REF_NAME}:refs/remotes/origin/${CI_COMMIT_REF_NAME}" \
       >/dev/null 2>&1 || true
# `-B <源分支名> <提交>`：本地分支名与源分支一致、停在那个提交上——最接近 Flow 检出后的状态
# （引擎第 3 步的 `SOURCE_BRANCH` 取自 CI_COMMIT_REF_NAME，分离头指针只会让人在日志里看不懂）。
# 结尾的 `--` 断掉「分支名碰巧也是一个路径」的歧义（形状已校验过，这是第二道）。
/usr/bin/git -C "$WORKROOT/business" checkout -q -B "$CI_COMMIT_REF_NAME" "$HEAD_SHA" -- \
  >/dev/null 2>&1 \
  || { echo "检出 MR 的提交失败：HEAD_SHA 在业务库里找不到（源分支已被改写或强推？）" >&2; exit 92; }
# 检出之后**逐字核对**：checkout 成功但 HEAD 不是那个提交（将来有人把 -B 改成别的写法）时，
# 评审会静默地评错提交——那正是本次要修的缺陷，不能修完再留一条同样静默的路径。
head_now=$(/usr/bin/git -C "$WORKROOT/business" rev-parse HEAD 2>/dev/null || true)
[[ "$head_now" == "$HEAD_SHA" ]] \
  || { echo "检出之后 HEAD 与 HEAD_SHA 不一致，拒绝评审（避免静默评错提交）" >&2; exit 92; }

# ── 与 Flow run block 完全相同的环境变量契约（I9 的裁判就看这一段）──
export REVIEW_REPO_DIR="$WORKROOT/business"
export CI_COMMIT_REF_NAME="$CI_COMMIT_REF_NAME"
# `:=` 缺省在文件顶部（使用之前）；这里的 `export` 必须单独占一行、顶格出现，才能被
# tests/test-aws-entrypoint.sh 断言 ① 的锚定正则（`^[[:space:]]*export`）当作「本文件导出的变量」
# 收进 entry_vars——那条正则就是 I9 的裁判，和别的语句写在一行会让它读不到 MR_TARGET_BRANCH。
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
