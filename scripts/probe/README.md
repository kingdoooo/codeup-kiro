# scripts/probe — 环境探测脚本

把「只能实测才知道」的问题测掉。每个脚本对应设计规格里的探测编号（P1-xx），
输出 `PASS / FAIL / INFO / SKIP`；`probe-codeup-inline.sh` 还会把结果写成一份 JSON
留给运行者自己归档（脚本结尾提示的回填路径指向设计规格，那份文档不随本仓库分发）。

首轮探测已经跑过，结论已经落进实现（接口路径、必填字段、行号侧向、引擎选择都以实测为准）。
这些脚本保留下来供三种场合使用：

1. **接入新的组织/站点**：先确认行内评论相关接口的字段与响应形态与实现假设一致；
2. **端到端验收的 canary 负向验收**（`pipeline/setup-guide.md` 第 9.3 节）：
   `probe-kiro-headless.sh` 验证 AGENTS.md 继承隔离与敏感路径拒绝，
   并用 `PROBE_NO_ISOLATION=1` 做**正控**——故意关掉隔离设置，canary 应当出现，
   以此证明「canary 未出现」是保护生效而不是模型碰巧没照做；
3. **升级 kiro-cli 之后**：核对事件流形态（`runFinished.data.finalText`）与引擎行为是否仍成立。

**安全约定**：所有脚本只从环境变量或 `*_FILE` 文件读取令牌，任何输出都不包含令牌。
副作用逐个脚本看清楚：

- `probe-codeup-inline.sh` 直接在指定 MR 上建评论，因此要求 `PROBE_I_KNOW_THIS_IS_A_TEST_MR=1`
  显式确认那是测试 MR，并在结束时删除自己创建的评论（`PROBE_KEEP=1` 可保留，需手工清理）。
- `probe-flow-run.sh` **会真实触发一次评审运行**，那次运行会照常在指定 MR 上发评论；
  它**没有**测试 MR 门禁、也不清理评论。只在测试 MR 上用它，提交前核对 `MR_LOCAL_ID`
  与 `FLOW_PIPELINE_ID`。
- `probe-kiro-headless.sh` 不写 Codeup，但会消耗 Kiro credit，并临时改动真实 `$HOME`
  下的设置与 agent 目录（退出时恢复，见下文）。

| 脚本 | 覆盖 | 需要 |
|---|---|---|
| `probe-codeup-inline.sh` | P1-00 身份/MR · P1-01 版本列表 · P1-02 行号侧向 · P1-03 必填字段 · P1-04 草稿一次提交 · P1-05 原地更新 · P1-06 评论列表 · P1-09 `<details>` 渲染 | 令牌：代码只读 + 合并请求读写；一个打开的测试 MR |
| `probe-flow-run.sh` | P1-07 `CreatePipelineRun` 的 `envs` / `runningBranchs` 覆写 | 令牌：流水线读写；已配置的评审流水线 |
| `probe-kiro-headless.sh` | P1-08 `stream-json` 事件形态 · P1-10 AGENTS.md 继承隔离 · P1-11 禁止路径 · P1-12 `--engine v3` 对照 | 装有 kiro-cli 的机器 + `KIRO_API_KEY`（或本机已 `kiro-cli login`） |

## 用法

```bash
# 1) Codeup 行内评论（在测试 MR 上）
export YUNXIAO_TOKEN_FILE=/path/to/token.txt        # 或 YUNXIAO_TOKEN
export YUNXIAO_ORG_ID=... CODEUP_REPO_ID=... MR_LOCAL_ID=...
export PROBE_FILE=src/app.py PROBE_LINE_NEW=17 PROBE_LINE_OLD=12   # PROBE_LINE_OLD 可选
PROBE_I_KNOW_THIS_IS_A_TEST_MR=1 bash scripts/probe/probe-codeup-inline.sh
# 想在 UI 里看 <details> 渲染和通知行为：加 PROBE_KEEP=1，看完手工删除

# 2) Flow 运行参数覆写
export FLOW_PIPELINE_ID=... BUSINESS_REPO_URL=https://codeup.aliyun.com/<org>/<repo>.git
export SOURCE_BRANCH=feature/x MR_LOCAL_ID=7 MR_TARGET_BRANCH=master
bash scripts/probe/probe-flow-run.sh
# 然后到 Flow 运行日志核对 checkout 分支与「使用环境变量指定的 MR：#7」

# 3) kiro-cli headless（生产用的 v2 引擎；不传 KIRO_ENGINE 则用 CLI 默认引擎，实测表现为 v1）
export KIRO_API_KEY=...                              # 或本机已 kiro-cli login
KIRO_ENGINE=v2 bash scripts/probe/probe-kiro-headless.sh
# 3b) 正控：故意不设置 chat.disableInheritingDefaultResources，AGENTS.md canary 应当出现（P1-10 FAIL）
KIRO_ENGINE=v2 PROBE_NO_ISOLATION=1 bash scripts/probe/probe-kiro-headless.sh
# 4) 对照 V3（时间盒）
KIRO_ENGINE=v3 bash scripts/probe/probe-kiro-headless.sh
# 原始输出默认留在 /tmp/kiro-probe-<时间>，可用 PROBE_KEEP_DIR 指定目录
```

`probe-kiro-headless.sh` 会真实调用 Kiro（消耗 credit），并在真实 `$HOME` 下临时改动
agent 目录、`chat.disableInheritingDefaultResources` 设置与 `~/.kiro/` 下的 canary 文件——
三者都在退出时恢复/删除。

## 怎么读结果

- `probe-codeup-inline.sh` 会在当前目录写 `probe-codeup-inline.<时间>.json`。重点看：
  - P1-02a / P1-02b 的 `location.can_located` 与 `located_line_number`：决定 `line_number` 是新文件侧还是旧文件侧；
  - P1-03 是否 400：决定实现能否省略 `from/to_patchset_biz_id`；
  - P1-04 是否成功：不成功且提示需为评审人 → 退回逐条发布；
  - P1-05 更新后 UI 是否有通知。
- `probe-kiro-headless.sh`：P1-10（AGENTS.md canary 未出现）与 P1-11（敏感路径 canary 未出现）
  在 `KIRO_ENGINE=v2` 下都必须 PASS——任一 FAIL 都意味着安全隔离不成立，不得接入生产。
  正控（`PROBE_NO_ISOLATION=1`）下 P1-10 应当 FAIL；若正控也 PASS，说明这个 canary 根本测不出东西，
  结论无效（例如模型这次没有遵从那条良性格式要求），需要换 canary 重跑。

## 常见问题

- `file_path` 用相对仓库根的路径；若 `can_located=false`，换成带前导 `/` 的形式再试一次（官方示例两种写法都出现过）。
- 令牌权限不足会得到 401/403，脚本按确定性失败处理、不重试。
