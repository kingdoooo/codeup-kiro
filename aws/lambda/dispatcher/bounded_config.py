"""两个 Lambda 所有 AWS 客户端共用的有界 botocore 配置（Secrets Manager、DynamoDB、ECS）。

botocore 的缺省是连接 60 s、读 60 s、legacy 重试（Secrets Manager 共 5 次、DynamoDB 共 10 次，
超时也重试）。本地 aws/.venv 里实测 `boto3.client("secretsmanager").meta.config` 就是这组值。
两个函数的超时都是 29 s，于是**一次卡住的调用就能耗尽整个预算**：
- 调度器：取密钥卡住 → Lambda 超时 → 固定形状的 `secret-unavailable` 那行日志根本没机会打出来，
  ALB 给的是函数超时而不是设计好的 503；RunTask 卡在抢锁之后 → 释放锁与「评审未启动」都不会执行，
  锁挂 24 h、MR 上一句话都没有（全分支复审 s1 F1、s4 M-B）。
- 兜底：卡住 → 超时 → 异步重试 → 最后被 Lambda 丢弃（Task 14 验收 (a) 实测过这个丢弃）。

所以每个客户端都用这里的配置。**单次调用最坏** = 尝试次数 × (连接超时 + 读超时) + 两次尝试之间的
退避（standard 模式第一次重试前最多 1 s；x-amz-retry-after 只在有响应时才生效）≈ 2 × (2 + 5) + 1
= 15 s。预算按「一次只有一个服务卡住」来算：调度器取密钥卡住时 15 s 内打出那行日志并回 503；
RunTask 卡住时 15 s 后还剩 14 s 做释放锁与留痕。几个服务同时卡住时仍可能超时——那时整条出网
链路多半已经断了，任何配置都救不回来。

重试会重发非幂等写入（issue 02），两处各有自己的去重：RunTask 的 clientToken 由 SDK 每次调用生成一次、
重试复用，ECS 按它返回原来那个任务；抢锁的 PutItem 已提交、应答却超时时，重试撞上的是本调用自己写的
记录，handler.claim 靠 claim_id + ALL_OLD 认出来。读超时仍不取得更小：每多一次这种重试就多等一轮，
而正常请求的延迟是毫秒级，5 s 只会切断真正卡住的连接。

`total_max_attempts` 而不是 `max_attempts`：写在 Config 对象里的 max_attempts **不含**首次请求
（boto3 文档 guide/retries.html），total_max_attempts 才是「一共几次」。
"""

CONNECT_TIMEOUT = 2
READ_TIMEOUT = 5
TOTAL_MAX_ATTEMPTS = 2


def worst_case_seconds():
    """单次调用在这组配置下的最坏耗时（秒），供测试与注释核对预算。

    standard 模式第 n 次重试之前的退避上限是 min(2^(n-1), 20) 秒（botocore retries/standard.py 的
    ExponentialBackoff：random() × 2^(attempt-1)，封顶 20）。
    """
    backoff = sum(min(2 ** i, 20) for i in range(TOTAL_MAX_ATTEMPTS - 1))
    return TOTAL_MAX_ATTEMPTS * (CONNECT_TIMEOUT + READ_TIMEOUT) + backoff


def client_config():
    """每次新建一份 Config（它是不可变的值对象，调用方直接传给 boto3.client/resource）。"""
    from botocore.config import Config
    return Config(connect_timeout=CONNECT_TIMEOUT, read_timeout=READ_TIMEOUT,
                  retries={"mode": "standard", "total_max_attempts": TOTAL_MAX_ATTEMPTS})
