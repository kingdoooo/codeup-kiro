#!/usr/bin/env bash
# Codeup MR 自动 Kiro 评审 — 主编排脚本。
# 安全前提：本脚本必须从受信集成包仓库（流水线独立代码源，固定分支/tag）执行，
# 绝不从被评审的业务仓库源分支执行（源分支可被 MR 作者任意修改）。
# 业务仓库 checkout 目录由 REVIEW_REPO_DIR 指定，仅作为被分析数据。
# 退出码：0=评审完成并回写；非 0=失败（不卡合并，仅流水线标红）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/codeup-api.sh"
source "${SCRIPT_DIR}/lib/diff-compress.sh"

KIRO_TIMEOUT="${KIRO_TIMEOUT:-900}"
MAX_COMMENT_BYTES="${MAX_COMMENT_BYTES:-60000}"
# 官方安装脚本 URL。来源：https://kiro.dev/docs/cli/installation/（页面命令
# `curl -fsSL https://cli.kiro.dev/install | bash`；脚本本身支持 Linux/macOS，
# Linux 下安装到 ~/.local/bin，含 glibc 检测与 musl 回退）。核实日期：2026-07-21。
KIRO_INSTALL_URL="${KIRO_INSTALL_URL:-https://cli.kiro.dev/install}"
PROMPT_FILE="${PROMPT_FILE:-${PKG_ROOT}/prompts/review-prompt.md}"
AGENT_FILE="${PKG_ROOT}/kiro/agent-codeup-reviewer.json"
REVIEW_REPO_DIR="${REVIEW_REPO_DIR:-$PWD}"

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
  command -v "$cmd" >/dev/null || die "缺少依赖：$cmd（请在构建机安装）"
done
TIMEOUT_BIN=""
command -v timeout >/dev/null && TIMEOUT_BIN=timeout
[[ -z "$TIMEOUT_BIN" ]] && command -v gtimeout >/dev/null && TIMEOUT_BIN=gtimeout
[[ -n "$TIMEOUT_BIN" ]] || die "缺少依赖：timeout/gtimeout（GNU coreutils）。无超时能力时 Kiro 挂起会永久占用流水线，拒绝运行"
: "${KIRO_API_KEY:?缺少 KIRO_API_KEY}"
: "${YUNXIAO_TOKEN:?缺少 YUNXIAO_TOKEN}"
: "${YUNXIAO_ORG_ID:?缺少 YUNXIAO_ORG_ID}"
: "${CODEUP_REPO_ID:?缺少 CODEUP_REPO_ID}"
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

# --- 2. 工作区隔离：移除业务仓库的 .kiro/（MCP/hooks/steering 注入面）+ 安装受信 agent ---
if [[ -d "$REVIEW_REPO_DIR/.kiro" ]]; then
  log "移除业务仓库工作区 .kiro/ 目录（不受信内容）"
  rm -rf "$REVIEW_REPO_DIR/.kiro"
fi
mkdir -p "$HOME/.kiro/agents"
cp "$AGENT_FILE" "$HOME/.kiro/agents/"
AGENT_ARGS=()
if kiro-cli chat --help 2>&1 | grep -q -- '--agent'; then
  AGENT_ARGS=(--agent codeup-reviewer)
  log "使用受信 custom agent：codeup-reviewer（includeMcpJson=false）"
else
  log "警告：kiro-cli chat 不支持 --agent，降级为 .kiro 移除 + --trust-tools 两层缓解"
fi

cd "$REVIEW_REPO_DIR"

# --- 3. 定位 MR ---
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
[[ "$truncated" == "0" || "$truncated" == "10" ]] || die_review "diff 压缩失败（rc=$truncated）"
if [[ ! -s "$WORK/review.diff" && ! -s "$WORK/omitted.txt" ]]; then
  log "diff 为空，跳过评审。"
  exit 0
fi

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

# --- 6. 执行 Kiro headless 评审（强制超时）---
log "开始 Kiro 评审（超时 ${KIRO_TIMEOUT}s）……"
kiro_rc=0
KIRO_LOG_NO_COLOR=1 "$TIMEOUT_BIN" -k 30 "$KIRO_TIMEOUT" kiro-cli chat --no-interactive \
  --trust-tools=read,grep "${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}" \
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
