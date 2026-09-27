import base64
import hashlib
import json
import pathlib
import sys
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
# 回显 Lambda 按 /opt/dispatcher 导入 http_shape（Lambda 运行时里由 layer 提供）；本地把同一个
# 生产目录加进 sys.path——测的是生产那一份 http_shape，不是副本。
sys.path.insert(0, str(ROOT / "lambda" / "dispatcher"))
echo = load_lambda("probe_echo_handler", ROOT / "lambda" / "probe_echo" / "handler.py")

TEXT = '{"note": "探测 中文 正文", "pad": "xx"}'
RAW = TEXT.encode("utf-8")
WANT = hashlib.sha256(RAW).hexdigest()


def _logged(capsys):
    lines = [ln for ln in capsys.readouterr().out.splitlines() if ln.strip()]
    assert len(lines) == 1, lines
    return json.loads(lines[0])


def test_echo_uses_the_production_http_shape_module_not_a_copy():
    # CLAUDE.md：测试里优先用真实的生产助手，不维护简化副本——回显 Lambda 也一样。
    src = (ROOT / "lambda" / "probe_echo" / "handler.py").read_text()
    assert "import http_shape" in src
    assert "b64decode" not in src, "回显 Lambda 不得自己另写一份解码"
    assert echo.http_shape.__file__ == str(ROOT / "lambda" / "dispatcher" / "http_shape.py")


def test_plain_body_response_is_sha256_of_body_bytes(capsys):
    r = echo.handler({"headers": {"content-type": "application/json"},
                      "isBase64Encoded": False, "body": TEXT}, None)
    assert_alb_response(r, 200, WANT)
    log = _logged(capsys)
    assert log["body_sha256"] == WANT and log["body_text"] == TEXT
    assert log["isBase64Encoded"] is False


def test_base64_body_is_decoded_before_hashing(capsys):
    # application/octet-stream 会让 ALB 改走 base64（G6）；哈希的是解码后的字节，
    # 不是 base64 文本本身——否则 P2a-08 的两端比对永远对不上。
    r = echo.handler({"headers": {"content-type": "application/octet-stream"},
                      "isBase64Encoded": True,
                      "body": base64.b64encode(RAW).decode("ascii")}, None)
    assert_alb_response(r, 200, WANT)
    log = _logged(capsys)
    assert log["body_sha256"] == WANT and log["body_text"] == TEXT
    assert log["isBase64Encoded"] is True


def test_token_header_is_redacted_with_its_length(capsys):
    echo.handler({"headers": {"X-Codeup-Token": "probe-throwaway", "codeup-event": "Note Hook"},
                  "isBase64Encoded": False, "body": TEXT}, None)
    out = capsys.readouterr().out
    assert "probe-throwaway" not in out, "令牌不得进日志"
    log = json.loads(out.strip())
    assert log["headers"]["X-Codeup-Token"] == "<redacted len=15>"
    assert log["headers"]["codeup-event"] == "Note Hook", "其余请求头原样记录（Task 1 要取它们）"


# ── F3：Codeup 一次投递里带两个令牌头（Task 1 实测）──────────────────────────────
# 真实投递的请求头形状（probe-results §1「请求头」）：事件头、投递 id、**两个**令牌头、
# okhttp 的 UA、带 charset 的 Content-Type。头名大小写按 Codeup 发出的原样写——ALB 转发时会
# 小写，但打码不能依赖「一定已经小写了」，所以这里刻意混着大小写喂。
#
# 两个头的值**故意写成不相等的两个 48 位十六进制串**：实测到的只是两者长度相同（各 48 位，
# 与生成的一次性令牌等长），「逐字相同」是按 GitLab 兼容语义推断的、没做过逐字节比对。
# 用不相等的值反而更强：它证明两个头各自被打码，而不是「打掉一个、另一个碰巧同值所以也看不见」。
TOKEN_CODEUP = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678abcdef01"
TOKEN_GITLAB = "ff00ee11dd22cc33bb44aa5566778899fedcba9876543210"
assert len(TOKEN_CODEUP) == len(TOKEN_GITLAB) == 48 and TOKEN_CODEUP != TOKEN_GITLAB
REAL_DELIVERY_HEADERS = {
    "X-Codeup-Event": "Merge Request Hook",
    "X-Codeup-Delivery": "d19fbb32-0000-4000-8000-000000000000",
    "X-Codeup-Token": TOKEN_CODEUP,
    "X-Gitlab-Token": TOKEN_GITLAB,
    "User-Agent": "okhttp/4.11.0",
    "Content-Type": "application/json; charset=utf-8",
}


