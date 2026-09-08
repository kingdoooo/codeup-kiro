#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
source fixture-repo.sh
source ../scripts/lib/isolation.sh   # 15-fix2 #23：等价性用例直接调生产的隔离函数
# 掩码库在这里就 source（原先只在票 04 段之前 source 一次）：本文件用它的 review_fingerprint 与两个 PEM 占位符常量
# （REVIEW_PEM_PLACEHOLDER / REVIEW_PEM_BODY_PH，票 18 ⑪ 起是唯一取值）。只加载函数与常量，不跑主流程。
source ../scripts/lib/review-render.sh

# kiro-review.sh 把 timeout/gtimeout 当强制依赖（无超时能力时拒绝运行），
# 本机缺失时它在第一步就退出，本套件的每条断言都测不到真实行为。
# 与其让成功路径断言炸掉（macOS 默认无 timeout），整体跳过并说明原因。
if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null; then
  echo "SKIP: 本机无 timeout/gtimeout（GNU coreutils），跳过 test-kiro-review.sh" >&2
  exit 0
fi

ROOT=$(cd .. && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# fixture 模板（票 18 ⑨）：本文件的第一个用例在这里建一次业务库模板，之后每个用例从它 `cp -R` 派生
# （每用例仍是独立目录树；派生时 work 的 origin 会改指向副本的 origin.git，见 tests/fixture-repo.sh）
FIXTURE_TEMPLATE_DIR="$tmp/fixture-template"

# --- 公共环境 ---
export PATH="$ROOT/tests/mockbin:$PATH"
# REVIEW_RERUN_HINT 是渲染器唯一的隐式环境输入：开发者环境里导出了它，
# 「默认取 Flow 语义」的断言与 golden 比对就会莫名失败（run_case 用 env 继承外部环境）。
unset REVIEW_RERUN_HINT
export DRY_RUN=1 KIRO_API_KEY=k YUNXIAO_TOKEN=t YUNXIAO_ORG_ID=org123 CODEUP_REPO_ID=456
export MR_LOCAL_ID=7 MR_TARGET_BRANCH=main CI_COMMIT_REF_NAME=feature/x

# 每个用例都重建 fixture（全部注入面文件重新就位，否则第一次运行删完后后面的「工作区干净」断言全是空转）、
# 独立 HOME，并 cd 进业务库 checkout 再调用（模拟 Flow 在 PROJECT_DIR 下调用脚本，让 REVIEW_REPO_DIR
# 回退与 `cd "$PKG_ROOT"` 保护都处在真实条件下）。
# 用法：run_case <名字> [VAR=值 ...]   额外的 VAR=值 只作用于这一次调用（VAR= 表示置空）。
# 可选：CASE_TWEAK=<函数名> 在运行前于 checkout 目录内执行，用来改造 fixture。
# 结果：CASE（用例目录）、MD（替身记录目录 = $CASE/home/.kiro-mock）、RC、OUT；
# 替身记录在 $MD/{args,stdin,settings,cwdscan,calls,helpcwd,env,env-help,env-settings,allowscan,nonce}。
# 替身 kiro-cli 的配置通道（票 15 / 15-fix #14 / 15-fix2 #19）：生产脚本以 `env -i` + 许可清单启动 kiro-cli 的每次调用，MOCK_*
# 环境变量到不了替身。替身只从 $HOME/.kiro-mock/ 取配置与写记录（HOME 在固定名单里、每个用例各有 $CASE/home）——不借道
# KIRO_ENV_PASSTHROUGH，那是安全控制，测试不该与它耦合；passthrough/badpass 是仅有的逃生口用例。行为开关写在
# $MD/mock.env（helpers.sh 的 mock_config_write，与替身的解析器同一份）。拿不到该目录的替身非零退出（97），所以漏配会让用例变红，
# 而不是让「Kiro 未被启动」类断言恒真。直接调用脚本的用例同样要先 mock_config_write "$CASE/home"。
# NO_MOCK_DIR=1 run_case x：故意不建配置目录（测 fail-closed）。
run_case() {
  local name="$1"; shift
  CASE="$tmp/case-$name"; mkdir -p "$CASE/home"; MD="$CASE/home/.kiro-mock"
  make_fixture_repo "$CASE"
  if [[ -n "${CASE_TWEAK:-}" ]]; then (cd "$CASE/work" && "$CASE_TWEAK"); fi
  # 显式清空：`CASE_TWEAK=f run_case x` 这种赋值前缀是否在函数返回后仍然生效，POSIX 未定义
  # （bash 3.2 不保留，POSIX 模式下保留）。不清掉的话，后面每个用例都会跑在被改造过的 fixture 上。
  CASE_TWEAK=""
  if [[ -z "${NO_MOCK_DIR:-}" ]]; then mock_config_write "$CASE/home" "$@"; fi
  NO_MOCK_DIR=""
  RC=0
  OUT=$(cd "$CASE/work" && env HOME="$CASE/home" REVIEW_REPO_DIR="$CASE/work" \
        "$@" "$ROOT/scripts/kiro-review.sh" 2>&1) || RC=$?
}
# 某个 kiro-cli 子命令被调用了几次。calls 文件在「脚本还没调过任何 kiro-cli 子命令」时
# 根本不存在（例如变量校验在安装/能力检查之前就失败了），所以缺文件按 0 处理。
call_count() { local f="$1" name="$2"; [[ -f "$f" ]] || { echo 0; return 0; }; grep -c "^${name}$" "$f" || true; }
# 注入面文件是否还在（任意深度 AGENTS.md / 任意深度 .kiro / 根 lsp.json）
leftovers() { (cd "$CASE/work" && injection_surface_scan | sort | paste -sd' ' -); }   # 谓词只在 helpers.sh 一份（15-fix2 #23）

# posted_comment（从 DRY_RUN 输出里取回写的评论正文）在 tests/helpers.sh（票 18 ⑫：原先两个文件各一份）

# ============ 成功路径 ============
run_case ok
out=$OUT
assert_rc "$RC" 0 "成功路径退出码 0"
assert_contains "$(cat "$MD/args")" "--no-interactive" "kiro 参数：no-interactive"
# 读取边界来自受信 agent 的 allowedPaths（票 15 / P1-15）：参数里不得有任何 --trust-* 开关。
# --trust-tools 让「整个工具免审」与路径边界叠加、语义不透明；--trust-all-tools（拒绝信息里推荐的那个）
# 实测**绕过** allowedPaths（P1-15 T7）。参数文件每行一个参数，按行首匹配，等号与空格两种写法都拦。
assert_eq "$(grep -c -- '^--trust' "$MD/args")" "0" "kiro 参数：没有任何 --trust-* 开关"
args_line=$(paste -sd' ' "$MD/args")
assert_not_contains "$args_line" "--trust-tools" "kiro 参数：不传 --trust-tools（免确认只来自 allowedPaths）"
assert_not_contains "$args_line" "--trust-all-tools" "kiro 参数：绝不传 --trust-all-tools（它绕过 allowedPaths）"
# Kiro 子进程环境 = env -i + 许可清单：替身记下 chat 时环境里的变量名
env_names=$(cat "$MD/env")
for v in YUNXIAO_TOKEN YUNXIAO_ORG_ID CODEUP_REPO_ID DRY_RUN MR_LOCAL_ID MR_TARGET_BRANCH CI_COMMIT_REF_NAME KIRO_ENV_PASSTHROUGH REVIEW_REPO_DIR; do
  assert_eq "$(printf '%s\n' "$env_names" | grep -c -x -- "$v")" "0" "Kiro 进程环境：没有 $v"
done
for v in PATH HOME KIRO_API_KEY KIRO_LOG_NO_COLOR; do
  assert_eq "$(printf '%s\n' "$env_names" | grep -c -x -- "$v")" "1" "Kiro 进程环境：有 $v"
done
# 第 3 步自检（15-fix2 #16）：日志声称的事实要有断言——这行只在 kiro_agent_selfcheck 通过时打出（值比对 + 安全字段）
assert_contains "$out" "受信 agent 自检通过" "第 3 步自检通过并留痕"
# kiro-cli 版本在 KIRO_TESTED_VERSIONS 名单内（替身默认 2.21.1）→ 不出 notice（15-fix2 #24）
assert_contains "$out" "在 P1-15 探测过的版本名单内" "kiro-cli 版本核对：名单内"
assert_not_contains "$out" "未经 P1-15 探测" "kiro-cli 版本核对：名单内时无警告"
# 另三处 kiro-cli 调用（chat --help、--version、settings）同样走 env -i + 许可清单（15-fix #8 / 15-fix4 #18）：README 与指南的
# 「Kiro 进程看不到…」才是绝对表述。替身把四次调用各自收到的环境变量名分别记在 env-help / env-version / env-settings / env。
for f in env-help env-version env-settings; do
  names_f=$(cat "$MD/$f")
  for v in YUNXIAO_TOKEN YUNXIAO_ORG_ID CODEUP_REPO_ID KIRO_ENV_PASSTHROUGH; do
    assert_eq "$(printf '%s\n' "$names_f" | grep -c -x -- "$v")" "0" "${f}：这次 kiro-cli 调用的环境里没有 $v"
  done
  for v in PATH HOME KIRO_API_KEY; do
    assert_eq "$(printf '%s\n' "$names_f" | grep -c -x -- "$v")" "1" "${f}：这次 kiro-cli 调用的环境里有 $v"
  done
done
assert_eq "$(call_count "$MD/calls" version)" "1" "kiro-cli --version 被调用一次（版本核对）"
assert_eq "$(cat "$MD/cwdscan")" "" "Kiro 启动时工作区里没有残留的注入面文件与符号链接"
assert_contains "$out" "Kiro 进程环境许可清单" "日志打出透传的变量名清单"
env_log_line=$(printf '%s\n' "$out" | grep -F "Kiro 进程环境许可清单" | head -1)
assert_contains "$env_log_line" "KIRO_API_KEY" "许可清单日志行列出 KIRO_API_KEY（只有名字）"
assert_not_contains "$env_log_line" "YUNXIAO_TOKEN" "许可清单日志行不含 YUNXIAO_TOKEN"
assert_not_contains "$out" "KIRO_API_KEY=k" "日志里不出现变量取值"
assert_contains "$args_line" "--agent codeup-reviewer" "kiro 参数：套用受信 custom agent codeup-reviewer"
assert_contains "$args_line" "--agent-engine v2" "kiro 参数：固定 --agent-engine v2"
assert_contains "$out" "引擎：v2" "日志显式记录所用引擎为 v2"
# 结构化输出契约依赖 stream-json（v1 引擎不支持该参数）：整行精确匹配，避免别的取值蒙混过关
assert_eq "$(grep -c -x -- '--output-format' "$MD/args")" "1" "kiro 参数：只有一个 --output-format"
assert_contains "$args_line" "--output-format stream-json" "kiro 参数：固定 --output-format stream-json"
assert_contains "$(cat "$MD/stdin")" "SECRET_KEY" "diff 已喂入 stdin"
# D4（2026-09-08）：真实 kiro-cli 2.21.1 有位置参数 [INPUT] 时整个忽略 stdin——运行时提示词与评审输入必须一起走 stdin、不给位置参数。
# 替身按真机行为实现（有位置参数 → stdin 记为空），所以旧写法下面几条会一起变红（变异 M-d4a）。
assert_eq "$(cat "$MD/positional")" "" "kiro 参数：没有位置参数 INPUT（有的话真机会丢掉 stdin 里的整份评审输入）"
assert_eq "$([[ "$(cat "$MD/nonce")" == nononcefound000 ]] && echo fallback || echo real)" "real" "替身从 stdin 里的提示词取到了本次 nonce"
assert_contains "$(cat "$MD/stdin-prompt")" "<<<KIRO_REVIEW_JSON:$(cat "$MD/nonce")>>>" "stdin 前半是运行时提示词（含本次 nonce 的标记模板）"
assert_eq "$(LC_ALL=C grep -c -x -F -- '=== REVIEW INPUT BEGIN ===' "$MD/stdin-full")" "1" "stdin 里恰好一行「评审输入开始」分隔"
assert_eq "$(LC_ALL=C grep -c -x -F -- '=== 变更元信息 ===' "$MD/stdin")" "1" "stdin 后半（评审输入）以变更元信息节开头，恰好一处"
assert_eq "$(LC_ALL=C grep -c -x -F -- '=== DIFF ===' "$MD/stdin")" "1" "stdin 后半（评审输入）恰好一个 DIFF 节标题"
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
# 票 17 B/C：契约内的结论、没有重复问题时，两条警告都不该出现（正控）
assert_not_contains "$out" "结论不在契约内" "票 17 B 正控：契约内结论不打警告"
assert_not_contains "$out" "完全重复的问题已合并" "票 17 C 正控：没有重复问题时不打警告"

# --- 隔离：diff 先算好，随后业务库工作树中的注入面文件在 Kiro 启动前被移除 ---
assert_contains "$(cat "$MD/stdin")" "CANARY-AGENTSMD-ROOT" "diff 先算：stdin 仍含根 AGENTS.md 的改动"
assert_contains "$(cat "$MD/stdin")" "CANARY-AGENTSMD-NESTED" "diff 先算：stdin 仍含子目录 AGENTS.md 的改动"
assert_contains "$(cat "$MD/stdin")" "+++ b/lsp.json" "diff 先算：stdin 仍含 lsp.json 的改动"
assert_contains "$(cat "$MD/stdin")" "mcpServers" "diff 先算：stdin 仍含 .kiro/settings/mcp.json 的改动"
assert_eq "$(cat "$MD/cwdscan")" "" "Kiro 启动时工作区已无 AGENTS.md（任意深度）/根 lsp.json/.kiro（任意深度）"
assert_eq "$(leftovers)" "" "运行后工作树无残留注入面文件"
assert_eq "$([[ -f "$CASE/work/src/app.py" ]] && echo y || echo n)" "y" "其余业务文件未被误删"
assert_eq "$([[ -d "$CASE/work/.git" ]] && echo y || echo n)" "y" ".git 未被触碰"
diff_ln=$(printf '%s\n' "$out" | grep -n 'diff 已生成' | head -1 | cut -d: -f1)
iso_ln=$(printf '%s\n' "$out" | grep -n '隔离：' | head -1 | cut -d: -f1)
assert_eq "$([[ -n "$diff_ln" && -n "$iso_ln" && "$iso_ln" -gt "$diff_ln" ]] && echo ok || echo bad)" "ok" \
  "隔离步骤的日志出现在 diff 生成之后（diff_ln=${diff_ln:-?} iso_ln=${iso_ln:-?}）"

# --- 隔离：执行环境禁止继承工作区默认资源，且在 Kiro 启动前生效 ---
assert_contains "$(cat "$MD/settings")" "chat.disableInheritingDefaultResources true" "Kiro 启动前设置 chat.disableInheritingDefaultResources=true"
assert_eq "$(awk '/^settings$/{s=NR} /^chat$/{c=NR} END{print (s && c && s<c) ? "ok" : "bad"}' "$MD/calls")" "ok" \
  "调用顺序：settings 先于 chat"
# 15-fix4 #1：四处 kiro-cli 调用（--help / --version / settings / chat）都在 $WORK/cwd 空目录下运行——kiro-cli 相对 cwd 发现的每一个面
# （$CWD/.kiro/agents 顶替同名受信 agent、.kiro/settings/cli.json 顶掉全局设置、AGENTS.md steering、lsp.json）都落在没有文件的目录里；
# 业务库只在 allowedPaths 里。三个 cwd 记录必须相同、名为 cwd、与 chunks 同父目录（同一个 $WORK）、不是业务库也不是集成包、chat 时为空。
ws_p=$(cd "$CASE/work" && pwd -P)
kcwd=$(cat "$MD/chatcwd")
assert_eq "$(cat "$MD/helpcwd")" "$kcwd" "kiro-cli chat --help 与 chat 在同一个运行目录下执行"
assert_eq "$(cat "$MD/settingscwd")" "$kcwd" "kiro-cli settings 与 chat 在同一个运行目录下执行"
assert_eq "$(basename "$kcwd")" "cwd" "Kiro 运行目录是 \$WORK/cwd（实际：${kcwd}）"
assert_eq "$([[ "$kcwd" == "$ws_p" || "$kcwd" == "$ws_p"/* ]] && echo in-repo || echo outside)" "outside" "Kiro 运行目录不是业务库 checkout、也不在其内"
assert_eq "$([[ "$kcwd" == "$ROOT" || "$kcwd" == "$ROOT"/* ]] && echo in-pkg || echo outside)" "outside" "Kiro 运行目录不在集成包内"
assert_eq "$(cat "$MD/chatcwd-entries")" "0" "chat 启动时运行目录为空（没有任何文件可被 kiro-cli 相对 cwd 发现）"
assert_contains "$out" "Kiro 运行目录：${kcwd}" "日志打出 Kiro 运行目录"
# 业务库绝对路径穿进运行时提示词：模型在空目录下必须按绝对路径读文件（相对路径会被拒、静默降低评审质量）
prompt_arg=$(cat "$MD/stdin-prompt")   # 运行时提示词走 stdin 前半（D4：不再是位置参数），替身按分隔行切出来存 stdin-prompt
assert_contains "$prompt_arg" "$ws_p" "运行时提示词含业务库 checkout 的物理路径"
assert_contains "$prompt_arg" "${ws_p}/src/app.py" "运行时提示词用业务库路径举例绝对路径的写法"
assert_not_contains "$prompt_arg" "{{REVIEW_WORKSPACE}}" "运行时提示词里的 {{REVIEW_WORKSPACE}} 已替换"
assert_not_contains "$prompt_arg" "{{" "运行时提示词里没有任何占位符残留"

# --- 受信 agent 安装：按 name 落盘，prompt 改写为集成包内提示词的绝对 file:// 路径 ---
inst="$CASE/home/.kiro/agents/codeup-reviewer.json"
assert_eq "$([[ -f "$inst" ]] && echo y || echo n)" "y" "受信 agent 已安装到 ~/.kiro/agents/codeup-reviewer.json"
inst_prompt=$(jq -r .prompt "$inst")
assert_eq "$([[ "$inst_prompt" == file:///*/prompts/review-agent-prompt.md ]] && echo abs || echo other)" "abs" \
  "安装后的 prompt 为绝对 file:// 路径（实际：${inst_prompt}）"
assert_eq "$([[ -r "${inst_prompt#file://}" ]] && echo y || echo n)" "y" "prompt 引用的提示词文件存在且可读"
assert_eq "$(jq -c '[.includeMcpJson, .includePowers]' "$inst")" "[false,false]" "安装后的 agent 不含 MCP/Powers"
assert_eq "$(jq -c 'del(.prompt) | del(.toolsSettings[].allowedPaths) | del(.toolsSettings[].deniedPaths) | del(.permissions)' "$inst")" "$(jq -c 'del(.prompt) | del(.toolsSettings[].allowedPaths) | del(.toolsSettings[].deniedPaths) | del(.permissions)' "$ROOT/kiro/agent-codeup-reviewer.json")" \
  "安装只改写 prompt、三处 allowedPaths、三处 deniedPaths 与 V3 的 permissions.rules[fs_read].match（都只追加按 allow 根注入的绝对副本），其余字段与集成包一致"
assert_eq "$(jq -c '.toolsSettings.read.deniedPaths[:32]' "$inst")" "$(jq -c '.toolsSettings.read.deniedPaths' "$ROOT/kiro/agent-codeup-reviewer.json")" "安装后 deniedPaths 前段就是集成包的原条目（顺序不变，只在末尾追加）"
# --- 读取边界（票 15）：allowedPaths = 业务库 checkout 物理路径 + 本次 $WORK/chunks；allowedTools 为空 ---
assert_eq "$(jq -r '.toolsSettings.read.allowedPaths | length' "$inst")" "2" "安装后 allowedPaths 恰好两条"
assert_eq "$(jq -r '.toolsSettings.read.allowedPaths[0]' "$inst")" "$ws_p" "allowedPaths[0] = 业务库 checkout 的物理路径"
chunks_p=$(jq -r '.toolsSettings.read.allowedPaths[1]' "$inst")
assert_eq "$([[ "$chunks_p" == /*/chunks ]] && echo y || echo n)" "y" "allowedPaths[1] 是绝对路径下的 chunks 目录（实际：${chunks_p}）"
assert_eq "$([[ "$chunks_p" == "$ws_p"/* ]] && echo inside || echo outside)" "outside" "chunks 目录不在业务库 checkout 之内（是 mktemp 出来的工作目录）"
assert_eq "$(dirname "$chunks_p")" "$(dirname "$kcwd")" "Kiro 运行目录与 chunks 同在本次 \$WORK 下"
assert_eq "$(jq -c '.toolsSettings | [.read.allowedPaths, .grep.allowedPaths, .glob.allowedPaths] | unique | length' "$inst")" "1" "read/grep/glob 的 allowedPaths 同组"
assert_eq "$(jq -c .allowedTools "$inst")" "[]" "安装后 allowedTools 为空"
# 15-fix4 #1 补：kiro-cli 把 **/ 形状按 cwd 解析，空 cwd 下要靠按 allow 根注入的绝对副本护住业务库里的 .git / .ssh（探测 t15fix4-4b30a00 T3/T9 实测）
for pat in '**/.git/**' '**/.git' '**/.ssh/**' '**/.aws/**' '**/id_rsa*' '**/id_ed25519*'; do
  assert_eq "$(jq -r --arg p "${ws_p}/${pat}" '.toolsSettings.read.deniedPaths | index($p) != null' "$inst")" "true" "安装后 deniedPaths 含业务库根前缀的 ${pat}"
  assert_eq "$(jq -r --arg p "${chunks_p}/${pat}" '.toolsSettings.read.deniedPaths | index($p) != null' "$inst")" "true" "安装后 deniedPaths 含 chunks 根前缀的 ${pat}"
done
assert_contains "$out" "已按两条 allow 根注入绝对副本（8 条 × 2）" "自检日志写明注入条目数"
assert_eq "$(jq '[.. | strings | select(contains("{{"))] | length' "$inst")" "0" "安装后没有残留占位符"
assert_contains "$out" "受信 agent 许可路径：${ws_p}、${chunks_p}" "日志打出许可路径两条（与安装文件一致）"
# chat 时两条许可路径都真实存在（chunks 目录在 Kiro 启动前已建好——否则 build_review_input 之前装的 agent 指向一个还没有的目录）
assert_eq "$(awk -F'\t' '{print $2}' "$MD/allowscan" | sort -u)" "dir" "Kiro 启动时两条许可路径都是存在的目录"
assert_eq "$(grep -c . "$MD/allowscan")" "2" "allowscan 记录了两条路径"

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
assert_eq "$(cat "$MD/cwdscan")" "" "Kiro 启动时工作区干净"

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

RC=0; CASE="$tmp/case-selftarget"; mkdir -p "$CASE/home"; MD="$CASE/home/.kiro-mock"; mock_config_write "$CASE/home"
OUT=$(cd "$PKGCOPY" && env HOME="$CASE/home" REVIEW_REPO_DIR="$PKGCOPY" \
      MOCK_ARGS_FILE="$CASE/args" "$PKGCOPY/scripts/kiro-review.sh" 2>&1) || RC=$?
assert_nonzero "$RC" "REVIEW_REPO_DIR=集成包：非零退出"
assert_contains "$OUT" "互相包含" "REVIEW_REPO_DIR=集成包：报错说明"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "REVIEW_REPO_DIR=集成包：Kiro 未被启动"
assert_eq "$(sentinel_intact)" "intact" "REVIEW_REPO_DIR=集成包：集成包内的 AGENTS.md 与 .kiro/ 都还在"

# 符号链接不能绕过这道保护（R10①：路径规范化必须用 pwd -P）
ln -s "$PKGCOPY" "$tmp/pkglink"
RC=0; CASE="$tmp/case-selflink"; mkdir -p "$CASE/home"; MD="$CASE/home/.kiro-mock"; mock_config_write "$CASE/home"
OUT=$(cd "$tmp" && env HOME="$CASE/home" REVIEW_REPO_DIR="$tmp/pkglink" \
      MOCK_ARGS_FILE="$CASE/args" "$PKGCOPY/scripts/kiro-review.sh" 2>&1) || RC=$?
assert_nonzero "$RC" "REVIEW_REPO_DIR=指向集成包的符号链接：非零退出"
assert_contains "$OUT" "互相包含" "符号链接：同样被这道保护拦住"
assert_eq "$(sentinel_intact)" "intact" "符号链接：集成包内的哨兵文件仍在"

# REVIEW_REPO_DIR 在集成包**内部**同样会删到集成包的文件，反向包含也要拦
RC=0; CASE="$tmp/case-selfinner"; mkdir -p "$CASE/home" "$PKGCOPY/nested"; MD="$CASE/home/.kiro-mock"; mock_config_write "$CASE/home"
OUT=$(cd "$tmp" && env HOME="$CASE/home" REVIEW_REPO_DIR="$PKGCOPY/nested" \
      MOCK_ARGS_FILE="$CASE/args" "$PKGCOPY/scripts/kiro-review.sh" 2>&1) || RC=$?
assert_nonzero "$RC" "REVIEW_REPO_DIR=集成包内的子目录：非零退出"
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
assert_eq "$(cat "$MD/cwdscan")" "" ".kiro 为符号链接：Kiro 启动时工作区干净"
assert_eq "$([[ -f "$CASE/evilcfg/settings/mcp.json" ]] && echo y || echo n)" "y" \
  "只删链接本身，不跟着链接把目标目录的内容删掉"

# ============ 失败路径：kiro 失败 → 回写"评审未完成" + 非零退出 ============
run_case kirofail MOCK_KIRO_FAIL=1
assert_nonzero "$RC" "kiro 失败：非零退出"
assert_contains "$OUT" "评审未完成" "kiro 失败：回写说明评论"

# ============ 失败路径：退出码 0 但输出为空 → 同失败处理 ============
run_case empty MOCK_KIRO_EMPTY=1
assert_nonzero "$RC" "空输出：非零退出"
assert_contains "$OUT" "评审未完成" "空输出：回写说明评论"

# ============ 失败路径：挂起 → 超时强杀（timeout/gtimeout 已由文件开头的前置检查保证）============
run_case hang MOCK_KIRO_HANG=1 KIRO_TIMEOUT=3
assert_nonzero "$RC" "挂起：超时后非零退出"
assert_contains "$OUT" "评审未完成" "挂起：回写说明评论"
assert_contains "$OUT" "Kiro 评审超时（3s）" "挂起：124 按超时点名 KIRO_TIMEOUT"
assert_contains "$(posted_comment "$OUT")" "超时" "挂起：失败评论含「超时」"

# ============ 失败路径：挂起且忽略 TERM → timeout -k 30 以 KILL 结束、退出码 137 也算超时（票 18 ③）============
# 真机里挂死的 kiro-cli 就是这个形态：TERM 无响应、30 秒后被 KILL。137 不能落到「kiro-cli 退出码 137」那条通用文案里——
# 那对运维是不可行动的信息。本用例要等 KIRO_TIMEOUT + 30 秒（-k 30 写死在脚本里）。
run_case hang137 MOCK_KIRO_HANG=1 MOCK_KIRO_HANG_IGNORE_TERM=1 KIRO_TIMEOUT=1
assert_nonzero "$RC" "挂起忽略 TERM：非零退出"
assert_contains "$OUT" "Kiro 评审超时（1s；进程未响应 TERM，已强制结束）" "挂起忽略 TERM：137 按超时处理并点明强杀"
assert_contains "$(posted_comment "$OUT")" "超时" "挂起忽略 TERM：失败评论含「超时」"
assert_not_contains "$OUT" "kiro-cli 退出码 137" "挂起忽略 TERM：不再写成不可行动的「退出码 137」"

# ============ 失败路径：settings 设置失败 → 隔离不成立，不启动 Kiro，回写"评审未完成" ============
run_case settingsfail MOCK_SETTINGS_FAIL=1
assert_nonzero "$RC" "settings 失败：非零退出"
assert_contains "$OUT" "评审未完成" "settings 失败：回写说明评论"
assert_contains "$OUT" "disableInheritingDefaultResources" "settings 失败：日志点名失败的设置项"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "settings 失败：Kiro 未被启动"

# ============ 失败路径：kiro-cli 不支持 --agent-engine（旧版）→ 拒绝运行，且 MR 上可见（spec I10）============
run_case oldcli MOCK_KIRO_NO_ENGINE_FLAG=1
assert_nonzero "$RC" "旧版 kiro-cli：非零退出"
assert_contains "$OUT" "--agent-engine" "旧版 kiro-cli：报错点名 --agent-engine"
assert_contains "$OUT" "评审未完成" "旧版 kiro-cli：回写「评审未完成」评论（失败可见）"
assert_contains "$OUT" "changeRequests/7/comments" "旧版 kiro-cli：评论发到 MR 7"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "旧版 kiro-cli：Kiro 未被启动"

# ============ 评论截断：MAX_COMMENT_BYTES 很小时评论被截断并注明 ============
# 1100：高于下界 1024（票 18 ②，更小的取值回落默认 60000、不再截断），低于这条评论的 ~1.9 KB
run_case truncate MAX_COMMENT_BYTES=1100
assert_rc "$RC" 0 "截断路径仍成功"
assert_contains "$OUT" "已截断" "截断注明"
assert_contains "$OUT" "上限 1100 字节" "截断提示写的是生效的上限"

# ============ MAX_COMMENT_BYTES 的十进制归一与下界（票 18 ②）============
# 06d5028 上 `0900` 会报「value too great for base」且被判合法 → 截断整体静默失效（正控：那条 assert_not_contains 在基线上失败）
run_case mcb-01200 MAX_COMMENT_BYTES=01200
assert_rc "$RC" 0 "MAX_COMMENT_BYTES=01200：前导零按十进制归一后照常运行"
assert_not_contains "$OUT" "value too great for base" "MAX_COMMENT_BYTES=01200：不漏 bash 算术报错"
assert_contains "$OUT" "MAX_COMMENT_BYTES=01200 按十进制归一为 1200" "MAX_COMMENT_BYTES=01200：日志写明归一结果"
assert_contains "$OUT" "上限 1200 字节" "MAX_COMMENT_BYTES=01200：截断按归一后的 1200 生效"
run_case mcb-0900 MAX_COMMENT_BYTES=0900
assert_rc "$RC" 0 "MAX_COMMENT_BYTES=0900：照常运行"
assert_not_contains "$OUT" "value too great for base" "MAX_COMMENT_BYTES=0900：不漏 bash 算术报错（06d5028 上会漏）"
assert_contains "$OUT" "MAX_COMMENT_BYTES=0900（=900） 低于下界 1024" "MAX_COMMENT_BYTES=0900：归一成 900 后低于下界、告警点明两个数"
assert_not_contains "$OUT" "已截断" "MAX_COMMENT_BYTES=0900：回落默认 60000 后不截断（06d5028 上是「静默不截断」，这里是「告警后不截断」）"
run_case mcb-010 MAX_COMMENT_BYTES=010
assert_rc "$RC" 0 "MAX_COMMENT_BYTES=010：照常运行"
assert_contains "$OUT" "MAX_COMMENT_BYTES=010（=10） 低于下界 1024" "MAX_COMMENT_BYTES=010：归一成 10 后回落默认并告警"
run_case mcb-abc MAX_COMMENT_BYTES=abc
assert_rc "$RC" 0 "MAX_COMMENT_BYTES=abc：照常运行"
assert_contains "$OUT" "MAX_COMMENT_BYTES=abc 不是整数，按默认 60000 处理" "MAX_COMMENT_BYTES=abc：非整数回落默认并告警"
assert_not_contains "$OUT" "已截断" "MAX_COMMENT_BYTES=abc：按默认 60000 不截断"
run_case mcb-512 MAX_COMMENT_BYTES=512
assert_rc "$RC" 0 "MAX_COMMENT_BYTES=512：照常运行"
assert_contains "$OUT" "MAX_COMMENT_BYTES=512 低于下界 1024" "MAX_COMMENT_BYTES=512：低于下界回落默认并告警（十进制形态不变时不重复打数字）"
assert_not_contains "$OUT" "已截断" "MAX_COMMENT_BYTES=512：按默认 60000 不截断"
assert_not_contains "$OUT" "拒绝截断" "MAX_COMMENT_BYTES=512：不会走到截断守卫的 rc 3（下界挡在前面）"

# ============ 票 18 ⑩：jq 版本预检（契约校验用 halt_error，需要 jq ≥ 1.6）============
# 替身 jq 只改写 --version 的输出，其余调用透传给真 jq——脚本必须在第 0 步就拒绝运行（更老的 jq 会在 halt_error 处退 3，
# 那会被当成「受信 agent 未生效」，把环境问题写成安全结论）
mkdir -p "$tmp/oldjq"
{ echo '#!/usr/bin/env bash'
  echo '[[ "${1:-}" == "--version" ]] && { echo "jq-1.5"; exit 0; }'
  printf 'exec %q "$@"\n' "$(command -v jq)"
} > "$tmp/oldjq/jq"; chmod +x "$tmp/oldjq/jq"
run_case oldjq PATH="$tmp/oldjq:$PATH"
assert_rc "$RC" 1 "jq 1.5：拒绝运行"
assert_contains "$OUT" "jq 版本过低" "jq 1.5：报错点名版本"
assert_contains "$OUT" "halt_error" "jq 1.5：报错说明为什么需要 ≥ 1.6"
assert_eq "$(call_count "$MD/calls" help)" "0" "jq 1.5：没白跑 kiro-cli（预检在第 0 步）"
# 认不出版本形态时只告警、不拒绝（自编译 jq 可能打印别的形态）
mkdir -p "$tmp/weirdjq"
{ echo '#!/usr/bin/env bash'
  echo '[[ "${1:-}" == "--version" ]] && { echo "homemade json query"; exit 0; }'
  printf 'exec %q "$@"\n' "$(command -v jq)"
} > "$tmp/weirdjq/jq"; chmod +x "$tmp/weirdjq/jq"
run_case weirdjq PATH="$tmp/weirdjq:$PATH"
assert_rc "$RC" 0 "认不出 jq 版本：只告警、评审照常跑完"
assert_contains "$OUT" "认不出 jq 版本" "认不出 jq 版本：日志留痕"

# ============ 失败路径：提示词文件不可读 → 立即失败，不带空提示词跑 Kiro ============
run_case noprompt PROMPT_FILE=/nonexistent
assert_nonzero "$RC" "提示词缺失：非零退出"
assert_contains "$OUT" "提示词文件不可读" "提示词缺失：报错说明"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "提示词缺失：Kiro 未被启动"

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
assert_nonzero "$RC" "status 非 success：非零退出"
assert_contains "$OUT" "评审未完成" "status 非 success：回写失败评论"
assert_contains "$OUT" "自报运行失败" "status 非 success：错误说明点名原因"
assert_contains "$OUT" "status=error" "status 非 success：错误说明带上 status 值"
assert_not_contains "$OUT" "结构化解析失败" "status 非 success：不走降级（不是解析问题）"

# ============ Kiro 失败：事件流没有 runFinished → 走失败评论路径 ============
run_case norunfinished MOCK_KIRO_NO_RUNFINISHED=1
assert_nonzero "$RC" "无 runFinished：非零退出"
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
assert_nonzero "$RC" "INLINE_COMMENT=yes：非零退出"
assert_contains "$OUT" "INLINE_COMMENT=yes" "INLINE_COMMENT=yes：报错点名开关取值"
assert_contains "$OUT" "评审未完成" "INLINE_COMMENT=yes：回写失败评论（失败可见）"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "INLINE_COMMENT=yes：不浪费额度，Kiro 未被启动"

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
assert_nonzero "$RC" "缺 contract 字段：非零退出"
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
# 取值取 helpers.sh 的 fake_token（票 18 ⑫：替身与断言两边原先各写一份字面量）
assert_not_contains "$OUT" "$(fake_token awssecret)" "原文含未掩码凭证：评论里不出现完整密钥"
assert_not_contains "$OUT" "$(fake_token akia)" "原文含未掩码凭证：评论里不出现完整 AWS 访问密钥 ID"
assert_contains "$OUT" "wJal****EKEY" "原文含未掩码凭证：脚本掩码后保留前 4 后 4"
assert_contains "$OUT" "AKIA****MPLE" "原文含未掩码凭证：AWS 访问密钥 ID 同样掩码"
# 票 10 ①：取值末尾带 base64 补位（值里含 `=`）的形态同样要掩掉
assert_not_contains "$OUT" "$SEC_B64" "原文含未掩码凭证：base64 补位结尾的取值不进评论（替身用的就是 SEC_B64）"
# DRY_RUN 打的是 JSON body，引号在里面是 \"，所以只断言取值本身（不带引号）
assert_contains "$OUT" 'dGhp****dA==' "原文含未掩码凭证：补位形态也保留前 4 后 4"
assert_contains "$OUT" 'api_key = ' "原文含未掩码凭证：键名保留"
# 票 10 ②：只引用了 PEM 起始行时，其后的结论不能被吞掉，且要给出未闭合提示
pem_body=$(fake_token pem1)    # 与替身的 PEM_BODY / PEM_BODY2 同一来源（helpers.sh 的 fake_token，票 18 ⑫）
pem_body2=$(fake_token pem2)   # 第 26 条改定义后尾巴要像随机 base64）
assert_not_contains "$OUT" "$pem_body" "原文含未掩码凭证：说明行之后的整行私钥正文不进评论"
# 16-fix3 第 14 条：降级原文走保行模式——正文行就地换成占位、起始行保留为标记、不插提示行、不删任何行
assert_contains "$OUT" "$REVIEW_PEM_BODY_PH" "原文含未掩码凭证：整行正文换成等行数的屏蔽占位（保行模式）"
assert_not_contains "$OUT" "$pem_body2" "原文含未掩码凭证：夹在句子里的正文片段不进评论"
assert_contains "$OUT" "正文片段 MIIE****2Lm4 出现在 app/key.pem" "原文含未掩码凭证：片段掩码后句子其余部分完整"
assert_contains "$OUT" "（下面是私钥内容，节选）" "原文含未掩码凭证：起始行后的说明行放出来（不被吞）"
assert_not_contains "$OUT" "没有配对的 END 行" "原文含未掩码凭证（第 14 条）：保行模式不再插「未闭合」提示行"
assert_contains "$OUT" "BEGIN RSA PRIVATE KEY" "原文含未掩码凭证（第 14 条）：起始行作为标记原位保留"
assert_contains "$OUT" "总体结论：不建议合并。" "原文含未掩码凭证：未闭合 PEM 之后的结论仍在评论里"

# ============ 能力检查：kiro-cli 不支持 --output-format → 拒绝运行，不白烧额度 ============
run_case nostreamflag MOCK_KIRO_NO_STREAM_FLAG=1
assert_nonzero "$RC" "不支持 --output-format：非零退出"
assert_contains "$OUT" "不支持 --output-format" "不支持 --output-format：报错点名参数"
assert_contains "$OUT" "评审未完成" "不支持 --output-format：回写失败评论（失败可见）"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "不支持 --output-format：Kiro 未被启动"

# ============ 失败评论的标题与标记必须与成功/降级评论同形（供后续票原地更新）============
run_case failheader MOCK_KIRO_FAIL=1
assert_contains "$OUT" "# Kiro 代码评审 · ⚠️ 评审未完成" "失败评论：标题与成功评论同一产品名"
# 15-fix4 #3：kiro-cli 非零退出 + 未探测版本 → 失败评论带版本告警（这条路径上 MR 只剩失败评论，告警不能丢；对 5462175 必须失败）
run_case failnotice MOCK_KIRO_FAIL=1 MOCK_KIRO_VERSION=9.9.9
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "失败 + 未探测版本：非零退出"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "评审未完成" "失败 + 未探测版本：是失败评论"
assert_contains "$comment" "> ⚠️ 注意：本次 kiro-cli 版本 9.9.9 未经 P1-15 探测" "失败 + 未探测版本：失败评论带版本告警引用块"
assert_contains "$comment" "构建号" "失败 + 未探测版本：日志线索仍在"
assert_not_contains "$OUT" "Kiro 自动代码评审" "失败评论：不再使用旧标题"
assert_eq "$(printf '%s' "$OUT" | grep -c 'kiro-review:[0-9a-f]* run:1')" "1" "失败评论：标记带 run 字段，与成功评论同形"

# ============ R8：按字节截断落在代码围栏内部时，截断提示必须仍然可见 ============
# fix 字段里带一段较长的 ```python 代码块；MAX_COMMENT_BYTES 选在围栏内部切断。
# 不补闭合围栏的话，后面追加的「已截断」提示会被 Markdown 当成代码块内容渲染掉，
# 读者只看到评论突然结束、完全不知道内容缺了。
run_case fencetrunc MAX_COMMENT_BYTES=1200 MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/fenced-code.json"   # 1200：≥ 下界 1024（票 18 ②），仍落在 877–2977 字节的围栏内部
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
assert_nonzero "$RC" "失败评论 + 原地更新：非零退出"
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
# 票 18 ⑤：选择器的多候选告警要经 log 转成带前缀的流水线日志行，并列出每条候选的 id 与 run（MR 上多出的那条要人工删）
assert_contains "$OUT" "[kiro-review] review_select_prior_comment: 警告：同一机器人有 2 条带合法评审标记的汇总评论候选：f0000000000000000000000000000001（run:1）、f0000000000000000000000000000003（run:3）" \
  "两条候选（票 18 ⑤）：告警经 log 带上 [kiro-review] 前缀，列出两条的 id 与 run"
assert_contains "$OUT" "本次原地更新 run 最大的那条（f0000000000000000000000000000003）" "两条候选（票 18 ⑤）：告警说明选了哪条"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "0" "两条候选（票 18 ⑤）：不新建第三条"

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
# 掩码库已在文件开头 source（review_fingerprint 与 PEM 占位符常量都来自它，与生产同一份实现）

E2E_CONTRACT="$ROOT/tests/fixtures/contract/inline-e2e.json"
# fixture 仓库里 src/app.py 只有第 2 行是新增行（base: import os/def main/pass），
# 所以 inline-e2e.json 里锚在第 2 行的问题可定位，锚在第 99 行与没有 file 的不可定位。
IFX_DIR=""
# 版本列表 fixture 的**唯一**入口（票 17-fix2 C⑦：原先六个 mk_* 各写一份，改一处 schema 要同步六处）。
# 由 CASE_TWEAK 在 $CASE/work 里执行，读下面这几个全局量；每次 run_inline_case 之后复位成默认值。
#   PS_SRC     最新 MERGE_SOURCE 的 commitId：HEAD（默认，真实全 sha）/ HEAD12（前 12 位缩写）/
#              HEADUP（全大写）/ PARENT（HEAD^，模拟版本列表滞后）/ OMIT（不带该字段）/ 其它值原样写入
#   PS_TGT     最新 MERGE_TARGET 的 commitId：BASE（默认，真实 merge-base）/ OMIT / NONE（整条不写，
#              于是选不出版本对）/ 其它值原样写入
#   PS_SRC_ID / PS_TGT_ID  两个版本的 patchSetBizId（默认 src-2 / tgt-1；断言点名版本时才改）
#   CASE_EXTRA_TWEAK       再跑一个函数（改业务库、写别的 fixture），在写完版本列表之后执行
# 默认值让每个用例都拿到「to = 真实 HEAD、from = 真实 merge-base」——否则每个用例都会打
# 「与 HEAD 不一致」或「不等于 merge-base」的警告，那两条警告本身就再也测不出来了。
CASE_EXTRA_TWEAK=""
# 版本列表 fixture 的实现在 tests/helpers.sh 的 mk_patchsets_fixture（票 17-fix3 ⑫：只留一份，
# 两个套件共用；未知模式硬错误）。这里只做「设好目录 → 调它 → 再跑用例自己的 tweak」。
mk_patchsets() {
  PS_FIXTURE_DIR="$IFX_DIR" mk_patchsets_fixture
  [[ -z "$CASE_EXTRA_TWEAK" ]] || "$CASE_EXTRA_TWEAK"
}
# 用法：run_inline_case <用例名> <fixture 目录名> [VAR=值 …]；版本列表形态与额外改造走上面那几个全局量
run_inline_case() {
  local name="$1" fx="$2"; shift 2
  IFX_DIR="$tmp/$fx"
  CASE_TWEAK=mk_patchsets run_case "$name" \
    DRY_RUN_FIXTURE_DIR="$IFX_DIR" CODEUP_BOT_USERNAME="$BOT" INLINE_COMMENT=1 \
    MOCK_KIRO_CONTRACT="$E2E_CONTRACT" "$@"
  # 复位：`PS_SRC=… run_inline_case …` 这种赋值前缀是否在函数返回后仍生效，POSIX 未定义
  reset_ps_vars; CASE_EXTRA_TWEAK=""
}
# inline_bodies（本次创建了哪些行内评论）在 helpers.sh 里，与变异测试共用同一份实现。
# 提交草稿那一次请求的 body
submit_body() { printf '%s\n' "$1" | grep -F 'DRY_RUN body: {"submitDraftCommentIds"' | tail -1 | sed 's/^DRY_RUN body: //'; }

# ---- 成功路径（默认档位 quiet、默认上限 10）----
run_inline_case ok1 ifx-ok1
assert_rc "$RC" 0 "行内开启：退出码 0"
assert_contains "$OUT" "changeRequests/7/diffs/patches" "行内开启：先查 MR 版本列表"
# 票 17-fix3 ⑥ 起是两次：Kiro 之前预采样一次（提前发现滞后/配置错），发布前再采样一次（两次比对证明成因）
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "2" "行内开启：版本列表查两次（Kiro 之前预采样 + 发布前采样）"
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
run_inline_case dedup ifx-dedup
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
run_inline_case dedupp0 ifx-dedup-p0
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "去重：同一处已有一条 P0 → 三条（P0/P0/P1）全部跳过"
assert_contains "$OUT" "已存在跳过 3 条" "去重：日志计数 3"
assert_contains "$(posted_comment "$OUT")" "其中 3 条已标注在「文件改动」对应行" "去重：3 条问题并到同一条已有评论上，计数按问题算"

# ---- 票 11：加粗首行 + 旧格式标记的旧评论 ----
# 脚本自己没发过这种形态（sev 进标记的 e534631 早于加粗首行的 5a1a9e3），会落到它的是被人改过首行的旧评论。
# 级别只能从首行解析；解析正则若仍只认 `### `，级别就成了 null → 不能压制 → 同一处每次重跑都多三条重复。
# 用 **P0**：解析对了 → 三条全压（去重生效，0 条新发）；解析成 null → 三条重复发出。
# （用 P2 的话两种结果都是「三条照发」，测不出正则；旧 P2 压不住新 P0 这条由单测与级别未知用例覆盖。）
IFX_DIR="$tmp/ifx-dedup-bold"; mkdir -p "$IFX_DIR"
jq -n --arg fp "$fp_dup" --arg bot "$BOT" '[
  {comment_biz_id:"old-bold-p0", comment_type:"INLINE_COMMENT", state:"OPENED", draft:false,
   filePath:"src/app.py", line_number:2, author:{username:$bot},
   content:("**P0 · 上一次的结论**\n<!-- kiro-inline:" + $fp + " -->\n\n上一次发的。\n")}
]' > "$IFX_DIR/list-comments-inline.json"
run_inline_case dedupbold ifx-dedup-bold
assert_rc "$RC" 0 "票 11 加粗旧评论：退出码 0"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "票 11 加粗旧评论：旧 P0 的级别从「**P0 · 」解析得出，同一处 P0/P0/P1 三条全压（去重生效）"
assert_contains "$OUT" "已存在跳过 3 条" "票 11 加粗旧评论：三条都记为已存在"
assert_contains "$(posted_comment "$OUT")" "其中 3 条已标注在「文件改动」对应行" "票 11 加粗旧评论：汇总计数照旧"
# 首行被人改掉、级别解析不出：按「最严」处理 = 不能压制任何级别
IFX_DIR="$tmp/ifx-dedup-nosev"; mkdir -p "$IFX_DIR"
jq 'map(.content |= sub("\\*\\*P0 · 上一次的结论\\*\\*"; "上一次（标题被人改过）"))' "$tmp/ifx-dedup-bold/list-comments-inline.json" > "$IFX_DIR/list-comments-inline.json"
run_inline_case dedupnosev ifx-dedup-nosev
assert_rc "$RC" 0 "票 11 级别未知：退出码 0"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "票 11 级别未知：解析不出级别的旧评论不压任何一条（宁可重复，不能吞掉 P0）"
assert_contains "$OUT" "已存在跳过 0 条" "票 11 级别未知：没有一条被压"

# ---- 真实验收暴露的缺陷（2026-09-03，demo-app MR #2 重跑 4 → 9）----
# fixture = 真实回读的第一次运行的 4 条行内评论（旧格式标记）；契约 = 第二次运行的形态：
# 标题全变、行号漂移 1 行（20→21、37→36）、一条问题拆成两条（L14 与 L22）。期望：0 条新建、跳过 5 条。
REAL_LIST="$ROOT/tests/fixtures/inline/real-rerun/list-comments-inline.json"
REAL_CONTRACT="$ROOT/tests/fixtures/contract/inline-rerun-real.json"
# 业务库里得有 app/download.py 且这些行都是本次新增的（新文件 → 全部行可定位）
# 由 CASE_EXTRA_TWEAK 在 mk_patchsets **之前**改业务库不行——它要先提交（HEAD 变了），
# 版本列表才写得出真实 HEAD。所以这里自己提交完再调 mk_patchsets（它会顺带把草稿 fixture 补齐）。
mk_real_repo() {
  mkdir -p app
  for i in $(seq 1 50); do echo "line_${i} = ${i}"; done > app/download.py
  git add app/download.py && git commit -qm "add download endpoint"
  mk_patchsets
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
run_inline_case rerun ifx-rerun
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
run_inline_case otherbotdup ifx-otherbot
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" \
  "去重：带指纹的评论是别人发的 → 不算已发出（否则任何人都能压掉一条 P0）"

# ---- 未配置机器人账号：去重退化为只按标记，必须留痕提示 ----
IFX_DIR="$tmp/ifx-noid"; mkdir -p "$IFX_DIR"
run_inline_case inlinenoid ifx-noid CODEUP_BOT_USERNAME=
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
run_inline_case nopatchsets ifx-nops DRY_RUN_FAIL_ROUTES="list-patchsets:403"
assert_rc "$RC" 0 "版本列表失败：评审仍成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "版本列表失败：一条行内评论都不发（不拿猜的版本去挂行）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "行内评论未发出" "版本列表失败：汇总里说明原因（I10 失败可见）"
assert_contains "$comment" "## 问题清单" "版本列表失败：回落成完整展开的问题清单"
assert_contains "$comment" "硬编码疑似应用密钥" "版本列表失败：问题明细仍在汇总里"
assert_not_contains "$comment" "已标注在" "版本列表失败：不谎报行内计数"

# ---- 版本列表里选不出版本对（只有合并源版本）----
PS_TGT=NONE run_inline_case nopair ifx-nopair
assert_rc "$RC" 0 "选不出版本对：评审仍成功"
assert_contains "$OUT" "MERGE_TARGET" "选不出版本对：日志点名缺哪一侧"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "选不出版本对：不发行内评论"
assert_contains "$(posted_comment "$OUT")" "## 问题清单" "选不出版本对：回落成完整清单"

# ---- A11（票 17 → 17-fix2 B③）：最新合并源版本的提交解析不出 ⇒ 评审期间有新推送 → fail-closed ----
# 行号是按本次评审的提交算的，绑到另一个版本上同一行号可能是完全不同的代码（I5，ADR-0005）。
# 这个 commitId 在克隆里找不到 ⇒ 它是本次 checkout 之后推上去的 ⇒ 成因是新推送，**会自愈**（那次推送
# 自己会触发新一轮评审），所以文案就直说新推送。滞后与历史改写各有自己的用例，见下。
# from 用默认的真实 merge-base：只让 to 异常，隔离成因（from≠BASE 是另一条分支，见下面 R8）
PS_SRC=RAW:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef PS_SRC_ID=src-9 run_inline_case shamismatch ifx-shamismatch
assert_rc "$RC" 0 "A11 新推送：评审仍成功（退出码 0）"
assert_contains "$OUT" "不在本地克隆里" "A11 新推送：日志点明成因是提交不在克隆里"
assert_contains "$OUT" "fail-closed" "A11 新推送：日志点明是 fail-closed，不是发了再提醒"
# 预采样就判定绑不上（这个 fixture 从头到尾都是那个不在克隆里的提交），发布前不再重查 ⇒ 只有预采样那一次
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "1" "A11 新推送：预采样已判定，发布前不再查版本列表"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "A11 新推送：0 次创建行内评论（不拿旧 HEAD 的行号去绑新版本）"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "A11 新推送：POST …/comments 只有汇总评论那一次，没有草稿"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "0" "A11 新推送：不调提交接口"
assert_eq "$(req_count "$OUT" DELETE)" "0" "A11 新推送：没有任何删除请求（没建草稿，也不清理孤儿）"
# 判定在草稿创建之前——也在拉现有行内评论（第 5 步）之前：除了查版本列表，一个副作用都没有
assert_eq "$(printf '%s\n' "$OUT" | grep -cF 'DRY_RUN body: {"comment_type":"INLINE_COMMENT"}')" "0" "A11 新推送：连现有行内评论都不查"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "行内评论未发出：评审期间源分支有新推送（Codeup 侧最新合并源版本是 deadbeefdead，本次评审的是 $(cd "$CASE/work" && git rev-parse HEAD | cut -c1-12)），下面是完整问题清单；新推送触发的评审会补上行内评论。" \
  "A11 新推送：notice 点名成因与两个 12 位提交号，并给出会自愈的处置"
assert_not_contains "$comment" "重跑流水线即可" "A11 新推送：不给「重跑流水线」这条相反的建议（那是滞后的处置）"
assert_not_contains "$comment" "滞后" "A11 新推送：不把成因说成版本列表滞后"
assert_contains "$comment" "## 问题清单" "A11 新推送：回落成完整展开的问题清单（INLINE_COMMENT=0 形态）"
assert_eq "$(printf '%s\n' "$comment" | grep -c '行内评论未发出')" "1" "A11 新推送：汇总里只有一句成因（票 17-fix3 ⑬：漏一处 return 就会变成两句）"
assert_contains "$comment" "硬编码疑似应用密钥" "A11 新推送：问题明细仍在汇总里（信息不丢，I10）"
assert_contains "$comment" "仓库级问题：没有统一的密钥管理" "A11 新推送：未定位问题也在完整清单里"
assert_not_contains "$comment" "已标注在" "A11 新推送：不谎报行内计数（INLINE_ACTIVE 仍为 0）"
assert_not_contains "$comment" "行号可能有偏移" "A11 新推送：不再有「行号可能有偏移」这种发了再提醒的文案"
# 按结构判（契约 fixture 的 G5 正文里本来就有「折叠区」二字，完整清单会把它展开出来）
assert_not_contains "$comment" "<details><summary>折叠区" "A11 新推送：没有折叠区（完整清单形态）"
# 正控：to = HEAD（mk_patchsets 默认写的就是真实 HEAD）→ 行内照发。成功路径 ok1 已断言 3 条，这里并排再钉一次
run_inline_case a11control ifx-a11control
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "A11 正控：to = HEAD 时行内照发 3 条"
assert_not_contains "$OUT" "fail-closed" "A11 正控：日志没有 fail-closed"
assert_not_contains "$(posted_comment "$OUT")" "行内评论未发出" "A11 正控：没有 fail-closed 的 notice"

# ---- A11 复审补充：两个核对同时不成立（to≠HEAD 且 from≠BASE）----
# from 侧那条警告是「P1-14 的结论失效了」的探针，必须先于 fail-closed 落进日志：否则最需要它的那种运行
# （目标语义变了、同一个 MR 又在评审期间被推送）反而没有它，运维只会看到「推送太频繁」。
# 汇总里仍然只写 fail-closed 的成因：一条行内评论都没发，「行内评论的行号可能有偏移」会让读者去找不存在的东西。
PS_SRC=RAW:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef PS_SRC_ID=src-9 \
  PS_TGT=RAW:feedfacefeedfacefeedfacefeedfacefeedface PS_TGT_ID=tgt-9 \
  run_inline_case bothmismatch ifx-bothmismatch
assert_rc "$RC" 0 "A11 两者都不一致：评审仍成功"
assert_contains "$OUT" "不等于本地 merge-base" "A11 两者都不一致：from 侧探针警告仍在日志里（不被 fail-closed 吞掉）"
assert_contains "$OUT" "不在本地克隆里" "A11 两者都不一致：to 侧警告也在"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "A11 两者都不一致：仍然 0 次创建行内评论"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "评审期间源分支有新推送（Codeup 侧最新合并源版本是 deadbeefdead" "A11 两者都不一致：汇总写 fail-closed 的成因"
assert_not_contains "$comment" "行号可能有偏移" "A11 两者都不一致：汇总不提行号偏移（一条行内评论都没发）"
assert_contains "$comment" "## 问题清单" "A11 两者都不一致：回落成完整清单"

# ---- A11（17-fix）：版本列表没给出最新合并源版本的提交号 → 同样 fail-closed ----
# `codeup_select_patchset_pair` 把缺失/非字符串的 commitId 映射成空串（tests/test-codeup-api.sh 钉住），
# 票 17 原实现在这里 fail-open：拿不到提交号照样发，等于放弃了「行内评论绑定它所评审的提交」这条证明（I5）。
# 协调者复审改判：绑不上就不发，notice 单列这个成因（读者要能区分「对不上」与「没给」）。
PS_SRC=OMIT PS_SRC_ID=src-9 run_inline_case nocommitid ifx-nocommitid
assert_rc "$RC" 0 "A11 缺 commitId：评审仍成功（退出码 0）"
assert_contains "$OUT" "最新合并源版本（src-9）没有可用的提交号" "A11 缺 commitId：日志在「没有可用的提交号」那一行点名是哪个版本缺"
assert_contains "$OUT" "fail-closed" "A11 缺 commitId：日志点明是 fail-closed"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "A11 缺 commitId：0 次创建行内评论（绑不上就不发）"
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "1" "A11 缺 commitId：只有预采样那一次（不重查——没有提交号不是滞后）"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "1" "A11 缺 commitId：POST …/comments 只有汇总评论那一次，没有草稿"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "0" "A11 缺 commitId：不调提交接口"
assert_eq "$(req_count "$OUT" DELETE)" "0" "A11 缺 commitId：没有任何删除请求"
assert_eq "$(printf '%s\n' "$OUT" | grep -cF 'DRY_RUN body: {"comment_type":"INLINE_COMMENT"}')" "0" "A11 缺 commitId：连现有行内评论都不查"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "行内评论未发出：Codeup 版本列表未给出该版本（src-9）的提交号，无法确认行内评论会绑到本次评审的提交上，下面是完整问题清单。" \
  "A11 缺 commitId：notice 单列这个成因并带上版本号"
assert_not_contains "$comment" "与 Codeup 侧最新合并源版本" "A11 缺 commitId：不谎称「对不上」（没给号 ≠ 号不同）"
assert_contains "$comment" "## 问题清单" "A11 缺 commitId：回落成完整清单"
assert_contains "$comment" "硬编码疑似应用密钥" "A11 缺 commitId：问题明细仍在汇总里（I10）"
assert_not_contains "$comment" "已标注在" "A11 缺 commitId：不谎报行内计数"

# ---- A11（17-fix2 B③）：提交号规范化——12 位缩写与大写都算「就是本次评审的提交」，照发 ----
# 证据分级（票 17-fix3 ⑧）：**真实 API 只观察到 40 位全 sha**（acceptance 留档），没有观察到 Codeup 返回缩写。
# 规范化是对**未观察到的形态**保守——万一哪天返回缩写或大写，字面相等会把它误判成「不一致」，
# 而 fail-closed 之后每轮都发不出行内评论。下面两条用例是 fixture/unit 级的形状覆盖，不是真实 API 的证据。
PS_SRC=HEAD12 run_inline_case shortsha ifx-shortsha
assert_rc "$RC" 0 "缩写 sha：评审成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "缩写 sha：规范化后等于 HEAD，行内照发 3 条"
assert_not_contains "$OUT" "fail-closed" "缩写 sha：不该 fail-closed"
assert_not_contains "$(posted_comment "$OUT")" "行内评论未发出" "缩写 sha：汇总里没有 fail-closed 的 notice"
PS_SRC=HEADUP run_inline_case uppersha ifx-uppersha
assert_rc "$RC" 0 "大写 sha：评审成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "大写 sha：大小写不影响规范化，行内照发 3 条"
assert_not_contains "$OUT" "fail-closed" "大写 sha：不该 fail-closed"

# ---- A11（17-fix2 B③）：提交号只有空白 → 走「没给出提交号」那条分支，不渲染空括号 ----
PS_SRC="RAW:   " PS_SRC_ID=src-9 run_inline_case blanksha ifx-blanksha
assert_rc "$RC" 0 "空白 commitId：评审成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "空白 commitId：0 次创建行内评论"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "未给出该版本（src-9）的提交号" "空白 commitId：按「没给出提交号」处置"
assert_not_contains "$comment" "（）" "空白 commitId：评论里不出现空括号"
# 更贴的一条：de03e59 会把空白串塞进「…最新合并源版本（<空白>）…」，括号里只有空格
assert_not_contains "$comment" "最新合并源版本（ " "空白 commitId：括号里不是一串空格（不走「不一致」那条分支）"
assert_not_contains "$comment" "有新推送" "空白 commitId：不谎称新推送"

# ---- A11（17-fix2 B③）：最新合并源版本是 HEAD 的祖先 ⇒ 版本列表滞后 → 有界重查后 fail-closed ----
# 与新推送相反：这一种**不会自愈**（没有下一次推送来触发新评审），处置是「重跑流水线」。
# 重查用同一个 GET，所以请求数 = 1 + 3；CODEUP_RETRY_BACKOFF=0 让三次退避不真的睡。
PS_SRC=PARENT PS_SRC_ID=src-9 run_inline_case lagging ifx-lagging CODEUP_RETRY_BACKOFF=0
assert_rc "$RC" 0 "版本列表滞后：评审成功"
assert_contains "$OUT" "是当前 HEAD" "版本列表滞后：日志点明那个版本是 HEAD 的祖先"
# 数字来自脚本里的 INLINE_LAG_MAX / INLINE_LAG_BUDGET（票 17-fix3 ⑯：测试也不硬写，只钉住「写明了上限」）
assert_contains "$OUT" "按退避重查（至多 3 次，总等待不超过 45 秒" "版本列表滞后：日志写明重查上限与总等待预算"
# 重查已经挪到预采样里（票 17-fix3 ⑥）：预采样 1 次 + 三次重查 = 4 次，发布前不再查
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "4" "版本列表滞后：预采样 1 次 + 三次重查 = 4 次 GET"
assert_contains "$OUT" "重查第 3/3 次" "版本列表滞后：三次都跑到了"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "版本列表滞后：重查仍滞后 → 0 次创建行内评论"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "Codeup 版本列表尚未包含本次提交" "版本列表滞后：notice 点名成因"
assert_contains "$comment" "重跑流水线即可" "版本列表滞后：给出正确的处置（不是「等下一轮」）"
assert_not_contains "$comment" "有新推送" "版本列表滞后：不谎称新推送（那条建议是等下一轮，等不到）"
assert_contains "$comment" "## 问题清单" "版本列表滞后：回落成完整清单"

# ---- A11（17-fix2 B③）：滞后但重查命中 → 用新版本正常发 ----
# 第二次 GET 起 fixture 换成「to = 真实 HEAD、版本号更大」的列表：模拟 Codeup 在几秒内把版本建出来了。
# 第 1 次 GET 用 `.1.json`（滞后：to 是 HEAD^），之后每一次都落到无序号的那份（已包含本次提交）：
# 预采样重查命中之后，发布前还会再采样一次，那一次也必须拿到新版本（票 17-fix3 ⑥）。
mk_lag_then_ok() {
  local head base
  head=$(git rev-parse HEAD); base=$(git merge-base origin/main HEAD)
  jq -n --arg sha "$(git rev-parse 'HEAD^')" --arg base "$base" '[
    {patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:$base},
    {patchSetBizId:"src-9", versionNo:9, relatedMergeItemType:"MERGE_SOURCE", commitId:$sha}
  ]' > "$IFX_DIR/list-patchsets.1.json"
  jq -n --arg sha "$head" --arg base "$base" '[
    {patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:$base},
    {patchSetBizId:"src-10", versionNo:10, relatedMergeItemType:"MERGE_SOURCE", commitId:$sha}
  ]' > "$IFX_DIR/list-patchsets.json"
}
# CASE_EXTRA_TWEAK 在 mk_patchsets 之后执行，所以上面写的两份 fixture 会覆盖它生成的那份
CASE_EXTRA_TWEAK=mk_lag_then_ok run_inline_case lagrecovered ifx-lagrecovered CODEUP_RETRY_BACKOFF=0
assert_rc "$RC" 0 "滞后后命中：评审成功"
assert_contains "$OUT" "重查命中" "滞后后命中：日志写明命中"
# 预采样 1 次（滞后）+ 第一次重查命中 = 2 次，随后发布前再采样一次 = 3 次
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "3" "滞后后命中：预采样 + 一次重查命中 + 发布前采样 = 3 次 GET"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "滞后后命中：行内照发 3 条"
assert_eq "$(inline_bodies "$OUT" | jq -r '.to_patchset_biz_id' | sort -u | paste -sd, -)" "src-10" \
  "滞后后命中：patchset_biz_id 换成重查拿到的新版本"
assert_not_contains "$(posted_comment "$OUT")" "行内评论未发出" "滞后后命中：汇总里没有 fail-closed 的 notice"

# ---- A11（17-fix3 ①）：提交号不是 sha 形状 → 按「没有可用的提交号」处置，**绝不**当成已证明的版本 ----
# `git rev-parse --verify "<x>^{commit}"` 接受任意 revision 表达式：不锚形状的话 `HEAD` / `@` / 一个 refname
# 都会解析成克隆里的分支顶端、恰好等于 HEAD，于是「版本已证明」这条结论建立在一个从未核对内容的取值上
# （fail-open）。锚了形状之后它落到 noid：一条行内评论都不发。
for shape in HEAD @ main refs/heads/main; do
  PS_SRC="RAW:$shape" PS_SRC_ID=src-9 run_inline_case "shape-$(printf '%s' "$shape" | tr -c 'A-Za-z0-9' '-')" ifx-shape
  assert_rc "$RC" 0 "形状锚定（${shape}）：评审仍成功"
  assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "形状锚定（${shape}）：0 次创建行内评论（不把 refname 当成已证明的版本）"
  assert_contains "$OUT" "不是 sha 形状" "形状锚定（${shape}）：日志点明形状不对"
  comment=$(posted_comment "$OUT")
  assert_contains "$comment" "未给出该版本（src-9）的提交号" "形状锚定（${shape}）：按「没有提交号」处置"
  assert_not_contains "$comment" "有新推送" "形状锚定（${shape}）：不谎称新推送（那条建议是等下一轮，永远等不到）"
done
# 正控：40 位全 sha 与 12 位缩写仍然照发（上面 shortsha/uppersha 已钉）；7 位以下不认
PS_SRC=HEAD6 PS_SRC_ID=src-9 run_inline_case shape6 ifx-shape6
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "形状锚定：6 位十六进制短于 git 短 sha 下限，不认"

# ---- A11（17-fix3 ⑩）：浅克隆里解析不出的提交 → 不能断言「新推送」----
# 这一条走**函数级**而不是端到端：把 fixture 仓库削成浅克隆会同时打断脚本自己的 diff 基准
# （`merge-base origin/<目标分支>`），那时评审在第 4 步就失败了，测不到版本核对。
# 所以直接抽出两个纯函数，在一个专门造的浅克隆里跑。
sh_dir="$tmp/shallow-src"; sh_clone="$tmp/shallow-clone"
git init -q "$sh_dir"
( cd "$sh_dir" && git config user.email t@t && git config user.name t \
  && echo one > f && git add f && git commit -qm one \
  && echo two >> f && git commit -qam two \
  && echo three >> f && git commit -qam three )
old_sha=$( cd "$sh_dir" && git rev-parse 'HEAD~2' )
# 从**非裸**仓库浅克隆（depth=1）：`HEAD~2` 于是落在 graft 边界之下、在克隆里解析不出
git clone -q --depth=1 "file://$sh_dir" "$sh_clone"
# 抽出待测函数（整脚本 source 会执行主流程），并给它一个空的 log 与一个必然失败的 fetch
sed -n '/^inline_resolve_commit() {/,/^}/p;/^inline_classify_to() {/,/^}/p' "$ROOT/scripts/kiro-review.sh" > "$tmp/cls.sh"
sh_status=$( cd "$sh_clone" \
  && git remote set-url origin "file://$tmp/no-such-remote.git" \
  && log() { :; } \
  && source "$tmp/cls.sh" \
  && inline_classify_to "$old_sha" "$(git rev-parse HEAD)" \
  && printf '%s' "$INLINE_TO_STATUS" )
assert_eq "$(cd "$sh_clone" && git rev-parse --is-shallow-repository)" "true" "浅克隆前置：克隆确实是浅的"
assert_eq "$sh_status" "unknown_shallow" \
  "17-fix3 ⑩：浅克隆里解析不出、加深又失败 → 判定 unknown_shallow（不是 pushed_dark「新推送、会自愈」）"
# 正控：同一个提交在**非浅**克隆里解析得出 → 它是 HEAD 的祖先，判定滞后而不是新推送
git clone -q "file://$sh_dir" "$tmp/deep-clone"
deep_status=$( cd "$tmp/deep-clone" && log() { :; } && source "$tmp/cls.sh" \
  && inline_classify_to "$old_sha" "$(git rev-parse HEAD)" && printf '%s' "$INLINE_TO_STATUS" )
assert_eq "$deep_status" "lag" "17-fix3 ⑩ 正控：非浅克隆里同一个提交解析得出、是 HEAD 的祖先 → lag"

# ---- A11（17-fix3 ③）：最新合并源版本是 HEAD 的**后代** ⇒ 评审期间有新推送（对象已在克隆里）----
# 浅克隆下这个提交拉不到（判定 pushed_dark），fetch 过之后它在本地（判定 pushed_known）——同一个事件，
# 处置与文案必须一致，不能一个说新推送、另一个说 force-push。
PS_SRC=CHILD PS_SRC_ID=src-9 run_inline_case descendant ifx-descendant
assert_rc "$RC" 0 "后代版本：评审仍成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "后代版本：0 次创建行内评论"
assert_contains "$OUT" "是当前 HEAD" "后代版本：日志点明拓扑关系"
assert_contains "$OUT" "的后代（对象已在克隆里）" "后代版本：日志说明对象在本地"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "评审期间源分支有新推送" "后代版本：与 pushed_dark 同一套文案（同因同断）"
assert_contains "$comment" "新推送触发的评审会补上行内评论" "后代版本：给出会自愈的处置"
assert_not_contains "$comment" "不在同一条历史上" "后代版本：不谎称 force-push"
assert_not_contains "$comment" "重跑流水线即可" "后代版本：不给滞后那条处置"

# ---- A11（17-fix3 ④）：分叉历史（force-push / rebase 改写）→ fail-closed 且文案单列 ----
# fixture 用 `git commit --amend` 之后的**旧** sha：对象还在克隆里（reflog 可达），但与新 HEAD 分属两条历史。
PS_SRC=ORPHAN PS_SRC_ID=src-9 run_inline_case diverged ifx-diverged
assert_rc "$RC" 0 "分叉历史：评审仍成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "分叉历史：0 次创建行内评论"
assert_contains "$OUT" "分属两条历史" "分叉历史：日志点明成因"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "不在同一条历史上（源分支被改写或强推）" "分叉历史：notice 单列这个成因"
assert_not_contains "$comment" "尚未包含本次提交" "分叉历史：不谎称滞后"
assert_contains "$comment" "## 问题清单" "分叉历史：回落成完整清单"

# ---- A11（17-fix3 ②）：滞后重查期间成因变了 → 按**最终**成因给文案，不再一律说「滞后，重跑流水线」----
# 第 1 次 GET 滞后 → 触发重查；之后每次都返回一个不在克隆里的提交（评审期间来了新推送）。
mk_lag_then_push() {
  local base
  base=$(git merge-base origin/main HEAD)
  jq -n --arg sha "$(git rev-parse 'HEAD^')" --arg base "$base" '[
    {patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:$base},
    {patchSetBizId:"src-9", versionNo:9, relatedMergeItemType:"MERGE_SOURCE", commitId:$sha}
  ]' > "$IFX_DIR/list-patchsets.1.json"
  jq -n --arg base "$base" '[
    {patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:$base},
    {patchSetBizId:"src-11", versionNo:11, relatedMergeItemType:"MERGE_SOURCE", commitId:"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}
  ]' > "$IFX_DIR/list-patchsets.json"
}
CASE_EXTRA_TWEAK=mk_lag_then_push run_inline_case lagthenpush ifx-lagthenpush CODEUP_RETRY_BACKOFF=0
assert_rc "$RC" 0 "重查期间来了新推送：评审仍成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "重查期间来了新推送：0 次创建行内评论"
assert_contains "$OUT" "判定：pushed_dark" "重查期间来了新推送：日志记下每次重查的判定"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "评审期间源分支有新推送" "重查期间来了新推送：按最终成因给文案"
assert_not_contains "$comment" "尚未包含本次提交" "重查期间来了新推送：不再一律说滞后"
assert_not_contains "$comment" "重跑流水线即可" "重查期间来了新推送：不给「重跑」这条只会复现的建议"

# ---- A11（17-fix3 ⑮）：滞后重查期间接口一直失败 → 用「查询版本列表失败」那条 notice，不谎称滞后 ----
# 按调用序号注入（DRY_RUN_FAIL_ROUTES 的 `@N+`）：第 1 次（预采样）成功、第 2 次（发布前采样）拿到旧版本
# 触发重查、第 3 次起全部 403。这正是第 ② 条最坏的实例：403 被说成「滞后，重跑流水线即可」。
mk_lag_then_403() {
  jq -n --arg sha "$(git rev-parse HEAD)" --arg base "$(git merge-base origin/main HEAD)" '[
    {patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:$base},
    {patchSetBizId:"src-2", versionNo:9, relatedMergeItemType:"MERGE_SOURCE", commitId:$sha}
  ]' > "$IFX_DIR/list-patchsets.1.json"
}
PS_SRC=PARENT PS_SRC_ID=src-9 CASE_EXTRA_TWEAK=mk_lag_then_403 \
  run_inline_case lagthen403 ifx-lagthen403 CODEUP_RETRY_BACKOFF=0 DRY_RUN_FAIL_ROUTES="list-patchsets:403@3+"
