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

def test_multi_container_picks_review_container_by_name_not_index():
    # sidecar 排在 index 0 且干净退出；真正的 review 容器（我们的环境变量所在的那个
    # override 报的 name）排在 index 1 且死了。用下标取会读到 sidecar 的 exitCode=0，
    # 误判成功从而沉默——这正是上一个任务修 N1 时踩过的同一类坑。
    ev = _ev(exit_code=137)
    ev["detail"]["containers"] = [{"name": "sidecar", "exitCode": 0},
                                   {"name": "review", "exitCode": 137}]
    ev["detail"]["overrides"]["containerOverrides"][0]["name"] = "review"
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "x"}}
    assert backstop.should_post(ev, table) is True

def test_multi_container_no_name_match_defers_to_posted_mark_not_blind_post():
    # 多容器、且没有一个容器名字对得上 override 的 name——退出码判不出来（既不能当 0
    # 也不能当非 0），但如果「已回写」标记确实已经置位（脚本其实跑完并发布成功），
    # 不该因为身份判不出来就盲目再发一条。
    ev = _ev(exit_code=1)
    ev["detail"]["containers"] = [{"name": "sidecar", "exitCode": 0},
                                   {"name": "other", "exitCode": 0}]
    ev["detail"]["overrides"]["containerOverrides"][0]["name"] = "review"
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "x", "posted": True}}
    assert backstop.should_post(ev, table) is False
