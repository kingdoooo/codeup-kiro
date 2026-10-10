import os

import aws_cdk as cdk
from aws_cdk import (
    aws_ec2 as ec2,
    aws_ecr_assets as ecr_assets,
    aws_ecs as ecs,
    aws_iam as iam,
    aws_logs as logs,
    aws_s3 as s3,
    aws_secretsmanager as secretsmanager,
    aws_securityagent as securityagent,
)
from constructs import Construct

from config import DEFAULT_COMMAND_PHRASE, PHRASE_DEFAULTS, feishu_notify_on
from stacks.egress import EgressLockdown

# aws/executor/Dockerfile 的构建上下文是仓库根（COPY scripts/ prompts/ kiro/ 都是相对仓库根的路径），
# 这里必须给出同一个根，否则 DockerImageAsset 的目录内容与 Dockerfile 里的 COPY 源路径对不上。
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# 页脚与降级评论里那句「怎么重新评审」（REVIEW_RERUN_HINT，共享引擎渲染，见
# scripts/lib/review-render.sh::_review_rerun_hint）。**必须由本档位设置**：引擎的默认值是 Flow 语义
# 的「重跑流水线可重新评审」，而 AWS 档位根本没有流水线——不设就是每条汇总评论末尾都教读者做一件
# 做不到的事（pipeline/setup-guide.md 第 11.2 节那张表也把本档位列为要改这个变量的一方）。
RERUN_HINT_PUSH = "向源分支推送新提交可重新评审"
# 失败评论里那句「去哪看日志」（REVIEW_LOG_HINT，issue 06，scripts/lib/review-render.sh::review_log_hint）同理必须由本档位设置：
# 引擎的默认值是「请查看流水线日志（构建号 N）或重跑流水线。」。流前缀要与下面 review 容器日志驱动的 stream_prefix 一致（有测试比对）。
LOG_HINT = "执行器日志在 CloudWatch（执行器日志组，流前缀 executor/）。"


def rerun_hint(cfg):
    """按 config.yaml 推出这句提示语。

    只有「评论命令真的会被受理」时才承诺评论命令：开关为 1 **且**短语非空。短语被显式写成空串时
    调度器是 fail closed 的（handler.py 的 `if not phrase`），此时承诺评论命令就是假承诺，
    所以回落到推送语义——这一条比「照着开关直译」更重要，页脚是读者唯一的操作指引。
    短语原样嵌进反引号：取值会经引擎的 `_review_sanitize_oneline` 清洗（本地实测：反引号与中文原样
    保留，`<!--` 被转义成 `&lt;!--`，换行折成空格），所以这里不自己再加一层转义。
    """
    phrase = str(cfg.get("command_phrase", DEFAULT_COMMAND_PHRASE) or "")
    if cfg.get("review_command", 0) == 1 and phrase:
        return f"评论 `{phrase}` 可重新评审"
    return RERUN_HINT_PUSH

def scanner_rerun_hint(cfg, phrase_key):
    """扫描员页脚那句「怎么重新评审」：与 rerun_hint 同一规则（开关为 1 且这一句短语非空才承诺评论命令）。"""
    phrase = str(cfg.get(phrase_key, PHRASE_DEFAULTS[phrase_key]) or "")
    if cfg.get("review_command", 0) == 1 and phrase:
        return f"评论 `{phrase}` 可重新评审"
    return RERUN_HINT_PUSH


def scanners_on(cfg):
    """启用了的扫描员（按 reviewers 的固定顺序）。开关按 `type(v) is int` 读（True == 1 的坑，见 config.default_bot_usernames）。"""
    out = []
    for rid, toggle in (("inspector", "inspector"), ("security", "security_agent")):
        v = cfg.get(toggle)
        if type(v) is int and v == 1:
            out.append(rid)
    return out


