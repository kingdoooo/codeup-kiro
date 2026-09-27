# Codeup + Kiro 自动评审：AWS 档位接入手册

本档位把调度与执行搬到客户自己的 AWS 账号：Codeup Webhook → CloudFront → VPC origin → 内网 ALB
→ Lambda 调度器（校验、过滤、幂等）→ ECS Fargate 临时任务（镜像内置钉死版本的 kiro-cli）。Flow 档位（见
[pipeline/setup-guide.md](../pipeline/setup-guide.md)）不因此退场，是客户没有 AWS 账号时的
退路；两者共用完全相同的评审引擎（`scripts/`、`prompts/`、`kiro/`，spec 不变式 **I9**），
本档位新增的只是 `aws/` 下的调度、执行与基础设施代码。见
[docs/adr/0001-aws-profile-as-target-architecture.md](../docs/adr/0001-aws-profile-as-target-architecture.md)。

**当前实现状态（写文档时点）**：`aws/app.py` 在 `aws/config.yaml` 存在时挂载三个 stack——
`CodeupKiroState`（DynamoDB 幂等锁 + 映射表）、`CodeupKiroExecutor`（VPC、ECS 集群、Fargate 任务定义、
执行器镜像）、`CodeupKiroDispatcher`（webhook 入口、调度 Lambda、兜底 Lambda），`cdk deploy` 会真的创建
这些资源（第 6 节）。已实现的代码路径：webhook 共享密钥校验、幂等抢锁、`RunTask` 与失败回写、执行器
entrypoint（N1 镜像摘要门、clone、调用评审脚本、「已回写」标记）、任务异常结束的兜底回写。**尚未实现**：
调度器的事件过滤与把 webhook 接到「抢锁 → `RunTask`」这一步（实现计划 Task 5，依赖第 6.1 节的真实报文
探测），以及评论命令（Task 13）。所以**此刻部署后，合法的 webhook 只会得到 200，不会拉起评审任务**——
这是预期现象，不是故障；Task 5 落地后本段与第 4.3 节对应两行要随之更新。

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
必须放独立代码库」的信任边界是同一个不变式的两种落地形态：谁能改评审代码，谁就能读到流水线密钥，
这里对应的是「谁能往镜像里塞代码、谁能改 `KIRO_IMAGE_DIGESTS` 名单」。

## 3. 密钥（Secrets Manager）

三个密钥必配，第四个为 2b 预留（本档位不创建）：

| 密钥名 | 用途 | 2a 是否必配 |
|---|---|---|
| `codeup-kiro/yunxiao-token-kiro` | Kiro 评审员使用的云效令牌（代码只读 + 合并请求读写） | 是 |
| `codeup-kiro/kiro-api-key` | Kiro API Key | 是 |
| `codeup-kiro/webhook-secret` | Lambda 调度器校验 Codeup webhook 共享密钥用（调度器在每次调用时按注入的 `WEBHOOK_SECRET_ID`——即这里的密钥名——向 Secrets Manager 取值，见 `aws/lambda/dispatcher/secret_fetch.py`） | 是 |
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
| `LOCK_KEY` | 调度器抢锁时写入的幂等锁键（仓库#MR#提交，评论命令再加评论 id），原样传给执行器——执行器置「已回写」标记、兜底 Lambda 读标记都只认它，不自己重建。只供 entrypoint 使用，不导出给评审脚本 |

### 4.2 部署级静态（同一部署下所有业务库共用，随 CDK 部署一次性配置）

| 变量 | 说明 |
|---|---|
| `YUNXIAO_ORG_ID` | 云效组织 ID |
| `CODEUP_BOT_USERNAME` | 机器人账号用户名（原地更新汇总评论、行内评论按作者去重的前提，同 Flow 档位） |
| 部署区域 | 第 1.1 节的九选一，`aws/config.yaml` 的 `region` 字段；三个 stack 都钉到这个区域 |

