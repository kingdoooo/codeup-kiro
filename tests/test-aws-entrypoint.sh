#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh

ENTRY=../aws/executor/entrypoint.sh
# 抽出来跑的几段（检出段、clone 那一行、租约段）都要用 retry_git_429（issue 03）：生产里它由 clone 之前那一行
# `source "$PKG/scripts/lib/git-retry.sh"` 加载，这里垫同一个文件。
RETRY_SRC="source \"$(cd .. && pwd)/scripts/lib/git-retry.sh\""
YAML=../pipeline/flow-pipeline.yaml

# 找 entrypoint 里第一处匹配的行号，**只看非注释行**。注释里正当地提到同一个词（比如解释
# 「引擎自己会 fetch」时写出 scripts/kiro-review.sh）会让「A 必须排在 B 之前」这类断言拿注释行当 B，
# 于是断言恒真——一条只会为了错的理由通过的守卫。本文件所有顺序断言都经这个函数取行号。
entry_code_line() {  # 正则 → 行号（没有匹配则空）
  LC_ALL=C grep -nE "$1" "$ENTRY" | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1
}

# ① I9 裁判：Flow run block 导出的每个变量，entrypoint 也必须导出
flow_vars=$(LC_ALL=C grep -oE 'export [A-Z_]+|: "\$\{[A-Z_]+:=' "$YAML" \
            | grep -oE '[A-Z_]{3,}' | sort -u)
entry_vars=$(LC_ALL=C grep -oE '^[[:space:]]*export [A-Z_]+' "$ENTRY" \
             | grep -oE '[A-Z_]{3,}' | sort -u)
missing=$(comm -23 <(printf '%s\n' "$flow_vars") <(printf '%s\n' "$entry_vars"))
assert_eq "$missing" "" "I9：Flow run block 导出的变量 entrypoint 必须全部导出"

# ② 档位固定为 pinned，且不新增取值
assert_contains "$(cat "$ENTRY")" 'KIRO_INSTALL_PROFILE=pinned' "档位固定为 pinned"
assert_not_contains "$(cat "$ENTRY")" 'KIRO_INSTALL_PROFILE=image' "不得新增 image 取值"

# ③ 镜像摘要门（N1）必须在调用评审脚本之前
gate_line=$(entry_code_line 'KIRO_IMAGE_DIGESTS')
call_line=$(entry_code_line 'kiro-review\.sh')
assert_eq "$([ -n "$gate_line" ] && [ "$gate_line" -lt "$call_line" ] && echo yes)" "yes" \
  "N1：镜像摘要门必须排在评审脚本之前"
# 元断言：上面取到的必须是**真正的调用行**而不是注释行。踩过一次：注释里正当地写了
# scripts/kiro-review.sh，call_line 于是取到那行注释（65）而不是真正的调用（134），③ 变成恒真——
# 一条只会为了错的理由通过的守卫。本文件所有顺序断言都经 entry_code_line 取行号，这条守着它。
assert_eq "$(LC_ALL=C sed -n "${call_line}p" "$ENTRY" | LC_ALL=C grep -cE '^[[:space:]]*#')" "0" \
  "③ 取到的行必须是真正的调用行，不能是注释行（否则顺序断言恒真）"

# ④ 解释器与关键命令用绝对路径（沿用 Flow run block 的同一条理由：PATH 不可信）
assert_contains "$(cat "$ENTRY")" '/bin/bash -p' "调评审脚本用 /bin/bash -p"

# ⑤ entrypoint 不得把密钥打进日志
assert_not_contains "$(cat "$ENTRY")" 'echo "$KIRO_API_KEY' "不得回显密钥"
assert_not_contains "$(cat "$ENTRY")" 'echo "$YUNXIAO_TOKEN' "不得回显密钥"

# ⑥ scripts/ 不得知道 AWS 细节（I9 推论）
for forbidden in dynamodb DynamoDB ECS_CONTAINER_METADATA secretsmanager; do
  hits=$(LC_ALL=C grep -rl "$forbidden" ../scripts/ 2>/dev/null || true)
  assert_eq "$hits" "" "I9：scripts/ 不得引用 $forbidden"
done

# ⑦ N1 摘要必须来自【容器级】端点的顶层 .ImageID，不是【任务级】/task 端点的 .Containers[0].ImageID
# （task 级端点返回本任务下全部容器、无自证身份、无顺序保证——加一个 sidecar 就可能读错容器）。
# 只看真正取值的那几行（curl/jq/self_digest=），绕开解释这件事本身的注释行，避免注释里出现
# 反例词汇（比如解释「为什么不能用 .Containers[0]」时提到它）把断言带偏。
# 只在 N1 那一段里找：租约那一段为了取本任务 ARN **正当地**读任务级 `/task` 端点（issue 02），全文 grep 的话
# 这条会为错的理由红。段落边界与 ⑫ 抽 N1 段用的是同一对标题行。
n1_block=$(awk '/^# ── N1 镜像摘要门/{f=1} /^# ── clone 业务库/{exit} f{print}' "$ENTRY")
assert_contains "$n1_block" 'exit 90' "⑦ 抽到了 N1 那一段"
digest_lines=$(printf '%s\n' "$n1_block" | LC_ALL=C grep -E 'curl -sf|jq -r|self_digest=')
assert_not_contains "$digest_lines" '/task"' "N1：容器级端点不得带 /task 后缀（那是任务级端点）"
assert_contains "$digest_lines" '.ImageID' "N1：必须读取顶层 .ImageID"
assert_not_contains "$digest_lines" 'Containers[0]' "N1：不得从 .Containers[0].ImageID 取值（任务级端点的产物）"
# ⑧ ECS 返回的 ImageID 带 sha256: 前缀，比对 KIRO_IMAGE_DIGESTS（约定存裸十六进制）之前必须剥掉
assert_contains "$digest_lines" '#sha256:' "N1：摘要口径必须剥离 ECS 返回值的 sha256: 前缀"

# ⑨ Step 5 收尾（任务 10 复审 Critical 1）：置位「已回写」标记必须以 rc=0 为条件，
#   不能不分退出码都置位——脚本在 MR 定位之前有三类路径会以非零退出却什么评论都
#   没写，无条件置位会让这些「没发过评论」的失败被标记本身拦下、兜底 Lambda 也不再补发。
#   租约那一段（㉒）也用 update-item、也有顶格的 `fi`，所以置位行与收尾的 `fi` 都从 rc 守卫**之后**找：
#   取全文第一处的话会取到租约的那一行，断言因为错的理由红（或者换个排列就因为错的理由绿）。
guard_line=$(LC_ALL=C grep -n '\[\[ "\$rc" -eq 0 \]\]' "$ENTRY" | head -1 | cut -d: -f1)
first_after() {  # 正则 起始行号 → 起始行之后第一处匹配的非注释行号
  LC_ALL=C grep -nE "$1" "$ENTRY" | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*#' \
    | awk -F: -v s="$2" '$1 > s {print $1; exit}'
}
mark_line=$(first_after 'update-item' "${guard_line:-0}")
close_line=$(first_after '^fi$' "${mark_line:-0}")
exit_line=$(LC_ALL=C grep -n 'exit "\$rc"' "$ENTRY" | head -1 | cut -d: -f1)
assert_eq "$([ -n "$guard_line" ] && [ -n "$mark_line" ] && [ -n "$close_line" ] && [ -n "$exit_line" ] \
  && [ "$guard_line" -lt "$mark_line" ] && [ "$mark_line" -lt "$close_line" ] && [ "$close_line" -lt "$exit_line" ] \
  && echo yes)" "yes" \
  "I10：update-item 置位标记必须在 rc=0 的 if 块内，容器最终仍以脚本原始 rc 退出"

# ⑩ I1 锁键单一来源：entrypoint 只用调度器传进来的 LOCK_KEY，绝不自己用 repo#MR#sha 重建
#   （评论命令的键多一段评论 id，重建出来的是另一条记录）；LOCK_KEY 只给 entrypoint 自己用，不导出
#   给评审脚本（I9 的裁判比较的是导出集合）。
assert_contains "$(cat "$ENTRY")" ': "${LOCK_KEY:?' "I1：LOCK_KEY 缺失必须硬失败"
code_lines=$(LC_ALL=C grep -vE '^[[:space:]]*#' "$ENTRY")
#   租约（㉒）让本文件第一次**合法地**拼了两个键：租约键 `lease#仓库#MR`，与「源分支最新提交」的抢锁键
#   `仓库#MR#<最新提交>`（查别人的记录，不是自己的）。所以这里不再是「一处都不许拼」，而是：
#   用自己的 HEAD_SHA 拼的键一个都不许有（那就是重建自己的 LOCK_KEY），拼键的只许是这两行。
assert_not_contains "$code_lines" '#${HEAD_SHA}' "I1：不得用自己的 HEAD_SHA 拼锁键"
assert_not_contains "$code_lines" '#$HEAD_SHA' "I1：不得用自己的 HEAD_SHA 拼锁键（无花括号写法）"
key_builds=$(LC_ALL=C grep -vE '^[[:space:]]*#' "$ENTRY" | LC_ALL=C grep -F '${CODEUP_REPO_ID}#' || true)
assert_eq "$key_builds" \
  "lease_key=\$(/usr/bin/jq -cn --arg k \"lease#\${CODEUP_REPO_ID}#\${MR_LOCAL_ID}\" '{pk: {S: \$k}}')
  tip_key=\"\${CODEUP_REPO_ID}#\${MR_LOCAL_ID}#\${tip}\"" \
  "I1：拼键的只有租约键与最新提交的抢锁键这两行"
assert_not_contains "$code_lines" 'export LOCK_KEY' "I1：LOCK_KEY 不导出给评审脚本"

