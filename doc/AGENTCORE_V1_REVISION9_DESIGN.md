# AgentCore ABI v1 Revision 9 设计方案

> 状态：R9 尚未正式发布；本次在 revision 9 内原子重切 Skill SDK
> 日期：2026-08-20
> 前置：`AGENTCORE_BINARY_ABI.md`、`AGENTCORE_COMPLETION_RUNTIME_DESIGN.md`、Revision 8 基线实现
> 目标：① 严谨的 Workspace Skill SDK；② 独立文本 Completion 公共接口

## 0. 决策摘要

Revision 9 的 Skill 公共模型按四层闭合：

```text
Source        从哪里获得 Skill
Resolution    当前 Workspace authority 下这个逻辑名称解析到哪个贡献
Authorization Host 授权哪个具体执行身份
Execution     在哪个 immutable catalog world 中执行
```

Catalog 查询表达 Workspace authority，不表达扫描模式。`personal_only` 与
`workspace_effective` 从公共接口移除；`SkillCatalogQueryV1.reserved0` 必须为
零。默认来源为 user/workspace 两个 `.agents/skills`，消费方可显式增加遵循
同一 Agent Skill 格式的本地目录。路径注册不是 `.claude`/`.codex` 格式
adapter，也不会使这些目录成为 AgentCore 的隐式默认来源。

Authorization 采用默认拒绝的 concrete Skill policy。公开 `skill_id` 同时绑定
来源贡献与内容版本；逻辑策略名由 `skill_policy_key` 表达。Session 原子绑定
Catalog + Policy，执行同时校验 catalog revision 和 concrete Skill identity。

Completion 的既定范围和实现保持不变。MCP 只修正 schema admission 边界：
`$schema` 不再决定 Tool 可用性，服务端负责 JSON Schema 语义。Revision 9 不包含
Host Tool 修改、Provider Registry、remote/custom provider、管理型 catalog
observation、格式 adapter、多模态、异步工具调度或完整 RunOptions。

```text
修改：AgentCore Skill facade / public wire / SDK / conformance tests / 文档
复用：现有 canonical catalog engine / immutable snapshot / CompletionRuntime
最小下沉：只给 catalog record 增加来源与内容身份承载字段
不改：Core / AgentLoop / Provider client / checkpoint schema marker / descriptor schema 名称
```

R9 尚无 revision 外正式消费者，因此本次明确作为 R9 原地重切，不升级
`abi_revision`。wire、实现、C/Zig/Rust SDK、artifact consumer、文档和证据必须
作为一个可构建整体同时切换；不存在同 revision 的双契约兼容层。

## 1. 范围判断

消费方需求只作为输入。R9 接受能形成当前纵向闭环的本地多来源能力，不预建
完整插件系统。

| 输入 | R9 决策 | 理由 |
|---|---|---|
| Workspace 可执行 catalog | 纳入 | Session authority 的唯一可执行视图 |
| 显式附加本地目录 | 纳入 | 支持第三方同格式 Skill，无需 Provider Registry |
| 来源身份、内容身份 | 纳入 | 授权、资产映射、冲突和 immutable execution 必需 |
| complete/incomplete | 纳入 | 防止暂时的目录读取失败被解释为空 catalog |
| default-deny concrete policy | 纳入 | 防止同名来源切换导致裸逻辑名授权劫持 |
| winner/source typed projection | 纳入最小集合 | 运行时解释与可靠映射所需 |
| `personal_only` 可执行视图 | 删除 | Personal 不是与 Workspace authority 同维度的执行模式 |
| `.claude`/`.codex` adapter | 不纳入 | 尚无稳定格式差异与真实解析需求 |
| Provider Registry / remote / custom | 不纳入 | 需要新的信任、刷新和生命周期模型 |
| shadowed 全量管理 observation | 不纳入 | 属于后续 Skill 中心管理 API |
| public numeric priority | 不纳入 | 注册顺序不应成为授权或覆盖机制 |

## 2. 架构与职责

### 2.1 Skill 四层

```text
SkillCatalogQueryV1 (Workspace authority + explicit sources)
        ↓
AgentCore source policy
        ↓
canonical resolver (validity / precedence / conflict / no fallback)
        ↓
immutable Catalog handle + typed descriptor
        ↓
default-deny SkillPolicyV1 (concrete skill_id grants)
        ↓
Session binding + pinned execution
```

AgentCore 决定默认来源、Workspace 高于 User、同 scope 同名冲突，以及失败
candidate 不回退 loser。底层 catalog engine 继续唯一负责候选解析、winner、
资源边界和 snapshot；本次只增加必要 metadata seam，不重写 resolver。

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

### 2.3 MCP schema 边界修正

