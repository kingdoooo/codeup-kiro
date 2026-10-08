#!/usr/bin/env bash
# 扫描员的输入准备（Phase 2b，spec「Task A」第 3 步、「I8（改写）」「N8」「S1」「S3」）。执行器（entrypoint.sh）用，只有函数定义。
# 读这些全局变量：WORKROOT（业务库在 $WORKROOT/business）、HEAD_SHA、MR_TARGET_BRANCH、CODEUP_REPO_ID、AWS_REGION、
# SCAN_RUN_ID（scan_dispatch 生成）、以及任务定义给的 SCAN_BUCKET、SCAN_BUCKET_OWNER。

# 把一个提交导出成一棵专用副本树（I8：取自 git 对象、不取自工作树——隔离只删工作树，所以 N8 在实质上自动成立）。
# 树内与执行器配置里的 export-ignore / export-subst 一律失效：MR 作者否则能用 export-ignore 把文件藏出扫描输入、用 export-subst
# 改写内容；内容转换类属性同理（working-tree-encoding=UTF-16 能让 sbomgen 读不出清单里的依赖，ident / text / eol / filter 改字节；
# 复审 M-2）。导出物必须与 blob 逐字节相同。手段：$GIT_DIR/info/attributes 的优先级高于树内任何 .gitattributes 与
# core.attributesFile（gitattributes(5)），导出期间在那里写一行把这些属性全部取消，导出完就删掉（不给之后的 Kiro 评审留任何改动）。
# 导出后删掉全部符号链接并核对为零（S1：sbomgen 与 SA 都不该顺着链接读到树外——AWS 自己的 SA 客户端同样跳过符号链接）。
# 导出有时限（SCAN_EXPORT_TIMEOUT，缺省 300 秒；复审 M-4）：clone 是完整 clone，导出只读本地对象、不会因网络挂住，但特别大的
# 仓库会拖慢它，而它在 Kiro 开始之前。管道整个包在 timeout 里（GNU timeout 不带 --foreground 时连同 git 与 tar 一起杀），
# 三个值经环境传给内层 bash（只是路径与提交号）。rc：0 = 成功；124/137 = 超时；1 = 其它失败。
scan_export_tree() {  # <40 位提交> <目标目录> → rc 0 / 124|137 / 1
  local commit="$1" dest="$2" gd="$WORKROOT/business" rc=0 left
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  /bin/mkdir -p "$gd/.git/info" "$dest" || return 1
  printf '* -export-ignore -export-subst -working-tree-encoding -text -eol -ident -filter\n' > "$gd/.git/info/attributes" || return 1
  gd="$gd" commit="$commit" dest="$dest" /usr/bin/timeout -k 10 "${SCAN_EXPORT_TIMEOUT:-300}" /bin/bash -c \
    'set -o pipefail; /usr/bin/git -C "$gd" archive --format=tar "$commit" | /usr/bin/tar -x -C "$dest" --no-same-owner --no-same-permissions' \
    || rc=$?
  /bin/rm -f "$gd/.git/info/attributes"
  case "$rc" in 0) ;; 124|137) return "$rc" ;; *) return 1 ;; esac
  /usr/bin/find "$dest" -type l -exec /bin/rm -f {} + || return 1
  left=$(/usr/bin/find "$dest" -type l | /usr/bin/head -1)
  [[ -z "$left" ]] || return 1
}

