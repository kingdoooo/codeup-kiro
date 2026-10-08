#!/usr/bin/env bash
# 扫描任务（Task B）：scan-entrypoint.sh 与扫描员公共骨架 aws/reviewers/lib/{reviewer,summary}.sh（Phase 2b，spec「Task B」「S2」「F1」「L7」）。
#   ① 入参形状不对 → 95，什么都不跑；
#   ② N1 那一段与 entrypoint.sh 逐字节相同（同一镜像、同一份已探测名单）；
#   ③ S2：每个扫描子进程只看得见自己的云效令牌，其它评审员的令牌与 Kiro 的密钥都不在它的环境里；
#   ④ F1：子进程退出码 → 锁记录终态（0 → posted_<评审员>，10 → superseded_<评审员>，其它 → 不置、入口退出 96）；
#   ⑤ 汇总定位与 kiro-review.sh 的 1.5 段对拍（同一批 fixture、逐项相同）；
#   ⑥ 失败评论用本评审员的档案（标题、标记族），走原地更新；
#   ⑦ L7：按评审员按 MR 的租约（键、被取代 → 10、等满上限 → 失败评论、退出时释放）。
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh
ROOT="$(cd .. && pwd)"
ENTRY=../aws/executor/entrypoint.sh
SCAN=../aws/executor/scan-entrypoint.sh
command -v python3 >/dev/null && [[ -x /usr/bin/jq ]] || { echo "SKIP: 需要 python3 与 /usr/bin/jq，跳过 test-aws-scan.sh" >&2; exit 0; }
tmp=$(mktemp -d); [[ -n "${KEEP_TMP:-}" ]] || trap 'rm -rf "$tmp"' EXIT

