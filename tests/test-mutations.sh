#!/usr/bin/env bash
# 变异测试（守卫真的会失败吗）：把集成包复制到临时目录，用 sed 精确删掉一段防护逻辑，
# 跑端到端，期望「该防护的可观测结果」不再成立。若变异后结果依旧成立，说明端到端测试里的
# 对应断言测不到这段逻辑（或防护来自别处），本测试失败。sed 没命中（脚本未改变）同样失败，
# 防止实现改写后变异测试悄悄变成空转。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
source fixture-repo.sh
if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null; then
  echo "SKIP: 本机无 timeout/gtimeout（GNU coreutils），跳过 test-mutations.sh" >&2
  exit 0
fi
ROOT=$(cd .. && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export PATH="$ROOT/tests/mockbin:$PATH"
export DRY_RUN=1 KIRO_API_KEY=k YUNXIAO_TOKEN=t YUNXIAO_ORG_ID=org123 CODEUP_REPO_ID=456
export MR_LOCAL_ID=7 MR_TARGET_BRANCH=master CI_COMMIT_REF_NAME=feature/x

# $1=变异名 $2=sed 表达式 $3=被变异文件（相对集成包根，默认 scripts/kiro-review.sh）
#   → stdout 变异后的集成包根目录
make_mutant() {
  local name="$1" expr="$2" target="${3:-scripts/kiro-review.sh}" dst
  dst="$tmp/pkg-$name"
  mkdir -p "$dst"; cp -R "$ROOT/scripts" "$ROOT/kiro" "$ROOT/prompts" "$dst/"
  sed -e "$expr" "$ROOT/$target" > "$dst/$target"
  if cmp -s "$ROOT/$target" "$dst/$target"; then
    echo "FAIL: 变异 ${name} 没有改变 ${target}——sed 模式 [${expr}] 已与实现失配" >&2; exit 1
  fi
  # 只对 shell 文件做语法检查（提示词 .md 也可以是变异对象，15-fix4 M5ac）
  [[ "$target" == *.md || "$target" == *.json ]] || bash -n "$dst/$target" || { echo "FAIL: 变异 ${name} 让 ${target} 产生语法错误" >&2; exit 1; }
  echo "$dst"
}
# 在已有变异包上再变异一处（双变异）：$1=变异包根 $2=sed 表达式 $3=目标文件（相对包根，默认 scripts/kiro-review.sh）
# 同样要求 sed 真的改到了文件、改后仍是合法 bash。给「两道防线叠着」的场景用：单独杀掉一道时可观测结果不变
# （那正是纵深防御该有的样子），只有两道一起杀掉，端到端断言才会失败——这条断言不是空转要靠双变异来证。
mutate_more() {
  local pkg="$1" expr="$2" target="${3:-scripts/kiro-review.sh}"
  sed -e "$expr" "$pkg/$target" > "$pkg/$target.mut" || exit 1
  if cmp -s "$pkg/$target" "$pkg/$target.mut"; then
    echo "FAIL: 双变异没有改变 ${target}——sed 模式 [${expr}] 已与实现失配" >&2; exit 1
  fi
  mv -f "$pkg/$target.mut" "$pkg/$target"; chmod +x "$pkg/$target"
  bash -n "$pkg/$target" || { echo "FAIL: 双变异让 ${target} 产生语法错误" >&2; exit 1; }
}
# 汇总 sink 掩码那一行（票 16）：M12 与票 16 段的 M-a/M-c/M-d 都要精确命中它
REDACT_LINE='^review_redact_file "\$WORK/comment.md" || rrc=\$?$'
# $1=用例名 $2=集成包根目录 → 新建 fixture 并运行；结果写入全局 CASE(目录) / RC / OUT
# 用法：run_case <用例名> <集成包根目录> [VAR=值 ...]（额外的 VAR=值 只作用于这一次调用）
# 可选：MUT_TWEAK=<函数名> 在运行前于 checkout 目录内执行，用来改造 fixture（与 test-kiro-review.sh 的 CASE_TWEAK 同义）。
run_case() {
  local name="$1" pkg="$2"; shift 2
  CASE="$tmp/case-$name"; mkdir -p "$CASE"
  make_fixture_repo "$CASE"
  if [[ -n "${MUT_TWEAK:-}" ]]; then (cd "$CASE/work" && "$MUT_TWEAK"); fi
  MUT_TWEAK=""
  export HOME="$CASE/home"; mkdir -p "$HOME"
  # 替身只从 $HOME/.kiro-mock/ 取配置与写记录（与 test-kiro-review.sh 同一约定；不借道 KIRO_ENV_PASSTHROUGH）
  export REVIEW_REPO_DIR="$CASE/work"
  mock_config_write "$HOME" "$@"; MD="$HOME/.kiro-mock"
  RC=0; OUT=$(env "$@" "$pkg/scripts/kiro-review.sh" 2>&1) || RC=$?
}

# 从 DRY_RUN 输出里取出将要回写的评论正文（与 test-kiro-review.sh 同一份实现意图）
posted_comment() {
  printf '%s' "$1" | python3 -c '
import json, sys
s = sys.stdin.read()
i = s.rfind("DRY_RUN body: ")
if i < 0:
    sys.exit(0)
b = s[i + len("DRY_RUN body: "):]
d = 0
for n, ch in enumerate(b):
    if ch == "{":
        d += 1
    elif ch == "}":
        d -= 1
        if d == 0:
            b = b[:n + 1]
            break
try:
    sys.stdout.write(json.loads(b).get("content", ""))
except Exception:
    pass
'
}

# --- 对照：未变异的实现，三项守卫全部成立（否则下面的「失败」没有参照意义）---
run_case baseline "$ROOT"
assert_rc "$RC" 0 "对照：未变异实现成功"
assert_eq "$([[ -e "$CASE/work/AGENTS.md" || -e "$CASE/work/src/sub/AGENTS.md" ]] && echo exists || echo gone)" "gone" "对照：AGENTS.md 已移除"
assert_eq "$(cat "$MD/cwdscan")" "" "对照：Kiro 启动时工作区干净"
assert_eq "$([[ -e "$CASE/work/src/sub/.kiro" || -e "$CASE/work/lsp.json" ]] && echo exists || echo gone)" "gone" "对照：子目录 .kiro/ 与根 lsp.json 已移除"
assert_contains "$(paste -sd' ' "$MD/args")" "--agent codeup-reviewer" "对照：参数含 --agent codeup-reviewer"
assert_eq "$(grep -c -- '^--trust' "$MD/args")" "0" "对照：参数里没有任何 --trust-* 开关"
assert_eq "$(grep -c -x -- 'YUNXIAO_TOKEN' "$MD/env")" "0" "对照：Kiro 进程环境里没有 YUNXIAO_TOKEN"
assert_eq "$(grep -c -x -- 'KIRO_API_KEY' "$MD/env")" "1" "对照：Kiro 进程环境里有 KIRO_API_KEY"
assert_contains "$(paste -sd' ' "$MD/args")" "--agent-engine v2" "对照：参数含 --agent-engine v2"
assert_contains "$(paste -sd' ' "$MD/args")" "--output-format stream-json" "对照：参数含 --output-format stream-json"
assert_contains "$(cat "$MD/settings")" "chat.disableInheritingDefaultResources true" "对照：settings 已调用"
assert_contains "$OUT" "P0 1 · P1 1 · P2 1" "对照：评论按契约渲染出分级统计"
assert_contains "$OUT" "Kiro 用量：credits=0.2609" "对照：credits 用量写进日志"
assert_not_contains "$OUT" "结构化解析失败" "对照：未变异实现不降级"

# --- M1：删掉 AGENTS.md 移除逻辑 → AGENTS.md 残留、Kiro 启动时仍能看到 ---
pkg=$(make_mutant m1-agentsmd '/-iname AGENTS.md -not -type d/d' scripts/lib/isolation.sh)
run_case m1 "$pkg"
assert_rc "$RC" 0 "M1：变异体仍能跑完（只是失去防护）"
assert_eq "$([[ -e "$CASE/work/AGENTS.md" && -e "$CASE/work/src/sub/AGENTS.md" ]] && echo exists || echo gone)" "exists" \
  "M1：移除逻辑被删后根与子目录 AGENTS.md 残留——端到端断言「AGENTS.md 已移除」会失败"
assert_contains "$(cat "$MD/cwdscan")" "AGENTS.md" "M1：Kiro 启动时工作区扫描到 AGENTS.md——端到端断言「工作区干净」会失败"
assert_contains "$(cat "$MD/stdin")" "CANARY-AGENTSMD-ROOT" "M1：diff 内容不受移除逻辑影响（对照两侧一致）"

# --- M2：删掉 --agent-engine 参数 → 引擎不再钉死 ---
pkg=$(make_mutant m2-engine 's/--agent-engine "\$KIRO_ENGINE"//')
run_case m2 "$pkg"
assert_rc "$RC" 0 "M2：变异体仍能跑完"
assert_not_contains "$(paste -sd' ' "$MD/args")" "--agent-engine v2" "M2：参数中不再有 --agent-engine v2——端到端断言会失败"

# --- M4：删掉 --agent 参数 → 以默认 agent 运行（无拒绝路径、无只读提示词）---
pkg=$(make_mutant m4-agent 's/ --agent "\$AGENT_NAME"//')
run_case m4 "$pkg"
assert_rc "$RC" 0 "M4：变异体仍能跑完"
assert_not_contains "$(paste -sd' ' "$MD/args")" "--agent codeup-reviewer" "M4：参数中不再有 --agent codeup-reviewer——端到端断言会失败"

# --- M5a：把 --trust-tools=read,grep,glob 加回调用行 → 「没有任何 --trust-*」断言必须失败（票 15）---
pkg=$(make_mutant m5a-trust-tools 's/--agent "\$AGENT_NAME"/--trust-tools=read,grep,glob --agent "$AGENT_NAME"/')
run_case m5a "$pkg"
assert_rc "$RC" 0 "M5a：变异体仍能跑完（只是失去边界语义）"
assert_eq "$(grep -c -x -- '--trust-tools=read,grep,glob' "$MD/args")" "1" "M5a：参数里出现 --trust-tools——端到端断言「没有任何 --trust-*」会失败"
assert_eq "$(grep -c -- '^--trust' "$MD/args")" "1" "M5a：行首匹配同样抓到它"

# --- M5b：加上拒绝信息里推荐的 --trust-all-tools（实测绕过 allowedPaths，P1-15 T7）→ 断言必须失败 ---
pkg=$(make_mutant m5b-trust-all 's/--agent "\$AGENT_NAME"/--trust-all-tools --agent "$AGENT_NAME"/')
run_case m5b "$pkg"
assert_rc "$RC" 0 "M5b：变异体仍能跑完"
assert_eq "$(grep -c -x -- '--trust-all-tools' "$MD/args")" "1" "M5b：参数里出现 --trust-all-tools——端到端断言「绝不传 --trust-all-tools」会失败"

# --- M5c：去掉 env -i 许可清单 → Kiro 进程继承完整环境，YUNXIAO_TOKEN 可见（票 15）---
pkg=$(make_mutant m5c-env-i 's/env -i "\${KIRO_ENV_ALLOW\[@\]}" kiro-cli chat --no-interactive/kiro-cli chat --no-interactive/')
run_case m5c "$pkg"
assert_rc "$RC" 0 "M5c：变异体仍能跑完"
assert_eq "$(grep -c -x -- 'YUNXIAO_TOKEN' "$MD/env")" "1" "M5c：Kiro 进程环境里出现 YUNXIAO_TOKEN——端到端断言「没有 YUNXIAO_TOKEN」会失败"
assert_eq "$(grep -c -x -- 'CODEUP_REPO_ID' "$MD/env")" "1" "M5c：CODEUP_REPO_ID 同样泄入"

# --- M5d：拿掉安装函数里「--workspace/--chunks 必填」的检查（15-fix #3 / 15-fix2 #7）---
# 15-fix2 #7 删掉了后面那两个恒真的 ws_set/ch_set 守卫，所以没了必填检查之后，缺参数会在「取物理路径」处以另一个理由失败
# （`--workspace 取值为空`），不再装出坏 agent；这道检查现在的价值是**报错把两个必填参数都点名**（含 --chunks 与 --allow-none 提示）。
# 可观测结果：缺参数时的报错不再点名 --chunks——单测「缺参数：报错点名 --chunks」断言会失败。
pkg=$(make_mutant m5d-required '/缺少必填参数/d' scripts/lib/kiro-agent.sh)
rc5d=0; err5d=$( set +e; source "$pkg/scripts/lib/kiro-agent.sh"; kiro_install_agent "$pkg/kiro/agent-codeup-reviewer.json" "$tmp/m5d-agents" 2>&1 >/dev/null ) || rc5d=$?
assert_eq "$([[ $rc5d -ne 0 ]] && echo nonzero)" "nonzero" "M5d：缺参数仍失败（在取物理路径处）——不会装出坏 agent"
assert_not_contains "$err5d" "--chunks" "M5d：报错不再点名 --chunks——单测「缺参数：报错点名 --chunks」断言会失败"
assert_not_contains "$err5d" "必填" "M5d：报错不再说明「必填」"
assert_eq "$([[ -e "$tmp/m5d-agents" ]] && echo written || echo none)" "none" "M5d：仍不落盘"
rc5d=0; err5dc=$( set +e; source "$ROOT/scripts/lib/kiro-agent.sh"; kiro_install_agent "$ROOT/kiro/agent-codeup-reviewer.json" "$tmp/m5d-control" 2>&1 >/dev/null ) || rc5d=$?
assert_contains "$err5dc" "--chunks" "M5d 对照：未变异实现的报错点名 --chunks"

# --- M5e：build_review_input 里 chunk 目录改回逻辑路径（pwd 而非 pwd -P）→ 索引里的 chunk 目录与 allowedPaths[1] 形态不一致（票 15）---
# 要让「逻辑 ≠ 物理」在任何平台成立：macOS 的 mktemp -d 落在 /var/folders（→ /private/var/folders，且不理 TMPDIR）；
# Linux 的 /tmp 通常是真目录，所以给一个符号链接 TMPDIR（GNU mktemp 按它创建 $WORK）。两个平台至少有一种生效；
# 下面第一条断言就是这个前提的自检：变异体写出的索引目录必须**不是**物理形态，否则本变异在此主机上不可观测。
pkg=$(make_mutant m5e-chunk-logical 's/chunk_dir=\$(cd "\$chunk_dir" \&\& pwd -P)/chunk_dir=$(cd "$chunk_dir" \&\& pwd)/' scripts/lib/diff-compress.sh)
mkdir -p "$tmp/m5e-tmp-real"; ln -s "$tmp/m5e-tmp-real" "$tmp/m5e-tmp-link"
# 变异体与对照都要读索引目录：$WORK 在脚本退出时被 trap 删掉，所以「物理形态」用其父目录（TMPDIR 或 /var/folders）的 pwd -P 判
idx_dir_of() { awk 'index($0, "=== 未直传的变更文件索引") == 1 {on=1; next} on && $0 == "" {exit} on {print}' "$1" | jq -r '.chunk | sub("/[^/]*$"; "")' | sort -u; }
phys_of_parent() { local d; d=$(dirname "$(dirname "$1")"); (cd "$d" && pwd -P); }   # <WORK>/chunks → <WORK> 的父目录
run_case m5e "$pkg" DIFF_SIZE_LIMIT=1 TMPDIR="$tmp/m5e-tmp-link"
assert_rc "$RC" 0 "M5e：变异体仍能跑完"
idx5e_dir=$(idx_dir_of "$MD/stdin")
assert_eq "$([[ -n "$idx5e_dir" ]] && echo nonempty)" "nonempty" "M5e：索引非空"
assert_eq "$([[ "$(dirname "$(dirname "$idx5e_dir")")" == "$(phys_of_parent "$idx5e_dir")" ]] && echo physical || echo logical)" "logical" \
  "M5e 前提自检：变异体写出的索引 chunk 目录是逻辑形态（${idx5e_dir}）——此主机上逻辑≠物理成立"
allow5e=$(jq -r '.toolsSettings.read.allowedPaths[1]' "$CASE/home/.kiro/agents/codeup-reviewer.json")
assert_eq "$([[ "$idx5e_dir" == "$allow5e" ]] && echo same || echo differs)" "differs" \
  "M5e：索引里的 chunk 目录（${idx5e_dir}）与 allowedPaths[1]（${allow5e}）形态不一致——端到端「逐字相同」断言会失败"
# 对照：未变异实现下两者逐字相同，且都是物理形态
run_case m5e-control "$ROOT" DIFF_SIZE_LIMIT=1 TMPDIR="$tmp/m5e-tmp-link"
idx5ec_dir=$(idx_dir_of "$MD/stdin")
allow5ec=$(jq -r '.toolsSettings.read.allowedPaths[1]' "$CASE/home/.kiro/agents/codeup-reviewer.json")
assert_eq "$idx5ec_dir" "$allow5ec" "M5e 对照：未变异实现下索引 chunk 目录与 allowedPaths[1] 逐字相同"
assert_eq "$([[ "$(dirname "$(dirname "$idx5ec_dir")")" == "$(phys_of_parent "$idx5ec_dir")" ]] && echo physical || echo logical)" "physical" \
  "M5e 对照：未变异实现写出的索引 chunk 目录是物理形态"

# --- M5f：去掉隔离步骤里的符号链接删除 → Kiro 启动时业务库里的符号链接还在（15-fix #1）---
mut_add_symlinks() {
  ln -s /etc/hosts link-to-hosts
  mkdir -p src/sub2 && ln -s /etc src/sub2/link-to-etc-dir
  git add -A && git commit -qm "add symlinks"
}
pkg=$(make_mutant m5f-symlinks '/-o -type l -exec sh -c/d' scripts/lib/isolation.sh)
MUT_TWEAK=mut_add_symlinks run_case m5f "$pkg"
assert_rc "$RC" 0 "M5f：变异体仍能跑完"
assert_contains "$(cat "$MD/cwdscan")" "link-to-hosts" "M5f：Kiro 启动时符号链接仍在——端到端「工作区里没有任何符号链接」断言会失败"
assert_contains "$(cat "$MD/cwdscan")" "link-to-etc-dir" "M5f：指向目录的符号链接同样残留"
# 对照见 test-kiro-review.sh 的 symlinks 用例（15-fix2 #8：不在这里重复跑一遍未变异实现）

# --- M5g / M5h：另两处 kiro-cli 调用（chat --help、settings）去掉 env -i → 那次调用继承完整环境（15-fix #8）---
pkg=$(make_mutant m5g-help-env 's/env -i "\${KIRO_ENV_ALLOW\[@\]}" kiro-cli chat --help/kiro-cli chat --help/')
run_case m5g "$pkg"
assert_rc "$RC" 0 "M5g：变异体仍能跑完"
assert_eq "$(grep -c -x -- 'YUNXIAO_TOKEN' "$MD/env-help")" "1" "M5g：--help 那次调用的环境里出现 YUNXIAO_TOKEN——端到端「env-help 没有 YUNXIAO_TOKEN」断言会失败"
assert_eq "$(grep -c -x -- 'YUNXIAO_TOKEN' "$MD/env")" "0" "M5g：chat 那次仍干净（变异只动了 --help）"
pkg=$(make_mutant m5h-settings-env 's/env -i "\${KIRO_ENV_ALLOW\[@\]}" kiro-cli settings/kiro-cli settings/')
run_case m5h "$pkg"
assert_rc "$RC" 0 "M5h：变异体仍能跑完"
assert_eq "$(grep -c -x -- 'YUNXIAO_TOKEN' "$MD/env-settings")" "1" "M5h：settings 那次调用的环境里出现 YUNXIAO_TOKEN——端到端「env-settings 没有 YUNXIAO_TOKEN」断言会失败"

# --- M5gv：第四处 kiro-cli 调用（--version，在库函数 kiro_cli_version 里）去掉 env -i → 那次调用继承完整环境（15-fix4 #18）---
pkg=$(make_mutant m5gv-version-env 's/env -i "\${KIRO_ENV_ALLOW\[@\]}" kiro-cli --version/kiro-cli --version/' scripts/lib/kiro-agent.sh)
run_case m5gv "$pkg"
assert_rc "$RC" 0 "M5gv：变异体仍能跑完"
assert_eq "$(grep -c -x -- 'YUNXIAO_TOKEN' "$MD/env-version")" "1" "M5gv：--version 那次调用的环境里出现 YUNXIAO_TOKEN——端到端「env-version 没有 YUNXIAO_TOKEN」断言会失败"
assert_eq "$(grep -c -x -- 'YUNXIAO_TOKEN' "$MD/env")" "0" "M5gv：chat 那次仍干净（变异只动了 --version）"

# --- M5i：日志里的变量名清单改回按行 cut → 取值含换行时半个取值进日志（15-fix #7）---
pkg=$(make_mutant m5i-names-cut 's/"\${KIRO_ENV_ALLOW\[@\]%%=\*}"/"${KIRO_ENV_ALLOW[@]}" | cut -d= -f1/' scripts/lib/kiro-agent.sh)
run_case m5i "$pkg" KIRO_API_KEY="$(printf 'k\nSECRETFRAG=leaked')"
assert_rc "$RC" 0 "M5i：变异体仍能跑完"
assert_contains "$OUT" "SECRETFRAG" "M5i：换行后的半个取值进了日志——端到端「日志里不出现 SECRETFRAG」断言会失败"
# 对照见 test-kiro-review.sh 的 nlkey 用例（15-fix2 #8）

# --- M5j：去掉 KIRO_ENV_PASSTHROUGH 的名字校验 → 非法名字被静默忽略、评审照跑（15-fix #11）---
pkg=$(make_mutant m5j-passthrough-check '/含非法变量名/d' scripts/lib/kiro-agent.sh)
run_case m5j "$pkg" KIRO_ENV_PASSTHROUGH="YUNXIAO_TOKEN=leakedvalue"
assert_rc "$RC" 0 "M5j：非法名字不再拒绝运行——端到端「KIRO_ENV_PASSTHROUGH 含 NAME=value：非零退出」断言会失败"
assert_not_contains "$(posted_comment "$OUT")" "非法变量名" "M5j：没有失败评论"
# 对照见 test-kiro-review.sh 的 badpass 用例（15-fix2 #8）

# --- M5k：固定名单里塞进一个 KIRO_FOO（模拟回到 KIRO_* 形状匹配）→ 名单外的 KIRO_FOO 被透传（15-fix #12）---
pkg=$(make_mutant m5k-fixed-list 's/KIRO_API_KEY KIRO_LOG_NO_COLOR/KIRO_API_KEY KIRO_FOO KIRO_LOG_NO_COLOR/' scripts/lib/kiro-agent.sh)
run_case m5k "$pkg" KIRO_FOO=1
assert_rc "$RC" 0 "M5k：变异体仍能跑完"
assert_eq "$(grep -c -x -- 'KIRO_FOO' "$MD/env")" "1" "M5k：KIRO_FOO 被透传——端到端「Kiro 进程看不到 KIRO_FOO」断言会失败"

# --- M5l：安装函数漏写 grep 那一处 allowedPaths → grep 没有边界（15-fix #3 / 15-fix2 #16：单变异可杀）---
# 单测层：三处不再相等；端到端层：执行器第 3 步的 kiro_agent_selfcheck **按值**比对三处 allowedPaths，拦下来并回写失败评论
# 15-fix4 裁决 A 后三处 allowedPaths 由 reduce 循环统一写入，不再有 grep 专属的一行；变异改为「循环里对 grep 跳过覆盖」（保留源定义里的旧值）。
pkg=$(make_mutant m5l-grep-allow 's/\.toolsSettings\[\$t\]\.allowedPaths = \[\$ws, \$ch\]/.toolsSettings[$t].allowedPaths = (if $t == "grep" then .toolsSettings[$t].allowedPaths else [$ws, $ch] end)/' scripts/lib/kiro-agent.sh)
mkdir -p "$tmp/m5l-ws" "$tmp/m5l-ch"
dest5l=$( set +e; source "$pkg/scripts/lib/kiro-agent.sh"; kiro_install_agent "$pkg/kiro/agent-codeup-reviewer.json" "$tmp/m5l-agents" --workspace "$tmp/m5l-ws" --chunks "$tmp/m5l-ch" 2>/dev/null )
assert_eq "$([[ "$(jq -c .toolsSettings.grep.allowedPaths "$dest5l")" == "$(jq -c .toolsSettings.read.allowedPaths "$dest5l")" ]] && echo same || echo differs)" "differs" \
  "M5l：安装后 grep.allowedPaths ≠ read.allowedPaths——单测「三处相等」断言会失败"
run_case m5l "$pkg"
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "M5l：执行器的自检（值比对）拒绝运行"
assert_contains "$(posted_comment "$OUT")" "grep.allowedPaths" "M5l：失败评论点名 grep.allowedPaths"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "M5l：Kiro 未被启动（grep 无边界的 agent 不能拿去跑）"

# --- M5ae：安装器不再按 allow 根注入绝对拒绝形状（15-fix4 #1 补）→ 自检按值拦下、Kiro 未启动（单变异可杀）---
pkg=$(make_mutant m5ae-no-abs-deny 's/= ($d + ($d | deny_abs($ws)) + ($d | deny_abs($ch)))/= $d/' scripts/lib/kiro-agent.sh)
run_case m5ae "$pkg"
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "M5ae：执行器自检拒绝运行"
assert_contains "$(posted_comment "$OUT")" "缺少按 allow 根注入的绝对拒绝形状" "M5ae：失败评论点名缺的是注入条目"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "M5ae：Kiro 未被启动（.git / .ssh 在空 cwd 下没有绝对拒绝形状护着的 agent 不能拿去跑）"

# --- M5m：删掉执行器第 3 步的自检调用（单变异）→ 「受信 agent 自检通过」那行日志消失（端到端断言它必须在）---
pkg=$(make_mutant m5m-no-selfcheck '/^if kiro_agent_selfcheck "\$INSTALLED_AGENT"/,/^fi$/d')
run_case m5m "$pkg"
assert_rc "$RC" 0 "M5m：没有自检时评审照跑"
assert_not_contains "$OUT" "受信 agent 自检通过" "M5m：自检留痕消失——端到端「第 3 步自检通过并留痕」断言会失败"

# --- M5n：安装器去掉 deniedPaths 三处检查 → glob.deniedPaths 为空数组的定义照样装成功、glob 只有 allow 没有 deny（15-fix2 #11）---
# 15-fix4 裁决 A 后渲染步会把 deny 形状按 allow 根注入，整个 toolsSettings.glob 缺失时渲染本身就失败（null 不可迭代），
# 所以夹具改成「glob.deniedPaths = []」：只有被删掉的那一处检查会拒它，变异体装成功、装出来的 glob deny 仍为空。
pkg=$(make_mutant m5n-deny-check '/^  \[\[ -z "\$deny_missing" \]\] ||/d' scripts/lib/kiro-agent.sh)
jq --arg p "file://$ROOT/prompts/review-agent-prompt.md" '.prompt = $p | .toolsSettings.glob.deniedPaths = []' "$ROOT/kiro/agent-codeup-reviewer.json" > "$tmp/m5n-noglob.json"
rc5n=0; dest5n=$( set +e; source "$pkg/scripts/lib/kiro-agent.sh"; kiro_install_agent "$tmp/m5n-noglob.json" "$tmp/m5n-agents" --workspace "$tmp/m5l-ws" --chunks "$tmp/m5l-ch" 2>/dev/null ) || rc5n=$?
assert_eq "$rc5n" "0" "M5n：glob.deniedPaths 为空的定义装成功——单测「deniedPaths 为空数组：拒绝安装」断言会失败"
assert_eq "$(jq -c '.toolsSettings.glob.deniedPaths' "$dest5n")" "[]" "M5n：装出来的 glob deniedPaths 仍为空（只有 allowedPaths 有效）"

# --- M5o：导出判定改回只认 `declare -x` 前缀 → declare -rx 的变量被丢（15-fix2 #12）---
pkg=$(make_mutant m5o-declare-prefix 's/=~ \^declare\\ -\[a-zA-Z\]\*x \]\]/== "declare -x"* ]]/' scripts/lib/kiro-agent.sh)
attr5o=$(env -i PATH="$PATH" HOME="$tmp/h5o" bash -c 'set -euo pipefail; declare -rx TMPDIR=/ro-tmp; source "$1"; kiro_env_allowlist; printf "%s\n" "${KIRO_ENV_ALLOW[@]}"' _ "$pkg/scripts/lib/kiro-agent.sh")
assert_not_contains "$attr5o" "TMPDIR=" "M5o：declare -rx TMPDIR 被丢——单测「declare -rx 的变量透传」断言会失败"

# --- M5p：凭证形状的名字不再单独归类（当成普通名字放进名单）→ KIRO_ENV_PASSTHROUGH=YUNXIAO_TOKEN 照跑，令牌进了 Kiro 进程环境（15-fix2 #13）---
# 只删「拒绝」那一行的变异会把凭证名字静默丢掉（进不了名单也不报错）——那是另一种坏；这里模拟的是「忘了区分」
pkg=$(make_mutant m5p-cred-names 's/rule=$(_kiro_env_cred_rule "$up")/rule=""/' scripts/lib/kiro-agent.sh)
run_case m5p "$pkg" KIRO_ENV_PASSTHROUGH="YUNXIAO_TOKEN"
assert_rc "$RC" 0 "M5p：凭证形状的名字不再拒绝——端到端「KIRO_ENV_PASSTHROUGH=YUNXIAO_TOKEN：拒绝运行」断言会失败"
assert_eq "$(grep -c -x -- 'YUNXIAO_TOKEN' "$MD/env")" "1" "M5p：YUNXIAO_TOKEN 进了 Kiro 进程环境（固定名单关掉的洞被一个变量名重新打开）"

# --- M5q：.git 剪枝退回只剪根目录 → 嵌套 .git 内部的符号链接被删（15-fix2 #15）---
mut_nested_git() { mkdir -p vendor/lib/.git && ln -s /etc/hosts vendor/lib/.git/nestedlink; }
pkg=$(make_mutant m5q-nested-git 's/ -o \\( -name \.git -type d \\)//' scripts/lib/isolation.sh)
MUT_TWEAK=mut_nested_git run_case m5q "$pkg"
assert_rc "$RC" 0 "M5q：变异体仍能跑完"
assert_eq "$([[ -L "$CASE/work/vendor/lib/.git/nestedlink" ]] && echo kept || echo gone)" "gone" "M5q：嵌套 .git 内部的符号链接被删——端到端「嵌套 .git：目录内部的符号链接不动」断言会失败"

# --- M5r：非法 token 不再掩码 → 像令牌的 token 原文进日志与评论（15-fix2 #17）---
pkg=$(make_mutant m5r-no-mask 's/bad+=("第 ${idx} 项 $(_kiro_env_mask_syntax "$tok")")/bad+=("第 ${idx} 项 $tok")/' scripts/lib/kiro-agent.sh)
run_case m5r "$pkg" KIRO_ENV_PASSTHROUGH="ghp-liveSecret123"
assert_contains "$OUT" "liveSecret123" "M5r：像令牌的 token 原文进了输出——端到端「原文不进日志也不进评论」断言会失败"

# --- M5s：去掉 kiro-cli 版本 notice → 版本不在名单也没有任何提示（15-fix2 #24）---
pkg=$(make_mutant m5s-version-notice '/REVIEW_NOTICE="注意：本次 kiro-cli 版本/d')
run_case m5s "$pkg" MOCK_KIRO_VERSION=9.9.9
assert_rc "$RC" 0 "M5s：变异体仍能跑完"
assert_not_contains "$(posted_comment "$OUT")" "未经 P1-15 探测" "M5s：汇总评论没有版本 notice——端到端「版本不在名单：汇总评论带 notice」断言会失败"

# --- M5t：.kiro 匹配退回区分大小写 → .Kiro/ 幸存（15-fix3 #1）---
# 夹具与端到端 kirocase 用例同一份（tests/fixture-repo.sh 的 make_kiro_case_variants，15-fix4 #10）：以前这里少了 src/x/.KIRO，变异跑在更小的树上
pkg=$(make_mutant m5t-kiro-case 's/-o -iname .kiro -prune/-o -name .kiro -prune/' scripts/lib/isolation.sh)
MUT_TWEAK=make_kiro_case_variants run_case m5t "$pkg"
assert_rc "$RC" 0 "M5t：变异体仍能跑完"
assert_eq "$([[ -d "$CASE/work/src/.Kiro" ]] && echo kept || echo gone)" "kept" "M5t：src/.Kiro/ 幸存——端到端「src/.Kiro/ 目录被删」断言会失败"
assert_eq "$([[ -f "$CASE/work/src/x/.KIRO" ]] && echo kept || echo gone)" "kept" "M5t：子目录大写文件 src/x/.KIRO 同样幸存——端到端「子目录 .KIRO 文件被删」断言会失败"
assert_eq "$([[ -e "$CASE/work/.kiro" ]] && echo kept || echo gone)" "gone" "M5t：小写的根 .kiro 文件仍被删（变异只动了大小写）"

# --- M5u：.kiro 匹配退回只认目录/符号链接 → 根 .kiro 普通文件幸存（15-fix3 #2）---
pkg=$(make_mutant m5u-kiro-type 's/-o -iname .kiro -prune/-o -iname .kiro \\( -type d -o -type l \\) -prune/' scripts/lib/isolation.sh)
MUT_TWEAK=make_kiro_case_variants run_case m5u "$pkg"
assert_rc "$RC" 0 "M5u：变异体仍能跑完"
assert_eq "$([[ -f "$CASE/work/.kiro" ]] && echo kept || echo gone)" "kept" "M5u：根 .kiro 普通文件幸存——端到端「根 .kiro 普通文件被删」断言会失败"
assert_eq "$([[ -f "$CASE/work/src/x/.KIRO" ]] && echo kept || echo gone)" "kept" "M5u：子目录大写普通文件 src/x/.KIRO 同样幸存"
assert_eq "$([[ -d "$CASE/work/src/.Kiro" ]] && echo kept || echo gone)" "gone" "M5u：src/.Kiro/ 目录仍被删（变异只动了类型）"

# --- M5v：降级评论不再接 --notice → 版本 notice 只在日志、评论里没有（15-fix3 #3）---
pkg=$(make_mutant m5v-degraded-notice '/review_render_degraded --text/s/ --notice "\$REVIEW_NOTICE"//')
run_case m5v "$pkg" MOCK_KIRO_NO_MARKER=1 MOCK_KIRO_VERSION=9.9.9
assert_rc "$RC" 0 "M5v：变异体仍能跑完"
assert_contains "$OUT" "未经 P1-15 探测" "M5v：日志仍有警告"
assert_not_contains "$(posted_comment "$OUT")" "未经 P1-15 探测" "M5v：降级评论丢了 notice——端到端「降级评论也带版本 notice」断言会失败"

# --- M5ad：die_review 不再给失败评论传 --notice → kiro-cli 非零退出 + 未探测版本时失败评论没有版本告警（15-fix4 #3）---
pkg=$(make_mutant m5ad-failure-notice '/^      --notice "\$REVIEW_NOTICE" \\$/d')
run_case m5ad "$pkg" MOCK_KIRO_FAIL=1 MOCK_KIRO_VERSION=9.9.9
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "M5ad：仍是失败"
assert_contains "$OUT" "未经 P1-15 探测" "M5ad：日志仍有警告"
assert_not_contains "$(posted_comment "$OUT")" "未经 P1-15 探测" "M5ad：失败评论丢了版本告警——端到端「失败评论带版本告警引用块」断言会失败"

# --- M5w：被拒的凭证形状名字不再掩码 → 完整名字进失败评论（15-fix3 #6）---
pkg=$(make_mutant m5w-cred-mask 's/cred+=("第 ${idx} 项 $(_kiro_env_mask_token "$tok")（命中 ${rule}）")/cred+=("第 ${idx} 项 ${tok}（命中 ${rule}）")/' scripts/lib/kiro-agent.sh)
run_case m5w "$pkg" KIRO_ENV_PASSTHROUGH="$(fake_token svc)"
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "M5w：仍拒绝运行"
assert_contains "$(posted_comment "$OUT")" "$(fake_token svc)" "M5w：完整名字进了评论——端到端「完整名字不进评论」断言会失败"

# --- M5x：kiro_cli_version 去掉 stderr 回退 → 版本打到 stderr 的 CLI 让版本永远「未知」（15-fix3 #8 / 15-fix4 #7）---
pkg=$(make_mutant m5x-version-stderr '/KIRO_CLI_VERSION=$(_kiro_cli_version_pick "$err")/d' scripts/lib/kiro-agent.sh)
run_case m5x "$pkg" MOCK_KIRO_VERSION_STDERR=1
assert_rc "$RC" 0 "M5x：变异体仍能跑完"
assert_contains "$(posted_comment "$OUT")" "未知" "M5x：版本永远「未知」、评论带 notice——端到端「--version 打到 stderr：无 notice」断言会失败"
# --- M5x2：执行器退回旧取法 `2>&1 | head -1 | grep -oE 数字`（正控，15-fix4 #7）→ stderr 上先到的升级提示 2.30.0 被当成本次版本 ---
pkg=$(make_mutant m5x2-version-merged 's|^kiro_cli_version "\$TIMEOUT_BIN" "\$KIRO_CWD" \|\| die_review .*$|KIRO_CLI_VERSION=$(cd "$PKG_ROOT" \&\& "$TIMEOUT_BIN" 60 env -i "${KIRO_ENV_ALLOW[@]}" kiro-cli --version 2>\&1 \| head -1 \| grep -oE "[0-9]+(\\.[0-9]+)+" \| head -1 \|\| true)|')
run_case m5x2 "$pkg" MOCK_KIRO_VERSION_WARN=1
assert_rc "$RC" 0 "M5x2：变异体仍能跑完"
assert_contains "$OUT" "2.30.0 未经 P1-15 探测" "M5x2：升级提示里的 2.30.0 被当成本次版本——端到端「取到的是已装版本 2.21.1」断言会失败"
# --- M5x3：--version 退出码不再判 → 跑不起来的 CLI 只留软 notice、继续去 chat（15-fix4 #7）---
pkg=$(make_mutant m5x3-version-rc 's|^kiro_cli_version "\$TIMEOUT_BIN" "\$KIRO_CWD" \|\| die_review .*$|kiro_cli_version "$TIMEOUT_BIN" "$KIRO_CWD" \|\| true|')
run_case m5x3 "$pkg" MOCK_KIRO_VERSION_RC=127
assert_rc "$RC" 0 "M5x3：--version 退出 127 也照跑——端到端「kiro-cli --version 退出 127：评审失败」断言会失败"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "launched" "M5x3：Kiro chat 仍被启动（额度照烧）"

# --- M5y：自检去掉 `[[ -s ]]` 0 字节检查（15-fix4 #13）→ 空文件仍被第二道（--slurp 恰好一个值）拦下，但固定文案不再点明「0 字节」---
# 单测「selfcheck：空文件的固定文案点明 0 字节」断言会失败。两道都在才是 fail-closed 的纵深：这条变异证明第一道有单独的可观测结果。
pkg=$(make_mutant m5y-selfcheck-size '/安装后的定义文件为空（0 字节）/d' scripts/lib/kiro-agent.sh)
: > "$tmp/m5y-empty.json"
rc5y=0; err5y=$( set +e; source "$pkg/scripts/lib/kiro-agent.sh"; kiro_agent_selfcheck "$tmp/m5y-empty.json" /ws /ch; rc=$?; printf '%s' "$KIRO_AGENT_SELFCHECK_ERROR"; exit $rc ) || rc5y=$?
assert_eq "$([[ $rc5y -ne 0 ]] && echo nonzero)" "nonzero" "M5y：空文件仍非零（第二道 --slurp 兜住）"
assert_not_contains "$err5y" "0 字节" "M5y：文案不再点明 0 字节——单测「空文件的固定文案点明 0 字节」断言会失败"
# --- M5z：自检去掉「恰好一个 JSON 值」这道（15-fix4 #13）→ 两个各自合格的定义拼在一个文件里通过自检（fail-open）---
# 只看 .[0]：纯空白文件退化成「顶层不是对象（null）」仍被拒，但双对象文件的第二个对象被无视——单测「两个各自合格的定义拼在一个文件里 → 失败」会失败。
pkg=$(make_mutant m5z-selfcheck-one 's/if length != 1 then "安装后的定义文件里不是恰好一个 JSON 值.*$/if false then ""/' scripts/lib/kiro-agent.sh)
mkdir -p "$tmp/m5z-ws" "$tmp/m5z-ch"
dest5z=$( set +e; source "$ROOT/scripts/lib/kiro-agent.sh"; kiro_install_agent "$ROOT/kiro/agent-codeup-reviewer.json" "$tmp/m5z-agents" --workspace "$tmp/m5z-ws" --chunks "$tmp/m5z-ch" 2>/dev/null )
cat "$dest5z" "$dest5z" > "$tmp/m5z-two.json"
rc5z=0; ( set +e; source "$pkg/scripts/lib/kiro-agent.sh"; kiro_agent_selfcheck "$tmp/m5z-two.json" "$(cd "$tmp/m5z-ws" && pwd -P)" "$(cd "$tmp/m5z-ch" && pwd -P)" ) || rc5z=$?
assert_eq "$rc5z" "0" "M5z：双对象定义文件通过自检——单测「两个各自合格的定义拼在一个文件里 → 失败」断言会失败"
rc5zc=0; ( set +e; source "$ROOT/scripts/lib/kiro-agent.sh"; kiro_agent_selfcheck "$tmp/m5z-two.json" "$(cd "$tmp/m5z-ws" && pwd -P)" "$(cd "$tmp/m5z-ch" && pwd -P)" ) || rc5zc=$?
assert_eq "$rc5zc" "1" "M5z 对照：未变异实现拒绝双对象定义文件"

# --- M5ab：chat 改回在业务库 checkout 下运行（15-fix4 #1）→ 替身记录的 chatcwd 就是业务库、目录非空 ---
pkg=$(make_mutant m5ab-chat-in-repo 's|( cd "\$KIRO_CWD" \&\& "\$TIMEOUT_BIN" -k 30|( cd "$REVIEW_REPO_DIR" \&\& "$TIMEOUT_BIN" -k 30|')
run_case m5ab "$pkg"
assert_rc "$RC" 0 "M5ab：变异体仍能跑完"
assert_eq "$(cat "$MD/chatcwd")" "$(cd "$CASE/work" && pwd -P)" "M5ab：chat 的 cwd 是业务库 checkout——端到端「Kiro 运行目录不是业务库」断言会失败"
assert_eq "$([[ "$(cat "$MD/chatcwd-entries")" -gt 0 ]] && echo nonempty || echo empty)" "nonempty" "M5ab：cwd 非空——端到端「chat 启动时运行目录为空」断言会失败"
# --- M5ac：运行时提示词丢了 {{REVIEW_WORKSPACE}} 占位符 → 脚本拒绝运行（模型拿不到业务库绝对路径，相对路径读取会全部被拒）---
pkg=$(make_mutant m5ac-no-ws-placeholder 's/{{REVIEW_WORKSPACE}}/REVIEW_WORKSPACE/g' prompts/review-prompt.md)
run_case m5ac "$pkg"
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "M5ac：缺占位符 → 拒绝运行"
assert_contains "$(posted_comment "$OUT")" "REVIEW_WORKSPACE" "M5ac：失败评论点名 {{REVIEW_WORKSPACE}} 占位符"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "M5ac：Kiro 未被启动"

# --- M6：删掉任意深度 .kiro/ 的删除逻辑 → 子目录 .kiro/ 残留、Kiro 启动时能看到 ---
# 模式只认 `-iname .kiro -prune` 这一行（15-fix3：不分大小写、任何类型）；实现改写后失配时 make_mutant 会报错，这正是它存在的意义。
# 隔离逻辑在 scripts/lib/isolation.sh（15-fix2 #10/#15）
pkg=$(make_mutant m6-kiro-dirs '/-iname .kiro -prune/d' scripts/lib/isolation.sh)
run_case m6 "$pkg"
assert_rc "$RC" 0 "M6：变异体仍能跑完"
assert_eq "$([[ -d "$CASE/work/src/sub/.kiro" ]] && echo exists || echo gone)" "exists" "M6：子目录 .kiro/ 残留——端到端断言「.kiro 已移除」会失败"
assert_contains "$(cat "$MD/cwdscan")" "src/sub/.kiro" "M6：Kiro 启动时工作区扫描到子目录 .kiro——端到端断言「工作区干净」会失败"

# --- M7：删掉根 lsp.json 的删除逻辑 → lsp.json 残留 ---
pkg=$(make_mutant m7-lspjson '/-o -path .\/lsp.json -prune -exec sh -c/d' scripts/lib/isolation.sh)
run_case m7 "$pkg"
assert_rc "$RC" 0 "M7：变异体仍能跑完"
assert_eq "$([[ -e "$CASE/work/lsp.json" ]] && echo exists || echo gone)" "exists" "M7：根 lsp.json 残留——端到端断言「lsp.json 已移除」会失败"
assert_contains "$(cat "$MD/cwdscan")" "./lsp.json" "M7：Kiro 启动时工作区扫描到 lsp.json——端到端断言「工作区干净」会失败"

# --- M8：删掉 --output-format stream-json → 替身回到纯文本，事件流里没有 runFinished ---
# 证明：结构化契约路径真的依赖这个参数，缺了会「评审失败」而不是静默降级或静默通过。
pkg=$(make_mutant m8-streamjson 's/--output-format stream-json//')
run_case m8 "$pkg"
assert_nonzero "$RC" "M8：删掉 --output-format 后评审失败——端到端「成功路径退出码 0」会失败"
assert_contains "$OUT" "没有 runFinished 事件" "M8：失败原因是拿不到 runFinished 事件"
assert_not_contains "$OUT" "P0 1 · P1 1 · P2 1" "M8：不再渲染出分级统计——端到端渲染断言会失败"

# --- M9（票 02 要求的变异）：让契约解析器恒返回空 → 必须走降级路径 ---
# 变异对象是库函数 review_extract_json 本身（不是脚本），直接在函数体开头返回空输出。
pkg=$(make_mutant m9-extract-empty 's|^review_extract_json() {|review_extract_json() { printf ""; return 0;|' scripts/lib/review-render.sh)
run_case m9 "$pkg"
assert_rc "$RC" 0 "M9：解析器恒返回空时评审仍以 0 退出（降级不算失败）"
assert_contains "$OUT" "结构化解析失败" "M9：降级断言触发——评论标题含「结构化解析失败」"
# 替身此时输出的仍是合法契约，所以「原文」就是标记外的散文 + 那段 JSON 本身：
# 端到端成功路径断言过「评论不含契约标记」，这里正好反过来，证明贴的是原文而不是渲染结果。
assert_contains "$OUT" "我已读取 src/app.py 并完成评审" "M9：正文退化为评审员输出原文（标记外散文）"
assert_contains "$OUT" "KIRO_REVIEW_JSON" "M9：原文里的契约标记原样出现——端到端「评论不含契约标记」断言会失败"
assert_not_contains "$OUT" "P0 1 · P1 1 · P2 1" "M9：不再有分级统计——端到端成功路径断言会失败"
assert_contains "$OUT" "changeRequests/7/comments" "M9：降级评论仍发到 MR"

# --- M10：拿掉 severity 的 P0/P1/P2 许可清单 → 非法级别不再被丢弃，丢弃计数变化 ---
pkg=$(make_mutant m10-sev-filter 's/| select(($sev == "P0" or $sev == "P1" or $sev == "P2")/| select((true)/' scripts/lib/review-render.sh)
run_case m10 "$pkg" MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/dirty.json"
assert_rc "$RC" 0 "M10：变异体仍能跑完"
assert_not_contains "$OUT" "7 条问题不符合输出契约已丢弃" "M10：级别许可清单被拿掉后丢弃数不再是 7——端到端丢弃断言会失败"
assert_contains "$OUT" "4 条问题不符合输出契约已丢弃" "M10：只剩缺 title/body 与非对象被丢弃（4 条）"

# --- M11：删掉「标记必须唯一」这道检查 → 契约不再唯一可辨，降级断言失效 ---
# 有这道检查时，输出里出现两对标记一律拒绝解析、走降级；删掉之后脚本会从两个候选契约里
# 挑一个（取第一对）当成评审结果——挑中哪一个取决于模型的叙述顺序，而顺序是被评审代码能影响的。
pkg=$(make_mutant m11-marker-unique '/if (ns > 1 || ne > 1) exit 2/d' scripts/lib/review-render.sh)
run_case m11 "$pkg" MOCK_KIRO_DOUBLE_MARKER=1
assert_rc "$RC" 0 "M11：变异体仍能跑完"
assert_not_contains "$OUT" "多于一对契约标记" "M11：不再报「标记不唯一」——端到端断言会失败"
assert_not_contains "$OUT" "结构化解析失败" "M11：不再降级，而是从多个候选契约里挑一个当结果——端到端降级断言会失败"

# --- M12：把降级路径的脚本侧前置掩码换回原样 cat ---
# 票 16 之后降级评论有两道掩码：渲染器里 sanitize 之前的这一道，加上 kiro-review.sh 在 sink 出口的整份掩码。
# 只杀掉前置这一道，端到端可观测结果不变（sink 兜住了）——所以它的守卫在单测层：直接调 review_render_degraded。
mut_degraded() { # $1=集成包根 → stdout 降级评论（原文里带未掩码的 AWS 密钥对）
  ( set +e; source "$1/scripts/lib/review-render.sh"
    printf 'P0：写死了凭证 AWS_SECRET_ACCESS_KEY=%s，还有 %s。\n' "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" "AKIAIOSFODNN7EXAMPLE" > "$tmp/m12.raw.md"
    review_render_degraded --text "$tmp/m12.raw.md" --sha 90fcb05 --src feature/x --dst master \
      --ts "2026-09-02 20:10:02" --diff-note "完整直传" --reason "输出中未找到契约标记" 2>/dev/null )
}
pkg=$(make_mutant m12-degrade-redact 's|^  _review_redact_to "\$_RR_TEXT" "\$masked" review_render_degraded .*$|  cat "$_RR_TEXT" > "$masked"  # 变异 M12：降级原文不掩码|' scripts/lib/review-render.sh)
assert_contains "$(mut_degraded "$pkg")" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" \
  "M12：降级渲染器不再掩码——单测「票 16 降级：原文不出现」断言会失败"
assert_not_contains "$(mut_degraded "$ROOT")" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" "M12 对照：未变异的降级渲染器自己掩掉"
# 端到端：只杀前置掩码，sink 掩码把降级评论兜住——这是票 16 在降级路径上的正控，不是 M12 的击杀条件
run_case m12-sink-catches "$pkg" MOCK_KIRO_LEAK_SECRET=1
assert_rc "$RC" 0 "M12 sink 正控：变异体仍能跑完"
assert_not_contains "$OUT" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" "M12 sink 正控：前置掩码被杀后 sink 掩码仍兜住降级评论（两道防线）"
assert_contains "$OUT" "wJal****EKEY" "M12 sink 正控：掩码形态在（不是靠内容消失蒙对）"
# 双变异：前置掩码 + sink 掩码一起杀掉 → 未掩码的凭证直接进 MR 评论——端到端「评论里不出现完整密钥」断言会失败
mutate_more "$pkg" "s@${REDACT_LINE}@rrc=0  # 双变异 M12：汇总出口也不过文档级兜底@"
run_case m12 "$pkg" MOCK_KIRO_LEAK_SECRET=1
assert_rc "$RC" 0 "M12 双变异：变异体仍能跑完"
assert_contains "$OUT" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" \
  "M12 双变异：降级评论里出现完整密钥——端到端「评论里不出现完整密钥」断言会失败"
assert_contains "$OUT" "AKIAIOSFODNN7EXAMPLE" "M12 双变异：AWS 访问密钥 ID 同样泄漏"

# --- M13：让「补齐未闭合代码围栏」的判定永不成立 → 截断提示被吞进代码块 ---
pkg=$(make_mutant m13-fence-close 's/% 2 )) -eq 1/% 2 )) -eq 99/' scripts/lib/review-render.sh)
run_case m13 "$pkg" MAX_COMMENT_BYTES=900 MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/fenced-code.json"
assert_rc "$RC" 0 "M13：变异体仍能跑完"
comment=$(posted_comment "$OUT")
fences=$(printf '%s\n' "$comment" | grep -c '^```' || true)
assert_eq "$(( fences % 2 ))" "1" "M13：围栏落单（${fences} 个）——端到端「围栏成对」断言会失败"
notice_ln=$(printf '%s\n' "$comment" | grep -n '报告超长已截断' | tail -1 | cut -d: -f1)
before=$(printf '%s\n' "$comment" | grep -n '^```' | cut -d: -f1 | awk -v n="$notice_ln" '$1 < n' | wc -l | tr -d ' ')
assert_eq "$(( before % 2 ))" "1" \
  "M13：截断提示之前只有一个未闭合的围栏（${before} 个），提示被吞进代码块——端到端断言会失败"

# --- M14：让 Markdown 结构清洗变成恒等函数 → 模型文本能注入第二个评审标记与伪造标题 ---
pkg=$(make_mutant m14-sanitize 's/if type != "string" then "" else/if true then . else/' scripts/lib/review-render.sh)
run_case m14 "$pkg" MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/inject.json"
assert_rc "$RC" 0 "M14：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_eq "$(printf '%s\n' "$comment" | grep -c '<!-- kiro-review:')" "2" \
  "M14：评论里出现两个评审标记——端到端「标记恰好一个」断言会失败（后续票按标记原地更新会被打乱）"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^## 结论：')" "2" \
  "M14：模型文本里的伪造结论章节成了真章节——端到端断言会失败"

# --- M15：让「受信 agent 契约标识」检查永远通过 → 非受信产出会被贴到 MR 上 ---
pkg=$(make_mutant m15-contract-id 's/(.contract \/\/ "") == $id/true/' scripts/lib/review-render.sh)
run_case m15 "$pkg" MOCK_KIRO_NO_CONTRACT=1
assert_rc "$RC" 0 "M15：变异体仍能跑完（这正是问题：本该失败）"
assert_not_contains "$OUT" "受信 agent 未生效" "M15：不再识别受信 agent 未生效——端到端断言会失败"
assert_contains "$OUT" "P0 1 · P1 1 · P2 1" "M15：非受信产出被照常渲染并回写 MR"

# ============ 票 03 的守卫 ============
CFX="$ROOT/tests/fixtures/comments"
BOT="$TEST_BOT_USERNAME"

# --- 对照：原地更新在未变异实现上确实成立 ---
run_case baseline-update "$ROOT" DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "对照：二次评审成功"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" "对照：原地更新旧评论"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "0" "对照：不新建第二条"
assert_contains "$(posted_comment "$OUT")" "run:2 -->" "对照：run 递增到 2"
assert_contains "$(posted_comment "$OUT")" "<details><summary>历次评审（2）</summary>" "对照：历次表两行"

# --- M16：拿掉「作者用户名必须匹配」这一半判定 → 会去改别人的评论 ---
# 判定本该是「作者匹配 **且** 含评审标记」。只看标记的话，别人手工复制过一份报告原文时
# （other-author fixture）就会去改那条评论。
pkg=$(make_mutant m16-author-match 's/select(._author == \$bot)/select(true)/' scripts/lib/review-render.sh)
run_case m16 "$pkg" DRY_RUN_FIXTURE_DIR="$CFX/other-author" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "M16：变异体仍能跑完"
assert_eq "$(req_count "$OUT" PUT 'comments/a0000000000000000000000000000002$')" "1" \
  "M16：作者判定被拿掉后去改了别人的评论——端到端「不去改别人的评论」断言会失败"

# --- M17：拿掉「必须含评审标记」这一半判定 → 机器人的闲聊评论被当成汇总改掉 ---
# noise fixture 里机器人有一条「流水线已开始评审」的普通评论，没有评审标记。
pkg=$(make_mutant m17-marker-required 's/| map(select((._runs | length) == 1))/| map(select((._runs | length) >= 0))/' scripts/lib/review-render.sh)
run_case m17 "$pkg" DRY_RUN_FIXTURE_DIR="$CFX/noise" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "M17：变异体仍能跑完"
assert_eq "$(req_count "$OUT" PUT 'comments/d0000000000000000000000000000002$')" "1" \
  "M17：标记判定被拿掉后把机器人的普通评论当成汇总改掉——端到端「不误判」断言会失败"

# --- M18：让历次记录的解析恒返回空 → 历次表丢掉上一次那一行 ---
pkg=$(make_mutant m18-history-empty 's|^review_parse_history() {|review_parse_history() { echo "[]"; return 0;|' scripts/lib/review-render.sh)
run_case m18 "$pkg" DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "M18：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "<details><summary>历次评审（1）</summary>" \
  "M18：历次记录读不回来 → 表里只剩本次一行——端到端「历次表两行」断言会失败"
assert_not_contains "$comment" "| 1 | \`90fcb05\` | 建议修改后合并 | 1/1/1 |" "M18：上一次那一行丢失"
assert_contains "$comment" "run:2 -->" "M18：run 号仍从评审标记算出（与历史解析是两条独立通路）"

# --- M19：把原地更新换成一律新建 → MR 上会出现第二条汇总 ---
pkg=$(make_mutant m19-always-create 's|if codeup_update_comment "\$LOCAL_ID" "\$PRIOR_COMMENT_ID" "\$file"; then|if false; then|')
run_case m19 "$pkg" DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "M19：变异体仍能跑完"
assert_eq "$(req_count "$OUT" PUT)" "0" "M19：不再调用更新接口——端到端「PUT 到同一个 biz_id」断言会失败"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "M19：退化成追加第二条汇总"

# --- M20：失败评论绕过 post_summary 直接新建 → 一次失败就多一条汇总 ---
pkg=$(make_mutant m20-fail-not-updated 's|    post_summary "\$f" |    codeup_post_comment "$LOCAL_ID" "$f" |')
run_case m20 "$pkg" DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT" MOCK_KIRO_FAIL=1
assert_nonzero "$RC" "M20：变异体仍以非零退出"
assert_eq "$(req_count "$OUT" PUT)" "0" "M20：失败评论不再原地更新——端到端断言会失败"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "M20：失败评论变成 MR 上的第二条汇总"

# --- M22：把「机器人用户名未知就不原地更新」退回成「按评审标记的作者推断」→ 会改到别人的评论 ---
# 评审标记是明文可复制的：任何 MR 参与者发一条带标记的评论，就能把本评审员的报告引到他那条上。
pkg=$(make_mutant m22-identity-required 's/{status: "no-identity",/{status: "ok", comment: ($cands | sort_by(.run) | last),/' scripts/lib/review-render.sh)
run_case m22 "$pkg" DRY_RUN_FIXTURE_DIR="$CFX/other-author" CODEUP_BOT_USERNAME=
assert_rc "$RC" 0 "M22：变异体仍能跑完"
assert_eq "$(req_count "$OUT" PUT 'comments/a0000000000000000000000000000002$')" "1" \
  "M22：退回推断后把报告写进了别人的评论——端到端「未配置机器人账号不做原地更新」断言会失败"

# --- M21：让「补齐未闭合 </details>」的循环永不执行 → 截断提示被吞进折叠块 ---
pkg=$(make_mutant m21-details-close 's/while \[\[ "\$det_open" -gt "\$det_close" \]\]; do/while false; do/' scripts/lib/review-render.sh)
run_case m21 "$pkg" MAX_COMMENT_BYTES=1700
assert_rc "$RC" 0 "M21：变异体仍能跑完"
comment=$(posted_comment "$OUT")
opens=$(printf '%s\n' "$comment" | grep -c '<details>' || true)
closes=$(printf '%s\n' "$comment" | grep -c '</details>' || true)
assert_eq "$([[ "$opens" -gt "$closes" ]] && echo unbalanced || echo balanced)" "unbalanced" \
  "M21：<details> 落单（${opens}/${closes}）——端到端「标签成对」断言会失败"
assert_eq "$(printf '%s\n' "$comment" | grep -c '</details>')" "0" "M21：截断提示被吞进未闭合的折叠块"

# --- M23：把折叠标签的转义改回大小写敏感 → 模型文本里的 <DETAILS> 原样进入评论 ---
# HTML 标签名不区分大小写：大写形式一样会被渲染成折叠块，能把脚本渲染的历次表与页脚
# 吞进攻击者自己的折叠块并伪造历次计数。
# 载荷放在**代码围栏内**：票 14 之后围栏外任何像标签的 `<` 都会被通用规则转义，围栏外的 <DETAILS>
# 不再能区分「折叠规则大小写不敏感」与「通用规则兜住了」——变异体会被通用规则遮住、观察不到变化
# （2026-09-05 实测）。折叠规则刻意也作用于围栏内（review_truncate_comment 按行首 `<details` 计数，
# 截断切在围栏中间时围栏内的那一行会露出来），所以围栏内是它独占的观察点。
cat > "$tmp/upperdetails.json" <<'JSON'
{"contract":"codeup-reviewer/1","summary":"s","verdict":"DO_NOT_MERGE","verdict_reason":"r","findings":[
 {"id":"F1","severity":"P0","category":"security","title":"注入企图","file":"src/app.py","line_start":2,"line_end":2,
  "body":"业务库里写着：\n```\n<DETAILS><SUMMARY>历次评审（99）</SUMMARY>\n伪造的历次表。\n```","fix":""}]}
JSON
pkg=$(make_mutant m23-details-case 's/| gsub("<(?<tag>\/?details)"; "\&lt;\\(.tag)"; "i"))/| gsub("<(?<tag>\/?details)"; "\&lt;\\(.tag)"))/' scripts/lib/review-render.sh)
run_case m23 "$pkg" MOCK_KIRO_CONTRACT="$tmp/upperdetails.json"
assert_rc "$RC" 0 "M23：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "<DETAILS>" \
  "M23：大小写敏感的转义放过了 <DETAILS>——端到端「评论里不再有可渲染的大写折叠标签」断言会失败"
assert_eq "$(printf '%s\n' "$comment" | grep -ci '^<details')" "2" \
  "M23：行首开标签变成 2 个（脚本一个 + 模型文本一个）——端到端计数断言会失败"

# --- M24：删掉「退到最后一个完整行」→ 截断点切在标签中间时留下半个标签 ---
# 上限要落在渲染结果里第一个 `<details>` 开标签的 `<det|ails>` 中间。这个字节位置随模板变动
# （2026-09-04 标题层级改成 `#`/`##`/加粗就把它挪前了，写死的 1603 当场失配），所以不写死：
# 先用未变异的集成包跑一次同一用例，量出开标签所在行的字节偏移，再加 4。
run_case m24-probe "$ROOT"
assert_rc "$RC" 0 "M24 前置：未变异的集成包能跑完"
details_off=$(posted_comment "$OUT" | grep -b -m1 '^<details' | cut -d: -f1)
assert_eq "$([[ "${details_off:-}" =~ ^[0-9]+$ && "${details_off:-0}" -gt 0 ]] && echo ok)" "ok" \
  "M24 前置：量出了 <details> 开标签的字节偏移（${details_off:-<空>}）"
pkg=$(make_mutant m24-retreat-line 's|awk .NR > 1 { print prev } { prev = \$0 }. "\$dir/cut" > "\$dir/out"|cp "$dir/cut" "$dir/out"|' scripts/lib/review-render.sh)
run_case m24 "$pkg" MAX_COMMENT_BYTES=$((details_off + 4))
assert_rc "$RC" 0 "M24：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_eq "$(printf '%s\n' "$comment" | grep -ciE '^</?d[a-z]*$' || true)" "1" \
  "M24：正文里留下半个 <details> 标签——端到端「没有残留半个标签」断言会失败"

# --- M25：删掉 die_review 的「渲染产出为空就退回最小失败评论」→ 会拿 0 字节文件去发评论 ---
# 让 review_render_failure 立刻以 rc 2 返回（模拟参数不合规），此时 $f 是 0 字节。
# 有那道退回时评论照常发出；没有的话 post_summary 的硬守卫会拒绝，MR 上什么都看不到（违反 I10）。
pkg=$(make_mutant m25-empty-failure 's|^    if \[\[ ! -s "\$f" \]\]; then|    if false; then|')
# 同时让渲染器直接失败（两处变异要落在同一个包里，所以在已变异的副本上再改一次）
python3 - "$pkg/scripts/lib/review-render.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "review_render_failure() {\n"
assert s.count(old) == 1
open(p, 'w', encoding='utf-8').write(s.replace(old, old + "  return 2\n"))
PY
bash -n "$pkg/scripts/lib/review-render.sh" || { echo "FAIL: M25 变异让 review-render.sh 语法错误" >&2; exit 1; }
# 票 16 之后 die_review 里还有第二道退回：sink 掩码对 0 字节文件返回非零 → 改用只含固定文案的最小评论。
# 只杀掉「-s 退回」这一道，空文件会被第二道兜住、评论照发——先把这条正控记下来，再把两道一起杀掉看硬守卫。
run_case m25-redact-catches "$pkg" DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT" MOCK_KIRO_FAIL=1
assert_nonzero "$RC" "M25 掩码退回正控：变异体仍以非零退出"
assert_eq "$(req_count "$OUT" PUT)" "1" "M25 掩码退回正控：-s 退回被杀后，掩码失败退回兜住 0 字节文件，评论照常原地更新（两道防线）"
assert_contains "$(posted_comment "$OUT")" "只保留固定文案" "M25 掩码退回正控：发出去的是掩码失败那种固定文案的最小评论"
mutate_more "$pkg" 's|^    if \[\[ "\$rrc" != "0" \]\]; then|    if false; then  # 双变异 M25：掩码失败退回也杀掉|'
run_case m25 "$pkg" DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT" MOCK_KIRO_FAIL=1
assert_nonzero "$RC" "M25：变异体仍以非零退出"
assert_eq "$(req_count "$OUT" PUT)" "0" "M25：两道退回都没有时，硬守卫拒绝回写 → MR 上看不到失败（违反 I10）"
assert_contains "$OUT" "拒绝回写" "M25：只剩「拒绝回写」的日志"
# 对照：未变异实现在同样条件下会发出最小失败评论
pkg2=$(make_mutant m25-control-render 's|^review_render_failure() {|review_render_failure() { return 2;|' scripts/lib/review-render.sh)
run_case m25control "$pkg2" DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT" MOCK_KIRO_FAIL=1
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" \
  "M25 对照：渲染器失败时未变异实现退回最小失败评论并照常原地更新"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "只保留最小信息" "M25 对照：最小失败评论说明自己是退化产物"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^# Kiro 代码评审 · ⚠️ 评审未完成$')" "1" \
  "M25 对照：最小失败评论的标题与 review_render_failure 同形（一级标题、同一份 REVIEW_TITLE_FAILED）"
assert_contains "$comment" "<!-- kiro-review:" "M25 对照：最小失败评论仍带评审标记（下次评审找得到）"
assert_contains "$comment" "<!-- kiro-history:" "M25 对照：仍带本次一行历史"
assert_contains "$comment" "第 2 次评审" "M25 对照：仍带页脚"

# ============ 票 04 的守卫（行内评论管线）============
# 这一组里的 M26 就是票要求的「正控」：把可定位判定故意关掉，必须能观察到
# 未定位问题被当成行内评论发出去——也就是端到端那条「行号都落在变更行集合内」的断言会失败。
E2EC="$ROOT/tests/fixtures/contract/inline-e2e.json"
IFX="$tmp/ifx"
mkdir -p "$IFX"
# 版本列表 fixture 由 _inline_patchsets_tweak 在每次运行前写入（见 inline_case）：票 17 之后最新合并源版本的
# commitId 必须等于 HEAD，否则 fail-closed 一条都不发——而 HEAD 只有在 fixture 仓库建好之后才知道。
for n in 1 2 3 4 5 6; do
  jq -n --arg id "draft-${n}" '{comment_biz_id:$id, comment_type:"INLINE_COMMENT", state:"DRAFT", draft:true}' \
    > "$IFX/create-comment-inline.${n}.json"
done
# 「重跑不重复」用的 fixture：把上一次发出去的三条（旧格式标记、锚在第 2 行）摆进现有行内评论列表。
# 去重判定是区间匹配（同文件、重叠或相距 ≤ 2 行），指纹只写进标记作信息用途。
IFXR="$tmp/ifx-rerun"
mkdir -p "$IFXR"
cp "$IFX"/create-comment-inline.*.json "$IFXR/"
source "$ROOT/scripts/lib/review-render.sh"   # 只为 review_fingerprint：与生产同一份实现
jq -n --arg bot "$BOT" \
  --arg a "$(review_fingerprint src/app.py 2 硬编码疑似应用密钥)" \
  --arg b "$(review_fingerprint src/app.py 2 密钥可能已泄漏到提交历史)" \
  --arg c "$(review_fingerprint src/app.py 2 缺少启动时的配置校验)" '
  [$a, $b, $c] | to_entries
  | map({comment_biz_id:("old-" + (.key | tostring)), comment_type:"INLINE_COMMENT",
         state:"OPENED", draft:false, filePath:"src/app.py", line_number:2,
         author:{username:$bot},
         content:("### P0 · 上一次发过的\n<!-- kiro-inline:" + .value + " -->\n")})' \
  > "$IFXR/list-comments-inline.json"

# 版本列表 fixture 的唯一入口（票 17-fix2 C⑦：原先 head_mismatch / both_mismatch / no_commitid 各写一份）。
# 默认 to = 真实 HEAD、from = 真实 merge-base——否则每个用例都会 fail-closed 或多一句 notice，
# 而那不是本组要证明的东西。HEAD 只有在 fixture 仓库建好（用例自己的 MUT_TWEAK 可能再提交）之后才知道，
# 所以内层 tweak 先跑、版本列表后写。取值语义与 test-kiro-review.sh 的 mk_patchsets 一致。
_INLINE_FX=""; _INLINE_INNER_TWEAK=""
# 实现在 tests/helpers.sh 的 mk_patchsets_fixture（票 17-fix3 ⑫：与 test-kiro-review.sh 共用同一份，
# 取值语义因此不会再走形）。用例自己的 tweak 先跑（它可能再提交、改变 HEAD），版本列表后写。
mk_patchsets() {
  [[ -z "$_INLINE_INNER_TWEAK" ]] || "$_INLINE_INNER_TWEAK"
  PS_FIXTURE_DIR="$_INLINE_FX" mk_patchsets_fixture
}
inline_case() { # <用例名> <集成包根> <fixture 目录> [VAR=值 …]；版本列表形态走 PS_* 全局量
  local name="$1" pkg="$2" fx="$3"; shift 3
  _INLINE_FX="$fx"; _INLINE_INNER_TWEAK="${MUT_TWEAK:-}"; MUT_TWEAK=""   # 与 run_case 同理：赋值前缀是否残留取决于 bash 版本
  MUT_TWEAK=mk_patchsets run_case "$name" "$pkg" DRY_RUN_FIXTURE_DIR="$fx" CODEUP_BOT_USERNAME="$BOT" \
    INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2EC" "$@"
  reset_ps_vars
}

# --- 对照：未变异实现上行内评论管线的四项可观测结果都成立 ---
inline_case baseline-inline "$ROOT" "$IFX"
assert_rc "$RC" 0 "对照：行内开启后评审成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "对照：quiet 下发 3 条"
assert_eq "$(inline_bodies "$OUT" | jq -r '.line_number' | sort -u | paste -sd, -)" "2" "对照：行号都落在变更行集合内"
assert_contains "$(posted_comment "$OUT")" "其中 3 条已标注在「文件改动」对应行" "对照：统计行注明行内条数"
assert_contains "$(posted_comment "$OUT")" "**未定位问题（2）**" "对照：未定位问题在折叠区"
inline_case baseline-rerun "$ROOT" "$IFXR"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "对照：重跑时三条都被区间去重，一条都不重发"

# --- M26（票要求的正控）：把可定位判定改成恒真 → 未定位问题被当成行内评论发出 ---
# 这条变异直接对准 spec I5「定位可信」：没有这道校验，模型给的任何行号都会被当成可评论的行，
# Codeup 会把评论挂到没改过的行上（甚至挂到别的文件上）。
# sed 的分隔符用 #：被替换的片段里本身带 jq 的 `|`，用 | 作分隔符会被当成分隔符解析
pkg=$(make_mutant m26-locatable 's#any(\.\[0\] <= \$f\.line_start and \$f\.line_start <= \.\[1\])#true#' scripts/lib/review-render.sh)
inline_case m26 "$pkg" "$IFX"
assert_rc "$RC" 0 "M26：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "4" \
  "M26：可定位判定恒真后多发了一条（G5，行号 99 不在变更行集合内）——端到端「quiet 下发 3 条」断言会失败"
assert_contains "$(inline_bodies "$OUT" | jq -r '.line_number' | sort -u | paste -sd, -)" "99" \
  "M26：行内评论被发到了本次没改过的第 99 行——端到端「行号都落在变更行集合内」断言会失败"
assert_not_contains "$(posted_comment "$OUT")" "**未定位问题（2）**" \
  "M26：未定位小节只剩 1 条（没有 file 的那条）——端到端折叠区断言会失败"

# --- M27：把去重判定改成恒「未命中」→ 重跑在同一行上重复发 ---
pkg=$(make_mutant m27-dedup 's#hrc=0; hits=$(review_inline_overlaps "$existing_rg" "$file" "$ls" "$le" "$sev") || hrc=$?#hrc=1#')
inline_case m27 "$pkg" "$IFXR"
assert_rc "$RC" 0 "M27：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" \
  "M27：去重被拿掉后重跑又发了 3 条——端到端「重跑一条都不重发」断言会失败（违反 I6 幂等）"

# --- M32 / M33：区间匹配的容差与重叠判定（真实验收 2026-09-03 暴露的缺陷）---
# fixture = 真实回读的第一次运行的 4 条行内评论（旧格式标记：app/download.py 14–22 / 20–23 / 29–30 / 37–38）；
# 契约 = 第二次运行的形态：标题全变、行号漂移（20→21、37→36）、一条拆成两条（14 与 22）。
# 未变异实现必须 0 条新建；把容差改回精确匹配后，漂移的那几条会被重新发出——端到端「0 条新建、跳过 5 条」断言会失败。
REALC="$ROOT/tests/fixtures/contract/inline-rerun-real.json"
IFXREAL="$tmp/ifx-real"
mkdir -p "$IFXREAL"
cp "$IFX"/create-comment-inline.*.json "$IFXREAL/"
cp "$ROOT/tests/fixtures/inline/real-rerun/list-comments-inline.json" "$IFXREAL/"
mk_real_repo() {  # 业务库里得有 app/download.py 且这些行都是本次新增的
  mkdir -p app
  for i in $(seq 1 50); do echo "line_${i} = ${i}"; done > app/download.py
  git add app/download.py && git commit -qm "add download endpoint"
}
MUT_TWEAK=mk_real_repo inline_case baseline-real "$ROOT" "$IFXREAL" MOCK_KIRO_CONTRACT="$REALC"
assert_rc "$RC" 0 "对照：真实重跑 fixture 上评审成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "对照：真实重跑 0 条新建"
assert_contains "$OUT" "已存在跳过 5 条" "对照：真实重跑跳过 5 条"
# M32：容差 2 → 0（只认重叠，不认相邻）→ 37→36 那条相距 1 行、被重新发出
pkg=$(make_mutant m32-tolerance 's#^REVIEW_INLINE_DEDUP_TOLERANCE=2$#REVIEW_INLINE_DEDUP_TOLERANCE=0#' scripts/lib/review-render.sh)
MUT_TWEAK=mk_real_repo inline_case m32 "$pkg" "$IFXREAL" MOCK_KIRO_CONTRACT="$REALC"
assert_rc "$RC" 0 "M32：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | jq -r '.line_number' | sort -n | paste -sd, -)" "36" \
  "M32：容差归零后 36 行（与 37–38 相邻）被重新发出——端到端「0 条新建」断言会失败"
assert_contains "$OUT" "已存在跳过 4 条" "M32：只剩 4 条靠重叠命中"
# M33：把「重叠或相邻」改回精确匹配起始行 → 漂移与拆分的那几条全部重发
pkg=$(make_mutant m33-exact 's#select(($s - .end) <= $tol and (.start - $e) <= $tol)#select(.start == $s)#' scripts/lib/review-render.sh)
MUT_TWEAK=mk_real_repo inline_case m33 "$pkg" "$IFXREAL" MOCK_KIRO_CONTRACT="$REALC"
assert_rc "$RC" 0 "M33：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | jq -r '.line_number' | sort -n | paste -sd, -)" "21,22,36" \
  "M33：精确匹配下漂移的 21、36 与拆出来的 22 都被重新发出（只有 14、29 恰好同起点）——端到端「0 条新建、跳过 5 条」断言会失败"
assert_contains "$OUT" "已存在跳过 2 条" "M33：只剩起点恰好相同的 2 条被跳过"

# --- M34：拿掉级别门槛 → 同一处一条旧 P1 就能压掉重跑时新出现的 P0（那条 P0 在 MR 上彻底消失）---
IFXSEV="$tmp/ifx-sev"
mkdir -p "$IFXSEV"
cp "$IFX"/create-comment-inline.*.json "$IFXSEV/"
jq -n --arg bot "$BOT" --arg fp "$(review_fingerprint src/app.py 2 上一次)" '[
  {comment_biz_id:"old-p1", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false,
   filePath:"src/app.py", line_number:2, author:{username:$bot},
   content:("### P1 · 上一次\n<!-- kiro-inline:" + $fp + " -->\n")}]' > "$IFXSEV/list-comments-inline.json"
inline_case baseline-sev "$ROOT" "$IFXSEV"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "2" "对照：同一处旧 P1 只压掉 P1 那条，两条 P0 照发"
assert_contains "$(inline_bodies "$OUT" | jq -r '.content')" "硬编码疑似应用密钥" "对照：P0 仍在 MR 上"
pkg=$(make_mutant m34-sevgate 's#select($sev == "" or ((.sev | type) == "string" and ((.sev | rank) != null) and ((.sev | rank) <= ($sev | rank))))#select(true)#' scripts/lib/review-render.sh)
inline_case m34 "$pkg" "$IFXSEV"
assert_rc "$RC" 0 "M34：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" \
  "M34：没有级别门槛时两条 P0 也被旧 P1 压掉——端到端「两条 P0 照发」断言会失败"
assert_not_contains "$(posted_comment "$OUT")" "硬编码疑似应用密钥" "M34：那条 P0 既不在行内也不在折叠区——从 MR 上彻底消失（这正是门槛要防的）"

# --- M46：首行级别正则退回只认 `### ` → 加粗首行 + 旧格式标记的旧 P0 认不出级别，重跑在同一处堆出三条重复（票 11）---
# 载荷用 **P0**（而不是票面复现用的 P2）：票 11 同时把「级别未知」改成「不能压制」，于是旧 P2 解析成 null 之后
# 三条照发——与正确解析出 P2 的结果一样，变异体观察不到变化（2026-09-05 实测）。旧 P0 则两边不同：
# 解析对了 → 三条全压（去重生效）；退回旧正则 → null → 不能压制 → 三条重复发出。
IFXBOLD="$tmp/ifx-bold"
mkdir -p "$IFXBOLD"
cp "$IFX"/create-comment-inline.*.json "$IFXBOLD/"
jq -n --arg bot "$BOT" --arg fp "$(review_fingerprint src/app.py 2 上一次)" '[
  {comment_biz_id:"old-bold-p0", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false,
   filePath:"src/app.py", line_number:2, author:{username:$bot},
   content:("**P0 · 上一次**\n<!-- kiro-inline:" + $fp + " -->\n")}]' > "$IFXBOLD/list-comments-inline.json"