assert_rc "$RC" 0 "重查一直 403：评审仍成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "重查一直 403：0 次创建行内评论"
assert_contains "$OUT" "两次采样：checkout 时判定=ok" "重查一直 403：两次采样比对写进日志"
assert_contains "$OUT" "重查 MR 版本列表失败（HTTP 403）" "重查一直 403：每次失败都留痕"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "查询 MR 版本列表失败（HTTP 403）" "重查一直 403：按最终成因（接口失败）给 notice"
assert_not_contains "$comment" "尚未包含本次提交" "重查一直 403：不谎称滞后"
assert_not_contains "$comment" "重跑流水线即可" "重查一直 403：不给「重跑」这条只会复现的建议"
assert_eq "$(printf '%s\n' "$comment" | grep -c '行内评论未发出')" "1" "重查一直 403：汇总里只有一句成因（票 17-fix3 ⑬）"

# ---- A11（17-fix3 ②）：滞后重查期间接口失败 / 选不出版本对 → 各自既有的 notice ----
mk_lag_then_500() {
  local base
  base=$(git merge-base origin/main HEAD)
  jq -n --arg sha "$(git rev-parse 'HEAD^')" --arg base "$base" '[
    {patchSetBizId:"tgt-1", versionNo:1, relatedMergeItemType:"MERGE_TARGET", commitId:$base},
    {patchSetBizId:"src-9", versionNo:9, relatedMergeItemType:"MERGE_SOURCE", commitId:$sha}
  ]' > "$IFX_DIR/list-patchsets.1.json"
  jq -n '[]' > "$IFX_DIR/list-patchsets.json"   # 之后每次都返回空数组 → 选不出版本对
}
CASE_EXTRA_TWEAK=mk_lag_then_500 run_inline_case lagthennopair ifx-lagthennopair CODEUP_RETRY_BACKOFF=0
assert_rc "$RC" 0 "重查后选不出版本对：评审仍成功"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "重查后选不出版本对：0 次创建行内评论"
assert_contains "$OUT" "重查后仍选不出版本对" "重查后选不出版本对：日志留痕"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "选不出「最新合并目标版本 + 最新合并源版本」这一对" "重查后选不出版本对：用这条既有 notice"
assert_not_contains "$comment" "重跑流水线即可" "重查后选不出版本对：不谎称滞后"

