import fnmatch
import pathlib
import re

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


def test_guide_prerequisites_mention_buildkit_because_the_asset_now_pins_a_platform():
    """代码里写了 `platform=`，手册的部署前提就必须跟着说构建机需要什么。

    CDK 对这个参数的要求是 *Requires Docker Buildx*（cloud_assembly_schema 原文），跨架构构建
    amd64 在 Apple Silicon 上还需要仿真。前提清单原本只写「本机有 Docker 与 CDK CLI」——
    一台只有老构建器（`DOCKER_BUILDKIT=0`）的机器会撞在资产构建阶段，而清单说它够了。
    """
    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    stack_src = (aws_dir / "stacks" / "executor_stack.py").read_text()
    guide = (aws_dir / "setup-guide.md").read_text()
    assert "platform=ecr_assets.Platform" in stack_src, "镜像资产不再钉平台，这条守卫的前提就没了"
    # 只在**部署前提那一段**里判，不整篇判：整篇判的话手册任何地方提一次 buildx 就算过，
    # 而要守的恰恰是「操作者照着前提清单准备环境时看得见这一条」。
    head = guide.find("前提：第 3 节的三个密钥已在")
    assert head != -1, "6.3 的部署前提那一段找不到"
    para = guide[head:guide.find("\n\n", head)]
    assert "buildx" in para.lower(), "部署前提没说构建机需要 BuildKit/buildx"
    assert "仿真" in para, "部署前提没说 Apple Silicon 上还需要 amd64 仿真"


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


def test_task_role_dynamodb_grant_is_exactly_update_and_get_item_on_the_lock_table():
    """任务角色对 DynamoDB 只有两件事：UpdateItem（「已回写」标记 + 按 MR 的租约）与 GetItem（查源分支
    最新提交的抢锁记录，spec I6 ②），且只作用在锁表那一个 ARN 上。按 (动作, 资源) 成对比较，而不是
    只收集动作：动作对了、资源写成 `*` 或映射表，只看动作的断言照样绿。动作按小写比较——IAM 的动作名
    不区分大小写，`DynamoDB:Query` 也是一条真授权。"""
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    executor = ExecutorStack(app, "E", cfg=_full_cfg(), state=state)
    st, et = Template.from_stack(state), Template.from_stack(executor)
    lock_ids = [k for k, r in st.find_resources("AWS::DynamoDB::Table").items()
                if r["Properties"]["KeySchema"] == [{"AttributeName": "pk", "KeyType": "HASH"}]]
    assert len(lock_ids) == 1, lock_ids
    exports = [o["Export"]["Name"] for o in st.to_json().get("Outputs", {}).values()
               if o.get("Value") == {"Fn::GetAtt": [lock_ids[0], "Arn"]}]
    assert len(exports) == 1, exports
    lock_arn = json.dumps({"Fn::ImportValue": exports[0]}, sort_keys=True)

    roles = [k for k, r in et.find_resources("AWS::IAM::Role").items() if k.startswith("TaskRole")]
    assert len(roles) == 1, roles
    assert "ManagedPolicyArns" not in et.find_resources("AWS::IAM::Role")[roles[0]]["Properties"]
    grants = set()
    for p in et.find_resources("AWS::IAM::Policy").values():
        if {"Ref": roles[0]} not in p["Properties"].get("Roles", []):
            continue
        for stmt in p["Properties"]["PolicyDocument"]["Statement"]:
            for a in _as_list(stmt["Action"]):
                if a.lower().startswith("dynamodb:") or a == "*":
                    for r in _as_list(stmt["Resource"]):
                        grants.add((a, json.dumps(r, sort_keys=True)))
    assert grants == {("dynamodb:UpdateItem", lock_arn), ("dynamodb:GetItem", lock_arn)}, grants


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
            "diff_size_limit": 100000, "max_comment_bytes": 30000, "kiro_engine": "v2"}
    assert set(over) == set(BEHAVIOUR_VARS)
    env = _all_envs(_full_cfg(**over))["container"]
    for key, (var, _default) in BEHAVIOUR_VARS.items():
        assert env[var] == str(over[key]), (var, env[var])


# ── I7：app.py / stacks/ 读取的每一个 config 键都写在 config.example.yaml 里 ─────
# 由 app.py 用 ExecutorStack 的真实资源填入、不是 config.yaml 字段的键（见 app.py 的注释），
NOT_CONFIG_KEYS = {"cluster", "task_definition", "subnets", "security_groups", "assign_public_ip"}


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
    # issue 05 G3：云效令牌改成 RunTask 失败后的留痕那一步才取，503 只剩**一个**来源（校验 webhook
    # 令牌的共享密钥）。按**行**判（不是整篇判）：整篇判会被手册里别处任何一次提及满足，而排错表
    # 是按「现象 → 这一行」读的。留痕那一步取不到令牌 / 发不出评论时的日志写在「评审未启动」那一行。
    row_503 = [ln for ln in guide.splitlines()
               if ln.startswith("|") and "secret-unavailable" in ln and "503" in ln]
    assert len(row_503) == 1, "排错表里 503 / secret-unavailable 那一行找不到（或不止一行）"
    assert "YUNXIAO_TOKEN_ID" not in row_503[0] and "yunxiao-token-kiro" not in row_503[0], \
        "503 那一行还在说取不到云效令牌会 503（G3 之后它只在留痕那一步取）"
    assert f"`{prefix}WEBHOOK_SECRET_ID code=" in row_503[0], \
        "503 那一行没按真实形状写共享密钥那个变量名"
    assert handler.count("return _secret_unavailable(exc)") == 1, \
        "503 只剩共享密钥这一个来源"
    row_rt = [ln for ln in guide.splitlines() if ln.startswith("| MR 上出现调度器写的「评审未启动」类评论")]
    assert len(row_rt) == 1
    for fact in ("`cleanup-failed step=comment reason=PostFailed`",
                 "`cleanup-failed step=comment reason=SecretUnavailable:<代号>`", "`ConnectionResetError`",
                 "最多一行", "`Status: timeout`"):
        assert fact in row_rt[0], f"「评审未启动」那一行缺：{fact}"
    assert "每次恰好一行" not in row_rt[0], "函数超时时连 cleanup-failed 那一行都没有（review-B M-4）"
    # 收口复审 R-2：Text 日志格式下超时只有 REPORT 行的 Status: timeout（sandbox 09-28 实测），没有 Task timed out 行
    assert "`Task timed out after" not in row_rt[0], row_rt[0]
    assert 'f"cleanup-failed step={step} reason={_failure_reason(exc)}"' in handler, \
        "手册写的是这行日志的形状，handler 必须真的这么打"
    # 兜底那侧确实不打这行（它抛异常走 EventBridge 重试），手册也照实这么写
    backstop = (aws_dir / "lambda" / "backstop" / "handler.py").read_text()
    assert prefix not in backstop
    silent = [ln for ln in guide.splitlines() if ln.startswith("| 评审任务确实异常结束了，MR 上却**没有**兜底评论")]
    assert len(silent) == 1
    assert "不打固定格式的代号日志" in silent[0], silent[0]
    # G3 之后 503 那一行只讲共享密钥，兜底这一行不能再把人指过去找令牌的日志（review-B M-3）
    assert "见本表「Codeup 的 webhook 投递记录显示 503」那一行" not in silent[0].split("不打固定格式的代号日志", 1)[1][:200]


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
    # 手册这侧一律**按行**判，不整篇判：`3 次` 现在在两行里共出现四次，只削弱 503 那一行
    # 整篇判照样绿；`未经核实` 整篇判还会在别处正当地给某件事留保留意见时误报。
    rows = [ln for ln in guide.splitlines() if ln.startswith("|")]
    row_503 = [ln for ln in rows if "secret-unavailable" in ln and "503" in ln]
    assert len(row_503) == 1, "排错表里 503 / secret-unavailable 那一行找不到（或不止一行）"
    row_retry = [ln for ln in rows if "X-Codeup-Delivery" in ln and "幂等" in ln]
    assert len(row_retry) == 1, "排错表缺少「同一 delivery 出现 2~3 次是预期行为、被幂等锁吸收」那一行"
    for text, name in ((handler, "dispatcher/handler.py"),
                       (row_503[0], "setup-guide.md 的 503 那一行"),
                       (row_retry[0], "setup-guide.md 的重投那一行")):
        assert "未经核实" not in text, f"{name} 又把 Codeup 的 503 重投写成未经核实"
        assert "3 次" in text, f"{name} 没写出实测的重投上界（同一 delivery 最多 3 次）"
    # 头名只要求 handler 与重投那一行点出来：503 那一行用「见下一行」指过去，不必重复。
    for text, name in ((handler, "dispatcher/handler.py"),
                       (row_retry[0], "setup-guide.md 的重投那一行")):
        assert "X-Codeup-Delivery" in text, f"{name} 没点名重投时不变的那个头"
    assert "ReviewLock" in row_retry[0], row_retry[0]
    # 实测过的只有 **503** 这一个状态码。这一行不得把「非 2xx 都会立即重试」写成实测结论，
    # 且必须点出其他状态码没测过——否则手册会对同一个行为给出两种置信度（502/504 那一行照实
    # hedge 着，这一行却言之凿凿）。复审把这条列为 ⚠️：原措辞是从 brief/probe-results 继承的过度概括。
    assert "503" in row_retry[0], "重投那一行没说清实测的是哪一个状态码"
    assert "没有测过" in row_retry[0], "重投那一行没点出 404/502/504 是否同样重投没有测过"
    row_5xx = [ln for ln in rows if "502/504" in ln]
    assert len(row_5xx) == 1, "排错表里 502/504 那一行找不到（或不止一行）"
    assert "没有实测过" in row_5xx[0], "502/504 那一行没照实说明它的重投行为未经实测"


# ── F5：P2a-04 已实测，5.2 的摘要引导不得再把它写成待取事实 ─────────────────────
def _guide_digest_bootstrap_step2():
    """截出 5.2「首次部署的引导」第 2 步那一段（`2. 读出…` 到 `3. 把真实摘要…` 之间）。

    按段截而不是整篇 grep：这段里要断言的几句话（比如那行退出码 90 的日志）在排错表里也出现，
    整篇 `in` 判断对它们永真，什么也不守。
    """
    guide = (pathlib.Path(__file__).resolve().parents[1] / "setup-guide.md").read_text()
    lines = guide.splitlines()
    # 用 next(..., None) + 断言而不是裸 next()：标题被改动时 StopIteration 的堆栈说不出
    # 「是这一段找不到了」，而这恰恰是最可能的失败原因（同 F1 那条 KeyError 的教训）。
    start = next((i for i, ln in enumerate(lines) if ln.startswith("2. 读出执行器镜像的真实摘要")), None)
    assert start is not None, "5.2 引导第 2 步的开头不见了（`2. 读出执行器镜像的真实摘要`）"
    end = next((i for i, ln in enumerate(lines[start + 1:], start + 1)
                if ln.startswith("3. 把真实摘要")), None)
    assert end is not None, "5.2 引导第 3 步的开头不见了（`3. 把真实摘要`）"
    return "\n".join(lines[start:end])


def _guide_measured_digest_sentence():
    """再往里截一层：只取 F5 新写的那句实测结论（`逐字一致，已实测` 到 `证据等级：` 之间）。

    为什么还要再截一层：整段（`_guide_digest_bootstrap_step2`）在 F5 **之前**就已经包含
    `describe-images`（第 2 步开头那个 bash 块）与 `逐字一致`（原文「是否逐字一致由真实运行确认」），
    所以拿整段判这两个字符串在不在，在 F5 之前就是真的——等于没守。复审逐字比对过 base 版本的
    同一段，确认只有这两条是空的，其余八条都是活的。三个来源的点名必须落在这句结论里。
    """
    block = _guide_digest_bootstrap_step2()
    head = block.find("逐字一致，已实测")
    assert head != -1, "5.2 第 2 步里找不到那句实测结论（`逐字一致，已实测`）"
    tail = block.find("证据等级：", head)
    assert tail != -1, "实测结论后面没有跟着证据等级那一句"
    return block[head:tail]


def test_guide_states_the_measured_ecr_vs_ecs_digest_fact_not_an_open_question():
    """Task 1 实测（sandbox，2026-09-27）：ECR 的 imageDigest、容器级元数据 .ImageID、
    DescribeTasks 的 containers[].imageDigest 三者是同一个值（OCI image index 自身的摘要）。

    原文把这件事写成「由真实运行确认（spec 待取事实 P2a-04）」，并让操作者在两者不一致时
    以日志为准——前半句现在是过时的。这条守住「不得退回待取事实」，同时守住实测结论的三个
    来源都点了名（少点一个，读者就不知道该拿哪条命令的输出去填名单）。
    """
    block = _guide_digest_bootstrap_step2()
    assert "待取事实 P2a-04" not in block, "5.2 又把 P2a-04 写回待取事实"
    # 三个来源与「逐字一致」只在**那句结论自己**里算：整段里 `describe-images`（bash 块）与
    # `逐字一致`（原文的「是否逐字一致由真实运行确认」）在 F5 之前就已经在了。少点一个来源，
    # 读者就不知道该拿哪条命令的输出去填名单——尤其是删掉 describe-images 那半句时，
    # bash 块还在，整段判断照样绿。
    sentence = _guide_measured_digest_sentence()
    assert "逐字一致" in sentence and "已实测" in sentence, "没写出实测结论"
    for source in (".ImageID", "containers[].imageDigest", "describe-images"):
        assert source in sentence, f"实测结论没点名 {source} 这个来源"
    # 钉整个短语而不是 `"index" in ...`：这段前面解释构建方式时已经出现过 `OCI image index`，
    # 只判断 `index` 在不在，对「三者同值的那个值到底是谁的摘要」这句话是永真的（实测过）。
    assert "index 自身的摘要" in sentence, "没说清三者同值的那个值是 image index 自身的摘要"
    # 证据等级必须照实标出来：单次 sandbox 实测，不是「所有构建方式都如此」。
    # 这一句在结论之后，所以对整段判（子串切片的右边界就是它）。
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


# ── Task 5 复审 I-2/I-3：形状检查的代号与手册必须逐个对齐 ──────────────────────
IGNORED_REASON_PREFIX = "ignored reason="


def _str_literals(node):
    """一个表达式（含 f-string）里所有**字面量**字符串片段拼起来；插值部分按空串处理。"""
    import ast
    return "".join(sub.value for sub in ast.walk(node)
                   if isinstance(sub, ast.Constant) and isinstance(sub.value, str))


def _ignored_reason_codes(src):
    """用 AST 抽出「调度器能打出 `ignored reason=` 的全部代号」，并顺带定位日志的出口。

    返回 `(codes, emitters, arg_forms)`：代号集合、正文含 `ignored reason=` 的 print 所在函数名、
    `_log_ignored(...)` 实参的形态集合。

    按 AST 抽而不是按字面量数（复审 M-4）：原来那条 `handler.count('print(f"ignored reason=') == 1`
    只钉住了一种拼法——`print("ignored reason=" + code)`、`print("ignored" " reason=" + code)`
    或 `_log_ignored(some_var)` 都能从它和两个正则抽取器底下溜过去，而那正是这条守卫要防的分叉。
    """
    import ast
    tree = ast.parse(src)
    fns = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
    assert {"_log_ignored", "_accept", "_reject_reason"} <= set(fns), sorted(fns)

    emitters, codes, arg_forms = [], set(), set()
    for name, fn in fns.items():
        for node in ast.walk(fn):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                    and node.func.id == "print"
                    and IGNORED_REASON_PREFIX in _str_literals(node)):
                emitters.append(name)
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                    and node.func.id == "_log_ignored"):
                continue
            arg = node.args[0] if len(node.args) == 1 else None
            if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                arg_forms.add("literal")
                codes.add(arg.value)
            elif isinstance(arg, ast.Name) and name == "_accept":
                # `_accept` 把 `_reject_reason` 的返回值原样转发：代号来自那个函数的 return
                arg_forms.add("reject-reason")
                for ret in ast.walk(fns["_reject_reason"]):
                    if not isinstance(ret, ast.Return):
                        continue
                    assert isinstance(ret.value, ast.Constant) and isinstance(ret.value.value, str), \
                        f"_reject_reason 返回了非字面量代号（抽取器看不见它）：{ast.dump(ret)}"
                    if ret.value.value:
                        codes.add(ret.value.value)
            else:
                raise AssertionError(
                    f"{name} 里的 _log_ignored 实参形态不认识（代号会从守卫底下溜过去）："
                    f"{ast.dump(node)}")
    return codes, emitters, arg_forms


def test_setup_guide_lists_every_shape_rejection_code_the_dispatcher_can_emit():
    """代号是运维唯一的分辨依据：代码里加一个代号却不写进手册，那一类拒绝就查不下去；
    手册写了代码里没有的代号，运维会照着一个永远不出现的现象排查。两边逐个对齐，不是子串抽查。
    """
    import re
    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    handler = (aws_dir / "lambda" / "dispatcher" / "handler.py").read_text()
    guide = (aws_dir / "setup-guide.md").read_text()
    codes, emitters, arg_forms = _ignored_reason_codes(handler)
    # 日志只有一个出口，且就是 `_log_ignored`：形状分叉了手册的排错表只对一半路径成立。
    assert emitters == ["_log_ignored"], \
        f"`{IGNORED_REASON_PREFIX}` 必须只在 _log_ignored 里打；实际出现在：{emitters}"
    # 两条代号来源都确实抽到了东西（否则「代号集合对得上」可能是空真）
    assert arg_forms == {"literal", "reject-reason"}, arg_forms
    assert codes == {"org-unset", "clone-url-prefix", "clone-url-chars", "head-sha",
                     "repo-id", "mr-local-id", "branch", "note-biz-id", "mr-not-open",
                     "missing-field", "kiro-marker", "reviewer-disabled"}, codes
    # 选行的条件要挑出**枚举那一行**：别处（4.3 的 REVIEW_COMMAND 一行）也会正当地提到某个具体代号
    # （`ignored reason=mr-not-open`），只按 `ignored reason=` 选会一下选中两行。
    row = [ln for ln in guide.splitlines()
           if ln.startswith("|") and "ignored reason=<代号>" in ln and "固定枚举：" in ln]
    assert len(row) == 1, "排错表里枚举代号那一行找不到（或不止一行）"
    # 只看那一行里**枚举代号的那一段**，不是整行：整行判会被同一行后面「处置：`org-unset` 查函数
    # 配置」这类再次提及满足——把枚举里的代号改名，整行判照样绿（失败模式 d，本轮实测踩到过）。
    listing = row[0].split("固定枚举：", 1)[1].split("。日志里", 1)[0]
    mentioned = set(re.findall(r"`([a-z][a-z-]+)`", listing))
    assert mentioned == codes, f"手册枚举与代码不一致，差集：{mentioned ^ codes}"


# ── I6：接入手册不得再次与代码脱节 ────────────────────────────────────────────
def test_setup_guide_matches_the_landed_stacks_and_ingress():
    # 手册曾在三个 stack 已经挂载之后仍写着「cdk deploy 不会创建任何资源」、且没有部署步骤。
    # 这里钉住会随代码变的几处事实：stack 名、入口输出名、摘要键名、探测栈、G7 的两个可用区 ID。
    guide = (pathlib.Path(__file__).resolve().parents[1] / "setup-guide.md").read_text()
    for stale in ("不挂载任何 stack", "零个 stack", "产出零个", "调度器尚未实现（Task 11）",
                  # Task 5 接线之后这几句都成了反话（复审 I-3：手册自己写了「落地后要更新」却没更新）
                  "不会拉起评审任务", "此刻它还不生效", "要等 Task 5 落地",
                  "评论命令触发尚未实现", "过滤逻辑随 Task 5 落地"):
        assert stale not in guide, f"手册仍有过时说法：{stale}"
    names = [s.stack_name for s in _app_mod.build_stacks(cdk.App(), _full_cfg())]
    for fact in [*names, "WebhookUrl", "kiro_image_digests", "CodeupKiroIngressProbe",
                 "use1-az3", "apne1-az3", "cdk bootstrap", "mergeRequestsEvents", "noteEvents",
                 # Task 5 接线之后运维会真的遇到的三样东西：形状检查的日志、分支过滤配错的日志、
                 # 以及本方两条失败评论的断环标记（名字改了手册必须跟着改）
                 "ignored reason=", "bad-target-branch-filter",
                 "kiro-dispatch-failed", "kiro-backstop", "<!-- kiro-"]:
        assert fact in guide, f"手册缺少：{fact}"

    # Task 13：评论命令落地之后，这几句也成了反话（B-2 与控制方裁决）
    for stale in ("执行器与评审脚本那一半", "一条新的汇总评论", "尚未实现（Task 13）",
                  "实现计划 Task 13"):
        assert stale not in guide, f"手册仍有过时说法：{stale}"