# 一个按镜像布局摆好的集成包根（/opt/integration 的样子）：scripts/、lib/ 指向仓库里的真文件，reviewers/ 放替身
mkdir -p "$tmp/pkg/reviewers"
ln -s "$ROOT/scripts" "$tmp/pkg/scripts"
# lib/ 必须是**换过路径的副本**，不能是符号链接：库里写死的 /usr/local/bin/aws 不换掉就会打到真的 AWS
mkdir -p "$tmp/pkg/lib"
ln -s "$ROOT/aws/reviewers/lib" "$tmp/pkg/reviewers/lib"
DIGEST=$(printf 'e%.0s' {1..64})
printf '#!/bin/sh\nprintf "{\\"ImageID\\": \\"sha256:%s\\", \\"TaskARN\\": \\"arn:aws:ecs:us-west-2:123456789012:task/c/abc\\"}"\n' "$DIGEST" > "$tmp/curl"
printf '#!/bin/sh\nexec python3 "%s/fake-aws-dynamodb.py" "$@"\n' "$PWD" > "$tmp/aws"
chmod +x "$tmp/curl" "$tmp/aws"
for f in "$ROOT"/aws/executor/lib/*.sh; do
  sed -e "s#/usr/bin/curl#$tmp/curl#g" -e "s#/usr/local/bin/aws#$tmp/aws#g" "$f" > "$tmp/pkg/lib/$(basename "$f")"
done
# 守卫：测试包根里任何一个文件都不得再指向真的 aws（否则这份测试会用本机凭证打真实账号）
assert_eq "$(LC_ALL=C grep -rl '/usr/local/bin/aws' "$tmp/pkg/lib" 2>/dev/null || true)" "" "（准备）测试包根里的库都换成了 aws 替身"
# 替身扫描员：把自己的环境（名字=值）写进文件，按 $tmp/rc.<评审员> 里的数退出（没有这个文件 = 0）。
# 退出码经文件给、不经环境变量：子进程的环境是白名单（issue 14），测试自己的变量也到不了它
# \$tmp/hang 存在时替身先登记自己（pid 与父进程 pid）、挂一个 EXIT 陷阱再睡——⑧ 用它验证 StopTask 时及时停下（issue 15）。
mkstub() {  # <评审员>
  local rid="$1"
  cat > "$tmp/pkg/reviewers/${rid}.sh" <<STUB
#!/bin/bash
env > "$tmp/env.${rid}"
if [ -e "$tmp/hang" ]; then
  /bin/sleep 30 & sp=\$!
  trap 'kill \$sp 2>/dev/null; echo ran > "$tmp/exit.${rid}"' EXIT
  echo "\$\$ \$PPID" > "$tmp/pid.${rid}"
  wait \$sp
fi
exit "\$(cat "$tmp/rc.${rid}" 2>/dev/null || echo 0)"
STUB
}
mkstub inspector; mkstub security
scan_prog=$(sed -e "s#^PKG=/opt/integration\$#PKG=$tmp/pkg#" -e "s#^WORKROOT=/tmp/scan\$#WORKROOT=$tmp/work#" \
                -e "s#/usr/bin/curl#$tmp/curl#g" -e "s#/usr/local/bin/aws#$tmp/aws#g" "$SCAN")
assert_contains "$scan_prog" "PKG=$tmp/pkg" "（准备）集成包根换成了测试布局"
SHA40=$(printf 'a%.0s' {1..40}); RUN32=$(printf 'b%.0s' {1..32})
scan_run() {  # [KEY=VAL …] → rc；stderr 在 $tmp/err
  printf '{"%s": {"pk": {"S": "%s"}}}' "r1#7#$SHA40" "r1#7#$SHA40" > "$tmp/state.json"
  rm -f "$tmp"/env.*
  local rc=0
  ( export CODEUP_REPO_ID=7 MR_LOCAL_ID=7 HEAD_SHA="$SHA40" CI_COMMIT_REF_NAME=feat MR_TARGET_BRANCH=main \
           LOCK_KEY="r1#7#$SHA40" REVIEWERS=inspector SCAN_RUN_ID="$RUN32" YUNXIAO_ORG_ID=o1 \
           SCAN_REPO_URL=https://codeup.aliyun.com/o1/r1.git KIRO_IMAGE_DIGESTS="$DIGEST" \
           ECS_CONTAINER_METADATA_URI_V4=http://meta AWS_REGION=us-west-2 LOCK_TABLE=t \
           FAKE_DDB_STATE="$tmp/state.json" FAKE_DDB_LOG="$tmp/ddb.log" \
           YUNXIAO_TOKEN_INSPECTOR=pt-insp YUNXIAO_TOKEN_SECURITY=pt-sec KIRO_API_KEY=should-not-be-here \
           INSPECTOR_BOT_USERNAME=aliyun:insp SECURITY_BOT_USERNAME=aliyun:sec INSPECTOR_RERUN_HINT=hint-i "$@"
    # SCAN_ENV_EXTRA：export 造不出来的环境项（名字非法的 `a-b=`、`BASH_FUNC_x%%`）经 env 塞进入口的环境（③b）
    /usr/bin/env ${SCAN_ENV_EXTRA[@]+"${SCAN_ENV_EXTRA[@]}"} /bin/bash --norc --noprofile -c "$scan_prog" ) 2> "$tmp/err" </dev/null || rc=$?
  echo "$rc"
}
attr_true() { /usr/bin/jq -r --arg k "r1#7#$SHA40" --arg a "$1" '.[$k][$a].BOOL // false' "$tmp/state.json"; }

# ① 入参形状不对 → 95，一个子进程都不起
for bad in REVIEWERS=kiro REVIEWERS=kiro,inspector REVIEWERS=inspector,inspector REVIEWERS= SCAN_RUN_ID=x HEAD_SHA=HEAD \
           CODEUP_REPO_ID=lease SCAN_REPO_URL=https://evil.example.com/o1/r1.git SCAN_REPO_URL=https://codeup.aliyun.com/o1/a@b.git \
           CI_COMMIT_REF_NAME=-x MR_TARGET_BRANCH="a b" YUNXIAO_ORG_ID=; do
  assert_eq "$(scan_run "$bad")" "95" "① ${bad} → 95"
  assert_eq "$(ls "$tmp"/env.* 2>/dev/null | wc -l | tr -d ' ')" "0" "① ${bad} 时一个扫描子进程都不起"
done

# ② N1 那一段逐字节相同（两边各自从标题行抽到下一个标题行之前）
n1_entry=$(awk '/^# ── N1 镜像摘要门/{f=1} /^# ── clone 业务库/{exit} f{print}' "$ENTRY")
n1_scan=$(awk '/^# ── N1 镜像摘要门/{f=1} /^# ── 按评审员的子进程/{exit} f{print}' "$SCAN")
assert_contains "$n1_scan" "exit 90" "② 抽到了扫描入口的 N1 段"
assert_eq "$n1_scan" "$n1_entry" "② 扫描入口的 N1 段与 entrypoint.sh 逐字节相同"
assert_eq "$(scan_run KIRO_IMAGE_DIGESTS="$(printf 'f%.0s' {1..64})")" "90" "② 摘要不在名单 → 90（行为）"

# ③ S2：令牌只给本评审员
assert_eq "$(scan_run REVIEWERS=inspector,security)" "0" "③ 两位扫描员都以 0 退出时入口退出 0"
ie=$(cat "$tmp/env.inspector"); se=$(cat "$tmp/env.security")
assert_contains "$ie" $'\n'"YUNXIAO_TOKEN=pt-insp"$'\n' "③ Inspector 子进程拿到自己的令牌"
assert_contains "$se" $'\n'"YUNXIAO_TOKEN=pt-sec"$'\n' "③ Security Agent 子进程拿到自己的令牌"
for e in "$ie" "$se"; do
  assert_not_contains "$e" "YUNXIAO_TOKEN_INSPECTOR=" "③ 子进程里没有 Inspector 令牌的原始变量"
  assert_not_contains "$e" "YUNXIAO_TOKEN_SECURITY=" "③ 子进程里没有 Security Agent 令牌的原始变量"
done
assert_not_contains "$ie" "pt-sec" "③ Inspector 子进程看不到 Security Agent 的令牌值"
assert_not_contains "$se" "pt-insp" "③ Security Agent 子进程看不到 Inspector 的令牌值"
assert_contains "$ie" $'\n'"CODEUP_BOT_USERNAME=aliyun:insp"$'\n' "③ 机器人用户名按评审员给"
assert_contains "$ie" $'\n'"REVIEW_RERUN_HINT=hint-i"$'\n' "③ 页脚提示按评审员给"
assert_not_contains "$(LC_ALL=C grep -vE '^[[:space:]]*#' "$SCAN")" 'env YUNXIAO' "③ 令牌不经 env NAME=值 进任何 argv"
# 任务定义层面（Kiro 的密钥不该进扫描任务）由 CDK 断言守；这里只钉入口不主动转交
assert_not_contains "$(LC_ALL=C grep -vE '^[[:space:]]*#' "$SCAN")" 'KIRO_API_KEY' "③ 扫描入口不碰 KIRO_API_KEY"

# ③b 子进程环境是白名单（issue 14，复审 M-3）：被攻破的 Task A 经 RunTask 环境覆盖塞进来的变量一个都到不了扫描员
names_of() { sed 's/=.*//' "$1" | LC_ALL=C grep -vE '^(PWD|SHLVL|_|OLDPWD)$' | sort | tr '\n' ' '; }
SCAN_ENV_EXTRA=('BASH_FUNC_evil%%=() { echo pwned; }' 'a-b=1')
assert_eq "$(scan_run REVIEWERS=inspector,security GIT_CONFIG_PARAMETERS="'credential.helper=!evil'" GIT_SSH_COMMAND=evil \
             HTTPS_PROXY=http://evil:1 LD_PRELOAD= SOME_UNKNOWN_VAR=x SECURITY_INPUT=ok SA_AGENT_SPACE_ID=as-1)" "0" \
  "③b（准备）注入了几个危险变量后照常跑完"
