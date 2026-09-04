# Core 答复:输出语义分类 + 文件修改结果可观测

两份需求的实现答复。

- 需求 A：`AGENT_OUTPUT_SEMANTICS_ISSUE.md`
- 需求 B：`CORE_FILE_CHANGE_OBSERVABILITY_REQUIREMENT.md`

代码：`src/core/output_semantics.zig`、`src/core/file_change.zig`，
以及它们在 `src/core/agent_loop.zig` / `src/core/tool_exec.zig` 的接线。
L2 验收：`tests/component/output_semantics_test.zig`、`tests/component/file_change_test.zig`。

---

## A. 输出语义分类

### 模型：段(segment)+ 定性(disposition)

一个 **段** = 一次 provider stream 产出的可见 assistant 文本。段在 stream 打开时开始，
恰好关闭一次，关闭时由 agent loop 给出它**已经知道**的定性：

| 定性 | 含义 | 判定依据(loop 已有的事实) |
|------|------|--------------------------|
| `commentary` | 可见的过程信息，不是答案 | 本轮跟着 `tool_use`；或主机判定这是"过早的最终答案"并注入 nudge 要求继续 |
| `final` | Run 的完成结果 | 自然 `end_turn`，且没有任何主机异议 |
| `continued` | 被 token 上限截断，与同 group 的下一段合成一个结果 | `stop_reason=max_tokens` 且进入续写 |
| `partial` | 可见但未完成 | abort / 预算终止 / 覆盖不足二次拒绝等非完成收尾 |
| `discarded` | 从未进入 Conversation，消费者须丢弃已缓冲字节 | 流内失败回滚、context-window 恢复重发 |

`thinking` **不是**段：它已经是独立事件(`CoreEvent.thinking_chunk`)，永不进入结果。

### 事件

```zig
CoreEvent.output_segment_begin: { index, turn, group }
CoreEvent.output_segment_end:   { index, turn, group, disposition, bytes }
```

- `index` 在 Run 内单调；**被丢弃的段也占一个索引**——"回滚过"与"没发生过"必须可区分。
- `group` 是续写组：同 group 的段按 index 顺序拼接成一个逻辑输出。
- 段的开/关严格配对，同一时刻至多一个段打开(由 `output_semantics.Tracker` 保证，
  重复关闭是 no-op)。任何忘记定性的退出路径由 `run()` 顶部的 `defer` 兜底记为
  `partial`——这是"Run 结束了但从没判定这段是答案"的诚实读法。

### 账本

`agent_loop.Options.output_ledger: ?*output_semantics.Ledger`。挂上后 core 直接组装好
结果，调用方 `ledger.finalText()` / `ledger.partialText()` 取用，**不再自己从 Conversation
尾部猜**。`truncated` 说明保留文本是真相的前缀。

**不传给 subagent**：子 agent 的输出是父 Run 的工具结果，不是父 Run 的最终答案。

### 接线证明

`src/repl/headless.zig` 的 fresh run 与 `--resume` 两条路径都已改用账本(自演化的 outcome note
也改吃定性结果，不再拿可能是 commentary 的 conversation 尾条当结论)：旧的
`lastAssistantText`(只看 conversation 最后一条 assistant message)退化为账本缺席时的兜底。
`--json` 结果行新增 `"text_kind"`：`final` / `partial` / `unclassified`(走兜底取到的文本，
core 没把它定性成结果) / `none`(没有可见输出)。**"none" 与非空 text 不可同时出现**，否则
receipt 自相矛盾——eval 校验器强制这一点。

### 需求 A 逐条答复

> 底层是否应明确区分 thinking、过程信息和最终结果

是。thinking 早已分离；过程信息 = `commentary`，最终结果 = `final`。

> 普通 text 在什么时点、依据什么事实被认定为 commentary 或 final

在 loop **拿到判定事实的那一刻**，见上表。不做任何启发式猜测，也不推迟到 Run 结束
统一回填(那会让 UI 在整个 Run 期间都不知道手上的文字算什么)。

