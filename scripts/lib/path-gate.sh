#!/usr/bin/env bash
# 启动环境门 + PATH 可信性门（CodeX 2026-09-13 第三轮/第四轮复审 P0/P1）。
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
#   · 物理路径等于业务库或落在业务库内   → 拒绝（条目自己进不去时按「最近的能进去的祖先」判断，见 fail-open ①②）
#   · 业务库目录本身解析不出物理路径     → 拒绝（见 fail-open ③）
#   · 业务库目录解析成 `/`               → 拒绝（见 fail-open ④）
#   · 其余「不存在 / 进不去」的绝对条目  → **跳过并计数**：它现在拿不出可执行文件，而真实执行器上
#                                          `/opt/homebrew/sbin` 这类不存在的 PATH 条目非常常见，拒绝会误伤
#
# 2026-09-13 第四轮复审复现的四个 fail-open 形态（本轮修的就是它们）：
#   ① `PATH=<业务库>/future-bin` 在该目录**尚不存在**时走「不存在 → 跳过」，门放行；目录一出现它立刻成为
#      有效 PATH 入口。这是 TOCTOU：门只看得到它执行那一刻的目录树，而业务库目录在脚本跑完之前可能被别人改动
#      （常驻 / 共享执行器上的并发运行与清理任务、外部重新 checkout、指进业务库的符号链接被换指向），
#      将来脚本自己也可能新增往业务库里写目录的代码。**不是 `git fetch` 干的**：fetch 只更新 refs 与对象，
#      不会把远端文件 materialize 到工作树里的任意路径（这条因果关系 2026-09-13 第五轮复审纠正）。
#   ② 条目末段不存在、但父目录是指进业务库的符号链接（`/tmp/link/bin`，`/tmp/link` → 业务库）同样被跳过。
#      ①② 同一个修法：解析不出条目本身时**一路向上找到第一个能进去的祖先**再做包含判断。
#   ③ 业务库 `cd -P` 失败时旧实现继续用原字符串比较，于是每一条包含判断都不成立 = 整道门失效。现在拒绝运行
#      （REVIEW_REPO_DIR 解析不出来，评审本来也跑不完，早失败比带着失效的门往下跑好）。
#   ④ `repo=/` 时 `"$phys" == "$repo"/*` 实际是 `//*`，匹配不到 `/usr/bin`——每个条目都放行（复现：
#      `REVIEW_REPO_DIR=/` 下假 jq 在「不是 git 仓库」那条校验之前就跑了）。现在显式拒绝根目录。
#   另外 `local CDPATH=''`：`cd` 的**相对**参数会走 CDPATH，`CDPATH=<别处>` 能让 `cd -- "$repo"` 落到别的目录，
#      而且命中 CDPATH 时 `cd` 会多打一行路径，把 `$(cd … && pwd -P)` 的取值变成两行 → 包含判断全部不成立。
#      赋值语句不可被顶替，所以这一行是最便宜的收口（bash ≥4.4 的 `-p` 也会忽略 CDPATH，bash 3.2 不会）。
#
# 启动环境（第四轮复审 P0）：
#   非交互 bash 在读取目标脚本**之前**会处理 `$BASH_ENV`（相对路径按 cwd 解析，而 cwd 就是业务库），
#   并且会从环境导入 exported functions——后者能顶替本文件依赖的 `cd`/`pwd`，也能顶替入口脚本里的
#   `source`，甚至直接定义一个空的 `review_path_gate_or_die` 把整道门变成空转（本机全部复现）。
#   也就是说「函数体只用 builtin」不等于安全：**按名字调用 builtin 不强制调用 builtin**（默认模式下
#   函数查找先于 builtin，`source` / `.` / `declare` / `cd` / `pwd` / `echo` / `exit` 都能被顶替）。
#   真正的收口在启动方：参考 YAML 用 `/bin/bash -p`——privileged 模式下 bash 不处理 BASH_ENV/ENV、
#   不从环境导入函数（本机实测）。入口脚本里那段 best-effort 检查（`builtin declare -F` 非空 = 有继承来的
#   函数，BASH_ENV/ENV 非空 = 启动环境已被污染）是纵深，不是边界：唯一顶不住的形态是环境里导出了一个名叫
#   `builtin` 的函数（实测能让 `builtin declare -F` 返回空）。它仍有独立价值——`-p` 只管当前进程，而脚本里
#   `curl … | bash` 拉起的**子** shell 不是 privileged 的，所以入口脚本还要把 BASH_ENV/ENV 从环境里删掉。
#
# 失败时直接退出（评审侧退 1，探测侧由调用方指定 5——见 review_path_gate_or_die 的 $3/$4，issue 14）
# 而不是回写 MR 评论：回写要跑 curl 与 jq，而这道门的前提正是「PATH 上的工具不可信」——
# 为了发一条评论去执行可能被顶替的二进制，方向是反的。所以这类失败只表现为流水线标红（与脚本里别的
# 「定位到 MR 之前」的失败一致），setup-guide 第 7 节把「PATH 全绝对且不指向业务库」「启动环境不来自业务库」
# 写成了执行器接入要求。
#
# 这道门只保证**调用它的那一刻** PATH 可信。PATH 是可变命名空间：脚本后面任何一次改写 PATH（第 2 步安装
# kiro-cli 后会往前面插 `$HOME/.local/bin`）都必须**重新过门**（第四轮复审 P1；HOME 相对 / HOME 指向业务库
# 都会在那里被拦住）。

