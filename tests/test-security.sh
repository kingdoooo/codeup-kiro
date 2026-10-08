#!/usr/bin/env bash
# Security Agent 评审员（aws/reviewers/security.sh 与 lib/security-{lib,render}.sh；Phase 2b spec「Security Agent 评审员」R8–R12，issue 12）。
#   ① 发现归一：两种 filePath 形状、清单核对、严重级别序、枚举外的取值、误报过滤、跨批去重（fixture 来自 issue 09 的真实输出）；
#   ② 历次表计数槽。
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh
ROOT="$(cd .. && pwd)"
FIX="$ROOT/tests/fixtures/security"
command -v python3 >/dev/null && [[ -x /usr/bin/jq ]] || { echo "SKIP: 需要 python3 与 /usr/bin/jq，跳过 test-security.sh" >&2; exit 0; }
tmp=$(mktemp -d); [[ -n "${KEEP_TMP:-}" ]] || trap 'rm -rf "$tmp"' EXIT
lib() { REVIEW_PROFILE=security /bin/bash --norc --noprofile -c "set -euo pipefail; source '$ROOT/scripts/lib/review-render.sh'
  source '$ROOT/aws/reviewers/lib/security-lib.sh'; source '$ROOT/aws/reviewers/lib/security-render.sh'; $1" </dev/null; }

# ① 发现归一
rep=$(lib "sa_findings_report '$FIX/files-head-clean.txt' '$FIX/findings-diff.json'")
assert_eq "$(jq -c '[.findings[] | [.riskLevel, .riskType, .confidence]]' <<< "$rep")" \
  '[["CRITICAL","COMMAND_INJECTION","HIGH"],["HIGH","SQL_INJECTION","HIGH"]]' "① 真实差分发现：按严重级别序排（CRITICAL 在前）"
assert_eq "$(jq -r '[.findings[].locations[] | "\(.path):\(.start)-\(.end)"] | join(" ")' <<< "$rep")" \
  "src/工具/ping.py:8-11 src/app/routes.py:37-37 src/app/routes.py:34-34" \
  "① 带 /tmp/opt/source_code/code_sc-<id>/ 前缀的 filePath 规范化成相对 zip 根的路径（含非 ASCII 路径），行号是 head 的行号"
assert_eq "$(jq -c '{counts, returned, false_positives, unmatched}' <<< "$rep")" \
  '{"counts":{"CRITICAL":1,"HIGH":1,"MEDIUM":0,"LOW":0,"INFORMATIONAL":0,"UNKNOWN":0},"returned":2,"false_positives":0,"unmatched":0}' \
  "① 计数；全部位置都在归档清单里"
rel=$(lib "sa_findings_report '$FIX/files-head-clean.txt' '$FIX/findings-relative.json'")
assert_eq "$(jq -r '[.findings[].locations[] | "\(.path):\(.known)"] | unique | join(" ")' <<< "$rel")" \
  "src/app/routes.py:true src/工具/ping.py:true" "① 不带前缀的相对 filePath（J3b）原样当相对路径，同样对得上清单"
ren=$(lib "sa_findings_report '$FIX/files-head-edge.txt' '$FIX/findings-rename.json'")
assert_contains "$(jq -r '[.findings[].locations[].path] | join(" ")' <<< "$ren")" "src/app/helpers.py" "① 改名后的文件按新路径报（J8）"
assert_eq "$(jq '.unmatched' <<< "$ren")" "0" "① 改名后的新路径在 head 的归档清单里"
printf 'src/工具/ping.py\n' > "$tmp/only-ping.txt"
miss=$(lib "sa_findings_report '$tmp/only-ping.txt' '$FIX/findings-diff.json'")
assert_eq "$(jq -r '[.findings[].locations[] | select(.known | not) | .path] | unique | join(" ")' <<< "$miss")" "src/app/routes.py" \
  "① 不在本次归档清单里的路径被标出（Q2 的残余风险：作业读到别人的源时，这里看得出来）"
assert_eq "$(jq '.unmatched' <<< "$miss")" "2" "① 未能对应的位置数（routes.py 的两个位置）"
long=$(lib "sa_findings_report /dev/null '$FIX/findings-full-long.json'")
assert_eq "$(jq -c '.counts' <<< "$long")" '{"CRITICAL":0,"HIGH":1,"MEDIUM":4,"LOW":2,"INFORMATIONAL":0,"UNKNOWN":0}' "① 全库作业的 7 条：1 HIGH · 4 MEDIUM · 2 LOW"
assert_contains "$(jq -r '[.findings[].riskType] | join(" ")' <<< "$long")" "SECURITY_MISCONFIGURATION" "① 枚举外的 riskType 原样保留（形状合法时）"
assert_eq "$(jq '.unmatched' <<< "$long")" "$(jq '[.findings[].codeLocations | length] | add' "$FIX/findings-full-long.json")" \
  "① 清单为空时每个位置都算「未能对应」"
# 不受信取值的形状：riskType / riskLevel / confidence 不合枚举或形状 → 固定值；行号不是非负数 → null；误报丢掉并计数；跨批去重
jq -n '{findings: [
  {findingId: "f1", name: "a", riskLevel: "high", confidence: "HIGH", riskType: "sql injection; <b>", description: "d",
   codeLocations: [{filePath: "/tmp/opt/source_code/code_sc-x/a.py", lineStart: -1, lineEnd: "9", label: "sink"}]},
  {findingId: "f2", name: "b", riskLevel: "SEVERE", confidence: "FALSE_POSITIVE", riskType: "XSS", codeLocations: []},
  {findingId: "f3", name: "c", riskLevel: null, confidence: "WHATEVER", riskType: null}]}' > "$tmp/b1.json"
