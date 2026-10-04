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


def test_base_image_comes_from_the_ecr_public_mirror_not_docker_hub():
    # Task 1 真实探测：本机网络下 `auth.docker.io` 超时，`FROM debian:stable-slim` 构建不出来；
    # public.ecr.aws/docker/library/debian:stable-slim 是同一个镜像且拉得通。Codeup 用户的网络
    # 对 Docker Hub 同样不可靠，所以构建期可达性不押在 Docker Hub 上。
    src = DOCKERFILE.read_text()
    froms = re.findall(r"^FROM\s+(\S+)", src, re.MULTILINE)
    assert froms == ["public.ecr.aws/docker/library/debian:stable-slim"], froms


def test_contains_no_secret_material():
    src = DOCKERFILE.read_text()
    for forbidden in ("KIRO_API_KEY", "YUNXIAO_TOKEN", "aws_secret_access_key", "BEGIN RSA"):
        assert forbidden not in src, "密钥绝不进镜像层（I3）"


def test_installs_the_hard_dependencies_kiro_review_checks():
    src = DOCKERFILE.read_text()
    for pkg in ("git", "jq", "unzip", "coreutils"):
        assert pkg in src


# ── Phase 2b：扫描任务的文件进镜像（issue 05）──────────────────────────────────────────────

def test_the_scan_task_files_are_in_the_image():
    src = DOCKERFILE.read_text()
    for line in ("COPY aws/executor/lib /opt/integration/lib",
                 "COPY aws/executor/scan-entrypoint.sh /opt/integration/scan-entrypoint.sh",
                 "COPY aws/reviewers /opt/integration/reviewers"):
        assert line in src, line


# ── Phase 2b：sbomgen（issue 06）──────────────────────────────────────────────────────────
def test_sbomgen_is_pinned_by_version_and_full_zip_digest_and_the_binary_digest_is_checked_too():
    src = DOCKERFILE.read_text()
    m = re.search(r"^ARG SBOMGEN_ZIP_SHA256=([0-9a-f]*)\s*$", src, re.MULTILINE)
    assert m and len(m.group(1)) == 64, "sbomgen zip 摘要必须是完整 64 位十六进制（截断 = 门形同虚设）"
    assert re.search(r"^ARG SBOMGEN_VERSION=\d+\.\d+\.\d+\s*$", src, re.MULTILINE), "版本必须钉死成 X.Y.Z"
    url = re.search(r'amazon-inspector-sbomgen\.s3\.amazonaws\.com/([^"]+)', src).group(1)
    assert url.startswith("${SBOMGEN_VERSION}/"), f"下载地址必须是版本化的，不是 latest/：{url}"
    code = "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("#"))
    assert "latest/" not in code, "非注释行里不得出现 latest/ 地址"
    assert src.count("sha256sum --strict -c") >= 3, "zip 与二进制两道核对都要 --strict（另一道是 Kiro 安装包）"
    assert "checksum.txt" in src, "zip 里那份二进制摘要也要核对"


def test_setpriv_is_present_for_running_sbomgen_as_nobody():
    # S1：sbomgen 以 uid 65534 跑；util-linux 的 setpriv 在 Debian slim 里（构建时验证它真的在）
    assert "/usr/bin/setpriv --version" in DOCKERFILE.read_text()
