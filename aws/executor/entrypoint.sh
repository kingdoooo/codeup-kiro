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
# HEAD_SHA 同样必填（评审哪个提交全靠它，见下面「检出 MR 的那个提交」那一段）。刻意**不用** `:?`：
# 那样退出码是 1，而检出那一段的每条 fail-closed 出口都是 92，运维按退出码查表（§8）——同一件事
# 给两个码只会让人查错行。位置也要在这里、而不是等到用它的地方：缺了它整轮注定失败，没有理由先跑完
# 一次镜像摘要门与一次全量 clone（复审 M-3）。形状校验放在检出那一段（紧邻使用处，便于单独测）。
[[ -n "${HEAD_SHA:-}" ]] || { echo "缺少 HEAD_SHA（由调度器经 RunTask 环境覆盖传入，评审哪个提交全靠它）" >&2; exit 92; }
# 目标分支可选（调度器对缺失值不传；未设置时评审脚本按源分支经 OpenAPI 反查），缺省必须在任何使用之前——
# `set -u` 下 `|| true` 救不了未绑定变量的展开，放在使用之后的缺省是死代码。
: "${MR_TARGET_BRANCH:=}"

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
#
# git 失败时打它 stderr 的**尾巴**（以前一律丢掉，退出码 91 这个最常见的真实故障——跨境网络、令牌
# 过期——因此查不下去，全分支复审 s1/s6）。只进容器日志、绝不进 MR 评论；文件放在业务库之外。
# 令牌不会出现在里面：它只经上面那个 helper 交给 git，git 从不打印 helper 给的密码，主机检查也
# 不允许 URL 里带 userinfo。仍按深度防御把任何 `scheme://…@` 的 userinfo 抹掉。git 的报错会带分支名
# （MR 作者可控），所以逐行去掉控制字符、截到 200 字节、加固定前缀：伪造不出一行像样的日志。
# 截断按字节：超过 200 字节的行末尾可能留下半个 UTF-8 字符（日志里显示为替换符），纯外观，有意不处理
# （issue 05 D2：换成「截到 200 字节再去掉被截断的半个字符」要引入容器里 mawk 的八进制转义方言依赖，为外观问题不值得）。
GIT_ERR="$WORKROOT/git-stderr.log"
git_err_tail() {
  [[ -s "$GIT_ERR" ]] || return 0
  /usr/bin/tail -n 5 "$GIT_ERR" | LC_ALL=C /usr/bin/tr -d '\000-\010\013-\037\177' \
    | LC_ALL=C /usr/bin/sed -E 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]*@#\1<redacted>@#g' \
    | LC_ALL=C /usr/bin/cut -c1-200 | LC_ALL=C /usr/bin/sed 's/^/  git: /' >&2 || true
}
# `--no-tags` 是**承重的**，不只是省流量：服务端若有一个叫 `origin/<目标分支>` 的标签，clone 下来的
# `refs/tags/origin/<目标分支>` 会遮蔽 `refs/remotes/origin/<目标分支>`（git 解析短名字时 refs/tags
# 排在 refs/remotes 之前），引擎第 4 步的 merge-base 就解析到那个标签——标签由有推送权限的人随意指，
# 指到 MR 头就是 diff 为空、静默漏评，与下面 `-B` 那个坑同一类。`--no-tags` 还会写下
# `remote.origin.tagOpt=--no-tags`，引擎自己那次 fetch 也就不会顺带取标签。tests/test-aws-entrypoint.sh
# 的 ⑲ 有一个服务端带这种标签的变体。
# Codeup 的 git HTTP 限流（429）有界重试（issue 03，scripts/lib/git-retry.sh）：clone、补取源分支、ls-remote 都经它，
# 只重试 429（10/20/40 秒）；别的失败原样立刻返回。重试时的「N 秒后重试」提示与最后一次的报错一起进 GIT_ERR。
source "$PKG/scripts/lib/git-retry.sh"
retry_git_429 /usr/bin/git clone --no-tags "$repo_url" \
  "$WORKROOT/business" >/dev/null 2>"$GIT_ERR" \
  || { echo "clone 业务库失败（凭证、网络或仓库权限）" >&2; git_err_tail; exit 91; }

