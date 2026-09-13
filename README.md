# codeup-kiro：Codeup MR 自动 Kiro 代码评审

开发者在阿里云云效 Codeup 提交/更新合并请求（MR，等同 GitHub 的 PR）时，
云效 Flow 流水线自动调用 Kiro CLI headless 模式评审代码变更，
并把中文评审报告以评论形式回写到 MR 页面：默认是一条含完整问题清单的汇总评论，
开启开关后可定位的问题会落到「文件改动」的对应行上（行内评论）。
重跑时汇总评论原地更新（而不是新增一条）**需要先配置 `CODEUP_BOT_USERNAME`**，见下方环境变量表。

## 工作原理

    开发者提交/更新 MR (Codeup)
            │  webhook（Flow 自动注册）
            ▼
    云效 Flow 流水线
      ├─ 代码源1：业务库（源分支 checkout，仅作被分析数据）
      └─ 代码源2：本集成包（固定分支，受信脚本来源）
            ▼
    scripts/kiro-review.sh（从集成包执行）
      1. 依赖与必填变量检测（timeout 强制；此时还没定位到 MR，失败只让流水线标红）
      2. 定位 MR（环境变量优先，OpenAPI 反查兜底，歧义即报错）；
         找出本评审员上一次的汇总评论（原地更新与 run 计数的前提）。
         此后任何失败（含第 3 步的安装失败与能力检查不通过）都会在 MR 上回写「评审未完成」
      3. 安装/检测 kiro-cli；安装只读受信 agent（read/grep/glob，禁 shell/write/web/MCP；
         读取**许可清单** allowedPaths = 业务库 checkout + 本次 diff chunk 目录，安装时把三处结构化写成物理路径，
         两条路径缺任一或某工具 deniedPaths 缺失即拒绝安装，安装后按值自检（三处路径、allowedTools=[]、
         includeMcpJson/includePowers=false、deniedPaths 含 **/.git/**）不符即拒绝运行；敏感路径、.git 与仓库相对形状
         （**/.ssh/**、**/.aws/**、**/id_rsa*、**/id_ed25519*）的拒绝清单是第二道）
         + 二进制摘要钉死（配置 KIRO_CLI_SHA256 时在第一次执行 kiro-cli 之前核对入口文件 sha256，不一致拒绝；生产必配）
         + 能力检查（--agent-engine / --agent / --output-format 缺一即拒绝运行）+ kiro-cli「平台 + 版本」核对（`<os>/<arch>:<版本>` 不在 P1-15
         探测过的 KIRO_TESTED_TARGETS 名单里就**拒绝评审**——同一个版本换平台不算已验证，只有流水线变量 KIRO_ACK_UNTESTED_TARGET 逐字等于本次「平台:版本」才放行并带醒目 notice）；这几次 kiro-cli 调用同样以 env -i 固定名单启动
      4. merge-base 三点 diff；>300KB 按优先级压缩，省略文件以 diff 片段索引供 Kiro 自读；
         开启行内评论时同时算出「本次变更行集合」（零上下文 diff，与评审输入同源）
      5. 隔离（必须在 diff 算完之后、启动 Kiro 之前）：一次遍历移除业务库工作树中任意深度的
         AGENTS.md、.kiro/、**全部符号链接**及根 lsp.json（任意深度的 .git 目录内部不动），
         设置 chat.disableInheritingDefaultResources=true
      6. timeout 强制限时、`env -i` **固定名单**环境（PATH/HOME/USER/TERM/TMPDIR/LANG/LANGUAGE/LC_ALL/LC_CTYPE/LC_MESSAGES/
         KIRO_API_KEY/KIRO_LOG_NO_COLOR/代理十个/证书三个/XDG 五个，外加 KIRO_ENV_PASSTHROUGH 点名的变量——凭证形状的名字拒绝；
         云效令牌与 Flow 变量不进 Kiro 进程）执行
         kiro-cli chat --no-interactive --agent-engine v2 --output-format stream-json
                       --agent codeup-reviewer
         不传 --trust-tools（免确认只来自 allowedPaths），绝不传会绕过 allowedPaths 的 --trust-all-tools；
         报告取自 runFinished.data.finalText 里带本次随机串标记包裹的契约 JSON
      7. 由脚本渲染评论并回写 OpenAPI：
         · 汇总评论每个 MR 一条；配了 CODEUP_BOT_USERNAME 时重跑原地更新
           （run:N +1、历次评审表 +1 行），未配置时每次新建一条
         · INLINE_COMMENT=1 时可定位的问题按档位发成行内评论（草稿 + 一次提交，不提交评审意见），
           其余进汇总评论的折叠区
         · 评论只用两级标题（评论标题 `#`、章节 `##`），问题分组与每条问题是加粗行——
           Codeup 只渲染这两级标题，`###` 以下会显示为普通文字
         · 结构化解析失败降级为贴出评审员原文；评审未跑完则回写「评审未完成」

