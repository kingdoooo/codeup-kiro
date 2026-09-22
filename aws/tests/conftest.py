import pathlib
import sys

import pytest
import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


@pytest.fixture
def write_cfg(tmp_path):
    """把 dict 写成 config.yaml 并返回路径。"""
    def _write(cfg):
        p = tmp_path / "config.yaml"
        p.write_text(yaml.safe_dump(cfg))
        return str(p)
    return _write


def _full_cfg(**over):
    """调度器运行时用的完整配置，Task 7 / Task 11 的用例共用。"""
    cfg = {
        "region": "us-west-2", "org_id": "o1", "bot_username": "aliyun:kirobot",
        "bot_usernames": ["aliyun:kirobot"],
        "inline_comment": 0, "review_command": 1,
        "command_phrase": "/kiro review", "target_branch_filter": "",
        "cluster": "c", "task_definition": "td", "container_name": "review",
        "subnets": ["s1"], "security_groups": ["sg1"],
        "lock_ttl_seconds": 86400, "codeup_token": "t0ken",
        "reserved_concurrency": 5,
        "ephemeral_storage_gib": 50, "cpu": 2048, "memory_mib": 8192,
    }
    cfg.update(over)
    return cfg


import builtins  # noqa: E402  — 让三个测试文件都能直接用，不必各自导入
builtins._full_cfg = _full_cfg
