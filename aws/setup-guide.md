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
entrypoint（N1 镜像摘要门、clone、**检出 MR 的那个提交**、**按 MR 的租约**、调用评审脚本、「已回写」标记）、任务异常结束的兜底回写。

**调度链路已经接通**：合法的 webhook 会走完「校验共享密钥 → 事件过滤 → 幂等抢锁 → `RunTask`」并真的
拉起评审任务，`RunTask` 失败时释放锁并在 MR 上留痕。所以第 4.3 节「抢锁冲突」「评审未启动」「兜底回写」
三类现象在真实部署上都能复现。事件过滤的判据（与真实报文一一对应，见第 6.1 节的探测结论）：

- 事件头 `X-Codeup-Event` 为 `Merge Request Hook`、且 `state` 为 `opened` → 评审。「批准」（`accepted`）
  不评审；批准之后再推送会回到 `opened`，正常评审。只改标题这类 `action: update` 且
  `is_update_by_push: false` 的事件不评审（没有新代码）。
- 事件头为 `Note Hook`、`REVIEW_COMMAND=1`、评论正文含触发短语、不是系统评论、不是本方评论、且被评论的
  MR 既没合并也没关闭（`merge_request.state` 归一后不是 merged / closed）→ 评审。
- 其余事件类型与认不出形状的报文一律忽略（HTTP 200、正文 `ignored`），不猜。
- 报文里的取值还要过一道形状检查（clone 地址必须是 `https://codeup.aliyun.com/<组织 id>/…` 且不含
  `%`、提交 SHA 必须是 40 位小写十六进制、分支名不得以 `-` 开头、评论 id 必须是 32 位小写十六进制等）。
  不通过时忽略并留一行 `ignored reason=<代号>` 日志，代号见第 8 节。

**评论命令已按 spec 落地**：`REVIEW_COMMAND=1` 时，MR 上带触发短语的评论会通过过滤、抢锁（键里多一段
评论 id，所以同一个提交可以被重复触发）并拉起一次评审任务。除 `LOCK_KEY` 多一段评论 id 外，任务拿到的
环境变量与 MR 事件的完全一样，所以评审引擎照常跑完，并**原地更新它那条唯一的汇总评论**
（`run:N` 递增、历次表多一行）；找不到上一条、原地**更新失败**、或没配 `CODEUP_BOT_USERNAME` 时才新建
一条（见 `scripts/kiro-review.sh` 开头的「汇总评论生命周期」）。
spec 对这个功能的验收就是「一条评论触发重审，而它产生的评论不触发下一轮」——后半句靠 `<!-- kiro-`
标记断环（第 8 节「机器人评论触发新评审」那一行），不含「回复那条评论」，评审脚本也不需要知道自己是被评论触发的。
所以发出命令之后要看的是**原来那条汇总评论变了**（`run:N` 加一），不是多出一条新的。开关为 `1` 时，
汇总评论页脚那句「怎么重新评审」也会跟着变成「评论 `/kiro review` 可重新评审」（`REVIEW_RERUN_HINT`，
由 `config.yaml` 派生，见第 4.3 节）。

**同一 MR 串行（spec I6 ②）**：调度器的幂等锁按「仓库#MR#提交」去重，只挡得住**同一次**投递；同一 MR
连推两次（或推送与一条评论命令撞在一起）会各拉起一个任务。所以执行器在跑评审引擎之前先拿一把**按 MR 的
租约**——锁表里键为 `lease#<仓库 id>#<MR 编号>` 的一条记录，租期 120 秒、持有期间每 30 秒续期一次，持有者记
「抢锁键 + 本任务 ARN」（ARN 取自 ECS 任务级元数据端点，同一次投递万一起了两个任务也互斥）。评审引擎本身有总时长
上限 `KIRO_TIMEOUT` + 1800 秒（超时以退出码 124 结束，第 8 节），所以持有时长有上界；任务被强杀（StopTask、内存
不足）来不及释放时，租约最多 120 秒后自动失效。拿不到就每 10 秒
重试一次，同一 MR 同一时刻至多一次引擎运行；任务结束（含失败）时释放，且只释放自己持有的那一把。拿到之后
再用 `git ls-remote` 核对源分支的最新提交：若它已不是本任务的 `HEAD_SHA`、**且**调度器已经为它抢过锁，本任务
**安静退出**（退出码 0、不发评论，日志一行 `head-check result=superseded sha=<本任务短 sha> tip=<最新提交短 sha>`），
由那个新任务评审最新提交；新提交没有抢锁记录（那次投递丢了）或核对本身失败时，照常评审自己的提交。
等满 `KIRO_TIMEOUT` + 2400 秒仍拿不到时先再核对一次最新提交（已被取代就同样安静退出），否则与读写租约本身失败、
读不到本任务 ARN 一样，以退出码 93 拒绝（第 8 节）。续期持续失败两分钟以上（DynamoDB 不可用）时租约会过期、
被别人接管，那时两者并发——也就是加租约之前的行为，不会更糟。

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
授予目标业务库「代码只读 + 合并请求读写」（AWS 档位的执行器在 clone 之前还要用这个令牌调一次 GetRepository，按仓库 id 取 clone 地址），不给组织级管理员权限，令牌按周期轮换（调度器与兜底两个 Lambda 按执行环境缓存取到的令牌 5 分钟，轮换后最多 5 分钟用上新值；
要立刻生效，给**两个**函数各改一次函数配置，任何无害改动都会换执行环境。执行器每个任务启动时现取）。区别只在于
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
| `codeup-kiro/webhook-secret` | Lambda 调度器校验 Codeup webhook 共享密钥用（调度器在每次调用时按注入的 `WEBHOOK_SECRET_ID`——即这里的密钥名——向 Secrets Manager 取值，见 `aws/lambda/dispatcher/secret_fetch.py`）。**信任边界**：一个部署只有这一个共享密钥，填进每一个接入仓库的 webhook。持有它的人能伪造或重放投递，触发组织里云效令牌读得到的任何仓库的 MR 评审；但评审的内容总是来自 MR 所在的那个仓库：执行器按仓库 id 向 Codeup 取 clone 地址，报文里的地址只拿来比对（不一致时日志里有一行 `clone-url-mismatch`，见第 8 节「clone-url-mismatch」那一行）。所以只把它交给被信任拥有云效令牌读权限的人，其中有人离开时轮换它 | 是 |
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
  --secret-string '<随机生成的 ASCII 共享密钥（例如 openssl rand -hex 32 的输出），与 Codeup webhook 配置里填的值一致>'
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
- **云效令牌给 git 用的方式：按主机限定的 credential helper，经环境变量下发给所有子进程。**
  `aws/executor/entrypoint.sh` 在 clone 之前导出三个变量——`GIT_CONFIG_COUNT=1`、
  `GIT_CONFIG_KEY_0=credential.https://codeup.aliyun.com.helper`、`GIT_CONFIG_VALUE_0=<helper 程序>`。
  要点有三个，改动这一段之前请先读 `tests/test-aws-entrypoint.sh` 的 ⑭/⑮/⑯（都有断言守着）：
  - **令牌不在 argv、不在 URL、不进 `.git/config`**：git 这条路，`GIT_CONFIG_VALUE_0` 里存的是 helper 的
    **程序文本**，其中的 `$YUNXIAO_TOKEN` 未展开（entrypoint 里那行用的是单引号）；git 在真的需要凭证时
    才把这段交给 `sh -c` 执行，那时才从环境里读出令牌。curl 这条路（评审引擎调 Codeup API 的
    `scripts/lib/codeup-api.sh`，两个档位相同；执行器按仓库 id 查业务库地址的那一次请求同样如此），
    令牌由 `printf` 内建写进管道，curl 用 `-H @-` 从 stdin 读请求头。所以令牌值不出现在 git 或 curl 进程的 `/proc/<pid>/cmdline` 里，
    也不出现在 `GIT_CONFIG_*` 这几个变量里。环境里带着它的只有 `YUNXIAO_TOKEN` 这一个变量：ECS 从 Secrets Manager 注入，执行器的
    进程树（entrypoint、git、评审引擎）都继承它。所以同一容器里能读别的进程 `/proc` 的进程都读得到令牌；
    Kiro 模型进程不继承（见下面最后一条）。
  - **经环境变量而不是 `git -c`**：`-c` 只作用于执行器自己发起的那一次 git 调用，而评审引擎
    （`scripts/kiro-review.sh`，两个档位共用、不因 AWS 而改）自己还要在业务库里 `git fetch` 目标
    分支。环境变量会被所有子进程继承，一处下发即可——凭证只有这一个来源。
  - **按主机限定**（`credential.<url>.helper` 而不是 `credential.helper`）：全局 helper 对任何主机的
    凭证询问都会作答，一次重定向就足以把组织令牌交给别人。限定之后只有 `codeup.aliyun.com` 问得到。
  - 这三个变量**不会**进 Kiro 模型进程：kiro-cli 一律以固定许可清单的空环境启动（`kiro_env_exec`，清单取值经 fd 交给垫片，
    不进 timeout / kiro-cli 的命令行参数）
    （`scripts/lib/kiro-agent.sh` 的 `KIRO_ENV_FIXED_NAMES`，里面既没有 `GIT_CONFIG_*` 也没有
    `YUNXIAO_TOKEN`；逃生口 `KIRO_ENV_PASSTHROUGH` 另有 `YUNXIAO_*` 这条拒绝规则）。

