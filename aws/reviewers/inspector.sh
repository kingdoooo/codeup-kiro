#!/usr/bin/env bash
# Inspector 评审员（Phase 2b spec「Inspector 评审员」，issue 07）。扫描任务的子进程：scan-entrypoint.sh 以只含本评审员令牌的环境
# exec 它。退出码约定见 lib/reviewer.sh（0 = 已回写；10 = 被取代；其它 = 兜底接手）。
# 流程：L7 租约 + 核对最新提交 → 定位上一条汇总 → 读执行器准备的两份 CycloneDX → 引入/存量分类 → ScanSbom（引入的组件先送、
# 分块、总调用数有上限）→ 合并 → 渲染 → 掩码、截断 → 原地更新或新建。任何一步失败都发本评审员自己的失败评论（固定文案 + 代号，F3）。
set -euo pipefail
PKG=/opt/integration
REVIEW_PROFILE=inspector
source "$PKG/reviewers/lib/reviewer.sh"
source "$PKG/reviewers/lib/inspector-lib.sh"
source "$PKG/reviewers/lib/inspector-render.sh"

# ScanSbom 的有效组件上限：模型文档写 2,000、SBOM Generator 文档写 5,000（issue 01 实测后定）；按小的那个留余量
INSPECTOR_COMPONENTS_PER_CALL=1900
REVIEWER_LEASE_WAIT="${REVIEWER_LEASE_WAIT:-900}"
REVIEW_META_NOTE="组件"
# AWS CLI 自己的有界重试（standard 模式会按 ThrottlingException / 5xx 退避）：ScanSbom 是幂等的（模型标注 idempotent）
export AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=4

reviewer_lease_and_check
summary_locate_prior

case "${INSPECTOR_INPUT:-}" in
  ok) ;;
  failed:*) reviewer_fail "执行器没能准备 Inspector 的扫描输入（代号 ${INSPECTOR_INPUT#failed:}）" ;;
  *) reviewer_fail "Inspector 的扫描输入状态不合法" ;;
esac
[[ "${INSPECTOR_MAX_SCAN_CALLS:-3}" =~ ^([1-9]|1[0-9]|20)$ ]] || reviewer_fail "INSPECTOR_MAX_SCAN_CALLS 不是 1–20 的整数"

prefix="inspector/${CODEUP_REPO_ID}/${HEAD_SHA}/${SCAN_RUN_ID}"
for side in head base; do
  /usr/local/bin/aws s3api get-object --region "$AWS_REGION" --bucket "$SCAN_BUCKET" --key "${prefix}/${side}.cdx.json" \
    --expected-bucket-owner "$SCAN_BUCKET_OWNER" "$WORK/${side}.cdx.json" >/dev/null 2>"$WORK/s3.err" \
    || reviewer_fail "读取 Inspector 的扫描输入失败（代号 $(aws_err_code "$(cat "$WORK/s3.err")")）"
done

inspector_introduced "$WORK/head.cdx.json" "$WORK/base.cdx.json" > "$WORK/introduced.json" \
  || reviewer_fail "解析扫描输入失败（代号 sbom-parse）"
read -r nchunks dropped < <(inspector_plan_chunks "$WORK/head.cdx.json" "$WORK/introduced.json" \
  "$INSPECTOR_COMPONENTS_PER_CALL" "${INSPECTOR_MAX_SCAN_CALLS:-3}" "$WORK/chunks") \
  || reviewer_fail "生成 ScanSbom 调用计划失败（代号 plan）"
results=()
i=1
while (( i <= nchunks )); do
  /usr/local/bin/aws inspector-scan scan-sbom --region "$AWS_REGION" --sbom "file://$WORK/chunks/chunk-${i}.json" \
    --output-format CYCLONE_DX_1_5 --output json > "$WORK/result-${i}.json" 2>"$WORK/scan.err" \
    || reviewer_fail "Inspector ScanSbom 调用失败（代号 $(aws_err_code "$(cat "$WORK/scan.err")")）"
  results+=("$WORK/result-${i}.json")
  i=$((i + 1))
done
log "ScanSbom ${nchunks} 次（引入 $(jq length "$WORK/introduced.json") 个组件；存量 ${dropped} 个组件超出调用上限未送检）"

if (( nchunks > 0 )); then
  inspector_merge "$WORK/introduced.json" "${results[@]}" > "$WORK/report.json" || reviewer_fail "合并 ScanSbom 结果失败（代号 merge）"
else
  # 一个组件都没有（没有任何可识别的清单文件）：合法的空报告
  jq -n '{vulns: [], counts: {introduced: {critical: 0, high: 0, medium: 0, low: 0, other: 0},
                               existing: {critical: 0, high: 0, medium: 0, low: 0, other: 0}}}' > "$WORK/report.json"
fi
inspector_render_summary "$WORK/report.json" "$(jq '.components | length' "$WORK/head.cdx.json")" \
  "$(jq '.components | length' "$WORK/base.cdx.json")" "$nchunks" "$dropped" > "$WORK/comment.md" \
  || reviewer_fail "Inspector 汇总评论渲染失败"
reviewer_publish "$WORK/comment.md"
