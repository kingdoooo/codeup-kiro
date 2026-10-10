"""飞书通知 Lambda（Phase 2c issue 20；spec「组件设计 · 通知 Lambda」、F4–F10、N-F1–N-F5）。

ReviewLock 表的 DynamoDB Stream（NEW_AND_OLD_IMAGES）→ 本函数。某位评审员的 `posted_<rid>` 在新映像里有、旧映像里没有，并且新映像带
形状合法的 `comment_<rid>`（32 位小写十六进制，评审员自己发出 / 更新的那条评论）→ 用 Kiro 机器人的云效令牌调 GetChangeRequest 取
MR 作者的邮箱与 MR 页地址 → 给作者发一条飞书消息。

消息正文只有三条固定文案之一 + 链接（N-F3）：链接 = API 返回的 `detailUrl`（按本 MR 的形状校验过）+ `?comment=<评论 id>`。MR 标题、
分支、发现计数都是业务库派生的不受信文本，一律不拼——被评审的代码不能借这条消息给公司里的人发钓鱼文本。

飞书凭证（密钥 `codeup-kiro/feishu-app`，JSON：app_id、app_secret）与到飞书的出站只在这里（N-F1）：两个持有业务库的任务都拿不到它。
任何失败只记一行日志（步骤、错误码、评审员、仓库 id、MR 号；**不记邮箱与令牌**），不改评审结果（N-F2：评审员只写锁记录，与这里没有
任何依赖），不抛给 Stream（抛了 Lambda 会按 ESM 的设置反复重放整批）。函数自己崩溃 / 超时时 ESM 的有限重试会重放整批，请求带
`uuid`（同一次评审、同一位评审员恒定），飞书一小时内同一个 uuid 最多发出一条（N-F4）。
每条通知有一个总时限（NOTIFY_BUDGET，终审 M-5）：用完就记 `code=deadline`、这一条不再试——连不上、对方不应答时函数因此不会跑到它自己的超时。
它管不到的：DNS 解析，以及连上之后对方一点一点地慢慢回（socket 超时在连接时定好，每次读到数据就重新计时）。
"""
import functools
import hashlib
import http.client
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request

# 与兜底 Lambda 同一手法（backstop/handler.py 顶部）：secret_fetch 与 bounded_config 在 /opt/dispatcher（共享 layer），本地 pytest 时由
# 测试把 lambda/dispatcher 加进 sys.path。条件式插入：无条件插一个不存在的路径会在本地掩盖真正的 import 错误。
if os.path.isdir("/opt/dispatcher"):
    sys.path.insert(0, "/opt/dispatcher")
import secret_fetch  # noqa: E402

REVIEWERS = ("kiro", "inspector", "security")
# 三条固定文案（spec F7）。SA 用「Continuum 代码安全扫描」，与它的汇总评论标题一致（F8）
MESSAGES = {
    "kiro": "Kiro 评审结束，请查阅：",
    "inspector": "Inspector 依赖漏洞扫描结束，请查阅：",
    "security": "Continuum 代码安全扫描结束，请查阅：",
}
CODEUP_API_BASE = "https://openapi-rdc.aliyuncs.com"
# 飞书与 Lark 是两个平台：API 路径相同、域名不同（open.feishu.cn / open.larksuite.com 的开发文档）
FEISHU_BASES = {"feishu": "https://open.feishu.cn", "lark": "https://open.larksuite.com"}
# 云效用户没绑邮箱时 GetChangeRequest 给的占位地址（sandbox 2026-10-09：accounts_<id>@mail.teambition.com），永不发送（N-F5）
PLACEHOLDER_SUFFIX = "@mail.teambition.com"
COMMENT_ID = re.compile(r"[0-9a-f]{32}")
# 锁键 = 仓库#MR#提交[#评论 id]（dispatcher/handler.py::lock_key；aws/tests/test_lock_key_contract.py 用真实的 lock_key() 核对）
LOCK_KEY = re.compile(r"([0-9]+)#([0-9]+)#[0-9a-f]{40}(?:#[^#]+)?")
EMAIL = re.compile(r"[^@\s]+@[^@\s]+")
HTTP_TIMEOUT = 10            # 每次 socket 操作（与 codeup_min 同一取值）；剩余时限更短时取剩余
NOTIFY_BUDGET = 40           # 每条通知的总时限（秒），见 _Budget
TOKEN_REFRESH_MARGIN = 600   # tenant_access_token 有效 2 小时；剩不到 10 分钟就重取（剩不到 30 分钟时飞书会给新令牌）
RATE_LIMIT_MAX_WAIT = 5      # 限流时按 x-ogw-ratelimit-reset 等，最多等这么久、只重试一次
_TOKEN_CACHE = {}            # (平台, app_id) → (tenant_access_token, 到期时的单调钟)


