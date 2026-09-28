#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh

ENTRY=../aws/executor/entrypoint.sh
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
digest_lines=$(LC_ALL=C grep -E 'curl -sf|jq -r|self_digest=' "$ENTRY")
assert_not_contains "$digest_lines" '/task"' "N1：容器级端点不得带 /task 后缀（那是任务级端点）"
assert_contains "$digest_lines" '.ImageID' "N1：必须读取顶层 .ImageID"
assert_not_contains "$digest_lines" 'Containers[0]' "N1：不得从 .Containers[0].ImageID 取值（任务级端点的产物）"
# ⑧ ECS 返回的 ImageID 带 sha256: 前缀，比对 KIRO_IMAGE_DIGESTS（约定存裸十六进制）之前必须剥掉
assert_contains "$digest_lines" '#sha256:' "N1：摘要口径必须剥离 ECS 返回值的 sha256: 前缀"

# ⑨ Step 5 收尾（任务 10 复审 Critical 1）：置位「已回写」标记必须以 rc=0 为条件，
#   不能不分退出码都置位——脚本在 MR 定位之前有三类路径会以非零退出却什么评论都
#   没写，无条件置位会让这些「没发过评论」的失败被标记本身拦下、兜底 Lambda 也不再补发。
guard_line=$(LC_ALL=C grep -n '\[\[ "\$rc" -eq 0 \]\]' "$ENTRY" | head -1 | cut -d: -f1)
mark_line=$(LC_ALL=C grep -n 'update-item' "$ENTRY" | head -1 | cut -d: -f1)
close_line=$(LC_ALL=C grep -n '^fi$' "$ENTRY" | head -1 | cut -d: -f1)
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
assert_not_contains "$code_lines" '${CODEUP_REPO_ID}#' "I1：不得自己拼锁键"
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
clone_line=$(entry_code_line 'clone --no-tags')
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
#   `GIT_CONFIG_GLOBAL/SYSTEM=/dev/null`：把开发机自己的全局配置（osxkeychain 之类）隔离掉，
#   否则负向断言可能被本机 helper 满足、变成假绿；执行器镜像里本来就没有这些配置。
if [[ -x /usr/bin/git ]]; then
  cred_block=$(awk '/^cred_helper=/{f=1} f{print} f&&/^export GIT_CONFIG_VALUE_0=/{exit}' "$ENTRY")
  assert_contains "$cred_block" 'GIT_CONFIG_VALUE_0' "⑯ 抽到了凭证那一段"
  FAKE_TOKEN='t0k3n-for-test-only'
  NOPASS=$(command -v false)
  fill() {  # 主机 → "rc 输出"
    local out rc=0
    out=$(printf 'protocol=https\nhost=%s\n\n' "$1" \
      | YUNXIAO_TOKEN="$FAKE_TOKEN" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$NOPASS" \
        /bin/bash -c "set -euo pipefail; $cred_block
exec /usr/bin/git credential fill" 2>&1) || rc=$?
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

# ⑰ Task 14 第二个验收阻塞：clone 给的是仓库**默认分支**，必须自己检出 MR 的那个提交。
#   真实运行实测过（Codeup-Demo MR !4：汇总标记写成 master 的头 f29435f，MR 的头是 7baa0cd）。
#   行为断言用**真的本地裸库**：两个分支、MR 头在非默认分支上，跑抽出来的检出段，断言 HEAD 落在
#   MR 头而不是默认分支头。主机检查让「用本地路径 clone」没法直接跑，所以按控制器裁决只单独跑检出段
#   （clone 这一步由本测试自己做，等价于执行器 clone 完的状态）。
if [[ -x /usr/bin/git ]]; then
  ck_block=$(awk '/^# ── 检出 MR 的那个提交/{f=1} /^# ── 与 Flow run block/{exit} f{print}' "$ENTRY")
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
#   因为 -B 本身就保证了一致——它守的是将来有人换掉 -B 写法时不要静默评错提交）
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

report
