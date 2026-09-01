//! Agent 主循环：user → API stream → tool_use(s) → tool_result(s) → API stream → ...
//!
//! M0.5 把 main.zig 的 runRepl 里嵌在 while 里的业务逻辑抽到这里。
//! M1.5 加入 AbortSignal 检查点：每轮开头、每 stream 事件前检查，触发时返回 .aborted。
//!
//! 核心：用 Conversation 的 Block tagged union 正确保存 tool_use / tool_result，
//! 不再像旧版那样把所有东西扁平化成 text。

const std = @import("std");
const pfs = @import("platform").fs;
const types = @import("../types.zig");
const client_mod = @import("../client.zig");
const provider_mod = @import("../api/provider.zig");
const dialect_mod = @import("../api/dialect.zig");
const request_gate_mod = @import("request_gate.zig");
const execution_effect = @import("execution_effect.zig");
const json_mod = @import("../json.zig");
const tools_mod = @import("../tools.zig");
const permission_mod = @import("../permission.zig");
const message_repair_mod = @import("message_repair.zig");
const hooks_mod = @import("../permission/hooks.zig");
const msg = @import("message.zig");
const conversation_mod = @import("conversation.zig");
const pdf_mod = @import("pdf.zig");
const Conversation = conversation_mod.Conversation;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const ReadState = @import("read_state.zig").ReadState;
const api_stream = @import("../api/stream.zig");
const tool_error = @import("tool_error.zig");
const context_pressure_mod = @import("context_pressure.zig");
const compact_kernel = @import("compact_kernel.zig");
const result_projection = @import("result_projection.zig");
const result_budget_mod = @import("result_budget.zig");
const verification_progress_mod = @import("verification_progress.zig");
const requirement_ledger_mod = @import("requirement_ledger.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const output_semantics = @import("output_semantics.zig");
const file_change_mod = @import("file_change.zig");
const tool_exec_mod = @import("tool_exec.zig");
const ui_backend = @import("protocol/ui_backend.zig");
const ui_event = @import("protocol/ui_event.zig");
const UiBackend = ui_backend.UiBackend;
const CoreEvent = ui_event.CoreEvent;

pub const StopReason = enum { end_turn, max_turns, aborted, tool_error, api_error, tool_loop, suspended, backgrounded, budget };

/// Event capture is independent of execution depth. The default preserves the
/// existing CLI/UI card behavior. Both AgentCore modes emit the complete raw
/// semantic stream into the facade's private projector without pretending that
/// a real child is depth zero; that projector alone decides which events become
/// public. In particular, model-tool boundaries must remain observable there
/// for final-text reconstruction even though they are hidden from the Host.
pub const EventProjection = enum {
    legacy,
    run_root,
    model_tool,

    fn emitToolStart(self: EventProjection, emit_tool_cards: bool, agent_depth: u8) bool {
        return switch (self) {
            .legacy => emit_tool_cards and agent_depth == 0,
            .run_root, .model_tool => true,
        };
    }

    fn emitToolResult(self: EventProjection, emit_tool_cards: bool) bool {
        return switch (self) {
            .legacy => emit_tool_cards,
            .run_root, .model_tool => true,
        };
    }

    fn emitToolProgress(self: EventProjection, agent_depth: u8) bool {
        return switch (self) {
            .legacy => agent_depth == 0,
            .run_root, .model_tool => true,
        };
    }

    fn allowUiRequests(self: EventProjection, agent_depth: u8) bool {
        return switch (self) {
            .legacy => agent_depth == 0,
            .run_root, .model_tool => true,
        };
    }
};

test "EventProjection is orthogonal to true agent depth and preserves legacy defaults" {
    try std.testing.expect(EventProjection.legacy.emitToolStart(true, 0));
    try std.testing.expect(!EventProjection.legacy.emitToolStart(true, 1));
    try std.testing.expect(EventProjection.legacy.emitToolResult(true));
    try std.testing.expect(!EventProjection.legacy.emitToolResult(false));

    try std.testing.expect(EventProjection.run_root.emitToolStart(false, 7));
    try std.testing.expect(EventProjection.run_root.emitToolResult(false));
    try std.testing.expect(EventProjection.run_root.emitToolProgress(7));
    try std.testing.expect(EventProjection.run_root.allowUiRequests(7));
    try std.testing.expect(EventProjection.model_tool.emitToolStart(false, 7));
    try std.testing.expect(EventProjection.model_tool.emitToolResult(false));
    try std.testing.expect(EventProjection.model_tool.emitToolProgress(7));
    try std.testing.expect(EventProjection.model_tool.allowUiRequests(7));
}

/// 工具进度 trampoline:把工具的 progress 回调(WebSearch query/results)转成 CoreEvent,
/// 经 backend 路由到归属 session 的 UI。per-run 实例(backend + session),progress_state 指它。
///
/// **生命周期 invariant**:progress_state 指向的 ProgressTramp 栈变量(agent_loop while-turn
/// 块内)必须活过 `executeSlots`——progress_fn 只在 executeSlots 同步执行期间被工具回调,
/// 那时存储仍在帧上。**若将来把工具执行改成异步/跨 turn 持有 ctx,必须把它移到更长寿的存储**
/// (否则 progress_fn 在栈回收后触发 = UAF)。
const ProgressTramp = struct {
    be: *const UiBackend,
    session: @import("session_id.zig").SessionId,
    fn cb(state: *anyopaque, id: []const u8, phase: tools_mod.ToolContext.ProgressPhase, text: []const u8, count: u32) void {
        const self: *@This() = @ptrCast(@alignCast(state));
        var buf: [192]u8 = undefined;
        const line: []const u8 = switch (phase) {
            // 对齐 cc UI.tsx:query_update→"Searching: q";results_received→"Found N results…".
            .query_update => std.fmt.bufPrint(&buf, "Searching: {s}", .{text}) catch text,
            .results_received => std.fmt.bufPrint(&buf, "Found {d} results for \"{s}\"", .{ count, text }) catch text,
        };
        // line 是栈 borrow,emit 同步消费(TuiBackend.setToolProgress 立即拷进定长卡)。
        self.be.emitEvent(self.session, .{ .tool_progress = .{ .id = id, .text = line } });
    }
};

/// **U6 A2:工具→父 backend 通知 trampoline**。Task 生 subagent / TaskUpdate 改 DAG 时,工具经
/// ctx.event_reporter 把 agent_lifecycle / tasks_changed 转发到父 backend.emitEvent。生命周期同
/// ProgressTramp(栈变量活过 executeSlots;若工具执行改异步跨 turn 持有 ctx,须移到更长寿存储)。
const EventTramp = struct {
    be: *const UiBackend,
    session: @import("session_id.zig").SessionId,
    fn agentCb(state: *anyopaque, ev: @import("protocol/ui_event.zig").AgentLifecycle) void {
        const self: *@This() = @ptrCast(@alignCast(state));
        self.be.emitEvent(self.session, .{ .agent_lifecycle = ev });
    }
    fn tasksCb(state: *anyopaque, ev: @import("protocol/ui_event.zig").TasksChanged) void {
        const self: *@This() = @ptrCast(@alignCast(state));
        self.be.emitEvent(self.session, .{ .tasks_changed = ev });
    }
};

/// Auto-compact 阈值下限:避免 catalog 返回异常小值(测试 mock、未知模型)导致每 turn 都 compact。
/// 低于这个值不做压缩。设为 32K——正常对话/工具调研远小于此,只有真逼近 context window 才触发。
pub const MIN_AUTO_COMPACT_THRESHOLD: usize = 32_000;
pub const COMPACT_MIN_SAVED_PERCENT: usize = 5;

/// Evaluation runs allow two bounded retries during connection setup/header
/// receipt, before any response stream is consumed. They remain one semantic
/// request under the same native budget and emit explicit retry telemetry;
/// after three physical attempts the rollout still fails closed.
pub fn providerAttemptLimit(evaluation_gated: bool) u32 {
    return if (evaluation_gated) 3 else client_mod.defaultMaxRetries();
}

/// 强制 auto-compact 阈值(测试/power-user 旋钮)。设 `METACODES_FORCE_COMPACT_AT=<tokens>` 后,
/// **直接**把 auto/micro 阈值钉到该值,绕过 formula(≈window-reserve)和 32K 下限——让真模型 e2e
/// 能在短对话里触发真实压缩+投影(否则 glm 262K 窗口下要灌 ~200K token 才够)。
/// 生产默认不设此 env → null → 走正常 formula+floor,行为不变。非法/0/空 → null(坏 env 不改行为)。
pub fn forcedAutoCompactThreshold() ?usize {
    const raw = std.c.getenv("METACODES_FORCE_COMPACT_AT") orelse return null;
    return parseForcedAutoCompactThreshold(std.mem.span(raw));
}

/// 纯解析(可单测,不碰 env):非法/0/空 → null。
fn parseForcedAutoCompactThreshold(raw: []const u8) ?usize {
    const v = std.fmt.parseInt(usize, raw, 10) catch return null;
    if (v == 0) return null;
    return v;
}

/// 强制 keep_recent(测试旋钮):`METACODES_FORCE_COMPACT_KEEP=<n>`。默认 keep_recent=10 需要 >10 条
/// 消息才有可丢的;调小它让"大的早期消息 + 几轮小追问"就能触发真实 summary 压缩(e2e 用)。
/// 生产默认不设 → null → 用正常 keep_recent。非法/0/空 → null。
pub fn forcedAutoCompactKeep() ?usize {
    const raw = std.c.getenv("METACODES_FORCE_COMPACT_KEEP") orelse return null;
    return parseForcedAutoCompactThreshold(std.mem.span(raw)); // 同款解析:非法/0/空 → null
}

/// L3 挂起信息:stop_reason==.suspended 时非空,带出挂起点供调用方落盘 + 恢复。
/// owned by run() 的 allocator;调用方用后 free(deinit)。
///
/// **API 配对约束(关键)**:Anthropic 要求 assistant 的每个 tool_use 在紧接 user 消息里都有
/// 对应 tool_result——不能拆成两次 user 消息。故挂起时**不**提交任何 partial user 消息;
/// 已完成工具(非 pending)的结果 stash 进 completed_results,resume 时与 pending 工具的迟来
/// 结果**一起**作为单条 user 消息补齐(A+B 同 turn),满足配对。
pub const SuspendInfo = struct {
    /// 待补迟来结果的 pending tool_use id(owned)。
    tool_use_id: []const u8,
    kind: []const u8, // custom UI 类型(owned)
    payload_json: []const u8, // 渲染规格(owned)
    /// 同轮已完成工具的结果(owned)。resume 时与 pending 的迟来结果一起补成单条 user 消息。
    completed_results: []CompletedResult,
    allocator: std.mem.Allocator,

    pub const CompletedResult = struct {
        tool_use_id: []const u8, // owned
        content: []const u8, // owned
        is_error: bool,
    };

    pub fn deinit(self: SuspendInfo) void {
        self.allocator.free(self.tool_use_id);
        self.allocator.free(self.kind);
        self.allocator.free(self.payload_json);
        for (self.completed_results) |cr| {
            self.allocator.free(cr.tool_use_id);
            self.allocator.free(cr.content);
        }
        self.allocator.free(self.completed_results);
    }
};

pub const RunResult = struct {
    stop_reason: StopReason,
    turns: u32,
    tool_calls: u32,
    /// L3:仅 stop_reason==.suspended 时非空。调用方据此落盘 suspend.json + 投递 UI 请求,
    /// 响应到达后 resumeRun 注入。用后 deinit。
    suspend_info: ?SuspendInfo = null,
};

pub const Options = struct {
    /// **唯一兜底 backstop**(对齐 codex:无主动熔断,只靠 max_turns + 用户中断)。
    /// 轮数不度量任何真实风险,只防真失控。长任务靠 pre-sampling auto-compact 压缩续接。
    max_turns: u32 = 400,
    /// **成本次闸**(度量真实"烧钱"维度,与轮数正交)。本 run 累计成本(USD)达此值 → 停
    /// (.budget),交互层询问用户是否继续(不自动续)。null = 不设预算(默认)。
    cost_budget_usd: ?f64 = null,
    /// Checked at every provider side-effect boundary, including compact
    /// summaries and same-turn context-recovery retries. A denial happens
    /// before network I/O and returns stop_reason=budget.
    request_gate: ?request_gate_mod.Gate = null,
    /// Optional execution-effect boundary. Null preserves the direct embedded
    /// path; durable Hosts and deterministic tests install an explicit adapter.
    execution_boundary: ?execution_effect.Boundary = null,
    /// 本次 run 归属的会话(emit/poll 路由用)。默认 .single(N=1/TUI);M6 多 Session 时
    /// 由 SessionContext 传各自的 id。所有 backend.emitEvent 用它路由到对应 UI 视图。
    session: @import("session_id.zig").SessionId = @import("session_id.zig").SessionId.single,
    system_prompt: ?[]const u8 = null,
    /// 首条 user-context message(对齐 cc prependUserContext):CLAUDE.md 链 + AutoMem +
    /// currentDate,`<system-reminder>` 包裹。仅主 session 传(subagent 走 preload 自己的链)。
    /// null → 不 prepend(headless/subagent/无记忆)。由 user_context.build 生成,owned-by-caller,
    /// 生命周期须覆盖整个 run。
    inject_user_context: ?[]const u8 = null,
    /// One-shot user-role steering item appended to the first API request only.
    /// This is intentionally not written to Conversation/transcript; extensions such
    /// as /loop use it to continue work without fabricating a persisted user turn.
    synthetic_user_input: ?[]const u8 = null,
    verbose: bool = false,
    abort: ?*const AbortSignal = null,
    /// 转后台请求信号(Ctrl+B 生成期置位)。run() 每轮**开头**(turn 边界,conversation 干净时)
    /// load 一次,命中则返回 stop_reason=.backgrounded(不中断当前未完成的 turn)。调用方据此把
    /// 主对话深拷贝转后台续跑。与 abort 分开:abort 是用户中断(对话留前台),background 是转后台续跑。
    /// null → 不支持转后台(headless/子 agent)。
    background_request: ?*const std.atomic.Value(bool) = null,
    /// 传给 Write/Edit 做 must-read-first 校验。null → 单测/headless 简化路径（不校验）
    read_state: ?*ReadState = null,
    /// Edit/Write 旁路高亮缓存(diff 工具卡 tree-sitter 着色用)。null → 不缓存。
    edit_hl_cache: ?*@import("edit_hl_cache.zig").EditHlCache = null,
    /// LSP 服务(CLI 默认开,`--no-lsp` 关)。透传进 ToolContext 供 Edit/Write finalizeWrite +
    /// CodeMap/FindSymbol/Read-outline 用。
    ///
    /// **不透传进 subagent(登记的已知局限)**:`core/subagent.zig` 刻意不把它放进子 loop 的
    /// Options,所以 subagent 里这四项能力一律报 `lsp_disabled`。原因不是疏忽——`lsp/client.zig`
    /// 的线程模型白纸黑字要求 `sendRequest`/`sendNotification` 由**单一 caller 线程**串行调用,
    /// 而 subagent 跑在后台线程上;直接透传会让两个线程交错写同一个 server 的 stdin。要放开得先
    /// 给 Client 加发送侧串行化,那是 LSP 子系统的改动,不是加一行 `.lsp = opts.lsp`。
    lsp: ?*@import("../lsp/service.zig").Service = null,
    /// 自动 compact 的 token 阈值。null → 按 input context window 扣输出保留区后动态算。
    auto_compact_threshold: ?usize = null,
    /// 自动 compact 保留的消息数（最新的 N 条）
    auto_compact_keep_recent: usize = 10,
    /// Bash 后台作业注册表（给 ToolContext 用，工具侧 Bash/BashOutput/KillShell 用）
    jobs: ?*@import("job_registry.zig").JobRegistry = null,
    /// 后台 subagent 作业注册表（Task run_in_background + TaskOutput + TaskStop agent_ 分流用）
    agent_jobs: ?*@import("agent_job_registry.zig").AgentJobRegistry = null,
    /// Swarm 会话状态（TeamCreate/TeamDelete/SendMessage + Task name+team_name spawn）。
    /// null = 非 lead 上下文（subagent/headless）。透传进 base_ctx.swarm。
    swarm: ?*@import("../swarm/context.zig").SwarmContext = null,
    /// Plan mode 前的原始 mode 存储；EnterPlanMode/ExitPlanMode 用
    plan_prev_mode: ?*?types.PermissionMode = null,
    /// 模型 Task 清单（TaskCreate/Get/List/Update/Stop 共享）
    tasks: ?*@import("task_store.zig").TaskStore = null,
    kg: ?*@import("../kg/client.zig").KgClient = null,
    kg_projects_dir: []const u8 = "",
    /// 本 agent loop 的对外身份(KG claim 租约)。null = 沿用 session(主 loop:
    /// App.session_id 跨进程唯一且跨 turn 稳定)。subagent spawn 时必须显式 gen——
    /// 每个独立 agent loop 一个全局唯一 id,进程内并发 subagent 才互相有防撞。
    agent_ident: ?@import("session_id.zig").SessionId = null,
    /// Optional TinyKG-specific lease identity. Main sessions inherit
    /// `agent_ident`; swarm injects `name@team` so claim/release/close use one
    /// exact holder string throughout the task lifecycle.
    kg_agent_ident: ?[]const u8 = null,
    /// AutoMem memdir 绝对路径(B/C 合并 markdown 自动入图)。
    memdir_abs: []const u8 = "",
    /// Anthropic 具体 *Client(仅 web_search server tool 用;非 Anthropic provider → null)。
    /// **职责边界**:P0.5 后 subagent **构造** per-call client 已走 provider_factory.makeProvider
    /// (provider-neutral),此字段只剩 web_search 这个 Anthropic 专有 server tool 的入口——它必须
    /// 是 Anthropic 具体 client 才能发 server-tool 请求,故保持 *Client 而非 Provider。
    api_client: ?*@import("../client.zig").Client = null,
    /// Optional explicit per-call provider factory. Normal App runs derive this
    /// from agent_jobs; embedders such as AgentSession provide their own.
    provider_factory: ?@import("../api/provider_factory.zig").Factory = null,
    tool_defs: ?[]const @import("../json.zig").ToolDefinition = null,
    /// 本次 run 对应的 agent 嵌套深度（父=0，子=1…）
    agent_depth: u8 = 0,
    /// 运行时工具（Skill/MCP）注册表。null = 仅静态工具。
    dyn_registry: ?*const @import("../tools/dynamic.zig").DynRegistry = null,
    /// Embedding Sessions set this to route execution through the same
    /// immutable selection that produced `tool_defs`. Null preserves the App's
    /// existing process registry behavior.
    tool_dispatcher: ?tools_mod.ToolDispatcher = null,
    /// Host tool 执行身份(admission 处固定,AgentSession.runLoop 显式传值)。
    /// 可选 + null 默认:非 Host-tool 消费者零感知(共享基础设施扩展规则)。
    host_run: ?tools_mod.HostRunIdentity = null,
    /// L5:宿主能力聚合(Skill 激活 / ToolSearch 激活 / Worktree push-pop)。透传到 ToolContext。
    /// 见 ToolContext.HostServices。
    host_services: ?tools_mod.HostServices = null,
    /// 本轮的 Skill 工具调用是否为"用户显式 /name 触发"。
    /// 当前 Stage C 总是 false(只支持模型自主);Stage D 加 /<skill-name> 命令后置 true。
    explicit_invocation: bool = false,
    /// session id + project root + shell-exec policy(对接 Skill 渲染)。
    session_id: []const u8 = "",
    project_dir: []const u8 = "",
    disable_shell_execution: bool = false,
    /// Sandbox 配置(Bash 工具用):非 null 且 enabled 时包 sandbox-exec。
    sandbox: ?*const @import("../sandbox/config.zig").SandboxSettings = null,
    /// cwd 绝对路径 + HOME(sandbox profile 用)。
    cwd_abs: []const u8 = "",
    /// 相对工具路径是否以 cwd_abs 为基准解析。默认 false 保持 CLI 既有输出/路径语义；
    /// embedding AgentSession 显式开启，使 Host 提供的 Workspace 真正成为工具执行基准。
    resolve_relative_paths: bool = false,
    home_dir: []const u8 = "",
    /// Session directory that owns recoverable tool-result artifacts. The
    /// artifact envelope never exposes this path to the model.
    artifact_root: []const u8 = "",
    tool_result_metrics: ?*@import("tool_result_metrics.zig").Metrics = null,
    /// **Run 输出语义账本**(见 core/output_semantics.zig)。挂上后 run() 把每个可见输出段
    /// 连同它的定性(commentary/final/continued/partial/discarded)记进来,并把最终结果
    /// 组装好——调用方直接 `ledger.finalText()`,不必再从 Conversation 尾部猜"什么算 final"。
    /// null → 只发 output_segment_* 事件,不留账本。**不传给 subagent**:子 agent 的输出是
    /// 父 Run 的工具结果,不是父 Run 的最终答案。
    output_ledger: ?*@import("output_semantics.zig").Ledger = null,
    /// **文件修改结果账本**(见 core/file_change.zig)。挂上后本 Run 及其子执行
    /// (Agent/Skill/TaskBatch)产生的每条文件修改都记进来,上层无需解析 tool_result 里的
    /// 工具私有 `gitDiff` 字段。null → 只发 file_changes 事件,不留账本。
    file_change_journal: ?*@import("file_change.zig").Journal = null,
    /// 额外工作目录(--add-dir / additionalDirectories,绝对路径;sandbox 可写白名单)。
    additional_dirs: []const []const u8 = &.{},
    /// 当前 session plan 文件路径(ExitPlanMode 读盘兜底用;仅顶层接)。
    plan_file_path: []const u8 = "",
    /// 子 agent 定义集合(Task 工具据此找 subagent_type)。
    agents: ?*const @import("../agents/set.zig").AgentSet = null,
    /// 当前会话用的 model 名(供 subagent inherit 解析)。
    parent_model: []const u8 = "",
    /// 当前 provider 的模型档位表(透传进 ToolContext 供 Task/skill 档位解析)。
    model_tiers: ?*const @import("../api/model_tiers.zig").ProviderTiers = null,
    /// per-call model override(subagent 用 AgentDef.model 覆盖父 client.model)。
    /// null = 用 api_client.model;非 null = 本次 turn 循环的所有请求都用此 model。
    model_override: ?[]const u8 = null,
    /// /model 从大上下文窗口切到小窗口后，下一次采样前先用旧模型做一次 inline compact。
    /// 新模型可能已经装不下旧历史+compact prompt，旧模型仍可完成摘要。
    model_switch_compact: ?ModelSwitchCompact = null,
    /// Skill 集合(Task 工具 subagent preload_skills 字段用)。
    skills_set: ?*const @import("../skills/skill.zig").SkillSet = null,
    /// ToolSearch 激活的 deferred 工具名集。非 null 时:deferred 且不在此集的工具
    /// 不进 API tools 数组(降低弱后端工具菜单稀释)。null = 不过滤 deferred(全暴露)。
    activated_tools: ?*const std.StringHashMap(void) = null,
    /// Borrowed immutable upper bound for this execution context. The owner
    /// keeps it alive until this synchronous Run and all tool workers quiesce.
    execution_policy: ?tools_mod.ToolExecutionPolicy = null,
    /// UI-independent actual-dispatch observation capability. Unlike
    /// `emit_tool_cards`/EventProjection this remains active at every depth.
    tool_observer: ?tools_mod.ToolObservationSink = null,
    /// Project-specific Lean gate propagated to every ToolContext and depth.
    project_rule_gate: ?tools_mod.ProjectRuleGate = null,
    /// Opt-in experiment: after a host-reobserved file mutation, append one
    /// late checkpoint when a conservative test command succeeds. This never
    /// changes the stable system prompt or tool definitions.
    verification_checkpoint: bool = false,
    /// Session-end verification obligation: a premature final answer after an
    /// unverified mutation receives a bounded nudge (task-agnostic process
    /// rule; carries no benchmark or task content).
    verification_final_gate: bool = false,
    /// Record the session-end verification obligation outcome without ever
    /// nudging. Measurement-only: conversation and control flow untouched.
    /// Gives control arms the same outcome record the gate arms get.
    verification_final_observe: bool = false,
    /// Session-end requirement-ledger closure obligation: decompose the task
    /// statement into the task list and close every item before finishing.
    requirement_ledger: bool = false,
    /// Record-only twin for measurement symmetry in control arms.
    requirement_ledger_observe: bool = false,
    /// 任务范围收尾义务(运行期 author 学得的环境规则,ledger 同款有界
    /// nudge 哲学)。null = 无义务/关闭。
    obligations: ?*@import("obligation_gate.zig").Runtime = null,
    /// Bounded same-turn retries after a mid-stream provider failure. The
    /// stream-error path already discards the partial turn (nothing was
    /// committed to the conversation), so re-issuing the identical request is
    /// semantically clean. Default 0 preserves interactive behavior — a TUI
    /// user has watched the partial text stream and a silent re-run would
    /// duplicate it; headless evaluation enables 2, where one transient
    /// otherwise destroys an entire paired arm's evidence.
    max_stream_turn_retries: u8 = 0,
    /// 统一 UI 请求回调(替代旧 ask_question/exit_plan 三套;ctx 指 *TuiBackend)。
    /// 仅顶层 TUI 接(agent_depth==0)——子 agent 无 tty。见 UiRequester。
    ui_requester: ?@import("protocol/ui_request.zig").UiRequester = null,
    /// MCP session 列表(ListMcpResourcesTool/ReadMcpResourceTool 用)。
    mcp_sessions: ?*const []@import("mcp_session.zig").McpSessionEntry = null,
    /// Cron registry(CronCreate/Delete/List 用)。
    cron_registry: ?*@import("cron_registry.zig").CronRegistry = null,
    /// 是否给每个工具执行 emit tool_start/tool_result 事件(REPL=true)。
    /// 由 backend(TuiBackend)经 renderResult 渲染(Edit diff 着色 / 搜索摘要 / Read 摘要)。
    /// false(headless/单测)→ 不 emit 工具卡事件,保持纯净输出。
    /// (原 tool_render_theme: ?*const Theme,只当存在标志用;为解 core→UI 类型依赖降为 bool。)
    emit_tool_cards: bool = false,
    /// Raw semantic-event capture for forked executions. `.legacy` keeps all
    /// existing callers byte-for-byte compatible; AgentCore's private adapter
    /// performs the actual public projection.
    event_projection: EventProjection = .legacy,
    /// 子进程长命令"仍在运行"心跳回调(per-session,传给 ToolContext.spawn_tick_fn → spawn 层)。
    /// 重构前是 tools/common.zig 进程全局 g_progress_cb。REPL tty 下 loop.zig 设;headless=null。
    spawn_tick_fn: ?*const fn (elapsed_ms: u64, argv0: []const u8) void = null,
    /// 是否给 assistant 流式文本加 ANSI 着色(\x1b[32m…)。前台交互 REPL = true;
    /// 后台 subagent(输出经 SinkWriter 进可查询缓冲)/headless = false,否则 final_text
    /// 会混入 \x1b[32m 等控制码。
    colorize: bool = true,
};

pub const ModelSwitchCompact = struct {
    previous_model: []const u8,
    previous_context_window: u32,
    current_context_window: u32,
};

/// 内部:发一次进度事件(turn 1-based;tool_name/tool_input 空 = 仅更新轮次)。
/// tool_calls = 截至此刻累计工具调用数(单调)。L1 重构:轮/工具级进度从扁平回调
/// (旧 ProgressReporter → JobEntry)收编进 CoreEvent.progress 事件——单向通知=事件。
/// 顶层 TUI 后端忽略它;JobEntry 后端(subagent 进度树)消费它更新 turn/工具/token 行。
fn emitProgress(backend: *const UiBackend, sess: @import("session_id.zig").SessionId, turn: u32, tool_name: []const u8, tool_input: []const u8, tool_calls: u32) void {
    backend.emitEvent(sess, .{ .progress = .{ .turn = turn, .tool_name = tool_name, .tool_input = tool_input, .tool_calls = tool_calls } });
}

const EffectiveToolSet = struct {
    policy_filtered: ?[]json_mod.ToolDefinition = null,
    filtered_pool: ?[]json_mod.ToolDefinition = null,
    discovery_filtered: ?[]json_mod.ToolDefinition = null,
    deferred_filtered: ?[]json_mod.ToolDefinition = null,
    cap_filtered: ?[]json_mod.ToolDefinition = null,
    defs: []const json_mod.ToolDefinition = &.{},

    fn deinit(self: *EffectiveToolSet, allocator: std.mem.Allocator) void {
        if (self.policy_filtered) |pf| allocator.free(pf);
        if (self.filtered_pool) |fp| allocator.free(fp);
        if (self.discovery_filtered) |df| allocator.free(df);
        if (self.deferred_filtered) |df| allocator.free(df);
        if (self.cap_filtered) |cf| allocator.free(cf);
        self.* = .{};
    }
};

/// Provider tool_choice is advisory at compatibility gateways. Keep the
/// required-first contract provider-neutral by checking the full native
/// Conversation as well: only the exact call plus a successful paired result
/// releases the gate. This also survives request serialization differences.
fn conversationHasSuccessfulRequiredFirst(
    conversation: *const Conversation,
    route: dialect_mod.VisibleCapabilities.RequiredFirst,
) bool {
    for (conversation.messages.items, 0..) |message, message_index| {
        for (message.blocks) |block| {
            const tool_use = switch (block) {
                .tool_use => |value| value,
                else => continue,
            };
            if (!dialect_mod.matchesRequiredFirst(route, tool_use.name, tool_use.input))
                continue;
            for (conversation.messages.items[message_index + 1 ..]) |later| {
                for (later.blocks) |later_block| switch (later_block) {
                    .tool_result => |result| {
                        if (std.mem.eql(u8, result.tool_use_id, tool_use.id) and
                            !result.is_error) return true;
                    },
                    else => {},
                };
            }
        }
    }
    return false;
}

const MAX_REQUIRED_FIRST_REPAIRS: u8 = 2;

fn requiredFirstRepairText(
    allocator: std.mem.Allocator,
    route: dialect_mod.VisibleCapabilities.RequiredFirst,
) ![]u8 {
    if (route.argument_name) |argument_name| {
        if (route.argument_value) |argument_value| return std.fmt.allocPrint(
            allocator,
            "Required-first activation is still pending. Before any answer or other tool, call `{s}` exactly with {{\"{s}\":\"{s}\"}}. Do not repeat the previous answer.",
            .{ route.tool_name, argument_name, argument_value },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Required-first activation is still pending. Before any answer or other tool, call `{s}`. Do not repeat the previous answer.",
        .{route.tool_name},
    );
}

fn buildEffectiveToolSet(
    allocator: std.mem.Allocator,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    activated_tools: ?*const std.StringHashMap(void),
    execution_policy: ?tools_mod.ToolExecutionPolicy,
    provider: provider_mod.Provider,
) error{OutOfMemory}!EffectiveToolSet {
    var out = EffectiveToolSet{ .defs = tool_defs };

    const policy_filtered = blk: {
        const policy = execution_policy orelse break :blk tool_defs;
        var keep: std.ArrayList(json_mod.ToolDefinition) = .empty;
        errdefer keep.deinit(allocator);
        for (tool_defs) |definition| {
            if (!policy.allowsTool(definition.name)) continue;
            try keep.append(allocator, definition);
        }
        out.policy_filtered = try keep.toOwnedSlice(allocator);
        break :blk out.policy_filtered.?;
    };
    out.defs = policy_filtered;

    const pool_filter = @import("../skills/tool_pool_filter.zig");
    out.filtered_pool = pool_filter.filterToolDefs(allocator, policy_filtered, permission_ctx.active_skill) catch null;
    const skill_filtered = if (out.filtered_pool) |fp| fp else policy_filtered;
    out.defs = skill_filtered;

    // ToolSearch is useful only while at least one deferred schema remains in
    // the policy/Skill-visible catalog. Reapply the same invariant used by
    // tools.toToolDefinitionsFull after later runtime filtering, otherwise the
    // model receives a discovery tool that can only return NoToolMatch.
    const discovery_filtered = blk: {
        var has_deferred = false;
        var has_tool_search = false;
        for (skill_filtered) |definition| {
            has_deferred = has_deferred or definition.deferred;
            has_tool_search = has_tool_search or std.mem.eql(u8, definition.name, "ToolSearch");
        }
        if (has_deferred or !has_tool_search) break :blk skill_filtered;
        var keep: std.ArrayList(json_mod.ToolDefinition) = .empty;
        errdefer keep.deinit(allocator);
        for (skill_filtered) |definition| {
            if (std.mem.eql(u8, definition.name, "ToolSearch")) continue;
            try keep.append(allocator, definition);
        }
        out.discovery_filtered = try keep.toOwnedSlice(allocator);
        break :blk out.discovery_filtered.?;
    };
    out.defs = discovery_filtered;

    const effective_tool_defs = blk: {
        const acts = activated_tools orelse break :blk discovery_filtered;
        var has_deferred = false;
        for (discovery_filtered) |d| {
            if (d.deferred) {
                has_deferred = true;
                break;
            }
        }
        if (!has_deferred) break :blk discovery_filtered;

        var keep: std.ArrayList(json_mod.ToolDefinition) = .empty;
        for (discovery_filtered) |d| {
            if (d.deferred and !acts.contains(d.name)) continue;
            keep.append(allocator, d) catch {
                keep.deinit(allocator);
                break :blk discovery_filtered;
            };
        }
        out.deferred_filtered = keep.toOwnedSlice(allocator) catch {
            keep.deinit(allocator);
            break :blk discovery_filtered;
        };
        break :blk out.deferred_filtered.?;
    };
    out.defs = effective_tool_defs;

    const capability = @import("../api/capability.zig");
    const gated_tool_defs = blk: {
        var any_dropped = false;
        for (effective_tool_defs) |d| {
            if (capability.requiredCapability(d.name)) |cap| {
                if (!provider.supports(cap)) {
                    any_dropped = true;
                    break;
                }
            }
        }
        if (!any_dropped) break :blk effective_tool_defs;

        var keep: std.ArrayList(json_mod.ToolDefinition) = .empty;
        for (effective_tool_defs) |d| {
            if (capability.requiredCapability(d.name)) |cap| {
                if (!provider.supports(cap)) continue;
            }
            keep.append(allocator, d) catch {
                keep.deinit(allocator);
                break :blk effective_tool_defs;
            };
        }
        out.cap_filtered = keep.toOwnedSlice(allocator) catch {
            keep.deinit(allocator);
            break :blk effective_tool_defs;
        };
        break :blk out.cap_filtered.?;
    };
    out.defs = gated_tool_defs;
    return out;
}

/// L4:run 出口统一收口——发 diag_run_end 诊断事件后返回 result。每个 `return <result>` 改成
/// `return finishRun(backend, sess, trace_id, depth, <result>)`,保证所有出口(abort/api_error/
/// end_turn/tool_error/max_turns)都 emit run span 终点,无遗漏(对齐"诊断不沉默")。
///
/// **span 平衡契约**:正常完成的 turn(有工具→循环 / 无工具→end_turn)都发 diag_turn_end,
/// 每个 turn_begin 配一个 turn_end。异常终止(abort/api_error/tool_error)**不**发
/// turn_end——该 turn 未完成,由 run_end 的 stop_reason 标明死因。消费者:turn span 未闭合 +
/// run_end 非 end_turn/max_turns = 该 turn 被中断,正确语义,非 bug。
/// (tool_loop 保留为 ABI dead variant,不再生产;对齐 codex 无主动熔断。)
fn finishRun(backend: *const UiBackend, sess: @import("session_id.zig").SessionId, trace_id: [12]u8, depth: u8, result: RunResult) RunResult {
    backend.emitEvent(sess, .{ .diag_run_end = .{
        .trace_id = trace_id,
        .depth = depth,
        .turns = result.turns,
        .tool_calls = result.tool_calls,
        .stop_reason_name = @tagName(result.stop_reason),
    } });
    return result;
}

/// Run 级输出语义通道:开/关一个可见输出段,并把定性同时投到事件流与账本。
///
/// 关键不变式由 `output_semantics.Tracker` 保证:同一时刻至多一个段打开,每段恰关闭一次
/// (重复关闭是 no-op,不会造出配不上对的 `output_segment_end`)。因此调用点可以无条件
/// 调 `close`,不用先判断"现在到底开着没"。反向的配对由 `begin` 兜底:若某个循环出口
/// 漏了收段,下一轮 `begin` 先把悬开段以 .partial 收口再开新段,消费者永远不会看到
/// 无配对的 `output_segment_begin`(漏关仍是 bug——正文进不了 Ledger,故留 warn 日志)。
const OutputChannel = struct {
    backend: *const UiBackend,
    session: @import("session_id.zig").SessionId,
    ledger: ?*output_semantics.Ledger,
    tracker: output_semantics.Tracker = .{},
    /// 本段已流出的可见字节数。**权威计数**:兜底关闭时 assistant_text 缓冲已随 turn 作用域
    /// 释放,拿不到文本,但字节数仍必须如实上报。
    pending_bytes: u64 = 0,

    fn begin(self: *OutputChannel, turn: u32) void {
        // 配对兜底(见顶注):漏关的段在这里以 .partial 收口,end 事件照发。
        // Tracker.begin 直接覆盖 self.open,不经此处收口的话,那个 begin 事件
        // 永远等不到配对的 end,Ledger 也不记这段。
        if (self.tracker.isOpen()) {
            log.warn("agent", "output segment leaked open across turns; closing as partial (missing close at a loop exit)", .{});
            self.close(.partial, "");
        }
        const seg = self.tracker.begin(turn);
        self.pending_bytes = 0;
        self.backend.emitEvent(self.session, .{ .output_segment_begin = .{
            .index = seg.index,
            .turn = seg.turn,
            .group = seg.group,
        } });
    }

    fn note(self: *OutputChannel, bytes: usize) void {
        self.pending_bytes +|= bytes;
    }

    /// `text` 是本段已流出的可见字节(借用;record 内立即拷贝需要保留的部分)。段的 bytes
    /// 取自权威计数器而非 text.len——兜底路径传 "" 但字节数照报。
    fn close(self: *OutputChannel, disposition: output_semantics.Disposition, text: []const u8) void {
        const seg = self.tracker.close(disposition, self.pending_bytes) orelse return;
        self.pending_bytes = 0;
        self.backend.emitEvent(self.session, .{ .output_segment_end = .{
            .index = seg.index,
            .turn = seg.turn,
            .group = seg.group,
            .disposition = seg.disposition,
            .bytes = seg.bytes,
        } });
        if (self.ledger) |l| l.record(seg, text);
    }
};

/// 把本轮所有 slot 的文件修改证据一次性投出去(事件 + Run 级账本),并交出所有权。
///
/// **必须在工具阶段任何可能提前返回的分支之前调**——挂起(UiPending)、host fatal、
/// result_blocks 为空都发生在**盘可能已经真的改过**之后。让 `Slot.deinit` 静默回收这些
/// 记录,等于对上层谎报"这一轮没动文件"。
///
/// **幂等**:靠 slot 上的 `file_changes_drained` 标记,不靠 `file_changes == null`——被拒的
/// slot 本来就是 null,只看 null 会在第二次调用时重新缝合并重复上报。
fn drainFileChanges(
    slots: []tool_exec_mod.Slot,
    base_ctx: *const @import("../tools/context.zig").ToolContext,
    backend: *const UiBackend,
    sess: @import("session_id.zig").SessionId,
    journal: ?*file_change_mod.Journal,
    allocator: std.mem.Allocator,
) void {
    for (slots) |*s| {
        if (s.file_changes_drained) continue;
        s.file_changes_drained = true;
        // 权限/策略在 dispatch **之前**拒掉的文件工具:executeOne 从没跑过,没人替它说话。
        // 沉默会被读成"没涉及文件",所以在这里补一条 rejected。
        if (s.decision == .denied and s.file_changes == null) {
            const rejected = tool_exec_mod.rejectedFileChanges(allocator, base_ctx, s.name, s.id, s.input);
            s.file_changes = rejected.records;
            s.file_changes_overflow = rejected.overflow;
            s.file_changes_lost = rejected.lost;
        }
        const changes = s.file_changes orelse continue;
        backend.emitEvent(sess, .{ .file_changes = .{
            .id = s.id,
            .name = s.name,
            .changes = changes,
            .overflow = s.file_changes_overflow,
            .lost = s.file_changes_lost,
        } });
        if (journal) |j| {
            j.recordAll(changes);
            if (s.file_changes_overflow or s.file_changes_lost) j.noteTruncated();
        }
        // 投递完即释放:账本收的是克隆,事件是同步消费的借用,留着只是占内存到 turn 末。
        // 置 null 是与外层 `Slot.deinit` 的交接——两边都释放就是双重释放。
        file_change_mod.freeRecords(allocator, changes);
        s.file_changes = null;
    }
}

/// L2 用:证明 drain 的幂等性(重复调不重复上报)。生产路径每轮只调一次,但幂等是这个
/// 收口点的正确性前提之一,得能被测到。
pub fn drainFileChangesForTest(
    slots: []tool_exec_mod.Slot,
    base_ctx: *const @import("../tools/context.zig").ToolContext,
    backend: *const UiBackend,
    sess: @import("session_id.zig").SessionId,
    journal: ?*file_change_mod.Journal,
    allocator: std.mem.Allocator,
) void {
    drainFileChanges(slots, base_ctx, backend, sess, journal, allocator);
}

fn stopReasonForAbort(abort: ?*const AbortSignal) StopReason {
    return if (abort) |signal|
        if (signal.reason() == .evaluation_budget) .budget else .aborted
    else
        .aborted;
}

/// 一次用户请求的完整 agent 运行：发送当前 conversation 到 API，
/// 收集事件到 assistant message 里（text 和 tool_use blocks），
/// 如果有 tool_use 则执行、追加 tool_result 到 conversation，继续下一轮。
/// 直到没有 tool_use、turns 达到 max_turns、或 abort 触发。
///
/// 每轮的 assistant 响应文字也通过 backend 实时输出（便于 REPL 看流）。
/// backend 是显式 vtable 契约(UiBackend):agent_loop 只发语义 CoreEvent,所有表达
/// (ANSI 颜色 / 工具卡渲染)由 backend 实现(TuiBackend / WriterBackend)完成。
pub fn run(
    conversation: *Conversation,
    provider: provider_mod.Provider,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    opts: Options,
    backend: *const UiBackend,
    allocator: std.mem.Allocator,
) !RunResult {
    // 本次 run 归属的会话(emit/poll 路由用)。N=1/TUI 默认 .single;M6 由 SessionContext 传。
    const sess = opts.session;
    // L4:run 级 trace_id(整个 run 一个,跨所有 turn);诊断事件内联携带,DiagnosticsBackend
    // 据 trace_id+depth 重建 span 树。depth = agent 嵌套深度(父 0 子 1)。
    const trace_id = log.genRequestId().bytes;
    const depth = opts.agent_depth;
    var turns: u32 = 0;
    var verification_progress = verification_progress_mod.State{};
    var total_tool_calls: u32 = 0;
    // max_tokens 续写计数:防止模型一直撞上限导致无限续写。上限 3 次。
    var continuations: u32 = 0;
    // 输出语义通道:每个 provider stream 一个可见输出段,定性在 loop **真正知道**时才发。
    // defer 是兜底——任何忘记定性的退出路径把仍打开的段记为 partial(诚实读法:Run 结束了,
    // 但从没判定这段是答案)。显式定性发生在前,兜底只在遗漏时生效。
    var output_channel = OutputChannel{ .backend = backend, .session = sess, .ledger = opts.output_ledger };
    defer output_channel.close(.partial, "");
    var verification_nudges: u8 = 0;
    var required_first_repairs: u8 = 0;
    const MAX_VERIFICATION_NUDGES: u8 = 2;
    var stream_turn_retries: u8 = 0;
    var requirement_ledger_state = requirement_ledger_mod.State{};
    // 元规则①:全部 host 注入共享一个计量器——各门自证有界不蕴含合成
    // 有界(Lean HostInjectionMeter.consumed_never_exceeds_cap 对任意门
    // 序列量化)。
    var host_injection_meter = @import("host_injection_meter.zig").Meter{};
    defer if (opts.requirement_ledger or opts.requirement_ledger_observe) {
        if (opts.tool_observer) |observer| {
            const counts = if (opts.tasks) |store|
                store.ledgerCounts()
            else
                @import("task_store.zig").LedgerCounts{ .open = 0, .total = 0 };
            _ = observer.emit(.{ .requirement_ledger = .{
                .enforced = opts.requirement_ledger,
                .prompt_emitted = requirement_ledger_state.prompt_emitted,
                .items_total = @intCast(@min(counts.total, std.math.maxInt(u32))),
                .items_open_at_final = @intCast(@min(counts.open, std.math.maxInt(u32))),
                .mutations_occurred = verification_progress.mutation_seen,
                .nudges = requirement_ledger_state.nudges,
                .max_nudges = requirement_ledger_mod.MAX_LEDGER_NUDGES,
            } });
        }
    };
    defer if (opts.verification_final_gate or opts.verification_final_observe) {
        if (opts.tool_observer) |observer| {
            _ = observer.emit(.{ .verification_final_gate = .{
                .enforced = opts.verification_final_gate,
                .mutations_occurred = verification_progress.mutation_seen,
                .obligation_met = !verification_progress.unverified_mutation,
                .nudges = verification_nudges,
                .max_nudges = MAX_VERIFICATION_NUDGES,
                .tier1_verifications = verification_progress.tier1_verifications,
                .tier2_verifications = verification_progress.tier2_verifications,
                .redundant_verifications = verification_progress.redundant_verifications,
                .final_closure_tier = verification_progress.final_closure_tier,
                .reopened_after_verification = verification_progress.reopened_after_verification,
                .known_failing = verification_progress.known_failing,
            } });
        }
    };
    const MAX_CONTINUATIONS: u32 = 3;

    // Governed lexical recall is run-scoped: the model proposes aliases and
    // variants, while this bounded host ledger remembers only node ids that
    // were actually returned. It is shared by every turn/tool context in this
    // run and never persisted into the canonical TinyKG store.
    var kg_lexical_ledger = @import("../kg/lexical_query_plan.zig").Ledger{};
    const kg_retrieval_protocol = @import("../kg/retrieval_protocol.zig");
    const kg_enumeration_query_hint = kg_retrieval_protocol.queryRequiresEnumerationCoverage(latestUserText(conversation)) or
        (if (opts.synthetic_user_input) |synthetic|
            kg_retrieval_protocol.queryRequiresEnumerationCoverage(synthetic)
        else
            false);
    var kg_coverage_reminder_emitted = false;
    var kg_context_reminder_emitted = false;
    var kg_coverage_repair_attempts: u8 = 0;
    var kg_context_repair_attempts: u8 = 0;
    var kg_coverage_borrowed_turns: u32 = 0;
    // 成本次闸:累计本 run 成本(USD),达 opts.cost_budget_usd → 停(.budget)。
    const cost_rates = @import("../util/pricing.zig").rateFor(provider.model());
    var run_cost_usd: f64 = 0;

    // Prompt cache 击穿检测(批3):跨 turn 跟踪 cache_read 跌幅 + system/tools 指纹。
    var cache_detector = @import("cache_break.zig").CacheBreakDetector{};
    var context_warning_emitted = false;
    // Paid no-savings summaries feed their measured overhead back into the
    // next optimistic preview. This is run-scoped on purpose: it suppresses
    // immediate retry storms without persisting model-specific estimates into
    // the transcript or across process revisions.
    var compact_summary_reserve_tokens: usize = 0;

    while (turns < opts.max_turns +| kg_coverage_borrowed_turns) : (turns += 1) {
        // 开头检查 abort
        if (opts.abort) |a| if (a.isAborted()) {
            log.warn("agent", "aborted before turn {d}", .{turns + 1});
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = stopReasonForAbort(opts.abort), .turns = turns, .tool_calls = total_tool_calls });
        };
        // 成本次闸:本 run 累计成本达预算 → 停,交互层询问是否继续(不自动续)。
        if (opts.cost_budget_usd) |budget| {
            if (run_cost_usd >= budget) {
                log.warn("agent", "cost budget reached: ${d:.4} >= ${d:.4}", .{ run_cost_usd, budget });
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .budget, .turns = turns, .tool_calls = total_tool_calls });
            }
        }

        // 转后台请求(Ctrl+B):turn 边界检查——此刻 conversation 干净(上轮 tool_result 已 append),
        // 返回 .backgrounded 让调用方深拷贝转后台续跑。**只在 turn 开头查**(run 是同步循环,无中途
        // 暂停点;唯一安全转后台点是 turn 边界)。与 abort 分开:这不是中断,是把完整对话搬去后台。
        if (opts.background_request) |bg| if (bg.load(.acquire)) {
            log.info("agent", "background requested before turn {d} → backgrounding", .{turns + 1});
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .backgrounded, .turns = turns, .tool_calls = total_tool_calls });
        };

        // 进度事件:进入新一轮(1-based);空 tool 名 = 仅推进轮次,保留上一个工具
        // (JobEntry 后端据空名跳过工具更新,对齐 cc 持续显示最近动作)。
        emitProgress(backend, sess, turns + 1, "", "", total_tool_calls);
        // L4 诊断:turn span 起点。
        backend.emitEvent(sess, .{ .diag_turn_begin = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1 } });

        // 工具池过滤必须在 prompt 投影和 compact 判断之前完成。App 初始化时构造的
        // prompt 不知道 per-run execution policy；先算真实 pool，才能避免 prompt 广告
        // provider schema 已隐藏的 deferred tool。
        var effective_tools = try buildEffectiveToolSet(
            allocator,
            tool_defs,
            permission_ctx,
            opts.activated_tools,
            opts.execution_policy,
            provider,
        );
        defer effective_tools.deinit(allocator);
        // 对齐 codex:无 breaker_finalization gate,gated_tool_defs 即 effective_tools.defs。
        // 保留别名减少下游改动,为将来可选 gate 预留。
        const gated_tool_defs: []const json_mod.ToolDefinition = effective_tools.defs;
        const visible_capabilities = dialect_mod.visibleCapabilities(
            @as(?[]const json_mod.ToolDefinition, gated_tool_defs),
        );
        const required_first_route = visible_capabilities.required_first;
        const required_first_pending = if (required_first_route) |route|
            !conversationHasSuccessfulRequiredFirst(conversation, route)
        else
            false;
        // The full native Conversation deliberately outlives its compacted
        // provider window. Preserve that Host fact in a turn-local shallow
        // copy so serializers do not re-force activation after the paired
        // call/result has moved behind the compact boundary. `satisfied` is
        // host-only metadata: serialized tool schemas and capability prompt
        // bytes remain identical, which keeps the provider cache prefix stable.
        var provider_tool_defs_owned: ?[]json_mod.ToolDefinition = null;
        defer if (provider_tool_defs_owned) |defs| allocator.free(defs);
        const provider_tool_defs: []const json_mod.ToolDefinition = blk: {
            const route = required_first_route orelse break :blk gated_tool_defs;
            if (required_first_pending) break :blk gated_tool_defs;
            const copied = try allocator.dupe(json_mod.ToolDefinition, gated_tool_defs);
            provider_tool_defs_owned = copied;
            for (copied) |*definition| {
                if (!std.mem.eql(u8, definition.name, route.tool_name)) continue;
                var activation = definition.model_activation orelse continue;
                if (activation.mode != .required_first) continue;
                activation.satisfied = true;
                definition.model_activation = activation;
            }
            break :blk copied;
        };
        // Deferred catalog sees policy + active-skill filtering, but intentionally
        // precedes activation filtering: unactivated deferred tools are exactly
        // the tools the catalog exists to advertise.
        const deferred_catalog_defs = if (effective_tools.discovery_filtered) |defs|
            defs
        else if (effective_tools.filtered_pool) |defs|
            defs
        else if (effective_tools.policy_filtered) |defs|
            defs
        else
            tool_defs;

        // Plan 模式每轮把 plan 指令追加到 system prompt(对齐 mecode 每轮 developer_instructions):
        // 根治"指令只在 EnterPlanMode 返回出现一次,后续轮模型忘了 <proposed_plan> 格式"。
        // turn 作用域 alloc,用后 free;非 plan 模式直接用 opts.system_prompt(零开销)。
        var sys_prompt_owned: ?[]u8 = null;
        defer if (sys_prompt_owned) |p| allocator.free(p);
        const augmented_system_prompt: ?[]const u8 = blk: {
            const in_plan = permission_ctx.modeValue() == .plan;
            // swarm 纪律:有 team 时追加 addendum(裸文本对 teammate 不可见,必须用 SendMessage;
            // 对齐 cc teammate addendum,Linus/PM SW2 F3)。lead 与 teammate 都注入。
            const in_swarm = if (opts.swarm) |s| s.hasTeam() else false;
            if (!in_plan and !in_swarm) break :blk opts.system_prompt;
            const base = opts.system_prompt orelse "";
            const plan_seg = if (in_plan) "\n\n# Plan Mode (active)\n" ++ @import("../tools/plan_mode.zig").PLAN_MODE_INSTRUCTIONS else "";
            const swarm_seg = if (in_swarm) "\n\n" ++ @import("../swarm/tools.zig").SWARM_ADDENDUM else "";
            sys_prompt_owned = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base, plan_seg, swarm_seg }) catch null;
            break :blk if (sys_prompt_owned) |p| p else opts.system_prompt;
        };
        var projected_guidance_owned: ?[]u8 = null;
        defer if (projected_guidance_owned) |p| allocator.free(p);
        var projected_deferred_owned: ?[]u8 = null;
        defer if (projected_deferred_owned) |p| allocator.free(p);
        var projected_capabilities_owned: ?[]u8 = null;
        defer if (projected_capabilities_owned) |p| allocator.free(p);
        const effective_system_prompt: ?[]const u8 = blk: {
            const base = augmented_system_prompt orelse break :blk null;
            const system_prompt_mod = @import("system_prompt.zig");
            projected_guidance_owned = try system_prompt_mod.projectUsingToolsForExecution(
                allocator,
                base,
                gated_tool_defs,
            );
            const guidance_projected = if (projected_guidance_owned) |p| p else base;
            projected_deferred_owned = try system_prompt_mod.projectDeferredToolsForExecution(
                allocator,
                guidance_projected,
                deferred_catalog_defs,
                gated_tool_defs,
            );
            const deferred_projected = if (projected_deferred_owned) |p| p else guidance_projected;
            projected_capabilities_owned = try system_prompt_mod.projectCapabilitySectionsForExecution(
                allocator,
                deferred_projected,
                gated_tool_defs,
            );
            break :blk if (projected_capabilities_owned) |p| p else deferred_projected;
        };

        // 自动 compact：发请求前检查 token 估算,超阈值则保留最近 N 条。
        // 阈值 null 时 = input context window * 0.8(逼近 context 上限才压缩,留出回复空间)。
        // **必须用 input context window(resolveMaxInputTokens,~200K),不是 output max_tokens(32K)**——
        // 否则正常工具调研刚读几个文件(20K+)就误触发压缩、丢掉原始问题(真机 bug)。
        // 下限 MIN_AUTO_COMPACT_THRESHOLD:避免异常小值导致每 turn 都 compact。
        const synthetic_user_input = if (turns == 0) opts.synthetic_user_input else null;
        const model_switch_compact = if (turns == 0) opts.model_switch_compact else null;
        var previous_model_compact_outcome: AutoCompactOutcome = .not_needed;
        if (model_switch_compact) |msc| {
            if (!std.mem.eql(u8, msc.previous_model, provider.model()) and msc.previous_context_window > msc.current_context_window) {
                previous_model_compact_outcome = try runAutoCompactIfNeeded(
                    conversation,
                    provider,
                    effective_system_prompt,
                    opts.inject_user_context,
                    synthetic_user_input,
                    provider_tool_defs,
                    opts.model_override,
                    msc.previous_model,
                    opts.auto_compact_threshold,
                    opts.auto_compact_keep_recent,
                    "pre_sampling_previous_model_smaller_window",
                    backend,
                    sess,
                    trace_id,
                    depth,
                    turns + 1,
                    &context_warning_emitted,
                    allocator,
                    opts.tasks,
                    permission_ctx.hooks,
                    &compact_summary_reserve_tokens,
                    opts.request_gate,
                    opts.abort,
                );
                if (previous_model_compact_outcome == .api_error) {
                    return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls });
                }
                if (previous_model_compact_outcome == .aborted) {
                    return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = stopReasonForAbort(opts.abort), .turns = turns, .tool_calls = total_tool_calls });
                }
            }
        }
        if (previous_model_compact_outcome != .skipped_no_savings) {
            const pre_sampling_compact = try runAutoCompactIfNeeded(
                conversation,
                provider,
                effective_system_prompt,
                opts.inject_user_context,
                synthetic_user_input,
                provider_tool_defs,
                opts.model_override,
                null,
                opts.auto_compact_threshold,
                opts.auto_compact_keep_recent,
                "pre_sampling_pending_turn_threshold",
                backend,
                sess,
                trace_id,
                depth,
                turns + 1,
                &context_warning_emitted,
                allocator,
                opts.tasks,
                permission_ctx.hooks,
                &compact_summary_reserve_tokens,
                opts.request_gate,
                opts.abort,
            );
            if (pre_sampling_compact == .api_error) {
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls });
            }
            if (pre_sampling_compact == .aborted) {
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = stopReasonForAbort(opts.abort), .turns = turns, .tool_calls = total_tool_calls });
            }
        }

        log.info("agent", "turn {d}/{d} starting (msgs={d})", .{ turns + 1, opts.max_turns, conversation.messages.items.len });

        // 建连阶段重试(对齐 CC withRetry):瞬态网络错误/429/5xx 退避重试,UI 提示"Retrying…"。
        // 仅覆盖建连+收头(未消费流、未输出文本);进入 stream.next() 后不再重试(已输出)。
        // 门控/格式/着色全在 backend 的 .retry_notice 处理(show_retry/colorize)——此处只转发。
        const RetryUi = struct {
            be: *const UiBackend,
            session: @import("session_id.zig").SessionId,
            boundary: ?execution_effect.Boundary,
            actor_id: @import("session_id.zig").SessionId,
            request_sha256: [64]u8 = [_]u8{'0'} ** 64,
            logical_turn: u32 = 0,
            context_generation: u32 = 0,
            active_attempt: u32 = 0,
            max_attempts: u32 = 0,

            fn prepare(
                self: *@This(),
                request_sha256: [64]u8,
                logical_turn: u32,
                context_generation: u32,
                max_attempts: u32,
            ) bool {
                if (self.active_attempt != 0 or max_attempts == 0) return false;
                self.request_sha256 = request_sha256;
                self.logical_turn = logical_turn;
                self.context_generation = context_generation;
                self.max_attempts = max_attempts;
                return self.startAttempt(1);
            }

            fn failed(state: *anyopaque, attempt: u32, max: u32, delay_ms: u64) bool {
                const self: *@This() = @ptrCast(@alignCast(state));
                if (attempt != self.active_attempt or max == 0 or
                    max > self.max_attempts or attempt >= max) return false;
                if (!self.finishAttempt(.api_error, .unknown)) return false;
                // TLS setup failures can tighten the generic retry ceiling.
                self.max_attempts = max;
                self.be.emitEvent(self.session, .{ .retry_notice = .{ .attempt = attempt, .max = max, .delay_ms = delay_ms } });
                return true;
            }

            fn beforeAttempt(state: *anyopaque, attempt: u32, max: u32) bool {
                const self: *@This() = @ptrCast(@alignCast(state));
                if (self.active_attempt != 0 or max == 0 or max > self.max_attempts)
                    return false;
                self.max_attempts = max;
                return self.startAttempt(attempt);
            }

            fn startAttempt(self: *@This(), physical_attempt: u32) bool {
                if (physical_attempt == 0 or physical_attempt > self.max_attempts) return false;
                const boundary = self.boundary orelse {
                    self.active_attempt = physical_attempt;
                    return true;
                };
                if (!boundary.emit(.{ .before = .{ .provider_request = .{
                    .attempt_id = self.attemptId(physical_attempt),
                    .actor_id = self.actor_id.bytes,
                    .request_sha256 = self.request_sha256,
                    .logical_turn = self.logical_turn,
                    .context_generation = self.context_generation,
                    .physical_attempt = physical_attempt,
                    .max_attempts = self.max_attempts,
                } } })) return false;
                self.active_attempt = physical_attempt;
                return true;
            }

            fn finishAttempt(
                self: *@This(),
                outcome: execution_effect.ProviderAttemptOutcome,
                metering: execution_effect.Metering,
            ) bool {
                const physical_attempt = self.active_attempt;
                if (physical_attempt == 0) return false;
                self.active_attempt = 0;
                const boundary = self.boundary orelse return true;
                return boundary.emit(.{ .after = .{ .provider_request = .{
                    .attempt_id = self.attemptId(physical_attempt),
                    .outcome = outcome,
                    .metering = metering,
                } } });
            }

            fn hasActiveAttempt(self: *const @This()) bool {
                return self.active_attempt != 0;
            }

            fn attemptId(self: *const @This(), physical_attempt: u32) [64]u8 {
                return execution_effect.providerAttemptId(
                    self.actor_id.bytes,
                    self.request_sha256,
                    self.logical_turn,
                    self.context_generation,
                    physical_attempt,
                );
            }
        };
        var retry_ui = RetryUi{
            .be = backend,
            .session = sess,
            .boundary = opts.execution_boundary,
            .actor_id = opts.agent_ident orelse sess,
        };
        const reporter = provider_mod.RetryReporter{
            .state = @ptrCast(&retry_ui),
            .failedFn = RetryUi.failed,
            .beforeAttemptFn = RetryUi.beforeAttempt,
        };

        // 1+2. 构造当前这一轮的 API 请求并发送。若建连/收头阶段或 SSE error
        // 明确报 context-window-exceeded,按 Rust compact recovery 路径逐步删最老
        // history 后重试。同一 turn 内重试,不把恢复尝试计成新 turn。
        var context_recovery_attempts: usize = 0;
        const context_recovery_cap = @max(conversation.len(), 1);
        var turn_stop_reason: api_stream.StopReason = .unknown;
        var rid_for_turn: log.RequestId = undefined;

        // 3. 收集响应 blocks。声明在 request_recovery 外层，使 SSE context
        // recovery 可以清空临时状态后重试同一 turn。
        var assistant_blocks = std.ArrayList(msg.Block).empty;
        errdefer {
            for (assistant_blocks.items) |b| b.deinit(allocator);
            assistant_blocks.deinit(allocator);
        }
        var assistant_text = std.ArrayList(u8).empty;
        defer assistant_text.deinit(allocator);

        // 思考过程累加器:本轮所有 thinking_delta/reasoning_content 拼成一个 thinking block,
        // 存入 assistant message(preserved thinking)。下轮请求 serializeContent 回传。
        var thinking_text = std.ArrayList(u8).empty;
        defer thinking_text.deinit(allocator);

        // provider 私有的推理续传项(issue #23,当前唯一生产者是 OpenAI Responses):
        // 按到达顺序收集 owned item JSON,turn 末转成 reasoning_item block 存进
        // assistant message,下轮同模型请求逐字节回传。丢弃残缺回合时随之释放。
        var reasoning_items = std.ArrayList([]u8).empty;
        defer {
            for (reasoning_items.items) |item| allocator.free(item);
            reasoning_items.deinit(allocator);
        }

        var tool_uses = std.ArrayList(msg.ToolUse).empty;
        defer tool_uses.deinit(allocator);

        // P0.4 流式预取:纯只读工具(Read/Grep/Glob)在其 tool_use_start 到达时就开线程执行,流末
        // executeSlots 直接用结果。仅当无 PreToolUse hook(避免 ModifyInput 让预取输入过时)时启用。
        const sp = @import("stream_prefetch.zig");
        var prefetch = sp.Prefetch.init(allocator);
        defer prefetch.deinit();
        const prefetch_enabled = if (permission_ctx.hooks) |h| !h.hasPre() else true;
        // 流期权限判定用的无 hook 上下文副本(不 mid-stream 跑 hook 副作用)。
        var pc_prefetch = permission_ctx.scopedDerive(null); // U4:单 seam 值拷贝+null sink
        pc_prefetch.hooks = null;
        // 预取用 ToolContext:**忠实镜像下方 base_ctx 的 opts.* 字段**(广播到 concurrency-safe 全集后
        // 只读 Bash/BashOutput/WebFetch 也流式,它们要 jobs/spawn_tick_fn/api_client 等——缺则行为分叉)。
        // 刻意排除三类 mid-stream 不安全/流末派生的:progress_reporter+ui_requester(流中不驱动 TUI/不
        // 弹询问,且 tool_start 卡尚未 emit)、last_proposed_plan(流末才提取,ExitPlanMode 非并发安全)、
        // hooks(经 pc_prefetch 剥离,PreToolUse 可 ModifyInput)、session/agent_ident(UiRequest 路由/kg
        // claim 身份,并发安全工具不用)。**维护约束**:base_ctx 新增字段若被并发安全工具读,须同步这里。
        var prefetch_ctx = tools_mod.ToolContext{
            .allocator = allocator,
            .abort = opts.abort,
            .read_state = opts.read_state,
            .edit_hl_cache = opts.edit_hl_cache,
            .lsp = opts.lsp,
            .jobs = opts.jobs,
            .agent_jobs = opts.agent_jobs,
            .permission_ctx = &pc_prefetch, // hooks 已剥离
            .plan_prev_mode = opts.plan_prev_mode,
            .tasks = opts.tasks,
            .kg = opts.kg,
            .kg_lexical_ledger = &kg_lexical_ledger,
            .kg_projects_dir = opts.kg_projects_dir,
            .memdir_abs = opts.memdir_abs,
            .api_client = opts.api_client,
            .provider = provider,
            .tool_defs = opts.tool_defs,
            .agent_depth = opts.agent_depth,
            .dyn_registry = opts.dyn_registry,
            .tool_dispatcher = opts.tool_dispatcher,
            .execution_policy = opts.execution_policy,
            .tool_observer = opts.tool_observer,
            .execution_boundary = opts.execution_boundary,
            .project_rule_gate = opts.project_rule_gate,
            .tool_observation_origin = .speculative_prefetch,
            .host_services = opts.host_services,
            .host_run = opts.host_run,
            .explicit_invocation = opts.explicit_invocation,
            .session_id = opts.session_id,
            .project_dir = opts.project_dir,
            .disable_shell_execution = opts.disable_shell_execution,
            .sandbox = opts.sandbox,
            .cwd_abs = opts.cwd_abs,
            .resolve_relative_paths = opts.resolve_relative_paths,
            .home_dir = opts.home_dir,
            .artifact_root = opts.artifact_root,
            // Mirrors base_ctx: Bash bounds its own channels against this, so a
            // prefetched Bash result must be sized by the same window as a
            // committed one or the two paths render differently.
            .result_budget = result_budget_mod.Budget.fromModel(provider.maxInputTokens()),
            .tool_result_metrics = opts.tool_result_metrics,
            .file_change_journal = opts.file_change_journal,
            .additional_dirs = opts.additional_dirs,
            .plan_file_path = opts.plan_file_path,
            .agents = opts.agents,
            .parent_model = opts.parent_model,
            .model_tiers = opts.model_tiers,
            .skills = opts.skills_set,
            .mcp_sessions = opts.mcp_sessions,
            .cron_registry = opts.cron_registry,
            .spawn_tick_fn = opts.spawn_tick_fn, // Bash/WebFetch 长命令心跳
        };

        request_recovery: while (true) {
            const model_request_started_ns = util_time.nowNs();
            var stream: api_stream.StreamHandle = undefined;
            var api_messages = try buildApiMessages(conversation, allocator, opts.inject_user_context, synthetic_user_input);
            defer freeApiMessages(&api_messages, allocator);
            if (opts.request_gate) |gate| {
                const max_input_tokens = serializedRequestInputTokenReserve(
                    allocator,
                    provider,
                    api_messages.items,
                    effective_system_prompt,
                    provider_tool_defs,
                    opts.model_override,
                ) catch std.math.maxInt(u64);
                if (!gate.allowsRequest(.{
                    .max_input_tokens = max_input_tokens,
                    .max_output_tokens = provider.maxTokens(),
                }))
                    return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .budget, .turns = turns, .tool_calls = total_tool_calls });
            }

            // 击穿检测必须跟真实 provider 前缀走：plan/swarm 会改变 effective
            // system prompt，同名工具也可能改变 description/input_schema。只看基础
            // system 或工具名会把真实前缀漂移误报成 TTL/server-side miss。
            {
                var th = std.hash.Wyhash.init(0);
                for (provider_tool_defs) |d| th.update(d.name);
                var tbuf: [16]u8 = undefined;
                std.mem.writeInt(u64, tbuf[0..8], th.final(), .little);
                const tool_schema = serializeToolSchemasForCache(allocator, provider_tool_defs) catch null;
                defer if (tool_schema) |bytes| allocator.free(bytes);
                const model_for_req = opts.model_override orelse provider.model();
                cache_detector.recordRequest(
                    effective_system_prompt orelse "",
                    tool_schema orelse tbuf[0..8],
                    model_for_req,
                );
            }

            const max_provider_attempts = providerAttemptLimit(opts.request_gate != null);
            const request_sha256 = if (opts.execution_boundary != null)
                canonicalAgentRequestSha256(
                    allocator,
                    provider,
                    api_messages.items,
                    effective_system_prompt,
                    provider_tool_defs,
                    opts.model_override,
                ) catch return finishRun(backend, sess, trace_id, depth, .{
                    .stop_reason = .api_error,
                    .turns = turns,
                    .tool_calls = total_tool_calls,
                })
            else
                [_]u8{'0'} ** 64;
            if (!retry_ui.prepare(
                request_sha256,
                turns + 1,
                @intCast(@min(context_recovery_attempts, std.math.maxInt(u32))),
                max_provider_attempts,
            )) return finishRun(backend, sess, trace_id, depth, .{
                .stop_reason = .api_error,
                .turns = turns,
                .tool_calls = total_tool_calls,
            });

            stream = provider.sendStreamRetry(
                api_messages.items,
                effective_system_prompt,
                provider_tool_defs,
                opts.abort,
                opts.model_override,
                null,
                max_provider_attempts,
                0, // base_ms=0 → 用默认 RETRY_BASE_MS(500)
                reporter,
                latestUserText(conversation), // web_search 显示用:用户原话(P1:作请求参数传, 不再 post-set)
            ) catch |err| {
                const attempt_outcome: execution_effect.ProviderAttemptOutcome = switch (err) {
                    error.ContextWindowExceeded => .context_window_exceeded,
                    error.Aborted => .aborted,
                    else => .api_error,
                };
                if (retry_ui.hasActiveAttempt() and
                    !retry_ui.finishAttempt(attempt_outcome, .unknown))
                    return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls });
                backend.emitEvent(sess, .{ .diag_model_request = .{
                    .trace_id = trace_id,
                    .depth = depth,
                    .turn = turns + 1,
                    .attempt = @intCast(@min(context_recovery_attempts, std.math.maxInt(u32))),
                    .elapsed_ms = elapsedSinceNs(model_request_started_ns),
                    .outcome = if (err == error.ContextWindowExceeded) "context_window_exceeded" else "api_error",
                } });
                switch (err) {
                    error.ContextWindowExceeded => {
                        if (!recoverContextWindowExceeded(
                            conversation,
                            provider,
                            effective_system_prompt,
                            opts.inject_user_context,
                            synthetic_user_input,
                            provider_tool_defs,
                            opts.model_override,
                            backend,
                            sess,
                            &context_recovery_attempts,
                            context_recovery_cap,
                            turns + 1,
                            allocator,
                        )) {
                            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls });
                        }
                        continue :request_recovery;
                    },
                    else => |e| {
                        log.err("agent", "sendMessageStream failed turn={d}: {s}", .{ turns + 1, @errorName(e) });
                        const stop_reason = if (e == error.Aborted)
                            stopReasonForAbort(opts.abort)
                        else
                            .api_error;
                        return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = stop_reason, .turns = turns, .tool_calls = total_tool_calls });
                    },
                }
            };
            defer stream.deinit();

            rid_for_turn = stream.requestId();
            const rid = rid_for_turn;
            log.infoId("agent", rid, "stream opened, reading events", .{});

            // This is a semantic model-attempt boundary, not only an ANSI
            // color hint. Consumers that observe lifecycle state must see it
            // after a retry succeeds even when colorization is disabled.
            backend.emitEvent(sess, .stream_begin);
            output_channel.begin(turns + 1);
            var aborted_during_stream = false;
            var stream_error = false;
            var stream_context_window_exceeded = false;
            var response_usage = @import("cache_break.zig").ResponseUsage{};
            while (true) {
                const ev_opt = stream.next() catch |err| switch (err) {
                    error.Aborted => {
                        aborted_during_stream = true;
                        log.warnId("agent", rid, "stream aborted mid-turn", .{});
                        break;
                    },
                    error.ContextWindowExceeded => {
                        stream_error = true;
                        stream_context_window_exceeded = true;
                        log.warnId("agent", rid, "stream returned context-window-exceeded at turn {d}", .{turns + 1});
                        break;
                    },
                    else => |e| {
                        stream_error = true;
                        log.errId("agent", rid, "stream returned error {s} at turn {d}", .{ @errorName(e), turns + 1 });
                        break;
                    },
                };
                const ev = ev_opt orelse break;
                switch (ev) {
                    .text => |text| {
                        backend.emitEvent(sess, .{ .text_chunk = text });
                        output_channel.note(text.len);
                        try assistant_text.appendSlice(allocator, text);
                        log.debugId("agent", rid, "text chunk bytes={d}", .{text.len});
                        // text bytes 是 stream 分配的 owned——用完必须 free，否则泄漏
                        allocator.free(text);
                    },
                    .thinking => |text| {
                        // 思考过程:不混入 assistant_text(最终回答),单独 emit 给 UI 折叠显示。
                        // preserved thinking:累加进 thinking_text,turn 末存入 thinking block,
                        // 下轮请求 serializeContent 回传给模型。
                        backend.emitEvent(sess, .{ .thinking_chunk = text });
                        try thinking_text.appendSlice(allocator, text);
                        log.debugId("agent", rid, "thinking chunk bytes={d}", .{text.len});
                        allocator.free(text);
                    },
                    .tool_use_start => |tu_in| {
                        var tu = tu_in;
                        // P0.6 弱模型健壮性:tool input 非法 JSON(markdown 围栏/trailing comma/括号不
                        // 配平/前置噪声)→ 尽力 salvage,兜底 {}。单一 choke point 覆盖所有 provider。
                        // tu.input_json 是 owned(stream 转移),修复则 free 旧、换 owned repaired。
                        if (!message_repair_mod.isValidJson(tu.input_json)) {
                            if (message_repair_mod.repairToolArgs(allocator, tu.input_json)) |repaired| {
                                log.warnId("agent", rid, "tool input repaired name={s}: {s} → {s}", .{ tu.name, tu.input_json, repaired });
                                allocator.free(tu.input_json);
                                tu.input_json = repaired;
                            } else |_| {} // repair OOM → 用原始(下游 tool 报错自纠)
                        }
                        // verbose 的 `[Tool: name]` 行移到 backend(在 tool_start 渲染时打,
                        // 见 TuiBackend/WriterBackend);此处只入队 tool_use。
                        log.infoId("agent", rid, "tool_use queued id={s} name={s} input_bytes={d}", .{ tu.id, tu.name, tu.input_json.len });
                        // stream 里 id/name/input_json 都是 owned；转移所有权给 tool_uses（不 dupe）
                        try tool_uses.append(allocator, .{
                            .id = tu.id,
                            .name = tu.name,
                            .input = tu.input_json,
                        });
                        // 流式执行(边流边跑):concurrency-safe(只读语义)+ 可流(非 WebSearch,不竞争
                        // 模型 client)+ 权限 allow(纯判定不 prompt)+ 无 PreToolUse hook → 立即开线程执行,
                        // 流末 executeSlots 直接用结果。广播自 P0.4 只读白名单(Read/Grep/Glob)到全 safe 集
                        // (加只读 Bash `git status`/`ls`、BashOutput、WebFetch)。borrow 刚 append 的稳定堆切片。
                        const not_aborted = if (opts.abort) |ab| !ab.isAborted() else true;
                        const activation_allows_prefetch = !required_first_pending or
                            if (required_first_route) |route|
                                dialect_mod.matchesRequiredFirst(route, tu.name, tu.input_json)
                            else
                                true;
                        if (prefetch_enabled and not_aborted and activation_allows_prefetch and sp.isStreamable(tu.name) and
                            prefetch_ctx.isPrefetchSafe(tu.name) and
                            tools_mod.isConcurrencySafeInput(tu.name, tu.input_json) and
                            permission_mod.checkPermission(&pc_prefetch, tu.name, tu.input_json) == .allow)
                        {
                            const last = &tool_uses.items[tool_uses.items.len - 1];
                            prefetch.start(&prefetch_ctx, last.id, last.name, last.input, rid);
                        }
                    },
                    .web_search_result => |w| {
                        // 主对话:照打 UI 装饰(⏺ Web Search ...),TUI 字节与旧版一致。
                        // ui_text 是预渲染的可见 assistant 内容(例外:含 ANSI 但属"可见输出")。
                        // content_json(结构化结果)主对话不消费(仅 web_search.zig 子请求用)。
                        backend.emitEvent(sess, .{ .text_chunk = w.ui_text });
                        output_channel.note(w.ui_text.len);
                        try assistant_text.appendSlice(allocator, w.ui_text);
                        allocator.free(w.ui_text);
                        allocator.free(w.content_json);
                    },
                    .web_search_query => |q| {
                        // 主对话不消费 query_update 进度(仅 web_search.zig 子请求驱动 TUI);释放。
                        allocator.free(q);
                    },
                    .reasoning_item => |item_json| {
                        // 不可读、不展示、不进 assistant_text——只按序留存供下轮回传。
                        // append 失败则就地释放(所有权尚未转移)。
                        log.debugId("agent", rid, "reasoning item bytes={d}", .{item_json.len});
                        reasoning_items.append(allocator, item_json) catch allocator.free(item_json);
                    },
                    .usage => |u| {
                        // L1:usage 走 CoreEvent 总线(顶层 TuiBackend 累加进 app.usage;
                        // JobEntry 后端累加进 .tokens 供进度树)——取代旧 opts.usage_sink 私有回调。
                        backend.emitEvent(sess, .{ .usage = u });
                        // 成本次闸累计(本 run):按模型单价把本响应 usage 折算成本。
                        run_cost_usd += @import("../util/pricing.zig").computeCost(cost_rates, u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens);
                        response_usage.observe(u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens);
                        log.infoId("agent", rid, "usage in={d} out={d} cache_r={d} cache_w={d}", .{ u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens });
                    },
                    .done => {},
                }
            }

            const provider_metering: execution_effect.Metering = if (response_usage.reported)
                .{ .known = .{
                    .input_tokens = response_usage.input_tokens,
                    .output_tokens = response_usage.output_tokens,
                    .cache_read_input_tokens = response_usage.cache_read_tokens,
                    .cache_creation_input_tokens = response_usage.cache_write_tokens,
                } }
            else
                .unknown;
            const provider_outcome: execution_effect.ProviderAttemptOutcome = if (aborted_during_stream)
                .aborted
            else if (stream_context_window_exceeded)
                .context_window_exceeded
            else if (stream_error)
                .stream_error
            else
                .succeeded;
            if (!retry_ui.finishAttempt(provider_outcome, provider_metering))
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls });

            // message_start/message_delta usage 是同一个 provider response 的片段，而不是
            // 两个请求。只在成功收完整条响应后更新 token anchor 和 cache detector；否则
            // preliminary zero usage 会把每个 warm request 误报成 cache break，partial error
            // 也会污染下一轮基线。
            if (!aborted_during_stream and !stream_error and response_usage.has_metering) {
                conversation.setUsageAnchor(@intCast(response_usage.promptTokens()));
                if (cache_detector.checkResponse(response_usage.cache_read_tokens, response_usage.cache_write_tokens)) |reason| {
                    log.warnId("cache", rid, "PROMPT CACHE BREAK: {s} [cache_read {d} creation {d}]", .{ reason, response_usage.cache_read_tokens, response_usage.cache_write_tokens });
                    backend.emitEvent(sess, .{ .diag_cache_break = .{
                        .trace_id = trace_id,
                        .depth = depth,
                        .cache_read = response_usage.cache_read_tokens,
                        .cache_creation = response_usage.cache_write_tokens,
                    } });
                }
            }
            backend.emitEvent(sess, .{ .diag_model_request = .{
                .trace_id = trace_id,
                .depth = depth,
                .turn = turns + 1,
                .attempt = @intCast(@min(context_recovery_attempts, std.math.maxInt(u32))),
                .elapsed_ms = elapsedSinceNs(model_request_started_ns),
                .outcome = if (aborted_during_stream)
                    "aborted"
                else if (stream_context_window_exceeded)
                    "context_window_exceeded"
                else if (stream_error)
                    "stream_error"
                else
                    "success",
            } });
            // 闭颜色括号 + 尾换行由 backend 决定(colorize ? "\x1b[0m\n" : "\n")。
            backend.emitEvent(sess, .stream_done);

            // 抓本轮 API 报告的 stop_reason(stream.deinit 前读;defer 在 turn 末才执行)
            turn_stop_reason = stream.stopReason();

            log.infoId("agent", rid, "stream finished text_bytes={d} tool_uses={d} aborted={} err={}", .{
                assistant_text.items.len,
                tool_uses.items.len,
                aborted_during_stream,
                stream_error,
            });

            if (aborted_during_stream) {
                // 保留已流出的 partial assistant text（对齐 TS 原版 `onCancel` 行为）：
                // 让用户看到已生成的内容；下次用 /retry 能继续。**语义**:可见但未完成 → partial,
                // 绝不能被上层当成最终结果。
                output_channel.close(.partial, assistant_text.items);
                // **先 join 预取线程**:它们 borrow tool_uses 的 id/name/input 字节,必须在下面 free
                // 之前 join,否则在飞 Read/Grep 读已释放内存(Linus HIGH-1 UAF)。
                prefetch.joinAll();
                // tool_uses 累了一半但没收齐 content_block_stop 时可能残缺——弃掉（不 commit）。
                for (tool_uses.items) |tu| {
                    allocator.free(tu.id);
                    allocator.free(tu.name);
                    allocator.free(tu.input);
                }
                tool_uses.clearRetainingCapacity();

                for (reasoning_items.items) |item| allocator.free(item);
                reasoning_items.clearRetainingCapacity();
                if (assistant_text.items.len > 0) {
                    const text_owned = try allocator.dupe(u8, assistant_text.items);
                    errdefer allocator.free(text_owned);
                    try assistant_blocks.append(allocator, .{ .text = text_owned });
                }
                if (assistant_blocks.items.len > 0) {
                    const blocks_slice = try assistant_blocks.toOwnedSlice(allocator);
                    try conversation.append(.{ .role = .assistant, .blocks = blocks_slice });
                } else {
                    assistant_blocks.deinit(allocator);
                }
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = stopReasonForAbort(opts.abort), .turns = turns + 1, .tool_calls = total_tool_calls });
            }

            // Stream error：不把残缺的 assistant_text / tool_uses commit 到 conversation
            // 否则下一轮会把残片作为 context 导致模型"续写"残片。
            // context-window-exceeded 若发生在任何 assistant payload 之前，可以安全删老
            // history 并重开同一 turn；一旦已经流出内容，就不能假装 UI 可回滚。
            if (stream_error) {
                // 残缺 assistant_text 下面会被整体丢弃(不 commit 到 conversation)→ discarded。
                // 消费者据此丢掉已缓冲的该段字节,不会把残片误当结果。
                output_channel.close(.discarded, assistant_text.items);
                const can_recover_context_error = stream_context_window_exceeded and
                    assistant_text.items.len == 0 and
                    tool_uses.items.len == 0 and
                    assistant_blocks.items.len == 0;
                // 先 join 预取线程再释放 tool_uses(它们 borrow 其字节),防 UAF(Linus HIGH-1)。
                prefetch.joinAll();
                for (tool_uses.items) |tu| {
                    allocator.free(tu.id);
                    allocator.free(tu.name);
                    allocator.free(tu.input);
                }
                tool_uses.clearRetainingCapacity();
                for (assistant_blocks.items) |b| b.deinit(allocator);
                assistant_blocks.clearRetainingCapacity();
                assistant_text.clearRetainingCapacity();
                thinking_text.clearRetainingCapacity();
                for (reasoning_items.items) |item| allocator.free(item);
                reasoning_items.clearRetainingCapacity();
                if (can_recover_context_error) {
                    if (!recoverContextWindowExceeded(
                        conversation,
                        provider,
                        effective_system_prompt,
                        opts.inject_user_context,
                        synthetic_user_input,
                        provider_tool_defs,
                        opts.model_override,
                        backend,
                        sess,
                        &context_recovery_attempts,
                        context_recovery_cap,
                        turns + 1,
                        allocator,
                    )) {
                        return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns + 1, .tool_calls = total_tool_calls });
                    }
                    continue :request_recovery;
                }
                // Mid-stream transient (connection drop, malformed tail):
                // the partial turn was fully discarded above, so a bounded
                // re-issue of the same request is safe. Aborts keep their
                // own path; context-window exhaustion was handled before.
                const abort_pending = if (opts.abort) |a| a.isAborted() else false;
                if (stream_turn_retries < opts.max_stream_turn_retries and
                    !abort_pending)
                {
                    stream_turn_retries += 1;
                    log.warnId("agent", rid_for_turn, "mid-stream failure → same-turn retry {d}/{d}", .{ stream_turn_retries, opts.max_stream_turn_retries });
                    continue :request_recovery;
                }
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns + 1, .tool_calls = total_tool_calls });
            }

            break :request_recovery;
        }
        const rid = rid_for_turn;

        // 4. 把 reasoning items + thinking + assistant text + tool_uses 组装成 Message
        // 追加到 conversation。顺序:thinking block 先于 text(对齐 Anthropic content[] 规范;
        // OpenAI-compatible 的 reasoning_content 平级字段由 request.zig 序列化时处理,
        // block 顺序无害)。
        // reasoning_item 排在最前:OpenAI Responses 的 `output` 就是 reasoning 在前,
        // 回传 `input` 亦然(reasoning → message/function_call)。
        // **不产出只有 reasoning 的 assistant 消息**:那种消息 buildApiMessages 会整条
        // 跳过(Anthropic 的 content 数组会空),于是它永远不上 wire,却仍被
        // estimateMessageTokens 按 REASONING_ITEM_TOKEN_ESTIMATE 计入——"发给模型的
        // 投影"与"token 估算"就此分叉,估算单调虚高、误触发 auto-compact。何况一个
        // 什么都没产出的回合,它的推理状态也没有可续的下文。这条不变式让
        // buildApiMessages 的 n_substantive 守卫在本进程内不可能被触发。
        const turn_has_content = assistant_text.items.len > 0 or tool_uses.items.len > 0;
        if (!turn_has_content) {
            for (reasoning_items.items) |item| allocator.free(item);
            reasoning_items.clearRetainingCapacity();
        }
        // 逐项**先摘表再转移**:append/dupe 在 OOM 下失败时,已转移项不再留在
        // reasoning_items 里,顶部 defer 与 assistant_blocks 的 errdefer 不会双释放。
        while (reasoning_items.items.len > 0) {
            const item_json = reasoning_items.orderedRemove(0);
            errdefer allocator.free(item_json);
            const model_owned = try allocator.dupe(u8, opts.model_override orelse provider.model());
            errdefer allocator.free(model_owned);
            try assistant_blocks.append(allocator, .{ .reasoning_item = .{
                .model = model_owned,
                .json = item_json,
            } });
        }
        if (thinking_text.items.len > 0) {
            const th_owned = try allocator.dupe(u8, thinking_text.items);
            errdefer allocator.free(th_owned);
            try assistant_blocks.append(allocator, .{ .thinking = th_owned });
        }
        if (assistant_text.items.len > 0) {
            const text_owned = try allocator.dupe(u8, assistant_text.items);
            errdefer allocator.free(text_owned);
            try assistant_blocks.append(allocator, .{ .text = text_owned });
        }
        for (tool_uses.items) |tu| {
            try assistant_blocks.append(allocator, .{ .tool_use = tu });
        }
        // 清空 tool_uses 的所有权转移表示：此后 tool_uses.items 内的字节归 assistant_blocks 所有
        tool_uses.clearRetainingCapacity();

        if (assistant_blocks.items.len > 0) {
            const blocks_slice = try assistant_blocks.toOwnedSlice(allocator);
            try conversation.append(.{ .role = .assistant, .blocks = blocks_slice });
        } else {
            // 空响应，避免 deinit 释放已归还的 slice
            assistant_blocks.deinit(allocator);
        }

        // 5. 如果这一轮没有 tool_use，整个请求结束
        const last_msg = &conversation.messages.items[conversation.messages.items.len - 1];
        var has_tool_use = false;
        for (last_msg.blocks) |b| if (@as(std.meta.Tag(msg.Block), b) == .tool_use) {
            has_tool_use = true;
            break;
        };
        // 本轮跟着工具调用 → 这段文字是执行过程中的可见说明,不是最终答案。
        if (has_tool_use) output_channel.close(.commentary, assistant_text.items);

        if (!has_tool_use) {
            // Some Anthropic-compatible gateways accept but ignore a forced
            // tool_choice. `required_first` is stronger than a prompt hint:
            // one bounded, provider-neutral repair keeps the model from
            // ending the Run before the exact activation boundary. Repeated
            // non-compliance fails closed instead of silently bypassing the
            // plugin contract.
            if (required_first_pending) {
                if (required_first_repairs >= MAX_REQUIRED_FIRST_REPAIRS or
                    !host_injection_meter.tryConsume())
                {
                    // fail-closed:定性与 run 顶部 defer 兜底一致(.partial),但必须趁
                    // assistant_text 还在作用域时显式收段——兜底只有权威字节数,Ledger
                    // 会丢这段 partial 正文。
                    output_channel.close(.partial, assistant_text.items);
                    backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
                    return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .tool_loop, .turns = turns + 1, .tool_calls = total_tool_calls });
                }
                required_first_repairs += 1;
                // 主机拒绝过早的"最终答案"并注入 required-first 修复 → 本段是过程
                // 信息(与其它 nudge 路径同款定性),不是答案。不收段的话它会跨轮
                // 悬开,破坏"段开/关严格配对"的协议不变式。
                output_channel.close(.commentary, assistant_text.items);
                const route = required_first_route.?;
                const repair = try requiredFirstRepairText(allocator, route);
                defer allocator.free(repair);
                log.warnId(
                    "agent",
                    rid,
                    "required-first route ignored; repair {d}/{d} tool={s}",
                    .{ required_first_repairs, MAX_REQUIRED_FIRST_REPAIRS, route.tool_name },
                );
                backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
                try conversation.appendText(.user, repair);
                continue;
            }
            // max_tokens 续写:模型被 token 上限截断(非自然 end_turn),
            // 注入 continue 提示让它接着写,而不是当作完成。最多 MAX_CONTINUATIONS 次。
            if (turn_stop_reason == .max_tokens and continuations < MAX_CONTINUATIONS) {
                continuations += 1;
                // 被 token 上限截断 → 本段与同 group 的下一段合成一个完整结果,单独任何一段
                // 都不是 final(`stream_done` 更不是)。
                output_channel.close(.continued, assistant_text.items);
                log.infoId("agent", rid, "max_tokens truncation → continuation {d}/{d}", .{ continuations, MAX_CONTINUATIONS });
                // L4 诊断:续写。
                backend.emitEvent(sess, .{ .diag_continuation = .{ .trace_id = trace_id, .depth = depth, .n = continuations, .max = MAX_CONTINUATIONS } });
                try conversation.appendText(.user, "Your previous response was cut off by the token limit. Continue exactly where you left off, without repeating.");
                continue;
            }
            const kg_pending = kgEnumerationPending(
                &kg_lexical_ledger,
                gated_tool_defs,
                kg_enumeration_query_hint,
            );
            if (kg_pending != .none) {
                const repair_attempts = switch (kg_pending) {
                    .batch => &kg_coverage_repair_attempts,
                    .context => &kg_context_repair_attempts,
                    .none => unreachable,
                };
                if (repair_attempts.* == 0) {
                    repair_attempts.* = 1;
                    // 主机判定这次"结论"覆盖不足并要求补检索 → 它不是最终答案,是过程信息。
                    output_channel.close(.commentary, assistant_text.items);
                    // A rejected batch-final may still need batch + context +
                    // final; a rejected context-final needs context + final.
                    // Budget/request gates still guard every provider boundary.
                    kg_coverage_borrowed_turns +|= switch (kg_pending) {
                        .batch => 3,
                        .context => 2,
                        .none => unreachable,
                    };
                    backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
                    try conversation.appendText(.user, switch (kg_pending) {
                        .batch => kg_retrieval_protocol.ENUMERATION_COVERAGE_REPAIR,
                        .context => kg_retrieval_protocol.ENUMERATION_CONTEXT_REPAIR,
                        .none => unreachable,
                    });
                    continue;
                }
                // A second premature final is not accepted as a valid answer.
                // Preserve the trace for audit and fail closed as a controlled
                // tool loop rather than laundering an uncovered conclusion.
                // 第二次未覆盖的"结论"不被接受为有效答案 → 已产出文本是 partial,不是 final。
                output_channel.close(.partial, assistant_text.items);
                backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
                return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .tool_loop, .turns = turns + 1, .tool_calls = total_tool_calls });
            }
            // Verification obligation (task-agnostic process rule): a final
            // answer after an unverified mutation gets a bounded nudge with a
            // concrete recovery protocol. Budget exhausted → finish normally
            // and record obligation_unmet; never block indefinitely.
            if (opts.verification_final_gate and
                verification_progress.unverified_mutation and
                verification_nudges < MAX_VERIFICATION_NUDGES and
                host_injection_meter.remaining() > 0)
            {
                _ = host_injection_meter.tryConsume();
                verification_nudges += 1;
                output_channel.close(.commentary, assistant_text.items);
                log.infoId("agent", rid, "verification final gate nudge {d}/{d}", .{ verification_nudges, MAX_VERIFICATION_NUDGES });
                backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
                try conversation.appendText(.user, if (verification_progress.known_failing)
                    verification_progress_mod.FINAL_GATE_KNOWN_FAILING_TEXT
                else
                    verification_progress_mod.FINAL_GATE_TEXT);
                continue;
            }
            // Requirement-ledger closure obligation: a final answer with open
            // ledger items (or with mutations but no ledger despite the
            // prompt) gets one bounded nudge per premature final. The
            // verification gate keeps priority — at most one injection per
            // round. Formal model: RequirementLedger.lean.
            if (opts.requirement_ledger and host_injection_meter.remaining() > 0) {
                const counts = if (opts.tasks) |store|
                    store.ledgerCounts()
                else
                    @import("task_store.zig").LedgerCounts{ .open = 0, .total = 0 };
                switch (requirement_ledger_state.decide(
                    counts.open,
                    counts.total,
                    verification_progress.mutation_seen,
                )) {
                    .none => {},
                    .open_items => {
                        _ = host_injection_meter.tryConsume();
                        requirement_ledger_state.nudges += 1;
                        output_channel.close(.commentary, assistant_text.items);
                        log.infoId("agent", rid, "requirement ledger nudge {d}/{d} open={d}", .{ requirement_ledger_state.nudges, requirement_ledger_mod.MAX_LEDGER_NUDGES, counts.open });
                        backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
                        const nudge = try std.fmt.allocPrint(
                            allocator,
                            requirement_ledger_mod.OPEN_NUDGE_FMT,
                            .{counts.open},
                        );
                        defer allocator.free(nudge);
                        try conversation.appendText(.user, nudge);
                        continue;
                    },
                    .coverage => {
                        _ = host_injection_meter.tryConsume();
                        requirement_ledger_state.nudges += 1;
                        output_channel.close(.commentary, assistant_text.items);
                        requirement_ledger_state.coverage_nudge_used = true;
                        log.infoId("agent", rid, "requirement ledger coverage nudge {d}/{d}", .{ requirement_ledger_state.nudges, requirement_ledger_mod.MAX_LEDGER_NUDGES });
                        backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
                        try conversation.appendText(.user, requirement_ledger_mod.COVERAGE_NUDGE_TEXT);
                        continue;
                    },
                    .shallow => {
                        _ = host_injection_meter.tryConsume();
                        requirement_ledger_state.nudges += 1;
                        output_channel.close(.commentary, assistant_text.items);
                        requirement_ledger_state.shallow_nudge_used = true;
                        log.infoId("agent", rid, "requirement ledger shallow nudge {d}/{d} total={d}", .{ requirement_ledger_state.nudges, requirement_ledger_mod.MAX_LEDGER_NUDGES, counts.total });
                        backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
                        try conversation.appendText(.user, requirement_ledger_mod.SHALLOW_NUDGE_TEXT);
                        continue;
                    },
                }
            }
            // 任务义务门:author 上一轮为本任务学得的收尾义务未满足 →
            // 有界 nudge(每义务一次,全局 ≤2,纯注入绝不硬拒)。
            if (opts.obligations) |obligation_runtime| {
                const obligation_decision: ?usize = if (host_injection_meter.remaining() > 0)
                    obligation_runtime.decide().index
                else
                    null;
                if (obligation_decision) |obligation_index| {
                    const envelope = obligation_runtime.envelopes[obligation_index];
                    _ = host_injection_meter.tryConsume();
                    obligation_runtime.noteNudged(obligation_index);
                    output_channel.close(.commentary, assistant_text.items);
                    log.warnId("agent", rid, "task obligation nudge {d}/{d} needle={s}", .{ obligation_runtime.nudges_used, @import("obligation_gate.zig").MAX_OBLIGATION_NUDGES, envelope.command_needle });
                    backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
                    const nudge = try std.fmt.allocPrint(
                        allocator,
                        @import("obligation_gate.zig").NUDGE_FMT,
                        .{ envelope.reason, envelope.command_needle },
                    );
                    defer allocator.free(nudge);
                    try conversation.appendText(.user, nudge);
                    continue;
                }
            }
            // L4 诊断:本轮无 tool_use → turn 结束(span 平衡:每个 turn_begin 都配一个
            // turn_end,无论有无工具)。紧接 run_end(end_turn)收口。
            backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
            // 自然 end_turn 且无任何主机异议 → 这一段(连同同 group 的续写段)就是最终结果。
            output_channel.close(.final, assistant_text.items);
            // Stop hook:顶层 agent 自然结束 → 触发(记忆提取挂载点)。
            fireStopHook(permission_ctx.hooks, allocator, conversation, "end_turn", depth);
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .end_turn, .turns = turns + 1, .tool_calls = total_tool_calls });
        }

        // 6. 执行所有 tool_use，把结果作为 user-role 的 tool_result block 追加。
        //    批1:权限检查主线程串行,执行按 isConcurrencySafe 分批并发(tool_exec.zig)。
        const tool_stage_started_ns = util_time.nowNs();
        var result_blocks = std.ArrayList(msg.Block).empty;
        errdefer {
            for (result_blocks.items) |b| b.deinit(allocator);
            result_blocks.deinit(allocator);
        }

        // 6a. 收集 tool_use + 主线程串行做权限检查 → slots。
        const tool_exec = @import("tool_exec.zig");
        var slots = std.ArrayList(tool_exec.Slot).empty;
        // 单个 defer 覆盖所有退出路径(正常/挂起/fatal/错误):slot-owned payload 全部回收。
        // 已转移 ownership 的字段(takeContent 置 null)天然跳过——转移必须走 takeContent。
        defer {
            for (slots.items) |*s| s.deinit(allocator);
            slots.deinit(allocator);
        }
        // P0.2 PreToolUse ModifyInput/Block:hook 在此**统一跑一次**(拿 block + updatedInput 改写);
        // 为避免 checkPermission 内 decision.check 再跑一次 hook(重复副作用),给它一份 hooks=null 的
        // 上下文副本。改写后的输入(owned)挂 mod_inputs,turn 作用域统一释放;slot.input 指向它。
        const hookset: ?*const hooks_mod.HookSet = permission_ctx.hooks;
        var pc_nohooks = permission_ctx.scopedDerive(null); // U4:单 seam 值拷贝+null sink
        pc_nohooks.hooks = null;
        var mod_inputs: std.ArrayList([]u8) = .empty;
        defer {
            for (mod_inputs.items) |mi| allocator.free(mi);
            mod_inputs.deinit(allocator);
        }
        var required_first_accepted = false;
        for (last_msg.blocks) |b| {
            const tu = switch (b) {
                .tool_use => |t| t,
                else => continue,
            };
            total_tool_calls += 1;
            if (required_first_pending) {
                const route = required_first_route.?;
                const exact_required_call = dialect_mod.matchesRequiredFirst(
                    route,
                    tu.name,
                    tu.input,
                );
                if (!exact_required_call or required_first_accepted) {
                    log.warnId(
                        "permission",
                        rid,
                        "required-first DENY tool={s}; pending={s}",
                        .{ tu.name, route.tool_name },
                    );
                    backend.emitEvent(sess, .{ .policy_decision = .{
                        .trace_id = trace_id,
                        .depth = depth,
                        .id = tu.id,
                        .tool = tu.name,
                        .decision = "deny",
                        .source = "model_activation_required_first",
                        .allowed = false,
                    } });
                    var denied = tool_exec.Slot{
                        .decision = .denied,
                        .name = tu.name,
                        .id = tu.id,
                        .input = tu.input,
                    };
                    denied.content = try tool_error.errorToJson(
                        "RequiredFirstPending",
                        "tool '{s}' cannot run before the exact required-first '{s}' activation succeeds",
                        .{ tu.name, route.tool_name },
                        allocator,
                    );
                    denied.is_error = true;
                    try slots.append(allocator, denied);
                    continue;
                }
                // Calls in one assistant message are parallel, not ordered.
                // Admit exactly one activation and deny every sibling above;
                // ordinary tools become eligible only on the next model turn
                // after the paired successful result is in Conversation.
                required_first_accepted = true;
            }
            // 权限侧真名(review round 2 / R2-3):hook 匹配、分类、规则与 ask 记忆都必须
            // 看**将被执行的名字**。dispatcher 宇宙 exact-name 不修;遗留分支用与 executeOne
            // 同一把 P0.6 归一化("bash"→"Bash")——否则 "Bash" 匹配的 block-hook / session
            // "always deny" 对 case-variant 名一律失配,而 dispatch 仍会修名真执行。
            // 真未知名保持原名(read 兜底 + UnknownTool 引导)。Slot 仍带 raw 名
            // (证据契约:requested vs dispatched 归属不糊);PostToolUse 观测 hook 仍按
            // raw 名匹配(存量,不在本修范围——Pre 侧是安全向,先闭合)。
            var name_probe_ctx = tools_mod.ToolContext{ .allocator = allocator, .dyn_registry = opts.dyn_registry };
            const canonical_name = if (opts.tool_dispatcher != null)
                tu.name // dispatcher universe: exact-name policy, no repair
            else
                tools_mod.resolveToolNameExact(&name_probe_ctx, tu.name) orelse tu.name;
            // PreToolUse hook(有配置才跑):可 block(拒)或 updatedInput(改写工具输入)。
            var eff_input = tu.input;
            if (hookset) |hs| if (hs.hasPre()) {
                const pre = hooks_mod.runPreToolUseFull(hs, allocator, canonical_name, tu.input, opts.abort);
                if (pre.modified_input) |mi| {
                    mod_inputs.append(allocator, mi) catch allocator.free(mi);
                    // append 成功才用改写值;失败(OOM)已 free,退回原 input。
                    if (mod_inputs.items.len > 0 and mod_inputs.items[mod_inputs.items.len - 1].ptr == mi.ptr) eff_input = mi;
                }
                if (pre.decision == .block) {
                    log.warnId("permission", rid, "PreToolUse hook blocked tool={s}", .{tu.name});
                    backend.emitEvent(sess, .{ .policy_decision = .{
                        .trace_id = trace_id,
                        .depth = depth,
                        .id = tu.id,
                        .tool = tu.name,
                        .decision = "deny",
                        .source = "pre_tool_use_hook",
                        .allowed = false,
                    } });
                    var dslot = tool_exec.Slot{ .decision = .denied, .name = tu.name, .id = tu.id, .input = eff_input };
                    dslot.content = try tool_error.errorToJson("PreToolUseBlocked", "tool '{s}' blocked by PreToolUse hook", .{tu.name}, allocator);
                    dslot.is_error = true;
                    try slots.append(allocator, dslot);
                    continue;
                }
            };
            // With a Session dispatcher present, the directory is the only
            // classification authority. A name it cannot resolve is not a
            // known-read tool — default it to `.execute` (deny in plan, ask
            // in default) instead of the legacy name-based read fallback.
            // Dispatch of such a name still fails as UnknownTool; note the
            // deny happens before dispatch, so the UnknownTool "did you
            // mean X" guidance does not fire on the denied path. The legacy
            // branch classifies canonical_name (resolved above, same
            // normalizer as executeOne) so classification can never look at
            // a different name than what dispatch will actually run.
            const classified = if (opts.tool_dispatcher) |dispatcher|
                dispatcher.category(tu.name) orelse .execute
            else if (opts.dyn_registry) |registry|
                registry.category(canonical_name)
            else
                null;
            const perm_result = permission_mod.checkPermissionClassified(&pc_nohooks, canonical_name, eff_input, classified);
            log.infoId("permission", rid, "tool={s} decision={s}", .{ tu.name, @tagName(perm_result) });
            var slot = tool_exec.Slot{ .decision = .run, .name = tu.name, .id = tu.id, .input = eff_input };
            var policy_allowed = perm_result == .allow;
            switch (perm_result) {
                .deny => {
                    log.warnId("permission", rid, "DENY tool={s} input={s}", .{ tu.name, tu.input });
                    slot.decision = .denied;
                    slot.content = try tool_error.errorToJson("PermissionDenied", "tool '{s}' denied by permission rule or plan mode", .{tu.name}, allocator);
                    slot.is_error = true;
                },
                .ask => {
                    // ctx constCast:promptUser 写 session 记忆(有副作用)。同 plan_mode 分支
                    // 的 @constCast 先例——agent_loop 持 *const 但权限交互本就改 per-session 状态。
                    // R2-3:传 canonical_name——ask 记忆(rememberAllow/Deny)与决策链读取
                    // (decisionFor)必须同键,否则 "always deny" 存 "bash" 键、后续按 "Bash"
                    // 查不到,session deny 被 settings allow 越过。
                    const allowed = permission_mod.promptUser(@constCast(permission_ctx), canonical_name, eff_input) catch false;
                    policy_allowed = allowed;
                    log.infoId("permission", rid, "prompt tool={s} user_allowed={}", .{ tu.name, allowed });
                    if (!allowed) {
                        slot.decision = .denied;
                        slot.content = try tool_error.errorToJson("PermissionDenied", "user declined '{s}' via prompt", .{tu.name}, allocator);
                        slot.is_error = true;
                    }
                },
                .allow => {},
            }
            backend.emitEvent(sess, .{ .policy_decision = .{
                .trace_id = trace_id,
                .depth = depth,
                .id = tu.id,
                .tool = tu.name,
                .decision = @tagName(perm_result),
                .source = if (perm_result == .ask) "user_prompt" else "permission_chain",
                .allowed = policy_allowed,
            } });
            try slots.append(allocator, slot);
            // 任务义务观察:获准执行的 Bash 命令喂给义务运行时(needle 子串
            // 命中即 met)。denied 的调用不算——义务要的是"真的跑过"。
            // R3-4:按 canonical 名判——"bash" 会被 P0.6 修名真执行,raw 名判失配
            // 会让真跑过的义务停在 unmet(有界误提醒,同 R2-3 键分裂族)。
            if (opts.obligations) |obligation_runtime| {
                if (slot.decision == .run and std.mem.eql(u8, canonical_name, "Bash")) {
                    if (@import("../util/json.zig").extractStringField(slot.input, "command")) |command|
                        obligation_runtime.observeDispatch(slot.id, command);
                }
            }
        }

        // AgentDef/skill execution ceilings are a distinct, final policy
        // layer.  executeOne remains the enforcing seam (and returns a paired
        // tool_result), while this event makes a denial visible to native eval
        // telemetry instead of looking like an unexplained tool failure.
        if (opts.execution_policy) |execution_policy| {
            for (slots.items) |*slot| {
                if (slot.decision != .run or
                    execution_policy.allowsInvocation(slot.name, slot.input)) continue;
                log.warnId("permission", rid, "execution policy DENY tool={s}", .{slot.name});
                backend.emitEvent(sess, .{ .policy_decision = .{
                    .trace_id = trace_id,
                    .depth = depth,
                    .id = slot.id,
                    .tool = slot.name,
                    .decision = "deny",
                    .source = "execution_policy",
                    .allowed = false,
                } });
            }
        }

        // 6b. 构造一次 ToolContext(所有 tool 共用;并发 job 各自换独立 arena allocator)。
        // plan 模式:从刚提交的助手文本提取 <proposed_plan>,存进 ctx 供 ExitPlanMode 读
        //（XML 协议主路径,对齐 mecode:计划走文本流而非工具参数)。turn 作用域,用后 free。
        var proposed_plan_buf: ?[]u8 = null;
        defer if (proposed_plan_buf) |p| allocator.free(p);
        if (permission_ctx.modeValue() == .plan and assistant_text.items.len > 0) {
            const pp = @import("proposed_plan.zig");
            proposed_plan_buf = pp.extractProposedPlan(allocator, assistant_text.items) catch null;
        }
        // 工具进度 trampoline 的 per-run 存储(backend + session),供 progress_state 指向。
        // 声明在 base_ctx 同作用域,生命周期覆盖整个工具执行。
        var progress_tramp: ProgressTramp = undefined;
        var event_tramp: EventTramp = undefined; // U6 A2:agent_lifecycle/tasks_changed 通知
        var base_ctx = tools_mod.ToolContext{
            .allocator = allocator,
            .abort = opts.abort,
            .read_state = opts.read_state,
            .edit_hl_cache = opts.edit_hl_cache,
            .lsp = opts.lsp,
            .jobs = opts.jobs,
            .agent_jobs = opts.agent_jobs,
            .swarm = opts.swarm,
            .permission_ctx = @constCast(permission_ctx),
            .plan_prev_mode = opts.plan_prev_mode,
            .tasks = opts.tasks,
            .kg = opts.kg,
            .kg_lexical_ledger = &kg_lexical_ledger,
            .kg_projects_dir = opts.kg_projects_dir,
            .memdir_abs = opts.memdir_abs,
            .api_client = opts.api_client,
            // Root App runs may reuse agent_jobs' owned provider config. Nested
            // agents can carry a model override while agent_jobs still stores
            // the parent model, so deriving there would silently search with
            // the wrong model; they stay on their private serial client unless
            // their caller supplies an explicit matching factory.
            .provider_factory = opts.provider_factory orelse if (opts.agent_depth == 0)
                if (opts.agent_jobs) |registry| registry.providerFactory() else null
            else
                null,
            .provider = provider, // P0.5:子 spawn 继承父 provider(跨 provider 正确)
            .tool_defs = opts.tool_defs,
            .agent_depth = opts.agent_depth,
            .dyn_registry = opts.dyn_registry,
            .tool_dispatcher = opts.tool_dispatcher,
            .execution_policy = opts.execution_policy,
            .tool_observer = opts.tool_observer,
            .execution_boundary = opts.execution_boundary,
            .project_rule_gate = opts.project_rule_gate,
            .tool_observation_origin = .authoritative,
            .host_services = opts.host_services,
            .host_run = opts.host_run,
            .explicit_invocation = opts.explicit_invocation,
            .session_id = opts.session_id,
            .project_dir = opts.project_dir,
            .disable_shell_execution = opts.disable_shell_execution,
            .sandbox = opts.sandbox,
            .cwd_abs = opts.cwd_abs,
            .resolve_relative_paths = opts.resolve_relative_paths,
            .home_dir = opts.home_dir,
            .artifact_root = opts.artifact_root,
            // The same value the projection pass below uses. Deriving it here
            // is what lets a tool bound its own output against the real window
            // instead of against the floor the budget can never go under.
            .result_budget = result_budget_mod.Budget.fromModel(provider.maxInputTokens()),
            .tool_result_metrics = opts.tool_result_metrics,
            .file_change_journal = opts.file_change_journal,
            .additional_dirs = opts.additional_dirs,
            .plan_file_path = opts.plan_file_path,
            .last_proposed_plan = if (proposed_plan_buf) |p| p else "",
            .agents = opts.agents,
            .parent_model = opts.parent_model,
            .model_tiers = opts.model_tiers,
            .skills = opts.skills_set,
            .mcp_sessions = opts.mcp_sessions,
            .cron_registry = opts.cron_registry,
        };

        // 工具执行期 progress 通路(对齐 cc onProgress):把 WebSearch 子请求的
        // query_update/results_received 格式化成第二行文本,经 backend.emit(.tool_progress) 喂 UI。
        // Legacy UI only wires depth zero. AgentCore captures progress from
        // real children too; its private projector suppresses model-tool
        // internals before they reach the Host.
        if (opts.event_projection.emitToolProgress(opts.agent_depth)) {
            progress_tramp = .{ .be = backend, .session = sess };
            base_ctx.progress_reporter = .{ .ctx = @ptrCast(&progress_tramp), .reportFn = &ProgressTramp.cb };
        }
        if (opts.agent_depth == 0) {
            // U6 A2:only the real root injects agent_lifecycle/tasks_changed.
            event_tramp = .{ .be = backend, .session = sess };
            base_ctx.event_reporter = .{
                .ctx = @ptrCast(&event_tramp),
                .agentFn = &EventTramp.agentCb,
                .tasksFn = &EventTramp.tasksCb,
            };
        }

        // Legacy subagents have no terminal UI. AgentCore explicit projections
        // reuse the outer Run's UI bridge and identity without faking depth.
        if (opts.ui_requester != null and
            opts.event_projection.allowUiRequests(opts.agent_depth))
        {
            base_ctx.ui_requester = opts.ui_requester;
        }
        // 子进程心跳(Bash 长命令"仍在运行")per-session 通路:从 opts 透传到 ctx → spawn 层。
        base_ctx.spawn_tick_fn = opts.spawn_tick_fn;
        base_ctx.session = sess; // UiRequest 路由到本 session 视图(M5)
        base_ctx.agent_ident = opts.agent_ident orelse sess; // 对外身份(claim);主 loop=session,subagent=spawn 时 gen
        base_ctx.kg_agent_ident = opts.kg_agent_ident;

        // 6c. 分批并发执行。过程态(TTY 顶层):无条件 emit tool_start(每个 run slot);
        // **渲染决策(showStartCard/hasProgressCard/喂 spinner)全在 backend**——agent_loop
        // 不再 import tool_card UI widget(层泄漏修复)。headless/subagent(depth>0)/无 theme
        // 时 tool_render_theme=null → 不 emit(那些场景 WriterBackend 也 no-op)。
        if (opts.event_projection.emitToolStart(opts.emit_tool_cards, opts.agent_depth)) {
            for (slots.items) |*s| {
                // Lifecycle represents the model's tool attempt, not proof of
                // dispatch. Denied attempts still receive a paired result and
                // must therefore receive a start event as well.
                backend.emitEvent(sess, .{ .tool_start = .{ .id = s.id, .name = s.name, .input = s.input } });
            }
        }
        // 进度事件:本轮第一个 run slot 的工具名 + 原始 input(subagent agent 树显示当前动作)。
        // 无条件 emit——backend 自决消费(顶层 TuiBackend 忽略 .progress;JobEntry 后端更新树)。
        for (slots.items) |*s| {
            if (s.decision == .run) {
                emitProgress(backend, sess, turns + 1, s.name, s.input, total_tool_calls);
                break;
            }
        }
        // P0.4:流式预取命中的 slot 直接填结果(executeSlots 会跳过 prefetched 的,不重复执行)。
        for (slots.items) |*s| {
            if (s.decision != .run) continue;
            if (prefetch.take(s.id)) |pf| {
                s.content = pf.content;
                s.file_refs = pf.file_refs;
                s.file_changes = pf.file_changes;
                s.file_changes_overflow = pf.file_changes_overflow;
                s.file_changes_lost = pf.file_changes_lost;
                s.is_error = pf.is_error;
                s.elapsed_ms = pf.elapsed_ms;
                s.effect = pf.effect;
                s.effect_valid = pf.effect_valid;
                s.prefetched = true;
            }
        }
        // Host 工具 fatal → 直接上抛:不组装 tool_result(errdefer 释放 result_blocks,
        // slot payload 由上方 defer 回收),AgentSession.runLoop 捕获后 poisonRun。
        const exec_outcome = tool_exec.executeSlots(slots.items, &base_ctx, allocator, rid);
        // 文件修改证据先于一切分支落地:fatal 同样可能发生在盘已改之后,先投再上抛。
        drainFileChanges(slots.items, &base_ctx, backend, sess, opts.file_change_journal, allocator);
        try exec_outcome;
        // 成功条件义务 2.0:结果侧回填 met——只有执行成功(!is_error 且
        // exit_code=0,bash.zig 序列化以 `"exit_code":N}` 收尾)才算履约。
        if (opts.obligations) |obligation_runtime| {
            for (slots.items) |*result_slot| {
                if (result_slot.decision != .run) continue;
                // R4-1:结果侧**不按名过滤**——slot 带 raw 名("bash" 经 P0.6 修名后真
                // 执行),按名筛会漏掉 case-variant 的成功回填(dispatch 侧已按 canonical
                // 记账,两侧键分裂 → 义务永不 met)。observeResult 本就按 pending id 精确
                // 匹配:非 Bash slot 的 id 永不命中已记账槽,无误报,无需名闸。
                const body = result_slot.content orelse continue;
                const ok = !result_slot.is_error and
                    std.mem.indexOf(u8, body, "\"exit_code\":0}") != null;
                obligation_runtime.observeResult(result_slot.id, ok);
            }
        }
        backend.emitEvent(sess, .{ .diag_tool_stage = .{
            .trace_id = trace_id,
            .depth = depth,
            .turn = turns + 1,
            .tool_calls = @intCast(slots.items.len),
            .elapsed_ms = elapsedSinceNs(tool_stage_started_ns),
        } });
        if (opts.event_projection.emitToolStart(opts.emit_tool_cards, opts.agent_depth)) {
            // P2.1:只发 clear_current_tool 清运行态动态卡。真结果由下方每 slot 的单条
            // tool_result(真 content)承载,不再双发空+实。
            backend.emitEvent(sess, .clear_current_tool);
        }

        // 6c.5 L3 挂起:本轮有工具返 error.UiPending(异步 custom UI 未完成)→ 整轮挂起。
        // **API 配对约束**:assistant 的每个 tool_use 须在紧接 user 消息里有 tool_result,不能拆
        // 两次。故挂起时**不**提交任何 partial user 消息;已完成工具的结果 stash 进 SuspendInfo,
        // resume 时与 pending 的迟来结果一起补成单条 user 消息(A+B 同 turn)。
        // 找首个 pending 作挂起点;其余 pending(MVP 不支持多挂起点)→ 当错误,resume 时也配对补。
        var first_pending: ?*tool_exec.Slot = null;
        for (slots.items) |*s| {
            if (s.pending) {
                first_pending = s;
                break;
            }
        }
        if (first_pending) |s| {
            // 收集**所有非挂起点**工具的结果(已完成的用真实结果;其余 pending 用错误占位)——
            // 它们都要在 resume 时与挂起点的迟来结果同 turn 补齐,满足 API 配对。
            var completed: std.ArrayList(SuspendInfo.CompletedResult) = .empty;
            errdefer {
                for (completed.items) |entry| {
                    allocator.free(entry.tool_use_id);
                    allocator.free(entry.content);
                }
                completed.deinit(allocator);
            }
            var completed_names: std.ArrayList([]const u8) = .empty;
            defer completed_names.deinit(allocator);
            for (slots.items) |*o| {
                if (o == s or o.decision != .run) continue;
                const content: []const u8 = if (o.pending)
                    // 非首个 pending:MVP 不支持并发挂起 → 错误占位(模型 resume 后可重试)。
                    try tool_error.errorToJson("ConcurrentSuspendUnsupported", "tool {s} requested UI while another suspended; not supported in MVP", .{o.name}, allocator)
                else
                    try allocator.dupe(u8, o.content orelse "{}");
                try completed.append(allocator, .{
                    .tool_use_id = try allocator.dupe(u8, o.id),
                    .content = content,
                    .is_error = if (o.pending) true else o.is_error,
                });
                try completed_names.append(allocator, o.name);
                // 释放 slot 原 owned 内存(content 已 dupe 进 completed;pending 的 kind/payload
                // 不进 SuspendInfo)——否则泄漏(正常路径 content 移交 result_blocks,此处改 dupe)。
                if (o.content) |c| {
                    allocator.free(c);
                    o.content = null;
                }
                if (o.pending) {
                    if (o.pending_kind) |k| allocator.free(k);
                    if (o.pending_payload) |p| allocator.free(p);
                    o.pending_kind = null;
                    o.pending_payload = null;
                }
            }
            // Suspended sibling results are persisted before suspend.json is
            // written. They cannot bypass the same one-shot projection simply
            // because another tool requested asynchronous UI.
            const suspended_items = try allocator.alloc(result_projection.Item, completed.items.len);
            defer allocator.free(suspended_items);
            for (completed.items, 0..) |*entry, index| {
                suspended_items[index] = .{
                    .tool_name = completed_names.items[index],
                    .content = &entry.content,
                    .is_error = entry.is_error,
                };
            }
            const suspended_projection_stats = try result_projection.project(allocator, suspended_items, .{
                .session_root = opts.artifact_root,
                .budget = result_budget_mod.Budget.fromModel(provider.maxInputTokens()),
            });
            if (opts.tool_result_metrics) |metrics| metrics.recordProjection(suspended_projection_stats);
            // result_blocks 这轮不提交(挂起不落 partial user 消息);释放已 append 的(本应为空)。
            result_blocks.clearAndFree(allocator);
            const kind = s.pending_kind orelse "";
            const payload = s.pending_payload orelse "{}";
            // 异步前端据此投递 UI 请求(tool_use_id + 渲染规格)。
            backend.emitEvent(sess, .{ .ui_request_pending = .{ .tool_use_id = s.id, .request_json = payload } });
            // SuspendInfo 接管挂起点 slot 的 pending 字符串所有权(移动,不重复 dupe);置 null 防 double-free。
            const si = SuspendInfo{
                .tool_use_id = try allocator.dupe(u8, s.id),
                .kind = if (s.pending_kind) |k| k else try allocator.dupe(u8, ""),
                .payload_json = if (s.pending_payload) |p| p else try allocator.dupe(u8, "{}"),
                .completed_results = try completed.toOwnedSlice(allocator),
                .allocator = allocator,
            };
            s.pending_kind = null;
            s.pending_payload = null;
            log.infoId("agent", rid, "run SUSPENDED tool_use_id={s} kind={s} completed_siblings={d}", .{ s.id, kind, si.completed_results.len });
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .suspended, .turns = turns + 1, .tool_calls = total_tool_calls, .suspend_info = si });
        }

        const observe_verification = opts.verification_checkpoint or
            opts.verification_final_gate or opts.verification_final_observe or
            opts.requirement_ledger or opts.requirement_ledger_observe;
        // PO-V2 M2(observe-only):候选信号要的是"编辑发生时,最近验证是否
        // 失败"——必须取 observeTurn 之前的位;本轮自己的验证结果属于下一轮。
        const pre_turn_verification_failed = verification_progress.last_verification_failed;
        const inject_verification_checkpoint = observe_verification and
            verification_progress.observeTurn(allocator, slots.items) and
            opts.verification_checkpoint;
        if (observe_verification) {
            if (opts.tool_observer) |observer| {
                for (slots.items) |slot| {
                    if (slot.decision != .run or slot.is_error) continue;
                    const is_file_edit = std.mem.eql(u8, slot.name, "Edit") or
                        std.mem.eql(u8, slot.name, "Write") or
                        std.mem.eql(u8, slot.name, "NotebookEdit");
                    if (!is_file_edit) continue;
                    if (!verification_progress_mod.isRealizedMutation(slot.effect, slot.effect_valid)) continue;
                    const edit_path = verification_progress_mod.slotFilePath(allocator, slot.input) orelse continue;
                    defer allocator.free(edit_path);
                    if (!verification_progress_mod.isTestFilePath(edit_path)) continue;
                    _ = observer.emit(.{ .test_weakening_candidate = .{
                        .dispatch_id = slot.id,
                        .path_sha256 = tools_mod.tool_observation.sha256Hex(edit_path),
                        .tool = slot.name,
                        .assert_tokens_touched = verification_progress_mod.editTouchesAssertTokens(slot.input),
                        .last_verification_failed = pre_turn_verification_failed,
                    } });
                }
            }
        }

        // 6d. 按原顺序回填 result_blocks。
        // P0.2 PostToolUse:执行后 hook 产出的 additionalContext,拼成一段注入本轮 user 消息(下轮模型可见)。
        var post_ctx: std.ArrayList(u8) = .empty;
        defer post_ctx.deinit(allocator);
        for (slots.items) |*s| {
            // takeContent:ownership 转移给 result_blocks 并置空 slot 字段——
            // 顶部 defer 的 Slot.deinit 不会再碰它(双释放防线)。
            const content = s.takeContent() orelse try tool_error.errorToJson("InternalError", "tool {s} produced no result", .{s.name}, allocator);
            // 已离开 slot、尚未进 result_blocks 的真空期:本迭代内 try 失败由此兜底。
            // 旗标而非裸 errdefer:append 后 ownership 归 result_blocks(其 errdefer 接管),
            // 本迭代若再加 try 也不会双释放。
            var content_transferred = false;
            errdefer if (!content_transferred) allocator.free(content);
            const tool_use_id = try allocator.dupe(u8, s.id);
            errdefer if (!content_transferred) allocator.free(tool_use_id);
            try result_blocks.append(allocator, .{ .tool_result = .{
                .tool_use_id = tool_use_id,
                .content = content,
                .is_error = s.is_error,
            } });
            content_transferred = true;

            // PostToolUse hook(执行后,仅真跑过的 slot):收集 additionalContext 注入下轮上下文。
            if (s.decision == .run) {
                if (hookset) |hs| if (hs.hasPost()) {
                    if (hooks_mod.runPostToolUse(hs, allocator, s.name, s.input, content, opts.abort)) |ac| {
                        defer allocator.free(ac);
                        if (post_ctx.items.len > 0) post_ctx.append(allocator, '\n') catch {};
                        post_ctx.appendSlice(allocator, ac) catch {};
                    }
                };
            }

            // 实时工具卡渲染(REPL):把结果经 backend 渲染到屏幕——Edit/Write diff 着色、
            // Grep/Glob 摘要、Read 摘要。headless/单测 tool_render_theme=null → 跳过(emit 仍发,
            // 但那些场景用 WriterBackend,tool_result no-op)。渲染移入 backend(renderResult)。
            if (opts.event_projection.emitToolResult(opts.emit_tool_cards)) {
                backend.emitEvent(sess, .{ .tool_result = .{
                    .id = s.id,
                    .name = s.name,
                    .input = s.input,
                    .content = content,
                    .is_error = s.is_error,
                    .elapsed_ms = s.elapsed_ms,
                    .file_refs = s.file_refs,
                } });
            }
        }

        if (result_blocks.items.len == 0) {
            result_blocks.deinit(allocator);
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .tool_error, .turns = turns + 1, .tool_calls = total_tool_calls });
        }

        // Hooks and UI above observe the exact execution result. Only now do
        // we commit the deterministic model-visible representation. This runs
        // once per result; later requests reuse the same Conversation bytes,
        // preserving provider prompt-cache prefixes.
        const projection_items = try allocator.alloc(result_projection.Item, result_blocks.items.len);
        defer allocator.free(projection_items);
        for (result_blocks.items, 0..) |*block, index| {
            if (block.* != .tool_result) unreachable;
            projection_items[index] = .{
                .tool_name = slots.items[index].name,
                .content = &block.tool_result.content,
                .is_error = block.tool_result.is_error,
            };
        }
        const projection_stats = try result_projection.project(allocator, projection_items, .{
            .session_root = opts.artifact_root,
            .budget = result_budget_mod.Budget.fromModel(provider.maxInputTokens()),
        });
        if (opts.tool_result_metrics) |metrics| metrics.recordProjection(projection_stats);
        if (projection_stats.changed() or projection_stats.budget_exhausted) {
            log.info("agent", "tool-result projection: raw={d} projected={d} artifact_bytes={d} spills={d} fallback={d} turn_spills={d} image_exempt={d} regrown={d} reinlined={d} budget_exhausted={}", .{
                projection_stats.raw_bytes,
                projection_stats.projected_bytes,
                projection_stats.artifact_bytes,
                projection_stats.artifact_spill_count,
                projection_stats.unrecoverable_fallback_count,
                projection_stats.turn_budget_spills,
                projection_stats.image_exempt_count,
                projection_stats.envelope_regrown_count,
                projection_stats.envelope_reinlined_count,
                projection_stats.budget_exhausted,
            });
        }

        // PostToolUse additionalContext → 同一 user 消息追加一个 text block(下轮模型可见)。
        if (post_ctx.items.len > 0) {
            const ctx_text = try std.fmt.allocPrint(allocator, "[PostToolUse hook]\n{s}", .{post_ctx.items});
            try result_blocks.append(allocator, .{ .text = ctx_text });
        }
        if (inject_verification_checkpoint) {
            const checkpoint = try allocator.dupe(
                u8,
                verification_progress_mod.CHECKPOINT_TEXT,
            );
            try result_blocks.append(allocator, .{ .text = checkpoint });
        }
        // Requirement-ledger prompt: once, at the first tool-result boundary
        // (the cacheable first request stays byte-identical across arms).
        if (opts.requirement_ledger and !requirement_ledger_state.prompt_emitted) {
            requirement_ledger_state.prompt_emitted = true;
            const prompt = try allocator.dupe(
                u8,
                requirement_ledger_mod.LEDGER_PROMPT_TEXT,
            );
            try result_blocks.append(allocator, .{ .text = prompt });
        }
        // Churn caution: enforced-gate arms only (observe mode must stay
        // behavior-neutral), at most once per session, fired the turn a
        // mutation lands on previously-verified state.
        if (opts.verification_final_gate and verification_progress.takeChurnCaution()) {
            const caution = try allocator.dupe(
                u8,
                verification_progress_mod.FRESHNESS_TEXT,
            );
            try result_blocks.append(allocator, .{ .text = caution });
        }
        const kg_pending = kgEnumerationPending(
            &kg_lexical_ledger,
            gated_tool_defs,
            kg_enumeration_query_hint,
        );
        if (kg_pending == .batch and !kg_coverage_reminder_emitted) {
            const reminder = try allocator.dupe(u8, kg_retrieval_protocol.ENUMERATION_COVERAGE_REMINDER);
            try result_blocks.append(allocator, .{ .text = reminder });
            kg_coverage_reminder_emitted = true;
        } else if (kg_pending == .context and !kg_context_reminder_emitted) {
            const reminder = try allocator.dupe(u8, kg_retrieval_protocol.ENUMERATION_CONTEXT_REMINDER);
            try result_blocks.append(allocator, .{ .text = reminder });
            kg_context_reminder_emitted = true;
        }

        const blocks_owned = try result_blocks.toOwnedSlice(allocator);
        try conversation.append(.{ .role = .user, .blocks = blocks_owned });

        // Mid-turn follow-up compact: after tool_result blocks are appended and
        // before the next sampling request, re-check the actual pending request.
        // This is the explicit Rust/metacode "post_sampling_follow_up_threshold"
        // equivalent; the next loop's pre-sampling check would be close, but this
        // makes the follow-up boundary a real trigger point with its own cause.
        const post_tool_compact = try runAutoCompactIfNeeded(
            conversation,
            provider,
            effective_system_prompt,
            opts.inject_user_context,
            null,
            gated_tool_defs,
            opts.model_override,
            null,
            opts.auto_compact_threshold,
            opts.auto_compact_keep_recent,
            "post_tool_follow_up_threshold",
            backend,
            sess,
            trace_id,
            depth,
            turns + 1,
            &context_warning_emitted,
            allocator,
            opts.tasks,
            permission_ctx.hooks,
            &compact_summary_reserve_tokens,
            opts.request_gate,
            opts.abort,
        );
        if (post_tool_compact == .api_error) {
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .api_error, .turns = turns + 1, .tool_calls = total_tool_calls });
        }
        if (post_tool_compact == .aborted) {
            return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = stopReasonForAbort(opts.abort), .turns = turns + 1, .tool_calls = total_tool_calls });
        }

        // L4 诊断:turn span 终点(本轮有 tool_use、将进入下一轮的正常路径;无工具的
        // end_turn 路径在上方提前 return + diag_run_end 收口,故不重复发)。
        backend.emitEvent(sess, .{ .diag_turn_end = .{ .trace_id = trace_id, .depth = depth, .turn = turns + 1, .tool_calls = total_tool_calls } });
    }

    // 循环正常退出 = turns >= max_turns
    return finishRun(backend, sess, trace_id, depth, .{ .stop_reason = .max_turns, .turns = turns, .tool_calls = total_tool_calls });
}

