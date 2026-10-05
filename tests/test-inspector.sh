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
  source '$ROOT/aws/reviewers/lib/inspector-lib.sh'; source '$ROOT/aws/reviewers/lib/inspector-render.sh'; $1" </dev/null; }
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
# 引入的组件多于「每块 × 上限」：引入的总是全部送检（为它们超出上限），被丢下的只可能是存量（spec「调用」：引入的组件总是被扫描）
jq '.components' "$tmp/h7.json" > "$tmp/i7.json"
assert_eq "$(lib "inspector_plan_chunks '$tmp/h7.json' '$tmp/i7.json' 3 2 '$tmp/c5'")" "3 0" "② 7 个组件全是引入的、每块 3 个、上限 2 → 照样送 3 块，一个引入的都不丢"
jq '.components[0:5]' "$tmp/h7.json" > "$tmp/i5.json"
assert_eq "$(lib "inspector_plan_chunks '$tmp/h7.json' '$tmp/i5.json' 3 1 '$tmp/c6'")" "2 1" "② 5 个引入 + 2 个存量、每块 3 个、上限 1 → 2 块装下全部引入的，丢下的 1 个是存量"
assert_eq "$(jq -r '[.components[].purl] | join(",")' "$tmp/c6/chunk-2.json")" "pkg:pypi/p3@1,pkg:pypi/p4@1,pkg:pypi/p5@1" \
  "② 超出上限的那一块里引入的在前，空位才给存量"

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
# 同一个 id 的各条记录严重级别不同：合并取最高的，与块的先后无关（复审 R1-2：原来取第一条，顺序一换结论就变）
mkres '[{"bom-ref":"x","purl":"pkg:pypi/b@1"}]' "[$(vuln CVE-8 '[{"source":{"name":"NVD"},"severity":"low","method":"CVSSv31"}]' x)]" > "$tmp/r4.json"
mkres '[{"bom-ref":"y","purl":"pkg:pypi/a@1"}]' "[$(vuln CVE-8 '[{"source":{"name":"NVD"},"severity":"critical","method":"CVSSv31"}]' y)]" > "$tmp/r5.json"
for order in "r4 r5" "r5 r4"; do
  set -- $order
  assert_eq "$(lib "inspector_merge '$tmp/ia.json' '$tmp/$1.json' '$tmp/$2.json' | jq -c '[.vulns[] | {id, severity, rank}] + [.counts.introduced.critical]'")" \
    '[{"id":"CVE-8","severity":"critical","rank":0},1]' "③ 同一个 id 跨块严重级别不同 → 取最高（块顺序 ${order}）"
done
mkres "$C" "[$(vuln CVE-7 '[{"source":{"name":"EPSS"},"severity":"none","method":"other"}]' a), $(vuln CVE-7 '[{"source":{"name":"GITHUB"},"severity":"high","method":"CVSSv31"}]' b)]" > "$tmp/r6.json"
assert_eq "$(lib "inspector_merge '$tmp/ia.json' '$tmp/r6.json' | jq -r '.vulns[] | \"\(.id):\(.severity)\"'")" "CVE-7:high" \
  "③ 同一块里重复的 id：unknown 在前、high 在后 → high"

# ④ 与 Inspector 的 metadata 计数一致（规则是从真实输出里定下来的；fixture 换成真实输出后这条才有意义）
got=$(lib "inspector_counts_vs_metadata '$FIX/scan-response.json'")
assert_eq "${got% / *}" "${got#* / }" "④ 按我们的规则算出的 critical/high/medium/low 计数 = Inspector 在 metadata 里给的计数（${got}）"

