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

# 环境变量里放的是**密钥名**（GetSecretValue 的 SecretId 接受 ARN 或名字），不是 partial ARN
# ——理由见 secret_fetch.py 顶部（名字以「连字符 + 六字符」结尾时 partial ARN 会解析错）。
SECRET_ID = "codeup-kiro/webhook-secret"
# AWS 的错误正文里回显的是完整 ARN，下面那条「消息不得泄露账号 ID」的断言要的就是这种真实形状。
FULL_ARN = "arn:aws:secretsmanager:us-west-2:111122223333:secret:" + SECRET_ID + "-AbCdEf"
# 真的 ClientError，不是裸 Mock 的 side_effect：只用 Mock 造异常只能验证我们的 except 分支，
# 验不到「botocore 真抛出来的那种异常」也被同一条路径接住。正文刻意带账号 ID 与自由文本，
# 供下面那条「错误消息不得泄露它们」的断言使用。
DENIED = bexc.ClientError(
    {"Error": {"Code": "AccessDeniedException",
               "Message": ("User: arn:aws:sts::111122223333:assumed-role/DispatcherRole/x is not "
                           f"authorized to perform: secretsmanager:GetSecretValue on {FULL_ARN}")}},
    "GetSecretValue")


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    fetch._CACHE.clear()
    monkeypatch.delenv("WEBHOOK_SECRET_ID", raising=False)
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


def test_returns_the_secret_string_and_asks_for_exactly_the_secret_id_in_the_env(monkeypatch):
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    client = _boto3(monkeypatch, {"SecretString": "s3cret"})
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "s3cret"
    # 断言请求形状，不只断言「抛/不抛」：把 SECRET_ID 拼错、或把变量名本身当 SecretId 传进去，
    # 都只会在部署后报 ResourceNotFound，单测里除了这条没有别的地方能接住。
    assert client.get_secret_value.call_args.kwargs == {"SecretId": SECRET_ID}
    assert _cached() == {SECRET_ID: "s3cret"}


def _cached():
    """缓存里的值（不含取到的时刻）：缓存项是 (value, 单调钟, 墙钟)，issue 05 G2。"""
    return {k: e[0] for k, e in fetch._CACHE.items()}


def _frozen_clock(monkeypatch, start=1000.0, wall=None):
    """冻结 secret_fetch 自己看到的两个时钟（只换它模块里的 time，不动全局）。返回可改的 [now]；
    传了 wall（可改的 [t]）就让墙钟单独走，否则墙钟跟着 now 走。"""
    import types
    now = [start]
    monkeypatch.setattr(fetch, "time", types.SimpleNamespace(
        monotonic=lambda: now[0], time=(lambda: wall[0]) if wall is not None else (lambda: now[0] + 1.7e9)))
    return now


def test_a_cached_value_is_refetched_once_the_ttl_has_passed(monkeypatch):
    """issue 05 G2（s1 F3）：缓存以前永不过期，手册又教轮换令牌——轮换并吊销旧值之后，热执行环境一直用旧值
    （兜底 401 → 异步重试多半落在同一个热环境 → 进队列；按手册同步回放也可能落在那里，同样失败）。
    冻结时钟、逐字断言调用次数：只断言「过了很久会重取」的话，TTL 写成一小时也能过。"""
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    client = _boto3(monkeypatch, {"SecretString": "old"}, {"SecretString": "new"})
    now = _frozen_clock(monkeypatch)
    assert fetch.CACHE_TTL_SECONDS == 300
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "old"
    now[0] = 1000.0 + 299.999
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "old"
    assert client.get_secret_value.call_count == 1, "TTL 之内不重取（正向对照）"
    now[0] = 1000.0 + 300
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "new"
    assert client.get_secret_value.call_count == 2
    now[0] = 1000.0 + 300 + 299
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "new"
    assert client.get_secret_value.call_count == 2, "重新计时从重取的那一刻算起"


