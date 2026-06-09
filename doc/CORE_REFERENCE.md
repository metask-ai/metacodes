# metacodes-core — 架构参考

> 面向在 core 之上构建前端的开发者:GUI、语音、IM 机器人、Web、工作流、嵌入式实体按钮。
> 快速接入(装依赖 + 跑 example)见 `doc/LIB_API.md`;本文是**架构契约 + 设计不变式**参考。
>
> 字段级 API 以源码为准(本文与源码同步于 2026-06-09);模块名 `metacodes_core`,
> `@import("metacodes-core")`。版本 `lib.VERSION = "0.1.0"`。

---

## 1. 定位:core 是 agent 平台内核

metacodes-core 是一个**无 UI、无 CLI** 的 LLM 编码-agent 引擎。它把"对话 → 调 Claude API →
执行工具 → 回灌结果 → 再对话"这个循环连同工具集、权限、subagent、持久化封装成库,**所有前端
表达(终端/GUI/语音/IM/…)都由 core 之外的 backend 提供**。

一句话契约:**你实现一个 `UiBackend`(2 个函数指针),把它 + 一个 `Conversation` + 一个
`Client` 交给 `agent_loop.run()`,core 就跑完整 agent 回合,所有"该显示什么/该问用户什么"
经协议事件交给你的 backend。**

### 1.1 四条 load-bearing 设计不变式(前端开发者必须知道)

1. **core↔UI 物理隔离**。`src/lib.zig` 可达的模块图够不到 `repl/`、`tui/`、`app.zig`、
   `main.zig`。`zig build test:lib`(refAllDecls 编全图)是**编译器证明**——前端再多,core
   不被污染,core 不依赖任何前端。

2. **窄腰协议(narrow waist)**。core↔UI 全部走 `UiBackend` 的 **emit/poll 两个函数指针** +
   一个**全可序列化**的 `CoreEvent`/`UiEvent` union。无指针、无闭包穿过协议 → 同一协议可进程内
   (直调)也可进程外(序列化经 WebSocket/gRPC,见 §6.4)。

3. **thread-per-session**。`run()` 不假设主线程——调用方在哪个线程跑,它就在哪跑。一个 backend
   实例可多路复用 N 个 session(emit/poll 带 `SessionId` 路由);N 个并发对话 = N 个 `run()`
   线程。同步阻塞(如等用户答话)只阻塞该 session 自己的线程,不影响其他 session。

4. **类型安全的接线面**。core 需要回调到宿主的地方(进度、token、UI 请求、skill 激活、worktree)
   全部是**接口 struct**(`{ctx: *anyopaque, fn}` + method),不是裸函数指针对——接错配对编译失败,
   不会运行时 UAF。

---

## 2. 模块地图与依赖方向

依赖**单向向下**,无循环、无层级倒置:

```
   前端层 (NOT in core)         repl/ · tui/ · app.zig · main.zig
        │  仅经 UiBackend + CoreEvent/UiEvent/UiRequest 通信
        ▼
   ┌─────────────────────────── metacodes-core ───────────────────────────┐
   │  协议层   core/protocol/  ui_backend · ui_event · ui_request           │
   │              (窄腰;前端只需实现/消费这几个)                              │
   │  引擎层   core/  agent_loop · conversation · message · subagent         │
   │              tool_exec · transcript · session_id · system_prompt        │
   │  能力层   tools.zig + tools/* · permission* · agents/* · skills/*        │
   │              mcp/* · sandbox/* · 各 registry(task/job/agent_job/cron)   │
   │  基础层   client · api/stream · json · types · util/*                    │
   └────────────────────────────────────────────────────────────────────────┘
```

`lib.zig` 是唯一对外面,按命名空间 re-export。分组:引擎 / API·client·配置 / 工具 /
权限 / agents·skills·mcp·sandbox / **协议** / 参考 backend / 工具库。

### 2.1 模块职责速查

