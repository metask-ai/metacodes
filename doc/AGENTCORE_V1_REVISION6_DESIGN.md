# AgentCore ABI v1 Revision 6 设计与冻结记录

> 状态：Implemented；canonical 语义、Revision 6 wire 与交付门已闭合
> 日期：2026-08-03
> 前置：`AGENTCORE_BINARY_ABI.md`、`AGENTCORE_V1_REVISION5_DESIGN.md`
> 当前目标：① Permission 体系完善；② Session checkpoint/restore；③ MCP `2026-07-28` 主协议与 `2025-11-25` 单代兼容

## 0. Revision 6 定位

Revision 6 是 ABI v1 experimental 阶段的下一次显式 hard cut。目前确认三个目标：

1. 完善 AgentCore 的 Session 级 Permission 体系；
2. 补齐 AgentCore Session 的持久化恢复基础能力；
3. 以 MCP `2026-07-28` 为主协议、`2025-11-25` 为唯一兼容协议，为 AgentCore 补齐标准 MCP Tool 消费能力。

三个目标相互独立，但在以下位置必须形成统一语义：

- Permission 的 `allow_session`/`deny_session` 作用于逻辑 Session，而不是进程内 Handle；
- 恢复同一逻辑 Session 时，是否保留临时授权取决于 policy generation 与安全绑定是否仍然匹配；
- Session checkpoint 不得成为恢复已撤销权限、旧 Tool authority 或旧 Skill authority 的通道；
- Permission 请求和 Session checkpoint 都必须绑定明确的 generation，避免状态更新后的陈旧响应或陈旧快照生效；
- MCP Tool 必须进入与内置 Tool、Host Tool 相同的 Permission、Run admission 与审计通路；
- MCP transport、认证和 catalog cache 属于 Runtime/Host 绑定，不是可持久化的 Session 运行态；
- Session 只持有经过过滤的 MCP 能力视图与绑定指纹，Run 在 admission 时固定该视图。

Revision 6 继续遵守以下架构原则：

- AgentCore 只定义并执行 canonical Core 语义，不承担 Host 产品逻辑；
- Runtime、Session、Run 和 Host 的所有权边界保持清晰；
- Host 负责 UI、持久化后端、租户隔离、加密、保留策略和任务映射；
- AgentCore 不内置数据库，不解析 slash command，不定义产品级 Task；
- 新能力必须先有唯一 Core seam，再投影到 binary ABI；
- exact wire layout、函数表顺序、状态码和 capability bits 在 Core 语义与测试闭合后冻结。

### 0.1 修订纪律与“冻结”分级

Revision 5 在 experimental 阶段把 wire、行为基线和实现选择都使用了“冻结”一词，粒度过粗。Revision 6 不把这些表述一概视为不可修改的长期兼容承诺，而是重新分为：

| 状态 | 含义 | Revision 6 处理方式 |
|---|---|---|
| ABI/Wire Frozen | 已进入已发布 header、函数表或消费方可见 token 的契约 | 只能通过显式 revision hard cut 修改，并提供 old -> new 对照与迁移说明 |
| Behavioral Baseline | 某一 revision 的已测公共行为，但尚未形成稳定期承诺 | 可以在新 revision 中修订；必须说明理由、影响和新验收项 |
| Implementation Detail | Core/adapter 内部组织、缓存或产品侧实现 | 不构成兼容性承诺；只受所有权、安全和测试约束 |

Revision 6 仍记录所有消费方可观察变化，但不会为了维护过早冻结的行为而保留不合理语义。只有经过 Core 语义闭合、reference-closure audit、conformance tests 与真实 artifact consumer gate 的内容，才成为下一次候选冻结项。

### 0.2 Revision 5 -> Revision 6 行为基线变化

| 主题 | Revision 5 基线 | Revision 6 方案 | 理由/迁移影响 |
|---|---|---|---|
| imported `ask` 与 Session allow | `allow_session` 可绕过 imported `ask` | explicit `ask` 必须发起询问，不能被 `allow_session` 绕过 | `ask` 表示 Host 明确要求逐次确认；消费方不能再依赖旧 grant 静默通过 |
| rules update 与 Session grants | 保留 `allow_session/deny_session` | 成功替换 policy 后默认清除两类 Session grants | 防止旧 policy 下产生的授权或拒绝在新 generation 下继续生效 |
| permission response vocabulary | `allow_once/allow_session/deny_once/deny_session` | 保留四个 wire token | 不引入含义模糊的 `allow_always`；产品级长期规则仍由 Host 持久化 |
| `session_id` | 对物理 Session Handle 生命周期稳定、live Session 间唯一 | 新建时由 Core 分配；restore 从通过结构、版本和 authority 校验的 checkpoint 继承 logical identity，并创建新物理 Handle | 这是跨进程恢复所需的语义扩展；Host 不得任意指定 logical ID |
| quiescence | 已明确 `session_run_input` 返回边界 | Revision 6 另外定义 checkpoint eligibility 和 Session idle 边界 | 属于 Revision 6 新声明，不归因于 Revision 5 已冻结语义 |
| MCP | 旧内部 client 使用 `2025-06-18`，不构成 AgentCore ABI 能力 | `2026-07-28` 首选，自动协商到 `2025-11-25`；更早版本拒绝 | 面向新无状态架构，同时覆盖当前生态；兼容逻辑限制在 protocol adapter |

### 0.3 AgentCore hard cut 与实现变更边界

Revision 6 对 AgentCore ABI 执行完全 hard cut：

- 只接受 `abi_revision == 6`，不接受、探测、回退或双分派到 Revision 5 及更早 AgentCore revision；
- 不提供旧函数表、旧 DTO layout、旧 status/token alias、compatibility shim 或同进程多 revision adapter；
- 第 0.2 节只用于说明语义变化和消费方迁移，不授权任何 runtime compatibility；
- Host 必须按 exact bundle/revision 重新编译并显式迁移，不能依赖 AgentCore 猜测旧调用方；
- MCP `2025-11-25` 是外部 MCP wire protocol 的单代互操作，不是对旧 AgentCore ABI revision 的兼容。

Revision 6 的实现范围默认限制在 AgentCore-owned 层：

1. 优先新增或修改 `src/agentcore/**`、AgentCore 专属测试、header/bundle artifact 与本设计文档；
2. MCP 双 era negotiation、checkpoint codec/report、Permission ABI 投影和 compatibility adapter 必须留在 AgentCore-owned namespace，不得借机改变 CLI/App 的现有产品行为；
3. 可以复用现有 pure framing、process、Conversation 和 Permission primitives，但优先通过窄 seam 调用，而不是修改其通用执行语义；
4. 只有当 AgentCore 所需 canonical 状态无法从现有 seam 正确取得、且在 AgentCore 层复制会制造第二真理源时，才允许最小化修改 shared Core；该修改必须有 necessity record、受影响 caller 清单和 L2 回归测试；
5. `src/core/agent_loop.zig`、Provider turn loop、通用 Tool execution、CLI/TUI/Web 产品层默认禁止修改。任何例外都必须单独形成设计论证，证明现有 seam 无法满足，并在实施前取得明确批准；
6. 不允许为了减少局部代码量，把 AgentCore 专属 lifecycle、wire compatibility 或 persistence policy 下沉成全局产品行为。

该边界会使现有 CLI/App 与 AgentCore 暂时保留不同的 Permission 决策路径和 MCP 协议栈。这是为控制 Revision 6 范围而接受的并行语义路径债务，不等于两边已经共享 canonical semantics；Ledger E5 记录 owner、双路径安全修复义务、触发条件和待定收敛方向。该债务本身不构成在 Revision 6 中迁移 CLI/App 或修改 `agent_loop` 的理由。

### 0.4 Shared Core necessity records

最终 scope audit 确认 Revision 6 除 AgentCore-owned、SDK、测试、构建和文档外，只修改了以下四个 shared Core 文件。它们是实现 canonical Session/Permission 语义所需的窄 seam，不包含 AgentCore wire、MCP adapter 或 Host persistence policy：

| Shared Core 文件 | 现有 seam 缺口 | 最小改动与必要性 | 受影响 caller | 验证与默认行为 |
|---|---|---|---|---|
| `src/core/agent_session.zig` | 现有 Session 无法在同一 activity gate 下取得已提交 Conversation 快照、以 checkpoint logical ID 原子恢复，或在不改 `agent_loop` 的前提下为一次 admitted Run 注入 budget/MCP 包装 Provider | 增加 `CheckpointLease`/`checkpointing` activity、`RestoredSessionState`、exact ID registration、borrowed Provider Run seam 和 candidate-aware compact commit guard。guard 只把 owned preview Conversation 借给 facade 的同步 predicate，使 AgentCore 能在 replacement linearization point 验算候选 checkpoint；Conversation 仍由 shared Session 持有，若在 AgentCore 层复制这些状态机会形成第二个 Session 真理源 | AgentCore 使用新 seam；CLI/App 继续走原 `createSession`、Run、compact 路径且不设置 guard | shared unit 覆盖 busy/restore collision/lease/guard/provider；AgentCore checkpoint、near-hard compact、budget、restore L2 覆盖端到端。所有新增参数默认 null/旧入口不变 |
| `src/permission/decision.zig` | shared matcher 能算 imported deny/ask/allow，但没有把该 canonical 结果交给 AgentCore logical-Session grants；在 AgentCore 重写 matcher 会复制 1200+ 行 specifier 语义 | 增加可空 `DecisionOverride`，只传 Tool identity、arguments 与 imported action；null 时原决策链不变。显式 settings deny、Core safety、active Skill narrowing 和 shared Session deny 被标记为 fixed authority，seam 只观察而不能替换；只有普通 settings ask/allow/undecided 路径可由 AgentCore 完成。AgentCore 的 generation、grant 和 provenance 仍留在 `src/agentcore/**` | 只有 AgentCore Session 与受限 child lease 设置非空 override；CLI/App 保持 null | unit 证明 null inert、imported action 完整传递；恶意 override 返回 allow 仍不能改写 explicit deny/shared ceiling；Permission matrix、fresh Session、rules update 和 child authority 测试覆盖非空路径 |
| `src/permission.zig` | public shared `PermissionContext` 无法装配上述窄 seam | 只重导出 override 类型并把可空字段传给 decision 层，不新增产品 mode、规则或持久化行为 | 同上 | 原产品 caller 无需修改；CLI/App 行为基线由 null 默认和既有测试保持 |
| `src/permission/prompt.zig` | `no_interactive_prompt` 只在没有 requester 时阻止交互；requester 返回 unavailable/cancelled/异常后仍可能落到进程 answer queue 或 stdin，破坏嵌入库的输入所有权 | 把 `no_interactive_prompt` 定义为绝对边界：requester 没有产生 answered response 时直接 fail closed，且 process queue/`askText` 均不可达。不改变默认 `false` 的产品交互路径 | AgentCore Session、无交互 child/teammate 使用该边界；CLI/TUI/Web 默认路径保持原值 | 确定性测试预装 `y` answer queue 并让 requester 返回 unavailable，断言 deny 且输入未被消费；既有交互测试继续覆盖默认路径 |

`git diff e043575 -- src/core/agent_loop.zig` 为空；Provider turn loop、通用 Tool execution、CLI/TUI/Web 产品层也没有 Revision 6 diff。上述 necessity records 不授权未来继续扩张 shared Core；任何新增 seam 仍需重新审计。

### 0.5 实现评审后的架构处置

本轮实现评审按不变量和所有权边界处置，不以局部条件补丁替代设计：

