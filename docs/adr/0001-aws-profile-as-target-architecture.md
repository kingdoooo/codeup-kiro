---
status: accepted
date: 2026-09-02
---

# AWS 档位（Lambda 调度器 + Fargate 执行器）为目标架构，Flow 档位保留为兼容形态

Flow 公共构建集群每次运行都要重新拉起容器并用 `curl | bash` 安装 kiro-cli，评审延迟高且 kiro-cli 版本不受控；Flow 的代码源触发也接不到 Codeup 的评论事件，做不到"在 MR 里评论一句就重审"。我们决定把调度与执行搬到 AWS：Codeup Webhook → Lambda 调度器（校验、过滤、幂等）→ ECS Fargate 临时任务（镜像内置钉死版本的 kiro-cli），Flow 完全退出执行链路。Flow 档位不删除，作为"客户没有 AWS 账号"时的部署形态与 AWS 档位共用全部核心脚本。

## Considered Options

- **EC2 装 Flow Runner 当私有构建集群**：改动最小，但仍是常驻服务器，Flow 仍在链路里，评论触发还要另接。
- **Lambda 直接当执行器**：15 分钟硬上限，与 `KIRO_TIMEOUT=900s` 加 clone 没有余量。
- **AgentCore Runtime 承载 kiro-cli**：技术可行（ARM64 kiro-cli 存在），但同步调用 15 分钟上限要走异步模式，且 Identity/Memory/Gateway 一概用不上——是拿 agent 托管服务当容器运行器。

## Consequences

- 业务库会被 clone 到 us-west-2 的 Fargate 任务中；数据治理条款从"diff 出境"升级为"仓库出境"，需要客户书面确认。
- 阿里云侧开发者看不到 CloudWatch，因此任一评审员失败都必须把错误摘要与日志尾部写回 MR 评论。
- 集成包变成一个 Docker 镜像，运行时不再 `curl | bash`，供应链风险由镜像构建时的 sha256 校验承担。
