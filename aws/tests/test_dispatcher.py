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
                               "container_name": "review"}, F, "r1#7#abc123")
    env = ecs.run_task.call_args.kwargs["overrides"]["containerOverrides"][0]["environment"]
    names = {e["name"] for e in env}
    assert {"CODEUP_REPO_ID", "MR_LOCAL_ID", "HEAD_SHA"} <= names

def test_run_task_never_passes_secrets_in_overrides():
    # RunTask 入参进 CloudTrail（I3）。密钥只能走任务定义的 secrets 块。
    ecs = mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "a"}]}
    handler_mod.run_task(ecs, {"cluster": "c", "task_definition": "td", "subnets": ["s"],
                               "security_groups": ["sg"], "container_name": "review"}, F,
                          "r1#7#abc123")
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


# ── Ruling 16：共享密钥在调用时向 Secrets Manager 取，环境变量里只有密钥名 ──────────
# 注入的是**密钥名**（SecretId），不是 partial ARN——理由见 lambda/dispatcher/secret_fetch.py 顶部。
SECRET_ID = "codeup-kiro/webhook-secret"
FULL_ARN = "arn:aws:secretsmanager:us-west-2:111122223333:secret:" + SECRET_ID + "-AbCdEf"
# 真的 ClientError（不是裸 Mock 的 side_effect）：只用 Mock 造异常只能验证我们写的 except 分支，
# 验不到 botocore 真抛出来的那种异常也被同一条 fail-closed 路径接住。正文刻意带账号 ID。
DENIED = bexc.ClientError(
    {"Error": {"Code": "AccessDeniedException",
               "Message": ("User: arn:aws:sts::111122223333:assumed-role/DispatcherRole/x is not "
                           f"authorized to perform: secretsmanager:GetSecretValue on {FULL_ARN}")}},
    "GetSecretValue")


def _stub_secrets(monkeypatch, *responses):
    """让 handler 走**真实**的 secret_fetch.py，只把它内部那句 `import boto3` 换掉。

    不直接把 handler_mod.secret_fetch.secret_from_env 整个替换成桩——那样就只测到自己的桩，
    连「SecretId 传的是不是环境变量里那个密钥名」都测不出来。_CACHE 每个用例换一份新字典
    （monkeypatch 用完自动还原），免得跨用例把值带过去。
    """
    monkeypatch.setenv("WEBHOOK_SECRET_ID", SECRET_ID)
    monkeypatch.setattr(handler_mod.secret_fetch, "_CACHE", {})
    client = mock.Mock()
    client.get_secret_value.side_effect = list(responses)
    boto3 = mock.Mock()
    boto3.client.return_value = client
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    return client


def test_handler_fetches_the_secret_by_the_arn_in_the_env_and_accepts_a_valid_token(monkeypatch):
    client = _stub_secrets(monkeypatch, {"SecretString": "s3cret"})
    assert_alb_response(handler_mod.handler({"headers": {"x-codeup-token": "s3cret"}}, None), 200, "")
    assert client.get_secret_value.call_args.kwargs == {"SecretId": SECRET_ID}


def test_handler_rejects_with_503_when_the_secret_cannot_be_fetched(monkeypatch):
    # fail closed，而且必须是**显式响应**：未捕获异常 → Lambda 报错 → ALB 502，Codeup 只看到
    # 投递失败，与 C1 同属静默失败。503 而不是 401：401 会把我们自己的权限/配置问题伪装成
    # 「对方令牌不对」，运维照着 401 去查 Codeup 那侧，永远查不到 Lambda 少了 GetSecretValue。
    client = _stub_secrets(monkeypatch, DENIED)
    assert_alb_response(
        handler_mod.handler({"headers": {"x-codeup-token": "s3cret"}}, None),
        503, "secret-unavailable")
    # 同时钉住请求形状：只断言错误处理不算，还要证明它真的拿环境变量里那个密钥名去问了。
    assert client.get_secret_value.call_args.kwargs == {"SecretId": SECRET_ID}


def test_the_503_response_leaks_neither_the_account_id_nor_the_aws_message(monkeypatch):
    # M7 的同一条理由：AWS 错误正文是自由文本，带角色 ARN 与账号 ID，绝不进返回给 Codeup 的响应。
    _stub_secrets(monkeypatch, DENIED)
    blob = json.dumps(handler_mod.handler({"headers": {"x-codeup-token": "s3cret"}}, None))
    assert "111122223333" not in blob, blob
    assert "not authorized" not in blob and "assumed-role" not in blob, blob
    assert "secretsmanager" not in blob.lower(), blob


