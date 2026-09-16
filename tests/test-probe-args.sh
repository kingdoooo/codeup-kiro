#!/usr/bin/env bash
# 探测脚本 scripts/probe/probe-kiro-allowlist.sh 的参数与退出码分级（15-fix2 #5 #22）——不调用 kiro-cli 的那部分：
#   2 = 参数错（PROBE_CASES 含未知用例名，零调用）
#   5 = 环境准备失败（缺 kiro-cli / jq / timeout 等）
# 其余分级（0 门禁全 PASS / 1 门禁 FAIL / 3 INCONCLUSIVE / 4 门禁未全部运行）需要真实 kiro-cli，由 sandbox 探测记录。
# 用一个假 kiro-cli（whoami 说已登录、--version 打版本）让脚本走到参数校验，而不真正发起任何 chat 调用。
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
ROOT=$(cd .. && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
PROBE="$ROOT/scripts/probe/probe-kiro-allowlist.sh"
if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null; then
  echo "SKIP: 本机无 timeout/gtimeout（GNU coreutils），跳过 test-probe-args.sh" >&2
  exit 0
fi

assert_rc "$(bash -n "$PROBE" && echo 0 || echo 1)" 0 "探测脚本语法合法"
# 15-fix4 #20：脚本头部的退出码表与 README 里的表逐字一致（15-fix3 #5 改了正控 agent 装不上的行为，头部那行没跟着改，同文件两段注释互相矛盾）
hdr_table=$(grep -E '^#   [0-5] = ' "$PROBE" | sed 's/^#   //')
readme_table=$(awk '/退出码分级.*逐字一致/{f=1; next} f && /^  ```$/{c++; if (c==2) exit; next} f && c==1 {sub(/^  /, ""); print}' "$ROOT/scripts/probe/README.md")
assert_eq "$(printf '%s\n' "$hdr_table" | grep -c .)" "6" "探测头部退出码表有 0–5 六行"
assert_eq "$readme_table" "$hdr_table" "探测头部退出码表与 README 的表逐字一致"

# 假 kiro-cli：只回答 whoami / --version；任何 chat 调用都记录下来（用于断言零调用）
mkdir -p "$tmp/fakebin" "$tmp/home"
cat > "$tmp/fakebin/kiro-cli" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  whoami) echo "Logged in with fake"; exit 0 ;;
  --version) echo "kiro-cli 0.0.0-fake"; exit 0 ;;
  *) echo "chat $*" >> "${FAKE_KIRO_CALLS:-/dev/null}"; exit 0 ;;
esac
SH
chmod +x "$tmp/fakebin/kiro-cli"
export FAKE_KIRO_CALLS="$tmp/calls"