AgentCore 不是通用 JSON Schema validator。Canonical catalog 无损保存原始
`inputSchema`/`outputSchema`；无 `$schema`、显式 2020-12 和显式 Draft-07 是一等
验收场景，其他字符串 dialect 同样不能单独导致 Tool unavailable。Provider
projection 只提取通用 object/properties/required 形状，不把根级 `$schema` 发给
模型。

调用前只检查 arguments 是资源受限的 JSON object，并继续执行 Permission、Skill
restriction 和 canonical MCP Tool identity 校验。required、property type、enum、
reference 等 JSON Schema 语义由 MCP Server 最终验证；服务端拒绝作为 Tool error
返回，而不是误报为 catalog、权限或 transport 失败。本次不新增 dialect adapter，
也不修改具体 Provider client。

## 3. Workspace Skill SDK

### 3.1 Wire

```zig
pub const SkillSourceV1 = extern struct {
    struct_size: u32,
    scope_code: u32, // USER=1, WORKSPACE=2
    root: BytesViewV1,
    source_instance_id: BytesViewV1,
    reserved: [3]u64,
}; // 64 bytes

pub const SkillCatalogQueryV1 = extern struct {
    struct_size: u32,
    reserved0: u32, // must be zero
    workspace_root: BytesViewV1,
    workspace_home: BytesViewV1,
    workspace_epoch: BytesViewV1,
    additional_sources: ?[*]const SkillSourceV1,
    additional_source_count: u64,
    reserved: [1]u64,
}; // 80 bytes

pub const SkillPolicyV1 = extern struct {
    struct_size: u32,
    reserved0: u32, // must be zero
    granted_skill_ids: ?[*]const BytesViewV1,
    granted_skill_id_count: u64,
    reserved: [4]u64,
}; // 56 bytes
```

所有 struct 使用 exact `struct_size`，reserved 必须为零。source 数量最多 64，
`source_instance_id` 为 1..128 字节的 ASCII 字母数字及 `._:-`。重复的 canonical
root 或 source instance id 是 `INVALID_ARGUMENT`。空 grant 集合表示拒绝全部 Skill。

C ABI 函数槽为稳定的 `runtime_query_skill_catalog` 与
`session_update_skills`；安全 SDK 有意命名为
`resolveWorkspaceSkillCatalog` 与 `sessionBindSkillPolicy`，Header 注释和
normative 文档必须声明这组别名。

### 3.2 Source 与 resolution

默认来源：

```text
<workspace_home>/.agents/skills  scope=user      source=agents.user.default
<workspace_root>/.agents/skills  scope=workspace source=agents.workspace.default
```

Workspace 高于 User。canonical home 与 root 相同时只注册 Workspace 来源，避免
同一物理目录自冲突。附加来源只能选择 User 或 Workspace scope；它与同 scope
默认来源处于同一优先级。同 scope 同 invocation name 是 conflict，不按注册顺序
选 winner。R9 的 provider id 固定为 `agents.directory`。

不存在 `.claude/skills`、`.codex/skills` 或 bundled 的隐式扫描。消费方可以把
任意本地目录作为附加来源，但内容必须已经符合 canonical Agent Skill 格式；
AgentCore 不据路径名称切换解析器。

不存在 public numeric priority。invalid/unavailable 高优先级 candidate 仍参与
resolution，不能因为 Host policy 未授权 winner 而回退执行 loser。

### 3.3 身份与 descriptor

`metask.skill-catalog/v1` schema 名称保持不变，但 R9 原地替换其未发布的 Skill
identity 字段形状。每个 winner 包含：

```text
skill_policy_key      逻辑 slot；R9 等于 invocation_name
provider_id           来源 provider 类型
source_scope          user | workspace
source_instance_id    来源实例
contribution_id       provider 内稳定贡献身份
content_revision      body/resources 内容身份
skill_id              provider/source/contribution/content 的 concrete 执行身份
```

`skill_id`、`contribution_id`、`content_revision` 和 `catalog_revision` 为 64 位
小写十六进制摘要字符串。Renderer 不获得物理路径或 opaque provider locator。
issue 至少包含 kind（invalid/unavailable/conflict）、typed code、逻辑 key 与
provider/source provenance；一个候选问题不使其他独立 Skill 失效。

### 3.4 Complete / incomplete observation

成功查询只发布完整 immutable snapshot：`STATUS_OK + handle + descriptor`。
不存在可执行的 incomplete handle。缺失来源目录视为完整的空贡献；无法打开、
遍历或证明某个已存在来源稳定时返回
`STATUS_SKILL_CATALOG_INCOMPLETE`，handle 为 null、descriptor 为空。

因此 Host 只能用 `STATUS_OK` 的结果替换 committed catalog。incomplete 时保留
last-good handle/Session binding，不得把它解释为空 catalog。独立 invalid
candidate 则返回 `OK + degraded` typed issue。

