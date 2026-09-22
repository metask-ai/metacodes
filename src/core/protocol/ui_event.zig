//! UI 解耦协议:core↔UI 的双向事件 union(阶段 A)。
//!
//! 设计目标(见 plan zazzy-dazzling-lake §协议可序列化):
//! - **全值类型/slice**:无裸指针、无函数指针、无共享内存依赖。
//! - **可 JSON 序列化**:进程内 vtable 直传(零序列化,TUI 现用);未来进程外
//!   WsBackend 把同一 union 序列化为 JSON 经隧道发送——core/agent_loop 不改。
//! - **slice 是 borrow**:CoreEvent 携带的 text/id/name 是借用切片,emit 必须
//!   **同步消费**(立即拷进定长/写 scrollback,不持有跨调用)。生命周期由
//!   producer(agent_loop)保证在 emit 返回前有效。
//!
//! 与现状的映射(阶段 B 接线时用,**表达层移入 backend**):
//!   colorize 开括号 print("\x1b[32m") → emit(.stream_begin)
//!   stdout_writer.print(纯文本)        → emit(.text_chunk)(只发文本,不含 ANSI)
//!   tool_card.renderStart→print        → emit(.tool_start)(card=false,backend 渲染)
//!   stdout_writer.addToolCard          → emit(.tool_start)(card=true)
//!   stdout_writer.setCurrentTool       → emit(.set_current_tool)
//!   stdout_writer.setToolProgress      → emit(.tool_progress)
//!   stdout_writer.clearCurrentTool     → emit(.clear_current_tool)
//!   stdout_writer.clearToolCard        → emit(.tool_result)(card=true)
//!   tool_card.renderResult→print       → emit(.tool_result)(card=false,backend 渲染)
//!   usage_sink                         → emit(.usage)
//!   context warning                    → emit(.context_warning)
//!   auto-compact 行                    → emit(.auto_compact)
//!   重试提示                            → emit(.retry_notice)
//!   colorize 闭括号 print("\x1b[0m\n")  → emit(.stream_done)

const std = @import("std");
const api_stream = @import("../../api/stream.zig");
const file_reference = @import("../file_reference.zig");
const output_semantics = @import("../output_semantics.zig");
const file_change = @import("../file_change.zig");
const abort = @import("../../util/abort.zig");
const types = @import("../../types.zig"); // UI-free 核心类型(PermissionMode/ReasoningEffort)

/// **跨 UI session 配置变更**(U4)。多 UI 附着同一 session 时的状态广播源。
/// 只含**跨 UI 关心的 session 级配置**——model/mode/dirs/reasoning;theme/vim 是
/// TUI 呈现层本地态(web/gui 各有自己的),不进核心事件(且 theme.Variant 是 UI 类型,
/// 进核心会破坏 lib UI-free 边界)。用 union → CoreEvent 只加 1 个 case,加轴时内层
/// exhaustive switch 编译期强制所有消费者处理。
///
/// **借用契约(Linus U4 定)**:.model/.dirs 是 borrow slice,**只在 emit 同步窗口有效**;
/// sink 若跨线程留存(web journal)必须落地时 dup。.mode/.reasoning 值语义,安全。
pub const ConfigChange = union(enum) {
    model: []const u8, // 新 model(borrow;sink 跨线程留存须 dup)
    mode: types.PermissionMode, // 值语义
    dirs: []const u8, // 新增/变更的目录(borrow;sink 跨线程留存须 dup)
    reasoning: ?types.ReasoningEffort, // 值语义
    /// issue #16:路由变更。model 名不足以标识路由——同一个可见 model 名可能来自
    /// 不同 provider / channel / 协议 / 账号,只广播 model 名会让进程外 UI 显示一条
    /// 它无法区分的"变更"。全部是 borrow(同 config_changed 契约)。
    route: Route,
};