@pytest.mark.parametrize("secret_id", ["", None])
def test_handler_rejects_when_the_secret_id_env_var_is_missing_or_empty(secret_id, monkeypatch):
    # falsy 但有意义：SecretId 为空串是配置错误，不能退化成「expected 是空的」那条 401 路径——
    # 结果同样是拒，但状态码会把我们的配置错误显示成对方令牌不对。
    monkeypatch.setattr(handler_mod.secret_fetch, "_CACHE", {})
    monkeypatch.delenv("WEBHOOK_SECRET_ID", raising=False)
    if secret_id is not None:
        monkeypatch.setenv("WEBHOOK_SECRET_ID", secret_id)
    client = mock.Mock()
    boto3 = mock.Mock()
    boto3.client.return_value = client
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    assert_alb_response(handler_mod.handler({"headers": {"x-codeup-token": "s"}}, None),
                        503, "secret-unavailable")
    assert not client.get_secret_value.called


# ── M3：没带令牌的请求在取密钥之前就被拒 ───────────────────────────────────────
@pytest.mark.parametrize("headers", [{}, None, {"x-codeup-token": ""},
                                     {"X-Codeup-Token": ""}, {"other": "v"}])
def test_a_request_without_a_token_is_rejected_before_any_secret_fetch(headers, monkeypatch):
    # 两个理由：①没带令牌的请求一定被拒，为它跑一次 GetSecretValue 纯属白费配额；
    # ②取密钥正在失败时，任意公网调用者会拿到 503 secret-unavailable——那是在向外泄露内部状态。
    client = _stub_secrets(monkeypatch, DENIED)
    assert_alb_response(handler_mod.handler({"headers": headers}, None), 401, "")
    assert not client.get_secret_value.called, "没带令牌就不该去取密钥"


def test_a_present_but_wrong_token_is_still_rejected_after_fetching(monkeypatch):
    # 正向对照：上面那条提前返回不能把「带了令牌但值不对」也短路掉——那会变成不校验。
    client = _stub_secrets(monkeypatch, {"SecretString": "s3cret"})
    assert_alb_response(handler_mod.handler({"headers": {"x-codeup-token": "nope"}}, None), 401, "")
    assert client.get_secret_value.call_args.kwargs == {"SecretId": SECRET_ID}


@pytest.mark.parametrize("headers,want", [
    ({"x-codeup-token": "t"}, "t"), ({"X-Codeup-Token": "t"}, "t"),
    ({"X-CODEUP-TOKEN": "t"}, "t"), ({}, ""), (None, ""),
    ({"x-codeup-token": ""}, ""), ({"x-codeup-token": None}, "")])
def test_token_header_is_case_insensitive_and_maps_absent_and_empty_to_the_same_thing(headers, want):
    # handler 与 verify_token 共用这一份取头逻辑；空值与缺头必须同一结果，否则
    # 「没带令牌」的判断会和 verify_token 分叉（ALB 转发的头名大小写不保证）。
    assert handler_mod.token_header(headers) == want


# ── I1：fail-closed 路径必须留一行固定形状的日志 ────────────────────────────────
def _log_of_503(monkeypatch, capsys, *responses, env=SECRET_ID):
    monkeypatch.setattr(handler_mod.secret_fetch, "_CACHE", {})
    monkeypatch.delenv("WEBHOOK_SECRET_ID", raising=False)
    if env is not None:
        monkeypatch.setenv("WEBHOOK_SECRET_ID", env)
    client = mock.Mock()
    client.get_secret_value.side_effect = list(responses) or [DENIED]
    boto3 = mock.Mock()
    boto3.client.return_value = client
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    r = handler_mod.handler({"headers": {"x-codeup-token": "s3cret"}}, None)
    assert_alb_response(r, 503, "secret-unavailable")
    return capsys.readouterr().out


def test_the_503_path_logs_the_var_name_and_the_aws_error_code(monkeypatch, capsys):
    # 这条路径在 Lambda 看来是成功调用（Errors 指标为 0），响应正文对四种成因完全一样：
    # 不打这行日志，全新部署一旦配错就只剩一个查不下去的 503（I1）。
    out = _log_of_503(monkeypatch, capsys, DENIED)
    assert "secret-unavailable var=WEBHOOK_SECRET_ID code=AccessDeniedException" in out, out
    assert out.count("\n") == 1, f"只留一行，不要每次调用刷一屏：{out!r}"


