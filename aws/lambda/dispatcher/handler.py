import hmac
import json
import os
import re
import time

import botocore.exceptions

import codeup_min
import secret_fetch  # 本目录下的 secret_fetch.py：调用时向 Secrets Manager 取密钥
# 入口是内网 ALB 的 Lambda target：每条返回路径都走 _resp（G5），正文一律经 _body_text 取（G6）。
from http_shape import body_text as _body_text
from http_shape import resp as _resp

TOKEN_HEADER = "x-codeup-token"
# 真实头名是 `X-Codeup-Event`，ALB 交给 Lambda 时小写成 `x-codeup-event`（Task 1 实测）。名字写错
# 不会有任何报错——`classify` 会把**每一个**投递都判 ignore，部署出去一切健康却一条评审都不跑。
EVENT_HEADER = "x-codeup-event"
MR_EVENT = "merge request hook"
NOTE_EVENT = "note hook"
# 本方评审评论的标记（scripts/lib/review-render.sh 写入 `<!-- kiro-review:<sha> run:N -->`）。
REVIEW_MARKER = "<!-- kiro-review:"


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


def _dig(d, *path, default=None):
    """按路径取值；中途遇到非字典、缺键或 None 都返回 default。

    报文形状不符合预期时不猜（N6）：容错取值 + 上层「任一必需字段缺失就 ignore」，
    比在半个报文上硬取字段安全。
    """
    cur = d
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur if cur is not None else default


def _scalar(v):
    """把报文里的标量转成字符串；缺失或形状不对返回 None。

    两件事各自都会变成静默故障：
    - `project_id` / `local_id` 在真实报文里是**整数**，而 containerOverrides.environment 的值
      必须是字符串（run_task 会 str() 一遍，但 fields 里就保持字符串，免得别处再各自转一次）。
    - 判「缺失」用显式的 `None` 判断，**不用真值判断**：`local_id == 0` 是合法序号，`if not v`
      会把它当成缺失、于是那条 MR 静默不评（falsy 但有意义）。
    字典/列表/浮点/布尔出现在这几个位置就是报文形状不对：`str({"a": 1})` 会把一个字典原样塞进
    CODEUP_REPO_ID，那比 ignore 糟得多。bool 要单独挡——Python 里 `isinstance(True, int)` 为真。
    """
    if v is None or isinstance(v, bool) or not isinstance(v, (str, int)):
        return None
    s = str(v).strip()
    return s or None


def _event_name(headers):
    """大小写不敏感地取事件头（ALB 转发的头名大小写不保证），取值也归一。"""
    for k, v in (headers or {}).items():
        if k.lower() == EVENT_HEADER:
            return str(v).strip().lower()
    return ""


def _fields_from(mr, repo):
    """从 MR 主体与 repository 抽出评审需要的六个标量；任一必需字段缺失返回 None。

    `mr` 是 MR Hook 的 `object_attributes`，或 Note Hook 的 `merge_request`——两者的字段名相同，
    只是挂的位置不同（Task 1 结论文件 §1），所以抽取只写一份。
    `dedupe_extra` 统一产出空串而不是 None（I5）：MR 事件没有评论 id，但缺失的可选值必须是 ""。
    """
    fields = {
        "repo_id": _scalar(_dig(mr, "project_id")),
        "mr_local_id": _scalar(_dig(mr, "local_id")),
        "source_branch": _scalar(_dig(mr, "source_branch")),
        "target_branch": _scalar(_dig(mr, "target_branch")),
        "head_sha": _scalar(_dig(mr, "last_commit", "id")),
        "clone_url": _scalar(_dig(repo, "git_http_url")),
    }
    if any(v is None for v in fields.values()):
        return None
    fields["dedupe_extra"] = ""
    return fields


def _branch_allowed(target, cfg):
    """目标分支过滤：过滤器为空表示不过滤。

    正则配错时 fail closed 并留一行固定形状日志：让 re.error 逃出去就是 ALB 502，Codeup 只看到
    投递失败（与 C1 同属静默失败），而且四类成因在响应里完全一样。日志里不带正则本身——它是
    自由文本，与 _failure_reason 同一条理由。
    """
    pattern = cfg.get("target_branch_filter") or ""
    if not pattern:
        return True
    try:
        return bool(re.search(pattern, target or ""))
    except re.error:
        print("bad-target-branch-filter var=TARGET_BRANCH_FILTER", flush=True)
        return False