def test_an_expired_entry_whose_refetch_fails_is_never_served_stale(monkeypatch):
    # 旧值在轮换场景下恰恰是错的：过期之后重取失败就照常抛，不回退到旧值，缓存里也不留它
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    _boto3(monkeypatch, {"SecretString": "old"}, DENIED)
    now = _frozen_clock(monkeypatch)
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "old"
    now[0] += 300
    with pytest.raises(fetch.SecretUnavailable):
        fetch.secret_from_env("WEBHOOK_SECRET_ID")
    assert fetch._CACHE == {}


def test_a_frozen_monotonic_clock_still_expires_the_entry_by_the_wall_clock(monkeypatch):
    """review-B N-7：Lambda 冻结执行环境期间单调钟是否前进没有第一手证据。单调钟停着、墙钟走满 300 s
    也必须重取；墙钟往回拨 300 s 同样重取（只会提前、多取一次）。"""
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    client = _boto3(monkeypatch, {"SecretString": "old"}, {"SecretString": "new"}, {"SecretString": "newer"})
    wall = [5000.0]
    _frozen_clock(monkeypatch, wall=wall)
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "old"
    wall[0] += 299
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "old"
    assert client.get_secret_value.call_count == 1
    wall[0] += 1
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "new"
    wall[0] -= 300
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "newer"
    assert client.get_secret_value.call_count == 3


def test_a_frozen_wall_clock_still_expires_the_entry_by_the_monotonic_clock(monkeypatch):
    # 收口复审 R-3：墙钟停着（或被拨回原处）、单调钟走满 300 s 也必须重取——另一臂不能替这一臂作证
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    client = _boto3(monkeypatch, {"SecretString": "old"}, {"SecretString": "new"})
    now = _frozen_clock(monkeypatch, wall=[5000.0])
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "old"
    now[0] += 299.999
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "old"
    now[0] += 0.001
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "new"
    assert client.get_secret_value.call_count == 2


def test_value_is_cached_per_process_so_a_warm_invocation_does_not_call_aws(monkeypatch):
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    client = _boto3(monkeypatch, {"SecretString": "s3cret"}, {"SecretString": "changed"})
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "s3cret"
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "s3cret"
    assert client.get_secret_value.call_count == 1


def test_a_failed_fetch_is_not_cached_so_the_next_invocation_retries(monkeypatch):
    # 控制器裁决 1：失败不入缓存。第一次失败、第二次成功必须真的拿到值。
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    client = _boto3(monkeypatch, DENIED, {"SecretString": "s3cret"})
    with pytest.raises(fetch.SecretUnavailable):
        fetch.secret_from_env("WEBHOOK_SECRET_ID")
    assert fetch._CACHE == {}, "失败绝不入缓存"
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "s3cret"
    assert client.get_secret_value.call_count == 2


@pytest.mark.parametrize("resp", [{"SecretString": ""}, {}, {"SecretBinary": b"\x00\x01"}])
def test_empty_or_binary_only_secret_fails_closed_and_is_not_cached(resp, monkeypatch):
    # 空 SecretString、根本没有 SecretString、只有 SecretBinary——三种都算「没取到」。
    # 让空值往下走会把「密钥建错了」显示成「对方令牌不对」。
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    client = _boto3(monkeypatch, resp, {"SecretString": "s3cret"})
    with pytest.raises(fetch.SecretUnavailable):
        fetch.secret_from_env("WEBHOOK_SECRET_ID")
    assert fetch._CACHE == {}
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "s3cret"
    assert client.get_secret_value.call_count == 2


@pytest.mark.parametrize("value", [None, ""])
def test_missing_or_empty_env_var_fails_closed_without_calling_aws(value, monkeypatch):
    # 「falsy 但有意义」（控制器裁决 3）：WEBHOOK_SECRET_ID="" 是配置错误，不得退化成任何默认值，
    # 也不该白跑一次 GetSecretValue。
    if value is not None:
        monkeypatch.setenv("WEBHOOK_SECRET_ID", value)
    client = _boto3(monkeypatch, {"SecretString": "s3cret"})
    with pytest.raises(fetch.SecretUnavailable):
        fetch.secret_from_env("WEBHOOK_SECRET_ID")
    assert not client.get_secret_value.called, "变量缺失或为空串时连 API 都不该调"
    assert fetch._CACHE == {}


