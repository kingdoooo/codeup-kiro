#!/usr/bin/env bash
# 评审员档案（Phase 2b spec「评审员档案」「M1」）：
#   ① Kiro 档案的每个派生值与 2a（93ac53e）的字面量逐字节相同——Kiro 的标记一变，MR 上已有的汇总就再也找不回来；
#   ② 档案取值严格枚举，未知值让 source 失败（fail closed）；空串与未设同义（= kiro）；
#   ③ M1：任意两份档案互喂对方渲染出的整条失败评论，选择器、历史解析、发布探针都不认；同档案互喂是正向对照（必须认）；
#   ④ 所有标记以 `<!-- kiro-` 开头（调度器断环 N5 只认这个前缀）；
#   ⑤ 渲染随档案走：标题、标记、历次表计数列、元信息第四列、页脚图例。
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh
LIB="$(cd .. && pwd)/scripts/lib"
PROFILES="kiro inspector security"

# 在一个新的 bash 里按档案 source 渲染库与 Codeup 库，再执行 $2。每次都是新进程：档案是加载期常量，同一进程里换档案不算数。
in_profile() {  # <档案> <bash 代码>
  REVIEW_PROFILE="$1" /bin/bash --norc --noprofile -c "set -euo pipefail; source '$LIB/review-render.sh'; source '$LIB/codeup-api.sh'; $2" </dev/null
}

# ① Kiro 档案 = 2a 字面量（逐字节）。期望值照抄 93ac53e 的 scripts/lib/review-render.sh，不从档案派生——派生出来的期望值证明不了任何事。
want_marker_re='^<!-- kiro-review:[0-9a-zA-Z._-]+ run:([0-9]{1,9}) -->[[:space:]]*$'
want_nonce_re='^<!-- kiro-review-post:([0-9a-f]{16}) -->[[:space:]]*$'
for p in "" kiro; do
  got=$(REVIEW_PROFILE="$p" /bin/bash --norc --noprofile -c "source '$LIB/review-render.sh'; printf '%s\n' \"\$REVIEW_TITLE\" \"\$REVIEW_MARKER_LINE_RE\" \"\$REVIEW_HISTORY_PREFIX\" \"\$REVIEW_POST_NONCE_PREFIX\" \"\$REVIEW_POST_NONCE_LINE_RE\" \"\$REVIEW_TITLE_FAILED\"" </dev/null)
  assert_eq "$got" "# Kiro 代码评审
${want_marker_re}
<!-- kiro-history:
<!-- kiro-review-post:
${want_nonce_re}
# Kiro 代码评审 · ⚠️ 评审未完成" "① Kiro 档案（REVIEW_PROFILE='${p}'）的标题与三个标记与 2a 字面量逐字节相同"
done
# 页脚与历次表表头在 Kiro 档案下不变（golden 也守着，这里给一条不依赖 golden 的直接断言）
foot=$(in_profile kiro 'review_render_footer 3')
assert_eq "$foot" "---
第 3 次评审 · P0 必须修复 · P1 应当修复 · P2 可选改进 · 重跑流水线可重新评审" "① Kiro 页脚逐字节不变"

# ② 未知档案：source 失败、报出档案名；不得静默按 kiro 渲染
rc=0; err=$(REVIEW_PROFILE=inspectr /bin/bash --norc --noprofile -c "source '$LIB/review-render.sh' && echo LOADED" 2>&1 </dev/null) || rc=$?
assert_not_contains "$err" "LOADED" "② 未知档案时 source 失败"
assert_contains "$err" "REVIEW_PROFILE=inspectr" "② 报错里点名未知档案"
# kiro-review.sh 自己写死档案（环境里的同名变量不能决定 Kiro 用哪套标记）
assert_eq "$(LC_ALL=C grep -cE '^REVIEW_PROFILE=kiro$' ../scripts/kiro-review.sh)" "1" "② kiro-review.sh 在 source 渲染库前写死 REVIEW_PROFILE=kiro"
src_line=$(LC_ALL=C grep -n 'source "${SCRIPT_DIR}/lib/review-render.sh"' ../scripts/kiro-review.sh | cut -d: -f1)
set_line=$(LC_ALL=C grep -nE '^REVIEW_PROFILE=kiro$' ../scripts/kiro-review.sh | cut -d: -f1)
assert_eq "$([ -n "$src_line" ] && [ -n "$set_line" ] && [ "$set_line" -lt "$src_line" ] && echo yes)" "yes" \
  "② 写死档案那一行在 source 渲染库之前"

# ③ M1：每份档案渲染一条失败评论（成功评论是各评审员自己的渲染器，但评论头/历史/页脚都出自这同一份代码）
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for p in $PROFILES; do
  in_profile "$p" "REVIEW_POST_NONCE=0123456789abcdef review_render_failure --reason 'x' --sha abc1234 --src feat --dst main --ts '2026-10-04 12:00:00' --diff-note n --run 4" > "$tmp/$p.md"
  assert_contains "$(cat "$tmp/$p.md")" "run:4 -->" "③ 渲染出了 ${p} 的失败评论"
  # 把这条评论包成 ListMergeRequestComments 的响应形状（作者 = 机器人）
  jq -n --rawfile c "$tmp/$p.md" '[{comment_biz_id: "c1", comment_type: "GLOBAL_COMMENT", state: "OPENED", author: {username: "bot"}, content: $c}]' > "$tmp/$p.json"
