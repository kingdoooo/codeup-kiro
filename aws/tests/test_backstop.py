import pathlib
import sys
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
# codeup_min 与 backstop 的 handler 不同目录，import codeup_min 要能解析
sys.path.insert(0, str(ROOT / "lambda" / "dispatcher"))
backstop = load_lambda("backstop_handler", ROOT / "lambda" / "backstop" / "handler.py")


def _ev(exit_code=1, status="STOPPED", overrides=None):
    # overrides=[] 必须真的产出「没有环境变量」的事件（用来测「忽略没有我们环境变量的事件」），
    # 所以这里用 `is not None` 判断——若写成 `overrides or [...]`，空列表这个「假值」会被
    # 悄悄换回默认三件套，那条用例就测不到它名字所说的场景（虚假通过）。
    env = overrides if overrides is not None else [
        {"name": "CODEUP_REPO_ID", "value": "r1"},
        {"name": "MR_LOCAL_ID", "value": "7"},
        {"name": "HEAD_SHA", "value": "abc"}]
    return {"detail": {"lastStatus": status, "containers": [{"exitCode": exit_code}],
                       "overrides": {"containerOverrides": [
                           {"environment": env}]}}}

def test_posts_when_task_died_and_no_posted_mark():
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "r1#7#abc"}}
    assert backstop.should_post(_ev(exit_code=137), table) is True

def test_does_not_post_when_script_already_wrote_a_comment():
    table = mock.Mock()
    table.get_item.return_value = {"Item": {"pk": "r1#7#abc", "posted": True}}
    assert backstop.should_post(_ev(exit_code=1), table) is False

def test_does_not_post_on_clean_exit():
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "x"}}
    assert backstop.should_post(_ev(exit_code=0), table) is False

def test_posts_when_container_never_started_so_exit_code_is_absent():
    # 拉镜像失败：没有 exitCode，这正是 die_review 永远管不到的盲区
    ev = _ev(); ev["detail"]["containers"] = [{}]
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "x"}}
    assert backstop.should_post(ev, table) is True

def test_ignores_events_without_our_env_overrides():
    ev = _ev(overrides=[])
    table = mock.Mock(); table.get_item.return_value = {}
    assert backstop.should_post(ev, table) is False
