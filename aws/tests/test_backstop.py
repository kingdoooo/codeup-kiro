import json
import pathlib
import sys
from unittest import mock

import botocore.exceptions as bexc
import pytest

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
        {"name": "HEAD_SHA", "value": "abc"},
        {"name": "LOCK_KEY", "value": "r1#7#abc"}]
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


@pytest.mark.parametrize("status", ["PROVISIONING", "PENDING", "ACTIVATING", "RUNNING",
                                    "DEACTIVATING", "STOPPING", "DEPROVISIONING"])
def test_does_not_post_on_a_non_stopped_transition(status):
    # ECS 在每次状态迁移都发 Task State Change；任务还在跑时容器没有 exitCode（官方示例事件
    # 就是 lastStatus=RUNNING、overrides 齐全、无 exitCode）。只看 exitCode 会把「还没结束」
    # 当成「异常结束」，每个 MR 在评审开始几秒后就收到一条假的「评审未完成」。
    # table 故意返回「无已回写标记」——判定必须在读锁之前就结束。
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "r1#7#abc"}}
    assert backstop.should_post(_ev(status=status, exit_code=None), table) is False
    assert not table.get_item.called, "非 STOPPED 事件不该走到读锁那一步"


def test_does_not_post_when_last_status_is_missing():
    ev = _ev(exit_code=None); del ev["detail"]["lastStatus"]
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "r1#7#abc"}}
    assert backstop.should_post(ev, table) is False


def test_reads_the_mark_under_lock_key_verbatim_not_a_rebuilt_key():
    # 评论命令的锁键多一段评论 id。兜底若用 CODEUP_REPO_ID#MR_LOCAL_ID#HEAD_SHA 自己拼，会读到
    # push 触发的那条记录：它被置过位，这次评论触发的任务 OOM 了也沉默（I1 / I10）。
    ev = _ev(exit_code=137)
    ev["detail"]["overrides"]["containerOverrides"][0]["environment"][-1]["value"] = "r1#7#abc#1244"
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "r1#7#abc#1244"}}
    assert backstop.should_post(ev, table) is True
    table.get_item.assert_called_once_with(Key={"pk": "r1#7#abc#1244"})


def test_posts_without_reading_the_table_when_lock_key_is_absent():
    # 读不到 LOCK_KEY 就无从确认「已回写」——宁可多发一条也不沉默。
    ev = _ev(exit_code=137)
    ev["detail"]["overrides"]["containerOverrides"][0]["environment"].pop()
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "r1#7#abc", "posted": True}}
    assert backstop.should_post(ev, table) is True
    assert not table.get_item.called


# ── Ruling 16：云效令牌在调用时向 Secrets Manager 取，环境变量里只有 ARN ──────────
TOKEN_ARN = "arn:aws:secretsmanager:us-west-2:111122223333:secret:codeup-kiro/yunxiao-token-kiro"
# 真的 ClientError，不是裸 Mock 的 side_effect：只用 Mock 造异常只能验证我们写的分支，
# 验不到 botocore 真抛出来的那种异常也走同一条路径。正文刻意带账号 ID。
DENIED = bexc.ClientError(
    {"Error": {"Code": "AccessDeniedException",
               "Message": ("User: arn:aws:sts::111122223333:assumed-role/BackstopRole/x is not "
                           f"authorized to perform: secretsmanager:GetSecretValue on {TOKEN_ARN}")}},
    "GetSecretValue")


def _stub_boto3(monkeypatch, *secret_responses, item=None):
    """打桩 handler() 用到的两条 boto3 出口（DynamoDB 资源 + Secrets Manager 客户端）。

    走**真实**的 secrets.py，只把它内部那句 `import boto3` 换掉——这样 SecretId 的请求形状
    才是真被断言到的东西，而不是我们自己的桩。
    """
    table = mock.Mock()
    table.get_item.return_value = {"Item": item if item is not None else {"pk": "r1#7#abc"}}
    client = mock.Mock()
    client.get_secret_value.side_effect = list(secret_responses)
    boto3 = mock.Mock()
    boto3.resource.return_value.Table.return_value = table
    boto3.client.return_value = client
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    monkeypatch.setenv("LOCK_TABLE", "lock")
    monkeypatch.setenv("YUNXIAO_ORG_ID", "o1")
    monkeypatch.setenv("YUNXIAO_TOKEN_ARN", TOKEN_ARN)
    monkeypatch.setattr(backstop.secrets, "_CACHE", {})
    return client


