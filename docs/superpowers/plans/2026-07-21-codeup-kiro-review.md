# Codeup MR 自动 Kiro 评审集成包 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个可复用集成包：Codeup MR 新建/更新时，云效 Flow 流水线自动调用 Kiro CLI headless 完成代码评审，并将 Markdown 报告以全局评论回写到 MR 页面。

**Architecture:** 纯 Bash 脚本方案（spec 方案 A）。`kiro-review.sh` 编排全流程，`lib/codeup-api.sh` 封装中心站 OpenAPI，`lib/diff-compress.sh` 实现 PR-Agent 式 diff 压缩。测试用纯 Bash 断言 + DRY_RUN + mock kiro-cli，全程无网络依赖。

**Tech Stack:** Bash（兼容 3.2）、curl、jq、git、Kiro CLI headless、云效 Codeup OpenAPI（中心站）。

**Spec:** `docs/superpowers/specs/2026-07-21-codeup-kiro-review-design.md`

## Global Constraints

- 所有面向用户的文本（脚本日志、评论、文档）用中文；代码注释用中文。
- Bash 兼容 3.2（macOS 本地测试）：不用关联数组、不用 `${var,,}` 等 bash4 特性；脚本头 `#!/usr/bin/env bash` + `set -euo pipefail`。
- 外部依赖仅 git / curl / jq；脚本启动时检测缺失即报错退出。
- 密钥（`KIRO_API_KEY`、`YUNXIAO_TOKEN`）绝不 echo、绝不落盘；不开 `set -x`。
- Kiro 工具权限仅 `--trust-tools=read,grep`；CI 中设 `KIRO_LOG_NO_COLOR=1`。
- 默认值：`DIFF_SIZE_LIMIT=307200`（300KB）、`KIRO_TIMEOUT=900`（秒），均可环境变量覆盖。
- 中心站 OpenAPI：base `https://openapi-rdc.aliyuncs.com`，认证头 `x-yunxiao-token`，路径含 `organizationId`。
- 评审失败不设合并卡点：回写「评审未完成」评论 + 非零退出即可。
- 所有网络交互支持 `DRY_RUN=1`（只打印不发送）。

## 环境变量契约（所有任务共用）

| 变量 | 必填 | 说明 |
|---|---|---|
| `KIRO_API_KEY` | 是 | Kiro API Key |
| `YUNXIAO_TOKEN` | 是 | 云效个人访问令牌（代码只读 + MR 读写） |
| `YUNXIAO_ORG_ID` | 是 | 云效组织 ID（中心站） |
| `CODEUP_REPO_ID` | 是 | Codeup 代码库数字 ID |
| `MR_LOCAL_ID` | 否 | MR 编号；未设置时按源分支 OpenAPI 反查 |
| `MR_TARGET_BRANCH` | 否 | 目标分支；未设置时随 MR 反查获得 |
| `CI_COMMIT_REF_NAME` | 否 | Flow 内置：运行分支（MR 触发=源分支）；缺省用 `git rev-parse --abbrev-ref HEAD` |
| `DIFF_SIZE_LIMIT` | 否 | diff 直传阈值字节数，默认 307200 |
| `KIRO_TIMEOUT` | 否 | Kiro 超时秒数，默认 900 |
| `KIRO_INSTALL_URL` | 否 | kiro-cli 安装脚本 URL（默认值在 Task 3 验证后固化） |
| `DRY_RUN` | 否 | `1`=不实际发 OpenAPI 请求 |
| `CODEUP_API_BASE` | 否 | 默认 `https://openapi-rdc.aliyuncs.com` |

---

### Task 1: 测试基座 + lib/codeup-api.sh

**Files:**
- Create: `tests/helpers.sh`
- Create: `tests/run-tests.sh`
- Create: `tests/fixtures/mr-list-result.json`
- Create: `tests/fixtures/mr-list-array.json`
- Create: `tests/test-codeup-api.sh`
- Create: `scripts/lib/codeup-api.sh`

**Interfaces:**
- Produces（后续任务依赖的精确签名）:
  - `codeup_parse_mr <source_branch>`：stdin 读 MR 列表 JSON，stdout 输出 `localId<TAB>targetBranch`（取 updateTime 最新一条；无匹配输出空）
  - `codeup_find_mr <source_branch>`：调 ListChangeRequests 后经 `codeup_parse_mr` 输出同上格式；失败返回非 0
  - `codeup_post_comment <local_id> <markdown_file>`：发 GLOBAL_COMMENT，重试 2 次（共 3 attempts），成功返回 0
  - 全部函数在 `DRY_RUN=1` 时打印 `DRY_RUN <METHOD> <URL>` 与 `DRY_RUN body: ...` 到 stderr，stdout 返回 `{"dry_run": true}`

- [ ] **Step 1: 核对 ListChangeRequests 接口文档**

用 tavily_extract 或搜索确认接口路径与查询参数（关键词：`云效 ListChangeRequests 查询合并请求列表 OpenAPI`，帮助中心 https://help.aliyun.com/zh/yunxiao/developer-reference/ 下）。需确认三点：① 列表路径是否为 `GET /oapi/v1/codeup/organizations/{organizationId}/changeRequests`；② 按仓库过滤的参数名（`projectIds` 或类似）；③ 状态过滤参数与取值（如 `state=opened`）。若与下文代码不符，以文档为准修改 Step 4 中 `codeup_find_mr` 的 URL 组装，并同步修改 fixture 字段名。

- [ ] **Step 2: 写测试基座与 fixtures**

`tests/helpers.sh`：

```bash
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

assert_rc() {  # 实际退出码 期望退出码 说明
  assert_eq "$1" "$2" "$3"
}

report() {
  echo "OK: ${TESTS_PASSED} 个断言通过（$0）"
}
```

