import re

import yaml

VALID_REGIONS = frozenset({
    "us-east-1", "us-west-2", "ap-south-1", "ap-southeast-1", "ap-southeast-2",
    "ap-northeast-1", "eu-central-1", "eu-west-1", "sa-east-1"})

# 这三个区域用 global 跨区推理，会把推理请求路由到任意商业区域（仅在启用 Security Agent 后生效）
GLOBAL_INFERENCE_REGIONS = frozenset({"ap-south-1", "ap-southeast-1", "sa-east-1"})

TOGGLES = ("inline_comment", "review_command")

# 两个 kiro-cli 摘要（安装包 zip / 装好后的入口文件），分工见 ADR-0006；pinned 档位下都是硬要求。
KIRO_CLI_DIGESTS = ("kiro_pinned_artifact_sha256", "kiro_cli_sha256")
_HEX64 = re.compile(r"[0-9a-f]{64}")


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

    for name in ("org_id", "bot_username"):
        if not cfg.get(name):
            raise ValueError(f"config 缺少 {name}")

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
            f"警告：{region} 使用 global 跨区推理。若日后启用 Security Agent，"
            "源码的模型推理可能被路由到 any commercial AWS Region；"
            "其余六个区域为地理跨区推理，留在本地理边界内。", flush=True)

    return cfg