pub const Route = struct {
    provider_id: []const u8,
    channel_id: []const u8,
    protocol: []const u8,
    /// 线上真正发送的 model id。
    request_model_id: []const u8,
    /// `offer-<32 hex>`;进程外 UI 用它精确指认这条路由。
    offer_id: []const u8,
    /// 绑定的凭证引用(账号),无绑定为 null。**永不含密钥**。
    credential_ref: ?[]const u8 = null,
    /// 作用域:once / session / global。
    scope: []const u8,
};

/// **session 生命周期事件**(U5)。进 journal seq 流(附着重放可见 session 边界)。同 config_changed
/// 用 union → CoreEvent 只加 1 case,加变体时内层 exhaustive switch 编译期强制消费者处理。
/// created="session 诞生"一次性,挂**事件流建立点作 seq 0**(非 App 装配/attach——那样丢/重复);
/// closed 在 session 结束。payload=session_id(borrow;sink 跨线程留存须 dup,同 config_changed 契约)。
/// **loaded(/resume)暂不列**:它需 SessionId.fromSlice(M1 未实现)+ 修 session_id 漂移
/// (handleResume 换 conversation 但不改 session_id,task#16)——待那个 bounded fix 落地再加
/// loaded 变体(遵"声明=接线=测试":不声明未接线的变体)。
pub const SessionLifecycle = union(enum) {
    created: []const u8, // session_id
    closed: []const u8, // session_id
};

/// **agent 生命周期事件**(U6,诉求②"agent 切换")。父 session 事件流上广播子 agent(Task/subagent)
/// 的 spawn/状态跃迁/结束,供进程外 UI 画 agent roster/切换。**非** subagent 内层事件转发
/// (那是 JobEntry.backend 的活)——这是外层"有个 agent 起了/变了/完了"通知。
/// **state 用 tagName 字符串而非 JobStatus enum**:JobStatus 定义在 agent_job_registry(非 core/protocol),
/// core 事件不能依赖它(会把 registry 拖进 lib UI-free 图);投影成字符串,同 diag_run_end.stop_reason_name。
/// payload slice 全 borrow(sink 跨线程留存须 dup,同 config_changed 契约)。
pub const AgentLifecycle = union(enum) {
    spawned: struct {
        id: []const u8, // job id
        agent_type: []const u8, // "Explore"/"Plan"/…
        desc: []const u8, // 描述预览
        foreground: bool, // 前台同步 job vs 后台
    },
    status: struct {
        id: []const u8,
        state: []const u8, // JobStatus tagName(running/…)
        turns: u32,
        tool_calls: u32,
    },
    done: struct {
        id: []const u8,
        state: []const u8, // 终态(done/failed/aborted)
        turns: u32,
        tool_calls: u32,
        tokens: u64,
    },
};

/// **任务 DAG 变更事件**(U6,诉求②"任务完成的 DAG 可视化")。tinykg task frontier 变化时发,
/// UI 据此重拉/增量更新看板。**默认轻信号 invalidated**(不把整棵 DAG 塞进每次事件——带宽 + journal
/// 膨胀;全量走 attach 快照 + /tasks 端点);`task` 富载可选(单跃迁便宜,UI 增量)。
/// payload slice 全 borrow(sink 跨线程留存须 dup)。
pub const TasksChanged = union(enum) {
    invalidated: void, // frontier 变了,UI 去拉全量
    task: struct {
        id: []const u8, // task 节点 id
        state: []const u8, // pending/in_progress/completed/…(tagName)
        claimed_by: []const u8, // agent_ident 或空
    },
};

/// **配置变更事件出口**(U4)。App **持有**(非借生成期 backend——config 变更在 run 外的
/// 空闲点),生命周期=session。各轴的**单写侧**(model→syncModelMirrors、mode→
/// permission_ctx.setMode、dirs/reasoning→App 方法)在 mutate 后经它 emit。driver 单线程 emit。
///
/// **借用契约**:传入的 ConfigChange 里 .model/.dirs 是 borrow，**只在本 emit 调用同步窗口有效**。
/// sink 实现若跨线程留存（web journal 落盘供 SSE 线程读）**必须在 emitFn 内 dup**；同步消费
/// （TUI 立即重绘）即用即弃。此契约与 CoreEvent 其余 borrow slice 一致（消费者留存自负拷贝）。
pub const ConfigEventSink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, ev: ConfigChange) void,
    pub fn emit(self: ConfigEventSink, ev: ConfigChange) void {
        self.emitFn(self.ctx, ev);
    }
};