# ---- A11（17-fix2 B③）：最新合并目标版本没有提交号 → 只打警告（P1-14 探针失效），照发 ----
PS_TGT=OMIT run_inline_case fromnoid ifx-fromnoid
assert_rc "$RC" 0 "from 缺 commitId：评审成功"
assert_contains "$OUT" "P1-14 的探针" "from 缺 commitId：日志写明探针本次失效"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "from 缺 commitId：不影响发布，行内照发 3 条"
assert_not_contains "$(posted_comment "$OUT")" "行内评论未发出" "from 缺 commitId：不 fail-closed"
assert_not_contains "$(posted_comment "$OUT")" "行号可能有偏移" "from 缺 commitId：没有提交号就不谈偏移（无从比较）"
# ---- A11（17-fix3 ⑤）：最新合并目标版本的提交号只有空白 → 与 to 侧同样先去空白，不渲染空括号 ----
PS_TGT="RAW:   " PS_TGT_ID=tgt-9 run_inline_case fromblank ifx-fromblank
assert_rc "$RC" 0 "from 空白 commitId：评审成功"
assert_contains "$OUT" "P1-14 的探针" "from 空白 commitId：按「没有提交号」处置（探针失效）"
assert_not_contains "$OUT" "不等于本地 merge-base" "from 空白 commitId：不落到「基准不一致」那条分支"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "from 空白 commitId：不影响发布，行内照发 3 条"
comment=$(posted_comment "$OUT")
assert_not_contains "$comment" "行号可能有偏移" "from 空白 commitId：汇总里不谈偏移（无从比较）"
assert_not_contains "$comment" "合并目标版本 ）" "from 空白 commitId：评论里不出现空括号"

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
# 预采样在 Kiro 之前，所以降级路径也会有那一次（它的作用正是「不用等模型跑完才知道版本对能不能用」）；
# 发布路径本身不会再查——降级不进行内发布。
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "1" "降级 + 行内开启：只有 Kiro 之前那次预采样"