def test_a_blank_but_non_empty_secret_id_still_fails_closed(monkeypatch):
    # 只有空白字符的 SECRET_ID 是真值，会被送去 GetSecretValue（AWS 自己拒）；这里钉住它最终仍然拒绝，
    # 不会因为「API 调过了」就被当成取到了密钥。
    monkeypatch.setenv("WEBHOOK_SECRET_ID", "   ")
    _boto3(monkeypatch, bexc.ClientError(
        {"Error": {"Code": "ValidationException"}}, "GetSecretValue"))
    with pytest.raises(fetch.SecretUnavailable):
        fetch.secret_from_env("WEBHOOK_SECRET_ID")
    assert fetch._CACHE == {}


def test_never_writes_the_value_into_os_environ(monkeypatch):
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    _boto3(monkeypatch, {"SecretString": "s3cret"})
    before = dict(os.environ)
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "s3cret"
    assert dict(os.environ) == before, "回写环境变量等于把刚消除的暴露面原地重建"
    assert "s3cret" not in " ".join(os.environ.values())


def test_the_error_carries_only_the_var_name_never_the_aws_message(monkeypatch):
    # 与 handler.py 的 _failure_reason 同一条理由：GetSecretValue 的错误正文是自由文本，
    # 带调用方角色 ARN 与账号 ID。异常消息会进日志、也可能被调用方拼进响应。
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    _boto3(monkeypatch, DENIED)
    with pytest.raises(fetch.SecretUnavailable) as ei:
        fetch.secret_from_env("WEBHOOK_SECRET_ID")
    msg = str(ei.value)
    assert msg == "WEBHOOK_SECRET_ID", msg
    assert "111122223333" not in msg and "not authorized" not in msg, msg
    # 原始异常仍挂在 __cause__ 上供排查，且仍是那个真实的 ClientError
    assert isinstance(ei.value.__cause__, bexc.ClientError)


def test_two_different_secret_ids_do_not_share_one_cache_entry(monkeypatch):
    other = SECRET_ID.replace("webhook-secret", "yunxiao-token-kiro")
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    monkeypatch.setenv("YUNXIAO_TOKEN_ID", other)
    _boto3(monkeypatch, {"SecretString": "s3cret"}, {"SecretString": "pt-t0ken"})
    assert fetch.secret_from_env("WEBHOOK_SECRET_ID") == "s3cret"
    assert fetch.secret_from_env("YUNXIAO_TOKEN_ID") == "pt-t0ken"
    assert _cached() == {SECRET_ID: "s3cret", other: "pt-t0ken"}


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


# ── 有界超时（全分支复审 s1 F1）：一次卡住的 GetSecretValue 不得耗尽 29 s 的函数预算 ──────────
# botocore 缺省是连接/读各 60 s + legacy 重试（超时也重试），卡住一次 Lambda 就超时，调度器那行
# `secret-unavailable` 日志根本打不出来。下面第一条钉住配置的**数值**，第二条用**真的 botocore**
# 连一个接受连接却永不应答的本地端口，证明这份配置真的传给了客户端、真的生效（只断言 Config 对象
# 的话，「建了但没传进去」照样绿）。
import socket  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402

import bounded_config  # noqa: E402

LAMBDA_TIMEOUT = 29   # stacks/dispatcher_stack.py 两个函数的 timeout；下面那条断言会从模板里核对


def test_the_bounded_config_leaves_room_in_the_29_second_budget():
    cfg = bounded_config.client_config()
    assert cfg.connect_timeout == bounded_config.CONNECT_TIMEOUT == 2
    assert cfg.read_timeout == bounded_config.READ_TIMEOUT == 5
    # total_max_attempts（含首次）而不是 max_attempts（写在 Config 里时不含首次，boto3 retries 指南）
    assert cfg.retries == {"mode": "standard", "total_max_attempts": 2}, cfg.retries
    worst = bounded_config.worst_case_seconds()
    assert worst == 2 * (2 + 5) + 1 == 15
    # 一个服务卡住时，卡住的那次调用之后还要有时间把日志打出来 / 释放锁 + 发评论
    assert worst <= LAMBDA_TIMEOUT - 10, worst