/// **工具→父 backend 的通知通路**(U6 A2)。工具(Task 生 subagent / TaskUpdate 改 DAG)是**单向
/// 通知**发起方,该上 CoreEvent 跨进程总线,但 ToolContext 原本只有请求-响应 UiRequester +
/// 工具内 ToolProgressReporter,没有发通知类 CoreEvent 的通路。EventReporter 补这条,**限定子集**
/// (只 agent_lifecycle / tasks_changed,用两个具名方法而非裸 CoreEvent → 类型上禁止工具乱发
/// text_chunk/tool_result 等表达类事件;"make illegal states unrepresentable")。
/// **线程/借用契约**:与 ToolProgressReporter 同——reportFn 转发到 backend.emitEvent,threading
/// 由 backend 契约兜底(precedent:tool_progress 已从并发工具发);payload slice borrow,emit 同步消费。
pub const EventReporter = struct {
    ctx: *anyopaque,
    agentFn: *const fn (ctx: *anyopaque, ev: AgentLifecycle) void,
    tasksFn: *const fn (ctx: *anyopaque, ev: TasksChanged) void,
    pub fn agentLifecycle(self: EventReporter, ev: AgentLifecycle) void {
        self.agentFn(self.ctx, ev);
    }
    pub fn tasksChanged(self: EventReporter, ev: TasksChanged) void {
        self.tasksFn(self.ctx, ev);
    }
};