## 安全模型（必读）

- 本集成包必须作为独立受信代码源引入流水线，严禁拷入业务库执行
  （否则 MR 作者可改脚本窃取流水线密钥）。
- MR 源分支全部内容视为不受信数据：kiro-cli 从不在业务库里运行（四处调用都在一个空的临时目录下，业务库只在
  `allowedPaths` 里、模型按绝对路径读取），运行前再移除业务库中任意深度的 `AGENTS.md`、`.kiro`（任何类型、不分大小写）、
  全部符号链接与根目录 `lsp.json` 作为第二道；custom agent 关闭工作区
  MCP/Powers 加载（`includeMcpJson: false`、`includePowers: false`），工具仅 read/grep/glob（安装后脚本按值自检：
  `tools`、`allowedTools=[]`、三处 `allowedPaths`/`deniedPaths`、`resources=[]`、`permissions` 只含 deny、`toolsSettings` 无多余键），
  读取边界是**许可清单**（`allowedPaths`：业务库 checkout 与本次 diff chunk 目录，其它路径 headless 下直接被拒；
  业务库里的符号链接在启动前全部删除，免得 `payload -> /root/.aws/credentials` 借 allow 内的路径名读到 allow 外），
  `~/.ssh`、`~/.aws`、`~/.kiro`、`/proc`、`/var/run/secrets`、`**/.git/**` 等拒绝清单是第二道；
  Kiro 进程的四次 kiro-cli 调用（`chat --help`、`--version`、`settings`、`chat`）都以 `env -i` 固定名单环境启动，看不到云效令牌与 Flow 注入的其它变量。
- Kiro 固定以 `--agent-engine v2` 运行：实测 headless 的默认引擎（v1）与预览版 v3 都不阻断
  工作区 `AGENTS.md` 注入，只有 v2 配合 `chat.disableInheritingDefaultResources` 才阻断
  （见 [docs/adr/0004-pin-kiro-cli-v2-engine.md](docs/adr/0004-pin-kiro-cli-v2-engine.md)）。
- 评审员输出必须带受信 agent 提示词才要求的契约标识，缺失即判定「受信 agent 未生效」，
  拒绝把该输出贴到 MR 上。
- 哪些数据会离开客户网络（diff、评审员读取的上下文文件、MR 元信息）、哪些不会（令牌），
  以及提示词注入的残余风险，见 [pipeline/setup-guide.md](pipeline/setup-guide.md) 第 1.2 节与第 12 节。

## 快速开始

部署与验收全流程见 **[pipeline/setup-guide.md](pipeline/setup-guide.md)**：

| 想做的事 | 去哪一节 |
|---|---|
| 前提条件、令牌与机器人账号 | 第 1、1.1 节 |
| 数据治理：哪些数据出境、需要客户确认什么 | 第 1.2 节 |
| **信任边界：为什么必须把集成包放独立代码库** | 第 2 节（先读） |
| 搭流水线、开 MR 触发、首次运行探测变量名、多代码源的带下标变量 | 第 3–5 节 |
| 执行器连通性验证、自建执行器 | 第 6–7 节 |
| 首次联调核对（本地无法验证的点，按日志逐项确认） | 第 8 节 |
| 端到端验收清单（含 canary 负向验收） | 第 9 节 |
| 故障排查表、「行内评论未出现」的排查顺序 | 第 10 节 |
| 变量与开关矩阵（默认 / 关 / 开 / 前提 / 适用档位）、测试变量 | 第 11 节 |
| 安全隔离的作用与局限（kiro-cli 版本、v2 引擎、全局设置） | 第 12 节 |
| 改集成包时的本地自测（含 macOS 需要 coreutils） | 第 13 节 |

## 仓库结构

