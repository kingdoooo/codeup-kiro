#!/usr/bin/env bash
# 探测 Codeup 行内评论相关 OpenAPI 的真实行为（spec §4.7：P1-00~P1-06、P1-09）。
#
# 只能在【测试 MR】上运行：会创建草稿评论、提交评审、更新评论，并在结束时尝试删除。
# 复用生产库 scripts/lib/codeup-api.sh 的请求原语（同一套重试/状态码判定），
# 新端点先在本脚本内以局部函数封装，Phase 1 实现时再下沉到 lib。
#
# 必填环境变量：
#   PROBE_I_KNOW_THIS_IS_A_TEST_MR=1
#   YUNXIAO_TOKEN 或 YUNXIAO_TOKEN_FILE（文件内容为令牌；令牌需「代码只读 + 合并请求读写」）
#   YUNXIAO_ORG_ID  CODEUP_REPO_ID  MR_LOCAL_ID
#   PROBE_FILE       MR 中被修改的文件路径（相对仓库根，如 src/app.py）
#   PROBE_LINE_NEW   该文件在【新版本】中一个新增/修改行的行号
# 可选：
#   PROBE_LINE_OLD   该文件在【旧版本】中一个被删除行的行号（测 line_number 侧向语义）
#   PROBE_KEEP=1     结束时不删除创建的评论（便于在 UI 里看 <details> 渲染与通知）
#
# 任何输出都不包含令牌。结果同时写入 ./probe-codeup-inline.<时间>.json。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/codeup-api.sh
source "${SCRIPT_DIR}/../lib/codeup-api.sh"

: "${PROBE_I_KNOW_THIS_IS_A_TEST_MR:?拒绝运行：本脚本会在 MR 上创建/删除评论，请确认是测试 MR 后设置 PROBE_I_KNOW_THIS_IS_A_TEST_MR=1}"
if [[ -z "${YUNXIAO_TOKEN:-}" && -n "${YUNXIAO_TOKEN_FILE:-}" ]]; then
  YUNXIAO_TOKEN=$(tr -d '\r\n' < "$YUNXIAO_TOKEN_FILE"); export YUNXIAO_TOKEN
fi
: "${YUNXIAO_TOKEN:?缺少 YUNXIAO_TOKEN（或 YUNXIAO_TOKEN_FILE）}"
: "${YUNXIAO_ORG_ID:?}" "${CODEUP_REPO_ID:?}" "${MR_LOCAL_ID:?}" "${PROBE_FILE:?}" "${PROBE_LINE_NEW:?}"
PROBE_LINE_OLD="${PROBE_LINE_OLD:-}"
PROBE_KEEP="${PROBE_KEEP:-0}"
for cmd in curl jq; do command -v "$cmd" >/dev/null || { echo "缺少依赖：$cmd" >&2; exit 1; }; done

MR_BASE="/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${MR_LOCAL_ID}"
TS=$(date '+%Y%m%d-%H%M%S')
OUT_JSON="./probe-codeup-inline.${TS}.json"
RESULTS='[]'
CREATED_IDS=()

log()    { echo "[probe] $*" >&2; }
record() { # id verdict detail [extra-json]
  local extra="${4:-null}"
  RESULTS=$(jq -c --arg id "$1" --arg v "$2" --arg d "$3" --argjson x "$extra" \
    '. + [{id:$id, verdict:$v, detail:$d, extra:$x}]' <<<"$RESULTS")
  printf '[%-6s] %-7s %s\n' "$1" "$2" "$3" >&2
}
# method path [body] → 全局 RESP（响应体）与 CODEUP_HTTP_CODE
call() {
  local tmp; tmp=$(mktemp)
  _codeup_request "$1" "$2" "${3:-}" > "$tmp"
  RESP=$(cat "$tmp"); rm -f "$tmp"
}
ok() { _codeup_http_ok "$CODEUP_HTTP_CODE"; }
jget() { jq -r "$1" <<<"$RESP" 2>/dev/null || echo ""; }

# ---------- P1-00 当前身份与 MR 基本信息 ----------
call GET "/oapi/v1/platform/user"
if ok; then ME=$(jget '.username // .name // empty'); record P1-00a PASS "令牌身份 username=${ME:-?}"; else record P1-00a FAIL "GetUserByToken HTTP ${CODEUP_HTTP_CODE}"; ME=""; fi

call GET "$MR_BASE"
if ok; then
  record P1-00b PASS "MR #${MR_LOCAL_ID} state=$(jget .state) $(jget .sourceBranch) -> $(jget .targetBranch) title=$(jget .title | cut -c1-40)"
  [[ "$(jget .state)" =~ ^(opened|OPENED|UNDER_REVIEW)$ ]] || log "警告：MR 非打开状态，后续步骤可能失败"
else
  record P1-00b FAIL "GetChangeRequest HTTP ${CODEUP_HTTP_CODE}: $(cut -c1-160 <<<"$RESP")"; exit 1
