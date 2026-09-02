#!/usr/bin/env bash
# 探测 Flow CreatePipelineRun 的 envs / runningBranchs 是否能覆写到 kiro-review.sh 读取的变量（spec P1-07）。
# 这是 AWS 档位调度器（Lambda → CreatePipelineRun）可行性的前提。
#
# 必填环境变量：
#   YUNXIAO_TOKEN 或 YUNXIAO_TOKEN_FILE   令牌需「流水线（读写）」
#   YUNXIAO_ORG_ID  FLOW_PIPELINE_ID
#   BUSINESS_REPO_URL   与流水线代码源 endpoint 完全一致的仓库地址（作为 runningBranchs 的 key）
#   SOURCE_BRANCH  MR_LOCAL_ID  MR_TARGET_BRANCH
#
# 运行后到 Flow 运行日志里核对：
#   1) 业务库 checkout 的分支 == SOURCE_BRANCH
#   2) 日志出现「[kiro-review] 使用环境变量指定的 MR：#<MR_LOCAL_ID>」（说明 envs 覆写生效）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/codeup-api.sh
source "${SCRIPT_DIR}/../lib/codeup-api.sh"

if [[ -z "${YUNXIAO_TOKEN:-}" && -n "${YUNXIAO_TOKEN_FILE:-}" ]]; then
  YUNXIAO_TOKEN=$(tr -d '\r\n' < "$YUNXIAO_TOKEN_FILE"); export YUNXIAO_TOKEN
fi
: "${YUNXIAO_TOKEN:?缺少 YUNXIAO_TOKEN（或 YUNXIAO_TOKEN_FILE）}"
: "${YUNXIAO_ORG_ID:?}" "${FLOW_PIPELINE_ID:?}" "${BUSINESS_REPO_URL:?}" "${SOURCE_BRANCH:?}" "${MR_LOCAL_ID:?}" "${MR_TARGET_BRANCH:?}"
command -v jq >/dev/null || { echo "缺少依赖：jq" >&2; exit 1; }

# params 是「JSON 字符串」字段，不是嵌套对象（见 CreatePipelineRun 文档）
PARAMS=$(jq -cn --arg url "$BUSINESS_REPO_URL" --arg src "$SOURCE_BRANCH" --arg id "$MR_LOCAL_ID" --arg tgt "$MR_TARGET_BRANCH" \
  '{envs:{MR_LOCAL_ID:$id, MR_TARGET_BRANCH:$tgt, CI_COMMIT_REF_NAME:$src, PROBE_MARKER:"codeup-kiro-flow-run-probe"},
    runningBranchs:{($url):$src},
    comment:"codeup-kiro probe P1-07: envs/runningBranchs 覆写"}')
BODY=$(jq -cn --arg p "$PARAMS" '{params:$p}')

echo "[probe] POST pipelines/${FLOW_PIPELINE_ID}/runs" >&2
echo "[probe] params: $PARAMS" >&2
tmp=$(mktemp)
_codeup_request POST "/oapi/v1/flow/organizations/${YUNXIAO_ORG_ID}/pipelines/${FLOW_PIPELINE_ID}/runs" "$BODY" > "$tmp"
RESP=$(cat "$tmp"); rm -f "$tmp"

if _codeup_http_ok "$CODEUP_HTTP_CODE"; then
  echo "[P1-07 ] PASS    CreatePipelineRun HTTP ${CODEUP_HTTP_CODE}，运行编号：${RESP}" >&2
  echo "[probe] 下一步：打开该次运行的日志，核对 checkout 分支与「使用环境变量指定的 MR：#${MR_LOCAL_ID}」" >&2
else
  echo "[P1-07 ] FAIL    HTTP ${CODEUP_HTTP_CODE}: $(cut -c1-300 <<<"$RESP")" >&2
  exit 1
fi
