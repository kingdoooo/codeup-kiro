# 设计：Codeup MR 自动触发 Kiro CLI 代码评审

- 日期：2026-07-21（v3 联调修订：2026-07-23）
- 状态：已在客户中心站环境端到端联调通过（v3：补充真实环境实测发现与修复，见第 12 节）
- v2 修订：吸收外部对抗性评审——信任边界重构、OpenAPI 契约修正、diff chunk 索引方案、超时/评论长度/失败路径加固
- 术语说明：本文中 **MR（Merge Request，合并请求）** 即 Codeup 平台上的代码合并评审流程，等同于 GitHub 的 PR（Pull Request）。

## 1. 背景与目标

客户使用阿里云云效 Codeup（**中心站模式**，非 Region 站）管理代码。目标：开发者提交/更新 MR 时，自动触发 Kiro CLI Headless 模式完成代码评审，并将评审结果以 **Markdown 全局评论** 回写到 MR 页面。

参考：

- Kiro headless 文档：https://kiro.dev/docs/cli/headless/
- Kiro custom agent 配置：https://kiro.dev/docs/cli/custom-agents/configuration-reference
- GitHub Actions 集成范例：https://builder.aws.com/content/35cLFnKM6DJMgRzdZQ7XPZkJmoz/automate-reviews-in-github-actions-with-kiro-headless-mode

### 成功标准

在客户组织的测试仓库提交一个带明显问题的 MR，MR 页面自动出现 Kiro 的中文评审评论。验收用的"硬编码密钥"必须是**明确无效的合成假密钥**（如 `SECRET_KEY = "FAKE-TEST-KEY-0000"`），严禁使用真实凭证。

### 需求决策（已与用户确认）

| 决策点 | 结论 |
|---|---|
| 结果呈现 | MR 全局评论（GLOBAL_COMMENT），不做行内评论 |
| 合并卡点 | 不设卡点；评审失败流水线标红提醒，不阻塞合并 |
| 构建环境 | 云托管与自建构建机两者兼顾，文档提供两套配置 |
| Kiro 订阅 | 客户已有 Pro 及以上订阅和 API Key 生成权限 |
| 交付物 | 可复用集成包（脚本 + 流水线配置 + 部署文档），存于本仓库 |
| diff 直传阈值 | 300KB，可通过环境变量调整 |
| 信任边界 | 集成脚本/提示词/agent 配置**只从受信来源（本集成包仓库的固定版本）执行**，绝不执行待评审源分支中的脚本 |
| 回写语义 | append-only / at-least-once（每次运行追加一条新评论，含 `<!-- kiro-review:<sha> -->` 标记）；**不承诺幂等** |

## 2. 关键事实（调研已验证）

### Codeup / Flow（中心站）

- Flow 流水线支持「代码源触发」，Codeup 代码源支持 **「合并请求新建/更新」** 事件。触发后 Flow 使用 **源分支** 作为运行分支。
- Flow YAML 中该触发事件可显式声明：`triggerEvents: [mergeRequestOpenedOrUpdate]`（见 https://help.aliyun.com/zh/yunxiao/user-guide/pipeline-sources ）。**未配置 triggerEvents 时流水线默认不能由代码源事件触发。**
- 开启代码源触发后，Flow 自动将 webhook 注册到 Codeup 仓库。若服务连接无自动配置权限，需手动在 Codeup 仓库设置中配置（常见触发失败原因）。
- 中心站 OpenAPI 接入点：`https://openapi-rdc.aliyuncs.com`，认证用个人访问令牌（请求头 `x-yunxiao-token`），中心站路径必须带 `organizationId`。
- **ListChangeRequests**（`GET /oapi/v1/codeup/organizations/{orgId}/changeRequests`）：支持 `projectIds`（代码库 ID，逗号分隔）、`state`（opened/merged/closed）、`orderBy`（created_at/updated_at）、`sort`（asc/desc）、`page`/`perPage`。返回字段为 **`updatedAt`/`createdAt`**（注意：与 MergeChangeRequest 等旧接口的 `updateTime` 命名不同）。
- **CreateChangeRequestComment**（`POST .../changeRequests/{localId}/comments`）：`comment_type=GLOBAL_COMMENT`，`content` 长度限制 **1–65535**；响应体字段为 snake_case 的 **`comment_biz_id`**（响应可能为数组形态）。成功判定以 HTTP 状态码为准，不依赖响应体结构。
- Flow 内置环境变量：`CI_COMMIT_REF_NAME`（运行分支，MR 触发时为源分支）、`CI_COMMIT_SHA`、`PIPELINE_ID`、`BUILD_NUMBER`、`PROJECT_DIR` 等。Git 相关变量要求流水线包含「获取代码」步骤。

