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

report
