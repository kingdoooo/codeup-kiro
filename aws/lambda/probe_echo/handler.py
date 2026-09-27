"""P2a-08 探测栈的回显 Lambda：站在生产调度器的位置上，证明入口把 Codeup 的 POST 原样送到了这里。

往日志写一行 JSON（请求头、isBase64Encoded、解码后正文的 SHA256 与文本），响应正文是解码后正文
**字节**的 SHA256 十六进制——curl 端拿它与本地算的哈希比对。REDACTED_HEADERS 里那几个头的值
换成 `<redacted len=N>`：长度够判断令牌有没有被截断，值本身不进日志。

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

# Task 1 实测：Codeup 每次投递都带**两个**令牌头——`X-Codeup-Token` 与 `X-Gitlab-Token`
# （它的 webhook 实现沿用了 GitLab 的头名）。**实测到的是**：两个头都带明文令牌、长度相同
# （各 48 位十六进制，与生成的那个一次性令牌等长）。「两个值逐字相同」是按 GitLab 兼容语义
# **推断**的，没有做过逐字节比对——这个区别不影响下面的做法，因为打码是按**头名**做的，
# 与两个值是否相等无关。只打码前者时一次性探测令牌就以明文进了日志（本轮真的发生过）。
# 所以这里是一个名单，不是单个头名；
# 名单项一律小写，比对时把实际头名 `.lower()`（ALB 不保证转发头名的大小写）。
# 注意：这只约束**回显日志**。生产调度器仍然只读 `x-codeup-token` 校验（handler.py::verify_token），
# 不接受 `x-gitlab-token` 作为替代——多认一个头就是多一条绕过面。
REDACTED_HEADERS = ("x-codeup-token", "x-gitlab-token")


def _redacted_headers(headers):
    return {k: (f"<redacted len={len(v or '')}>" if k.lower() in REDACTED_HEADERS else v)
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
