---
status: accepted
date: 2026-10-15
---

# 默认 V3 引擎，`KIRO_ENGINE=v2` 显式回退；V3 在评审根目录与临时 HOME 里运行（取代 ADR-0004）

Kiro 2026-10-09 公告 CLI V3 在 10 月底随 3.0 成为默认引擎、Classic 退役。ADR-0004 当时钉死 V2 的三条理由已经不成立或已被本 ADR 的措施覆盖：headless 文档明确支持 V3（`kiro.dev/docs/cli/headless` 有 `--v3` 示例）；V3 默认放行只读 shell，而受信 agent 对 shell 是整体 deny（deny 优先于一切）；V3 会加载工作区的 `AGENTS.md` / steering，这一条由下面的评审根目录布局、第 5.5 步的删除、kiroignore 与事件流兜底四层处理。因此评审脚本**默认以 v3 运行**，流水线变量（AWS 档位是 `config.yaml` 的 `kiro_engine`）**整串等于 `v2`** 才走 v2；不设或留空 = v3，其余取值拒绝运行。V2 只为演示保留，冻结在已探测名单里 2.29.0 的两条 v2 组合上，之后升级 kiro-cli 只验证 v3。

## 决定

- **已探测名单是「平台 + 版本 + 引擎」三元组**（`<os>/<arch>:<版本>:<引擎>`）。同一个安装包里两种引擎的读取边界由不同的配置表达（V2 读 `toolsSettings`，V3 读 `permissions.rules`），探测结论只对探测时用的引擎成立。两段的旧格式在名单常量、`KIRO_TESTED_TARGETS_EXTRA` 与 `KIRO_ACK_UNTESTED_TARGET` 里一律拒绝；逃生口语义不变。版本即切换点：2.29.0 及以前只有 v2 组合，v3 的组合从 2.31.1 起（2.29.1 只做过 spike，没有进名单；写 ADR 时本机与官方 latest 都已是 2.31.1）；同平台同版本只有另一引擎的组合时，拒绝文案提示该设的 `KIRO_ENGINE`。
- **受信 agent 定义按引擎各一份**：`kiro/agent-codeup-reviewer.json`（V2，冻结，与 v1.10.1 逐字节一致，测试钉 sha256）与 `kiro/agent-codeup-reviewer.v3.json`（只有 `permissions.rules`：一条 `fs_read` allow 覆盖评审根目录与 chunks、一条与 V2 同一份的 `fs_read` deny、`fs_write` / `shell` / `web_fetch` / `web_search` 以及 `subagent` / `skill` / `power` / `context` / `diagnostics` / `mcp` / `sandbox_network` 整体 deny——后七种是 2.31.1 引擎认得的其余全部能力：skill 类工具 `disclose_context`（按需加载 skill 与 `inclusion: auto` 的 steering）不看 `tools`、引擎总是把它加进工具集，其余几类本来就不在 `tools` 里，整体 deny 是不靠「没给」的纵深；引擎对认不出的能力名只跳过那条规则、记一行 `[PolicyParser]` 警告，所以跑完还要核对日志里没有这种警告；prompt 用相对 `file://`）。V3 的 deny 清单里每条 `~/` 形状由安装器按真实 HOME 补一份绝对副本。
- **V3 在评审根目录里运行**：V3 的 grep / 文件搜索只覆盖工作区根目录（cwd），空 cwd 下什么也搜不到；cwd 设成业务库时，仓库的 `.kiro/hooks` 会在执行器上**被执行**、同名工作区 agent 会**顶替**受信 agent（spike S9 c05 实测，2.29.1；2.31.1 上探测 T13 复现：steering 被加载、agent 被顶替、业务库的 hook 被注册——`hooks.reload.loaded registered=1`，事件流里没有 `hook_update`，所以兜底另读 Kiro 日志里的注册数）。所以 cwd 是集成包每次新建的 `$WORK/review-root`，第 5.5 步之后把已隔离的业务库复制到其下 `repo/`（不含 `.git`）；运行目录本身的根 `AGENTS.md`、`.kiro/steering`、`.kiro/hooks`、`.kiro/agents` 都不在业务库手里（S9 c10 / c12 实测：搜索与读取可用、这些面都不加载）。
- **V3 用临时 HOME 与本次运行专用的 TMPDIR**：`$WORK/kiro-home`，五处 kiro-cli 调用只看得见它（`HOME` 与四个 `XDG_*` 都换掉）；`TMPDIR` 换成执行器 TMPDIR 下新建的 `kiro-tmp.<随机>`（0700，退出清理里删）——kiro-cli 在 HOME 之外还往 `$TMPDIR` 写自己的运行日志（`kiro-log/kiro-chat.log`、`lsp.log`、`mcp.log`）与更新暂存目录（`kiro-cli-updates-<uid>`），sandbox 容器里前后快照实测（2026-10-16，Kent 选择换掉而不是照实记下）。v2 冻结，仍写执行器的 `$TMPDIR`（v1.10.1 起就这样；内容是客户端运行日志，不含评审内容）；agent、设置（关掉 code intelligence、knowledge，以及 S8 判定能关的遥测与内容收集）、kiroignore（`AGENTS.md`）都只在里面，跑完随 `$WORK` 删除；
  V3 的 Kiro 进程环境另外固定带两个常量（S8：只有环境变量能关的通道）。kiroignore 在 2.29.1 上承重（不写就加载嵌套的 `AGENTS.md`，S9 c11），在 2.31.1 上只是纵深（不写也不加载）。V3 不认 `KIRO_HOME` / `KIRO_AGENT_CONFIG_DIR`（S6），用户级 `~/.kiro/settings/permissions.yaml` 能打穿读取边界（S3），临时 HOME 同时消掉这两个问题。脚本从不写 `chat.agentEngine`。