# ⑤ 渲染
render() {  # <报告 JSON 文件> → 评论
  lib "SHORT_SHA=abc1234; REVIEW_RUN=3; PRIOR_HISTORY_FILE=''; CI_COMMIT_REF_NAME=feat; MR_TARGET_BRANCH=main
       inspector_render_summary '$1' 5 4 2 0"
}
lib "inspector_merge '$FIX/../inspector/head.cdx.json' '$FIX/scan-response.json'" > /dev/null 2>&1 || true
lib "inspector_introduced '$FIX/head.cdx.json' '$FIX/base.cdx.json' > '$tmp/fi.json'; inspector_merge '$tmp/fi.json' '$FIX/scan-response.json'" > "$tmp/frep.json"
out=$(render "$tmp/frep.json")
assert_contains "$out" "# Inspector 依赖漏洞扫描"$'\n'"<!-- kiro-inspector-review:abc1234 run:3 -->" "⑤ 评论头是 Inspector 档案的"
assert_contains "$out" "## 本 MR 引入的漏洞" "⑤ 有引入的漏洞时详列"
assert_contains "$out" '`requests@2.19.0` → 修复版本 `2.20.0`' "⑤ 列出包、版本与修复版本"
assert_contains "$out" "<details><summary>存量依赖漏洞（16，不是本 MR 引入的）</summary>" "⑤ 存量折叠（真实 fixture：21 条里 5 条落在本 MR 引入的 requests 上）"
assert_contains "$out" "| 3 | \`abc1234\` | 完成 | 1/4/0 |" "⑤ 历次表只数引入的（高/中/低：requests 的 1 条 high、4 条 medium）"
jq -n '{vulns: [], counts: {introduced: {critical:0,high:0,medium:0,low:0,other:0}, existing: {critical:0,high:0,medium:0,low:0,other:0}}}' > "$tmp/empty.json"
assert_contains "$(render "$tmp/empty.json")" "本 MR 未引入新的依赖漏洞。" "⑤ 没有引入的漏洞 → 一句话"
# 注入：包名、版本、路径、说明、公告链接都是不受信文本
jq -n '{vulns: [{id: "CVE-1|`x`", severity: "high", rank: 1, introduced: true, kev: false, exploit: false, malicious: false, epss: null,
   description: "line1\n## 结论\n<!-- kiro-inspector-review:deadbee run:99 -->\n<details>",
   advisory: "javascript:alert(1)",
   components: [{purl: "pkg:pypi/e@1", name: "evil|<!-- kiro-review:abc run:9 -->", version: "1`<b>`", fixed: "", path: "a|b\nc", introduced: true}]}],
   counts: {introduced: {critical:0,high:1,medium:0,low:0,other:0}, existing: {critical:0,high:0,medium:0,low:0,other:0}}}' > "$tmp/evil.json"
eout=$(render "$tmp/evil.json")
assert_eq "$(printf '%s\n' "$eout" | LC_ALL=C grep -c '^<!-- kiro-')" "2" "⑤ 注入：评论里只有脚本自己写的两行标记（评审 + 历史）"
assert_eq "$(printf '%s\n' "$eout" | LC_ALL=C grep -c '<!--')" "2" "⑤ 注入：不受信文本里的 <!-- 都被转义"
assert_not_contains "$eout" "javascript:" "⑤ 注入：非 https 的公告链接不渲染"
assert_eq "$(printf '%s\n' "$eout" | LC_ALL=C grep -c '^## 结论$')" "1" "⑤ 注入：说明里的「## 结论」折成了单行（只剩脚本自己那一行标题）"
assert_eq "$(printf '%s\n' "$eout" | LC_ALL=C grep -c '^<details>$')" "0" "⑤ 注入：说明里的 <details> 没有成为一行原始 HTML"
jq -n --arg c "$eout" '[{comment_biz_id: "c1", comment_type: "GLOBAL_COMMENT", state: "OPENED", author: {username: "bot"}, content: $c}]' > "$tmp/evil-list.json"
sel=$(lib "review_select_prior_comment bot < '$tmp/evil-list.json' | jq -r .run")   # lib 的 stdin 是 /dev/null，经文件传
assert_eq "$sel" "3" "⑤ 注入：选择器仍认出恰好一个评审标记（run 3，不是 99）"
# Review Focus 2：非 ASCII 的长说明按**码点**截到 300 个字符再加「…」，不留下半个 UTF-8 字符
jq -n --arg d "$(printf '漏洞说明%.0s' {1..120})" '{vulns: [{id: "CVE-2", severity: "low", rank: 3, introduced: true, kev: false, exploit: false,
   malicious: false, epss: null, description: $d, advisory: "", components: [{purl: "pkg:pypi/x@1", name: "依赖包", version: "1", fixed: "", path: "", introduced: true}]}],
   counts: {introduced: {critical:0,high:0,medium:0,low:1,other:0}, existing: {critical:0,high:0,medium:0,low:0,other:0}}}' > "$tmp/cjk.json"