# 评审行为变量：config.yaml 键 → (容器环境变量名, 缺省值)。缺省值与 scripts/ 里的 `${VAR:-默认}`
# 逐项一致（tests/test_cdk_assertions.py 读脚本比对），写进任务定义是为了让取值在任务定义里看得见，
# 而不是隐含在脚本里。取值语义归共享评审引擎，本档位不另做校验（与 Flow 档位同一套规则）；
# 唯一例外是 max_comment_bytes：它也进扫描任务，开了扫描员时 config.py 按扫描入口的规则校验（针对性复审 M-3）。
BEHAVIOUR_VARS = {
    "inline_profile": ("INLINE_PROFILE", "quiet"),
    "max_inline_comments": ("MAX_INLINE_COMMENTS", 10),
    "kiro_timeout": ("KIRO_TIMEOUT", 900),
    "diff_size_limit": ("DIFF_SIZE_LIMIT", 307200),
    "max_comment_bytes": ("MAX_COMMENT_BYTES", 60000),
}


class ExecutorStack(cdk.Stack):
    """Fargate 执行器：ECS Cluster + 任务定义 + 执行器镜像资产。

    调度器用 assignPublicIp=ENABLED 拉起任务（见 lambda/dispatcher/handler.py::run_task），
    所以这里的子网必须是公有子网，不建 NAT——没有出网需求要靠 NAT 转发的理由。

    同一个 VPC 另有两个隔离子网（无 NAT、无 IGW 路由），只放 webhook 入口的内网 ALB
    （stacks/ingress.py，spec「入口修订」G1）。VPC origin 要求 VPC 挂着 IGW——公有子网已提供。
    """

    def __init__(self, scope: Construct, cid: str, *, cfg: dict, state, **kw):
        super().__init__(scope, cid, **kw)

        ephemeral_gib = cfg.get("ephemeral_storage_gib", 25)
        if ephemeral_gib <= 20:
            raise ValueError(
                f"ephemeral_storage_gib={ephemeral_gib} 未超过 20 GiB 默认值："
                "业务库完整副本 + 归档在默认额度下容易撑爆临时存储，必须显式调大")

        # 出站形态（Phase 2c 阶段二，issue 19）：public = 任务在公有子网、分配公网 IP、直连 IGW（2b 的形状）；nat = 任务在私有子网、不分配
        # 公网 IP、经一个 NAT 网关出站（约 $32/月 + $0.045/GB）——VPC Block Public Access 会拦住公有子网经 IGW 的出站，NAT 网关是它下面
        # 最便宜的合规出站（ingress-only 模式放行 NAT 网关的出站，VPC 文档 security-vpc-bpa）。私有子网组**排在最后**：CDK 按
        # subnet_configuration 的顺序分 CIDR，排在中间会改掉已有子网的 CIDR、替换它们（ALB 与 VPC origin 跟着重建）。一个 NAT 网关放在
        # 第一个公有子网，两个私有子网都经它出站（跨可用区的那一份流量另有少量费用）。
        nat = cfg.get("egress_mode", "public") == "nat"
        subnet_groups = [
            ec2.SubnetConfiguration(
                name="public", subnet_type=ec2.SubnetType.PUBLIC, cidr_mask=24),
            ec2.SubnetConfiguration(
                name="isolated", subnet_type=ec2.SubnetType.PRIVATE_ISOLATED, cidr_mask=24),
        ]
        if nat:
            subnet_groups.append(ec2.SubnetConfiguration(
                name="private", subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS, cidr_mask=24))
        self.vpc = ec2.Vpc(
            self, "Vpc", max_azs=2, nat_gateways=1 if nat else 0,
            subnet_configuration=subnet_groups,
        )
        # 两个任务（执行器、扫描任务）落在哪些子网、要不要公网 IP：调度器（app.py 传给 DispatcherStack）与执行器派发扫描任务都用这一对
        self.task_subnets = self.vpc.private_subnets if nat else self.vpc.public_subnets
        self.assign_public_ip = "DISABLED" if nat else "ENABLED"
        if nat:
            # 改回 public 要两步（setup-guide 第 6.8 节）：先只部署调度器栈、让它改为导入公有子网的 id——这要求本栈此时仍导出它们
            # （名字与 public 形态下自动生成的导出相同）；否则执行器栈去掉私有子网时，它们的导出还被调度器导入着，CloudFormation 拒绝删除
            for subnet in self.vpc.public_subnets:
                self.export_value(subnet.subnet_id)

        self.cluster = ecs.Cluster(
            self, "Cluster", vpc=self.vpc,
            container_insights_v2=ecs.ContainerInsights.ENABLED)

        # 任务本身不监听任何入站端口（只是拉起来跑一次评审就退出），出站需要访问
        # Codeup/云效 API、Kiro API、Secrets Manager、DynamoDB——保留默认放行出站，不加入站规则。
        # description 必须是 ASCII——EC2 SecurityGroupDescription 的校验正则不接受中文，
        # cdk synth 会把这个当模板校验警告打出来（本任务实测踩到过，见任务报告）。
        # 出站限制（Phase 2c 阶段二，issue 19，egress_lockdown: 1）：不再全放行，只放 TCP 443（规则在 stacks/egress.py 里加）。
        # 描述**不跟着改**：EC2 安全组的描述一改就是替换（新的安全组 id），调度器经跨栈导入的 id 也随之变——卡在导出上
        lockdown = cfg.get("egress_lockdown", 0) == 1
        self.task_security_group = ec2.SecurityGroup(
            self, "TaskSg", vpc=self.vpc,
            description="Kiro review Fargate task: no inbound, default-allow outbound",
            allow_all_outbound=not lockdown,
        )

        image_asset = ecr_assets.DockerImageAsset(
            self, "ExecutorImage",
            directory=REPO_ROOT,
            file="aws/executor/Dockerfile",
            # platform 必须显式写死：CDK 的缺省是「构建机当前平台」
            # （cloud_assembly_schema: "Default: - current machine platform"），于是在 Apple Silicon
            # 上 synth/deploy 会产出 linux/arm64 的镜像，Fargate 侧（X86_64）拉取时直接
            # TaskFailedToStart：`CannotPullContainerError: … image Manifest does not contain
            # descriptor matching platform 'linux/amd64'`（Task 1 真实探测踩到）。
            # 构建机的架构绝不允许泄进镜像。另外烤进镜像的是 kirocli-x86_64-linux-musl，
            # 本身就只有 x86_64 一种，arm64 在这两件事上都是错的。
            platform=ecr_assets.Platform.LINUX_AMD64,
            # 不排除的话 CDK 分阶段 staging 会把整个仓库根（含 aws/cdk.out/、aws/.venv/、.git/）
            # 当成构建上下文原样拷贝一份——cdk.out 又刚好在仓库根之内，前一次 synth 留下的
            # cdk.out 会被下一次 synth 递归拷进新的 cdk.out，实测直接拷出 ENAMETOOLONG。
            # Dockerfile 只 COPY scripts/ prompts/ kiro/ aws/executor/ 这几处，其余都不需要。
            # aws/config.yaml 与 aws/cdk.context.json 也必须排除：它们在两次部署之间会变（手册 5.2 的
            # 摘要引导就是改 config.yaml 再部署），留在上下文里会改变资产哈希、触发重新构建，
            # 刚登记进 kiro_image_digests 的摘要随即对应的是上一个镜像。
            exclude=["aws/cdk.out", "aws/.venv", ".git", "**/__pycache__", "**/*.pyc",
                     ".pytest_cache", ".scratch", "docs/blog", "docs/superpowers",
                     "aws/config.yaml", "aws/cdk.context.json"],
        )

        log_group = logs.LogGroup(
            self, "ExecutorLogs",
            retention=logs.RetentionDays.ONE_MONTH,
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )

        # 任务角色只给 dynamodb:UpdateItem + GetItem 与写日志。UpdateItem：entrypoint.sh 收尾时写
        # 「已回写」标记，以及按 MR 的租约（拿租约是条件 upsert、释放是条件更新，都是 UpdateItem）；
        # GetItem：拿到租约后查「源分支最新提交」有没有调度器的抢锁记录（spec I6 ②）。
        # 不用 grant_read_write_data，那会连 PutItem/DeleteItem/Query/Scan 都给上，超出这个角色实际要做的事。
        self.task_role = iam.Role(
            self, "TaskRole", assumed_by=iam.ServicePrincipal("ecs-tasks.amazonaws.com"))

        kiro_api_key = secretsmanager.Secret.from_secret_name_v2(
            self, "KiroApiKeySecret", "codeup-kiro/kiro-api-key")
        yunxiao_token = secretsmanager.Secret.from_secret_name_v2(
            self, "YunxiaoTokenForExecutor", "codeup-kiro/yunxiao-token-kiro")

        self.task_definition = ecs.FargateTaskDefinition(
            self, "TaskDef",
            cpu=cfg.get("cpu", 2048),
            memory_limit_mib=cfg.get("memory_mib", 8192),
            ephemeral_storage_gib=ephemeral_gib,
            task_role=self.task_role,
            # 与镜像资产的 platform 成对写死。Fargate 的 runtime_platform 缺省是 X86_64/LINUX，
            # 但「缺省恰好对」和「显式声明」不是一回事：这一对值必须在同一次改动里一起看见，
            # 否则谁把镜像改成 arm64 时不会注意到任务定义还停在 X86_64（或反之），
            # 表现就是任务起不来而模板本身毫无异样。
            runtime_platform=ecs.RuntimePlatform(
                cpu_architecture=ecs.CpuArchitecture.X86_64,
                operating_system_family=ecs.OperatingSystemFamily.LINUX,
            ),
        )

        self.container_name = cfg.get("container_name", "review")
        self.container = self.task_definition.add_container(
            self.container_name,
            container_name=self.container_name,
            image=ecs.ContainerImage.from_docker_image_asset(image_asset),
            logging=ecs.LogDrivers.aws_logs(stream_prefix="executor", log_group=log_group),
            # PID 1 = init（tini，issue 15）：没有它时入口 bash 是 PID 1，内核对 PID 1 上没有处理函数的 SIGTERM 一律忽略，
            # StopTask 只能等 30 秒后的 SIGKILL（EXIT 陷阱不跑、租约靠到期失效；Task 13 验收 5a 实测）
            linux_parameters=ecs.LinuxParameters(self, "ExecutorLinuxParameters", init_process_enabled=True),
            # KIRO_IMAGE_DIGESTS/KIRO_PINNED_ARTIFACT_SHA256/KIRO_CLI_SHA256 刻意不从
            # image_asset 的内容哈希派生——ADR-0006 明确这三个值必须由「使用方环境」声明，
            # 集成包/CDK 自己填等于自己出题自己判。真正的镜像摘要要在构建、推送之后由操作者
            # 读出来（setup-guide 第 5.2 节），写进 config.yaml 再重新部署这一层。
            # 三个都是必配、无默认（load_config 校验），这里用 cfg[...]，不给空串兜底。
            environment={
                "KIRO_IMAGE_DIGESTS": cfg["kiro_image_digests"],
                "KIRO_PINNED_ARTIFACT_SHA256": cfg["kiro_pinned_artifact_sha256"],
                "KIRO_CLI_SHA256": cfg["kiro_cli_sha256"],
                "YUNXIAO_ORG_ID": cfg["org_id"],
                "CODEUP_BOT_USERNAME": cfg["bot_username"],
                "LOCK_TABLE": state.lock_table.table_name,
                "AWS_REGION": cfg["region"],
                # 评论里的时间格与 Flow 档位一致用北京时间（issue 05 E1）。POSIX 写法，不靠时区数据库：
                # 基础镜像目前带 tzdata，但写 Asia/Shanghai 就依赖它，没有时 glibc 静默回落成 UTC。
                # 中国没有夏令时，CST-8 就是 UTC+8。
                "TZ": "CST-8",
                # 开关与行为变量必须真的进容器：config.py 校验通过、却从没传给评审脚本的开关，
                # 表现就是「配对了也不生效」且毫无报错（I2）。
                "INLINE_COMMENT": str(cfg["inline_comment"]),
                # 派生值，不是 config.yaml 的键（见 rerun_hint 的 docstring）
                "REVIEW_RERUN_HINT": rerun_hint(cfg),
                "REVIEW_LOG_HINT": LOG_HINT,
                **{var: str(cfg.get(key, default))
                   for key, (var, default) in BEHAVIOUR_VARS.items()},
                # 飞书通知（Phase 2c issue 20）：只是一个开关——执行器据此记下本次 Kiro 评论的 id（lib/notify-mark.sh）。飞书凭证不进任何任务（N-F1）；
                # 开关为 0 时不写这个变量，任务定义与不开时逐字节相同
                **({"FEISHU_NOTIFY": "1"} if feishu_notify_on(cfg) else {}),
            },
            secrets={
                "KIRO_API_KEY": ecs.Secret.from_secrets_manager(kiro_api_key),
                "YUNXIAO_TOKEN": ecs.Secret.from_secrets_manager(yunxiao_token),
            },
        )

        state.lock_table.grant(self.task_role, "dynamodb:UpdateItem", "dynamodb:GetItem")
        # add_container 已经通过 LogDrivers.aws_logs 把 CreateLogStream/PutLogEvents 授给了
        # execution_role；这里再显式给任务角色同一组权限——本任务的环境契约明确写了
        # 「任务角色需要 dynamodb:UpdateItem 与 logs」（租约之后多一个 GetItem），两个角色都持有虽有重叠但各自都是最小授权
        # （都只scope 到这一个日志组），不是通配符。
        log_group.grant_write(self.task_role)

        # ── Phase 2b：扫描任务（Task B）与输入桶。任一扫描开关为 1 才存在（I7：都为 0 时模板与 2a 相同）──
        self.scan_task_definition = None
        self.scan_bucket = None
        scanners = scanners_on(cfg)
        if scanners:
            self._add_scan_task(cfg, state, image_asset, log_group, scanners)
        if lockdown:
            # 映射表只有 Security Agent 用：不开 SA 时不写进终端节点策略（否则 StateStack 多一个只有这里导入的导出，关掉出站限制时卡住）
            EgressLockdown(
                self, "EgressLockdown", vpc=self.vpc, task_subnets=self.task_subnets,
                security_group=self.task_security_group, scan_bucket=self.scan_bucket,
                tables=[state.lock_table] + ([state.mapping_table] if "security" in scanners else []),
                scanners=scanners, dns_action=cfg.get("egress_dns_action", "alert"))

    def _add_scan_task(self, cfg, state, image_asset, log_group, scanners):
        account = cdk.Aws.ACCOUNT_ID
        # 输入桶（spec S3）：名字由 CloudFormation 生成（不可预测——AWS 安全公告 2026-105 的抢注教训）；公共访问全挡、
        # BucketOwnerEnforced、只许 TLS、SSE-S3；按前缀的生命周期：inspector/ 1 天（SBOM）、security/ 7 天（ADR-0003 的归档）。
        # RETAIN：里面可能有客户源码的归档，删栈不该顺手删数据（与两张表、日志组同一策略；删不删由运维决定）。
        self.scan_bucket = s3.Bucket(
            self, "ScanInputs",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            encryption=s3.BucketEncryption.S3_MANAGED,
            enforce_ssl=True,
            object_ownership=s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
            removal_policy=cdk.RemovalPolicy.RETAIN,
            lifecycle_rules=[
                s3.LifecycleRule(id="inspector-1d", prefix="inspector/", expiration=cdk.Duration.days(1)),
                s3.LifecycleRule(id="security-7d", prefix="security/", expiration=cdk.Duration.days(7)),
            ],
        )
        prefixes = [f"{rid}/" for rid in scanners]

        self.scan_task_role = iam.Role(
            self, "ScanTaskRole", assumed_by=iam.ServicePrincipal("ecs-tasks.amazonaws.com"))
        # 扫描任务的密钥只有启用了的扫描员各自的云效令牌（S2）；**没有** Kiro API Key 与 Kiro 的令牌
        scan_secrets = {}
        if "inspector" in scanners:
            scan_secrets["YUNXIAO_TOKEN_INSPECTOR"] = ecs.Secret.from_secrets_manager(
                secretsmanager.Secret.from_secret_name_v2(
                    self, "YunxiaoTokenInspector", "codeup-kiro/yunxiao-token-inspector"))
        if "security" in scanners:
            scan_secrets["YUNXIAO_TOKEN_SECURITY"] = ecs.Secret.from_secrets_manager(
                secretsmanager.Secret.from_secret_name_v2(
                    self, "YunxiaoTokenSecurity", "codeup-kiro/yunxiao-token-security"))

        self.scan_task_definition = ecs.FargateTaskDefinition(
            self, "ScanTaskDef",
            cpu=cfg.get("scan_cpu", 512),
            memory_limit_mib=cfg.get("scan_memory_mib", 1024),
            task_role=self.scan_task_role,
            runtime_platform=ecs.RuntimePlatform(
                cpu_architecture=ecs.CpuArchitecture.X86_64,
                operating_system_family=ecs.OperatingSystemFamily.LINUX,
            ),
        )
        self.scan_container_name = "scan"
        self.scan_task_definition.add_container(
            self.scan_container_name,
            container_name=self.scan_container_name,
            # 同一个镜像资产（R2）：一份已探测摘要名单、一次摘要引导；只换启动命令
            image=ecs.ContainerImage.from_docker_image_asset(image_asset),
            entry_point=["/bin/bash", "-p", "/opt/integration/scan-entrypoint.sh"],
            logging=ecs.LogDrivers.aws_logs(stream_prefix="scan", log_group=log_group),
            # 同上（issue 15）；扫描入口收到 TERM 后再转给各扫描员子进程（init 只转给它的直接子进程）
            linux_parameters=ecs.LinuxParameters(self, "ScanLinuxParameters", init_process_enabled=True),
            environment={
                "KIRO_IMAGE_DIGESTS": cfg["kiro_image_digests"],
                "YUNXIAO_ORG_ID": cfg["org_id"],
                "LOCK_TABLE": state.lock_table.table_name,
                "AWS_REGION": cfg["region"],
                "TZ": "CST-8",
                "MAX_COMMENT_BYTES": str(cfg.get("max_comment_bytes", 60000)),
                "SCAN_BUCKET": self.scan_bucket.bucket_name,
                "SCAN_BUCKET_OWNER": account,
                "INSPECTOR_BOT_USERNAME": cfg.get("inspector_bot_username", cfg["bot_username"]),
                "SECURITY_BOT_USERNAME": cfg.get("security_bot_username", cfg["bot_username"]),
                "INSPECTOR_RERUN_HINT": scanner_rerun_hint(cfg, "inspector_command_phrase"),
                "SECURITY_RERUN_HINT": scanner_rerun_hint(cfg, "security_command_phrase"),
                "INSPECTOR_MAX_SCAN_CALLS": str(cfg.get("inspector_max_scan_calls", 3)),
                # 飞书通知的开关（同执行器那一处）：扫描员据此记下本次评论的 id（aws/reviewers/lib/summary.sh）
                **({"FEISHU_NOTIFY": "1"} if feishu_notify_on(cfg) else {}),
            },
            secrets=scan_secrets,
        )
        self.agent_space = None
        if "security" in scanners:
            self._add_security_agent(cfg, state)
        state.lock_table.grant(self.scan_task_role, "dynamodb:UpdateItem", "dynamodb:GetItem")
        log_group.grant_write(self.scan_task_role)
        self.scan_task_role.add_to_policy(iam.PolicyStatement(
            actions=["s3:GetObject"],
            resources=[self.scan_bucket.arn_for_objects(f"{p}*") for p in prefixes]))
        if "inspector" in scanners:
            # ScanSbom 不支持资源级授权（docs：Resource "*"）；Inspector 不需要在账号里启用
            self.scan_task_role.add_to_policy(iam.PolicyStatement(
                actions=["inspector-scan:ScanSbom"], resources=["*"]))

        # 执行器（Task A）这一侧：只写自己那几个前缀、只能拉起这一个扫描任务定义、只能把那两个角色交给 ECS
        self.task_role.add_to_policy(iam.PolicyStatement(
            actions=["s3:PutObject"],
            resources=[self.scan_bucket.arn_for_objects(f"{p}*") for p in prefixes]))
        self.task_role.add_to_policy(iam.PolicyStatement(
            actions=["ecs:RunTask"],
            resources=[f"arn:{cdk.Aws.PARTITION}:ecs:{cdk.Aws.REGION}:{account}"
                       f":task-definition/{self.scan_task_definition.family}:*"],
            conditions={"ArnEquals": {"ecs:cluster": self.cluster.cluster_arn}}))
        self.task_role.add_to_policy(iam.PolicyStatement(
            actions=["iam:PassRole"],
            resources=[self.scan_task_role.role_arn, self.scan_task_definition.execution_role.role_arn],
            conditions={"StringEquals": {"iam:PassedToService": "ecs-tasks.amazonaws.com"}}))
        for name, value in (
                ("INSPECTOR", str(cfg.get("inspector", 0))),
                ("SECURITY_AGENT", str(cfg.get("security_agent", 0))),
                ("SCAN_CLUSTER", self.cluster.cluster_name),
                ("SCAN_TASK_DEFINITION", self.scan_task_definition.family),
                ("SCAN_CONTAINER_NAME", self.scan_container_name),
                ("SCAN_SUBNETS", ",".join(s.subnet_id for s in self.task_subnets)),
                ("SCAN_SECURITY_GROUPS", self.task_security_group.security_group_id),
                ("SCAN_BUCKET", self.scan_bucket.bucket_name),
                ("SCAN_BUCKET_OWNER", account)):
            self.container.add_environment(name, value)
        # NAT 形态才写（public 形态与 2b 逐字节相同；没设 = ENABLED，lib/scan-dispatch.sh）
        if self.assign_public_ip != "ENABLED":
            self.container.add_environment("SCAN_ASSIGN_PUBLIC_IP", self.assign_public_ip)

    # Security Agent 的 Agent Space、服务角色、扫描任务这一侧的权限（spec「Security Agent 评审员 · CDK」，issue 10）。
    # Agent Space 名字不带 codeup-kiro/ 前缀的密钥能匹配上的形状：控制台给服务角色生成的 base policy 允许读 secret:<Space 名>*，
    # Space 若叫 codeup-kiro，这个形状就会覆盖 codeup-kiro/kiro-api-key 与各个云效令牌——本部署干脆不给服务角色任何 secretsmanager 权限
    # （SA 的代码评审不读密钥；那条只为渗透测试与集成）。不建 Application（R13：它只是 SA Web 控制台的配置，API 差分扫描用不到）。
    SA_SPACE_NAME = "codeup-kiro-security"
    # 扫描任务（Task B）调 SA 的动作白名单（I2：只读评审员——没有 StartCodeRemediation、UpdateFinding、BatchDeleteCodeReviews）
    SA_TASK_ACTIONS = ("securityagent:CreateCodeReview", "securityagent:UpdateCodeReview", "securityagent:ListCodeReviews",
                       "securityagent:StartCodeReviewJob", "securityagent:StopCodeReviewJob",
                       "securityagent:BatchGetCodeReviewJobs", "securityagent:ListCodeReviewJobsForCodeReview",
                       "securityagent:ListFindings", "securityagent:BatchGetFindings")

    def _add_security_agent(self, cfg, state):
        account, region, partition = cdk.Aws.ACCOUNT_ID, cdk.Aws.REGION, cdk.Aws.PARTITION
        # 服务角色：SA 扮演它读输入桶里的归档与 .patch、写自己的作业日志。信任按文档（create-iam-role.html）加混淆代理两道条件。
        self.sa_service_role = iam.Role(
            self, "SecurityAgentServiceRole",
            description="codeup-kiro Security Agent service role: read the security/ prefix of the scan bucket, write job logs",
            assumed_by=iam.ServicePrincipal("securityagent.amazonaws.com", conditions={
                "StringEquals": {"aws:SourceAccount": account},
                "ArnLike": {"aws:SourceArn": f"arn:{partition}:securityagent:{region}:{account}:agent-space/*"}}))
        role = self.sa_service_role
        # 控制台 base policy 里的两项自检（10-04 探测的 CloudTrail：没有它们时 SA 的 iam:GetRole / SimulatePrincipalPolicy 被拒）
        role.add_to_policy(iam.PolicyStatement(
            actions=["iam:GetRole", "iam:SimulatePrincipalPolicy"], resources=[role.role_arn]))
        logs_arn = f"arn:{partition}:logs:{region}:{account}:log-group:/aws/securityagent/{self.SA_SPACE_NAME}*"
        own_account = {"StringEquals": {"aws:ResourceAccount": account}}
        role.add_to_policy(iam.PolicyStatement(
            actions=["logs:CreateLogGroup"], resources=[logs_arn], conditions=own_account))
        role.add_to_policy(iam.PolicyStatement(
            actions=["logs:CreateLogStream", "logs:PutLogEvents"], resources=[f"{logs_arn}:log-stream:*"],
            conditions=own_account))
        # S3：读对象只限 security/（spec S3：Inspector 的 SBOM 不在它可读范围内）。列桶不限前缀：sandbox 实测（2026-10-08 Task 9）
        # 带 s3:prefix=security/* 条件时 CreateCodeReview 报「Access denied to source code S3 object」，IAM 模拟器里不带前缀的
        # ListBucket 是 implicitDeny；探测时跑通的服务角色就是这样列桶的。代价：SA 能列出 inspector/ 下的键名（看不到内容）
        role.add_to_policy(iam.PolicyStatement(
            actions=["s3:GetObject"], resources=[self.scan_bucket.arn_for_objects("security/*")], conditions=own_account))
        role.add_to_policy(iam.PolicyStatement(
            actions=["s3:ListBucket"], resources=[self.scan_bucket.bucket_arn], conditions=own_account))

        self.agent_space = securityagent.CfnAgentSpace(
            self, "AgentSpace",
            name=self.SA_SPACE_NAME,
            description="codeup-kiro: Security Agent differential code review of Codeup merge requests (managed by CDK)",
            aws_resources=securityagent.CfnAgentSpace.AWSResourcesProperty(
                iam_roles=[role.role_arn], s3_buckets=[self.scan_bucket.bucket_arn]),
            # 只开通用扫描（spec「CDK」）；不设 KMS（设了以后不可更新，换 KMS 要替换 Space）
            code_review_settings=securityagent.CfnAgentSpace.CodeReviewSettingsProperty(
                controls_scanning=False, general_purpose_scanning=True))
        # 角色与它的策略先建好再登记进 Space（Space 可能当场校验角色）
        self.agent_space.node.add_dependency(role)

        space_arn = f"arn:{partition}:securityagent:{region}:{account}:agent-space/{self.agent_space.attr_agent_space_id}"
        self.scan_task_role.add_to_policy(iam.PolicyStatement(actions=list(self.SA_TASK_ACTIONS), resources=[space_arn]))
        # 文档说 CreateCodeReview / UpdateCodeReview 只授权它们自己的动作、不要 iam:PassRole（api-facts A9）；10-04 的探测是管理员
        # 身份、证明不了这一点。为一次「部署后才发现被拒」的往返，这里先给（只能把这一个角色交给 securityagent）。
        self.scan_task_role.add_to_policy(iam.PolicyStatement(
            actions=["iam:PassRole"], resources=[role.role_arn],
            conditions={"StringEquals": {"iam:PassedToService": "securityagent.amazonaws.com"}}))
        # 映射表 repo_id → code review（spec Q1；2a 建的、永不开 TTL）：认领与登记都是条件 UpdateItem，读是 GetItem
        state.mapping_table.grant(self.scan_task_role, "dynamodb:GetItem", "dynamodb:UpdateItem")
        scan_container = self.scan_task_definition.find_container(self.scan_container_name)
        for name, value in (
                ("SA_AGENT_SPACE_ID", self.agent_space.attr_agent_space_id),
                ("SA_SERVICE_ROLE_ARN", role.role_arn),
                ("SA_MAPPING_TABLE", state.mapping_table.table_name),
                ("SECURITY_AGENT_TIMEOUT", str(cfg.get("security_agent_timeout", 3600)))):
            scan_container.add_environment(name, value)
