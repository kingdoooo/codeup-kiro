#!/usr/bin/env bash
# scripts/lib/git-retry.sh（issue 03）：Codeup 的 git HTTP 限流（429）有界重试，别的失败原样立刻返回。
# 重试判定对的是**真 git 的报错**：本地起一个一律回 429 的 HTTP 服务，让真 git 去撞它——判定写错了（比如只认
# 某个版本的措辞）在这里就会红，而不是在沙箱里第一次被限流时才发现。退避用 shell 函数覆盖 `sleep`（函数优先于
# PATH），生产代码里不放测试旋钮。
set -uo pipefail
cd "$(dirname "$0")"
. ./helpers.sh
. ../scripts/lib/git-retry.sh

SLEEPS=""
sleep() { SLEEPS="${SLEEPS}${SLEEPS:+ }$1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; [[ -n "${srv_pid:-}" ]] && kill "$srv_pid" 2>/dev/null' EXIT

# 替身命令：前 N 次（FAIL_TIMES）把 FAIL_TEXT 打到 stderr 并以 FAIL_RC 失败，之后成功并打一行 stdout
fake() {
  local n; n=$(( $(cat "$tmp/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$tmp/count"
  if (( n <= FAIL_TIMES )); then echo "partial-stdout-$n"; printf '%s\n' "$FAIL_TEXT" >&2; return "$FAIL_RC"; fi
  printf 'deadbeef\trefs/heads/feat\n'
}
reset() { SLEEPS=""; rm -f "$tmp/count"; }

# ① 限流两次后成功：退避 10、20 秒；stdout 只有成功那一次的（失败那几次的半截输出不混进来，G3）；rc 0
reset; FAIL_TIMES=2 FAIL_RC=128 FAIL_TEXT="fatal: unable to access 'https://codeup.aliyun.com/o/x.git/': The requested URL returned error: 429"
out=$(retry_git_429 fake 2>"$tmp/err"); rc=$?
assert_eq "$rc" "0" "① 限流两次后成功：rc 0"
assert_eq "$out" $'deadbeef\trefs/heads/feat' "① stdout 只有成功那一次的输出（G3）"
assert_eq "$(grep -c '^git: Codeup 限流（HTTP 429），' "$tmp/err")" "2" "① 每次重试前打一行提示"
assert_contains "$(cat "$tmp/err")" "10 秒后重试" "① 第一次退避 10 秒"
assert_contains "$(cat "$tmp/err")" "20 秒后重试" "① 第二次退避 20 秒"
assert_eq "$(cat "$tmp/count")" "3" "① 一共跑了 3 次"

# ② 在当前 shell 里调用（不经命令替换）才能数到 sleep：退避序列 10 20 40，最多 4 次尝试，rc 是最后一次的（G2）
reset; FAIL_TIMES=99 FAIL_RC=128 FAIL_TEXT="error: RPC failed; HTTP 429 curl 22 The requested URL returned error: 429"   # smart HTTP 的 RPC 失败
retry_git_429 fake >/dev/null 2>"$tmp/err"; rc=$?
assert_eq "$SLEEPS" "10 20 40" "② 退避 10、20、40 秒（G2：最多等 70 秒）"
assert_eq "$(cat "$tmp/count")" "4" "② 最多 4 次尝试"
assert_eq "$rc" "128" "② 一直被限流时返回最后一次的退出码"
assert_contains "$(cat "$tmp/err")" "HTTP 429 curl 22" "② 最后一次的 stderr 原样透出"

# ③ 非 429 的失败：一次都不重试，退出码与 stderr 原样（G1）
reset; FAIL_TIMES=99 FAIL_RC=128 FAIL_TEXT="fatal: couldn't find remote ref refs/heads/no-such"
retry_git_429 fake >/dev/null 2>"$tmp/err"; rc=$?
assert_eq "$SLEEPS" "" "③ 非 429 不退避"
assert_eq "$(cat "$tmp/count")" "1" "③ 非 429 只跑一次"
assert_eq "$rc" "128" "③ 非 429 的退出码原样"
assert_eq "$(cat "$tmp/err")" "fatal: couldn't find remote ref refs/heads/no-such" "③ 非 429 的 stderr 逐字原样（G1）"
reset; FAIL_TIMES=99 FAIL_RC=7 FAIL_TEXT="fatal: Authentication failed for 'https://codeup.aliyun.com/o/x.git/'"
retry_git_429 fake >/dev/null 2>/dev/null; rc=$?
assert_eq "$rc:$SLEEPS" "7:" "③ 鉴权失败不重试、退出码原样"

# ④ Codeup 自己的中文提示（沙箱实见：`remote: 请求过于频繁，请稍后重试！`）也认
reset; FAIL_TIMES=1 FAIL_RC=128 FAIL_TEXT="remote: 请求过于频繁，请稍后重试！"
retry_git_429 fake >/dev/null 2>/dev/null; rc=$?
assert_eq "$rc:$SLEEPS" "0:10" "④ 认 Codeup 的中文限流提示"

# ⑤ 首次成功：不退避、stdout 原样
reset; FAIL_TIMES=0 FAIL_RC=1 FAIL_TEXT=""
assert_eq "$(retry_git_429 fake)" $'deadbeef\trefs/heads/feat' "⑤ 首次成功时 stdout 原样"
assert_eq "$SLEEPS" "" "⑤ 首次成功不退避"

# ⑥ 真 git 撞真 429：本地 HTTP 服务一律回 429（带 Codeup 那句正文与 Retry-After）。判定必须认得真 git 的报错。
if command -v git >/dev/null && command -v python3 >/dev/null; then
  python3 - "$tmp/port" <<'PY' &
import sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def _429(self):
        body = "请求过于频繁，请稍后重试！".encode()
        self.send_response(429); self.send_header("Retry-After", "1")
        self.send_header("Content-Type", "text/plain; charset=utf-8"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = _429
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1])); s.serve_forever()
PY
  srv_pid=$!
  for _ in $(seq 1 50); do [[ -s "$tmp/port" ]] && break; /bin/sleep 0.1; done
  url="http://127.0.0.1:$(cat "$tmp/port")/o/x.git"
  gitq() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 GIT_HTTP_MAX_RETRIES=0 git "$@"; }
  real_err=$(gitq ls-remote "$url" 2>&1 >/dev/null); real_rc=$?
  assert_nonzero "$real_rc" "⑥ 前提：真 git 撞 429 失败"
  git_is_429 "$real_err"; assert_eq "$?" "0" "⑥ 真 git（$(git --version)）的 429 报错被认出：${real_err:0:120}"
  SLEEPS=""; retry_git_429 gitq ls-remote "$url" >/dev/null 2>"$tmp/err"; rc=$?
  assert_eq "$SLEEPS" "10 20 40" "⑥ 真 git 的 429 按退避序列重试"
  assert_nonzero "$rc" "⑥ 一直 429 时最后仍失败"
  # 真 git 的非 429 失败（仓库不存在）：不重试
  SLEEPS=""; retry_git_429 gitq ls-remote "$tmp/no-such-repo" >/dev/null 2>"$tmp/err"; rc=$?
  assert_eq "$SLEEPS" "" "⑥ 真 git 的非 429 失败不重试"
  assert_nonzero "$rc" "⑥ 非 429 失败的退出码非零"
  git_is_429 "$(cat "$tmp/err")"; assert_nonzero "$?" "⑥ 真 git 的「仓库不存在」不被当成 429"
else
  echo "SKIP: 无 git 或 python3，跳过 ⑥ 真 git 撞 429" >&2
fi

# ⑦ 调用点（静态，只看非注释行）：引擎第 4 步的目标分支 fetch、--unshallow、内联解析的加深，以及入口脚本的
#   clone、补取源分支、ls-remote 都经重试；入口脚本不再在 clone 之后单独取一次目标分支（G4）。
code_of() { LC_ALL=C grep -vE '^[[:space:]]*#' "$1"; }
eng=$(code_of ../scripts/kiro-review.sh)
assert_contains "$eng" 'retry_git_429 git fetch -q origin "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}"' \
  "⑦ 引擎目标分支 fetch 经重试"
assert_contains "$eng" 'retry_git_429 git fetch -q --unshallow origin' "⑦ 引擎 --unshallow 经重试"
assert_contains "$eng" 'retry_git_429 git fetch --unshallow --quiet' "⑦ 内联解析的加深经重试"
assert_contains "$eng" 'retry_git_429 git fetch --deepen 100 --quiet' "⑦ 内联解析的 --deepen 经重试"
# 引擎与 scripts/lib 里所有 git 网络子命令（含 `$(git …`、`git -C 目录 …` 的写法）都经重试；git-retry.sh 自己除外
net_re='git( -C [^ ]+)? (fetch|clone|ls-remote|pull|push)( |$)'
bare=$(for f in ../scripts/*.sh ../scripts/lib/*.sh; do [[ "$f" == */git-retry.sh ]] && continue
         code_of "$f" | LC_ALL=C grep -E "$net_re" | LC_ALL=C grep -vE 'retry_git_429 git '; done)
