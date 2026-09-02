#!/usr/bin/env bash
# 受信 agent 安装：把集成包内的 agent 定义写入 kiro-cli 的 agent 目录（通常 ~/.kiro/agents/）。
#
# agent 定义里的 prompt 用相对 file:// 引用集成包内的提示词文件。kiro 按「相对 agent 文件所在目录」
# 解析相对 file://（官方文档「File URI path resolution」，kiro-cli 2.21.0 实测一致），所以定义放在
# kiro/ 下时 file://../prompts/x.md 能解析；但直接复制到 ~/.kiro/agents/ 后就会指向不存在的文件。
# 因此安装时把相对 file:// 改写为集成包内的绝对路径；绝对路径原样保留。
# 落盘文件名取定义中的 name（kiro 按 name 字段发现 agent；文件名与 name 一致最不易混淆）。
#
# 用法：kiro_install_agent <agent.json> <目标目录>
#   成功：stdout 打印安装后的文件路径，返回 0
#   失败（定义不可读/非法 JSON/缺 name/缺 prompt/file:// 指向不存在的文件）：stderr 说明原因，返回非零，
#   且不落盘半成品（宁可不跑评审，也不能带错误的 agent 跑）。安装后会清掉目标目录里其它声明同一 name 的文件。
kiro_install_agent() {
  local src="$1" dest_dir="$2"
  local src_dir name prompt dest rel abs stale stale_name
  [[ -r "$src" ]] || { echo "kiro_install_agent: agent 定义不可读：${src}" >&2; return 1; }
  src_dir=$(cd "$(dirname "$src")" && pwd) || return 1
  name=$(jq -r '.name // empty' "$src" 2>/dev/null) \
    || { echo "kiro_install_agent: agent 定义不是合法 JSON：${src}" >&2; return 1; }
  [[ -n "$name" ]] || { echo "kiro_install_agent: agent 定义缺少 name：${src}" >&2; return 1; }
  prompt=$(jq -r '.prompt // empty' "$src")
  # prompt 是只读角色约束所在，缺失就等于让默认系统提示词跑评审——拒绝安装
  [[ -n "$prompt" ]] || { echo "kiro_install_agent: agent 定义缺少 prompt：${src}" >&2; return 1; }
  dest="${dest_dir}/${name}.json"
  if [[ "$prompt" == file:///* ]]; then
    abs="${prompt#file://}"
    [[ -r "$abs" ]] || { echo "kiro_install_agent: prompt 引用的文件不可读：${abs}（来自 ${prompt}）" >&2; return 1; }
    mkdir -p "$dest_dir" || return 1
    cp "$src" "$dest" || return 1
  elif [[ "$prompt" == file://* ]]; then
    rel="${prompt#file://}"
    abs="${src_dir}/${rel}"
    [[ -r "$abs" ]] || { echo "kiro_install_agent: prompt 引用的文件不可读：${abs}（来自 ${prompt}）" >&2; return 1; }
    abs="$(cd "$(dirname "$abs")" && pwd)/$(basename "$abs")"
    mkdir -p "$dest_dir" || return 1
    jq --arg p "file://${abs}" '.prompt = $p' "$src" > "$dest" || { rm -f "$dest"; return 1; }
  else
    mkdir -p "$dest_dir" || return 1
    cp "$src" "$dest" || return 1
  fi
  # 常驻执行器的 agent 目录里可能留着旧版本集成包按别的文件名装的同名 agent（如 agent-codeup-reviewer.json）；
  # kiro 按 name 发现 agent，同名两份会二选一或报错，因此把其它声明同一 name 的文件清掉。
  for stale in "$dest_dir"/*.json; do
    [[ -f "$stale" && "$stale" != "$dest" ]] || continue
    stale_name=$(jq -r '.name // empty' "$stale" 2>/dev/null || true)
    if [[ "$stale_name" == "$name" ]]; then
      rm -f "$stale" || return 1
      echo "kiro_install_agent: 已移除同名旧 agent 文件：${stale}" >&2
    fi
  done
  printf '%s\n' "$dest"
}