def test_both_lambdas_really_run_with_a_29_second_timeout():
    # 上面的预算按 29 s 算；函数超时哪天被改大改小，这条先红，预算要跟着复核
    import aws_cdk as cdk
    from aws_cdk.assertions import Template
    from stacks.dispatcher_stack import DispatcherStack
    from stacks.executor_stack import ExecutorStack
    from stacks.state_stack import StateStack
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    executor = ExecutorStack(app, "E", cfg=_full_cfg(), state=state)
    t = Template.from_stack(DispatcherStack(app, "D", cfg=_full_cfg(), state=state, executor=executor))
    timeouts = {k: r["Properties"].get("Timeout") for k, r in t.find_resources("AWS::Lambda::Function").items()
                if k.startswith(("DispatcherFn", "BackstopFn"))}
    assert sorted(timeouts.values()) == [LAMBDA_TIMEOUT, LAMBDA_TIMEOUT], timeouts


class _SilentServer:
    """接受 TCP 连接但一个字节都不回；hold 秒之后关掉（没有配置时客户端就会卡满这段时间）。"""

    def __init__(self, hold):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.port = self.sock.getsockname()[1]
        self.accepted, self.hold, self._conns = 0, hold, []
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            self.accepted += 1
            self._conns.append(conn)
            threading.Timer(self.hold, conn.close).start()

    def close(self):
        self.sock.close()
        for c in self._conns:
            c.close()


@pytest.fixture
def silent_secrets_manager(monkeypatch):
    srv = _SilentServer(hold=4)
    monkeypatch.setenv("AWS_ENDPOINT_URL_SECRETS_MANAGER", f"http://127.0.0.1:{srv.port}")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "fake")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-west-2")
    for var in ("AWS_PROFILE", "AWS_SESSION_TOKEN", "AWS_RETRY_MODE", "AWS_MAX_ATTEMPTS"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("AWS_CONFIG_FILE", "/dev/null")
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", "/dev/null")
    # 生产值（2 + 5 s）×2 次要等 15 s；这里只把两个超时缩小，重试模式与次数保持生产值——
    # 要证明的是「这份配置真的传进了客户端」，数值本身由上面那条断言钉住。
    monkeypatch.setattr(bounded_config, "CONNECT_TIMEOUT", 0.3)
    monkeypatch.setattr(bounded_config, "READ_TIMEOUT", 0.3)
    yield srv
    srv.close()


def test_a_stalled_get_secret_value_fails_closed_within_the_bound_with_real_botocore(
        silent_secrets_manager, monkeypatch):
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    t0 = time.monotonic()
    with pytest.raises(fetch.SecretUnavailable) as ei:
        fetch.secret_from_env("WEBHOOK_SECRET_ID")
    elapsed = time.monotonic() - t0
    assert type(ei.value.__cause__).__name__ == "ReadTimeoutError", repr(ei.value.__cause__)
    # 缺省配置下这里要等满 hold（4 s）才被断开，然后 legacy 再重试几轮
    assert elapsed < 3, elapsed
    assert silent_secrets_manager.accepted == 2, "total_max_attempts=2：首次 + 一次重试"


def test_the_dispatcher_logs_secret_unavailable_and_answers_503_on_a_stall(
        silent_secrets_manager, monkeypatch, capsys):
    handler_mod = load_lambda("stall_dispatcher", ROOT / "lambda" / "dispatcher" / "handler.py")
    handler_mod.secret_fetch._CACHE.clear()
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    r = handler_mod.handler({"headers": {"x-codeup-token": "s3cret"}}, None)
    assert_alb_response(r, 503, "secret-unavailable")
    assert capsys.readouterr().out == \
        "secret-unavailable var=WEBHOOK_SECRET_ID code=ReadTimeoutError\n"
