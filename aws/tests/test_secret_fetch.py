"""调用时取密钥（Ruling 16）：lambda/dispatcher/secret_fetch.py 的行为约定。

两个 Lambda 共用这一份助手，所以它的失败语义是两条 fail-closed 路径的共同前提：取不到密钥必须抛
SecretUnavailable（绝不返回空串让调用方当成「密钥就是空的」），而失败绝不进缓存——否则一次限流会
把这个执行环境钉死在失败态直到它被回收，期间每个 webhook 都被拒。

这里加载的是与两个 handler **不同**的一份模块实例（load_lambda 不进 sys.modules），所以本文件
折腾 _CACHE 不会影响 test_dispatcher / test_backstop 里那份。
"""
import os
import pathlib
import sys
from unittest import mock

import botocore.exceptions as bexc
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lambda" / "dispatcher"))
fetch = load_lambda("secret_fetch_helper", ROOT / "lambda" / "dispatcher" / "secret_fetch.py")

ARN = "arn:aws:secretsmanager:us-west-2:111122223333:secret:codeup-kiro/webhook-secret"
# 真的 ClientError，不是裸 Mock 的 side_effect：只用 Mock 造异常只能验证我们的 except 分支，
# 验不到「botocore 真抛出来的那种异常」也被同一条路径接住。正文刻意带账号 ID 与自由文本，
# 供下面那条「错误消息不得泄露它们」的断言使用。
DENIED = bexc.ClientError(
    {"Error": {"Code": "AccessDeniedException",
               "Message": ("User: arn:aws:sts::111122223333:assumed-role/DispatcherRole/x is not "
                           f"authorized to perform: secretsmanager:GetSecretValue on {ARN}")}},
    "GetSecretValue")


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    fetch._CACHE.clear()
    monkeypatch.delenv("WEBHOOK_SECRET_ARN", raising=False)
    yield
    fetch._CACHE.clear()


def _boto3(monkeypatch, *responses):
    """把 secret_fetch.py 里那句函数内部 `import boto3` 换成打桩客户端；返回它以便断言请求形状。"""
    client = mock.Mock()
    client.get_secret_value.side_effect = list(responses)
    boto3 = mock.Mock()
    boto3.client.return_value = client
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    return client


def test_returns_the_secret_string_and_asks_for_exactly_the_arn_in_the_env(monkeypatch):
    monkeypatch.setenv("WEBHOOK_SECRET_ARN", ARN)
    client = _boto3(monkeypatch, {"SecretString": "s3cret"})
    assert fetch.secret_from_env("WEBHOOK_SECRET_ARN") == "s3cret"
    # 断言请求形状，不只断言「抛/不抛」：把 ARN 拼错、或把变量名本身当 SecretId 传进去，
    # 都只会在部署后报 ResourceNotFound，单测里除了这条没有别的地方能接住。
    assert client.get_secret_value.call_args.kwargs == {"SecretId": ARN}
    assert fetch._CACHE == {ARN: "s3cret"}


def test_value_is_cached_per_process_so_a_warm_invocation_does_not_call_aws(monkeypatch):
    monkeypatch.setenv("WEBHOOK_SECRET_ARN", ARN)
    client = _boto3(monkeypatch, {"SecretString": "s3cret"}, {"SecretString": "changed"})
    assert fetch.secret_from_env("WEBHOOK_SECRET_ARN") == "s3cret"
    assert fetch.secret_from_env("WEBHOOK_SECRET_ARN") == "s3cret"
    assert client.get_secret_value.call_count == 1


def test_a_failed_fetch_is_not_cached_so_the_next_invocation_retries(monkeypatch):
    # 控制器裁决 1：失败不入缓存。第一次失败、第二次成功必须真的拿到值。
    monkeypatch.setenv("WEBHOOK_SECRET_ARN", ARN)
    client = _boto3(monkeypatch, DENIED, {"SecretString": "s3cret"})
    with pytest.raises(fetch.SecretUnavailable):
        fetch.secret_from_env("WEBHOOK_SECRET_ARN")
    assert fetch._CACHE == {}, "失败绝不入缓存"
    assert fetch.secret_from_env("WEBHOOK_SECRET_ARN") == "s3cret"
    assert client.get_secret_value.call_count == 2


@pytest.mark.parametrize("resp", [{"SecretString": ""}, {}, {"SecretBinary": b"\x00\x01"}])
def test_empty_or_binary_only_secret_fails_closed_and_is_not_cached(resp, monkeypatch):
    # 空 SecretString、根本没有 SecretString、只有 SecretBinary——三种都算「没取到」。
    # 让空值往下走会把「密钥建错了」显示成「对方令牌不对」。
    monkeypatch.setenv("WEBHOOK_SECRET_ARN", ARN)
    client = _boto3(monkeypatch, resp, {"SecretString": "s3cret"})
    with pytest.raises(fetch.SecretUnavailable):
        fetch.secret_from_env("WEBHOOK_SECRET_ARN")
    assert fetch._CACHE == {}
    assert fetch.secret_from_env("WEBHOOK_SECRET_ARN") == "s3cret"
    assert client.get_secret_value.call_count == 2


