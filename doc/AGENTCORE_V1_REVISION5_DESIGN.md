# AgentCore ABI v1 Revision 5 范围设计

> 状态：Implemented；公共语义与 Revision 5 wire layout 已冻结
> 日期：2026-07-31
> 前置：`AGENTCORE_V1_REVISION4_DESIGN.md`、`AGENTCORE_BINARY_ABI.md`

## 0. 范围决定

Revision 5 补齐 AgentCore 对长生命周期 Session 的受控操作边界：

1. Session 默认模型切换；
2. Host 主动触发 Conversation compact；
3. Session Skill availability 更新；
4. Host-owned permission rules 导入与更新。

版本仍以精确二元组定位：

```text
(abi_version = 1, abi_revision = 5)
```

Revision 4 与 Revision 5 的 API table、结构大小和 revision 必须精确匹配，不支持混用。

消费方反馈只用于暴露公共能力缺口和形成验收场景，不作为 ABI 演进依据。能力进入
Revision 5 的依据是：

- 状态属于 AgentCore/Core；
- Core 能形成唯一 canonical 语义；
- 所有权、并发、提交和失败行为可以稳定承诺；
- Host 确实需要跨二进制边界调用。

## 1. 架构原则与 Revision 4 审计

### 1.1 Core 先于 ABI

每项能力进入 wire ABI 前必须满足：

1. Core 内部只有一套 canonical 实现；
2. CLI、Web 和 AgentCore 只保留适配逻辑；
3. 输入所有权、活动互斥、提交点、回滚和取消语义完整；
4. L2 覆盖声明到执行的端到端行为；
5. artifact consumer 能从发布归档验证公共契约。

如果能力仍只存在于产品层，或 Core 内仍有多套不一致实现，不得由 AgentCore adapter
临时补出第二套语义。

### 1.2 最小公共投影

Revision 5 不增加：

- `query_interface`；
- 独立 interface revision；
- `ExecutionTarget`；
- 通用 `Activity`、`Operation` 或 policy handle；
- 为假想未来准备的空 DTO。

函数集合和公共行为在本文确定；exact C signature、字段宽度、结构大小、数量上限和
API table layout 在 Core seam 与 L2 完成后冻结。

### 1.3 Host 与 AgentCore 边界

Host 负责：

- slash、按钮和产品 UI；
- 设置与 permission rules 持久化；
- Skill 管理中心状态持久化；
- 产品默认值和配置同步。

AgentCore：

- 不解析 slash command；
- 不读取或写入消费方配置；
- 不输出产品 UI；
- 不隐式读取 fd 0；
- 只执行 Host 通过 ABI 明确请求的 Session 操作。

### 1.4 Revision 4 暴露审计

| 领域 | Revision 4 状态 | Revision 5 判断 |
|---|---|---|
| Session model | `SessionConfigV1` 创建时固定 | 缺少 Core Session model mutation |
| Conversation | 跨成功 Run 保留 | 已具备 Session 级所有权 |
| compact | agent loop、Conversation、产品层存在多条路径 | 先收敛 `CompactKernel`，再公开 |
| Skill catalog | Runtime 可查询 immutable snapshot | 已具备发现能力 |
| Skill availability | 只有 catalog refresh | 缺少统一 selection enforcement |
| permission response | `allow_once/allow_session/deny_once/deny_session` | 只有 Session 临时记忆 |
| permission rules | Core 已有 canonical parser/evaluator | 缺少 Host rules 导入通道 |
| permission persistence | AgentCore facade 为 Host-owned | 继续由 Host 负责 |
| Full access | 无统一安全语义 | 不进入 Revision 5 |

Revision 4 引入了跨 Agent 中立的 `.agents/skills` discovery root。Revision 5 将
AgentCore 默认 discovery policy 收紧为只读取 personal/project `.agents/skills`；
`.claude/skills`、`.metacodes/skills` 与 enterprise roots 属于产品 adapter policy，
不是 AgentCore 默认文件系统权限。该修正不增加 wire 能力。

## 2. 统一 Session 语义

### 2.1 活动互斥

```text
Session idle
  ├─ Run
  ├─ set_model
  ├─ compact
  ├─ update_skills
  └─ update_permission_rules
```

任意时刻只允许一个活动：

- active Run 期间，四种 Session 变更均返回 `BUSY`；
- compact 或其它 mutation 期间，Run、其它 mutation 和 destroy 返回 `BUSY`；
- poisoned Session 不允许恢复性 mutation；
- destroy 与所有活动互斥。