SCAN_ENV_EXTRA=()
for rid in inspector security; do
  for bad in GIT_CONFIG_PARAMETERS GIT_SSH_COMMAND HTTPS_PROXY LD_PRELOAD SOME_UNKNOWN_VAR BASH_FUNC_evil a-b KIRO_API_KEY \
             KIRO_IMAGE_DIGESTS REVIEWERS FAKE_DDB_STATE INSPECTOR_BOT_USERNAME; do
    assert_eq "$(sed 's/=.*//' "$tmp/env.$rid" | LC_ALL=C grep -c "^${bad}" || true)" "0" "③b ${rid} 子进程的环境里没有 ${bad}"
  done
done
assert_eq "$(LC_ALL=C grep -c 'pwned' "$tmp/env.inspector" || true)" "0" "③b 导出的 bash 函数（BASH_FUNC_x%%）没有漏进子进程"
common="AWS_REGION CI_COMMIT_REF_NAME CODEUP_BOT_USERNAME CODEUP_REPO_ID ECS_CONTAINER_METADATA_URI_V4 HEAD_SHA LOCK_KEY LOCK_TABLE MR_LOCAL_ID MR_TARGET_BRANCH PATH REVIEWER_WORKDIR REVIEW_RERUN_HINT SCAN_REPO_URL SCAN_RUN_ID YUNXIAO_ORG_ID YUNXIAO_TOKEN"
# 名单里另几项 scan_run 不设、取决于跑测试的机器（LANG、HOME 之类）：本机设了就应当在
for n in HOME LANG LC_ALL TZ AWS_DEFAULT_REGION AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_EXECUTION_ENV SCAN_BUCKET \
         SCAN_BUCKET_OWNER MAX_COMMENT_BYTES; do
  [[ -n "${!n+x}" ]] && common+=" $n"