def test_both_token_headers_are_redacted_case_insensitively(capsys):
    # 原缺陷：只给 x-codeup-token 打码，X-Gitlab-Token 原样进日志——探测用的一次性令牌
    # 就这么以明文落在了探测栈的日志里（Task 1 真的发生过）。
    headers = dict(REAL_DELIVERY_HEADERS)
    headers["x-CODEUP-token"] = headers.pop("X-Codeup-Token")   # 再混一层大小写
    headers["X-GITLAB-token"] = headers.pop("X-Gitlab-Token")
    echo.handler({"headers": headers, "isBase64Encoded": False, "body": TEXT}, None)
    out = capsys.readouterr().out
    for token in (TOKEN_CODEUP, TOKEN_GITLAB):
        assert token not in out, "令牌值不得出现在日志任何位置"
    log = json.loads(out.strip())
    marker = "<redacted len=48>"
    assert log["headers"]["x-CODEUP-token"] == marker
    assert log["headers"]["X-GITLAB-token"] == marker
    # 正向对照：只打码这两个，其余真实请求头逐字保留——否则「日志里没有令牌」也可能是
    # 因为把所有头都打码了（那样 Task 1 要取的事件头/投递 id 就一起没了）。
    for name in ("X-Codeup-Event", "X-Codeup-Delivery", "User-Agent", "Content-Type"):
        assert log["headers"][name] == REAL_DELIVERY_HEADERS[name], name


def test_redacted_header_list_covers_every_token_header_the_real_delivery_carries():
    # 负向测试的配套（不是只验我们自己的打码分支）：把真实投递的头名跑一遍，凡是名字里
    # 带 token 的都必须在名单里。Codeup 以后再加一个同值的头，这条会先红。
    carries_token = {k for k in REAL_DELIVERY_HEADERS if "token" in k.lower()}
    assert carries_token == {"X-Codeup-Token", "X-Gitlab-Token"}, carries_token
    assert {k.lower() for k in carries_token} <= set(echo.REDACTED_HEADERS)


def test_production_dispatcher_still_accepts_only_x_codeup_token():
    """打码面扩到两个头，**校验面不扩**：多认一个头就是多一条绕过面。

    按行为判，不用 `"gitlab" not in 源码` 那种静态判：那种写法连**注释**都禁得住——
    本文件对应的 probe_echo/handler.py 里就有一句解释「不接受 x-gitlab-token 作为替代」的
    注释，将来 dispatcher 里加一句同样纯解释性的注释就会无理由地红。
    """
    disp = load_lambda("dispatcher_header_scope", ROOT / "lambda" / "dispatcher" / "handler.py")
    secret = "s3cret-value"
    # 只带 x-gitlab-token、且值是**对的**：必须 401，而且必须在取密钥**之前**就拒掉。
    # 把取密钥换成一调用就抛，401 仍然出现，才说明这个头连触发一次 GetSecretValue 都做不到
    # （否则「401」也可能是取密钥失败之后才拐出来的，那是另一条路径、另一个语义）。
    with mock.patch.object(disp.secret_fetch, "secret_from_env",
                           side_effect=AssertionError("不该为 x-gitlab-token 去取密钥")):
        r = disp.handler({"headers": {"X-Gitlab-Token": secret}}, None)
    assert r["statusCode"] == 401, r
    # 正向对照：同一个值换到 x-codeup-token 就能过校验，且那条路径**真的会**去取密钥——
    # 否则上面那个 401 可能只是「这个 handler 什么都 401」。
    assert disp.verify_token({"X-Codeup-Token": secret}, secret) is True
    with mock.patch.object(disp.secret_fetch, "secret_from_env",
                           return_value=secret) as fetched:
        assert disp.handler({"headers": {"X-Codeup-Token": secret}}, None)["statusCode"] == 200
    assert fetched.call_args_list == [mock.call("WEBHOOK_SECRET_ID")], fetched.call_args_list
    # 取值层同样只认一个头名
    assert disp.verify_token({"X-Gitlab-Token": secret}, secret) is False
    assert disp.token_header({"X-Gitlab-Token": secret}) == ""


def test_non_utf8_body_is_still_hashed_and_logged_without_crashing(capsys):
    r = echo.handler({"headers": {}, "isBase64Encoded": True,
                      "body": base64.b64encode(b"\xff\xfe").decode("ascii")}, None)
    assert_alb_response(r, 200, hashlib.sha256(b"\xff\xfe").hexdigest())
    log = _logged(capsys)
    assert log["body_text"] is None and log["body_text_error"]
