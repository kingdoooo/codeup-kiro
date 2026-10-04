# 与 Docker Hub 的 debian:stable-slim 是同一个镜像，走 ECR Public 镜像站：Task 1 真实探测里
# 本机网络下 `auth.docker.io` 超时、`FROM debian:stable-slim` 直接构建失败，而这个地址拉取正常。
# Codeup 用户所在的网络对 Docker Hub 往往同样不可靠，构建期可达性不该赌在它身上。
FROM public.ecr.aws/docker/library/debian:stable-slim

# kiro-review.sh 把 timeout（GNU coreutils）当强制依赖，缺了直接拒绝运行；
# jq >= 1.6 有硬前置检查；git 用于 clone 与 diff；unzip 用于解开钉版安装包。
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      git jq unzip coreutils ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# aws-cli v2：entrypoint 收尾时要写一次 DynamoDB「已回写」标记（Task 10）。
# 用它而不是手写 SigV4：整个执行器只需要这一个 AWS 调用，而在 bash 里签名比多 100 MB 糟得多。
# Debian 的 apt awscli 是 v1 且过旧，所以走官方安装器。装到 /usr/local/bin/aws。
RUN curl -sSf "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
 && unzip -q /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/awscliv2.zip /tmp/aws \
 && /usr/local/bin/aws --version

ARG KIRO_CLI_VERSION=2.21.4
# 完整 64 位十六进制摘要（安装包，非入口文件）——见 docs/adr/0006-flow-pinned-install-profile.md
# 与 pipeline/setup-guide.md 的集成包发布值。截断值会让 `sha256sum -c` 只发警告而 exit 0，
# 门形同虚设，故此处必须是完整值，并配 --strict 让格式错误本身也让构建失败。
ARG KIRO_PINNED_ARTIFACT_SHA256=bbb0a22161d5aea045919cc75e9210e61b63b8c877525f123a30610911b6c44d

# 烤进去的是**安装包 zip**，不是安装好的二进制：pinned 档位的既有代码路径正好接受
# 「一个本地路径 + 两个摘要」，于是 scripts/ 零改动（ADR-0006 明言此意图）。
# 代价是每个任务多约 14 s 安装时间，相对一次数分钟的评审可以忽略。
# 构建上下文是仓库根（见 Step 5 的 `docker build -f aws/executor/Dockerfile … .`），
# 所以 COPY 的源路径必须带 aws/executor/ 前缀。
COPY aws/executor/kirocli-x86_64-linux-musl.zip /opt/kiro/kirocli-x86_64-linux-musl.zip
RUN echo "${KIRO_PINNED_ARTIFACT_SHA256}  /opt/kiro/kirocli-x86_64-linux-musl.zip" \
      | sha256sum --strict -c - \
 || { echo "安装包摘要不符，拒绝构建"; exit 1; }

# 集成包（scripts/ prompts/ kiro/）进镜像。AWS 档位下镜像摘要因此成为
# **集成包自身唯一的信任锚**——Flow 档位里这个角色由受保护分支承担。
COPY scripts /opt/integration/scripts
COPY prompts /opt/integration/prompts
COPY kiro    /opt/integration/kiro
COPY aws/executor/entrypoint.sh /opt/integration/entrypoint.sh
# 执行器与扫描任务共用的 bash 库（Phase 2b：租约、派发、扫描输入）、扫描任务的入口与扫描员驱动
COPY aws/executor/lib /opt/integration/lib
COPY aws/executor/scan-entrypoint.sh /opt/integration/scan-entrypoint.sh
COPY aws/reviewers /opt/integration/reviewers
RUN chmod +x /opt/integration/scan-entrypoint.sh
RUN chmod +x /opt/integration/entrypoint.sh

ENTRYPOINT ["/bin/bash", "-p", "/opt/integration/entrypoint.sh"]
