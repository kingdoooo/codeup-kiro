---
status: accepted
date: 2026-10-04
---

# 多评审员层：每位评审员独立进程、独立标记族、独立机器人身份

AWS 档位从一位评审员（Kiro）变成多位（Kiro、Inspector，以及之后的 Security Agent）。共享的部分只有「评论长什么样」：
评论头、历次表、页脚、掩码、截断与 Codeup 请求都出自同一份 `scripts/lib`，按**评审员档案**（`REVIEW_PROFILE`）换标题与标记族
（`<!-- kiro-review:` / `<!-- kiro-inspector-review:` / `<!-- kiro-security-review:`，两两不相交）；Kiro 档案下的输出逐字节不变。
其余一律按评审员分开：**执行器**（Task A）在 clone 之后、Kiro 的租约之前为每位扫描员准备扫描输入（从 git 对象导出、
非 root 空环境跑 sbomgen），再拉起一个**扫描任务**（Task B，同一镜像）；扫描任务里每位扫描员一个只带自己令牌的子进程，
持有按评审员按 MR 的租约，只调扫描 API、只写自己的那一条汇总评论。锁记录按评审员记终态（`dispatched_` / `posted_` / `superseded_` / `disabled_`），
兜底 Lambda 与调度器按评审员各用各的机器人回写；评论命令按评审员分（`/kiro review`、`/inspector review`、`/review` = 全部已启用的）。

## Considered Options

- **Inspector 留在 Task A 里与 Kiro 同进程顺序跑** — 拒绝：扫描员的失败（ScanSbom 限流、输入准备超时）会与 Kiro 的时长上限、
  租约、退出码纠缠在一起，F2（扫描员的任何失败不改变 Kiro 的执行与退出码）只能靠到处 `|| true` 维持；扫描员的令牌也会进
  Kiro 那条进程树。
- **调度器同时拉起两个任务（Kiro 一个、扫描员一个）** — 拒绝：扫描输入必须取自同一次 clone、同一个提交的 git 对象（I8 / N8），
  两个任务各 clone 一次就是两次跨境 clone，也给「两边评的不是同一个提交」开了口子；调度器也不该知道扫描输入怎么准备。
- **所有评审员合并成一条评论** — 拒绝（ADR-0003 已拒绝）：各评审员的节奏、失败方式与严重级别体系都不同，合并之后任何一位的
  失败或重跑都要重写别人的结论；同一机器人账号下也无法按标记定位「我的那一条」。

## Consequences

- **F1**：每位被请求的评审员，负责它的任务结束时要么 `posted`、要么被取代，否则兜底以它自己的机器人回写。**F2**：扫描员的失败
  只体现在它自己的评论里。**S2**：每个扫描子进程只看得见自己的令牌（`export` 自己的、`unset` 别人的，不经任何 argv）。
- 汇总的「定位上一条 → 原地更新」逻辑有了第二份调用代码（`aws/reviewers/lib/summary.sh`，对应 `scripts/kiro-review.sh` 的 1.5 段）：
  不改 `kiro-review.sh`（I9），由对拍测试（`tests/test-aws-scan.sh` ⑤）保证两边结果相同。
- 三位评审员可以共用一个 Codeup 账号（R7 的 PoC 形态，验收必验）：互不接管靠的是标记族两两不相交（M1），不是作者名。
- 每加一位扫描员 = 一份档案 + 一个 `scan_prep_<rid>` + 一个驱动脚本 + 一个开关，执行器、扫描任务入口、兜底与调度器的骨架不动。