| 发现 | 架构处置 |
|---|---|
| Permission 在 callback 非 answered 后回落 stdin | `no_interactive_prompt` 升格为输入所有权边界；AgentCore/child 永不读取宿主进程输入 |
| 合法 durable profile 可产生 checkpoint codec 无法编码的字符串 | profile 构造时要求所有 durable 单 payload cap 不超过 checkpoint `max_string_bytes`；transient provider request 不受该约束 |
| restore 把下一次 Run reserve 当作快照有效性条件 | restore 只验证已持久化状态和 profile；下一次 Run 在自己的 admission 阶段检查 reserve，使近满 Session 仍可恢复、describe，并通过 replacement-aware compact 降低 durable 使用量 |
| Run 可恢复错误绕过 budget 终结 | admitted Run 的 error path 统一 reconciliation；只对已经提交的同一 `run_id` 对账，不把 pre-admission 失败伪装成已运行 |
| 单个 MCP server 的协议资源超限中止整个 refresh | server-controlled failure 形成该 server issue 并跳过；只有 Runtime 本地 OOM 等全局失败中止 refresh |
| MCP 成功/错误、schema 和 wire 细节漂移 | `isError=true` 不强制 success `structuredContent`；参数 number lexeme 原样重编码；`format` 作为 annotation 接纳；schema OOM/resource-limit 保持 typed |
| negotiation 假分支和 allocator 漂移 | 删除生产路径不可达的“明确 legacy response”观察；只以格式正确的 `MethodNotFound`/stdio timeout/child exit 进入 legacy 候选；probe 使用 Runtime allocator，OOM 不伪装 transport failure |

评审同时暴露一个仍需单独设计的 shared seam：public Permission provenance 已区分 `user_cancelled` 与 `unavailable`，但通用 `agent_loop` 仍通过 bool prompt 结果生成同一普通拒绝 Tool result。Revision 6 不为修文案越过第 0.3 节修改 `agent_loop`；Ledger E8 记录该模型可见差异和后续 typed prompt-outcome seam 的触发条件。

## 1. 整体架构边界

### 1.1 Runtime、Session、Run、Host

| 层级 | 负责内容 |
|---|---|
| Runtime | Tool 注册表、Host Tool adapter、MCP client/transport manager、server discovery、catalog cache、可供 Session 绑定的运行时能力 |
| Session | Conversation、逻辑身份、模型绑定、Skill 绑定、Permission 状态、MCP 能力选择与 catalog view、跨 Run 状态 |
| Run | 一次输入到 terminal result 的执行活动，不拥有长期持久化状态 |
| Host | 凭证、MCP server 配置与认证、UI、持久化介质、用户/租户授权、任务与 Session 映射、产品策略 |

MCP 主协议 `2026-07-28` 是无状态协议，兼容协议 `2025-11-25` 的连接态只由 Runtime adapter 持有。两者的 transport 或 stdio server 进程生命周期都不等于 AgentCore Session、Run、任务或对话生命周期。Runtime 可以在符合隔离条件时复用 transport 与 catalog cache，但缓存必须至少绑定 server configuration、认证上下文与隔离域；不得在不同租户或凭证之间盲目共享。

### 1.2 Session 活动互斥

Revision 5 的 Session activity gate 继续作为 Revision 6 的基础：

```text
Session idle
  |-- Run
  |-- compact
  |-- mutation
  |-- checkpoint export
  `-- destroy
```

- 同一 Session 同时只有一个普通活动；
- matching Run abort 和 matching compact abort 仍是唯一并发例外；
- Permission UI callback 在所属 Run 的同步执行路径内；
- checkpoint export 只允许在 quiescent/idle 边界执行；
- restore 创建新的物理 Handle，不在已有 Handle 上覆盖内部状态。

### 1.3 统一生命周期与全局不变量

三个目标共同遵守以下生命周期：

```text
create
  -> Core 分配 logical session_id
  -> 绑定当前 policy/catalog authority
run admission
  -> 固定 policy_generation + catalog_generation
  -> 执行并提交 canonical Session state
checkpoint export
  -> 只导出已提交的 durable state
restore
  -> 校验 canonical state
  -> 创建新物理 Handle并登记 logical session_id
  -> 重新绑定当前 Provider/Skill/MCP/Permission authority
  -> 返回 complete 或 degraded RestoreReport
```

全局不变量：

- Conversation、logical identity 与已提交 Run 序列是 Session 核心资产；外部 MCP server、Skill 或 Tool 暂时不可用不得使核心资产无法恢复；
- Permission grant、MCP catalog view 和 Skill selection 是派生 authority，恢复时必须使用当前事实重新验证；
- active Run 只观察 admission 时的不可变快照，Runtime refresh 和 Host mutation 只影响后续 Run；
- checkpoint 不保存凭证、连接、callback、线程、指针或 live worker；
- 所有交给 Host 的 identifier 都必须有分配者、解析入口、生命周期、失效规则和诊断路径；
- 任一子系统失败不得隐式扩大 authority，也不得以“恢复失败”为由丢弃仍可安全恢复的 Conversation。

### 1.4 Generation 的作用域

Generation 不是一类可互换的全局 ID：

| Generation | 分配者与作用域 | restore 语义 |
|---|---|---|
| `policy_generation` | Core；在 logical Session 内单调递增 | checkpoint 中同时保存 compiled-policy fingerprint；fingerprint 相同才可延续 generation 和验证 Session rules，否则建立新 generation 并清除旧 rules |
| `catalog_generation` | Runtime MCP/Tool catalog；只在当前 Runtime 实例内单调 | 新 Runtime 重新 discovery 后分配新 generation；跨进程只比较 binding/schema fingerprints，不比较数值大小 |
| `checkpoint_generation` | Core；每个 logical Session 成功 export 后递增 | restore 保留最后成功 generation，下一次成功 export 继续递增 |

Host 不分配或伪造这些 generation。generation 用于固定视图、检测同作用域陈旧状态和审计；跨进程兼容判断必须依赖规范化 fingerprint，而不是碰巧相同的整数。

## 2. 目标一：Permission 体系完善

### 2.1 问题定义

Revision 5 已经具有 Permission mode、Host 导入的 `allow/ask/deny` 规则和 Session 临时记忆，但公共契约仍存在基础缺口：

- Session 临时记忆当前主要按 Tool 名称记录，对 Bash、MCP 等参数敏感工具过宽；
- mode、rules、Session memory 与单次 response 的优先级没有形成完整、经消费方验证的公共矩阵；
- Tool identity、specifier、arguments 与最终执行之间缺少强绑定；
- rules 更新没有 policy generation，无法可靠拒绝陈旧审批；
- Skill、Subagent、MCP、Run 与 Session 的权限继承规则尚未形成公共矩阵；
- Permission 与 Sandbox 的职责容易被消费方混淆；
- 缺少稳定的 decision source、matched rule 和审计字段。

Revision 6 保留现有 Permission 子系统的所有权和 canonical matcher 基础，但会修订 Revision 5 中过早冻结的行为基线。修订内容必须在第 0.2 节留痕，并由新的 conformance tests 取代旧行为断言。

### 2.2 架构定位

Permission 是独立的 Session 级授权系统：

- AgentCore 负责规则匹配、Session 授权状态、最终裁决和执行绑定；
- Host 负责展示审批 UI，并返回用户选择；
- Tool 只有在 AgentCore 产生 final allow 后才能执行；
- Skill、Subagent 和 MCP 不建立各自的 Permission 系统，统一进入 Session 的决策链；
- Sandbox 是独立的执行约束层，不能被 Permission allow 扩大。

```text
Tool call
  -> Session Permission decision
       -> deny: 不执行
       -> ask: Host UI response -> final allow/deny
       -> allow: 执行
  -> Sandbox / workspace / runtime authority ceiling
  -> Tool execution
