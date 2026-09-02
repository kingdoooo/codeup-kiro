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

# 重试退避。CODEUP_RETRY_BACKOFF=0 关掉睡眠，供测试真正跑一遍重试循环
# （否则每条重试路径的负向测试都要等 15 秒，结果就是没人写这类测试）。
_codeup_retry_sleep() {
  local secs=$(( $1 * ${CODEUP_RETRY_BACKOFF:-5} ))
  [[ "$secs" -gt 0 ]] && sleep "$secs"
  return 0
}

# --- DRY_RUN 的响应注入：按「方法 + 路径特征」给请求起一个 route 名 ---
# DRY_RUN 下默认一律返回 `[]`（票 01/02 的测试依赖这个），但「先查旧评论再决定更新还是新建」
# 这类逻辑必须能在 DRY_RUN 下喂进不同的列表响应，否则只能在真实 Codeup 上验证。
# 机制：DRY_RUN_FIXTURE_DIR/<route>.json 存在就用它当响应体；不存在仍是 `[]`（向后兼容）。
# 另有 DRY_RUN_FAIL_ROUTES="<route>:<code>,…" 注入 HTTP 状态码，用来测重试与失败退回。
_codeup_route_name() {
  local method="$1" path="$2"
  case "${method}:${path}" in
    GET:/oapi/v1/platform/user) echo platform-user ;;
    # list 必须排在 create 前面：两者都是 POST 且路径前缀相同
    POST:*/comments/list)       echo list-comments ;;
    POST:*/comments)            echo create-comment ;;
    PUT:*/comments/*)           echo update-comment ;;
    DELETE:*/comments/*)        echo delete-comment ;;
    GET:*/changeRequests\?*)    echo list-change-requests ;;
    GET:*/diffs/patches)        echo list-patchsets ;;
    *)                          echo other ;;
  esac
}

# method path [body] → stdout=响应体；全局 CODEUP_HTTP_CODE=状态码（传输失败=000）
_codeup_request() {
  local method="$1" path="$2" body="${3:-}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    local route pair fixture
    route=$(_codeup_route_name "$method" "$path")
    echo "DRY_RUN ${method} ${CODEUP_API_BASE}${path}" >&2
    [[ -n "$body" ]] && echo "DRY_RUN body: ${body}" >&2
    CODEUP_HTTP_CODE=200
    for pair in $(printf '%s' "${DRY_RUN_FAIL_ROUTES:-}" | tr ',' ' '); do
      [[ "${pair%%:*}" == "$route" ]] || continue
      CODEUP_HTTP_CODE="${pair##*:}"
      echo "DRY_RUN 注入失败：route=${route} HTTP ${CODEUP_HTTP_CODE}" >&2
      echo '{}'
      return 0
    done
    fixture="${DRY_RUN_FIXTURE_DIR:-}/${route}.json"
    if [[ -n "${DRY_RUN_FIXTURE_DIR:-}" && -r "$fixture" ]]; then
      echo "DRY_RUN 响应取自 fixture：${fixture}" >&2
      cat "$fixture"
    else
      echo '[]'
    fi
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
  local body attempt tmp author
  # 注意：中心站 CreateChangeRequestComment 要求 resolved 字段必填（缺失报 400 "resolved can not be null"）
  body=$(jq -n --rawfile content "$markdown_file" \
    '{comment_type: "GLOBAL_COMMENT", content: $content, draft: false, resolved: false}')
  for attempt in 1 2 3; do
    # 不能用 $(...) 包住 _codeup_request：命令替换在子 shell 里跑，CODEUP_HTTP_CODE 传不回来
    tmp=$(mktemp)
    _codeup_request POST \
      "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments" \
      "$body" > "$tmp"
    if _codeup_http_ok "$CODEUP_HTTP_CODE"; then
      # 新建评论的响应里带 author.username，这就是本机器人账号的用户名。令牌身份接口实测 403
      # （spec §4.7.1 P1-00），所以这条日志是运维拿到 CODEUP_BOT_USERNAME 取值的实用途径。
      author=$(jq -r 'if type == "object" then (.author.username // "") else "" end' "$tmp" 2>/dev/null || echo "")
      [[ -n "$author" ]] \
        && echo "codeup_post_comment: 新建评论的作者用户名=${author}（可据此配置 CODEUP_BOT_USERNAME）" >&2
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
    if ! _codeup_should_retry "$CODEUP_HTTP_CODE"; then
      echo "codeup_post_comment: HTTP ${CODEUP_HTTP_CODE}，确定性失败不重试" >&2
      return 1
    fi
    echo "codeup_post_comment: HTTP ${CODEUP_HTTP_CODE}，第 ${attempt} 次尝试失败" >&2
    [[ "$attempt" -lt 3 ]] && _codeup_retry_sleep "$attempt"
  done
  return 1
}

