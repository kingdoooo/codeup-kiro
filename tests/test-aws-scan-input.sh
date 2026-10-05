#!/usr/bin/env bash
# 扫描员的输入准备（aws/executor/lib/scan-input.sh；Phase 2b spec「I8（改写）」「N8」「S1」「S3」，issue 06）。
#   ① 导出取自 git 对象：树内 .gitattributes 与执行器 core.attributesFile 的 export-ignore / export-subst 一律失效；
#      AGENTS.md、.kiro/、根 lsp.json 都在（N8 的实质）；符号链接全删；文件集合 = 提交树的非链接文件；不给 Kiro 留改动。
#   ② N8 静态：执行器里没有对工作树的打包动作；扫描输入的准备在调 kiro-review.sh 之前。
#   ③ scan_prep_inspector：各种失败 → 枚举状态；成功 → 两个不可变键、带 ExpectedBucketOwner。
#   ④ S1（只在 Linux、root、有 setpriv 时跑——构建机容器测 ct.sh 里）：sbomgen 以 uid 65534、空环境运行，读不到 PID 1 的 environ。
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh
ROOT="$(cd .. && pwd)"
ENTRY=../aws/executor/entrypoint.sh
LIB=../aws/executor/lib/scan-input.sh
[[ -x /usr/bin/git && -x /usr/bin/jq ]] || { echo "SKIP: 需要 /usr/bin/git 与 /usr/bin/jq，跳过 test-aws-scan-input.sh" >&2; exit 0; }
tmp=$(mktemp -d); [[ -n "${KEEP_TMP:-}" ]] || trap 'rm -rf "$tmp"' EXIT
lgit() { GIT_CONFIG_GLOBAL="${LGIT_GLOBAL:-/dev/null}" GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
           GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com /usr/bin/git "$@"; }

# 一个「业务库」：base 提交 + MR 提交；MR 作者在树里放了 export-ignore / export-subst 与几种注入面、符号链接
B="$tmp/work/business"; mkdir -p "$B"; lgit init -q -b main "$B"
echo 'requests==2.31.0' > "$B/requirements.txt"; lgit -C "$B" add -A; lgit -C "$B" commit -qm base
BASE=$(lgit -C "$B" rev-parse HEAD)
lgit -C "$B" checkout -qb feat
printf 'hidden.py export-ignore\nver.txt export-subst\n' > "$B/.gitattributes"
# 复审 M-2：内容转换类属性同样能改写导出物——working-tree-encoding 把清单转成 UTF-16（sbomgen 读不出依赖）、ident 与 eol 改字节
printf 'requirements.txt working-tree-encoding=UTF-16\nid.txt ident\ncrlf.txt text eol=crlf\n' >> "$B/.gitattributes"
echo 'eval(input())' > "$B/hidden.py"; printf '$Format:%%H$\n' > "$B/ver.txt"
echo steering > "$B/AGENTS.md"; mkdir -p "$B/.kiro"; echo '{}' > "$B/.kiro/x.json"; echo '{}' > "$B/lsp.json"
printf 'requests==2.19.0\n' | /usr/bin/iconv -f UTF-8 -t UTF-16 > "$B/requirements.txt"   # 工作树按属性是 UTF-16，blob 是 UTF-8
printf '$Id$\n' > "$B/id.txt"; printf 'a\nb\n' > "$B/crlf.txt"
ln -s /proc/1/environ "$B/package-lock.json"; ln -s /etc "$B/etc-link"; ln -s missing "$B/dangling"
lgit -C "$B" add -A; lgit -C "$B" commit -qm mr
HEAD=$(lgit -C "$B" rev-parse HEAD)
lgit -C "$B" update-ref refs/remotes/origin/main "$BASE"
# 执行器自己的 git 配置也带一条 export-ignore（core.attributesFile）——同样必须失效
printf '* export-ignore\n' > "$tmp/global-attrs"; printf '[core]\n\tattributesFile = %s\n' "$tmp/global-attrs" > "$tmp/gitconfig"

