import fnmatch
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


# ── Ruling 16：任何 Lambda 的环境里都不得出现密钥的值，只能出现 SecretId ────────────
# 裸名。带 "_ID" 后缀的变量存的是 SecretId（密钥名），是本波要求的写法，不在禁止名单里。
PLAINTEXT_SECRET_ENV = ("WEBHOOK_SECRET", "YUNXIAO_TOKEN", "KIRO_API_KEY")
# `*_ID` 变量应有的**确切**取值：密钥名本身。
EXPECTED_SECRET_IDS = {"WEBHOOK_SECRET_ID": "codeup-kiro/webhook-secret",
                       "YUNXIAO_TOKEN_ID": "codeup-kiro/yunxiao-token-kiro"}


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


def test_both_lambdas_get_secret_ids_so_the_absence_assertion_is_not_vacuous():
    # 正向对照：上面那条「不得出现」若因为密钥根本没接线而通过，就什么也没证明。
    t = _disp_template()
    envs = {k: v["Properties"].get("Environment", {}).get("Variables", {})
            for k, v in t.find_resources("AWS::Lambda::Function").items()}
    disp = [e for k, e in envs.items() if "DispatcherFn" in k]
    back = [e for k, e in envs.items() if "BackstopFn" in k]
    assert len(disp) == 1 and len(back) == 1, envs.keys()
    assert {"WEBHOOK_SECRET_ID", "YUNXIAO_TOKEN_ID"} <= set(disp[0]), disp[0].keys()
    assert "YUNXIAO_TOKEN_ID" in back[0], back[0].keys()


def test_secret_id_env_vars_are_plain_secret_names_not_arns():
    """`*_ID` 的值必须**恰好**是密钥名字符串，不是 ARN、不是动态引用、不是 Fn::Join。

    传 partial ARN 会踩 AWS 文档
    （secretsmanager/latest/userguide/troubleshoot.html，「An AWS CLI or AWS SDK operation can't
    find my secret from a partial ARN」）说的那个坑：密钥名以「连字符 + 六个字符」结尾时——
    `codeup-kiro/webhook-secret` 的末段 `secret` 正好是六个字符——partial ARN 会被当成完整 ARN
    解析，GetSecretValue 找不到密钥；文档建议用完整 ARN 或密钥名，而完整 ARN 的六位后缀在 synth
    期拿不到（要调 AWS API）。

    这条只有在模板层面才接得住：Lambda 单测里助手拿到什么就问什么，看不出传进去的是名字还是 ARN。
    也做遍历，不按逻辑 ID 点名。
    """
    t = _disp_template()
    seen = 0
    for logical_id, fn in t.find_resources("AWS::Lambda::Function").items():
        env = fn["Properties"].get("Environment", {}).get("Variables", {})
        for name, want in EXPECTED_SECRET_IDS.items():
            if name not in env:
                continue
            seen += 1
            value = env[name]
            assert isinstance(value, str), (
                f"{logical_id}.{name} 不是纯字符串（动态引用或按 ARN 拼出来的 Fn::Join？）："
                f"{json.dumps(value)}")
            assert not value.startswith("arn:"), (
                f"{logical_id}.{name} 给的是 ARN：{value}——partial ARN 对末段六字符的名字会解析错")
            assert "{{resolve:" not in value, f"{logical_id}.{name} 是 CFN 动态引用：{value}"
            assert value == want, (logical_id, name, value)
    # 调度器两个 + 兜底一个；数量对不上说明有函数漏接或多接了密钥
    assert seen == 3, seen


def _arn_literal(resource):
    """把 Fn::Join 形式的 IAM 资源还原成「字面量部分拼起来」的字符串，Ref 段丢掉。

    断言只关心密钥名与六位后缀通配这两段字面量，partition/region/account 由 Ref 提供、
    与本条不变式无关；直接 json.dumps 整个 Fn::Join 会把它们混进来，endswith 之类就失效了。
    """
    if isinstance(resource, str):
        return resource
    return "".join(p for p in resource.get("Fn::Join", ["", []])[1] if isinstance(p, str))


def _as_list(v):
    return v if isinstance(v, list) else [v]


