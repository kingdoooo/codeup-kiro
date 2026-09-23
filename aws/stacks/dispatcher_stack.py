import os

import aws_cdk as cdk
from aws_cdk import (
    aws_events as events,
    aws_events_targets as targets,
    aws_iam as iam,
    aws_lambda as lambda_,
    aws_secretsmanager as secretsmanager,
)
from constructs import Construct

from stacks.ingress import WebhookIngress

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LAMBDA_ROOT = os.path.join(REPO_ROOT, "aws", "lambda")


class DispatcherStack(cdk.Stack):
    """调度 Lambda + webhook 入口 + 兜底 Lambda。

    Codeup webhook → CloudFront（唯一对公网开放的面）→ VPC origin → 执行器 VPC 隔离子网里的
    内网 ALB → 调度器 Lambda → ecs:RunTask。入口的不变式（G1–G4）全在 stacks/ingress.py 的
    WebhookIngress 里，P2a-08 探测栈复用同一个构造。EventBridge 另外盯着本集群任务的 STOPPED，
    喂给兜底 Lambda 补发「任务死在脚本能自己回写之前」的评论（I10）。

    Codeup 的 webhook 注册**不**用 AwsCustomResource 实现：那个构造专门用来调 AWS SDK 的
    服务动作（service/action 映射到某个 AWS 客户端方法），Codeup OpenAPI 根本不是 AWS
    服务，AwsCustomResource 调不到它。手写一个自定义资源 Lambda 去发 HTTP 请求是可以做，
    但那是一块全新的、没有任何任务列表覆盖过的生产代码（webhook 密钥轮换、CFN
    create/update/delete 三种生命周期、网络失败重试语义都要重新设计），本任务不臆造它——
    见下方 CfnOutput：把 CloudFront 域名亮出来，注册留作部署后的手动接入步骤。
    """

    def __init__(self, scope: Construct, cid: str, *, cfg: dict, state, executor, **kw):
        super().__init__(scope, cid, **kw)

        yunxiao_token = secretsmanager.Secret.from_secret_name_v2(
            self, "YunxiaoTokenSecret", "codeup-kiro/yunxiao-token-kiro")
        webhook_secret = secretsmanager.Secret.from_secret_name_v2(
            self, "WebhookSecret", "codeup-kiro/webhook-secret")

        dispatcher_fn = lambda_.Function(
            self, "DispatcherFn",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="handler.handler",
            code=lambda_.Code.from_asset(os.path.join(LAMBDA_ROOT, "dispatcher")),
            # 早于 CloudFront 回源读超时（VPC origin 默认 30s）返回：否则 CloudFront 先给 Codeup 回 504，
            # 请求其实还在处理，Codeup 却记投递失败（可能重投，由抢锁挡住）。
            timeout=cdk.Duration.seconds(29),
            # reserved concurrency 是支出闸门：webhook 重放或异常流量下，账号级 Lambda
            # 并发配额不会被这一个函数吃满，也顺带给这条链路的意外账单设了个天花板。
            reserved_concurrent_executions=cfg["reserved_concurrency"],
            environment={
                "YUNXIAO_ORG_ID": cfg["org_id"],
                "ECS_CLUSTER": cfg["cluster"],
                "ECS_TASK_DEFINITION": cfg["task_definition"],
                "ECS_CONTAINER_NAME": cfg["container_name"],
                "SUBNET_IDS": ",".join(cfg["subnets"]),
                "SECURITY_GROUP_IDS": ",".join(cfg["security_groups"]),
                "LOCK_TABLE": state.lock_table.table_name,
                "LOCK_TTL_SECONDS": str(cfg["lock_ttl_seconds"]),
                "BOT_USERNAMES": ",".join(cfg["bot_usernames"]),
                "REVIEW_COMMAND": str(cfg["review_command"]),
                "REVIEW_COMMAND_PHRASE": cfg["command_phrase"],
                "TARGET_BRANCH_FILTER": cfg.get("target_branch_filter", ""),
                # 两个密钥经 CloudFormation 动态引用注入——部署期由 CFN 自己的凭据解析，
                # 从不落进本模板的明文（I3）。handler.py 现有契约是直接读同名环境变量的
                # 明文值（Task 7 已定，不在本任务改动范围内），所以不能走 ECS `secrets{}`
                # 那种「运行时向 Secrets Manager 发 API 调用」的路子——Lambda 环境变量没有
                # 那个机制，动态引用是唯一能让「模板里不出现明文」这条要求同时成立的写法。
                # 已知代价：部署后这两个值会以明文形式留在函数配置里，`lambda:GetFunctionConfiguration`
                # 能读到——与 ECS secrets 块（值从不出现在任务定义里）不是同一档安全性；
                # 更彻底的做法是改 handler.py 换成 Parameters and Secrets Lambda 扩展在运行时取，
                # 但那要改 Task 7 的既有契约，超出本任务范围，留作后续加固项。
                "WEBHOOK_SECRET": webhook_secret.secret_value.unsafe_unwrap(),
                "YUNXIAO_TOKEN": yunxiao_token.secret_value.unsafe_unwrap(),
            },
        )
        # 下面两条 grant 当前没有代码路径会真的触发（上面用的是动态引用，Lambda 自己从不
        # 调 Secrets Manager API）——按本任务的环境契约（"Secrets Manager reads on specific
        # ARNs"）显式给上，范围仅限这两个 ARN，为将来切到运行时读取的加固项预留，无害。
        yunxiao_token.grant_read(dispatcher_fn)
        webhook_secret.grant_read(dispatcher_fn)

        # claim/release 只做 PutItem/DeleteItem（见 handler.py），不用 grant_read_write_data——
        # 那会连 Query/Scan/GetItem 都给上，超出这两个函数实际动的写路径。
        state.lock_table.grant(dispatcher_fn, "dynamodb:PutItem", "dynamodb:DeleteItem")

        # ecs:RunTask 只对这一个任务族放行，用 :* 通配 revision——族名下每次重新部署镜像
        # 都会注册新 revision，不用 revision 通配的话每次都要跟着改一次 IAM 策略。
        task_def_arn = (
            f"arn:{cdk.Aws.PARTITION}:ecs:{cdk.Aws.REGION}:{cdk.Aws.ACCOUNT_ID}"
            f":task-definition/{cfg['task_definition']}:*"
        )
        dispatcher_fn.add_to_role_policy(iam.PolicyStatement(
            actions=["ecs:RunTask"],
            resources=[task_def_arn],
            conditions={"ArnEquals": {"ecs:cluster": (
                f"arn:{cdk.Aws.PARTITION}:ecs:{cdk.Aws.REGION}:{cdk.Aws.ACCOUNT_ID}"
                f":cluster/{cfg['cluster']}")}},
        ))
        # RunTask 还得能把任务角色/执行角色「递」给 ECS——这是最容易被漏掉的权限，缺了
        # 只在运行时报错，synth/单测都测不出来。收紧到 ExecutorStack 实际持有的那两个
        # 角色（跨栈引用，state.lock_table.grant 已经在用同一种手法），resource 不再是
        # "*"；iam:PassedToService 条件仍然保留做纵深防御，不因为已经点名角色就撤掉。
        dispatcher_fn.add_to_role_policy(iam.PolicyStatement(
            actions=["iam:PassRole"],
            resources=[executor.task_role.role_arn,
                       executor.task_definition.execution_role.role_arn],
            conditions={"StringEquals": {"iam:PassedToService": "ecs-tasks.amazonaws.com"}},
        ))

        # ALB 放进执行器 VPC 的隔离子网（跨栈引用），不为入口单独再建一个 VPC。
        ingress = WebhookIngress(self, "WebhookIngress", vpc=executor.vpc, target_fn=dispatcher_fn)

        # codeup_min 与 backstop/handler.py 不同目录；handler.py 按约定从 /opt/dispatcher
        # 导入它（见该文件顶部注释），所以这里把整个 lambda/ 目录铺成一层 Layer——
        # 铺开后 layer 内容根就是 lambda/ 的内容，挂载到 /opt/ 之后正好落在
        # /opt/dispatcher/codeup_min.py，与既有代码的路径假设完全对齐。
        codeup_min_layer = lambda_.LayerVersion(
            self, "CodeupMinLayer",
            code=lambda_.Code.from_asset(LAMBDA_ROOT),
            compatible_runtimes=[lambda_.Runtime.PYTHON_3_12],
            description="共享 codeup_min.py，供 backstop 按 /opt/dispatcher 的既有路径假设导入",
        )

        backstop_fn = lambda_.Function(
            self, "BackstopFn",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="handler.handler",
            code=lambda_.Code.from_asset(os.path.join(LAMBDA_ROOT, "backstop")),
            layers=[codeup_min_layer],
            timeout=cdk.Duration.seconds(29),
            reserved_concurrent_executions=cfg["reserved_concurrency"],
            environment={
                "LOCK_TABLE": state.lock_table.table_name,
                "YUNXIAO_ORG_ID": cfg["org_id"],
                "YUNXIAO_TOKEN": yunxiao_token.secret_value.unsafe_unwrap(),
            },
        )
        state.lock_table.grant(backstop_fn, "dynamodb:GetItem")
        yunxiao_token.grant_read(backstop_fn)

        events.Rule(
            self, "TaskStateChangeRule",
            event_pattern=events.EventPattern(
                source=["aws.ecs"], detail_type=["ECS Task State Change"]),
            targets=[targets.LambdaFunction(backstop_fn)],
        )

        cdk.CfnOutput(
            self, "WebhookUrl", value=ingress.url,
            description=(
                "Codeup webhook 手动接入地址（AwsCustomResource 调不到非 AWS 的 Codeup "
                "OpenAPI，注册留作部署后手动步骤）：在 Codeup 仓库的 Webhook 设置里创建一个 "
                "指向这个 URL 的 webhook，勾选 mergeRequestsEvents 与 noteEvents，"
                "enableSslVerification 必须为 true"),
        )

        self.dispatcher_fn = dispatcher_fn
        self.backstop_fn = backstop_fn
        self.ingress = ingress
