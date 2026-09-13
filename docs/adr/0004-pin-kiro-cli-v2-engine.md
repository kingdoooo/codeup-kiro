---
status: accepted
date: 2026-09-02
---

# 生产钉 Kiro CLI 稳定版（V2 引擎），agent 配置写成 V2/V3 双兼容，V3 只做观察

Kiro CLI 3.0 目前是 early access：随 2.x 稳定版一起安装，需 `--v3` / `--engine v3` 显式进入，2.13 到 2.20 每个版本都在改 V3 行为。V3 带来的权限模型（capability 级 deny、deny 优先、硬编码不变量）对只读评审员更简洁，但三点让它不适合现在上生产：headless 对 V3 引擎的支持在文档中自相矛盾（"Classic mode not supported" vs `--output-format stream-json` 支持 `--engine v3`）；V3 在没有 `permissions.yaml` 时**默认放行** `git status/log/diff` 等 shell 命令，与本项目"评审员绝不执行命令"的不变量相悖；V3 会把子目录 `AGENTS.md` 也作为 steering 载入，扩大了被评审代码的注入面。因此镜像固定安装稳定通道的指定版本（当前 2.21.0，sha256 校验），并**显式**以 `--agent-engine v2` 运行——实测 2.21 的 headless 默认引擎是 v1（经典），它不支持 `--output-format stream-json`，而结构化输出契约依赖该事件流（`runFinished.finalText`）；agent 配置同时写 `toolsSettings`（V2 生效）与 `permissions.rules`（V3 生效，含显式 `shell deny`），任何时候切换引擎都不需要改配置。

## Consequences

- **v1 不可用于生产**：实测 v1（2.21 headless 的默认引擎）下 `chat.disableInheritingDefaultResources=true` 不阻止工作区 `AGENTS.md` 进入自定义 agent 上下文，v2 才阻止；因此 `--agent-engine v2` 是安全要求而非仅为结构化输出。同时执行器在运行前删除业务库 checkout 中任意深度的 `AGENTS.md` 作为不依赖引擎的纵深防御。
- 调用命令固定为 `kiro-cli chat --no-interactive --agent-engine v2 --output-format stream-json --agent codeup-reviewer …`；引擎不写在配置里而写在脚本里，避免被工作区设置覆盖。
- **实测备注（2026-09-02，不改决策）**：kiro-cli 2.21.0 的 `chat --help` 把 `--agent-engine` 标为 `"v2" (default)`，但 headless（`--no-interactive`）实测不传该参数时 `--output-format stream-json` 被拒「not supported on the v1 engine」，且工作区 `AGENTS.md` 的 canary 出现在输出中（`.scratch/codeup-kiro-v2/probe-results/kiro-headless/kiro-probe-t01-default-iso`）——帮助文本与实际默认行为不一致。因此必须显式传 `--agent-engine v2`，不能信任「默认就是 v2」。

- **实测备注（2026-09-08，不改决策）**：kiro-cli 2.21.1 的 `chat [INPUT]` 一旦收到位置参数就**整个忽略 stdin**
  （本机 env -i 许可清单 / 完整环境 × 空 cwd / 业务库 cwd 四种组合一致；`chat --help` 只把 `[INPUT]` 写成
  「The first question to ask」，对 stdin 没有任何说明）。因此集成包自 `06d5028` 起把**运行时提示词与评审输入一起走 stdin、
  不给位置参数**；在那之前的所有真实运行里，模型从未收到 diff，只是自己读工作树、把整个文件当成本次改动来评
  （见 `.scratch/codeup-kiro-v2/acceptance/NOTES.md` D4 / D4b）。探测脚本仍用位置参数（提示词短、不喂 diff），
  两者刻意不同，见 `scripts/probe/README.md`。这条只是记录 CLI 的行为事实，v2 引擎的决策不变。

- **修订（2026-09-10，CodeX 复审 P1-2）**：版本门从「名单外只 notice」（15-fix2 #24）改为**默认拒绝**。`scripts/kiro-review.sh` 的
  `KIRO_TESTED_TARGETS`（2026-09-13 起改成**平台 + 版本**元组，形如 `<os>/<arch>:<版本>`——CodeX 复审指出「探测结论只对
  平台 + 版本成立」写进了文档、门禁却只比版本号，于是只在 darwin 上探测过的版本在 Linux 上照样被判名单内。
  当前名单见 `scripts/kiro-review.sh`；平台键由 `kiro_platform_key` 算，门禁与探测脚本共用同一实现，
  **不含** libc 变体与发行版——那一维靠固定执行器镜像 digest 控。上文正文写的 2.21.0 是决策当时的版本）之外的 kiro-cli
  组合拒绝评审并回写失败评论，Kiro 不启动；只有流水线变量 `KIRO_ACK_UNTESTED_TARGET` 与本次 `<os>/<arch>:<版本>`**逐字相等**才放行（汇总带醒目
  notice），刻意不做布尔开关（会永久留在环境里放行以后所有未知版本）；版本解析不出一律拒绝。原因：官方安装脚本只装 latest、没有版本
  开关、sha256 只对在线 manifest，Kiro 3.x 的权限模型是 breaking change，「新版本仍保持已探测版本的路径解析语义」不能当默认假设；本 ADR
  要求的「固定版本 + 校验」只有 setup-guide 第 7 节的预装执行器能满足，第 6 节 curl|bash 路径降为评估 / PoC。这是运维可见的行为变化。
  **同日补充（CodeX 复审 P1）**：版本门只挡版本语义漂移，不是完整性边界——任何打印 2.21.1 的二进制都过得了它。本 ADR 的「sha256 校验」
  落地为两层：构建期在执行器镜像里记录 kiro-cli 入口文件的 SHA-256 并固定镜像 digest（第 7 节）；运行期流水线变量 `KIRO_CLI_SHA256`
  在**第一次执行 kiro-cli 之前**核对该摘要，不一致拒绝评审（生产必配；未配置只留日志）。只核对入口文件，所以镜像 digest 仍要固定。
- 切换到 V3 的门槛，全部满足才切：官方 GA 公告；headless 文档明确支持 V3；`--trust-tools` 在 V3 的语义定型；canary 负向测试（读禁止路径、AGENTS.md 注入、shell 执行）在 V3 下全部通过。**2026-09-02 实测：V3 下 `chat.disableInheritingDefaultResources=true` 不能阻止工作区 `AGENTS.md` 进入自定义 agent 的上下文（v2 可以），因此当前 V3 直接不满足 AGENTS.md 注入这一项。**
- 探测阶段保留一个时间盒（≤ 半天）的 `--engine v3` 对照实验，只为提前发现迁移成本，不作为上线依据。
- 不依赖 V3 独有能力（标签式 `tools`、`code` 工具）实现任何功能。
