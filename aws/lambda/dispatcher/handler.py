import hmac
import json
import os
import re
import time
import uuid

import botocore.exceptions

import codeup_min
import secret_fetch  # 本目录下的 secret_fetch.py：调用时向 Secrets Manager 取密钥
# 入口是内网 ALB 的 Lambda target：每条返回路径都走 _resp（G5），正文一律经 _body_text 取（G6）。
from http_shape import body_text as _body_text
from http_shape import resp as _resp

TOKEN_HEADER = "x-codeup-token"
# 真实头名是 `X-Codeup-Event`，ALB 交给 Lambda 时小写成 `x-codeup-event`（Task 1 实测）。名字写错
# 不会有任何报错——`classify` 会把**每一个**投递都判 ignore，部署出去一切健康却一条评审都不跑。
EVENT_HEADER = "x-codeup-event"
MR_EVENT = "merge request hook"
NOTE_EVENT = "note hook"
# 本方评论的标记**前缀**，不是某一种标记：评审脚本至少写四种（`<!-- kiro-review:<sha> run:N -->`、
# `<!-- kiro-review-post:<nonce> -->`、`<!-- kiro-history:[…] -->`、行内评论的
# `<!-- kiro-inline:<指纹> L<起>-<止> sev=P<n> -->`，见 scripts/lib/review-render.sh），
# 调度器与兜底 Lambda 自己的失败评论又各有一种。只认 `<!-- kiro-review:` 的话，行内评论（AWS 档位
# 有 inline_comment 开关）一旦正文里带上命令短语就会触发新一轮评审，而机器人与人可以是同一个账号
# （Task 1 实测）→ 作者名单也断不了环 → 无穷循环。按前缀认，本方写出去的任何一种标记都能断环。
# 模型文本里的 `<!--` 已被 scripts 侧 _sanitize_md 转义，所以不受信内容伪造不出这一行。
REVIEW_MARKER = "<!-- kiro-"
# 调度器与兜底 Lambda 的失败评论各自的标记。它们不经评审脚本渲染，所以必须自己带上，否则
# 「拉起任务持续失败」就会变成：失败评论 → Note Hook → 又一次评审 → 又一条失败评论（每次都是
# 新的 note_biz_id，抢锁拦不住）。取值刻意不带冒号参数，与脚本那几种（`kiro-xxx:<载荷>`）区分开。
# （兜底 Lambda 的那一个叫 `<!-- kiro-backstop -->`，定义在 backstop/handler.py 里——它自己发那条
# 评论，标记跟着发出去的地方走；断环这侧按前缀认，不需要逐个枚举。）
DISPATCH_FAILED_MARKER = "<!-- kiro-dispatch-failed -->"


def token_header(headers):
    """按大小写不敏感取 `x-codeup-token`；没有这个头、或它的值为空都返回 ""。

    verify_token 与 handler 都要判断「这次请求带没带令牌」，这里只写一份：两处各自遍历一遍
    headers，迟早会在大小写或空值的处理上分叉（ALB 转发的头名大小写不保证）。
    """
    for k, v in (headers or {}).items():
        if k.lower() == TOKEN_HEADER:
            return v or ""
    return ""


def verify_token(headers, expected):
    """常量时间比对 Codeup webhook 的共享密钥。

    Codeup 的 webhook 鉴权是**共享密钥而非 HMAC**：没有正文绑定、没有时间戳，
    所以它按设计可重放。重放防护由抢锁（N3）承担，这里只管「是不是我们的 webhook」。
    """
    if not expected:
        return False  # 密钥未配置时拒绝一切，绝不退化成放行
    got = token_header(headers)
    if not got:
        return False
    # 按 bytes 比（issue 05 G1）：str 版 compare_digest 遇到非 ASCII 抛 TypeError，未鉴权的调用方就拿到
    # 502 而不是 401；配置的密钥本身非 ASCII 时连带对令牌的投递也 502。surrogatepass：ALB 转来的头里
    # 若有孤立代理项也编得出来，照样 fail closed。常量时间的性质不变。
    return hmac.compare_digest(str(got).encode("utf-8", "surrogatepass"),
                               str(expected).encode("utf-8", "surrogatepass"))


def _dig(d, *path, default=None):
    """按路径取值；中途遇到非字典、缺键或 None 都返回 default。

    报文形状不符合预期时不猜（N6）：容错取值 + 上层「任一必需字段缺失就 ignore」，
    比在半个报文上硬取字段安全。
    """
    cur = d
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur if cur is not None else default


