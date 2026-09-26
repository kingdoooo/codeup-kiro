import pathlib

import pytest
from config import load_config, VALID_REGIONS


D1, D2 = "a" * 64, "b" * 64


def _cfg(**over):
    base = {"region": "us-west-2", "org_id": "o1", "bot_username": "aliyun:bot",
            "inline_comment": 0, "review_command": 0,
            "kiro_image_digests": f"{D1} {D2}",
            "kiro_pinned_artifact_sha256": "c" * 64, "kiro_cli_sha256": "d" * 64}
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


# ── 必配字段与三个摘要（I4：spec「无默认，必配」，N7 不允许隐式默认）────────────
REQUIRED = ("org_id", "bot_username", "kiro_image_digests",
            "kiro_pinned_artifact_sha256", "kiro_cli_sha256")


@pytest.mark.parametrize("name", REQUIRED)
def test_required_key_missing_is_rejected(name, write_cfg):
    cfg = _cfg(); del cfg[name]
    with pytest.raises(ValueError, match=name):
        load_config(write_cfg(cfg))


@pytest.mark.parametrize("name", REQUIRED)
def test_required_key_empty_is_rejected(name, write_cfg):
    with pytest.raises(ValueError, match=name):
        load_config(write_cfg(_cfg(**{name: ""})))


@pytest.mark.parametrize("bad", [
    "   \n\t ",                 # 只有空白：split 之后是空名单
    "a" * 63,                   # 截断
    "A" * 64,                   # 大写
    "sha256:" + "a" * 64,       # 带前缀（setup-guide 5.2 反复提醒的那个坑，现在 synth 就拦住）
    f"{'a' * 64},{'b' * 64}",   # 逗号分隔
    "z" * 64])
def test_image_digest_list_entries_must_be_bare_lowercase_hex64(bad, write_cfg):
    with pytest.raises(ValueError, match="kiro_image_digests"):
        load_config(write_cfg(_cfg(kiro_image_digests=bad)))


def test_image_digest_with_sha256_prefix_says_so_in_the_error(write_cfg):
    # 这个坑原先要等评审被 N1 拒绝、再对着日志里打印的摘要才猜得出来；报错必须直接点名前缀。
    with pytest.raises(ValueError, match="sha256: 前缀"):
        load_config(write_cfg(_cfg(kiro_image_digests=f"{D1} sha256:{D2}")))


def test_image_digest_list_whitespace_is_normalised_to_single_spaces(write_cfg):
    cfg = load_config(write_cfg(_cfg(kiro_image_digests=f"  {D1}\n\t{D2}  ")))
    assert cfg["kiro_image_digests"] == f"{D1} {D2}"


def test_unquoted_all_zero_placeholder_is_rejected_with_a_quoting_hint(tmp_path):
    # 64 个 0 不加引号，YAML 把它解析成整数 0——落进「falsy 但有意义」那一类坑。直接写 YAML 文本复现。
    p = tmp_path / "config.yaml"
    p.write_text("region: us-west-2\norg_id: o1\nbot_username: aliyun:bot\n"
                 f"kiro_image_digests: {'0' * 64}\n"
                 f"kiro_pinned_artifact_sha256: \"{'c' * 64}\"\nkiro_cli_sha256: \"{'d' * 64}\"\n")
    with pytest.raises(ValueError, match="加引号"):
        load_config(str(p))


@pytest.mark.parametrize("name", ["kiro_pinned_artifact_sha256", "kiro_cli_sha256"])
@pytest.mark.parametrize("bad", ["c" * 63, "C" * 64, "sha256:" + "c" * 64, f"{'c' * 64} {'d' * 64}"])
def test_kiro_cli_digests_must_each_be_one_lowercase_hex64(name, bad, write_cfg):
    with pytest.raises(ValueError, match=name):
        load_config(write_cfg(_cfg(**{name: bad})))


