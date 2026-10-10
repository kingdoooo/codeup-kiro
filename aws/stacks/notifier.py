"""飞书通知（Phase 2c issue 20；spec「组件设计 · 通知 Lambda」、F4、N-F1）：挂在锁表 Stream 上的通知 Lambda。

只在 `feishu_notify: 1` 时由 StateStack 建出来（state_stack.py）。放在 StateStack 而不是调度器栈：事件源要锁表 Stream 的 ARN，跨栈引用会变成
一个 CloudFormation 导出，而**被导入的导出既不能改也不能删**——关掉通知（关 Stream）或重开一次（新 Stream、新 ARN）都会卡在
「导出正被另一个栈使用」上（CloudFormation 文档 using-cfn-stack-exports）。同一个栈里没有这个问题。

飞书凭证（`codeup-kiro/feishu-app`）只有这个函数的角色读得到（N-F1）；两个任务定义都不引用它。函数不进 VPC（与调度器、兜底 Lambda
相同，P2c-01：sandbox 2026-10-10 两者 VpcConfig 都为空），阶段二收紧任务出站时不受影响。
"""
import os
import sys

import aws_cdk as cdk
from aws_cdk import (
    aws_iam as iam,
    aws_lambda as lambda_,
    aws_lambda_event_sources as event_sources,
    aws_secretsmanager as secretsmanager,
)
from constructs import Construct

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LAMBDA_ROOT = os.path.join(REPO_ROOT, "aws", "lambda")
# 评审员的固定顺序取自 Lambda 侧档案表（与 dispatcher_stack.py 同一手法：按路径插进 sys.path，不在这里抄第二份）
sys.path.insert(0, os.path.join(LAMBDA_ROOT, "dispatcher"))
import reviewers as _reviewers  # noqa: E402

FEISHU_SECRET_NAME = "codeup-kiro/feishu-app"


class FeishuNotifier(Construct):
    def __init__(self, scope: Construct, cid: str, *, cfg: dict, lock_table):
        super().__init__(scope, cid)
        # GetChangeRequest 用 Kiro 机器人的云效令牌（只读这一个云效密钥）；飞书应用的 app_id / app_secret 是另一个密钥。两个都只放密钥名，
        # 值由 handler 在调用时经 secret_fetch.py 取（与调度器、兜底同一条理由：Lambda 环境变量里的值部署后是明文）
        kiro_token = secretsmanager.Secret.from_secret_name_v2(
            self, "YunxiaoTokenKiro", _reviewers.PROFILES["kiro"]["secret_name"])
        feishu_app = secretsmanager.Secret.from_secret_name_v2(self, "FeishuApp", FEISHU_SECRET_NAME)
        # secret_fetch.py 与 bounded_config.py 按 /opt/dispatcher 导入：整个 lambda/ 目录铺成一层 layer（与兜底 Lambda 的 CodeupMinLayer 同一手法）
        shared = lambda_.LayerVersion(
            self, "SharedLayer",
            code=lambda_.Code.from_asset(LAMBDA_ROOT),
            compatible_runtimes=[lambda_.Runtime.PYTHON_3_12],
            description="secret_fetch.py and bounded_config.py for the Feishu notifier, imported from /opt/dispatcher",
        )
        self.function = lambda_.Function(
            self, "NotifierFn",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="handler.handler",
            code=lambda_.Code.from_asset(os.path.join(LAMBDA_ROOT, "notifier")),
            layers=[shared],
            # 一条记录最多三条通知，每条有一个总时限（handler.py 的 NOTIFY_BUDGET，40 秒；最坏再多一次 socket 操作与两次取密钥）：一条记录最坏约
            # 4 分钟，留在这 300 秒之内（test_cdk_assertions 核对），函数不会跑到超时。一批只给一条记录（批 1）：万一超时，重放的只是它自己，uuid 保证重放不重发
            timeout=cdk.Duration.seconds(300),
            environment={
                "YUNXIAO_ORG_ID": cfg["org_id"],
                "YUNXIAO_TOKEN_ID": kiro_token.secret_name,
                "FEISHU_APP_SECRET_ID": feishu_app.secret_name,
                "FEISHU_DOMAIN": cfg.get("feishu_domain", "feishu"),
            },
        )
        # 末尾的 -?????? 不能省（理由见 dispatcher_stack.py 的同一段注释：按名导入的密钥只有 partial ARN）
        self.function.add_to_role_policy(iam.PolicyStatement(
            actions=["secretsmanager:GetSecretValue"],
            resources=[f"{kiro_token.secret_arn}-??????", f"{feishu_app.secret_arn}-??????"]))
        # 事件源：只把「某位评审员的 posted_<rid> 为 true、且带 comment_<rid>」的记录交给函数（三个过滤器取或）。从无到有的判定（旧映像里没有
        # posted_<rid>）与 eventName 由 handler 自己做——过滤器的 exists 只认类型叶子（NewImage.x.S），eventName 过滤在两份 AWS 文档里说法不一，
        # 不靠它们。租约续期、Kiro 的 posted、dispatched_* 这些 MODIFY 在这里就被丢掉，不调用函数。
        # 重试只给函数自己崩溃 / 超时用（handler 对每条通知的失败只记日志、不抛）：缺省是无限重试到记录过期（24 小时），这里 2 次、记录 1 小时
        # 就丢（请求带 uuid，重试不重发）。函数不超时之后，只有 Stream 里积压超过 1 小时（一个卡住的执行环境里几十条通知各自用满时限）才会丢，
        # 丢的不留日志、只在 IteratorAge 指标上看得到（终审 M-5，手册第 8 节；没有配失败目的地）。
        # TRIM_HORIZON：LATEST 在建、改事件源映射的那几分钟里可能漏事件（Lambda 文档 with-ddb）。
        self.function.add_event_source(event_sources.DynamoEventSource(
            lock_table,
            starting_position=lambda_.StartingPosition.TRIM_HORIZON,
            batch_size=1,
            retry_attempts=2,
            max_record_age=cdk.Duration.hours(1),
            filters=[lambda_.FilterCriteria.filter({"dynamodb": {"NewImage": {
                f"posted_{rid}": {"BOOL": lambda_.FilterRule.is_equal(True)},
                f"comment_{rid}": {"S": lambda_.FilterRule.exists()}}}}) for rid in _reviewers.ORDER],
        ))
        cdk.CfnOutput(self, "NotifierFunctionName", value=self.function.function_name,
                      description="Feishu notifier Lambda: its log group has one line per notification (setup-guide section 6.7)")
