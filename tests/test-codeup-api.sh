#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
source ../scripts/lib/codeup-api.sh

export YUNXIAO_TOKEN="test-token"
export YUNXIAO_ORG_ID="org123"
export CODEUP_REPO_ID="456"

# --- codeup_parse_mr：每匹配一行 ---
out=$(codeup_parse_mr "feature/x" < fixtures/mr-list-result.json)
assert_eq "$out" "$(printf '7\tmaster')" "parse: 唯一匹配"

out=$(codeup_parse_mr "feature/dup" < fixtures/mr-list-result.json)
assert_eq "$(printf '%s' "$out" | wc -l | tr -d ' ')" "1" "parse: 多匹配输出多行（wc -l 计换行=1 即两行）"

out=$(codeup_parse_mr "feature/none" < fixtures/mr-list-result.json)
assert_eq "$out" "" "parse: 无匹配输出空"

# 裸数组形态兼容
out=$(printf '[{"localId":9,"sourceBranch":"feature/y","targetBranch":"develop","updatedAt":"2026-07-21T08:00:00Z"}]' \
  | codeup_parse_mr "feature/y")
assert_eq "$out" "$(printf '9\tdevelop')" "parse: 裸数组形态"

# --- DRY_RUN 请求组装与返回码 ---
export DRY_RUN=1

