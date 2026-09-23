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


def test_non_utf8_body_is_still_hashed_and_logged_without_crashing(capsys):
    r = echo.handler({"headers": {}, "isBase64Encoded": True,
                      "body": base64.b64encode(b"\xff\xfe").decode("ascii")}, None)
    assert_alb_response(r, 200, hashlib.sha256(b"\xff\xfe").hexdigest())
    log = _logged(capsys)
    assert log["body_text"] is None and log["body_text_error"]