内部可以复用 Session mutation gate，但不把该抽象暴露成公共 Activity 框架。

matching abort 是唯一的并发例外：`session_abort` 只可与其标识的 active Run 并发，
`session_abort_compact` 只可与其标识的 active compact 并发。它们不获得与
其它 Session 调用并发的额外权利。Host 必须等待所有 abort 调用返回后，才能在同一
handle 上发起任何后续调用，包括新的 Run、compact、mutation 或 destroy；destroy 返回
`OK` 后 handle 立即失效，后续任何调用均属于 Host 错误。Revision 5 只保证有效 handle
上符合上述时序的调用安全，不承诺已销毁或可能在调用返回前被销毁的裸指针仍可使用。

### 2.2 Run 固定读取视图

Run admission 成功时固定读取：

- provider/model；
- Skill catalog 与 selection；
- Host-owned permission rules；
- 工具、workspace 和 permission bounds。

active Run 不观察中途变更。Revision 5 不支持对 active Run 热切换 model、Skill 或
permission rules。

### 2.3 原子提交

所有 Session mutation 必须满足：

1. 参数和资源先校验；
2. 新状态先完整构造；
3. 只有成功路径才在单一提交点替换旧状态；
4. 非 `OK` 返回时旧状态继续有效；
5. 可恢复失败不得 poison Session。

model、Skill 和 permission rules mutation 不修改 Conversation。只有 compact 可以提交
Conversation 维护结果。

### 2.4 身份空间

- `run_id` 只标识 Run；
- model、Skill 和 permission rules mutation 是同步本地提交，不需要 ID；
- manual compact 包含 provider I/O，使用独立 `operation_id`；
- compact 不推进或占用 `run_id`；
- `operation_id` 不泛化为公共通用 Operation 模型。

## 3. Session 默认模型切换

### 3.1 公共函数

Revision 5 增加 `session_set_model`。exact wire signature 后续冻结，其语义参数为：

```text
session_set_model(session, model, diagnostic)
```

### 3.2 公共语义

- 仅允许 Session idle 时调用；
- `model` 必须非空、合法 UTF-8，并受 metadata 上限约束；
- AgentCore 在调用期间复制输入，不保留 Host borrowed pointer；
- 只修改 model；
- provider kind、API key、base URL、workspace、工具、权限和 Skill 状态保持不变；
- Session handle、Session ID、Conversation 和最后 admitted `run_id` 保持不变；
- 成功后，下一个 admitted Run 使用新模型；
- 相同 model 返回 `OK`，视为幂等 no-op。

`OK` 只表示本地 effective model state 已成功切换，不表示远端 provider 已确认模型存在。
AgentCore 不在 `session_set_model` 中发起探测请求。

不存在、无权访问或拼写错误的模型由下一 Run 的 provider 判定：

```text
session_set_model("invalid-model") -> OK
next Run -> STOP_API_ERROR
Session remains usable
session_set_model("valid-model") -> OK
later Run may continue
```

`STOP_API_ERROR` 不 poison Session。

### 3.3 Core 门槛

Core 必须提供不依赖 `App` 的 `AgentSession.setModel` seam，并保证：

- 新 effective model/provider state 在提交前完整构造；
- 构造失败完整回滚；
- 成功后原子替换旧状态；
- 旧 owned state 只在无读者后释放；
- 不触碰 Conversation 和 Run identity。

Revision 5 不包含 provider、API key、base URL 切换，不包含 per-Run model override，也不
隐式执行“换模型 + compact”复合事务。

## 4. Host 主动 compact

### 4.1 公共函数

Revision 5 增加：

```text
session_compact(session, operation_id, result, diagnostic)
session_abort_compact(session, operation_id, diagnostic)
```

函数集合已经确定。只有当共享 `CompactKernel` 证明存在 Host 必须控制的稳定策略输入
时，wire freeze 才可以为 `session_compact` 增加 options；不得发布空 options DTO，也
不得直接暴露现有实现参数。

Host 可以通过 slash、按钮或自己的策略调用 compact；AgentCore 不感知触发来源。

Revision 5 的 manual compact 执行 canonical 默认策略，是 best-effort Conversation
维护操作。它不接收 Host 指定的目标 token budget，也不保证结果能够装入某个当前或未来
模型的上下文窗口。`session_set_model` 与 `session_compact` 是两个独立 primitive；Host
可以自行安排顺序，但 Revision 5 不定义复合事务或目标模型适配承诺。只有真实消费证据
证明 Host 必须控制某个稳定策略输入，且 Core 已形成 canonical 语义后，才讨论新的 wire
输入。

