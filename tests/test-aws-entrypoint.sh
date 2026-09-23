#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh

ENTRY=../aws/executor/entrypoint.sh
YAML=../pipeline/flow-pipeline.yaml

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
gate_line=$(LC_ALL=C grep -n 'KIRO_IMAGE_DIGESTS' "$ENTRY" | head -1 | cut -d: -f1)
call_line=$(LC_ALL=C grep -n 'kiro-review.sh' "$ENTRY" | head -1 | cut -d: -f1)
assert_eq "$([ -n "$gate_line" ] && [ "$gate_line" -lt "$call_line" ] && echo yes)" "yes" \
  "N1：镜像摘要门必须排在评审脚本之前"

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

report