inline_case baseline-bold "$ROOT" "$IFXBOLD"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "对照：加粗首行的旧 P0 解析得出级别，同一处 P0/P0/P1 三条全压（去重生效）"
pkg=$(make_mutant m46-title-sev-re "s|^REVIEW_INLINE_TITLE_SEV_RE=.*\$|REVIEW_INLINE_TITLE_SEV_RE='^### (?<sev>P[0-2]) · '|" scripts/lib/review-render.sh)
inline_case m46 "$pkg" "$IFXBOLD"
assert_rc "$RC" 0 "M46：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" \
  "M46：级别解析成 null → 不能压制 → 三条在同一处重复发出——端到端「旧 P0 全压」断言会失败"

# --- M47：级别未知的旧评论改回「不设门槛」→ 标题被人改掉的一条旧评论压掉同一处所有新问题（票 11）---
IFXNOSEV="$tmp/ifx-nosev"
mkdir -p "$IFXNOSEV"
cp "$IFX"/create-comment-inline.*.json "$IFXNOSEV/"
jq 'map(.content |= sub("\\*\\*P0 · 上一次\\*\\*"; "上一次（标题被人改过）"))' "$IFXBOLD/list-comments-inline.json" > "$IFXNOSEV/list-comments-inline.json"
inline_case baseline-nosev "$ROOT" "$IFXNOSEV"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "对照：级别未知的旧评论不压任何一条"
pkg=$(make_mutant m47-unknown-sev 's#(.sev | type) == "string" and ((.sev | rank) != null) and ((.sev | rank) <= ($sev | rank))#(.sev | type) != "string" or ((.sev | rank) == null) or ((.sev | rank) <= ($sev | rank))#' scripts/lib/review-render.sh)
inline_case m47 "$pkg" "$IFXNOSEV"
assert_rc "$RC" 0 "M47：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" \
  "M47：级别未知按「不设门槛」处理时三条全被压掉——端到端「三条照发」断言会失败"