```

Permission 回答“这次调用是否获得授权”；Sandbox 回答“获得授权后技术上最多能做什么”。

### 2.3 三组术语

#### 规则动作

```text
deny | ask | allow
```

它们用于 Host rules、Session rules 和 canonical matcher。

#### 引擎决策

```text
deny | ask | allow
```

`ask` 是中间状态，不代表 Tool 已获准执行。

#### 用户响应

```text
deny_once | deny_session | allow_once | allow_session
```

- `deny_once`：只拒绝当前调用；
- `deny_session`：拒绝当前调用，并在当前 logical Session 内保存受限 deny rule；
- `allow_once`：只允许当前调用；
- `allow_session`：允许当前调用，并在当前 logical Session 内保存受限 allow rule，可跨 Run 生效；
- 新建 Session 后必须重新授权；
- restore 同一 logical Session 时是否恢复 Session rule，按第 3.8 节的安全恢复规则处理；
- wire token 描述 Core 作用域，不规定产品 UI 文案。Host 可以显示 “Always for this session”，但不能把 `allow_session` 描述为跨 Session 永久授权。

`full_access` 不是审批响应，而是 Session permission mode。

### 2.4 Rule 模型

规则继续使用 canonical：

```text
Tool(specifier)
```

要求：

- matcher 必须理解 Tool identity 和该 Tool 的 canonical specifier；
- 不允许仅凭展示名称授权参数敏感工具；
- MCP Tool 必须包含稳定的 server/tool identity；
- `allow_session`/`deny_session` 保存的规则由 AgentCore 根据当前调用生成候选；
- Host 只能选择 AgentCore 给出的候选，不能扩大、改写或自行拼接 matcher；
- 无法安全生成受限规则时，不提供对应 Session response；
- arguments 不直接作为未规范化字符串参与授权，必须先经过 Tool 对应的 canonicalization。

### 2.5 固定优先级

Revision 6 的 canonical 决策顺序为：

1. 不可绕过的 Core safety constraints；
2. 显式 `deny` rule；
3. 当前 Session 的 `deny_session` rules；
4. 显式 `ask` rule；
5. 显式 `allow` rule；
6. 当前 Session 的 `allow_session` rules；
7. AgentCore 内置的安全分类；
8. permission mode fallback。

核心原则：

```text
deny > ask > allow
```

- 显式 `deny` 不能被 Session grant 或 mode 绕过；
- `deny_session` 不能被显式 allow、Session allow 或 mode 绕过；
- 显式 `ask` 表示每次都要询问，不能被既有 `allow_session` 绕过；
- 由显式 `ask` 触发的请求不提供无效的 `allow_session`；仍可提供 `deny_once`、`deny_session` 和 `allow_once`；
- action 优先级不因 rule specificity 改变。需要“总体询问、窄范围放行”时，应使用 mode fallback 表达总体询问，再添加窄范围 explicit allow；不得用 broad explicit ask 覆盖后又期待窄 allow 绕过；
- Core safety constraints 不得因 `full_access` 失效。

### 2.6 Permission mode

Revision 6 的 public wire 已采用五个固定 code：`PERMISSION_DEFAULT`、`PERMISSION_ACCEPT_EDITS`、`PERMISSION_AUTO`、`PERMISSION_DONT_ASK` 和 `PERMISSION_FULL_ACCESS`；下表描述其 Session 语义：

| Mode | 未命中显式规则时 | 显式 `ask` | 显式 `deny` |
|---|---|---|---|
| `default` | 只读安全调用 allow，其余 ask | ask | deny |
| `accept_edits` | 只读与 Workspace 编辑 allow，其余 ask | ask | deny |
| `auto` | Core 判定的低风险调用 allow，其余 ask | ask | deny |
| `dont_ask` | 原本需要询问的调用直接 deny，不发 callback | deny | deny |
| `full_access` | 未决调用 allow | ask | deny |

补充约束：

- `PERMISSION_FULL_ACCESS` 在 AgentCore public wire 中对应 shared Core 的 `bypass_permissions` mode；该映射不把 shared Core 的旧命名暴露给消费方；
- Host 可以完全禁用 `full_access`；
- `full_access` 不关闭不可绕过 safety constraints；
- `full_access` 不等于关闭 Sandbox；
- Core 可以对极高风险场景保留不可绕过的 circuit breaker。

Revision 5 拒绝公开 `full_access`，主要因为当时 Permission 与 Sandbox/authority ceiling 的分层尚未形成。Revision 6 只有在本节的分层成立、Host 可禁用且 safety constraints 不可绕过时才重新评估该命名；这不是一次 Tool response，也不是“关闭全部安全机制”。

### 2.7 Permission request 与执行绑定

每个进入 Host callback 的请求至少绑定：

```text
session_id
run_id
tool_call_id
request_id
tool_identity
canonical_arguments_digest
policy_generation
```

要求：

- response 只能完成对应的 pending request；
- Tool 执行参数必须与批准参数完全一致；
- callback response 必须与 pending request 中固定的 policy generation 一致；
- Run 结束、abort 或 Session 销毁后，所有 pending request 失效；
- callback outcome 必须区分 `answered`、`user_cancelled`、`unavailable` 与 `contract_failure`；
- `deny_once/deny_session`、`user_cancelled` 与 `unavailable` 都不执行 Tool；public request/provenance 必须保持三者的 typed 区分，不得把 callback unavailable 记录成用户主动拒绝；
- 用户取消或 callback unavailable 不创建 Session grant，Session 保持可用；
- callback 返回非法 response、错误 request identity 或无效 rule candidate 属于 callback contract failure。

AgentCore 设置 `no_interactive_prompt=true` 后，该值是绝对的输入所有权边界：即使 requester 已安装但返回 unavailable、cancelled 或异常，也不得读取 process answer queue 或 stdin。当前通用 `agent_loop` 的 bool prompt seam 仍把 non-answered 路径投影为同一普通拒绝 Tool result；这是模型可见文案/类型的已知缺口，不影响 final authorization 与 public provenance 的四态区分，处置见 Ledger E8。

### 2.8 Rules 更新

Host permission rules 仍只能在 Session idle 时原子替换：

- 新规则完整校验、编译成功后一次提交；
- 失败保留旧规则；
- 成功后递增 `policy_generation`；
- 因更新只允许发生在 idle，进程内不存在可同时存活的 Run permission request；不得把“使旧 pending request 失效”描述为可达的普通更新路径；
- 当前 Session 的 `allow_session` 与 `deny_session` rules 默认全部清除，避免在新 policy 下继承旧裁决；
- active Run 固定观察 admission 时的 permission view。

`policy_generation` 仍用于 checkpoint compatibility、restore 后 grant validation、审计和跨边界 defense-in-depth。Revision 6 第一版不提供“兼容更新后保留 Session grants”的旁路。

### 2.9 Skill、Subagent、MCP 继承原则

- 所有调用继承所属逻辑 Session 的 permission mode 与 authority ceiling；
- Skill 只能进一步收窄权限，不能恢复父层移除的 authority；
- inline Skill 使用当前 Run 的 Permission 通路；
- fork Skill/Subagent 不建立独立持久授权域；
- fork child 若没有 Host UI 能力，`ask` 必须 fail closed；
- MCP Tool 使用与内置/Host Tool 相同的决策、请求绑定和审计模型；
- nested activation 的有效权限是父 PolicyFrame 与当前 Skill 限制的交集；
- explicit settings deny、shared Core safety、active Skill narrowing 与 shared Session denial 是不可由 AgentCore consumer seam 放宽的 fixed authority；seam 仍观察其 canonical source，以形成同一 provenance record。

### 2.10 可观测性

每次 Permission 判定应形成稳定、结构化、可审计的数据：

- final decision；
- decision source：`core_safety`、`active_skill`、`explicit_deny`、`session_deny`、`explicit_ask`、`explicit_allow`、`session_allow`、`builtin_classification`、`mode_fallback` 或 `callback`；
- matched rule identity；
- tool identity 与 canonical specifier；
- request/tool-call/run/session identity；
- policy generation；
- 是否使用 Session grant；
- 是否经过 Host callback；
- callback outcome 与用户响应作用域。

审计记录如何持久化由 Host 决定；AgentCore 只提供规范化事件，不内置审计数据库。

Host callback response 与 final authorization decision 是两个不同事实。AgentCore 对需要新增 Session grant 的回答采用两阶段 receipt：先为审计 receipt 准备 owned storage，再尝试预留 durable budget 和修改 Session authority，最后以既有 `policy_decision` 事件中的实际 `allowed` 结果提交同一 receipt 并发布 provenance。准备失败时不得新增 grant；grant/budget 失败时 receipt 仍保留 Host 的 `response=allow_session|deny_session`，但 final decision 必须记录实际 deny，不能先写一条 allow 审计再对外发布 deny。receipt commit 不得再分配内存，避免“authority 已生效但审计无法落地”的反向裂缝。

### 2.11 持久化边界与 Ledger A3 disposition

AgentCore 的 Permission seam 必须满足：

- 不读取或写入 `.claude`、`.metacodes` 或任何产品 settings 文件；
- `allow_session/deny_session` 只修改当前 logical Session 的 Core state；
- Session grant 可以作为 checkpoint 语义状态由 Host 保存，但 checkpoint export 本身不等于跨 Session 产品设置；
- 产品 UI 若提供 “Allow always”，Host 必须先完成自己的持久化，再对当前 callback 返回 `allow_session`；后续 Session 通过导入 canonical Host rules 获得长期效果；
- 产品侧 `settings_writer` 可以继续存在，但 AgentCore Runtime/Session/Run 路径不得调用它。

Ledger A3 只有在真实临时 Workspace 的 AgentCore 零写盘测试，以及“新 logical Session 必须重新 prompt”的 L2 测试通过后才能关闭。

### 2.12 Permission 非目标

- 组织、租户、项目和用户权限数据库；
- Host 产品设置文件读写；
- UI 文案与按钮布局；
- 关闭或替代 Sandbox；
- 通过 permission response 持久化到其它 Session；
- 让 Host 自行解释或扩展 AgentCore matcher；
- 将 `full_access` 设计为一次 Tool 审批结果。

## 3. 目标二：Session checkpoint/restore

### 3.1 问题定义

Revision 5 的 Session 已经是长生命周期、多 Run、共享 Conversation 的有状态执行容器，但状态只存在于当前进程和 Handle 生命周期内。它没有：

- Conversation export/import；
- Session checkpoint；
- 从 checkpoint 创建 Session；
- 恢复原逻辑 `session_id` 与 `run_id` 序列；
- 状态格式版本和兼容性校验；
- 消费方重新对账所需的最小 Session 描述信息。

因此消费方只能保存 UI 事件或摘要，然后创建全新 Session；这不是语义等价的恢复。

### 3.2 目标边界

Revision 6 的基础目标是：

1. 在 Session idle/quiescent 边界导出版本化 checkpoint；
2. 使用 checkpoint 创建新的物理 Session Handle；
3. 恢复同一个逻辑 Session 的 canonical 执行状态；
4. 校验当前 Runtime、Host 配置和 checkpoint 是否兼容；
5. 提供最小 Session 描述信息，供 Host 恢复后对账。

Revision 6 不承诺从 Tool 执行中间位置继续，也不承诺外部副作用 exactly-once。

### 3.3 存储职责

AgentCore 负责：

- 定义 checkpoint 的语义；
- 生成一致、版本化、资源受限且可流式导出的 checkpoint；
- 校验并恢复 canonical Session state；
- 拒绝损坏、不兼容或可能扩大 authority 的状态。

Host 负责：

- checkpoint 存储介质；
- 加密、访问控制和租户隔离；
- retention、归档、删除和跨设备同步；
- Task 与 logical Session 的映射；
- 恢复时重新提供凭证、Runtime、callbacks 和当前安全策略。

AgentCore 不选择 SQLite、Redis、数据库、对象存储或产品目录。

任何已启用 checkpoint 能力的 Session 都必须维持 durable-state invariant：一次成功接纳的状态变化不能把 Session 推入“此后永久无法导出”的状态。chunked section 解决连续内存与 sink 写入问题；总量安全由 admission/reservation 状态机保证，不能推迟到 commit 或用户发起 export 时才处理。

#### 3.3.1 Durable-state 预算状态机

compact 继续是第 1.2 节定义的独立 idle activity，不允许作为 Run commit 的隐藏副作用。预算状态机固定为：

1. Session create/restore 校验 checkpoint budget 至少可以容纳 canonical 最小 terminal/error record；无效配置直接失败；
2. idle Session 接近 soft threshold 时，通过 describe/result 暴露 `compaction_recommended`，由 Host 决定是否调用独立 `session_compact`；compact 是 replacement transaction：Provider 请求/结果仍受 cap 约束，提交时按候选 Conversation checkpoint 精确验算，而不是把摘要当作追加到旧 Conversation；
3. `session_run_input` 在 admission 前校验输入、当前 durable usage 与最小 Run reserve；不足时返回 `checkpoint_budget_required`（语义占位名），不分配 `run_id`、不修改 Conversation，输入仍由 Host 持有；
4. Run admission 后维护 Run-local durable reservation；每次 Provider、Tool 或 MCP 外部操作前，按当前 reservation profile 为 canonical request、结果上限、审计记录和 terminal marker 预留预算。profile 由 Runtime hard cap、Provider/Tool/MCP 已声明或 AgentCore 配置的 per-operation cap，以及 Host 协商的 checkpoint budget 共同约束；不得把协议理论最大 payload 直接作为默认 reservation；
5. 无法建立 reservation 时，不发起下一次外部操作，以 `checkpoint_budget_exhausted`（语义占位名）结束已接纳 Run；已在安全边界内接纳的 Conversation 前缀和有界 terminal marker 一并提交，Session 返回 idle 且继续可 checkpoint；
6. 用户输入等已知超大 payload 在 admission 前拒绝；Provider/Tool/MCP 返回超过已声明上限时，不提交原始 payload，而是形成有界 resource-limit terminal/tool outcome。若外部调用可能已有副作用，仍按对应的 indeterminate/failed 语义记录，不能伪装为未执行。

Profile 在构造时还必须保证 `input_cap_bytes`、`provider_result_cap_bytes`、`tool_result_cap_bytes` 与 `mcp_result_cap_bytes` 不超过 checkpoint codec 的 `max_string_bytes`；`provider_request_cap_bytes` 是 transient wire budget，不受 durable-string 约束。这样“可接纳的单段 durable payload 必然可编码”由配置构造保证，而不是依赖 Run 结束后的 poison 兜底。

checkpoint 保存可继续执行的 canonical Conversation 投影，而不是原始 transcript 归档：未 compact 时保存全部 messages；compact 后保存 summary 与 active messages，不再重复保存已经被 summary 替代的隐藏前缀。restore 将 summary 物化为首条 assistant context，使后续再次 compact 仍会把既有摘要纳入新摘要；因此 codec 的 `max_messages` 同时计入该物化 summary，不能在恢复时凭空多出一条越过上限的消息。Host 若需要逐字审计历史，应从 event/transcript 存储独立归档。该边界让 compact 同时降低模型上下文和 durable checkpoint 使用量。

Text 与 typed Skill 共用 `preflightRootRecords` 不变量，但不能伪装二者的输入生成时机相同：Text prompt 和 Skill canonical invocation record 都是无副作用、可在 admission 前精确编码的 root record，因此只按精确 checkpoint delta 预留；Skill body 的文件引用、materialization 路径和 shell 注入只有在 admitted Run 内才能安全求值。后者在 Conversation mutation 前原子对账其精确 root-record delta，超出 input cap 形成 `resource_limit`，durable budget 不足形成 `budget_exhausted`。不得为方便计算而把 materialization 或 shell 执行偷移到 Run admission 之前，也不得再用整块 `input_cap_bytes` 冒充 Skill 的已知输入大小。

公开 wire 已将上述路径映射为 `STATUS_CHECKPOINT_BUDGET_REQUIRED`、`STOP_CHECKPOINT_BUDGET_EXHAUSTED`、`STOP_CHECKPOINT_RESOURCE_LIMIT` 与 `RunResultV1.checkpoint_outcome_code`。实现必须保持“pre-admission 不消费状态”“admitted Run 只在已预留的安全边界提交”“compact 不隐藏在 commit 内”三条可观察语义。

reservation profile 必须同时满足安全性与可用性：结果超过已预留的 per-operation cap 时仍按第 6 条形成有界 outcome，但常规有界结果不得仅因为协议存在极大的理论上限而提前耗尽长 Session。默认 cap 和 soft threshold 必须由真实长会话与 consumer workload gate 决定，不能只做最坏值推导。

### 3.4 checkpoint 一致性边界

现有 binary ABI 只明确保证 matching `session_run_input` 返回是该 Run 的 quiescence boundary。Revision 6 在此之外单独声明 checkpoint eligibility：

- checkpoint export 只允许 Session idle；
- active Run、compact、mutation 或 in-flight abort 期间返回 `BUSY`；
- Session-owned live background job、未完成 MCP request 或其它不可序列化活动仍存在时，不满足 checkpoint eligibility，并返回 `BUSY`；
- checkpoint 对应一个完整提交点；
- export 不改变 Conversation、`run_id`、Permission 或 Skill 状态；
- export 失败不 poison Session；
- checkpoint generation 只标识已成功形成的逻辑快照。

进程在 active Run 中崩溃时：

- 只能恢复最近一次完整 checkpoint；
- 未完成 Run 不得被 AgentCore 自动重放；
- Host 可以把该 Run 标记为 interrupted，并决定是否由用户重新发起；
- Revision 6 第一版不尝试恢复 Tool worker、provider stream 或中间模型输出。

### 3.5 checkpoint 中的语义状态

必须能够恢复：

- logical `session_id`；
- 最后接纳的 `run_id`；
- canonical Conversation，包括合法的 Tool use/result 结构；
- Compact 后的 resumable 投影（summary + active messages）；被 summary 替代的 raw prefix 属于 Host transcript 归档，不重复进入 checkpoint；
- 当前有效模型标识；
- Skill Catalog revision 与 selection；
- MCP server/tool selection、catalog generation 与 binding/schema fingerprints；
- Permission mode；
- Session `allow_session/deny_session` rules 及其 policy generation；
- 必要的 authority/configuration fingerprints；
- checkpoint/state schema revision。

是否保存累计 usage、上下文估算和 compact operation identity，待 Core 状态审计后确定；它们不能与 provider 账单语义混淆。

### 3.6 不进入 checkpoint 的运行时状态

以下内容不得直接序列化：

- API key、access token 等凭证；
- Provider client、网络连接与 MCP connection；
- Host callback、Host `ctx` 和函数指针；
- Runtime/Session Handle 或任何内存指针；
- mutex、thread、AbortSignal、worker；
- Bash 进程、fd、pid、JobRegistry live handle；
- 临时 allocator、缓存和内部借用视图。

恢复时这些对象由当前 Host/Runtime 重新构造。

Read state 默认不作为可直接信任的持久授权状态。若未来保存文件指纹，恢复时也必须重新验证 Workspace 中的真实文件，不能因为旧 checkpoint 声称“已读”而绕过当前安全检查。

### 3.7 Restore 语义

restore 的语义是“新物理实例承接同一逻辑 Session”：

- 创建新的 Session Handle；
- 新建 Session 的 logical `session_id` 由 Core 分配；restore 的 logical `session_id` 只能来自通过校验的 checkpoint，Host 不得另行指定或覆盖；
- 保留 `last_admitted_run_id`，后续 Run 继续严格递增；
- 恢复完整 Conversation；
- callbacks、Host ctx、Provider client 和凭证使用本次恢复参数重新绑定；
- restore 完成 canonical state 校验、logical ID 登记和当前 authority 对账前不发布 Session Handle；
- 损坏、资源超限、state schema 不兼容、logical ID 冲突或可能扩大 authority 的状态必须 fail closed；
- 可选/派生外部 binding 不可用时不得丢弃已安全恢复的 Conversation，而是发布 degraded Session 与 RestoreReport；
- restore 失败不得产生半初始化 Session 或修改 checkpoint。

原物理 Handle 若仍存在，Host 不得同时恢复相同 logical Session 并并发运行。如何防止跨进程双活由 Host 的存储租约/注册表负责；AgentCore Runtime 仍应拒绝同一进程内的 live `session_id` 冲突。

restore 按两阶段提交：

```text
phase 1: validate envelope -> reconstruct canonical core state -> reserve logical session_id
phase 2: bind current Provider/Skill/Tool/MCP/Permission authority -> invalidate unsafe derived state
commit: publish Handle + RestoreReport(complete | degraded)
```

### 3.8 Permission 恢复安全

恢复的是同一个逻辑 Session，因此 `allow_session/deny_session` 在语义上可以跨进程恢复，但每条 rule 必须满足全部条件：

- checkpoint 完整性校验成功；
- Tool identity/specifier 仍可解析；
- Workspace、Runtime Tool 和相关 Skill/MCP 绑定兼容；
- 当前 compiled-policy fingerprint 与 checkpoint 兼容，并按第 1.4 节延续或重建 policy generation；
- 当前 authority ceiling 不小于该 Session rule 所依赖的能力。

恢复后的 rule 仍重新进入第 2.5 节优先级：`allow_session` 遇到当前 explicit deny/ask 或 Core safety constraint 时失效；`deny_session` 继续按 deny-wins 生效，不能被当前 explicit allow 或 mode 绕过。

任何兼容性条件不满足时，对应 Session rule 必须失效并进入 RestoreReport，不能静默扩大权限。只有 rule 数据本身损坏、伪造出不可表示状态或试图越过 authority ceiling 时才拒绝整个 restore。Host policy 更新、Tool identity 变化或 Workspace 变化默认使 Session rules 失效。

checkpoint 不得恢复 Host 已撤销的 imported allow rule。Host rules 是当前 authority 输入，不以旧 checkpoint 为权威来源。

### 3.9 Skill、Tool 与 MCP 兼容性

- checkpoint 记录 Skill Catalog identity/revision 和 selection；
- restore 时必须由当前 Runtime 提供可验证的 catalog binding；
- Skill 被删除、revision 不匹配或 policy 收窄时，不能盲目恢复旧 authority；
- Runtime Tool/Host Tool 通过稳定 identity 与能力指纹匹配；
- MCP transport 由当前 Runtime 重建，server/tool binding 与 schema fingerprint 必须重新发现和验证；
- checkpoint 不能携带可执行函数或用旧 schema 覆盖当前 Runtime registry；
- Skill、Tool 或 MCP server 暂时不可用时恢复核心 Session，并把对应 catalog view、selection 和 grants 标记为 unavailable/invalidated；
- 恢复可以接受当前 authority 更窄，但必须在 RestoreReport 中明确失效哪些 Session grants；
- 当前 authority 更宽也不能自动赋予旧 Session 新能力。

### 3.10 RestoreReport 与 reference closure

restore 返回的规范化报告至少表达：

- `complete | degraded`；
- logical `session_id` 与新物理 Handle 的关联；
- 被恢复和被清除的 Permission Session rules；
- unavailable/changed Skill、Tool 与 MCP bindings；
- MCP 协商版本、catalog/schema 漂移和不可用原因；
- policy/catalog/checkpoint generations；
- 不影响 Conversation 使用但会影响后续能力的 warnings。

MCP server 不在线、认证暂时不可用或 catalog refresh 失败，默认属于 degraded restore，不是整个 Session restore failure。相关 MCP view 与 grants 必须失效；后续 refresh 成功后只能为后续 Run 建立新 view，不能自动复活旧 grant。

所有交给 Host 的 `session_id`、`run_id`、`policy_generation`、`catalog_generation`、`checkpoint_generation`、`server_binding_identity` 和 issue identity，都必须在 `session_describe`、Runtime catalog query 或对应 result/event 中存在规范化解析路径。reference-closure audit 是 ABI freeze 前置条件。

### 3.11 最小 Session 描述信息

Revision 6 需要一个只读、规范化的最小描述能力，供 Host 对账。候选字段：

- logical `session_id`；
- lifecycle state；
- last admitted `run_id`；
- model identity；
- Skill Catalog revision；
- MCP catalog generation 与 Session view fingerprint；
- Permission/policy generation；
- checkpoint generation；
- Conversation/context size estimate；
- restore health、degraded bindings 与 invalidated-grant summary；
- logical ID 的来源（fresh create 或 restored checkpoint）及当前 Runtime registration state。

它不是通用内部状态 dump，不承诺暴露完整 Conversation，也不允许 Host 修改任意内部字段。public 入口已经固定为 `session_describe`，返回受 `sdk/zig/protocol.zig` 校验的 `SessionDescription` JSON；新增字段必须通过新的 ABI revision，而不是复用 reserved 字段暗改语义。

### 3.12 状态格式、容量与信任边界

checkpoint 必须具备：

- 独立 state schema revision；
- 明确的导入总量、单 section、嵌套、条目和字符串上限；
- 先限长、后解引用、再解析；
- UTF-8、tag、reserved field 和结构完整性校验；
- AgentCore/ABI 兼容性信息；
- 配置与 authority fingerprints；
- 明确区分 corrupt、unsupported、incompatible、stale-policy 和 resource-limit。

checkpoint export/restore 的 C ABI 已采用 Host-owned `checkpoint_sink_v1`/`checkpoint_source_v1` 回调与显式 `checkpoint_limits_v1`，不得要求整个长 Session 先形成单个连续 owned buffer。Host 在 Session create/restore 时提供可接受的 checkpoint budget；Core 暴露预算使用量，并通过第 3.3.1 节的 admission/reservation 状态机持续维持 durable-state invariant。

checkpoint 包含对话、工具结果和可能的用户数据，属于敏感数据。AgentCore 负责结构、版本、资源边界和内容一致性校验；Host 负责加密、MAC/签名、访问控制和来源真实性。checksum 只能检测意外损坏，不能冒充可信来源。AgentCore 不假设传入 checkpoint 天然可信。

### 3.13 Session 恢复非目标

- AgentCore 内置持久化数据库；
- Session 列表、搜索、标题、归档和删除；
- 跨设备同步协议；
- active Run 的指令级或 token 级续跑；
- Tool 外部副作用 exactly-once；
- 自动重放未完成 Run；
- Bash/MCP 网络连接跨进程复活；
- Session fork、time travel 和任意 checkpoint 分支；
- 任意 Conversation CRUD；
- 将 Session-owned live activity 转移为 Host-owned detached activity 的所有权移交协议；
- poisoned live Handle 的原地修复。

## 4. 目标三：MCP `2026-07-28` 主协议与 `2025-11-25` 单代兼容

### 4.1 协议基线

Revision 6 的主协议固定为 **MCP 2026-07-28**，同时只为紧邻的 **MCP 2025-11-25** 提供兼容。更早 revision 明确不支持。

- AgentCore 的 MCP canonical catalog、Tool identity、Permission 与 restore 语义面向 `2026-07-28` 的无状态架构设计；
- protocol adapter 隔离两个 era 的 lifecycle 差异：`2026-07-28` 使用 `server/discover` 与 request `_meta`，`2025-11-25` 使用 `initialize/notifications/initialized` 和该版本定义的连接状态；
- 协商出的版本必须进入 diagnostics、Runtime binding status 与 restore report，不允许对消费方静默；
- 若只支持 `2025-06-18` 或更早版本，返回明确的 unsupported-version 错误；
- 不把当前 `src/mcp` 的旧协议行为直接暴露为 AgentCore 公共契约；
- Revision 6 后续若升级 MCP，必须重新进行协议、权限、缓存和恢复兼容性审计。

每个 server binding 必须选择一种 negotiation policy。以下是语义名，不是已冻结 public wire token：

```text
auto | modern_only | legacy_only
```

- `modern_only`：只执行 `2026-07-28` `server/discover`，任何不兼容都失败；
- `legacy_only`：跳过 probe，直接执行 `2025-11-25` initialize；最终协商到其它版本时失败；
- `auto`：优先 probe modern era，再按 transport-specific policy 判断是否进入 legacy initialize。

`auto` 的 transport-specific policy 固定为：

| Probe 结果 | stdio | Streamable HTTP |
|---|---|---|
| 合法且 mutually supported 的 `server/discover` | modern | modern |
| 格式正确的 `MethodNotFound` | legacy probe | legacy probe |
| 有界 probe timeout | legacy probe；默认不 retry | typed timeout failure，不 fallback |
| probe child 在 modern 响应前退出 | legacy probe | 不适用 |
| 401/403、5xx、损坏响应、现代协议错误、显式取消 | typed failure，不 fallback | typed failure，不 fallback |

stdio `auto` probe 必须使用按同一 server 配置启动的短生命周期 disposable process，并在确定候选 era 后回收；随后按候选 era 启动真正的 Runtime transport，modern 与 legacy 都不得把 probe process 升格为实际连接。这样避免旧 Server 因未知 pre-initialize request 沉默或退出后污染实际连接。若 Server 启动本身有副作用或 Host 已知 era，Host 应使用 `modern_only`/`legacy_only`，避免双启动和 probe 延迟。

disposable probe 只确定真正 transport 的候选 era，不证明两次启动之间 server identity 或行为不会变化。真正 transport 必须重新验证所选 era；若其响应与 probe 结果不一致、server 在两次启动之间更新或表现不确定，binding 返回 typed negotiation failure。Revision 6 不在同一次 binding 中静默重新 probe、切换 era 或继续降级，避免 TOCTOU 被转化成不可观测的协议漂移。

stdio timeout fallback 不扩展 authority：legacy adapter 不开放 Roots、Sampling、Logging 等已排除能力，并继续使用相同的 canonical schema、Permission 与 Runtime ceiling。HTTP timeout 不作为 era 信号，避免把网络故障或降级攻击误判为 legacy。

```text
policy modern_only -> server/discover (`2026-07-28`) -> modern or fail
policy legacy_only -> initialize (`2025-11-25`) -> legacy or fail
policy auto
  -> transport-specific modern probe
       |-- modern -> modern adapter
       `-- legacy probe -> initialize (`2025-11-25`)
              |-- negotiated exactly 2025-11-25 -> legacy adapter
              `-- older/no common version -> UnsupportedProtocolVersion