# 以非 root、空环境、空 cwd、有界时长跑 sbomgen（S1）：以 root 跑时 /proc/1/environ（entrypoint 的环境，含云效令牌与
# Kiro API Key）对它可读；非 root 让 root 进程的 environ 不可读（内核按属主 0400），是独立于「删符号链接」的第二道。
# HOME 是每次新建、只属于 65534 的 0700 私有目录：sbomgen 要在 $HOME/.inspector-sbomgen 建工作目录（issue 01 实测：不可写的
# HOME 让它必然以 WorkDirInitFailed 失败）。--skip-cloud-metadata：不探测实例元数据（行为不随所在环境变）。
# 成功后把组件路径改写成相对树根、根组件名改成 .：执行器内部路径不进 S3、Inspector 与 MR 评论。
# rc：0 = 写好了 <输出文件>；124/137 = 超时；5 = 时限之前被 KILL（多为内存不足）；3 = 输出超过 SBOM_MAX_BYTES；
# 4 = 输出不是 CycloneDX；其它 = sbomgen 失败。137 有两种来源（复审 M-6）：timeout 到点后 -k 的 KILL，与时限之前别人
# （OOM killer）的 KILL——按已用时间区分，免得内存不足被报成「超过 300 秒」。
scan_sbomgen() {  # <树> <输出文件>
  local tree="$1" out="$2" od cwd home rc=0 size t0 limit="${SBOMGEN_TIMEOUT:-300}"
  od=$(/usr/bin/mktemp -d) && cwd=$(/usr/bin/mktemp -d) && home=$(/usr/bin/mktemp -d) || return 1
  /bin/chmod 0777 "$od" && /bin/chmod 0755 "$cwd" && /bin/chmod 0700 "$home" && /bin/chmod -R a+rX "$tree" || return 1
  if [[ "$(/usr/bin/id -u)" == 0 ]]; then /bin/chown 65534:65534 "$home" || return 1; fi
  t0=$(/bin/date +%s)
  ( cd "$cwd" && /usr/bin/timeout -k 10 "$limit" \
      /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs \
      /usr/bin/env -i PATH=/usr/bin:/bin HOME="$home" \
      /opt/sbomgen/inspector-sbomgen directory --path "$tree" -o "$od/sbom.json" --skip-cloud-metadata ) \
    >/dev/null 2>"$od/err" || rc=$?
  if [[ "$rc" == 137 && "$limit" =~ ^[0-9]+$ ]] && (( $(/bin/date +%s) - t0 < 10#$limit )); then rc=5; fi
  if [[ "$rc" != 0 ]]; then
    # 报错尾巴只进容器日志（不进 MR 评论）：逐行去控制字符、截到 200 字节、加固定前缀（与 git 报错尾巴同一处理）
    /usr/bin/tail -n 3 "$od/err" | LC_ALL=C /usr/bin/tr -d '\000-\010\013-\037\177' \
      | LC_ALL=C /usr/bin/cut -c1-200 | LC_ALL=C /usr/bin/sed 's/^/  sbomgen: /' >&2 || true
    /bin/rm -rf "$od" "$cwd" "$home"; return "$rc"
  fi
  /bin/rm -rf "$home"
  size=$(/usr/bin/wc -c < "$od/sbom.json" 2>/dev/null | /usr/bin/tr -d ' ') || size=""
  if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size > ${SBOM_MAX_BYTES:-52428800} )); then /bin/rm -rf "$od" "$cwd"; return 3; fi
  /usr/bin/jq -e --arg t "$tree" '
      select(.bomFormat == "CycloneDX" and (.components | type) == "array")
      | (.components[].properties[]? | select(.name == "amazon:inspector:sbom_generator:source_path") | .value) |= ltrimstr($t + "/")
      | if (.metadata.component | type) == "object" then .metadata.component.name = "." else . end' \
      "$od/sbom.json" > "$od/rel.json" 2>/dev/null \
    || { /bin/rm -rf "$od" "$cwd"; return 4; }
  /bin/mv "$od/rel.json" "$out" && /bin/rm -rf "$od" "$cwd"
}

# 上传到输入桶（S3：不可变键 <评审员>/<仓库>/<提交>/<run_id>/<名字>，每次调用都带 ExpectedBucketOwner）
scan_put() {  # <评审员> <名字> <本地文件>
  local key="$1/${CODEUP_REPO_ID}/${HEAD_SHA}/${SCAN_RUN_ID}/$2"
  /usr/local/bin/aws s3api put-object --region "$AWS_REGION" --bucket "$SCAN_BUCKET" --key "$key" \
    --body "$3" --expected-bucket-owner "$SCAN_BUCKET_OWNER" >/dev/null 2>&1
}

