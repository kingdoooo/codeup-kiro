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

## 修订（2026-10，Phase 2b 实测）

Phase 2b 在 sandbox 里用合成仓库把上面几条未知都测了（证据与作业记录在 Phase 2b 的探测记录里），结论如下，实现以此为准：

- **重指向可行，每仓库一个代码评审资源**：作业在 `StartCodeReviewJob` 时记下代码评审当时的 `sourceCode`，PREFLIGHT 按这份副本读一次源与 diff，
  之后不再读；Start 之后立刻重指向、或 PREFLIGHT 之后删掉对象，作业都照常按原来的源完成。所以同一仓库的并发只需在「重指向 → Start → 核对作业
  记下的源」这几秒里串行。`CreateCodeReview` 同步校验源对象存在，`StartCodeReviewJob` 不校验；`UpdateCodeReview` 整体替换 assets，带
  `sourceCode` 时必须同时带 `serviceRole`。
- **归档用 MR 提交的整棵树**（不是 merge-base）：两者都能报出问题，但 head 树给出精确的 head 行号。diff 是 merge-base 到 MR 提交，同一个提交。
- **diff 必须以 `.patch` 结尾**（文档示例里的 `.diff` 会被拒）。**ZIP 不能带归档注释**：`git archive --format=zip <提交>` 会把提交号写成注释，
  带注释的源在 PREFLIGHT 失败（早期报 `INTERNAL_ERROR`，现在报 `CLIENT_ERROR … not a valid zip archive`）。空 diff 会被受理并报出与改动无关的
  发现，所以空 diff 不起作业。
- **发现**：`ListFindings` 只有摘要，位置要 `BatchGetFindings`；`filePath` 是 `/tmp/opt/source_code/code_sc-<id>/<相对路径>` 或直接的相对路径；
  没有 `reasoning`、`validationStatus`；`riskType` 会出枚举外的值；同一输入重跑，条数与位置可能不同。每次差分扫描最多 30 条。
- **配额**：并发作业默认 5（第 6 个 Start 同步收到 `ThrottlingException`，不排队）。上文「每账号每月 1,000 次」是配额页的「PR code reviews」；
  API 发起的作业是否计入，Service Quotas 与 `AWS/Usage` 里都看不到——按可能计入规划，不做触发频率闸门（与 Phase 2 的决定一致）。
- **2b 只发汇总评论**（「findings 直接复用 Kiro 的行内/汇总评论管线」改为只复用汇总那一半）：行内评论要先把 Kiro 的行内管线抽成库，并设计「重跑时
  已有行内评论怎么处理」（结论非确定），另开一轮。
- **不需要 Security Agent 的 Application**：它是 Web 控制台的配置；API 差分扫描只要 Agent Space、服务角色、已连接的桶（文档与 SDK 模型的结论，
  并在一个没有 Application 的区域里实际跑通过一个作业）。
