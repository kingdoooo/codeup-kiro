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

# ④ 驱动端到端（aws/reviewers/security.sh）：真的 aws CLI 形状（替身按 issue 09 的实测行为）+ DRY_RUN 的 Codeup
mkdir -p "$tmp/pkg/lib" "$tmp/pkg/reviewers/lib"; ln -s "$ROOT/scripts" "$tmp/pkg/scripts"
DIGEST=$(printf 'e%.0s' {1..64})
printf '#!/bin/sh\nprintf "{\\"ImageID\\": \\"sha256:%s\\", \\"TaskARN\\": \\"arn:aws:ecs:us-west-2:123456789012:task/c/abc\\"}"\n' "$DIGEST" > "$tmp/curl"
cat > "$tmp/aws" <<STUB
#!/bin/sh
case "\$1 \$2" in
  "s3api get-object")
    printf '%s\n' "\$@" >> "$tmp/s3.argv"
    key=""; out=""; prev=""; for a in "\$@"; do [ "\$prev" = --key ] && key="\$a"; prev="\$a"; out="\$a"; done
    cp "$tmp/s3/\$(basename "\$key")" "\$out" || exit 254; echo '{}' ;;
  # 每次查作业时记下按仓库租约的租期（R12：只有核对作业源那一次持有它，轮询时已释放）
  "securityagent batch-get-code-review-jobs")
    jq -r '.["lease#7#security-repo"].lease_until.N // "none"' "$tmp/ddb.json" >> "$tmp/lease-at-poll" 2>/dev/null
    exec python3 "$ROOT/tests/fake-aws-securityagent.py" "\$@" ;;
  securityagent*) exec python3 "$ROOT/tests/fake-aws-securityagent.py" "\$@" ;;
  # \$tmp/stale-get：映射表的下一次 get-item 读到这份旧记录（一次）——模拟「读到 creating 之后、认领之前，别人已经置了 ready」（终审 I-3）
  "dynamodb get-item")
    case "\$*" in *repo_id*) if [ -e "$tmp/stale-get" ]; then cat "$tmp/stale-get"; rm -f "$tmp/stale-get"; exit 0; fi ;; esac
    exec python3 "$ROOT/tests/fake-aws-dynamodb.py" "\$@" ;;
  *) exec python3 "$ROOT/tests/fake-aws-dynamodb.py" "\$@" ;;