def classify(headers, body, cfg):
    """决定这次投递要不要评审，并抽出评审所需的标量。

    返回 ("review", fields) 或 ("ignore", None)。未知事件与未知报文形状一律 ignore —— 不猜（N6）。

    两条 Task 1 实测的事实只影响注释、不影响逻辑：①同一次投递最多到 3 次（我们回 503 时 Codeup
    在约 1 秒内立即重试 2 次，`X-Codeup-Delivery` 不变），靠幂等抢锁（N3）吸收，classify 不去重；
    ②Note 报文里的 `merge_request.state` 与 MR 报文的 `state` 不是同一套取值（MR 已通过时前者仍是
    `opened`），不要拿来互相比较，所以评论分支不看 state。
    """
    ev = _event_name(headers)

    if ev == MR_EVENT:
        fields = _fields_from(_dig(body, "object_attributes"), _dig(body, "repository"))
        if fields is None:
            return "ignore", None
        # state/action 归一大小写再比：Codeup 自己就不统一（MR 报文的 state 是 `opened`，Note 报文
        # 里那个是 `OPENED`），逐字比一旦对方改了大小写就是「一条都不评」的静默失败。
        if _norm(_dig(body, "object_attributes", "state")) != "opened":
            return "ignore", None            # 通过 = accepted（Task 1 实测），不是新评审
        if (_norm(_dig(body, "object_attributes", "action")) == "update"
                and _dig(body, "object_attributes", "is_update_by_push") is False):
            return "ignore", None            # 非推送的 update 没有新代码；字段缺失时不走这条
        if not _branch_allowed(fields["target_branch"], cfg):
            return "ignore", None
        return "review", fields

    if ev == NOTE_EVENT:
        if not cfg.get("review_command"):
            return "ignore", None
        if _dig(body, "object_attributes", "system") is True:
            return "ignore", None
        author = _dig(body, "user", "username", default="")
        if author in set(cfg.get("bot_usernames") or []):
            return "ignore", None            # N5：本方评论会触发 Note Hook，必须断环
        note = _dig(body, "object_attributes", "note", default="")
        if not isinstance(note, str):
            return "ignore", None
        if REVIEW_MARKER in note:
            # 本方评审评论。**不能只靠作者名单**：本方机器人与人可以是同一个账号（Task 1 实测，
            # Kent 的 demo 里 Flow 的评审评论作者就是 MR 作者本人），那时名单里要么没这个人
            # （断不了环）、要么有（把人的命令一起吞掉）。而 AWS 档位的页脚按
            # pipeline/setup-guide.md 会写「评论 `/kiro review` 可重新评审」——评审评论正文里
            # 就带着命令短语，少了这道守卫就是评审触发自己的无穷循环。
            return "ignore", None
        phrase = cfg.get("command_phrase") or ""
        if not phrase:
            # falsy 但有意义：`"" in note` 恒真 → 每条评论都触发评审（含本方那条）→ 循环。
            # 短语没配好时 fail closed，绝不退化成「谁说话都评」。
            return "ignore", None
        if phrase not in note:
            return "ignore", None
        fields = _fields_from(_dig(body, "merge_request"), _dig(body, "repository"))
        if fields is None:
            return "ignore", None
        if not _branch_allowed(fields["target_branch"], cfg):
            return "ignore", None
        # 评论的唯一 id 是 note_biz_id（32 位十六进制）；真实 Note Hook 里**没有**
        # object_attributes.id——用 id 取值会恒为空串，于是每一条 /kiro review 都被静默忽略。
        fields["dedupe_extra"] = _scalar(_dig(body, "object_attributes", "note_biz_id")) or ""
        if not fields["dedupe_extra"]:
            return "ignore", None            # 没有评论 id 就无法去重，宁可不评
        return "review", fields

    return "ignore", None


def _norm(v):
    """报文里的枚举值归一：缺失变空串，去空白并转小写。"""
    return "" if v is None else str(v).strip().lower()


def _secret_unavailable_code(exc):
    """写进日志的固定代号：AWS 错误码，或没走到 AWS 调用时的固定枚举值。

    固定枚举（`env-unset` / `empty-value` / AWS 错误码 / 异常类型名）而不是异常正文：正文是自由
    文本，带调用方角色 ARN 与账号 ID。这是 _failure_reason 已经确立的做法，直接复用它。
    """
    if exc.__cause__ is not None:
        return _failure_reason(exc.__cause__)
    return exc.reason or "unknown"


