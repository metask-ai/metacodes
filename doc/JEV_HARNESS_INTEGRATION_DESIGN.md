# Jev × metacodes Harness 接入方案

> **状态：历史提案，没有按本文实现。** 本文是 2026-09-23 由 Codex 起草的接入方案，
> 原文保留，作为 [JEV_SYSTEM_ONE.md §5](JEV_SYSTEM_ONE.md#5-与-codex-方案的融合)
> 逐条取舍的输入。实际落地的是记忆面顾问：内核边界、shadow/advisory 两档、零重试和
> 离线回放驱动被采纳；JevTree 图搜索、动作族评分和 bounded nudge 推迟；enforced-safe
> 被拒绝。文中“默认 disabled”已经不成立：CLI 内置默认以 advisory 模式咨询 Jev，且只开
> `scoped_recall` 一个面（#195、#197）。当前行为以 JEV_SYSTEM_ONE.md 为准。

原状态：设计提案。本文不改变当前运行时行为，也不把 Jev 作为默认 provider。

基线：metacodes `main` 已同步到 `95980e10aaddf5634468c07b5d1e107e21290905`
（`0.2.0-dev`）。该基线包含 context-window recovery、stream liveness 和
environment-fault stop；Jev advisor 应在这些现有边界之后工作。

## 目标与边界

目标是改善长任务中的下一步选择、验证覆盖和失败恢复，同时保持 metacodes 的
因果所有权。Jev 只提供结构化判断；JevTree 的图搜索只负责组合这些判断。以下
组件仍由 metacodes 内核独占：AgentLoop、Conversation、工具合法性、权限与沙箱、
取消、预算、Lean/project rule verdict、TinyKG admission/CAS、artifact store、
durable journal 和最终 harness/grader 判定。

接入后默认仍是 `disabled`。没有配置、advisor 子预算不足、服务错误、答案校验
失败或状态发生变化时，advisor 可以退回 baseline；宿主取消、总预算拒绝、durable
journal/checkpoint 写失败、permission 或 formal 错误仍按现有 fail-closed/poison
语义，不能借“Jev 降级”绕过。Jev 的概率永远不是授权、成功证明或事实来源。

## 从 JevTree 借什么

jev-tree 在 commit
[`c129b4d0`](https://github.com/Chuf-H/jev-tree/tree/c129b4d0eed274dcb1500d69b8eef0ed6ef621f8)
中把问题限制为有限决策问题：adapter 提供 `initial_state`、`common_state`、
稳定的 `decision_key`、合法动作查询、纯 `apply`、廉价的 `is_terminal`、正向
到达后的 `terminal_outcome` 和诊断用 `state_payload`。详见
[adapter contract](https://github.com/Chuf-H/jev-tree/blob/c129b4d0eed274dcb1500d69b8eef0ed6ef621f8/docs/ADAPTER_GUIDE.md#L7-L61)。

可迁移的运行时思想有四个：

1. 对同一语义状态只查询一次 Jev，合并等价状态，但保留不同逻辑路径的概率质量。
2. 把 `P(action | state)` 沿路径相乘，分别汇总成功、失败和未展开的
   `unresolved` mass；不能把因查询预算而省略的边重新归一化。
3. 用下游 terminal success、失败风险和当前动作概率组成 Pareto 选择，不只取当前
   `argmax`。
4. 真实环境采用“观察 → 有限候选 → 短视界规划 → 风险/人审门 → 执行一个动作 →
   重新观察”，旧图在 observation revision 改变后失效。

完整树适合 Game24 这类可枚举、纯函数、可验证的问题。编码任务的命令、补丁和
工具结果不能可靠地预模拟，因此在线只采用 receding-horizon/adaptive graph；
coding adapter 第一版固定 `max_depth=1`，只产出 local action preference，所有
未真实执行的分支均为 `unresolved`，不能叫 downstream success mass，也不能把
Jev path mass 当成现实成功概率。完整树、合并图和 downstream-success policy
只在另一个具有纯 transition 和 forward verifier 的有限 workflow adapter 中验证。
最多展开很小的候选集合，其余质量显式记为 `unresolved`。jev-tree 当前
`max_states` 边界有省略分支后重新归一化的实现风险，metacodes 实现必须以
“每个被裁剪候选保留 unresolved edge/mass”为硬不变量。

Jev 本身是 typed decision engine，不是代码生成器或 coding-agent LLM。官方说明
的 HTTP 接口是 `POST /v1/systemone`，请求包含 `state`、固定的 `model` 和
`questions`；Choice 返回完整选项分布。参见
[TypeSafe API](https://docs.typesafe.ai/api)、[Jev models and limits](https://docs.typesafe.ai/models)
和 [coding-agent positioning](https://docs.typesafe.ai/introduction/coding-agents)。

## 与当前 metacodes 的落点

当前 `src/plugin/runtime.zig` 的 `advisory_hook` 只有布尔型
`allowsTool/allowsInvocation` 上限，不能表达概率分布、Pareto 结果或
`unresolved` mass；不能把 JevTree 硬塞进这个接口。当前 process plugin v1 也
只有 `host_tool`，不能隐式包住 AgentLoop。合适的形状是一个由内核拥有生命周期
和验证规则的 `DecisionAdvisor` typed seam，由 Host 选择是否安装。

建议把 seam 放在 turn boundary：上一轮 stream 已结束、同批 tool slots 已 join、
结果已经按原顺序提交、UI steering 已 drain 后，再建立只读 observation。
`response_observer` 运行在 loop 线程上，契约要求 callback cheap/non-blocking；它
只能采集规范化元数据，不能承载 sidecar，也不能改变已经进入 prefetch/dispatch
的 tool_use。数据流是：

```text
AgentLoop 构造 effective tool set
  → 生成并校验有限、互斥的 Host decision 候选
  → DecisionAdvisor 只读评分/规划
  → 普通 provider/tool-choice 或 bounded nudge
  → permission / sandbox / ToolExecutionPolicy
  → PreToolUse / project_rule_gate / dispatch
  → tool observation + durable journal
  → terminal verifier 后 settle，再规划
```

候选动作必须来自当前 effective tools 和宿主的确定性枚举，不能由 Jev 生成命令、
路径或新的工具名。第一版建议只包含动作族和已经规范化的候选调用：

| 动作族 | 第一阶段用途 | 终止事实 |
|---|---|---|
| `Read` / `Grep` / `Glob` / `CodeMap` / `FindSymbol` | 查证需求、定位定义、收集证据 | tool observation |
| `RunTests` / `ReviewDiff` / `ProjectRuleCheck` | 验证变更与收尾 | 测试、project/Lean verdict |
| `KgRecall` / `KgContext` | 只读地补充已准入记忆 | TinyKG read receipt |
| `Write` / `Edit` / `ApplyPatch` / `Bash` | 第二阶段只做风险排序或建议 | 真实 effect + re-observation |
| `Finalize` / `AskUser` / `Delegate` | 收尾与人审建议 | requirement/output/grader |

现有 assistant response 中的多个 `tool_use` 是已经承诺且需要配对的一个执行批次，
不是互斥候选；v1 不删除、延期、重排或只执行其中一项。Jev 候选必须是一个新的、
尚未提交到 Conversation 的 Host decision（例如下一轮验证包或检索策略），实际
落地首版只转成有界 nudge，交给普通模型选择。若未来需要 exact route，必须新增
明确的 choice protocol，不能复用已提交的 tool-use batch。

每个候选带稳定 `action_id`（工具族 + canonical 参数摘要的 hash）、风险类别、
可逆性、所需 capability 和当前 permission 分类。候选在进入 Jev 前就已经通过
schema、有效工具集和普通权限分类；Jev 返回未知 id、过期 revision 或不完整分布
时全部作无效建议。

建议的内核数据形状如下，实际命名和 ABI 版本在实现阶段冻结：

```zig
pub const DecisionObservation = struct {
    schema_version: []const u8,
    observation_revision: u64,
    state_key: [64]u8,
    task_fingerprint: [64]u8,
    workspace_digest: [64]u8,
    candidates: []const CandidateAction,
    budget_bucket: BudgetBucket,
    permission_fingerprint: [64]u8,
};

pub const DecisionAdvice = struct {
    observation_revision: u64,
    action_probabilities: []const ActionProbability,
    selected_action: ?ActionId,
    unresolved_mass: f64,
    mass_error: f64,
    policy: SelectionPolicy,
    actuation: Actuation, // observe | advisory; never permission
};
```

`DecisionAdvisor` 的 callback 只能借用当前 observation，不能取得可变 AgentLoop、
Conversation、Permission、Lean 或 TinyKG handle。它不能启动 tool effect、写
TinyKG、改变 `tool_defs` 的安全上限或提高预算。Jev 查询可由 Host sidecar 执行，
但请求必须在同一 run 的取消、deadline、预算和 evidence journal 下登记。

## 状态与动作适配器

`common_state` 只包含宿主生成的最小、脱敏快照：任务摘要、requirements ledger、
当前 worktree/content digest、已验证的 diff 摘要、最近工具结果的错误类别、
TinyKG read revision、permission/capability fingerprint 和剩余预算桶。不要发送
完整 transcript、秘密、API key、绝对路径、时间戳、plugin generation、journal
路径或未过滤的对抗性工具输出；文本片段必须按不可信输入处理。

`decision_key` 只在这些语义字段相同时合并；不能用过宽的 hash 把不同需求、不同
工作树或不同权限状态合并。缓存键应为
`SHA256(model_version || schema_version || canonical_state || canonical_questions)`，
不以动态时间或请求 id 组成 provider-visible prompt。真实 transition 不符合预测
时丢弃旧子树并从新 observation 规划。

Jev 问题保持窄而封闭：Choice 的合法动作逐项枚举，必要时拆成动作族、风险 Noul
和验证 Score，并在一次请求中并行发送独立问题。算术、计数、日期、预算、权限、
路径和测试结果由 Zig/内核代码确定，不交给 Jev 推理。`jev-latest` 必须在实验中
解析为实际版本并固定到 manifest；生产配置应固定具体 model id，避免别名漂移。

## 控制模式与故障语义

实现分三档，便于把 harness 改善与模型质量隔离：

1. **shadow**：调用 Jev 并记录分布、Pareto 选择、actual-vs-selected 和
   unresolved，但完全不改行为。默认先跑这一档。
2. **advisory**：只对新的 Host decision 候选评分，或发一条有界的普通 nudge；
   不拒绝合法动作，不直接执行 Jev 推荐，也不重排已经提交的 tool-use batch。
3. **enforced-safe（后续）**：只允许对可逆、已通过原生 policy 的只读动作做
   bounded exact route；Write/Edit/Bash、TinyKG 写入、不可逆外部调用仍需要原有
   permission、formal 和人审路径。Jev 失败时退回 advisory 或 baseline，不能
   自动扩大查询或预算。

每次真实动作后只保留新的 observation；只有新增的 Host decision 才能一次选择一个
动作，现有模型 tool batch 仍按原 AgentLoop 语义执行。低 confidence、较高 unresolved、候选覆盖不足、
   stale revision、API 429/529/5xx、超时、解析错误和预算拒绝都产出结构化
   `unresolved`/`provider_error`，不伪装成失败或成功。Jev SDK/HTTP 重试必须显式
   设为零或把每个物理 attempt 纳入同一 budget journal；禁止静默重试。

## HTTP、预算和隐私边界

Zig 集成不依赖 Python SDK；可以在 Host sidecar 或受控 HTTP adapter 中实现当前
System One JSON 契约。响应必须严格校验：answer id/type、Choice 选项覆盖、概率
范围与总和、Score legend、Noul 范围和 usage。401/403/404/422 直接永久失败；
408/429/5xx/529、连接错误和超时只允许在总 deadline 与预算内有限退避，并记录
`x-typesafe-request-id`、实际 model、usage、延迟和错误类别，不记录 key 或 debug
正文。官方接口和模型限制以
[OpenAPI](https://api.typesafe.ai/openapi.json)、[retries](https://docs.typesafe.ai/sdk/python/api/retries)
和 [exceptions](https://docs.typesafe.ai/sdk/python/api/exceptions) 为准。

Jev 请求是第二种 provider side effect，不能绕过 `request_gate`/evaluation budget。
实现时应增加 kernel-owned `BudgetAccount`/`ProviderCharge`，按
`provider_kind + model + pricing_receipt + input/output/cost upper bound` 在请求前
原子 reserve、请求后 settle known/unknown usage。主 provider 与 Jev 各自费率，
共享总上限并有 decision 子预算；未知 usage 保留 reserve，不退款。decision-query
telemetry 至少记录 query 数、输入/输出 tokens、实际 model、成本、延迟、cache hit、
mass error、unresolved mass 和 selection policy。Jev 子预算耗尽时跳过 advisor 回到
baseline；总预算拒绝仍由现有 Abort/stop reason 处理，Jev 永远不能把预算返还给普通
provider。shadow 仍消耗预算和延迟，只能声明 actuator 未改变，不能声明零成本。

Jev provider 默认关闭、API key 只存在宿主环境或 secret reference；state 先脱敏、
按内容 hash 缓存，正文按明确 retention policy 处理。Jev 结果是建议证据，不是
TinyKG memory、task claim、ontology promotion 或 formal verdict。

## 分阶段实施与验收

### Stage 0：离线回放适配器

现有 `tool_observation_journal`/`EvalEvent` 只有 hash、size、错误类别和 effect 等
执行证据，不能反推出完整 state、参数或 counterfactual candidates。Stage 0 要从
显式版本化的 `DecisionFixture`（最小脱敏 semantic snapshot、候选清单、纯 transition
table、forward-verifier receipt）读取；现有日志只用于 trigger/频率/overhead 基线。
使用 heuristic/uniform backend 验证 action coverage、稳定 key、纯 `apply`、terminal
verifier、路径/状态合并、mass conservation 和 unresolved 记账；不发网络请求，不改
AgentLoop。

### Stage 1：shadow observer

新增 `src/core/decision_advisor.zig`（名称待冻结），由 `AgentLoop.Options` 可选
挂载，在一个完整 turn boundary、effective tool set 和 native permission 分类之后
观测；不在 stream 或 prefetch 路径中阻塞。
写入 versioned `jev_decision_query_v1`、`jev_action_distribution_v1`、
`jev_selection_v1` 事件；默认 `actuated=false`。`response_observer` 可以提供
规范化 tool_use 观察，但不能成为 Jev 改写 Conversation 或启动副作用的通道。

### Stage 2：只读 receding-horizon

对新增的 Host decision 执行一个已经通过原生权限的安全动作，收到 observation 后
重新规划；coding adapter 只比较 local preference，`downstream_success` 只在独立
纯 transition workflow 上做 paired replay，分开评估 harness policy 与 Jev provider。
每个候选都保留 original model action（若有）、Jev selected action、实际 dispatch、
formal/tool outcome 和 unresolved mass。

### Stage 3：编码动作的风险排序

只对 Write/Edit/ApplyPatch/Bash 生成风险排序、证据补齐建议和人审提示；任何实际
调用仍走现有 permission → PreToolUse → ToolExecutionPolicy → project_rule_gate
→ dispatch → post/re-observation 链。不得把 Jev recommendation 接到
`execution_boundary` 充当授权。

每个阶段的 L2 证据至少包括：

- 非法 action、错误 state revision、错误概率和缺失选项均 fail closed；
- 概率质量 + unresolved mass 在剪枝、合并、预算耗尽和服务失败时守恒；
- Jev advisor 无法绕过 permission、required-first、sandbox、project rule 或
  TinyKG/CAS；
- journal 篡改和 replay 能检测 Jev 事件不一致；
- second Jev query 在 shared budget 不足时于网络边界前被阻止；
- shadow 与 baseline 的工具轨迹一致，advisory/enforced 每一步都有 paired
  `actual-vs-selected` 证据；
- 仅在完整冻结 cohort、相同任务/model/grader/预算和显式付费授权下运行真实 Jev。

JevTree README 中的 Game24/MiniGrid 对比属于其仓库作者报告，不能当作 metacodes
SLA 或 coding benchmark 预测；接入是否提升 harness，必须以本项目的冻结 paired
evaluation 和现有 non-regression gates 为准。
