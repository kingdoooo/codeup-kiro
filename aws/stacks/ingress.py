from aws_cdk import (
    aws_cloudfront as cloudfront,
    aws_cloudfront_origins as origins,
    aws_ec2 as ec2,
    aws_elasticloadbalancingv2 as elbv2,
    aws_elasticloadbalancingv2_targets as elb_targets,
    custom_resources as cr,
)
from constructs import Construct

# CloudFront 源站侧服务器的 AWS 托管前缀列表（IPv4）。VPC origin 的流量从这组地址进来。
CLOUDFRONT_ORIGIN_FACING = "com.amazonaws.global.cloudfront.origin-facing"


class WebhookIngress(Construct):
    """Codeup webhook 的唯一入口：CloudFront → VPC origin → 内网 ALB → 目标 Lambda。

    生产 DispatcherStack 与 P2a-08 探测栈复用这一个构造，只换目标 Lambda——探测验证的就是
    生产入口本身（spec「入口修订」G8）。不变式与守卫见 tests/test_ingress.py：

    - G1 ALB 是 internal，只放在 PRIVATE_ISOLATED 子网；不建 Function URL，也不建 API Gateway。
    - G2 ALB 安全组入站只有一条：CloudFront 源站托管前缀列表的 TCP 80。同一 VPC 里还有评审任务，
      内网不等于可信，所以也不放 VPC CIDR。
    - G3 CloudFront→ALB 走 HTTP 80：ALB 的默认域名 *.elb.amazonaws.com 申请不到 ACM 证书，HTTPS
      源站需要自有域名，本轮不引入。这一段走 VPC origin 的私有连接、不经公网；Codeup→CloudFront
      一段仍是 HTTPS。
    - G4 监听器默认动作固定返回 404，只有 POST 转发给目标 Lambda。

    放弃的原方案（CloudFront + OAC → AWS_IAM Function URL）收不了 webhook：AWS 要求经 OAC 向
    Function URL 发 POST 的**发送方**自己算正文 SHA256 放进 x-amz-content-sha256，Codeup 不会发。
    """

    def __init__(self, scope: Construct, cid: str, *, vpc: ec2.IVpc, target_fn):
        super().__init__(scope, cid)

        # 前缀列表 ID 按区域不同，部署时查，不用 ec2.PrefixList.from_lookup：后者在 synth 时就要
        # 具体账号，离线 synth 与单测都会失败，还会把账号相关的值写进 cdk.context.json（公开仓库）。
        # install_latest_aws_sdk=False：用 Lambda 运行时自带的 SDK，部署时不去 npm 拉包。
        lookup_call = cr.AwsSdkCall(
            service="EC2", action="describeManagedPrefixLists",
            parameters={"Filters": [{"Name": "prefix-list-name",
                                     "Values": [CLOUDFRONT_ORIGIN_FACING]}]},
            physical_resource_id=cr.PhysicalResourceId.of(CLOUDFRONT_ORIGIN_FACING),
            output_paths=["PrefixLists.0.PrefixListId"],
        )
        prefix_list = cr.AwsCustomResource(
            self, "CloudFrontPrefixList",
            on_create=lookup_call, on_update=lookup_call,
            policy=cr.AwsCustomResourcePolicy.from_sdk_calls(
                resources=cr.AwsCustomResourcePolicy.ANY_RESOURCE),
            install_latest_aws_sdk=False,
        )

        # description 必须是 ASCII（EC2 的校验正则不接受中文，见 executor_stack.py 的同类注释）。
        # 出站不放行：Lambda target 由 ELB 服务调用，不走 ALB 安全组的出站（与 CDK 给 ALB 自动建的
        # 安全组默认一致）。
        self.security_group = ec2.SecurityGroup(
            self, "AlbSg", vpc=vpc,
            description="Webhook ALB: inbound TCP 80 only from CloudFront origin-facing prefix list",
            allow_all_outbound=False,
        )
        # 只写这一条：引用前缀列表的规则按其 max-entries（CloudFront 这张约 55）计入安全组规则配额，
        # 默认上限 60。
        self.security_group.add_ingress_rule(
            ec2.Peer.prefix_list(prefix_list.get_response_field("PrefixLists.0.PrefixListId")),
            ec2.Port.tcp(80), "CloudFront origin-facing only")

        self.alb = elbv2.ApplicationLoadBalancer(
            self, "Alb", vpc=vpc, internet_facing=False,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE_ISOLATED),
            security_group=self.security_group,
        )

        # open=False 是本构造最要紧的一个参数：CDK 默认 open=True，会自动给 ALB 安全组加一条
        # 0.0.0.0/0 的入站——G2 当场作废，而 synth 不会有任何提示。
        self.listener = self.alb.add_listener(
            "Http", port=80, open=False,
            default_action=elbv2.ListenerAction.fixed_response(
                404, content_type="text/plain", message_body="not found"),
        )
        self.listener.add_targets(
            "Target", priority=10,
            conditions=[elbv2.ListenerCondition.http_request_methods(["POST"])],
            targets=[elb_targets.LambdaTarget(target_fn)],
        )

        self.distribution = cloudfront.Distribution(
            self, "Distribution",
            default_behavior=cloudfront.BehaviorOptions(
                origin=origins.VpcOrigin.with_application_load_balancer(
                    self.alb, protocol_policy=cloudfront.OriginProtocolPolicy.HTTP_ONLY,
                    http_port=80),
                allowed_methods=cloudfront.AllowedMethods.ALLOW_ALL,
                cache_policy=cloudfront.CachePolicy.CACHING_DISABLED,
                origin_request_policy=cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
                viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
            ),
        )

        self.url = f"https://{self.distribution.distribution_domain_name}/"
