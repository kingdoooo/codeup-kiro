import hmac
import os

TOKEN_HEADER = "x-codeup-token"


def verify_token(headers, expected):
    """常量时间比对 Codeup webhook 的共享密钥。

    Codeup 的 webhook 鉴权是**共享密钥而非 HMAC**：没有正文绑定、没有时间戳，
    所以它按设计可重放。重放防护由抢锁（N3）承担，这里只管「是不是我们的 webhook」。
    """
    if not expected:
        return False  # 密钥未配置时拒绝一切，绝不退化成放行
    got = None
    for k, v in (headers or {}).items():
        if k.lower() == TOKEN_HEADER:
            got = v
            break
    if not got:
        return False
    return hmac.compare_digest(str(got), str(expected))


def handler(event, context):
    expected = os.environ.get("WEBHOOK_SECRET", "")
    if not verify_token(event.get("headers"), expected):
        return {"statusCode": 401}
    return {"statusCode": 200}
