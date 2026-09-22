#!/usr/bin/env bash
# 把 aws/ 下的 Python 测试并入统一入口 `bash tests/run-tests.sh`。
# 缺 python3 或缺依赖时整体跳过并说明原因——沿用 test-kiro-review.sh 缺 timeout 时跳过的先例：
# 静默跳过会让一整片测试面在 CI 上消失而没人发现，所以必须打一行。
set -euo pipefail
cd "$(dirname "$0")/../aws"

# 先找约定的 in-repo venv（aws/.venv，见 aws/setup-guide.md「安装依赖」）；
# 依赖真的装进去、能导入才用它，否则退回系统 python3——venv 目录存在但没装依赖
# （装了一半、误删过）不能当作可用，那样会把「装错」误报成「装对了但测试碰巧不跑」。
if [[ -x .venv/bin/python3 ]] && .venv/bin/python3 -c 'import pytest, yaml' 2>/dev/null; then
  exec .venv/bin/python3 -m pytest tests -q
fi

if ! command -v python3 >/dev/null; then
  echo "SKIP: 未安装 python3，跳过 AWS 档位的 CDK/Lambda 测试" >&2
  exit 0
fi
if ! python3 -c 'import pytest, yaml' 2>/dev/null; then
  echo "SKIP: aws/requirements.txt 未安装（pip install -r aws/requirements.txt，装进 aws/.venv 或系统 python3），跳过 AWS 档位测试" >&2
  exit 0
fi

python3 -m pytest tests -q
