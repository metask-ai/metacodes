# AgentCore ABI v1 Revision 14 — Agent Runtime 收敛方案

> 状态：Proposed；实现前设计冻结候选
>
> 日期：2026-08-26
>
> 实现基线：`main` commit `af1ea06d`，AgentCore ABI v1 Revision 13
>
> 参考分支：`feat/agentcore-r14-subtables`，只参考 layout、SDK 和测试迁移，不继承实现

## 1. 结论

Revision 14 将 AgentCore 公共职责收敛为 **Agent Runtime**。它继续提供 Runtime、Session、
Session maintenance、Skill 和 MCP，不再提供独立通用模型调用 facade。

公共结构固定为：

```text
metask_agentcore_get_api(1)
              |
              v
        AgentCore ApiV1 root
        |-- RuntimeApiV1
        |-- SessionApiV1
        |-- SessionControlApiV1
        |-- SkillApiV1
        `-- McpApiV1
```

本版冻结以下决定：

1. `abi_version == 1`，下一主线 revision 候选为 14。
2. `metask_agentcore_get_api(1)` 仍是唯一公共发现符号。
3. 根表直接持有五张 library-owned typed 子表，不提供 `query_interface`、字符串接口 ID、
   可选能力协商或动态注册。
4. 五张子表全部存在并在 SDK discovery 时一次性验证；消费方需要什么就调用什么，
   不需要时不调用。
5. `runtime_create` 和 `runtime_create_with_plugins` 合并为一个 `RuntimeApiV1.create`，
   插件配置允许为 null。
6. Runtime 创建期间完成插件 staging 和原子发布。发布后的 generation 不可变；没有
   install、uninstall、reload、HMR、watcher 或 live registry。
7. 公共 Completion facade、handle、DTO、status 和 SDK surface 从 R14 删除。
   内部 `CompletionRuntime` 保留，继续服务 compact summary 等内核流程。
8. 不修改 AgentLoop、Provider、Permission、Sandbox、budget、formal verdict、TinyKG、
   artifact CAS、提示词或持久化格式。
9. Revision 14 是 hard cut，不保留 Revision 13 或旧 R14 的 shim、alias、fallback、
   reserved-field 兼容或双 dispatch。

最终公共函数槽共 21 个：

| 位置 | 函数槽数量 |
|---|---:|
| 根表 `buffer_release` | 1 |
| Runtime | 2 |
| Session | 4 |
| Session Control | 7 |
| Skill | 3 |
| MCP | 4 |
| 合计 | 21 |

Revision 13 有 30 个公共函数槽。R14 通过合并两个 Runtime create 删除 1 个，通过删除
公共 Completion 删除 8 个，最终为 21 个。

## 2. 职责边界

### 2.1 AgentCore 负责

- Runtime generation 和 Session 生命周期；
- AgentLoop 与 model-visible history 的因果顺序；
- Tool/Skill/MCP catalog、admission、调度和结果提交；
- Run/compact/checkpoint 的状态机、取消和并发 gate；
- Permission、Sandbox、protected path 和 budget 的最终裁决；
- formal verdict、TinyKG admission 和 artifact CAS；
- Provider-visible prompt bytes 的规范生成。

### 2.2 插件负责贡献，不负责替换内核

“插件能力”分为两层，不得混为同一个公共接口面：

- Zig 源码嵌入层已有 static trusted plugin，可贡献 typed/streaming Tool、typed service、
  单调收紧的 advisory policy 和 deterministic provider dialect；
- AgentCore 二进制 ABI 在 R14 只沿用现有 `RuntimePluginConfigV1`，接收 process plugin source
  和 Host streaming Tool。普通 Host Tool、MCP server 等继续属于 `RuntimeConfigV1`，Skill
  source 继续走现有 Skill catalog 合同。

所有贡献进入不可变 Runtime generation 后，仍受 AgentCore admission 和治理约束。R14 不把
Zig 源码插件面扩张成新的 C ABI。

插件不能取得或替换以下对象：

- AgentLoop；
- Session 状态机；
- Permission/Sandbox guard；
- durable budget/journal；
- formal verdict；
- TinyKG writer；
- artifact CAS。

本版不把内部 Zig typed service graph、任意静态 Zig 插件或新的 process capability 投影为
C ABI，也不加载任意动态库。

### 2.3 Host 负责

- Provider 凭据、Workspace 和产品配置；
- UI callback 和产品持久化；
- 明确选择插件来源；
- 标题、摘要、分类等产品级模型调用；
- 产品级 Prompt、重试、费用和结果展示。

如果消费方希望 Agent 调用某个产品能力，应通过已有 Tool 插件合同暴露语义明确的 Tool，
例如 `SummarizeDocument`，而不是恢复一个允许任意 system/messages/model 的通用
Completion Tool。

## 3. Revision 与发布前提

主线当前为 Revision 13，因此本方案默认：

```text
abi_version  = 1
abi_revision = 14
```

旧 `feat/agentcore-r14-subtables` 已经使用过本地 Revision 14 布局。实现前必须书面确认该
bundle 从未交付给需要兼容的外部消费者：

- 审计记录见附录 A；
- 记录检查过的 release、tag、bundle、交付渠道、日期、证据和结论；
- 口头确认不满足该 Gate；
- 如果旧 R14 已外发，本文所有 Revision 14 标识必须整体改为 Revision 15。

拒绝关系由根表大小在稳定前缀处完成：

| 布局 | 根表大小 | 新 R14 consumer |
|---|---:|---|
| Revision 13 平铺表 | 280 | 拒绝 |
| 旧 R14 五子表参考布局 | 72 | 拒绝 |
| 本方案 | 64 | 接受后继续逐表验证 |

反向 consumer fixture 同样因 64/72/280 不相等而拒绝。验证器不得在 root size/version
通过前读取后续字段或解引用子表。

## 4. 根表

### 4.1 C 形状

```c
typedef struct metask_agentcore_runtime_api_v1
    metask_agentcore_runtime_api_v1;