- **跑完核对**：事件流第一个 `runStarted.data.engine` 必须等于 `KIRO_ENGINE`（v3 上缺字段也拒绝；v2 上缺字段维持旧行为；有字段但不是 `v<数字>`——比如 3.x 改叫 `v3.1`——两种引擎都拒绝）。v3 再过三条兜底，任一命中就失败评论、不贴任何评审内容：`steering_inclusion` 或非空的 `contextFiles`；`hook_update`，或临时 HOME 里 Kiro 自己的日志报 `hooks.reload.loaded` 的 `registered` 大于 0（注册了就拦，不等触发；spec E3-2）；最后一次 `config_option_update` 的 `mode` 不是本次安装的 agent、或来源不是 `global`。只认 Kiro 写的结构，模型文本伪造不出（模型没有写文件的工具，日志是 Kiro 写的）。同一处另有三项核对，不符同样失败评论：S8 关掉的内容收集——`contentCollection` 不是 `disabled`；受信 agent 的权限规则被 Kiro 跳过——Kiro 对认不出的能力名、不合规的路径只跳过那条规则、在临时 HOME 的日志里记 `[PolicySession] Policy reload warning|error` / `[PolicyParser]`，不报错，出现任何一条就拒绝（只给条数）；用到的工具不在只读名单内——turn_completion 的 `usedTools` 只许 `read_file` / `read_files` / `list_directory` / `file_search` / `grep_search`，名单外或不合形就拒绝，不论那次调用被没被拒（Kent 2026-10-16，超出 spec E2「工具身份只进日志」）。日志里没有 hook 那一行或没有 kiro.log、事件流里没有 `contentCollection`（版本改了形态）只警告。V3 的实际模型取自 `config_option_update`，与声明不同时挂提示、不拒绝。
- **V3 上不传任何 `--trust*`**：两者在 V3 下都打穿 allow 边界（S3：`--trust-all-tools` 与 `--trust-tools=read_file` 都读出了 allow 之外的 canary）。

## Considered Options

- **只支持 V3** —— 拒绝：一段时间内演示仍要用 V2。
- **独立的引擎开关、不进版本门** —— 拒绝：「2.31.1 + v2」这类没测过的组合会绕开门禁，等于从后门加回已删除的 `KIRO_ACK_UNTESTED_VERSION`。
- **一份同时兼容两个引擎的 agent 定义**（ADR-0004 的做法） —— 拒绝：每次为 V3 修改都会触及 V2，V2 的冻结就不成立了。
- **V3 的 cwd 仍是空目录（不能搜索）** —— 拒绝：评审能力比 V2 低一截，而评审根目录布局已实测能安全地搜索。
- **cwd = 业务库，把要删的文件列清楚** —— 拒绝：仓库的 hook 会被执行、同名 agent 会顶替，而「会被自动加载的文件」这份清单没有文档、以后的版本还可能变长。
- **ACP 的 `additionalDirectories` 把业务库挂成额外根目录** —— 拒绝：被挂上的目录同样加载 steering（S9 c09）。
- **`KIRO_HOME` / `KIRO_AGENT_CONFIG_DIR` 隔离** —— 拒绝：V3 的 `chat` 不认（S6）。

## Consequences

- **V2 冻结**：只保留 `darwin/arm64:2.29.0:v2` 与 `linux/x86_64:2.29.0:v2`；需要更老版本的用 v1.10.1 tag。等 3.x 不再提供 `--agent-engine v2`、或演示不再需要 V2 时，把 V2 的定义、分支与这两条组合一并删除。V2 定义的 description 里那句「V3 不上生产（ADR-0004）」因冻结而保留原文，以本 ADR 为准。
- **3.x 必须重新探测**：门禁清单不含 3.x；3.0 可能改事件形态、kiroignore 语义与加载规则，兜底负责防住加载规则悄悄变化。
- **模型读不到仓库里的 `AGENTS.md` 本身**：这一点不是新的——第 5.5 步本来就删除它们；它们的改动仍经 diff 进入评审。
- **临时 HOME 的开销**：每次运行在新 HOME 里准备一次引擎，另加四项设置写入与业务库副本。实测（2026-10-15，demo-app !10，与 v1.10.1 / V2 2.29.0 比）：
  AWS 档位 sandbox 执行器日志首尾 49 s 对 45 s（+4 s）；Flow 进 Kiro 之前 34 s 对 27 s（+7 s）。Flow 那次的模型一段 V3 124 s、V2 45 s，
  同一时段 gpt-5.6-sol 正在限流（前一次运行被 `ModelThrottleError` 拒掉），算模型时延，不算这套隔离的开销。