done
want_names() { printf '%s\n' $common "$@" | sort | tr '\n' ' '; }
assert_eq "$(names_of "$tmp/env.inspector")" "$(want_names)" "③b Inspector 子进程的环境恰好是白名单里已设置的那些（正向对照：一个都不少）"
assert_eq "$(names_of "$tmp/env.security")" "$(want_names SA_AGENT_SPACE_ID SECURITY_INPUT)" \
  "③b Security Agent 子进程额外只多它自己的两项（SECURITY_INPUT、SA_AGENT_SPACE_ID）；Inspector 的不给它"
assert_contains $'\n'"$(cat "$tmp/env.inspector")"$'\n' $'\n'"REVIEWER_WORKDIR=$tmp/work/inspector"$'\n' "③b 工作目录按评审员给"
assert_eq "$(LC_ALL=C grep -c 'kiro_env_exec' <(LC_ALL=C grep -vE '^[[:space:]]*#' "$SCAN"))" "0" \
  "③b 垫片直接内联（函数放后台时 \$! 是包着它的子 shell，issue 15 要的是评审员进程本身）"

# ③c 白名单里的数值在交给扫描员之前查形状（终审 I-1）：bash 算术会对 `NAME[$(cmd)]` 的下标求值、执行 cmd——这样的取值一旦进了
#    扫描员的 $(( )) / [[ -gt ]]，被攻破的 Task A 就能在持有扫描员令牌的进程里跑命令。形状不对 → 95，一个扫描员都不起
for v in MAX_COMMENT_BYTES SECURITY_AGENT_TIMEOUT INSPECTOR_MAX_SCAN_CALLS; do
  rm -f "$tmp/env.inspector" "$tmp/env.security"
  assert_eq "$(scan_run REVIEWERS=inspector,security "$v=PATH[\$(touch $tmp/pwned)]")" "95" "③c ${v} 不是十进制整数 → 入口 95"
  assert_eq "$([ -e "$tmp/env.inspector" ] || [ -e "$tmp/env.security" ] && echo started || echo none)" "none" \
    "③c ${v} 形状不对时一个扫描员都不起"
done
assert_eq "$(scan_run REVIEWERS=inspector,security MAX_COMMENT_BYTES=60000 SECURITY_AGENT_TIMEOUT=3600 INSPECTOR_MAX_SCAN_CALLS=3)" "0" \
  "③c（正向对照）合法的数值照常跑完"

# ④ F1：退出码 → 终态
assert_eq "$(attr_true posted_inspector)/$(attr_true posted_security)" "true/true" "④ 两位都回写了 → 各自 posted"
echo 10 > "$tmp/rc.inspector"; echo 3 > "$tmp/rc.security"
assert_eq "$(scan_run REVIEWERS=inspector,security)" "96" "④ 有一位没有终态 → 入口 96"
rm -f "$tmp/rc.inspector" "$tmp/rc.security"
assert_eq "$(attr_true superseded_inspector)/$(attr_true posted_security)/$(attr_true superseded_security)" "true/false/false" \
  "④ 10 → superseded；3 → 不置任何终态（交给兜底）"
assert_contains "$(cat "$tmp/err")" "scan-reviewer reviewer=security result=failed rc=3" "④ 日志里点名没有终态的那位"
rm -f "$tmp/pkg/reviewers/security.sh"
assert_eq "$(scan_run REVIEWERS=security)" "96" "④ 驱动不存在（还没实现）→ 没有终态 → 96，不静默"