def _scalar(v):
    """把报文里的标量转成字符串；缺失或形状不对返回 None。

    两件事各自都会变成静默故障：
    - `project_id` / `local_id` 在真实报文里是**整数**，而 containerOverrides.environment 的值
      必须是字符串（run_task 会 str() 一遍，但 fields 里就保持字符串，免得别处再各自转一次）。
    - 判「缺失」用显式的 `None` 判断，**不用真值判断**：`local_id == 0` 是合法序号，`if not v`
      会把它当成缺失、于是那条 MR 静默不评（falsy 但有意义）。
    字典/列表/浮点/布尔出现在这几个位置就是报文形状不对：`str({"a": 1})` 会把一个字典原样塞进
    CODEUP_REPO_ID，那比 ignore 糟得多。bool 要单独挡——Python 里 `isinstance(True, int)` 为真。
    """
    if v is None or isinstance(v, bool) or not isinstance(v, (str, int)):
        return None
    s = str(v).strip()
    return s or None


def _event_name(headers):
    """大小写不敏感地取事件头（ALB 转发的头名大小写不保证），取值也归一。"""
    for k, v in (headers or {}).items():
        if k.lower() == EVENT_HEADER:
            return str(v).strip().lower()
    return ""


def _fields_from(mr, repo):
    """从 MR 主体与 repository 抽出评审需要的六个标量；任一必需字段缺失返回 None。

    `mr` 是 MR Hook 的 `object_attributes`，或 Note Hook 的 `merge_request`——两者的字段名相同，
    只是挂的位置不同（Task 1 结论文件 §1），所以抽取只写一份。
    `dedupe_extra` 统一产出空串而不是 None（I5）：MR 事件没有评论 id，但缺失的可选值必须是 ""。
    """
    fields = {
        "repo_id": _scalar(_dig(mr, "project_id")),
        "mr_local_id": _scalar(_dig(mr, "local_id")),
        "source_branch": _scalar(_dig(mr, "source_branch")),
        "target_branch": _scalar(_dig(mr, "target_branch")),
        "head_sha": _scalar(_dig(mr, "last_commit", "id")),
        "clone_url": _scalar(_dig(repo, "git_http_url")),
    }
    if any(v is None for v in fields.values()):
        return None
    fields["dedupe_extra"] = ""
    return fields


# 报文取来的标量在往下走之前必须逐个过形状：它们会变成 clone 的 URL、`git checkout` 的参数、
# 锁键的组成部分。webhook 鉴权只是一个共享密钥（可重放、无正文绑定），谁拿到它就能把
# `repository.git_http_url` 写成任意主机——执行器的 credential helper 会把云效组织令牌交给那台
# 主机，等于把弱密钥升级成组织令牌。执行器那侧另有一道主机检查（深度防御），这里是最便宜的一道。
CODEUP_HOST = "codeup.aliyun.com"
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_DIGITS_RE = re.compile(r"^[0-9]+$")   # 不用 str.isdigit()：它对 "٣"、"²" 这类也为真
_CTRL_OR_SPACE_RE = re.compile(r"[\s\x00-\x1f\x7f]")
# `%` 整条拒绝，不只拒绝 `%2e`：字面量 `..` 的检查对百分号编码无效——`/<org>/%2e%2e/%2e%2e/other-org/x.git`
# 与 `/<org>/.%2e/…` 两种写法都能绕过它（Task 5 复审 B-1 实测），而这道检查的目的正是「不许爬出本组织」。
# 云效那侧会不会把 `%2e%2e` 解码再归一成上级目录没有实测过（未知），所以按 fail closed 处理。
# 真实报文里不会出现 `%`：Task 1 抓到的六个 fixture 的 git_http_url 一个都没有（tests 里有守卫）。
_URL_UNSAFE_RE = re.compile(r"[@?#%\s\x00-\x1f\x7f]|\.\.")
# 评论命令的去重键：真实 Note Hook 的 note_biz_id 是 32 位小写十六进制（Task 1 抓到的两个评论
# fixture 都是）。它会原样进 LOCK_KEY → 容器环境变量与 DynamoDB 主键，所以必须过形状。
_NOTE_BIZ_ID_RE = re.compile(r"^[0-9a-f]{32}$")
# Note 报文里 MR 已经合并/关闭时不受理命令：那时评审无处落地（新评论只会挂在一个已结束的 MR 上），
# 而抢锁又拦不住（每条评论都是新的 note_biz_id）。**只挡云效文档列出的这两个取值**，其余（含没见过的词）
# 一律放行：`merge_request.state` 与 MR 报文的 state 不是同一套取值（MR 已通过时前者仍是 `opened`，
# Task 1 实测），而 merged/closed 本身只见于云效文档、没有实测样本（Task 1 结论文件 §1 第 61 行）。
# 若哪天云效换了词，失败方向是「照常评审」而不是「命令静默失效」。
NOTE_CLOSED_STATES = frozenset({"merged", "closed"})