`aws/config.yaml` 的**全部**键（含默认值与是否必配）列在 [aws/config.example.yaml](config.example.yaml)，
代码读取而示例里没写的键会让测试失败。注意 `bot_username`（单数，执行器用来原地更新汇总评论）与
`bot_usernames`（复数，调度器忽略哪些作者的评论，默认只含前者）是两个键。

### 4.3 行为开关

执行器的开关与评审行为变量由 `config.yaml` 写进任务定义的容器环境（默认值与 `scripts/` 里的缺省值
逐项一致，有测试比对）；取值语义归共享评审引擎（`scripts/`），与 Flow 档位同一套规则，详见
`pipeline/setup-guide.md` 第 11.2 节，本档位不改这些语义。

| 变量 | `config.yaml` 键 | 说明 |
|---|---|---|
| `INLINE_COMMENT` | `inline_comment` | 是否发行内评论，只收 `0`/`1`（`config.py` 在 synth 时就拒绝别的取值，包括 YAML 里未加引号的 `yes`/`true`） |
| `INLINE_PROFILE` | `inline_profile` | 行内档位：`quiet`（默认）/ `balanced` / `critical`，**不是** 0/1 布尔值 |
| `MAX_INLINE_COMMENTS` | `max_inline_comments` | 单次行内评论上限，非负整数，默认 `10` |
| `KIRO_TIMEOUT` | `kiro_timeout` | Kiro 超时秒数，默认 `900`，只收纯数字 |
| `DIFF_SIZE_LIMIT` | `diff_size_limit` | diff 直传阈值字节数，默认 `307200`，只收纯数字 |
| `MAX_COMMENT_BYTES` | `max_comment_bytes` | 单条评论字节上限，默认 `60000` |
| `TARGET_BRANCH_FILTER` | `target_branch_filter` | 调度器：目标分支正则，空 = 全部 MR。环境变量已随调度 Lambda 部署，**过滤逻辑随 Task 5 落地**——此刻它还不生效 |
| `REVIEW_COMMAND` / `REVIEW_COMMAND_PHRASE` | `review_command` / `command_phrase` | 调度器：评论命令开关（`0`/`1`）与触发短语（默认 `/kiro review`）。**评论命令触发尚未实现（Task 13）**：预期行为是在 MR 上评论这句短语即可重新评审，取代 Flow 档位「只能重跑流水线」的限制 |

## 5. 镜像构建与摘要登记

### 5.1 构建

安装包 `kirocli-x86_64-linux-musl.zip` **不在本仓库里**，由 Kiro 官方发布渠道单独获取
（见 `pipeline/setup-guide.md` 第 6.1 节「一次性备包」小节的下载与摘要核对方式）。操作者把它
放到 `aws/executor/` 目录下（与 `Dockerfile` 同级），再从**仓库根目录**构建（构建上下文是仓库根，
`Dockerfile` 需要 `COPY scripts/ prompts/ kiro/` 这些仓库根下的目录）：

```bash
docker build --platform linux/amd64 -f aws/executor/Dockerfile -t codeup-kiro-executor:2.21.4 .
```

`--platform linux/amd64` 不能省：`docker build` 的缺省是构建机当前平台，在 Apple Silicon 上会构建出
`linux/arm64`，而 Fargate 任务定义是 X86_64（`aws/stacks/executor_stack.py` 里与镜像资产成对写死），
拉取时直接 `TaskFailedToStart` / `CannotPullContainerError: … image Manifest does not contain
descriptor matching platform 'linux/amd64'`；烤进镜像的 `kirocli-x86_64-linux-musl` 本身也只有 x86_64。
`cdk deploy` 走的是 `DockerImageAsset`，那一侧的平台已经在代码里钉住，不依赖这条手工命令。
基础镜像取自 `public.ecr.aws/docker/library/debian:stable-slim`（与 Docker Hub 的
`debian:stable-slim` 同一个镜像）：实测有些网络下 `auth.docker.io` 会超时，Docker Hub 拉不动。