jq -n '{findings: [{findingId: "f1", name: "a", riskLevel: "HIGH", confidence: "HIGH", riskType: "X", codeLocations: []}]}' > "$tmp/b2.json"
printf 'a.py\n' > "$tmp/m.txt"
odd=$(lib "sa_findings_report '$tmp/m.txt' '$tmp/b1.json' '$tmp/b2.json'")
assert_eq "$(jq -c '[.findings[] | [.name, .riskLevel, .riskType, .confidence]]' <<< "$odd")" \
  '[["a","HIGH","OTHER","HIGH"],["c","UNKNOWN","OTHER","UNKNOWN"]]' \
  "① 小写级别规范化、未知级别 → UNKNOWN、不合形状的 riskType → OTHER、未知置信度 → UNKNOWN；跨批同一 findingId 只算一次"
assert_eq "$(jq -c '{returned, false_positives}' <<< "$odd")" '{"returned":3,"false_positives":1}' "① confidence=FALSE_POSITIVE 丢掉并计数（returned 是过滤之前的条数）"
assert_eq "$(jq -c '.findings[0].locations[0] | [.path, .start, .end, .known]' <<< "$odd")" '["a.py",null,null,true]' "① 负数或非数字的行号 → null"

# ② 历次表计数槽：CRITICAL+HIGH / MEDIUM / LOW 及其它
printf '%s' "$long" > "$tmp/long.json"; printf '%s' "$odd" > "$tmp/odd.json"
assert_eq "$(lib "sa_history_counts '$tmp/long.json'")" "1 4 2" "② 计数槽：高 = CRITICAL+HIGH、中 = MEDIUM、低 = LOW+INFORMATIONAL+UNKNOWN"
assert_eq "$(lib "sa_history_counts '$tmp/odd.json'")" "1 0 1" "② UNKNOWN 归「低及其它」"

