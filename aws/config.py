import re
import unicodedata

import yaml

VALID_REGIONS = frozenset({
    "us-east-1", "us-west-2", "ap-south-1", "ap-southeast-1", "ap-southeast-2",
    "ap-northeast-1", "eu-central-1", "eu-west-1", "sa-east-1"})

# 这三个区域用 global 跨区推理，会把推理请求路由到任意商业区域（只在 security_agent: 1 时有源码推理，手册第 1.2 节）
GLOBAL_INFERENCE_REGIONS = frozenset({"ap-south-1", "ap-southeast-1", "sa-east-1"})

TOGGLES = ("inline_comment", "review_command", "inspector", "security_agent")

# 评论命令的触发短语：默认值只在这里写一份。它有**两个**消费者——调度器（判评论正文里有没有这句）
# 与执行器（页脚那句「怎么重新评审」要把同一句短语印给读者，见 stacks/executor_stack.py::rerun_hint）。
# 两边各自 `cfg.get(..., "/kiro review")` 的话，改默认值时漏掉一处就是「页脚教的短语触发不了评审」。
DEFAULT_COMMAND_PHRASE = "/kiro review"

# 按评审员的评论命令（Phase 2b R5）：键 → 默认短语。Kiro 那一句沿用 2a 的 command_phrase 与 DEFAULT_COMMAND_PHRASE。
# 「全部」那一句不属于某位评审员：它点名的是本部署启用的全部评审员。
PHRASE_DEFAULTS = {
    "command_phrase": DEFAULT_COMMAND_PHRASE,
    "inspector_command_phrase": "/inspector review",
    "security_command_phrase": "/security review",
    "all_command_phrase": "/review",
}
# 短语键 → 它属于哪位评审员的开关（None = Kiro 或「全部」，总是生效）。只有生效的短语参与子串冲突检查。
PHRASE_TOGGLE = {"command_phrase": None, "inspector_command_phrase": "inspector",
                 "security_command_phrase": "security_agent", "all_command_phrase": None}
# 扫描员的机器人账号用户名（选择器按作者 + 标记找自己的汇总）。缺省 = bot_username：R7 的 PoC 形态是三位评审员共用一个账号。
SCANNER_BOT_KEYS = ("inspector_bot_username", "security_bot_username")

# 两个 kiro-cli 摘要（安装包 zip / 装好后的入口文件），分工见 ADR-0006；pinned 档位下都是硬要求。
KIRO_CLI_DIGESTS = ("kiro_pinned_artifact_sha256", "kiro_cli_sha256")
_HEX64 = re.compile(r"[0-9a-f]{64}")


def default_bot_usernames(cfg):
    """调度器缺省忽略名单 = 启用了的评审员各自的机器人账号（去重、保持顺序）。三位共用一个账号（R7 的 PoC 形态）时只有一个名字。
    开关按 `type(v) is int` 读（与 lambda/dispatcher/reviewers.enabled 同一理由：True == 1）。"""
    names = [cfg["bot_username"]]
    for key, toggle in (("inspector_bot_username", "inspector"), ("security_bot_username", "security_agent")):
        v = cfg.get(toggle)
        if type(v) is int and v == 1:
            names.append(cfg.get(key, cfg["bot_username"]))
    return list(dict.fromkeys(names))


def feishu_notify_on(cfg):
    """飞书通知开着（Phase 2c issue 20）。按 `type(v) is int` 读：绕过 load_config 传进来的 True 不算（True == 1 的坑，同上）。"""
    v = cfg.get("feishu_notify")
    return type(v) is int and v == 1


def _has_invisible(s):
    """含控制字符（C0/DEL/C1，\t\r\n 都算）、格式字符（零宽空格之类）、代理项或行/段分隔符。

    人手打的评论与用户名里不会有这些，配进去只会让匹配静默失效（issue 05 C1/C2）。带 ZWJ 的组合表情
    （ZWJ 属于 Cf）也会被拒，是有意的：命令短语与用户名里不该有表情。普通空格与全角
    空格不算：看得见、中文输入法打得出来。私用区（Co）看得见、未分配码位（Cn）的判定随 synth 机器上
    的 Python 版本变，这两类都不拒。
    """
    return any(unicodedata.category(ch) in ("Cc", "Cf", "Cs", "Zl", "Zp") for ch in s)


def _is_clean_name(n):
    """用户名形状：非空字符串，不带首尾空白、不含逗号或看不见的字符（bot_username 与 bot_usernames 共用）。"""
    return isinstance(n, str) and bool(n.strip()) and n == n.strip() and "," not in n and not _has_invisible(n)


