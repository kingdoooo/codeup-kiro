"""ALB Lambda target 的请求/响应形状。无第三方依赖，调度器与探测回显 Lambda 共用这一份。

入口是 CloudFront → VPC origin → 内网 ALB → Lambda target（spec「入口修订」）。ALB 与 Function URL
在两头的形状都不一样，这里集中处理：

- 响应（G5）：ALB 要求至少 statusCode、statusDescription、isBase64Encoded 齐全，缺了回 502——
  请求其实已被处理，Codeup 却记为投递失败，与 C1 同属静默失败。headers/body 也一并给全。
- 请求体（G6）：ALB 对 text/*、application/json 等类型原样转发，其它类型或带 content-encoding
  头时改为 base64（isBase64Encoded=true）。不能假设 Codeup 的 Content-Type 恰好落在原样转发的
  那几类里，所以一律先按 isBase64Encoded 解码成字节，再按 UTF-8 解成文本。
"""
import base64
from http import HTTPStatus


def resp(status, body=""):
    """ALB 可接受的完整响应。body 是纯文本，永远不走 base64。"""
    return {
        "statusCode": status,
        "statusDescription": f"{status} {HTTPStatus(status).phrase}",
        "isBase64Encoded": False,
        "headers": {"Content-Type": "text/plain; charset=utf-8"},
        "body": body,
    }


def body_bytes(event):
    """请求体原始字节；无正文返回 b""。

    base64 解码用 validate=True：掺了非法字符的正文要报错，而不是被悄悄丢掉几个字符后当成
    另一份正文——那样 P2a-08 的两端 SHA256 比对会在错误的地方失败。
    """
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return base64.b64decode(body, validate=True)
    return body.encode("utf-8")


def body_text(event):
    """请求体文本（UTF-8）；无正文返回 ""。

    解不开时抛 ValueError（binascii.Error 与 UnicodeDecodeError 都是它的子类），调用方据此
    归入「不可解析」，不猜（N6）。
    """
    return body_bytes(event).decode("utf-8")
