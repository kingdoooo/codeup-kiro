"""飞书通知 Lambda（aws/lambda/notifier/handler.py；Phase 2c issue 20，spec F4–F10、N-F1–N-F5）。

请求形状用本地 HTTP 替身（fake_notify_http.py）验：notifier 的 urllib 请求真的发出去，云效与飞书都只是替身——不靠 Mock 的 side_effect
证明请求发出（spec「测试与验收」）。密钥照 test_backstop.py 的做法：走真实的 secret_fetch.py，只把它内部那句 `import boto3` 换掉。
"""
import json
import pathlib
import socket
import sys
import time
from unittest import mock

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lambda" / "dispatcher"))
notifier = load_lambda("notifier_handler", ROOT / "lambda" / "notifier" / "handler.py")
import fake_notify_http  # noqa: E402

ORG = fake_notify_http.ORG
SHA = "a" * 40
PK = f"7215683#10#{SHA}"
CID = "0123456789abcdef0123456789abcdef"
KIRO_TOKEN = "pt-kiro-t0ken"
APP = {"app_id": "cli_fake", "app_secret": "s3cr3t-fake"}


@pytest.fixture
def fake(monkeypatch):
    srv = fake_notify_http.FakeNotify().start()
    monkeypatch.setattr(notifier, "CODEUP_API_BASE", srv.url + "/codeup")
    monkeypatch.setattr(notifier, "FEISHU_BASES", {"feishu": srv.url + "/feishu", "lark": srv.url + "/lark"})
    monkeypatch.setattr(notifier, "_TOKEN_CACHE", {})
    monkeypatch.setattr(notifier.time, "sleep", lambda s: None)
    secrets = {"codeup-kiro/yunxiao-token-kiro": KIRO_TOKEN, "codeup-kiro/feishu-app": json.dumps(APP)}
    client = mock.Mock()
    client.get_secret_value.side_effect = lambda SecretId: {"SecretString": secrets[SecretId]}
    boto3 = mock.Mock()
    boto3.client.return_value = client
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    monkeypatch.setattr(notifier.secret_fetch, "_CACHE", {})
    for k, v in (("YUNXIAO_ORG_ID", ORG), ("YUNXIAO_TOKEN_ID", "codeup-kiro/yunxiao-token-kiro"),
                 ("FEISHU_APP_SECRET_ID", "codeup-kiro/feishu-app"), ("FEISHU_DOMAIN", "feishu")):
        monkeypatch.setenv(k, v)
    srv.secrets, srv.client = secrets, client
    yield srv
    srv.stop()


def _img(**attrs):
    out = {"pk": {"S": attrs.pop("pk", PK)}}
    for k, v in attrs.items():
        out[k] = {"BOOL": v} if isinstance(v, bool) else {"S": v}
    return out


def _rec(new, old=None, event="MODIFY"):
    ddb = {"NewImage": new}
    if old is not None:
        ddb["OldImage"] = old
    return {"eventName": event, "dynamodb": ddb}


def _posted(rid="kiro", cid=CID, **old):
    return _rec(_img(**{f"posted_{rid}": True, f"comment_{rid}": cid}), _img(**old))


def _run(*records):
    return notifier.handler({"Records": list(records)}, None)


# ── Stream 事件的形状：只认 posted_<rid> 从无到有、且带合法评论 id 的那一次 MODIFY（N-F4）──────────────────────────
def test_posted_appearing_with_a_valid_comment_id_sends_one_message(fake, capsys):
    assert _run(_posted()) == {"ok": True}
    assert len(fake.sends()) == 1
    assert capsys.readouterr().out == "notify reviewer=kiro repo=7215683 mr=10 result=sent\n"


