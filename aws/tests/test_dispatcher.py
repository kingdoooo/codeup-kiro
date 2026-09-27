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


def test_handler_fetches_the_secret_by_the_name_in_the_env_and_accepts_a_valid_token(monkeypatch):
    # `_runtime_cfg` 换成桩，好让这条用例只管令牌这一段：否则它会连云效令牌一起取，
    # 下面那句「取的是环境变量里那个密钥名」的断言就会指到第二次调用上（接线本身另有用例覆盖）。
    monkeypatch.setattr(handler_mod, "_runtime_cfg", lambda: _full_cfg(org_id=FIX_ORG))
    client = _stub_secrets(monkeypatch, {"SecretString": "s3cret"})
    # 令牌对了之后这次投递没有事件头 → classify 判 ignore（不是「验完签名就返回 200」）。
    assert_alb_response(handler_mod.handler({"headers": {"x-codeup-token": "s3cret"}}, None),
                        200, "ignored")
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
    monkeypatch.setattr(handler_mod, "_runtime_cfg", lambda: _full_cfg(org_id=FIX_ORG))
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
    # 静态守卫，管住以后新增的返回路径（Task 5 已加 unparseable/ignored 两条）：handler()/dispatch()
    # 里每一个 return 都必须是 `_resp(...)`；handler 另允许 `return dispatch(...)` 与
    # `return _secret_unavailable(...)`——这两个自己也在这份名单里受同一条约束。
    # 行为用例只覆盖今天存在的路径，新路径写成裸 dict 时只有这条会先红。
    import ast
    tree = ast.parse(pathlib.Path(handler_mod.__file__).read_text())
    allowed = {"handler": {"_resp", "dispatch", "_secret_unavailable"},
               "dispatch": {"_resp"}, "_secret_unavailable": {"_resp"}}
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


# ── Task 5：事件过滤（classify）──────────────────────────────────────────────
# 六个 fixture 是 Task 1 抓到的**真实投递**（唯一改动是把 email 换成 user@example.com），
# 字段路径按结论文件 §1，不按文档猜：文档写的是旧版报文，真实投递是 `version: new`。
FIX = pathlib.Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "webhook"

def _fix(name):
    return json.loads((FIX / name).read_text())

# 真实 fixture 的组织 id。classify 要用它核对 clone 地址的前缀，所以每个 cfg 都得带上
# （`_full_cfg()` 的默认 org_id 是 "o1"，那是给不过 classify 的 dispatch 用例用的）。
FIX_ORG = "0123456789abcdef01234567"

CFG = {"org_id": FIX_ORG, "bot_usernames": ["aliyun:kirobot"], "review_command": 1,
       "command_phrase": "/kiro review", "target_branch_filter": ""}

# 真实头名是 `X-Codeup-Event`（ALB 交给 Lambda 时小写）。计划原文写的 `codeup-event` 永远匹配不上。
MR_HDR = {"x-codeup-event": "Merge Request Hook"}
NOTE_HDR = {"x-codeup-event": "Note Hook"}


def test_mr_opened_is_reviewed():
    kind, f = handler_mod.classify({"x-codeup-event": "Merge Request Hook"}, _fix("mr-opened.json"), CFG)
    assert kind == "review"
    assert f["head_sha"] and f["mr_local_id"] and f["repo_id"]

def test_mr_updated_is_reviewed():
    kind, _ = handler_mod.classify({"x-codeup-event": "Merge Request Hook"}, _fix("mr-updated.json"), CFG)
    assert kind == "review"

def test_approved_mr_is_not_a_new_review():
    # 真实形状（Task 1）：通过 = action "accept"、state "accepted"，不是新评审。
    assert handler_mod.classify({"x-codeup-event": "Merge Request Hook"},
                                _fix("mr-approved.json"), CFG)[0] == "ignore"

def test_push_after_approval_is_reviewed_again():
    # 真实形状（Task 1）：通过之后再推送，state 回到 opened、is_update_by_push 为 true。
    kind, f = handler_mod.classify({"x-codeup-event": "Merge Request Hook"},
                                   _fix("mr-updated-after-approval.json"), CFG)
    assert kind == "review" and f["head_sha"]

def test_update_without_push_is_ignored():
    # 改标题之类的 update 没有新代码。没有真实样本，按真实字段路径改 mr-updated.json 的副本。
    body = _fix("mr-updated.json")
    body["object_attributes"]["is_update_by_push"] = False
    assert handler_mod.classify({"x-codeup-event": "Merge Request Hook"}, body, CFG)[0] == "ignore"

def test_an_update_whose_push_flag_is_missing_is_still_reviewed():
    # 「字段缺失时退回只看 state」：`is_update_by_push is False` 必须是**恒等于 False** 的判断，
    # 写成 `not _dig(...)` 的话字段缺失（None）就变成 ignore——Codeup 哪天不发这个字段，
    # 所有 update 事件就静默不评了。
    body = _fix("mr-updated.json")
    del body["object_attributes"]["is_update_by_push"]
    assert handler_mod.classify(MR_HDR, body, CFG)[0] == "review"

def test_an_update_by_push_is_reviewed_even_though_the_extra_filter_exists():
    # 正向对照：额外过滤只丢「update 且明确不是推送」这一种，不能把所有 update 一起丢掉。
    body = _fix("mr-updated.json")
    assert body["object_attributes"]["action"] == "update"
    assert body["object_attributes"]["is_update_by_push"] is True
    assert handler_mod.classify(MR_HDR, body, CFG)[0] == "review"

def test_note_carrying_the_kiro_review_marker_is_ignored_even_from_a_human_account():
    # 真实样本：Flow 的评审评论，作者与 MR 作者是同一个账号，所以作者名单断不了环。
    cfg = dict(CFG, bot_usernames=[])
    assert handler_mod.classify({"x-codeup-event": "Note Hook"},
                                _fix("note-bot-review.json"), cfg)[0] == "ignore"

