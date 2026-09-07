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

# 不用 grep -q：-q 在第一处命中就退出，pipefail 下还没写完的 printf 会被 SIGPIPE 杀掉（rc 141）、整条管道判失败——
# 内容一大、机器一忙就随机出现「明明有子串却报未找到」的假阴性（2026-09-06/07 两次全套在负载 40+ 时各踩到一次）。
# 让 grep 读完全部输入（输出丢弃）即可，语义不变。
assert_contains() {  # 内容 子串 说明
  if printf '%s' "$1" | grep -F -- "$2" >/dev/null; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $3 — 未找到子串 [$2]，内容: [$1]" >&2
    exit 1
  fi
}

assert_not_contains() {  # 内容 子串 说明
  if printf '%s' "$1" | grep -F -- "$2" >/dev/null; then
    echo "FAIL: $3 — 不应出现子串 [$2]" >&2
    exit 1
  else
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

assert_rc() { assert_eq "$1" "$2" "$3"; }
# 非零退出码（第 15 条：`assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero"` 这句习语重复了十几次）
assert_nonzero() {  # rc 说明
  if [[ "$1" =~ ^[0-9]+$ && "$1" -ne 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $2 — 期望非零退出码，实际 [$1]" >&2
    exit 1
  fi
}
# 两个文件逐字节相同（第 15 条）：失败时打一次 diff，而不是只说 same/differ
assert_same_file() {  # 文件A 文件B 说明
  if cmp -s "$1" "$2"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $3 — 两个文件不同：[$1] vs [$2]" >&2
    diff "$1" "$2" | head -40 >&2 || true   # 第 29 条：先 head 再进 stderr（原先 diff 的 stdout 直接进了 stderr，head 读到空管道）
    exit 1
  fi
}

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
# 标题里的掩码：boldsafe 把所有 `*` 转义（16-fix4 第 22 条），渲染出来仍是 AKIA****4567，源码里是 AKIA\*\*\*\*4567
SEC_AKIA_MASKED_TITLE='AKIA\*\*\*\*4567'
SEC_GHP_MASKED_TITLE='ghp_\*\*\*\*6789'
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
# 三种 token 的六条事实一处定义（第 14 条）：原文都不在、掩码形态都在。只收**内容字符串**（文件调用方传 "$(cat f)"）——
# 以前有一个收文件路径的同名助手，串用时 assert_not_contains 对路径字面量恒真、只剩一半断言会响。
assert_masked() {  # 内容 说明前缀
  assert_no_secrets "$1" "$2"
  assert_contains "$1" "$SEC_GHP_MASKED" "$2：ghp_ 形态掩成前 4 后 4"
  # AKIA 掩码可能只出现在标题里（行内正文：title 是它唯一的槽位）——标题里的 * 一律转义（第 22 条），两种形态认一种即可
  if [[ "$1" == *"$SEC_AKIA_MASKED"* || "$1" == *"$SEC_AKIA_MASKED_TITLE"* ]]; then TESTS_PASSED=$((TESTS_PASSED + 1))
  else echo "FAIL: $2：AKIA 形态掩成前 4 后 4（正文 ${SEC_AKIA_MASKED} 或标题 ${SEC_AKIA_MASKED_TITLE}）— 都未找到，内容: [$1]" >&2; exit 1; fi
  assert_contains "$1" "$SEC_B64_MASKED" "$2：base64 补位形态掩成前 4 后 4"
}
assert_no_secrets() {  # 内容 说明前缀：三种原文都不在（掩码形态在不在不管——给「掩码失败 → 只剩固定文案」的用例用）
  assert_not_contains "$1" "$SEC_GHP" "$2：ghp_ 形态原文不出现"
  assert_not_contains "$1" "$SEC_AKIA" "$2：AKIA 形态原文不出现"
  assert_not_contains "$1" "$SEC_B64" "$2：base64 补位形态原文不出现"
}
# 故障注入替身：让 review_redact_secrets 那段 awk 程序失败（按程序文本识别），其余 awk 调用透传给真 awk——
# 否则 diff/变更行的 awk 也会挂，评审在到达出口之前就失败了，测不到「掩码失败」这一段。
# 真 awk 的路径在这里就解析好并写死进替身，不在替身里靠剥 PATH 首项去找：kiro-review.sh 找不到 kiro-cli 时
# 会往 PATH 前面再插一段，那时首项就不是替身目录，剥错了就会 exec 到自己、无限递归。
# 用法：make_bad_awk <目录> [all|doc|inline]   → 在 <目录>/awk 写好替身；调用方把 <目录> 放到 PATH 最前面
#   all（默认）：字段级与文档级都失败（→ review_redact_json 先失败，评审走失败评论）
#   doc：只让**评论出口**的文档级掩码失败（--keep-lines 且 stdin 带 <!-- kiro- 标记）——字段级（含单行槽位的保行模式）照常，
#        用来测出口兜底的失败分支
#   inline：只让**行内正文**的文档级掩码失败（stdin 里带 <!-- kiro-inline: 标记）——汇总照常发出，用来测「掩码失败 → 折叠区」
#   raw：只让**原文**（stdin 里没有任何 <!-- kiro- 标记：降级原文、日志行）的保行掩码失败——渲染好的评论照常过文档级兜底，
#        用来单独观察降级渲染器自己的 fail-closed（第 13 条）
make_bad_awk() {
  local dir="$1" mode="${2:-all}" real
  real=$(command -v awk) || { echo "make_bad_awk: 本机找不到 awk" >&2; return 1; }
  mkdir -p "$dir"
  {
    echo '#!/usr/bin/env bash'
    # 字段级 / 文档级 / 原文三种调用先按**参数**区分（16-fix4 第 21 条 + 补）：字段级掩码带 -v sentre=<非空>（--sentinel），一律放行；
    # 没有哨兵的 keep-lines 调用再看 stdin：含 <!-- kiro- 标记的是 comment.md / body-N.md（doc），不含的是降级原文 / 日志行（raw）。
    # 原先 doc 模式靠 stdin 含标记判定，会把 dump-k 单行槽位（模型 title 里伪造的标记原样进 dump-k）一起打坏；raw 模式反过来把
    # dump-k 与 _untrusted_for_log 一起打坏（M-s 只因走降级路径没调 review_redact_json 才侥幸）。
    echo 'is_mask=0; is_doc=0; has_sent=0'
    echo 'for a in "$@"; do'
    echo '  [[ "$a" == *"function mask(s)"* ]] && is_mask=1'
    echo '  [[ "$a" == "keeplines=1" ]] && is_doc=1'
    echo '  [[ "$a" == sentre=?* ]] && has_sent=1'
    echo 'done'
    case "$mode" in
      all)    echo '[[ $is_mask == 1 ]] && { echo "badawk: 模拟掩码程序失败" >&2; exit 1; }' ;;
      doc)    echo 'if [[ $is_mask == 1 && $is_doc == 1 && $has_sent == 0 ]]; then'
              echo '  buf=$(mktemp); cat > "$buf"'
              echo '  if grep -q "<!-- kiro-" "$buf"; then rm -f "$buf"; echo "badawk: 模拟文档级掩码失败" >&2; exit 1; fi'
              printf '  %q "$@" < "$buf"; rc=$?; rm -f "$buf"; exit $rc\n' "$real"
              echo 'fi' ;;
      inline) echo 'if [[ $is_mask == 1 && $is_doc == 1 && $has_sent == 0 ]]; then'
              echo '  buf=$(mktemp); cat > "$buf"'
              echo '  if grep -q "<!-- kiro-inline:" "$buf"; then rm -f "$buf"; echo "badawk: 模拟行内正文掩码失败" >&2; exit 1; fi'
              printf '  %q "$@" < "$buf"; rc=$?; rm -f "$buf"; exit $rc\n' "$real"
              echo 'fi' ;;
      raw)    echo 'if [[ $is_mask == 1 && $is_doc == 1 && $has_sent == 0 ]]; then'
              echo '  buf=$(mktemp); cat > "$buf"'
              echo '  if ! grep -q "<!-- kiro-" "$buf"; then rm -f "$buf"; echo "badawk: 模拟原文掩码失败" >&2; exit 1; fi'
              printf '  %q "$@" < "$buf"; rc=$?; rm -f "$buf"; exit $rc\n' "$real"
              echo 'fi' ;;
      *) echo "make_bad_awk: 未知模式 ${mode}" >&2; return 1 ;;
    esac
    printf 'exec %q "$@"\n' "$real"
  } > "$dir/awk"
  chmod +x "$dir/awk"
}
