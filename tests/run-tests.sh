#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for t in test-*.sh; do
  echo "=== ${t} ==="
  bash "$t"
done
echo "=== 全部测试通过 ==="
