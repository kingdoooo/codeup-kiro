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

# --- 缺 jq → 同样退出码 5 ---
mkdir -p "$tmp/nojq"; for f in "$tmp/nokiro"/*; do ln -sf "$(readlink "$f")" "$tmp/nojq/$(basename "$f")"; done; rm -f "$tmp/nojq/jq"; ln -sf "$tmp/fakebin/kiro-cli" "$tmp/nojq/kiro-cli"
rc=0; err=$(env -i PATH="$tmp/nojq" HOME="$tmp/home" bash "$PROBE" 2>&1) || rc=$?
assert_eq "$rc" "5" "缺 jq：退出码 5"

report