def test_merged_or_closed_state_is_ignored():
    body = _fix("mr-opened.json")
    for state in ("merged", "closed", "locked"):
        _set_state(body, state)
        assert handler_mod.classify({"x-codeup-event": "Merge Request Hook"}, body, CFG)[0] == "ignore"

def test_unknown_event_type_is_ignored_not_guessed():
    assert handler_mod.classify({"x-codeup-event": "Pipeline Hook"}, {}, CFG)[0] == "ignore"

def test_unknown_payload_shape_is_ignored():
    assert handler_mod.classify({"x-codeup-event": "Merge Request Hook"}, {"nope": 1}, CFG)[0] == "ignore"

def test_note_from_own_bot_is_ignored_to_break_the_loop():
    body = _fix("note-mr-new.json")
    _set_note_author(body, "aliyun:kirobot")
    _set_note_text(body, "/kiro review")
    assert handler_mod.classify({"x-codeup-event": "Note Hook"}, body, CFG)[0] == "ignore"

def test_a_note_whose_author_is_not_a_string_is_ignored_without_raising():
    # `{...} in set(...)` 会因为不可哈希抛 TypeError，`{...} in [...]` 则悄悄不匹配——
    # 前者逃出 handler 就是 ALB 502，后者是在形状不明的报文上继续往下走。一律 ignore（N6）。
    for bad in ({"a": 1}, ["x"], 7):
        body = _fix("note-mr-new.json")
        body["user"]["username"] = bad
        _set_note_text(body, "/kiro review")
        assert handler_mod.classify(NOTE_HDR, body, CFG)[0] == "ignore", bad

@pytest.mark.parametrize("mutate", [lambda b: b["user"].__setitem__("username", None),
                                    lambda b: b["user"].pop("username"),
                                    lambda b: b.__setitem__("user", None),
                                    lambda b: b.pop("user")])
def test_a_note_without_an_author_name_still_gets_reviewed(mutate):
    """作者名缺失（或显式 null）按「没给作者」处理，继续往下走，**不**变成 ignore。

    缺失与空串行为一致是既有约定（见 lock_key 那组用例）。这里不 fail closed 的理由：断环真正
    承重的是 `<!-- kiro-review:` 标记那道（本方机器人与人可以是同一个账号，作者名单本来就靠不住），
    空串永远不可能等于某个真实的机器人用户名；反过来若因为缺这个字段就 ignore，Codeup 哪天不发
    `user.username`，评论命令就整体静默失效——那正是本轮要消灭的一类静默失败。
    """
    body = _fix("note-mr-new.json")
    mutate(body)
    _set_note_text(body, "/kiro review")
    assert handler_mod.classify(NOTE_HDR, body, CFG)[0] == "review"

def test_a_note_whose_body_is_not_a_string_is_ignored_without_raising():
    # `phrase in note` 对非字符串会抛 TypeError → 502。
    for bad in ({"a": 1}, ["x"], 7):
        body = _fix("note-mr-new.json")
        body["object_attributes"]["note"] = bad
        assert handler_mod.classify(NOTE_HDR, body, CFG)[0] == "ignore", bad

def test_system_note_is_ignored():
    body = _fix("note-mr-new.json")
    _set_note_system(body, True)
    _set_note_text(body, "/kiro review")
    assert handler_mod.classify({"x-codeup-event": "Note Hook"}, body, CFG)[0] == "ignore"

def test_note_without_command_phrase_is_ignored():
    body = _fix("note-mr-new.json")
    _set_note_text(body, "looks good to me")
    assert handler_mod.classify({"x-codeup-event": "Note Hook"}, body, CFG)[0] == "ignore"

def test_note_with_command_from_human_triggers_review_and_carries_comment_id():
    body = _fix("note-mr-new.json")
    _set_note_text(body, "/kiro review")
    kind, f = handler_mod.classify({"x-codeup-event": "Note Hook"}, body, CFG)
    assert kind == "review"
    # 精确值，不是真值判断：原文用不存在的 object_attributes.id 取值，恒为空串（Task 1）。
    assert f["dedupe_extra"] == body["object_attributes"]["note_biz_id"], "评论命令的去重键必须是评论 id"

def test_target_branch_filter_excludes_non_matching():
    cfg = dict(CFG, target_branch_filter=r"^release/")
    assert handler_mod.classify({"x-codeup-event": "Merge Request Hook"},
                                _fix("mr-opened.json"), cfg)[0] == "ignore"


# ── 上面那组的补强：几处「恒绿的守卫」与「falsy 但有意义」─────────────────────────
# AWS 档位的真实页脚：pipeline/setup-guide.md 明确写了本档位要把 REVIEW_RERUN_HINT 设成
# 「评论 `/kiro review` 可重新评审」。届时机器人自己的评审评论正文里**就带着命令短语**，
# 而机器人与人可以是同一个账号（Task 1 实测）——这才是无穷循环的真实形状。
# 真实 note-bot-review.json 的正文不含这句短语，所以上面那条真实样本用例即使删掉标记守卫
# 也照样绿（假绿）；这条才是标记守卫的变异证据。
def _bot_review_note_with_the_aws_tier_footer():
    body = _fix("note-bot-review.json")
    body["object_attributes"]["note"] += "\n第 1 次评审 · 评论 `/kiro review` 可重新评审"
    return body

def test_bot_review_comment_whose_footer_contains_the_command_phrase_is_still_ignored():
    cfg = dict(CFG, bot_usernames=[])          # 机器人 == 人：作者名单断不了环
    body = _bot_review_note_with_the_aws_tier_footer()
    assert CFG["command_phrase"] in body["object_attributes"]["note"], "本用例的前提：正文确实带命令短语"
    assert handler_mod.classify(NOTE_HDR, body, cfg)[0] == "ignore", \
        "本方评审评论必须靠 kiro-review 标记断环，否则页脚里的短语会让它自己触发自己"