### Kiro CLI Headless

- 认证：环境变量 `KIRO_API_KEY`（仅 Pro / Pro+ / Pro Max / Power 订阅可生成；组织订阅需管理员开启 API Key 生成权限）。
- 调用：`kiro-cli chat --no-interactive "<prompt>"`，支持管道输入。
- 权限控制：`--trust-tools=read,grep` 只授予只读工具；绝不授予 write/shell。
- Custom agent 配置支持 `includeMcpJson` 字段：设为 `false` 时不加载 `~/.kiro/settings/mcp.json` 与 `<cwd>/.kiro/settings/mcp.json` 中的 MCP server —— 这是隔离工作区级恶意 MCP 配置的关键开关。Agent 可安装在全局目录 `~/.kiro/agents/`（不受工作区内容影响）。
- CI 环境设置 `KIRO_LOG_NO_COLOR=1`，避免终端颜色码污染评论内容。

### 待实施时验证的点

1. **MR 编号（localId）的流水线环境变量名**：Flow 文档未明确。实施时首次运行用 `env | cut -d= -f1 | sort` 输出**变量名清单**（严禁输出值——env 值含私密变量，流水线日志长期保存）确认；取不到则按第 5 节 OpenAPI 反查兜底。
2. **`kiro-cli chat` 是否支持 `--agent <name>` 旗标**（headless 限制页只说明 `/agent` 斜杠命令不可用）：实施时用 `kiro-cli chat --help` 验证；若不支持，降级方案见第 4 节。
3. **Flow YAML 的 `step: Checkout` 步骤标识**：交付 YAML 需在 Flow 编辑器中实际粘贴校验通过（列入验收步骤）。

## 3. 整体架构

```
开发者提交/更新 MR (Codeup)
        │  webhook（Flow 自动注册，事件：合并请求新建/更新）
        ▼
云效 Flow 流水线
  ├─ 代码源 1：业务代码库（触发源，checkout 源分支 → 仅作为【被分析的数据】）
  └─ 代码源 2：本集成包仓库（固定分支/tag，受信 → 提供可执行脚本）
        │
        ▼
Shell 任务步骤（执行【受信集成包】中的 kiro-review.sh，绝不执行业务仓库中的脚本）
  1. 检测依赖（git/curl/jq/timeout）+ 安装/检测 kiro-cli
  2. 移除业务仓库 checkout 中的 .kiro/ 目录（消除工作区级 MCP/hooks/steering 注入面）
     + 安装受信只读 custom agent 到 ~/.kiro/agents/（includeMcpJson: false）
  3. 定位本次 MR（localId）+ 生成 diff（merge-base 三点比较）
  4. 超阈值时按文件拆 chunk 落盘并建立索引
  5. kiro-cli chat --no-interactive --trust-tools=read,grep（强制 timeout）
  6. 调 Codeup OpenAPI（中心站）以 GLOBAL_COMMENT 回写 Markdown 评审报告
```

### 方案选型

| 方案 | 说明 | 结论 |
|---|---|---|
| A. Flow + Shell 脚本 | MR 触发流水线，Shell 步骤跑受信仓库中的版本化脚本 | **采用**：交付快、维护简单、脚本可版本化 |
| B. Flow 自定义步骤（flow-cli 发布） | 封装为组织级步骤，界面化配置 | 放弃：开发/发布成本高，适合后期规模化推广 |
| C. Webhook + 自建服务 | 自建常驻评审服务接收 webhook | 放弃：运维负担最重 |

## 4. 信任边界与威胁模型

**核心原则：MR 源分支的全部内容（代码、脚本、配置、文档）都是不受信数据。** 流水线持有 `KIRO_API_KEY` 与 `YUNXIAO_TOKEN`，任何"执行源分支代码"的路径都等于把密钥交给任意 MR 提交者。

