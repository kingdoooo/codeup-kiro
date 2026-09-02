---
status: accepted
date: 2026-09-02
---

# 保留 Kiro CLI 作为评审引擎，搁置 Bedrock/AgentCore 原生评审员

执行器搬到 AWS 之后，出现了一条"用 Strands + Bedrock 上的 Claude、托管在 AgentCore Runtime 上"替代 kiro-cli 的路径：数据不出客户 AWS 账号、IAM 鉴权、可加 Guardrails，治理故事更好，也是 AgentCore 的正确用法。我们仍决定保留 Kiro：这个产品向客户交付的是"Kiro 自动评审"，客户为 Kiro 订阅付费，Kiro 的 agent 循环、工具与模型选择是产品的一部分；换引擎等于换产品，不是基础设施决策。

## Consequences

- AgentCore 在本仓库内没有角色；Security Agent 通过其自身 API 接入，不经 AgentCore。
- 重新评估此决定的触发条件：客户明确不再需要 Kiro 订阅，或 Kiro CLI headless 不再可用于 CI 场景。届时应另开 spec，而不是在现有脚本上做双引擎切换。
