# Roadmap：diff 预处理的硬资源上限（Phase 2，P1 可用性）

**状态**：已排入 Phase 2 backlog，未实现。当前版本的缓解只有流水线任务超时（`pipeline/setup-guide.md` 第 4 节第 5 步）。

## 问题

`DIFF_SIZE_LIMIT`（默认 307200 字节）**只是提示词预算**：它限制直接进评审提示词的 diff 字节数，不限制原始 diff 总量、磁盘占用、
变更文件数与预处理时间。超限路径（`scripts/lib/diff-compress.sh` 的 `build_review_input` rc 10）仍会：

1. 把整份 diff 落盘到 `.full.diff`；
2. 为每个变更文件再单独 `git diff` 生成完整 chunk；
3. 对省略文件逐个 `numstat` + `jq`。

只要一个变更文件带 `-diff` 属性或自定义 diff driver，整轮强制 `--text`（防止改动藏进「Binary files differ」的取舍），巨大二进制文件会按
原始字节展开成巨型文本 diff。`KIRO_TIMEOUT` 只包住 Kiro 调用，不包住这段预处理。

Flow 的并发运行实例数 = 1 是**整条流水线**级别，所以一个极端 MR 占住预处理阶段时，后续所有 MR 的评审都排队；被任务超时强杀时
MR 上没有失败评论、只有流水线标红。因此定级 P1（可用性 / 性能），不需要保密性或完整性影响。

## 目标

在整份 diff 落盘之前判定，超过任一上限时不再完整物化巨型 diff / chunk，只给路径、大小与 numstat，并回写可行动的失败 / 降级评论。

## 范围

1. 新增流水线变量（纯数字校验，与 `KIRO_TIMEOUT` / `DIFF_SIZE_LIMIT` 同款）：`MAX_RAW_DIFF_BYTES`、`MAX_CHANGED_FILES`、
   `MAX_SINGLE_CHUNK_BYTES`、`DIFF_PREP_TIMEOUT`（秒）。默认值按真实 Flow 上 ≥ 10 次运行的实测取。
2. 先用 `git diff --numstat` / `--name-only -z` 一次遍历算出文件数与估算体量，在落盘之前判定；超限时评审输入只给清单，
   汇总评论写明「哪一项、实际值 / 上限」。
3. 单文件 chunk 超过 `MAX_SINGLE_CHUNK_BYTES` 时只落头部 + 说明（保持 `.index` 三字段契约与 `NNNN.path` sidecar 不变）。
4. 预处理整段包在 `timeout` 里，超时回写失败评论，不依赖 Flow 任务超时兜底。
5. 超过单 chunk 上限的二进制文件（numstat 给 `-  -`）不再 `--text` 展开，只记路径与大小。
6. 文档：`pipeline/flow-pipeline.yaml`、`pipeline/setup-guide.md` §4 / §11.2、README。

## 验收（以负向为主）

- 变更文件数超上限：不生成任何 chunk，评论写明上限，磁盘写入 < 1 MB。
- 原始 diff 超上限：同上，且 `.full.diff` 不落盘。
- 单个 500 MB 二进制 + 树内 `.gitattributes` 标 `-diff`：不 `--text` 展开，chunk 目录总量小于单 chunk 上限。
- 预处理被人为拖慢超过 `DIFF_PREP_TIMEOUT`：失败评论到 MR，退出码非零，Kiro 未启动。
- 正控：现有 `tests/test-diff-compress.sh` 与端到端大 MR 用例不变；默认值下常规规模 MR 行为与今天一致。
- 变异：去掉任一上限判定 → 对应负向用例失败。