/// core → UI:agent_loop 产出的事件。在 agent_loop 线程(及工具线程,见 tool_progress)调。
///
/// JSON 序列化:union(enum) 默认有 tag,所有 payload 字段均为值/slice,可直接
/// `std.json.stringify`。slice 是 borrow——序列化时拷贝字节,进程内直传时同步消费。
pub const CoreEvent = union(enum) {
    /// assistant 文本流(进 scrollback)。borrow slice。
    text_chunk: []const u8,

    /// 思考过程流(reasoning_content / thinking_delta)。borrow slice。
    /// 与 text_chunk 分离:UI 折叠显示,不混入最终回答;多轮 preserved thinking 回传需要它。
    thinking_chunk: []const u8,

    /// 一轮流式输出开始(取代 agent_loop 旧 `if(colorize) print("\x1b[32m")`)。
    /// backend 决定是否开颜色括号。
    stream_begin,

    /// 工具开始执行。agent_loop 无条件发(每个 run slot 一个);backend 据 name 自决渲染:
    /// hasProgressCard(WebSearch)→ addToolCard;showStartCard → renderStart→scrollback;
    /// 都不是 → 跳过(AskUserQuestion/plan/Skill 走专门 UI)。spinner 喂也由 backend 自决。
    tool_start: struct {
        id: []const u8,
        name: []const u8,
        input: []const u8,
    },

    /// 把当前工具喂底部 spinner(每轮第一个普通工具)。取代旧 setCurrentTool。
    set_current_tool: struct {
        name: []const u8,
    },

    /// 工具执行中进度刷新(按 tool_use id 路由)。WebSearch 子请求等工具内进度。
    tool_progress: struct {
        id: []const u8,
        text: []const u8,
    },

    /// 轮/工具级进度(turn 1-based;tool_name/tool_input 空 = 仅推进轮次,保留上一动作)。
    /// tool_calls = 截至此刻累计工具调用数(单调)。subagent 进度树消费此事件更新
    /// turn/当前工具/token 行。取代旧 ProgressReporter 扁平回调(L1:单向通知=事件)。
    /// 顶层 TUI 后端忽略它(顶层进度走 spinner + set_current_tool);仅 JobEntry 后端消费。
    progress: struct {
        turn: u32,
        tool_name: []const u8,
        tool_input: []const u8,
        tool_calls: u32,
    },

    /// 清除底部 spinner 当前工具(本轮工具执行完)。取代旧 clearCurrentTool。
    clear_current_tool,

    /// 工具执行完成。agent_loop 无条件发;backend 据 name 自决:
    /// hasProgressCard → clearToolCard;否则 renderResult→scrollback(showStartCard=false 跳过)。
    tool_result: struct {
        id: []const u8,
        name: []const u8,
        input: []const u8,
        content: []const u8,
        is_error: bool,
        elapsed_ms: u64 = 0,
        file_refs: ?[]const file_reference.FileReference = null,
    },

    /// **文件修改结果**(见 core/file_change.zig)。**无条件发**(它是证据不是渲染,headless/
    /// subagent/关工具卡时同样发),每个产生了文件修改的 slot 一条。
    ///
    /// **时序**:本轮工具**全部执行完后一次性发**,早于本轮任何 `tool_result`——不是紧邻配对。
    /// 这是刻意的:挂起(UiPending)、host fatal、结果组装失败都可能发生在盘已经真的改过之后,
    /// 只有把证据放在所有分支之前才不会静默丢失。消费者按 `id` 与 tool_result 配对,不靠相邻。
    ///
    /// `changes` 是借用切片,emit 同步消费;跨线程留存须逐条 `Record.clone`。上层据此展示每个
    /// 文件的实际修改,不必解析 tool_result.content 里的工具私有 `gitDiff`。
    ///
    /// `overflow`/`lost` 说明本次 dispatch 报告不完整(超单次上限 / 复制失败),消费者应显示
    /// "不完整"而不是把少报当成少改。
    file_changes: struct {
        id: []const u8,
        name: []const u8,
        changes: []const file_change.Record,
        overflow: bool = false,
        lost: bool = false,
    },

    /// token 计数增量。
    usage: api_stream.UsageDelta,

    /// **跨 UI session 配置变更**(U4)。命令/键盘触发的 model/mode/dirs/reasoning 变更后，
    /// 从该轴的单写侧 emit。多 UI 消费者据此更新状态显示(TUI statusline / web /state 广播)。
    config_changed: ConfigChange,

    /// **session 生命周期**(U5)。created(seq 0)/loaded(/resume)/closed。进 journal seq 流，
    /// 附着客户端据此见 session 边界起止。
    session_lifecycle: SessionLifecycle,

    /// **agent 生命周期**(U6)。父 session 上广播子 agent spawn/status/done,进程外 UI 画 roster/切换。
    /// TUI/Writer no-op(TUI 进度树走 snapshotJobs 轮询);web journal → SSE。
    agent_lifecycle: AgentLifecycle,

    /// **任务 DAG 变更**(U6)。tinykg frontier 变化信号,UI 重拉/增量画看板。TUI/Writer no-op
    /// (TUI 看板走既有注入路径);web journal → SSE。
    tasks_changed: TasksChanged,

    /// 上下文接近 auto-compact 阈值的主动提示。每个 run 至多发一次。
    context_warning: struct {
        current_tokens: u64,
        warning_threshold: u64,
        auto_compact_threshold: u64,
        blocking_limit: u64,
        level: []const u8,
    },

    /// 自动压缩历史:丢弃 dropped 条旧消息,保留 kept 条。
    auto_compact: struct {
        dropped: u32,
        kept: u32,
        before_tokens: u64 = 0,
        after_tokens: u64 = 0,
        /// pre_sampling_pending_turn_threshold | pre_sampling_previous_model_smaller_window |
        /// post_tool_follow_up_threshold | summary_fallback | tool_result_pressure |
        /// context_window_exceeded_recovery
        cause: []const u8 = "trigger",
    },

    /// 本地上下文投影：没有发 compact-summary 请求，但活跃 provider 上下文已被
    /// 截断或把旧 tool_result 替换成 stub。原始 transcript 仍可保留；该事件只说明
    /// 下一次模型请求看到的上下文发生了有损变化，供评测禁止静默宣称保真/cache 优势。
    context_projection: struct {
        /// large_tool_result_truncation | stale_tool_result_microcompact
        kind: []const u8,
        changed_items: u32,
        bytes_before: u64,
        bytes_after: u64,
        active_messages: u32,
        cause: []const u8,
    },

    /// 流式建连重试提示(第 attempt/max 次,退避 delay_ms)。
    retry_notice: struct {
        attempt: u32,
        max: u32,
        delay_ms: u64,
    },

    /// 一轮流式输出结束(取代旧 `print("\x1b[0m\n")`/`print("\n")`)。
    /// backend 决定闭颜色括号 + 尾换行。
    stream_done,

    /// **可见输出段开始**(输出语义 v1,见 core/output_semantics.zig)。此后到配对的
    /// `output_segment_end` 之间的每个 `text_chunk` 都属于本段。`thinking_chunk` **不**属于
    /// 任何段——思考永不进入结果。段索引在 Run 内单调,回滚的段也占一个索引。
    output_segment_begin: struct {
        index: u32,
        turn: u32,
        group: u32,
    },

    /// **可见输出段结束 + 语义定性**。agent_loop 在它**真正知道**时才发:见到 tool_use →
    /// commentary;自然 end_turn → final;max_tokens 续写 → continued(与同 group 的下一段
    /// 合成一个结果);abort/预算终止 → partial;流内错误回滚 → discarded(消费者须丢弃已缓冲
    /// 的该段字节)。消费者不再需要自建"什么算 final"的状态机——`stream_done` 只表示一次
    /// provider stream 结束,从来不是完成信号。
    output_segment_end: struct {
        index: u32,
        turn: u32,
        group: u32,
        disposition: output_semantics.Disposition,
        bytes: u64,
    },

    /// 可挂起 UI 请求预留(Stage 1):异步前端(Slack/邮件/工作流)收到此事件后,
    /// 据 tool_use_id + request_json 把请求 out-of-band 投递给人类,响应到达后经
    /// resumeWithResponse 注入。sync 前端(TUI/GUI)no-op(它们走同步阻塞 requestUi)。
    /// 纯数据(无指针/闭包)→ 可序列化跨进程(WsBackend)。
    ui_request_pending: struct {
        tool_use_id: []const u8,
        request_json: []const u8,
    },
    /// Internal synchronous-UI lifecycle edge. It is consumed by the
    /// AgentCore RunState projector and remains hidden from the public ABI.
    ui_request_resolved,

    // ── L4 诊断变体(可观测性)──────────────────────────────────────────────
    // agent_loop 在现有 log 点旁 emit;渲染 backend(TUI/Writer/JobEntry)一律 no-op,
    // 仅 DiagnosticsBackend 消费。内联 trace_id(run 级,12-byte RequestId)+ depth
    // (agent 嵌套深度:父 0 子 1)。**当前 DiagnosticsBackend 只挂顶层,只见 depth=0**;
    // depth 字段为日后接 subagent(跨 agent span 树)留位,本版恒 0(见 diagnostics_backend.zig)。
    // 全值类型(trace_id 是定长数组,非 slice)→ 可 JSON 序列化、可跨进程。

    /// 诊断:一轮开始。span 树的 turn span 起点。
    diag_turn_begin: struct { trace_id: [12]u8, depth: u8, turn: u32 },
    /// 诊断:一轮结束(本轮累计 tool_calls)。turn span 终点。
    diag_turn_end: struct { trace_id: [12]u8, depth: u8, turn: u32, tool_calls: u32 },
    /// 评估:一次 provider 请求（含建连重试与完整 stream 消费）的阻塞墙钟。
    diag_model_request: struct { trace_id: [12]u8, depth: u8, turn: u32, attempt: u32, elapsed_ms: u64, outcome: []const u8 },
    /// 评估:一次真实 compact-summary provider 请求。仅在跨过 provider
    /// 边界后发出；纯本地 optimistic preview 不产生该事件。
    diag_compact_request: struct { trace_id: [12]u8, depth: u8, turn: u32, elapsed_ms: u64, outcome: []const u8, cause: []const u8 },
    /// Internal lifecycle edge emitted when auto-compact is admitted. This is
    /// deliberately separate from diag_compact_request, whose meaning is the
    /// completed provider summary request.
    diag_compact_begin: struct { trace_id: [12]u8, depth: u8, turn: u32, cause: []const u8 },
    /// Internal lifecycle edge emitted for every auto-compact exit, including
    /// local no-change and aborted/error paths that have no provider request.
    diag_compact_end: struct { trace_id: [12]u8, depth: u8, turn: u32, elapsed_ms: u64, outcome: []const u8, cause: []const u8 },
    /// 评估:模型 stream 完成后，本轮权限/Hook/工具执行关键路径的墙钟。
    /// 与 model request 串行，因此两者可从 run wall time 中相减得到 harness residual。
    diag_tool_stage: struct { trace_id: [12]u8, depth: u8, turn: u32, tool_calls: u32, elapsed_ms: u64 },
    /// 诊断:工具熔断器触发(同错连续 N 轮)。
    diag_breaker_tripped: struct { trace_id: [12]u8, depth: u8, same_err_count: u32 },
    /// 诊断:prompt cache 击穿(cache_read 跌幅触发)。
    diag_cache_break: struct { trace_id: [12]u8, depth: u8, cache_read: u64, cache_creation: u64 },
    /// 诊断:max_tokens 截断 → 续写(第 n/max 次)。
    diag_continuation: struct { trace_id: [12]u8, depth: u8, n: u32, max: u32 },
    /// 评估/审计:工具执行前的最终权限结果。input 不进入事件，避免评估 artifact
    /// 复制命令、路径或密钥；tool_started 与 allowed=false 的配对可检测策略绕过。
    policy_decision: struct {
        trace_id: [12]u8,
        depth: u8,
        id: []const u8,
        tool: []const u8,
        decision: []const u8,
        source: []const u8,
        allowed: bool,
    },
    /// 诊断:run 结束(stop_reason + 总计)。run span 终点;借用 slice(同步消费)。
    diag_run_end: struct { trace_id: [12]u8, depth: u8, turns: u32, tool_calls: u32, stop_reason_name: []const u8 },
};

