"""入口不变式 G1/G2/G4（spec「入口修订」）的 CDK 静态断言。

参数化到两份模板上：生产 DispatcherStack（连同同一个 app 里的 State/Executor 两个 stack）与
P2a-08 探测栈。两者复用同一个 WebhookIngress 构造，所以两份都必须满足——探测验证的就是生产入口
本身（G8），任何一份不满足都说明两者已经分叉。

这些断言只能证明形状；CloudFront 真的把 Codeup 的 POST 原样送进 Lambda，只能靠 P2a-08 真跑。
"""
import json
from dataclasses import dataclass

import aws_cdk as cdk
import pytest
from aws_cdk.assertions import Template

from stacks.dispatcher_stack import DispatcherStack
from stacks.executor_stack import ExecutorStack
from stacks.probe_stack import IngressProbeStack
from stacks.state_stack import StateStack

PREFIX_LIST_NAME = "com.amazonaws.global.cloudfront.origin-facing"
CACHING_DISABLED = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
ALL_VIEWER_EXCEPT_HOST_HEADER = "b689b0a8-53d0-40ab-baf2-68738e2966ac"


@dataclass
class Case:
    ingress: dict          # 含入口（ALB/CloudFront）的那份模板
    all: list              # 同一个 app 里的全部模板（G2 要求「任何 stack」）
    subnet_owner: dict     # 子网定义所在的模板（生产是 Executor，探测是它自己）
    target_hint: str       # 目标 Lambda 的逻辑 ID 片段
    url_output: str


def _prod():
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    executor = ExecutorStack(app, "E", cfg=_full_cfg(), state=state)
    disp = DispatcherStack(app, "D", cfg=_full_cfg(), state=state, executor=executor)
    t = {k: Template.from_stack(s).to_json() for k, s in (("S", state), ("E", executor), ("D", disp))}
    return Case(t["D"], list(t.values()), t["E"], "DispatcherFn", "WebhookUrl")


def _probe():
    app = cdk.App()
    t = Template.from_stack(IngressProbeStack(
        app, "P", env=cdk.Environment(region="us-west-2"))).to_json()
    return Case(t, [t], t, "EchoFn", "ProbeUrl")


@pytest.fixture(scope="module", params=["production", "probe"])
def case(request):
    return _prod() if request.param == "production" else _probe()


def _res(t, typ):
    return {k: v for k, v in t.get("Resources", {}).items() if v["Type"] == typ}


def _one(t, typ):
    found = _res(t, typ)
    assert len(found) == 1, f"{typ} 应恰好一个，实际 {list(found)}"
    return next(iter(found.items()))


def _ref_id(v):
    if isinstance(v, dict) and "Ref" in v:
        return v["Ref"]
    if isinstance(v, dict) and "Fn::GetAtt" in v:
        return v["Fn::GetAtt"][0]
    return None


def _subnet_logical_id(case, v):
    """ALB 的子网引用 → 子网在 subnet_owner 里的逻辑 ID。同栈是 Ref，跨栈是 ImportValue → Export。"""
    if isinstance(v, dict) and "Fn::ImportValue" in v:
        name = v["Fn::ImportValue"]
        outs = [o for o in case.subnet_owner.get("Outputs", {}).values()
                if o.get("Export", {}).get("Name") == name]
        assert len(outs) == 1, f"找不到导出 {name}"
        v = outs[0]["Value"]
    rid = _ref_id(v)
    assert rid, f"无法解析子网引用 {v}"
    return rid


# ── G1 源站不可从公网直达 ─────────────────────────────────────────────────────
def test_g1_no_function_url_and_no_api_gateway_anywhere(case):
    for t in case.all:
        types = {r["Type"] for r in t.get("Resources", {}).values()}
        assert "AWS::Lambda::Url" not in types, "G1：不得存在 Function URL"
        bad = [ty for ty in types if ty.startswith(("AWS::ApiGateway::", "AWS::ApiGatewayV2::"))]
        assert not bad, f"G1：不得存在 API Gateway 资源：{bad}"


def test_g1_alb_is_internal(case):
    _, alb = _one(case.ingress, "AWS::ElasticLoadBalancingV2::LoadBalancer")
    assert alb["Properties"].get("Scheme") == "internal", alb["Properties"].get("Scheme")


