"""调用时向 Secrets Manager 取密钥的值。两个 Lambda 共用这一份，不维护简化副本。

为什么不把值注入环境变量：CloudFormation 动态引用能让**模板**里不出现明文，但部署后的函数
配置里存的仍是明文，任何能 `lambda:GetFunctionConfiguration` 的主体都读得到——与 ECS 任务
定义的 `secrets{}` 块（值从不出现在任务定义里）不是同一档安全性。Lambda 环境变量没有对应的
运行时机制，只能自己在调用时取（Ruling 16）。所以环境变量里只放密钥 **ARN**。

兜底 Lambda 与本文件不同目录：靠 CodeupMinLayer 把整个 `lambda/` 铺到 `/opt`、按
`/opt/dispatcher` 导入，与 codeup_min 同一手法，不另建 layer（见 backstop/handler.py 顶部）。

文件名与标准库 `secrets` 同名，而 Lambda 把函数根目录放在 sys.path 最前——进程内
`import secrets` 会一律命中本文件。已审计过这层遮蔽：给 `builtins.__import__` 打桩跑
`import boto3`，整个导入图里唯一导入标准库 `secrets` 的是 `multiprocessing.shared_memory`，
它只在 `_make_filename()`（创建共享内存段）里用 `secrets.token_hex`，两个 Lambda 都不走
那条路；boto3/botocore/urllib3 自身没有任何一处 `import secrets`。故遮蔽无害。
将来若引入会用标准库 `secrets` 的依赖（JWT、随机 nonce 之类），这个文件必须改名。
"""
import os

# 按进程缓存：Lambda 执行环境跨调用复用，冷启动取一次就够。键用 ARN，同一个函数里的两个
# 密钥不会互相串。**只缓存取到的非空值**——失败绝不入缓存，否则一次限流会把这个执行环境
# 钉死在失败态直到它被回收，期间每个 webhook 都被拒。下一次调用必须能重试。
_CACHE = {}


class SecretUnavailable(RuntimeError):
    """取不到密钥：环境变量缺失或为空、GetSecretValue 失败、密钥值为空。

    消息里只有环境变量名，绝不带原始异常正文——GetSecretValue 的错误正文是自由文本，带调用方
    角色 ARN 与账号 ID（与 handler.py 的 _failure_reason 同一条理由）。原始异常挂在 `__cause__`
    上供排查；要给运维一个可分辨的代号时经 `_failure_reason` 取 AWS 错误码，不要 `str(__cause__)`。
    """


def secret_from_env(var_name):
    """读环境变量 `var_name` 里的密钥 ARN，返回该密钥的值；任何取不到的情形都抛 SecretUnavailable。

    入参是**变量名**而不是 ARN 本身：调用点因此不可能把值当 ARN 传进来，也让「变量没配好」与
    「密钥取不到」落在同一条 fail-closed 路径上，由调用方一处处理。
    """
    arn = os.environ.get(var_name) or ""
    # 空串按配置错误处理，不退化成任何默认值：`os.environ.get(var, default)` 那种写法会让
    # WEBHOOK_SECRET_ARN="" 静默走进「没配就用默认」，正是本轮要消灭的一类静默失败
    # （falsy 但有意义）。
    if not arn:
        raise SecretUnavailable(var_name)
    if arn in _CACHE:
        return _CACHE[arn]
    import boto3  # 沿用本仓库写法：boto3 在函数内部 import（见 backstop/handler.py 的 handler）
    try:
        resp = boto3.client("secretsmanager").get_secret_value(SecretId=arn)
    except Exception as exc:  # noqa: BLE001 — 权限、限流、密钥不存在、瞬时网络错误都要落到同一条
                              # fail-closed 路径；只挑几种已知异常会让其余的逃成 Lambda 500
        raise SecretUnavailable(var_name) from exc
    value = resp.get("SecretString") or ""
    # 空字符串与只有 SecretBinary（没有 SecretString）都算「没取到」：两个 Lambda 要的都是文本
    # 令牌。让空值继续往下走，会把「密钥建错了」显示成「对方令牌不对」（401），运维照着 401
    # 去查 Codeup 那侧，永远查不到真正的原因。
    if not value:
        raise SecretUnavailable(var_name)
    _CACHE[arn] = value
    return value