`tests/run-tests.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for t in test-*.sh; do
  echo "=== ${t} ==="
  bash "$t"
done
echo "=== 全部测试通过 ==="
```

`tests/fixtures/mr-list-result.json`（对象包裹形态；字段名以 Step 1 核对结果为准）：

```json
{
  "result": [
    {"localId": 3, "sourceBranch": "feature/x", "targetBranch": "master", "status": "UNDER_REVIEW", "updateTime": "2026-07-20T10:00:00Z"},
    {"localId": 7, "sourceBranch": "feature/x", "targetBranch": "master", "status": "UNDER_REVIEW", "updateTime": "2026-07-21T10:00:00Z"},
    {"localId": 5, "sourceBranch": "feature/other", "targetBranch": "master", "status": "UNDER_REVIEW", "updateTime": "2026-07-21T09:00:00Z"}
  ]
}
```

`tests/fixtures/mr-list-array.json`（裸数组形态）：

```json
[
  {"localId": 9, "sourceBranch": "feature/y", "targetBranch": "develop", "status": "UNDER_REVIEW", "updateTime": "2026-07-21T08:00:00Z"}
]
```

- [ ] **Step 3: 写失败测试 tests/test-codeup-api.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
source ../scripts/lib/codeup-api.sh

export YUNXIAO_TOKEN="test-token"
export YUNXIAO_ORG_ID="org123"
export CODEUP_REPO_ID="456"

# --- codeup_parse_mr ---
out=$(codeup_parse_mr "feature/x" < fixtures/mr-list-result.json)
assert_eq "$out" "$(printf '7\tmaster')" "parse: 命中且取最新一条"

out=$(codeup_parse_mr "feature/y" < fixtures/mr-list-array.json)
assert_eq "$out" "$(printf '9\tdevelop')" "parse: 裸数组形态"

out=$(codeup_parse_mr "feature/none" < fixtures/mr-list-result.json)
assert_eq "$out" "" "parse: 无匹配输出空"

# --- DRY_RUN 请求组装 ---
export DRY_RUN=1

err=$(codeup_find_mr "feature/x" 2>&1 >/dev/null || true)
assert_contains "$err" "organizations/org123/changeRequests" "find_mr: URL 含组织与资源路径"

md=$(mktemp); echo "## 评审结果" > "$md"
rc=0
err=$(codeup_post_comment 7 "$md" 2>&1 >/dev/null) || rc=$?
assert_rc "$rc" 0 "post_comment: DRY_RUN 成功"
assert_contains "$err" "changeRequests/7/comments" "post_comment: URL 正确"
assert_contains "$err" "GLOBAL_COMMENT" "post_comment: body 含评论类型"
rm -f "$md"

report
```

- [ ] **Step 4: 运行测试验证失败**

Run: `bash tests/test-codeup-api.sh`
Expected: FAIL（`codeup-api.sh` 不存在，source 报错）

- [ ] **Step 5: 实现 scripts/lib/codeup-api.sh**

```bash
#!/usr/bin/env bash
# Codeup OpenAPI（中心站）薄封装。
# 依赖环境变量：YUNXIAO_TOKEN, YUNXIAO_ORG_ID, CODEUP_REPO_ID
# DRY_RUN=1 时只打印请求到 stderr，不实际发送。

CODEUP_API_BASE="${CODEUP_API_BASE:-https://openapi-rdc.aliyuncs.com}"

_codeup_curl() {  # method path [body]
  local method="$1" path="$2" body="${3:-}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "DRY_RUN ${method} ${CODEUP_API_BASE}${path}" >&2
    [[ -n "$body" ]] && echo "DRY_RUN body: ${body}" >&2
    echo '{"dry_run": true}'
    return 0
  fi
  curl -sS --fail-with-body -X "$method" \
    -H "Content-Type: application/json" \
    -H "x-yunxiao-token: ${YUNXIAO_TOKEN}" \
    ${body:+--data "$body"} \
    "${CODEUP_API_BASE}${path}"
}

