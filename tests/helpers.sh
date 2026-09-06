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

assert_contains() {  # 内容 子串 说明
  if printf '%s' "$1" | grep -qF -- "$2"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $3 — 未找到子串 [$2]，内容: [$1]" >&2
    exit 1
  fi
}

assert_not_contains() {  # 内容 子串 说明
  if printf '%s' "$1" | grep -qF -- "$2"; then
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

report() { echo "OK: ${TESTS_PASSED} 个断言通过（$0）"; }

# --- 票 16（A10）：合成凭证的三种形态与它们掩码后的样子 ---
# 由片段拼接而成：仓库源码里不能出现完整的凭证形态字面量（Code Defender 会拦）。
# 单测（golden）、端到端替身与变异测试三处共用同一份取值：任何一处自己再拼一份，掩码规则一变就会
# 有一处静静地测着别的东西。
SEC_GHP="ghp_""abcdefghij""klmnopqrst""uvwxyz0123""456789"   # GitHub PAT（classic）：ghp_ + 36 位
SEC_GHP_MASKED='ghp_****6789'
SEC_AKIA="AKIA""TESTFAKE01234567"                            # AWS 访问密钥 ID：AKIA + 16 位大写字母数字
SEC_AKIA_MASKED='AKIA****4567'
SEC_B64="dGhpcyBpcyBh""IHNlY3JldA=="                         # key=value 取值：末尾带 base64 补位 =
SEC_B64_MASKED='dGhp****dA=='
# 用法：with_secrets <契约 JSON 文件> → stdout：同一份契约，只多了 token——
#   summary 末尾 + ghp_、verdict_reason 末尾 + AKIA、findings[0].title 末尾 + AKIA、findings[0].body 末尾 + ghp_、
#   findings[0].fix 里独占一行 api_key = "<base64>"（有代码围栏就放围栏内最后一行）、findings[2].body 第一句句末前 + ghp_
#   （折叠区只渲染首句，放在句号之后就进不了折叠区）。
# 每处插入都是「一个空格 + token」或独占一行，所以把 token/掩码剔掉就能逐字节还原成不带 token 的渲染结果——
# golden 测试靠这一点证明「掩码只动了 token」。
with_secrets() {
  jq --arg ghp "$SEC_GHP" --arg akia "$SEC_AKIA" --arg b64 "$SEC_B64" '
    .summary += " " + $ghp
    | .verdict_reason += " " + $akia
    | .findings[0].title += " " + $akia
    | .findings[0].body += " " + $ghp
    | .findings[0].fix |= (("api_key = \"" + $b64 + "\"") as $kv
                           | if endswith("```") then .[:-3] + $kv + "\n```" else . + "\n" + $kv end)
    | .findings[2].body |= sub("。"; " " + $ghp + "。")' "$1"
}
# 故障注入替身：只让 review_redact_secrets 那段 awk 程序失败（按程序文本识别），其余 awk 调用透传给真 awk——
# 否则 diff/变更行的 awk 也会挂，评审在到达 sink 之前就失败了，测不到「掩码失败」这一段。
# 真 awk 的路径在这里就解析好并写死进替身，不在替身里靠剥 PATH 首项去找：kiro-review.sh 找不到 kiro-cli 时
# 会往 PATH 前面再插一段，那时首项就不是替身目录，剥错了就会 exec 到自己、无限递归。
# 用法：make_bad_awk <目录>   → 在 <目录>/awk 写好替身；调用方把 <目录> 放到 PATH 最前面
make_bad_awk() {
  local dir="$1" real
  real=$(command -v awk) || { echo "make_bad_awk: 本机找不到 awk" >&2; return 1; }
  mkdir -p "$dir"
  {
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do'
    echo '  [[ "$a" == *"function mask(s)"* ]] && { echo "badawk: 模拟掩码程序失败" >&2; exit 1; }'
    echo 'done'
    printf 'exec %q "$@"\n' "$real"
  } > "$dir/awk"
  chmod +x "$dir/awk"
}