| 威胁 | 缓解措施 |
|---|---|
| MR 修改集成脚本窃取密钥 | 脚本/提示词/agent 配置只从集成包仓库（流水线第二代码源，固定分支/tag）执行；业务仓库 checkout 仅作数据。指南明确禁止把脚本拷入业务仓库执行 |
| 工作区 `.kiro/settings/mcp.json` 注入恶意 MCP server（可启动任意命令） | 运行 Kiro 前 `rm -rf <业务仓库>/.kiro`；custom agent 设 `includeMcpJson: false` 双保险 |
| 工作区 hooks/steering/agents 注入 | 同上（`.kiro/` 整体移除）；agent 安装于全局 `~/.kiro/agents/`，`resources: []` 不继承工作区资源 |
| Kiro 工具越权 | agent `tools`/`allowedTools` 仅 `read,grep`；CLI 侧再加 `--trust-tools=read,grep` |
| 源码/README 中的提示词注入误导评审结论 | **残余风险，明确接受**：Kiro 只有只读工具，注入最坏结果是评审结论失真；评论仅供人工参考、不设卡点，最终合并决策在人。指南中向客户披露 |
| diff 中出现真实密钥被评论原样复述 | 提示词明确禁止完整复述疑似密钥，只允许掩码展示（前 4 后 4）并报告为严重问题 |
| curl\|bash 安装脚本供应链 | `KIRO_INSTALL_URL` 可固定；生产环境建议自建构建机预装固定版本（指南说明）。完整 checksum 校验体系列为生产化改进项，不进 v1 |
| 令牌权限过大 | `YUNXIAO_TOKEN` 建议使用专用机器人账号，权限最小化（代码只读 + MR 读写），定期轮换（指南说明） |

**数据治理前置条件**（写入指南第 1 节）：MR diff 与仓库上下文会发送至 Kiro 服务端（境外）。实施前需客户确认：① 允许相关代码库内容出境评审；② 知悉 Kiro 的数据保留与模型使用策略；③ 涉密仓库不接入本方案。

**Custom agent 降级方案**：若实施时验证 `kiro-cli chat` 不支持 `--agent` 旗标，则依赖「`.kiro/` 移除 + `--trust-tools=read,grep`」两层缓解，并在指南中注明差异。

## 5. 交付物结构（本仓库）

```
codeup-kiro/
├── README.md                  # 快速开始 + 架构 + 安全模型说明
├── scripts/
│   ├── kiro-review.sh         # 主脚本：依赖检测 → 隔离 → 评审 → 回写（append-only）
│   └── lib/
│       ├── codeup-api.sh      # OpenAPI 封装：查 MR、发评论（HTTP 状态码判定成败）
│       └── diff-compress.sh   # diff 压缩：文件级优先级 + chunk 索引
├── prompts/
│   └── review-prompt.md       # 评审提示词模板（中文、分级、密钥掩码、chunk 读取指引）
├── kiro/
│   └── agent-codeup-reviewer.json  # 受信只读 custom agent（includeMcpJson: false）
├── pipeline/
│   ├── flow-pipeline.yaml     # Flow YAML（双代码源 + triggerEvents）
│   └── setup-guide.md         # 配置指南（前提/导入/触发/探测/连通性/自建机/排查）
└── docs/superpowers/          # 设计文档与实施计划
```

### 流水线变量（Flow「变量和缓存」中配置，私密模式）

| 变量 | 说明 |
|---|---|
| `KIRO_API_KEY` | Kiro API Key（私密） |
| `YUNXIAO_TOKEN` | 云效令牌，建议专用机器人账号（代码只读 + MR 读写）（私密） |
| `YUNXIAO_ORG_ID` | 云效组织 ID（中心站必需） |
| `CODEUP_REPO_ID` | Codeup 代码库数字 ID |
| `REVIEW_REPO_DIR` | 业务仓库 checkout 目录（多代码源场景必填） |
| `DIFF_SIZE_LIMIT` | diff 直传阈值，默认 `307200`（300KB），可调 |
| `KIRO_TIMEOUT` | Kiro 评审超时秒数，默认 `900`（15 分钟），可调 |
| `MAX_COMMENT_BYTES` | 评论截断阈值，默认 `60000`（Codeup 上限 65535 字符），可调 |

## 6. 核心流程（kiro-review.sh）

