#!/usr/bin/env bash
# Security Agent 评审员的分析库（Phase 2b spec「Security Agent 评审员」R10，issue 12）：把 BatchGetFindings 的输出归一成报告 JSON。
# 只有函数定义与常量，source 时不执行任何动作；纯 jq，不调 AWS（驱动 aws/reviewers/security.sh 负责调用）。
# 发现的形状以 issue 09 的真实输出为准（tests/fixtures/security/），不以文档为准：
#   · filePath 有两种形状：`/tmp/opt/source_code/code_sc-<id>/<相对 zip 根的路径>` 或直接的相对路径；
#   · riskType 是自由字符串（实测有枚举外的 SECURITY_MISCONFIGURATION、AUTHENTICATION_BYPASS……）；
#   · 没有 reasoning / validationStatus / riskScore（validationMode=DISABLED 下）；label 是自由文本。

# 报告 JSON 的形状：
#   {findings: [{name, riskLevel, rank, confidence, riskType, description,
#                locations: [{path, start, end, label, known}]}],     # 按严重级别序、再按 name 排
#    counts: {CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL, UNKNOWN},
#    returned: 服务返回的条数（过滤之前；= 30 时是服务上限）, false_positives: 丢掉的误报条数, unmatched: 不在归档清单里的位置数}
# 严重级别序（spec「严重级别序」，只在排序与计数时用）：CRITICAL 0 · HIGH 1 · MEDIUM 2 · LOW 3 · INFORMATIONAL 4 · UNKNOWN 5。
SA_RISK_LEVELS="CRITICAL HIGH MEDIUM LOW INFORMATIONAL UNKNOWN"

# shellcheck disable=SC2016  # jq 程序里的 $ 是 jq 变量
_SA_JQ_DEFS='
  def sa_levels: ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNKNOWN"];
  def sa_level: (if type == "string" then ascii_upcase else "" end) as $l
                | if (sa_levels | index($l)) != null then $l else "UNKNOWN" end;
  def sa_rank: sa_level as $l | sa_levels | index($l);
  def sa_conf: . as $c | if (["FALSE_POSITIVE", "UNCONFIRMED", "LOW", "MEDIUM", "HIGH"] | index($c)) != null then $c else "UNKNOWN" end;
  def sa_risktype: if type == "string" and test("^[A-Z_]{1,64}$") then . else "OTHER" end;
  def sa_path: if type != "string" then ""
               elif test("^/tmp/opt/source_code/code_sc-[^/]+/") then sub("^/tmp/opt/source_code/code_sc-[^/]+/"; "")
               else . end;
  def sa_line: if type == "number" and . >= 0 then floor else null end;
'

# 用法：sa_findings_report <归档文件清单（一行一个路径）> <BatchGetFindings 输出 JSON 文件…> → stdout 报告 JSON
# 多个批次合并后按 findingId 去重（同一条发现分在两批里也只算一次）。清单读不到时当作空（每个位置都是「未能对应」）。
sa_findings_report() {
  local manifest="$1"; shift
  [[ "$#" -ge 1 ]] || { echo "sa_findings_report: 至少要一个 BatchGetFindings 输出" >&2; return 2; }
  local mf
  mf=$(mktemp) || return 1
  [[ -r "$manifest" ]] && cat "$manifest" > "$mf"
  jq -s --rawfile manifest "$mf" "${_SA_JQ_DEFS}"'
    ($manifest | split("\n") | map(select(length > 0)) | reduce .[] as $p ({}; .[$p] = true)) as $files
    | [.[] | (.findings // [])[]] | unique_by(.findingId) as $all
    | ($all | map(select((.confidence | sa_conf) != "FALSE_POSITIVE"))) as $kept
    | ($kept | map({
        name: ((.name // "") | tostring),
        riskLevel: (.riskLevel | sa_level),
        rank: (.riskLevel | sa_rank),
        confidence: ((.confidence // "") | sa_conf),
        riskType: (.riskType | sa_risktype),
        description: ((.description // "") | tostring),
        locations: [(.codeLocations // [])[] | (.filePath | sa_path) as $p
                    | {path: $p, start: (.lineStart | sa_line), end: (.lineEnd | sa_line),
                       label: ((.label // "") | tostring), known: ($files[$p] == true)}]
      }) | sort_by(.rank, .name)) as $f
    | {findings: $f,
       counts: (reduce sa_levels[] as $l ({}; .[$l] = ([$f[] | select(.riskLevel == $l)] | length))),
       returned: ($all | length),
       false_positives: (($all | length) - ($kept | length)),
       unmatched: ([$f[].locations[] | select(.known | not)] | length)}' "$@"
  local rc=$?
  rm -f "$mf"
  return "$rc"
}

# 历次表的三个计数槽（档案 security 的表头「高/中/低」）：CRITICAL+HIGH / MEDIUM / LOW 及其它 → stdout 三个数（空格分隔）
sa_history_counts() {  # <报告 JSON 文件>
  jq -r '.counts | "\(.CRITICAL + .HIGH) \(.MEDIUM) \(.LOW + .INFORMATIONAL + .UNKNOWN)"' "$1"
}