```

这是“新架构 + 单代兼容”，不是无限历史兼容。两个 adapter 必须汇入同一 canonical MCP seam，不能让握手、连接级 Session 或版本分支渗透到 Permission、Session Conversation 和模型 Tool 层。

`2025-11-25` legacy adapter 是带退场条件的 compatibility debt，不是永久资产。下一版 MCP stable revision 进入 AgentCore 时，应以新规范作为 primary candidate、`2026-07-28` 作为 compatibility candidate，并默认移除 `2025-11-25`；但退场只能通过新的显式 ABI revision，在新 adapter conformance、真实 consumer/server matrix、old -> new 迁移说明和 Ledger E4 stability-horizon 评估完成后执行，不能在同一 revision 内静默改变。

### 4.2 最新规范带来的设计约束

两个版本的 lifecycle 差异是 adapter 责任：

- `2026-07-28` 无协议 Session，不使用 `initialize` 或 `Mcp-Session-Id`；每个请求携带规范要求的 `_meta`，client 通过 `server/discover` 获取版本、能力与 server 自报信息；
- `2025-11-25` 的 initialize state、连接级 session ID 和 legacy notification 只存在于 Runtime adapter；它们不等于 logical AgentCore `session_id`，也不得进入 checkpoint；
- `2026-07-28` operation result 必须携带 `resultType`；`2025-11-25` 结果缺失该字段时在 canonical seam 规范化为 `complete`；
- `2026-07-28` 通过 MRTR 表达额外输入需求；Revision 6 不为兼容旧版而把 server-initiated request 重新引入 canonical Core；
- `2026-07-28` `tools/list` cache 使用 required `ttlMs/cacheScope`；`server/discover` 未返回两者时表示没有该结果级 cache hint，不能误判为损坏；旧版缺失这些字段时采用保守的 Runtime refresh policy，并仍产生 catalog generation；
- `subscriptions/listen`、legacy notifications 或 transport resumability 都只能触发 Runtime refresh，不能直接修改 active Run。

因此，AgentCore 的逻辑 Session、MCP transport、server process 和 catalog cache 必须解耦设计。

### 4.3 所有权模型

| 状态/能力 | 所有者 | 说明 |
|---|---|---|
| MCP server 配置、凭证、OAuth/认证上下文 | Host | 不进入 AgentCore checkpoint，不跨租户共享 |
| transport、stdio process、protocol client、request routing | Runtime | 可按隔离键复用，但不等同于 Session 生命周期 |
| server discovery 与原始 catalog cache | Runtime | modern 遵守 `ttlMs`/`cacheScope`，legacy 使用保守 refresh；缓存键包含 server config、auth context 和隔离域 |
| 启用的 server/tool、Permission grants、catalog view/generation | Session | 只是经过当前 policy 与 authority 过滤后的能力视图 |
| 本次可见 Tool 集合与 schema | Run | 在 Run admission 时固定，active Run 中不因 catalog 刷新漂移 |
| server binding/catalog fingerprint | checkpoint | 只用于 restore 对账，不包含 live connection 或 token |

Runtime 可以选择按 server binding 常驻、延迟连接或按需重建 transport；这是 Core 实现策略，不改变上述公共语义。无论采用哪种策略，断线重连都不得产生新的 Session authority。

### 4.4 Revision 6 基础支持范围

Revision 6 第一阶段必须具备以下 MCP 消费能力：

1. 双 era negotiation：modern `server/discover`/request `_meta` 与 legacy `initialize` lifecycle；
2. 两个版本的 `tools/list`/`tools/call` 进入同一 canonical catalog/result seam；
3. 完整保留 Tool identity、description、annotations、`inputSchema` 与 `outputSchema`；
4. `2026-07-28` 严格处理 required `resultType`；`2025-11-25` 缺失时兼容规范化为 `complete`；
5. JSON Schema 处理：无显式 dialect 时按 2020-12；显式 dialect 按已声明支持范围验证，不支持时明确拒绝；
6. text、image、audio、resource link/embedded resource 和 structured content 等规范结果类型；
7. modern list TTL/cache-scope、legacy 保守 refresh、catalog generation 与统一失效；
8. 统一 Permission、Run admission、abort、timeout、错误映射和审计；
9. Session 级 server/tool 选择与 Run 级固定 Tool view；
10. restore 时重新协商版本并对 MCP binding、catalog fingerprint 和 Session grants 重新验证。

Revision 6 第一阶段不声明 MRTR/Elicitation client capability。若 `2026-07-28` server 在未协商支持的情况下返回 `resultType: "input_required"`，AgentCore 必须完整解析并校验该结果，然后以结构化 `input_required_unsupported`（语义占位名，非 wire token）结束当前 Tool call：不自动 retry、不把 interim result 当作 complete、不提交部分 Tool result，Session 保持可用。完整 MRTR 支持需要单独冻结 request/response、用户输入和重试状态机。

这里只确认 MCP Tool 作为 Revision 6 的基础能力。Resources、Prompts、Elicitation 和 subscription 的公共投影范围仍待单独讨论，不能因为底层协议能够收发就宣称 AgentCore 已经支持。

### 4.5 Catalog 与 Run 可见性

MCP Tool 必须进入 AgentCore 统一 Tool catalog，而不是形成绕过 Core 的第二套调用入口：

```text
MCP server
  -> Runtime discovery/catalog cache
  -> schema validation + canonical MCP Tool identity
  -> Session authority/policy filter
  -> Session catalog view + generation
  -> Run admission snapshot
  -> model-visible Tool definition
  -> unified Permission decision
  -> MCP tools/call
