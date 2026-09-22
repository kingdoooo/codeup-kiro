import hmac
import os
import time

import botocore.exceptions

import codeup_min

TOKEN_HEADER = "x-codeup-token"


def verify_token(headers, expected):
    """常量时间比对 Codeup webhook 的共享密钥。

    Codeup 的 webhook 鉴权是**共享密钥而非 HMAC**：没有正文绑定、没有时间戳，
    所以它按设计可重放。重放防护由抢锁（N3）承担，这里只管「是不是我们的 webhook」。
    """
    if not expected:
        return False  # 密钥未配置时拒绝一切，绝不退化成放行
    got = None
    for k, v in (headers or {}).items():
        if k.lower() == TOKEN_HEADER:
            got = v
            break
    if not got:
        return False
    return hmac.compare_digest(str(got), str(expected))


def handler(event, context):
    expected = os.environ.get("WEBHOOK_SECRET", "")
    if not verify_token(event.get("headers"), expected):
        return {"statusCode": 401}
    return {"statusCode": 200}


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


def run_task(ecs, cfg, fields):
    """拉起 Fargate 评审任务，返回 task ARN。

    只往 containerOverrides.environment 塞非敏感标量（I3）：RunTask 的入参会进
    CloudTrail，密钥必须走任务定义的 secrets 块（Secrets Manager ARN），绝不能出现在这里。
    """
    env = [{"name": k, "value": str(v)} for k, v in (
        ("CODEUP_REPO_ID", fields["repo_id"]),
        ("MR_LOCAL_ID", fields["mr_local_id"]),
        ("MR_TARGET_BRANCH", fields["target_branch"]),
        ("CI_COMMIT_REF_NAME", fields["source_branch"]),
        ("HEAD_SHA", fields["head_sha"]),
        ("BUSINESS_REPO_URL", fields["clone_url"]),
    )]
    resp = ecs.run_task(
        cluster=cfg["cluster"], taskDefinition=cfg["task_definition"],
        launchType="FARGATE", count=1,
        networkConfiguration={"awsvpcConfiguration": {
            "subnets": cfg["subnets"], "securityGroups": cfg["security_groups"],
            "assignPublicIp": "ENABLED"}},
        overrides={"containerOverrides": [
            {"name": cfg["container_name"], "environment": env}]})
    return resp["tasks"][0]["taskArn"]


def dispatch(ecs, table, cfg, fields):
    """抢锁 → 拉起任务；RunTask 失败时释放锁并在 MR 上留痕（I10），HTTP 仍返回 200
    以免 Codeup 因为我们的内部失败重投同一个 webhook。
    """
    key = lock_key(fields)
    if not claim(table, key, cfg.get("lock_ttl_seconds", 86400)):
        return {"statusCode": 200, "body": "duplicate"}
    try:
        run_task(ecs, cfg, fields)
    except Exception as exc:  # noqa: BLE001 — 拉起任务的失败面很杂（限流/无容量/瞬时网络错误），
                               # 都要落到同一条「释放锁 + 留痕」的兜底路径上，不能只挑几种已知异常
        release(table, key)
        codeup_min.post_comment(
            cfg["org_id"], fields["repo_id"], fields["mr_local_id"], cfg["codeup_token"],
            "## 🤖 Kiro 代码评审\n\n**评审未启动**：调度器无法拉起评审任务。\n\n"
            f"原因：`{type(exc).__name__}`。稍后重新推送可再次触发。")
        return {"statusCode": 200, "body": "runtask-failed"}
    return {"statusCode": 200, "body": "dispatched"}
