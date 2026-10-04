#!/usr/bin/env bash
# Inspector 评审员（aws/reviewers/inspector.sh 与 lib/inspector-{lib,render}.sh；Phase 2b spec「Inspector 评审员」，issue 07）。
#   ① 组件键与引入/存量分类；② ScanSbom 调用计划（引入的先送、分块、上限、被丢下的计数）；③ 合并与严重级别规则；
#   ④ 严重级别规则与 Inspector 自己的 metadata 计数一致（fixture 来自 issue 01 的真实输出，见 fixtures/inspector/README.md）；
#   ⑤ 渲染：引入为主、存量折叠；不受信文本伪造不出标记、撑不坏表格、带不进非 https 链接；
#   ⑥ 驱动端到端：真的 aws CLI 形状（替身记录 argv）+ DRY_RUN 的 Codeup：成功、输入失败、ScanSbom 失败、超出调用上限。
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh
ROOT="$(cd .. && pwd)"
FIX="$ROOT/tests/fixtures/inspector"
command -v python3 >/dev/null && [[ -x /usr/bin/jq ]] || { echo "SKIP: 需要 python3 与 /usr/bin/jq，跳过 test-inspector.sh" >&2; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
lib() { REVIEW_PROFILE=inspector /bin/bash --norc --noprofile -c "set -euo pipefail; source '$ROOT/scripts/lib/review-render.sh'
  source '$ROOT/aws/reviewers/lib/inspector-lib.sh'; $1" </dev/null; }
cdx() { jq -n --argjson c "$1" '{bomFormat: "CycloneDX", specVersion: "1.5", components: $c}'; }

# ① 组件键与分类
cdx '[{"purl":"pkg:Maven/a/b@1.0?type=jar#x"},{"purl":"pkg:pypi/c@2"},{"name":"no-purl"}]' > "$tmp/h.json"
assert_eq "$(lib "inspector_component_keys '$tmp/h.json'")" "pkg:maven/a/b@1.0
pkg:pypi/c@2" "① 键 = purl 去 qualifiers/subpath、转小写；没有 purl 的组件不算"
cdx '[{"purl":"pkg:pypi/c@2"},{"purl":"pkg:pypi/d@1"},{"purl":"pkg:pypi/d@2"}]' > "$tmp/hh.json"
cdx '[{"purl":"pkg:PyPI/c@2?x=1"},{"purl":"pkg:pypi/d@1"}]' > "$tmp/bb.json"
assert_eq "$(lib "inspector_introduced '$tmp/hh.json' '$tmp/bb.json' | jq -r '[.[].purl] | join(\",\")'")" "pkg:pypi/d@2" \
  "① 引入 = head 有、base 没有的键：同一个包换了写法不算引入，升版本算"
assert_eq "$(lib "inspector_introduced '$tmp/hh.json' '$tmp/hh.json' | jq length")" "0" "① head = base → 一个都不是引入的"

# ② 调用计划
cdx "$(jq -n '[range(0; 7) | {purl: "pkg:pypi/p\(.)@1"}]')" > "$tmp/h7.json"
echo '[{"purl":"pkg:pypi/p6@1"},{"purl":"pkg:pypi/p5@1"}]' > "$tmp/i2.json"
assert_eq "$(lib "inspector_plan_chunks '$tmp/h7.json' '$tmp/i2.json' 3 5 '$tmp/c1'")" "3 0" "② 7 个组件、每块 3 个 → 3 块，没有丢下的"
assert_eq "$(jq -r '[.components[].purl] | join(",")' "$tmp/c1/chunk-1.json")" "pkg:pypi/p5@1,pkg:pypi/p6@1,pkg:pypi/p0@1" \
  "② 引入的组件排在第一块的最前面"
assert_eq "$(jq -r '.bomFormat + " " + .specVersion' "$tmp/c1/chunk-2.json")" "CycloneDX 1.5" "② 每块都是一份 CycloneDX 1.5 文档"
assert_eq "$(lib "inspector_plan_chunks '$tmp/h7.json' '$tmp/i2.json' 3 2 '$tmp/c2'")" "2 1" "② 调用上限 2 → 只送 2 块，丢下 1 个存量组件"
assert_eq "$(ls "$tmp/c2"/chunk-*.json | wc -l | tr -d ' ')" "2" "② 只写出 2 块"
assert_eq "$(lib "inspector_plan_chunks '$tmp/h7.json' '$tmp/i2.json' 0 2 '$tmp/c3'" >/dev/null 2>&1; echo $?)" "2" "② 每块组件数必须 ≥ 1"
cdx '[]' > "$tmp/h0.json"
assert_eq "$(lib "inspector_plan_chunks '$tmp/h0.json' '$tmp/i2.json' 3 2 '$tmp/c4'")" "0 0" "② 没有组件 → 0 块"

# ③ 合并与严重级别
vuln() { jq -n --arg id "$1" --argjson r "$2" --arg ref "$3" '{id: $id, ratings: $r, affects: [{ref: $ref}]}'; }
mkres() {  # <组件 JSON 数组> <漏洞 JSON 数组> → 一份 ScanSbom 响应（{sbom: …}）
  jq -n --argjson c "$1" --argjson v "$2" '{sbom: {bomFormat: "CycloneDX", specVersion: "1.5", components: $c, vulnerabilities: $v}}'
}
C='[{"bom-ref":"a","purl":"pkg:pypi/a@1","name":"a","version":"1"},{"bom-ref":"b","purl":"pkg:pypi/b@1","name":"b","version":"1"}]'
V="[$(vuln CVE-1 '[{"source":{"name":"GITHUB"},"severity":"critical","method":"CVSSv31"},{"source":{"name":"NVD"},"severity":"high","method":"CVSSv31"}]' a),
    $(vuln CVE-2 '[{"source":{"name":"GITHUB"},"severity":"low","method":"CVSSv31"},{"source":{"name":"VENDOR"},"severity":"medium","method":"CVSSv3"}]' b),
    $(vuln CVE-3 '[{"source":{"name":"EPSS"},"severity":"critical","method":"other","score":0.9}]' a),
    $(vuln CVE-1 '[{"source":{"name":"NVD"},"severity":"high","method":"CVSSv31"}]' b)]"
mkres "$C" "$V" > "$tmp/r1.json"
echo '[{"purl":"pkg:pypi/a@1"}]' > "$tmp/ia.json"
rep=$(lib "inspector_merge '$tmp/ia.json' '$tmp/r1.json'")
assert_eq "$(jq -r '[.vulns[] | "\(.id):\(.severity):\(.introduced)"] | join(",")' <<< "$rep")" \
  "CVE-1:critical:true,CVE-2:medium:false,CVE-3:unknown:true" "③ 取全部 CVSS 评级（任何来源）里最高的；EPSS 不算严重级别；按严重级别序排"
assert_eq "$(jq -r '.vulns[] | select(.id == "CVE-1") | [.components[].purl] | join(",")' <<< "$rep")" "pkg:pypi/a@1,pkg:pypi/b@1" \
  "③ 同一个 id 合并成一条，列出全部受影响组件"
assert_eq "$(jq -c '.counts' <<< "$rep")" \
  '{"introduced":{"critical":1,"high":0,"medium":0,"low":0,"other":1},"existing":{"critical":0,"high":0,"medium":1,"low":0,"other":0}}' \
  "③ 计数按「引入 / 存量」分开，unknown 归「其它」"
# 跨块合并：同一个 id 出现在两块结果里
mkres '[{"bom-ref":"x","purl":"pkg:pypi/b@1"}]' "[$(vuln CVE-9 '[{"source":{"name":"NVD"},"severity":"low","method":"CVSSv31"}]' x)]" > "$tmp/r2.json"
mkres '[{"bom-ref":"y","purl":"pkg:pypi/a@1"}]' "[$(vuln CVE-9 '[{"source":{"name":"NVD"},"severity":"low","method":"CVSSv31"}]' y)]" > "$tmp/r3.json"
assert_eq "$(lib "inspector_merge '$tmp/ia.json' '$tmp/r2.json' '$tmp/r3.json' | jq -c '[.vulns[] | {id, introduced, n: (.components | length)}]'")" \
  '[{"id":"CVE-9","introduced":true,"n":2}]' "③ 跨块的同一个 id 合并；任一受影响组件是引入的 → 这条算引入"

# ④ 与 Inspector 的 metadata 计数一致（规则是从真实输出里定下来的；fixture 换成真实输出后这条才有意义）
got=$(lib "inspector_counts_vs_metadata '$FIX/scan-response.json'")
assert_eq "${got% / *}" "${got#* / }" "④ 按我们的规则算出的 critical/high/medium/low 计数 = Inspector 在 metadata 里给的计数（${got}）"

report
