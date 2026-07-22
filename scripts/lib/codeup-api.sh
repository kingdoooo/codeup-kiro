#!/usr/bin/env bash
# Codeup OpenAPI（中心站）薄封装。
# 成功判定以 HTTP 状态码为准（官方响应体形态在不同接口间不一致：
# ListChangeRequests 为 camelCase 对象，CreateChangeRequestComment 为 snake_case 数组），
# 因此不解析响应体判断成败。
# 依赖环境变量：YUNXIAO_TOKEN, YUNXIAO_ORG_ID, CODEUP_REPO_ID
# DRY_RUN=1 时只打印请求到 stderr，行为等同 HTTP 200。

CODEUP_API_BASE="${CODEUP_API_BASE:-https://openapi-rdc.aliyuncs.com}"

_codeup_http_ok() { [[ "$1" -ge 200 && "$1" -lt 300 ]]; }

# 仅传输错误(000)/429/5xx 可重试；其余 4xx 是确定性失败（POST 非幂等，盲目重试会重复发评论）
_codeup_should_retry() { [[ "$1" == "000" || "$1" == "429" || "$1" -ge 500 ]]; }

# method path [body] → stdout=响应体；全局 CODEUP_HTTP_CODE=状态码（传输失败=000）
_codeup_request() {
  local method="$1" path="$2" body="${3:-}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "DRY_RUN ${method} ${CODEUP_API_BASE}${path}" >&2
    [[ -n "$body" ]] && echo "DRY_RUN body: ${body}" >&2
    CODEUP_HTTP_CODE=200
    echo '[]'
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  CODEUP_HTTP_CODE=$(curl -sS -o "$tmp" -w '%{http_code}' \
    --connect-timeout 10 --max-time 60 \
    -X "$method" \
    -H "Content-Type: application/json" \
    -H "x-yunxiao-token: ${YUNXIAO_TOKEN}" \
    ${body:+--data "$body"} \
    "${CODEUP_API_BASE}${path}" 2>/dev/null) || CODEUP_HTTP_CODE=000
  cat "$tmp"; rm -f "$tmp"
}

# stdin: ListChangeRequests 响应；$1=源分支
# stdout: 每个匹配一行 "localId<TAB>targetBranch"（保持服务端 updated_at 降序）
codeup_parse_mr() {
  jq -r --arg src "$1" '
    (if type == "object" then (.result // []) else . end)
    | map(select(.sourceBranch == $src))
    | .[] | "\(.localId)\t\(.targetBranch)"'
}

# $1=源分支。rc 0=唯一匹配（stdout 一行）；2=无匹配；3=歧义（stdout 全部候选）
codeup_find_mr() {
  local src="$1" page=1 matches="" resp page_out resp_tmp
  while [[ "$page" -le 5 ]]; do
    # 不能用 resp=$(...)：命令替换在子 shell 里跑，CODEUP_HTTP_CODE 传不回来
    resp_tmp=$(mktemp)
    _codeup_request GET \
      "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/changeRequests?projectIds=${CODEUP_REPO_ID}&state=opened&orderBy=updated_at&sort=desc&page=${page}&perPage=100" \
      > "$resp_tmp"
    resp=$(cat "$resp_tmp"); rm -f "$resp_tmp"
    if ! _codeup_http_ok "$CODEUP_HTTP_CODE"; then
      # 与「真无匹配」区分开：HTTP 失败必须留痕，否则上层只报「无法定位 MR」误导排查
      echo "codeup_find_mr: ListChangeRequests 调用失败（HTTP ${CODEUP_HTTP_CODE}）" >&2
      return 2
    fi
    page_out=$(printf '%s' "$resp" | codeup_parse_mr "$src")
    [[ -n "$page_out" ]] && matches="${matches}${matches:+$'\n'}${page_out}"
    # 该页结果数不足 100 说明已到末页
    local count
    count=$(printf '%s' "$resp" | jq -r 'if type == "object" then (.result // []) else . end | length')
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
  [[ -z "$matches" ]] && return 2
  printf '%s\n' "$matches"
  [[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" == "1" ]] && return 0
  return 3
}

# $1=localId $2=Markdown 文件路径。HTTP 2xx=成功；可重试类失败重试至多 2 次。
codeup_post_comment() {
  local local_id="$1" markdown_file="$2"
  local body attempt
  body=$(jq -n --rawfile content "$markdown_file" \
    '{comment_type: "GLOBAL_COMMENT", content: $content, draft: false}')
  for attempt in 1 2 3; do
    _codeup_request POST \
      "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments" \
      "$body" >/dev/null
    _codeup_http_ok "$CODEUP_HTTP_CODE" && return 0
    if ! _codeup_should_retry "$CODEUP_HTTP_CODE"; then
      echo "codeup_post_comment: HTTP ${CODEUP_HTTP_CODE}，确定性失败不重试" >&2
      return 1
    fi
    echo "codeup_post_comment: HTTP ${CODEUP_HTTP_CODE}，第 ${attempt} 次尝试失败" >&2
    [[ "$attempt" -lt 3 ]] && sleep $((attempt * 5))
  done
  return 1
}
