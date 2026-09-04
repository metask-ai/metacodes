# Agent 底层输出语义分类问题

当前底层流式事件主要区分：

```text
text
thinking
tool_use
usage
done
```

其中 `thinking` 已与普通文本分离，但所有可见文本仍统一表示为 `text` 或 `text_chunk`，没有区分：

- `commentary`：展示给用户的中间处理信息；
- `final`：Agent 完成任务后提交的最终结果；
- `partial/provisional`：中断、错误或尚未完成的临时输出。

## 期望语义

一般 Agent 输出应区分：

- `thinking`：内部推理，默认不展示，也不能进入最终结果；
- `commentary`：面向用户的过程说明，可以展示，但不属于最终答案；
- `final`：任务完成后的正式结果；
- `partial/discarded`：中断、错误或回滚产生的未完成内容。

## 当前问题

普通文本增量到达时，底层通常还不知道它最终属于 commentary 还是 final：

- 后续出现工具调用：此前文本应属于 commentary；
- 自然 `end_turn`：最后一段文本才是 final；
- `max_tokens` 后继续生成：多个响应片段需要合并后才能形成 final；
- abort 或 API error：已经产生的文本只能算 partial 或 provisional。

当前 agent loop 已经掌握工具调用、continuation、终止原因和 Run 完成状态，但没有把这些判断结果建模成正式的输出类型。

同时，`stream_done` 只表示一次 Provider stream 结束，不能代表 final。工具调用、continuation、中断和错误路径都可能产生 `stream_done`。

## 影响

- UI 无法分别展示 thinking、commentary 和 final；
- thinking 可能被当成普通可见文本；
- 工具调用前的中间说明可能被误认为最终答案；
- 中断或错误产生的残片可能被误认为完整结果；
- 每个上层消费者都必须重复实现“什么算 final”的状态机；
- 不同消费者可能得到不同的最终结果。

## 典型场景

### 工具调用前存在文本

```text
text → tool_use → tool_result → text → end_turn
```

第一段文本是执行过程中的可见信息，最后一段文本才是任务结束时的结果。当前底层事件没有直接表达二者的差异。

### max tokens 后继续生成

```text
text → max_tokens → text → end_turn
```

两次 Provider stream 共同组成一次完整结果，任意单独一次 `stream_done` 都不能代表最终完成。

### 用户中断

```text
text → abort
```

已经产生的文本可能需要展示，但它不是完整结果。当前文本事件本身无法表达这一状态。

### 流错误

```text
text → API error
```

已经产生的文本可能未提交到 Conversation。只观察文本和 `stream_done` 的上层无法直接判断该内容是否有效。

## 需要维护人员确认的语义

- 底层是否应明确区分 thinking、过程信息和最终结果；
- 普通 text 在什么时点、依据什么事实被认定为 commentary 或 final；
- max-token continuation 的多个文本片段对外应如何表示为一个完整结果；
- abort、API error、预算终止和最大轮数终止时，已产生文本分别是什么状态；
- 上层是否应该自行根据工具事件和终止原因重建最终结果；
- `stream_done` 的准确含义是否仅为一次 Provider stream 结束。

本文只记录当前类型表达能力与消费需求之间的缺口，不预设具体修改方式。