构建期会用 `sha256sum --strict -c` 核对这个安装包的摘要——摘要写死在 `Dockerfile` 里的
`ARG KIRO_PINNED_ARTIFACT_SHA256`（完整 64 位十六进制值，不是截断值：截断摘要会让
`sha256sum -c` 只发警告就 `exit 0`，门形同虚设）。**Linux 必须用 musl 变体**，不是 glibc——
已探测的「平台 + 版本」元组 `linux/x86_64:2.21.4` 是对 musl 入口文件跑出来的，换成 glibc
变体等于换了一个从未探测过的组合，要重新走一遍 `scripts/probe/README.md` 的探测流程。

### 5.2 摘要登记（KIRO_IMAGE_DIGESTS）

名单在 `config.yaml` 里的键是 **`kiro_image_digests`**（写进任务定义的 `KIRO_IMAGE_DIGESTS`）：空白分隔，
每项 64 位小写十六进制。entrypoint 在第一步（clone 业务库之前）就核对自己所在容器的镜像摘要是否在这个
名单里，不在名单里、或读不到自身摘要，都直接拒绝评审（`aws/executor/entrypoint.sh` 的 N1 门，退出码 90）。
它与两个 kiro-cli 摘要（`kiro_pinned_artifact_sha256`、`kiro_cli_sha256`）一样是**必配、无默认**，
缺失或格式不对时 `cdk synth` 就报错。

**摘要格式约定**：ECS 容器级元数据端点返回的 `ImageID` 带 `sha256:` 前缀（形如 `sha256:25f3…`），
entrypoint 核对前会剥掉它，所以名单里存的**必须是裸十六进制**。把带前缀的形式粘进 `config.yaml`，
`cdk synth` 会直接报错并点名前缀；全是数字的值必须加引号（否则 YAML 把它解析成整数，同样报错）。

**首次部署的引导**：真实镜像摘要要等镜像构建、推送之后才有，所以第一次部署时名单里还没有它。按这个
顺序走（失败方向始终是关闭——占位值不可能匹配任何真实镜像，entrypoint 以退出码 90 拒绝评审）：

1. `kiro_image_digests` 先填 64 个 `0` 的占位值（`config.example.yaml` 里就是它），照第 6 节部署。
2. 读出执行器镜像的真实摘要。首选 ECR：任务定义里的镜像地址形如
   `<账号>.dkr.ecr.<区域>.amazonaws.com/cdk-<qualifier>-container-assets-<账号>-<区域>:<标签>`，
   ```bash
   aws ecr describe-images --region <区域> \
     --repository-name cdk-<qualifier>-container-assets-<账号>-<区域> \
     --image-ids imageTag=<标签> --query 'imageDetails[0].imageDigest' --output text
   ```
   输出形如 `sha256:…`，去掉 `sha256:` 前缀。或者等第一次真实评审被拒：执行器日志（日志组名以
   `CodeupKiroExecutor-ExecutorLogs` 开头，流前缀 `executor`）里有一行
   「镜像摘要不在已探测名单内，拒绝评审：<摘要>」，MR 上同时会出现一条兜底的「评审未完成」。
   ECR 的 `imageDigest` 与 ECS 元数据的 `ImageID` **逐字一致，已实测**（Task 1 真实 sandbox，
   2026-09-27，X86_64 Fargate）：镜像按生产路径构建并推送（`docker build --platform linux/amd64`
   + `docker push`，containerd 镜像存储，所以 ECR 里是带 attestation 子清单的 **OCI image index**），
   容器级元数据端点顶层 `.ImageID`、`DescribeTasks` 的 `containers[].imageDigest`、以及上面那条
   `aws ecr describe-images --image-ids imageTag=<标签>` 的 `imageDigest`，三者返回同一个值——
   **index 自身的摘要**，不是某个平台子清单的摘要。所以上面那条命令取到的就是 entrypoint 会拿去
   比对的那个值，不必先让一次评审被拒来换取摘要。
   证据等级：**sandbox 单次实测**，一个账号、一个区域、上面这一种构建方式。换构建方式（不走
   containerd 镜像存储、或推一个单平台清单而不是 index）没有测过，那时三者的关系可能不同。
   所以这条交叉核对仍然保留：被拒时执行器日志里那行「镜像摘要不在已探测名单内，拒绝评审：<摘要>」
   打印的是 entrypoint **实际读到**的值，与上面命令的输出不一致时一律以日志里那个为准。