const KgEnumerationPending = enum { none, batch, context };

fn kgEnumerationPending(
    ledger: *@import("../kg/lexical_query_plan.zig").Ledger,
    tool_defs: []const json_mod.ToolDefinition,
    query_hint: bool,
) KgEnumerationPending {
    var kg_recall_visible = false;
    var kg_context_visible = false;
    for (tool_defs) |definition| {
        if (std.mem.eql(u8, definition.name, "KgRecall")) {
            kg_recall_visible = true;
        } else if (std.mem.eql(u8, definition.name, "KgContext")) {
            kg_context_visible = true;
        }
    }
    if (!kg_recall_visible) return .none;
    const coverage = ledger.coverageState();
    const enumeration_active = coverage.successful_plan_calls > 0 and
        (query_hint or coverage.enumeration_plan_calls > 0);
    if (!enumeration_active) return .none;
    if (!coverage.enumeration_batch_committed) return .batch;
    if (kg_context_visible and
        coverage.enumeration_context_required and
        !coverage.enumeration_context_committed) return .context;
    return .none;
}

test "enumeration coverage gate ignores query wording before a successful recall" {
    var ledger = @import("../kg/lexical_query_plan.zig").Ledger{};
    const tool_defs = [_]json_mod.ToolDefinition{.{
        .name = "KgRecall",
        .description = "recall",
        .input_schema = .{ .prop_specs = &.{}, .required = &.{} },
    }};

    try std.testing.expectEqual(KgEnumerationPending.none, kgEnumerationPending(&ledger, &tool_defs, true));
    try std.testing.expectEqual(KgEnumerationPending.none, kgEnumerationPending(&ledger, &.{}, true));
}

