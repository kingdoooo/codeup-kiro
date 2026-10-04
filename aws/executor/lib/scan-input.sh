#!/usr/bin/env bash
# 扫描员的输入准备（Phase 2b，spec「Task A」第 3 步、「I8（改写）」「N8」「S1」「S3」）。执行器（entrypoint.sh）用，只有函数定义。
# 读这些全局变量：WORKROOT（业务库在 $WORKROOT/business）、HEAD_SHA、MR_TARGET_BRANCH、CODEUP_REPO_ID、AWS_REGION、
# SCAN_RUN_ID（scan_dispatch 生成）、以及任务定义给的 SCAN_BUCKET、SCAN_BUCKET_OWNER。

# 把一个提交导出成一棵专用副本树（I8：取自 git 对象、不取自工作树——隔离只删工作树，所以 N8 在实质上自动成立）。
# 树内与执行器配置里的 export-ignore / export-subst 一律失效：MR 作者否则能用 export-ignore 把文件藏出扫描输入、用 export-subst
# 改写内容。手段：$GIT_DIR/info/attributes 的优先级高于树内任何 .gitattributes 与 core.attributesFile（gitattributes(5)），
# 导出期间在那里写一行 `* -export-ignore -export-subst`，导出完就删掉（不给之后的 Kiro 评审留任何改动）。
# 导出后删掉全部符号链接并核对为零（S1：sbomgen 与 SA 都不该顺着链接读到树外——AWS 自己的 SA 客户端同样跳过符号链接）。
scan_export_tree() {  # <40 位提交> <目标目录> → rc 0 / 非 0
  local commit="$1" dest="$2" gd="$WORKROOT/business" rc=0 left
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  /bin/mkdir -p "$gd/.git/info" "$dest" || return 1
  printf '* -export-ignore -export-subst\n' > "$gd/.git/info/attributes" || return 1
  /usr/bin/git -C "$gd" archive --format=tar "$commit" | /usr/bin/tar -x -C "$dest" --no-same-owner --no-same-permissions || rc=1
  /bin/rm -f "$gd/.git/info/attributes"
  [[ "$rc" == 0 ]] || return 1
  /usr/bin/find "$dest" -type l -exec /bin/rm -f {} + || return 1
  left=$(/usr/bin/find "$dest" -type l | /usr/bin/head -1)
  [[ -z "$left" ]] || return 1
}

# 以非 root、空环境、空 cwd、有界时长跑 sbomgen（S1）：以 root 跑时 /proc/1/environ（entrypoint 的环境，含云效令牌与
# Kiro API Key）对它可读；非 root 让 root 进程的 environ 不可读（内核按属主 0400），是独立于「删符号链接」的第二道。
# HOME 是每次新建、只属于 65534 的 0700 私有目录：sbomgen 要在 $HOME/.inspector-sbomgen 建工作目录（issue 01 实测：不可写的
# HOME 让它必然以 WorkDirInitFailed 失败）。--skip-cloud-metadata：不探测实例元数据（行为不随所在环境变）。
# 成功后把组件路径改写成相对树根、根组件名改成 .：执行器内部路径不进 S3、Inspector 与 MR 评论。
# rc：0 = 写好了 <输出文件>；124 = 超时；3 = 输出超过 SBOM_MAX_BYTES；4 = 输出不是 CycloneDX；其它 = sbomgen 失败。
scan_sbomgen() {  # <树> <输出文件>
  local tree="$1" out="$2" od cwd home rc=0 size
  od=$(/usr/bin/mktemp -d) && cwd=$(/usr/bin/mktemp -d) && home=$(/usr/bin/mktemp -d) || return 1
  /bin/chmod 0777 "$od" && /bin/chmod 0755 "$cwd" && /bin/chmod 0700 "$home" && /bin/chmod -R a+rX "$tree" || return 1
  if [[ "$(/usr/bin/id -u)" == 0 ]]; then /bin/chown 65534:65534 "$home" || return 1; fi
  ( cd "$cwd" && /usr/bin/timeout -k 10 "${SBOMGEN_TIMEOUT:-300}" \
      /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups --no-new-privs \
      /usr/bin/env -i PATH=/usr/bin:/bin HOME="$home" \
      /opt/sbomgen/inspector-sbomgen directory --path "$tree" -o "$od/sbom.json" --skip-cloud-metadata ) \
    >/dev/null 2>"$od/err" || rc=$?
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
  local base dir="$WORKROOT/scan/inspector" side rc
  [[ -n "${MR_TARGET_BRANCH:-}" ]] || { printf 'failed:no-target-branch'; return 0; }
  # 目标分支用完整的 refs/remotes/ 名字：短名字会被同名的本地分支或标签遮蔽（entrypoint 检出段那两个坑的同一类）
  base=$(/usr/bin/git -C "$WORKROOT/business" merge-base "refs/remotes/origin/${MR_TARGET_BRANCH}" "$HEAD_SHA" 2>/dev/null) || base=""
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || { printf 'failed:merge-base'; return 0; }
  for side in head base; do
    if [[ "$side" == head ]]; then scan_export_tree "$HEAD_SHA" "$dir/$side" || { printf 'failed:export'; return 0; }
    else scan_export_tree "$base" "$dir/$side" || { printf 'failed:export'; return 0; }; fi
    rc=0; scan_sbomgen "$dir/$side" "$dir/$side.cdx.json" || rc=$?
    /bin/rm -rf "${dir:?}/$side"
    case "$rc" in
      0) ;;
      124|137) printf 'failed:sbomgen-timeout'; return 0 ;;
      3) printf 'failed:sbom-too-large'; return 0 ;;
      4) printf 'failed:sbom-not-cyclonedx'; return 0 ;;
      *) printf 'failed:sbomgen'; return 0 ;;
    esac
  done
  scan_put inspector head.cdx.json "$dir/head.cdx.json" && scan_put inspector base.cdx.json "$dir/base.cdx.json" \
    || { printf 'failed:upload'; return 0; }
  printf 'ok'
}