# ---- 无问题：不发行内评论，汇总仍完整 ----
printf '{"contract":"codeup-reviewer/1","summary":"没有发现问题。","verdict":"MERGE","verdict_reason":"改动很小。","findings":[]}\n' > "$tmp/empty-contract.json"
run_inline_case inlineempty ifx-inlineempty MOCK_KIRO_CONTRACT="$tmp/empty-contract.json"
assert_rc "$RC" 0 "无问题 + 行内开启：退出码 0"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "0" "无问题 + 行内开启：不发行内评论"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/review$')" "0" "无问题 + 行内开启：不调提交接口"
# 没有可发的行内评论时连版本列表与现有评论列表都不该查：白跑两个接口，还可能在一条
# 「未发现明显问题」的汇总上挂一句「下面是完整问题清单」
assert_eq "$(req_count "$OUT" GET 'diffs/patches$')" "1" "无问题 + 行内开启：只有 Kiro 之前那次预采样（发布路径提前返回，不再查）"
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
run_inline_case outdated ifx-outdated
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

# ---- 票 14：模型文本里的原始 HTML 与间隔分隔线进不了汇总评论（Codeup 会渲染原始 HTML）----
run_case htmlinject MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/inject.json"
assert_rc "$RC" 0 "HTML 注入：退出码 0"
comment=$(posted_comment "$OUT")
assert_not_contains "$comment" '<div style="display:none">' "HTML 注入：不闭合的 display:none 不进评论（否则吞掉其后整份报告）"
assert_contains "$comment" '&lt;div style="display:none">' "HTML 注入：转义后仍可读出模型引用了什么"
assert_not_contains "$comment" "<h1>结论：可合并</h1>" "HTML 注入：<h1> 不进评论（否则伪造出与脚本同级的标题）"
assert_contains "$comment" "&lt;h1>结论：可合并&lt;/h1>" "HTML 注入：<h1> 被转义"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^\\- - -$')" "1" "HTML 注入：间隔分隔线被转义（\\- - -）"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^\\=$')" "1" "HTML 注入：单个 = 的 setext 下划线被转义"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^<details')" "1" "HTML 注入：行首 <details> 仍只有脚本的历次评审那一个"

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
run_inline_case orphan ifx-orphan
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
run_inline_case stilldraft ifx-stilldraft
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

