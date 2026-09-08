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

report
