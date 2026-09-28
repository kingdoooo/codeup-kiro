"""锁键单一来源（I1）：调度器抢锁写入的键、容器拿到的 LOCK_KEY、兜底 Lambda 读标记用的键，
必须是同一个字符串。评论命令（Note Hook）的键比 MR 事件多一段评论 id——任何一处自己用
repo#MR#sha 重建，都会读写到另一条记录上。

两个 Lambda 都按生产文件加载，事件由调度器真实发出的 containerOverrides 构造（ECS 会把
RunTask 的 overrides 原样带进 Task State Change 事件）；entrypoint 那一半见
tests/test-aws-entrypoint.sh 的对应断言。
"""
import pathlib
import sys
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lambda" / "dispatcher"))
dispatcher = load_lambda("lock_contract_dispatcher", ROOT / "lambda" / "dispatcher" / "handler.py")
backstop = load_lambda("lock_contract_backstop", ROOT / "lambda" / "backstop" / "handler.py")

NOTE_FIELDS = {"repo_id": "r1", "mr_local_id": "7", "head_sha": "abc123", "dedupe_extra": "1244",
               "target_branch": "main", "source_branch": "feature/x",
               "clone_url": "https://codeup.aliyun.com/o1/r1.git"}


def _dispatch(fields):
    table, ecs = mock.Mock(), mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "arn:task/1"}]}
    dispatcher.dispatch(ecs, table, _full_cfg(), fields)
    claimed = table.put_item.call_args.kwargs["Item"]["pk"]
    overrides = ecs.run_task.call_args.kwargs["overrides"]["containerOverrides"]
    return claimed, overrides


def test_container_gets_exactly_the_key_that_claim_wrote_for_a_note_hook():
    claimed, overrides = _dispatch(NOTE_FIELDS)
    env = {e["name"]: e["value"] for e in overrides[0]["environment"]}
    assert claimed == "r1#7#abc123#1244", claimed
    assert env["LOCK_KEY"] == claimed


def test_backstop_reads_the_mark_under_the_key_claim_wrote():
    claimed, overrides = _dispatch(NOTE_FIELDS)
    event = {"detail": {"lastStatus": "STOPPED", "containers": [{"exitCode": 137}],
                        "overrides": {"containerOverrides": overrides}}}
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": claimed}}
    assert backstop.should_post(event, table) is True
    table.get_item.assert_called_once_with(Key={"pk": claimed})


def test_mr_hook_key_without_comment_id_round_trips_too():
    claimed, overrides = _dispatch(dict(NOTE_FIELDS, dedupe_extra=""))
    env = {e["name"]: e["value"] for e in overrides[0]["environment"]}
    assert claimed == env["LOCK_KEY"] == "r1#7#abc123"


# ── 执行器按 MR 的租约（spec I6 ②）要读**别的投递**的抢锁记录 ──────────────────────────
# entrypoint.sh 拿到租约后核对源分支最新提交：最新提交 ≠ HEAD_SHA 且调度器已为它抢过锁 → 被取代、安静退出。
# 那一次查的是「仓库#MR#<最新提交>」这条记录（MR 事件的键，不带评论 id），键形状在 entrypoint 里拼。
# 这里把那一行原样抽出来交给 bash 求值，与真实的 lock_key() 逐字比较：调度器哪天改了键形状，
# 这条先红——否则执行器会永远查不到记录，「被取代」的任务照样评审旧提交，C2 静默回来。
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402

import pytest  # noqa: E402

ENTRY = ROOT / "executor" / "entrypoint.sh"


def _entry_assignment(var):
    lines = [ln for ln in ENTRY.read_text().splitlines()
             if re.match(rf"^\s*{var}=", ln)]
    assert len(lines) == 1, (var, lines)
    return lines[0].strip()


def _bash_eval(assignment, var, **env):
    out = subprocess.run(["/bin/bash", "-c", f"set -eu; {assignment}; printf '%s' \"${var}\""],
                         env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **env},
                         capture_output=True, text=True,
                         check=True)
    return out.stdout


def test_the_executor_reads_the_tip_claim_under_the_key_the_dispatcher_writes():
    tip = "f" * 40
    fields = dict(NOTE_FIELDS, repo_id="7215683", mr_local_id="4", head_sha=tip, dedupe_extra="")
    want = dispatcher.lock_key(fields)
    got = _bash_eval(_entry_assignment("tip_key"), "tip_key",
                     CODEUP_REPO_ID="7215683", MR_LOCAL_ID="4", tip=tip)
    assert got == want == f"7215683#4#{tip}", (got, want)


@pytest.mark.skipif(shutil.which("jq") is None, reason="需要 jq 才能求值 entrypoint 的租约键那一行")
def test_the_lease_key_is_disjoint_from_every_claim_key():
    # L4：租约与抢锁同表，靠命名空间不相交。抢锁键以 repo_id 开头，而 repo_id 必须是纯数字（_reject_reason）。
    assignment = _entry_assignment("lease_key")
    got = _bash_eval(assignment.replace("/usr/bin/jq", "jq"), "lease_key",
                     CODEUP_REPO_ID="7215683", MR_LOCAL_ID="4")
    assert json.loads(got) == {"pk": {"S": "lease#7215683#4"}}, got
    assert dispatcher._DIGITS_RE.match("lease") is None
    bad = dict(NOTE_FIELDS, repo_id="lease", clone_url="https://codeup.aliyun.com/o1/r1.git",
               head_sha="a" * 40, dedupe_extra="")
    assert dispatcher._reject_reason(bad, {"org_id": "o1"}) == "repo-id"
