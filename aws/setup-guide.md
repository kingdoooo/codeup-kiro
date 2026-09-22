# Codeup + Kiro 自动评审：AWS 档位接入手册

本档位把调度与执行搬到客户自己的 AWS 账号：Codeup Webhook → Lambda 调度器（校验、过滤、幂等）
→ ECS Fargate 临时任务（镜像内置钉死版本的 kiro-cli）。Flow 档位（见
[pipeline/setup-guide.md](../pipeline/setup-guide.md)）不因此退场，是客户没有 AWS 账号时的
退路；两者共用完全相同的评审引擎（`scripts/`、`prompts/`、`kiro/`，spec 不变式 **I9**），
本档位新增的只是 `aws/` 下的调度、执行与基础设施代码。见
[docs/adr/0001-aws-profile-as-target-architecture.md](../docs/adr/0001-aws-profile-as-target-architecture.md)。

**当前实现状态（写文档时点）**：CDK 出的执行器镜像与 State Stack（DynamoDB 幂等锁 + 映射表）
已实现；Lambda 调度器目前只有 webhook 签名校验一段代码。**调度器其余逻辑、Dispatcher/Executor
的完整 CDK 栈、兜底回写 Lambda、评论命令触发（Task 10、11、13）都还没写。** 本手册涉及这些部分时，
只描述运维应当观察到的**行为**，不给具体的资源名、CLI 命令或构造 ID——那些要等对应任务落地后再补。

## 1. 前提条件与数据治理确认

### 1.1 部署区域（必配，无默认）

`aws/config.py` 的 `region` 字段没有默认值，且只接受下面九个区域——这是 2026-09-22 对每个区域
实测一次 `ListAgentSpaces` 调用得出的有效集合（Security Agent 支持范围，2b 里程碑会用到，
但区域门本身在本档位就已生效）：

| 区域 | 区域 | 区域 |
|---|---|---|
| `us-east-1` | `us-west-2` | `ap-south-1` |
| `ap-southeast-1` | `ap-southeast-2` | `ap-northeast-1` |
| `eu-central-1` | `eu-west-1` | `sa-east-1` |

**实测确认不支持**（同一批探测里明确排除，不是遗漏）：`ap-east-1`（中国香港）、`cn-north-1`、
`cn-northwest-1`。`aws-cn` 分区完全不在范围内。

**直接后果**：一个中国大陆客户的部署**必然**落在中国境外——九个有效区域里没有任何一个在
中国大陆或香港。这件事要在客户确认「仓库出境」（见 1.2 节）时一并说清楚，不要等客户自己在
`cdk deploy` 时才发现区域选不了。

### 1.2 跨区推理警告（三个区域，条件式）

九个区域里 `ap-south-1`、`ap-southeast-1`、`sa-east-1` 三个用**全局**跨区推理——推理请求可能被
路由到**任意商业 AWS 区域**；其余六个用地理跨区推理，请求留在同一地理范围内。

这条警告是**条件式**的：本档位（2a）本身不调用任何模型推理，`aws/config.py` 只在这三个区域下
打印一行提醒（`cdk synth` 时可见），不阻断部署——**若日后启用 Security Agent**（2b 里程碑），
源码的模型推理才可能被路由出这三个区域的地理边界。数据落地在哪里是客户自己的合规判断，
这里的责任是把事实讲清楚，不代客户做决定。

### 1.3 数据流与治理披露（部署前必须书面确认）

三条数据流分别对应不同的持久性与引入时机，客户的合规评审人最容易把它们混为一谈——尤其是第二行：
它是 Flow 档位早就有的行为，**不是**本次新增的出境面。

| 数据流 | 去向 | 持久性 | 何时引入 |
|---|---|---|---|
| 业务库完整副本 | Fargate 任务（所选区域） | 临时存储，随任务销毁，**不持久化** | **本档位（2a）新增** |
| diff 与 Kiro 读到的文件内容 | Kiro 自己的服务（美国） | Kiro 侧 | Flow 档位**已存在**，非本档位新增 |
| 业务库完整归档 | S3（持久化）+ Security Agent 的模型推理 | 持久（7 天生命周期） | 后续里程碑（**2b**），见 [ADR-0003](../docs/adr/0003-security-agent-via-s3-differential-scan.md) |

