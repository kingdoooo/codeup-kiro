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


# ── Ruling 16：云效令牌在调用时向 Secrets Manager 取，环境变量里只有密钥名 ──────────
# 注入的是**密钥名**（SecretId），不是 partial ARN——理由见 lambda/dispatcher/secret_fetch.py 顶部。
TOKEN_ID = "codeup-kiro/yunxiao-token-kiro"
FULL_ARN = "arn:aws:secretsmanager:us-west-2:111122223333:secret:" + TOKEN_ID + "-AbCdEf"
# 真的 ClientError，不是裸 Mock 的 side_effect：只用 Mock 造异常只能验证我们写的分支，
# 验不到 botocore 真抛出来的那种异常也走同一条路径。正文刻意带账号 ID。
DENIED = bexc.ClientError(
    {"Error": {"Code": "AccessDeniedException",
               "Message": ("User: arn:aws:sts::111122223333:assumed-role/BackstopRole/x is not "
                           f"authorized to perform: secretsmanager:GetSecretValue on {FULL_ARN}")}},
    "GetSecretValue")


def _stub_boto3(monkeypatch, *secret_responses, item=None):
    """打桩 handler() 用到的两条 boto3 出口（DynamoDB 资源 + Secrets Manager 客户端）。

    走**真实**的 secret_fetch.py，只把它内部那句 `import boto3` 换掉——这样 SecretId 的请求形状
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
    monkeypatch.setenv("YUNXIAO_TOKEN_ID", TOKEN_ID)
    monkeypatch.setattr(backstop.secret_fetch, "_CACHE", {})
    return client


def test_handler_posts_with_the_token_it_fetched_at_invoke_time(monkeypatch):
    client = _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"})
    posted = []
    monkeypatch.setattr(backstop.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(a) or True)
    assert backstop.handler(_ev(exit_code=137), None) == {"ok": True, "posted": True}
    assert client.get_secret_value.call_args.kwargs == {"SecretId": TOKEN_ID}
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
    with pytest.raises(backstop.secret_fetch.SecretUnavailable) as ei:
        backstop.handler(_ev(exit_code=137), None)
    assert client.get_secret_value.call_args.kwargs == {"SecretId": TOKEN_ID}
    assert not posted, "取不到令牌时不该拿着空令牌去发评论"
    # 异常消息只有变量名：AWS 错误正文带角色 ARN 与账号 ID，不进日志（M7 的同一条理由）
    assert str(ei.value) == "YUNXIAO_TOKEN_ID", str(ei.value)
    assert "111122223333" not in json.dumps(str(ei.value))


@pytest.mark.parametrize("secret_id", ["", None])
def test_handler_fails_closed_when_the_token_id_env_var_is_missing_or_empty(secret_id, monkeypatch):
    # falsy 但有意义：空串不得退化成任何默认值，更不能拿空令牌去调 Codeup（那会 401，
    # 却在日志里看起来像「令牌过期」）。
    client = _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"})
    monkeypatch.delenv("YUNXIAO_TOKEN_ID", raising=False)
    if secret_id is not None:
        monkeypatch.setenv("YUNXIAO_TOKEN_ID", secret_id)
    posted = []
    monkeypatch.setattr(backstop.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(a) or True)
    with pytest.raises(backstop.secret_fetch.SecretUnavailable):
        backstop.handler(_ev(exit_code=137), None)
    assert not client.get_secret_value.called and not posted


def test_backstop_never_reads_a_bare_plaintext_secret_env_var():
    # 静态守卫：裸名 YUNXIAO_TOKEN 不得再作为环境变量名出现（"_ID" 后缀的那个不算）。
    src = pathlib.Path(backstop.__file__).read_text()
    for bare in ('YUNXIAO_TOKEN"', "YUNXIAO_TOKEN'", 'WEBHOOK_SECRET"', "WEBHOOK_SECRET'"):
        assert bare not in src, f"backstop/handler.py 仍在读明文环境变量 {bare}"


# ── 兜底可靠性（全分支复审 s1 F2）───────────────────────────────────────────────
def test_the_backstops_dynamodb_resource_is_built_with_the_bounded_config(monkeypatch):
    # 真的 boto3 资源（不发请求）：lastStatus 不是 STOPPED，should_post 在读表之前就返回
    import boto3
    for k, v in (("AWS_DEFAULT_REGION", "us-west-2"), ("AWS_ACCESS_KEY_ID", "testing"),
                 ("AWS_SECRET_ACCESS_KEY", "fake"), ("AWS_CONFIG_FILE", "/dev/null"),
                 ("AWS_SHARED_CREDENTIALS_FILE", "/dev/null"), ("LOCK_TABLE", "lock")):
        monkeypatch.setenv(k, v)
    for var in ("AWS_PROFILE", "AWS_SESSION_TOKEN", "AWS_RETRY_MODE", "AWS_MAX_ATTEMPTS"):
        monkeypatch.delenv(var, raising=False)
    made, real = [], boto3.resource
    monkeypatch.setattr(boto3, "resource", lambda *a, **k: made.append(real(*a, **k)) or made[-1])
    assert backstop.handler(_ev(status="RUNNING"), None) == {"ok": True, "posted": False}
    cfg = made[0].meta.client.meta.config
    assert (cfg.connect_timeout, cfg.read_timeout) == (2, 5)
    assert cfg.retries == {"mode": "standard", "total_max_attempts": 2}, cfg.retries


def test_a_failed_post_raises_so_lambda_retries_and_the_failure_destination_gets_it(
        monkeypatch, capsys):
    # codeup_min.post_comment 失败时只返回 False、不抛。以前这个返回值被丢掉、照样报 posted=True：
    # Lambda 不重试、失败目的地收不到，MR 上一句话都没有——兜底要消灭的正是这种沉默。
    _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"})
    monkeypatch.setattr(backstop.codeup_min, "post_comment", lambda *a, **k: False)
    with pytest.raises(backstop.PostFailed):
        backstop.handler(_ev(exit_code=137), None)
    # 每一次出站调用之前一行固定形状的步骤日志（超时时最后一行就是卡住的那一步）
    assert capsys.readouterr().out == (
        "backstop step=read-mark\nbackstop step=fetch-token\nbackstop step=post-comment\n"
        "backstop step=post-comment result=failed\n")


def test_a_successful_post_logs_each_step_once_and_reports_posted(monkeypatch, capsys):
    _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"})
    monkeypatch.setattr(backstop.codeup_min, "post_comment", lambda *a, **k: True)
    assert backstop.handler(_ev(exit_code=137), None) == {"ok": True, "posted": True}
    assert capsys.readouterr().out == (
        "backstop step=read-mark\nbackstop step=fetch-token\nbackstop step=post-comment\n")


# ── 复审 s6 m-B：兜底评论要写出退出码，entrypoint 自己的四个 fail-closed 码各有一句成因 ─────────
GUIDE = ROOT / "setup-guide.md"


@pytest.mark.parametrize("code", [90, 91, 92, 93, 94])
def test_each_entrypoint_exit_code_gets_its_own_cause_and_a_pointer_that_resolves(code):
    text = backstop.backstop_comment(code)
    assert f"（退出码 {code}）" in text, text
    assert backstop.EXIT_CAUSES[code] in text
    assert "拉取镜像失败" not in text and "内存不足" not in text, "entrypoint 的码不得再套用笼统的成因"
    assert f"第 8 节里标着「退出码 {code}」的行" in text, text
    # 指针要真的指得到：§8 里至少有一行的「现象」那一格写着这个退出码
    lines = GUIDE.read_text().splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.startswith("## 8."))
    rows = [ln for ln in lines[start:] if ln.startswith("|") and f"退出码 {code}" in ln.split(" | ")[0]]
    assert rows, f"§8 没有标着退出码 {code} 的行，评论里的指针指空了"


def test_the_four_codes_are_exactly_the_entrypoints_fail_closed_exits():
    # 与 entrypoint.sh 两头核对：那边加一个新的 fail-closed 码而这里没有，评论又会套用笼统成因
    import re
    entry = (ROOT / "executor" / "entrypoint.sh").read_text()
    code = "\n".join(ln for ln in entry.splitlines() if not ln.lstrip().startswith("#"))
    exits = {int(n) for n in re.findall(r"\bexit (9[0-9])\b", code)}
    assert exits == set(backstop.EXIT_CAUSES) == {90, 91, 92, 93, 94}, exits


@pytest.mark.parametrize("code, want", [
    (137, "（退出码 137；可能是内存不足或任务超时）"),
    (1, "（退出码 1；"),
    (0, "（退出码 0；"),              # falsy 但有意义：0 也是一个真实的退出码（多容器时可能走到）
    (None, "没有退出码"),
    (True, "没有退出码"),              # bool 不是退出码
    ("92", "没有退出码"),              # 字符串不写进评论（不是 ECS 给的整数形状）
])
def test_other_exit_codes_are_stated_without_guessing_an_entrypoint_cause(code, want):
    text = backstop.backstop_comment(code)
    assert want in text, text
    assert "第 8 节里标着" not in text


def test_multi_container_no_name_match_posts_a_comment_that_does_not_guess_a_cause(monkeypatch):
    """issue 05 D1：多容器、没有一个名字对得上评审容器、也没有「已回写」标记时照样发（宁可多发），但以前
    handler 把「认不出是哪个容器」这个标志丢了，正文照 backstop_comment(None) 猜成「容器多半没能启动」。"""
    _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"})
    posted = []
    monkeypatch.setattr(backstop.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(a) or True)
    ev = _ev(exit_code=1)
    ev["detail"]["containers"] = [{"name": "sidecar", "exitCode": 0}, {"name": "other", "exitCode": 137}]
    ev["detail"]["overrides"]["containerOverrides"][0]["name"] = "review"
    assert backstop.handler(ev, None) == {"ok": True, "posted": True}
    body = posted[0][4]
    assert body.startswith("## 🤖 Kiro 代码评审\n" + backstop.BACKSTOP_MARKER), body   # 断环标记仍在
    assert "容器多半没能启动" not in body, body
    assert "对得上评审容器" in body, body
    # 正向对照：真的没有退出码（单容器、容器没起来）时，原来那句判断仍然成立、原样保留
    assert "容器多半没能启动" in backstop.backstop_comment(None)


def test_the_handler_posts_the_comment_for_the_exit_code_of_the_matched_container(monkeypatch):
    _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"})
    posted = []
    monkeypatch.setattr(backstop.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(a) or True)
    ev = _ev(exit_code=92)
    assert backstop.handler(ev, None) == {"ok": True, "posted": True}
    assert posted[0][4] == backstop.backstop_comment(92)
    # 多容器：按 override 的名字取那个容器的码，不取下标 0
    ev = _ev(exit_code=0)
    ev["detail"]["overrides"]["containerOverrides"][0]["name"] = "review"
    ev["detail"]["containers"] = [{"name": "sidecar", "exitCode": 0}, {"name": "review", "exitCode": 93}]
    posted.clear()
    _stub_boto3(monkeypatch, {"SecretString": "pt-t0ken"})
    assert backstop.handler(ev, None) == {"ok": True, "posted": True}
    assert posted[0][4] == backstop.backstop_comment(93)


# ── Phase 2b F1：按评审员的兜底（spec「F1」「兜底 Lambda」，issue 03）──────────────────────────
def _ev2(exit_code=1, reviewers_env=None, kind=None, name=None):
    """带 REVIEWERS / TASK_KIND 的事件。reviewers_env=None 表示不带 REVIEWERS（旧调度器拉起的任务）。"""
    ev = _ev(exit_code=exit_code)
    env = ev["detail"]["overrides"]["containerOverrides"][0]["environment"]
    if reviewers_env is not None:
        env.append({"name": "REVIEWERS", "value": reviewers_env})
    if kind is not None:
        env.append({"name": "TASK_KIND", "value": kind})
    if name is not None:
        ev["detail"]["overrides"]["containerOverrides"][0]["name"] = name
    return ev


def _decide_with(item, **kw):
    table = mock.Mock(); table.get_item.return_value = {"Item": item}
    return backstop._decide(_ev2(**kw), table)


def test_task_a_scanner_without_dispatched_mark_gets_a_comment_even_on_clean_exit():
    # 扫描员派发失败时执行器仍以 0 退出（F2：扫描员的失败不改变执行器的退出码），兜底必须照样发
    assert _decide_with({"pk": "k", "posted": True}, exit_code=0, reviewers_env="kiro,inspector") == (False, ["inspector"])


def test_task_a_scanner_with_dispatched_mark_is_left_to_the_scan_task():
    assert _decide_with({"pk": "k", "posted": True, "dispatched_inspector": True},
                        exit_code=0, reviewers_env="kiro,inspector") == (False, [])


def test_task_a_superseded_silences_every_reviewer():
    # 被新推送取代：新提交的那一轮会评，这一轮所有评审员都不该发（那是正常流量）
    assert _decide_with({"pk": "k", "superseded": True},
                        exit_code=137, reviewers_env="kiro,inspector,security") == (True, [])
    # Kiro 的判据不看 superseded（与 2a 相同：被取代时执行器以 0 退出，Kiro 本来就不发）
    assert _decide_with({"pk": "k", "superseded": True},
                        exit_code=0, reviewers_env="kiro,inspector") == (False, [])


def test_kiro_is_not_posted_for_a_scanner_only_command():
    # 评论 `/inspector review`：REVIEWERS 不含 kiro，执行器不跑 Kiro，也就没有 posted——绝不能替 Kiro 发「评审未完成」
    assert _decide_with({"pk": "k", "dispatched_inspector": True},
                        exit_code=0, reviewers_env="inspector") == (False, [])
    assert _decide_with({"pk": "k"}, exit_code=137, reviewers_env="inspector") == (False, ["inspector"])


def test_missing_reviewers_means_kiro_only_as_in_2a():
    assert _decide_with({"pk": "k"}, exit_code=137) == (True, [])
    assert _decide_with({"pk": "k", "posted": True}, exit_code=137) == (False, [])


def test_invalid_reviewers_on_the_executor_falls_back_to_kiro_and_logs(capsys):
    assert _decide_with({"pk": "k"}, exit_code=94, reviewers_env="kiro,inspectr") == (True, [])
    assert "backstop reviewers=invalid" in capsys.readouterr().out


@pytest.mark.parametrize("bad", [None, "", "kiro,inspector", "inspectr"])
def test_invalid_reviewers_on_the_scan_task_raises_instead_of_guessing(bad):
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "k"}}
    with pytest.raises(ValueError):
        backstop._decide(_ev2(exit_code=137, reviewers_env=bad, kind="scan", name="scan"), table)


def test_scan_task_posts_for_each_scanner_without_a_terminal_state():
    item = {"pk": "k", "posted_inspector": True, "dispatched_inspector": True, "dispatched_security": True}
    assert _decide_with(item, exit_code=96, reviewers_env="inspector,security", kind="scan") == (False, ["security"])
    # 扫描员级的 superseded 是终态
    item["superseded_security"] = True
    assert _decide_with(item, exit_code=96, reviewers_env="inspector,security", kind="scan") == (False, [])
    # 退出码 0 也照样看标记：扫描入口只有在所有子进程都到终态时才以 0 退出，但这里不信退出码、只信标记
    assert _decide_with({"pk": "k"}, exit_code=0, reviewers_env="inspector", kind="scan") == (False, ["inspector"])


def _stub_tokens(monkeypatch, tokens):
    """按密钥名给不同的令牌；记录每次 GetSecretValue 的 SecretId。走真实 secret_fetch，只换掉它内部的 boto3。"""
    table = mock.Mock(); table.get_item.return_value = {"Item": {"pk": "r1#7#abc"}}
    client = mock.Mock()
    client.get_secret_value.side_effect = lambda SecretId: {"SecretString": tokens[SecretId]}
    boto3 = mock.Mock()
    boto3.resource.return_value.Table.return_value = table
    boto3.client.return_value = client
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    monkeypatch.setenv("LOCK_TABLE", "lock")
    monkeypatch.setenv("YUNXIAO_ORG_ID", "o1")
    monkeypatch.setenv("YUNXIAO_TOKEN_ID", "codeup-kiro/yunxiao-token-kiro")
    monkeypatch.setenv("YUNXIAO_TOKEN_INSPECTOR_ID", "codeup-kiro/yunxiao-token-inspector")
    monkeypatch.setenv("YUNXIAO_TOKEN_SECURITY_ID", "codeup-kiro/yunxiao-token-security")
    monkeypatch.setattr(backstop.secret_fetch, "_CACHE", {})
    return client


TOKENS = {"codeup-kiro/yunxiao-token-kiro": "pt-kiro", "codeup-kiro/yunxiao-token-inspector": "pt-insp",
          "codeup-kiro/yunxiao-token-security": "pt-sec"}


def test_each_reviewer_is_posted_with_its_own_token_and_marker(monkeypatch):
    _stub_tokens(monkeypatch, TOKENS)
    posted = []
    monkeypatch.setattr(backstop.codeup_min, "post_comment", lambda *a, **k: posted.append(a) or True)
    assert backstop.handler(_ev2(exit_code=137, reviewers_env="kiro,inspector,security"), None) \
        == {"ok": True, "posted": True}
    assert [(p[3], p[4].splitlines()[1]) for p in posted] == [
        ("pt-kiro", "<!-- kiro-backstop -->"),
        ("pt-insp", "<!-- kiro-backstop-inspector -->"),
        ("pt-sec", "<!-- kiro-backstop-security -->")]
    assert posted[1][4].startswith("## 🤖 Inspector 依赖漏洞扫描\n"), posted[1][4]
    assert "执行器在交给扫描任务之前异常结束（退出码 137" in posted[1][4]


def test_one_reviewers_failure_does_not_swallow_the_next_and_the_first_error_is_reraised(monkeypatch):
    _stub_tokens(monkeypatch, TOKENS)
    posted = []
    def fake_post(org, repo, mr, token, body):
        posted.append(token)
        return token != "pt-kiro"          # Kiro 那条被 Codeup 拒收
    monkeypatch.setattr(backstop.codeup_min, "post_comment", fake_post)
    with pytest.raises(backstop.PostFailed):
        backstop.handler(_ev2(exit_code=137, reviewers_env="kiro,inspector"), None)
    assert posted == ["pt-kiro", "pt-insp"], "Kiro 失败之后 Inspector 那条仍要发"


def test_a_scanner_token_failure_is_reraised_as_secret_unavailable_after_trying_the_rest(monkeypatch):
    client = _stub_tokens(monkeypatch, {"codeup-kiro/yunxiao-token-security": "pt-sec"})  # 只有 SA 的令牌取得到
    posted = []
    monkeypatch.setattr(backstop.codeup_min, "post_comment", lambda *a, **k: posted.append(a[3]) or True)
    # 桩对缺的 SecretId 抛 KeyError，真实 secret_fetch 把它包成 SecretUnavailable（原始异常挂在 __cause__）——断言真实路径的类型
    with pytest.raises(backstop.secret_fetch.SecretUnavailable) as ei:
        backstop.handler(_ev2(exit_code=96, reviewers_env="inspector,security", kind="scan", name="scan"), None)
    assert str(ei.value) == "YUNXIAO_TOKEN_INSPECTOR_ID", "异常消息只有变量名（不带 AWS 错误正文）"
    assert posted == ["pt-sec"]
    assert [c.kwargs["SecretId"] for c in client.get_secret_value.call_args_list] == [
        "codeup-kiro/yunxiao-token-inspector", "codeup-kiro/yunxiao-token-security"]


def test_kiro_only_event_keeps_the_2a_step_log_exactly(monkeypatch, capsys):
    _stub_tokens(monkeypatch, TOKENS)
    monkeypatch.setattr(backstop.codeup_min, "post_comment", lambda *a, **k: True)
    backstop.handler(_ev2(exit_code=137, reviewers_env="kiro"), None)
    assert capsys.readouterr().out == (
        "backstop step=read-mark\nbackstop step=fetch-token\nbackstop step=post-comment\n")


@pytest.mark.parametrize("code, want", [
    (90, "扫描任务的镜像摘要门拒绝了运行（镜像摘要不在已探测名单内，或读不到本容器的镜像摘要）（退出码 90）"),
    (96, "扫描子进程没有正常结束"),
    (137, "扫描任务异常结束（退出码 137"),
    (None, "没有退出码"),
])
def test_scan_task_causes(code, want):
    assert want in backstop.scanner_comment("inspector", code, True, "scan")


@pytest.mark.parametrize("text", [
    lambda: backstop.backstop_comment(143),
    lambda: backstop.scanner_comment("security", 143, True, "scan"),
    lambda: backstop.scanner_comment("security", 143, True, "review"),
], ids=["kiro", "scan", "review"])
def test_a_stopped_task_gets_its_own_cause_not_the_out_of_memory_guess(text):
    """issue 15 开了 init 之后 StopTask 的 SIGTERM 到得了入口，任务以 143 结束（以前是 30 秒后 SIGKILL 的 137）。"""
    body = text()
    assert "被停止（收到 SIGTERM" in body, body
    assert "退出码 143" in body, body
    assert "内存不足" not in body, body


def test_a_scanner_the_executor_recorded_as_disabled_is_not_posted():
    assert _decide_with({"pk": "k", "posted": True, "disabled_inspector": True},
                        exit_code=0, reviewers_env="kiro,inspector") == (False, [])


def test_the_scan_exit_causes_are_exactly_the_scan_entrypoints_fail_closed_exits_and_the_guide_has_each_row():
    import re
    scan = (ROOT / "executor" / "scan-entrypoint.sh").read_text()
    code = "\n".join(ln for ln in scan.splitlines() if not ln.lstrip().startswith("#"))
    exits = {int(n) for n in re.findall(r"\bexit (9[0-9])\b", code)}
    assert exits == set(backstop.SCAN_EXIT_CAUSES) == {90, 95, 96}, exits
    lines = GUIDE.read_text().splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.startswith("## 8."))
    for c in exits:
        rows = [ln for ln in lines[start:] if ln.startswith("|") and f"扫描退出码 {c}" in ln.split(" | ")[0]]
        assert rows, f"§8 没有标着「扫描退出码 {c}」的行，扫描员兜底评论里的指针指空了"