# --- 未知用例名 → 退出码 2，零调用（15-fix #5：PROBE_CASES=t1 曾零调用却打「全部 PASS」）---
rc=0; err=$(env PATH="$tmp/fakebin:$PATH" HOME="$tmp/home" PROBE_CASES="t1" PROBE_KEEP_DIR="$tmp/keep1" bash "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "2" "PROBE_CASES=t1：退出码 2（参数错）"
assert_contains "$err" "未知用例名" "PROBE_CASES=t1：报错点名"
assert_eq "$([[ -e "$tmp/calls" ]] && echo called || echo none)" "none" "PROBE_CASES=t1：零次 kiro-cli chat 调用"
rc=0; err=$(env PATH="$tmp/fakebin:$PATH" HOME="$tmp/home" PROBE_CASES="T1 T99" PROBE_KEEP_DIR="$tmp/keep2" bash "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "2" "PROBE_CASES 混入 T99：退出码 2"
assert_not_contains "$err" "全部 PASS" "参数错时绝不打「全部 PASS」"
assert_not_contains "$err" "走主方案" "参数错时绝不打「走主方案」"

# --- 缺 kiro-cli → 退出码 5（环境准备失败，与门禁 FAIL 的 1 分开；15-fix2 #22）---
mkdir -p "$tmp/nokiro"; for t in bash jq git awk sed grep head tail tr cut sort paste od date mktemp cp rm mkdir ln printf cat basename dirname wc timeout gtimeout uname env; do
  p=$(command -v "$t" 2>/dev/null || true); [[ -n "$p" ]] && ln -sf "$p" "$tmp/nokiro/$t"
done
rc=0; err=$(env -i PATH="$tmp/nokiro" HOME="$tmp/home" bash "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "5" "缺 kiro-cli：退出码 5（环境准备失败，不是门禁 FAIL 的 1）"
assert_contains "$err" "缺少 kiro-cli" "缺 kiro-cli：报错点名"

# --- 身份（平台 + 版本）确定不了 → 退出码 5（CodeX 2026-09-13 复审 P1）---
# 探测的产物是「这个元组通过了门禁」这一条发布证据。没有元组的 rc 0 是一份不能绑定到任何东西的「通过」，
# 只看退出码的人 / 自动化会拿它当有效证据。所以身份要在跑任何**耗额度**用例之前就确定，缺了按「环境准备失败」退 5。
# 假 kiro-cli 报的是 `kiro-cli 0.0.0-fake`——整行锚定之后解析不出唯一版本，正好用来测这条。
rc=0; err=$(env PATH="$tmp/fakebin:$PATH" HOME="$tmp/home" PROBE_KEEP_DIR="$tmp/keep-noident" bash "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "5" "版本号解析不出（kiro-cli 0.0.0-fake）：退出码 5（环境准备失败），不是跑完再警告"
assert_contains "$err" "版本号解析不出" "版本未知：报错点名"
assert_not_contains "$err" "全部 PASS" "版本未知：绝不打「全部 PASS」"
assert_not_contains "$err" "走主方案" "版本未知：绝不打「走主方案」"
assert_eq "$([[ -e "$tmp/calls" ]] && echo called || echo none)" "none" "版本未知：零次 kiro-cli chat 调用（没烧额度）"
# 版本能解析时不该被这条挡住（正控：换一个报合法版本的假 kiro-cli，就会走到后面的环境准备而不是「版本未知」）
mkdir -p "$tmp/fakebin2"
cat > "$tmp/fakebin2/kiro-cli" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  whoami) echo "Logged in with fake"; exit 0 ;;
  --version) echo "kiro-cli 9.9.9"; exit 0 ;;
  *) echo "chat $*" >> "${FAKE_KIRO_CALLS:-/dev/null}"; exit 0 ;;
esac
SH
chmod +x "$tmp/fakebin2/kiro-cli"
rc=0; err=$(env PATH="$tmp/fakebin2:$PATH" HOME="$tmp/home2" PROBE_KEEP_DIR="$tmp/keep-ident" bash "$PROBE" 2>&1) || rc=$?
assert_not_contains "$err" "版本号解析不出" "正控：版本合法时不再报「版本未知」"
assert_contains "$err" "本次探测身份：" "正控：版本合法时打出「平台:版本」身份行"

# ============ 票 18 ④：参考 YAML 里 MR_TARGET_BRANCH 用 `:=`（envs 注入不被覆盖）============
# 这段是**静态**断言（不跑 Flow）：YAML 的 run 块是一段 shell，抽出来做语法检查与两条语义检查。
YAML="$ROOT/pipeline/flow-pipeline.yaml"
assert_eq "$(LC_ALL=C grep -c '^                : "\${MR_TARGET_BRANCH:=\$CI_COMMIT_TARGET_REF_NAME_1}"; export MR_TARGET_BRANCH$' "$YAML")" "1" \
  "④：YAML 用 : \"\${MR_TARGET_BRANCH:=…}\" 写法（不是无条件 export）"
assert_eq "$(LC_ALL=C grep -c '^ *export MR_TARGET_BRANCH="\$CI_COMMIT_TARGET_REF_NAME_1"' "$YAML")" "0" \
  "④：YAML 里不再有无条件 export MR_TARGET_BRANCH=…（那会把 envs 注入值覆盖掉）"
assert_eq "$(LC_ALL=C grep -c '^                export CI_COMMIT_REF_NAME="\$CI_COMMIT_REF_NAME_1"$' "$YAML")" "1" \
  "④：CI_COMMIT_REF_NAME 那行仍是无条件覆盖（多代码源歧义，必须显式压掉）"
# run 块（`run: |` 之后缩进 16 空格的那些行）本身要是合法 shell
runblk=$(mktemp)
LC_ALL=C awk '/^              run: \|$/ {f=1; next} f && /^                / {sub(/^                /, ""); print; next} f {exit}' "$YAML" > "$runblk"
assert_eq "$([[ -s "$runblk" ]] && echo nonempty)" "nonempty" "④：从 YAML 里抽出了 run 块"
assert_rc "$(bash -n "$runblk" && echo 0 || echo 1)" 0 "④：YAML 的 run 块是合法 shell"
# 语义两条：注入时保留注入值；未注入时取内置变量
assert_eq "$(env -i PATH="$PATH" CI_COMMIT_TARGET_REF_NAME_1=master MR_TARGET_BRANCH=injected bash --noprofile --norc -c ': "${MR_TARGET_BRANCH:=$CI_COMMIT_TARGET_REF_NAME_1}"; printf %s "$MR_TARGET_BRANCH"')" "injected" \
  "④：已注入 MR_TARGET_BRANCH 时 := 不覆盖它"
assert_eq "$(env -i PATH="$PATH" CI_COMMIT_TARGET_REF_NAME_1=master bash --noprofile --norc -c ': "${MR_TARGET_BRANCH:=$CI_COMMIT_TARGET_REF_NAME_1}"; printf %s "$MR_TARGET_BRANCH"')" "master" \
  "④：未注入时 := 取内置变量的取值"
# 指南与参考 YAML 同一写法（~127 行那段），且「已知坑」段落改成「参考 YAML 已用 := 写法」
GUIDE="$ROOT/pipeline/setup-guide.md"
assert_eq "$(LC_ALL=C grep -c ': "\${MR_TARGET_BRANCH:=\$CI_COMMIT_TARGET_REF_NAME_1}"; export MR_TARGET_BRANCH' "$GUIDE")" "1" \
  "④：setup-guide 第 5.1 节示例与 YAML 同一写法"
assert_eq "$(LC_ALL=C grep -c '已知坑：若之后要从 API 触发流水线' "$GUIDE")" "0" "④：指南里的「已知坑」段落已改写"
assert_contains "$(cat "$GUIDE")" "参考 YAML（\`pipeline/flow-pipeline.yaml\`）已经用" "④：指南改为指向参考 YAML 的写法"
rm -f "$runblk"

# ============ issue 08：钉版档位的 OSSDownload 步骤（静态断言；真实行为是人工/流水线验收）============
# 评审脚本对 OSS 一无所知（ADR-0006），所以这一步纯粹是流水线配置。本地套件覆盖不到 OSSDownload 的真实执行，
# 只能守住参考 YAML 的结构不变式：步骤存在、排在评审之前、走服务连接不带 AK/SK（I10）、并把
# 「targetFilePath ≡ KIRO_PINNED_ARTIFACT 且在业务库之外」这条跨组件不变式写进注释。
assert_eq "$(LC_ALL=C grep -c 'step: OSSDownload' "$YAML")" "1" "08：参考 YAML 恰有一个 OSSDownload 步骤"
# 排序：OSSDownload 必须在评审启动行之前（安装包要先落地，评审脚本才读得到）
oss_ln=$(LC_ALL=C grep -m1 -n 'step: OSSDownload' "$YAML" | cut -d: -f1)
rev_ln=$(LC_ALL=C grep -m1 -n '/bin/bash -p "\$PROJECT_DIR/\.\./integration_repo/scripts/kiro-review\.sh"' "$YAML" | cut -d: -f1)
assert_eq "$([[ -n "$oss_ln" && -n "$rev_ln" && "$oss_ln" -lt "$rev_ln" ]] && echo before)" "before" \
  "08：OSSDownload 步骤排在评审启动行之前"
# 步骤配置齐备：源对象键 + 落地路径 + 走服务连接
assert_eq "$(LC_ALL=C grep -c '^ *sourceFilePath:' "$YAML")" "1" "08：OSSDownload 配了 sourceFilePath（桶内对象键）"
assert_eq "$(LC_ALL=C grep -c '^ *targetFilePath:' "$YAML")" "1" "08：OSSDownload 配了 targetFilePath（执行器本地落地路径）"
# I10：OSS 鉴权走服务连接（RAM），AK/SK 绝不进 YAML。整份 YAML 不得出现任何形态的 access key
assert_eq "$(LC_ALL=C grep -ciE 'accesskey|access-key|ak_secret|aksk' "$YAML")" "0" "08：YAML 里没有任何 AK/SK 形态（OSS 鉴权走服务连接，I10）"
# 跨组件不变式必须在注释里写清：targetFilePath 与 KIRO_PINNED_ARTIFACT 逐字相同、且在业务库之外
assert_eq "$(LC_ALL=C grep -c '与 UI 变量 KIRO_PINNED_ARTIFACT 逐字相同' "$YAML")" "1" \
  "08：YAML 注明 targetFilePath ≡ KIRO_PINNED_ARTIFACT（否则下载到的文件与脚本读的路径对不上）"
assert_contains "$(cat "$YAML")" "业务库" "08：YAML 注明落地路径必须在业务库 checkout 之外"
# 钉版路径绝不 curl 官方安装脚本（那是 latest 档位的事）——整份 YAML 不出现安装脚本 URL
assert_eq "$(LC_ALL=C grep -c 'cli.kiro.dev/install' "$YAML")" "0" "08：钉版参考 YAML 不出现 curl 官方安装脚本"

# ============ 票 18 ⑫：探测脚本的三处静态守卫 ============
# ① 「命令管进 grep -q」的形状（grep -q 命中即退出 → 上游收 SIGPIPE → pipefail 下管道非零 → 找到了却判成没找到）
for f in probe-kiro-headless.sh probe-kiro-allowlist.sh probe-codeup-inline.sh probe-flow-run.sh; do
  assert_eq "$(LC_ALL=C grep -cE '[^|]\|[[:space:]]*grep -[a-zA-Z]*q' "$ROOT/scripts/probe/$f" || true)" "0" \
    "⑫：${f} 里没有「把命令输出管进 grep -q」的形状（改子串比较；逻辑或后面的 grep -q、以及读文件 / here-string 的 grep -q 不在此列）"
done
# ② RAN（实际运行的用例集合）必须在每次 CASES 变化之后重算：清空 CASES 的那一行后面就得跟一次重算
assert_eq "$(LC_ALL=C grep -c 'CASES=""; recalc_ran' "$ROOT/scripts/probe/probe-kiro-allowlist.sh")" "1" \
  "⑫：清空 CASES 的地方紧跟一次 recalc_ran（否则汇总会声称门禁用例都跑过）"
assert_eq "$(LC_ALL=C grep -cE '^CASES=""$|^ *CASES=""$' "$ROOT/scripts/probe/probe-kiro-allowlist.sh" || true)" "0" \
  "⑫：没有「清空 CASES 却不重算 RAN」的写法"
# ③ kiro_cli_version 在空目录（$KIRO_CWD）下跑，与生产四处调用一致
assert_eq "$(LC_ALL=C grep -c 'kiro_cli_version "\$TIMEOUT_BIN" "\$KIRO_CWD"' "$ROOT/scripts/probe/probe-kiro-allowlist.sh")" "1" \
  "⑫：probe-kiro-allowlist.sh 的 kiro_cli_version 在 \$KIRO_CWD 下跑"
# ④ run_case / run_case_agent 共用一份实现（_probe_run），拼命令与计时只有一处
assert_eq "$(LC_ALL=C grep -c 'kiro-cli chat --no-interactive --agent-engine v2' "$ROOT/scripts/probe/probe-kiro-allowlist.sh")" "1" \
  "⑫：探测里拼 kiro-cli 命令只有一处（run_case 与 run_case_agent 都走 _probe_run）"
assert_rc "$(bash -n "$ROOT/scripts/probe/probe-kiro-headless.sh" && echo 0 || echo 1)" 0 "⑫：probe-kiro-headless.sh 语法合法"

# ============ 票 18 ⑦：run-tests.sh 的 bash 解析诊断守卫（行为测试，不是静态断言）============
# 用两个假测试文件跑一遍真实的 run-tests.sh：一个「断言报 OK 但自身有解析错误」、一个干净的。
# 两条要求：① 全绿时也要因解析诊断整体失败并打出那几行；② **有套件失败时诊断照样要跑**——
# 否则「命中即整体失败」只在其它套件都通过时成立，而解析错误恰恰最常与失败同时出现。
rt_probe() { # <失败套件？yes|no> → stdout: "<rc>|<有没有诊断块>"
  local withfail="$1" d rc=0 out
  d=$(mktemp -d)
  cp "$ROOT/tests/run-tests.sh" "$d/"
  # 要复现 ⑦ 真正修的那个形态：解析错误在**命令替换内部**（运行期报错），文件本身照样以 0 退出、断言照样报 OK
  printf '#!/usr/bin/env bash\necho "x ``` %sy" >/dev/null\necho "z ``` w" >/dev/null\necho OK\n' "'" > "$d/test-aaa.sh"
  printf '#!/usr/bin/env bash\necho OK\n' > "$d/test-bbb.sh"
  [[ "$withfail" == "yes" ]] && printf '#!/usr/bin/env bash\necho "别的原因失败" >&2; exit 3\n' > "$d/test-ccc.sh"
  out=$(bash "$d/run-tests.sh" 2>&1) || rc=$?
  printf '%s|%s' "$rc" "$([[ "$out" == *"bash 解析诊断"* ]] && echo 有 || echo 无)"
  rm -rf "$d"
}
assert_eq "$(rt_probe no)" "1|有" "⑦：全绿但有解析诊断 → 整体以 1 退出并打出诊断块"
assert_eq "$(rt_probe yes)" "3|有" "⑦：有套件失败时保留该套件的退出码，且诊断块照样打出来（不能被 fail-fast 跳过）"
# CodeX 2026-09-09 复审 P2：`生产函数 | head -1` 让 printf 吃 EPIPE——stderr 一行 `printf: write error: Broken pipe`、断言照样 OK。诊断要认它。
rt_probe_epipe() { # → "<rc>|<有没有诊断块>"
  local d rc=0 out
  d=$(mktemp -d); cp "$ROOT/tests/run-tests.sh" "$d/"
  printf '#!/usr/bin/env bash\necho "%s: line 1: printf: write error: Broken pipe" >&2\necho OK\n' "test-aaa.sh" > "$d/test-aaa.sh"
  out=$(bash "$d/run-tests.sh" 2>&1) || rc=$?
  printf '%s|%s' "$rc" "$([[ "$out" == *"bash 解析诊断"* ]] && echo 有 || echo 无)"
  rm -rf "$d"
}
assert_eq "$(rt_probe_epipe)" "1|有" "P2：stderr 里的 write error: Broken pipe 也算诊断 → 全绿也整体以 1 退出"

# ============ 票 18 ⑬：awk locale 静态守卫 ============
# macOS 自带 awk（20200816）在 UTF-8 locale 下会把两条**不同**的中文行判成相等（D4 修复替身时实测：
# `=== 变更元信息 ===` == `=== 评审输入开始 ===` 为真，LC_ALL=C 下正确），而且遇到无效 UTF-8 字节会直接罢工。
# 所以 scripts/ 与测试基建里**每个** awk 调用都必须带 LC_ALL=C。两种例外在同一行注明即放行：
#   awk-ascii-only —— 确属只处理 ASCII 的调用；
#   awk-utf8-substr —— 刻意要**字符**语义的 substr 截断（探测脚本的诊断尾巴，按字节截会把中文截成半个字符，15-fix4 #14）。
# 只数**命令位置**上的 awk（行首 / 管道 / `;` / `&&` / `(` / `$(` 之后）：错误文案里的「awk 退出非零」不算调用。
# 扫描收成函数，下面用一份「故意去掉一处 LC_ALL=C」的副本做正控（证明这条守卫不是空转）。
awk_locale_bad() { # <树根> → 每行一个「文件:行号」（缺 LC_ALL=C 的 awk 调用）
  local root="$1" f
  for f in "$root"/scripts/*.sh "$root"/scripts/lib/*.sh "$root"/scripts/probe/*.sh "$root"/tests/mockbin/* "$root"/tests/helpers.sh "$root"/tests/fixture-repo.sh; do
    [[ -f "$f" ]] || continue
    LC_ALL=C grep -nE '(^|[|;&(]|\$\()[[:space:]]*(LC_ALL=C[[:space:]]+)?awk[[:space:]]' "$f" \
      | LC_ALL=C grep -v 'LC_ALL=C[[:space:]]*awk' \
      | LC_ALL=C grep -vE 'awk-ascii-only|awk-utf8-substr' \
      | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*#' \
      | LC_ALL=C sed "s|^|${f#$root/}:|" | LC_ALL=C cut -d: -f1,2
  done
  return 0
}
assert_eq "$(awk_locale_bad "$ROOT" | LC_ALL=C paste -sd' ' -)" "" \
  "⑬：scripts/ 与测试基建里每个 awk 调用都带 LC_ALL=C（例外须在同一行注明 awk-ascii-only）"
# 正控：把替身里的一处 LC_ALL=C 去掉 → 守卫必须报出那一行
awkroot="$tmp/awkroot"
mkdir -p "$awkroot/scripts/lib" "$awkroot/scripts/probe" "$awkroot/tests/mockbin"
cp "$ROOT"/scripts/*.sh "$awkroot/scripts/" 2>/dev/null || true
cp "$ROOT"/scripts/lib/*.sh "$awkroot/scripts/lib/"
cp "$ROOT"/scripts/probe/*.sh "$awkroot/scripts/probe/"
cp "$ROOT"/tests/helpers.sh "$ROOT"/tests/fixture-repo.sh "$awkroot/tests/"
LC_ALL=C sed 's/LC_ALL=C awk -v s="\$MOCK_SENT"/awk -v s="$MOCK_SENT"/' "$ROOT/tests/mockbin/kiro-cli" > "$awkroot/tests/mockbin/kiro-cli"
assert_eq "$(LC_ALL=C grep -c 'LC_ALL=C awk -v s="\$MOCK_SENT"' "$awkroot/tests/mockbin/kiro-cli" || true)" "0" "⑬ 正控：副本里那处 LC_ALL=C 确实被去掉了"
assert_eq "$(awk_locale_bad "$awkroot" | LC_ALL=C paste -sd' ' -)" "tests/mockbin/kiro-cli:$(LC_ALL=C grep -n 'awk -v s="\$MOCK_SENT"' "$awkroot/tests/mockbin/kiro-cli" | LC_ALL=C cut -d: -f1)" \
  "⑬ 正控：守卫报出替身里缺 LC_ALL=C 的那一行（这条守卫不是空转）"
# 例外机制：同一行写 awk-ascii-only 就放行（给确属 ASCII-only 的调用留一个显式出口）
LC_ALL=C sed 's|awk -v s="\$MOCK_SENT"|awk -v s="$MOCK_SENT"  # awk-ascii-only|' "$awkroot/tests/mockbin/kiro-cli" > "$awkroot/tests/mockbin/kiro-cli.tmp"
mv "$awkroot/tests/mockbin/kiro-cli.tmp" "$awkroot/tests/mockbin/kiro-cli"
assert_eq "$(awk_locale_bad "$awkroot" | LC_ALL=C paste -sd' ' -)" "" "⑬ 例外机制：同一行注明 awk-ascii-only 的调用被放行"
# 事实本身也钉一条（不是所有机器都能复现，所以只在 macOS 自带 awk 上断言）：LC_ALL=C 下两条不同的中文行不相等
if [[ -x /usr/bin/awk ]]; then
  assert_eq "$(LC_ALL=C /usr/bin/awk 'BEGIN { print ("=== 变更元信息 ===" == "=== 评审输入开始 ===") ? "equal" : "differ" }')" "differ" \
    "⑬：LC_ALL=C 下两条不同的中文行判为不相等（UTF-8 locale 下 macOS 自带 awk 会判成相等——这就是守卫存在的理由）"
fi

# --- 缺 jq → 同样退出码 5 ---
mkdir -p "$tmp/nojq"; for f in "$tmp/nokiro"/*; do ln -sf "$(readlink "$f")" "$tmp/nojq/$(basename "$f")"; done; rm -f "$tmp/nojq/jq"; ln -sf "$tmp/fakebin/kiro-cli" "$tmp/nojq/kiro-cli"
rc=0; err=$(env -i PATH="$tmp/nojq" HOME="$tmp/home" bash "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "5" "缺 jq：退出码 5"

# --- 文档里的探测命令必须带 `-p`（CodeX 2026-09-13 第五轮复审 P1）---
# 探测产出的是发布证据。裸 `bash` 会在读到脚本第一行之前 source $BASH_ENV 并导入环境里的函数——
# 一边在威胁模型里写明这点、一边在操作说明里让人按不安全的方式跑，是自相矛盾（allowlist 探测自己的报错
# 也要求 `bash -p`）。这条守卫防的是将来从 `bash -p` 漂回裸 `bash`。
for _f in "$ROOT/scripts/probe/README.md" "$ROOT/pipeline/setup-guide.md"; do
  assert_eq "$(LC_ALL=C grep -c 'bash scripts/probe/' "$_f" || true)" "0" \
    "$(basename "$_f")：没有裸 bash 启动探测的命令（一律 bash -p）"
done
assert_eq "$(LC_ALL=C grep -c 'bash -p scripts/probe/probe-kiro-allowlist.sh' "$ROOT/scripts/probe/README.md" || true)" "2" \
  "probe/README.md：allowlist 探测的两条命令都是 bash -p"
assert_eq "$(LC_ALL=C grep -c 'bash -p scripts/probe/probe-kiro-allowlist.sh' "$ROOT/pipeline/setup-guide.md" || true)" "1" \
  "setup-guide：升级流程里的 allowlist 探测命令是 bash -p"
unset _f

# --- 启动环境不可信 → 退出码 5（CodeX 2026-09-13 第四轮复审 P0）---
# 探测产出的是发布证据：BASH_ENV / 从环境导入的函数都能在第一条命令之前执行不受信代码，也能顶替脚本用到的 builtin。
: > "$tmp/probe-launch-payload.log"
printf 'command echo PROBE_PAYLOAD_RAN >> "%s"\n' "$tmp/probe-launch-payload.log" > "$tmp/probe-payload.sh"
rc=0; err=$(env -i PATH="$tmp/fakebin:$PATH" HOME="$tmp/home" BASH_ENV="$tmp/probe-payload.sh" bash "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "5" "BASH_ENV 非空：退出码 5"
assert_contains "$err" "启动环境不可信" "BASH_ENV：报错点明启动环境"
assert_eq "$(grep -c PROBE_PAYLOAD_RAN "$tmp/probe-launch-payload.log" 2>/dev/null || true)" "1" \
  "BASH_ENV：载荷在脚本第一行之前就跑了——所以启动方要用 bash -p，脚本层只能拒绝继续"
: > "$tmp/probe-launch-payload.log"
rc=0; err=$(env -i PATH="$tmp/fakebin:$PATH" HOME="$tmp/home" BASH_ENV="$tmp/probe-payload.sh" bash -p "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "5" "BASH_ENV + bash -p：仍然拒绝（环境里还有 BASH_ENV 就说明启动环境被污染过）"
assert_eq "$(grep -c PROBE_PAYLOAD_RAN "$tmp/probe-launch-payload.log" 2>/dev/null || true)" "0" \
  "BASH_ENV + bash -p：载荷一次都没跑"
FN_VAR_P=$(bash -c 'zzprobe() { :; }; export -f zzprobe; env' \
           | LC_ALL=C awk -F= '!f && /zzprobe/ && $0 ~ /=\(\) \{/ {print $1; f=1}')
assert_contains "$FN_VAR_P" "zzprobe" "元测试：问出了本机 bash 导出函数用的环境变量名"
rc=0; err=$(env -i PATH="$tmp/fakebin:$PATH" HOME="$tmp/home" \
            "${FN_VAR_P/zzprobe/pwd}=() { command echo FAKE >&2; builtin pwd \"\$@\"; }" bash "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "5" "环境里导入了假 pwd：退出码 5"
assert_contains "$err" "启动环境不可信" "导入函数：报错点明启动环境"
# 同一形态改用 `bash -p`：本进程不导入函数，但 BASH_FUNC_* 还在 environ 里 → PATH 门之后那一步拒绝（第五轮 P1）
rc=0; err=$(env -i PATH="$tmp/fakebin:$PATH" HOME="$tmp/home" \
            "${FN_VAR_P/zzprobe/pwd}=() { command echo FAKE >&2; builtin pwd \"\$@\"; }" bash -p "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "5" "bash -p + environ 里残留 BASH_FUNC_*：退出码 5"
assert_contains "$err" "environ 里还有" "bash -p + BASH_FUNC_*：报错点明 environ 里的残留"
assert_not_contains "$err" "BASH_FUNC_pwd" "bash -p + BASH_FUNC_*：不打印具体函数名"
# 拒绝路径不打印取值（第五轮 P0）：探测与主脚本同一条规则
# 令牌形状的 canary 用变量拼前缀，源文件里没有字面 `ghp_`+连片（不触发密钥扫描器——公开客户仓库）
_ghp=ghp; PROBE_LEAK="${_ghp}_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
rc=0; err=$(env -i PATH="$tmp/fakebin:$PATH" HOME="$tmp/home" \
            BASH_ENV="$PROBE_LEAK" bash "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "5" "BASH_ENV 取值是令牌形状：退出码 5"
assert_contains "$err" "BASH_ENV 已设置" "P0：只报状态"
assert_not_contains "$err" "${_ghp}_" "P0：BASH_ENV 的取值不进日志"

report