| 模块 | 职责 | 关键导出 |
|------|------|----------|
| `agent_loop` | 一个 agent 回合的完整循环:流式请求→收 tool_use→执行→回灌→再循环 | `run()`, `Options`, `RunResult`, `StopReason`, `UsageSink`, `ProgressReporter` |
| `conversation` / `message` | 对话状态(messages → blocks);压缩/microcompact | `Conversation`, `Message`, `Block`(text/tool_use/tool_result/thinking) |
| `subagent` | 父 agent spawn 子 agent(隔离 Conversation + TaskStore) | `spawnAgent`, `spawnAgentSink`, `SpawnOptions`, `SubagentResult` |
| `tool_exec` | 工具批量执行(按并发安全分批;每 job 独立 arena + per-worker 值拷贝 ctx) | `executeSlots`, `Slot` |
| `tools` | 工具注册表 + dispatch(静态 + 动态 Skill/MCP) | `dispatch`, `registry`, `isConcurrencySafe(Input)` |
| `tools/context` | `ToolContext`——工具执行时拿到的全部依赖 + 接口回调 | `ToolContext`, `SkillActivator`, `ToolActivator`, `WorktreeHook`, `ToolProgressReporter` |
| `transcript` | 对话持久化(JSONL per-turn)+ 重建 | `Writer`, `loadTranscript` |
| `session_id` | session 身份值类型(多 session 基石) | `SessionId`, `.single`, `gen()` |
| `permission*` | 权限决策链(模式 + 规则 + 沙箱 + UI 请求) | `PermissionContext`, decision/settings/session_rules |
| `agents` / `skills` / `mcp` / `sandbox` | subagent 定义 / Skill / MCP 客户端 / Seatbelt 沙箱 | `AgentSet`, `SkillSet`, `mcp_client`, `sandbox_config` |
| registries | task/job/agent_job/cron 的运行时态 | `TaskStore`, `JobRegistry`, `AgentJobRegistry`, `CronRegistry` |
| `client` / `api/stream` | Anthropic HTTP + SSE 流式 + 重试 | `Client.init(WithBaseUrl)`, `sendMessageStreamFull`, `UsageDelta` |
| 参考 backend | 库自带非-UI 前端(可直接用或当模板) | `WriterBackend`(打印型), `HeadlessBackend`(CoreEvent→JSON) |

---

## 3. 协议契约(前端开发者的核心)

实现一个前端 = 实现一个 `UiBackend`。三个文件就是全部契约:
`core/protocol/{ui_backend, ui_event, ui_request}.zig`。

### 3.1 UiBackend — 窄腰

```zig
pub const UiBackend = struct {
    ctx: *anyopaque,
    /// core→UI:消费一个 CoreEvent(归属 session)。同步——返回时 ev 的 borrow slice 即失效,
    /// 后端必须在返回前拷走需保留的字节。
    emit: *const fn (ctx: *anyopaque, session: SessionId, ev: CoreEvent) void,
    /// UI→core:非阻塞拉取该 session 的一个用户事件;无则返 null。
    poll: *const fn (ctx: *anyopaque, session: SessionId) ?UiEvent,
    pub inline fn emitEvent(self, session, ev) void;
    pub inline fn pollEvent(self, session) ?UiEvent;
};
```

- **emit 是 push(core→UI)**,**poll 是 pull(UI→core)**。tick(spinner 等定期刷新)**不进
  vtable**——前端自己起 timer/线程(TUI=tick 线程,GUI=requestAnimationFrame,语音=无 tick)。
- **借用切片纪律**:emit 的 ev 内所有 `[]const u8` 在 emit 返回后失效。in-process 后端立即拷进
  自己的缓冲;out-of-process 后端在 emit 内同步序列化(CoreEvent 全可序列化,见 §6.4)。
- **线程性**:emit 可能在 agent_loop 线程或工具 worker 线程被调(`tool_progress` 跨线程);后端
  实现自负线程安全(TuiBackend 内部持 RenderRegion 锁)。

### 3.2 CoreEvent — core 告诉前端"发生了什么"(语义事件,非渲染指令)