def _reject_reason(fields, cfg):
    """报文形状不可信时给一个固定代号，可信时给 ""。代号是固定枚举，不含报文里的任何取值。"""
    org = str(cfg.get("org_id") or "")
    if not org:
        return "org-unset"          # 组织 id 没配就无从判断 clone 地址属不属于我们，fail closed
    if not fields["clone_url"].startswith(f"https://{CODEUP_HOST}/{org}/"):
        return "clone-url-prefix"   # 主机 + 组织都必须是我们自己的
    if _URL_UNSAFE_RE.search(fields["clone_url"]):
        # `@` 会让 `https://codeup.aliyun.com/<org>/x@evil/…` 之类把 userinfo 挪到前面；
        # `?`/`#`/`..` 可以改写 git 看到的路径；`%` 能把 `..` 藏成 `%2e%2e`（见 _URL_UNSAFE_RE 上方）；
        # 空白与控制字符能把一行参数拆成两行。
        return "clone-url-chars"
    if not _SHA_RE.match(fields["head_sha"]):
        return "head-sha"           # 会变成 `git checkout` 的参数：只接受 40 位小写十六进制
    if not _DIGITS_RE.match(fields["repo_id"]):
        return "repo-id"
    if not _DIGITS_RE.match(fields["mr_local_id"]):
        return "mr-local-id"
    for key in ("source_branch", "target_branch"):
        value = fields[key]
        # 以 `-` 开头的分支名会被 git 当成选项；空白与控制字符同上。空串 _scalar 已经挡过一次，
        # 这里再判一次是因为这个函数是「往下走之前的最后一道」，不依赖上游的顺序。
        if not value or value.startswith("-") or _CTRL_OR_SPACE_RE.search(value):
            return "branch"
    extra = fields.get("dedupe_extra") or ""
    # 评论 id 只有评论命令那条路径才有；MR 事件是空串（既有约定：缺失与空串一致），不检查。
    # 有值就必须是 32 位小写十六进制——它会进 LOCK_KEY，而锁键是容器环境变量与 DynamoDB 主键。
    if extra and not _NOTE_BIZ_ID_RE.match(extra):
        return "note-biz-id"
    return ""


def _log_ignored(reason):
    """忽略这次投递时留下的那一行固定形状日志：`ignored reason=<代号>`。

    只有一处 print（`_accept` 与评论命令的状态门都走它）：形状分叉了 setup-guide 的排错表就只对一半
    路径成立，而运维是按 `reason=` 过滤的。代号是固定枚举，绝不带报文里的取值。
    """
    print(f"ignored reason={reason}", flush=True)


def _accept(fields, cfg):
    """最后一道形状检查。不可信时打一行固定形状日志并返回 False。

    为什么要留日志：这条路径与「正常的 ignore」（approve、非推送 update、分支不匹配）在响应上
    完全一样（200 ignored），而它意味着有人拿着 webhook 密钥在改报文，或者报文格式变了——两种
    都必须能在日志里看见。形状固定、只有代号，按 `reason=` 过滤；绝不打印报文里的取值（那是
    攻击者可控的自由文本，会污染日志，也可能带令牌）。正常的 ignore 一行都不打（否则这条
    信号就被淹没了）。
    """
    reason = _reject_reason(fields, cfg)
    if reason:
        _log_ignored(reason)
        return False
    return True


def _branch_allowed(target, cfg):
    """目标分支过滤：过滤器为空表示不过滤。

    正则配错时 fail closed 并留一行固定形状日志：让 re.error 逃出去就是 ALB 502，Codeup 只看到
    投递失败（与 C1 同属静默失败），而且四类成因在响应里完全一样。日志里不带正则本身——它是
    自由文本，与 _failure_reason 同一条理由。
    """
    pattern = cfg.get("target_branch_filter") or ""
    if not pattern:
        return True
    try:
        return bool(re.search(pattern, target or ""))
    except re.error:
        print("bad-target-branch-filter var=TARGET_BRANCH_FILTER", flush=True)
        return False