@pytest.mark.parametrize("record", [
    _rec(_img(posted_kiro=True, comment_kiro=CID), event="INSERT"),                       # 不是 MODIFY
    _rec(_img(posted_kiro=True, comment_kiro=CID), event="REMOVE"),
    _rec(_img(posted_kiro=True, comment_kiro=CID), _img(posted_kiro=True)),             # 之前就有 posted：不是这一次变化
    _rec(_img(posted_kiro=True), _img()),                                                # 没有评论 id
    _rec(_img(posted_kiro=False, comment_kiro=CID), _img()),                             # posted 不是 true
    _rec(_img(posted=True), _img()),                                                     # Kiro 的旧标记（引擎 rc=0），不是通知的信号
    _rec(_img(pk="lease#7215683#10", holder="x", lease_until="1"), _img(pk="lease#7215683#10")),   # 租约续期
    _rec(_img(dispatched_inspector=True), _img()),
], ids=["insert", "remove", "already-posted", "no-comment", "posted-false", "kiro-rc0-mark", "lease", "dispatched"])
def test_other_stream_shapes_send_nothing(fake, record, capsys):
    _run(record)
    assert fake.requests == [], fake.paths()
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize("bad", ["", "0123456789ABCDEF0123456789ABCDEF", CID[:-1], CID + "0", "../../x", CID[:31] + ")",
                                 "<at user_id=\"all\"></at>"])
def test_a_comment_id_that_is_not_32_lowercase_hex_sends_nothing(fake, bad):
    _run(_posted(cid=bad))
    assert fake.requests == []


def test_two_reviewers_posting_in_one_record_send_two_messages_with_distinct_uuids(fake):
    _run(_rec(_img(posted_inspector=True, comment_inspector=CID, posted_security=True, comment_security="f" * 32), _img()))
    sends = fake.sends()
    assert len(sends) == 2
    texts = [json.loads(b["content"])["text"] for _, _, _, b in sends]
    assert texts[0].startswith("Inspector 依赖漏洞扫描结束，请查阅：") and texts[1].startswith("Continuum 代码安全扫描结束，请查阅：")
    assert sends[0][3]["uuid"] != sends[1][3]["uuid"]


def test_a_malformed_lock_key_is_skipped_without_any_request(fake, capsys):
    _run(_rec(_img(pk="r1#7#abc", posted_kiro=True, comment_kiro=CID), _img(pk="r1#7#abc")))
    assert fake.requests == []
    assert capsys.readouterr().out == "notify result=skipped reason=bad-lock-key\n"


# ── 请求形状（真的 urllib）──────────────────────────────────────────────────────────────────────────────
def test_request_shapes_codeup_with_the_kiro_token_then_feishu_token_then_message(fake):
    _run(_posted(rid="security"))
    (m1, p1, h1, _), (m2, p2, _, b2), (m3, p3, h3, b3) = fake.requests
    assert (m1, p1) == ("GET", f"/codeup/oapi/v1/codeup/organizations/{ORG}/repositories/7215683/changeRequests/10")
    assert h1["x-yunxiao-token"] == KIRO_TOKEN
    assert (m2, p2, b2) == ("POST", "/feishu/open-apis/auth/v3/tenant_access_token/internal", APP)
    assert (m3, p3) == ("POST", "/feishu/open-apis/im/v1/messages?receive_id_type=email")
    assert h3["authorization"] == "Bearer t-fake-tenant"
    link = f"https://codeup.aliyun.com/{ORG}/demo-app/change/10?comment={CID}"
    assert b3 == {"receive_id": "dev@example.com", "msg_type": "text", "uuid": notifier.message_uuid(PK, "security"),
                  "content": json.dumps({"text": f"Continuum 代码安全扫描结束，请查阅：[{link}]({link})"}, ensure_ascii=False)}
    # 只读了这两个密钥：Kiro 机器人的云效令牌与飞书应用（N-F1 的 Lambda 这一侧）
    assert sorted(c.kwargs["SecretId"] for c in fake.client.get_secret_value.call_args_list) == \
        ["codeup-kiro/feishu-app", "codeup-kiro/yunxiao-token-kiro"]


@pytest.mark.parametrize("rid,text", [("kiro", "Kiro 评审结束，请查阅："), ("inspector", "Inspector 依赖漏洞扫描结束，请查阅："),
                                      ("security", "Continuum 代码安全扫描结束，请查阅：")])
