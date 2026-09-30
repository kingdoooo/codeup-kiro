import json
import urllib.error
import urllib.request

CODEUP_API_BASE = "https://openapi-rdc.aliyuncs.com"


def post_comment(org_id, repo_id, mr_local_id, token, markdown):
    """发一条 MR 全局评论。刻意只有一次 POST——不查重、不原地更新、不发行内评论。

    调用点都是评审脚本从未跑起来的失败点（调度失败、任务死在脚本启动之前），
    这时没有任何进程带着 scripts/ 里那套完整渲染器在跑，所以这不是汇总评论管线
    的替代品，只管在 MR 上留一句话（I10）。

    `timeout=10` 是**每次 socket 操作**的超时，不是整体截止时间：连接那一步按域名解析出的每个地址
    各算一次（openapi-rdc 能解析出十来个地址），连上之后每次 recv 又重新计时，所以跨境链路卡住时
    这一次调用可能吃满函数的 29 s。有意不加整体截止时间（issue 05 B4，Kent 2026-10-01 裁决）。超时
    的后果两边不同：兜底是 Lambda 重试、耗尽后进队列并告警，可见、可补发；调度器是同步调用（ALB 等着
    回应），函数超时即 ALB 502，「评审未启动」这条留痕就丢了，只剩平台 `REPORT` 行末尾的 `Status: timeout`。用线程
    强加截止时间，复用的执行环境里残留的线程可能晚些再把评论发出去。

    返回 False 只覆盖 HTTP 非 2xx 与连不上（`HTTPError` / `URLError`）；连上之后的读超时、连接被
    重置、对方不应答就断开抛的是原始的 `TimeoutError` / `ConnectionResetError` / `RemoteDisconnected`。
    """
    url = (f"{CODEUP_API_BASE}/oapi/v1/codeup/organizations/{org_id}"
           f"/repositories/{repo_id}/changeRequests/{mr_local_id}/comments")
    body = json.dumps({
        "comment_type": "GLOBAL_COMMENT",
        "content": markdown,
        "draft": False,
        "resolved": False,
    }).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "x-yunxiao-token": token,
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return 200 <= resp.status < 300
    except (urllib.error.HTTPError, urllib.error.URLError):
        return False
