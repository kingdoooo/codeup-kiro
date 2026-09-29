"""本地 HTTP 替身：说 DynamoDB PutItem / DeleteItem 与 ECS RunTask 的 JSON 协议，让**真的** botocore 客户端（生产 `_clients()` 建的
那两个，带有界超时与 standard 重试）打过来。

它存在的理由是 issue 02：「已提交、应答却丢了」之后 SDK 的重试会发生什么，靠 Mock 的 side_effect 证明不了——重试发生在
botocore 里面，而 Mock 替掉的正是 botocore。这里客户端、超时、重试、请求序列化与错误解析全是真的，只有服务端是替身。

- PutItem **真的求值**条件：只认 `attribute_not_exists(pk)` 与「无条件」两种，认不出的条件回 ValidationException（不猜：
  认不出就放行会让删掉/改弱条件的变异假绿）。条件失败时按请求里的 ReturnValuesOnConditionCheckFailure 决定带不带旧项：
  `ALL_OLD` → 带，线上格式（`{"S": …}`）；不带 → 没有 `Item`。两者都与真 DynamoDB 一致（2026-09-29 沙箱实测，
  `boto3.resource(...).Table.put_item` 拿到的 `exc.response["Item"]` 就是线上格式）。
- RunTask 按 clientToken 去重：同一个 token 返回原来那个任务（ECS 文档 ECS_Idempotency.html）；没带 token 就每次新起一个。
- `stall(op, n)`：该操作接下来 n 个请求「先落地副作用、再拖过读超时才应答」——服务端已经写了/起了，客户端只看到超时。
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_TARGETS = {
    "DynamoDB_20120810.PutItem": ("PutItem", "application/x-amz-json-1.0"),
    "DynamoDB_20120810.DeleteItem": ("DeleteItem", "application/x-amz-json-1.0"),
    "AmazonEC2ContainerServiceV20141113.RunTask": ("RunTask", "application/x-amz-json-1.1"),
}
_DDB_ERR = "com.amazonaws.dynamodb.v20120810#"


class FakeAws:
    def __init__(self, stall_seconds):
        self.items = {}        # pk 字符串 → 线上格式的项
        self.launched = []     # 真正「起了」的任务 ARN，按起的先后
        self.requests = []     # (操作名, 请求体)，含被重试的那几次
        self._by_token = {}
        self._stalls = {}
        self._stall_seconds = stall_seconds
        self._lock = threading.Lock()
        self._server = None

    def stall(self, op, n=1):
        self._stalls[op] = n

    @property
    def url(self):
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    def start(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                op, ctype = _TARGETS.get(self.headers.get("X-Amz-Target", ""), (None, "application/json"))
                with fake._lock:
                    fake.requests.append((op, body))
                    status, payload = fake._handle(op, body)
                    stall = fake._stalls.get(op, 0) > 0
                    if stall:
                        fake._stalls[op] -= 1
                if stall:
                    time.sleep(fake._stall_seconds)
                data = json.dumps(payload).encode()
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", ctype)
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("x-amzn-RequestId", "fake")
                    self.end_headers()
                    self.wfile.write(data)
                except OSError:
                    pass   # 拖过读超时之后客户端早已断开：副作用已落地，应答丢了——这正是要模拟的

            def log_message(self, *args):
                pass

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self._server.block_on_close = False
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def stop(self):
        self._server.shutdown()
        self._server.server_close()

    def _handle(self, op, body):
        if op == "PutItem":
            return self._put_item(body)
        if op == "DeleteItem":
            self.items.pop(body["Key"]["pk"]["S"], None)
            return 200, {}
        if op == "RunTask":
            return self._run_task(body)
        return 400, {"__type": "UnknownOperationException", "message": "fake_aws_http: unsupported target"}

    def _put_item(self, body):
        item = body["Item"]
        pk = item["pk"]["S"]
        cond = body.get("ConditionExpression")
        if cond not in (None, "attribute_not_exists(pk)"):
            return 400, {"__type": _DDB_ERR + "ValidationException",
                         "message": f"fake_aws_http: unsupported condition {cond!r}"}
        if cond and pk in self.items:
            err = {"__type": _DDB_ERR + "ConditionalCheckFailedException",
                   "message": "The conditional request failed"}
            if body.get("ReturnValuesOnConditionCheckFailure") == "ALL_OLD":
                err["Item"] = self.items[pk]
            return 400, err
        self.items[pk] = item
        return 200, {}

    def _run_task(self, body):
        token = body.get("clientToken")
        arn = self._by_token.get(token) if token else None
        if arn is None:
            arn = f"arn:aws:ecs:us-west-2:123456789012:task/c/{len(self.launched) + 1:032x}"
            self.launched.append(arn)
            if token:
                self._by_token[token] = arn
        return 200, {"tasks": [{"taskArn": arn}], "failures": []}