# ⑤ 汇总定位对拍：kiro-review.sh 的 1.5 段 vs aws/reviewers/lib/summary.sh，同一批 fixture、同一档案
kiro_block=$(awk '/^# --- 1\.5 定位本评审员上一次的汇总评论/{f=1} /^# --- 1\.6 流水线变量的取值校验/{exit} f{print}' ../scripts/kiro-review.sh)
assert_contains "$kiro_block" "review_select_prior_comment" "⑤ 抽到了 kiro-review.sh 的 1.5 段"
mkfix() {  # <目录> <档案> <作者> <run> → 一条带历史的旧汇总
  mkdir -p "$1"
  REVIEW_PROFILE="$2" /bin/bash --norc --noprofile -c "source '$ROOT/scripts/lib/review-render.sh'
    printf '[{\"run\":%s,\"sha\":\"abc1234\",\"verdict\":\"\",\"status\":\"\",\"p0\":1,\"p1\":0,\"p2\":0}]\n' $4 > '$1/h.json'
    review_render_comment_head \"\$REVIEW_TITLE\" abc1234 $4 '$1/h.json'; echo; echo 正文" </dev/null > "$1/c.md"
  jq -n --rawfile c "$1/c.md" --arg a "$3" '[{comment_biz_id: "cid-9", comment_type: "GLOBAL_COMMENT", state: "OPENED", author: {username: $a}, content: $c}]' \
    > "$1/list-comments.json"
}
run_locator() {  # <kiro|scan> <档案> <fixture 目录> <机器人用户名> → 「PRIOR_COMMENT_ID|REVIEW_RUN|历史」
  local code
  if [[ "$1" == kiro ]]; then
    code="log() { :; }; die_review() { echo DIE; exit 7; }; INLINE_COMMENT=0; INLINE_NOTICE=''; PRIOR_COMMENT_ID=''; REVIEW_RUN=1; PRIOR_HISTORY_FILE=''
$kiro_block"
  else
    code="log() { :; }; reviewer_fail() { echo DIE; exit 7; }; source '$ROOT/aws/reviewers/lib/summary.sh'; summary_locate_prior"
  fi
  mkdir -p "$tmp/w.$1"
  REVIEW_PROFILE="$2" DRY_RUN=1 DRY_RUN_FIXTURE_DIR="$3" CODEUP_BOT_USERNAME="$4" YUNXIAO_ORG_ID=o1 CODEUP_REPO_ID=7 \
    /bin/bash --norc --noprofile -c "set -euo pipefail; source '$ROOT/scripts/lib/review-render.sh'; source '$ROOT/scripts/lib/codeup-api.sh'
    WORK='$tmp/w.$1'; LOCAL_ID=7
    $code
    printf '%s|%s|%s\n' \"\$PRIOR_COMMENT_ID\" \"\$REVIEW_RUN\" \"\$( [[ -n \"\$PRIOR_HISTORY_FILE\" ]] && jq -c . \"\$PRIOR_HISTORY_FILE\" )\"" \
    2>/dev/null </dev/null
}
mkfix "$tmp/fx-insp" inspector aliyun:bot 3
mkfix "$tmp/fx-kiro" kiro aliyun:bot 5
mkdir -p "$tmp/fx-empty"; echo '[]' > "$tmp/fx-empty/list-comments.json"
for case in "inspector fx-insp aliyun:bot" "inspector fx-kiro aliyun:bot" "kiro fx-kiro aliyun:bot" "kiro fx-insp aliyun:bot" \
            "inspector fx-insp aliyun:other" "inspector fx-insp ''" "inspector fx-empty aliyun:bot"; do
  set -- $case; [[ "$3" == "''" ]] && set -- "$1" "$2" ""
  k=$(run_locator kiro "$1" "$tmp/$2" "$3"); s=$(run_locator scan "$1" "$tmp/$2" "$3")
  assert_eq "$s" "$k" "⑤ 对拍（档案 $1 / fixture $2 / 机器人 '${3}'）：summary_locate_prior 与 kiro-review.sh 1.5 段结果相同"
done
assert_eq "$(run_locator scan inspector "$tmp/fx-insp" aliyun:bot)" \
  'cid-9|4|[{"run":3,"sha":"abc1234","verdict":"","status":"","p0":1,"p1":0,"p2":0}]' "⑤ 正向对照：找到自己的旧汇总、run+1、读回历史"
assert_eq "$(run_locator scan inspector "$tmp/fx-kiro" aliyun:bot)" "|1|" "⑤ M1：Inspector 不接管 Kiro 的汇总"

