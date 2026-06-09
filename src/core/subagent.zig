//! Subagent：父 agent 启动的子 agent 实例。
//!
//! 设计：
//! - 独立 Conversation（起点为空 + system prompt）
//! - 共享：api_client、tool_defs、permission_ctx、abort
//! - 有自己的 max_turns 上限（默认 20，避免子 agent 失控）
//! - 返回：final text（assistant 最后的文本）+ stop_reason + tool_calls 次数
//!
//! 父 agent 通过一个内建 "Task" 工具调起 subagent（M6.2 暂不实现 Task tool——只
//! 提供 spawn API 供未来调用）。

const std = @import("std");
const client_mod = @import("../client.zig");
const json_mod = @import("../json.zig");
const permission_mod = @import("../permission.zig");
const agent_loop = @import("agent_loop.zig");
const writer_backend = @import("writer_backend.zig");
const ui_backend = @import("protocol/ui_backend.zig");
const Conversation = @import("conversation.zig").Conversation;
const msg = @import("message.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const TaskStore = @import("task_store.zig").TaskStore;

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
    /// 父 dispatch 传过来的回调,subagent 同样需要 Skill 工具激活权限态等。
    skill_activator: ?@import("../tools/context.zig").SkillActivator = null,
    project_dir: []const u8 = "",
    /// 后台 subagent registry(允许嵌套后台:子 agent 也能 Task(run_in_background)注册进同一 root)。
    /// null = 子 agent 不能再开后台(同步路径恒 null)。
    agent_jobs: ?*@import("agent_job_registry.zig").AgentJobRegistry = null,
    /// 实时进度回调(后台 job 传自己的 JobEntry trampoline;同步路径 null)。
    progress_reporter: ?agent_loop.ProgressReporter = null,
    /// usage 回写(后台/前台 job 把 token 数喂进 JobEntry.tokens,供进度树 `· X tokens`)。
    /// null = 不统计(同步无 registry 路径)。透传给 agent_loop.Options.usage_sink。
    usage_sink: ?agent_loop.UsageSink = null,
};

pub fn spawnAgent(
    allocator: std.mem.Allocator,
    api_client: *client_mod.Client,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    abort: ?*const AbortSignal,
    prompt: []const u8,
    opts: SpawnOptions,
) !SubagentResult {
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    return spawnAgentSink(allocator, api_client, tool_defs, permission_ctx, abort, prompt, opts, &be);
}

/// 与 spawnAgent 相同,但允许注入一个 UiBackend(后台 job 用 WriterBackend 把流式
/// text 导进可查询缓冲;同步路径用 null backend,行为不变)。
pub fn spawnAgentSink(
    allocator: std.mem.Allocator,
    api_client: *client_mod.Client,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    abort: ?*const AbortSignal,
    prompt: []const u8,
    opts: SpawnOptions,
    backend: *const ui_backend.UiBackend,
) !SubagentResult {
    var conv = Conversation.init(allocator);
    defer conv.deinit();

    try conv.appendText(.user, prompt);

    // 选择实际用的 tool_defs:override > 父
    const effective_tool_defs = opts.tool_defs_override orelse tool_defs;

    // 选择实际用的 permission_ctx
    var ctx_override: permission_mod.PermissionContext = permission_ctx.*;
    if (opts.permission_mode_override) |m| ctx_override.setMode(m);
    const ctx_to_use: *const permission_mod.PermissionContext = if (opts.permission_mode_override != null) &ctx_override else permission_ctx;

    // subagent 是隔离上下文:给它**自己的** TaskStore。早先未挂 store(opts 无 tasks 字段)→
    // subagent 调 TaskCreate 时 requireStore 返 TaskStoreUnavailable → 第一轮多个 TaskCreate
    // 全失败同错 → 熔断器(单轮内累计)turns=1 就 tool_loop 中止,subagent 啥也没干。
    // 用独立 store 而非共享父 store:① 后台 subagent 跑在独立线程,TaskStore 无 mutex 非线程
    // 安全,共享会数据竞争;② 隔离语义——subagent 的任务清单不该混进主对话的 todo。
    var sub_tasks = TaskStore.init(allocator);
    defer sub_tasks.deinit();

    const result = try agent_loop.run(
        &conv,
        api_client,
        effective_tool_defs,
        ctx_to_use,
        .{
            .max_turns = opts.max_turns,
            .system_prompt = opts.system_prompt,
            .abort = abort,
            .api_client = api_client,
            .tool_defs = effective_tool_defs,
            .agent_depth = opts.agent_depth,
            .dyn_registry = opts.dyn_registry,
            .skill_activator = opts.skill_activator,
            .agent_jobs = opts.agent_jobs,
            .project_dir = opts.project_dir,
            .model_override = opts.model_override,
            .tasks = &sub_tasks,
            // 后台 subagent 不应往父 stdout 喷 ANSI 着色(final_text/output 会混入 \x1b[32m)。
            // sink 是 NullWriter(同步)或 SinkWriter(后台)时都非交互终端 → 关着色。
            .colorize = false,
            .progress_reporter = opts.progress_reporter,
            .usage_sink = opts.usage_sink,
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
}
