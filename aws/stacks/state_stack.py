import aws_cdk as cdk
from aws_cdk import aws_dynamodb as ddb
from constructs import Construct

from config import feishu_notify_on
from stacks.notifier import FeishuNotifier


class StateStack(cdk.Stack):
    """有状态资源单独成栈：两张表的生命周期完全不同，删除策略都是 RETAIN。

    飞书通知（Phase 2c issue 20，`feishu_notify: 1`）也在这里：通知 Lambda 挂在锁表的 Stream 上，同栈才不会产生跨栈导出（理由见
    stacks/notifier.py）。开关为 0 时本栈的模板与 Phase 2b 逐字节相同（不开 Stream、没有 Lambda）。
    """

    def __init__(self, scope: Construct, cid: str, *, cfg: dict, **kw):
        super().__init__(scope, cid, **kw)
        notify = feishu_notify_on(cfg)

        # 幂等锁：键 = 仓库#MR#head_sha（评论命令再拼评论 id）。TTL 24h。
        # 同一张表还放执行器按 MR 的租约（键 `lease#仓库#MR`，见 executor/entrypoint.sh）：
        # 抢锁键以纯数字的仓库 id 开头，两类键不相交；租约记录同样带 expires_at。
        # 飞书通知开着时开 Stream（新旧映像都要：通知只认 posted_<评审员> 从无到有的那一次变化）。开 / 关 Stream 都不中断表
        # （CloudFormation：StreamSpecification 的更新是 No interruption）；关了再开是一个新 Stream（新 ARN），事件源映射随之重建。
        self.lock_table = ddb.Table(
            self, "ReviewLock",
            partition_key=ddb.Attribute(name="pk", type=ddb.AttributeType.STRING),
            billing_mode=ddb.BillingMode.PAY_PER_REQUEST,
            time_to_live_attribute="expires_at",
            removal_policy=cdk.RemovalPolicy.RETAIN,
            stream=ddb.StreamViewType.NEW_AND_OLD_IMAGES if notify else None,
        )

        # repo → codeReviewId 映射：2a 建表不使用，留给 2b。
        # **绝不设置 time_to_live_attribute**，见 test_mapping_table_must_never_enable_ttl。
        self.mapping_table = ddb.Table(
            self, "CodeReviewMapping",
            partition_key=ddb.Attribute(name="repo_id", type=ddb.AttributeType.STRING),
            billing_mode=ddb.BillingMode.PAY_PER_REQUEST,
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )
        # 执行器开着 SA 时经跨栈导入映射表的 ARN（授权）与名字（SA_MAPPING_TABLE）；关掉 SA 时本栈先部署——这两个导出若随之消失，
        # 执行器栈的旧模板还导入着，CloudFormation 拒绝删除仍被导入的导出、部署卡住（Codex 第 1 轮 R3）。所以一直显式导出
        # （名字与自动生成的相同，同 executor_stack 里 NAT 回退保留公有子网导出的手法）；没开过 SA 时只是多两个没人导入的导出
        self.export_value(self.mapping_table.table_arn)
        self.export_value(self.mapping_table.table_name)

        self.notifier = FeishuNotifier(self, "FeishuNotifier", cfg=cfg, lock_table=self.lock_table) if notify else None
