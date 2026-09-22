import pathlib
import re

DOCKERFILE = pathlib.Path(__file__).resolve().parents[1] / "executor" / "Dockerfile"


def test_bakes_the_zip_not_the_installed_binary():
    # 烤 zip 而非二进制，是为了让 scripts/ 零改动地复用 pinned 档位（ADR-0006）
    src = DOCKERFILE.read_text()
    assert "kirocli-x86_64-linux-musl.zip" in src


def test_uses_musl_variant_not_glibc():
    # 已探测元组 linux/x86_64:2.21.4 是对 musl 入口文件跑出来的；换 glibc 要重新探测
    src = DOCKERFILE.read_text()
    assert "musl" in src
    assert "glibc" not in src


def test_artifact_digest_is_a_full_64_char_sha256_not_a_truncated_value():
    # 截断摘要（如 8 位）会让 `sha256sum -c` 只发 WARNING 就 exit 0，
    # 门形同虚设——必须是完整 64 位十六进制值才有约束力。
    src = DOCKERFILE.read_text()
    m = re.search(r"^ARG KIRO_PINNED_ARTIFACT_SHA256=([0-9a-fA-F]*)\s*$", src, re.MULTILINE)
    assert m, "找不到 ARG KIRO_PINNED_ARTIFACT_SHA256= 这一行"
    digest = m.group(1)
    assert len(digest) == 64, f"摘要长度是 {len(digest)}，不是 64（截断摘要=门形同虚设）"


def test_sha256sum_check_uses_strict_mode():
    # --strict 让格式错误的摘要行本身也让 sha256sum -c 失败，而不是只发警告后放行。
    src = DOCKERFILE.read_text()
    assert re.search(r"sha256sum\s+--strict\s+-c", src), "缺 --strict：格式错误的摘要行会被放过"


def test_contains_no_secret_material():
    src = DOCKERFILE.read_text()
    for forbidden in ("KIRO_API_KEY", "YUNXIAO_TOKEN", "aws_secret_access_key", "BEGIN RSA"):
        assert forbidden not in src, "密钥绝不进镜像层（I3）"


def test_installs_the_hard_dependencies_kiro_review_checks():
    src = DOCKERFILE.read_text()
    for pkg in ("git", "jq", "unzip", "coreutils"):
        assert pkg in src