def load_config(path):
    with open(path) as fh:
        cfg = yaml.safe_load(fh) or {}

    region = cfg.get("region")
    if not region:
        raise ValueError("config 缺少 region：必配，无默认值")
    if region not in VALID_REGIONS:
        raise ValueError(
            f"region {region!r} 不在 Security Agent 支持的九个区域内，拒绝部署。"
            f"实测排除 ap-east-1 / cn-north-1 / cn-northwest-1。有效集合：{sorted(VALID_REGIONS)}")

    for name in TOGGLES:
        if name not in cfg:
            cfg[name] = 0
            continue
        # type(x) is not int（而非 isinstance）：bool 是 int 的子类，True == 1 / False == 0，
        # isinstance(True, int) 为真——用 isinstance 会放过 YAML 里未加引号的 yes/no/true/on/off
        # （PyYAML 解析成 bool），恰好是人手写配置时最常见的写法，也是这条校验本该拦住的那种错。
        if type(cfg[name]) is not int or cfg[name] not in (0, 1):
            raise ValueError(
                f"{name} 取值 {cfg[name]!r} 非法：必须严格为 0 或 1（缺省即关闭）。"
                "刻意不回落默认——拼错的取值静默关闭功能是最难排查的失败")

    if not cfg.get("org_id"):
        raise ValueError("config 缺少 org_id")
    # bot_username 只有「没写 / 空值 / 空串」才算缺少：0、false 这类 falsy 取值是写错了，交给下面那条报「取值非法」
    if cfg.get("bot_username") in (None, ""):
        raise ValueError("config 缺少 bot_username")
    # bot_username 与 bot_usernames 每一项同一套规则（issue 05 C2）：键不写时默认名单 [bot_username]
    # 不经下面那道名单校验，执行器的 CODEUP_BOT_USERNAME 也直接用它。带首尾空白 → 作者守卫永不命中、
    # 引擎按作者找不到上一条汇总；带逗号 → 默认名单被 join/split 拆成两个名字；非字符串 → 到 CDK 里才抛。
    if not _is_clean_name(cfg["bot_username"]):
        raise ValueError(
            f"bot_username 取值 {cfg['bot_username']!r} 非法：必须是用户名字符串，不带首尾空白、"
            "不含逗号或控制字符（YAML 里没加引号的数字、true/false 不是字符串，要加引号）")

    # 键**不存在**时才填默认（不是 `or`）：显式写成空串/空值是「fail closed，一条命令都不受理」的
    # 既有语义（handler.py 的 `if not phrase` 那一段），用 `or` 回落默认会把它悄悄变成「命令照常生效」。
    for key, default in PHRASE_DEFAULTS.items():
        cfg.setdefault(key, default)

    # bot_usernames 只校验形状，不校验内容：它会被 `",".join(...)` 写进 Lambda 环境变量。
    # YAML 里想清空名单**必须**写 `[]`；写成 `bot_usernames:`（空值）会被解析成 None，
    # 那时 `",".join(None)` 抛 TypeError，报错指向 CDK 内部、说不出是配置写法的问题（手册 4.2 教的
    # 正是「机器人与人同号时把它设成 []」，这条错路必须给一句人话）。
    # 每一项还必须**去掉了首尾空白且不含逗号**：带空白的名字永远匹配不上真实用户名（那道断环守卫
    # 静默失效）；带逗号的名字在 `",".join(...)` 之后会被调度器拆成两个（复审 s5 M-1）。
    if "bot_usernames" in cfg:
        names = cfg["bot_usernames"]
        if not isinstance(names, list) or any(
                not _is_clean_name(n) for n in names):
            raise ValueError(
                f"bot_usernames 取值 {names!r} 非法：必须是用户名字符串的列表，每一项不带首尾空白、"
                "不含逗号或控制字符；清空名单请写 `bot_usernames: []`（不要留空值），键整个不写则默认只含 bot_username")
        if names == []:
            # 空名单是「机器人与人同号」的 PoC 配法（手册 4.2）。它合法，但带着一个只有专用账号才能
            # 消除的隐患，synth 时说一声（与跨区推理那条同一种警告）。
            print("警告：bot_usernames 为空——只适合机器人与人同号的 PoC。同号时引擎分不清你的评论与它自己的"
                  "汇总：你发的带 `<!-- kiro-review:… run:N -->` 标记行的评论会在下一次评审时被当成汇总接管。"
                  "生产请用专用机器人账号（setup-guide.md 第 1.4、4.2 节）。", flush=True)

    # command_phrase：键存在时必须是字符串，且要么是空串（fail closed，一律不受理），要么首尾不带空白、
    # 不含换行或其他看不见的字符（复审 s5 M-1；issue 05 C1：以前只拒 \n，\r、\t、零宽空格都放行）。全空白的短语是空串的孪生兄弟却**不** fail closed——任何含这串空格的
    # 评论都会拉起一次评审；首尾带空白的短语在评论开头永远匹配不上；null 或数字到 CDK 里只报一句看不懂的
    # 「Unable to deserialize value as aws-cdk-lib.aws_lambda.FunctionProps」。
    for key in PHRASE_DEFAULTS:
        phrase = cfg[key]
        if type(phrase) is not str or (phrase and (phrase != phrase.strip() or _has_invisible(phrase))):
            raise ValueError(
                f"{key} 取值 {phrase!r} 非法：必须是加引号的字符串，首尾不带空白、不含换行、制表符或"
                "其他看不见的控制字符，"
                f'例如 {key}: "{PHRASE_DEFAULTS[key]}"；写成空串 "" 表示'
                + ("一条命令都不受理" if key == "command_phrase" else "这一句命令不受理"))
    # 生效短语两两不得互为子串：调度器按「正文含短语」判定，`/review` 若是 `/kiro review all` 的子串，一条只想重跑 Kiro 的
    # 评论就会把全部评审员都拉起来（也可能反过来）。空串不参与（它表示不受理）。只看生效的：没启用的评审员的短语调度器根本不读。
    # 「全部」那一句只在启用了至少一位扫描员时生效（与调度器同一条规则；开关全 0 时与 2a 相同，2a 没有这一句）
    any_scanner = any(cfg[t] == 1 for t in PHRASE_TOGGLE.values() if t)
    live = {k: cfg[k] for k, t in PHRASE_TOGGLE.items()
            if cfg[k] and (cfg[t] == 1 if t else (k != "all_command_phrase" or any_scanner))}
    for a, pa in live.items():
        for b, pb in live.items():
            if a != b and pa in pb:
                raise ValueError(
                    f"{a} 的取值 {pa!r} 是 {b} 的取值 {pb!r} 的子串：一条评论会同时触发两句命令。请改成互不包含的短语")

    for key in SCANNER_BOT_KEYS:
        cfg.setdefault(key, cfg["bot_username"])
        if not _is_clean_name(cfg[key]):
            raise ValueError(
                f"{key} 取值 {cfg[key]!r} 非法：规则与 bot_username 相同（用户名字符串，不带首尾空白、不含逗号或控制字符）")

    calls = cfg.setdefault("inspector_max_scan_calls", 3)
    if type(calls) is not int or not 1 <= calls <= 20:
        raise ValueError(f"inspector_max_scan_calls 取值 {calls!r} 非法：1–20 的整数（每次 ScanSbom 调用约 $0.03）")

    # 三个摘要无默认、必配（spec 变量契约；N7 不允许隐式默认）：缺了的话 synth/部署都顺利，要等第一次
    # 真实评审才在容器里失败，MR 上只看到兜底那句笼统的「可能是拉取镜像失败…」。
    # type(x) is str：YAML 里未加引号、恰好全是数字的摘要会被解析成整数（64 个 0 的占位值就是这样），
    # 那不是「值不对」而是「要加引号」，报错直接说清楚。
    digests = cfg.get("kiro_image_digests")
    if type(digests) is not str:
        raise ValueError(
            f"kiro_image_digests 取值 {digests!r} 非法：必配，空白分隔的镜像摘要名单（字符串，加引号）。"
            "首次部署还没有真实摘要时先填 64 个 0 的占位值，见 setup-guide.md 第 5.2 节")
    parts = digests.split()
    if not parts:
        raise ValueError("kiro_image_digests 为空：必配，首次部署先填 64 个 0 的占位值（见 setup-guide.md 第 5.2 节）")
    for d in parts:
        if d.startswith("sha256:"):
            raise ValueError(
                f"kiro_image_digests 里的 {d!r} 带了 sha256: 前缀：名单里必须是裸十六进制"
                "（entrypoint 核对前会剥掉 ECS 返回值的前缀，两边口径才对得上）")
        if not _HEX64.fullmatch(d):
            raise ValueError(f"kiro_image_digests 里的 {d!r} 不是 64 位小写十六进制")
    # 归一成单空格分隔：人手追加摘要时带进来的换行、制表符、多余空格不再改变名单的含义
    cfg["kiro_image_digests"] = " ".join(parts)

    for name in KIRO_CLI_DIGESTS:
        value = cfg.get(name)
        if type(value) is not str or not _HEX64.fullmatch(value):
            raise ValueError(
                f"{name} 取值 {value!r} 非法：必配，64 位小写十六进制（字符串，加引号），"
                "官方发布值见 pipeline/setup-guide.md")

    if region in GLOBAL_INFERENCE_REGIONS:
        print(
            f"警告：{region} 使用 global 跨区推理。开了 Continuum（security_agent: 1）时，"
            "源码的模型推理可能被路由到 any commercial AWS Region；"
            "其余六个区域为地理跨区推理，留在本地理边界内。", flush=True)

    # Security Agent 作业的总预算（秒，spec R8）：从第一次 StartCodeReviewJob 到作业终态，含并发满时的排队重试（R9）。
    # 实测差分作业 9.2–10 分钟（issue 09）；下限 600 是「排队 + 一次作业」都装得下的最小值，上限 7200 给特别大的仓库。
    timeout = cfg.setdefault("security_agent_timeout", 3600)
    if type(timeout) is not int or not 600 <= timeout <= 7200:
        raise ValueError(f"security_agent_timeout 取值 {timeout!r} 非法：600–7200 的整数（秒）")

    # max_comment_bytes 是评审行为变量（取值语义归共享评审引擎、本档位不另做校验），但它也进扫描任务的白名单，而扫描入口对
    # 不是十进制整数的取值一律退出 95（终审 I-1：不让它进 bash 算术）——Kiro 只警告、按缺省继续。开了扫描员时在这里按扫描入口
    # 同一条规则（栈写进任务定义的 str(取值) 要过 ^[0-9]{1,9}$）拦下，否则部署后两位扫描员在每个 MR 上都失败（针对性复审 M-3）。
    if "max_comment_bytes" in cfg and any(cfg.get(t) == 1 for t in ("inspector", "security_agent")):
        mcb = cfg["max_comment_bytes"]
        if type(mcb) is bool or not re.fullmatch(r"[0-9]{1,9}", str(mcb)):
            raise ValueError(
                f"max_comment_bytes 取值 {mcb!r} 非法：开了 Inspector 或 Security Agent 时必须是十进制整数（最多 9 位，"
                "扫描任务对别的取值一律拒绝运行）")

    # 飞书通知（Phase 2c issue 20，spec F2）：开关严格 0/1、缺省 0；平台只认 feishu / lark、缺省 feishu（两个平台 API 路径相同、域名不同）。
    # 不并进 TOGGLES：那四个开关总会进某个函数或容器的环境（test_every_validated_toggle_reaches_…），这一个为 0 时模板与不开时逐字节相同
    notify = cfg.setdefault("feishu_notify", 0)
    if type(notify) is not int or notify not in (0, 1):
        raise ValueError(
            f"feishu_notify 取值 {notify!r} 非法：必须严格为 0 或 1（缺省 0 = 不发飞书通知）。"
            "刻意不回落默认——拼错的取值静默关闭功能是最难排查的失败")
    domain = cfg.setdefault("feishu_domain", "feishu")
    if type(domain) is not str or domain not in ("feishu", "lark"):
        raise ValueError(
            f"feishu_domain 取值 {domain!r} 非法：只认 feishu（飞书，open.feishu.cn）或 lark（Lark，open.larksuite.com），"
            "按你的企业自建应用建在哪个平台上填")

    # 出站限制（Phase 2c 阶段二，issue 19）：egress_lockdown 严格 0/1、缺省 0（S3 / DynamoDB 网关终端节点 + 终端节点策略、安全组出站只放
    # TCP 443、Route 53 Resolver DNS Firewall）；egress_dns_action 是 DNS Firewall 兜底那条规则的动作，alert（缺省，只记录）或 block（不在
    # 名单上的域名解析失败），先 alert 跑满一轮、从查询日志取名单再切 block（setup-guide.md 第 6.8 节）；egress_mode 是任务的出站形态，
    # public（缺省：公有子网 + 公网 IP 直连 IGW，2b 的形状）或 nat（私有子网 + 一个 NAT 网关，VPC BPA 下最便宜的合规出站）。
    lockdown = cfg.setdefault("egress_lockdown", 0)
    if type(lockdown) is not int or lockdown not in (0, 1):
        raise ValueError(f"egress_lockdown 取值 {lockdown!r} 非法：必须严格为 0 或 1（缺省 0 = 不限制任务出站）")
    mode = cfg.setdefault("egress_mode", "public")
    if type(mode) is not str or mode not in ("public", "nat"):
        raise ValueError(f"egress_mode 取值 {mode!r} 非法：只认 public（公有子网直连）或 nat（私有子网 + NAT 网关）")
    action = cfg.setdefault("egress_dns_action", "alert")
    if type(action) is not str or action not in ("alert", "block"):
        raise ValueError(f"egress_dns_action 取值 {action!r} 非法：只认 alert（只记录）或 block（拦下名单外的域名）")
    if action == "block" and lockdown != 1:
        raise ValueError("egress_dns_action: block 只在 egress_lockdown: 1 时有意义（没开出站限制就没有 DNS Firewall 可切）")

    return cfg
