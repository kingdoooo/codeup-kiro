import json
import pathlib
import sys
from unittest import mock

import botocore.exceptions as bexc
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
# codeup_min 与本文件的 handler 同目录，但 load_lambda 按文件路径加载、不会自动把
# 那个目录搬上 sys.path——handler.py 里的 `import codeup_min` 得靠这行才能解析。
sys.path.insert(0, str(ROOT / "lambda" / "dispatcher"))
handler_mod = load_lambda("dispatcher_handler", ROOT / "lambda" / "dispatcher" / "handler.py")


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


F = {"repo_id": "r1", "mr_local_id": "7", "head_sha": "abc123", "dedupe_extra": "",
     "target_branch": "main", "source_branch": "feature/x",
     "clone_url": "https://codeup.aliyun.com/o1/r1.git"}

def test_lock_key_includes_repo_mr_and_head_sha():
    k = handler_mod.lock_key(F)
    assert "r1" in k and "7" in k and "abc123" in k

def test_lock_key_differs_when_comment_id_present():
    assert handler_mod.lock_key(F) != handler_mod.lock_key(dict(F, dedupe_extra="1244"))

def test_first_claim_succeeds():
    table = mock.Mock()
    assert handler_mod.claim(table, "k", 86400) is True
    assert table.put_item.called

def test_second_claim_on_same_key_fails():
    table = mock.Mock()
    table.put_item.side_effect = bexc.ClientError(
        {"Error": {"Code": "ConditionalCheckFailedException"}}, "PutItem")
    assert handler_mod.claim(table, "k", 86400) is False

def test_claim_writes_a_ttl_so_a_stuck_lock_cannot_block_forever():
    table = mock.Mock()
    handler_mod.claim(table, "k", 86400)
    item = table.put_item.call_args.kwargs["Item"]
    assert int(item["expires_at"]) > 0, "锁必须带 TTL（N4）"

def test_release_deletes_the_key():
    table = mock.Mock()
    handler_mod.release(table, "k")
    table.delete_item.assert_called_once()

def test_claim_actually_uses_a_conditional_write():
    # Mock 不会真的强制 DynamoDB 的条件语义——如果 put_item 悄悄丢了
    # ConditionExpression，上面那条「第二次抢锁失败」的用例照样会通过
    # （因为它是靠 side_effect 手动制造异常，不是靠真条件触发的）。
    # 这条断言就是防止条件表达式被静默删掉的那道保险。
    table = mock.Mock()
    handler_mod.claim(table, "k", 86400)
    kwargs = table.put_item.call_args.kwargs
    assert kwargs.get("ConditionExpression") == "attribute_not_exists(pk)"

def test_claim_reraises_non_conditional_check_client_errors():
    # 抢锁失败要区分「已被占」和「AWS 真错误」——后者绝不能吞成 False
    table = mock.Mock()
    table.put_item.side_effect = bexc.ClientError(
        {"Error": {"Code": "ProvisionedThroughputExceededException"}}, "PutItem")
    with pytest.raises(bexc.ClientError):
        handler_mod.claim(table, "k", 86400)


def test_run_task_passes_scalars_as_env_overrides():
    ecs = mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "arn:task/1"}]}
    handler_mod.run_task(ecs, {"cluster": "c", "task_definition": "td",
                               "subnets": ["s1"], "security_groups": ["sg1"],
                               "container_name": "review"}, F)
    env = ecs.run_task.call_args.kwargs["overrides"]["containerOverrides"][0]["environment"]
    names = {e["name"] for e in env}
    assert {"CODEUP_REPO_ID", "MR_LOCAL_ID", "HEAD_SHA"} <= names

def test_run_task_never_passes_secrets_in_overrides():
    # RunTask 入参进 CloudTrail（I3）。密钥只能走任务定义的 secrets 块。
    ecs = mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "a"}]}
    handler_mod.run_task(ecs, {"cluster": "c", "task_definition": "td", "subnets": ["s"],
                               "security_groups": ["sg"], "container_name": "review"}, F)
    blob = json.dumps(ecs.run_task.call_args.kwargs)
    for forbidden in ("KIRO_API_KEY", "YUNXIAO_TOKEN", "WEBHOOK_SECRET", "secret"):
        assert forbidden not in blob

def test_run_task_failure_releases_lock_and_posts_to_mr(monkeypatch):
    posted = []
    monkeypatch.setattr(handler_mod.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(k or a) or True)
    table, ecs = mock.Mock(), mock.Mock()
    ecs.run_task.side_effect = RuntimeError("Throttled")
    rc = handler_mod.dispatch(ecs, table, _full_cfg(), F)
    assert rc["statusCode"] == 200, "webhook 不该因为我们的内部失败而被重投"
    assert table.delete_item.called, "必须释放锁（N4）"
    assert posted, "必须在 MR 上留痕（I10）"