# 允许出现在 Lambda 角色 ManagedPolicyArns 里的托管策略（CDK 给每个函数加的基础执行权限；
# 挂进 VPC 的函数还会多一个）。别的托管策略一律不允许：它的内容不在模板里，等于把一整片
# 权限从断言的视野里挪走——`SecretsManagerReadWrite` 就是这样溜进来的。
ALLOWED_MANAGED_POLICIES = ("service-role/AWSLambdaBasicExecutionRole",
                            "service-role/AWSLambdaVPCAccessExecutionRole")
KNOWN_SECRETS = ("webhook-secret", "yunxiao-token-kiro")


def _covers_get_secret_value(action):
    """IAM 动作通配是否覆盖 secretsmanager:GetSecretValue。

    用 fnmatch 而不是「等于 GetSecretValue」：`*`、`secretsmanager:*`、`secretsmanager:Get*`
    都覆盖它，而只比对字面量的写法会把这三种放行——复审的 P5/P6 就是这么溜过去的。
    IAM 的通配符是 `*` 与 `?`，与 fnmatch 一致；动作名里不会出现 `[`。
    """
    return fnmatch.fnmatchcase("secretsmanager:GetSecretValue", action)


def _secret_grants_by_function(t):
    """{Lambda 函数逻辑 ID: {它实际能读的密钥名或通配标记}}，外加它角色上的托管策略。

    遍历模板里**全部** AWS::Lambda::Function，顺着 Role 解析到角色，再把三个来源合起来看：
    独立的 AWS::IAM::Policy（按 Roles 引用匹配）、角色自己的内联 Policies、以及
    ManagedPolicyArns。原来的写法只扫「逻辑 ID 里含函数名」的 AWS::IAM::Policy，于是
    ①第三个主体（AwsCustomResource 的 Node 函数）拿到 GetSecretValue on * 照样绿，
    ②`{Action:"*", Resource:"*"}` 照样绿，③托管策略从不进视野。
    """
    roles = t.find_resources("AWS::IAM::Role")
    policies = t.find_resources("AWS::IAM::Policy")
    grants, managed = {}, {}
    for fn_id, fn in t.find_resources("AWS::Lambda::Function").items():
        role_ref = fn["Properties"].get("Role")
        role_id = (role_ref or {}).get("Fn::GetAtt", [None])[0] if isinstance(role_ref, dict) else None
        # 角色不是本模板里的资源（导入的 ARN）时权限查不到，只能当断言失效——宁可红，不要假绿。
        assert role_id in roles, f"{fn_id} 的 Role 不是本模板里的 AWS::IAM::Role：{role_ref}"
        role = roles[role_id]["Properties"]
        managed[fn_id] = [_arn_literal(a) for a in role.get("ManagedPolicyArns", [])]
        docs = [p["PolicyDocument"] for p in role.get("Policies", [])]
        docs += [p["Properties"]["PolicyDocument"] for p in policies.values()
                 if any((r or {}).get("Ref") == role_id for r in _as_list(p["Properties"].get("Roles", [])))]
        got = set()
        for doc in docs:
            for st in _as_list(doc["Statement"]):
                if st.get("Effect", "Allow") != "Allow":
                    continue  # Deny 不是授权，不能算进「它能读什么」
                if not any(_covers_get_secret_value(a) for a in _as_list(st["Action"])):
                    continue
                for r in _as_list(st["Resource"]):
                    lit = _arn_literal(r)
                    named = [n for n in KNOWN_SECRETS
                             if lit.endswith(f":secret:codeup-kiro/{n}-??????")]
                    # 认不出是哪个密钥的资源（"*"、少了六位后缀通配、或别的密钥）一律记成通配标记，
                    # 让下面的集合相等断言带着它红出来，而不是被静默忽略（M9：用 endswith 而不是
                    # 子串匹配，否则 `...:secret:evilcodeup-kiro/webhook-secret-??????` 也算过）。
                    got.update(named or [f"<unrecognised:{lit}>"])
        grants[fn_id] = got
    return grants, managed


