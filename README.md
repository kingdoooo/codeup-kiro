# codeup-kiro：Codeup MR 自动 Kiro 代码评审

开发者在阿里云云效 Codeup 提交/更新合并请求（MR，等同 GitHub 的 PR）时，
云效 Flow 流水线自动调用 Kiro CLI headless 模式评审代码变更，
并将中文 Markdown 评审报告以全局评论回写到 MR 页面。

## 工作原理

    开发者提交/更新 MR (Codeup)
            │  webhook（Flow 自动注册）
            ▼
    云效 Flow 流水线
      ├─ 代码源1：业务仓库（源分支 checkout，仅作被分析数据）
      └─ 代码源2：本集成包（固定分支，受信脚本来源）
            ▼
    scripts/kiro-review.sh（从集成包执行）
      1. 依赖检测（timeout 强制）+ 安装/检测 kiro-cli
      2. 隔离：移除业务仓库 .kiro/ + 安装只读 custom agent（includeMcpJson: false）
      3. 定位 MR（环境变量优先，OpenAPI 反查兜底，歧义即报错）
      4. merge-base 三点 diff；>300KB 按优先级压缩，省略文件以 diff chunk 索引供 Kiro 自读
      5. timeout 强制限时执行 kiro-cli chat --no-interactive --trust-tools=read,grep
      6. OpenAPI 回写 GLOBAL_COMMENT（HTTP 状态码判成败；仅网络/429/5xx 重试；
         append-only，评论含 <!-- kiro-review:<sha> --> 标记）

## 安全模型（必读）

- 本集成包必须作为独立受信代码源引入流水线，严禁拷入业务仓库执行
  （否则 MR 作者可改脚本窃取流水线密钥）。
- MR 源分支全部内容视为不受信数据：运行 Kiro 前移除其 .kiro/ 目录，
  custom agent 关闭工作区 MCP 加载（includeMcpJson: false），工具仅 read/grep。
- 数据出境与提示词注入残余风险见 pipeline/setup-guide.md 第 1 节。

## 快速开始

见 [pipeline/setup-guide.md](pipeline/setup-guide.md)。

## 仓库结构

| 文件 | 职责 |
|---|---|
| `scripts/kiro-review.sh` | 主编排脚本：依赖检测、隔离、MR 定位、diff 生成、执行 Kiro 评审、回写评论 |
| `scripts/lib/codeup-api.sh` | Codeup OpenAPI 薄封装：MR 反查、发评论，HTTP 状态码判成败，仅网络/429/5xx 重试 |
| `scripts/lib/diff-compress.sh` | diff 超限压缩：按优先级取舍文件，省略文件落盘为 diff chunk 并输出索引清单 |
| `prompts/review-prompt.md` | 评审提示词：中文 Markdown 报告格式、严重级别分类、行号引用要求 |
| `kiro/agent-codeup-reviewer.json` | 只读 custom agent 定义：工具仅 read/grep，`includeMcpJson: false` 不加载工作区 MCP |
| `pipeline/flow-pipeline.yaml` | 云效 Flow 流水线参考配置：双代码源 + MR 触发事件 + 评审任务 |
| `pipeline/setup-guide.md` | 部署指南：安全前提、密钥配置、流水线搭建与端到端验收步骤 |
| `tests/` | 测试套件：DRY_RUN + mock kiro-cli，全程无网络依赖 |

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `KIRO_API_KEY` | 是 | Kiro API Key |
| `YUNXIAO_TOKEN` | 是 | 云效令牌，建议专用机器人账号（代码只读 + MR 读写） |
| `YUNXIAO_ORG_ID` | 是 | 云效组织 ID（中心站） |
| `CODEUP_REPO_ID` | 是 | Codeup 业务代码库数字 ID |
| `REVIEW_REPO_DIR` | 否 | 业务仓库 checkout 目录；缺省 `$PWD`（仅限单源 demo，生产必须双源+显式配置） |
| `MR_LOCAL_ID` | 否 | MR 编号；与 `MR_TARGET_BRANCH` 必须同时设置才生效，否则按源分支反查 |
| `MR_TARGET_BRANCH` | 否 | 目标分支；与 `MR_LOCAL_ID` 成对设置 |
| `CI_COMMIT_REF_NAME` | 否 | Flow 内置：运行分支（MR 触发=源分支）；缺省 `git rev-parse --abbrev-ref HEAD` |
| `DIFF_SIZE_LIMIT` | 否 | diff 直传阈值字节数，默认 307200 |
| `KIRO_TIMEOUT` | 否 | Kiro 超时秒数，默认 900 |
| `MAX_COMMENT_BYTES` | 否 | 评论截断阈值字节数，默认 60000 |
| `KIRO_INSTALL_URL` | 否 | kiro-cli 安装脚本 URL，默认 `https://cli.kiro.dev/install` |
| `DRY_RUN` | 否 | `1`=不实际发 OpenAPI 请求 |
| `CODEUP_API_BASE` | 否 | 默认 `https://openapi-rdc.aliyuncs.com` |

## 本地测试

    bash tests/run-tests.sh

全程无网络依赖（DRY_RUN + mock kiro-cli）。