/// UI → core:用户产生的事件(非阻塞 poll 拉取)。
///
/// **消费点(#115)**:`agent_loop.run` 在**每个 turn 边界**(上一轮 tool_result 已追加、下一次
/// provider 请求尚未构造)`pollEvent()` 直到 null;流式消费期间不 poll。两个变体的运行期语义:
/// - `queue_message` → 追加为一条 user 消息进 Conversation,**本 Run 的下一次请求就带上它**
///   (生成期入队的转向/补充指令不必等整个 Run 结束);空白消息丢弃。
/// - `interrupt` → 在边界结束本 Run(stop_reason=aborted;`evaluation_budget` → budget)。它补充
///   而不取代 AbortSignal:动中断(流式期间)仍只走 AbortSignal(见 UI_DECOUPLE_BACKEND_FRAMEWORK
///   §3.4);in-process 的 TuiBackend 两条都戳,进程外后端只有这条。
/// - max_tokens 续写边界不 poll(续写段必须仍是同一个答案)。
/// **生产方契约**:什么可转向由 backend 定——`queue_message` 只能是要喂给模型的普通 prompt;REPL
/// 命令(`/x`、`!shell`、`exit`)Core 不认识,TuiBackend 把它们留在队列给 loop.zig 在 Run 结束后派发。
/// input_complete 不走这条:输入期由各 UI 后端各自收集完整输入,返回给 loop 编排。
/// AgentCore Session(agent_session.zig)的 backend.poll 恒返 null——二进制 ABI 没有活动 Run 的
/// 输入操作,宿主自己排队、Run 返回后再 run_input,或 abort。
pub const UiEvent = union(enum) {
    /// 打断当前任务(esc/ctrl+c/语音"停")。携带原因便于日志/错误消息。
    interrupt: abort.Reason,

    /// 生成期入队消息。
    /// **所有权**:in-process backend(TuiBackend)从 MsgQueue.popFront 取出,所有权
    /// 转移给 poll 调用方——agent_loop 消费后用 **`run()` 的 allocator** free,所以 in-process
    /// backend 必须用同一个 allocator 分配它(TuiBackend 的 MsgQueue 与 REPL 传给 run 的是同一个)。
    /// 序列化传输时(WsBackend)则是值拷贝,无所有权问题。协议层视为"调用方拥有的字节"。
    queue_message: []const u8,
};

