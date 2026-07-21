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
rm -f "$md"

# --- 真实响应契约：_codeup_http_ok 状态码判定 ---
unset DRY_RUN
assert_rc "$(_codeup_http_ok 200 && echo 0 || echo 1)" "0" "http_ok: 200"
assert_rc "$(_codeup_http_ok 201 && echo 0 || echo 1)" "0" "http_ok: 201"
assert_rc "$(_codeup_http_ok 400 && echo 0 || echo 1)" "1" "http_ok: 400"

# --- 重试分类 ---
assert_rc "$(_codeup_should_retry 500 && echo y || echo n)" "y" "retry: 5xx 重试"
assert_rc "$(_codeup_should_retry 429 && echo y || echo n)" "y" "retry: 429 重试"
assert_rc "$(_codeup_should_retry 403 && echo y || echo n)" "n" "retry: 403 不重试"
assert_rc "$(_codeup_should_retry 000 && echo y || echo n)" "y" "retry: 传输错误(000) 重试"

report
