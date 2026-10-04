#!/usr/bin/env bash
# Inspector 评审员的纯数据处理（Phase 2b spec「Inspector 评审员」，issue 07）：组件键、引入/存量分类、ScanSbom 调用计划、
# 结果合并与严重级别。只有函数定义；全部是 jq，输入输出都是文件，便于用真实输出做 fixture（D4：fixture 不从文档样例派生）。
#
# 组件键：purl 去掉 qualifiers（?…）与 subpath（#…）、整体转小写。head 有、base 没有的键 = 本 MR 引入。
# 严重级别（每条漏洞）：ratings[] 里只看 CVSS 评级（method 以 CVSS 开头，任何来源；EPSS、SSVC、厂商 other 评级不算），取最高的
#   一个，都没有 = unknown。issue 01 用真实输出定下：只有这条规则算出的计数等于同一份输出 metadata.properties 里 Inspector 自己给的
#   critical/high/medium/low 计数（「NVD 的 v3 优先」差了两条）；tests/test-inspector.sh 的「与 metadata 计数一致」那一条守着。
# 严重级别序（只用于排序与预算）：critical 0 · high 1 · medium 2 · low 3 · 其它（none/info/unknown）4。

_INSPECTOR_JQ_DEFS='
  def ckey: ascii_downcase | sub("[?#].*$"; "");
  def sevrank: {"critical": 0, "high": 1, "medium": 2, "low": 3}[.] // 4;
  def bucket: if (. | sevrank) < 4 then . else "other" end;
  def is_cvss: ((.method // "") | ascii_downcase | startswith("cvss"));
  def severity:
    ([(.ratings // [])[] | select(is_cvss) | select(((.severity // "") | type) == "string")]) as $r
    | if ($r | length) > 0 then ([$r[].severity | ascii_downcase] | sort_by(sevrank) | .[0])
      else "unknown" end;
  def prop($name): [(.properties // [])[] | select(.name == $name) | .value] | .[0];
'

# 组件键集合（排序去重，一行一个）
inspector_component_keys() {  # <sbom.json>
  jq -r "${_INSPECTOR_JQ_DEFS}"' [(.components // [])[] | (.purl // empty) | select(type == "string") | ckey] | unique[]' "$1"
}

# head 里本 MR 引入的组件（base 里没有它的键）→ JSON 数组
inspector_introduced() {  # <head.cdx.json> <base.cdx.json>
  jq -c --slurpfile base "$2" "${_INSPECTOR_JQ_DEFS}"'
    ([($base[0].components // [])[] | (.purl // empty) | select(type == "string") | ckey] | unique) as $b
    | [(.components // [])[] | select((.purl | type) == "string") | select((.purl | ckey) as $k | ($b | index($k)) == null)]' "$1"
}

# ScanSbom 调用计划：引入的组件在前（总是扫），其余在后（尽力而为），每块 ≤ <每次组件数>，最多 <调用上限> 块。
# 写出 <目录>/chunk-<n>.json（最小的 CycloneDX 1.5 文档）；stdout 一行「<块数> <被丢下的存量组件数>」。
inspector_plan_chunks() {  # <head.cdx.json> <introduced.json> <每次组件数> <调用上限> <目录>
  local head="$1" intro="$2" per="$3" max="$4" dir="$5" n
  [[ "$per" =~ ^[1-9][0-9]*$ && "$max" =~ ^[1-9][0-9]*$ ]] || return 2
  mkdir -p "$dir" || return 1
  jq -c --slurpfile intro "$intro" --argjson per "$per" --argjson max "$max" "${_INSPECTOR_JQ_DEFS}"'
    ([$intro[0][] | .purl | ckey]) as $ik
    | [(.components // [])[] | select((.purl | type) == "string")] as $all
    | ([$all[] | select((.purl | ckey) as $k | ($ik | index($k)) != null)]
       + [$all[] | select((.purl | ckey) as $k | ($ik | index($k)) == null)]) as $ordered
    | [range(0; ($ordered | length); $per) as $i | $ordered[$i:$i + $per]] as $chunks
    | {chunks: $chunks[0:$max], dropped: ([$chunks[$max:][][]] | length)}' "$head" > "$dir/plan.json" || return 1
  n=$(jq '.chunks | length' "$dir/plan.json") || return 1
  local i=0
  while (( i < n )); do
    jq -c --argjson i "$i" '{bomFormat: "CycloneDX", specVersion: "1.5", version: 1, components: .chunks[$i]}' \
      "$dir/plan.json" > "$dir/chunk-$((i + 1)).json" || return 1
    i=$((i + 1))
  done
  printf '%s %s\n' "$n" "$(jq '.dropped' "$dir/plan.json")"
}

# 合并若干份 ScanSbom 结果（CycloneDX，`sbom` 字段或直接是文档都认）→ 报告 JSON：
#   {vulns: [{id, severity, rank, introduced, kev, exploit, malicious, epss, description, advisory,
#             components: [{purl, name, version, fixed, path, introduced}]}], counts: {introduced: {…}, existing: {…}}}
# 同一个漏洞 id 出现在多块里（或影响多个组件）合并成一条；任一受影响组件是引入的 → 这条算引入。
inspector_merge() {  # <introduced.json> <结果文件…>
  local intro="$1"; shift
  jq -cs --slurpfile intro "$intro" "${_INSPECTOR_JQ_DEFS}"'
    ([$intro[0][] | .purl | ckey]) as $ik
    | [ .[] | (if has("sbom") then .sbom else . end) as $doc
        | ([($doc.components // [])[] | {key: (."bom-ref" // ""), value: .}] | from_entries) as $comp
        | ($doc.vulnerabilities // [])[]
        | . as $v
        | { id: (.id // "unknown"), severity: severity,
            kev: ((prop("amazon:inspector:sbom_scanner:cisa_kev_date_added") // "") != ""),
            exploit: (prop("amazon:inspector:sbom_scanner:exploit_available") == "true"),
            malicious: (prop("amazon:inspector:sbom_scanner:is_malicious") == "true"),
            epss: ([(.ratings // [])[] | select((.source.name // "") == "EPSS") | .score] | .[0]),
            description: (.description // ""),
            advisory: ([(.advisories // [])[] | .url | select(type == "string")] | .[0] // ""),
            components: [ (.affects // [])[] | .ref as $r | ($comp[$r] // {}) as $c | select($c.purl)
                          | { purl: $c.purl, name: ($c.name // ""), version: ($c.version // ""),
                              fixed: ($v | prop("amazon:inspector:sbom_scanner:fixed_version:" + $r) // ""),
                              path: ($c | (prop("amazon:inspector:sbom_scanner:path")
                                           // prop("amazon:inspector:sbom_generator:source_path") // "")),
                              introduced: (($c.purl | ckey) as $k | ($ik | index($k)) != null) } ] } ]
    | group_by(.id)
    | map(.[0] + {components: ([.[].components[]] | unique_by(.purl)),
                  kev: any(.[]; .kev), exploit: any(.[]; .exploit), malicious: any(.[]; .malicious)})
    | map(. + {rank: (.severity | sevrank), introduced: any(.components[]; .introduced)})
    | sort_by(.rank, .id)
    | {vulns: .,
       counts: {introduced: (reduce (.[] | select(.introduced)) as $v ({critical: 0, high: 0, medium: 0, low: 0, other: 0};
                              .[$v.severity | bucket] += 1)),
                existing: (reduce (.[] | select(.introduced | not)) as $v ({critical: 0, high: 0, medium: 0, low: 0, other: 0};
                              .[$v.severity | bucket] += 1))}}' "$@"
}

# 与 Inspector 自己的计数对拍用：一份结果里按上面规则算出的 critical/high/medium/low 计数 vs metadata.properties 里的那四个
inspector_counts_vs_metadata() {  # <结果文件> → 「我们的 / Inspector 的」两段，各四个数
  jq -r "${_INSPECTOR_JQ_DEFS}"'
    (if has("sbom") then .sbom else . end) as $d
    | ([($d.vulnerabilities // [])[] | severity]) as $s
    | ([ "critical", "high", "medium", "low" ] | map(. as $k | [$s[] | select(. == $k)] | length) | join(" "))
      + " / "
      + ([ "critical", "high", "medium", "low" ]
         | map(. as $k | ([($d.metadata.properties // [])[] | select(.name == "amazon:inspector:sbom_scanner:" + $k + "_vulnerabilities") | .value] | .[0] // "?"))
         | join(" "))' "$1"
}
