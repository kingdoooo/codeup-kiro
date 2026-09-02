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
  bash -n "$dst/$target" || { echo "FAIL: 变异 ${name} 让 ${target} 产生语法错误" >&2; exit 1; }
  echo "$dst"
}
# $1=用例名 $2=集成包根目录 → 新建 fixture 并运行；结果写入全局 CASE(目录) / RC / OUT
# 用法：run_case <用例名> <集成包根目录> [VAR=值 ...]（额外的 VAR=值 只作用于这一次调用）
run_case() {
  local name="$1" pkg="$2"; shift 2
  CASE="$tmp/case-$name"; mkdir -p "$CASE"
  make_fixture_repo "$CASE"
  export HOME="$CASE/home"; mkdir -p "$HOME"
  export REVIEW_REPO_DIR="$CASE/work" MOCK_ARGS_FILE="$CASE/args" MOCK_STDIN_FILE="$CASE/stdin" \
         MOCK_SETTINGS_FILE="$CASE/settings" MOCK_CWD_SCAN_FILE="$CASE/cwdscan" MOCK_CALLS_FILE="$CASE/calls"
  RC=0; OUT=$(env "$@" "$pkg/scripts/kiro-review.sh" 2>&1) || RC=$?
}

# --- 对照：未变异的实现，三项守卫全部成立（否则下面的「失败」没有参照意义）---
run_case baseline "$ROOT"
assert_rc "$RC" 0 "对照：未变异实现成功"
assert_eq "$([[ -e "$CASE/work/AGENTS.md" || -e "$CASE/work/src/sub/AGENTS.md" ]] && echo exists || echo gone)" "gone" "对照：AGENTS.md 已移除"
assert_eq "$(cat "$CASE/cwdscan")" "" "对照：Kiro 启动时工作区干净"
assert_eq "$([[ -e "$CASE/work/src/sub/.kiro" || -e "$CASE/work/lsp.json" ]] && echo exists || echo gone)" "gone" "对照：子目录 .kiro/ 与根 lsp.json 已移除"
assert_contains "$(paste -sd' ' "$CASE/args")" "--agent codeup-reviewer" "对照：参数含 --agent codeup-reviewer"
assert_eq "$(grep -c -x -- '--trust-tools=read,grep,glob' "$CASE/args")" "1" "对照：--trust-tools 精确"
assert_contains "$(paste -sd' ' "$CASE/args")" "--agent-engine v2" "对照：参数含 --agent-engine v2"
assert_contains "$(paste -sd' ' "$CASE/args")" "--output-format stream-json" "对照：参数含 --output-format stream-json"
assert_contains "$(cat "$CASE/settings")" "chat.disableInheritingDefaultResources true" "对照：settings 已调用"
assert_contains "$OUT" "P0 1 · P1 1 · P2 1" "对照：评论按契约渲染出分级统计"
assert_contains "$OUT" "Kiro 用量：credits=0.2609" "对照：credits 用量写进日志"
assert_not_contains "$OUT" "结构化解析失败" "对照：未变异实现不降级"

# --- M1：删掉 AGENTS.md 移除逻辑 → AGENTS.md 残留、Kiro 启动时仍能看到 ---
pkg=$(make_mutant m1-agentsmd '/-iname AGENTS.md/d')
run_case m1 "$pkg"
assert_rc "$RC" 0 "M1：变异体仍能跑完（只是失去防护）"
assert_eq "$([[ -e "$CASE/work/AGENTS.md" && -e "$CASE/work/src/sub/AGENTS.md" ]] && echo exists || echo gone)" "exists" \
  "M1：移除逻辑被删后根与子目录 AGENTS.md 残留——端到端断言「AGENTS.md 已移除」会失败"
assert_contains "$(cat "$CASE/cwdscan")" "AGENTS.md" "M1：Kiro 启动时工作区扫描到 AGENTS.md——端到端断言「工作区干净」会失败"
assert_contains "$(cat "$CASE/stdin")" "CANARY-AGENTSMD-ROOT" "M1：diff 内容不受移除逻辑影响（对照两侧一致）"

# --- M2：删掉 --agent-engine 参数 → 引擎不再钉死 ---
pkg=$(make_mutant m2-engine 's/--agent-engine "\$KIRO_ENGINE"//')
run_case m2 "$pkg"
assert_rc "$RC" 0 "M2：变异体仍能跑完"
assert_not_contains "$(paste -sd' ' "$CASE/args")" "--agent-engine v2" "M2：参数中不再有 --agent-engine v2——端到端断言会失败"

