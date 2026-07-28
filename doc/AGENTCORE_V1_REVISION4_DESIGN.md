# AgentCore ABI v1 Revision 4 设计

> 状态：Revision 4 公共 ABI 与内部 Skill Runtime 收敛均已实施
> 日期：2026-07-28
> 前置：`AGENTCORE_V1_EXPERIMENTAL_LEDGER.md` A1/A3/A4、B1–B4、C9
> 本文记录已实施设计；公共契约以 `AGENTCORE_BINARY_ABI.md` 为准。

## 0. 版本语义

Revision 4 是一次 experimental breaking cut，目标只有两类：

1. 修正 ABI 声明与实际行为不一致的 A1/A3/A4、B1–B4；
2. 根据 MetaWork 的 C9 消费证据，把已有 Skill 内核暴露为 UI-neutral 的正式 ABI。

版本仍为 ABI v1，以 `(abi_version=1, abi_revision=4)` 精确定位。Revision 3 与
Revision 4 双向拒绝混用；每个 revision 定义自己的 table layout 和
`struct_size`。`struct_size` 用来校验对象符合该 revision，不限制后续 revision
扩展 v1。

不进入本 cut：通用 Command ABI、slash parser、`/resume`、`/retry`、`/compact`、
Session persistence/restore、异步 Run、Conversation 导出、托管语言绑定和冻结后的
演化机制。

## 1. 全局不变量

1. **可观察**：Run 的最终文本和全部 provider usage 可仅凭 public events 与
   `RunResult` 重建。
2. **宿主拥有策略**：AgentCore facade 不隐式读 fd 0、不写产品配置、不向 stderr
   输出产品 UI。
3. **尽早失败**：由 Runtime、Session、CatalogQuery 或 RunInput 已能确定的错误，
   必须在对应 admission 阶段失败。
4. **先限长再解码**：外部 descriptor 先检查长度，再访问 pointer、校验 UTF-8、
   parse 或分配。
5. **所有权统一**：callback/descriptor 的 canonical 与 release 规则不因 status
   改变。
6. **Session 前可发现**：Skill catalog 查询不依赖 Task 或 Session。
7. **Snapshot 绑定**：Skill body、资源、覆盖与 policy 均来自 immutable snapshot；
   Run 不重新读取活文件。
8. **单一 Run 合同**：Text 与 Skill 共用 run_id、admission、events、usage、abort、
   poison、Conversation 和 quiescence 语义。
9. **UI-neutral**：AgentCore 不解析 slash、不发布 Command catalog、不认识具体命令。
10. **最小失败域**：能归属到单个 Skill slot 的错误只隔离该 slot；无法证明整个
    候选集合或 snapshot 完整性时才使 catalog query 失败。
11. **嵌套权限单调收窄**：child activation 的工具、shell 和 permission bounds
    不得超出 parent；并发 sibling 互不污染。
12. **单一 Skill 语义**：CLI 与 AgentCore 必须共用同一套 catalog、invocation、
    policy、materialization 与 activation 实现；产品入口和 ABI 入口只能保留适配逻辑。

## 2. Cut 范围

| 项 | 目标 | 证据 | breaking |
|---|---|---|---|
| A1 | `on_event` 必填，事件流成为唯一输出合同 | ledger A1 | 是 |
| A3 | Host-owned 权限策略及新的 permission 词汇 | ledger A3 | 是 |
| A4 | `session_create` 探测沙箱可用性 | ledger A4 | 行为收紧 |
| B1 | UI answers 改为 per-question values 数组 | ledger B1 | 是 |
| B2 | 增加 `UI_CANCELLED` | ledger B2/C3 | 是 |
| B3 | 工具 schema 和名称严格校验 | ledger B3 | 行为收紧 |
| B4 | prompt 16 MiB 上限 | ledger B4/C5 | 行为收紧 |
| S1 | pre-session Skill catalog 与 typed RunInput | ledger C9 | 是 |

C9 引用 MetaWork commit
`4e0f30dfe44fea29288f35d334f2532ecf8df071` 的
`docs/workbench-ui-design.md` §5.1/§5.3 和
`docs/agentcore-abi-v1.md` §2/§4。

## 3. 契约修正

### 3.1 A1：事件流即输出合同

- `session_create` 在 `callbacks.on_event == NULL` 时返回 `INVALID_ARGUMENT`。
- `RunResult` 继续保持 POD 摘要，不携带文本或 owned 资源。
- Revision 4 不增加终结摘要事件。

Host 按以下规则重建最终文本：

1. `text_chunk` 追加到当前 response segment；
2. `stream_done` 关闭当前 segment，之后的文本属于新 segment；
3. public `tool_start` 或 `tool_result` 是 answer-group boundary：清空此前累计的
   closed segments，并丢弃尚未关闭的当前 segment；`tool_progress` 不是边界；