# ── 检出 MR 的那个提交（clone 给的是仓库默认分支）────────────────────
# `git clone` 检出的是**仓库默认分支**；Flow 那侧是平台按 MR 事件检出**源分支**。引擎从
# `git rev-parse HEAD` 取「本次评审的提交」（scripts/kiro-review.sh:602 / :653 / :1513，还有 :975 的
# 短 sha），自己不做任何 checkout——所以不补这一步，AWS 档位每次评审的都是默认分支。真实 Fargate
# 运行实测过（Task 14 验收，Codeup-Demo MR !4）：汇总标记写成 `<!-- kiro-review:f29435f run:1 -->`，
# f29435f 是 master 的头，而 MR 的头是 7baa0cd。
#
# 三个入参在这里**再查一次形状**（调度器的 classify 已经查过同样的规则，这是执行器侧的第二道，
# 与主机检查同一条理由：执行器不假设上游一定校验过）。它们随后会成为 git 的参数：`HEAD_SHA` 只认
# 40 位小写十六进制，分支名不得以 `-` 开头（会被当成选项）、不得含空白或控制字符。目标分支是可选的，
# 只在非空时查（空 = 引擎按源分支反查目标分支）。
# 消息里**不回显取值**：分支名是 MR 作者可控的不受信取值（引擎侧同样只在掩码后记录）。
# （「HEAD_SHA 有没有传」在文件顶部就判过了，与另外几个必填项在一起——那里还没有任何网络 I/O。）
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "HEAD_SHA 不是 40 位小写十六进制，拒绝评审（取值不回显）" >&2; exit 92; }
[[ -n "$CI_COMMIT_REF_NAME" && "$CI_COMMIT_REF_NAME" != -* \
   && ! "$CI_COMMIT_REF_NAME" =~ [[:space:]] && ! "$CI_COMMIT_REF_NAME" =~ [[:cntrl:]] ]] \
  || { echo "CI_COMMIT_REF_NAME 为空、以 - 开头或含空白/控制字符，拒绝评审（取值不回显）" >&2; exit 92; }
[[ -z "$MR_TARGET_BRANCH" ]] || [[ "$MR_TARGET_BRANCH" != -* \
   && ! "$MR_TARGET_BRANCH" =~ [[:space:]] && ! "$MR_TARGET_BRANCH" =~ [[:cntrl:]] ]] \
  || { echo "MR_TARGET_BRANCH 以 - 开头或含空白/控制字符，拒绝评审（取值不回显）" >&2; exit 92; }
# 这里**不再**单独取一次目标分支（issue 03 G4）：全量 clone 已经带了 `refs/remotes/origin/<目标>`，引擎第 4 步
# 自己还会用带前缀的 refspec 再取一次（并在取不到时给出「无法 fetch 目标分支」）——多一次往返只会在 Codeup 限流时
# 多撞一次 429。形状检查（上面那道 92）照旧：MR_TARGET_BRANCH 随后会原样交给引擎。
# 全量 clone 后 HEAD_SHA 通常已在本地；不在（评审排队期间源分支又被推过）就再取一次源分支。
# 这次取的是 origin，也就是目标仓库：跨 fork 的 MR 的提交不在这里，将来要支持时得另取 fork 的地址。
# 取不到不在这里判死：下面的 checkout 会给出同一个结论（报错尾巴先留在日志里）。
if ! /usr/bin/git -C "$WORKROOT/business" rev-parse --verify --quiet "${HEAD_SHA}^{commit}" \
     >/dev/null 2>&1 \
   && ! retry_git_429 /usr/bin/git -C "$WORKROOT/business" fetch --no-tags origin \
       "+refs/heads/${CI_COMMIT_REF_NAME}:refs/remotes/origin/${CI_COMMIT_REF_NAME}" \
       >/dev/null 2>"$GIT_ERR"; then
  echo "补取源分支失败（取值不回显）" >&2; git_err_tail
fi
# **分离头指针**（`--detach`），刻意不建本地分支。原先写的是 `-B "$CI_COMMIT_REF_NAME"`，那是一个
# 可被 MR 作者触发的静默漏评（复审 I-1，本机真 git 复现过）：`-B` 建的是 `refs/heads/<源分支名>`，
# 而 git 解析短名字时 refs/heads 排在 refs/remotes 之前。源分支若叫 `origin/master`（合法分支名，
# 调度器与这里的形状检查都不该拒它），引擎第 4 步的 `git merge-base "origin/${TARGET_BRANCH}" HEAD`
# 里那个 `origin/master` 就解析到 MR 头本身（git 只打一句 `warning: refname … is ambiguous`）：
# merge-base == HEAD → diff 为空 → 引擎打「diff 为空，跳过评审」并 exit 0 → 执行器置「已回写」标记 →
# 兜底 Lambda 看到 exitCode 0 也不吭声。**一条评论都没有的静默漏评**，而且检出后的 HEAD 核对也拦不住
# （HEAD 确实是对的）。分离头指针没有这个歧义，也没丢任何引擎要读的东西：分支名引擎取自
# CI_COMMIT_REF_NAME（本档位必填），`:958` 那个 `--abbrev-ref HEAD` 兜底在这里是死代码。
/usr/bin/git -C "$WORKROOT/business" checkout -q --detach "$HEAD_SHA" \
  >/dev/null 2>"$GIT_ERR" \
  || { echo "检出 MR 的提交失败：HEAD_SHA 指的提交不在业务库里——源分支被改写/强推/删除，或上面那次补取源分支没成功（git 可能不接受这个分支名）" >&2; git_err_tail; exit 92; }