1. **依赖检测**：git / curl / jq / **timeout（或 gtimeout）**缺一即报错退出——超时能力是强制依赖，不允许静默降级为无超时。
2. **安装/检测 kiro-cli**：已存在则跳过（自建机预装场景）；否则按 `KIRO_INSTALL_URL` curl 安装（云托管场景）。
3. **工作区隔离**：删除业务仓库 checkout 中的 `.kiro/` 目录；将集成包内 `kiro/agent-codeup-reviewer.json` 安装到 `~/.kiro/agents/`。
4. **定位 MR**：优先环境变量 `MR_LOCAL_ID`/`MR_TARGET_BRANCH`；否则 OpenAPI 按源分支反查（`state=opened&orderBy=updated_at&sort=desc&projectIds=<repo>`）。**同源分支存在多个 opened MR 时报错退出、要求显式配置 MR_LOCAL_ID，不静默取最新**。
5. **生成 diff**：`git fetch` 目标分支 → merge-base 三点比较（浅克隆自动 `--unshallow`）。空 diff 直接成功退出。
6. **组装评审输入**（超限走第 7 节压缩）。
7. **执行评审**：`timeout $KIRO_TIMEOUT kiro-cli chat --no-interactive --trust-tools=read,grep [--agent codeup-reviewer]`，工作目录为业务仓库（Kiro 可用 read/grep 查阅完整源码上下文）。**输出为空视为失败**。
8. **回写评论**：Markdown 头部含元信息（commit SHA、分支、时间、截断说明）与 `<!-- kiro-review:<sha> -->` 标记；超 `MAX_COMMENT_BYTES` 时按字节截断并注明。HTTP 2xx 即成功；仅对网络错误/429/5xx 重试（至多 2 次），4xx 不重试（避免非幂等 POST 重复发评论）。
9. **失败处理**：定位到 MR 之后的**任何**失败路径（fetch 失败、压缩失败、Kiro 失败/超时/空输出、回写失败）统一走 best-effort「评审未完成」评论 + 非零退出。定位 MR 之前的失败只写日志。不设合并卡点。

## 7. diff 压缩策略（大 MR 处理）

参考 PR-Agent（Qodo）的 Compression Strategy（https://docs.pr-agent.ai/core-abilities/compression_strategy/ ），结合 Kiro agentic 能力调整：

- **阈值内**（diff ≤ `DIFF_SIZE_LIMIT`，默认 300KB）：整个 diff 进提示词。
- **超阈值**：
  1. 用 `git diff --name-only -z` 逐文件生成独立 diff chunk 文件落盘（NUL 分隔，路径含空格安全）；
  2. **文件级**优先级排序：代码(0) > 配置(1) > 文档(2)；整文件删除(3) 永不直传（注：v1 为文件级分类，不做 hunk 级拆分）；
  3. 按预算逐文件装填直传；
  4. **未直传的文件不丢弃**：省略清单每项为「路径 (+增/-删行数) → 该文件完整 diff 的 chunk 文件路径」，提示词明确指示 Kiro 用 read 工具读取这些 **diff chunk 文件**（而非仓库当前文件——当前文件无法体现改动内容，删除文件更是已不存在）；
  5. 评论头部注明「diff 超出直传阈值已按优先级截断，其余变更 Kiro 通过 diff 索引自主读取」。

## 8. 错误处理汇总

| 场景 | 处理 |
|---|---|
| 依赖缺失（含 timeout） | 启动即报错退出，日志给出安装指引 |
| kiro-cli 安装失败/网络不通 | 快速失败，日志给出代理（`HTTP_PROXY`/`HTTPS_PROXY`）与自建机预装指引 |
| MR 定位失败（无匹配/歧义） | 报错退出并给出明确指引（歧义时列出候选，要求配置 MR_LOCAL_ID） |
| diff 超 300KB | 第 7 节压缩策略 |
| OpenAPI 调用 | `--connect-timeout 10 --max-time 60`；仅网络错误/429/5xx 重试（退避），4xx 立即失败 |
| Kiro 超时/失败/空输出 | 回写「评审未完成」评论，非零退出 |
| 评论超长 | 60000 字节截断 + 末尾注明 |
| 定位 MR 后的任何失败 | best-effort 回写失败说明评论 |
| 密钥安全 | 全走 Flow 私密变量；脚本不落盘、不 echo、不开 `set -x`；日志只打印变量名不打印值 |

## 9. 两种构建环境

| | 云托管构建机 | 自建构建机 |
|---|---|---|
| kiro-cli | 脚本内联 curl 安装（`KIRO_INSTALL_URL` 可固定版本） | 预装固定版本（生产推荐） |
| 境外网络 | 需先验证：setup-guide 提供最小连通性验证流水线 | 可控：支持配置 HTTP 代理 |
| 适用 | 网络通畅时最省事 | 网络受限或需固化环境/供应链时 |

## 10. 测试与验证

- **脚本单测/冒烟**：`DRY_RUN=1` + mock kiro-cli（含参数记录、失败模拟、**挂起模拟**验证超时强杀），本地 bare git 仓库模拟完整流程，全程无网络。
- **契约测试**：Codeup API fixture 采用官方文档响应形态（`updatedAt`、数组 + `comment_biz_id`）。
- **连通性验证**：最小流水线确认构建机可安装 kiro-cli 并完成一次 headless 调用。
- **YAML 校验**：flow-pipeline.yaml 粘贴进 Flow 编辑器校验通过（验收步骤）。
- **端到端验收**：客户组织建测试仓库 → 按 setup-guide 配置（集成包为独立受信代码源）→ 提交含**合成假密钥**的 MR → 确认 MR 页面出现 Kiro 中文评审评论（含掩码而非完整"密钥"）；重跑流水线确认追加新评论且标记 SHA 正确。

