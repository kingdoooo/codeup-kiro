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

report