def test_a_human_comment_that_only_quotes_the_phrase_still_triggers_a_review():
    # 正向对照：上面那道标记守卫不能退化成「凡是提到短语就不评」。
    body = _fix("note-mr-new.json")
    _set_note_text(body, "麻烦重跑一下：/kiro review")
    assert handler_mod.classify(NOTE_HDR, body, CFG)[0] == "review"

def test_an_empty_command_phrase_does_not_turn_every_comment_into_a_review():
    # falsy 但有意义：`"" in note` 恒真 → 每条评论都触发评审，连机器人自己那条也算 → 循环。
    # REVIEW_COMMAND_PHRASE 被显式设成空串就会落到这里，必须 fail closed。
    body = _fix("note-mr-new.json")
    _set_note_text(body, "looks good to me")
    assert handler_mod.classify(NOTE_HDR, body, dict(CFG, command_phrase=""))[0] == "ignore"
    assert handler_mod.classify(NOTE_HDR, body, dict(CFG, command_phrase=None))[0] == "ignore"

def test_review_command_disabled_ignores_the_command():
    # 开关关掉时评论命令一律不生效（review_command 是 0/1 的整数）。
    body = _fix("note-mr-new.json")
    _set_note_text(body, "/kiro review")
    assert handler_mod.classify(NOTE_HDR, body, dict(CFG, review_command=0))[0] == "ignore"

def test_target_branch_filter_admits_a_matching_branch():
    # 正向对照：上面那条排除用例不能靠「过滤器一非空就全排除」通过。
    cfg = dict(CFG, target_branch_filter=r"^master$")
    assert handler_mod.classify(MR_HDR, _fix("mr-opened.json"), cfg)[0] == "review"

def test_target_branch_filter_also_applies_to_a_comment_command():
    cfg = dict(CFG, target_branch_filter=r"^release/")
    body = _fix("note-mr-new.json")
    _set_note_text(body, "/kiro review")
    assert handler_mod.classify(NOTE_HDR, body, cfg)[0] == "ignore"

def test_an_invalid_target_branch_filter_fails_closed_with_one_log_line(capsys):
    # 配错的正则原本会让 re.search 抛 re.error 逃出 handler → ALB 502 → Codeup 只看到投递失败
    # （与 C1 同属静默失败）。改成 fail closed + 一行固定形状日志，运维才有痕迹可查。
    cfg = dict(CFG, target_branch_filter="[unclosed(?P<x>")
    assert handler_mod.classify(MR_HDR, _fix("mr-opened.json"), cfg)[0] == "ignore"
    out = capsys.readouterr().out
    assert out == "bad-target-branch-filter var=TARGET_BRANCH_FILTER\n", out
    # docstring 承诺了「日志里不带正则本身」（它是自由文本），这里就得钉住
    for leak in ("[unclosed", "(?P<x>", "unclosed"):
        assert leak not in out, (leak, out)


# ── 字段抽取：整数变字符串、0 不是「缺失」、任一必需字段缺失就 ignore ─────────────
def test_mr_fields_are_strings_because_they_flow_into_container_env():
    # containerOverrides.environment 的值必须是字符串；project_id / local_id 在报文里是整数。
    _, f = handler_mod.classify(MR_HDR, _fix("mr-opened.json"), CFG)
    assert f == {"repo_id": "7215683", "mr_local_id": "6",
                 "source_branch": "probe/p2a08-20260927", "target_branch": "master",
                 "head_sha": "0731ec9d3a8cddf524bca91e6fe799b19d0b01f9",
                 "clone_url": "https://codeup.aliyun.com/0123456789abcdef01234567/demo-app.git",
                 "dedupe_extra": ""}
    assert all(isinstance(v, str) for v in f.values()), f

def test_note_fields_come_from_the_merge_request_object():
    # Note Hook 的同名字段在 `merge_request` 下，不在 `object_attributes` 下（Task 1 §1）。
    body = _fix("note-mr-new.json")
    _set_note_text(body, "/kiro review")
    _, f = handler_mod.classify(NOTE_HDR, body, CFG)
    assert f["repo_id"] == "7215683" and f["mr_local_id"] == "6"
    assert f["head_sha"] == body["merge_request"]["last_commit"]["id"]
    assert f["target_branch"] == "master" and f["source_branch"] == "probe/p2a08-20260927"
    assert f["clone_url"] == body["repository"]["git_http_url"]

@pytest.mark.parametrize("field", ["project_id", "local_id"])
def test_a_zero_int_field_is_not_treated_as_missing(field):
    # falsy 但有意义：local_id/project_id 为 0 是合法取值，`if not v` 会把它当成缺失、
    # 于是整条 MR 静默不评。必须用显式的 None 判断。
    body = _fix("mr-opened.json")
    body["object_attributes"][field] = 0
    kind, f = handler_mod.classify(MR_HDR, body, CFG)
    assert kind == "review"
    assert f["repo_id" if field == "project_id" else "mr_local_id"] == "0"

@pytest.mark.parametrize("path", [("object_attributes", "project_id"),
                                  ("object_attributes", "local_id"),
                                  ("object_attributes", "source_branch"),
                                  ("object_attributes", "target_branch"),
                                  ("object_attributes", "last_commit"),
                                  ("repository", "git_http_url"),
                                  ("repository",)])
def test_mr_event_missing_any_required_field_is_ignored(path):
    body = _fix("mr-opened.json")
    cur = body
    for k in path[:-1]:
        cur = cur[k]
    del cur[path[-1]]
    assert handler_mod.classify(MR_HDR, body, CFG)[0] == "ignore"