```zig
pub const CoreEvent = union(enum) {
    text_chunk: []const u8,                      // 助手文本流(增量)
    stream_begin,                                 // 一轮助手输出开始
    stream_done,                                  // 一轮助手输出结束
    tool_start: struct { id, name, input },       // 工具开始执行
    set_current_tool: struct { name },            // 当前工具(喂底部 spinner 语义)
    tool_progress: struct { id, text },           // 工具执行中进度(按 id 路由)
    clear_current_tool,                           // 本轮工具执行完
    tool_result: struct { id, name, input, content, is_error, elapsed_ms }, // 工具完成
    usage: UsageDelta,                            // token 计数增量
    phase_change: Phase,                          // input ↔ generating
    auto_compact: struct { dropped, kept },       // 自动压缩历史
    retry_notice: struct { attempt, max, delay_ms }, // 流式建连重试
    ui_request_pending: struct { tool_use_id, request_json }, // 可挂起 UI 请求(异步前端,见 §5.3)
};
```

**关键认知:这些是语义事件,不是终端指令**。`stream_begin` = "助手文本开始"(语音前端可据此起
TTS 会话、LED 可亮灯),`set_current_tool` = "正在执行某工具"(语音可播报、按钮设备可亮工作灯)。
命名带历史 TUI 味,但语义中立。**前端只处理自己关心的变体,其余 `=> {}`**(参考 WriterBackend
no-op 了 set_current_tool/tool_progress/usage 等)。新增变体不会破坏现有 backend(各自 no-op)。

### 3.3 UiEvent — 前端告诉 core"用户做了什么"

```zig
pub const UiEvent = union(enum) {
    interrupt: abort.Reason,      // esc/ctrl+c/语音"停"
    queue_message: []const u8,    // 生成期入队的新消息(所有权转调用方,须 free)
};
pub const Phase = enum(u8) { input = 0, generating = 1 };
```

### 3.4 UiRequest — core 向前端**请求一个回答**(交互式)

工具(AskUserQuestion / 权限门 / ExitPlanMode 审批)需要用户当场回答时,经
`ToolContext.requestUi` / `PermissionContext.ui_requester` 发出:

```zig
pub const UiRequest = union(enum) {
    ask_question: []const AskQuestion,                    // 多选问答(可多选 + preview)
    permission: struct { tool, args },                    // 权限确认
    plan_approval: struct { plan_md },                    // 计划审批(三选项)
};
pub const UiResponse = union(enum) {
    answers: []const []const u8,                          // 选中的 label(s)
    permission: PermissionChoice,                         // allow_once/allow_always/deny_once/deny_tool_session
    plan_approval: PlanApproval,                          // approve_default/approve_accept_edits/reject
};
pub const RequestOutcome = enum { answered, pending, unavailable };
pub const UiRequester = struct {
    ctx: *anyopaque,
    requestFn: UiRequestFn, // fn(ctx, session, allocator, *const UiRequest, *UiResponse) anyerror!RequestOutcome
    pub fn request(self, session, allocator, req, out) anyerror!RequestOutcome;
};
pub fn serializeUiRequest(allocator, req) ![]u8; // 给异步前端投递用
```

`RequestOutcome` 三态是同步/异步前端的分水岭(见 §5)。

---

## 4. 主循环契约:agent_loop.run()

```zig
pub fn run(
    conversation: *Conversation,
    api_client: *Client,
    tool_defs: []const ToolDefinition,
    permission_ctx: *const PermissionContext,
    opts: Options,
    backend: *const UiBackend,
    allocator: std.mem.Allocator,
) !RunResult

pub const RunResult = struct { stop_reason: StopReason, turns: u32, tool_calls: u32 };
pub const StopReason = enum { end_turn, max_turns, aborted, tool_error, api_error, tool_loop, suspended };
```

**一回合做什么**:流式发当前 conversation → 收集 assistant 文本 + tool_use blocks(经 backend
emit `text_chunk`/`tool_start`)→ 按权限决策 + 并发安全分批执行工具(`tool_exec.executeSlots`)→
tool_result 回灌为 user 消息 → 下一轮。直到无 tool_use(`end_turn`)/ 达 max_turns / abort /
熔断(`tool_loop`)/ 挂起(`suspended`,见 §5)。

### 4.1 Options(全可选,`.{}` 即最简跑)