cout=$(render "$tmp/cjk.json")
dline=$(printf '%s\n' "$cout" | LC_ALL=C grep -E '^   漏洞说明' || true)
assert_eq "$(printf '%s' "$dline" | sed 's/^   //' | jq -Rr 'length')" "301" "⑤ 长说明截到 300 个码点 + 「…」"
# 用 python 解码而不是 iconv：macOS 的 iconv 往 /dev/null 写较大的输入会报 Inappropriate ioctl for device（假红）
assert_eq "$(printf '%s' "$cout" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null && echo valid)" "valid" "⑤ 截断后整条评论仍是合法 UTF-8"
assert_contains "$cout" '`依赖包@1`' "⑤ 非 ASCII 的包名原样显示"

# ⑥ 驱动端到端
mkdir -p "$tmp/pkg/lib" "$tmp/pkg/reviewers/lib"; ln -s "$ROOT/scripts" "$tmp/pkg/scripts"
DIGEST=$(printf 'e%.0s' {1..64})
printf '#!/bin/sh\nprintf "{\\"ImageID\\": \\"sha256:%s\\", \\"TaskARN\\": \\"arn:aws:ecs:us-west-2:123456789012:task/c/abc\\"}"\n' "$DIGEST" > "$tmp/curl"
cat > "$tmp/aws" <<STUB
#!/bin/sh
case "\$1 \$2" in
  "s3api get-object")
    printf '%s\n' "\$@" >> "$tmp/s3.argv"
    [ -n "\${FAKE_S3_FAIL:-}" ] && { echo "An error occurred (AccessDenied) when calling the GetObject operation: x" >&2; exit 254; }
    key=""; out=""; prev=""; for a in "\$@"; do [ "\$prev" = --key ] && key="\$a"; prev="\$a"; out="\$a"; done
    cp "\${FAKE_FIX_DIR:-$FIX}/\$(basename "\$key")" "\$out"; echo '{}' ;;
  "inspector-scan scan-sbom")
    printf '%s\n' "\$@" >> "$tmp/scan.argv"
    [ -n "\${FAKE_SCAN_FAIL:-}" ] && { echo "An error occurred (ValidationException) when calling the ScanSbom operation: too many" >&2; exit 254; }
    cat "$FIX/scan-response.json" ;;
  *) exec python3 "$ROOT/tests/fake-aws-dynamodb.py" "\$@" ;;