@pytest.mark.parametrize("responses,env,code", [
    ([DENIED], SECRET_ID, "AccessDeniedException"),
    ([bexc.ClientError({"Error": {"Code": "ThrottlingException"}}, "GetSecretValue")],
     SECRET_ID, "ThrottlingException"),
    ([bexc.ClientError({"Error": {"Code": "ResourceNotFoundException"}}, "GetSecretValue")],
     SECRET_ID, "ResourceNotFoundException"),
    ([TimeoutError("10.0.0.12 timed out")], SECRET_ID, "TimeoutError"),
    ([{"SecretString": ""}], SECRET_ID, "empty-value"),
    ([{}], SECRET_ID, "empty-value"),
    ([DENIED], None, "env-unset"),
    ([DENIED], "", "env-unset"),
])
def test_the_503_log_code_distinguishes_every_cause(responses, env, code, monkeypatch, capsys):
    # 运维要分清的四类成因（缺 IAM 授权 / 密钥不存在或名字不符 / 密钥值为空 / 限流）加上
    # 「变量根本没配」，每一类都要有自己的代号；全部是固定枚举，没有自由文本。
    out = _log_of_503(monkeypatch, capsys, *responses, env=env)
    assert f"code={code}" in out, (out, code)


def test_the_503_log_line_leaks_neither_the_account_id_nor_the_aws_message(monkeypatch, capsys):
    # 与响应正文同一条要求（M7 的理由）：错误正文是自由文本，带角色 ARN 与账号 ID。
    out = _log_of_503(monkeypatch, capsys, DENIED)
    for leak in ("111122223333", "not authorized", "assumed-role", "arn:", FULL_ARN):
        assert leak not in out, (leak, out)


def test_the_success_path_logs_nothing(monkeypatch, capsys):
    # 正向对照：这行日志只在 fail-closed 路径出现。否则每个正常 webhook 都会刷一行，
    # 上面那条「按 code= 过滤」的排错指引就没法用了。
    _stub_secrets(monkeypatch, {"SecretString": "s3cret"})
    handler_mod.handler({"headers": {"x-codeup-token": "s3cret"}}, None)
    assert capsys.readouterr().out == ""


def test_handler_never_reads_a_bare_plaintext_secret_env_var():
    # 静态守卫：裸名 WEBHOOK_SECRET / YUNXIAO_TOKEN 不得再作为环境变量名出现在源码里
    # （"WEBHOOK_SECRET_ID" 里紧跟的是下划线，所以只查带引号收尾的那种字面量）。
    src = pathlib.Path(handler_mod.__file__).read_text()
    for bare in ('WEBHOOK_SECRET"', "WEBHOOK_SECRET'", 'YUNXIAO_TOKEN"', "YUNXIAO_TOKEN'"):
        assert bare not in src, f"handler.py 仍在读明文环境变量 {bare}"


# ── G5：每条返回路径都是 ALB 可接受的完整响应 ─────────────────────────────────
def test_handler_401_is_a_full_alb_response(monkeypatch):
    _stub_secrets(monkeypatch, {"SecretString": "s3cret"})
    assert_alb_response(handler_mod.handler({"headers": {}}, None), 401, "")


def test_dispatch_duplicate_is_a_full_alb_response():
    table, ecs = mock.Mock(), mock.Mock()
    table.put_item.side_effect = bexc.ClientError(
        {"Error": {"Code": "ConditionalCheckFailedException"}}, "PutItem")
    assert_alb_response(handler_mod.dispatch(ecs, table, _full_cfg(), F), 200, "duplicate")
    assert not ecs.run_task.called, "重复投递不得拉起任务（N3）"


def test_dispatch_runtask_failed_is_a_full_alb_response(monkeypatch):
    monkeypatch.setattr(handler_mod.codeup_min, "post_comment", lambda *a, **k: True)
    table, ecs = mock.Mock(), mock.Mock()
    ecs.run_task.side_effect = RuntimeError("Throttled")
    assert_alb_response(handler_mod.dispatch(ecs, table, _full_cfg(), F), 200, "runtask-failed")


def test_dispatch_dispatched_is_a_full_alb_response():
    table, ecs = mock.Mock(), mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "arn:task/1"}]}
    assert_alb_response(handler_mod.dispatch(ecs, table, _full_cfg(), F), 200, "dispatched")