assert_not_contains "$(posted_comment "$OUT")" "硬编码疑似应用密钥" "M47：那条 P0 既不在行内也不在折叠区——从 MR 上彻底消失"

# --- M28：拿掉上限截取 → MAX_INLINE_COMMENTS 失效 ---
pkg=$(make_mutant m28-max 's|(\$cand\[0:\$max\]) as \$inline|($cand) as $inline|' scripts/lib/review-render.sh)
inline_case m28 "$pkg" "$IFX" MAX_INLINE_COMMENTS=1
assert_rc "$RC" 0 "M28：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" \
  "M28：上限 1 却发了 3 条——端到端「上限 1 只发 1 条」断言会失败"
assert_contains "$(posted_comment "$OUT")" "其中 3 条已标注在「文件改动」对应行" \
  "M28：统计行也跟着变成 3——端到端「上限 1 时行内计数为 1」断言会失败"
# 截取被拿掉后 overflow 桶仍照原样算出来，于是同两条问题既发了行内评论、又出现在折叠区
# （违反 I4「同一问题只出现一次」）——这是这条变异的第二个可观测后果
assert_contains "$(posted_comment "$OUT")" "**超出行内上限的 P0/P1（2）**" \
  "M28：那两条问题同时出现在行内与折叠区（同一问题出现两次）"