done
for p in $PROFILES; do
  for q in $PROFILES; do
    sel_rc=0; in_profile "$q" "review_select_prior_comment bot < '$tmp/$p.json' >/dev/null 2>&1" || sel_rc=$?
    hist=$(in_profile "$q" "review_parse_history '$tmp/$p.md' 2>/dev/null | jq -r length")
    in_profile "$q" "_codeup_post_probe_marker '$tmp/$p.md'; printf '%s %s\n' \"\$_CODEUP_POST_PROBE_SHA\" \"\$_CODEUP_POST_PROBE_RUN\"" > "$tmp/probe.out" 2>/dev/null
    probe=$(cat "$tmp/probe.out")
    if [[ "$p" == "$q" ]]; then
      assert_eq "$sel_rc" "0" "③ 正向对照：${q} 认得自己的汇总"
      assert_eq "$hist" "1" "③ 正向对照：${q} 读得回自己的一行历史"
      assert_eq "$probe" "abc1234 4" "③ 正向对照：${q} 的发布探针读得出自己的 sha 与 run"
    else
      assert_eq "$sel_rc" "1" "③ M1：${q} 的选择器不认 ${p} 的汇总"
      assert_eq "$hist" "0" "③ M1：${q} 的历史解析不认 ${p} 的历史"
      assert_eq "$probe" " " "③ M1：${q} 的发布探针不认 ${p} 的评审标记"
    fi
  done
done
# 掩码保行守卫：各档案的「脚本标记行」正则同样两两不相交（只匹配自己的评论头）
for p in $PROFILES; do
  for q in $PROFILES; do
    n=$(in_profile "$q" "LC_ALL=C grep -cE \"\$(_review_marker_line_re)\" '$tmp/$p.md' || true")
    if [[ "$p" == "$q" ]]; then
      assert_eq "$n" "3" "③ 正向对照：${q} 的标记行正则命中自己的三行评论头（评审标记 / 历史 / 发布随机串）"
    else
      assert_eq "$n" "0" "③ M1：${q} 的标记行正则不命中 ${p} 的任何一行"
    fi
  done
done

# ④ 所有标记都在 `<!-- kiro-` 族里
for p in $PROFILES; do
  heads=$(head -4 "$tmp/$p.md" | tail -3)
  while IFS= read -r line; do
    assert_eq "${line:0:10}" "<!-- kiro-" "④ ${p} 的评论头标记行以 <!-- kiro- 开头：${line:0:40}"
  done <<< "$heads"
done

# ⑤ 渲染随档案走
assert_contains "$(cat "$tmp/inspector.md")" "# Inspector 依赖漏洞扫描 · ⚠️ 评审未完成" "⑤ Inspector 标题"
assert_contains "$(cat "$tmp/inspector.md")" "| Commit | 分支 | 时间 | 组件 |" "⑤ Inspector 元信息第四列"
assert_contains "$(cat "$tmp/inspector.md")" "| 次 | 提交 | 结论 | 引入 高/中/低 |" "⑤ Inspector 历次表计数列"
assert_contains "$(cat "$tmp/inspector.md")" "第 4 次评审 · 计数为本 MR 引入的依赖漏洞" "⑤ Inspector 页脚图例"
assert_contains "$(cat "$tmp/security.md")" "# Continuum 代码安全扫描 · ⚠️ 评审未完成" "⑤ Security Agent 标题（Phase 2c spec F8：与飞书通知的文案一致）"
assert_not_contains "$(cat "$tmp/security.md")" "Security Agent 安全评审" "⑤ 旧标题不再出现"
# F8：只改标题——命令、标记、评审员 id 不变，所以 MR 上旧标题的那条 SA 汇总照样被认出来、原地更新（run 递增，不新建第二条）
sed '1s/.*/# Security Agent 安全评审 · ⚠️ 评审未完成/' "$tmp/security.md" > "$tmp/security-old.md"
assert_eq "$(head -1 "$tmp/security-old.md")" "# Security Agent 安全评审 · ⚠️ 评审未完成" "⑤（准备）一条旧标题的 SA 汇总"
jq -n --rawfile c "$tmp/security-old.md" '[{comment_biz_id: "c-old", comment_type: "GLOBAL_COMMENT", state: "OPENED", author: {username: "bot"}, content: $c}]' > "$tmp/security-old.json"
assert_eq "$(in_profile security "review_select_prior_comment bot < '$tmp/security-old.json' | jq -r '\"\(.comment_biz_id) \(.run)\"'")" "c-old 4" \
  "⑤ F8：旧标题的 SA 汇总照样被选中（原地更新那一条，run 接着数）"
assert_contains "$(cat "$tmp/kiro.md")" "| Commit | 分支 | 时间 | diff |" "⑤ Kiro 元信息第四列不变"
# 「完成」标签只给扫描员档案：一行 status=ok 的历史在 Inspector 表里显示「完成」，在 Kiro 表里仍按契约结论中文化
printf '[{"run":1,"sha":"abc1234","verdict":"","status":"","p0":1,"p1":0,"p2":2}]\n' > "$tmp/h.json"
assert_contains "$(in_profile inspector "review_render_history_table '$tmp/h.json'")" '| 1 | `abc1234` | 完成 | 1/0/2 |' "⑤ Inspector 历次表的正常行显示「完成」"
assert_contains "$(in_profile kiro "review_render_history_table '$tmp/h.json'")" '| 1 | `abc1234` | 评审员未给出契约内的结论 | 1/0/2 |' "⑤ Kiro 历次表的正常行仍按契约结论中文化"

echo "test-reviewer-profile: ${TESTS_PASSED} 条断言通过"
