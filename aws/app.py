#!/usr/bin/env python3
"""AWS 档位 CDK 入口。目前不挂载任何 stack——那是后续任务的事。

本任务只接通「读配置」这一步：config.yaml 存在就跑一遍 load_config 的校验
（区域门、开关取值），提前在 synth 阶段暴露配置错误。config.yaml 本身不进
版本库（含 codeup_token 等敏感值），所以本地/CI 没放它时必须能正常跑通，
不能因为文件缺失就崩。
"""
import os

import aws_cdk as cdk

from config import load_config

app = cdk.App()

_config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.yaml")
if os.path.exists(_config_path):
    load_config(_config_path)

app.synth()
