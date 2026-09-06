#!/usr/bin/env bash
# 极简断言库。失败即打印并退出非零。
TESTS_PASSED=0

assert_eq() {  # 实际值 期望值 说明
  if [[ "$1" == "$2" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $3 — 期望 [$2]，实际 [$1]" >&2
    exit 1
  fi
}

# 子串断言用 bash 自己的 [[ == *"$sub"* ]]（逐字节、多行同样适用），**不走 printf | grep -qF**：grep -q 命中即退出，
# 内容较长时 printf 会收到 EPIPE，测试文件都开了 pipefail，于是管道整体非零——明明包含却报 FAIL
# （2026-09-07 全套与别的会话并发运行时实测复现：「渲染：统计行注明已标注到行的条数」内容里明明有那一行）。
assert_contains() {  # 内容 子串 说明
  if [[ "$1" == *"$2"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $3 — 未找到子串 [$2]，内容: [$1]" >&2
    exit 1
  fi
}

assert_not_contains() {  # 内容 子串 说明
  if [[ "$1" == *"$2"* ]]; then
    echo "FAIL: $3 — 不应出现子串 [$2]" >&2
    exit 1
  else
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

assert_rc() { assert_eq "$1" "$2" "$3"; }

# DRY_RUN 下数一数脚本真的发了哪些请求（stderr 上每个请求一行 `DRY_RUN <方法> <URL>`）。
# 用法：req_count "$OUT" PUT [URL 片段（ERE）]
# 端到端与变异测试都要用：判定「原地更新」还是「新建」全靠这个，实现只能有一份——
# DRY_RUN 的日志行格式一变，两处拷贝里只改一处的那一处会静静地一直数出 0。
req_count() {
  local pat="DRY_RUN $2 "
  [[ -n "${3:-}" ]] && pat="${pat}.*$3"
  printf '%s\n' "$1" | grep -cE -- "$pat" || true
}

# DRY_RUN 下本次「创建行内评论」请求的 body（每条一行 compact JSON）。
# 用法：inline_bodies "$OUT"
# 必须按 file_path 过滤：查现有行内评论那次请求的 body 也是 {"comment_type":"INLINE_COMMENT"}，
# 只按类型抓会多算一条。端到端与变异测试都要用它判断「到底发了几条行内评论、发到哪一行」，
# 所以实现只能有一份——过滤条件一变，两处拷贝里没改的那一处会静静地数错。
# `|| true`：一条行内评论都没发时 grep 以 1 退出，而测试文件都开了 pipefail——
# 没有这个兜底，「零条」这种完全正常的用例会让整个测试文件在此处无提示中止（与 req_count 同理）。
inline_bodies() {
  { printf '%s\n' "$1" | grep -F 'DRY_RUN body: {"comment_type":"INLINE_COMMENT"' || true; } \
    | sed 's/^DRY_RUN body: //' | jq -c 'select(has("file_path"))'
}

# 汇总/降级/失败评论里的「元信息行」（`| \`sha\` | \`src\` → \`dst\` | 时间 | diff |`）。
# 单测与变异测试都要用它判断「分支名有没有撑破表格 / 有没有把原始 HTML 带进单元格」，
# 所以实现只能有一份——提取管道一变，两处拷贝里没改的那一处会静静地返回空串，
# 然后以「过滤失效」的名义失败，把维护者引向错误的方向（与 req_count/inline_bodies 同一理由）。
# 没匹配到时返回空串而不是让调用方在 pipefail 下直接中止（调用方要能打出自己的诊断）。
meta_row() { printf '%s\n' "$1" | { grep -F '| `' || true; } | { grep -F ' → ' || true; } | head -1; }

# 端到端 fixture 里机器人账号的用户名（取自 spec §4.7.1 P1-00 实测值）
TEST_BOT_USERNAME='aliyun:kingdooo_hvFXC'

# ---- 替身 kiro-cli 的配置通道（15-fix #14 / 15-fix2 #19）----
# 生产脚本以 env -i + 许可清单启动 kiro-cli，MOCK_* 环境变量到不了替身。替身只从 **$HOME/.kiro-mock/** 取配置与写记录：
# HOME 在固定名单里（真实 kiro-cli 的登录态与 agent 目录也靠它），每个用例都有自己的 $CASE/home，所以不需要借道
# KIRO_ENV_PASSTHROUGH——那是一个安全控制，端到端与变异测试不该与它耦合（收紧它就全红）；passthrough/badpass 是仅有的逃生口用例。
# 目录下：mock.env  行为开关，每行 MOCK_X=值（由 mock_config_write 写、mock_config_load 读——解析与写入只有这一份）
#         args stdin settings cwdscan calls helpcwd env env-help env-settings allowscan nonce   替身的记录文件（固定名字）
# 拿不到该目录时替身**非零退出（97）并报错**：漏配要变成红测试，而不是「记不了 args 于是『Kiro 未启动』恒真」。
mock_dir_of_home() { printf '%s/.kiro-mock' "$1"; }
mock_config_write() { # <HOME 目录> [MOCK_X=值 ...]（非 MOCK_ 开头的参数忽略，便于把 run_case 的 "$@" 原样传进来）
  local dir; dir=$(mock_dir_of_home "$1"); shift
  local a
  mkdir -p "$dir"; : > "$dir/mock.env"
  for a in "$@"; do [[ "$a" == MOCK_* ]] && printf '%s\n' "$a" >> "$dir/mock.env"; done
  return 0
}
mock_config_load() { # <HOME 目录>：把 .kiro-mock/mock.env 里的 MOCK_X=值 导出到当前 shell（同名后者覆盖前者，与 env 的语义一致）
  local dir line n v; dir=$(mock_dir_of_home "$1")
  [[ -r "$dir/mock.env" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^(MOCK_[A-Z0-9_]+)=(.*)$ ]] || continue
    n="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    export "$n=$v"
  done < "$dir/mock.env"
}

# ---- 注入面扫描（15-fix2 #23 / 15-fix4 #6）：**转调**生产 scripts/lib/isolation.sh 的单一发射器 review_isolation_scan，谓词只有一份 ----
# 在 cwd（业务库根）执行，每行一个相对路径（去掉 class 列、NUL 换成换行；路径含换行的会拆成两行——只用于替身 cwdscan 与端到端
# leftovers() 这类「有没有残留」的断言，集合相等的断言直接比 NUL 清单）。以前这里是第二份 find 表达式，本票内就与生产分叉过一次。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/isolation.sh"
injection_surface_scan() {
  review_isolation_scan | tr '\0' '\n' | cut -f2-
  return 0
}

report() { echo "OK: ${TESTS_PASSED} 个断言通过（$0）"; }