```

要求：

- Runtime catalog 更新产生新的 catalog generation；
- 单个 server 的 transport/protocol/resource-limit 失败只形成该 server issue 并跳过，不得中止其它 server 的 catalog 构建；只有 Runtime 本地 OOM 等全局失败可以中止整个 refresh；
- active Run 继续使用 admission 时固定的 Tool view；
- 新 generation 只影响后续 Run，不在模型生成中途替换 schema；
- 已从 Session view 移除的 Tool 不得通过手工构造调用绕过可见性检查；
- cache 过期不等于自动扩大或缩小正在执行的 Run authority；
- Runtime snapshot 为每个 server 固定 `expires_at` 与 `cache_scope`：TTL 从该 server 的 discovery/list 完成时刻计算，不能从整轮 refresh 开始时刻计算；modern TTL 受 Runtime 上限约束，legacy 缺失 TTL 时使用 30 秒保守默认；
- fresh Session view 遇到过期 server 返回 `mcp_not_refreshed`，restore 则降级并失效相关 view/grant；同一过期 snapshot 不得为新 Run 投影 MCP Tool；
- 已 admitted Run 使用 admission 时形成的 immutable Environment，TTL 在执行中到期不会改变该 Run 的 Tool 集合；
- catalog refresh 失败时不得用无限期陈旧结果伪装为成功；Host 可通过 Runtime catalog description 观察 `fresh`、`cache_scope` 与 `ttl_remaining_ms` 后显式刷新；
- list/change notification 或 subscription 只能触发重新发现，不能直接修改 active Run。

### 4.6 Identity、Schema 与结果

MCP Tool identity 必须稳定地区分 server binding 与 tool name。展示名称可以面向模型或 UI 调整，但授权、审计和 restore 绑定不得依赖展示名称。

`server/discover` 返回的 `serverInfo` 是 server 自报信息，既不保证唯一也未经过协议验证。它可以参与诊断 fingerprint，但不得单独用于权限、缓存隔离、同名 Tool 消歧或 restore authority 判断；这些安全语义必须绑定 Host/Runtime 分配的 `server_binding_identity`。

候选 canonical identity 至少包含：

```text
server_binding_identity
server_identity
tool_name
tool_schema_fingerprint
```

Revision 6 不把这些字段拼成需要转义的单一 identity 字符串：C ABI 使用定长 digest/identity 字段，JSON description 使用规范化小写十六进制，Permission matcher 使用结构化 MCP identity。三种投影必须满足：

- 同名 Tool 来自不同 server 时不冲突；
- server 配置、认证隔离域或 Tool schema 变化可被识别；
- `allow_session/deny_session` 不能从一个 server/tool 漂移到另一个同名 Tool；
- checkpoint 只记录 identity/fingerprint，不记录或覆盖当前 server schema。

Schema 不是从 MCP 到模型 Provider 的一次直通复制，而是三层模型：

```text
canonical MCP schema (lossless catalog copy)
  |-- bounded validator / canonical arguments
  |-- Permission specifier and digest
  `-- provider-specific Tool projection
```

Schema 处理要求：

