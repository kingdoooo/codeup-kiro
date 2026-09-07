#!/usr/bin/env bash
# 评审报告的提取、校验与渲染。
#
# 数据流：kiro-cli（--agent-engine v2 --output-format stream-json）的 JSON Lines
#   → review_stream_final_text  取 runFinished.data.finalText（Kiro 失败在这一步识别）
#   → review_extract_json       取 <<<KIRO_REVIEW_JSON>>> 标记内的契约 JSON
#   → review_validate           丢弃不合契约的问题并计数，规范化字段
#   → review_render_summary     渲染汇总评论（Markdown）
# 任一提取步骤失败 → review_render_degraded 渲染「结构化解析失败」评论（评审仍算产出）。
#
# 汇总评论的原地更新（票 03）：
#   review_select_prior_comment  从 MR 的全局评论里定位「本评审员上一次那条」（作者 + 评审标记）
#   review_parse_history         从那条评论的隐藏 JSON 读回历次记录
#   review_history_append        追加本次记录（并对所有字段做字符许可清单过滤）
#   review_render_history_marker / review_render_history_table / review_render_footer
#                                隐藏 JSON、「历次评审」折叠表、含「第 N 次评审」的页脚
#
# 事件形态以实测为准（kiro-cli 2.21.0，spec §4.7.1 P1-08，原始输出见
# .scratch/codeup-kiro-v2/probe-results/kiro-headless/*/out.jsonl，裁剪样例见
# tests/fixtures/stream/real-shape.jsonl）：
#   runStarted   {data:{payloadSchema,acpProtocolVersion,engine}}
#   sessionUpdate{data:{sessionId,update:{sessionUpdate:"agent_message_chunk"|"tool_call"|"tool_call_update",...}}}
#   metadata     {data:{sessionId,contextUsagePercentage,meteringUsage?:[{value,unit}],turnDurationMs?}}
#   runFinished  {data:{sessionId,status,stopReason,finalText,finalTextTruncated}}
# finalText 就是完整最终消息，无需拼接 agent_message_chunk。
#
# 渲染是纯函数：sha / 分支 / 时间戳 / diff 说明 / 评审次数全部由参数传入（不读 date、不读 git），
# 因此可以用 golden file 逐字节比对（tests/test-review-render.sh）。唯一的隐式输入是
# REVIEW_RERUN_HINT（档位相关的「怎么重新评审」提示语，见下），它有固定默认值，golden 仍然确定。

# 严重级别的中文标签与排序权重。级别词汇以 CONTEXT.md 为准：P0 必须修复 / P1 应当修复 / P2 可选改进。
REVIEW_SEVERITIES="P0 P1 P2"

# 汇总评论的标题（成功 / 降级 / 失败三条同形）。一级标题、不带图标（用户要求，2026-09-04）。
# kiro-review.sh 的最小失败评论也用 REVIEW_TITLE_FAILED，不要再手写第二份字面量。
REVIEW_TITLE="# Kiro 代码评审"
REVIEW_TITLE_DEGRADED="${REVIEW_TITLE} · ⚠️ 结构化解析失败"
REVIEW_TITLE_FAILED="${REVIEW_TITLE} · ⚠️ 评审未完成"