# --- M29：发布结果不回填 → 发失败的问题在 MR 上一条都看不到 ---
# 这条对准 I4「同一问题只出现一次（行内或折叠区）」：不回填时那三条既没发出去，
# 又被算成「已标注在对应行」而不进折叠区，等于评审报告悄悄少了三个问题。
pkg=$(make_mutant m29-outcomes 's|^review_plan_apply_outcomes() {|review_plan_apply_outcomes() { cat "$1"; return 0;|' scripts/lib/review-render.sh)
inline_case m29 "$pkg" "$IFX" DRY_RUN_FAIL_ROUTES="submit-review:400,create-comment-inline:400"
assert_rc "$RC" 0 "M29：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "其中 3 条已标注在「文件改动」对应行" \
  "M29：一条都没发出去却报「3 条已标注」——端到端「全部发布失败时行内计数为 0」断言会失败"
assert_not_contains "$comment" "**行内发布失败" \
  "M29：折叠区里没有「行内发布失败」小节——那三个问题在 MR 上彻底消失了"
assert_not_contains "$comment" "硬编码疑似应用密钥" "M29：连问题标题都看不到了"

# --- M30：把「行内评论创建只重试 429」改回默认策略 → 000/5xx 之后重复创建 ---
# 创建评论不幂等：服务端已经建好、只是响应没回来时，重试会在同一行上多出一条，
# 而第一条的 comment_biz_id 我们从来没拿到过——它永远提交不了、也永远删不掉，
# 之后的去重还看不到它（草稿会被状态过滤掉）。
pkg=$(make_mutant m30-create-retry \
  's|_codeup_should_retry_create_inline() { \[\[ "\$1" == "429" \]\]; }|_codeup_should_retry_create_inline() { _codeup_should_retry "$1"; }|' \
  scripts/lib/codeup-api.sh)