def classify(headers, body, cfg):
    """决定这次投递要不要评审，并抽出评审所需的标量。

    返回 ("review", fields) 或 ("ignore", None)。未知事件与未知报文形状一律 ignore —— 不猜（N6）。

    两条 Task 1 实测的事实：①同一次投递最多到 3 次（我们回 503 时 Codeup 在约 1 秒内立即重试 2 次，
    `X-Codeup-Delivery` 不变），靠幂等抢锁（N3）吸收，classify 不去重（只影响注释，不影响逻辑）；
    ②Note 报文里的 `merge_request.state` 与 MR 报文的 `state` 不是同一套取值（MR 已通过时前者仍是
    `opened`），所以评论分支**不**照抄 MR 分支的 `== "opened"`，只挡云效文档列出的 merged/closed（没有实测样本）
    （NOTE_CLOSED_STATES），别的取值一律放行。
    """
    ev = _event_name(headers)

    if ev == MR_EVENT:
        # state/action 归一大小写再比：Codeup 自己就不统一（MR 报文的 state 是 `opened`，Note 报文
        # 里那个是 `OPENED`），逐字比一旦对方改了大小写就是「一条都不评」的静默失败。
        # 这两道排在抽字段**之前**（它们直接读报文）：这样下面「缺字段」那行日志只会出现在本该评审的
        # 事件上，批准、改标题这类正常的 ignore 不会因为报文里恰好缺个字段而刷日志。
        if _norm(_dig(body, "object_attributes", "state")) != "opened":
            return "ignore", None            # 通过 = accepted（Task 1 实测），不是新评审
        if (_norm(_dig(body, "object_attributes", "action")) == "update"
                and _dig(body, "object_attributes", "is_update_by_push") is False):
            return "ignore", None            # 非推送的 update 没有新代码；字段缺失时不走这条
        fields = _fields_from(_dig(body, "object_attributes"), _dig(body, "repository"))
        if fields is None:
            # 本该评审的事件缺了必需字段（或字段不是标量）：报文格式变了，或者有人在改报文。
            # 以前这里一行日志都没有——每一次评审都静默停掉、部署看上去完全健康（复审 s3 M-1）。
            _log_ignored("missing-field")
            return "ignore", None
        if not _branch_allowed(fields["target_branch"], cfg):
            return "ignore", None
        if not _accept(fields, cfg):
            return "ignore", None
        return "review", fields

    if ev == NOTE_EVENT:
        if not cfg.get("review_command"):
            return "ignore", None
        if _dig(body, "object_attributes", "system") is True:
            return "ignore", None
        author = _dig(body, "user", "username", default="")
        if not isinstance(author, str):
            # 形状不明的作者一律 ignore（N6）。顺带也挡住成员判断本身：作者字段是个字典时
            # `{...} in set(...)` 会因为不可哈希抛 TypeError → 逃出 handler → ALB 502。
            # 作者名**缺失或为空**不走这条：缺失与空串行为一致（既有约定），空串不可能等于某个
            # 真实的机器人用户名，而断环真正承重的是下面那道 kiro-review 标记；若因为缺这个字段就
            # ignore，Codeup 哪天不发 user.username，评论命令就整体静默失效。
            return "ignore", None
        if author in (cfg.get("bot_usernames") or []):
            return "ignore", None            # N5：本方评论会触发 Note Hook，必须断环
        note = _dig(body, "object_attributes", "note", default="")
        if not isinstance(note, str):
            return "ignore", None
        if REVIEW_MARKER in note:
            # 本方评审评论。**不能只靠作者名单**：本方机器人与人可以是同一个账号（Task 1 实测，
            # Kent 的 demo 里 Flow 的评审评论作者就是 MR 作者本人），那时名单里要么没这个人
            # （断不了环）、要么有（把人的命令一起吞掉）。而 AWS 档位的页脚按
            # pipeline/setup-guide.md 会写「评论 `/kiro review` 可重新评审」——评审评论正文里
            # 就带着命令短语，少了这道守卫就是评审触发自己的无穷循环。
            # 留一行日志：机器人与人同号时，人贴了标记的那条评论里的命令会在这里被吞掉，
            # 不留痕的话「命令静默失效」查不下去（复审 s5 I-1）。本方评论也会打这一行，量是每次评审一两行。
            _log_ignored("kiro-marker")
            return "ignore", None
        phrase = cfg.get("command_phrase") or ""
        if not phrase:
            # falsy 但有意义：`"" in note` 恒真 → 每条评论都触发评审（含本方那条）→ 循环。
            # 短语没配好时 fail closed，绝不退化成「谁说话都评」。
            return "ignore", None
        if phrase not in note:
            return "ignore", None
        fields = _fields_from(_dig(body, "merge_request"), _dig(body, "repository"))
        if fields is None:
            # 已经过了短语那一道（只有命令才走到这里），所以这行日志不会被普通评论刷屏
            _log_ignored("missing-field")
            return "ignore", None
        if not _branch_allowed(fields["target_branch"], cfg):
            return "ignore", None
        # 评论的唯一 id 是 note_biz_id（32 位十六进制）；真实 Note Hook 里**没有**
        # object_attributes.id——用 id 取值会恒为空串，于是每一条 /kiro review 都被静默忽略。
        # 取值的**形状**由下面的 _accept 一并检查（代号 note-biz-id），与别的标量同一处、同一行日志。
        fields["dedupe_extra"] = _scalar(_dig(body, "object_attributes", "note_biz_id")) or ""
        if not fields["dedupe_extra"]:
            _log_ignored("note-biz-id")      # 没有评论 id 就无法去重，宁可不评——但要留痕
            return "ignore", None
        if not _accept(fields, cfg):
            return "ignore", None
        # MR 已经合并或关闭时不受理命令（见 NOTE_CLOSED_STATES）。位置有两个约束：
        # ①在短语之后——否则每一条普通评论都会打一行日志，真正的信号就被淹掉；
        # ②在 _accept **之后**——`mr-not-open` 在手册里是「正常流量、无需处置」，而形状代号是
        # 「有人在改报文」。放在前面的话，伪造报文只要顺手多带一个 `state: merged`，就能把
        # 那条告警降级成一句无需处置的日志（Task 13 复审 M-3）。两种都 ignore，差别只在信号。
        if _norm(_dig(body, "merge_request", "state")) in NOTE_CLOSED_STATES:
            _log_ignored("mr-not-open")
            return "ignore", None
        return "review", fields

    return "ignore", None


