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

# --- 创建行内评论专用的重试策略：只重试 429 ---
# 000（响应丢失）与 5xx 都可能发生在「服务端其实已经建好了」之后。对**行内评论**重试的代价很具体：
# 同一行上多出一条重复评论，而第一条的 comment_biz_id 我们从来没拿到过——它永远不会被纳入
# 一次提交、永远不会被删除，之后的去重也看不到它（草稿会被状态过滤掉）。429 是服务端明确表示
# 「没受理」，重试是安全的。
# 不重试的代价小得多：这一条按发布失败处理，进汇总评论的折叠区「行内发布失败」（完整渲染，
# 说明与修复建议都在），下次评审重发。
# 刻意**不**把这条策略套到 codeup_post_comment（汇总评论）上：汇总评论是评审结果唯一的通道，
# 一次传输抖动就丢掉整份报告违反 I10；而它重复的后果是 MR 上多一条汇总，下一次评审还能靠
# 评审标记找到并原地更新其中一条。两者的取舍方向相反。
_codeup_should_retry_create_inline() { [[ "$1" == "429" ]]; }

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

# --- 带重试的请求（默认策略：000/429/5xx 重试至多 2 次，其余 4xx 确定性失败不重试）---
# 用法：_codeup_request_retry <日志前缀> <响应体输出文件（可为 /dev/null）> <method> <path> [body] [重试判定函数]
#   rc 0 = HTTP 2xx（响应体已写入输出文件）；rc 1 = 失败
# 第 6 个参数可换一个更严的重试判定（行内评论创建用 _codeup_should_retry_create_inline：
# 只重试 429，因为创建不幂等）。
# 这四个封装（post/list/update/bot_username）原先各抄了一份同样的循环，一处改动要同步四处，
# 而 bot_username 那份当时干脆漏了重试：一次传输抖动（000）就让本次评审退化为新建，
# 日志还把它写成「令牌未勾选平台用户权限」，把运维引向错误方向。
# 不能用 $(...) 取响应：命令替换在子 shell 里跑，CODEUP_HTTP_CODE 传不回来。
_codeup_request_retry() {
  local prefix="$1" out="$2" method="$3" path="$4" body="${5:-}" pred="${6:-_codeup_should_retry}"
  local attempt tmp
  for attempt in 1 2 3; do
    tmp=$(mktemp)
    _codeup_request "$method" "$path" "$body" > "$tmp"
    if _codeup_http_ok "$CODEUP_HTTP_CODE"; then
      cat "$tmp" > "$out"; rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"
    if ! "$pred" "$CODEUP_HTTP_CODE"; then
      echo "${prefix}: HTTP ${CODEUP_HTTP_CODE}，确定性失败不重试" >&2
      return 1
    fi
    echo "${prefix}: HTTP ${CODEUP_HTTP_CODE}，第 ${attempt} 次尝试失败" >&2
    [[ "$attempt" -lt 3 ]] && _codeup_retry_sleep "$attempt"
  done
  return 1
}

# --- DRY_RUN 的响应注入：按「方法 + 路径特征 + body 里的评论类型」给请求起一个 route 名 ---
# DRY_RUN 下默认一律返回 `[]`（票 01/02 的测试依赖这个），但「先查旧评论再决定更新还是新建」
# 这类逻辑必须能在 DRY_RUN 下喂进不同的列表响应，否则只能在真实 Codeup 上验证。
# 机制：DRY_RUN_FIXTURE_DIR/<route>.json 存在就用它当响应体；不存在仍是 `[]`（向后兼容）。
# 另有 DRY_RUN_FAIL_ROUTES="<route>:<code>,…" 注入 HTTP 状态码，用来测重试与失败退回。
#
# 行内评论的列表与创建跟汇总评论**走同一组路径**，只有 body 里的 comment_type 不同，所以
# 这两条 route 还要看 body。汇总评论的正文里出现同样字样不会误判：正文是 JSON 字符串，
# 其中的引号已被转义成 `\"`，与 body 里真正的 `"comment_type":"INLINE_COMMENT"` 不同形。
_codeup_route_name() {
  local method="$1" path="$2" body="${3:-}"
  local inline=0
  # 紧凑与带空格两种形态都认：body 由 jq 生成，加不加 -c 决定有没有那个空格，
  # 而这个判定一旦只认一种形态，换个 jq 调用方式就会静默把行内评论算成汇总评论的 route。
  [[ "$body" == *'"comment_type":"INLINE_COMMENT"'* || "$body" == *'"comment_type": "INLINE_COMMENT"'* ]] && inline=1
  case "${method}:${path}" in
    GET:/oapi/v1/platform/user) echo platform-user ;;
    POST:*/changeRequests/*/review) echo submit-review ;;
    # list 必须排在 create 前面：两者都是 POST 且路径前缀相同
    POST:*/comments/list)       [[ "$inline" == "1" ]] && echo list-comments-inline || echo list-comments ;;
    POST:*/comments)            [[ "$inline" == "1" ]] && echo create-comment-inline || echo create-comment ;;
    PUT:*/comments/*)           echo update-comment ;;
    DELETE:*/comments/*)        echo delete-comment ;;
    GET:*/changeRequests\?*)    echo list-change-requests ;;
    GET:*/diffs/patches)        echo list-patchsets ;;
    *)                          echo other ;;
  esac
}

