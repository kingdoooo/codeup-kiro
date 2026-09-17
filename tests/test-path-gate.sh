#!/usr/bin/env bash
# scripts/lib/path-gate.sh 的单元测试（CodeX 2026-09-13 第四轮复审 P1）。
#
# 分工：test-kiro-review.sh 的 e2e 用例证明「门装在脚本第 0 步、在第一个外部命令之前」；本文件测**判据本身**，
# 覆盖 e2e 造不出或造起来很贵的形态：改写 PATH 之后重新过门、业务库目录解析不出物理路径、业务库解析成 `/`、
# 业务库里**还不存在**的 PATH 条目、经符号链接指进业务库的条目、待检路径自己是符号链接（含相对目标 / 链式 /
# 断链 / 链接环，CodeX 2026-09-16 复审 R2）。
# 门用 `exit 1` 而不是 return，所以每次调用都放在子 shell 里。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
GATE="$(cd .. && pwd)/scripts/lib/path-gate.sh"

# 物理路径：macOS 的 mktemp -d 给的是 /var/... 而 /var 是指向 /private/var 的符号链接。
# 门比较的是物理路径，夹具这边也统一用物理路径，否则「字面 vs 物理」两类断言在两个平台上结论不同。
tmp=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$tmp"' EXIT
repo="$tmp/business-repo"; mkdir -p "$repo/bin"
outside="$tmp/outside-bin"; mkdir -p "$outside"
SAFE="/usr/bin:/bin"

# gate <PATH 取值> <业务库目录> → stdout 收到门的 stderr，RC 是门的退出码
gate() {
  local p="$1" r="$2"
  RC=0
  OUT=$( ( set -euo pipefail; PATH="$p"; export PATH; source "$GATE"; review_path_gate_or_die "$r" ) 2>&1 ) || RC=$?
}

# ---- 正控：干净 PATH 放行，且不打任何东西 ----
gate "$SAFE:$outside" "$repo"
assert_rc "$RC" 0 "干净 PATH（全绝对、都在业务库外）→ 放行"
assert_eq "$OUT" "" "干净 PATH：门一句话都不打"

# ---- 既有判据（回归）----
gate "" "$repo";              assert_nonzero "$RC" "PATH 为空 → 拒绝"
assert_contains "$OUT" "PATH 未设置或为空" "PATH 为空：报错点明"
gate "$SAFE:" "$repo";        assert_nonzero "$RC" "尾随空条目 → 拒绝"
assert_contains "$OUT" "空条目=当前目录" "尾随空条目：报错点明"
gate "relbin:$SAFE" "$repo";  assert_nonzero "$RC" "相对条目 → 拒绝"
assert_contains "$OUT" "（相对路径）" "相对条目：报错点明"
gate "$repo/bin:$SAFE" "$repo"; assert_nonzero "$RC" "业务库内的已存在目录 → 拒绝"
assert_contains "$OUT" "解析到业务库内" "业务库内目录：报错点明"
gate "$repo:$SAFE" "$repo";   assert_nonzero "$RC" "条目就是业务库自己 → 拒绝"

# ---- P1 ①：业务库里**还不存在**的目录 ----
# 旧实现：cd 失败 → 「不存在 → 跳过」→ 门放行。门是时点判断，目录在门之后出现（常驻执行器上的并发运行、
# 外部重新 checkout、符号链接改指向）就立刻是有效 PATH 入口——所以「此刻不存在」不能当成「拿不出可执行文件」。
[[ ! -e "$repo/future-bin" ]] || { echo "FAIL: 夹具错误，future-bin 不该存在" >&2; exit 1; }
gate "$repo/future-bin:$SAFE" "$repo"
assert_nonzero "$RC" "P1①：业务库里还不存在的目录 → 拒绝（不走「不存在就跳过」）"
assert_contains "$OUT" "解析到业务库内" "P1①：报错点明它落在业务库里（按最近的能进去的祖先判断）"
# 正控：业务库**外**、同样不存在的目录仍然只跳过并计数（真实执行器上 /opt/homebrew/sbin 这类很常见）
gate "$SAFE:$tmp/no-such-outside-$$" "$repo"
assert_rc "$RC" 0 "P1①正控：业务库外不存在的绝对条目仍然放行（不误伤真实执行器）"
assert_contains "$OUT" "1 个不存在或进不去的绝对条目" "P1①正控：跳过的条目要计数并打日志"

