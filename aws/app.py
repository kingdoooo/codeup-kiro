#!/usr/bin/env python3
"""AWS 档位 CDK 入口。

config.yaml 存在才挂载三个 stack（State/Executor/Dispatcher）；不存在时直接 synth 出零个 stack——
本地/CI 没放它时仍要能正常跑通 `cdk synth`，不能因为文件缺失就崩。

config.yaml 的强校验（区域门、必填字段、开关取值、三个摘要）全部在 aws/config.py::load_config
里，这里不重复。Dispatcher/Executor 用到的其余部署级静态值（reserved_concurrency、cpu、
ephemeral_storage_gib 等）不在 load_config 的必填字段里，这里与各 stack 统一用
cfg.get(key, 默认值) 读——每个键、默认值与是否必填都列在 config.example.yaml。

三个 stack 都钉到 cfg["region"]：不钉的话 stack 与环境无关，CloudFormation 按 CDK CLI 解析到的
区域（CDK_DEFAULT_REGION / AWS_REGION / profile）部署，区域门校验的就是一个决定不了部署位置的值。
账号取 CDK_DEFAULT_ACCOUNT（CLI 按当前凭证填入；离线 synth 时为空，stack 对账号保持无关）。
"""
import os

import aws_cdk as cdk

from config import load_config
from stacks.dispatcher_stack import DispatcherStack
from stacks.executor_stack import ExecutorStack
from stacks.state_stack import StateStack

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.yaml")


def build_stacks(app, cfg):
    env = cdk.Environment(account=os.environ.get("CDK_DEFAULT_ACCOUNT"), region=cfg["region"])

    state = StateStack(app, "CodeupKiroState", cfg=cfg, env=env)
    executor = ExecutorStack(app, "CodeupKiroExecutor", cfg=cfg, state=state, env=env)

    dispatcher_cfg = dict(cfg)
    dispatcher_cfg.setdefault("bot_usernames", [cfg["bot_username"]])
    dispatcher_cfg.setdefault("command_phrase", "/kiro review")
    dispatcher_cfg.setdefault("target_branch_filter", "")
    dispatcher_cfg.setdefault("lock_ttl_seconds", 86400)
    dispatcher_cfg.setdefault("reserved_concurrency", 5)
    # 这几项由 ExecutorStack 的真实资源覆盖——不是 config.yaml 的字段，config.yaml 写了也不算，
    # 调度器必须打到刚刚创建的那个集群/任务定义/安全组上，不能是使用者随手填的字符串。
    dispatcher_cfg["cluster"] = executor.cluster.cluster_name
    dispatcher_cfg["task_definition"] = executor.task_definition.family
    dispatcher_cfg["container_name"] = executor.container_name
    dispatcher_cfg["subnets"] = [s.subnet_id for s in executor.vpc.public_subnets]
    dispatcher_cfg["security_groups"] = [executor.task_security_group.security_group_id]

    dispatcher = DispatcherStack(
        app, "CodeupKiroDispatcher", cfg=dispatcher_cfg, state=state, executor=executor, env=env)
    dispatcher.add_stack_dependency(executor)
    return state, executor, dispatcher


def main(config_path=CONFIG_PATH):
    app = cdk.App()
    if os.path.exists(config_path):
        build_stacks(app, load_config(config_path))
    app.synth()
    return app


if __name__ == "__main__":
    main()
