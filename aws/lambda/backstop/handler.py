import os
import sys

# Lambda 运行时里 codeup_min 与本文件不同目录（打包时放到 /opt/dispatcher）；
# 本地 pytest 时由测试文件把 lambda/dispatcher 加进 sys.path。两种情形都要能 import，
# 所以这一行是**条件式**的——无条件 insert 一个不存在的路径在本地会掩盖真正的 import 错误。
if os.path.isdir("/opt/dispatcher"):
    sys.path.insert(0, "/opt/dispatcher")
import codeup_min  # noqa: E402
import reviewers  # noqa: E402 — 同上，评审员档案的 Lambda 侧常量表（Phase 2b）
import secret_fetch  # noqa: E402 — 同上，dispatcher 目录下的 secret_fetch.py

# 认出「这是我们的评审任务」靠这三个变量；读「已回写」标记只用调度器传进来的 LOCK_KEY（I1）。
WANT = ("CODEUP_REPO_ID", "MR_LOCAL_ID", "HEAD_SHA")

# 本方标记。这条评论会触发 Codeup 的 Note Hook，而调度器按 `<!-- kiro-` 前缀断环（N5）：
# 没有标记时唯一的防线是「命令短语不是它的子串」，而短语是可配的（配成 `Kiro 代码评审` 就会
# 命中标题）——那时「任务反复异常结束」会变成兜底评论 → Note Hook → 又一次评审 → 又一条兜底
# 评论，每次都是新的 note_biz_id，抢锁拦不住。正文写成模块级常量而不是 post_comment 的内联
# 字面量：单测要用**真实的这一份**去验断环，不能各自抄一份（抄的那份迟早与线上分叉）。
BACKSTOP_MARKER = reviewers.PROFILES["kiro"]["backstop_marker"]

# entrypoint.sh 自己 fail closed 的四个退出码：都在评审脚本启动之前（或租约那一步），脚本没机会回写。
# 以前兜底对任何非零退出码都说「可能是拉取镜像失败、内存不足或任务超时」，对这四个全是错的
# （复审 s6 m-B）。每个码一句成因，并指到手册 §8 里按退出码查的那一行。
EXIT_CAUSES = {
    90: "执行器的镜像摘要门拒绝了评审（镜像摘要不在已探测名单内，或读不到本容器的镜像摘要）",
    91: "执行器按仓库 id 取不到业务库地址或 clone 失败（云效令牌、网络或仓库权限），或业务库地址没过检查",
    92: "执行器没能检出 MR 的那个提交（提交已被强推改写或删除、分支名 git 不接受，或缺少 HEAD_SHA）",
    93: "执行器没能拿到这个 MR 的评审租约（同一 MR 的上一次评审迟迟没结束、读写租约失败，或读不到本任务的 ARN）",
    94: "执行器收到的评审员清单（REVIEWERS）或扫描开关不合法",
}

# 扫描任务（Task B，scan-entrypoint.sh）自己的 fail-closed 退出码。与上表分开：同一个码在两个入口里不是同一件事，
# 合在一张表里迟早有人给扫描任务的码配上 Kiro 执行器的成因（复审 s6 m-B 的同一类错误）。
SCAN_EXIT_CAUSES = {
    90: "扫描任务的镜像摘要门拒绝了运行（镜像摘要不在已探测名单内，或读不到本容器的镜像摘要）",
    95: "扫描任务收到的输入不合法（评审员清单、输入前缀或提交号的形状不对）",
    96: "扫描子进程没有正常结束（进程被杀、超时，或连失败评论都没能发出）",
}


def backstop_comment(exit_code, identified=True):
    """兜底评论的正文。退出码只在确实是整数时写进去（它来自 ECS 事件，不是自由文本；bool 不算）。

    identified 为 False：多容器且没有一个名字对得上评审容器（_exit_code 的第二个返回值），退出码
    无从判断——这时不能把它说成「没有退出码、容器多半没能启动」（issue 05 D1）。
    """
    code = exit_code if type(exit_code) is int else None
    if not identified:
        cause = ("评审任务结束了，但 ECS 事件里有多个容器、没有一个名字对得上评审容器，无从判断退出码；"
                 "评审脚本也没有留下「已回写」标记")
    elif code in EXIT_CAUSES:
        cause = (f"{EXIT_CAUSES[code]}（退出码 {code}），评审脚本没有启动。"
                 f"按部署手册 aws/setup-guide.md 第 8 节里标着「退出码 {code}」的行排查")
    elif code is not None:
        cause = (f"评审任务异常结束（退出码 {code}；可能是内存不足或任务超时），"
                 "脚本没有机会回写失败原因")
    else:
        cause = "评审任务异常结束（没有退出码：容器多半没能启动，例如拉取镜像失败），脚本没有机会回写失败原因"
    return ("## 🤖 Kiro 代码评审\n" + BACKSTOP_MARKER +
            f"\n\n**评审未完成**：{cause}。重新推送可再次触发。")


