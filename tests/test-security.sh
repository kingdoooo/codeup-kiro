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
  source '$ROOT/aws/reviewers/lib/security-lib.sh'; $1" </dev/null; }

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

report
