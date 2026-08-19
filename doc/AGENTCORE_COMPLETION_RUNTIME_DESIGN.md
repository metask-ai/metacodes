# AgentCore Completion Runtime 设计方案

状态：库内实现已落地；最小文本 Completion 已由 ABI v1 Revision 9 公开

本文只定义 AgentCore 可提供的通用模型调用能力，不定义标题、摘要、会话或任何具体产品业务。

## 1. 背景与目标

当前 AgentCore 已经通过 `api.Provider` 把 Anthropic、OpenAI、Gemini 等后端抽象为中立模型接口。AgentLoop 不直接依赖具体 Client，而是通过 Provider vtable 发起流式请求，并在调用点处理重试、continuation、abort、usage 和诊断观测。

消费方可能需要一次独立的模型生成能力，例如标题、摘要、分类或上下文摘要。这类能力不应进入 AgentLoop，但可以复用 AgentCore 已有的 Provider、模型配置、鉴权、取消、错误和 usage 基础设施。

本提案最初用于先在库内定义并落地通用 `CompletionRuntime`。后续经过真实消费需求与 AgentCore 边界审计，Revision 9 只公开其中已被现有 Provider 可靠支撑的无工具文本 complete/stream 子集；本文件中的库内扩展形状不自动构成公共 ABI 承诺。

## 2. 架构边界

```text
AgentCore
├── AgentRuntime
│   └── run()
│       └── api.Provider
│
└── CompletionRuntime
    └── api.Provider
```

`AgentRuntime` 和 `CompletionRuntime` 是建立在同一个 Provider 能力之上的两个平级使用面。当前不把 AgentLoop 改道到 CompletionRuntime；已有的 `provider.sendStreamRetry(...)` 调用保持不变。

消费方可以直接使用库内的 CompletionRuntime，但消费方如何触发、解析、持久化或展示结果不属于 AgentCore。

## 3. AgentCore 负责的内容

- 通用请求和响应数据契约；
- 非流式、流式模型调用；
- Provider 适配和模型选择；
- 请求取消、资源生命周期和并发安全契约；
- 标准化错误和 usage；
- 真实能力的 capability 查询；
- 现有 Provider 的复用，而不是第二套 HTTP Client。

## 4. AgentCore 不负责的内容

以下内容由消费方决定：

- 标题、摘要、分类等业务语义；
- Prompt 内容和调用时机；
- 异步、重试和失败回退；
- 结果清洗、持久化和 UI 事件；
- 会话元数据；
- 消费方自己的 token/cost 展示。

因此 AgentCore 不提供 `generate_title()`、`generate_summary()` 等产品语义接口。

## 5. 命名决策

推荐名称：

```text
类型：CompletionRuntime
函数前缀：completion_
请求类型：CompletionRequest
未来 ABI 结果类型：CompletionResult
```

不采用 `AuxiliaryRuntime`：同一能力也可能被 AgentRuntime 使用，对 AgentRuntime 并非 auxiliary。

不采用 `InferenceGateway`：`Gateway` 偏基础设施实现，语义过宽。

不采用 `ModelRuntime`：容易和完整的 AgentCore Runtime 混淆。

`Completion` 表示一次由消息输入驱动的模型生成，不携带消费方业务语义。

## 6. 库内契约的最小形状

第一版只定义无工具的一次性模型生成。这样不会把 AgentLoop 的 tool-use 应答路径重造一遍。

```zig
pub const CompletionRequest = struct {
    messages: []const ApiMessage,
    system: ?[]const u8 = null,
    model_override: ?[]const u8 = null,
    abort: ?*const AbortSignal = null,
    user_query: []const u8 = "",
};

// 当前库内实现直接复用现有 api_stream.ApiResponse。
    // Revision 9 公共投影定义独立的 CompletionResult(text/usage/stop_reason)。
```

当前库内实现使用现有 `AbortSignal` 借用指针完成取消适配；这是库内形状。Revision 9
不暴露该内部指针或 `user_query`，而由 opaque stream handle 的 `completion_stream_abort`
打断阻塞中的 `next`。公共 `complete()` 内部消费同一 stream 路径，但不宣称可取消。

库内 `complete()` 返回现有 `ApiResponse`，其 `content` 所有权和释放方式沿用 Provider
已有契约。Revision 9 公共投影将结果收敛为 library-owned `CompletionResult.text`，
并使用公共 `buffer_release` 配对释放。

库内入口：

```text
complete(request) → 完整结果
stream(request)   → 流式事件句柄
```

### stream 事件面与观测

库内第一版 `stream()` 直接复用中立层 `api_stream.StreamEvent`，不另造裁剪版事件集。事件集合固定为：

```text
text
thinking
tool_use_start
web_search_result
web_search_query
usage
done
```

这并不把客户端 tool-use 应答路径加入 CompletionRequest；它只是保留 Provider 已有的中立事件面和 server-tool 观测，避免迁移内部消费者时丢失行为。每个 owned event 变体仍由调用方按 `api_stream.StreamEvent.deinit()` 释放；`usage` 和 `done` 不拥有资源。

除 `next()` 和 `deinit()` 外，stream handle 必须暴露：

```text
requestId()
stopReason()
```