- **生成会话标题的那次模型调用**：2.29.1 上 V3 每次运行多这一次（S5，计入 credit）；v3 路径用 `KIRO_DISABLE_SESSION_TITLE_LLM=true` 关掉（见下一条）。
- **数据与网络通道（spike S8，2026-10-15，kiro-cli 2.31.1，API key 身份）**。能关的都关掉了（只作用于 v3 路径，v2 不变）；「关后停了」的证据逐项不同：
  - 遥测（OTLP → `telemetry.us-east-1.kiro.dev`）：临时 HOME 的设置 `telemetry.enabled false`。证据：本机 debug 日志 `Telemetry disabled by user preference`、端点里不再有 telemetry 主机（integration-local）。
  - 内容收集（service improvement）：设置 `codeWhisperer.shareCodeWhispererContentWithAWS false`；环境变量 `KIRO_CONTENT_COLLECTION_ENABLED=false` 无效（kiro-cli 自己替引擎设这个变量）。
    证据：本机引擎日志 `content_collection.resolved {"enabled":false}`、请求带 optout 头（integration-local）；sandbox 与本机探测的事件流 `contentCollection` = `disabled`，生产每次跑完都核对（上一条）。
  - 活动发布（`activity.publish`）：随内容收集一起不再出现——证据只是「日志不再出现」，代码路径没核实（推断）。
  - 服务端实验配置拉取：进程环境 `KIRO_DISABLE_EXPERIMENT_CONFIG=true`。证据：本机日志里不再出现（integration-local）。
  - 生成会话标题的那次模型调用：进程环境 `KIRO_DISABLE_SESSION_TITLE_LLM=true`。证据：读代码（`=== "true"` 直接返回；static）——2.31.1 未关的那组本来就没出现这次调用（实验配置超时、按缺省值），实测证明不了关后停了。

  关不掉、**Kent 2026-10-15 逐项接受**：
  - A 远程会话（`app.kiro.dev`）：每次都「已启用」，但一次性运行的 debug 日志里没有任何远程会话的网络调用；端点由 kiro-cli 以进程参数传给引擎，环境变量盖不掉。3.x 重新探测时复查。
  - B 云端配置拉取（`app.kiro.dev`）：API key 身份下每次 401，什么也拉不到；即使将来拉到，事件流兜底仍拦被改的 agent。
  - C API key 的区域探测：带 API key 向 `management.{us-east-1, eu-central-1, us-gov-east-1, us-gov-west-1}.kiro.dev` 发 `GetProfile`，us-east-1 成功后其余中止——Kiro 自己的凭证到 Kiro 自己的控制面。
  - D 远程工具清单：只拉清单（按 profile 过滤后只剩 `web_search`），受信 agent 用不了（工具只有 read / grep / glob，`web_search` 整体 deny）。

  另有一项不是外发通道、但 S8 点名要查的：`disclose_context`（skill 类工具，2026-10-16 补，static）。它按需把 skill 与 `inclusion: auto` 的 steering 文件读进上下文，
  不看 agent 的 `tools`、引擎总是把它加进工具集（S4 实测模型看得到它），调用时走权限检查。临时 HOME 与评审根目录里没有可加载的 skill / steering；
  受信 agent 对 `skill` 整体 deny，跑完再核对用到的工具都在只读名单内（69 份真实 V3 事件流里没用过它）。

  AWS 档位的出口白名单**不需要新的主机**：V3 用到的 `app.kiro.dev`、`runtime.us-east-1.kiro.dev`、`management.{us-east-1,eu-central-1}.kiro.dev` 都已在名单里；
  sandbox（DNS Firewall BLOCK）的真实评审里被拦的只有 `cognito-identity.us-east-1.amazonaws.com`（v1.10.1 同样被拦）与 `management.us-gov-*.kiro.dev`（C），评审照常完成。
- **ADR-0004 的四个切换门槛**：官方 GA 公告（2026-10-09 的 CLI 3.0 公告）；headless 文档支持 V3；`--trust-tools` 语义定型（V3 只认内部工具 id；生产从不传，探测 T6 记录）；canary 负向测试在 V3 下全过（`probe-kiro-allowlist.sh` 的门禁 15 个用例 + T5 / T13 正控：`darwin/arm64:2.31.1:v3` 2026-10-15 本机、`linux/x86_64:2.31.1:v3` 2026-10-15 sandbox 一次性 Fargate 任务）。
  真实环境另有：sandbox AWS 档位一次 `/review`、Flow 的 V3 与 V2 各一次评审、业务库自带 AGENTS.md / steering / hook 的 V3 负控（评论里没有任何 canary，这些文件的改动照常被评审）。
- **ADR-0006**：「每个进入已探测名单的元组连带发布两个摘要」不变；摘要按版本发布，同一版本的 v2 / v3 组合共用。
