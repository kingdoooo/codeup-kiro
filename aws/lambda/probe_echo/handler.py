"""P2a-08 探测栈的回显 Lambda：站在生产调度器的位置上，证明入口把 Codeup 的 POST 原样送到了这里。

往日志写一行 JSON（请求头、isBase64Encoded、解码后正文的 SHA256 与文本），响应正文是解码后正文
**字节**的 SHA256 十六进制——curl 端拿它与本地算的哈希比对。x-codeup-token 的值换成
`<redacted len=N>`：长度够判断令牌有没有被截断，值本身不进日志。

正文解码复用调度器的同一份 http_shape（不另写一份）：探测验证的必须是生产的解码路径。
"""
import hashlib
import json
import os
import sys

# Lambda 运行时里 http_shape 由 layer 铺到 /opt/dispatcher（与兜底 Lambda 导入 codeup_min 同一手法）；
# 本地 pytest 时由测试文件把 lambda/dispatcher 加进 sys.path。条件式插入，理由见 backstop/handler.py。
if os.path.isdir("/opt/dispatcher"):
    sys.path.insert(0, "/opt/dispatcher")
import http_shape  # noqa: E402

TOKEN_HEADER = "x-codeup-token"


def _redacted_headers(headers):
    return {k: (f"<redacted len={len(v or '')}>" if k.lower() == TOKEN_HEADER else v)
            for k, v in (headers or {}).items()}


def handler(event, context):
    raw = http_shape.body_bytes(event)
    digest = hashlib.sha256(raw).hexdigest()
    record = {"headers": _redacted_headers(event.get("headers")),
              "isBase64Encoded": event.get("isBase64Encoded"),
              "body_sha256": digest}
    try:
        record["body_text"] = http_shape.body_text(event)
    except ValueError as exc:  # 非 UTF-8 正文：哈希照样回，日志注明解不开，而不是让探测本身 502
        record["body_text"], record["body_text_error"] = None, type(exc).__name__
    print(json.dumps(record, ensure_ascii=False), flush=True)
    return http_shape.resp(200, digest)
