import pytest
from config import load_config, VALID_REGIONS


def _cfg(**over):
    base = {"region": "us-west-2", "org_id": "o1", "bot_username": "aliyun:bot",
            "inline_comment": 0, "review_command": 0}
    base.update(over)
    return base


def test_nine_valid_regions_exactly():
    assert VALID_REGIONS == frozenset({
        "us-east-1", "us-west-2", "ap-south-1", "ap-southeast-1", "ap-southeast-2",
        "ap-northeast-1", "eu-central-1", "eu-west-1", "sa-east-1"})


@pytest.mark.parametrize("bad", ["ap-east-1", "cn-north-1", "cn-northwest-1", "eu-north-1"])
def test_region_outside_security_agent_support_is_rejected(bad, write_cfg):
    with pytest.raises(ValueError, match="Security Agent"):
        load_config(write_cfg(_cfg(region=bad)))


def test_missing_region_is_rejected_with_no_default(write_cfg):
    cfg = _cfg(); del cfg["region"]
    with pytest.raises(ValueError, match="region"):
        load_config(write_cfg(cfg))


@pytest.mark.parametrize("bad", ["on", "off", "true", "yes", "2", ""])
def test_toggle_must_be_exactly_0_or_1(bad, write_cfg):
    with pytest.raises(ValueError, match="inline_comment"):
        load_config(write_cfg(_cfg(inline_comment=bad)))


def test_absent_toggle_defaults_to_off(write_cfg):
    cfg = _cfg(); del cfg["inline_comment"]
    assert load_config(write_cfg(cfg))["inline_comment"] == 0


@pytest.mark.parametrize("bad", [True, False])
def test_toggle_rejects_genuine_yaml_boolean(bad, write_cfg):
    # True == 1 / False == 0 in Python，isinstance(True, int) 也为真——只有严格的
    # type(x) is int 才能拦住 PyYAML 把无引号 yes/no/true/on/off 解析出来的真布尔值。
    with pytest.raises(ValueError, match="inline_comment"):
        load_config(write_cfg(_cfg(inline_comment=bad)))


def test_toggle_rejects_unquoted_yaml_yes(tmp_path):
    # write_cfg 走 yaml.safe_dump，Python str "yes" 会被加引号、往返仍是字符串；
    # 这里直接手写 YAML 文本，复现人手改配置时最常见的无引号写法。
    p = tmp_path / "config.yaml"
    p.write_text(
        "region: us-west-2\norg_id: o1\nbot_username: aliyun:bot\n"
        "inline_comment: yes\nreview_command: 0\n"
    )
    with pytest.raises(ValueError, match="inline_comment"):
        load_config(str(p))


def test_global_inference_regions_are_flagged(write_cfg, capsys):
    load_config(write_cfg(_cfg(region="ap-southeast-1")))
    assert "any commercial" in capsys.readouterr().out


import aws_cdk as cdk
from aws_cdk.assertions import Template
from stacks.state_stack import StateStack

def _state_template():
    app = cdk.App()
    return Template.from_stack(StateStack(app, "S", cfg={"region": "us-west-2"}))

def test_lock_table_has_ttl_enabled():
    t = _state_template()
    tables = t.find_resources("AWS::DynamoDB::Table")
    lock = [v for v in tables.values()
            if v["Properties"].get("TimeToLiveSpecification", {}).get("Enabled")]
    assert len(lock) == 1, "恰好一张表启用 TTL（幂等锁）"

def test_mapping_table_must_never_enable_ttl():
    # 单独守卫：映射表被 TTL 清掉后，每次扫描都会新建 code review 资源，
    # 慢慢烧掉「1,000 个项目/账号/区域」的配额——静默且延迟数周发作。
    t = _state_template()
    tables = t.find_resources("AWS::DynamoDB::Table")
    mapping = [v for k, v in tables.items() if "Mapping" in k]
    assert len(mapping) == 1
    ttl = mapping[0]["Properties"].get("TimeToLiveSpecification")
    assert ttl is None or ttl.get("Enabled") is False, \
        "映射表绝不允许开启 TTL"

def test_both_tables_retain_on_delete():
    t = _state_template()
    for v in t.find_resources("AWS::DynamoDB::Table").values():
        assert v.get("DeletionPolicy") == "Retain"


# ── Task 11: DispatcherStack / ExecutorStack ────────────────────────────────
import json  # noqa: E402

from stacks.dispatcher_stack import DispatcherStack  # noqa: E402
from stacks.executor_stack import ExecutorStack  # noqa: E402


def _disp_template():
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    return Template.from_stack(DispatcherStack(app, "D", cfg=_full_cfg(), state=state))


def _exec_template():
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    return Template.from_stack(ExecutorStack(app, "E", cfg=_full_cfg(), state=state))


def test_function_url_auth_type_is_aws_iam():
    # CloudFront 之外不可匿名调用；对齐 Security Hub 控制项 CloudFront.16
    _disp_template().has_resource_properties("AWS::Lambda::Url", {"AuthType": "AWS_IAM"})