@pytest.mark.parametrize("path", [("merge_request", "project_id"),
                                  ("merge_request", "local_id"),
                                  ("merge_request", "source_branch"),
                                  ("merge_request", "target_branch"),
                                  ("merge_request", "last_commit"),
                                  ("repository", "git_http_url"),
                                  ("merge_request",)])
def test_note_event_missing_any_required_field_is_ignored(path):
    body = _fix("note-mr-new.json")
    _set_note_text(body, "/kiro review")
    cur = body
    for k in path[:-1]:
        cur = cur[k]
    del cur[path[-1]]
    assert handler_mod.classify(NOTE_HDR, body, CFG)[0] == "ignore"

def test_a_note_without_a_comment_id_is_ignored_because_it_cannot_be_deduped():
    body = _fix("note-mr-new.json")
    _set_note_text(body, "/kiro review")
    del body["object_attributes"]["note_biz_id"]
    assert handler_mod.classify(NOTE_HDR, body, CFG)[0] == "ignore"

@pytest.mark.parametrize("bad", [{"a": 1}, ["x"], True, 1.5])
def test_a_non_scalar_in_a_required_field_is_ignored_not_stringified(bad):
    # str({"a": 1}) 会把一个字典原样塞进 CODEUP_REPO_ID。形状不对就 ignore，不猜（N6）。
    body = _fix("mr-opened.json")
    body["object_attributes"]["project_id"] = bad
    assert handler_mod.classify(MR_HDR, body, CFG)[0] == "ignore"

def test_a_non_dict_payload_is_ignored_without_raising():
    for body in ([], "x", None, 7):
        assert handler_mod.classify(MR_HDR, body, CFG)[0] == "ignore"
        assert handler_mod.classify(NOTE_HDR, body, CFG)[0] == "ignore"


# ── 事件头：大小写不敏感，且名字写错不能退化成「什么都评」或「什么都不评」───────────
@pytest.mark.parametrize("name", ["x-codeup-event", "X-Codeup-Event", "X-CODEUP-EVENT"])
def test_the_event_header_is_matched_case_insensitively(name):
    assert handler_mod.classify({name: "Merge Request Hook"}, _fix("mr-opened.json"), CFG)[0] == "review"

@pytest.mark.parametrize("value", ["merge request hook", "MERGE REQUEST HOOK", " Merge Request Hook "])
def test_the_event_value_is_normalised(value):
    assert handler_mod.classify({"x-codeup-event": value}, _fix("mr-opened.json"), CFG)[0] == "review"

@pytest.mark.parametrize("headers", [{}, None, {"codeup-event": "Merge Request Hook"},
                                     {"x-gitlab-event": "Merge Request Hook"}])
def test_a_missing_or_misnamed_event_header_is_ignored(headers):
    # 计划原文把头名写成 `codeup-event`：那样每一个投递都判 ignore，而用例照样绿（Task 1 §6.4）。
    assert handler_mod.classify(headers, _fix("mr-opened.json"), CFG)[0] == "ignore"


# ── Step 6：handler() 端到端接线 ────────────────────────────────────────────
TOKEN_SECRET_ID = "codeup-kiro/yunxiao-token-kiro"   # 与 stacks/dispatcher_stack.py 注入的密钥名一致


def _set_runtime_env(monkeypatch):
    """_runtime_cfg 需要的非敏感环境变量，名字与 dispatcher_stack.py 注入的完全一致。"""
    cfg = _full_cfg()
    for name, value in (("YUNXIAO_ORG_ID", FIX_ORG),   # 真实 fixture 的组织 id：classify 要核对 clone 前缀
                        ("YUNXIAO_TOKEN_ID", TOKEN_SECRET_ID),
                        ("ECS_CLUSTER", cfg["cluster"]),
                        ("ECS_TASK_DEFINITION", cfg["task_definition"]),
                        ("ECS_CONTAINER_NAME", cfg["container_name"]),
                        ("SUBNET_IDS", ",".join(cfg["subnets"])),
                        ("SECURITY_GROUP_IDS", ",".join(cfg["security_groups"])),
                        ("LOCK_TABLE", "ReviewLock"),
                        ("LOCK_TTL_SECONDS", str(cfg["lock_ttl_seconds"])),
                        ("BOT_USERNAMES", ",".join(cfg["bot_usernames"])),
                        ("REVIEW_COMMAND", str(cfg["review_command"])),
                        ("REVIEW_COMMAND_PHRASE", cfg["command_phrase"]),
                        ("TARGET_BRANCH_FILTER", cfg["target_branch_filter"])):
        monkeypatch.setenv(name, value)


def test_handler_end_to_end_valid_mr_event_launches_a_task(monkeypatch):
    """签名有效的 MR 事件必须真的走到 RunTask——这条用例是唯一能发现
    「各部件都对、但入口没接起来」的守卫。"""
    ecs, table = mock.Mock(), mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "arn:task/1"}]}
    monkeypatch.setattr(handler_mod, "_clients", lambda cfg: (ecs, table))
    monkeypatch.setattr(handler_mod, "_runtime_cfg", lambda: _full_cfg(org_id=FIX_ORG))
    _stub_secrets(monkeypatch, {"SecretString": "s3cret"})  # secrets wave 已提供的助手，走真实 secret_fetch
    resp = handler_mod.handler({
        "headers": {"x-codeup-token": "s3cret", "x-codeup-event": "Merge Request Hook"},
        "body": (FIX / "mr-opened.json").read_text(),
    }, None)
    assert resp["statusCode"] == 200
    assert ecs.run_task.called, "入口必须真的拉起任务，而不是验完签名就返回 200"