# ── Task 13 / B-2 + 控制方裁决：评论命令的结果是「原地更新那条汇总评论」 ──────────────
def _guide_text():
    return (pathlib.Path(__file__).resolve().parents[1] / "setup-guide.md").read_text()


def test_the_guide_describes_the_comment_command_result_as_an_in_place_summary_update():
    """手册两处原来写「结果照常以一条新的汇总评论呈现」，与引擎的生命周期正好相反。

    引擎：每评审员每 MR 至多一条汇总，按「作者 = 机器人 且 正文含评审标记」定位上一次那条，
    找到就**原地更新**（run:N 递增、历次表 +1），找不到或没配机器人用户名才新建
    （scripts/kiro-review.sh 开头，spec I4）。操作者发出命令后看到的是那条评论变了。

    两处各自按**段 / 行**判，不整篇判：整篇判会被 4.2 节里 `CODEUP_BOT_USERNAME` 那句说明满足，
    而要守的恰恰是「读命令这一段时就看得见原地更新」（失败模式 d，本仓库的文档守卫踩过四次）。
    """
    guide = _guide_text()
    head = guide.find("**评论命令已按 spec 落地**")
    assert head != -1, "§0 里那段评论命令的说明找不到"
    para = guide[head:guide.find("\n\n", head)]
    row = [ln for ln in guide.splitlines()
           if ln.startswith("|") and "REVIEW_COMMAND_PHRASE" in ln]
    assert len(row) == 1, "4.3 的 REVIEW_COMMAND 那一行找不到（或不止一行）"
    for text, name in ((para, "§0 的评论命令那一段"), (row[0], "4.3 的 REVIEW_COMMAND 那一行")):
        assert "原地更新" in text, f"{name}没说结果是原地更新那条汇总评论"
        assert "run:N" in text, f"{name}没说 run:N 递增（操作者就是靠这个数字确认重审跑了）"
        # 「新建」的条件是三条，不是一条（复审 M-2）：原文只写了「没配 CODEUP_BOT_USERNAME 时才新建」，
        # 比引擎强——首次评审（找不到上一条）与原地更新失败同样会新建一条。
        assert "CODEUP_BOT_USERNAME" in text, f"{name}没说「没配机器人用户名时才新建」的那个前提"
        assert "更新失败" in text, f"{name}把「新建」的条件写窄了：原地更新失败时引擎也会新建一条"
        assert "找不到上一条" in text, f"{name}漏了「找不到上一条（首次评审）也会新建」"
        for stale in ("新的汇总评论", "尚未实现", "Task 13", "不会回复那条评论"):
            assert stale not in text, f"{name}仍有过时说法：{stale}"
    # M-1：`LOCK_KEY` 是唯一一项不一样的环境变量（run_task 把多带一段评论 id 的锁键原样传进去），
    # 所以「环境变量与 MR 事件完全一样」这句话必须带上那个例外，否则同一段里前后矛盾。
    assert "环境变量与 MR 事件的完全一样" in para, "§0 那段不再讲环境变量，这条守卫的前提没了"
    assert "除 `LOCK_KEY` 多一段评论 id 外" in para, \
        "§0 那段把「环境变量完全一样」写成了无条件的：锁键多一段评论 id（handler.py::run_task）"
    handler = (pathlib.Path(__file__).resolve().parents[1]
               / "lambda" / "dispatcher" / "handler.py").read_text()
    run_task = handler.split("def run_task(")[1].split("\ndef ")[0]
    assert '("LOCK_KEY", key)' in run_task, "run_task 不再把锁键当环境变量传，上面那句例外要复核"
    # 手册说的必须与引擎真的实现的是同一件事（只读 scripts/，不改）
    engine = (pathlib.Path(__file__).resolve().parents[2] / "scripts" / "kiro-review.sh").read_text()
    assert "找到就原地更新（run:N 递增" in engine, "引擎的汇总评论生命周期变了，手册这两处要跟着复核"
    assert "找不到或更新失败就新建" in engine, "引擎不再「找不到才新建」，手册那句前提要跟着复核"


def test_the_guide_lists_the_executors_host_check_as_an_exit_91_cause():
    """B-3：entrypoint 的第二道主机检查也以 91 退出，但 §8 的 91 那一行只写了令牌/网络/权限三类。

    消息逐字取自 entrypoint.sh：运维是拿日志里那句话去表里找行的，手册改写一遍就对不上了。
    """
    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    entry = (aws_dir / "executor" / "entrypoint.sh").read_text()
    literal = "业务库地址的主机不是 codeup.aliyun.com，拒绝 clone"
    assert f'echo "{literal}" >&2; exit 91' in entry, "entrypoint 的主机检查消息/退出码变了"
    row = [ln for ln in _guide_text().splitlines() if ln.startswith("|") and "退出码 91" in ln]
    assert len(row) == 1, "§8 的退出码 91 那一行找不到（或不止一行）"
    assert literal in row[0], "§8 的退出码 91 那一行没写主机检查这个成因"


# ── Task 14 验收阻塞：git 凭证必须下发给**引擎那个子进程**，手册与代码两头都钉 ──────────
def test_git_credentials_reach_the_engine_and_the_guide_says_how():
    """真实 Fargate 运行踩过的坑：helper 只作为 `git -c` 传给执行器自己那两次调用，评审引擎
    （scripts/kiro-review.sh 第 4 步）自己的 `git fetch` 因此是无凭证的，装机/摘要/自检/版本门
    全过之后才在生成 diff 那一步整轮失败。

    三件事一起钉，少一件这个坑就会以另一种形式回来：
    ① 引擎真的会自己 fetch（只读 scripts/，不改）——哪天引擎不再自己 fetch，这条会提醒复核；
    ② 执行器用**环境变量**下发按主机限定的 helper，且没有退回 `-c` / 全局 helper；
    ③ §8 有一行以引擎**逐字**的报错为线索（运维就是拿那句话去表里找行的），并点出修法。
    """
    root = pathlib.Path(__file__).resolve().parents[2]
    entry = (root / "aws" / "executor" / "entrypoint.sh").read_text()
    engine = (root / "scripts" / "kiro-review.sh").read_text()
    guide = _guide_text()

    engine_err = "无法 fetch 目标分支"
    assert f'die_review "{engine_err}"' in engine, "引擎的 fetch 报错措辞变了，手册那一行要跟着改"
    assert 'git fetch -q origin "+refs/heads/${TARGET_BRANCH}' in engine, \
        "引擎不再自己 fetch 目标分支了：执行器的凭证下发方式与 §8 那一行都要复核"

    for line in ("export GIT_CONFIG_COUNT=1",
                 "export GIT_CONFIG_KEY_0='credential.https://codeup.aliyun.com.helper'",
                 'export GIT_CONFIG_VALUE_0="$cred_helper"'):
        assert line in entry, f"entrypoint 不再经环境变量下发 git 凭证：{line}"
    code = "\n".join(ln for ln in entry.splitlines() if not ln.lstrip().startswith("#"))
    assert "credential.helper" not in code, "退回了未限定主机的全局 credential.helper"
    assert "-c credential" not in code, "退回了只作用于本进程的 -c（引擎那个子进程又拿不到凭证）"

    # 按**第一格**（现象）选行：别的行按名字引用这一行（「本表『无法 fetch 目标分支』那一行」）时，
    # 整行判会一下选中两行。
    row = [ln for ln in guide.splitlines() if ln.startswith("|") and engine_err in ln.split(" | ")[0]]
    assert len(row) == 1, "§8 缺少「无法 fetch 目标分支」那一行（或不止一行）"
    for fact in ("GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0",
                 "could not read Username"):
        assert fact in row[0], f"§8 那一行没写出 {fact}"


# ── Task 14 验收阻塞 2：执行器必须检出 MR 的那个提交，手册与代码两头都钉 ──────────────
def test_the_executor_checks_out_the_reviewed_commit_and_the_guide_says_so():
    """真实 Fargate 运行踩过的坑：`git clone` 检出的是仓库**默认分支**，entrypoint 从不检出
    HEAD_SHA，而引擎把 `git rev-parse HEAD` 当作「本次评审的提交」——于是 AWS 档位每次评审的都是
    默认分支（MR !4 的汇总标记是 master 的头 f29435f，MR 的头是 7baa0cd）。

    三件事一起钉：① 引擎真的只从 git 里取那个提交（只读 scripts/，它哪天改成读 HEAD_SHA 就提醒复核）；
    ② entrypoint 有检出 + 检出后的逐字核对，且排在调用引擎之前；③ §8 有一行对应的排错项。
    """
    root = pathlib.Path(__file__).resolve().parents[2]
    entry = (root / "aws" / "executor" / "entrypoint.sh").read_text()
    engine = (root / "scripts" / "kiro-review.sh").read_text()
    guide = _guide_text()

    # ① 引擎侧：本次评审的提交只来自 git HEAD，引擎自己不 checkout、也不读 HEAD_SHA
    assert "head_full=$(git rev-parse HEAD)" in engine, "引擎不再从 git HEAD 取评审提交，检出契约要复核"
    assert "SHORT_SHA=$(git rev-parse --short HEAD)" in engine
    assert "HEAD_SHA" not in engine, "引擎开始读 HEAD_SHA 了：执行器的检出与这条断言都要复核"
    engine_code = "\n".join(ln for ln in engine.splitlines() if not ln.lstrip().startswith("#"))
    assert "git checkout" not in engine_code, "引擎自己 checkout 了：与执行器这一步的职责要重新划清"

    # ② 执行器侧：形状再查一次 + 检出 + 逐字核对，且都在调用引擎之前
    code = [ln for ln in entry.splitlines() if not ln.lstrip().startswith("#")]
    joined = "\n".join(code)
    for frag in ('[[ -n "${HEAD_SHA:-}" ]]',
                 '[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]',
                 'checkout -q --detach "$HEAD_SHA"',
                 '[[ "$head_now" == "$HEAD_SHA" ]]'):
        assert frag in joined, f"entrypoint 缺少：{frag}"
    # **分离头指针**，不建本地分支：`-B "$CI_COMMIT_REF_NAME"` 会建出 refs/heads/<源分支名>，
    # 源分支叫 `origin/<目标分支>` 时它遮蔽 refs/remotes/origin/<目标分支>（git 解析短名字时
    # refs/heads 在前），引擎的 merge-base 退化成 HEAD → diff 为空 → 评审被跳过且不留评论。
    # 真 git 复现过；tests/test-aws-entrypoint.sh 的 ⑲ 是那个场景的端到端断言。
    assert "checkout -q -B" not in joined, "不得建本地分支（refs/heads 会遮蔽 refs/remotes）"
    def line_of(frag):
        return next(i for i, ln in enumerate(code) if frag in ln)
    assert line_of("/usr/bin/git clone ") < line_of("checkout -q --detach") < line_of("kiro-review.sh"), \
        "检出必须排在 clone 之后、调用引擎之前"
    assert line_of('[[ "$HEAD_SHA" =~') < line_of("checkout -q --detach"), "形状检查必须在检出之前"
    # 必填守卫在**任何网络 I/O 之前**（复审 M-3）：缺 HEAD_SHA 时不该先跑完镜像摘要门与一次全量 clone
    assert line_of('[[ -n "${HEAD_SHA:-}" ]]') < line_of("KIRO_IMAGE_DIGESTS") < line_of("/usr/bin/git clone "), \
        "HEAD_SHA 必填守卫必须排在镜像摘要门与 clone 之前"
    assert joined.count("exit 92") == 6, \
        ("六条 fail-closed 出口（HEAD_SHA 必填、HEAD_SHA 形状、源分支形状、目标分支形状、检出失败、"
         "HEAD 不一致）少了一条")

    # ③ 手册侧
    # 只在 §8 里找：§4 的 HEAD_SHA 那一行也提到退出码 92，整篇判会变成 2 匹配
    row = [ln for ln in _guide_section_lines("8.") if ln.startswith("|") and "退出码 92" in ln]
    assert len(row) == 1, "§8 缺少退出码 92 那一行（或不止一行）"
    for fact in ("HEAD_SHA", "CI_COMMIT_REF_NAME", "MR_TARGET_BRANCH", "默认分支", "ref 名"):
        assert fact in row[0], f"§8 退出码 92 那一行没写出 {fact}"
    # 复审 s6 N-1：上面 `"HEAD_SHA" in row` 被成因①（形状不对）满足，于是「缺少 HEAD_SHA」这个成因
    # 漏写了也照样绿。这里要求逐字的日志前缀，取自 entrypoint 那条消息本身。
    missing = re.search(r'echo "(缺少 HEAD_SHA)（', entry)
    assert missing, "entrypoint 的「缺少 HEAD_SHA」消息变了"
    assert f"「{missing.group(1)}」" in row[0].split(" | ")[0], "§8 退出码 92 那一行的现象格没写「缺少 HEAD_SHA」"
    assert f"「{missing.group(1)}」——" in row[0], "§8 退出码 92 那一行没解释「缺少 HEAD_SHA」这个成因"


# ── Task 13 / O-4：§8 的排错表必须是**一张**连续的表 ─────────────────────────────
def _guide_section_lines(heading):
    lines = _guide_text().splitlines()
    start = next((i for i, ln in enumerate(lines) if ln.startswith(f"## {heading}")), None)
    assert start is not None, f"找不到小节标题：## {heading}"
    end = next((i for i, ln in enumerate(lines[start + 1:], start + 1) if ln.startswith("## ")),
               len(lines))
    return lines[start:end]


def test_the_troubleshooting_table_renders_as_one_contiguous_table():
    """原缺陷（O-4）：表格中间有一个空行，空行之后那几行没有表头，GitHub 把它们当普通段落渲染成
    一堆竖线文本——而那几行正是最常查的 401 / 503 / 重投 / 404 / 502。

    判的是「所有表格行连成一片」＋「只有一个表头分隔行」，不是「有没有那个空行」：换成别的非表格
    行（一句说明、一个列表项）插在中间，渲染结果一样坏，这条同样要红。
    """
    section = _guide_section_lines("8. 排错")
    idx = [i for i, ln in enumerate(section) if ln.startswith("|")]
    assert len(idx) >= 12, f"§8 的表格行少于 12 行，守卫的前提不成立：{len(idx)}"
    if idx != list(range(idx[0], idx[0] + len(idx))):
        broken = [section[i][:40] for i in range(idx[0], idx[-1] + 1)
                  if not section[i].startswith("|")]
        raise AssertionError(f"§8 的表格被非表格行劈开了：{broken}")
    seps = [i for i in idx if section[i].replace(" ", "").startswith("|---")]
    assert seps == [idx[1]], f"§8 应当只有一张表、表头分隔行紧跟表头：{seps}"


# ── F6：AWS 档位必须自己设 REVIEW_RERUN_HINT，否则页脚教的是 Flow 的操作 ──────────────
# 共享引擎的默认值是「重跑流水线可重新评审」（scripts/lib/review-render.sh 的
# REVIEW_RERUN_HINT_DEFAULT），而本档位没有流水线：不设这个变量，每条汇总评论末尾都在教读者做一件
# 做不到的事。pipeline/setup-guide.md 第 11.2 节那张表也把本档位列为要改这个变量的一方。
def _container_env(cfg):
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    td = next(iter(Template.from_stack(ExecutorStack(app, "E", cfg=cfg, state=state))
                   .find_resources("AWS::ECS::TaskDefinition").values()))
    return {e["Name"]: e["Value"]
            for e in td["Properties"]["ContainerDefinitions"][0]["Environment"]}


@pytest.mark.parametrize("over,want", [
    # 期望值写成字面量，不引用生产代码里的常量：引用的话改坏了取值两边一起变，守卫恒绿。
    ({"review_command": 1}, "评论 `/kiro review` 可重新评审"),
    ({"review_command": 0}, "向源分支推送新提交可重新评审"),
    ({"review_command": 1, "command_phrase": "Kiro 重新评审"}, "评论 `Kiro 重新评审` 可重新评审"),
    # 开关开着但短语被显式清空：调度器此时 fail closed（一条命令都不受理），页脚不能承诺评论命令
    ({"review_command": 1, "command_phrase": ""}, "向源分支推送新提交可重新评审"),
    # 开关关着时，短语配了也不该出现在页脚里
    ({"review_command": 0, "command_phrase": "Kiro 重新评审"}, "向源分支推送新提交可重新评审"),
])
def test_the_rerun_hint_reaches_the_container_env_and_matches_the_toggle(over, want):
    env = _container_env(_full_cfg(**over))
    assert env["REVIEW_RERUN_HINT"] == want, env["REVIEW_RERUN_HINT"]


def test_the_rerun_hint_is_never_the_flow_tier_default():
    # 反向守卫：无论开关取哪个值，都不能出现 Flow 那句（那才是「忘了设」的真实表现）。
    render = (pathlib.Path(__file__).resolve().parents[2]
              / "scripts" / "lib" / "review-render.sh").read_text()
    assert 'REVIEW_RERUN_HINT_DEFAULT="重跑流水线可重新评审"' in render, \
        "引擎的默认值变了：本档位派生的那句提示要跟着复核"
    assert 'local raw="${REVIEW_RERUN_HINT-}"' in render, \
        "引擎读的环境变量名变了，任务定义里那一项就白设了"
    for toggle in (0, 1):
        assert "重跑流水线" not in _container_env(_full_cfg(review_command=toggle))["REVIEW_RERUN_HINT"]


# ── v1.9.1 #06：AWS 档位同样要自己设 REVIEW_LOG_HINT，否则失败评论教读者「请查看流水线日志（构建号 ?）」────────────
def test_the_log_hint_reaches_the_container_env_and_names_the_real_stream_prefix():
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    t = Template.from_stack(ExecutorStack(app, "E", cfg=_full_cfg(), state=state))
    c = _td_by_container(t, "review")["ContainerDefinitions"][0]
    env = {e["Name"]: e["Value"] for e in c["Environment"]}
    # 期望值写成字面量（同上面 F6 的理由）
    assert env.get("REVIEW_LOG_HINT") == "执行器日志在 CloudWatch（执行器日志组，流前缀 executor/）。", env.get("REVIEW_LOG_HINT")
    # 句子里的流前缀 = 容器日志驱动真实的 awslogs-stream-prefix：改了前缀没改这句，这条先红
    prefix = c["LogConfiguration"]["Options"]["awslogs-stream-prefix"]
    assert f"流前缀 {prefix}/" in env["REVIEW_LOG_HINT"], (prefix, env["REVIEW_LOG_HINT"])
    render = (pathlib.Path(__file__).resolve().parents[2] / "scripts" / "lib" / "review-render.sh").read_text()
    assert 'local raw="${REVIEW_LOG_HINT-}"' in render, "引擎读的环境变量名变了，任务定义里那一项就白设了"


# ── phase2a issue 11：两个任务都设 REVIEW_LOG_NAME（截断提示「完整内容见<名字>」与基础设施类失败文案）────────────
def test_both_tasks_set_the_log_name_the_engine_reads():
    _, t = _scan_templates(inspector=1)
    # 字面量（同 F6）：改了措辞这条先红，手册与票面跟着改。扫描任务用自己的名字（复审 M-1，Kent 2026-10-11）：扫描员的失败提示与
    # Security 汇总都说「扫描任务日志」，全文在 scan/ 流里，写成执行器日志会让读者去 executor/ 流里找
    want = {"review": "执行器日志（CloudWatch）", "scan": "扫描任务日志（CloudWatch，流前缀 scan/）"}
    for name, value in want.items():
        c = _td_by_container(t, name)["ContainerDefinitions"][0]
        env = {e["Name"]: e["Value"] for e in c["Environment"]}
        assert env.get("REVIEW_LOG_NAME") == value, (name, env.get("REVIEW_LOG_NAME"))
    scan = _td_by_container(t, "scan")["ContainerDefinitions"][0]
    prefix = scan["LogConfiguration"]["Options"]["awslogs-stream-prefix"]
    assert f"流前缀 {prefix}/" in want["scan"], "扫描任务名字里的流前缀要与它真实的 awslogs-stream-prefix 一致"
    render = (pathlib.Path(__file__).resolve().parents[2] / "scripts" / "lib" / "review-render.sh").read_text()
    assert 'local raw="${REVIEW_LOG_NAME-}"' in render, "引擎读的环境变量名变了，任务定义里那一项就白设了"


