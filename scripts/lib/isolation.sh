#!/usr/bin/env bash
# 工作区隔离：在业务库 checkout（cwd）里一次遍历删除 Kiro 会自动读取 / 可被借道的注入面，Kiro 启动之前执行。
#
# 删什么、为什么（票 02 / R10 / 票 15 / 15-fix2 #10 #15）：
#   · AGENTS.md（任意深度、大小写不敏感）：V3 把子目录 AGENTS.md 也当 steering；大小写不敏感文件系统上 agents.md 同样会被读到
#   · .kiro（任意深度；目录、**符号链接**或普通文件，大小写不敏感——macOS/Windows 执行器上 `.Kiro/` 按 `.kiro/` 读到）：
#     MCP/hooks/steering/agents/settings。`.kiro/settings/cli.json` 会覆盖全局设置、`.kiro/agents/codeup-reviewer.json` 会顶替
#     受信 agent（kiro-cli 2.21 实测），所以删它是后两道措施可信的前提
#   · 符号链接（任意深度，含指向目录的、悬空的）：`payload -> /root/.aws/credentials` 的请求路径字面上在 allowedPaths 之内，
#     kiro-cli 是否先解析再比对是它的实现细节（探测 P1-15 T8 记录事实，生产不依赖它）
#   · 根 lsp.json（文件或同名目录：rm -f 遇目录会失败，让 MR 作者能用一个目录名卡死评审）
# 不碰的：**任意深度**的 `.git` 目录（`-name .git -type d -prune`），以及根 `./.git` 不论类型。旧写法 `-path ./.git -prune`
#   只剪根目录那一份，嵌套 `.git`（旧式子模块、vendored clone、fixture 仓库）内部的符号链接会被删掉；而
#   `-not -path './.git/*'` 是过滤不是剪枝，会 stat 整个 .git。
# 一次遍历：三类匹配用 `-o` 串在同一条 find 里，`.kiro` 与 `.git` 命中即 `-prune` 不再下钻。
# 用 -exec rm 而不是 -delete：-delete 隐含 -depth，而 -depth 下 -prune 失效。
# diff 已从 git 对象算好并写入 $WORK，删工作树文件不影响评审输入（这些文件的**改动本身**在 diff 里照样可见、照样被评审）。
#
# 与测试的关系：tests/helpers.sh 的 injection_surface_scan 是同一条谓词的**枚举版**（替身 kiro-cli 启动时扫描残留、测试断言
# 「工作区干净」都用它）。两份谓词必须等价——test-kiro-review.sh 在含嵌套 .git / .git 符号链接 / 多层 AGENTS.md / .kiro 链接的
# 合成树上断言「本函数实际删除的集合 == 枚举版列出的集合」。改一处必须改另一处。
#
# 用法：review_isolate_workspace <removed-list-file>   （在业务库根目录下调用）
#   删除的每个路径写一行到列表文件；stdout 打四个计数「<AGENTS.md 数> <.kiro 数> <符号链接数> <lsp.json 数>」；任一步失败返回非零。
#   分类由 find 在**匹配时**决定：每个分支用 `-exec sh -c … {} +` 把路径追加到各自的 <list>.agents / .kiro / .links，并把每批的
#   条数记进 <list>.<类>.n——不按路径字符串回头重分类（路径含换行会被算两次、符号链接的根 lsp.json 会被算成 lsp；15-fix3 #10）。
#   不用 GNU 的 -fprint：macOS/BSD find 没有它，测试跑不起来。列表文件是三份的拼接 + 根 lsp.json 一行。
review_isolate_workspace() {
  local out="$1" f n_agents n_kiro n_links n_lsp=0
  for f in "$out" "$out.agents" "$out.agents.n" "$out.kiro" "$out.kiro.n" "$out.links" "$out.links.n"; do : > "$f" || return 1; done
  # shellcheck disable=SC2016  # 单引号里的 $0/$@ 是给 sh -c 的
  find . \( -path ./.git -o \( -name .git -type d \) \) -prune \
       -o -iname .kiro -prune -exec sh -c 'printf "%s\n" "$@" >> "$0"; echo "$#" >> "$0.n"' "$out.kiro" {} + -exec rm -rf {} + \
       -o \( -iname AGENTS.md -not -type d \) -exec sh -c 'printf "%s\n" "$@" >> "$0"; echo "$#" >> "$0.n"' "$out.agents" {} + -exec rm -f {} + \
       -o -type l -exec sh -c 'printf "%s\n" "$@" >> "$0"; echo "$#" >> "$0.n"' "$out.links" {} + -exec rm -f {} + \
       || return 1
  # 符号链接形态的根 lsp.json 已在上面按符号链接删掉；这里只剩普通文件 / 同名目录
  if [[ -e ./lsp.json || -L ./lsp.json ]]; then
    rm -rf ./lsp.json || return 1
    n_lsp=1
  fi
  cat "$out.agents" "$out.kiro" "$out.links" > "$out" || return 1
  [[ "$n_lsp" == "1" ]] && echo "./lsp.json" >> "$out"
  n_agents=$(awk '{s+=$1} END{print s+0}' "$out.agents.n"); n_kiro=$(awk '{s+=$1} END{print s+0}' "$out.kiro.n"); n_links=$(awk '{s+=$1} END{print s+0}' "$out.links.n")
  printf '%d %d %d %d\n' "$n_agents" "$n_kiro" "$n_links" "$n_lsp"
}