class NotifyError(Exception):
    """某一步失败：step 是固定枚举（secret / codeup / token / send），code 是错误码（HTTP 状态或飞书 code），都可以安全进日志。"""

    def __init__(self, step, code):
        super().__init__(f"{step}:{code}")
        self.step, self.code = step, code


def due(record):
    """这一条 Stream 记录要发的通知：[(评审员, 评论 id)]。只认 MODIFY 里 posted_<rid> 从无到有、且带合法 comment_<rid> 的那一次变化。"""
    if record.get("eventName") != "MODIFY":
        return []
    images = record.get("dynamodb") or {}
    new, old = images.get("NewImage") or {}, images.get("OldImage") or {}
    out = []
    for rid in REVIEWERS:
        if (new.get(f"posted_{rid}") or {}).get("BOOL") is not True or f"posted_{rid}" in old:
            continue
        cid = (new.get(f"comment_{rid}") or {}).get("S")
        if isinstance(cid, str) and COMMENT_ID.fullmatch(cid):
            out.append((rid, cid))
    return out


def mr_of(record):
    """(锁键, 仓库 id, MR 号)，锁键形状不对时 None。"""
    pk = (((record.get("dynamodb") or {}).get("NewImage") or {}).get("pk") or {}).get("S")
    m = LOCK_KEY.fullmatch(pk) if isinstance(pk, str) else None
    return (pk, m.group(1), m.group(2)) if m else None


def message_uuid(pk, rid):
    """同一次评审（锁键）、同一位评审员恒定的请求 uuid（飞书：最长 50 个字符，一小时内同一个 uuid 最多成功发送一条）。"""
    return hashlib.sha256(f"{pk}|{rid}".encode()).hexdigest()[:32]


class _Budget:
    """一条通知的总时限（终审 M-5）。HTTP_TIMEOUT 只管每次 socket 操作：sandbox 2026-10-10 一个执行环境连不上云效时，一次请求要 120 秒
    （OpenAPI 解析出 12 个地址，标准库逐个地址试、每个都套满 10 秒）；批 1、一个分片，后面的记录全排在它后面，函数超时后 ESM 重放整批、
    最后按记录年龄无声丢弃。所以每次请求前查剩余、socket 超时取 min(HTTP_TIMEOUT, 剩余)，连接逐个地址试时剩余用完就停（_connect_within），
    限流等待也不超过剩余。不用线程或 SIGALRM：不留下晚些才发出去的请求，也不在库代码持锁时抛异常。
    限的是连接失败与对方不应答；DNS 解析与连上之后慢慢回（每读到一点数据 socket 超时就重新计时）不在时限内（复审 m-1，接受：两个上游都是受信的 API）。"""

    def __init__(self):
        self.at = time.monotonic() + NOTIFY_BUDGET

    def left(self):
        return self.at - time.monotonic()


def _connect_within(budget):
    """给 http.client 连接对象的 create_connection：与 socket.create_connection 一样逐个地址试，但每个地址的连接超时取 min(超时, 剩余)，
    剩余用完就不再试下一个。"""
    def create(address, timeout, source_address=None, *args, **kwargs):
        per = timeout if isinstance(timeout, (int, float)) else HTTP_TIMEOUT
        err = None
        for *_, sa in socket.getaddrinfo(address[0], address[1], 0, socket.SOCK_STREAM):
            rest = budget.left()
            if rest <= 0:
                break
            try:
                return socket.create_connection(sa[:2], min(per, rest), source_address)
            except OSError as exc:
                err = exc
        raise err if err is not None else TimeoutError("notify budget spent")
    return create


# `_create_connection` 是 http.client 连接对象在 __init__ 里设的实例属性（connect() 经它建 socket；CPython 自己的测试也这样换它）。
# 运行时换版本后它若不再被用到，test_notifier.py 的 blackhole 用例先红
class _BudgetHTTPConnection(http.client.HTTPConnection):
    def __init__(self, *args, budget, **kwargs):
        super().__init__(*args, **kwargs)
        self._create_connection = _connect_within(budget)


class _BudgetHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *args, budget, **kwargs):
        super().__init__(*args, **kwargs)
        self._create_connection = _connect_within(budget)