3. 把真实摘要**追加**进 `kiro_image_digests`（占位值可以同时删掉），再 `cdk deploy CodeupKiroExecutor`。
   `config.yaml` 不在镜像构建上下文里，改它不会触发重新构建，镜像与摘要保持不变（有测试守着这一条）。

升级 kiro-cli 版本时要重新走一遍：重新探测（新平台/版本要在 `scripts/probe/README.md` 走一遍
「升级 kiro-cli 之后」流程）→ 改 `Dockerfile` 的 `ARG KIRO_CLI_VERSION` 与 `KIRO_PINNED_ARTIFACT_SHA256`
→ 重新构建 → 把新摘要**追加**进 `KIRO_IMAGE_DIGESTS`（先追加新的、确认新任务都已切到新摘要后再
从名单里删旧的，避免切换窗口内正在跑的旧任务被自己的摘要门拒绝）。

## 6. CDK 部署

### 6.1 前置：P2a-08 入口探测（阻塞）

webhook 入口是 **CloudFront → VPC origin → 私有隔离子网里的内网 ALB → 调度 Lambda**（`aws/stacks/ingress.py`）。
静态断言只能证明形状，证明不了 CloudFront 真的把 Codeup 的 POST 原样送进 Lambda——上一版入口
（CloudFront + OAC → `AWS_IAM` Function URL）就是被一套全绿的静态断言放过去的：AWS 要求经 OAC 向
Function URL 发 POST 的发送方自己算正文 SHA256，Codeup 不会发，每次投递都会被静默拒绝。所以正式部署前，
先在**同一个区域**部署探测栈，真跑一遍（对应实现计划 Task 1 / 待取事实 P2a-08）：

```bash
cd aws
cdk --app "python3 probe_app.py" -c region=<区域> deploy CodeupKiroIngressProbe
```

探测栈与生产栈复用同一个入口构造，只把目标换成回显 Lambda（`aws/lambda/probe_echo/handler.py`：把请求头
与解码后的正文写进 CloudWatch，`X-Codeup-Token` 打码；响应正文是解码后正文字节的 SHA256）。四条判据全过
才算通过：① 含中文的 JSON 正文用 `application/json`、`application/json; charset=UTF-8`、
`application/octet-stream`（最后一种会让 ALB 改走 base64）三种 `Content-Type` POST 到输出 `ProbeUrl`，
响应都等于本地算的 SHA256；② `GET` 得 404；③ 输出 `AlbDnsName` 从公网连不上；④ 在 Codeup 注册一个指向
`ProbeUrl` 的 webhook（一次性的 Secret Token），它的投递记录是 2xx 且回显日志里有对应报文。做完删掉：

```bash
cdk --app "python3 probe_app.py" -c region=<区域> destroy CodeupKiroIngressProbe
```

### 6.2 区域、可用区与费用

- **区域**：`config.yaml` 的 `region`，三个 stack 都钉到这个区域（不受 `AWS_REGION` 或 profile 默认区域
  影响）；`cdk bootstrap` 因此是**按区域**的，换区域要在新区域重新 bootstrap。
- **可用区（G7）**：VPC origin 在九个区域都可用，但 `us-east-1` 的 `use1-az3` 与 `ap-northeast-1` 的
  `apne1-az3` 两个可用区不支持。执行器 VPC 取该区域的**前两个**可用区，而可用区名（`us-east-1a`…）到
  ID（`use1-az3`…）的映射**按账号而异**，所以在这两个区域部署前先核对：
  ```bash
  aws ec2 describe-availability-zones --region us-east-1 \
    --query 'AvailabilityZones[].[ZoneName,ZoneId]' --output text
  ```
  前两行里若出现 `use1-az3`（`ap-northeast-1` 为 `apne1-az3`），本版本不能直接部署到该账号的这个区域
  ——当前没有可用区选择配置。