def test_handler_rejects_bad_token_without_reaching_classify(monkeypatch):
    called = []
    monkeypatch.setattr(handler_mod, "classify", lambda *a: called.append(1) or ("ignore", None))
    _stub_secrets(monkeypatch, {"SecretString": "s3cret"})  # secrets wave 已提供的助手，走真实 secret_fetch
    resp = handler_mod.handler({"headers": {"x-codeup-token": "wrong"}, "body": "{}"}, None)
    assert resp["statusCode"] == 401
    assert not called, "验签失败必须在解析之前短路"


def test_handler_ignores_a_filtered_event_without_launching(monkeypatch):
    ecs, table = mock.Mock(), mock.Mock()
    monkeypatch.setattr(handler_mod, "_clients", lambda cfg: (ecs, table))
    monkeypatch.setattr(handler_mod, "_runtime_cfg", lambda: _full_cfg(org_id=FIX_ORG))
    _stub_secrets(monkeypatch, {"SecretString": "s3cret"})  # secrets wave 已提供的助手，走真实 secret_fetch
    resp = handler_mod.handler({
        "headers": {"x-codeup-token": "s3cret", "x-codeup-event": "Pipeline Hook"},
        "body": "{}"}, None)
    assert resp["statusCode"] == 200
    assert not ecs.run_task.called


def test_handler_end_to_end_with_the_real_runtime_cfg_passes_the_fixture_values_to_run_task(monkeypatch):
    """不 stub `_runtime_cfg`：上面那条 e2e 用例把它整个换掉了，所以环境变量名写错、
    `codeup_token` 忘了经 Secrets Manager 取，它一概发现不了。这条走真实 `_runtime_cfg`
    与真实 `secret_fetch`，并**钉住 RunTask 的请求形状**（不只是「被调用过」）。
    """
    ecs, table = mock.Mock(), mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "arn:task/1"}]}
    monkeypatch.setattr(handler_mod, "_clients", lambda cfg: (ecs, table))
    client = _stub_secrets(monkeypatch, {"SecretString": "s3cret"}, {"SecretString": "t0ken"})
    _set_runtime_env(monkeypatch)
    assert_alb_response(handler_mod.handler({
        "headers": {"X-Codeup-Token": "s3cret", "X-Codeup-Event": "Merge Request Hook"},
        "body": (FIX / "mr-opened.json").read_text()}, None), 200, "dispatched")
    kwargs = ecs.run_task.call_args.kwargs
    assert kwargs["cluster"] == "c" and kwargs["taskDefinition"] == "td"
    env = {e["name"]: e["value"] for e in
           kwargs["overrides"]["containerOverrides"][0]["environment"]}
    assert env == {"CODEUP_REPO_ID": "7215683", "MR_LOCAL_ID": "6",
                   "MR_TARGET_BRANCH": "master",
                   "CI_COMMIT_REF_NAME": "probe/p2a08-20260927",
                   "HEAD_SHA": "0731ec9d3a8cddf524bca91e6fe799b19d0b01f9",
                   "BUSINESS_REPO_URL":
                       "https://codeup.aliyun.com/0123456789abcdef01234567/demo-app.git",
                   "LOCK_KEY": "7215683#6#0731ec9d3a8cddf524bca91e6fe799b19d0b01f9"}, env
    # 抢锁必须在 RunTask 之前（N3），且用的是同一个键（I1）
    assert table.put_item.call_args.kwargs["Item"]["pk"] == env["LOCK_KEY"]
    # 云效令牌只从 Secrets Manager 来，且取的是环境变量里那个密钥名
    assert [c.kwargs["SecretId"] for c in client.get_secret_value.call_args_list] == \
        [SECRET_ID, TOKEN_SECRET_ID]


def test_handler_end_to_end_reads_a_base64_encoded_body(monkeypatch):
    # ALB 对非 text/*、application/json 的类型会改成 base64（G6）。正文必须经 _body_text 取，
    # 否则 Codeup 换一个 Content-Type 就变成「每一条都 unparseable」。
    import base64
    ecs, table = mock.Mock(), mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "arn:task/1"}]}
    monkeypatch.setattr(handler_mod, "_clients", lambda cfg: (ecs, table))
    monkeypatch.setattr(handler_mod, "_runtime_cfg", lambda: _full_cfg(org_id=FIX_ORG))
    _stub_secrets(monkeypatch, {"SecretString": "s3cret"})
    raw = (FIX / "mr-opened.json").read_bytes()
    assert_alb_response(handler_mod.handler({
        "headers": {"x-codeup-token": "s3cret", "x-codeup-event": "Merge Request Hook"},
        "isBase64Encoded": True,
        "body": base64.b64encode(raw).decode("ascii")}, None), 200, "dispatched")
    assert ecs.run_task.called


@pytest.mark.parametrize("body", ["not json", "{", "", None, '{"a": 1', "\udcff"])
def test_handler_unparseable_body_is_a_full_alb_response_and_launches_nothing(body, monkeypatch):
    # 新增的返回路径要各有一条完整形状断言：ALB 收到缺字段的响应会回 502（G5）。
    ecs, table = mock.Mock(), mock.Mock()
    monkeypatch.setattr(handler_mod, "_clients", lambda cfg: (ecs, table))
    monkeypatch.setattr(handler_mod, "_runtime_cfg", lambda: _full_cfg(org_id=FIX_ORG))
    _stub_secrets(monkeypatch, {"SecretString": "s3cret"})
    want = "ignored" if body in ("", None) else "unparseable"   # 空正文 → {} → 形状不对 → ignored
    assert_alb_response(handler_mod.handler({
        "headers": {"x-codeup-token": "s3cret", "x-codeup-event": "Merge Request Hook"},
        "body": body}, None), 200, want)
    assert not ecs.run_task.called


