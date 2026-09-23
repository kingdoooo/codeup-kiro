import base64
import pathlib

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
http_shape = load_lambda("http_shape", ROOT / "lambda" / "dispatcher" / "http_shape.py")


@pytest.mark.parametrize("status", [200, 401, 404, 500])
def test_resp_has_every_field_alb_requires(status):
    # G5：ALB 要求 statusCode / statusDescription / isBase64Encoded 齐全，缺了回 502——
    # 请求其实已被处理，Codeup 却记投递失败。headers 与 body 一并给全，不让 ALB 去猜。
    assert_alb_response(http_shape.resp(status, "x"), status, "x")


def test_resp_body_defaults_to_empty_string_not_none():
    assert_alb_response(http_shape.resp(401), 401, "")


def test_body_text_decodes_base64_then_utf8():
    # G6：ALB 对非 text/*、非 application/json 等类型（或带 content-encoding 头）改走 base64，
    # 不能假设 Codeup 的 Content-Type 恰好落在原样转发的那几类里。
    raw = '{"note": "探测 中文 正文"}'.encode("utf-8")
    event = {"isBase64Encoded": True, "body": base64.b64encode(raw).decode("ascii")}
    assert http_shape.body_text(event) == '{"note": "探测 中文 正文"}'
    assert http_shape.body_bytes(event) == raw


def test_body_text_passes_plain_body_through():
    event = {"isBase64Encoded": False, "body": '{"note": "中文"}'}
    assert http_shape.body_text(event) == '{"note": "中文"}'
    assert http_shape.body_bytes(event) == '{"note": "中文"}'.encode("utf-8")


@pytest.mark.parametrize("event", [
    {}, {"body": None}, {"body": ""}, {"isBase64Encoded": True, "body": ""},
    {"isBase64Encoded": True, "body": None}])
def test_body_text_of_an_empty_request_is_empty_string(event):
    assert http_shape.body_text(event) == ""
    assert http_shape.body_bytes(event) == b""


@pytest.mark.parametrize("event", [
    {"isBase64Encoded": True, "body": "!!!不是base64!!!"},
    {"isBase64Encoded": True, "body": base64.b64encode(b"\xff\xfe").decode("ascii")}])
def test_undecodable_body_raises_value_error(event):
    # 解不开的正文抛 ValueError（binascii.Error / UnicodeDecodeError 都是它的子类）——
    # 调度器 handler 的 `except ValueError` 据此把它归入 unparseable（N6：不猜），而不是 500。
    with pytest.raises(ValueError):
        http_shape.body_text(event)