- **CloudFront→ALB 走 HTTP 80（G3）**：ALB 的默认域名 `*.elb.amazonaws.com` 申请不到 ACM 证书，HTTPS 源站
  需要自有域名，本版本不引入。这一段走 VPC origin 的私有连接、不经公网；Codeup→CloudFront 一段仍是 HTTPS。
  ALB 安全组只放 CloudFront 源站托管前缀列表（`com.amazonaws.global.cloudfront.origin-facing`）的 80 端口，
  执行器任务虽在同一个 VPC 里也连不上它。
- **费用与耗时**：内网 ALB 按小时计固定费用（与流量无关，没有评审也在计费）；VPC origin 的创建与删除
  各需约 15 分钟，`cdk deploy`/`cdk destroy` 会在这一步停留较久，属正常现象；执行器 VPC 另有两个隔离子网，
  不需要 NAT。

### 6.3 部署

前提：第 3 节的三个密钥已在**同一区域**创建；第 5.1 节的安装包已放到 `aws/executor/`（`cdk deploy` 会从
仓库根构建执行器镜像并推到 CDK 的资产 ECR 仓库）；本机有 Docker 与 CDK CLI。**Docker 必须带
BuildKit/buildx**：镜像资产声明了 `platform=linux/amd64`（`aws/stacks/executor_stack.py`），CDK 把它原样
传给 `docker build --platform`，而 CDK 文档对这个参数的要求就是 *Requires Docker Buildx*——
用 `DOCKER_BUILDKIT=0` 的老构建器会直接报错。在 Apple Silicon 上还需要 **amd64 仿真**（跨架构构建）。
Docker Desktop 两者都自带，装它就不用管这一条。失败方向是响亮的（构建报错、部署停在资产阶段），
不会静默产出一个架构不对的镜像。

```bash
set -euo pipefail
cd aws
cp config.example.yaml config.yaml          # 按 config.example.yaml 的注释填真实值（config.yaml 不进版本库）
cdk bootstrap aws://<账号>/<区域>             # 每个账号 + 区域一次
cdk deploy --all                            # CodeupKiroState → CodeupKiroExecutor → CodeupKiroDispatcher
```

`config.yaml` 在 `cdk synth` 阶段就被 `aws/config.py::load_config` 校验：区域不在九个有效区域内、必配键
（`org_id`、`bot_username`、三个摘要）缺失或格式不对、`inline_comment`/`review_command` 取值不严格是
`0`/`1`，都会直接报错并中止。`cdk.out/`、`cdk.context.json`（CDK 查询可用区时会连同账号 ID 一起写进去）
与安装包 zip 都已 gitignore——本仓库是公开仓库，不要把它们提交上去。

首次部署后照第 5.2 节登记真实镜像摘要，再部署一次 `CodeupKiroExecutor`。

### 6.4 在 Codeup 注册 webhook（部署后手动）

webhook 注册**不**自动化：Codeup 不是 AWS 服务，CDK 的 `AwsCustomResource` 调不到它的 OpenAPI，手写一个
自定义资源 Lambda 又是一块没有任何测试覆盖的生产代码。所以部署完成后手动接入。先读出入口地址：

```bash
aws cloudformation describe-stacks --region <区域> --stack-name CodeupKiroDispatcher \
  --query "Stacks[0].Outputs[?OutputKey=='WebhookUrl'].OutputValue" --output text
```

然后在**每个**要接入的业务库（一套部署服务多个仓库，都指向同一个地址）的 Codeup 设置 → Webhooks 里新建：