assert_eq "$bare" "" "⑦ scripts/ 里没有漏掉的裸网络 git 调用"
# 加载顺序：source 那一行必须排在第一次用它之前（只看代码行）。挪到后面的话生产里第一次调用就是 command not found
first_line_of() { LC_ALL=C grep -nE "$2" "$1" | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1; }
e_src=$(first_line_of ../scripts/kiro-review.sh '^source "\$\{SCRIPT_DIR\}/lib/git-retry.sh"$')
e_use=$(first_line_of ../scripts/kiro-review.sh 'retry_git_429 ')
assert_eq "$([ -n "$e_src" ] && [ -n "$e_use" ] && [ "$e_src" -lt "$e_use" ] && echo yes)" "yes" "⑦ 引擎先 source 再用（${e_src} < ${e_use}）"
assert_contains "$eng" 'source "${SCRIPT_DIR}/lib/git-retry.sh"' "⑦ 引擎加载了 git-retry.sh"
ent=$(code_of ../aws/executor/entrypoint.sh)
assert_contains "$ent" 'retry_git_429 /usr/bin/git clone --no-tags' "⑦ 入口脚本 clone 经重试"
assert_contains "$ent" 'retry_git_429 /usr/bin/git -C "$WORKROOT/business" fetch --no-tags origin \' "⑦ 入口脚本补取源分支经重试"
# Phase 2b：「核对最新提交」随租约函数抽到了 lib/lease.sh（扫描任务共用；ls-remote 的目录可由扫描任务换成 LEASE_GIT_DIR）
lease=$(code_of ../aws/executor/lib/lease.sh)
assert_contains "$lease" 'retry_git_429 /usr/bin/timeout 30 /usr/bin/git -C "${LEASE_GIT_DIR:-$WORKROOT/business}" ls-remote origin' "⑦ 租约库的 ls-remote 经重试"
# AWS 档位其余的 bash 文件（执行器的库、扫描任务入口、扫描员）同样不得有裸的网络 git 调用；还没建出来的文件跳过
for f in ../aws/executor/lib/*.sh ../aws/executor/scan-entrypoint.sh ../aws/reviewers/*.sh ../aws/reviewers/lib/*.sh; do
  [[ -e "$f" ]] || continue
  assert_eq "$(code_of "$f" | LC_ALL=C grep -E "/usr/bin/$net_re" \
                | LC_ALL=C grep -vE 'retry_git_429 (/usr/bin/timeout [0-9]+ )?/usr/bin/git ' || true)" "" \
    "⑦ ${f#../} 里没有漏掉的裸网络 git 调用"
done
assert_not_contains "$ent" 'refs/remotes/origin/${MR_TARGET_BRANCH}' "⑦ 入口脚本不再在 clone 之后取目标分支（G4）"
assert_eq "$(printf '%s\n' "$ent" | LC_ALL=C grep -E "/usr/bin/$net_re" \
              | LC_ALL=C grep -vE 'retry_git_429 (/usr/bin/timeout [0-9]+ )?/usr/bin/git ' || true)" "" \
  "⑦ 入口脚本里没有漏掉的裸网络 git 调用"
assert_contains "$ent" 'source "$PKG/scripts/lib/git-retry.sh"' "⑦ 入口脚本加载了 git-retry.sh"
a_src=$(first_line_of ../aws/executor/entrypoint.sh '^source "\$PKG/scripts/lib/git-retry.sh"$')
a_use=$(first_line_of ../aws/executor/entrypoint.sh 'retry_git_429 ')
assert_eq "$([ -n "$a_src" ] && [ -n "$a_use" ] && [ "$a_src" -lt "$a_use" ] && echo yes)" "yes" \
  "⑦ 入口脚本先 source 再用（${a_src} < ${a_use}；复审把 source 挪到 clone 之后，两套测试都没红——生产里就是每次 clone 失败 91）"

# ⑨ mktemp 失败：退化成不重试地跑一次，退出码与 stdout 原样（绝不因为拿不到临时文件就不执行）
reset; FAIL_TIMES=0 FAIL_RC=1 FAIL_TEXT=""
mktemp() { return 1; }
assert_eq "$(retry_git_429 fake)" $'deadbeef\trefs/heads/feat' "⑨ mktemp 失败时命令照样跑、stdout 原样"
reset; FAIL_TIMES=99 FAIL_RC=5 FAIL_TEXT="fatal: x"
retry_git_429 fake >/dev/null 2>/dev/null; rc=$?
assert_eq "$rc:$(cat "$tmp/count")" "5:1" "⑨ mktemp 失败时只跑一次、退出码原样"
unset -f mktemp

# ⑧ 运维照着日志里那句提示去手册里找：两个档位的排错表都逐字写出了它（取自库里的 echo，不另抄一份）
notice=$(LC_ALL=C grep -oE 'echo "git: Codeup 限流（HTTP 429），' ../scripts/lib/git-retry.sh | sed 's/^echo "//')
assert_eq "$notice" "git: Codeup 限流（HTTP 429），" "⑧ 从库里取到了提示的固定部分"
for guide in ../aws/setup-guide.md ../pipeline/setup-guide.md; do
  assert_eq "$(LC_ALL=C grep -c "^| 日志里有 \`${notice}N 秒后重试\`" "$guide" | tr -d ' ')" "1" "⑧ ${guide#../} 的排错表有 429 那一行"
done

report