# Inspector 的输入：head 与 merge-base 两棵树各一份 CycloneDX。输出一行输入状态（scan_prep 的约定）。
# 导出的树每跑完一次 sbomgen 就删，任何返回路径上也都删（只留两份清单）：两份仓库大小的副本不能在 Kiro 评审期间
# 占着同一块临时盘（F2：扫描员的输入准备不改变 Kiro 的执行；复审 I-3）。
scan_prep_inspector() {
  local st
  st=$(_scan_prep_inspector_run)
  /bin/rm -rf "$WORKROOT/scan/inspector/head" "$WORKROOT/scan/inspector/base"
  printf '%s' "$st"
}

_scan_prep_inspector_run() {
  local base dir="$WORKROOT/scan/inspector" side rc commit
  [[ -n "${MR_TARGET_BRANCH:-}" ]] || { printf 'failed:no-target-branch'; return 0; }
  # 目标分支用完整的 refs/remotes/ 名字：短名字会被同名的本地分支或标签遮蔽（entrypoint 检出段那两个坑的同一类）
  base=$(/usr/bin/git -C "$WORKROOT/business" merge-base "refs/remotes/origin/${MR_TARGET_BRANCH}" "$HEAD_SHA" 2>/dev/null) || base=""
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || { printf 'failed:merge-base'; return 0; }
  for side in head base; do
    if [[ "$side" == head ]]; then commit="$HEAD_SHA"; else commit="$base"; fi
    rc=0; scan_export_tree "$commit" "$dir/$side" || rc=$?
    case "$rc" in
      0) ;;
      124|137) printf 'failed:export-timeout'; return 0 ;;
      *) printf 'failed:export'; return 0 ;;
    esac
    rc=0; scan_sbomgen "$dir/$side" "$dir/$side.cdx.json" || rc=$?
    /bin/rm -rf "${dir:?}/$side"
    case "$rc" in
      0) ;;
      124|137) printf 'failed:sbomgen-timeout'; return 0 ;;
      5) printf 'failed:sbomgen-killed'; return 0 ;;
      3) printf 'failed:sbom-too-large'; return 0 ;;
      4) printf 'failed:sbom-not-cyclonedx'; return 0 ;;
      *) printf 'failed:sbomgen'; return 0 ;;
    esac
  done
  scan_put inspector head.cdx.json "$dir/head.cdx.json" && scan_put inspector base.cdx.json "$dir/base.cdx.json" \
    || { printf 'failed:upload'; return 0; }
  printf 'ok'
}

# ── Security Agent 的输入（spec「Task A」SA 一项、「I8」「Z1」「D1」，issue 11）────────────────────────────────
# 四个对象，键 security/<仓库>/<提交>/<run_id>/…（不可变）：
#   changes.patch  merge-base..HEAD_SHA 的 unified diff（钉死参数 = _git_diff_pinned 的参数集 + 显式 -M；`.patch` 结尾是服务硬要求）
#   source.zip     head 树（issue 09 实测：head 归档给出精确的 head 行号）的钉死属性导出 + zip -X（Z1：不写归档注释——带注释的源被 SA 拒绝）
#   files.txt      zip 里的文件清单（一行一个路径，含换行的名字不列、只计数）：Task B 据此标「路径未能对应」的发现
#   meta.json      计数（归档文件数、剔除的符号链接数、diff 文件数与字节数、merge-base）
# 服务上限（run-diff-scan-s3.html / code-review-ide-integration.html）：diff 3,000 个文件或 5 MB、归档 2 GB；超了 → skipped:*，不起作业。
# 空 diff → skipped:empty-diff（issue 09 实测：空 .patch 会被受理，报出与改动无关的发现）。取值可经环境覆盖只为测试。
SCAN_SA_DIFF_MAX_FILES="${SCAN_SA_DIFF_MAX_FILES:-3000}"
SCAN_SA_DIFF_MAX_BYTES="${SCAN_SA_DIFF_MAX_BYTES:-5242880}"
SCAN_SA_ZIP_MAX_BYTES="${SCAN_SA_ZIP_MAX_BYTES:-2147483648}"