- URL：上面读出的 `WebhookUrl`（`https://<CloudFront 域名>/`）；
- Secret Token：`codeup-kiro/webhook-secret` 的值（调度器按 `X-Codeup-Token` 头常量时间比对，不符即 401）；
- 触发事件：勾选**合并请求事件**（`mergeRequestsEvents`）与**评论事件**（`noteEvents`）；
- SSL 校验：开启（`enableSslVerification: true`）。

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
| 评审被拒绝，日志/退出码指向「镜像摘要不在已探测名单内」（entrypoint 退出码 90） | 镜像重新构建过、但没有把新摘要登记进 `kiro_image_digests`（第 5.2 节；首次部署时名单里只有占位值，这是引导流程的正常一步）。核对日志里打印的摘要与名单是否一致 |
| 评审被拒绝，日志指向「读不到本容器镜像摘要」（entrypoint 退出码 90） | ECS 容器级元数据端点读取失败或返回形状变了。N1 门在读不到摘要时一律拒绝，不会放行；偶发时重新推送即可，持续出现时核对 P2a-04 记录的元数据形状 |
| 评审被拒绝，日志/退出码指向「clone 业务库失败」（entrypoint 退出码 91） | 云效令牌（`codeup-kiro/yunxiao-token-kiro`）过期或权限不足（需代码只读 + 合并请求读写）；执行器网络不通（VPC/子网/安全组配置，或出网路径）；业务库 URL/仓库权限本身有问题。三者从同一条报错信息区分不开，需要逐个排除 |
| 同一个 MR 短时间内被评审两次，或看到「抢锁」相关的提示（幂等锁 `ReviewLock` 表） | **预期行为，不是错误**：webhook 被重放，或 Codeup 的「批准」事件与「新建/更新」事件都触发了调度器。幂等锁按「仓库#MR#提交」这个键去重，重复请求会被挡在真正拉起 Fargate 任务之前 |
| MR 上出现调度器写的「评审未启动」类评论 | 调度器判定收到了合法请求，但 `RunTask` 本身被节流或调用失败——多为 Fargate 任务并发数/账号级限流，或任务定义/网络配置有误导致 `RunTask` 直接报错。这条评论意味着 Fargate 任务从未真正跑起来，评审引擎本身没有机会失败 |
| 评审任务确实异常结束了，MR 上却**没有**「兜底」类评论 | 兜底 Lambda 自己失败了。它取云效令牌（`codeup-kiro/yunxiao-token-kiro`）的方式与调度器相同，但**不打调度器那行固定格式的日志**（见下面 503 那一行）：取不到令牌时它直接抛 `SecretUnavailable`，所以 CloudWatch 里看到的是一条 traceback（末行 `SecretUnavailable: YUNXIAO_TOKEN_ID`，其上还会带原始 AWS 错误正文，该正文可能含角色 ARN 与账号 ID）。抛出是有意的：这是 EventBridge 的异步调用，抛出会走 Lambda 自己的重试，限流之类能自愈；吞掉才会变成真正的沉默。最常见的成因是兜底角色缺 `secretsmanager:GetSecretValue`。另外查 `Errors`/`Throttles` 指标与 EventBridge 规则是否匹配到了事件 |
| MR 上出现「兜底」类回写评论（评审没有正常结论，也没有评审引擎自己的失败原因） | 与上一条不同：`RunTask` 成功了，任务真的起来过，但没能跑到评审脚本自己汇报结果那一步就死掉了——常见原因是镜像拉取失败（registry 权限、镜像被删）、容器 OOM（`ephemeral_storage`/内存配置不够大 diff 的仓库）、或任务在 `KIRO_TIMEOUT` 之外的更外层超时（任务本身的运行时长上限）被杀。这条评论是任务级的兜底，不经过评审脚本自己的失败评论路径，所以看不到评审脚本给出的具体原因 |