# ⑥ 失败评论：本评审员的档案、原地更新那一条
drv="$tmp/drv.sh"
cat > "$drv" <<DRV
PKG=$tmp/pkg; REVIEW_PROFILE=inspector
source "\$PKG/reviewers/lib/reviewer.sh"
summary_locate_prior
reviewer_fail "Inspector 扫描输入准备失败（代号 sbomgen-timeout）"
DRV
out=$( mkdir -p "$tmp/w6"; REVIEWER_WORKDIR="$tmp/w6" DRY_RUN=1 DRY_RUN_FIXTURE_DIR="$tmp/fx-insp" CODEUP_BOT_USERNAME=aliyun:bot \
       YUNXIAO_ORG_ID=o1 CODEUP_REPO_ID=7 MR_LOCAL_ID=7 HEAD_SHA="$SHA40" CI_COMMIT_REF_NAME=feat MR_TARGET_BRANCH=main \
       /bin/bash --norc --noprofile -c "set -euo pipefail; source '$drv'" 2>&1 </dev/null; echo "rc=$?")
assert_contains "$out" "rc=0" "⑥ 失败评论发出去 → 退出 0（终态）"
assert_eq "$(req_count "$out" PUT 'comments/cid-9')" "1" "⑥ 失败评论原地更新本评审员的那一条"
assert_eq "$(req_count "$out" POST 'comments$')" "0" "⑥ 没有新建第二条"
body=$(posted_comment "$out")   # helpers.sh：最后一次请求（就是那次 PUT）的正文
assert_contains "$body" "# Inspector 依赖漏洞扫描 · ⚠️ 评审未完成" "⑥ 失败评论用 Inspector 的标题"
assert_contains "$body" "<!-- kiro-inspector-review:aaaaaaa run:4 -->" "⑥ 失败评论用 Inspector 的评审标记、run 递增"
assert_contains "$body" "代号 sbomgen-timeout" "⑥ 固定文案 + 枚举代号"

