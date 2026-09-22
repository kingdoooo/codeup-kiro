import pathlib

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


def test_verifies_artifact_sha256_at_build_time():
    src = DOCKERFILE.read_text()
    assert "sha256sum" in src or "sha256" in src


def test_contains_no_secret_material():
    src = DOCKERFILE.read_text()
    for forbidden in ("KIRO_API_KEY", "YUNXIAO_TOKEN", "aws_secret_access_key", "BEGIN RSA"):
        assert forbidden not in src, "密钥绝不进镜像层（I3）"


def test_installs_the_hard_dependencies_kiro_review_checks():
    src = DOCKERFILE.read_text()
    for pkg in ("git", "jq", "unzip", "coreutils"):
        assert pkg in src