typedef struct metask_agentcore_session_api_v1
    metask_agentcore_session_api_v1;
typedef struct metask_agentcore_session_control_api_v1
    metask_agentcore_session_control_api_v1;
typedef struct metask_agentcore_skill_api_v1
    metask_agentcore_skill_api_v1;
typedef struct metask_agentcore_mcp_api_v1
    metask_agentcore_mcp_api_v1;

typedef struct metask_agentcore_api_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t abi_revision;
    uint32_t reserved0;
    metask_agentcore_buffer_release_fn_v1 buffer_release;
    const metask_agentcore_runtime_api_v1 *runtime;
    const metask_agentcore_session_api_v1 *session;
    const metask_agentcore_session_control_api_v1 *session_control;
    const metask_agentcore_skill_api_v1 *skill;
    const metask_agentcore_mcp_api_v1 *mcp;
} metask_agentcore_api_v1;
```

### 4.2 固定布局

Revision 14 继续只支持规范指定的 64-bit pointer ABI：

| Offset | 字段 | 大小 |
|---:|---|---:|
| 0 | `struct_size` | 4 |
| 4 | `abi_version` | 4 |
| 8 | `abi_revision` | 4 |
| 12 | `reserved0` | 4 |
| 16 | `buffer_release` | 8 |
| 24 | `runtime` | 8 |
| 32 | `session` | 8 |
| 40 | `session_control` | 8 |
| 48 | `skill` | 8 |
| 56 | `mcp` | 8 |

根表固定大小 64 bytes，alignment 8。

Revision 13 的全局 `capabilities` 删除。它在 exact revision 合同下与 revision、table size
和 mandatory slot 集合重复，不承担独立协商语义。R14 通过五个非 null typed pointer
表达完整 Agent Runtime 能力面。

根表不增加备用函数槽或 `reserved[]`。新增领域时明确升级 ABI revision。

## 5. 五张领域子表

所有子表使用同一 exact-layout 前缀：

```c
uint32_t struct_size;
uint32_t reserved0;
```

`struct_size` 必须精确相等，`reserved0` 必须为零。子表是 library-lifetime、只读、地址稳定
的静态对象，不拥有任何 Runtime、Session 或 Catalog handle。

### 5.1 RuntimeApiV1

```c
typedef uint32_t (*metask_agentcore_runtime_create_fn_v1)(
    const metask_agentcore_runtime_config_v1 *config,
    const metask_agentcore_runtime_plugin_config_v1 *plugins,
    metask_agentcore_runtime **out_runtime,
    metask_agentcore_owned_bytes_v1 *out_error);

