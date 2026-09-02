---
status: accepted
date: 2026-09-02
---

# AWS Security Agent 通过 S3 差分扫描 API 接入，不镜像仓库到 GitHub/GitLab，使用独立机器人账号

Security Agent 原生只集成 GitHub / GitLab / Bitbucket Cloud / Confluence，Codeup 不在列表中，也不能伪装成 GitLab（API 不兼容）。2026 年 7 月的调研结论是"只能 MCP/IDE 本地扫描或镜像到受支持平台"。现在官方提供了 S3 差分扫描路径：`CreateCodeReview(assets.sourceCode[].s3Location)` 建一次代码评审资源，每个 MR 上传归档与 unified diff 到已连接的 S3 桶，`StartCodeReviewJob(diffSource.s3Uri)` 后 `ListFindings` 取结果（含 `codeLocations` 的文件与行区间）。我们决定走这条路：执行器已经有 clone 好的仓库和 diff，增量只是上传与轮询；findings 直接复用 Kiro 的行内/汇总评论管线；以独立机器人账号 `Security Agent` 发评论，与 Kiro 在同一 MR 上并列出现。

## Considered Options

- **镜像到 GitHub/GitLab 再用原生集成**：写回落在镜像仓库而非 Codeup，双平台维护。
- **MCP/IDE 本地扫描**：无 MR 自动化、无法写回。
- **与 Kiro 合并为一条评论**：两位评审员范围不同（通用 vs 安全），合并会让安全 finding 淹没在质量意见里，也无法体现不同的置信度与验证状态。

## Consequences

- 业务库完整归档会以提交 SHA 为 key 持久化在客户 S3（7 天生命周期）；数据治理条款需覆盖。
- 归档必须与 diff 对应同一提交；并发 MR 不得共用同一 S3 key。
- 代码评审能力处于 Preview、免费但有配额（每账号每月 1,000 次）；触发频率做成可降级的配置。
- 归档在 `CreateCodeReview` 时快照还是在 job 时读取，决定"每次 `UpdateCodeReview` 重指向"是否可行；不可行则退回"每个 MR 一个代码评审资源"。
