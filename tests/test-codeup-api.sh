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
md=$(mktemp); printf '# Kiro 代码评审\n<!-- kiro-review:abc1234 run:2 -->\n' > "$md"
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

# 复审修复：评论列表条数达到异常保护阈值时必须留痕——接口文档不分页，但服务端若有未文档化上限，旧汇总会被误判成「首次评审」
pagedir=$(mktemp -d); jq -n '[range(5) | {comment_biz_id:"x", comment_type:"GLOBAL_COMMENT", content:"c"}]' > "$pagedir/list-comments.json"
err=$(DRY_RUN_FIXTURE_DIR="$pagedir" CODEUP_COMMENT_PAGE_HINT=5 codeup_list_global_comments 7 2>&1 >/dev/null)
assert_contains "$err" "达到异常保护阈值" "list_comments: 条数达阈值时告警（异常保护，只留痕）"
err=$(DRY_RUN_FIXTURE_DIR="$pagedir" CODEUP_COMMENT_PAGE_HINT=6 codeup_list_global_comments 7 2>&1 >/dev/null)
assert_not_contains "$err" "达到异常保护阈值" "list_comments: 未达阈值时不告警"
# 票 05 复审修复：非整数取值不能让这条告警**永久失效**（bash 算术错误 + 恒取假），
# 必须回落默认值并留痕。默认 100 > 5 条，所以这次不该告警，但也不该报算术错误。
err=$(DRY_RUN_FIXTURE_DIR="$pagedir" CODEUP_COMMENT_PAGE_HINT=100条 codeup_list_global_comments 7 2>&1 >/dev/null)
assert_contains "$err" "不是 ≥1 的整数，按默认 100 处理" "list_comments: PAGE_HINT 非整数 → 回落默认并留痕"
assert_not_contains "$err" "value too great for base" "list_comments: PAGE_HINT 非整数不漏 bash 算术报错"
assert_not_contains "$err" "达到异常保护阈值" "list_comments: 回落到 100 后 5 条不算达阈值"
# 正控：回落后的默认值真的还在比较（把 fixture 撑到 100 条应重新告警）
jq -n '[range(100) | {comment_biz_id:"x", comment_type:"GLOBAL_COMMENT", content:"c"}]' > "$pagedir/list-comments.json"
err=$(DRY_RUN_FIXTURE_DIR="$pagedir" CODEUP_COMMENT_PAGE_HINT=100条 codeup_list_global_comments 7 2>&1 >/dev/null)
assert_contains "$err" "达到异常保护阈值（100；" "list_comments: 回落后的默认阈值仍在生效（正控）"
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
md=$(mktemp); printf '# Kiro 代码评审\n' > "$md"
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

# ============ 票 04：行内评论相关接口 ============
# 路径、字段与响应形态一律以 scripts/probe/probe-codeup-inline.sh 的实测为准（spec §4.7.1）。
IFX=fixtures/inline

# ---- route 名：按「方法 + 路径 + body 里的评论类型」区分 ----
# 行内评论的列表/创建与汇总评论走同一组路径，只有 body 里的 comment_type 不同；
# 不区分的话 DRY_RUN 下没法给两者喂不同的 fixture，整条行内通路就只能上真实 Codeup 验证。
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments/list '{"comment_type":"GLOBAL_COMMENT"}')" "list-comments" "route: 汇总评论列表"
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments/list '{"comment_type":"INLINE_COMMENT"}')" "list-comments-inline" "route: 行内评论列表"
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments '{"comment_type":"INLINE_COMMENT","content":"x"}')" "create-comment-inline" "route: 新建行内评论"
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments '{"comment_type":"GLOBAL_COMMENT","content":"x"}')" "create-comment" "route: 新建汇总评论"
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/review '{"submitDraftCommentIds":["x"]}')" "submit-review" "route: 一次提交草稿"
# body 由 jq 生成，带不带 -c 决定 `:` 后有没有空格；只认一种形态的话换个调用方式就会静默判错 route
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments '{
  "comment_type": "INLINE_COMMENT",
  "content": "x"
}')" "create-comment-inline" "route: 非紧凑 body 同样认得出行内评论"
# 不传 body 时（票 01–03 的调用形式）行为不变
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments/list)" "list-comments" "route: 不传 body 仍按汇总评论列表（向后兼容）"
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments)" "create-comment" "route: 不传 body 仍按新建汇总评论（向后兼容）"
# 汇总评论的正文里出现「comment_type":"INLINE_COMMENT」字样时不能被误判：
# 正文是 JSON 字符串，里面的引号已被转义成 \" ，与 body 里真正的字段不同形
md=$(mktemp); printf '本条评论提到 API 字段 comment_type=INLINE_COMMENT 与 "comment_type":"INLINE_COMMENT"。\n' > "$md"
body=$(jq -n --rawfile content "$md" '{comment_type: "GLOBAL_COMMENT", content: $content, draft: false, resolved: false}')
assert_eq "$(_codeup_route_name POST /a/changeRequests/7/comments "$body")" "create-comment" "route: 汇总评论正文里提到行内评论类型时不被误判"
rm -f "$md"