esac
STUB
# 假时钟（只给 security.sh 用）：每读一次前进 FAKE_DATE_STEP 秒（缺省 0 = 真时间）——超时路径不必真等 10 分钟
cat > "$tmp/fakedate" <<STUB
#!/bin/sh
[ "\${FAKE_DATE_STEP:-0}" = 0 ] && exec /bin/date "\$@"
n=\$(cat "$tmp/date.n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$tmp/date.n"
echo \$((1800000000 + n * FAKE_DATE_STEP))
STUB
chmod +x "$tmp/curl" "$tmp/aws" "$tmp/fakedate"
for f in "$ROOT"/aws/executor/lib/*.sh; do
  sed -e "s#/usr/bin/curl#$tmp/curl#g" -e "s#/usr/local/bin/aws#$tmp/aws#g" "$f" > "$tmp/pkg/lib/$(basename "$f")"
done
# 测试：不 ls-remote 真的 Codeup。第一次（L7 拿到租约之后那次）总是「没被取代」，之后有 $tmp/superseded 就算被取代——轮询中途被取代的用例要它
echo "head_check_superseded() { if [ -e '$tmp/hc.seen' ] && [ -e '$tmp/superseded' ]; then return 0; fi; touch '$tmp/hc.seen'; return 1; }" >> "$tmp/pkg/lib/lease.sh"
for f in "$ROOT"/aws/reviewers/lib/*.sh; do
  sed -e "s#/usr/bin/curl#$tmp/curl#g" "$f" > "$tmp/pkg/reviewers/lib/$(basename "$f")"
done
sed -e "s#^PKG=/opt/integration\$#PKG=$tmp/pkg#" -e "s#/usr/local/bin/aws#$tmp/aws#g" -e "s#/bin/date +%s#$tmp/fakedate +%s#g" \
  "$ROOT/aws/reviewers/security.sh" > "$tmp/security.sh"
assert_eq "$(LC_ALL=C grep -rl '/usr/local/bin/aws' "$tmp/pkg" "$tmp/security.sh" 2>/dev/null || true)" "" "④（准备）测试包里没有任何指向真 aws 的路径"
mkdir -p "$tmp/fx" "$tmp/s3"; echo '[]' > "$tmp/fx/list-comments.json"
cp "$FIX/files-head-clean.txt" "$tmp/s3/files.txt"; cp "$tmp/meta.json" "$tmp/s3/meta.json"
SPACE=as-11111111-1111-4111-8111-111111111111
SHA=$(printf 'a%.0s' {1..40}); RUNID=$(printf 'b%.0s' {1..32})
SRC="s3://bkt/security/7/$SHA/$RUNID/source.zip"; PATCH="s3://bkt/security/7/$SHA/$RUNID/changes.patch"
fresh() { rm -f "$tmp"/sa.json* "$tmp/sa.log" "$tmp/s3.argv" "$tmp/date.n" "$tmp/superseded" "$tmp/hc.seen" "$tmp/lease-at-poll" "$tmp/stale-get"; echo '{}' > "$tmp/ddb.json"; rm -f "$tmp/ddb.json.lock"; }
drive() {  # [KEY=VAL …] → rc；输出在 $tmp/out
  rm -rf "$tmp/w"; mkdir -p "$tmp/w"
  local rc=0
  ( export REVIEWER_WORKDIR="$tmp/w" DRY_RUN=1 DRY_RUN_FIXTURE_DIR="$tmp/fx" CODEUP_BOT_USERNAME=aliyun:bot YUNXIAO_ORG_ID=o1 \
           CODEUP_REPO_ID=7 MR_LOCAL_ID=7 HEAD_SHA="$SHA" CI_COMMIT_REF_NAME=feat MR_TARGET_BRANCH=main \
           LOCK_KEY=k SCAN_RUN_ID="$RUNID" SCAN_REPO_URL=https://codeup.aliyun.com/o1/r1.git \
           ECS_CONTAINER_METADATA_URI_V4=http://meta AWS_REGION=us-west-2 LOCK_TABLE=t SCAN_BUCKET=bkt SCAN_BUCKET_OWNER=123456789012 \
           FAKE_DDB_STATE="$tmp/ddb.json" FAKE_DDB_LOG="$tmp/ddb.log" FAKE_SA_STATE="$tmp/sa.json" FAKE_SA_LOG="$tmp/sa.log" \
           FAKE_SA_FINDINGS="$FIX/findings-diff.json" FAKE_SA_JOB_TEMPLATE="$FIX/job-diff-completed.json" \
           SECURITY_INPUT=ok SA_AGENT_SPACE_ID="$SPACE" SA_SERVICE_ROLE_ARN=arn:aws:iam::123456789012:role/sa-role \
           SA_MAPPING_TABLE=map SECURITY_AGENT_TIMEOUT=600 SA_POLL_INTERVAL=0 SA_START_RETRY_EVERY=0 SA_LOCK_WAIT=30 "$@"
    /bin/bash --norc --noprofile "$tmp/security.sh" ) > "$tmp/out" 2>&1 </dev/null || rc=$?
  echo "$rc"
}
ops() { awk '{print $1}' "$tmp/sa.log" | tr '\n' ' '; }
req_of() { awk -v op="$1" '$1 == op {sub(/^[^ ]+ /, ""); sub(/ (ok|ERR [A-Za-z]+) attempts=.*$/, ""); print}' "$tmp/sa.log" | sed -n "${2:-1}p"; }
attempts_of() { awk -v op="$1" '$1 == op {print $NF}' "$tmp/sa.log" | sort -u | tr '\n' ' '; }
mapping() { jq -c '.["repo_id=7"] // {} | {status: .status.S, cr: .code_review_id.S, space: .agent_space_id.S}' "$tmp/ddb.json"; }

fresh
assert_eq "$(drive)" "0" "④ 正常 → 0（已回写）"
out=$(cat "$tmp/out"); body=$(posted_comment "$out")
assert_eq "$(req_count "$out" POST 'comments$')" "1" "④ 新建一条汇总"
assert_contains "$body" "差分扫描发现 2 个安全问题" "④ 汇总里是作业的发现"
assert_contains "$body" '`src/工具/ping.py:8–11`' "④ 位置已规范化"
assert_eq "$(ops)" "list-code-reviews create-code-review update-code-review start-code-review-job batch-get-code-review-jobs batch-get-code-review-jobs list-findings batch-get-findings " \
  "④ 调用顺序：收编（无）→ 建 → 重指向 → Start → 核对作业的源 → 轮询 → 取发现"
creq=$(req_of create-code-review)
assert_eq "$(jq -c '[.title, .codeRemediationStrategy, .validationMode, .assets.sourceCode[0].s3Location, .serviceRole]' <<< "$creq")" \
  "[\"codeup-kiro:7\",\"DISABLED\",\"DISABLED\",\"$SRC\",\"arn:aws:iam::123456789012:role/sa-role\"]" "④ Q1 / I2：建 code review 的请求（标题、两个 DISABLED、本次源、服务角色）"
assert_eq "$(jq -c '[.assets.sourceCode[0].s3Location, .serviceRole]' <<< "$(req_of update-code-review)")" \
  "[\"$SRC\",\"arn:aws:iam::123456789012:role/sa-role\"]" "④ 重指向带本次的源与服务角色（实测：带 sourceCode 时必须带 serviceRole）"
assert_eq "$(jq -c '.diffSource' <<< "$(req_of start-code-review-job)")" "{\"s3Uri\":\"$PATCH\"}" "④ D1：Start 带 diffSource，指向本次的 .patch"
assert_eq "$(attempts_of create-code-review)$(attempts_of start-code-review-job)" "attempts=1 attempts=1 " "④ Q3：两个非幂等操作 AWS_MAX_ATTEMPTS=1（CLI 不自动重试）"
assert_eq "$(attempts_of list-findings)" "attempts=4 " "④ 只读调用照常让 CLI 重试"
assert_eq "$(mapping)" "{\"status\":\"ready\",\"cr\":\"cr-00000001-0000-4000-8000-000000000000\",\"space\":\"$SPACE\"}" "④ Q1：映射表登记了本仓库的 code review"
assert_eq "$(awk '{ print ($1 ~ /^[1-9][0-9]*$/ ? "held" : $1 == "0" ? "free" : $1) }' "$tmp/lease-at-poll" | tr '\n' ' ')" "held free " \
  "④ R12：核对作业源时持有按仓库租约，轮询时已释放（轮询期间不持有）"
assert_eq "$(jq -r '.["lease#7#security-repo"].lease_until.N' "$tmp/ddb.json")" "0" "④ R12：按仓库租约用完即释放"
assert_eq "$(jq -r '.["lease#7#security-repo"] | has("holder")' "$tmp/ddb.json")" "false" "④ 释放时抹掉持有者（L6）"
assert_eq "$(awk 'p{print; p=0} $0=="--key"{p=1}' "$tmp/s3.argv" | tr '\n' ' ')" "security/7/$SHA/$RUNID/meta.json security/7/$SHA/$RUNID/files.txt " \
  "④ 读的是执行器写的计数与清单（不下载 source.zip）"
assert_eq "$(grep -c -- '--expected-bucket-owner' "$tmp/s3.argv")" "2" "④ 每次读都带 ExpectedBucketOwner"
# 第二次评审：映射表已有 → 不列、不建，只重指向 + Start
rm -f "$tmp/sa.log"
assert_eq "$(drive)" "0" "④ 第二次评审 → 0"
assert_eq "$(ops)" "update-code-review start-code-review-job batch-get-code-review-jobs batch-get-code-review-jobs list-findings batch-get-findings " \
  "④ Q1：映射表命中 → 复用 code review，不再列、不再建"
# Q1：映射表空、但服务里已有同标题的 code review（上一次建了却没登记上）→ 收编，不建第二个
fresh
python3 - "$tmp/sa.json" "$SPACE" <<'PY'
import json, sys
json.dump({"n": 5, "codeReviews": {"cr-0000000a-0000-4000-8000-000000000000": {
  "codeReviewId": "cr-0000000a-0000-4000-8000-000000000000", "title": "codeup-kiro:7", "assets": {"sourceCode": [{"s3Location": "s3://bkt/old.zip"}]},
  "serviceRole": "r", "agentSpaceId": sys.argv[2], "createdAt": "2026-10-01T00:00:00.000000+00:00"}}}, open(sys.argv[1], "w"))
PY
assert_eq "$(drive)" "0" "④ 收编 → 0"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^create-code-review$')" "0" "④ Q1：按标题收编已有的 code review，不建第二个"
assert_eq "$(mapping | jq -r .cr)" "cr-0000000a-0000-4000-8000-000000000000" "④ Q1：映射表登记的是收编的那个"
# Q1：两个子进程同时为同一仓库首次评审（不同 MR）→ 只建一个 code review，两边用同一个
fresh
( drive MR_LOCAL_ID=7 LOCK_KEY=k7 > "$tmp/rc.a"; cp "$tmp/out" "$tmp/out.a" ) & pa=$!
sleep 0.2
( REVIEWER_WORKDIR_SUFFIX=b; rm -rf "$tmp/w2"; mkdir -p "$tmp/w2"
  ( export REVIEWER_WORKDIR="$tmp/w2" DRY_RUN=1 DRY_RUN_FIXTURE_DIR="$tmp/fx" CODEUP_BOT_USERNAME=aliyun:bot YUNXIAO_ORG_ID=o1 \
           CODEUP_REPO_ID=7 MR_LOCAL_ID=8 HEAD_SHA="$SHA" CI_COMMIT_REF_NAME=feat2 MR_TARGET_BRANCH=main \
           LOCK_KEY=k8 SCAN_RUN_ID="$RUNID" SCAN_REPO_URL=https://codeup.aliyun.com/o1/r1.git \
           ECS_CONTAINER_METADATA_URI_V4=http://meta AWS_REGION=us-west-2 LOCK_TABLE=t SCAN_BUCKET=bkt SCAN_BUCKET_OWNER=123456789012 \
           FAKE_DDB_STATE="$tmp/ddb.json" FAKE_DDB_LOG="$tmp/ddb.log" FAKE_SA_STATE="$tmp/sa.json" FAKE_SA_LOG="$tmp/sa.log" \
           FAKE_SA_FINDINGS="$FIX/findings-diff.json" FAKE_SA_JOB_TEMPLATE="$FIX/job-diff-completed.json" \
           SECURITY_INPUT=ok SA_AGENT_SPACE_ID="$SPACE" SA_SERVICE_ROLE_ARN=arn:aws:iam::123456789012:role/sa-role \
           SA_MAPPING_TABLE=map SECURITY_AGENT_TIMEOUT=600 SA_POLL_INTERVAL=0 SA_START_RETRY_EVERY=0 SA_LOCK_WAIT=30
    /bin/bash --norc --noprofile "$tmp/security.sh" ) > "$tmp/out.b" 2>&1 </dev/null; echo $? > "$tmp/rc.b" ) & pb=$!
wait "$pa" "$pb"
assert_eq "$(cat "$tmp/rc.a")/$(cat "$tmp/rc.b")" "0/0" "④ Q1 并发：两个子进程都回写了"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^create-code-review$')" "1" "④ Q1 并发：只调了一次 CreateCodeReview"
assert_eq "$(jq '.codeReviews | length' "$tmp/sa.json")" "1" "④ Q1 并发：服务里只有一个 code review"
assert_eq "$(jq -r '[.jobs[].codeReviewId] | unique | length' "$tmp/sa.json")" "1" "④ Q1 并发：两个作业落在同一个 code review 上"
# 终审 I-3：读到别人「正在建」之后、认领之前，那边已经置了 ready → 认领不能覆盖这条 ready（否则要再收编一次，ListCodeReviews 若还没
# 列出它就会建第二个）。认领失败 → 再读一次 → 用表里 ready 的那个
fresh
python3 - "$tmp/sa.json" "$tmp/ddb.json" "$SPACE" <<'PY'
import json, sys
cr = "cr-0000000b-0000-4000-8000-000000000000"
json.dump({"n": 5, "codeReviews": {cr: {"codeReviewId": cr, "title": "codeup-kiro:7", "assets": {"sourceCode": [{"s3Location": "s3://bkt/old.zip"}]},
  "serviceRole": "r", "agentSpaceId": sys.argv[3], "createdAt": "2026-10-01T00:00:00.000000+00:00"}}}, open(sys.argv[1], "w"))
json.dump({"repo_id=7": {"repo_id": {"S": "7"}, "status": {"S": "ready"}, "code_review_id": {"S": cr},
  "agent_space_id": {"S": sys.argv[3]}, "holder": {"S": "other"}, "until": {"N": "1"}}}, open(sys.argv[2], "w"))
PY
printf '{"Item": {"repo_id": {"S": "7"}, "status": {"S": "creating"}, "holder": {"S": "other"}, "until": {"N": "9999999999"}}}' > "$tmp/stale-get"
assert_eq "$(drive)" "0" "④ I-3 读到旧的 creating → 0"
assert_eq "$(ops | cut -d' ' -f1-2)" "update-code-review start-code-review-job" "④ I-3 认领没有覆盖已 ready 的映射：不再列、不再建，直接用表里那个"
assert_eq "$(mapping | jq -r .cr)" "cr-0000000b-0000-4000-8000-000000000000" "④ I-3 映射表仍是原来那个 code review"
# R9：并发满（明确拒绝、不建作业）→ 放开仓库租约、退避重试
fresh
assert_eq "$(drive FAKE_SA_START_THROTTLE=2)" "0" "④ R9：前两次 Start 被限流 → 重试后成功"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^start-code-review-job$')" "3" "④ R9：Start 共 3 次"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^update-code-review$')" "3" "④ R12：每次重试都在仓库租约下重新重指向（租约在两次之间放开过）"
assert_eq "$(jq '.jobs | length' "$tmp/sa.json")" "1" "④ R9：被拒的 Start 不建作业，最终只有一个作业"
fresh
assert_eq "$(drive FAKE_SA_START_THROTTLE=99 SA_START_RETRY_MAX=0)" "0" "④ R9：排队超过上限 → 失败评论（终态 0）"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "Security Agent 并发已满，排队超过上限仍未启动（代号 sa-concurrency-full）" "④ R9：失败评论带 sa-concurrency-full"
assert_eq "$(jq -r '.["lease#7#security-repo"].lease_until.N' "$tmp/ddb.json")" "0" "④ R9：放弃时仓库租约已释放"
# 终审 I-5：并发满排队期间同一 MR 有了新提交 → 不再为旧提交起作业（它还会占一个本就紧缺的名额）、安静退出（10）
fresh; touch "$tmp/superseded"
assert_eq "$(drive FAKE_SA_START_THROTTLE=99 SA_START_RETRY_MAX=3)" "10" "④ I-5 排队时被取代 → 10（安静）"
rm -f "$tmp/superseded"
assert_eq "$(jq '.jobs // {} | length' "$tmp/sa.json")" "0" "④ I-5 被取代的那次一个作业都没起"
assert_eq "$(req_count "$(cat "$tmp/out")" POST 'comments$')" "0" "④ I-5 被取代时不发评论"
assert_eq "$(jq -r '.["lease#7#security-repo"].lease_until.N' "$tmp/ddb.json")" "0" "④ I-5 退出时仓库租约已释放"
# Q3：Start 建了作业、应答却是 5xx → 收编，不再 Start 第二次
fresh
assert_eq "$(drive FAKE_SA_START_AMBIGUOUS=1)" "0" "④ Q3：含糊失败 → 收编本次的作业 → 0"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^start-code-review-job$')" "1" "④ Q3：只 Start 了一次（没有因为重试起出第二个作业）"
assert_eq "$(jq '.jobs | length' "$tmp/sa.json")" "1" "④ Q3：服务里只有一个作业"
assert_contains "$(cat "$tmp/out")" "收编了本次的作业" "④ Q3：日志写明收编"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "差分扫描发现 2 个安全问题" "④ Q3：收编的作业照常出汇总"
# Q2：作业记下的源不是本次的 → Stop + 失败评论
fresh
assert_eq "$(drive FAKE_SA_JOB_SOURCE_OVERRIDE=s3://bkt/security/7/other/source.zip)" "0" "④ Q2：源不符 → 失败评论（终态 0）"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "Security Agent 作业记下的源与本次不符，已停止（代号 sa-source-mismatch）" "④ Q2：失败评论带 sa-source-mismatch"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^stop-code-review-job$')" "1" "④ Q2：作业被停止"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^list-findings$')" "0" "④ Q2：不取（别人的）发现"
# 作业 FAILED / 被别人停止：失败评论只带枚举代号，不回显 errorInformation.message（F3）
fresh
assert_eq "$(drive FAKE_SA_JOB_STATUSES=IN_PROGRESS,IN_PROGRESS,FAILED FAKE_SA_JOB_ERROR=CLIENT_ERROR)" "0" "④ 作业 FAILED → 失败评论"
fb=$(posted_comment "$(cat "$tmp/out")")
assert_contains "$fb" "Security Agent 作业失败（代号 CLIENT_ERROR）" "④ FAILED：失败评论带 errorInformation.code"
assert_not_contains "$fb" "secret-bucket" "④ F3：不回显服务端的错误正文"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^stop-code-review-job$')" "0" "④ FAILED 的作业不再 Stop"
fresh
assert_eq "$(drive FAKE_SA_JOB_STATUSES=IN_PROGRESS,STOPPED)" "0" "④ 作业被别人停止 → 失败评论"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "Security Agent 作业被停止（代号 STOPPED_BY_USER）" "④ 被停止：代号 STOPPED_BY_USER"
# 终态只看 status：COMPLETED 而 FINALIZING 仍是 NOT_STARTED（替身就这么给）→ 照常取发现
assert_contains "$(posted_comment "$(cat "$tmp/out")" | head -1)$(jq -r '.jobs | to_entries[0].value.status' "$tmp/sa.json")" "STOPPED" "④（正向对照）上一条确实停在了 STOPPED"
# R8：超时 → Stop + 失败评论（假时钟每读一次走 200 秒）
fresh
assert_eq "$(drive FAKE_SA_JOB_STATUSES=IN_PROGRESS FAKE_DATE_STEP=200)" "0" "④ R8：超时 → 失败评论（终态 0）"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "Security Agent 作业超过 600 秒仍未结束，已停止（代号 sa-timeout）" "④ R8：失败评论带 sa-timeout"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^stop-code-review-job$')" "1" "④ R8：超时的作业被停止（不白占并发名额）"
# 轮询期间源分支有了新提交 → 停掉作业、安静退出（10），交给新的那次
fresh; touch "$tmp/superseded"
assert_eq "$(drive FAKE_SA_JOB_STATUSES=IN_PROGRESS SA_SUPERSEDE_EVERY=2)" "10" "④ 轮询中被取代 → 10（安静）"
rm -f "$tmp/superseded"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^stop-code-review-job$')" "1" "④ 被取代时作业被停止"
assert_eq "$(req_count "$(cat "$tmp/out")" POST 'comments$')" "0" "④ 被取代时不发评论"
# code review 在别处被删了（映射表还指着它）→ 标成过期、重新建一个、照常评审
fresh
printf '{"repo_id=7": {"repo_id": {"S": "7"}, "status": {"S": "ready"}, "code_review_id": {"S": "cr-dead0000-0000-4000-8000-000000000000"}, "agent_space_id": {"S": "%s"}}}' "$SPACE" > "$tmp/ddb.json"
assert_eq "$(drive)" "0" "④ 映射指向已删的 code review → 重建后 0"
assert_eq "$(ops)" "update-code-review list-code-reviews create-code-review update-code-review start-code-review-job batch-get-code-review-jobs batch-get-code-review-jobs list-findings batch-get-findings " \
  "④ 重指向报 ResourceNotFound → 重新取/建 → 再重指向"
assert_eq "$(mapping | jq -r .status)" "ready" "④ 映射表重新登记为 ready"
# Agent Space 换过（栈重建）：映射里的 space 不是本部署的 → 当作没有，重新取/建
fresh
printf '{"repo_id=7": {"repo_id": {"S": "7"}, "status": {"S": "ready"}, "code_review_id": {"S": "cr-0dd00000-0000-4000-8000-000000000000"}, "agent_space_id": {"S": "as-99999999-9999-4999-8999-999999999999"}}}' > "$tmp/ddb.json"
assert_eq "$(drive)" "0" "④ Agent Space 换过 → 0"
assert_eq "$(mapping | jq -r .space)" "$SPACE" "④ 映射表改登记为本部署的 Agent Space"
assert_eq "$(ops | cut -d' ' -f1-2)" "list-code-reviews create-code-review" \
  "④ 旧 Space 的 code review 一次都不碰（直接收编或新建，不先拿旧 id 去重指向再靠 ResourceNotFound 兜回来）"
# 发现很多：BatchGetFindings 分批（每批 50）
jq '{findings: [range(0; 60) as $i | .findings[0] | .findingId = "f-\($i)"]}' "$FIX/findings-diff.json" > "$tmp/f60.json"
fresh
assert_eq "$(drive FAKE_SA_FINDINGS="$tmp/f60.json")" "0" "④ 60 条发现 → 0"
assert_eq "$(ops | tr ' ' '\n' | grep -c '^batch-get-findings$')" "2" "④ BatchGetFindings 分两批（50 + 10）"
assert_eq "$(jq -c '.findingIds | length' <<< "$(req_of batch-get-findings 2)")" "10" "④ 第二批 10 个"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "本次返回 60 条，达到服务上限" "④ 返回 ≥ 30 条时注明服务上限"
# 输入状态：skipped → 说明汇总、不调 SA；failed → 失败评论、不调 SA；部署配置不对 → 失败评论
fresh
assert_eq "$(drive SECURITY_INPUT=skipped:empty-diff)" "0" "④ skipped:empty-diff → 说明汇总"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "本次没有执行差分扫描：MR 相对目标分支没有改动" "④ 说明汇总"
assert_eq "$([ -e "$tmp/sa.log" ] && echo yes || echo no)" "no" "④ skipped 时一次 SA 调用都没有（不起作业）"
assert_eq "$(drive SECURITY_INPUT=failed:zip-timeout)" "0" "④ failed:* → 失败评论"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "执行器没能准备 Security Agent 的扫描输入（代号 zip-timeout）" "④ 失败评论带输入状态的代号"
assert_eq "$([ -e "$tmp/sa.log" ] && echo yes || echo no)" "no" "④ failed 时一次 SA 调用都没有"
assert_eq "$(drive SECURITY_INPUT='ok; x')" "0" "④ 输入状态不合法 → 失败评论"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "Security Agent 的扫描输入状态不合法" "④ 不合法的状态不回显"
for bad in SA_AGENT_SPACE_ID=bad SA_SERVICE_ROLE_ARN=x SECURITY_AGENT_TIMEOUT=599 SECURITY_AGENT_TIMEOUT=7201 SA_MAPPING_TABLE=; do
  assert_eq "$(drive "$bad")" "0" "④ ${bad} → 失败评论"
  assert_contains "$(posted_comment "$(cat "$tmp/out")")" "（代号 sa-config）" "④ ${bad} → sa-config"
done
assert_eq "$([ -e "$tmp/sa.log" ] && echo yes || echo no)" "no" "④ 配置不对时一次 SA 调用都没有"
# 终审 I-1：SECURITY_AGENT_TIMEOUT 不能在形状核对之前进 $(( ))（REVIEWER_LEASE_WAIT 的缺省值）——bash 算术会执行 `NAME[$(cmd)]` 里的 cmd
rm -f "$tmp/pwned.sat"
assert_eq "$(drive "SECURITY_AGENT_TIMEOUT=SA_POLL_INTERVAL[\$(touch $tmp/pwned.sat)]")" "0" "④ I-1 SECURITY_AGENT_TIMEOUT 带命令 → 失败评论"
assert_eq "$([ -e "$tmp/pwned.sat" ] && echo ran || echo no)" "no" "④ I-1 SECURITY_AGENT_TIMEOUT 里的命令没有被执行"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "（代号 sa-config）" "④ I-1 → sa-config"

# ⑤ 静态守卫（D1 / I2）：只做差分、只读
code=$(LC_ALL=C grep -rvhE '^[[:space:]]*#' "$ROOT/aws/reviewers" "$ROOT/aws/executor")
assert_eq "$(printf '%s\n' "$code" | LC_ALL=C grep -c 'start-code-review-job')" "1" "⑤ D1：仓库里只有一处 StartCodeReviewJob 调用"
assert_contains "$(printf "%s\n" "$code" | LC_ALL=C grep -A1 "start-code-review-job")" "diffSource: {s3Uri: \$p}" "⑤ D1：那一处的请求（同一条语句的下一行）带 diffSource"
assert_eq "$(printf '%s\n' "$code" | LC_ALL=C grep -oE '(codeRemediationStrategy|validationMode): "[A-Z]+"' | sort -u | tr '\n' ' ')" \
  'codeRemediationStrategy: "DISABLED" validationMode: "DISABLED" ' "⑤ I2：两个开关只出现 DISABLED"
assert_eq "$(printf '%s\n' "$code" | LC_ALL=C grep -ciE 'start-code-remediation|update-finding|batch-delete-code-reviews|StartCodeRemediation|UpdateFinding' || true)" "0" \
  "⑤ I2：不调用代码修复、改发现、删 code review"

report
