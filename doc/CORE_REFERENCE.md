# metacodes-core — 内部架构参考

> 面向 metacodes 仓库内部维护者，说明 TUI、Web、daemon 等 frontend 与 core 的模块边界。
> 本文是**内部架构契约 + 设计不变式**参考；第三方接入见 `doc/LIB_API.md`。
>
> 字段级 API 以源码为准（本次审计更新于 2026-08-24）；模块名 `metacodes-core`,
> 本文仅描述仓库内部模块边界，不是第三方稳定源码 API。外部 Host 可选择源码级
> `metacodes-core` 或预编译 AgentCore bundle；交付契约见 `doc/LIB_API.md`。内部 module 名为
> `lib.VERSION = "0.1.0"`。

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

    // 输出语义(见 §3.2.1)
    output_segment_begin: struct { index, turn, group },
    output_segment_end: struct { index, turn, group, disposition, bytes },
    // 文件修改结果(见 §3.2.2)
    file_changes: struct { id, name, changes, overflow, lost },
};
```

**关键认知:这些是语义事件,不是终端指令**。`stream_begin` = "助手文本开始"(语音前端可据此起
TTS 会话、LED 可亮灯),`set_current_tool` = "正在执行某工具"(语音可播报、按钮设备可亮工作灯)。
命名带历史 TUI 味,但语义中立。**前端只处理自己关心的变体,其余 `=> {}`**(参考 WriterBackend
no-op 了 set_current_tool/tool_progress/usage 等)。新增变体不会破坏现有 backend(各自 no-op)。

#### 3.2.1 输出语义:哪段文本才是答案(`core/output_semantics.zig`)

`text_chunk` 只说"有文本到了";`stream_done` 只说"一次 provider stream 结束"——**它从来不是
完成信号**(每轮工具调用、每次续写、每次流内重试都会发一个)。前端若只看这两者,必须自建
"什么算 final"的状态机,而且每个前端会得出不同答案。

core 因此把它**已经知道**的判定发出来。一个 **段** = 一次 provider stream 的可见文本,
`output_segment_begin` 开、`output_segment_end` 关(严格配对,至多一个打开),关闭时带定性:

| disposition | 含义 |
|-------------|------|
| `commentary` | 可见过程信息(本轮跟着工具调用,或主机拒绝了这次"过早的最终答案") |
| `final` | Run 的完成结果 |
| `continued` | 被 max_tokens 截断,与**同 `group`** 的下一段合成一个结果 |
| `partial` | 可见但未完成(abort / 预算终止 / 二次拒绝) |
| `discarded` | 从未进入 Conversation(流内失败回滚),前端须丢弃已缓冲的该段字节 |

`index` 在 Run 内单调,**被丢弃的段也占一个索引**("回滚过"与"没发生过"必须可区分)。
`thinking_chunk` 不属于任何段——思考永不进入结果。

不想消费事件的调用方挂 `Options.output_ledger: ?*output_semantics.Ledger`,run() 返回后直接
`ledger.finalText()` / `partialText()`(续写组已拼好)。**账本不传给 subagent**:子 agent 的
输出是父 Run 的工具结果,不是父 Run 的答案。

#### 3.2.2 文件修改结果:实际改了什么(`core/file_change.zig`)

`file_refs` 只说"碰了哪些文件";`tool_result.content` 里的 `gitDiff` 是**工具私有渲染字段**
(Read 没有、各工具形状不同、结果落盘成 artifact 时会被信封替换)。要展示实际改动请用
`file_changes` 事件,它**无条件发**(证据不是渲染——headless / subagent /
`emit_tool_cards=false` 时同样发)。

**时序**:本轮工具全部执行完后**一次性发**,早于本轮任何 `tool_result`——不是紧邻配对。
挂起(UiPending)、host fatal、结果组装失败都可能发生在盘已经真的改过之后,证据放在所有分支
之前才不会静默丢失。消费者按 `id` 与 tool_result 配对,不靠相邻。

每条 `Record` 带 locator(与 `FileReference` 同一归一化)、`kind`(created/modified/deleted/
moved)、`status`(applied/no_change/failed/rejected/partial)、`tool`+`tool_use_id`(与工具卡
配对)、`agent_depth`(>0 = 子执行)、前后字节数、`unified_diff` 与 `diff_complete`。
事件的 `overflow`/`lost` 表示本次报告不完整。

`Options.file_change_journal: ?*file_change.Journal` 是 Run 级账本,**经 SpawnOptions 下传给
子执行**(子 agent 的修改仍是本 Run 的修改)。带锁,读用 `acquire()/release()` 成对。
`file_change.writeJsonEnvelope` 是进程外消费者的稳定线格式(`{schema_version, truncated, changes[]}`——版本由模块自己盖,不靠调用方约定)。

**不覆盖** `Bash` 等任意命令造成的文件系统变化——本契约只管类型化文件工具,并明说这一点。

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
// `api_provider` is the `mc.api_provider` namespace exported by `src/lib.zig`.
pub fn run(
    conversation: *Conversation,
    provider: api_provider.Provider,
    tool_defs: []const ToolDefinition,
    permission_ctx: *const PermissionContext,
    opts: Options,
    backend: *const UiBackend,
    allocator: std.mem.Allocator,
) !RunResult

pub const RunResult = struct {
    stop_reason: StopReason,
    turns: u32,
    tool_calls: u32,
    suspend_info: ?SuspendInfo = null,
};
pub const StopReason = enum {
    end_turn, max_turns, aborted, tool_error, api_error, tool_loop,
    suspended, backgrounded, budget,
};
```