def _norm(v):
    """报文里的枚举值归一：缺失变空串，去空白并转小写。"""
    return "" if v is None else str(v).strip().lower()


def _secret_unavailable_code(exc):
    """写进日志的固定代号：AWS 错误码，或没走到 AWS 调用时的固定枚举值。

    固定枚举（`env-unset` / `empty-value` / AWS 错误码 / 异常类型名）而不是异常正文：正文是自由
    文本，带调用方角色 ARN 与账号 ID。这是 _failure_reason 已经确立的做法，直接复用它。
    """
    if exc.__cause__ is not None:
        return _failure_reason(exc.__cause__)
    return exc.reason or "unknown"


def _secret_unavailable(exc):
    """取不到共享密钥（WEBHOOK_SECRET_ID）时的唯一出口：一行固定形状日志 + 503。云效令牌以前也走这里，
    issue 05 G3 起改成只在留痕那一步取、取不到只落一行 cleanup-failed（见 _post_failed_comment）。

    响应正文只给一个固定代号，不带任何 AWS 错误正文（含角色 ARN 与账号 ID，与 _failure_reason
    同一条理由）。

    必须**留一行日志**（I1）：这条路径在 Lambda 看来是成功调用（Errors 指标为 0），
    响应正文对四种成因（缺 IAM 授权、密钥不存在/名字不符、密钥值为空、限流）完全一样，
    不打日志的话全新部署一旦配错就只剩一个查不下去的 503。形状固定、只有变量名与代号，
    便于按 code= 过滤；setup-guide 排错表按这个形状写。
    """
    print(f"secret-unavailable var={exc.var_name} code={_secret_unavailable_code(exc)}",
          flush=True)
    return _resp(503, "secret-unavailable")


def handler(event, context):
    # 先看请求带没带令牌，再取密钥（M3）：没带令牌的请求一定会被拒，为它跑一次 GetSecretValue
    # 只是白费配额；更要紧的是取密钥正在失败时，任意公网调用者都会收到 503 secret-unavailable，
    # 那是在向外泄露我们这边的内部状态。没带令牌一律 401，不给它任何区分度。
    if not token_header(event.get("headers")):
        return _resp(401)
    try:
        expected = secret_fetch.secret_from_env("WEBHOOK_SECRET_ID")
    except secret_fetch.SecretUnavailable as exc:
        # fail closed：取不到共享密钥就无从判断「这是不是我们的 webhook」，一律不放行。
        # 关键在于给一个**显式响应**而不是让异常逃出 handler——未捕获异常对 ALB 就是 502，
        # Codeup 只看到投递失败，与 C1 同属静默失败。
        # 选 503 而不是 401：401 会把我们自己的配置/权限问题（少 secretsmanager:GetSecretValue、
        # 密钥名写错、密钥没建）伪装成「对方令牌不对」，运维照着 401 去查 Codeup 那侧的密钥，
        # 永远查不到真正的原因；503 是「我这边没就绪」，语义正确。
        #
        # Codeup 对 503 的重投行为已实测（Task 1，真实 webhook）：同一个 `X-Codeup-Delivery`
        # 在约 1 秒内一共到 3 次（立即重试 2 次），之后再无投递（观察 10 分钟以上）。所以
        # **只有亚秒级抖动（比如一次限流）能靠重投自愈**；配置或权限错误在 1 秒内不可能修好，
        # 那次事件就永久丢了——_secret_unavailable 打的那行日志是它留下的唯一痕迹。同时这也意味着
        # **被我们回了 503 的那次投递**最多可能到 3 次且 delivery id 相同，幂等抢锁（N3）是承重的。
        # （只测了 503 这一个状态码；404/502/504 是否同样重投没测过，所以「最多 3 次」不是所有
        # 状态码的上界。幂等抢锁的必要性不依赖这个数字——共享密钥鉴权本身就可重放。）
        return _secret_unavailable(exc)
    if not verify_token(event.get("headers"), expected):
        return _resp(401)

    # 验签通过。下面才是「这次投递要不要评审」——原计划把 verify_token / classify / claim /
    # run_task 各自实现并各自测试，却没有任何一步把它们接到入口上：那样 handler 会验完签名就
    # return 200，每一个 webhook 都被接受然后什么都不做，而全套单测照样绿。这段接线是唯一
    # 能证明「部件都对且真的连上了」的地方。
    # 云效令牌不在这里取（issue 05 G3）：它只在 RunTask 失败后的留痕里用得上，见 _post_failed_comment。
    cfg = _runtime_cfg()
    try:
        body = json.loads(_body_text(event) or "{}")
    except ValueError:
        # 解不开的正文不猜（N6）。200 而不是 4xx：这次投递我们已经处理完了，回非 2xx 只会让
        # Codeup 把同一份解不开的正文再投两次（实测行为，见上）。
        return _resp(200, "unparseable")

    kind, fields = classify(event.get("headers"), body, cfg)
    if kind != "review":
        return _resp(200, "ignored")

    ecs, table = _clients(cfg)
    return dispatch(ecs, table, cfg, fields)