fn elapsedSinceNs(started_ns: util_time.Nanos) u64 {
    const now = util_time.nowNs();
    if (now <= started_ns) return 0;
    return @intCast(@divTrunc(now - started_ns, std.time.ns_per_ms));
}

/// L3 恢复:把异步 UI 响应 + 同轮已完成工具的结果**一起**注入为单条 user 消息(满足 API 的
/// tool_use/tool_result 同 turn 配对),然后续跑 run()。
///
/// conversation 须已含挂起点的 assistant(带那些 tool_use)——同进程时它还在内存;跨进程/重启
/// 时由调用方先 loadTranscript 从盘重建。resumeRun 不关心来源,只:① 构造一条 user 消息,内含
/// **挂起点 tool_use 的迟来 tool_result(content=response_json)+ completed_results 里每个同轮
/// 已完成工具的 tool_result**;② 调 run() 续跑。response_json / completed 借用,append 时 dupe。
///
/// **为什么要 completed_results**:挂起的那条 assistant 消息可能有多个 tool_use(A=pending,
/// B/C=done)。API 要求 A+B+C 的 tool_result 都在紧接的同一条 user 消息里。挂起时已完成的 B/C
/// 结果没单独提交(那样会拆 turn 违规),而是 stash 在 SuspendInfo.completed_results,此刻一起补。
pub fn resumeRun(
    conversation: *Conversation,
    provider: provider_mod.Provider,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    resumed_tool_use_id: []const u8,
    response_json: []const u8,
    completed_results: []const SuspendInfo.CompletedResult,
    opts: Options,
    backend: *const UiBackend,
    allocator: std.mem.Allocator,
) !RunResult {
    // 一条 user 消息,内含挂起点的迟来结果 + 所有同轮已完成工具的结果(同 turn 配对)。
    var blocks: std.ArrayList(msg.Block) = .empty;
    errdefer blocks.deinit(allocator);
    try blocks.append(allocator, .{ .tool_result = .{
        .tool_use_id = try allocator.dupe(u8, resumed_tool_use_id),
        .content = try allocator.dupe(u8, response_json),
        .is_error = false,
    } });
    for (completed_results) |cr| {
        try blocks.append(allocator, .{ .tool_result = .{
            .tool_use_id = try allocator.dupe(u8, cr.tool_use_id),
            .content = try allocator.dupe(u8, cr.content),
            .is_error = cr.is_error,
        } });
    }
    try conversation.append(.{ .role = .user, .blocks = try blocks.toOwnedSlice(allocator) });
    log.info("agent", "resume: injected {d} tool_result(s) (pending={s} + {d} siblings), continuing run", .{ completed_results.len + 1, resumed_tool_use_id, completed_results.len });
    // 续跑(可能再次挂起——resume 可链式)。
    return run(conversation, provider, tool_defs, permission_ctx, opts, backend, allocator);
}

