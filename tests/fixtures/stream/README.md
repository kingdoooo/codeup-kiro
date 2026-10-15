# 事件流 fixture

kiro-cli `--output-format stream-json` 的真实输出（裁剪过的只有 `real-shape.jsonl`）。`tests/test-review-render.sh` 用它们做解析与负控：
目录下**每一份**都必须让「模型拒绝 / 回退」检测判「无」——升级 Kiro 时把新版本的真实事件流放进来，那一圈负控就覆盖新版本。

| 文件 | 引擎 | 来源 |
|---|---|---|
| `real-shape.jsonl` | v2 | kiro-cli 2.21 探测输出裁剪 |
| `v2.29-read.jsonl` / `v2.29-denied.jsonl` | v2 | kiro-cli 2.29.0 本机探测（kiro-2.29 后续） |
| `v3-2.29.1-apikey.jsonl` | v3 | kiro-cli 2.29.1 本机，API key 身份，无工具调用（ADR-0008 spike S1） |
| `v3-2.29.1-h5-search.jsonl` | v3 | 评审根目录布局 + kiroignore，grep 与读文件，干净（spike S9 c10） |
| `v3-2.29.1-hostile-cwd.jsonl` | v3 | cwd = 业务库：加载 AGENTS.md 与 steering、执行 hook、被同名工作区 agent 顶替（spike S9 c05） |
| `v3-2.29.1-nested-agentsmd.jsonl` | v3 | 评审根目录布局但没写 kiroignore：嵌套 AGENTS.md 被加载（spike S9 c11） |
| `v3-2.31.1-headless.jsonl` | v3 | kiro-cli 2.31.1 本机 headless 探测默认模式（评审根目录 + 临时 HOME + kiroignore，API key），钉版升到 2.31.1 时放进来做负控；真实 HOME 路径换成 `/Users/me` |

V3 的几份来自本机 darwin 运行，路径是 `/private/tmp/…` 下的一次性目录，不含账号信息（复制前已扫描）。