def test_handler_ignored_is_a_full_alb_response(monkeypatch):
    ecs, table = mock.Mock(), mock.Mock()
    monkeypatch.setattr(handler_mod, "_clients", lambda cfg: (ecs, table))
    monkeypatch.setattr(handler_mod, "_runtime_cfg", lambda: _full_cfg(org_id=FIX_ORG))
    _stub_secrets(monkeypatch, {"SecretString": "s3cret"})
    assert_alb_response(handler_mod.handler({
        "headers": {"x-codeup-token": "s3cret", "x-codeup-event": "Merge Request Hook"},
        "body": (FIX / "mr-approved.json").read_text()}, None), 200, "ignored")
    assert not ecs.run_task.called


def test_handler_returns_503_when_the_codeup_token_cannot_be_fetched(monkeypatch, capsys):
    """云效令牌取不到时，必须走与 WEBHOOK_SECRET_ID **同一条** 503 + 固定形状日志路径。"""
    ecs, table = mock.Mock(), mock.Mock()
    monkeypatch.setattr(handler_mod, "_clients", lambda cfg: (ecs, table))
    client = _stub_secrets(monkeypatch, {"SecretString": "s3cret"}, DENIED)
    _set_runtime_env(monkeypatch)
    assert_alb_response(handler_mod.handler({
        "headers": {"x-codeup-token": "s3cret", "x-codeup-event": "Merge Request Hook"},
        "body": (FIX / "mr-opened.json").read_text()}, None), 503, "secret-unavailable")
    out = capsys.readouterr().out
    assert "secret-unavailable var=YUNXIAO_TOKEN_ID code=AccessDeniedException" in out, out
    assert out.count("\n") == 1, f"只留一行：{out!r}"
    for leak in ("111122223333", "not authorized", "assumed-role", "arn:", FULL_ARN):
        assert leak not in out, (leak, out)
    assert not ecs.run_task.called, "取不到令牌就不能拉起任务：失败时没法在 MR 上留痕（I10）"
    # 请求形状，不只是错误处理：第二次问的必须是 YUNXIAO_TOKEN_ID 里那个密钥名
    assert [c.kwargs["SecretId"] for c in client.get_secret_value.call_args_list] == \
        [SECRET_ID, TOKEN_SECRET_ID]


def test_the_codeup_token_never_comes_from_a_plaintext_env_var(monkeypatch):
    # 既有裁决：codeup_token 永远不是 config.yaml / 环境变量的字段。把明文变量设上也不该被用到。
    monkeypatch.setenv("YUNXIAO_TOKEN", "plaintext-must-not-be-used")
    client = _stub_secrets(monkeypatch, {"SecretString": "t0ken"})
    _set_runtime_env(monkeypatch)
    cfg = handler_mod._runtime_cfg()
    assert cfg["codeup_token"] == "t0ken"
    assert client.get_secret_value.call_args.kwargs == {"SecretId": TOKEN_SECRET_ID}


# ── Fix round 1 / I-1 + M-1：断环按 `<!-- kiro-` 前缀，覆盖本方写出去的每一种评论 ─────────
# 本方评论至少五种标记：评审汇总 `<!-- kiro-review:`、发布随机串 `<!-- kiro-review-post:`、
# 历次记录 `<!-- kiro-history:`、行内评论 `<!-- kiro-inline:`（scripts/lib/review-render.sh），
# 以及调度器与兜底 Lambda 自己的失败评论。只认第一种时，其余几种一旦正文里带上命令短语就会
# 触发新一轮评审，而机器人与人可以是同一个账号 → 作者名单也断不了环 → 无穷循环。
BACKSTOP = load_lambda("dispatcher_tests_backstop", ROOT / "lambda" / "backstop" / "handler.py")

# 与本方评论标题重叠的短语：默认短语 `/kiro review` 不会出现在这些评论里，所以只用默认短语测
# 等于什么都没测（守卫恒绿）。这个取值是 setup-guide 明确允许配的那一类。
OVERLAP_PHRASE = "Kiro 代码评审"
LOOP_CFG = dict(CFG, bot_usernames=[], command_phrase=OVERLAP_PHRASE)


def _note_with(text):
    body = _fix("note-mr-new.json")
    _set_note_text(body, text)
    return body


def test_an_inline_review_comment_is_ignored_even_when_it_quotes_the_command_phrase():
    # 行内评论的真实标记形状见 review-render.sh:934-945（新格式带指纹/行号/等级）。
    note = ("这里建议改成 early return，否则和上面的分支重复。\n"
            "<!-- kiro-inline:" + "a" * 40 + " L3-3 sev=P1 -->")
    assert OVERLAP_PHRASE not in note      # 这条不靠标题重叠，靠下面那条 cfg 的短语
    body = _note_with(note + "\n" + OVERLAP_PHRASE)
    assert handler_mod.classify(NOTE_HDR, body, LOOP_CFG)[0] == "ignore", \
        "行内评论也是本方评论，必须断环（N5）"


def test_the_dispatchers_own_failure_comment_is_ignored():
    # 用**生产那一份**正文（handler_mod.failed_comment），不抄副本：抄的那份迟早与线上分叉。
    body = _note_with(handler_mod.failed_comment("ThrottlingException"))
    assert OVERLAP_PHRASE in body["object_attributes"]["note"], "前提：短语确实与这条评论重叠"
    assert handler_mod.classify(NOTE_HDR, body, LOOP_CFG)[0] == "ignore", \
        "拉起任务持续失败时，失败评论不能把自己再触发一轮（每次都是新的 note_biz_id，抢锁拦不住）"


def test_the_backstops_own_comment_is_ignored():
    body = _note_with(BACKSTOP.BACKSTOP_COMMENT)
    assert OVERLAP_PHRASE in BACKSTOP.BACKSTOP_COMMENT, "前提：短语确实与这条评论重叠"
    assert handler_mod.classify(NOTE_HDR, body, LOOP_CFG)[0] == "ignore"