def test_the_guide_names_both_hints_that_differ_from_the_engine_default():
    # 手册 §4.3 原先说「唯一一个刻意与引擎缺省值不同的是 REVIEW_RERUN_HINT」；v1.9.1 #06 起 REVIEW_LOG_HINT 也是，表里要有它的那一行
    sec = "\n".join(_guide_section_lines("4."))
    assert "唯一一个刻意与引擎缺省值不同" not in sec, "§4.3 还在说只有一个变量与引擎缺省值不同"
    # phase2a issue 11 起是三个（REVIEW_LOG_NAME）
    assert "**三个刻意与引擎缺省值不同的是 `REVIEW_RERUN_HINT`、`REVIEW_LOG_HINT` 与 `REVIEW_LOG_NAME`**" in sec
    row = next((ln for ln in sec.splitlines() if ln.startswith("| `REVIEW_LOG_HINT` |")), "")
    assert "执行器日志在 CloudWatch（执行器日志组，流前缀 executor/）。" in row and "请查看流水线日志或重跑流水线。" in row, row
    assert "构建号 ?" not in row, "§4.3 还说不设时会出现「构建号 ?」（v1.9.1 起没有构建号时不再打那一段）"
    row = next((ln for ln in sec.splitlines() if ln.startswith("| `REVIEW_LOG_NAME` |")), "")
    assert "`执行器日志（CloudWatch）`" in row and "流水线日志" in row, row


def test_the_cross_region_inference_note_describes_the_shipped_continuum_not_a_future_milestone(write_cfg, capsys):
    # v1.9.1：手册 §1.2 与 synth 时那行警告原先写的是 2a 时的状态（「本档位（2a）本身不调用任何模型推理」「若日后启用 Security Agent（2b 里程碑）」），
    # Continuum 早已发布。三个全局推理区域与 config.py 的 GLOBAL_INFERENCE_REGIONS 对拍
    import config as cfgmod
    sec = _guide_subsection("1.2")
    for stale in ("本档位（2a）本身不调用任何模型推理", "若日后启用", "2b 里程碑"):
        assert stale not in sec, stale
    assert "`security_agent: 1`" in sec, "§1.2 没说推理只在开了 Continuum 时发生"
    assert set(re.findall(r"`([a-z]{2}-[a-z]+-[0-9])`", sec.split("\n\n")[1])) == set(cfgmod.GLOBAL_INFERENCE_REGIONS), sec
    load_config(write_cfg(_cfg(region="ap-southeast-1")))
    out = capsys.readouterr().out
    assert "any commercial" in out and "若日后" not in out and "security_agent: 1" in out, out


def test_the_command_phrase_default_is_written_in_exactly_one_place():
    """短语默认值有两个消费者（调度器判正文、执行器印页脚）。两边各写一份字面量的话，改默认值时
    漏掉一处就是「页脚教的短语触发不了评审」——那是静默的假承诺，没有任何报错。
    """
    import ast
    import re
    aws_dir = pathlib.Path(__file__).resolve().parents[1]
    srcs = {p.relative_to(aws_dir).as_posix(): p.read_text()
            for p in [aws_dir / "app.py", aws_dir / "config.py",
                      *sorted((aws_dir / "stacks").glob("*.py"))]}
    from config import DEFAULT_COMMAND_PHRASE

    def _literal_count(src):
        """数的是**代码里的字符串字面量**，不是文本出现次数：注释里写出这句短语（解释它是默认值）
        不算第二份实现，而 `src.count()` 会把它算进去。"""
        return sum(1 for n in ast.walk(ast.parse(src))
                   if isinstance(n, ast.Constant) and n.value == DEFAULT_COMMAND_PHRASE)

    where = {name: _literal_count(src) for name, src in srcs.items()}
    assert sum(where.values()) == 1, f"短语默认值出现在多处（或一处都没有）：{where}"
    assert where["config.py"] == 1, where
    # 派生那一侧必须真的用这个常量，而不是恰好也写对了一个同样的字面量
    assert "DEFAULT_COMMAND_PHRASE" in srcs["stacks/executor_stack.py"], \
        "executor_stack 没有引用那个常量（短语缺省时页脚会与调度器实际认的短语不一致）"
    # 调度 Lambda 是独立部署包、不 import config.py，只能各自写一份；那一份必须与常量一致
    handler = (aws_dir / "lambda" / "dispatcher" / "handler.py").read_text()
    assert re.search(r'os\.environ\.get\("REVIEW_COMMAND_PHRASE",\s*"([^"]*)"\)', handler).group(1) \
        == DEFAULT_COMMAND_PHRASE, "handler.py 的兜底短语与 config.py 的常量不一致"


# ── 机器人与人同号：显式 bot_usernames: [] 必须一路活到运行时的空名单 ──────────────────
def test_an_explicit_empty_bot_list_survives_to_an_empty_env_and_parses_back_to_empty():
    """手册 4.2 教「机器人与人同号时把 bot_usernames 设成 []」，这条把那句话钉在三处：
    app.py 的 setdefault 不覆盖显式的 []、模板里那一项是空字符串、运行时解析回空名单。
    """
    cfg = _full_cfg(bot_usernames=[])
    envs = _all_envs(cfg)
    disp = [env for src, env in envs.items() if "DispatcherFn" in src]
    assert len(disp) == 1, envs.keys()
    assert disp[0]["BOT_USERNAMES"] == "", disp[0]["BOT_USERNAMES"]
    # app.py 这一层：显式的 [] 不能被 setdefault 换成 [bot_username]
    stacks = _app_mod.build_stacks(cdk.App(), dict(cfg))
    tmpl = Template.from_stack(stacks[2])
    fns = tmpl.find_resources("AWS::Lambda::Function")
    got = {k: v["Properties"]["Environment"]["Variables"].get("BOT_USERNAMES")
           for k, v in fns.items() if "Dispatcher" in k}
    assert set(got.values()) == {""}, got
    # 运行时那一层（空字符串必须解析回空名单，而不是 [""]）在 test_dispatcher.py 里断言：
    # 那个文件才把 lambda/dispatcher 放进了 sys.path（handler.py 要 import codeup_min）。


def test_a_null_bot_list_is_refused_with_a_message_that_names_the_fix(write_cfg):
    # `bot_usernames:`（空值）在 YAML 里是 null，不是空列表：`",".join(None)` 会在 CDK 内部抛
    # TypeError，报错说不出「配置写法不对」。手册教的是 `[]`，所以这条错路必须给一句人话。
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    for bad in (None, "aliyun:kirobot", [""], ["  "], [None], 3):
        cfg = dict(base, bot_usernames=bad)
        with pytest.raises(ValueError) as exc:
            load_config(write_cfg(cfg))
        assert "bot_usernames" in str(exc.value) and "[]" in str(exc.value), str(exc.value)
    # 正向对照：空列表与正常名单都必须过
    for ok in ([], ["aliyun:kirobot"], ["a", "b"]):
        assert load_config(write_cfg(dict(base, bot_usernames=ok)))["bot_usernames"] == ok


def test_an_absent_command_phrase_is_filled_but_an_explicit_empty_one_is_kept(write_cfg):
    # falsy 但有意义：显式空串是「fail closed，一条命令都不受理」的既有语义（handler 的 if not phrase）。
    # 用 `or` 回落默认会把它悄悄变成「命令照常生效」。
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    from config import DEFAULT_COMMAND_PHRASE
    bare = {k: v for k, v in base.items() if k != "command_phrase"}
    assert load_config(write_cfg(bare))["command_phrase"] == DEFAULT_COMMAND_PHRASE
    assert load_config(write_cfg(dict(base, command_phrase="")))["command_phrase"] == ""
    # 显式 null 不再原样放行（复审 s5 M-1，吸收 pre-accept M-a）：到 CDK 里只剩一句看不懂的
    # 「Unable to deserialize value」。现在在 load_config 就报错，并点名这个键。
    with pytest.raises(ValueError, match="command_phrase"):
        load_config(write_cfg(dict(base, command_phrase=None)))


@pytest.mark.parametrize("bad", [None, 123, True, " ", "   ", " /kiro review", "/kiro review ",
                                 "/kiro\nreview", "\t/kiro",
                                 # issue 05 C1：以前只拒 \n，这些都放行了——人手打的评论里不会有它们，
                                 # 评论命令静默失效，页脚还照样教读者打这句
                                 "/kiro\rreview", "/kiro\treview", "/kiro\x00review", "/kiro\x7freview",
                                 "/kiro\x85review", "/kiro\u200breview", "/kiro\u2028review"])
def test_a_command_phrase_that_is_not_a_clean_string_is_refused_naming_the_key(bad, write_cfg):
    # 全空白是空串的孪生兄弟却不 fail closed：任何含这串空格的评论都会拉起一次评审
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    with pytest.raises(ValueError, match="command_phrase"):
        load_config(write_cfg(dict(base, command_phrase=bad)))


@pytest.mark.parametrize("good", ["", "/kiro review", "Kiro 重新评审", "/kiro  review",
                                  "Kiro\u3000重新评审"])
def test_clean_command_phrases_are_kept_verbatim(good, write_cfg):
    # 正向对照：空串（fail closed 的既有语义）与中间带空白的短语都合法，原样保留。全角空格（中文输入法
    # 打得出来、看得见）也合法：拒的是控制字符与零宽/行分隔这类看不见的字符，不是所有非 ASCII 空白
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    assert load_config(write_cfg(dict(base, command_phrase=good)))["command_phrase"] == good


@pytest.mark.parametrize("bad", [" aliyun:bot", "aliyun:bot ", "aliyun:a,aliyun:b", "\taliyun:bot",
                                 "aliyun:\x00bot", "aliyun:bot\u200b", 123, True, 0, False])
def test_bot_username_must_be_a_clean_string(bad, write_cfg):
    """issue 05 C2：bot_username 以前只查真值。带首尾空白 → 作者守卫永不命中、引擎按作者找不到上一条
    汇总（每次新建一条）；带逗号 → 默认名单 [bot_username] 被 join/split 拆成两个名字，第二个人的命令被
    静默忽略；非字符串 → 到 CDK 里才抛一句 TypeError。与 bot_usernames 每一项同一套规则。
    按「bot_username 取值」匹配：别被 bot_usernames 的报错满足。"""
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    base.pop("bot_usernames", None)   # 默认名单由 bot_username 派生：正是绕过了名单校验的那条路
    with pytest.raises(ValueError, match=r"bot_username 取值"):
        load_config(write_cfg(dict(base, bot_username=bad)))


def test_bot_username_is_checked_even_when_bot_usernames_is_given(write_cfg):
    # review-A F-5：验收部署正是这种形状（bot_usernames: []），bot_username 照样进 CODEUP_BOT_USERNAME
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    for names in ([], ["aliyun:kirobot"]):
        with pytest.raises(ValueError, match=r"bot_username 取值"):
            load_config(write_cfg(dict(base, bot_usernames=names, bot_username=" aliyun:bot")))


@pytest.mark.parametrize("good", ["aliyun:kirobot", "aliyun:kingdooo_hvFXC"])
def test_clean_bot_usernames_are_kept_verbatim(good, write_cfg):
    # 正向对照：示例值与验收部署实际用的值的形状
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    assert load_config(write_cfg(dict(base, bot_username=good)))["bot_username"] == good


def test_bot_usernames_items_refuse_control_characters_too(write_cfg):
    # 同一套规则：名单里的每一项也不许带控制字符（以前只查首尾空白与逗号）
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    with pytest.raises(ValueError, match="bot_usernames"):
        load_config(write_cfg(dict(base, bot_usernames=["aliyun:\x00bot"])))


@pytest.mark.parametrize("bad", [[" aliyun:bot"], ["aliyun:bot "], ["a,b"], ["ok", "x,y"], ["\taliyun:bot"]])
def test_bot_username_items_must_be_stripped_and_comma_free(bad, write_cfg):
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    with pytest.raises(ValueError, match="bot_usernames"):
        load_config(write_cfg(dict(base, bot_usernames=bad)))


def test_an_empty_bot_list_is_accepted_with_a_poc_only_warning(write_cfg, capsys):
    base = load_config(str(pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml"))
    capsys.readouterr()
    assert load_config(write_cfg(dict(base, bot_usernames=[])))["bot_usernames"] == []
    out = capsys.readouterr().out
    assert out.startswith("警告：bot_usernames 为空——只适合机器人与人同号的 PoC"), out
    assert "专用机器人账号" in out and "run:N" in out, out
    # 正向对照：非空名单不打这行（否则上面那条可能只是「总在打」）
    assert load_config(write_cfg(dict(base, bot_usernames=["aliyun:bot"])))["bot_usernames"] == ["aliyun:bot"]
    assert "bot_usernames" not in capsys.readouterr().out


# ── spec I6 ②：按 MR 的租约——手册与 entrypoint 两头都钉 ─────────────────────────────
def _entry_code():
    """entrypoint.sh 与它 source 的租约库（Phase 2b：租约函数抽到了 executor/lib/lease.sh）的非注释行。"""
    executor = pathlib.Path(__file__).resolve().parents[1] / "executor"
    entry = (executor / "entrypoint.sh").read_text() + "\n" + (executor / "lib" / "lease.sh").read_text()
    return "\n".join(ln for ln in entry.splitlines() if not ln.lstrip().startswith("#"))


def test_the_guide_documents_the_lease_exit_93_and_every_head_check_result():
    """运维拿日志里那句话去 §8 找行：93 的三条消息与 head-check 的每个取值都逐字取自 entrypoint.sh，
    不在这里另抄一份。每条断言都只在**那一行**里找（整篇或整节里找，别的行碰巧写了同一个词就会假绿）。"""
    code = _entry_code()
    msgs = re.findall(r'echo "([^"]*)" >&2; exit 93', code)
    # 等待超限 / 读写失败 / 读不到本任务 ARN（issue 02），三条消息必须各不相同
    assert len(msgs) == 3 and len(set(msgs)) == 3, msgs
    results = re.findall(r"head-check result=([a-z-]+)", code)
    assert sorted(set(results)) == ["claim-unknown", "current", "moved-unclaimed", "superseded",
                                    "unknown"], results
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]

    row93 = [ln for ln in sec8 if "退出码 93" in ln.split(" | ")[0]]
    assert len(row93) == 1, "§8 缺少退出码 93 那一行（或不止一行）"
    for msg in msgs:
        # `${lease_wait_limit}` / `${lease_err}` 在日志里是具体取值，手册里写成占位；比的是两边的固定部分
        for chunk in re.split(r"\$\{[a-z_]+\}", msg):
            assert chunk.strip("（）") in row93[0], f"§8 退出码 93 那一行没逐字写出：{chunk}"
    for code_name in ("AccessDeniedException", "ResourceNotFoundException", "unknown"):
        assert code_name in row93[0], f"§8 退出码 93 那一行没解释 code={code_name}"

    row_sup = [ln for ln in sec8 if "head-check result=superseded" in ln.split(" | ")[0]]
    assert len(row_sup) == 1, "§8 缺少 head-check result=superseded 那一行（或不止一行）"
    for r in set(results) - {"superseded"}:
        assert f"result={r}" in row_sup[0], f"§8 head-check 那一行没解释 result={r}"

    # 「同一 MR 被评审两次」那一行原先把原因写成「批准事件也触发了调度器」——批准从不触发评审（§0 事件过滤），
    # 而真正的原因（两次推送）过去会并发、现在按租约依次进行。
    row_twice = [ln for ln in sec8 if ln.startswith("| 同一个 MR 短时间内被评审两次")]
    assert len(row_twice) == 1
    assert "租约" in row_twice[0] and "依次" in row_twice[0], "那一行没说两次评审按租约依次进行"
    assert "「批准」事件" not in row_twice[0], "那一行仍说批准事件会触发评审"


def test_the_guide_opening_explains_the_per_mr_lease():
    paras = [p for p in _guide_text().split("\n\n") if p.startswith("**同一 MR 串行")]
    assert len(paras) == 1, "开头缺少「同一 MR 串行」那一段"
    for fact in ("`lease#<仓库 id>#<MR 编号>`", "租期 120 秒", "每 30 秒续期", "`KIRO_TIMEOUT` + 1800 秒",
                 "`KIRO_TIMEOUT` + 2400 秒", "退出码 124", "每 10 秒", "只释放自己持有",
                 "`git ls-remote`", "`head-check result=superseded", "退出码 93", "没有抢锁记录"):
        assert fact in paras[0], f"「同一 MR 串行」那一段没写出：{fact}"
    code = _entry_code()
    assert '"lease#${CODEUP_REPO_ID}#${MR_LOCAL_ID}"' in code, "租约键的形状变了，手册那一段要跟着改"
    # 手册里的四个数都从这几行来（issue 04）：租期、续期间隔、引擎总时长上限、等待上限
    for line in ("LEASE_TTL=120", "LEASE_RENEW_EVERY=30", "engine_cap=$((engine_cap + 1800))",
                 "lease_wait_limit=$((engine_cap + 600))", "/bin/sleep 10", '/bin/sleep "$LEASE_RENEW_EVERY"'):
        assert line in code, f"{line} 变了，手册「同一 MR 串行」那一段要跟着改"
    # 续期间隔必须远小于租期：连着失败两次（每次最坏约 25 秒）租约还在（L1）
    ttl = int(re.search(r"^LEASE_TTL=(\d+)$", code, re.M).group(1))
    every = int(re.search(r"^LEASE_RENEW_EVERY=(\d+)$", code, re.M).group(1))
    assert 3 * every < ttl, (every, ttl)


def test_the_guide_documents_the_engine_cap_exit_124():
    """引擎总时长上限那条消息逐字取自 entrypoint.sh，§8 标着「退出码 124」的那一行必须逐字写出（issue 04）。"""
    msgs = re.findall(r'echo "(评审引擎超过总时长上限[^"]*)" >&2', _entry_code())
    assert len(msgs) == 1, msgs
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]
    row = [ln for ln in sec8 if "退出码 124" in ln.split(" | ")[0]]
    assert len(row) == 1, "§8 缺少退出码 124 那一行（或不止一行）"
    for chunk in re.split(r"\$\{[a-z_]+\}", msgs[0]):
        assert chunk in row[0], f"§8 退出码 124 那一行没逐字写出：{chunk}"


# ── 兜底可靠性（全分支复审 s1 F2）：重试耗尽的事件不得被 Lambda 静默丢弃 ─────────────────
def _only(t, typ, pred=lambda k, r: True):
    found = {k: r for k, r in t.find_resources(typ).items() if pred(k, r)}
    assert len(found) == 1, (typ, sorted(found))
    return next(iter(found.items()))


def test_backstop_failed_async_invocations_land_in_an_encrypted_14_day_queue():
    t = _disp_template()
    fn_id, _ = _only(t, "AWS::Lambda::Function", lambda k, r: k.startswith("BackstopFn"))
    q_id, q = _only(t, "AWS::SQS::Queue")
    assert q["Properties"].get("SqsManagedSseEnabled") is True, q["Properties"]
    assert q["Properties"].get("MessageRetentionPeriod") == 14 * 86400, q["Properties"]
    _, eic = _only(t, "AWS::Lambda::EventInvokeConfig")
    p = eic["Properties"]
    assert p["FunctionName"] == {"Ref": fn_id}, p
    assert p["Qualifier"] == "$LATEST", p
    assert p["MaximumRetryAttempts"] == 2, p
    assert p["DestinationConfig"] == {"OnFailure": {"Destination": {"Fn::GetAtt": [q_id, "Arn"]}}}, p
    # 目的地要真的写得进去：兜底角色必须能往这个队列 SendMessage（CDK 的 SqsDestination 负责授）
    sends = set()
    for pol in t.find_resources("AWS::IAM::Policy").values():
        if "BackstopFn" not in json.dumps(pol["Properties"].get("Roles")):
            continue
        for stmt in pol["Properties"]["PolicyDocument"]["Statement"]:
            if "sqs:SendMessage" in _as_list(stmt["Action"]):
                sends.update(json.dumps(r, sort_keys=True) for r in _as_list(stmt["Resource"]))
    assert sends == {json.dumps({"Fn::GetAtt": [q_id, "Arn"]}, sort_keys=True)}, sends