| 文件 | 职责 |
|---|---|
| `scripts/kiro-review.sh` | 主编排脚本：依赖检测、MR 定位、diff 生成、隔离、执行 Kiro 评审、发布行内评论与汇总评论 |
| `scripts/lib/codeup-api.sh` | Codeup OpenAPI 薄封装：MR 反查、评论增删改查、版本列表、草稿一次提交；HTTP 状态码判成败，仅网络/429/5xx 重试（创建行内评论只重试 429，因为创建不幂等） |
| `scripts/lib/review-render.sh` | 契约提取与校验、变更行集合、行内发布计划与区间去重、汇总/行内/降级/失败四类评论的渲染、超长截断 |
| `scripts/lib/diff-compress.sh` | diff 超限压缩：按优先级取舍文件，省略文件落盘为 diff 片段并输出索引清单 |
| `scripts/lib/kiro-agent.sh` | 受信 agent 安装（按 `name` 落盘、改写相对 `file://` 提示词引用、结构化写三处 allowedPaths、deniedPaths 检查、清理同名旧文件）、安装结果按值自检、Kiro 子进程环境固定名单 + `KIRO_ENV_PASSTHROUGH` 校验 |
| `scripts/lib/isolation.sh` | 工作区隔离：一次 `find` 删除业务库工作树里任意深度的 AGENTS.md / `.kiro`（不分大小写、任何类型）/ 符号链接与根 lsp.json，任意深度 `.git` 目录内部不动；与 `tests/helpers.sh` 的枚举谓词等价 |
| `scripts/probe/` | 环境探测脚本（真实 Codeup / 真实 kiro-cli），见下节与 `scripts/probe/README.md` |
| `prompts/review-agent-prompt.md` | agent 提示词（稳定部分）：只读角色、不受信输入、P0/P1/P2 判定、掩码规则、输出契约 |
| `prompts/review-prompt.md` | 运行时提示词（每次不同）：MR 元信息与本次契约标记随机串 `{{REVIEW_NONCE}}` |
| `kiro/agent-codeup-reviewer.json` | 只读 custom agent 定义：工具仅 read/grep/glob，`allowedPaths` 许可清单（两个运行时路径占位符，安装时注入），拒绝清单 V2/V3 双写，不加载工作区 MCP/Powers |
| `pipeline/flow-pipeline.yaml` | 云效 Flow 流水线参考配置：双代码源 + MR 触发事件 + 评审任务 + 变量清单 |
| `pipeline/setup-guide.md` | 部署指南：前提、流水线搭建、开关矩阵、验收清单、故障排查、安全隔离说明 |
| `tests/` | 测试套件：DRY_RUN + mock kiro-cli + golden file + 变异测试，全程无网络依赖 |
| `docs/adr/` | 决策记录（引擎钉版、档位选择、Security Agent 接入方式等） |

## 环境变量

下表是生产会用到的变量；**每个开关关闭/开启时各是什么行为、前提是什么**见
[pipeline/setup-guide.md 第 11.2 节](pipeline/setup-guide.md)，另有一节
「测试/高级变量（生产流水线不要设）」（第 11.2.1 节）列出 `DRY_RUN*`、`PROMPT_FILE`、
`CODEUP_RETRY_BACKOFF`、`CODEUP_COMMENT_PAGE_HINT`、`CODEUP_API_BASE` 等排障用变量及误配后果。

| 变量 | 必填 | 说明 |
|---|---|---|
| `KIRO_API_KEY` | 是 | Kiro API Key |
| `YUNXIAO_TOKEN` | 是 | 云效令牌，建议专用机器人账号（代码只读 + MR 读写） |
| `YUNXIAO_ORG_ID` | 是 | 云效组织 ID（中心站） |
| `CODEUP_REPO_ID` | 是 | Codeup 业务代码库数字 ID |
| `CODEUP_BOT_USERNAME` | 否 | 机器人账号在 Codeup 上的用户名。**汇总评论原地更新与行内评论按作者去重都以它为前提**；未配置时每次新建汇总评论。取值照抄首次运行日志里「新建评论的作者用户名=…」 |
| `INLINE_COMMENT` | 否 | `0`（默认）=只发一条含完整问题清单的汇总评论；`1`=可定位的问题发成行内评论，汇总退化为状态面板 + 折叠区。其它取值拒绝运行。开启前提：执行器有 `sha1sum`/`shasum`，且配置了 `CODEUP_BOT_USERNAME`（拿不到可信机器人账号时本轮按 `0` 处理、汇总写明原因）；注意行内评论以「未解决」状态创建，可能计入「评论全部解决才可合并」类门禁（见指南 11.3） |
| `INLINE_PROFILE` | 否 | 行内档位：`quiet`（默认，P0+P1）/ `balanced`（全部）/ `critical`（仅 P0）。非法取值回落 `quiet` 并在评论中说明 |
| `MAX_INLINE_COMMENTS` | 否 | 单次行内评论上限，默认 `10`，超出的进折叠区。非法取值回落 `10` 并在评论中说明 |
| `REVIEW_REPO_DIR` | 否 | 业务库 checkout 目录；缺省 `$PWD`（仅限单源 demo，生产必须双源+显式配置） |
| `MR_LOCAL_ID` | 否 | MR 编号；与 `MR_TARGET_BRANCH` 必须同时设置才生效，否则按源分支反查 |
| `MR_TARGET_BRANCH` | 否 | 目标分支；与 `MR_LOCAL_ID` 成对设置 |
| `CI_COMMIT_REF_NAME` | 否 | Flow 内置：运行分支（MR 触发=源分支）；缺省 `git rev-parse --abbrev-ref HEAD` |
| `REVIEW_RERUN_HINT` | 否 | 页脚与降级提示里「怎么重新评审」那句话，默认 `重跑流水线可重新评审`。Flow 档位接不到 Codeup 的评论事件（ADR-0001），所以默认不承诺 `/kiro review`；AWS 档位（Phase 2）会把它设成评论命令 |
| `DIFF_SIZE_LIMIT` | 否 | diff 直传阈值字节数，默认 307200。**必须是纯数字**（`300KB` 这类写法会被拒绝运行） |
| `KIRO_TIMEOUT` | 否 | Kiro 超时秒数，默认 900。**必须是纯数字**（`15m` 这类写法会被拒绝运行）。小 MR 实测整个任务 98–432 秒、Kiro 评审本身 20–130 秒；接近 300 KB diff 阈值、需读多个 diff 片段的大 MR 建议 1200–1800 |
| `MAX_COMMENT_BYTES` | 否 | 评论截断阈值字节数，默认 60000（非法取值回落默认并打日志） |
| `KIRO_INSTALL_URL` | 否 | kiro-cli 安装脚本 URL，默认 `https://cli.kiro.dev/install` |