def test_both_failure_comments_actually_carry_a_kiro_marker():
    # 直接钉住「标记在正文里」这件事：上面两条用例即使标记被删掉也可能因为别的原因变绿。
    for text in (handler_mod.failed_comment("X"), BACKSTOP.BACKSTOP_COMMENT):
        assert handler_mod.REVIEW_MARKER in text, text
    assert handler_mod.DISPATCH_FAILED_MARKER in handler_mod.failed_comment("X")
    assert BACKSTOP.BACKSTOP_MARKER in BACKSTOP.BACKSTOP_COMMENT
    # 两个标记不得与评审脚本那几种混淆：脚本按 `kiro-review:<载荷> run:N` / `kiro-inline:<指纹>`
    # 这类带载荷的形状找自己的评论，我们这两个不带冒号载荷，匹配不到。
    for marker in (handler_mod.DISPATCH_FAILED_MARKER, BACKSTOP.BACKSTOP_MARKER):
        assert ":" not in marker, marker


def test_a_human_comment_still_triggers_a_review_with_the_overlapping_phrase():
    # 正向对照：上面三条不是因为「这个短语永远匹配不上」而绿的。
    assert handler_mod.classify(NOTE_HDR, _note_with("辛苦，" + OVERLAP_PHRASE),
                                LOOP_CFG)[0] == "review"


# ── Fix round 1 / I-2(a)：报文取来的标量必须过形状，否则 ignore + 一行固定代号 ───────────
# 这些标量会变成 clone 的 URL、`git checkout` 的参数与锁键。webhook 鉴权只是一个共享密钥，
# 拿到它就能把 repository.git_http_url 改成任意主机，而执行器的凭证 helper 会把云效组织令牌
# 交给那台主机——弱密钥就此升级成组织令牌。
EVIL_URL = "https://evil.example/x.git"


def _mr_with(**over):
    body = _fix("mr-opened.json")
    for k, v in over.items():
        if k == "clone_url":
            body["repository"]["git_http_url"] = v
        else:
            body["object_attributes"][k] = v
    return body


def _note_body_with(**over):
    body = _note_with("/kiro review")
    for k, v in over.items():
        if k == "clone_url":
            body["repository"]["git_http_url"] = v
        else:
            body["merge_request"][k] = v
    return body


@pytest.mark.parametrize("url,code", [
    (EVIL_URL, "clone-url-prefix"),
    ("http://codeup.aliyun.com/0123456789abcdef01234567/demo-app.git", "clone-url-prefix"),
    ("https://codeup.aliyun.com.evil.example/0123456789abcdef01234567/x.git", "clone-url-prefix"),
    ("https://codeup.aliyun.com/other-org/demo-app.git", "clone-url-prefix"),
    ("https://codeup.aliyun.com/0123456789abcdef01234567x/demo-app.git", "clone-url-prefix"),
    ("https://codeup.aliyun.com/0123456789abcdef01234567/x@evil.example/y.git", "clone-url-chars"),
    ("https://codeup.aliyun.com/0123456789abcdef01234567/x.git?upload-pack=y", "clone-url-chars"),
    ("https://codeup.aliyun.com/0123456789abcdef01234567/x.git#frag", "clone-url-chars"),
    ("https://codeup.aliyun.com/0123456789abcdef01234567/../../other/x.git", "clone-url-chars"),
])
def test_a_crafted_clone_url_is_rejected_with_a_fixed_reason_code(url, code, capsys):
    assert handler_mod.classify(MR_HDR, _mr_with(clone_url=url), CFG)[0] == "ignore"
    out = capsys.readouterr().out
    assert out == f"ignored reason={code}\n", out


@pytest.mark.parametrize("field,value,code", [
    ("last_commit", {"id": "0731ec9"}, "head-sha"),
    ("last_commit", {"id": "0731EC9D3A8CDDF524BCA91E6FE799B19D0B01F9"}, "head-sha"),
    ("last_commit", {"id": "--upload-pack=touch /tmp/x"}, "head-sha"),
    ("last_commit", {"id": "0731ec9d3a8cddf524bca91e6fe799b19d0b01f9x"}, "head-sha"),
    ("project_id", "7215683; rm -rf /", "repo-id"),
    ("project_id", "72156８3", "repo-id"),
    ("local_id", "6a", "mr-local-id"),
    ("source_branch", "-upload-pack=x", "branch"),
    ("target_branch", "-upload-pack=x", "branch"),
    ("target_branch", "mas ter", "branch"),
    ("source_branch", "feat\tx", "branch"),
])
def test_a_crafted_scalar_is_rejected_with_a_fixed_reason_code(field, value, code, capsys):
    assert handler_mod.classify(MR_HDR, _mr_with(**{field: value}), CFG)[0] == "ignore"
    assert capsys.readouterr().out == f"ignored reason={code}\n"


def test_the_note_path_validates_the_same_way(capsys):
    assert handler_mod.classify(NOTE_HDR, _note_body_with(clone_url=EVIL_URL), CFG)[0] == "ignore"
    assert capsys.readouterr().out == "ignored reason=clone-url-prefix\n"
    assert handler_mod.classify(NOTE_HDR, _note_body_with(last_commit={"id": "x"}),
                                CFG)[0] == "ignore"
    assert capsys.readouterr().out == "ignored reason=head-sha\n"


def test_a_missing_org_id_fails_closed(capsys):
    # falsy 但有意义：组织 id 没配就无从判断 clone 地址属不属于我们，绝不放行。
    for cfg in (dict(CFG, org_id=""), dict(CFG, org_id=None), {k: v for k, v in CFG.items()
                                                               if k != "org_id"}):
        assert handler_mod.classify(MR_HDR, _fix("mr-opened.json"), cfg)[0] == "ignore"
        assert capsys.readouterr().out == "ignored reason=org-unset\n"


