# Security Agent fixtures

全部取自 Phase 2b issue 09 的真实作业输出（sandbox，us-west-2，2026-10-07/08），被扫描的是合成仓库（三个文件的 Flask 应用 +
一个带改名、二进制、非 ASCII 路径的变体），不含任何客户或真实仓库内容。规则同 `../inspector/README.md`：解析器与渲染器的 fixture
一律从真实输出派生，不从文档样例派生（D4 教训）。

账号相关的取值已替换（账号 id → `123456789012`，输入桶名、服务角色名、Agent Space / code review id → 占位值）；作业 id、发现 id、
发现的正文与位置保持原样。生成脚本在 `.scratch/codeup-kiro-phase2b/plan-gen-sa/mkfixtures.py`（本地，不进版本库）。

| 文件 | 来源 | 用途 |
|---|---|---|
| `job-diff-completed.json` | 差分作业 J1 的 `BatchGetCodeReviewJobs`（COMPLETED，带 `overview`） | 轮询终态、`overview` 折叠区 |
| `list-findings-diff.json` | J1 的 `ListFindings` | 取发现 id |
| `findings-diff.json` | J1 的 `BatchGetFindings`：2 条（CRITICAL 命令注入在 `src/工具/ping.py`、HIGH SQL 注入在 `src/app/routes.py:37`），`filePath` 带 `/tmp/opt/source_code/code_sc-<id>/` 前缀 | 主路径、非 ASCII 路径 |
| `findings-relative.json` | J3b 的 `BatchGetFindings`：同样两条，`filePath` 是**不带前缀的相对路径** | 路径规范化的第二种形状 |
| `findings-rename.json` | J8 的 `BatchGetFindings`：3 条，含改名后文件 `src/app/helpers.py` 里的路径穿越 | 改名 |
| `findings-full-long.json` | 10-07 全库作业 `cj-a0bd9fef` 的 `BatchGetFindings`：7 条，`description` 2.5–3 KB、`codeLocations` 多达 6 个、`name` 带 `[Requirement: …]`、`riskType` 有枚举外的值 | 截断、枚举外的值 |
| `job-full-completed.json` | 同一全库作业的 `BatchGetCodeReviewJobs`：`status` = COMPLETED 而 FINALIZING 步骤仍是 IN_PROGRESS | 终态只看 `status` |
| `files-head-clean.txt` / `files-head-edge.txt` | J1 / J8 所用 `source.zip` 的文件清单 | 「路径未能对应」的核对 |