def test_each_reviewer_gets_its_fixed_text_and_nothing_else(fake, rid, text):
    _run(_posted(rid=rid))
    (_, _, _, body), = fake.sends()
    link = f"https://codeup.aliyun.com/{ORG}/demo-app/change/10?comment={CID}"
    assert json.loads(body["content"]) == {"text": f"{text}[{link}]({link})"}


def test_the_lark_platform_uses_the_lark_domain(fake, monkeypatch):
    monkeypatch.setenv("FEISHU_DOMAIN", "lark")
    _run(_posted())
    assert [p.split("/")[1] for p in fake.paths()] == ["codeup", "lark", "lark"]


def test_the_uuid_is_stable_per_review_and_reviewer_and_fits_feishus_50_characters():
    a, b = notifier.message_uuid(PK, "kiro"), notifier.message_uuid(PK, "kiro")
    assert a == b and len(a) <= 50 and a.isalnum()
    assert notifier.message_uuid(PK, "inspector") != a
    assert notifier.message_uuid(PK + "#" + "c" * 32, "kiro") != a   # 评论命令触发的那次评审是另一把锁、另一个 uuid


def test_a_replayed_record_reuses_the_same_uuid_so_feishu_drops_the_duplicate(fake):
    _run(_posted())
    _run(_posted())
    u = [b["uuid"] for _, _, _, b in fake.sends()]
    assert len(u) == 2 and u[0] == u[1]


def test_the_tenant_token_is_cached_within_an_execution_environment(fake):
    _run(_posted(rid="inspector"), _posted(rid="security"))
    assert sum("tenant_access_token" in p for p in fake.paths()) == 1
    assert len(fake.sends()) == 2


# ── N-F5：占位 / 空邮箱永不发送 ─────────────────────────────────────────────────────────────────────────────
@pytest.mark.parametrize("email", ["", "  ", "accounts_6a5ede93bdf2b6df65dec432@mail.teambition.com",
                                   "ACCOUNTS_X@MAIL.TEAMBITION.COM", None, 42])
def test_a_placeholder_or_empty_email_sends_nothing_and_says_why(fake, email, capsys):
    fake.change_request["author"]["email"] = email
    _run(_posted())
    assert [p.split("/")[1] for p in fake.paths()] == ["codeup"], "不取飞书令牌、不发消息"
    assert capsys.readouterr().out == "notify reviewer=kiro repo=7215683 mr=10 result=skipped reason=no-email\n"


# ── N-F3：正文只有固定文案 + 校验过的链接（注入用例）─────────────────────────────────────────────────────────
def test_untrusted_mr_fields_never_reach_the_message(fake):
    fake.change_request.update(title="<at user_id=\"all\"></at> [点我](https://evil.example)",
                               sourceBranch="x](https://evil.example)", description="**钓鱼**")
    _run(_posted())
    (_, _, _, body), = fake.sends()
    text = json.loads(body["content"])["text"]
    for needle in ("evil", "<at", "钓鱼", "点我"):
        assert needle not in text, needle


@pytest.mark.parametrize("url", [
    f"https://codeup.aliyun.com/{ORG}/demo-app/change/11",                      # 别的 MR
    "https://codeup.aliyun.com/other-org/demo-app/change/10",                  # 别的组织
    f"https://evil.example/{ORG}/demo-app/change/10",
    f"http://codeup.aliyun.com/{ORG}/demo-app/change/10",
    f"https://codeup.aliyun.com/{ORG}/demo-app/change/10)](https://evil.example",
    f"https://codeup.aliyun.com/{ORG}/demo app/change/10",
    f"https://codeup.aliyun.com/{ORG}/demo-app/change/10?x=1",
    f"https://codeup.aliyun.com/{ORG}/change/10",
    "", None])
