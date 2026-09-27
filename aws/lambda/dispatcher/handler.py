import hmac
import time

import botocore.exceptions

import codeup_min
import secret_fetch  # 本目录下的 secret_fetch.py：调用时向 Secrets Manager 取密钥
# 入口是内网 ALB 的 Lambda target：每条返回路径都走 _resp（G5），正文一律经 _body_text 取（G6）。
from http_shape import body_text as _body_text  # noqa: F401 — Task 5 的 handler 用它取正文
from http_shape import resp as _resp

TOKEN_HEADER = "x-codeup-token"


def token_header(headers):
    """按大小写不敏感取 `x-codeup-token`；没有这个头、或它的值为空都返回 ""。

    verify_token 与 handler 都要判断「这次请求带没带令牌」，这里只写一份：两处各自遍历一遍
    headers，迟早会在大小写或空值的处理上分叉（ALB 转发的头名大小写不保证）。
    """
    for k, v in (headers or {}).items():
        if k.lower() == TOKEN_HEADER:
            return v or ""
    return ""


def verify_token(headers, expected):
    """常量时间比对 Codeup webhook 的共享密钥。

    Codeup 的 webhook 鉴权是**共享密钥而非 HMAC**：没有正文绑定、没有时间戳，
    所以它按设计可重放。重放防护由抢锁（N3）承担，这里只管「是不是我们的 webhook」。
    """
    if not expected:
        return False  # 密钥未配置时拒绝一切，绝不退化成放行
    got = token_header(headers)
    if not got:
        return False
    return hmac.compare_digest(str(got), str(expected))


def _secret_unavailable_code(exc):
    """写进日志的固定代号：AWS 错误码，或没走到 AWS 调用时的固定枚举值。

    固定枚举（`env-unset` / `empty-value` / AWS 错误码 / 异常类型名）而不是异常正文：正文是自由
    文本，带调用方角色 ARN 与账号 ID。这是 _failure_reason 已经确立的做法，直接复用它。
    """
    if exc.__cause__ is not None:
        return _failure_reason(exc.__cause__)
    return exc.reason or "unknown"


def handler(event, context):
    # 先看请求带没带令牌，再取密钥（M3）：没带令牌的请求一定会被拒，为它跑一次 GetSecretValue
    # 只是白费配额；更要紧的是取密钥正在失败时，任意公网调用者都会收到 503 secret-unavailable，
    # 那是在向外泄露我们这边的内部状态。没带令牌一律 401，不给它任何区分度。
    if not token_header(event.get("headers")):
        return _resp(401)
    try:
        expected = secret_fetch.secret_from_env("WEBHOOK_SECRET_ID")
    except secret_fetch.SecretUnavailable as exc:
        # fail closed：取不到共享密钥就无从判断「这是不是我们的 webhook」，一律不放行。
        # 关键在于给一个**显式响应**而不是让异常逃出 handler——未捕获异常对 ALB 就是 502，
        # Codeup 只看到投递失败，与 C1 同属静默失败。
        # 选 503 而不是 401：401 会把我们自己的配置/权限问题（少 secretsmanager:GetSecretValue、
        # 密钥名写错、密钥没建）伪装成「对方令牌不对」，运维照着 401 去查 Codeup 那侧的密钥，
        # 永远查不到真正的原因；503 是「我这边没就绪」，语义正确。
        #
        # Codeup 对 503 的重投行为已实测（Task 1，真实 webhook）：同一个 `X-Codeup-Delivery`
        # 在约 1 秒内一共到 3 次（立即重试 2 次），之后再无投递（观察 10 分钟以上）。所以
        # **只有亚秒级抖动（比如一次限流）能靠重投自愈**；配置或权限错误在 1 秒内不可能修好，
        # 那次事件就永久丢了——下面那行日志是它留下的唯一痕迹。同时这也意味着任何一次投递
        # 最多可能到 3 次且 delivery id 相同，幂等抢锁（N3）是承重的。
        #
        # 正文只给一个固定代号，不带任何 AWS 错误正文（含角色 ARN 与账号 ID，与 _failure_reason
        # 同一条理由）。
        #
        # 必须**留一行日志**（I1）：这条路径在 Lambda 看来是成功调用（Errors 指标为 0），
        # 响应正文对四种成因（缺 IAM 授权、密钥不存在/名字不符、密钥值为空、限流）完全一样，
        # 不打日志的话全新部署一旦配错就只剩一个查不下去的 503。形状固定、只有变量名与代号，
        # 便于按 code= 过滤；setup-guide 排错表按这个形状写。
        print(f"secret-unavailable var={exc.var_name} code={_secret_unavailable_code(exc)}",
              flush=True)
        return _resp(503, "secret-unavailable")
    if not verify_token(event.get("headers"), expected):
        return _resp(401)
    return _resp(200)


