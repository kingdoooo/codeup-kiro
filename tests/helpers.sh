#!/usr/bin/env bash
# 极简断言库。失败即打印并退出非零。
TESTS_PASSED=0

assert_eq() {  # 实际值 期望值 说明
  if [[ "$1" == "$2" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $3 — 期望 [$2]，实际 [$1]" >&2
    exit 1
  fi
}

assert_contains() {  # 内容 子串 说明
  if printf '%s' "$1" | grep -qF -- "$2"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $3 — 未找到子串 [$2]，内容: [$1]" >&2
    exit 1
  fi
}

assert_not_contains() {  # 内容 子串 说明
  if printf '%s' "$1" | grep -qF -- "$2"; then
    echo "FAIL: $3 — 不应出现子串 [$2]" >&2
    exit 1
  else
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

assert_rc() { assert_eq "$1" "$2" "$3"; }

# DRY_RUN 下数一数脚本真的发了哪些请求（stderr 上每个请求一行 `DRY_RUN <方法> <URL>`）。
# 用法：req_count "$OUT" PUT [URL 片段（ERE）]
# 端到端与变异测试都要用：判定「原地更新」还是「新建」全靠这个，实现只能有一份——
# DRY_RUN 的日志行格式一变，两处拷贝里只改一处的那一处会静静地一直数出 0。
req_count() {
  local pat="DRY_RUN $2 "
  [[ -n "${3:-}" ]] && pat="${pat}.*$3"
  printf '%s\n' "$1" | grep -cE -- "$pat" || true
}

# DRY_RUN 下本次「创建行内评论」请求的 body（每条一行 compact JSON）。
# 用法：inline_bodies "$OUT"
# 必须按 file_path 过滤：查现有行内评论那次请求的 body 也是 {"comment_type":"INLINE_COMMENT"}，
# 只按类型抓会多算一条。端到端与变异测试都要用它判断「到底发了几条行内评论、发到哪一行」，
# 所以实现只能有一份——过滤条件一变，两处拷贝里没改的那一处会静静地数错。
# `|| true`：一条行内评论都没发时 grep 以 1 退出，而测试文件都开了 pipefail——
# 没有这个兜底，「零条」这种完全正常的用例会让整个测试文件在此处无提示中止（与 req_count 同理）。
inline_bodies() {
  { printf '%s\n' "$1" | grep -F 'DRY_RUN body: {"comment_type":"INLINE_COMMENT"' || true; } \
    | sed 's/^DRY_RUN body: //' | jq -c 'select(has("file_path"))'
}

# 汇总/降级/失败评论里的「元信息行」（`| \`sha\` | \`src\` → \`dst\` | 时间 | diff |`）。
# 单测与变异测试都要用它判断「分支名有没有撑破表格 / 有没有把原始 HTML 带进单元格」，
# 所以实现只能有一份——提取管道一变，两处拷贝里没改的那一处会静静地返回空串，
# 然后以「过滤失效」的名义失败，把维护者引向错误的方向（与 req_count/inline_bodies 同一理由）。
# 没匹配到时返回空串而不是让调用方在 pipefail 下直接中止（调用方要能打出自己的诊断）。
meta_row() { printf '%s\n' "$1" | { grep -F '| `' || true; } | { grep -F ' → ' || true; } | head -1; }

# 端到端 fixture 里机器人账号的用户名（取自 spec §4.7.1 P1-00 实测值）
TEST_BOT_USERNAME='aliyun:kingdooo_hvFXC'

report() { echo "OK: ${TESTS_PASSED} 个断言通过（$0）"; }

# --- 版本列表 fixture 的唯一实现（票 17-fix3 ⑫）---
# 端到端与变异两个套件原先各有一份，取值语义还不一样（变异那份把 OMIT/NONE 当字面 commitId 写进去，
# 于是变异「看似被杀」）。这里只留一份，未知模式**硬错误**而不是静默直通。
# 用法：由各套件的 tweak 钩子在 $CASE/work 里调用；读下面这些全局量：
#   PS_SRC  最新 MERGE_SOURCE 的 commitId：HEAD / HEAD12 / HEAD6 / HEADUP / PARENT / CHILD / ORPHAN /
#           OMIT（不带该字段）/ RAW:<原样值>
#   PS_TGT  最新 MERGE_TARGET 的 commitId：BASE / OMIT / NONE（整条不写）/ RAW:<原样值>
#   PS_SRC_ID / PS_TGT_ID  两个版本的 patchSetBizId
#   PS_FIXTURE_DIR         写到哪个目录
mk_patchsets_fixture() {
  local head base src tgt n
  : "${PS_FIXTURE_DIR:?mk_patchsets_fixture: 需要 PS_FIXTURE_DIR}"
  mkdir -p "$PS_FIXTURE_DIR"
  head=$(git rev-parse HEAD)
  base=$(git merge-base origin/master HEAD)
  case "${PS_SRC:-HEAD}" in
    HEAD)   src="$head" ;;
    HEAD12) src="${head:0:12}" ;;
    HEAD6)  src="${head:0:6}" ;;                    # 短于 git 短 sha 下限（7 位）
    HEADUP) src=$(printf '%s' "$head" | tr 'a-f' 'A-F') ;;
    PARENT) src=$(git rev-parse 'HEAD^') ;;
    # 后代：在 HEAD 之上再造一个提交，再把工作树退回 HEAD（对象仍在克隆里，模拟「新推送已被 fetch 到」）
    CHILD)  echo "child of head" >> src/app.py; git commit -qam "child commit"
            src=$(git rev-parse HEAD); git reset -q --hard 'HEAD^' ;;
    # 分叉：`git commit --amend` 之后旧提交仍可达（reflog），与新 HEAD 分属两条历史
    ORPHAN) src=$(git rev-parse HEAD); git commit -q --amend -m "amended (history rewritten)" ;;
    OMIT)   src="" ;;
    RAW:*)  src="${PS_SRC#RAW:}" ;;
    *) echo "FAIL: mk_patchsets_fixture: 未知的 PS_SRC=[${PS_SRC}]（要写字面值请用 RAW: 前缀）" >&2; exit 1 ;;
  esac
  case "${PS_TGT:-BASE}" in
    BASE)  tgt="$base" ;;
    OMIT)  tgt="" ;;
    NONE)  tgt="" ;;
    RAW:*) tgt="${PS_TGT#RAW:}" ;;
    *) echo "FAIL: mk_patchsets_fixture: 未知的 PS_TGT=[${PS_TGT}]（要写字面值请用 RAW: 前缀）" >&2; exit 1 ;;
  esac
  # src-1（versionNo 1）是诱饵：选版本对必须按 versionNo 取最大，不能取第一条或最后一条
  jq -n --arg src "$src" --arg tgt "$tgt" --arg srcmode "${PS_SRC:-HEAD}" --arg tgtmode "${PS_TGT:-BASE}" \
        --arg srcid "${PS_SRC_ID:-src-2}" --arg tgtid "${PS_TGT_ID:-tgt-1}" '[
    (if $tgtmode == "NONE" then empty
     else ({patchSetBizId:$tgtid, versionNo:1, relatedMergeItemType:"MERGE_TARGET"}
           + (if $tgtmode == "OMIT" then {} else {commitId:$tgt} end)) end),
    {patchSetBizId:"src-1", versionNo:1, relatedMergeItemType:"MERGE_SOURCE", commitId:"0000111122223333"},
    ({patchSetBizId:$srcid, versionNo:9, relatedMergeItemType:"MERGE_SOURCE"}
     + (if $srcmode == "OMIT" then {} else {commitId:$src} end))
  ]' > "$PS_FIXTURE_DIR/list-patchsets.json"
  for n in 1 2 3 4 5 6; do
    [[ -e "$PS_FIXTURE_DIR/create-comment-inline.${n}.json" ]] \
      || jq -n --arg id "draft-${n}" '{comment_biz_id:$id, comment_type:"INLINE_COMMENT", state:"DRAFT", draft:true}' \
           > "$PS_FIXTURE_DIR/create-comment-inline.${n}.json"
  done
}
# 复位成默认值（每个用例之后调用；赋值前缀是否残留取决于 bash 版本）
reset_ps_vars() { PS_SRC="HEAD"; PS_TGT="BASE"; PS_SRC_ID="src-2"; PS_TGT_ID="tgt-1"; }
reset_ps_vars