`provider` 是按值传递的轻量 vtable；它借用具体 client 的 context，client 必须活到
本次 `run` 以及所有并发工具工作结束。源码 Host 通常使用
`agent_session.RuntimeHost`/`AgentSession`（见 §6 和 `example/main.zig`）；只有需要
直接驱动低层循环时，才从具体 client 取得 `client.provider()`。
当 `stop_reason == .suspended` 时，`suspend_info` 由调用方拥有；写入持久状态或完成
投递后调用其 `deinit()`。

**一回合做什么**:流式发当前 conversation → 收集 assistant 文本 + tool_use blocks(经 backend
emit `text_chunk`/`tool_start`)→ 按权限决策 + 并发安全分批执行工具(`tool_exec.executeSlots`)→
tool_result 回灌为 user 消息 → 下一轮。直到无 tool_use(`end_turn`)/ 达 max_turns / abort /
挂起(`suspended`,见 §5)。`tool_loop` 枚举值保留为 ABI 兼容(无生产者,对齐 codex 无主动熔断)。

**大结果提交协议**:工具统一返回 `ToolResultBody`。旧工具经 `legacy_inline` adapter 仍先产生
完整 bytes；byte-zero 原生工具和 process plugin 则在产生第一字节前取得 kernel Spool，最终直接
返回 artifact receipt。`executeSlots`、PostToolUse hook 和 backend 观察该类型的确定性模型投影：
inline 路径保持原始结果，artifact 路径观察 bounded recovery envelope（全文从未进入内核内存）。
随后 `result_projection` 只做一次确定性 Conversation 提交。结构化工具应优先返回合法的 bounded
envelope（`rows/cursor/total/truncated`）；其余超限 inline 结果写入 Session 内容寻址 artifact，
模型只看到稳定 SHA-256、head/tail 预览和 `ReadArtifact(offset,limit)` 指令。最后的通用字节截断
仅是失存储时的显式不可恢复兜底。已提交的 recovery envelope 不在后续 provider 请求前重新
投影；`ReadArtifact` 从首个请求就属于冻结工具目录，避免因溢出动态改 schema 而破坏 prompt cache。