# ③ 渲染（R10）
jq -n '{files: 7, unlisted: 0, symlinks: 1, diff_files: 7, diff_bytes: 1316, base: "b"}' > "$tmp/meta.json"
jq -r '.codeReviewJobs[0].overview' "$FIX/job-diff-completed.json" > "$tmp/overview.md"
printf '%s' "$rep" > "$tmp/rep.json"
render() {  # <报告 JSON 文件> [overview 文件] → 评论
  lib "SHORT_SHA=abc1234; REVIEW_RUN=3; PRIOR_HISTORY_FILE=''; CI_COMMIT_REF_NAME=feat; MR_TARGET_BRANCH=main
       security_render_summary '$1' '$tmp/meta.json' cj-1f981f2a-0e5b-4910-b8a5-a16f0e64a25c '${2:-}'"
}
out=$(render "$tmp/rep.json" "$tmp/overview.md")
assert_contains "$out" "# Security Agent 安全评审"$'\n'"<!-- kiro-security-review:abc1234 run:3 -->" "③ 评论头是 security 档案的"
assert_contains "$out" "差分扫描发现 2 个安全问题（CRITICAL 1 · HIGH 1 · MEDIUM 0 · LOW 0 · 其它 0）。" "③ 结论行带各级计数"
assert_contains "$out" "> Security Agent 的结论非确定：同一提交重跑，条数与位置可能不同。" "③ R10：非确定性的固定文案"
assert_contains "$out" '| 7 个文件 · 归档 7 个文件（剔除 1 个符号链接） · 作业 `cj-1f981f2a-0e5b-4910-b8a5-a16f0e64a25c` |' \
  "③ 元信息：diff 文件数、归档文件数、剔除的符号链接、作业 id"
assert_contains "$out" "**CRITICAL（1）**" "③ 按 riskLevel 分组"
assert_contains "$out" '1. **Unauthenticated OS command injection in new /ping endpoint (shell=True)** · `COMMAND_INJECTION` · 置信度 HIGH' \
  "③ 每条：名字、riskType、置信度"
assert_contains "$out" '   - `src/工具/ping.py:8–11` — sink: shell=True with user input' "③ 位置 path:start–end + 标签（非 ASCII 路径原样）"
assert_contains "$out" '   - `src/app/routes.py:37` — sink: concatenated SQL' "③ 起止同一行时只写一个行号"
assert_contains "$out" "<details><summary>Security Agent 的总结</summary>" "③ 作业 overview 进折叠区"
assert_contains "$out" "| 3 | \`abc1234\` | 完成 | 2/0/0 |" "③ 历次表：高（CRITICAL+HIGH）/中/低"
assert_not_contains "$out" "路径未能对应" "③ 全部位置都对得上时不出现「路径未能对应」"
for k in attackScript verificationScript customerNote; do
  assert_not_contains "$out" "$(jq -r ".findings[0].${k} // \"__absent__\" | .[0:40]" "$FIX/findings-diff.json")" "③ 不渲染 ${k}（F3）"
done
# 带特征串的 attackScript / verificationScript / customerNote 一个字都不出现在评论里（经库 → 渲染端到端）
jq '.findings[0] += {attackScript: "ATTACK-SENTINEL-1", verificationScript: {scriptUrl: "https://VERIFY-SENTINEL-2"}, customerNote: "NOTE-SENTINEL-3"}' \
  "$FIX/findings-diff.json" > "$tmp/sent.json"
