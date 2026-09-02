#!/usr/bin/env bash
# Codeup MR 自动 Kiro 评审 — 主编排脚本。
# 安全前提：本脚本必须从受信集成包仓库（流水线独立代码源，固定分支/tag）执行，
# 绝不从被评审的业务仓库源分支执行（源分支可被 MR 作者任意修改）。
# 业务仓库 checkout 目录由 REVIEW_REPO_DIR 指定，仅作为被分析数据；其中的 AGENTS.md/lsp.json/.kiro/
# 在 diff 生成之后、Kiro 启动之前被移除（第 5.5 步），Kiro 固定以 v2 引擎运行（ADR-0004）。
# 退出码：0=评审完成并回写；非 0=失败（不卡合并，仅流水线标红）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/codeup-api.sh"
source "${SCRIPT_DIR}/lib/diff-compress.sh"
source "${SCRIPT_DIR}/lib/kiro-agent.sh"

KIRO_TIMEOUT="${KIRO_TIMEOUT:-900}"
MAX_COMMENT_BYTES="${MAX_COMMENT_BYTES:-60000}"
# 官方安装脚本 URL。来源：https://kiro.dev/docs/cli/installation/（页面命令
# `curl -fsSL https://cli.kiro.dev/install | bash`；脚本本身支持 Linux/macOS，
# Linux 下安装到 ~/.local/bin，含 glibc 检测与 musl 回退）。核实日期：2026-07-21。
KIRO_INSTALL_URL="${KIRO_INSTALL_URL:-https://cli.kiro.dev/install}"
PROMPT_FILE="${PROMPT_FILE:-${PKG_ROOT}/prompts/review-prompt.md}"
AGENT_FILE="${PKG_ROOT}/kiro/agent-codeup-reviewer.json"
REVIEW_REPO_DIR="${REVIEW_REPO_DIR:-$PWD}"
# Kiro 引擎钉死为 v2，写在脚本里而不是 agent 配置里（ADR-0004）：实测 kiro-cli 2.21 headless 的默认
# 引擎 v1 与预览版 v3 都不阻断工作区 AGENTS.md 注入，只有 v2 配合 chat.disableInheritingDefaultResources
# 才阻断。故意不读环境变量——引擎不是可配置项，避免被流水线变量或工作区设置改掉。
KIRO_ENGINE=v2

log() { echo "[kiro-review] $*" >&2; }
die() { log "错误：$*"; exit 1; }

# 定位到 MR 后的失败：best-effort 回写"评审未完成"评论再退出
MR_LOCATED=0
die_review() {
  log "错误：$*"
  if [[ "$MR_LOCATED" == "1" ]]; then
    local f
    f=$(mktemp)
    {
      echo "## 🤖 Kiro 自动代码评审"
      echo ""
      echo "<!-- kiro-review:${SHORT_SHA:-unknown} -->"
      echo "⚠️ 评审未完成：$*"
      echo ""
      echo "请查看流水线日志（构建号 ${BUILD_NUMBER:-?}）或重跑流水线。"
    } > "$f"
    codeup_post_comment "$LOCAL_ID" "$f" || log "回写失败评论也未成功，仅保留日志"
    rm -f "$f"
  fi
  exit 1
}

# --- 0. 依赖与必填变量检查（timeout 为强制依赖，不允许无超时运行）---
for cmd in git curl jq; do
  command -v "$cmd" >/dev/null || die "缺少依赖：${cmd}（请在构建机安装）"