# 检出之后**逐字核对**：checkout 成功但 HEAD 不是那个提交（将来有人改动上面这行检出写法）时，
# 评审会静默地评错提交——那正是本次要修的缺陷，不能修完再留一条同样静默的路径。
head_now=$(/usr/bin/git -C "$WORKROOT/business" rev-parse HEAD 2>/dev/null || true)
[[ "$head_now" == "$HEAD_SHA" ]] \
  || { echo "检出之后 HEAD 与 HEAD_SHA 不一致，拒绝评审（避免静默评错提交）" >&2; exit 92; }

# ── 按 MR 的租约：同一 MR 同时最多一次引擎运行（spec I6 ②）────────────
# 调度器的抢锁键含 head SHA（I6 ①），只能去重「同一次投递」，挡不住同一 MR 的两次推送各起一个任务。
# 真实环境实测过（Task 14 验收 C2）：两个任务并发评同一个 MR，历次表丢一行；后结束的那个若是旧提交，
# 唯一那条汇总评论会被改回旧提交的结论。所以引擎之前先拿一把**按 MR** 的租约，拿不到就等。
# 不变式（全分支复审 s3 I-1）：
#   L1 租约有效期内，同一 MR 至多一次引擎运行；
#   L2 接管只比较 lease_until，不靠 DynamoDB TTL 删除（TTL 是惰性的，可能迟到约 48 h）；
#   L3 释放以「持有者是我」为条件，绝不放掉别人的租约；
#   L4 键 `lease#<仓库>#<MR>` 与抢锁键不相交（抢锁键以数字开头），同一张表可以共用；
#   L5 最后一个拿到租约的任务评的是当前的头（拿到之后核对源分支，见下一段）；
#   L6 退出（任何路径）时续期循环已停，释放之后不会再有续期成功（issue 04）。
# 租期短、持有期间续期（issue 04）：租期 120 秒，拿到之后后台每 30 秒续一次。不按引擎最坏耗时定一个长租期——
# 那个最坏值约 1–1.5 小时（每次 Codeup API 最坏约 195 秒、一次评审十几次调用，引擎自己的 git fetch 还没有上限），
# 被强杀的任务（OOM、StopTask 之后迟迟不退被 SIGKILL）会把 MR 挡上那么久；短租期下最多 120 秒就能被接管（L2），
# 所以也不需要 init 进程来保证陷阱一定跑到。（StopTask 的 SIGTERM 本身陷阱是接得住的：挂了 EXIT 陷阱的 bash 作为
# PID 1 会跑陷阱、释放租约、以 143 退出——issue 04 复审在 debian:stable-slim 的 bash 5.2 里实验过。）
# 引擎包在总时长上限 engine_cap = KIRO_TIMEOUT + 1800 秒里：它给续期（也就是持有时长）设了上界，也给挂住的任务的
# Fargate 费用设了上界。KIRO_TIMEOUT 不是纯数字时按引擎的缺省 900 算：引擎自己会拒绝这个取值并在 MR 上说明
# （die_review），这里不抢它的活。等待上限 = engine_cap + 600：持有者合法持有的最长时间（引擎 + KILL 余量 30 秒 +
# 拿到租约后核对最新提交，其中 ls-remote 被限流时最坏约 190 秒——issue 03 复审），再加上它死后租约失效的 120 秒。
# 退化：续期失败到租约过期（DynamoDB 持续不可用两分钟以上），别人就会接管、两者并发——就是加租约之前的行为。
LEASE_TTL=120
LEASE_RENEW_EVERY=30
engine_cap=900
if [[ "${KIRO_TIMEOUT:-}" =~ ^[0-9]+$ ]]; then engine_cap=$((10#$KIRO_TIMEOUT)); fi
engine_cap=$((engine_cap + 1800))
lease_wait_limit=$((engine_cap + 600))
lease_key=$(/usr/bin/jq -cn --arg k "lease#${CODEUP_REPO_ID}#${MR_LOCAL_ID}" '{pk: {S: $k}}')
# 持有者 = LOCK_KEY + 本任务 ARN（issue 02）。只记 LOCK_KEY 不够：同一个键可以有两个任务（RunTask 客户端耗尽重试、
# 服务端其实已经起了，调度器释放锁之后同一报文又被重放），下面的 `#h = :me` 会把第二个当成本人放进去——L1 破。
# ARN 取自**任务级**端点的 TaskARN（文档保证的字段：v4 只增不删不改名）；容器级响应里的 Labels 是 Docker 标签，
# 不是契约。读不到或形状不对就 fail closed（93），与上面 N1 门对同一个元数据服务的处理一致。
# 这个值在任务整个生命期不变，所以 AWS CLI 自己的重试（上一次尝试已经写入、应答丢了）仍被 `#h = :me` 认成本人。
task_meta=$(/usr/bin/curl -sf --max-time 10 "${ECS_CONTAINER_METADATA_URI_V4}/task" || true)
task_arn=$(printf '%s' "$task_meta" | /usr/bin/jq -r '.TaskARN // empty' 2>/dev/null || true)
[[ "$task_arn" =~ ^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:task/[A-Za-z0-9_/-]+$ ]] || {
  echo "读不到本任务的 ARN（ECS 任务级元数据端点），无法确定租约持有者，拒绝评审" >&2; exit 93; }
lease_me="${LOCK_KEY}|${task_arn}"
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
# ls-remote 经上面导出的凭证 helper 访问 origin（即主机检查过的那个地址），不需要任何新 API；
# 包在 30 秒上限里（issue 04：挂住的连接会让任务永远不结束），超时同样算「核对未知」；撞上 429 按 issue 03 重试——
# 限流下核对失败会让本任务照常评审旧提交，那正是会把汇总评论改回旧结论的场景。
# 新提交的抢锁键是调度器 lock_key() 对 MR 事件的形状（仓库#MR#提交，不带评论 id）；
# aws/tests/test_lock_key_contract.py 用真实的 lock_key() 核对这一行，两边不会各写各的。
head_check_superseded() {
  local ls_out tip="" ls_sha ls_ref tip_key claim_rc=0 claim_out claim_pk
  ls_out=$(retry_git_429 /usr/bin/timeout 30 /usr/bin/git -C "$WORKROOT/business" ls-remote origin \
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
lease_err=""
lease_deadline=$(( $(/bin/date +%s) + lease_wait_limit ))
lease_waiting=0
while :; do
  lease_rc=0; lease_acquire || lease_rc=$?
  if [[ "$lease_rc" -eq 0 ]]; then break; fi
  # 读写租约本身失败：不知道有没有别的任务在评这个 MR，fail closed（兜底 Lambda 会按退出码回写）。
  if [[ "$lease_rc" -ne 1 ]]; then
    echo "读写 MR 租约失败（code=${lease_err}），拒绝评审" >&2; exit 93; fi
  if (( $(/bin/date +%s) >= lease_deadline )); then
    # 排队等到上限的任务先再核对一次：连推三次以上时，排在后面的旧任务往往早已被取代——那时安静退出，
    # 不让兜底 Lambda 为一个旧提交发「评审未完成」（issue 04 A-M3）。没拿到租约，退出时什么都不碰。
    if head_check_superseded; then exit 0; fi
    echo "等待同一 MR 的上一次评审超过 ${lease_wait_limit} 秒仍未结束，拒绝评审" >&2; exit 93; fi
  if [[ "$lease_waiting" -eq 0 ]]; then
    echo "同一 MR 的上一次评审仍在进行，等待租约（最长 ${lease_wait_limit} 秒）" >&2; lease_waiting=1; fi
  /bin/sleep 10
done
# 拿到了才挂陷阱：没拿到就退出时，租约是别人的，碰都不能碰。陷阱先停续期循环、再释放（L6）；
# 续期循环是后台子 shell，EXIT 陷阱不会被它继承，它被 kill 时不会自己去释放。
lease_renewer_pid=""
lease_exit() {
  if [[ -n "$lease_renewer_pid" ]]; then
    kill "$lease_renewer_pid" 2>/dev/null || true
    wait "$lease_renewer_pid" 2>/dev/null || true
  fi
  lease_release
}
trap lease_exit EXIT
lease_renew_loop &
lease_renewer_pid=$!

# ── 拿到租约之后核对源分支的最新提交（L5，见 head_check_superseded）────────────
if head_check_superseded; then exit 0; fi

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
# 总时长上限（见租约那一段开头）：超时 124 原样透出——兜底 Lambda 的通用文案写着「任务超时」；
# 30 秒内不理 TERM 就 KILL（137）。137 与 OOM 同码，所以只在确实跑满了上限时才打那行消息，运维靠它区分两者。
# 引擎内层 timeout 下的 kiro-cli 自成进程组、不被这里杀掉，但本文件是 PID 1，它一退出整个任务就结束。
engine_t0=$(/bin/date +%s)
/usr/bin/timeout -k 30 "$engine_cap" /bin/bash -p "$PKG/scripts/kiro-review.sh" || rc=$?
if [[ "$rc" -eq 124 ]] || { [[ "$rc" -eq 137 ]] && (( $(/bin/date +%s) - engine_t0 >= engine_cap )); }; then
  echo "评审引擎超过总时长上限 ${engine_cap} 秒仍未结束，已终止" >&2
fi
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
