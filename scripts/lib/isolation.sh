#!/usr/bin/env bash
# 工作区隔离：在业务库 checkout（cwd）里一次遍历删除 Kiro 会自动读取 / 可被借道的注入面，Kiro 启动之前执行。
# 这是**第二道**（15-fix4 #1）：第一道是五处 kiro-cli 调用都在 $WORK/cwd 空目录下运行，业务库从来不是 kiro-cli 的 cwd——
# 它相对 cwd 发现的每一个面（.kiro/agents 顶替、.kiro/settings/cli.json 覆盖全局设置、AGENTS.md steering、lsp.json）都落在没有文件的目录里。
# 删除仍做：业务库在 allowedPaths 里，这些文件被 kiro-cli 按别的途径发现时（未来版本、v3 子目录 steering）仍不该在。
#
# 删什么、为什么（票 02 / R10 / 票 15 / 15-fix2 #10 #15 / 15-fix3 #1 #2）——四个类别（class）：
#   · agents：AGENTS.md（任意深度、大小写不敏感、非目录）：V3 把子目录 AGENTS.md 也当 steering；大小写不敏感文件系统上 agents.md 同样会被读到
#   · kiro：.kiro（任意深度；目录、**符号链接**或普通文件，大小写不敏感——macOS/Windows 执行器上 `.Kiro/` 按 `.kiro/` 读到）：
#     MCP/hooks/steering/agents/settings。`.kiro/settings/cli.json` 会覆盖全局设置、`.kiro/agents/codeup-reviewer.json` 会顶替
#     受信 agent（kiro-cli 2.21 实测）——第一道（空 cwd）已让这两条相对 cwd 的发现失效，这里是第二道
#   · lsp：根 `lsp.json`，**任何类型**（文件、目录、符号链接都归这一类，15-fix4 #6 / B7：符号链接形态的根 lsp.json 以前落进符号链接桶，
#     日志却写「根 lsp.json（0 个）」）。只删根目录那一份：kiro-cli 只从 cwd 读 lsp.json 是我们的理解，嵌套的会不会被读**未验证**——
#     第一道（空 cwd）让这个问题不必单独追
#   · links：其余任意深度的符号链接（含指向目录的、悬空的）：`payload -> /root/.aws/credentials` 的请求路径字面上在 allowedPaths 之内，
#     kiro-cli 是否先解析再比对是它的实现细节（探测 P1-15 T8 记录事实，生产不依赖它）
# 不碰的：**工作树自己的** `.git`——顶层 `./.git`（不论类型）与任何**不在被删目录内部**的 `.git` 目录（`-name .git -type d -prune`：
#   嵌套子模块、vendored clone、fixture 仓库的 .git 内部不进、不报）。被删目录（`.kiro/`、目录形态的根 `lsp.json/`）内部的一切随目录
#   一起删，其中嵌套的 `.git` 不是例外（它不是工作树的版本库；`.kiro -> .git` 这类符号链接 rm -rf 只删链接本身）——15-fix4 #6 / E4。
#   旧写法 `-path ./.git -prune` 只剪根目录那一份；`-not -path './.git/*'` 是过滤不是剪枝，会 stat 整个 .git。
# 一次遍历：四类匹配用 `-o` 串在同一条 find 里，`.kiro` / `.git` / 根 lsp.json 命中即 `-prune` 不再下钻。
# 用 -exec 而不是 -delete：-delete 隐含 -depth，而 -depth 下 -prune 失效。
# diff 已从 git 对象算好并写入 $WORK，删工作树文件不影响评审输入（这些文件的**改动本身**在 diff 里照样可见、照样被评审）。
#
# 单一发射器（15-fix4 #6）：review_isolation_scan 是**唯一**一份谓词——生产的 review_isolate_workspace 与测试的 tests/helpers.sh
# injection_surface_scan（替身 kiro-cli 启动时扫描残留、端到端断言「工作区干净」）都转调它。以前两份 find 表达式各写一遍，本票内就分叉过一次。
#
# 用法：
#   review_isolation_scan                      在业务库根目录下调用；对每个命中输出 `class<TAB>path<NUL>`（不删除）。find 的 stdout 只留给
#                                              这一个发射器：计数在 bash 侧从 NUL 流算出，任何往 stdout 写字节的 -exec 都打不坏计数（C4b）。
#   review_isolate_workspace <removed-list>    在业务库根目录下调用。先把发射器的 NUL 流**原样写进** <removed-list>（`class<TAB>path<NUL>`，
#                                              这是「不受信业务库删了什么」的唯一记录——先持久化再删），再逐条删除、按 class 计数；
#                                              stdout 打四个计数「<agents> <kiro> <links> <lsp>」；扫描、写清单、任一条删除失败都返回非零。
review_isolation_scan() {
  # shellcheck disable=SC2016  # 单引号里的 $@ 是给 sh -c 的
  find . \( -path ./.git -o \( -name .git -type d \) \) -prune \
       -o -path ./lsp.json -prune -exec sh -c 'for p in "$@"; do printf "lsp\t%s\0" "$p"; done' _ {} + \
       -o -iname .kiro -prune -exec sh -c 'for p in "$@"; do printf "kiro\t%s\0" "$p"; done' _ {} + \
       -o \( -iname AGENTS.md -not -type d \) -exec sh -c 'for p in "$@"; do printf "agents\t%s\0" "$p"; done' _ {} + \
       -o -type l -exec sh -c 'for p in "$@"; do printf "links\t%s\0" "$p"; done' _ {} + \
       -o -false
  # 末尾的 `-o -false` 是语法占位：四个类别各占一行、任一行被变异测试删掉后 find 表达式仍合法（BSD / GNU find 都有 -false）
}
review_isolate_workspace() {
  local out="$1" cls path n_agents=0 n_kiro=0 n_links=0 n_lsp=0
  # ① 扫描（不删）——发射器的 stdout 直接落到清单文件；find 失败即返回非零，清单可能不完整、此时一个文件都不删
  review_isolation_scan > "$out" || return 1
  # ② 逐条删除、按 class 计数。任一条删不掉返回非零：清单里已经写了它，调用方按失败处理（不启动 Kiro）
  # 整条记录读入再按**第一个**制表符切分：`IFS=$'\t' read cls path` 会把 path 末尾的制表符当分隔符剥掉，名字以 \t 结尾的
  # 符号链接就被计数、进清单、却 rm 了一个不存在的路径（合并后复审第 2 条）。class 本身没有制表符，所以首个制表符就是边界。
  local rec
  while IFS= read -r -d '' rec; do
    cls=${rec%%$'\t'*}; path=${rec#*$'\t'}
    case "$cls" in
      agents) rm -f "$path" || return 1; n_agents=$((n_agents + 1)) ;;
      kiro)   rm -rf "$path" || return 1; n_kiro=$((n_kiro + 1)) ;;
      links)  rm -f "$path" || return 1; n_links=$((n_links + 1)) ;;
      lsp)    rm -rf "$path" || return 1; n_lsp=$((n_lsp + 1)) ;;
      *) echo "review_isolate_workspace: 清单里出现未知类别 [${cls}]（集成包缺陷）" >&2; return 1 ;;
    esac
  done < "$out"
  printf '%d %d %d %d\n' "$n_agents" "$n_kiro" "$n_links" "$n_lsp"
}