# ---- R8：Codeup 侧的比较基准与本地 merge-base 不一致 → 警告 + 汇总里说明，**照发**（票 17 裁决：from≠BASE 不 fail-closed）----
# 与 A11 相反：line_number 是新文件侧行号（P1-02 实测），比较基准不同不改变行号；P1-14 又证明 MERGE_TARGET
# 冻结在建 MR 时的 merge-base。所以这条只是留痕，不拒发。
# MERGE_TARGET 的 commitId 是目标分支顶端（不是 merge-base）——目标分支在 MR 分出后前进过
PS_TGT=RAW:feedfacefeedfacefeedfacefeedfacefeedface PS_TGT_ID=tgt-9 run_inline_case basemismatch ifx-basemismatch
assert_rc "$RC" 0 "R8 基准不一致：评审仍成功"
assert_contains "$OUT" "不等于本地 merge-base" "R8 基准不一致：日志告警"
assert_contains "$OUT" "P1-14" "R8 基准不一致：日志引用 P1-14 的结论（不 fail-closed 的依据）"
assert_not_contains "$OUT" "待探测" "R8 基准不一致：P1-14 已探完，日志不再写成待探测项"
assert_not_contains "$OUT" "fail-closed" "R8 基准不一致：这条分支不 fail-closed"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "3" "R8 基准不一致：仍以 API 给的版本发出（新文件侧行号不受基准影响）"
assert_eq "$(inline_bodies "$OUT" | jq -r '.from_patchset_biz_id' | sort -u | paste -sd, -)" "tgt-9" "R8 基准不一致：from 仍用 API 的版本"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "行内评论的行号可能有偏移" "R8 基准不一致：汇总评论里说明不确定性（I10）"
assert_contains "$comment" "其中 3 条已标注在「文件改动」对应行" "R8 基准不一致：不影响行内计数"

# ---- 行内评论不影响汇总评论的原地更新（票 03 的不变量在开关打开后仍成立）----
IFX_DIR="$tmp/ifx-update"; mkdir -p "$IFX_DIR"
cp "$CFX/prior-run1/list-comments.json" "$IFX_DIR/list-comments.json"
run_inline_case inlineupdate ifx-update
assert_rc "$RC" 0 "行内 + 原地更新：退出码 0"
assert_eq "$(req_count "$OUT" PUT 'comments/b1f0e9d8c7b6a5948372615049382716$')" "1" "行内 + 原地更新：汇总仍原地更新同一条"
assert_eq "$(req_count "$OUT" POST 'changeRequests/7/comments$')" "3" "行内 + 原地更新：POST …/comments 只有三条行内评论，没有新建第二条汇总"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "run:2 -->" "行内 + 原地更新：run 递增"
assert_contains "$comment" "<details><summary>历次评审（2）</summary>" "行内 + 原地更新：历次表两行"

# ============================================================================
# 票 05 复审修复
# ============================================================================
# ============ 票 13 ④ ============
# ---- 失败评论的 reason 里带分支名：`<summary>` 是合法 ref 字符，fetch 失败时它随 reason 进评论正文 ----
# 票 14 让 review_sanitize_md 转义所有像标签的 `<`，这里是那条链路在真实失败路径上的负向用例：
# 目标分支名 `feat/a<summary>b` 在 fixture 里不存在 → fetch 失败 → die_review → 失败评论。
run_case fetchfail MR_TARGET_BRANCH='feat/a<summary>b'
assert_nonzero "$RC" "票 13 ④：fetch 失败 → 非零退出"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "无法 fetch 目标分支" "票 13 ④：失败评论说明是 fetch 失败"
# 只查载荷本身：失败评论自己的历次表就是 `<details><summary>`，不能查裸 `<summary`
assert_not_contains "$comment" "a<summary>b" "票 13 ④：分支名里的 <summary> 不以原始 HTML 进入失败评论正文"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^<details><summary>历次评审')" "1" "票 13 ④：评论里的 <summary> 只有脚本自己的历次表那一个"
assert_contains "$comment" "feat/a&lt;summary>b" "票 13 ④：reason 里的分支名转义后仍可读"
assert_not_contains "$(meta_row "$comment")" "<" "票 13 ④：元信息单元格里的分支名照旧剔掉 <"
# 正控：普通的不存在分支名原样出现在 reason 里
run_case fetchfail2 MR_TARGET_BRANCH='no-such-branch'
assert_contains "$(posted_comment "$OUT")" "无法 fetch 目标分支：no-such-branch" "票 13 ④ 正控：普通分支名原样进 reason（分支名作不受信取值走 die_review 的第二个参数，自审 finding）"

# ============ 票 12 ============
# ---- ⑤ 超限路径的端到端契约——喂给 Kiro 的 stdin 里有索引节，每行一个含 chunk/file 的 JSON ----
# 这是「脚本节标题」与 prompts/review-prompt.md 契约不漂移的唯一守卫：任一侧退回 `- 名字 => 路径` 的分隔文本
# 就是票 06 P0（文件名伪造第二个路径）的复发路径，而此前没有任何测试会因此变红。
IDX_HDR='=== 未直传的变更文件索引'
assert_eq "$(grep -c -F "$IDX_HDR" "$ROOT/prompts/review-prompt.md")" "1" "超限契约：提示词里引用的是同一个节标题"
run_case overlimit DIFF_SIZE_LIMIT=1
assert_rc "$RC" 0 "超限：退出码 0"
stdin_ol=$(cat "$MD/stdin")
assert_eq "$(printf '%s\n' "$stdin_ol" | grep -c -F "$IDX_HDR")" "1" "超限：stdin 里恰好一个索引节标题"
# 索引节 = 标题行之后、下一个空行之前的所有行：每行必须是含 chunk/file/added/removed 的 JSON 对象
idx_lines=$(printf '%s\n' "$stdin_ol" | awk -v h="$IDX_HDR" 'index($0, h) == 1 {on=1; next} on && $0 == "" {exit} on {print}')
n_changed=$(git -C "$CASE/work" diff --no-renames --name-only main HEAD | wc -l | tr -d ' ')
assert_eq "$(printf '%s\n' "$idx_lines" | grep -c .)" "$n_changed" "超限：fixture 的全部变更文件（${n_changed} 个）都在索引里（阈值 1 字节，一个都装不下）"
assert_eq "$(printf '%s\n' "$idx_lines" | jq -r 'type == "object" and has("chunk") and has("file") and (.added|type) == "number" and (.removed|type) == "number"' | sort -u)" "true" \
  "超限：索引每行都是含 chunk/file/added/removed 的 JSON 对象"
assert_eq "$(printf '%s\n' "$idx_lines" | jq -r '.chunk | test("^/.*/[0-9]{4}\\.diff$")' | sort -u)" "true" "超限：chunk 是绝对路径、NNNN.diff 形态"
assert_not_contains "$idx_lines" "=> " '超限：索引里没有旧的 `=> 路径` 分隔文本'
assert_contains "$idx_lines" '"file":"src/app.py"' "超限：file 字段是文件名本身"
assert_eq "$(printf '%s\n' "$idx_lines" | jq -r 'select(.file == "src/app.py") | .added')" "1" "超限：src/app.py 的增行数按 numstat 算（+1 行密钥）"
assert_contains "$stdin_ol" "=== DIFF ===" "超限：DIFF 节仍在（此时为空）"
# 许可路径里的 chunks 目录就是 chunk 真正落盘的目录：Kiro 启动时那个目录里已有 0000.diff（票 15）
allow_chunks_row=$(awk -F'\t' '$1 ~ /\/chunks$/ {print}' "$MD/allowscan")
assert_eq "$(printf '%s\n' "$allow_chunks_row" | grep -cE '(^|,)[0-9]{4}\.diff(,|$)')" "1" \
  "超限：Kiro 启动时许可清单里的 chunks 目录内已有 NNNN.diff chunk 文件（就是 build_review_input 的落盘目录；实际：${allow_chunks_row})"
assert_eq "$(printf '%s\n' "$idx_lines" | jq -r '.chunk | test("/chunks/[0-9]{4}\\.diff$")' | sort -u)" "true" "超限：索引里的 chunk 路径都在 chunks 目录下"
# 索引里的 chunk 目录与 allowedPaths[1] 必须**逐字同一形态**（物理路径）：模型按索引去读，形态不同就落在 allow 之外
# （kiro-cli 会不会先解析符号链接再比对未经实测，P1-15 T1 只按物理路径读过）。要让「逻辑路径 ≠ 物理路径」在任何平台上
# 都成立：macOS 的 mktemp -d 落在 /var/folders（→ /private/var/folders 的符号链接，且它不理 TMPDIR）；Linux 的 /tmp 通常
# 是真目录，所以给一个符号链接 TMPDIR（GNU mktemp 按它创建 $WORK）。断言不写死哪一种：只要求 allowedPaths[1] 已是物理
# 形态、索引里的 chunk 目录与之逐字相同。
mkdir -p "$tmp/tmp-real"; ln -s "$tmp/tmp-real" "$tmp/tmp-link"
run_case overlimit-symtmp DIFF_SIZE_LIMIT=1 TMPDIR="$tmp/tmp-link"
assert_rc "$RC" 0 "超限+符号链接 TMPDIR：退出码 0"
allow_chunks_st=$(jq -r '.toolsSettings.read.allowedPaths[1]' "$CASE/home/.kiro/agents/codeup-reviewer.json")
assert_eq "$([[ "$allow_chunks_st" == /*/chunks ]] && echo y || echo n)" "y" "超限+符号链接 TMPDIR：allowedPaths[1] 是绝对路径下的 chunks（实际：${allow_chunks_st}）"
idx_st=$(awk -v h="$IDX_HDR" 'index($0, h) == 1 {on=1; next} on && $0 == "" {exit} on {print}' "$MD/stdin")
assert_eq "$(printf '%s\n' "$idx_st" | grep -c .)" "$(git -C "$CASE/work" diff --no-renames --name-only main HEAD | wc -l | tr -d ' ')" "超限+符号链接 TMPDIR：索引非空、条数与变更文件数一致"
idx_st_dir=$(printf '%s\n' "$idx_st" | jq -r '.chunk | sub("/[^/]*$"; "")' | sort -u)
assert_eq "$idx_st_dir" "$allow_chunks_st" "超限+符号链接 TMPDIR：索引里每条 chunk 的目录与 allowedPaths[1] 逐字相同"
# 前提自检：allowedPaths[1] 已是物理形态（$WORK 已被 trap 删掉，用其父目录——TMPDIR 或 /var/folders/…/T——的 pwd -P 判）
allow_gp=$(dirname "$(dirname "$allow_chunks_st")")
assert_eq "$allow_gp" "$(cd "$allow_gp" && pwd -P)" "超限+符号链接 TMPDIR：allowedPaths[1] 是物理形态（父目录 pwd -P 与原文一致）"
# chunk 目录在 Kiro 启动时已存在（allowscan 记录的是 chat 时的状态），此刻 $WORK 已被脚本 trap 删掉，
# 物理形态的判据用 allowscan 里的路径与 chunks 目录的父目录 pwd -P 对照：allowscan 每行首列就是 allowedPaths 原文
assert_eq "$(awk -F'\t' '$1 ~ /\/chunks$/ {print $2}' "$MD/allowscan")" "dir" "超限+符号链接 TMPDIR：Kiro 启动时 chunks 许可路径是存在的目录"
assert_contains "$(posted_comment "$OUT")" "已按优先级截断" "超限：汇总评论的 diff 说明写明已截断"
# 正控：阈值足够大时没有索引节
run_case underlimit DIFF_SIZE_LIMIT=1000000
assert_eq "$(grep -c -F "$IDX_HDR" "$MD/stdin")" "0" "未超限：stdin 里没有索引节（正控）"

# ---- KIRO_TIMEOUT / DIFF_SIZE_LIMIT 必须是正整数：非法取值是「静默走偏」，必须硬失败 ----
# KIRO_TIMEOUT=15m → timeout 会以 rc 125 退出，MR 上只剩「Kiro 评审失败（退出码 125）」
run_case badtimeout KIRO_TIMEOUT=15m
assert_rc "$RC" 1 "KIRO_TIMEOUT 非整数：拒绝运行"
assert_contains "$OUT" "KIRO_TIMEOUT=15m 不是纯数字" "KIRO_TIMEOUT 非整数：报错点名变量与取值"
assert_contains "$OUT" "不支持 15m / 300KB 这类带单位的写法" "KIRO_TIMEOUT 非整数：告诉运维正确写法"
assert_eq "$(call_count "$MD/calls" chat)" "0" "KIRO_TIMEOUT 非整数：没白跑 Kiro（不烧额度）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "⚠️ 评审未完成" "KIRO_TIMEOUT 非整数：MR 上看得见（I10）"
assert_contains "$comment" "KIRO_TIMEOUT=15m" "KIRO_TIMEOUT 非整数：失败评论写明原因"
# DIFF_SIZE_LIMIT=300KB → 与字节数比较时按 0 处理：整份 diff 进省略清单，说明还会写成「300KBB」
run_case baddiffsize DIFF_SIZE_LIMIT=300KB
assert_rc "$RC" 1 "DIFF_SIZE_LIMIT 非整数：拒绝运行"
assert_contains "$OUT" "DIFF_SIZE_LIMIT=300KB 不是纯数字" "DIFF_SIZE_LIMIT 非整数：报错点名变量与取值"
assert_eq "$(call_count "$MD/calls" chat)" "0" "DIFF_SIZE_LIMIT 非整数：没白跑 Kiro"
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
assert_eq "$(call_count "$tmp/case-badtimeout/home/.kiro-mock/calls" help)" "0" "取值校验早于 kiro-cli 能力检查（没白跑 --help）"
# 合法取值仍照常工作（正控：上面三条不是靠「任何取值都失败」蒙对的）
run_case goodlimits KIRO_TIMEOUT=60 DIFF_SIZE_LIMIT=1000000
assert_rc "$RC" 0 "合法的秒数/字节数：评审照常成功"

# ---- REVIEW_RERUN_HINT：AWS 档位可把提示语换成评论命令（Flow 默认不承诺它）----
# ============ Kiro 子进程环境许可清单（票 15）：Flow 注入的任何东西都不进 Kiro 进程 ============
# 固定名单内的变量各放一个（区域设置、代理、证书、XDG），名单外放几个像凭证的 canary，以及几个**形状像**名单但不在名单里的
# （KIRO_FOO、LC_TIME、CORP_SECRET_PROXY——15-fix #12：名单是固定名字，不是 KIRO_* / *_PROXY 这类模式）。
run_case envscrub CODEUP_BOT_USERNAME=bot-x FLOW_CANARY_SECRET=s3cr3t AWS_SECRET_ACCESS_KEY=aws GIT_ASKPASS=/askpass \
  LC_ALL=C LC_TIME=C HTTPS_PROXY=http://proxy.example:3128 http_proxy=http://proxy.example:3128 no_proxy=localhost CORP_SECRET_PROXY=s \
  XDG_CACHE_HOME=/tmp/xdg-canary XDG_CONFIG_HOME=/tmp/xdg-cfg SSL_CERT_FILE=/etc/ssl/cert.pem SSL_CERT_DIR=/etc/ssl/certs CURL_CA_BUNDLE=/etc/ssl/cert.pem KIRO_FOO=1
assert_rc "$RC" 0 "环境许可清单：评审正常完成（名单内的变量足够 kiro-cli 启动）"
env_names=$(cat "$MD/env")
for v in CODEUP_BOT_USERNAME FLOW_CANARY_SECRET AWS_SECRET_ACCESS_KEY GIT_ASKPASS YUNXIAO_TOKEN YUNXIAO_ORG_ID CODEUP_REPO_ID KIRO_FOO LC_TIME CORP_SECRET_PROXY; do
  assert_eq "$(printf '%s\n' "$env_names" | grep -c -x -- "$v")" "0" "环境许可清单：Kiro 进程看不到 $v"
done
for v in PATH HOME KIRO_API_KEY KIRO_LOG_NO_COLOR LC_ALL HTTPS_PROXY http_proxy no_proxy XDG_CACHE_HOME XDG_CONFIG_HOME SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE; do
  assert_eq "$(printf '%s\n' "$env_names" | grep -c -x -- "$v")" "1" "环境许可清单：Kiro 进程看得到 $v"
done
# 替身按 --agent 在 $HOME/.kiro/agents 下找定义、找不到就失败：rc 0 已证明 HOME 透传的是安装 agent 的那个 HOME
assert_contains "$(paste -sd' ' "$MD/args")" "--agent codeup-reviewer" "环境许可清单：仍以受信 agent 运行"

# ---- KIRO_ENV_PASSTHROUGH：名单之外要额外透传的变量**名**（逗号分隔；自建执行器的 LD_LIBRARY_PATH / AWS_PROFILE 这类）----
run_case passthrough KIRO_ENV_PASSTHROUGH=" KIRO_FOO,LD_LIBRARY_PATH" KIRO_FOO=1 LD_LIBRARY_PATH=/opt/lib
assert_rc "$RC" 0 "KIRO_ENV_PASSTHROUGH：评审正常完成"
env_names=$(cat "$MD/env")
for v in KIRO_FOO LD_LIBRARY_PATH PATH HOME KIRO_API_KEY; do
  assert_eq "$(printf '%s\n' "$env_names" | grep -c -x -- "$v")" "1" "KIRO_ENV_PASSTHROUGH：点名的 $v 透传了"
done
for v in YUNXIAO_TOKEN CODEUP_REPO_ID KIRO_ENV_PASSTHROUGH; do
  assert_eq "$(printf '%s\n' "$env_names" | grep -c -x -- "$v")" "0" "KIRO_ENV_PASSTHROUGH：没点名的 $v 仍看不到"
done
env_log_line=$(printf '%s\n' "$OUT" | grep -F "Kiro 进程环境许可清单" | head -1)
assert_contains "$env_log_line" "LD_LIBRARY_PATH" "KIRO_ENV_PASSTHROUGH：日志的变量名清单里列出了额外透传的名字"
# 非法名字（写成 NAME=value / 带连字符）→ 拒绝运行并回写失败评论；取值不进评论也不进日志；校验早于 --help、Kiro 未启动
run_case badpass KIRO_ENV_PASSTHROUGH="KIRO_FOO,YUNXIAO_TOKEN=leakedvalue" KIRO_FOO=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "KIRO_ENV_PASSTHROUGH 含 NAME=value：非零退出"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "KIRO_ENV_PASSTHROUGH" "KIRO_ENV_PASSTHROUGH 含 NAME=value：失败评论点名该变量"
assert_contains "$comment" "非法变量名" "KIRO_ENV_PASSTHROUGH 含 NAME=value：失败评论说明原因"
assert_not_contains "$OUT" "leakedvalue" "KIRO_ENV_PASSTHROUGH 含 NAME=value：取值既不进评论也不进日志"
# 15-fix4 #4 补：语法错误分支打完整标识符 + ****（名字带了 = 是手误、不是秘密），只隐藏 = 后面的取值；掩到首段只在凭证形状分支
assert_contains "$comment" "第 2 项 YUNXIAO_TOKEN****" "KIRO_ENV_PASSTHROUGH 含 NAME=value：评论按序号列出完整标识符 + ****"
assert_eq "$(call_count "$MD/calls" help)" "0" "KIRO_ENV_PASSTHROUGH 非法：校验早于 kiro-cli 能力检查（没跑 --help）"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "KIRO_ENV_PASSTHROUGH 非法：Kiro 未被启动"
run_case badpass2 KIRO_ENV_PASSTHROUGH="bad-name"
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "KIRO_ENV_PASSTHROUGH 含连字符名字：非零退出"
assert_contains "$(posted_comment "$OUT")" "KIRO_ENV_PASSTHROUGH" "KIRO_ENV_PASSTHROUGH 含连字符名字：失败评论点名该变量"
# 15-fix2 #17：不含 = 的非法 token 也无条件掩码——原来 `ghp-liveSecret123` 会原样进流水线日志
run_case badpass3 KIRO_ENV_PASSTHROUGH="ghp-liveSecret123"
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "KIRO_ENV_PASSTHROUGH 贴了一个像令牌的非法 token：非零退出"
assert_not_contains "$OUT" "liveSecret" "像令牌的非法 token：原文不进日志也不进评论"
assert_contains "$(posted_comment "$OUT")" "ghp****" "像令牌的非法 token：评论里只有掩码"
# 15-fix3 #6：`ghp_<36 位>` 是**合法标识符**，不带 = 也不带连字符——原来不匹配任何凭证形状、被静默接受并透传；现在按 GHP_* 前缀拒绝并掩码
FAKE_GHP=$(fake_token ghp)   # 片段拼接只在 helpers.sh 的 fake_token 一处（15-fix4 #9）：公开仓库里不留完整的令牌形态字面量
run_case badpass3b KIRO_ENV_PASSTHROUGH="$FAKE_GHP"
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "KIRO_ENV_PASSTHROUGH 贴了一个真形态 ghp_ 令牌：拒绝运行"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "凭证形状" "ghp_ 令牌：按凭证形状拒绝"
assert_contains "$comment" "ghp****" "ghp_ 令牌：评论里只有掩码"
assert_not_contains "$OUT" "ABCDEFGHIJ" "ghp_ 令牌：原文不进日志也不进评论"
# 15-fix2 #13：语法合法但凭证形状的名字（YUNXIAO_* / CODEUP_* / AWS_* / *TOKEN* / *SECRET* / *PASSWORD* / *CREDENTIAL* / *_KEY）→ 拒绝运行；名字掩码进评论
run_case badpass4 KIRO_ENV_PASSTHROUGH="KIRO_FOO,YUNXIAO_TOKEN" KIRO_FOO=1
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "KIRO_ENV_PASSTHROUGH=YUNXIAO_TOKEN：拒绝运行（固定名单刚关掉的洞不能被一个变量名重新打开）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "凭证形状" "KIRO_ENV_PASSTHROUGH=YUNXIAO_TOKEN：失败评论说明原因"
assert_contains "$comment" "YUNXIAO****" "KIRO_ENV_PASSTHROUGH=YUNXIAO_TOKEN：失败评论列出被拒名字的掩码（15-fix3 #6）"
assert_not_contains "$comment" "YUNXIAO_TOKEN" "KIRO_ENV_PASSTHROUGH=YUNXIAO_TOKEN：完整名字不进评论（svc_SECRET_… 这类名字本身就是密钥）"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "KIRO_ENV_PASSTHROUGH=YUNXIAO_TOKEN：Kiro 未被启动"
# 15-fix4 #4：AWS_PROFILE / AWS_REGION / AWS_DEFAULT_REGION 是配置不是凭证，显式放行；AWS_* 其余仍拒
run_case awscfg KIRO_ENV_PASSTHROUGH="AWS_PROFILE,AWS_REGION,AWS_DEFAULT_REGION" AWS_PROFILE=p AWS_REGION=cn-north-1 AWS_DEFAULT_REGION=cn-north-1
assert_rc "$RC" 0 "KIRO_ENV_PASSTHROUGH=AWS_PROFILE,AWS_REGION,AWS_DEFAULT_REGION：放行、评审正常完成"
for v in AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION; do
  assert_eq "$(grep -c -x -- "$v" "$MD/env")" "1" "KIRO_ENV_PASSTHROUGH：$v 透传到 Kiro 进程"
