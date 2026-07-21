# 设计：Codeup MR 自动触发 Kiro CLI 代码评审

- 日期：2026-07-21
- 状态：已评审通过
- 术语说明：本文中 **MR（Merge Request，合并请求）** 即 Codeup 平台上的代码合并评审流程，等同于 GitHub 的 PR（Pull Request）。

## 1. 背景与目标

客户使用阿里云云效 Codeup（**中心站模式**，非 Region 站）管理代码。目标：开发者提交/更新 MR 时，自动触发 Kiro CLI Headless 模式完成代码评审，并将评审结果以 **Markdown 全局评论** 回写到 MR 页面。

参考：

- Kiro headless 文档：https://kiro.dev/docs/cli/headless/
- Kiro headless 介绍：https://kiro.dev/blog/introducing-headless-mode/
- GitHub Actions 集成范例：https://builder.aws.com/content/35cLFnKM6DJMgRzdZQ7XPZkJmoz/automate-reviews-in-github-actions-with-kiro-headless-mode

### 成功标准

在客户组织的测试仓库提交一个带明显问题的 MR（如硬编码密钥），MR 页面自动出现 Kiro 的中文评审评论。

### 需求决策（已与用户确认）

| 决策点 | 结论 |
|---|---|
| 结果呈现 | MR 全局评论（GLOBAL_COMMENT），不做行内评论 |
| 合并卡点 | 不设卡点；评审失败流水线标红提醒，不阻塞合并 |
| 构建环境 | 云托管与自建构建机两者兼顾，文档提供两套配置 |
| Kiro 订阅 | 客户已有 Pro 及以上订阅和 API Key 生成权限 |
| 交付物 | 可复用集成包（脚本 + 流水线配置 + 部署文档），存于本仓库 |
| diff 直传阈值 | 300KB，可通过环境变量调整 |

## 2. 关键事实（调研已验证）

### Codeup / Flow（中心站）

- Flow 流水线支持「代码源触发」，Codeup 代码源支持 **「合并请求新建/更新」** 事件（该事件为 Codeup 独有，其他 Git 源不支持）。触发后 Flow 使用 **源分支** 作为运行分支。
- 开启代码源触发后，Flow 自动将 webhook 注册到 Codeup 仓库（Webhooks 设置页可见）。若服务连接无自动配置权限，需手动在 Codeup 仓库设置中配置（常见触发失败原因）。
- 中心站 OpenAPI 接入点：`https://openapi-rdc.aliyuncs.com`，认证用个人访问令牌（请求头 `x-yunxiao-token`），中心站路径必须带 `organizationId`（组织管理后台「基本信息」页获取）。
- 回写评论接口：`POST /oapi/v1/codeup/organizations/{organizationId}/repositories/{repositoryId}/changeRequests/{localId}/comments`，`comment_type=GLOBAL_COMMENT`。
- 查询 MR 列表可按源分支/目标分支/状态过滤，用于反查 `localId`。
- Flow 内置环境变量：`CI_COMMIT_REF_NAME`（运行分支，MR 触发时为源分支）、`CI_COMMIT_SHA`、`PIPELINE_ID`、`BUILD_NUMBER`、`PROJECT_DIR` 等。Git 相关变量要求流水线包含「获取代码」步骤。

### Kiro CLI Headless

- 认证：环境变量 `KIRO_API_KEY`（仅 Pro / Pro+ / Pro Max / Power 订阅可生成；组织订阅需管理员开启 API Key 生成权限）。
- 调用：`kiro-cli chat --no-interactive "<prompt>"`，支持管道输入（`git diff | kiro-cli chat --no-interactive "..."`）。
- 权限控制：`--trust-tools=read,grep` 只授予只读工具（评审场景最佳实践，绝不授予 write/shell）。
- CI 环境设置 `KIRO_LOG_NO_COLOR=1`，避免终端颜色码污染评论内容。

### 待实施时验证的点

Flow 文档未明确列出 MR 编号（localId）的内置环境变量。实施采用双保险：

1. 实施第一步在 MR 触发的流水线里 `env | sort` dump 全部环境变量，确认是否存在 MR 相关变量（参考社区项目 yunxiao-LLM-reviewer，其 `CodeSource` 类从流水线环境变量解析出合并请求 ID，说明 MR 触发场景下存在此类变量）；
2. 若取不到，调 OpenAPI 按「源分支 + 目标分支 + 状态=评审中」查询 MR 列表反查 `localId`。

