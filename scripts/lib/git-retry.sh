# shellcheck shell=bash
# git 网络调用遇到 Codeup 的 HTTP 限流（429）时有界重试（issue 03）。
#
# 为什么在这里做：git 从 2.54 起才有原生的 429 重试（http.maxRetries / http.retryAfter），而运行环境里的 git 版本
# 不由这份脚本决定（Debian 13 及其 backports 只有 2.47，2026-09-30 实测）。实见过限流（`remote: 请求过于频繁，
# 请稍后重试！` / HTTP 429）打断目标分支 fetch，整轮评审失败。档位无关（I9）：只知道 git 与 Codeup。
#
# 只重试 429：鉴权失败、分支不存在这类确定性失败重试也不会好，退出码与 stderr 原样立刻返回（G1）。
# 退避 10、20、40 秒，最多 4 次尝试（G2）。git 看不到 Retry-After，所以用固定序列。
# stdout 每次尝试单独收，只透出最后一次的（G3）：调用方会拿 ls-remote 的输出做判断，失败那几次的半截输出不能混进去。
# 代价：输出按文本行处理（末尾多个换行合成一个、NUL 不保留）——包在这里的 git 网络命令都只输出文本行。
# 只用 bash 内建与 mktemp/cat/rm/sleep：source 它的脚本可能处在不同的 PATH 约定下（引擎在 PATH 门之后）。
#
# 用法：retry_git_429 <命令…>，例如 `retry_git_429 git fetch -q origin …`、`retry_git_429 /usr/bin/git clone …`。

# 这段 git 报错像不像限流。认两种写法：curl 的 `returned error: 429`（GET info/refs 被拒，与 smart HTTP 的 RPC 失败
# `error: RPC failed; HTTP 429 curl 22 The requested URL returned error: 429` 都带这一句）、Codeup 正文里的「请求过于
# 频繁」（git 以 `remote:` 行转出来）。不单独认 `HTTP 429`：真 git 的报错里它总与上一句同时出现（issue 03 复审实测
# v0/v2 两种协议），多认一种只多一个误判面。误判的代价有界：最多多等 70 秒再原样失败。
git_is_429() {
  [[ "$1" == *"returned error: 429"* || "$1" == *"请求过于频繁"* ]]
}

retry_git_429() {
  local err_file out rc delay err
  # 拿不到临时文件时退化成不重试地跑一次——绝不因为 mktemp 失败就不执行调用方的 git（复审 Minor）
  err_file=$(mktemp 2>/dev/null) || { "$@"; return; }
  for delay in 10 20 40 ""; do
    rc=0
    out=$("$@" 2>"$err_file") || rc=$?
    err=$(cat "$err_file")
    if [[ "$rc" -eq 0 || -z "$delay" ]] || ! git_is_429 "$err"; then
      rm -f "$err_file"
      [[ -z "$out" ]] || printf '%s\n' "$out"
      [[ -z "$err" ]] || printf '%s\n' "$err" >&2
      return "$rc"
    fi
    echo "git: Codeup 限流（HTTP 429），${delay} 秒后重试" >&2
    sleep "$delay"
  done
}