# ---- P1 ②：末段不存在、父目录是指进业务库的符号链接 ----
ln -s "$repo" "$tmp/link-to-repo"
gate "$tmp/link-to-repo/late-bin:$SAFE" "$repo"
assert_nonzero "$RC" "P1②：末段不存在 + 父目录符号链接指进业务库 → 拒绝"
assert_contains "$OUT" "解析到业务库内" "P1②：报错点明祖先解析到业务库"
gate "$tmp/link-to-repo/bin:$SAFE" "$repo"
assert_nonzero "$RC" "P1②：符号链接 + 已存在的业务库子目录 → 拒绝"
# 反向正控：字面在业务库内、物理在业务库外（`<业务库>/../outside-bin`）不该被误伤——
# 这就是不用「字面前缀比较」而用「最近的能进去的祖先」的原因。
gate "$repo/../outside-bin:$SAFE" "$repo"
assert_rc "$RC" 0 "P1②反向正控：字面在业务库内、物理在业务库外的条目不误伤"

# ---- P1 ③：业务库目录解析不出物理路径 → 拒绝（旧实现回退原字符串 = 整道门失效）----
gate "$repo/bin:$SAFE" "$tmp/no-such-repo-$$"
assert_nonzero "$RC" "P1③：业务库目录不存在 → 拒绝运行"
assert_contains "$OUT" "业务仓库目录解析不出物理路径" "P1③：报错点明是业务库目录解析不出来"
assert_not_contains "$OUT" "PATH 不可信" "P1③：报的是业务库目录那条，不是含糊的 PATH 报错"
gate "$repo/bin:$SAFE" "relative-repo"
assert_nonzero "$RC" "P1③：业务库目录是不存在的相对路径 → 拒绝"

# ---- P1 ④：业务库解析成 `/` → 拒绝（`"$phys" == "$repo"/*` 在 repo=/ 时是 `//*`，谁都匹配不上）----
gate "$SAFE:$outside" "/"
assert_nonzero "$RC" "P1④：业务库解析成根目录 → 拒绝运行"
assert_contains "$OUT" "解析成根目录" "P1④：报错点明根目录"
# 同一形态的旧行为：repo=/ 时连 /usr/bin 都被判成「业务库外」，于是任何假工具都能进 PATH。
# 这条断言就是那个 fail-open 的反面——现在整道门在根目录上直接拒绝，不再逐条放行。
gate "$tmp/fake-bin:$SAFE" "/"
assert_nonzero "$RC" "P1④：repo=/ 时任何 PATH 都拒绝（旧实现会逐条放行）"

# ---- P1（另一条）：门只保证「调用它那一刻」的 PATH，改写 PATH 之后要重新过门 ----
# 主脚本第 2 步安装完 kiro-cli 会 `export PATH="$HOME/.local/bin:$PATH"`。三种 HOME 形态在**重新过门**时被拦住：
gate "$repo/.local/bin:$SAFE" "$repo"
assert_nonzero "$RC" "改写后重过门：HOME 指向业务库 → 新条目落在业务库内 → 拒绝"
gate "./.local/bin:$SAFE" "$repo"
assert_nonzero "$RC" "改写后重过门：HOME 是相对路径（HOME=.）→ 新条目是相对条目 → 拒绝"
assert_contains "$OUT" "（相对路径）" "改写后重过门：HOME=. 报的是相对条目"
gate "/.local/bin:$SAFE" "$repo"
assert_rc "$RC" 0 "改写后重过门：HOME 未设置（条目 /.local/bin）不在业务库内 → 放行"
# $2 = 时点说明进拒绝文案：第 2 步那次调用不能再说「未执行任何外部命令」（那时 curl 已经跑过了）
RC=0
OUT=$( ( set -euo pipefail; PATH="$repo/bin:$SAFE"; export PATH; source "$GATE"
         review_path_gate_or_die "$repo" "PATH 在安装 kiro-cli 之后被改写，kiro-cli 尚未执行" ) 2>&1 ) || RC=$?
assert_nonzero "$RC" "第二次调用同样拒绝"
assert_contains "$OUT" "PATH 在安装 kiro-cli 之后被改写" "第二次调用：拒绝文案用调用方给的时点说明"
assert_not_contains "$OUT" "未执行任何外部命令" "第二次调用：不再声称「未执行任何外部命令」"

