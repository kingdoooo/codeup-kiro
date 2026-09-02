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

# 退避秒数的基数。CODEUP_RETRY_BACKOFF=0 关掉睡眠，供测试真正跑一遍重试循环
# （否则每条重试路径的负向测试都要等 15 秒，结果就是没人写这类测试）。
# 必须校验：不带校验时 `five` 会被 $(( )) 当 0 用（退避被静默关掉，生产上把 429/5xx 变成三连击），
# `5s` 直接算术报错（在 set -e 下让整次评审挂掉），而超大值会把流水线挂住。
CODEUP_RETRY_BACKOFF_DEFAULT=5
CODEUP_RETRY_BACKOFF_MAX=60
_codeup_retry_backoff() {
  local v="${CODEUP_RETRY_BACKOFF-}"
  if [[ -z "$v" ]]; then printf '%s' "$CODEUP_RETRY_BACKOFF_DEFAULT"; return 0; fi
  if [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -le "$CODEUP_RETRY_BACKOFF_MAX" ]]; then printf '%s' "$v"; return 0; fi
  echo "codeup: CODEUP_RETRY_BACKOFF=${v} 不是 0–${CODEUP_RETRY_BACKOFF_MAX} 的整数，按默认 ${CODEUP_RETRY_BACKOFF_DEFAULT} 秒退避处理" >&2
  printf '%s' "$CODEUP_RETRY_BACKOFF_DEFAULT"
}
_codeup_retry_sleep() {
  local secs=$(( $1 * $(_codeup_retry_backoff) ))
  [[ "$secs" -gt 0 ]] && sleep "$secs"
  return 0
}

