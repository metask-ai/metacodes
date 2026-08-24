# MULTI_SESSION_REFACTOR — 会话显式化重构设计

> 历史设计快照。当前源码已经实现 `agent_session.AgentRuntime`、
> `RuntimeHost` 与 per-Session 生命周期；本文的“当前架构”段落不应当作为现状判断。
> 现行接口请看 [CORE_REFERENCE](CORE_REFERENCE.md) 和 [LIB_API](LIB_API.md)。

> 目标：把 cc-zig (metacodes-core) 从"单进程单 Session、会话隐含在调用栈"重构为"单进程多 Session、会话显式"，以支撑未来 GUI 产品（一个进程多个并发会话，各有独立 UI 视图）。TUI 行为必须零回归（TUI 是多 Session 架构下"N=1"的特例）。

## 0. 背景与事实基线（已 code 核实）

当前架构是**彻底的单 Session**：

- **App 是单例**（`src/app.zig` `pub const App`）：一个 App 持单个 `conversation`/`read_state`/`jobs`/`agent_jobs`/`tasks`/`mcp_sessions`。无 `sessions` map。
- **协议层 vtable 设计良好但缺 Session 维度**（`src/core/protocol/`）：`UiBackend.emit/poll` 只有 `(ctx, ev)`；`CoreEvent`/`UiEvent` 变体不带 session 标识；`UiRequest`（ask_question/permission/plan_approval）是**同步阻塞**。
- **散落的全局可变状态会串台**（grep `^var g_` / `^pub var` 实锤）：
  - `permission/prompt.zig`：`g_always_allow`/`g_session_deny`/`g_buf`（注释写"session 级"实为进程全局）、`g_project_dir`/`g_home`（`setPersistContext` 全局覆盖）、`g_ui_runner`/`g_ui_runner_state`（`setDialogRunner` 全局，指向 TuiBackend 栈实例 → 多 session UAF）。
  - `app.zig`：`g_abort_signal`（单一 SIGINT handler → Ctrl+C 杀所有 session）。
  - `tools/common.zig`：`g_progress_cb`（Bash 进度全局回调，repl 层设）。
  - `recorder.zig`：`g_seq`/`g_sse_buf`（录制全局，多 session 文件名错序，仅调试路径）。
  - `answer_queue.zig`：`g_answers`/`g_pos`（headless 应答队列全局，e2e 路径）。

**已经做对、不动的**：
- `UiBackend` vtable 已为进程外 backend（WsBackend，序列化传输）预留。
- 后台 subagent（`agent_job_registry`）每 job 独立 Thread+Client+mutex+join，隔离优秀。
- `AbortSignal` 本身 per-run atomic，隔离良好（问题在全局 SIGINT 入口）。
- `agent_loop.run()` **不假设自己是主线程**（调用方在哪线程就在哪跑）→ 多 run() 多线程并发本身可行。这是关键好消息：改造集中在协议路由 + 全局状态，**不在循环本身**。

**只有 WebSearch 一个工具用主 `ctx.api_client`**（Agent/subagent 已各自独立 Client）。api_client 并发是窄问题，非普遍危险。

## 1. 目标架构（会话显式化）

```
进程
├── ProcessContainer（进程级，只读/共享）
│   ├── allocator
│   ├── api_client: *Client          （共享；HTTP 并发需验证或 per-session）
│   ├── tool_defs: []ToolDefinition   （只读）
│   ├── agents: AgentSet              （只读）
│   ├── skills: SkillSet              （只读）
│   ├── dyn_registry: DynRegistry     （Skill/MCP，只读激活）
│   ├── sandbox: SandboxSettings      （只读策略）
│   └── sessions: HashMap<SessionId, *SessionContext>
│
└── SessionContext（每会话一份，可变）
    ├── session_id: SessionId         （distinct type，见 §2）
    ├── conversation: Conversation
    ├── read_state: ReadState
    ├── edit_hl_cache: EditHlCache
    ├── jobs: JobRegistry             （Bash 后台，per-session 隔离）
    ├── agent_jobs: AgentJobRegistry
    ├── tasks: TaskStore
    ├── cron_registry: CronRegistry
    ├── mcp_sessions: []McpSessionEntry
    ├── abort: AbortSignal            （per-session 独立中断）
    ├── permission_ctx: PermissionContext（含 session 级 allow/deny 记忆，§5）
    ├── plan_prev_mode / plan_file_path
    ├── cwd_abs / project_dir / home_dir / parent_model
    └── backend: *UiBackend           （或经 session_id 路由到多路 backend）
```

**SessionId 用 distinct type**（`enum(u64){ _ }` 或带长度的固定数组 key），防止与普通字符串/其它 id 混淆（对齐项目"distinct types 防 ID 混淆"原则）。

## 2. 模块分解（metaknow 里逐个对应，coding 按此顺序）

设计拆成 **7 个模块**，每个独立可编码、可 Linus-review、可验证不回归 TUI。顺序经过依赖排序：**先做不破坏 TUI 的全局态清理（低风险打底），再做协议加维度，最后做 App 拆分（高风险反转）**。