# 钉死参数的 diff（_git_diff_pinned，与 Kiro 喂给模型的 diff 同一套参数）+ 显式 -M（不依赖执行器的 diff.renames）。
# 树内 .gitattributes 的 `-diff` / `diff=<驱动>` 是 MR 作者可控的：`*.py -diff` 能让改动只剩一句「Binary files … differ」，
# SA 就在没看到代码的情况下给出「未发现问题」。$GIT_DIR/info/attributes 的优先级高于树内任何 .gitattributes（gitattributes(5)），
# 生成期间在那里写一行 `* !diff`（diff 属性回到「未指定」= 按内容判断是不是二进制），用完即删。真正的二进制文件仍按二进制处理。
# 输出被 head 截在上限 + 1 字节：特别大的 diff 不撑满临时盘；此时 SIGPIPE（141）只在输出确实超过上限时算正常（交给调用方报超限）。
# rc：0 = 成功（names 里是 NUL 分隔的改动路径，patch 是 diff）；1 = 失败。
_scan_sa_diff() {  # <merge-base> <patch 输出> <names 输出>
  local base="$1" patch="$2" names="$3" gd="$WORKROOT/business" rc=0 drc=0
  /bin/mkdir -p "$gd/.git/info" || return 1
  printf '* !diff\n' > "$gd/.git/info/attributes" || return 1
  ( source "$PKG/scripts/lib/diff-compress.sh" && cd "$gd" \
      && _git_diff_pinned -M -z --name-only "$base" "$HEAD_SHA" > "$names" ) || rc=1
  if [[ "$rc" == 0 ]]; then
    ( set -o pipefail; source "$PKG/scripts/lib/diff-compress.sh" && cd "$gd" \
        && _git_diff_pinned -M "$base" "$HEAD_SHA" | /usr/bin/head -c "$((SCAN_SA_DIFF_MAX_BYTES + 1))" > "$patch" ) || drc=$?
    if [[ "$drc" == 141 ]] && (( $(/usr/bin/wc -c < "$patch") > SCAN_SA_DIFF_MAX_BYTES )); then drc=0; fi
    [[ "$drc" == 0 ]] || rc=1
  fi
  /bin/rm -f "$gd/.git/info/attributes"
  return "$rc"
}

# 输出一行输入状态（scan_prep 的约定）。工作目录在任何返回路径上都删掉（F2：不在 Kiro 评审期间占着一份仓库大小的磁盘）。
scan_prep_security() {
  local st
  st=$(_scan_prep_security_run)
  /bin/rm -rf "$WORKROOT/scan/security"
  printf '%s' "$st"
}