struct metask_agentcore_runtime_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_runtime_create_fn_v1 create;
    metask_agentcore_runtime_destroy_fn_v1 destroy;
};
```

固定大小 24 bytes。

`plugins` 允许为 null：

- null 等价于没有额外的 `RuntimePluginConfigV1` 贡献；
- 非 null 时沿用现有 process plugin 和 Host streaming Tool 的校验与 ownership；
- create 返回前完成输入复制、manifest/digest/handshake/依赖校验和原子发布；
- 任一失败拒绝整个 Runtime，不发布 partial generation；
- 删除 `runtime_create_with_plugins`，不保留 forwarding alias。

### 5.2 SessionApiV1

```c
struct metask_agentcore_session_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_session_create_fn_v1 create;
    metask_agentcore_session_destroy_fn_v1 destroy;
    metask_agentcore_session_run_input_fn_v1 run_input;
    metask_agentcore_session_abort_fn_v1 abort;
};
```

固定大小 40 bytes。它表达最小 Agent 执行生命周期：

```text
Runtime create -> Session create -> Run/Abort -> Session destroy -> Runtime destroy
```

Session 继续拥有 Conversation、AgentLoop admission、权限作用域、预算和事件投影。

### 5.3 SessionControlApiV1

```c
struct metask_agentcore_session_control_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_session_restore_fn_v1 restore;
    metask_agentcore_session_describe_fn_v1 describe;
    metask_agentcore_session_set_model_fn_v1 set_model;
    metask_agentcore_session_update_permission_rules_fn_v1 update_permission_rules;
    metask_agentcore_session_compact_fn_v1 compact;
    metask_agentcore_session_abort_compact_fn_v1 abort_compact;
    metask_agentcore_session_export_checkpoint_fn_v1 export_checkpoint;
};
```

固定大小 64 bytes。它只负责恢复、观察和显式 Session maintenance。单独成表是为了把基本
执行生命周期与维护操作分开，不表示插件可以替换 Session 状态机。

### 5.4 SkillApiV1

```c
struct metask_agentcore_skill_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_runtime_query_skill_catalog_fn_v1 resolve_catalog;
    metask_agentcore_skill_catalog_release_fn_v1 release_catalog;
    metask_agentcore_session_bind_skills_fn_v1 bind_policy;
};
```

固定大小 32 bytes。保留完整 immutable catalog snapshot、显式 source、default-deny policy
和 Session 原子绑定语义。消费者可以提供 Skill 内容，不能替换 canonical parser。

### 5.5 McpApiV1

```c
struct metask_agentcore_mcp_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_runtime_apply_mcp_configuration_fn_v1 apply_configuration;
    metask_agentcore_runtime_refresh_mcp_fn_v1 refresh;
    metask_agentcore_runtime_describe_mcp_fn_v1 describe;
    metask_agentcore_session_update_mcp_fn_v1 update_selection;
};
```

固定大小 40 bytes。Host 继续拥有 transport callback、凭据和连接上下文；AgentCore 继续
拥有协议协商、canonical catalog、tool-call 校验、Session selection 和结果数据面。

## 6. 公共 Completion 删除决定

Revision 13 Completion 是独立于 Runtime、Session、Conversation 和 AgentLoop 的无工具文本
Provider facade。它不经过 Session 的 Permission、budget、journal 或 checkpoint 治理，
本质上是 AgentCore 附带的通用模型调用 SDK，不是 Agent Runtime。

R14 从公共投影删除：

- `CompletionHandle`、`CompletionStreamHandle`；
- `CompletionConfigV1`、`CompletionMessageV1`、`CompletionRequestV1`；
- `CompletionResultV1`、`CompletionInfoV1`、`CompletionEventV1`；
- Completion stop reason/event kind；
- create/destroy/describe/complete/stream-start/next/abort/destroy 八个函数；
- `completion_unsupported_response` public status；
- C/Zig/Rust safe SDK wrapper 和 source-free consumer 调用。

不删除或修改：

- `src/api/completion.zig`；
- `src/core/compact_summary.zig` 对内部 `CompletionRuntime` 的使用；
- Provider 实现和 AgentLoop 请求路径。

`completion_unsupported_response` 的符号和公共语义删除，但其 status code 26 永久废弃，
不得分配给其他状态。`skill_catalog_incomplete` 保持编号 27。R14 SDK 解码数值 26 时必须返回
`UnknownStatus`；这样保留能力的 wire 值、历史日志和跨版本诊断记录不会静默换义。

消费方的标题、摘要、分类和其他独立模型调用属于 Host/产品插件。若需要让 Agent 调用，
应包装成输入输出受限、业务语义明确的 Tool；本版不定义 Completion plugin ABI，也不向
插件暴露 AgentCore Provider 指针或凭据。

## 7. Revision 13 迁移矩阵

| Revision 13 字段 | Revision 14 位置 | 处理 |
|---|---|---|
| `runtime_create` | `root->runtime->create(..., NULL, ...)` | 合并 |
| `runtime_create_with_plugins` | `root->runtime->create(..., plugins, ...)` | 合并 |
| `runtime_destroy` | `root->runtime->destroy` | 保留 |
| `runtime_query_skill_catalog` | `root->skill->resolve_catalog` | 保留 |
| `skill_catalog_release` | `root->skill->release_catalog` | 保留 |
| `runtime_refresh_mcp` | `root->mcp->refresh` | 保留 |
| `runtime_describe_mcp` | `root->mcp->describe` | 保留 |
| `runtime_apply_mcp_configuration` | `root->mcp->apply_configuration` | 保留 |
| `session_create` | `root->session->create` | 保留 |
| `session_restore` | `root->session_control->restore` | 保留 |
| `session_destroy` | `root->session->destroy` | 保留 |
| `session_describe` | `root->session_control->describe` | 保留 |
| `session_set_model` | `root->session_control->set_model` | 保留 |
| `session_update_skills` | `root->skill->bind_policy` | 保留 |
| `session_update_permission_rules` | `root->session_control->update_permission_rules` | 保留 |
| `session_update_mcp` | `root->mcp->update_selection` | 保留 |
| `session_run_input` | `root->session->run_input` | 保留 |
| `session_abort` | `root->session->abort` | 保留 |
| `session_compact` | `root->session_control->compact` | 保留 |
| `session_abort_compact` | `root->session_control->abort_compact` | 保留 |
| `session_export_checkpoint` | `root->session_control->export_checkpoint` | 保留 |
| `buffer_release` | `root->buffer_release` | 保留 |
| `completion_create` | 无 | 删除公共投影 |
| `completion_destroy` | 无 | 删除公共投影 |
| `completion_describe` | 无 | 删除公共投影 |
| `completion_complete` | 无 | 删除公共投影 |
| `completion_stream_start` | 无 | 删除公共投影 |
| `completion_stream_next` | 无 | 删除公共投影 |
| `completion_stream_abort` | 无 | 删除公共投影 |
| `completion_stream_destroy` | 无 | 删除公共投影 |

除上述 hard cut 项外，保留的函数 DTO、ownership、status、stop reason、线程约束和 handle
失效规则沿用 Revision 13。

## 8. SDK 与验证模型

### 8.1 验证顺序

C compatibility helper、Zig `Api.discover` 和 Rust `Api::discover/from_raw` 必须：

1. 要求 discovery 返回非 null、满足根表对齐；
2. 只读取稳定前缀中的 `struct_size` 和 `abi_version`；
3. 要求 root size 64、ABI version 1；
4. 才读取并要求 revision 14、`reserved0 == 0`；
5. 要求 `buffer_release` 和五个子表指针全部非 null；
6. 逐表检查指针对齐、exact `struct_size`、`reserved0 == 0`；
7. 要求每个表的全部函数槽非 null；
8. 全部通过后才发布 safe `Api`。

成功 discovery 后，五个领域 accessor 返回 borrowed、不可失败的 typed view。消费方不需要
额外发现或选择接口。

### 8.2 使用形状

C：

```c
const metask_agentcore_api_v1 *api = metask_agentcore_api_v1_discover();
if (api == NULL) fail_incompatible_bundle();