def test_distribution_uses_origin_access_control():
    t = _disp_template()
    assert t.find_resources("AWS::CloudFront::OriginAccessControl"), "必须有 OAC"


def test_no_security_agent_or_inspector_resources_exist_in_2a():
    # 原版用 S3 Bucket「不存在」当 Security Agent 的替身信号——两者毫无关系，S3 缺失
    # 证明不了任何事。这里直接断言真正会出现的资源类型前缀不存在。
    t = _disp_template()
    types = {r["Type"] for r in t.to_json().get("Resources", {}).values()}
    forbidden_prefixes = ("AWS::SecurityAgent::", "AWS::Inspector::", "AWS::InspectorV2::")
    offending = [ty for ty in types if any(ty.startswith(p) for p in forbidden_prefixes)]
    assert not offending, f"2a 不得创建 Security Agent/Inspector 资源，发现：{offending}"
    # S3 单独留着是有理由的，不是 Security Agent 的替身：2b 的差分扫描（ADR-0003）需要一个
    # 持久化归档桶，一旦有人提早把它加进 Dispatcher Stack，这条该在这里就炸出来。
    assert t.find_resources("AWS::S3::Bucket") == {}, "2a 不建 S3（差分扫描存档桶是 2b 的事）"


def test_lambda_has_reserved_concurrency_as_a_spend_gate():
    t = _disp_template()
    fns = t.find_resources("AWS::Lambda::Function")
    assert any("ReservedConcurrentExecutions" in v["Properties"] for v in fns.values())


def test_webhook_secret_comes_from_secrets_manager_not_plaintext():
    # 原版断言扫的是整份模板的 blob——只要模板里任何地方出现过一次 "{{resolve:"
    # （哪怕是别的密钥留下的），这条断言就会不分青红皂白地通过，就算
    # WEBHOOK_SECRET 自己被换成硬编码明文也测不出来（已用临时改动验证过：见任务报告）。
    # 收紧成只看 DispatcherFn 这个资源自己的 WEBHOOK_SECRET 环境变量值。
    t = _disp_template()
    fns = t.find_resources("AWS::Lambda::Function")
    dispatcher = [v for k, v in fns.items() if "DispatcherFn" in k]
    assert len(dispatcher) == 1
    value = dispatcher[0]["Properties"]["Environment"]["Variables"]["WEBHOOK_SECRET"]
    blob = json.dumps(value)
    assert "resolve:secretsmanager" in blob, blob


def test_dispatcher_run_task_iam_is_scoped_not_wildcard():
    t = _disp_template()
    policies = t.find_resources("AWS::IAM::Policy")
    run_task_stmts = [
        s for p in policies.values()
        for s in p["Properties"]["PolicyDocument"]["Statement"]
        if "ecs:RunTask" in (s["Action"] if isinstance(s["Action"], list) else [s["Action"]])
    ]
    assert run_task_stmts, "找不到 ecs:RunTask 语句"
    for s in run_task_stmts:
        resources = s["Resource"] if isinstance(s["Resource"], list) else [s["Resource"]]
        for r in resources:
            blob = json.dumps(r)
            assert blob != '"*"', "ecs:RunTask 不能对 * 放行，必须 scope 到具体任务族"


def test_dispatcher_has_pass_role_scoped_to_ecs_service():
    t = _disp_template()
    policies = t.find_resources("AWS::IAM::Policy")
    pass_role_stmts = [
        s for p in policies.values()
        for s in p["Properties"]["PolicyDocument"]["Statement"]
        if "iam:PassRole" in (s["Action"] if isinstance(s["Action"], list) else [s["Action"]])
    ]
    assert pass_role_stmts, "缺 iam:PassRole——RunTask 递不出任务角色/执行角色"
    assert any(
        s.get("Condition", {}).get("StringEquals", {}).get("iam:PassedToService")
        == "ecs-tasks.amazonaws.com"
        for s in pass_role_stmts
    ), "iam:PassRole 必须用 iam:PassedToService 收紧到 ECS，不能是无条件通配"


def test_dispatcher_dynamodb_grant_is_put_and_delete_only():
    # claim/release 只做 PutItem/DeleteItem（见 handler.py），不该是 grant_read_write_data
    # 那种连 Query/Scan/GetItem 都给上的宽授权。只看挂在 DispatcherFn 角色上的那份策略——
    # 兜底 Lambda 自己的策略允许有 GetItem（它确实要读「已回写」标记），不能混在一起判。
    t = _disp_template()
    policies = t.find_resources("AWS::IAM::Policy")
    ddb_actions = set()
    for k, p in policies.items():
        if "DispatcherFn" not in k:
            continue
        for s in p["Properties"]["PolicyDocument"]["Statement"]:
            actions = s["Action"] if isinstance(s["Action"], list) else [s["Action"]]
            ddb_actions.update(a for a in actions if a.startswith("dynamodb:"))
    assert ddb_actions == {"dynamodb:PutItem", "dynamodb:DeleteItem"}, ddb_actions