# ⑦ L7：按评审员按 MR 的租约
# 第二个包根：租约库与骨架里的 aws / curl 换成替身（其余仍是仓库里的真文件）
mkdir -p "$tmp/pkg2/lib" "$tmp/pkg2/reviewers/lib"; ln -s "$ROOT/scripts" "$tmp/pkg2/scripts"
sed -e "s#/usr/bin/curl#$tmp/curl#g" -e "s#/usr/local/bin/aws#$tmp/aws#g" "$ROOT/aws/executor/lib/lease.sh" > "$tmp/pkg2/lib/lease.sh"
sed -e "s#/usr/bin/curl#$tmp/curl#g" "$ROOT/aws/reviewers/lib/reviewer.sh" > "$tmp/pkg2/reviewers/lib/reviewer.sh"
cp "$ROOT/aws/reviewers/lib/summary.sh" "$tmp/pkg2/reviewers/lib/summary.sh"
lease_drv="$tmp/lease-drv.sh"
cat > "$lease_drv" <<DRV
PKG=$tmp/pkg2; REVIEW_PROFILE=inspector
source "\$PKG/reviewers/lib/reviewer.sh"
head_check_superseded() { return "\${FAKE_SUPERSEDED:-1}"; }
reviewer_lease_and_check
echo GOT_LEASE
DRV
lease_run() {  # [KEY=VAL …] → 「rc 末行输出」
  local out rc=0
  mkdir -p "$tmp/w7"; rm -rf "$tmp/w7"/*
  out=$( REVIEWER_WORKDIR="$tmp/w7" DRY_RUN=1 DRY_RUN_FIXTURE_DIR="$tmp/fx-insp" CODEUP_BOT_USERNAME=aliyun:bot \
         YUNXIAO_ORG_ID=o1 CODEUP_REPO_ID=7 MR_LOCAL_ID=7 HEAD_SHA="$SHA40" CI_COMMIT_REF_NAME=feat MR_TARGET_BRANCH=main \
         LOCK_KEY="r1#7#$SHA40" SCAN_REPO_URL=https://codeup.aliyun.com/o1/r1.git ECS_CONTAINER_METADATA_URI_V4=http://meta \
         AWS_REGION=us-west-2 LOCK_TABLE=t FAKE_DDB_STATE="$tmp/l7.json" FAKE_DDB_LOG="$tmp/l7.log" \
         /usr/bin/env "$@" /bin/bash --norc --noprofile -c "set -euo pipefail; source '$lease_drv'" 2>"$tmp/l7.err" </dev/null) || rc=$?
  echo "$rc $(printf '%s' "$out" | tail -1)"
}
LKEY="lease#7#7#inspector"
echo '{}' > "$tmp/l7.json"
assert_eq "$(lease_run)" "0 GOT_LEASE" "⑦ 租约空闲 → 拿到、继续"
assert_eq "$(jq -r --arg k "$LKEY" '.[$k].lease_until.N' "$tmp/l7.json")" "0" "⑦ 退出时释放（lease_until 清零）"
assert_eq "$(jq -r --arg k "$LKEY" '.[$k] | has("holder")' "$tmp/l7.json")" "false" "⑦ 释放时抹掉持有者（L6）"
assert_eq "$(jq -r 'keys | map(select(startswith("lease#"))) | join(",")' "$tmp/l7.json")" "$LKEY" "⑦ 租约键 = lease#<仓库>#<MR>#<评审员>（与 Kiro 的 lease#<仓库>#<MR> 不相交）"
echo '{}' > "$tmp/l7.json"
assert_eq "$(lease_run FAKE_SUPERSEDED=0)" "10 " "⑦ 拿到租约后发现被取代 → 10（安静）"
# 别人持有一把很久才到期的租约、等待上限 0：先核对（没被取代）→ 失败评论（原地更新、退出 0）
printf '{"%s": {"pk": {"S": "%s"}, "holder": {"S": "other"}, "lease_until": {"N": "9999999999"}, "expires_at": {"N": "9999999999"}}}' "$LKEY" "$LKEY" > "$tmp/l7.json"
assert_eq "$(lease_run REVIEWER_LEASE_WAIT=0)" "0 " "⑦ 等满上限 → 失败评论（终态 0）"
assert_contains "$(cat "$tmp/l7.err")" "等待同一 MR 的上一次评审超过 0 秒仍未结束" "⑦ 失败原因是等租约超时"
assert_eq "$(jq -r --arg k "$LKEY" '.[$k].holder.S' "$tmp/l7.json")" "other" "⑦ 没拿到租约时不碰别人的租约"
printf '{"%s": {"pk": {"S": "%s"}, "holder": {"S": "other"}, "lease_until": {"N": "9999999999"}, "expires_at": {"N": "9999999999"}}}' "$LKEY" "$LKEY" > "$tmp/l7.json"
assert_eq "$(lease_run REVIEWER_LEASE_WAIT=0 FAKE_SUPERSEDED=0)" "10 " "⑦ 等满上限但已被取代 → 10（不发失败评论）"

# ⑧ StopTask 时及时停下（issue 15）：任务开了 init，入口不是 PID 1，收得到 TERM——它要把 TERM 转给每位扫描员、等它们的 EXIT
# 陷阱跑完（租约在那里释放）、以 143 退出；不能等扫描员自己跑完。替身扫描员睡 30 秒，从发 TERM 到入口退出必须远小于这个数。
mkstub security   # ④ 删掉过它
touch "$tmp/hang"; rm -f "$tmp"/pid.* "$tmp"/exit.*
( scan_run REVIEWERS=inspector,security > "$tmp/rc8" ) &
bg=$!
for _ in $(seq 1 100); do [[ -s "$tmp/pid.inspector" && -s "$tmp/pid.security" ]] && break; sleep 0.1; done
read -r _ entry_pid < "$tmp/pid.inspector"
assert_eq "$(read -r _ p < "$tmp/pid.security"; echo "$p")" "$entry_pid" "⑧（准备）两位替身的父进程是同一个入口进程（\$! 就是评审员本身，垫片一路 exec）"
t0=$(date +%s); kill -TERM "$entry_pid"; wait "$bg"; t1=$(date +%s)
rm -f "$tmp/hang"
assert_eq "$(cat "$tmp/rc8")" "143" "⑧ 入口收到 TERM → 退出 143"
assert_eq "$([ $((t1 - t0)) -le 5 ] && echo fast)" "fast" "⑧ 不等扫描员睡完 30 秒（用了 $((t1 - t0)) 秒）"
assert_eq "$(cat "$tmp/exit.inspector" 2>/dev/null)/$(cat "$tmp/exit.security" 2>/dev/null)" "ran/ran" \
  "⑧ TERM 转给了每位扫描员，它们的 EXIT 陷阱都跑了（租约在那里释放）"
assert_contains "$(cat "$tmp/err")" "scan-entrypoint 收到 TERM" "⑧ 日志里写明是收到 TERM 停下的"
assert_eq "$(attr_true posted_inspector)/$(attr_true posted_security)" "false/false" "⑧ 被停下的扫描员不置 posted（交给兜底，F1）"

report