/// 取对话里最近一条 user 文本 block(borrowed),用于 web_search 显示真实 query。
/// 找不到返回 ""。从后往前找第一条 role==.user 且含 text block 的。
fn latestUserText(conversation: *const @import("conversation.zig").Conversation) []const u8 {
    var i: usize = conversation.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = conversation.messages.items[i];
        if (m.role != .user) continue;
        for (m.blocks) |b| {
            if (b == .text and b.text.len > 0) return b.text;
        }
    }
    return "";
}

/// 把 Conversation 中的所有消息 1:1 映射为 `types.ApiMessage`，
/// 供 `client.sendMessageStream` 使用。调用方必须用 `freeApiMessages` 释放。
fn buildApiMessages(
    conversation: *const Conversation,
    allocator: std.mem.Allocator,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
) !std.ArrayList(types.ApiMessage) {
    var out = std.ArrayList(types.ApiMessage).empty;
    errdefer {
        freeApiMessages(&out, allocator);
    }

    // 首条 user-context message(对齐 cc prependUserContext):合成一条 user message,
    // content 单 text block = `<system-reminder>` 包裹的 CLAUDE.md/AutoMem/currentDate。
    // 借用 inject_user_context 的字节(不 dupe);freeApiMessages 只 free content 数组本身,
    // 不 free block 内字符串——与下方 conversation 借用块同策略。
    if (inject_user_context) |ctx_text| {
        if (ctx_text.len > 0) {
            const contents = try allocator.alloc(types.ApiContent, 1);
            contents[0] = .{ .text = ctx_text };
            try out.append(allocator, .{ .role = .user, .content = contents });
        }
    }

    // P1.5 纯投影:压缩摘要作为边界前一条 assistant 消息注入(原始消息仍全量留在 conversation,
    // 只是不发)。发给模型 = [inject_ctx] + [summary] + activeMessages()。与 totalTokens 投影一致。
    if (conversation.compact_summary) |summ| {
        if (summ.len > 0) {
            const contents = try allocator.alloc(types.ApiContent, 1);
            contents[0] = .{ .text = summ }; // 借用 conversation 拥有的摘要字节
            try out.append(allocator, .{ .role = .assistant, .content = contents });
        }
    }

    for (conversation.activeMessages()) |m| {
        // thinking block 不回 API(模型自己产);先算实际要回的 block 数
        var n_actual: usize = 0;
        // reasoning_item 是 provider 私有的续传状态,不是"内容":只有 OpenAI
        // Responses 序列化器会用它,别的方言整块跳过。它单独存在时**不足以**
        // 撑起一条消息(Anthropic 的 content 数组会空),故不计入实质 block。
        // 本进程写出的会话不会有这种消息(见上方 turn_has_content 不变式);
        // 这里是针对外部/未来版本 transcript 的防线,而不是热路径。
        var n_substantive: usize = 0;
        for (m.blocks) |b| switch (b) {
            .thinking => {},
            .reasoning_item => n_actual += 1,
            else => {
                n_actual += 1;
                n_substantive += 1;
            },
        };
        // max_tokens 可能恰好截断在 thinking 末尾：Conversation 会保留该
        // thinking block 供本地审计，但 provider-visible 投影不能生成
        // `content: []` 的空 assistant 消息。跳过后，紧随的 continuation user
        // 会由 normalizeApiMessages 与前一条 user 合并，维持合法角色/content。
        if (n_substantive == 0) continue;
        const contents = try allocator.alloc(types.ApiContent, n_actual);
        var idx: usize = 0;
        for (m.blocks) |b| {
            const c: types.ApiContent = switch (b) {
                .text => |t| .{ .text = t }, // 借用，不 dupe——lifetime 绑定 conversation
                .tool_use => |tu| .{ .tool_use = .{ .id = tu.id, .name = tu.name, .input = tu.input } },
                .tool_result => |tr| .{ .tool_result = .{
                    .tool_use_id = tr.tool_use_id,
                    .content = tr.content,
                    .is_error = tr.is_error,
                } },
                .image => |img| .{ .image = .{ .media_type = img.media_type, .data = img.data } },
                .document => |doc| .{ .document = .{
                    .media_type = doc.media_type,
                    .data = doc.data,
                    .title = doc.title,
                    .pages = doc.pages,
                } },
                .reasoning_item => |item| .{ .reasoning_item = .{ .model = item.model, .json = item.json } },
                .thinking => continue, // 不发回 API
            };
            contents[idx] = c;
            idx += 1;
        }
        try out.append(allocator, .{ .role = m.role, .content = contents });
    }
    if (synthetic_user_input) |synthetic_text| {
        if (synthetic_text.len > 0) {
            const contents = try allocator.alloc(types.ApiContent, 1);
            contents[0] = .{ .text = synthetic_text };
            try out.append(allocator, .{ .role = .user, .content = contents });
        }
    }
    // P0.6 弱模型健壮性层:发请求前规范化——剥孤儿 tool_result + 补缺失结果 + 合并连续同角色。
    // 维持 content 数组 owned / block 借用的内存契约(见 message_repair 顶注)。
    try @import("message_repair.zig").normalizeApiMessages(allocator, &out);
    return out;
}