def test_a_detail_url_that_is_not_this_mrs_page_sends_nothing(fake, url, capsys):
    fake.change_request["detailUrl"] = url
    _run(_posted())
    assert fake.sends() == []
    assert capsys.readouterr().out.endswith("result=skipped reason=bad-url\n")


# ── F9：任何失败只记一行带错误码的日志，不抛、不改任何东西 ───────────────────────────────────────────────────────
@pytest.mark.parametrize("code", [230013, 230038, 230029, 230053])
def test_a_feishu_send_error_is_logged_with_its_code_and_not_retried(fake, code, capsys):
    fake.send_replies = [(400, {"code": code, "msg": "x dev@example.com"}, {})]
    assert _run(_posted()) == {"ok": True}
    assert len(fake.sends()) == 1, "不重试"
    out = capsys.readouterr().out
    assert out == f"notify reviewer=kiro repo=7215683 mr=10 result=failed step=send code=feishu-{code}\n"


def test_rate_limiting_waits_for_the_reset_header_and_retries_once(fake, monkeypatch, capsys):
    slept = []
    monkeypatch.setattr(notifier.time, "sleep", lambda s: slept.append(s))
    fake.send_replies = [(429, {"code": 99991400, "msg": "rate"}, {"x-ogw-ratelimit-reset": "2"})]
    _run(_posted())
    assert len(fake.sends()) == 2 and slept == [2]
    assert capsys.readouterr().out.endswith("result=sent\n")


def test_the_per_recipient_frequency_limit_230020_is_retried_once_after_a_second(fake, monkeypatch, capsys):
    # 飞书对同一收件人 5 QPS：同一位作者在同一秒收到两条（两位评审员同时结束）时，第二条回 HTTP 400 + 230020，通常没有 reset 头
    slept = []
    monkeypatch.setattr(notifier.time, "sleep", lambda s: slept.append(s))
    fake.send_replies = [(400, {"code": 230020, "msg": "frequency limited"}, {})]
    _run(_posted())
    assert len(fake.sends()) == 2 and slept == [1]
    assert capsys.readouterr().out.endswith("result=sent\n")


def test_rate_limiting_that_outlasts_the_one_retry_is_logged_and_not_retried_again(fake, monkeypatch, capsys):
    monkeypatch.setattr(notifier.time, "sleep", lambda s: None)
    fake.send_replies = [(400, {"code": 230020}, {}), (400, {"code": 230020}, {})]
    _run(_posted())
    assert len(fake.sends()) == 2
    assert capsys.readouterr().out == "notify reviewer=kiro repo=7215683 mr=10 result=failed step=send code=feishu-230020\n"


def test_rate_limiting_never_waits_longer_than_the_cap(fake, monkeypatch):
    slept = []
    monkeypatch.setattr(notifier.time, "sleep", lambda s: slept.append(s))
    fake.send_replies = [(429, {"code": 99991400}, {"x-ogw-ratelimit-reset": "3600"}),
                         (429, {"code": 99991400}, {"x-ogw-ratelimit-reset": "3600"})]
    _run(_posted())
    assert slept == [notifier.RATE_LIMIT_MAX_WAIT] and len(fake.sends()) == 2


def test_an_expired_tenant_token_is_refetched_once(fake):
    fake.send_replies = [(400, {"code": 99991663, "msg": "invalid token"}, {})]
    _run(_posted())
    assert sum("tenant_access_token" in p for p in fake.paths()) == 2 and len(fake.sends()) == 2


def test_a_wrong_app_secret_is_logged_and_nothing_is_sent(fake, capsys):
    # sandbox 2026-10-10 实测：app_secret 写错时 tenant_access_token/internal 返回 code 10014（不是通用错误码表里「App Secret 错误」的 10015）
    fake.token_reply = {"code": 10014}
    _run(_posted())
    assert fake.sends() == []
    assert capsys.readouterr().out == "notify reviewer=kiro repo=7215683 mr=10 result=failed step=token code=feishu-10014\n"