def lock_key(fields):
    """锁键 = repo#MR#head_sha，评论命令再拼评论 id。

    approve 携带上一次评审的同一个 head_sha，所以这个键天然区分「有新工作」
    与「回放/无关子事件」，不需要解析 Codeup 那六种子事件的字段。
    """
    parts = [fields["repo_id"], fields["mr_local_id"], fields["head_sha"]]
    extra = fields.get("dedupe_extra")
    if extra:  # None 或 "" 都视为「没有评论 id」，二者行为必须一致
        parts.append(extra)
    return "#".join(parts)


def claim(table, key, ttl_seconds):
    """条件写入抢锁。返回 False 表示这次投递是重复的（重放、approve、元数据更新）。

    抢锁必须在 RunTask 之前（N3）：webhook 共享密钥可重放，这是唯一的重放防护点。
    """
    try:
        table.put_item(
            Item={"pk": key, "expires_at": int(time.time()) + ttl_seconds,
                  "claimed_at": int(time.time())},
            ConditionExpression="attribute_not_exists(pk)")
        return True
    except botocore.exceptions.ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code == "ConditionalCheckFailedException":
            return False
        raise  # 真 AWS 错误（限流等）绝不能吞成「重复投递」


def release(table, key):
    """RunTask 失败后释放锁——否则一次限流会让那个 MR 永远评不了（N4）。"""
    table.delete_item(Key={"pk": key})


def run_task(ecs, cfg, fields, key):
    """拉起 Fargate 评审任务，返回 task ARN。

    只往 containerOverrides.environment 塞非敏感标量（I3）：RunTask 的入参会进
    CloudTrail，密钥必须走任务定义的 secrets 块（Secrets Manager ARN），绝不能出现在这里。

    LOCK_KEY 是 dispatch 抢锁用的同一个字符串，原样传进容器：执行器置「已回写」标记、兜底
    Lambda 读标记都只认它，任何别处都不重建（I1）——评论命令的键多一段评论 id，重建必然对不上。

    fields 的约定：缺失的可选值是 ""。值为 None 的字段不传——str(None) 会变成字面量 "None"：
    MR_TARGET_BRANCH=None 非空，脚本就不走「按源分支反查目标分支」，而是评审一个叫 None 的分支。
    不传时由 entrypoint 的 `:=` 缺省（可选项）或 `:?` 守卫（必填项）处理。
    """
    env = [{"name": k, "value": str(v)} for k, v in (
        ("CODEUP_REPO_ID", fields["repo_id"]),
        ("MR_LOCAL_ID", fields["mr_local_id"]),
        ("MR_TARGET_BRANCH", fields["target_branch"]),
        ("CI_COMMIT_REF_NAME", fields["source_branch"]),
        ("HEAD_SHA", fields["head_sha"]),
        ("BUSINESS_REPO_URL", fields["clone_url"]),
        ("LOCK_KEY", key),
    ) if v is not None]
    resp = ecs.run_task(
        cluster=cfg["cluster"], taskDefinition=cfg["task_definition"],
        launchType="FARGATE", count=1,
        networkConfiguration={"awsvpcConfiguration": {
            "subnets": cfg["subnets"], "securityGroups": cfg["security_groups"],
            "assignPublicIp": "ENABLED"}},
        overrides={"containerOverrides": [
            {"name": cfg["container_name"], "environment": env}]})
    return resp["tasks"][0]["taskArn"]


def _failure_reason(exc):
    """MR 评论里给的失败原因：AWS 错误码（ThrottlingException、AccessDeniedException…）或异常类型名。

    错误码是固定枚举，能区分限流、权限、集群不存在——从没部署过的环境里最先出现的就是这几类，
    这条评论是运维唯一的信号。绝不用 str(exc)：错误正文是自由文本，带 ARN、账号 ID 甚至内网地址。
    """
    if isinstance(exc, botocore.exceptions.ClientError):
        code = exc.response.get("Error", {}).get("Code")
        if code:
            return code
    return type(exc).__name__


def dispatch(ecs, table, cfg, fields):
    """抢锁 → 拉起任务；RunTask 失败时释放锁并在 MR 上留痕（I10），HTTP 仍返回 200
    以免 Codeup 因为我们的内部失败重投同一个 webhook。
    """
    key = lock_key(fields)
    if not claim(table, key, cfg.get("lock_ttl_seconds", 86400)):
        return _resp(200, "duplicate")
    try:
        run_task(ecs, cfg, fields, key)
    except Exception as exc:  # noqa: BLE001 — 拉起任务的失败面很杂（限流/无容量/瞬时网络错误），
                               # 都要落到同一条「释放锁 + 留痕」的兜底路径上，不能只挑几种已知异常
        release(table, key)
        codeup_min.post_comment(
            cfg["org_id"], fields["repo_id"], fields["mr_local_id"], cfg["codeup_token"],
            "## 🤖 Kiro 代码评审\n\n**评审未启动**：调度器无法拉起评审任务。\n\n"
            f"原因：`{_failure_reason(exc)}`。稍后重新推送可再次触发。")
        return _resp(200, "runtask-failed")
    return _resp(200, "dispatched")