# --- 列出 MR 的汇总评论（ListMergeRequestComments）---
# 路径与参数以 scripts/probe/probe-codeup-inline.sh 实测为准：POST `…/changeRequests/<id>/comments/list`，
# body `{"comment_type":"GLOBAL_COMMENT"}`（P1-06 实测支持按 comment_type 过滤）。
# 响应是评论对象数组，每项含 comment_biz_id / comment_type / content / state / author.username。
# $1=localId → stdout=响应体；rc 1=失败（按既有重试策略重试后仍失败）
codeup_list_global_comments() {
  local local_id="$1" attempt tmp
  local body='{"comment_type":"GLOBAL_COMMENT"}'
  for attempt in 1 2 3; do
    tmp=$(mktemp)
    _codeup_request POST \
      "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments/list" \
      "$body" > "$tmp"
    if _codeup_http_ok "$CODEUP_HTTP_CODE"; then
      cat "$tmp"; rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"
    if ! _codeup_should_retry "$CODEUP_HTTP_CODE"; then
      echo "codeup_list_global_comments: HTTP ${CODEUP_HTTP_CODE}，确定性失败不重试" >&2
      return 1
    fi
    echo "codeup_list_global_comments: HTTP ${CODEUP_HTTP_CODE}，第 ${attempt} 次尝试失败" >&2
    [[ "$attempt" -lt 3 ]] && _codeup_retry_sleep "$attempt"
  done
  return 1
}

# --- 原地更新一条评论（UpdateChangeRequestComment）---
# 实测（P1-05）：PUT `…/changeRequests/<id>/comments/<comment_biz_id>`，body 只需 `{content}`，
# 评论 biz_id 不变、UI 显示「已编辑」，本人编辑自己的评论不产生通知。
# $1=localId $2=comment_biz_id $3=Markdown 文件路径。重试策略与 codeup_post_comment 一致。
codeup_update_comment() {
  local local_id="$1" biz_id="$2" markdown_file="$3"
  local body attempt
  body=$(jq -n --rawfile content "$markdown_file" '{content: $content}')
  for attempt in 1 2 3; do
    _codeup_request PUT \
      "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments/${biz_id}" \
      "$body" >/dev/null
    _codeup_http_ok "$CODEUP_HTTP_CODE" && return 0
    if ! _codeup_should_retry "$CODEUP_HTTP_CODE"; then
      # 4xx 常见于「旧评论已被人删除」（404）：调用方应据此退回新建
      echo "codeup_update_comment: HTTP ${CODEUP_HTTP_CODE}，确定性失败不重试" >&2
      return 1
    fi
    echo "codeup_update_comment: HTTP ${CODEUP_HTTP_CODE}，第 ${attempt} 次尝试失败" >&2
    [[ "$attempt" -lt 3 ]] && _codeup_retry_sleep "$attempt"
  done
  return 1
}

# --- 机器人账号的用户名 ---
# 优先级：① CODEUP_BOT_USERNAME 显式配置（推荐，也是 DRY_RUN 下测试的注入点）；
#         ② 令牌身份接口 GET /oapi/v1/platform/user。
# 两者都取不到 → rc 1，由调用方退回「从带评审标记的评论作者推断」（见 review_select_prior_comment）。
# 实测（spec §4.7.1 P1-00）：未勾选平台用户权限的令牌访问 ② 返回 403，所以生产上 ② 大概率不可用。
codeup_bot_username() {
  if [[ -n "${CODEUP_BOT_USERNAME:-}" ]]; then printf '%s\n' "$CODEUP_BOT_USERNAME"; return 0; fi
  local tmp name=""
  tmp=$(mktemp)
  _codeup_request GET "/oapi/v1/platform/user" > "$tmp"
  if _codeup_http_ok "$CODEUP_HTTP_CODE"; then
    name=$(jq -r 'if type == "object" then (.username // .name // "") else "" end' "$tmp" 2>/dev/null || echo "")
  else
    echo "codeup_bot_username: GetUserByToken HTTP ${CODEUP_HTTP_CODE}（令牌可能未勾选平台用户权限，属已知情况）" >&2
  fi
  rm -f "$tmp"
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}