# --- 控制字符集只此一份（16-fix4 第 2 条）：NUL、\001–\010、\013、\014、\016–\037 剔除；换行 \012、制表 \011、回车 \015 保留。
# 三个消费者（review_clean_text 的 tr、_sanitize_md 与 _review_normalize 共用的 jq def dectl）都从下面两份渲染取值，不再各写一份字面量。
_REVIEW_CTRL_RANGES=(0 8 11 12 14 31)   # 成对的十进制闭区间
_review_ctrl_render() {  # <每段的 printf 格式（吃两个数）> → 各段拼接
  local fmt="$1" out="" i
  for ((i = 0; i < ${#_REVIEW_CTRL_RANGES[@]}; i += 2)); do
    out+=$(printf "$fmt" "${_REVIEW_CTRL_RANGES[i]}" "${_REVIEW_CTRL_RANGES[i+1]}")
  done
  printf '%s' "$out"
}
REVIEW_CTRL_TR_SET=$(_review_ctrl_render '\\%03o-\\%03o')          # tr 字符集：\000-\010\013-\014\016-\037
REVIEW_CTRL_JQ_RE="[$(_review_ctrl_render '\\u%04x-\\u%04x')]"     # jq 正则：[\u0000-\u0008\u000b-\u000c\u000e-\u001f]

# --- 文本清洗：剥离 ANSI 控制序列（stdin → stdout）---
# stream-json 的 stdout 实测不含 ANSI，但降级路径要贴的是模型原文，且纯文本回退路径仍需清洗，
# 所以清洗放在公共函数里，两条路径都过一遍。
# LC_ALL=C 是必需的（R9）：模型输出里混进无效 UTF-8 字节时，带 UTF-8 locale 的 sed（macOS/BSD）会
# 直接报错退出；在 `set -o pipefail` 的管道里，这个失败会被上游当成「awk 没找到标记」，一次编码问题
# 就被写成「被评审代码里有假标记」。按字节处理既不会失败，对 ANSI 序列的剥离也不受影响。
review_clean_text() {
  local esc
  esc=$(printf '\033')
  # 先剔 NUL 与其它控制字符（REVIEW_CTRL_TR_SET，与 _sanitize_md / 归一化同一份字符集）：BSD awk 在 NUL 处截断记录，
  # 降级原文 / kiro stderr 里一个 NUL 就能让它后面的密钥静默消失又不进掩码（第 20 条）；换行 / 制表 / 回车保留
  # 顺序：先剥 ANSI 序列再剔控制字符——ESC（\033）本身就在剔除范围里，反过来会只剩 `[38;5;141m` 的尾巴
  LC_ALL=C sed "s/${esc}\\[[0-9;?]*[a-zA-Z]//g" | LC_ALL=C tr -d "$REVIEW_CTRL_TR_SET"
}

# --- 模型文本的 Markdown 结构清洗（R1）---
# 威胁：summary / verdict_reason / title / body / fix 与降级原文全部来自模型，而模型按 agent 提示词
# 会把业务库里的注入内容作为 P0 原文引用出来。业务库因此可以往这些槽位里塞：
#   ① 第二个评审标记 `<!-- kiro-review:deadbee run:1 -->`——后续票「按标记找自己那条评论」会被打乱；
#   ② 伪造的 `# Kiro 代码评审` / `## 结论：可合并` 标题与 `---` 页脚分隔线——读者看到的结构
#      就不再是脚本渲染的结构（降级路径尤其严重，那里贴的是整段原文）。
# 因此：评论里的结构（评审标记、标题层级、页脚分隔线）只能来自脚本，模型文本一律降级为普通文本。
# 做法（jq 实现，避免同一套转义规则出现两份）：
#   - `<!--` / `-->` 转义为 `&lt;!--` / `--&gt;`：注释语法失效，标记再也构不成 HTML 注释。
#     无条件执行（也包括代码围栏内）——后续票的去重是对评论原文做文本匹配，围栏内的标记同样会被匹配到。
#   - `<details` / `</details` 同样转义，且**大小写不敏感**（HTML 标签名不区分大小写，`<DETAILS>`
#     一样会被渲染成折叠块）：折叠区是脚本渲染的结构（票 03 的「历次评审」表就是一个），
#     模型文本里的折叠标签能把脚本渲染的历次表与页脚吞进攻击者自己的折叠块、伪造历次计数，
#     也会让「超长截断后补齐未闭合 </details>」这道修复按错误的标签计数走偏。
#     用带捕获的单条 gsub 保留原始大小写（转义后的字面量按原样显示，便于读者看出模型引用了什么）。
#   - 代码围栏外，行首的 `#{1,6}` 标题与 `---`/`***`/`___`/`===` 分隔线前加反斜杠转义（渲染成字面量）。
#     围栏内不动：那里的 `#` 是代码注释，转义会破坏代码，而围栏内的 `#` 本来也不会渲染成标题。
#   - 代码围栏外，**整行只是一个加粗**（`**…**` / `__…__`）的行：首尾定界符各加反斜杠转义成字面量。
#     2026-09-04 起问题分组、每条问题、折叠区小节与行内评论首行都是整行加粗（Codeup 不渲染 `###` 以下
#     标题），模型文本里的整行加粗能逐字节冒充这些结构行。行内加粗（`**影响**：…`）不动——真实评审里
#     模型从没写过整行加粗（acceptance 留档的 13 处整行加粗全是脚本自己的「修复建议」）。
#   - 围栏数为奇数时补一个闭合围栏：否则模型开一个不闭合的围栏就能把后面脚本渲染的章节与页脚一起吞掉。
# 开头的 def dectl 是控制字符剔除（REVIEW_CTRL_JQ_RE 渲染进来；_sanitize_md 与 _review_normalize 都用它，第 2 条）
_REVIEW_JQ_SANITIZE="def dectl(v): (v | gsub(\"${REVIEW_CTRL_JQ_RE}\"; \"\"));"'
  def _is_bold_line: (test("^[[:space:]]{0,3}\\*\\*[^[:space:]*].*\\*\\*[[:space:]]*$")
                      or test("^[[:space:]]{0,3}__[^[:space:]_].*__[[:space:]]*$"));
  def _escape_bold_line: sub("^(?<sp>[[:space:]]{0,3})\\*\\*"; .sp + "\\*\\*")
                         | sub("\\*\\*(?<ws>[[:space:]]*)$"; "\\*\\*" + .ws)
                         | sub("^(?<sp>[[:space:]]{0,3})__"; .sp + "\\_\\_")
                         | sub("__(?<ws>[[:space:]]*)$"; "\\_\\_" + .ws);
  # 票 14：Codeup 会渲染原始 HTML，而模型文本进评论的通道有 summary/verdict_reason/title/body/fix
  # 与降级路径的整段原文。提示词要求模型把注入企图当 P0 报出来并引用原文，所以业务库里写一段
  # `<div style="display:none">`（不闭合）就能吞掉它之后的整份报告，`<h1>` 能伪造出与脚本同级的标题。
  # 策略（三选一，选 ②）：① 转义全部 `<`——模型引用代码里的 `<` 全变实体，围栏内还得豁免；
  # ② 只转义「看起来像标签」的 `<`（后跟字母、`/`、`!`、`?`）——`a < b`、`<3`、`<-` 不动，
  #    `a<b` 变 `a&lt;b` 但渲染后与原文无异；③ 标签许可清单——要维护、且任何一个放行的标签都是新入口。
  # `!`/`?` 后不要求字母：CommonMark 把 `<?…?>` 与 `<![CDATA[…]]>` 当原始 HTML 放行，浏览器则把它们
  # 当「错误注释」一路吞到下一个 `>`（复审 A1）。
  # **行内 code span 不豁免**（复审 C1）：code span 能跨行配对——上一行结尾一个孤立反引号会和本行开头的
  # 反引号配成一对，本行「看起来平衡」的 `` `<div>` `` 在渲染器眼里反而在 span 之外。逐行判定做不对，
  # 做对要重写整个块级解析；这是安全控制，宁可让 `` `<div>` `` 显示成 `` `&lt;div>` ``（实体在 span 内不解码，
  # 读者仍能认出）。4 空格缩进的代码块同理不豁免：段落后一行缩进 4 空格是段落的惰性延续，不是代码。
  # 自动链接 `<https://…>` 也会被转义成文字——结构只能来自脚本，这个损失有意接受。
  def _re_tag: "<(?=[A-Za-z/!?])";
  def _escape_tags: gsub(_re_tag; "&lt;");
  # 围栏按 CommonMark 判定（复审 C2）：反引号围栏的 info string 里不能有反引号（```` ```x`y ```` 不是围栏，
  # 渲染器把它当段落，其后的 `<div>` 照样渲染）；闭合围栏必须与开启同一字符、长度不短于开启、后面只能
  # 有空白（所以 ``` 里的 `~~~` 是内容，`~~~` 里的 ``` 也是）。开启行本身也过标签转义：info string 里
  # 的 `<` 没有任何合法用途。围栏内只认定不渲染 HTML，其余一律按普通行处理。
  def _fence_open: [capture("^[[:space:]]{0,3}(?<f>`{3,}|~{3,})(?<info>.*)$")][0]
                   | if . == null then null
                     elif (.f | startswith("~")) or (.info | test("`") | not) then {ch: .f[0:1], len: (.f | length)}
                     else null end;
  def _fence_close($ch; $len): [capture("^[[:space:]]{0,3}(?<f>`{3,}|~{3,})[[:space:]]*$")][0]
                   | . != null and (.f[0:1] == $ch) and ((.f | length) >= $len);
  # 分隔线与 setext 下划线（PROGRESS：原先只认连续 3+ 个 `-*_=`，`- - -`/`* * *`/单个 `=`/`-` 漏网）：
  # CommonMark 的分隔线是同一字符 3 个以上、之间可夹空白；setext 下划线是任意长度的 `=` 或 `-`
  # （单个 `=` 就能把上一行变成一级标题）。`= = =` 与 `* *` 两者都不是，不动。
  def _re_thematic: "^[[:space:]]{0,3}([-*_])([[:space:]]*\\1){2,}[[:space:]]*$";
  def _re_setext: "^[[:space:]]{0,3}(=+|-+)[[:space:]]*$";
  def _is_break_line: (test(_re_thematic) or test(_re_setext));
  # 第 23 条：NUL 与其它控制字符（dectl，字符集见 REVIEW_CTRL_JQ_RE）一律剔除——一个 NUL 就能让 grep 把评论
  # 当二进制（BSD grep 的「Binary file matches」进 stdout，守卫失败 → 整份评审退成最小失败评论）；换行 / 制表 / 回车保留。
  def _sanitize_md:
    if type != "string" then "" else
    (dectl(.)
     | gsub("<!--"; "&lt;!--") | gsub("-->"; "--&gt;")
     | gsub("<(?<tag>/?details)"; "&lt;\(.tag)"; "i"))
    | split("\n")
    | reduce .[] as $l ({fch: null, flen: 0, out: []};
        . as $st
        | if .fch != null then
          if ($l | _fence_close($st.fch; $st.flen)) then {fch: null, flen: 0, out: (.out + [$l])}
          else {fch: .fch, flen: .flen, out: (.out + [$l])} end
        else
          ($l | _fence_open) as $o
          | if $o != null then {fch: $o.ch, flen: $o.len, out: (.out + [($l | _escape_tags)])}
            else
              ($l | _escape_tags) as $t
              | {fch: null, flen: 0, out: (.out + [
                  if ($t | test("^[[:space:]]{0,3}#{1,6}([[:space:]]|$)")) then
                    ($t | sub("^(?<sp>[[:space:]]{0,3})(?<h>#{1,6})"; .sp + "\\" + .h))
                  elif ($t | _is_break_line) then
                    ($t | sub("^(?<sp>[[:space:]]{0,3})"; .sp + "\\"))
                  elif ($t | _is_bold_line) then
                    ($t | _escape_bold_line)
                  else $t end ])}
            end
        end)
    | (if .fch != null then (.out + [(.fch * .flen)]) else .out end)
    | join("\n")
    end;
'

# --- 不受信取值进表格单元格 / code span 时要剔掉的字符集（票 13：三处只此一份；仓库里习惯把这条规则叫「字符许可清单」，
#     指的是「除这几个字符和控制字符外全部放行」）---
# 用在：① review_history_append 的 safe()（上一条评论里的隐藏历史，人可编辑）；② review_validate 的 fpath()
# （模型给的 file——命中即按未定位处理而不是剔字符，它要把「不可定位」计数出来）；③ _review_meta_cell（分支名）。
#   `|`      —— GFM 先按 | 切单元格再解析行内，撑出幻影列，把时间与 diff 挤出表格
#   反引号   —— 逃出脚本包的 code span，其后的原始 HTML 直接进评论；定位串的反引号失配
#   `<` `>`  —— 逃出 code span 后就是原始 HTML；也让 `<!--`/`-->` 构不成（隐藏标记不被提前闭合）
#   反斜杠   —— 纵深防御（git ref 已拒；流水线变量那条路不过 git 校验）
#   控制字符 —— 另按 [[:cntrl:]] 类处理（bash 与 jq 都有这个 POSIX 类，不必列举）：换行会造出第二行、
#              \x1f 会让历次表的字段分隔错位
# bash 侧用 ${v//["$REVIEW_CELL_DENY_CHARS"]/}（引号让括号里的字符按字面量匹配，bash 3.2 实测）；jq 侧经
# --arg deny 注入、按码点比对（不拼正则，省掉反斜杠转义的坑）。长度上限按槽位各自定义（历次表字段 40/16、
# 元信息单元格 200）：那是列宽语义，不是同一个概念。
REVIEW_CELL_DENY_CHARS='<>|`\'
REVIEW_META_CELL_MAX_LEN=200
_REVIEW_JQ_CELL='
  def _deny_codes: ($deny | explode);
  def _cell_strip(s): ((s | explode) as $cs | _deny_codes as $d
                       | [$cs[] | select(. as $c | ($d | index($c)) == null)] | implode | gsub("[[:cntrl:]]"; ""));
  def _cell_has_deny(s): (_cell_strip(s) != s);
'

# 用法：review_sanitize_md < 文件 → stdout（降级原文走这条；契约字段在 review_validate 里用同一个 jq def）
# -j（join output，不额外补换行）：输入文件末尾本来就有换行，split/join 会原样保留它；
# 用 -r 的话 jq 还会再补一个，降级评论的正文与页脚之间就多出一个空行。
review_sanitize_md() {
  jq -Rjs "${_REVIEW_JQ_SANITIZE} _sanitize_md"
}
# 清洗后再折成单行：给要嵌进**一行**里的不受信取值用（页脚的重评提示、降级引用块里的 --reason）。
# 顺序不能反：_sanitize_md 在代码围栏数为奇数时会**追加一行** ```，先折行的话那个换行又被加回来——
# 页脚会变成两行，而降级评论里那一行还会跳出 `> ` 引用块并开一个吞掉后文的未闭合围栏。
# 用法：_review_sanitize_oneline <取值> → stdout（不带换行）
_review_sanitize_oneline() {
  printf '%s' "$1" | review_sanitize_md | LC_ALL=C tr '\n\r\t' '   '
}

# --- 从 JSON Lines 事件流取最终消息 ---
# 用法：review_stream_final_text <jsonl 文件>
#   rc 0 → stdout = finalText
#   rc 2 → 没有 runFinished 事件（Kiro 未跑完：视为 Kiro 失败）
#   rc 3 → runFinished.data.status 非 success；stdout = status 值（供失败评论写明原因）
#   rc 7 → 事件流文件不可读（**不能**与 review_extract_json 的「标记不唯一」rc 6 复用同一个码：
#          那会把一次 I/O 故障在 MR 上写成「被评审代码里有假标记」）
# 用 `jq -R 'fromjson?'` 逐行解析：stdout 里混进 CLI 的非 JSON 警告行时跳过该行，而不是整体失败。
review_stream_final_text() {
  local jsonl="$1" rf status
  [[ -r "$jsonl" ]] || { echo "review_stream_final_text: 事件流文件不可读：${jsonl}" >&2; return 7; }
  rf=$(jq -c -R 'fromjson? | select(type == "object" and .type == "runFinished")' "$jsonl" 2>/dev/null | tail -1)
  [[ -n "$rf" ]] || return 2
  status=$(printf '%s' "$rf" | jq -r '.data.status // ""')
  if [[ "$status" != "success" ]]; then
    printf '%s\n' "${status:-<runFinished 无 status 字段>}"
    return 3
  fi
  printf '%s' "$rf" | jq -r '.data.finalText // ""'
}

# --- 成本与上下文可观测指标（写流水线日志；spec §4.1「metadata.meteringUsage 写入日志」）---
# 用法：review_stream_usage <jsonl 文件> → stdout "credits=0.2609 context=3.8%"
# credits 累加所有 metadata 事件里 unit=credit 的 value（实测一次评审会分多笔计量）；
# context 取**峰值**而不是最后一个：实测事件流里这个值不单调（real-shape.jsonl 是 12.02 → 1.30，
# 取最后一个会把「上下文最高用到 12%」记成 1.3%，这个指标本来就是为了看离上限还有多远）。
# 缺数据时对应字段为 -，永不失败（日志不该拖垮评审）。
review_stream_usage() {
  local jsonl="$1" credits ctx
  if [[ ! -r "$jsonl" ]]; then printf 'credits=- context=-\n'; return 0; fi
  credits=$(jq -R 'fromjson? | select(type == "object" and .type == "metadata")
                   | .data.meteringUsage // empty | .[] | select(.unit == "credit") | .value' \
              "$jsonl" 2>/dev/null | LC_ALL=C awk '{s += $1; n++} END {if (n) printf "%.4f", s; else printf "-"}')
  ctx=$(jq -r -R 'fromjson? | select(type == "object" and .type == "metadata")
                  | .data.contextUsagePercentage // empty' "$jsonl" 2>/dev/null \
        | LC_ALL=C awk 'NF { if (!f || $1 > m) m = $1; f = 1 } END {if (f) printf "%.1f%%", m; else printf "-"}')
  printf 'credits=%s context=%s\n' "${credits:--}" "${ctx:--}"
}

# --- 最终消息是否被 kiro-cli 自己截断（runFinished.data.finalTextTruncated）---
# 用法：review_stream_final_truncated <jsonl 文件> → rc 0 = 被截断；rc 1 = 未截断或读不到。
# 截断会让契约 JSON 缺尾巴，表现成「没有结束标记」或「JSON 非法」。不读这个字段的话，
# 降级评论会把 Kiro 自己的截断说成模型不守契约，运维只会一遍遍重跑同一个必然失败的评审。
review_stream_final_truncated() {
  local jsonl="$1" v
  [[ -r "$jsonl" ]] || return 1
  v=$(jq -r -R 'fromjson? | select(type == "object" and .type == "runFinished")
                | .data.finalTextTruncated // false' "$jsonl" 2>/dev/null | tail -1)
  [[ "$v" == "true" ]]
}

# --- 本次运行的标记随机串（R4）---
# 固定字面量标记是可被业务库利用的：提示词要求把注入企图作为 P0 报出来，模型常常直接原文引用
# 那行 `<<<KIRO_REVIEW_JSON>>>`，于是标记计数变成 2、每次评审都被打成「标记不唯一」而降级——
# 业务库提交一行文本就能让评审永久失去结构化输出。改成每次运行生成随机 nonce、标记里带上它，
# 攻击者无法预先把本次的 nonce 提交进仓库。
review_new_nonce() {
  # 优先 /dev/urandom（Linux/macOS 都有）；取不到时退回 PID + 纳秒/秒级时间戳，仍然不可预测到「提前提交」
  od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n' | grep -qE '^[0-9a-f]{16}$' \
    && od -An -tx1 -N8 /dev/urandom | tr -d ' \n' \
    || printf '%08x%08x' "$$" "$(date +%s)"
}

# 用法：review_marker_start <nonce> / review_marker_end <nonce>
review_marker_start() { printf '<<<KIRO_REVIEW_JSON:%s>>>' "$1"; }
review_marker_end()   { printf '<<<END_KIRO_REVIEW_JSON:%s>>>' "$1"; }

# --- 从最终消息里截出标记包裹的那段 JSON（stdin → stdout）---
# 安全要求：业务库内容不受信，而 agent 提示词要求评审员把注入企图作为 P0 报告出来——也就是说
# **被评审代码里的假契约块很可能被评审员原文引用到最终消息里**。带 nonce 之后攻击者已经无法预先
# 造出「本次」标记，但模型自己复述一遍本次标记仍然可能发生，此时输出里会出现两对标记、无法判定
# 哪一段是结论。取「最后一对」会让后一段顶掉前一段，取「第一对」也只是换一种被绕过的顺序。
# 因此：**本次标记不唯一就拒绝解析**，交给降级路径贴出原文，让人来看。
# LC_ALL=C：按字节处理，模型输出里的无效 UTF-8 不会让 awk 罢工（与 review_clean_text 同理）。
# 用法：_review_slice_marker <起始标记> <结束标记>
# rc 1 = 没有成对标记；rc 2 = 起始或结束标记出现多于一次。
_review_slice_marker() {
  LC_ALL=C awk -v S="$1" -v E="$2" '
    # 统计 hay 中 needle 出现的次数
    function count(hay, needle,   c, p) {
      c = 0
      while ((p = index(hay, needle)) > 0) { c++; hay = substr(hay, p + length(needle)) }
      return c
    }
    { buf = buf $0 "\n" }
    END {
      ns = count(buf, S); ne = count(buf, E)
      if (ns == 0 || ne == 0) exit 1
      if (ns > 1 || ne > 1) exit 2
      start = index(buf, S)
      rest = substr(buf, start + length(S))
      q = index(rest, E)
      if (q == 0) exit 1
      printf "%s", substr(rest, 1, q - 1)
    }'
}

# --- 去掉契约 JSON 外面可能包着的 Markdown 代码围栏（stdin → stdout）---
# 模型很容易把 JSON 放进 ```json 围栏里（提示词里的 schema 本身就是围栏形式）。
# 围栏不是契约的一部分，但它会让 jq 解析失败、把每一次评审都推进降级路径，所以这里宽容处理。
_review_strip_code_fence() {
  awk '
    { line[NR] = $0 }
    END {
      first = 1; last = NR
      while (first <= last && line[first] ~ /^[[:space:]]*$/) first++
      while (last >= first && line[last] ~ /^[[:space:]]*$/) last--
      if (first <= last && line[first] ~ /^[[:space:]]*```/ && line[last] ~ /^[[:space:]]*```[[:space:]]*$/) {
        first++; last--
      }
      for (i = first; i <= last; i++) print line[i]
    }'
}

# --- 提取契约 JSON ---
# 用法：review_extract_json <jsonl 文件> <本次运行的 nonce>
#   rc 0 → stdout = 契约 JSON（compact，单个对象）
#   rc 2/3/7 → 透传 review_stream_final_text：Kiro 失败或事件流不可读，调用方走失败评论路径（不是降级）
#   rc 4 → 没有成对的契约标记 → 降级
#   rc 5 → 标记内不是「恰好一个」JSON 对象 → 降级
#   rc 6 → 输出里出现多于一对契约标记 → 降级
#   rc 8 → 用法错误（没传 nonce）：绝不退回固定标记，否则 R4 的防护就白做了
review_extract_json() {
  local jsonl="$1" nonce="${2:-}" final slice rc=0 slice_rc=0 ms me
  [[ -n "$nonce" ]] || { echo "review_extract_json: 缺少 nonce 参数（标记必须带本次运行的随机串）" >&2; return 8; }
  ms=$(review_marker_start "$nonce"); me=$(review_marker_end "$nonce")
  final=$(review_stream_final_text "$jsonl") || rc=$?
  if [[ "$rc" != "0" ]]; then
    # rc 3 时 review_stream_final_text 把 status 值写在 stdout；透传给调用方，让失败评论能写明原因
    [[ "$rc" == "3" ]] && printf '%s\n' "$final"
    return "$rc"
  fi
  slice=$(printf '%s\n' "$final" | review_clean_text | _review_slice_marker "$ms" "$me") || slice_rc=$?
  case "$slice_rc" in
    0) ;;
    2) return 6 ;;
    *) return 4 ;;
  esac
  slice=$(printf '%s\n' "$slice" | _review_strip_code_fence)
  # -s 把输入读成数组：jq 默认接受 JSON 流，`{...}{...}` 两个对象也能通过 `type == "object"`，
  # 之后 review_validate 会把两行 JSON 一起吐出来，渲染出「P0 0\n0」这种垃圾。必须恰好一个对象。
  printf '%s\n' "$slice" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || return 5
  printf '%s\n' "$slice" | jq -c -s '.[0]'
}

# --- 受信 agent 的契约标识（R3）---
# 这个字段**只**写在 agent 提示词里，运行时提示词绝不提它。kiro-cli 对 `--agent` 的未知名字是静默接受的，
# runStarted 事件也不含 agent 名，所以「受信 agent 到底有没有生效」在事件流里看不出来。
# 一旦 agent 没加载（文件改名、安装回归、CLI 行为变化），模型拿到的是裸提示词：拒绝路径全部失效，
# 输出也不合契约——而降级路径会把那份输出贴到 MR 上。有了这个字段，缺失/不符就能判定为
# 「不是受信 agent 的产出」，走失败评论而**不是**降级（不能把非受信产出贴出去）。
REVIEW_CONTRACT_ID="codeup-reviewer/1"
# 模型字段的字节上限（第 21 条；只在这里定义，_review_normalize / review_finalize_json 经 --argjson 注入）。summary / verdict_reason
# 共用 REVIEW_CAP_SUMMARY。fix 取 16 KB 而非 32 KB、title 另设 2 KB：title + body + fix + 标记 + 页脚要落在 MAX_COMMENT_BYTES 默认值
# 60000 之内。上限在两处生效（16-fix4 第 12 条）：归一化先按 2 × 上限的码点数预切（把掩码 awk 的成本绑定到上限而不是模型输出），
# 清洗之后再按字节精确截断并标注。掩码 awk 对单行的成本是线性的（redact_url 先 index("://") 再跑正则；连片掩码按 match 前进），
# 100 KB 单行 body 与 10000 个 `<!--` 的清洗膨胀向量都在秒级（tests 里有 4 × 目标的计时守卫）。
REVIEW_CAP_SUMMARY=8192
REVIEW_CAP_TITLE=2048
REVIEW_CAP_BODY=32768
REVIEW_CAP_FIX=16384
REVIEW_CAP_ID=256        # id / category：不渲染，只为约束掩码成本（按码点预切，不计入 truncated_fields）

# --- 契约归一化（stdin = 契约 JSON → stdout = 归一化 JSON；只做结构 / 类型 / trim / 归一化 / 预切，**不**清洗、不掩码、不截断）---
# 对外入口与最终形态见下面的 review_validate；这里只描述归一化本身。
# 丢弃规则（spec §4.1「字段校验失败的 finding 丢弃并计数」）：
#   - 不是 JSON 对象
#   - severity 规范化（去首尾空白 + 大写）后不是 P0/P1/P2
#   - title 或 body 去空白后为空（缺字段同样算空）
# 置空（不丢弃）的情形：
#   - file 为空/非字符串 → null（仓库级意见）
#   - file 含换行/回车/`|`/反引号 → null 并计入 delocated_findings（R2）：file 会被渲染进
#     「重点关注文件」表格的单元格（`|` 会造出幻影列、截断表格）和被反引号包裹的定位串（反引号会破坏配对），
#     换行更是直接把表格截断、给攻击者一个塞伪造章节的位置。这类路径本来也不可能是真实文件名。
#   - line_start/line_end 不是 ≥1 的整数 → null；file 为 null 时行号一并置 null
# 单行槽位（title / verdict / id / category）把空白折叠成单空格——它们要渲染进单行（`**n. … — 标题**` 加粗行与 `## 结论：…`），
#   带换行就会把标题行截断；body / fix 不做 trim：它们是 Markdown，可能以缩进代码块开头，裁掉缩进会破坏渲染。
# 控制字符在这里就剔掉（dectl）：掩码在清洗之前跑，BSD awk 会在 NUL 处截断记录，一个 NUL 就能让它后面的密钥静默消失又不进掩码（第 20 / 23 条）。
# 预切（16-fix4 第 12a 条）：多行槽位按 2 × 字节上限的**码点**数切（一个码点至少一字节，所以永远不会切到最终字节上限之下），
#   id / category 切 REVIEW_CAP_ID 码点——只为把掩码的 awk 成本绑定到上限而不是模型输出；真正的字节上限与截断标记在 review_finalize_json。
# 问题条数上限 REVIEW_MAX_FINDINGS：超出的条数计入 overflow_findings（第 28 条），dropped_findings 只数不合契约的。
# 计数直接写进输出 JSON 而不是回传全局变量：调用方普遍用 $(…) 取结果，命令替换在子 shell 里跑，全局变量传不回来。
REVIEW_MAX_FINDINGS=200
_review_normalize() {
  local input
  input=$(cat)
  printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { echo "review_validate: 契约不是 JSON 对象" >&2; return 1; }
  printf '%s' "$input" | jq -e '(.findings // []) | type == "array"' >/dev/null 2>&1 \
    || { echo "review_validate: 契约的 findings 不是数组" >&2; return 1; }
  printf '%s' "$input" | jq -e --arg id "$REVIEW_CONTRACT_ID" '(.contract // "") == $id' >/dev/null 2>&1 \
    || { echo "review_validate: 契约缺少 contract=\"${REVIEW_CONTRACT_ID}\" 字段（该字段只在受信 agent 提示词里要求，说明受信 agent 未生效）" >&2; return 3; }
  printf '%s' "$input" | jq -c --arg deny "$REVIEW_CELL_DENY_CHARS" --argjson maxf "$REVIEW_MAX_FINDINGS" \
      --argjson cap_summary "$REVIEW_CAP_SUMMARY" --argjson cap_title "$REVIEW_CAP_TITLE" --argjson cap_body "$REVIEW_CAP_BODY" \
      --argjson cap_fix "$REVIEW_CAP_FIX" --argjson cap_id "$REVIEW_CAP_ID" "${_REVIEW_JQ_SANITIZE}${_REVIEW_JQ_CELL}"'
    # \A / \z 是显式的「字符串首/尾」锚点：jq 的 ^ / $ 在不同版本可能被当行锚点，
    # 那会连多行字符串里每一行的缩进都裁掉。
    # dectl 来自 _REVIEW_JQ_SANITIZE（控制字符集只此一份，第 2 条）
    def pre(v; n): if (v | type) == "string" then v[0:n] else v end;   # 预切（第 12a 条，按码点）
    def tr(v): if (v | type) == "string"
               then (dectl(v) | gsub("\\A[[:space:]]+"; "") | gsub("[[:space:]]+\\z"; ""))
               else "" end;
    # 单行槽位：折叠所有空白（含换行）为单空格（清洗与 `*` 转义在 review_finalize_json，掩码之后）
    def oneline(v): (tr(v) | gsub("[[:space:]]+"; " "));
    def lineno(v): if (v | type) == "number" and (v | floor) == v and v >= 1 then (v | floor) else null end;
    # 文件路径：非空字符串，且不含许可清单外的字符（REVIEW_CELL_DENY_CHARS 与控制字符；否则按未定位处理——
    # 与另两处的差别只在处置：这里不剔字符，因为「不可定位」要计数并写进统计行）。
    # 先在**只 trim、不剔控制字符**的值上查禁用字符（第 27 条）：先 dectl 会把 `src/\u0001app.py` 洗成合法路径、既不计数也不置空
    def fpath(v): (if (v | type) == "string" then (v | gsub("\\A[[:space:]]+"; "") | gsub("[[:space:]]+\\z"; "")) else "" end) as $t
                  | if ($t | length) == 0 then null
                    elif _cell_has_deny($t) then null
                    elif ($t | startswith("-----")) then null   # 路径不可能长这样；PEM 的 BEGIN 标记当 file 会被 PEM 规则当块起始（第 10 条）
                    else $t end;
    . as $root
    | ((.findings // []) | length) as $total
    | [ (.findings // [])[:$maxf][]
        | select(type == "object")
        | (tr(.severity) | ascii_upcase) as $sev
        | oneline(.title | pre(.; 2 * $cap_title)) as $title
        | select(($sev == "P0" or $sev == "P1" or $sev == "P2")
                 and ($title | length) > 0
                 and ((tr(.body)) | length) > 0)
        | fpath(.file) as $file
        | ((tr(.file) | length) > 0 and $file == null) as $delocated
        | (if $file == null then null else lineno(.line_start) end) as $ls
        | (if $ls == null then null
           else (lineno(.line_end)) as $le | (if $le == null or $le < $ls then $ls else $le end) end) as $le
        | { id: (oneline(.id | pre(.; $cap_id))), severity: $sev, category: (oneline(.category | pre(.; $cap_id))), title: $title,
            file: $file, line_start: $ls, line_end: $le, delocated: $delocated,
            body: (if (.body | type) == "string" then dectl(.body | pre(.; 2 * $cap_body)) else "" end),
            fix: (if (.fix | type) == "string" then dectl(.fix | pre(.; 2 * $cap_fix)) else "" end) }
      ] as $kept
    | { summary: (tr($root.summary | pre(.; 2 * $cap_summary))),
        verdict: (tr($root.verdict) | ascii_upcase | gsub("[[:space:]]+"; " ")),
        verdict_reason: (tr($root.verdict_reason | pre(.; 2 * $cap_summary))),
        findings: ($kept | map(del(.delocated))),
        dropped_findings: (([$total, $maxf] | min) - ($kept | length)),
        overflow_findings: (if $total > $maxf then $total - $maxf else 0 end),
        delocated_findings: ([$kept[] | select(.delocated)] | length) }'
}
# --- 就地 jq 改写（16-fix4 第 3 条；review_finalize_json 与 review_redact_json 共用）---
# 输出先写到目标同目录的临时文件（跨文件系统的 mv 不是原子的，中途失败会留下半截 JSON），jq 失败或输出为空 → 删临时文件、
# 原文件一个字节不动。用法：_review_jq_inplace <文件> <调用方名> <步骤名> <jq 参数…（程序在最后）>
_review_jq_inplace() {
  local file="$1" who="$2" step="$3" out; shift 3
  out=$(mktemp "${file}.jq.XXXXXX") || { echo "$who: 建不出临时文件：${file}" >&2; return 1; }
  if ! jq "$@" "$file" > "$out" || [[ ! -s "$out" ]]; then rm -f "$out"; echo "$who: ${step}失败：${file}" >&2; return 1; fi
  mv -f "$out" "$file" || { rm -f "$out"; echo "$who: 写回失败：${file}" >&2; return 1; }
}
# --- 清洗 + 上限（掩码**之后**）：Markdown 结构清洗、title 的 `*` 转义、按字节上限截断并计数 ---
# 用法：review_finalize_json <文件>  就地改写；上限值只在 REVIEW_CAP_* 常量、经 --argjson 注入。
review_finalize_json() {
  local file="${1-}"
  [[ -n "$file" && -r "$file" ]] || { echo "review_finalize_json: 文件不可读：${file}" >&2; return 2; }
  _review_jq_inplace "$file" review_finalize_json "清洗 / 上限" -c --argjson cap_summary "$REVIEW_CAP_SUMMARY" --argjson cap_title "$REVIEW_CAP_TITLE" \
           --argjson cap_body "$REVIEW_CAP_BODY" --argjson cap_fix "$REVIEW_CAP_FIX" "${_REVIEW_JQ_SANITIZE}"'
    # 字段上限（第 21 条，按 UTF-8 **字节**）：最终结果是「清洗过的文本 ≤ 上限」——清洗会膨胀（全是 `<!--` 的字段 4 → 7 字节；`<a` → `&lt;a`
    # 2.5 倍），所以不能洗完再切（切点可能落在围栏中间、留下半个实体），也不能切完就交（洗一遍又超）。做法（16-fix4 第 12b / 19 条）：
    # 原文按字节预算二分找最长的码点前缀（不 explode）→ 清洗 → 超了就按比例缩预算再来，最多 6 轮，**最后一步一定是清洗**；截断标记
    # 「（已截断）」是脚本文案、在清洗之外追加，预算里已经给它留了位置，所以 v 的总字节数 ≤ n。cap 返回 {v, t}，计数就在这里产出（第 6 条）。
    # 掩码不会让字段变长（mask 等长或变短；PEM 占位 / 提示行有界），行内正文 ≈ 上限之和 + 标记 + 页脚 < 60000；出口另有硬守卫。
    # 参数一进函数就绑成 $变量：jq 的函数参数是闭包，在 until 的状态对象上求值时 `.body` 一类路径参数会变成 null
    def _bytecut(v; n): v as $v | n as $n
      | if ($v | utf8bytelength) <= $n then $v
        else ({lo: 0, hi: ($v | length)}
              | until(.lo >= .hi;
                  (((.lo + .hi + 1) / 2) | floor) as $mid
                  | if ($v[:$mid] | utf8bytelength) <= $n then .lo = $mid else .hi = ($mid - 1) end)
              | $v[:.lo]) end;
    def _fit(raw; m): raw as $raw | m as $m
      | {b: $m, c: null, i: 0}
      | until(.i >= 6 or (if .c == null then false else (.c | utf8bytelength) <= $m end);
          .b as $b | (_bytecut($raw; $b) | _sanitize_md) as $c
          | .c = $c | .i += 1
          | if ($c | utf8bytelength) > $m then .b = ([0, (((($b * $m) / ($c | utf8bytelength)) | floor) - 1)] | max) else . end)
      | if .c != null and (.c | utf8bytelength) <= $m then .c else (_bytecut($raw; (($m / 4) | floor)) | _sanitize_md) end;   # 6 轮仍超（清洗膨胀 > 2.5 倍的病态输入）：预算砍到 1/4 再洗一次
    def _mark: "（已截断）";
    def cap(v; n): v as $v | n as $n
      | if ($v | type) != "string" then {v: "", t: 0}
        else ($v | _sanitize_md) as $s
          | if ($s | utf8bytelength) <= $n then {v: $s, t: 0}
            else {v: (_fit($v; $n - (_mark | utf8bytelength)) + _mark), t: 1} end end;
    # 加粗槽位：title 会被脚本包进 `**…**`（问题标题行、折叠区条目、行内评论首行）。先把 `*` 转义成 `\*`，
    # 否则标题里的 `**kwargs` 会提前闭合脚本的加粗、把级别前缀变回普通文字。先转义再清洗：转义后的
    # 字符串以反斜杠开头，不会再被 _sanitize_md 的整行加粗规则二次转义。
    # 标题里**所有** `*` 一律转义（16-fix4 第 22 条）：掩码结果 `AKIA****4567` 的四颗星也转义成 `\*\*\*\*`（渲染出来仍是 ****）——
    # 一处掩码靠 CommonMark「三的倍数」规则碰巧不闭合外层 `**`，两处（`硬编码 AKIA… 与 ghp_… 两处密钥`）就互相配对、把 `P0 ·`
    # 级别前缀打回普通文字。全部转义在两种解读下都安全。
    def boldsafe_esc: if type == "string" then gsub("\\*"; "\\*") else . end;   # 清洗由 cap 做（最后一步一定是清洗）
    . as $r
    | cap($r.summary; $cap_summary) as $S
    | cap($r.verdict_reason; $cap_summary) as $R
    | .findings |= [ .[]
        | cap((.title | boldsafe_esc); $cap_title) as $T
        | cap(.body; $cap_body) as $B
        | cap(.fix; $cap_fix) as $F
        | .title = $T.v | .body = $B.v | .fix = $F.v | .id |= _sanitize_md | .category |= _sanitize_md
        | ._tc = ($T.t + $B.t + $F.t) ]
    | .summary = $S.v | .verdict_reason = $R.v | .verdict |= _sanitize_md
    | .truncated_fields = ($S.t + $R.t + ([.findings[]._tc] | add // 0))
    | .findings |= map(del(._tc))'
}
# --- 契约校验（对外入口）：归一化 → 字段级掩码 → 清洗 + 上限（stdin → stdout）---
# 顺序不能倒（16-fix3 第 15 条，P1）：先清洗再掩码时，围栏内的 `# Kiro 代码评审` / `---` 合法地不被转义，随后 PEM 整块删除把围栏
# 开启行一起删掉，渲染出的汇总里出现真 H1 / H2 与吞掉页脚的未闭合围栏，R1「结构只能来自脚本」被打穿。
# 规范化后的形态：{summary, verdict, verdict_reason, findings:[…], dropped_findings:N, overflow_findings:N, delocated_findings:N, truncated_fields:N}
#   summary / verdict_reason / title / body / fix 已掩码并过 _sanitize_md（见 R1 说明），title 里的 `*` 已转义；
#   title / verdict / id / category 是单行；每个文本字段 ≤ REVIEW_CAP_*（字节），超出的已截断并计入 truncated_fields。
# rc 1 = 顶层不是对象 / findings 不是数组 / 不是合法 JSON（调用方走降级）
# rc 3 = contract 字段缺失或不等于 REVIEW_CONTRACT_ID（调用方走失败评论，**不得**贴出模型内容）
# rc 4 = 字段级掩码或清洗失败（调用方走失败评论：不能把未掩码的字段往下送，也不能把它当「解析失败」贴原文）
review_validate() {
  local f rc=0
  f=$(mktemp) || return 4
  _review_normalize > "$f" || rc=$?
  if (( rc != 0 )); then rm -f "$f"; return "$rc"; fi
  review_redact_json "$f" || { rm -f "$f"; echo "review_validate: 字段级掩码失败" >&2; return 4; }
  review_finalize_json "$f" || { rm -f "$f"; echo "review_validate: 清洗 / 上限失败" >&2; return 4; }
  cat "$f" || { rm -f "$f"; echo "review_validate: 输出失败" >&2; return 4; }   # 第 20 条：写 stdout 失败也算失败，调用方不能拿半截文件当结果
  rm -f "$f"
}

# ============================================================================
# 票 04：行内评论管线（spec §4.5 第 2–7 步）
# ============================================================================
#
#   review_changed_lines        零上下文 diff → 每个文件「新文件侧」的变更行区间集合
#   review_plan_inline          规范化契约 + 变更行集合 + 档位 + 上限 → 本次的行内发布计划
#   review_fingerprint          行内评论指纹 sha1(file + line + title)（写进标记，仅作信息用途）
#   review_render_inline_marker 行内评论正文里的隐藏标记：指纹 + 行区间 + 级别
#   review_inline_existing_ranges / review_inline_draft_ranges
#                               从 MR 现有行内评论 / 残留草稿里读回「文件 + 行区间 + 级别」
#   review_inline_overlaps      去重判定：同文件、区间重叠或相距 ≤ 2 行、且已有评论级别不低于新问题 → 同一问题
#   review_render_inline_body   一条行内评论的正文（spec §4.4）
#   review_plan_apply_outcomes  发布结果回填计划（发失败的问题必须落到折叠区，不能凭空消失）
#
# 为什么行号集合必须自己算而不是信模型：`line_start` 完全由模型给出，而 Codeup 只接受
# **新文件侧**的行号（spec §4.7.1 P1-02 实测），挂到未改动行上的评论对读者是噪音。
# 集合来自 git 对象（`git diff --no-renames -U0 BASE HEAD`），与评审输入同源。

# --- 零上下文 diff → 变更行集合（stdin = diff 文本 → stdout = JSON）---
# 输出形态：{"src/app.py":[[30,31],[45,45]], "docs/x.md":[]}
#   - 键 = 本次变更中**新文件侧存在**的文件路径（相对仓库根）
#   - 值 = 该文件新增/修改行的行号区间（闭区间，升序按 diff 出现次序）
#   - 值为 `[]`：文件确实变了但没有新文件侧的新增行（纯删除行的改动）→ 无处可挂行内评论
#   - 被删除的文件、二进制文件不出现在键里：新文件侧没有可评论的行
#     （P1-02 实测「只能对新文件侧的行评论」，被删除行的问题只能进折叠区）
#
# 解析要点（都是 git 真实输出里存在、且容易解析错的形态）：
#   ① 正文行可能与文件头逐字节同形：新文件里一行 `++ b/evil.py` 在 diff 里就是 `+++ b/evil.py`。
#      因此「一个文件段内出现第一个 @@ 之后不再认 ---/+++ 头」，段边界用 `^diff --git ` 判定
#      （正文行永远带 +/-/空格前缀，不可能顶到行首的 `diff --git `、`@@ `）。
#   ② 路径含空格/引号/控制字符时 git 用 C 风格转义并整体加引号（`+++ "b/q\"uote.py"`），必须还原；
#      非 ASCII 由调用方的 `-c core.quotePath=false` 保证不转义，八进制转义仍作兜底还原。
#   ③ `@@ -1,2 +3,4 @@` 的新侧计数为 0（`+0,0` / `+4,0`）表示纯删除 hunk，不贡献任何行号。
#      省略计数（`@@ -5 +5 @@`）等价于计数 1。
#   ④ `\ No newline at end of file` 行既不是头也不是 hunk，天然被忽略。
#   ⑤ 还原后的路径可能含换行/Tab/0x1f 等控制字符（git 只对它们做 C 转义，core.quotePath=false 不例外）。
#      awk → jq 的中间流按行切分，路径若原样进入，一个 `x\nsrc/untouched.py` 就会被切成两条记录，
#      第二条恰好是「MR 没碰过的文件 + 攻击者选的行号」（票 09）。所以 awk 侧先把路径 JSON 编码，
#      每条记录是一行 `{"p":…,"s":N,"e":N}`，jq 用 fromjson 解，路径里任何字节都构不成记录边界。
# LC_ALL=C：按字节处理，diff 里的无效 UTF-8 字节不会让 awk 罢工（与 review_clean_text 同理）。
review_changed_lines() {
  # awk 的 rc 必须显式检查，不能依赖调用方开了 pipefail：没开时 awk 的 exit 3 会被 jq 的 rc 0 吞掉，
  # 而失败发生在流中间时前面的文件已经写出去了——那就是「部分变更行集合 + 成功返回」，
  # 行内评论照发、少掉的文件全静默进「未定位」。所以先落盘、验 rc，再交给 jq。
  local _rcl_raw _rcl_rc=0
  _rcl_raw=$(mktemp) || return 1
  LC_ALL=C awk '
    # --- git 的 C 转义 → JSON 字符串字面量，一次翻译到位 ---
    # 刻意**不**先还原成裸控制字节再重新编码：那条路要维护两张必须与 git quote.c 逐项一致的表，
    # 漏一项就悄悄错——`\a` 曾被「丢反斜杠留字母」还原成 `a`，于是 `src/<BEL>pp.py` 变成
    # `src/app.py`（一个 MR 没碰过的文件），行内评论能挂到它任意行上（票 09 复审）。
    # git quote.c 输出的全集：\a \b \f \n \r \t \v \" \\ 与 \NNN 八进制。表外转义一律硬失败。
    function jesc(o) { return sprintf("\\u%04x", o) }
    function cq2json(s,   body, out, i, c, n, oct, v) {
      body = substr(s, 2, length(s) - 2)   # 去掉两端引号
      out = ""; i = 1
      while (i <= length(body)) {
        c = substr(body, i, 1)
        if (c != "\\") { out = out jsonbyte(c); i++; continue }
        n = substr(body, i + 1, 1)
        if      (n == "a")  { out = out jesc(7);  i += 2 }
        else if (n == "b")  { out = out jesc(8);  i += 2 }
        else if (n == "t")  { out = out jesc(9);  i += 2 }
        else if (n == "n")  { out = out jesc(10); i += 2 }
        else if (n == "v")  { out = out jesc(11); i += 2 }
        else if (n == "f")  { out = out jesc(12); i += 2 }
        else if (n == "r")  { out = out jesc(13); i += 2 }
        else if (n == "\"") { out = out "\\\""; i += 2 }
        else if (n == "\\") { out = out "\\\\"; i += 2 }
        else if (n >= "0" && n <= "7") {
          oct = substr(body, i + 1, 3)
          if (length(oct) < 3) return "!"
          v = (substr(oct, 1, 1) + 0) * 64 + (substr(oct, 2, 1) + 0) * 8 + (substr(oct, 3, 1) + 0)
          out = out (v < 32 || v == 127 ? jesc(v) : jsonbyte(sprintf("%c", v)))
          i += 4
        }
        else return "!"                    # 表外转义：宁可整次评审失败，也不猜路径
      }
      return out
    }
    # 未加引号的路径里只可能有普通字节，但 `"`/`\` 仍要转义；控制字节走 \u00XX（防御性）
    function jsonbyte(c,   o) {
      if (c == "\"") return "\\\""
      if (c == "\\") return "\\\\"
      o = ord[c]
      if (o != "" && o < 32) return jesc(o)
      return c
    }
    function jsonstr(s,   out, i) {
      out = ""
      for (i = 1; i <= length(s); i++) out = out jsonbyte(substr(s, i, 1))
      return out
    }
    function rec(pj, s, e) { return "{\"p\":\"" pj "\",\"s\":" s ",\"e\":" e "}" }
    # `+++ ` 之后那一段 → JSON 编码后的真实路径（去掉 b/ 前缀）；"!" = 解析失败
    function newpath_json(raw,   p, t, q, i2) {
      p = raw
      if (substr(p, 1, 1) == "\"") {
        # 引号形式后面 git 还会补一个 TAB（实测：`+++ "b/has space\tand tab.py"<TAB>`）。
        # 不能按「去掉首尾各一个字符」剥引号——那样剥掉的是 TAB，键上多留一个 `"`：该文件的问题
        # 全判为未定位，而 `<真名>"` 也是合法文件名，攻击者再加一个那样命名的文件就能拿到别人的行号。
        # 结尾引号是**最后**一个 `"`（名字里的引号都已转义成 \"），所以按最后一个 `"` 截断是安全的。
        q = 0
        for (i2 = length(p); i2 >= 1; i2--) { if (substr(p, i2, 1) == "\"") { q = i2; break } }
        if (q < 2) return "!"
        p = cq2json(substr(p, 1, q))
        if (p == "!") return "!"
      }
      else { t = index(p, "\t"); if (t > 0) p = substr(p, 1, t - 1); p = jsonstr(p) }
      if (substr(p, 1, 2) == "b/") p = substr(p, 3)   # 前缀是字面 ASCII，转义不影响它
      return p
    }
    BEGIN { for (i = 1; i < 32; i++) ord[sprintf("%c", i)] = i; cur = ""; in_hunks = 0 }
    /^diff --git / { cur = ""; in_hunks = 0; next }
    !in_hunks && /^\+\+\+ / {
      raw = substr($0, 5)
      if (raw == "/dev/null") { cur = ""; next }
      cur = newpath_json(raw)
      if (cur == "!") {
        print "review_changed_lines: +++ 行里有无法按 git 转义表还原的路径，拒绝猜测（原始行：" $0 "）" > "/dev/stderr"
        exit 3
      }
      if (cur != "") print rec(cur, 0, 0)     # 文件出现过（即使没有可定位行）
      next
    }
    /^@@ / {
      in_hunks = 1
      if (cur == "") next
      if (match($0, /\+[0-9]+(,[0-9]+)?/) == 0) next
      spec = substr($0, RSTART + 1, RLENGTH - 1)
      ci = index(spec, ",")
      if (ci > 0) { start = substr(spec, 1, ci - 1) + 0; cnt = substr(spec, ci + 1) + 0 }
      else        { start = spec + 0; cnt = 1 }
      if (start < 1 || cnt < 1) next
      print rec(cur, start, start + cnt - 1)   # cur 已是编码后的形态，每个 hunk 直接复用
      next
    }
  ' > "$_rcl_raw" || _rcl_rc=$?
  if [[ "$_rcl_rc" != "0" ]]; then rm -f "$_rcl_raw"; return "$_rcl_rc"; fi
  jq -Rn '
      reduce (inputs | fromjson) as $r ({};
        if ($r.p | length) == 0 then .
        else .[$r.p] = ((.[$r.p] // []) + (if $r.s >= 1 and $r.e >= $r.s then [[$r.s, $r.e]] else [] end))
        end)' < "$_rcl_raw" || _rcl_rc=$?
  rm -f "$_rcl_raw"
  return "$_rcl_rc"
}

# --- 行内档位（CONTEXT.md「行内档位」）---
# quiet=P0+P1（默认）· balanced=全部 · critical=仅 P0。
# 非法取值由 review_plan_inline 回落 quiet 并记 warning（配错开关不该让评审失败，但必须留痕）。
REVIEW_INLINE_PROFILE_DEFAULT=quiet
REVIEW_MAX_INLINE_DEFAULT=10
_review_profile_levels() {
  case "$1" in
    quiet)    echo "P0 P1" ;;
    balanced) echo "P0 P1 P2" ;;
    critical) echo "P0" ;;
    *)        return 1 ;;
  esac
}

# --- 行内发布计划 ---
# 用法：review_plan_inline --json <review_validate 的输出> --changed-lines <review_changed_lines 的输出>
#                          [--profile quiet] [--max 10]
# stdout = 在输入 JSON 上追加以下字段：
#   inline_profile / max_inline            实际生效的档位与上限（非法取值已回落）
#   config_notice                          档位/上限被回落时的一句话说明（正常为空串），
#                                          由调用方接到汇总评论的 --notice 上（I10 失败可见）
#   inline: [问题…]                        本次要发成行内评论的问题（已排序、已截取）
#   folded: {profile,overflow,unlocated,failed}
#       profile   = 可定位但档位不覆盖其级别（quiet 下就是 P2）
#       overflow  = 可定位、档位覆盖，但超出 max_inline
#       unlocated = 不可定位（无 file/行号，或行号不在该文件的变更行集合内）
#       failed    = 行内发布失败（由 review_plan_apply_outcomes 回填）
#   inline_count / folded_count
# 每个问题都带 `idx`（在 findings 里的原始下标）：发布结果靠它回填，不靠内容比对。
# 排序：P0→P1→P2，同级按文件路径升序、再按起始行、再按原始次序（`idx` 兜底，保证逐字节确定）。
# rc 2 = 参数错误（缺参数 / 文件不可读）——绝不静默按默认值规划，那会让开关看起来生效了。
review_plan_inline() {
  local json="" changed="" profile="${REVIEW_INLINE_PROFILE_DEFAULT}" max="${REVIEW_MAX_INLINE_DEFAULT}" levels
  local notice=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json|--changed-lines|--profile|--max)
        [[ $# -ge 2 ]] || { echo "review_plan_inline: 参数 $1 缺少取值" >&2; return 2; }
        case "$1" in
          --json) json="$2" ;;
          --changed-lines) changed="$2" ;;
          --profile) profile="$2" ;;
          --max) max="$2" ;;
        esac
        shift 2 ;;
      *) echo "review_plan_inline: 未知参数：$1" >&2; return 2 ;;
    esac
  done
  [[ -n "$json" && -r "$json" ]] || { echo "review_plan_inline: --json 不可读：${json:-<未提供>}" >&2; return 2; }
  [[ -n "$changed" && -r "$changed" ]] || { echo "review_plan_inline: --changed-lines 不可读：${changed:-<未提供>}" >&2; return 2; }
  # 档位与上限来自流水线变量，配错不该让评审失败，但必须回落到默认值并留痕。
  # 留痕不能只在 stderr：阿里云侧开发者看不到流水线日志（I10），所以同时写进 config_notice，
  # 由调用方接到汇总评论的 --notice 上——否则「档位配错了」这件事在 MR 上完全看不出来，
  # 而评论看起来一切正常（只是覆盖范围不是运维以为的那个）。
  if ! levels=$(_review_profile_levels "$profile"); then
    echo "review_plan_inline: INLINE_PROFILE=${profile} 不是 quiet/balanced/critical，按默认 ${REVIEW_INLINE_PROFILE_DEFAULT} 处理" >&2
    notice="INLINE_PROFILE=${profile} 不是 quiet/balanced/critical，本次已按默认 ${REVIEW_INLINE_PROFILE_DEFAULT} 处理。"
    profile="$REVIEW_INLINE_PROFILE_DEFAULT"
    levels=$(_review_profile_levels "$profile")
  fi
  if ! [[ "$max" =~ ^[0-9]+$ ]]; then
    echo "review_plan_inline: MAX_INLINE_COMMENTS=${max} 不是非负整数，按默认 ${REVIEW_MAX_INLINE_DEFAULT} 处理" >&2
    notice="${notice}${notice:+ }MAX_INLINE_COMMENTS=${max} 不是非负整数，本次已按默认 ${REVIEW_MAX_INLINE_DEFAULT} 处理。"
    max="$REVIEW_MAX_INLINE_DEFAULT"
  fi
  jq -c --slurpfile changed "$changed" --argjson max "$max" \
        --arg profile "$profile" --arg levels "$levels" --arg notice "$notice" '
    def sevrank: {"P0":0,"P1":1,"P2":2}[.] // 3;
    def ordered: sort_by([(.severity | sevrank), (.file // ""), (.line_start // 0), .idx]);
    ($changed[0] // {}) as $cl
    | ($levels | split(" ")) as $elig
    | . as $root
    | [ ($root.findings // []) | to_entries[] | (.value + {idx: .key}) ] as $all
    | [ $all[]
        | . as $f
        | $f + { located:
            ( if ($f.file == null or $f.line_start == null) then false
              else (($cl[$f.file] // []) | any(.[0] <= $f.line_start and $f.line_start <= .[1]))
              end ) } ] as $ann
    # 注意 index() 里的 `.` 是 $elig 本身，所以级别必须先绑成变量再查（否则是「用字符串索引数组」）
    | def eligible: (.severity) as $s | (($elig | index($s)) != null);
      [ $ann[] | select(.located and eligible) | del(.located) ] as $cand0
    | ($cand0 | ordered) as $cand
    | ($cand[0:$max]) as $inline
    | ($cand[$max:]) as $overflow
    | [ $ann[] | select(.located and (eligible | not)) | del(.located) ] as $prof
    | [ $ann[] | select(.located | not) | del(.located) ] as $unloc
    | $root + {
        inline_profile: $profile,
        max_inline: $max,
        config_notice: $notice,
        inline: $inline,
        folded: { profile: ($prof | ordered), overflow: $overflow,
                  unlocated: ($unloc | ordered), failed: [] },
        inline_count: ($inline | length),
        folded_count: (($prof | length) + ($overflow | length) + ($unloc | length))
      }' "$json"
}

# --- 发布结果回填 ---
# 用法：review_plan_apply_outcomes <计划 JSON> <结果 JSON>
#   结果 JSON = [{"idx":0,"outcome":"created"|"existing"|"failed"}, …]
#   created  = 本次新发出的行内评论
#   existing = 同一处已有本评审员的行内评论（区间去重命中）→ 仍算「已标注在对应行」（spec §4.5 第 5 步「跳过并计数」）
#   failed   = 没发出去 → 必须移进折叠区，否则这条问题在 MR 上一条都看不到（违反 I4「同一问题只出现一次」）
# **缺失的结果按 failed 处理**（fail-closed）。这里绝不能按 created 兜底：调用方给每一条 inline 项
# 都会记一个结果，所以「查不到结果」只有一种含义——结果文件出了问题。此时按 created 兜底会把
# 一条根本没发出去的 P0 算成「已标注在对应行」，而 INLINE_COMMENT=1 的汇总不展开问题清单，
# 那条 P0 就在 MR 上彻底消失了。按 failed 兜底最坏只是让一条已经发出去的评论在折叠区里重复一次。
review_plan_apply_outcomes() {
  local plan="$1" outcomes="$2"
  [[ -r "$plan" ]] || { echo "review_plan_apply_outcomes: 计划文件不可读：${plan}" >&2; return 2; }
  [[ -r "$outcomes" ]] || { echo "review_plan_apply_outcomes: 结果文件不可读：${outcomes}" >&2; return 2; }
  jq -c --slurpfile oc "$outcomes" '
    (($oc[0] // []) | map(select(type == "object" and (.idx | type) == "number"))
                    | map({key: (.idx | tostring), value: (.outcome // "failed")}) | from_entries) as $o
    | def status(f): ($o[(f.idx | tostring)] // "failed");
      (.inline // []) as $in
    | [ $in[] | select(status(.) != "failed") ] as $kept
    | [ $in[] | select(status(.) == "failed") ] as $failed
    | .inline = $kept
    | .folded.failed = $failed
    | .inline_count = ($kept | length)
    | .folded_count = (((.folded.profile // []) | length) + ((.folded.overflow // []) | length)
                       + ((.folded.unlocated // []) | length) + ($failed | length))' "$plan"
}

# --- 问题指纹（spec §4.5 第 5 步的原始设计；实测澄清后只作信息用途）---
# 指纹 = sha1(file + line + title)。三段之间插 \x1f 分隔符：不分隔时
# ("a.py", 1, "2x") 与 ("a.py", 12, "x") 会撞成同一个指纹，两条不同的问题互相顶掉。
# 2026-09-03 真实验收（demo-app MR #2 重跑）：模型第二次给的标题全部不同、行号漂移 1 行
# （20→21、37→36）、一条问题拆成两条（L14 与 L22），指纹全部不命中，行内评论 4 → 9。
# 去重判定因此改为 review_inline_overlaps 的区间匹配；指纹仍写进标记，方便人工核对，不再参与判定。
# sha1sum（GNU）与 shasum（macOS）二选一；两者都没有时 rc 1——调用方仍把它当硬依赖：
# 标记里没有指纹就没法把「本评审员发的」与人工评论区分开（标记的存在本身就是身份证据之一）。
review_fingerprint() {
  local payload
  payload=$(printf '%s\037%s\037%s' "${1-}" "${2-}" "${3-}")
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha1sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$payload" | shasum -a 1 | cut -d' ' -f1
  else
    echo "review_fingerprint: 缺少 sha1sum/shasum，算不出行内评论指纹" >&2
    return 1
  fi
}

# --- 行内评论正文里的隐藏标记 ---
# 新格式：<!-- kiro-inline:<sha1> L<start>-<end> sev=<P0|P1|P2> -->
# 旧格式：<!-- kiro-inline:<sha1> -->（票 04 首版发出的评论；只读兼容，见 review_inline_existing_ranges）
# 为什么把区间写进标记而不是「从正文里反解首行的 P0 · 标题（L起–L止）」：反解要依赖渲染格式，
# 任何模板微调都会让去重静默失效、在同一行上堆重复评论。标记是稳定的解析契约（与汇总评论的
# kiro-history 同一思路）。模型文本里的 `<!--` 已被 _sanitize_md 转义，伪造不出这一行。
# 区间是去重的**主键**（旧格式退回 line_number + 标题区间），级别与指纹只作信息用途。
REVIEW_INLINE_MARKER_PREFIX="<!-- kiro-inline:"
REVIEW_INLINE_MARKER_SUFFIX=" -->"
# jq（Oniguruma）命名捕获；可选组缺席时 start/end/sev 为 null = 旧格式。
# 行号位数限 1–7：行内评论在 Codeup 上是人可编辑的（与 REVIEW_MARKER_LINE_RE 限 run 位数同理），
# 改成天文数字的标记宁可整条不认（重发一条）也不能让它压住整个文件。
REVIEW_INLINE_MARKER_RE='^<!-- kiro-inline:(?<fp>[0-9a-f]{40})(?: L(?<start>[0-9]{1,7})-(?<end>[0-9]{1,7}) sev=(?<sev>P[0-2]))? -->[[:space:]]*$'
# 旧格式评论只能从首行标题里的「（L起–L止）」还原结束行与级别（review_render_inline_body 渲染的形态，
# 破折号是 U+2013）。首行有两种历史形态，都要认（票 11）：
#   · bff99dd 起 `### P0 · 标题（L起–L止）`（真实 demo MR 上的旧格式评论都是这一种，见 fixtures/inline/real-rerun）；
#   · 5a1a9e3（2026-09-04 10:54）起 `**P0 · 标题（L起–L止）**`。sev 写进标记是更早的 e534631（同日 00:19），
#     所以脚本自己**没有**发出过「加粗首行 + 旧格式标记」的评论；会落到这个形态的是被人改过首行、或从加粗
#     评论里复制出来的旧格式标记。原先正则只认 `### `，这种首行的级别解析成 null——级别未知本身由
#     review_inline_overlaps 兜底（不能压制），这里解析对了才能让去重继续生效（旧 P0 仍压同一处的 P0/P1/P2），
#     否则同一处每次重跑都多一条重复评论。
REVIEW_INLINE_TITLE_RANGE_RE='（L(?<s>[0-9]{1,7})–L(?<e>[0-9]{1,7})）(?:\*\*)?[[:space:]]*$'
REVIEW_INLINE_TITLE_SEV_RE='^(?:### |\*\*)(?<sev>P[0-2]) · '
# 读回的区间宽度上限（行）。区间来自模型给的 line_end 或人可编辑的标记/标题：一条「（L1–L800）」
# 不设上限就能把整个文件后续所有 P0/P1 都压掉。去重要找的是「同一处」，起点附近几十行足够；
# 超出的部分截掉（end = start + 上限），起点不动。
REVIEW_INLINE_MAX_RANGE_SPAN=50
# 用法：review_render_inline_marker <指纹> <起始行> <结束行（可空/null → 同起始行）> <级别>
# rc 2 = 参数不合形。行内评论必然有锚点行，所以起始行是必填：没有它标记就写不出区间，
# 下一次评审只能退回 line_number 去猜——那正是这次要修掉的路径。
review_render_inline_marker() {
  local fp="${1-}" start="${2-}" end="${3-}" sev="${4-}" t
  [[ "$fp" =~ ^[0-9a-f]{40}$ ]] || { echo "review_render_inline_marker: 指纹不是 40 位十六进制：${fp}" >&2; return 2; }
  [[ "$start" =~ ^[0-9]+$ ]] || { echo "review_render_inline_marker: 起始行不是整数：${start:-<空>}" >&2; return 2; }
  [[ -z "$end" || "$end" == "null" ]] && end="$start"
  [[ "$end" =~ ^[0-9]+$ ]] || { echo "review_render_inline_marker: 结束行不是整数：${end}" >&2; return 2; }
  [[ "$sev" =~ ^P[0-2]$ ]] || { echo "review_render_inline_marker: 级别不是 P0/P1/P2：${sev:-<空>}" >&2; return 2; }
  if (( end < start )); then t="$start"; start="$end"; end="$t"; fi
  printf '%s%s L%s-%s sev=%s%s\n' "$REVIEW_INLINE_MARKER_PREFIX" "$fp" "$start" "$end" "$sev" "$REVIEW_INLINE_MARKER_SUFFIX"
}

# --- 内部：把一条评论解析成 {id, file, start, end, sev, fp}（jq 片段）---
# 区间来源，按优先级：
#   ① 新格式标记里的 L<start>-<end>；
#   ② 旧格式：line_number 作起点（数字或数字字符串都认——接口形态在不同接口间不一致），
#      再尝试从首行标题解析「（L起–L止）」得到终点；解析不到就当单行；
#   ③ 旧格式又没有 line_number：标题里有「（L起–L止）」就用它——那是我们自己的渲染器按 line_start/line_end
#      写出来的，不是猜；连它也没有 → start/end 为 null（作为去重候选会被丢掉，作为草稿仍列出 id）。
# 宽度超过 REVIEW_INLINE_MAX_RANGE_SPAN 的区间截到上限（起点不动）。
# 文件路径：实测响应是 camelCase 的 filePath（P1-06），同时带一个恒为 null 的 file_path；两者都认。
# 级别：新格式取标记里的 sev，旧格式从首行「### P0 · 」解析，都没有 → null。
_REVIEW_JQ_INLINE_RANGE='
  def str(v): if (v | type) == "string" then v else "" end;
  def author_name: if (.author | type) == "object" then str(.author.username) else "" end;
  def lnum(v): if (v | type) == "number" then (v | floor)
               elif ((v | type) == "string") and (v | test("^[0-9]{1,7}$")) then (v | tonumber)
               else null end;
  def marker: [ str(.content) | split("\n")[] | capture($re) ] | (.[0] // null);
  def first_line: (str(.content) | split("\n")[0]);
  def title_range: (first_line | capture($tre) // null)
                   | if . == null then null else {s: (.s | tonumber), e: (.e | tonumber)} end;
  def title_sev: (first_line | capture($sre) // null) | if . == null then null else .sev end;
  def file_of: (str(.filePath)) as $a | if $a != "" then $a else str(.file_path) end;
  def as_range:
    (marker) as $m
    | select($m != null)
    | (title_range) as $t
    | (if $m.start != null then ($m.start | tonumber)
       elif lnum(.line_number) != null then lnum(.line_number)
       elif $t != null then $t.s
       else null end) as $s0
    | (if $m.end != null then ($m.end | tonumber)
       elif $s0 == null then null
       elif $t != null then $t.e
       else $s0 end) as $e0
    | (if ($s0 != null and $e0 != null and $e0 < $s0) then [$e0, $s0] else [$s0, $e0] end) as $se
    | { id: str(.comment_biz_id),
        file: (file_of | if . == "" then null else . end),
        start: $se[0],
        end: (if $se[1] == null then null elif ($se[1] - $se[0]) > $span then ($se[0] + $span) else $se[1] end),
        sev: ($m.sev // title_sev),
        fp: $m.fp };
'

# --- 内部：从 ListMergeRequestComments 响应里读回本评审员的行内评论（stdin）---
# 用法：_review_inline_ranges <机器人账号用户名或空串> existing|draft → stdout 紧凑 JSON 数组
#   [{id, file, start, end, sev, fp}, …]；任何解析失败都输出 `[]`（仍是合法 JSON，调用方直接 jq length）。
# 两种模式共用同一套前置过滤（对象 / 行内类型 / 作者 / 带标记），只在状态与最终筛选上不同：
#   existing：非 DELETED/DRAFT、非 draft:true、未过期，且必须还原得出「文件 + 区间」（参与去重）
#   draft   ：draft:true 或 state=DRAFT，且有 biz_id（清理孤儿草稿 + 提交后回读；out_dated 不参与——草稿无论新旧都要清理）
# 作者过滤：给了用户名就只认本机器人发的（别人复制一条带标记的评论不能压掉本评审员的问题）；
# 用户名未知时退化为「只按标记」——重跑重复是必然会发生的伤害，而伪造标记需要一个
# 已认证的 MR 参与者主动发评论（可见、可追溯），两害相权取轻，并由调用方打警告提示配置。
# 状态过滤在脚本侧做：接口只实测过 comment_type 过滤（P1-06），state 参数名未实测，
# 凭记忆传一个可能 400 的参数会让整条去重通路挂掉。
# 状态判定用**排除清单**（排除 DELETED 与 DRAFT）而不是许可清单（只认 OPENED）：实测只见过这三个取值，
# 万一 Codeup 对「已被开发者解决」的行内评论返回别的状态（如 RESOLVED），许可清单会漏收它，
# 于是每次重跑都在同一行上再发一条（违反 I6 幂等）。与 review_select_prior_comment 的判定一致。
# out_dated 的评论一律**不算**已发出：它绑的是被取代的旧版本，Codeup 会把它折叠/隐藏在 diff 视图里。
# 把它算作已发出，就等于汇总里那句「已标注在「文件改动」对应行」在说谎——读者在当前 diff 上看不到它。
# 重跑（没有新推送）时 out_dated 为 false，去重照常生效，A3「重跑不重复」不受影响。
# 字段类型守卫与 review_select_prior_comment 同理：任何一条评论字段不合形都不能废掉整批。
_review_inline_ranges() {
  local bot="${1-}" mode="${2-}" out
  case "$mode" in
    existing|draft) ;;
    *) echo "_review_inline_ranges: 模式必须是 existing 或 draft：${mode:-<空>}" >&2; echo '[]'; return 2 ;;
  esac
  out=$(jq -c --arg bot "$bot" --arg mode "$mode" --arg re "$REVIEW_INLINE_MARKER_RE" \
           --arg tre "$REVIEW_INLINE_TITLE_RANGE_RE" --arg sre "$REVIEW_INLINE_TITLE_SEV_RE" \
           --argjson span "$REVIEW_INLINE_MAX_RANGE_SPAN" \
           "${_REVIEW_JQ_INLINE_RANGE}"'
    (if type == "object" then (.result // []) else . end)
    | (if type == "array" then . else [] end)
    | map(select(type == "object"))
    | map(select(str(.comment_type) == "" or str(.comment_type) == "INLINE_COMMENT"))
    | (if $mode == "existing" then
         map(select((str(.state) | ascii_upcase) as $s | $s != "DELETED" and $s != "DRAFT"))
         | map(select((.draft == true) | not))
         | map(select((.out_dated == true) | not))
       else
         map(select(.draft == true or (str(.state) | ascii_upcase) == "DRAFT"))
       end)
    | map(select(if $bot == "" then true else author_name == $bot end))
    | [ .[] | as_range
        | select(if $mode == "existing" then (.file != null and .start != null and .end != null)
                 else ((.id | length) > 0) end) ]' 2>/dev/null) \
    || out=""
  [[ -n "$out" ]] && printf '%s\n' "$out" || echo '[]'
}

# --- 从 MR 现有行内评论里读回「文件 + 行区间」（去重候选）---
# 用法：review_inline_existing_ranges <机器人账号用户名或空串> < 列表响应 → JSON 数组
review_inline_existing_ranges() { _review_inline_ranges "${1-}" existing; }

# --- 本评审员留在 MR 上的行内评论**草稿** ---
# 用法：review_inline_draft_ranges <机器人账号用户名或空串> < 列表响应 → JSON 数组（含 fp，孤儿草稿按指纹精确匹配）
# 草稿只有机器人自己看得见，正常流程里不会留下——留下就说明上一次运行在「建好草稿」与
# 「一次提交」之间断了。两处要用它：① 发布前按**指纹精确匹配**清理孤儿草稿（刻意不用区间匹配：
# 同一 MR 上可能有另一次运行正在进行中，按区间会把它刚建好的草稿删掉；按指纹只在同一模型输出重放时命中，
# 命不中的孤儿草稿只有机器人自己看得见，无害）；② 一次提交之后回读，仍是草稿的按发布失败处理，只看 id。
review_inline_draft_ranges() { _review_inline_ranges "${1-}" draft; }

# --- 去重判定：区间匹配（协调者裁决 2026-09-03，取代 spec Q8 的「文件+行+内容指纹」）---
# 同一文件、且 [start, end] 与某条已有评论的区间重叠，或两区间相距 ≤ REVIEW_INLINE_DEDUP_TOLERANCE 行
# → 视为同一问题。容差 2 行来自实测漂移幅度（1 行）留一倍余量；标题不参与判定（模型每次措辞都不同）。
# 级别门槛：已有评论只压制**级别不高于它**的新问题（P0 压 P0/P1/P2，P1 压 P1/P2，P2 只压 P2）——
# 否则同一处一条旧 P2 就能让重跑时新出现的 P0 从 MR 上消失（outcome=existing 留在 inline，而
# INLINE_COMMENT=1 的汇总不展开 inline）。
# 调用方不给新问题级别 → 不设门槛。已有评论的级别**解析不出**（标记是旧格式、首行又被人改过）→ 按最严处理：
# 它不能压制任何级别（票 11）。原先这种情况按「不设门槛」处理，等于一条来历不明的旧评论能吞掉同一处新出现的
# P0；代价是这种评论旁边会多出一条重复评论——与 rc 2 的取舍一致：宁可重复，绝不吞掉 P0。
# 代价是同一处相邻两行上的两条**不同**、级别相同的问题在重跑时会被并成一条——接受：MR 上已经有一条
# 指着那里，读者能看到；反过来不并的话，每次重跑都在同一处多出一组措辞不同的重复评论（真实验收 4 → 9）。
# 用法：review_inline_overlaps <区间 JSON 文件> <文件路径> <起始行> [结束行] [新问题级别 P0|P1|P2]
#   stdout = 命中的已有评论 id（每行一个，缺 id 打 `?`）；rc 0 命中 / rc 1 未命中 / rc 2 参数错误。
# rc 2 与 rc 1 必须分开：调用方对 rc 2 只打警告并照常发出（宁可重复，绝不因为一个坏文件吞掉一条 P0）。
REVIEW_INLINE_DEDUP_TOLERANCE=2
review_inline_overlaps() {
  local ranges="${1-}" file="${2-}" start="${3-}" end="${4-}" sev="${5-}" hits t
  [[ -n "$ranges" && -r "$ranges" ]] || { echo "review_inline_overlaps: 区间文件不可读：${ranges:-<空>}" >&2; return 2; }
  [[ -n "$file" ]] || { echo "review_inline_overlaps: 文件路径为空" >&2; return 2; }
  [[ "$start" =~ ^[0-9]+$ ]] || { echo "review_inline_overlaps: 起始行不是整数：${start:-<空>}" >&2; return 2; }
  [[ -z "$end" || "$end" == "null" ]] && end="$start"
  [[ "$end" =~ ^[0-9]+$ ]] || { echo "review_inline_overlaps: 结束行不是整数：${end}" >&2; return 2; }
  [[ -z "$sev" || "$sev" =~ ^P[0-2]$ ]] || { echo "review_inline_overlaps: 级别不是 P0/P1/P2：${sev}" >&2; return 2; }
  if (( end < start )); then t="$start"; start="$end"; end="$t"; fi
  hits=$(jq -r --arg f "$file" --argjson s "$start" --argjson e "$end" --arg sev "$sev" \
            --argjson tol "$REVIEW_INLINE_DEDUP_TOLERANCE" '
    def rank: {"P0": 0, "P1": 1, "P2": 2}[.] // null;
    (if type == "array" then . else [] end)
    | .[]
    | select(type == "object" and .file == $f and (.start | type) == "number" and (.end | type) == "number")
    | select(($s - .end) <= $tol and (.start - $e) <= $tol)
    | select($sev == "" or ((.sev | type) == "string" and ((.sev | rank) != null) and ((.sev | rank) <= ($sev | rank))))
    | (.id // "") | if (type == "string" and length > 0) then . else "?" end' "$ranges" 2>/dev/null) \
    || { echo "review_inline_overlaps: 区间文件不是合法 JSON：${ranges}" >&2; return 2; }
  [[ -n "$hits" ]] || return 1
  printf '%s\n' "$hits"
}

# --- 一条行内评论的正文（spec §4.4）---
# 用法：review_render_inline_body <单条问题的 JSON 文件> <短 sha> <指纹>
# 模板：
#   **{P0} · {title}[（L{起}–L{止}）]**
#   <!-- kiro-inline:{指纹} L{起}-{止} sev={P0} -->
#
#   {body}
#
#   **修复建议**
#
#   {fix}
#
#   — Kiro 评审 · 提交 `{sha}`
# 多行区间在标题后附 `（L起–L止）`，锚点仍取 line_start（Codeup 的行内评论只能锚一行）。
# 首行用加粗而不是标题：Codeup 不渲染 `###`，而行内评论卡片很窄，标题级别本来也没有意义。
# body/fix 已在 review_validate 里过 _sanitize_md：这里不再二次转义（会把代码块弄坏）。
review_render_inline_body() {
  local item="$1" sha="$2" fp="$3" sev title body fix ls le
  [[ -r "$item" ]] || { echo "review_render_inline_body: 问题 JSON 不可读：${item}" >&2; return 2; }
  [[ -n "$sha" ]] || { echo "review_render_inline_body: 缺少短 sha" >&2; return 2; }
  [[ "$fp" =~ ^[0-9a-f]{40}$ ]] || { echo "review_render_inline_body: 指纹不是 40 位十六进制：${fp}" >&2; return 2; }
  jq -e 'type == "object" and (.severity | type) == "string" and (.title | type) == "string"' "$item" >/dev/null 2>&1 \
    || { echo "review_render_inline_body: 问题 JSON 缺 severity/title：${item}" >&2; return 2; }
  # 行内评论必然有锚点行：没有 line_start 的问题是未定位问题，根本不该走到这里；
  # 而标记里写不出区间，下一次评审就只能退回 line_number 去猜。
  jq -e '(.line_start | type) == "number"' "$item" >/dev/null 2>&1 \
    || { echo "review_render_inline_body: 问题 JSON 缺 line_start（行内评论必然有锚点行）：${item}" >&2; return 2; }
  sev=$(jq -r '.severity' "$item")
  title=$(jq -r '.title' "$item")
  body=$(jq -r '.body // ""' "$item")
  fix=$(jq -r '.fix // ""' "$item")
  ls=$(jq -r '.line_start // ""' "$item")
  le=$(jq -r '.line_end // ""' "$item")
  if [[ -n "$ls" && -n "$le" && "$le" != "$ls" ]]; then
    title="${title}（L${ls}–L${le}）"
  fi
  printf '**%s · %s**\n' "$sev" "$title"
  review_render_inline_marker "$fp" "$ls" "$le" "$sev" || return 2
  echo ""
  if [[ -n "$body" ]]; then printf '%s\n' "$body"; else echo "（评审员未给出说明）"; fi
  if [[ -n "$fix" ]]; then
    echo ""
    echo "**修复建议**"
    echo ""
    printf '%s\n' "$fix"
  fi
  echo ""
  printf -- '— Kiro 评审 · 提交 `%s`\n' "$sha"
}

# --- 评审标记（原地更新的定位依据）---
# 形态必须与 _review_render_header 渲染出的那一行严格一致：
#   <!-- kiro-review:{sha} run:{n} -->
# 同一条正则同时给 jq（Oniguruma）与 grep/sed（POSIX ERE）用，两个引擎都支持这里用到的字符类。
# 注意：jq 的 ^/$ 默认锚定整个字符串而不是行，所以在 jq 里必须先 split("\n") 再逐行 match
# （见 review_select_prior_comment）。
# run 限 1–9 位：汇总评论在 Codeup 上是人可编辑的，`run:99999999999999999999` 这种手改值会让
# `$((prior_run + 1))` 静默溢出成负数、渲染出一个再也匹配不上的标记。位数上限让这类值直接不算候选
# （于是新建一条正常的汇总），而不是把 run 号搞坏。
REVIEW_MARKER_LINE_RE='^<!-- kiro-review:[0-9a-zA-Z._-]+ run:([0-9]{1,9}) -->[[:space:]]*$'

# --- 历次评审记录 ---
# 汇总评论里嵌一行隐藏 JSON 作为机器可读的历次记录，「历次评审」表只是它的人类可读投影：
#   <!-- kiro-history:[{"run":1,"sha":"90fcb05","verdict":"MERGE","status":"","p0":0,"p1":1,"p2":2}] -->
# 为什么不反解表格：表格要把结论中文化、要把三个计数合成一列，反解需要一套反向映射，
# 任何渲染微调都会让历史读不出来。隐藏 JSON 与渲染解耦，是稳定的解析契约。
# status：""=正常评审；failed=评审未完成；degraded=结构化解析失败（此时计数为 null）。
# 注入面：这一行会被下一次评审读回来，所以写入时对每个字符串字段做许可清单过滤
# （review_history_append 的 safe()），保证正文里不可能出现 `-->` 而提前闭合注释。
REVIEW_HISTORY_PREFIX="<!-- kiro-history:"
REVIEW_HISTORY_SUFFIX=" -->"
# 行数上限：历史无限增长会把汇总评论撑到 Codeup 的长度上限
REVIEW_HISTORY_MAX=20

# 用法：review_parse_history <旧评论正文文件> → stdout = JSON 数组（读不到/不合法一律 []）
# 永不失败：拿不到历史只会让「历次评审」表少几行，不该拖垮评审。
review_parse_history() {
  local file="$1" n line json out
  [[ -r "$file" ]] || { echo '[]'; return 0; }
  n=$(grep -c "^${REVIEW_HISTORY_PREFIX}" "$file" 2>/dev/null || true)
  n=${n:-0}
  if [[ "$n" != "1" ]]; then
    [[ "$n" == "0" ]] \
      || echo "review_parse_history: 历史标记出现 ${n} 次（预期 1），无法判定哪一份是自己的，忽略历史" >&2
    echo '[]'; return 0
  fi
  line=$(grep "^${REVIEW_HISTORY_PREFIX}" "$file" | head -1)
  # 剥掉行尾**所有**空白，不只是 \r：评审标记的正则以 [[:space:]]*$ 结尾，所以行尾多一个空格或
  # 制表符（Codeup 网页编辑很常见）的评论**照样**会被选中并被原地更新；而这里若剥不掉 " -->"
  # 后缀，历史就会静默清空，那条评论被 PUT 成只剩本次一行——「历次评审」表悄悄丢掉全部历史。
  # 容忍度必须与选择器一致。
  line=$(printf '%s' "$line" | LC_ALL=C sed -E 's/[[:space:]]+$//')
  json=${line#"$REVIEW_HISTORY_PREFIX"}
  json=${json%"$REVIEW_HISTORY_SUFFIX"}
  # 必须 -s 读成数组并要求「恰好一个 JSON 值」：
  #   ① payload 尾巴上有多余字节时，jq 会先输出一份合法结果、再报错退出，而 `|| echo '[]'` 是
  #      **追加**不是替换——下游就拿到两个 JSON 值，历次表会渲染出重复行与断成两行的 <summary>；
  #   ② payload 为空（`<!-- kiro-history: -->`）时，不带 -s 的 jq 无输入即无输出且退出码 0，
  #      本函数会返回空串而不是 []，把「拿不到历史」升级成整条评论渲染失败。
  out=$(printf '%s' "$json" | jq -c -s '
          if length == 1 and (.[0] | type == "array")
          then [.[0][] | select(type == "object" and (.run | type) == "number")]
          else [] end' 2>/dev/null) || out=""
  if [[ -z "$out" ]]; then
    echo "review_parse_history: 历史标记内不是恰好一个 JSON 数组，忽略历史" >&2
    out='[]'
  fi
  printf '%s\n' "$out"
}

# 用法：review_history_append <历史 JSON 文件或 -> <run> <sha> <verdict> <status> <p0> <p1> <p2>
#   p0/p1/p2 传 "-"（或任何非数字）表示未知 → 记为 null
# stdout = 追加本次记录后的 JSON 数组（只保留最近 REVIEW_HISTORY_MAX 行）
review_history_append() {
  local hist="$1" run="$2" sha="$3" verdict="$4" status="$5" p0="$6" p1="$7" p2="$8" base
  if [[ "$hist" == "-" || ! -r "$hist" ]]; then base='[]'; else base=$(cat "$hist"); fi
  printf '%s' "$base" | jq -c --argjson max "$REVIEW_HISTORY_MAX" --arg deny "$REVIEW_CELL_DENY_CHARS" \
    --arg run "$run" --arg sha "$sha" --arg verdict "$verdict" --arg status "$status" \
    --arg p0 "$p0" --arg p1 "$p1" --arg p2 "$p2" "${_REVIEW_JQ_CELL}"'
    def num(v): if (v | test("^[0-9]+$")) then (v | tonumber) else null end;
    def numj(v): if (v | type) == "number" then (v | floor) else null end;
    # 字符许可清单 = REVIEW_CELL_DENY_CHARS + 控制字符（定义与理由见那里）：过滤后的取值不可能构成
    # `-->`／`<!--`，历次表的单元格不会被撑出幻影列，\x1f 字段分隔不会错位。非 ASCII 一律保留（中文结论要能显示）。
    def safe(v; n): (_cell_strip((v // "") | tostring) | .[0:n]);
    # 旧记录同样过一遍过滤与字段规范化：汇总评论在 Codeup 上是人可编辑的，隐藏 JSON 里的取值
    # 不能当作可信输入（只做「追加时过滤新行」的话，被手工改过的历史会原样渲染进表格）。
    (if type == "array" then . else [] end)
    | map(select(type == "object" and (.run | type) == "number")
          | { run: (.run | floor), sha: safe(.sha; 40), verdict: safe(.verdict; 40),
              status: safe(.status; 16), p0: numj(.p0), p1: numj(.p1), p2: numj(.p2) })
    + [{ run: (num($run) // 1), sha: safe($sha; 40), verdict: safe($verdict; 40),
         status: safe($status; 16), p0: num($p0), p1: num($p1), p2: num($p2) }]
    | .[-$max:]'
}

# --- 定位「本评审员上一次的汇总评论」（stdin = ListMergeRequestComments 响应）---
# 用法：review_select_prior_comment <机器人账号用户名或空串>
#   rc 0 → stdout = 选中的评论对象（compact JSON，额外带 run 字段＝从评审标记解析出的次数）
#   rc 1 → 没有候选（首次评审，或旧评论已被人删除）
#   rc 3 → 有候选，但机器人账号用户名未知 → **不得**原地更新，调用方新建（见下）
#
# 判定 = 作者用户名匹配 **且** 正文含本集成包渲染的评审标记（票 03 验收项）。缺任何一半都不行：
#   只看作者 → 机器人发的行内评论/状态评论会被当成汇总改掉；
#   只看标记 → 有人把整条报告原文复制一份留档，就会去改别人的评论。
# 机器人用户名只接受两个来源：① CODEUP_BOT_USERNAME 显式配置（推荐）；② 令牌身份接口
# （spec §4.7.1 P1-00 实测 403，生产上大概率不可用）。
# **刻意不再**用「带评审标记的评论作者」作为更新依据：评审标记是明文可复制的，任何 MR 参与者
# 发一条正文含 `<!-- kiro-review:… run:1 -->` 的评论，就能把本评审员的报告引到他自己那条评论上
# （覆盖其内容，且他之后仍可编辑我们的报告）。「每评审员至多一条汇总」不能建立在可伪造的推断上。
# 用户名未知时推断值仍会算出来，但**只用于日志提示**（告诉运维该把哪个值配进 CODEUP_BOT_USERNAME）。
# 多条候选时取 run 最大的那条（上一次更新失败退回新建会留下两条，此后应继续更新最新那条）。
review_select_prior_comment() {
  local bot="${1-}" input out status inferred
  input=$(cat)
  out=$(printf '%s' "$input" | jq -c --arg bot "$bot" --arg re "$REVIEW_MARKER_LINE_RE" '
    # 字段类型守卫：响应形态只在一次探测里见过，不能假定每一行的每个字段都规整。
    # 任何一条评论里 .content 非字符串（split 报错）、.state 非字符串（ascii_upcase 报错）、
    # .author 非对象（索引字符串报错）都会让**整个** jq 程序失败 → 调用方按「未找到」处理 →
    # 这个 MR 从此每次评审都新建一条汇总。不合形的字段一律按缺省值处理，只影响那一行。
    def str(v): if (v | type) == "string" then v else "" end;
    def author_name: if (.author | type) == "object" then str(.author.username) else "" end;
    def marker_runs:
      [ (str(.content) | split("\n")[] | match($re) | .captures[0].string | tonumber) ];
    (if type == "object" then (.result // []) else . end)
    | (if type == "array" then . else [] end)
    | map(select(type == "object"))
    # content 必须是非空字符串才可能带评审标记
    | map(select((.content | type) == "string"))
    # comment_type 缺失或不合形 → 按 GLOBAL_COMMENT 处理（接口已按类型过滤过，这里只是纵深防御）
    | map(select(str(.comment_type) == "" or str(.comment_type) == "GLOBAL_COMMENT"))
    | map(select((str(.state) | ascii_upcase) != "DELETED"))
    # 只有布尔真才算草稿；其它取值按「不是草稿」处理
    | map(select((.draft == true) | not))
    | map(. + {_runs: marker_runs})
    # 一条评论里有两个评审标记时无法判定次数，不作为候选（与「契约标记必须唯一」同一个原则）
    | map(select((._runs | length) == 1))
    | map(. + {run: ._runs[0], _author: author_name} | del(._runs))
    | . as $cands
    | ([$cands[] | ._author] | unique) as $authors
    | if ($cands | length) == 0 then {status: "none"}
      elif $bot == "" then
        {status: "no-identity",
         inferred: (if ($authors | length) == 1 then $authors[0] else "" end),
         authors: $authors}
      else
        ([$cands[] | select(._author == $bot)] | sort_by(.run) | last) as $sel
        | if $sel == null then {status: "none"} else {status: "ok", comment: ($sel | del(._author))} end
      end' 2>/dev/null) \
    || { echo "review_select_prior_comment: 评论列表不是合法 JSON，按「未找到」处理" >&2; return 1; }
  status=$(printf '%s' "$out" | jq -r '.status // ""')
  case "$status" in
    ok)
      printf '%s' "$out" | jq -c '.comment'
      return 0 ;;
    no-identity)
      inferred=$(printf '%s' "$out" | jq -r '.inferred // ""')
      echo "review_select_prior_comment: 未配置 CODEUP_BOT_USERNAME、令牌身份接口也不可用，不以「带评审标记的评论作者」作为原地更新依据（评审标记可被任何 MR 参与者复制，那样就会把报告写进别人的评论）" >&2
      [[ -n "$inferred" ]] \
        && echo "review_select_prior_comment: 带评审标记的评论作者是 ${inferred}——若确认那是本评审员的机器人账号，把它配进 CODEUP_BOT_USERNAME 即可启用原地更新" >&2
      return 3 ;;
    *) return 1 ;;
  esac
}

# --- 内部：总体结论的中文化（CONTEXT.md 的「总体结论」词汇）---
_review_verdict_cn() {
  case "$1" in
    MERGE) echo "可合并" ;;
    MERGE_AFTER_FIX) echo "建议修改后合并" ;;
    DO_NOT_MERGE) echo "不建议合并" ;;
    "") echo "评审员未给出结论" ;;
    # 契约外的值原样带出：宁可评论上难看，也不能把评审员的结论静默改写成别的意思
    *) echo "$1（非契约取值）" ;;
  esac
}

# --- 内部：参数解析（两个渲染函数共用）---
# 解析结果写入 _RR_* 变量；未知参数或缺值 → rc 2（拼错参数不能静默按默认值渲染）。
_review_parse_render_args() {
  _RR_JSON=""; _RR_TEXT=""; _RR_SHA=""; _RR_SRC=""; _RR_DST=""; _RR_TS=""
  _RR_DIFF_NOTE=""; _RR_RUN=1; _RR_INLINE=0; _RR_REASON=""; _RR_HISTORY=""; _RR_LOG_HINT=""
  _RR_NOTICE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json|--text|--sha|--src|--dst|--ts|--diff-note|--run|--inline-comment|--reason|--history|--log-hint|--notice)
        [[ $# -ge 2 ]] || { echo "review 渲染：参数 $1 缺少取值" >&2; return 2; }
        case "$1" in
          --json) _RR_JSON="$2" ;;
          --text) _RR_TEXT="$2" ;;
          --sha) _RR_SHA="$2" ;;
          --src) _RR_SRC="$2" ;;
          --dst) _RR_DST="$2" ;;
          --ts) _RR_TS="$2" ;;
          --diff-note) _RR_DIFF_NOTE="$2" ;;
          --run) _RR_RUN="$2" ;;
          --inline-comment) _RR_INLINE="$2" ;;
          --reason) _RR_REASON="$2" ;;
          --history) _RR_HISTORY="$2" ;;
          --log-hint) _RR_LOG_HINT="$2" ;;
          --notice) _RR_NOTICE="$2" ;;
        esac
        shift 2 ;;
      *) echo "review 渲染：未知参数：$1" >&2; return 2 ;;
    esac
  done
  local v
  for v in _RR_SHA _RR_SRC _RR_DST _RR_TS _RR_DIFF_NOTE; do
    [[ -n "${!v}" ]] || { echo "review 渲染：缺少必填参数 --$(echo "${v#_RR_}" | tr 'A-Z_' 'a-z-')" >&2; return 2; }
  done
  [[ "$_RR_RUN" =~ ^[0-9]+$ && "$_RR_RUN" -ge 1 ]] || { echo "review 渲染：默认 --run 必须是 ≥1 的整数（实际：${_RR_RUN}）" >&2; return 2; }
  # --history 拼错路径不能静默按「无历史」渲染：那会把历次表悄悄清空，而评论上看不出异常
  [[ -z "$_RR_HISTORY" || -r "$_RR_HISTORY" ]] \
    || { echo "review 渲染：--history 指定的历史文件不可读：${_RR_HISTORY}" >&2; return 2; }
}

# --- 内部：追加后的历次记录必须是合法 JSON 数组 ---
# 两个渲染函数都被调用方写成 `review_render_… || die_review …`，而 `||` 会让整个函数体不受 errexit
# 约束：review_history_append 万一失败（jq 报错、--history 内容不合法），历史文件会是空的，
# 渲染出来的评论带一行 `<!-- kiro-history: -->` 与一张空表，而调用方看到的仍是退出码 0。
# 所以在这里显式拦一次：宁可整条评论渲染失败（调用方回写「评审未完成」），也不发一条坏掉的汇总。
# -s（读成数组后判断「恰好一个」）：不带 -s 时 jq 逐个 JSON 值套用过滤器、退出码取最后一个，
# 于是 `[…]\n[]` 这种「两个值」的文件会输出 true true 且退出 0——正是本守卫要拦的那种损坏。
_review_history_ok() {
  jq -e -s 'length == 1 and (.[0] | type == "array")' "$1" >/dev/null 2>&1 \
    || { echo "$2: 历次记录渲染失败（review_history_append 未产出恰好一个 JSON 数组）" >&2; return 1; }
}

# --- 历次记录的隐藏 JSON（下一次评审的解析入口）---
# 用法：review_render_history_marker <历史 JSON 文件>
# 刻意紧跟评审标记放在评论开头：MAX_COMMENT_BYTES 的截断是从尾部砍的，放在末尾的话
# 一条超长评论被截断之后，下一次评审就再也读不回历史了。
review_render_history_marker() {
  printf '%s%s%s\n' "$REVIEW_HISTORY_PREFIX" "$(jq -c '.' "$1")" "$REVIEW_HISTORY_SUFFIX"
}

# --- 「历次评审」折叠区（人类可读投影；spec §4.3）---
# 用法：review_render_history_table <历史 JSON 文件>
# 结论的中文化复用 _review_verdict_cn（不在 jq 里再写一份映射），所以行渲染走 bash 循环：
# 历史最多 REVIEW_HISTORY_MAX 行，成本可忽略。
review_render_history_table() {
  local hist="$1" n run sha status verdict p0 p1 p2 label
  n=$(jq -r 'length' "$hist")
  echo "<details><summary>历次评审（${n}）</summary>"
  echo ""
  echo "| 次 | 提交 | 结论 | P0/P1/P2 |"
  echo "|---|---|---|---|"
  # 分隔符用 \x1f 而不是制表符：制表符属于 IFS 空白，bash 会把连续分隔符并成一个，
  # status 或 verdict 为空串时字段就整体错位（实测把 verdict 读成了计数）。
  while IFS=$'\x1f' read -r run sha status verdict p0 p1 p2; do
    case "$status" in
      failed)   label="评审未完成" ;;
      degraded) label="结构化解析失败" ;;
      *)        label=$(_review_verdict_cn "$verdict") ;;
    esac
    printf '| %s | `%s` | %s | %s/%s/%s |\n' "$run" "$sha" "$label" "$p0" "$p1" "$p2"
  done < <(jq -r --arg sep "$(printf '\037')" '.[] | [ (.run | tostring), (.sha // ""), (.status // ""), (.verdict // ""),
                          (if .p0 == null then "-" else (.p0 | tostring) end),
                          (if .p1 == null then "-" else (.p1 | tostring) end),
                          (if .p2 == null then "-" else (.p2 | tostring) end) ] | join($sep)' "$hist")
  echo "</details>"
}

# --- 「怎么重新评审」的提示语（档位相关）---
# 这句话会出现在页脚与降级评论里，读者会照着做，所以它必须描述**本档位真的可行**的操作。
# Flow 档位接不到 Codeup 的评论事件（ADR-0001），「评论 `/kiro review`」在这里是假承诺；
# 评论命令由 AWS 档位的调度器承担（spec Q2/Q11），那一档部署时把变量设成
#   REVIEW_RERUN_HINT='评论 `/kiro review` 可重新评审'
# 即可，渲染代码不必再分档位。默认值取 Flow 语义。
REVIEW_RERUN_HINT_DEFAULT="重跑流水线可重新评审"
# 取值来自流水线变量、会原样进入评论，所以先过一遍 Markdown 结构清洗（运维手抖写进一个
# `<!-- kiro-review:… -->` 就会让评论带上第二个评审标记 → 下一次评审判它「标记不唯一」
# 而新建第二条汇总，违反 I4），**再**折成单行（顺序的理由见 _review_sanitize_oneline）。
# 全空白视为未配置。取值在一次评审里是常量，按原始取值缓存，避免降级路径重复起 jq。
_review_rerun_hint() {
  local raw="${REVIEW_RERUN_HINT-}" v
  if [[ "${_RRH_RAW-$'\001'}" != "$raw" ]]; then
    v="$raw"
    [[ -n "${v//[[:space:]]/}" ]] || v="$REVIEW_RERUN_HINT_DEFAULT"
    _RRH_VAL=$(_review_sanitize_oneline "$v")
    _RRH_RAW="$raw"
  fi
  printf '%s' "$_RRH_VAL"
}

# --- 页脚（第 N 次评审 + 图例 + 重新评审提示）---
# 用法：review_render_footer <run>（公开：kiro-review.sh 的失败评论也要用同一份页脚）
review_render_footer() {
  echo "---"
  printf '第 %s 次评审 · P0 必须修复 · P1 应当修复 · P2 可选改进 · %s\n' "$1" "$(_review_rerun_hint)"
}

# --- 标题层级（2026-09-04 真实验收）---
# Codeup 合并请求评论的 Markdown 只把 `#` 与 `##` 渲染成标题，`###` 及以下按普通段落文字显示
# （加粗、表格、<details>、代码块、引用、`---` 都正常）。所以评论只用两级标题：评论标题 `#`、
# 五个章节（变更摘要/结论/问题统计/重点关注文件/问题清单）`##`；问题分组 `**P0 必须修复（n）**`、
# 每条问题 `**1. `file:line` — 标题**`、折叠区小节 `**P2 建议（n）**` 与行内评论首行 `**P0 · 标题**`
# 一律用加粗行。_sanitize_md 对模型文本行首 `#{1,6}` 的转义不变：模型文本冒充 `#`/`##` 仍要挡，
# `###` 以下虽不再渲染成标题，转义成字面量也不损失什么。这条只约束脚本自己发出的行：模型文本
# 代码围栏内的 `###` 是代码，原样保留（所以「评论里没有 ### 行」不是全局不变量，测试只对无围栏 fixture 断言）。

# --- 评论头（标题 + 评审标记 + 历史标记）：成功 / 降级 / 失败评论与 kiro-review.sh 的最小失败评论**同一份**（第 13 条）---
# 用法：review_render_comment_head <标题> <sha> <run> <历史 JSON 文件（已含本次那一行）>
# 评审标记那一行的形态必须与 REVIEW_MARKER_LINE_RE 严格一致：定位旧评论、守卫、去重全靠它。以前最小失败评论在
# kiro-review.sh 里手写了第三份，守卫漏掉那一份就会在 MR 上多出一条汇总（违反 I4）。
review_render_comment_head() {
  local title="$1" sha="$2" run="$3" hist="$4"
  echo "$title"
  echo "<!-- kiro-review:${sha} run:${run} -->"
  review_render_history_marker "$hist"
}
# --- 本次一行历史（status=failed / degraded）的三步回退：读回的历史 + 本次 → 只有本次 → 空数组（第 13 条，一处定义）---
# 用法：review_history_for_run <历史 JSON 文件或 -> <run> <sha> <status> <调用方名> → stdout = 历史 JSON 数组
# 刻意永不失败：失败评论 / 最小失败评论是「评审没跑完」时唯一能到达 MR 的信息通道，历史算不出来就退化成只有本次一行。
review_history_for_run() {
  local prior="$1" run="$2" sha="$3" status="$4" who="$5" f
  f=$(mktemp)
  review_history_append "$prior" "$run" "$sha" "" "$status" - - - > "$f" 2>/dev/null || true
  _review_history_ok "$f" "$who" 2>/dev/null \
    || review_history_append - "$run" "$sha" "" "$status" - - - > "$f" 2>/dev/null || true
  _review_history_ok "$f" "$who" 2>/dev/null || printf '[]\n' > "$f"
  cat "$f"; rm -f "$f"
}
# --- 内部：评论头 + 元信息表 ---
# $2 = 历史 JSON 文件（已含本次那一行）
_review_render_header() {
  local title="$1" hist="$2"
  review_render_comment_head "$title" "$_RR_SHA" "$_RR_RUN" "$hist"
  echo ""
  echo "| Commit | 分支 | 时间 | diff |"
  echo "|---|---|---|---|"
  echo "| \`${_RR_SHA}\` | \`$(_review_meta_cell "$_RR_SRC")\` → \`$(_review_meta_cell "$_RR_DST")\` | ${_RR_TS} | ${_RR_DIFF_NOTE} |"
}

# --- 元信息单元格的字符许可清单（$1=原始取值 → stdout）---
# 只用在 --src/--dst 上：分支名是 **MR 作者可控输入**。实测 `git check-ref-format --branch`：
# `< > | ` 反引号 **都是合法 ref 字符**（而 `\ ~ ^ : ? * [` 与空格被 git 拒绝）。所以真正可达的
# 危险输入就是前四个；反斜杠与控制字符 git 侧已挡，这里仍一并过滤作纵深防御——`--dst` 还能经
# `MR_TARGET_BRANCH` 从流水线变量/CreatePipelineRun envs 注入，那条路**不过 git 校验**。
#   `|`      —— GFM 先按 | 切单元格再解析行内，`a|b|c` 会给 4 列表头配出 6 格，把时间与 diff 挤出表格；
#   反引号   —— **以反引号开头**的名字逃出脚本包的 code span，其后的原始 HTML 直接进评论；
#   `<` `>`  —— 逃出 code span 后 `<details>`/`<script>` 就是原始 HTML，未闭合的 <details> 折叠掉整段后文；
#              也让 `<!--`/`-->` 再也构不成 HTML 注释（隐藏标记不会被提前闭合）；
#   控制字符 —— 换行是关键的一个：`--dst $'x\n<!-- kiro-review:… run:9 -->'` 会让评论出现第二行
#              评审标记，review_select_prior_comment 的「标记恰好一个」不成立 → 每次评审新建汇总（破 I4）。
# 字符集就是 REVIEW_CELL_DENY_CHARS（与 review_history_append 的 `safe()`、review_validate 的 `fpath()` 同一份定义，票 13）。
# **只处理这两个**：`--sha` 来自 `git rev-parse`，`--ts` 由脚本 date 生成，`--diff-note` 是脚本常量，
# 三者都不含不受信输入；过滤它们只会掩盖「脚本自己传错了」这类问题。
# 全部用参数展开完成（bash 3.2 实测支持 `${v//[[:cntrl:]]/}`）：渲染路径每次评审都要走，不为两个
# 单元格起六个进程。只有真的需要截断时才起一次 iconv。
_review_meta_cell() {
  local v="${1-}" orig="${1-}"
  v=${v//["$REVIEW_CELL_DENY_CHARS"]/}
  v=${v//[[:cntrl:]]/}
  # 截断到 REVIEW_META_CELL_MAX_LEN 字符：分支名上限远小于此，超长只会撑坏表格。
  # `${v:0:200}` 在 POSIX locale（CI 容器常见 LANG 未设置）下按**字节**切，会切在 UTF-8 序列中间，
  # 于是评论正文里出现非法字节、jq 静默替换成 U+FFFD、页面上一个乱码方块且无任何日志。
  # 与 kiro-review.sh 的评论截断同一处置：截完用 iconv -c 清掉残缺序列。
  if [[ "${#v}" -gt "$REVIEW_META_CELL_MAX_LEN" ]]; then
    v=${v:0:$REVIEW_META_CELL_MAX_LEN}
    v=$(printf '%s' "$v" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null) || true
  fi
  # 过滤成空串时不能直接渲染成一对相邻反引号：GFM 找不到配对会按字面量显示两个裸反引号，
  # 分支信息彻底丢失且列数断言看不出来。回填占位，让读者知道「名字被过滤掉了」而不是「没有分支」。
  [[ -n "$v" ]] || v="(名称含非法字符，已过滤)"
  # 过滤改变了取值就留痕：否则评论上的分支名与真实 ref 不一致，运维照抄去 checkout 会失败而无从得知
  # （同一仓库对模型侧 file 字段的处置也是「计数 + 日志 + 写进统计行」，见 delocated_findings）。
  [[ "$v" == "$orig" ]] || echo "review 渲染：元信息表里的分支名含表格/HTML 危险字符，已过滤后显示（原值不进评论）" >&2
  printf '%s' "$v"
}

# --- 折叠区（INLINE_COMMENT=1；spec §4.3）---
# 小节标题里的级别列表按实际内容生成，而不是写死 spec 模板里的字面量：
#   - 档位桶在 quiet 下就是 P2（渲染成 `**P2 建议（n）**`；spec §4.3 模板写的 `#### P2 建议` 按 2026-09-04 实测澄清映射为加粗行），
#     但在 critical 下还包含 P1——写死「P2 建议」会把 P1 问题标成 P2，那是改写评审员的判级。
#   - 超限桶在 quiet 下是 P0/P1（与 spec 模板一致），balanced 下可能含 P2。
# --- 共用 jq 片段：问题的定位串 ---
# 两处渲染（折叠区条目、INLINE_COMMENT=0 的问题清单）必须给出同一种定位串，所以只留一份定义
# （与 _REVIEW_JQ_SANITIZE 同一个做法）。
# $unloc == "1"（折叠区的「未定位问题」小节）刻意只给文件、不给行号：那个行号恰恰是
# 「不在变更行集合里」的，摆出来只会让读者按一个不可信的行号去找问题（spec §4.3 模板）。
_REVIEW_JQ_LOC='
  def _loc($unloc):
    if .file == null then "（未定位）"
    elif $unloc == "1" then "`\(.file)`（无法定位到变更行）"
    elif .line_start == null then "`\(.file)`"
    elif (.line_end != null and .line_end > .line_start) then "`\(.file):\(.line_start)-\(.line_end)`"
    else "`\(.file):\(.line_start)`" end;
'

# --- 共用 jq 片段：body 的首句（折叠区条目用）---
# 折叠区是「一眼扫过去」的清单，整段 body（可能带代码块）会把折叠区撑成第二份报告。
# 取法：跳过整段代码围栏 → 取第一个非空行 → 截到第一个句号 → 按 120 字符封顶。
# 三个坑：
#   ① **句子边界必须用 split("。") 而不是 index("。")**：jq 的 index 对字符串返回**字节**偏移，
#      而 `.[a:b]` 切片按**码点**。中文正文里两者差三倍（"第一句说明。第二句解释。" → index 15、
#      length 12），切出来的既不是首句也不是完整字符。短句时字节偏移超过码点长度、被切片夹住
#      而「恰好」返回整行，所以这个 bug 在单句 fixture 上完全看不出来。
#   ② 跳过围栏行是必需的：评审员的 body 很常以 ```python 开头，取到那一行的话这个条目
#      就只剩一串反引号、什么信息都没有；围栏**内**的代码行同样什么都说明不了，整段跳过。
#   ③ 反引号还要再处理两道，否则这一行会把后面的条目一起吞掉：
#      连续 2 个以上的反引号折叠成 1 个（3 连是 Markdown 行内代码定界符，会一直找下一个 3 连
#      来配对，把两个条目之间的定位串与标题全吃进代码 span）；折叠后个数为奇数时补一个闭合
#      （120 字符封顶很容易切在代码 span 中间）。
_REVIEW_JQ_FIRSTSENT='
  def _lines: (. // "") | split("\n");
  def _outside_fence:
    _lines
    | reduce .[] as $l ({fence: false, out: []};
        if ($l | test("^[[:space:]]{0,3}(```|~~~)")) then {fence: (.fence | not), out: .out}
        elif .fence then .
        else {fence: .fence, out: (.out + [$l])} end)
    | .out;
  def firstsent:
    (_outside_fence | map(select(test("[^[:space:]]"))) | (.[0] // "")) as $outside
    # 整段 body 就是一个代码块时退回「围栏外没有、就取围栏内第一行」，总比留一个空说明好
    | (if ($outside | length) > 0 then $outside
       else (_lines
             | map(select(test("[^[:space:]]") and (test("^[[:space:]]{0,3}(```|~~~)") | not)))
             | (.[0] // "")) end) as $l
    | ($l | sub("^[[:space:]]+"; "")) as $t
    | ($t | split("。")) as $parts
    | (if ($parts | length) > 1 then ($parts[0] + "。") else $t end) as $s0
    | (if ($s0 | length) > 120 then $s0[0:120] + "…" else $s0 end) as $s1
    | ($s1 | gsub("`{2,}"; "`")) as $s
    | if ((($s | split("`") | length) - 1) % 2) == 1 then $s + "`" else $s end;
'

# _review_render_fold_section <计划文件> <标题模板> <桶名> <是否未定位桶 0|1> [是否完整渲染 0|1]
# 标题模板里的 `{levels}` 会替换成该桶里实际出现的级别列表（`P0/P1`）。替换刻意放在
# 「桶为空就直接返回」之后：空桶时那个标题根本不会渲染，先算它等于白跑一个 jq。
# 完整渲染（full=1）只给「行内发布失败」用：那些问题一条行内评论都没发出去，说明与修复建议
# 在 MR 上再没有别的地方能看到（I10 失败可见），只给标题 + 首句等于把 P0 的内容丢了。
_review_render_fold_section() {
  local plan="$1" title="$2" bucket="$3" unloc="${4:-0}" full="${5:-0}" n
  n=$(jq -r --arg b "$bucket" '(.folded[$b] // []) | length' "$plan")
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || return 0
  if [[ "$title" == *'{levels}'* ]]; then
    title="${title//\{levels\}/$(_review_fold_levels "$plan" "$bucket")}"
  fi
  echo ""
  printf '**%s（%s）**\n' "$title" "$n"
  if [[ "$full" == "1" ]]; then
    # 与「问题清单」同款：编号 + 定位串 + 标题 + 说明 + 修复建议
    jq -r --arg b "$bucket" --arg unloc "$unloc" "${_REVIEW_JQ_LOC}"'
      (.folded[$b] // []) | to_entries[]
      | .value as $f
      | "\n**\(.key + 1). \($f | _loc($unloc)) — \($f.title)**\n\n\($f.body)"
        + (if ($f.fix | length) > 0 then "\n\n**修复建议**\n\n\($f.fix)" else "" end)' "$plan"
    return 0
  fi
  echo ""
  jq -r --arg b "$bucket" --arg unloc "$unloc" "${_REVIEW_JQ_LOC}${_REVIEW_JQ_FIRSTSENT}"'
    (.folded[$b] // [])[]
    | "- \(_loc($unloc)) **\(.title)** — \(.body | firstsent)"' "$plan"
}

# 档位桶/超限桶里实际出现的级别，升序连成 `P0/P1`
_review_fold_levels() {
  jq -r --arg b "$2" '[(.folded[$b] // [])[] | .severity] | unique
                      | sort_by({"P0":0,"P1":1,"P2":2}[.] // 3) | join("/")' "$1"
}

# _review_render_folded <计划文件>：折叠区整块（为空时整体省略，不发一个空折叠块）
_review_render_folded() {
  local plan="$1" n
  n=$(jq -r '.folded_count // 0' "$plan")
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || return 0
  echo ""
  printf '<details><summary>折叠区：未展开的问题（%s）</summary>\n' "$n"
  _review_render_fold_section "$plan" '{levels} 建议'          profile   0
  _review_render_fold_section "$plan" '超出行内上限的 {levels}' overflow  0
  _review_render_fold_section "$plan" '未定位问题'              unlocated 1
  # 发布失败的那些问题完整渲染：一条行内评论都没发出去，说明与修复建议在 MR 上没有第二个落点
  _review_render_fold_section "$plan" '行内发布失败'            failed    0 1
  echo "</details>"
}

# --- 汇总评论 ---
# 用法：review_render_summary --json <契约 JSON 文件> --sha X --src A --dst B \
#                            --ts "YYYY-mm-dd HH:MM:SS" --diff-note N [--run 1] \
#                            [--inline-comment 0|1] [--history …] [--notice "一句话"]
# INLINE_COMMENT=0（spec §4.3 的 0 变体）：问题清单**完整展开**、不用折叠区、不提行内计数，
#   观感对齐 v1（I7：默认关闭 = 观感不变）。--json 收 review_validate 的输出。
# INLINE_COMMENT=1（spec §4.3、§4.5 第 8 步）：明细已经作为行内评论挂在「文件改动」对应行上，
#   汇总退化为状态面板——统计行注明已标注到行的条数，未发行内的问题进折叠区。
#   --json 必须收 review_plan_inline（经 review_plan_apply_outcomes 回填）的输出：
#   拿 review_validate 的输出硬渲染会得到一条「什么都没有折叠区、看不出行内发了几条」的评论。
# --notice：一句话警告，渲染成统计行下方的引用块。行内评论整体发不出去时由调用方回落到
#   INLINE_COMMENT=0 渲染并带上原因——阿里云侧开发者看不到流水线日志（I10 失败可见）。
review_render_summary() {
  _review_parse_render_args "$@" || return $?
  [[ -n "$_RR_JSON" ]] || { echo "review_render_summary: 缺少必填参数 --json" >&2; return 2; }
  [[ -r "$_RR_JSON" ]] || { echo "review_render_summary: 契约 JSON 不可读：${_RR_JSON}" >&2; return 2; }
  if [[ "$_RR_INLINE" != "0" && "$_RR_INLINE" != "1" ]]; then
    echo "review_render_summary: INLINE_COMMENT=${_RR_INLINE} 不是 0 或 1，拒绝渲染（静默按 0 渲染会让开关看起来生效了）" >&2
    return 3
  fi

  # --json 必须是 review_validate 的输出。不校验的话：空文件/非 JSON 会让每个 jq -r 都吐空串，
  # 渲染出一条「结论：评审员未给出结论 / P0 · P1 · P2 全空 / 问题清单里什么也没有」的空壳评论并返回 0；
  # 缺 dropped_findings 时 `[[ "$dropped" -gt 0 ]]` 还会在 set -u 下直接崩（null: unbound variable）。
  jq -e '(type == "object")
         and ((.dropped_findings | type) == "number")
         and ((.delocated_findings | type) == "number")
         and ((.findings | type) == "array")' "$_RR_JSON" >/dev/null 2>&1 \
    || { echo "review_render_summary: --json 不是 review_validate 的输出（需要对象 + 数值 dropped_findings/delocated_findings + 数组 findings）：${_RR_JSON}" >&2; return 2; }
  # INLINE_COMMENT=1 还需要发布计划的字段：缺了就说明调用方没走 review_plan_inline，
  # 硬渲染只会得到一条没有折叠区、行内计数恒为 0 的评论——那比报错更难发现。
  if [[ "$_RR_INLINE" == "1" ]]; then
    jq -e '((.inline | type) == "array") and ((.folded | type) == "object")
           and ((.folded.profile | type) == "array") and ((.folded.overflow | type) == "array")
           and ((.folded.unlocated | type) == "array") and ((.folded.failed | type) == "array")
           and ((.inline_count | type) == "number") and ((.folded_count | type) == "number")' \
       "$_RR_JSON" >/dev/null 2>&1 \
      || { echo "review_render_summary: --inline-comment 1 需要 review_plan_inline 的输出（缺 inline/folded/inline_count/folded_count 字段）：${_RR_JSON}" >&2; return 2; }
  fi

  local summary verdict verdict_cn verdict_reason dropped delocated n0 n1 n2 total stat hist
  summary=$(jq -r '.summary // ""' "$_RR_JSON")
  verdict=$(jq -r '.verdict // ""' "$_RR_JSON")
  verdict_reason=$(jq -r '.verdict_reason // ""' "$_RR_JSON")
  dropped=$(jq -r '.dropped_findings' "$_RR_JSON")
  delocated=$(jq -r '.delocated_findings' "$_RR_JSON")
  overflow=$(jq -r '.overflow_findings // 0' "$_RR_JSON")   # 超出 REVIEW_MAX_FINDINGS 的条数（第 28 条；旧 JSON 没有这个字段 → 0）
  total=$(jq -r '.findings | length' "$_RR_JSON")
  n0=$(jq -r '[.findings[] | select(.severity == "P0")] | length' "$_RR_JSON")
  n1=$(jq -r '[.findings[] | select(.severity == "P1")] | length' "$_RR_JSON")
  n2=$(jq -r '[.findings[] | select(.severity == "P2")] | length' "$_RR_JSON")
  verdict_cn=$(_review_verdict_cn "$verdict")

  # 历次记录：把本次这一行追加到 --history 给的旧记录上。由渲染器统一追加（而不是让调用方传全量），
  # 保证表格里的本次那一行与评审标记里的 run:N、与统计行的计数永远出自同一份输入。
  hist=$(mktemp)
  review_history_append "${_RR_HISTORY:--}" "$_RR_RUN" "$_RR_SHA" "$verdict" "" "$n0" "$n1" "$n2" > "$hist"
  _review_history_ok "$hist" review_render_summary || { rm -f "$hist"; return 2; }

  _review_render_header "$REVIEW_TITLE" "$hist"
  echo ""
  echo "## 变更摘要"
  echo ""
  # 模型给的字符串一律用 printf：值恰好是 -n / -e / -E 时 echo 会当成选项吃掉，正文直接消失
  if [[ -n "$summary" ]]; then printf '%s\n' "$summary"; else echo "（评审员未给出变更摘要）"; fi
  echo ""
  echo "## 结论：${verdict_cn}"
  echo ""
  if [[ -n "$verdict_reason" ]]; then printf '%s\n' "$verdict_reason"; else echo "（评审员未给出结论理由）"; fi
  # 契约要求「有 P0 时不要给 MERGE」。模型违约时不改写它的结论（那是评审员的判断），
  # 但必须把矛盾摆在结论旁边——否则只看标题的人会合并一份自己都说有 P0 的代码。
  if [[ "$verdict" == "MERGE" && "$n0" -gt 0 ]]; then
    echo ""
    # 指向的必须是本次真的会渲染出来的地方：INLINE_COMMENT=1 时早返回、根本没有「问题清单」这一节，
    # 明细都在行内评论与折叠区里，指过去会让读者去找一个不存在的章节。
    if [[ "$_RR_INLINE" == "1" ]]; then
      echo "> ⚠️ 评审员给出「可合并」，但同时报了 ${n0} 条 P0（必须修复）。两者矛盾，请以「文件改动」上的行内评论与下方折叠区为准。"
    else
      echo "> ⚠️ 评审员给出「可合并」，但同时报了 ${n0} 条 P0（必须修复）。两者矛盾，请以下方 P0 清单为准。"
    fi
  fi
  echo ""
  echo "## 问题统计"
  echo ""
  stat="P0 ${n0} · P1 ${n1} · P2 ${n2}"
  # INLINE_COMMENT=1：注明其中多少条已经作为行内评论挂在「文件改动」对应行上（spec §4.3）。
  # 这个数只算「真的在那一处有评论」的问题：本次新发的 + 因同一处已有评论而跳过的；发布失败的不算（它们在折叠区）。
  # 口径是「问题条数」而不是「评论条数」：多条问题并到同一条已有评论上时，计数仍按问题算（协调者 R3）。
  [[ "$_RR_INLINE" == "1" ]] \
    && stat="${stat} —— 其中 $(jq -r '.inline_count' "$_RR_JSON") 条已标注在「文件改动」对应行"
  [[ "$dropped" -gt 0 ]] && stat="${stat}（另有 ${dropped} 条不合契约已丢弃）"
  [[ "$overflow" -gt 0 ]] && stat="${stat}（另有 ${overflow} 条超出展示上限）"
  [[ "$delocated" -gt 0 ]] && stat="${stat}（${delocated} 条的文件路径不合规，已按未定位处理）"
  echo "$stat"
  if [[ -n "$_RR_NOTICE" ]]; then
    echo ""
    # 取值由脚本自己拼（可能带 HTTP 状态码之类），仍过一遍结构清洗：评论的结构只能来自渲染器
    printf '> ⚠️ '
    printf '%s' "$_RR_NOTICE" | review_sanitize_md
    echo ""
  fi

  # 重点关注文件：按 P0→P1→P2 计数降序、同计数按路径升序，最多 10 行；无可归属文件时整节省略。
  if [[ "$(jq -r '[.findings[] | select(.file != null)] | length' "$_RR_JSON")" -gt 0 ]]; then
    echo ""
    echo "## 重点关注文件"
    echo ""
    echo "| 文件 | P0 | P1 | P2 |"
    echo "|---|---|---|---|"
    jq -r '
      [.findings[] | select(.file != null)]
      | group_by(.file)
      | map({ file: .[0].file,
              p0: ([.[] | select(.severity == "P0")] | length),
              p1: ([.[] | select(.severity == "P1")] | length),
              p2: ([.[] | select(.severity == "P2")] | length) })
      | sort_by(.file) | sort_by([-.p0, -.p1, -.p2])
      | .[0:10][]
      | "| `\(.file)` | \(.p0) | \(.p1) | \(.p2) |"' "$_RR_JSON"
  fi

  if [[ "$_RR_INLINE" == "1" ]]; then
    # 明细由行内评论承载：汇总里不再展开问题清单，否则同一条问题在 MR 上出现两次（违反 I4）
    if [[ "$total" == "0" ]]; then
      echo ""
      echo "未发现明显问题。"
    fi
    _review_render_folded "$_RR_JSON"
    echo ""
    review_render_history_table "$hist"
    rm -f "$hist"
    echo ""
    review_render_footer "$_RR_RUN"
    return 0
  fi

  echo ""
  echo "## 问题清单"
  if [[ "$total" == "0" ]]; then
    echo ""
    echo "未发现明显问题。"
  else
    # 分组与编号都在 jq 里做，保证同一输入逐字节一致：
    # 组内先按原始次序编号（to_entries 固定索引），再按 文件 → 起始行 → 原始次序 排序。
    jq -r --arg sevs "$REVIEW_SEVERITIES" "${_REVIEW_JQ_LOC}"'
      def sevlabel: { "P0": "P0 必须修复", "P1": "P1 应当修复", "P2": "P2 可选改进" }[.] // .;
      (.findings | to_entries | map(.value + {idx: .key})) as $all
      | ($sevs | split(" "))[] as $sev
      | [$all[] | select(.severity == $sev)] as $grp
      | select(($grp | length) > 0)
      | "\n**\($sev | sevlabel)（\($grp | length)）**",
        ( $grp
          | sort_by([(.file == null), (.file // ""), (.line_start // 0), .idx])
          | to_entries[]
          | .value as $f
          | "\n**\(.key + 1). \($f | _loc("0")) — \($f.title)**\n\n\($f.body)"
            + (if ($f.fix | length) > 0 then "\n\n**修复建议**\n\n\($f.fix)" else "" end) )' "$_RR_JSON"
  fi
  echo ""
  review_render_history_table "$hist"
  rm -f "$hist"
  echo ""
  review_render_footer "$_RR_RUN"
}

# --- 超长评论的截断（Codeup 的 content 有长度上限）---
# 用法：review_truncate_comment <评论文件（就地改写）> <字节上限>
#   rc 0 = 已截断并追加提示；rc 1 = 未超限（文件不变）；rc 2 = 用法错误
# 放在库里而不是内联在 kiro-review.sh：这段逻辑的正确性取决于「切在哪个字节上」，
# 只有能在库层面对几十个截断窗口做扫描式回归，才谈得上验证过（见 tests/test-review-render.sh）。
# 返回码：0 已截断并写回；1 未超限（文件不变）；2 参数错；3 截断后标记行丢失（拒绝）；4 写回失败；5 守卫命令失败（第 26 条）
review_truncate_comment() {
  local file="$1" max="$2" size dir
  [[ -r "$file" ]] || { echo "review_truncate_comment: 文件不可读：${file}" >&2; return 2; }
  [[ "$max" =~ ^[0-9]+$ && "$max" -ge 1 ]] || { echo "review_truncate_comment: 字节上限必须是 ≥1 的整数（实际：${max}）" >&2; return 2; }
  size=$(wc -c < "$file" | tr -d ' ')
  [[ "$size" -gt "$max" ]] || return 1
  dir=$(mktemp -d) || { echo "review_truncate_comment: 建不出临时目录" >&2; return 4; }   # $dir 为空时会写到 /cut（第 29 条）
  head -c "$max" "$file" > "$dir/cut"
  # **先退到最后一个完整行**（丢掉那半行），再做任何补齐：
  #   ① 半行会让后面追加的闭合围栏/闭合标签接在半行后面，而它们不在行首就不起作用
  #      （实测截断后得到的是 `    row_2 = fetc``` `，围栏没闭合）；
  #   ② 半个标签（切在 `<deta|ils>` 或 `</d|etails>` 中间）会让行首标签计数判断错——
  #      对 golden summary-full.md，1730 与 1882 这两个上限正好落在这两处；
  #   ③ 行边界不会落在多字节字符中间，所以退到完整行同时消掉了「截出半个 UTF-8 字符」。
  # awk 逐行打印时把最后一条记录留在 prev 不输出，正好等于「丢掉末尾那半行」，且输出以换行结尾。
  if [[ $(tail -c1 "$dir/cut" | wc -l | tr -d ' ') -eq 1 ]]; then
    cp "$dir/cut" "$dir/out"
  else
    awk 'NR > 1 { print prev } { prev = $0 }' "$dir/cut" > "$dir/out"
  fi
  # iconv 只作兜底（清掉输入本身可能带的非法字节），且**只看输出是否可用，不看退出码**：
  # 实测（macOS）`iconv -f UTF-8 -t UTF-8 -c` 对「EOF 处不完整的字符」以 1 退出，同时照样写出
  # 清理好的前缀。原先写成 `head -c … | iconv -c || head -c …`，这个回退恰好在 iconv 清理成功时
  # 触发，把干净结果覆盖回带半个字符的原文，评论末尾就出现 U+FFFD。
  iconv -f UTF-8 -t UTF-8 -c < "$dir/out" > "$dir/iconv" 2>/dev/null || true
  if [[ -s "$dir/iconv" || ! -s "$dir/out" ]]; then
    mv "$dir/iconv" "$dir/out"
  else
    rm -f "$dir/iconv"
  fi
  # 空文件（上限小于第一行）时补一个换行，保证后面追加的内容仍在行首
  [[ $(tail -c1 "$dir/out" | wc -l | tr -d ' ') -eq 1 ]] || printf '\n' >> "$dir/out"
  # fix 字段里会带 ```代码块```：截断点落在围栏中间时，随后追加的截断提示会被 Markdown 当成
  # 代码块内容渲染掉，读者只看到评论突然结束、完全看不到「已截断」。所以先补闭合围栏，再写提示。
  if [[ $(( $(grep -c '^```' "$dir/out" || true) % 2 )) -eq 1 ]]; then
    echo '```' >> "$dir/out"
  fi
  # 同理对「历次评审」折叠区：截断点落在 <details> 里面时，未闭合的标签会把随后追加的截断提示
  # 一起吞进折叠块（甚至吞掉页脚）。补齐缺的闭合标签，提示才落在折叠块外面。
  # 只数**行首**的标签：脚本渲染的折叠块都是行首整行，而模型文本里的折叠标签已被 _sanitize_md
  # （大小写不敏感地）转义成 `&lt;details`——所以这里数到的一定是脚本自己的标签。用无锚点的 grep
  # 会把模型原文引用的 `</details>` 也算进闭合数，于是该补的时候反而不补。
  # 计数用 -i：HTML 标签名不区分大小写。
  local det_open det_close
  det_open=$(grep -ci '^<details' "$dir/out" || true)
  det_close=$(grep -ci '^</details>[[:space:]]*$' "$dir/out" || true)
  while [[ "$det_open" -gt "$det_close" ]]; do
    echo '</details>' >> "$dir/out"
    det_close=$((det_close + 1))
  done
  {
    echo ""
    echo "> ⚠️ 报告超长已截断（上限 ${max} 字节），完整内容见流水线日志。"
  } >> "$dir/out"
  # 硬守卫（与 review_redact_file 共用一份 _review_replace_guarded，第 12 条）：截断结果里必须还留着原文里的每一行脚本标记
  # （评审标记 + 隐藏历史——后者紧跟标记之后，上限小到砍掉它时下一次评审就读不回历次记录，票 18 ②）。丢了标记的残片一旦被
  # PUT 上去：① 上一次的完整报告与隐藏的历次记录当场不可恢复地消失；② 下一次评审再也定位不到这条评论，会在 MR 上新建
  # 第二条汇总（违反 I4）。宁可让截断失败（调用方回写失败评论，形态完整、历史仍在），也不发这种残片。
  # 交给守卫的替换文件必须在目标同目录（第 29 条，与 review_redact_file / _review_jq_inplace 同款）：TMPDIR 与 WORK 不同文件系统时
  # mv 是拷贝不是原子重命名——而这是全脚本风险最高的写者（结果会 PUT 覆盖上一份汇总）
  local rc=0 out
  out=$(mktemp "${file}.trunc.XXXXXX") || { rm -rf "$dir"; echo "review_truncate_comment: 建不出临时文件：${file}" >&2; return 4; }
  cp "$dir/out" "$out" || { rm -f "$out"; rm -rf "$dir"; echo "review_truncate_comment: 写临时文件失败：${file}" >&2; return 4; }
  _review_replace_guarded "$file" "$out" review_truncate_comment || rc=$?
  rm -rf "$dir"
  if [[ "$rc" == "3" ]]; then
    echo "review_truncate_comment: 上限 ${max} 字节太小，截断后连评审标记/隐藏历史都没了——拒绝截断（那份残片会覆盖掉上一条汇总的全部内容与历次记录）。请调大 MAX_COMMENT_BYTES" >&2
  fi
  return "$rc"
}

# --- 疑似密钥的脚本侧掩码（stdin → stdout）---
# 用法：review_redact_secrets [--keep-lines]
#   默认（**字段级**，给 review_redact_json 用）：PEM 私钥块整块删除（BEGIN…END，票 10 `df6e6c3` 的语义），
#     未闭合的块暂存到字段末再放出并掩码；行数可能变化。
#   --keep-lines（**保行模式**：文档级兜底、降级原文、日志行）：不删行不加行——PEM 块的正文行**逐行就地**换成
#     `****（PEM 正文已屏蔽）`，起始 / END 行保留为标记；起始行之后的散文继续按普通行掩码并掩掉 ≥ 40 位的 base64 连片
#     （票 10「放出并继续掩码」的语义，只是不再暂存、不再删）。降级原文走这条：两条标记行之间的评审内容不再整段消失
#     （第 11 / 14 条）。
# 掩码规则与提示词一致：长度 ≥ 12 保留前 4 后 4，其余整体替换为 ****。
#
# 精度要求（R7，票 10）：评论是人要**手读**的。key=value 规则只对「像字面量凭证」的取值生效——表达式、路径、属性访问
# 不掩（`password: os.environ.get("PW")`、`private_key=/etc/ssl/private/server.key`）。字面量的判定只有一处
# （literal_credential，第 8/18/29 条）：
#   · 加了引号 → 只看长度（引号里的东西就是字面量，「别把可读代码掩花」的理由不成立；`"/Jalr…"`、`"ya29.…"`、`"-abc…"` 都掩）；
#   · 未加引号 → 先排除代码形状（表达式 / 路径开头 / 属性访问），剩下的按**字符集与上下文**判定：含数字、含 [A-Za-z0-9_]
#     之外的字符（/ + = . ~ - …，连字符也算——diceware 口令 `correct-horse-battery-staple` 就是连字符小写词组，第 14 条）、
#     键名全大写下划线风格（SECRET_KEY / AWS_…）、env 形态 `key=value`、YAML 形态 `key: value`（短于 16 的英文词形除外）——
#     满足任一即掩；都不满足（小写/camelCase 键 + ` = ` + 纯字母数字下划线取值）才按代码里的标识符引用放行
#     （`token = userToken`、`String apiKey = configApiKey;`）。有意接受的漏报：`secret = MySecretValueHere`——形状上与标识符引用
#     不可区分；`password: SuperSecretPass`（15 位驼峰，词形上与 sessionToken 一类引用不可分）；同一值写成 `SECRET=…` / 加引号 /
#     长于 16 就会被掩。有意接受的误报：`token: rate-limited-endpoint` → `rate****oint`（键名保留）。
# Bearer/Basic 与令牌头后面的取值：**散文词**（英文词形且长度 < 20；显式令牌头 x-api-key 等 < 12）不掩——
#   `Basic authentication`、`Authorization: HeaderMissing`；真令牌几乎必含数字或 `.`/`/`/`=`，纯字母 ≥ 20（base32 恢复码、
#   许可证密钥）仍掩。**不用**「大小写一致性」判定（TOKENName 会被放行），也**不用** looks_literal（它会把含 `.` 的
#   `ya29.…` 当属性访问放行）。
# URL 内嵌凭证两遍匹配（第 12 条）：先按 RFC 3986 严格类（userinfo 不含 `/`）；不中时用口令可含 `/` 的宽松类，但要求 user 段
#   不含 `.`（含点的是主机名）且口令段不以 `[0-9]+/` 开头（那是端口 + 路径）——真实世界里未编码粘贴的
#   `https://ci:wJalr…/K7MD…@git…` 与 `postgres://admin:Ab3/xY9+…==@db` 要掩，`registry.npmjs.org:443/@babel/core` 不能掩。
review_redact_secrets() {
  local keep=0 sentre=""
  while (( $# )); do
    case "$1" in
      --keep-lines) keep=1; shift ;;
      --sentinel)   # 字段分隔行的正则只走显式参数：不读环境（第 16 条：Flow 作业环境里一个 export 就能让全部掩码直通）
        [[ $# -ge 2 && -n "${2-}" ]] || { echo "review_redact_secrets: --sentinel 缺少取值" >&2; return 2; }
        sentre="$2"; shift 2 ;;
      *) echo "review_redact_secrets: 未知参数 $1" >&2; return 2 ;;
    esac
  done
  LC_ALL=C awk -v keeplines="$keep" -v sentre="$sentre" '
    # 注意：本函数整体在 LC_ALL=C 下运行（按字节），所以**所有取值的字符类都必须是显式 ASCII 许可清单**，
    # 不能用 [^…] 这种否定类——中文标点等高位字节不属于 [[:space:]]/[[:punct:]]，取值会一路吞进中文正文，
    # 掩码还会从多字节字符中间切断（输出 U+FFFD）。
    function mask(s) {
      if (length(s) >= 12) return substr(s, 1, 4) "****" substr(s, length(s) - 3)
      return "****"
    }
    # 把 line 中所有匹配 re 的片段替换成掩码后的自身
    function redact(line, re,   out, m, pre) {
      out = ""
      while (match(line, re) > 0) {
        pre = substr(line, 1, RSTART - 1)
        m = substr(line, RSTART, RLENGTH)
        out = out pre mask(m)
        line = substr(line, RSTART + RLENGTH)
      }
      return out line
    }
    # 字面量凭证的**唯一**判定（第 8/18/29 条）。quoted：取值前有引号；key：键名原样；unspaced：分隔符是 `:`，或 `=` 两侧都没空格。
    function literal_credential(val, quoted, key, unspaced) {
      if (length(val) < 12) return 0
      if (quoted) return 1                                   # 引号里的就是字面量：不再看路径 / 属性访问 / 首字符
      if (val ~ /[(){}$<>[:space:]]/) return 0               # 函数调用 / 变量展开 / 模板
      if (val ~ /^[\/.~\-]/) return 0                        # 绝对路径、./ 相对路径、~/、选项
      if (val ~ /[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_]/) return 0  # 属性访问（os.environ、server.key）
      if (val ~ /[0-9]/) return 1                            # ① 含数字
      if (val ~ /[^A-Za-z0-9_]/) return 1                    # ② 含标识符不会有的字符（/ + = . ~ - …；第 14 条：连字符不再是散文信号——diceware 口令就是连字符小写词组）
      if (key ~ /^[A-Z0-9_-]*[A-Z][A-Z0-9_-]*$/) return 1    # ③ 键名全大写 / 下划线风格（SECRET_KEY、AWS_…、MYSQL_PASSWORD）
      if (unspaced == 2) return 1                            # ④a env / properties 形态（key=value）
      if (unspaced == 1 && !prose_word(val, 16)) return 1    # ④b YAML 形态（key: value）——短于 16 的英文词形（authentication、SuperSecretPass）放行
      return 0                                               # 代码里的标识符引用：token = userToken
    }
    # 散文词（第 19 条）：短于 maxlen 的**英文词形**——全大写缩写，或小写 / 首字母大写的驼峰词（首段 ≥ 2 个小写字母，
    # 后续每段大写 + ≥ 1 个小写：authentication / Authentication / HeaderMissing / RequestId）。base64 的大小写是逐字符乱序的
    # （dXNlcjpwYXNz、dGhpcyBpcyBh），不成词形，所以照掩；长度上限另把 ≥ 20 的纯字母（base32 恢复码、许可证密钥、TOKENNameXXXX…）
    # 全部收回来。
    function prose_word(v, maxlen) {
      if (length(v) >= maxlen) return 0
      return (v ~ /^[A-Z]+$/ || v ~ /^([A-Z]?[a-z][a-z]+)([A-Z][a-z]+)*$/)
    }
    # 形如 SECRET_KEY = "xxx" / token: xxx 的赋值：只掩码取值部分，保留键名（键名是排查线索）。
    # 大小写不敏感靠 tolower 副本定位——tolower 不改变长度，下标可以直接套回原串；副本在循环外算一次、与 line 同步推进
    # （第 6 条 ②：每轮重算 tolower 让 40000 处匹配的 760 KB 单行跑 27 s，同步推进后 6 s）。
    function redact_assign(line,   lo, out, seg, sep, vstart, val, i, ch, quoted, key, before, after, unspaced) {
      out = ""
      lo = tolower(line)
      while (match(lo, /(secret|token|passwd|password|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|credential)[a-z0-9_-]*[[:space:]]*[:=][[:space:]]*"?'"'"'?[A-Za-z0-9._~+\/=-]+/) > 0) {
        seg = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1)
        line = substr(line, RSTART + RLENGTH); lo = substr(lo, RSTART + RLENGTH)
        # 分隔符从**键之后向前**找第一个 `:`/`=`（与 redact_header 一致），不能从段末往回找：取值字符类里也有 `=`
        # （base64 补位），往回找会把补位的 `=` 当成分隔符、val 变成空串（`api_key = "…c2VjcmV0=="` 全裸奔）。
        # 段首到分隔符之间是正则里的键名 `(secret|token|…)[a-z0-9_-]*`，不含 `:`/`=`，所以段内第一个 `:`/`=` 一定是分隔符。
        sep = 0
        for (i = 1; i <= length(seg); i++) {
          ch = substr(seg, i, 1)
          if (ch == ":" || ch == "=") { sep = i; break }
        }
        if (sep == 0) { out = out seg; continue }
        key = substr(seg, 1, sep - 1); sub(/[[:space:]]+$/, "", key)
        before = (sep > 1) ? substr(seg, sep - 1, 1) : ""
        after = substr(seg, sep + 1, 1)
        unspaced = (ch == ":") ? 1 : ((before !~ /[[:space:]]/ && after !~ /[[:space:]]/) ? 2 : 0)   # 1 = YAML 冒号，2 = 无空格的 =
        vstart = sep + 1
        while (vstart <= length(seg) && substr(seg, vstart, 1) ~ /[[:space:]]/) vstart++
        # 外层正则只允许「至多一个双引号 + 至多一个单引号」，peek 一两个字符即可，不必逐字符循环
        quoted = 0
        while (vstart <= length(seg) && substr(seg, vstart, 1) ~ /["'"'"']/) { quoted = 1; vstart++ }
        val = substr(seg, vstart)
        if (literal_credential(val, quoted, key, unspaced)) out = out substr(seg, 1, vstart - 1) mask(val)
        else                                                 out = out seg
      }
      return out line
    }
    # Authorization: Bearer <token> / Authorization: Basic <b64>：掩码方案后面的那一段（散文词除外）
    function redact_bearer(line,   lo, out, seg, p, val) {
      out = ""
      lo = tolower(line)
      while (match(lo, /(bearer|basic)[[:space:]]+[A-Za-z0-9._~+\/=-]{8,}/) > 0) {
        seg = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1)
        line = substr(line, RSTART + RLENGTH); lo = substr(lo, RSTART + RLENGTH)
        p = match(seg, /[[:space:]]+/)
        val = substr(seg, p + RLENGTH)
        if (prose_word(val, 20)) out = out seg
        else                     out = out substr(seg, 1, p + RLENGTH - 1) mask(val)
      }
      return out line
    }
    # 自定义令牌头（云效令牌走这条：x-yunxiao-token: xxx）。
    function redact_header(line,   lo, out, seg, vstart, val, i, ch, hdr) {
      out = ""
      lo = tolower(line)
      while (match(lo, /(x-yunxiao-token|x-api-key|x-auth-token|private-token|authorization)[[:space:]]*:[[:space:]]*[A-Za-z0-9._~+\/=-]+/) > 0) {
        seg = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1)
        line = substr(line, RSTART + RLENGTH); lo = substr(lo, RSTART + RLENGTH)
        vstart = index(seg, ":") + 1
        hdr = tolower(substr(seg, 1, vstart - 2)); sub(/[[:space:]]+$/, "", hdr)
        while (vstart <= length(seg) && substr(seg, vstart, 1) ~ /[[:space:]]/) vstart++
        val = substr(seg, vstart)
        # 值本身是 Bearer/Basic 方案时交给 redact_bearer，别把方案名掩掉。散文豁免只给 Authorization:（`Authorization: header missing`）；
        # 显式令牌头（x-api-key / x-auth-token / x-yunxiao-token / private-token）后面 ≥ 8 位一律掩——头名本身就是上下文（第 18 条）
        if (tolower(val) ~ /^(bearer|basic)/) out = out seg
        else if (hdr == "authorization" && prose_word(val, 20)) out = out seg
        else if (hdr != "authorization" && length(val) < 8 && prose_word(val, 8)) out = out seg   # 第 24 条：只放行词形短值（short / none / TODO），aB3.x7 一律掩
        else out = out substr(seg, 1, vstart - 1) mask(val)
      }
      return out line
    }
    # URL 内嵌凭证 scheme://user:pass@host：只掩 pass（两遍，见函数头注释；第 9 / 12 条）
    function redact_url_pass(line, re, loose,   out, seg, p, q, user, pass) {
      out = ""
      while (match(line, re) > 0) {
        seg = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1)
        line = substr(line, RSTART + RLENGTH)
        p = index(seg, "://") + 3
        q = index(substr(seg, p), ":")
        user = substr(seg, p, q - 1)
        pass = substr(seg, p + q, length(seg) - (p + q))   # 去掉结尾的 @
        if (loose && pass ~ /^[0-9]+\//) { out = out seg; continue }   # host:port/path…@ 不是凭证
        out = out substr(seg, 1, p - 1) user ":" mask(pass) "@"
      }
      return out line
    }
    # 没有 "://" 的行直接返回（第 12c 条）：两遍正则里 `[a-zA-Z][a-zA-Z0-9+.-]*://` 的无界 `*` 让 BSD awk 从每个起点向前重扫，
    # 40 KB 无 URL 的单行要跑 15 s；index 一次就能排掉
    function redact_url(line) {
      if (index(line, "://") == 0) return line
      return redact_url_pass(redact_url_pass(line, URL_STRICT_RE, 0), URL_LOOSE_RE, 1)
    }
    # --- PEM 私钥块 ---
    # 起始行 / END 行都要**锚定整行**（第 10 条）：剥掉常见 Markdown 装饰（前导空白、引用 `>`、列表 `*`/`+`/`- `、有序列表 `1.`、
    # 反引号；diff 删除行紧贴标记的第 6 个 `-`；尾随反引号 / `*` / 空白）后整行只剩标记才算。句中引用（「…以 BEGIN RSA PRIVATE KEY
    # 标记开头的私钥文件…」、标题末尾提到 END 标记）是正文，不是块——不锚定时那一句整行被换成占位符，其后到 EOF 全部进 held，
    # 另一条问题的长路径还会被 redact_b64 打碎。兜底：一行**含**起始标记（没锚定）且下一行像密钥正文 → 也当块起始（pend 机制）。
    function pem_strip_deco(s) {
      sub(/^[[:space:]]+/, "", s)
      while (1) {
        if (s ~ /^[>*+`][[:space:]]*/) { sub(/^[>*+`][[:space:]]*/, "", s); continue }
        if (s ~ /^-[[:space:]]+/) { sub(/^-[[:space:]]+/, "", s); continue }
        if (s ~ /^[0-9]+\.[[:space:]]+/) { sub(/^[0-9]+\.[[:space:]]+/, "", s); continue }
        if (s ~ /^------/) { s = substr(s, 2); continue }
        break
      }
      sub(/[[:space:]`*]+$/, "", s)
      return s
    }
    function pem_marker(l, re) { return (pem_strip_deco(l) ~ ("^" re "$")) }
    # base64 连片掩码（第 1 / 5 条：字母表只在 B64C 一处定义）：每个候选连片都要过 b64_material 的严格分支（第 23 / 26 条：含数字、
    # 非纯十六进制、含 +/= 或类别切换率 ≥ 0.35），否则原样——`见 <BEGIN 标记> 出现在 src/main/java/…/UserService` 的路径尾巴、
    # 块内散文里的 Java 长路径与长类名都不能被打碎；full=1 整段 ****，否则前 4 后 4
    function redact_b64(s, minlen, full,   out, m, re) {
      re = "[" B64C "]{" minlen ",}={0,2}"
      out = ""
      while (match(s, re) > 0) {
        m = substr(s, RSTART, RLENGTH)
        out = out substr(s, 1, RSTART - 1) (b64_material(m, minlen, 1) ? (full ? "****" : mask(m)) : m)
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    # 非锚定行里的 PEM：`PRIVATE_KEY="<BEGIN 标记>\nMIIE…\n<END 标记>"`（.env / JSON 里用 \n 转义写成一行的密钥）——
    # 起止标记之间夹着 ≥ 20 位 base64 连片时整段换成占位符；只有起始标记时把其后的 base64 连片（≥ 20、非十六进制）整段 ****。
    # 散文里「从 <BEGIN 标记> 到 <END 标记> 的整块私钥」之间没有 base64，逐字节不动。标记正则与 pem_marker 同一常量（第 2 条）。
    # 同一行多把钥匙（`A="…BEGIN…END…" B="…BEGIN…END…"`）循环处理到行内不再有起始标记（第 23 条）
    function pem_inline(line,   out, b, blen, rest, mid) {
      out = ""
      while (match(line, PEM_BEGIN_RE) > 0) {
        b = RSTART; blen = RLENGTH
        rest = substr(line, b + blen)
        if (match(rest, PEM_END_RE) > 0) {
          mid = substr(rest, 1, RSTART - 1)
          if (mid ~ ("[" B64C "]{20,}")) { out = out substr(line, 1, b - 1) PEM_PLACEHOLDER; line = substr(rest, RSTART + RLENGTH) }
          else { out = out substr(line, 1, b + blen - 1) mid substr(rest, RSTART, RLENGTH); line = substr(rest, RSTART + RLENGTH) }
        } else {
          return out substr(line, 1, b + blen - 1) redact_b64(rest, 20, 1)
        }
      }
      return out line
    }
    # 只有 RFC 1421 的这两个头属于 PEM 块内（加密私钥才有）。不放宽成「任意 Word: 值」：
    # 那样模型写在起始行后面的 `Note: …` 一类正文也会被当成块内容静静丢掉。
    function pem_is_hdr(l) { return tolower(l) ~ /^[[:space:]]*[-+>]?[[:space:]]*(proc-type|dek-info):[[:print:]]*$/ }
    # 「像密钥正文」的行——一份判定、两种松紧（16-fix4 第 1 条：原先 pem_body_like 剥 diff/引用前缀而 pem_body_key 不剥，
    # `+MIIE…` 这种带前缀的正文行整行规则与兜底都会漏掉）。都先去掉 `[-+>]?` 前缀与首尾空白、要求整行是 base64 字符集；
    #   strict=1（块外：第 10 条兜底前瞻 / 第 17 条整行规则）：b64_material(s, minlen, 1)；
    #   strict=0（锚定 BEGIN 之后的块内，票 10 的 pem_body_like）：b64_material(s, 20, 0)、或以补位 `=` 结尾、或 < 20 的短行含数字 + 大小写混合
    #     （收住正文最后一行 `short==`、`AbCd1234EfGh`，而 `DONOTMERGE`、`P0`、`MERGE`、`disableInheritingDefaultResources` 一条都不满足——
    #     第 15 条 ②：≥ 20 分支不再放过无数字的纯字母标识符行）。
    function pem_body(l, minlen, strict,   s) {
      s = l
      sub(/^[[:space:]]*[-+>]?[[:space:]]*/, "", s)
      sub(/[[:space:]]+$/, "", s)
      if (s !~ ("^[" B64C "=]+$")) return 0
      if (strict) return b64_material(s, minlen, 1)
      if (b64_material(s, 20, 0) || s ~ /=$/) return 1
      return (length(s) < 20 && s ~ /[0-9]/ && s ~ /[a-z]/ && s ~ /[A-Z]/)
    }
    # 「就是密钥正文 / 密钥碎片」的**唯一**判定（第 26 条改定义，补充八；pem_body 与 redact_b64 的每个候选连片都调它）：
    #   共同条件：base64 字符集、≥ minlen、非纯十六进制（40 位提交 SHA、64 位 SHA-256）、含数字；
    #   strict=1（块外：整行规则、pend 前瞻、pem_inline 尾巴、散文里的连片）再要求：含 `+` 或 `=`（标识符与路径永远没有这两个字符），
    #     **或**大小写 / 数字类别切换率 ≥ 0.35——切换率 = 相邻字母数字字符之间（小写 / 大写 / 数字）类别变化次数 ÷ 相邻对数。
    #     随机 base64 0.6–0.98；标识符 / 路径 0.14–0.27（`AbstractSingletonProxyFactoryBean2Configuration` 0.26、
    #     `OAuth2AuthorizationServerConfig` 0.27、`src/main/java/com/example/v2/service/impl/UserService2Impl` 0.20）。
    #     已知代价：PKCS#8 首行 `MIIEvQIBADANBgkq…`（DER 常量头，0.33、无 `+`）在块外不算材料——它对所有同规格密钥相同，不是秘密；
    #     随后各行随机（≥ 0.6）照掩。20 位短行判错概率约 0.4%（仅块外兜底场景）。
    #   strict=0（块内）：只要共同条件——块内不会有路径 / 类名，第 15 条 128 行上界兜住装饰性 BEGIN。
    function b64_material(s, minlen, strict,   n, i, c, cls, prev, sw, pairs) {
      if (s !~ ("^[" B64C "=]+$")) return 0
      if (length(s) < minlen || is_hex(s)) return 0
      if (s !~ /[0-9]/) return 0
      if (!strict) return 1
      if (s ~ /[+=]/) return 1
      prev = ""; sw = 0; pairs = 0; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c ~ /[a-z]/) cls = "l"; else if (c ~ /[A-Z]/) cls = "u"; else if (c ~ /[0-9]/) cls = "d"; else continue
        if (prev != "") { pairs++; if (cls != prev) sw++ }
        prev = cls
      }
      return (pairs > 0 && sw / pairs >= 0.35)
    }
    # 纯十六进制串不算 base64 大块：40 位提交 SHA、64 位 SHA-256 在评审正文里很常见，而一行真正的
    # 密钥正文（64 个 base64 字符）全落在 [0-9a-f] 里的概率约 (22/64)^64，可以忽略。
    function is_hex(s) { return s ~ /^[0-9a-fA-F]+$/ }
    # 提示文案只写一处：两种措辞只在结尾不同，抄成两条整句时改一句会漏另一句。
    function pem_note(k,   head) {
      head = "> ⚠️ 上面的 PEM 块没有配对的 END 行（评审员只引用了起始行，或原文被截断）；"
      if (k > 0) return head "其后 " k " 行按原文保留并继续掩码。"
      return head "其后没有其他内容。"
    }
    function pem_hold(l) { held[++held_n] = l }
    function pem_drop() { held_n = 0; inpem = 0 }
    # 字段级闭合块：占位（起始行时已打）之后再补一行「其间 N 行已随密钥块一并屏蔽」（第 24 条：整块丢弃不能无声——BEGIN 在字段
    # 开头、END 在末尾时整段 P0 说明会蒸发而统计仍计数）
    function pem_close_block() {
      if (held_n > 0) print "> ⚠️ （其间 " held_n " 行已随密钥块一并屏蔽）"
      pem_drop()
    }
    # 字段级、到字段末仍未闭合：丢掉紧跟起始行的密钥正文（含 Proc-Type/DEK-Info 头与头后的那一个空行），其余按普通行掩码放出，
    # 整行 base64 与连片 base64 额外再掩一次。「块内行」的判定只有这一处（第 16 条）。
    # 有 END → 整块丢弃，零泄漏（**不判块内纯度**：闭合块里夹注释行 / 16 字符折行 / 单一大小写短尾 `AQAB` 都是密钥文件的常见形态，
    # 票 16 一度按「不纯就放出」处理，四行明文正文进了评论——第 22 条 P1 回退）。
    function pem_flush(   i, first, prev_hdr, l) {
      first = 1
      while (first <= held_n) {
        l = held[first]
        if (pem_is_hdr(l)) { prev_hdr = 1; first++; continue }
        if (prev_hdr && l ~ /^[[:space:]]*$/) { prev_hdr = 0; first++; continue }
        if (pem_body(l, 0, 0)) { prev_hdr = 0; first++; continue }
        break
      }
      print pem_note(held_n - first + 1)
      for (i = first; i <= held_n; i++) {
        l = redact_line(held[i])
        if (pem_body(l, 0, 0)) l = redact(l, "[" B64C "=]+")
        print redact_b64(l, 40, 0)
      }
      pem_drop()
    }
    # 一行普通文本要过的全部掩码（PEM 之外的每一行、以及未闭合块放出来的每一行都走这一份）。
    # 带前缀的令牌形态合成一个交替式、一次 redact（第 6 条 ①；awk 的 match 取最左最长，与逐条套用结果逐字节相同）。
    function redact_line(line) {
      if (pem_body(line, 40, 1)) {                                       # 第 17 条：整行密钥正文（无论出现在哪个字段 / 哪种模式）
        match(line, /^[[:space:]]*[-+>]?[[:space:]]*/)                     # 第 1 条补：diff / 引用前缀留下，只掩正文本身（`+` 也在 base64 字母表里）
        return substr(line, 1, RLENGTH) redact(substr(line, RLENGTH + 1), "[" B64C "=]+")
      }
      line = redact(line, PREFIX_RE)
      line = redact_url(line)
      line = redact_bearer(line)
      line = redact_header(line)
      return pem_inline(redact_assign(line))
    }
    # 上一行含起始标记但没锚定，这一行决定它的身份：像正文 → 上一行是块起始；否则上一行按普通行放出（含 pem_inline）
    function emit_pending() { if (pend != "") { print redact_line(pend); pend = "" } }
    # 起始行。锚定的（整行只有标记 + 装饰）：保行模式原样打出（只是标记），字段级换成占位（票 10 的形态：闭合 / 未闭合都在这一行
    # 之后补提示）。**悬挂行**（第 10 条再补的兜底：标记前面有散文、下一行才像正文）：标记前的散文必须过 redact_line 再打出——
    # 16-fix3 一度整行原样（保行）/ 整行换占位（字段级），`硬编码凭证 AKIA… 与私钥 -----BEGIN…-----` 里的 AKIA 就跟着原样出去、
    # 或者整段问题陈述被无声吞掉（第 11 条 P0 回归）。标记后同一行的尾巴：保行整段 ****（第 42 条，与 pem_inline 一致），字段级随块丢弃。
    # anchored 由调用方传入（第 1 条补：锚定 BEGIN 规则与 pend 规则都已经算过 pem_marker，不再剥一次装饰）
    function begin_block(l, anchored,   pre, mk, tail) {
      inpem = 1; kb_lines = 0
      if (anchored) { if (keeplines) print l; else print PEM_PLACEHOLDER; return }
      match(l, PEM_BEGIN_RE)
      # 三段先切好再掩：redact_line 内部的 match() 会改写 RSTART / RLENGTH
      pre = substr(l, 1, RSTART - 1); mk = substr(l, RSTART, RLENGTH); tail = substr(l, RSTART + RLENGTH)
      # 尾巴（同一行紧跟标记的密钥正文）整段 ****（第 42 条）：与 pem_inline 一致——PEM 正文没有保留前 4 后 4 的意义
      if (keeplines) print redact_line(pre) mk redact_b64(redact_line(tail), 20, 1)
      else           print redact_line(pre) PEM_PLACEHOLDER
    }
    BEGIN {
      PEM_PLACEHOLDER = "**** （脚本已屏蔽一段 PRIVATE KEY 内容）"
      PEM_BODY_PH = "****（PEM 正文已屏蔽）"
      PEM_BEGIN_RE = "-----BEGIN [A-Z ]*PRIVATE KEY-----"
      PEM_END_RE = "-----END [A-Z ]*PRIVATE KEY-----"
      B64C = "A-Za-z0-9+/"
      URL_STRICT_RE = "[a-zA-Z][a-zA-Z0-9+.-]*://[A-Za-z0-9._~+-]+:[A-Za-z0-9._~+=%-]+@"
      URL_LOOSE_RE = "[a-zA-Z][a-zA-Z0-9+.-]*://[A-Za-z0-9_~+-]+:[A-Za-z0-9._~+/=%-]+@"
      PREFIX_RE = "(AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[0-9A-Z]{16}" \
                  "|ghp_[0-9A-Za-z]{20,}" \
                  "|github_pat_[0-9A-Za-z_]{20,}" \
                  "|gh[opsu]_[0-9A-Za-z]{20,}" \
                  "|xox[baprs]-[0-9A-Za-z-]{10,}" \
                  "|AIza[0-9A-Za-z_-]{30,}" \
                  "|sk-[0-9A-Za-z]{20,}" \
                  "|eyJ[0-9A-Za-z_-]{8,}\\.[0-9A-Za-z_-]{8,}\\.[0-9A-Za-z_-]{8,}"
      pend = ""
    }
    # 字段分隔行（review_redact_json 用随机 nonce 拼出，模型伪造不出）：一个字段结束——悬而未决的上一行放出、未闭合的 PEM 就地放出，
    # 分隔行原样透传
    sentre != "" && $0 ~ sentre { emit_pending(); if (inpem) { if (keeplines) inpem = 0; else pem_flush() } print; next }
    pend != "" { if (!inpem && (pem_body($0, 20, 1) || pem_is_hdr($0))) { begin_block(pend, 0); pend = "" } else emit_pending() }
    inpem && pem_marker($0, PEM_END_RE) { if (keeplines) { print; inpem = 0 } else pem_close_block(); next }
    inpem && !keeplines { pem_hold($0); next }
    inpem && keeplines {
      # 第 15 条 ①：保行模式的块状态有上界——连续 128 行没有 END 就退出（RSA-8192 的 PEM 约 100 行，含 RFC 1421 头也不到 128），
      # 否则围栏里引用的一条裸 BEGIN 会让后文所有标识符行 / 代码行都按块内处理；已替换的行不回退、不加提示（保行不能加行）
      if (++kb_lines > 128) { inpem = 0 }
    }
    inpem && keeplines {
      if (pem_marker($0, PEM_BEGIN_RE)) { print; next }                 # 块内又一条起始行：只是标记
      if (pem_body($0, 0, 0) || pem_is_hdr($0)) { print PEM_BODY_PH; next }   # 正文行 / RFC 1421 头：等行数替换（第 11 条）
      if ($0 ~ /^[[:space:]]*$/) { print; next }
      print redact_b64(redact_line($0), 40, 0); next                    # 起始行之后的散文：继续掩码，并掩 ≥ 40 位 base64 连片（连片须像密钥碎片）
    }
    pem_marker($0, PEM_BEGIN_RE) { begin_block($0, 1); next }
    # 兜底是主规则（第 10 条再补）：一行**含**起始标记（前面有任何文字：`**F1** 硬编码私钥：-----BEGIN…-----`）且下一行就是密钥正文
    # （pem_body_key：≥ 20 位 base64、含数字与大小写——长路径 src/main/java/…/UserService 无数字不中）→ 块起始；
    # 下一行不是正文的是句中引用，按普通行放出。同一行已带 END 标记的（一行 .env 形态、「从 BEGIN 到 END」的散文）交给 pem_inline。
    $0 ~ PEM_BEGIN_RE && $0 !~ PEM_END_RE { pend = $0; next }
    { print redact_line($0) }
    END { emit_pending(); if (inpem && !keeplines) pem_flush() }'
}

# --- 字段级掩码：validated.json 的唯一收口点（16-fix2，Kent 裁决方案 C）---
# 用法：review_redact_json <validated.json>   就地改写；rc 0 = 成功；非零 = 失败，原文件一个字节不动
# 结构化路径的全部模型文本只存在于归一化契约里，所有渲染器与日志行都从它（或派生的 plan.json）读。review_validate 在**清洗之前**
# 调用本函数（第 15 条），对 summary / verdict / verdict_reason / 每条 title / id / category / body / fix 逐字段过
# review_redact_secrets（PEM 整块删除只在这里发生——字段里没有脚本结构，删行吞不到章节、表格与标记），再回注。做法（第 3 / 4 条）：
# jq 把字段按固定顺序倒出、每个字段后跟一行带随机 nonce 的分隔行（单行槽位与多行槽位各一份）；awk 掩码（分隔行让未闭合的 PEM 在
# 字段边界放出、不会跨字段吞掉下一个字段；单行槽位用保行模式）；一次**静态** jq 用 split 切回并按同一顺序回填（rtrimstr 去掉 -r 输出
# 补的那个换行）。与字段数无关；分隔行的形状只在 REVIEW_FIELD_SENTINEL_FMT 一处定义，倒出 / awk / 切回三处都从它派生。
REVIEW_FIELD_SENTINEL_FMT='<<<KIRO_FIELD:%s:%s>>>'   # %s = nonce, %s = 字段序号
_review_field_sentinel() { printf "$REVIEW_FIELD_SENTINEL_FMT" "$1" "$2"; }   # <nonce> <idx>
_review_field_sentinel_re() {  # <nonce> → 能匹配任意序号的 ERE（同时也是 Oniguruma 能用的形状）
  local lit; lit=$(_review_field_sentinel "$1" $'\001')
  lit=$(_review_ere_escape "$lit"); printf '%s' "${lit//$'\001'/[0-9]+}"
}
# --- 掩码到文件（16-fix4 第 4 条；review_redact_file / review_render_degraded / review_redact_json 共用）---
# awk 退出非零、或「输入非空而输出为空」都算失败，失败时删掉输出文件、报错行以调用方名开头。
# 用法：_review_redact_to <输入文件> <输出文件> <调用方名> <报错尾巴> [review_redact_secrets 的参数…]
_review_redact_to() {
  local in="$1" out="$2" who="$3" tail="$4"; shift 4
  if ! review_redact_secrets "$@" < "$in" > "$out" || [[ ! -s "$out" && -s "$in" ]]; then
    rm -f "$out"; echo "$who: 掩码失败（awk 退出非零或无输出）${tail}" >&2; return 1
  fi
}
review_redact_json() {
  local file="${1-}" dir nonce sre pre suf
  [[ -n "$file" && -r "$file" ]] || { echo "review_redact_json: 文件不可读：${file}" >&2; return 2; }
  jq -e 'type == "object" and (.findings | type) == "array"' "$file" >/dev/null 2>&1 \
    || { echo "review_redact_json: 不是归一化契约（顶层不是对象 / findings 不是数组）：${file}" >&2; return 2; }
  dir=$(mktemp -d) || { echo "review_redact_json: 建不出临时目录：${file}" >&2; return 1; }
  nonce=$(review_new_nonce)
  pre=$(_review_field_sentinel "$nonce" $'\001'); suf=${pre#*$'\001'}; pre=${pre%%$'\001'*}
  sre=$(_review_field_sentinel_re "$nonce")
  # 两份倒出（第 19 条）：单行槽位（verdict、每条 title / id / category）走保行模式——起始标记当 title 时不能变成两行
  # （占位 + 提示），否则结论行 / 加粗 / 行内首行都断成两行、指纹只 hash 到第一行；多行槽位（summary / verdict_reason / body / fix）
  # 走可删行的字段级模式。category / id 也进清单（第 31 条：全部模型文本）。
  if ! jq -r --arg pre "$pre" --arg suf "$suf" '
        [.verdict, (.findings[] | .title, .id, .category)]
        | to_entries[] | (if (.value | type) == "string" then .value else "" end) + "\n" + $pre + (.key | tostring) + $suf' \
        "$file" > "$dir/dump-k" \
     || ! jq -r --arg pre "$pre" --arg suf "$suf" '
        [.summary, .verdict_reason, (.findings[] | .body, .fix)]
        | to_entries[] | (if (.value | type) == "string" then .value else "" end) + "\n" + $pre + (.key | tostring) + $suf' \
        "$file" > "$dir/dump-f"; then
    rm -rf "$dir"; echo "review_redact_json: 倒出字段失败：${file}" >&2; return 1
  fi
  if ! _review_redact_to "$dir/dump-k" "$dir/masked-k" review_redact_json "：${file}" --keep-lines --sentinel "^${sre}\$" \
     || ! _review_redact_to "$dir/dump-f" "$dir/masked-f" review_redact_json "：${file}" --sentinel "^${sre}\$"; then
    rm -rf "$dir"; return 1
  fi
  # 静态 jq：按分隔行切回，第 k 段就是第 k 个字段（与倒出顺序同一份约定）。被整块删掉的字段只剩空段，rtrimstr 后是 ""。
  # 输出文件放在目标同目录、失败时原文不动（_review_jq_inplace，第 3 / 28 条）
  if ! _review_jq_inplace "$file" review_redact_json "回注字段" -c --rawfile mk "$dir/masked-k" --rawfile mf "$dir/masked-f" --arg re "${sre}"$'\n' '
        ($mk | split($re; null) | map(rtrimstr("\n"))) as $k
        | ($mf | split($re; null) | map(rtrimstr("\n"))) as $f
        | .verdict = $k[0] | .summary = $f[0] | .verdict_reason = $f[1]
        | reduce range(.findings | length) as $i (.;
            .findings[$i].title = $k[1 + 3 * $i] | .findings[$i].id = $k[2 + 3 * $i] | .findings[$i].category = $k[3 + 3 * $i]
            | .findings[$i].body = $f[2 + 2 * $i] | .findings[$i].fix = $f[3 + 2 * $i])'; then
    rm -rf "$dir"; return 1
  fi
  rm -rf "$dir"
}

# --- 脚本标记行的识别（评审标记 / 行内标记 / 隐藏历史）：从三个常量派生，不手写第四份字面量（第 11 条）---
# 纯 bash 转义（第 8 条：原先每次调用起两个 sed 给三个编译期常量转义，每个 MR 二十来次）
_review_ere_escape() {
  local s="$1" c out="" i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      '['|']'|'/'|'.'|'^'|'$'|'*'|'+'|'?'|'('|')'|'{'|'}'|'|'|'\') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}
# 加载期算一次的常量（16-fix4 第 16 条）：三个常量与 _review_ere_escape 都在上面定义完了才能算；_review_marker_line_re 只是它的取值口，
# _review_marker_line_re_build 是派生公式（测试改常量后用它重算，证明没有第四份手写字面量）
_review_marker_line_re_build() {
  printf '%s|^%s|^%s' "$REVIEW_MARKER_LINE_RE" \
    "$(_review_ere_escape "$REVIEW_INLINE_MARKER_PREFIX")" "$(_review_ere_escape "$REVIEW_HISTORY_PREFIX")"
}
REVIEW_MARKER_LINE_RE_ALL=$(_review_marker_line_re_build)
_review_marker_line_re() { printf '%s' "$REVIEW_MARKER_LINE_RE_ALL"; }
# 文件的**记录数**（最后一行没有换行也算一行）：不受 NUL 字节影响。一个 fork（第 8 条）。
_review_line_count() { LC_ALL=C awk 'END { print NR }' "$1"; }
# 两份文件的记录数一次算完（16-fix4 第 17 条：review_redact_file 的保行守卫原先起两个 awk，这里合成一个）：输出「前者 后者」。
# 第一份文件必须非空（调用方已保证），否则文件切换点判不出来。
_review_line_counts() { LC_ALL=C awk 'FNR == 1 { fi++ } fi == 1 { a++ } END { print a + 0, NR - a }' "$1" "$2"; }
# --- 守卫 + 原子替换（review_redact_file 与 review_truncate_comment 共用；第 12 条）---
# 用法：_review_replace_guarded <原文件> <新文件> <调用方名>
#   原文件里的每一行脚本标记（评审标记 / 行内标记 / 隐藏历史）必须在新文件里逐字节仍在，否则拒绝写回。
#   rc 0 = 已把新文件 mv 到原文件；rc 3 = 标记丢失或被改写；rc 4 = 写回（mv）失败；rc 5 = grep 本身失败（不是「没有标记」——
#   fail-closed，第 23 条再补）。独立于 review_truncate_comment 自己的 rc 1（未超限）/ rc 2（参数错）（第 26 条）。
#   非零返回时新文件已删除、原文件一个字节不动。
# 为什么要守：丢了标记的评论发出去，下一次评审就认不出它——汇总 → 新建第二条汇总（违反 I4）、旧报告与历次记录不可恢复；
# 行内 → 去重失守、同一处重复发。宁可让调用方失败（回写失败评论 / 转折叠区，形态完整）。
# grep 一律 `LC_ALL=C grep -a`：模型 body 里一个 NUL 字节会让 grep 把评论当二进制，BSD grep 把「Binary file matches」
# 打到 stdout 而 -qxF 失败（一个 NUL = 整份评审被替换成最小失败评论），GNU ≥ 3.5 则静默放行（第 23 条）。
_review_replace_guarded() {
  local orig="$1" new="$2" who="$3" markers rc=0 m
  # 调用方都开着 errexit：grep 的 rc 1（零匹配）必须用 `|| rc=$?` 接住，否则赋值语句本身就把整个脚本杀掉
  markers=$(LC_ALL=C grep -a -E "$REVIEW_MARKER_LINE_RE_ALL" "$orig") || rc=$?
  if (( rc > 1 )); then rm -f "$new"; echo "$who: 读取脚本标记行失败（grep rc=${rc}），拒绝写回" >&2; return 5; fi
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    rc=0; LC_ALL=C grep -a -qxF -- "$m" "$new" || rc=$?
    if (( rc == 1 )); then rm -f "$new"; echo "$who: 脚本标记行丢失或被改写，拒绝写回：${m:0:60}" >&2; return 3; fi
    if (( rc > 1 )); then rm -f "$new"; echo "$who: 核对脚本标记行失败（grep rc=${rc}），拒绝写回" >&2; return 5; fi
  done <<< "$markers"
  mv -f "$new" "$orig" || { rm -f "$new"; echo "$who: 写回失败：${orig}" >&2; return 4; }
}

# --- 文档级兜底：评论出口前的**严格保行**掩码（16-fix2 方案 C）---
# 用法：review_redact_file <文件>   就地改写；rc 0 = 已改写；rc 1 = 掩码程序失败；rc 2 = 文件不可读 / 为空；
#   rc 3 = 守卫拒绝（行数变化或标记行丢失）；rc 4 = 写回失败；rc 5 = 守卫命令（grep / 行数统计）本身失败。
#   非零时**原文件一个字节都没动**，调用方按渲染失败处理。
# 字段级掩码（review_redact_json）已经覆盖了 validated.json 派生的全部文本；这一遍兜住任何绕过 validated.json 的输出面
# （元信息表里的分支名、由 API 字符串拼出的 notice、失败评论的 --reason）。--keep-lines：不删行不加行，行内替换为主；
# 唯一的整行改写是 PEM 块内的正文行 / RFC 1421 头等行数换成占位（16-fix3 第 11 条起有块状态，第 15 条起块状态最多 128 行），
# 所以结构上不可能吞掉章节；守卫两条都要：行数前后相等（结构上排除吞行）+ 标记行逐字节仍在。
# 行内评论正文今天确实只含 validated.json 的字段 + 指纹 + sha，也照样过这一遍：这是**有意的双保险**（第 9 条不采纳「跳过」）——
# 兜底就是为「将来某个出口混入未经 validated.json 的文本」而设。成本（16-fix4 第 17 条实测，3 KB 行内正文）：掩码 awk + 一次
# 行数统计 awk + 守卫的 grep（标记行数 + 1 次）≈ 6 个进程、约 0.1 s；默认 10 条行内评论约 1 s。
review_redact_file() {
  local file="${1-}" out counts lines_in lines_out
  [[ -n "$file" ]] || { echo "review_redact_file: 缺少文件参数" >&2; return 2; }
  [[ -r "$file" ]] || { echo "review_redact_file: 文件不可读：${file}" >&2; return 2; }
  [[ -s "$file" ]] || { echo "review_redact_file: 文件为空：${file}" >&2; return 2; }
  out=$(mktemp "${file}.redact.XXXXXX") || { echo "review_redact_file: 建不出临时文件：${file}" >&2; return 1; }
  _review_redact_to "$file" "$out" review_redact_file "：${file}" --keep-lines || return 1
  counts=$(_review_line_counts "$file" "$out") && [[ "$counts" =~ ^[0-9]+\ [0-9]+$ ]] \
    || { rm -f "$out"; echo "review_redact_file: 统计行数失败，拒绝写回：${file}" >&2; return 5; }
  lines_in=${counts% *}; lines_out=${counts#* }
  if [[ "$lines_in" != "$lines_out" ]]; then
    rm -f "$out"
    echo "review_redact_file: 掩码后行数从 ${lines_in} 变成 ${lines_out}（文档级掩码必须保行），拒绝写回：${file}" >&2
    return 3
  fi
  _review_replace_guarded "$file" "$out" review_redact_file
}

# --- 降级评论：结构化解析失败时贴出评审员原文 ---
# 用法：review_render_degraded --text <清洗后的原文文件> --sha X --src A --dst B --ts T --diff-note N \
#                             [--run 1] [--reason 原因]
# 标题含「结构化解析失败」（票 02 验收项），正文是原文全文。原文先过脚本侧掩码（保行模式：PEM 正文逐行就地屏蔽、不删行，
# 两条标记行之间的评审内容不会整段消失，第 14 条），掩码失败则整个渲染失败（rc 2）——与 review_redact_file / review_redact_json
# 同一 fail-closed 契约，绝不能让一份未掩码或半截的原文以「渲染成功」的样子发出去（第 13 条）。
review_render_degraded() {
  _review_parse_render_args "$@" || return $?
  [[ -n "$_RR_TEXT" ]] || { echo "review_render_degraded: 缺少必填参数 --text" >&2; return 2; }
  [[ -r "$_RR_TEXT" ]] || { echo "review_render_degraded: 原文文件不可读：${_RR_TEXT}" >&2; return 2; }
  local hist masked
  masked=$(mktemp)
  _review_redact_to "$_RR_TEXT" "$masked" review_render_degraded "，拒绝渲染降级评论" --keep-lines || return 2
  # 降级时没有可信的分级计数（正是因为解析失败），历次表这一行记 status=degraded、计数为 -（三步回退与失败评论同一份）
  hist=$(mktemp)
  review_history_for_run "${_RR_HISTORY:--}" "$_RR_RUN" "$_RR_SHA" degraded review_render_degraded > "$hist"
  _review_render_header "$REVIEW_TITLE_DEGRADED" "$hist"
  echo ""
  # --reason 是一个真实的不受信 sink：kiro-review.sh 在「契约 JSON 顶层结构不符」时把 review_validate
  # 的最后一行 stderr 拼进 reason，而那是 jq 自己的报错——jq 会把出错的取值回显在消息里
  # （`Cannot iterate over string ("<模型文本…")`），模型文本就这样进了这一行。所以与失败评论一样过结构
  # 清洗；再多一步折成单行，因为它嵌在一行 `> ` 引用块里（失败评论的 reason 独占一行，不用折）。
  echo "> ⚠️ 评审已完成，但输出不符合结构化契约（$(_review_sanitize_oneline "${_RR_REASON:-未说明原因}")），无法给出分级问题清单与统计。"
  echo "> 下面是评审员输出的原文（已由脚本对疑似凭证再做一次掩码，并把其中的 Markdown 标题、分隔线与"
  echo "> HTML 注释降级为普通文本——评论的结构只能来自脚本，否则原文里可以伪造标题与评审标记）。"
  # 「怎么重新评审」与页脚同一份取值：两处写死同一句话时，换档位只改一处会留下另一处的假承诺
  echo "> 结构化输出通常在下一次评审就能恢复——$(_review_rerun_hint)。"
  echo ""
  echo "---"
  echo ""
  review_sanitize_md < "$masked"
  rm -f "$masked"
  echo ""
  review_render_history_table "$hist"
  rm -f "$hist"
  echo ""
  review_render_footer "$_RR_RUN"
}

# --- 失败评论：评审没跑完时唯一能到达 MR 的信息通道（spec I10 失败可见）---
# 用法：review_render_failure --reason <失败说明> --sha X --src A --dst B --ts T --diff-note N
#                            [--run N] [--history <历史 JSON 文件>] [--log-hint <一句话>]
# 与成功/降级评论**同形**：标题、评审标记、历史标记、元信息表、历次表、页脚全部出自同一份代码。
# 早先这段是在 kiro-review.sh 里手写第二份的，结果是「形态一致」这个不变量靠人肉维护，
# 而给两个渲染函数加的历次记录守卫漏掉了第三份拷贝。
# 本函数刻意**不因历次记录异常而失败**：历史算不出来就退化成「只有本次一行」，
# 绝不能出现「评审失败 + 失败评论也发不出去」的组合。
# --reason 里可能带上 runFinished.status 之类来自事件流的取值（不受信），所以过一遍结构清洗。
review_render_failure() {
  _review_parse_render_args "$@" || return $?
  [[ -n "$_RR_REASON" ]] || { echo "review_render_failure: 缺少必填参数 --reason" >&2; return 2; }
  local hist
  hist=$(mktemp)
  review_history_for_run "${_RR_HISTORY:--}" "$_RR_RUN" "$_RR_SHA" failed review_render_failure > "$hist"
  _review_render_header "$REVIEW_TITLE_FAILED" "$hist"
  echo ""
  printf '⚠️ 评审未完成：'
  printf '%s' "$_RR_REASON" | review_sanitize_md
  echo ""
  if [[ -n "$_RR_LOG_HINT" ]]; then
    echo ""
    printf '%s' "$_RR_LOG_HINT" | review_sanitize_md
    echo ""
  fi
  echo ""
  review_render_history_table "$hist"
  rm -f "$hist"
  echo ""
  review_render_footer "$_RR_RUN"
}