def test_g1_alb_sits_only_in_isolated_subnets(case):
    # 不只看 CDK 打的 subnet-type 标签：顺着路由表查它真的没有通往 IGW 的路由——
    # 「隔离」的实质是这条，标签只是 CDK 对它的称呼。
    _, alb = _one(case.ingress, "AWS::ElasticLoadBalancingV2::LoadBalancer")
    subnets = alb["Properties"]["Subnets"]
    assert len(subnets) >= 2, "ALB 至少要两个可用区的子网"
    res = case.subnet_owner["Resources"]
    for v in subnets:
        sid = _subnet_logical_id(case, v)
        sub = res[sid]
        assert sub["Type"] == "AWS::EC2::Subnet", sid
        tags = {t["Key"]: t["Value"] for t in sub["Properties"].get("Tags", [])}
        assert tags.get("aws-cdk:subnet-type") == "Isolated", (sid, tags)
        assert not sub["Properties"].get("MapPublicIpOnLaunch"), sid
        rts = [_ref_id(a["Properties"]["RouteTableId"]) for a in res.values()
               if a["Type"] == "AWS::EC2::SubnetRouteTableAssociation"
               and _ref_id(a["Properties"]["SubnetId"]) == sid]
        assert len(rts) == 1, (sid, rts)
        igw_routes = [r for r in res.values() if r["Type"] == "AWS::EC2::Route"
                      and _ref_id(r["Properties"]["RouteTableId"]) == rts[0]
                      and "GatewayId" in r["Properties"]]
        assert not igw_routes, f"G1：ALB 子网 {sid} 的路由表通往 IGW——那是公有子网"


# ── G2 安全组只放 CloudFront 源站托管前缀列表 ─────────────────────────────────
def _ingress_rules(t):
    """(所属安全组逻辑 ID, 规则) —— 内联 SecurityGroupIngress 与独立的 SecurityGroupIngress 资源都算。"""
    out = []
    for k, v in _res(t, "AWS::EC2::SecurityGroup").items():
        out += [(k, r) for r in v["Properties"].get("SecurityGroupIngress", [])]
    for v in _res(t, "AWS::EC2::SecurityGroupIngress").values():
        out.append((_ref_id(v["Properties"].get("GroupId")), v["Properties"]))
    return out


def test_g2_no_security_group_in_any_stack_is_open_to_the_world(case):
    for t in case.all:
        for sg, r in _ingress_rules(t):
            assert r.get("CidrIp") != "0.0.0.0/0", f"G2：{sg} 对 0.0.0.0/0 开放入站：{r}"
            assert r.get("CidrIpv6") != "::/0", f"G2：{sg} 对 ::/0 开放入站：{r}"


def test_g2_alb_security_group_admits_only_the_cloudfront_prefix_list_on_80(case):
    t = case.ingress
    _, alb = _one(t, "AWS::ElasticLoadBalancingV2::LoadBalancer")
    sgs = [_ref_id(v) for v in alb["Properties"]["SecurityGroups"]]
    assert len(sgs) == 1, sgs
    rules = [r for sg, r in _ingress_rules(t) if sg == sgs[0]]
    # 引用前缀列表的规则按其 max-entries（CloudFront 这张约 55）计入安全组规则配额，所以只能有这一条
    assert len(rules) == 1, rules
    rule = rules[0]
    assert (rule.get("IpProtocol"), rule.get("FromPort"), rule.get("ToPort")) == ("tcp", 80, 80), rule
    assert "CidrIp" not in rule and "CidrIpv6" not in rule and "SourceSecurityGroupId" not in rule, rule
    src = rule.get("SourcePrefixListId")
    assert isinstance(src, dict) and src.get("Fn::GetAtt", [None, None])[1] == \
        "PrefixLists.0.PrefixListId", src
    lookup = t["Resources"][src["Fn::GetAtt"][0]]
    assert lookup["Type"] == "Custom::AWS", lookup["Type"]
    create = json.loads(lookup["Properties"]["Create"])
    assert create["action"].lower() == "describemanagedprefixlists", create
    assert create["parameters"]["Filters"] == [
        {"Name": "prefix-list-name", "Values": [PREFIX_LIST_NAME]}], create
    assert create["outputPaths"] == ["PrefixLists.0.PrefixListId"], create


def test_g2_prefix_list_lookup_does_not_download_the_latest_sdk(case):
    lookups = _res(case.ingress, "Custom::AWS")
    assert lookups, "找不到前缀列表查询（Custom::AWS）——循环为空时这条会假通过"
    for v in lookups.values():
        assert v["Properties"].get("InstallLatestAwsSdk") is False, v["Properties"]


# ── G4 监听器默认 404，只有 POST 转发给目标 Lambda ────────────────────────────
def test_g4_listener_default_action_is_a_fixed_404(case):
    alb_id, _ = _one(case.ingress, "AWS::ElasticLoadBalancingV2::LoadBalancer")
    _, lis = _one(case.ingress, "AWS::ElasticLoadBalancingV2::Listener")
    p = lis["Properties"]
    assert _ref_id(p["LoadBalancerArn"]) == alb_id
    assert (p["Port"], p["Protocol"]) == (80, "HTTP"), p
    acts = p["DefaultActions"]
    assert len(acts) == 1 and acts[0]["Type"] == "fixed-response", acts
    assert acts[0]["FixedResponseConfig"]["StatusCode"] == "404", acts