**客户书面确认「仓库出境」是部署前的硬前置**（[ADR-0001](../docs/adr/0001-aws-profile-as-target-architecture.md)）：
执行器 clone 的是**业务库完整副本**，不再是 Flow 档位那样只有 diff 与评审员按需读取的文件——
这条数据治理条款必须重新取得书面确认，参考 `pipeline/setup-guide.md` 第 1.2 节的确认清单形态，
按上表把三条数据流分别列出、分别取得确认（不要笼统写「代码出境」，客户会误以为整个流程只有一条数据流）。

### 1.4 机器人账号与令牌权限

与 Flow 档位相同的最小权限要求（见 `pipeline/setup-guide.md` 第 1.1 节）：专用云效机器人账号，
授予目标业务库「代码只读 + 合并请求读写」，不给组织级管理员权限，令牌按周期轮换。区别只在于
令牌的存放位置——本档位下令牌进 Secrets Manager（见第 3 节），不进流水线变量。

### 1.5 残余风险

同 Flow 档位（`pipeline/setup-guide.md` 第 1.2 节末段）：被评审代码中的文本可能试图误导 AI
评审结论（提示词注入）；评审员只读、读取范围是许可清单；评论仅供参考、不设合并卡点，
最终合并决策始终在人工评审。

## 2. 部署集成包（信任边界）

Flow 档位靠「受保护分支」当集成包的信任锚；本档位没有这条路径——评审代码被烤进容器镜像，
**镜像摘要因此成为集成包自身唯一的信任锚**（`aws/executor/Dockerfile` 顶部注释明确这一点）。
执行器 entrypoint 在 clone 业务库、启动 Kiro **之前**先核对自己所在容器的镜像摘要是否在
`KIRO_IMAGE_DIGESTS` 名单内，不在名单里直接拒绝评审（第 6、8 节）。这一点与 Flow 档位「集成包
必须放独立代码库」的信任边界是同一个不变式的两种落地形态：谁能改评审代码，谁就能读到流水线密钥,
这里对应的是「谁能往镜像里塞代码、谁能改 `KIRO_IMAGE_DIGESTS` 名单」。

## 3. 密钥（Secrets Manager）

三个密钥必配，第四个为 2b 预留（本档位不创建）：

| 密钥名 | 用途 | 2a 是否必配 |
|---|---|---|
| `codeup-kiro/yunxiao-token-kiro` | Kiro 评审员使用的云效令牌（代码只读 + 合并请求读写） | 是 |
| `codeup-kiro/kiro-api-key` | Kiro API Key | 是 |
| `codeup-kiro/webhook-secret` | Lambda 调度器校验 Codeup webhook 共享密钥用（见 `aws/lambda/dispatcher/handler.py` 的 `WEBHOOK_SECRET`） | 是 |
| `codeup-kiro/yunxiao-token-security` | Security Agent 机器人账号的云效令牌 | **否，2b 才用**，先不要创建 |

创建命令（值本身在命令行历史与终端 scrollback 里可见，生产环境建议改用 `--cli-input-json`
从文件读取，或直接在控制台里创建）：

```bash
aws secretsmanager create-secret \
  --name codeup-kiro/yunxiao-token-kiro \
  --description "Kiro 评审员使用的云效令牌（代码只读 + 合并请求读写）" \
  --secret-string '<云效令牌>'

aws secretsmanager create-secret \
  --name codeup-kiro/kiro-api-key \
  --description "Kiro API Key" \
  --secret-string '<Kiro API Key>'

aws secretsmanager create-secret \
  --name codeup-kiro/webhook-secret \
  --description "Lambda 调度器校验 Codeup webhook 用的共享密钥" \
  --secret-string '<随机生成的共享密钥，与 Codeup webhook 配置里填的值一致>'
```