# --- DRY_RUN fixture 序列 ---
# 逐条创建行内评论草稿时，同一个 route 会被调用多次，而每次都必须拿到**不同**的 comment_biz_id，
# 否则「一次提交 N 条草稿」在 DRY_RUN 下永远只能测到同一个 id、收集 id 的逻辑写错也测不出来。
# 机制：第 n 次调用先找 <route>.<n>.json，找不到再退回 <route>.json（既有 fixture 目录行为不变）。
# 计数器是 shell 变量，因此**只在同一个 shell 里递增**：调用方必须把响应写进文件，不能用 `$(...)`
# 取（命令替换在子 shell 里跑，计数器与 CODEUP_HTTP_CODE 一样传不回来）。
# 同理，本函数把结果写进全局 CODEUP_DRY_SEQ 而不是 stdout——写 stdout 就得靠 `$(…)` 取，
# 那一层命令替换本身就在子 shell 里，递增会立刻丢掉（每次都拿到 1）。
_codeup_dry_seq_next() {
  local key cur
  key="_CODEUP_DRY_SEQ_${1//[^A-Za-z0-9]/_}"
  eval "cur=\${${key}:-0}"
  cur=$((cur + 1))
  eval "${key}=${cur}"
  CODEUP_DRY_SEQ="$cur"
}
# 只给测试用：一次评审只跑一个进程，生产路径永远不需要重置计数器；
# 而同一个测试文件里的多组用例必须能各自从 .1.json 开始。
_codeup_dry_seq_reset() {
  local v
  for v in $(compgen -v _CODEUP_DRY_SEQ_ 2>/dev/null || true); do unset "$v"; done
}