@pytest.mark.parametrize("value", [None, ""])
def test_missing_or_empty_env_var_fails_closed_without_calling_aws(value, monkeypatch):
    # 「falsy 但有意义」（控制器裁决 3）：WEBHOOK_SECRET_ARN="" 是配置错误，不得退化成任何默认值，
    # 也不该白跑一次 GetSecretValue。
    if value is not None:
        monkeypatch.setenv("WEBHOOK_SECRET_ARN", value)
    client = _boto3(monkeypatch, {"SecretString": "s3cret"})
    with pytest.raises(fetch.SecretUnavailable):
        fetch.secret_from_env("WEBHOOK_SECRET_ARN")
    assert not client.get_secret_value.called, "变量缺失或为空串时连 API 都不该调"
    assert fetch._CACHE == {}


def test_a_blank_but_non_empty_arn_still_fails_closed(monkeypatch):
    # 只有空白字符的 ARN 是真值，会被送去 GetSecretValue（AWS 自己拒）；这里钉住它最终仍然拒绝，
    # 不会因为「API 调过了」就被当成取到了密钥。
    monkeypatch.setenv("WEBHOOK_SECRET_ARN", "   ")
    _boto3(monkeypatch, bexc.ClientError(
        {"Error": {"Code": "ValidationException"}}, "GetSecretValue"))
    with pytest.raises(fetch.SecretUnavailable):
        fetch.secret_from_env("WEBHOOK_SECRET_ARN")
    assert fetch._CACHE == {}


def test_never_writes_the_value_into_os_environ(monkeypatch):
    monkeypatch.setenv("WEBHOOK_SECRET_ARN", ARN)
    _boto3(monkeypatch, {"SecretString": "s3cret"})
    before = dict(os.environ)
    assert fetch.secret_from_env("WEBHOOK_SECRET_ARN") == "s3cret"
    assert dict(os.environ) == before, "回写环境变量等于把刚消除的暴露面原地重建"
    assert "s3cret" not in " ".join(os.environ.values())


def test_the_error_carries_only_the_var_name_never_the_aws_message(monkeypatch):
    # 与 handler.py 的 _failure_reason 同一条理由：GetSecretValue 的错误正文是自由文本，
    # 带调用方角色 ARN 与账号 ID。异常消息会进日志、也可能被调用方拼进响应。
    monkeypatch.setenv("WEBHOOK_SECRET_ARN", ARN)
    _boto3(monkeypatch, DENIED)
    with pytest.raises(fetch.SecretUnavailable) as ei:
        fetch.secret_from_env("WEBHOOK_SECRET_ARN")
    msg = str(ei.value)
    assert msg == "WEBHOOK_SECRET_ARN", msg
    assert "111122223333" not in msg and "not authorized" not in msg, msg
    # 原始异常仍挂在 __cause__ 上供排查，且仍是那个真实的 ClientError
    assert isinstance(ei.value.__cause__, bexc.ClientError)


def test_two_different_arns_do_not_share_one_cache_entry(monkeypatch):
    other = ARN.replace("webhook-secret", "yunxiao-token-kiro")
    monkeypatch.setenv("WEBHOOK_SECRET_ARN", ARN)
    monkeypatch.setenv("YUNXIAO_TOKEN_ARN", other)
    _boto3(monkeypatch, {"SecretString": "s3cret"}, {"SecretString": "pt-t0ken"})
    assert fetch.secret_from_env("WEBHOOK_SECRET_ARN") == "s3cret"
    assert fetch.secret_from_env("YUNXIAO_TOKEN_ARN") == "pt-t0ken"
    assert fetch._CACHE == {ARN: "s3cret", other: "pt-t0ken"}


def test_no_lambda_source_writes_into_os_environ():
    """静态守卫：遍历 lambda/ 下**全部**源文件，不点名两个 handler。

    新增 Lambda 或新增取密钥的调用点时，「把取到的值塞回 os.environ 省事」是最自然的退化写法，
    而它恰好把本波消除的暴露面（函数配置里的明文）原地重建成另一种形式。
    """
    import ast
    srcs = sorted((ROOT / "lambda").rglob("*.py"))
    assert len(srcs) >= 5, srcs
    for p in srcs:
        for node in ast.walk(ast.parse(p.read_text())):
            if isinstance(node, ast.Assign):
                for t in node.targets:
                    bad = (isinstance(t, ast.Subscript) and isinstance(t.value, ast.Attribute)
                           and t.value.attr == "environ")
                    assert not bad, f"{p.name}:{node.lineno} 往 os.environ 写值"
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                base, attr = node.func.value, node.func.attr
                bad = ((isinstance(base, ast.Attribute) and base.attr == "environ"
                        and attr in ("update", "setdefault", "pop"))
                       or (isinstance(base, ast.Name) and base.id == "os" and attr == "putenv"))
                assert not bad, f"{p.name}:{node.lineno} 改写 os.environ（{attr}）"