def test_the_rejection_log_line_never_echoes_the_payload(capsys):
    # 报文取值是攻击者可控的自由文本：打进日志会污染日志，也可能把令牌带进去
    # （`https://oauth2:<令牌>@…` 这种形状）。
    url = "https://oauth2:s3cret-token@evil.example/x.git"
    handler_mod.classify(MR_HDR, _mr_with(clone_url=url), CFG)
    out = capsys.readouterr().out
    assert out == "ignored reason=clone-url-prefix\n", out
    for leak in ("evil.example", "s3cret-token", "oauth2", url):
        assert leak not in out, (leak, out)


def test_a_normal_review_logs_nothing():
    # 正向对照：这行日志只在形状不可信时出现，否则正常投递会把它淹掉。
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        assert handler_mod.classify(MR_HDR, _fix("mr-opened.json"), CFG)[0] == "review"
        assert handler_mod.classify(NOTE_HDR, _note_with("/kiro review"), CFG)[0] == "review"
    assert buf.getvalue() == ""


def test_the_real_fixtures_pass_the_shape_checks():
    # 六个真实 fixture 都不能被这道检查误伤（其中两个本来就该 ignore，但不是因为形状）。
    for name in ("mr-opened.json", "mr-updated.json", "mr-updated-after-approval.json"):
        assert handler_mod.classify(MR_HDR, _fix(name), CFG)[0] == "review", name
    assert handler_mod._reject_reason(
        handler_mod.classify(MR_HDR, _fix("mr-opened.json"), CFG)[1], CFG) == ""


# ── Fix round 1 / M-2：_norm 的大小写与空白归一必须有用例 ────────────────────────────
@pytest.mark.parametrize("state", ["OPENED", " opened ", "Opened", "opened\n"])
def test_an_uppercase_or_padded_state_is_still_reviewed(state):
    # Codeup 自己就不统一：MR 报文的 state 是 `opened`，Note 报文里那个是 `OPENED`（Task 1 §1）。
    # 逐字比一旦对方换了大小写，就是「一条都不评」的静默失败。
    assert handler_mod.classify(MR_HDR, _set_state(_fix("mr-opened.json"), state), CFG)[0] == "review"


@pytest.mark.parametrize("action", ["UPDATE", " update ", "Update"])
def test_an_uppercase_action_still_hits_the_non_push_filter(action):
    body = _fix("mr-updated.json")
    body["object_attributes"]["action"] = action
    body["object_attributes"]["is_update_by_push"] = False
    assert handler_mod.classify(MR_HDR, body, CFG)[0] == "ignore"


# ── Fix round 1 / 重投链加固：抢锁成功之后，收尾失败也必须回 200 ────────────────────
# Codeup 对非 2xx 会用同一个 delivery id 立即重投 2 次（Task 1 实测）：抢锁之后让异常冒出去
# 就是 502，锁可能已经释放，同一个 head 会被再拉起一次。
def test_post_comment_failure_after_a_runtask_failure_still_returns_200(monkeypatch, capsys):
    monkeypatch.setattr(handler_mod.codeup_min, "post_comment",
                        mock.Mock(side_effect=bexc.ClientError(
                            {"Error": {"Code": "ThrottlingException",
                                       "Message": f"…{FULL_ARN}…"}}, "PostComment")))
    table, ecs = mock.Mock(), mock.Mock()
    ecs.run_task.side_effect = RuntimeError("Throttled")
    assert_alb_response(handler_mod.dispatch(ecs, table, _full_cfg(), F), 200, "runtask-failed")
    out = capsys.readouterr().out
    assert out == "cleanup-failed step=comment reason=ThrottlingException\n", out
    assert table.delete_item.called, "留痕失败不影响释放锁（N4）"


def test_release_failure_after_a_runtask_failure_still_posts_and_returns_200(monkeypatch, capsys):
    posted = []
    monkeypatch.setattr(handler_mod.codeup_min, "post_comment",
                        lambda *a, **k: posted.append(a[4]) or True)
    table, ecs = mock.Mock(), mock.Mock()
    table.delete_item.side_effect = bexc.ClientError(
        {"Error": {"Code": "ProvisionedThroughputExceededException"}}, "DeleteItem")
    ecs.run_task.side_effect = RuntimeError("Throttled")
    assert_alb_response(handler_mod.dispatch(ecs, table, _full_cfg(), F), 200, "runtask-failed")
    assert capsys.readouterr().out == \
        "cleanup-failed step=release reason=ProvisionedThroughputExceededException\n"
    assert posted, "释放锁失败不得连带吞掉 I10 的留痕"


def test_the_cleanup_log_line_leaks_neither_the_account_id_nor_the_aws_message(monkeypatch, capsys):
    monkeypatch.setattr(handler_mod.codeup_min, "post_comment",
                        mock.Mock(side_effect=DENIED))
    table, ecs = mock.Mock(), mock.Mock()
    ecs.run_task.side_effect = RuntimeError("Throttled")
    handler_mod.dispatch(ecs, table, _full_cfg(), F)
    out = capsys.readouterr().out
    for leak in ("111122223333", "not authorized", "assumed-role", "arn:", FULL_ARN):
        assert leak not in out, (leak, out)
    assert out == "cleanup-failed step=comment reason=AccessDeniedException\n", out


def test_a_successful_dispatch_logs_no_cleanup_line(capsys):
    table, ecs = mock.Mock(), mock.Mock()
    ecs.run_task.return_value = {"tasks": [{"taskArn": "a"}]}
    handler_mod.dispatch(ecs, table, _full_cfg(), F)
    assert capsys.readouterr().out == ""