# method path [body] → stdout=响应体；全局 CODEUP_HTTP_CODE=状态码（传输失败=000）
_codeup_request() {
  local method="$1" path="$2" body="${3:-}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    local route pair fixture seq
    route=$(_codeup_route_name "$method" "$path" "$body")
    echo "DRY_RUN ${method} ${CODEUP_API_BASE}${path}" >&2
    [[ -n "$body" ]] && echo "DRY_RUN body: ${body}" >&2
    CODEUP_HTTP_CODE=200
    # 失败注入放在序号递增之前：重试不该消耗 fixture 序号
    for pair in $(printf '%s' "${DRY_RUN_FAIL_ROUTES:-}" | tr ',' ' '); do
      [[ "${pair%%:*}" == "$route" ]] || continue
      CODEUP_HTTP_CODE="${pair##*:}"
      echo "DRY_RUN 注入失败：route=${route} HTTP ${CODEUP_HTTP_CODE}" >&2
      echo '{}'
      return 0
    done
    _codeup_dry_seq_next "$route"; seq="$CODEUP_DRY_SEQ"
    fixture=""
    if [[ -n "${DRY_RUN_FIXTURE_DIR:-}" ]]; then
      if [[ -r "${DRY_RUN_FIXTURE_DIR}/${route}.${seq}.json" ]]; then
        fixture="${DRY_RUN_FIXTURE_DIR}/${route}.${seq}.json"
      elif [[ -r "${DRY_RUN_FIXTURE_DIR}/${route}.json" ]]; then
        fixture="${DRY_RUN_FIXTURE_DIR}/${route}.json"
      fi
    fi
    if [[ -n "$fixture" ]]; then
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
CODEUP_COMMENT_PAGE_HINT_DEFAULT=100
CODEUP_COMMENT_PAGE_HINT="${CODEUP_COMMENT_PAGE_HINT:-$CODEUP_COMMENT_PAGE_HINT_DEFAULT}"
# 取值校验放在**用的时候**（与 _codeup_retry_backoff 同一形态），不是 source 时：
# 非整数取值会让下面那句 `-ge` 比较变成 bash 算术错误并恒取假，于是「返回 N 条评论，已达常见
# 单页上限」这条告警**永久失效**——而它是「旧汇总落在页外 → 每次误判为首次评审 → MR 上堆出
# 多条汇总」这个已知故障的唯一提示。回落默认值并留痕，不因此中断评审。
_codeup_page_hint() {
  local v="${CODEUP_COMMENT_PAGE_HINT-}"
  if [[ "$v" =~ ^[0-9]+$ ]] && [[ "$((10#$v))" -ge 1 ]]; then printf '%s' "$((10#$v))"; return 0; fi
  echo "codeup: CODEUP_COMMENT_PAGE_HINT=${v} 不是 ≥1 的整数，按默认 ${CODEUP_COMMENT_PAGE_HINT_DEFAULT} 处理" >&2
  printf '%s' "$CODEUP_COMMENT_PAGE_HINT_DEFAULT"
}
# 内部实现：两种评论类型只差 body 里的 comment_type 与告警文案，共用一份请求/分页告警逻辑。
# 用法：_codeup_list_comments <localId> <GLOBAL_COMMENT|INLINE_COMMENT> <日志前缀> <达上限时的后果说明>
_codeup_list_comments() {
  local local_id="$1" ctype="$2" prefix="$3" consequence="$4" tmp cnt rc=0
  local body
  body=$(printf '{"comment_type":"%s"}' "$ctype")
  tmp=$(mktemp)
  _codeup_request_retry "$prefix" "$tmp" POST \
    "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments/list" \
    "$body" || rc=$?
  if [[ "$rc" == "0" ]]; then
    cnt=$(jq -r 'if type == "array" then length elif type == "object" then ((.result // []) | length) else 0 end' \
            "$tmp" 2>/dev/null || echo 0)
    local hint
    hint=$(_codeup_page_hint)
    if [[ "${cnt:-0}" =~ ^[0-9]+$ && "${cnt:-0}" -ge "$hint" ]]; then
      echo "${prefix}: 返回 ${cnt} 条评论，已达常见单页上限（${hint}）→ ${consequence}" >&2
    fi
    cat "$tmp"
  fi
  rm -f "$tmp"
  return "$rc"
}
codeup_list_global_comments() {
  _codeup_list_comments "$1" GLOBAL_COMMENT codeup_list_global_comments \
    "旧汇总评论可能不在本页内，可能误判为首次评审并多发一条汇总"
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

# ============================================================================
# 票 04：行内评论相关接口
# 路径、字段与响应形态一律以 scripts/probe/probe-codeup-inline.sh 的实测为准（spec §4.7.1），
# 不凭记忆写 API。
# ============================================================================

# --- MR 的版本列表（ListChangeRequestPatchSets）---
# 实测（P1-01）：GET …/changeRequests/<id>/diffs/patches → 评论对象数组，每项含
# versionNo / relatedMergeItemType（MERGE_SOURCE | MERGE_TARGET）/ patchSetBizId / commitId / shortId。
# 该 MR 上有 6 个 MERGE_SOURCE + 1 个 MERGE_TARGET，按 versionNo 取最新即可唯一选出 from/to。
# $1=localId → stdout=响应体；rc 1=失败（按既有重试策略重试后仍失败）
codeup_list_patchsets() {
  local local_id="$1" tmp rc=0
  tmp=$(mktemp)
  _codeup_request_retry codeup_list_patchsets "$tmp" GET \
    "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/diffs/patches" \
    || rc=$?
  [[ "$rc" == "0" ]] && cat "$tmp"
  rm -f "$tmp"
  return "$rc"
}

# --- 选出行内评论要用的版本对（spec §4.5 第 1 步、Q6）---
# from = 最新 MERGE_TARGET，to = 最新 MERGE_SOURCE（都按 versionNo 取最大），patchset_biz_id 用 to。
# stdin = ListChangeRequestPatchSets 响应
# stdout = "from_patchset_biz_id<TAB>to_patchset_biz_id<TAB>to_commit_id<TAB>from_commit_id"
# from_commit_id 排在最后（追加而不是插入）：调用方按 cut -f1..3 取值的写法不受影响。
# 它用来核对「Codeup 侧的比较基准」与本地 merge-base 是否一致（见 kiro-review.sh 的 R8 告警）。
# rc 1 = 选不出（响应不合法，或缺 MERGE_TARGET / MERGE_SOURCE 中的一侧）——调用方据此回落到
#        「只发一条含完整问题清单的汇总评论」，绝不用猜出来的版本去发行内评论（会挂错行）。
# 字段类型守卫与 review_select_prior_comment 同理：响应形态只在一次探测里见过，
# 单项不合形（patchSetBizId 非字符串、versionNo 非数字、项不是对象）只跳过那一项。
codeup_select_patchset_pair() {
  local out
  out=$(jq -r '
    def norm: (if type == "object" then (.result // []) else . end)
              | (if type == "array" then . else [] end)
              | map(select(type == "object"));
    def pick($t): [ norm[]
                    | select((.relatedMergeItemType // "") == $t)
                    | select((.patchSetBizId | type) == "string" and ((.patchSetBizId | length) > 0)) ]
                  | sort_by(if (.versionNo | type) == "number" then .versionNo else -1 end)
                  | last;
    . as $all
    | ($all | pick("MERGE_TARGET")) as $from
    | ($all | pick("MERGE_SOURCE")) as $to
    | if $from == null then "missing:MERGE_TARGET"
      elif $to == null then "missing:MERGE_SOURCE"
      else [$from.patchSetBizId, $to.patchSetBizId,
            (if ($to.commitId | type) == "string" then $to.commitId else "" end),
            (if ($from.commitId | type) == "string" then $from.commitId else "" end)] | @tsv
      end' 2>/dev/null) || out=""
  case "$out" in
    "")
      echo "codeup_select_patchset_pair: 版本列表不是合法 JSON，选不出行内评论要用的版本对" >&2
      return 1 ;;
    missing:*)
      echo "codeup_select_patchset_pair: 版本列表里没有 ${out#missing:} 版本，选不出行内评论要用的版本对" >&2
      return 1 ;;
  esac
  printf '%s\n' "$out"
}

# --- 创建一条行内评论（CreateChangeRequestComment）---
# 实测：`line_number` 是**新文件侧**行号（P1-02）；`patchset_biz_id` / `from_patchset_biz_id` /
# `to_patchset_biz_id` 三个字段必传，缺 from 即 400 `from patch set biz id can not be null`（P1-03）；
# `resolved` 与汇总评论一样必填。draft=true 建草稿，随后由 codeup_submit_drafts 一次提交。
# 用法：codeup_create_inline_comment <localId> <正文 md 文件> <file_path> <line> <from> <to> <true|false> <响应输出文件>
# **必须**这样调用而不是 `id=$(codeup_create_inline_comment …)`：命令替换在子 shell 里跑，
# CODEUP_HTTP_CODE 与 DRY_RUN 的 fixture 序号都传不回来。
codeup_create_inline_comment() {
  local local_id="$1" md="$2" file_path="$3" line="$4" from="$5" to="$6" draft="$7" out="$8"
  local body rc=0
  # 本地先拦下必然 400 的请求：真实接口的报错要翻流水线日志才看得到，而这些前置条件是确定的
  [[ -s "$md" ]] \
    || { echo "codeup_create_inline_comment: 正文为空，拒绝创建（一条空的行内评论挂在代码上没法解释）：${md}" >&2; return 2; }
  [[ -n "$file_path" ]] \
    || { echo "codeup_create_inline_comment: 缺 file_path" >&2; return 2; }
  [[ "$line" =~ ^[0-9]+$ && "$line" -ge 1 ]] \
    || { echo "codeup_create_inline_comment: line_number 必须是 ≥1 的整数（实际：${line}）" >&2; return 2; }
  [[ -n "$from" && -n "$to" ]] \
    || { echo "codeup_create_inline_comment: from/to 版本必须都给（P1-03 实测缺一即 400）" >&2; return 2; }
  [[ "$draft" == "true" || "$draft" == "false" ]] \
    || { echo "codeup_create_inline_comment: draft 只能是 true/false（实际：${draft}）" >&2; return 2; }
  body=$(jq -nc --rawfile content "$md" --arg f "$file_path" --argjson l "$line" \
            --arg from "$from" --arg to "$to" --argjson draft "$draft" \
    '{comment_type: "INLINE_COMMENT", content: $content, draft: $draft, resolved: false,
      file_path: $f, line_number: $l,
      patchset_biz_id: $to, from_patchset_biz_id: $from, to_patchset_biz_id: $to}')
  # 只重试 429（见 _codeup_should_retry_create_inline）：创建不幂等，000/5xx 之后重试会在同一行上
  # 留下一条我们永远拿不到 id 的重复评论
  _codeup_request_retry codeup_create_inline_comment "$out" POST \
    "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments" \
    "$body" _codeup_should_retry_create_inline || rc=$?
  return "$rc"
}

# --- 从创建响应里取评论 biz_id ---
# 响应形态在接口之间不一致（本文件头注释就写明这点），所以对象与数组两种都认。
# $1=响应文件 → stdout=comment_biz_id（取不到则为空串，rc 仍为 0：由调用方决定怎么处理）
codeup_comment_biz_id() {
  jq -r '
    def one: if type == "object" then ((.comment_biz_id // "") | if type == "string" then . else "" end) else "" end;
    if type == "array" then ((.[0] // {}) | one) else one end' "$1" 2>/dev/null || echo ""
}

# --- 一次提交草稿（ReviewChangeRequest）---
# 实测（P1-04）：POST …/changeRequests/<id>/review，body `{"submitDraftCommentIds":[…]}`，
# **不带** reviewOpinion 也成功（草稿转 OPENED），机器人不需要先是评审人。
# 不带 reviewOpinion 是硬要求：传了就等于给出评审意见，会参与合并卡点（spec 非目标「合并卡点」）。
# 用法：codeup_submit_drafts <localId> <草稿 id 文件（每行一个）>
codeup_submit_drafts() {
  local local_id="$1" ids_file="$2" body
  [[ -s "$ids_file" ]] \
    || { echo "codeup_submit_drafts: 没有草稿 id，拒绝提交（空提交没有意义）：${ids_file}" >&2; return 2; }
  body=$(jq -Rc --slurp 'split("\n") | map(select(length > 0)) | {submitDraftCommentIds: .}' "$ids_file")
  _codeup_request_retry codeup_submit_drafts /dev/null POST \
    "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/review" \
    "$body"
}

# --- 列出 MR 的行内评论（去重用；spec §4.5 第 5 步）---
# body 只带 comment_type（P1-06 实测支持该过滤，返回含 author.username / state / filePath / line_number）。
# **刻意不带 state 过滤**：探测只验证过 comment_type，state 参数名未实测；凭记忆传一个可能 400 的
# 参数会让整条去重通路挂掉，而去重挂掉的后果是重跑在同一行上堆重复评论。状态在脚本侧按 .state 过滤
# （review_inline_existing_fingerprints）。分页告警与汇总评论列表同理。
# $1=localId → stdout=响应体；rc 1=失败
codeup_list_inline_comments() {
  _codeup_list_comments "$1" INLINE_COMMENT codeup_list_inline_comments \
    "已有的行内评论可能不在本页内，去重可能漏判、重跑会重复发"
}

# --- 删除一条评论（DeleteChangeRequestComment）---
# 只用在一处：草稿一次提交失败、要退回逐条非草稿发布之前，先把已经建好的草稿删掉。
# 不删的话同一条问题会在 MR 上同时留下一条草稿（只有机器人自己看得见）和一条正式评论，
# 而下一次评审读到那条草稿的指纹（若把草稿也算作已发出）就再也不会重发了。
# $1=localId $2=comment_biz_id。失败由调用方降级为警告，绝不因此中断评审。
codeup_delete_comment() {
  local local_id="$1" biz_id="$2"
  [[ -n "$biz_id" ]] || { echo "codeup_delete_comment: 缺 comment_biz_id" >&2; return 2; }
  _codeup_request_retry codeup_delete_comment /dev/null DELETE \
    "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments/${biz_id}"
}
