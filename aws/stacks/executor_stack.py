import os

import aws_cdk as cdk
from aws_cdk import (
    aws_ec2 as ec2,
    aws_ecr_assets as ecr_assets,
    aws_ecs as ecs,
    aws_iam as iam,
    aws_logs as logs,
    aws_secretsmanager as secretsmanager,
)
from constructs import Construct

from config import DEFAULT_COMMAND_PHRASE

# aws/executor/Dockerfile 的构建上下文是仓库根（COPY scripts/ prompts/ kiro/ 都是相对仓库根的路径），
# 这里必须给出同一个根，否则 DockerImageAsset 的目录内容与 Dockerfile 里的 COPY 源路径对不上。
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# 页脚与降级评论里那句「怎么重新评审」（REVIEW_RERUN_HINT，共享引擎渲染，见
# scripts/lib/review-render.sh::_review_rerun_hint）。**必须由本档位设置**：引擎的默认值是 Flow 语义
# 的「重跑流水线可重新评审」，而 AWS 档位根本没有流水线——不设就是每条汇总评论末尾都教读者做一件
# 做不到的事（pipeline/setup-guide.md 第 11.2 节那张表也把本档位列为要改这个变量的一方）。
RERUN_HINT_PUSH = "向源分支推送新提交可重新评审"


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

# 评审行为变量：config.yaml 键 → (容器环境变量名, 缺省值)。缺省值与 scripts/ 里的 `${VAR:-默认}`
# 逐项一致（tests/test_cdk_assertions.py 读脚本比对），写进任务定义是为了让取值在任务定义里看得见，
# 而不是隐含在脚本里。取值语义归共享评审引擎，本档位不另做校验（与 Flow 档位同一套规则）。
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

        self.vpc = ec2.Vpc(
            self, "Vpc", max_azs=2, nat_gateways=0,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="public", subnet_type=ec2.SubnetType.PUBLIC, cidr_mask=24),
                ec2.SubnetConfiguration(
                    name="isolated", subnet_type=ec2.SubnetType.PRIVATE_ISOLATED, cidr_mask=24),
            ],
        )

        self.cluster = ecs.Cluster(
            self, "Cluster", vpc=self.vpc,
            container_insights_v2=ecs.ContainerInsights.ENABLED)

        # 任务本身不监听任何入站端口（只是拉起来跑一次评审就退出），出站需要访问
        # Codeup/云效 API、Kiro API、Secrets Manager、DynamoDB——保留默认放行出站，不加入站规则。
        # description 必须是 ASCII——EC2 SecurityGroupDescription 的校验正则不接受中文，
        # cdk synth 会把这个当模板校验警告打出来（本任务实测踩到过，见任务报告）。
        self.task_security_group = ec2.SecurityGroup(
            self, "TaskSg", vpc=self.vpc,
            description="Kiro review Fargate task: no inbound, default-allow outbound",
            allow_all_outbound=True,
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
                # 开关与行为变量必须真的进容器：config.py 校验通过、却从没传给评审脚本的开关，
                # 表现就是「配对了也不生效」且毫无报错（I2）。
                "INLINE_COMMENT": str(cfg["inline_comment"]),
                # 派生值，不是 config.yaml 的键（见 rerun_hint 的 docstring）
                "REVIEW_RERUN_HINT": rerun_hint(cfg),
                **{var: str(cfg.get(key, default))
                   for key, (var, default) in BEHAVIOUR_VARS.items()},
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
