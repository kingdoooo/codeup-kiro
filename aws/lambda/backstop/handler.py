import os
import sys

# Lambda 运行时里 codeup_min 与本文件不同目录（打包时放到 /opt/dispatcher）；
# 本地 pytest 时由测试文件把 lambda/dispatcher 加进 sys.path。两种情形都要能 import，
# 所以这一行是**条件式**的——无条件 insert 一个不存在的路径在本地会掩盖真正的 import 错误。
if os.path.isdir("/opt/dispatcher"):
    sys.path.insert(0, "/opt/dispatcher")
import codeup_min  # noqa: E402

WANT = ("CODEUP_REPO_ID", "MR_LOCAL_ID", "HEAD_SHA")


def _fields(event):
    for ov in (event.get("detail", {}).get("overrides", {})
               .get("containerOverrides") or []):
        env = {e.get("name"): e.get("value") for e in (ov.get("environment") or [])}
        if all(env.get(k) for k in WANT):
            return env
    return None


def should_post(event, table):
    """任务非正常结束、且评审脚本没留下「已回写」标记时，由我们补一条。

    覆盖 die_review 管不到的盲区：拉镜像失败、OOM、任务超时、entrypoint 在脚本启动前就死。
    """
    env = _fields(event)
    if not env:
        return False
    containers = event.get("detail", {}).get("containers") or [{}]
    code = containers[0].get("exitCode")
    if code == 0:
        return False
    key = "#".join(env[k] for k in WANT)
    item = (table.get_item(Key={"pk": key}).get("Item") or {})
    return not item.get("posted")


def handler(event, context):
    import boto3
    table = boto3.resource("dynamodb").Table(os.environ["LOCK_TABLE"])
    if not should_post(event, table):
        return {"ok": True, "posted": False}
    env = _fields(event)
    codeup_min.post_comment(
        os.environ["YUNXIAO_ORG_ID"], env["CODEUP_REPO_ID"], env["MR_LOCAL_ID"],
        os.environ["YUNXIAO_TOKEN"],
        "## 🤖 Kiro 代码评审\n\n**评审未完成**：评审任务异常结束（可能是拉取镜像失败、"
        "内存不足或任务超时），脚本没有机会回写失败原因。重新推送可再次触发。")
    return {"ok": True, "posted": True}
