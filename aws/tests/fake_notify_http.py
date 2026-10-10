"""本地 HTTP 替身：说云效 GetChangeRequest 与飞书（tenant_access_token、im/v1/messages）的协议，让通知 Lambda **真的** urllib 请求打过来
（spec「测试与验收」：真实请求形状用 fake_aws_http.py 那种替身，不靠 Mock 的 side_effect 证明请求发出——2a 的教训）。

一个服务器同时扮演三个上游：路径前缀 `/codeup`、`/feishu`、`/lark` 分别对应 notifier 的 CODEUP_API_BASE 与 FEISHU_BASES 的两个平台，
测试把它们 monkeypatch 成 `<url>/codeup` 之类。每个请求按到达顺序记进 requests：(方法, 路径含查询串, 请求头 dict, 解析后的 JSON 体或 None)。

- GetChangeRequest：`change_request` 是返回的 JSON（缺省一位绑了邮箱的作者 + 本组织本 MR 的 detailUrl），`change_request_status` 是状态码。
- tenant_access_token：`token_reply` 是返回的 JSON（缺省 code 0、expire 7200）。
- 发消息：`send_replies` 是按次序给出的 (状态码, JSON, 额外响应头)；用完之后一律成功（code 0）。
"""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ORG = "0123456789abcdef01234567"


def default_change_request(repo="7215683", mr="10", email="dev@example.com"):
    return {"localId": int(mr), "title": "t", "status": "UNDER_REVIEW",
            "author": {"email": email, "userId": "u1", "username": "aliyun:dev", "name": "dev"},
            "detailUrl": f"https://codeup.aliyun.com/{ORG}/demo-app/change/{mr}",
            "webUrl": f"https://codeup.aliyun.com/{ORG}/demo-app"}


class FakeNotify:
    def __init__(self):
        self.requests = []
        self.change_request = default_change_request()
        self.change_request_status = 200
        self.token_reply = {"code": 0, "msg": "ok", "tenant_access_token": "t-fake-tenant", "expire": 7200}
        self.send_replies = []
        self._lock = threading.Lock()
        self._server = None

    @property
    def url(self):
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    def paths(self):
        return [p for _, p, _, _ in self.requests]

    def sends(self):
        return [r for r in self.requests if "/open-apis/im/v1/messages" in r[1]]

    def start(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def _reply(self, status, payload, extra=None):
                data = json.dumps(payload, ensure_ascii=False).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                for k, v in (extra or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)

            def _record(self):
                n = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(n) if n else b""
                body = json.loads(raw) if raw else None
                with fake._lock:
                    fake.requests.append((self.command, self.path, {k.lower(): v for k, v in self.headers.items()}, body))
                return body

            def do_GET(self):
                self._record()
                if self.path.startswith("/codeup/oapi/v1/codeup/organizations/"):
                    return self._reply(fake.change_request_status, fake.change_request)
                return self._reply(404, {"errorCode": "NotFound"})

            def do_POST(self):
                self._record()
                if self.path.endswith("/open-apis/auth/v3/tenant_access_token/internal"):
                    return self._reply(200, fake.token_reply)
                if "/open-apis/im/v1/messages?receive_id_type=email" in self.path:
                    with fake._lock:
                        nxt = fake.send_replies.pop(0) if fake.send_replies else (200, {"code": 0, "msg": "success",
                                                                                         "data": {"message_id": "om_x"}}, {})
                    return self._reply(*nxt)
                return self._reply(404, {"code": -1})

            def log_message(self, *args):
                pass

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        # poll_interval 缺省 0.5 秒：每条用例收尾的 shutdown() 都要等满一轮
        threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        return self

    def stop(self):
        self._server.shutdown()
        self._server.server_close()
