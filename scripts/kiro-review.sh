#!/usr/bin/env bash
# Codeup MR 自动 Kiro 评审 — 主编排脚本。
# 安全前提：本脚本必须从受信集成包仓库（流水线独立代码源，固定分支/tag）执行，
# 绝不从被评审的业务仓库源分支执行（源分支可被 MR 作者任意修改）。
# 业务仓库 checkout 目录由 REVIEW_REPO_DIR 指定，仅作为被分析数据；其中的 AGENTS.md/lsp.json/.kiro/
# 在 diff 生成之后、Kiro 启动之前被移除（第 5.5 步），Kiro 固定以 v2 引擎运行（ADR-0004）。
# 输出契约：Kiro 以 --output-format stream-json 输出事件流，评审报告是 runFinished.data.finalText 里
# 由 <<<KIRO_REVIEW_JSON>>> 包裹的一段 JSON；汇总评论由 scripts/lib/review-render.sh 渲染。
# 退出码：0=评审完成并回写；非 0=失败（不卡合并，仅流水线标红）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# -P 解析掉符号链接：两侧都用物理路径，下面的「REVIEW_REPO_DIR 不得指向集成包自身」比较才拦得住
# `ln -s <集成包> /tmp/link; REVIEW_REPO_DIR=/tmp/link` 这种绕过（R10①）
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
source "${SCRIPT_DIR}/lib/codeup-api.sh"
source "${SCRIPT_DIR}/lib/diff-compress.sh"
source "${SCRIPT_DIR}/lib/kiro-agent.sh"
source "${SCRIPT_DIR}/lib/review-render.sh"