def test_backstop_dynamodb_grant_is_get_item_only():
    t = _disp_template()
    policies = t.find_resources("AWS::IAM::Policy")
    ddb_actions = set()
    for k, p in policies.items():
        if "BackstopFn" not in k:
            continue
        for s in p["Properties"]["PolicyDocument"]["Statement"]:
            actions = s["Action"] if isinstance(s["Action"], list) else [s["Action"]]
            ddb_actions.update(a for a in actions if a.startswith("dynamodb:"))
    assert ddb_actions == {"dynamodb:GetItem"}, ddb_actions


def test_backstop_layer_supplies_codeup_min_at_opt_dispatcher():
    t = _disp_template()
    fns = t.find_resources("AWS::Lambda::Function")
    backstop = [v for k, v in fns.items() if "Backstop" in k]
    assert len(backstop) == 1
    assert backstop[0]["Properties"].get("Layers"), "backstop 必须挂 codeup_min 所在的 layer"


def test_eventbridge_rule_watches_ecs_task_state_change():
    t = _disp_template()
    t.has_resource_properties("AWS::Events::Rule", {
        "EventPattern": {"source": ["aws.ecs"], "detail-type": ["ECS Task State Change"]}})


def test_webhook_registration_is_documented_as_manual_output_not_fabricated_automation():
    # Codeup 不是 AWS 服务，AwsCustomResource 调不到它的 OpenAPI；这里断言我们没有假装
    # 自动化了这一步（没有 Custom::AWS 资源），而是把域名亮成一个 Output。
    t = _disp_template()
    assert t.find_resources("Custom::AWS") == {}, "不能用 AwsCustomResource 冒充调用 Codeup"
    outputs = t.to_json().get("Outputs", {})
    assert any("webhook" in k.lower() for k in outputs), "必须有一个手动接入用的 Output"


def test_ephemeral_storage_above_20_gib_default():
    t = _exec_template()
    t.has_resource_properties("AWS::ECS::TaskDefinition", {"EphemeralStorage": {"SizeInGiB": 50}})


def test_ephemeral_storage_at_or_below_20_gib_is_rejected():
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    with pytest.raises(ValueError, match="20"):
        ExecutorStack(app, "E", cfg=_full_cfg(ephemeral_storage_gib=20), state=state)


def test_task_definition_supplies_aws_region_and_lock_table_to_container():
    # 环境契约里 entrypoint.sh 收尾靠 AWS_REGION/LOCK_TABLE 写「已回写」标记（Task 9）；
    # 一旦这两个缺了，那次 update-item 会静默失败（脚本里 `|| true`），且现在这条断言能
    # 在 CDK 层面接住，不必等到真实运行时才发现。
    t = _exec_template()
    tds = t.find_resources("AWS::ECS::TaskDefinition")
    assert len(tds) == 1
    envs = tds[list(tds)[0]]["Properties"]["ContainerDefinitions"][0]["Environment"]
    names = {e["Name"] for e in envs}
    assert {"AWS_REGION", "LOCK_TABLE"} <= names


def test_task_role_dynamodb_grant_is_update_item_only():
    t = _exec_template()
    policies = t.find_resources("AWS::IAM::Policy")
    ddb_actions = set()
    for p in policies.values():
        for s in p["Properties"]["PolicyDocument"]["Statement"]:
            actions = s["Action"] if isinstance(s["Action"], list) else [s["Action"]]
            ddb_actions.update(a for a in actions if a.startswith("dynamodb:"))
    assert ddb_actions == {"dynamodb:UpdateItem"}, ddb_actions


def test_container_secrets_reference_secrets_manager_arns_not_plaintext():
    t = _exec_template()
    tds = t.find_resources("AWS::ECS::TaskDefinition")
    secrets = tds[list(tds)[0]]["Properties"]["ContainerDefinitions"][0]["Secrets"]
    names = {s["Name"] for s in secrets}
    assert {"KIRO_API_KEY", "YUNXIAO_TOKEN"} <= names
    blob = json.dumps(secrets)
    assert "KIRO_API_KEY" in blob and "secretsmanager" in blob.lower()


def test_app_mounts_all_three_stacks():
    # 回归 setup-guide.md 记录的「此刻 0 个 stack」事实：这个测试证明它已经不成立。
    import importlib
    import pathlib
    import sys

    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    example_cfg = aws_dir / "config.example.yaml"
    config_path = aws_dir / "config.yaml"
    created = not config_path.exists()
    if created:
        config_path.write_text(example_cfg.read_text())
    try:
        sys.path.insert(0, str(aws_dir))
        if "app" in sys.modules:
            del sys.modules["app"]
        app_module = importlib.import_module("app")
        stack_names = [s.stack_name for s in app_module.app.node.children
                       if isinstance(s, cdk.Stack)]
        assert len(stack_names) == 3, stack_names
    finally:
        if created:
            config_path.unlink()
        sys.path.remove(str(aws_dir))
        sys.modules.pop("app", None)
