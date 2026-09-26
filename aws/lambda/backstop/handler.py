import os
import sys

# Lambda 运行时里 codeup_min 与本文件不同目录（打包时放到 /opt/dispatcher）；
# 本地 pytest 时由测试文件把 lambda/dispatcher 加进 sys.path。两种情形都要能 import，
# 所以这一行是**条件式**的——无条件 insert 一个不存在的路径在本地会掩盖真正的 import 错误。
if os.path.isdir("/opt/dispatcher"):
    sys.path.insert(0, "/opt/dispatcher")
import codeup_min  # noqa: E402
import secret_fetch  # noqa: E402 — 同上，dispatcher 目录下的 secret_fetch.py

# 认出「这是我们的评审任务」靠这三个变量；读「已回写」标记只用调度器传进来的 LOCK_KEY（I1）。
WANT = ("CODEUP_REPO_ID", "MR_LOCAL_ID", "HEAD_SHA")


def _matched_override(event):
    """找到真正带着我们这套环境变量的那个 containerOverride——整个字典，含 name，
    不只是环境变量表。多容器任务里要判断该看哪个容器的退出码，得靠这个 override
    自带的 name，不能靠数组下标（ECS 事件里容器顺序不保证；上一个任务修 N1
    镜像摘要门时已经踩过同一个坑：加一个 sidecar，index 0 就可能指向别的容器）。
    """
    for ov in (event.get("detail", {}).get("overrides", {})
               .get("containerOverrides") or []):
        env = {e.get("name"): e.get("value") for e in (ov.get("environment") or [])}
        if all(env.get(k) for k in WANT):
            return ov, env
    return None, None


def _fields(event):
    return _matched_override(event)[1]


def _exit_code(event, container_name):
    """按容器名字（不是数组下标）取退出码。只有一个容器时天然无歧义，直接用它；
    多容器且找不到匹配名字的容器时返回 (None, False)——调用方不能把这当「退出码是 0」，
    只能退回「已回写」标记去判断，宁可多发一条评论也不要因为看错容器而沉默。
    """
    containers = event.get("detail", {}).get("containers") or [{}]
    if len(containers) == 1:
        return containers[0].get("exitCode"), True
    for c in containers:
        if c.get("name") == container_name:
            return c.get("exitCode"), True
    return None, False


def should_post(event, table):
    """任务非正常结束、且评审脚本没留下「已回写」标记时，由我们补一条。

    覆盖 die_review 管不到的盲区：拉镜像失败、OOM、任务超时、entrypoint 在脚本启动前就死。

    第一句先看 lastStatus：ECS 在每次状态迁移（PROVISIONING/PENDING/RUNNING/…）都发这个事件，
    任务还在跑时容器没有 exitCode，不挡住的话每次评审开始几秒就会收到一条假的「评审未完成」。
    EventBridge 规则也只放 STOPPED，但规则是运维可改的配置，这里是这条不变式的最后一道。
    """
    if event.get("detail", {}).get("lastStatus") != "STOPPED":
        return False
    ov, env = _matched_override(event)
    if not env:
        return False
    code, determined = _exit_code(event, ov.get("name"))
    if determined and code == 0:
        return False
    # 锁键原样取调度器抢锁时写入的那个字符串，不用 WANT 自己拼——评论命令的键多一段评论 id，
    # 自己拼会读到另一条记录（被别的评审置过位就沉默，I10）。读不到 LOCK_KEY 就无从确认
    # 「已回写」，宁可多发一条也不沉默。
    key = env.get("LOCK_KEY")
    if not key:
        return True
    item = (table.get_item(Key={"pk": key}).get("Item") or {})
    return not item.get("posted")


def handler(event, context):
    import boto3
    table = boto3.resource("dynamodb").Table(os.environ["LOCK_TABLE"])
    if not should_post(event, table):
        return {"ok": True, "posted": False}
    env = _fields(event)
    # 令牌在真要发评论时才取（见 secret_fetch.py）：绝大多数 Task State Change 事件都被 should_post
    # 挡掉，提前取只会给每一次状态迁移都加一次 GetSecretValue 调用（配额与延迟）。
    # 取不到就让 SecretUnavailable 抛出去：这是 EventBridge 的异步调用，抛出会走 Lambda 自己的
    # 重试（密钥限流这类瞬时失败能自愈），吞掉返回 {"posted": False} 才是真正的沉默——兜底的
    # 整个存在理由就是「宁可多发一条也不沉默」（I10）。
    codeup_min.post_comment(
        os.environ["YUNXIAO_ORG_ID"], env["CODEUP_REPO_ID"], env["MR_LOCAL_ID"],
        secret_fetch.secret_from_env("YUNXIAO_TOKEN_ARN"),
        "## 🤖 Kiro 代码评审\n\n**评审未完成**：评审任务异常结束（可能是拉取镜像失败、"
        "内存不足或任务超时），脚本没有机会回写失败原因。重新推送可再次触发。")
    return {"ok": True, "posted": True}