def test_example_config_passes_load_config_and_matches_the_dockerfile(tmp_path):
    # config.example.yaml 必须能直接过 load_config（手册让人从它复制），且它给的安装包摘要就是
    # Dockerfile 构建期核对的那个值——两处不一致时镜像能构建、评审却在 die_review 里失败。
    import re
    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    cfg_path = tmp_path / "config.yaml"
    cfg_path.write_text((aws_dir / "config.example.yaml").read_text())
    cfg = load_config(str(cfg_path))
    dockerfile = (aws_dir / "executor" / "Dockerfile").read_text()
    arg = re.search(r"^ARG KIRO_PINNED_ARTIFACT_SHA256=([0-9a-f]{64})$", dockerfile, re.M).group(1)
    assert cfg["kiro_pinned_artifact_sha256"] == arg


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
    # PassRole 收紧到 ExecutorStack 实际持有的两个角色（见 review 修复），所以 DispatcherStack
    # 现在离不开一个真实的 ExecutorStack 实例，不能再只给它一堆字符串 cfg。
    executor = ExecutorStack(app, "E", cfg=_full_cfg(), state=state)
    return Template.from_stack(
        DispatcherStack(app, "D", cfg=_full_cfg(), state=state, executor=executor))


def _exec_template():
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    return Template.from_stack(ExecutorStack(app, "E", cfg=_full_cfg(), state=state))


# 入口（CloudFront → VPC origin → 内网 ALB）的断言在 tests/test_ingress.py，参数化到生产与探测两份模板。


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


# ── Ruling 16：任何 Lambda 的环境里都不得出现密钥的值，只能出现 ARN ────────────────
# 裸名。带 "_ARN" 后缀的变量存的是 ARN，是本波要求的写法，不在禁止名单里。
PLAINTEXT_SECRET_ENV = ("WEBHOOK_SECRET", "YUNXIAO_TOKEN", "KIRO_API_KEY")


def test_no_lambda_function_carries_a_secret_value_in_its_environment():
    """遍历模板里**全部** AWS::Lambda::Function，不按逻辑 ID 点名任何一个。

    点名式断言会随新函数加入而失效：原版只看 DispatcherFn，兜底 Lambda 的明文令牌因此在
    原地留了一整轮而断言照样通过。遍历式还天然覆盖 AwsCustomResource 带进来的 Node.js 函数。
    也不扫整份模板的 blob——那种形状里只要别处出现过一次 "{{resolve:" 就算过，连把密钥硬编码
    成明文都测不出来（这个坑本计划已经踩过一次）。
    """
    t = _disp_template()
    fns = t.find_resources("AWS::Lambda::Function")
    # 调度器 + 兜底 + 入口查前缀列表的 AwsCustomResource 那个 Node 函数
    assert len(fns) >= 3, fns
    for logical_id, fn in fns.items():
        env = fn["Properties"].get("Environment", {}).get("Variables", {})
        for name in PLAINTEXT_SECRET_ENV:
            assert name not in env, f"{logical_id} 的环境里出现明文密钥变量 {name}"
        blob = json.dumps(env)
        assert "resolve:secretsmanager" not in blob, (
            f"{logical_id} 用了 CFN 动态引用：模板里看不到明文，但部署后的函数配置里就是明文，"
            f"任何能 lambda:GetFunctionConfiguration 的主体都读得到")


def test_both_lambdas_get_secret_arns_so_the_absence_assertion_is_not_vacuous():
    # 正向对照：上面那条「不得出现」若因为密钥根本没接线而通过，就什么也没证明。
    t = _disp_template()
    envs = {k: v["Properties"].get("Environment", {}).get("Variables", {})
            for k, v in t.find_resources("AWS::Lambda::Function").items()}
    disp = [e for k, e in envs.items() if "DispatcherFn" in k]
    back = [e for k, e in envs.items() if "BackstopFn" in k]
    assert len(disp) == 1 and len(back) == 1, envs.keys()
    assert {"WEBHOOK_SECRET_ARN", "YUNXIAO_TOKEN_ARN"} <= set(disp[0]), disp[0].keys()
    assert "YUNXIAO_TOKEN_ARN" in back[0], back[0].keys()
    # 值必须是指向 Secrets Manager 的 ARN（跨账号/分区用 Ref 拼出来），不是名字也不是明文
    for env in (disp[0], back[0]):
        for name in (k for k in env if k.endswith("_ARN")):
            blob = json.dumps(env[name])
            assert "secretsmanager" in blob, (name, blob)
            assert "codeup-kiro/" in blob, (name, blob)