静态 `ToolEntry.result_production` 把生产方式收成三种不可混淆的状态：`bounded_inline`、
`input_derived`、`byte_zero_spool`；comptime 断言禁止 `byte_zero_spool` 工具接回
`legacy_inline` executor。当前原生 byte-zero 清单是 `Glob`、`Grep`、`CodeMap`、
`FindSymbol`、`Bash`、`ListMcpResourcesTool`、`ReadMcpResourceTool`、`WebFetch`。
其中 Bash 在第一个 stdout/stderr 字节前重定向到 JobRegistry 文件；没有长生命周期
JobRegistry 的源码嵌入者只要提供 `artifact_root`，内核就为该次同步调用建立临时 registry，
不会退回 pipe 全量捕获。MCP stdio、AgentCore MCP connector、process plugin 与公开 Host
stream ABI 都复用同一 CAS/receipt/`ReadArtifact` 恢复面。

真实 rollout 的非敏感证据用 `scripts/eval/tool_result_projection_eval.py <cassette>
--headless-result <result.ndjson> --time-file <time.txt>` 导出；报告只含尺寸、hash、usage、
恢复/前缀判定和时延，原始 cassette、artifact 与模型文本必须留在隔离本地目录。

### 4.1 Options(全可选,`.{}` 即最简跑)

字段较多,分四类——理解分类比记字段重要:

- **CONFIG(纯标量旋钮)**:`max_turns=400` `cost_budget_usd` `system_prompt` `verbose`
  `auto_compact_threshold`
  `auto_compact_keep_recent=10` `agent_depth=0` `colorize=true` `emit_tool_cards=false`
  `model_override` `explicit_invocation` …
- **DEPS(注入的依赖句柄)**:`abort` `read_state` `edit_hl_cache` `jobs` `agent_jobs` `tasks`
  `api_client`(仅 Anthropic `web_search` 专用) `provider_factory` `tool_defs` `dyn_registry`
  `agents` `skills_set` `cron_registry` `sandbox`
  `mcp_sessions` `output_ledger`(§3.2.1) `file_change_journal`(§3.2.2) …
- **SESSION/身份**:`session: SessionId` `session_id` `project_dir` `cwd_abs` `home_dir`
  `parent_model` `plan_file_path` `artifact_root` …
- **接口回调/观察(类型安全,见 §4.2)**:`ui_requester` `host_services` `tool_observer`
  `spawn_tick_fn`；usage/progress 由 `CoreEvent`/`EventSink` 投影，不再注入私有 sink。

### 4.2 接口/事件结构(宿主接 core 的类型安全面)

回调接口统一把 context 与函数指针收进类型安全的 value；usage/progress 则走
`CoreEvent`，不是已经移除的私有 `UsageSink`/`ProgressReporter` 回调:

| 接口 | 定义于 | 作用 |
|------|--------|------|
| `EventSink` | `agent_session` | Session 级 `CoreEvent` 消费（文本、工具、usage、progress、诊断） |
| `UiBackend` | `protocol/ui_backend` | 低层 `agent_loop.run` 的 emit/poll 事件面 |
| `UiRequester` | `protocol/ui_request` | 交互式 UI 请求(§3.4)，可返回 answered/pending/unavailable |
| `HostServices` | `tools/context` | Skill/ToolSearch 激活与 Worktree push/pop 的宿主 RPC |
| `ToolProgressReporter` | `tools/context` | 工具执行内进度(id, phase, text, count;WebSearch 用) |
| `ToolObservationSink` | `tools/observation` | UI-independent 的实际 dispatch 观察 |

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

### 5.3 异步前端(IM / 邮件 / 工作流)— 可挂起路径

