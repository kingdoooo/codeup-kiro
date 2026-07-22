# Codeup + Kiro 自动评审 配置指南

## 1. 前提条件与数据治理确认
- Kiro 订阅：Pro / Pro+ / Pro Max / Power；组织订阅需管理员开启 API Key 生成权限。
- 生成 Kiro API Key：kiro.dev → 账户设置 → API Keys（参考 headless 文档）。
- 云效令牌：**建议创建专用机器人账号**，仅授予目标代码库「代码只读 + 合并请求读写」，
  设置轮换周期（如 90 天）。个人令牌可用于 PoC，生产不推荐。
- 组织 ID：云效「组织管理后台 → 基本信息」；代码库数字 ID：库设置 → 基本信息。
- 【数据治理，实施前必须确认】MR diff 与仓库上下文会发送至 Kiro 服务端（境外）：
  ① 客户确认允许相关代码库内容出境评审；
  ② 客户知悉 Kiro 数据保留与模型使用策略（指引至 Kiro 官方条款）；
  ③ 涉密/受监管仓库不得接入本方案。
- 【残余风险披露】被评审代码中的文本可能试图误导 AI 评审结论（提示词注入）。
  本方案中 Kiro 仅有只读权限，最坏影响是评审意见失真；评论仅供参考、不设合并卡点，
  最终合并决策始终在人工评审。

## 2. 部署集成包（信任边界）
**必须**将本集成包放入独立代码库（如 codeup-kiro），流水线以第二代码源引入固定分支/tag。
**严禁**把 scripts/ 拷贝进业务代码库执行——MR 源分支可被提交者任意修改，
执行业务仓库中的脚本等于把流水线密钥交给任意 MR 提交者。

## 3. 创建流水线
1. Flow 控制台 → 新建流水线 → 空模板。
2. 添加两个代码源：业务代码库 + 集成包代码库（固定分支）。
3. 添加任务：「执行命令」步骤，命令见 flow-pipeline.yaml（先 export REVIEW_REPO_DIR，
   再执行集成包中的 kiro-review.sh）。
4. 变量和缓存：按 YAML 尾部注释配置变量（KIRO_API_KEY、YUNXIAO_TOKEN 勾选私密）。
5. 【YAML 校验】若用 YAML 模式：粘贴 flow-pipeline.yaml 并确认编辑器校验通过，
   替换两个 endpoint 占位符。

## 4. 开启 MR 触发
1. 编辑流水线 → 编辑【业务代码库】代码源 → 开启「代码源触发」。
2. 触发事件勾选：「合并请求新建/更新」（YAML 对应 triggerEvents: mergeRequestOpenedOrUpdate）。
   不要勾「代码提交」，避免每次 push 双触发。
3. 集成包代码源不开启任何触发。
4. 可选：目标分支过滤（如 `master|release/.*`）。
5. 保存后到 Codeup 业务库 → 设置 → Webhooks 确认 Flow 已注册 webhook；
   若无 → 第 10 节排查。

## 5. 首次运行：环境探测（不打印任何变量值）
1. 临时在命令最前加一行（只输出变量名，严禁 `env` 直接输出——
   值含私密变量且流水线日志长期保存）：
       env | cut -d= -f1 | sort
2. 提交测试 MR 触发流水线，在日志中找 MR / merge / change 相关变量名。
3. 同时确认两个代码源的实际 checkout 目录名（日志工作目录结构），
   校正 REVIEW_REPO_DIR 的 export 路径。
4. 若存在 MR 编号/目标分支变量：在「变量和缓存」把它们映射为
   MR_LOCAL_ID / MR_TARGET_BRANCH（值填 `${实际变量名}`），可免 OpenAPI 反查。
5. 若不存在：无需配置，脚本自动按源分支反查；注意——同一源分支同时存在
   多个打开的 MR 时脚本会明确报错，需显式配置 MR_LOCAL_ID 与 MR_TARGET_BRANCH
   （两者必须同时设置，只设其一时脚本仍走反查路径）。
6. 确认后删除探测行。

## 6. 连通性验证（云托管构建机必做）
前提：先在该验证流水线的「变量和缓存」中配置 `KIRO_API_KEY`（私密变量）——
headless 调用必须依赖它认证，未配置时 chat 命令会因认证失败而报错。
最小验证流水线命令：
    curl -fsSL https://cli.kiro.dev/install | bash
    export PATH="$HOME/.local/bin:$PATH"
    KIRO_LOG_NO_COLOR=1 kiro-cli chat --no-interactive "回复 ok 两个字母即可"
成功输出 ok → 可用。失败时先区分两类：
- `curl | bash` 安装失败 → 网络不通 → 第 7 节自建构建机；
- 安装成功但 chat 失败 → 多为认证问题（KIRO_API_KEY 未配置/无效/订阅无 API Key 权限），
  与网络无关，回到第 1 节核对 Key。
同时验证构建机具备 timeout 命令（GNU coreutils）：`command -v timeout`。