~45 字段,分四类——理解分类比记字段重要:

- **CONFIG(纯标量旋钮)**:`max_turns=50` `system_prompt` `verbose` `auto_compact_threshold`
  `auto_compact_keep_recent=10` `agent_depth=0` `colorize=true` `emit_tool_cards=false`
  `model_override` `explicit_invocation` …
- **DEPS(注入的依赖句柄)**:`abort` `read_state` `edit_hl_cache` `jobs` `agent_jobs` `tasks`
  `api_client` `tool_defs` `dyn_registry` `agents` `skills_set` `cron_registry` `sandbox`
  `mcp_sessions` …
- **SESSION/身份**:`session: SessionId` `session_id` `project_dir` `cwd_abs` `home_dir`
  `parent_model` `plan_file_path` …
- **接口回调(类型安全,见 §4.2)**:`usage_sink` `progress_reporter` `ui_requester`
  `skill_activator` `tool_activator` `worktree_hook` + `spawn_tick_fn`(无状态,裸 fn)

### 4.2 接口回调结构(宿主接 core 的类型安全面)

全部形如 `{ctx: *anyopaque, fn} + method`(仿 `UsageSink`),接错配对编译失败:

| 接口 | 定义于 | 作用 |
|------|--------|------|
| `UsageSink` | agent_loop | 每个 usage event 回写 token 计数 |
| `ProgressReporter` | agent_loop | 轮/工具级进度(turn, tool_name, tool_input, tool_calls)——subagent 进度树用 |
| `UiRequester` | protocol/ui_request | 交互式 UI 请求(§3.4) |
| `SkillActivator` | tools/context | Skill 工具激活 → 把白/黑名单挂宿主 |
| `ToolActivator` | tools/context | ToolSearch 激活 deferred 工具 |
| `WorktreeHook` | tools/context | Enter/ExitWorktree 的 push/pop |
| `ToolProgressReporter` | tools/context | 工具执行内进度(id, phase, text, count;WebSearch 用) |

---

## 5. 同步 vs 异步前端(thread-per-session 的边界)

这是多前端最关键的分野。

### 5.1 同步前端(TUI / GUI / 带长连接的 Web)— 默认路径

人类响应秒级、session = 活线程生命。`UiRequester.request` **阻塞**该 session 线程直到用户答完,
返回 `.answered`(out 已写)。一个慢 session 只阻塞自己的线程,不影响其他 session(thread-per-
session)。这是 `requestUi`/`promptUser` 当前的全部行为。

### 5.2 无交互前端(headless / 批处理 / 后台 subagent)

无 requester(`ui_requester == null`)→ requestUi 返 `.unavailable` → 工具按语义兜底
(AskUserQuestion→NotATty;plan→answer_queue/reject)。参考 `WriterBackend.initNull()` /
`HeadlessBackend`。

### 5.3 异步前端(IM / 邮件 / 工作流)— 可挂起路径(协议已预留,全链待实施)

人类响应延迟 >> 进程寿命(几小时 + 跨重启),活线程无法存活那么久。**协议层已预留**:
- `RequestOutcome.pending`:异步 requester 不阻塞——stash 请求、out-of-band 投递、返回 `.pending`。
- `CoreEvent.ui_request_pending`:core 据此把"待回答的请求"交给异步 backend 投递(Slack/邮件)。
- `StopReason.suspended`:run() 检测到 pending 即挂起返回(不再调 API)。
- `serializeUiRequest`:把 UiRequest 序列化给前端渲染。

**当前状态(2026-06-09)**:协议形状已落地且 sync 路径字节不变(所有现有 requester 返
`.answered`,所有 backend no-op `ui_request_pending`,`.suspended` 无人产生)。**挂起检测 +
checkpoint + `resumeWithResponse`(响应到达后注入 tool_result 续跑)的全链未实施**——设计见
`doc/` 计划文档,建议接第一个真实异步前端时连同前端一并实现验证。

---

## 6. 构建一个前端的最小路径

### 6.1 实现 backend(in-process)