KIRO_TIMEOUT="${KIRO_TIMEOUT:-900}"
MAX_COMMENT_BYTES="${MAX_COMMENT_BYTES:-60000}"
# 行内评论开关（spec §4.6）。本版本只实现 INLINE_COMMENT=0：MR 上仍然只有一条汇总评论，
# 内含按 P0→P1→P2 分组的完整问题清单。1 的渲染与发布属后续票，这里显式拒绝而不是静默按 0 跑，
# 否则开关看起来生效了、实际什么也没发生。
INLINE_COMMENT="${INLINE_COMMENT:-0}"
# 第几次评审。原地更新汇总评论、维护「历次评审」表属后续票；本版本每次都是新评论，固定为 1。
REVIEW_RUN=1
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
      # 标题与标记必须与成功/降级评论同形：后续票要靠 `<!-- kiro-review:<sha> run:N -->` 找到
      # 自己那条评论做原地更新，失败评论用另一种标记就会被漏掉；两种标题也会让 MR 上出现两个产品名。
      echo "## 🤖 Kiro 代码评审 · ⚠️ 评审未完成"
      echo "<!-- kiro-review:${SHORT_SHA:-unknown} run:${REVIEW_RUN} -->"
      echo ""
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
REVIEW_REPO_DIR=$(cd "$REVIEW_REPO_DIR" >/dev/null 2>&1 && pwd -P) || die "REVIEW_REPO_DIR 不存在或不可进入：${REVIEW_REPO_DIR}"
# 第 5.5 步会删掉业务库工作树里的 AGENTS.md/.kiro/lsp.json，而 DRY_RUN 并不拦删除：
# 本地把集成包自身（或它的上级目录）误当业务库跑，会把集成包自己的文件删掉，直接拒绝。
[[ "$PKG_ROOT" != "$REVIEW_REPO_DIR" && "$PKG_ROOT" != "$REVIEW_REPO_DIR"/* && "$REVIEW_REPO_DIR" != "$PKG_ROOT"/* ]] \
  || die "REVIEW_REPO_DIR（${REVIEW_REPO_DIR}）与集成包（${PKG_ROOT}）互相包含，拒绝运行：隔离步骤会删除集成包内的文件"
[[ -d "$REVIEW_REPO_DIR/.git" ]] || die "REVIEW_REPO_DIR 不是 git 仓库：$REVIEW_REPO_DIR"
[[ -r "$PROMPT_FILE" ]] || die "评审提示词文件不可读：$PROMPT_FILE"
[[ -r "$AGENT_FILE" ]] || die "custom agent 配置文件不可读：$AGENT_FILE"

cd "$REVIEW_REPO_DIR"

# --- 1. 定位 MR（放在最前面：此后任何失败都能回写「评审未完成」评论，spec I10 失败可见。
#        定位只需要 git 与 Codeup OpenAPI，不需要 kiro-cli，所以安装排在它后面）---
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

# --- 2. 安装/检测 kiro-cli（失败用 die_review：网络受限的构建机上这是最常见的失败，
#        原来用 die 会让 MR 上什么都看不到、只有流水线标红，违反 I10）---
if ! command -v kiro-cli >/dev/null; then
  log "kiro-cli 不存在，尝试安装（云托管构建机场景）……"
  curl -fsSL --connect-timeout 10 --max-time 300 "$KIRO_INSTALL_URL" | bash \
    || die_review "kiro-cli 安装失败。网络受限时请使用自建构建机预装固定版本，或配置 HTTP_PROXY/HTTPS_PROXY（见 pipeline/setup-guide.md）"
  command -v kiro-cli >/dev/null || export PATH="$HOME/.local/bin:$PATH"
  command -v kiro-cli >/dev/null || die_review "安装后仍找不到 kiro-cli，请检查安装日志中的 PATH 提示"
fi

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
# 结构化输出契约完全依赖 stream-json（报告从 runFinished.data.finalText 取）。不预检的话，
# 不支持该参数的版本会先把额度烧掉、再以 clap 退出码 2 失败，MR 上只剩「退出码 2」这种不可行动的信息。
grep -q -- '--output-format' <<<"$KIRO_CHAT_HELP" \
  || die_review "kiro-cli chat 不支持 --output-format，无法取得结构化评审报告（契约在 runFinished.data.finalText 里），拒绝运行。请升级 kiro-cli（≥ 2.21）"
# 开关校验放在 MR 定位之后：配错开关也要在 MR 上看得见，而不是只让流水线标红
[[ "$INLINE_COMMENT" == "0" ]] \
  || die_review "INLINE_COMMENT=${INLINE_COMMENT} 尚未实现（行内评论属后续票），当前版本只支持 INLINE_COMMENT=0。请把该流水线变量改回 0 或删除"

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
# `\( -type d -o -type l \)`：`.kiro` 也可能是指向别处的**符号链接**（R10②）。原来只匹配 -type d，
# 业务库提交 `src/sub/.kiro -> ../../evilcfg` 就能让一份工作区配置在隔离之后依然可读。
find . -path ./.git -prune -o -name .kiro \( -type d -o -type l \) -print -prune -exec rm -rf {} + >> "$WORK/removed-kiro-dirs.txt" || die_review "隔离失败：无法移除业务库中的 .kiro/"
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
# --output-format stream-json 只在 v2/v3 引擎上被接受（v1 直接报错），结构化输出契约依赖它：
# 评审报告要从 runFinished.data.finalText 里取（spec §4.1、§4.7.1 P1-08）。
# 本次运行的契约标记随机串。固定字面量标记可被业务库利用：提示词要求把注入企图作为 P0 报出来，
# 模型常常直接原文引用那行标记，标记计数变 2 → 每次评审都降级。nonce 让攻击者无法预先提交。
REVIEW_NONCE=$(review_new_nonce)
[[ "$REVIEW_NONCE" =~ ^[0-9a-f]{16}$ ]] || die_review "生成契约标记随机串失败（得到：${REVIEW_NONCE}）"
grep -q '{{REVIEW_NONCE}}' "$PROMPT_FILE" \
  || die_review "运行时提示词缺少 {{REVIEW_NONCE}} 占位符：模型拿不到本次标记，每次评审都会降级。请同步更新 ${PROMPT_FILE}"
sed "s/{{REVIEW_NONCE}}/${REVIEW_NONCE}/g" "$PROMPT_FILE" > "$WORK/prompt.txt" \
  || die_review "运行时提示词渲染失败"
# 只打随机串、不打完整标记：日志里出现标记字面量会干扰「评论/日志里不该有契约标记」这类断言，
# 排查时有随机串就够了（标记模板是固定的）。
log "本次契约标记随机串：${REVIEW_NONCE}"

log "Kiro 引擎：${KIRO_ENGINE}（--agent-engine ${KIRO_ENGINE}；ADR-0004：v1/v3 不阻断 AGENTS.md 注入，不得使用）"
log "开始 Kiro 评审（超时 ${KIRO_TIMEOUT}s，输出格式 stream-json）……"
kiro_rc=0
KIRO_LOG_NO_COLOR=1 "$TIMEOUT_BIN" -k 30 "$KIRO_TIMEOUT" kiro-cli chat --no-interactive \
  --agent-engine "$KIRO_ENGINE" --output-format stream-json \
  --trust-tools=read,grep,glob --agent "$AGENT_NAME" \
  "$(cat "$WORK/prompt.txt")" \
  < "$WORK/input.txt" > "$WORK/stream.jsonl" 2> "$WORK/kiro-stderr.log" || kiro_rc=$?

if [[ "$kiro_rc" -ne 0 ]]; then
  tail -20 "$WORK/kiro-stderr.log" >&2 || true
  [[ "$kiro_rc" == "124" ]] && die_review "Kiro 评审超时（${KIRO_TIMEOUT}s）"
  die_review "Kiro 评审失败（kiro-cli 退出码 ${kiro_rc}）"
fi
[[ -s "$WORK/stream.jsonl" ]] || die_review "Kiro 退出码为 0 但事件流为空"

# --- 6.1 成本与上下文可观测指标写流水线日志（spec §4.1：metadata.meteringUsage 作为成本指标）---
# 阿里云侧开发者看不到 CloudWatch，用量只能靠流水线日志留痕；取不到时打 - 而不是让评审失败。
log "Kiro 用量：$(review_stream_usage "$WORK/stream.jsonl")"

# --- 6.2 提取契约 JSON ---
# rc 2/3 是「Kiro 没跑完 / 自报失败」——不是解析问题，走既有失败评论路径。
# rc 4/5 是「跑完了但输出不合契约」——评审已产出，降级为贴出原文（退出码仍为 0）。
extract_rc=0
review_extract_json "$WORK/stream.jsonl" "$REVIEW_NONCE" > "$WORK/contract.json" || extract_rc=$?
case "$extract_rc" in
  2) die_review "Kiro 事件流中没有 runFinished 事件（评审未跑完；确认 --agent-engine ${KIRO_ENGINE} 与 --output-format stream-json 被接受）" ;;
  3) die_review "Kiro 自报运行失败（runFinished.status=$(tr -d '\n' < "$WORK/contract.json")）" ;;
  # rc 7/8 是本地故障，绝不能和「被评审代码里有假标记」（rc 6）共用一个文案
  7) die_review "读不到 Kiro 事件流文件（本地 I/O 故障，不是评审内容问题）：${WORK}/stream.jsonl" ;;
  8) die_review "内部错误：提取契约时没有传入本次标记随机串（集成包缺陷，请报告）" ;;
esac

DEGRADE_REASON=""
case "$extract_rc" in
  0) ;;
  4) DEGRADE_REASON="评审员输出中没有成对的 <<<KIRO_REVIEW_JSON>>> 契约标记" ;;
  5) DEGRADE_REASON="契约标记内不是恰好一个 JSON 对象" ;;
  6) DEGRADE_REASON="输出里出现多于一对契约标记（很可能是被评审代码里的假标记被评审员原文引用），无法判定哪一段是评审结果" ;;
  *) DEGRADE_REASON="提取契约 JSON 失败（rc=${extract_rc}）" ;;
esac
# kiro-cli 自己截断了最终消息时，契约必然缺尾巴。不点明这一点，运维只会照着评论里的
# 「重跑评审」提示一遍遍重跑同一个必然失败的评审。
if [[ -n "$DEGRADE_REASON" ]] && review_stream_final_truncated "$WORK/stream.jsonl"; then
  DEGRADE_REASON="${DEGRADE_REASON}；且 kiro-cli 标记 finalTextTruncated=true（最终消息被其自身截断，重跑同样会截断，需要缩小 diff 或调高 kiro-cli 输出上限）"
fi

# --- 6.3 字段校验：不合契约的问题丢弃并计数 ---
if [[ -z "$DEGRADE_REASON" ]]; then
  validate_rc=0
  review_validate < "$WORK/contract.json" > "$WORK/validated.json" 2> "$WORK/validate-err.log" || validate_rc=$?
  case "$validate_rc" in
    0) ;;
    # 受信 agent 未生效：contract 字段只在 agent 提示词里要求，缺了就说明模型拿的是裸提示词——
    # 拒绝路径与掩码规则都没生效，这份输出不能贴到 MR 上，所以走失败评论而不是降级。
    3) die_review "受信 agent 未生效：评审输出缺少 contract=\"${REVIEW_CONTRACT_ID}\" 标识（只在受信 agent 提示词里要求）。这份输出不是受信只读 agent 的产出，已拒绝回写其内容。请检查 ${AGENT_FILE} 的安装与 --agent ${AGENT_NAME} 是否生效" ;;
    *) DEGRADE_REASON="契约 JSON 顶层结构不符（$(tail -1 "$WORK/validate-err.log")）" ;;
  esac
fi

# --- 7. 渲染汇总评论并回写 ---
DIFF_NOTE="完整直传"
[[ "$truncated" == "10" ]] && DIFF_NOTE="超出阈值（${DIFF_SIZE_LIMIT}B）已按优先级截断，其余变更 Kiro 通过 diff 索引自主读取"
REVIEW_TS=$(date '+%Y-%m-%d %H:%M:%S')
render_args=(--sha "$SHORT_SHA" --src "$SOURCE_BRANCH" --dst "$TARGET_BRANCH"
             --ts "$REVIEW_TS" --diff-note "$DIFF_NOTE" --run "$REVIEW_RUN")

if [[ -n "$DEGRADE_REASON" ]]; then
  # 降级：评审已经产出、只是没按契约输出——贴清洗后的原文并在标题标明，退出码仍为 0。
  log "警告：结构化解析失败（${DEGRADE_REASON}），降级为贴出评审员输出原文"
  final_rc=0
  review_stream_final_text "$WORK/stream.jsonl" > "$WORK/final.txt" || final_rc=$?
  [[ "$final_rc" == "0" ]] || die_review "结构化解析失败，且取评审员原文也失败（rc=${final_rc}）"
  review_clean_text < "$WORK/final.txt" > "$WORK/raw.md"
  [[ -s "$WORK/raw.md" ]] || die_review "结构化解析失败，且评审员输出为空"
  review_render_degraded --text "$WORK/raw.md" --reason "$DEGRADE_REASON" "${render_args[@]}" \
    > "$WORK/comment.md" || die_review "降级评论渲染失败"
else
  dropped=$(jq -r '.dropped_findings' "$WORK/validated.json")
  delocated=$(jq -r '.delocated_findings' "$WORK/validated.json")
  [[ "$dropped" == "0" ]] \
    || log "警告：${dropped} 条问题不符合输出契约已丢弃（级别不在 P0/P1/P2，或缺 title/body）"
  [[ "$delocated" == "0" ]] \
    || log "警告：${delocated} 条问题的 file 含换行/竖线/反引号，已按未定位处理（这类值会破坏表格与定位串）"
  log "评审报告：P0 $(jq -r '[.findings[] | select(.severity == "P0")] | length' "$WORK/validated.json") · P1 $(jq -r '[.findings[] | select(.severity == "P1")] | length' "$WORK/validated.json") · P2 $(jq -r '[.findings[] | select(.severity == "P2")] | length' "$WORK/validated.json")，结论 $(jq -r '.verdict' "$WORK/validated.json")，丢弃 ${dropped}"
  review_render_summary --json "$WORK/validated.json" --inline-comment "$INLINE_COMMENT" "${render_args[@]}" \
    > "$WORK/comment.md" || die_review "汇总评论渲染失败"
fi
[[ -s "$WORK/comment.md" ]] || die_review "渲染后的评论为空"

# Codeup content 上限 65535 字符；按字节截断留足余量，iconv 清理截断产生的残缺 UTF-8 序列
if [[ "$(wc -c < "$WORK/comment.md" | tr -d ' ')" -gt "$MAX_COMMENT_BYTES" ]]; then
  cp "$WORK/comment.md" "$WORK/comment.full.md"
  head -c "$MAX_COMMENT_BYTES" "$WORK/comment.md" | iconv -f UTF-8 -t UTF-8 -c > "$WORK/comment.trunc.md" || \
    head -c "$MAX_COMMENT_BYTES" "$WORK/comment.md" > "$WORK/comment.trunc.md"
  # 按字节截断几乎总是切在行中间：先补一个换行，否则后面追加的内容会接在那半行后面——
  # 闭合围栏不在行首就不起作用（实测截断后得到的是 `    row_2 = fetc``` `，围栏没闭合）。
  [[ $(tail -c1 "$WORK/comment.trunc.md" | wc -l | tr -d ' ') -eq 1 ]] || printf '\n' >> "$WORK/comment.trunc.md"
  # fix 字段里会带 ```代码块```：截断点落在围栏中间时，随后追加的截断提示会被 Markdown 当成
  # 代码块内容渲染掉，读者只看到评论突然结束、完全看不到「已截断」。所以先补闭合围栏，再写提示。
  if [[ $(( $(grep -c '^```' "$WORK/comment.trunc.md" || true) % 2 )) -eq 1 ]]; then
    echo '```' >> "$WORK/comment.trunc.md"
  fi
  {
    echo ""
    echo "> ⚠️ 报告超长已截断（上限 ${MAX_COMMENT_BYTES} 字节），完整内容见流水线日志。"
  } >> "$WORK/comment.trunc.md"
  mv "$WORK/comment.trunc.md" "$WORK/comment.md"
  log "评审报告超长已截断；完整内容如下："
  cat "$WORK/comment.full.md" >&2
fi

if codeup_post_comment "$LOCAL_ID" "$WORK/comment.md"; then
  log "评审完成，已回写 MR #${LOCAL_ID}"
else
  log "OpenAPI 回写失败（已按策略重试）。评审结果如下："
  cat "$WORK/comment.md" >&2
  exit 1
fi