**硬规则**：
- 密钥**绝不进镜像层**——`aws/executor/Dockerfile` 有静态测试守着这条（`test_contains_no_secret_material`）；
- 密钥**绝不经 `RunTask` 的调用参数传递**——那些参数会落进 CloudTrail 事件，等于把密钥写进审计日志；
  任务定义（task definition）里只存 Secrets Manager 的 ARN，由 ECS 在容器启动时注入环境变量；
- **`codeup_token` 从来不是 `config.yaml` 的字段**（`.gitignore` 里专门有一条注释说明这件事）：
  运行时配置来自平台从 Secrets Manager 灌入的环境变量，`config.yaml`/`config.example.yaml` 只放
  区域、组织 ID、开关这类非敏感的部署静态值；
- **AWS 凭证本身不需要任何密钥**：任务角色（task role）通过容器凭证端点（container credentials
  endpoint）向执行器提供临时凭证，不要为「AWS 访问」单独建一个 Secrets Manager 条目。

## 4. 变量三分类

一套部署服务多个业务库，所以环境变量按「谁决定这个值」分三类：

### 4.1 调度器按 webhook 载荷逐次派生（每次运行不同）

| 变量 | 来源 |
|---|---|
| `CODEUP_REPO_ID` | webhook 载荷里的代码库 ID |
| 业务库 clone URL（`BUSINESS_REPO_URL`） | webhook 载荷 |
| `MR_LOCAL_ID` | webhook 载荷里的 MR 编号 |
| `MR_TARGET_BRANCH` | webhook 载荷里的目标分支 |
| `CI_COMMIT_REF_NAME` | webhook 载荷里的源分支（`aws/executor/entrypoint.sh` 直接要求这四项，缺一硬失败） |
| `HEAD_SHA` | webhook 载荷里本次评审的提交 |

### 4.2 部署级静态（同一部署下所有业务库共用，随 CDK 部署一次性配置）

| 变量 | 说明 |
|---|---|
| `YUNXIAO_ORG_ID` | 云效组织 ID |
| `CODEUP_BOT_USERNAME` | 机器人账号用户名（原地更新汇总评论、行内评论按作者去重的前提，同 Flow 档位） |
| 部署区域 | 第 1.1 节的九选一，`aws/config.yaml` 的 `region` 字段 |

### 4.3 行为开关

| 变量 | 说明 |
|---|---|
| `INLINE_COMMENT` | 是否发行内评论。共享评审引擎（`scripts/`）的既有语义：只收 `0`/`1`，非法取值拒绝运行；详见 `pipeline/setup-guide.md` 第 11.2 节，本档位不改这条语义 |
| `INLINE_PROFILE` | 行内档位：`quiet`（默认）/ `balanced` / `critical`，同上共享语义，**不是** 0/1 布尔值 |
| `MAX_INLINE_COMMENTS` | 单次行内评论上限，非负整数，默认 `10`，同上共享语义 |
| `KIRO_TIMEOUT` | Kiro 超时秒数，默认 `900`，只收纯数字，同上共享语义 |
| `DIFF_SIZE_LIMIT` | diff 直传阈值字节数，默认 `307200`，只收纯数字，同上共享语义 |
| `TARGET_BRANCH_FILTER` | 目标分支过滤（对应 `aws/config.py` 的 `target_branch_filter`）。**调度器尚未实现（Task 11）**：这里只能描述预期行为——配置后只有匹配目标分支的 MR 会触发评审，不匹配的 webhook 请求被静默忽略；具体取值形态（正则 / glob）以 Task 11 落地时的实现为准 |
| `REVIEW_COMMAND_PHRASE` | 评论命令触发短语（对应 `aws/config.py` 的 `review_command` 开关 + 短语文本）。**评论命令触发尚未实现（Task 13）**：预期行为是在 MR 上评论一句配置的短语（如 `/kiro review`）可触发重新评审，取代 Flow 档位「只能重跑流水线」的限制（`REVIEW_RERUN_HINT` 在本档位下会改写成这句话，见 `pipeline/setup-guide.md` 第 11.2 节该行）；具体接口以 Task 13 落地时的实现为准 |