### M1. SessionId 类型 + 全局态盘点冻结
- 新建 `src/core/session_id.zig`：`pub const SessionId = enum(u64){ _ }` + `fromString`/`toString`（基于现有 genSessionId 的 hash）。
- 不改行为，只引入类型 + 在 transcript/Options 里把 `session_id: []const u8` 逐步换成 `SessionId`（保留 string 边界用于持久化路径）。
- **验证**：编译 + 全测试绿（纯类型引入，零行为变化）。

### M2. permission/prompt.zig 全局态 → PermissionContext
- 把 `g_always_allow`/`g_session_deny`/`g_buf` 搬进 `PermissionContext`（已是 per-session 候选，`permission.zig`）。`remember()`/查询改成 `ctx` 方法。
- `g_project_dir`/`g_home`（`setPersistContext`）→ `PermissionContext` 字段，权限询问时从 ctx 读。
- `g_ui_runner`/`g_ui_runner_state`（`setDialogRunner`）→ 这是 UI 回调，移到 `ToolContext.ui_request_fn`/`ui_request_state`（**已存在**！只需把 permission 询问从全局回调改走 ctx 上的回调）。删 `setDialogRunner`/`clearDialogRunner`。
- **验证**：权限 e2e（component compound_perm/protected_skill + tty 权限框）。这是 core 库内最毒的串台源，优先清。

### M3. tools/common.zig g_progress_cb → ToolContext
- `g_progress_cb` 全局回调 → `ToolContext` 字段（progress_state/progress_fn **已存在**，Bash 的进度走它而非全局）。
- 删 `repl/progress.zig` 的 `common.g_progress_cb = …` 设置点，改在 backend 接线时挂 ctx。
- **验证**：Bash 长命令 progress tty 实测。

### M4. CoreEvent/UiEvent 加 session 维度
- **决策**：用 **emit/poll 签名加 `session_id` 参数**（而非每个事件变体塞字段）——更显式、序列化时不重复、改动集中在 vtable + 调用点。
  ```zig
  emit: *const fn (ctx, session_id: SessionId, ev: CoreEvent) void,
  poll: *const fn (ctx, session_id: SessionId) ?UiEvent,
  ```
- agent_loop 的所有 `backend.emitEvent(ev)` → `backend.emitEvent(self.session_id, ev)`。
- TuiBackend（N=1）忽略 session_id 或断言==唯一会话；未来 GuiBackend 据此路由到对应视图。
- **验证**：TUI 字节零回归（emitEvent 多一个参数，TuiBackend 不用它）；mock backend 多 session 断言事件按 id 分流。

### M5. UiRequest 同步阻塞 → 异步请求-响应
- **这是最深的一步**（控制流模型变更）。`UiRequest` 加 `request_id: u64` + `session_id`。
- vtable 拆成：`sendRequest(ctx, req) -> request_id`（非阻塞，进队）+ `pollResponse(ctx, request_id) -> ?UiResponse`（非阻塞）。
- agent_loop/工具在等 UI 响应时**让出而非阻塞**：发 request → 轮询 pollResponse（让 abort 检查 + 其它 session 可跑）→ 拿到 response 继续。
- **TUI 适配（保 N=1 行为）**：TuiBackend 的 sendRequest 仍可同步弹框拿结果立即 pollResponse 返回（单会话独占终端，行为等价旧同步）；多会话 GuiBackend 真异步排队。
- **验证**：plan_approval/ask_question/permission tty e2e 全过 + 单 session 行为不变；mock 验两 session 并发请求不互相阻塞。

### M6. registry per-session 化 + App 拆 ProcessContainer/SessionContext
- 抽 `SessionContext`（§1），把 App 的 per-session 字段搬进去。App 退化成 ProcessContainer + `sessions` map。
- registry 改 per-session init/own（JobRegistry/AgentJobRegistry/TaskStore/CronRegistry/ReadState/EditHlCache 各 session 一份）。
- `agent_loop.run()` 签名：传 `*SessionContext` 而非散落的 Options 字段（Options 瘦身：只留 per-call 的 max_turns/verbose/model_override 等）。
- **验证**：TUI 走 N=1（建一个 session）全绿；refAllDecls 库隔离仍成立。

### M7. SIGINT/abort session 路由 + 收尾
- `g_abort_signal` 单一 → ProcessContainer 持前台 session 指针；SIGINT handler 只设标志，主循环按前台 session 设 abort（后台 session 继续）。
- `recorder`/`answer_queue` 的全局态：调试/e2e 路径，低优先级。recorder 文件名嵌 session_id；answer_queue 暂可保留（headless 单 session）或 per-session。
- **验证**：单 session Ctrl+C 行为不变；（多 session GUI 集成时再验前台路由，本重构留好接口即可）。

## 3. 关键设计决策（取舍记录）