def test_the_backstop_alarms_fire_on_the_first_occurrence_and_notify_one_topic():
    t = _disp_template()
    fn_id, _ = _only(t, "AWS::Lambda::Function", lambda k, r: k.startswith("BackstopFn"))
    q_id, _ = _only(t, "AWS::SQS::Queue")
    topic_id, _ = _only(t, "AWS::SNS::Topic")
    alarms = {(a["Properties"]["Namespace"], a["Properties"]["MetricName"]): a["Properties"]
              for a in t.find_resources("AWS::CloudWatch::Alarm").values()}
    # issue 05 B5：第三个告警补上「重试耗尽 → 进队列」这条链上唯一没有告警的一环——事件连队列都没进去
    # （投递失败）时队列告警没有消息可数。AsyncEventsDropped 不加：配了 OnFailure 目的地时，事件先送进
    # 目的地再计为 dropped（Lambda 文档 Asynchronous invocation metrics），与队列告警重复。
    assert set(alarms) == {("AWS/SQS", "ApproximateNumberOfMessagesVisible"),
                           ("AWS/Lambda", "Errors"),
                           ("AWS/Lambda", "DestinationDeliveryFailures")}, set(alarms)
    dims = {("AWS/SQS", "ApproximateNumberOfMessagesVisible"):
            [{"Name": "QueueName", "Value": {"Fn::GetAtt": [q_id, "QueueName"]}}],
            ("AWS/Lambda", "Errors"): [{"Name": "FunctionName", "Value": {"Ref": fn_id}}],
            ("AWS/Lambda", "DestinationDeliveryFailures"): [{"Name": "FunctionName", "Value": {"Ref": fn_id}}]}
    stats = {("AWS/SQS", "ApproximateNumberOfMessagesVisible"): "Maximum",
             ("AWS/Lambda", "Errors"): "Sum", ("AWS/Lambda", "DestinationDeliveryFailures"): "Sum"}
    for key, a in alarms.items():
        assert a["Dimensions"] == dims[key], (key, a["Dimensions"])
        assert a["Statistic"] == stats[key] and a["Period"] == 300, (key, a.get("Statistic"), a.get("Period"))
        # 「> 0」：第一次出现就告警。阈值 0 是有意义的取值（falsy），GreaterThanOrEqual 0 会恒真
        assert a["Threshold"] == 0 and a["ComparisonOperator"] == "GreaterThanThreshold", (key, a)
        assert a["EvaluationPeriods"] == 1 and a["TreatMissingData"] == "notBreaching", (key, a)
        assert a["AlarmActions"] == [{"Ref": topic_id}], (key, a.get("AlarmActions"))
    outputs = t.to_json()["Outputs"]
    assert {"BackstopAlarmTopicArn", "BackstopFailuresQueueUrl", "BackstopFunctionName"} \
        <= set(outputs), sorted(outputs)
    assert outputs["BackstopFunctionName"]["Value"] == {"Ref": fn_id}
    assert outputs["BackstopFailuresQueueUrl"]["Value"] == {"Ref": q_id}
    assert outputs["BackstopAlarmTopicArn"]["Value"] == {"Ref": topic_id}


def test_the_guide_says_how_to_subscribe_to_and_replay_backstop_failures():
    """每条断言只在它那一行里找：整节里找的话，别的行碰巧提到同一个词就会假绿。"""
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]
    row = [ln for ln in sec8 if ln.startswith("| 收到兜底告警")]
    assert len(row) == 1, "§8 缺少「收到兜底告警」那一行"
    t = _disp_template()
    outputs = set(t.to_json()["Outputs"])
    alarms = {k for k in t.find_resources("AWS::CloudWatch::Alarm")}
    for name in ("BackstopAlarmTopicArn", "BackstopFailuresQueueUrl", "BackstopFunctionName"):
        assert name in outputs, f"部署输出里没有 {name}，手册那一行引用的是它"
        assert f"<{name}>" in row[0], f"「收到兜底告警」那一行没用部署输出 {name}"
    for alarm in ("BackstopFailuresAlarm", "BackstopErrorsAlarm", "BackstopDeliveryFailuresAlarm"):
        assert any(k.startswith(alarm) for k in alarms), f"模板里没有 {alarm}"
        assert f"`{alarm}`" in row[0], f"那一行没点名 {alarm}"
    assert "连队列都没进去" in row[0], "那一行没说 BackstopDeliveryFailuresAlarm 意味着什么"
    for step in ("aws sns subscribe", "aws sqs receive-message", ".requestPayload",
                 "aws lambda invoke", "fileb://event.json", "aws sqs delete-message",
                 '"posted": true', "RetriesExhausted", "14 天"):
        assert step in row[0], f"「收到兜底告警」那一行缺：{step}"
    # issue 05 B1：函数自己失败时 `aws lambda invoke` 照样退出 0（失败只在 FunctionError 与 out.json 里），
    # 「命令本身就会报错」会让人用 && 把 invoke 与 delete-message 串起来、误删消息。
    for fact in ("`\"FunctionError\": \"Unhandled\"`", "照样退出 0", "**不要**用 `&&`"):
        assert fact in row[0], f"「收到兜底告警」那一行缺：{fact}"
    assert "命令本身就会报错" not in row[0]
    # issue 05 B6：队列告警只在进入告警状态的那一刻通知一次，回放必须把队列清空。
    for fact in ("通知**一次**", "清空", "ApproximateNumberOfMessagesNotVisible", "--wait-time-seconds 20",
                 "一直停在告警状态"):
        assert fact in row[0], f"「收到兜底告警」那一行缺：{fact}"
    assert "直到 `receive-message` 返回空）" not in row[0], "短轮询返回空不代表队列空了"

    silent = [ln for ln in sec8 if ln.startswith("| 评审任务确实异常结束了，MR 上却**没有**兜底评论")]
    assert len(silent) == 1
    backstop = (pathlib.Path(__file__).resolve().parents[1] / "lambda" / "backstop" / "handler.py").read_text()
    steps = re.findall(r'print\("backstop step=([a-z-]+)"', backstop)
    assert steps == ["read-mark", "fetch-token", "post-comment"], steps
    for step in steps:
        assert f"`backstop step={step}`" in silent[0], f"那一行没列出步骤日志 backstop step={step}"
    for fact in ("`PostFailed`", "`BackstopFailures`", "不会被丢掉"):
        assert fact in silent[0], f"「没有兜底评论」那一行缺：{fact}"
    # issue 05 B2：连上之后读超时 / 被重置时抛的是原始异常、没有 result=failed 那一行（/tmp 实测），
    # 不是 PostFailed。
    for fact in ("`backstop step=post-comment result=failed`", "`TimeoutError`", "`ConnectionResetError`",
                 "`RemoteDisconnected`", "没有 `result=failed` 那一行", "`[ERROR] PostFailed: post-comment`"):
        assert fact in silent[0], f"「没有兜底评论」那一行缺：{fact}"
    # review-A F-2：运行时的错误记录不打 __cause__，别再说「其上还会带原始 AWS 错误正文」
    assert "其上还会带原始 AWS 错误正文" not in silent[0] and "traceback 末行" not in silent[0]
    assert "不再把失败当成功" not in silent[0]
    # issue 05 B4（Kent 10-01 裁决：只写进文档）：发评论只有每次 socket 操作的超时、没有整体截止时间。
    assert "整体截止时间" in silent[0]
    codeup_min = (pathlib.Path(__file__).resolve().parents[1] / "lambda" / "dispatcher" / "codeup_min.py").read_text()
    assert "整体截止时间" in codeup_min and "每次 socket 操作" in codeup_min


def test_the_503_row_lists_the_timeout_codes_the_bounded_client_can_now_produce():
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]
    row = [ln for ln in sec8 if ln.startswith("| Codeup 的 webhook 投递记录显示 503")]
    assert len(row) == 1
    for code in ("`ReadTimeoutError`", "`ConnectTimeoutError`", "`EndpointConnectionError`",
                 "bounded_config.py"):
        assert code in row[0], f"503 那一行缺：{code}"
    # 代号是开放集合（AWS 错误码或异常类型名），原文「只有固定几种，正是四类成因」既数错又说成了封闭集合
    assert "只有固定几种" not in row[0]


def test_the_guide_says_where_the_git_error_tail_shows_up_for_exit_91_and_92():
    """全分支复审 s1/s6：git 的 stderr 以前一律丢掉，91 的三类成因「区分不开、逐个排除」。现在 entrypoint
    打一段带固定前缀的尾巴；手册的 91 / 92 两行要告诉运维去看它。前缀取自 entrypoint，不在这里另写。"""
    entry = (pathlib.Path(__file__).resolve().parents[1] / "executor" / "entrypoint.sh").read_text()
    m = re.search(r"sed 's/\^/  (git: )/'", entry)
    assert m, "entrypoint 的 git 报错尾巴前缀变了"
    prefix = m.group(1)
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]
    for code in (91, 92):
        row = [ln for ln in sec8 if f"退出码 {code}" in ln.split(" | ")[0]]
        assert len(row) == 1, code
        assert f"`{prefix}`" in row[0], f"§8 退出码 {code} 那一行没说 git 报错的尾巴在哪"
    row91 = [ln for ln in sec8 if "退出码 91" in ln.split(" | ")[0]][0]
    assert "区分不开，需要逐个排除" not in row91, "91 那一行仍说三类成因区分不开"
    assert "`<redacted>`" in row91 and "不进 MR 评论" in row91


# ── 最终修复轮 C：文档与小修的守卫。每一条都只在它那一行 / 那一段 / 那一段注释里找 ──────────
def test_the_dispatchers_retry_chain_comment_labels_only_503_as_measured():
    """复审 s2 M-1（延期的 L34 实际发生了）：dispatch 里那段注释曾写「Codeup 对非 2xx 会…立即重投
    2 次（Task 1 实测）」，实测的只有 503。只在**那一段注释**里判，不整篇判：同一文件别处（F4 那段）
    正当地写着「只测了 503」，整篇判会被它满足。"""
    handler = (pathlib.Path(__file__).resolve().parents[1] / "lambda" / "dispatcher" / "handler.py").read_text()
    body = handler.split("\ndef dispatch(", 1)[1].split("\ndef ", 1)[0]
    lines = body.splitlines()
    start = next(i for i, ln in enumerate(lines) if "抢锁已经成功" in ln)
    block = []
    for ln in lines[start:]:
        if not ln.strip().startswith("#"):
            break
        block.append(ln.strip().lstrip("#").strip())
    comment = "".join(block)
    assert "（Task 1 实测）" in comment, "那段注释不再引用实测，这条守卫的前提没了"
    assert "对 503 会" in comment and "对 502" in comment and "没有测过" in comment, comment
    # 「实测」只许挂在 503 那一句上
    assert comment.index("对 503 会") < comment.index("（Task 1 实测）") < comment.index("对 502"), comment
    assert "非 2xx" not in comment, "那段注释又把「非 2xx 都重投」写成了实测结论"


def test_the_troubleshooting_table_refers_to_rows_by_name_and_every_name_resolves():
    """复审 s2 M-2 / L35：「见上面那一行」「见下一行」这类位置引用一插行就错（502/504 那一行的「上面那一行」
    早就指错了）。§8 里一律按名字引用，而且每个名字都要唯一对上一行的「现象」格。"""
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]
    for ln in sec8:
        # issue 05 A2：「见下面 `head-check` 那一行」这种中间夹了名字的写法以前漏过了（其中一处方向还是错的）。
        found = re.findall(r"上一行|下一行|上一条|下一条|上一格|下一格|(?<!最)(?:前|后)一[行条格]|上面那一行|下面那一行"
                           r"|(?:上面|下面|上方|下方|前面|后面|上文|下文)(?:「[^」]*」|[^，。；（）|「」]){0,40}?"
                           r"(?:[那这]一?[行条格栏]|所在的?行)", ln)
        # (?<!最)：§8 里「最后一行就是卡住的那一步」「第 3 节最后一条」是合法写法
        # 「…」 整段放行：名字里可能带全角括号（review 变异「见下面「head-check（租约）」那一行」以前漏过）
        assert not found, f"§8 仍有位置引用 {found}：{ln[:60]}"
    firsts = [ln.split(" | ")[0].replace("**", "").replace("`", "") for ln in sec8]
    names = set()
    for ln in sec8:
        names.update(re.findall(r"本表「([^」]+)」那一行", ln))
    assert len(names) >= 5, names   # 不是空真：这几处位置引用都已经换成了名字
    for name in names:
        hits = [f for f in firsts if name in f]
        assert len(hits) == 1, f"本表「{name}」那一行对上了 {len(hits)} 行"


def test_references_into_the_troubleshooting_table_from_other_sections_are_by_name():
    """issue 05 A1：上面那条只扫 §8 表内，§0 的「第 8 节最后几行」与 §4.2 的「第 8 节倒数第二行」不在它的范围里，
    而这两处从写下起就指错了（那一行是倒数第六行）。全文一律写「第 8 节「X」那一行」，X 唯一对上 §8 一行的「现象」格。"""
    guide = _guide_text()
    found = re.findall(r"(?:第\s*[8八]\s*节|§\s*8)[^「」。，）\n]{0,4}?(?:倒数|最后|末尾|第.{1,3}行)", guide)
    assert not found, f"仍有指向第 8 节的位置引用：{found}"
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]
    firsts = [ln.split(" | ")[0].replace("**", "").replace("`", "") for ln in sec8]
    names = re.findall(r"第 8 节「([^」]+)」那一行", guide)
    assert len(names) >= 2, names   # 不是空真：那两处都已换成名字
    for name in names:
        hits = [f for f in firsts if name in f]
        assert len(hits) == 1, f"第 8 节「{name}」那一行对上了 {len(hits)} 行"


def test_the_redelivery_row_describes_an_observable_symptom():
    """复审 s2 M-3：我们部署的代码不记录 X-Codeup-Delivery，「同一个 X-Codeup-Delivery 在日志里出现 2~3 次」
    是看不到的现象；「只有第一次能拉起」对实测的 503 也不对（回 503 的那几次根本没走到抢锁）。"""
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]
    row = [ln for ln in sec8 if ln.startswith("| Codeup 重投同一次投递")]
    assert len(row) == 1
    first = row[0].split(" | ")[0]
    assert "REPORT" in first and "查不到" in first, first
    assert "只有第一次能真正拉起" not in row[0]
    assert "抢到锁的那一次" in row[0]
    # 反向核对「查不到」这句话：调度器的代码里没有任何一个非文档字符串的字面量提到这个头
    # （文档字符串与注释正当地提到它，不算）。哪天开始读/记它，这一行的现象要改回来。
    import ast
    handler = (pathlib.Path(__file__).resolve().parents[1] / "lambda" / "dispatcher" / "handler.py").read_text()
    tree = ast.parse(handler)
    docstrings = {id(n.value) for n in ast.walk(tree)
                  if isinstance(n, ast.Expr) and isinstance(n.value, ast.Constant)}
    literals = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant)
                and isinstance(n.value, str) and id(n) not in docstrings]
    assert literals and not [v for v in literals if "delivery" in v.lower()], "调度器开始读/记 delivery id 了"


def test_the_merged_or_closed_states_are_labelled_doc_derived_and_unmeasured():
    """复审 s5 M-2：merged / closed 只见于云效文档，Task 1 只见过 opened/accepted。两处都不得再写成确知。"""
    rows = [ln for ln in _guide_text().splitlines() if ln.startswith("|")]
    r43 = [ln for ln in rows if ln.startswith("| `REVIEW_COMMAND` / `REVIEW_COMMAND_PHRASE`")]
    assert len(r43) == 1
    sent = r43[0].split("已合并/已关闭的 MR 上的命令不受理", 1)[1].split("。短语为空串", 1)[0]
    assert "没有实测过" in sent and "照常评审" in sent, sent
    r8 = [ln for ln in rows if "ignored reason=<代号>" in ln and "固定枚举：" in ln]
    assert len(r8) == 1
    seg = r8[0].split("`mr-not-open`（**正常流量**", 1)[1].split("）。日志里", 1)[0]
    assert "没有实测过" in seg and "确知" not in seg, seg
    # issue 05 D3：代码注释同一口径（handler.py 以前有两处「确知的取值」，紧接着又说没有实测样本）。
    handler = (pathlib.Path(__file__).resolve().parents[1] / "lambda" / "dispatcher" / "handler.py").read_text()
    assert "确知" not in handler


def test_the_guide_says_bot_equals_human_is_poc_only_with_the_adoption_hazard_and_recovery():
    """复审 s5 I-1：真实验收（N5，Codeup-Demo MR !4）里人发的带标记评论被引擎当成汇总接管了；
    手册以前说唯一的代价是「触发短语被忽略」。"""
    guide = _guide_text()
    paras = [p for p in guide.split("\n\n") if p.startswith("**机器人与人是同一个账号只适合 PoC")]
    assert len(paras) == 1, "4.2 缺少「只适合 PoC」那一段"
    for fact in ("第 1.4 节", "`CODEUP_BOT_USERNAME`", "接管", "**恢复**", "删掉那条评论",
                 "`<!-- kiro-test -->`", "`ignored reason=kiro-marker`", "`cdk synth` 会打一行警告"):
        assert fact in paras[0], f"「只适合 PoC」那一段缺：{fact}"
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]
    row = [ln for ln in sec8 if ln.startswith("| 担心「机器人评论触发新评审」的死循环")]
    assert len(row) == 1
    tail = row[0].split("代价", 1)[1]
    for fact in ("只适合 PoC", "接管", "删掉那条评论", "专用机器人账号"):
        assert fact in tail, f"§8 断环那一行的「代价」没写出：{fact}"
    example = (pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml").read_text()
    block = example.split("# bot_usernames:", 1)[1].split("# command_phrase:", 1)[0]
    assert "只适合 PoC" in block and "专用机器人账号" in block, block


def test_the_guide_does_not_claim_no_process_environ_holds_the_token():
    """issue 05 G5（s6 m-D）：§3 以前说「任何进程的 /proc/<pid>/environ 都看不到令牌值本身」，紧接着又说
    YUNXIAO_TOKEN 里就有——entrypoint、git、评审引擎都继承它。只在「令牌不在 argv…」那一条里找。
    issue 09：引擎调 Codeup API 也改成经 stdin 给 curl 请求头，这一条要写出 git、curl 两条路都不进 argv，environ 照旧有。"""
    lines = _guide_section_lines("3.")
    start = next(i for i, ln in enumerate(lines) if ln.startswith("  - **令牌不在 argv"))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("  - "))
    item = "\n".join(lines[start:end])
    assert "都看不到令牌值本身" not in item, item
    # review-A F-1：environ 里有令牌，不能笼统说「任何进程里都没有」——cmdline 的结论只按 git、curl 两条路各自写
    assert "不出现在任何进程的" not in item, item
    # 收口复审 R-1：换个说法（「都看不到」「不会出现在任何进程」）也不行；正向要写出「都读得到令牌」
    assert "看不到" not in item, item
    assert not re.search(r"不(?:会)?出现在任何进程", item), item
    assert "都读得到令牌" in item, item
    for fact in ("`/proc/<pid>/cmdline`", "`YUNXIAO_TOKEN`", "进程树", "不继承", "`scripts/lib/codeup-api.sh`",
                 "curl 用 `-H @-` 从 stdin 读请求头", "令牌值不出现在 git 或 curl 进程的 `/proc/<pid>/cmdline` 里"):
        assert fact in item, f"§3「令牌不在 argv」那一条缺：{fact}"
    # issue 09：旧说法（引擎把令牌写在 curl 的命令行参数里、这只管 git 这一条路、另开票）一句都不能留——整句的方向反了
    for stale in ("这只管 git 这一条路", "另开票"):
        assert stale not in item, item
    # 近义句同样算（复审 N-6）：同一句（不跨句号）里「令牌……写/放 在/进……curl……参数」或「……argv」就红。
    # 宁可把否定式（「不写进 curl 的参数」）也误判成红——这一条请用正面说法写。
    assert not re.search(r"令牌[^。]*?(?:写|放)(?:在|进)[^。]*?(?:curl[^。]*?参数|argv)", item), item
    # 代码侧只核对「写法与手册同向」：argv 里到底有没有令牌由 bash 行为测试守（tests/test-codeup-api.sh 的 issue 09
    # 回环段、tests/test-aws-entrypoint.sh ㉕），这里不冒充那一层。只看非注释行——两份源码的注释里都写着 `-H @-`（复审 N-5）。
    root = pathlib.Path(__file__).resolve().parents[2]
    header_via_stdin = re.compile(r"""printf 'x-yunxiao-token: %s\\n' "\$\{YUNXIAO_TOKEN(?::-)?\}" \\\n\s*\|\s*\S*curl -q """)
    for rel in ("scripts/lib/codeup-api.sh", "aws/executor/entrypoint.sh"):
        code = "\n".join(ln for ln in (root / rel).read_text().splitlines() if not ln.lstrip().startswith("#"))
        assert header_via_stdin.search(code), f"{rel}：令牌不再经 printf 管道给 curl 了，手册 §3 这一条要跟着改"
        assert re.search(r"(?m)^\s*-H @-(?:\s|$)", code), f"{rel}：curl 不再用 -H @- 读请求头了"
        assert not re.search(r"""(?:-H|--header)\s*["']?[^"'\n]*x-yunxiao-token""", code, re.I), \
            f"{rel}：x-yunxiao-token 又写进 curl 的 -H/--header 参数了"


