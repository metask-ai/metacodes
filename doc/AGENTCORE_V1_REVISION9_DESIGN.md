# AgentCore ABI v1 Revision 9 设计方案

> 状态：R9 已实施；native delivery gate 已通过
> 日期：2026-08-19
> 前置：`AGENTCORE_BINARY_ABI.md`、`AGENTCORE_COMPLETION_RUNTIME_DESIGN.md`、Revision 8 基线实现
> 目标：① Skill Catalog 显式查询范围；② 独立文本 Completion 公共接口

## 0. 决策摘要

Revision 9 的范围只包含两项能力；详细 ABI 契约和 wire 按本文实施，并作为一次范围受控的 hard cut 交付：

1. Skill Catalog 查询必须显式选择 `personal_only` 或 `workspace_effective`；
2. 将已经在库内使用的 `CompletionRuntime` 投影为独立、无工具、文本型公共 ABI。

Revision 9 不包含 Host Tool 修改，也不为消费方提出的未来能力预建 Provider Registry、格式 adapter、多模态、异步工具调度或完整 RunOptions。

本方案的默认工程边界是：

```text
修改：AgentCore facade / public wire / SDK / conformance tests / 文档
复用：现有 Skill catalog engine / CompletionRuntime / OwnedProvider
不改：Core / AgentLoop / Provider 实现 / checkpoint schema / catalog descriptor schema
```

代码、Header 与 SDK 已原子切换到 ABI Revision 9；交付前仍必须让 wire、实现、SDK、artifact consumer 和门禁保持同一提交可构建，不发布或合入半成品 R9。

### 0.1 当前确认层级

本文记录 Revision 9 的能力范围、架构边界和详细 ABI 语义。结构体字段顺序、size/alignment/offset 已由 Type-First layout 断言和跨语言 gate 固定：

| 层级 | 当前状态 |
|---|---|
| R9 能力范围 | 已确认：Catalog 显式查询范围 + Completion 公共接口 |
| 架构边界 | 已确认：默认不改 Core、AgentLoop、Provider 实现和持久化 schema |
| 排除项 | 已确认：Host Tool、Provider Registry、格式 adapter、多模态和完整 RunOptions 不进入 R9 |
| 详细 ABI 契约 | 已确认：wire、借用期、并发、错误、所有权和 provider observation 按本节决策实施 |
| 实现与测试 | 已实施；Catalog/Completion L2、三 Provider MockServer 和 native delivery gate 已通过 |

详细契约采用以下决策：

- `completion_stream_start` 只在调用期间借用请求数据；成功返回前必须完成序列化和请求体发送；
- `completion_stream_abort` 可以从另一线程并发打断阻塞中的 `next`；destroy 不得与 `next` 或 abort 并发；
- 首版不提供请求级 `model_override`；切换模型通过创建另一个 Completion handle 表达；
- `completion_describe` 只公开 provider kind 和 handle 配置模型，不公开当前无法跨 Provider 诚实保证的 token 上限或 capability；
- 公共 `completion_complete` 在 AgentCore 内部消费同一 stream 路径并聚合结果，不要求 OpenAI/Gemini 新增非流式 Provider 实现。

## 1. 需求判断与范围控制

消费方需求是设计输入，不直接等于 AgentCore 的架构结论。Revision 9 只接纳能够复用现有底层能力、职责明确且可端到端验收的部分。