run_lib() {  # <bash 代码> [KEY=VAL …]：在一个新 bash 里 source 库（路径换成替身）后执行
  local code="$1"; shift
  local prog
  prog=$(sed -e "s#/usr/local/bin/aws#$tmp/aws#g" -e "s#/opt/sbomgen/inspector-sbomgen#$tmp/sbomgen#g" \
             -e "s#/usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs#${SETPRIV:-$tmp/setpriv}#g" \
             -e "s#/usr/bin/timeout -k 10#${TIMEOUT_BIN:-/usr/bin/env}#g" "$LIB")
  ( export WORKROOT="$tmp/work" HEAD_SHA="$HEAD" MR_TARGET_BRANCH=main CODEUP_REPO_ID=7 AWS_REGION=us-west-2 \
           SCAN_RUN_ID="$(printf 'c%.0s' {1..32})" SCAN_BUCKET=bkt SCAN_BUCKET_OWNER=123456789012 \
           GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 "$@"
    /bin/bash --norc --noprofile -c "set -euo pipefail; $prog
$code" ) </dev/null
}
# 替身：setpriv 只是把后面的命令原样执行（④ 用真的）；timeout 缺省换成 /usr/bin/env（吃掉「秒数」参数不行——见下），
# 所以 timeout 替身单独写：丢掉秒数再执行
printf '#!/bin/sh\nexec "$@"\n' > "$tmp/setpriv"
# 它包着两种命令：导出管道（/bin/bash -c '… git archive | tar …'，复审 M-4）与 sbomgen（setpriv …）——各用各的开关，
# 免得「sbomgen 超时」的用例先在导出那一步就红了。FAKE_TIMEOUT_RC：137 = timeout 的 -k KILL，或别人（OOM）的 KILL。
cat > "$tmp/timeout" <<'STUB'
#!/bin/sh
shift
case "$1" in
  /bin/bash) [ -n "${FAKE_EXPORT_RC:-}" ] && exit "$FAKE_EXPORT_RC" ;;
  *) [ -n "${FAKE_TIMEOUT:-}" ] && exit "${FAKE_TIMEOUT_RC:-124}" ;;
esac
exec "$@"
STUB
# 输出路径写死进替身（env -i 之后它拿不到任何环境变量——这本身就是 S1 要的效果；STUB_MODE 同理经文件传）
cat > "$tmp/sbomgen" <<STUB
#!/bin/sh
env > "$tmp/env.out"
{ echo "home=\$HOME"; if [ -d "\$HOME" ] && [ -w "\$HOME" ]; then echo homeok=yes; else echo homeok=no; fi; } > "$tmp/home.out"
STUB_MODE=\$(cat "$tmp/stub.mode" 2>/dev/null || echo ok)
STUB
cat >> "$tmp/sbomgen" <<'STUB'
# 参数：directory --path <树> -o <输出> --skip-cloud-metadata（Task 1：--disable-progress-bar 已废弃、升级后会报错，不再传）
[ "$#" = 6 ] && [ "$1" = directory ] && [ "$2" = --path ] && [ "$4" = -o ] && [ "$6" = --skip-cloud-metadata ] || exit 9
case "${STUB_MODE:-ok}" in
  ok) printf '{"bomFormat":"CycloneDX","specVersion":"1.5","metadata":{"component":{"bom-ref":"comp-1","type":"file","name":"%s"}},"components":[{"name":"requests","purl":"pkg:pypi/requests@x","properties":[{"name":"amazon:inspector:sbom_generator:source_path","value":"%s/requirements.txt"}]}]}' "$3" "$3" > "$5" ;;
  fail) echo "boom" >&2; exit 1 ;;
  notcdx) echo '{"hello":1}' > "$5" ;;
esac
STUB
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s/aws.argv"\n[ -n "${FAKE_S3_FAIL:-}" ] && exit 254\nexit 0\n' "$tmp" > "$tmp/aws"
chmod +x "$tmp/setpriv" "$tmp/timeout" "$tmp/sbomgen" "$tmp/aws"
export TIMEOUT_BIN="$tmp/timeout"