## 4. 变量三分类

一套部署服务多个业务库，所以环境变量按「谁决定这个值」分三类：

### 4.1 调度器按 webhook 载荷逐次派生（每次运行不同）

| 变量 | 来源 |
|---|---|
| `CODEUP_REPO_ID` | webhook 载荷里的代码库 ID |
| 业务库 clone URL（`BUSINESS_REPO_URL`） | webhook 载荷（执行器只拿来与按仓库 id 查到的地址比对，不用它 clone；见第 8 节「clone-url-mismatch」那一行） |
| `MR_LOCAL_ID` | webhook 载荷里的 MR 编号 |
| `MR_TARGET_BRANCH` | webhook 载荷里的目标分支 |
| `CI_COMMIT_REF_NAME` | webhook 载荷里的源分支（`aws/executor/entrypoint.sh` 在跑任何网络 I/O 之前就要求 `CODEUP_REPO_ID`、`MR_LOCAL_ID`、`CI_COMMIT_REF_NAME`、`BUSINESS_REPO_URL`、`LOCK_KEY`、`HEAD_SHA` 这六项（`MR_TARGET_BRANCH` 可选，不在其中），缺一硬失败：前五项缺失退出码 1，`HEAD_SHA` 缺失退出码 92——与它形状不对、检出失败时同一个码，运维按码查 §8 一行即可） |
| `HEAD_SHA` | webhook 载荷里本次评审的提交。**执行器用它检出**：`git clone` 给的是仓库默认分支，而引擎从 `git rev-parse HEAD` 取「本次评审的提交」，所以 entrypoint 在 clone 之后 `git checkout -q --detach "$HEAD_SHA"`，并逐字核对检出后的 HEAD（不一致就以退出码 92 拒绝，避免静默评错提交）。**刻意是分离头指针、不建本地分支**：建 `refs/heads/<源分支名>` 时，源分支若叫 `origin/<目标分支>`（合法分支名）就会遮蔽 `refs/remotes/origin/<目标分支>`——git 解析短名字时 refs/heads 排在 refs/remotes 之前——于是引擎的 `git merge-base "origin/<目标分支>" HEAD` 退化成 HEAD、diff 为空、评审被「跳过」且不留任何评论（真 git 复现过）。分支名引擎取自 `CI_COMMIT_REF_NAME`，分离头指针不影响它。形状要求：40 位小写十六进制；与 `CI_COMMIT_REF_NAME` 一样在执行器侧**再查一次**（调度器已查过一次，这是第二道）。只供 entrypoint 使用，不导出给评审脚本（引擎只认 git 里的 HEAD） |
| `LOCK_KEY` | 调度器抢锁时写入的幂等锁键（仓库#MR#提交，评论命令再加评论 id），原样传给执行器——执行器置「已回写」标记、兜底 Lambda 读标记都只认它，不自己重建。只供 entrypoint 使用，不导出给评审脚本 |

### 4.2 部署级静态（同一部署下所有业务库共用，随 CDK 部署一次性配置）

| 变量 | 说明 |
|---|---|
| `YUNXIAO_ORG_ID` | 云效组织 ID |
| `CODEUP_BOT_USERNAME` | 机器人账号用户名（原地更新汇总评论、行内评论按作者去重的前提，同 Flow 档位） |
| `TZ` | 固定为 `CST-8`（北京时间，UTC+8；不是 `config.yaml` 的键）：评审评论里的时间格与 Flow 档位一致。用 POSIX 写法是为了不依赖时区数据库：基础镜像 `debian:stable-slim` 目前带着 tzdata（Debian 13 里它是 required 包），但写成 `Asia/Shanghai` 就把正确性押在它身上，哪天镜像里没有这份数据，glibc 会静默回落成 UTC |
| 部署区域 | 第 1.1 节的九选一，`aws/config.yaml` 的 `region` 字段；三个 stack 都钉到这个区域 |