```zig
const mc = @import("metacodes-core");
const MyBackend = struct {
    fn emitImpl(ctx: *anyopaque, _: mc.session_id.SessionId, ev: mc.protocol.ui_event.CoreEvent) void {
        const self: *MyBackend = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .text_chunk => |t| self.render(t),       // 你关心的
            .tool_start => |s| self.showTool(s.name),
            else => {},                               // 其余 no-op
        }
    }
    fn pollImpl(_: *anyopaque, _: mc.session_id.SessionId) ?mc.protocol.ui_event.UiEvent {
        return null; // 或返回用户事件(interrupt / queue_message)
    }
    fn backend(self: *MyBackend) mc.protocol.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitImpl, .poll = pollImpl };
    }
};
```

### 6.2 跑一回合(对齐 `example/main.zig`)

```zig
var client = mc.client.Client.init(a, init.io, api_key, "claude-3-5-haiku-20241022");
var conv = mc.conversation.Conversation.init(a);
try conv.appendText(.user, "Reply with a single word: hello");
var be = MyBackend{};
const result = try mc.agent_loop.run(&conv, &client, tool_defs, &perm_ctx, .{}, &be.backend(), a);
```

### 6.3 多 session(GUI 多视图 / IM 多对话)

N 个 session = N 个 `run()` 线程,共用一个 backend 实例;emit/poll 按 `SessionId` 参数路由到
对应视图/对话。`SessionId.gen()` 造新身份,`.single` 是 N=1 哨兵。每 session 自己的
`Conversation` + `PermissionContext`(per-instance,无进程全局串台)。

### 6.4 进程外前端(WebSocket / gRPC)

CoreEvent/UiEvent/UiRequest 全可序列化(无指针/闭包)。emit 内 `serialize → 发送`、poll 内
`接收 → parse`。`HeadlessBackend` 已示范 emit→NDJSON,可作进程外传输的起点。

---

## 7. 已知约束与边界(诚实清单)

- **剩余进程全局态**:`core/answer_queue.zig`(headless 应答兜底)、`core/recorder.zig`
  (record-replay 测试)仍是进程全局。**非多租户路径**——真要并发多租户 IM 服务前,需 session
  化 answer_queue(参考权限模块 M2 的全局态搬迁手法)。其余 session 态已 per-instance。
- **跨进程恢复**:`transcript` 持久化对话(含 tool_use/tool_result),`loadTranscript` 可重建,
  但**不**持久化 in-memory registry(read_state / 后台 job / cron / activated tools)。同步前端
  无影响;异步可挂起路径(§5.3)的完整恢复需补这部分(已知,待实施)。
- **能力协商缺失**:协议未让 backend 声明能力(最大选项数 / 输入模态)。3 按钮设备如何映射 4 选项
  multi-select、语音如何表达 preview——需在接受限输入前端时加 `BackendCapabilities`(加性扩展)。
- **输出粒度**:`text_chunk` 按 token 流。语音要整句、IM 要整条(限流)、LED 要终态——backend 可
  缓冲到 `stream_done` 再出(加性,backend 私事)。
- **permission 门不可挂起**:权限确认是 `executeSlots` 前的同步门,异步挂起暂不覆盖(out of scope)。

---

## 8. 验证 core 健康的命令

```bash
zig build                 # 主二进制(含 TUI 前端)
zig build test            # 全单测(含协议/工具/权限)
zig build test:lib        # ★ refAllDecls 编 core 全图 = core↔UI 物理隔离的编译器证明
zig build example         # 跑 example/ 最小前端(真端点;离线见 LIB_API.md §9)
```

**`zig build test:lib` 绿 = core 不依赖任何前端**——这是平台内核最该守的不变式,每次改 core 后必跑。

---

## 9. 导航

- 快速接入(装依赖 + 跑 example):`doc/LIB_API.md`
- 最小前端示例:`example/main.zig`(`zig build example`)
- 多 session 设计:metaknow scope metask_business `MULTI_SESSION_REFACTOR`
- 设计文档总入口:metaknow scope `metask_business`(PLAN/SUBAGENT/PERMISSION/TOOLS 等根)
- 操作命令/API 规范:`doc/L2.md`