- `inputSchema`/`outputSchema` 在 canonical catalog 中完整、无损保存，不能像当前 bridge 一样投影为空对象；
- AgentCore 对调用参数、`outputSchema` 与 structured content 使用有资源上限的 validator；
- 无 `$schema` 时按 JSON Schema 2020-12；遇到显式 dialect 时按该 dialect 验证，unsupported dialect 产生明确诊断；
- 对 schema 深度、节点数、字符串长度、枚举项和调用参数设置上限；
- 默认不自动解引用网络 `$ref`；若未来提供 opt-in resolver，必须独立设计 allowlist、SSRF 防护、timeout、size limit 和审计；
- 不受支持、无法安全验证或超限的 schema 必须使该 Tool 不可用并产生 catalog issue，不能静默放宽为任意参数；
- Provider projection 可以是有损的，但必须有版本化 projection profile 和 diagnostics；不能宣称完整 JSON Schema 无损进入 Provider API；
- 若 projection 丢失的关键约束会使模型产生 AgentCore 无法安全验证或授权的调用，该 Tool 不进入该 Provider 的 Run view；
- Revision 6 固定使用版本化、资源受限的本地 profile，而不是完整 JSON Schema 2020-12 validator：支持 object/property、required、type、字符串/数组/对象边界、additionalProperties、dependentRequired、prefix/items，以及 string/bool/null 的 `enum/const`；
- `uniqueItems: true`、所有数值边界/`multipleOf`、数值或结构化 `enum/const`、`$ref/$dynamicRef` 与 `x-mcp-header` 在 Revision 6 都是 typed unavailable。这样避免二次复杂度、IEEE-754 精度漂移和未定义 resolver authority；
- schema 容器项数、遍历节点和 admission/validation work units 分别有硬预算；达到任一预算即产生 `schema_resource_limit`，不进入 Run view；
- schema 和 invocation JSON 在构造动态树之前先经过 O(depth) 流式结构准入；深度、节点、单容器项数或 work budget 超限时不得进入高分配 parser；
- `format` 在本地 profile 中作为 JSON Schema annotation 接纳，不声称执行 `date-time`、URI 等格式断言；
- invocation 数字在校验和 `tools/call` 重编码时都保留原始 JSON number lexeme；批准参数、digest 与发送到 server 的参数不得因 f64 转换而改变。`type: integer` 按 JSON Schema 的数学整数语义判断，因此 `1.0`、`1e3` 与超出 i64/IEEE-754 精确范围的整数不会因本地机器表示被误拒，非整数仍 fail closed；
- `outputSchema` 只约束成功结果的 `structuredContent`；`isError=true` 是 Tool 业务错误，允许只有 typed content，不能因为缺少 success payload 而改判协议错误并吞掉原错误；
- 完整 validator 若未来有真实需求，必须作为新的依赖、二进制体积和安全边界决策进入后续 ABI revision；不得把当前 bounded profile 描述成完整 2020-12 支持。

若首版包含 Streamable HTTP，还必须按规范处理 `x-mcp-header`：先验证 header name、类型和静态可达性，再从已验证参数生成 header；不得把敏感字段或任意 schema 值未经约束地投影为 HTTP header。

MCP annotations、description 和 server instructions 是不可信元数据，只能作为展示或风险判断提示，不能单独赋予 authority，也不能覆盖 Core safety policy。

### 4.7 Permission 集成

MCP 不拥有独立 Permission 系统。每次 MCP Tool 调用进入第 2 章定义的 Session 级决策链：

- `tool_identity` 包含 canonical MCP server/tool identity；
- canonical arguments digest 基于通过 schema 校验后的规范化参数；
- `allow_once` 只授权当前 MCP call；
- `allow_session/deny_session` 生成受 server/tool/schema/specifier 约束的 Session rule；
- catalog/schema/binding generation 变化后，旧 grant 必须重新验证或失效；
- explicit `deny`、explicit `ask`、Core safety 与 Sandbox 规则保持优先；
- 不在 Session/Run Tool view 中的 MCP Tool 直接拒绝，不进入 Host callback；
- server annotations 不能把高风险调用自行标记为免询问。

### 4.8 与 checkpoint/restore 的关系

checkpoint 可以记录：

- MCP server binding identity；
- Session 选择的 server/tool 集合；
- catalog generation/fingerprint；
- 与 MCP Tool 绑定的 Session grants 及 policy generation；
- 最近一次 negotiated protocol version，仅用于诊断和 restore 对账，不用于跳过重新协商。

checkpoint 不得记录：

- live transport、stdio process、socket 或 request；
- access token、refresh token、client secret 或 OAuth 临时状态；
- Runtime cache 中的可执行 client 对象；
- in-flight `tools/call`、subscription stream 或未完成外部副作用。

restore 后由 Host 重新提供 server 配置和认证，Runtime 重新执行版本协商与 discovery/catalog validation。只有 binding、schema、policy 和 authority 均兼容时，相关 Session grant 才能恢复。Server 下线、认证暂时不可用或只剩不支持的旧版本时，核心 Session 仍恢复为 degraded；相关 MCP view/grants 失效并进入 RestoreReport。

### 4.9 失败、重试与不确定结果

- `server/discover`、legacy initialize probe 和 list/read 类只读操作可以在有界预算内重试；
- `tools/call` 在能够证明请求尚未交付前可以安全重试；
- 请求已可能到达 server、但响应流在 terminal result 前断开时，外部副作用是否发生不可证明，必须返回 `outcome_indeterminate`（语义占位名，非 wire token）；
- `outcome_indeterminate` 不产生成功 Tool result、不恢复 Session grant、也不 poison 无关 Session；
- 后续重试必须是新的、经过当前 Permission 与 Host/用户确认的调用，不能由 restore 或 transport manager 盲目重放。

MCP `2026-07-28` Streamable HTTP 对 broken response stream 要求 client 以新 request ID 重发。对具有未知副作用的 `tools/call`，上述安全策略是有意的更严格限制。若 Revision 6 首版包含 Streamable HTTP，必须在 conformance 声明中明确该差异，或只在 server 提供可验证幂等机制时自动重发；在此问题关闭前不得宣称 broken-stream 路径完全 conformant。stdio 不引入该 HTTP 重发义务，但仍遵守不自动重放未完成调用的 Session 语义。

### 4.10 当前内部实现与 Revision 6 的差距

现有 `src/mcp` 可作为实现素材，但不满足 Revision 6 公共契约：

- 当前 protocol client 仍发送旧版 `2025-06-18` `initialize`；
- 当前没有 `2025-11-25`/`2026-07-28` 双 era negotiation，也不能把现有 `2025-06-18` 路径直接当作 legacy adapter；
- 当前主要是 stdio transport，不具备 `2026-07-28` 的请求级元数据与 `server/discover` 语义；
- 当前 registry bridge 丢弃 MCP `inputSchema`，动态 Tool 对模型暴露为空参数对象；
- 当前连接由 App/进程生命周期直接持有，尚未形成 Runtime catalog 与 Session view 的所有权分层；
- 现有 tools/resources/elicitation 子集不等于最新规范下已完成的 AgentCore capability。

可复用的是受测的 JSON-RPC framing、stdio 子进程管理、动态 Tool 注册和部分结果转换思路。协议状态机、catalog/schema projection、所有权和 ABI seam 必须按最新规范校正后才能接入 AgentCore。

### 4.11 MCP 明确非目标

- 兼容 `2025-11-25` 之前的 MCP revision；
- 在两个明确支持版本之外提供通用历史兼容代理；
- 把 legacy `initialize`、`notifications/initialized` 或 `Mcp-Session-Id` 暴露为 AgentCore Session 公共语义；
- 已废弃的 HTTP+SSE transport 与 SSE resumability；
- 新接入已废弃的 Roots、Sampling、Logging 能力；
- MCP Tasks extension；
- 把 Skill 包装成 MCP、MCP Apps 或 UI extension；
- 让 AgentCore 在 Revision 6 中成为 MCP server；
- 通过 MCP 恢复 active Run 或 exactly-once 外部副作用。

### 4.12 MCP 后续能力边界

- Revision 6 首版 transport 是只支持 stdio，还是同时支持最新规范的网络 transport；
- Resources、Prompts、Elicitation 的 AgentCore 公共投影与优先级；
- 是否在首版开放 `subscriptions/listen`，以及 reconnect/backpressure 边界；
- 完整 MRTR 中需要由 AgentCore 暴露的 client operation、用户输入和 retry state 范围；
- Host OAuth callback、token refresh 与多租户 isolation 的具体接口；
- 完整 JSON Schema validator、远程 resolver 与更宽 keyword profile 是否值得引入；
- 每个新增 Provider projection profile 的 exact keyword 投影；
- server/tool display naming 的产品策略；
- 尚未纳入 Revision 6 的 MCP-specific error 扩展与新 capability。

## 5. 三个目标的交叉约束

| 场景 | Permission 要求 | Session 要求 | MCP 要求 |
|---|---|---|---|
| 新建 Session | 无历史 grant | 新 logical `session_id` | 从 Runtime catalog 建立受 policy 过滤的新 view |
| 同一 Session 多 Run | `allow_session/deny_session` 可复用 | Conversation 与 `run_id` 连续 | 每个 Run 固定 admission 时的 catalog generation |
| 恢复同一 Session | Session rule 仅在 policy/binding 兼容时恢复 | logical identity 与核心状态连续；派生能力可降级 | 重建 transport、重新协商版本/discover，并核对 binding/schema fingerprint |
| Host 更新 rules | generation 递增并清除 Session rules；idle gate 保证无 active pending request | 后续 checkpoint 记录新 generation | 后续 Session view 按新 policy 重新过滤 |
| Tool/Skill/MCP identity 变化 | 旧 matcher/grant 不得误匹配 | 核心 Session 可恢复，失效 binding 进入 RestoreReport | catalog generation 更新，旧 schema grant 失效 |
| active Run 崩溃 | 未决审批失效 | 回退到最近完整 checkpoint，不自动重放 | in-flight call 不自动重放，不假定外部副作用未发生 |
| MCP server 不可用 | 相关 Session grants 失效 | Conversation 恢复为 degraded Session | view disabled，报告 unavailable；refresh 只影响后续 Run |
| MCP 版本协商 | 不改变 Permission 语义 | checkpoint 不固定 live protocol state | 首选 `2026-07-28`，只回退 `2025-11-25`，更早版本拒绝 |
| full access Session | 仍受 safety/sandbox 约束 | checkpoint 不得绕过 Host 当前禁用策略 | 仍受 server selection、schema validation 与 Runtime authority ceiling 约束 |

## 6. Revision 6 public wire freeze

Revision 6 的 public wire 已按以下内容冻结。规范性机器声明位于 `sdk/zig/types.zig`、C header 与 Rust sys binding；三者必须由 layout/conformance gate 证明一致，不允许任何 Revision 5 alias、shim 或多 revision dispatch。

### 6.1 Discovery、能力位与函数表

- `abi_version = 1`、`abi_revision = 6`、64-bit `ApiV1.struct_size = 216`；发现只接受 version、revision、table size、capability mask 全部精确匹配。
- `REQUIRED_CAPABILITIES_V1 = 0x7ffff`。Revision 6 新增 bit 12..18：`session_checkpoint`、`session_restore`、`session_describe`、`mcp_runtime_catalog`、`mcp_session_selection`、`durable_budget`、`session_permission_authority`。
- 函数表固定顺序：`runtime_create`、`runtime_destroy`、`runtime_query_skill_catalog`、`skill_catalog_release`、`runtime_refresh_mcp`、`runtime_describe_mcp`、`session_create`、`session_restore`、`session_destroy`、`session_describe`、`session_set_model`、`session_update_skills`、`session_update_permission_rules`、`session_update_mcp`、`session_run_input`、`session_abort`、`session_compact`、`session_abort_compact`、`session_export_checkpoint`、`buffer_release`。
- `SessionHostConfigV1` 只表达当前 Host authority；fresh create 通过 `SessionCreateConfigV1` 另带 model，restore 通过 `SessionRestoreConfigV1` 另带 bounded source。Host 没有写入 logical `session_id` 的入口。

### 6.2 Permission wire

- Session mode code 固定为 `default=1`、`accept_edits=2`、`auto=3`、`dont_ask=4`、`full_access=5`；不再公开 `bypass`/`bypass_permissions` token。
- callback response 固定为 `deny_once`、`deny_session`、`allow_once`、`allow_session`。`allow_always` 不存在。
- Permission request 是 flat JSON object，`type="permission"`，并携带 `request_id`、logical `session_id`、`run_id`、`tool_call_id`、`tool{namespace,name,binding}`、`canonical_arguments_digest`、`policy_generation`、原始 `arguments_json`、有序 `responses` 与可空 exact-arguments `candidate{rule_id,scope}`。
- response 是 flat JSON object：`permission`、回显 `request_id`、回显 `policy_generation`；Session-scoped response 还必须回显 candidate `rule_id`，once response 禁止携带该字段。
- `permission_provenance` 是公开 CoreEvent tag，字段固定为 decision/source/matched rule、Session/Run/tool-call/request identity、Tool identity、argument digest、policy generation、Session-rule 标记及 typed callback outcome/response。事件不包含 raw arguments 或凭证。