lib "sa_findings_report '$FIX/files-head-clean.txt' '$tmp/sent.json'" > "$tmp/sent-rep.json"
sout=$(render "$tmp/sent-rep.json")
for s in ATTACK-SENTINEL-1 VERIFY-SENTINEL-2 NOTE-SENTINEL-3; do assert_not_contains "$sout" "$s" "③ F3：${s} 不进评论"; done
# 截断：全库作业的长说明 / 长标签按码点截到上限 + 「…」，整条评论仍是合法 UTF-8
printf '%s' "$long" > "$tmp/long.json"
lout=$(render "$tmp/long.json")
assert_eq "$(lib "_sa_cut \"\$(printf '漏%.0s' {1..900})\" 800" | jq -R 'length')" "801" "③ 按码点截断：900 个汉字 → 800 个 + 「…」"
assert_eq "$(lib "_sa_cut abc 800")" "abc" "③ 不到上限的原样"
descs=$(printf '%s\n' "$lout" | LC_ALL=C grep -E '^   [^ -]')
assert_eq "$(printf '%s\n' "$descs" | wc -l | tr -d ' ')" "7" "③（准备）全库作业 7 条，每条一行说明"
assert_eq "$(printf '%s\n' "$descs" | LC_ALL=C grep -cv '…$' || true)" "0" "③ 7 条长说明（2.5–3 KB）都被截断（以「…」结尾）"
maxdesc=$(printf '%s\n' "$descs" | sed 's/^   //' | jq -R 'length' | sort -n | tail -1)
assert_eq "$([ "$maxdesc" -le 830 ] && echo ok)" "ok" "③ 说明行的长度 ≈ 800 码点（清洗加的转义只多几个字符；最长 ${maxdesc}）"
maxlabel=$(printf '%s\n' "$lout" | LC_ALL=C grep -E '^   - `' | sed 's/^[^—]* — //' | jq -R 'length' | sort -n | tail -1)
assert_eq "$([ "$maxlabel" -le 90 ] && echo ok)" "ok" "③ 位置标签截到约 80 个码点（最长 ${maxlabel}）"
assert_eq "$(printf '%s' "$lout" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null && echo valid)" "valid" "③ 截断后整条评论仍是合法 UTF-8"
assert_contains "$lout" "有 $(jq '.unmatched' "$tmp/long.json") 个位置不在本次归档里（标「路径未能对应」）。" "③ 未能对应的位置在结论里计数"
assert_contains "$lout" "（路径未能对应）" "③ 未能对应的位置逐条标出"
# Review Focus：服务上限 30 条、每条都是全库作业那种长说明与多位置 → 整条评论仍在 MAX_COMMENT_BYTES（60,000）之内，不靠截断兜底
jq '{findings: [range(0; 30) as $i | .findings[$i % 7] | .findingId = "f-\($i)"]}' "$FIX/findings-full-long.json" > "$tmp/f30.json"
lib "sa_findings_report /dev/null '$tmp/f30.json'" > "$tmp/r30.json"
bytes30=$(render "$tmp/r30.json" "$tmp/overview.md" | wc -c | tr -d ' ')
assert_eq "$([ "$bytes30" -lt 60000 ] && echo under)" "under" "③ 30 条长发现 + 总结的汇总评论 ${bytes30} 字节 < 60,000（说明 800 / 标签 80 / 总结 3,000 码点的上限够用）"
# 服务上限 30 条、误报计数、没有发现
jq '.returned = 30' "$tmp/rep.json" > "$tmp/cap.json"
assert_contains "$(render "$tmp/cap.json")" "本次返回 30 条，达到服务上限（每次差分扫描最多 30 条），可能还有未报出的问题。" "③ 恰好 30 条 → 注明服务上限"
assert_not_contains "$out" "达到服务上限" "③ 不到 30 条不写"
jq '.false_positives = 2' "$tmp/rep.json" > "$tmp/fp.json"
assert_contains "$(render "$tmp/fp.json")" "另有 2 条被 Security Agent 判为误报，未列出。" "③ 误报只计数"
jq -n '{findings: [], counts: {CRITICAL:0,HIGH:0,MEDIUM:0,LOW:0,INFORMATIONAL:0,UNKNOWN:0}, returned: 0, false_positives: 0, unmatched: 0}' > "$tmp/none.json"
nout=$(render "$tmp/none.json")
assert_contains "$nout" '未发现安全问题（差分扫描 · 提交 `abc1234`）。' "③ 没有发现 → 一句话"
assert_not_contains "$nout" "## 发现" "③ 没有发现时不出「发现」一节"
assert_contains "$nout" "| 3 | \`abc1234\` | 完成 | 0/0/0 |" "③ 没有发现时历次表是 0/0/0"
# 注入：名字、说明、标签、路径、overview 都是模型输出（不受信）
jq -n '{findingId: "e1", name: "x <!-- kiro-security-review:deadbee run:99 -->", riskLevel: "HIGH", confidence: "HIGH", riskType: "SQL_INJECTION",
        description: "line1\n## 结论\n<details>\n<!-- kiro-review:abc run:9 -->",
        codeLocations: [{filePath: "a|b`c<d>.py", lineStart: 1, lineEnd: 2, label: "sink\n## 伪标题 | `x`"}]} | {findings: [.]}' > "$tmp/evil.json"