done
# 被拒条目按「第 N 项 掩码（命中 规则）」列出（A8：两个 AWS_* 名字掩码后都是 AWS****，靠序号与规则区分）；流水线日志给完整名字，评论不给
run_case badpass5 KIRO_ENV_PASSTHROUGH="AWS_PROFILE,AWS_ACCESS_KEY_ID,MY_PAT" AWS_PROFILE=p
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "KIRO_ENV_PASSTHROUGH 含 AWS_ACCESS_KEY_ID：拒绝运行"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "第 2 项 AWS****（命中 AWS_*）" "凭证形状：评论按条目序号 + 掩码 + 命中规则列出（第 2 项）"
assert_contains "$comment" "第 3 项 MY****（命中 *_PAT）" "凭证形状：*_PAT 规则命中、序号 3"
assert_not_contains "$comment" "AWS_ACCESS_KEY_ID" "凭证形状：完整名字不进评论"
assert_contains "$OUT" "第 2 项 AWS_ACCESS_KEY_ID（命中 AWS_*）" "凭证形状：流水线日志给完整名字 + 规则（名字是运维自己写的配置）"
assert_not_contains "$comment" "第 1 项" "凭证形状：放行的 AWS_PROFILE 不在被拒条目里"

# ---- 替身通道是 fail-closed（15-fix #14 / 15-fix2 #18 #19）：拿不到 $HOME/.kiro-mock 或加载不了 helpers.sh 的替身以 97 退出并报错 ----
mkdir -p "$tmp/nohome"
rc=0; err=$(cd "$tmp" && env -i PATH="$PATH" HOME="$tmp/nohome" kiro-cli chat --help 2>&1 >/dev/null) || rc=$?
assert_eq "$rc" "97" "替身拿不到 \$HOME/.kiro-mock：以 97 退出"
assert_contains "$err" ".kiro-mock" "替身拿不到配置目录：报错点名"
rc=0; err=$(cd "$tmp" && env -i PATH="$PATH" kiro-cli chat --help 2>&1 >/dev/null) || rc=$?
assert_eq "$rc" "97" "替身没有 HOME：以 97 退出"
mkdir -p "$tmp/okhome/.kiro-mock"
rc=0; help_out=$(env -i PATH="$PATH" HOME="$tmp/okhome" kiro-cli chat --help 2>&1) || rc=$?
assert_rc "$rc" 0 "替身正控：HOME 下有 .kiro-mock 就正常工作"
assert_contains "$help_out" "--agent-engine" "替身正控：--help 输出正常"
# helpers.sh 加载不了（把替身单独拷到没有 ../helpers.sh 的目录）→ 97，而不是故障注入开关静默失效
mkdir -p "$tmp/lonely/mockbin"; cp "$ROOT/tests/mockbin/kiro-cli" "$tmp/lonely/mockbin/kiro-cli"
rc=0; err=$(env -i PATH="$tmp/lonely/mockbin:$PATH" HOME="$tmp/okhome" kiro-cli chat --help 2>&1 >/dev/null) || rc=$?
assert_eq "$rc" "97" "替身加载不了 helpers.sh：以 97 退出"
assert_contains "$err" "helpers.sh" "替身加载不了 helpers.sh：报错点名"
# 端到端层面：测试忘了 mock_config_write → 第一次 kiro-cli 调用（--help）就失败 → 用例红（不是假绿）
NO_MOCK_DIR=1 run_case nomockdir
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "漏建替身配置目录：评审失败（替身拒绝运行）"
assert_eq "$([[ -e "$MD/args" || -e "$MD/calls" ]] && echo recorded || echo none)" "none" "漏建替身配置目录：替身什么都没记（而不是记了一半）"
# Kiro 进程环境里不再有 KIRO_ENV_PASSTHROUGH/KIRO_MOCK_DIR 这类测试专用变量——替身通道完全走 HOME
assert_eq "$(grep -c -x -- 'KIRO_MOCK_DIR' "$tmp/case-ok/home/.kiro-mock/env")" "0" "成功路径：Kiro 进程环境里没有测试专用的 KIRO_MOCK_DIR"

# ---- kiro-cli 版本 vs KIRO_TESTED_VERSIONS（15-fix2 #24）：不在名单里不失败，但日志与汇总评论都要有 notice ----
run_case oldver MOCK_KIRO_VERSION=9.9.9
assert_rc "$RC" 0 "kiro-cli 版本不在名单：评审照常完成（不失败）"
assert_contains "$OUT" "未经 P1-15 探测" "kiro-cli 版本不在名单：日志警告"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "未经 P1-15 探测" "kiro-cli 版本不在名单：汇总评论带 notice"
assert_contains "$comment" "9.9.9" "kiro-cli 版本不在名单：notice 写出实际版本"
assert_contains "$comment" "2.21.1" "kiro-cli 版本不在名单：notice 写出已探测版本"
run_case nover MOCK_KIRO_VERSION=
assert_rc "$RC" 0 "kiro-cli 版本取不到：评审照常完成"
assert_contains "$(posted_comment "$OUT")" "未知" "kiro-cli 版本取不到：notice 写「未知」"
# 15-fix3 #8：版本打到 stderr 的 CLI 也要取得到（否则每条评论永久带「版本未知」notice 且无法清除）
run_case verstderr MOCK_KIRO_VERSION_STDERR=1
assert_rc "$RC" 0 "kiro-cli --version 打到 stderr：评审照常完成"
assert_contains "$OUT" "在 P1-15 探测过的版本名单内" "kiro-cli --version 打到 stderr：仍取得到版本、名单内"
assert_not_contains "$(posted_comment "$OUT")" "未经 P1-15 探测" "kiro-cli --version 打到 stderr：无 notice"
# 15-fix4 #7：stderr 上先到的升级提示不能被当成已装版本。旧写法 `2>&1 | head -1 | grep -oE 数字` 取到的是先 flush 的那个流的第一行——
# stderr 无缓冲、stdout 进管道块缓冲，升级提示「… 2.30.0 …」先到 → 脚本据以判定的是**可用**版本；等 2.30.0 进 KIRO_TESTED_VERSIONS，
# 装着未探测 2.21.x 的机器反而不再告警。新取法：stdout 与 stderr 分开捕获，先在 stdout 里按程序名锚定 `kiro-cli <X.Y.Z>`，取不到再看 stderr。
run_case verwarn MOCK_KIRO_VERSION_WARN=1
assert_rc "$RC" 0 "stderr 先打升级提示：评审照常完成"
assert_contains "$OUT" "kiro-cli 版本 2.21.1：在 P1-15 探测过的版本名单内" "stderr 先打升级提示：取到的是已装版本 2.21.1，不是提示里的 2.30.0"
assert_not_contains "$OUT" "2.30.0 未经" "stderr 先打升级提示：没把 2.30.0 当成本次版本"
assert_not_contains "$(posted_comment "$OUT")" "未经 P1-15 探测" "stderr 先打升级提示：无 notice"
# 升级提示 + 版本打到 stderr（两条都在 stderr）：仍按程序名锚定取到已装版本
run_case verwarn2 MOCK_KIRO_VERSION_WARN=1 MOCK_KIRO_VERSION_STDERR=1
assert_contains "$OUT" "kiro-cli 版本 2.21.1：在 P1-15 探测过的版本名单内" "升级提示与版本都在 stderr：按程序名锚定仍取到 2.21.1"
# --version 跑不起来（退出码 127）：走失败评论（固定文案），不再是软 notice 后在 chat 上烧掉整个 KIRO_TIMEOUT
run_case verfail MOCK_KIRO_VERSION_RC=127 MOCK_KIRO_VERSION_ERRTOKEN="$SEC_GHP"
assert_eq "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero" "kiro-cli --version 退出 127：评审失败"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "评审未完成" "kiro-cli --version 退出 127：失败评论"
assert_contains "$comment" "kiro-cli --version 失败" "kiro-cli --version 退出 127：失败评论固定文案点名 --version"
assert_not_contains "$OUT" "$SEC_GHP" "合并后复审⑦：--version 的 stderr 尾巴是不受信取值，走 die_review 第二参数过掩码——流水线日志不含原文（130f977 原样进日志：正控）"
assert_contains "$OUT" "$SEC_GHP_MASKED" "合并后复审⑦：日志里是掩码形态"
assert_contains "$comment" "127" "kiro-cli --version 退出 127：失败评论带退出码"
assert_eq "$([[ -e "$MD/args" ]] && echo launched || echo not-launched)" "not-launched" "kiro-cli --version 退出 127：Kiro chat 未被启动（不烧额度）"
assert_eq "$(call_count "$MD/calls" settings)" "0" "kiro-cli --version 退出 127：settings 也未调用（在能力检查处就停）"
# 15-fix3 #3：降级路径（结构化解析失败）同样要带版本 notice——原来只在结构化分支并入
run_case degnotice MOCK_KIRO_NO_MARKER=1 MOCK_KIRO_VERSION=9.9.9
assert_rc "$RC" 0 "降级 + 版本不在名单：退出码 0"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "结构化解析失败" "降级 + 版本不在名单：是降级评论"
assert_contains "$comment" "未经 P1-15 探测" "降级 + 版本不在名单：降级评论也带版本 notice"
assert_contains "$comment" "9.9.9" "降级 + 版本不在名单：notice 写出实际版本"
assert_not_contains "$(posted_comment "$out")" "未经 P1-15 探测" "成功路径（2.21.1）：汇总评论无版本 notice"

# 15-fix4 #3 / A7：降级评论只带 REVIEW_NOTICE——INLINE_NOTICE（「全部问题都归入未定位」这类关于分桶的提示）不该出现在一份没有问题清单的评论里。
# 纯删除 MR + INLINE_COMMENT=1 让第 4.5 步产生 INLINE_NOTICE，再让评审员不守契约走降级。对 5462175 必须失败（那里降级评论继承 ALL_NOTICE）。
tweak_pure_delete() { git reset -q --hard origin/main; git rm -q src/app.py; git commit -qm "delete app"; git push -qf origin feature/x; }
CASE_TWEAK=tweak_pure_delete run_case degnoinline INLINE_COMMENT=1 MOCK_KIRO_NO_MARKER=1 MOCK_KIRO_VERSION=9.9.9
assert_rc "$RC" 0 "降级 + 纯删除 MR：退出码 0"
assert_contains "$OUT" "全部问题都归入" "降级 + 纯删除 MR：日志里有分桶提示（INLINE_NOTICE 确实产生了）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "结构化解析失败" "降级 + 纯删除 MR：是降级评论"
assert_contains "$comment" "未经 P1-15 探测" "降级 + 纯删除 MR：版本 notice 在"
assert_not_contains "$comment" "全部问题都归入" "降级 + 纯删除 MR：分桶提示（INLINE_NOTICE）不进降级评论"

# ---- 日志里的变量名清单按数组元素取名字（15-fix #7）：取值含换行时，换行后的半个取值不能进日志 ----
run_case nlkey KIRO_API_KEY="$(printf 'k\nSECRETFRAG=leaked')"
assert_rc "$RC" 0 "取值含换行：评审正常完成"
assert_not_contains "$OUT" "SECRETFRAG" "取值含换行：日志里不出现换行后的半个取值"
assert_contains "$(printf '%s\n' "$OUT" | grep -F "Kiro 进程环境许可清单" | head -1)" "KIRO_API_KEY" "取值含换行：清单里仍列出 KIRO_API_KEY 这个名字"

# ---- 业务库里的符号链接在 Kiro 启动前全部删除（15-fix #1）：`payload -> /root/.aws/credentials` 的请求路径字面上在 allow 内 ----
tweak_symlinks() {
  ln -s /etc/hosts link-to-hosts
  mkdir -p src/sub2 && ln -s /etc src/sub2/link-to-etc-dir
  ln -s ../outside-target src/link-rel-dangling
  git add -A && git commit -qm "add symlinks"
}
CASE_TWEAK=tweak_symlinks run_case symlinks
assert_rc "$RC" 0 "符号链接：评审正常完成"
assert_eq "$(cat "$MD/cwdscan")" "" "符号链接：Kiro 启动时工作区里没有任何符号链接（含指向目录的、悬空的）"
assert_contains "$OUT" "3 个符号链接" "符号链接：日志计数 3 个"
assert_contains "$(cat "$MD/stdin")" "link-to-hosts" "符号链接：链接本身的改动仍在 diff 里（diff 先算好，删链接不影响评审输入）"
assert_eq "$([[ -d "$CASE/work/src/sub2" ]] && echo kept || echo gone)" "kept" "符号链接：只删链接，普通目录保留"
assert_eq "$([[ -e "$CASE/work/src/app.py" ]] && echo kept || echo gone)" "kept" "符号链接：普通文件保留"
assert_eq "$(git -C "$CASE/work" rev-parse --is-inside-work-tree 2>/dev/null)" "true" "符号链接：.git 未被触碰"

# ---- 嵌套 .git（15-fix2 #15）：旧写法 -path ./.git -prune 只剪根目录那一份，vendored clone / fixture 仓库的 .git 内部会被改动 ----
tweak_nested_git() {
  mkdir -p vendor/lib/.git/hooks
  ln -s /etc/hosts vendor/lib/.git/nestedlink
  printf 'inside nested .git\n' > vendor/lib/.git/AGENTS.md
  mkdir -p vendor/lib/.git/.kiro && echo '{}' > vendor/lib/.git/.kiro/x.json
  mkdir -p sub && ln -s /etc sub/.git          # .git 本身是符号链接：不是目录、不剪枝，按符号链接删掉
  ln -s /etc/hosts vendor/lib/link-outside-git  # 嵌套 .git **旁边**的链接照常删
}
CASE_TWEAK=tweak_nested_git run_case nestedgit
assert_rc "$RC" 0 "嵌套 .git：评审正常完成"
assert_eq "$([[ -L "$CASE/work/vendor/lib/.git/nestedlink" ]] && echo kept || echo gone)" "kept" "嵌套 .git：目录内部的符号链接不动"
assert_eq "$([[ -f "$CASE/work/vendor/lib/.git/AGENTS.md" ]] && echo kept || echo gone)" "kept" "嵌套 .git：目录内部的 AGENTS.md 不动"
assert_eq "$([[ -d "$CASE/work/vendor/lib/.git/.kiro" ]] && echo kept || echo gone)" "kept" "嵌套 .git：目录内部的 .kiro 不动"
assert_eq "$([[ -L "$CASE/work/sub/.git" || -e "$CASE/work/sub/.git" ]] && echo kept || echo gone)" "gone" "嵌套 .git：名为 .git 的符号链接按符号链接删掉"
assert_eq "$([[ -L "$CASE/work/vendor/lib/link-outside-git" ]] && echo kept || echo gone)" "gone" "嵌套 .git：旁边的符号链接照常删"
assert_eq "$(cat "$MD/cwdscan")" "" "嵌套 .git：Kiro 启动时扫描不到残留（扫描谓词同样剪掉嵌套 .git）"
assert_contains "$OUT" "2 个符号链接" "嵌套 .git：只删了 sub/.git 与 link-outside-git 两个链接（计数 2）"

# ---- .kiro 大小写不敏感 + 根 .kiro 普通文件（15-fix3 #1 #2）：macOS/Windows 执行器上 .Kiro/ 按 .kiro/ 读到；旧代码无条件 rm -rf ./.kiro 没搬进新库 ----
# 夹具在 tests/fixture-repo.sh 的 make_kiro_case_variants（与变异 M5t / M5u 同一份，15-fix4 #10）
CASE_TWEAK=make_kiro_case_variants run_case kirocase
assert_rc "$RC" 0 ".kiro 变体：评审正常完成"
assert_eq "$([[ -e "$CASE/work/.kiro" ]] && echo kept || echo gone)" "gone" ".kiro 变体：根 .kiro 普通文件被删"
assert_eq "$([[ -e "$CASE/work/src/.Kiro" ]] && echo kept || echo gone)" "gone" ".kiro 变体：src/.Kiro/ 目录被删（不分大小写）"
assert_eq "$([[ -e "$CASE/work/src/x/.KIRO" ]] && echo kept || echo gone)" "gone" ".kiro 变体：子目录 .KIRO 文件被删"
assert_eq "$([[ -e "$CASE/work/src/sub/.kiro" ]] && echo kept || echo gone)" "gone" ".kiro 变体：原有子目录 .kiro/ 照删"
assert_eq "$(cat "$MD/cwdscan")" "" ".kiro 变体：Kiro 启动时扫描不到残留（扫描谓词同样不分大小写、不限类型）"
assert_eq "$(leftovers)" "" ".kiro 变体：运行后无残留"
assert_contains "$OUT" "4 个 .kiro、" ".kiro 变体：计数 4（根文件 + .Kiro + src/x/.KIRO + src/sub/.kiro）"

# ---- 谓词等价（15-fix2 #23 / 15-fix4 #6）：生产隔离函数实际删除的集合 == 枚举版列出的集合（在一棵刻意刁难的合成树上）----
# 15-fix4 #6 起两者转调同一个发射器 review_isolation_scan，等价现在是恒等；用例保留为「删除清单 == 扫描结果」与计数口径的 golden。
EQ="$tmp/eqtree"; mkdir -p "$EQ"
( cd "$EQ" && mkdir -p .git/hooks nested/repo/.git a/b c .kiro/settings d
  ln -s /etc/hosts .git/rootgitlink; printf 'x' > .git/AGENTS.md            # 根 .git 内部：不动
  ln -s /etc/hosts nested/repo/.git/innerlink; printf 'x' > nested/repo/.git/AGENTS.md; mkdir nested/repo/.git/.kiro   # 嵌套 .git 内部：不动
  ln -s /etc c/.git                                                          # 名为 .git 的符号链接：按符号链接删
  printf 'x' > AGENTS.md; printf 'x' > a/agents.md; mkdir a/b/AGENTS.md      # 大小写不敏感；同名目录不算
  echo '{}' > .kiro/settings/cli.json; ln -s ../evil d/.kiro                # .kiro 目录 + .kiro 符号链接
  ln -s /etc/hosts filelink; ln -s /etc dirlink; ln -s nowhere dangling; ln -s /etc/hosts a/b/deeplink
  ln -s /etc/hosts "$(printf 'tabtail\t')"                                    # 名字以制表符结尾的链接：IFS 切分会剥掉尾巴（合并后复审②）
  printf 'x' > lsp.json; printf 'x' > a/lsp.json                            # 只有根 lsp.json 算
  printf 'x' > .kiro/settings/inner-agents.md )                               # .kiro 内部：随 .kiro 整体删，不单列