def test_get_secret_value_is_granted_per_function_only_on_the_secrets_it_reads():
    """遍历每个 Lambda 函数经它的角色实际拿到的 Secrets Manager 读权限。

    调度器读两个（webhook 密钥现在就在用，云效令牌给 Task 5 的 _runtime_cfg 预留且已注入
    SecretId），兜底只读云效令牌，**其余任何函数都必须是空集**——包括入口查前缀列表的
    AwsCustomResource 那个 Node 函数。

    请求与授权两侧用的形式不同：请求传密钥名（见 test_secret_id_env_vars_...），IAM 策略的
    Resource 只接受 ARN，且 IAM 比对的是 Secrets Manager 解析出来的完整 ARN（带六位随机后缀），
    所以资源必须以 `:secret:codeup-kiro/<名字>-??????` 结尾。少了后缀只会在部署后的运行时报
    AccessDenied，synth 与行为用例都接不住，只有这条能。
    """
    t = _disp_template()
    grants, managed = _secret_grants_by_function(t)
    assert len(grants) >= 3, grants  # 调度器 + 兜底 + AwsCustomResource 的 Node 函数
    want = {"DispatcherFn": {"webhook-secret", "yunxiao-token-kiro"},
            "BackstopFn": {"yunxiao-token-kiro"}}
    for fn_id, got in grants.items():
        expected = next((v for k, v in want.items() if k in fn_id), set())
        assert got == expected, f"{fn_id} 能读的密钥不是 {expected or '∅'}：{got}"
    # 两个该有权限的函数确实各被匹配到一次，否则上面那圈可能因为改名而全部按 ∅ 通过
    assert sum(1 for fn_id in grants if any(k in fn_id for k in want)) == len(want), grants
    for fn_id, arns in managed.items():
        for arn in arns:
            assert any(arn.endswith(a) for a in ALLOWED_MANAGED_POLICIES), \
                f"{fn_id} 的角色挂了未知托管策略（内容不在模板里，断言看不见）：{arn}"


def test_no_lambda_role_grants_any_secretsmanager_action_beyond_get_secret_value():
    # 与上面那条互补：上面管「能读哪些密钥」，这条管「动作面」。DescribeSecret、
    # PutSecretValue 之类一个都不需要（所以没用 grant_read）。
    t = _disp_template()
    roles = t.find_resources("AWS::IAM::Role")
    policies = t.find_resources("AWS::IAM::Policy")
    lambda_role_ids = {
        fn["Properties"]["Role"]["Fn::GetAtt"][0]
        for fn in t.find_resources("AWS::Lambda::Function").values()}
    actions = set()
    for role_id in lambda_role_ids:
        docs = [p["PolicyDocument"] for p in roles[role_id]["Properties"].get("Policies", [])]
        docs += [p["Properties"]["PolicyDocument"] for p in policies.values()
                 if any((r or {}).get("Ref") == role_id
                        for r in _as_list(p["Properties"].get("Roles", [])))]
        for doc in docs:
            for st in _as_list(doc["Statement"]):
                if st.get("Effect", "Allow") != "Allow":
                    continue
                actions.update(a for a in _as_list(st["Action"])
                               if a.startswith("secretsmanager:") or a == "*")
    assert actions == {"secretsmanager:GetSecretValue"}, actions


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


# ── F1：构建机架构不得泄进镜像（Task 1 真实探测：arm64 镜像在 X86_64 Fargate 上 TaskFailedToStart）──
def test_task_definition_pins_runtime_platform_to_x86_64_linux():
    # Fargate 的缺省恰好就是 X86_64/LINUX，但这里要的是**模板里看得见**：与镜像 platform 成对，
    # 任何一侧被改动时另一侧的断言会立刻红。
    t = _exec_template()
    tds = t.find_resources("AWS::ECS::TaskDefinition")
    assert len(tds) == 1
    rp = tds[list(tds)[0]]["Properties"].get("RuntimePlatform")
    assert rp, "任务定义没有显式 RuntimePlatform"
    assert rp["CpuArchitecture"] == "X86_64", rp
    assert rp["OperatingSystemFamily"] == "LINUX", rp


def _exec_asset_manifest(tmp_path):
    """真正 synth 一次，读云装配里的资产清单（`<stack>.assets.json`）。

    断言必须落在真实产物上：镜像的构建平台只出现在资产清单的 `dockerImages.*.source.platform`
    里（模板里没有这个字段，cdk-assets 才是拿它去 `docker build --platform` 的那一方）。
    读 Python 源码里有没有 `platform=` 证明不了 synth 真的写出了它。
    """
    app = cdk.App(outdir=str(tmp_path))
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    ExecutorStack(app, "E", cfg=_full_cfg(), state=state)
    app.synth()
    return json.loads((tmp_path / "E.assets.json").read_text())