# review_path_gate_or_die [<业务库目录>] [<时点说明>] [<退出码>] [<日志前缀>]
#   不传参数时取 ${REVIEW_REPO_DIR:-$PWD}。只用 builtin。改写 PATH 之后要再调一次。
#
# $3 / $4 是给**探测脚本**用的（issue 14）：门原先把 `exit 1` 写死，而探测脚本自己的退出码分级里
# **1 的语义是「门禁用例 FAIL（allowedPaths 不是边界 / deny 未生效 / `../` 越界未被拒），不得上线」**。
# 于是 CI 检出目录里只要 PATH 含 `node_modules/.bin`、`.venv/bin` 或一个空条目，探测就以 1 退出，
# 自动化会把一个**PATH 配置问题**判成**读取边界破了 + 告警**（2026-09-18 两种形态都本机实测复现过）。
# 探测因此传 `5`（它的分级表里 5 = 环境准备失败，PATH 不可信正属于这一类）与前缀 `[probe]`。
# **刻意不把函数里的 1 直接改成 5**：那会静默改掉评审侧的退出码语义。评审侧不传这两个参数、行为完全不变。
review_path_gate_or_die() {
  local repo="${1:-${REVIEW_REPO_DIR:-$PWD}}"
  # $2 = 这一次调用的时点说明，进所有拒绝文案的括号里。默认是第 0 步那次（第一个外部命令之前）；
  # 第 2 步改写 PATH 之后那次会传别的值——同一句「未执行任何外部命令」在那里已经不成立。
  local ctx="${2:-未执行任何外部命令}"
  local rc="${3:-1}" tag="${4:-kiro-review}"
  local rest entry probe phys bad="" skipped=0 n=0
  local CDPATH=''   # `cd` 的相对参数会走 CDPATH：不清掉它，下面解析业务库的那次 cd 可能落到别处（见顶部说明）

  if [[ -z "${PATH-}" ]]; then
    echo "[${tag}] 错误：PATH 未设置或为空，拒绝运行：脚本要在不受信的业务仓库目录下执行 git / jq 等外部命令，PATH 必须是一组可信的绝对路径。请检查执行器配置" >&2
    exit "$rc"
  fi
  # 业务库的物理路径（cd / pwd 都是 builtin）。解析不出来就**拒绝运行**：旧实现在这里回退原字符串，
  # 于是下面每一条「落在业务库内」的比较都不成立 = 整道门 fail-open（第四轮复审 P1 ③）。
  if ! phys=$(cd -P -- "$repo" 2>/dev/null && pwd -P); then
    echo "[${tag}] 错误：业务仓库目录解析不出物理路径（不存在 / 进不去 / 不是目录），拒绝运行（${ctx}）：[${repo:0:200}]。这道门要靠业务库的物理路径判断 PATH 条目是否落在业务库内，解析不出来就无法判断——请检查 REVIEW_REPO_DIR（setup-guide 第 5.1 节）" >&2
    exit "$rc"
  fi
  repo="$phys"
  # 根目录要显式拒绝：`"$phys" == "$repo"/*` 在 repo=/ 时是 `//*`，匹配不到 `/usr/bin`，于是每个条目都放行
  # （第四轮复审 P1 ④）。语义上 repo=/ 时「不在业务库内的可信目录」根本不存在，只能拒绝。
  if [[ "$repo" == "/" ]]; then
    echo "[${tag}] 错误：业务仓库目录解析成根目录 /，拒绝运行（${ctx}）：那样每一个 PATH 条目都落在「业务仓库内」，不存在可信的 PATH。请把 REVIEW_REPO_DIR 指向业务库 checkout 目录（setup-guide 第 5.1 节）" >&2
    exit "$rc"
  fi

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
    # 物理解析。条目自己进不去时**一路向上找第一个能进去的祖先**再判断（P1 ①②）：
    #   · `<业务库>/future-bin` 目录还不存在 → 祖先是业务库 → 拒绝（旧实现走「不存在 → 跳过」，而门是时点
    #     判断：目录在门之后出现——并发运行 / 外部 re-checkout / 符号链接改指向——就立刻是有效 PATH 入口）；
    #   · `/tmp/link/bin` 末段不存在、`/tmp/link` 是指进业务库的符号链接 → 祖先解析到业务库 → 拒绝。
    # 祖先判断**包含**了「字面落在业务库内」那一类（字面在业务库内的条目，第一个能进去的祖先必然在业务库内
    # 或就是业务库；业务库自己进不去的情况上面已经拒绝了），所以不再额外做字面前缀比较——
    # `<业务库>/../tools/bin` 这种字面在业务库内、物理在业务库外的写法不该被误伤。
    probe="$entry"; phys=""
    while :; do
      if phys=$(cd -P -- "$probe" 2>/dev/null && pwd -P); then break; fi
      phys=""
      [[ "$probe" != "/" ]] || break                      # 连根都进不去：这台机器上什么都跑不了
      probe="${probe%/*}"; [[ -n "$probe" ]] || probe="/"
    done
    if [[ -z "$phys" ]]; then
      skipped=$((skipped + 1)); continue                   # 整条路径链都进不去：拿不出可执行文件
    fi
    if [[ "$phys" == "$repo" || "$phys" == "$repo"/* ]]; then
      bad="${bad}${bad:+, }第${n}项[${entry:0:40}]（解析到业务库内：${phys:0:60}）"; continue
    fi
    [[ "$probe" == "$entry" ]] || skipped=$((skipped + 1)) # 条目本身不存在，但祖先在业务库外：跳过并计数
  done

  if [[ -n "$bad" ]]; then
    echo "[${tag}] 错误：执行器的 PATH 不可信，拒绝运行（${ctx}）。本脚本会在**不受信的业务仓库**目录下运行 git / jq / tr / curl 等外部工具，PATH 决定这些名字解析到哪个文件：空条目与相对条目等于当前目录，指向业务仓库的条目等于让 MR 作者提供这些工具。请把 PATH 改成一组不在业务仓库内的绝对路径（setup-guide 第 7 节）。可疑条目：${bad}" >&2
    exit "$rc"
  fi
  [[ "$skipped" == "0" ]] \
    || echo "[${tag}] PATH 里有 ${skipped} 个不存在或进不去的绝对条目（跳过，它们拿不出可执行文件）" >&2
  return 0
}

# review_dir_not_in_repo_or_die <待检路径> <业务库目录> [<时点说明>]
#   在**运行 curl / 安装器之前**用它挡住「$HOME 落在业务库内」（CodeX 2026-09-13 第六轮复审 P0），
#   钉版档位还用它挡「安装包路径取自业务库」（不变式 I6）。待检路径可以是目录也可以是文件。
#   为什么不能只靠第 2 步那次 PATH 重新过门：curl 会读 `$HOME/.curlrc`、安装器会写 `$HOME/.local/bin`，
#   两者都发生在那次过门**之前**——业务库里提交一个 `.curlrc`（`url = "file://<业务库>/evil.sh"`）就能让 curl
#   先把业务库脚本打到 stdout，与受信安装脚本一起被右侧 bash 执行（本机 curl 8.7 复现：marker=EVIL_RAN）。
#   env -i 与 `-p` 都挡不住它，因为注入发生在 curl 左侧、在它们之前。所以 HOME 的可信性必须在 curl 之前定。
#   判据与 review_path_gate_or_die 的单条一致：相对 / 空 / 物理祖先落在业务库内 → 拒绝。只用 builtin。
#   多一条（CodeX 2026-09-16 复审 R2）：**待检路径自己 `cd -P` 进不去、而它是符号链接 → 拒绝**。
#   只用 builtin 读不出链接目标（bash 没有 readlink 这类 builtin），于是「最近的能进去的祖先」会退到
#   链接**所在的目录**——库外的一个链接指向业务库里的文件时，祖先在库外，整类形态就被放过去了。
#   目录形态的链接不受影响：`cd -P` 对它成功，上一步已经把它解析成物理路径。
review_dir_not_in_repo_or_die() {
  local cand="$1" repo="$2" ctx="${3:-未执行任何外部命令}"
  local probe phys
  local CDPATH=''
  # 这个 helper 在**掩码库加载之前**就可能拒绝，而 `cand`（通常是 $HOME）与 `repo` 都是不受信的环境取值。
  # 所以三类拒绝**只报状态、不回显取值**（CodeX 2026-09-13 第六轮复审 P1，与第五轮 BASH_ENV/ENV 同一根因）：
  # 原样进流水线日志既是泄露面（令牌形状的 HOME 会整串进日志），也是日志注入面（可含换行 / 终端控制字符）。
  # `ctx` 只由调用方用固定文案填，不含环境取值。要查具体取值请在执行器上自己看环境。
  if [[ -z "$cand" ]]; then
    echo "[kiro-review] 错误：${ctx}——待检目录为空，拒绝运行" >&2; exit 1
  fi
  if ! phys=$(cd -P -- "$repo" 2>/dev/null && pwd -P); then
    echo "[kiro-review] 错误：${ctx}——业务仓库目录解析不出物理路径，拒绝运行" >&2; exit 1
  fi
  repo="$phys"
  if [[ "$repo" == "/" ]]; then
    echo "[kiro-review] 错误：${ctx}——业务仓库目录解析成根目录 /，拒绝运行" >&2; exit 1
  fi
  if [[ "$cand" != /* ]]; then
    echo "[kiro-review] 错误：${ctx}——待检目录不是绝对路径（相对路径 = 当前目录 = 业务库；取值不打印，见 setup-guide 第 7 节），拒绝运行" >&2; exit 1
  fi
  # 与 PATH 门同款「最近的能进去的祖先」解析：末段不存在（`.local/bin` 还没建）、或父目录是指进业务库的符号链接都拦得住
  probe="$cand"; phys=""
  while :; do
    if phys=$(cd -P -- "$probe" 2>/dev/null && pwd -P); then break; fi
    phys=""
    # 进不去、而它自己是符号链接：祖先回退在这里会失真（见函数头 R2），只能拒绝。链接环、断链、
    # 指向文件的链接（钉版安装包就是文件）都落在这一条上。检查放在 cd 失败之后：指向目录的链接
    # 已经在上一行被 `cd -P` 解析成物理路径了，不会误伤 `$HOME` 是目录链接这种正常形态。
    if [[ -L "$probe" ]]; then
      echo "[kiro-review] 错误：${ctx}——待检路径本身是符号链接（进不去、且只用 builtin 解不出链接目标，无法判断它是否指进业务库；取值不打印）。请把它指到业务仓库之外的**物理**路径（setup-guide 第 7 节），拒绝运行" >&2
      exit 1
    fi
    [[ "$probe" != "/" ]] || break
    probe="${probe%/*}"; [[ -n "$probe" ]] || probe="/"
  done
  if [[ -n "$phys" && ( "$phys" == "$repo" || "$phys" == "$repo"/* ) ]]; then
    echo "[kiro-review] 错误：${ctx}——待检目录解析到业务库内（取值不打印）。请把它指到业务仓库之外（setup-guide 第 7 节），拒绝运行" >&2
    exit 1
  fi
  return 0
}