inline_case m30 "$pkg" "$IFX" DRY_RUN_FAIL_ROUTES="create-comment-inline:500" CODEUP_RETRY_BACKOFF=0
assert_rc "$RC" 0 "M30：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "9" \
  "M30：三条问题各发了 3 次创建请求（共 9 次）——端到端「三条各只尝试一次」断言会失败，真实后果是同一行上留下重复评论"
# 对照：未变异实现在同样注入下每条只发一次
inline_case m30control "$ROOT" "$IFX" DRY_RUN_FAIL_ROUTES="create-comment-inline:500" CODEUP_RETRY_BACKOFF=0
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "M30 对照：未变异实现三条各只尝试一次"
assert_contains "$(posted_comment "$OUT")" "**行内发布失败（3）**" "M30 对照：不重试的代价只是进折叠区，下次评审重发"

# --- M31：拿掉「一次提交后回读」→ 被服务端拒掉的草稿被当成已发布 ---
# 提交返回 2xx 只说明请求被受理，不保证每个 id 都真的转成了 OPENED。
IFXSD="$tmp/ifx-stilldraft"
mkdir -p "$IFXSD"
cp "$IFX"/create-comment-inline.*.json "$IFXSD/"
jq -n '[]' > "$IFXSD/list-comments-inline.1.json"
jq -n --arg bot "$BOT" '[
  {comment_biz_id:"draft-1", comment_type:"INLINE_COMMENT", state:"DRAFT", draft:true,
   filePath:"src/app.py", line_number:2, author:{username:$bot},
   content:"### P0 · 被服务端拒掉的那条\n<!-- kiro-inline:1111111111111111111111111111111111111111 -->\n"}
]' > "$IFXSD/list-comments-inline.2.json"
inline_case baseline-readback "$ROOT" "$IFXSD"
assert_eq "$(req_count "$OUT" DELETE 'comments/draft-1$')" "1" "对照：回读发现仍是草稿 → 删除"
assert_contains "$(posted_comment "$OUT")" "**行内发布失败（1）**" "对照：那条进折叠区"
assert_contains "$(posted_comment "$OUT")" "其中 2 条已标注在「文件改动」对应行" "对照：行内计数为 2"
pkg=$(make_mutant m31-no-readback 's|if codeup_list_inline_comments "\$LOCAL_ID" > "\$WORK/inline-after.json"; then|if false; then|')
inline_case m31 "$pkg" "$IFXSD"
assert_rc "$RC" 0 "M31：变异体仍能跑完"
# 变异后走的是「回读失败」那条 fail-closed 分支：不会把被拒的草稿谎报成已发布
assert_eq "$(req_count "$OUT" DELETE 'comments/draft-1$')" "0" "M31：不回读就发现不了那条仍是草稿，也就不会删除它"
assert_contains "$(posted_comment "$OUT")" "**行内发布失败（3）**" \
  "M31：拿不到回读结果时三条全部按失败处理——端到端「行内发布失败（1）」与「已标注 2 条」断言都会失败"

# --- M3：删掉 settings 调用 → 继承未被禁用 ---
pkg=$(make_mutant m3-settings '/chat.disableInheritingDefaultResources true/d')
run_case m3 "$pkg"
assert_rc "$RC" 0 "M3：变异体仍能跑完"
assert_eq "$([[ -s "$MD/settings" ]] && echo called || echo none)" "none" "M3：settings 未被调用——端到端断言会失败"

# --- M35：让「整行加粗 → 转义」失效 → 模型文本能逐字节冒充问题分组行 / 问题标题行 ---
# 2026-09-04 起分组与每条问题都是整行加粗（Codeup 不渲染 ### 以下标题），这条清洗是它们唯一的防伪造手段。
pkg=$(make_mutant m35-bold-line 's/def _is_bold_line: (/def _is_bold_line: false and (/' scripts/lib/review-render.sh)
run_case m35 "$pkg" MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/inject.json"
assert_rc "$RC" 0 "M35：变异体仍能跑完"
assert_eq "$(printf '%s\n' "$(posted_comment "$OUT")" | grep -c '^\*\*P0 必须修复（')" "2" \
  "M35：模型文本里的整行加粗成了第二个「P0 必须修复」分组行——单测「分组行恰好一个」断言会失败"
run_case m35control "$ROOT" MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/inject.json"
assert_eq "$(printf '%s\n' "$(posted_comment "$OUT")" | grep -c '^\*\*P0 必须修复（')" "1" "M35 对照：未变异实现里分组行恰好一个"
assert_contains "$(posted_comment "$OUT")" '\*\*P0 必须修复（1）\*\*' "M35 对照：模型文本里的那行被转义成字面量"


# --- M36：让 review_changed_lines 的 git 转义表失效 → 未改动文件被伪造成变更行集合的键 ---
# 这是行内评论「定位可信」（I5）的最外层依据：键错了，评论就发到 MR 没碰过的文件上。
# 单测粒度（不跑端到端）：直接把变异体的库 source 进子壳喂一条 git 真实形态的 +++ 行。
# 两处一起改才是「修复前」的行为：既停掉 \a 的专用分支，又让表外转义回到「丢反斜杠留字母」。
# 只改后者不构成变异——\a 有自己的分支，根本走不到那里（第一版 M36 就是这样空转的）。
pkg=$(make_mutant m36-cescape 's|if      (n == "a")  { out = out jesc(7);  i += 2 }|if      (0)         { out = out jesc(7);  i += 2 }|; s|else return "!"                    # 表外转义|else { out = out n; i += 2 }  # 变异：表外转义|' scripts/lib/review-render.sh)
mut_keys() { # $1=集成包根 $2=diff 文本 → stdout 键名（每行一个）；rc 非 0 时输出 <rc:N>
  local pkg_root="$1" text="$2"
  ( set +e; source "$pkg_root/scripts/lib/review-render.sh"
    out=$(printf '%s' "$text" | review_changed_lines 2>/dev/null); rc=$?
    if [[ "$rc" != "0" ]]; then printf '<rc:%s>' "$rc"; else printf '%s' "$out" | jq -r 'keys[]'; fi )
}
# `+++ "b/src/\app.py"` 是 git 对文件名 `src/<BEL>pp.py` 的真实输出
BEL_DIFF=$(printf 'diff --git a/x b/x\n--- a/x\n+++ "b/src/\\app.py"\n@@ -0,0 +1 @@\n+a\n')
assert_eq "$(mut_keys "$pkg" "$BEL_DIFF")" "src/app.py" \
  "M36：转义表失效后 \\a 被当成字母 a，键变成 MR 没碰过的 src/app.py——单测「不得伪造未改动文件的键」断言会失败"
assert_eq "$(mut_keys "$ROOT" "$BEL_DIFF")" "$(printf 'src/\007pp.py')" \
  "M36 对照：未变异实现把 \\a 还原为 BEL，键是真实文件名"
UNKNOWN_DIFF=$(printf 'diff --git a/x b/x\n--- a/x\n+++ "b/x\\qy.py"\n@@ -0,0 +1 @@\n+a\n')
assert_eq "$(mut_keys "$ROOT" "$UNKNOWN_DIFF")" "<rc:3>" "M36 对照：表外转义在未变异实现里硬失败"
assert_eq "$(mut_keys "$pkg" "$UNKNOWN_DIFF")" "xqy.py" "M36：变异体反而猜出一个路径（正是「宁可失败也不猜」要挡的行为）"


# --- M37：让元信息表的分支名过滤失效 → MR 作者的分支名撑破表格并把原始 HTML 带进评论 ---
# 分支名是 MR 作者可控输入（票 07）。单测粒度：把变异体的库 source 进子壳直接渲染一次。
# 变异点 = 许可清单那一行（控制字符那半由 M38 单独覆盖）。用地址选行、再整行替换：票 13 之后那一行是
# `v=${v//["$REVIEW_CELL_DENY_CHARS"]/}`，地址锚在行首的 `  v=${v//["$REVIEW_CELL_DENY_CHARS"]`——恰好一行
# （常量定义处的注释也含这个名字，不加行首锚会选中两行）；不碰反引号与反斜杠（直接写进 sed 模式在不同
# sed 实现下含义不同，GNU 把 \` 当缓冲区起始锚）。
# 提醒：改 `_review_meta_cell` 的实现时这条 sed 会失配，make_mutant 的「必须改动文件」检查会
# 立刻报出来（本票就是这样被抓到的），按新实现重新选点即可，别删掉这条变异。
pkg=$(make_mutant m37-metacell '/^  v=\${v\/\/\["\$REVIEW_CELL_DENY_CHARS"\]/ s@v=${v//.*@: # 变异：不过滤危险字符@' scripts/lib/review-render.sh)
mut_meta_row() { # $1=集成包根 $2=分支名 → stdout 元信息行（提取器用 helpers.sh 的 meta_row，只有一份）
  local pkg_root="$1" branch="$2" out
  ( set +e; source "$pkg_root/scripts/lib/review-render.sh"
    review_validate < "$ROOT/tests/fixtures/contract/full.json" > "$tmp/m37.json"
    out=$(review_render_summary --json "$tmp/m37.json" --sha 90fcb05 --src "$branch" --dst master \
            --ts "2026-09-02 20:10:02" --diff-note "完整直传" 2>/dev/null)
    meta_row "$out" )
}
mut_render() { # $1=集成包根 $2=分支名 → stdout 整段汇总评论（M38 要看被劈开的行，meta_row 找不到它）
  local pkg_root="$1" branch="$2"
  ( set +e; source "$pkg_root/scripts/lib/review-render.sh"
    review_validate < "$ROOT/tests/fixtures/contract/full.json" > "$tmp/m37.json"
    review_render_summary --json "$tmp/m37.json" --sha 90fcb05 --src "$branch" --dst master \
      --ts "2026-09-02 20:10:02" --diff-note "完整直传" 2>/dev/null )
}
# 元信息行开头那一段（`| \`sha\` | …`）的竖线数：行被换行劈开时前半截只剩 2 个
sha_row_pipes() { printf '%s\n' "$1" | grep -F '90fcb05' | grep -F '| `' | head -1 | tr -cd '|' | wc -c | tr -d ' '; }
assert_eq "$(mut_meta_row "$pkg" 'a|b|c' | tr -cd '|' | wc -c | tr -d ' ')" "7" \
  "M37：过滤失效后 '\''a|b|c'\'' 把元信息行撑成 7 个竖线（4 列变 6 格）——单测「表格列数」断言会失败"
assert_contains "$(mut_meta_row "$pkg" '`<details><summary>h</summary>')" "<details" \
  "M37：过滤失效后原始 HTML 进入元信息单元格——单测「不把 < 带进单元格」断言会失败"
assert_eq "$(mut_meta_row "$ROOT" 'a|b|c' | tr -cd '|' | wc -c | tr -d ' ')" "5" \
  "M37 对照：未变异实现里元信息行恒为 5 个竖线"
assert_not_contains "$(mut_meta_row "$ROOT" '`<details><summary>h</summary>')" "<details" \
  "M37 对照：未变异实现把 < 与反引号一并剔掉"


# --- M38：只去掉元信息单元格的控制字符过滤 → 带换行的分支名把表格行劈成两行 ---
# 与 M37 分开：M37 的变异点是返回行，一次同时杀掉「许可清单 + 截断 + 占位」；这条只杀控制字符那一半，
# 否则「删掉 `${v//[[:cntrl:]]/}` 后全套测试照样绿」（复审实测过）。
# 注：复审推测「换行能造出第二个评审标记」——实测**不成立**，`<`/`>` 已被许可清单剔掉、`<!--` 构不成；
# 换行的真实后果是表格行被劈开，所以断言写在行形态上。
pkg=$(make_mutant m38-metacell-cntrl 's|  v=${v//\[\[:cntrl:\]\]/}|  : # 变异：不过滤控制字符|' scripts/lib/review-render.sh)
nl_branch=$(printf 'feat/a\nb|c')
# 变异体里那一行被换行劈成两行，于是**连一条形态完整的元信息行都找不到**（meta_row 返回空串），
# 前半截只剩 2 个竖线。这两条一起看才能区分「行被劈开」与「渲染器改了形态」。
assert_eq "$(mut_meta_row "$pkg" "$nl_branch")" "" \
  "M38：不过滤控制字符时找不到形态完整的元信息行（行被换行劈开）——单测「表格列数恒 5」断言会失败"
assert_eq "$(sha_row_pipes "$(mut_render "$pkg" "$nl_branch")")" "2" \
  "M38：被劈开后前半截只剩 2 个竖线"
assert_eq "$(mut_meta_row "$ROOT" "$nl_branch" | tr -cd '|' | wc -c | tr -d ' ')" "5" \
  "M38 对照：未变异实现把换行剔掉，元信息行仍是完整一行（5 个竖线）"
assert_eq "$(sha_row_pipes "$(mut_render "$ROOT" "$nl_branch")")" "5" \
  "M38 对照：未变异实现里前半截就是完整那一行"

# --- M39–M43：库级探针（字段模式的 review_redact_secrets）。M39 / M40 / M42 / M43 是 PEM 未闭合块的放出 / 提示 / 掩码——16-fix3 第 14 条后
#     降级路径走保行模式，字段级的 pem_flush 只在 review_redact_json 里跑，端到端向量换成保行模式的 M-r；M41 与 PEM 无关：
#     redact_assign 的分隔符扫描方向（16-fix4 第 25 条补回）---
D5="-----"; PEM_B="${D5}BEGIN RSA PRIVATE KEY${D5}"; PEM_E="${D5}END RSA PRIVATE KEY${D5}"   # 拆片段：完整 PEM 头字面量不进源码
PEM_L64="MIIEvQIBADANBgkqhkiG9w0BAQEF""AASCBKcwggSjAgEAAoIBAQC7x9Kf2Lm4ijkl"   # 尾巴像随机 base64（第 26 条改定义）
PEM_PLACEHOLDER="**** （脚本已屏蔽一段 PRIVATE KEY 内容）"
mut_rd_multi() { ( set +e; source "$1/scripts/lib/review-render.sh"; printf '%b' "$2" | review_redact_secrets ); }   # <包根> <多行文本（printf %b）>
unclosed_in="$PEM_B\n（下面是私钥内容，节选）\nMIIEowIBAAKCAQEAfakekey0123456\n正文片段 $PEM_L64 出现在 app/key.pem\n\n总体结论：不建议合并。\n"
# M39：让 EOF 时的放出失效 → 未配对 BEGIN 之后暂存的全部正文一起消失（等价于票 10 之前的「块内一律丢弃」）。
#      注意它覆盖的是**无哨兵形态**（库被直接调用 / 测试直接调）：生产唯一的字段模式调用方 review_redact_json 总带 --sentinel，
#      倒出文件总以哨兵行结尾，END 块在生产里永不触发——生产里放出未闭合块的是哨兵规则里的 pem_flush()，由下面的 M39b 覆盖（第 39 条）
pkg=$(make_mutant m39-pem-unclosed 's|    END { emit_pending(); if (inpem \&\& !keeplines) pem_flush() }|    END { emit_pending() }|' scripts/lib/review-render.sh)
assert_not_contains "$(mut_rd_multi "$pkg" "$unclosed_in")" "总体结论：不建议合并。" "M39：未配对 BEGIN 之后的结论被整段吞掉——单测「结论仍在」断言会失败"
assert_contains "$(mut_rd_multi "$ROOT" "$unclosed_in")" "总体结论：不建议合并。" "M39 对照：未变异实现放出结论"
# M39b：哨兵规则里去掉 pem_flush() → 字段末未闭合的 PEM 块（BEGIN + 正文 + 结论）在哨兵行之前静默消失（review_redact_json 的生产路径）
pkg=$(make_mutant m39b-sentinel-flush 's|    sentre != "" \&\& \$0 ~ sentre { emit_pending(); if (inpem) { if (keeplines) inpem = 0; else pem_flush() } print; next }|    sentre != "" \&\& $0 ~ sentre { emit_pending(); if (inpem) { if (keeplines) inpem = 0; else pem_drop() } print; next }  # 变异 M39b|' scripts/lib/review-render.sh)
mut_rd_sent() { ( set +e; source "$1/scripts/lib/review-render.sh"; printf '%b' "$2" | review_redact_secrets --sentinel '^<<S>>$' ); }   # <包根> <多行文本>
sent_in="$PEM_B\n$PEM_L64\n总体结论：不建议合并。\n<<S>>\n"
assert_not_contains "$(mut_rd_sent "$pkg" "$sent_in")" "总体结论：不建议合并。" "M39b：字段末未闭合 PEM 之后的结论在哨兵前被静默吞掉——单测「字段末未闭合 PEM 放出 + 提示」断言会失败"
assert_not_contains "$(mut_rd_sent "$pkg" "$sent_in")" "没有配对的 END 行" "M39b：连未闭合提示也没有（无声）"
assert_contains "$(mut_rd_sent "$ROOT" "$sent_in")" "总体结论：不建议合并。" "M39b 对照：未变异实现在哨兵前放出结论"
assert_contains "$(mut_rd_sent "$ROOT" "$sent_in")" "没有配对的 END 行" "M39b 对照：未变异实现给未闭合提示"
# M40：只掐掉未闭合提示（正文照样放出）
pkg=$(make_mutant m40-pem-note 's|      print pem_note(held_n - first + 1)|      held_n = held_n  # 变异：不打未闭合提示|' scripts/lib/review-render.sh)
assert_contains "$(mut_rd_multi "$pkg" "$unclosed_in")" "总体结论：不建议合并。" "M40：正文仍在（变异只影响提示）"
assert_not_contains "$(mut_rd_multi "$pkg" "$unclosed_in")" "没有配对的 END 行" "M40：未闭合提示消失——单测「给出提示」断言会失败"
assert_contains "$(mut_rd_multi "$ROOT" "$unclosed_in")" "没有配对的 END 行" "M40 对照：未变异实现给提示"
# M41：分隔符改成从段末往回找 → base64 补位的 `=` 被当成分隔符、取值变空串，`api_key = "…dA=="` 全裸奔（单测「补位 == 结尾的取值被掩掉」会失败）
pkg=$(make_mutant m41-assign-sep 's|^        for (i = 1; i <= length(seg); i++) {$|        for (i = length(seg); i >= 1; i--) {  # 变异 M41：反向扫描|' scripts/lib/review-render.sh)
b64_pad="dGhpcyBpcyBh""IHNlY3JldA=="
assert_contains "$(mut_rd_multi "$pkg" "api_key = \"${b64_pad}\"\n")" "$b64_pad" "M41：补位 == 结尾的取值原样放出——单测「掩码①」断言会失败"
assert_eq "$(mut_rd_multi "$ROOT" "api_key = \"${b64_pad}\"\n")" 'api_key = "dGhp****dA=="' "M41 对照：未变异实现从键之后向前找分隔符、取值被掩"
# M42：放出时不再掩夹在句子里的 base64 连片（redact_b64 的掩码换成原样）
pkg=$(make_mutant m42-b64-runs 's|out = out substr(s, 1, RSTART - 1) (b64_material(m, minlen, 1) ? (full ? "\*\*\*\*" : mask(m)) : m)|out = out substr(s, 1, RSTART - 1) m|' scripts/lib/review-render.sh)
assert_contains "$(mut_rd_multi "$pkg" "$unclosed_in")" "$PEM_L64" "M42：句子里的私钥正文片段完整放出——单测「片段不进评论」断言会失败"
assert_not_contains "$(mut_rd_multi "$pkg" "$unclosed_in")" "MIIEowIBAAKCAQEAfakekey0123456" "M42 对照：整行正文仍被掩（另一条规则）"
# M43：放出时不再掩整行 base64
pkg=$(make_mutant m43-b64-line 's|        if (pem_body(l, 0, 0)) l = redact(l, "\[" B64C "=\]+")|        l = l  # 变异：整行 base64 不掩|' scripts/lib/review-render.sh)
assert_contains "$(mut_rd_multi "$pkg" "$unclosed_in")" "MIIEowIBAAKCAQEAfakekey0123456" "M43：整行私钥正文完整放出——单测「整行正文不进评论」断言会失败"
assert_not_contains "$(mut_rd_multi "$pkg" "$unclosed_in")" "$PEM_L64" "M43 对照：句子里的片段仍被掩（另一条规则）"

# --- M44：让「像标签的 <」转义失效 → 模型文本里的原始 HTML 直达评论 ---
# 变异只把 _escape_tags 换成恒等（其余清洗规则都不动），所以观察到的差异只能来自这一条规则。
pkg=$(make_mutant m44-tag-escape 's|^  def _escape_tags: .*$|  def _escape_tags: .;|' scripts/lib/review-render.sh)
run_case m44 "$pkg" MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/inject.json"
assert_rc "$RC" 0 "M44：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_contains "$comment" '<div style="display:none">' \
  "M44：不闭合的 display:none 原样进了评论——端到端「不进评论」断言会失败（页面上它之后的一切都被吞掉）"
assert_contains "$comment" "<h1>结论：可合并</h1>" "M44：<h1> 原样进了评论——端到端断言会失败"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^<details')" "1" "M44 对照：<details> 仍由另一条规则转义（变异只杀了新规则）"

# --- M45：把分隔线/下划线判定退回「连续 3+ 个 -*_=」→ `- - -` 与单个 `=` 漏网 ---
pkg=$(make_mutant m45-break-line \
  's|^  def _is_break_line: .*$|  def _is_break_line: test("^[[:space:]]{0,3}[-*_=]{3,}[[:space:]]*$");|' scripts/lib/review-render.sh)