fn freeApiMessages(list: *std.ArrayList(types.ApiMessage), allocator: std.mem.Allocator) void {
    for (list.items) |m| {
        allocator.free(m.content);
    }
    list.deinit(allocator);
}

fn estimateNextRequestTokens(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    conversation: *const Conversation,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
) !usize {
    // 热路径:usage 锚点有效 → 服务端实计 tokens + 锚点后新消息的本地估算。
    // 锚点请求已含 system/tools/inject_user_context,不重复计;synthetic 只在
    // turns==0 发,锚点在则它已被计入或不再发,同样不补。
    if (conversation.usageAnchor()) |anchor| {
        var total: usize = anchor.context_tokens;
        for (conversation.messages.items[anchor.msg_count..]) |m| {
            total += estimateMessageTokens(m);
        }
        return total;
    }
    // 冷路径(首轮/后端不报 usage/前缀被 compact 改写):序列化真实下一请求做全量估算。
    var api_messages = try buildApiMessages(conversation, allocator, inject_user_context, synthetic_user_input);
    defer freeApiMessages(&api_messages, allocator);
    return estimateApiRequestTokens(allocator, provider, api_messages.items, system_prompt, tool_defs, model_override);
}

/// 单条消息的 token 估算(usage 锚点后缀用):text/tool_use/tool_result 各 block
/// 走 Conversation.estimateTokens,再加 JSON 信封开销;thinking 不回 API 不计。
fn estimateMessageTokens(m: msg.Message) usize {
    var total: usize = 8; // message 信封(role/content 括号)
    for (m.blocks) |b| {
        total += 12; // block 信封(type/id 等字段)
        switch (b) {
            .text => |t| total += Conversation.estimateTokens(t),
            .tool_use => |tu| total += Conversation.estimateTokens(tu.name) + Conversation.estimateTokens(tu.input),
            // usage-anchor 热路径同口径:Read 图像 tool_result 落在锚点后缀时按
            // IMAGE_TOKEN_ESTIMATE 计,否则一次大图 Read 就把 anchor+增量推过
            // auto_threshold,每图强制一次有损 compact。
            .tool_result => |tr| total += if (json_mod.extractImageResult(tr.content) != null)
                conversation_mod.IMAGE_TOKEN_ESTIMATE
            else
                Conversation.estimateTokens(tr.content),
            .thinking => {},
            .image => total += conversation_mod.IMAGE_TOKEN_ESTIMATE,
            // 文档同图像取向:按 provider 的**页计费**估,不按 base64 字节
            // (12MB PDF ≈ 400 万 token,会把每次带文档的回合直接推过阈值)。
            .document => |doc| total += pdf_mod.estimateTokens(doc.data.len, doc.pages),
            // 加密推理状态:回传时 provider 按它编码的**推理 token** 计费,不是
            // 按密文字节。密文没有可本地推断的 token 数,取保守常量高估——
            // auto-compact 宁可早触发,绝不因低估爆窗口(与图像同一取向)。
            .reasoning_item => total += conversation_mod.REASONING_ITEM_TOKEN_ESTIMATE,
        }
    }
    return total;
}