## 7. 自建构建机（网络受限/生产推荐）
1. ECS/物理机按 Flow 文档接入为自有构建集群。
2. 预装：git、curl、jq（≥1.6）、coreutils(timeout)、kiro-cli 固定版本
   （`kiro-cli --version` 验证；固定版本可规避 curl|bash 供应链漂移）。
3. 代理：流水线变量配置 HTTP_PROXY / HTTPS_PROXY / NO_PROXY
   （NO_PROXY 含 openapi-rdc.aliyuncs.com 与内网地址）。
4. 流水线任务指定运行在该构建集群。

## 8. 首次联调核对清单
对以下在本地无法验证、依赖真实 kiro-cli 行为的点，首次联调时逐项确认：
1. custom agent 是否生效：查看流水线日志——出现「使用受信 custom agent：codeup-reviewer」
   说明 `kiro-cli chat --help` 列出了 `--agent` 且已启用；出现
   「警告：kiro-cli chat 不支持 --agent」则说明降级为 .kiro 移除 + --trust-tools
   两层缓解（可接受，但需知悉差异，见设计文档 §4）。
2. agent 名称解析：本包安装的文件名为 `agent-codeup-reviewer.json`，agent 名为
   `codeup-reviewer`。若真实 CLI 按文件名解析导致 `--agent codeup-reviewer` 报错
   （表现为 die_review「评审未完成」且日志含 agent 相关错误），
   将文件重命名为 `codeup-reviewer.json` 后重试。
3. `--trust-tools=read,grep` 等号语法是否被真实 CLI 接受（报错会在流水线日志明确显示）。
4. Kiro 的 read 工具能否读取工作区外的绝对路径（/tmp 下的 diff chunk 文件）——
   提交一个 >300KB 的大 MR，确认评审报告覆盖了省略清单中的文件。
5. 安装源核对：确认 `https://cli.kiro.dev/install` 与 kiro.dev 官方文档一致；
   生产环境建议自建构建机预装固定版本（见第 7 节）。
6. 模型是否生效：agent 配置指定了 `"model": "gpt-5.6-sol"`（GPT-5.6 Sol，
   Kiro 官方已上线，实验性支持，credit 倍率 2.4x）。两点核对：
   ① 确切模型 ID 以交互式会话 `/model` 列表为准——若 ID 不匹配或组织
   管理员的模型访问策略未放行，Kiro 会**静默回退默认模型并打警告**，
   不会报错中断，因此需检查流水线日志中无模型 fallback 警告；
   ② 模型配置依赖 `--agent` 生效（见第 1 项），若 CLI 降级则模型字段
   随之失效，评审将使用账号默认模型。
7. stdin 内容是否真正到达 Kiro：脚本以「提示词作参数 + diff 走 stdin」方式调用
   （`kiro-cli chat "<prompt>" < input.txt`）。若真实 CLI 在有参数时忽略 stdin，
   评审会在没有 diff 的情况下静默运行且不报错。核对方法：确认评审报告明确引用了
   本次 MR 的源/目标分支与 diff 中的具体改动（元信息与 diff 均来自 stdin）；
   若报告内容与本次变更无关或过于泛化，即为 stdin 未生效，需改造调用方式
   （如将 diff 并入提示词参数）并反馈集成包维护者。

## 9. 端到端验收
1. 在业务测试库提交含**合成假密钥**的 MR（如 `SECRET_KEY = "FAKE-TEST-KEY-0000"`，
   严禁用真实凭证做验收）。
2. 确认 MR 页面出现 Kiro 中文评审评论，密钥以掩码呈现（非完整值）。
3. 重跑流水线：确认追加第二条评论且 `<!-- kiro-review:<sha> -->` 标记正确
   （append-only 语义，重复评论仅在人工重跑时出现）。
4. 提交一个改动很大的 MR（>300KB diff）验证截断说明与评审仍覆盖省略文件。

## 10. 故障排查
| 现象 | 排查 |
|---|---|
| MR 提交后流水线未触发 | Codeup 库 Webhooks 页无 Flow 条目 → 服务连接无自动配置权限，手动配置；确认触发事件勾选「合并请求新建/更新」；YAML 模式确认 triggerEvents 已配置 |
| 报错「缺少依赖：timeout」 | 构建机安装 GNU coreutils（超时是强制依赖，防 Kiro 挂起占死流水线） |
| kiro-cli 安装失败 | 网络不通 → 第 6/7 节 |
| 报错「缺少 KIRO_API_KEY」等 | 流水线变量未配置或拼写错误 |
| 报错「MR 定位歧义」 | 同源分支多个打开 MR → 显式配置 MR_LOCAL_ID 与 MR_TARGET_BRANCH（需同时设置） |
| 报错「无法定位 MR」 | MR 已关闭/合并；或第 5 节显式配置 |
| OpenAPI 401/403 | 令牌过期/权限不足（代码只读+MR 读写）；YUNXIAO_ORG_ID 是否正确；注意 4xx 不重试直接失败 |
| 评论被截断 | 属预期（65535 上限）；完整报告在流水线日志；可调 MAX_COMMENT_BYTES |
| 评审内容为英文 | 检查 prompts/review-prompt.md 是否被改动 |
