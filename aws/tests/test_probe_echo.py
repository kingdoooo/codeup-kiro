import base64
import hashlib
import json
import pathlib
import sys

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


# ── F3：Codeup 把同一个 Secret Token 放在两个头里（Task 1 实测）────────────────────
# 真实投递的请求头形状（probe-results §1「请求头」）：事件头、投递 id、**两个**同值的令牌头、
# okhttp 的 UA、带 charset 的 Content-Type。头名大小写按 Codeup 发出的原样写——ALB 转发时会
# 小写，但打码不能依赖「一定已经小写了」，所以这里刻意混着大小写喂。
REAL_DELIVERY_HEADERS = {
    "X-Codeup-Event": "Merge Request Hook",
    "X-Codeup-Delivery": "d19fbb32-0000-4000-8000-000000000000",
    "X-Codeup-Token": "probe-throwaway-token",
    "X-Gitlab-Token": "probe-throwaway-token",
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
    assert "probe-throwaway-token" not in out, "令牌值不得出现在日志任何位置"
    log = json.loads(out.strip())
    marker = f"<redacted len={len('probe-throwaway-token')}>"
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
    # 打码面扩到两个头，**校验面不扩**：多认一个头就是多一条绕过面。
    disp = (ROOT / "lambda" / "dispatcher" / "handler.py").read_text()
    assert 'TOKEN_HEADER = "x-codeup-token"' in disp
    assert "gitlab" not in disp.lower(), "调度器不得开始接受 x-gitlab-token 作为替代"


def test_non_utf8_body_is_still_hashed_and_logged_without_crashing(capsys):
    r = echo.handler({"headers": {}, "isBase64Encoded": True,
                      "body": base64.b64encode(b"\xff\xfe").decode("ascii")}, None)
    assert_alb_response(r, 200, hashlib.sha256(b"\xff\xfe").hexdigest())
    log = _logged(capsys)
    assert log["body_text"] is None and log["body_text_error"]