- **D1 emit 加参数 vs 事件塞字段**：选签名加 `session_id` 参数。理由：事件变体多（10+），逐个塞字段 churn 大且序列化重复；签名加参数集中在 vtable，TuiBackend 忽略即可。
- **D2 UiRequest 异步**：必须异步。同步阻塞在多会话下，A 弹框冻结 B。但 TuiBackend 保留"同步弹框"实现（sendRequest 内立即拿结果），让 N=1 行为零变化——异步是协议能力，TUI 用同步特例。
- **D3 App 拆分放最后**：M6 是高风险反转（牵动 run 签名、所有工具 ctx 来源）。前面 M2-M5 先把全局态和协议清理好（都不破坏 TUI），最后一次性反转 App，降低"中途半成品破坏 TUI"的风险。
- **D4 共享 vs per-session**：只读的 tool_defs/agents/skills/dyn_registry/sandbox 留 ProcessContainer 共享；所有可变会话状态 per-session。api_client 先共享（WebSearch 并发风险窄），M6 时评估是否 per-session Client。
- **D5 SessionId distinct type**：防 id 混淆，对齐项目 Make-Illegal-States-Unrepresentable。

## 4. 验证总纲

每个模块完成后：
1. `zig build`（编译）+ `zig build test`（cc-test 单测，除已知无-tty 的 AskUserQuestion 渲染测试）。
2. `zig build test:new`（component L2，failed-command 应保持基线 5 网络失败数）。
3. `zig build test:lib`（库 UI 隔离 refAllDecls 仍成立）。
4. 相关 tty e2e（权限/plan/progress 真模型，区分模型漂移 SkipTest vs regression）。
5. **Linus 级 review**（用 linus skill），改到通过才进下一模块。

**TUI 零回归是硬约束**：每步后 TUI 必须按 N=1 正常跑（字节级关键路径不变）。

## 5. 风险与回退

- **M5（异步 UiRequest）风险最高**：控制流从阻塞改让出，易引入"等不到响应死循环"或"响应丢失"。缓解：TuiBackend 同步特例先保 TUI；mock 双 session 测并发不阻塞；超时兜底。
- **M6（App 拆分）churn 最大**：run 签名变、所有工具 ctx 溯源变。缓解：SessionContext 先与 App 并存（App 内嵌一个 default session），逐步迁移，而非一次性删 App 字段。
- 每模块独立 commit，可单独回退。

## 6. 不做（本重构范围外）

- 不做跨进程 WsBackend 实现（只保证协议可序列化，留接口）。
- 不做 GUI 前端（只把 core 改成多 session-ready）。
- recorder/answer_queue 的全局态仅在不影响生产多 session 时保留（调试/e2e 路径，最低优先级）。

---

## 实现记录(M1-M7 完成,含对本设计的修正)

实施时三次基于"读完调用链/事实"修正了本设计(都经 Linus review + 用户确认),记录如下,本节为最终真理:

- **M1**(SessionId 抽模块):缩回纯抽取,删了投机性 eql/fromSlice(YAGNI,M5/M6 真需要时再加)。
- **M2**(permission 全局态):session_rules/ui-runner 进 PermissionContext;persist 复用 match_ctx(删冗余 g_project_dir/g_home);ask 签名 *const→*(去 const 谎言)。
- **M3**(g_progress_cb):进 ToolContext.spawn_tick_fn;顺手修 tick 硬编码 "bash"→basename(argv[0])。
- **M4**(emit/poll 加 session):session 放**签名**(envelope)非每事件字段(D1);SessionId.single sentinel。
- **M5 修正**:doc 原写"同步→异步(request_id+poll)"。**推翻**——同步不是多-session 障碍(工具调 requestUi 本须阻塞自己线程;并发隔离归 M6 per-session 线程;唯一共享是 TUI 单终端=N=1)。改轻:仅给 UiRequestFn 加 session 参数,保持同步。避免在有真线程时手搓协作调度器。
- **M6 修正**:doc 原写"物理拆 SessionContext struct + sessions HashMap"。**不物理拆**——app.X 几百处引用,搬字段=零能力增益高风险 churn(premature refactoring)。改交付**能力前提**:App.session_id 身份 + 路由接线 + 字段分区注释(地图)。**关键事实**:多 session 真障碍是进程全局(M1-M5 已全清),App.init 无全局副作用→多 App 实例天然可共存=多 session。
- **M7 修正**:doc 原写"SIGINT 路由到前台会话"。**不做**——abort 早已 per-session(App.abort);SIGINT 是 TUI N=1 的桥(正确);GUI 旁路 SIGINT 直调 app.abort.abort()。"路由到前台"是 phantom requirement。

### 最终状态:multi-session **READY**,非 **DONE**

- ✅ 已达成:所有会串台的进程全局清除(permission/progress/ui-runner);会话身份(SessionId);emit/UiRequest 按 session 路由(测试验非默认 session 端到端);abort per-session 隔离(测试验);多 App 实例可共存不串台(init 无全局副作用)。
- ⬜ 留给 GUI 集成(非本重构):sessions HashMap + 多线程跑多个 App + ProcessContainer 提取共享只读资源(tool_defs/skills/agents;client 建议 per-session)。现状仍一进程一 App 一 session。

### 遗留 TODO
- Grep/Edit component 测试写死 /tmp fixture,并发 test artifact 撞车致 flaky(pre-existing,非本重构;应改 mkdtemp)。
- App.session_id 与 transcript 目录 id 是两个独立 gen(),将来统一。