| 消费方提议 | Revision 9 决策 | 判断依据 |
|---|---|---|
| 显式 `personal_only` / `workspace_effective` | 纳入 | 当前隐式路径不足以表达调用意图；现有 catalog 已支持传入来源集合 |
| Completion 公共接口 | 纳入 | 库内 `CompletionRuntime` 和 `OwnedProvider` 已存在并有真实内部使用 |
| Host Tool V2 | 不纳入 | 当前同步 Host Tool 可用，尚无已确认的 correctness 缺陷或必须场景 |
| `.claude` / `.codex` adapter | 不纳入 | 尚未证明存在必须由 AgentCore 承担的格式差异和稳定契约 |
| Provider Registry / custom / remote provider | 不纳入 | 会引入新的发现、信任、失效和生命周期模型，当前没有必要 |
| complete/incomplete catalog observation | 不纳入 | 当前 R9 只查询同步本地 `.agents/skills`，没有暂态远程 Provider |
| provenance / shadowed projection / typed issue 扩展 | 不纳入 | 现有 descriptor 足以承载当前来源；不为未来 Skill 中心预建模型 |
| 多模态、structured output、tool calling | 不纳入 | 现有 Completion 最小闭环是无工具文本生成 |
| 非流式强制取消、通用 deadline | 不纳入 | 当前 Provider 非流式 vtable 没有取消槽，不能伪造能力 |

Revision 大小不是目标。只要两项能力各自形成完整的公共契约、实现、SDK 和测试闭环，Revision 9 即具备独立发布价值。

## 2. 架构位置

### 2.1 Catalog

```text
SkillCatalogQueryV1.scope_code
        ↓
AgentCore source policy
        ↓
RuntimeCatalogs.query(sources)
        ↓
现有 canonical catalog.build()
```

AgentCore 只负责把公开查询范围转换成已有 `catalog.Source` 集合。合法 Candidate、优先级、winner、conflict、invalid candidate、no-fallback 和 immutable snapshot 仍由现有 canonical catalog engine 唯一决定。

### 2.2 Completion

```text
AgentCore
├── AgentRuntime / Session
│     └── AgentLoop
└── CompletionHandle
      ├── owned provider configuration
      ├── OwnedProvider
      └── CompletionRuntime
```

Completion 与 Agent Runtime 平级，不从 Session 派生，不读取或修改 Conversation，不经过 AgentLoop，也不共享 Session 的 Provider client。

## 3. Skill Catalog 显式查询范围

### 3.1 公共 wire

Revision 9 将 `SkillCatalogQueryV1.reserved0` 改为显式的 `scope_code`，并保持结构体大小不变：

```zig
pub const SkillCatalogQueryScopeV1 = enum(u32) {
    personal_only = 1,
    workspace_effective = 2,
};

pub const SkillCatalogQueryV1 = extern struct {
    struct_size: u32,
    scope_code: u32,
    workspace_root: BytesViewV1,
    workspace_home: BytesViewV1,
    workspace_epoch: BytesViewV1,
    reserved: [3]u64,
};
```

`scope_code = 0` 和未知值必须返回 `STATUS_INVALID_ARGUMENT`。Revision 9 不允许通过路径相等、空字段或默认值推断查询范围。

### 3.2 `personal_only`

来源集合固定为：

```text
workspace_home/.agents/skills
scope    = personal
priority = 1
```

约束：

- `workspace_root` 必填；`workspace_home` 为空时继续沿用现有契约，回退到 canonical `workspace_root`；
- 只选择用户级来源，不读取项目级目录；
- Catalog handle 仍绑定该 workspace identity，可用于对应 Session 的 Skill 选择；
- 不把 Personal 查询解释为“全局、跨 workspace 的可执行授权”。

### 3.3 `workspace_effective`

来源集合固定为：

```text
workspace_home/.agents/skills  scope=personal priority=1
workspace_root/.agents/skills scope=project  priority=2
```

项目级来源优先于用户级来源。相同 invocation name 的 winner、shadowing、conflict 和 invalid candidate 规则全部复用现有 canonical resolver。

当 canonical `workspace_root == workspace_home` 时，只扫描一次物理目录，避免相同文件作为两个 Candidate 产生伪冲突。去重不改变 `scope_code` 的显式要求。

### 3.4 保持不变的语义

