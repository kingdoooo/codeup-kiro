import json
import urllib.error
import urllib.request

CODEUP_API_BASE = "https://openapi-rdc.aliyuncs.com"


def post_comment(org_id, repo_id, mr_local_id, token, markdown):
    """发一条 MR 全局评论。刻意只有一次 POST——不查重、不原地更新、不发行内评论。

    调用点都是评审脚本从未跑起来的失败点（调度失败、任务死在脚本启动之前），
    这时没有任何进程带着 scripts/ 里那套完整渲染器在跑，所以这不是汇总评论管线
    的替代品，只管在 MR 上留一句话（I10）。
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