> `TARGET_BRANCH_FILTER` 与 `REVIEW_COMMAND_PHRASE` 两项因为背后的调度逻辑还没写，这里刻意只写
> 「运维应当观察到的行为」，不写具体的环境变量语法或校验规则——避免文档先于代码把接口定死。

## 5. 镜像构建与摘要登记

### 5.1 构建

安装包 `kirocli-x86_64-linux-musl.zip` **不在本仓库里**，由 Kiro 官方发布渠道单独获取
（见 `pipeline/setup-guide.md` 第 6.1 节「一次性备包」小节的下载与摘要核对方式）。操作者把它
放到 `aws/executor/` 目录下（与 `Dockerfile` 同级），再从**仓库根目录**构建（构建上下文是仓库根，
`Dockerfile` 需要 `COPY scripts/ prompts/ kiro/` 这些仓库根下的目录）：

```bash
docker build -f aws/executor/Dockerfile -t codeup-kiro-executor:2.21.4 .
```

构建期会用 `sha256sum --strict -c` 核对这个安装包的摘要——摘要写死在 `Dockerfile` 里的
`ARG KIRO_PINNED_ARTIFACT_SHA256`（完整 64 位十六进制值，不是截断值：截断摘要会让
`sha256sum -c` 只发警告就 `exit 0`，门形同虚设）。**Linux 必须用 musl 变体**，不是 glibc——
已探测的「平台 + 版本」元组 `linux/x86_64:2.21.4` 是对 musl 入口文件跑出来的，换成 glibc
变体等于换了一个从未探测过的组合，要重新走一遍 `scripts/probe/README.md` 的探测流程。

### 5.2 摘要登记（KIRO_IMAGE_DIGESTS）

构建完成后读出镜像摘要并加进 `KIRO_IMAGE_DIGESTS`——entrypoint 在第一步（clone 业务库之前）
就核对自己所在容器的镜像摘要是否在这个名单里，不在名单里直接拒绝评审（`aws/executor/entrypoint.sh`
的 N1 门，退出码 90）：

```bash
docker inspect --format='{{index .RepoDigests 0}}' codeup-kiro-executor:2.21.4
# 或部署后从 ECS 任务的容器级元数据端点读 .ImageID
```

**摘要格式约定必须显式说明，不能靠默契**：ECS 容器级元数据端点返回的 `ImageID` 带 `sha256:`
前缀（形如 `sha256:25f3…`），entrypoint 在核对前会剥掉这个前缀（`self_digest="${raw_digest#sha256:}"`），
所以 `KIRO_IMAGE_DIGESTS` 里存的**必须是裸十六进制**，不带 `sha256:` 前缀。操作者若把
`docker inspect` 或控制台上带前缀的完整形式原样粘进去，entrypoint 两边比对不上，评审会被
无声地拒绝——错误信息里只会打印读到的摘要，不会提示「你把前缀也粘进来了」，排查时先检查这一点。

升级 kiro-cli 版本时要重新走一遍：重新探测（新平台/版本要在 `scripts/probe/README.md` 走一遍
「升级 kiro-cli 之后」流程）→ 改 `Dockerfile` 的 `ARG KIRO_CLI_VERSION` 与 `KIRO_PINNED_ARTIFACT_SHA256`
→ 重新构建 → 把新摘要**追加**进 `KIRO_IMAGE_DIGESTS`（先追加新的、确认新任务都已切到新摘要后再
从名单里删旧的，避免切换窗口内正在跑的旧任务被自己的摘要门拒绝）。

## 6. CDK 部署

**当前只有 State Stack（`aws/stacks/state_stack.py`）已实现**：两张 DynamoDB 表（评审幂等锁
`ReviewLock`，TTL 24h；`repo → codeReviewId` 映射表 `CodeReviewMapping`，2a 建表但不使用，留给
2b），两张表的删除策略都是 `RETAIN`。Dispatcher（Lambda）与 Executor（ECS/Fargate/VPC/任务定义）
对应的 CDK 栈**尚未实现（Task 11）**，本节暂不给出 `cdk deploy` 的具体子命令或栈名——那些要等
Task 11 落地后再补，避免文档写出一个此刻并不存在的部署拓扑。