# ---- CDPATH 不能改变业务库的解析结果 ----
# `cd` 的**相对**参数会走 CDPATH；命中时 cd 还会往 stdout 多打一行路径，把 `$(cd … && pwd -P)` 的取值变成两行，
# 于是下面每一条包含比较都不成立 = fail-open。门里 `local CDPATH=''` 收口（bash 3.2 的 `-p` 不管 CDPATH）。
mkdir -p "$tmp/cdtrap/business-repo"
RC=0
OUT=$( ( set -euo pipefail; PATH="$repo/bin:$SAFE"; export PATH; export CDPATH="$tmp/cdtrap"
         cd "$tmp"; source "$GATE"; review_path_gate_or_die "business-repo" ) 2>&1 ) || RC=$?
assert_nonzero "$RC" "CDPATH 指向别处时，相对的业务库目录仍按 cwd 解析 → 业务库内的条目照样被拒"
assert_contains "$OUT" "解析到业务库内" "CDPATH：报的是「解析到业务库内」，不是被 CDPATH 带偏后的放行"

# ---- review_dir_not_in_repo_or_die（curl 之前的 HOME 检查，第六轮复审 P0/P1）----
# gate2 <待检目录> <业务库目录> → OUT 收 stderr，RC 是退出码；固定 ctx 便于断言
gate2() {
  RC=0
  OUT=$( ( set -euo pipefail; source "$GATE"; review_dir_not_in_repo_or_die "$1" "$2" "安装 kiro-cli 前" ) 2>&1 ) || RC=$?
}
# 正控：HOME 在业务库外 → 放行、不打任何东西
gate2 "$outside" "$repo";        assert_rc "$RC" 0 "HOME 检查：业务库外的绝对目录 → 放行"
assert_eq "$OUT" "" "HOME 检查：放行时一句话都不打"
gate2 "$tmp/no-such-home-$$" "$repo"; assert_rc "$RC" 0 "HOME 检查：业务库外、尚不存在的绝对目录 → 放行（祖先在库外）"
# 相对 HOME → 拒绝，且**取值不回显**（第六轮 P1：cand=$HOME 是不受信环境取值）
gate2 "ghp_SECRETTOKEN1234567890" "$repo"
assert_nonzero "$RC" "HOME 检查：相对 HOME → 拒绝"
assert_contains "$OUT" "不是绝对路径" "HOME 检查：相对 HOME 报「不是绝对路径」"
assert_not_contains "$OUT" "ghp_SECRETTOKEN1234567890" "HOME 检查：相对 HOME 的取值一个字都不进日志（令牌形状 HOME）"
assert_not_contains "$OUT" "ghp_" "HOME 检查：连令牌前缀都不进日志"
# 业务库内、尚不存在的子目录（`.local/bin` 还没建）→ 拒绝（按最近的能进去的祖先判定），取值不回显
gate2 "$repo/.local/bin" "$repo"
assert_nonzero "$RC" "HOME 检查：业务库内还不存在的子目录 → 拒绝"
assert_contains "$OUT" "解析到业务库内" "HOME 检查：报「解析到业务库内」"
assert_not_contains "$OUT" "$repo" "HOME 检查：解析到业务库内时，路径取值不进日志"
# 经符号链接指进业务库 → 拒绝
ln -s "$repo" "$tmp/home-link" 2>/dev/null || true
gate2 "$tmp/home-link/late" "$repo"
assert_nonzero "$RC" "HOME 检查：末段不存在 + 父目录符号链接指进业务库 → 拒绝"
assert_contains "$OUT" "解析到业务库内" "HOME 检查：符号链接指进业务库也报「解析到业务库内」"
# HOME 就是业务库自己 → 拒绝
gate2 "$repo" "$repo";           assert_nonzero "$RC" "HOME 检查：HOME 就是业务库自己 → 拒绝"
# 空 HOME → 拒绝
gate2 "" "$repo";                assert_nonzero "$RC" "HOME 检查：空目录 → 拒绝"
assert_contains "$OUT" "待检目录为空" "HOME 检查：空目录报「待检目录为空」"
# 业务库目录解析不出物理路径 → 拒绝（这条分支只有 helper 有；主 PATH 门在它之前不会被调用，repogone 覆盖不到它），
# 且取值不回显（cand=业务库外的合法目录、repo=不存在的路径，两者都不该进日志）
gate2 "$outside" "$tmp/no-such-repo-$$"
assert_nonzero "$RC" "HOME 检查：业务库目录解析不出物理路径 → 拒绝"
assert_contains "$OUT" "业务仓库目录解析不出物理路径" "HOME 检查：报「业务仓库目录解析不出物理路径」"
assert_not_contains "$OUT" "no-such-repo" "HOME 检查：业务库路径取值不进日志"
assert_not_contains "$OUT" "$outside" "HOME 检查：待检目录取值也不进日志"
# 业务库解析成 / → 拒绝（与 PATH 门同款）
gate2 "$outside" "/";            assert_nonzero "$RC" "HOME 检查：业务库解析成根目录 → 拒绝"