## 探测脚本

`scripts/probe/` 下的脚本用来验证「只能在真实环境里才能确认」的行为，
本地测试套件覆盖不到它们。**什么时候用**：

- 接入一个新的 Codeup 组织/站点，想先确认行内评论相关接口的字段与响应形态；
- 端到端验收要做 canary 负向验收：AGENTS.md 注入（含**正控** `PROBE_NO_ISOLATION=1`，
  故意关掉隔离以证明 canary 真的会失败）、敏感路径拒绝（`PROBE_FORCE_READ=1`，
  提示词只要求读 canary 文件，从而把「拒绝生效」与「模型压根没去读」区分开）；
- 升级 kiro-cli 后核对事件流形态与引擎行为是否仍与实现一致。

| 脚本 | 覆盖 | 需要 |
|---|---|---|
| `probe-codeup-inline.sh` | 身份与 MR 字段、版本列表、行号侧向、必填字段、草稿一次提交、评论原地更新、评论列表过滤、`<details>` 渲染 | 令牌（代码只读 + MR 读写）+ 一个打开的**测试 MR** |
| `probe-kiro-headless.sh` | `stream-json` 事件形态、AGENTS.md 继承隔离（含正控）、敏感路径拒绝、v3 引擎对照 | 装有 kiro-cli 的机器 + `KIRO_API_KEY` 或已登录（**会消耗 credit**） |
| `probe-flow-run.sh` | `CreatePipelineRun` 的 `envs` / `runningBranchs` 是否覆写脚本读到的变量 | 令牌（流水线读写）+ 已配置的评审流水线 |

用法、逐项判定标准与常见问题见 [scripts/probe/README.md](scripts/probe/README.md)。所有脚本都不输出令牌。
副作用须知：`probe-codeup-inline.sh` 会在指定 MR 上创建评论，因此要求显式确认那是测试 MR
（`PROBE_I_KNOW_THIS_IS_A_TEST_MR=1`）并在结束时清理自己创建的评论；
`probe-flow-run.sh` **会真实触发一次评审运行**，那次运行会照常在指定 MR 上留下评论，
而它既没有测试 MR 门禁也不做清理——只在测试 MR 上用它，填参数前核对 MR 编号；
`probe-kiro-headless.sh` 不写 Codeup，但会消耗 Kiro credit。

## 本地测试

    bash tests/run-tests.sh

全程无网络依赖（DRY_RUN + mock kiro-cli），覆盖渲染 golden file、变更行解析、排序与上限、
区间去重、原地更新、降级与截断，以及一批变异测试（故意破坏守卫，证明它们真的会失败）。

`kiro-review.sh` 把 `timeout`/`gtimeout` 作为强制依赖（无超时能力时拒绝运行），
Linux 自带。macOS 需要 `brew install coreutils` 提供 `gtimeout`，否则
`tests/test-kiro-review.sh` 会整体跳过并打印 SKIP。
开启行内评论还需要 `sha1sum` 或 `shasum`（算行内评论隐藏标记里的指纹）。
