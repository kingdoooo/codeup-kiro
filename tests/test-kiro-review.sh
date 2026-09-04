#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
source fixture-repo.sh

# kiro-review.sh 把 timeout/gtimeout 当强制依赖（无超时能力时拒绝运行），
# 本机缺失时它在第一步就退出，本套件的每条断言都测不到真实行为。
# 与其让成功路径断言炸掉（macOS 默认无 timeout），整体跳过并说明原因。
if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null; then
  echo "SKIP: 本机无 timeout/gtimeout（GNU coreutils），跳过 test-kiro-review.sh" >&2
  exit 0
fi

ROOT=$(cd .. && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- 公共环境 ---
export PATH="$ROOT/tests/mockbin:$PATH"
# REVIEW_RERUN_HINT 是渲染器唯一的隐式环境输入：开发者环境里导出了它，
# 「默认取 Flow 语义」的断言与 golden 比对就会莫名失败（run_case 用 env 继承外部环境）。
unset REVIEW_RERUN_HINT
export DRY_RUN=1 KIRO_API_KEY=k YUNXIAO_TOKEN=t YUNXIAO_ORG_ID=org123 CODEUP_REPO_ID=456
export MR_LOCAL_ID=7 MR_TARGET_BRANCH=master CI_COMMIT_REF_NAME=feature/x

# 每个用例都重建 fixture（全部注入面文件重新就位，否则第一次运行删完后后面的「工作区干净」断言全是空转）、
# 独立 HOME，并 cd 进业务库 checkout 再调用（模拟 Flow 在 PROJECT_DIR 下调用脚本，让 REVIEW_REPO_DIR
# 回退与 `cd "$PKG_ROOT"` 保护都处在真实条件下）。
# 用法：run_case <名字> [VAR=值 ...]   额外的 VAR=值 只作用于这一次调用（VAR= 表示置空）。
# 可选：CASE_TWEAK=<函数名> 在运行前于 checkout 目录内执行，用来改造 fixture。
# 结果：CASE（用例目录）、RC、OUT；替身记录在 $CASE/{args,stdin,settings,cwdscan,calls,helpcwd}。
run_case() {
  local name="$1"; shift
  CASE="$tmp/case-$name"; mkdir -p "$CASE/home"
  make_fixture_repo "$CASE"
  if [[ -n "${CASE_TWEAK:-}" ]]; then (cd "$CASE/work" && "$CASE_TWEAK"); fi
  # 显式清空：`CASE_TWEAK=f run_case x` 这种赋值前缀是否在函数返回后仍然生效，POSIX 未定义
  # （bash 3.2 不保留，POSIX 模式下保留）。不清掉的话，后面每个用例都会跑在被改造过的 fixture 上。
  CASE_TWEAK=""
  RC=0
  OUT=$(cd "$CASE/work" && env HOME="$CASE/home" REVIEW_REPO_DIR="$CASE/work" \
        MOCK_ARGS_FILE="$CASE/args" MOCK_STDIN_FILE="$CASE/stdin" MOCK_SETTINGS_FILE="$CASE/settings" \
        MOCK_CWD_SCAN_FILE="$CASE/cwdscan" MOCK_CALLS_FILE="$CASE/calls" MOCK_HELP_CWD_FILE="$CASE/helpcwd" \
        "$@" "$ROOT/scripts/kiro-review.sh" 2>&1) || RC=$?
}
# 某个 kiro-cli 子命令被调用了几次。calls 文件在「脚本还没调过任何 kiro-cli 子命令」时
# 根本不存在（例如变量校验在安装/能力检查之前就失败了），所以缺文件按 0 处理。
call_count() { local f="$1" name="$2"; [[ -f "$f" ]] || { echo 0; return 0; }; grep -c "^${name}$" "$f" || true; }
# 注入面文件是否还在（任意深度 AGENTS.md / 任意深度 .kiro / 根 lsp.json）
leftovers() { (cd "$CASE/work" && { [[ -e lsp.json ]] && echo ./lsp.json; find . -not -path './.git/*' \( -iname AGENTS.md -not -type d \) -o \( -name .kiro -not -path './.git/*' \); } | sort | paste -sd' ' -); }

# 从 DRY_RUN 输出里取出将要回写的评论正文（OUT 同时含日志与超长时回显的全文，
# 有些断言必须只看评论本身）。用法：posted_comment "$OUT"
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

# ============ 成功路径 ============
run_case ok
out=$OUT
assert_rc "$RC" 0 "成功路径退出码 0"
assert_contains "$(cat "$CASE/args")" "--no-interactive" "kiro 参数：no-interactive"
# 参数文件每行一个参数：用整行精确匹配，避免 --trust-tools=read,grep,glob,shell 或 --agent-engine 也能蒙混过关
assert_eq "$(grep -c -x -- '--trust-tools=read,grep,glob' "$CASE/args")" "1" "kiro 参数：--trust-tools 精确等于 read,grep,glob"
assert_eq "$(grep -c -- '^--trust-tools=' "$CASE/args")" "1" "kiro 参数：只有一个 --trust-tools"
args_line=$(paste -sd' ' "$CASE/args")
assert_contains "$args_line" "--agent codeup-reviewer" "kiro 参数：套用受信 custom agent codeup-reviewer"
assert_contains "$args_line" "--agent-engine v2" "kiro 参数：固定 --agent-engine v2"
assert_contains "$out" "引擎：v2" "日志显式记录所用引擎为 v2"
# 结构化输出契约依赖 stream-json（v1 引擎不支持该参数）：整行精确匹配，避免别的取值蒙混过关
assert_eq "$(grep -c -x -- '--output-format' "$CASE/args")" "1" "kiro 参数：只有一个 --output-format"
assert_contains "$args_line" "--output-format stream-json" "kiro 参数：固定 --output-format stream-json"
assert_contains "$(cat "$CASE/stdin")" "SECRET_KEY" "diff 已喂入 stdin"
assert_contains "$out" "changeRequests/7/comments" "回写到 MR 7"

# --- 汇总评论（INLINE_COMMENT=0）：由脚本按契约渲染，不再是模型原文 ---
assert_contains "$out" "# Kiro 代码评审" "评论标题（一级标题，无图标）"
assert_contains "$out" "<!-- kiro-review:" "评论含评审标记"
assert_contains "$out" "run:1" "评审标记含评审次数"
assert_contains "$out" "变更摘要" "评论含变更摘要小节"
assert_contains "$out" "结论：建议修改后合并" "评论含中文化的总体结论"
assert_contains "$out" "硬编码凭证必须先移除" "评论含结论理由"
assert_contains "$out" "P0 1 · P1 1 · P2 1" "评论含问题统计"
assert_contains "$out" "重点关注文件" "评论含重点关注文件表"
assert_contains "$out" "P0 必须修复（1）" "评论按级别分组"
assert_contains "$out" "P1 应当修复（1）" "评论按级别分组：P1"
assert_contains "$out" "P2 可选改进（1）" "评论按级别分组：P2"
assert_contains "$out" "硬编码疑似应用密钥" "评论含问题标题"
assert_contains "$out" "src/app.py:2" "评论含问题定位 文件:行"
assert_contains "$out" "src/app.py:3-4" "评论含多行区间定位"
assert_contains "$out" "（未定位）" "评论标注未定位问题（file/line 为 null）"
assert_contains "$out" "修复建议" "评论含修复建议"
assert_contains "$out" "P0 必须修复 · P1 应当修复 · P2 可选改进" "评论含页脚图例"
assert_contains "$out" "第 1 次评审 · P0 必须修复" "页脚自报第 1 次评审"
assert_contains "$out" "重跑流水线可重新评审" "评论含重新评审提示（默认 Flow 语义）"
assert_not_contains "$out" "/kiro review" "评论不承诺 Flow 档位接不到的评论命令（ADR-0001）"
assert_not_contains "$out" "🔴" "评论不再出现红灯"
assert_not_contains "$out" "🟡" "评论不再出现黄灯"
assert_not_contains "$out" "🔵" "评论不再出现蓝灯"
assert_not_contains "$out" "结构化解析失败" "成功路径不出现降级标题"
# 掩码：评审员按提示词只给掩码值，diff 里的原始假密钥不得出现在评论里
assert_contains "$out" "FAKE****0000" "评论含掩码后的疑似密钥"
assert_not_contains "$out" "FAKE-TEST-KEY-0000" "评论不含 diff 里的原始密钥值"
# stream-json 的事件流本身（工具轨迹、chunk）不得进评论
assert_not_contains "$out" "agent_message_chunk" "评论不含事件流原文"
assert_not_contains "$out" "tool_call" "评论不含工具调用事件"
assert_not_contains "$out" "runFinished" "评论不含事件类型名"
assert_not_contains "$out" "KIRO_REVIEW_JSON" "评论不含契约标记本身"
esc=$(printf '\033')
assert_not_contains "$out" "${esc}[" "清洗：不含 ANSI 控制序列"

# --- credits 与上下文占用写流水线日志（票 02 验收项）---
assert_contains "$out" "Kiro 用量：credits=0.2609" "日志记录 credits 用量（累加 meteringUsage）"
assert_contains "$out" "context=3.8%" "日志记录上下文占用"
assert_contains "$out" "评审报告：P0 1 · P1 1 · P2 1" "日志记录各级别问题数"

# --- 隔离：diff 先算好，随后业务库工作树中的注入面文件在 Kiro 启动前被移除 ---
assert_contains "$(cat "$CASE/stdin")" "CANARY-AGENTSMD-ROOT" "diff 先算：stdin 仍含根 AGENTS.md 的改动"
assert_contains "$(cat "$CASE/stdin")" "CANARY-AGENTSMD-NESTED" "diff 先算：stdin 仍含子目录 AGENTS.md 的改动"
assert_contains "$(cat "$CASE/stdin")" "+++ b/lsp.json" "diff 先算：stdin 仍含 lsp.json 的改动"
assert_contains "$(cat "$CASE/stdin")" "mcpServers" "diff 先算：stdin 仍含 .kiro/settings/mcp.json 的改动"
assert_eq "$(cat "$CASE/cwdscan")" "" "Kiro 启动时工作区已无 AGENTS.md（任意深度）/根 lsp.json/.kiro（任意深度）"
assert_eq "$(leftovers)" "" "运行后工作树无残留注入面文件"
assert_eq "$([[ -f "$CASE/work/src/app.py" ]] && echo y || echo n)" "y" "其余业务文件未被误删"
assert_eq "$([[ -d "$CASE/work/.git" ]] && echo y || echo n)" "y" ".git 未被触碰"
diff_ln=$(printf '%s\n' "$out" | grep -n 'diff 已生成' | head -1 | cut -d: -f1)
iso_ln=$(printf '%s\n' "$out" | grep -n '隔离：' | head -1 | cut -d: -f1)
assert_eq "$([[ -n "$diff_ln" && -n "$iso_ln" && "$iso_ln" -gt "$diff_ln" ]] && echo ok || echo bad)" "ok" \
  "隔离步骤的日志出现在 diff 生成之后（diff_ln=${diff_ln:-?} iso_ln=${iso_ln:-?}）"

# --- 隔离：执行环境禁止继承工作区默认资源，且在 Kiro 启动前生效 ---
assert_contains "$(cat "$CASE/settings")" "chat.disableInheritingDefaultResources true" "Kiro 启动前设置 chat.disableInheritingDefaultResources=true"
assert_eq "$(awk '/^settings$/{s=NR} /^chat$/{c=NR} END{print (s && c && s<c) ? "ok" : "bad"}' "$CASE/calls")" "ok" \
  "调用顺序：settings 先于 chat"
assert_eq "$(cat "$CASE/helpcwd")" "$ROOT" "kiro-cli chat --help 在集成包目录下执行，而不是尚未隔离的业务库 checkout"

# --- 受信 agent 安装：按 name 落盘，prompt 改写为集成包内提示词的绝对 file:// 路径 ---
inst="$CASE/home/.kiro/agents/codeup-reviewer.json"
assert_eq "$([[ -f "$inst" ]] && echo y || echo n)" "y" "受信 agent 已安装到 ~/.kiro/agents/codeup-reviewer.json"
inst_prompt=$(jq -r .prompt "$inst")
assert_eq "$([[ "$inst_prompt" == file:///*/prompts/review-agent-prompt.md ]] && echo abs || echo other)" "abs" \
  "安装后的 prompt 为绝对 file:// 路径（实际：${inst_prompt}）"
assert_eq "$([[ -r "${inst_prompt#file://}" ]] && echo y || echo n)" "y" "prompt 引用的提示词文件存在且可读"
assert_eq "$(jq -c '[.includeMcpJson, .includePowers]' "$inst")" "[false,false]" "安装后的 agent 不含 MCP/Powers"
assert_eq "$(jq -c 'del(.prompt)' "$inst")" "$(jq -c 'del(.prompt)' "$ROOT/kiro/agent-codeup-reviewer.json")" "安装只改写 prompt，其余字段与集成包一致"

# ============ REVIEW_REPO_DIR 未设置：回退到 cwd（Flow 里 PROJECT_DIR 就是 cwd）============
run_case fallback REVIEW_REPO_DIR=
assert_rc "$RC" 0 "REVIEW_REPO_DIR 未设置：以 cwd 为业务库成功运行"
assert_eq "$(leftovers)" "" "REVIEW_REPO_DIR 未设置：隔离作用在 cwd 上"
assert_contains "$OUT" "changeRequests/7/comments" "REVIEW_REPO_DIR 未设置：仍回写评论"

# ============ 同名目录/文件不是注入面，但也不能让它卡死评审 ============
tweak_lsp_dir() { rm -rf lsp.json .kiro; mkdir -p lsp.json/sub && echo x > lsp.json/sub/f; echo notadir > .kiro; }
CASE_TWEAK=tweak_lsp_dir run_case lspdir
assert_rc "$RC" 0 "lsp.json 为目录 / .kiro 为文件：评审仍成功"
assert_eq "$(leftovers)" "" "lsp.json 目录、.kiro 文件与子目录 .kiro/、AGENTS.md 都已移除"
assert_eq "$(cat "$CASE/cwdscan")" "" "Kiro 启动时工作区干净"

# ============ 误把集成包自身当业务库：拒绝运行，且集成包内的文件确实还在 ============
# 用集成包的**副本**跑，不拿开发者的真实 checkout 当靶子；并在副本里放一个哨兵 AGENTS.md，
# 断言它仍在——原来那条断言（git status 里没有 ' D'）是恒真的：仓库里根本没有跟踪任何
# AGENTS.md/.kiro/lsp.json，删多少个都不会出现在 git status 的那个 pathspec 里（R10③）。
PKGCOPY="$tmp/pkgcopy"
mkdir -p "$PKGCOPY"
cp -R "$ROOT/scripts" "$ROOT/kiro" "$ROOT/prompts" "$PKGCOPY/"
printf '# 集成包内的哨兵文件\n隔离逻辑一旦作用在集成包上，这个文件会被删掉。\n' > "$PKGCOPY/AGENTS.md"
mkdir -p "$PKGCOPY/.kiro/settings" && echo '{}' > "$PKGCOPY/.kiro/settings/cli.json"
sentinel_intact() {
  [[ -f "$PKGCOPY/AGENTS.md" && -f "$PKGCOPY/.kiro/settings/cli.json" ]] && echo intact || echo deleted
}
assert_eq "$(sentinel_intact)" "intact" "前置：哨兵文件已就位（否则下面的断言恒真）"

RC=0; CASE="$tmp/case-selftarget"; mkdir -p "$CASE/home"
OUT=$(cd "$PKGCOPY" && env HOME="$CASE/home" REVIEW_REPO_DIR="$PKGCOPY" \
      MOCK_ARGS_FILE="$CASE/args" "$PKGCOPY/scripts/kiro-review.sh" 2>&1) || RC=$?
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "REVIEW_REPO_DIR=集成包：非零退出"
assert_contains "$OUT" "互相包含" "REVIEW_REPO_DIR=集成包：报错说明"
assert_eq "$([[ -e "$CASE/args" ]] && echo launched || echo not-launched)" "not-launched" "REVIEW_REPO_DIR=集成包：Kiro 未被启动"
assert_eq "$(sentinel_intact)" "intact" "REVIEW_REPO_DIR=集成包：集成包内的 AGENTS.md 与 .kiro/ 都还在"

# 符号链接不能绕过这道保护（R10①：路径规范化必须用 pwd -P）
ln -s "$PKGCOPY" "$tmp/pkglink"
RC=0; CASE="$tmp/case-selflink"; mkdir -p "$CASE/home"
OUT=$(cd "$tmp" && env HOME="$CASE/home" REVIEW_REPO_DIR="$tmp/pkglink" \
      MOCK_ARGS_FILE="$CASE/args" "$PKGCOPY/scripts/kiro-review.sh" 2>&1) || RC=$?
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "REVIEW_REPO_DIR=指向集成包的符号链接：非零退出"
assert_contains "$OUT" "互相包含" "符号链接：同样被这道保护拦住"
assert_eq "$(sentinel_intact)" "intact" "符号链接：集成包内的哨兵文件仍在"

# REVIEW_REPO_DIR 在集成包**内部**同样会删到集成包的文件，反向包含也要拦
RC=0; CASE="$tmp/case-selfinner"; mkdir -p "$CASE/home" "$PKGCOPY/nested"
OUT=$(cd "$tmp" && env HOME="$CASE/home" REVIEW_REPO_DIR="$PKGCOPY/nested" \
      MOCK_ARGS_FILE="$CASE/args" "$PKGCOPY/scripts/kiro-review.sh" 2>&1) || RC=$?
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "REVIEW_REPO_DIR=集成包内的子目录：非零退出"
assert_contains "$OUT" "互相包含" "反向包含：同样被拦住"
assert_eq "$(sentinel_intact)" "intact" "反向包含：集成包内的哨兵文件仍在"

# ============ 符号链接形式的 .kiro 也必须被移除（R10②）============
tweak_kiro_symlink() {
  rm -rf src/sub/.kiro
  mkdir -p ../evilcfg/settings && echo '{"mcpServers":{"evil":{"command":"curl"}}}' > ../evilcfg/settings/mcp.json
  ln -s ../../../evilcfg src/sub/.kiro
}
CASE_TWEAK=tweak_kiro_symlink run_case kirosymlink
CASE_TWEAK=
assert_rc "$RC" 0 ".kiro 是符号链接：评审仍成功"
assert_eq "$([[ -e "$CASE/work/src/sub/.kiro" || -L "$CASE/work/src/sub/.kiro" ]] && echo exists || echo gone)" "gone" \
  ".kiro 为符号链接时同样被移除（原来 find -type d 漏掉链接）"
assert_eq "$(cat "$CASE/cwdscan")" "" ".kiro 为符号链接：Kiro 启动时工作区干净"
assert_eq "$([[ -f "$CASE/evilcfg/settings/mcp.json" ]] && echo y || echo n)" "y" \
  "只删链接本身，不跟着链接把目标目录的内容删掉"

# ============ 失败路径：kiro 失败 → 回写"评审未完成" + 非零退出 ============
run_case kirofail MOCK_KIRO_FAIL=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "kiro 失败：非零退出"
assert_contains "$OUT" "评审未完成" "kiro 失败：回写说明评论"

# ============ 失败路径：退出码 0 但输出为空 → 同失败处理 ============
run_case empty MOCK_KIRO_EMPTY=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "空输出：非零退出"
assert_contains "$OUT" "评审未完成" "空输出：回写说明评论"

# ============ 失败路径：挂起 → 超时强杀（timeout/gtimeout 已由文件开头的前置检查保证）============
run_case hang MOCK_KIRO_HANG=1 KIRO_TIMEOUT=3
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "挂起：超时后非零退出"
assert_contains "$OUT" "评审未完成" "挂起：回写说明评论"

# ============ 失败路径：settings 设置失败 → 隔离不成立，不启动 Kiro，回写"评审未完成" ============
run_case settingsfail MOCK_SETTINGS_FAIL=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "settings 失败：非零退出"
assert_contains "$OUT" "评审未完成" "settings 失败：回写说明评论"
assert_contains "$OUT" "disableInheritingDefaultResources" "settings 失败：日志点名失败的设置项"
assert_eq "$([[ -e "$CASE/args" ]] && echo launched || echo not-launched)" "not-launched" "settings 失败：Kiro 未被启动"

# ============ 失败路径：kiro-cli 不支持 --agent-engine（旧版）→ 拒绝运行，且 MR 上可见（spec I10）============
run_case oldcli MOCK_KIRO_NO_ENGINE_FLAG=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "旧版 kiro-cli：非零退出"
assert_contains "$OUT" "--agent-engine" "旧版 kiro-cli：报错点名 --agent-engine"
assert_contains "$OUT" "评审未完成" "旧版 kiro-cli：回写「评审未完成」评论（失败可见）"
assert_contains "$OUT" "changeRequests/7/comments" "旧版 kiro-cli：评论发到 MR 7"
assert_eq "$([[ -e "$CASE/args" ]] && echo launched || echo not-launched)" "not-launched" "旧版 kiro-cli：Kiro 未被启动"

# ============ 评论截断：MAX_COMMENT_BYTES 很小时评论被截断并注明 ============
run_case truncate MAX_COMMENT_BYTES=200
assert_rc "$RC" 0 "截断路径仍成功"
assert_contains "$OUT" "已截断" "截断注明"

# ============ 失败路径：提示词文件不可读 → 立即失败，不带空提示词跑 Kiro ============
run_case noprompt PROMPT_FILE=/nonexistent
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "提示词缺失：非零退出"
assert_contains "$OUT" "提示词文件不可读" "提示词缺失：报错说明"
assert_eq "$([[ -e "$CASE/args" ]] && echo launched || echo not-launched)" "not-launched" "提示词缺失：Kiro 未被启动"

# ============ 降级：finalText 无契约标记 → 标题标明「结构化解析失败」+ 贴原文 + 退出码 0 ============
run_case nomarker MOCK_KIRO_NO_MARKER=1
assert_rc "$RC" 0 "无契约标记：退出码仍为 0（评审已产出，不算失败）"
assert_contains "$OUT" "结构化解析失败" "无契约标记：评论标题含「结构化解析失败」"
assert_contains "$OUT" "没有成对的" "无契约标记：评论写明失败原因"
assert_contains "$OUT" "P0 必须修复：发现硬编码密钥" "无契约标记：正文为评审员输出原文"
assert_contains "$OUT" "总体结论：建议修改后合并" "无契约标记：原文全文（含结论）"
assert_contains "$OUT" "changeRequests/7/comments" "无契约标记：评论仍发到 MR"
assert_contains "$OUT" "<!-- kiro-review:" "无契约标记：降级评论仍带评审标记"
assert_not_contains "$OUT" "评审未完成" "无契约标记：不是失败评论"
assert_not_contains "$OUT" "问题统计" "无契约标记：没有伪造的分级统计"

# ============ 降级：标记内 JSON 非法 → 同样降级 ============
run_case badjson MOCK_KIRO_BAD_JSON=1
assert_rc "$RC" 0 "非法契约 JSON：退出码仍为 0"
assert_contains "$OUT" "结构化解析失败" "非法契约 JSON：评论标题含「结构化解析失败」"
assert_contains "$OUT" "不是恰好一个 JSON 对象" "非法契约 JSON：评论写明失败原因"
assert_contains "$OUT" "缺右括号" "非法契约 JSON：正文为原文（含那段坏 JSON）"
assert_not_contains "$OUT" "评审未完成" "非法契约 JSON：不是失败评论"

# ============ Kiro 失败：runFinished.status 非 success → 走失败评论路径（非零退出）============
run_case statusfailed MOCK_KIRO_STATUS_FAILED=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "status 非 success：非零退出"
assert_contains "$OUT" "评审未完成" "status 非 success：回写失败评论"
assert_contains "$OUT" "自报运行失败" "status 非 success：错误说明点名原因"
assert_contains "$OUT" "status=error" "status 非 success：错误说明带上 status 值"
assert_not_contains "$OUT" "结构化解析失败" "status 非 success：不走降级（不是解析问题）"

# ============ Kiro 失败：事件流没有 runFinished → 走失败评论路径 ============
run_case norunfinished MOCK_KIRO_NO_RUNFINISHED=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "无 runFinished：非零退出"
assert_contains "$OUT" "评审未完成" "无 runFinished：回写失败评论"
assert_contains "$OUT" "没有 runFinished 事件" "无 runFinished：错误说明点名原因"
assert_not_contains "$OUT" "结构化解析失败" "无 runFinished：不走降级"

# ============ 没有 metadata 事件：credits 取不到也不能让评审失败 ============
run_case nometa MOCK_KIRO_NO_METADATA=1
assert_rc "$RC" 0 "无 metadata：评审仍成功"
assert_contains "$OUT" "Kiro 用量：credits=- context=-" "无 metadata：用量日志降级为 -"
assert_contains "$OUT" "P0 1 · P1 1 · P2 1" "无 metadata：评论照常渲染"

# ============ 字段校验：不合契约的问题被丢弃并计数（级别越界 / 缺 title / 缺 body）============
run_case dropped MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/dirty.json"
assert_rc "$RC" 0 "含非法问题的契约：评审仍成功"
assert_contains "$OUT" "7 条问题不符合输出契约已丢弃" "丢弃计数写进流水线日志"
assert_contains "$OUT" "另有 7 条不合契约已丢弃" "丢弃计数写进评论的问题统计"
assert_contains "$OUT" "P0 1 · P1 0 · P2 2" "只统计留下的合法问题"
assert_contains "$OUT" "合法的 P0" "保留合法问题"
assert_not_contains "$OUT" "级别越界" "丢弃级别非 P0/P1/P2 的问题"
assert_not_contains "$OUT" "级别是中文灯" "丢弃用中文灯当级别的问题"
assert_not_contains "$OUT" "缺说明" "丢弃 body 为空白的问题"
assert_not_contains "$OUT" "缺 body 字段本身" "丢弃缺 body 字段的问题"

# ============ INLINE_COMMENT 取值非 0/1：拒绝运行且 MR 上可见，不静默按 0 跑 ============
run_case inlinebad INLINE_COMMENT=yes
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "INLINE_COMMENT=yes：非零退出"
assert_contains "$OUT" "INLINE_COMMENT=yes" "INLINE_COMMENT=yes：报错点名开关取值"
assert_contains "$OUT" "评审未完成" "INLINE_COMMENT=yes：回写失败评论（失败可见）"
assert_eq "$([[ -e "$CASE/args" ]] && echo launched || echo not-launched)" "not-launched" "INLINE_COMMENT=yes：不浪费额度，Kiro 未被启动"

# ============ INLINE_COMMENT 显式为 0：与默认一致 ============
run_case inline0 INLINE_COMMENT=0
assert_rc "$RC" 0 "INLINE_COMMENT=0：成功"
assert_contains "$OUT" "P0 必须修复（1）" "INLINE_COMMENT=0：完整问题清单展开"
assert_not_contains "$OUT" "折叠区" "INLINE_COMMENT=0：问题清单不进折叠区"
# 唯一的 <details> 是票 03 的「历次评审」，问题清单本身仍然全部展开
assert_eq "$(printf '%s\n' "$(posted_comment "$OUT")" | grep -c '<details>')" "1" "INLINE_COMMENT=0：只有历次评审一个折叠块"

# ============ R4：业务库无法预先造出「本次」标记，伪造块不再能让评审降级 ============
# 替身模拟：真契约用本次 nonce，随后原文引用业务库里的假契约块（假块用别的 nonce）。
run_case foreignmarker MOCK_KIRO_DOUBLE_MARKER=1
assert_rc "$RC" 0 "别的 nonce 的伪造块：评审正常完成"
assert_not_contains "$OUT" "结构化解析失败" "别的 nonce 的伪造块：不再被迫降级（nonce 的收益）"
assert_contains "$OUT" "P0 1 · P1 1 · P2 1" "别的 nonce 的伪造块：真契约照常渲染"
assert_not_contains "$OUT" "结论：可合并" "别的 nonce 的伪造块：伪造的「可合并」没有变成结论"
assert_contains "$OUT" "结论：建议修改后合并" "别的 nonce 的伪造块：结论来自真契约"
assert_eq "$(printf '%s\n' "$OUT" | grep -c 'kiro-review:[0-9a-f]* run:1')" "1" "别的 nonce 的伪造块：评审标记恰好一个"

# ============ 本次 nonce 的标记出现两对（模型自己复述）→ 拒绝解析并降级 ============
run_case dupnonce MOCK_KIRO_DUP_NONCE=1
assert_rc "$RC" 0 "本次标记重复：退出码 0（降级不算失败）"
assert_contains "$OUT" "结构化解析失败" "本次标记重复：走降级路径"
assert_contains "$OUT" "多于一对契约标记" "本次标记重复：降级原因点明标记不唯一"
assert_not_contains "$OUT" "P0 1 · P1 1 · P2 1" "本次标记重复：不从多个候选里挑一个当结果"

# ============ 模型没照抄本次 nonce → 视为无标记并降级 ============
run_case wrongnonce MOCK_KIRO_WRONG_NONCE=1
assert_rc "$RC" 0 "nonce 不匹配：退出码 0"
assert_contains "$OUT" "结构化解析失败" "nonce 不匹配：走降级路径"
assert_contains "$OUT" "没有成对的" "nonce 不匹配：按无标记处理"

# ============ R3：受信 agent 未生效（契约缺 contract 字段）→ 失败评论，不贴模型内容 ============
run_case nocontract MOCK_KIRO_NO_CONTRACT=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "缺 contract 字段：非零退出"
assert_contains "$OUT" "受信 agent 未生效" "缺 contract 字段：错误说明点明受信 agent 未生效"
assert_contains "$OUT" "评审未完成" "缺 contract 字段：回写失败评论"
assert_not_contains "$OUT" "结构化解析失败" "缺 contract 字段：不走降级（不能把非受信产出贴出去）"
assert_not_contains "$OUT" "硬编码疑似应用密钥" "缺 contract 字段：模型给的问题内容一条都没贴出去"
assert_not_contains "$OUT" "P0 1 · P1 1 · P2 1" "缺 contract 字段：不渲染分级统计"

# ============ 容错：契约被 ```json 围栏包着仍然正常解析（不该退化成降级）============
run_case fenced MOCK_KIRO_FENCED_JSON=1
assert_rc "$RC" 0 "围栏包裹的契约：成功"
assert_not_contains "$OUT" "结构化解析失败" "围栏包裹的契约：不降级"
assert_contains "$OUT" "P0 1 · P1 1 · P2 1" "围栏包裹的契约：照常渲染分级统计"

# ============ 标记内两个 JSON 对象 → 降级（jq 默认接受 JSON 流，不拦会渲染出垃圾）============
run_case twoobjects MOCK_KIRO_TWO_OBJECTS=1
assert_rc "$RC" 0 "两个 JSON 对象：退出码 0"
assert_contains "$OUT" "结构化解析失败" "两个 JSON 对象：走降级路径"
assert_contains "$OUT" "不是恰好一个 JSON 对象" "两个 JSON 对象：降级原因点明"
assert_not_contains "$OUT" "syntax error" "两个 JSON 对象：不产生 bash 算术报错"

# ============ kiro-cli 自己截断最终消息：降级原因必须点明，别让运维反复重跑 ============
run_case truncated MOCK_KIRO_TRUNCATED=1
assert_rc "$RC" 0 "finalText 被截断：退出码 0"
assert_contains "$OUT" "结构化解析失败" "finalText 被截断：走降级路径"
assert_contains "$OUT" "finalTextTruncated=true" "finalText 被截断：降级原因点明是 kiro-cli 自身截断"
assert_contains "$OUT" "重跑同样会截断" "finalText 被截断：明确告诉运维重跑没用"

# ============ 降级路径的脚本侧掩码：评审员没守契约时不能假设它守了掩码规则 ============
run_case leaksecret MOCK_KIRO_LEAK_SECRET=1
assert_rc "$RC" 0 "原文含未掩码凭证：退出码 0"
assert_contains "$OUT" "结构化解析失败" "原文含未掩码凭证：走降级路径"
assert_not_contains "$OUT" "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" "原文含未掩码凭证：评论里不出现完整密钥"
assert_not_contains "$OUT" "AKIAIOSFODNN7EXAMPLE" "原文含未掩码凭证：评论里不出现完整 AWS 访问密钥 ID"
assert_contains "$OUT" "wJal****EKEY" "原文含未掩码凭证：脚本掩码后保留前 4 后 4"
assert_contains "$OUT" "AKIA****MPLE" "原文含未掩码凭证：AWS 访问密钥 ID 同样掩码"
# 票 10 ①：取值末尾带 base64 补位（值里含 `=`）的形态同样要掩掉
assert_not_contains "$OUT" "dGhpcyBpcyBh""IHNlY3JldA==" "原文含未掩码凭证：base64 补位结尾的取值不进评论"
# DRY_RUN 打的是 JSON body，引号在里面是 \"，所以只断言取值本身（不带引号）
assert_contains "$OUT" 'dGhp****dA==' "原文含未掩码凭证：补位形态也保留前 4 后 4"
assert_contains "$OUT" 'api_key = ' "原文含未掩码凭证：键名保留"
# 票 10 ②：只引用了 PEM 起始行时，其后的结论不能被吞掉，且要给出未闭合提示
pem_body="MIIEowIBAAKCAQEA""fakekey0123456"
pem_body2="MIIEvQIBADANBgkqhkiG9w0BAQEF""AASCBKcwggSjAgEAAoIBAQCfake02"
assert_not_contains "$OUT" "$pem_body" "原文含未掩码凭证：说明行之后的整行私钥正文不进评论"
assert_contains "$OUT" "MIIE****3456" "原文含未掩码凭证：整行正文掩成前 4 后 4"
assert_not_contains "$OUT" "$pem_body2" "原文含未掩码凭证：夹在句子里的正文片段不进评论"
assert_contains "$OUT" "正文片段 MIIE****ke02 出现在 app/key.pem" "原文含未掩码凭证：片段掩码后句子其余部分完整"
assert_contains "$OUT" "（下面是私钥内容，节选）" "原文含未掩码凭证：起始行后的说明行放出来（不被吞）"
assert_contains "$OUT" "没有配对的 END 行" "原文含未掩码凭证：未闭合的 PEM 块给出提示"
assert_contains "$OUT" "总体结论：不建议合并。" "原文含未掩码凭证：未闭合 PEM 之后的结论仍在评论里"

# ============ 能力检查：kiro-cli 不支持 --output-format → 拒绝运行，不白烧额度 ============
run_case nostreamflag MOCK_KIRO_NO_STREAM_FLAG=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "不支持 --output-format：非零退出"
assert_contains "$OUT" "不支持 --output-format" "不支持 --output-format：报错点名参数"
assert_contains "$OUT" "评审未完成" "不支持 --output-format：回写失败评论（失败可见）"
assert_eq "$([[ -e "$CASE/args" ]] && echo launched || echo not-launched)" "not-launched" "不支持 --output-format：Kiro 未被启动"

# ============ 失败评论的标题与标记必须与成功/降级评论同形（供后续票原地更新）============
run_case failheader MOCK_KIRO_FAIL=1
assert_contains "$OUT" "# Kiro 代码评审 · ⚠️ 评审未完成" "失败评论：标题与成功评论同一产品名"
assert_not_contains "$OUT" "Kiro 自动代码评审" "失败评论：不再使用旧标题"
assert_eq "$(printf '%s' "$OUT" | grep -c 'kiro-review:[0-9a-f]* run:1')" "1" "失败评论：标记带 run 字段，与成功评论同形"

# ============ R8：按字节截断落在代码围栏内部时，截断提示必须仍然可见 ============
# fix 字段里带一段较长的 ```python 代码块；MAX_COMMENT_BYTES 选在围栏内部切断。
# 不补闭合围栏的话，后面追加的「已截断」提示会被 Markdown 当成代码块内容渲染掉，
# 读者只看到评论突然结束、完全不知道内容缺了。
run_case fencetrunc MAX_COMMENT_BYTES=900 MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/fenced-code.json"
assert_rc "$RC" 0 "围栏内截断：评审仍成功"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "报告超长已截断" "围栏内截断：评论里能看到截断提示"
fences=$(printf '%s\n' "$comment" | grep -c '^```' || true)
assert_eq "$(( fences % 2 ))" "0" "围栏内截断：代码围栏成对（补了闭合围栏，提示不会被吞进代码块）——实际 ${fences} 个"
assert_eq "$([[ "$fences" -ge 2 ]] && echo yes || echo no)" "yes" "围栏内截断：确实截在围栏内部（评论里至少有一对围栏）"
# 「提示不在代码块里」的等价判据：截断提示之前的围栏数必须是偶数
notice_ln=$(printf '%s\n' "$comment" | grep -n '报告超长已截断' | tail -1 | cut -d: -f1)
before=$(printf '%s\n' "$comment" | grep -n '^```' | cut -d: -f1 | awk -v n="$notice_ln" '$1 < n' | wc -l | tr -d ' ')
assert_eq "$(( before % 2 ))" "0" "围栏内截断：截断提示之前的围栏数为偶数，提示不在代码块内（提示在第 ${notice_ln:-?} 行，之前有 ${before} 个围栏）"


# ============ 票 03：汇总评论原地更新 ============
# DRY_RUN 下用 DRY_RUN_FIXTURE_DIR 注入「MR 上现有的全局评论列表」，
# 用 stderr 上的 DRY_RUN <方法> <URL> 判定脚本到底是新建（POST …/comments）还是原地更新（PUT …/comments/<id>）。
CFX="$ROOT/tests/fixtures/comments"
BOT="$TEST_BOT_USERNAME"

# --- 首次评审：列表为空 → 新建（POST），run:1，历次表 1 行 ---
run_case first DRY_RUN_FIXTURE_DIR="$CFX/empty" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "首次评审：成功"
assert_contains "$OUT" "changeRequests/7/comments/list" "首次评审：发汇总前先查询 MR 全局评论"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "首次评审：新建评论（POST …/comments）"
assert_eq "$(req_count "$OUT" PUT)" "0" "首次评审：不调用更新接口"
assert_contains "$OUT" "未找到本评审员的旧汇总评论" "首次评审：日志说明按新建处理"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "<!-- kiro-review:" "首次评审：评论带评审标记"
assert_contains "$comment" "run:1 -->" "首次评审：标记 run:1"
assert_contains "$comment" "<details><summary>历次评审（1）</summary>" "首次评审：历次表只有 1 行"
assert_contains "$comment" "第 1 次评审 · P0 必须修复" "首次评审：页脚第 1 次评审"

# --- 二次评审：找到旧汇总 → 原地更新同一个 biz_id，run:2，历次表两行 ---
run_case second DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "二次评审：成功"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" \
  "二次评审：PUT 到旧评论同一个 biz_id（评论 ID 不变）"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "0" "二次评审：不再新建第二条汇总"
assert_contains "$OUT" "已原地更新汇总评论" "二次评审：日志说明原地更新"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "run:2 -->" "二次评审：标记 run:2（计数 +1）"
assert_contains "$comment" "第 2 次评审 · P0 必须修复" "二次评审：页脚第 2 次评审"
assert_contains "$comment" "<details><summary>历次评审（2）</summary>" "二次评审：历次表两行"
assert_contains "$comment" "| 1 | \`90fcb05\` | 建议修改后合并 | 1/1/1 |" "二次评审：历次表保留上一次那一行"
assert_contains "$comment" "| 2 | \`" "二次评审：历次表追加本次那一行"
assert_eq "$(printf '%s\n' "$comment" | grep -c '<!-- kiro-review:')" "1" "二次评审：更新后的评论里评审标记仍恰好一个"

# --- 机器人用户名未配置（令牌身份接口也不可用）：一律新建，不以评审标记作者作为更新依据 ---
# 评审标记是明文可复制的，拿它的作者当自己就等于让任何 MR 参与者把报告引到他那条评论上。
run_case noidentity DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME=
assert_rc "$RC" 0 "未配置机器人账号：评审仍成功"
assert_eq "$(req_count "$OUT" PUT)" "0" "未配置机器人账号：不做原地更新"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "未配置机器人账号：新建"
assert_contains "$OUT" "不做原地更新" "未配置机器人账号：日志说明"
assert_contains "$OUT" "CODEUP_BOT_USERNAME" "未配置机器人账号：日志点名要配的变量"
assert_contains "$OUT" "${BOT}——若确认那是本评审员的机器人账号" "未配置机器人账号：日志把用户名作为提示给出"

# --- 旧评论被人删除（列表里 state=DELETED）→ 重新新建，run 回到 1 ---
run_case deleted DRY_RUN_FIXTURE_DIR="$CFX/deleted" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "旧评论被删除：成功"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "旧评论被删除：新建"
assert_eq "$(req_count "$OUT" PUT)" "0" "旧评论被删除：不去更新已删除的评论"
assert_contains "$(posted_comment "$OUT")" "run:1 -->" "旧评论被删除：run 从 1 重新开始"

# --- 带评审标记的评论是别人发的 → 不改别人的评论，新建自己的 ---
run_case otherauthor DRY_RUN_FIXTURE_DIR="$CFX/other-author" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "标记评论作者是别人：成功"
assert_eq "$(req_count "$OUT" PUT)" "0" "标记评论作者是别人：不去改别人的评论"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "标记评论作者是别人：新建自己的汇总"

# --- 有人把整条报告原文复制了一份，且用户名未配置 → 谁的评论都不改，新建 ---
run_case forgedmarker DRY_RUN_FIXTURE_DIR="$CFX/ambiguous" CODEUP_BOT_USERNAME=
assert_rc "$RC" 0 "伪造标记 + 未配置用户名：成功"
assert_eq "$(req_count "$OUT" PUT)" "0" "伪造标记 + 未配置用户名：不去改任何人的评论"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "伪造标记 + 未配置用户名：新建"
# 配了用户名之后，同一份列表里那条伪造评论不再有任何影响
run_case forgedmarker2 DRY_RUN_FIXTURE_DIR="$CFX/ambiguous" CODEUP_BOT_USERNAME="$BOT"
assert_eq "$(req_count "$OUT" PUT 'comments/e0000000000000000000000000000001$')" "1" "伪造标记 + 已配置用户名：只更新自己那条"
assert_eq "$(req_count "$OUT" PUT 'comments/e0000000000000000000000000000002$')" "0" "伪造标记 + 已配置用户名：不碰复制者那条"

# --- 更新接口失败（404，例如评论刚被人删掉）→ 4xx 不重试，退回新建并在日志说明 ---
run_case updatefail DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT" \
  DRY_RUN_FAIL_ROUTES="update-comment:404"
assert_rc "$RC" 0 "更新失败退回新建：评审仍成功"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" "更新失败退回新建：只尝试了一次 PUT（4xx 不重试）"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "更新失败退回新建：随后新建"
assert_contains "$OUT" "退回新建" "更新失败退回新建：日志说明"

# --- 更新接口 5xx：按既有重试策略重试 2 次后仍失败 → 退回新建 ---
run_case updateretry DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT" \
  DRY_RUN_FAIL_ROUTES="update-comment:500" CODEUP_RETRY_BACKOFF=0
assert_rc "$RC" 0 "更新 5xx：评审仍成功"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "3" "更新 5xx：共尝试 3 次（重试 2 次）"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "更新 5xx：最终退回新建"

# --- 查询评论列表失败 → 按新建处理，不阻断评审 ---
run_case listfail DRY_RUN_FAIL_ROUTES="list-comments:403" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "查询评论列表失败：评审仍成功"
assert_contains "$OUT" "查询 MR 全局评论失败" "查询评论列表失败：日志说明"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "查询评论列表失败：按新建处理"

# --- 降级评论同样原地更新，历次表记「结构化解析失败」 ---
run_case degradeupdate DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT" MOCK_KIRO_NO_MARKER=1
assert_rc "$RC" 0 "降级 + 原地更新：退出码 0"
assert_contains "$OUT" "结构化解析失败" "降级 + 原地更新：仍是降级评论"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" "降级 + 原地更新：更新同一条评论"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "| 2 | \`" "降级 + 原地更新：历次表追加本次"
assert_contains "$comment" "结构化解析失败 | -/-/- |" "降级 + 原地更新：历次表记结构化解析失败、计数未知"

# --- 失败评论也原地更新：否则一次失败就会在 MR 上留下第二条汇总（违反「每评审员至多一条」）---
run_case failupdate DRY_RUN_FIXTURE_DIR="$CFX/prior-run1" CODEUP_BOT_USERNAME="$BOT" MOCK_KIRO_FAIL=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "失败评论 + 原地更新：非零退出"
assert_contains "$OUT" "评审未完成" "失败评论 + 原地更新：仍是失败评论"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" "失败评论 + 原地更新：更新同一条评论"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "0" "失败评论 + 原地更新：不新建第二条"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "run:2 -->" "失败评论 + 原地更新：标记 run:2"
assert_contains "$comment" "第 2 次评审 · P0 必须修复" "失败评论 + 原地更新：页脚第 2 次评审"
assert_contains "$comment" "| 1 | \`90fcb05\` | 建议修改后合并 | 1/1/1 |" "失败评论 + 原地更新：历次表保留上一次的成功记录"
assert_contains "$comment" "评审未完成 | -/-/- |" "失败评论 + 原地更新：历次表记本次评审未完成"
assert_eq "$(printf '%s\n' "$comment" | grep -c '<!-- kiro-review:')" "1" "失败评论 + 原地更新：评审标记恰好一个"
assert_eq "$(printf '%s\n' "$comment" | grep -c '<!-- kiro-history:')" "1" "失败评论 + 原地更新：历史标记恰好一个"

# --- 截断点落在「历次评审」折叠区内部：截断提示必须仍然在折叠区外面可见 ---
# 不补 </details> 的话，未闭合的标签会把随后追加的截断提示（乃至页脚）一起吞进折叠块。
# 1700 字节这个取值落在渲染结果里 <details> 与 </details> 之间（实测 1599 / 1753）。
run_case detailstrunc MAX_COMMENT_BYTES=1700
assert_rc "$RC" 0 "折叠区内截断：评审仍成功"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "报告超长已截断" "折叠区内截断：评论里能看到截断提示"
opens=$(printf '%s\n' "$comment" | grep -c '<details>' || true)
closes=$(printf '%s\n' "$comment" | grep -c '</details>' || true)
assert_eq "$([[ "$opens" -ge 1 ]] && echo yes || echo no)" "yes" "折叠区内截断：确实截在折叠区内部（评论里有 <details>）"
assert_eq "$opens" "$closes" "折叠区内截断：<details> 与 </details> 成对（补了闭合标签）——实际 ${opens}/${closes}"
notice_ln=$(printf '%s\n' "$comment" | grep -n '报告超长已截断' | tail -1 | cut -d: -f1)
close_ln=$(printf '%s\n' "$comment" | grep -n '</details>' | tail -1 | cut -d: -f1)
assert_eq "$([[ -n "$close_ln" && "$notice_ln" -gt "$close_ln" ]] && echo ok || echo bad)" "ok" \
  "折叠区内截断：截断提示在 </details> 之后（不在折叠块里，提示在第 ${notice_ln:-?} 行，闭合在第 ${close_ln:-?} 行）"

# --- 复审修复：旧评论经 Codeup 网页编辑后是 CRLF，历史仍要能读回来 ---
run_case crlf DRY_RUN_FIXTURE_DIR="$CFX/crlf" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "CRLF 旧评论：成功"
assert_eq "$(req_count "$OUT" PUT 'comments/c11f0000000000000000000000000001$')" "1" "CRLF 旧评论：仍然原地更新"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "run:2 -->" "CRLF 旧评论：run 递增"
assert_contains "$comment" "<details><summary>历次评审（2）</summary>" "CRLF 旧评论：历史读回来了（不是被判为损坏后清空）"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^<!-- kiro-history:')" "1" "CRLF 旧评论：历史标记恰好一行（不是「合法结果 + []」两行）"
# <summary> 只有一行：两个 JSON 值时 `length` 会输出两行，把 <summary> 撑成断行的两截
# （assert_not_contains 不能用带换行的模式——grep -F 会把它当成两个可选模式）
assert_eq "$(printf '%s\n' "$comment" | grep -c '<summary>历次评审')" "1" "CRLF 旧评论：<summary> 只有一行，没被两个 JSON 值撑断"

# --- 复审修复：某条评论的 content 不是字符串，不能让整个 MR 从此每次都新建 ---
run_case badcontent DRY_RUN_FIXTURE_DIR="$CFX/badcontent" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "content 非字符串：成功"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" "content 非字符串：跳过那条，仍然原地更新"

# --- 复审修复：失败评论与成功评论同形（同一个渲染器）---
run_case failshape MOCK_KIRO_FAIL=1
comment=$(posted_comment "$OUT")
assert_contains "$comment" "| Commit | 分支 | 时间 | diff |" "失败评论：与成功评论同形（含元信息表）"
assert_contains "$comment" "<!-- kiro-history:" "失败评论：带历史标记"
assert_contains "$comment" "<details><summary>历次评审（1）</summary>" "失败评论：带历次表"
assert_contains "$comment" "第 1 次评审 · P0 必须修复" "失败评论：页脚与成功评论同形"

# --- 同一机器人留下过两条带标记的汇总（上次退回新建）→ 继续更新 run 最大的那条 ---
run_case tworuns DRY_RUN_FIXTURE_DIR="$CFX/two-runs" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "两条候选：成功"
assert_eq "$(req_count "$OUT" PUT 'comments/f0000000000000000000000000000003$')" "1" "两条候选：更新 run 最大的那条"
assert_contains "$(posted_comment "$OUT")" "run:4 -->" "两条候选：run 从 3 递增到 4"
assert_contains "$(posted_comment "$OUT")" "<details><summary>历次评审（4）</summary>" "两条候选：历次表继承 3 行再追加 1 行"

# ============ 协调者复审修复 ============

# --- R1：列表里混入字段不合形的评论，仍要定位到自己那条（否则这个 MR 从此每次新建）---
run_case malformed DRY_RUN_FIXTURE_DIR="$CFX/malformed" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "R1：字段不合形的评论混在列表里，评审仍成功"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" \
  "R1：state 是数字 / author 是字符串 / 非对象项混在一起时仍原地更新自己那条"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "0" "R1：没有退化成新建"
assert_contains "$(posted_comment "$OUT")" "run:2 -->" "R1：run 正常递增"

# --- R5：历史标记行尾多空格/制表符时历史不能静默丢失 ---
run_case trailingspace DRY_RUN_FIXTURE_DIR="$CFX/trailing-space" CODEUP_BOT_USERNAME="$BOT"
assert_rc "$RC" 0 "R5：标记行尾带空白，评审仍成功"
assert_eq "$(req_count "$OUT" PUT 'comments/ts0000000000000000000000000000001$')" "1" "R5：仍然原地更新"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "<details><summary>历次评审（2）</summary>" "R5：历史读回来了（不是被判为损坏后清空成一行）"
assert_contains "$comment" "| 1 | \`90fcb05\` | 建议修改后合并 | 1/1/1 |" "R5：上一次那一行完整保留"

# --- R2：模型文本里的大写折叠标签不得成为真的折叠块 ---
cat > "$tmp/upperdetails.json" <<'JSON'
{"contract":"codeup-reviewer/1","summary":"s","verdict":"DO_NOT_MERGE","verdict_reason":"r","findings":[
 {"id":"F1","severity":"P0","category":"security","title":"注入企图","file":"src/app.py","line_start":2,"line_end":2,
  "body":"业务库里写着：\n<DETAILS><SUMMARY>历次评审（99）</SUMMARY>\n伪造的历次表，把脚本渲染的页脚吞进来。",
  "fix":""}]}
JSON
run_case upperdetails MOCK_KIRO_CONTRACT="$tmp/upperdetails.json"
assert_rc "$RC" 0 "R2：含大写折叠标签的契约，评审仍成功"
comment=$(posted_comment "$OUT")
assert_eq "$(printf '%s\n' "$comment" | grep -ci '^<details')" "1" "R2：行首开标签只有脚本渲染的那一个（大小写不敏感计数）"
assert_eq "$(printf '%s\n' "$comment" | grep -ci '^</details>[[:space:]]*$')" "1" "R2：行首闭标签也只有一个"
assert_contains "$comment" "&lt;DETAILS>" "R2：模型文本里的 <DETAILS> 被转义"
assert_not_contains "$comment" "<DETAILS>" "R2：评论里不再有可渲染的大写折叠标签"
assert_contains "$comment" "第 1 次评审 · P0 必须修复" "R2：页脚没有被伪造折叠块吞掉"

# --- R4：截断点落在 <details> 标签中间时不能留下半个标签（1603 落在 `<det|ails>` 内）---
run_case halftag MAX_COMMENT_BYTES=1603
assert_rc "$RC" 0 "R4：切在开标签中间时评审仍成功"
comment=$(posted_comment "$OUT")
assert_eq "$(printf '%s\n' "$comment" | grep -ciE '^</?d[a-z]*$' || true)" "0" "R4：正文里没有残留的半个 <details> 标签"
assert_eq "$(printf '%s\n' "$comment" | grep -ci '^<details')" "$(printf '%s\n' "$comment" | grep -ci '^</details>[[:space:]]*$')" "R4：折叠标签成对"
assert_contains "$comment" "报告超长已截断" "R4：截断提示可见"
assert_not_contains "$comment" "$(printf '\357\277\275')" "R4：评论里没有 U+FFFD 替换字符"

# ============================================================================
# 票 04：行内评论管线（INLINE_COMMENT=1）
# ============================================================================
# 全部在 DRY_RUN + fixture 下验证：绝不碰真实 Codeup。
# 判定「到底发了什么请求」仍靠 stderr 上的 `DRY_RUN <方法> <URL>`（req_count）与 body 行。
source "$ROOT/scripts/lib/review-render.sh"   # 只为 review_fingerprint：指纹必须与生产同一份实现

E2E_CONTRACT="$ROOT/tests/fixtures/contract/inline-e2e.json"
# fixture 仓库里 src/app.py 只有第 2 行是新增行（base: import os/def main/pass），
# 所以 inline-e2e.json 里锚在第 2 行的问题可定位，锚在第 99 行与没有 file 的不可定位。
IFX_DIR=""
# 在 $CASE/work 里执行（CASE_TWEAK）：版本列表 fixture 必须带**真实 HEAD sha**，
# 否则每个用例都会打「版本提交与 HEAD 不一致」的警告，那条警告本身就测不出来了。
mk_inline_fixture() {
  local head base n
  mkdir -p "$IFX_DIR"
  head=$(git rev-parse HEAD)
  # MERGE_TARGET 的 commitId 必须就是本地 merge-base：不然每个用例都会打「比较基准不一致」的
  # 警告并往汇总评论里塞一句 notice，那条警告本身就再也测不出来了（R8）
  base=$(git merge-base origin/master HEAD)
  jq -n --arg sha "$head" --arg base "$base" '[
    {patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:$base},
    {patchSetBizId:"src-1", versionNo:1, relatedMergeItemType:"MERGE_SOURCE", commitId:"0000111122223333"},
    {patchSetBizId:"src-2", versionNo:2, relatedMergeItemType:"MERGE_SOURCE", commitId:$sha}
  ]' > "$IFX_DIR/list-patchsets.json"
  for n in 1 2 3 4 5 6; do
    [[ -e "$IFX_DIR/create-comment-inline.${n}.json" ]] \
      || jq -n --arg id "draft-${n}" '{comment_biz_id:$id, comment_type:"INLINE_COMMENT", state:"DRAFT", draft:true}' \
           > "$IFX_DIR/create-comment-inline.${n}.json"
  done
}
# 用法：run_inline_case <用例名> <fixture 目录名> [VAR=值 …]
run_inline_case() {
  local name="$1" fx="$2"; shift 2
  IFX_DIR="$tmp/$fx"
  CASE_TWEAK=mk_inline_fixture run_case "$name" \
    DRY_RUN_FIXTURE_DIR="$IFX_DIR" CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 \
    MOCK_KIRO_CONTRACT="$E2E_CONTRACT" "$@"
}
# inline_bodies（本次创建了哪些行内评论）在 helpers.sh 里，与变异测试共用同一份实现。
# 提交草稿那一次请求的 body
submit_body() { printf '%s\n' "$1" | grep -F 'DRY_RUN body: {"submitDraftCommentIds"' | tail -1 | sed 's/^DRY_RUN body: //'; }

# ---- 成功路径（默认档位 quiet、默认上限 10）----
run_inline_case ok1 ifx-ok1
assert_rc "$RC" 0 "行内开启：退出码 0"
assert_contains "$OUT" "changeRequests/7/diffs/patches" "行内开启：先查 MR 版本列表"
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "1" "行内开启：版本列表只查一次"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "行内开启：quiet 下发出 3 条可定位的 P0/P1"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "1" "行内开启：草稿一次提交（只调一次 review）"
# 三个版本字段必传（P1-03 实测缺一即 400），且 line_number 是新文件侧行号
assert_eq "$(inline_bodies "$OUT" | jq -r 'select(.from_patchset_biz_id == "tgt-1" and .to_patchset_biz_id == "src-2" and .patchset_biz_id == "src-2")' | jq -s length)" "3" \
  "行内开启：每条都带 from=最新合并目标版本、to=patchset_biz_id=最新合并源版本"
assert_eq "$(inline_bodies "$OUT" | jq -r '.line_number' | sort -u | paste -sd, -)" "2" "行内开启：行号落在变更行集合内（新文件侧第 2 行）"
assert_eq "$(inline_bodies "$OUT" | jq -r '.file_path' | sort -u | paste -sd, -)" "src/app.py" "行内开启：文件路径相对仓库根"
assert_eq "$(inline_bodies "$OUT" | jq -r 'select(.draft == true and .resolved == false)' | jq -s length)" "3" "行内开启：都是草稿、都不标记已解决"
# 一次提交带上全部草稿 id，且**不带** reviewOpinion
assert_eq "$(submit_body "$OUT" | jq -r '.submitDraftCommentIds | join(",")')" "draft-1,draft-2,draft-3" "行内开启：提交带上三个不同的草稿 id"
assert_eq "$(submit_body "$OUT" | jq -r 'has("reviewOpinion")')" "false" "行内开启：提交不带 reviewOpinion（不卡合并）"
# 行内评论正文（spec §4.4）
assert_contains "$(inline_bodies "$OUT" | jq -r '.content' | head -20)" "**P0 · 硬编码疑似应用密钥**" "行内正文：级别 · 标题（整行加粗且闭合；Codeup 不渲染三级标题）"
assert_contains "$(inline_bodies "$OUT" | jq -r '.content')" "<!-- kiro-inline:" "行内正文：带去重指纹标记"
assert_contains "$(inline_bodies "$OUT" | jq -r '.content')" "（L2–L3）" "行内正文：多行区间在标题后附 L 起–L 止"
assert_contains "$(inline_bodies "$OUT" | jq -r '.content')" "— Kiro 评审 · 提交 " "行内正文：落款"
# 汇总评论：计数注明已标注到行的条数，其余进折叠区
comment=$(posted_comment "$OUT")
assert_contains "$comment" "其中 3 条已标注在「文件改动」对应行" "汇总：注明已标注到行的条数"
assert_contains "$comment" "<details><summary>折叠区：未展开的问题（3）</summary>" "汇总：折叠区带条数"
assert_contains "$comment" "**P2 建议（1）**" "汇总：折叠区含 P2 小节"
assert_contains "$comment" "**未定位问题（2）**" "汇总：折叠区含未定位小节"
assert_not_contains "$comment" "## 问题清单" "汇总：明细已在行内，不再展开清单（I4 同一问题只出现一次）"
assert_not_contains "$comment" "硬编码疑似应用密钥" "汇总：已发行内的问题不在汇总里重复"
assert_contains "$comment" "<!-- kiro-review:" "汇总：仍带评审标记"
assert_contains "$comment" "<details><summary>历次评审（1）</summary>" "汇总：历次表照旧"
# 版本提交与 HEAD 一致时不该有那条警告
assert_not_contains "$OUT" "与当前 HEAD" "行内开启：版本提交与 HEAD 一致时不打警告"
assert_contains "$OUT" "行内评论：新发 3 条" "行内开启：日志汇报发布结果"

# ---- 档位 critical：只发 P0 ----
run_inline_case critical ifx-critical INLINE_PROFILE=critical
assert_rc "$RC" 0 "critical：退出码 0"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "2" "critical：只发 2 条 P0"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "其中 2 条已标注在「文件改动」对应行" "critical：行内计数为 2"
assert_contains "$comment" "**P1/P2 建议（2）**" "critical：可定位的 P1/P2 进折叠区且标题如实列出级别"

# ---- 档位 balanced：可定位的全发 ----
run_inline_case balanced ifx-balanced INLINE_PROFILE=balanced
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "4" "balanced：4 条可定位问题全发"
assert_contains "$(posted_comment "$OUT")" "**未定位问题（2）**" "balanced：未定位的仍进折叠区"

# ---- 非法档位：回落 quiet 并留痕 ----
run_inline_case badprofile ifx-badprofile INLINE_PROFILE=严格模式
assert_rc "$RC" 0 "非法档位：评审仍成功"
assert_contains "$OUT" "不是 quiet/balanced/critical" "非法档位：日志告警"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "非法档位：按 quiet 发 3 条"
# 配错档位这件事必须在 MR 上看得见：阿里云侧开发者看不到流水线日志（I10）
assert_contains "$(posted_comment "$OUT")" "INLINE_PROFILE=严格模式" "非法档位：汇总评论里说明已回落"
assert_contains "$(posted_comment "$OUT")" "已按默认 quiet 处理" "非法档位：汇总评论点明回落到哪个档位"

# ---- 上限截取 ----
run_inline_case max1 ifx-max1 MAX_INLINE_COMMENTS=1
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "1" "上限 1：只发 1 条"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "其中 1 条已标注在「文件改动」对应行" "上限 1：行内计数为 1"
assert_contains "$comment" "**超出行内上限的 P0/P1（2）**" "上限 1：超限的 P0/P1 进折叠区"
run_inline_case badmax ifx-badmax MAX_INLINE_COMMENTS=很多
assert_contains "$OUT" "不是非负整数" "非法上限：日志告警"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "非法上限：按默认 10 处理"

# ---- 去重：MR 上同一处已有本评审员的行内评论 → 跳过并计数，不重复发 ----
# 判定是「同文件、行区间重叠或相距 ≤ 2 行、且已有评论级别不低于新问题」（实测澄清 2026-09-03），标题不参与。
# fixture 里三条可定位问题都锚在 src/app.py 第 2 行：G1/G2 是 P0、G3 是 P1；旧评论是一条 P1 →
# 两条 P0 不被压（否则重跑时新出现的 P0 会从 MR 上消失），P1 那条被压。
IFX_DIR="$tmp/ifx-dedup"; mkdir -p "$IFX_DIR"
fp_dup=$(review_fingerprint "src/app.py" 2 "硬编码疑似应用密钥")
jq -n --arg fp "$fp_dup" --arg bot "$BOT" '[
  {comment_biz_id:"old-1", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false,
   filePath:"src/app.py", line_number:2, author:{username:$bot},
   content:("### P1 · 上一次的措辞完全不同\n<!-- kiro-inline:" + $fp + " -->\n\n上一次发的。\n")}
]' > "$IFX_DIR/list-comments-inline.json"
CASE_TWEAK=mk_inline_fixture run_case dedup DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "去重：退出码 0"
assert_contains "$OUT" "changeRequests/7/comments/list" "去重：发布前先查现有行内评论"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "2" "去重：同一处已有一条 P1 → 两条 P0 照发、P1 那条被压（3 → 2）"
assert_contains "$(inline_bodies "$OUT" | jq -r '.content')" "硬编码疑似应用密钥" "去重：新出现的 P0 不被旧 P1 压掉"
assert_not_contains "$(inline_bodies "$OUT" | jq -r '.content')" "缺少启动时的配置校验" "去重：被压的正是同级别（P1）那条，标题不同也算同一问题"
assert_contains "$OUT" "已存在跳过 1 条" "去重：日志计数"
assert_contains "$OUT" "去重：问题 #2（P1 src/app.py L2）与已有行内评论 old-1 同文件且行区间重叠/相邻、级别不低于它，视为同一问题，跳过" "去重：日志指得出是和哪条算同一问题"
assert_contains "$OUT" "判定 = 同文件且行区间重叠或相距 ≤ 2 行、已有评论级别不低于新问题" "去重：日志说明判定口径"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "其中 3 条已标注在「文件改动」对应行" "去重：跳过的仍算「已标注在对应行」（那一处确实有评论）"
assert_not_contains "$comment" "缺少启动时的配置校验" "去重：跳过的不该又出现在折叠区（否则同一问题出现两次）"

# 同一处旧评论是 P0 → 三条全压（级别门槛只挡「旧的比新的低」）
IFX_DIR="$tmp/ifx-dedup-p0"; mkdir -p "$IFX_DIR"
jq 'map(.content |= sub("### P1 · "; "### P0 · "))' "$tmp/ifx-dedup/list-comments-inline.json" > "$IFX_DIR/list-comments-inline.json"
CASE_TWEAK=mk_inline_fixture run_case dedupp0 DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "去重：同一处已有一条 P0 → 三条（P0/P0/P1）全部跳过"
assert_contains "$OUT" "已存在跳过 3 条" "去重：日志计数 3"
assert_contains "$(posted_comment "$OUT")" "其中 3 条已标注在「文件改动」对应行" "去重：3 条问题并到同一条已有评论上，计数按问题算"

# ---- 真实验收暴露的缺陷（2026-09-03，demo-app MR #2 重跑 4 → 9）----
# fixture = 真实回读的第一次运行的 4 条行内评论（旧格式标记）；契约 = 第二次运行的形态：
# 标题全变、行号漂移 1 行（20→21、37→36）、一条问题拆成两条（L14 与 L22）。期望：0 条新建、跳过 5 条。
REAL_LIST="$ROOT/tests/fixtures/inline/real-rerun/list-comments-inline.json"
REAL_CONTRACT="$ROOT/tests/fixtures/contract/inline-rerun-real.json"
# 业务库里得有 app/download.py 且这些行都是本次新增的（新文件 → 全部行可定位）
mk_real_repo() {
  mkdir -p app
  for i in $(seq 1 50); do echo "line_${i} = ${i}"; done > app/download.py
  git add app/download.py && git commit -qm "add download endpoint" 
  mk_inline_fixture
  cp "$REAL_LIST" "$IFX_DIR/list-comments-inline.json"
}
IFX_DIR="$tmp/ifx-real"; mkdir -p "$IFX_DIR"
CASE_TWEAK=mk_real_repo run_case realrerun DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$REAL_CONTRACT"
assert_rc "$RC" 0 "真实重跑：退出码 0"
assert_contains "$OUT" "MR 上已有 4 条本评审员的未过期行内评论" "真实重跑：4 条旧格式评论都被认出（区间从 line_number + 标题区间还原）"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "真实重跑：0 条新建（标题全变、行号漂移、一条拆两条都算同一问题）"
assert_contains "$OUT" "已存在跳过 5 条" "真实重跑：跳过 5 条"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "0" "真实重跑：没有新草稿就不调提交接口"
assert_contains "$OUT" "P0 app/download.py L36）与已有行内评论 115adf34175b4c0eaf33b39c3a07f631 同文件" "真实重跑：36 与 37–38 相邻 → 命中那条 pickle 评论"
assert_contains "$OUT" "app/download.py L21–L23）与已有行内评论 39410c6f45434235bf87f60304d9d682,30ed01ac16ae406a898c6dd8791073c3 同文件" \
  "真实重跑：21–23 与 20–23 重叠（也与 14–22 重叠）→ 两条命中的 id 都列出"
assert_contains "$OUT" "app/download.py L22）与已有行内评论 39410c6f45434235bf87f60304d9d682,30ed01ac16ae406a898c6dd8791073c3 同文件" \
  "真实重跑：拆出来的 L22 落在 14–22 内（也与 20–23 重叠）"
assert_contains "$OUT" "app/download.py L14）与已有行内评论 39410c6f45434235bf87f60304d9d682 同文件" "真实重跑：拆出来的 L14 只命中 14–22 那条"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "P0 5 · P1 0 · P2 0 —— 其中 5 条已标注在「文件改动」对应行" "真实重跑：跳过的 5 条都算「已标注」（MR 上确实存在）"
assert_not_contains "$comment" "签名密钥被硬编码" "真实重跑：跳过的问题不进折叠区"
assert_not_contains "$comment" "折叠区" "真实重跑：没有任何未展开的问题"

# 负向：相距 ≥ 3 行的新问题仍会新建（容差不是「同文件就算重复」）
jq '.findings += [
  {id:"F6", severity:"P0", category:"security", title:"41 行与 37–38 相距 3 行", file:"app/download.py",
   line_start:41, line_end:41, body:"容差边界之外。", fix:""},
  {id:"F7", severity:"P1", category:"logic", title:"45 行离所有旧评论都很远", file:"app/download.py",
   line_start:45, line_end:46, body:"新问题。", fix:""}]' "$REAL_CONTRACT" > "$tmp/real-plus.json"
IFX_DIR="$tmp/ifx-real-far"; mkdir -p "$IFX_DIR"
CASE_TWEAK=mk_real_repo run_case realfar DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$tmp/real-plus.json"
assert_rc "$RC" 0 "真实重跑 + 新问题：退出码 0"
assert_eq "$(inline_bodies "$OUT" | jq -r '.line_number' | sort -n | paste -sd, -)" "41,45" "真实重跑 + 新问题：只有相距 ≥ 3 行的两条新建"
assert_contains "$OUT" "已存在跳过 5 条" "真实重跑 + 新问题：原来 5 条仍跳过"
assert_contains "$OUT" "新发 2 条" "真实重跑 + 新问题：新发 2 条"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "1" "真实重跑 + 新问题：新草稿一次提交"
assert_contains "$(inline_bodies "$OUT" | jq -r '.content')" " L45-46 sev=P1 -->" "真实重跑 + 新问题：新发的评论带新格式标记（区间 + 级别）"
assert_contains "$(posted_comment "$OUT")" "其中 7 条已标注在「文件改动」对应行" "真实重跑 + 新问题：已标注 = 新发 2 + 跳过 5"

# 第三次运行：MR 上是本次修复之后发出的新格式标记 → 区间直接从标记里读，line_number 不参与
mk_real_repo_newmarker() {
  mk_real_repo
  jq --arg bot "$BOT" '[
    {comment_biz_id:"nm-1", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false, out_dated:false,
     filePath:"app/download.py", line_number:null, author:{username:$bot},
     content:"### P0 · 密钥被硬编码并写入日志（L14–L22）\n<!-- kiro-inline:554053a282e7d7519bced6cc3131edbdc3134c57 L14-22 sev=P0 -->\n\n说明。\n"},
    {comment_biz_id:"nm-2", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false, out_dated:false,
     filePath:"app/download.py", line_number:20, author:{username:$bot},
     content:"### P0 · 下载接口存在目录穿越（L20–L23）\n<!-- kiro-inline:f0951a07e682f7957218dbe407fa46d154e76750 L20-23 sev=P0 -->\n"},
    {comment_biz_id:"nm-3", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false, out_dated:false,
     filePath:"app/download.py", line_number:29, author:{username:$bot},
     content:"### P0 · 远程抓取接口可被用于 SSRF（L29–L30）\n<!-- kiro-inline:169e03b5565fc921ea6f9dfff3690711b7abc2ab L29-30 sev=P0 -->\n"},
    {comment_biz_id:"nm-4", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false, out_dated:false,
     filePath:"app/download.py", line_number:37, author:{username:$bot},
     content:"### P0 · 请求体反序列化可执行任意代码（L37–L38）\n<!-- kiro-inline:ad63f7d922057542ad5363d2a0e61e307e95ea1d L37-38 sev=P0 -->\n"}
  ]' -n > "$IFX_DIR/list-comments-inline.json"
}
IFX_DIR="$tmp/ifx-real-newmarker"; mkdir -p "$IFX_DIR"
CASE_TWEAK=mk_real_repo_newmarker run_case realnewmarker DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$REAL_CONTRACT"
assert_rc "$RC" 0 "新格式标记：退出码 0"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "新格式标记：区间从标记里读（nm-1 连 line_number 都没有），5 条全部跳过"
assert_contains "$OUT" "已存在跳过 5 条" "新格式标记：跳过 5 条"
assert_contains "$OUT" "app/download.py L14）与已有行内评论 nm-1 同文件" "新格式标记：line_number 为 null 的那条靠标记区间命中"

# out_dated 的旧评论在区间去重下同样不算：推了新提交后同一处会按当前版本重发
mk_real_repo_outdated() {
  mk_real_repo
  jq 'map(.out_dated = true)' "$REAL_LIST" > "$IFX_DIR/list-comments-inline.json"
}
IFX_DIR="$tmp/ifx-real-outdated"; mkdir -p "$IFX_DIR"
CASE_TWEAK=mk_real_repo_outdated run_case realoutdated DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$REAL_CONTRACT"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "5" "真实重跑 + 全部过期：旧评论绑在被取代的版本上，5 条全部按当前版本重发"
assert_contains "$OUT" "MR 上已有 0 条本评审员的未过期行内评论" "真实重跑 + 全部过期：候选集为空"

# ---- 重跑不重复：把上一次发出去的三条都当作 MR 上已有 → 一条都不再发 ----
IFX_DIR="$tmp/ifx-rerun"; mkdir -p "$IFX_DIR"
fp1=$(review_fingerprint "src/app.py" 2 "硬编码疑似应用密钥")
fp2=$(review_fingerprint "src/app.py" 2 "密钥可能已泄漏到提交历史")
fp3=$(review_fingerprint "src/app.py" 2 "缺少启动时的配置校验")
jq -n --arg a "$fp1" --arg b "$fp2" --arg c "$fp3" --arg bot "$BOT" '
  [$a, $b, $c] | to_entries | map({comment_biz_id:("old-" + (.key|tostring)),
    comment_type:"INLINE_COMMENT", state:"OPENED", draft:false,
    filePath:"src/app.py", line_number:2, author:{username:$bot},
    content:("### P0 · 上一次\n<!-- kiro-inline:" + .value + " -->\n")})' > "$IFX_DIR/list-comments-inline.json"
CASE_TWEAK=mk_inline_fixture run_case rerun DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "重跑：退出码 0"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "重跑：三条都已存在 → 一条都不重发（A3 重跑不重复）"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "0" "重跑：没有新草稿就不调提交接口"
assert_contains "$(posted_comment "$OUT")" "其中 3 条已标注在「文件改动」对应行" "重跑：计数仍为 3（都在那些行上）"

# ---- 别人发的同指纹评论不算「我发过了」 ----
IFX_DIR="$tmp/ifx-otherbot"; mkdir -p "$IFX_DIR"
jq -n --arg fp "$fp_dup" '[
  {comment_biz_id:"h-1", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false,
   filePath:"src/app.py", line_number:2, author:{username:"aliyun:human_dev"},
   content:("### P0 · 我把机器人的评论复制了一份\n<!-- kiro-inline:" + $fp + " -->\n")}
]' > "$IFX_DIR/list-comments-inline.json"
CASE_TWEAK=mk_inline_fixture run_case otherbotdup DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" \
  "去重：带指纹的评论是别人发的 → 不算已发出（否则任何人都能压掉一条 P0）"

# ---- 未配置机器人账号：去重退化为只按标记，必须留痕提示 ----
IFX_DIR="$tmp/ifx-noid"; mkdir -p "$IFX_DIR"
CASE_TWEAK=mk_inline_fixture run_case inlinenoid DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME= INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "未配置机器人账号：行内评论仍照发"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "未配置机器人账号：3 条照发"
assert_contains "$OUT" "去重无法按作者过滤" "未配置机器人账号：日志说明去重的局限"
assert_contains "$OUT" "CODEUP_BOT_USERNAME" "未配置机器人账号：日志点名要配的变量"

# ---- 草稿一次提交失败 → 先删已建草稿，再逐条非草稿发布 ----
run_inline_case submitfail ifx-submitfail DRY_RUN_FAIL_ROUTES="submit-review:400"
assert_rc "$RC" 0 "提交失败：评审仍成功（评论已经用别的方式发出去了）"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "1" "提交失败：4xx 不重试，只调一次"
assert_contains "$OUT" "退回逐条非草稿发布" "提交失败：日志说明回退"
assert_eq "$(req_count "$OUT" DELETE 'comments/draft-1$')" "1" "提交失败：先删掉已建的草稿（否则同一条问题既留草稿又发正式评论）"
assert_eq "$(req_count "$OUT" DELETE)" "3" "提交失败：三条草稿都删"
assert_eq "$(inline_bodies "$OUT" | jq -r 'select(.draft == false)' | jq -s length)" "3" "提交失败：随后逐条以非草稿发布"
assert_contains "$(posted_comment "$OUT")" "其中 3 条已标注在「文件改动」对应行" "提交失败：回退成功后计数仍为 3"

# ---- 逐条回退也失败 → 那些问题必须在折叠区看得见（不能凭空消失）----
run_inline_case allfail ifx-allfail DRY_RUN_FAIL_ROUTES="submit-review:400,create-comment-inline:400"
assert_rc "$RC" 0 "全部发布失败：评审仍以 0 退出（评审本身产出了）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "其中 0 条已标注在「文件改动」对应行" "全部发布失败：行内计数为 0"
assert_contains "$comment" "**行内发布失败（3）**" "全部发布失败：折叠区单独一节列出"
assert_contains "$comment" "硬编码疑似应用密钥" "全部发布失败：问题本身仍然可见"
assert_contains "$comment" "<details><summary>折叠区：未展开的问题（6）</summary>" "全部发布失败：折叠区 3 + 3"
# R4：一条行内评论都没发出去时，说明与修复建议在 MR 上再没有别的落点（I10），必须完整渲染
assert_contains "$comment" '**1. `src/app.py:2` — 硬编码疑似应用密钥**' "R4：发布失败小节带编号与定位串"
assert_contains "$comment" "硬编码模式会让真实密钥被提交、传播或误用于其他环境。" "R4：发布失败的问题说明完整可见（不只是首句）"
assert_contains "$comment" "从环境变量或密钥管理服务读取，启动时校验非空。" "R4：发布失败的问题修复建议完整可见"
assert_contains "$comment" "立即轮换该凭证，并考虑清理历史。" "R4：第二条失败问题的修复建议也在"
# 创建被 400 拒掉时不重试（创建不幂等）：三条问题各自只发一次请求
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "R5：三条各只尝试创建一次（400 不重试）"

# ---- 版本列表查不到 → 回落成「一条含完整问题清单的汇总」，并在评论里说明原因 ----
IFX_DIR="$tmp/ifx-nops"; mkdir -p "$IFX_DIR"
CASE_TWEAK=mk_inline_fixture run_case nopatchsets DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT" \
  DRY_RUN_FAIL_ROUTES="list-patchsets:403"
assert_rc "$RC" 0 "版本列表失败：评审仍成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "版本列表失败：一条行内评论都不发（不拿猜的版本去挂行）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "行内评论未发出" "版本列表失败：汇总里说明原因（I10 失败可见）"
assert_contains "$comment" "## 问题清单" "版本列表失败：回落成完整展开的问题清单"
assert_contains "$comment" "硬编码疑似应用密钥" "版本列表失败：问题明细仍在汇总里"
assert_not_contains "$comment" "已标注在" "版本列表失败：不谎报行内计数"

# ---- 版本列表里选不出版本对（只有合并源版本）----
IFX_DIR="$tmp/ifx-nopair"; mkdir -p "$IFX_DIR"
mk_nopair() {
  mkdir -p "$IFX_DIR"
  jq -n '[{patchSetBizId:"src-1", versionNo:1, relatedMergeItemType:"MERGE_SOURCE", commitId:"x"}]' \
    > "$IFX_DIR/list-patchsets.json"
}
CASE_TWEAK=mk_nopair run_case nopair DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "选不出版本对：评审仍成功"
assert_contains "$OUT" "MERGE_TARGET" "选不出版本对：日志点名缺哪一侧"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "选不出版本对：不发行内评论"
assert_contains "$(posted_comment "$OUT")" "## 问题清单" "选不出版本对：回落成完整清单"

# ---- 最新合并源版本的提交与 HEAD 不一致 → 记 warning，但仍以 API 版本为准 ----
IFX_DIR="$tmp/ifx-shamismatch"; mkdir -p "$IFX_DIR"
mk_mismatch() {
  mkdir -p "$IFX_DIR"
  jq -n '[{patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:"aaaa1111"},
          {patchSetBizId:"src-9", versionNo:9, relatedMergeItemType:"MERGE_SOURCE", commitId:"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]' \
    > "$IFX_DIR/list-patchsets.json"
  jq -n '{comment_biz_id:"draft-1"}' > "$IFX_DIR/create-comment-inline.json"
}
CASE_TWEAK=mk_mismatch run_case shamismatch DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "版本提交与 HEAD 不一致：评审仍成功"
assert_contains "$OUT" "与当前 HEAD" "版本提交与 HEAD 不一致：记 warning"
assert_eq "$(inline_bodies "$OUT" | jq -r '.to_patchset_biz_id' | sort -u | paste -sd, -)" "src-9" \
  "版本提交与 HEAD 不一致：仍以 API 给的版本为准（Codeup 侧真值）"
# 票 05 复审修复：这条不确定性也必须进汇总评论——阿里云侧开发者看不到流水线日志（I10）
comment=$(posted_comment "$OUT")
assert_contains "$comment" "不是 Codeup 侧最新的合并源版本" "版本提交与 HEAD 不一致：汇总评论里说明（I10）"
assert_contains "$comment" "行号可能有偏移" "版本提交与 HEAD 不一致：说清后果"
assert_contains "$comment" "已标注在「文件改动」对应行" "版本提交与 HEAD 不一致：不影响行内计数"

# ---- 查现有行内评论失败 → 跳过去重但照常发布，并留痕 ----
run_inline_case nodedup ifx-nodedup DRY_RUN_FAIL_ROUTES="list-comments-inline:500" CODEUP_RETRY_BACKOFF=0
assert_rc "$RC" 0 "查现有行内评论失败：评审仍成功"
assert_contains "$OUT" "本次跳过去重" "查现有行内评论失败：日志说明"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "查现有行内评论失败：仍照常发布"

# ---- 降级路径（结构化解析失败）下不发行内评论：没有可信的分级问题可发 ----
run_inline_case inlinedegrade ifx-inlinedegrade MOCK_KIRO_NO_MARKER=1
assert_rc "$RC" 0 "降级 + 行内开启：退出码 0"
assert_contains "$OUT" "结构化解析失败" "降级 + 行内开启：仍是降级评论"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "降级 + 行内开启：不发行内评论（没有可信的结构化问题）"
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "0" "降级 + 行内开启：连版本列表都不用查"

# ---- 无问题：不发行内评论，汇总仍完整 ----
printf '{"contract":"codeup-reviewer/1","summary":"没有发现问题。","verdict":"MERGE","verdict_reason":"改动很小。","findings":[]}\n' > "$tmp/empty-contract.json"
run_inline_case inlineempty ifx-inlineempty MOCK_KIRO_CONTRACT="$tmp/empty-contract.json"
assert_rc "$RC" 0 "无问题 + 行内开启：退出码 0"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "无问题 + 行内开启：不发行内评论"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "0" "无问题 + 行内开启：不调提交接口"
# 没有可发的行内评论时连版本列表与现有评论列表都不该查：白跑两个接口，还可能在一条
# 「未发现明显问题」的汇总上挂一句「下面是完整问题清单」
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "0" "无问题 + 行内开启：不查版本列表"
assert_eq "$(printf '%s\n' "$OUT" | grep -cF 'DRY_RUN body: {"comment_type":"INLINE_COMMENT"}')" "0" "无问题 + 行内开启：不查现有行内评论"
assert_contains "$OUT" "本次没有可发的行内评论" "无问题 + 行内开启：日志说明为什么跳过"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "P0 0 · P1 0 · P2 0 —— 其中 0 条已标注在「文件改动」对应行" "无问题 + 行内开启：统计行完整"
assert_contains "$comment" "未发现明显问题。" "无问题 + 行内开启：明确说明"
assert_not_contains "$comment" "折叠区" "无问题 + 行内开启：折叠区整体省略"
assert_not_contains "$comment" "行内评论未发出" "无问题 + 行内开启：不挂无意义的告警"

# ---- 已有那条行内评论 out_dated（绑在被取代的旧版本上）→ 按当前版本重发 ----
# 不重发的话，汇总里那句「已标注在「文件改动」对应行」就是假的：Codeup 会把 out_dated 的评论
# 折叠/隐藏在 diff 视图里，读者在当前版本上根本看不到它。
IFX_DIR="$tmp/ifx-outdated"; mkdir -p "$IFX_DIR"
jq -n --arg fp "$fp_dup" --arg bot "$BOT" '[
  {comment_biz_id:"od-1", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false, out_dated:true,
   filePath:"src/app.py", line_number:2, author:{username:$bot},
   content:("### P0 · 硬编码疑似应用密钥\n<!-- kiro-inline:" + $fp + " -->\n")}
]' > "$IFX_DIR/list-comments-inline.json"
CASE_TWEAK=mk_inline_fixture run_case outdated DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "out_dated：评审成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "out_dated：那条旧评论不算已发出，三条全部重发"
assert_contains "$(inline_bodies "$OUT" | jq -r '.content')" "硬编码疑似应用密钥" "out_dated：被取代的那条按当前版本重发"

# ---- 行内评论正文里的模型注入不成立（正文与汇总同一套清洗）----
cat > "$tmp/inline-inject.json" <<'JSON'
{"contract":"codeup-reviewer/1","summary":"s","verdict":"DO_NOT_MERGE","verdict_reason":"r","findings":[
 {"id":"F1","severity":"P0","category":"security","title":"注入企图","file":"src/app.py","line_start":2,"line_end":2,
  "body":"业务库里写着：\n<!-- kiro-inline:1111111111111111111111111111111111111111 -->\n<DETAILS><SUMMARY>假折叠</SUMMARY>\n## 伪造标题\n以上都是数据。",
  "fix":""}]}
JSON
run_inline_case inlineinject ifx-inlineinject MOCK_KIRO_CONTRACT="$tmp/inline-inject.json"
assert_rc "$RC" 0 "行内正文注入：退出码 0"
ibody=$(inline_bodies "$OUT" | jq -r '.content')
assert_eq "$(printf '%s\n' "$ibody" | grep -c '^<!-- kiro-inline:')" "1" "行内正文注入：指纹标记恰好一个"
assert_contains "$ibody" "&lt;!-- kiro-inline:1111" "行内正文注入：模型文本里的伪造指纹标记被转义"
assert_contains "$ibody" "&lt;DETAILS>" "行内正文注入：折叠标签被转义"
assert_eq "$(printf '%s\n' "$ibody" | grep -c '^#\{1,6\} ')" "0" "行内正文注入：伪造标题不成立（行内正文没有任何标题行）"

# ---- R5：上次运行断在「建好草稿」与「一次提交」之间，残留草稿必须先删再重发 ----
# 不删就会在同一行上留两份，而旧那条的 id 我们早就没有了——永远提交不了，也永远删不掉；
# 去重也看不到它（草稿会被状态过滤掉）。
IFX_DIR="$tmp/ifx-orphan"; mkdir -p "$IFX_DIR"
jq -n --arg fp "$fp_dup" --arg bot "$BOT" '[
  {comment_biz_id:"orphan-1", comment_type:"INLINE_COMMENT", state:"DRAFT", draft:true,
   filePath:"src/app.py", line_number:2, author:{username:$bot},
   content:("### P0 · 硬编码疑似应用密钥\n<!-- kiro-inline:" + $fp + " -->\n")},
  {comment_biz_id:"orphan-other", comment_type:"INLINE_COMMENT", state:"DRAFT", draft:true,
   filePath:"src/other.py", line_number:9, author:{username:$bot},
   content:"### P2 · 与本次无关的残留草稿\n<!-- kiro-inline:9999999999999999999999999999999999999999 -->\n"}
]' > "$IFX_DIR/list-comments-inline.json"
CASE_TWEAK=mk_inline_fixture run_case orphan DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "R5 残留草稿：评审成功"
assert_eq "$(req_count "$OUT" DELETE 'comments/orphan-1$')" "1" "R5 残留草稿：指纹对得上的那条先被删掉"
assert_eq "$(req_count "$OUT" DELETE 'comments/orphan-other$')" "0" "R5 残留草稿：与本次无关的草稿不动（同一 MR 上可能有另一次运行在进行中）"
assert_contains "$OUT" "残留草稿" "R5 残留草稿：日志说明清理动作"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "R5 残留草稿：草稿不算已发出，三条照常重发"
assert_contains "$(inline_bodies "$OUT" | jq -r '.content')" "硬编码疑似应用密钥" "R5 残留草稿：那条问题确实被重发"

# ---- R6：一次提交返回 2xx，但回读发现某条仍是草稿 → 删除并记为发布失败 ----
# 服务端可以受理请求却拒掉其中一个 id（版本过期、超上限）。不回读的话那条只有机器人自己看得见，
# 汇总却报「已标注在对应行」，下次重跑还会再发一条。
IFX_DIR="$tmp/ifx-stilldraft"; mkdir -p "$IFX_DIR"
jq -n '[]' > "$IFX_DIR/list-comments-inline.1.json"
jq -n --arg bot "$BOT" '[
  {comment_biz_id:"draft-1", comment_type:"INLINE_COMMENT", state:"DRAFT", draft:true,
   filePath:"src/app.py", line_number:2, author:{username:$bot},
   content:"### P0 · 被服务端拒掉的那条\n<!-- kiro-inline:1111111111111111111111111111111111111111 -->\n"},
  {comment_biz_id:"draft-2", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false,
   filePath:"src/app.py", line_number:2, author:{username:$bot},
   content:"### P0 · 正常转公开的那条\n<!-- kiro-inline:2222222222222222222222222222222222222222 -->\n"}
]' > "$IFX_DIR/list-comments-inline.2.json"
CASE_TWEAK=mk_inline_fixture run_case stilldraft DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "R6 回读：评审成功"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "1" "R6 回读：提交本身成功（2xx）"
assert_eq "$(printf '%s\n' "$OUT" | grep -cF 'DRY_RUN body: {"comment_type":"INLINE_COMMENT"}')" "2" "R6 回读：提交后又查了一次行内评论列表"
assert_contains "$OUT" "仍是草稿" "R6 回读：日志点明那条没转成公开评论"
assert_eq "$(req_count "$OUT" DELETE 'comments/draft-1$')" "1" "R6 回读：仍为草稿的那条被删除"
assert_eq "$(req_count "$OUT" DELETE 'comments/draft-2$')" "0" "R6 回读：已转公开的那条不动"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "其中 2 条已标注在「文件改动」对应行" "R6 回读：行内计数只算真的转成公开评论的（3 → 2）"
assert_contains "$comment" "**行内发布失败（1）**" "R6 回读：被拒的那条进折叠区"
assert_contains "$comment" "硬编码疑似应用密钥" "R6 回读：被拒那条的内容在折叠区完整可见"

# ---- R6b：提交后回读失败 → 全部按发布失败处理（fail-closed）----
run_inline_case readbackfail ifx-readbackfail DRY_RUN_FAIL_ROUTES="list-comments-inline:403"
assert_rc "$RC" 0 "R6b 回读失败：评审仍成功"
assert_contains "$OUT" "本次跳过去重" "R6b 回读失败：发布前那次查询也失败了（同一个 route）"
assert_contains "$OUT" "全部按发布失败处理" "R6b 回读失败：日志说明 fail-closed"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "其中 0 条已标注在「文件改动」对应行" "R6b 回读失败：不谎报已标注条数"
assert_contains "$comment" "**行内发布失败（3）**" "R6b 回读失败：三条都在折叠区完整列出（宁可重复，绝不藏问题）"

# ---- R8：Codeup 侧的比较基准与本地 merge-base 不一致 → 警告 + 汇总里说明 ----
IFX_DIR="$tmp/ifx-basemismatch"; mkdir -p "$IFX_DIR"
mk_basemismatch() {
  local head
  mkdir -p "$IFX_DIR"
  head=$(git rev-parse HEAD)
  # MERGE_TARGET 的 commitId 是目标分支顶端（不是 merge-base）——目标分支在 MR 分出后前进过
  jq -n --arg sha "$head" '[
    {patchSetBizId:"tgt-9", versionNo:9, relatedMergeItemType:"MERGE_TARGET", commitId:"feedfacefeedfacefeedfacefeedfacefeedface"},
    {patchSetBizId:"src-2", versionNo:2, relatedMergeItemType:"MERGE_SOURCE", commitId:$sha}
  ]' > "$IFX_DIR/list-patchsets.json"
  jq -n '{comment_biz_id:"draft-1"}' > "$IFX_DIR/create-comment-inline.json"
}
CASE_TWEAK=mk_basemismatch run_case basemismatch DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "R8 基准不一致：评审仍成功"
assert_contains "$OUT" "不等于本地 merge-base" "R8 基准不一致：日志告警"
assert_contains "$OUT" "P1-14" "R8 基准不一致：日志指向待探测项"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "R8 基准不一致：仍以 API 给的版本发出（不猜语义）"
assert_eq "$(inline_bodies "$OUT" | jq -r '.from_patchset_biz_id' | sort -u | paste -sd, -)" "tgt-9" "R8 基准不一致：from 仍用 API 的版本"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "行内评论的行号可能有偏移" "R8 基准不一致：汇总评论里说明不确定性（I10）"
assert_contains "$comment" "其中 3 条已标注在「文件改动」对应行" "R8 基准不一致：不影响行内计数"

# ---- 行内评论不影响汇总评论的原地更新（票 03 的不变量在开关打开后仍成立）----
IFX_DIR="$tmp/ifx-update"; mkdir -p "$IFX_DIR"
cp "$CFX/prior-run1/list-comments.json" "$IFX_DIR/list-comments.json"
CASE_TWEAK=mk_inline_fixture run_case inlineupdate DRY_RUN_FIXTURE_DIR="$IFX_DIR" \
  CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 MOCK_KIRO_CONTRACT="$E2E_CONTRACT"
assert_rc "$RC" 0 "行内 + 原地更新：退出码 0"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" "行内 + 原地更新：汇总仍原地更新同一条"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "3" "行内 + 原地更新：POST …/comments 只有三条行内评论，没有新建第二条汇总"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "run:2 -->" "行内 + 原地更新：run 递增"
assert_contains "$comment" "<details><summary>历次评审（2）</summary>" "行内 + 原地更新：历次表两行"

# ============================================================================
# 票 05 复审修复
# ============================================================================
# ---- KIRO_TIMEOUT / DIFF_SIZE_LIMIT 必须是正整数：非法取值是「静默走偏」，必须硬失败 ----
# KIRO_TIMEOUT=15m → timeout 会以 rc 125 退出，MR 上只剩「Kiro 评审失败（退出码 125）」
run_case badtimeout KIRO_TIMEOUT=15m
assert_rc "$RC" 1 "KIRO_TIMEOUT 非整数：拒绝运行"
assert_contains "$OUT" "KIRO_TIMEOUT=15m 不是纯数字" "KIRO_TIMEOUT 非整数：报错点名变量与取值"
assert_contains "$OUT" "不支持 15m / 300KB 这类带单位的写法" "KIRO_TIMEOUT 非整数：告诉运维正确写法"
assert_eq "$(call_count "$CASE/calls" chat)" "0" "KIRO_TIMEOUT 非整数：没白跑 Kiro（不烧额度）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "⚠️ 评审未完成" "KIRO_TIMEOUT 非整数：MR 上看得见（I10）"
assert_contains "$comment" "KIRO_TIMEOUT=15m" "KIRO_TIMEOUT 非整数：失败评论写明原因"
# DIFF_SIZE_LIMIT=300KB → 与字节数比较时按 0 处理：整份 diff 进省略清单，说明还会写成「300KBB」
run_case baddiffsize DIFF_SIZE_LIMIT=300KB
assert_rc "$RC" 1 "DIFF_SIZE_LIMIT 非整数：拒绝运行"
assert_contains "$OUT" "DIFF_SIZE_LIMIT=300KB 不是纯数字" "DIFF_SIZE_LIMIT 非整数：报错点名变量与取值"
assert_eq "$(call_count "$CASE/calls" chat)" "0" "DIFF_SIZE_LIMIT 非整数：没白跑 Kiro"
assert_not_contains "$(posted_comment "$OUT")" "300KBB" "DIFF_SIZE_LIMIT 非整数：不会渲染出 300KBB 这种说明"
run_case zerotimeout KIRO_TIMEOUT=0
assert_rc "$RC" 1 "KIRO_TIMEOUT=0：拒绝运行（0 会让 timeout 变成不限时）"
assert_contains "$OUT" "KIRO_TIMEOUT=0 不合法" "KIRO_TIMEOUT=0：报错"
# 带前导零的取值是纯数字、意图明确：必须按十进制归一化后接受，而不是让 bash 的八进制解析
# 先漏一行 `value too great for base` 再判它「不是纯数字」
run_case leadingzero KIRO_TIMEOUT=0900 DIFF_SIZE_LIMIT=0307200
assert_rc "$RC" 0 "前导零取值：按十进制归一化后照常运行"
assert_not_contains "$OUT" "value too great for base" "前导零取值：不漏 bash 算术报错"
assert_contains "$OUT" "超时 900s" "前导零取值：日志里是归一化后的 900 秒"
# 校验必须在装 kiro-cli 之前：一眼可辨的配置错误不该先花几分钟装 CLI 再失败
assert_eq "$(call_count "$tmp/case-badtimeout/calls" help)" "0" "取值校验早于 kiro-cli 能力检查（没白跑 --help）"
# 合法取值仍照常工作（正控：上面三条不是靠「任何取值都失败」蒙对的）
run_case goodlimits KIRO_TIMEOUT=60 DIFF_SIZE_LIMIT=1000000
assert_rc "$RC" 0 "合法的秒数/字节数：评审照常成功"

# ---- REVIEW_RERUN_HINT：AWS 档位可把提示语换成评论命令（Flow 默认不承诺它）----
run_case rerunhint REVIEW_RERUN_HINT='评论 `/kiro review` 可重新评审'
assert_rc "$RC" 0 "REVIEW_RERUN_HINT：评审成功"
comment=$(posted_comment "$OUT")
assert_contains "$comment" '评论 `/kiro review` 可重新评审' "REVIEW_RERUN_HINT：页脚用配置的提示语"
assert_not_contains "$comment" "重跑流水线可重新评审" "REVIEW_RERUN_HINT：不再出现默认提示语"

report