def test_image_asset_manifest_pins_the_build_platform_to_linux_amd64(tmp_path):
    # CDK 的缺省是「构建机当前平台」（cloud_assembly_schema 原文 "Default: - current machine
    # platform"），Apple Silicon 上就是 linux/arm64——部署阻塞级缺陷，静态复审看不出来。
    images = _exec_asset_manifest(tmp_path)["dockerImages"]
    assert len(images) == 1, images
    source = list(images.values())[0]["source"]
    # 用 .get 而不是下标：platform 缺失恰好是要接住的那个缺陷，KeyError 的堆栈说不出这一点。
    assert source.get("platform") == "linux/amd64", \
        f"资产清单里的构建平台是 {source.get('platform')!r}（缺失=跟构建机走）"
    # 正向对照：这份清单确实是执行器镜像那一条，不是碰巧读到了别的资产
    assert source["dockerFile"] == "aws/executor/Dockerfile", source


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


# ── I1：手册排错表里那行日志必须与 handler 真的打出来的一致 ──────────────────────
def test_setup_guide_documents_the_exact_secret_unavailable_log_line():
    """复审记下的原始缺陷：手册让运维去日志里找 `SecretUnavailable`，而那条路径当时一行都不打。

    所以这条断言两头都钉：handler.py 里那句 print 的字面量前缀，与手册排错表里写的形状，
    必须是同一个字符串；手册列出的每一个代号也必须真的在代码里出现（固定枚举来自
    secret_fetch.py 的 reason 与 _failure_reason 的 AWS 错误码）。
    """
    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    handler = (aws_dir / "lambda" / "dispatcher" / "handler.py").read_text()
    fetch = (aws_dir / "lambda" / "dispatcher" / "secret_fetch.py").read_text()
    guide = (aws_dir / "setup-guide.md").read_text()
    prefix = "secret-unavailable var="
    assert f'print(f"{prefix}' in handler, "handler.py 不再打那行日志，手册的排错指引就成了空指引"
    assert "code={_secret_unavailable_code(exc)}" in handler, \
        "日志里的代号必须经 _secret_unavailable_code 取（固定枚举），不能换成异常正文"
    assert f"`{prefix}WEBHOOK_SECRET_ID code=" in guide, "手册没有按真实形状写这行日志"
    for code in ("env-unset", "empty-value"):
        assert f'"{code}"' in fetch, f"手册里的代号 {code} 在 secret_fetch.py 里不存在"
        assert f"`{code}`" in guide, code
    # 兜底那侧确实不打这行（它抛异常走 EventBridge 重试），手册也照实这么写
    backstop = (aws_dir / "lambda" / "backstop" / "handler.py").read_text()
    assert prefix not in backstop
    assert "不打调度器那行固定格式的日志" in guide


# ── F4：Codeup 对 503 的重投行为已实测，两处都不得退回「未经核实」 ──────────────
def test_the_measured_503_redelivery_fact_is_stated_in_both_code_and_guide():
    """守的是**退回**，不是措辞。

    原注释把「Codeup 对 503 是否重投未经核实」当成选 503 的免责说明，手册排错表也照抄了
    「是否会自己重投未经核实，重新推送一次即可」。Task 1 实测的结论比那句话窄得多：同一个
    `X-Codeup-Delivery` 在约 1 秒内一共到 3 次就不再来，所以配置/权限错误这次事件是真丢了。
    谁把这段改回「未经核实」，或者把「最多 3 次」这个上界丢掉，这条会红。
    """
    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    handler = (aws_dir / "lambda" / "dispatcher" / "handler.py").read_text()
    guide = (aws_dir / "setup-guide.md").read_text()
    for text, name in ((handler, "dispatcher/handler.py"), (guide, "setup-guide.md")):
        assert "未经核实" not in text, f"{name} 又把 Codeup 的 503 重投写成未经核实"
        assert "3 次" in text, f"{name} 没写出实测的重投上界（同一 delivery 最多 3 次）"
        assert "X-Codeup-Delivery" in text, f"{name} 没点名重投时不变的那个头"
    # 手册这侧还必须有**一行**同时讲到重投与幂等锁的承重作用——只说「丢了」等于没给出路。
    # 逐行找而不是整篇找：`幂等`/`ReviewLock` 在排错表别处早就有了，整篇 in 判断永真、什么也不守。
    rows = [ln for ln in guide.splitlines()
            if ln.startswith("|") and "X-Codeup-Delivery" in ln and "幂等" in ln]
    assert len(rows) == 1, "排错表缺少「同一 delivery 出现 2~3 次是预期行为、被幂等锁吸收」那一行"
    assert "ReviewLock" in rows[0], rows[0]


