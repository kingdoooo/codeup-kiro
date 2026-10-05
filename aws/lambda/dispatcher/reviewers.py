"""评审员档案的 Lambda 侧常量表（Phase 2b spec「评审员档案」）。

bash 侧那一份在 scripts/lib/review-render.sh 开头（REVIEW_PROFILE）。两份逐项比对由
aws/tests/test_reviewer_profiles.py 做：它读 bash 那边 source 之后的**真实值**，不在测试里再抄第三份。

调度器与兜底 Lambda 都 import 本文件（兜底经 CodeupMinLayer 的 /opt/dispatcher，与 codeup_min 同一手法）。
Kiro 的两个 Lambda 侧标记保持 2a 的无后缀形态（`<!-- kiro-backstop -->`、`<!-- kiro-dispatch-failed -->`）：
它们已经出现在真实 MR 上，换名没有收益。扫描员的带 `-<rid>` 后缀（`<!-- kiro-backstop-<rid> -->`、
`<!-- kiro-dispatch-failed-<rid> -->`，不带冒号载荷），仍在 `<!-- kiro-` 族里（调度器断环 N5 只认这个前缀）。
"""

# 固定顺序：REVIEWERS 环境变量按这个顺序拼，日志与测试都依赖它稳定
ORDER = ("kiro", "inspector", "security")
SCANNERS = ("inspector", "security")

PROFILES = {
    "kiro": {
        "marker_name": "kiro-review",
        "title": "Kiro 代码评审",
        "lambda_heading": "## 🤖 Kiro 代码评审",
        "backstop_marker": "<!-- kiro-backstop -->",
        "dispatch_failed_marker": "<!-- kiro-dispatch-failed -->",
        # Lambda 环境变量：放的是 Secrets Manager 的**密钥名**（secret_fetch.secret_from_env 的入参），不是值
        "token_secret_env": "YUNXIAO_TOKEN_ID",
        "secret_name": "codeup-kiro/yunxiao-token-kiro",
        # config.yaml 的开关键；Kiro 总是启用（None）
        "toggle": None,
    },
    "inspector": {
        "marker_name": "kiro-inspector-review",
        "title": "Inspector 依赖漏洞扫描",
        "lambda_heading": "## 🤖 Inspector 依赖漏洞扫描",
        "backstop_marker": "<!-- kiro-backstop-inspector -->",
        "dispatch_failed_marker": "<!-- kiro-dispatch-failed-inspector -->",
        "token_secret_env": "YUNXIAO_TOKEN_INSPECTOR_ID",
        "secret_name": "codeup-kiro/yunxiao-token-inspector",
        "toggle": "inspector",
    },
    "security": {
        "marker_name": "kiro-security-review",
        "title": "Security Agent 安全评审",
        "lambda_heading": "## 🤖 Security Agent 安全评审",
        "backstop_marker": "<!-- kiro-backstop-security -->",
        "dispatch_failed_marker": "<!-- kiro-dispatch-failed-security -->",
        "token_secret_env": "YUNXIAO_TOKEN_SECURITY_ID",
        "secret_name": "codeup-kiro/yunxiao-token-security",
        "toggle": "security_agent",
    },
}


def parse(raw):
    """REVIEWERS 环境变量的严格解析（N7 扩写）：逗号分隔、每项是已知评审员、不重复、非空。

    返回按 ORDER 排好的元组。任何不合形状的取值都抛 ValueError——绝不回落默认：拼错的 REVIEWERS 静默按
    「只有 Kiro」处理，就是某位评审员悄无声息地不再出现在 MR 上。
    """
    if type(raw) is not str or not raw:
        raise ValueError("REVIEWERS 为空或不是字符串")
    items = raw.split(",")
    if any(i not in PROFILES for i in items) or len(set(items)) != len(items):
        raise ValueError("REVIEWERS 含未知或重复的评审员")
    return tuple(r for r in ORDER if r in items)


def join(rids):
    """按 ORDER 拼成 REVIEWERS 环境变量的取值（parse 的逆）。"""
    return ",".join(r for r in ORDER if r in rids)


def enabled(cfg):
    """config 里启用了的评审员（Kiro 总在），按 ORDER。开关的取值校验在 aws/config.py；这里仍按 `type(v) is int`
    判断：`True == 1` 在 Python 里成立，只写 `== 1` 会把绕过 load_config 传进来的布尔值当成「启用」（2a 的同一个坑）。"""
    def on(key):
        v = cfg.get(key)
        return type(v) is int and v == 1
    return tuple(r for r in ORDER if PROFILES[r]["toggle"] is None or on(PROFILES[r]["toggle"]))
