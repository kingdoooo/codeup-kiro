"""执行器与扫描任务的出站限制（Phase 2c 阶段二，issue 19 做法 A；`egress_lockdown: 1` 时由 ExecutorStack 建）。

两个任务（执行器 Task A、扫描任务 Task B）的容器里有整个业务库。现有防线（业务库只作数据、镜像摘要名单、Kiro 只读 + 读取许可清单、
sbomgen 非 root 空环境）都防「进程失控」；一旦失控，网络层没有任何东西挡得住它把代码发往任意地址。做法 A 每月约 $0、不改网络结构：

1. S3 / DynamoDB **网关终端节点 + 终端节点策略**：本区域的 S3、DynamoDB 流量都经它（按任务子网的路由表），策略只许本部署的输入桶、
   ECR 的镜像层桶（Fargate 拉镜像要用）与本部署的两张表——挡住「传到自己的 S3 桶 / 写进别的表」。别的区域的 S3 不经网关终端节点，
   靠第 3 条的域名名单挡。
2. **安全组出站只放 TCP 443**（安全组本身在 executor_stack.py 里建，这里只加规则）。到 Amazon DNS 与任务元数据端点的流量不受安全组约束
   （VPC 与 ECS 文档）；镜像拉取、取密钥、写日志都经任务的网卡、都是 443。
3. **Route 53 Resolver DNS Firewall**：名单上的域名 ALLOW，其余按 `egress_dns_action` ALERT（只记录）或 BLOCK（NXDOMAIN）；缺省 fail-closed。
   名单不手写猜：先以 ALERT 部署、开查询日志，跑一轮三位评审员都开的完整验收，从日志里取实际用到的域名，再切 BLOCK（setup-guide.md 第 6.8 节）。
   不放 `*.amazonaws.com` 这种宽通配（会把别的区域的 S3 等都放进来）。

残余风险（手册 1.5 节写明）：直接连写死的 IP 的 443 端口挡不住——那要做法 B（私有子网 + 接口终端节点 + 按 IP 放行），只进手册。
"""
import aws_cdk as cdk
from aws_cdk import (
    aws_ec2 as ec2,
    aws_iam as iam,
    aws_logs as logs,
    aws_route53resolver as resolver,
)
from constructs import Construct

# Kiro CLI 要连的主机（kiro.dev/docs/privacy-and-security/firewalls.md 的 CLI 一栏，2026-08-04 版；本集成包用 API Key、不走浏览器登录，
# 登录与身份那几组不列）。验收时以 Resolver 查询日志为准增删（第 6.8 节的步骤）。
KIRO_HOSTS = (
    "app.kiro.dev", "cli.kiro.dev",
    "prod.us-east-1.auth.desktop.kiro.dev", "prod.us-east-1.telemetry.desktop.kiro.dev",
    "q.us-east-1.amazonaws.com", "runtime.us-east-1.kiro.dev", "management.us-east-1.kiro.dev", "telemetry.us-east-1.kiro.dev",
    "q.eu-central-1.amazonaws.com", "runtime.eu-central-1.kiro.dev", "management.eu-central-1.kiro.dev",
    "telemetry.eu-central-1.kiro.dev",
)
# 云效：clone / fetch / ls-remote 与 OpenAPI
CODEUP_HOSTS = ("codeup.aliyun.com", "openapi-rdc.aliyuncs.com")


def allowed_domains(region, account, scanners):
    """DNS Firewall 允许名单（本区域的 AWS 端点 + 云效 + Kiro）。account 可以是 CDK 的 token（拼进字符串由 CloudFormation 解析）。"""
    aws = [f"{svc}.{region}.amazonaws.com" for svc in ("secretsmanager", "logs", "ecs", "dynamodb", "api.ecr", "s3")]
    # DynamoDB 的按账号端点：AWS CLI v2 在凭证带账号 id 时缺省改连 <账号>.ddb.<区域>（account_id_endpoint_mode=preferred）。
    # 网关终端节点同样管它；不列的话哪天任务凭证带上账号 id，BLOCK 下每次评审都连不上 DynamoDB
    aws.append(f"{account}.ddb.{region}.amazonaws.com")
    aws += [f"{account}.dkr.ecr.{region}.amazonaws.com",    # Fargate 拉执行器镜像（CDK 资产仓库）
            f"*.s3.{region}.amazonaws.com"]                 # 虚拟主机式的桶地址（输入桶、ECR 镜像层桶）；哪个桶能用由网关终端节点策略管
    if "inspector" in scanners:
        aws.append(f"inspector-scan.{region}.amazonaws.com")
    if "security" in scanners:
        aws.append(f"securityagent.{region}.api.aws")       # Security Agent 的 API 不在 amazonaws.com 下（服务端点文档）
    return [*CODEUP_HOSTS, *KIRO_HOSTS, *aws]