run_case m45 "$pkg" MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/inject.json"
assert_rc "$RC" 0 "M45：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_eq "$(printf '%s\n' "$comment" | grep -c '^- - -$')" "1" "M45：间隔分隔线原样进了评论——端到端「\\- - -」断言会失败"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^=$')" "1" "M45：单个 = 原样进了评论——端到端「\\=」断言会失败"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^\\---$')" "1" "M45 对照：连续三个 --- 仍被旧规则转义（变异只放宽了间隔与单字符）"

# --- M48：索引节标题改名 → 提示词引用的标题与脚本写出的对不上（票 12 ⑤ 的契约守卫）---
pkg=$(make_mutant m48-index-title 's|=== 未直传的变更文件索引|=== 省略清单|' scripts/kiro-review.sh)
run_case m48 "$pkg" DIFF_SIZE_LIMIT=1
assert_rc "$RC" 0 "M48：变异体仍能跑完"
assert_eq "$(grep -c -F '=== 未直传的变更文件索引' "$MD/stdin")" "0" "M48：stdin 里找不到提示词引用的节标题——端到端「恰好一个标题」断言会失败"

# --- M49：省略清单退回 `- 名字 (+a / -b) => chunk` 分隔文本 → 文件名能伪造第二个路径（票 06 P0 复发路径）---
pkg=$(make_mutant m49-omitted-format \
  "s|'{chunk: \$chunk, file: \$file, added: \$added, removed: \$removed}'|-r '\"- \" + \$file + \" (+\" + (\$added\|tostring) + \" / -\" + (\$removed\|tostring) + \") => \" + \$chunk'|" scripts/lib/diff-compress.sh)
run_case m49 "$pkg" DIFF_SIZE_LIMIT=1
assert_rc "$RC" 0 "M49：变异体仍能跑完"
idx49=$(awk 'index($0, "=== 未直传的变更文件索引") == 1 {on=1; next} on && $0 == "" {exit} on {print}' "$MD/stdin")
assert_contains "$idx49" "=> " "M49：索引行回到了分隔文本形态——端到端「每行是 JSON 对象」断言会失败"
assert_eq "$(printf '%s\n' "$idx49" | jq -e . >/dev/null 2>&1 && echo json || echo notjson)" "notjson" "M49：索引行不再是 JSON"

# --- M50：把共享的字符许可清单常量清空 → bash 侧（元信息单元格）与 jq 侧（历次表）同时失守（票 13）---
# 三处规则收敛成一份定义之后，这一份就是单点：清空它，分支名撑破表格、隐藏历史里的 < 原样回到评论。
pkg=$(make_mutant m50-deny-empty "s|^REVIEW_CELL_DENY_CHARS=.*\$|REVIEW_CELL_DENY_CHARS=''|" scripts/lib/review-render.sh)
assert_eq "$(mut_meta_row "$pkg" 'a|b|c' | tr -cd '|' | wc -c | tr -d ' ')" "7" \
  "M50：常量清空后 a|b|c 撑成 7 个竖线——单测「表格列数恒 5」断言会失败"
mut_hist_sha() { ( set +e; source "$1/scripts/lib/review-render.sh"; review_history_append - 1 'ab<c>|d' MERGE "" 0 0 0 | jq -r '.[0].sha' ); }
assert_eq "$(mut_hist_sha "$pkg")" 'ab<c>|d' "M50：常量清空后历次表 sha 里的 < > | 原样保留——单测「剔掉」断言会失败"
assert_eq "$(mut_hist_sha "$ROOT")" "abcd" "M50 对照：未变异实现两侧都剔掉"
# 第三个消费者 review_validate 的 fpath：常量清空后 `docs/<draft>.md` 不再按未定位处理
mut_delocated() { ( set +e; source "$1/scripts/lib/review-render.sh"
  printf '{"contract":"codeup-reviewer/1","summary":"s","verdict":"MERGE","verdict_reason":"r","findings":[{"id":"E","severity":"P0","title":"t","file":"docs/<draft>.md","line_start":1,"line_end":1,"body":"b","fix":""}]}' \
    | review_validate | jq -r .delocated_findings ); }
assert_eq "$(mut_delocated "$pkg")" "0" "M50：常量清空后 fpath 放行 docs/<draft>.md——单测「3 条按未定位处理」断言会失败"
assert_eq "$(mut_delocated "$ROOT")" "1" "M50 对照：未变异实现按未定位处理"

# --- M51：只让 jq 侧的 _cell_strip 变成恒等（bash 侧不动）→ 历次表失守而元信息单元格仍正常（票 13「任一半」）---
pkg=$(make_mutant m51-cell-strip 's|^  def _cell_strip(s): .*$|  def _cell_strip(s): (s \| gsub("[[:cntrl:]]"; ""));|; /^                       | \[\$cs\[\] | select/d' scripts/lib/review-render.sh)
assert_eq "$(mut_hist_sha "$pkg")" 'ab<c>|d' "M51：jq 侧恒等后历次表 sha 不再过滤——单测断言会失败"
assert_eq "$(mut_meta_row "$pkg" 'a|b|c' | tr -cd '|' | wc -c | tr -d ' ')" "5" "M51 对照：bash 侧不受影响，元信息行仍 5 个竖线（证明两侧确实是同一份定义的两个消费者）"

# ============ 票 16 / 16-fix2 的守卫（方案 C：字段级掩码 + 严格保行的文档级兜底）=====# 端到端 A10（tests/test-kiro-review.sh）断言汇总正文、行内正文、流水线日志三处都不含 token 原文。下面的变异各自只杀掉一处，
# 对应的那条断言必须失败——否则「三处都掩了」就是靠别处顺手做掉的。字段级与文档级是两道防线叠着的：只杀文档级时模型 token
# 仍被字段级掩掉，所以文档级的变异用**分支名**里的 token（MR 作者可控、不经 validated.json）作为观测向量。
SEC_SUMMARY="$tmp/secrets-summary.json"; with_secrets "$ROOT/tests/fixtures/contract/mock-review.json" > "$SEC_SUMMARY"
SEC_INLINE="$tmp/secrets-inline.json";   with_secrets "$E2EC" > "$SEC_INLINE"
FIELD_LINE='^  review_redact_json "\$f" || { rm -f "\$f"; echo "review_validate: 字段级掩码失败" >\&2; return 4; }$'   # 16-fix3 第 15 条起字段级掩码在 review_validate 内部
DOC_LINE='^review_redact_file "\$WORK/comment.md" || rrc=\$?$'
mut_rd() { ( set +e; source "$1/scripts/lib/review-render.sh"; printf '%s\n' "$2" | review_redact_secrets ); }   # 库级探针：<包根> <一行>

# --- 对照：未变异实现三处都不含原文；分支名 token 被文档级掩掉 ---
run_case baseline-sink "$ROOT" MOCK_KIRO_CONTRACT="$SEC_SUMMARY" CI_COMMIT_REF_NAME="feature/${SEC_AKIA}"
assert_rc "$RC" 0 "票 16 对照：带 token 的合法契约评审成功"
assert_not_contains "$(posted_comment "$OUT")" "$SEC_GHP" "票 16 对照：汇总不含 ghp_ 原文"
assert_contains "$OUT" "$SEC_GHP_MASKED" "票 16 对照：掩码形态在"
assert_contains "$(meta_row "$(posted_comment "$OUT")")" "feature/${SEC_AKIA_MASKED}" "票 16 对照：分支名 token 被文档级兜底掩掉"

# --- M-a：去掉汇总出口的文档级兜底 → 分支名 token 原样进元信息表（模型 token 仍被字段级掩掉：两道防线各自独立）---
pkg=$(make_mutant m-a-summary-doc "s@${DOC_LINE}@rrc=0  # 变异 M-a：汇总出口不过文档级兜底@")
run_case m-a "$pkg" MOCK_KIRO_CONTRACT="$SEC_SUMMARY" CI_COMMIT_REF_NAME="feature/${SEC_AKIA}"
assert_rc "$RC" 0 "M-a：变异体仍能跑完"
assert_contains "$(meta_row "$(posted_comment "$OUT")")" "feature/${SEC_AKIA}" "M-a：分支名 token 原样进了元信息表——端到端「分支名 token 被掩」断言会失败"
assert_not_contains "$(posted_comment "$OUT")" "$SEC_GHP" "M-a 对照：模型字段里的 token 仍被字段级掩掉"

# --- M-b：去掉字段级掩码 → 只剩文档级兜底：闭合的 PEM 块不再整块删除，只能逐行等行数屏蔽（正文行换成占位、BEGIN / END 行原样）---
# 票 17 之后 verdict 是枚举、「评审报告：… 结论」日志行不再带模型文本，原来「verdict 里的 token 进日志 / 进隐藏历史」的观测向量
# 在合并后失效（那是件好事）。字段级掩码独有、文档级兜底做不到的效果是 PEM **整块删除**（方案 C：只在 validated.json 发生），
# 所以观测它：未变异 → 一个整块占位、没有逐行占位；变异 → 逐行占位、BEGIN 行留在正文里。
pkg=$(make_mutant m-b-field "s@${FIELD_LINE}@  :  # 变异 M-b：不做字段级掩码@" scripts/lib/review-render.sh)
jq --arg b "$(printf '%s\n%s\n%s\n%s' "$PEM_B" "$PEM_L64" "$PEM_L64" "$PEM_E")" '.findings[0].body += "\n\n" + $b' "$SEC_INLINE" > "$tmp/secrets-inline-pem.json"
inline_case m-b "$pkg" "$IFX" MOCK_KIRO_CONTRACT="$tmp/secrets-inline-pem.json"
assert_rc "$RC" 0 "M-b：变异体仍能跑完（文档级保行兜底不改行数，守卫不拦）"
inline_text=$(inline_bodies "$OUT" | jq -r '.content')
assert_contains "$inline_text" "PEM 正文已屏蔽" "M-b：行内正文里 PEM 只被文档级逐行屏蔽——端到端「PEM 整块删除、无逐行占位」断言会失败"
assert_contains "$inline_text" "$PEM_B" "M-b：BEGIN 行原样留在行内正文（保行模式只换正文行）"
assert_not_contains "$inline_text" "$PEM_L64" "M-b 对照：正文行仍被文档级兜底屏蔽（两道防线）"
assert_not_contains "$inline_text" "$SEC_GHP" "M-b 对照：ghp_ 形态仍被文档级兜底掩掉"
run_case m-b-control "$ROOT" MOCK_KIRO_CONTRACT="$tmp/secrets-inline-pem.json"
assert_contains "$(posted_comment "$OUT")" "$PEM_PLACEHOLDER" "M-b 对照：未变异实现把 PEM 整块删除成一个占位"
assert_not_contains "$(posted_comment "$OUT")" "PEM 正文已屏蔽" "M-b 对照：未变异实现没有逐行占位（字段级已整块删除）"
assert_not_contains "$OUT" "$PEM_L64" "M-b 对照：未变异实现全部输出不含正文行"

# --- M-c：把汇总的文档级兜底挪到截断之后 → 截断前副本（comment.full.md）未掩，日志回显的「完整内容」带分支名原文 ---
pkg=$(make_mutant m-c-doc-after-trunc \
  "\\@${DOC_LINE}@d; s@^if post_summary \"\\\$WORK/comment.md\"; then\$@review_redact_file \"\$WORK/comment.md\" || rrc=\$?; if post_summary \"\$WORK/comment.md\"; then  # 变异 M-c@")
run_case m-c "$pkg" MAX_COMMENT_BYTES=1200 MOCK_KIRO_CONTRACT="$SEC_SUMMARY" CI_COMMIT_REF_NAME="feature/${SEC_AKIA}"
assert_rc "$RC" 0 "M-c：变异体仍能跑完"
assert_contains "$OUT" "评审报告超长已截断；完整内容如下：" "M-c：确实走了截断分支"
assert_contains "$OUT" "| \`feature/${SEC_AKIA}\` → " "M-c：日志回显的完整内容里元信息表带分支名原文——端到端截断变体「日志不含原文」断言会失败"
run_case m-c-control "$ROOT" MAX_COMMENT_BYTES=1200 MOCK_KIRO_CONTRACT="$SEC_SUMMARY" CI_COMMIT_REF_NAME="feature/${SEC_AKIA}"
assert_not_contains "$OUT" "| \`feature/${SEC_AKIA}\` → " "M-c 对照：未变异实现回显的完整内容里分支名已掩"

# --- M-d：文档级兜底失败照样往下送 → 分支名 token 原样回写 ---
make_bad_awk "$tmp/badawk-doc" doc
run_case m-d-control "$ROOT" PATH="$tmp/badawk-doc:$PATH" MOCK_KIRO_CONTRACT="$SEC_SUMMARY" CI_COMMIT_REF_NAME="feature/${SEC_AKIA}"
assert_nonzero "$RC" "M-d 对照：文档级掩码失败 → 评审失败"
assert_not_contains "$(posted_comment "$OUT")" "$SEC_AKIA" "M-d 对照：掩码失败时分支名原文没有进评论（流水线开头的「使用环境变量指定的 MR」那行本来就打分支名，不是模型文本出口）"
pkg=$(make_mutant m-d-doc-fail-continue "s@${DOC_LINE}@review_redact_file \"\$WORK/comment.md\" || rrc=0  # 变异 M-d：掩码失败照样往下送@")
run_case m-d "$pkg" PATH="$tmp/badawk-doc:$PATH" MOCK_KIRO_CONTRACT="$SEC_SUMMARY" CI_COMMIT_REF_NAME="feature/${SEC_AKIA}"
assert_rc "$RC" 0 "M-d：变异体把掩码失败吞掉后评审「成功」"
assert_contains "$(meta_row "$(posted_comment "$OUT")")" "feature/${SEC_AKIA}" "M-d：未掩码的元信息表被回写——端到端「掩码失败不回写原文」断言会失败"

# --- M-e：保行模式重新允许删行（正文行分支从「等行数换占位」改成「丢弃」）→ 行数守卫 rc 3 拦住（方案 C 裁决里的那条变异）---
mut_doc_pem() { ( set +e; source "$1/scripts/lib/review-render.sh"
  printf '| 文件 | P0 |\n|---|---|\n| x | 1 |\n%s\n%s\n%s\n' "$PEM_B" "$PEM_L64" "$PEM_E" > "$tmp/m-e.md"
  review_redact_file "$tmp/m-e.md" 2>/dev/null; echo $? ); }
pkg=$(make_mutant m-e-doc-deletes-lines 's|      if (pem_body(\$0, 0, 0) \|\| pem_is_hdr(\$0)) { print PEM_BODY_PH; next }   # 正文行 / RFC 1421 头：等行数替换（第 11 条）|      if (pem_body($0, 0, 0) \|\| pem_is_hdr($0)) { next }  # 变异 M-e：保行模式删行|' scripts/lib/review-render.sh)
assert_eq "$(mut_doc_pem "$pkg")" "3" "M-e：保行模式删行 → 行数守卫 rc 3 拒绝写回（单测「行数不变 rc 0」断言会失败）"
assert_eq "$(mut_doc_pem "$ROOT")" "0" "M-e 对照：未变异实现正文行等行数替换、rc 0"

# --- M-f：拆掉标记守卫（_review_replace_guarded 不再核对标记）→ 删了评审标记的输出照样写回（行数补齐一行绕过行数守卫）---
mut_guard() { ( set +e; source "$1/scripts/lib/review-render.sh"
    printf '# T\n<!-- kiro-review:90fcb05 run:1 -->\n<!-- kiro-history:[] -->\n\n正文\n' > "$tmp/m-f.md"
    review_redact_secrets() { grep -v 'kiro-review:'; echo pad; }
    review_redact_file "$tmp/m-f.md" 2>/dev/null; echo $? ); }
pkg=$(make_mutant m-f-no-guard 's|^    if (( rc == 1 )); then rm -f "\$new"; echo "\$who: 脚本标记行丢失或被改写，拒绝写回：\${m:0:60}" >\&2; return 3; fi$|    :  # 变异 M-f：守卫不看标记|' scripts/lib/review-render.sh)
assert_eq "$(mut_guard "$pkg")" "0" "M-f：守卫拆掉后删了评审标记的输出照样 rc 0 写回——单测「rc 3」断言会失败"
assert_eq "$(mut_guard "$ROOT")" "3" "M-f 对照：未变异实现 rc 3"
# 第 11 条：守卫的标记正则从常量派生——把常量改掉，守卫探针文件也从常量生成，仍要抓到
mut_guard_const() { ( set +e; source "$1/scripts/lib/review-render.sh"; REVIEW_HISTORY_PREFIX='<!-- kiro-hist:'; REVIEW_MARKER_LINE_RE_ALL=$(_review_marker_line_re_build)   # 16-fix4 第 16 条：加载期常量，改常量后按派生公式重算
    printf '# T\n<!-- kiro-review:90fcb05 run:1 -->\n%s[] -->\n正文\n' "$REVIEW_HISTORY_PREFIX" > "$tmp/m-f2.md"
    review_redact_secrets() { sed 's/kiro-hist:\[\]/kiro-hist:[9]/'; }
    review_redact_file "$tmp/m-f2.md" 2>/dev/null; echo $? ); }
assert_eq "$(mut_guard_const "$ROOT")" "3" "第 11 条：常量改名后守卫仍按常量抓到被改写的历史行（硬编码字面量会零命中放行）"

# --- M-g：die_review 的日志行不再过掩码 → 事件流 status 里的 token 原样进流水线日志（评论仍被文档级兜底掩掉）---
pkg=$(make_mutant m-g-log-redact 's|^  log "错误：\${reason_fixed}\${detail:+：\$(_untrusted_for_log "\$detail")}"$|  log "错误：${reason_fixed}${detail:+：$detail}"  # 变异 M-g：不受信取值不掩码|')
run_case m-g "$pkg" MOCK_KIRO_STATUS_TEXT="error ${SEC_GHP}"
assert_nonzero "$RC" "M-g：变异体仍以非零退出"
assert_contains "$OUT" "错误：Kiro 自报运行失败（runFinished.status 取值见后）：status=error ${SEC_GHP}" "M-g：日志行带 ghp_ 原文——端到端「日志不含原文」断言会失败"
assert_not_contains "$(posted_comment "$OUT")" "$SEC_GHP" "M-g 对照：失败评论仍被文档级兜底掩掉（差别只在日志）"
run_case m-g-control "$ROOT" MOCK_KIRO_STATUS_TEXT="error ${SEC_GHP}"
assert_not_contains "$OUT" "$SEC_GHP" "M-g 对照：未变异实现日志与评论都不含原文"

# --- M-h：第 29 条的两条上下文判定各去掉一条 → 无数字凭证裸奔（单测「仍掩」断言会失败）---
pkg=$(make_mutant m-h-no-caps-key 's|^      if (key ~ /\^\[A-Z0-9_-\]\*\[A-Z\]\[A-Z0-9_-\]\*\$/) return 1 .*$|      # 变异 M-h：去掉 ③ 键名全大写|' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'SECRET_KEY=MySuperSecretPassphrase')" 'SECRET_KEY=MySu****rase' "M-h 对照：去掉 ③ 后 SECRET_KEY=… 仍被 ④（无空格）兜住"
assert_eq "$(mut_rd "$pkg" 'MYSQL_PASSWORD: SuperSecretPassword')" 'MYSQL_PASSWORD: Supe****word' "M-h 对照：去掉 ③ 后 YAML 形态仍被 ④b 兜住（16-fix4 第 14 条：19 位驼峰不是词形）"
assert_eq "$(mut_rd "$pkg" 'SECRET_KEY = MySuperSecretPassphrase')" 'SECRET_KEY = MySuperSecretPassphrase' "M-h：去掉 ③ 后「全大写键 + 有空格的 =」裸奔——单测断言会失败"
assert_eq "$(mut_rd "$ROOT" 'SECRET_KEY = MySuperSecretPassphrase')" 'SECRET_KEY = MySu****rase' "M-h 对照：未变异实现按 ③ 掩"
pkg=$(make_mutant m-h-no-unspaced 's|^      if (unspaced == 2) return 1 .*$|      # 变异 M-h2：去掉 ④a env / properties 形态|' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'client_secret=hJKlMnOpQrStUvWxYzAbCdEfGhIj')" 'client_secret=hJKlMnOpQrStUvWxYzAbCdEfGhIj' "M-h2：去掉 ④ 后 client_secret=hJKl… 裸奔——单测断言会失败"
assert_eq "$(mut_rd "$ROOT" 'client_secret=hJKlMnOpQrStUvWxYzAbCdEfGhIj')" 'client_secret=hJKl****GhIj' "M-h2 对照：未变异实现按 ④ 掩"

