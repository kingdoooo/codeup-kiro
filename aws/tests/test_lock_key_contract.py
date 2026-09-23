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