def _runtime_cfg():
    """运行时的非敏感值，全部来自环境变量。

    云效令牌不在这里（issue 05 G3）：它只在 RunTask 失败后的留痕里用得上，由 _post_failed_comment
    在那一步向 Secrets Manager 取；config.yaml 与明文环境变量都不是它的来源（既有裁决）。
    这层间接（连同 _clients）同时让入口可测：单测不必真的有环境变量和 AWS 客户端。
    """
    return {
        "org_id": os.environ["YUNXIAO_ORG_ID"],
        "cluster": os.environ["ECS_CLUSTER"],
        "task_definition": os.environ["ECS_TASK_DEFINITION"],
        "container_name": os.environ["ECS_CONTAINER_NAME"],
        "subnets": os.environ["SUBNET_IDS"].split(","),
        "security_groups": os.environ["SECURITY_GROUP_IDS"].split(","),
        "lock_ttl_seconds": int(os.environ.get("LOCK_TTL_SECONDS", "86400")),
        "bot_usernames": [u for u in os.environ.get("BOT_USERNAMES", "").split(",") if u],
        "review_command": int(os.environ.get("REVIEW_COMMAND", "0")),
        "command_phrase": os.environ.get("REVIEW_COMMAND_PHRASE", "/kiro review"),
        "target_branch_filter": os.environ.get("TARGET_BRANCH_FILTER", ""),
    }


def _clients(cfg):
    """ECS 客户端与锁表。boto3 在函数内部 import，沿用本仓库写法（见 secret_fetch.py）。

    两个都用有界配置（bounded_config.py）：RunTask 或 PutItem 在抢锁之后卡过 29 s 的话，Lambda
    直接超时，释放锁与「评审未启动」都不会执行——锁挂 24 h、MR 上一句话都没有，Codeup 的重投又被
    抢锁当成重复（全分支复审 s4 M-B）。
    """
    import boto3
    import bounded_config
    return (boto3.client("ecs", config=bounded_config.client_config()),
            boto3.resource("dynamodb", config=bounded_config.client_config())
            .Table(os.environ["LOCK_TABLE"]))


def lock_key(fields):
    """锁键 = repo#MR#head_sha，评论命令再拼评论 id。

    approve 携带上一次评审的同一个 head_sha，所以这个键天然区分「有新工作」
    与「回放/无关子事件」，不需要解析 Codeup 那六种子事件的字段。
    """
    parts = [fields["repo_id"], fields["mr_local_id"], fields["head_sha"]]
    extra = fields.get("dedupe_extra")
    if extra:  # None 或 "" 都视为「没有评论 id」，二者行为必须一致
        parts.append(extra)
    return "#".join(parts)


def claim(table, key, ttl_seconds):
    """条件写入抢锁。返回 False 表示这次投递是重复的（重放、approve、元数据更新）。

    抢锁必须在 RunTask 之前（N3）：webhook 共享密钥可重放，这是唯一的重放防护点。

    条件失败**不一定**是别人抢的（issue 02）：PutItem 没有幂等 token，本调用的第一次尝试已经写进去、应答却超时，
    SDK 的 standard 重试就会撞上自己刚写的记录。所以每次调用写一个新的 claim_id，并让条件失败带回旧项
    （ALL_OLD）：旧项是本调用写的就算抢到。claim_id 刻意每次调用新生成——用 `X-Codeup-Delivery` 之类的
    报文取值的话，同一投递的精确重放也会被认成「我的」，N3 就没了。
    """
    claim_id = uuid.uuid4().hex
    now = int(time.time())
    try:
        table.put_item(
            Item={"pk": key, "expires_at": now + ttl_seconds, "claimed_at": now,
                  "claim_id": claim_id},
            ConditionExpression="attribute_not_exists(pk)",
            ReturnValuesOnConditionCheckFailure="ALL_OLD")
        return True
    except botocore.exceptions.ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code == "ConditionalCheckFailedException":
            # 旧项是线上格式（`{"S": …}`）：错误应答不经 resource 层反序列化（2026-09-29 沙箱实测）。
            # 也认反序列化后的裸字符串：哪个 boto3 版本改了这一点时，修复不至于静默失效。两种都只认
            # 本调用刚生成的 id，所以放宽形状不放宽 C1。认不出的（没带旧项、升级前没有 claim_id 的记录）
            # 一律当成重复——失败方向是不派发。
            old = exc.response.get("Item")
            return isinstance(old, dict) and old.get("claim_id") in ({"S": claim_id}, claim_id)
        raise  # 真 AWS 错误（限流等）绝不能吞成「重复投递」