# --- M-i / M-j：去掉 bearer / header 的散文词豁免 → 英文散文被掩 ---
pkg=$(make_mutant m-i-bearer-prose 's|^        if (prose_word(val, 20)) out = out seg$|        if (0) out = out seg  # 变异 M-i|' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'Basic authentication')" 'Basic auth****tion' "M-i：豁免去掉后散文被掩——单测断言会失败"
assert_eq "$(mut_rd "$ROOT" 'Basic authentication')" 'Basic authentication' "M-i 对照：未变异实现不掩"
pkg=$(make_mutant m-j-header-prose 's#        else if (hdr == "authorization" \&\& prose_word(val, 20)) out = out seg#        else if (0) out = out seg  \# 变异 M-j#' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'Authorization: header missing')" 'Authorization: **** missing' "M-j：豁免去掉后 header 被掩——单测断言会失败"
assert_eq "$(mut_rd "$ROOT" 'Authorization: header missing')" 'Authorization: header missing' "M-j 对照：未变异实现不掩"
# 第 19 条：散文词上限去掉 → 20 位纯小写令牌放行
pkg=$(make_mutant m-j2-prose-nolimit 's|^      if (length(v) >= maxlen) return 0$|      # 变异 M-j2：散文词不设长度上限|' scripts/lib/review-render.sh)
# 载荷用 Bearer：x-auth-token 里含 token，键值规则（④ 分隔符是 :）会把它再掩一次、遮住这条变异（两条规则重叠时选只有一条规则覆盖的载荷）
assert_eq "$(mut_rd "$pkg" 'Authorization: Bearer abcdefghijklmnopqrst')" 'Authorization: Bearer abcdefghijklmnopqrst' "M-j2：去掉长度上限后 Bearer 后 20 位纯小写令牌裸奔——单测「仍掩」断言会失败"
assert_eq "$(mut_rd "$ROOT" 'Authorization: Bearer abcdefghijklmnopqrst')" 'Authorization: Bearer abcd****qrst' "M-j2 对照：未变异实现掩"

# --- M-k：第 8 条——恢复对加引号取值的路径 / 属性访问排除 → 引号里的 /Jalr… 放行 ---
pkg=$(make_mutant m-k-quoted-excl 's|^      if (quoted) return 1 .*$|      # 变异 M-k：引号取值也走路径 / 属性访问排除|' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'aws_secret_access_key = "/JalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"')" 'aws_secret_access_key = "/JalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"' "M-k：引号里以 / 开头的密钥裸奔——单测「仍掩」断言会失败"
assert_eq "$(mut_rd "$ROOT" 'aws_secret_access_key = "/JalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"')" 'aws_secret_access_key = "/Jal****EKEY"' "M-k 对照：未变异实现掩"

# --- M-l：第 9 条——口令字符类放回 / → 普通 URL 被掩成「像凭证 URL」---
pkg=$(make_mutant m-l-url-slash 's#URL_STRICT_RE = "\[a-zA-Z\]\[a-zA-Z0-9+.-\]\*://\[A-Za-z0-9._~+-\]+:\[A-Za-z0-9._~+=%-\]+@"#URL_STRICT_RE = "[a-zA-Z][a-zA-Z0-9+.-]*://[A-Za-z0-9._~+-]+:[A-Za-z0-9._~+/=%-]+@"#' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'https://registry.npmjs.org:443/@babel/core')" 'https://registry.npmjs.org:****@babel/core' "M-l：口令字符类含 / 时 npm URL 被改写——单测「不掩」断言会失败"
assert_eq "$(mut_rd "$ROOT" 'https://registry.npmjs.org:443/@babel/core')" 'https://registry.npmjs.org:443/@babel/core' "M-l 对照：未变异实现不动"

# --- M-m：第 4 条——行内正文掩码失败分支去掉 continue → 该条既记 failed 又照常发出 ---
pkg=$(make_mutant m-m-inline-continue 's|^      printf .{"idx":%s,"outcome":"failed"}\\n. "\$idx" >> "\$WORK/outcomes.jsonl"; n_failed=\$((n_failed + 1)); continue$|      printf '"'"'{"idx":%s,"outcome":"failed"}\\n'"'"' "$idx" >> "$WORK/outcomes.jsonl"; n_failed=$((n_failed + 1))  # 变异 M-m：不 continue|')
make_bad_awk "$tmp/badawk-inline" inline
inline_case m-m "$pkg" "$IFX" PATH="$tmp/badawk-inline:$PATH" MOCK_KIRO_CONTRACT="$SEC_INLINE"
assert_rc "$RC" 0 "M-m：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | grep -c . || true)" "3" "M-m：掩码失败的正文照样发出了 3 条——端到端「一条都没发出」断言会失败"
inline_case m-m-control "$ROOT" "$IFX" PATH="$tmp/badawk-inline:$PATH" MOCK_KIRO_CONTRACT="$SEC_INLINE"
assert_eq "$(inline_bodies "$OUT" | grep -c . || true)" "0" "M-m 对照：未变异实现掩码失败的正文一条都不发"

# --- M-n：第 24 条——kiro stderr 尾巴不过掩码 → 日志带 bearer 原文 ---
pkg=$(make_mutant m-n-stderr 's@^  tail -20 "\$WORK/kiro-stderr.log" 2>/dev/null | review_clean_text | review_redact_secrets --keep-lines >\&2 || true$@  tail -20 "$WORK/kiro-stderr.log" >\&2 || true  # 变异 M-n@')
run_case m-n "$pkg" MOCK_KIRO_FAIL=1 MOCK_KIRO_STDERR_TEXT="Authorization: Bearer ${SEC_GHP}"
assert_contains "$OUT" "Authorization: Bearer ${SEC_GHP}" "M-n：kiro stderr 尾巴带 bearer 原文进了日志——端到端「日志不含原文」断言会失败"
run_case m-n-control "$ROOT" MOCK_KIRO_FAIL=1 MOCK_KIRO_STDERR_TEXT="Authorization: Bearer ${SEC_GHP}"
assert_not_contains "$OUT" "$SEC_GHP" "M-n 对照：未变异实现掩掉"

# ============ 16-fix3 的守卫 ============
make_bad_awk "$tmp/badawk"   # 全部掩码程序失败的替身（M-s 用）
# --- M-o：第 7 条——行内出口的字节硬守卫拆掉 → 超限正文照样发出 ---
pkg=$(make_mutant m-o-body-guard 's|^    if ! \[\[ "\$body_bytes" =~ .*\]\]; then .*$|    if false; then  # 变异 M-o：不守字节上限|')
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["findings"][0]["body"]="B"*40000; json.dump(c,open(sys.argv[2],"w"),ensure_ascii=False)' "$E2EC" "$tmp/oversize-inline.json"
inline_case m-o "$pkg" "$IFX" MAX_COMMENT_BYTES=20000 MOCK_KIRO_CONTRACT="$tmp/oversize-inline.json"
assert_rc "$RC" 0 "M-o：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | grep -c . || true)" "3" "M-o：超限正文照样发出（3 条）——端到端「超限那条不发」断言会失败"
inline_case m-o-control "$ROOT" "$IFX" MAX_COMMENT_BYTES=20000 MOCK_KIRO_CONTRACT="$tmp/oversize-inline.json"
assert_eq "$(inline_bodies "$OUT" | grep -c . || true)" "2" "M-o 对照：未变异实现只发 2 条"
# --- M-p：第 12 条——去掉宽松第二遍 → 口令含 / 的凭证 URL 裸奔 ---
pkg=$(make_mutant m-p-url-loose 's|^      return redact_url_pass(redact_url_pass(line, URL_STRICT_RE, 0), URL_LOOSE_RE, 1)$|      return redact_url_pass(line, URL_STRICT_RE, 0)  # 变异 M-p|' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'https://ci:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY@git.example.com/x.git')" 'https://ci:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY@git.example.com/x.git' "M-p：没有宽松第二遍，含 / 的口令裸奔——单测「仍掩」断言会失败"
assert_eq "$(mut_rd "$ROOT" 'https://ci:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY@git.example.com/x.git')" 'https://ci:wJal****EKEY@git.example.com/x.git' "M-p 对照：未变异实现掩"
pkg=$(make_mutant m-p2-url-port 's%        if (loose && pass ~ /\^\[0-9\]+\\//) { out = out seg; continue }   # host:port/path…@ 不是凭证%        # 变异 M-p2：不排除端口 + 路径%' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'http://localhost:8080/oauth/callback/user@example.com')" 'http://localhost:8080****user@example.com' "M-p2：去掉端口 + 路径排除后普通 URL 被掩——单测「不掩」断言会失败"
# --- M-q：第 10 条——装饰剥离去掉反引号 / 列表 → 装饰 BEGIN 行不再开块 ---
pkg=$(make_mutant m-q-deco 's|      while (sub(/\^\[>\*+`\]\[\[:space:\]\]\*/, "", s) \|\| sub(/\^-\[\[:space:\]\]+/, "", s)|      while (sub(/^-[[:space:]]+/, "", s)|' scripts/lib/review-render.sh)   # 变异 M-q：去掉「引用 / 列表 / 反引号」那条装饰规则
# 起始行由「行末标记 + 下一行像正文」的兜底另行兜住（两道防线叠着），装饰剥离失效的可观测结果在 END 行：反引号装饰的 END
# 不再认出 → 块到 EOF 仍未闭合 → 放出并插「没有配对的 END 行」提示（单测「整块丢弃、只剩一行占位」断言会失败）
assert_contains "$(mut_rd_multi "$pkg" "\`$PEM_B\`\n$PEM_L64\n\`$PEM_E\`\n")" "没有配对的 END 行" "M-q：装饰剥离失效后反引号装饰的 END 行认不出，块被当成未闭合——单测「整块丢弃」断言会失败"
assert_eq "$(mut_rd_multi "$ROOT" "\`$PEM_B\`\n$PEM_L64\n\`$PEM_E\`\n")" "$(printf '%s\n> ⚠️ （其间 1 行已随密钥块一并屏蔽）' "$PEM_PLACEHOLDER")" "M-q 对照：未变异实现整块丢弃、占位 + 提示"
# --- M-t：第 10 条兜底——「含 BEGIN 且下一行像正文」不再当块起始 ---
pkg=$(make_mutant m-t-pend 's|    pend != "" { if (!inpem \&\& (pem_body(\$0, 20, 1) \|\| pem_is_hdr(\$0))) { begin_block(pend, 0); pend = "" } else emit_pending() }|    pend != "" { emit_pending() }  # 变异 M-t：兜底失效|' scripts/lib/review-render.sh)
# 载荷用 28 位正文：≥ 40 位的整行会被第 17 条的整行规则另行掩掉（两道防线叠着），只有兜底能兜住 20–39 位的正文行
PEM_L28="MIIEvQIBADANBgkq""1hkiG9w0BAQE"
assert_contains "$(mut_rd_multi "$pkg" "私钥如下 $PEM_B\n$PEM_L28\n$PEM_E\n")" "$PEM_L28" "M-t：兜底失效后 28 位正文行裸奔——单测「兜底当块起始」断言会失败"
assert_not_contains "$(mut_rd_multi "$ROOT" "私钥如下 $PEM_B\n$PEM_L28\n$PEM_E\n")" "$PEM_L28" "M-t 对照：未变异实现兜底开块、整块丢弃"
# --- M-r：第 11 / 14 条——保行模式正文行不再换占位（原样打出）→ 降级评论 / kiro stderr 泄露正文 ---
pkg=$(make_mutant m-r-keep-body 's|      if (pem_body(\$0, 0, 0) \|\| pem_is_hdr(\$0)) { print PEM_BODY_PH; next }   # 正文行 / RFC 1421 头：等行数替换（第 11 条）|      if (pem_body($0, 0, 0) \|\| pem_is_hdr($0)) { print; next }  # 变异 M-r：保行模式正文原样|' scripts/lib/review-render.sh)
run_case m-r "$pkg" MOCK_KIRO_LEAK_SECRET=1
assert_rc "$RC" 0 "M-r：变异体仍能跑完"
assert_contains "$OUT" "MIIEowIBAAKCAQEA""fakekey0123456" "M-r：降级评论里整行私钥正文裸奔——端到端「整行正文不进评论」断言会失败"
run_case m-r-control "$ROOT" MOCK_KIRO_LEAK_SECRET=1
assert_not_contains "$OUT" "MIIEowIBAAKCAQEA""fakekey0123456" "M-r 对照：未变异实现屏蔽"
# --- M-s：第 13 条——降级渲染器掩码失败不再 fail-closed → 空正文的降级评论以 rc 0 发出 ---
pkg=$(make_mutant m-s-degraded-open 's|^  _review_redact_to "\$_RR_TEXT" "\$masked" review_render_degraded .*$|  _review_redact_to "$_RR_TEXT" "$masked" review_render_degraded "" --keep-lines \|\| : > "$masked"  # 变异 M-s：掩码失败照样渲染（空正文）|' scripts/lib/review-render.sh)
# 替身只让**原文**的掩码失败（渲染好的评论带 <!-- kiro- 标记，文档级兜底照常）——否则出口的兜底会替降级渲染器把评审拦下，
# 观察不到渲染器自己的 fail-open
make_bad_awk "$tmp/badawk-raw" raw
run_case m-s "$pkg" PATH="$tmp/badawk-raw:$PATH" MOCK_KIRO_LEAK_SECRET=1
assert_rc "$RC" 0 "M-s：掩码失败被吞后评审「成功」——端到端「降级掩码失败 → 评审失败」断言会失败"
assert_contains "$(posted_comment "$OUT")" "结构化解析失败" "M-s：发出的是一份降级评论（正文为空）"
run_case m-s-control "$ROOT" PATH="$tmp/badawk-raw:$PATH" MOCK_KIRO_LEAK_SECRET=1
assert_nonzero "$RC" "M-s 对照：未变异实现 fail-closed"
assert_contains "$OUT" "review_render_degraded: 掩码失败" "M-s 对照：库函数点明原因"
# --- M-u：第 17 条——去掉全模式的整行密钥正文规则 → 跨字段的正文行裸奔 ---
pkg=$(make_mutant m-u-body-line 's|^      if (pem_body(line, 40, 1)) {   .*$|      if (0) {   # 变异 M-u：无整行规则|' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" "$PEM_L64")" "$PEM_L64" "M-u：整行密钥正文原样——单测「≥ 40 位整行 base64 在任何字段都掩」断言会失败"
assert_eq "$(mut_rd "$ROOT" "$PEM_L64")" "MIIE****ijkl" "M-u 对照：未变异实现掩"
# --- M-v：第 24 条——闭合块不再打「其间 N 行」提示 → 整段无声消失 ---
pkg=$(make_mutant m-v-close-note 's|^      if (held_n > 0) print "> ⚠️ （其间 " held_n " 行已随密钥块一并屏蔽）"$|      # 变异 M-v：闭合块无提示|' scripts/lib/review-render.sh)
assert_not_contains "$(mut_rd_multi "$pkg" "x\n$PEM_B\n（内容已省略）\n$PEM_L64\n$PEM_E\ny\n")" "其间 2 行已随密钥块一并屏蔽" "M-v：闭合块提示消失——单测「不再无声」断言会失败"
assert_contains "$(mut_rd_multi "$ROOT" "x\n$PEM_B\n（内容已省略）\n$PEM_L64\n$PEM_E\ny\n")" "其间 2 行已随密钥块一并屏蔽" "M-v 对照：未变异实现给提示"
# ============ 16-fix4 的守卫 ============
# --- M-w：第 11 条——begin_block 的悬挂行不再对标记前的散文过 redact_line → AKIA 原文跟着出去 ---
pkg=$(make_mutant m-w-begin-pre 's|      if (keeplines) print redact_line(pre) mk redact_b64(redact_line(tail), 20, 1)|      if (keeplines) print pre mk redact_b64(redact_line(tail), 20, 1)  # 变异 M-w|' scripts/lib/review-render.sh)
assert_contains "$( ( set +e; source "$pkg/scripts/lib/review-render.sh"; printf '%b' "硬编码凭证 $SEC_AKIA 与私钥 $PEM_B\n$PEM_L64\n$PEM_E\n" | review_redact_secrets --keep-lines ) )" "$SEC_AKIA" "M-w：悬挂行 BEGIN 前的 AKIA 原样出去——单测「悬挂行掩码」断言会失败"
assert_not_contains "$( ( set +e; source "$ROOT/scripts/lib/review-render.sh"; printf '%b' "硬编码凭证 $SEC_AKIA 与私钥 $PEM_B\n$PEM_L64\n$PEM_E\n" | review_redact_secrets --keep-lines ) )" "$SEC_AKIA" "M-w 对照：未变异实现掩"

# --- M-x：第 26 条——b64_material 的路径排除 / 数字要求各去掉一条 → Java 路径被掩 / 无数字长标识符被掩（单测 golden 会失败）---
pkg=$(make_mutant m-x1-no-switch-rate 's|^      return (pairs > 0 \&\& sw / pairs >= 0.35)$|      return 1  # 变异 M-x1：块外不再看类别切换率|' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'src/main/java/com/example/v2/service/impl/UserService')" 'src/****vice' "M-x1：Java 长路径整行掩成碎片——单测「路径 / 类名不是密钥正文」断言会失败"
assert_eq "$(mut_rd "$pkg" 'AbstractSingletonProxyFactoryBean2Configuration')" 'Abst****tion' "M-x1：长类名整行掩成碎片——单测第 26 条改定义断言会失败"
assert_eq "$(mut_rd "$ROOT" 'src/main/java/com/example/v2/service/impl/UserService')" 'src/main/java/com/example/v2/service/impl/UserService' "M-x1 对照：未变异实现原样"
pkg=$(make_mutant m-x2-no-digit 's|^      if (s !~ /\[0-9\]/) return 0$|      # 变异 M-x2：不要求数字|' scripts/lib/review-render.sh)
assert_eq "$(mut_rd "$pkg" 'aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgH')" 'aBcD****eFgH' "M-x2：无数字但高切换率的 60 位纯字母串整行掩——单测「共同条件含数字」断言会失败"
assert_eq "$(mut_rd "$ROOT" 'aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgH')" 'aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgH' "M-x2 对照：未变异实现原样（无数字不算材料）"

# --- M-y：第 27 条——fpath 回到先剔控制字符再查禁用字符 → src/<U+0001>app.py 洗成合法路径、不计数（单测「按不可定位处理并计数」会失败）---
pkg=$(make_mutant m-y-fpath-dectl-first 's|^    def fpath(v): (if (v \| type) == "string" then .*$|    def fpath(v): (tr(v)) as $t   # 变异 M-y：先 dectl|' scripts/lib/review-render.sh)
assert_eq "$( ( set +e; source "$pkg/scripts/lib/review-render.sh"; jq -n --arg f "$(printf 'src/\001app.py')" '{contract:"codeup-reviewer/1", summary:"s", verdict:"MERGE", verdict_reason:"r", findings:[{severity:"P2",title:"t",body:"b",file:$f,line_start:1}]}' | review_validate | jq -c '[.findings[0].file, .delocated_findings]' ) )" '["src/app.py",0]' "M-y：控制字符被洗掉后路径「合法」、不计数——单测第 27 条断言会失败"
assert_eq "$( ( set +e; source "$ROOT/scripts/lib/review-render.sh"; jq -n --arg f "$(printf 'src/\001app.py')" '{contract:"codeup-reviewer/1", summary:"s", verdict:"MERGE", verdict_reason:"r", findings:[{severity:"P2",title:"t",body:"b",file:$f,line_start:1}]}' | review_validate | jq -c '[.findings[0].file, .delocated_findings]' ) )" '[null,1]' "M-y 对照：未变异实现置空并计数"

# --- M-z：第 37 条——finalize 的 body 上限写死成字面量 32768 → 覆盖 REVIEW_CAP_BODY 不再生效（单测「覆盖后截到 ≤ 100」会失败）---
pkg=$(make_mutant m-z-cap-literal 's@^          | cap(.body; \$cap_body) as \$B$@          | cap(.body; 32768) as $B  # 变异 M-z：上限写死@' scripts/lib/review-render.sh)
body5k=$(python3 -c 'print("b"*5000, end="")')
assert_eq "$( ( set +e; source "$pkg/scripts/lib/review-render.sh"; REVIEW_CAP_BODY=100; jq -n --arg b "$body5k" '{contract:"codeup-reviewer/1", summary:"s", verdict:"MERGE", verdict_reason:"r", findings:[{severity:"P0",title:"t",body:$b,fix:"",file:"src/app.py",line_start:1}]}' | review_validate | jq -r '[(.findings[0].body | utf8bytelength <= 100), .truncated_fields] | @csv' ) )" "false,0" "M-z：覆盖 REVIEW_CAP_BODY=100 后 body 仍不截——单测第 37 条断言会失败"
assert_eq "$( ( set +e; source "$ROOT/scripts/lib/review-render.sh"; REVIEW_CAP_BODY=100; jq -n --arg b "$body5k" '{contract:"codeup-reviewer/1", summary:"s", verdict:"MERGE", verdict_reason:"r", findings:[{severity:"P0",title:"t",body:$b,fix:"",file:"src/app.py",line_start:1}]}' | review_validate | jq -r '[(.findings[0].body | utf8bytelength <= 100), .truncated_fields] | @csv' ) )" "true,1" "M-z 对照：未变异实现按覆盖后的上限截"

# ============ 票 17 的守卫 ============
# --- M52（票 17 A / M-a）：to≠HEAD 从 fail-closed 改回「warn 然后继续」→ 旧 HEAD 的行号被绑到最新版本 ---
# fixture：to 是评审期间新推上去的另一个提交（不在克隆里），from 仍是 merge-base（只让 to 异常）。
# 各种成因与各自的处置见 docs/adr/0005-inline-comments-bind-to-reviewed-commit.md。
IFXMIS="$tmp/ifx-headmismatch"
mkdir -p "$IFXMIS"
cp "$IFX"/create-comment-inline.*.json "$IFXMIS/"
head_mismatch_case() { # <用例名> <集成包根>
  PS_SRC=RAW:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef PS_SRC_ID=src-9 inline_case "$1" "$2" "$IFXMIS"
}
head_mismatch_case baseline-headmismatch "$ROOT"
assert_rc "$RC" 0 "对照：to 解析不出时评审成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "对照：to 解析不出时 0 条行内评论（fail-closed）"
assert_contains "$(posted_comment "$OUT")" "## 问题清单" "对照：退回完整清单"
# 变异锚在 inline_bail 那一行的文案上（票 17-fix2 C⑤：出口收敛成一个函数之后，锚点是 notice 而不是注释）：
# 把 `; return 1` 换成空语句 → notice 与 warning 照旧写出，随后继续往下发草稿，正是票 17 之前的行为
# 按 `# fail-closed:<名字>` 标签锚定（票 17-fix3：文案挪进 inline_bail_to 之后，按 notice 锚会失配）。
# 这条路径上有两个出口：预采样先判定（fail-closed:pre），放开它之后发布前再判定一次（fail-closed:to）。
# **两个都得放开**才回到「拿旧 HEAD 的行号去绑另一个版本」——出口是合起来守住这条不变量的。
pkg=$(make_mutant m52-head-failclosed \
  '/# fail-closed:pre$/ s/return 1/:/; /# fail-closed:to$/ s/return 1/:/')