/// 估算/预留/身份专用投影:把 base64 载荷换成短占位 text(真实请求绝不经此路径)。
/// 覆盖三条载荷通道:一等 `.image` block、一等 `.document` block(issue #25),
/// 以及 Read 工具图像形态的 tool_result(`{"type":"image",...}` JSON,经
/// request.zig extractImageResult 判定)。
/// 动机:①字节估算(≈bytes/4)会把 MB 级 base64 计成~百万 token(3.75MB 图 ≈ 125 万,
/// 12MB PDF ≈ 400 万),误触发 auto-compact 与预算门;②这些路径统一走 Anthropic
/// 序列化器,非 claude 模型带图/带文档会因能力守门报错(request_gate 场景 catch 成
/// maxInt → 必被预算拒)。投影后 body 无 base64、序列化必成功;图按
/// IMAGE_TOKEN_ESTIMATE、文档按页估算,单独加回。
/// 返回 null = 无图(调用方直接用原 slice,零分配零拷贝)。
/// pub:agentcore session_budget 的请求字节测量复用同一投影(加回真实载荷长度)。
pub const EstimationProjection = struct {
    messages: []types.ApiMessage,
    image_count: usize,
    /// 文档块 token 估算合计(逐块按页算,见 core/pdf.zig)——文档大小差异极大,
    /// 不能像图像那样用"数量 × 常量"。
    document_tokens: usize,

    pub fn deinit(self: EstimationProjection, allocator: std.mem.Allocator) void {
        for (self.messages) |m| allocator.free(m.content);
        allocator.free(self.messages);
    }
};

/// 需要在估算前换成占位的载荷块:base64 直接进字节估算会把一张图/一份 PDF
/// 计成上百万 token,且会撞上非 Claude 模型的能力守门。
fn contentNeedsProjection(c: types.ApiContent) bool {
    return switch (c) {
        .image, .document => true,
        .tool_result => |tr| json_mod.extractImageResult(tr.content) != null,
        else => false,
    };
}

pub fn projectPayloadsForEstimation(allocator: std.mem.Allocator, messages: []const types.ApiMessage) !?EstimationProjection {
    var image_count: usize = 0;
    var document_tokens: usize = 0;
    for (messages) |m| for (m.content) |c| {
        if (!contentNeedsProjection(c)) continue;
        switch (c) {
            .document => |doc| document_tokens +|= pdf_mod.estimateTokens(doc.data.len, doc.pages),
            else => image_count += 1,
        }
    };
    if (image_count == 0 and document_tokens == 0) return null;
    const out = try allocator.alloc(types.ApiMessage, messages.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |m| allocator.free(m.content);
        allocator.free(out);
    }
    for (messages, 0..) |m, i| {
        const content = try allocator.alloc(types.ApiContent, m.content.len);
        for (m.content, 0..) |c, ci| content[ci] = switch (c) {
            .image => .{ .text = "[image]" }, // static 占位,借用语义与其余 block 一致
            .document => .{ .text = "[document]" },
            .tool_result => |tr| if (json_mod.extractImageResult(tr.content) != null)
                .{ .tool_result = .{
                    .tool_use_id = tr.tool_use_id,
                    .content = "[image tool result]",
                    .is_error = tr.is_error,
                } }
            else
                c,
            else => c,
        };
        out[i] = .{ .role = m.role, .content = content };
        built = i + 1;
    }
    return .{ .messages = out, .image_count = image_count, .document_tokens = document_tokens };
}

/// 投影 + Anthropic-canonical 序列化(估算/预留/身份共用的唯一入口——"序列化用于
/// 度量必先投影"的不变量在此由构造保证,新消费者无法绕过)。调用方 free body。
const EstimationBody = struct { body: []u8, image_tokens: u64 };

fn serializeForEstimation(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    messages: []const types.ApiMessage,
    system_prompt: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
) !EstimationBody {
    const projection = try projectPayloadsForEstimation(allocator, messages);
    defer if (projection) |p| p.deinit(allocator);
    const effective: []const types.ApiMessage = if (projection) |p| p.messages else messages;
    // 图像按张计常量,文档按页计(逐块估算已在投影里累加)。
    const image_tokens: u64 = @intCast(
        (if (projection) |p| p.image_count else 0) * conversation_mod.IMAGE_TOKEN_ESTIMATE +
            (if (projection) |p| p.document_tokens else 0),
    );
    const body = try json_mod.serializeMessagesRequest(.{
        .model = model_override orelse provider.model(),
        .max_tokens = provider.maxTokens(),
        .messages = effective,
        .system = system_prompt,
        .stream = true,
        .tools = tool_defs,
        .reasoning_effort = provider.reasoningEffort(),
    }, allocator);
    return .{ .body = body, .image_tokens = image_tokens };
}

fn estimateApiRequestTokens(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    messages: []const types.ApiMessage,
    system_prompt: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
) !usize {
    const est = try serializeForEstimation(allocator, provider, messages, system_prompt, tool_defs, model_override);
    defer allocator.free(est.body);
    return Conversation.estimateTokens(est.body) +| @as(usize, @intCast(est.image_tokens));
}

/// Conservative request-local input reserve used by the paid evaluation gate.
/// Freeze both independent estimates: twice the calibrated local tokenizer
/// estimate, or one token per two serialized UTF-8 bytes, whichever is larger.
/// The fixed margin covers provider-side chat framing absent from the JSON.
fn serializedRequestInputTokenReserve(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    messages: []const types.ApiMessage,
    system_prompt: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
) !u64 {
    // 图像经估算投影(serializeForEstimation):按 IMAGE_TOKEN_ESTIMATE 计入 estimated
    // (随 doubled 一起获得 2x 预留),不按 base64 字节计——否则一张图就把预留推到
    // ~百万 token,request_gate 必拒。byte_reserve 的 floor 相应基于投影后 body:
    // provider 按 token 计费(base64 字节不进 tokenizer 语义),图的预留由
    // IMAGE_TOKEN_ESTIMATE*2(≈2x 缩放上限)承担,不再由 wire 字节 floor 承担。
    const est = try serializeForEstimation(allocator, provider, messages, system_prompt, tool_defs, model_override);
    defer allocator.free(est.body);
    const estimated = @as(u64, @intCast(Conversation.estimateTokens(est.body))) +| est.image_tokens;
    const doubled_estimate = estimated *| 2;
    const byte_reserve = (@as(u64, @intCast(est.body.len)) +| 1) / 2;
    return @max(doubled_estimate, byte_reserve) +| 4096;
}

/// Provider-neutral identity of the exact AgentLoop request IR. Concrete
/// transports may serialize different wire dialects, but retries and restored
/// runs compare this canonical projection before any provider I/O.
/// 图像处理:canonical 序列化用估算投影(占位替换,避开 vision 守门——否则非 claude
/// vision 模型带图的 execution-boundary 会话在此报错,run 直接 .api_error),图像
/// 内容的身份经原始载荷字节按序追加进 hash(sha256Hex 每段带长度前缀,无拼接歧义):
/// 两图交换/换内容/换 MIME → hash 变;身份完备且恒可计算。
fn canonicalAgentRequestSha256(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    messages: []const types.ApiMessage,
    system_prompt: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
) ![64]u8 {
    const est = try serializeForEstimation(allocator, provider, messages, system_prompt, tool_defs, model_override);
    defer allocator.free(est.body);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, est.body);
    for (messages) |m| for (m.content) |c| switch (c) {
        .image => |img| {
            try parts.append(allocator, img.media_type);
            try parts.append(allocator, img.data);
        },
        .document => |doc| {
            try parts.append(allocator, doc.media_type);
            try parts.append(allocator, doc.title);
            try parts.append(allocator, doc.data);
        },
        // 推理续传项不进 Anthropic canonical 序列化(那是 Responses 私有形态),
        // 但两个只在它上有差别的请求确实是不同的请求 IR —— 一并进身份哈希。
        .reasoning_item => |item| {
            try parts.append(allocator, item.model);
            try parts.append(allocator, item.json);
        },
        .tool_result => |tr| if (json_mod.extractImageResult(tr.content) != null) {
            try parts.append(allocator, tr.content);
        },
        else => {},
    };
    return execution_effect.sha256Hex(parts.items);
}

fn estimateNextRequestTokensOrFallback(
    allocator: std.mem.Allocator,
    provider: provider_mod.Provider,
    conversation: *const Conversation,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
) usize {
    return estimateNextRequestTokens(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override) catch |err| {
        log.warn("agent", "actual request token estimate failed: {s}; using fallback estimate", .{@errorName(err)});
        return estimateNextRequestTokensFallback(conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs);
    };
}

const AutoCompactOutcome = enum { not_needed, compacted, skipped_no_savings, aborted, api_error };

fn serializeToolSchemasForCache(
    allocator: std.mem.Allocator,
    tool_defs: []const json_mod.ToolDefinition,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    for (tool_defs, 0..) |tool, index| {
        if (index > 0) try out.append(allocator, ',');
        try @import("../api/request.zig").serializeOneTool(tool, &out, allocator);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn recoverContextWindowExceeded(
    conversation: *Conversation,
    provider: provider_mod.Provider,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
    backend: *const UiBackend,
    sess: @import("session_id.zig").SessionId,
    attempts: *usize,
    cap: usize,
    turn_number: u32,
    allocator: std.mem.Allocator,
) bool {
    attempts.* += 1;
    if (attempts.* > cap) {
        log.err("agent", "context-window recovery exhausted turn={d} attempts={d}", .{ turn_number, attempts.* });
        return false;
    }
    // 先作废 usage 锚点:removeOldest 反正会作废它,提前作废让 before/after 同用
    // 冷路径基准——否则 before=锚点实计、after=冷估算,删消息后数字反而翻倍(假遥测,
    // 实录 2026-07-06 fix4.log:dropped=1 before=203081 after=415469)。
    conversation.invalidateUsageAnchor();
    const before_tokens = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
    // 投影:removeOldest 推进 boundary(原始不删),收缩的是活跃窗口 → 遥测用活跃计数,否则 N->N。
    const before_active = conversation.activeMessages().len;
    const dropped = conversation.removeOldestForContextRecovery();
    if (dropped == 0) {
        log.err("agent", "context-window recovery impossible turn={d} active_msgs={d}", .{ turn_number, conversation.activeMessages().len });
        return false;
    }
    const after_tokens = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
    const kept_active = conversation.activeMessages().len;
    log.warn("agent", "context-window recovery: dropped={d} active_msgs={d}->{d} before_tokens={d} after_tokens={d} attempt={d}", .{ dropped, before_active, kept_active, before_tokens, after_tokens, attempts.* });
    backend.emitEvent(sess, .{ .auto_compact = .{
        .dropped = @as(u32, @intCast(dropped)),
        .kept = @as(u32, @intCast(kept_active)),
        .before_tokens = @intCast(before_tokens),
        .after_tokens = @intCast(after_tokens),
        .cause = "context_window_exceeded_recovery",
    } });
    return true;
}

/// 构造 PostCompact hook 的 stdin JSON(summary 是自由文本须 JSON 转义)。
fn buildPostCompactStdin(allocator: std.mem.Allocator, trigger: []const u8, summary: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"hook_event_name\":\"PostCompact\",\"trigger\":");
    try std.json.Stringify.encodeJsonString(trigger, .{}, &aw.writer);
    try aw.writer.writeAll(",\"summary\":");
    try std.json.Stringify.encodeJsonString(summary, .{}, &aw.writer);
    try aw.writer.writeAll("}");
    return try aw.toOwnedSlice();
}

fn emitContextProjection(
    backend: *const UiBackend,
    sess: @import("session_id.zig").SessionId,
    conversation: *const Conversation,
    kind: []const u8,
    cause: []const u8,
    reduction: Conversation.ToolResultReduction,
) void {
    if (!reduction.changed()) return;
    const changed = reduction.cleared +| reduction.truncated;
    backend.emitEvent(sess, .{ .context_projection = .{
        .kind = kind,
        .changed_items = @intCast(@min(changed, @as(usize, std.math.maxInt(u32)))),
        .bytes_before = @intCast(reduction.bytes_before),
        .bytes_after = @intCast(reduction.bytes_after),
        .active_messages = @intCast(@min(conversation.activeMessages().len, @as(usize, std.math.maxInt(u32)))),
        .cause = cause,
    } });
}

/// 构造 Stop hook 的 stdin JSON(last_message 自由文本须转义)。供记忆提取等 side-effect hook 用。
fn buildStopStdin(allocator: std.mem.Allocator, stop_reason: []const u8, last_message: []const u8, num_messages: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"hook_event_name\":\"Stop\",\"stop_reason\":");
    try std.json.Stringify.encodeJsonString(stop_reason, .{}, &aw.writer);
    try aw.writer.writeAll(",\"last_message\":");
    try std.json.Stringify.encodeJsonString(last_message, .{}, &aw.writer);
    try aw.writer.print(",\"num_messages\":{d}}}", .{num_messages});
    return try aw.toOwnedSlice();
}

/// Stop hook(顶层 agent 自然结束时触发):喂最后一条 assistant 文本(截断)+ 消息数,供
/// 记忆提取等 side-effect hook 用。depth!=0(subagent)不触发;无 Stop hook 直接返回。非阻塞。
fn fireStopHook(hookset: ?*const hooks_mod.HookSet, allocator: std.mem.Allocator, conversation: *const Conversation, stop_reason: []const u8, depth: u8) void {
    if (depth != 0) return;
    const hs = hookset orelse return;
    if (!hs.hasStop()) return;
    var last_text: []const u8 = "";
    var i = conversation.messages.items.len;
    while (i > 0) : (i -= 1) {
        const m = conversation.messages.items[i - 1];
        if (m.role != .assistant) continue;
        for (m.blocks) |b| switch (b) {
            .text => |t| {
                last_text = t;
                break;
            },
            else => {},
        };
        if (last_text.len > 0) break;
    }
    const MAX_STOP_TEXT = 4000;
    const trimmed = if (last_text.len > MAX_STOP_TEXT) last_text[0..MAX_STOP_TEXT] else last_text;
    const stdin_json = buildStopStdin(allocator, stop_reason, trimmed, conversation.messages.items.len) catch return;
    defer allocator.free(stdin_json);
    if (hooks_mod.runLifecycleHooks(hs.stop, allocator, "Stop", stdin_json)) |ac| allocator.free(ac);
}

fn runAutoCompactIfNeeded(
    conversation: *Conversation,
    provider: provider_mod.Provider,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
    model_override: ?[]const u8,
    compact_model_override: ?[]const u8,
    configured_threshold: ?usize,
    keep_recent: usize,
    trigger_cause: []const u8,
    backend: *const UiBackend,
    sess: @import("session_id.zig").SessionId,
    trace_id: [12]u8,
    depth: u8,
    turn: u32,
    context_warning_emitted: ?*bool,
    allocator: std.mem.Allocator,
    tasks: ?*@import("task_store.zig").TaskStore,
    hookset: ?*const hooks_mod.HookSet,
    summary_reserve_tokens: ?*usize,
    request_gate: ?request_gate_mod.Gate,
    abort: ?*const AbortSignal,
) !AutoCompactOutcome {
    var outcome: AutoCompactOutcome = .not_needed;

    var request_tokens_before = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
    var pressure = context_pressure_mod.ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens(), configured_threshold, request_tokens_before);
    emitContextWarningIfNeeded(backend, sess, pressure, context_warning_emitted);
    // 正常:auto=max(formula, 32K floor);micro=其下一档。强制旋钮(仅测试/power-user)存在时,
    // auto/micro 一起钉到强制值——让短对话也能触发真实 summary 压缩+投影。一次 getenv,不在热路径重复读。
    const forced_threshold = forcedAutoCompactThreshold();
    const auto_threshold: usize = forced_threshold orelse
        @max(pressure.auto_compact_threshold, MIN_AUTO_COMPACT_THRESHOLD);
    const micro_threshold = forced_threshold orelse
        @max(@min(pressure.warning_threshold, auto_threshold), MIN_AUTO_COMPACT_THRESHOLD);
    if (request_tokens_before > micro_threshold and request_tokens_before <= auto_threshold) {
        var reduced = conversation.microcompactToolResultsByRecentResults(conversation_mod.DEFAULT_RECENT_TOOL_RESULTS_TO_KEEP);
        // Clearing deliberately preserves the most recent results, and skips
        // anything whose artifact envelope is its only recovery capability.
        // Neither exemption bounds a single oversized result that entered the
        // Conversation under a different budget (a /resume'd transcript, or a
        // switch to a smaller window), because projection never re-runs on
        // history. Bound those here against the same per-result budget
        // projection uses, so the `truncated=` field of the line below stops
        // being structurally zero.
        reduced.merge(conversation.truncateLargeToolResults(
            conversation_mod.toolResultContextBytes(provider.maxInputTokens()),
        ));
        if (reduced.changed()) {
            outcome = .compacted;
            log.info("agent", "microcompact: cleared={d} truncated={d} old tool_results bytes={d}->{d} keep_recent_results={d} threshold={d} cause={s}", .{ reduced.cleared, reduced.truncated, reduced.bytes_before, reduced.bytes_after, conversation_mod.DEFAULT_RECENT_TOOL_RESULTS_TO_KEEP, micro_threshold, trigger_cause });
            emitContextProjection(backend, sess, conversation, "stale_tool_result_microcompact", trigger_cause, reduced);
            request_tokens_before = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
            pressure = context_pressure_mod.ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens(), configured_threshold, request_tokens_before);
        }
    }

    if (request_tokens_before >= auto_threshold) {
        // PreCompact hook(压缩前):喂 {trigger, active_msgs, tokens},side-effect(如存盘/记忆快照),非阻塞。
        if (hookset) |hs| if (hs.hasPreCompact()) {
            const pre_json = std.fmt.allocPrint(allocator, "{{\"hook_event_name\":\"PreCompact\",\"trigger\":\"{s}\",\"active_messages\":{d},\"tokens\":{d}}}", .{ trigger_cause, conversation.activeMessages().len, request_tokens_before }) catch null;
            if (pre_json) |pj| {
                defer allocator.free(pj);
                if (hooks_mod.runLifecycleHooks(hs.pre_compact, allocator, "PreCompact", pj)) |ac| allocator.free(ac);
            }
        };
        const compact_summary = @import("compact_summary.zig");
        const summary_model = compact_model_override orelse model_override;
        const eff_keep_recent = forcedAutoCompactKeep() orelse keep_recent;
        if (conversation.compactBoundary(eff_keep_recent) <= conversation.compact_boundary)
            return outcome;
        // 任务锚:进行中的任务确定性追加到摘要尾(压缩有损,闭环纪律硬保底)。
        const task_anchor: ?[]u8 = if (tasks) |ts| compact_summary.buildTaskAnchor(allocator, ts) else null;
        defer if (task_anchor) |a| allocator.free(a);
        // Lifecycle boundary: compact is now admitted. Keep this separate
        // from diag_compact_request, whose existing meaning is the completed
        // provider summary request consumed by evaluation telemetry.
        const compact_started_ns = util_time.nowNs();
        var compact_lifecycle_outcome: []const u8 = "api_error";
        backend.emitEvent(sess, .{ .diag_compact_begin = .{
            .trace_id = trace_id,
            .depth = depth,
            .turn = turn,
            .cause = trigger_cause,
        } });
        defer backend.emitEvent(sess, .{ .diag_compact_end = .{
            .trace_id = trace_id,
            .depth = depth,
            .turn = turn,
            .elapsed_ms = elapsedSinceNs(compact_started_ns),
            .outcome = compact_lifecycle_outcome,
            .cause = trigger_cause,
        } });
        const EstimateContext = struct {
            allocator: std.mem.Allocator,
            provider: provider_mod.Provider,
            system_prompt: ?[]const u8,
            inject_user_context: ?[]const u8,
            synthetic_user_input: ?[]const u8,
            tool_defs: []const json_mod.ToolDefinition,
            model_override: ?[]const u8,

            fn estimate(raw: *anyopaque, value: *const Conversation) usize {
                const self: *@This() = @ptrCast(@alignCast(raw));
                return estimateNextRequestTokensOrFallback(
                    self.allocator,
                    self.provider,
                    value,
                    self.system_prompt,
                    self.inject_user_context,
                    self.synthetic_user_input,
                    self.tool_defs,
                    self.model_override,
                );
            }
        };
        var estimate_ctx = EstimateContext{
            .allocator = allocator,
            .provider = provider,
            .system_prompt = system_prompt,
            .inject_user_context = inject_user_context,
            .synthetic_user_input = synthetic_user_input,
            .tool_defs = tool_defs,
            .model_override = model_override,
        };
        var local_abort = AbortSignal.init();
        const signal = abort orelse &local_abort;
        const report = compact_kernel.run(
            allocator,
            conversation,
            provider,
            signal,
            .{
                .keep_recent = eff_keep_recent,
                .model_override = summary_model,
                .task_anchor = task_anchor,
                .estimator = .{
                    .ctx = &estimate_ctx,
                    .estimate_fn = EstimateContext.estimate,
                },
                .minimum_saved_percent = COMPACT_MIN_SAVED_PERCENT,
                .minimum_summary_reserve_tokens = if (compact_model_override == null)
                    if (summary_reserve_tokens) |reserve| reserve.* else 0
                else
                    0,
                .request_gate = request_gate,
                .target_tokens = auto_threshold,
            },
        ) catch |err| {
            log.warn("agent", "auto-compact kernel failed: {s}", .{@errorName(err)});
            return .api_error;
        };
        // Persist metered usage before the diagnostic event. If the process is
        // hard-killed between the two complete NDJSON records, budget evidence
        // survives even if request-count telemetry is conservatively partial.
        if (usageChanged(report.usage))
            backend.emitEvent(sess, .{ .usage = report.usage });
        if (report.summary_request) |request| {
            backend.emitEvent(sess, .{ .diag_compact_request = .{
                .trace_id = trace_id,
                .depth = depth,
                .turn = turn,
                .elapsed_ms = request.elapsed_ms,
                .outcome = @tagName(request.outcome),
                .cause = trigger_cause,
            } });
        }
        switch (report.outcome) {
            .aborted => {
                compact_lifecycle_outcome = "aborted";
                return .aborted;
            },
            .no_change => {
                if (compact_model_override == null and report.summary_request != null) {
                    if (summary_reserve_tokens) |reserve|
                        reserve.* = @max(reserve.*, report.summary_overhead_tokens);
                }
                const active_reserve = if (summary_reserve_tokens) |reserve| reserve.* else 0;
                log.warn("agent", "auto-compact skipped: summary savings below {d}% before_tokens={d} after_tokens={d} summary_reserve_tokens={d} paid_request={} cause={s}", .{ COMPACT_MIN_SAVED_PERCENT, report.before_tokens, report.after_tokens, active_reserve, report.summary_request != null, trigger_cause });
                outcome = .skipped_no_savings;
                compact_lifecycle_outcome = "no_change";
            },
            .compacted, .degraded => {
                compact_lifecycle_outcome = if (report.outcome == .compacted) "compacted" else "degraded";
                if (compact_model_override == null) {
                    if (summary_reserve_tokens) |reserve| reserve.* = 0;
                }
                // PostCompact hook(压缩后):喂 {trigger, summary},其 additionalContext 拼进投影摘要
                // → 模型下轮读得到(条目 I 的挂载点:重注入 active skill/plan/MCP)。非阻塞。
                if (hookset) |hs| if (hs.hasPostCompact()) {
                    const pj = buildPostCompactStdin(allocator, trigger_cause, conversation.compact_summary orelse "") catch null;
                    if (pj) |json| {
                        defer allocator.free(json);
                        if (hooks_mod.runLifecycleHooks(hs.post_compact, allocator, "PostCompact", json)) |extra| {
                            defer allocator.free(extra);
                            conversation.appendToCompactSummary(extra);
                        }
                    }
                };
                // 投影:len() 不变(原始不删),真正收缩的是活跃窗口——日志/事件的"after/kept"用活跃计数。
                const cause: []const u8 = if (report.emergency_reduced)
                    "tool_result_pressure"
                else if (report.outcome == .degraded)
                    "summary_fallback"
                else
                    trigger_cause;
                log.info("agent", "auto-compact: dropped {d} old messages kept={d} threshold={d} before_tokens={d} after_tokens={d} cause={s}", .{ report.dropped, report.kept, auto_threshold, report.before_tokens, report.after_tokens, cause });
                backend.emitEvent(sess, .{ .auto_compact = .{
                    .dropped = @as(u32, @intCast(report.dropped)),
                    .kept = @as(u32, @intCast(report.kept)),
                    .before_tokens = @intCast(report.before_tokens),
                    .after_tokens = @intCast(report.after_tokens),
                    .cause = cause,
                } });
                outcome = .compacted;
                request_tokens_before = report.after_tokens;
                pressure = context_pressure_mod.ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens(), configured_threshold, request_tokens_before);
            },
        }
    }

    if (outcome == .skipped_no_savings) return outcome;

    if (pressure.isAtBlockingLimit()) {
        var reduced = conversation.microcompactToolResultsByRecentResults(0);
        // Same rationale as the stale-result valve above, and it matters more
        // here: at the blocking limit the request is otherwise rejected, so a
        // single unbounded surviving result is the difference between
        // recovering and returning api_error.
        reduced.merge(conversation.truncateLargeToolResults(
            conversation_mod.toolResultContextBytes(provider.maxInputTokens()),
        ));
        if (reduced.changed()) {
            outcome = .compacted;
            const before_block_tokens = request_tokens_before;
            request_tokens_before = estimateNextRequestTokensOrFallback(allocator, provider, conversation, system_prompt, inject_user_context, synthetic_user_input, tool_defs, model_override);
            pressure = context_pressure_mod.ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens(), configured_threshold, request_tokens_before);
            log.warn("agent", "blocking-limit recovery microcompact: bytes={d}->{d} before_tokens={d} after_tokens={d} cause={s}", .{ reduced.bytes_before, reduced.bytes_after, before_block_tokens, request_tokens_before, trigger_cause });
            // This is the same lossy operation as the earlier stale-result
            // pressure valve.  Keep the mechanism kind stable; the trigger
            // cause already records that this happened at the blocking limit.
            emitContextProjection(backend, sess, conversation, "stale_tool_result_microcompact", trigger_cause, reduced);
        }
        if (pressure.isAtBlockingLimit()) {
            log.err("agent", "context blocking limit reached: tokens={d} blocking_limit={d} raw_window={d} effective_window={d} cause={s}", .{ request_tokens_before, pressure.blocking_limit, pressure.raw_context_window, pressure.effective_context_window, trigger_cause });
            return .api_error;
        }
    }
    return outcome;
}

fn emitContextWarningIfNeeded(
    backend: *const UiBackend,
    sess: @import("session_id.zig").SessionId,
    pressure: context_pressure_mod.ContextPressure,
    emitted: ?*bool,
) void {
    const flag = emitted orelse return;
    if (flag.*) return;
    if (pressure.level() != .medium) return;
    flag.* = true;
    backend.emitEvent(sess, .{ .context_warning = .{
        .current_tokens = @intCast(pressure.current_context_tokens),
        .warning_threshold = @intCast(pressure.warning_threshold),
        .auto_compact_threshold = @intCast(pressure.auto_compact_threshold),
        .blocking_limit = @intCast(pressure.blocking_limit),
        .level = pressure.level().label(),
    } });
}

fn usageChanged(usage: api_stream.UsageDelta) bool {
    return usage.input_tokens != 0 or
        usage.output_tokens != 0 or
        usage.cache_read_input_tokens != 0 or
        usage.cache_creation_input_tokens != 0;
}