class _BudgetHTTPHandler(urllib.request.HTTPHandler):
    def __init__(self, budget):
        super().__init__()
        self._budget = budget

    def http_open(self, req):
        return self.do_open(functools.partial(_BudgetHTTPConnection, budget=self._budget), req)


class _BudgetHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, budget):
        super().__init__()
        self._budget = budget

    def https_open(self, req):
        return self.do_open(functools.partial(_BudgetHTTPSConnection, budget=self._budget), req, context=self._context)


def _http(req, budget):
    """→ (HTTP 状态, 响应头, 解析后的 JSON 或 None)。连不上抛 NotifyError 由调用方补 step。"""
    opener = urllib.request.build_opener(_BudgetHTTPHandler(budget), _BudgetHTTPSHandler(budget))
    try:
        with opener.open(req, timeout=min(HTTP_TIMEOUT, budget.left())) as resp:
            status, headers, raw = resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as exc:
        status, headers, raw = exc.code, exc.headers, exc.read()
    try:
        body = json.loads(raw or b"null")
    except ValueError:
        body = None
    return status, headers, body


def _call(step, req, budget):
    if budget.left() <= 0:
        raise NotifyError(step, "deadline")
    try:
        return _http(req, budget)
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
        raise NotifyError(step, "deadline" if budget.left() <= 0 else "network") from exc


def change_request(org, repo, mr, token, budget):
    """GetChangeRequest → (作者邮箱, MR 页地址)。"""
    req = urllib.request.Request(
        f"{CODEUP_API_BASE}/oapi/v1/codeup/organizations/{org}/repositories/{repo}/changeRequests/{mr}",
        headers={"x-yunxiao-token": token, "Accept": "application/json"})
    status, _, body = _call("codeup", req, budget)
    if not 200 <= status < 300:
        raise NotifyError("codeup", f"http-{status}")
    if not isinstance(body, dict):
        raise NotifyError("codeup", "bad-json")
    author = body.get("author") if isinstance(body.get("author"), dict) else {}
    email = author.get("email") if isinstance(author.get("email"), str) else ""
    url = body.get("detailUrl") if isinstance(body.get("detailUrl"), str) else ""
    return email.strip(), url


def detail_url_ok(url, org, mr):
    """detailUrl 必须是本组织、本 MR 的页面（sandbox 2026-10-10：`https://codeup.aliyun.com/<组织>/<仓库路径>/change/<MR 号>`）。
    只许路径里常见的字符：链接写成 `[…](…)`，方括号、圆括号、空白、`?`、`#` 都会改掉它的意思。"""
    return re.fullmatch(rf"https://codeup\.aliyun\.com/{re.escape(org)}(?:/[A-Za-z0-9._-]+)+/change/{mr}", url) is not None


def _feishu_code(body):
    return body.get("code") if isinstance(body, dict) else None


def tenant_token(platform, app_id, app_secret, budget, fresh=False):
    key = (platform, app_id)
    hit = _TOKEN_CACHE.get(key)
    if hit and not fresh and time.monotonic() < hit[1]:
        return hit[0]
    req = urllib.request.Request(
        f"{FEISHU_BASES[platform]}/open-apis/auth/v3/tenant_access_token/internal",
        data=json.dumps({"app_id": app_id, "app_secret": app_secret}).encode(), method="POST",
        headers={"Content-Type": "application/json; charset=utf-8"})
    status, _, body = _call("token", req, budget)
    code = _feishu_code(body)
    token = body.get("tenant_access_token") if isinstance(body, dict) else None
    if code != 0 or not isinstance(token, str) or not token:
        raise NotifyError("token", f"feishu-{code}" if code is not None else f"http-{status}")
    expire = body.get("expire") if type(body.get("expire")) is int else 7200
    _TOKEN_CACHE[key] = (token, time.monotonic() + max(expire - TOKEN_REFRESH_MARGIN, 0))
    return token


