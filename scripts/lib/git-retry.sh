# shellcheck shell=bash
# git 网络调用遇到 Codeup 的 HTTP 限流（429）时有界重试（issue 03）。
#
# 为什么在这里做：git 从 2.54 起才有原生的 429 重试（http.maxRetries / http.retryAfter），执行器镜像（Debian 13）
# 只有 2.47、backports 里也没有更新的 git（2026-09-30 实测），Flow 构建机的 git 版本更不受我们控制。沙箱里实见过
# 限流（`remote: 请求过于频繁，请稍后重试！` / HTTP 429）打断引擎的目标分支 fetch，整轮评审失败。
#
# 只重试 429：鉴权失败、分支不存在这类确定性失败重试也不会好，退出码与 stderr 原样立刻返回（G1）。
# 退避 10、20、40 秒，最多 4 次尝试（G2）。git 看不到 Retry-After，所以用固定序列。
# stdout 每次尝试单独收，只透出最后一次的（G3）：调用方会拿 ls-remote 的输出做判断，失败那几次的半截输出不能混进去。
# 只用 bash 内建与 mktemp/cat/rm/sleep：引擎（PATH 门之后）与执行器入口脚本（PID 1、PATH 是镜像缺省）都会 source 它。
#
# 用法：retry_git_429 <命令…>，例如 `retry_git_429 git fetch -q origin …`、`retry_git_429 /usr/bin/git clone …`。

# 这段 git 报错像不像限流。认三种写法：curl 的 `returned error: 429`（GET info/refs 就被拒）、
# `HTTP 429`（smart HTTP 的 RPC 失败）、Codeup 正文里的「请求过于频繁」（git 以 `remote:` 行转出来）。
git_is_429() {
  [[ "$1" == *"returned error: 429"* || "$1" == *"HTTP 429"* || "$1" == *"请求过于频繁"* ]]
}

retry_git_429() {
  local err_file out rc delay err
  err_file=$(mktemp)
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
