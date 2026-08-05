//! Subagent：父 agent 启动的子 agent 实例。
//!
//! 设计：
//! - 独立 Conversation（起点为空 + system prompt）
//! - 共享：api provider、tool_defs、permission_ctx、abort
//! - KG：从父客户端克隆 child-owned 实例，隔离 allocator/cache/detail/abort
//! - 有自己的 max_turns 上限（默认 20，避免子 agent 失控）
//! - 返回：final text（assistant 最后的文本）+ stop_reason + tool_calls 次数
//!
//! 父 agent 通过一个内建 "Task" 工具调起 subagent（M6.2 暂不实现 Task tool——只
//! 提供 spawn API 供未来调用）。

const std = @import("std");
const client_mod = @import("../client.zig");
const provider_mod = @import("../api/provider.zig");
const json_mod = @import("../json.zig");
const permission_mod = @import("../permission.zig");
const agent_loop = @import("agent_loop.zig");
const writer_backend = @import("writer_backend.zig");
const ui_backend = @import("protocol/ui_backend.zig");
const Conversation = @import("conversation.zig").Conversation;
const msg = @import("message.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const TaskStore = @import("task_store.zig").TaskStore;
const SessionId = @import("session_id.zig").SessionId;

pub const SubagentResult = struct {
    allocator: std.mem.Allocator,
    final_text: []u8, // owned
    stop_reason: agent_loop.StopReason,
    turns: u32,
    tool_calls: u32,
    /// subagent 在其**独立** TaskStore 里创建的任务数。用途:① 可观测性(主 agent/UI
    /// 可知 subagent 内部规划了几个子任务);② 接线回归——若 subagent 的 ctx.tasks 没接上
    /// (tasks=null),TaskCreate 全失败,此值恒 0。非零证明 task store 真接通了。
    subagent_tasks_created: u32 = 0,

    pub fn deinit(self: SubagentResult) void {
        self.allocator.free(self.final_text);
    }
};

pub const SpawnOptions = struct {
    max_turns: u32 = 20,
    system_prompt: ?[]const u8 = null,
    /// UI/event routing identity. It is deliberately separate from
    /// `agent_ident`, which remains the child's coordination identity.
    session: @import("session_id.zig").SessionId = .single,
    /// 嵌套深度。Agent 工具 spawn 时传 parent_depth+1。
    agent_depth: u8 = 1,
    /// 父 agent 的 dyn_registry，子 agent 共享同一套 Skill/MCP 工具。
    dyn_registry: ?*const @import("../tools/dynamic.zig").DynRegistry = null,
    /// 子 agent 可见的工具白名单(空 = 继承父全部)。已经应用永久禁用集 + def 过滤。
    /// 注意:此处覆盖 tool_defs 参数本身;子 agent_loop 用这个 tool_defs 跑。
    tool_defs_override: ?[]const json_mod.ToolDefinition = null,
    /// per-spawn permission mode 覆盖。null = 沿用父 permission_ctx。
    permission_mode_override: ?@import("../types.zig").PermissionMode = null,
    /// per-spawn model 覆盖(用 AgentDef.model 解析后的具体 model 名;"inherit" 父端
    /// 自己已经解析过,这里只接受具体 model 名或 null)。
    model_override: ?[]const u8 = null,
    /// AgentDef.effort override。Anthropic client 在本 isolated run 期间临时覆盖，结束恢复。
    reasoning_effort_override: ?@import("../types.zig").ReasoningEffort = null,
    /// 父 dispatch 传过来的宿主能力(L5)。subagent 通常只用 skill 激活(调用方传 skillOnly 投影);
    /// 见 HostServices.skillOnly。
    host_services: ?@import("../tools/context.zig").HostServices = null,
    /// Optional Session-owned dispatch and immutable execution bound.
    tool_dispatcher: ?@import("../tools/context.zig").ToolDispatcher = null,
    execution_policy: ?@import("../tools/context.zig").ToolExecutionPolicy = null,
    host_run: ?@import("../tools/context.zig").HostRunIdentity = null,
    ui_requester: ?@import("protocol/ui_request.zig").UiRequester = null,
    read_state: ?*@import("read_state.zig").ReadState = null,
    jobs: ?*@import("job_registry.zig").JobRegistry = null,
    /// Explicit raw-event capture for AgentCore fork children. The facade's
    /// private projector performs public filtering. The default retains the
    /// existing CLI/headless behavior.
    event_projection: agent_loop.EventProjection = .legacy,
    project_dir: []const u8 = "",
    /// 后台 subagent registry(允许嵌套后台:子 agent 也能 Task(run_in_background)注册进同一 root)。
    /// null = 子 agent 不能再开后台(同步路径恒 null)。
    agent_jobs: ?*@import("agent_job_registry.zig").AgentJobRegistry = null,
    /// KG 能力来源。spawnAgentSink 会克隆 child-owned 客户端再传给 agent_loop；
    /// 父子不共享 allocator/cache/detail/abort。null = 子 agent 无图。
    kg: ?*@import("../kg/client.zig").KgClient = null,
    kg_projects_dir: []const u8 = "",
    /// 本 subagent loop 的对外身份(KG claim 租约)。null = spawn 时自动 gen 一个
    /// 全局唯一 id——**身份由程序赋予**,每个独立 agent loop 一个,进程内并发 subagent
    /// 互相防撞、跨进程靠 gen()(ms 时戳+monotonic ns)天然不撞。
    /// Ctrl+B 主对话转后台续跑若需延续主 session 的租约,显式传父 id。
    agent_ident: ?@import("session_id.zig").SessionId = null,
    /// 预建对话(Ctrl+B 主对话转后台用):非 null 时 spawnAgentSink **用它续跑**(忽略 prompt 参数),
    /// 而非从空 conversation + appendText(prompt) 起。**所有权转移给 spawnAgentSink**(它 defer deinit)。
    /// 普通 subagent 恒 null(从 prompt 起新对话)。
    prebuilt_conversation: ?Conversation = null,
    /// **Sandbox 透传(task#12,安全)**:subagent 的 Bash 必须继承父的 sandbox,否则 subagent 成为
    /// 绕过用户 sandbox 配置的后门。调用方(agent_tool)从 ctx.sandbox/cwd_abs/home_dir/additional_dirs 传入。
    /// 默认 null/空 = 无 sandbox(与 agent_loop.Options 默认一致)。
    sandbox: ?*const @import("../sandbox/config.zig").SandboxSettings = null,
    cwd_abs: []const u8 = "",
    resolve_relative_paths: bool = false,
    home_dir: []const u8 = "",
    additional_dirs: []const []const u8 = &.{},
    /// AgentDef.mcpServers 过滤后的 session 视图。
    mcp_sessions: ?*const []@import("mcp_session.zig").McpSessionEntry = null,
};

pub fn spawnAgent(
    allocator: std.mem.Allocator,
    prov: provider_mod.Provider, // P0.5:中立 Provider 驱动子 loop(不再必须 Anthropic 具体 client)
    anthropic_client: ?*client_mod.Client, // 供子 ctx.api_client(web_search 是 Anthropic server tool);非 Anthropic provider → null
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    abort: ?*const AbortSignal,
    prompt: []const u8,
    opts: SpawnOptions,
) !SubagentResult {
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    return spawnAgentSink(allocator, prov, anthropic_client, tool_defs, permission_ctx, abort, prompt, opts, &be);
}

/// 与 spawnAgent 相同,但允许注入一个 UiBackend(后台 job 用 WriterBackend 把流式
/// text 导进可查询缓冲;同步路径用 null backend,行为不变)。
pub fn spawnAgentSink(
    allocator: std.mem.Allocator,
    prov: provider_mod.Provider, // 中立 Provider 驱动子 loop
    anthropic_client: ?*client_mod.Client, // 子 ctx.api_client(web_search 用;非 Anthropic → null)
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    abort: ?*const AbortSignal,
    prompt: []const u8,
    opts: SpawnOptions,
    backend: *const ui_backend.UiBackend,
) !SubagentResult {
    // Effort is a Provider capability, not an Anthropic implementation detail. Restore the
    // previous value so a scoped AgentDef override never leaks into its parent session.
    const saved_effort = prov.reasoningEffort();
    if (opts.reasoning_effort_override) |effort| {
        try prov.setReasoningEffort(effort);
    }
    defer if (opts.reasoning_effort_override != null) {
        prov.setReasoningEffort(saved_effort) catch unreachable;
    };

    // 预建对话(Ctrl+B 转后台续跑)→ 用它(所有权转移,本函数 defer deinit);否则从 prompt 起新对话。
    var conv = if (opts.prebuilt_conversation) |pc| pc else blk: {
        var c = Conversation.init(allocator);
        errdefer c.deinit();
        try c.appendText(.user, prompt);
        break :blk c;
    };
    defer conv.deinit();

    // 选择实际用的 tool_defs:override > 父
    const effective_tool_defs = opts.tool_defs_override orelse tool_defs;

    // 选择实际用的 permission_ctx。U4:override 走 scopedDerive 单 seam(值拷贝+null sink,
    // scoped 的 mode override 绝不 emit 到 session sink)。无 override 用父 ctx 指针(pointer-share,
    // 见 U4 裁定 task#15)。
    var ctx_override: permission_mod.PermissionContext = permission_ctx.scopedDerive(opts.permission_mode_override);
    const ctx_to_use: *const permission_mod.PermissionContext = if (opts.permission_mode_override != null) &ctx_override else permission_ctx;

    // subagent 是隔离上下文:给它**自己的** TaskStore。早先未挂 store(opts 无 tasks 字段)→
    // subagent 调 TaskCreate 时 requireStore 返 TaskStoreUnavailable → 第一轮多个 TaskCreate
    // 全失败同错 → 熔断器(单轮内累计)turns=1 就 tool_loop 中止,subagent 啥也没干。
    // 用独立 store 而非共享父 store:① 后台 subagent 跑在独立线程,TaskStore 无 mutex 非线程
    // 安全,共享会数据竞争;② 隔离语义——subagent 的任务清单不该混进主对话的 todo。
    var sub_tasks = TaskStore.init(allocator);
    defer sub_tasks.deinit();

    // 每个独立 agent loop 必须 own 自己的 KgClient。KgClient 的 allocator、缓存与 abort
    // 都是 session-local 状态；把父指针直接透传会让并发 child 互相覆盖取消信号，且可能在
    // 不同 allocator 间 alloc/free。clone 失败是 spawn 失败，不能静默把已广告的 KG 工具
    // 变成“未配置”；版本/环境不就绪则保留 degraded clone，让工具返回结构化原因。
    var child_kg: ?@import("../kg/client.zig").KgClient = null;
    if (opts.kg) |parent_kg| {
        child_kg = try parent_kg.cloneForThread(allocator, opts.home_dir);
        child_kg.?.ensureReady();
    }
    defer if (child_kg) |*kg| kg.deinit();
    const child_kg_ptr: ?*@import("../kg/client.zig").KgClient = if (child_kg) |*kg| kg else null;

    const result = try agent_loop.run(
        &conv,
        prov,
        effective_tool_defs,
        ctx_to_use,
        .{
            .max_turns = opts.max_turns,
            .system_prompt = opts.system_prompt,
            .session = opts.session,
            .abort = abort,
            .api_client = anthropic_client,
            .tool_defs = effective_tool_defs,
            .agent_depth = opts.agent_depth,
            .dyn_registry = opts.dyn_registry,
            .tool_dispatcher = opts.tool_dispatcher,
            .execution_policy = opts.execution_policy,
            .host_services = opts.host_services,
            .host_run = opts.host_run,
            .ui_requester = opts.ui_requester,
            .read_state = opts.read_state,
            .jobs = opts.jobs,
            .agent_jobs = opts.agent_jobs,
            .project_dir = opts.project_dir,
            .session_id = opts.session.asSlice(),
            .model_override = opts.model_override,
            .tasks = &sub_tasks,
            .kg = child_kg_ptr,
            .kg_projects_dir = opts.kg_projects_dir,
            // 每个 subagent loop 一个程序生成的全局唯一对外身份(claim 租约)。
            .agent_ident = opts.agent_ident orelse @import("session_id.zig").gen(),
            // 后台 subagent 不应往父 stdout 喷 ANSI 着色(final_text/output 会混入 \x1b[32m)。
            // sink 是 NullWriter(同步)或 SinkWriter(后台)时都非交互终端 → 关着色。
            .colorize = false,
            .event_projection = opts.event_projection,
            // task#12:sandbox 透传——subagent Bash 继承父 sandbox(否则绕过用户配置的后门)。
            .sandbox = opts.sandbox,
            .cwd_abs = opts.cwd_abs,
            .resolve_relative_paths = opts.resolve_relative_paths,
            .home_dir = opts.home_dir,
            .additional_dirs = opts.additional_dirs,
            .mcp_sessions = opts.mcp_sessions,
        },
        backend,
        allocator,
    );

    // 提取最后一条 assistant 消息的 text block 拼接
    var final = std.ArrayList(u8).empty;
    errdefer final.deinit(allocator);

    for (conv.messages.items) |m| {
        if (m.role != .assistant) continue;
        for (m.blocks) |b| switch (b) {
            .text => |t| try final.appendSlice(allocator, t),
            else => {},
        };
    }

    return .{
        .allocator = allocator,
        .final_text = try final.toOwnedSlice(allocator),
        .stop_reason = result.stop_reason,
        .turns = result.turns,
        .tool_calls = result.tool_calls,
        .subagent_tasks_created = @intCast(sub_tasks.tasks.items.len),
    };
}

// ============================================================================
// Tests（纯签名/接口测试——真 API 调用需要集成）
// ============================================================================

const testing = std.testing;

test "SubagentResult roundtrip allocation" {
    const r = SubagentResult{
        .allocator = testing.allocator,
        .final_text = try testing.allocator.dupe(u8, "test"),
        .stop_reason = .end_turn,
        .turns = 1,
        .tool_calls = 0,
    };
    defer r.deinit();
    try testing.expectEqualStrings("test", r.final_text);
}

test "SpawnOptions defaults" {
    const o = SpawnOptions{};
    try testing.expect(o.max_turns == 20);
    try testing.expect(o.system_prompt == null);
    try testing.expectEqualSlices(u8, SessionId.single.asSlice(), o.session.asSlice());
    try testing.expect(o.event_projection == .legacy);
    try testing.expect(o.execution_policy == null);
    try testing.expect(o.tool_dispatcher == null);
}