# find_mr：DRY_RUN 返回空列表 → rc 2（无匹配）
rc=0; err=$(codeup_find_mr "feature/x" 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 2 "find_mr: DRY_RUN 空结果 rc=2"
assert_contains "$err" "organizations/org123/changeRequests" "find_mr: URL 路径"
assert_contains "$err" "projectIds=456" "find_mr: 按库过滤"
assert_contains "$err" "state=opened" "find_mr: 只查打开的 MR"
assert_contains "$err" "orderBy=updated_at" "find_mr: 显式排序字段"

# post_comment：DRY_RUN 视同 200 成功
md=$(mktemp); echo "## 评审结果" > "$md"
rc=0; err=$(codeup_post_comment 7 "$md" 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "post_comment: DRY_RUN 成功"
assert_contains "$err" "changeRequests/7/comments" "post_comment: URL"
assert_contains "$err" "GLOBAL_COMMENT" "post_comment: 评论类型"
assert_contains "$err" "resolved" "post_comment: body 含 resolved 字段（中心站必填）"
rm -f "$md"

# --- 真实响应契约：_codeup_http_ok 状态码判定 ---
unset DRY_RUN
assert_rc "$(_codeup_http_ok 200 && echo 0 || echo 1)" "0" "http_ok: 200"
assert_rc "$(_codeup_http_ok 201 && echo 0 || echo 1)" "0" "http_ok: 201"
assert_rc "$(_codeup_http_ok 400 && echo 0 || echo 1)" "1" "http_ok: 400"

# --- find_mr HTTP 失败分支：连接拒绝（无需真实服务），须留痕日志且 rc=2 ---
rc=0; err=$(CODEUP_API_BASE="http://127.0.0.1:1" codeup_find_mr "feature/x" 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 2 "find_mr: HTTP 失败 rc=2"
assert_contains "$err" "ListChangeRequests 调用失败（HTTP 000）" "find_mr: HTTP 失败留痕日志"

# --- 重试分类 ---
assert_rc "$(_codeup_should_retry 500 && echo y || echo n)" "y" "retry: 5xx 重试"
assert_rc "$(_codeup_should_retry 429 && echo y || echo n)" "y" "retry: 429 重试"
assert_rc "$(_codeup_should_retry 403 && echo y || echo n)" "n" "retry: 403 不重试"
assert_rc "$(_codeup_should_retry 000 && echo y || echo n)" "y" "retry: 传输错误(000) 重试"

# ============ 票 03：DRY_RUN 响应注入（fixture）============
export DRY_RUN=1
FX=fixtures/comments

# 向后兼容：不设 DRY_RUN_FIXTURE_DIR 时一律返回 []（票 01/02 的测试依赖这个）
out=$(_codeup_request POST "/x/changeRequests/7/comments/list" '{}' 2>/dev/null)
assert_eq "$out" "[]" "dry_run: 未设 fixture 目录时仍返回 []（向后兼容）"

# route 名按「方法 + 路径特征」判定，list 必须先于 create 匹配
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments/list)" "list-comments" "route: 评论列表"
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments)" "create-comment" "route: 新建评论"
assert_eq "$(_codeup_route_name PUT /a/changeRequests/7/comments/abc123)" "update-comment" "route: 更新评论"
assert_eq "$(_codeup_route_name GET '/a/changeRequests?projectIds=1&state=opened')" "list-change-requests" "route: MR 列表"
assert_eq "$(_codeup_route_name GET /oapi/v1/platform/user)" "platform-user" "route: 令牌身份"
assert_eq "$(_codeup_route_name GET /a/changeRequests/7/diffs/patches)" "list-patchsets" "route: 版本列表"
assert_eq "$(_codeup_route_name POST /a/nowhere)" "other" "route: 未识别路径"

# 设了 fixture 目录 → 按 route 名取响应；目录里没有对应文件时退回 []
out=$(DRY_RUN_FIXTURE_DIR="$FX/prior-run1" _codeup_request POST "/x/changeRequests/7/comments/list" '{}' 2>/dev/null)
assert_eq "$(printf '%s' "$out" | jq -r 'length')" "4" "dry_run: 按 route 取到 list-comments.json"
out=$(DRY_RUN_FIXTURE_DIR="$FX/prior-run1" _codeup_request GET "/oapi/v1/platform/user" 2>/dev/null)
assert_eq "$out" "[]" "dry_run: fixture 目录缺该 route 的文件时退回 []"

# 注入 HTTP 失败码（用来测更新失败退回新建）
# 不能用 out=$(...)：命令替换在子 shell 里跑，CODEUP_HTTP_CODE 传不回来（与 codeup_find_mr 同一个坑）
DRY_RUN_FAIL_ROUTES="update-comment:404" _codeup_request PUT "/x/changeRequests/7/comments/abc" '{}' >/dev/null 2>/dev/null
assert_eq "$CODEUP_HTTP_CODE" "404" "dry_run: DRY_RUN_FAIL_ROUTES 注入 404"
DRY_RUN_FAIL_ROUTES="update-comment:404" _codeup_request POST "/x/changeRequests/7/comments" '{}' >/dev/null 2>/dev/null
assert_eq "$CODEUP_HTTP_CODE" "200" "dry_run: 未列出的 route 不受注入影响"

# ============ 票 03：列出全局评论 ============
rc=0; err=$(DRY_RUN_FIXTURE_DIR="$FX/prior-run1" codeup_list_global_comments 7 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "list_comments: DRY_RUN 成功"
assert_contains "$err" "changeRequests/7/comments/list" "list_comments: URL 路径（实测 POST comments/list）"
assert_contains "$err" '"comment_type":"GLOBAL_COMMENT"' "list_comments: 只要汇总评论类型"
out=$(DRY_RUN_FIXTURE_DIR="$FX/prior-run1" codeup_list_global_comments 7 2>/dev/null)
assert_eq "$(printf '%s' "$out" | jq -r 'length')" "4" "list_comments: 返回 fixture 内容"

# ============ 票 03：原地更新评论 ============
md=$(mktemp); printf '## 🤖 Kiro 代码评审\n<!-- kiro-review:abc1234 run:2 -->\n' > "$md"
rc=0; err=$(codeup_update_comment 7 b1f0e9d8c7b6a5948372615049382716 "$md" 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "update_comment: DRY_RUN 成功"
assert_contains "$err" "DRY_RUN PUT" "update_comment: 用 PUT（实测 UpdateChangeRequestComment）"
assert_contains "$err" "changeRequests/7/comments/b1f0e9d8c7b6a5948372615049382716" "update_comment: URL 带评论 biz_id"
assert_contains "$err" "run:2" "update_comment: body 带新正文"
assert_not_contains "$err" "GLOBAL_COMMENT" "update_comment: 更新 body 只传 content（实测只需 content）"

# 4xx 确定性失败不重试；000/5xx 重试至多 2 次（CODEUP_RETRY_BACKOFF=0 免等待）
rc=0; err=$(DRY_RUN_FAIL_ROUTES="update-comment:404" codeup_update_comment 7 abc "$md" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "update_comment: 404 → 失败"
assert_contains "$err" "确定性失败不重试" "update_comment: 4xx 不重试"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN PUT')" "1" "update_comment: 4xx 只发一次请求"
rc=0; err=$(CODEUP_RETRY_BACKOFF=0 DRY_RUN_FAIL_ROUTES="update-comment:500" codeup_update_comment 7 abc "$md" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "update_comment: 5xx 重试后仍失败"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN PUT')" "3" "update_comment: 5xx 共尝试 3 次（重试 2 次）"
rc=0; err=$(CODEUP_RETRY_BACKOFF=0 DRY_RUN_FAIL_ROUTES="list-comments:500" codeup_list_global_comments 7 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "list_comments: 5xx 重试后仍失败"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN POST')" "3" "list_comments: 5xx 共尝试 3 次"
rc=0; err=$(DRY_RUN_FAIL_ROUTES="list-comments:403" codeup_list_global_comments 7 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "list_comments: 403 → 失败"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN POST')" "1" "list_comments: 403 不重试"
rm -f "$md"

# ============ 票 03：机器人账号用户名 ============
out=$(CODEUP_BOT_USERNAME="aliyun:explicit" codeup_bot_username 2>/dev/null)
assert_eq "$out" "aliyun:explicit" "bot_username: CODEUP_BOT_USERNAME 优先"
out=$(DRY_RUN_FIXTURE_DIR="$FX/token-identity" codeup_bot_username 2>/dev/null)
assert_eq "$out" "aliyun:kingdooo_hvFXC" "bot_username: 令牌身份接口可用时取 .username"
rc=0; out=$(codeup_bot_username 2>/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "bot_username: 身份接口返回非对象 → 非零（交给标记推断）"
assert_eq "$out" "" "bot_username: 取不到时不输出任何用户名"
rc=0; err=$(DRY_RUN_FAIL_ROUTES="platform-user:403" codeup_bot_username 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "bot_username: 403（P1-00 实测）→ 非零"
assert_contains "$err" "403" "bot_username: 403 留痕日志"
# 复审修复：身份接口只给显示名（.name）时必须当作「取不到」。退回 .name 会给出一个永远匹配不上
# author.username 的非空值，反而把「按评审标记推断」这条兜底路径也关掉 → 每次评审都新建一条汇总。
nameonly=$(mktemp -d); jq -n '{name:"kiro-bot"}' > "$nameonly/platform-user.json"
rc=0; out=$(DRY_RUN_FIXTURE_DIR="$nameonly" codeup_bot_username 2>/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "bot_username: 身份接口只有 .name → 非零（不拿显示名冒充用户名）"
assert_eq "$out" "" "bot_username: 只有 .name 时不输出任何用户名"
rm -rf "$nameonly"

# 复审修复：评论列表达到常见单页上限时必须留痕——旧汇总落在页外会被误判成「首次评审」
pagedir=$(mktemp -d); jq -n '[range(5) | {comment_biz_id:"x", comment_type:"GLOBAL_COMMENT", content:"c"}]' > "$pagedir/list-comments.json"
err=$(DRY_RUN_FIXTURE_DIR="$pagedir" CODEUP_COMMENT_PAGE_HINT=5 codeup_list_global_comments 7 2>&1 >/dev/null)
assert_contains "$err" "已达常见单页上限" "list_comments: 条数达上限时告警（分页参数未实测，只能留痕）"
err=$(DRY_RUN_FIXTURE_DIR="$pagedir" CODEUP_COMMENT_PAGE_HINT=6 codeup_list_global_comments 7 2>&1 >/dev/null)
assert_not_contains "$err" "已达常见单页上限" "list_comments: 未达上限时不告警"
rm -rf "$pagedir"

# ============ 协调者复审修复 ============

# ---- R7：CODEUP_RETRY_BACKOFF 必须校验 ----
# 不校验时 `five` 会被 $(( )) 当 0 用（退避被静默关掉，429/5xx 直接三连击），`5s` 直接算术报错
# （set -e 下让整次评审挂掉）；超大值会把流水线挂住。
assert_eq "$(CODEUP_RETRY_BACKOFF=0 _codeup_retry_backoff 2>/dev/null)" "0" "R7：0 被接受（测试靠它关掉退避）"
assert_eq "$(CODEUP_RETRY_BACKOFF=7 _codeup_retry_backoff 2>/dev/null)" "7" "R7：合法整数原样采用"
assert_eq "$(CODEUP_RETRY_BACKOFF=60 _codeup_retry_backoff 2>/dev/null)" "60" "R7：上限 60 被接受"
assert_eq "$(unset CODEUP_RETRY_BACKOFF; _codeup_retry_backoff 2>/dev/null)" "5" "R7：未设置 → 默认 5"
assert_eq "$(CODEUP_RETRY_BACKOFF= _codeup_retry_backoff 2>/dev/null)" "5" "R7：空串 → 默认 5"
for bad in five 5s -1 61 3.5 " " "0;rm"; do
  out=$(CODEUP_RETRY_BACKOFF="$bad" _codeup_retry_backoff 2>/dev/null)
  err=$(CODEUP_RETRY_BACKOFF="$bad" _codeup_retry_backoff 2>&1 >/dev/null)
  assert_eq "$out" "5" "R7：非法取值 [${bad}] → 用默认 5"
  assert_contains "$err" "不是 0–60 的整数" "R7：非法取值 [${bad}] 告警"
done
# 非整数取值下 _codeup_retry_sleep 不能因算术错误退出（原来 `5s` 会让 $(( )) 报错）
rc=0; (set -e; CODEUP_RETRY_BACKOFF=5s _codeup_retry_sleep 0 >/dev/null 2>&1) || rc=$?
assert_rc "$rc" 0 "R7：非整数取值下 _codeup_retry_sleep 不再触发算术错误"

# ---- R6：身份接口也要重试（一次传输抖动不该让本次退化为新建）----
rc=0; err=$(CODEUP_RETRY_BACKOFF=0 DRY_RUN_FAIL_ROUTES="platform-user:000" codeup_bot_username 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "R6：身份接口传输失败（000）→ 非零"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN GET')" "3" "R6：000 共尝试 3 次（与其它三个封装同一策略）"
assert_contains "$err" "codeup_bot_username: HTTP 000，第 1 次尝试失败" "R6：重试留痕带函数名"
# 403 是确定性失败，不重试，且日志不能把网络问题写成权限问题
rc=0; err=$(DRY_RUN_FAIL_ROUTES="platform-user:403" codeup_bot_username 2>&1 >/dev/null) || rc=$?
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN GET')" "1" "R6：403 不重试"
assert_contains "$err" "403 表示令牌未勾选平台用户权限" "R6：403 的解释只出现在 403 语境下"
# 身份接口 200 但没有 username 字段 → 明确留痕，不静默
err=$(codeup_bot_username 2>&1 >/dev/null || true)
assert_contains "$err" "没有 username 字段" "R6：200 但缺 username 时留痕"

# ---- R8：新建评论的作者用户名日志必须同时兼容对象与数组两种响应形态 ----
# 这是运维拿到 CODEUP_BOT_USERNAME 取值的唯一途径；本文件头注释就写明官方响应体形态在接口之间
# 不一致（CreateChangeRequestComment 被记为 snake_case 数组），只认对象的话这条日志可能永远不打印。
md=$(mktemp); printf '## 🤖 Kiro 代码评审\n' > "$md"
err=$(DRY_RUN_FIXTURE_DIR="$FX/created" codeup_post_comment 7 "$md" 2>&1 >/dev/null)
assert_contains "$err" "新建评论的作者用户名=aliyun:kingdooo_hvFXC" "R8：对象形态响应能取到作者用户名"
err=$(DRY_RUN_FIXTURE_DIR="$FX/created-array" codeup_post_comment 7 "$md" 2>&1 >/dev/null)
assert_contains "$err" "新建评论的作者用户名=aliyun:kingdooo_hvFXC" "R8：数组形态响应同样能取到作者用户名"
# 形态不认识时只是不打这条日志，绝不失败
rc=0; err=$(codeup_post_comment 7 "$md" 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "R8：响应形态不认识（DRY_RUN 默认 []）时仍算成功"
assert_not_contains "$err" "新建评论的作者用户名" "R8：取不到就不打这条日志"

# ---- R3（API 侧的一半）：绝不 PUT 空正文 ----
empty=$(mktemp); : > "$empty"
rc=0; err=$(codeup_update_comment 7 abc "$empty" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "R3：待写入正文为空 → 拒绝更新"
assert_contains "$err" "覆盖成空白" "R3：报错说明为什么拒绝"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN PUT')" "0" "R3：空正文时一个请求都不发"
rm -f "$empty" "$md"
unset DRY_RUN

report