`aws/config.yaml`（不进版本库，复制 `aws/config.example.yaml` 并填入真实值）在 `cdk synth` 阶段
就会被 `aws/app.py` 读取校验：区域不在九个有效区域内、`org_id`/`bot_username` 缺失、或
`inline_comment`/`review_command` 取值不严格是 `0`/`1`，都会在 synth 阶段直接报错并中止，
不会带着错误配置继续往前跑。

## 7. 本地测试

`aws/` 下的 CDK/Lambda 测试用 pytest，依赖装进项目内的虚拟环境 `aws/.venv`（已加入
`.gitignore`，不要提交）：

```bash
python3 -m venv aws/.venv
aws/.venv/bin/pip install -r aws/requirements.txt
```

装好后 `bash tests/run-tests.sh`（或单独 `bash tests/test-aws-cdk.sh`）会自动发现并使用这个
虚拟环境；没有它时会退回系统 `python3`，系统解释器也没装依赖时整套 AWS 测试打印一行 `SKIP`
并说明原因（`pip install -r aws/requirements.txt`），**不会**让整体测试静默变绿却什么都没跑——
这与 `timeout`/`gtimeout` 缺失时 `test-kiro-review.sh` 的跳过先例是同一套约定（见根目录
`CLAUDE.md`「本地测试」一节）。

## 8. 排错

| 现象 | 排查 |
|---|---|
| 评审被拒绝，日志/退出码指向「镜像摘要不在已探测名单内」（entrypoint 退出码 90） | 镜像重新构建过、但没有把新摘要登记进 `KIRO_IMAGE_DIGESTS`（第 5.2 节）。核对当前任务实际跑的镜像摘要与名单是否一致；也检查是不是把带 `sha256:` 前缀的完整形式粘进了名单——名单里必须是裸十六进制 |
| 评审被拒绝，日志/退出码指向「clone 业务库失败」（entrypoint 退出码 91） | 云效令牌（`codeup-kiro/yunxiao-token-kiro`）过期或权限不足（需代码只读 + 合并请求读写）；执行器网络不通（VPC/子网/安全组配置，或出网路径）；业务库 URL/仓库权限本身有问题。三者从同一条报错信息区分不开，需要逐个排除 |
| 同一个 MR 短时间内被评审两次，或看到「抢锁」相关的提示（幂等锁 `ReviewLock` 表） | **预期行为，不是错误**：webhook 被重放，或 Codeup 的「批准」事件与「新建/更新」事件都触发了调度器。幂等锁按「仓库#MR#提交」这个键去重，重复请求会被挡在真正拉起 Fargate 任务之前 |
| MR 上出现调度器写的「评审未启动」类评论 | 调度器判定收到了合法请求，但 `RunTask` 本身被节流或调用失败——多为 Fargate 任务并发数/账号级限流，或任务定义/网络配置有误导致 `RunTask` 直接报错。这条评论意味着 Fargate 任务从未真正跑起来，评审引擎本身没有机会失败 |
| MR 上出现「兜底」类回写评论（评审没有正常结论，也没有评审引擎自己的失败原因） | 与上一条不同：`RunTask` 成功了，任务真的起来过，但没能跑到评审脚本自己汇报结果那一步就死掉了——常见原因是镜像拉取失败（registry 权限、镜像被删）、容器 OOM（`ephemeral_storage`/内存配置不够大 diff 的仓库）、或任务在 `KIRO_TIMEOUT` 之外的更外层超时（任务本身的运行时长上限）被杀。这条评论是任务级的兜底，不经过评审脚本自己的失败评论路径，所以看不到评审脚本给出的具体原因 |

以上「抢锁冲突」「评审未启动」「兜底回写」三行描述的是调度器/兜底 Lambda（Task 10、11）尚未实现
时**预期上线后**的行为，不是当前代码里能复现的现象——落地后请对照真实日志核对措辞是否一致，
不一致时以代码为准并更新本表。