def send(platform, creds, email, text, uuid, budget):
    """im/v1/messages?receive_id_type=email。限流（HTTP 429、code 99991400，或同一收件人发得太频繁的 230020——飞书给它的是 HTTP 400）
    按 x-ogw-ratelimit-reset 等一次再试（没有这个头时等 1 秒，最多等 RATE_LIMIT_MAX_WAIT 秒；仍限流就只记日志，这一条不再发）；
    租户令牌失效（99991663）重取一次再试；别的错误（230013 不在可用范围、230038 跨租户、230029 已离职、230053 屏蔽了机器人……）不重试。
    等待也不超过这条通知剩下的时限（_Budget）。"""
    body = json.dumps({"receive_id": email, "msg_type": "text", "uuid": uuid,
                       "content": json.dumps({"text": text}, ensure_ascii=False)}, ensure_ascii=False).encode()
    fresh = False
    for attempt in (1, 2):
        token = tenant_token(platform, creds["app_id"], creds["app_secret"], budget, fresh=fresh)
        req = urllib.request.Request(
            f"{FEISHU_BASES[platform]}/open-apis/im/v1/messages?receive_id_type=email", data=body, method="POST",
            headers={"Content-Type": "application/json; charset=utf-8", "Authorization": f"Bearer {token}"})
        status, headers, resp = _call("send", req, budget)
        code = _feishu_code(resp)
        if 200 <= status < 300 and code == 0:
            return
        if attempt == 1 and (status == 429 or code in (99991400, 230020)):
            try:
                wait = int((headers or {}).get("x-ogw-ratelimit-reset") or 1)
            except ValueError:
                wait = 1
            time.sleep(max(min(wait, RATE_LIMIT_MAX_WAIT, budget.left()), 0))
            continue
        if attempt == 1 and code == 99991663:
            fresh = True
            continue
        raise NotifyError("send", f"feishu-{code}" if code is not None else f"http-{status}")


def _secret_code(exc):
    if exc.reason:
        return exc.reason
    err = getattr(exc.__cause__, "response", None)
    code = (err or {}).get("Error", {}).get("Code") if isinstance(err, dict) else None
    return code if isinstance(code, str) and re.fullmatch(r"[A-Za-z]{1,64}", code) else "unknown"


def feishu_creds():
    try:
        raw = secret_fetch.secret_from_env("FEISHU_APP_SECRET_ID")
    except secret_fetch.SecretUnavailable as exc:
        raise NotifyError("secret", _secret_code(exc)) from exc
    try:
        creds = json.loads(raw)
    except ValueError:
        creds = None
    if not (isinstance(creds, dict) and isinstance(creds.get("app_id"), str) and creds["app_id"]
            and isinstance(creds.get("app_secret"), str) and creds["app_secret"]):
        raise NotifyError("secret", "bad-shape")
    return creds


def codeup_token():
    try:
        return secret_fetch.secret_from_env("YUNXIAO_TOKEN_ID")
    except secret_fetch.SecretUnavailable as exc:
        raise NotifyError("secret", _secret_code(exc)) from exc


def notify(pk, repo, mr, rid, cid):
    """→ 'sent' 或 'skipped:<原因>'；失败抛 NotifyError。"""
    org = os.environ["YUNXIAO_ORG_ID"]
    budget = _Budget()
    email, url = change_request(org, repo, mr, codeup_token(), budget)
    if not email or email.lower().endswith(PLACEHOLDER_SUFFIX):
        return "skipped:no-email"
    if not EMAIL.fullmatch(email):
        return "skipped:bad-email"
    if not detail_url_ok(url, org, mr):
        return "skipped:bad-url"
    link = f"{url}?comment={cid}"
    platform = os.environ.get("FEISHU_DOMAIN") or "feishu"
    if platform not in FEISHU_BASES:
        raise NotifyError("config", "bad-domain")
    send(platform, feishu_creds(), email, f"{MESSAGES[rid]}[{link}]({link})", message_uuid(pk, rid), budget)
    return "sent"


def handler(event, context):
    for record in (event or {}).get("Records") or []:
        jobs = due(record)
        if not jobs:
            continue
        where = mr_of(record)
        if where is None:
            print("notify result=skipped reason=bad-lock-key", flush=True)
            continue
        pk, repo, mr = where
        for rid, cid in jobs:
            tag = f"notify reviewer={rid} repo={repo} mr={mr}"
            try:
                out = notify(pk, repo, mr, rid, cid)
                if out == "sent":
                    print(f"{tag} result=sent", flush=True)
                else:
                    print(f"{tag} result=skipped reason={out.split(':', 1)[1]}", flush=True)
            except NotifyError as exc:
                print(f"{tag} result=failed step={exc.step} code={exc.code}", flush=True)
            except Exception as exc:  # noqa: BLE001 — 通知永远不改评审结果、也不让 Stream 重放整批（F9）；只记异常类名
                print(f"{tag} result=failed step=internal code={type(exc).__name__}", flush=True)
    return {"ok": True}