def test_g4_exactly_one_rule_forwards_post_to_a_lambda_target_group(case):
    t = case.ingress
    lis_id, _ = _one(t, "AWS::ElasticLoadBalancingV2::Listener")
    _, rule = _one(t, "AWS::ElasticLoadBalancingV2::ListenerRule")
    p = rule["Properties"]
    assert _ref_id(p["ListenerArn"]) == lis_id
    assert p["Conditions"] == [{"Field": "http-request-method",
                                "HttpRequestMethodConfig": {"Values": ["POST"]}}], p["Conditions"]
    assert len(p["Actions"]) == 1 and p["Actions"][0]["Type"] == "forward", p["Actions"]
    tg = t["Resources"][_ref_id(p["Actions"][0]["TargetGroupArn"])]
    assert tg["Properties"]["TargetType"] == "lambda", tg["Properties"]
    targets = tg["Properties"]["Targets"]
    assert len(targets) == 1 and case.target_hint in _ref_id(targets[0]["Id"]), targets


def test_g4_target_lambda_lets_elb_invoke_it(case):
    # 与原 Function URL 方案的 add-permission 同一类陷阱：缺了只在运行时 502，synth 看不出来。
    perms = [v["Properties"] for v in _res(case.ingress, "AWS::Lambda::Permission").values()
             if v["Properties"].get("Principal") == "elasticloadbalancing.amazonaws.com"]
    assert len(perms) == 1, perms
    assert case.target_hint in _ref_id(perms[0]["FunctionName"]), perms
    assert perms[0]["Action"] == "lambda:InvokeFunction", perms


# ── CloudFront → VPC origin → 这个 ALB ────────────────────────────────────────
def test_cloudfront_origin_is_a_vpc_origin_pointing_at_this_alb(case):
    t = case.ingress
    alb_id, _ = _one(t, "AWS::ElasticLoadBalancingV2::LoadBalancer")
    _, dist = _one(t, "AWS::CloudFront::Distribution")
    origins = dist["Properties"]["DistributionConfig"]["Origins"]
    assert len(origins) == 1, origins
    o = origins[0]
    assert "VpcOriginConfig" in o and "S3OriginConfig" not in o and "OriginAccessControlId" not in o, o
    assert _ref_id(o["DomainName"]) == alb_id, o["DomainName"]
    vo_id, vo = _one(t, "AWS::CloudFront::VpcOrigin")
    assert _ref_id(o["VpcOriginConfig"]["VpcOriginId"]) == vo_id
    ep = vo["Properties"]["VpcOriginEndpointConfig"]
    assert _ref_id(ep["Arn"]) == alb_id, ep
    # G3：ALB 默认域名拿不到 ACM 证书，这一段走 HTTP 80（VPC origin 私有连接，不经公网）
    assert ep.get("HTTPPort") == 80 and ep.get("OriginProtocolPolicy") == "http-only", ep
    assert not _res(t, "AWS::CloudFront::OriginAccessControl"), "新入口不再有 OAC"


def test_cloudfront_behavior_is_https_only_uncached_and_forwards_viewer_headers(case):
    _, dist = _one(case.ingress, "AWS::CloudFront::Distribution")
    b = dist["Properties"]["DistributionConfig"]["DefaultCacheBehavior"]
    assert b["ViewerProtocolPolicy"] == "https-only", b
    assert "POST" in b["AllowedMethods"], b
    assert b["CachePolicyId"] == CACHING_DISABLED, b
    assert b["OriginRequestPolicyId"] == ALL_VIEWER_EXCEPT_HOST_HEADER, b


def test_webhook_url_output_is_the_distribution_domain(case):
    t = case.ingress
    dist_id, _ = _one(t, "AWS::CloudFront::Distribution")
    out = t["Outputs"][case.url_output]["Value"]
    parts = out["Fn::Join"][1]
    assert parts[0] == "https://" and parts[-1] == "/", parts
    assert parts[1] == {"Fn::GetAtt": [dist_id, "DomainName"]}, parts


# ── 探测 app：区域门同样适用，stack 钉到该区域 ────────────────────────────────
import pathlib  # noqa: E402

probe_app = load_lambda("probe_app", pathlib.Path(__file__).resolve().parents[1] / "probe_app.py")


def test_probe_stack_is_pinned_to_the_requested_region():
    stack = probe_app.build(cdk.App(context={"region": "eu-west-1"}))
    assert stack.stack_name == "CodeupKiroIngressProbe"
    assert stack.region == "eu-west-1"


@pytest.mark.parametrize("bad", ["ap-east-1", "cn-north-1", "eu-north-1"])
def test_probe_region_outside_the_nine_is_rejected(bad):
    with pytest.raises(ValueError, match="Security Agent"):
        probe_app.build(cdk.App(context={"region": bad}))


def test_probe_region_is_required():
    with pytest.raises(ValueError, match="region"):
        probe_app.build(cdk.App())