def _scan_cause(exit_code, identified, task_kind):
    """扫描员兜底评论里的成因句。task_kind="review"：执行器（Task A）在派发扫描任务之前结束；"scan"：扫描任务本身。"""
    code = exit_code if type(exit_code) is int else None
    if task_kind == "review":
        if code == 0:
            return "执行器没能拉起扫描任务（ecs:RunTask 失败，执行器日志里有一行 scan-dispatch result=failed）"
        if code in EXIT_CAUSES:
            return f"执行器在交给扫描任务之前结束：{EXIT_CAUSES[code]}（退出码 {code}）"
        if code is not None:
            return f"执行器在交给扫描任务之前异常结束（退出码 {code}；可能是内存不足或任务超时）"
        return "执行器在交给扫描任务之前结束（没有退出码：容器多半没能启动，例如拉取镜像失败）"
    if not identified:
        return "扫描任务结束了，但 ECS 事件里有多个容器、没有一个名字对得上扫描容器，无从判断退出码"
    if code in SCAN_EXIT_CAUSES:
        return f"{SCAN_EXIT_CAUSES[code]}（退出码 {code}）。按部署手册 aws/setup-guide.md 第 8 节里标着「扫描退出码 {code}」的行排查"
    if code is not None:
        return f"扫描任务异常结束（退出码 {code}；可能是内存不足或任务超时）"
    return "扫描任务异常结束（没有退出码：容器多半没能启动，例如拉取镜像失败）"


def scanner_comment(rid, exit_code, identified=True, task_kind="scan"):
    """扫描员的兜底评论：该评审员自己的标题与 `<!-- kiro-backstop:<rid> -->` 断环标记（N5）+ 固定文案与枚举代号（F3）。"""
    prof = reviewers.PROFILES[rid]
    return (prof["lambda_heading"] + "\n" + prof["backstop_marker"] +
            f"\n\n**评审未完成**：{_scan_cause(exit_code, identified, task_kind)}。重新推送可再次触发。")


def _matched_override(event):
    """找到真正带着我们这套环境变量的那个 containerOverride——整个字典，含 name，
    不只是环境变量表。多容器任务里要判断该看哪个容器的退出码，得靠这个 override
    自带的 name，不能靠数组下标（ECS 事件里容器顺序不保证；上一个任务修 N1
    镜像摘要门时已经踩过同一个坑：加一个 sidecar，index 0 就可能指向别的容器）。
    """
    for ov in (event.get("detail", {}).get("overrides", {})
               .get("containerOverrides") or []):
        env = {e.get("name"): e.get("value") for e in (ov.get("environment") or [])}
        if all(env.get(k) for k in WANT):
            return ov, env
    return None, None


def _fields(event):
    return _matched_override(event)[1]


def _exit_code(event, container_name):
    """按容器名字（不是数组下标）取退出码。只有一个容器时天然无歧义，直接用它；
    多容器且找不到匹配名字的容器时返回 (None, False)——调用方不能把这当「退出码是 0」，
    只能退回「已回写」标记去判断，宁可多发一条评论也不要因为看错容器而沉默。
    """
    containers = event.get("detail", {}).get("containers") or [{}]
    if len(containers) == 1:
        return containers[0].get("exitCode"), True
    for c in containers:
        if c.get("name") == container_name:
            return c.get("exitCode"), True
    return None, False


def _requested(env):
    """这个任务负责的评审员。REVIEWERS 缺失 = 旧调度器拉起的执行器任务，只有 Kiro（滚动部署期间的向后兼容）。

    取值不合法时：执行器任务按「只有 Kiro」处理并留一行日志（执行器自己会以退出码 94 拒绝，那条 Kiro 兜底照常发）；
    扫描任务抛 ValueError——扫描任务的 REVIEWERS 由我们自己的执行器拼，不合法就是我们的缺陷，必须走 Lambda 重试 + 失败
    目的地 + 告警，而不是猜一个评审员替它发。
    """
    raw = env.get("REVIEWERS")
    kind = env.get("TASK_KIND") or "review"
    if raw is None:
        if kind == "scan":
            raise ValueError("scan task without REVIEWERS")
        return ("kiro",)
    try:
        rids = reviewers.parse(raw)
    except ValueError:
        if kind == "scan":
            raise
        print("backstop reviewers=invalid", flush=True)
        return ("kiro",)
    if kind == "scan" and "kiro" in rids:
        raise ValueError("scan task must not carry kiro")
    return rids


