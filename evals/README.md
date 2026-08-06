# metacodes Harness 评估框架

这套框架把《Agent Harness Engineering: A Survey》中的 ETCLOVG 分类和五阶段
task-to-feedback lifecycle 落到 metacodes。论文原文：
[Agent Harness Engineering: A Survey](https://picrew.github.io/LLM-Harness/main.pdf)。

它不替代 `zig build test` 或 `tests/e2e/run_e2e.sh`：前者验证代码，后者执行真模型场景；
本框架负责把执行 episode 变成可比较、可归因、可门禁的工程证据。

## 中文精读

### 1. 什么是 harness engineering

Prompt engineering 只设计单次模型调用的指令；context engineering 决定模型在每一步能看到
什么；harness engineering 则设计包围模型调用的完整闭环：模型输出怎样变成受控动作，工具和
环境结果怎样反馈回来，状态怎样保存，何时重试或停止，哪些动作需要权限和人工审批，执行过程
怎样被观测、验证和恢复。

因此，agent 的测量结果属于 `model × harness`，而不是模型本身。比较模型时要锁定 harness；
比较 prompt、工具 schema、context 策略、权限或 agent loop 时要锁定模型。两者一起变化只能称为
joint comparison，不能把差异归因给其中一个。

### 2. ETCLOVG 七层

| 层 | 论文定义 | metacodes 对应面 |
|---|---|---|
| E - Execution | 执行环境、沙箱、隔离与复位 | workspace/fake HOME、Seatbelt、子进程、worktree |
| T - Tooling | 工具描述、发现、选择和协议 | Tool schema、MCP、Read/Write/Edit/Bash、Task |
| C - Context | 活跃窗口、session、长期记忆和漂移 | conversation、compact、transcript、memory/TinyKG |
| L - Lifecycle | agent loop、状态、恢复、编排和 handoff | agent_loop、subagent、swarm、task DAG、resume |
| O - Observability | trace、成本、延迟、错误和可靠性 | debug log、CoreEvent、usage、record/replay |
| V - Verification | benchmark、判定、归因和回归 | L1-L5、EXPECT、replay、本文框架 |
| G - Governance | 身份、权限、策略、审计和人工监督 | permission decision、hooks、sandbox、approval UI |

E/T/C/L 是结构核心，O/V/G 是包围核心的控制面。七层不是独立 checklist：工具描述会占用
context，权限会改变动作空间，sandbox 会改变失败模式，trace 若不记录身份和权限就不能成为审计
证据。局部优化必须通过整条 rollout 回归验证。

### 3. 五阶段 task-to-feedback 闭环

1. **Task and Benchmark Grounding**：任务不只是 prompt，还必须固定仓库/环境状态、工具、
   允许动作、约束、终止条件和可执行成功条件。
2. **Pre-execution Readiness**：运行前检查 sandbox、依赖、工具、context reset、权限、预算、
   grader。环境坏、grader 坏或测量信息缺失时不能把结果记成 agent fail。
3. **Controlled Execution and Trace Capture**：rollout 是基本测量单位。记录 model+harness 配置、
   模型输出、工具调用/结果、状态变化、错误、重试、恢复、token、成本和延迟。
4. **Multi-level Judgement and Failure Attribution**：分别判断 outcome、trajectory 和 evaluator。
   最终结果正确仍可能轨迹不可接受；grader 自身也必须被测试。故障允许多标签归因到模型、
   E/T/C/L/O/V/G、benchmark 或 grader。
5. **Continuous Regression and Feedback**：把失败 trace 变成回归用例和门禁；prompt、工具、
   context、sandbox、权限和 grader 的变化都应触发评估。

### 4. 为什么不能只看 pass rate

成功率必须和成本、延迟、工具调用、重试、安全与方差一起报告。一个 harness 可以靠更多 token、
更强模型或无限重试提高成功率，却不一定更适合部署。框架因此同时报告：

- `Outcome success`：有效 rollout 中最终任务是否完成；
- `Trustworthy success`：还要求执行有效、trajectory 通过、evaluator ready；
- Wilson 95% 区间：小样本下避免把 6/6 误读成确定的 100%；
- token、成本、壁钟、工具调用、turn、重试的 mean/P50/P95/total；
- invalid、unscored、策略违规与 ETCLOVG 多标签归因；
- 配对版本比较使用 exact McNemar，而不是把同一任务的重复运行当独立样本。

论文是 170+ 开源项目的综述地图，不是经过验证的成熟度标准。它采用单主编码者加作者审计，
没有正式标注者一致性统计，并偏向英语、GitHub、开源和 coding-agent 生态。本框架借用其结构，
但门槛和权重必须用 metacodes 自己的历史数据校准。

## 目录与职责

- `evals/suites/core-e2e.json`：Stage 1 的可执行任务定义，覆盖环境、工具 profile、权限、
  outcome checks、trajectory constraints、grader version 和 ETCLOVG 标签。
- `scripts/eval/model.py`：suite/rollout 的可执行 schema；非法状态在进入统计前被拒绝。
- `scripts/eval/e2e_adapter.py`：把已有 `tests/e2e/runs/<timestamp>` 规范化成 rollout JSONL。
- `scripts/eval/analysis.py`：汇总、配对比较、归因和 fail-closed gate。
- `scripts/eval/statistics.py`：Wilson 区间、分位数、exact McNemar（无第三方依赖）。
- `scripts/eval/cli.py`：统一 CLI。
- `scripts/eval/tests/`：评估器自身的确定性测试；`zig build test:eval` 运行。

## Rollout 状态语义

框架刻意不使用一个 `pass/fail` 字段压扁整个 episode：

- `execution.status = completed | invalid`：环境、网络、harness 崩溃或缺关键 trace 时是 invalid；
- `outcome.status = pass | fail | unscored`：只回答最终任务；
- `trajectory.status = pass | fail | unscored`：工具选择、调用数、错误、权限等路径约束；
- `evaluator.status = ready | invalid`：grader 输入、版本和依赖是否可信；
- `judgement.valid_for_scoring`：invalid rollout 不进入成功率分母；
- `judgement.trustworthy_success`：上述三层都满足才为真。

`invalid` 不能偷换成 `fail`，否则网络故障会被误归因给模型；`unscored` 也不能偷换成 `pass`，
否则没有成功条件的 demo 会污染能力分数。

## 使用

所有命令从 `metacodes/` 运行，仅依赖 Python 标准库。

### 1. 校验任务定义

```bash
python3 scripts/eval/cli.py validate-suite evals/suites/core-e2e.json
```

### 2. 运行现有真模型 E2E

```bash
tests/e2e/run_e2e.sh
```

对 suite 中的场景，驱动会在启动子进程前冻结 task、model、harness（二进制哈希 + revision +
config）、environment 和 grader fingerprint。metadata 与 event stream 都通过 runner 持有的匿名
fd 传递；metacodes 启动后立即把 fd 标为 close-on-exec，因此 Bash/MCP/其它工具子进程拿不到评估
控制面。agent 退出后 runner 才将 `CoreEvent → EvaluationBackend` 的完整流以 `0600`、不覆盖既有
路径的方式落为场景目录 `events.jsonl`。suite 外的探索场景继续运行，
但不会被伪装成有 grounding 的计分样本。可用 `E2E_MODEL`、`E2E_MODEL_PROVIDER`、
`E2E_HARNESS_CONFIG_ID` 和 `E2E_TRIAL` 显式设置实验轴。

### 3. 规范化一个 run

```bash
python3 scripts/eval/cli.py import-e2e \
  --suite evals/suites/core-e2e.json \
  --run tests/e2e/runs/<timestamp> \
  --output /tmp/metacodes-rollouts.jsonl
```

原生 `events.jsonl` 存在时，适配器优先直接消费其中的 execution-time metadata、token、估算
成本、wall-clock、工具错误、重试和权限决策；debug log 仅作兼容 artifact。历史 E2E 没有记录
git revision、完整 harness config、wall-clock 和 cost 时，适配器保留结果，
但报告会明确发出测量完整性警告。`--config` 可补入已知的 model/harness 元数据：

```json
{
  "model": {"provider": "anthropic", "id": "model-id"},
  "harness": {
    "config_id": "baseline-2026-07-31",
    "revision": "git-sha",
    "permission_mode": "bypassPermissions"
  }
}
```

这仍不能把历史 run 变成严格 A/B：task fingerprint 是导入时按当前 suite 推断的，不是执行时
记录的。`compare` 会 fail closed，拒绝这种事后 grounding。正式 A/B 使用原生 evaluation
events，在 rollout 开始前冻结并记录 task、环境、grader、model 和 harness fingerprint。

### 4. 报告

```bash
python3 scripts/eval/cli.py report /tmp/metacodes-rollouts.jsonl \
  --markdown /tmp/metacodes-eval.md \
  --json /tmp/metacodes-eval.json
```

### 5. 配对比较

```bash
python3 scripts/eval/cli.py compare baseline.jsonl candidate.jsonl \
  --factor harness \
  --markdown comparison.md \
  --json comparison.json
```

`--factor harness` 强制 model 相同；`--factor model` 强制 harness 相同；两边 grader fingerprint
不同会直接拒绝比较。`--factor joint` 允许两者都变，但报告会声明无法做单因素归因。
正式实验用 order-balanced runner 重复执行；奇偶 trial 交换 baseline/candidate 先后顺序，降低
时间漂移和 provider 短时波动偏差：

```bash
python3 scripts/eval/cli.py run-paired \
  --baseline-binary /path/to/baseline/metacodes \
  --candidate-binary /path/to/candidate/metacodes \
  --baseline-revision <baseline-git-sha> \
  --candidate-revision <candidate-git-sha> \
  --trials 5 \
  --baseline-output baseline.jsonl \
  --candidate-output candidate.jsonl
```

两侧 revision 必须显式提供；runner 会分别冻结到 rollout 身份和 checkpoint，不能从当前工作树
替旧二进制猜 revision。runner 每个昂贵 rollout 后 checkpoint JSONL。比较要求
`(task_id, trial)` 集合完全相同，并报告
paired delta 的均值、样本方差、Student-t 95% CI、P50/P95、exact McNemar，以及
quality–cost–latency frontier（dominates / dominated / tradeoff / equivalent）。cost 或 wall-clock
任一侧缺失时比较 fail closed。

### 5.1 三臂长程机制实验（分级合同 v2）

两个 manifest 共享 `metacodes-long-horizon-pk-v2`、同一 `glm-5.2`、同一二进制和三种
typed treatment：`codex_style`（transcript + compact）、`claude_style`（再加 Markdown
AutoMemory）和 `tinykg`（再加 TinyKG/DAG 与原生 Lean formal audit）。两阶段都关闭 swarm，避免额外模型调用成为混杂因子；
每个阶段使用 6-row Williams-style block，平衡顺序位置和一阶 carryover。

- `long-horizon-three-arm-calibration-v2.json`：1 个非结论性机制任务 × 3 臂 × 6 trial =
  18 rollouts；只校验基础设施、遥测、checkpoint 和 treatment 隔离，阶段上限 $100 / 24M token。
- `long-horizon-three-arm-confirmatory-v2.json`：3 个 held-out 真实历史仓库快照 × 3 臂 ×
  6 trial = 54 rollouts；只在校准 receipt 通过后计分，阶段上限 $900 / 66M token。
- 两阶段 aggregate 硬上限 $1000 / 90M token。每个 rollout 在所有 arm/order position
  上固定为最多 $2 / 1.2M metered token；runner 在任何模型请求前证明完整剩余 schedule 的
  固定上限总和严格小于 stage 与 aggregate 剩余额度。confirmatory runner 自动把 receipt 中的校准消耗
  纳入总预算，不能靠换 output directory 清零。

最初的 3M/30M token 合同经两次非结论性 calibration 被实测证伪：完整 trial-0 的单 rollout
最高达到 1,017,497 metered token，旧合同即使每条都恰好达成也不可能容纳 18 条 schedule。
24M/90M 是基于该非评分资源上界预注册的容量修正，不改变 $100/$1000 用户授权、任务、grader、
arm treatment 或 confirmatory held-out 数据。旧失败 checkpoint 保留原 fingerprint，不能混入新 schedule。

confirmatory 的 83–85 任务从三个完整 Git commit id 安全抽取稀疏快照，分别覆盖 POSIX pipe
hangup drain、Windows swarm lock liveness 和 AgentCore Skill identity。物化器拒绝链接、特殊文件、
路径逃逸及超过 2048 files/64 MiB 的快照；commit/tree、路径清单、场景 `.conf` 和仓库外隐藏
validator 的 SHA-256 全部进入 task/grader fingerprint。提示词不得出现 TinyKG/Codex/Claude/arm
等 treatment 标签，grader 只看到 workspace。

先分别执行零成本 dry-run：

```bash
python3 scripts/eval/cli.py run-multi \
  --experiment evals/experiments/long-horizon-three-arm-calibration-v2.json \
  --binary zig-out/bin/metacodes \
  --tinykg-binary zig-out/vendor/tinykg/tinykg \
  --formal-kernel zig-out/libexec/metacodes/metacodes-formal-kernel \
  --revision "$(git rev-parse HEAD)" \
  --output-dir /tmp/metacodes-lh3-calibration \
  --dry-run --plan-output /tmp/metacodes-lh3-calibration-plan.json

python3 scripts/eval/cli.py run-multi \
  --experiment evals/experiments/long-horizon-three-arm-confirmatory-v2.json \
  --binary zig-out/bin/metacodes \
  --tinykg-binary zig-out/vendor/tinykg/tinykg \
  --formal-kernel zig-out/libexec/metacodes/metacodes-formal-kernel \
  --revision "$(git rev-parse HEAD)" \
  --output-dir /tmp/metacodes-lh3-confirmatory \
  --dry-run --plan-output /tmp/metacodes-lh3-confirmatory-plan.json
```

runner 会把 Lean checker 二进制、相邻 provenance 及其版本化协议验证为一个 artifact identity，
将 identity 绑定到三臂 config/checkpoint，但只向 `tinykg` 臂注入 checker 路径与 SHA-256；
基线臂既拿不到路径，也不能从宿主环境继承它。用户在 2026-08-06 授权总预算不超过
$1000 后，checked-in calibration manifest 只开启最多 $100 / 24M token 的基础设施校准；
confirmatory manifest 仍保持 `paid_rollouts_enabled=false`。真正执行 calibration 还必须显式传
`--allow-paid-rollouts`，形成合同与命令行双钥匙。每个昂贵 rollout 后独立原子 checkpoint；invalid 或基础设施
失败先保留证据再中止。TinyKG binary 的 storage/schema/version/SHA 会在执行前冻结，只有 TinyKG
臂收到其路径；runner 同时清除宿主 `METACODES_*`、`TINYKG_*`、`E2E_*`、
`CLAUDE_CODE_*` 和 `RG_BIN` 污染。

18 个校准 rollout 全部有效、cost/token 遥测完整且未触及阶段预算后，生成不可混用的 promotion
receipt：

```bash
python3 scripts/eval/cli.py promote-multi \
  --experiment evals/experiments/long-horizon-three-arm-calibration-v2.json \
  --codex-style /tmp/metacodes-lh3-calibration/codex_style.jsonl \
  --claude-style /tmp/metacodes-lh3-calibration/claude_style.jsonl \
  --tinykg /tmp/metacodes-lh3-calibration/tinykg.jsonl \
  --output /tmp/metacodes-lh3-calibration/promotion.json
```

confirmatory 执行和正式报告都必须同时提供 receipt 与原始 calibration directory。confirmatory
manifest 冻结 calibration manifest 路径及其 experiment+suite fingerprint；runner 会重新读取三份
JSONL、复算完整 18-rollout release contract、遥测/预算/identity 和文件 SHA。receipt 只是可缓存的
审计摘要，不能脱离源 checkpoint 单独授权。正式报告还会验证 54 个 confirmatory pair、当前
experiment fingerprint 与全部 identity：

```bash
python3 scripts/eval/cli.py report-multi \
  --experiment evals/experiments/long-horizon-three-arm-confirmatory-v2.json \
  --codex-style /tmp/metacodes-lh3-confirmatory/codex_style.jsonl \
  --claude-style /tmp/metacodes-lh3-confirmatory/claude_style.jsonl \
  --tinykg /tmp/metacodes-lh3-confirmatory/tinykg.jsonl \
  --promotion-receipt /tmp/metacodes-lh3-calibration/promotion.json \
  --calibration-dir /tmp/metacodes-lh3-calibration \
  --markdown /tmp/metacodes-lh3-confirmatory/report.md \
  --json /tmp/metacodes-lh3-confirmatory/report.json
```

### 6. 自动门禁

```bash
python3 scripts/eval/cli.py gate candidate.jsonl \
  --baseline baseline.jsonl \
  --factor harness \
  --suite evals/suites/core-e2e.json \
  --suite evals/suites/agentdef-release.json \
  --expected-trials 6 \
  --thresholds evals/gates/default.json
```

`candidate.jsonl` 与 `baseline.jsonl` 必须各自包含 release contract 声明的全部 suite（可以把
各次 `run-paired` 输出按侧拼接成一个 JSONL）。Production gate 原子校验全部 suite；少传一套、
混入额外 suite、跨 suite 重复 task id 或 run id 都直接失败，不能用单套 PASS 冒充完整发布证据。

缺 policy telemetry 时门禁默认失败；只有明确使用 `--ignore-policy-telemetry` 才跳过。统计显著性
用于解释结果，不替代工程阈值：小样本的严重回归不能因为 `p > 0.05` 就放行。阈值文件带
机器可验证的 production calibration 与 release contract；校准还必须绑定当前 evaluation contract
version，旧适配器生成的 rollout 即使结构仍可读取，也不能进入发布门禁。门禁要求 suite 中每个 task 恰好包含
`0..trials-1` 的完整 rollout、无重复或额外 pair，并校验 model、task、grader、permission、
environment、harness revision/fingerprint 等 execution-time identity；删除失败样本或混入旧环境会
直接报错，而不是用剩余样本计算通过率。2026-08-01 的 `glm-5.2` AgentDef 30 对和 core E2E
36 对历史校准曾两套 suite 均 9/9 通过、且没有放宽阈值；policy 精确配对与 latency
fail-closed 先将 evaluation contract 升到 v2；随后可信匿名 fd、no-follow regular-file 校验和
64 MiB artifact 上限将 contract 升到 v3。该 v1 校准已机器可读地标记为 `stale`。重新完成
当前 contract 的 6-trial order-balanced native 校准前，默认 production gate 必须拒绝发布。

## 与现有 L1-L5 的关系

- L1/L2/L3/L4 继续验证纯逻辑、跨模块接线、真实本地副作用和确定性回放；
- L5 `tests/e2e` 继续负责真模型 rollout、隔离、record/replay 和原始 artifacts；
- 本框架是 L5 上方的 evaluation control plane：统一数据模型、readiness、三级判定、归因、
  统计比较和 deployment gate；
- 线上 failure trace 可被固化成新 suite task，再下沉为 L2/L3/L4 回归，完成 Stage 5 闭环。

## 当前边界

当前原生路径输出 versioned evaluation events，并由同一 schema 直接消费；工具 input/result 只
记录长度和 SHA-256，不复制敏感内容。原生 artifact 仅接受 regular file，拒绝 symlink/FIFO、无界
读取和 agent 运行期可替换的路径通道。成本来自内置 2026-04 价格表并显式标记 fallback provenance，
因此未知代理模型的金额应视为估算值。历史 run 仍走 debug-log 兼容适配，并明确报告 wall-clock、
成本、policy telemetry 和 execution-time fingerprint 的缺口，不做事后补真。