// ---------------------------------------------------------------------------
// 测试:协议是纯数据 + 可 JSON 序列化(进程外传输前提)。
// ---------------------------------------------------------------------------

test "CoreEvent: 所有 payload 字段为值/slice,无函数指针" {
    // 编译期保证:union 能整体 @sizeOf,无 comptime-only 字段。
    const sz = @sizeOf(CoreEvent);
    try std.testing.expect(sz > 0);
}

test "CoreEvent.text_chunk 可 JSON 序列化" {
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, CoreEvent{ .text_chunk = "hello" }, .{});
    defer std.testing.allocator.free(out);
    // tag 名 + payload 都在
    try std.testing.expect(std.mem.indexOf(u8, out, "text_chunk") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
}

test "CoreEvent.tool_start 可 JSON 序列化(backend 据 name 自决渲染)" {
    const ev = CoreEvent{ .tool_start = .{
        .id = "tu_1",
        .name = "WebSearch",
        .input = "{\"q\":\"zig\"}",
    } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, ev, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "tool_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "WebSearch") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tu_1") != null);
}

test "CoreEvent.context_warning 可 JSON 序列化" {
    const ev = CoreEvent{ .context_warning = .{
        .current_tokens = 160_000,
        .warning_threshold = 160_000,
        .auto_compact_threshold = 167_000,
        .blocking_limit = 177_000,
        .level = "medium",
    } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, ev, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "context_warning") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "medium") != null);
}