### 4.2 结果与 usage

`CompactResult` 的 exact wire shape 后续冻结，但必须表达：

- terminal outcome：compacted、no-change、degraded 或 aborted；
- compact 前后的有效上下文规模；
- 本次 provider usage delta。

`degraded` 表示 Core 使用了有损但合法的 fallback，不冻结具体摘要或裁剪算法。
Revision 5 不提供结构化 degrade reason；不得从 diagnostic 文案反推原因。未来若 Core
形成稳定的 reason taxonomy，必须通过新的 ABI revision 显式投影，不能在 Revision 5
中把 reserved storage 重新解释成新字段。

compact 前后的 token 规模是用于上下文状态展示和策略判断的估算值，不是 provider
账单或计费凭据。四项 provider usage delta 与这两个估算值语义独立；消费方不得用
`before_context_tokens` 或 `after_context_tokens` 对账计费。

manual compact 不伪造 `RunContext`，也不借用 `run_id` 发事件。它产生的 provider usage
通过 `CompactResult` 返回。

Run 内 auto compact 继续通过所属 Run 的 usage 与 `auto_compact` event 观察，但必须与
manual compact 共用同一个 Core kernel。

非 `OK` 返回不得提交 Conversation。被接受的 abort 使 `session_compact` 以
`OK + outcome=aborted` 结束，不提交 Conversation。

### 4.3 operation admission

`operation_id` 由 Host 分配，非零，并在 Session compact 身份空间内严格递增：

- `session_compact(id == 0)`：`INVALID_ARGUMENT`；
- `session_compact(id <= last_admitted_compact_id)`：`STATUS_STALE_COMPACT`；
- pre-admission 参数、状态或资源失败不消费 ID；
- admission 成功后立即消费 ID；
- admission 后的 no-change、provider failure、degraded fallback 和 abort 均不得复用 ID。

任意成功 admission 的 compact，在同步 `session_compact` 调用返回时均达到 terminal
状态，无论结果是 compacted、no-change、degraded、aborted、provider failure
或其它 post-admission failure。terminal 不表示成功提交 Conversation。
`last_terminal_id` 指最近一个达到该状态的 admitted operation ID，不论公共返回状态
是否为 `OK`。

`session_abort_compact(id == 0)` 始终返回 `INVALID_ARGUMENT`。其余 abort 语义按
Session 状态互斥判定：

| Session 状态 | ID 关系 | 结果 |
|---|---|---|
| compact active | `id == active_id` | `OK`，请求取消 |
| compact active | `id < active_id` | `STATUS_STALE_COMPACT` |
| compact active | `id > active_id` | `INVALID_ARGUMENT` |
| idle，存在 terminal compact | `id == last_terminal_id` | `TOO_LATE` |
| idle，存在 terminal compact | `id < last_terminal_id` | `STATUS_STALE_COMPACT` |
| idle，无 terminal compact，或 `id > last_terminal_id` | `INVALID_ARGUMENT` |

不得复用 `STALE_RUN` 表达 compact 身份错误。

### 4.4 取消与 liveness

`session_abort_compact` 必须向 in-flight provider I/O 传播取消：

- abort 不得只等待下一次自然网络读取；
- 不得依赖 provider 响应或 TCP timeout；
- abort 生效时间必须有界；
- compact 结束后 Session 回到 idle，随后 destroy 可以成功。

具体 wall-clock 数字不是 ABI 语义。L2 使用 5 秒作为过载环境下的测试上限。

### 4.5 CompactKernel 门槛

以下路径必须共用 `CompactKernel`：

- Run 内 auto compact；
- Host manual compact；
- CLI/Web 产品适配。

Kernel 负责：

- 构造稳定 Conversation snapshot；
- 保持 tool use/result 结构合法；
- 执行默认 compact 与安全 fallback；
- 统计 provider usage；
- 使用可主动中断的 provider 请求；
- 生成中立 report；
- 在单一提交点替换有效 Conversation 状态；
- 非成功返回零提交。

现有不接收 `AbortSignal` 的非流式 provider `sendFn` 必须改造，或 CompactKernel 必须改走
等价的可中断 provider 路径。

## 5. Skill availability

### 5.1 Catalog 与 selection

```text
SkillCatalog
  = Workspace 中被发现、校验并进入 immutable snapshot 的全部 Skill

SkillSelection
  = 当前 Session 对该 catalog 的可用状态
```