head_mismatch_case m52 "$pkg"
assert_rc "$RC" 0 "M52：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" \
  "M52：改回 warn 然后继续之后 3 条行内评论绑到了另一个提交的版本上——端到端 A11「0 次创建」断言会失败"
assert_eq "$(inline_bodies "$OUT" | jq -r '.to_patchset_biz_id' | sort -u | paste -sd, -)" "src-9" "M52：绑的正是那个不在克隆里的最新版本（I5 被违反）"
assert_contains "$(posted_comment "$OUT")" "已标注在「文件改动」对应行" "M52：汇总还谎报「已标注」——端到端「不谎报行内计数」断言会失败"
assert_not_contains "$(posted_comment "$OUT")" "## 问题清单" "M52：完整清单没有了——端到端「回落成完整清单」断言会失败"

# --- M53（票 17 B / M-b）：拿掉「MERGE + P0 → 不建议合并」的改写 → 结论行照样写「可合并」---
printf '{"contract":"codeup-reviewer/1","summary":"s","verdict":"MERGE","verdict_reason":"看起来没问题","findings":[{"id":"F1","severity":"P0","category":"security","title":"SQL 注入","file":"src/app.py","line_start":2,"line_end":2,"body":"拼接 SQL。","fix":"参数化。"}]}\n' \
  > "$tmp/merge-p0-contract.json"
run_case baseline-mergep0 "$ROOT" MOCK_KIRO_CONTRACT="$tmp/merge-p0-contract.json"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "## 结论：不建议合并" "对照：MERGE + P0 改写为不建议合并"
assert_contains "$comment" "已按不建议合并处理" "对照：改写原因明说"
assert_contains "$comment" '"verdict":"DO_NOT_MERGE"' "对照：历次表记改写后的结论"
pkg=$(make_mutant m53-p0-rewrite 's|  if \[\[ "\$verdict" == "MERGE" \&\& "\$n0" -gt 0 \]\]; then|  if false; then|' scripts/lib/review-render.sh)
run_case m53 "$pkg" MOCK_KIRO_CONTRACT="$tmp/merge-p0-contract.json"
assert_rc "$RC" 0 "M53：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "## 结论：可合并" "M53：有 P0 却渲染「可合并」——golden summary-merge-p0.md 与端到端断言都会失败"
assert_not_contains "$comment" "已按不建议合并处理" "M53：没有改写说明行"
assert_contains "$comment" '"verdict":"MERGE"' "M53：历次表记的也是 MERGE（与读者看到的一致，但都是错的）"

# --- M54（票 17 B / M-c）：契约外取值改回原样带出 → 载荷直达结论行 ---
# **三处**都得改，少一处载荷就到不了评论：① `review_validate` 放行契约外取值；② `_review_verdict_cn` 的
# `*)` 分支回显原值（否则仍是固定文案）；③ 渲染器边界那个 case（复审加的纵深防御，否则它又把值置空）。
# 三层都塌了才泄露，这正是这条变异要证明的：golden 与端到端的「载荷不出现」断言不是空转。
# 只塌第三层的情形另有 M58。
printf '{"contract":"codeup-reviewer/1","summary":"s","verdict":"<h1>可合并</h1>","verdict_reason":"r","findings":[]}\n' > "$tmp/offcontract-contract.json"
run_case baseline-offverdict "$ROOT" MOCK_KIRO_CONTRACT="$tmp/offcontract-contract.json"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "## 结论：评审员未给出契约内的结论" "对照：契约外取值渲染固定文案"
assert_not_contains "$comment" "可合并" "对照：载荷不进评论"
pkg=$(make_mutant m54-verdict-passthrough \
  's|        verdict: (if \$vok then \$vnorm else "" end),|        verdict: $vnorm,|; s|    \*) echo "评审员未给出契约内的结论" ;;|    *) echo "$1" ;;|; s|^    \*) echo "review_render_summary: 结论不在契约内.*$|    *) ;;|' \
  scripts/lib/review-render.sh)
run_case m54 "$pkg" MOCK_KIRO_CONTRACT="$tmp/offcontract-contract.json"
assert_rc "$RC" 0 "M54：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "## 结论：&lt;H1>可合并&lt;/H1>" "M54：像标签的载荷进了结论行（票 16 的单行清洗仍把标签转义，但载荷本身已到达）——golden summary-verdict-offcontract.md 与端到端「载荷不出现」断言都会失败"
assert_not_contains "$comment" "评审员未给出契约内的结论" "M54：固定文案消失"

# --- M55（票 17 C / M-d）：拿掉同轮完全重复的合并 → 两条一样的问题各发一条行内评论 ---
DUPC="$ROOT/tests/fixtures/contract/inline-dup.json"
inline_case baseline-dup "$ROOT" "$IFX" MOCK_KIRO_CONTRACT="$DUPC"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "1" "对照：逐字段相同的两条只发一条"
assert_contains "$OUT" "1 条完全重复的问题已合并" "对照：日志记合并条数"
pkg=$(make_mutant m55-dup-merge 's#if .seen\[\$k\] then . else#if false then . else#' scripts/lib/review-render.sh)
inline_case m55 "$pkg" "$IFX" MOCK_KIRO_CONTRACT="$DUPC"
assert_rc "$RC" 0 "M55：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "2" \
  "M55：两条一样的问题各发了一条（inline_count=2）——单测「inline_count=1」与端到端「只发一条」断言会失败"
assert_not_contains "$OUT" "完全重复的问题已合并" "M55：日志里也没有合并记录"
assert_contains "$(posted_comment "$OUT")" "其中 2 条已标注在「文件改动」对应行" "M55：统计行按 2 条算——端到端「其中 1 条」断言会失败"

# --- M56（票 17 C 复审，17-fix2 重锚）：判定键里的路径/行号改回用归一化**后**的字段 →
#     不可定位的问题被塌成（null,null,null,…），两个**不同文件**上的问题被并成一条 ---
# fixture 的两条只有路径不同（级别/标题/说明/修复建议逐字节相同），所以这条变异只证明「路径必须按原值比」——
# body/fix 在键里那一半由 M59 单独守（子代理构造的「只改归一化」变异体曾经全绿，就是因为两条 fixture 正文不同、
# 杀伤实际来自 body 那一半）。
DELOCC="$ROOT/tests/fixtures/contract/deloc-dup.json"
run_case baseline-delocdup "$ROOT" MOCK_KIRO_CONTRACT="$DELOCC"
assert_rc "$RC" 0 "对照：两条路径不合规、其余逐字节相同的 P0 时评审成功"
assert_contains "$OUT" "评审报告：P0 2" "对照：两条都留下了（路径不同就是两条）"
assert_not_contains "$OUT" "完全重复的问题已合并" "对照：不同文件不算重复"
assert_contains "$OUT" "2 条问题的 file 含" "对照：两条都按未定位处理（归一化后 file 为 null）"
pkg=$(make_mutant m56-dupkey-normalized \
  's#dupkey: (\[tr(.file), lineno(.line_start), lineno(.line_end),#dupkey: ([$file, $ls, $le,#' \
  scripts/lib/review-render.sh)
run_case m56 "$pkg" MOCK_KIRO_CONTRACT="$DELOCC"
assert_rc "$RC" 0 "M56：变异体仍能跑完"
assert_contains "$OUT" "评审报告：P0 1" "M56：一条 P0 被静默并掉——单测「路径不同的两条不合并」断言会失败"
assert_contains "$OUT" "1 条完全重复的问题已合并" "M56：日志还把两个不同文件说成完全重复"
assert_contains "$OUT" "1 条问题的 file 含" "M56：未定位计数也跟着少算一条"

# --- M57（票 17 A 复审）：from 侧的探针警告挪回 fail-closed 之后 → 两个核对同时不成立时它被一起吞掉 ---
# from 侧那条警告是「P1-14 的结论失效了」的探针；to 侧 return 1 在前的话，最需要它的那种运行里反而没有它。
IFXBOTH="$tmp/ifx-bothmismatch"
mkdir -p "$IFXBOTH"
cp "$IFX"/create-comment-inline.*.json "$IFXBOTH/"
both_mismatch_case() { # <用例名> <集成包根>
  PS_SRC=RAW:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef PS_SRC_ID=src-9 \
    PS_TGT=RAW:feedfacefeedfacefeedfacefeedfacefeedface PS_TGT_ID=tgt-9 inline_case "$1" "$2" "$IFXBOTH"
}
both_mismatch_case baseline-bothmismatch "$ROOT"
assert_rc "$RC" 0 "对照：两个核对都不成立时评审仍成功"
assert_contains "$OUT" "不等于本地 merge-base" "对照：from 侧探针警告在日志里"
assert_contains "$OUT" "不在本地克隆里" "对照：to 侧警告也在"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "对照：仍然一条行内评论都不发"
pkg=$(make_mutant m57-from-canary '/不等于本地 merge-base（/ s/^  log /  : /')
both_mismatch_case m57 "$pkg"
assert_rc "$RC" 0 "M57：变异体仍能跑完"
assert_not_contains "$OUT" "不等于本地 merge-base" \
  "M57：from 侧探针被 fail-closed 吞掉——端到端「两个核对都不成立时 from 侧警告仍在日志里」断言会失败"
assert_contains "$OUT" "不在本地克隆里" "M57：to 侧警告不受影响（证明变异只动了探针那一行）"

# --- M58（票 17 B 复审）：只塌掉渲染器边界那一层 → 没走 review_validate 的调用方能把任意文本写进隐藏历史 ---
# 隐藏历史里的结论下一轮会被读回来渲染；结论行本身有固定文案兜底，标记没有。所以这一层单独也要有变异守卫。
# 用 jq 造输入：printf 里的 \n 会变成真的换行，那是非法 JSON，渲染器的输入校验会先把它挡掉。
jq -n '{summary:"s", verdict:"MERGE\n## 伪造标题", verdict_reason:"r", findings:[],
        dropped_findings:0, delocated_findings:0}' > "$tmp/m58-input.json"
mut_bypass_marker() { ( set +e; source "$1/scripts/lib/review-render.sh"
  review_render_summary --json "$tmp/m58-input.json" --sha 90fcb05 --src f --dst m --ts t --diff-note n 2>/dev/null \
    | grep -F '<!-- kiro-history:' ); }
pkg=$(make_mutant m58-render-boundary 's|^    \*) echo "review_render_summary: 结论不在契约内.*$|    *) ;;|' scripts/lib/review-render.sh)
assert_contains "$(mut_bypass_marker "$pkg")" "伪造标题" \
  "M58：边界一塌，绕过校验的原值进了隐藏历史标记——单测「原值不出现在评论任何位置」断言会失败"
assert_not_contains "$(mut_bypass_marker "$ROOT")" "伪造标题" "M58 对照：未变异实现把它按未给出结论处理"

# --- M59（17-fix，17-fix2 重锚）：判定键里去掉 body/fix → 同一处（这里是仓库级）说法不同的两条被并掉，
#     第二条的正文与修复建议在评论里彻底消失 ---
# 走库级（review_validate | review_render_summary）而不是端到端：这条守的是 jq 判定键，
# 端到端多跑一遍 kiro 替身与回写只是重复覆盖（票 17-fix2 C⑦）。
REPODUPC="$ROOT/tests/fixtures/contract/repo-level-dup.json"
mut_repodup_comment() { ( set +e; source "$1/scripts/lib/review-render.sh"
  review_validate < "$REPODUPC" > "$tmp/m59-validated.json" 2>/dev/null
  review_render_summary --json "$tmp/m59-validated.json" --sha 90fcb05 --src f --dst m --ts t --diff-note n 2>/dev/null ); }
mut_repodup_count() { ( set +e; source "$1/scripts/lib/review-render.sh"
  review_validate < "$REPODUPC" 2>/dev/null \
    | jq -r '[(.findings | length), .duplicate_findings] | join(",")' ); }
assert_eq "$(mut_repodup_count "$ROOT")" "2,0" "对照：两条仓库级同标题、说法不同的问题不合并"
assert_contains "$(mut_repodup_comment "$ROOT")" "CANARY-REPO-BILLING" "对照：第二条正文在评论里"
pkg=$(make_mutant m59-dupkey-nobody \
  's#\$title, \$bodykey, \$fixkey\] | tojson),#$title, "", ""] | tojson),#' \
  scripts/lib/review-render.sh)
assert_eq "$(mut_repodup_count "$pkg")" "1,1" "M59：body/fix 一出键就并成一条——单测「正文不同 → 不合并」断言会失败"
assert_not_contains "$(mut_repodup_comment "$pkg")" "CANARY-REPO-BILLING" \
  "M59：第二条正文在评论里彻底消失——单测「第二条正文还在」断言会失败"

# --- M60（17-fix）：缺 commitId 改回 fail-open → 拿不到提交号也照发，放弃了 I5 的绑定证明 ---
IFXNC="$tmp/ifx-nocommitid"
mkdir -p "$IFXNC"
cp "$IFX"/create-comment-inline.*.json "$IFXNC/"
no_commitid_case() { # <用例名> <集成包根>
  PS_SRC=OMIT PS_SRC_ID=src-9 inline_case "$1" "$2" "$IFXNC"
}
# 对照不另跑一次：端到端 nocommitid 用例已经把「0 条 + notice + 完整清单」全钉住了（票 17-fix2 C⑦），
# 这里只需要变异体的行为。变异 = 让「没有提交号」那条 fail-closed 出口落空（锚在 inline_bail 的文案上）：
# 后面那条 `!= HEAD` 的判定拿空串去 `git rev-parse` 会解析失败，所以还要把解析失败那条出口也一起放开，
# 才回到票 17 的 fail-open —— 这条变异要证明的就是「几个出口合起来才守得住」。
pkg=$(make_mutant m60-nocommitid-failopen \
  '/# fail-closed:pre$/ s/return 1/:/; /# fail-closed:to$/ s/return 1/:/')
no_commitid_case m60 "$pkg"
assert_rc "$RC" 0 "M60：变异体仍能跑完"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" \
  "M60：拿不到提交号也发了 3 条行内评论——端到端「0 次创建」断言会失败"
assert_contains "$(posted_comment "$OUT")" "已标注在「文件改动」对应行" "M60：汇总还谎报「已标注」"

# --- M61（17-fix3 ④）：把 to 侧的祖先判定反过来 → 滞后被报成「新推送」，处置从「重跑流水线」变成
#     「等下一轮」，而下一轮永远不会来（没有新推送去触发它）---
IFXLAG="$tmp/ifx-lagging"
mkdir -p "$IFXLAG"
cp "$IFX"/create-comment-inline.*.json "$IFXLAG/"
lag_case() { # <用例名> <集成包根>
  PS_SRC=PARENT PS_SRC_ID=src-9 inline_case "$1" "$2" "$IFXLAG" CODEUP_RETRY_BACKOFF=0
}
lag_case baseline-lag "$ROOT"
assert_rc "$RC" 0 "对照：版本列表滞后时评审成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "对照：滞后时 0 条行内评论（fail-closed）"
assert_contains "$(posted_comment "$OUT")" "尚未包含本次提交" "对照：notice 说滞后"
assert_contains "$(posted_comment "$OUT")" "重跑流水线即可" "对照：给出「重跑流水线」的处置"
# 变异：交换 is-ancestor 的两个参数 → 祖先被认成后代
pkg=$(make_mutant m61-ancestor-direction \
  's|if git merge-base --is-ancestor "\$INLINE_TO_NORM" "\$head" 2>/dev/null; then INLINE_TO_STATUS=lag|if git merge-base --is-ancestor "$head" "$INLINE_TO_NORM" 2>/dev/null; then INLINE_TO_STATUS=lag|')
lag_case m61 "$pkg"
assert_rc "$RC" 0 "M61：变异体仍能跑完"
comment=$(posted_comment "$OUT")
assert_not_contains "$comment" "尚未包含本次提交" \
  "M61：方向反了之后滞后不再被认出——端到端「notice 点名滞后」断言会失败"
# 方向一反，祖先在两个方向上都不成立 → 落到最后那支，滞后被报成 force-push：
# notice 变成「等下一轮」（永远等不到），而正确的处置是「重跑流水线」。
assert_contains "$comment" "不在同一条历史上" "M61：滞后被报成分叉历史（处置从「重跑流水线」变成「等下一轮」）"
assert_not_contains "$OUT" "按退避重查" "M61：既然不认为是滞后，重查也不会发生（本该重查 3 次）"

# --- M62（17-fix3 ②④）：拆掉**滞后重查收尾**那个 fail-closed 出口 → 重查期间成因变成「选不出版本对」，
#     却仍被报成「滞后，重跑流水线即可」（重跑在同一份陈旧 checkout 上只会复现）---
# 这个出口的独有价值正是「按最终状态重新分类」：只有它能把 http / nopair 这两种收尾说对——
# 后面那个 fail-closed:to 出口读的是最后一次分类的结果，接口失败时那个值还停在 lag。
# fixture 分三段：第 1 次 GET（预采样）= 本次提交 → ok；第 2 次（发布前采样）= 旧版本 → lag 触发重查；
# 第 3 次起落到无序号那份，PS_TGT=NONE 让它只有 MERGE_SOURCE → 选不出版本对。
IFXLAG2="$tmp/ifx-lag-late"
mkdir -p "$IFXLAG2"
cp "$IFX"/create-comment-inline.*.json "$IFXLAG2/"
mk_lag_late() {
  local base
  base=$(git merge-base origin/master HEAD)
  jq -n --arg sha "$(git rev-parse HEAD)" --arg base "$base" '[
    {patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:$base},
    {patchSetBizId:"src-2", versionNo:9, relatedMergeItemType:"MERGE_SOURCE", commitId:$sha}
  ]' > "$IFXLAG2/list-patchsets.1.json"
  jq -n --arg sha "$(git rev-parse 'HEAD^')" --arg base "$base" '[
    {patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:$base},
    {patchSetBizId:"src-9", versionNo:9, relatedMergeItemType:"MERGE_SOURCE", commitId:$sha}
  ]' > "$IFXLAG2/list-patchsets.2.json"
}
lag_late_case() { # <用例名> <集成包根>
  PS_TGT=NONE PS_SRC_ID=src-9 MUT_TWEAK=mk_lag_late inline_case "$1" "$2" "$IFXLAG2" CODEUP_RETRY_BACKOFF=0
}
lag_late_case baseline-lag-late "$ROOT"
assert_rc "$RC" 0 "对照：发布前才滞后、重查又选不出版本对时评审成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "对照：0 条行内评论"
assert_contains "$OUT" "两次采样：checkout 时判定=ok" "对照：两次采样比对写进日志"
assert_contains "$(posted_comment "$OUT")" "选不出「最新合并目标版本 + 最新合并源版本」这一对" \
  "对照：按最终状态（选不出版本对）给 notice"
assert_not_contains "$(posted_comment "$OUT")" "重跑流水线即可" "对照：不谎称滞后"
pkg=$(make_mutant m62-lag-exit '/# fail-closed:lag-end$/ s/return 1/:/')
lag_late_case m62 "$pkg"
assert_rc "$RC" 0 "M62：变异体仍能跑完"
comment=$(posted_comment "$OUT")
# 出口一拆，流程继续往下走，被后面那个 fail-closed:to 出口接住——而它读的是**最后一次分类**的结果，
# 选不出版本对时那个值还停在 lag。于是同一条汇总里出现两句互相矛盾的成因，而且给出「重跑流水线」
# 这条只会复现的建议（重跑在同一份陈旧 checkout 上还是选不出版本对）。
assert_contains "$comment" "尚未包含本次提交" \
  "M62：出口一拆，最终状态又被回落成「滞后」——端到端「不谎称滞后」断言会失败"
assert_contains "$comment" "重跑流水线即可" "M62：给出「重跑」这条只会复现的建议"
# 两句都在同一条 notice 里（INLINE_NOTICE 是拼接的，渲染成一行），所以按子串判而不是数行数
assert_contains "$comment" "选不出「最新合并目标版本 + 最新合并源版本」这一对" \
  "M62：正确的那句也还在——两句互相矛盾的成因同时进了汇总"

report