fi

# ---------- P1-01 版本列表 → 选 from/to ----------
call GET "$MR_BASE/diffs/patches"
if ! ok; then record P1-01 FAIL "ListChangeRequestPatchSets HTTP ${CODEUP_HTTP_CODE}"; exit 1; fi
PATCHSETS="$RESP"
jq -r '.[] | "  v\(.versionNo)\t\(.relatedMergeItemType)\t\(.shortId // (.commitId|.[0:8]))\t\(.patchSetBizId)"' <<<"$PATCHSETS" >&2 || true
FROM_ID=$(jq -r '[.[] | select(.relatedMergeItemType=="MERGE_TARGET")] | sort_by(.versionNo) | last | .patchSetBizId // empty' <<<"$PATCHSETS")
TO_ID=$(jq -r '[.[] | select(.relatedMergeItemType=="MERGE_SOURCE")] | sort_by(.versionNo) | last | .patchSetBizId // empty' <<<"$PATCHSETS")
TO_SHA=$(jq -r '[.[] | select(.relatedMergeItemType=="MERGE_SOURCE")] | sort_by(.versionNo) | last | .commitId // empty' <<<"$PATCHSETS")
N_SRC=$(jq '[.[] | select(.relatedMergeItemType=="MERGE_SOURCE")] | length' <<<"$PATCHSETS")
N_TGT=$(jq '[.[] | select(.relatedMergeItemType=="MERGE_TARGET")] | length' <<<"$PATCHSETS")
if [[ -n "$FROM_ID" && -n "$TO_ID" ]]; then
  record P1-01 PASS "MERGE_SOURCE×${N_SRC} MERGE_TARGET×${N_TGT}；from=${FROM_ID:0:8}… to=${TO_ID:0:8}… (to.sha=${TO_SHA:0:8})" \
    "$(jq -c '{n_source:'"$N_SRC"', n_target:'"$N_TGT"'}' <<<'{}')"
else
  record P1-01 FAIL "无法同时选出 MERGE_TARGET 与 MERGE_SOURCE（from='${FROM_ID}' to='${TO_ID}'）"; exit 1
fi

# ---------- P1-06a 现有评论（去重可行性）----------
call POST "$MR_BASE/comments/list" '{}'
if ok; then
  TOTAL=$(jq 'length' <<<"$RESP"); MINE=$(jq --arg me "$ME" '[.[] | select(.author.username==$me)] | length' <<<"$RESP")
  TYPES=$(jq -r '[.[] | .comment_type] | group_by(.) | map("\(.[0])×\(length)") | join(" ")' <<<"$RESP")
  record P1-06a PASS "现有评论 ${TOTAL} 条（本账号 ${MINE}）类型分布：${TYPES:-无}"
else
  record P1-06a FAIL "ListMergeRequestComments HTTP ${CODEUP_HTTP_CODE}: $(cut -c1-160 <<<"$RESP")"
fi

# ---------- P1-02 行内草稿：新文件侧 / 旧文件侧 ----------
make_inline_body() { # content line [with_from_to=1]
  local with="${3:-1}"
  if [[ "$with" == "1" ]]; then
    jq -cn --arg c "$1" --argjson l "$2" --arg f "$PROBE_FILE" --arg ps "$TO_ID" --arg from "$FROM_ID" --arg to "$TO_ID" \
      '{comment_type:"INLINE_COMMENT", content:$c, draft:true, resolved:false, file_path:$f, line_number:$l, patchset_biz_id:$ps, from_patchset_biz_id:$from, to_patchset_biz_id:$to}'
  else
    jq -cn --arg c "$1" --argjson l "$2" --arg f "$PROBE_FILE" --arg ps "$TO_ID" \
      '{comment_type:"INLINE_COMMENT", content:$c, draft:true, resolved:false, file_path:$f, line_number:$l, patchset_biz_id:$ps}'
  fi
}
probe_inline() { # id label line with_from_to
  call POST "$MR_BASE/comments" "$(make_inline_body "[codeup-kiro probe ${1}] ${2}（自动创建，可删除）" "$3" "$4")"
  if ok; then
    local cid; cid=$(jget '.comment_biz_id')
    [[ -n "$cid" && "$cid" != "null" ]] && CREATED_IDS+=("$cid")
    record "$1" PASS "HTTP ${CODEUP_HTTP_CODE} id=${cid:0:8}… state=$(jget .state) can_located=$(jget .location.can_located) located_line=$(jget .location.located_line_number) out_dated=$(jget .out_dated)" \
      "$(jq -c '{state:.state, location:.location, line_number:.line_number, filePath:.filePath}' <<<"$RESP" 2>/dev/null || echo null)"
  else
    record "$1" FAIL "HTTP ${CODEUP_HTTP_CODE}: $(cut -c1-200 <<<"$RESP")"
  fi
}
probe_inline P1-02a "新文件侧行 L${PROBE_LINE_NEW}" "$PROBE_LINE_NEW" 1
if [[ -n "$PROBE_LINE_OLD" ]]; then probe_inline P1-02b "旧文件侧行 L${PROBE_LINE_OLD}" "$PROBE_LINE_OLD" 1; else record P1-02b SKIP "未提供 PROBE_LINE_OLD"; fi