def release(table, key):
    """RunTask 失败后释放锁——否则一次限流会让那个 MR 永远评不了（N4）。"""
    table.delete_item(Key={"pk": key})


def run_task(ecs, cfg, fields, key):
    """拉起 Fargate 评审任务，返回 task ARN。

    只往 containerOverrides.environment 塞非敏感标量（I3）：RunTask 的入参会进
    CloudTrail，密钥必须走任务定义的 secrets 块（Secrets Manager ARN），绝不能出现在这里。

    LOCK_KEY 是 dispatch 抢锁用的同一个字符串，原样传进容器：执行器置「已回写」标记、兜底
    Lambda 读标记都只认它，任何别处都不重建（I1）——评论命令的键多一段评论 id，重建必然对不上。

    fields 的约定：缺失的可选值是 ""。值为 None 的字段不传——str(None) 会变成字面量 "None"：
    MR_TARGET_BRANCH=None 非空，脚本就不走「按源分支反查目标分支」，而是评审一个叫 None 的分支。
    不传时由 entrypoint 的 `:=` 缺省（可选项）或 `:?` 守卫（必填项）处理。
    """
    env = [{"name": k, "value": str(v)} for k, v in (
        ("CODEUP_REPO_ID", fields["repo_id"]),
        ("MR_LOCAL_ID", fields["mr_local_id"]),
        ("MR_TARGET_BRANCH", fields["target_branch"]),
        ("CI_COMMIT_REF_NAME", fields["source_branch"]),
        ("HEAD_SHA", fields["head_sha"]),
        ("BUSINESS_REPO_URL", fields["clone_url"]),
        ("LOCK_KEY", key),
    ) if v is not None]
    resp = ecs.run_task(
        cluster=cfg["cluster"], taskDefinition=cfg["task_definition"],
        launchType="FARGATE", count=1,
        networkConfiguration={"awsvpcConfiguration": {
            "subnets": cfg["subnets"], "securityGroups": cfg["security_groups"],
            "assignPublicIp": "ENABLED"}},
        overrides={"containerOverrides": [
            {"name": cfg["container_name"], "environment": env}]})
    tasks = resp.get("tasks") or []
    if not tasks:
        # RunTask 可以 HTTP 200、不抛异常，却一个任务都没拉起，原因放在 failures[]（ECS API 文档）。
        # 以前这里直接 `[0]`，于是「评审未启动」那条评论里的原因是 `IndexError`（复审 s3 M-2）。
        raise RunTaskFailure((resp.get("failures") or [{}])[0].get("reason"))
    return tasks[0]["taskArn"]


# RunTask failures[].reason 的形状：`RESOURCE:ENI`、`AGENT`、`ATTRIBUTE` 这类枚举（可带冒号后缀）。
# 不是这个形状的一律记成 unknown：这段文字要进 MR 评论，绝不回显自由文本（与 _failure_reason 同一条理由）。
_RUNTASK_REASON_RE = re.compile(r"[A-Z][A-Z_]*(:[A-Z][A-Z_]*)?")


class RunTaskFailure(RuntimeError):
    """RunTask 返回了空的 tasks[]。reason 取 failures[0].reason，只认枚举形状。"""

    def __init__(self, reason):
        super().__init__("RunTaskFailure")
        self.reason = reason if isinstance(reason, str) and _RUNTASK_REASON_RE.fullmatch(reason) \
            else "unknown"


def _failure_reason(exc):
    """MR 评论里给的失败原因：AWS 错误码（ThrottlingException、AccessDeniedException…）或异常类型名。

    错误码是固定枚举，能区分限流、权限、集群不存在——从没部署过的环境里最先出现的就是这几类，
    这条评论是运维唯一的信号。绝不用 str(exc)：错误正文是自由文本，带 ARN、账号 ID 甚至内网地址。
    """
    if isinstance(exc, botocore.exceptions.ClientError):
        code = exc.response.get("Error", {}).get("Code")
        if code:
            return code
    if isinstance(exc, RunTaskFailure):
        return f"RunTaskFailure:{exc.reason}"
    if isinstance(exc, secret_fetch.SecretUnavailable):
        return f"SecretUnavailable:{_secret_unavailable_code(exc)}"
    return type(exc).__name__