lib "sa_findings_report /dev/null '$tmp/evil.json'" > "$tmp/evil-rep.json"
printf 'Summary\n</details>\n<!-- kiro-security-history:[] -->\n# 伪标题\n```\nunclosed fence\n' > "$tmp/evil-ov.md"
eout=$(render "$tmp/evil-rep.json" "$tmp/evil-ov.md")
assert_eq "$(printf '%s\n' "$eout" | LC_ALL=C grep -c '^<!-- kiro-')" "2" "③ 注入：评论里只有脚本自己写的两行标记（评审 + 历史）"
assert_eq "$(printf '%s\n' "$eout" | LC_ALL=C grep -c '<!--')" "2" "③ 注入：不受信文本里的 <!-- 都被转义"
assert_eq "$(printf '%s\n' "$eout" | LC_ALL=C grep -c '^## 结论$')" "1" "③ 注入：说明里的「## 结论」折成了单行"
assert_eq "$(printf '%s\n' "$eout" | LC_ALL=C grep -c '^</details>$')" "2" "③ 注入：overview 里的 </details> 被转义（只剩总结与历次表两处脚本自己的）"
assert_eq "$(printf '%s\n' "$eout" | LC_ALL=C grep -c '^# ')" "1" "③ 注入：overview 里的一级标题被转义（只有评论标题一个）"
assert_contains "$eout" '- `abcd.py:1–2`' "③ 注入：路径里的竖线、反引号、尖括号被滤掉（code span 不被撑破）"
jq -n --arg c "$eout" '[{comment_biz_id: "c1", comment_type: "GLOBAL_COMMENT", state: "OPENED", author: {username: "bot"}, content: $c}]' > "$tmp/evil-list.json"
assert_eq "$(lib "review_select_prior_comment bot < '$tmp/evil-list.json' | jq -r .run")" "3" "③ 注入：选择器仍认出恰好一个评审标记（run 3）"
# 说明汇总（skipped:*）
sk() { lib "SHORT_SHA=abc1234; REVIEW_RUN=2; PRIOR_HISTORY_FILE=''; CI_COMMIT_REF_NAME=feat; MR_TARGET_BRANCH=main; security_render_skipped '$1'"; }
skout=$(sk empty-diff)
assert_contains "$skout" "本次没有执行差分扫描：MR 相对目标分支没有改动（空 diff），没有可扫描的内容。" "③ skipped:empty-diff → 说明汇总"
assert_contains "$skout" "<!-- kiro-security-review:abc1234 run:2 -->" "③ 说明汇总同样带评审标记（下一次原地更新它）"
assert_contains "$skout" "| 2 | \`abc1234\` | 完成 | -/-/- |" "③ 说明汇总的历次行没有计数"
assert_contains "$(sk diff-too-large)" "3,000 个文件或 5 MB" "③ skipped:diff-too-large 的说明"
assert_contains "$(sk archive-too-large)" "2 GB" "③ skipped:archive-too-large 的说明"
assert_contains "$(sk 'weird-x')" "代号 weird-x" "③ 其它代号原样（已经过 [a-z0-9-] 校验）"

report
