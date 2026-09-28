import aws_cdk as cdk
from aws_cdk import aws_dynamodb as ddb
from constructs import Construct


class StateStack(cdk.Stack):
    """有状态资源单独成栈：两张表的生命周期完全不同，删除策略都是 RETAIN。"""

    def __init__(self, scope: Construct, cid: str, *, cfg: dict, **kw):
        super().__init__(scope, cid, **kw)

        # 幂等锁：键 = 仓库#MR#head_sha（评论命令再拼评论 id）。TTL 24h。
        # 同一张表还放执行器按 MR 的租约（键 `lease#仓库#MR`，见 executor/entrypoint.sh）：
        # 抢锁键以纯数字的仓库 id 开头，两类键不相交；租约记录同样带 expires_at。
        self.lock_table = ddb.Table(
            self, "ReviewLock",
            partition_key=ddb.Attribute(name="pk", type=ddb.AttributeType.STRING),
            billing_mode=ddb.BillingMode.PAY_PER_REQUEST,
            time_to_live_attribute="expires_at",
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )

        # repo → codeReviewId 映射：2a 建表不使用，留给 2b。
        # **绝不设置 time_to_live_attribute**，见 test_mapping_table_must_never_enable_ttl。
        self.mapping_table = ddb.Table(
            self, "CodeReviewMapping",
            partition_key=ddb.Attribute(name="repo_id", type=ddb.AttributeType.STRING),
            billing_mode=ddb.BillingMode.PAY_PER_REQUEST,
            removal_policy=cdk.RemovalPolicy.RETAIN,
        )