> max-token continuation 的多个文本片段对外应如何表示为一个完整结果

同一 `group`。前面的段是 `continued`，收尾的段是 `final`；拼接顺序即 index 顺序。
账本已经拼好。

> abort、API error、预算终止和最大轮数终止时，已产生文本分别是什么状态

- abort / 预算终止：`partial`(文本已提交 Conversation，可展示，不是结果)。
- 流内 API error：`discarded`(残片被整体丢弃，从未提交)。若重试耗尽仍失败，
  该 Run 没有任何 `final` 段。
- 最大轮数终止：最后一段此前已因带工具调用被定为 `commentary`；Run 无 `final`。

> 上层是否应该自行根据工具事件和终止原因重建最终结果

不应该。这正是本次要消除的重复状态机。上层要么消费 `output_segment_end`，
要么直接读账本。

> `stream_done` 的准确含义是否仅为一次 Provider stream 结束

是，仅此而已，语义未变。它不是完成信号，也从来不是——现在有了 `output_segment_end`
之后，也不该再被当成完成信号使用。

---

## B. 文件修改结果可观测

### 为什么现有两条路都不够

- `file_reference.FileReference`：只说"碰了哪些文件"，没有前后态、没有逐文件结果。
- `tools/observation.FileMutationV1`：审计证据——SHA-256 承诺 + 字节数，**故意**不含明文
  路径和内容，且每次 dispatch 只允许一条。

于是消费者去抠 `tool_result.content` 里的 `gitDiff`。那是工具私有渲染字段：`Read` 没有、
各工具形状不同、结果落盘成 artifact 时会被信封替换、工具改结果 JSON 时随时会变。

### 契约

`src/core/file_change.zig`：

```zig
Kind   = { created, modified, deleted, moved }
Status = { applied, no_change, failed, rejected, partial }

Record = {
    locator,            // workspace_path / absolute_path / uri(与 FileReference 同一归一化策略)
    from_locator,       // moved 的原路径
    kind, status,
    tool, tool_use_id,  // 与消费者已在展示的工具卡配对
    agent_depth,        // 0 = 本 Run;>0 = 子执行(Agent/Skill)
    before_bytes, after_bytes,
    unified_diff,       // 本文件的实际改动
    diff_complete,      // false = diff 被截断/缺失但确实改了 → 消费者须显示"不完整"
}
```

产出路径：工具经 `ToolContext.reportFileChange(Draft)` 逐文件发布 →
`tool_exec.executeOne` 安装的每-dispatch `Collector` 立刻拷出工具 arena →
`agent_loop` 在**本轮工具全部执行完后**一次性 **无条件** emit `CoreEvent.file_changes`
(证据不是渲染：headless / subagent / 关工具卡时同样发)，并写入
`Options.file_change_journal`。

**为什么不紧邻 tool_result**：挂起(UiPending)、host fatal、结果组装失败都可能发生在盘已经
真的改过之后。证据必须落在所有分支之前的单一收口点，否则那几条路径上"改了盘但一个字都没说"。
消费者按 `id` 与 tool_result 配对，不依赖相邻。

`Journal` 带锁，且**经 SpawnOptions 传给子执行**——子 agent 的修改仍是本 Run 的修改，
落同一账本，靠 `agent_depth` 区分层级。

### 覆盖