@pytest.mark.parametrize("status", [401, 403, 404, 429, 500])
def test_a_failed_get_change_request_is_logged_and_feishu_is_never_called(fake, status, capsys):
    fake.change_request_status = status
    _run(_posted())
    assert [p.split("/")[1] for p in fake.paths()] == ["codeup"]
    assert capsys.readouterr().out == f"notify reviewer=kiro repo=7215683 mr=10 result=failed step=codeup code=http-{status}\n"


@pytest.mark.parametrize("raw", ["not json", json.dumps({"app_id": "x"}), json.dumps(["x"])])
def test_a_malformed_feishu_secret_is_logged_as_bad_shape(fake, raw, capsys):
    fake.secrets["codeup-kiro/feishu-app"] = raw
    _run(_posted())
    assert fake.sends() == []
    assert capsys.readouterr().out.endswith("result=failed step=secret code=bad-shape\n")


def test_an_unreachable_upstream_is_logged_as_network(fake, monkeypatch, capsys):
    monkeypatch.setattr(notifier, "CODEUP_API_BASE", "http://127.0.0.1:9")   # discard 端口：连接被拒
    _run(_posted())
    assert capsys.readouterr().out.endswith("result=failed step=codeup code=network\n")


# ── 终审 M-5：每条通知一个总时限（NOTIFY_BUDGET）；用完记 code=deadline、这一条不再试 ─────────────────────────────────────
# sandbox 2026-10-10：一个执行环境连不上云效时一次请求约 120 秒（OpenAPI 解析出 12 个地址，urllib 逐个试、每个 10 秒）；批 1、一个分片，
# 后面的记录全排在它后面。用例把时限缩到 1 秒以内、上游的慢由 HTTP 替身的 delays 或下面的 blackhole 给。
def _timed(*records):
    t0 = time.monotonic()
    _run(*records)
    return time.monotonic() - t0


def test_a_slow_upstream_ends_the_notification_at_its_budget(fake, monkeypatch, capsys):
    monkeypatch.setattr(notifier, "NOTIFY_BUDGET", 1.0, raising=False)
    fake.delays["/codeup/"] = 3
    took = _timed(_posted())
    assert capsys.readouterr().out == "notify reviewer=kiro repo=7215683 mr=10 result=failed step=codeup code=deadline\n"
    assert took < 2, took
    assert [p.split("/")[1] for p in fake.paths()] == ["codeup"], "用完时限就不再取飞书令牌、不发消息"


def test_the_budget_covers_the_whole_notification_not_each_request(fake, monkeypatch, capsys):
    # 云效与取令牌各 0.6 秒：单看都在每次 socket 操作的超时之内，合起来超过 1 秒的总时限 → 停在取令牌那一步
    monkeypatch.setattr(notifier, "NOTIFY_BUDGET", 1.0, raising=False)
    fake.delays.update({"/codeup/": 0.6, "tenant_access_token": 0.6})
    took = _timed(_posted())
    assert capsys.readouterr().out == "notify reviewer=kiro repo=7215683 mr=10 result=failed step=token code=deadline\n"
    assert took < 1.6, took
    assert fake.sends() == []


def test_each_notification_in_a_record_gets_its_own_budget(fake, monkeypatch, capsys):
    monkeypatch.setattr(notifier, "NOTIFY_BUDGET", 1.0, raising=False)
    fake.delays["/codeup/"] = 0.6
    _run(_rec(_img(posted_inspector=True, comment_inspector=CID, posted_security=True, comment_security="f" * 32), _img()))
    assert capsys.readouterr().out.splitlines() == ["notify reviewer=inspector repo=7215683 mr=10 result=sent",
                                                    "notify reviewer=security repo=7215683 mr=10 result=sent"]


def test_a_rate_limit_wait_never_outlasts_the_budget(fake, monkeypatch, capsys):
    slept = []
    monkeypatch.setattr(notifier.time, "sleep", lambda s: slept.append(s))
    monkeypatch.setattr(notifier, "NOTIFY_BUDGET", 1.0, raising=False)
    fake.send_replies = [(429, {"code": 99991400}, {"x-ogw-ratelimit-reset": "3"})]
    _run(_posted())
    assert len(slept) == 1 and 0 <= slept[0] <= 1.0, slept
    assert capsys.readouterr().out.endswith("result=sent\n")