# ── review_copy_to_root（V3 评审根目录，ADR-0008 / Q21 H5 布局）────────────────────────────────
# 把业务库工作树复制到 <评审根目录>/repo（不含任意深度的 .git），再核对两边的条目清单逐字节相同。
# 必须在 review_isolate_workspace（第 5.5 步）之后调用：复制的是**已隔离**的工作树（AGENTS.md / .kiro / 符号链接已删）。
# Kiro 的 cwd 是评审根目录（集成包新建、里面只有 repo/），所以 V3 能搜索整个业务库，而工作区根目录上那些会被自动加载的面
# （根 AGENTS.md、.kiro/steering、.kiro/hooks、.kiro/agents）都不在业务库手里（S9 实测）。
# 用法：review_copy_to_root <业务库目录> <评审根目录> → stdout 条目数；rc 0 = 复制并核对通过；rc 1 = 失败（原因进 stderr）
_review_copy_list() {   # <目录> → stdout：相对路径清单（NUL 分隔、排序），跳过任意深度名为 .git 的条目
  ( cd "$1" && LC_ALL=C find . -name .git -prune -o -print0 | LC_ALL=C sort -z )
}
review_copy_to_root() {
  local src="${1-}" root="${2-}" dst
  [[ -d "$src" ]] || { echo "review_copy_to_root: 业务库目录不存在：${src}" >&2; return 1; }
  [[ -d "$root" ]] || { echo "review_copy_to_root: 评审根目录不存在：${root}" >&2; return 1; }
  dst="$root/repo"
  [[ ! -e "$dst" && ! -L "$dst" ]] || { echo "review_copy_to_root: ${dst} 已存在（评审根目录必须是本次新建的空目录）" >&2; return 1; }
  mkdir "$dst" || { echo "review_copy_to_root: 无法创建 ${dst}" >&2; return 1; }
  # 失败时当场删掉半个副本，不等退出 trap：磁盘写满时失败评论也渲染在同一个 TMPDIR 里，半个副本占着空间，评论可能写不出来（复审 I-4）
  _review_copy_fill "$src" "$dst" || { rm -rf "$dst"; return 1; }
}
_review_copy_fill() {   # <业务库目录> <副本目录（已建好的空目录）> → stdout 条目数；rc 1 = 失败（原因进 stderr）
  local src="$1" dst="$2"
  # 子 shell 里自己开 pipefail：打包与解包任一端失败都算失败，不依赖调用方的 shell 选项。
  # --exclude=.git 在 GNU tar 与 bsdtar 下都按任意一段路径名匹配（子模块的 .git 文件也排除）。
  ( set -o pipefail; ( cd "$src" && LC_ALL=C tar --exclude=.git -cf - . ) | ( cd "$dst" && LC_ALL=C tar -xf - ) ) \
    || { echo "review_copy_to_root: tar 复制失败（打包或解包出错；磁盘满、权限或文件名问题？）" >&2; return 1; }
  # 核对：业务库里的每个条目在副本里都在，且两边条目数相同。不逐字节比较两份清单：macOS 上 bsdtar 解包会把非 ASCII 文件名
  # 换成另一种 Unicode 规范形式（APFS 查找时不区分，字节却不同，本机实测），逐字节比较会把正常的副本判成不一致。
  local e n_src=0 n_dst
  while IFS= read -r -d '' e; do
    [[ -e "$dst/$e" || -L "$dst/$e" ]] || { echo "review_copy_to_root: 副本里缺少业务库的条目（磁盘满、权限或文件名问题？）" >&2; return 1; }
    n_src=$((n_src + 1))
  done < <(_review_copy_list "$src")
  n_dst=$(_review_copy_list "$dst" | tr -dc '\0' | wc -c | tr -d ' ')
  [[ "$n_src" == "$n_dst" ]] || { echo "review_copy_to_root: 副本条目数（${n_dst}）与业务库（${n_src}）不一致" >&2; return 1; }
  printf '%s' "$n_dst"
}