# --- 带重试的请求（既有策略：000/429/5xx 重试至多 2 次，其余 4xx 确定性失败不重试）---
# 用法：_codeup_request_retry <日志前缀> <响应体输出文件（可为 /dev/null）> <method> <path> [body]
#   rc 0 = HTTP 2xx（响应体已写入输出文件）；rc 1 = 失败
# 这四个封装（post/list/update/bot_username）原先各抄了一份同样的循环，一处改动要同步四处，
# 而 bot_username 那份当时干脆漏了重试：一次传输抖动（000）就让本次评审退化为新建，
# 日志还把它写成「令牌未勾选平台用户权限」，把运维引向错误方向。
# 不能用 $(...) 取响应：命令替换在子 shell 里跑，CODEUP_HTTP_CODE 传不回来。
_codeup_request_retry() {
  local prefix="$1" out="$2" method="$3" path="$4" body="${5:-}"
  local attempt tmp
  for attempt in 1 2 3; do
    tmp=$(mktemp)
    _codeup_request "$method" "$path" "$body" > "$tmp"
    if _codeup_http_ok "$CODEUP_HTTP_CODE"; then
      cat "$tmp" > "$out"; rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"
    if ! _codeup_should_retry "$CODEUP_HTTP_CODE"; then
      echo "${prefix}: HTTP ${CODEUP_HTTP_CODE}，确定性失败不重试" >&2
      return 1
    fi
    echo "${prefix}: HTTP ${CODEUP_HTTP_CODE}，第 ${attempt} 次尝试失败" >&2
    [[ "$attempt" -lt 3 ]] && _codeup_retry_sleep "$attempt"
  done
  return 1
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
  local body tmp author rc=0
  # 注意：中心站 CreateChangeRequestComment 要求 resolved 字段必填（缺失报 400 "resolved can not be null"）
  body=$(jq -n --rawfile content "$markdown_file" \
    '{comment_type: "GLOBAL_COMMENT", content: $content, draft: false, resolved: false}')
  tmp=$(mktemp)
  _codeup_request_retry codeup_post_comment "$tmp" POST \
    "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments" \
    "$body" || rc=$?
  if [[ "$rc" == "0" ]]; then
    # 新建评论的响应里带 author.username，这就是本机器人账号的用户名。令牌身份接口实测 403
    # （spec §4.7.1 P1-00），所以这条日志是运维拿到 CODEUP_BOT_USERNAME 取值的**唯一**实用途径。
    # 因此必须同时认对象与数组两种形态：本文件头注释就写明官方响应体形态在接口之间不一致
    # （CreateChangeRequestComment 被记为 snake_case 数组），只认对象的话这条日志可能永远不打印。
    author=$(jq -r '
      def uname: if type == "object" and (.author | type) == "object"
                 then ((.author.username // "") | if type == "string" then . else "" end)
                 else "" end;
      if type == "array" then ((.[0] // {}) | uname) else uname end' "$tmp" 2>/dev/null || echo "")
    [[ -n "$author" ]] \
      && echo "codeup_post_comment: 新建评论的作者用户名=${author}（可据此配置 CODEUP_BOT_USERNAME）" >&2
  fi
  rm -f "$tmp"
  return "$rc"
}

# --- 列出 MR 的汇总评论（ListMergeRequestComments）---
# 路径与参数以 scripts/probe/probe-codeup-inline.sh 实测为准：POST `…/changeRequests/<id>/comments/list`，
# body `{"comment_type":"GLOBAL_COMMENT"}`（P1-06 实测支持按 comment_type 过滤）。
# 响应是评论对象数组，每项含 comment_biz_id / comment_type / content / state / author.username。
# 分页：探测只在一条评论的新 MR 上调过 `{}`（probe-codeup-inline.sh），**分页参数名未实测**，
# 因此这里不凭记忆往 body 里塞 page/perPage。取而代之的是：返回条数达到常见单页上限时打警告——
# 旧汇总评论落在页外时脚本会误判「首次评审」而每次新建一条。补分页需要先做一次探测（见票 03 Comments）。
# $1=localId → stdout=响应体；rc 1=失败（按既有重试策略重试后仍失败）
CODEUP_COMMENT_PAGE_HINT="${CODEUP_COMMENT_PAGE_HINT:-100}"
codeup_list_global_comments() {
  local local_id="$1" tmp cnt rc=0
  local body='{"comment_type":"GLOBAL_COMMENT"}'
  tmp=$(mktemp)
  _codeup_request_retry codeup_list_global_comments "$tmp" POST \
    "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments/list" \
    "$body" || rc=$?
  if [[ "$rc" == "0" ]]; then
    cnt=$(jq -r 'if type == "array" then length elif type == "object" then ((.result // []) | length) else 0 end' \
            "$tmp" 2>/dev/null || echo 0)
    if [[ "${cnt:-0}" =~ ^[0-9]+$ && "${cnt:-0}" -ge "$CODEUP_COMMENT_PAGE_HINT" ]]; then
      echo "codeup_list_global_comments: 返回 ${cnt} 条评论，已达常见单页上限（${CODEUP_COMMENT_PAGE_HINT}），旧汇总评论可能不在本页内 → 可能误判为首次评审并多发一条汇总" >&2
    fi
    cat "$tmp"
  fi
  rm -f "$tmp"
  return "$rc"
}

# --- 原地更新一条评论（UpdateChangeRequestComment）---
# 实测（P1-05）：PUT `…/changeRequests/<id>/comments/<comment_biz_id>`，body 只需 `{content}`，
# 评论 biz_id 不变、UI 显示「已编辑」，本人编辑自己的评论不产生通知。
# $1=localId $2=comment_biz_id $3=Markdown 文件路径。重试策略与 codeup_post_comment 一致。
# 4xx（尤其 404「旧评论已被人删除」）不重试，调用方据此退回新建。
codeup_update_comment() {
  local local_id="$1" biz_id="$2" markdown_file="$3" body
  # 绝不 PUT 空正文：那会把上一次的完整报告（含隐藏历史）覆盖成空白且不可恢复
  [[ -s "$markdown_file" ]] \
    || { echo "codeup_update_comment: 待写入的正文文件为空，拒绝更新（空正文会把上一条汇总覆盖成空白）：${markdown_file}" >&2; return 1; }
  body=$(jq -n --rawfile content "$markdown_file" '{content: $content}')
  _codeup_request_retry codeup_update_comment /dev/null PUT \
    "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments/${biz_id}" \
    "$body"
}

# --- 机器人账号的用户名 ---
# 优先级：① CODEUP_BOT_USERNAME 显式配置（推荐，也是 DRY_RUN 下测试的注入点）；
#         ② 令牌身份接口 GET /oapi/v1/platform/user。
# 两者都取不到 → rc 1，由调用方退回「从带评审标记的评论作者推断」（见 review_select_prior_comment）。
# 实测（spec §4.7.1 P1-00）：未勾选平台用户权限的令牌访问 ② 返回 403，所以生产上 ② 大概率不可用。
codeup_bot_username() {
  if [[ -n "${CODEUP_BOT_USERNAME:-}" ]]; then printf '%s\n' "$CODEUP_BOT_USERNAME"; return 0; fi
  local tmp name="" rc=0
  tmp=$(mktemp)
  # 走公共重试封装：机器人用户名决定本次能否原地更新，一次传输抖动（000）不该让它退化为新建，
  # 更不该把「网络抖了一下」在日志里写成「令牌未勾选平台用户权限」。
  _codeup_request_retry codeup_bot_username "$tmp" GET "/oapi/v1/platform/user" || rc=$?
  if [[ "$rc" == "0" ]]; then
    # 只取 username：`.name` 是显示名，与要比对的 `author.username`（实测形如 aliyun:kingdooo_hvFXC）
    # 不同命名空间。退回 .name 会给出一个**永远匹配不上**的非空值，反而把新建/更新的判定也带偏。
    name=$(jq -r 'if type == "object" then ((.username // "") | if type == "string" then . else "" end) else "" end' \
             "$tmp" 2>/dev/null || echo "")
    [[ -n "$name" ]] || echo "codeup_bot_username: 身份接口响应里没有 username 字段，按「取不到」处理" >&2
  else
    echo "codeup_bot_username: GetUserByToken 取不到身份（HTTP ${CODEUP_HTTP_CODE}；403 表示令牌未勾选平台用户权限，属已知情况——P1-00 实测）" >&2
  fi
  rm -f "$tmp"
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}