## 11. 范围外（YAGNI）

- 行内评论（INLINE_COMMENT）与精准行号定位
- 合并卡点 / Commit Status / Check Runs 回写
- Flow 自定义步骤封装（方案 B）
- 评论查重-更新（幂等化）——当前为 append-only；重复评论仅在人工重跑时出现，可接受
- Kiro 输出的自动敏感信息扫描/清洗（生产化改进项）
- kiro-cli 安装包 checksum 校验体系（生产化改进项，以自建机预装替代）
- hunk 级删除内容分类（v1 为文件级）

## 12. 联调实测发现与修复（2026-07-23，中心站真实环境）

在客户中心站环境完成端到端联调（Flow 双代码源流水线 + demo-app 业务库 + 植入 4 处安全问题的测试 MR），发现并修复了 3 个本地测试无法覆盖的真实环境问题。三者均属"接口/环境细节"，验证了"必须在真实环境联调"这一判断。

### 12.1 多代码源下源分支变量被污染（配置层，非代码 bug）

- 现象：脚本用无下标的 `CI_COMMIT_REF_NAME` 猜源分支，多代码源场景下它取到的是 `main`（集成包源分支），而非业务库 MR 的源分支 `feature/user-search`，导致 OpenAPI 反查不到 MR。
- 根因：Flow 多代码源时，无下标内置变量的取值不可预期（文档已警示），必须用带下标变量。实测 MR 触发时可用：`CI_COMMIT_REF_NAME_1`=业务库源分支、`CI_COMMIT_TARGET_REF_NAME_1`=MR 目标分支。
- 修复：流水线「执行命令」步骤显式修正——`export CI_COMMIT_REF_NAME="$CI_COMMIT_REF_NAME_1"` 与 `export MR_TARGET_BRANCH="$CI_COMMIT_TARGET_REF_NAME_1"`，再调脚本。已写入 setup-guide 与本文档的流水线示例。
- 教训：setup-guide §5「首次运行环境探测（只打变量名）」正是为此设计——不同组织/多源顺序下变量名需实测确认。

### 12.2 回写评论接口 `resolved` 字段必填（OpenAPI 契约）

- 现象：Kiro 评审成功，但回写报 `HTTP 400 "resolved can not be null"`。
- 根因：中心站 CreateChangeRequestComment 接口 `resolved` 字段实际必填，官方文档示例将其标为可选，与实测不符。
- 修复：`codeup-api.sh` 请求体补 `resolved: false`，并加测试断言锁定（commit f7c9de1）。

### 12.3 kiro-cli headless 输出混入工具轨迹与 ANSI 色码（输出清洗）

- 现象：回写的 MR 评论正文前段混入 kiro-cli 的工具调用轨迹（`Reading directory...`、`using tool: read`）与 ANSI 颜色控制序列，真报告被往下挤。
- 根因：headless 模式下 kiro-cli 把执行轨迹和最终报告一并打到 stdout；`KIRO_LOG_NO_COLOR=1` 未能完全抑制色码；且报告标题被加了 Markdown 引用前缀 `> `。
- 修复（commit 81645cd、fe937b9）：脚本在捕获输出后 ① `sed` 剥离 ANSI 控制序列；② 以 `# 代码评审报告` 为锚点（正则兼容 `> `/`#`/空白前缀）截取正文并去掉引用前缀；找不到锚点则降级保留全文并告警。提示词固定报告首行为该标题；mock 与测试覆盖清洗逻辑。
- 残留改进项：该清洗依赖 kiro-cli 的输出格式，属"生产化改进项"级别的脆弱点；kiro-cli 若提供 headless 纯结果输出旗标（类似 `--output-format`），应优先改用。

### 12.4 评论身份（Kiro Bot）

- 现状：评论经 `YUNXIAO_TOKEN` 所属账号发出，作者名/头像即令牌账号；正文以 `## 🤖 Kiro 自动代码评审` 打品牌。
- 建议：生产用**专用机器人成员账号**（名如 `Kiro Review Bot`、头像上传 Kiro icon、仅授予目标库 MR 读写），令牌作为 `YUNXIAO_TOKEN` —— 视觉上即"Kiro 在评论"。Codeup 无第三方 App/Bot 平台身份能力，这是最接近的做法，且不需改代码。
