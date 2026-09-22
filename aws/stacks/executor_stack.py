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

# aws/executor/Dockerfile 的构建上下文是仓库根（COPY scripts/ prompts/ kiro/ 都是相对仓库根的路径），
# 这里必须给出同一个根，否则 DockerImageAsset 的目录内容与 Dockerfile 里的 COPY 源路径对不上。
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


class ExecutorStack(cdk.Stack):
    """Fargate 执行器：ECS Cluster + 任务定义 + 执行器镜像资产。

    调度器用 assignPublicIp=ENABLED 拉起任务（见 lambda/dispatcher/handler.py::run_task），
    所以这里的子网必须是公有子网，不建 NAT——没有出网需求要靠 NAT 转发的理由。
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
            subnet_configuration=[ec2.SubnetConfiguration(
                name="public", subnet_type=ec2.SubnetType.PUBLIC, cidr_mask=24)],
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
            # 不排除的话 CDK 分阶段 staging 会把整个仓库根（含 aws/cdk.out/、aws/.venv/、.git/）
            # 当成构建上下文原样拷贝一份——cdk.out 又刚好在仓库根之内，前一次 synth 留下的
            # cdk.out 会被下一次 synth 递归拷进新的 cdk.out，实测直接拷出 ENAMETOOLONG。
            # Dockerfile 只 COPY scripts/ prompts/ kiro/ aws/executor/ 这几处，其余都不需要。
            exclude=["aws/cdk.out", "aws/.venv", ".git", "**/__pycache__", "**/*.pyc",
                     ".pytest_cache", ".scratch", "docs/blog", "docs/superpowers"],
        )

        log_group = logs.LogGroup(
            self, "ExecutorLogs",
            retention=logs.RetentionDays.ONE_MONTH,
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )

        # 任务角色只给 dynamodb:UpdateItem（entrypoint.sh 收尾时写「已回写」标记）与写日志——
        # 不用 grant_write_data，那会连 PutItem/DeleteItem/条件写都给上，超出这个角色实际要做的事。
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
            environment={
                "KIRO_IMAGE_DIGESTS": cfg.get("kiro_image_digests", ""),
                "KIRO_PINNED_ARTIFACT_SHA256": cfg.get("kiro_pinned_artifact_sha256", ""),
                "KIRO_CLI_SHA256": cfg.get("kiro_cli_sha256", ""),
                "YUNXIAO_ORG_ID": cfg["org_id"],
                "CODEUP_BOT_USERNAME": cfg["bot_username"],
                "LOCK_TABLE": state.lock_table.table_name,
                "AWS_REGION": cfg["region"],
            },
            secrets={
                "KIRO_API_KEY": ecs.Secret.from_secrets_manager(kiro_api_key),
                "YUNXIAO_TOKEN": ecs.Secret.from_secrets_manager(yunxiao_token),
            },
        )

        state.lock_table.grant(self.task_role, "dynamodb:UpdateItem")
        # add_container 已经通过 LogDrivers.aws_logs 把 CreateLogStream/PutLogEvents 授给了
        # execution_role；这里再显式给任务角色同一组权限——本任务的环境契约明确写了
        # 「任务角色需要 dynamodb:UpdateItem 与 logs」，两个角色都持有虽有重叠但各自都是最小授权
        # （都只scope 到这一个日志组），不是通配符。
        log_group.grant_write(self.task_role)