# ── F5：P2a-04 已实测，5.2 的摘要引导不得再把它写成待取事实 ─────────────────────
def _guide_digest_bootstrap_step2():
    """截出 5.2「首次部署的引导」第 2 步那一段（`2. 读出…` 到 `3. 把真实摘要…` 之间）。

    按段截而不是整篇 grep：这段里要断言的几句话（比如那行退出码 90 的日志）在排错表里也出现，
    整篇 `in` 判断对它们永真，什么也不守。
    """
    guide = (pathlib.Path(__file__).resolve().parents[1] / "setup-guide.md").read_text()
    lines = guide.splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.startswith("2. 读出执行器镜像的真实摘要"))
    end = next(i for i, ln in enumerate(lines[start + 1:], start + 1)
               if ln.startswith("3. 把真实摘要"))
    return "\n".join(lines[start:end])


def test_guide_states_the_measured_ecr_vs_ecs_digest_fact_not_an_open_question():
    """Task 1 实测（sandbox，2026-09-27）：ECR 的 imageDigest、容器级元数据 .ImageID、
    DescribeTasks 的 containers[].imageDigest 三者是同一个值（OCI image index 自身的摘要）。

    原文把这件事写成「由真实运行确认（spec 待取事实 P2a-04）」，并让操作者在两者不一致时
    以日志为准——前半句现在是过时的。这条守住「不得退回待取事实」，同时守住实测结论的三个
    来源都点了名（少点一个，读者就不知道该拿哪条命令的输出去填名单）。
    """
    block = _guide_digest_bootstrap_step2()
    assert "待取事实 P2a-04" not in block, "5.2 又把 P2a-04 写回待取事实"
    assert "逐字一致" in block and "已实测" in block, "没写出实测结论"
    for source in (".ImageID", "containers[].imageDigest", "describe-images"):
        assert source in block, f"实测结论没点名 {source} 这个来源"
    # 钉整个短语而不是 `"index" in block`：这段前面解释构建方式时已经出现过 `OCI image index`，
    # 只判断 `index` 在不在，对「三者同值的那个值到底是谁的摘要」这句话是永真的（实测过）。
    assert "index 自身的摘要" in block, "没说清三者同值的那个值是 image index 自身的摘要"
    # 证据等级必须照实标出来：单次 sandbox 实测，不是「所有构建方式都如此」
    assert "sandbox" in block and "单次实测" in block, "没标证据等级"


def test_guide_keeps_the_exit_90_log_line_as_a_cross_check_and_quotes_it_verbatim():
    # 交叉核对这一条不能因为「已经实测了」就删掉：日志里那个值是 entrypoint **实际读到**的，
    # 命令的输出只是推断。顺带把措辞钉到 entrypoint.sh 真的打出来的那句上。
    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    entry = (aws_dir / "executor" / "entrypoint.sh").read_text()
    literal = "镜像摘要不在已探测名单内，拒绝评审："
    assert f'echo "{literal}${{self_digest}}"' in entry, "entrypoint 不再打这行，手册的交叉核对就空了"
    block = _guide_digest_bootstrap_step2()
    assert literal in block, "5.2 第 2 步丢了退出码 90 那行日志"
    # 光有那句日志**不够**：这一段里它本来就出现两次（引导路径之一也引用它），所以上面那条
    # 断言在 F5 之前就已经是真的、守不住 F5 加的东西。真正要钉的是**优先级规则**——
    # 日志里那个值是 entrypoint 实际读到的，命令输出只是推断，两者不一致时以日志为准。
    assert "实际读到" in block and "以日志里那个为准" in block, \
        "5.2 第 2 步没写明两者不一致时以日志里的值为准"


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
