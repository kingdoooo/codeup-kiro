import yaml

VALID_REGIONS = frozenset({
    "us-east-1", "us-west-2", "ap-south-1", "ap-southeast-1", "ap-southeast-2",
    "ap-northeast-1", "eu-central-1", "eu-west-1", "sa-east-1"})

# 这三个区域用 global 跨区推理，会把推理请求路由到任意商业区域（仅在启用 Security Agent 后生效）
GLOBAL_INFERENCE_REGIONS = frozenset({"ap-south-1", "ap-southeast-1", "sa-east-1"})

TOGGLES = ("inline_comment", "review_command")


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
        if cfg[name] not in (0, 1):
            raise ValueError(
                f"{name} 取值 {cfg[name]!r} 非法：必须严格为 0 或 1（缺省即关闭）。"
                "刻意不回落默认——拼错的取值静默关闭功能是最难排查的失败")

    for name in ("org_id", "bot_username"):
        if not cfg.get(name):
            raise ValueError(f"config 缺少 {name}")

    if region in GLOBAL_INFERENCE_REGIONS:
        print(
            f"警告：{region} 使用 global 跨区推理。若日后启用 Security Agent，"
            "源码的模型推理可能被路由到 any commercial AWS Region；"
            "其余六个区域为地理跨区推理，留在本地理边界内。", flush=True)

    return cfg
