#!/usr/bin/env bash
# 串行跑全部测试文件。每个文件的 stderr 先落到临时文件、跑完再原样打回 stderr（顺序不变），结束时对全部 stderr 做一遍
# bash 解析诊断的 grep（票 18 ⑦）：`unexpected EOF` / `command substitution` / `syntax error` / `unbound variable` / `write error` 这几类是
# 测试脚本**自身**的解析错误——bash 把断言的描述串里配不上对的反引号当命令替换，报一行错、断言照样 OK（2026-09-08 全套日志里
# 四行 `test-review-render.sh: command substitution: line 109x: unexpected EOF` 就这样被吞了两天）。命中即整体失败并把那几行打出来。
# 每个文件另打一行墙钟耗时（⑨ 的 fixture 效率对比要用）。
set -euo pipefail
cd "$(dirname "$0")"
errdir=$(mktemp -d); trap 'rm -rf "$errdir"' EXIT
DIAG_RE='unexpected EOF|command substitution|syntax error|unbound variable|write error'   # write error = 测试里 `渲染函数 | head -1` 之类让生产函数吃 EPIPE（CodeX 2026-09-09 复审 P2）
# 已跑完的那些 stderr 里有没有 bash 解析诊断：命中就打出来并返回 1。**每个退出点之前都要跑一次**——
# 原先只在全绿之后跑，某个套件先失败时 fail-fast 直接退出、这个块永远不打，而解析错误最常与失败同时出现。
diag_check() {
  local bad
  bad=$(grep -HnE "$DIAG_RE" "$errdir"/*.err 2>/dev/null | sed "s#^${errdir}/##" || true)
  [[ -n "$bad" ]] || return 0
  echo "=== bash 解析诊断：以下 stderr 行说明测试脚本自身有解析错误（断言报 OK 也算整体失败）===" >&2
  printf '%s\n' "$bad" >&2
  return 1
}
t0=$SECONDS
for t in test-*.sh; do
  echo "=== ${t} ==="
  t1=$SECONDS
  rc=0; bash "$t" 2> "$errdir/${t}.err" || rc=$?
  cat "$errdir/${t}.err" >&2
  echo "--- ${t}: ${rc} · $((SECONDS - t1))s"
  # 失败即止（后面的套件不跑），但**先**把已跑完那些的解析诊断打出来；退出码保留失败套件自己的
  [[ "$rc" == "0" ]] || { diag_check || true; exit "$rc"; }
done
diag_check || exit 1
echo "=== 全部测试通过（$((SECONDS - t0))s）==="