Catalog 回答“有什么”，selection 回答“当前 Session 能用什么”。disabled Skill 必须继续
出现在 catalog descriptor 中，供管理中心展示。

### 5.2 Selection 公共语义

exact wire shape 后续冻结。canonical selection 必须表达：

- 新发现 Skill 的默认状态；
- 当前 catalog Skill ID 的例外状态。

无论采用何种 wire 表示，都必须：

- 对重复、冲突和 foreign Skill ID fail-fast；
- 明确定义新发现 Skill 的默认状态；
- 由 Host 持久化；
- 由 AgentCore 持有 immutable effective selection。

Revision 5 不增加 Skill policy/binding handle 或 binding revision。已有 `catalog_revision`
继续用于 catalog stale；typed invocation 仍须由 Session 当前 selection 再校验。

### 5.3 创建与更新

`SessionConfigV1` 的初始 Skill binding 必须成对出现：

- catalog 与 selection 都为空：Session 不绑定 Skill catalog；
- catalog 与 selection 都非空：selection 针对该 catalog 校验后共同绑定；
- 只提供其中一个：`INVALID_ARGUMENT`。

不存在隐式的 initial selection；Host 必须明确提交默认状态和 exceptions。

Revision 5 以 `session_update_skills` 替代 Revision 4 只刷新 catalog 的语义：

```text
session_update_skills(session, optional_catalog, selection, diagnostic)
```

`selection` 必选，不支持 catalog-only 更新。

- `optional_catalog == null`：保留当前 catalog，不触发 discovery 或文件系统扫描；
- 当前没有 catalog 时传 null：`INVALID_STATE`；
- `optional_catalog != null`：传入 catalog 是 target catalog；
- selection 始终针对 target catalog 校验；
- selection-only 更新只替换 selection；
- 联合更新共同校验、共同构造、一次提交；
- 非 `OK` 返回时旧 catalog/selection 组合保持不变。

### 5.4 Disabled 语义

disabled Skill：

- 保留在 catalog descriptor；
- 不进入模型可见 Skill surface；
- typed invocation 返回 `SKILL_POLICY_VIOLATION`；
- explicit invocation 和 nested activation 不得绕过；
- Revision 5 AgentCore 不公开或隐式执行 preload；Session create/update 只绑定
  catalog/selection，不 materialize Skill；
- model 猜测名称不得触发 materialization；
- 不创建 activation working tree；
- 不执行 Skill script、tool 或 provider 行为。

检查必须发生在 materialization 和 Conversation mutation 之前。

`disable-model-invocation` 是 Skill 定义自身的调用面限制，不等于 Host 管理中心的
disabled。

### 5.5 Core 门槛

共享 Skill Runtime 必须提供 canonical availability enforcement：

- snapshot 保留全部 valid records；
- selection 在 Session/Run admission 时固定；
- model surface、typed invocation 和 nested activation 共用同一判断；
- Revision 5 AgentCore 不存在 preload 入口；未来若引入，必须先进入同一 canonical
  availability enforcement；
- CLI 和 AgentCore 只做类型、所有权与错误映射。

## 6. Host-owned permission rules

### 6.1 能力边界

Revision 4 已确定 AgentCore 使用 Host-owned permission persistence，但缺少规则回注
通道。Revision 5 增加：

> Host-owned permission rules 的导入与 Session 原子更新。

AgentCore 负责 canonical 规则校验与执行，Host 继续负责持久化。

### 6.2 公共函数与规则集

规则集直接投影 Core canonical 三数组：

```text
PermissionRuleSet {
    allow[]
    ask[]
    deny[]
}
```

每个元素使用现有 `Tool(specifier)` 语法。exact layout、数量上限和字节上限后续冻结。

`SessionConfigV1` 接受 optional initial rule set。Revision 5 增加：

```text
session_update_permission_rules(session, rules, diagnostic)
```

rules 在 Session 创建或 idle update 时完成限长、UTF-8、语法和资源校验。AgentCore
复制并编译规则，不保留 Host borrowed pointer。

### 6.3 `Allow always` 产品流程

公共 permission response 保持：

```text
allow_once | allow_session | deny_once | deny_session
```

不新增 `allow_always` response。Host 提供该产品动作：

```text
user selects Allow always
  -> Host persists a canonical rule
  -> current permission callback returns allow_session
  -> after current Run, Host updates Session rules while idle
  -> later Sessions import persisted rules through SessionConfig
```

Revision 4 可以由 Host 自行持久化和匹配；Revision 5 使规则由 AgentCore canonical matcher
统一执行。

