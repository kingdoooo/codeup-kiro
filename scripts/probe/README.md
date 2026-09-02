# scripts/probe — 环境探测脚本

在动手实现行内评论与 AWS 档位之前，先把「只能实测才知道」的问题测掉。每个脚本对应
设计规格里的探测编号（P1-xx），输出 `PASS / FAIL / INFO / SKIP`，并把结果写成 JSON 便于回填。

**安全约定**：所有脚本只从环境变量或 `*_FILE` 文件读取令牌，任何输出都不包含令牌；
会写 Codeup 的脚本必须显式确认是测试 MR，并在结束时清理自己创建的评论。

| 脚本 | 覆盖 | 需要 |
|---|---|---|
| `probe-codeup-inline.sh` | P1-00 身份/MR · P1-01 版本列表 · P1-02 行号侧向 · P1-03 必填字段 · P1-04 草稿一次提交 · P1-05 原地更新 · P1-06 评论列表 · P1-09 `<details>` 渲染 | 令牌：代码只读 + 合并请求读写；一个打开的测试 MR |
| `probe-flow-run.sh` | P1-07 `CreatePipelineRun` 的 `envs` / `runningBranchs` 覆写 | 令牌：流水线读写；已配置的评审流水线 |
| `probe-kiro-headless.sh` | P1-08 `stream-json` 事件形态 · P1-10 AGENTS.md 继承隔离 · P1-11 禁止路径 · P1-12 `--engine v3` 对照 | 装有 kiro-cli 的机器 + `KIRO_API_KEY` |

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

# 3) kiro-cli headless（默认引擎）
export KIRO_API_KEY=...
bash scripts/probe/probe-kiro-headless.sh
# 4) 对照 V3（时间盒）
KIRO_ENGINE=v3 bash scripts/probe/probe-kiro-headless.sh
```

## 怎么读结果

- `probe-codeup-inline.sh` 会在当前目录写 `probe-codeup-inline.<时间>.json`。重点看：
  - P1-02a / P1-02b 的 `location.can_located` 与 `located_line_number`：决定 `line_number` 是新文件侧还是旧文件侧；
  - P1-03 是否 400：决定实现能否省略 `from/to_patchset_biz_id`；
  - P1-04 是否成功：不成功且提示需为评审人 → 退回逐条发布；
  - P1-05 更新后 UI 是否有通知。
- `probe-kiro-headless.sh` 三项任一 FAIL 都是阻塞项：P1-10/P1-11 FAIL 意味着隔离不成立，不得进入实现。

## 常见问题

- `file_path` 用相对仓库根的路径；若 `can_located=false`，换成带前导 `/` 的形式再试一次（官方示例两种写法都出现过）。
- 令牌权限不足会得到 401/403，脚本按确定性失败处理、不重试。