# ---------- P1-03 必填字段：不带 from/to ----------
probe_inline P1-03 "缺 from/to（预期 400；若成功说明文档的“必传”不成立）" "$PROBE_LINE_NEW" 0

# ---------- P1-04 草稿一次提交，不带 reviewOpinion ----------
if ((${#CREATED_IDS[@]})); then
  IDS_JSON=$(printf '%s\n' "${CREATED_IDS[@]}" | jq -R . | jq -cs .)
  call POST "$MR_BASE/review" "$(jq -cn --argjson ids "$IDS_JSON" '{submitDraftCommentIds:$ids}')"
  if ok; then record P1-04 PASS "ReviewChangeRequest(无 opinion) HTTP ${CODEUP_HTTP_CODE} result=$(jget .result)"
  else record P1-04 FAIL "HTTP ${CODEUP_HTTP_CODE}: $(cut -c1-200 <<<"$RESP")（若提示需为评审人，见 spec R2）"; fi
  call POST "$MR_BASE/comments/list" '{"comment_type":"INLINE_COMMENT"}'
  if ok; then
    STATES=$(jq -r --argjson ids "$IDS_JSON" '[.[] | select(.comment_biz_id as $c | $ids | index($c)) | .state] | join(",")' <<<"$RESP")
    record P1-06b PASS "提交后我方草稿状态：${STATES:-未在列表中找到}"
  fi
else
  record P1-04 SKIP "没有成功创建的草稿"
fi

# ---------- P1-05 原地更新自己的评论 ----------
if ((${#CREATED_IDS[@]})); then
  call PUT "$MR_BASE/comments/${CREATED_IDS[0]}" "$(jq -cn --arg c "[codeup-kiro probe P1-02a] 已由探测脚本原地更新 ${TS}" '{content:$c}')"
  if ok; then record P1-05 PASS "UpdateChangeRequestComment HTTP ${CODEUP_HTTP_CODE} result=$(jget .result)（请在 UI 确认是否收到通知）"
  else record P1-05 FAIL "HTTP ${CODEUP_HTTP_CODE}: $(cut -c1-200 <<<"$RESP")"; fi
fi

# ---------- P1-09 <details> 渲染（需人工在 UI 查看）----------
DETAILS_MD=$(cat <<'MD'
## 🤖 codeup-kiro 渲染探测
<!-- kiro-review:probe -->
| 项 | 值 |
|---|---|
| 目的 | 检查 Codeup 是否渲染 `<details>` 与表格 |

<details><summary>折叠区（点开应看到一行列表）</summary>

- `src/app.py:17` **P2 · 示例问题** — 这是折叠区内容
</details>

P0 必须修复 · P1 应当修复 · P2 可选改进
MD
)
call POST "$MR_BASE/comments" "$(jq -cn --arg c "$DETAILS_MD" '{comment_type:"GLOBAL_COMMENT", content:$c, draft:false, resolved:false}')"
if ok; then cid=$(jget '.comment_biz_id'); CREATED_IDS+=("$cid"); record P1-09 INFO "已发汇总评论 id=${cid:0:8}…，请到 MR 页面确认 <details> 是否可折叠、表格是否渲染"
else record P1-09 FAIL "HTTP ${CODEUP_HTTP_CODE}: $(cut -c1-200 <<<"$RESP")"; fi

# ---------- 清理 ----------
if [[ "$PROBE_KEEP" == "1" ]]; then
  record CLEAN SKIP "PROBE_KEEP=1，保留 ${#CREATED_IDS[@]} 条评论供 UI 检查；手工删除或再次运行时清理"
else
  for cid in "${CREATED_IDS[@]}"; do
    call DELETE "$MR_BASE/comments/${cid}"
    if ok; then record CLEAN PASS "删除 ${cid:0:8}… HTTP ${CODEUP_HTTP_CODE}"; else record CLEAN WARN "删除 ${cid:0:8}… HTTP ${CODEUP_HTTP_CODE}（可能需人工删除）"; fi
  done
fi

jq -n --arg ts "$TS" --arg mr "$MR_LOCAL_ID" --arg file "$PROBE_FILE" --argjson results "$RESULTS" \
  '{probe:"codeup-inline", ts:$ts, mr_local_id:$mr, probe_file:$file, results:$results}' > "$OUT_JSON"
log "结果已写入 $OUT_JSON（不含令牌）。请把 PASS/FAIL 结论回填到 .scratch/codeup-kiro-v2/spec.md §4.7"