- Catalog snapshot 继续不可变；
- Host handle 与 Session retain 的引用生命周期不变；
- Session 更新继续原子替换 Skill binding；
- MetaWork 禁用 winner 后，执行阶段继续不得回退到 loser；
- Catalog revision 继续由现有 canonical 内容计算产生；
- Catalog descriptor 格式和版本不升级；
- `scope_id` 继续绑定 canonical root/home，不因查询范围新增另一套 Session identity。

## 4. Completion 公共接口

### 4.1 能力边界

Revision 9 Completion 是“消息到文本”的无工具模型调用：

```text
输入：user/assistant 文本消息 + 可选 system
输出：文本、stop reason；流式路径额外提供 thinking 和 usage 事件
```

它不提供产品语义接口，例如 `generate_title`、`generate_summary` 或 `classify`。Prompt 内容、触发时机、结果清洗、持久化和 UI 均由消费方负责。

### 4.2 Completion 配置与所有权

建议公共配置：

```zig
pub const CompletionConfigV1 = extern struct {
    struct_size: u32,
    provider_kind_code: u32,
    api_key: BytesViewV1,
    base_url: BytesViewV1,
    model: BytesViewV1,
    reserved: [4]u64,
};
```

`completion_create` 必须复制并持有 `api_key`、`base_url` 和 `model`。原因是当前具体 Provider client 在生命周期内保存这些 slice，不能借用只在 create 调用期间有效的 Host 内存。

`completion_destroy` 释放 Provider、独立 IO runtime 和所有配置副本，并清理持有的凭据。Completion handle 不依赖 Agent Runtime handle。

### 4.3 文本消息和请求

Revision 9 只接受两种 message role：

```text
user      = 1
assistant = 2
```

System prompt 使用请求的独立 `system` 字段，不增加第三种 message role。

Revision 9 wire：

```zig
pub const CompletionMessageV1 = extern struct {
    struct_size: u32,
    role_code: u32,
    text: BytesViewV1,
    reserved: [2]u64,
};

pub const CompletionRequestV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    messages: ?[*]const CompletionMessageV1,
    message_count: u64,
    system: BytesViewV1,
    reserved: [4]u64,
};

pub const CompletionResultV1 = extern struct {
    struct_size: u32,
    stop_reason_code: u32,
    text: OwnedBytesV1,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
    reserved: [2]u64,
};

pub const CompletionInfoV1 = extern struct {
    struct_size: u32,
    provider_kind_code: u32,
    model: OwnedBytesV1,
    reserved: [3]u64,
};
```

请求数据只在同步 API 调用期间借用。`completion_stream_start` 成功返回前必须完成消息序列化和 HTTP 请求体发送，不得让 Provider stream 保留 Host 的 messages/system 引用。AgentCore 至少必须验证：

- message 数量和总字节上限；
- role code；
- UTF-8；
- 指针、count 和空值组合；
- reserved 字段为零。

Revision 9 不包含 `tools`、`tool_choice`、图片、文件、MIME、response schema、reasoning effort、retry 参数或完整 RunOptions。

### 4.4 非流式调用

公共入口：

```text
completion_complete(handle, request, out_result, out_diagnostic)
```

公共 `complete` 不调用 Provider 非流式 vtable，而是在 AgentCore 内部打开同一流式请求、读取至 terminal observation 并聚合结果。这样三个 Provider 共享一条已存在的实现路径，也不会为了公共 ABI 修改底层 Provider。

结果包含：

```text
text        library-owned UTF-8
stop_reason typed code
usage       checked-add 后的四项 token 计数
```

文本使用现有 `buffer_release` 释放。聚合文本受 `MAX_COMPLETION_RESULT_BYTES_V1` 限制；usage 只累计实际收到的流式 usage observation。

非流式调用不支持中途取消。接口不得接受后静默忽略取消参数。

如果 Provider 在无工具请求中返回 client tool call，AgentCore 返回明确的不支持响应错误，不把工具参数拼入文本。

### 4.5 流式调用