`aws/config.yaml` 的**全部**键（含默认值与是否必配）列在 [aws/config.example.yaml](config.example.yaml)，
代码读取而示例里没写的键会让测试失败。注意 `bot_username`（单数，执行器用来原地更新汇总评论）与
`bot_usernames`（复数，调度器忽略哪些作者的评论，默认只含前者）是两个键。

**机器人与人是同一个账号只适合 PoC；生产部署用第 1.4 节要求的专用机器人账号。** 同号时有一个
只有专用账号才能消除的隐患：评审引擎（`scripts/`，两个档位共用、不因 AWS 而改）找「上一条汇总评论」
的判据是「作者等于 `CODEUP_BOT_USERNAME` **且**正文带 `<!-- kiro-review:<sha> run:N -->` 标记行」，
同号时作者那一半恒成立，判据退化成只看标记行。于是**你**发的任何一条带这种标记行的评论——复制或存档一份
汇总、引用它的 markdown 原文、照 N5 的做法复现断环测试——会在下一次评审时被当成汇总评论接管：内容被原地
覆盖、历次表从头记、`run` 取最大的那条，MR 上可能最终留下两条汇总（Task 14 验收实测过，Codeup-Demo
MR !4）。**恢复**：在下一次评审之前删掉那条评论（引擎跳过已删除的评论）；已经被接管的话，删掉重复的
那一条、只留一条。要测断环，用引擎接管不了的标记，例如 `<!-- kiro-test -->` 加命令短语：调度器按
`<!-- kiro-` 前缀忽略它（日志 `ignored reason=kiro-marker`），引擎只认完整的 `<!-- kiro-review:… run:N -->`
那一行。`bot_usernames: []` 时 `cdk synth` 会打一行警告提醒这件事。

PoC 里机器人与人确实是同一个账号时，**把 `bot_usernames` 设成 `[]`**。云效上完全可以用一个账号既当机器人又当人
（Task 1 在真实 demo 里实测到：Flow 档位那条评审评论的作者就是 MR 作者本人）。这种部署下默认名单
`[bot_username]` 会把**人自己发的** `/kiro review` 当成本方评论忽略掉——评论命令静默失效，日志里一行都
没有，是最难查的那类故障。处置：在 `config.yaml` 里显式写

```yaml
bot_usernames: []          # 机器人与人同号：名单留空，断环交给 `<!-- kiro-` 标记那道守卫
```

显式的 `[]` 会原样生效（不会回落成默认名单），进到调度 Lambda 的 `BOT_USERNAMES` 就是空字符串，
运行时解析成空名单。**不要**写成 `bot_usernames:`（空值）——那在 YAML 里是 `null` 而不是空列表，
`cdk synth` 会直接报错并提示改成 `[]`。名单留空不会带来自触发循环：断环真正承重的是「正文含
`<!-- kiro-` 标记的评论一律忽略」那一道（第 8 节「机器人评论触发新评审」那一行的第 ② 道），本方写出去的每一种评论都带这个前缀。
代价除了那一道守卫本来的代价（人在评论里原样贴出这类标记时，那条评论里的触发短语也会被忽略），
还有上面说的「人发的评论被当成汇总接管」——后者只有专用账号能消除。

### 4.3 行为开关

执行器的开关与评审行为变量由 `config.yaml` 写进任务定义的容器环境（默认值与 `scripts/` 里的缺省值
逐项一致，有测试比对）；取值语义归共享评审引擎（`scripts/`），与 Flow 档位同一套规则，详见
`pipeline/setup-guide.md` 第 11.2 节，本档位不改这些语义。**唯一一个刻意与引擎缺省值不同的是
`REVIEW_RERUN_HINT`**（见下表最后一行）：引擎的缺省值是 Flow 语义的「重跑流水线」，本档位没有流水线。

| 变量 | `config.yaml` 键 | 说明 |
|---|---|---|
| `INLINE_COMMENT` | `inline_comment` | 是否发行内评论，只收 `0`/`1`（`config.py` 在 synth 时就拒绝别的取值，包括 YAML 里未加引号的 `yes`/`true`） |
| `INLINE_PROFILE` | `inline_profile` | 行内档位：`quiet`（默认）/ `balanced` / `critical`，**不是** 0/1 布尔值 |
| `MAX_INLINE_COMMENTS` | `max_inline_comments` | 单次行内评论上限，非负整数，默认 `10` |
| `KIRO_TIMEOUT` | `kiro_timeout` | Kiro 超时秒数，默认 `900`，只收纯数字 |
| `DIFF_SIZE_LIMIT` | `diff_size_limit` | diff 直传阈值字节数，默认 `307200`，只收纯数字 |
| `MAX_COMMENT_BYTES` | `max_comment_bytes` | 单条评论字节上限，默认 `60000` |
| `TARGET_BRANCH_FILTER` | `target_branch_filter` | 调度器：目标分支正则，空 = 全部 MR。**已生效**：非空时只有目标分支匹配这个正则的 MR 事件与评论命令才被受理，不匹配的一律忽略（HTTP 200、正文 `ignored`，不拉起任务）。用的是 Python `re.search`（部分匹配），要锚定请自己写 `^`/`$`。正则编译不过时 **fail closed**：不评审，并在调度 Lambda 日志里留一行 `bad-target-branch-filter var=TARGET_BRANCH_FILTER`（日志里不回显正则本身）——配错时是「一条都不评」而不是「全评」 |
| `REVIEW_COMMAND` / `REVIEW_COMMAND_PHRASE` | `review_command` / `command_phrase` | 调度器：评论命令开关（`0`/`1`）与触发短语（默认 `/kiro review`）。**已按 spec 落地**：开关为 `1` 时，MR 上正文含这句短语的评论会拉起一次评审（锁键里多一段评论 id，所以同一个提交可以被重复触发）；开关为 `0` 时 Note Hook 一律忽略。结果**以原地更新的那条汇总评论呈现**（`run:N` 递增）；找不到上一条、原地**更新失败**、或没配 `CODEUP_BOT_USERNAME` 时才新建一条。spec 的验收不含「回复那条评论」，脚本也不知道自己是被评论触发的。开关为 `1` 时页脚的 `REVIEW_RERUN_HINT` 会跟着改成这句短语（见下一行）。已合并/已关闭的 MR 上的命令不受理（日志 `ignored reason=mr-not-open`，见第 8 节）——判据 `merged` / `closed` 两个取值来自云效文档，**没有实测过**，实际取值不同时这类命令会照常评审。短语为空串时 fail closed（一律不受理），否则「空串是任何正文的子串」会让每条评论都触发评审。**短语不要配成会出现在本方评论里的词**（例如 `Kiro 代码评审`）：本方评论靠 `<!-- kiro-` 标记断环，不靠短语，但把短语配成常见词会让任何转述都触发评审 |
| `REVIEW_RERUN_HINT` | （派生值，**不是** `config.yaml` 的键） | 汇总评论页脚与降级评论里那句「怎么重新评审」。本档位按上一行那两个键自动派生，不用手配：`review_command: 1` 且短语非空 → ``评论 `<短语>` 可重新评审``（用的就是 `command_phrase` 的取值，不是写死的 `/kiro review`）；`review_command: 0`，或短语被显式写成空串（那时调度器一条命令都不受理）→ `向源分支推送新提交可重新评审`。共享引擎的默认值是 Flow 语义的「重跑流水线可重新评审」，而**本档位没有流水线**——不设这个变量就等于每条汇总评论都在教读者做一件做不到的事。取值会经引擎清洗再折成单行（本地实测：反引号与中文原样保留，`<!--` 转义成 `&lt;!--`，换行折成空格），所以短语里带反引号只会让那对反引号显示得难看，伪造不出评审标记 |

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

