# AgentCore V1 Revision 8 RunState 设计方案

## 1. 文档目的

本文定义 AgentCore V1 Revision 8 的 RunState 观察机制。

RunState 是消费方对一次 admitted root run 的实时状态观察副本，用于驱动消费方的状态展示和 reducer。它不是 replay/resume 接口，也不是内部状态查询接口；同步 `RunResultV1` 和 Run 的返回值仍是一次运行的权威终态。

Revision 8 采用完整、可协商的公开能力，不在 Revision 7 中以不可协商的附加事件形式提供。

## 2. Revision 与能力边界

RunState 属于正式公开能力，必须随 ABI Revision 一起冻结：

- `abi_revision = 8`；
- 新增并固定 RunState capability bit；
- C header、Zig/Rust SDK、manifest、bundle 和 consumer fixtures 原子更新；
- Revision 7 consumer 必须拒绝 Revision 8 bundle；
- 不提供 R7/R8 双 dispatch、隐式 shim 或同 revision 下的能力猜测。

Revision 8 继续采用现有的 exact revision、table size、capability、reserved-field 和 function-identity 校验规则。

## 3. 公开事件形状

RunState 使用现有 CoreEvent 的 tagged-object wire convention：

```json
{
  "run_state": {
    "run_id": 123,
    "transition_seq": 42,
    "phase": "executing_tools"
  }
}
```

不得改用 `{"type":"run_state", ...}`。现有 SDK decoder 将对象首 key 作为 union tag，wire shape 必须与现有 `tool_start`、`tool_result` 等事件保持一致。

## 4. 状态范围

RunState 只观察一个 admitted root run：

- 状态按 `session_id + run_id` 隔离；
- fork 子 agent 的内部生命周期不直接外发；
- 不公开 `active_agent`、内部线程、slot、transport 或凭证等实现细节；
- 不提供 replay、resume 或主动查询内部状态；
- 独立的 `session_compact` 不属于 run 生命周期，不伪造 run_state。

公开 phase 枚举为：

```text
starting
generating
executing_tools
waiting_ui
retrying
compacting
finalizing
completed
failed
aborted
poisoned
```

## 5. RunState 数据模型

RunState 恰好包含以下字段；Revision 8 不允许同一 capability 下出现不同字段集合：

- `run_id`：当前 admitted run 标识；
- `transition_seq`：公开事件投递顺序上的单调序号；
- `phase`：上述公开 phase；
- `turn`：与已有 `progress.turn` 同源；
- `tool_calls`：与已有 `progress.tool_calls` 同源；
- `in_flight_tools`：有界工具集合，每项包含拥有副本的 `tool_call_id` 和 `name`；

RunState 不承载 usage。usage 继续由既有 usage 事件提供，避免把高频流式 usage delta 复制成另一条状态流。`turn` 和 `tool_calls` 是 phase/工具集合变化时从既有 progress 的 canonical source 采样的快照字段，不是投影层自行维护的计数器。

`active_tool` 如果保留，只能作为展示提示，不得参与 phase 判定，也不得被解释为唯一执行中的工具。

所有进入长期 RunState 快照的数据必须由投影层拥有。不得保存 `CoreEvent` 中的 borrowed slice。

## 6. Phase 一致性规则

### 6.1 RunState 发送规则

RunState 不是每个 CoreEvent 的镜像。以下情况产生一个新的 `run_state` 事件：

- admitted run 建立时发送一次 `starting`；
- phase 发生变化时发送；
- `in_flight_tools` 集合发生变化时发送；
- canonical `turn` 或 `tool_calls` 发生变化时发送；
- 进入任一终态时发送一次终态快照（若 callback 尚未失败）。

普通文本 chunk、单独的 usage delta 和不会改变上述字段的诊断事件不产生 RunState。快照中的 `turn` 和 `tool_calls` 表示该次状态变更时刻的采样值；实时 usage 以既有 usage 事件为准。

`transition_seq` 是 per-Run 序号，从 1 开始，仅对实际发出的 RunState 事件递增。被 public protocol 过滤的内部事件不消耗该序号。消费方先比较 `run_id`，再在同一 run 内比较 `transition_seq`。

### 6.2 工具并发

工具状态由 in-flight 集合决定：

```text
in_flight_count > 0  => executing_tools 或 waiting_ui
phase == generating => in_flight_count == 0
```

`waiting_ui` 是同步 Host UI 回调占用 active Run 时的观察阶段，因此它可以与尚未闭合的工具集合同时存在；只有 `generating` 要求工具集合为空。

单个 `tool_result` 不能单独触发 `executing_tools -> generating`，因为同一批次可能仍有其他工具运行。`in_flight_tools` 表示公开层尚未闭合的工具尝试，不承诺每个 `tool_start` 都有配对 `tool_result`；HostTool FATAL 或其他终止路径可以使工具尝试无配对结果。

终态迁移不受上述正常路径约束。进入终态时，RunState 关闭本次 run 的工具集合并在终态快照中呈现空的 `in_flight_tools`。`tool_start` 不保证一定有配对的 `tool_result`。

投影层的 in-flight 集合有固定容量（当前实现为 64）。容量耗尽属于观察降级：本次 Run 停止继续发 RunState，但不修改 callback status、不 poison Session，也不影响 canonical CoreEvent、同步 RunResult 或工具执行。下一次 Run 会重新启用投影；因此 RunState 从始至终是 best-effort 观察副本。

### 6.3 UI 等待

进入同步 `on_ui_request` 后进入 `waiting_ui`。UI 响应、拒绝、取消或失败后，依据实际控制流进入下一 phase。

