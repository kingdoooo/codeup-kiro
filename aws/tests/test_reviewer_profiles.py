"""评审员档案两份常量表的一致性（Phase 2b spec「评审员档案」「M1」）。

bash 侧（scripts/lib/review-render.sh，按 REVIEW_PROFILE 选）与 Lambda 侧（aws/lambda/dispatcher/reviewers.py）。
读 bash 那边 source 之后的**真实值**来比，不在这里抄第三份——抄的那份迟早与两边都分叉。
"""
import pathlib
import subprocess
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "aws" / "lambda" / "dispatcher"))
import reviewers  # noqa: E402


def _bash_profile(rid):
    out = subprocess.run(
        ["/bin/bash", "--norc", "--noprofile", "-c",
         "source scripts/lib/review-render.sh; printf '%s\\n' \"$REVIEW_MARKER_NAME\" \"$REVIEW_TITLE\""],
        cwd=ROOT, env={"PATH": "/usr/bin:/bin", "REVIEW_PROFILE": rid}, capture_output=True, text=True,
        stdin=subprocess.DEVNULL, check=True).stdout.splitlines()
    return {"marker_name": out[0], "title": out[1]}


@pytest.mark.parametrize("rid", reviewers.ORDER)
def test_bash_and_lambda_profiles_agree(rid):
    b = _bash_profile(rid)
    p = reviewers.PROFILES[rid]
    assert b["marker_name"] == p["marker_name"]
    assert b["title"] == "# " + p["title"]
    assert p["lambda_heading"] == "## 🤖 " + p["title"]


def test_security_agent_is_titled_continuum_and_keeps_its_markers_and_secret():
    # Phase 2c spec F8：标题改成「Continuum 代码安全扫描」（与飞书通知的文案一致）；评审员 id、标记、令牌密钥都不变——MR 上已有的评论照样认得出来
    p = reviewers.PROFILES["security"]
    assert p["title"] == "Continuum 代码安全扫描"
    assert (p["marker_name"], p["backstop_marker"], p["dispatch_failed_marker"], p["secret_name"]) == (
        "kiro-security-review", "<!-- kiro-backstop-security -->", "<!-- kiro-dispatch-failed-security -->",
        "codeup-kiro/yunxiao-token-security")


def test_every_lambda_marker_is_in_the_kiro_family_the_dispatcher_ignores():
    dispatcher = load_lambda("dispatcher_handler_profiles", ROOT / "aws" / "lambda" / "dispatcher" / "handler.py")
    for p in reviewers.PROFILES.values():
        for m in (p["backstop_marker"], p["dispatch_failed_marker"]):
            assert m.startswith(dispatcher.REVIEW_MARKER), m


def test_lambda_markers_carry_no_colon_payload_so_no_script_marker_regex_can_match_them():
    # 2a 的约定（test_dispatcher 的断环用例）：Lambda 侧标记不带冒号载荷，与评审脚本那几种（`kiro-review:<sha> run:N`、
    # `kiro-history:[…]`、`kiro-inline:<指纹>`）一眼可分。扫描员的标记用连字符后缀，同一约定成立。
    for p in reviewers.PROFILES.values():
        for m in (p["backstop_marker"], p["dispatch_failed_marker"]):
            assert ":" not in m, m


def test_kiro_keeps_its_2a_lambda_markers():
    assert reviewers.PROFILES["kiro"]["backstop_marker"] == "<!-- kiro-backstop -->"
    assert reviewers.PROFILES["kiro"]["dispatch_failed_marker"] == "<!-- kiro-dispatch-failed -->"
    assert reviewers.PROFILES["kiro"]["token_secret_env"] == "YUNXIAO_TOKEN_ID"


@pytest.mark.parametrize("raw, want", [
    ("kiro", ("kiro",)), ("inspector,kiro", ("kiro", "inspector")), ("security", ("security",)),
])
def test_parse_accepts_known_reviewers_and_orders_them(raw, want):
    assert reviewers.parse(raw) == want
    assert reviewers.join(want) == ",".join(want)


@pytest.mark.parametrize("raw", ["", None, "kiro,", "kiro,kiro", "Kiro", "kiro inspector", 1, "inspectr"])
def test_parse_rejects_everything_else(raw):
    with pytest.raises(ValueError):
        reviewers.parse(raw)


def test_enabled_reads_the_two_toggles_strictly():
    assert reviewers.enabled({}) == ("kiro",)
    assert reviewers.enabled({"inspector": 1}) == ("kiro", "inspector")
    assert reviewers.enabled({"inspector": True, "security_agent": 1}) == ("kiro", "security")   # True 不是 1