| Codeup 的 webhook 投递记录显示 401 | Codeup 里填的 Secret Token 与 `codeup-kiro/webhook-secret` 的值不一致，或请求根本没带 `X-Codeup-Token` 头（没带令牌时调度器在取密钥之前就回 401）。**改密钥的值不需要重新部署**：两个 Lambda 的环境变量里只有密钥名，值在调用时取。但取到的值**按执行环境缓存且没有 TTL**，而 Lambda 不承诺执行环境的最长寿命——持续有流量时旧值可能存活数小时，没有任何保证的上限。要让新值立刻生效，改一次函数配置（任何无害改动）强制换执行环境 |
| Codeup 的 webhook 投递记录显示 503，正文 `secret-unavailable` | 调度器取不到它要的密钥：`codeup-kiro/webhook-secret`（校验 webhook 令牌用），或 `codeup-kiro/yunxiao-token-kiro`（在 MR 上留痕用的云效令牌，验签通过之后才取，所以只有带对令牌的投递才会碰到它）。这是 fail-closed 的显式响应（绝不放行），且**每次都会在调度 Lambda 的日志里留一行固定形状的记录**：`secret-unavailable var=WEBHOOK_SECRET_ID code=<代号>`，取不到云效令牌时同一行写 `var=YUNXIAO_TOKEN_ID`（按 `code=` 过滤定位成因，按 `var=` 定位是哪一个密钥）。代号只有固定几种，正是四类成因的区分：`env-unset`（环境变量没配或为空，几乎只会出现在手改过函数配置之后）、`empty-value`（密钥存在但值为空）、`ResourceNotFoundException`（密钥不存在或名字不符）、`AccessDeniedException`（Lambda 角色缺 `secretsmanager:GetSecretValue`）、`ThrottlingException`（Secrets Manager 限流）。日志里只有变量名与代号，不含密钥值、账号 ID 或 AWS 错误正文。**这次事件已经丢了，不会自己回来**：Codeup 对 503 的重投行为已实测（见下一行）——同一次投递在约 1 秒内一共来 3 次就不再来了，`ThrottlingException` 这种亚秒级抖动有机会在第 2/3 次自愈，而上面四类配置/权限成因在 1 秒内不可能修好。所以处置顺序是：按 `code=` 定位并修好配置，然后**主动重新触发**——往 MR 的源分支再推一次提交（`git commit --allow-empty` 也算）即可产生一次新投递。云效控制台的 webhook 页面是否提供「重新发送」按钮本轮没有核实，不要依赖它 |
| 同一个 `X-Codeup-Delivery` 的投递在日志里出现了 2~3 次 | **预期行为，不是错误**。实测的是 **503**（Task 1，只测了这一个状态码）：回 503 时 Codeup 立即重试，同一个 delivery id 在约 1 秒内最多到 3 次，之后不再重投（观察 10 分钟以上）。**其他非 2xx（404 / 502 / 504）是否同样重投没有测过**，所以不要把「最多 3 次」当成所有状态码的上界。幂等抢锁（`ReviewLock` 表，键是「仓库#MR#提交」）把这几次吸收掉，只有第一次能真正拉起 Fargate 任务；`X-Codeup-Delivery` 本身也可以当投递级去重的辅助键 |
| Codeup 的 webhook 投递记录显示 404 或连接超时，调度 Lambda 没有任何日志 | 请求没有到达 Lambda：方法不是 `POST`（监听器默认动作固定返回 404，只有 `POST` 转发给调度器），或 URL 填成了 ALB 域名（内网 ALB 从公网连不上，只能经 CloudFront 访问）——URL 必须是 `WebhookUrl` |
| Codeup 的 webhook 投递记录显示 502/504 | 502：调度 Lambda 抛了异常或返回了不完整的响应（查 Lambda 日志）；504：Lambda 超过 CloudFront 回源读超时（30 秒）仍未返回。两种情况下请求可能已被处理，Codeup 却记为失败。**Codeup 对 502/504 会不会重投没有实测过**（实测过的只有 503，见上面那一行），所以这里只能说：如果它重投，会被幂等锁挡住；如果它不重投，这次事件就丢了，得主动重新触发 |

「抢锁冲突」「评审未启动」「兜底回写」三行对应的代码已经实现（`aws/lambda/dispatcher/handler.py`、
`aws/lambda/backstop/handler.py`），但调度器接到 webhook 后走到抢锁这一步要等 Task 5 落地（见本文开头），
在那之前真实部署上复现不出这三类现象；落地后请对照真实日志核对措辞，不一致时以代码为准并更新本表。
