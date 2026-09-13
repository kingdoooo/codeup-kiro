#!/usr/bin/env bash
# PATH 可信性门（CodeX 2026-09-13 第三轮复审 P0/P1）。
#
# 本文件**只定义函数、不在顶层跑任何命令**，而且函数体只用 bash builtin。原因见下面第 3 条。
# 两个入口脚本（scripts/kiro-review.sh 与 scripts/probe/probe-kiro-allowlist.sh）都要在**第一个外部命令之前**
# source 它并调用 review_path_gate_or_die。
#
# 为什么需要这道门：
#   两个脚本都会在**不受信的业务仓库**目录下运行 git / jq / tr / cut / mktemp / curl / sha1sum 等外部工具。
#   PATH 决定这些名字解析到哪个文件，所以 PATH 的可信性就是这些工具的可信性。
#
# v1.5.0 的第一版门有三个缺陷，全部由 2026-09-13 第三轮复审复现，本文件是重写：
#   1. **位置太晚**：门在第 1.7 步，而 git / jq / cut / mktemp / dirname 早在第 1 步就跑过了（cwd 已是业务库）。
#      现在移到脚本最前面，`source` 之前——连 `SCRIPT_DIR` 里原来的 `dirname` 都换成了参数展开，
#      因为假 `dirname` 能把 PKG_ROOT 指到别处，等于换掉整个受信集成包。
#   2. **把「绝对路径」当成「可信路径」**：只要求条目以 `/` 开头，于是 `<业务库绝对路径>/bin` 照样通过——
#      MR 提交一个 `bin/git` 就能被执行（复现：假 git 在评审完成前被调用 8 次，还能读到启动脚本继承来的
#      YUNXIAO_TOKEN / KIRO_API_KEY）。现在**逐条解析物理路径并拒绝落在业务库内的条目**。
#   3. **用不受信的工具去检查 PATH**：第一版门自己用 `printf | tr ':' '\n'` 分割、`cut` 截断显示。
#      MR 提交一个假 `tr`，让它对分割请求只回 `/usr/bin`，门就看不见任何可疑条目（复现：门放行、假 git 照跑）。
#      现在整段只用参数展开、`[[ ]]`、`cd`/`pwd`（都是 builtin），一个外部命令都不用。
#
# 判据（缺一即拒绝运行）：
#   · PATH 未设置或为空                 → 拒绝（这本身是执行器配置错误）
#   · 空条目（`::` 与首尾的 `:`）        → 拒绝：POSIX 里空条目等于当前目录
#   · 相对条目                          → 拒绝
#   · 物理路径等于业务库或落在业务库内   → 拒绝（这一条是本轮新增的关键判据）
#   · 进不去 / 不存在的绝对条目          → **跳过并计数**：它现在拿不出可执行文件，而真实执行器上
#                                          `/opt/homebrew/sbin` 这类不存在的 PATH 条目非常常见，拒绝会误伤
#
# 失败时用 `exit 1` 而不是回写 MR 评论：回写要跑 curl 与 jq，而这道门的前提正是「PATH 上的工具不可信」——
# 为了发一条评论去执行可能被顶替的二进制，方向是反的。所以这类失败只表现为流水线标红（与脚本里别的
# 「定位到 MR 之前」的失败一致），setup-guide 第 7 节把「PATH 全绝对且不指向业务库」写成了执行器接入要求。
#
# 另一半不是这道门能管的：Flow 用什么解释器启动脚本（裸 `bash` 也走 PATH）。参考 YAML 已改成绝对路径
# `/bin/bash`，并在 setup-guide 里写明——脚本启动之前的 PATH 只能由运维保证。

# review_path_gate_or_die [<业务库目录>]
#   不传参数时取 ${REVIEW_REPO_DIR:-$PWD}。只用 builtin。
review_path_gate_or_die() {
  local repo="${1:-${REVIEW_REPO_DIR:-$PWD}}"
  local rest entry phys bad="" skipped=0 n=0

  if [[ -z "${PATH-}" ]]; then
    echo "[kiro-review] 错误：PATH 未设置或为空，拒绝运行：脚本要在不受信的业务仓库目录下执行 git / jq 等外部工具，PATH 必须是一组可信的绝对路径。请检查执行器配置" >&2
    exit 1
  fi
  # 业务库的物理路径（cd / pwd 都是 builtin；进不去就用原值，下面的比较仍然拦得住字面相同的条目）
  if phys=$(cd -P -- "$repo" 2>/dev/null && pwd -P); then repo="$phys"; fi

  # 逐条解析：**不能**用 `$(printf … | tr ':' '\n')`——① tr 是外部命令（正是要防的东西），
  # ② 命令替换会吃掉尾随换行，于是 `PATH=/usr/bin:` 末尾那个「等于当前目录」的空条目会凭空消失
  # （v1.5.0 的门就有这个洞，复现：PATH="$PATH:" 时门放行）。参数展开没有这两个问题。
  rest="${PATH}:"
  while [[ "$rest" == *:* ]]; do
    entry="${rest%%:*}"; rest="${rest#*:}"
    n=$((n + 1))
    if [[ -z "$entry" ]]; then
      bad="${bad}${bad:+, }第${n}项<空条目=当前目录>"; continue
    fi
    if [[ "$entry" != /* ]]; then
      bad="${bad}${bad:+, }第${n}项[${entry:0:40}]（相对路径）"; continue
    fi
    if ! phys=$(cd -P -- "$entry" 2>/dev/null && pwd -P); then
      skipped=$((skipped + 1)); continue      # 不存在 / 进不去：拿不出可执行文件，不算可疑
    fi
    if [[ "$phys" == "$repo" || "$phys" == "$repo"/* ]]; then
      bad="${bad}${bad:+, }第${n}项[${entry:0:40}]（解析到业务库内：${phys:0:60}）"
    fi
  done

  if [[ -n "$bad" ]]; then
    echo "[kiro-review] 错误：执行器的 PATH 不可信，拒绝运行（未执行任何外部命令）。本脚本会在**不受信的业务仓库**目录下运行 git / jq / tr / curl 等外部工具，PATH 决定这些名字解析到哪个文件：空条目与相对条目等于当前目录，指向业务仓库的条目等于让 MR 作者提供这些工具。请把 PATH 改成一组不在业务仓库内的绝对路径（setup-guide 第 7 节）。可疑条目：${bad}" >&2
    exit 1
  fi
  [[ "$skipped" == "0" ]] \
    || echo "[kiro-review] PATH 里有 ${skipped} 个不存在或进不去的绝对条目（跳过，它们拿不出可执行文件）" >&2
  return 0
}
