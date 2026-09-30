"""调用时向 Secrets Manager 取密钥的值。两个 Lambda 共用这一份，不维护简化副本。

为什么不把值注入环境变量：CloudFormation 动态引用能让**模板**里不出现明文，但部署后的函数
配置里存的仍是明文，任何能 `lambda:GetFunctionConfiguration` 的主体都读得到——与 ECS 任务
定义的 `secrets{}` 块（值从不出现在任务定义里）不是同一档安全性。Lambda 环境变量没有对应的
运行时机制，只能自己在调用时取（Ruling 16）。所以环境变量里只放密钥的 **SecretId**。

SecretId 是 GetSecretValue 的入参名，接受完整 ARN 或密钥名；这里放的是**密钥名**。不放
partial ARN 的理由见 AWS 文档 secretsmanager/latest/userguide/troubleshoot.html 的
「An AWS CLI or AWS SDK operation can't find my secret from a partial ARN」：密钥名以
「连字符 + 六个字符」结尾时（`codeup-kiro/webhook-secret` 的末段 `secret` 正好如此），
partial ARN 会被当成完整 ARN 解析、从而找不到密钥，文档建议用完整 ARN 或密钥名；而完整 ARN
的六位后缀要调 AWS API 才知道，CDK 在 synth 期给不出来（见 stacks/dispatcher_stack.py 的注释）。

兜底 Lambda 与本文件不同目录：靠 CodeupMinLayer 把整个 `lambda/` 铺到 `/opt`、按
`/opt/dispatcher` 导入，与 codeup_min 同一手法，不另建 layer（见 backstop/handler.py 顶部）。

文件名刻意**不叫** `secrets.py`：`/var/task` 与 `/opt/dispatcher` 都排在标准库之前，同名文件会
在整个 Lambda 进程里遮蔽标准库的 `secrets` 模块——今天没有依赖会踩到，但将来任何一处
`import secrets`（boto3/botocore 或标准库自身的变化）都会拿到这份，而 synth 与单测都接不住。
"""
import os
import time

# 按进程缓存：Lambda 执行环境跨调用复用，不必每次调用都取。键用 SecretId，同一个函数里的两个
# 密钥不会互相串；值是 (value, 取到时的单调钟, 取到时的墙钟)。**只缓存取到的非空值**——失败绝不入缓存，否则一次
# 限流会把这个执行环境钉死在失败态直到它被回收，期间每个 webhook 都被拒。下一次调用必须能重试。
_CACHE = {}

# 缓存项的寿命（issue 05 G2）。以前永不过期，而手册教轮换令牌：轮换并吊销旧值之后，热执行环境
# 一直拿旧值（Lambda 不承诺执行环境的最长寿命，持续有流量时可能是几个小时）——兜底的重试多半落在
# 同一个热环境里、同样 401。5 分钟：轮换后两个函数最多 5 分钟都用上新值、重试耗尽后的回放拿得到新值，
# GetSecretValue 的费用与配额可以忽略。过期之后重取失败就照常抛，**绝不**回退到旧值——旧值在
# 轮换场景下恰恰是错的。setup-guide.md 里写的「5 分钟」由测试从这个数算出来。
# 单调钟**与**墙钟任一走满 TTL 就算过期：Lambda 冻结执行环境期间 time.monotonic() 是否照常前进没有第一手证据
# （不前进的话，低流量时缓存会远远活过 5 分钟）；墙钟被校时拨动最多只让缓存提前过期、多取一次，无害。
CACHE_TTL_SECONDS = 300


class SecretUnavailable(RuntimeError):
    """取不到密钥：环境变量缺失或为空、GetSecretValue 失败、密钥值为空。

    消息里只有环境变量名，绝不带原始异常正文——GetSecretValue 的错误正文是自由文本，带调用方
    角色 ARN 与账号 ID（与 handler.py 的 _failure_reason 同一条理由）。原始异常挂在 `__cause__`
    上供排查；要给运维一个可分辨的代号时经 `_failure_reason` 取 AWS 错误码，不要 `str(__cause__)`。

    `reason` 是**没有** `__cause__` 时的固定代号（`env-unset` / `empty-value`）：这两种失败根本
    没走到 AWS 调用，从异常类型上区分不出来，而运维最需要先分清的恰好是「我没配」还是「AWS 拒了」。
    有 `__cause__` 时 `reason` 为 None，调用方改用 `_failure_reason(exc.__cause__)` 取 AWS 错误码。
    固定枚举、绝不含自由文本，所以可以安全地打进日志。
    """

    def __init__(self, var_name, reason=None):
        super().__init__(var_name)
        self.var_name = var_name
        self.reason = reason


def secret_from_env(var_name):
    """读环境变量 `var_name` 里的 SecretId（密钥名），返回该密钥的值；取不到一律抛 SecretUnavailable。

    入参是**变量名**而不是 SecretId 本身：调用点因此不可能把密钥值当 SecretId 传进来，也让
    「变量没配好」与「密钥取不到」落在同一条 fail-closed 路径上，由调用方一处处理。
    """
    secret_id = os.environ.get(var_name) or ""
    # 空串按配置错误处理，不退化成任何默认值：`os.environ.get(var, default)` 那种写法会让
    # WEBHOOK_SECRET_ID="" 静默走进「没配就用默认」，正是本轮要消灭的一类静默失败
    # （falsy 但有意义）。
    if not secret_id:
        raise SecretUnavailable(var_name, "env-unset")
    hit = _CACHE.get(secret_id)
    if hit is not None:
        value, at_mono, at_wall = hit
        if (time.monotonic() - at_mono < CACHE_TTL_SECONDS
                and abs(time.time() - at_wall) < CACHE_TTL_SECONDS):
            return value
        del _CACHE[secret_id]   # 过期：先扔掉，重取失败时缓存里不留旧值
    import boto3  # 沿用本仓库写法：boto3 在函数内部 import（见 backstop/handler.py 的 handler）
    import bounded_config  # 同目录；兜底 Lambda 经 /opt/dispatcher 导入，与本文件同一手法
    try:
        # 有界配置是承重的：缺省的 60 s 读超时 + legacy 重试会让一次卡住的调用耗尽 29 s 的函数预算，
        # 调用方那行 `secret-unavailable` 日志就永远打不出来（见 bounded_config.py）。
        resp = boto3.client("secretsmanager", config=bounded_config.client_config()) \
            .get_secret_value(SecretId=secret_id)
    except Exception as exc:  # noqa: BLE001 — 权限、限流、密钥不存在、瞬时网络错误都要落到同一条
                              # fail-closed 路径；只挑几种已知异常会让其余的逃成 Lambda 500
        raise SecretUnavailable(var_name) from exc
    value = resp.get("SecretString") or ""
    # 空字符串与只有 SecretBinary（没有 SecretString）都算「没取到」：两个 Lambda 要的都是文本
    # 令牌。让空值继续往下走，会把「密钥建错了」显示成「对方令牌不对」（401），运维照着 401
    # 去查 Codeup 那侧，永远查不到真正的原因。
    if not value:
        raise SecretUnavailable(var_name, "empty-value")
    _CACHE[secret_id] = (value, time.monotonic(), time.time())
    return value