BLACKHOLE = "blackhole.invalid"
_real_sleep = time.sleep   # fake 夹具把 time.sleep 换成了空操作；这里的连接替身要真睡


@pytest.fixture
def blackhole(monkeypatch):
    """BLACKHOLE 解析出 12 个地址（云效 OpenAPI 实测就是 12 个），每个都要等满连接超时才失败。socket.create_connection 的替身照标准库的
    行为：给主机名 → 逐个地址试、每个地址都套**完整的**超时（120 秒就是这么来的）；给地址 → 睡满超时、TimeoutError。返回每次连接的超时。"""
    real_gai, real_cc = socket.getaddrinfo, socket.create_connection
    ips = [f"192.0.2.{i}" for i in range(1, 13)]
    tried = []

    def gai(host, port, *a, **kw):
        if host == BLACKHOLE:
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port)) for ip in ips]
        return real_gai(host, port, *a, **kw)

    def cc(address, timeout=socket._GLOBAL_DEFAULT_TIMEOUT, source_address=None, **kw):
        host, port = address[:2]
        if host == BLACKHOLE:
            err = None
            for *_, sa in gai(host, port):
                try:
                    return cc(sa, timeout, source_address)
                except OSError as exc:
                    err = exc
            raise err
        if host in ips:
            tried.append(timeout)
            _real_sleep(timeout)
            raise TimeoutError("timed out")
        return real_cc(address, timeout, source_address, **kw)

    monkeypatch.setattr(socket, "getaddrinfo", gai)
    monkeypatch.setattr(socket, "create_connection", cc)
    return tried


@pytest.mark.parametrize("scheme", ["http", "https"])
def test_connecting_stops_trying_addresses_once_the_budget_is_spent(fake, blackhole, monkeypatch, capsys, scheme):
    monkeypatch.setattr(notifier, "NOTIFY_BUDGET", 0.5, raising=False)
    monkeypatch.setattr(notifier, "HTTP_TIMEOUT", 0.2)
    monkeypatch.setattr(notifier, "CODEUP_API_BASE", f"{scheme}://{BLACKHOLE}")
    took = _timed(_posted())
    assert capsys.readouterr().out == "notify reviewer=kiro repo=7215683 mr=10 result=failed step=codeup code=deadline\n"
    assert took < 1.0, took
    assert 1 <= len(blackhole) <= 3 and max(blackhole) <= 0.2, blackhole


def test_an_unexpected_bug_is_contained_per_message(fake, monkeypatch, capsys):
    monkeypatch.setattr(notifier, "change_request", lambda *a: 1 / 0)
    assert _run(_posted(rid="inspector"), _posted(rid="security")) == {"ok": True}
    out = capsys.readouterr().out.splitlines()
    assert out == ["notify reviewer=inspector repo=7215683 mr=10 result=failed step=internal code=ZeroDivisionError",
                   "notify reviewer=security repo=7215683 mr=10 result=failed step=internal code=ZeroDivisionError"]


def test_logs_never_contain_the_email_or_any_token(fake, capsys):
    fake.send_replies = [(400, {"code": 230013, "msg": "user dev@example.com not in scope"}, {})]
    _run(_posted())
    _run(_posted(rid="inspector"))
    out = capsys.readouterr().out
    for secret in ("dev@example.com", KIRO_TOKEN, APP["app_secret"], "t-fake-tenant"):
        assert secret not in out, secret


def test_the_handler_source_never_prints_the_email_or_tokens():
    src = (ROOT / "lambda" / "notifier" / "handler.py").read_text()
    prints = [ln for ln in src.splitlines() if "print(" in ln]
    for name in ("email", "token", "app_secret", "creds"):
        assert not any("{" + name in ln for ln in prints), (name, prints)