fn estimateNextRequestTokensFallback(
    conversation: *const Conversation,
    system_prompt: ?[]const u8,
    inject_user_context: ?[]const u8,
    synthetic_user_input: ?[]const u8,
    tool_defs: []const json_mod.ToolDefinition,
) usize {
    var total = conversation.totalTokens();
    if (system_prompt) |s| total += Conversation.estimateTokens(s);
    if (inject_user_context) |s| total += Conversation.estimateTokens(s);
    if (synthetic_user_input) |s| total += Conversation.estimateTokens(s);
    for (tool_defs) |tool| {
        total += Conversation.estimateTokens(tool.name);
        total += Conversation.estimateTokens(tool.description);
        if (tool.server_type) |server_type| total += Conversation.estimateTokens(server_type);
        total += estimateInputSchemaTokens(tool.input_schema);
    }
    return total;
}

fn estimateInputSchemaTokens(schema: json_mod.InputSchema) usize {
    var total = Conversation.estimateTokens(schema.type);
    if (schema.prop_specs) |props| {
        total += estimatePropSpecsTokens(props);
    }
    if (schema.required) |required| {
        for (required) |r| total += Conversation.estimateTokens(r);
    }
    if (schema.properties) |props| {
        var it = props.iterator();
        while (it.next()) |entry| total += Conversation.estimateTokens(entry.key_ptr.*);
    }
    return total;
}

fn estimatePropSpecsTokens(props: []const json_mod.PropSpec) usize {
    var total: usize = 0;
    for (props) |prop| {
        total += Conversation.estimateTokens(prop.name);
        total += Conversation.estimateTokens(prop.type);
        total += Conversation.estimateTokens(prop.description);
        if (prop.items_type) |t| total += Conversation.estimateTokens(t);
        if (prop.enum_values) |vals| {
            for (vals) |v| total += Conversation.estimateTokens(v);
        }
        if (prop.items_props) |nested| total += estimatePropSpecsTokens(nested);
        if (prop.items_required) |required| {
            for (required) |r| total += Conversation.estimateTokens(r);
        }
        if (prop.object_props) |nested| total += estimatePropSpecsTokens(nested);
        if (prop.object_required) |required| {
            for (required) |r| total += Conversation.estimateTokens(r);
        }
    }
    return total;
}

test "emitProgress 发 CoreEvent.progress 到 backend(L1:进度=事件)" {
    const S = struct {
        var hits: u32 = 0;
        var last_turn: u32 = 0;
        var last_calls: u32 = 0;
        var last_tool: [16]u8 = undefined;
        var last_tool_len: usize = 0;
        fn emit(_: *anyopaque, _: ui_backend.SessionId, ev: ui_backend.CoreEvent) void {
            switch (ev) {
                .progress => |p| {
                    hits += 1;
                    last_turn = p.turn;
                    last_calls = p.tool_calls;
                    last_tool_len = @min(p.tool_name.len, last_tool.len);
                    @memcpy(last_tool[0..last_tool_len], p.tool_name[0..last_tool_len]);
                },
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: ui_backend.SessionId) ?ui_backend.UiEvent {
            return null;
        }
    };
    S.hits = 0;
    var dummy: u8 = 0;
    const be = ui_backend.UiBackend{ .ctx = @ptrCast(&dummy), .emit = &S.emit, .poll = &S.poll };
    emitProgress(&be, .single, 2, "Grep", "{}", 5);
    try std.testing.expectEqual(@as(u32, 1), S.hits);
    try std.testing.expectEqual(@as(u32, 2), S.last_turn);
    try std.testing.expectEqual(@as(u32, 5), S.last_calls);
    try std.testing.expectEqualStrings("Grep", S.last_tool[0..S.last_tool_len]);
}

test "buildApiMessages maps blocks" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "hi");

    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);

    try std.testing.expect(api.items.len == 1);
    try std.testing.expect(api.items[0].role == .user);
    try std.testing.expect(api.items[0].content.len == 1);
    try std.testing.expectEqualStrings("hi", api.items[0].content[0].text);
}

test "buildApiMessages omits thinking-only assistant before continuation" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    try c.appendText(.user, "fix the bug");
    const thinking_blocks = try a.alloc(msg.Block, 1);
    thinking_blocks[0] = .{ .thinking = try a.dupe(u8, "private truncated reasoning") };
    try c.append(.{ .role = .assistant, .blocks = thinking_blocks });
    try c.appendText(.user, "Continue exactly where you left off.");

    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);

    try std.testing.expectEqual(@as(usize, 1), api.items.len);
    try std.testing.expectEqual(types.MessageRole.user, api.items[0].role);
    try std.testing.expect(api.items[0].content.len > 0);
    for (api.items) |message| try std.testing.expect(message.content.len > 0);
}

test "buildApiMessages maps tool_use and tool_result" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    // assistant with tool_use
    const blks_a = try a.alloc(msg.Block, 1);
    blks_a[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"path\":\"/x\"}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = blks_a });

    // user with tool_result
    const blks_u = try a.alloc(msg.Block, 1);
    blks_u[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "ok"),
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blks_u });

    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);

    try std.testing.expect(api.items.len == 2);
    try std.testing.expect(@as(std.meta.Tag(types.ApiContent), api.items[0].content[0]) == .tool_use);
    try std.testing.expect(@as(std.meta.Tag(types.ApiContent), api.items[1].content[0]) == .tool_result);
}

test "buildApiMessages empty conversation returns empty" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);
    try std.testing.expect(api.items.len == 0);
}

test "buildApiMessages preserves roles" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "u1");
    try c.appendText(.assistant, "a1");
    try c.appendText(.user, "u2");
    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);
    try std.testing.expect(api.items[0].role == .user);
    try std.testing.expect(api.items[1].role == .assistant);
    try std.testing.expect(api.items[2].role == .user);
}

test "buildApiMessages multiple blocks per message" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    const blks = try a.alloc(msg.Block, 2);
    blks[0] = .{ .text = try a.dupe(u8, "preamble") };
    blks[1] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = blks });
    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);
    try std.testing.expect(api.items[0].content.len == 2);
}

test "buildApiMessages appends one-shot synthetic user input without mutating conversation" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "real user");

    var api = try buildApiMessages(&c, a, null, "synthetic steering");
    defer freeApiMessages(&api, a);

    try std.testing.expectEqual(@as(usize, 1), c.len());
    // P0.6 normalizeApiMessages 合并相邻同角色:real user + synthetic 都是 user →
    // 合成 1 条 user 消息(2 个 text block),满足 OpenAI/Gemini 严格角色交替。conversation 不被改动。
    try std.testing.expectEqual(@as(usize, 1), api.items.len);
    try std.testing.expect(api.items[0].role == .user);
    try std.testing.expectEqual(@as(usize, 2), api.items[0].content.len);
    try std.testing.expectEqualStrings("real user", api.items[0].content[0].text);
    try std.testing.expectEqualStrings("synthetic steering", api.items[0].content[1].text);
}

const TestProviderState = struct {
    model: []const u8 = "test-model",
    max_tokens: u32 = 777,
    max_input_tokens: u32 = 200_000,
    supports_web_search: bool = true,
    reasoning_effort: ?types.ReasoningEffort = null,
    allocator: ?std.mem.Allocator = null,
    compact_summary_response: ?[]const u8 = null,
    last_send_model_override: ?[]const u8 = null,
    compact_stream_stage: u8 = 0,
    compact_request_count: u32 = 0,
};

fn testProvider(state: *TestProviderState) provider_mod.Provider {
    const F = struct {
        fn asState(ctx: *anyopaque) *TestProviderState {
            return @ptrCast(@alignCast(ctx));
        }
        fn model(ctx: *anyopaque) []const u8 {
            return asState(ctx).model;
        }
        fn sendStream(ctx: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?*const AbortSignal, model_override: ?[]const u8, _: ?json_mod.ToolChoice, _: []const u8) anyerror!provider_mod.StreamHandle {
            const st = asState(ctx);
            if (st.compact_summary_response == null or st.allocator == null)
                return error.UnexpectedTestCall;
            st.compact_request_count += 1;
            st.last_send_model_override = model_override;
            st.compact_stream_stage = 0;
            return .{
                .ctx = ctx,
                .nextFn = streamNext,
                .deinitFn = streamDeinit,
                .stopReasonFn = streamStop,
                .requestIdFn = streamRequestId,
            };
        }
        fn streamNext(ctx: *anyopaque) anyerror!?api_stream.StreamEvent {
            const st = asState(ctx);
            defer st.compact_stream_stage += 1;
            return switch (st.compact_stream_stage) {
                0 => .{ .text = try st.allocator.?.dupe(u8, st.compact_summary_response.?) },
                1 => .{ .usage = .{ .input_tokens = 11, .output_tokens = 7 } },
                2 => .{ .done = {} },
                else => null,
            };
        }
        fn streamDeinit(_: *anyopaque) void {}
        fn streamStop(_: *anyopaque) api_stream.StopReason {
            return .end_turn;
        }
        fn streamRequestId(_: *anyopaque) log.RequestId {
            return log.RequestId{ .bytes = [_]u8{1} ** 12 };
        }
        fn sendStreamRetry(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?*const AbortSignal, _: ?[]const u8, _: ?json_mod.ToolChoice, _: u32, _: u64, _: ?provider_mod.RetryReporter, _: []const u8) anyerror!provider_mod.StreamHandle {
            return error.UnexpectedTestCall;
        }
        fn send(ctx: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, model_override: ?[]const u8) anyerror!provider_mod.ApiResponse {
            const st = asState(ctx);
            st.last_send_model_override = model_override;
            if (st.compact_summary_response) |body| {
                const a = st.allocator orelse return error.UnexpectedTestCall;
                return .{ .content = try a.dupe(u8, body) };
            }
            return error.UnexpectedTestCall;
        }
        fn maxTokens(ctx: *anyopaque) u32 {
            return asState(ctx).max_tokens;
        }
        fn maxInputTokens(ctx: *anyopaque) u32 {
            return asState(ctx).max_input_tokens;
        }
        fn reasoningEffort(ctx: *anyopaque) ?types.ReasoningEffort {
            return asState(ctx).reasoning_effort;
        }
        fn supports(ctx: *anyopaque, cap: provider_mod.Capability) bool {
            if (cap == .web_search) return asState(ctx).supports_web_search;
            return true;
        }
    };
    return .{
        .ctx = @ptrCast(state),
        .modelFn = F.model,
        .sendStreamFn = F.sendStream,
        .sendStreamRetryFn = F.sendStreamRetry,
        .sendFn = F.send,
        .maxTokensFn = F.maxTokens,
        .maxInputTokensFn = F.maxInputTokens,
        .reasoningEffortFn = F.reasoningEffort,
        .supportsFn = F.supports,
    };
}

test "estimateNextRequestTokens serializes the actual next Anthropic request" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "short");

    var state = TestProviderState{ .model = "base-model", .max_tokens = 777, .reasoning_effort = .medium };
    const provider = testProvider(&state);
    const tool_defs = [_]json_mod.ToolDefinition{.{
        .name = "Read",
        .description = "Read file contents",
        .input_schema = .{ .prop_specs = &.{.{ .name = "file_path", .type = "string", .description = "Path to read" }}, .required = &.{"file_path"} },
    }};
    const estimated = try estimateNextRequestTokens(
        a,
        provider,
        &c,
        "system prompt text",
        "user context text",
        "synthetic steering text",
        &tool_defs,
        "override-model",
    );

    var api = try buildApiMessages(&c, a, "user context text", "synthetic steering text");
    defer freeApiMessages(&api, a);
    const body = try json_mod.serializeMessagesRequest(.{
        .model = "override-model",
        .max_tokens = 777,
        .messages = api.items,
        .system = "system prompt text",
        .stream = true,
        .tools = &tool_defs,
        .reasoning_effort = .medium,
    }, a);
    defer a.free(body);
    try std.testing.expectEqual(Conversation.estimateTokens(body), estimated);
    try std.testing.expectEqual(
        @max(
            @as(u64, @intCast(Conversation.estimateTokens(body))) * 2,
            (@as(u64, @intCast(body.len)) + 1) / 2,
        ) + 4096,
        try serializedRequestInputTokenReserve(
            a,
            provider,
            api.items,
            "system prompt text",
            &tool_defs,
            "override-model",
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, body, "synthetic steering text") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "override-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"effort\":\"medium\"}") != null);
}

test "cache-break fingerprint binds full schemas for same-named tools" {
    const a = std.testing.allocator;
    const first = [_]json_mod.ToolDefinition{.{
        .name = "Read",
        .description = "read a file",
        .input_schema = .{
            .prop_specs = &.{.{ .name = "file_path", .type = "string" }},
            .required = &.{"file_path"},
        },
    }};
    const changed = [_]json_mod.ToolDefinition{.{
        .name = "Read",
        .description = "read a bounded file slice",
        .input_schema = .{
            .prop_specs = &.{
                .{ .name = "file_path", .type = "string" },
                .{ .name = "limit", .type = "integer" },
            },
            .required = &.{"file_path"},
        },
    }};
    const first_bytes = try serializeToolSchemasForCache(a, &first);
    defer a.free(first_bytes);
    const changed_bytes = try serializeToolSchemasForCache(a, &changed);
    defer a.free(changed_bytes);
    try std.testing.expect(!std.mem.eql(u8, first_bytes, changed_bytes));

    var detector = @import("cache_break.zig").CacheBreakDetector{};
    detector.recordRequest("stable-system", first_bytes, "glm-5.2");
    _ = detector.checkResponse(5_000, 0);
    detector.recordRequest("stable-system", changed_bytes, "glm-5.2");
    try std.testing.expectEqualStrings(
        "tool schemas changed",
        detector.checkResponse(100, 4_900).?,
    );
}

test "usage anchor: estimate = server tokens + suffix estimate; no anchor falls back to serialize" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "question");

    var state = TestProviderState{};
    const provider = testProvider(&state);

    // 无锚点:冷路径 = 序列化全请求估算。
    const cold = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    try std.testing.expect(cold > 0);

    // 设锚点(模拟 message_start usage),再追加后缀。
    c.setUsageAnchor(100_000);
    try c.appendText(.assistant, "reply text");
    const anchored = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    var expected: usize = 100_000;
    expected += estimateMessageTokens(c.messages.items[1]);
    try std.testing.expectEqual(expected, anchored);
}

test "usage anchor suppresses false blocking-limit nuke (glm-5.2 并发工具风暴回归)" {
    // 实测场景(2026-07-06):glm-5.2 窗口 262144,一轮 20 个并发 Read。
    // 旧行为:纯字节估算 384K > blocking 239K → 全部 tool_result 未给模型看就清成
    // stub,模型拿 20 个空结果幻觉"已完成"。真实用量仅 ~15K/245K。
    // 新行为:usage 锚点(真实 in+cache)+ 后缀校准估算 → 远低于阈值,一个都不清。
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "read all 20 files");
    c.setUsageAnchor(13_522); // message_start 报的真实 prompt tokens

    // 20 个 tool_use + 20 个 32KB tool_result(toolResultContextBytes(262144) 截断后)。
    const tu_blocks = try a.alloc(msg.Block, 20);
    for (tu_blocks, 0..) |*b, i| {
        var idbuf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&idbuf, "t{d}", .{i});
        b.* = .{ .tool_use = .{
            .id = try a.dupe(u8, id),
            .name = try a.dupe(u8, "Read"),
            .input = try a.dupe(u8, "{\"file_path\":\"/tmp/data.txt\"}"),
        } };
    }
    try c.append(.{ .role = .assistant, .blocks = tu_blocks });
    const tr_blocks = try a.alloc(msg.Block, 20);
    for (tr_blocks, 0..) |*b, i| {
        var idbuf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&idbuf, "t{d}", .{i});
        const content = try a.alloc(u8, 32 * 1024);
        @memset(content, 'r');
        b.* = .{ .tool_result = .{
            .tool_use_id = try a.dupe(u8, id),
            .content = content,
            .is_error = false,
        } };
    }
    try c.append(.{ .role = .user, .blocks = tr_blocks });

    var provider_state = TestProviderState{
        .allocator = a,
        .max_input_tokens = 262_144, // metask /v1/models 实测值
        .max_tokens = 64_000,
    };
    const provider = testProvider(&provider_state);

    const Capture = struct {
        fn emit(_: *anyopaque, _: @import("session_id.zig").SessionId, _: CoreEvent) void {}
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var dummy: u8 = 0;
    const backend = UiBackend{ .ctx = @ptrCast(&dummy), .emit = Capture.emit, .poll = Capture.poll };

    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        null, // 阈值走窗口公式:auto=229144
        10,
        "post_tool_follow_up_threshold",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        0,
        null,
        a,
        null,
        null,
        null,
        null,
        null,
    );

    // est = 13522 + 20×(32768/4) + 信封 ≈ 178K < 229144 → 不触发;结果全部保留。
    try std.testing.expectEqual(AutoCompactOutcome.not_needed, outcome);
    for (c.messages.items[2].blocks) |b| {
        try std.testing.expect(b.tool_result.content.len == 32 * 1024); // 无一被清成 stub
    }
}

test "auto-compact preflight never rewrites an already committed tool_result" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "inspect large output");

    // 配对的 tool_use:否则 tool_result 是孤儿,P0.6 normalizeApiMessages 会剥掉它 → 巨内容不进估算。
    const tu_blocks = try a.alloc(msg.Block, 1);
    tu_blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "toolu_huge"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = tu_blocks });

    const limit = conversation_mod.toolResultContextBytes(200_000);
    const blocks = try a.alloc(msg.Block, 1);
    const huge = try a.alloc(u8, limit * 4);
    @memset(huge, 'A');
    huge[huge.len - 1] = 'Z';
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "toolu_huge"),
        .content = huge,
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blocks });

    var state = TestProviderState{};
    const provider = testProvider(&state);
    const before = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    var api_before = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api_before, a);
    const body_before = try json_mod.serializeMessagesRequest(.{
        .model = provider.model(),
        .max_tokens = provider.maxTokens(),
        .messages = api_before.items,
        .stream = true,
        .tools = &.{},
    }, a);
    defer a.free(body_before);
    const Capture = struct {
        count: u32 = 0,
        kind: ?[]const u8 = null,
        changed_items: u32 = 0,
        bytes_before: u64 = 0,
        bytes_after: u64 = 0,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .context_projection => |projection| {
                    self.count += 1;
                    self.kind = projection.kind;
                    self.changed_items = projection.changed_items;
                    self.bytes_before = projection.bytes_before;
                    self.bytes_after = projection.bytes_after;
                },
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var cap = Capture{};
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };
    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        null,
        2,
        "post_tool_follow_up_threshold",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        0,
        null,
        a,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectEqual(AutoCompactOutcome.not_needed, outcome);
    try std.testing.expectEqual(@as(u32, 0), cap.count);
    const after = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    try std.testing.expectEqual(before, after);

    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);
    const body = try json_mod.serializeMessagesRequest(.{
        .model = provider.model(),
        .max_tokens = provider.maxTokens(),
        .messages = api.items,
        .stream = true,
        .tools = &.{},
    }, a);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "toolu_huge") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Z") != null);
    try std.testing.expectEqual(Conversation.estimateTokens(body), after);
    try std.testing.expectEqualStrings(body_before, body);
}

test "auto-compact emits stale tool-result projection from the real microcompact path" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "inspect the accumulated results");

    const result_count = 14;
    const tool_uses = try a.alloc(msg.Block, result_count);
    for (tool_uses, 0..) |*block, index| {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "micro-{d}", .{index});
        block.* = .{ .tool_use = .{
            .id = try a.dupe(u8, id),
            .name = try a.dupe(u8, "Read"),
            .input = try a.dupe(u8, "{}"),
        } };
    }
    try c.append(.{ .role = .assistant, .blocks = tool_uses });

    const tool_results = try a.alloc(msg.Block, result_count);
    for (tool_results, 0..) |*block, index| {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "micro-{d}", .{index});
        const content = try a.alloc(u8, 12 * 1024);
        @memset(content, 'r');
        block.* = .{ .tool_result = .{
            .tool_use_id = try a.dupe(u8, id),
            .content = content,
            .is_error = false,
        } };
    }
    try c.append(.{ .role = .user, .blocks = tool_results });

    var provider_state = TestProviderState{
        .allocator = a,
        .max_input_tokens = 100_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);
    const base_tokens = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    const target_tokens: usize = 51_000;
    const padding_len = if (base_tokens < target_tokens)
        (target_tokens - base_tokens) * 4
    else
        0;
    const system_prompt = try a.alloc(u8, padding_len);
    defer a.free(system_prompt);
    @memset(system_prompt, 's');
    const before_tokens = try estimateNextRequestTokens(a, provider, &c, system_prompt, null, null, &.{}, null);
    const pressure = context_pressure_mod.ContextPressure.fromModel(
        provider.maxInputTokens(),
        provider.maxTokens(),
        null,
        before_tokens,
    );
    try std.testing.expect(before_tokens > pressure.warning_threshold);
    try std.testing.expect(before_tokens < pressure.auto_compact_threshold);

    const Capture = struct {
        count: u32 = 0,
        kind: ?[]const u8 = null,
        changed_items: u32 = 0,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .context_projection => |projection| {
                    self.count += 1;
                    self.kind = projection.kind;
                    self.changed_items = projection.changed_items;
                },
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var cap = Capture{};
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };
    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        system_prompt,
        null,
        null,
        &.{},
        null,
        null,
        null,
        2,
        "post_tool_follow_up_threshold",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        0,
        null,
        a,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);
    try std.testing.expectEqual(@as(u32, 1), cap.count);
    try std.testing.expectEqualStrings("stale_tool_result_microcompact", cap.kind.?);
    try std.testing.expectEqual(
        @as(u32, result_count - conversation_mod.DEFAULT_RECENT_TOOL_RESULTS_TO_KEEP),
        cap.changed_items,
    );
}

test "mid-turn follow-up auto-compact emits post-tool cause and preserves tool suffix" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    // 8192 ASCII ≈ 2048 est-token/条(校准估算 ASCII/4);30 条 ≈ 61K > 32K 阈值。
    const chunk = try a.alloc(u8, 8192);
    defer a.free(chunk);
    @memset(chunk, 'x');
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try c.appendText(.user, chunk);
    }

    const tool_use_blocks = try a.alloc(msg.Block, 1);
    tool_use_blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "t1"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{\"file_path\":\"/tmp/huge\"}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = tool_use_blocks });

    const tool_result_blocks = try a.alloc(msg.Block, 1);
    tool_result_blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "t1"),
        .content = try a.dupe(u8, "tool output"),
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = tool_result_blocks });

    var provider_state = TestProviderState{
        .allocator = a,
        .compact_summary_response = "small summary",
        .max_input_tokens = 200_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);

    const Capture = struct {
        cause: ?[]const u8 = null,
        dropped: u32 = 0,
        compact_requests: u32 = 0,
        compact_request_outcome: ?[]const u8 = null,
        compact_request_cause: ?[]const u8 = null,
        compact_begins: u32 = 0,
        compact_ends: u32 = 0,
        compact_end_outcome: ?[]const u8 = null,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .auto_compact => |ac| {
                    self.cause = ac.cause;
                    self.dropped = ac.dropped;
                },
                .diag_compact_request => |request| {
                    self.compact_requests += 1;
                    self.compact_request_outcome = request.outcome;
                    self.compact_request_cause = request.cause;
                },
                .diag_compact_begin => self.compact_begins += 1,
                .diag_compact_end => |event| {
                    self.compact_ends += 1;
                    self.compact_end_outcome = event.outcome;
                },
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var cap = Capture{};
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };

    const before_active = c.activeMessages().len;
    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        32_000,
        2,
        "post_tool_follow_up_threshold",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        0,
        null,
        a,
        null,
        null,
        null,
        null,
        null,
    );

    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);
    try std.testing.expect(cap.dropped > 0);
    try std.testing.expectEqual(@as(u32, 1), cap.compact_requests);
    try std.testing.expectEqual(@as(u32, 1), cap.compact_begins);
    try std.testing.expectEqual(@as(u32, 1), cap.compact_ends);
    try std.testing.expectEqualStrings("compacted", cap.compact_end_outcome.?);
    try std.testing.expectEqualStrings("success", cap.compact_request_outcome.?);
    try std.testing.expectEqualStrings("post_tool_follow_up_threshold", cap.compact_request_cause.?);
    // 投影:原始消息全量保留(len 不变),收缩的是活跃窗口。
    const active = c.activeMessages();
    try std.testing.expect(active.len < before_active);
    try std.testing.expectEqualStrings("post_tool_follow_up_threshold", cap.cause.?);
    // 保住工具后缀:活跃窗口末尾仍是配对的 tool_use / tool_result(不留孤儿)。
    try std.testing.expect(active[active.len - 2].blocks[0] == .tool_use);
    try std.testing.expect(active[active.len - 1].blocks[0] == .tool_result);
}

test "auto-compact does not buy a summary when fixed request overhead makes savings impossible" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "one");
    try c.appendText(.assistant, "two");
    try c.appendText(.user, "three");
    try c.appendText(.assistant, "four");

    const system_prompt = try a.alloc(u8, 160 * 1024);
    defer a.free(system_prompt);
    @memset(system_prompt, 's');
    var provider_state = TestProviderState{
        .allocator = a,
        .compact_summary_response = "summary that must not be requested",
        .max_input_tokens = 200_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);
    const Capture = struct {
        fn emit(_: *anyopaque, _: @import("session_id.zig").SessionId, _: CoreEvent) void {}
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var dummy: u8 = 0;
    const backend = UiBackend{ .ctx = @ptrCast(&dummy), .emit = Capture.emit, .poll = Capture.poll };

    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        system_prompt,
        null,
        null,
        &.{},
        null,
        null,
        32_000,
        2,
        "pre_sampling_pending_turn_threshold",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        0,
        null,
        a,
        null,
        null,
        null,
        null,
        null,
    );

    try std.testing.expectEqual(AutoCompactOutcome.skipped_no_savings, outcome);
    try std.testing.expectEqual(@as(u32, 0), provider_state.compact_request_count);
    try std.testing.expectEqual(@as(usize, 0), c.compact_boundary);
}

test "auto-compact checks runtime request gate before provider side effect" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    const chunk = try a.alloc(u8, 8192);
    defer a.free(chunk);
    @memset(chunk, 'x');
    var i: usize = 0;
    while (i < 30) : (i += 1) try c.appendText(.user, chunk);

    var provider_state = TestProviderState{
        .allocator = a,
        .compact_summary_response = "small summary",
        .max_input_tokens = 200_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);
    const Capture = struct {
        fn emit(_: *anyopaque, _: @import("session_id.zig").SessionId, _: CoreEvent) void {}
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var dummy: u8 = 0;
    const backend = UiBackend{ .ctx = @ptrCast(&dummy), .emit = Capture.emit, .poll = Capture.poll };
    const GateState = struct {
        checks: usize = 0,
        fn allows(raw: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.checks += 1;
            return false;
        }
    };
    var gate_state = GateState{};

    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        32_000,
        2,
        "pre_sampling_pending_turn_threshold",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        0,
        null,
        a,
        null,
        null,
        null,
        .{ .ctx = @ptrCast(&gate_state), .allows_fn = GateState.allows },
        null,
    );
    try std.testing.expectEqual(AutoCompactOutcome.aborted, outcome);
    try std.testing.expectEqual(@as(usize, 1), gate_state.checks);
    try std.testing.expectEqual(@as(u32, 0), provider_state.compact_request_count);
    try std.testing.expectEqual(@as(usize, 0), c.compact_boundary);
}

test "auto-compact feeds realized summary overhead back into retry preview" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    const chunk = try a.alloc(u8, 8192);
    defer a.free(chunk);
    @memset(chunk, 'x');
    var i: usize = 0;
    while (i < 30) : (i += 1) try c.appendText(.user, chunk);

    // Dropping the prefix without a summary easily clears the 5% gate, but
    // this realized summary is large enough to erase those savings. The first
    // attempt therefore supplies a measured overhead reserve; the unchanged
    // second attempt must be rejected locally without another provider call.
    const oversized_summary = try a.alloc(u8, 240 * 1024);
    defer a.free(oversized_summary);
    @memset(oversized_summary, 's');
    var provider_state = TestProviderState{
        .allocator = a,
        .compact_summary_response = oversized_summary,
        .max_input_tokens = 200_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);
    const Capture = struct {
        fn emit(_: *anyopaque, _: @import("session_id.zig").SessionId, _: CoreEvent) void {}
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var dummy: u8 = 0;
    const backend = UiBackend{ .ctx = @ptrCast(&dummy), .emit = Capture.emit, .poll = Capture.poll };
    var summary_reserve_tokens: usize = 0;

    const first = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        32_000,
        2,
        "post_tool_follow_up_threshold",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        0,
        null,
        a,
        null,
        null,
        &summary_reserve_tokens,
        null,
        null,
    );
    try std.testing.expectEqual(AutoCompactOutcome.skipped_no_savings, first);
    try std.testing.expectEqual(@as(u32, 1), provider_state.compact_request_count);
    try std.testing.expect(summary_reserve_tokens > 0);

    const second = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        32_000,
        2,
        "pre_sampling_pending_turn_threshold",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        1,
        null,
        a,
        null,
        null,
        &summary_reserve_tokens,
        null,
        null,
    );
    try std.testing.expectEqual(AutoCompactOutcome.skipped_no_savings, second);
    try std.testing.expectEqual(@as(u32, 1), provider_state.compact_request_count);
    try std.testing.expectEqual(@as(usize, 0), c.compact_boundary);
}