def _arn_literal(resource):
    """把 Fn::Join 形式的 IAM 资源还原成「字面量部分拼起来」的字符串，Ref 段丢掉。

    断言只关心密钥名与六位后缀通配这两段字面量，partition/region/account 由 Ref 提供、
    与本条不变式无关；直接 json.dumps 整个 Fn::Join 会把它们混进来，endswith 之类就失效了。
    """
    if isinstance(resource, str):
        return resource
    return "".join(p for p in resource.get("Fn::Join", ["", []])[1] if isinstance(p, str))


def test_get_secret_value_is_granted_per_function_only_on_the_secrets_it_reads():
    # 调度器读两个（webhook 密钥现在就在用，云效令牌给 Task 5 的 _runtime_cfg 预留且已注入 ARN），
    # 兜底只读云效令牌。资源不得是 "*"，也不得互相多给。
    t = _disp_template()
    policies = t.find_resources("AWS::IAM::Policy")
    want = {"DispatcherFn": {"webhook-secret", "yunxiao-token-kiro"},
            "BackstopFn": {"yunxiao-token-kiro"}}
    for fn, want_secrets in want.items():
        sm_actions, resources = set(), []
        for k, p in policies.items():
            if fn not in k:
                continue
            for s in p["Properties"]["PolicyDocument"]["Statement"]:
                actions = s["Action"] if isinstance(s["Action"], list) else [s["Action"]]
                sm_actions.update(a for a in actions if a.startswith("secretsmanager:"))
                if "secretsmanager:GetSecretValue" not in actions:
                    continue
                res = s["Resource"] if isinstance(s["Resource"], list) else [s["Resource"]]
                resources.extend(res)
        assert sm_actions == {"secretsmanager:GetSecretValue"}, (fn, sm_actions)
        assert resources, f"{fn} 缺 secretsmanager:GetSecretValue——运行时取密钥会 AccessDenied"
        got = set()
        for r in resources:
            lit = _arn_literal(r)
            assert lit != "*", f"{fn} 的 GetSecretValue 不能对 * 放行"
            assert ":secretsmanager:" in lit, (fn, lit)
            # "-??????" 不能省：请求里给的是 from_secret_name_v2 的 partial ARN，IAM 授权比对的
            # 却是 Secrets Manager 解析出来的完整 ARN（带六位随机后缀）。少了它一律 AccessDenied，
            # 而这只在部署后的运行时暴露——synth 与行为用例都接不住，只有这条能。
            assert lit.endswith("-??????"), f"{fn} 的 Resource 少了六位后缀通配：{lit}"
            got.update(n for n in ("webhook-secret", "yunxiao-token-kiro")
                       if f"codeup-kiro/{n}-??????" in lit)
        assert got == want_secrets, (fn, got)
        assert len(resources) == len(want_secrets), (fn, resources)


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


def test_dispatcher_pass_role_resource_is_not_wildcard():
    # review 发现：条件收紧不能替代 resource 收紧——resources=["*"] 配合条件仍然是
    # 「能递给 ECS 的任意角色」，必须点名 ExecutorStack 实际持有的那两个角色 ARN。
    t = _disp_template()
    policies = t.find_resources("AWS::IAM::Policy")
    pass_role_stmts = [
        s for p in policies.values()
        for s in p["Properties"]["PolicyDocument"]["Statement"]
        if "iam:PassRole" in (s["Action"] if isinstance(s["Action"], list) else [s["Action"]])
    ]
    assert pass_role_stmts, "缺 iam:PassRole"
    for s in pass_role_stmts:
        resources = s["Resource"] if isinstance(s["Resource"], list) else [s["Resource"]]
        assert len(resources) == 2, resources
        for r in resources:
            assert json.dumps(r) != '"*"', "iam:PassRole 的 Resource 不能是 *"


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