## 3. 整体架构

```
开发者提交/更新 MR (Codeup)
        │  webhook（Flow 自动注册，事件：合并请求新建/更新）
        ▼
云效 Flow 流水线（运行源分支代码）
        │
        ▼
Shell 任务步骤（执行仓库内版本化脚本 kiro-review.sh）
  1. 安装/检测 kiro-cli（KIRO_API_KEY 认证）
  2. 定位本次 MR（localId）+ 生成 diff（git diff origin/<target>...HEAD）
  3. kiro-cli chat --no-interactive --trust-tools=read,grep 执行评审
  4. 调 Codeup OpenAPI（中心站）以 GLOBAL_COMMENT 回写 Markdown 评审报告
```

### 方案选型

| 方案 | 说明 | 结论 |
|---|---|---|
| A. Flow + Shell 脚本 | MR 触发流水线，Shell 步骤跑版本化脚本 | **采用**：交付快、维护简单、脚本可版本化 |
| B. Flow 自定义步骤（flow-cli 发布） | 封装为组织级步骤，界面化配置 | 放弃：开发/发布成本高，适合后期规模化推广 |
| C. Webhook + 自建服务 | 自建常驻评审服务接收 webhook | 放弃：运维负担最重，不依赖 Flow 的优势对本场景无价值 |

## 4. 交付物结构（本仓库）

```
codeup-kiro/
├── README.md                  # 快速开始 + 架构说明
├── scripts/
│   ├── kiro-review.sh         # 主脚本：装 CLI → 评审 → 回写（幂等，可重复跑）
│   └── lib/
│       └── codeup-api.sh      # OpenAPI 封装：查 MR、发评论
├── prompts/
│   └── review-prompt.md       # 评审提示词模板（中文输出、按严重级别分类）
├── pipeline/
│   ├── flow-pipeline.yaml     # Flow YAML 流水线参考配置
│   └── setup-guide.md         # 控制台逐步配置指南（含两种构建环境）
└── docs/superpowers/specs/    # 设计文档（本文件）
```

### 各单元职责与接口

- **`kiro-review.sh`**：入口。读取环境变量（见下），编排「安装 → 定位 MR → 生成 diff → 评审 → 回写」全流程。任何环节失败均有明确日志与退出码。可在同一 MR 上重复运行（每次追加一条新评论，评论头部含 commit SHA 区分版本）。
- **`lib/codeup-api.sh`**：Codeup OpenAPI 的薄封装，提供 `codeup_find_mr <source_branch> <target_branch>`（返回 localId）与 `codeup_post_comment <localId> <markdown_file>` 两个函数。支持 `DRY_RUN=1` 只打印不发请求。
- **`prompts/review-prompt.md`**：评审提示词模板，要求中文输出、按「严重 / 警告 / 建议」分级、引用文件路径与行号、明确指示 Kiro 可用 read/grep 自行查阅仓库上下文。
- **`pipeline/flow-pipeline.yaml`**：Flow YAML 参考（代码源触发事件、Shell 步骤、变量声明）。
- **`pipeline/setup-guide.md`**：面向客户的控制台配置指南：创建令牌、配置流水线变量、开启代码源触发、连通性验证、两种构建环境差异、常见故障排查。

### 流水线变量（Flow「变量和缓存」中配置，私密模式）

| 变量 | 说明 |
|---|---|
| `KIRO_API_KEY` | Kiro API Key（私密） |
| `YUNXIAO_TOKEN` | 云效个人访问令牌，需代码只读 + MR 读写权限（私密） |
| `YUNXIAO_ORG_ID` | 云效组织 ID（中心站必需） |
| `DIFF_SIZE_LIMIT` | diff 直传阈值，默认 `307200`（300KB），可调 |
| `KIRO_TIMEOUT` | Kiro 评审超时秒数，默认 `900`（15 分钟），可调 |

## 5. 核心流程（kiro-review.sh）