# ---- DRY_RUN fixture 序列：同一 route 多次调用时依次取 <route>.<n>.json ----
seqdir=$(mktemp -d)
jq -n '{comment_biz_id:"draft-1"}' > "$seqdir/create-comment-inline.1.json"
jq -n '{comment_biz_id:"draft-2"}' > "$seqdir/create-comment-inline.2.json"
jq -n '{comment_biz_id:"draft-fallback"}' > "$seqdir/create-comment-inline.json"
ibody='{"comment_type":"INLINE_COMMENT","content":"x"}'
# 必须把响应写进文件：`$(...)` 在子 shell 里跑，序号计数器（与 CODEUP_HTTP_CODE 一样）传不回来。
# 这条约定写在库注释里，生产侧的 codeup_create_inline_comment 也是文件式接口。
export DRY_RUN_FIXTURE_DIR="$seqdir"
_codeup_dry_seq_reset
_codeup_request POST /a/changeRequests/7/comments "$ibody" > "$seqdir/r1" 2>/dev/null
_codeup_request POST /a/changeRequests/7/comments "$ibody" > "$seqdir/r2" 2>/dev/null
_codeup_request POST /a/changeRequests/7/comments "$ibody" > "$seqdir/r3" 2>/dev/null
assert_eq "$(jq -r .comment_biz_id "$seqdir/r1")" "draft-1" "dry_run 序列: 第 1 次取 .1.json"
assert_eq "$(jq -r .comment_biz_id "$seqdir/r2")" "draft-2" "dry_run 序列: 第 2 次取 .2.json"
assert_eq "$(jq -r .comment_biz_id "$seqdir/r3")" "draft-fallback" "dry_run 序列: 序号用尽后退回 <route>.json"
# 别的 route 的调用不影响本 route 的序号
_codeup_request POST /a/changeRequests/7/comments/list '{"comment_type":"GLOBAL_COMMENT"}' >/dev/null 2>&1
_codeup_request POST /a/changeRequests/7/comments "$ibody" > "$seqdir/r4" 2>/dev/null
assert_eq "$(jq -r .comment_biz_id "$seqdir/r4")" "draft-fallback" "dry_run 序列: 每个 route 各自计数"
# 重试（失败注入）不消耗序号：否则一次 5xx 就会把后面的 fixture 顺序全错开
DRY_RUN_FAIL_ROUTES="create-comment-inline:500" _codeup_request POST /a/changeRequests/7/comments "$ibody" >/dev/null 2>&1
unset DRY_RUN_FIXTURE_DIR
seqdir2=$(mktemp -d)
_codeup_dry_seq_reset
jq -n '{comment_biz_id:"only-1"}' > "$seqdir2/create-comment-inline.1.json"
DRY_RUN_FIXTURE_DIR="$seqdir2" DRY_RUN_FAIL_ROUTES="create-comment-inline:500" \
  _codeup_request POST /a/changeRequests/7/comments "$ibody" >/dev/null 2>&1
DRY_RUN_FIXTURE_DIR="$seqdir2" _codeup_request POST /a/changeRequests/7/comments "$ibody" > "$seqdir2/r1" 2>/dev/null
assert_eq "$(jq -r .comment_biz_id "$seqdir2/r1")" "only-1" "dry_run 序列: 注入失败的那次不消耗序号"
rm -rf "$seqdir" "$seqdir2"