def test_eventbridge_rule_watches_only_stopped_tasks_of_our_cluster():
    # 精确比对整个 EventPattern，不用 has_resource_properties——后者按子集匹配，规则里完全没有
    # detail 时照样通过（C2 就是这样溜过去的）。lastStatus 只放 STOPPED：否则任务还在跑时就触发兜底；
    # clusterArn 只放本集群：否则账号里别的 ECS 负载每次状态迁移都调用兜底，按保留并发把它挤满（I9）。
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    executor = ExecutorStack(app, "E", cfg=_full_cfg(), state=state)
    disp = DispatcherStack(app, "D", cfg=_full_cfg(), state=state, executor=executor)
    rules = Template.from_stack(disp).find_resources("AWS::Events::Rule")
    assert len(rules) == 1, rules
    pattern = next(iter(rules.values()))["Properties"]["EventPattern"]
    cluster_arn = pattern.get("detail", {}).get("clusterArn")
    assert pattern == {
        "source": ["aws.ecs"], "detail-type": ["ECS Task State Change"],
        "detail": {"lastStatus": ["STOPPED"], "clusterArn": cluster_arn}}, pattern
    # 集群 ARN 是 ExecutorStack 那个集群的跨栈导出，不是随手写的字符串
    assert len(cluster_arn) == 1 and "Fn::ImportValue" in cluster_arn[0], cluster_arn
    exported = [o["Value"] for o in Template.from_stack(executor).to_json()["Outputs"].values()
                if o.get("Export", {}).get("Name") == cluster_arn[0]["Fn::ImportValue"]]
    cluster_id = next(iter(Template.from_stack(executor).find_resources("AWS::ECS::Cluster")))
    assert exported == [{"Fn::GetAtt": [cluster_id, "Arn"]}], exported


def test_webhook_registration_is_documented_as_manual_output_not_fabricated_automation():
    # Codeup 不是 AWS 服务，AwsCustomResource 调不到它的 OpenAPI；这里断言我们没有假装
    # 自动化了这一步，而是把域名亮成一个 Output。模板里唯一允许的 Custom::AWS 是入口查
    # CloudFront 前缀列表 ID 的那一个（EC2 describeManagedPrefixLists，见 stacks/ingress.py）。
    t = _disp_template()
    calls = [json.loads(v["Properties"]["Create"])
             for v in t.find_resources("Custom::AWS").values()]
    assert [(c["service"], c["action"]) for c in calls] == \
        [("EC2", "describeManagedPrefixLists")], calls
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


_app_mod = load_lambda("cdk_app", pathlib.Path(__file__).resolve().parents[1] / "app.py")


def test_app_mounts_all_three_stacks_when_config_exists(tmp_path):
    # 走 app.py 真正的入口 main()，但把 config.yaml 放在 tmp_path——不往仓库里的 aws/ 写文件
    # （原先写 aws/config.yaml 再在 finally 里删，进程被杀时会留下一份按示例值生效的配置）。
    cfg_path = tmp_path / "config.yaml"
    cfg_path.write_text((pathlib.Path(__file__).resolve().parents[1]
                         / "config.example.yaml").read_text())
    app = _app_mod.main(str(cfg_path))
    names = sorted(s.stack_name for s in app.node.children if isinstance(s, cdk.Stack))
    assert names == ["CodeupKiroDispatcher", "CodeupKiroExecutor", "CodeupKiroState"], names


def test_app_mounts_nothing_without_config(tmp_path):
    app = _app_mod.main(str(tmp_path / "absent.yaml"))
    assert [s for s in app.node.children if isinstance(s, cdk.Stack)] == []


def test_all_stacks_are_pinned_to_the_configured_region():
    # 区域门（config.VALID_REGIONS）校验的是 cfg["region"]；只有每个 stack 都钉到它，这道门才决定
    # 部署位置——否则 CloudFormation 按 CLI 解析到的区域放，operator 的 AWS_REGION 说了算（C3）。
    # 用一个与 conftest 默认值（us-west-2）不同的区域，免得「碰巧等于默认」掩盖漏钉。
    stacks = _app_mod.build_stacks(cdk.App(), _full_cfg(region="eu-central-1"))
    assert [(s.stack_name, s.region) for s in stacks] == [
        ("CodeupKiroState", "eu-central-1"), ("CodeupKiroExecutor", "eu-central-1"),
        ("CodeupKiroDispatcher", "eu-central-1")]