不只是升级 kiro-cli：镜像构建上下文里**任何东西**变了都会换摘要——评审引擎 `scripts/`、提示词 `prompts/`、
受信 agent 定义 `kiro/`、`aws/executor/entrypoint.sh`（见 `aws/executor/Dockerfile` 的 `COPY`）。所以升级本集成包
（哪怕只改了引擎里的一行）同样要走上面第 2、3 步：不登记就 `exit 90`，所有评审被拒、MR 上是兜底的「评审未完成」。
旧摘要先留在名单里：回滚到上一版时它还能直接用。

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
| 评审被拒绝，日志/退出码指向「clone 业务库失败」（entrypoint 退出码 91） | 云效令牌（`codeup-kiro/yunxiao-token-kiro`）过期或权限不足（需代码只读 + 合并请求读写）；执行器网络不通（VPC/子网/安全组配置，或出网路径）；业务库 URL/仓库权限本身有问题。三者从这条固定消息本身区分不开；消息下面紧跟着最多 5 行以 `git: ` 开头的日志，是 git 自己报错的尾巴（`Authentication failed` 多半是令牌，`Could not resolve host` / `timed out` 多半是网络，`not found` 多半是地址或权限），按它缩小范围。这几行只进容器日志、不进 MR 评论；令牌不会出现在里面（git 不打印 helper 给的密码），URL 里的 userinfo 也会被抹成 `<redacted>`。**退出码 91 还有另一个成因，日志形状不同**：`业务库地址的主机不是 codeup.aliyun.com，拒绝 clone`——执行器在 clone 之前自己再查一次主机（深度防御，调度器的形状检查已经挡过一次）。走到这里说明调度器那道被绕过、或两处的组织/地址口径不一致；此时先查 `YUNXIAO_ORG_ID` 与报文里的 `repository.git_http_url`，并考虑轮换 webhook 共享密钥。日志里**不回显地址**（它是外部可控的，可能带令牌）。注意 clone 成功**不代表**后续 git 操作也有凭证：凭证是经 `GIT_CONFIG_*` 环境变量下发给所有子进程的（第 3 节最后一条），本表「无法 fetch 目标分支」那一行就是这一段被改坏时的现象。**clone 之前还有一步（issue 01）**：执行器按 `CODEUP_REPO_ID` 向 Codeup OpenAPI 取这个仓库的 clone 地址（GetRepository 的 `httpUrlToRepo`），只 clone 这个地址。这一步的四条消息：「按仓库 id 查不到业务库（云效令牌权限、网络、Codeup 限流或仓库 id）」下面紧跟一行以 `curl: ` 开头的报错：`curl: (22) The requested URL returned error: 429` 是 Codeup 限流（已退避重试过，稍后重新推送），401 / 403 是令牌没有读这个仓库的权限，404 是仓库 id 不存在或令牌看不到它，5xx 是 Codeup 自己出错，连接超时之类是到 openapi-rdc.aliyuncs.com 的网络不通；「按仓库 id 查到的业务库地址缺失、仓库 id 不符或形状不对」是 Codeup 返回的形状变了（地址不在本组织前缀下、不以 `.git` 结尾、带 `@` `?` `#` `%` `..` 或空白）。API 响应不进日志，要核对就用同一个令牌在本机 `curl` 一次 GetRepository（`/oapi/v1/codeup/organizations/<组织 ID>/repositories/<仓库 id>`），看 `id` 与 `httpUrlToRepo`；「CODEUP_REPO_ID 形状不对（必须全是数字）」与「YUNXIAO_ORG_ID 没配或形状不对」是调度器口径变了或任务定义被手改过 |
| 日志里有 `clone-url-mismatch` | **不是错误，执行器照常评审**：报文里的业务库地址（`repository.git_http_url`）与按仓库 id 查到的不一致，clone 的是按仓库 id 查到的那个地址，所以评审内容总是来自 MR 所在的仓库。两种成因：仓库刚改名、报文还带着旧路径（偶发，随即消失）；或者有人拿着 webhook 共享密钥在改报文。持续出现时先在本机比对两个地址（报文的 `git_http_url` 与 GetRepository 的 `httpUrlToRepo`）：只是写法不同（平台口径变了），报给集成包维护方；报文确实被改过，按第 3 节轮换那个密钥。日志里不回显两个地址（报文是外部可控的） |
| 日志里有 `git: Codeup 限流（HTTP 429），N 秒后重试` | Codeup 对 git HTTP 限流。执行器（clone、补取源分支、`git ls-remote`）与评审引擎（取目标分支、浅克隆加深历史）遇到 429 都会自动退避重试（10、20、40 秒，最多 4 次），只重试 429、别的失败不重试。提示行在哪儿看得到：引擎取目标分支时直接打进任务日志；执行器自己的 clone / 补取源分支只在最后仍失败时随 `git:` 报错尾巴一起打出，重试成功时不留痕；`ls-remote` 与加深历史的重试不打提示。最后仍失败时，clone 那一步见本表「clone 业务库失败」那一行、引擎那一步报「无法 fetch 目标分支」，`ls-remote` 失败则按 `head-check result=unknown` 照常评审。多为同一组织短时间内 git 请求太多（多个 MR 同时推送、批量重跑）；稍后重新推送或发评论命令即可 |
| 评审被拒绝，日志指向「缺少 HEAD_SHA」「检出 MR 的提交失败」或「HEAD 与 HEAD_SHA 不一致」（entrypoint 退出码 92） | 执行器在 clone 之后要把工作树检出到 `HEAD_SHA`（`git clone` 只给仓库默认分支）。另有一种出现在任何网络 I/O 之前：日志是「缺少 HEAD_SHA」——调度器没把 `HEAD_SHA` 传进来（多为手工 `RunTask` 或改过调度器），与形状不对同一个码，是为了运维按码查表只查这一行。其余三类成因：① `HEAD_SHA` / `CI_COMMIT_REF_NAME` / `MR_TARGET_BRANCH` 形状不对（分别要求 40 位小写十六进制、非空且不以 `-` 开头、不含空白或控制字符；目标分支是可选的，非空时与源分支同一套规则）——调度器已经查过同样的规则，走到这里说明两处口径不一致或调度器那道被绕过；② 那个提交在业务库里找不到——源分支被强推改写、评审排队期间源分支已被删，或那次「补取源分支」本身没成功（git 不接受这个 ref 名，例如 `HEAD`、`a..b`、含 `~^:`、以 `.lock` 结尾）。前两种重新推送即可；最后一种要改分支名；③ 检出成功但 HEAD 与 `HEAD_SHA` 不一致（只会出现在有人改动这段检出逻辑之后）。检出失败时下面同样紧跟 `git: ` 开头的几行 git 报错；「补取源分支失败」这一行也带一段（目标分支执行器不再单独取，issue 03；取不到时是引擎报「无法 fetch 目标分支」）。日志**不回显取值**（分支名是 MR 作者可控的不受信取值）。**这一步以前不存在**，当时的现象是评审静默地评了默认分支：汇总评论的 `Commit:` 与标记里的短 sha 是默认分支的头而不是 MR 的头（真实运行实测，Task 14 验收）——升级后若再看到这种现象，先确认执行器镜像是不是旧的 |
| 评审被拒绝，日志指向「等待同一 MR 的上一次评审超过 N 秒仍未结束，拒绝评审」、「读写 MR 租约失败（code=<代号>），拒绝评审」或「读不到本任务的 ARN（ECS 任务级元数据端点），无法确定租约持有者，拒绝评审」（entrypoint 退出码 93） | 执行器拿不到按 MR 的租约（开头「同一 MR 串行」一段）。**前一种**：等满 `KIRO_TIMEOUT` + 2400 秒（引擎总时长上限 + 600），租约一直被同一 MR 的别的任务占着。单独一个任务挡不了这么久（引擎有总时长上限，被强杀的任务租约 120 秒后失效），所以多半是同一 MR 短时间内连推了好几次、排队的任务轮流拿走了租约（已被取代的排队任务到上限时会安静退出、打 `head-check result=superseded`，不走这一行）。等最新那次评审结束后，重新推送或发评论命令即可。**后一种**：租约那条 DynamoDB 请求本身失败，`code=` 是 AWS 错误码：`AccessDeniedException`（任务角色缺 `dynamodb:UpdateItem` / `dynamodb:GetItem`，多见于升级后没重新部署 `CodeupKiroExecutor`）、`ResourceNotFoundException`（`LOCK_TABLE` 指错了表）、`ProvisionedThroughputExceededException` / `ThrottlingException`（限流），`unknown`（没有错误码，多为连不上 DynamoDB 端点）。**第三种**：执行器读不到 ECS 任务级元数据端点（`${ECS_CONTAINER_METADATA_URI_V4}/task`）或那里的 `TaskARN` 形状不对，就无从确定租约持有者是不是自己；Fargate 平台版本 1.4.0 起都有这个端点，偶发多为元数据服务的瞬时故障，重新推送即可；每次都出现时核对任务的平台版本。三种情况都 fail closed：不确定有没有别的任务正在评这个 MR 时不评。兜底 Lambda 会在 MR 上回写「评审未完成（退出码 93）」 |
| 评审被终止，日志里有「评审引擎超过总时长上限 N 秒仍未结束，已终止」（entrypoint 退出码 124；引擎 30 秒内不理 TERM 时是 137） | 评审引擎跑满了总时长上限 `KIRO_TIMEOUT` + 1800 秒（开头「同一 MR 串行」一段）。Kiro 对话本身已受 `KIRO_TIMEOUT` 限制，所以多半是引擎自己的 `git fetch` 或 Codeup API 长时间没有应答（跨境网络、Codeup 限流）。上限同时给持有租约的时长与这个任务的 Fargate 费用设了上界。兜底 Lambda 会在 MR 上回写「评审任务异常结束（退出码 124）」；重新推送或发评论命令即可，频繁出现时查执行器到 codeup.aliyun.com 的网络。137 而**没有**这行消息的是内存不足（OOM）之类，不是上限；143 是任务被 StopTask 停掉（租约照样释放了） |
| 某次推送没有对应的评审，日志里有 `head-check result=superseded` | **预期行为，不是错误**：这个任务等租约期间源分支又被推过，调度器也已为最新提交拉起了任务，所以它退出 0、不评审也不发评论，由新任务评最新提交（汇总评论里的 `Commit:` 是最新的那个）。这一行其余几种取值：`result=current`（最新提交就是本任务的，照常评审）、`result=moved-unclaimed`（源分支前进了，但新提交没有抢锁记录——那次投递丢了——照常评审本任务的提交）、`result=unknown`（`git ls-remote` 失败或源分支已不存在，照常评审）、`result=claim-unknown`（读新提交的抢锁记录失败，照常评审）。后三种是退化路径：与加租约之前的行为相同 |
| 装机、摘要、自检、版本门全过，评审在生成 diff 那一步失败：`[kiro-review] 错误：无法 fetch 目标分支：<分支>`，日志里还有 `fatal: could not read Username for 'https://codeup.aliyun.com'` | **执行器的 git 凭证没有传给评审引擎。** 引擎（`scripts/kiro-review.sh` 第 4 步）会自己在业务库里 `git fetch` 目标分支、必要时再 `git fetch --unshallow`——Flow 档位由平台检出业务库并留下可用凭证，AWS 档位得由执行器提供。真实 Fargate 运行实测过这个坑（Task 14 验收）：当时 helper 只作为 `git -c` 传给执行器自己那两次调用，引擎那次 fetch 因此是无凭证的。**修法**：凭证必须经 `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` 导出（第 3 节最后一条），环境变量才会被引擎这个子进程继承。核对办法：`bash tests/test-aws-entrypoint.sh` 的 ⑯ 用真 git 的 `credential fill` 判这件事。若这三个变量确实在位而现象依旧，再查令牌本身（与本表「clone 业务库失败」那一行同一批成因） |
| 同一个 MR 短时间内被评审两次，或看到「抢锁」相关的提示（幂等锁 `ReviewLock` 表） | **预期行为，不是错误**：每次推送、每条评论命令各是一次评审，两次推送离得很近时就会看到两次。它们**依次**进行、不会同时跑——执行器先拿按 MR 的租约（开头「同一 MR 串行」一段），后到的任务等前一个结束；拿到租约时源分支已经又前进了的话，旧任务直接退出、只评最新的提交（见本表「某次推送没有对应的评审」那一行）。同一次投递被重放（Codeup 对 503 的立即重投、有人重放报文）则由幂等锁按「仓库#MR#提交」去重，挡在真正拉起 Fargate 任务之前 |
| MR 上出现调度器写的「评审未启动」类评论 | 调度器判定收到了合法请求，但 `RunTask` 本身被节流或调用失败——多为 Fargate 任务并发数/账号级限流，或任务定义/网络配置有误导致 `RunTask` 直接报错。这条评论通常意味着 Fargate 任务从未真正跑起来，评审引擎本身没有机会失败。**例外**：原因是 `ReadTimeoutError` / `ConnectTimeoutError` 这类超时时，`RunTask` 的两次尝试都没等到应答，任务却可能已经起了（ECS 按 SDK 自动生成的 clientToken 去重，所以最多一个）——先等几分钟看评审是否照常出现，再决定要不要重新触发；真重新触发了也只是同一 MR 先后评两次，不会并发。**`RunTask` 失败了、MR 上却没有这条评论**时，查调度 Lambda 日志里那一行 `cleanup-failed step=comment reason=<代号>`（最多一行：这一步要先取云效令牌再发评论，缓存 5 分钟内免取；两步合起来卡到函数的 29 秒超时时连这一行都没有，只有平台为这次调用打的 `REPORT` 行，末尾是 `Status: timeout`（sandbox 实测：09-28 兜底超时的日志就是这样，没有单独的 `Task timed out` 行））：`cleanup-failed step=comment reason=PostFailed` 是 Codeup 拒收或连不上（多为云效令牌过期或被吊销的 401）；`cleanup-failed step=comment reason=SecretUnavailable:<代号>` 是这一步才取的云效令牌 `codeup-kiro/yunxiao-token-kiro` 取不到，`<代号>` 与 503 那一行的 `code=` 同一套（见本表「Codeup 的 webhook 投递记录显示 503」那一行）；`ConnectionResetError`、`TimeoutError` 之类是连上 Codeup 之后断开或卡住。修好成因之后重新推送或发评论命令即可 |
| 评审任务确实异常结束了，MR 上却**没有**兜底评论 | 兜底 Lambda 自己失败了。它取云效令牌（`codeup-kiro/yunxiao-token-kiro`）用的是与调度器同一份 `secret_fetch`，但**不打固定格式的代号日志**：取不到令牌时它直接抛 `SecretUnavailable`，CloudWatch 里是一条以 `[ERROR] SecretUnavailable: YUNXIAO_TOKEN_ID` 开头的错误记录（Lambda Python 运行时的格式，按运行时源码，本部署还没有真实样本）。原始 AWS 错误挂在 `__cause__` 上，这条记录不打它，所以从这里看不出是权限还是限流：服务端拒绝（权限、限流、密钥不存在）时查 CloudTrail 里兜底角色的 `GetSecretValue` 事件的 `errorCode`；超时或连不上 Secrets Manager 时 CloudTrail 里没有这次调用，看同一次调用的 `REPORT` 行是不是 `Status: timeout`。评论发不出去时同样抛出、不会当成功：HTTP 非 2xx（如令牌被吊销的 401）与连不上时抛 `PostFailed`（错误记录以 `[ERROR] PostFailed: post-comment` 开头），日志多一行 `backstop step=post-comment result=failed`；连上之后读超时、连接被重置或对方不应答就断开时，抛的是原始异常（`TimeoutError` / `ConnectionResetError` / `RemoteDisconnected`），没有 `result=failed` 那一行。抛出是有意的：这是 EventBridge 的异步调用，Lambda 会再重试 2 次，限流之类能自愈；重试耗尽的事件**不会被丢掉**，而是进 `BackstopFailures` 队列并触发告警（见本表「收到兜底告警」那一行）。兜底每一次出站调用之前打一行 `backstop step=read-mark` / `backstop step=fetch-token` / `backstop step=post-comment`，超时时日志里最后一行就是卡住的那一步。最后一行是 `backstop step=post-comment` 时多为到 openapi-rdc.aliyuncs.com 的跨境链路卡住：发评论那一步只有每次 socket 操作 10 秒的超时（域名解析出几个地址，连接就按地址各算一次）、没有整体截止时间，可能吃满函数的 29 秒；这时照样是重试、耗尽后进队列。最常见的成因是兜底角色缺 `secretsmanager:GetSecretValue`。另外查 `Errors`/`Throttles` 指标与 EventBridge 规则是否匹配到了事件 |
| 收到兜底告警（`BackstopFailuresAlarm`、`BackstopErrorsAlarm` 或 `BackstopDeliveryFailuresAlarm`） | **订阅**：三个告警都通知部署输出 `BackstopAlarmTopicArn` 那个 SNS 主题，部署后订阅一次：`aws sns subscribe --topic-arn <BackstopAlarmTopicArn> --protocol email --notification-endpoint <运维邮箱>`，再点确认邮件里的链接（告警动作写在 CDK 里，别在控制台手加——下一次 `cdk deploy` 会把手加的覆盖掉）。`BackstopErrorsAlarm` 只说明兜底抛过异常，Lambda 会自己重试，先看它的日志（见本表「MR 上却没有兜底评论」那一行）。`BackstopDeliveryFailuresAlarm` 说明重试耗尽的事件**连队列都没进去**：Lambda 往 `BackstopFailures` 投递失败（队列被删、队列策略被改、兜底角色少了 `sqs:SendMessage`），这时队列告警不会响，也没有可重放的消息，受影响的是哪几个 MR 从告警本身看不出来。先查队列是否还在、兜底角色的策略里是否还有 `sqs:SendMessage`，修好投递之后再请近期推送过的 MR 作者重新推送。`BackstopFailuresAlarm` 说明重试耗尽了：**有 MR 缺一条「评审未完成」评论**，事件在部署输出 `BackstopFailuresQueueUrl` 那个队列里保留 14 天。告警只在从「正常」变成「告警」的那一刻通知**一次**：队列里还有消息期间新到的失败不会再发邮件，所以每次都要把队列**清空**：重复下面三步，直到 `aws sqs get-queue-attributes --queue-url <BackstopFailuresQueueUrl> --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible` 的两个值连续几分钟都是 0（两个都是近似值；`receive-message` 返回空不算数：不带 `--wait-time-seconds` 的短轮询在队列里还有消息时也可能返回空）。补发不成功的消息留在队列里，告警就一直停在告警状态、之后的新失败都不会再通知：要么修好成因把它补发掉，要么确认那个 MR 已经另行处理之后手工删掉它。告警回到正常之后，下一次失败才会再通知。**重放**：先按日志修好成因（多为令牌或网络），再逐条取出、同步调用兜底、确认后删除——`aws sqs receive-message --queue-url <BackstopFailuresQueueUrl> --max-number-of-messages 1 --visibility-timeout 300 --wait-time-seconds 20 > msg.json`；`jq '.Messages[0].Body \| fromjson \| .requestPayload' msg.json > event.json`（队列里存的是 Lambda 的调用记录，`requestPayload` 才是原始的 ECS 事件，`requestContext.condition` 是 `RetriesExhausted` 或 `EventAgeExceeded`）；`aws lambda invoke --function-name <BackstopFunctionName> --payload fileb://event.json out.json`，`out.json` 是 `{"ok": true, "posted": true}` 才算补发成功（`"posted": false` 表示评审脚本其实已经回写过、无需补发）；最后 `aws sqs delete-message --queue-url <BackstopFailuresQueueUrl> --receipt-handle "$(jq -r '.Messages[0].ReceiptHandle' msg.json)"`。同步调用不经重试也不进队列。**函数自己失败时 `aws lambda invoke` 照样退出 0**：失败只体现在命令输出的 `"FunctionError": "Unhandled"` 与 `out.json` 里的 `errorType`（如 `PostFailed`、`SecretUnavailable`），所以只按 `out.json` 判、**不要**用 `&&` 把 invoke 与 delete-message 串起来；不是 `{"ok": true, …}` 时不删，消息留在队列里等下次 |
| MR 上出现「兜底」类回写评论（评审没有正常结论，也没有评审引擎自己的失败原因） | 与本表「MR 上却没有兜底评论」那一行不同：`RunTask` 成功了，任务真的起来过，但没能跑到评审脚本自己汇报结果那一步就死掉了——常见原因是镜像拉取失败（registry 权限、镜像被删）、容器 OOM（`ephemeral_storage`/内存配置不够大 diff 的仓库）、或任务在 `KIRO_TIMEOUT` 之外的更外层超时（任务本身的运行时长上限）被杀。这条评论是任务级的兜底，不经过评审脚本自己的失败评论路径，所以看不到评审脚本给出的具体原因。评论里写着容器的退出码：90 / 91 / 92 / 93 是 entrypoint 自己在评审脚本启动之前拒绝的（评论里各有一句成因），按本表标着那个退出码的行排查；「没有退出码」多半是容器根本没启动（例如拉取镜像失败）；评论说「ECS 事件里有多个容器、没有一个名字对得上评审容器」时，是任务定义里加了别的容器、评审容器的名字又对不上，按任务定义核对容器名 |
| 投递返回 200，正文 `ignored`，但没有任何评审任务被拉起 | 调度器**受理了但按设计忽略了**这次事件。常见且正常的原因：事件类型不是 `Merge Request Hook` / `Note Hook`；MR 的 `state` 不是 `opened`（批准、合并、关闭都在这一类）；`action: update` 且 `is_update_by_push: false`（只改了标题之类，没有新代码）；目标分支不匹配 `TARGET_BRANCH_FILTER`；Note Hook 但 `REVIEW_COMMAND=0`、正文没有触发短语、是系统评论、或是本方评论。这些**都不留日志**（否则正常流量会把真正的信号淹掉）。想确认是哪一类，先按上面几条对照报文 |
| 投递返回 200 `ignored`，且日志里有一行 `ignored reason=<代号>` | 除 `mr-not-open`、`kiro-marker`、`missing-field` 与 `org-unset` 这四个之外，都是**报文里的取值没过形状检查**——那不是正常流量，要么有人拿着 webhook 共享密钥在改报文（该密钥可重放、无正文绑定，所以它只能证明「是我们的 webhook」），要么 Codeup 的报文格式变了。代号是固定枚举：`clone-url-prefix`（clone 地址不是 `https://codeup.aliyun.com/<组织 id>/…`——主机或组织 id 不对）、`clone-url-chars`（地址里有 `@`、`?`、`#`、`%`、`..`、空白或控制字符；`%` 整条拒绝，因为字面量 `..` 挡不住百分号编码的写法，而真实报文的 clone 地址里从来没有 `%`）、`head-sha`（提交 SHA 不是 40 位小写十六进制）、`repo-id` / `mr-local-id`（不是纯数字）、`branch`（分支名为空、以 `-` 开头，或含空白/控制字符）、`note-biz-id`（评论命令的那个评论 id 缺失、为空，或不是 32 位小写十六进制——它会原样进锁键，而锁键是容器环境变量与 DynamoDB 主键；缺了就无法去重，宁可不评）、`missing-field`（本该评审的 MR 事件或评论命令缺了必需字段：项目 id、MR 编号、源/目标分支、`last_commit.id`、clone 地址之一，或者取值不是标量。只在本该评审的事件上判，批准、改标题、没有命令短语的普通评论不会打这一行；出现就说明 Codeup 的报文格式变了或有人在改报文，每一次评审都会这样静默停掉）、`kiro-marker`（评论正文带 `<!-- kiro-` 开头的本方标记，断环守卫把它忽略了——本方写出去的评论每次评审都会打一两行，属**正常流量**；若是**人**发的命令被吞掉，见本表「机器人评论触发新评审」那一行与第 4.2 节：机器人与人同号时人不要在评论里贴这类标记）、`org-unset`（`YUNXIAO_ORG_ID` 没配好——这一个是我们自己的配置问题）、`mr-not-open`（**正常流量**：有人在已经合并或已关闭的 MR 上发了触发短语，此时不受理；报文形状是**先**过完检查才判这一条的，所以伪造报文顺手多带一个已合并状态并不能把形状告警降级成这一条；只挡云效文档列出的这两个取值——它们**只见于云效文档、没有实测过**（真实投递里只见过 opened 这一个取值），若实际取值不同，这类命令会照常评审）。日志里只有代号，**不回显报文里的任何取值**（那是外部可控的自由文本，回显等于把它打进日志，还可能把 `https://oauth2:<令牌>@…` 里的令牌一起带进去）。处置：`mr-not-open` 与本方评论的 `kiro-marker` 无需处置（在还没结束的 MR 上重发命令即可）；`missing-field` 先对照 Codeup 最新的 webhook 报文格式；`org-unset` 查函数配置；其余先确认这次投递是不是真的来自云效，再考虑轮换共享密钥 |
| 担心「机器人评论触发新评审」的死循环 | 不会发生，两道防线：① 作者用户名在 `BOT_USERNAMES` 名单里的评论一律忽略；② **正文含 `<!-- kiro-` 开头的 HTML 注释标记的评论一律忽略**。第二道是承重的那道——本方机器人与人**可以是同一个账号**（Task 1 在真实 demo 里实测到：Flow 档位的评审评论作者就是 MR 作者本人），那时名单要么没有这个人（断不了环）、要么有（连人发的命令一起吞掉）。本方写出去的每一种评论都带 `<!-- kiro-` 前缀的标记：评审汇总 `kiro-review:`、发布随机串 `kiro-review-post:`、历次记录 `kiro-history:`、行内评论 `kiro-inline:`、调度器的「评审未启动」`kiro-dispatch-failed`、兜底的「评审未完成」`kiro-backstop`。被这道守卫忽略的评论留一行 `ignored reason=kiro-marker`。代价有两个：① 人在评论里原样贴出这类标记时，那条评论里的触发短语也会被忽略；② **机器人与人同号时**（只适合 PoC，见第 4.2 节），人发的带 `<!-- kiro-review:<sha> run:N -->` 标记行的评论会在下一次评审时被引擎当成汇总评论接管（内容被覆盖、MR 上可能留下两条汇总；Task 14 验收实测过）——在下一次评审之前删掉那条评论即可恢复，已被接管就删掉重复的那一条。生产用专用机器人账号就没有这个问题 |
| Codeup 的 webhook 投递记录显示 401 | Codeup 里填的 Secret Token 与 `codeup-kiro/webhook-secret` 的值不一致，或请求根本没带 `X-Codeup-Token` 头（没带令牌时调度器在取密钥之前就回 401）。**改密钥的值不需要重新部署**：两个 Lambda 的环境变量里只有密钥名，值在调用时取。但取到的值**按执行环境缓存 5 分钟**（`aws/lambda/dispatcher/secret_fetch.py` 的 `CACHE_TTL_SECONDS`）：改了值之后最多 5 分钟，调度器就会用上新值（这个密钥只有调度器读）。要让新值立刻生效，给调度器函数改一次函数配置（任何无害改动都会换执行环境）。云效令牌的缓存与轮换见第 1.4 节 |
| Codeup 的 webhook 投递记录显示 503，正文 `secret-unavailable` | 调度器取不到校验 webhook 令牌用的共享密钥 `codeup-kiro/webhook-secret`。云效令牌不会造成 503：调度器只在拉起任务失败、要发「评审未启动」评论时才取它（见本表「评审未启动」那一行）。这是 fail-closed 的显式响应（绝不放行），且**每次都会在调度 Lambda 的日志里留一行固定形状的记录**：`secret-unavailable var=WEBHOOK_SECRET_ID code=<代号>`（按 `code=` 过滤定位成因）。代号是 AWS 错误码或异常类型名（不是封闭的集合），常见的几种：`env-unset`（环境变量没配或为空，几乎只会出现在手改过函数配置之后）、`empty-value`（密钥存在但值为空）、`ResourceNotFoundException`（密钥不存在或名字不符）、`AccessDeniedException`（Lambda 角色缺 `secretsmanager:GetSecretValue`）、`ThrottlingException`（Secrets Manager 限流）、`ReadTimeoutError` / `ConnectTimeoutError` / `EndpointConnectionError`（调用卡住或连不上 Secrets Manager 端点）。取密钥的客户端带有界超时（连接 2 秒、读 5 秒、最多 2 次，单次最坏约 15 秒，见 `aws/lambda/dispatcher/bounded_config.py`），所以卡住时这一行照样会在函数 29 秒超时之前打出来，响应仍是 503。日志里只有变量名与代号，不含密钥值、账号 ID 或 AWS 错误正文。**这次事件已经丢了，不会自己回来**：Codeup 对 503 的重投行为已实测（见本表「Codeup 重投同一次投递」那一行）——同一次投递在约 1 秒内一共来 3 次就不再来了，`ThrottlingException` 这种亚秒级抖动有机会在第 2/3 次自愈，而上面四类配置/权限成因在 1 秒内不可能修好。所以处置顺序是：按 `code=` 定位并修好配置，然后**主动重新触发**——往 MR 的源分支再推一次提交（`git commit --allow-empty` 也算）即可产生一次新投递。云效控制台的 webhook 页面是否提供「重新发送」按钮本轮没有核实，不要依赖它 |
| Codeup 重投同一次投递：投递记录里同一次投递重试了，调度 Lambda 在约 1 秒内被调用 2~3 次（Lambda 日志里的 `REPORT` 行；我们部署的代码不记录 `X-Codeup-Delivery`，日志里按它是查不到的） | **预期行为，不是错误**。实测的是 **503**（Task 1，只测了这一个状态码）：回 503 时 Codeup 立即重试，同一个 delivery id 在约 1 秒内最多到 3 次，之后不再重投（观察 10 分钟以上）。**其他非 2xx（404 / 502 / 504）是否同样重投没有测过**，所以不要把「最多 3 次」当成所有状态码的上界。幂等抢锁（`ReviewLock` 表，键是「仓库#MR#提交」）把这几次吸收掉，只有过了验签与取密钥、抢到锁的那一次能拉起 Fargate 任务（回 503 的那几次根本没走到抢锁）；`X-Codeup-Delivery` 本身也可以当投递级去重的辅助键 |
| Codeup 的 webhook 投递记录显示 404 或连接超时，调度 Lambda 没有任何日志 | 请求没有到达 Lambda：方法不是 `POST`（监听器默认动作固定返回 404，只有 `POST` 转发给调度器），或 URL 填成了 ALB 域名（内网 ALB 从公网连不上，只能经 CloudFront 访问）——URL 必须是 `WebhookUrl` |
| Codeup 的 webhook 投递记录显示 502/504 | 502：调度 Lambda 抛了异常或返回了不完整的响应（查 Lambda 日志）；504：Lambda 超过 CloudFront 回源读超时（30 秒）仍未返回。两种情况下请求可能已被处理，Codeup 却记为失败。**Codeup 对 502/504 会不会重投没有实测过**（实测过的只有 503，见本表「Codeup 重投同一次投递」那一行），所以这里只能说：如果它不重投，这次事件就丢了；如果它重投，而 502 之前抢锁那一步已经写进去了（比如写入的应答丢了、重试又被限流），重投会被幂等锁当成重复挡住——**这次事件同样丢了**，那条抢锁记录 24 小时后才过期。两种情况都不会自己恢复，得主动重新触发（重新推送，或发一条评论命令） |

「抢锁冲突」「评审未启动」「兜底回写」三行对应的代码都已实现且已接到 webhook 入口上
（`aws/lambda/dispatcher/handler.py`、`aws/lambda/backstop/handler.py`），真实部署上这三类现象都能复现。
本表的措辞按代码写，真实日志与它不一致时以代码为准并更新本表。
