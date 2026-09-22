#!/usr/bin/env python3
"""AWS 档位 CDK 入口。

config.yaml 存在才挂载三个 stack（State/Executor/Dispatcher）；不存在时只做「读配置」这一步
就直接 synth——那一步在 config.yaml 缺失时天然是空操作，不能因为文件缺失就崩，本地/CI
没放它时仍要能正常跑通 `cdk synth`（这也是为什么 setup-guide.md 第 6 节要单独说明「零个 stack
不是故障」：那句话描述的是本文件曾经的状态，Task 11 把它改成了「有 config.yaml 才有三个 stack」）。

config.yaml 的强校验（区域门、org_id/bot_username、开关取值）全部在 aws/config.py::load_config
里，这里不重复。Dispatcher/Executor 用到的部署级静态值（reserved_concurrency、cpu、
ephemeral_storage_gib 等）不在 load_config 的必填字段里——它只验证自己关心的那几个键，
其余键原样放行——所以这里统一用 cfg.get(key, 默认值) 读，config.yaml 没写这些键时退回
合理默认，写了就按写的来，不需要为这几个新键去改 config.py 的强校验（那是 Task 2 的文件）。
"""
import os

import aws_cdk as cdk

from config import load_config
from stacks.dispatcher_stack import DispatcherStack
from stacks.executor_stack import ExecutorStack
from stacks.state_stack import StateStack

app = cdk.App()

_config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.yaml")
if os.path.exists(_config_path):
    cfg = load_config(_config_path)

    state = StateStack(app, "CodeupKiroState", cfg=cfg)
    executor = ExecutorStack(app, "CodeupKiroExecutor", cfg=cfg, state=state)

    dispatcher_cfg = dict(cfg)
    dispatcher_cfg.setdefault("bot_usernames", [cfg["bot_username"]])
    dispatcher_cfg.setdefault("command_phrase", "/kiro review")
    dispatcher_cfg.setdefault("target_branch_filter", "")
    dispatcher_cfg.setdefault("lock_ttl_seconds", 86400)
    dispatcher_cfg.setdefault("reserved_concurrency", 5)
    # 三项由 ExecutorStack 的真实资源覆盖——不是 config.yaml 的字段，config.yaml 写了也不算，
    # 调度器必须打到刚刚创建的那个集群/任务定义/安全组上，不能是使用者随手填的字符串。
    dispatcher_cfg["cluster"] = executor.cluster.cluster_name
    dispatcher_cfg["task_definition"] = executor.task_definition.family
    dispatcher_cfg["container_name"] = executor.container_name
    dispatcher_cfg["subnets"] = [s.subnet_id for s in executor.vpc.public_subnets]
    dispatcher_cfg["security_groups"] = [executor.task_security_group.security_group_id]

    dispatcher = DispatcherStack(
        app, "CodeupKiroDispatcher", cfg=dispatcher_cfg, state=state, executor=executor)
    dispatcher.add_stack_dependency(executor)

app.synth()