# ---- 待检路径自己是符号链接（CodeX 2026-09-16 复审 R2）----
# 钉版档位把这个 helper 也用在**文件**上（KIRO_PINNED_ARTIFACT）。文件的 `cd -P` 必然失败，于是「最近的能进去的
# 祖先」退到链接**所在的目录**：库外的一个链接指向业务库里的 ZIP 时祖先在库外，路径判据整类失效，而调用方随后的
# `-f` / 摘要 / `unzip` 全都跟着链接读业务库文件。只用 builtin 解不出链接目标（没有 readlink builtin），只能拒绝。
: > "$repo/inrepo.zip"
: > "$outside/real.zip"
ln -s "$repo/inrepo.zip" "$outside/abs-link.zip"                      # 绝对目标指进业务库
ln -s "../business-repo/inrepo.zip" "$outside/rel-link.zip"           # 相对目标指进业务库
ln -s "abs-link.zip" "$outside/chain-link.zip"                        # 链式链接
ln -s "$tmp/no-such-target.zip" "$outside/broken-link.zip"            # 断链
ln -s "$outside/loop-b.zip" "$outside/loop-a.zip"                     # 链接环
ln -s "$outside/loop-a.zip" "$outside/loop-b.zip"
ln -s "$outside/real.zip" "$outside/out-link.zip"                     # 目标在库外：同样拒绝（解不出就是解不出）
for _f in abs-link.zip rel-link.zip chain-link.zip broken-link.zip loop-a.zip out-link.zip; do
  gate2 "$outside/$_f" "$repo"
  assert_nonzero "$RC" "R2：待检路径自己是符号链接（${_f}）→ 拒绝"
  assert_contains "$OUT" "本身是符号链接" "R2（${_f}）：报错点明它是符号链接"
  assert_not_contains "$OUT" "$repo" "R2（${_f}）：取值不回显"
done
unset _f
# 正控①：库外的普通文件放行（钉版档位的正常形态），且一句话都不打
gate2 "$outside/real.zip" "$repo"; assert_rc "$RC" 0 "R2 正控：库外的普通文件 → 放行"
assert_eq "$OUT" "" "R2 正控：放行时一句话都不打"
# 正控②：库外、尚不存在的文件路径仍按祖先判定放行（「取不到」由调用方的 `-f` 报，不是路径门的事）
gate2 "$outside/not-yet.zip" "$repo"; assert_rc "$RC" 0 "R2 正控：库外尚不存在的文件路径 → 放行（祖先在库外）"
# 正控③：待检目录是指向**库外目录**的符号链接不受影响——`cd -P` 对它成功，上一步就解析成物理路径了
# （$HOME 是 /home/x → /data/x 这类形态很常见，不能误伤）
ln -s "$outside" "$tmp/home-dirlink"
gate2 "$tmp/home-dirlink" "$repo"; assert_rc "$RC" 0 "R2 正控：待检目录是指向库外目录的符号链接 → 放行"
# 目录链接指进业务库仍走原来那条判据（报「解析到业务库内」，不是新加的这条）
gate2 "$tmp/home-link" "$repo"
assert_nonzero "$RC" "R2：指向业务库的目录链接 → 拒绝"
assert_contains "$OUT" "解析到业务库内" "R2：目录链接报「解析到业务库内」（cd -P 解析得出物理路径）"
# 不经链接、直接落在业务库内的文件路径 → 仍按祖先判定拒绝
gate2 "$repo/inrepo.zip" "$repo"
assert_nonzero "$RC" "R2：业务库内的文件路径 → 拒绝"
assert_contains "$OUT" "解析到业务库内" "R2：库内文件报「解析到业务库内」"

report