公共入口：

```text
completion_stream_start
completion_stream_next
completion_stream_abort
completion_stream_destroy
```

流式事件只投影：

```text
text
thinking
usage
done
```

事件 wire：

```zig
pub const CompletionEventV1 = extern struct {
    struct_size: u32,
    kind_code: u32,
    payload: OwnedBytesV1,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
    stop_reason_code: u32,
    reserved0: u32,
    reserved: [2]u64,
};
```

约束：

- stream handle 由 AgentCore 创建，Host 必须显式 destroy；
- `next` 是单读取者、阻塞式 pull，不允许两个线程并发读取同一 stream；
- text/thinking payload 为 library-owned，使用 `buffer_release` 释放；
- usage 使用 checked integer fields，不编码为可解析 JSON；
- abort 是协作式取消，复用 Provider 的 `AbortSignal` 和 transport shutdown；
- abort 可以与阻塞中的 `next` 从另一线程并发调用，并使 `next` 以一次 typed aborted `done` observation 返回；
- 两个线程不得并发调用同一 stream 的 `next`；destroy 不得与 `next` 或 abort 并发，Host 必须先等待这些调用返回；
- abort 后 stream 以 typed aborted terminal observation 结束，随后仍须 destroy；
- stream start 成功后，Completion handle 在 stream 销毁前保持 busy；
- Completion destroy 在活动 complete/stream 存在时返回 `STATUS_BUSY`；
- 同一个 Completion handle 同时只允许一个活动调用，需要并发时创建多个 handle。

Revision 9 不暴露 client tool、server tool 或 Web Search 事件。遇到这些事件时必须明确终止为 unsupported response，不得静默丢弃后继续把结果标记为完整。

Completion stop reason 固定区分 `unknown`、`end_turn`、`max_tokens`、`stop_sequence`、`pause_turn`、`refusal` 和 `aborted`；它不复用 Agent Run 的 `StopReason` enum。非预期 client/server tool response 使用独立的 completion unsupported-response status，不伪装为正常 stop reason。

### 4.6 Provider 信息

`completion_describe` 只返回：

```text
provider kind
handle 配置模型
```

返回的 model 是 library-owned 副本，使用现有 `buffer_release` 释放。Revision 9 不提供请求级 model override，因此 describe 与实际请求模型不存在歧义。

Revision 9 不公开 token 上限或现有内部 `Capability` enum。当前 OpenAI/Gemini 的部分 token limit 仍是保守配置值而非稳定模型事实；`web_search`、`structured_output`、`server_tool` 等能力也不属于本次公共 Completion 契约，不能仅因内部有查询函数就对外承诺。

## 5. ABI、schema 与兼容性

### 5.1 公共 ABI

本次已执行：

```text
ABI v1 Revision 8 → Revision 9
```

Revision 9 是 exact hard cut：

- API table 增加 Completion 函数；
- `SkillCatalogQueryV1.reserved0` 变为 `scope_code`；
- 增加 Catalog query scope 和 Completion 相关 public types；
- capability bits 增加显式 Catalog scope 与 text Completion；
- 不保留 Revision 8 table shim、旧字段默认行为或双 revision dispatch。

### 5.2 持久化格式不升级

以下值保持不变：

- Session checkpoint `STATE_SCHEMA_REVISION`；
- Session permission checkpoint revision；
- MCP checkpoint schema；
- Skill catalog descriptor schema；
- Skill catalog revision算法。

Revision 8 基线的 `session_checkpoint.zig` 曾有一个值为 `8` 的 `AGENTCORE_ABI_REVISION`，并将其写入 checkpoint envelope。Revision 9 没有机械地把该值改为 `9`，否则会在 Session 持久化内容没有变化的情况下人为制造 checkpoint 不兼容。

该内部常量已澄清为 `CHECKPOINT_COMPATIBILITY_MARKER`，编码值继续为 `8`，并由回归测试固定：