4. Run 返回 `OK` 后，最终文本为最后一个 answer-group boundary 之后全部 closed
   segments 的顺序拼接；没有边界时拼接全部 closed segments；
5. 非 `OK` 时，已发事件只是 provisional observations。

因此 continuation 的多个 stream 会拼接，而工具调用前的中间文本不会进入最终答案。
AgentCore 必须为每个 run-root 工具执行发出 public answer-group boundary。model-tool
内部执行只有在被外层 public Skill 工具边界完整包围时才可抑制内部工具边界。

Usage 合同：

- 本 Run 发起的主采样、continuation、自动压缩、fork 和 retry attempt，只要
  provider 返回 usage，就必须向同一 public sink 发出对应增量，且每个字段恰好
  计入一次；
- provider-neutral `ApiResponse` 增加 `usage: ?UsageDelta`，流式和非流式路径使用
  同一 checked parser；
- usage 整体缺失表示不可观测，不猜数、不发零值事件；
- 已出现但类型错误、负数、非整数或溢出的字段使响应解析失败；
- Host 使用 checked arithmetic；累计溢出即重建失败，不得 wrap 或 saturate。

上述重建算法必须进入 canonical ABI 文档，并由独立 provider fixture 作为 oracle，
不能用被测 Conversation 反推期望值。

### 3.2 A3：Host-owned 权限策略

新增内部策略：

```text
PermissionPersistence = product_managed | host_owned
```

- AgentCore facade session 固定为 `host_owned`；CLI 固定为 `product_managed`。
- `host_owned` 下，`allow_session` 只更新内存 SessionRules；权限子系统不得写
  workspace/HOME 产品配置。
- `host_owned` 下 requester 缺失、`UNAVAILABLE` 或 `CANCELLED` 均 fail-closed，
  等效 `deny_once`，不得读取 fd 0。
- callback 抛错、未知 status、非法 response 或 release 违约返回
  `CALLBACK_FAILED` 并 poison；分配失败返回 `OUT_OF_MEMORY`。
- `product_managed` 保留现有 CLI TUI、answer queue 与文本 fallback 行为。

公共 permission 词汇改为：

```text
allow_once | allow_session | deny_once | deny_session
```

移除 `allow_always` 与 `deny_tool_session`，不保留别名。

### 3.3 A4：创建时验证沙箱

- 提取共享 `sandbox.executableAvailability()`，结果为
  `available | unsupported_os | missing | not_executable`；macOS 使用 `X_OK`。
- `session_create(SANDBOXED)` 先检查可执行性，再用最小 profile 执行一次
  `/usr/bin/true` canary；任一步失败均返回 `INVALID_ARGUMENT`，不创建 Session。
- canary 只在 Session admission 执行一次。每条命令仍轻量复查环境，并固定
  `fail_if_unavailable = true`，不得静默 passthrough。
- `DISABLED` 与 `UNRESTRICTED` 不执行该探测。

### 3.4 B1：UI answers 数组化

Revision 4 response：

```json
{"answers":[{"values":["a","b"]}]}
```

约束：

- `answers.len == questions.len`；
- single：`values.len == 1`；
- multi：`1 <= values.len <= options.len`；
- 每题 `options.len >= 1`，违反表示 core 内部契约错误；
- values 可以是 option label 或自由文本，不要求属于 options。

facade 向现有内部单字符串答案投影时，用 `", "` 连接 values。公共 wire 保留数组
边界，不再使用逗号分隔字符串编码多选。

### 3.5 B2：区分取消与不可用

新增：

```text
METASK_AGENTCORE_UI_CANCELLED = 3u
```

- `CANCELLED` 与 `UNAVAILABLE` 均不 poison Session。
- permission request 的 `CANCELLED` 等效 `deny_once`。
- ask-question 的 `CANCELLED` 映射为现有模型可见 `InputAborted` tool error。
- 所有 status 的非空 canonical response token 都必须恰好 release 一次；只有
  `ANSWERED` 解析内容。
- `FATAL`、未知 status 和非法 response 保持 callback-fatal 语义。

### 3.6 B3：工具 schema 与名称严格化

`runtime_create` 必须拒绝：

- schema 顶层出现 `type`、`properties`、`required` 之外的键；
- `required` 重复或引用不存在的 property；
- 不匹配 `^[A-Za-z_][A-Za-z0-9_-]{0,63}$` 的 builtin/Host tool name。