def failed_comment(reason):
    """「评审未启动」评论的正文。正文里必须带本方标记（DISPATCH_FAILED_MARKER）——这条评论会触发
    Note Hook，没有标记时唯一的防线是「命令短语不是它的子串」，而短语是可配的（比如配成
    `Kiro 代码评审`）：那时拉起任务持续失败就变成失败评论 → Note Hook → 又一次评审 → 又一条失败
    评论，每次都是新的 note_biz_id，抢锁拦不住（N5）。

    标记单独占一行、紧跟标题：与评审脚本渲染的评论形状一致，且不会与脚本的
    `<!-- kiro-review:<sha> run:N -->` 混淆（后者带载荷，正则匹配不到这一行）。
    """
    return ("## 🤖 Kiro 代码评审\n" + DISPATCH_FAILED_MARKER +
            "\n\n**评审未启动**：调度器无法拉起评审任务。\n\n"
            f"原因：`{reason}`。稍后重新推送可再次触发。")


def dispatch(ecs, table, cfg, fields):
    """抢锁 → 拉起任务；RunTask 失败时释放锁并在 MR 上留痕（I10），HTTP 仍返回 200
    以免 Codeup 因为我们的内部失败重投同一个 webhook。
    """
    key = lock_key(fields)
    if not claim(table, key, cfg.get("lock_ttl_seconds", 86400)):
        return _resp(200, "duplicate")
    try:
        run_task(ecs, cfg, fields, key)
    except Exception as exc:  # noqa: BLE001 — 拉起任务的失败面很杂（限流/无容量/瞬时网络错误），
                               # 都要落到同一条「释放锁 + 留痕」的兜底路径上，不能只挑几种已知异常
        # 抢锁已经成功，这次投递的副作用已经落地。收尾（释放锁、留痕）再抛异常就会让 handler
        # 以 502 结束。Codeup 对 503 会用**同一个** delivery id 立即重投 2 次（Task 1 实测）；对 502
        # 是否同样重投没有测过，按会重投来设计：
        # 锁此时可能已经释放，于是同一个 head 可能被再拉起一次（RunTask 两次尝试都超时、服务端其实
        # 已经拉起的那种客户端错误下，就是同一个 LOCK_KEY 的两个任务；执行器的租约持有者带任务 ARN，
        # 它们先后评、不会并发，issue 02）。所以抢锁之后的每条路径都必须回 200，
        # 收尾失败只留一行固定形状的代号。两步各自 try：释放锁失败不该连带吞掉 I10 的留痕。
        _cleanup(release, table, key, step="release")
        _cleanup(_post_failed_comment, cfg, fields, _failure_reason(exc), step="comment")
        return _resp(200, "runtask-failed")
    return _resp(200, "dispatched")


class PostFailed(RuntimeError):
    """Codeup 拒收了「评审未启动」评论（post_comment 返回 False：HTTP 非 2xx 或连不上）。"""


def _post_failed_comment(cfg, fields, reason):
    """「评审未启动」留痕（I10）。云效令牌到这一步才取（issue 05 G3）：预先取的话，只是这一个密钥取不到
    （改名、IAM 少一条 ARN、限流）就会让每一次评审都 503、事件丢失，而执行器根本不用调度器这一份令牌。

    两件事都在 _cleanup 的 try 里跑（参数也在里面求值），所以都只落成一行代号：取不到令牌是
    `SecretUnavailable:<代号>`，Codeup 拒收是 `PostFailed`（issue 05 N1：以前 post_comment 的 False
    被丢掉，令牌被吊销的 401 一行日志都不留），连上之后断开是原始异常的类型名。
    """
    token = secret_fetch.secret_from_env("YUNXIAO_TOKEN_ID")
    if not codeup_min.post_comment(cfg["org_id"], fields["repo_id"], fields["mr_local_id"], token,
                                   failed_comment(reason)):
        raise PostFailed("post-comment")


def _cleanup(fn, *args, step):
    """跑一步收尾动作；它抛异常时只打一行固定代号，绝不让异常冒出 dispatch。

    理由见 dispatch 里那段注释：抢锁之后的 502 会招来 Codeup 的立即重投。代号经 _failure_reason
    取（固定枚举），不带 AWS 错误正文（含角色 ARN 与账号 ID）。
    """
    try:
        fn(*args)
    except Exception as exc:  # noqa: BLE001 — 收尾这一步的失败面同样很杂，且无论哪种都不能改变响应
        print(f"cleanup-failed step={step} reason={_failure_reason(exc)}", flush=True)