```text
Revision 9 能恢复现有 Revision 8 checkpoint fixture
Revision 9 导出的 checkpoint 继续使用当前 schema 和 compatibility marker
```

这是内部命名澄清，不是 schema migration。

## 6. 文件级实施范围

### 6.1 实际修改

| 文件 | 修改内容 |
|---|---|
| `sdk/zig/types.zig` | R9 public enums、structs、函数签名、API table 和 layout tests |
| `src/agentcore/abi_v1.zig` | Catalog scope 验证与 Completion ABI 薄转发 |
| `src/agentcore/skill_catalog_handles.zig` | 按显式 scope 构造 `.agents/skills` 来源集合 |
| `src/agentcore/session_checkpoint.zig` | 仅澄清 compatibility marker 命名；编码值不变 |
| `src/agentcore/completion_handles.zig` | 新增独立 Completion/stream handle、状态和所有权实现 |
| `sdk/metask/agentcore.h` | 同步 R9 C ABI |
| `sdk/zig/root.zig` | Zig SDK 包装与 exact R9 table 校验 |
| `sdk/rust/src/raw.rs` | Rust raw layout |
| `sdk/rust/src/lib.rs` | 最小安全包装和 revision 检查 |
| `tests/component/agentcore_abi_test.zig` | Catalog 与 Completion L2 测试 |
| `tests/agentcore_artifact_consumer/**` | source-free C/C++/Zig/Rust consumer 验证 |
| `doc/AGENTCORE_BINARY_ABI.md` | R9 normative ownership、线程、错误和迁移语义 |
| `doc/AGENTCORE_COMPLETION_RUNTIME_DESIGN.md` | 状态更新为公共 ABI 已由 R9 接管 |

### 6.2 禁止修改

除非后续审计发现无法绕过且另行批准，本次不得修改：

```text
src/core/**
src/core/agent_loop.zig
src/core/agent_session.zig
src/api/provider.zig
src/api/provider_factory.zig
src/api/completion.zig
具体 Anthropic/OpenAI/Gemini client
Host Tool ABI
```

如果实施中发现必须修改上述边界，停止扩张 R9，重新审查；不得以“接线需要”为由静默扩大范围。

## 7. 验收测试

下列公共语义必须由可执行断言覆盖；最终结果随交付门禁记录更新。

### 7.1 Catalog

- `personal_only` 只返回用户目录 Skill；
- `workspace_effective` 合并用户和项目目录；
- 同名 Skill 由项目来源获胜；
- `workspace_root == workspace_home` 时只扫描一次且不产生伪冲突；
- 相同路径下，范围仍由 `scope_code` 而不是路径关系决定；
- `scope_code = 0` 和未知值返回 invalid argument；
- Catalog handle 可以正常绑定匹配 workspace 的 Session；
- 禁用 winner 后不执行 loser 的既有回归继续通过；
- Catalog descriptor 和 revision 保持确定性。

### 7.2 Completion

- Anthropic、OpenAI、Gemini 配置均能创建正确 Provider；
- create 返回后释放 Host 输入，Completion 仍能使用，证明配置已复制；
- messages 和 system 真实进入 MockServer 请求；
- `stream_start` 返回后立即毒化/释放 Host 请求缓冲，stream 仍完整读至 done，MockServer 请求体保持完整；
- complete 经内部 stream 聚合返回文本、usage 和 stop reason，owned text 可释放；
- stream 正确投影 text、thinking、usage、done；
- 另一线程的 abort 能中断阻塞中的 next，并产生一次 aborted done；
- 非流式 complete 不宣称取消；
- 同 handle 重叠调用返回 busy；
- 活动 stream 阻止 Completion destroy；
- 非法 role、UTF-8、指针/count、reserved 和资源上限全部拒绝；
- 非预期 tool/server-tool 事件不会被静默解释为完整文本结果；
- 所有成功和失败路径无内存泄漏、无凭据悬挂引用。

