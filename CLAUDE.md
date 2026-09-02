# codeup-kiro

在阿里云 Codeup 上用 Kiro 做自动 MR 评审。实现在 `scripts/`（评审入口与库函数）、
`pipeline/`（Flow 流水线配置）、`prompts/`（评审提示词）、`kiro/`（受信 agent 定义），
测试在 `tests/`。

## Agent skills

### Issue tracker

Issues 与 spec 存为 `.scratch/<feature>/` 下的本地 markdown 文件，`.scratch/` 已 gitignore，
不进入这个公开仓库。见 `docs/agents/issue-tracker.md`。

### Triage labels

沿用五个标准角色（`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` /
`wontfix`），在本地 issue 文件里体现为 `Status:` 行。见 `docs/agents/triage-labels.md`。

### Domain docs

single-context：根目录一份 `CONTEXT.md` 加一个 `docs/adr/`（两者按需惰性创建，缺失时不要提示）。
见 `docs/agents/domain.md`。

## 本地测试

    bash tests/run-tests.sh

`scripts/kiro-review.sh` 把 `timeout`/`gtimeout` 当强制依赖，macOS 需要
`brew install coreutils`，否则 `tests/test-kiro-review.sh` 会整体跳过。

## 不进版本库的目录

`docs/blog/`（客户材料）、`docs/superpowers/`（设计过程文档）与 `.scratch/`（issue 与 spec）
刻意只留在本地，已在 `.gitignore` 中排除。不要把它们重新加入版本控制。