def _secret_unavailable(exc):
    """取不到密钥时的唯一出口：一行固定形状日志 + 503。两个密钥（WEBHOOK_SECRET_ID 与
    YUNXIAO_TOKEN_ID）共用这一份，不复制——复制出来的第二份迟早在日志形状或状态码上分叉，
    而 setup-guide 的排错表只按一种形状写。

    必须**留一行日志**（I1）：这条路径在 Lambda 看来是成功调用（Errors 指标为 0），
    响应正文对四种成因（缺 IAM 授权、密钥不存在/名字不符、密钥值为空、限流）完全一样，
    不打日志的话全新部署一旦配错就只剩一个查不下去的 503。形状固定、只有变量名与代号，
    便于按 code= 过滤；setup-guide 排错表按这个形状写。
    """
    print(f"secret-unavailable var={exc.var_name} code={_secret_unavailable_code(exc)}",
          flush=True)
    return _resp(503, "secret-unavailable")


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
        # 那次事件就永久丢了——下面那行日志是它留下的唯一痕迹。同时这也意味着**被我们回了 503 的
        # 那次投递**最多可能到 3 次且 delivery id 相同，幂等抢锁（N3）是承重的。
        # （只测了 503 这一个状态码；404/502/504 是否同样重投没测过，所以「最多 3 次」不是所有
        # 状态码的上界。幂等抢锁的必要性不依赖这个数字——共享密钥鉴权本身就可重放。）
        #
        return _secret_unavailable(exc)
    if not verify_token(event.get("headers"), expected):
        return _resp(401)

    # 验签通过。下面才是「这次投递要不要评审」——原计划把 verify_token / classify / claim /
    # run_task 各自实现并各自测试，却没有任何一步把它们接到入口上：那样 handler 会验完签名就
    # return 200，每一个 webhook 都被接受然后什么都不做，而全套单测照样绿。这段接线是唯一
    # 能证明「部件都对且真的连上了」的地方。
    try:
        cfg = _runtime_cfg()
    except secret_fetch.SecretUnavailable as exc:
        # 云效令牌也取不到就没法在 MR 上留痕（I10），继续往下走只会在拉起任务失败时静默丢失。
        # 与 WEBHOOK_SECRET_ID 共用同一条 503 + 同一行日志形状，运维只需按 var= 区分是哪一个密钥。
        return _secret_unavailable(exc)
    try:
        body = json.loads(_body_text(event) or "{}")
    except ValueError:
        # 解不开的正文不猜（N6）。200 而不是 4xx：这次投递我们已经处理完了，回非 2xx 只会让
        # Codeup 把同一份解不开的正文再投两次（实测行为，见上）。
        return _resp(200, "unparseable")

    kind, fields = classify(event.get("headers"), body, cfg)
    if kind != "review":
        return _resp(200, "ignored")

    ecs, table = _clients(cfg)
    return dispatch(ecs, table, cfg, fields)


def _runtime_cfg():
    """非敏感值来自环境变量；云效令牌来自 Secrets Manager（调用时取，见 secret_fetch.py）。

    config.yaml 只放非敏感值，`codeup_token` 永远不是它的字段（既有裁决）——所以这里是运行时
    唯一的令牌来源，也绝不读明文环境变量。取不到时 secret_fetch.SecretUnavailable 原样抛出，
    由 handler 统一走 503 那条路径。
    这层间接（连同 _clients）同时让入口可测：单测不必真的有环境变量和 AWS 客户端。
    """
    return {
        "org_id": os.environ["YUNXIAO_ORG_ID"],
        "codeup_token": secret_fetch.secret_from_env("YUNXIAO_TOKEN_ID"),
        "cluster": os.environ["ECS_CLUSTER"],
        "task_definition": os.environ["ECS_TASK_DEFINITION"],
        "container_name": os.environ["ECS_CONTAINER_NAME"],
        "subnets": os.environ["SUBNET_IDS"].split(","),
        "security_groups": os.environ["SECURITY_GROUP_IDS"].split(","),
        "lock_ttl_seconds": int(os.environ.get("LOCK_TTL_SECONDS", "86400")),
        "bot_usernames": [u for u in os.environ.get("BOT_USERNAMES", "").split(",") if u],
        "review_command": int(os.environ.get("REVIEW_COMMAND", "0")),
        "command_phrase": os.environ.get("REVIEW_COMMAND_PHRASE", "/kiro review"),
        "target_branch_filter": os.environ.get("TARGET_BRANCH_FILTER", ""),
    }


def _clients(cfg):
    """ECS 客户端与锁表。boto3 在函数内部 import，沿用本仓库写法（见 secret_fetch.py）。"""
    import boto3
    return boto3.client("ecs"), boto3.resource("dynamodb").Table(os.environ["LOCK_TABLE"])


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
