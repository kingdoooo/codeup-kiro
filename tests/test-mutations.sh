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

# $1=变异名 $2=sed 表达式 → stdout 变异后的集成包根目录
make_mutant() {
  local name="$1" expr="$2" dst
  dst="$tmp/pkg-$name"
  mkdir -p "$dst"; cp -R "$ROOT/scripts" "$ROOT/kiro" "$ROOT/prompts" "$dst/"
  sed -e "$expr" "$ROOT/scripts/kiro-review.sh" > "$dst/scripts/kiro-review.sh"
  if cmp -s "$ROOT/scripts/kiro-review.sh" "$dst/scripts/kiro-review.sh"; then
    echo "FAIL: 变异 ${name} 没有改变脚本——sed 模式 [${expr}] 已与实现失配" >&2; exit 1
  fi
  bash -n "$dst/scripts/kiro-review.sh" || { echo "FAIL: 变异 ${name} 产生了语法错误的脚本" >&2; exit 1; }
  echo "$dst"
}
# $1=用例名 $2=集成包根目录 → 新建 fixture 并运行；结果写入全局 CASE(目录) / RC / OUT
run_case() {
  local name="$1" pkg="$2"
  CASE="$tmp/case-$name"; mkdir -p "$CASE"
  make_fixture_repo "$CASE"
  export HOME="$CASE/home"; mkdir -p "$HOME"
  export REVIEW_REPO_DIR="$CASE/work" MOCK_ARGS_FILE="$CASE/args" MOCK_STDIN_FILE="$CASE/stdin" \
         MOCK_SETTINGS_FILE="$CASE/settings" MOCK_CWD_SCAN_FILE="$CASE/cwdscan" MOCK_CALLS_FILE="$CASE/calls"
  RC=0; OUT=$("$pkg/scripts/kiro-review.sh" 2>&1) || RC=$?
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
assert_contains "$(cat "$CASE/settings")" "chat.disableInheritingDefaultResources true" "对照：settings 已调用"

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

# --- M3：删掉 settings 调用 → 继承未被禁用 ---
pkg=$(make_mutant m3-settings '/chat.disableInheritingDefaultResources true/d')
run_case m3 "$pkg"
assert_rc "$RC" 0 "M3：变异体仍能跑完"
assert_eq "$([[ -s "$CASE/settings" ]] && echo called || echo none)" "none" "M3：settings 未被调用——端到端断言会失败"

report