_scan_prep_security_run() {
  local base dir="$WORKROOT/scan/security" rc nfiles dbytes zbytes nlinks=0 nlisted=0 nunlisted=0 rec p
  [[ -n "${MR_TARGET_BRANCH:-}" ]] || { printf 'failed:no-target-branch'; return 0; }
  base=$(/usr/bin/git -C "$WORKROOT/business" merge-base "refs/remotes/origin/${MR_TARGET_BRANCH}" "$HEAD_SHA" 2>/dev/null) || base=""
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || { printf 'failed:merge-base'; return 0; }
  /bin/mkdir -p "$dir" || { printf 'failed:prep'; return 0; }
  # 1) diff 先做（便宜）：空或超限就不必导出整棵树
  _scan_sa_diff "$base" "$dir/changes.patch" "$dir/names" || { printf 'failed:diff'; return 0; }
  nfiles=$(LC_ALL=C /usr/bin/tr -cd '\000' < "$dir/names" | /usr/bin/wc -c | /usr/bin/tr -d ' ')
  dbytes=$(/usr/bin/wc -c < "$dir/changes.patch" | /usr/bin/tr -d ' ')
  [[ "$nfiles" =~ ^[0-9]+$ && "$dbytes" =~ ^[0-9]+$ ]] || { printf 'failed:diff'; return 0; }
  (( nfiles > 0 )) || { printf 'skipped:empty-diff'; return 0; }
  (( nfiles <= SCAN_SA_DIFF_MAX_FILES && dbytes <= SCAN_SA_DIFF_MAX_BYTES )) || { printf 'skipped:diff-too-large'; return 0; }
  # 2) head 树：钉死属性的导出（与 Inspector 同一个辅助函数，N8 / I8），符号链接已删
  rc=0; scan_export_tree "$HEAD_SHA" "$dir/tree" || rc=$?
  case "$rc" in
    0) ;;
    124|137) printf 'failed:export-timeout'; return 0 ;;
    *) printf 'failed:export'; return 0 ;;
  esac
  # 被剔除的符号链接数（汇总里写明：「导出物 = 提交树」唯一允许的偏差）
  while IFS= read -r -d '' rec; do
    [[ "${rec%% *}" == 120000 ]] && nlinks=$((nlinks + 1))
  done < <(/usr/bin/git -C "$WORKROOT/business" ls-tree -r -z "$HEAD_SHA" 2>/dev/null)
  # 3) 文件清单（一行一个路径；名字里有换行的不列，只计数）
  : > "$dir/files.txt"
  while IFS= read -r -d '' p; do
    p="${p#./}"
    if [[ "$p" == *$'\n'* ]]; then nunlisted=$((nunlisted + 1)); continue; fi
    printf '%s\n' "$p" >> "$dir/files.txt"; nlisted=$((nlisted + 1))
  done < <(cd "$dir/tree" && /usr/bin/find . -type f -print0)
  # 4) 打包：zip -X（不存额外属性）、不写注释（Z1），有时限。打完核对注释确实为空——这是 SA 能不能跑的前提，不靠「zip 不会写」的推断
  rc=0
  ( cd "$dir/tree" && /usr/bin/timeout -k 10 "${SCAN_ZIP_TIMEOUT:-600}" /usr/bin/zip -q -X -r "$dir/source.zip" . ) >/dev/null 2>&1 || rc=$?
  /bin/rm -rf "${dir:?}/tree"
  case "$rc" in
    0) ;;
    124|137) printf 'failed:zip-timeout'; return 0 ;;
    *) printf 'failed:zip'; return 0 ;;
  esac
  [[ -z "$(/usr/bin/unzip -zq "$dir/source.zip" 2>/dev/null)" ]] || { printf 'failed:zip-comment'; return 0; }
  zbytes=$(/usr/bin/wc -c < "$dir/source.zip" | /usr/bin/tr -d ' ')
  (( zbytes <= SCAN_SA_ZIP_MAX_BYTES )) || { printf 'skipped:archive-too-large'; return 0; }
  /usr/bin/jq -n --argjson files "$nlisted" --argjson unlisted "$nunlisted" --argjson symlinks "$nlinks" \
    --argjson diff_files "$nfiles" --argjson diff_bytes "$dbytes" --arg base "$base" \
    '{files: $files, unlisted: $unlisted, symlinks: $symlinks, diff_files: $diff_files, diff_bytes: $diff_bytes, base: $base}' \
    > "$dir/meta.json" || { printf 'failed:meta'; return 0; }
  scan_put security changes.patch "$dir/changes.patch" && scan_put security meta.json "$dir/meta.json" \
    && scan_put security files.txt "$dir/files.txt" && scan_put security source.zip "$dir/source.zip" \
    || { printf 'failed:upload'; return 0; }
  printf 'ok'
}