# ⑪ 置位请求的真实形状（不是只看源码里有没有某个词）：把 rc=0 那段原样抽出来，只把
#   /usr/local/bin/aws 换成记录 argv 的替身，断言发出去的 --key 与 --condition-expression。
#   条件 attribute_exists(pk) 缺了，锁记录不在时 update-item 会新建一条没有 expires_at 的记录，永不过期（N4）。
if [[ -x /usr/bin/jq ]]; then
  mtmp=$(mktemp -d)
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\n' "$mtmp" > "$mtmp/aws"; chmod +x "$mtmp/aws"
  mark_block=$(awk '/^if \[\[ "\$rc" -eq 0 \]\]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$ENTRY" \
               | sed "s#/usr/local/bin/aws#$mtmp/aws#")
  assert_contains "$mark_block" "$mtmp/aws dynamodb update-item" "⑪ 抽到了置位那一段"
  after() { awk -v f="$1" 'p{print; exit} $0==f{p=1}' "$mtmp/argv"; }
  for key in 'r1#7#abc123#1244' 'r1#7#ab"c'; do
    rm -f "$mtmp/argv"
    LOCK_KEY="$key" AWS_REGION=us-west-2 LOCK_TABLE=t \
      /bin/bash -c "set -euo pipefail; rc=0; $mark_block" </dev/null
    want=$(/usr/bin/jq -cn --arg k "$key" '{pk: {S: $k}}')
    assert_eq "$(after --key)" "$want" "⑪ 置位用的键就是 LOCK_KEY 原样（${key}）"
    assert_eq "$(after --condition-expression)" "attribute_exists(pk)" \
      "⑪ 置位带 attribute_exists(pk) 条件，绝不新建无 TTL 的锁记录"
  done
  rm -rf "$mtmp"
else
  echo "SKIP: 无 /usr/bin/jq，跳过 ⑪ 置位请求形状断言" >&2
fi

# ⑫ I3：N1 门不得在「读不到摘要」时放行。静态：元数据端点有 :? 守卫、非空判断排在名单比对之前；
#   行为：把 N1 那一段原样抽出来跑（元数据端点指向本地 file://），覆盖复审在 shell 里复现的放行组合。
nonempty_line=$(LC_ALL=C grep -n '\[\[ -n "\$self_digest" \]\]' "$ENTRY" | head -1 | cut -d: -f1)
member_line=$(LC_ALL=C grep -n 'digest_ok=1' "$ENTRY" | head -1 | cut -d: -f1)
guard_meta=$(LC_ALL=C grep -n ': "${ECS_CONTAINER_METADATA_URI_V4:?' "$ENTRY" | head -1 | cut -d: -f1)
curl_line=$(LC_ALL=C grep -n 'curl -sf' "$ENTRY" | head -1 | cut -d: -f1)
assert_eq "$([ -n "$nonempty_line" ] && [ -n "$member_line" ] && [ "$nonempty_line" -lt "$member_line" ] && echo yes)" \
  "yes" "I3：空摘要的显式拒绝必须排在名单比对之前"
assert_eq "$([ -n "$guard_meta" ] && [ -n "$curl_line" ] && [ "$guard_meta" -lt "$curl_line" ] && echo yes)" \
  "yes" "I3：ECS_CONTAINER_METADATA_URI_V4 必须有 :? 守卫且在读取之前"
if [[ -x /usr/bin/jq && -x /usr/bin/curl ]]; then
  gtmp=$(mktemp -d)
  gate_block=$(awk '/^# ── N1 镜像摘要门/{f=1} /^# ── clone 业务库/{exit} f{print}' "$ENTRY")
  assert_contains "$gate_block" 'exit 90' "⑫ 抽到了 N1 那一段"
  A=$(printf 'a%.0s' {1..64}); B=$(printf 'b%.0s' {1..64}); C=$(printf 'c%.0s' {1..64})
  run_gate() {  # 元数据文件内容（空 = 不建文件，模拟端点读取失败） 名单 → 打印 "rc 输出"
    rm -f "$gtmp/meta.json"; [[ -z "$1" ]] || printf '%s' "$1" > "$gtmp/meta.json"
    local out rc=0
    out=$(KIRO_IMAGE_DIGESTS="$2" ECS_CONTAINER_METADATA_URI_V4="file://$gtmp/meta.json" \
          /bin/bash -c "set -euo pipefail; $gate_block
echo GATE_PASSED" </dev/null 2>&1) || rc=$?
    printf '%s %s' "$rc" "$out"
  }
  assert_eq "$(run_gate "{\"ImageID\":\"sha256:$B\"}" "$A $B")" "0 GATE_PASSED" "⑫ 名单内的摘要放行"
  assert_contains "$(run_gate "{\"ImageID\":\"sha256:$C\"}" "$A $B")" "90 镜像摘要不在已探测名单内" "⑫ 名单外的摘要拒绝"
  for lst in "$A " " $A" "$A  $B"; do   # 复审复现的三种放行组合：摘要为空 + 名单里有多余空格
    assert_contains "$(run_gate '{}' "$lst")" "90 读不到本容器镜像摘要" "⑫ 读不到摘要时拒绝（名单 [${lst}]）"
  done
  assert_contains "$(run_gate '' "$A ")" "90 读不到本容器镜像摘要" "⑫ 元数据端点读取失败时拒绝"
  assert_contains "$(run_gate '<html>502</html>' "$A ")" "90 读不到本容器镜像摘要" "⑫ 元数据不是 JSON 时拒绝"
  assert_eq "$(run_gate "{\"ImageID\":\"sha256:$B\"}" $'  '"$A"$'\n\t'"$B"$'  ')" "0 GATE_PASSED" \
    "⑫ 名单里混用空格/制表符/换行不改变含义"
  assert_contains "$(run_gate "{\"ImageID\":\"sha256:$A\"}" "   ")" "90 镜像摘要不在已探测名单内" "⑫ 全空白名单拒绝"
  out=$(KIRO_IMAGE_DIGESTS="$A" /bin/bash -c "set -euo pipefail; $gate_block
echo GATE_PASSED" </dev/null 2>&1) && rc=0 || rc=$?
  assert_nonzero "$rc" "⑫ 缺 ECS_CONTAINER_METADATA_URI_V4 时硬失败"
  assert_not_contains "$out" "GATE_PASSED" "⑫ 缺元数据端点变量时不放行"
  rm -rf "$gtmp"
else
  echo "SKIP: 无 /usr/bin/jq 或 /usr/bin/curl，跳过 ⑫ N1 门行为断言" >&2
fi

# ⑬ I5：MR_TARGET_BRANCH 的 `:=` 缺省必须排在任何使用之前（set -u 下 `|| true` 救不了未绑定变量）
default_line=$(entry_code_line ': "\$\{MR_TARGET_BRANCH:=\}"')
first_use=$(LC_ALL=C grep -nE '^[^#]*\$\{?MR_TARGET_BRANCH' "$ENTRY" | grep -v ':=' | head -1 | cut -d: -f1)
assert_eq "$([ -n "$default_line" ] && [ -n "$first_use" ] && [ "$default_line" -lt "$first_use" ] && echo yes)" \
  "yes" "I5：MR_TARGET_BRANCH 的缺省必须在第一次使用之前"

# ⑭ I-2（Task 5 复审）：clone 地址来自 webhook 报文，而 webhook 鉴权只是一个共享密钥——
#   拿到它就能把地址改成任意主机，凭证 helper 随后会把云效组织令牌交给那台主机（弱密钥升级成
#   组织令牌）。两道防线都要守：主机逐字比对必须排在 clone 之前，且 helper 必须按 URL 限定。
host_line=$(entry_code_line '拒绝 clone')
# 锚点只认「这是 clone 那一行」，不连带 `--no-tags`：连带的话删掉 `--no-tags` 会在这里以「主机检查必须
# 排在 clone 之前」这种不相干的理由红（复审 s6），⑲ 的标签变体才是守 `--no-tags` 的那一条。
clone_line=$(entry_code_line '^retry_git_429 /usr/bin/git clone ')
assert_eq "$([ -n "$host_line" ] && [ -n "$clone_line" ] && [ "$host_line" -lt "$clone_line" ] && echo yes)" \
  "yes" "I-2：主机检查必须存在且排在 clone 之前"
# 凭证经**环境变量**下发给所有子进程（Task 14 验收阻塞：评审引擎自己也要 git fetch，`-c` 只作用于
# 执行器自己那一次调用，引擎那次是无凭证的）；key 仍必须按 URL 限定。
export_line=$(entry_code_line '^export GIT_CONFIG_VALUE_0=')
assert_eq "$([ -n "$export_line" ] && [ -n "$clone_line" ] && [ "$export_line" -lt "$clone_line" ] && echo yes)" \
  "yes" "I-2：凭证 helper 的导出必须存在且排在 clone 之前"
assert_contains "$code_lines" "export GIT_CONFIG_COUNT=1" "I-2：必须声明 GIT_CONFIG_COUNT"
assert_contains "$code_lines" \
  "export GIT_CONFIG_KEY_0='credential.https://codeup.aliyun.com.helper'" \
  "I-2：凭证 helper 的 key 必须按 URL 限定到 codeup.aliyun.com"
assert_contains "$code_lines" 'export GIT_CONFIG_VALUE_0="$cred_helper"' \
  "I-2：value 取自 cred_helper 变量，不是就地写一份"
assert_not_contains "$code_lines" 'credential.helper' \
  "I-2：不得留下未限定主机的全局 credential.helper（任何主机问凭证它都答）"
assert_not_contains "$code_lines" '-c credential' \
  "I-2：凭证只有环境变量这一处来源，不得再留 -c（两种写法并存迟早分叉）"
# 令牌绝不以字面量出现：`password=` 后面只允许是 `$YUNXIAO_TOKEN` 这种引用。
assert_eq "$(LC_ALL=C grep -nE 'password=[^$]' "$ENTRY" || true)" "" \
  "I-2：password= 后面只能是 \$YUNXIAO_TOKEN 引用，不得写字面量"
# 单引号是承重的：换成双引号，密文会在这一行就被 bash 展开进导出的 GIT_CONFIG_VALUE_0。
assert_contains "$code_lines" \
  "cred_helper='!f() { echo \"username=oauth2\"; echo \"password=\$YUNXIAO_TOKEN\"; }; f'" \
  "I-2：cred_helper 必须是单引号，令牌不得在赋值时展开"

# ⑮ 行为：把主机检查那一段原样抽出来跑，覆盖 userinfo、同后缀域名、缺协议与令牌写进 URL 四类
host_block=$(awk '/^repo_url=/{f=1} f{print} f&&/拒绝 clone/{exit}' "$ENTRY")
assert_contains "$host_block" 'exit 91' "⑮ 抽到了主机检查那一段"
run_host() {  # BUSINESS_REPO_URL → "rc 输出"
  local out rc=0
  out=$(BUSINESS_REPO_URL="$1" /bin/bash -c "set -euo pipefail; $host_block
echo HOST_OK" </dev/null 2>&1) || rc=$?
  printf '%s %s' "$rc" "$out"
}
assert_eq "$(run_host 'https://codeup.aliyun.com/6a5eeddf/demo-app.git')" "0 HOST_OK" \
  "⑮ 本方主机放行"
assert_eq "$(run_host 'codeup.aliyun.com/6a5eeddf/demo-app.git')" "0 HOST_OK" \
  "⑮ 缺协议时补 https 后仍是本方主机，放行"
for bad in 'https://evil.example/x.git' \
           'https://codeup.aliyun.com.evil.example/x.git' \
           'https://user@evil.example/x.git' \
           'https://codeup.aliyun.com@evil.example/x.git' \
           'evil.example/x.git' \
           'https://oauth2:s3cret-token@codeup.aliyun.com/o/x.git'; do
  assert_contains "$(run_host "$bad")" "91 业务库地址的主机不是" "⑮ 非本方主机拒绝（${bad}）"
done
# 拒绝消息里绝不回显地址：BUSINESS_REPO_URL 外部可控，写成 `https://oauth2:<令牌>@…` 时
# 回显就等于把令牌打进日志（与 ⑤ 同一条理由）。
assert_not_contains "$(run_host 'https://oauth2:s3cret-token@codeup.aliyun.com/o/x.git')" \
  's3cret-token' "⑮ 拒绝消息不得回显 URL 里的令牌"
assert_not_contains "$(run_host 'https://evil.example/x.git')" 'evil.example' \
  "⑮ 拒绝消息不得回显攻击者可控的地址"

# ⑯ I-2 / Task 14 行为断言（真 git，不是只看源码里有没有某个字符串）：把凭证那一段原样抽出来，
#   用 `git credential fill` 问三个主机。本方主机必须拿到 oauth2 + 环境里的令牌；另外两个主机
#   （完全无关的域名、以及带本方域名前缀的域名）必须什么都拿不到。
#   `GIT_CONFIG_GLOBAL/SYSTEM=/dev/null` 加 `GIT_CONFIG_NOSYSTEM=1`：把开发机自己的配置（osxkeychain 之类）
#   隔离掉，否则负向断言可能被本机 helper 满足、变成假绿；执行器镜像里本来就没有这些配置。
#   只写 GIT_CONFIG_SYSTEM 不够：macOS 的 /usr/bin/git 另读一份内置配置
#   （/Library/Developer/CommandLineTools/usr/share/git-core/gitconfig，开着 osxkeychain），只有 NOSYSTEM
#   关得掉（2026-09-30 实测：钥匙串里存着 codeup.aliyun.com 的凭证时，本方主机拿到的是它、不是环境里的
#   令牌，失败信息还把它原样打了出来）。所以 fill 的输出里凡不是测试令牌的 password= 一律抹掉再断言。
if [[ -x /usr/bin/git ]]; then
  cred_block=$(awk '/^cred_helper=/{f=1} f{print} f&&/^export GIT_CONFIG_VALUE_0=/{exit}' "$ENTRY")
  assert_contains "$cred_block" 'GIT_CONFIG_VALUE_0' "⑯ 抽到了凭证那一段"
  FAKE_TOKEN='t0k3n-for-test-only'
  NOPASS=$(command -v false)
  fill() {  # 主机 → "rc 输出"
    local out rc=0
    out=$(printf 'protocol=https\nhost=%s\n\n' "$1" \
      | YUNXIAO_TOKEN="$FAKE_TOKEN" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$NOPASS" \
        /bin/bash -c "set -euo pipefail; $cred_block
exec /usr/bin/git credential fill" 2>&1) || rc=$?
    out=$(printf '%s\n' "$out" \
      | LC_ALL=C sed -E "/^password=${FAKE_TOKEN}\$/!s/^password=.*/password=<redacted-non-test>/")
    printf '%s %s' "$rc" "$out"
  }
  ours=$(fill codeup.aliyun.com)
  assert_contains "$ours" "username=oauth2" "⑯ 本方主机拿到 oauth2 用户名"
  assert_contains "$ours" "password=$FAKE_TOKEN" "⑯ 本方主机拿到环境里的令牌（helper 真的被调用）"
  for host in evil.example codeup.aliyun.com.evil.example; do
    got=$(fill "$host")
    assert_not_contains "$got" "password=" "⑯ 非本方主机拿不到任何密码（${host}）"
    assert_not_contains "$got" "$FAKE_TOKEN" "⑯ 非本方主机拿不到令牌（${host}）"
  done
  # 令牌只能留在 YUNXIAO_TOKEN 里：cred_helper 那行改成双引号就会把密文展开进导出的
  # GIT_CONFIG_VALUE_0，等于摊给容器里每一个进程（/proc/<pid>/environ）。
  env_dump=$(YUNXIAO_TOKEN="$FAKE_TOKEN" /bin/bash -c "set -euo pipefail; $cred_block
env" | LC_ALL=C grep -v '^YUNXIAO_TOKEN=')
  assert_not_contains "$env_dump" "$FAKE_TOKEN" "⑯ 令牌不得被展开进任何导出的环境变量"
  assert_contains "$env_dump" 'GIT_CONFIG_VALUE_0=' "⑯ 正向对照：helper 确实导出给了子进程"
  assert_contains "$env_dump" 'GIT_CONFIG_COUNT=1' "⑯ 正向对照：GIT_CONFIG_COUNT 也导出了"
else
  echo "SKIP: 无 /usr/bin/git，跳过 ⑯ 凭证行为断言" >&2
fi

# issue 05 E1：执行器任务定义里的 TZ=CST-8（stacks/executor_stack.py）不靠时区数据库也得生效（基础镜像目前带
#   tzdata，但 CST-8 这种 POSIX 写法本来就不依赖它；本机 macOS 与容器里各跑一次）。
#   这条测的是平台（libc 的 POSIX TZ 解析），所以要在构建机的 debian:stable-slim 容器里也跑一次才算容器证据。
assert_eq "$(TZ=CST-8 date +%z)" "+0800" "E1 TZ=CST-8 不靠时区数据库也是 +0800"

# ⑰ Task 14 第二个验收阻塞：clone 给的是仓库**默认分支**，必须自己检出 MR 的那个提交。
#   真实运行实测过（Codeup-Demo MR !4：汇总标记写成 master 的头 f29435f，MR 的头是 7baa0cd）。
#   行为断言用**真的本地裸库**：两个分支、MR 头在非默认分支上，跑抽出来的检出段，断言 HEAD 落在
#   MR 头而不是默认分支头。主机检查让「用本地路径 clone」没法直接跑，所以按控制器裁决只单独跑检出段
#   （clone 这一步由本测试自己做，等价于执行器 clone 完的状态）。
if [[ -x /usr/bin/git ]]; then
  # 检出段之后紧跟租约那一段（㉒ 单独测），抽到租约段的标题为止。检出段失败时要打 git 报错的尾巴，
  # 那个助手（GIT_ERR + git_err_tail）定义在 clone 那一段，原样抽出来垫在前面（㉓ 单独测它）。
  err_block=$(awk '/^GIT_ERR=/{f=1} f{print} f&&/^}$/{exit}' "$ENTRY")
  assert_contains "$err_block" 'git_err_tail()' "⑰ 抽到了 git 报错尾巴的助手"
  # 检出段也读 MR_TARGET_BRANCH（非空时查形状；issue 03 起不再取目标分支），它的 `:=` 缺省在文件顶部，一并垫上。
  tb_default=$(LC_ALL=C grep -E '^: "\$\{MR_TARGET_BRANCH:=\}"$' "$ENTRY")
  assert_eq "$tb_default" ': "${MR_TARGET_BRANCH:=}"' "⑰ 抽到了 MR_TARGET_BRANCH 的缺省"
  ck_block="$tb_default
$err_block
$RETRY_SRC
$(awk '/^# ── 检出 MR 的那个提交/{f=1} /^# ── 按 MR 的租约/{exit} f{print}' "$ENTRY")"
  # 只验证「抽到了」，**不钉具体写法**：钉写法的话，任何改动都先在这里红，后面真正的行为断言
  # （⑲ 的引用遮蔽复现）就跑不到了——变异测试会得出「守卫有用」的错误结论。
  assert_contains "$ck_block" 'checkout -q' "⑰ 抽到了检出那一段"
  ctmp=$(mktemp -d)
  # 环境隔离：不读开发机的全局/系统配置（模板、hooks、init.defaultBranch 都可能改变结果）
  gitq() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
             GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
             GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
             /usr/bin/git "$@"; }
  gitq init -q "$ctmp/work"
  gitq -C "$ctmp/work" commit -q --allow-empty -m A
  def_branch=$(gitq -C "$ctmp/work" rev-parse --abbrev-ref HEAD)
  gitq -C "$ctmp/work" checkout -q -b mr-src
  gitq -C "$ctmp/work" commit -q --allow-empty -m "MR head"
  mr_head=$(gitq -C "$ctmp/work" rev-parse HEAD)
  gitq -C "$ctmp/work" checkout -q "$def_branch"
  gitq -C "$ctmp/work" commit -q --allow-empty -m "默认分支又前进了一步"
  def_head=$(gitq -C "$ctmp/work" rev-parse HEAD)
  gitq clone -q --bare "$ctmp/work" "$ctmp/bare"
  assert_eq "$([ "$mr_head" != "$def_head" ] && echo yes)" "yes" "⑰ 前提：MR 头与默认分支头不同"

  run_checkout() {  # HEAD_SHA 分支名 → "rc 输出|HEAD"
    local out rc=0 head
    rm -rf "$ctmp/business"
    gitq clone -q "$ctmp/bare" "$ctmp/business"
    out=$(WORKROOT="$ctmp" HEAD_SHA="$1" CI_COMMIT_REF_NAME="$2" \
          GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
          /bin/bash -c "set -euo pipefail; $ck_block" 2>&1) || rc=$?
    head=$(gitq -C "$ctmp/business" rev-parse HEAD)
    printf '%s %s|%s' "$rc" "$out" "$head"
  }

  # 正向对照：clone 出来的 HEAD 本来就是默认分支的头，检出之后必须变成 MR 头
  assert_eq "$(gitq clone -q "$ctmp/bare" "$ctmp/probe" && gitq -C "$ctmp/probe" rev-parse HEAD)" \
    "$def_head" "⑰ 前提：clone 出来的 HEAD 是默认分支的头（这就是那个缺陷）"
  got=$(run_checkout "$mr_head" mr-src)
  assert_eq "${got##*|}" "$mr_head" "⑰ 检出之后 HEAD 必须是 MR 的提交"
  assert_eq "${got%% *}" "0" "⑰ 正常输入下检出段退出码 0"

  # ⑰ issue 05 G4（s6 m-C）：「检出成功但 HEAD 与 HEAD_SHA 不一致」那道守卫以前没有任何行为用例走得到——
  #   真实的 `--detach <40hex>` 下 HEAD 按构造恒等于 HEAD_SHA。用一个 post-checkout 钩子在检出之后把 HEAD
  #   挪回默认分支的头，**原样**跑生产的检出段（一个字不改）。钩子留下的标记文件证明确实走到了这一情形：
  #   将来 entrypoint 若为安全起见关掉钩子（core.hooksPath=/dev/null），这里红在「钩子没跑」，不会误报守卫失效。
  rm -rf "$ctmp/business"
  gitq clone -q "$ctmp/bare" "$ctmp/business"
  printf '#!/bin/sh\ntouch "%s/hook-ran"\nexec /usr/bin/git update-ref --no-deref HEAD %s\n' "$ctmp" "$def_head" \
    > "$ctmp/business/.git/hooks/post-checkout"
  chmod +x "$ctmp/business/.git/hooks/post-checkout"
  g4_rc=0
  g4_out=$(WORKROOT="$ctmp" HEAD_SHA="$mr_head" CI_COMMIT_REF_NAME=mr-src \
           GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
           /bin/bash -c "set -euo pipefail; $ck_block" 2>&1) || g4_rc=$?
  assert_eq "$([ -e "$ctmp/hook-ran" ] && echo yes)" "yes" "⑰ G4 前提：钩子确实在检出之后跑了"
  assert_eq "$g4_rc" "92" "⑰ G4 检出成功但 HEAD 被挪走 → 退出码 92"
  assert_contains "$g4_out" "检出之后 HEAD 与 HEAD_SHA 不一致" "⑰ G4 报的是 HEAD 不一致那一条"
  assert_not_contains "$g4_out" "检出 MR 的提交失败" "⑰ G4 不是「检出失败」那一条 92"
# ⑲ 复审 I-1 的端到端复现：源分支名叫 `origin/<默认分支>`（合法分支名，MR 作者随手就能起）。
#   建本地分支时 `refs/heads/origin/<默认分支>` 会遮蔽 `refs/remotes/origin/<默认分支>`，引擎第 4 步的
#   `git merge-base "origin/${TARGET_BRANCH}" HEAD` 退化成 HEAD → diff 为空 → 引擎打「diff 为空，跳过评审」
#   并 exit 0 → 执行器置「已回写」标记 → 兜底 Lambda 看 exitCode 0 也不吭声 = 一条评论都没有的静默漏评。
#   所以这条不只断言 HEAD 对，还要**把引擎那两步原样跑一遍**（fetch 目标分支 → merge-base → diff）。
  stmp=$(mktemp -d)
  gitq2() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
              GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
              GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
              /usr/bin/git "$@"; }
  gitq2 init -q "$stmp/work"
  printf 'base\n' > "$stmp/work/f.txt"
  gitq2 -C "$stmp/work" add f.txt
  gitq2 -C "$stmp/work" commit -q -m A
  sdef=$(gitq2 -C "$stmp/work" rev-parse --abbrev-ref HEAD)
  # 源分支名刻意与「远端默认分支的短名」同形
  gitq2 -C "$stmp/work" checkout -q -b "origin/${sdef}"
  printf 'changed\n' > "$stmp/work/f.txt"; printf 'new\n' > "$stmp/work/g.txt"
  gitq2 -C "$stmp/work" add -A
  gitq2 -C "$stmp/work" commit -q -m "MR head"
  s_mr_head=$(gitq2 -C "$stmp/work" rev-parse HEAD)
  gitq2 -C "$stmp/work" checkout -q "$sdef"
  gitq2 clone -q --bare "$stmp/work" "$stmp/bare"
  gitq2 clone -q "$stmp/bare" "$stmp/business"
  # 执行器的检出段
  out=$(WORKROOT="$stmp" HEAD_SHA="$s_mr_head" CI_COMMIT_REF_NAME="origin/${sdef}" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        /bin/bash -c "set -euo pipefail; $ck_block" 2>&1) || true
  assert_eq "$(gitq2 -C "$stmp/business" rev-parse HEAD)" "$s_mr_head" \
    "⑲ 源分支名叫 origin/<默认分支> 时也要检出 MR 的提交"
  # 引擎第 4 步原样：先 fetch 目标分支到 refs/remotes/origin/<目标分支>，再算 merge-base 与 diff
  gitq2 -C "$stmp/business" fetch -q origin "+refs/heads/${sdef}:refs/remotes/origin/${sdef}"
  s_base=$(gitq2 -C "$stmp/business" merge-base "origin/${sdef}" HEAD)
  assert_eq "$([ "$s_base" != "$s_mr_head" ] && echo yes)" "yes" \
    "⑲ merge-base 不得退化成 HEAD（退化 = diff 为空 = 静默漏评）"
  assert_eq "$(gitq2 -C "$stmp/business" diff --numstat "$s_base" HEAD | wc -l | tr -d ' ')" "2" \
    "⑲ 引擎算出来的 diff 必须非空（本例改了 1 个文件、加了 1 个文件）"

  # ⑲ 的标签变体：`clone --no-tags` 是承重的（全分支复审 s6）。服务端有一个叫 `origin/<默认分支>` 的
  # **标签**、指着 MR 头（有推送权限的人随手就能打）：clone 带上它的话，`refs/tags/origin/<默认分支>`
  # 会遮蔽 `refs/remotes/origin/<默认分支>`（git 解析短名字时 refs/tags 排在 refs/remotes 之前），
  # 引擎第 4 步的 merge-base 退化成 HEAD——diff 为空、静默漏评。clone 的参数**取自 entrypoint 那一行**，
  # 不在这里另写一份：有人删掉 `--no-tags`，这里先红。
  # 先跑行为、后钉写法（与 ⑰ 同一条理由）：先钉写法的话删掉 `--no-tags` 在这里就红，下面真正的
  # 遮蔽复现跑不到，变异测试得出「守卫有用」的错误结论。
  clone_flags=$(LC_ALL=C grep -oE '^retry_git_429 /usr/bin/git clone( --[a-z-]+)*' "$ENTRY" \
                | sed -E 's#^retry_git_429 /usr/bin/git clone ?##')
  rm -rf "$stmp/business"
  gitq2 -C "$stmp/work" tag "origin/${sdef}" "$s_mr_head"
  gitq2 -C "$stmp/work" push -q "$stmp/bare" "refs/tags/origin/${sdef}"
  # shellcheck disable=SC2086 # clone_flags 是若干个 `--xxx`，需要按空白拆开
  gitq2 clone -q $clone_flags "$stmp/bare" "$stmp/business"
  out=$(WORKROOT="$stmp" HEAD_SHA="$s_mr_head" CI_COMMIT_REF_NAME="origin/${sdef}" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        /bin/bash -c "set -euo pipefail; $ck_block" 2>&1) || true
  gitq2 -C "$stmp/business" fetch -q origin "+refs/heads/${sdef}:refs/remotes/origin/${sdef}"
  s_base=$(gitq2 -C "$stmp/business" merge-base "origin/${sdef}" HEAD 2>/dev/null)
  assert_eq "$([ "$s_base" != "$s_mr_head" ] && echo yes)" "yes" \
    "⑲ 标签变体：merge-base 不得被标签带偏成 HEAD"
  assert_eq "$(gitq2 -C "$stmp/business" diff --numstat "$s_base" HEAD | wc -l | tr -d ' ')" "2" \
    "⑲ 标签变体：diff 仍非空"
  assert_eq "$(gitq2 -C "$stmp/business" tag -l)" "" "⑲ 标签变体：clone 没有带下任何标签"
  assert_eq "$(gitq2 -C "$stmp/business" config remote.origin.tagOpt)" "--no-tags" \
    "⑲ 标签变体：clone 写下了 tagOpt，引擎之后的 fetch 也不会顺带取标签"
  assert_contains " $clone_flags " " --no-tags " "⑲ 标签变体：entrypoint 的 clone 带 --no-tags"
  rm -rf "$stmp"

  # 必须是**分离头指针**：建本地分支 `refs/heads/<源分支名>` 会在源分支叫 `origin/<目标分支>` 时
  # 遮蔽 `refs/remotes/origin/<目标分支>`，引擎的 merge-base 退化成 HEAD → diff 为空 → 静默漏评
  # （复审 I-1，下面 ⑲ 是那个场景的端到端复现）。
  assert_eq "$(gitq -C "$ctmp/business" rev-parse --abbrev-ref HEAD)" "HEAD" \
    "⑰ 检出后必须是分离头指针，不建本地分支"
  assert_eq "$(gitq -C "$ctmp/business" for-each-ref --format='%(refname)' refs/heads/mr-src)" "" \
    "⑰ 不得建出 refs/heads/<源分支名>"

  # 负向：HEAD_SHA 形状不对（短 sha、大写、非十六进制、空）一律 fail closed，且不得动 HEAD
  for bad in "${mr_head:0:7}" "$(printf '%s' "$mr_head" | LC_ALL=C tr 'a-f' 'A-F')" \
             "zzzz567890123456789012345678901234567890" "${mr_head} " "${mr_head}x"; do
    got=$(run_checkout "$bad" mr-src)
    assert_contains "$got" "92 HEAD_SHA 不是 40 位小写十六进制" "⑰ HEAD_SHA 形状不对时拒绝（${bad:0:12}）"
    assert_eq "${got##*|}" "$def_head" "⑰ 拒绝时不得动 HEAD（${bad:0:12}）"
  done
  # HEAD_SHA 是空串：落到形状那条（空串也不是 40 位十六进制）。
  # 「变量根本没传」是另一件事，由文件顶部那条守卫负责——见下面 ⑳ 的行为断言。
  got=$(run_checkout "" mr-src)
  assert_contains "$got" "92 HEAD_SHA 不是 40 位小写十六进制" "⑰ HEAD_SHA 为空串时拒绝"
  assert_eq "${got##*|}" "$def_head" "⑰ HEAD_SHA 为空串时不得动 HEAD"
  # 负向：分支名以 - 开头 / 含空白 / 为空
  for bad in "-upload-pack=x" "mr src" "" "$(printf 'mr\tsrc')"; do
    got=$(run_checkout "$mr_head" "$bad")
    assert_contains "$got" "92 CI_COMMIT_REF_NAME 为空、以 - 开头或含空白/控制字符" \
      "⑰ 分支名形状不对时拒绝（${bad})"
    assert_eq "${got##*|}" "$def_head" "⑰ 拒绝时不得动 HEAD（${bad}）"
  done
  # 负向：形状合法但提交在库里不存在（源分支被强推改写）
  got=$(run_checkout "0000000000000000000000000000000000000000" mr-src)
  assert_contains "$got" "92 检出 MR 的提交失败" "⑰ 提交不存在时 fail closed"
  # 拒绝消息里不得回显不受信取值（分支名由 MR 作者控制）
  got=$(run_checkout "$mr_head" "-upload-pack=touch /tmp/pwned")
  assert_not_contains "$got" "upload-pack" "⑰ 拒绝消息不得回显分支名"

  # 正向覆盖「补取源分支」那一步（复审 M-2）：clone 之后源分支又被推了一次，HEAD_SHA 不在本地，
  # 必须靠那次 `fetch +refs/heads/<源分支>:refs/remotes/origin/<源分支>` 才拿得到。
  # 之前只覆盖了「补取也拿不到 → 92」，refspec 写错一个字母所有用例照样绿（全量 clone 里本来就有）。
  rm -rf "$ctmp/business"
  gitq clone -q "$ctmp/bare" "$ctmp/business"
  gitq -C "$ctmp/work" checkout -q mr-src
  gitq -C "$ctmp/work" commit -q --allow-empty -m "clone 之后的新推送"
  new_head=$(gitq -C "$ctmp/work" rev-parse HEAD)
  gitq -C "$ctmp/work" push -q "$ctmp/bare" mr-src
  assert_eq "$(gitq -C "$ctmp/business" rev-parse --verify --quiet "${new_head}^{commit}" \
              || echo MISSING)" "MISSING" "⑰ 前提：新提交在已有的克隆里确实不存在"
  fetch_rc=0
  WORKROOT="$ctmp" HEAD_SHA="$new_head" CI_COMMIT_REF_NAME=mr-src \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    /bin/bash -c "set -euo pipefail; $ck_block" >/dev/null 2>&1 || fetch_rc=$?
  assert_eq "$fetch_rc" "0" "⑰ 补取源分支之后检出必须成功"
  assert_eq "$(gitq -C "$ctmp/business" rev-parse HEAD)" "$new_head" \
    "⑰ 补取源分支之后 HEAD 必须是那个新提交"
  rm -rf "$ctmp"
else
  echo "SKIP: 无 /usr/bin/git，跳过 ⑰ 检出行为断言" >&2
fi

# ⑱ 检出段的静态形状：必须校验两个入参、必须核对检出后的 HEAD（⑰ 的负向用例覆盖不到「核对」这条，
#   因为 `--detach "$HEAD_SHA"` 本身就保证了一致——它守的是将来有人改动检出写法时不要静默评错提交）
assert_contains "$code_lines" 'rev-parse HEAD' "⑰/⑱：检出之后必须核对 HEAD"
assert_contains "$code_lines" '[[ "$head_now" == "$HEAD_SHA" ]]' "⑱ HEAD 与 HEAD_SHA 必须逐字比较"
# 必填守卫：刻意不用 `:?`（那样退出码是 1），与检出那一段同一个 92；且必须排在镜像摘要门与 clone
# 之前——缺了它整轮注定失败，没有理由先跑完一次全量 clone（复审 M-3）。
assert_contains "$code_lines" '[[ -n "${HEAD_SHA:-}" ]]' "⑱ HEAD_SHA 缺失必须硬失败"
assert_not_contains "$code_lines" ': "${HEAD_SHA:?' "⑱ HEAD_SHA 的守卫不得用 :?（退出码会变成 1）"
need_line=$(entry_code_line '\[\[ -n "\$\{HEAD_SHA:-\}" \]\]')
assert_eq "$([ -n "$need_line" ] && [ -n "$gate_line" ] && [ "$need_line" -lt "$gate_line" ] && echo yes)" \
  "yes" "⑱ HEAD_SHA 必填守卫必须排在镜像摘要门（和 clone）之前，不做任何网络 I/O"
# 分离头指针，不建本地分支（复审 I-1：`-B` 会让 `origin/<目标分支>` 这种源分支名遮蔽远端引用）
assert_contains "$code_lines" 'checkout -q --detach "$HEAD_SHA"' "⑱ 必须用 --detach 检出"
# 检出失败有两种成因（提交真不在库里 / git 不接受这个 ref 名，补取源分支那一步因此失败）。
# 只写第一种的话，第二种会被归错因——运维照着「重新推送」试到死（复审 M-4）。
ck_msg=$(LC_ALL=C grep -F '检出 MR 的提交失败' "$ENTRY")
assert_contains "$ck_msg" "不在业务库里" "⑱ 检出失败消息要说「提交不在业务库里」"
assert_contains "$ck_msg" "分支名" "⑱ 检出失败消息也要覆盖「git 不接受这个分支名」这个成因"
assert_not_contains "$code_lines" 'checkout -q -B' "⑱ 不得建本地分支（refs/heads 会遮蔽 refs/remotes）"
ck_line=$(entry_code_line 'checkout -q --detach')
engine_line=$(entry_code_line 'kiro-review\.sh')
assert_eq "$([ -n "$ck_line" ] && [ -n "$clone_line" ] && [ -n "$engine_line" ] \
  && [ "$clone_line" -lt "$ck_line" ] && [ "$ck_line" -lt "$engine_line" ] && echo yes)" "yes" \
  "⑱ 检出必须排在 clone 之后、调用引擎之前"


# ⑳ 必填守卫的行为断言（复审 M-3）：HEAD_SHA 根本没传时，必须在**任何网络 I/O 之前**以 92 退出。
#   抽的是文件顶部那一段必填项，别的变量都给上、只把 HEAD_SHA 拿掉。
req_block=$(awk '/^: "\$\{CODEUP_REPO_ID:\?/{f=1} f{print} f&&/^: "\$\{MR_TARGET_BRANCH:=\}"/{exit}' "$ENTRY")
assert_contains "$req_block" 'HEAD_SHA' "⑳ 抽到了必填项那一段（含 HEAD_SHA 守卫）"
req_out=$(CODEUP_REPO_ID=1 MR_LOCAL_ID=2 CI_COMMIT_REF_NAME=b BUSINESS_REPO_URL=u LOCK_KEY=k \
          /bin/bash -c "set -euo pipefail; $req_block
echo REQ_OK" 2>&1); req_rc=$?
assert_eq "$req_rc" "92" "⑳ 缺 HEAD_SHA 必须以 92 退出（与检出那一段同一个码，运维按码查表）"
assert_contains "$req_out" "缺少 HEAD_SHA" "⑳ 报错点名 HEAD_SHA"
assert_not_contains "$req_out" "REQ_OK" "⑳ 缺 HEAD_SHA 时不得继续往下走"
# 正向对照：给上 HEAD_SHA 就能过（否则上面那条 92 可能只是「这段什么都拒」）
req_out=$(CODEUP_REPO_ID=1 MR_LOCAL_ID=2 CI_COMMIT_REF_NAME=b BUSINESS_REPO_URL=u LOCK_KEY=k \
          HEAD_SHA=0123456789abcdef0123456789abcdef01234567 \
          /bin/bash -c "set -euo pipefail; $req_block
echo REQ_OK" 2>&1)
assert_contains "$req_out" "REQ_OK" "⑳ 正向对照：必填项齐全时这一段放行"

# ㉓ git 失败时打 stderr 的尾巴（全分支复审 s1/s6：以前一律丢掉，退出码 91/92 查不下去），以及
#   MR_TARGET_BRANCH 的第二道形状检查 + 带前缀的 refspec（复审 O-5 / s4 M-A）。都用真 git。
if [[ -x /usr/bin/git ]]; then
  gtmp=$(mktemp -d)
  err_block=$(awk '/^GIT_ERR=/{f=1} f{print} f&&/^}$/{exit}' "$ENTRY")
  assert_contains "$err_block" 'git_err_tail()' "㉓ 抽到了 git 报错尾巴的助手"
  # 尾巴的形状：只留最后 5 行、逐行去控制字符、截到 200 字节、固定前缀、抹掉 URL 里的 userinfo
  {
    for i in 1 2 3; do echo "early line $i"; done
    printf 'fatal: unable to access '"'"'https://oauth2:s3cret-t0ken@codeup.aliyun.com/o/x.git/'"'"'\n'
    printf 'remote: forged\r\033[31m red\n'
    printf 'x%.0s' $(seq 1 300); echo
    echo "fatal: couldn't find remote ref refs/heads/功能/登录"
    echo "last line"
  } > "$gtmp/git-stderr.log"
  tail_out=$(WORKROOT="$gtmp" /bin/bash -c "set -euo pipefail; $err_block
git_err_tail" 2>&1)
  assert_not_contains "$tail_out" "early line 3" "㉓ 只打最后 5 行"
  assert_contains "$tail_out" "  git: fatal: unable to access 'https://<redacted>@codeup.aliyun.com/o/x.git/'" \
    "㉓ URL 里的 userinfo 被抹掉"
  assert_not_contains "$tail_out" "s3cret-t0ken" "㉓ 令牌形状的 userinfo 不进日志"
  assert_contains "$tail_out" "  git: remote: forged[31m red" "㉓ 控制字符（回车、ESC）被去掉"
  assert_eq "$(printf '%s' "$tail_out" | LC_ALL=C tr -d '\n\t' | LC_ALL=C grep -c "$(printf '[\001-\037\177]')" || true)" "0" \
    "㉓ 输出里一个控制字符都没有"
  long=$(printf '%s\n' "$tail_out" | LC_ALL=C grep '^  git: xxx')
  assert_eq "${#long}" "$((200 + 7))" "㉓ 每行截到 200 字节（加 7 字节前缀）"
  assert_contains "$tail_out" "  git: fatal: couldn't find remote ref refs/heads/功能/登录" "㉓ 非 ASCII 原样保留"
  assert_eq "$(printf '%s\n' "$tail_out" | LC_ALL=C grep -vc '^  git: ' || true)" "0" "㉓ 每一行都带固定前缀"
  : > "$gtmp/git-stderr.log"
  assert_eq "$(WORKROOT="$gtmp" /bin/bash -c "set -euo pipefail; $err_block
git_err_tail" 2>&1)" "" "㉓ 没有报错时什么都不打"

  # clone 失败（91）时真的带上 git 的报错：抽 clone 那一行原样跑，地址换成一个不存在的本地路径
  #（主机检查是另一段，⑮ 单独测）
  clone_block=$(awk '/^retry_git_429 \/usr\/bin\/git clone /{f=1} f{print} f&&/exit 91; }$/{exit}' "$ENTRY")
  assert_contains "$clone_block" 'exit 91' "㉓ 抽到了 clone 那一行"
  out=$(WORKROOT="$gtmp" repo_url="$gtmp/no-such-repo" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        /bin/bash -c "set -euo pipefail; $err_block
$RETRY_SRC
$clone_block" 2>&1) && rc=0 || rc=$?
  assert_eq "$rc" "91" "㉓ clone 失败退出 91"
  assert_contains "$out" "clone 业务库失败（凭证、网络或仓库权限）" "㉓ 固定消息还在"
  assert_contains "$out" "  git: fatal:" "㉓ clone 失败时日志里有 git 自己的报错"

  # MR_TARGET_BRANCH：非空时查形状（与 CI_COMMIT_REF_NAME 同一套），用带前缀的 refspec 取
  tgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t \
             GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
             /usr/bin/git "$@"; }
  tgit init -q "$gtmp/work"
  tgit -C "$gtmp/work" commit -q --allow-empty -m A
  tdef=$(tgit -C "$gtmp/work" rev-parse --abbrev-ref HEAD)
  tgit -C "$gtmp/work" checkout -q -b mr-src
  tgit -C "$gtmp/work" commit -q --allow-empty -m "MR head"
  t_head=$(tgit -C "$gtmp/work" rev-parse HEAD)
  tgit -C "$gtmp/work" checkout -q "$tdef"      # 裸库的默认分支 = 这时 work 所在的分支
  tgit clone -q --bare "$gtmp/work" "$gtmp/bare"
  run_ck() {  # MR_TARGET_BRANCH → "rc|输出"；每次重新 clone
    local out rc=0
    rm -rf "$gtmp/business"; tgit clone -q --no-tags "$gtmp/bare" "$gtmp/business"
    out=$(WORKROOT="$gtmp" HEAD_SHA="$t_head" CI_COMMIT_REF_NAME=mr-src MR_TARGET_BRANCH="$1" \
          GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
          /bin/bash -c "set -euo pipefail; $ck_block" 2>&1) || rc=$?
    printf '%s|%s' "$rc" "$out"
  }
  for bad in "-upload-pack=touch /tmp/pwned" "main x" "$(printf 'ma\tin')" "$(printf 'ma\001in')"; do
    got=$(run_ck "$bad")
    assert_eq "${got%%|*}" "92" "㉓ MR_TARGET_BRANCH 形状不对时 92（${bad:0:12}）"
    assert_contains "$got" "MR_TARGET_BRANCH 以 - 开头或含空白/控制字符，拒绝评审" "㉓ 固定消息（${bad:0:12}）"
    assert_not_contains "$got" "upload-pack" "㉓ 不回显取值"
    assert_eq "$(tgit -C "$gtmp/business" rev-parse HEAD)" "$(tgit -C "$gtmp/bare" rev-parse "$tdef")" \
      "㉓ 拒绝时不动 HEAD（${bad:0:12}）"
  done
  # 空串是「没给目标分支」（可选项）：放行，不取
  assert_eq "$(run_ck "" | cut -d'|' -f1)" "0" "㉓ MR_TARGET_BRANCH 为空时放行（可选项）"
  # G4（issue 03）：检出段**不再**取目标分支——clone 之后目标分支又前进了一步，检出段跑完 refs/remotes/origin/<目标>
  # 仍是 clone 时的那个提交（跟上它是引擎第 4 步自己那次 fetch 的事），少一次往返就少撞一次 Codeup 的 429
  rm -rf "$gtmp/business"; tgit clone -q --no-tags "$gtmp/bare" "$gtmp/business"
  t_old=$(tgit -C "$gtmp/business" rev-parse "refs/remotes/origin/$tdef")
  tgit -C "$gtmp/work" commit -q --allow-empty -m "目标分支在 clone 之后又前进了"
  tgit -C "$gtmp/work" push -q "$gtmp/bare" "$tdef"
  WORKROOT="$gtmp" HEAD_SHA="$t_head" CI_COMMIT_REF_NAME=mr-src MR_TARGET_BRANCH="$tdef" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    /bin/bash -c "set -euo pipefail; $ck_block" >/dev/null 2>&1
  assert_eq "$(tgit -C "$gtmp/business" rev-parse "refs/remotes/origin/$tdef")" "$t_old" \
    "㉓ G4：检出段不取目标分支（refs/remotes/origin/<目标> 仍是 clone 时的值）"
  # 目标分支在服务端不存在：检出段不取它，所以既不失败也不留「取目标分支失败」那一行（引擎第 4 步会报）
  got=$(run_ck "no-such-branch")
  assert_eq "${got%%|*}" "0" "㉓ 目标分支在服务端不存在时检出段照常通过"
  assert_not_contains "$got" "取目标分支失败" "㉓ G4：检出段不再有「取目标分支失败」那一行"
  # 检出失败（92）时也带 git 的报错；补取源分支失败时同样留痕
  out=$(rm -rf "$gtmp/business"; tgit clone -q --no-tags "$gtmp/bare" "$gtmp/business"
        WORKROOT="$gtmp" HEAD_SHA=0000000000000000000000000000000000000000 CI_COMMIT_REF_NAME=mr-src \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        /bin/bash -c "set -euo pipefail; $ck_block" 2>&1) && rc=0 || rc=$?
  assert_eq "$rc" "92" "㉓ 提交不存在时 92"
  assert_contains "$out" "  git: " "㉓ 检出失败时日志里有 git 自己的报错"
  out=$(rm -rf "$gtmp/business"; tgit clone -q --no-tags "$gtmp/bare" "$gtmp/business"
        WORKROOT="$gtmp" HEAD_SHA=0000000000000000000000000000000000000000 CI_COMMIT_REF_NAME=gone \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        /bin/bash -c "set -euo pipefail; $ck_block" 2>&1) || true
  assert_contains "$out" "补取源分支失败（取值不回显）" "㉓ 补取源分支失败时留一行"
  rm -rf "$gtmp"
else
  echo "SKIP: 无 /usr/bin/git，跳过 ㉓ git 报错尾巴与目标分支断言" >&2
fi
assert_not_contains "$code_lines" 'origin "$MR_TARGET_BRANCH"' \
  "㉓ 目标分支不得再以裸值出现在 fetch 的参数位置（以 - 开头就是选项）"
assert_not_contains "$code_lines" 'refs/remotes/origin/${MR_TARGET_BRANCH}' \
  "㉓ G4：入口脚本不再单独取目标分支（引擎第 4 步用带前缀的 refspec 取）"

# ㉒ 按 MR 的租约（spec I6 ②，全分支复审 s3 I-1；Task 14 验收 C2 在真实环境证实了同一 MR 两次推送并发、
#   丢失更新）。行为断言：把租约那一段与「调引擎 + 收尾」那一段原样抽出来跑，只把 aws / date / sleep /
#   引擎换成替身。aws 替身（fake-aws-dynamodb.py）**真的求值**条件表达式、持文件锁读改写同一张表，所以
#   删掉条件、改成无条件释放这类改动在这里真的会写出重叠或误放；git 用真的本地裸库（ls-remote 是真的）。
if [[ -x /usr/bin/git && -x /usr/bin/jq ]] && command -v python3 >/dev/null; then
  ltmp=$(mktemp -d)
  lease_block=$(awk '/^# ── 按 MR 的租约/{f=1} /^# ── 与 Flow run block/{exit} f{print}' "$ENTRY")
  tail_block=$(awk '/^rc=0$/{f=1} f{print} f&&/^exit "\$rc"$/{exit}' "$ENTRY")
  assert_contains "$lease_block" 'exit 93' "㉒ 抽到了租约那一段"
  assert_contains "$lease_block" 'head-check result=superseded' "㉒ 抽到的租约段包含核对最新提交那一段"
  assert_contains "$tail_block" 'scripts/kiro-review.sh' "㉒ 抽到了调引擎与收尾那一段"
  printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$PWD/fake-aws-dynamodb.py" > "$ltmp/aws"
  cat > "$ltmp/date" <<'STUB'
#!/bin/sh
if [ -n "${FAKE_CLOCK:-}" ]; then cat "$FAKE_CLOCK"; else exec /bin/date "$@"; fi
STUB
  # sleep 替身：等待租约那一轮是 10 秒，续期循环那一轮是 30 秒（issue 04）。续期那一轮默认真睡 0.2 秒
  # （RENEW_REAL_SLEEP），否则续期循环会在引擎替身运行的那一小会儿里空转几十次。
  cat > "$ltmp/sleep" <<'STUB'
#!/bin/sh
echo "$1" >> "$SLEEP_LOG"
step="$1"; if [ "$1" = 30 ] && [ -n "${RENEW_CLOCK_STEP:-}" ]; then step="$RENEW_CLOCK_STEP"; fi
if [ -n "${FAKE_CLOCK:-}" ]; then echo $(( $(cat "$FAKE_CLOCK") + step )) > "$FAKE_CLOCK"; fi
if [ -n "${SLEEP_HOOK:-}" ]; then sh -c "$SLEEP_HOOK"; fi
if [ "$1" = 30 ]; then exec /bin/sleep "${RENEW_REAL_SLEEP:-0.2}"; fi
exec /bin/sleep "${REAL_SLEEP:-0}"
STUB
  # timeout 替身：记下参数；命令行里含 TIMEOUT_EXPIRE_MATCH 时不跑命令、以 TIMEOUT_EXPIRE_RC（缺省 124，GNU timeout
  # 的超时码）退出，并把假时钟拨快 TIMEOUT_EXPIRE_ADVANCE 秒（模拟「真的跑满了上限」；不拨 = 早早被杀，比如 OOM）
  cat > "$ltmp/timeout" <<'STUB'
#!/bin/sh
echo "$*" >> "$TIMEOUT_LOG"
while [ $# -gt 0 ]; do case "$1" in -k) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
case "$*" in *"${TIMEOUT_EXPIRE_MATCH:-<never>}"*)
  if [ -n "${FAKE_CLOCK:-}" ] && [ -n "${TIMEOUT_EXPIRE_ADVANCE:-}" ]; then
    echo $(( $(cat "$FAKE_CLOCK") + TIMEOUT_EXPIRE_ADVANCE )) > "$FAKE_CLOCK"; fi
  exit "${TIMEOUT_EXPIRE_RC:-124}" ;;
esac
exec "$@"
STUB
  cat > "$ltmp/engine" <<'STUB'
#!/bin/sh
echo "engine-start $LOCK_KEY" >> "$EVENTS"
cp "$FAKE_DDB_STATE" "$ENGINE_SNAPSHOT"
if [ -n "${ENGINE_HOOK:-}" ]; then sh -c "$ENGINE_HOOK"; fi
/bin/sleep "${ENGINE_SECONDS:-0}"
cp "$FAKE_DDB_STATE" "$ENGINE_SNAPSHOT.end"
echo "engine-end $LOCK_KEY" >> "$EVENTS"
exit "${ENGINE_RC:-0}"
STUB
  # 元数据端点替身：只答任务级端点 `<元数据地址>/task`（别的地址一律当成读取失败，curl -f 的 22），正文是
  # FAKE_TASK_META；FAKE_TASK_META_FAIL 非空 = 端点读取失败。读容器级端点当持有者来源的改动会在这里读不到。
  cat > "$ltmp/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do url="$a"; done
case "$url" in "$ECS_CONTAINER_METADATA_URI_V4/task") ;; *) exit 22 ;; esac
[ -z "${FAKE_TASK_META_FAIL:-}" ] || exit 22
printf '%s' "$FAKE_TASK_META"
STUB
  chmod +x "$ltmp/aws" "$ltmp/date" "$ltmp/sleep" "$ltmp/engine" "$ltmp/curl" "$ltmp/timeout"
  run_block=$(printf '%s\n%s\n%s\n' "$RETRY_SRC" "$lease_block" "$tail_block" \
    | sed -e "s#/usr/local/bin/aws#$ltmp/aws#g" -e "s#/bin/date#$ltmp/date#g" \
          -e "s#/bin/sleep#$ltmp/sleep#g" -e "s#/usr/bin/curl#$ltmp/curl#g" \
          -e "s#/usr/bin/timeout#$ltmp/timeout#g" \
          -e "s#/bin/bash -p \"\$PKG/scripts/kiro-review.sh\"#$ltmp/engine#")
  assert_contains "$run_block" "$ltmp/engine || rc=\$?" "㉒ 引擎调用换成了替身"
  assert_not_contains "$run_block" "/usr/local/bin/aws" "㉒ aws 全部换成了替身（不会碰真的 AWS）"
  assert_not_contains "$run_block" "/usr/bin/curl" "㉒ curl 全部换成了元数据端点替身"
  assert_not_contains "$run_block" "/usr/bin/timeout" "㉒ timeout 全部换成了替身"

  # 真的本地裸库：源分支 feat 上两个提交，c1 是本任务的 HEAD_SHA；「源分支又被推过」= 把 c2 推进裸库
  lgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
             GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
             GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com /usr/bin/git "$@"; }
  lgit init -q "$ltmp/work"
  lgit -C "$ltmp/work" commit -q --allow-empty -m base
  lgit -C "$ltmp/work" checkout -q -b feat
  lgit -C "$ltmp/work" commit -q --allow-empty -m c1
  c1=$(lgit -C "$ltmp/work" rev-parse HEAD)
  lgit clone -q --bare "$ltmp/work" "$ltmp/bare"
  lgit clone -q "$ltmp/bare" "$ltmp/business"
  lgit -C "$ltmp/work" commit -q --allow-empty -m c2
  c2=$(lgit -C "$ltmp/work" rev-parse HEAD)
  push_c2() { lgit -C "$ltmp/work" push -q -f "$ltmp/bare" "$1:refs/heads/feat"; }

  LEASE='lease#r1#7'
  ARN_A='arn:aws:ecs:us-west-2:123456789012:task/codeup-kiro/0123456789abcdef0123456789abcdef'
  ARN_B='arn:aws:ecs:us-west-2:123456789012:task/codeup-kiro/fedcba9876543210fedcba9876543210'
  reset_lease() {  # 每个用例从一张空表开始；可选参数是初始表的 JSON
    rm -f "$ltmp/state.json" "$ltmp/ddb.log" "$ltmp/sleep.log" "$ltmp/events" "$ltmp/snap.json"
    local init='{}'; if [[ $# -gt 0 ]]; then init="$1"; fi
    printf '%s' "$init" > "$ltmp/state.json"
    : > "$ltmp/sleep.log"; : > "$ltmp/events"; : > "$ltmp/ddb.log"; : > "$ltmp/timeout.log"
    rm -f "$ltmp/clock" "$ltmp/state.json.updates" "$ltmp/snap.json.end"
  }
  run_lease() {  # LOCK_KEY [KEY=VAL ...] → 打印 rc；stderr 在 $ltmp/err.<LOCK_KEY>
    local me="$1" rc=0; shift
    env AWS_REGION=us-west-2 LOCK_TABLE=t CODEUP_REPO_ID=r1 MR_LOCAL_ID=7 HEAD_SHA="$c1" \
        CI_COMMIT_REF_NAME=feat KIRO_TIMEOUT=60 WORKROOT="$ltmp" LOCK_KEY="$me" PKG=/nonexistent \
        ECS_CONTAINER_METADATA_URI_V4=http://169.254.170.2/v4/c0 FAKE_TASK_META="{\"TaskARN\":\"$ARN_A\"}" \
        FAKE_DDB_STATE="$ltmp/state.json" FAKE_DDB_LOG="$ltmp/ddb.log" SLEEP_LOG="$ltmp/sleep.log" \
        EVENTS="$ltmp/events" ENGINE_SNAPSHOT="$ltmp/snap.json" TIMEOUT_LOG="$ltmp/timeout.log" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
        "$@" /bin/bash -c "set -euo pipefail; $run_block" >/dev/null 2>"$ltmp/err.$me" </dev/null || rc=$?
    echo "$rc"
  }
  attr() { /usr/bin/jq -r --arg k "$2" --arg a "$3" '.[$k][$a] | (.S // .N // empty)' "$1"; }
  sleeps() { grep -cx 10 "$ltmp/sleep.log" | tr -d ' '; }   # 只数等待租约的那几轮（续期那一轮是 30）
  updates_ok() { grep -c "^update-item $LEASE ok$" "$ltmp/ddb.log" | tr -d ' '; }

  # 正向对照：空表 → 拿到、评审、释放。持有者是自己，lease_until 清零，expires_at 一直在（N4）。
  reset_lease; push_c2 "$c1"
  assert_eq "$(run_lease 'r1#7#A')" "0" "㉒ 无人持有时拿到租约并评审"
  assert_eq "$(cat "$ltmp/events")" $'engine-start r1#7#A\nengine-end r1#7#A' "㉒ 引擎跑了一次"
  assert_eq "$(attr "$ltmp/snap.json" "$LEASE" holder)" "r1#7#A|$ARN_A" \
    "㉒ 引擎运行期间持有者是自己：抢锁键 + 本任务 ARN（issue 02 L1'）"
  snap_until=$(attr "$ltmp/snap.json" "$LEASE" lease_until)
  assert_eq "$(( $(attr "$ltmp/snap.json" "$LEASE" expires_at) - snap_until ))" "86400" \
    "㉒ 租约记录带 expires_at = lease_until + 1 天（N4：不许有不带 TTL 的记录）"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" lease_until)" "0" "㉒ 退出时释放（lease_until 清零）"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" holder)" "" \
    "㉒ 释放抹掉持有者（issue 04 L3：被 kill 的续期循环留下的孤儿调用晚到时，条件 #h = :me 必然失败）"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "head-check result=current sha=${c1:0:7}" \
    "㉒ 最新提交就是 HEAD_SHA 时打 current"
  assert_eq "$(sleeps)" "0" "㉒ 无人持有时不等待"
  assert_nonzero "$(grep -c '^update-item r1#7#A ' "$ltmp/ddb.log" | tr -d ' ')" \
    "㉒ 正向对照：rc=0 时写过「已回写」标记（下面「超过上限时不置标记」那条断言的同一个模式在这里能匹配）"

  # issue 04：租期固定 120 秒（与 KIRO_TIMEOUT 无关，靠续期撑住长评审）；引擎包在总时长上限
  # engine_cap = KIRO_TIMEOUT + 1800 里。0 是有意义的取值（不回落 900），0600 按十进制，非数字按引擎缺省 900。
  # 前导零的样例刻意**不用 0900**：去掉 `10#` 之后 bash 3.2 报「value too great for base」却不中止，
  # 取值留在缺省 900——恰好等于 0900 的正确结果，变异测试因此假绿过一次。
  # 续期那一轮真睡 5 秒：引擎开始时快照里的 lease_until 只可能来自拿租约或紧接着那次立刻续期，两者读到的时钟都是 5000。
  for kt in '60:1860' '0:1800' '0600:2400' '15m:2700'; do
    reset_lease; echo 5000 > "$ltmp/clock"
    run_lease 'r1#7#A' KIRO_TIMEOUT="${kt%%:*}" FAKE_CLOCK="$ltmp/clock" RENEW_REAL_SLEEP=5 >/dev/null
    assert_eq "$(attr "$ltmp/snap.json" "$LEASE" lease_until)" "5120" \
      "㉒ KIRO_TIMEOUT=${kt%%:*} 时租约到期仍是 现在 + 120 秒"
    assert_contains "$(cat "$ltmp/timeout.log")" "-k 30 ${kt##*:} $ltmp/engine" \
      "㉒ KIRO_TIMEOUT=${kt%%:*} 时引擎总时长上限 = ${kt##*:} 秒（KIRO_TIMEOUT + 1800），另给 30 秒 KILL 余量"
  done

  # 续期：引擎运行期间把 lease_until 续到「那一刻 + 120」，expires_at 跟着推（N4）。为了让「续多长」可以逐字断言：
  # 续期那一轮不拨假时钟（RENEW_CLOCK_STEP=0），引擎一开始把时钟拨到 7000——之后每次续期读到的都是 7000，
  # 引擎结束时 lease_until 必须正好是 7120（复审 Important 2：只断言「越过 5120」时，续 30 或 90 秒也能过）。
  reset_lease; echo 5000 > "$ltmp/clock"
  assert_eq "$(run_lease 'r1#7#A' FAKE_CLOCK="$ltmp/clock" ENGINE_SECONDS=1 RENEW_REAL_SLEEP=0.1 RENEW_CLOCK_STEP=0 \
               ENGINE_HOOK='echo 7000 > "$FAKE_CLOCK"')" "0" "㉒ 前提：带续期的评审正常结束"
  end_until=$(attr "$ltmp/snap.json.end" "$LEASE" lease_until)
  assert_eq "$end_until" "7120" "㉒ 续期把租约续到「续期那一刻 + 120 秒」（引擎结束时的快照）"
  # 续期循环每一轮睡的都正好是 LEASE_RENEW_EVERY（30）秒：sleep 替身只数 10 秒的等待，续期间隔改成比租期还长
  # 也不会有别的断言变红（复审 Important 1 实测过 150 秒）
  assert_eq "$(LC_ALL=C grep -vx 10 "$ltmp/sleep.log" | sort -u)" "30" "㉒ 续期循环每一轮睡 30 秒"
  assert_eq "$(( $(attr "$ltmp/snap.json.end" "$LEASE" expires_at) - end_until ))" "86400" \
    "㉒ 续期时 expires_at 同步 = lease_until + 1 天（N4）"
  assert_eq "$(attr "$ltmp/snap.json.end" "$LEASE" holder)" "r1#7#A|$ARN_A" "㉒ 续期不改持有者"
  assert_eq "$([ "$(updates_ok)" -ge 3 ] && echo yes)" "yes" "㉒ 拿租约 + 至少一次续期 + 释放（共 $(updates_ok) 次写入）"
  # 起续期循环时先立刻续一次（拿租约那次调用可能慢慢才成功，复审 Minor）：续期那一轮真睡 5 秒、引擎 1 秒，
  # 这期间能出现的续期只有那「立刻一次」
  reset_lease
  assert_eq "$(run_lease 'r1#7#A' ENGINE_SECONDS=1 RENEW_REAL_SLEEP=5)" "0" "㉒ 前提：评审正常结束"
  assert_eq "$(updates_ok)" "3" "㉒ 起续期循环时先立刻续一次（拿租约 + 立刻续期 + 释放）"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" lease_until)" "0" "㉒ 带续期的评审结束后照样释放"
  # L6：退出之后续期循环已经停了——再等一会儿，表上不再有任何写入
  n_before=$(wc -l < "$ltmp/ddb.log"); /bin/sleep 0.6
  assert_eq "$(wc -l < "$ltmp/ddb.log")" "$n_before" "㉒ L6：退出之后不再有续期写入（续期循环没有泄漏）"

  # 续期调用自带短的 CLI 超时（静态）：CLI 缺省连接/读各 60 秒、共 3 次，一次续期就可能比 120 秒的租期还长
  renew_fn=$(awk '/^lease_renew_loop\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ENTRY")
  assert_contains "$renew_fn" "update-item --cli-connect-timeout 2 --cli-read-timeout 5" "㉒ 续期调用带短的 CLI 超时"
  # 续期遇到别的错误（限流）：打代号、下一轮接着续，不停。第 1 次写是拿租约，第 2 次是第一次续期
  reset_lease
  assert_eq "$(run_lease 'r1#7#A' FAKE_DDB_FAIL_NTH=2 ENGINE_SECONDS=1 RENEW_REAL_SLEEP=0.1)" "0" \
    "㉒ 续期失败一次不影响评审"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "续期 MR 租约失败（code=ProvisionedThroughputExceededException），下一轮再试" \
    "㉒ 续期失败打一行带错误码的消息"
  # 数「失败之后的成功写入」至少 2 次：释放本身也是一次成功的 update-item，只数 1 次的话「失败一次就停止续期」
  # 照样通过（变异 N4 在这里假绿过一次）。
  after_fail=$(awk -v k="$LEASE" '$2==k && $3=="injected-error"{f=1; next} f && $2==k && $3=="ok"{n++} END{print n+0}' "$ltmp/ddb.log")
  assert_eq "$([ "$after_fail" -ge 2 ] && echo yes)" "yes" \
    "㉒ 续期失败之后接着续：失败之后还有 ${after_fail} 次成功写入（至少一次续期 + 释放）"

  # L1：第二个任务在第一个持有期间必须等，第一个结束（释放）之后才轮到它——两个真的并发进程
  reset_lease
  run_lease 'r1#7#A' ENGINE_SECONDS=1.5 >/dev/null &
  a_pid=$!
  for _ in $(seq 1 50); do grep -q 'engine-start r1#7#A' "$ltmp/events" && break; /bin/sleep 0.1; done
  assert_contains "$(cat "$ltmp/events")" "engine-start r1#7#A" "㉒ 前提：第一个任务的引擎已经在跑"
  b_rc=$(run_lease 'r1#7#1244b' REAL_SLEEP=0.2)
  wait "$a_pid"
  assert_eq "$b_rc" "0" "㉒ 第二个任务等到租约后正常评审"
  assert_eq "$(cat "$ltmp/events")" \
    $'engine-start r1#7#A\nengine-end r1#7#A\nengine-start r1#7#1244b\nengine-end r1#7#1244b' \
    "㉒ L1：同一 MR 的两次引擎运行不重叠（第二个在第一个结束之后才开始）"
  assert_nonzero "$(sleeps)" "㉒ 第二个任务确实等过（轮询过至少一次）"
  assert_contains "$(cat "$ltmp/err.r1#7#1244b")" "等待租约" "㉒ 等待时打一行说明"

  # L1'（issue 02）：同一个 LOCK_KEY 的两个任务（RunTask 客户端耗尽重试、服务端其实已起，调度器释放锁后同一
  # 报文又被重放）同样互斥。持有者只记 LOCK_KEY 时，第二个任务被 `#h = :me` 当成本人、直接进去 → 两次引擎重叠。
  reset_lease
  run_lease 'r1#7#A' ENGINE_SECONDS=1.5 >/dev/null &
  a_pid=$!
  for _ in $(seq 1 50); do grep -q 'engine-start r1#7#A' "$ltmp/events" && break; /bin/sleep 0.1; done
  assert_contains "$(cat "$ltmp/events")" "engine-start r1#7#A" "㉒ 前提：同键的第一个任务的引擎已经在跑"
  b_rc=$(run_lease 'r1#7#A' REAL_SLEEP=0.2 FAKE_TASK_META="{\"TaskARN\":\"$ARN_B\"}")
  wait "$a_pid"
  assert_eq "$b_rc" "0" "㉒ 同键的第二个任务等到租约后正常评审"
  assert_eq "$(cat "$ltmp/events")" \
    $'engine-start r1#7#A\nengine-end r1#7#A\nengine-start r1#7#A\nengine-end r1#7#A' \
    "㉒ L1'：同一个 LOCK_KEY 的两个任务，引擎运行也不重叠"
  assert_nonzero "$(sleeps)" "㉒ 同键的第二个任务确实等过"
  assert_eq "$(attr "$ltmp/snap.json" "$LEASE" holder)" "r1#7#A|$ARN_B" \
    "㉒ 第二个任务的引擎运行期间，持有者是它自己（同键、ARN 不同）"

  # L1''：同一个任务的持有者值不变 → AWS CLI 自己的重试（上一次尝试已经写入、应答丢了）被 `#h = :me` 认成本人，
  # 不等、直接进去。这里用「表里已经是我、而且远未到期」模拟那次已落地的写入。
  reset_lease "{\"$LEASE\":{\"pk\":{\"S\":\"$LEASE\"},\"holder\":{\"S\":\"r1#7#A|$ARN_A\"},\"lease_until\":{\"N\":\"999999999999\"},\"expires_at\":{\"N\":\"999999999999\"}}}"
  echo 1000 > "$ltmp/clock"
  assert_eq "$(run_lease 'r1#7#A' FAKE_CLOCK="$ltmp/clock")" "0" "㉒ L1''：本任务自己已写下的租约直接重入"
  assert_eq "$(sleeps)" "0" "㉒ L1''：重入不等待"
  # 反向对照：同键、别的任务（ARN 不同）写下的未到期租约 → 必须等（等满上限 93）
  reset_lease "{\"$LEASE\":{\"pk\":{\"S\":\"$LEASE\"},\"holder\":{\"S\":\"r1#7#A|$ARN_B\"},\"lease_until\":{\"N\":\"999999999999\"},\"expires_at\":{\"N\":\"999999999999\"}}}"
  echo 1000 > "$ltmp/clock"
  jump='echo $(( $(cat "$FAKE_CLOCK") + 100000 )) > "$FAKE_CLOCK"'   # 第一轮等待之后把假时钟拨过等待上限
  assert_eq "$(run_lease 'r1#7#A' FAKE_CLOCK="$ltmp/clock" SLEEP_HOOK="$jump")" "93" "㉒ 同键别的任务持有时不得重入"
  assert_eq "$(cat "$ltmp/events")" "" "㉒ 同键别的任务持有时不跑引擎"

  # 读不到本任务 ARN → fail closed（93），不碰租约、不跑引擎。端点失败、字段缺失、形状不对都一样
  for meta in FAIL '{}' '{"TaskARN":""}' '{"TaskARN":"not-an-arn"}' 'not json' \
              '{"TaskARN":"arn:aws:ecs:us-west-2:123456789012:task/c/x y"}'; do
    reset_lease
    if [[ "$meta" == FAIL ]]; then rc=$(run_lease 'r1#7#A' FAKE_TASK_META_FAIL=1)
    else rc=$(run_lease 'r1#7#A' FAKE_TASK_META="$meta"); fi
    assert_eq "$rc" "93" "㉒ 读不到本任务 ARN 时以 93 退出（${meta}）"
    assert_contains "$(cat "$ltmp/err.r1#7#A")" "读不到本任务的 ARN（ECS 任务级元数据端点），无法确定租约持有者，拒绝评审" \
      "㉒ 读不到 ARN 的消息固定（${meta}）"
    assert_eq "$(cat "$ltmp/ddb.log")" "" "㉒ 读不到 ARN 时不碰租约表（${meta}）"
    assert_eq "$(cat "$ltmp/events")" "" "㉒ 读不到 ARN 时不跑引擎（${meta}）"
  done

  # L5：拿到租约后源分支已前进，且新提交有抢锁记录 → 退出 0、不评审、不发评论，并释放租约
  reset_lease "{\"r1#7#$c2\":{\"pk\":{\"S\":\"r1#7#$c2\"},\"expires_at\":{\"N\":\"99999999999\"}}}"
  push_c2 "$c2"
  assert_eq "$(run_lease 'r1#7#A')" "0" "㉒ 被新推送取代时退出 0（兜底 Lambda 看到 0 不回写）"
  assert_eq "$(cat "$ltmp/events")" "" "㉒ 被取代时不跑引擎"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "head-check result=superseded sha=${c1:0:7} tip=${c2:0:7}" \
    "㉒ 被取代时打 superseded（固定形状）"
  assert_contains "$(cat "$ltmp/ddb.log")" "get-item r1#7#$c2 hit" \
    "㉒ 查的是新提交的抢锁键（仓库#MR#提交，与调度器 lock_key 同形）"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" lease_until)" "0" "㉒ 被取代退出时同样释放租约"

  # 源分支前进了但新提交**没有**抢锁记录（那次投递丢了）→ 照常评自己的提交。查不到记录的两种输出形状都要认。
  for empty in braces blank; do
    reset_lease; push_c2 "$c2"
    assert_eq "$(run_lease 'r1#7#A' FAKE_DDB_EMPTY_GET="$empty")" "0" "㉒ 新提交无抢锁记录时照常评审（${empty}）"
    assert_eq "$(head -1 "$ltmp/events")" "engine-start r1#7#A" "㉒ 新提交无抢锁记录时跑引擎（${empty}）"
    assert_contains "$(cat "$ltmp/err.r1#7#A")" "head-check result=moved-unclaimed" \
      "㉒ 新提交无抢锁记录时打 moved-unclaimed（${empty}）"
  done
  # 读抢锁记录本身失败 → 照常评审（退化成加租约之前的行为，不更糟）
  reset_lease; push_c2 "$c2"
  assert_eq "$(run_lease 'r1#7#A' FAKE_DDB_FAIL=get-item)" "0" "㉒ 读新提交的抢锁记录失败时照常评审"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "head-check result=claim-unknown" "㉒ 读失败时打 claim-unknown"
  assert_eq "$(head -1 "$ltmp/events")" "engine-start r1#7#A" "㉒ 读失败时跑引擎"
  # ls-remote 失败 → 照常评审
  reset_lease; push_c2 "$c2"
  lgit -C "$ltmp/business" remote set-url origin "$ltmp/no-such-repo"
  assert_eq "$(run_lease 'r1#7#A')" "0" "㉒ ls-remote 失败时照常评审"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "head-check result=unknown" "㉒ ls-remote 失败时打 unknown"
  assert_eq "$(head -1 "$ltmp/events")" "engine-start r1#7#A" "㉒ ls-remote 失败时跑引擎"
  lgit -C "$ltmp/business" remote set-url origin "$ltmp/bare"
  push_c2 "$c1"

  # L2：别人的租约已过期（lease_until < now）→ 直接接管，不等；恰好等于 now 还不算过期（严格小于）
  reset_lease "{\"$LEASE\":{\"pk\":{\"S\":\"$LEASE\"},\"holder\":{\"S\":\"r1#7#old\"},\"lease_until\":{\"N\":\"9990\"},\"expires_at\":{\"N\":\"96390\"}}}"
  echo 10000 > "$ltmp/clock"
  assert_eq "$(run_lease 'r1#7#A' FAKE_CLOCK="$ltmp/clock")" "0" "㉒ 过期租约被接管"
  assert_eq "$(sleeps)" "0" "㉒ 过期租约不等待"
  assert_eq "$(attr "$ltmp/snap.json" "$LEASE" holder)" "r1#7#A|$ARN_A" "㉒ 接管后引擎运行期间持有者是自己"
  reset_lease "{\"$LEASE\":{\"pk\":{\"S\":\"$LEASE\"},\"holder\":{\"S\":\"r1#7#old\"},\"lease_until\":{\"N\":\"10000\"},\"expires_at\":{\"N\":\"96400\"}}}"
  echo 10000 > "$ltmp/clock"
  assert_eq "$(run_lease 'r1#7#A' FAKE_CLOCK="$ltmp/clock")" "0" "㉒ 到期那一刻之后接管"
  assert_eq "$(sleeps)" "1" "㉒ lease_until == now 还不算过期：等一轮（10 秒）之后才接管"

  # L3：我挂住期间租约被别人接管（这里由引擎替身模拟），我退出时绝不能放掉别人的租约
  reset_lease
  steal="$ltmp/aws dynamodb update-item --region x --table-name t --key '{\"pk\":{\"S\":\"$LEASE\"}}' \
--update-expression 'SET #h = :h, #u = :u' --expression-attribute-names '{\"#h\":\"holder\",\"#u\":\"lease_until\"}' \
--expression-attribute-values '{\":h\":{\"S\":\"r1#7#new\"},\":u\":{\"N\":\"77777777777\"}}'"
  assert_eq "$(run_lease 'r1#7#A' ENGINE_HOOK="$steal" ENGINE_SECONDS=1 RENEW_REAL_SLEEP=0.1)" "0" \
    "㉒ 前提：被接管的任务自己正常结束"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "MR 租约已被别的任务接管，停止续期" "㉒ 续期发现被接管时打一行并停止续期"
  assert_eq "$(grep -c 'MR 租约已被别的任务接管，停止续期' "$ltmp/err.r1#7#A" | tr -d ' ')" "1" \
    "㉒ 被接管之后真的停止续期（引擎还跑了约 1 秒、续期一轮 0.1 秒，没停的话这一行会打很多次）"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" holder)" "r1#7#new" "㉒ L3：退出时不改别人的持有"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" lease_until)" "77777777777" \
    "㉒ L3：退出时绝不放掉别人的租约（lease_until 原样）"

  # 等待有上限：别人一直持有（这里是远未到期的租约）→ 等满 engine_cap + 600 秒（KIRO_TIMEOUT=60 → 2460）后
  # 以 93 退出，不跑引擎
  reset_lease "{\"$LEASE\":{\"pk\":{\"S\":\"$LEASE\"},\"holder\":{\"S\":\"r1#7#hung\"},\"lease_until\":{\"N\":\"999999999999\"},\"expires_at\":{\"N\":\"999999999999\"}}}"
  echo 1000 > "$ltmp/clock"
  assert_eq "$(run_lease 'r1#7#A' FAKE_CLOCK="$ltmp/clock")" "93" "㉒ 等待超过上限时以 93 退出"
  assert_eq "$(sleeps)" "246" "㉒ 按 10 秒一轮等满 2460 秒（KIRO_TIMEOUT=60 + 1800 + 600）"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "等待同一 MR 的上一次评审超过 2460 秒仍未结束，拒绝评审" \
    "㉒ 等待超限的消息固定"
  assert_eq "$(cat "$ltmp/events")" "" "㉒ 等待超限时不跑引擎"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" holder)" "r1#7#hung" "㉒ 没拿到租约就退出时不碰别人的租约"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" lease_until)" "999999999999" "㉒ 没拿到租约时 lease_until 原样"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "head-check result=current sha=${c1:0:7}" \
    "㉒ 等待到上限时先再核对一次最新提交（这里仍是本任务的提交 → 照旧 93）"
  # A-M3：排队等到上限时源分支已前进、新提交也抢过锁 → 本任务已被取代：安静退出 0（不让兜底为旧提交发失败评论）
  reset_lease "{\"$LEASE\":{\"pk\":{\"S\":\"$LEASE\"},\"holder\":{\"S\":\"r1#7#hung\"},\"lease_until\":{\"N\":\"999999999999\"},\"expires_at\":{\"N\":\"999999999999\"}},\"r1#7#$c2\":{\"pk\":{\"S\":\"r1#7#$c2\"},\"expires_at\":{\"N\":\"99999999999\"}}}"
  push_c2 "$c2"; echo 1000 > "$ltmp/clock"
  assert_eq "$(run_lease 'r1#7#A' FAKE_CLOCK="$ltmp/clock" SLEEP_HOOK="$jump")" "0" "㉒ A-M3：等到上限时已被取代 → 退出 0"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "head-check result=superseded sha=${c1:0:7} tip=${c2:0:7}" \
    "㉒ A-M3：打 superseded"
  assert_not_contains "$(cat "$ltmp/err.r1#7#A")" "拒绝评审" "㉒ A-M3：被取代时不打 93 的消息"
  assert_eq "$(cat "$ltmp/events")" "" "㉒ A-M3：不跑引擎"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" holder)" "r1#7#hung" "㉒ A-M3：没拿到租约，不碰别人的租约"
  push_c2 "$c1"

  # DynamoDB 别的错误 → fail closed（93），消息与等待超限区分开，只带错误码不带错误正文
  reset_lease
  assert_eq "$(run_lease 'r1#7#A' FAKE_DDB_FAIL=update-item)" "93" "㉒ 读写租约失败时以 93 退出"
  lerr=$(cat "$ltmp/err.r1#7#A")
  assert_contains "$lerr" "读写 MR 租约失败（code=ProvisionedThroughputExceededException），拒绝评审" \
    "㉒ 读写失败的消息带错误码"
  assert_not_contains "$lerr" "等待同一 MR" "㉒ 读写失败与等待超限是两条不同的消息"
  assert_not_contains "$lerr" "provisioned throughput for the table" "㉒ 不打 AWS 错误正文"
  assert_eq "$(sleeps)" "0" "㉒ 读写失败时不重试等待"
  assert_eq "$(cat "$ltmp/events")" "" "㉒ 读写失败时不跑引擎"
  reset_lease
  assert_eq "$(run_lease 'r1#7#A' FAKE_DDB_FAIL=update-item FAKE_DDB_FAIL_KIND=connect)" "93" \
    "㉒ 连不上 DynamoDB 时以 93 退出"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "读写 MR 租约失败（code=unknown），拒绝评审" \
    "㉒ 没有错误码的失败记成 unknown（不从别的括号里捡词）"

  # 引擎超过总时长上限：timeout 以 124 结束 → 原样透出、打一行固定消息、照样释放租约、不置「已回写」标记
  reset_lease
  assert_eq "$(run_lease 'r1#7#A' TIMEOUT_EXPIRE_MATCH="$ltmp/engine")" "124" "㉒ 引擎超过总时长上限时退出码 124 原样透出"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "评审引擎超过总时长上限 1860 秒仍未结束，已终止" "㉒ 超过上限打一行固定消息"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" lease_until)" "0" "㉒ 超过上限时照样释放租约"
  assert_eq "$(grep -c '^update-item r1#7#A ' "$ltmp/ddb.log" | tr -d ' ')" "0" "㉒ 超过上限时不置「已回写」标记"
  # 137：30 秒内不理 TERM 被 KILL 与 OOM 同码——只有真的跑满了上限才打那行消息（复审 Minor）
  reset_lease; echo 5000 > "$ltmp/clock"
  assert_eq "$(run_lease 'r1#7#A' FAKE_CLOCK="$ltmp/clock" TIMEOUT_EXPIRE_MATCH="$ltmp/engine" TIMEOUT_EXPIRE_RC=137 \
               TIMEOUT_EXPIRE_ADVANCE=1890)" "137" "㉒ 跑满上限后被 KILL：137 原样透出"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "评审引擎超过总时长上限 1860 秒仍未结束，已终止" "㉒ 跑满上限后被 KILL 也打那行消息"
  reset_lease; echo 5000 > "$ltmp/clock"
  assert_eq "$(run_lease 'r1#7#A' FAKE_CLOCK="$ltmp/clock" TIMEOUT_EXPIRE_MATCH="$ltmp/engine" TIMEOUT_EXPIRE_RC=137)" \
    "137" "㉒ 早早被 KILL（像 OOM）：137 原样透出"
  assert_not_contains "$(cat "$ltmp/err.r1#7#A")" "总时长上限" "㉒ 没跑满上限的 137 不打上限那行消息（不把 OOM 说成超时）"
  # ls-remote 有上限（30 秒）：超时 = 核对未知 = 照常评审
  reset_lease; push_c2 "$c2"
  assert_eq "$(run_lease 'r1#7#A' TIMEOUT_EXPIRE_MATCH=ls-remote)" "0" "㉒ ls-remote 超时时照常评审"
  assert_contains "$(cat "$ltmp/timeout.log")" "30 /usr/bin/git -C $ltmp/business ls-remote origin" "㉒ ls-remote 包在 30 秒上限里"
  assert_contains "$(cat "$ltmp/err.r1#7#A")" "head-check result=unknown" "㉒ ls-remote 超时时打 unknown"
  assert_eq "$(head -1 "$ltmp/events")" "engine-start r1#7#A" "㉒ ls-remote 超时时跑引擎"
  push_c2 "$c1"

  # 引擎的退出码原样透出：EXIT 陷阱里的释放不得吞掉它（兜底 Lambda 按退出码判断要不要回写）
  reset_lease
  assert_eq "$(run_lease 'r1#7#A' ENGINE_RC=3)" "3" "㉒ 引擎非零退出码原样透出"
  assert_eq "$(attr "$ltmp/state.json" "$LEASE" lease_until)" "0" "㉒ 引擎失败时同样释放租约"
  rm -rf "$ltmp"
else
  echo "SKIP: 无 /usr/bin/git、/usr/bin/jq 或 python3，跳过 ㉒ 租约行为断言" >&2
fi

# ㉒ 静态顺序：租约在检出核对之后、引擎之前；陷阱挂在拿到租约之后（没拿到就退出时不碰别人的租约）
headnow_line=$(entry_code_line '\[\[ "\$head_now" == "\$HEAD_SHA" \]\]')
acquire_line=$(entry_code_line '^while :; do')
trap_line=$(entry_code_line '^trap lease_exit EXIT')
# 「核对最新提交」取**顶层的调用点**：核对本身抽成了函数、定义在等待循环之前（等待到上限时也要调它）
lsremote_line=$(entry_code_line '^if head_check_superseded; then exit 0; fi')
assert_eq "$([ -n "$headnow_line" ] && [ -n "$acquire_line" ] && [ -n "$trap_line" ] \
  && [ -n "$lsremote_line" ] && [ -n "$engine_line" ] && [ "$headnow_line" -lt "$acquire_line" ] \
  && [ "$acquire_line" -lt "$trap_line" ] && [ "$trap_line" -lt "$lsremote_line" ] \
  && [ "$lsremote_line" -lt "$engine_line" ] && echo yes)" "yes" \
  "㉒ 顺序：检出核对 → 拿租约 → 挂释放陷阱 → 核对最新提交 → 调引擎"

# ㉔ 元数据端点的每一次读取都有上限（issue 04）：端点挂住时 curl 永远不返回，任务永远不结束、也没有兜底评论。
curl_code=$(LC_ALL=C grep -nE '/usr/bin/curl ' "$ENTRY" | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*#')
assert_eq "$(printf '%s\n' "$curl_code" | wc -l | tr -d ' ')" "2" "㉔ entrypoint 里正好两处 curl（N1 摘要、租约持有者 ARN）"
assert_eq "$(printf '%s\n' "$curl_code" | LC_ALL=C grep -c -- '--max-time 10')" "2" "㉔ 两处 curl 都带 --max-time 10"

# ㉑ 元断言（复审 M-1 的收口）：本文件所有顺序断言的行号都必须落在**非注释行**上。注释里正当地
#   提到同一个词就会让「A 必须排在 B 之前」恒真——③ 的 call_line 已经踩过一次（注释里写了
#   scripts/kiro-review.sh，于是取到注释行 65 而不是真正的调用行）。这里把每个模式都过一遍，
#   免得下一处顺序断言又各自踩。
for pat in 'kiro-review\.sh' 'KIRO_IMAGE_DIGESTS' '^retry_git_429 /usr/bin/git clone ' '拒绝 clone' \
           '^export GIT_CONFIG_VALUE_0=' 'checkout -q --detach' \
           '\[\[ -n "\$\{HEAD_SHA:-\}" \]\]' ': "\$\{MR_TARGET_BRANCH:=\}"' \
           '\[\[ "\$head_now" == "\$HEAD_SHA" \]\]' '^while :; do' '^trap lease_exit EXIT' \
           'ls-remote origin' '^if head_check_superseded; then exit 0; fi'; do
  pat_line=$(entry_code_line "$pat")
  assert_eq "$([ -n "$pat_line" ] && echo yes)" "yes" "㉑ 顺序断言的模式必须匹配到代码：${pat}"
  assert_eq "$(LC_ALL=C sed -n "${pat_line}p" "$ENTRY" | LC_ALL=C grep -cE '^[[:space:]]*#')" "0" \
    "㉑ 取到的必须是代码行而不是注释行：${pat}"
done

report