expected=$(cd "$EQ" && injection_surface_scan | sort)
assert_eq "$(printf '%s\n' "$expected" | grep -c .)" "11" "谓词等价前置：枚举版在合成树上列出 11 条（2 AGENTS.md + 2 .kiro + 6 符号链接 + 根 lsp.json）"
pre_scan=$(cd "$EQ" && review_isolation_scan | od -An -c | tr -d ' \n')   # 删除前发射器的原始 NUL 流
counts=$(cd "$EQ" && review_isolate_workspace "$tmp/eq-removed.zlist")
actual=$(tr '\0' '\n' < "$tmp/eq-removed.zlist" | cut -f2- | sort)
assert_eq "$actual" "$expected" "谓词等价：生产隔离函数删除的集合 == 测试谓词枚举的集合"
assert_eq "$(od -An -c "$tmp/eq-removed.zlist" | tr -d ' \n')" "$pre_scan" "谓词等价：删除清单逐字节等于删除前发射器的 NUL 流（先写清单再删）"
assert_eq "$(tr '\0' '\n' < "$tmp/eq-removed.zlist" | cut -f1 | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')" "agents=2 kiro=2 links=6 lsp=1 " "谓词等价：清单里的 class 列与四个计数一致"
assert_eq "$([[ -L "$EQ/$(printf 'tabtail\t')" ]] && echo survived || echo gone)" "gone" "合并后复审②：名字以制表符结尾的符号链接真的被删了（130f977：计数了、清单里有、链接却幸存——正控）"
assert_eq "$counts" "2 2 6 1" "谓词等价：计数 = 2 个 AGENTS.md（根 + a/agents.md）、2 个 .kiro（目录 + 链接）、6 个符号链接（filelink dirlink dangling a/b/deeplink c/.git tabtail\t）、1 个根 lsp.json"
assert_eq "$(cd "$EQ" && injection_surface_scan | wc -l | tr -d ' ')" "0" "谓词等价：隔离后枚举版扫描为空"
assert_eq "$([[ -L "$EQ/.git/rootgitlink" && -f "$EQ/.git/AGENTS.md" ]] && echo kept || echo gone)" "kept" "谓词等价：根 .git 内部不动"
assert_eq "$([[ -L "$EQ/nested/repo/.git/innerlink" && -f "$EQ/nested/repo/.git/AGENTS.md" && -d "$EQ/nested/repo/.git/.kiro" ]] && echo kept || echo gone)" "kept" "谓词等价：嵌套 .git 内部不动"
assert_eq "$([[ -d "$EQ/a/b/AGENTS.md" && -f "$EQ/a/lsp.json" ]] && echo kept || echo gone)" "kept" "谓词等价：同名目录 AGENTS.md/ 与非根 lsp.json 不动"
# 第二棵树（15-fix3 #1 #2 #11）：根 .kiro 普通文件、.Kiro/ 目录、.KIRO 符号链接、**符号链接形态的根 lsp.json**（枚举版曾把它输出两次）
EQ2="$tmp/eqtree2"; mkdir -p "$EQ2"
( cd "$EQ2" && mkdir -p .git a/.Kiro/settings b c
  printf 'plain' > .kiro; echo '{}' > a/.Kiro/settings/cli.json; ln -s ../nowhere b/.KIRO     # 大小写变体各在不同目录（APFS 大小写不敏感）
  ln -s /etc/hosts lsp.json; printf 'x' > c/lsp.json )
expected2=$(cd "$EQ2" && injection_surface_scan | sort)
assert_eq "$(printf '%s\n' "$expected2" | grep -c .)" "4" "谓词等价 2：枚举版列出 4 条（.kiro 文件、a/.Kiro 目录、b/.KIRO 链接、lsp.json 链接）"
assert_eq "$(printf '%s\n' "$expected2" | grep -c -x './lsp.json')" "1" "谓词等价 2：符号链接形态的根 lsp.json 只出现一次"
counts2=$(cd "$EQ2" && review_isolate_workspace "$tmp/eq2-removed.zlist")
assert_eq "$(tr '\0' '\n' < "$tmp/eq2-removed.zlist" | cut -f2- | sort)" "$expected2" "谓词等价 2：生产隔离函数删除的集合 == 枚举版集合"
# 15-fix4 #6 / B7：符号链接形态的根 lsp.json 归 lsp 类（日志「根 lsp.json（N 个）」与实际一致），不再落进符号链接桶
assert_eq "$counts2" "0 3 0 1" "谓词等价 2：计数 = 0 AGENTS.md、3 个 .kiro（文件/.Kiro/.KIRO 链接）、0 个符号链接、1 个根 lsp.json（符号链接形态也算 lsp）"
assert_eq "$(tr '\0' '\n' < "$tmp/eq2-removed.zlist" | grep -c $'^lsp\t./lsp.json$')" "1" "谓词等价 2：清单里 ./lsp.json 的 class 是 lsp"
assert_eq "$(cd "$EQ2" && injection_surface_scan | wc -l | tr -d ' ')" "0" "谓词等价 2：隔离后枚举版扫描为空"
assert_eq "$([[ -f "$EQ2/c/lsp.json" ]] && echo kept || echo gone)" "kept" "谓词等价 2：非根 lsp.json 不动"
# 15-fix3 #10 / 15-fix4 #6：计数按 find 匹配时的类别记账；清单按 NUL 分隔——路径含换行时清单里仍是**一条**、且逐字等于那个名字（对 5462175 必须失败：那里按行写，一条拆成两行）
EQ3="$tmp/eqtree3"; mkdir -p "$EQ3/.git" && ( cd "$EQ3" && ln -s /etc/hosts "$(printf 'weird\nname')" )
counts3=$(cd "$EQ3" && review_isolate_workspace "$tmp/eq3-removed.zlist")
assert_eq "$counts3" "0 0 1 0" "谓词等价 3：含换行的符号链接只算 1 个（按 find 匹配计数，不按列表行数、不按字符串重分类）"
assert_eq "$(ls -A "$EQ3" | grep -v '^.git$' | wc -l | tr -d ' ')" "0" "谓词等价 3：含换行名字的符号链接已删除"
assert_eq "$(tr -cd '\0' < "$tmp/eq3-removed.zlist" | wc -c | tr -d ' ')" "1" "谓词等价 3：NUL 清单恰好一条记录"
assert_eq "$(tr '\0' '\n' < "$tmp/eq3-removed.zlist" | head -c -1 2>/dev/null || tr '\0' '\n' < "$tmp/eq3-removed.zlist")" "$(printf 'links\t./weird\nname\n')" "谓词等价 3：那条记录逐字是 links<TAB>./weird<换行>name（集合相等，不只是计数）"
# 15-fix4 #6 / E4：被删目录（.kiro/、目录形态的根 lsp.json/）内部的嵌套 .git 随目录一起删——不是工作树的版本库；工作树自己的 .git（根、a/.git）不动
EQ4="$tmp/eqtree4"; mkdir -p "$EQ4/.git" "$EQ4/x/.kiro/fixtures/repo/.git/objects" "$EQ4/a/.git/objects" "$EQ4/lsp.json/.git"
( cd "$EQ4" && printf 'x' > x/.kiro/fixtures/repo/.git/HEAD && printf 'x' > a/.git/HEAD && printf 'x' > .git/HEAD && printf 'x' > lsp.json/.git/HEAD )
counts4=$(cd "$EQ4" && review_isolate_workspace "$tmp/eq4-removed.zlist")
assert_eq "$counts4" "0 1 0 1" "谓词等价 4：1 个 .kiro（含内部嵌套 .git）+ 1 个目录形态的根 lsp.json（含内部 .git）"
assert_eq "$([[ -e "$EQ4/x/.kiro" ]] && echo kept || echo gone)" "gone" "谓词等价 4：x/.kiro/ 连同内部嵌套的 .git 一起删除（不是工作树的版本库）"
assert_eq "$([[ -e "$EQ4/lsp.json" ]] && echo kept || echo gone)" "gone" "谓词等价 4：目录形态的根 lsp.json/ 连同内部 .git 一起删除"
assert_eq "$([[ -f "$EQ4/.git/HEAD" && -f "$EQ4/a/.git/HEAD" ]] && echo kept || echo gone)" "kept" "谓词等价 4：工作树自己的根 .git 与不在被删目录内的 a/.git 不动"
# 15-fix4 #6：多批 -exec +（大量符号链接、长名字让 find 分多批调用 sh -c）——计数与清单都必须完整
EQ5="$tmp/eqtree5"; mkdir -p "$EQ5/.git" "$EQ5/d"
( cd "$EQ5/d" && longname=$(printf 'l%.0s' $(seq 1 150)) && for i in $(seq 1 7000); do ln -s /etc/hosts "${longname}-${i}"; done )
counts5=$(cd "$EQ5" && review_isolate_workspace "$tmp/eq5-removed.zlist")
assert_eq "$counts5" "0 0 7000 0" "谓词等价 5：7000 个符号链接（多批 -exec +）计数完整"
assert_eq "$(tr -cd '\0' < "$tmp/eq5-removed.zlist" | wc -c | tr -d ' ')" "7000" "谓词等价 5：清单 7000 条"
assert_eq "$(ls -A "$EQ5/d" | wc -l | tr -d ' ')" "0" "谓词等价 5：全部删除"
# 15-fix4 #6：任一条删除失败 → 返回非零（清单已写、计数不打）：把一个 .kiro 目录设为不可删（父目录只读）
if [[ "$(id -u)" != "0" ]]; then
  EQ6="$tmp/eqtree6"; mkdir -p "$EQ6/.git" "$EQ6/ro/.kiro"; chmod 555 "$EQ6/ro"
  rc6=0; out6=$(cd "$EQ6" && review_isolate_workspace "$tmp/eq6-removed.zlist" 2>/dev/null) || rc6=$?
  chmod 755 "$EQ6/ro"
  assert_eq "$([[ $rc6 -ne 0 ]] && echo nonzero)" "nonzero" "谓词等价 6：删不掉时返回非零"
  assert_eq "$out6" "" "谓词等价 6：失败时不打计数（调用方 die_review）"
  assert_eq "$(tr '\0' '\n' < "$tmp/eq6-removed.zlist" | cut -f2-)" "./ro/.kiro" "谓词等价 6：清单在删除之前已写好（先持久化再删）"
fi

# ---- 静态：scripts/ 里不得再有多字节分隔符的 paste（GNU coreutils 会截成单字节，产出非法 UTF-8；15-fix3 #4）与 --print-paths（#12）----
# 只看 paste 的分隔符参数：-d / -sd 后接单引号或双引号字面量，以及 --delimiters=… 的两种引号（15-fix4 #12）。
# 非 ASCII 判定用 LC_ALL=C 下的**否定可打印类** `[^ -~[:space:]]`：BSD grep 在 C locale 下对 `[\x80-\xff]` 字节范围匹配不到任何东西
# （macOS 上旧守卫恒为 0，正控只证明 paste -d 存在，D3 实测），否定类在 BSD / GNU 都按字节生效。
paste_delims() { LC_ALL=C grep -rhoE "paste[[:space:]]+(-[a-z]*d[[:space:]]*|--delimiters=)('[^']*'|\"[^\"]*\")" "$@" || true; }   # 无匹配时输出空、不让 set -e 中止
non_ascii_count() { LC_ALL=C grep -c '[^ -~[:space:]]' || true; }
assert_eq "$(paste_delims "$ROOT/scripts" | non_ascii_count)" "0" "静态：scripts/ 里 paste 的每个分隔符字面量都是单字节 ASCII（GNU coreutils 会把多字节截成单字节）"
assert_eq "$([[ "$(paste_delims "$ROOT/scripts" | wc -l | tr -d ' ')" -ge 1 ]] && echo some || echo none)" "some" "静态前置：scripts/ 里确有 paste -d 调用（否则上一条恒真）"
# 正控（本平台上跑一次）：四种写法的多字节分隔符都必须被正则认出、且被非 ASCII 判定抓到——否则上面那条在本平台上是空的
printf "%s\n" "x | paste -sd'、' -" 'y | paste -d"、" -' "z | paste --delimiters='、' -" 'w | paste -sd"，" -' "ok | paste -sd' ' -" > "$tmp/paste-ctl.txt"
paste_ctl=$(paste_delims "$tmp/paste-ctl.txt")
assert_eq "$(printf '%s\n' "$paste_ctl" | wc -l | tr -d ' ')" "5" "静态正控：五种 paste 分隔符写法都被正则认出"
assert_eq "$(printf '%s\n' "$paste_ctl" | non_ascii_count)" "4" "静态正控：四个多字节分隔符在本平台上都被非 ASCII 判定抓到（单字节那个不算）"
assert_eq "$(grep -rn -- '--print-paths\|print_paths' "$ROOT/scripts" | wc -l | tr -d ' ')" "0" "静态：--print-paths 协议已从 scripts/ 删除"
# 15-fix4 #8：tests/helpers.sh 的辅助函数不得把 printf 出来的大字符串管进可能提前停读的程序（grep -q / head）——下游一停读上游 printf 收
# SIGPIPE，pipefail 下整个测试文件以 141 静默退出、连 FAIL 行都没有（assert_contains 与 meta_row 都踩过）。只看代码行，不看注释。
early_exit_pipes() { grep -v '^[[:space:]]*#' "$1" | grep -cE 'printf .*\|.*(grep -q|head( |$))' || true; }
assert_eq "$(early_exit_pipes "$ROOT/tests/helpers.sh")" "0" "静态：helpers.sh 里没有 printf … | grep -q / head 这类会提前停读的管道"
printf '%s\n' 'meta_row() { printf "%s\n" "$1" | { grep -F x || true; } | head -1; }' 'x() { printf "%s" "$1" | grep -qF y; }' '# printf | head 注释不算' > "$tmp/helpers-old-shape.sh"
assert_eq "$(early_exit_pipes "$tmp/helpers-old-shape.sh")" "2" "静态正控：旧 meta_row（… | head -1）与 printf | grep -q 两种形状都被认出、注释不算"

run_case rerunhint REVIEW_RERUN_HINT='评论 `/kiro review` 可重新评审'
assert_rc "$RC" 0 "REVIEW_RERUN_HINT：评审成功"
comment=$(posted_comment "$OUT")
assert_contains "$comment" '评论 `/kiro review` 可重新评审' "REVIEW_RERUN_HINT：页脚用配置的提示语"
assert_not_contains "$comment" "重跑流水线可重新评审" "REVIEW_RERUN_HINT：不再出现默认提示语"

