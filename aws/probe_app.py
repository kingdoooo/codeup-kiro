#!/usr/bin/env python3
"""P2a-08 入口探测：独立 CDK app，只含 CodeupKiroIngressProbe 一个 stack（计划 Task 1 Step 1/1b/8）。

    cdk --app "python3 probe_app.py" -c region=<r> deploy CodeupKiroIngressProbe

区域取自 `-c region=`，同样过 config.VALID_REGIONS 这道区域门，并把 stack 钉到这个区域——探测
必须在正式部署的区域里做，VPC origin 的可用性按区域/可用区而异（spec G7）。不读 config.yaml。
"""
import os

import aws_cdk as cdk

from config import VALID_REGIONS
from stacks.probe_stack import IngressProbeStack

STACK_NAME = "CodeupKiroIngressProbe"


def probe_region(app):
    region = app.node.try_get_context("region")
    if not region:
        raise ValueError("缺少 -c region=<r>：探测必须在正式部署的区域里做，无默认值")
    if region not in VALID_REGIONS:
        raise ValueError(
            f"region {region!r} 不在 Security Agent 支持的九个区域内，拒绝部署探测栈。"
            f"有效集合：{sorted(VALID_REGIONS)}")
    return region


def build(app):
    env = cdk.Environment(account=os.environ.get("CDK_DEFAULT_ACCOUNT"), region=probe_region(app))
    return IngressProbeStack(app, STACK_NAME, env=env)


if __name__ == "__main__":
    _app = cdk.App()
    build(_app)
    _app.synth()