### 6.4 优先级与更新

rules update 保留现有 `allow_session/deny_session` 临时记忆。

公共可观察优先级固定为 deny-wins：

| Session 临时记忆 | imported allow | imported deny |
|---|---|---|
| `allow_session` | allow | deny |
| `deny_session` | deny | deny |

对 imported `ask`：

- 已有 `allow_session`：allow；
- 已有 `deny_session`：deny；
- 没有临时记忆：发起 permission callback。

imported deny 不得被临时 allow 绕过，临时 deny 也不得被 imported allow 绕过。
protected paths 等 Core 强制安全边界不因 imported 或临时 allow 失效。

active Run 固定使用 admission 时的 rules。更新成功后下一 Run 使用新 rules；非 `OK`
返回时旧 rules 继续有效；empty rules 恢复无 imported rules 的行为。

imported rules 与 Session 临时记忆必须进入同一条 Core decision chain。AgentCore adapter
只允许做 wire、所有权和错误映射，不得自行匹配 permission rules。

### 6.5 最小范围

Revision 5 不增加：

- AgentCore settings loader/writer；
- rule revision 或 policy generation；
- workspace/global/organization scope 对象；
- suggested-rule 生成系统；
- matched-rule identity、decision trace 或通用 permission provenance；
- 审计数据库。

规则命中来源若进入后续 ABI，必须先由 Core decision chain 形成覆盖 imported rules、
Session 临时记忆、protected paths、permission mode 与 Skill policy 的统一结构化结果；
AgentCore adapter 不得依据当前三数组索引临时拼出第二套来源语义。

## 7. Revision 5 API surface

Revision 5 仍是一张精确的 `ApiV1` table。函数集合确定为：

| 函数 | Revision 5 处理 |
|---|---|
| `runtime_create/destroy` | 保留 |
| `runtime_query_skill_catalog` | 保留 |
| `skill_catalog_release` | 保留 |
| `session_create/destroy` | 更新 `SessionConfigV1` |
| `session_set_model` | 新增 |
| `session_update_skills` | 新增，替换 catalog-only refresh 语义 |
| `session_update_permission_rules` | 新增 |
| `session_run_input` | 保留 |
| `session_abort` | 保留，仅取消 Run |
| `session_compact` | 新增 |
| `session_abort_compact` | 新增 |
| `buffer_release` | 保留 |

不通过扩展表或字符串 ID 发现这些函数。

### 7.1 冻结的 wire contract

Revision 5 是 hard cut，不包含 Revision 4 table、layout、capability set、旧函数入口或兼容分派。
精确发现元组为：

```text
abi_version   = 1
abi_revision  = 5
ApiV1 size    = 168
capabilities  = 0x0fff
```

消费者必须同时精确匹配四项；capabilities 不是“至少包含”关系。`ApiV1` 在 24-byte
发现前缀之后按下列顺序包含函数指针：

```text
runtime_create
runtime_destroy
runtime_query_skill_catalog
skill_catalog_release
session_create
session_destroy
session_set_model
session_update_skills
session_update_permission_rules
session_run_input
session_abort
session_compact
session_abort_compact
buffer_release
```

Revision 4 的 `session_refresh_skill_catalog` 不存在于 Revision 5 table。

新增或变更 DTO 冻结为：

| DTO | size | 字段 |
|---|---:|---|
| `SessionConfigV1` | 168 | 既有字段 + optional `skill_catalog`、optional `skill_selection`、optional `permission_rules` |
| `SkillSelectionV1` | 56 | `default_state_code` + `exception_skill_ids[]`；例外 ID 使用默认状态的反向状态 |
| `PermissionRuleSetV1` | 88 | borrowed `allow[]`、`ask[]`、`deny[]` |
| `CompactResultV1` | 88 | outcome、compact 前后 token 规模、四项 provider usage delta |

`session_compact` 不接收 options。compact outcome 固定为 `compacted/no_change/degraded/aborted`；
新增独立状态 `STATUS_STALE_COMPACT = 17`。Skill exception 数量上限为 1024；permission
rules 总数上限为 1024，单条 64 KiB，总字节数 1 MiB。所有 `struct_size` 必须精确相等，
reserved 字段必须为零，输入在解引用前先限长。C、Zig、Rust binding 与 manifest 使用同一组
精确值；manifest 同时记录 revision、table size 与 capability set。

reserved storage 只保留布局空间，不是 Revision 5 内的扩展协议。任何 reserved 字段的
新解释、非零值或新增可观察语义都必须切换 ABI revision。