test "auto-compact summary carries in_progress task anchor through compaction" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    const chunk = try a.alloc(u8, 8192);
    defer a.free(chunk);
    @memset(chunk, 'x');
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try c.appendText(.user, chunk);
    }

    var store = @import("task_store.zig").TaskStore.init(a);
    defer store.deinit();
    try store.createWithId("kg-42", "修复解析器", "细节", .in_progress);
    try store.createWithId("kg-43", "已完成的不进锚", "细节", .completed);

    var provider_state = TestProviderState{
        .allocator = a,
        .compact_summary_response = "small summary",
        .max_input_tokens = 200_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);

    const Capture = struct {
        fn emit(_: *anyopaque, _: @import("session_id.zig").SessionId, _: CoreEvent) void {}
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var dummy: u8 = 0;
    const backend = UiBackend{ .ctx = @ptrCast(&dummy), .emit = Capture.emit, .poll = Capture.poll };

    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        null,
        32_000,
        2,
        "post_tool_follow_up_threshold",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        0,
        null,
        a,
        &store,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);

    // 投影:摘要存在 compact_summary(投影时作边界前一条 assistant 消息注入),不在 messages.items。
    // 里面必须带确定性任务锚(进行中任务 + 闭合指引),completed 不进锚。
    try std.testing.expect(c.compact_summary != null);
    const summ = c.compact_summary.?;
    try std.testing.expect(std.mem.indexOf(u8, summ, "compact 任务锚") != null);
    try std.testing.expect(std.mem.indexOf(u8, summ, "kg-42 修复解析器") != null);
    try std.testing.expect(std.mem.indexOf(u8, summ, "small summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, summ, "kg-43") == null); // completed 不进锚
}

test "auto-compact 触发 PreCompact + PostCompact hook(G-rest 接线,端到端)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    const chunk = try a.alloc(u8, 8192);
    defer a.free(chunk);
    @memset(chunk, 'x');
    var i: usize = 0;
    while (i < 30) : (i += 1) try c.appendText(.user, chunk);

    var provider_state = TestProviderState{ .allocator = a, .compact_summary_response = "small summary", .max_input_tokens = 200_000, .max_tokens = 32_000 };
    const provider = testProvider(&provider_state);
    const Capture = struct {
        fn emit(_: *anyopaque, _: @import("session_id.zig").SessionId, _: CoreEvent) void {}
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var dummy: u8 = 0;
    const backend = UiBackend{ .ctx = @ptrCast(&dummy), .emit = Capture.emit, .poll = Capture.poll };

    // PreCompact hook 写 marker(证明压缩前触发);PostCompact hook 回 additionalContext(模拟重注入 skill)。
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pre_marker = try std.fmt.bufPrintZ(&marker_buf, "{s}/precompact-fired.marker", .{root_buf[0..root_len]});
    const pre_cmd = try std.fmt.allocPrint(a, "touch -- {s}", .{pre_marker});
    defer a.free(pre_cmd);
    const pre_cmds = [_][]const u8{pre_cmd};
    const pre_entries = [_]hooks_mod.HookEntry{.{ .matcher = "*", .commands = &pre_cmds }};
    const post_cmds = [_][]const u8{"echo '{\"additionalContext\":\"ACTIVE_SKILL_REINJECTED\"}'"};
    const post_entries = [_]hooks_mod.HookEntry{.{ .matcher = "*", .commands = &post_cmds }};
    const hs = hooks_mod.HookSet{ .pre_tool_use = &.{}, .pre_compact = &pre_entries, .post_compact = &post_entries, .allocator = a };

    const outcome = try runAutoCompactIfNeeded(&c, provider, null, null, null, &.{}, null, null, 32_000, 2, "post_tool_follow_up_threshold", &backend, .single, [_]u8{0} ** 12, 0, 0, null, a, null, &hs, null, null, null);
    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);

    // PreCompact 真触发:marker 文件存在。
    const pre_fd = pfs.open(@ptrCast(pre_marker.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(pre_fd >= 0);
    if (pre_fd >= 0) _ = pfs.close(pre_fd);
    // PostCompact 的 additionalContext 拼进投影摘要 → 模型下轮读得到。
    try std.testing.expect(c.compact_summary != null);
    try std.testing.expect(std.mem.indexOf(u8, c.compact_summary.?, "ACTIVE_SKILL_REINJECTED") != null);
}

test "fireStopHook:顶层触发 + 传入 last_message;subagent(depth!=0)不触发(G-rest)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "do something");
    try c.appendText(.assistant, "DONE_MARKER_ANSWER");

    const marker: [:0]const u8 = "/tmp/cc_stop_hook_fired.marker";
    _ = std.c.unlink(@ptrCast(marker.ptr));
    const cmds = [_][]const u8{"cat > /tmp/cc_stop_hook_fired.marker"};
    const entries = [_]hooks_mod.HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const hs = hooks_mod.HookSet{ .pre_tool_use = &.{}, .stop = &entries, .allocator = a };

    // 顶层(depth=0)触发:hook 收到含 Stop/last_message/stop_reason 的 stdin。
    fireStopHook(&hs, a, &c, "end_turn", 0);
    {
        const fd = pfs.open(@ptrCast(marker.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        try std.testing.expect(fd >= 0);
        defer _ = pfs.close(fd);
        var buf: [1024]u8 = undefined;
        const n = pfs.read(fd, buf[0..buf.len]);
        try std.testing.expect(n > 0);
        const got = buf[0..@intCast(n)];
        try std.testing.expect(std.mem.indexOf(u8, got, "\"Stop\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "DONE_MARKER_ANSWER") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "end_turn") != null);
    }

    // 负向:subagent(depth=1)不触发(marker 删后不重现)。
    _ = std.c.unlink(@ptrCast(marker.ptr));
    fireStopHook(&hs, a, &c, "end_turn", 1);
    const fd2 = pfs.open(@ptrCast(marker.ptr), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(fd2 < 0); // 不触发 → 文件不存在
    if (fd2 >= 0) _ = pfs.close(fd2);
}

test "previous-model compact uses old model override before smaller-window sampling" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    // 8192 ASCII ≈ 2048 est-token/条;30 条 ≈ 61K > 32K 阈值(校准估算 ASCII/4)。
    const chunk = try a.alloc(u8, 8192);
    defer a.free(chunk);
    @memset(chunk, 'p');
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try c.appendText(.user, chunk);
    }

    var provider_state = TestProviderState{
        .model = "new-small-model",
        .allocator = a,
        .compact_summary_response = "small summary",
        .max_input_tokens = 80_000,
        .max_tokens = 32_000,
    };
    const provider = testProvider(&provider_state);

    const Capture = struct {
        cause: ?[]const u8 = null,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .auto_compact => |ac| self.cause = ac.cause,
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var cap = Capture{};
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };

    const outcome = try runAutoCompactIfNeeded(
        &c,
        provider,
        null,
        null,
        null,
        &.{},
        null,
        "old-large-model",
        32_000,
        2,
        "pre_sampling_previous_model_smaller_window",
        &backend,
        .single,
        [_]u8{0} ** 12,
        0,
        0,
        null,
        a,
        null,
        null,
        null,
        null,
        null,
    );

    try std.testing.expectEqual(AutoCompactOutcome.compacted, outcome);
    try std.testing.expectEqualStrings("old-large-model", provider_state.last_send_model_override.?);
    try std.testing.expectEqualStrings("pre_sampling_previous_model_smaller_window", cap.cause.?);
}

test "stream context-window recovery retries before assistant payload" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "oldest context");
    try c.appendText(.assistant, "middle context");
    try c.appendText(.user, "current request");

    const FakeStream = struct {
        allocator: std.mem.Allocator,
        attempt: u32 = 0,
        index: u32 = 0,
        rid: log.RequestId = undefined,

        fn next(ctx: *anyopaque) anyerror!?api_stream.StreamEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.attempt == 0) return error.ContextWindowExceeded;
            if (self.index == 0) {
                self.index += 1;
                return api_stream.StreamEvent{ .text = try self.allocator.dupe(u8, "ok") };
            }
            return null;
        }
        fn deinit(_: *anyopaque) void {}
        fn stop(ctx: *anyopaque) api_stream.StopReason {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return if (self.attempt == 0) .unknown else .end_turn;
        }
        fn requestId(ctx: *anyopaque) log.RequestId {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.rid;
        }
    };
    const FakeProvider = struct {
        allocator: std.mem.Allocator,
        sends: u32 = 0,
        streams: [2]FakeStream = undefined,

        fn asState(ctx: *anyopaque) *@This() {
            return @ptrCast(@alignCast(ctx));
        }
        fn model(_: *anyopaque) []const u8 {
            return "fake";
        }
        fn sendStreamRetry(ctx: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?*const AbortSignal, _: ?[]const u8, _: ?json_mod.ToolChoice, _: u32, _: u64, _: ?provider_mod.RetryReporter, _: []const u8) anyerror!provider_mod.StreamHandle {
            const st = asState(ctx);
            if (st.sends >= st.streams.len) return error.UnexpectedTestCall;
            const attempt = st.sends;
            st.streams[attempt] = .{ .allocator = st.allocator, .attempt = attempt, .rid = log.genRequestId() };
            st.sends += 1;
            return .{
                .ctx = @ptrCast(&st.streams[attempt]),
                .nextFn = FakeStream.next,
                .deinitFn = FakeStream.deinit,
                .stopReasonFn = FakeStream.stop,
                .requestIdFn = FakeStream.requestId,
            };
        }
        fn sendStream(ctx: *anyopaque, messages: []const types.ApiMessage, system: ?[]const u8, tools: ?[]const json_mod.ToolDefinition, abort: ?*const AbortSignal, model_override: ?[]const u8, tool_choice: ?json_mod.ToolChoice, user_query: []const u8) anyerror!provider_mod.StreamHandle {
            return sendStreamRetry(ctx, messages, system, tools, abort, model_override, tool_choice, 0, 0, null, user_query);
        }
        fn send(_: *anyopaque, _: []const types.ApiMessage, _: ?[]const u8, _: ?[]const json_mod.ToolDefinition, _: ?[]const u8) anyerror!provider_mod.ApiResponse {
            return error.UnexpectedTestCall;
        }
        fn maxTokens(_: *anyopaque) u32 {
            return 32_000;
        }
        fn maxInputTokens(_: *anyopaque) u32 {
            return 200_000;
        }
        fn reasoningEffort(_: *anyopaque) ?types.ReasoningEffort {
            return null;
        }
        fn supports(_: *anyopaque, _: provider_mod.Capability) bool {
            return false;
        }
        fn provider(self: *@This()) provider_mod.Provider {
            return .{
                .ctx = @ptrCast(self),
                .modelFn = model,
                .sendStreamFn = sendStream,
                .sendStreamRetryFn = sendStreamRetry,
                .sendFn = send,
                .maxTokensFn = maxTokens,
                .maxInputTokensFn = maxInputTokens,
                .reasoningEffortFn = reasoningEffort,
                .supportsFn = supports,
            };
        }
    };

    const Capture = struct {
        auto_compacts: u32 = 0,
        text: std.ArrayList(u8) = .empty,
        allocator: std.mem.Allocator,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .auto_compact => self.auto_compacts += 1,
                .text_chunk => |t| self.text.appendSlice(self.allocator, t) catch {},
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };

    var fp = FakeProvider{ .allocator = a };
    var cap = Capture{ .allocator = a };
    defer cap.text.deinit(a);
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };
    const perm = permission_mod.createContext(.bypass_permissions, a);
    const result = try run(&c, fp.provider(), &.{}, &perm, .{ .max_turns = 2, .colorize = false }, &backend, a);

    try std.testing.expectEqual(StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), fp.sends);
    try std.testing.expectEqual(@as(u32, 1), cap.auto_compacts);
    try std.testing.expectEqualStrings("ok", cap.text.items);
    // 投影:context-window recovery 推进 boundary 丢 "oldest context",不删原始。
    // 全量 = [oldest, middle, current, ok(assistant 回复)];活跃窗口从 middle 起。
    try std.testing.expectEqual(@as(usize, 4), c.len());
    try std.testing.expectEqual(@as(usize, 1), c.activeStart());
    const active = c.activeMessages();
    try std.testing.expectEqualStrings("middle context", active[0].blocks[0].text);
    try std.testing.expectEqualStrings("current request", active[1].blocks[0].text);
    // 被投影掉的 oldest 仍原样保留在头部(供 transcript/resume)。
    try std.testing.expectEqualStrings("oldest context", c.messages.items[0].blocks[0].text);
}

test "context warning emits once only at medium pressure" {
    const Capture = struct {
        warnings: u32 = 0,
        level: ?[]const u8 = null,
        current_tokens: u64 = 0,
        fn emit(ctx: *anyopaque, _: @import("session_id.zig").SessionId, ev: CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .context_warning => |w| {
                    self.warnings += 1;
                    self.level = w.level;
                    self.current_tokens = w.current_tokens;
                },
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: @import("session_id.zig").SessionId) ?@import("protocol/ui_event.zig").UiEvent {
            return null;
        }
    };
    var cap = Capture{};
    const backend = UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };
    var emitted = false;

    emitContextWarningIfNeeded(&backend, .single, context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 147_999), &emitted);
    try std.testing.expectEqual(@as(u32, 0), cap.warnings);
    try std.testing.expect(!emitted);

    emitContextWarningIfNeeded(&backend, .single, context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 148_000), &emitted);
    try std.testing.expectEqual(@as(u32, 1), cap.warnings);
    try std.testing.expect(emitted);
    try std.testing.expectEqualStrings("medium", cap.level.?);
    try std.testing.expectEqual(@as(u64, 148_000), cap.current_tokens);

    emitContextWarningIfNeeded(&backend, .single, context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 152_000), &emitted);
    try std.testing.expectEqual(@as(u32, 1), cap.warnings);

    emitted = false;
    emitContextWarningIfNeeded(&backend, .single, context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 155_000), &emitted);
    try std.testing.expectEqual(@as(u32, 1), cap.warnings);
    try std.testing.expect(!emitted);
}

test "auto-compact preflight keeps serialized request valid UTF-8 after multibyte truncation" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();

    const limit = conversation_mod.toolResultContextBytes(0);
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(a);
    while (payload.items.len < limit * 3) {
        try payload.appendSlice(a, "路径/中文/🙂/");
    }

    // 配对 tool_use:否则 tool_result 是孤儿,normalizeApiMessages 会剥掉 → body 里就没有它。
    const tu_blocks = try a.alloc(msg.Block, 1);
    tu_blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "toolu_utf8"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try c.append(.{ .role = .assistant, .blocks = tu_blocks });

    const blocks = try a.alloc(msg.Block, 1);
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, "toolu_utf8"),
        .content = try a.dupe(u8, payload.items),
        .is_error = false,
    } };
    try c.append(.{ .role = .user, .blocks = blocks });

    const reduced = c.truncateLargeToolResults(limit);
    try std.testing.expectEqual(@as(usize, 1), reduced.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c.messages.items[1].blocks[0].tool_result.content));

    var state = TestProviderState{};
    const provider = testProvider(&state);
    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);
    const body = try json_mod.serializeMessagesRequest(.{
        .model = provider.model(),
        .max_tokens = provider.maxTokens(),
        .messages = api.items,
        .stream = true,
        .tools = &.{},
    }, a);
    defer a.free(body);
    try std.testing.expect(std.unicode.utf8ValidateSlice(body));
    try std.testing.expect(std.mem.indexOf(u8, body, "original_bytes") != null);
}

test "buildEffectiveToolSet hides unactivated deferred tools for compact estimate" {
    const a = std.testing.allocator;
    const tool_defs = [_]json_mod.ToolDefinition{
        .{
            .name = "Read",
            .description = "Read file contents",
            .input_schema = .{ .prop_specs = &.{.{ .name = "file_path", .type = "string" }}, .required = &.{"file_path"} },
        },
        .{
            .name = "DeferredHuge",
            .description = "This deferred schema should not affect the next request estimate until activated.",
            .input_schema = .{ .prop_specs = &.{.{ .name = "payload", .type = "string", .description = "large hidden payload" }}, .required = &.{"payload"} },
            .deferred = true,
        },
    };
    var activated = std.StringHashMap(void).init(a);
    defer activated.deinit();
    var permission_ctx = permission_mod.PermissionContext{ .allocator = a };
    var state = TestProviderState{};
    var effective = try buildEffectiveToolSet(
        a,
        &tool_defs,
        &permission_ctx,
        &activated,
        null,
        testProvider(&state),
    );
    defer effective.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), effective.defs.len);
    try std.testing.expectEqualStrings("Read", effective.defs[0].name);
}

test "buildEffectiveToolSet applies an execution policy before provider exposure" {
    const Policy = struct {
        fn allowsTool(_: *const anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "Read");
        }
        fn allowsInvocation(
            _: *const anyopaque,
            name: []const u8,
            _: []const u8,
        ) bool {
            return std.mem.eql(u8, name, "Read");
        }
        var sentinel: u8 = 0;
    };
    const tool_defs = [_]json_mod.ToolDefinition{
        .{ .name = "Read", .description = "read", .input_schema = .{} },
        .{ .name = "Write", .description = "write", .input_schema = .{} },
    };
    var permission_ctx = permission_mod.PermissionContext{
        .allocator = std.testing.allocator,
    };
    var provider_state = TestProviderState{};
    var effective = try buildEffectiveToolSet(
        std.testing.allocator,
        &tool_defs,
        &permission_ctx,
        null,
        .{
            .ctx = @ptrCast(&Policy.sentinel),
            .allowsToolFn = Policy.allowsTool,
            .allowsInvocationFn = Policy.allowsInvocation,
        },
        testProvider(&provider_state),
    );
    defer effective.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), effective.defs.len);
    try std.testing.expectEqualStrings("Read", effective.defs[0].name);
}

test "StopReason has aborted and max_turns" {
    // 编译时保证 stop_reason 含新枚举值
    const r: StopReason = .aborted;
    try std.testing.expect(r == .aborted);
    const r2: StopReason = .max_turns;
    try std.testing.expect(r2 == .max_turns);
}

test "auto-compact 阈值用 input context window 而非 output max_tokens(防回归真机 bug)" {
    // 真机 bug:阈值曾用 output max_tokens(sonnet 默认 32K)*0.7 → 工具调研刚读几个文件就误触发
    // 压缩、丢掉原始问题。修复:改用 input context window(~200K)扣 output reserve 后的 CC/Rust 阈值。
    // 源级守卫:阈值算式必须调 resolveMaxInputTokens(而非 output 的解析器),且 MIN 不再是早期小值。
    const src = @embedFile("agent_loop.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "ContextPressure.fromModel(provider.maxInputTokens(), provider.maxTokens()") != null);
    // 全额输出预留(服务端校验 in+max_tokens ≤ window):200K-32K-13K = 155K。
    try std.testing.expectEqual(@as(usize, 155_000), context_pressure_mod.ContextPressure.fromModel(200_000, 32_000, null, 0).auto_compact_threshold);
    try std.testing.expect(MIN_AUTO_COMPACT_THRESHOLD >= 32_000);
}

test "微压缩两趟都接线:clear 与 truncate 必须同时在生产路径上" {
    // 回归守卫:`truncateLargeToolResults` 曾经零生产调用者——全仓每一个调用点
    // 都在 test 块内,而下面这条日志行一直打印 `truncated={d}`,该字段结构性
    // 恒为 0。projection 只在结果**提交那一刻**限界且从不重投影历史,所以
    // /resume 载入的历史、或切到更小窗口的模型,其超限结果没有任何一层管得到。
    // 两个压力阀点都必须按 provider 窗口派生的同一预算跑截断趟。
    const src = @embedFile("agent_loop.zig");
    const wiring = "reduced.merge(conversation.truncateLargeToolResults(\n            conversation_mod.toolResultContextBytes(provider.maxInputTokens()),\n        ));";
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, src, cursor, wiring)) |at| {
        count += 1;
        cursor = at + wiring.len;
    }
    // 一处在 micro 阈值带,一处在 blocking-limit 恢复。
    try std.testing.expectEqual(@as(usize, 2), count);
    // 且预算必须与 projection 的 per_result_bytes 同源,不能各自造常量。
    try std.testing.expect(std.mem.indexOf(u8, src, "conversation_mod.toolResultContextBytes(provider.maxInputTokens())") != null);
}

test "parseForcedAutoCompactThreshold: 合法强制值 + 坏值回退 null" {
    // 合法:e2e 用它在短对话直接钉低阈值触发真实压缩+投影。
    try std.testing.expectEqual(@as(?usize, 3000), parseForcedAutoCompactThreshold("3000"));
    // 空 / 0 / 非法 → null(坏 env 绝不改压缩行为)。
    try std.testing.expectEqual(@as(?usize, null), parseForcedAutoCompactThreshold(""));
    try std.testing.expectEqual(@as(?usize, null), parseForcedAutoCompactThreshold("0"));
    try std.testing.expectEqual(@as(?usize, null), parseForcedAutoCompactThreshold("garbage"));
    // 无 env 时 getenv 返回 null → 走正常 formula+floor(wiring 由真模型 e2e 验证)。
}

test "估算投影:image 按 IMAGE_TOKEN_ESTIMATE 计,不按 base64 字节(防爆表/误 compact)" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    // 800KB 伪 base64:按旧字节估算 ≈ 20 万 token;按投影应只计 IMAGE_TOKEN_ESTIMATE。
    const big = try a.alloc(u8, 800_000);
    @memset(big, 'A');
    const blocks = try a.alloc(msg.Block, 2);
    blocks[0] = .{ .text = try a.dupe(u8, "看图") };
    blocks[1] = .{ .image = .{ .media_type = try a.dupe(u8, "image/png"), .data = big } };
    try c.append(.{ .role = .user, .blocks = blocks });

    // model 用非 claude 名:投影后估算序列化不再触发 vision 守门(此前会 error 落 fallback)。
    var state = TestProviderState{ .model = "gpt-4o", .max_tokens = 777, .reasoning_effort = null };
    const provider = testProvider(&state);
    const estimated = try estimateNextRequestTokens(a, provider, &c, null, null, null, &.{}, null);
    try std.testing.expect(estimated >= conversation_mod.IMAGE_TOKEN_ESTIMATE);
    try std.testing.expect(estimated < 50_000); // 远小于按字节计的 ~20 万

    // request_gate 的 input 预留同理:不因图爆表,也不因非 vision 模型报错(此前
    // catch maxInt → 预算门必拒)。
    var api = try buildApiMessages(&c, a, null, null);
    defer freeApiMessages(&api, a);
    const reserve = try serializedRequestInputTokenReserve(a, provider, api.items, null, &.{}, null);
    try std.testing.expect(reserve < 100_000);
    try std.testing.expect(reserve >= 2 * @as(u64, conversation_mod.IMAGE_TOKEN_ESTIMATE));
}

test "projectPayloadsForEstimation: 无载荷返 null(零拷贝),有图/有文档替换占位并计数" {
    const a = std.testing.allocator;
    const text_only = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    try std.testing.expect((try projectPayloadsForEstimation(a, &text_only)) == null);

    const mixed = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .text = "a" },
            .{ .image = .{ .media_type = "image/png", .data = "XXXX" } },
            .{ .image = .{ .media_type = "image/jpeg", .data = "YYYY" } },
        } },
    };
    const proj = (try projectPayloadsForEstimation(a, &mixed)).?;
    defer proj.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), proj.image_count);
    try std.testing.expectEqualStrings("a", proj.messages[0].content[0].text);
    try std.testing.expectEqualStrings("[image]", proj.messages[0].content[1].text);
    try std.testing.expectEqualStrings("[image]", proj.messages[0].content[2].text);
    try std.testing.expectEqual(@as(usize, 0), proj.document_tokens);
}

test "projectPayloadsForEstimation: 文档按页计,不按 base64 字节(12MB PDF 不爆表)" {
    const a = std.testing.allocator;
    // 4 MB 伪 base64:按字节估算 ≈ 100 万 token,按页估算是 3 页 × 3000。
    const payload = try a.alloc(u8, 4 * 1024 * 1024);
    defer a.free(payload);
    @memset(payload, 'A');
    const contents = [_]types.ApiContent{
        .{ .text = "summarize" },
        .{ .document = .{
            .media_type = "application/pdf",
            .data = payload,
            .title = "report.pdf",
            .pages = 3,
        } },
    };
    const messages = [_]types.ApiMessage{.{ .role = .user, .content = &contents }};
    const proj = (try projectPayloadsForEstimation(a, &messages)).?;
    defer proj.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), proj.image_count);
    try std.testing.expectEqual(@as(usize, 3 * pdf_mod.PAGE_TOKEN_ESTIMATE), proj.document_tokens);
    try std.testing.expectEqualStrings("[document]", proj.messages[0].content[1].text);

    // 端到端:非 claude 命名的模型也能算出来(canonical 投影不重放能力守门),
    // 且结果远低于"按 base64 字节"的百万级。
    var state = TestProviderState{ .model = "gpt-4o", .max_tokens = 777, .reasoning_effort = null };
    const provider = testProvider(&state);
    const estimated = try estimateApiRequestTokens(a, provider, &messages, null, &.{}, null);
    try std.testing.expect(estimated > 3 * pdf_mod.PAGE_TOKEN_ESTIMATE);
    try std.testing.expect(estimated < 50_000);
}

test "估算投影覆盖 tool_result 图像形态(Read 截图不爆表)" {
    const a = std.testing.allocator;
    // Read 工具图像形态 tool_result:800KB 伪 base64。
    const big = try a.alloc(u8, 800_000);
    defer a.free(big);
    @memset(big, 'A');
    const tr_content = try std.fmt.allocPrint(a, "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}", .{big});
    defer a.free(tr_content);

    const contents = [_]types.ApiContent{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = tr_content } },
    };
    const messages = [_]types.ApiMessage{.{ .role = .user, .content = &contents }};
    const proj = (try projectPayloadsForEstimation(a, &messages)).?;
    defer proj.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), proj.image_count);
    try std.testing.expectEqualStrings("[image tool result]", proj.messages[0].content[0].tool_result.content);
    try std.testing.expectEqualStrings("t1", proj.messages[0].content[0].tool_result.tool_use_id);

    // 端到端:估算不按 base64 字节计。
    var state = TestProviderState{ .model = "gpt-4o", .max_tokens = 777, .reasoning_effort = null };
    const provider = testProvider(&state);
    const estimated = try estimateApiRequestTokens(a, provider, &messages, null, &.{}, null);
    try std.testing.expect(estimated < 50_000);
}

test "canonical 请求身份:非 claude vision 模型带图可算,图内容参与身份" {
    // 此前经 Anthropic 序列化器直算 → gpt-4o 带图报 ImageInputUnsupported,
    // execution-boundary 会话 run 直接 .api_error(review 轮修复,此测试锁定)。
    const a = std.testing.allocator;
    var state = TestProviderState{ .model = "gpt-4o", .max_tokens = 777, .reasoning_effort = null };
    const provider = testProvider(&state);

    const c1 = [_]types.ApiContent{
        .{ .text = "look" },
        .{ .image = .{ .media_type = "image/png", .data = "AAAA" } },
    };
    const m1 = [_]types.ApiMessage{.{ .role = .user, .content = &c1 }};
    const h1 = try canonicalAgentRequestSha256(a, provider, &m1, null, &.{}, null);

    // 图内容变 → 身份变(占位投影不丢失图像身份)。
    const c2 = [_]types.ApiContent{
        .{ .text = "look" },
        .{ .image = .{ .media_type = "image/png", .data = "BBBB" } },
    };
    const m2 = [_]types.ApiMessage{.{ .role = .user, .content = &c2 }};
    const h2 = try canonicalAgentRequestSha256(a, provider, &m2, null, &.{}, null);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));

    // 同输入 → 同身份(确定性)。
    const h1_again = try canonicalAgentRequestSha256(a, provider, &m1, null, &.{}, null);
    try std.testing.expectEqualStrings(&h1, &h1_again);
}

test "usage-anchor 热路径:Read 图像 tool_result 增量按 IMAGE_TOKEN_ESTIMATE 计" {
    // 锚点后缀里一条 5MB 级图像 tool_result 若按字节/4 计 → anchor+~125 万,
    // maybeAutoCompact 每图强制一次有损 compact(review 轮修复,此测试锁定)。
    const a = std.testing.allocator;
    const big = try a.alloc(u8, 400_000);
    defer a.free(big);
    @memset(big, 'A');
    const tr_content = try std.fmt.allocPrint(a, "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}", .{big});
    defer a.free(tr_content);
    const blocks = [_]msg.Block{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = tr_content } },
    };
    const m = msg.Message{ .role = .user, .blocks = @constCast(&blocks) };
    const total = estimateMessageTokens(m);
    try std.testing.expect(total >= conversation_mod.IMAGE_TOKEN_ESTIMATE);
    try std.testing.expect(total < 50_000);
}