### 3.5 Authorization 与原子绑定

Policy 只授予 descriptor 中的 concrete `skill_id`，默认拒绝，禁止裸
`skill_policy_key` grant。Session create/restore 要求 Catalog 与 Policy 同时
存在或同时缺席。idle-only rebind 共同校验二者并原子提交：任何 foreign id、
重复 id、wrong workspace、资源限制或状态错误都保留旧 binding，不做逐条失活。

### 3.6 Immutable execution 与错误优先序

Catalog handle 固定 Skill body 和全部 resources。文件变化后的新查询产生新的
`content_revision`、`skill_id` 和通常不同的 `catalog_revision`；旧 Session 继续
执行旧 snapshot，绝不在旧 revision 下静默读取新内容。

外部 typed invocation 的可观察校验顺序固定为：

1. wire/UTF-8/identity shape → `INVALID_ARGUMENT`；
2. pinned catalog revision 不匹配 → `STALE_CATALOG`；
3. concrete `skill_id` 不在 snapshot → `SKILL_NOT_FOUND`；
4. concrete id 未获 policy grant → `SKILL_POLICY_VIOLATION`；
5. arguments 不合法 → `INVALID_SKILL_ARGUMENTS`；
6. winner 当前不可执行 → `SKILL_UNAVAILABLE`；
7. 通过后才 admission，不通过不消费 `run_id`。

checkpoint 继续使用 compatibility marker 8，但 selection intersection 存储和
比较 concrete `skill_id`。不改变 checkpoint envelope schema。
Workspace scope identity 的既有 domain marker 继续是内部
`metask-agentcore/abi-v1/revision-5`；它表示该身份算法的引入版本，不是当前
ABI revision，不得机械改成 9。

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

Revision 9 是 exact hard cut。最初的 R9 cut 增加 Completion；本次因尚未正式
发布而在 revision 9 内原子重切 Skill wire：

- `SkillCatalogQueryV1` 恢复 `reserved0=0`，增加 `additional_sources`；
- `SkillSelectionV1` 替换为 default-deny `SkillPolicyV1`；
- 增加 `SkillSourceV1`、concrete identity 和 incomplete status；
- capability bit 的数值位置不变，语义名称切为
  `CAP_SKILL_POLICY` 与 `CAP_WORKSPACE_SKILL_CATALOG`；
- Completion table 和契约不变；
- 不保留旧 R9 Skill wire shim、默认行为或双 revision dispatch。

### 5.2 持久化格式不升级

以下值保持不变：

- Session checkpoint `STATE_SCHEMA_REVISION`；
- Session permission checkpoint revision；
- MCP checkpoint schema；
- Skill catalog descriptor schema 名称；

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
| `sdk/zig/types.zig` | Skill source/query/policy wire、status、capability 与 layout tests |
| `sdk/zig/protocol.zig` | typed source/identity/issues 与 descriptor validation |
| `src/agentcore/abi_v1.zig` | Workspace query、policy transaction、error ordering 与 safe aliases |
| `src/agentcore/skill_catalog_handles.zig` | 默认来源、附加来源验证与 Workspace authority |
| `src/agentcore/session_authority.zig` | checkpoint selection 交集使用 concrete identity |
| `src/skills/runtime/catalog.zig` | 最小来源/贡献/内容身份 metadata seam；resolver 不重写 |
| `src/agentcore/mcp_schema.zig` | dialect-transparent envelope admission 与 Provider 投影 |
| `src/agentcore/mcp_catalog.zig` | dialect/semantic keyword 不再淘汰 Tool |
| `src/agentcore/mcp_session.zig` | 调用前只执行 JSON object envelope 校验 |
| `src/agentcore/mcp_runtime.zig` | MCP Server 负责 input/output schema 语义 |
| `src/agentcore/completion_handles.zig` | 既有 R9 Completion 实现保持不变 |
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

- 单一 Workspace authority 合并 user 与 workspace 默认来源；
- 同名 Skill 由项目来源获胜；
- `workspace_root == workspace_home` 时只扫描一次且不产生伪冲突；
- `reserved0 != 0` 返回 invalid argument；
- `.claude/.codex` 不隐式扫描，但同格式目录可显式注册并投影 source identity；
- 同 scope 同名候选产生 conflict，不按附加来源顺序覆盖；
- invalid/unavailable winner 不回退 loser；
- incomplete 查询不返回新 handle/descriptor，旧 Session binding 仍可执行；
- 内容变化改变 `content_revision` 和 concrete `skill_id`；旧 Session 仍执行 pinned body/resources；
- policy 默认拒绝，只接受当前 catalog 的 concrete ids；失败 rebind 保留旧 binding；
- stale/not-found/policy/unavailable/invalid-arguments 的错误优先序有 wire 断言；
- Catalog handle 可以正常绑定匹配 workspace 的 Session；
- Catalog descriptor、identity 和 revision 保持确定性。

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