人类响应延迟 >> 进程寿命(几小时 + 跨重启),活线程无法存活那么久。**协议层已预留**:
- `RequestOutcome.pending`:异步 requester 不阻塞——stash 请求、out-of-band 投递、返回 `.pending`。
- `CoreEvent.ui_request_pending`:core 据此把"待回答的请求"交给异步 backend 投递(Slack/邮件)。
- `StopReason.suspended`:run() 检测到 pending 即挂起返回(不再调 API)。
- `serializeUiRequest`:把 UiRequest 序列化给前端渲染。

当前同步 requester 仍返回 `.answered`；异步 requester 可以返回 `.pending`，由
`run()` 产出 `.suspended` 和 `RunResult.suspend_info`。CLI/headless 已把该信息写入
`suspend.json`，`--resume-response` 通过 `resumeSuspended` 读取 transcript 与挂起状态，
调用 `resumeRun` 注入成对的 `tool_result` 并继续运行（再次挂起时链式重写状态）。真正的
Slack/邮件投递器仍属于宿主职责，core 不负责网络传输。

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
defer client.deinit();
const provider = client.provider(); // value vtable; client/context must outlive run()
var conv = mc.conversation.Conversation.init(a);
defer conv.deinit();
try conv.appendText(.user, "Reply with a single word: hello");
var be = MyBackend{};
const backend = be.backend();
const result = try mc.agent_loop.run(&conv, provider, tool_defs, &perm_ctx, .{}, &backend, a);
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
- **文件修改契约只覆盖类型化文件工具**(Write/Edit/NotebookEdit/ApplyPatch,§3.2.2)。`Bash` 或
  任意终端命令改动文件系统**不会**产生 `file_changes`——要覆盖它需要文件系统级观测,不在本契约内。
- **输出段兜底定性排在 `diag_run_end` 之后**(§3.2.1)。所有显式定性路径都在 run 收口前关闭段;
  兜底(`defer` 把仍打开的段记为 `partial`)只在遗漏时生效,顺序因此靠后。
- **`--stream-json` 已投影输出段定性**(`output_segment_begin/end` 行),但**未投影 file_changes**
  ——那条事件带整段 diff,塞进逐行时间线会把流撑爆;需要文件修改的消费者走 `--json` 结果行的
  `file_changes` 数组或直接消费 CoreEvent。TUI 对两组事件都 no-op(边流边渲染,不需要事后重标)。
- **AgentCore 公共 C ABI 不导出这三条事件**(`output_segment_begin/end`、`file_changes`)。
  facade 内部的 A1 projector **已经**消费 `output_segment_end` 来正确重建最终答案(它此前用
  `stream_done` 收段,会把回滚重试的文本重复计入),消费者观察到的行为因此已修好;把原始事件
  也导出去要动冻结的 C header + symbol gate + 版本与消费方签字,不在本次范围。
- **ApplyPatch phase-1 校验失败**(解析错/定位不到/Add 撞已存在)只对**已建好计划**的文件报
  `rejected`;触发失败的那个文件还没进计划表,只出现在工具错误 detail 里。整批零落盘,故没有
  谎报,但目标清单不完整——登记而非假装完整。

---

## 8. 验证 core 健康的命令

```bash
zig build                 # 主二进制(含 TUI 前端)
zig build test            # 全单测(含协议/工具/权限)
zig build test:lib        # ★ refAllDecls 编 core 全图 = core↔UI 物理隔离的编译器证明
zig build example         # 跑 example/ 最小前端(真端点;离线见 LIB_API.md §1)
```

**`zig build test:lib` 绿 = core 不依赖任何前端**——这是平台内核最该守的不变式,每次改 core 后必跑。

---

## 9. 导航

- 第三方 AgentCore 二进制接入:`doc/LIB_API.md`
- 最小前端示例:`example/main.zig`(`zig build example`)
- 多 session 设计:metaknow scope metask_business `MULTI_SESSION_REFACTOR`
- 设计文档总入口:metaknow scope `metask_business`(PLAN/SUBAGENT/PERMISSION/TOOLS 等根)
- 操作命令/API 规范:`doc/API.md`