# ① 导出
run_lib "scan_export_tree '$HEAD' '$tmp/out'" >/dev/null 2>"$tmp/err"; rc=$?
assert_eq "$rc" "0" "① 导出成功"
assert_eq "$(cat "$tmp/out/hidden.py" 2>/dev/null)" "eval(input())" "① 树内 export-ignore 失效：hidden.py 在导出物里"
assert_eq "$(cat "$tmp/out/ver.txt" 2>/dev/null)" '$Format:%H$' "① 树内 export-subst 失效：内容与 blob 逐字节相同"
for f in requirements.txt id.txt crlf.txt; do
  assert_eq "$(cmp -s "$tmp/out/$f" <(lgit -C "$B" cat-file blob "$HEAD:$f") && echo same)" "same" \
    "① 树内的内容转换属性失效：${f} 与 blob 逐字节相同（working-tree-encoding / ident / eol；复审 M-2）"
done
for f in AGENTS.md .kiro/x.json lsp.json .gitattributes requirements.txt; do
  assert_eq "$([ -f "$tmp/out/$f" ] && echo yes)" "yes" "① N8 的实质：${f} 在导出物里（隔离会删它，导出取自 git 对象所以不受影响）"
done
assert_eq "$(find "$tmp/out" -type l | wc -l | tr -d ' ')" "0" "① 导出物里没有任何符号链接"
want=$(lgit -C "$B" ls-tree -r "$HEAD" | awk '$1 != "120000" {sub(/^[^\t]*\t/, ""); print}' | sort)
got=$(cd "$tmp/out" && find . -type f | sed 's#^\./##' | sort)
assert_eq "$got" "$want" "① 导出物的文件集合 = 提交树的非链接文件（不多不少）"
assert_eq "$([ -e "$B/.git/info/attributes" ] && echo yes || echo no)" "no" "① 导出完删掉了临时的 info/attributes（不给 Kiro 留改动）"
assert_eq "$(run_lib "scan_export_tree HEAD '$tmp/out2'" 2>/dev/null; echo $?)" "1" "① 提交号不是 40 位十六进制 → 拒绝（HEAD 之类的 revision 表达式不收）"
# 正向对照：不加那一行 info/attributes 时，同一个 git 确实会藏掉 hidden.py（证明上面不是因为这个 git 根本不认 export-ignore）
mkdir -p "$tmp/ctl"; lgit -C "$B" archive --format=tar "$HEAD" | tar -x -C "$tmp/ctl"
assert_eq "$([ -e "$tmp/ctl/hidden.py" ] && echo yes || echo no)" "no" "① 正向对照：没有那一行时 export-ignore 真的生效"
for f in requirements.txt id.txt crlf.txt; do
  assert_eq "$(cmp -s "$tmp/ctl/$f" <(lgit -C "$B" cat-file blob "$HEAD:$f") && echo same || echo converted)" "converted" \
    "① 正向对照：没有那一行时 ${f} 真的被转换了"
done