# ── I2：开关与评审行为变量必须真的进到某个函数/容器的环境里 ────────────────────
def _all_envs(cfg):
    """{来源: {变量名: 值}}：每个 Lambda 函数的环境与执行器容器的环境。"""
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    executor = ExecutorStack(app, "E", cfg=cfg, state=state)
    disp = DispatcherStack(app, "D", cfg=cfg, state=state, executor=executor)
    envs = {k: v["Properties"].get("Environment", {}).get("Variables", {})
            for k, v in Template.from_stack(disp).find_resources("AWS::Lambda::Function").items()}
    td = next(iter(Template.from_stack(executor).find_resources("AWS::ECS::TaskDefinition").values()))
    envs["container"] = {e["Name"]: e["Value"]
                         for e in td["Properties"]["ContainerDefinitions"][0]["Environment"]}
    return envs


def test_every_validated_toggle_reaches_a_function_or_container_env():
    # 遍历 config.TOGGLES 而不是写死两个名字：以后新增开关、忘了接线，这条先红。
    # 两个开关取不同值，确认进去的是各自的值（review_command 属调度器，inline_comment 属执行器）。
    from config import TOGGLES
    cfg = _full_cfg(inline_comment=1, review_command=0)
    envs = _all_envs(cfg)
    for name in TOGGLES:
        where = {src: env[name.upper()] for src, env in envs.items() if name.upper() in env}
        assert where, f"开关 {name} 通过了 config 校验，却没有进任何函数/容器的环境（I2）"
        assert set(where.values()) == {str(cfg[name])}, where
    assert envs["container"]["INLINE_COMMENT"] == "1"
    assert any(env.get("REVIEW_COMMAND") == "0" for src, env in envs.items() if "DispatcherFn" in src)


def _script_default(var):
    """从 scripts/ 读 `VAR="${VAR:-默认}"` 的缺省值；默认值本身是 `$OTHER` 时再解一层。只读不改。"""
    import re
    scripts = pathlib.Path(__file__).resolve().parents[2] / "scripts"
    src = "\n".join(p.read_text() for p in (scripts / "kiro-review.sh",
                                             scripts / "lib" / "diff-compress.sh"))
    hits = re.findall(rf'^{var}="\$\{{{var}:-([^}}]*)\}}"', src, re.M)
    assert len(hits) == 1, (var, hits)
    value = hits[0]
    if value.startswith("$"):
        value = re.search(rf"^{value[1:]}=(\S+)$", src, re.M).group(1)
    return value


def test_behaviour_vars_default_to_exactly_what_the_scripts_default_to():
    # 缺省值写进任务定义是为了看得见，前提是它们与共享评审引擎自己的缺省值逐项一致——
    # 否则 AWS 档位与 Flow 档位在同一份 config 下行为不同，Task 14 的逐字节判据会以渲染差异的面目失败。
    from stacks.executor_stack import BEHAVIOUR_VARS
    env = _all_envs(_full_cfg())["container"]
    for key, (var, _default) in BEHAVIOUR_VARS.items():
        assert env[var] == _script_default(var), (var, env[var])
    # INLINE_COMMENT 取自 cfg["inline_comment"]，load_config 缺省补 0（test_absent_toggle_defaults_to_off）
    assert _script_default("INLINE_COMMENT") == "0"


def test_behaviour_vars_pass_configured_values_through():
    from stacks.executor_stack import BEHAVIOUR_VARS
    over = {"inline_profile": "critical", "max_inline_comments": 3, "kiro_timeout": 1200,
            "diff_size_limit": 100000, "max_comment_bytes": 30000}
    assert set(over) == set(BEHAVIOUR_VARS)
    env = _all_envs(_full_cfg(**over))["container"]
    for key, (var, _default) in BEHAVIOUR_VARS.items():
        assert env[var] == str(over[key]), (var, env[var])


# ── I7：app.py / stacks/ 读取的每一个 config 键都写在 config.example.yaml 里 ─────
# 由 app.py 用 ExecutorStack 的真实资源填入、不是 config.yaml 字段的键（见 app.py 的注释），
# 以及只存在于运行时 cfg 的 codeup_token（密钥，永远不是 config.yaml 的字段）。
NOT_CONFIG_KEYS = {"cluster", "task_definition", "subnets", "security_groups", "codeup_token"}