# ============================================================================
# 票 16 / A10：脚本侧掩码覆盖全部 sink（spec I3 修订）
# =====================================================================# mock 评审员输出**合法契约**、summary / verdict_reason / title / body / fix 里各放一个合成 token
# （helpers.sh with_secrets：ghp_ 形态、AKIA 形态、base64 补位形态）。此前正常路径只做结构清洗、不掩码，
# 三个值原样进汇总评论（CodeX P0-2）。断言对象是三处 sink：DRY_RUN 记录的汇总正文、每条行内正文、以及
# 2> 捕获的流水线日志（OUT 同时含三者，所以对 OUT 整体断一次「原文不在」等于三处都断了；再对各处单独断
# 「掩码形态在」，证明不是靠内容整体消失蒙对的）。
with_secrets "$ROOT/tests/fixtures/contract/mock-review.json" > "$tmp/secrets-summary.json"
with_secrets "$E2E_CONTRACT" > "$tmp/secrets-inline.json"
# ---- INLINE_COMMENT=0：汇总正文 + 流水线日志 ----
run_case sinkleak MOCK_KIRO_CONTRACT="$tmp/secrets-summary.json"
assert_rc "$RC" 0 "A10：合法契约带 token → 评审仍成功（掩码不是失败）"
assert_not_contains "$OUT" "结构化解析失败" "A10：走的是正常结构化路径，不是降级路径上的旧掩码"
comment=$(posted_comment "$OUT")
assert_masked "$comment" "A10 汇总正文"
assert_masked "$OUT" "A10 全部输出（含流水线日志）"
assert_contains "$comment" "硬编码疑似应用密钥 ${SEC_AKIA_MASKED_TITLE}**" "A10 汇总：标题里的 token 掩码后（* 转义，第 22 条），加粗标题其余部分完好"
assert_contains "$comment" "api_key = \"${SEC_B64_MASKED}\"" "A10 汇总：fix 里的 key=value 只掩取值、键名保留"
assert_contains "$comment" "FAKE****0000" "A10 汇总：模型已自行掩码的值不被二次改写（幂等）"
# 掩码不碰脚本结构：评审标记 / 隐藏历史 / 元信息表 / 页脚都还在原形
assert_eq "$(printf '%s\n' "$comment" | grep -cE '^<!-- kiro-review:[0-9a-f]+ run:1 -->$')" "1" "A10 汇总：评审标记仍恰好一行"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^<!-- kiro-history:\[')" "1" "A10 汇总：隐藏历史仍在"
assert_eq "$(meta_row "$comment" | tr -cd '|' | wc -c | tr -d ' ')" "5" "A10 汇总：元信息表列数不变"
assert_contains "$comment" "第 1 次评审 · P0 必须修复 · P1 应当修复 · P2 可选改进" "A10 汇总：页脚不变"

# ---- INLINE_COMMENT=1：每条行内正文 + 汇总 + 日志 ----
run_inline_case sinkleak-inline ifx-sinkleak MOCK_KIRO_CONTRACT="$tmp/secrets-inline.json"
assert_rc "$RC" 0 "A10 行内：评审成功"
bodies=$(inline_bodies "$OUT")
assert_eq "$(printf '%s\n' "$bodies" | grep -c .)" "3" "A10 行内：仍发出 3 条行内评论（掩码不改变发布计划）"
inline_text=$(printf '%s\n' "$bodies" | jq -r '.content')
assert_masked "$inline_text" "A10 行内正文"
assert_contains "$inline_text" "**P0 · 硬编码疑似应用密钥 ${SEC_AKIA_MASKED_TITLE}**" "A10 行内正文：首行加粗完好，只有 token 变掩码（标题里的 * 转义）"
assert_eq "$(printf '%s\n' "$inline_text" | grep -c '^<!-- kiro-inline:[0-9a-f]\{40\} L[0-9]*-[0-9]* sev=P[0-2] -->$')" "3" \
  "A10 行内正文：三条隐藏标记完好（sha1 是十六进制、sev= 不在键名清单里，都没被掩）"
assert_no_secrets "$OUT" "A10 行内全部输出（含汇总与流水线日志）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "$SEC_GHP_MASKED" "A10 行内的汇总：summary 里的 token 掩码后仍在"
assert_contains "$comment" "$SEC_AKIA_MASKED" "A10 行内的汇总：verdict_reason 里的 token 掩码后仍在"
assert_contains "$comment" "其中 3 条已标注在「文件改动」对应行" "A10 行内的汇总：计数不受掩码影响"

# ---- 一次提交失败 → 退回逐条非草稿发布：回退路径复用同一份 body-<idx>.md，掩过一次就够 ----
run_inline_case sinkleak-submitfail ifx-sinkleak-sf DRY_RUN_FAIL_ROUTES="submit-review:400" \
  MOCK_KIRO_CONTRACT="$tmp/secrets-inline.json"
assert_rc "$RC" 0 "A10 回退发布：评审成功"
nondraft=$(inline_bodies "$OUT" | jq -r 'select(.draft == false) | .content')
assert_eq "$(printf '%s\n' "$nondraft" | grep -c '^<!-- kiro-inline:')" "3" "A10 回退发布：三条非草稿正文都发了"
assert_masked "$nondraft" "A10 回退发布的非草稿正文"
assert_no_secrets "$OUT" "A10 回退发布全部输出"

# ---- 行内全部发布失败 → 问题完整渲染进折叠区：折叠区里的 body/fix 由汇总的 sink 掩码兜住 ----
run_inline_case sinkleak-allfail ifx-sinkleak-af DRY_RUN_FAIL_ROUTES="submit-review:400,create-comment-inline:400" \
  MOCK_KIRO_CONTRACT="$tmp/secrets-inline.json"
assert_rc "$RC" 0 "A10 折叠区：评审成功"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "**行内发布失败（3）**" "A10 折叠区：发布失败小节在"
assert_contains "$comment" "api_key = \"${SEC_B64_MASKED}\"" "A10 折叠区：完整渲染的 fix 里 token 已掩"
assert_masked "$comment" "A10 折叠区里的完整正文"
assert_no_secrets "$OUT" "A10 折叠区全部输出"

# ---- 截断变体：掩码在截断之前，日志里回显的「完整内容」也是掩码后的 ----
run_case sinkleak-trunc MAX_COMMENT_BYTES=1200 MOCK_KIRO_CONTRACT="$tmp/secrets-summary.json"
assert_rc "$RC" 0 "A10 截断：评审成功"
assert_contains "$OUT" "评审报告超长已截断；完整内容如下：" "A10 截断：日志确实回显了完整内容（否则下面的断言是空转）"
assert_contains "$OUT" "已截断（上限 1200 字节）" "A10 截断：评论确实被截断"
assert_masked "$OUT" "A10 截断（日志全文 + 截断后评论）"

# ---- 回写失败变体：日志里回显的「评审结果如下」也是掩码后的 ----
run_case sinkleak-postfail DRY_RUN_FAIL_ROUTES="create-comment:500" CODEUP_RETRY_BACKOFF=0 \
  MOCK_KIRO_CONTRACT="$tmp/secrets-summary.json"
assert_nonzero "$RC" "A10 回写失败：非零退出"
assert_contains "$OUT" "OpenAPI 回写失败（已按策略重试）。评审结果如下：" "A10 回写失败：日志确实回显了评论全文"
assert_masked "$OUT" "A10 回写失败（日志全文）"

# ---- 掩码程序失败 → 绝不把未掩码的评论往下送：方案 C 下字段级（review_redact_json）先失败 → 失败评论，且失败评论自己也只剩固定文案 ----
make_bad_awk "$tmp/badawk"
run_case sinkleak-redactfail PATH="$tmp/badawk:$PATH" MOCK_KIRO_CONTRACT="$tmp/secrets-summary.json"
assert_nonzero "$RC" "A10 掩码失败：评审以失败结束（不能带着未掩码的评论成功）"
assert_contains "$OUT" "契约字段级掩码或清洗失败（rc=4" "A10 掩码失败：die_review 点明是字段级掩码失败（第 25 条：不含 token 连片的固定文案照常打出）"
assert_contains "$OUT" "review_redact_json: 掩码失败" "16-fix4 第 13 条：校验日志里库函数自己写的行进了日志（不再只说「详见校验日志」）"
assert_contains "$OUT" "review_validate: 字段级掩码失败" "第 13 条：review_validate 的说明行也在"
assert_contains "$OUT" "行 jq 诊断已省略" "第 13 条：非库函数前缀的 stderr 行（替身的 badawk: …）只报条数"
assert_not_contains "$(printf '%s\n' "$OUT" | grep -a '契约字段级掩码或清洗失败' || true)" "badawk:" "第 13 条：非库函数行本身不进失败原因（它们可能回显模型取值；替身在别的调用点直接写 stderr 的那几行不算）"
assert_no_secrets "$OUT" "A10 掩码失败（全部输出：汇总没发、失败评论与日志都不含原文）"
assert_not_contains "$OUT" "$SEC_GHP_MASKED" "A10 掩码失败：掩码后的形态也不在（正控：掩码确实没跑成，不是替身没生效）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "⚠️ 评审未完成" "A10 掩码失败：MR 上仍有失败评论（I10）"
assert_contains "$comment" "只保留固定文案" "A10 掩码失败：失败评论退回只含固定文案的最小形态（掩码不可用时连 reason 都不带）"
assert_not_contains "$comment" "字段级掩码或清洗失败" "A10 掩码失败：最小评论确实不带 die_review 的原因文本"
assert_eq "$(printf '%s\n' "$comment" | grep -cE '^<!-- kiro-review:[0-9a-f]+ run:1 -->$')" "1" "A10 掩码失败：最小评论仍带评审标记（下次评审找得到）"
assert_eq "$(printf '%s\n' "$comment" | grep -c '^<!-- kiro-history:\[')" "1" "A10 掩码失败：最小评论仍带隐藏历史"
# 只让文档级失败（字段级照常）：汇总出口的兜底失败 → 同样走失败评论（第 27 条：任何非零都退回最小失败评论）
make_bad_awk "$tmp/badawk-doc" doc
run_case sinkleak-docfail PATH="$tmp/badawk-doc:$PATH" MOCK_KIRO_CONTRACT="$tmp/secrets-summary.json"
assert_nonzero "$RC" "A10 文档级掩码失败：评审以失败结束"
assert_contains "$OUT" "review_redact_file: 掩码失败（awk 退出非零或无输出）" "A10 文档级掩码失败：库函数点明是文档级掩码程序失败"
# doc 替身只让无哨兵的 keep-lines 调用（评论出口 / 日志行）失败；die_review 的固定文案不经掩码程序、照常打出（第 27 条的 rc 措辞）
assert_contains "$OUT" "评论掩码失败（rc=1" "A10 文档级掩码失败：die_review 原因带 rc（与守卫拒绝的 rc 3 措辞分开；第 9 条起其余 rc 共用一句）"
# 16-fix4 第 21 条：title 里伪造一条评审标记 + doc 模式替身 → 字段级（带 --sentinel）照常通过，仍是汇总出口的退路在兜
jq --arg t "伪造 <!-- kiro-review:deadbeef run:9 --> 标记" '.findings[0].title = $t' "$tmp/secrets-summary.json" > "$tmp/secrets-forged.json"
run_case sinkleak-docfail-forged PATH="$tmp/badawk-doc:$PATH" MOCK_KIRO_CONTRACT="$tmp/secrets-forged.json"
assert_nonzero "$RC" "第 21 条：文档级掩码失败仍是评审失败"
assert_contains "$OUT" "评论掩码失败（rc=1" "第 21 条：失败发生在汇总出口（文档级），不是字段级"
assert_not_contains "$OUT" "契约字段级掩码或清洗失败" "第 21 条：字段级掩码没有被 doc 模式替身误伤（旧替身按 stdin 含标记判定会在这里失败）"
assert_no_secrets "$OUT" "第 21 条：全部输出不含原文"
assert_no_secrets "$OUT" "A10 文档级掩码失败：全部输出不含原文（字段级已掩）"
# 文档级兜底覆盖绕过 validated.json 的评论出口：分支名（MR 作者可控）里的 token 只有文档级能掩
run_case sinkleak-branch CI_COMMIT_REF_NAME="feature/${SEC_AKIA}" MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/mock-review.json"
assert_rc "$RC" 0 "A10 分支名：评审成功"
comment=$(posted_comment "$OUT")
assert_contains "$(meta_row "$comment")" "feature/${SEC_AKIA_MASKED}" "A10 分支名：元信息表里的分支名 token 被文档级兜底掩掉"
assert_not_contains "$comment" "$SEC_AKIA" "A10 分支名：评论里不含原文"
# 第 4 条：行内正文的文档级掩码失败 → 该条 outcome=failed、进折叠区、n_failed 计数；汇总照常发出且仍过掩码
make_bad_awk "$tmp/badawk-inline" inline
run_inline_case sinkleak-inlinefail ifx-sinkleak-if PATH="$tmp/badawk-inline:$PATH" MOCK_KIRO_CONTRACT="$tmp/secrets-inline.json"
assert_rc "$RC" 0 "第 4 条：行内掩码失败不让评审失败"
assert_eq "$(inline_bodies "$OUT" | grep -c . || true)" "0" "第 4 条：三条行内正文一条都没发出（掩码失败 → 不发）"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '行内评论正文渲染或掩码失败，转入折叠区')" "3" "第 4 条：三条都记为掩码失败、转入折叠区"
assert_contains "$OUT" "失败 3 条" "第 4 条：n_failed 计数为 3"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "**行内发布失败（3）**" "第 4 条：折叠区「行内发布失败」小节在"
assert_masked "$comment" "第 4 条：折叠区里的正文（字段级已掩、汇总文档级照常）"
# 第 21 条端到端：超限字段截断 + 日志计数 + 单条行内正文 ≤ MAX_COMMENT_BYTES
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["findings"][0]["body"]="B"*40000; c["findings"][0]["fix"]="F"*40000; json.dump(c,open(sys.argv[2],"w"),ensure_ascii=False)' "$E2E_CONTRACT" "$tmp/oversize-inline.json"
run_inline_case oversize ifx-oversize MOCK_KIRO_CONTRACT="$tmp/oversize-inline.json"
assert_rc "$RC" 0 "第 21 条：超限字段不让评审失败"
assert_contains "$OUT" "个模型字段超出上限已截断" "第 21 条：日志记录截断字段数"
bodies=$(inline_bodies "$OUT")
assert_eq "$(printf '%s\n' "$bodies" | grep -c .)" "3" "第 21 条：三条行内仍发出"
max_body=$(printf '%s\n' "$bodies" | jq -r '.content | utf8bytelength' | sort -n | tail -1)
assert_eq "$([[ $max_body -le 60000 ]] && echo ok)" "ok" "第 21 条：单条行内正文 ≤ MAX_COMMENT_BYTES 默认值 60000（实际最大 ${max_body} 字节）"
assert_contains "$(printf '%s\n' "$bodies" | jq -r '.content')" "（已截断）" "第 21 条：超限字段末尾带「（已截断）」"
# 第 24 条：kiro-cli 自己的 stderr 尾巴也是出口——失败时打进日志前先掩码
run_case stderrleak MOCK_KIRO_FAIL=1 MOCK_KIRO_STDERR_TEXT="request failed: Authorization: Bearer ${SEC_GHP}"
assert_nonzero "$RC" "第 24 条：kiro 失败 → 非零退出"
assert_contains "$OUT" "request failed: Authorization: Bearer ${SEC_GHP_MASKED}" "第 24 条：kiro stderr 尾巴打进日志前掩码"
assert_no_secrets "$OUT" "第 24 条：全部输出不含原文"
# 第 25 条：去重日志行里的 file 过掩码——file 必须命中变更行集合才走到去重日志，端到端造不出带 token 的路径；静态断言该行经过 _untrusted_for_log
assert_eq "$(grep -c 'log "去重：问题 #${idx}（${sev} $(_untrusted_for_log "$file")' "$ROOT/scripts/kiro-review.sh")" "1" "第 25 条（静态）：去重日志行里的 file 经过 _untrusted_for_log"
assert_eq "$(grep -c 'unset REVIEW_REDACT_SENTINEL_RE' "$ROOT/scripts/kiro-review.sh")" "0" "16-fix4 第 8 条（静态）：死 unset 已删"
assert_eq "$(grep -c '\[\[ -s "$WORK/validated.json" \]\] || die_review' "$ROOT/scripts/kiro-review.sh")" "1" "第 20 条（静态）：validated.json 非空守卫"
assert_eq "$(grep -c 'local body_bytes' "$ROOT/scripts/kiro-review.sh")" "1" "第 30 条（静态）：body_bytes 是函数局部变量"
assert_eq "$(grep -c '超过上限 ${REVIEW_MAX_FINDINGS}，仅展示前' "$ROOT/scripts/kiro-review.sh")" "1" "第 28 条（静态）：超上限有单独的日志行"

# ---- 票 16-fix ②：die_review 的日志行也是 sink——失败原因里的不受信取值（runFinished.status）过掩码再打日志 ----
# 评论正文已由 sink 掩码覆盖，这里补的是 `log "错误：…"` 那一行：事件流里的 status 串原样拼进原因，
# 此前直接进流水线日志。降级原因的不受信部分走同一个 _untrusted_for_log（现有 review_validate 对各种怪类型都做了规范化、
# jq 报错不会回显模型取值，所以降级原因目前没有能带出完整 token 的端到端向量——只断言那行日志仍在、没被包坏）。
run_case statusleak MOCK_KIRO_STATUS_TEXT="error ${SEC_GHP} ${SEC_AKIA}"
assert_nonzero "$RC" "16-fix 日志：status 非 success → 非零退出"
assert_contains "$OUT" "错误：Kiro 自报运行失败（runFinished.status 取值见后）：status=error ${SEC_GHP_MASKED} ${SEC_AKIA_MASKED}" \
  "16-fix 日志：die_review 的日志行带掩码后的 status（固定文案与取值都在，只有 token 变掩码）"
assert_no_secrets "$OUT" "16-fix 日志（全部输出：日志 + 失败评论）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "取值见后）：status=error ${SEC_GHP_MASKED}" "16-fix 日志对照：失败评论里同样是掩码后的 status（出口掩码兜住）"
# 掩码程序不可用时的日志退回：不打原文，只留固定文案（第 20 条：不再有第二套「粗掩」词汇）
run_case statusleak-badawk PATH="$tmp/badawk:$PATH" MOCK_KIRO_STATUS_TEXT="error ${SEC_GHP}"
assert_nonzero "$RC" "16-fix 日志退回：非零退出"
assert_contains "$OUT" "错误：Kiro 自报运行失败（runFinished.status 取值见后）：〈不受信取值已省略〉" "16-fix4 第 6 条：掩码不可用时固定文案照打、只丢不受信取值（中性占位）"
assert_no_secrets "$OUT" "16-fix 日志退回：全部输出不含原文"
# 降级原因那一行没被包坏（原因文案完整）
run_case degrade-reason-log MOCK_KIRO_LEAK_SECRET=1
assert_rc "$RC" 0 "16-fix 降级原因日志：评审成功（降级）"
assert_contains "$OUT" "警告：结构化解析失败（评审员输出中没有成对的 <<<KIRO_REVIEW_JSON>>> 契约标记），降级为贴出评审员输出原文" \
  "16-fix 降级原因日志：过掩码后文案逐字不变"

# ---- 16-fix3 第 13 条：降级路径掩码失败 fail-closed（48aff39：rc 0、评论 25 行正文空：正控）----
run_case degrade-redactfail PATH="$tmp/badawk:$PATH" MOCK_KIRO_LEAK_SECRET=1
assert_nonzero "$RC" "第 13 条：降级原文掩码失败 → 评审失败，而不是发一份空正文的降级评论"
assert_contains "$OUT" "review_render_degraded: 掩码失败" "第 13 条：库函数点明原因"
assert_contains "$OUT" "错误：降级评论渲染失败" "第 13 条 / 第 6 条：die_review 的固定文案在掩码不可用时照样打出"
assert_no_secrets "$OUT" "第 13 条：全部输出不含原文"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "⚠️ 评审未完成" "第 13 条：MR 上是失败评论"
# ---- 16-fix3 第 7 条：清洗会膨胀的填充（<!--）不再让行内正文超限；出口硬守卫兜住任何超限正文 ----
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); f="<!--"*10000; c["findings"][0]["title"]=f; c["findings"][0]["body"]=f; c["findings"][0]["fix"]=f; json.dump(c,open(sys.argv[2],"w"),ensure_ascii=False)' "$E2E_CONTRACT" "$tmp/expand-inline.json"
# 计时守卫量的是 CPU 时间（user + sys，含子进程）而不是墙钟：共机跑多套测试时墙钟能翻 5–8 倍，CPU 时间不受负载影响（自审 finding）
TIMEFORMAT='%U %S'
{ time run_inline_case expand ifx-expand MOCK_KIRO_CONTRACT="$tmp/expand-inline.json"; } 2> "$tmp/expand.time"
expand_cpu=$(awk 'END { printf "%d", $1 + $2 }' "$tmp/expand.time")
assert_rc "$RC" 0 "第 7 条：膨胀填充不让评审失败"
assert_eq "$([[ $expand_cpu -le 20 ]] && echo ok)" "ok" "16-fix4 第 12d 条：膨胀向量端到端 CPU ${expand_cpu}s（≤ 20 s，目标 < 5 s 的 4 倍；不缩小填充规模；cf29da0 单是 review_validate 就 2 分钟）"
bodies=$(inline_bodies "$OUT")
assert_eq "$(printf '%s\n' "$bodies" | grep -c .)" "3" "第 7 条：三条行内仍发出"
max_body=$(printf '%s\n' "$bodies" | jq -r '.content | utf8bytelength' | sort -n | tail -1)
assert_eq "$([[ $max_body -le 60000 ]] && echo ok)" "ok" "第 7 条：<!-- 填充清洗后再截断，单条行内正文 ≤ 60000（实际最大 ${max_body}；48aff39 为 89789：正控）"
# 出口硬守卫：把 MAX_COMMENT_BYTES 压到 20000，40 KB 的 body 过不了守卫 → 该条 failed 进折叠区、不发
run_inline_case bodyguard ifx-bodyguard MAX_COMMENT_BYTES=20000 MOCK_KIRO_CONTRACT="$tmp/oversize-inline.json"
assert_rc "$RC" 0 "第 7 条守卫：评审成功"
assert_contains "$OUT" "字节超过 MAX_COMMENT_BYTES=20000，转入折叠区" "第 7 条守卫：日志点明超限正文进折叠区"
assert_eq "$(inline_bodies "$OUT" | grep -c . || true)" "2" "第 7 条守卫：超限的那一条没发出（其余两条照发）"
assert_contains "$(posted_comment "$OUT")" "**行内发布失败（1）**" "第 7 条守卫：超限的那一条进了折叠区"
# 16-fix4 第 38 条：超大正文不再搬进汇总——折叠区只渲染标题 + 说明句，汇总不超限、不触发截断
assert_contains "$(posted_comment "$OUT")" "字节超过评论上限 MAX_COMMENT_BYTES=20000，未在评论中展示。" "第 38 条：折叠区那一条只有标题 + 说明句"
assert_not_contains "$(posted_comment "$OUT")" "$(python3 -c 'print("B"*200, end="")')" "第 38 条：40 KB 正文的前 200 字节不在汇总里（4e542ca 全文搬进折叠区、汇总随之超限被截：正控）"
assert_eq "$([[ $(posted_comment "$OUT" | wc -c) -lt 20000 ]] && echo ok)" "ok" "第 38 条：汇总总字节 < MAX_COMMENT_BYTES=20000"
assert_not_contains "$OUT" "报告超长已截断" "第 38 条：没有触发 review_truncate_comment（其它问题的文本不再被一起截掉）"
# ---- 16-fix4 第 7 条：掩码程序不可用时，含 ≥ 12 位 ASCII 标识符的固定文案必须原样出现在日志里（cf29da0 的「连片分类器」会整段省略：正控）----
run_case fixedtext-badawk PATH="$tmp/badawk:$PATH" INLINE_COMMENT=yes
assert_nonzero "$RC" "第 7 条：INLINE_COMMENT=yes → 非零退出"
assert_contains "$OUT" "错误：INLINE_COMMENT=yes 不是 0 或 1。行内评论开关只接受这两个取值" "第 7 条：含 INLINE_COMMENT 这种 ≥ 12 位标识符的固定文案在掩码不可用时仍原样进日志"
# 票 17 B：契约外的 verdict → 结论行固定文案，原值只进流水线日志
# ============================================================================
printf '{"contract":"codeup-reviewer/1","summary":"s","verdict":"<h1>可合并</h1>","verdict_reason":"r","findings":[]}\n' > "$tmp/offcontract-verdict.json"
run_case offverdict MOCK_KIRO_CONTRACT="$tmp/offcontract-verdict.json"
assert_rc "$RC" 0 "票 17 B：契约外 verdict 不让评审失败（退出码 0）"
assert_contains "$OUT" "警告：评审员结论不在契约内（已按未给出结论处理）：&lt;h1>可合并&lt;/h1>" "票 17 B：日志带清洗后的原值（只在日志里）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "## 结论：评审员未给出契约内的结论" "票 17 B：结论行是脚本的固定文案"
assert_not_contains "$comment" "h1" "票 17 B：载荷（连转义形态）不出现在评论任何位置"
assert_not_contains "$comment" "可合并" "票 17 B：载荷里的文字不出现在评论任何位置"
assert_not_contains "$comment" "非契约取值" "票 17 B：不再是「X（非契约取值）」"

# ============================================================================
# 票 17 C：同一轮完全重复的问题 → 合并、日志警告、行内只发一条
# ============================================================================
run_inline_case inlinedup ifx-inlinedup MOCK_KIRO_CONTRACT="$ROOT/tests/fixtures/contract/inline-dup.json"
assert_rc "$RC" 0 "票 17 C：退出码 0"
assert_contains "$OUT" "警告：1 条完全重复的问题已合并" "票 17 C：日志说明合并了几条"
assert_contains "$OUT" "评审报告：P0 1 · P1 0 · P2 0" "票 17 C：日志里的级别计数按合并后算"
assert_eq "$(inline_bodies "$OUT" | wc -l | tr -d ' ')" "1" "票 17 C：两条逐字段相同的问题只发一条行内评论（CodeX 复现时 inline_count=2）"
comment=$(posted_comment "$OUT")
assert_contains "$comment" "其中 1 条已标注在「文件改动」对应行" "票 17 C：统计行按合并后计数"
assert_contains "$comment" "P0 1 · P1 0 · P2 0" "票 17 C：级别计数按合并后算"
assert_eq "$(inline_bodies "$OUT" | jq -r '.content' | grep -c '直接写入源码')" "1" "票 17 C：发出的是首条（保留首条的正文）"

report