# ---- 版本列表（ListChangeRequestPatchSets）----
rc=0; err=$(DRY_RUN_FIXTURE_DIR="$IFX/normal" codeup_list_patchsets 7 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "list_patchsets: DRY_RUN 成功"
assert_contains "$err" "changeRequests/7/diffs/patches" "list_patchsets: URL 路径（实测 GET diffs/patches）"
out=$(DRY_RUN_FIXTURE_DIR="$IFX/normal" codeup_list_patchsets 7 2>/dev/null)
assert_eq "$(printf '%s' "$out" | jq -r 'length')" "4" "list_patchsets: 返回 fixture 内容"
rc=0; err=$(CODEUP_RETRY_BACKOFF=0 DRY_RUN_FAIL_ROUTES="list-patchsets:500" codeup_list_patchsets 7 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "list_patchsets: 5xx 重试后仍失败"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN GET')" "3" "list_patchsets: 5xx 共尝试 3 次（与其它封装同一策略）"

# ---- 选版本对：from = 最新 MERGE_TARGET，to = 最新 MERGE_SOURCE（按 versionNo）----
out=$(codeup_select_patchset_pair < "$IFX/normal/list-patchsets.json")
assert_eq "$out" "$(printf 'tgt-v1\tsrc-v6\td97b8017eeee\ta12311be11112222333344445555666677778888')" \
  "select_patchset_pair: 取 versionNo 最大的一对，并带上 to 与 from 两侧的 commitId"
# from 侧的 commitId 排在最后（追加而不是插入）：调用方 cut -f1..3 的老写法不受影响。
# 它用来核对 Codeup 侧的比较基准与本地 merge-base 是否一致（R8 的告警）。
assert_eq "$(printf '%s' "$out" | cut -f4)" "a12311be11112222333344445555666677778888" "select_patchset_pair: 第 4 列是 from 侧 commitId"
assert_eq "$(printf '%s' "$out" | cut -f1,2,3)" "$(printf 'tgt-v1\tsrc-v6\td97b8017eeee')" "select_patchset_pair: 前三列语义不变"
# 缺 commitId 时对应列为空串，不能整体选不出来
assert_eq "$(jq -c 'map(if .relatedMergeItemType == "MERGE_TARGET" then del(.commitId) else . end)' "$IFX/normal/list-patchsets.json" \
  | codeup_select_patchset_pair | cut -f4)" "" "select_patchset_pair: from 缺 commitId 时第 4 列为空串"
# versionNo 乱序、类型不合形都不能选错
out=$(codeup_select_patchset_pair < "$IFX/shuffled/list-patchsets.json")
assert_eq "$(printf '%s' "$out" | cut -f2)" "src-v6" "select_patchset_pair: 顺序打乱后仍取 versionNo 最大的合并源版本"
assert_eq "$(printf '%s' "$out" | cut -f1)" "tgt-v2" "select_patchset_pair: 合并目标版本同样取最新"
# 缺一侧 → rc 1（调用方回落 INLINE_COMMENT=0 渲染）
rc=0; err=$(codeup_select_patchset_pair < "$IFX/no-target/list-patchsets.json" 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 1 "select_patchset_pair: 没有 MERGE_TARGET → rc 1"
assert_contains "$err" "MERGE_TARGET" "select_patchset_pair: 报错点名缺哪一侧"
rc=0; codeup_select_patchset_pair < /dev/null >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 1 "select_patchset_pair: 空响应 → rc 1"
rc=0; printf 'not json' | codeup_select_patchset_pair >/dev/null 2>&1 || rc=$?
assert_rc "$rc" 1 "select_patchset_pair: 非法 JSON → rc 1（不报 jq 错）"
# {result:[…]} 形态兼容
out=$(jq -c '{result: .}' "$IFX/normal/list-patchsets.json" | codeup_select_patchset_pair)
assert_eq "$(printf '%s' "$out" | cut -f2)" "src-v6" "select_patchset_pair: {result:[…]} 形态兼容"

# ---- 创建行内评论：三个版本字段必传（P1-03 实测缺一即 400）----
imd=$(mktemp); printf '### P0 · 硬编码凭证\n\n改用环境变量。\n' > "$imd"
resp=$(mktemp)
rc=0; err=$(codeup_create_inline_comment 7 "$imd" "src/app.py" 30 from-1 to-2 true "$resp" 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "create_inline: DRY_RUN 成功"
assert_contains "$err" "changeRequests/7/comments" "create_inline: URL"
assert_contains "$err" '"comment_type":"INLINE_COMMENT"' "create_inline: 评论类型"
assert_contains "$err" '"file_path":"src/app.py"' "create_inline: 带文件路径"
assert_contains "$err" '"line_number":30' "create_inline: 行号是数字（新文件侧，P1-02 实测）"
assert_contains "$err" '"patchset_biz_id":"to-2"' "create_inline: patchset_biz_id = to"
assert_contains "$err" '"from_patchset_biz_id":"from-1"' "create_inline: from 版本"
assert_contains "$err" '"to_patchset_biz_id":"to-2"' "create_inline: to 版本"
assert_contains "$err" '"draft":true' "create_inline: 草稿"
assert_contains "$err" '"resolved":false' "create_inline: resolved 必填（中心站缺它报 400）"
# 非草稿（提交失败后的逐条回退）
err=$(codeup_create_inline_comment 7 "$imd" "src/app.py" 30 from-1 to-2 false "$resp" 2>&1 >/dev/null)
assert_contains "$err" '"draft":false' "create_inline: draft=false 走非草稿发布"
# 响应写进指定文件（不能用 $(...) 取：那样 DRY_RUN 的 fixture 序号与 CODEUP_HTTP_CODE 都传不回来）
DRY_RUN_FIXTURE_DIR="$IFX/normal" codeup_create_inline_comment 7 "$imd" a.py 1 f t true "$resp" 2>/dev/null
assert_eq "$(jq -r '.comment_biz_id' "$resp")" "20497727aaaa" "create_inline: 响应体写入指定文件"
# 参数校验：空正文绝不发（一条空的行内评论挂在代码上没法解释，也没法按指纹去重）
emptymd=$(mktemp); : > "$emptymd"
rc=0; err=$(codeup_create_inline_comment 7 "$emptymd" a.py 1 f t true "$resp" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "create_inline: 正文为空 → 拒绝"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN POST')" "0" "create_inline: 正文为空时一个请求都不发"
for bad_line in 0 -1 abc ""; do
  rc=0; err=$(codeup_create_inline_comment 7 "$imd" a.py "$bad_line" f t true "$resp" 2>&1 >/dev/null) || rc=$?
  assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "create_inline: 行号 [${bad_line}] 非法 → 拒绝"
  assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN POST')" "0" "create_inline: 行号 [${bad_line}] 非法时不发请求"
done
rc=0; err=$(codeup_create_inline_comment 7 "$imd" a.py 1 "" t true "$resp" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "create_inline: 缺 from 版本 → 拒绝（P1-03 实测缺一即 400，本地先拦）"
rc=0; err=$(codeup_create_inline_comment 7 "$imd" "" 1 f t true "$resp" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "create_inline: 缺文件路径 → 拒绝"
# ---- 重试策略：创建**不幂等**，只有 429 才重试 ----
# 000（响应丢失）与 5xx 都可能发生在「服务端其实已经建好了」之后。重试的代价很具体：
# 同一行上多出一条重复评论，而第一条的 comment_biz_id 我们从来没拿到过——它永远不会被纳入
# 一次提交、永远不会被删除，之后的去重也看不到它（草稿被状态过滤掉）。
assert_eq "$(_codeup_should_retry_create_inline 429 && echo y || echo n)" "y" "create_inline 重试策略: 429 重试（服务端明确没受理）"
assert_eq "$(_codeup_should_retry_create_inline 000 && echo y || echo n)" "n" "create_inline 重试策略: 000 不重试（可能已经建好了）"
assert_eq "$(_codeup_should_retry_create_inline 500 && echo y || echo n)" "n" "create_inline 重试策略: 5xx 不重试"
assert_eq "$(_codeup_should_retry_create_inline 503 && echo y || echo n)" "n" "create_inline 重试策略: 503 不重试"
assert_eq "$(_codeup_should_retry_create_inline 400 && echo y || echo n)" "n" "create_inline 重试策略: 4xx 不重试"
for code in 400 000 500 502; do
  rc=0; err=$(CODEUP_RETRY_BACKOFF=0 DRY_RUN_FAIL_ROUTES="create-comment-inline:${code}" \
    codeup_create_inline_comment 7 "$imd" a.py 1 f t true "$resp" 2>&1 >/dev/null) || rc=$?
  assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "create_inline: HTTP ${code} → 失败"
  assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN POST')" "1" "create_inline: HTTP ${code} 只发一次请求（创建不幂等）"
done
rc=0; err=$(CODEUP_RETRY_BACKOFF=0 DRY_RUN_FAIL_ROUTES="create-comment-inline:429" \
  codeup_create_inline_comment 7 "$imd" a.py 1 f t true "$resp" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "create_inline: 429 重试后仍失败"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN POST')" "3" "create_inline: 429 共尝试 3 次（服务端明确没受理，重试安全）"
# 对照：别的接口仍按默认策略重试 000/5xx（这条策略只收紧了行内评论创建）
rc=0; err=$(CODEUP_RETRY_BACKOFF=0 DRY_RUN_FAIL_ROUTES="list-comments-inline:500" codeup_list_inline_comments 7 2>&1 >/dev/null) || rc=$?
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN POST')" "3" "对照: 查询类接口（幂等）仍按默认策略重试 5xx"

# ---- 一次提交草稿（ReviewChangeRequest，不带 reviewOpinion）----
ids=$(mktemp); printf 'id-a\nid-b\n' > "$ids"
rc=0; err=$(codeup_submit_drafts 7 "$ids" 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "submit_drafts: DRY_RUN 成功"
assert_contains "$err" "changeRequests/7/review" "submit_drafts: URL（实测 POST review）"
assert_contains "$err" '"submitDraftCommentIds":["id-a","id-b"]' "submit_drafts: 一次提交全部草稿 id"
assert_not_contains "$err" "reviewOpinion" "submit_drafts: 不带 reviewOpinion（不卡合并，spec 非目标）"
rc=0; err=$(codeup_submit_drafts 7 /dev/null 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "submit_drafts: 没有草稿 id → 拒绝（不发一个空提交）"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN POST')" "0" "submit_drafts: 没有 id 时不发请求"
rc=0; err=$(DRY_RUN_FAIL_ROUTES="submit-review:400" codeup_submit_drafts 7 "$ids" 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "submit_drafts: 400 → 失败（调用方退回逐条非草稿发布）"
assert_eq "$(printf '%s\n' "$err" | grep -c 'DRY_RUN POST')" "1" "submit_drafts: 400 不重试"

# ---- 行内评论列表（去重用）----
rc=0; err=$(DRY_RUN_FIXTURE_DIR="$IFX/normal" codeup_list_inline_comments 7 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "list_inline_comments: DRY_RUN 成功"
assert_contains "$err" "changeRequests/7/comments/list" "list_inline_comments: URL"
assert_contains "$err" '"comment_type":"INLINE_COMMENT"' "list_inline_comments: 只要行内评论类型"
# state 过滤刻意不进 body：探测只验证过 comment_type 过滤，state 参数名未实测
assert_not_contains "$err" '"state"' "list_inline_comments: 不凭记忆传未实测的 state 参数"
out=$(DRY_RUN_FIXTURE_DIR="$IFX/normal" codeup_list_inline_comments 7 2>/dev/null)
assert_eq "$(printf '%s' "$out" | jq -r 'length')" "2" "list_inline_comments: 取到行内评论 fixture（与汇总评论列表分开）"

# ---- 删除评论（草稿提交失败后清理，避免同一条问题既留草稿又发正式评论）----
rc=0; err=$(codeup_delete_comment 7 draft-x 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "delete_comment: DRY_RUN 成功"
assert_contains "$err" "DRY_RUN DELETE" "delete_comment: 用 DELETE"
assert_contains "$err" "changeRequests/7/comments/draft-x" "delete_comment: URL 带评论 biz_id"
rc=0; err=$(DRY_RUN_FAIL_ROUTES="delete-comment:404" codeup_delete_comment 7 draft-x 2>&1 >/dev/null) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "delete_comment: 404 → 失败（调用方只打警告，不中断评审）"
rm -f "$imd" "$emptymd" "$resp" "$ids"

unset DRY_RUN

report