def test_the_guide_states_the_secret_cache_ttl_where_rotation_is_discussed():
    """issue 05 G2：401 那一行以前说缓存「没有 TTL」、要立刻生效得改函数配置；§1.4 教轮换令牌，却没说新值
    多久才生效。数字只写一份：手册里的「N 分钟」从 secret_fetch.py 的 CACHE_TTL_SECONDS 算出来。"""
    src = (pathlib.Path(__file__).resolve().parents[1] / "lambda" / "dispatcher" / "secret_fetch.py").read_text()
    m = re.search(r"^CACHE_TTL_SECONDS = (\d+)$", src, re.M)
    assert m and int(m.group(1)) % 60 == 0, "CACHE_TTL_SECONDS 必须是整分钟"
    minutes = f"{int(m.group(1)) // 60} 分钟"
    row = [ln for ln in _guide_section_lines("8.") if ln.startswith("| Codeup 的 webhook 投递记录显示 401")]
    assert len(row) == 1
    assert "没有 TTL" not in row[0], row[0]
    # webhook 密钥只有调度器读（review-B M-5）：401 那一行不该让人去改兜底
    assert minutes in row[0] and "只有调度器读" in row[0], row[0]
    assert "**两个**函数" not in row[0], row[0]
    sec14 = "\n".join(_guide_section_lines("1.")).split("### 1.4", 1)[1].split("### 1.5", 1)[0]
    for fact in ("轮换", minutes, "**两个**函数"):
        assert fact in sec14, f"§1.4 讲轮换令牌，缺：{fact}"