名称规则采用 Anthropic、OpenAI、Gemini 的保守交集。官方规则于 2026-07-23
查证：[Anthropic](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools?categoryid=2849204)、
[OpenAI](https://github.com/openai/openai-python/blob/main/src/openai/types/chat/completion_create_params.py)、
[Gemini](https://firebase.google.com/docs/reference/js/ai.functiondeclaration)。

本地 provider request fixture 只验证 encoder，不代替外部规则证据。

### 3.7 B4：prompt 上限

新增：

```text
METASK_AGENTCORE_MAX_PROMPT_BYTES_V1 = 16777216ULL
```

`session_run_input(TEXT)` 先按 descriptor length 检查 16 MiB 上限；超限返回
`RESOURCE_LIMIT`，之后才允许访问 pointer、校验 UTF-8 或进入 core。

## 4. Skill 架构

### 4.1 责任边界

```text
MetaWork slash/Command UI → Workbench tasks.run
→ AgentCore session_run_input → Run events + RunResult
```

- **MetaWork**：slash parser、Command Registry、菜单/补全与冲突策略。内建 Command
  优先于同名 Skill。
- **Workbench**：扩展既有 `tasks.run` input union 为 `text | skill`，校验
  Task/Run ownership、Workspace binding 和 catalog ownership；取消仍走
  `metawork.tasks.cancel`。
- **共享 Skill Runtime**：Skill discovery、优先级、snapshot、参数终验、policy、
  资源以及 inline/fork 的唯一语义权威。
- **AgentCore adapter**：拥有 ABI handle/status、Session/Run admission、Host callback、
  event/diagnostic 映射，不拥有第二套 Skill 语义。

AgentCore 不提供 `list_commands`、`invoke_command` 或 slash parser。`/new`、
`/status`、`/stop` 等产品命令不进入 AgentCore。MetaWork 对未命中的 Command 再查
Skill catalog；命中 valid Skill 才提交 typed invocation，命中 typed issue 显示
unavailable，均未命中才是 unknown slash。不得回退成 text prompt。

#### 4.1.1 单一 Skill Runtime 与适配边界

共享实现位于 `src/skills/runtime/`，依赖方向固定为：

```text
CLI Skill adapter ─┐
                   ├─> skills/runtime ─> 既有通用执行接口
AgentCore adapter ─┘
```

Runtime 负责 canonical definition、catalog resolver/snapshot、typed invocation、
argument validation、PolicyFrame、materialization、activation plan 与模型面 Skill
语义。它不得 import `agentcore`、`app`、`repl`，也不得依赖具体的
`agent_loop`、`agent_session`、Conversation 或 permission 产品层；只能使用
adapter-neutral 的既有通用接口。

AgentCore 保留 scope HMAC、catalog handle/refcount、wire descriptor/status、
Session/run_id/admission、Host callback 与 event projection。CLI 保留 source 配置、
slash/UI、DynRegistry 与错误呈现。两侧 adapter 只做类型、所有权和错误映射，不得重新
解析 frontmatter、计算优先级/policy、读取活 Skill tree 或实现第二条 inline/fork 路径。

本次收敛不新增 `agent_loop`、provider、Conversation、permission engine、REPL
基础设施或 subagent scheduler 改动，只复用已经存在的通用执行钩子。CLI Skill
适配语义集中在 `src/skills/cli_adapter.zig`；`app.zig` 只负责 Runtime/adapter
初始化与接线，`repl/loop.zig` 只负责 import、slash 委托和删除旧 handler。现有
`SkillSet`、`ActiveSkillState` 或 pool-filter 形状若因底层调用签名暂时保留，必须
降为 Runtime projection/adapter，不得继续拥有独立语义；它们不是兼容栈。

CLI 随此次收敛明确采用与 AgentCore 相同的 snapshot 和 activation 语义：调用不再
读取活 source tree；`${CLAUDE_SKILL_DIR}` 指向本次 activation 的 working tree，
其中写入在 terminal 后销毁；materialization 能力不足时该 Skill typed unavailable。
这些是批准的 Revision 4 CLI 迁移，不得通过回退旧 loader/直读路径规避。

CLI adapter 以程序赋值的 `agent_ident` 隔离 execution context；Runtime 管理的 fork
会预注册 child context 并在 terminal 注销。缺少 terminal hook 的其它 child context
不得创建持久 activation，必须 fail-closed，不能退回进程全局 Skill 状态。

### 4.2 Catalog 查询与身份

新增 opaque `metask_agentcore_skill_catalog`：

```c
uint32_t runtime_query_skill_catalog(
    metask_agentcore_runtime *runtime,
    const metask_agentcore_skill_catalog_query_v1 *query,
    metask_agentcore_skill_catalog **out_catalog,
    metask_agentcore_owned_bytes_v1 *out_descriptor_json,
    metask_agentcore_owned_bytes_v1 *out_diagnostic);

uint32_t skill_catalog_release(
    metask_agentcore_skill_catalog *catalog,
    metask_agentcore_owned_bytes_v1 *out_diagnostic);
```

`SkillCatalogQueryV1` 固定 80 bytes：

```text
struct_size@0
reserved0@4
workspace_root@8
workspace_home@24
workspace_epoch@40
reserved[3]@56
```

身份规则：

- `catalog_scope_id` 和 `catalog_revision` 均为 64-byte lowercase hex。
- scope id =
  `HMAC-SHA256(runtime_secret, domain || bundle identity || workspace binding)`；
  同一 Runtime 内稳定，不暴露物理路径。Runtime secret 由 OS CSPRNG 生成，仅驻留
  内存，销毁时清零；生成失败使 `runtime_create` 返回 `CORE_ERROR`。
- revision 是对 scope、workspace epoch 及 canonical effective records 的
  SHA-256。valid Skill 的 body、frontmatter、policy、资源及可执行位进入 hash；
  tombstone 的稳定字段进入 hash；diagnostic 文案不进入 hash。
- `workspace_epoch` 是调用方声明的 opaque byte token，只在同一 canonical Workspace
  scope 内按 byte equality 解释；不要求可解析、单调或跨 Host 可比。canonical empty
  表示没有外部世代。Host 在 Workspace binding 的外部世代变化时更换它；由于它进入
  revision hash，更换后旧 Session 与新 descriptor 组合会产生 `STALE_CATALOG`。
- revision 只允许在同一 Runtime/scope 内做 byte equality，不表示全局顺序。
- 普通 source 的 `invocation_name` 来自 discovery root 的直接子目录名；plugin
  使用稳定 namespace + `:` + 子目录名。frontmatter `name` 只作为
  `display_name`。
- `invocation_name` 匹配
  `^[A-Za-z0-9_][A-Za-z0-9_:-]{0,127}$`。它不是 provider tool name，因此与 B3
  规则不同。
- `skill_id` 是由 canonical `invocation_name` 计算的 64-byte lowercase
  SHA-256 hex，只能在 pinned catalog 内解析。

### 4.3 Catalog 解析与失败域

resolver 按 invocation slot fail-closed：

1. 有界浅枚举各 source 的结构候选，按 `invocation_name` 和 source priority 分组；
2. 每个 slot 只深度验证最高优先级候选；
3. 最高候选有效则发布 Skill；
4. 最高候选损坏、同优先级冲突或资源非法则发布 typed tombstone，不回退同名
   低优先级候选；
5. 非法结构名称产生 non-addressable issue，不获得 `skill_id`；
6. 只有 discovery root、候选集合或 snapshot 完整性无法证明时，整个 query 才失败。

optional root 不存在等价于空 source；已存在但 unreadable/unstable 的 root 不能
静默跳过。被有效高优先级候选遮蔽的低优先级内容不进入 snapshot 或 revision。

descriptor schema 固定为 `metask.skill-catalog/v1`：

```text
catalog_scope_id
catalog_revision
health = healthy | degraded
skills[]
issues[]
```

- `skills[]` 仅含 valid Skill：
  `skill_id`、`invocation_name`、`display_name`、`description`、
  `argument_schema`。
- `issues[]` 包含稳定字段：
  `code = invalid_definition | source_conflict | invalid_resource |
  invalid_invocation_name`、可选 `invocation_name` 和
  `source_scope = enterprise | personal | project | plugin`。
- tombstone 不含 `skill_id`，不可调用。
- descriptor 不含 body、source path、policy、`explicit_only` 或
  `execution_mode`；diagnostic 仅供人阅读。
- 数组按稳定键排序，重复 query 的 descriptor bytes 必须确定性相等。

每个 valid Skill 的 `argument_schema` 固定为：

```json
{
  "schema": "metask.skill-arguments/v1",
  "max_values": 64,
  "names": ["target", "scope"]
}
```

`names[]` 是有序的位置参数提示名，`values[i]` 对应 `names[i]`；它不声明 required
arity。提交允许 `0..max_values` 个值，超出 `names.len` 的值仍是合法位置参数。
消费方按顺序生成参数 UI，但不得把 `names.len` 当成必填数量。

`OK + degraded` 表示 snapshot 完整，但存在隔离的 issue；Session 可以绑定，只暴露
`skills[]`。非 `OK` 才表示没有 snapshot。

### 4.4 Snapshot、遍历与物化

query 只读取、解析并构造 immutable snapshot，不执行 script、shell、
provider 或 tool。执行所需 body/resource/script 必须复制进 snapshot；invocation
不得重新读取 source path。

遍历要求：

- 从 no-follow 的 root handle 开始，使用 handle-relative 枚举和打开；
- symlink、Windows reparse point 及其它特殊文件不得进入 snapshot；
- 已选候选内部错误隔离为该 slot 的 `invalid_resource`；影响 root/候选集合完整性
  的错误使整个 query 返回 `SKILL_CATALOG_INVALID`；
- visited entries、depth、relative path、file count、单文件和总字节在 descent、
  read 或 allocation 前计费；
- snapshot 原子发布，失败时不得返回半个 handle 或部分 descriptor。

每次 activation 在 `beginRun` 成功后，从 immutable snapshot 创建独占 working
tree：

- 不跨 activation、Run、Session 或并发 sibling 共享；
- 使用 Runtime 私有临时根和不可预测目录名；
- working tree 是可变 scratch，不得回写 snapshot；
- 完整写入并复核后才交给执行器；
- 创建、执行和清理受当前 Run abort/quiescence 管理；
- terminal return 前销毁并释放预算。

Runtime 从有界、确定的候选根中选择 materialization 根：先尝试平台首选临时目录，
再尝试不同的 OS-native fallback。每个候选都必须先创建独占私有目录，再探测权限位
语义；失败候选完整删除后才能继续。OOM 与 CSPRNG 失败立即返回，不得伪装成候选不可用；
只有路径或文件系统能力不满足才能尝试下一候选。全部候选失败时，Skill capability
为 typed `SKILL_UNAVAILABLE`，不得因单个错误的 `TMPDIR` 放弃可用的 native temp。

公共上限：

```text
Skill slots                         1024
Catalog descriptor                 4 MiB
Visited entries / depth            65536 / 64
Relative path / files              4096 bytes / 16384
Single file / snapshot             4 MiB / 64 MiB
Runtime live snapshots             256 MiB
Runtime active materializations    256 MiB
scope / revision / skill id        64 bytes
invocation_name                    128 bytes
```

query cap 超限返回 `RESOURCE_LIMIT` 且不发布 handle。active materialization cap 在
创建文件前原子 reserve，但发生于 admitted Run 内。

### 4.5 Handle 与 Session 绑定

Catalog handle immutable、可跨线程只读，由 Host 恰好 release 一次。Session
create/refresh 成功后 retain snapshot，Host 可释放自己的 handle。Runtime 使用
destroying flag、active-call guard 与 refcount；存在 active call、Session ref 或
Host catalog handle 时 `runtime_destroy` 返回 `BUSY`。query 返回 `OK` 时 handle
与 descriptor 必须同时有效，非 `OK` 时二者 canonical empty。

`SessionConfigV1` 在 `allowed_tool_count@104` 后增加：

```text
skill_catalog@112
reserved[4]@120
```

总大小 152 bytes。NULL 表示 Session 只接受 TextInput。非 NULL 时必须验证 catalog
属于同一 Runtime 与同一 canonical Workspace binding。

新增：

```c
uint32_t session_refresh_skill_catalog(
    metask_agentcore_session *session,
    metask_agentcore_skill_catalog *catalog,
    metask_agentcore_owned_bytes_v1 *out_diagnostic);
```

refresh 仅在 idle Session 上允许，并与 run/destroy 使用同一 facade gate。它原子
替换 snapshot、tool exposure、prompt 和 policy lookup；失败保留旧状态。refresh
不修改 Conversation、不产生 events、不影响 run_id，也不自动发生。

`STALE_CATALOG` 是 pre-admission failure，因此不推进 run_id。Host 必须重新 query，
按新 descriptor 重新解析 Skill identity，等待 Session idle 后 refresh，释放自己的
新 catalog handle，再以相同 run_id 和新 revision 重试。只修改 source 文件不会改变
已绑定 snapshot；stale 只表示 RunInput revision 与 Session 当前绑定 revision 不同。

### 4.6 Typed RunInput

Revision 4 以统一入口替换 text-only `session_run`：

```c
uint32_t session_run_input(
    metask_agentcore_session *session,
    uint64_t run_id,
    const metask_agentcore_run_input_v1 *input,
    const metask_agentcore_run_options_v1 *options,
    metask_agentcore_run_result_v1 *out_result,
    metask_agentcore_owned_bytes_v1 *out_diagnostic);
```

`RunInputV1` 固定 104 bytes：

```text
struct_size@0
kind_code@4 = TEXT | SKILL
text@8
skill_id@24
catalog_revision@40
arguments_json@56
reserved[4]@72
```

约束：

- `TEXT=1u`：Skill 字段 canonical empty，text 服从 B4。
- `SKILL=2u`：text canonical empty；Session 已绑定 catalog；skill id 和 revision
  非空。
- 未知 kind 返回 `INVALID_ARGUMENT`。
- wire 没有 `origin`。外部 SKILL input 本身代表 Host 显式调用；模型自主调用只
  发生在 AgentCore 内部路径。

arguments schema 固定为：

```json
{"values":["..."]}
```

canonical empty 表示零参数。只允许唯一顶层键 `values`；
`MAX_SKILL_ARGUMENT_VALUES_V1 = 64`，
`MAX_SKILL_ARGUMENT_JSON_BYTES_V1 = 1 MiB`。AgentCore 是最终校验 owner。

### 4.7 Admission 与执行生命周期

external Skill Run 的固定顺序：

1. 校验 input shape/cap/UTF-8/JSON、当前 catalog revision、Skill、arguments 和
   静态 capability/policy，生成无文件副作用的 immutable `ActivationPlan`；
2. 调用 `beginRun`，线性化 run_id、active state 和 abort；
3. 在 Run abort token 与 aggregate cap 下创建并复核 activation working tree；
4. 取得当前 activation 的 `PolicyFrame`，修改 Conversation 并开始执行；
5. terminal 前等待全部派生执行 quiescent，释放 frame、working tree 和预算。

步骤 1 的失败是 pre-admission failure，不推进 `last_run_id`。步骤 2 后的
materialization 失败属于 admitted Run，推进 `last_run_id`，但步骤 4 前不得修改
Conversation 或 parent policy。

model-tool activation 已位于 admitted parent Run 内；其解析、物化或执行失败沿普通
tool/Run 语义返回，不伪装成 external pre-admission status。

external 与 model-tool 调用必须共用唯一内部入口：

```text
skills.runtime.activate(snapshot, skill_id, arguments, context)
context = external_run_root | model_tool
```

不得复制 loader、renderer、resource resolver、policy 或 inline/fork 路径。

### 4.8 PolicyFrame

```text
base = parent_policy_frame.effective_tools
       if parent_policy_frame exists
       else session_effective_tools

effective = base
if skill.allowed_tools is present:
    effective = effective ∩ skill.allowed_tools
effective = effective - skill.disallowed_tools
```

始终满足：

```text
child_effective ⊆ parent_effective ⊆ session_effective_tools
```

- `allowed_tools` 是上界，不是重新授权请求。
- Host/session deny 永远优先。
- `PolicyFrame` 是 execution-context-local immutable chain，不是 Session 全局
  可变 stack。
- inline、model-tool 和 fork child 都从调用点 current frame 派生。
- 并发 sibling 共享 immutable parent，但各自持有 child frame。
- child 任意 terminal 只释放自己的 frame；Run terminal 等待全部 lineage
  quiescent，下一 Run 从 Session baseline 开始。
- frame 同时持有不可扩大的 shell/permission bounds。
- policy rule 在 frame 构造时完成校验或解析；运行期再次解析失败必须 fail-closed，
  不得使用 `catch unreachable` 把跨函数约定升级成 ReleaseFast UB。

Shell policy：

- `disabled`：不暴露 Bash-family tools；必须执行 shell injection 的 Skill 在
  pre-admission 返回 `SKILL_POLICY_VIOLATION`。
- `sandboxed`：工具与 Skill injection 共用通过 A4 canary 的 sandbox executor，
  强制 fail-closed。
- `unrestricted`：才允许无 sandbox 执行。

`PolicyFrame` 由 Skill Runtime 持有并通过既有 type-erased
`ToolExecutionPolicy` 投影给执行 adapter。通用 agent loop 不拥有或解释
`PolicyFrame`，也不得为 Skill 新增状态字段。

### 4.9 Fork、事件与 Conversation 投影

fork 是当前 ABI Run 内部执行，不分配第二个 Host run_id，不建立第二套 status、
result、poison 或 catalog binding。它继承 parent frame、abort 和串行 event sink；
外层 Run 必须等待全部 child quiescent。

事件投影与真实 `agent_depth` 正交：

- external top-level fork 使用 run-root projection，公开 child 的文本、
  `stream_done`、工具事件和 usage；
- model-tool fork 公开文本、`stream_done` 和 usage，但抑制内部工具边界，由外层
  Skill 的 public `tool_start/tool_result` 包围；
- callback failure、abort、core failure 和 usage 均归属外层 Run；
- Run terminal 后不得出现迟到事件或 usage。
- fork child 不支持可恢复 UI suspend；其执行 adapter 不提供 UI requester。
  child 内的提问或权限请求 fail-closed，并作为普通 fork/tool 失败归属外层 Run。

不得通过伪造 `agent_depth=0` 实现投影。ABI semantic events 必须与 UI card
显示开关解耦。

Conversation 投影：

- external inline：append canonical invocation user record，再 append rendered
  body，随后进入普通 agent loop；
- external fork：append canonical invocation record，不导入 child body 或
  Conversation；成功后只提交按 A1 重建的非空最终 assistant 文本；
- model-tool：由既有 tool_use/tool_result 表达，不额外 append invocation record。

## 5. ABI 布局与状态

### 5.1 Table

统一 cut 的 Revision 4 `ApiV1` 固定 136 bytes，函数顺序为：

```text
runtime_create
runtime_destroy
runtime_query_skill_catalog
skill_catalog_release
session_create
session_destroy
session_refresh_skill_catalog
session_run_input
session_abort
buffer_release
reserved[4]
```

关键布局：`SkillCatalogQueryV1=80`、`RunInputV1=104`、
`SessionConfigV1=152`、`ApiV1=136` bytes。

新增 required capabilities：

```text
CAP_SKILL_CATALOG = 1ULL << 6
CAP_TYPED_RUN_INPUT = 1ULL << 7
```

capability 仅在 version、revision、size 和 table identity 校验通过后读取，不用于跨
revision 协商。

### 5.2 Skill 状态

新增：

```text
SKILL_CATALOG_INVALID   = 11u
STALE_CATALOG           = 12u
SKILL_NOT_FOUND         = 13u
INVALID_SKILL_ARGUMENTS = 14u
SKILL_POLICY_VIOLATION  = 15u
SKILL_UNAVAILABLE       = 16u
```

| 条件 | status | 是否推进 run_id |
|---|---|---|
| 单 slot 损坏/冲突/资源非法 | query `OK + degraded` | 不适用 |
| catalog 候选集合或 snapshot 不完整 | `SKILL_CATALOG_INVALID` | 否 |
| 当前 Session 未绑定 catalog | `INVALID_STATE` | 否 |
| revision 非 canonical | `INVALID_ARGUMENT` | 否 |
| revision 与当前绑定不等 | `STALE_CATALOG` | 否 |
| 当前 snapshot 无 skill id | `SKILL_NOT_FOUND` | 否 |
| arguments 非法 | `INVALID_SKILL_ARGUMENTS` | 否 |
| 静态 policy 违规 | `SKILL_POLICY_VIOLATION` | 否 |
| 静态执行能力缺失 | `SKILL_UNAVAILABLE` | 否 |
| admitted materialization cap 超限 | `RESOURCE_LIMIT` | 是 |
| admitted materialization I/O/复核失败 | `CORE_ERROR` | 是 |
| materialization 期间 abort | `OK + ABORTED` | 是 |

`OUT_OF_MEMORY` 优先于业务映射；实现 bug 使用 `INTERNAL_ERROR`。diagnostic 始终是
不稳定的人类文本，机器只按 status 和 typed descriptor 分支。

## 6. 实施与验收

### 6.1 原子 cut

Revision 4 公共 ABI 已完成原子 cut；内部纠偏不得改变已发布的 layout、status、
ownership 或 failure boundary。收敛顺序固定为：

1. 在 `src/skills/runtime/` 定义 adapter-neutral 类型与边界测试；
2. 将现有 AgentCore catalog、materialization、policy、activation 的通用语义迁入
   Runtime，不改变行为；
3. AgentCore 改为 ABI adapter，保留 handle/admission/event 等 ABI 所有权；
4. 在 `src/skills/cli_adapter.zig` 收敛 CLI discovery、slash 与 model-tool
   适配，产品调用点只委托给该 adapter；
5. 删除两侧重复实现；迁移期间可以短暂共存，但任何可交付状态不得保留两套语义；
6. 逐条用 Runtime 测试和 CLI/AgentCore adapter 测试替换旧测试。

本节所有“新增 diff”均以
`d3cf66634982c0ac780112fb8732602349d4fb89` 为固定收敛基线，不随分支 HEAD 漂移。

公共表面只切换一次。任何中间提交不得发布可被消费的 Revision 4 header 或 bundle。

若在任何 Revision 4 公共产物发布或被消费者 pin 之前，S1 存在需要返工且会阻塞
A/B 关闭的设计缺陷，可经 MetaWork 确认拆分为：

- Revision 4：A1/A3/A4、B1–B4；
- Revision 5：S1。

拆分后必须重新批准两个 revision 的 table、struct、caps、manifest、baseline 和
测试；本文的 136/152-byte 数字不再自动适用。发布或 pin 后不得拆分、复用 revision
号或原地改布局。

### 6.2 验收矩阵

| 层 | 必须证明 |
|---|---|
| ABI/layout | C/Zig/Rust 的 80/104/152/136-byte 布局、offset、status、capability、cap parity；Revision 3/4 和错误 size 双向 fail-closed；descriptor 先限长再解码 |
| A1 | 普通结束、ABORTED、continuation、工具后 continuation、自动压缩、top-level fork、两类 event projection；流式/非流式 usage 恰好计量 |
| A3/A4 | Host-owned 零权限配置写入、无跨 Session 泄漏、不读 fd 0、CLI 行为保持；sandbox 全部 admission/运行期漂移分支 |
| B1–B4 | single/multi/free-text、取消及 release；schema/name 边界；prompt cap-before-UTF-8 |
| Catalog | Session 前查询、priority、identity/revision、argument schema、workspace epoch、healthy/degraded、slot tombstone、无同名回退、全局/局部失败域、遍历与资源 caps |
| Lifecycle | immutable snapshot、per-activation working tree、Runtime aggregate caps、首选 temp 不适用时选择 native fallback；强制覆盖 final release 与 destroy 的两种竞争顺序，结果只能符合规定的成功或 `BUSY`，且无 UAF |
| Run/policy | pre-admission 不改 Conversation/不推进 run_id；在 working-tree reserve、create/write、final verification 三处逐点注入失败，均推进 run_id、完整清理且不污染 parent frame；三层 policy 收窄、并发 sibling 隔离、非法 rule fail-closed、所有 terminal 精确恢复 |
| Fork | inline/fork 共用 events、usage、abort、RunResult；run-root/model-tool 投影正确，无迟到事件，fork UI 请求 fail-closed |
| 单一路径 | TextInput 行为不变；external/model-tool 只经过一套 activation kernel；同一 roots/scope/epoch fixture 在 CLI 与 AgentCore 产生相同 records、issues、revision、activation plan、policy 与 materialized tree |
| 模块边界 | `skills/runtime` 不 import AgentCore 或产品层；AgentCore 目录不保留第二份 catalog/materialization/policy/activation 语义；相对固定基线，全部 changed paths 命中 allowlist，受限文件仅含批准的 adapter/注册改动 |
| 消费闭环 | `/skill → MetaWork route → tasks.run → session_run_input(SKILL)`；TextInput 的 `/xxx` 仍是普通文本；valid/tombstone/unknown 三种结果互不退化；`STALE_CATALOG` query/refresh/同 run_id 重试 |

定向门禁为 `zig build test:skill-runtime` 与 `zig build agentcore:test`。旧测试替代关系：
loader/catalog → Runtime catalog + CLI projection；model tool/slash → shared model semantics
+ adapter L2；active policy/pool filter → `PolicyFrame` + projection tests。

### 6.3 实施护栏

1. Revision 4 的 header、SDK、manifest、protocol schema 与 canonical ABI 文档不得
   残留 `allow_always` 或 `deny_tool_session`；合入前机械扫描。
2. AgentCore public header、SDK、manifest 与 wire schema 不得暴露 slash/Command
   API、route 字段或具体 Skill 名称特判；MetaWork/CLI 产品路由不在该禁区。
3. 批准前必须关闭影响 public contract 的事实调查；实施不得自行决定或改变
   layout、映射、ownership、failure boundary 与 event projection。
4. CLI 明确批准 invocation identity、degraded catalog、snapshot-bound source、
   per-activation working tree 与 typed unavailable 迁移；除此之外行为不得改变。
   未被替换的存量测试必须全绿，每条删除的旧测试必须指名对应的新语义测试。
5. 不得以清理旧字段、统一 App/Session 或消除所有 Skill 名称为由修改通用底层。
   底层遗留适配点的物理删除另立任务，不阻塞 Revision 4 的单一语义 Runtime。
6. 修改范围采用 allowlist，未列出的路径相对固定基线一律零 diff：
   - 允许：`src/skills/**`、`src/agentcore/**`、`tests/**`、`doc/**`；
   - 受限：`src/app.zig` 仅允许 Runtime/adapter 初始化与接线；
     `src/repl/loop.zig` 仅允许 import `skills/cli_adapter.zig`、委托 slash 调用并删除
     旧 `handleSkillInvocation`；`src/main.zig`、`src/lib.zig` 与 `build.zig` 仅允许
     Runtime/测试模块注册；`sdk/metask/agentcore.h` 仅允许消费合同注释；
   - 因而 `src/core/agent_loop.zig`、`src/core/agent_session.zig`、
     `src/core/conversation.zig`、`src/core/tool_exec.zig`、
     `src/core/subagent.zig`、`src/tools/context.zig`、`src/tools/ask_user.zig`、
     `src/api/**`、`src/permission.zig`、`src/permission/**` 及其余
     `src/repl/**` 均禁止修改。
   任何新解析、catalog、policy、materialization 或执行语义必须位于共享 Runtime
   或 CLI adapter。若实现证据表明必须修改 allowlist 外路径，应停止实施，先更新
   本文、说明缺失的通用接口和最小操作范围并重新评审，不得现场扩权。

完成条件：矩阵全绿，双平台 baseline 更新，canonical ABI 文档、header、SDK、
manifest、ledger 与实现一致；MetaWork 无需读取 Skill body、复制 loader 或解析
diagnostic，即可完成 Command + Skill slash 路由。