class EgressLockdown(Construct):
    def __init__(self, scope: Construct, cid: str, *, vpc, task_subnets, security_group, scan_bucket, tables, scanners,
                 dns_action):
        super().__init__(scope, cid)
        region, account, partition = cdk.Aws.REGION, cdk.Aws.ACCOUNT_ID, cdk.Aws.PARTITION
        own_account = {"StringEquals": {"aws:PrincipalAccount": account}}

        security_group.add_egress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(443), "HTTPS only (codeup-kiro egress lockdown)")

        on_task_subnets = [ec2.SubnetSelection(subnets=task_subnets)]
        s3 = vpc.add_gateway_endpoint("S3Endpoint", service=ec2.GatewayVpcEndpointAwsService.S3, subnets=on_task_subnets)
        # 第一次 add_to_policy 就替换掉缺省的全放行策略。ECR 镜像层：Fargate 拉镜像时按 ECR 给的预签名地址读这个桶（ECR 文档的最小权限），
        # 发请求的不是本账号的主体，所以这一条不加 aws:PrincipalAccount
        s3.add_to_policy(iam.PolicyStatement(
            principals=[iam.AnyPrincipal()], actions=["s3:GetObject"],
            resources=[f"arn:{partition}:s3:::prod-{region}-starport-layer-bucket/*"]))
        if scan_bucket is not None:
            s3.add_to_policy(iam.PolicyStatement(
                principals=[iam.AnyPrincipal()], actions=["s3:GetObject", "s3:PutObject"],
                resources=[scan_bucket.arn_for_objects("*")], conditions=own_account))
        ddb = vpc.add_gateway_endpoint("DynamoDbEndpoint", service=ec2.GatewayVpcEndpointAwsService.DYNAMODB,
                                       subnets=on_task_subnets)
        ddb.add_to_policy(iam.PolicyStatement(
            principals=[iam.AnyPrincipal()], actions=["dynamodb:GetItem", "dynamodb:UpdateItem"],
            resources=[t.table_arn for t in tables], conditions=own_account))

        allowed = resolver.CfnFirewallDomainList(
            self, "AllowedDomains", name="codeup-kiro-egress-allowed", domains=allowed_domains(region, account, scanners))
        everything = resolver.CfnFirewallDomainList(self, "AllDomains", name="codeup-kiro-egress-all", domains=["*"])
        block = dns_action == "block"
        group = resolver.CfnFirewallRuleGroup(
            self, "RuleGroup", name="codeup-kiro-egress",
            firewall_rules=[
                # 名单上的放行；CNAME 链上的后续名字不再逐个核对（缺省会核对整条链，S3 / ECR 的端点都经 CNAME）
                resolver.CfnFirewallRuleGroup.FirewallRuleProperty(
                    action="ALLOW", firewall_domain_list_id=allowed.attr_id, priority=100,
                    firewall_domain_redirection_action="TRUST_REDIRECTION_DOMAIN"),
                resolver.CfnFirewallRuleGroup.FirewallRuleProperty(
                    action="BLOCK" if block else "ALERT", firewall_domain_list_id=everything.attr_id, priority=200,
                    **({"block_response": "NXDOMAIN"} if block else {})),
            ])
        resolver.CfnFirewallRuleGroupAssociation(
            self, "Association", name="codeup-kiro-egress", firewall_rule_group_id=group.attr_id, vpc_id=vpc.vpc_id,
            priority=101)

        # 查询日志（ALERT 阶段取名单、BLOCK 阶段查误拦都靠它）：日志里有任务解析过的每个域名（域名本身可能透露业务，保留 30 天）
        log_group = logs.LogGroup(self, "DnsQueryLogs", retention=logs.RetentionDays.ONE_MONTH,
                                  removal_policy=cdk.RemovalPolicy.DESTROY)
        query_log = resolver.CfnResolverQueryLoggingConfig(
            self, "QueryLogging", name="codeup-kiro-egress",
            destination_arn=f"arn:{partition}:logs:{region}:{account}:log-group:{log_group.log_group_name}")
        # 写日志的权限显式给（Route 53 文档：CloudWatch Logs 目的地用 V1 权限模型，由「建日志配置的调用方」代建资源策略——经 CloudFormation
        # 建时谁是那个调用方、会不会建，文档没说；显式写一份不依赖它）。条件照 CloudWatch Logs 文档「V1 权限」的写法：投递服务出示的
        # aws:SourceArn 是 logs 的 ARN（arn:…:logs:<区域>:<账号>:*），不是 route53resolver 的
        log_group.add_to_resource_policy(iam.PolicyStatement(
            principals=[iam.ServicePrincipal("delivery.logs.amazonaws.com")],
            actions=["logs:CreateLogStream", "logs:PutLogEvents"],
            resources=[f"{log_group.log_group_arn}"],
            conditions={"StringEquals": {"aws:SourceAccount": account},
                        "ArnLike": {"aws:SourceArn": f"arn:{partition}:logs:{region}:{account}:*"}}))
        resolver.CfnResolverQueryLoggingConfigAssociation(
            self, "QueryLoggingAssociation", resolver_query_log_config_id=query_log.attr_id, resource_id=vpc.vpc_id)
        cdk.CfnOutput(self, "DnsQueryLogGroup", value=log_group.log_group_name,
                      description="Route 53 Resolver query logs of the executor VPC (setup-guide section 6.8)")