# ② N8 静态
code=$(cat "$ENTRY" ../aws/executor/lib/*.sh | LC_ALL=C grep -vE '^[[:space:]]*#')
assert_eq "$(printf '%s\n' "$code" | LC_ALL=C grep -nE '(^|[[:space:];|&])(zip|cp -r|cp -R|tar -c|tar c)[[:space:]].*WORKROOT/business' || true)" "" \
  "② N8：执行器里没有对业务库工作树的打包动作"
assert_eq "$(printf '%s\n' "$code" | LC_ALL=C grep -c 'git -C "\$gd" archive')" "1" "② 唯一一处 git archive 在 scan_export_tree 里"
sd=$(LC_ALL=C grep -nE '^  if ! scan_dispatch "\$scan_rids"; then' "$ENTRY" | cut -d: -f1)
kr=$(LC_ALL=C grep -nE '^/usr/bin/timeout -k 30 "\$engine_cap" /bin/bash -p "\$PKG/scripts/kiro-review.sh"' "$ENTRY" | cut -d: -f1)
assert_eq "$([ -n "$sd" ] && [ -n "$kr" ] && [ "$sd" -lt "$kr" ] && echo yes)" "yes" "② N8：扫描输入在调 kiro-review.sh（隔离在它里面）之前准备"

# ③ scan_prep_inspector
prep() {  # [STUB_MODE=…] [KEY=VAL …]
  rm -f "$tmp/aws.argv" "$tmp/env.out"; rm -rf "$tmp/work/scan"; echo ok > "$tmp/stub.mode"
  case "${1:-}" in STUB_MODE=*) echo "${1#STUB_MODE=}" > "$tmp/stub.mode"; shift ;; esac
  run_lib 'scan_prep_inspector' "$@" 2>"$tmp/err"
}
assert_eq "$(prep)" "ok" "③ 正常 → ok"
keys=$(awk 'p{print; p=0} $0=="--key"{p=1}' "$tmp/aws.argv")
assert_eq "$keys" "inspector/7/$HEAD/$(printf 'c%.0s' {1..32})/head.cdx.json
inspector/7/$HEAD/$(printf 'c%.0s' {1..32})/base.cdx.json" "③ 两个不可变键：inspector/<仓库>/<提交>/<run_id>/{head,base}.cdx.json"
assert_eq "$(grep -c -- '--expected-bucket-owner' "$tmp/aws.argv")" "2" "③ 每次上传都带 ExpectedBucketOwner（S3）"
assert_eq "$(awk 'p{print; p=0} $0=="--expected-bucket-owner"{p=1}' "$tmp/aws.argv" | sort -u)" "123456789012" "③ 期望的属主是本账号"
envnames=$(sed 's/=.*//' "$tmp/env.out" | LC_ALL=C grep -vE '^(PWD|SHLVL|_|OLDPWD)$' | sort | tr '\n' ' ')
assert_eq "$envnames" "HOME PATH " "③ S1：sbomgen 在空环境里跑（env -i，只有 PATH 与 HOME）"
home=$(sed -n 's/^home=//p' "$tmp/home.out")
assert_eq "$(sed -n 's/^homeok=//p' "$tmp/home.out")" "yes" "③ sbomgen 的 HOME 是一个存在且可写的目录（Task 1：它要在 \$HOME/.inspector-sbomgen 建工作目录，不可写就必然失败）"
assert_eq "$([ "$home" != /nonexistent ] && [ -n "$home" ] && echo yes)" "yes" "③ HOME 不是 /nonexistent"
assert_eq "$([ -e "$home" ] && echo yes || echo no)" "no" "③ 私有 HOME 用完删掉"
hj="$tmp/work/scan/inspector/head.cdx.json"
assert_eq "$(/usr/bin/jq -r '.components[0].properties[0].value' "$hj" 2>/dev/null)" "requirements.txt" \
  "③ 组件路径改写成相对树根（执行器内部路径不进 S3、Inspector 与 MR 评论——Task 1 Q9）"
assert_eq "$(/usr/bin/jq -r '.metadata.component.name' "$hj" 2>/dev/null)" "." "③ 根组件名（被扫目录的绝对路径）改成 ."
assert_eq "$(ls -A "$tmp/work/scan/inspector" | sort | tr '\n' ' ')" "base.cdx.json head.cdx.json " \
  "③ 导出的两棵树用完即删、只留两份清单：不在 Kiro 评审期间占着两份仓库大小的磁盘（F2；复审 I-3）"
assert_eq "$(prep MR_TARGET_BRANCH=)" "failed:no-target-branch" "③ 没有目标分支 → failed:no-target-branch"
assert_eq "$(prep MR_TARGET_BRANCH=nope)" "failed:merge-base" "③ 目标分支在 clone 里没有 → failed:merge-base"
assert_eq "$(prep STUB_MODE=fail)" "failed:sbomgen" "③ sbomgen 失败 → failed:sbomgen"
assert_contains "$(cat "$tmp/err")" "  sbomgen: boom" "③ sbomgen 的报错尾巴进日志（固定前缀）"
assert_eq "$(ls -A "$tmp/work/scan/inspector" 2>/dev/null | LC_ALL=C grep -vE '\.cdx\.json$' || true)" "" "③ 失败路径上导出的树同样删掉"
assert_eq "$(prep FAKE_TIMEOUT=1)" "failed:sbomgen-timeout" "③ sbomgen 超时 → failed:sbomgen-timeout"
# 复审 M-6：137 有两种来源——timeout 到点后 -k 的 KILL（真超时）与时限之前别人（OOM killer）的 KILL；按已用时间区分
assert_eq "$(prep FAKE_TIMEOUT=1 FAKE_TIMEOUT_RC=137)" "failed:sbomgen-killed" "③ M-6 sbomgen 在时限之前被 KILL（多为内存不足）→ failed:sbomgen-killed"
assert_eq "$(prep FAKE_TIMEOUT=1 FAKE_TIMEOUT_RC=137 SBOMGEN_TIMEOUT=0)" "failed:sbomgen-timeout" "③ M-6 已到时限的 137（-k 的 KILL）仍是 failed:sbomgen-timeout"
# 复审 M-4：导出管道有时限（git archive | tar 包在 timeout 里），超时与其它导出失败分开报
assert_eq "$(prep FAKE_EXPORT_RC=124)" "failed:export-timeout" "③ M-4 导出超时 → failed:export-timeout"
assert_eq "$(prep FAKE_EXPORT_RC=137)" "failed:export-timeout" "③ M-4 导出超时后被 -k 的 KILL → failed:export-timeout"
assert_eq "$(prep FAKE_EXPORT_RC=1)" "failed:export" "③ M-4 其它导出失败仍是 failed:export"
assert_eq "$(ls -A "$tmp/work/scan/inspector" 2>/dev/null | tr '\n' ' ')" "" "③ M-4 导出失败时导出到一半的树也删掉（复审 I-3 的失败路径）"
assert_eq "$(prep STUB_MODE=notcdx)" "failed:sbom-not-cyclonedx" "③ 输出不是 CycloneDX → failed:sbom-not-cyclonedx"
assert_eq "$(prep SBOM_MAX_BYTES=10)" "failed:sbom-too-large" "③ 输出超过上限 → failed:sbom-too-large"
assert_eq "$(prep FAKE_S3_FAIL=1)" "failed:upload" "③ 上传失败 → failed:upload"

# ④ S1 真跑：Linux、root、有 setpriv
if [[ "$(uname -s)" == Linux && "$(id -u)" == 0 && -x /usr/bin/setpriv ]]; then
    cat > "$tmp/sbomgen" <<STUB
#!/bin/sh
{ echo "uid=\$(id -u)"; if cat /proc/1/environ >/dev/null 2>&1; then echo environ=readable; else echo environ=denied; fi; } > "$tmp/s1/s1.out"
printf '{"bomFormat":"CycloneDX","components":[]}' > "\$5"
STUB
  chmod +x "$tmp/sbomgen"
  # mktemp -d 是 0700：不放开，uid 65534 连替身都执行不了（④ 就会因为权限而不是因为 S1 红）。结果写进一个 0777 的子目录。
  chmod 0755 "$tmp"; mkdir -p "$tmp/s1"; chmod 0777 "$tmp/s1"
  rm -rf "$tmp/work/scan"; mkdir -p "$tmp/tree"; echo x > "$tmp/tree/a"
  SETPRIV="/usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs" \
    run_lib "scan_sbomgen '$tmp/tree' '$tmp/s1.json'" 2>"$tmp/err"
  assert_eq "$(cat "$tmp/s1/s1.out")" "uid=65534
environ=denied" "④ S1：sbomgen 以 uid 65534 运行、读不到 PID 1（root）的 environ"
else
  echo "SKIP: ④ S1 真跑需要 Linux + root + /usr/bin/setpriv（构建机容器测 ct.sh 里会跑）" >&2
fi

report