# --- M4：删掉 --agent 参数 → 以默认 agent 运行（无拒绝路径、无只读提示词）---
pkg=$(make_mutant m4-agent 's/ --agent "\$AGENT_NAME"//')
run_case m4 "$pkg"
assert_rc "$RC" 0 "M4：变异体仍能跑完"
assert_not_contains "$(paste -sd' ' "$CASE/args")" "--agent codeup-reviewer" "M4：参数中不再有 --agent codeup-reviewer——端到端断言会失败"

# --- M5：--trust-tools 放宽到 shell → 精确匹配断言必须失败 ---
pkg=$(make_mutant m5-trust 's/--trust-tools=read,grep,glob/--trust-tools=read,grep,glob,shell/')
run_case m5 "$pkg"
assert_rc "$RC" 0 "M5：变异体仍能跑完"
assert_eq "$(grep -c -x -- '--trust-tools=read,grep,glob' "$CASE/args")" "0" "M5：精确的 --trust-tools=read,grep,glob 不再出现——端到端断言会失败"

# --- M6：删掉任意深度 .kiro/ 的删除逻辑 → 子目录 .kiro/ 残留、Kiro 启动时能看到 ---
pkg=$(make_mutant m6-kiro-dirs '/-name .kiro -type d/d')
run_case m6 "$pkg"
assert_rc "$RC" 0 "M6：变异体仍能跑完"
assert_eq "$([[ -d "$CASE/work/src/sub/.kiro" ]] && echo exists || echo gone)" "exists" "M6：子目录 .kiro/ 残留——端到端断言「.kiro 已移除」会失败"
assert_contains "$(cat "$CASE/cwdscan")" "src/sub/.kiro" "M6：Kiro 启动时工作区扫描到子目录 .kiro——端到端断言「工作区干净」会失败"

# --- M7：删掉根 lsp.json 的删除逻辑 → lsp.json 残留 ---
pkg=$(make_mutant m7-lspjson '/rm -rf .\/lsp.json/d')
run_case m7 "$pkg"
assert_rc "$RC" 0 "M7：变异体仍能跑完"
assert_eq "$([[ -e "$CASE/work/lsp.json" ]] && echo exists || echo gone)" "exists" "M7：根 lsp.json 残留——端到端断言「lsp.json 已移除」会失败"
assert_contains "$(cat "$CASE/cwdscan")" "./lsp.json" "M7：Kiro 启动时工作区扫描到 lsp.json——端到端断言「工作区干净」会失败"

# --- M8：删掉 --output-format stream-json → 替身回到纯文本，事件流里没有 runFinished ---
# 证明：结构化契约路径真的依赖这个参数，缺了会「评审失败」而不是静默降级或静默通过。
pkg=$(make_mutant m8-streamjson 's/--output-format stream-json//')
run_case m8 "$pkg"
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "M8：删掉 --output-format 后评审失败——端到端「成功路径退出码 0」会失败"
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

# --- M10：拿掉 severity 的 P0/P1/P2 白名单 → 非法级别不再被丢弃，丢弃计数变化 ---
pkg=$(make_mutant m10-sev-filter 's/| select(($sev == "P0" or $sev == "P1" or $sev == "P2")/| select((true)/' scripts/lib/review-render.sh)
run_case m10 "$pkg" MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/dirty.json"
assert_rc "$RC" 0 "M10：变异体仍能跑完"
assert_not_contains "$OUT" "7 条问题不符合输出契约已丢弃" "M10：级别白名单被拿掉后丢弃数不再是 7——端到端丢弃断言会失败"
assert_contains "$OUT" "4 条问题不符合输出契约已丢弃" "M10：只剩缺 title/body 与非对象被丢弃（4 条）"

# --- M3：删掉 settings 调用 → 继承未被禁用 ---
pkg=$(make_mutant m3-settings '/chat.disableInheritingDefaultResources true/d')
run_case m3 "$pkg"
assert_rc "$RC" 0 "M3：变异体仍能跑完"
assert_eq "$([[ -s "$CASE/settings" ]] && echo called || echo none)" "none" "M3：settings 未被调用——端到端断言会失败"

report