def _decide(event, table):
    """返回 (kiro 要不要发, 要发的扫描员列表)。整个事件只读一次锁记录。

    Kiro 的判据与 2a 逐条相同（含「退出码 0 不读表」）；扫描员（spec F1）：
      执行器任务（TASK_KIND 缺省）：被请求的扫描员 s 没有 dispatched_<s>，且任务没有置 superseded → 发；
      扫描任务（TASK_KIND=scan）：s 没有 posted_<s>，也没有 superseded_<s> → 发。
    任务级 superseded（执行器发现源分支已被新推送取代）让本次所有评审员都安静：新提交的那一轮会评。
    """
    if event.get("detail", {}).get("lastStatus") != "STOPPED":
        return False, []
    ov, env = _matched_override(event)
    if not env:
        return False, []
    rids = _requested(env)
    kind = env.get("TASK_KIND") or "review"
    scanners = [r for r in rids if r in reviewers.SCANNERS]
    code, determined = _exit_code(event, ov.get("name"))
    kiro_wanted = "kiro" in rids and not (determined and code == 0)
    if not kiro_wanted and not scanners:
        return False, []
    key = env.get("LOCK_KEY")
    if not key:
        return kiro_wanted, scanners
    print("backstop step=read-mark", flush=True)
    item = (table.get_item(Key={"pk": key}).get("Item") or {})
    kiro = kiro_wanted and not item.get("posted")
    if kind == "scan":
        due = [s for s in scanners if not item.get(f"posted_{s}") and not item.get(f"superseded_{s}")]
    else:
        # disabled_<s>：调度器点名了、但执行器那边这位扫描员没启用（滚动部署时两边开关一时不一致），执行器明确记了「不评」
        due = [] if item.get("superseded") else [s for s in scanners
                                                 if not item.get(f"dispatched_{s}") and not item.get(f"disabled_{s}")]
    return kiro, due


def should_post(event, table):
    """任务非正常结束、且评审脚本没留下「已回写」标记时，由我们补一条。

    覆盖 die_review 管不到的盲区：拉镜像失败、OOM、任务超时、entrypoint 在脚本启动前就死。

    第一句先看 lastStatus：ECS 在每次状态迁移（PROVISIONING/PENDING/RUNNING/…）都发这个事件，
    任务还在跑时容器没有 exitCode，不挡住的话每次评审开始几秒就会收到一条假的「评审未完成」。
    EventBridge 规则也只放 STOPPED，但规则是运维可改的配置，这里是这条不变式的最后一道。
    """
    return _decide(event, table)[0]


class PostFailed(RuntimeError):
    """发评论的那次 POST 没成功（HTTP 非 2xx 或网络错误；codeup_min 只返回 False，不抛）。"""


def handler(event, context):
    import boto3
    import bounded_config  # /opt/dispatcher 下，与 secret_fetch 同一手法（有界超时，见该文件）
    table = boto3.resource("dynamodb", config=bounded_config.client_config()) \
        .Table(os.environ["LOCK_TABLE"])
    kiro, scanners = _decide(event, table)
    if not kiro and not scanners:
        return {"ok": True, "posted": False}
    ov, env = _matched_override(event)
    exit_code, identified = _exit_code(event, ov.get("name"))
    kind = env.get("TASK_KIND") or "review"
    # 每位评审员各发各的、用各自的令牌（S2）：一位失败不吞后一位。第一个异常最后原样抛出（类型不变——
    # 取不到令牌仍是 SecretUnavailable、Codeup 拒收仍是 PostFailed），走 Lambda 重试与失败目的地；重试时已发出的那几条
    # 会再发一次（重复好于沉默，2a 已裁决的取舍逐评审员成立）。
    first_exc = None
    jobs = ([("kiro", backstop_comment(exit_code, identified))] if kiro else []) + \
           [(rid, scanner_comment(rid, exit_code, identified, kind)) for rid in scanners]
    for rid, body in jobs:
        tag = "" if rid == "kiro" else f" reviewer={rid}"
        try:
            print("backstop step=fetch-token" + tag, flush=True)
            # 令牌在真要发评论时才取（见 secret_fetch.py）：绝大多数 Task State Change 事件都被 _decide
            # 挡掉，提前取只会给每一次状态迁移都加一次 GetSecretValue 调用（配额与延迟）。
            # 取不到就让 SecretUnavailable 抛出去：这是 EventBridge 的异步调用，抛出会走 Lambda 自己的
            # 重试（密钥限流这类瞬时失败能自愈），吞掉返回 {"posted": False} 才是真正的沉默——兜底的
            # 整个存在理由就是「宁可多发一条也不沉默」（I10）。
            token = secret_fetch.secret_from_env(reviewers.PROFILES[rid]["token_secret_env"])
            print("backstop step=post-comment" + tag, flush=True)
            posted = codeup_min.post_comment(
                os.environ["YUNXIAO_ORG_ID"], env["CODEUP_REPO_ID"], env["MR_LOCAL_ID"], token, body)
            # 发失败（令牌被轮换吊销 → 401、跨境网络断）也必须抛：以前返回值被丢掉、照样报 posted=True，
            # 这次调用就算「成功」——Lambda 不重试，失败目的地队列也收不到，MR 上一句话都没有，正是
            # 兜底要消灭的那种沉默。抛出之后走 Lambda 的重试，重试耗尽进 BackstopFailures 队列并触发告警
            # （dispatcher_stack.py）。代价：超时但其实已经发出去的那次会在重试时多发一条（重复好于沉默）。
            if not posted:
                print("backstop step=post-comment result=failed" + tag, flush=True)
                raise PostFailed("post-comment")
        except Exception as exc:  # noqa: BLE001 — 每位评审员的失败面一样杂，都不能挡住下一位
            if first_exc is None:
                first_exc = exc
    if first_exc is not None:
        raise first_exc
    return {"ok": True, "posted": True}