### 7.3 ABI 与交付

- Zig/C/C++/Rust 的 struct size、alignment、offset 和函数表一致；
- R9 revision、table size 和 capability bits 精确匹配；
- Revision 8 table 不被 R9 SDK 接受；
- source-free artifact consumer 跑通两种 Catalog 查询和一次 Completion；
- Revision 8 checkpoint fixture 在 R9 下恢复成功；
- `zig build agentcore:test` 通过；
- `zig build agentcore:gate` 通过；
- archive/manifest/symbol gates 通过。

## 8. 实施顺序

1. 确认本文的 R9 能力范围、详细 ABI 契约、架构边界和排除项，不先修改代码 revision；
2. 按 Type-First 原则修改 `sdk/zig/types.zig` 的 R9 wire 和 layout 断言；
3. 实现 Catalog scope 映射和定向测试；
4. 实现独立 Completion handle、stream handle 和资源生命周期；
5. 补 MockServer L2 测试，证明三个 Provider 的实际请求接线；
6. 同步 C Header、Zig SDK、Rust raw/safe SDK 和 artifact consumer；
7. 增加 checkpoint compatibility 回归，不升级持久化 schema；
8. 更新 normative ABI 文档和 Completion 旧设计文档状态；
9. 全部门禁通过后，在同一交付中把公共 ABI revision 从 8 切到 9；
10. 记录最终测试证据和未实现项，结束 Revision 9。

## 9. 实施与验证记录

R9 实现提交为 `6590e4f`。同分支的 MCP Classic 空 `params` 修复提交为
`9f8f5d9`，它是独立维护项，不增加 R9 capability，也不修改 MCP schema。

2026-08-19 验证结果：

- `zig build agentcore:test`：通过；
- `zig build agentcore:bundle -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSmall`：通过；
- `zig build agentcore:consumer -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSmall`：C/Zig source-free consumer 通过；
- `zig build agentcore:rust -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSmall`：Rust link probe 通过；
- `zig build agentcore:gate -Dtarget=x86_64-windows-msvc`：C/C++/Zig/Rust native delivery gate 通过；
- `zig build agentcore:archive -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSmall`：manifest、package self-test、archive 与 SHA-256 产物通过。

两项不应被误报为 R9 实现失败的环境/基线事实：

- `agentcore:rust-bindgen-check` 在当前机器缺少 `libclang.dll`，因此无法执行精确再生成 diff；checked-in Rust raw declarations 已通过 Rust 编译、link probe 和跨语言 layout 断言，但仍应在具备 libclang 的发布环境补跑该独立 gate；
- 完整 ReleaseSmall `agentcore:gate` 会在既有 `Skill materialization is post-admission and pre-Conversation` 单测中以 code 5 崩溃。对照提交 `9f8f5d9` 在同配置同样稳定复现，ReleaseSafe 和 Debug 通过，因此这不是 R9 回归，也不在本次越界修改 Skill/Core。

## 10. Definition of Done

Revision 9 只有同时满足以下条件才算完成：

- 两种 Catalog query scope 均由显式 enum 决定，零值不再隐式工作；
- Catalog 查询和 Session Skill binding 的现有 canonical 语义没有分叉；
- Completion 是独立 handle，不借用 Session/Runtime 的 Provider 生命周期；
- complete、stream、abort、destroy 的所有权和并发状态均有可执行测试；
- 没有修改 Core、AgentLoop、Provider 实现或 Host Tool；
- 没有升级 checkpoint/catalog/MCP schema；
- 公共 Header、Zig SDK、Rust SDK、artifact 和 normative 文档原子一致；
- `agentcore:test` 与 `agentcore:gate` 全部通过。

如果其中任何一项只能通过扩大到 Provider Registry、多模态、异步 Host Tool 或 Core 调度修改来完成，应缩减或暂停 Revision 9，而不是继续扩张范围。