# stdin: ListChangeRequests 响应 JSON；$1=源分支
# stdout: "localId<TAB>targetBranch"（updateTime 最新一条；无匹配输出空）
codeup_parse_mr() {
  jq -r --arg src "$1" '
    (if type == "object" then (.result // []) else . end)
    | map(select(.sourceBranch == $src))
    | sort_by(.updateTime) | last
    | if . == null then empty else "\(.localId)\t\(.targetBranch)" end'
}

# $1=源分支；stdout 同 codeup_parse_mr。查询参数名以官方文档核对结果为准。
codeup_find_mr() {
  local resp
  resp=$(_codeup_curl GET \
    "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/changeRequests?projectIds=${CODEUP_REPO_ID}&state=opened&page=1&perPage=50") \
    || return 1
  printf '%s' "$resp" | codeup_parse_mr "$1"
}

# $1=localId $2=Markdown 文件路径。重试 2 次（共 3 attempts）。
codeup_post_comment() {
  local local_id="$1" markdown_file="$2"
  local body attempt resp
  body=$(jq -n --rawfile content "$markdown_file" \
    '{comment_type: "GLOBAL_COMMENT", content: $content, draft: false}')
  for attempt in 1 2 3; do
    if resp=$(_codeup_curl POST \
      "/oapi/v1/codeup/organizations/${YUNXIAO_ORG_ID}/repositories/${CODEUP_REPO_ID}/changeRequests/${local_id}/comments" \
      "$body") \
      && printf '%s' "$resp" | jq -e '(.dry_run // false) or ((.commentBizId // .id // null) != null)' >/dev/null; then
      return 0
    fi
    echo "codeup_post_comment: 第 ${attempt} 次尝试失败" >&2
    [[ "$attempt" -lt 3 ]] && sleep $((attempt * 5))
  done
  return 1
}
```

注意：若构建机 curl 版本过旧不支持 `--fail-with-body`，降级为 `--fail`（实现时用 `curl --help all | grep -q fail-with-body` 判断或直接用 `--fail`，在日志中保留响应排查能力即可，不必过度设计）。

- [ ] **Step 6: 运行测试验证通过**

Run: `bash tests/test-codeup-api.sh`
Expected: `OK: 7 个断言通过`

- [ ] **Step 7: 提交**

```bash
git add tests/ scripts/lib/codeup-api.sh
git commit -m "feat: Codeup OpenAPI 封装（查 MR / 发评论）与测试基座"
```

---

### Task 2: lib/diff-compress.sh（PR-Agent 式压缩）

**Files:**
- Create: `scripts/lib/diff-compress.sh`
- Create: `tests/fixtures/small.diff`
- Create: `tests/fixtures/mixed.diff`
- Create: `tests/test-diff-compress.sh`

**Interfaces:**
- Consumes: 无（独立库）
- Produces:
  - `build_review_input <diff_file> <out_diff_file> <out_omitted_file>`：
    - diff ≤ `DIFF_SIZE_LIMIT`：全量拷入 `out_diff_file`，`out_omitted_file` 为空，返回 0
    - 超限：按优先级（代码 0 > 配置 1 > 文档 2；纯删除 3 永不直传）装填至预算，未装入文件写入 `out_omitted_file`（格式 `- <path> (+<n> / -<m>)` 每行一个），返回 10
  - `_diff_priority <path> <chunk_file>`：输出 0/1/2/3（内部函数，测试可直接调用）

- [ ] **Step 1: 写 fixtures**

`tests/fixtures/small.diff`：

```
diff --git a/src/app.py b/src/app.py
index 1111111..2222222 100644
--- a/src/app.py
+++ b/src/app.py
@@ -1,3 +1,4 @@
 import os
+SECRET_KEY = "hardcoded-secret"
 def main():
     pass
```

`tests/fixtures/mixed.diff`（代码 + 文档 + 纯删除三个文件）：

```
diff --git a/src/main.go b/src/main.go
index aaaaaaa..bbbbbbb 100644
--- a/src/main.go
+++ b/src/main.go
@@ -1,5 +1,8 @@
 package main
+import "fmt"
 func main() {
+	fmt.Println("hello")
+	fmt.Println("world")
 }
diff --git a/README.md b/README.md
index ccccccc..ddddddd 100644
--- a/README.md
+++ b/README.md
@@ -1,2 +1,4 @@
 # Demo
+新增了两行说明文档内容。
+这里是第二行说明。
 结束。
diff --git a/old.txt b/old.txt
deleted file mode 100644
index eeeeeee..0000000
--- a/old.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-line1
-line2
```

- [ ] **Step 2: 写失败测试 tests/test-diff-compress.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh
source ../scripts/lib/diff-compress.sh

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- 阈值内：全量直传 ---
rc=0
build_review_input fixtures/small.diff "$tmp/out.diff" "$tmp/omitted.txt" || rc=$?
assert_rc "$rc" 0 "small: 返回 0"
assert_eq "$(cat "$tmp/out.diff")" "$(cat fixtures/small.diff)" "small: 内容原样"
assert_eq "$(wc -c < "$tmp/omitted.txt" | tr -d ' ')" "0" "small: 无省略清单"

# --- 超限：优先级压缩 ---
# 预算 300 字节：只装得下 src/main.go（代码，优先级 0）
rc=0
DIFF_SIZE_LIMIT=300 build_review_input fixtures/mixed.diff "$tmp/out2.diff" "$tmp/omitted2.txt" || rc=$?
assert_rc "$rc" 10 "mixed: 返回 10（已截断）"
assert_contains "$(cat "$tmp/out2.diff")" "src/main.go" "mixed: 代码文件直传"
omitted=$(cat "$tmp/omitted2.txt")
assert_contains "$omitted" "README.md" "mixed: 文档进省略清单"
assert_contains "$omitted" "old.txt" "mixed: 删除文件进省略清单"
case "$(cat "$tmp/out2.diff")" in
  *README.md*) echo "FAIL: 文档不应直传" >&2; exit 1 ;;
esac
TESTS_PASSED=$((TESTS_PASSED + 1))
assert_contains "$omitted" "(+" "mixed: 清单含增删行数"

# --- 优先级函数 ---
c=$(mktemp); echo "deleted file mode 100644" > "$c"
assert_eq "$(_diff_priority "any.go" "$c")" "3" "priority: 纯删除=3"
: > "$c"
assert_eq "$(_diff_priority "a.md" "$c")" "2" "priority: 文档=2"
assert_eq "$(_diff_priority "a.yaml" "$c")" "1" "priority: 配置=1"
assert_eq "$(_diff_priority "a.go" "$c")" "0" "priority: 代码=0"
rm -f "$c"

report
```

- [ ] **Step 3: 运行测试验证失败**

Run: `bash tests/test-diff-compress.sh`
Expected: FAIL（`diff-compress.sh` 不存在）

- [ ] **Step 4: 实现 scripts/lib/diff-compress.sh**

```bash
#!/usr/bin/env bash
# diff 压缩：参考 PR-Agent Compression Strategy
# (https://docs.pr-agent.ai/core-abilities/compression_strategy/)
# 简化为：代码 > 配置 > 文档 优先装填；纯删除文件只列清单；
# 未装入文件列清单（含 +/- 行数）交由 Kiro 用 read 工具自行读取。
# 已知限制：不支持路径含空格的文件（awk 按 $4 取路径）。

DIFF_SIZE_LIMIT="${DIFF_SIZE_LIMIT:-307200}"

# $1=文件路径 $2=该文件的 diff chunk 文件；输出优先级 0-3
_diff_priority() {
  local path="$1" chunk_file="$2"
  if grep -q '^deleted file mode' "$chunk_file"; then echo 3; return; fi
  case "$path" in
    *.md|*.markdown|*.txt|*.rst|*.adoc) echo 2 ;;
    *.json|*.yaml|*.yml|*.toml|*.ini|*.lock|*.xml|*.cfg) echo 1 ;;
    *) echo 0 ;;
  esac
}

# $1=输入 diff $2=输出直传 diff $3=输出省略清单
# 返回 0=未截断；10=已截断
build_review_input() {
  local diff_file="$1" out_diff="$2" out_omitted="$3"
  : > "$out_diff"; : > "$out_omitted"

  local total
  total=$(wc -c < "$diff_file")
  if [[ "$total" -le "$DIFF_SIZE_LIMIT" ]]; then
    cat "$diff_file" > "$out_diff"
    return 0
  fi

  local workdir
  workdir=$(mktemp -d)

  # 按 "diff --git" 边界把 diff 拆成每文件一个 chunk
  awk -v dir="$workdir" '
    /^diff --git / {
      n++;
      file = $4; sub(/^b\//, "", file);
      out = dir "/" sprintf("%04d", n) ".chunk";
      meta = dir "/" sprintf("%04d", n) ".path";
      print file > meta; close(meta);
    }
    n { print >> out }
  ' "$diff_file"

  # 建立 优先级\t大小\t路径\tchunk路径 索引
  local index="$workdir/index" chunk path prio size
  : > "$index"
  for chunk in "$workdir"/*.chunk; do
    path=$(cat "${chunk%.chunk}.path")
    prio=$(_diff_priority "$path" "$chunk")
    size=$(wc -c < "$chunk" | tr -d ' ')
    printf '%s\t%s\t%s\t%s\n' "$prio" "$size" "$path" "$chunk" >> "$index"
  done

  # 优先级升序、同级内小文件优先，逐个装填预算
  local used=0 added removed
  while IFS=$'\t' read -r prio size path chunk; do
    if [[ "$prio" != "3" ]] && [[ $((used + size)) -le "$DIFF_SIZE_LIMIT" ]]; then
      cat "$chunk" >> "$out_diff"
      used=$((used + size))
    else
      added=$(grep -c '^+[^+]' "$chunk" || true)
      removed=$(grep -c '^-[^-]' "$chunk" || true)
      printf -- '- %s (+%s / -%s)\n' "$path" "$added" "$removed" >> "$out_omitted"
    fi
  done < "$workdir/index.sorted"

  rm -rf "$workdir"
  return 10
}
```

注意实现细节：上面 while 循环读取的是排序后的索引，需在循环前加一行 `sort -t"$(printf '\t')" -k1,1n -k2,2n "$index" > "$workdir/index.sorted"`。

- [ ] **Step 5: 运行测试验证通过**

Run: `bash tests/test-diff-compress.sh && bash tests/run-tests.sh`
Expected: 两条命令均全部通过

- [ ] **Step 6: 提交**

```bash
git add scripts/lib/diff-compress.sh tests/fixtures/small.diff tests/fixtures/mixed.diff tests/test-diff-compress.sh
git commit -m "feat: PR-Agent 式 diff 优先级压缩（300KB 阈值可调）"
```

---

### Task 3: prompts/review-prompt.md + scripts/kiro-review.sh 主编排

**Files:**
- Create: `prompts/review-prompt.md`
- Create: `scripts/kiro-review.sh`
- Create: `tests/mockbin/kiro-cli`
- Create: `tests/test-kiro-review.sh`

**Interfaces:**
- Consumes:
  - `codeup_find_mr <source_branch>` → `localId<TAB>targetBranch`；`codeup_post_comment <local_id> <md_file>`（Task 1）
  - `build_review_input <diff> <out_diff> <out_omitted>` → rc 0/10（Task 2）
- Produces: `scripts/kiro-review.sh`（无参数，靠环境变量契约驱动；退出码 0=评审完成并回写，非 0=失败）

- [ ] **Step 1: 核实 kiro-cli 安装命令**

用 tavily_extract 抓取 https://kiro.dev/docs/cli/installation/ ，确认官方 Linux 一键安装命令（形如 `curl -fsSL <URL> | bash`）。把确认到的 URL 写入 Step 4 脚本中 `KIRO_INSTALL_URL` 的默认值。若文档给出的是分平台安装方式，取 Linux x86_64 的方式并在脚本注释中注明来源 URL 与核实日期。

- [ ] **Step 2: 写评审提示词 prompts/review-prompt.md**

```markdown
你是一位资深代码评审专家。stdin 提供了本次合并请求（MR）的变更元信息与 Git diff，请完成代码评审。

要求：

1. 用中文输出评审报告，使用 Markdown 格式。
2. 按严重级别分类问题：
   - 🔴 严重：安全漏洞（硬编码密钥、注入、越权）、逻辑错误、数据丢失风险
   - 🟡 警告：性能问题、并发隐患、错误处理缺失、资源泄漏
   - 🔵 建议：代码规范、可读性、可维护性
3. 每个问题必须引用具体的文件路径和行号，并给出简短的修复建议。
4. 当前工作目录是完整的代码仓库。你可以使用 read/grep 工具查阅任何文件获取上下文；对 diff 中上下文不足的改动，先主动读取相关文件再下结论。
5. 若输入中「未直传的变更文件清单」不为空，请用 read 工具逐个查阅这些文件的变更内容并纳入评审范围。
6. 报告末尾给出总体结论：整体质量评价 + 合并建议（可合并 / 建议修改后合并 / 不建议合并）。
7. 只输出评审报告本身：不要复述 diff，不要解释你的工作过程，不要输出与评审无关的内容。
8. 若没有发现任何问题，明确说明「未发现明显问题」并仍给出总体结论。
```

- [ ] **Step 3: 写 mock 与失败测试**

`tests/mockbin/kiro-cli`（`chmod +x`）：

```bash
#!/usr/bin/env bash
# 测试替身：记录参数与 stdin，输出固定评审报告。
# MOCK_KIRO_FAIL=1 时模拟评审失败。
[[ -n "${MOCK_ARGS_FILE:-}" ]] && printf '%s\n' "$@" > "$MOCK_ARGS_FILE"
[[ -n "${MOCK_STDIN_FILE:-}" ]] && cat > "$MOCK_STDIN_FILE" || cat > /dev/null
if [[ "${MOCK_KIRO_FAIL:-0}" == "1" ]]; then
  echo "mock: 模拟 kiro 失败" >&2
  exit 1
fi
echo "## 评审结果"
echo "🔴 严重：发现硬编码密钥 src/app.py:2，建议改用环境变量。"
echo "总体结论：建议修改后合并。"
```

`tests/test-kiro-review.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source helpers.sh

ROOT=$(cd .. && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- 搭建本地 git 环境：bare 远端 + 工作克隆 ---
git init --bare -q "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work"
cd "$tmp/work"
git config user.email t@t && git config user.name t
mkdir src && printf 'import os\ndef main():\n    pass\n' > src/app.py
git add . && git commit -qm "init" && git branch -M master && git push -q origin master
git checkout -qb feature/x
printf 'import os\nSECRET_KEY = "hardcoded-secret"\ndef main():\n    pass\n' > src/app.py
git commit -qam "add secret" && git push -q origin feature/x

# --- 公共环境 ---
export PATH="$ROOT/tests/mockbin:$PATH"
export DRY_RUN=1 KIRO_API_KEY=k YUNXIAO_TOKEN=t YUNXIAO_ORG_ID=org123 CODEUP_REPO_ID=456
export MR_LOCAL_ID=7 MR_TARGET_BRANCH=master CI_COMMIT_REF_NAME=feature/x
export MOCK_ARGS_FILE="$tmp/args" MOCK_STDIN_FILE="$tmp/stdin"

# --- 成功路径 ---
rc=0; out=$("$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_rc "$rc" 0 "成功路径退出码 0"
assert_contains "$(cat "$tmp/args")" "--no-interactive" "kiro 参数：no-interactive"
assert_contains "$(cat "$tmp/args")" "--trust-tools=read,grep" "kiro 参数：只读工具"
assert_contains "$(cat "$tmp/stdin")" "SECRET_KEY" "diff 已喂入 stdin"
assert_contains "$out" "changeRequests/7/comments" "回写到 MR 7"
assert_contains "$out" "评审结果" "评论含 kiro 输出"
assert_contains "$out" "feature/x" "评论头含源分支"

# --- 失败路径：kiro 失败 → 回写“评审未完成” + 非零退出 ---
rc=0; out=$(MOCK_KIRO_FAIL=1 "$ROOT/scripts/kiro-review.sh" 2>&1) || rc=$?
assert_eq "$([[ $rc -ne 0 ]] && echo nonzero)" "nonzero" "失败路径非零退出"
assert_contains "$out" "评审未完成" "失败路径回写说明评论"

report
```

- [ ] **Step 4: 运行测试验证失败**

Run: `bash tests/test-kiro-review.sh`
Expected: FAIL（`kiro-review.sh` 不存在）

- [ ] **Step 5: 实现 scripts/kiro-review.sh**

```bash
#!/usr/bin/env bash
# Codeup MR 自动 Kiro 评审 — 主编排脚本。
# 流程：检测依赖 → 定位 MR → 生成 diff → 压缩 → kiro headless 评审 → 回写评论。
# 环境变量契约见 README.md。退出码：0=评审完成并回写；非 0=失败（不卡合并，仅流水线标红）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/codeup-api.sh"
source "${SCRIPT_DIR}/lib/diff-compress.sh"

KIRO_TIMEOUT="${KIRO_TIMEOUT:-900}"
# 默认安装 URL 在实施 Step 1 核实后固化（来源：kiro.dev/docs/cli/installation/）
KIRO_INSTALL_URL="${KIRO_INSTALL_URL:-<Step1核实后的官方安装脚本URL>}"
PROMPT_FILE="${PROMPT_FILE:-${REPO_ROOT}/prompts/review-prompt.md}"

log() { echo "[kiro-review] $*" >&2; }
die() { log "错误：$*"; exit 1; }

# --- 0. 依赖与必填变量检查 ---
for cmd in git curl jq; do
  command -v "$cmd" >/dev/null || die "缺少依赖：$cmd（请在构建机安装）"
done
: "${KIRO_API_KEY:?缺少 KIRO_API_KEY}"
: "${YUNXIAO_TOKEN:?缺少 YUNXIAO_TOKEN}"
: "${YUNXIAO_ORG_ID:?缺少 YUNXIAO_ORG_ID}"
: "${CODEUP_REPO_ID:?缺少 CODEUP_REPO_ID}"

# --- 1. 安装/检测 kiro-cli ---
if ! command -v kiro-cli >/dev/null; then
  log "kiro-cli 不存在，尝试安装（云托管构建机场景）……"
  curl -fsSL "$KIRO_INSTALL_URL" | bash \
    || die "kiro-cli 安装失败。网络受限时请使用自建构建机预装，或配置 HTTP_PROXY/HTTPS_PROXY（见 pipeline/setup-guide.md）"
  command -v kiro-cli >/dev/null || export PATH="$HOME/.local/bin:$PATH"
  command -v kiro-cli >/dev/null || die "安装后仍找不到 kiro-cli，请检查安装日志中的 PATH 提示"
fi

# --- 2. 定位 MR（localId + 目标分支）---
SOURCE_BRANCH="${CI_COMMIT_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
if [[ -n "${MR_LOCAL_ID:-}" && -n "${MR_TARGET_BRANCH:-}" ]]; then
  LOCAL_ID="$MR_LOCAL_ID"; TARGET_BRANCH="$MR_TARGET_BRANCH"
  log "使用环境变量指定的 MR：#${LOCAL_ID}（${SOURCE_BRANCH} → ${TARGET_BRANCH}）"
else
  log "环境变量未提供 MR 信息，按源分支 ${SOURCE_BRANCH} 反查 OpenAPI……"
  mr_line=$(codeup_find_mr "$SOURCE_BRANCH") || mr_line=""
  if [[ -z "$mr_line" ]]; then
    die "无法定位 MR（源分支 ${SOURCE_BRANCH}）。请确认 MR 处于开启状态，或在流水线变量中显式配置 MR_LOCAL_ID/MR_TARGET_BRANCH"
  fi
  LOCAL_ID="${mr_line%%$(printf '\t')*}"
  TARGET_BRANCH="${mr_line##*$(printf '\t')}"
  log "反查到 MR：#${LOCAL_ID}（${SOURCE_BRANCH} → ${TARGET_BRANCH}）"
fi

# --- 3. 生成 diff（merge-base 三点比较；浅克隆自动加深）---
git fetch -q origin "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}" \
  || die "无法 fetch 目标分支 ${TARGET_BRANCH}"
if ! BASE=$(git merge-base "origin/${TARGET_BRANCH}" HEAD 2>/dev/null); then
  log "浅克隆缺少历史，尝试 --unshallow……"
  git fetch -q --unshallow origin 2>/dev/null || true
  BASE=$(git merge-base "origin/${TARGET_BRANCH}" HEAD) || die "无法计算 merge-base"
fi
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
git diff "$BASE" HEAD > "$WORK/full.diff"
if [[ ! -s "$WORK/full.diff" ]]; then
  log "diff 为空，跳过评审。"
  exit 0
fi

# --- 4. 压缩 diff 并组装评审输入 ---
truncated=0
build_review_input "$WORK/full.diff" "$WORK/review.diff" "$WORK/omitted.txt" || truncated=$?
[[ "$truncated" == "0" || "$truncated" == "10" ]] || die "diff 压缩失败（rc=$truncated）"

{
  echo "=== 变更元信息 ==="
  echo "源分支: ${SOURCE_BRANCH}"
  echo "目标分支: ${TARGET_BRANCH}"
  echo "Commit: $(git rev-parse HEAD)"
  if [[ "$truncated" == "10" ]]; then
    echo ""
    echo "=== 未直传的变更文件清单（请用 read 工具逐个查阅其变更）==="
    cat "$WORK/omitted.txt"
  fi
  echo ""
  echo "=== DIFF ==="
  cat "$WORK/review.diff"
} > "$WORK/input.txt"

# --- 5. 执行 Kiro headless 评审 ---
TIMEOUT_CMD=()
command -v timeout >/dev/null && TIMEOUT_CMD=(timeout "$KIRO_TIMEOUT")
log "开始 Kiro 评审（超时 ${KIRO_TIMEOUT}s）……"
kiro_rc=0
KIRO_LOG_NO_COLOR=1 "${TIMEOUT_CMD[@]}" kiro-cli chat --no-interactive \
  --trust-tools=read,grep \
  "$(cat "$PROMPT_FILE")" \
  < "$WORK/input.txt" > "$WORK/review-output.md" 2> "$WORK/kiro-stderr.log" || kiro_rc=$?

# --- 6. 组装评论并回写 ---
SHORT_SHA=$(git rev-parse --short HEAD)
DIFF_NOTE="完整直传"
[[ "$truncated" == "10" ]] && DIFF_NOTE="超出阈值（${DIFF_SIZE_LIMIT}B）已按优先级截断，其余文件由 Kiro 自主读取"

write_header() {  # $1=状态行
  {
    echo "## 🤖 Kiro 自动代码评审"
    echo ""
    echo "| 项 | 值 |"
    echo "|---|---|"
    echo "| Commit | \`${SHORT_SHA}\` |"
    echo "| 分支 | \`${SOURCE_BRANCH}\` → \`${TARGET_BRANCH}\` |"
    echo "| 时间 | $(date '+%Y-%m-%d %H:%M:%S') |"
    echo "| diff | ${DIFF_NOTE} |"
    [[ -n "$1" ]] && echo "| 状态 | $1 |"
    echo ""
    echo "---"
    echo ""
  } > "$WORK/comment.md"
}

if [[ "$kiro_rc" -ne 0 ]]; then
  log "Kiro 评审失败（rc=${kiro_rc}），stderr 摘要："
  tail -20 "$WORK/kiro-stderr.log" >&2 || true
  write_header "⚠️ 评审未完成（kiro-cli 退出码 ${kiro_rc}，可能为超时或服务异常），请查看流水线日志或重跑流水线"
  codeup_post_comment "$LOCAL_ID" "$WORK/comment.md" \
    || log "回写失败评论也未成功，仅保留日志"
  exit 1
fi

write_header ""
cat "$WORK/review-output.md" >> "$WORK/comment.md"
if codeup_post_comment "$LOCAL_ID" "$WORK/comment.md"; then
  log "评审完成，已回写 MR #${LOCAL_ID}"
else
  log "OpenAPI 回写失败（已重试）。评审结果如下："
  cat "$WORK/comment.md" >&2
  exit 1
fi
```

实现注意：`${mr_line%%$(printf '\t')*}` 的 TAB 切分写法若在 bash 3.2 上有问题，改用 `LOCAL_ID=$(printf '%s' "$mr_line" | cut -f1)`、`TARGET_BRANCH=$(printf '%s' "$mr_line" | cut -f2)`（更稳妥，建议直接用 cut）。

- [ ] **Step 6: 运行测试验证通过**

Run: `chmod +x scripts/kiro-review.sh tests/mockbin/kiro-cli && bash tests/test-kiro-review.sh`
Expected: `OK: 9 个断言通过`

- [ ] **Step 7: 全量回归**

Run: `bash tests/run-tests.sh`
Expected: 三个测试文件全部通过

- [ ] **Step 8: 提交**

```bash
git add prompts/review-prompt.md scripts/kiro-review.sh tests/mockbin/ tests/test-kiro-review.sh
git commit -m "feat: kiro-review 主编排脚本与评审提示词（含失败回写路径）"
```

---

### Task 4: pipeline/flow-pipeline.yaml + pipeline/setup-guide.md

**Files:**
- Create: `pipeline/flow-pipeline.yaml`
- Create: `pipeline/setup-guide.md`

**Interfaces:**
- Consumes: `scripts/kiro-review.sh` 的环境变量契约（见 Global Constraints 后的表格）
- Produces: 客户可照做的配置文档；无代码接口

- [ ] **Step 1: 写 pipeline/flow-pipeline.yaml**

```yaml
# 云效 Flow 流水线参考配置 — Kiro MR 自动评审
#
# 注意：
# 1. 本文件是 YAML 结构参考。代码源触发（webhook）无法完全在 YAML 中表达，
#    必须在流水线编辑页 UI 完成：编辑代码源 → 开启代码源触发 →
#    勾选「合并请求新建/更新」事件（详见 setup-guide.md 第 4 节）。
# 2. 变量 KIRO_API_KEY / YUNXIAO_TOKEN 必须在 UI「变量和缓存」中配置为私密变量，
#    不要写入本文件。
sources:
  kiro_review_repo:
    type: codeup
    name: 业务代码库
    # 替换为实际代码库，如 https://codeup.aliyun.com/<org>/<repo>.git
    endpoint: <你的代码库地址>
    branch: master   # 默认分支；MR 触发时 Flow 自动切换为源分支

stages:
  review:
    name: "代码评审"
    jobs:
      kiro_review:
        name: "Kiro 自动评审"
        steps:
          checkout:
            step: Checkout
            name: "获取代码"
            with:
              source: kiro_review_repo
          review:
            step: Command
            name: "运行 Kiro 评审"
            with:
              run: |
                # 集成包与业务代码同库时直接执行；
                # 若集成包独立存放，先 git clone 集成包仓库再执行。
                bash scripts/kiro-review.sh

# UI 中需配置的变量（变量和缓存 → 字符变量）：
#   KIRO_API_KEY     （私密）Kiro API Key
#   YUNXIAO_TOKEN    （私密）云效个人访问令牌（代码只读 + MR 读写）
#   YUNXIAO_ORG_ID   云效组织 ID
#   CODEUP_REPO_ID   Codeup 代码库数字 ID
#   DIFF_SIZE_LIMIT  可选，默认 307200（300KB）
#   KIRO_TIMEOUT     可选，默认 900（秒）
```

- [ ] **Step 2: 写 pipeline/setup-guide.md**

文档必须包含以下 8 节，每节为客户可照做的操作步骤（含控制台入口路径），无 TBD：

```markdown
# Codeup + Kiro 自动评审 配置指南

## 1. 前提条件
- Kiro 订阅：Pro / Pro+ / Pro Max / Power（API Key 仅这些档位可生成）。
  组织订阅需管理员先在 Kiro 管理后台开启 API Key 生成权限。
- 生成 Kiro API Key：登录 kiro.dev → 账户设置 → API Keys → 创建（参考
  https://kiro.dev/docs/cli/headless/ 的 Generate an API key 章节）。
- 云效个人访问令牌：云效控制台右上角头像 → 个人设置 → 个人访问令牌 → 新建，
  勾选权限：代码管理（只读）+ 合并请求（读写）。
- 组织 ID：云效「组织管理后台 → 基本信息」页获取（中心站必需）。
- 代码库数字 ID：进入 Codeup 目标代码库 → 库设置 → 基本信息（或从库 URL 获取）。

## 2. 导入集成包
两种方式（任选）：
- 方式 A（推荐）：将本仓库的 scripts/ 与 prompts/ 目录拷贝进业务代码库根目录；
- 方式 B：保持集成包独立仓库，流水线中先 clone 集成包再执行（需为流水线配置
  集成包仓库的访问凭证）。

## 3. 创建流水线
1. Flow 控制台 → 新建流水线 → 选择「空模板」。
2. 添加代码源：选择云效 Codeup，选中业务代码库。
3. 添加任务：空任务 → 添加步骤 →「获取代码」→ 再添加「执行命令」步骤，
   命令填 `bash scripts/kiro-review.sh`。
4. 变量和缓存：按 flow-pipeline.yaml 尾部注释配置 6 个变量
   （KIRO_API_KEY、YUNXIAO_TOKEN 必须勾选「私密模式」）。

## 4. 开启 MR 触发
1. 编辑流水线 → 编辑代码源 → 开启「代码源触发」。
2. 触发事件勾选：「合并请求新建/更新」（不要勾「代码提交」，避免每次 push 都触发）。
3. 可选：配置分支过滤（如目标分支正则 `master|release/.*`）。
4. 保存后到 Codeup 代码库 → 设置 → Webhooks 确认 Flow 已自动注册 webhook；
   若无，按本指南第 8 节排查（服务连接权限问题需手动配置）。

## 5. 首次运行：环境变量探测（重要）
Flow 文档未明确 MR 编号的内置环境变量，首次接入时需实测确认：
1. 临时在「执行命令」步骤的命令最前面加一行：`env | sort`。
2. 提交一个测试 MR 触发流水线，在运行日志中搜索 merge / MR / change 等关键词。
3. 若发现 MR 编号/目标分支变量（社区项目 yunxiao-LLM-reviewer 表明存在此类变量），
   在「变量和缓存」中把它们映射为 MR_LOCAL_ID / MR_TARGET_BRANCH
   （值填 `${实际变量名}`），可省去 OpenAPI 反查。
4. 若未发现：无需任何配置，脚本会自动按源分支反查 OpenAPI 定位 MR。
5. 确认后删除 `env | sort` 临时行（env 输出包含私密变量值，勿长期保留）。

## 6. 连通性验证（云托管构建机必做）
kiro-cli 需访问境外服务端。先建一条最小验证流水线，命令：
    curl -fsSL <KIRO_INSTALL_URL> | bash
    export PATH="$HOME/.local/bin:$PATH"
    KIRO_LOG_NO_COLOR=1 kiro-cli chat --no-interactive "回复 ok 两个字母即可"
成功输出 ok → 云托管构建机可用；安装或调用超时 → 走第 7 节自建构建机。

## 7. 自建构建机（网络受限场景）
1. 准备 ECS/物理机，按 Flow 文档接入为自有构建集群。
2. 预装：git、curl、jq、kiro-cli（安装后 `kiro-cli --version` 验证）。
3. 如需代理：在流水线变量中配置 HTTP_PROXY / HTTPS_PROXY / NO_PROXY
   （NO_PROXY 需包含 openapi-rdc.aliyuncs.com 与内网地址）。
4. 流水线任务指定运行在该构建集群。

## 8. 故障排查
| 现象 | 排查 |
|---|---|
| MR 提交后流水线未触发 | Codeup 库 Webhooks 页无 Flow 条目 → 服务连接无自动配置权限，需在 Codeup 库设置中手动添加流水线 webhook；确认触发事件勾选了「合并请求新建/更新」 |
| kiro-cli 安装失败 | 构建机网络不通 → 第 6/7 节 |
| 报错「缺少 KIRO_API_KEY」等 | 流水线变量未配置或名称拼写错误 |
| 报错「无法定位 MR」 | MR 已关闭/已合并；或按第 5 节显式配置 MR_LOCAL_ID |
| OpenAPI 401/403 | 令牌过期或权限不足（需代码只读 + MR 读写）；确认 YUNXIAO_ORG_ID 正确 |
| 评论未出现但流水线绿 | 不可能（回写失败流水线必红）；检查是否看错 MR |
| 评审内容为英文 | 检查 prompts/review-prompt.md 是否被改动 |
```

- [ ] **Step 3: 自检**

对照 spec 第 8 节（两种构建环境）逐项核对指南覆盖：云托管（内联安装 + 连通性验证）、自建（预装 + 代理）。对照 spec 第 2 节「待实施时验证的点」确认第 5 节 env 探测步骤完整。

- [ ] **Step 4: 提交**

```bash
git add pipeline/
git commit -m "docs: Flow 流水线参考配置与客户配置指南"
```

---

### Task 5: README.md + 收尾

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: 全部前序交付物
- Produces: 仓库入口文档

- [ ] **Step 1: 写 README.md**

必须包含（用真实内容，不留占位）：

```markdown
# codeup-kiro：Codeup MR 自动 Kiro 代码评审

开发者在阿里云云效 Codeup 提交/更新合并请求（MR，等同 GitHub 的 PR）时，
云效 Flow 流水线自动调用 Kiro CLI headless 模式评审代码变更，
并将中文 Markdown 评审报告以全局评论回写到 MR 页面。

## 工作原理

    开发者提交/更新 MR (Codeup)
            │  webhook（Flow 自动注册）
            ▼
    云效 Flow 流水线（源分支）
            ▼
    scripts/kiro-review.sh
      1. 安装/检测 kiro-cli
      2. 定位 MR + 生成 diff（merge-base 三点比较）
      3. 超 300KB 按优先级压缩（代码>配置>文档，纯删除只列清单）
      4. kiro-cli chat --no-interactive --trust-tools=read,grep
      5. OpenAPI 回写 GLOBAL_COMMENT 到 MR

## 快速开始

见 [pipeline/setup-guide.md](pipeline/setup-guide.md)。

## 仓库结构

（列出各文件一行职责）

## 环境变量

（复制本计划开头的环境变量契约表）

## 本地测试

    bash tests/run-tests.sh

全程无网络依赖（DRY_RUN + mock kiro-cli）。

## 设计文档

docs/superpowers/specs/2026-07-21-codeup-kiro-review-design.md
```

- [ ] **Step 2: 全量回归**

Run: `bash tests/run-tests.sh`
Expected: 全部通过

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "docs: README 入口文档"
```

---

## 后续（不在本计划内，交付时执行）

端到端验收需要客户环境（spec 第 9 节）：测试仓库导入集成包 → 按 setup-guide 配置 → 提交带硬编码密钥的 MR → 确认评论出现。此步无法在本地完成，作为交付 checklist 项写入 setup-guide 第 6 节之后由实施人员执行。

## Self-Review 记录

- **Spec 覆盖**：§4 交付物 → T1(codeup-api)/T2(diff-compress)/T3(prompt+主脚本)/T4(yaml+guide)/T5(README)；§5 流程 → T3；§6 压缩 → T2；§7 错误表 → T1 重试/T3 失败路径/T2 截断；§8 双环境 → T4 指南 6/7 节；§9 测试 → 各任务 TDD + T4 连通性验证；§2 待验证点（MR 环境变量、ListChangeRequests 参数、安装 URL）→ T4 指南第 5 节、T1 Step 1、T3 Step 1。无遗漏。
- **占位符**：`<Step1核实后的官方安装脚本URL>` 与 `<你的代码库地址>` 均为显式指令性占位（前者有专门核实步骤，后者是客户必须替换的配置项），非计划缺陷。
- **类型/签名一致性**：`codeup_find_mr` 单参数（源分支）、输出 TAB 分隔两字段，T1 定义与 T3 消费一致；`build_review_input` 三参数 rc 0/10，T2 定义与 T3 消费一致；`codeup_post_comment <id> <file>` 一致。