def test_every_config_key_the_code_reads_is_documented_in_the_example():
    import re
    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    src = "\n".join(p.read_text() for p in [aws_dir / "app.py", *sorted((aws_dir / "stacks").glob("*.py"))])
    read = set(re.findall(r'''cfg(?:\[|\.get\(|\.setdefault\()["'](\w+)["']''', src))
    from stacks.executor_stack import BEHAVIOUR_VARS
    read |= set(BEHAVIOUR_VARS)                     # 经字典间接读取，正则看不见
    assert {"region", "kiro_image_digests", "inline_profile"} <= read, read  # 正则确实抓到了东西
    example = (aws_dir / "config.example.yaml").read_text()
    documented = set(re.findall(r"^#?\s*(\w+):", example, re.M))
    missing = sorted(read - NOT_CONFIG_KEYS - documented)
    assert not missing, f"这些键被代码读取，却没写进 config.example.yaml：{missing}"


# ── I4 引导流程的前提：改 config.yaml 不得改变镜像 ──────────────────────────────
def _image_asset_hash(monkeypatch, root, app):
    import stacks.executor_stack as es
    monkeypatch.setattr(es, "REPO_ROOT", str(root))
    cdk.AssetStaging.clear_asset_hash_cache()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    stack = ExecutorStack(app, "E", cfg=_full_cfg(), state=state)
    return stack.node.find_child("ExecutorImage").asset_hash


def test_editing_config_yaml_does_not_change_the_image(monkeypatch, tmp_path):
    # 手册 5.2 的引导：先用占位摘要部署 → 读出真实镜像摘要 → 追加进 config.yaml → 再部署。
    # 构建上下文是仓库根；config.yaml 若在上下文里，第二次部署的资产哈希就变了，CDK 重新构建、推送，
    # 刚登记的摘要对应的是上一个镜像——N1 拒绝，引导永远收敛不了。
    (tmp_path / "aws" / "executor").mkdir(parents=True)
    (tmp_path / "aws" / "executor" / "Dockerfile").write_text("FROM scratch\n")
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts" / "kiro-review.sh").write_text("v1\n")
    cfg_file = tmp_path / "aws" / "config.yaml"
    cfg_file.write_text("kiro_image_digests: '0000'\n")
    h1 = _image_asset_hash(monkeypatch, tmp_path, cdk.App())
    cfg_file.write_text("kiro_image_digests: '0000 1111'\n")
    (tmp_path / "aws" / "cdk.context.json").write_text("{}\n")
    h2 = _image_asset_hash(monkeypatch, tmp_path, cdk.App())
    assert h1 == h2, "config.yaml / cdk.context.json 改动不得改变镜像资产哈希"
    # 正向对照：集成包本身变了，哈希必须跟着变——否则上面那条等式什么也没证明
    (tmp_path / "scripts" / "kiro-review.sh").write_text("v2\n")
    assert _image_asset_hash(monkeypatch, tmp_path, cdk.App()) != h1


# ── I6：接入手册不得再次与代码脱节 ────────────────────────────────────────────
def test_setup_guide_matches_the_landed_stacks_and_ingress():
    # 手册曾在三个 stack 已经挂载之后仍写着「cdk deploy 不会创建任何资源」、且没有部署步骤。
    # 这里钉住会随代码变的几处事实：stack 名、入口输出名、摘要键名、探测栈、G7 的两个可用区 ID。
    guide = (pathlib.Path(__file__).resolve().parents[1] / "setup-guide.md").read_text()
    for stale in ("不挂载任何 stack", "零个 stack", "产出零个", "调度器尚未实现（Task 11）"):
        assert stale not in guide, f"手册仍有过时说法：{stale}"
    names = [s.stack_name for s in _app_mod.build_stacks(cdk.App(), _full_cfg())]
    for fact in [*names, "WebhookUrl", "kiro_image_digests", "CodeupKiroIngressProbe",
                 "use1-az3", "apne1-az3", "cdk bootstrap", "mergeRequestsEvents", "noteEvents"]:
        assert fact in guide, f"手册缺少：{fact}"