| 需求项 | 实现 |
|--------|------|
| Write / Edit / NotebookEdit / ApplyPatch | 四者均已发布 |
| 新增 / 修改 / 删除 / 移动 | `Kind` 四值;删除与移动由 ApplyPatch 产出 |
| 单次多文件修改 | ApplyPatch 逐文件一条 Record;单次上限 64，超出置 `overflow` |
| 子执行(Agent/Skill) | Journal 经 SpawnOptions 下传，Record 带 `agent_depth` |
| 无实际变化 | `no_change`(写入内容与原内容逐字节相同) |
| 失败 | `failed`;工具没来得及发布时由 dispatch 缝合成(沉默会被读成"没涉及文件")。若工具已上报真实 mutation 才失败(写完盘、渲染结果时挂)则升级成 `partial` |
| 拒绝 | `rejected`;权限在 dispatch **之前**拒掉的由 agent_loop 补一条。ApplyPatch 的目标藏在不透明信封里，由**工具自己**交代(`publishRejectedTargets`)，不让 host 去解析工具私有格式 |
| 部分完成 | `partial`;ApplyPatch phase 2 非原子——失败点之前 `applied`、失败那个 `partial`、之后 `rejected` |
| 结果不完整 | `diff_complete=false` / 事件的 `overflow`/`lost` / Journal 的 `truncated` |

### 验收

`tests/component/file_change_test.zig` 全部断言只走本契约，从不读工具结果 JSON。
`file_change.writeJsonEnvelope` 是进程外消费者的稳定线格式：`{schema_version, truncated,
changes[]}`——版本由模块自己盖进信封(对齐仓库惯例：只声明不携带的 SCHEMA_VERSION 是装饰不是
契约)。headless `--json` 结果行的 `file_changes` 就是这个信封。

### 顺带修好的既有缺陷

`src/agentcore/event_projection.zig` 的 A1 重建**正是需求 A 描述的那个重复状态机**：它用
`stream_done` 收段。而 `stream_done` 对每个 provider stream 都发一次，**包括被 loop 丢弃后重试
的那一次**——重建出的"最终答案"里既有回滚掉的残片、又有重试的正文(`half-writclean answer`)。
现在它改成消费 `output_segment_end` 的定性，只收 `final`/`continued`；中断产出的 `partial` 也不再
被当成完成的答案。两条回归测试已钉死。

### 明确不在范围内(与需求一致)

预览 / 会话聚合 / UI 展示；评审(评论、批准、接受、拒绝)；`Bash` 或任意终端命令造成的
文件系统变化——本契约只覆盖类型化文件工具，并**明说**这一点，而不假装完整。

---

## 已知取舍

- 兜底关闭(`defer`)发出的 `output_segment_end` 排在 `diag_run_end` 之后。所有显式定性
  路径都在 `finishRun` 之前关闭，兜底只在遗漏时生效。
- `Journal.acquire()/release()` 成对使用：后台 subagent 与父 Run 共享账本，没有无锁访问
  接口，避免把一条可能被 append 重分配的切片交出去。**且 App 的账本用 c_allocator**——mutex
  串行化的是账本自己的调用，串行化不了 allocator，而 App GPA 非线程安全。
- 工具写完盘却在渲染结果时失败(如 gitDiff OOM)：dispatch 缝合处看 `effect_slot` 是否已有真实
  mutation，有则报 `partial` 而非 `failed`——宁可说"可能改了"，不能说"没改"。
- AgentCore 通过既有 `on_event` JSON 观察流导出 `output_segment_begin/end` 与
  `file_changes`。输出段事件完整保留段标识、定性和字节数；文件变更事件直接保留 Core 的
  批次与逐文件证据。它们都是可前向兼容的新观察 tag，不改变 C 布局或 Revision 14。
  ApplyPatch phase-1 校验失败只对**已建好计划**的文件报 `rejected`，触发失败的那个文件
  还没进计划表(整批零落盘，故没有谎报，但目标清单不完整)。
- `--stream-json` 已投影输出段定性(新增 `output_segment_begin/end` 两种 type，按该模块声明的
  前向兼容约定增量加行)，但**未投影 `file_changes`**——那条事件带整段 diff，塞进逐行时间线
  会把流撑爆；要文件修改的消费者走 `--json` 结果行的 `file_changes` 数组或直接消费 CoreEvent。
  TUI 对两组事件都 no-op：它边流边渲染，不需要事后重标。