def test_every_return_in_handler_and_dispatch_goes_through_resp():
    # 静态守卫，管住以后新增的返回路径（Task 5 会加 unparseable/ignored 两条）：handler()/dispatch()
    # 里每一个 return 都必须是 `_resp(...)`；handler 另允许 `return dispatch(...)`（它自己也受这条约束）。
    # 行为用例只覆盖今天存在的路径，新路径写成裸 dict 时只有这条会先红。
    import ast
    tree = ast.parse(pathlib.Path(handler_mod.__file__).read_text())
    allowed = {"handler": {"_resp", "dispatch"}, "dispatch": {"_resp"}}
    seen = set()
    for fn in (n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in allowed):
        seen.add(fn.name)
        for ret in (n for n in ast.walk(fn) if isinstance(n, ast.Return)):
            call = ret.value
            name = (call.func.id if isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
                    else None)
            assert name in allowed[fn.name], \
                f"{fn.name}() 第 {ret.lineno} 行的 return 没有经过 _resp（G5：ALB 会回 502）"
    assert seen == set(allowed), seen


# ── I5 / Task 6 遗留：None 与 "" 行为一致，None 绝不变成字面量 "None" ─────────────
def test_lock_key_treats_none_and_empty_dedupe_extra_the_same():
    no_key = {k: v for k, v in F.items() if k != "dedupe_extra"}
    assert handler_mod.lock_key(dict(F, dedupe_extra=None)) == "r1#7#abc123"
    assert handler_mod.lock_key(dict(F, dedupe_extra="")) == "r1#7#abc123"
    assert handler_mod.lock_key(no_key) == "r1#7#abc123"


def test_dispatch_with_none_dedupe_extra_claims_and_passes_the_three_part_key():
    table, ecs = mock.Mock(), mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "a"}]}
    handler_mod.dispatch(ecs, table, _full_cfg(), dict(F, dedupe_extra=None))
    env = {e["name"]: e["value"] for e in
           ecs.run_task.call_args.kwargs["overrides"]["containerOverrides"][0]["environment"]}
    assert table.put_item.call_args.kwargs["Item"]["pk"] == env["LOCK_KEY"] == "r1#7#abc123"


@pytest.mark.parametrize("field", ["target_branch", "source_branch", "clone_url",
                                   "repo_id", "mr_local_id", "head_sha"])
def test_run_task_never_emits_the_literal_string_none(field):
    # str(None) == "None"：MR_TARGET_BRANCH=None 非空，脚本就不走「按源分支反查目标分支」，
    # 而是拿一个叫 None 的分支当目标分支评审。值为 None 的字段一律不传，缺省由 entrypoint 处理。
    ecs = mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "a"}]}
    handler_mod.run_task(ecs, _full_cfg(), dict(F, **{field: None}), "k")
    env = ecs.run_task.call_args.kwargs["overrides"]["containerOverrides"][0]["environment"]
    assert all(e["value"] != "None" for e in env), env
    assert len(env) == 6, "值为 None 的那一项不传，其余照传"


# ── M7：评论里的原因是 AWS 错误码，不是异常正文 ─────────────────────────────────
def _posted_reason(monkeypatch, exc):
    posted = []
    monkeypatch.setattr(handler_mod.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(a[4]) or True)
    table, ecs = mock.Mock(), mock.Mock()
    ecs.run_task.side_effect = exc
    handler_mod.dispatch(ecs, table, _full_cfg(), F)
    assert len(posted) == 1
    return posted[0]


def test_runtask_client_error_comment_names_the_aws_error_code_only(monkeypatch):
    # 错误码是固定枚举，能区分限流 / 权限 / 集群不存在；错误正文是自由文本（含 ARN、账号 ID），
    # 不得进 MR 评论。
    exc = bexc.ClientError({"Error": {"Code": "AccessDeniedException",
                                      "Message": "arn:aws:iam::123456789012:role/x is not authorized"}},
                           "RunTask")
    body = _posted_reason(monkeypatch, exc)
    assert "`AccessDeniedException`" in body
    assert "123456789012" not in body and "not authorized" not in body, body
    assert "ClientError" not in body, "ClientError 本身区分不了限流与权限"


def test_runtask_other_error_comment_names_the_type_only(monkeypatch):
    body = _posted_reason(monkeypatch, RuntimeError("internal detail 10.0.0.12"))
    assert "`RuntimeError`" in body
    assert "internal detail" not in body and "10.0.0.12" not in body, body