1. **安装/检测 kiro-cli**：已存在则跳过（自建机预装场景）；否则 curl 安装（云托管场景）。安装失败快速退出，日志给出代理/自建机指引。
2. **获取目标分支并 fetch**：从环境变量或 OpenAPI 反查得到 MR 的目标分支，`git fetch origin <target>`。
3. **生成 diff**：`git diff origin/<target>...HEAD`，统计大小（`wc -c` 近似 token 预算）。
4. **组装提示词**（含 diff 压缩策略，见第 6 节）：模板 + diff（或压缩后的 diff + 文件清单）。
5. **执行评审**：`KIRO_LOG_NO_COLOR=1 kiro-cli chat --no-interactive --trust-tools=read,grep`，工作目录为仓库根（Kiro 可用 read/grep 查阅完整源码上下文——这是 agentic 评审优于纯 diff 评审的关键）。设置超时（默认 15 分钟，可调）。
6. **回写评论**：捕获输出为 Markdown，头部加元信息（commit SHA、源/目标分支、时间、是否截断），调 `codeup_post_comment` 发布 GLOBAL_COMMENT。
7. **失败处理**：评审失败（CLI 报错/超时）时回写一条「评审未完成」说明性评论并以非零退出——流水线标红提醒人工关注，**不设合并卡点，不阻塞合并**。

## 6. diff 压缩策略（大 MR 处理）

参考 PR-Agent（Qodo）的 Compression Strategy（https://docs.pr-agent.ai/core-abilities/compression_strategy/），并利用 Kiro 的 agentic 能力简化：

- **阈值内**（diff ≤ `DIFF_SIZE_LIMIT`，默认 300KB）：整个 diff 进提示词。
- **超阈值**：
  1. 按优先级排序：代码文件优先于文档/配置；增量（新增/修改）优先于纯删除 hunk；删除文件只保留文件名；
  2. 按预算逐文件装填，装不下的不硬塞；
  3. **未装入的文件不静默丢弃**：列成「变更文件清单（含每文件 +/- 行数）」写进提示词，并明确指示 Kiro 用 read 工具自行读取这些文件的变更部分；
  4. 评论头部注明「diff 超出直传阈值（300KB），已按优先级截断，其余文件由 Kiro 自主读取」，保证透明。

## 7. 错误处理与安全

| 场景 | 处理 |
|---|---|
| kiro-cli 安装失败/网络不通 | 快速失败，日志给出代理（`HTTP_PROXY`/`HTTPS_PROXY`）与自建机预装指引 |
| MR localId 取不到 | 先环境变量，后 OpenAPI 按分支反查；仍失败则跳过回写、评审结果仅输出到流水线日志，流水线标记失败 |
| diff 超 300KB | 第 6 节压缩策略 |
| OpenAPI 回写失败 | 重试 2 次（间隔退避）；仍失败则打印评审结果到日志，流水线标记失败 |
| Kiro 评审超时 | 默认 15 分钟超时，回写「评审未完成」评论，非零退出 |
| 密钥安全 | `KIRO_API_KEY`/`YUNXIAO_TOKEN` 全走 Flow 私密变量；脚本不落盘、不 echo；`set +x` 保护 |
| Kiro 工具权限 | 仅 `--trust-tools=read,grep`，绝不授予 write/shell |

## 8. 两种构建环境

| | 云托管构建机 | 自建构建机 |
|---|---|---|
| kiro-cli | 脚本内联 curl 安装 | 预装（脚本检测到已存在则跳过） |
| 境外网络 | 需先验证：setup-guide 提供一条最小连通性验证流水线（安装 kiro-cli + 一次最小 headless 调用） | 可控：支持配置 HTTP 代理 |
| 适用 | 网络通畅时最省事 | 网络受限或需固化环境时 |

## 9. 测试与验证

- **脚本单测/冒烟**：`codeup-api.sh` 用 `DRY_RUN=1` 本地验证请求组装；用固定 diff 样例本地跑 `kiro-review.sh` 的提示词组装与压缩逻辑（不实际调用 Kiro）。
- **连通性验证**：最小流水线确认构建机可安装 kiro-cli 并完成一次 headless 调用。
- **端到端验收**：客户组织建测试仓库 → 导入本集成包 → 按 setup-guide 配置流水线 → 提交带明显问题的 MR（硬编码密钥等）→ 确认 MR 页面出现 Kiro 中文评审评论；再提交一次更新，确认评论追加且头部 SHA 正确。

## 10. 范围外（YAGNI）

- 行内评论（INLINE_COMMENT）与精准行号定位
- 合并卡点 / Commit Status / Check Runs 回写
- Flow 自定义步骤封装（方案 B，规模化推广时再考虑）
- 多仓库批量接入自动化