esac
STUB
chmod +x "$tmp/curl" "$tmp/aws"
for f in "$ROOT"/aws/executor/lib/*.sh; do
  sed -e "s#/usr/bin/curl#$tmp/curl#g" -e "s#/usr/local/bin/aws#$tmp/aws#g" "$f" > "$tmp/pkg/lib/$(basename "$f")"
done
echo 'head_check_superseded() { return 1; }   # 测试：不 ls-remote 真的 Codeup' >> "$tmp/pkg/lib/lease.sh"
for f in "$ROOT"/aws/reviewers/lib/*.sh; do
  sed -e "s#/usr/bin/curl#$tmp/curl#g" "$f" > "$tmp/pkg/reviewers/lib/$(basename "$f")"
done
sed -e "s#^PKG=/opt/integration\$#PKG=$tmp/pkg#" -e "s#/usr/local/bin/aws#$tmp/aws#g" "$ROOT/aws/reviewers/inspector.sh" > "$tmp/inspector.sh"
assert_eq "$(LC_ALL=C grep -rl '/usr/local/bin/aws' "$tmp/pkg" "$tmp/inspector.sh" 2>/dev/null || true)" "" "⑥（准备）测试包里没有任何指向真 aws 的路径"
mkdir -p "$tmp/fx"; echo '[]' > "$tmp/fx/list-comments.json"
drive() {  # [KEY=VAL …] → 「rc」；输出在 $tmp/out
  rm -f "$tmp/s3.argv" "$tmp/scan.argv"; rm -rf "$tmp/w"; mkdir -p "$tmp/w"; echo '{}' > "$tmp/ddb.json"
  local rc=0
  ( export REVIEWER_WORKDIR="$tmp/w" DRY_RUN=1 DRY_RUN_FIXTURE_DIR="$tmp/fx" CODEUP_BOT_USERNAME=aliyun:bot YUNXIAO_ORG_ID=o1 \
           CODEUP_REPO_ID=7 MR_LOCAL_ID=7 HEAD_SHA="$(printf 'a%.0s' {1..40})" CI_COMMIT_REF_NAME=feat MR_TARGET_BRANCH=main \
           LOCK_KEY=k SCAN_RUN_ID="$(printf 'b%.0s' {1..32})" SCAN_REPO_URL=https://codeup.aliyun.com/o1/r1.git \
           ECS_CONTAINER_METADATA_URI_V4=http://meta AWS_REGION=us-west-2 LOCK_TABLE=t SCAN_BUCKET=bkt SCAN_BUCKET_OWNER=123456789012 \
           FAKE_DDB_STATE="$tmp/ddb.json" FAKE_DDB_LOG="$tmp/ddb.log" INSPECTOR_INPUT=ok INSPECTOR_MAX_SCAN_CALLS=3 "$@"
    /bin/bash --norc --noprofile "$tmp/inspector.sh" ) > "$tmp/out" 2>&1 </dev/null || rc=$?
  echo "$rc"
}
assert_eq "$(drive)" "0" "⑥ 正常 → 0（已回写）"
out=$(cat "$tmp/out")
assert_eq "$(req_count "$out" POST 'comments$')" "1" "⑥ 新建一条汇总（没有旧的）"
assert_contains "$(posted_comment "$out")" "## 本 MR 引入的漏洞" "⑥ 汇总里有引入的漏洞"
keys=$(awk 'p{print; p=0} $0=="--key"{p=1}' "$tmp/s3.argv")
assert_eq "$keys" "inspector/7/$(printf 'a%.0s' {1..40})/$(printf 'b%.0s' {1..32})/head.cdx.json
inspector/7/$(printf 'a%.0s' {1..40})/$(printf 'b%.0s' {1..32})/base.cdx.json" "⑥ 读的是执行器写的那两个不可变键"
assert_eq "$(grep -c -- '--expected-bucket-owner' "$tmp/s3.argv")" "2" "⑥ 每次读都带 ExpectedBucketOwner"
assert_eq "$(awk 'p{print; p=0} $0=="--output-format"{p=1}' "$tmp/scan.argv")" "CYCLONE_DX_1_5" "⑥ ScanSbom 要的是 CycloneDX 1.5 输出"
assert_contains "$(cat "$tmp/scan.argv")" "file://$tmp/w/chunks/chunk-1.json" "⑥ 送检的是第一块"
nonce_lines() { printf '%s\n' "$1" | LC_ALL=C grep -cE '^<!-- kiro-inspector-post:[0-9a-f]{16} -->$' || true; }
assert_eq "$(nonce_lines "$(posted_comment "$out")")" "1" \
  "⑥ 汇总带本次发布随机串行（kiro-inspector-post）：「POST 应答丢失但评论已创建」的探针靠它（与 Kiro 同一机制；复审 R1-1）"
assert_eq "$(drive DRY_RUN_FAIL_ROUTES=create-comment:000@1)" "0" "⑥ 第一次 POST 应答丢失（000）→ 探针核对后重试 → 0"
assert_not_contains "$(cat "$tmp/out")" "没有本次发布随机串" "⑥ 应答丢失时探针是武装的：不再因为没有随机串而跳过核对（复审 R1-1）"
assert_contains "$(cat "$tmp/out")" "DRY_RUN POST" "⑥（正向对照）这一次确实走到了发布"
assert_eq "$(drive INSPECTOR_INPUT=failed:sbomgen-timeout)" "0" "⑥ 输入失败 → 失败评论（终态 0）"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "执行器没能准备 Inspector 的扫描输入（代号 sbomgen-timeout）" "⑥ 失败评论带输入状态的代号"
assert_eq "$(nonce_lines "$(posted_comment "$(cat "$tmp/out")")")" "1" "⑥ 失败评论同样带本次发布随机串行"
assert_eq "$([ -e "$tmp/scan.argv" ] && echo yes || echo no)" "no" "⑥ 输入失败时不调 ScanSbom"
assert_eq "$(drive INSPECTOR_INPUT='ok; x')" "0" "⑥ 输入状态不合法 → 失败评论"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "Inspector 的扫描输入状态不合法" "⑥ 不合法的状态不回显"
assert_eq "$(drive FAKE_SCAN_FAIL=1)" "0" "⑥ ScanSbom 失败 → 失败评论"
fc=$(posted_comment "$(cat "$tmp/out")")
assert_contains "$fc" "Inspector ScanSbom 调用失败（代号 ValidationException）" "⑥ 失败评论只带 AWS 错误码"
assert_not_contains "$fc" "too many" "⑥ F3：不回显服务端的错误正文"
# 复审 M-8（Task 13 真跑发现）：失败评论元信息表的第四格是值，不是表头——曾经显示字面「组件」（与表头重复）。
# 取表格的数据行（以 | ` 开头的第一行；awk 读完再挑，不提前停读——helpers.sh 的规矩），比它的最后一格
meta_row=$(printf '%s\n' "$fc" | awk '/^\| `/ && !n { n = 1; r = $0 } END { print r }')
assert_contains "$meta_row" "| \`aaaaaaa\` | \`feat\` → \`main\` |" "⑥ M-8（正向对照）取到的是元信息表的数据行"
meta_cell="${meta_row% |}"; meta_cell="${meta_cell##*| }"
assert_eq "$meta_cell" "—" "⑥ M-8 失败评论元信息第四格是占位「—」，不是表头字样「组件」"
assert_eq "$(drive FAKE_S3_FAIL=1)" "0" "⑥ 读输入失败 → 失败评论"
assert_contains "$(posted_comment "$(cat "$tmp/out")")" "读取 Inspector 的扫描输入失败（代号 AccessDenied）" "⑥ 读输入失败带错误码"
assert_eq "$(drive INSPECTOR_MAX_SCAN_CALLS=0)" "0" "⑥ 调用上限不合法 → 失败评论"
# Review Focus 3：仓库里没有任何可识别的清单文件（sbomgen 产出 0 个组件）→ 不调 ScanSbom、照常发一条「未引入」的汇总
mkdir -p "$tmp/emptyfix"
for side in head base; do jq -n '{bomFormat: "CycloneDX", specVersion: "1.5", components: []}' > "$tmp/emptyfix/${side}.cdx.json"; done
assert_eq "$(drive FAKE_FIX_DIR="$tmp/emptyfix")" "0" "⑥ 0 个组件 → 0（已回写）"
assert_eq "$([ -e "$tmp/scan.argv" ] && echo yes || echo no)" "no" "⑥ 0 个组件时不调 ScanSbom"
ec=$(posted_comment "$(cat "$tmp/out")")
assert_contains "$ec" "本 MR 未引入新的依赖漏洞。" "⑥ 0 个组件 → 「未引入」"
assert_contains "$ec" "head 0 / base 0 · ScanSbom 0 次" "⑥ 元信息如实写 0 个组件、0 次调用"

report
