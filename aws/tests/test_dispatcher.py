import importlib, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "lambda" / "dispatcher"))
handler_mod = importlib.import_module("handler")


def test_missing_token_header_is_rejected():
    assert handler_mod.verify_token({}, "s3cret") is False

def test_wrong_token_is_rejected():
    assert handler_mod.verify_token({"x-codeup-token": "nope"}, "s3cret") is False

def test_empty_expected_token_rejects_everything():
    # 密钥没配好时绝不能变成「谁都放行」
    assert handler_mod.verify_token({"x-codeup-token": ""}, "") is False

def test_correct_token_accepted_case_insensitive_header():
    assert handler_mod.verify_token({"X-Codeup-Token": "s3cret"}, "s3cret") is True

def test_uses_constant_time_comparison():
    # 静态守卫：必须用 hmac.compare_digest，不能用 ==
    src = (pathlib.Path(handler_mod.__file__)).read_text()
    assert "compare_digest" in src
    assert "hmac" in src