## 8. 明确非目标

### 8.1 已由 Revision 4 处理

- `.agents/skills` discovery root；
- Skill catalog query 与 immutable snapshot；
- Session 内 `allow_session/deny_session`。

### 8.2 AgentCore-owned persistence

Revision 5 不让 AgentCore：

- 选择产品配置路径；
- 写入、删除或迁移设置；
- 管理跨设备同步；
- 定义产品级 global/project/organization scope；
- 通过单个 response 在无 Host 参与时跨 Session 持久授权。

### 8.3 Full access

Full access 可能同时影响工具、permission mode、sandbox、workspace、protected paths、
网络和 Host tool。在这些轴没有统一安全语义前，不定义 `full_access` 布尔值，也不把
bypass、unrestricted shell 或 allowed tools 拼成公共承诺。

### 8.4 其它非目标

- slash parser、Command Registry 和命令补全；
- Session persistence/restore；
- provider、credential、base URL 动态切换；
- per-Run model override；
- Conversation 导出；
- Skill 安装、卸载和文件写入；
- Skill 管理中心 UI；
- 通用 extension/versioning framework；
- 通用异步 Operation API。
- Host 指定目标 token budget 的 compact，以及“适配目标模型窗口”的结果保证；
- 结构化 permission decision provenance 与 compact degrade reason。

## 9. 冻结门槛

以下是 public semantics 到验证证据的最小映射，不重复定义前文章节的语义。

| 能力 | 必须通过的证据 |
|---|---|
| model switch | idle/BUSY；owned state 无 UAF；构造失败回滚；下一 Run 使用新 model |
| model state preservation | Conversation、compact boundary、last run ID、Skill binding、imported rules 和 Session 临时权限记忆保持不变 |
| invalid model recovery | 下一 Run `STOP_API_ERROR`；Session 不 poison；切回后继续成功 Run |
| compact admission | zero/future/stale/too-late 及 active/idle 互斥矩阵；pre-admission 不消费；admitted terminal 均消费 |
| compact atomicity | tool pair 合法；非 `OK` 零提交；degraded/no-change/aborted 结果明确 |
| compact liveness | provider 永不响应时 abort 主动中断；测试上限 5 秒；之后 destroy 成功 |
| abort lifecycle | matching abort 只与对应 Run/compact 并发；任何后续调用等待 abort 返回；Core provider snapshot 与 cancel borrow 在同一 admission gate 下；destroy 成功后 handle 失效 |
| compact accounting | manual/auto 共用 kernel；provider usage 恰好计入一次；不消费 `run_id` |
| Skill selection-only | 不要求 catalog handle；不 discovery；对当前 target catalog 校验 |
| Skill joint update | invalid/duplicate/foreign ID fail-fast；失败保留旧组合 |
| Skill enforcement | model、typed、nested 共用判断；Session create/update 不 materialize；Revision 5 无 preload 入口 |
| permission rules | owned parse/compile；create/update 共用 seam；失败保留旧 rules |
| permission precedence | deny-wins 四格矩阵；imported ask 三种结果；protected paths 不被绕过 |
| Run fixed view | active Run 不观察 model、Skill 或 permission rules 中途变化 |

ABI 冻结还必须满足：

- `abi_revision == 5` 精确校验；
- C/Zig layout static assertions；
- reserved 字段必须为零；
- 所有输入先限长再解引用；
- owned/borrowed 规则与测试一致；
- Revision 4 consumer 拒绝 Revision 5 bundle，反向亦然；
- artifact consumer 从发布归档验证四项新增能力。

## 附录 A：消费反馈与验收映射（非规范性）

| 反馈场景 | 暴露的边界缺口 | 验收映射 |
|---|---|---|
| 对话后执行 `/model` | Session model 创建后不可变 | Conversation 保留，后续 Run 使用新 model |
| Host `/compact` 或按钮 | 无 UI-neutral manual compact | Host 直接调用 compact primitive |
| 切换到更小上下文窗口的模型 | 是否需要 Host 指定目标预算尚未形成 canonical 公共语义 | R5 仅提供独立 model/default compact primitive，不承诺适配；由真实消费证据决定后续演进 |
| Skill 管理中心拨开关 | catalog 与 availability 未分离 | selection-only 更新且全入口一致生效 |
| 跨 Session `Allow always` | Host rules 无正式导入通道 | Host 持久化，AgentCore 校验和执行 |
| Full access | 无统一 capability 语义 | 不以单个布尔字段进入 ABI |
