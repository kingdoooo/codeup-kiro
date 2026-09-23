import os

import aws_cdk as cdk
from aws_cdk import (
    aws_ec2 as ec2,
    aws_lambda as lambda_,
    aws_logs as logs,
)
from constructs import Construct

from stacks.ingress import WebhookIngress

LAMBDA_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "lambda"))


class IngressProbeStack(cdk.Stack):
    """P2a-08 探测栈（计划 Task 1 Step 1/1b/8 部署、打穿、删除）：与生产同一个 WebhookIngress，
    目标换成回显 Lambda，所以探测验证的就是生产入口本身（spec「入口修订」G8）。

    自带 VPC：公有子网只为满足「VPC origin 要求 VPC 挂着 IGW」，里面什么也不放；ALB 在隔离子网。
    不读 config.yaml——探测发生在正式配置之前，也不该依赖它。
    """

    def __init__(self, scope: Construct, cid: str, **kw):
        super().__init__(scope, cid, **kw)

        vpc = ec2.Vpc(
            self, "Vpc", max_azs=2, nat_gateways=0,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="public", subnet_type=ec2.SubnetType.PUBLIC, cidr_mask=24),
                ec2.SubnetConfiguration(
                    name="isolated", subnet_type=ec2.SubnetType.PRIVATE_ISOLATED, cidr_mask=24),
            ],
        )

        # http_shape 在 lambda/dispatcher/ 下；与兜底 Lambda 取 codeup_min 同一手法——整个 lambda/
        # 铺成一层 layer，挂到 /opt 后正好是 /opt/dispatcher/http_shape.py。
        shared_layer = lambda_.LayerVersion(
            self, "HttpShapeLayer",
            code=lambda_.Code.from_asset(LAMBDA_ROOT),
            compatible_runtimes=[lambda_.Runtime.PYTHON_3_12],
            description="shared http_shape.py at /opt/dispatcher",
        )
        # 日志里有 Codeup 报文全文（MR 标题、作者等），留存一周、随栈删除；令牌已在 handler 里打码。
        log_group = logs.LogGroup(
            self, "EchoLogs", retention=logs.RetentionDays.ONE_WEEK,
            removal_policy=cdk.RemovalPolicy.DESTROY)
        echo_fn = lambda_.Function(
            self, "EchoFn",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="handler.handler",
            code=lambda_.Code.from_asset(os.path.join(LAMBDA_ROOT, "probe_echo")),
            layers=[shared_layer],
            timeout=cdk.Duration.seconds(10),
            log_group=log_group,
        )

        ingress = WebhookIngress(self, "Ingress", vpc=vpc, target_fn=echo_fn)

        cdk.CfnOutput(self, "ProbeUrl", value=ingress.url,
                      description="P2a-08: POST here; response body = SHA256 of the decoded body")
        cdk.CfnOutput(self, "AlbDnsName", value=ingress.alb.load_balancer_dns_name,
                      description="P2a-08 (3): must NOT be reachable from the internet")