def test_the_executor_runs_in_beijing_time_without_needing_tzdata():
    """issue 05 E1（Kent 2026-10-01 裁决）：评论里的时间格 Flow 档位是北京时间、AWS 档位以前是 UTC（容器没有 TZ），
    同一次评审差 8 小时（验收实测）。用 POSIX 写法 `CST-8` 不依赖时区数据库：基础镜像目前带 tzdata，但写
    `Asia/Shanghai` 就押在它身上，没有时静默回落成 UTC（`TZ=CST-8 date +%z` 的行为断言在 tests/test-aws-entrypoint.sh，
    容器里也跑）。"""
    env = _all_envs(_full_cfg())["container"]
    assert env["TZ"] == "CST-8", env.get("TZ")
    # review-B N-6：TZ 要一路到得了引擎（它的 date 在 kiro-review.sh 自己的进程里）。引擎不能以 env -i 启动，
    # 也不能把 TZ 摘掉；kiro-cli 的 env -i 许可清单与此无关（模型进程不打时间格）。
    entry = (pathlib.Path(__file__).resolve().parents[1] / "executor" / "entrypoint.sh").read_text()
    code = [ln for ln in entry.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    idx = [i for i, ln in enumerate(code) if "kiro-review.sh" in ln]
    assert len(idx) == 1, idx
    assert not code[idx[0] - 1].rstrip().endswith("\\"), "启动引擎那一行不能是续行（前一行可能接了 env -i）"
    # 收口复审 N-6：只看启动那一行的话，前一行 unset TZ、改用 env --ignore-environment 都漏过——整个文件都不许
    for bad in ("env -i", "--ignore-environment", "unset TZ", "-u TZ", "TZ="):
        assert not [ln for ln in code if bad in ln], (bad, [ln for ln in code if bad in ln])
    row = [ln for ln in _guide_text().splitlines() if ln.startswith("| `TZ` |")]
    assert len(row) == 1, "§4.2 缺 TZ 那一行"
    for fact in ("`CST-8`", "tzdata", "`Asia/Shanghai`", "UTC"):
        assert fact in row[0], f"TZ 那一行缺：{fact}"
    # 收口复审 M-1 残余：debian:stable-slim 带 tzdata（Debian 13 的 required 包），不得再写成「镜像不带」
    for wrong in ("镜像不带", "没有 tzdata", "无 tzdata"):
        assert wrong not in row[0], row[0]


def test_the_six_required_executor_variables_are_named_where_the_guide_counts_them():
    """复审 s6 N-3：4.1 那一格原来写「上面四项加 LOCK_KEY、HEAD_SHA 共六项」，字面所指的「上面四项」
    含可选的 MR_TARGET_BRANCH 而漏了 CI_COMMIT_REF_NAME。现在逐个点名，并与 entrypoint 的必填守卫核对。"""
    entry = (pathlib.Path(__file__).resolve().parents[1] / "executor" / "entrypoint.sh").read_text()
    head = entry.split("# ── N1 镜像摘要门", 1)[0]
    required = re.findall(r'^: "\$\{([A-Z_]+):\?', head, re.M)
    assert '[[ -n "${HEAD_SHA:-}" ]]' in head
    required.append("HEAD_SHA")
    assert sorted(required) == sorted(["CODEUP_REPO_ID", "MR_LOCAL_ID", "CI_COMMIT_REF_NAME",
                                       "BUSINESS_REPO_URL", "LOCK_KEY", "HEAD_SHA"]), required
    row = [ln for ln in _guide_text().splitlines() if ln.startswith("| `CI_COMMIT_REF_NAME` |")]
    assert len(row) == 1
    sent = row[0].split("就要求", 1)[1].split("缺一硬失败", 1)[0]
    assert set(re.findall(r"`([A-Z_]+)`", sent)) == set(required) | {"MR_TARGET_BRANCH"}, sent
    assert "可选" in sent and "上面四项" not in row[0], sent


def test_the_webhook_secret_row_states_the_trust_boundary_with_content_bound_to_the_repo_id():
    """复审 s3 I-2 / s4 O-1：一个共享密钥填进每个接入仓库的 webhook，持有者能触发组织里令牌读得到的任何仓库的评审。
    issue 01 之后评审内容总是来自 MR 所在的仓库（执行器按仓库 id 取 clone 地址），「把 A 的评审贴到 B」不再成立。"""
    guide = _guide_text()
    row = [ln for ln in guide.splitlines() if ln.startswith("| `codeup-kiro/webhook-secret` |")]
    assert len(row) == 1
    for fact in ("**信任边界**", "只有这一个共享密钥", "任何仓库", "按仓库 id", "`clone-url-mismatch`", "轮换"):
        assert fact in row[0], f"webhook 密钥那一行缺：{fact}"
    for stale in ("修好之前", "另一个仓库的 MR 上", "后续工作跟踪"):
        assert stale not in row[0], f"webhook 密钥那一行还在说修复之前的边界：{stale}"
    assert ".scratch" not in guide, "公开手册不得链接本地的 .scratch 路径"


def test_the_guide_documents_the_repo_id_clone_binding_messages():
    """issue 01：按仓库 id 取地址那一段的每一条固定消息都要在 §8 退出码 91 那一行里（取自 entrypoint，不另写一份）；
    clone-url-mismatch 不是错误，单独一行讲它意味着什么。兜底评论里 91 的成因也要提到这一步。"""
    entry = (pathlib.Path(__file__).resolve().parents[1] / "executor" / "entrypoint.sh").read_text()
    seg = entry.split("# ── 按仓库 id 取业务库地址（issue 01）", 1)[1].split("# ── 按仓库 id 取业务库地址：结束", 1)[0]
    msgs = re.findall(r'echo "([^"]+?)，拒绝 clone" >&2', seg)
    assert len(msgs) == 4, msgs
    sec8 = [ln for ln in _guide_section_lines("8.") if ln.startswith("|")]
    row91 = [ln for ln in sec8 if "退出码 91" in ln.split(" | ")[0]]
    assert len(row91) == 1
    for m in msgs:
        assert m in row91[0], f"§8 退出码 91 那一行缺这条消息：{m}"
    for fact in ("`curl: `", "429", "GetRepository", "`httpUrlToRepo`"):
        assert fact in row91[0], f"§8 退出码 91 那一行缺：{fact}"
    mm = [ln for ln in sec8 if ln.startswith("| 日志里有 `clone-url-mismatch`")]
    assert len(mm) == 1, "§8 缺 clone-url-mismatch 那一行"
    for fact in ("照常评审", "按仓库 id", "改名", "轮换", "`httpUrlToRepo`", "平台口径"):
        assert fact in mm[0], f"clone-url-mismatch 那一行缺：{fact}"
    assert "持续出现时按第 3 节轮换" not in mm[0], "持续出现不一定是伪造：先比对两个地址（issue 01 复审 M-8）"
    row41 = [ln for ln in _guide_text().splitlines() if ln.startswith("| 业务库 clone URL（`BUSINESS_REPO_URL`） |")]
    assert len(row41) == 1 and "不用它 clone" in row41[0], row41
    sec14 = "\n".join(_guide_section_lines("1.")).split("### 1.4", 1)[1].split("### 1.5", 1)[0]
    assert "GetRepository" in sec14, "§1.4 要说执行器还要用令牌调 GetRepository（令牌权限）"
    backstop = (pathlib.Path(__file__).resolve().parents[1] / "lambda" / "backstop" / "handler.py").read_text()
    cause91 = re.search(r'^    91: "([^"]+)"', backstop, re.M)
    assert cause91 and "按仓库 id" in cause91.group(1), cause91


# ── Phase 2b：扫描员开关、按评审员的短语与机器人账号（issue 04）──────────────────────────────
def _base_cfg(**over):
    from config import load_config  # noqa: F401
    cfg = {"region": "us-west-2", "org_id": "o1", "bot_username": "aliyun:kirobot",
           "kiro_image_digests": "a" * 64, "kiro_pinned_artifact_sha256": "c" * 64, "kiro_cli_sha256": "d" * 64}
    cfg.update(over)
    return cfg


def test_scanner_toggles_default_off_and_phrases_default_to_the_spec_values(write_cfg):
    from config import load_config
    cfg = load_config(write_cfg(_base_cfg()))
    assert (cfg["inspector"], cfg["security_agent"]) == (0, 0)
    assert (cfg["inspector_command_phrase"], cfg["security_command_phrase"], cfg["all_command_phrase"]) == \
        ("/inspector review", "/security review", "/review")
    assert cfg["inspector_bot_username"] == cfg["security_bot_username"] == "aliyun:kirobot"


@pytest.mark.parametrize("over", [
    {"inspector": 1, "inspector_command_phrase": "/review all"},        # "/review" 是它的子串
    {"inspector": 1, "all_command_phrase": "review"},                   # "review" 是 "/kiro review" 的子串
    {"security_agent": 1, "security_command_phrase": "/kiro review"},   # 与 Kiro 那句相同（互为子串）
])
def test_overlapping_live_phrases_are_rejected(write_cfg, over):
    from config import load_config
    with pytest.raises(ValueError, match="子串"):
        load_config(write_cfg(_base_cfg(**over)))


def test_an_overlapping_phrase_of_a_disabled_reviewer_is_not_checked(write_cfg):
    # 没启用的评审员的短语调度器根本不读：不能因为它拒绝部署（正向对照：上一条不是「凡有重叠就拒」的空转）
    from config import load_config
    load_config(write_cfg(_base_cfg(inspector=0, inspector_command_phrase="/review all")))
    load_config(write_cfg(_base_cfg(inspector=1, all_command_phrase="")))   # 空串不参与比较


def test_the_all_phrase_is_not_checked_while_no_scanner_is_enabled(write_cfg):
    # 复审 I-2：扫描开关全 0 时「全部」那一句不生效（调度器不读它），2a 合法的 command_phrase 不能因为与它重叠而被拒
    from config import load_config
    load_config(write_cfg(_base_cfg(command_phrase="/review please")))
    with pytest.raises(ValueError, match="子串"):   # 正向对照：开了扫描员，「全部」生效，同一份配置就该被拒
        load_config(write_cfg(_base_cfg(inspector=1, command_phrase="/review please")))


@pytest.mark.parametrize("over", [{"inspector": True}, {"security_agent": "1"}, {"inspector": 2},
                                  {"inspector_bot_username": " aliyun:x"}, {"security_bot_username": "a,b"},
                                  {"inspector_max_scan_calls": 0}, {"inspector_max_scan_calls": 21},
                                  {"inspector_max_scan_calls": True}, {"inspector_command_phrase": " /x"}])
def test_scanner_settings_are_strictly_validated(write_cfg, over):
    from config import load_config
    with pytest.raises(ValueError):
        load_config(write_cfg(_base_cfg(**over)))


def test_security_agent_can_be_enabled_and_its_timeout_defaults_to_3600(write_cfg):
    # SA 半段落地后 security_agent: 1 合法（复审 I-4 那道「尚未实现」的拒绝随之撤掉）；超时缺省 3600 秒（spec R8）
    from config import load_config
    cfg = load_config(write_cfg(_base_cfg(security_agent=1)))
    assert cfg["security_agent"] == 1 and cfg["security_agent_timeout"] == 3600
    assert load_config(write_cfg(_base_cfg(security_agent=1, security_agent_timeout=600)))["security_agent_timeout"] == 600


@pytest.mark.parametrize("bad", [599, 7201, 0, "3600", True, 3600.0, None])
def test_security_agent_timeout_is_a_strict_integer_between_600_and_7200(write_cfg, bad):
    from config import load_config
    with pytest.raises(ValueError, match="security_agent_timeout"):
        load_config(write_cfg(_base_cfg(security_agent=1, security_agent_timeout=bad)))


@pytest.mark.parametrize("scanner", [{"inspector": 1}, {"security_agent": 1}])
@pytest.mark.parametrize("bad", ["sixty", "60000 ", -1, 1.5, 1234567890, True, None])
def test_max_comment_bytes_must_pass_the_scan_task_gate_when_a_scanner_is_on(write_cfg, scanner, bad):
    # 针对性复审 M-3：扫描入口对 MAX_COMMENT_BYTES 不是十进制整数（^[0-9]{1,9}$）时一律 95（终审 I-1），Kiro 却只警告、按缺省继续——
    # 开了扫描员时 synth 就按同一条规则拦下，否则部署后两位扫描员在每个 MR 上都失败
    from config import load_config
    with pytest.raises(ValueError, match="max_comment_bytes"):
        load_config(write_cfg(_base_cfg(max_comment_bytes=bad, **scanner)))


def test_max_comment_bytes_gate_matches_what_the_stack_writes(write_cfg):
    from config import load_config
    for ok in (60000, "60000", 0):   # 栈写进任务定义的是 str(取值)：过得了扫描入口的那道正则就放行（下界由引擎按缺省兜）
        load_config(write_cfg(_base_cfg(inspector=1, max_comment_bytes=ok)))
    # 正向对照：没开扫描员时不查（取值语义归共享评审引擎，Kiro 警告后按缺省继续，与 Flow 档位一致）
    load_config(write_cfg(_base_cfg(max_comment_bytes="sixty")))


# ── Phase 2c：飞书通知的开关与平台（issue 20，spec F2）────────────────────────────────────────────
def test_feishu_notify_defaults_off_and_the_platform_defaults_to_feishu(write_cfg):
    from config import load_config
    cfg = load_config(write_cfg(_base_cfg()))
    assert (cfg["feishu_notify"], cfg["feishu_domain"]) == (0, "feishu")
    for v in (0, 1):
        assert load_config(write_cfg(_base_cfg(feishu_notify=v)))["feishu_notify"] == v
    assert load_config(write_cfg(_base_cfg(feishu_domain="lark")))["feishu_domain"] == "lark"


@pytest.mark.parametrize("bad", [True, False, "1", 2, -1, 1.0, None, "on"])
def test_feishu_notify_must_be_exactly_0_or_1(write_cfg, bad):
    from config import load_config
    with pytest.raises(ValueError, match="feishu_notify"):
        load_config(write_cfg(_base_cfg(feishu_notify=bad)))


@pytest.mark.parametrize("bad", ["Feishu", "LARK", "open.feishu.cn", "larksuite", "", None, 1, True])
def test_feishu_domain_is_exactly_feishu_or_lark(write_cfg, bad):
    from config import load_config
    with pytest.raises(ValueError, match="feishu_domain"):
        load_config(write_cfg(_base_cfg(feishu_domain=bad)))


def test_the_unquoted_yaml_yes_is_refused_for_feishu_notify(tmp_path):
    # 与开关同一个坑：PyYAML 把没加引号的 yes/on 解析成布尔值
    from config import load_config
    p = tmp_path / "config.yaml"
    p.write_text("region: us-west-2\norg_id: o1\nbot_username: aliyun:bot\nfeishu_notify: yes\n"
                 f"kiro_image_digests: \"{D1}\"\nkiro_pinned_artifact_sha256: \"{'c' * 64}\"\nkiro_cli_sha256: \"{'d' * 64}\"\n")
    with pytest.raises(ValueError, match="feishu_notify"):
        load_config(str(p))



# ── Phase 2c 阶段二：出站限制的三个键（issue 19，spec「范围」第 2 条）──────────────────────────────────────────────
def test_egress_settings_default_to_the_2b_shape(write_cfg):
    from config import load_config
    cfg = load_config(write_cfg(_base_cfg()))
    assert (cfg["egress_lockdown"], cfg["egress_mode"], cfg["egress_dns_action"]) == (0, "public", "alert")
    ok = load_config(write_cfg(_base_cfg(egress_lockdown=1, egress_mode="nat", egress_dns_action="block")))
    assert (ok["egress_lockdown"], ok["egress_mode"], ok["egress_dns_action"]) == (1, "nat", "block")


@pytest.mark.parametrize("bad", [True, "1", 2, None, 1.0])
def test_egress_lockdown_must_be_exactly_0_or_1(write_cfg, bad):
    from config import load_config
    with pytest.raises(ValueError, match="egress_lockdown"):
        load_config(write_cfg(_base_cfg(egress_lockdown=bad)))


@pytest.mark.parametrize("bad", ["NAT", "private", "", None, 1])
def test_egress_mode_is_exactly_public_or_nat(write_cfg, bad):
    from config import load_config
    with pytest.raises(ValueError, match="egress_mode"):
        load_config(write_cfg(_base_cfg(egress_mode=bad)))


@pytest.mark.parametrize("bad", ["BLOCK", "Alert", "deny", "", None, 1])
def test_egress_dns_action_is_exactly_alert_or_block(write_cfg, bad):
    from config import load_config
    with pytest.raises(ValueError, match="egress_dns_action"):
        load_config(write_cfg(_base_cfg(egress_lockdown=1, egress_dns_action=bad)))


def test_blocking_dns_without_the_lockdown_is_refused(write_cfg):
    # block 只在 egress_lockdown: 1 时有意义（没有 DNS Firewall 可切）：写了却不生效的设置不让它静默通过
    from config import load_config
    with pytest.raises(ValueError, match="egress_dns_action"):
        load_config(write_cfg(_base_cfg(egress_dns_action="block")))


def test_default_bot_usernames_cover_every_enabled_reviewer_once():
    from config import default_bot_usernames
    assert default_bot_usernames(_base_cfg()) == ["aliyun:kirobot"]
    assert default_bot_usernames(_base_cfg(inspector=1, inspector_bot_username="aliyun:insp",
                                           security_agent=1, security_bot_username="aliyun:kirobot")) \
        == ["aliyun:kirobot", "aliyun:insp"]
    assert default_bot_usernames(_base_cfg(inspector=True, inspector_bot_username="x")) == ["aliyun:kirobot"]


def test_dispatcher_and_backstop_get_scanner_token_names_only_for_enabled_scanners():
    from aws_cdk.assertions import Template  # noqa: F401
    envs = _all_envs(_full_cfg(inspector=1, security_agent=0))
    disp = next(env for src, env in envs.items() if "DispatcherFn" in src)
    back = next(env for src, env in envs.items() if "BackstopFn" in src)
    for env in (disp, back):
        assert env["YUNXIAO_TOKEN_INSPECTOR_ID"] == "codeup-kiro/yunxiao-token-inspector"
        assert "YUNXIAO_TOKEN_SECURITY_ID" not in env
    assert disp["INSPECTOR"] == "1" and disp["SECURITY_AGENT"] == "0"
    off = _all_envs(_full_cfg())
    assert not any("YUNXIAO_TOKEN_INSPECTOR_ID" in env for env in off.values())


# ── Phase 2b：扫描任务（Task B）与输入桶（issue 05，spec「S2」「S3」「I7」）─────────────────────
def _scan_templates(**over):
    app = cdk.App()
    state = StateStack(app, "S", cfg={"region": "us-west-2"})
    executor = ExecutorStack(app, "E", cfg=_full_cfg(**over), state=state)
    return executor, Template.from_stack(executor)


def _td_by_container(t, name):
    hits = [v for v in t.find_resources("AWS::ECS::TaskDefinition").values()
            if v["Properties"]["ContainerDefinitions"][0]["Name"] == name]
    assert len(hits) == 1, (name, len(hits))
    return hits[0]["Properties"]


def _policy_statements(t, role_logical_prefix):
    out = []
    for k, v in t.find_resources("AWS::IAM::Policy").items():
        roles = json.dumps(v["Properties"].get("Roles", []))
        # 按 Ref 的逻辑 id **开头**匹配：只写子串的话 "TaskRole" 会把 "ScanTaskRole" 一起算进来
        if f'"Ref": "{role_logical_prefix}' in roles:
            out += v["Properties"]["PolicyDocument"]["Statement"]
    return out


def test_with_both_toggles_off_there_is_no_scan_task_no_bucket_and_no_new_executor_env():
    _, t = _scan_templates()
    assert len(t.find_resources("AWS::ECS::TaskDefinition")) == 1
    assert t.find_resources("AWS::S3::Bucket") == {}
    env = {e["Name"] for e in _td_by_container(t, "review")["ContainerDefinitions"][0]["Environment"]}
    assert not {n for n in env if n.startswith("SCAN_") or n in ("INSPECTOR", "SECURITY_AGENT")}, env


def test_inspector_on_adds_a_scan_task_on_the_same_image_with_its_own_entrypoint():
    _, t = _scan_templates(inspector=1)
    review, scan = _td_by_container(t, "review"), _td_by_container(t, "scan")
    rc, sc = review["ContainerDefinitions"][0], scan["ContainerDefinitions"][0]
    assert sc["Image"] == rc["Image"], "R2：扫描任务与执行器同一个镜像"
    assert sc["EntryPoint"] == ["/bin/bash", "-p", "/opt/integration/scan-entrypoint.sh"]
    assert scan["RuntimePlatform"]["CpuArchitecture"] == "X86_64"
    senv = {e["Name"]: e["Value"] for e in sc["Environment"]}
    assert senv["KIRO_IMAGE_DIGESTS"] == {e["Name"]: e["Value"] for e in rc["Environment"]}["KIRO_IMAGE_DIGESTS"], \
        "同一份已探测摘要名单"
    assert senv["INSPECTOR_MAX_SCAN_CALLS"] == "3"
    # S2：扫描任务只有扫描员的令牌；没有 Kiro 的密钥
    assert {s["Name"] for s in sc["Secrets"]} == {"YUNXIAO_TOKEN_INSPECTOR"}
    assert {s["Name"] for s in rc["Secrets"]} == {"KIRO_API_KEY", "YUNXIAO_TOKEN"}, "执行器不拿扫描员的令牌"
    renv = {e["Name"] for e in rc["Environment"]}
    assert {"SCAN_CLUSTER", "SCAN_TASK_DEFINITION", "SCAN_CONTAINER_NAME", "SCAN_SUBNETS",
            "SCAN_SECURITY_GROUPS", "SCAN_BUCKET", "SCAN_BUCKET_OWNER", "INSPECTOR", "SECURITY_AGENT"} <= renv


def test_both_task_definitions_run_an_init_process_so_stoptask_sigterm_reaches_the_entrypoint():
    # issue 15：没有 init 时入口 bash 是 PID 1，内核对 PID 1 上没有处理函数的 SIGTERM 一律忽略——StopTask 只能等 30 秒后的
    # SIGKILL，EXIT 陷阱不跑、租约靠到期失效（Task 13 验收 5a 实测）。开关为 0 时执行器同样要开（执行器自己也持租约）。
    for over in ({}, {"inspector": 1}):
        _, t = _scan_templates(**over)
        names = ["review"] + (["scan"] if over else [])
        for name in names:
            c = _td_by_container(t, name)["ContainerDefinitions"][0]
            assert c.get("LinuxParameters", {}).get("InitProcessEnabled") is True, (over, name, c.get("LinuxParameters"))


def test_the_scan_bucket_is_private_tls_only_owner_enforced_and_expires_by_prefix():
    _, t = _scan_templates(inspector=1)
    (b,) = t.find_resources("AWS::S3::Bucket").values()
    p = b["Properties"]
    assert "BucketName" not in p, "S3：桶名由 CloudFormation 生成，不可预测"
    assert p["PublicAccessBlockConfiguration"] == {"BlockPublicAcls": True, "BlockPublicPolicy": True,
                                                   "IgnorePublicAcls": True, "RestrictPublicBuckets": True}
    assert p["OwnershipControls"]["Rules"] == [{"ObjectOwnership": "BucketOwnerEnforced"}]
    assert p["BucketEncryption"]["ServerSideEncryptionConfiguration"][0]["ServerSideEncryptionByDefault"]["SSEAlgorithm"] == "AES256"
    rules = {r["Prefix"]: r["ExpirationInDays"] for r in p["LifecycleConfiguration"]["Rules"]}
    assert rules == {"inspector/": 1, "security/": 7}
    assert b["DeletionPolicy"] == "Retain"
    (pol,) = t.find_resources("AWS::S3::BucketPolicy").values()
    deny = [s for s in pol["Properties"]["PolicyDocument"]["Statement"] if s["Effect"] == "Deny"]
    assert any(s.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport") == "false" for s in deny)


def test_the_scan_task_role_can_only_read_its_prefixes_and_call_scansbom():
    _, t = _scan_templates(inspector=1)
    st = _policy_statements(t, "ScanTaskRole")
    actions = sorted({a for s in st for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"])})
    assert actions == ["dynamodb:GetItem", "dynamodb:UpdateItem", "inspector-scan:ScanSbom",
                       "logs:CreateLogStream", "logs:PutLogEvents", "s3:GetObject"], actions
    s3_res = json.dumps([s["Resource"] for s in st if s["Action"] == "s3:GetObject"])
    assert "inspector/*" in s3_res and "security/*" not in s3_res, s3_res


def test_the_executor_may_only_put_its_prefixes_run_the_scan_task_and_pass_its_two_roles():
    executor, t = _scan_templates(inspector=1)
    st = _policy_statements(t, "TaskRole")
    st = [s for s in st if (s["Action"] if isinstance(s["Action"], str) else s["Action"][0]).split(":")[0] in ("s3", "ecs", "iam")]
    by = {s["Action"] if isinstance(s["Action"], str) else tuple(s["Action"]): s for s in st}
    assert set(by) == {"s3:PutObject", "ecs:RunTask", "iam:PassRole"}, set(by)
    assert "inspector/*" in json.dumps(by["s3:PutObject"]["Resource"])
    assert "ecs:cluster" in json.dumps(by["ecs:RunTask"]["Condition"])
    assert by["iam:PassRole"]["Condition"] == {"StringEquals": {"iam:PassedToService": "ecs-tasks.amazonaws.com"}}
    assert len(by["iam:PassRole"]["Resource"]) == 2


def test_security_agent_on_adds_only_its_own_token_and_prefix():
    _, t = _scan_templates(security_agent=1)
    sc = _td_by_container(t, "scan")["ContainerDefinitions"][0]
    assert {s["Name"] for s in sc["Secrets"]} == {"YUNXIAO_TOKEN_SECURITY"}
    st = _policy_statements(t, "ScanTaskRole")
    assert not any("inspector-scan" in json.dumps(s["Action"]) for s in st), "Inspector 没启用就不给 ScanSbom"
    assert "security/*" in json.dumps([s["Resource"] for s in st if s["Action"] == "s3:GetObject"])


# ── Phase 2b SA：Agent Space、服务角色、扫描任务这一侧的权限（issue 10，spec「Security Agent 评审员 · CDK」「I2」「I7」「S3」）──
SA_ACTIONS = {"securityagent:CreateCodeReview", "securityagent:UpdateCodeReview", "securityagent:ListCodeReviews",
              "securityagent:StartCodeReviewJob", "securityagent:StopCodeReviewJob", "securityagent:BatchGetCodeReviewJobs",
              "securityagent:ListCodeReviewJobsForCodeReview", "securityagent:ListFindings", "securityagent:BatchGetFindings"}


def _actions(st):
    return {a for s in st for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"])}


@pytest.mark.parametrize("over", [{}, {"inspector": 1}])
def test_without_security_agent_there_is_no_security_agent_resource_anywhere(over):
    # I7：开关为 0 时零个 SA 资源（执行器栈也算，不只是调度器栈）、扫描任务没有 SA 的权限与变量
    _, t = _scan_templates(**over)
    types = {r["Type"] for r in t.to_json()["Resources"].values()}
    assert not {ty for ty in types if ty.startswith("AWS::SecurityAgent::")}, types
    assert "securityagent" not in json.dumps(t.to_json()), "开关为 0 时模板里不该出现任何 securityagent 字样"
    if over:
        env = {e["Name"] for e in _td_by_container(t, "scan")["ContainerDefinitions"][0]["Environment"]}
        assert not {n for n in env if n.startswith("SA_") or n == "SECURITY_AGENT_TIMEOUT"}, env


def test_security_agent_on_creates_one_agent_space_with_general_purpose_scanning_only():
    executor, t = _scan_templates(security_agent=1)
    (space,) = t.find_resources("AWS::SecurityAgent::AgentSpace").values()
    p = space["Properties"]
    assert p["Name"] == "codeup-kiro-security"
    assert p["CodeReviewSettings"] == {"ControlsScanning": False, "GeneralPurposeScanning": True}
    assert "KmsKeyId" not in p, "设了 KMS 以后不可更新、换要替换 Space"
    assert "—" not in p["Description"] and "–" not in p["Description"], "资源描述不用破折号（CLAUDE.md）"
    res = json.dumps(p["AwsResources"])
    assert executor.resolve(executor.scan_bucket.bucket_arn) in p["AwsResources"]["S3Buckets"], res
    assert executor.resolve(executor.sa_service_role.role_arn) in p["AwsResources"]["IamRoles"], res
    assert not t.find_resources("AWS::SecurityAgent::Application"), "R13：不建 Application"


def test_the_security_agent_service_role_trusts_only_securityagent_from_this_account_and_its_agent_spaces():
    executor, t = _scan_templates(security_agent=1)
    roles = t.find_resources("AWS::IAM::Role")
    (role,) = [v for k, v in roles.items() if k.startswith("SecurityAgentServiceRole")]
    (stmt,) = role["Properties"]["AssumeRolePolicyDocument"]["Statement"]
    assert stmt["Principal"] == {"Service": "securityagent.amazonaws.com"} and stmt["Action"] == "sts:AssumeRole"
    cond = json.dumps(stmt["Condition"])
    assert '"aws:SourceAccount"' in cond and ":agent-space/*" in cond and '"ArnLike"' in cond, cond


def test_the_security_agent_service_role_can_only_read_the_security_prefix_and_write_its_logs():
    _, t = _scan_templates(security_agent=1, inspector=1)
    st = _policy_statements(t, "SecurityAgentServiceRole")
    assert _actions(st) == {"iam:GetRole", "iam:SimulatePrincipalPolicy", "logs:CreateLogGroup", "logs:CreateLogStream",
                            "logs:PutLogEvents", "s3:GetObject", "s3:ListBucket"}, _actions(st)
    assert not any("secretsmanager" in json.dumps(s) for s in st), \
        "不给 secretsmanager：控制台 base policy 的 secret:<Space 名>* 会覆盖 codeup-kiro/ 下的令牌"
    (get,) = [s for s in st if s["Action"] == "s3:GetObject"]
    assert "security/*" in json.dumps(get["Resource"]) and "inspector/" not in json.dumps(get["Resource"]), get
    (lst,) = [s for s in st if s["Action"] == "s3:ListBucket"]
    # 列桶不能限前缀（sandbox，2026-10-08 Task 9）：带 s3:prefix=security/* 条件时 CreateCodeReview 报「Access denied to source code
    # S3 object」；IAM 模拟器里不带前缀的 ListBucket 是 implicitDeny。探测时跑通的服务角色就是不带前缀条件的列桶。读对象仍只限 security/*
    assert lst["Condition"] == {"StringEquals": {"aws:ResourceAccount": {"Ref": "AWS::AccountId"}}}, lst
    for s in st:
        if s["Action"] != "iam:GetRole" and not (isinstance(s["Action"], list) and "iam:GetRole" in s["Action"]):
            assert "aws:ResourceAccount" in json.dumps(s.get("Condition", {})), s
    logs = json.dumps([s["Resource"] for s in st if "logs:" in json.dumps(s["Action"])])
    assert "/aws/securityagent/codeup-kiro-security" in logs, logs


def test_the_scan_task_may_call_exactly_the_whitelisted_security_agent_actions_on_its_own_agent_space():
    executor, t = _scan_templates(security_agent=1)
    st = _policy_statements(t, "ScanTaskRole")
    sa = [s for s in st if "securityagent:" in json.dumps(s["Action"])]
    assert _actions(sa) == SA_ACTIONS, _actions(sa)
    for forbidden in ("StartCodeRemediation", "UpdateFinding", "BatchDeleteCodeReviews", "securityagent:*"):
        assert forbidden not in json.dumps(st), forbidden
    assert all(":agent-space/" in json.dumps(s["Resource"]) for s in sa), sa
    assert "AgentSpace" in json.dumps([s["Resource"] for s in sa]), "资源是本部署的 Agent Space（GetAtt），不是通配"
    (pr,) = [s for s in st if s["Action"] == "iam:PassRole"]
    assert pr["Condition"] == {"StringEquals": {"iam:PassedToService": "securityagent.amazonaws.com"}}
    assert "SecurityAgentServiceRole" in json.dumps(pr["Resource"])
    ddb = [s for s in st if "dynamodb:" in json.dumps(s["Action"]) and "CodeReviewMapping" in json.dumps(s["Resource"])]
    assert _actions(ddb) == {"dynamodb:GetItem", "dynamodb:UpdateItem"}, ddb


def test_the_scan_task_gets_the_agent_space_service_role_mapping_table_and_timeout():
    _, t = _scan_templates(security_agent=1, security_agent_timeout=900)
    env = {e["Name"]: e["Value"] for e in _td_by_container(t, "scan")["ContainerDefinitions"][0]["Environment"]}
    assert "AgentSpace" in json.dumps(env["SA_AGENT_SPACE_ID"]) and "AgentSpaceId" in json.dumps(env["SA_AGENT_SPACE_ID"])
    assert "SecurityAgentServiceRole" in json.dumps(env["SA_SERVICE_ROLE_ARN"])
    assert "CodeReviewMapping" in json.dumps(env["SA_MAPPING_TABLE"])
    assert env["SECURITY_AGENT_TIMEOUT"] == "900"
    _, t2 = _scan_templates(security_agent=1)
    env2 = {e["Name"]: e["Value"] for e in _td_by_container(t2, "scan")["ContainerDefinitions"][0]["Environment"]}
    assert env2["SECURITY_AGENT_TIMEOUT"] == "3600"



# ── Phase 2c：飞书通知（issue 20，spec「组件设计 · 通知 Lambda」、失败矩阵第一行、N-F1）─────────────────────────────────────
def _notify_stacks(**over):
    """三个栈都用同一份配置（StateStack 也拿完整配置：通知 Lambda 在它里面）。"""
    app = cdk.App()
    cfg = _full_cfg(**over)
    state = StateStack(app, "S", cfg=cfg)
    executor = ExecutorStack(app, "E", cfg=cfg, state=state)
    disp = DispatcherStack(app, "D", cfg=cfg, state=state, executor=executor)
    return {k: Template.from_stack(v).to_json() for k, v in (("state", state), ("executor", executor), ("dispatcher", disp))}


def _resources(tpl, typ):
    return {k: v for k, v in tpl.get("Resources", {}).items() if v["Type"] == typ}


@pytest.mark.parametrize("over", [{}, {"inspector": 1, "security_agent": 1}])
def test_with_feishu_notify_off_every_template_is_identical_to_not_configuring_it(over):
    # 失败矩阵第一行：feishu_notify: 0 → 不建 Lambda、不开 Stream，三个栈的模板与不写这个键时逐字节相同
    absent, off = _notify_stacks(**over), _notify_stacks(feishu_notify=0, feishu_domain="lark", **over)
    for name in absent:
        assert json.dumps(off[name], sort_keys=True) == json.dumps(absent[name], sort_keys=True), name
        assert "feishu" not in json.dumps(off[name]).lower(), name
    (lock,) = [t for t in _resources(off["state"], "AWS::DynamoDB::Table").values()
               if t["Properties"].get("TimeToLiveSpecification", {}).get("Enabled")]
    assert "StreamSpecification" not in lock["Properties"]
    assert _resources(off["state"], "AWS::Lambda::Function") == {}


def test_feishu_notify_on_streams_the_lock_table_into_one_notifier_outside_any_vpc():
    t = _notify_stacks(feishu_notify=1)["state"]
    tables = _resources(t, "AWS::DynamoDB::Table")
    (lock,) = [v for v in tables.values() if v["Properties"].get("TimeToLiveSpecification", {}).get("Enabled")]
    (mapping,) = [v for k, v in tables.items() if "Mapping" in k]
    assert lock["Properties"]["StreamSpecification"] == {"StreamViewType": "NEW_AND_OLD_IMAGES"}
    assert "StreamSpecification" not in mapping["Properties"], "只有锁表开 Stream"
    assert lock["DeletionPolicy"] == "Retain", "开 Stream 不改表的删除策略"
    (fn_id, fn), = [(k, v) for k, v in _resources(t, "AWS::Lambda::Function").items() if "NotifierFn" in k]
    assert "VpcConfig" not in fn["Properties"], "通知 Lambda 不进 VPC（P2c-01：与调度器、兜底同）"
    assert fn["Properties"]["Runtime"] == "python3.12" and fn["Properties"]["Handler"] == "handler.handler"
    assert fn["Properties"]["Timeout"] == 300, "一条记录最多三条通知、上游很慢时约 4 分钟"
    (esm,) = _resources(t, "AWS::Lambda::EventSourceMapping").values()
    assert esm["Properties"]["FunctionName"] == {"Ref": fn_id}
    assert "StreamArn" in json.dumps(esm["Properties"]["EventSourceArn"]), esm["Properties"]["EventSourceArn"]


def test_the_event_source_only_passes_posted_with_a_comment_id_and_retries_little():
    (esm,) = _resources(_notify_stacks(feishu_notify=1)["state"], "AWS::Lambda::EventSourceMapping").values()
    p = esm["Properties"]
    patterns = [json.loads(f["Pattern"]) for f in p["FilterCriteria"]["Filters"]]
    assert patterns == [{"dynamodb": {"NewImage": {f"posted_{rid}": {"BOOL": [True]}, f"comment_{rid}": {"S": [{"exists": True}]}}}}
                        for rid in ("kiro", "inspector", "security")], patterns
    assert (p["StartingPosition"], p["BatchSize"], p["MaximumRetryAttempts"], p["MaximumRecordAgeInSeconds"]) == \
        ("TRIM_HORIZON", 1, 2, 3600), p
    assert p.get("BisectBatchOnFunctionError") in (None, False)


def test_the_notifiers_env_has_secret_names_only_and_the_configured_platform():
    t = _notify_stacks(feishu_notify=1, feishu_domain="lark")["state"]
    (fn,) = [v for k, v in _resources(t, "AWS::Lambda::Function").items() if "NotifierFn" in k]
    assert fn["Properties"]["Environment"]["Variables"] == {
        "YUNXIAO_ORG_ID": "o1", "YUNXIAO_TOKEN_ID": "codeup-kiro/yunxiao-token-kiro",
        "FEISHU_APP_SECRET_ID": "codeup-kiro/feishu-app", "FEISHU_DOMAIN": "lark"}


def test_three_notifications_at_their_budget_fit_in_the_notifier_timeout():
    # 终审 M-5：一条记录最多三条通知（三位评审员）。连不上、对方不应答时每条最坏 = 总时限 + 一次 socket 操作 + 两次取密钥（bounded_config 的最坏）；
    # 对方连上之后慢慢回不在时限内（复审 m-1，handler.py 的 _Budget），这里算的不是那种情形。
    # 三条加起来要小于函数超时：函数一超时，ESM 就重放整批，最后按记录年龄（1 小时）无声丢弃——总时限要防的正是这个
    import bounded_config
    root = pathlib.Path(__file__).resolve().parents[1]
    notifier = load_lambda("notifier_for_budget", root / "lambda" / "notifier" / "handler.py")
    (fn,) = [v for k, v in _resources(_notify_stacks(feishu_notify=1)["state"], "AWS::Lambda::Function").items() if "NotifierFn" in k]
    per = notifier.NOTIFY_BUDGET + notifier.HTTP_TIMEOUT + 2 * bounded_config.worst_case_seconds()
    assert 3 * per < fn["Properties"]["Timeout"], (per, fn["Properties"]["Timeout"])


def _role_statements(tpl, role_ref_prefix):
    out = []
    for v in _resources(tpl, "AWS::IAM::Policy").values():
        if any(isinstance(r, dict) and r.get("Ref", "").startswith(role_ref_prefix) for r in v["Properties"].get("Roles", [])):
            out += v["Properties"]["PolicyDocument"]["Statement"]
    return out


def test_only_the_notifier_role_can_read_the_feishu_secret_and_no_task_definition_references_it():
    # N-F1：飞书凭证不进任何任务定义、任务环境或镜像；只有通知 Lambda 的执行角色能读 codeup-kiro/feishu-app（三位评审员都开着）
    stacks = _notify_stacks(feishu_notify=1, inspector=1, security_agent=1)
    holders = set()
    for name, tpl in stacks.items():
        for v in _resources(tpl, "AWS::IAM::Policy").values():
            if "feishu-app" in json.dumps(v["Properties"]["PolicyDocument"]):
                holders |= {(name, r.get("Ref", "")) for r in v["Properties"]["Roles"]}
        for td in _resources(tpl, "AWS::ECS::TaskDefinition").values():
            # 任务里只有开关 FEISHU_NOTIFY（让评审员记下评论 id），没有飞书密钥的名字、ARN 或任何取值
            blob = json.dumps(td)
            assert "feishu-app" not in blob and "FEISHU_APP" not in blob, "任务定义里不得出现飞书凭证或它的名字"
            for c in td["Properties"]["ContainerDefinitions"]:
                assert not [s for s in c.get("Secrets", []) if "FEISHU" in s["Name"].upper()], c.get("Secrets")
    assert len(holders) == 1 and all(n == "state" and "NotifierFn" in r for n, r in holders), holders
    st = _role_statements(stacks["state"], next(r for _, r in holders))
    sm = [s for s in st if "secretsmanager" in json.dumps(s["Action"])]
    assert len(sm) == 1 and sm[0]["Action"] == "secretsmanager:GetSecretValue", sm
    res = json.dumps(sm[0]["Resource"])
    assert "yunxiao-token-kiro-??????" in res and "feishu-app-??????" in res and "inspector" not in res and "security" not in res, res
    acts = {a for s in st for a in ([s["Action"]] if isinstance(s["Action"], str) else s["Action"])}
    assert not {a for a in acts if a in ("dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query",
                                         "dynamodb:Scan", "dynamodb:DeleteItem")}, "通知只读 Stream，不碰表里的数据"
    assert {"dynamodb:GetRecords", "dynamodb:GetShardIterator"} <= acts, acts
    # 两个持有业务库的任务的环境与密钥块里都没有飞书相关的名字（N-F1 的任务这一侧）
    for fn in _resources(stacks["dispatcher"], "AWS::Lambda::Function").values():
        assert "FEISHU" not in json.dumps(fn["Properties"].get("Environment", {})), "调度器 / 兜底不碰飞书"


def _cfn_str(v):
    """Fn::Join 拼成一个字符串，Ref / 导入之类的内部函数记作 <ref>（只看字面部分有没有通配）。"""
    if isinstance(v, str):
        return v
    if isinstance(v, dict) and set(v) == {"Fn::Join"}:
        sep, parts = v["Fn::Join"]
        return sep.join(_cfn_str(p) for p in parts)
    return "<ref>"


def _iam_statements(tpl):
    for k, v in tpl.get("Resources", {}).items():
        p = v.get("Properties", {})
        if v["Type"] in ("AWS::IAM::Policy", "AWS::IAM::ManagedPolicy"):
            docs = [p["PolicyDocument"]]
        elif v["Type"] == "AWS::IAM::Role":
            docs = [d["PolicyDocument"] for d in p.get("Policies", [])]
        else:
            continue
        for d in docs:
            for s in d["Statement"]:
                yield k, s


@pytest.mark.parametrize("over", [{}, {"feishu_notify": 1, "inspector": 1, "security_agent": 1, "egress_lockdown": 1}],
                         ids=["default", "all-on"])
def test_every_secrets_manager_grant_names_exactly_one_secret(over):
    # 终审 M-7：上一条只认字面 `feishu-app`，以后有人给任务角色加一条 `secret:codeup-kiro/*`（或 Resource "*"）它也会通过。这里换成形状：
    # 三个栈里凡是能落到 secretsmanager 上的授权（含 `*`、`secretsmanager:*` 这类通配动作），每个资源都必须是 `codeup-kiro/<名字>-??????`——
    # 名字里没有 `*` / `?`，只有末尾那六个 `?`（按名导入的密钥只有 partial ARN，见 dispatcher_stack.py）
    one = re.compile(r"arn:(?:<ref>|aws[a-z-]*):secretsmanager:(?:<ref>|[a-z0-9-]+):(?:<ref>|[0-9]{12})"
                     r":secret:codeup-kiro/[A-Za-z0-9/_+=.@-]+-\?{6}")
    seen = 0
    for name, tpl in _notify_stacks(**over).items():
        for k, s in _iam_statements(tpl):
            assert "NotAction" not in s and "NotResource" not in s, (name, k, s)
            acts = s["Action"] if isinstance(s["Action"], list) else [s["Action"]]
            if not any(fnmatch.fnmatchcase("secretsmanager:getsecretvalue", a.lower()) for a in acts):
                continue
            seen += 1
            for r in (s["Resource"] if isinstance(s["Resource"], list) else [s["Resource"]]):
                assert one.fullmatch(_cfn_str(r)), (name, k, _cfn_str(r))
        # 托管策略只有 Lambda 的基本执行角色（SecretsManagerReadWrite 之类整账号的读权限不得挂上来）
        for k, v in tpl.get("Resources", {}).items():
            for arn in v.get("Properties", {}).get("ManagedPolicyArns", []):
                assert _cfn_str(arn) == "arn:<ref>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole", (name, k, _cfn_str(arn))
    assert seen >= 3, "（准备）至少看到执行角色、调度器与兜底的那几条密钥授权"


@pytest.mark.parametrize("on", [0, 1])
def test_feishu_notify_reaches_both_task_containers_only_when_on(on):
    _, t = _scan_templates(inspector=1, feishu_notify=on)
    for name in ("review", "scan"):
        env = {e["Name"]: e["Value"] for e in _td_by_container(t, name)["ContainerDefinitions"][0]["Environment"]}
        assert env.get("FEISHU_NOTIFY") == ("1" if on else None), (name, env.get("FEISHU_NOTIFY"))



# ── Phase 2c：手册里飞书通知的那几处与代码对拍（issue 20 第 7 条；改了代码没改手册，这几条先红）────────────────────────────
def _guide_subsection(heading):
    lines = _guide_text().splitlines()
    start = next((i for i, ln in enumerate(lines) if ln.startswith(f"### {heading}")), None)
    assert start is not None, f"找不到小节标题：### {heading}"
    end = next((i for i, ln in enumerate(lines[start + 1:], start + 1) if ln.startswith(("## ", "### "))), len(lines))
    return "\n".join(lines[start:end])


def test_the_guide_documents_the_feishu_notifier_the_way_the_code_behaves():
    import stacks.notifier as stack_notifier
    root = pathlib.Path(__file__).resolve().parents[1]
    notifier = load_lambda("notifier_for_guide", root / "lambda" / "notifier" / "handler.py")
    src = (root / "lambda" / "notifier" / "handler.py").read_text()
    sec = _guide_subsection("6.7")
    for text in notifier.MESSAGES.values():
        assert f"`{text}<链接>`" in sec, text
    assert stack_notifier.FEISHU_SECRET_NAME == "codeup-kiro/feishu-app" and "`codeup-kiro/feishu-app`" in sec
    for needle in ("im:message:send_as_bot", "可用范围", "发布版本", "feishu_notify: 1", "feishu_domain: lark", "mail.teambition.com",
                   "主邮箱", "feishu_notify: 0", "NotifierFunctionName"):
        assert needle in sec, needle
    rows = "\n".join(ln for ln in _guide_section_lines("8.") if ln.startswith("|"))
    reasons = set(re.findall(r'return "skipped:([a-z-]+)"', src)) | {"bad-lock-key"}
    assert reasons == {"no-email", "bad-email", "bad-url", "bad-lock-key"}, reasons
    for r in reasons:
        assert f"`{r}`" in rows, r
    steps = set(re.findall(r'NotifyError\("([a-z]+)"', src)) - {"config"} | {"internal"}
    assert steps == {"secret", "codeup", "token", "send", "internal"}, steps
    for st in steps:
        assert f"`step={st}`" in rows, st
    for code in (230013, 230038, 230029, 230053, 10014):
        assert f"feishu-{code}" in rows, code
    # sandbox 2026-10-10（Phase 2c Task 11 Step 6.5）实测：app_secret 写错时 tenant_access_token/internal 返回的是 10014，不是飞书通用错误码表里
    # 「App Secret 错误」的 10015。手册得照实测说「写错 app_secret 就是 10014」，不能按通用表把 10014 说成「应用被停用」、把人引去查错地方
    assert re.search(r"`feishu-10014`[^；]*`app_secret`[^；]*实测", rows), "§8 的 step=token 那一段没照实测写：app_secret 写错时是 feishu-10014"
    # 终审 M-5：每条通知的总时限用完时是 code=deadline（任何一步都可能）；手册写明时限多长，以及仍然不留日志的那一条路（Stream 里积压超过 1 小时）
    assert '"deadline"' in src, "handler 里没有 deadline 这个错误码"
    assert "`code=deadline`" in rows and re.search(rf"(?<![0-9]){notifier.NOTIFY_BUDGET} 秒的总时限", rows), \
        "§8 没写 code=deadline 与每条通知的总时限"
    # 小时数取自事件源的 MaximumRecordAgeInSeconds、按整数匹配（复审 m-2：「11 小时」不能蒙混过去）
    (esm,) = _resources(_notify_stacks(feishu_notify=1)["state"], "AWS::Lambda::EventSourceMapping").values()
    hours = esm["Properties"]["MaximumRecordAgeInSeconds"] // 3600
    assert "IteratorAge" in rows and re.search(rf"排队超过 (?<![0-9]){hours} 小时", rows), "§8 没写积压超过记录年龄上限被事件源丢掉、只有 IteratorAge 看得到"
    # 会用到总时限的步骤 = 经 _call 发请求的那几步（复审 m-3：取密钥、读配置不查时限，手册不能说「任何一步」）
    timed = sorted(set(re.findall(r'_call\("([a-z]+)"', src)))
    assert timed == ["codeup", "send", "token"], timed
    assert "`code=deadline`（" + " / ".join(f"`{x}`" for x in ("codeup", "token", "send")) + " 三步都可能）" in rows, "§8 的 code=deadline 没点名哪几步"
    assert "第 8 节「result=skipped」与「result=failed」那两行" in sec
    # §1.3 的数据流表与 §3 的密钥表各有一行
    sec13 = _guide_subsection("1.3")
    assert "`feishu_notify: 1`" in sec13 and "author.email" in sec13 and "open.feishu.cn" in sec13
    assert "| `codeup-kiro/feishu-app` |" in "\n".join(_guide_section_lines("3."))



# ── Phase 2c 阶段二：可选的 NAT 网关形态（issue 19「新增：可选的 NAT 网关形态」，spec G3）──────────────────────────────────────
def _app_templates(**over):
    """走 app.py 的 build_stacks（调度器的子网、公网 IP 取自 ExecutorStack 的真实资源）。"""
    state, executor, disp = _app_mod.build_stacks(cdk.App(), _full_cfg(**over))
    return {"state": Template.from_stack(state).to_json(), "executor": Template.from_stack(executor).to_json(),
            "dispatcher": Template.from_stack(disp).to_json()}


def _subnets(tpl):
    return {k: v["Properties"] for k, v in _resources(tpl, "AWS::EC2::Subnet").items()}


@pytest.mark.parametrize("over", [{}, {"inspector": 1, "security_agent": 1}])
def test_the_public_egress_mode_is_byte_identical_to_not_configuring_it(over):
    a, b = _app_templates(**over), _app_templates(egress_mode="public", **over)
    for name in a:
        assert json.dumps(a[name], sort_keys=True) == json.dumps(b[name], sort_keys=True), name
    assert _resources(a["executor"], "AWS::EC2::NatGateway") == {}


def test_nat_mode_adds_two_private_subnets_and_one_nat_gateway_without_touching_existing_subnets():
    pub, nat = _app_templates(inspector=1), _app_templates(inspector=1, egress_mode="nat")
    ps, ns = _subnets(pub["executor"]), _subnets(nat["executor"])
    assert len(ps) == 4 and len(ns) == 6
    # 新的子网组排在最后：已有的公有、隔离子网逻辑 id 与 CIDR 一个不变（换了就是替换子网，ALB 与 VPC origin 跟着重建）
    for k, v in ps.items():
        assert ns[k]["CidrBlock"] == v["CidrBlock"], k
    private = {k: v for k, v in ns.items() if k not in ps}
    assert all("private" in k for k in private) and all(v["MapPublicIpOnLaunch"] is False for v in private.values()), private
    assert len(_resources(nat["executor"], "AWS::EC2::NatGateway")) == 1, "一个 NAT 网关（约 $32/月）"
    routes = [r["Properties"] for r in _resources(nat["executor"], "AWS::EC2::Route").values() if "NatGatewayId" in r["Properties"]]
    assert len(routes) == 2 and all(r["DestinationCidrBlock"] == "0.0.0.0/0" for r in routes), routes


def _env_of(tpl, container):
    return {e["Name"]: e["Value"] for e in _td_by_container_tpl(tpl, container)["ContainerDefinitions"][0]["Environment"]}


def _td_by_container_tpl(tpl, name):
    hits = [v["Properties"] for v in _resources(tpl, "AWS::ECS::TaskDefinition").values()
            if v["Properties"]["ContainerDefinitions"][0]["Name"] == name]
    assert len(hits) == 1, (name, len(hits))
    return hits[0]


def test_nat_mode_launches_both_tasks_into_the_private_subnets_without_a_public_ip():
    t = _app_templates(inspector=1, egress_mode="nat")
    private = {k for k in _subnets(t["executor"]) if "private" in k}
    env = _env_of(t["executor"], "review")
    assert env["SCAN_ASSIGN_PUBLIC_IP"] == "DISABLED"
    refs = {r["Ref"] for r in env["SCAN_SUBNETS"]["Fn::Join"][1] if isinstance(r, dict)}
    assert refs == private, refs
    (disp,) = [v for k, v in _resources(t["dispatcher"], "AWS::Lambda::Function").items() if "DispatcherFn" in k]
    denv = disp["Properties"]["Environment"]["Variables"]
    assert denv["ASSIGN_PUBLIC_IP"] == "DISABLED"
    # 调度器的子网来自执行器栈的导出（跨栈引用）：私有子网那两个
    assert "privateSubnet" in json.dumps(denv["SUBNET_IDS"]) and "publicSubnet" not in json.dumps(denv["SUBNET_IDS"]), denv["SUBNET_IDS"]


def test_public_mode_keeps_the_public_subnets_and_writes_no_assign_public_ip_variable():
    t = _app_templates(inspector=1)
    env = _env_of(t["executor"], "review")
    assert "SCAN_ASSIGN_PUBLIC_IP" not in env and "publicSubnet" in json.dumps(env["SCAN_SUBNETS"])
    (disp,) = [v for k, v in _resources(t["dispatcher"], "AWS::Lambda::Function").items() if "DispatcherFn" in k]
    assert "ASSIGN_PUBLIC_IP" not in disp["Properties"]["Environment"]["Variables"]


def test_nat_mode_keeps_the_webhook_alb_in_the_isolated_subnets():
    t = _app_templates(egress_mode="nat")
    (alb,) = _resources(t["dispatcher"], "AWS::ElasticLoadBalancingV2::LoadBalancer").values()
    assert "isolatedSubnet" in json.dumps(alb["Properties"]["Subnets"]) and "private" not in json.dumps(alb["Properties"]["Subnets"])



def _exports(tpl):
    return {v["Export"]["Name"] for v in tpl.get("Outputs", {}).values() if "Export" in v}


def _imports(tpl):
    return set(re.findall(r'"Fn::ImportValue": "([^"]+)"', json.dumps(tpl)))


def test_switching_between_public_and_nat_never_strands_a_cross_stack_import():
    # 调度器的子网 id 经跨栈导出从执行器栈来；CloudFormation 不许删一个仍被导入的导出（using-cfn-stack-exports）。
    # public → nat：执行器先加私有子网与它们的导出，调度器再改导入——一次 cdk deploy --all 即可。
    # nat → public：执行器去掉私有子网时，调度器还导入着它们——所以要两步（setup-guide 第 6.8 节）：先只部署调度器栈（改为导入公有子网），
    # 再部署全部。第一步要求 nat 形态的执行器栈**仍导出**公有子网的 id，且名字与 public 形态下自动生成的一致。
    pub, nat = _app_templates(), _app_templates(egress_mode="nat")
    # 隔离子网（webhook 的 ALB）两种形态都导入、都在，不受影响；只看任务子网
    pub_subnet_imports = {n for n in _imports(pub["dispatcher"]) if "publicSubnet" in n or "privateSubnet" in n}
    nat_subnet_imports = {n for n in _imports(nat["dispatcher"]) if "publicSubnet" in n or "privateSubnet" in n}
    assert len(pub_subnet_imports) == 2 and all("publicSubnet" in n for n in pub_subnet_imports), pub_subnet_imports
    assert len(nat_subnet_imports) == 2 and all("privateSubnet" in n for n in nat_subnet_imports), nat_subnet_imports
    assert pub_subnet_imports <= _exports(nat["executor"]), "nat 形态的执行器栈要继续导出公有子网的 id（改回 public 的第一步要导入它们）"
    assert nat_subnet_imports <= _exports(nat["executor"])


# ── Phase 2c 阶段二：出站限制（issue 19 做法 A：网关终端节点 + 策略、安全组只放 443、Route 53 Resolver DNS Firewall）──────────────────
@pytest.mark.parametrize("over", [{}, {"inspector": 1, "security_agent": 1}, {"egress_mode": "nat"}])
def test_with_egress_lockdown_off_every_template_is_identical_to_not_configuring_it(over):
    a, b = _app_templates(**over), _app_templates(egress_lockdown=0, egress_dns_action="alert", **over)
    for name in a:
        assert json.dumps(a[name], sort_keys=True) == json.dumps(b[name], sort_keys=True), name
    t = a["executor"]
    for typ in ("AWS::EC2::VPCEndpoint", "AWS::Route53Resolver::FirewallRuleGroup", "AWS::Route53Resolver::ResolverQueryLoggingConfig"):
        assert _resources(t, typ) == {}, typ


def _task_sg(tpl):
    (sg,) = [v["Properties"] for k, v in _resources(tpl, "AWS::EC2::SecurityGroup").items() if k.startswith("TaskSg")]
    return sg


@pytest.mark.parametrize("mode", ["public", "nat"])
def test_lockdown_lets_the_task_security_group_out_only_on_tcp_443_without_replacing_it(mode):
    on, off = _app_templates(inspector=1, egress_lockdown=1, egress_mode=mode), _app_templates(inspector=1, egress_mode=mode)
    assert _task_sg(on["executor"])["SecurityGroupEgress"] == [
        {"CidrIp": "0.0.0.0/0", "Description": "HTTPS only (codeup-kiro egress lockdown)", "FromPort": 443, "IpProtocol": "tcp", "ToPort": 443}]
    # 描述不变：EC2 安全组的描述一改就是替换（新 id），调度器经跨栈导入的安全组 id 也跟着变——卡在导出上
    assert _task_sg(on["executor"])["GroupDescription"] == _task_sg(off["executor"])["GroupDescription"]
    assert not [r for r in _resources(on["executor"], "AWS::EC2::SecurityGroupIngress").values()
                if "TaskSg" in json.dumps(r["Properties"].get("GroupId"))], "任务安全组仍然没有入站规则"


def _endpoints(tpl):
    out = {}
    for v in _resources(tpl, "AWS::EC2::VPCEndpoint").values():
        svc = json.dumps(v["Properties"]["ServiceName"])
        out["s3" if ".s3" in svc else "dynamodb" if ".dynamodb" in svc else svc] = v["Properties"]
    return out


@pytest.mark.parametrize("mode,group", [("public", "publicSubnet"), ("nat", "privateSubnet")])
def test_lockdown_adds_s3_and_dynamodb_gateway_endpoints_on_the_task_subnets_route_tables(mode, group):
    eps = _endpoints(_app_templates(inspector=1, security_agent=1, egress_lockdown=1, egress_mode=mode)["executor"])
    assert set(eps) == {"s3", "dynamodb"}, eps.keys()
    for name, ep in eps.items():
        assert ep["VpcEndpointType"] == "Gateway", name
        rts = json.dumps(ep["RouteTableIds"])
        assert rts.count(group) == 2 and "isolatedSubnet" not in rts, (name, rts)


def _statements(ep):
    return ep["PolicyDocument"]["Statement"]


def test_the_s3_endpoint_policy_allows_only_this_deployments_bucket_and_the_ecr_layer_bucket():
    executor = _app_mod.build_stacks(cdk.App(), _full_cfg(inspector=1, security_agent=1, egress_lockdown=1))[1]
    eps = _endpoints(Template.from_stack(executor).to_json())
    st = _statements(eps["s3"])
    assert len(st) == 2, st
    (layer,) = [x for x in st if "starport-layer-bucket" in json.dumps(x["Resource"])]
    assert layer["Action"] == "s3:GetObject" and layer["Principal"] == {"AWS": "*"} and "Condition" not in layer
    assert "prod-" in json.dumps(layer["Resource"]) and "-starport-layer-bucket/*" in json.dumps(layer["Resource"])
    (own,) = [x for x in st if x is not layer]
    assert sorted(own["Action"]) == ["s3:GetObject", "s3:PutObject"]
    assert "ScanInputs" in json.dumps(own["Resource"]) and json.dumps(own["Resource"]).endswith('"/*"]]}'), own["Resource"]
    assert own["Condition"] == {"StringEquals": {"aws:PrincipalAccount": {"Ref": "AWS::AccountId"}}}
    assert '"s3:*"' not in json.dumps(st) and '"Resource": "*"' not in json.dumps(st)


def test_without_scanners_the_s3_endpoint_only_allows_the_ecr_layer_bucket():
    st = _statements(_endpoints(_app_templates(egress_lockdown=1)["executor"])["s3"])
    assert len(st) == 1 and "starport-layer-bucket" in json.dumps(st[0]["Resource"]), st


def test_the_dynamodb_endpoint_policy_allows_only_get_and_update_on_the_two_tables():
    st = _statements(_endpoints(_app_templates(security_agent=1, egress_lockdown=1)["executor"])["dynamodb"])
    (x,) = st
    assert sorted(x["Action"]) == ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    res = json.dumps(x["Resource"])
    assert "ReviewLock" in res and "CodeReviewMapping" in res, res
    assert x["Condition"] == {"StringEquals": {"aws:PrincipalAccount": {"Ref": "AWS::AccountId"}}}


def test_without_security_agent_the_dynamodb_endpoint_names_only_the_lock_table_and_adds_no_new_export():
    # 映射表只有 SA 用；不开 SA 时把它写进终端节点策略，会给 StateStack 多一个只有这里导入的导出——关掉 egress_lockdown 时
    # StateStack 先部署、删这个导出，执行器栈还导入着它，部署卡住（CloudFormation 不许删仍被导入的导出）
    on, off = _app_templates(inspector=1, egress_lockdown=1), _app_templates(inspector=1)
    (x,) = _statements(_endpoints(on["executor"])["dynamodb"])
    assert "ReviewLock" in json.dumps(x["Resource"]) and "CodeReviewMapping" not in json.dumps(x["Resource"]), x["Resource"]
    assert _exports(on["state"]) == _exports(off["state"]), "开出站限制不给 StateStack 增加导出"



def test_turning_security_agent_off_never_strands_a_state_export_the_executor_imports():
    # Codex 第 1 轮 R3：SA 开着时执行器经跨栈导入映射表的 ARN（授权）与名字（SA_MAPPING_TABLE）；关掉时 StateStack 先部署——这两个导出若随之消失，
    # 执行器栈的旧模板还导入着，CloudFormation 拒绝删除仍被导入的导出、部署卡住。StateStack 一直显式导出它们（与 NAT 回退的 export_value 同一手法）
    on, off = _app_templates(inspector=1, security_agent=1), _app_templates(inspector=1)
    imported = {n for n in _imports(on["executor"]) if n.startswith("CodeupKiroState:")}
    assert any("CodeReviewMapping" in n for n in imported), ("前提：SA 开着时执行器从 State 导入映射表", sorted(imported))
    assert imported <= _exports(off["state"]), ("关掉 SA 后 State 仍导出执行器旧模板导入的值", sorted(imported - _exports(off["state"])))
    assert not [n for n in _imports(off["executor"]) if "CodeReviewMapping" in n], "关掉 SA 后执行器不再导入映射表"

def _dns(tpl):
    lists = {k: v["Properties"] for k, v in _resources(tpl, "AWS::Route53Resolver::FirewallDomainList").items()}
    (group,) = [v["Properties"] for v in _resources(tpl, "AWS::Route53Resolver::FirewallRuleGroup").values()]
    return lists, group


@pytest.mark.parametrize("action,want", [("alert", "ALERT"), ("block", "BLOCK")])
def test_dns_firewall_allows_the_list_then_alerts_or_blocks_everything_else(action, want):
    t = _app_templates(inspector=1, security_agent=1, egress_lockdown=1, egress_dns_action=action)["executor"]
    lists, group = _dns(t)
    rules = sorted(group["FirewallRules"], key=lambda r: r["Priority"])
    assert [(r["Priority"], r["Action"]) for r in rules] == [(100, "ALLOW"), (200, want)], rules
    assert rules[0]["FirewallDomainRedirectionAction"] == "TRUST_REDIRECTION_DOMAIN", "CNAME 链上的名字不必逐个列"
    assert rules[1].get("BlockResponse") == ("NXDOMAIN" if want == "BLOCK" else None), rules[1]
    catch_all = [v for v in lists.values() if v["Domains"] == ["*"]]
    assert len(catch_all) == 1, lists
    (assoc,) = [v["Properties"] for v in _resources(t, "AWS::Route53Resolver::FirewallRuleGroupAssociation").values()]
    assert 100 <= assoc["Priority"] <= 9900 and "Vpc" in json.dumps(assoc["VpcId"])


def _allowed(tpl):
    lists, _ = _dns(tpl)
    (allowed,) = [v["Domains"] for v in lists.values() if v["Domains"] != ["*"]]
    return json.dumps(allowed)


def test_the_allow_list_names_what_the_tasks_reach_and_no_wide_wildcards():
    t = _app_templates(inspector=1, security_agent=1, egress_lockdown=1)["executor"]
    allowed = _allowed(t)
    for need in ("codeup.aliyun.com", "openapi-rdc.aliyuncs.com", "secretsmanager.", "logs.", "ecs.", "dynamodb.", "api.ecr.",
                 ".dkr.ecr.", ".ddb.", "inspector-scan.", "securityagent."):
        assert need in allowed, need
    for wide in ('"*.amazonaws.com"', '"amazonaws.com"', '"*.aliyuncs.com"', '"*"'):
        assert wide not in allowed, wide
    # N-F1 的旁证：飞书只在通知 Lambda（不在 VPC 里）发，任务那一侧的名单里不该有它
    assert "feishu" not in allowed and "larksuite" not in allowed


def test_scanner_endpoints_are_only_allowed_when_that_scanner_is_on():
    allowed = _allowed(_app_templates(egress_lockdown=1)["executor"])
    assert "inspector-scan." not in allowed and "securityagent." not in allowed


def test_dns_queries_are_logged_to_a_log_group_in_this_stack():
    t = _app_templates(egress_lockdown=1)["executor"]
    (qlc,) = [v["Properties"] for v in _resources(t, "AWS::Route53Resolver::ResolverQueryLoggingConfig").values()]
    assert "DnsQueryLogs" in json.dumps(qlc["DestinationArn"]), qlc
    (qla,) = [v["Properties"] for v in _resources(t, "AWS::Route53Resolver::ResolverQueryLoggingConfigAssociation").values()]
    assert "Vpc" in json.dumps(qla["ResourceId"])
    (lg,) = [v for k, v in _resources(t, "AWS::Logs::LogGroup").items() if "DnsQueryLogs" in k]
    assert lg["Properties"]["RetentionInDays"] == 30
    # 投递服务的资源策略：条件按 CloudWatch Logs「V1 权限」的写法（aws:SourceArn 是 logs 的 ARN）
    (rp,) = [json.loads(json.dumps(v["Properties"])) for v in _resources(t, "AWS::Logs::ResourcePolicy").values()]
    doc = json.dumps(rp)
    assert "delivery.logs.amazonaws.com" in doc and ":logs:" in doc and "route53resolver" not in doc, doc


def test_egress_resource_names_and_descriptions_have_no_dashes_of_the_long_kind():
    t = _app_templates(inspector=1, egress_lockdown=1)["executor"]
    blob = json.dumps({k: v for k, v in t["Resources"].items() if v["Type"].startswith(("AWS::Route53Resolver::", "AWS::EC2::"))},
                      ensure_ascii=False)
    assert "—" not in blob and "–" not in blob



# ── Phase 2c 阶段二：手册第 6.8 节与代码对拍（issue 19 第 6 条）─────────────────────────────────────────────────────────────
def test_the_guide_documents_the_egress_lockdown_the_way_the_code_builds_it():
    import stacks.egress as egress
    sec = _guide_subsection("6.8")
    for needle in ("egress_lockdown: 1", "egress_dns_action: block", "egress_mode: nat", "starport-layer-bucket", "DnsQueryLogGroup",
                   "aws/stacks/egress.py", "firewall_rule_action", "cdk deploy CodeupKiroDispatcher --exclusively", "*.amazonaws.com",
                   "做法 B", "us-east-1", "Network Firewall", "Block Public Access", "Kiro CLI 换版本后"):
        assert needle in sec, needle
    for host in egress.CODEUP_HOSTS:
        assert f"`{host}`" in sec, host
    assert "api.aws" in sec and "securityagent." in json.dumps(egress.allowed_domains("r", "a", ("security",)))
    # §1.5 写明残余风险、§6.2 写明 NAT 的费用、§8 有一行按名字可引用
    sec15 = _guide_subsection("1.5")
    assert "直接连写死的 IP 的 443 端口" in sec15 and "攻击者自己的凭证" in sec15 and "缺省的 `alert` 只记录、不拦" in sec15, sec15
    assert "egress_mode: nat" in _guide_subsection("6.2")
    assert "第 8 节「DNS Firewall 拦下了」那一行" in sec
    firsts = [ln.split(" | ")[0].replace("**", "").replace("`", "") for ln in _guide_section_lines("8.") if ln.startswith("|")]
    assert len([f for f in firsts if "DNS Firewall 拦下了" in f]) == 1


# sandbox 2026-10-10（Phase 2c Task 17）：ALERT 一轮里名单外的只有 Kiro CLI 的遥测与更新检查这四个，BLOCK 下评审照常——刻意不进名单（少放一个出口）。
# 手册要点名它们，免得运维照第 6.8 节第 3 步把它们当「评审需要的」加回去
KIRO_UNNEEDED_HOSTS = ("cognito-identity.us-east-1.amazonaws.com", "client-telemetry.us-east-1.amazonaws.com",
                       "prod.us-east-1.telemetry-v2.kiro.dev", "desktop-release.q.us-east-1.amazonaws.com")


def test_the_kiro_telemetry_and_update_hosts_stay_off_the_list_and_the_guide_says_why():
    import stacks.egress as egress
    listed = egress.allowed_domains("us-east-1", "123456789012", ("inspector", "security"))
    sec = _guide_subsection("6.8")
    for host in KIRO_UNNEEDED_HOSTS:
        assert host not in listed, host
        assert f"`{host}`" in sec, host
    assert "评审不需要" in sec and "BLOCK 下照常评审" in sec


# ── 每个开关的「功能区别 / 配置区别」（Kent 2026-10-10）：config.example.yaml 每个开关键之上一个注释块，手册 §4.3「开关一览」表每个开关一行 ──
# 开关 = 0/1 与枚举取值的键（inline_profile 之类的评审行为变量不是开关）。以后新增 0/1 开关、忘了写说明，守卫那一句先红
SWITCHES = ("inline_comment", "review_command", "inspector", "security_agent", "feishu_notify", "feishu_domain",
            "egress_lockdown", "egress_dns_action", "egress_mode")
_EXAMPLE_KEY_LINE = re.compile(r"^#?\s*([a-z_]+):(\s|$)")
_SWITCH_TABLE_HEAD = "| 键 | 取值（缺省） | 功能区别 | 配置区别 | 详见 |"


def _example_switch_block(key):
    """config.example.yaml 里这个键那一行（`key: v` 或注释掉的 `# key: v`）正上方连续的注释行；碰到空行或别的键那一行就停。"""
    lines = (pathlib.Path(__file__).resolve().parents[1] / "config.example.yaml").read_text().splitlines()
    at = [i for i, ln in enumerate(lines) if (m := _EXAMPLE_KEY_LINE.match(ln)) and m.group(1) == key]
    assert len(at) == 1, f"config.example.yaml 里 {key} 那一行找不到（或不止一行）：{at}"
    block, i = [], at[0] - 1
    while i >= 0 and lines[i].startswith("#") and not _EXAMPLE_KEY_LINE.match(lines[i]):
        block.insert(0, lines[i])
        i -= 1
    return block


def _switch_table_rows():
    sec = _guide_subsection("4.3").splitlines()
    assert _SWITCH_TABLE_HEAD in sec, "§4.3 没有「开关一览」表（表头不是 " + _SWITCH_TABLE_HEAD + "）"
    i = sec.index(_SWITCH_TABLE_HEAD) + 2   # 跳过表头分隔行
    rows = []
    while i < len(sec) and sec[i].startswith("|"):
        rows.append([c.strip() for c in sec[i].strip()[1:-1].split("|")])
        i += 1
    return rows


def test_every_switch_says_what_each_value_does_and_what_it_needs():
    import config
    assert set(config.TOGGLES) | {"feishu_notify", "feishu_domain", "egress_lockdown", "egress_dns_action", "egress_mode"} <= set(SWITCHES), \
        "有开关没进 SWITCHES（没写功能区别 / 配置区别）"
    rows = _switch_table_rows()
    assert sorted(r[0] for r in rows) == sorted(f"`{k}`" for k in SWITCHES), [r[0] for r in rows]
    for key in SWITCHES:
        block = _example_switch_block(key)
        assert block and block[0].startswith(f"# {key}（"), f"config.example.yaml 里 {key} 之上没有「# {key}（取值，缺省）」开头的注释块：{block}"
        for label in ("功能区别", "配置区别"):
            hit = [ln for ln in block if ln.startswith(f"#   {label}：")]
            assert len(hit) == 1 and hit[0][len(f"#   {label}："):].strip(), f"config.example.yaml 里 {key} 的注释块缺「{label}」：{block}"
        row = [r for r in rows if r[0] == f"`{key}`"]
        assert len(row) == 1 and len(row[0]) == 5, f"§4.3 开关一览里 {key} 那一行找不到、不止一行或不是五格：{row}"
        assert all(row[0][1:]), f"§4.3 开关一览里 {key} 那一行有空格子：{row[0]}"


# ── Phase 2c minors：security.sh 里两处残余窗口的注释与代码对拍（终审 M-2 / M-3；改了代码没改注释，这两条先红）────────────────────────
def _security_sh():
    return (pathlib.Path(__file__).resolve().parents[1] / "reviewers" / "security.sh").read_text()


def test_the_sa_exit_trap_says_what_bounds_its_wait_on_an_in_flight_start():
    # 终审 M-2：EXIT 陷阱 wait 在途的 Start 只受 aws CLI 自己的超时约束（sa_call 没改 CLI 的连接 / 读超时 → 缺省各 60 秒），比任务的
    # stopTimeout（扫描容器没设 → Fargate 缺省 30 秒）长：Start 卡住时 SIGKILL 先到、租约没释放，由两个租约的 TTL 兜底。注释里的数与代码一致
    root = pathlib.Path(__file__).resolve().parents[1]
    src = _security_sh()
    l7 = re.search(r"LEASE_TTL=(\d+)", (root / "reviewers" / "lib" / "reviewer.sh").read_text()).group(1)
    repo = re.search(r"^sa_repo_lease\(\) \{.*?LEASE_TTL=(\d+)", src, re.S | re.M).group(1)
    _, t = _scan_templates(inspector=1, security_agent=1)
    scan = _td_by_container(t, "scan")["ContainerDefinitions"][0]
    assert "StopTimeout" not in scan, "扫描容器设了 stopTimeout：_sa_exit 注释里的 30 秒要跟着改"
    call = re.search(r"^sa_call\(\) \{.*?^\}", src, re.S | re.M).group(0)
    assert "--cli-connect-timeout" not in call and "--cli-read-timeout" not in call, "sa_call 改了 CLI 的超时：注释里的 60 秒要跟着改"
    trap = re.search(r"^_sa_exit\(\) \{.*?^\}", src, re.S | re.M).group(0)
    for needle in ("各 60 秒", "stopTimeout 30 秒", f"L7 租约 {l7} 秒", f"仓库租约 {repo} 秒", "终审 M-2"):
        assert needle in trap, needle


def test_the_start_call_names_its_one_residual_term_window():
    # 终审 M-3：TERM 落在 `sa_call_once … &` 与 `SA_START_PID=$!` 之间时，陷阱还不知道这个子进程。注释说两句之间只有这一条赋值——
    # 再插任何命令，这句话就不对了
    lines = _security_sh().splitlines()
    i = next(n for n, ln in enumerate(lines) if ln.rstrip().endswith('> "$WORK/sa-start.json" &'))
    assert lines[i + 1].strip() == "SA_START_PID=$!", lines[i + 1]
    j = next(n for n in range(i, -1, -1) if lines[n].lstrip().startswith("sa_call_once start-code-review-job"))
    comment = "\n".join(ln for ln in lines[max(j - 8, 0):j] if ln.lstrip().startswith("#"))
    for needle in ("残余", "SA_START_PID=$!", "终审 M-3"):
        assert needle in comment, (needle, comment)


# ── Phase 2c minors：手册与代码对拍（终审 M-9 / M-6 / M-4；改了代码没改手册，这几条先红）────────────────────────────────────────────
def _guide_rows(heading):
    return "\n".join(ln for ln in _guide_section_lines(heading) if ln.startswith("|"))


def test_the_guide_says_how_long_a_feishu_secret_change_takes_to_show():
    # 终审 M-9 + 执行时记的那条：改了 codeup-kiro/feishu-app 之后，热的执行环境最多 5 分钟仍用缓存的旧值（secret_fetch 的缓存）；取令牌失败
    # 不缓存令牌，所以写错的 app_secret 改对后最多再报这 5 分钟；已经取到的租户令牌最多缓存约 110 分钟（有效期 2 小时减重取余量），所以把
    # 有效的 app_secret 换掉（轮换或改错）之后，这段时间里照样发得出去、不会马上报错
    import secret_fetch
    root = pathlib.Path(__file__).resolve().parents[1]
    notifier = load_lambda("notifier_for_cache_guide", root / "lambda" / "notifier" / "handler.py")
    rows = _guide_rows("8.")
    seg = rows[rows.index("`step=token`"):rows.index("`step=codeup`")]
    # 数字前面不能紧挨着数字：「10 分钟」不能靠「110 分钟」蒙混过去（变异实测过）
    assert re.search(rf"(?<![0-9]){secret_fetch.CACHE_TTL_SECONDS // 60} 分钟", seg), seg
    assert re.search(rf"约 {(7200 - notifier.TOKEN_REFRESH_MARGIN) // 60} 分钟", seg), seg
    assert "取令牌失败不缓存令牌" in seg and "（轮换或改错）之后这段时间里照样发得出去" in seg, seg


def test_the_guide_says_to_wait_for_running_tasks_before_switching_egress_mode():
    # 终审 M-6：切 egress_mode（尤其 nat → public 第 2 步删掉私有子网与 NAT 网关）时，任务的网卡还在那些子网里，CloudFormation 的清理会失败、
    # 或者评审中途断网（Security Agent 一次评审可能超过一小时）。sandbox 每一步之前都核对过 RUNNING 为空，手册要叫运维也这么做
    sec = _guide_subsection("6.8")
    row = next(ln for ln in _guide_section_lines("4.") if ln.startswith("| `egress_mode` |"))
    for name, text in (("§6.8", sec), ("§4.3 egress_mode 那一行", row)):
        # 带方向：「之前**不必**等…」这种改写不能蒙混过关
        assert "之前等所有任务结束" in text, name
    assert "list-tasks" in sec and "--desired-status RUNNING" in sec and "第 2 步之前" in sec


def test_the_guide_says_a_compromised_task_can_still_trigger_fixed_text_messages():
    # 终审 M-4：两个任务角色对锁表都有 UpdateItem、没有按键的条件（dynamodb:LeadingKeys）——被攻破的任务能在任意一条锁记录上写
    # posted_<评审员> + 一个形状合法的 comment_<评审员>（不带条件的 UpdateItem 还能新建记录），通知 Lambda 就给那个 MR 的作者发一条固定文案。
    # 不能钓鱼（N-F3），但能骚扰；手册要说出来。以后给任务角色加上按键的条件，这条先红、手册跟着改
    stacks = _notify_stacks(feishu_notify=1, inspector=1)
    for prefix in ("TaskRole", "ScanTaskRole"):
        st = [s for s in _role_statements(stacks["executor"], prefix)
              if "dynamodb:UpdateItem" in (s["Action"] if isinstance(s["Action"], list) else [s["Action"]])]
        assert len(st) == 1 and "Condition" not in st[0], (prefix, st)
    sec = _guide_subsection("6.7")
    for needle in ("仍能**触发**消息", "`UpdateItem`、不按键限制", "任意一条锁记录", "`posted_<评审员>`", "拿不来钓鱼", "但能拿来骚扰"):
        assert needle in sec, needle
