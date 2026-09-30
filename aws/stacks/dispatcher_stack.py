import os

import aws_cdk as cdk
from aws_cdk import (
    aws_cloudwatch as cloudwatch,
    aws_cloudwatch_actions as cw_actions,
    aws_events as events,
    aws_events_targets as targets,
    aws_iam as iam,
    aws_lambda as lambda_,
    aws_lambda_destinations as destinations,
    aws_secretsmanager as secretsmanager,
    aws_sns as sns,
    aws_sqs as sqs,
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
                # 两个密钥只注入 **SecretId**（GetSecretValue 的入参名，接受 ARN 或密钥名），
                # 值由 handler 在调用时自己向 Secrets Manager 取
                # （lambda/dispatcher/secret_fetch.py）。这里绝不注入明文：CloudFormation 动态引用
                # 能让模板里不出现明文，但部署后的函数配置里存的仍是明文，任何能
                # `lambda:GetFunctionConfiguration` 的主体都读得到——与 ECS 的 `secrets{}` 块
                # （值从不进任务定义）不是同一档安全性（Ruling 16）。
                #
                # 给的是**密钥名**（secret_name）而不是 ARN，理由是 from_secret_name_v2 能拿到的
                # 只有 partial ARN：secret_full_arn 对按名导入的密钥恒为 None（aws_cdk/
                # aws_secretsmanager/__init__.py:4767 的 secretFullArn 文档：“undefined when a full
                # ARN is not available (e.g., secrets imported by name)”），而六位随机后缀要调
                # AWS API 才知道、synth 期拿不到。AWS 文档
                # （secretsmanager/latest/userguide/troubleshoot.html，“An AWS CLI or AWS SDK
                # operation can't find my secret from a partial ARN”）明确说：密钥名以「连字符 +
                # 六个字符」结尾时，partial ARN 会被当成完整 ARN 解析、从而找不到密钥，建议用
                # 完整 ARN **或密钥名**。`codeup-kiro/webhook-secret` 的末段 `secret` 正好是六个
                # 字符，正中这个坑；密钥名没有这个歧义，所以传名字。
                # secret_name 对按名导入的密钥就是传进去的那个字面量（同文件 :4728，且已实测
                # 不是 Token），不会在模板里变成 Fn::Join。
                "WEBHOOK_SECRET_ID": webhook_secret.secret_name,
                # 调度器只在 RunTask 失败后的留痕那一步读云效令牌（handler.py 的 _post_failed_comment，
                # issue 05 G3）；注入的是密钥名，不是暴露面。
                "YUNXIAO_TOKEN_ID": yunxiao_token.secret_name,
            },
        )
        # 这条授权现在是真在用的代码路径：调度器每次调用都经 secret_fetch.py 读 webhook 密钥
        # （云效令牌只在 RunTask 失败后的留痕那一步读，见 handler.py 的 _post_failed_comment，一并授权）。缺了它
        # GetSecretValue 会抛 AccessDeniedException，handler 按 fail-closed 回 503。
        # 不用 grant_read：那会连 secretsmanager:DescribeSecret 一起给上，两个 Lambda 都不调它
        # （与上面 lock_table 不用 grant_read_write_data 同一条理由）。
        # IAM 这侧仍然按 ARN 授权（策略的 Resource 不接受密钥名），且末尾的 "-??????" 不能省：
        # 请求里传的是密钥名，IAM 授权比对的却是 Secrets Manager 解析出来的完整 ARN（带六位随机
        # 后缀），不通配这六位会一律 AccessDenied——CDK 自己的 grant_read 对按名导入的密钥也正是
        # 这么拼的（arnForPolicies = `${secretArn}-??????`）。这类错误只在部署后的运行时暴露，
        # 所以 tests 里有一条断言专门钉住这个后缀。
        dispatcher_fn.add_to_role_policy(iam.PolicyStatement(
            actions=["secretsmanager:GetSecretValue"],
            resources=[f"{webhook_secret.secret_arn}-??????",
                       f"{yunxiao_token.secret_arn}-??????"]))

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

        # codeup_min、secret_fetch 与 bounded_config 都与 backstop/handler.py 不同目录；handler.py 按约定从
        # /opt/dispatcher 导入它们（见该文件顶部注释），所以这里把整个 lambda/ 目录铺成一层
        # Layer——铺开后 layer 内容根就是 lambda/ 的内容，挂载到 /opt/ 之后正好落在
        # /opt/dispatcher/codeup_min.py 与 /opt/dispatcher/secret_fetch.py，与既有代码的路径假设
        # 完全对齐（取密钥的助手因此只有一份实现，不为兜底再抄一遍）。
        codeup_min_layer = lambda_.LayerVersion(
            self, "CodeupMinLayer",
            code=lambda_.Code.from_asset(LAMBDA_ROOT),
            compatible_runtimes=[lambda_.Runtime.PYTHON_3_12],
            description="共享 codeup_min.py 与 secret_fetch.py，供 backstop 按 /opt/dispatcher 的既有路径假设导入",
        )

        # 兜底 Lambda 是 EventBridge 异步调用的：抛异常或超时后 Lambda 自己重试 2 次，再失败就**丢弃**
        # 这个事件（AWS 文档：Lambda discards the event when the maximum age passes or all retry
        # attempts fail）——I10「重复好于沉默」在平台这一层断掉，而且毫无痕迹。Task 14 验收 (a)
        # 实测过一次：任务 c38fb2ce 异常结束，MR 上没有兜底评论（全分支复审 s1 F2）。
        # 所以丢弃之前先把调用记录（`requestPayload` 就是原始的 ECS 事件）送进这个队列，并对它与
        # BackstopFn 的 Errors 各设一个告警。队列用 SQS 托管加密（不需要额外的 KMS 授权就能让
        # Lambda 往里写），保留 14 天（上限）：够运维在假期之后照手册 §8 重放。
        backstop_failures = sqs.Queue(
            self, "BackstopFailures",
            encryption=sqs.QueueEncryption.SQS_MANAGED,
            enforce_ssl=True,
            retention_period=cdk.Duration.days(14),
        )

        backstop_fn = lambda_.Function(
            self, "BackstopFn",
            on_failure=destinations.SqsDestination(backstop_failures),
            # 显式写出 Lambda 的缺省（重试 2 次）：手册 §8 讲重放时按这个次数解释
            # `approximateInvokeCount`，缺省哪天变了这里不该跟着悄悄变。
            retry_attempts=2,
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="handler.handler",
            code=lambda_.Code.from_asset(os.path.join(LAMBDA_ROOT, "backstop")),
            layers=[codeup_min_layer],
            timeout=cdk.Duration.seconds(29),
            reserved_concurrent_executions=cfg["reserved_concurrency"],
            environment={
                "LOCK_TABLE": state.lock_table.table_name,
                "YUNXIAO_ORG_ID": cfg["org_id"],
                # 同调度器：只给密钥名（理由见上），值由 handler.py 在真要发评论时经
                # secret_fetch.py 取。
                "YUNXIAO_TOKEN_ID": yunxiao_token.secret_name,
            },
        )
        state.lock_table.grant(backstop_fn, "dynamodb:GetItem")
        # 兜底只读云效令牌这一个密钥（发那条「评审未完成」评论用），不给它 webhook 密钥——
        # 两个函数各自只拿到自己真正会读的那些 ARN。
        backstop_fn.add_to_role_policy(iam.PolicyStatement(
            actions=["secretsmanager:GetSecretValue"],
            resources=[f"{yunxiao_token.secret_arn}-??????"]))

        # 只要本集群、已 STOPPED 的任务：ECS 每次状态迁移都发这个事件，不筛 lastStatus 会在任务
        # 还在跑时就触发兜底（backstop/handler.py 的 should_post 另有同一道判断）；不筛 clusterArn，
        # 账号里别的 ECS 负载也会调用兜底，按保留并发把它挤满，恰好在我们的任务死掉时丢评论。
        # EventBridge 至少一次投递：重复的 STOPPED 会产生重复的兜底评论，属 spec 已接受的「重复好于沉默」。
        events.Rule(
            self, "TaskStateChangeRule",
            event_pattern=events.EventPattern(
                source=["aws.ecs"], detail_type=["ECS Task State Change"],
                detail={"lastStatus": ["STOPPED"],
                        "clusterArn": [executor.cluster.cluster_arn]}),
            targets=[targets.LambdaFunction(backstop_fn)],
        )

        # 三个告警都通知同一个主题，运维订阅它即可（手册 §8「兜底告警」）。告警动作写在 CDK 里而不是
        # 让运维在控制台手加：手加的动作下一次 `cdk deploy` 就被覆盖掉。
        # 主题**不加** KMS 加密：CloudWatch 告警发不进用 AWS 托管密钥 alias/aws/sns 加密的主题（那个
        # 密钥的策略不允许 cloudwatch.amazonaws.com 解密/生成数据密钥，也改不了），要加密就得另建客户
        # 托管密钥并改它的策略。告警通知里只有告警名、指标与阈值，没有评审内容或密钥；传输强制 TLS。
        alarm_topic = sns.Topic(self, "BackstopAlarmTopic", enforce_ssl=True)
        failures_alarm = cloudwatch.Alarm(
            self, "BackstopFailuresAlarm",
            alarm_description=(
                "兜底 Lambda 重试耗尽后丢下的事件进了 BackstopFailures 队列：有 MR 缺一条「评审未完成」"
                "评论。按 aws/setup-guide.md 第 8 节「兜底告警」重放"),
            metric=backstop_failures.metric_approximate_number_of_messages_visible(
                period=cdk.Duration.minutes(5), statistic="Maximum"),
            threshold=0,
            comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
            evaluation_periods=1,
            treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
        )
        errors_alarm = cloudwatch.Alarm(
            self, "BackstopErrorsAlarm",
            alarm_description=(
                "兜底 Lambda 抛了异常或超时（会自动重试；重试耗尽的事件进 BackstopFailures 队列）。"
                "查它的日志组，见 aws/setup-guide.md 第 8 节「兜底告警」"),
            metric=backstop_fn.metric_errors(period=cdk.Duration.minutes(5), statistic="Sum"),
            threshold=0,
            comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
            evaluation_periods=1,
            treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
        )
        # 事件连队列都没进去：Lambda 往 BackstopFailures 投递失败（队列被删、策略被改、兜底角色少了
        # sqs:SendMessage）。这时上面那个队列告警没有消息可数、不会响（issue 05 B5）。AsyncEventsDropped
        # 不加：配了 OnFailure 目的地时，事件先送进目的地再计为 dropped（Lambda 文档 Asynchronous
        # invocation metrics），与队列告警重复。
        delivery_alarm = cloudwatch.Alarm(
            self, "BackstopDeliveryFailuresAlarm",
            alarm_description=(
                "兜底 Lambda 重试耗尽的事件没能投递进 BackstopFailures 队列（目的地权限或队列本身有问题），"
                "队列告警不会响，也没有可重放的消息。见 aws/setup-guide.md 第 8 节「兜底告警」"),
            metric=backstop_fn.metric("DestinationDeliveryFailures",
                                      period=cdk.Duration.minutes(5), statistic="Sum"),
            threshold=0,
            comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
            evaluation_periods=1,
            treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
        )
        for alarm in (failures_alarm, errors_alarm, delivery_alarm):
            alarm.add_alarm_action(cw_actions.SnsAction(alarm_topic))
        cdk.CfnOutput(self, "BackstopAlarmTopicArn", value=alarm_topic.topic_arn,
                      description="兜底告警的 SNS 主题：aws sns subscribe 订阅它（手册第 8 节）")
        cdk.CfnOutput(self, "BackstopFailuresQueueUrl", value=backstop_failures.queue_url,
                      description="兜底重试耗尽后丢下的事件：按手册第 8 节「兜底告警」重放")
        cdk.CfnOutput(self, "BackstopFunctionName", value=backstop_fn.function_name,
                      description="重放兜底事件时 aws lambda invoke 的目标（手册第 8 节「兜底告警」）")

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
        self.backstop_failures = backstop_failures
        self.ingress = ingress