test "CoreEvent.output_segment_end 可 JSON 序列化(进程外前端整条 union 序列化)" {
    const ev = CoreEvent{ .output_segment_end = .{
        .index = 3,
        .turn = 2,
        .group = 1,
        .disposition = .final,
        .bytes = 42,
    } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, ev, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "output_segment_end") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "final") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"bytes\":42") != null);
}

test "CoreEvent.file_changes 可 JSON 序列化(含 locator union 与可选 diff)" {
    // WebBackend 把整条 CoreEvent 交给 std.json.Stringify;若这条序列化不了,web 前端会
    // 静默丢事件(emit 里 catch → log.warn)。这里把它钉死。
    const records = [_]file_change.Record{.{
        .locator = .{ .workspace_path = "src/a.zig" },
        .from_locator = .{ .absolute_path = "/old/a.zig" },
        .kind = .moved,
        .status = .applied,
        .tool = "ApplyPatch",
        .tool_use_id = "tu-1",
        .agent_depth = 1,
        .before_bytes = 3,
        .after_bytes = 4,
        .unified_diff = "-a\n+b\n",
    }};
    const ev = CoreEvent{ .file_changes = .{
        .id = "tu-1",
        .name = "ApplyPatch",
        .changes = &records,
    } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, ev, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "file_changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/old/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "moved") != null);
}

test "CoreEvent.usage 复用 stream.UsageDelta" {
    const ev = CoreEvent{ .usage = .{ .input_tokens = 10, .output_tokens = 5 } };
    try std.testing.expectEqual(@as(u64, 10), ev.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), ev.usage.output_tokens);
}

test "UiEvent.interrupt 携带 AbortSignal.Reason" {
    const ev = UiEvent{ .interrupt = .user_ctrl_c };
    try std.testing.expectEqual(abort.Reason.user_ctrl_c, ev.interrupt);
}

test "UiEvent 可 JSON 序列化" {
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, UiEvent{ .queue_message = "later" }, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "queue_message") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "later") != null);
}