### 6.3 Session/checkpoint wire

- checkpoint 只通过 Host-owned `CheckpointSinkV1`/`CheckpointSourceV1` 流式传输；AgentCore 不拥有路径、数据库、加密密钥或 checkpoint buffer。export 成功才提交 `checkpoint_generation`。
- `CheckpointLimitsV1` 同时约束总字节、chunk 和各 durable section；公开硬上限为 1 GiB，总 chunk 上限为 1 MiB。超限不会截断或提交半成品。
- pre-admission budget 不足返回 `STATUS_CHECKPOINT_BUDGET_REQUIRED=18`，不消费 `run_id`；admitted Run 中途耗尽分别用 `STOP_CHECKPOINT_BUDGET_EXHAUSTED=7` 或 `STOP_CHECKPOINT_RESOURCE_LIMIT=8` 结束，并通过 `RunResultV1.checkpoint_outcome_code` 和 `result_flags` 报告。
- 新增 status 18..25 固定为 `checkpoint_budget_required`、`checkpoint_corrupt`、`checkpoint_unsupported`、`checkpoint_incompatible`、`checkpoint_io`、`logical_session_conflict`、`mcp_not_refreshed`、`invalid_mcp_selection`。
- `session_describe` 输出 `agentcore.session-description/v1`；`session_restore` 输出 `agentcore.restore-report/v1`。typed source-free DTO、枚举、hash/id 校验与 16 MiB JSON 上限位于 `sdk/zig/protocol.zig`。

### 6.4 MCP wire

- transport code 固定为 `stdio=1`、`streamable_http=2`；negotiation code 固定为 `auto=1`、`modern_only=2`、`legacy_only=3`；era code 只允许 `2026-07-28=1` 与 `2025-11-25=2`。
- Host-owned `McpConnectorV1` 提供 open/request/notify/close/release-response；AgentCore-owned Runtime 管理协商、连接生命周期、catalog generations 和 Session view。凭证及 transport handle 不进入 Session 或 checkpoint。
- `auto` 只允许规范定义的 modern-first probe；stdio 可使用 disposable probe 后单次 fallback，HTTP timeout 不降级。actual connection 必须重新验证 era，probe/actual 不一致产生 typed failure，不静默重协商。
- `runtime_describe_mcp` 输出 `agentcore.mcp-catalog/v1`，公开 server binding identity、negotiated protocol、server/catalog/schema/permission fingerprints、canonical Tool identity、`cache_scope`、`fresh`、`ttl_remaining_ms` 与 typed issue reference。Session selector只引用 `server_binding_identity + tool_name`。
- connector open/exchange/notify outcome code、cancellation descriptor、frame/schema/catalog limits均为固定 DTO/code；未知 outcome fail closed。

### 6.5 仍明确不属于 Revision 6 wire 的内容

Resources、Prompts、Elicitation、subscription、完整 MRTR client operation、AgentCore server 模式、OAuth 产品流程、exactly-once Tool replay、增量 checkpoint、完整 JSON Schema 2020-12 validator 与跨 Provider 无损 schema projection均不是 Revision 6 公共能力。后续引入必须走新的 ABI revision，不得在 Revision 6 reserved 字段或 JSON 可选字段中偷渡新的 authority。

## 7. 实施顺序

Revision 6 进入实现前，按以下顺序推进：

1. 按第 0.1 节重新分类 Revision 5 的 ABI/Wire、behavioral baseline 与 implementation detail，并关闭 old -> new 对照；
2. 冻结 Runtime/Session/Run/Host 所有权、create/run/export/restore 生命周期和三个目标的非目标；
3. 建立 AgentCore-owned 模块计划与变更范围清单；对每个拟修改的 shared Core seam 预先记录缺失能力、最小改动、受影响 caller 和验证方式，并把 `src/core/agent_loop.zig` 标记为默认禁止区；
4. 在 AgentCore-owned 内部建立唯一 Permission decision/request/response/outcome/provenance 类型和必要的窄 Core seam；
5. 在 AgentCore-owned 内部建立唯一 Session durable-state、admission/reservation budget、checkpoint sink/export、restore/report/describe seam；
6. 建立 MCP `2026-07-28` modern adapter 与 `2025-11-25` legacy adapter，汇入同一 AgentCore-owned canonical protocol seam；
7. 建立 AgentCore Runtime MCP manager/catalog、bounded schema validator、Provider projection 与 Session/Run view seam；
8. 完成 Permission × Skill/Subagent/MCP 继承矩阵及 A3/B2/E2 dispositions；
9. 完成 checkpoint durable/transient state、degraded restore、MCP binding 和外部副作用审计；
10. 完成 reference-closure、安全、所有权、并发、失败原子性、资源上限和变更范围审计；
11. 运行两个 MCP era 的 conformance tests、checkpoint 长会话测试与真实 artifact consumer gate；
12. 再设计 C ABI DTO、status、capability 和 API table；
13. 最后执行 hard-cut revision freeze，并更新 experimental ledger 的 A3、B2、C8、E2、E4、E5 disposition；E4 必须记录 legacy adapter 的单代窗口与退场条件，E5 必须保留 owner、双路径安全修复义务、触发条件和待定收敛方向。

实现顺序必须是 AgentCore-owned canonical 类型与 seam 在前、binary ABI 投影在后。这条规则不授权修改通用 agent loop：每个实施变更集都必须声明触及层级；没有 necessity record 的 shared Core 改动不得进入实现，未经单独方案和明确批准的 `src/core/agent_loop.zig` 改动直接视为范围验收失败。

## 8. 验收门槛

### 8.1 Permission

- `deny > ask > allow` 全矩阵测试；
- 五种 mode × explicit rules × Session grants 测试；
- `allow_once/deny_once` 不跨调用，`allow_session/deny_session` 只跨同一 logical Session；
- explicit `ask` 不被旧 `allow_session` 绕过，broad ask 与 narrow allow 按固定 action priority 处理；
- 新 Session 不继承 grant；restore 同一 logical Session 仅在 generation/identity/authority 兼容时恢复；
- idle rules update 原子递增 policy generation 并清除两类 Session rule；测试不得构造不存在的 active pending response 路径；
- AgentCore 路径在真实临时 Workspace 中零 settings 写盘，产品 `settings_writer` 不可达；
- `answered deny`、`user_cancelled`、`unavailable` 与 `contract_failure` 产生不同 typed outcome/provenance；
- 每次 final Permission decision 都先形成完整 provenance，再经所属 Run 的统一 EventSink 发布；`on_event` fatal 必须按普通 callback failure 中止并 poison，不能被吞并成 deny 或只留内部日志；
- callback response、Session grant mutation 与 final decision 使用两阶段 receipt：审计 storage 在 grant 前准备，receipt 只在 authoritative `policy_decision` 到达后以实际 allowed/denied 结果提交；budget/grant 失败不得留下“audit allow / execution deny”分叉；
- 批准参数与执行参数 digest 不一致时拒绝执行；
- MCP、Host Tool、内置 Tool 使用同一 identity/matcher 路径；
- Skill/Subagent 不得扩大父 authority；
- Permission allow 不得扩大 Sandbox authority；
- 不同 Session 并发时授权状态完全隔离。

### 8.2 Session checkpoint/restore

- Text、Tool、Skill 和 Compact 后 Conversation round-trip 等价；
- logical `session_id` 与 last admitted `run_id` 正确恢复；
- fresh logical `session_id` 由 Core 分配，restore ID 只能来自 checkpoint，Host 不能任意覆盖；
- 恢复后下一 Run 延续 Conversation，且 `run_id` 仍严格递增；
- API key、callback、pointer、live job 不进入 checkpoint；
- live background job 或未完成外部 request 存在时 checkpoint export 返回 `BUSY`，Revision 6 不存在 activity ownership transfer 例外；
- corrupt、oversized、unsupported 和 incompatible checkpoint fail closed；
- restore 失败不发布 Handle、不注册残留 Session ID；
- active Session 无法 export；
- 同一 Runtime 中 logical Session ID 冲突被拒绝；
- Tool/Skill/policy binding 变化不会恢复旧 authority；
- checkpoint 中的 Session grant 不得绕过当前 explicit deny/ask；
- 长 Conversation 在协商预算内可经 sink/chunk 导出；budget 小于最小 terminal/error record 时 Session create/restore 失败；
- restore 不要求为“下一次 Run”预留空间；近满但合法的 checkpoint 可恢复/describe，并可通过 replacement-aware compact 把 summary + active messages 收敛为更小 checkpoint；
- pre-admission budget 不足不消费 `run_id`、不修改 Conversation，Host 可在独立 compact 后重试原输入；
- Text prompt 与 Skill canonical invocation record 使用同一精确 pre-admission 预算路径；Skill 动态 body expansion 在 admitted Run 内、Conversation mutation 前原子对账，禁止整块预留 `input_cap_bytes`，也禁止把 materialization/shell 注入提前到 admission 前；
- admitted Run 在每次 Provider/Tool/MCP 调用前完成 durable reservation；不足时不发起该外部调用，以有界 terminal marker 结束并保持 Session 可 checkpoint；
- reservation profile 在 hard cap、per-operation cap 和 Host budget 边界上有确定性测试；常规有界结果与代表性长会话不得因为协议理论最大 payload 被提前判定 budget exhausted；
- 超限 Provider/Tool/MCP payload 不进入 Conversation 原文，而形成有界 resource-limit outcome；
- MCP server 下线、认证暂不可用或 Skill 缺失时，Conversation 恢复成功并返回 degraded RestoreReport；
- `session_describe`/Runtime query 对所有 Host-visible identifiers 完成 reference closure；
- checksum 与 Host authenticity/MAC 职责有独立测试，不把结构完整性冒充可信来源；
- artifact consumer 能完成 export -> 持久化 -> 进程重建 -> restore -> 后续 Run 的完整链路。

### 8.3 MCP

- `modern_only` 只接受 `2026-07-28`；`legacy_only` 直接 initialize 且只接受 `2025-11-25`；`auto` 优先 modern probe；
- stdio `auto` 使用 disposable process；格式正确的 `MethodNotFound`、probe child 退出和有界 timeout 触发且仅触发 `2025-11-25` fallback，probe process 被回收；
- probe 与真正 transport 的 era 一致时才能完成 binding；server 两次启动间更新、identity/era 不一致或行为不确定时返回 typed negotiation failure，不重新 probe、不静默切换或降级；
- HTTP timeout/network error、401/403、5xx、损坏响应和现代协议错误不触发 fallback；negotiated version 与 fallback reason 对 Host 可见；
- 任一 policy 最终遇到 `2025-06-18` 或更早 revision 都明确失败；
- modern 请求携带规范要求的 `_meta` 且 `server/discover` 结果经过校验；legacy initialize/session state 只存在于 Runtime adapter；
- 两个 era 的 `tools/list/tools/call` 投影到相同 canonical Tool identity、catalog 和 result；
- `tools/list` 的完整 input/output schema 无损进入 canonical catalog；Provider projection 的有损字段、拒绝原因与 profile 可观测；
- JSON Schema 2020-12 默认 dialect、显式 dialect、非法、超深、超大和外部引用场景均有边界测试；动态树分配前的流式 depth/node/container/work admission 有确定性边界测试；bounded profile 对 `uniqueItems`、数值约束/枚举和 validation work budget 有确定性 fail-closed 测试；
- `type: integer` 以 exact number lexeme 验证 `1`、`1.0`、`1e3`、大整数和负例，不以 Zig `integer/float` tag 或 i64 范围冒充 JSON Schema 数学语义；
- `2026-07-28` 缺失 required `resultType` 失败，`2025-11-25` 缺失时规范化为 `complete`；typed/structured content 与协议错误均有测试；
- `isError=true` 的业务错误不要求 success `structuredContent`；text/image/audio/resource link/embedded resource 保持 canonical 无损；
- 未声明 MRTR 时收到 `input_required` 返回 `input_required_unsupported` 语义结果，不重试、不提交 partial result，且 Session 可复用；
- modern `ttlMs/cacheScope`、legacy 30 秒保守 TTL、Runtime TTL cap、catalog generation、过期和刷新失败语义有注入时钟的确定性测试；新 Run 不接纳过期 Tool，已 admitted Run view 不漂移；
- MCP Tool 使用与内置/Host Tool 相同的 Permission identity、argument digest 和审计路径；
- 不同 Session 的 server/tool selection 与 grants 完全隔离；
- active Run 的 Tool view 不因并发 catalog refresh 变化；
- abort、timeout、transport failure 和 server process exit 不 poison 无关 Session；
- 已交付但丢失 terminal response 的 `tools/call` 返回 `outcome_indeterminate` 语义结果，不盲目重放；
- checkpoint 不包含 token、transport、process 或 in-flight request；
- restore 后重新协商/discover，binding/schema 漂移或 server unavailable 使相关 view/grant 失效并报告 degraded，不阻断核心 Session；
- artifact consumer 能完成 server binding -> discovery -> Session selection -> Run tool call -> checkpoint -> Runtime 重建 -> restore -> 后续调用的完整链路。