`requestId()` 用于日志、诊断和调用身份串联；`stopReason()` 保留 Provider 的停止原因。Provider 的 `model()`、`maxTokens()`、`supports()` 等能力查询通过 CompletionRuntime 的只读 provider identity/capability 入口暴露，不能让消费者重新依赖具体 Client。

概念入口为：

```text
providerInfo().model()
providerInfo().maxTokens()
providerInfo().supports(capability)
```

`structured()` 暂不进入已承诺的最小契约。等至少一个 Provider 具备真实端到端结构化输出、schema 校验、错误和所有权语义后，再作为独立 capability 加入。

### 契约约束

- `tools` 和 `tool_choice` 不属于第一版 CompletionRequest；
- 当前库内接口使用借用的 `AbortSignal*`；Revision 9 ABI 不传递内部指针，也不引入 `cancel_token`，而通过 opaque stream handle 取消；
- 当前库内沿用 `ApiResponse.content` 的 Provider 所有权契约；Revision 9 ABI 的 `CompletionResult.text` 采用 library-owned + 配对释放；
- `stream()` 返回的 handle 由调用方创建并负责一次性 `deinit`；同一 handle 只允许一个读取者，不允许跨线程并发 `next()`；
- abort 后，未消费完的 stream 的 `next()` 返回明确的 `Aborted`，随后仍由调用方负责 `deinit`；
- AgentRuntime 的 run 结束不会隐式销毁消费方持有的 handle；
- 重复 `deinit` 不属于合法用法，ABI 层必须在 opaque handle 层提供可诊断的无效句柄错误；
- 不支持的能力必须返回明确错误，不得静默降级。

## 7. 与现有 Provider 的关系

现有 `api.Provider` 已提供：

```text
send()
sendWithModel()
sendStream()
sendStreamRetry()
```

`CompletionRuntime` 应是 Provider 之上的薄库内封装：

```text
CompletionRuntime ──┐
                    └── api.Provider ── Client / OpenAIClient / GeminiClient

AgentRuntime ───────┘
```

不要为了 CompletionRuntime 新建 HTTP Client，也不要改动 AgentLoop 热路径 `provider.sendStreamRetry(...)`。现有建连重试、continuation、abort、usage 和诊断观测保持原样。

真实内部消费者优先用于磨合接口：

- `core/compact_summary.zig` 的一次性 `provider.sendWithModel`；
- `core/compact_summary.zig` 的流式调用；
- `core/rule_author.zig` 的一次性模型调用；其流式身份校验依赖 `requestId()`、`model()` 和 `maxTokens()`，只有 CompletionRuntime 能无损提供这些观测时才迁移，否则继续留在 Provider。

`compact_summary` 是第一迁移验证点：它依赖完整 `StreamEvent` 事件面和 usage 增量，迁移必须逐变体保持释放与累计行为不变。`rule_author` 暂列为条件性候选，不把它的迁移作为当前方案的硬验收项。

## 8. ABI 影响与 revision 门槛

上述门槛已由 Revision 9 的范围审计和验收矩阵满足，因此公共 ABI 执行：

```text
ABI v1 Revision 8 → Revision 9
```

Revision 9 只公开 user/assistant 文本消息、可选 system、文本结果、typed stream event、usage、stop reason 和并发 abort。它不公开库内 `model_override`、`user_query`、tool/server-tool、structured output 或通用 capability 查询；遇到 tool/server-tool 响应返回明确的不支持状态。Revision 9 是 exact hard cut，不提供 Revision 8 的隐式兼容、双表 shim 或旧表回退。规范以 `AGENTCORE_BINARY_ABI.md` 为准。

## 9. AgentLoop 改造边界

当前事实：

```text
AgentLoop → provider.sendStreamRetry(...)
```

这条 Provider 抽象已经完成了 Client 解耦。本提案不把 AgentLoop 改成：

```text
AgentLoop → CompletionRuntime.stream()
```

除非未来能够单独证明 CompletionRuntime 提供了 Provider 无法提供的能力，并给出针对重试、continuation、abort、usage、诊断和性能的回归证据。

## 10. 验收测试

库内回归继续覆盖 `CompletionRuntime`；Revision 9 额外用公共 ABI 和 source-free consumer 覆盖：

- CompletionRuntime.complete 的非流式请求和结果；
- CompletionRuntime.stream 的打开、读取、结束和释放；
- model override 正确进入请求；
- `abort` 传递与 stream 中断行为；
- 返回文本和 usage 的所有权；
- complete/stream 与现有 Provider 的一致性；
- compact_summary 迁移后逐变体事件、owned 字节释放和 usage 累计行为不变；
- rule_author 仅在 `requestId()`、`model()`、`maxTokens()` 和身份错误语义闭合后迁移并验收；
- AgentLoop 的工具、MCP、重试、abort、usage 和诊断回归不变。

不在 AgentCore 中测试标题、摘要或 WebUI。

## 11. 最终决策

```text
当前：AgentCore ABI v1 Revision 9
  ├── AgentRuntime
  │   └── run() → api.Provider
  └── Completion（独立公共 handle，投影库内 CompletionRuntime）
      ├── complete()（内部消费同一 stream 路径）
      └── stream() / abort()
```

`structured()` 作为待定 capability，不得提前画入已承诺的 ABI 能力表。

公共 R9 只承诺已闭合的最小文本能力；后续能力必须重新证明底层支持并通过独立 revision 评审，不能从库内接口存在推导为公共承诺。
