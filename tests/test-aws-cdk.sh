#!/usr/bin/env bash
# 把 aws/ 下的 Python 测试并入统一入口 `bash tests/run-tests.sh`。
# 缺 python3 或缺依赖时整体跳过并说明原因——沿用 test-kiro-review.sh 缺 timeout 时跳过的先例：
# 静默跳过会让一整片测试面在 CI 上消失而没人发现，所以必须打一行。
set -euo pipefail
cd "$(dirname "$0")/../aws"

if ! command -v python3 >/dev/null; then
  echo "SKIP: 未安装 python3，跳过 AWS 档位的 CDK/Lambda 测试" >&2
  exit 0
fi
if ! python3 -c 'import pytest, yaml' 2>/dev/null; then
  echo "SKIP: aws/requirements.txt 未安装（pip install -r aws/requirements.txt），跳过 AWS 档位测试" >&2
  exit 0
fi

python3 -m pytest tests -q