### 8.4 AgentCore hard cut 与变更范围

- bundle 和函数表只接受 `abi_revision == 6`；Revision 5 及更早调用方在 revision 校验处明确失败，不得进入旧 layout 的偶然解释路径；
- 产物中不存在旧函数表、旧 DTO layout、旧 status/token alias、compatibility shim、双 revision dispatch 或运行时 revision 猜测；
- 第 0.2 节 old -> new 对照只用于消费方显式迁移，不对应任何兼容代码或回退测试；
- 默认实现 diff 只触及 `src/agentcore/**`、AgentCore 专属测试、header/bundle artifact 和设计文档；
- 任一 shared Core 改动均附带 necessity record、受影响 caller 清单和 L2 回归测试，且不得把 AgentCore 专属 lifecycle、wire 或 persistence policy 变成全局产品行为；
- 未经独立设计论证和明确批准，`src/core/agent_loop.zig`、Provider turn loop、通用 Tool execution 与 CLI/TUI/Web 产品层保持零 diff；
- 现有 CLI/App 路径的行为和测试基线不因 Revision 6 改变；
- Ledger E5 明确登记 CLI/App 与 AgentCore 的 Permission/MCP 并行语义路径、owner、双路径安全修复义务、触发条件和待定收敛方向；该登记不扩大 Revision 6 实现范围；
- MCP `2025-11-25` adapter 只提供外部协议互操作，不暴露或恢复任何旧 AgentCore ABI。

### 8.5 最终 conformance、reference closure 与交付证据

2026-08-03 的初始矩阵与 2026-08-04 的增量架构收口结果如下。专项行使用 `PASS` 或当前精确计数；全量 gate 必须覆盖全部专项矩阵：

| 门禁 | 结果 | 覆盖重点 |
|---|---:|---|
| `agentcore:test -Dtfilter="Revision 6 Permission"` | PASS | deny/ask/allow action priority、五种 mode、once/Session grant、fresh Session 隔离、generation、restore、规则替换、child authority、typed callback outcome、零 settings 写盘 |
| shared Permission provenance/ceiling tests | PASS | null seam inert；settings、Session memory、Core safety 与 active Skill 来源完整；consumer override 不能放宽 explicit deny 或 shared authority ceiling；callback receipt 在 grant 前准备并以 final policy result 提交 |
| `agentcore:test -Dtfilter="MCP"` | PASS | modern/legacy canonical projection、auto/modern_only/legacy_only、stdio disposable probe、HTTP 禁止降级、actual-era revalidation、两页 `tools/list` 无损合并及保守 cache policy、schema/Permission/Session/checkpoint 绑定 |
| MCP freshness/schema budget tests | PASS | 注入时钟验证 TTL/default/cap；过期 view 的新 Run 排除、active Run 不漂移；schema 在动态树分配前执行 container/node/depth/work admission；数学 integer lexeme 与 unsupported semantics fail closed |
| `agentcore:test -Dtfilter="checkpoint"` | 16/16 | 长 Conversation、compact 投影、summary 恢复消息数上限、chunk/byte 边界、budget admission/reservation、corrupt/unsupported、authority revalidation、degraded restore |
| Text/Skill unified root admission tests | PASS | 精确 canonical invocation preflight；admitted effectful expansion 原子对账；拒绝不消费 `run_id`、不改 Conversation、不预留整块 input cap |
| `agentcore:test -Dtfilter="public MCP checkpoint restore"` | 1/1 | public ABI 下 MCP catalog -> Session selection -> Run -> checkpoint -> narrower restore -> continued Run，并执行 identifier reference closure 断言 |
| `agentcore:consumer -Dtarget=x86_64-windows-msvc` | 18/18 | 无源码 C consumer；无源码 Zig consumer 完成 tools -> checkpoint -> Runtime 重建 -> restore -> continued Run |
| `agentcore:gate -Dtarget=x86_64-windows-msvc` | 42/42 steps；217/217 tests（2026-08-04） | C/C++/Zig/Rust exact R6 discovery、symbol/manifest、原生 consumer 与全量 ABI 回归 |
| `agentcore:archive -Dtarget=x86_64-windows-msvc` | PASS（2026-08-04，6/6 self-tests） | immutable archive、coordinate root、hash、identity、拒绝覆盖和错误 payload |

Host-visible identifier 的 reference-closure audit 结论：

| Identifier | 产生位置 | 规范化解析/对账位置 | conformance 断言 |
|---|---|---|---|
| logical `session_id` | callback `RunContextV1`、Session create/restore | `session_describe`、`RestoreReport` | checkpoint 前后 ID 相同，恢复后新物理 Handle 的 callback 仍解析为同一 logical ID |
| `run_id` | Host 调用、callback context、Run result | `session_describe.last_run_id` | restore 后 last ID 可见，下一 Run 严格递增 |
| `policy_generation` | Permission request/provenance、checkpoint | `session_describe`、`RestoreReport` | request/response 回显绑定；report 与 describe 相等 |
| `catalog_generation` | `runtime_refresh_mcp` result | `runtime_describe_mcp`、`session_describe`、`RestoreReport` | Runtime catalog、restore report 与 Session description 相等 |
| `checkpoint_generation` | export result | `session_describe`、`RestoreReport` | export、report 与 describe 三方相等，只在 sink 成功后递增 |
| `server_binding_identity` | Runtime MCP catalog | catalog Tool、Session MCP view、RestoreReport/Session issue | server/tool identity 相等；degraded issue 回指原 catalog binding |
| authority/catalog `issue_id` | Runtime refresh 或 restore reconciliation | Runtime catalog、`RestoreReport`、`session_describe.restore.issues` | RestoreReport 与 Session description 暴露同一稳定 issue identity 和 binding |

scope audit 以 `e043575` 为 Revision 6 基线：允许范围外只有第 0.4 节登记的四个 shared Core seam；`src/core/agent_loop.zig`、产品层和旧 `src/mcp` 均为零 diff。hard-cut symbol gate 与 source-free consumers 证明 Revision 5 table、DTO、alias、shim 和 multi-revision dispatch 不存在。

## 9. 当前结论

Revision 6 当前确认三个目标：

1. 把已有 Permission 能力完善为严格、可解释、参数受限、Session-scoped 的公共授权契约；
2. 把已有内存态 Session 完善为可由 Host 持久化并在 idle checkpoint 边界恢复的逻辑 Session；
3. 以 MCP `2026-07-28` 为首选、`2025-11-25` 为唯一兼容协议提供标准 MCP Tool 消费能力，并把版本差异限制在 Runtime adapter，统一纳入 catalog、Session authority 与 Run admission。

Permission 不负责 Sandbox，Session restore 不负责存储系统，MCP transport 不等同于 AgentCore Session。三者通过 logical Session identity、policy generation、catalog generation 和 authority compatibility 形成统一安全边界。

评审中采纳的 revision discipline、degraded restore、schema projection、typed callback outcome 和 reference closure 都是这三个目标的横切闭合条件，不构成第四个目标。

Revision 6 对 AgentCore ABI 是完全 hard cut，不提供任何旧 revision 兼容；实现默认收敛在 AgentCore-owned 层，`agent_loop` 等通用执行层不属于本方案修改范围。MCP `2025-11-25` 的单代 adapter 是外部协议互操作，不改变这两个约束。

Revision 6 的三个目标、exact wire、默认值、DTO、跨语言 SDK、source-free consumer 和 conformance/governance 门均已闭合。后续能力必须进入新的显式 ABI revision，不得继续修改 Revision 6 reserved 字段或 JSON wire。CLI/App 与 AgentCore 的并行语义路径作为 Ledger E5 的显式债务继续管理，不能以“消债”为由回改本 revision 或扩大其实现范围。

## 10. 参考依据（非规范性）

本草案没有把外部产品的 API 直接复制为 AgentCore wire contract，但参考了其已经验证的职责划分：

- [Claude Code permissions](https://code.claude.com/docs/en/permissions)：`deny/ask/allow` 规则、显式询问、permission mode 与 Sandbox 分层；
- [OpenAI Agents SDK sessions](https://openai.github.io/openai-agents-python/sessions/)：跨 Run Conversation、可替换持久化后端和 Session 历史管理；
- [Microsoft Agent Framework sessions](https://learn.microsoft.com/en-us/agent-framework/agents/conversations/session)：Session serialization/restore 以及 Agent/Provider 兼容性约束；
- [Microsoft Agent Framework self-hosting](https://learn.microsoft.com/en-us/agent-framework/hosting/self-hosting)：SessionStore、HistoryProvider 与 Host 存储职责分离；
- [LangGraph persistence](https://docs.langchain.com/oss/python/langgraph/persistence)：logical thread、checkpoint boundary、state inspection 和 fault-tolerance；
- [LangGraph durable execution](https://docs.langchain.com/oss/python/langgraph/functional-api)：恢复时的确定性、幂等性和外部副作用边界；
- `AGENTCORE_V1_EXPERIMENTAL_LEDGER.md`：A3（AgentCore 零写盘与 Session token）、B2（cancelled 与 unavailable）、C8（Conversation export）、E2（decision provenance）、E4（stability horizon）和 E5（CLI/App 与 AgentCore 并行语义路径）；
- [MCP 2026-07-28 specification](https://modelcontextprotocol.io/specification/2026-07-28)：Revision 6 的主协议与未来架构基线；
- [MCP 2025-11-25 specification](https://modelcontextprotocol.io/specification/2025-11-25)：Revision 6 唯一兼容协议；
- [MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)：无状态协议、discovery、request metadata、result type、cache 和 subscription 等变更依据；
- [MCP versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)：协议 revision 与 latest stable 规则；
- [MCP tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)：Tool discovery/call、MRTR、schema、typed result 与安全要求；
- [MCP deprecated features](https://modelcontextprotocol.io/specification/2026-07-28/deprecated)：Revision 6 不接入旧 transport 和已废弃能力的依据；
- [MCP TypeScript SDK 2026-07-28 migration](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/migration/support-2026-07-28.md)：modern/legacy 双 era negotiation 与单代兼容的生态依据；
- [MCP Go SDK releases](https://github.com/modelcontextprotocol/go-sdk/releases)：新版协议发布窗口、fallback 与生态迁移状态的参考。

这些参考支持的是架构原则，不意味着 Revision 6 必须引入 workflow graph、AgentCore-owned storage 或对方的命名与 wire layout。