def test_handler_posts_with_the_token_it_fetched_at_invoke_time(monkeypatch):
    client = _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"})
    posted = []
    monkeypatch.setattr(backstop.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(a) or True)
    assert backstop.handler(_ev(exit_code=137), None) == {"ok": True, "posted": True}
    assert client.get_secret_value.call_args.kwargs == {"SecretId": TOKEN_ARN}
    assert posted[0][3] == "pt-t0ken", posted  # post_comment 的第 4 个位置参数是令牌


def test_no_secret_is_fetched_when_there_is_nothing_to_post(monkeypatch):
    # 绝大多数 Task State Change 都被 should_post 挡掉；提前取令牌等于给每次状态迁移
    # 都加一次 GetSecretValue（配额与延迟）。
    client = _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"},
                         item={"pk": "r1#7#abc", "posted": True})
    assert backstop.handler(_ev(exit_code=1), None) == {"ok": True, "posted": False}
    assert not client.get_secret_value.called


def test_handler_raises_instead_of_silently_reporting_success_when_the_token_is_unavailable(
        monkeypatch):
    # 兜底是异步（EventBridge）调用：抛出会走 Lambda 自己的重试，限流这类瞬时失败能自愈。
    # 吞掉返回 {"posted": False} 才是真正的沉默——兜底的整个存在理由就是「宁可多发也不沉默」。
    client = _stub_boto3(monkeypatch, DENIED)
    posted = []
    monkeypatch.setattr(backstop.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(a) or True)
    with pytest.raises(backstop.secrets.SecretUnavailable) as ei:
        backstop.handler(_ev(exit_code=137), None)
    assert client.get_secret_value.call_args.kwargs == {"SecretId": TOKEN_ARN}
    assert not posted, "取不到令牌时不该拿着空令牌去发评论"
    # 异常消息只有变量名：AWS 错误正文带角色 ARN 与账号 ID，不进日志（M7 的同一条理由）
    assert str(ei.value) == "YUNXIAO_TOKEN_ARN", str(ei.value)
    assert "111122223333" not in json.dumps(str(ei.value))


@pytest.mark.parametrize("arn", ["", None])
def test_handler_fails_closed_when_the_token_arn_env_var_is_missing_or_empty(arn, monkeypatch):
    # falsy 但有意义：空串不得退化成任何默认值，更不能拿空令牌去调 Codeup（那会 401，
    # 却在日志里看起来像「令牌过期」）。
    client = _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"})
    monkeypatch.delenv("YUNXIAO_TOKEN_ARN", raising=False)
    if arn is not None:
        monkeypatch.setenv("YUNXIAO_TOKEN_ARN", arn)
    posted = []
    monkeypatch.setattr(backstop.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(a) or True)
    with pytest.raises(backstop.secrets.SecretUnavailable):
        backstop.handler(_ev(exit_code=137), None)
    assert not client.get_secret_value.called and not posted


def test_backstop_never_reads_a_bare_plaintext_secret_env_var():
    # 静态守卫：裸名 YUNXIAO_TOKEN 不得再作为环境变量名出现（"_ARN" 后缀的那个不算）。
    src = pathlib.Path(backstop.__file__).read_text()
    for bare in ('YUNXIAO_TOKEN"', "YUNXIAO_TOKEN'", 'WEBHOOK_SECRET"', "WEBHOOK_SECRET'"):
        assert bare not in src, f"backstop/handler.py 仍在读明文环境变量 {bare}"