### 7.3 MCP schema compatibility

- 无 `$schema`、显式 2020-12、显式 Draft-07 都进入同一可执行 catalog；
- 三类 Tool 同时投影到 Provider 请求，properties/required 保留且根级 `$schema` 不发送；
- dialect、reference、数值约束和未知 semantic keyword 不单独淘汰 Tool；
- 非法 JSON、非 object arguments 和资源超限仍在本地拒绝；
- schema 语义不匹配的 object arguments 能到达 MCP Server，服务端 Tool error 完整返回；
- outputSchema dialect 不影响 Tool admission，成功结果仍要求 structuredContent。

### 7.4 ABI 与交付

- Zig/C/C++/Rust 的 struct size、alignment、offset 和函数表一致；
- R9 revision、table size 和 capability bits 精确匹配；
- Revision 8 table 不被 R9 SDK 接受；
- source-free artifact consumer 跑通 Workspace Catalog、default-deny policy 和一次 Completion；
- Revision 8 checkpoint fixture 在 R9 下恢复成功；
- `zig build agentcore:test` 通过；
- `zig build agentcore:gate` 通过；
- archive/manifest/symbol gates 通过。

## 8. 实施顺序

1. 明确 Source→Resolution→Authorization→Execution 契约和边界；
2. Type-First 修改 public wire、layout 与 descriptor validation；
3. 增加最小 catalog metadata seam，接入 Workspace source policy；
4. 实现 default-deny policy、原子 binding 和 concrete execution；
5. 补 identity、explicit source、incomplete、pinning 与错误优先序 L2；
6. 同步 C Header、Zig SDK、Rust raw/safe SDK 和 artifact consumer；
7. 更新 normative ABI 文档，不升级 revision 或持久化 schema；
8. 通过 Debug/ReleaseSafe、MSVC/GNU 与 source-free delivery gates；
9. 记录最终证据，结束 R9 Skill recut。

## 9. 实施与验证记录

2026-08-20 Skill recut 验证结果：

- `zig test sdk/zig/types.zig`：3/3；
- `zig test sdk/zig/protocol.zig`：19/19；
- `zig build test:skill-runtime`：通过；
- `zig build agentcore:test`：通过（负路径测试会输出预期的 provider error 日志）；
- `zig build agentcore:gate -Dtarget=x86_64-windows-msvc`：C/C++/Zig/Rust native gate 通过；
- MSVC 与 GNU 的 ReleaseSafe `agentcore:bundle`、`agentcore:consumer`：通过；
- MSVC 与 GNU 的 ReleaseSafe `agentcore:archive`：archive contract 6/6，产物与 SHA-256 生成成功；
- MSVC `agentcore:rust`：通过；GNU bundle 与 C/Zig consumer 已通过，但当前机器缺少
  `x86_64-w64-mingw32-gcc`，因此 GNU Rust link probe 是环境阻塞；
- `agentcore:rust-bindgen-check`：当前机器缺少 `libclang.dll`，无法执行 bindgen
  精确再生成 diff；checked-in raw layout 已由 Rust/MSVC、C static asserts 和 Zig layout tests 验证。

旧 R9 cut 的证据不自动证明重切后的 Skill 契约。MCP Classic 空 `params` 修复
仍是独立维护项，不增加 R9 capability。

## 10. Definition of Done

Revision 9 只有同时满足以下条件才算完成：

- Catalog 只有一个 Workspace authority；`reserved0` 不承载扫描策略；
- 默认与显式来源、resolution、concrete identity 和 default-deny policy 闭合；
- complete/incomplete 不会把暂态失败发布为空 catalog；
- Catalog + Policy 共同校验、原子提交，失败保留旧 binding；
- immutable snapshot 与 content identity 有可执行 pinning 证据；
- Completion 是独立 handle，不借用 Session/Runtime 的 Provider 生命周期；
- complete、stream、abort、destroy 的所有权和并发状态均有可执行测试；
- 没有修改 Core、AgentLoop、Provider 实现或 Host Tool；
- MCP schema dialect 不决定 Tool 可用性，服务端保有 schema 语义权威；
- 没有升级 ABI revision、checkpoint/catalog schema 名称或 MCP schema；
- 公共 Header、Zig SDK、Rust SDK、artifact 和 normative 文档原子一致；
- `agentcore:test` 与 `agentcore:gate` 全部通过。

如果其中任何一项只能通过扩大到 Provider Registry、多模态、异步 Host Tool 或 Core 调度修改来完成，应缩减或暂停 Revision 9，而不是继续扩张范围。