R8 RunState 不公开 UI request ID。一个 Session 同时只有一个 active Run，现有 UI callback 也是同步单槽；消费方需要的是 `waiting_ui` 状态，不是跨请求恢复或异步响应关联。permission/ask_question 的既有 DTO 不因 RunState 增加 request-id 字段。

### 6.4 Retry 与 compact

- `retrying` 在重试请求开始时进入；每一次新的模型尝试都发出内部 `stream_begin` 边界并进入 `generating`，重试失败或重试取消时离开；
- `compacting` 在 auto-compact 实际开始前由内部 `diag_compact_begin` 进入，并由成对的 `diag_compact_end` 在完成、无变化、失败或取消后离开；provider 的 `diag_compact_request` 仅表示已有摘要请求，不承担 compact 生命周期语义；
- `finalizing` 位于清理 run context 之前；
- `session_compact` 没有 `run_id` 时，不生成 run_state。

### 6.5 终态

正常路径为：

```text
finalizing -> completed | failed | aborted
```

`poisoned` 表示 AgentSession 已因 callback 或致命错误进入不可继续状态。

权威 ABI 结果到 phase 的映射如下：

| ABI 结果 | RunState phase | Session 语义 |
|---|---|---|
| `Status.OK + end_turn` / `max_turns` | `completed` | 回到 idle，可复用 |
| `Status.OK + aborted` | `aborted` | 回到 idle，可复用 |
| `Status.OK + tool_error` / `api_error` / `tool_loop` / `checkpoint_budget_exhausted` / `checkpoint_resource_limit` | `failed` | Run 终止，Session 按 ABI 结果决定是否可复用 |
| `OUT_OF_MEMORY` / `CORE_ERROR` / `CALLBACK_FAILED` / `INTERNAL_ERROR`，或 facade lifecycle 已为 poisoned | `poisoned` | 不可继续使用，必须销毁 handle |

当一次路径同时具备普通 Run 失败和 facade poison 条件时，`poisoned` 优先；`failed` 只表示 Status.OK 下的可闭合 Run 终态。

终态事件必须在清理 `active_sink` 和 `active_run_id` 之前具备发送机会。但如果 `on_event` 已经返回非 `CONTINUE`，后续不再保证任何事件，包括终态事件；此时 `RunResultV1` 和同步返回值是权威闭合信号。

## 7. 投影层与事件管线

RunState 投影位于已经具备 Session/Run 上下文的 ABI/Session 边界，不由 `agent_loop` 直接维护：

```text
内部 CoreEvent
    -> Session/ABI 状态投影
    -> transition_seq 分配
    -> public protocol 过滤/编码
    -> on_event callback
```

`agent_loop` 只发出无状态的阶段边界事件，并限制 root run 的公开范围。投影层必须先观察状态所需的内部边界，再执行 public event 过滤；不能先调用 `protocol_v1.event()` 丢弃事件，再尝试重建状态。

## 8. 一致性与来源约束

### 8.1 transition_seq

`transition_seq` 必须在 `callback_mutex` 持有的串行窗口内分配，并与实际 callback 投递顺序一致。并发工具线程不得自行分配公开序号。

### 8.2 turn 与 tool_calls

RunState 不重新维护 turn 或累计 tool call 计数，直接复用已有 `progress` 的 canonical source，避免出现第二真源。

### 8.3 usage

RunState 不累计 usage。消费方通过既有 usage 事件获得 usage；该事件流已包含 event projection 转发的 fork 子 agent usage，R8 不再定义第二套累计口径。

### 8.4 UI callback 错误

UI 请求和普通 event callback 是不同 ABI 通道，但 RunState 的失败语义必须能与 Session 的 `callback_failed`、abort signal 和同步返回值闭合，不能只更新某一条通道的局部状态。

## 9. 不在本次范围内的能力

Revision 8 RunState 不承诺：

- 对话 replay；
- 从状态快照恢复运行；
- 任意时刻主动查询内部状态；
- 公开所有子 agent 身份和内部阶段；
- 通过 run_state 替代 `RunResultV1`；
- 为没有 run_id 的 session-level 操作伪造 run 生命周期。

## 10. 验收矩阵

R8 进入实现验收前，至少覆盖以下路径：

1. Read + Bash 并发执行，先完成者不能提前进入 `generating`；
2. 一个工具 HostTool FATAL、另一个工具仍在执行；
3. 多线程工具完成时 `transition_seq` 与投递顺序一致；
4. starting、waiting_ui、finalizing 阶段 callback 失败；
5. callback 失败后无后续事件，同步返回为 `CALLBACK_FAILED`；
6. UI 请求进入和离开 `waiting_ui` 的迁移正确；
7. 子 agent 事件不会污染 root RunState；
8. 多 Session 并发运行不会串状态；
9. 工具 slot 释放后，RunState 中的 ToolRef 仍有效；
10. Zig/C/Rust SDK 正确解码 `{"run_state": {...}}`；
11. manual `session_compact` 不产生伪造 run_state；
12. 状态事件不泄露凭证、内部指针或未定义 agent identity；
13. source-free bundle consumer 通过 Revision 8 ABI 校验；
14. real-consumer gate 有独立于 library authors 的消费者证据。

## 11. 冻结条件

只有以下条件全部满足，才冻结 Revision 8：

- RunState 字段、phase、错误和终态语义固定；
- 并发工具、UI、retry、compact、finalizing 的边界可观测且可测试；
- 投影、序列分配和数据所有权边界固定；
- ABI、SDK、manifest、bundle 和跨语言 decoder 一致；
- reference-closure audit 通过；
- real-consumer gate 有可核验的独立证据。