done
TIMEOUT_BIN=""
command -v timeout >/dev/null && TIMEOUT_BIN=timeout
[[ -z "$TIMEOUT_BIN" ]] && command -v gtimeout >/dev/null && TIMEOUT_BIN=gtimeout
[[ -n "$TIMEOUT_BIN" ]] || die "缺少依赖：timeout/gtimeout（GNU coreutils）。无超时能力时 Kiro 挂起会永久占用流水线，拒绝运行"
: "${KIRO_API_KEY:?缺少 KIRO_API_KEY}"
: "${YUNXIAO_TOKEN:?缺少 YUNXIAO_TOKEN}"
: "${YUNXIAO_ORG_ID:?缺少 YUNXIAO_ORG_ID}"
: "${CODEUP_REPO_ID:?缺少 CODEUP_REPO_ID}"
REVIEW_REPO_DIR=$(cd "$REVIEW_REPO_DIR" 2>/dev/null && pwd) || die "REVIEW_REPO_DIR 不存在或不可进入：${REVIEW_REPO_DIR}"
# 第 5.5 步会删掉业务库工作树里的 AGENTS.md/.kiro/lsp.json，而 DRY_RUN 并不拦删除：
# 本地把集成包自身（或它的上级目录）误当业务库跑，会把集成包自己的文件删掉，直接拒绝。
[[ "$PKG_ROOT" != "$REVIEW_REPO_DIR" && "$PKG_ROOT" != "$REVIEW_REPO_DIR"/* ]] \
  || die "REVIEW_REPO_DIR（${REVIEW_REPO_DIR}）指向集成包自身或其上级目录，拒绝运行：隔离步骤会删除集成包内的文件"
[[ -d "$REVIEW_REPO_DIR/.git" ]] || die "REVIEW_REPO_DIR 不是 git 仓库：$REVIEW_REPO_DIR"
[[ -r "$PROMPT_FILE" ]] || die "评审提示词文件不可读：$PROMPT_FILE"
[[ -r "$AGENT_FILE" ]] || die "custom agent 配置文件不可读：$AGENT_FILE"

# --- 1. 安装/检测 kiro-cli ---
if ! command -v kiro-cli >/dev/null; then
  log "kiro-cli 不存在，尝试安装（云托管构建机场景）……"
  curl -fsSL --connect-timeout 10 --max-time 300 "$KIRO_INSTALL_URL" | bash \
    || die "kiro-cli 安装失败。网络受限时请使用自建构建机预装固定版本，或配置 HTTP_PROXY/HTTPS_PROXY（见 pipeline/setup-guide.md）"
  command -v kiro-cli >/dev/null || export PATH="$HOME/.local/bin:$PATH"
  command -v kiro-cli >/dev/null || die "安装后仍找不到 kiro-cli，请检查安装日志中的 PATH 提示"
fi

cd "$REVIEW_REPO_DIR"

# --- 2. 定位 MR（先定位，之后的任何失败都能回写「评审未完成」评论：spec I10 失败可见）---
SOURCE_BRANCH="${CI_COMMIT_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
if [[ -n "${MR_LOCAL_ID:-}" && -n "${MR_TARGET_BRANCH:-}" ]]; then
  LOCAL_ID="$MR_LOCAL_ID"; TARGET_BRANCH="$MR_TARGET_BRANCH"
  log "使用环境变量指定的 MR：#${LOCAL_ID}（${SOURCE_BRANCH} → ${TARGET_BRANCH}）"
else
  log "环境变量未提供 MR 信息，按源分支 ${SOURCE_BRANCH} 反查 OpenAPI……"
  mr_rc=0; mr_out=$(codeup_find_mr "$SOURCE_BRANCH") || mr_rc=$?
  case "$mr_rc" in
    0) LOCAL_ID=$(printf '%s' "$mr_out" | cut -f1)
       TARGET_BRANCH=$(printf '%s' "$mr_out" | cut -f2)
       log "反查到唯一 MR：#${LOCAL_ID}（${SOURCE_BRANCH} → ${TARGET_BRANCH}）" ;;
    3) log "同源分支存在多个打开的 MR，无法自动判定："
       printf '%s\n' "$mr_out" >&2
       die "MR 定位歧义。请在流水线变量中显式配置 MR_LOCAL_ID 与 MR_TARGET_BRANCH" ;;
    *) die "无法定位 MR（源分支 ${SOURCE_BRANCH}）。请确认 MR 处于开启状态，或显式配置 MR_LOCAL_ID/MR_TARGET_BRANCH" ;;
  esac
fi
SHORT_SHA=$(git rev-parse --short HEAD)
MR_LOCATED=1

# --- 3. 安装受信 agent + kiro-cli 能力检查（放在 MR 定位之后：失败用 die_review 回写评论，而不是只让流水线标红）---
# agent 定义里的 prompt 是相对 file:// 引用（kiro 相对 agent 文件所在目录解析），复制到 ~/.kiro/agents/
# 后会失效；kiro_install_agent 在安装时把它改写为集成包内提示词文件的绝对路径。
INSTALLED_AGENT=$(kiro_install_agent "$AGENT_FILE" "$HOME/.kiro/agents") || die_review "受信 agent 安装失败：$AGENT_FILE"
AGENT_NAME=$(basename "$INSTALLED_AGENT" .json)
log "已安装受信 custom agent：${AGENT_NAME}（${INSTALLED_AGENT}；includeMcpJson=false，includePowers=false）"
# --help 在集成包目录下执行：此刻业务库工作树尚未隔离，不在其中运行任何 kiro-cli 子命令
KIRO_CHAT_HELP=$(cd "$PKG_ROOT" && "$TIMEOUT_BIN" 60 kiro-cli chat --help 2>&1 || true)
grep -q -- '--agent-engine' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --agent-engine，无法钉死 ${KIRO_ENGINE} 引擎（ADR-0004：默认引擎不阻断 AGENTS.md 注入），拒绝运行。请升级 kiro-cli（≥ 2.21）"
grep -qE -- '(^|[[:space:]])--agent([[:space:]]|$)' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --agent，无法套用受信只读 agent（拒绝路径、无 MCP/shell/write/web），拒绝运行。请升级 kiro-cli"

# --- 4. 生成 diff（merge-base 三点比较；浅克隆自动加深）---
git fetch -q origin "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}" \
  || die_review "无法 fetch 目标分支 ${TARGET_BRANCH}"
if ! BASE=$(git merge-base "origin/${TARGET_BRANCH}" HEAD 2>/dev/null); then
  log "浅克隆缺少历史，尝试 --unshallow……"
  git fetch -q --unshallow origin 2>/dev/null || true
  BASE=$(git merge-base "origin/${TARGET_BRANCH}" HEAD) || die_review "无法计算 merge-base"
fi
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
truncated=0
build_review_input "$BASE" "HEAD" "$WORK/review.diff" "$WORK/omitted.txt" "$WORK/chunks" || truncated=$?
[[ "$truncated" == "0" || "$truncated" == "10" ]] || die_review "diff 压缩失败（rc=${truncated}）"
if [[ ! -s "$WORK/review.diff" && ! -s "$WORK/omitted.txt" ]]; then
  log "diff 为空，跳过评审。"
  exit 0
fi
log "diff 已生成：$(wc -c < "$WORK/review.diff" | tr -d ' ') 字节（merge-base ${BASE:0:12}..HEAD，$([[ "$truncated" == "10" ]] && echo 已按阈值截断 || echo 完整直传)）"

# --- 5. 组装评审输入 ---
{
  echo "=== 变更元信息 ==="
  echo "源分支: ${SOURCE_BRANCH}"
  echo "目标分支: ${TARGET_BRANCH}"
  echo "Commit: $(git rev-parse HEAD)"
  if [[ "$truncated" == "10" ]]; then
    echo ""
    echo "=== 未直传的变更文件索引（每项 => 后为该文件完整 diff 的本地路径，请用 read 工具读取）==="
    cat "$WORK/omitted.txt"
  fi
  echo ""
  echo "=== DIFF ==="
  cat "$WORK/review.diff"
} > "$WORK/input.txt"

# --- 5.5 工作区隔离：必须在 diff 生成之后、Kiro 启动之前 ---
# 业务库内容一律不受信。下面三类文件 Kiro 会从工作区自动读取，MR 作者可借此操纵评审员：
#   AGENTS.md（任意深度；V3 把子目录 AGENTS.md 也当 steering）、根 lsp.json（可指定任意可执行文件）、
#   .kiro/（MCP/hooks/steering/agents/settings；任意深度——Kiro 是否只看 cwd 下的 .kiro/ 无官方保证，多删无害）。
# 删 .kiro/ 是后面两道措施的前提，不是可选项（kiro-cli 2.21 实测）：
#   ① `.kiro/settings/cli.json`（`settings --workspace` 写入）会覆盖全局设置——业务库放一份
#      {"chat.disableInheritingDefaultResources": false} 就能把下面设置的 true 顶掉；
#   ② `agent list` 显示 Workspace（$CWD/.kiro/agents）优先于 Global（~/.kiro/agents）——业务库放一份
#      .kiro/agents/codeup-reviewer.json 就能顶替受信 agent（拒绝路径、只读工具集全部失效）。
# 所以三道措施的依赖关系是：删 .kiro/ → 全局设置与受信 agent 才可信；删 AGENTS.md 独立于引擎与设置。
# diff 已从 git 对象算好并写入 $WORK，删工作树文件不影响评审输入。
# 用 -iname：大小写不敏感文件系统（macOS/Windows 执行器）上 agents.md 同样会被当作 AGENTS.md 读到。
# 同名目录（如 lsp.json/）不是注入面，但也一并删除：rm -f 遇到目录会失败，让 MR 作者能用一个目录名卡死评审。
: > "$WORK/removed-agents-md.txt"; : > "$WORK/removed-kiro-dirs.txt"
find . -not -path './.git/*' -iname AGENTS.md -not -type d -print -delete >> "$WORK/removed-agents-md.txt" || die_review "隔离失败：无法移除业务库中的 AGENTS.md"
find . -path ./.git -prune -o -name .kiro -type d -print -prune -exec rm -rf {} + >> "$WORK/removed-kiro-dirs.txt" || die_review "隔离失败：无法移除业务库中的 .kiro/"
rm -rf ./.kiro || die_review "隔离失败：无法移除业务库根目录 .kiro"
rm -rf ./lsp.json || die_review "隔离失败：无法移除业务库根目录 lsp.json"
log "隔离：已移除业务库工作树中 $(wc -l < "$WORK/removed-agents-md.txt" | tr -d ' ') 个 AGENTS.md、$(wc -l < "$WORK/removed-kiro-dirs.txt" | tr -d ' ') 个 .kiro/（均任意深度）与根 lsp.json"
# 执行环境：禁止 Kiro 继承工作区默认资源（AGENTS.md/README.md 等），只对 v2 引擎有效（ADR-0004）。
# 它依赖上面对 .kiro/ 的删除（见 ①），本身只覆盖「AGENTS.md 没删干净 / 藏在别处」这一种漏网情形。
# 写入的是执行器 $HOME 的全局设置且刻意不回滚（spec I1）：常驻构建机上它保持为 true 只会更严格。
"$TIMEOUT_BIN" 60 kiro-cli settings chat.disableInheritingDefaultResources true || die_review "隔离失败：无法设置 kiro-cli chat.disableInheritingDefaultResources=true"
log "隔离：已设置 chat.disableInheritingDefaultResources=true"

# --- 6. 执行 Kiro headless 评审（强制超时）---
# --trust-tools 用 V2 短名（read/grep/glob）：kiro-cli 对未知名字静默接受，所以名字靠实测而非 --help
# （--help 示例里的 fs_read/fs_write 已过期：--trust-tools=fs_write 不生效，=write 生效）。三个名字都在 v2
# stream-json 事件的 _meta.kiro.toolName 里实证过（probe-results/kiro-headless/kiro-probe-t01-v2-iso、
# kiro-probe-t01r-toolnames、kiro-probe-t01r-trusttools）。
log "Kiro 引擎：${KIRO_ENGINE}（--agent-engine ${KIRO_ENGINE}；ADR-0004：v1/v3 不阻断 AGENTS.md 注入，不得使用）"
log "开始 Kiro 评审（超时 ${KIRO_TIMEOUT}s）……"
kiro_rc=0
KIRO_LOG_NO_COLOR=1 "$TIMEOUT_BIN" -k 30 "$KIRO_TIMEOUT" kiro-cli chat --no-interactive \
  --agent-engine "$KIRO_ENGINE" --trust-tools=read,grep,glob --agent "$AGENT_NAME" \
  "$(cat "$PROMPT_FILE")" \
  < "$WORK/input.txt" > "$WORK/review-output.md" 2> "$WORK/kiro-stderr.log" || kiro_rc=$?

if [[ "$kiro_rc" -ne 0 ]]; then
  tail -20 "$WORK/kiro-stderr.log" >&2 || true
  [[ "$kiro_rc" == "124" ]] && die_review "Kiro 评审超时（${KIRO_TIMEOUT}s）"
  die_review "Kiro 评审失败（kiro-cli 退出码 ${kiro_rc}）"
fi
[[ -s "$WORK/review-output.md" ]] || die_review "Kiro 退出码为 0 但输出为空"

# --- 6.1 清洗 kiro-cli 输出：剥离 ANSI 控制序列，并从报告锚点截取正文 ---
# headless 模式下 kiro-cli 会把工具调用轨迹（Reading directory / using tool...）
# 和 ANSI 色码一并打到 stdout，需剔除后只保留报告正文。
ESC=$(printf '\033')
sed "s/${ESC}\\[[0-9;?]*[a-zA-Z]//g" "$WORK/review-output.md" > "$WORK/clean.md"
# 报告正文以一级标题「# 代码评审报告」为锚点（见 prompts/review-prompt.md 第 9 条）；
# kiro-cli 可能给锚点行加 Markdown 引用前缀（如 "> # 代码评审报告"），故锚点允许
# 行首出现「> 」「#」「空白」等前缀字符。找到则从该行截到结尾（并去掉锚点行的引用前缀），
# 找不到则降级保留清洗后全文（不丢内容）。
if grep -qE '^[[:space:]>#]*# 代码评审报告' "$WORK/clean.md"; then
  awk '/^[[:space:]>#]*# 代码评审报告/{f=1} f' "$WORK/clean.md" \
    | sed '1s/^[[:space:]>]*//' > "$WORK/report.md"
else
  cp "$WORK/clean.md" "$WORK/report.md"
  log "警告：未找到报告标题锚点「# 代码评审报告」，回退保留清洗后全文（可能含过程轨迹）"
fi
[[ -s "$WORK/report.md" ]] || die_review "清洗后报告为空"

# --- 7. 组装评论（含标记与截断）并回写 ---
DIFF_NOTE="完整直传"
[[ "$truncated" == "10" ]] && DIFF_NOTE="超出阈值（${DIFF_SIZE_LIMIT}B）已按优先级截断，其余变更 Kiro 通过 diff 索引自主读取"
{
  echo "## 🤖 Kiro 自动代码评审"
  echo ""
  echo "<!-- kiro-review:${SHORT_SHA} -->"
  echo ""
  echo "| 项 | 值 |"
  echo "|---|---|"
  echo "| Commit | \`${SHORT_SHA}\` |"
  echo "| 分支 | \`${SOURCE_BRANCH}\` → \`${TARGET_BRANCH}\` |"
  echo "| 时间 | $(date '+%Y-%m-%d %H:%M:%S') |"
  echo "| diff | ${DIFF_NOTE} |"
  echo ""
  echo "---"
  echo ""
  cat "$WORK/report.md"
} > "$WORK/comment.md"

# Codeup content 上限 65535 字符；按字节截断留足余量，iconv 清理截断产生的残缺 UTF-8 序列
if [[ "$(wc -c < "$WORK/comment.md" | tr -d ' ')" -gt "$MAX_COMMENT_BYTES" ]]; then
  head -c "$MAX_COMMENT_BYTES" "$WORK/comment.md" | iconv -f UTF-8 -t UTF-8 -c > "$WORK/comment.trunc.md" || \
    head -c "$MAX_COMMENT_BYTES" "$WORK/comment.md" > "$WORK/comment.trunc.md"
  {
    echo ""
    echo "> ⚠️ 报告超长已截断（上限 ${MAX_COMMENT_BYTES} 字节），完整内容见流水线日志。"
  } >> "$WORK/comment.trunc.md"
  mv "$WORK/comment.trunc.md" "$WORK/comment.md"
  log "评审报告超长已截断；完整内容如下："
  cat "$WORK/report.md" >&2
fi

if codeup_post_comment "$LOCAL_ID" "$WORK/comment.md"; then
  log "评审完成，已回写 MR #${LOCAL_ID}"
else
  log "OpenAPI 回写失败（已按策略重试）。评审结果如下："
  cat "$WORK/comment.md" >&2
  exit 1
fi
