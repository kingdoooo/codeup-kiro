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


import importlib.util  # noqa: E402


def load_lambda(module_name, path):
    """按文件路径加载 Lambda 模块，模块名由调用方指定。

    绝不用 importlib.import_module("handler")：两个 Lambda 的入口文件都叫 handler.py，
    裸名导入会命中 sys.modules 缓存、静默测到另一个 Lambda。
    """
    spec = importlib.util.spec_from_file_location(module_name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


builtins.load_lambda = load_lambda


def assert_alb_response(r, status, body):
    """ALB Lambda target 的完整响应形状（G5）。调度器每条返回路径、回显 Lambda 都用它断言。

    逐字段断言类型而不只断言「键存在」：isBase64Encoded 写成字符串 "false"、headers 写成列表，
    ALB 同样按畸形响应回 502。
    """
    from http import HTTPStatus
    assert set(r) == {"statusCode", "statusDescription", "isBase64Encoded", "headers", "body"}, r
    assert r["statusCode"] == status and type(r["statusCode"]) is int, r
    assert r["statusDescription"] == f"{status} {HTTPStatus(status).phrase}", r
    assert r["isBase64Encoded"] is False, r
    assert isinstance(r["headers"], dict) and r["headers"].get("Content-Type"), r
    assert all(isinstance(k, str) and isinstance(v, str) for k, v in r["headers"].items()), r
    assert r["body"] == body and isinstance(r["body"], str), r


builtins.assert_alb_response = assert_alb_response
