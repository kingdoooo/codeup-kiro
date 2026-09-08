#!/usr/bin/env bash
# 串行跑全部测试文件。每个文件的 stderr 先落到临时文件、跑完再原样打回 stderr（顺序不变），结束时对全部 stderr 做一遍
# bash 解析诊断的 grep（票 18 ⑦）：`unexpected EOF` / `command substitution` / `syntax error` / `unbound variable` 这几类是
# 测试脚本**自身**的解析错误——bash 把断言的描述串里配不上对的反引号当命令替换，报一行错、断言照样 OK（2026-09-08 全套日志里
# 四行 `test-review-render.sh: command substitution: line 109x: unexpected EOF` 就这样被吞了两天）。命中即整体失败并把那几行打出来。
# 每个文件另打一行墙钟耗时（⑨ 的 fixture 效率对比要用）。
set -euo pipefail
cd "$(dirname "$0")"
errdir=$(mktemp -d); trap 'rm -rf "$errdir"' EXIT
DIAG_RE='unexpected EOF|command substitution|syntax error|unbound variable'
t0=$SECONDS
for t in test-*.sh; do
  echo "=== ${t} ==="
  t1=$SECONDS
  rc=0; bash "$t" 2> "$errdir/${t}.err" || rc=$?
  cat "$errdir/${t}.err" >&2
  echo "--- ${t}: ${rc} · $((SECONDS - t1))s"
  [[ "$rc" == "0" ]] || exit "$rc"
done
bad=$(grep -HnE "$DIAG_RE" "$errdir"/*.err | sed "s#^${errdir}/##" || true)
if [[ -n "$bad" ]]; then
  echo "=== bash 解析诊断：以下 stderr 行说明测试脚本自身有解析错误（断言报 OK 也算整体失败）===" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi
echo "=== 全部测试通过（$((SECONDS - t0))s）==="
