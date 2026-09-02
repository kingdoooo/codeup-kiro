---
status: accepted
date: 2026-09-02
---

# 生产钉 Kiro CLI 稳定版（V2 引擎），agent 配置写成 V2/V3 双兼容，V3 只做观察

Kiro CLI 3.0 目前是 early access：随 2.x 稳定版一起安装，需 `--v3` / `--engine v3` 显式进入，2.13 到 2.20 每个版本都在改 V3 行为。V3 带来的权限模型（capability 级 deny、deny 优先、硬编码不变量）对只读评审员更简洁，但三点让它不适合现在上生产：headless 对 V3 引擎的支持在文档中自相矛盾（"Classic mode not supported" vs `--output-format stream-json` 支持 `--engine v3`）；V3 在没有 `permissions.yaml` 时**默认放行** `git status/log/diff` 等 shell 命令，与本项目"评审员绝不执行命令"的不变量相悖；V3 会把子目录 `AGENTS.md` 也作为 steering 载入，扩大了被评审代码的注入面。因此镜像固定安装稳定通道的指定版本（当前 2.21.0，sha256 校验），运行 V2 引擎；agent 配置同时写 `toolsSettings`（V2 生效）与 `permissions.rules`（V3 生效，含显式 `shell deny`），任何时候切换引擎都不需要改配置。

## Consequences

- 切换到 V3 的门槛，全部满足才切：官方 GA 公告；headless 文档明确支持 V3；`--trust-tools` 在 V3 的语义定型；canary 负向测试（读禁止路径、AGENTS.md 注入、shell 执行）在 V3 下全部通过。
- 探测阶段保留一个时间盒（≤ 半天）的 `--engine v3` 对照实验，只为提前发现迁移成本，不作为上线依据。
- 不依赖 V3 独有能力（标签式 `tools`、`code` 工具）实现任何功能。