check(api->runtime->create(&runtime_config, &plugin_config, &runtime, &error));
check(api->skill->resolve_catalog(runtime, &query, &catalog, &json, &error));
```

Zig：

```zig
const api = try sdk.Api.discover();
const runtime = try api.runtime().create(config, plugin_config);
const session = try api.session().create(runtime, session_config, callbacks);
const catalog = try api.skill().resolveCatalog(runtime, query);
```

Rust：

```rust
let api = Api::discover()?;
let runtime = api.runtime().create(&config, Some(&plugins))?;
let session_api = api.session();
```

Rust raw binding 继续由固定 bindgen 版本从 C header 生成，禁止手改 `raw.rs`。

## 9. Bundle manifest

Revision 14 是 hard cut。bundle manifest 保持 schema version 1，删除 capability mask，
只记录精确 ABI revision 和根表大小；子表由 runtime discovery 验证，不在 manifest 中
维护第二份 inventory：

```json
{
  "schema_version": 1,
  "vendor": "metask",
  "name": "agentcore",
  "contract": {
    "binary_abi_status": "experimental",
    "binary_abi_version": 1,
    "binary_abi_revision": 14,
    "binary_abi_table_size": 64
  }
}
```

artifact consumer 验证 schema 1、ABI revision 14、64-byte 根表和 bundle file digests；
加载后再由 ABI discovery 验证五张必选子表。Revision 13 bundle 直接按 revision/size 拒绝，
不提供旧 manifest 迁移、双解析或兼容路径。

## 10. 生命周期与不可变性

- 根表和五张子表在 library 完整加载期间地址稳定；
- Runtime create 成功后 generation 不可变；
- Session 固定绑定创建它的 Runtime generation；
- Runtime 在任一 Session 存活时 destroy 返回 busy；
- 需要更换插件集合时创建新 Runtime 和新 Session，旧 Session 行为不漂移；
- Host callback retain/release、同步借用和禁止重入规则沿用 R13；
- 没有 HMR、live registry 或跨 generation handle 复用。

## 11. 明确非目标

本版不做：

- 修改 MetaCode 身份或系统提示词；
- 开放任意 Session system prompt；
- 修改 AgentLoop、Provider、Permission、MCP canonical 或 Skill runtime 业务语义；
- 删除或重写内部 CompletionRuntime；
- 修改 checkpoint、journal、artifact、TinyKG 或数据库表；
- 暴露完整 Zig plugin service graph；
- 加载任意动态库或同进程不可信代码；
- 新增插件安装、市场、网络下载、热更新或 watcher；
- 修改 MCP 外部协议、Skill 文件格式或 Provider wire；
- 保留 Revision 13/旧 R14 兼容层；
- 借 ABI 重组新增产品功能。

Provider-visible bytes 是 cache contract。table layout、plugin path、Runtime generation、
journal 和 timestamp 不得进入 prompt。MetaCode 身份和现有 prompt golden bytes 保持不变。

## 12. 实施范围

### 12.1 必须修改

| 文件 | 修改 |
|---|---|
| `sdk/metask/agentcore.h` | R14 根表、五张子表、删除公共 Completion、layout assertions |
| `sdk/zig/types.zig` | R14 raw types、status 26 tombstone、删除公共 Completion types |
| `sdk/zig/root.zig` | 根表/子表验证和五个领域 view |
| `sdk/rust/src/raw.rs` | 从 C header 重新生成 |
| `sdk/rust/src/lib.rs` | R14 验证、领域 view、删除 Completion wrapper |
| `src/agentcore/abi_v1.zig` | 五张表装配、统一 Runtime create、删除 Completion 转发 |
| `src/agentcore/completion_handles.zig` | 删除仅服务公共 ABI 的 handle adapter |
| `scripts/agentcore_manifest.zig` | schema-1 manifest 的 Revision 14 hard-cut 元数据 |
| `tests/component/agentcore_abi_test.zig` | layout/validation/dispatch/L2，删除公共 Completion fixtures |
| `tests/agentcore_header_compile.c` | C11/C++17 layout 和调用形状 |
| `tests/agentcore_artifact_consumer/**` | schema-1 R14 manifest 和 source-free 四语言 consumer |
| `doc/AGENTCORE_BINARY_ABI.md` | Revision 14 normative contract |
| `doc/API.md`、`doc/LIB_API.md` | Agent Runtime 公共边界 |
| `sdk/README.md`、bundle README | R13 -> R14 迁移说明 |

### 12.2 默认禁止修改

- `src/core/system_prompt.zig`；
- `src/core/agent_loop.zig`；
- `src/api/completion.zig`；
- `src/core/compact_summary.zig`；
- Provider、Permission、MCP canonical、Skill runtime；
- `src/formal/**`、TinyKG bundle、artifact CAS；
- checkpoint/journal/schema 编码；
- CLI/TUI/Web 产品行为；
- plugin process protocol 和 plugin manifest v1。

如果实现必须修改这些业务层，停止当前批次并形成 necessity record，不得以“ABI 适配”为名
扩大范围。

## 13. 实施顺序

### Phase 0：冻结与发布审计

- 完成旧 R14 是否外发的书面审计；
- 冻结 root/table layout、状态码、ownership 和迁移矩阵；
- 保存 Revision 13 和旧 R14 root fixture 作为拒绝证据。

### Phase 1：Raw ABI 纵向切片

- 先定义 C/Zig raw types 和 compile-time layout assertions；
- 装配五张静态子表和 64-byte 根表；
- 合并 Runtime create；
- 删除 Completion 公共投影；
- 用 C header compile 和 Zig L2 完成可运行切片。

### Phase 2：SDK 与 artifact

- 迁移 Zig/Rust safe SDK；
- 重新生成 Rust raw binding；
- 迁移 C/C++/Zig/Rust source-free consumer；
- 生成并验证 hard-cut 后的 schema-1 R14 manifest。

### Phase 3：规范与全量门禁

- 更新 normative ABI、API overview 和 SDK/bundle README；
- 运行 AgentCore L2、组件、集成、coverage、doc link 和 diff hygiene 门禁；
- declaration、wiring、L2 evidence 必须在同一变更闭环。

## 14. 验收标准

### 14.1 Layout 与拒绝矩阵

- root 64、Runtime 24、Session 40、Session Control 64、Skill 32、MCP 40；
- C11/C++17/Zig/Rust 的 size、alignment、offset 一致；
- root null、misaligned、错误 size/version/revision/reserved 被拒绝；
- `buffer_release` 或任一子表为 null 被拒绝；
- 每张子表错误 alignment/size/reserved 或任一 function slot 为 null 被拒绝；
- R13 280-byte 和旧 R14 72-byte fixture 在 root size 处拒绝；
- 根表失败时不提前读取或解引用子表；
- public status 不再声明 `completion_unsupported_response`，数值 26 解码为 `UnknownStatus`，
  `skill_catalog_incomplete` 保持 27；
- public symbol gate 仍只承认 `metask_agentcore_get_api` 为 AgentCore ABI entry point。

### 14.2 Dispatch identity

C compatibility helper、Zig safe SDK 和 Rust safe SDK 分别使用每槽唯一 sentinel，验证：

- 五张子表没有错接；
- 20 个领域函数槽没有漏接或交换；
- 根级 `buffer_release` 正确；
- 同签名槽位交换也能被 fixture 检出。

### 14.3 Runtime 与插件 L2

- `plugins == NULL` 创建无额外插件 Runtime；
- 空 `RuntimePluginConfigV1` 与 null 得到等价 generation；
- Host streaming Tool 和 process plugin 通过统一 create 进入真实 Tool schema/execute；
- invalid manifest、digest、handshake、dependency 或名称冲突拒绝整个 Runtime；
- 失败不发布 partial generation，不泄漏 callback/effect/process；
- 活跃 Session 期间 Runtime destroy 继续 busy；
- 新旧 Runtime generation 之间 Session 行为不漂移。

### 14.4 Agent Runtime L2

- Runtime -> Session -> Run/Abort -> destroy 闭环；
- Session restore/describe/set-model/permission/compact/checkpoint 闭环；
- Skill resolve -> bind -> model-visible tool -> execute 闭环；
- MCP apply/refresh -> select -> tool call -> streamed artifact 闭环；
- Permission、Sandbox、formal verdict、budget 和 TinyKG admission 拒绝测试保持通过；
- 内部 compact summary 继续通过 CompletionRuntime 复用 Provider；
- 公共 header/SDK/manifest 不再声明 Completion surface。

### 14.5 Prompt 与持久化零变化

- AgentCore system prompt 与 R13 golden bytes 一致；
- MetaCode 身份和工具说明不变；
- table/plugin/generation/journal/timestamp 不进入 Provider-visible bytes；
- checkpoint、journal、artifact 和 TinyKG 格式无 diff；
- 公共 ABI 不存在独立 Completion system 输入。

### 14.6 提交前门禁

```sh
zig fmt --check build.zig src tests
zig build test:lib -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
scripts/test_coverage_audit.sh
python3 scripts/check_doc_links.py
git diff --check
```

此外必须运行 AgentCore bundle/source-free consumer、C/C++ header compile、Rust SDK test 和
public symbol gate。不得运行付费 Provider benchmark，除非另有明确授权、费用上限和 durable
budget journal。

## 15. 合入条件

满足以下条件才可提交实现：

- Revision 编号审计通过；
- root/table/header/SDK/manifest 布局一致；
- Runtime create 统一且 plugin generation 原子、不可变；
- 公共 Completion 完整删除，内部 CompletionRuntime 回归通过；
- 除明确删除的 Completion 外，R13 Agent Runtime 能力全部迁移；
- AgentLoop、安全治理、提示词和持久化格式无行为变化；
- C/C++/Zig/Rust source-free consumer 与真实 L2 全部通过；
- 文档、实现和测试不存在兼容 shim、第二事实源或 silent no-op。

如果实施中发现需要开放可替换 AgentLoop、动态 registry、Provider service、通用 Completion
plugin、提示词覆盖或新的持久化模型，立即停止本 Revision，另立设计。

## 附录 A：Revision 14 发布编号审计

> 状态：Passed
>
> 日期：2026-08-26
>
> 审计对象：旧 `feat/agentcore-r14-subtables` 布局是否已经交付给需要兼容的外部消费者

### A.1 结论

旧 72-byte Revision 14 布局仅存在于本地参考分支，没有进入本项目受控的远端分支、tag、
release source 或主线。维护方已书面决定旧 R14 只作为参考，并要求从 `main` 重新实施插件化
ABI。因此新的 Agent Runtime ABI 可以继续使用：

```text
abi_version  = 1
abi_revision = 14
```

如果后续发现曾通过仓库外人工渠道交付旧 R14 bundle，本结论立即失效；新方案必须在发布前
整体改为 Revision 15，不得在 Revision 14 下发布第二种布局。

### A.2 被审计对象

| 项目 | 值 |
|---|---|
| 旧设计提交 | `89cdbfe3` |
| 旧实现提交 | `4da02abe45850b607e0605d4e362e49fab1ec977` |
| 旧分支 | `feat/agentcore-r14-subtables` |
| 与当前主线的 merge base | `f09cb23519101a60857e78e0f127ff423c63a415` |
| 旧布局 | 72-byte root；Runtime/Session/Skill/MCP/Completion 五张子表 |
| 当前主线基线 | `main` `af1ea06dddc1e4f5274e93a971070d0c578f8f3c`；Revision 13 |

### A.3 检查记录

#### A.3.1 Git 可达性

2026-08-26 检查结果：

- `git for-each-ref --contains` 显示两个旧提交只被本地
  `refs/heads/feat/agentcore-r14-subtables` 引用；
- 本地没有包含旧实现提交的 tag 或其他 branch；
- `origin` 当时共有 4 个 remote head；逐一做 ancestor 检查，均不包含旧设计或旧实现提交；
- `git ls-remote --tags origin` 返回 0 个 remote tag；
- `origin` 不存在名为 `feat/agentcore-r14-subtables`、R14 或 Revision 14 的 head/tag；
- `main` 与旧分支分叉，旧分支相对 `main` 只有上述 2 个独有提交，未合入主线。

#### A.3.2 仓库发布记录

在排除本冻结方案自身、构建缓存和 vendor 后，仓库工作树未发现以下发布痕迹：

- Revision 14 ABI 常量；
- 72-byte AgentCore root manifest；
- 旧 R14 bundle/release 清单；
- 对 `feat/agentcore-r14-subtables` 的发布引用。

`CHANGELOG.md`、AgentCore manifest 生成器和 artifact consumer 仍以当前主线合同为事实源。

#### A.3.3 发布方书面方向

本次设计流程已明确记录：

- 旧 R14 分支只作为 layout、SDK 和测试迁移参考；
- 不合入旧实现；
- 基于最新 `main` 重新制定并实施 Agent Runtime ABI；
- 新方案经评审得到 `APPROVE`，没有 blocking finding。

该方向已固化在本方案和 TinyKG decision 1364/task root 1365，不依赖口头确认。

### A.4 证据边界

本审计覆盖当前本地仓库、全部可见 local refs、`origin` remote heads/tags、工作树发布记录和
维护方书面实施方向。当前环境无法通过 GitHub HTTP API读取私有 Release/Actions Artifact
元数据；同时，任何未登记在仓库、远端 refs 或项目记录中的人工文件传输都无法由代码库
自动证明不存在。

项目发布规则要求正式 bundle 具有 tag/manifest/digest 和 source-free consumer 证据。按该
受控发布模型，旧 R14 未发布。若维护方掌握仓库外交付证据，必须在 Phase 1 发布新 bundle
前否决本审计并升级 revision。

### A.5 Gate

Phase 0 Gate 结论：**通过**。

- 新方案冻结为 AgentCore ABI v1 Revision 14；
- 旧 72-byte R14 fixture 只保留为拒绝测试；
- 新 64-byte R14 consumer 必须拒绝旧 R14；
- 发现任何旧 R14 外发证据时，Revision 15 升级规则自动生效。
