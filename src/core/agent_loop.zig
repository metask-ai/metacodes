//! Agent 主循环：user → API stream → tool_use(s) → tool_result(s) → API stream → ...
//!
//! M0.5 把 main.zig 的 runRepl 里嵌在 while 里的业务逻辑抽到这里。
//! M1.5 加入 AbortSignal 检查点：每轮开头、每 stream 事件前检查，触发时返回 .aborted。
//!
//! 核心：用 Conversation 的 Block tagged union 正确保存 tool_use / tool_result，
//! 不再像旧版那样把所有东西扁平化成 text。

const std = @import("std");
const types = @import("../types.zig");
const client_mod = @import("../client.zig");
const json_mod = @import("../json.zig");
const tools_mod = @import("../tools.zig");
const permission_mod = @import("../permission.zig");
const msg = @import("message.zig");
const Conversation = @import("conversation.zig").Conversation;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const ReadState = @import("read_state.zig").ReadState;
const api_stream = @import("../api/stream.zig");
const tool_error = @import("tool_error.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");

pub const StopReason = enum { end_turn, max_turns, aborted, tool_error, api_error };

/// Auto-compact 阈值下限：避免 resolveMaxTokens 返回异常小值（测试 mock、未知模型）
/// 导致每 turn 都 compact。低于这个值不做压缩。
pub const MIN_AUTO_COMPACT_THRESHOLD: usize = 4096;

pub const RunResult = struct {
    stop_reason: StopReason,
    turns: u32,
    tool_calls: u32,
};

pub const Options = struct {
    max_turns: u32 = 50,
    system_prompt: ?[]const u8 = null,
    verbose: bool = false,
    abort: ?*const AbortSignal = null,
    /// 传给 Write/Edit 做 must-read-first 校验。null → 单测/headless 简化路径（不校验）
    read_state: ?*ReadState = null,
    /// 收集 stream usage 事件：input/output/cache token 数。null → 不累加。
    /// by-value：sink 只含两个指针，直接塞进来，避免悬挂指针风险。
    usage_sink: ?UsageSink = null,
    /// 自动 compact 的 token 阈值。null → 按 resolveMaxTokens() * 0.7 动态算
    auto_compact_threshold: ?usize = null,
    /// 自动 compact 保留的消息数（最新的 N 条）
    auto_compact_keep_recent: usize = 10,
    /// Bash 后台作业注册表（给 ToolContext 用，工具侧 Bash/BashOutput/KillShell 用）
    jobs: ?*@import("job_registry.zig").JobRegistry = null,
    /// Plan mode 前的原始 mode 存储；EnterPlanMode/ExitPlanMode 用
    plan_prev_mode: ?*?types.PermissionMode = null,
    /// 模型 Task 清单（TaskCreate/Get/List/Update/Stop 共享）
    tasks: ?*@import("task_store.zig").TaskStore = null,
    /// 供 Agent 工具 spawn 子 agent 复用 api_client + tool_defs
    api_client: ?*@import("../client.zig").Client = null,
    tool_defs: ?[]const @import("../json.zig").ToolDefinition = null,
    /// 本次 run 对应的 agent 嵌套深度（父=0，子=1…）
    agent_depth: u8 = 0,
    /// 运行时工具（Skill/MCP）注册表。null = 仅静态工具。
    dyn_registry: ?*const @import("../tools/dynamic.zig").DynRegistry = null,
    /// Skill 激活回调:Skill 工具激活后调用,把临时白/黑名单挂到 App。
    activate_skill_state: ?*anyopaque = null,
    activate_skill_fn: ?*const fn (
        state: *anyopaque,
        skill_name: []const u8,
        allowed: []const []const u8,
        disallowed: []const []const u8,
    ) anyerror!void = null,
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
    home_dir: []const u8 = "",
    /// 子 agent 定义集合(Task 工具据此找 subagent_type)。
    agents: ?*const @import("../agents/set.zig").AgentSet = null,
    /// 当前会话用的 model 名(供 subagent inherit 解析)。
    parent_model: []const u8 = "",
    /// Skill 集合(Task 工具 subagent preload_skills 字段用)。
    skills_set: ?*const @import("../skills/skill.zig").SkillSet = null,
    /// Worktree state(EnterWorktree/ExitWorktree 工具用)。
    worktree_state: ?*anyopaque = null,
    worktree_push_fn: ?*const fn (
        state: *anyopaque,
        allocator: std.mem.Allocator,
        wt_path: []const u8,
        original_cwd: []const u8,
    ) anyerror!void = null,
    worktree_pop_fn: ?*const fn (
        state: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror!?@import("../tools/worktree.zig").WorktreeEntry = null,
    /// MCP session 列表(ListMcpResourcesTool/ReadMcpResourceTool 用)。
    mcp_sessions: ?*const []@import("../app.zig").McpSessionEntry = null,
    /// Cron registry(CronCreate/Delete/List 用)。
    cron_registry: ?*@import("cron_registry.zig").CronRegistry = null,
};

/// usage 回调接口：stream 每次吐 usage event 时调用。
/// App.usage 实现此接口；测试用 mock 亦可。
pub const UsageSink = struct {
    ctx: *anyopaque,
    addFn: *const fn (ctx: *anyopaque, delta: api_stream.UsageDelta) void,

    pub fn add(self: UsageSink, delta: api_stream.UsageDelta) void {
        self.addFn(self.ctx, delta);
    }
};

/// 一次用户请求的完整 agent 运行：发送当前 conversation 到 API，
/// 收集事件到 assistant message 里（text 和 tool_use blocks），
/// 如果有 tool_use 则执行、追加 tool_result 到 conversation，继续下一轮。
/// 直到没有 tool_use、turns 达到 max_turns、或 abort 触发。
///
/// 每轮的 assistant 响应文字也通过 stdout_writer 实时输出（便于 REPL 看流）。
/// stdout_writer 必须有 `print(fmt, args)` 方法（用 `anytype`）。
pub fn run(
    conversation: *Conversation,
    api_client: *client_mod.Client,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    opts: Options,
    stdout_writer: anytype,
    allocator: std.mem.Allocator,
) !RunResult {
    var turns: u32 = 0;
    var total_tool_calls: u32 = 0;

    while (turns < opts.max_turns) : (turns += 1) {
        // 开头检查 abort
        if (opts.abort) |a| if (a.isAborted()) {
            log.warn("agent", "aborted before turn {d}", .{turns + 1});
            return .{ .stop_reason = .aborted, .turns = turns, .tool_calls = total_tool_calls };
        };

        // 自动 compact：在发请求前检查 token 估算，超阈值则保留最近 N 条。
        // 阈值 null 时按 client.resolveMaxTokens() * 0.7 动态算（跟上模型 context window 变化）。
        // 下限 MIN_AUTO_COMPACT_THRESHOLD：避免 resolveMaxTokens 返回异常小值导致每 turn 都 compact。
        const auto_threshold: usize = opts.auto_compact_threshold orelse
            @max(@as(usize, api_client.resolveMaxTokens()) * 7 / 10, MIN_AUTO_COMPACT_THRESHOLD);
        if (conversation.isOverThreshold(auto_threshold)) {
            const before = conversation.len();
            const dropped = conversation.compactKeepRecent(opts.auto_compact_keep_recent);
            if (dropped > 0) {
                log.info("agent", "auto-compact: dropped {d} old messages ({d} -> {d}) threshold={d}", .{ dropped, before, conversation.len(), auto_threshold });
                try stdout_writer.print("\x1b[33m[auto-compacted {d} old messages, kept last {d}]\x1b[0m\n", .{ dropped, conversation.len() });
            }
        }

        log.info("agent", "turn {d}/{d} starting (msgs={d})", .{ turns + 1, opts.max_turns, conversation.messages.items.len });

        // 1. 构造当前这一轮的 API 请求（把 Conversation 映射为 types.ApiMessage 数组）。
        var api_messages = try buildApiMessages(conversation, allocator);
        defer freeApiMessages(&api_messages, allocator);

        // 2. 发送流式请求（abortable 版本：abort 通过 EventIterator 检查点传播）
        var stream = api_client.sendMessageStreamAbortable(api_messages.items, opts.system_prompt, tool_defs, opts.abort) catch |err| {
            log.err("agent", "sendMessageStream failed turn={d}: {s}", .{ turns + 1, @errorName(err) });
            return .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls };
        };
        defer stream.deinit();

        const rid = stream.id;
        log.infoId("agent", rid, "stream opened, reading events", .{});

        // 3. 收集响应 blocks
        var assistant_blocks = std.ArrayList(msg.Block).empty;
        errdefer {
            for (assistant_blocks.items) |b| b.deinit(allocator);
            assistant_blocks.deinit(allocator);
        }
        var assistant_text = std.ArrayList(u8).empty;
        defer assistant_text.deinit(allocator);

        var tool_uses = std.ArrayList(msg.ToolUse).empty;
        defer tool_uses.deinit(allocator);

        try stdout_writer.print("\x1b[32m", .{});
        var aborted_during_stream = false;
        var stream_error = false;
        while (true) {
            const ev_opt = stream.next() catch |err| switch (err) {
                error.Aborted => {
                    aborted_during_stream = true;
                    log.warnId("agent", rid, "stream aborted mid-turn", .{});
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
                    try stdout_writer.print("{s}", .{text});
                    try assistant_text.appendSlice(allocator, text);
                    log.debugId("agent", rid, "text chunk bytes={d}", .{text.len});
                    // text bytes 是 stream 分配的 owned——用完必须 free，否则泄漏
                    allocator.free(text);
                },
                .tool_use_start => |tu| {
                    if (opts.verbose) {
                        try stdout_writer.print("\n\x1b[35m[Tool: {s}]\x1b[0m", .{tu.name});
                    }
                    log.infoId("agent", rid, "tool_use queued id={s} name={s} input_bytes={d}", .{ tu.id, tu.name, tu.input_json.len });
                    // stream 里 id/name/input_json 都是 owned；转移所有权给 tool_uses（不 dupe）
                    try tool_uses.append(allocator, .{
                        .id = tu.id,
                        .name = tu.name,
                        .input = tu.input_json,
                    });
                },
                .usage => |u| {
                    if (opts.usage_sink) |sink| sink.add(u);
                    log.infoId("agent", rid, "usage in={d} out={d} cache_r={d} cache_w={d}", .{ u.input_tokens, u.output_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens });
                },
                .done => {},
            }
        }
        try stdout_writer.print("\x1b[0m\n", .{});

        log.infoId("agent", rid, "stream finished text_bytes={d} tool_uses={d} aborted={} err={}", .{
            assistant_text.items.len,
            tool_uses.items.len,
            aborted_during_stream,
            stream_error,
        });

        if (aborted_during_stream) {
            // 保留已流出的 partial assistant text（对齐 TS 原版 `onCancel` 行为）：
            // 让用户看到已生成的内容；下次用 /retry 能继续。
            // tool_uses 累了一半但没收齐 content_block_stop 时可能残缺——弃掉（不 commit）。
            for (tool_uses.items) |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input);
            }
            tool_uses.clearRetainingCapacity();

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
            return .{ .stop_reason = .aborted, .turns = turns + 1, .tool_calls = total_tool_calls };
        }

        // Stream error：不把残缺的 assistant_text / tool_uses commit 到 conversation
        // 否则下一轮会把残片作为 context 导致模型"续写"残片
        if (stream_error) {
            for (tool_uses.items) |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input);
            }
            tool_uses.clearRetainingCapacity();
            for (assistant_blocks.items) |b| b.deinit(allocator);
            assistant_blocks.deinit(allocator);
            return .{ .stop_reason = .api_error, .turns = turns + 1, .tool_calls = total_tool_calls };
        }

        // 4. 把 assistant text + tool_uses 组装成 Message 追加到 conversation
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
        if (!has_tool_use) {
            return .{ .stop_reason = .end_turn, .turns = turns + 1, .tool_calls = total_tool_calls };
        }

        // 6. 执行所有 tool_use，把结果作为 user-role 的 tool_result block 追加
        var result_blocks = std.ArrayList(msg.Block).empty;
        errdefer {
            for (result_blocks.items) |b| b.deinit(allocator);
            result_blocks.deinit(allocator);
        }

        for (last_msg.blocks) |b| {
            const tu = switch (b) {
                .tool_use => |t| t,
                else => continue,
            };
            total_tool_calls += 1;

            // 权限检查
            const perm_result = permission_mod.checkPermission(permission_ctx, tu.name, tu.input);
            log.infoId("permission", rid, "tool={s} decision={s}", .{ tu.name, @tagName(perm_result) });
            switch (perm_result) {
                .deny => {
                    log.warnId("permission", rid, "DENY tool={s} input={s}", .{ tu.name, tu.input });
                    const err_json = try tool_error.errorToJson("PermissionDenied", "tool '{s}' denied by permission rule or plan mode", .{tu.name}, allocator);
                    errdefer allocator.free(err_json);
                    try result_blocks.append(allocator, .{ .tool_result = .{
                        .tool_use_id = try allocator.dupe(u8, tu.id),
                        .content = err_json,
                        .is_error = true,
                    } });
                    continue;
                },
                .ask => {
                    const allowed = permission_mod.promptUser(tu.name, tu.input, allocator) catch false;
                    log.infoId("permission", rid, "prompt tool={s} user_allowed={}", .{ tu.name, allowed });
                    if (!allowed) {
                        const err_json = try tool_error.errorToJson("PermissionDenied", "user declined '{s}' via prompt", .{tu.name}, allocator);
                        errdefer allocator.free(err_json);
                        try result_blocks.append(allocator, .{ .tool_result = .{
                            .tool_use_id = try allocator.dupe(u8, tu.id),
                            .content = err_json,
                            .is_error = true,
                        } });
                        continue;
                    }
                },
                .allow => {},
            }

            // 派发到工具（先查静态，未命中查 dyn_registry：Skill / MCP）
            log.infoId("agent", rid, "tool.exec start name={s} id={s}", .{ tu.name, tu.id });
            log.debugId("agent", rid, "tool.exec input={s}", .{tu.input});
            const t_start = util_time.nowMs();
            const exec_result = blk: {
                const tool_ctx = tools_mod.ToolContext{
                    .allocator = allocator,
                    .abort = opts.abort,
                    .read_state = opts.read_state,
                    .jobs = opts.jobs,
                    .permission_ctx = @constCast(permission_ctx),
                    .plan_prev_mode = opts.plan_prev_mode,
                    .tasks = opts.tasks,
                    .api_client = opts.api_client,
                    .tool_defs = opts.tool_defs,
                    .agent_depth = opts.agent_depth,
                    .dyn_registry = opts.dyn_registry,
                    .activate_skill_state = opts.activate_skill_state,
                    .activate_skill_fn = opts.activate_skill_fn,
                    .explicit_invocation = opts.explicit_invocation,
                    .session_id = opts.session_id,
                    .project_dir = opts.project_dir,
                    .disable_shell_execution = opts.disable_shell_execution,
                    .sandbox = opts.sandbox,
                    .cwd_abs = opts.cwd_abs,
                    .home_dir = opts.home_dir,
                    .agents = opts.agents,
                    .parent_model = opts.parent_model,
                    .skills = opts.skills_set,
                    .worktree_state = opts.worktree_state,
                    .worktree_push_fn = opts.worktree_push_fn,
                    .worktree_pop_fn = opts.worktree_pop_fn,
                    .mcp_sessions = opts.mcp_sessions,
                    .cron_registry = opts.cron_registry,
                };
                break :blk tools_mod.dispatch(&tool_ctx, tu.name, tu.input);
            } catch |err| {
                log.warnId("agent", rid, "tool.exec FAILED name={s} err={s} duration_ms={d}", .{ tu.name, @errorName(err), util_time.nowMs() - t_start });
                const code = if (err == error.UnknownTool) "UnknownTool" else @errorName(err);
                const err_json = try tool_error.errorToJson(code, "{s} failed with {s}", .{ tu.name, @errorName(err) }, allocator);
                errdefer allocator.free(err_json);
                try result_blocks.append(allocator, .{ .tool_result = .{
                    .tool_use_id = try allocator.dupe(u8, tu.id),
                    .content = err_json,
                    .is_error = true,
                } });
                continue;
            };

            log.infoId("agent", rid, "tool.exec done name={s} output_bytes={d} duration_ms={d}", .{ tu.name, exec_result.len, util_time.nowMs() - t_start });
            log.debugId("agent", rid, "tool.exec output={s}", .{exec_result});

            try result_blocks.append(allocator, .{ .tool_result = .{
                .tool_use_id = try allocator.dupe(u8, tu.id),
                .content = exec_result,
                .is_error = false,
            } });
        }

        if (result_blocks.items.len == 0) {
            result_blocks.deinit(allocator);
            return .{ .stop_reason = .tool_error, .turns = turns + 1, .tool_calls = total_tool_calls };
        }

        const blocks_owned = try result_blocks.toOwnedSlice(allocator);
        try conversation.append(.{ .role = .user, .blocks = blocks_owned });
    }

    // 循环正常退出 = turns >= max_turns
    return .{ .stop_reason = .max_turns, .turns = turns, .tool_calls = total_tool_calls };
}

/// 把 Conversation 中的所有消息 1:1 映射为 `types.ApiMessage`，
/// 供 `client.sendMessageStream` 使用。调用方必须用 `freeApiMessages` 释放。
fn buildApiMessages(
    conversation: *const Conversation,
    allocator: std.mem.Allocator,
) !std.ArrayList(types.ApiMessage) {
    var out = std.ArrayList(types.ApiMessage).empty;
    errdefer {
        freeApiMessages(&out, allocator);
    }

    for (conversation.messages.items) |m| {
        const contents = try allocator.alloc(types.ApiContent, m.blocks.len);
        for (m.blocks, 0..) |b, i| {
            contents[i] = switch (b) {
                .text => |t| .{ .text = t }, // 借用，不 dupe——lifetime 绑定 conversation
                .tool_use => |tu| .{ .tool_use = .{ .id = tu.id, .name = tu.name, .input = tu.input } },
                .tool_result => |tr| .{ .tool_result = .{
                    .tool_use_id = tr.tool_use_id,
                    .content = tr.content,
                    .is_error = tr.is_error,
                } },
            };
        }
        try out.append(allocator, .{ .role = m.role, .content = contents });
    }
    return out;
}

fn freeApiMessages(list: *std.ArrayList(types.ApiMessage), allocator: std.mem.Allocator) void {
    for (list.items) |m| {
        allocator.free(m.content);
    }
    list.deinit(allocator);
}

test "buildApiMessages maps blocks" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    try c.appendText(.user, "hi");

    var api = try buildApiMessages(&c, a);
    defer freeApiMessages(&api, a);

    try std.testing.expect(api.items.len == 1);
    try std.testing.expect(api.items[0].role == .user);
    try std.testing.expect(api.items[0].content.len == 1);
    try std.testing.expectEqualStrings("hi", api.items[0].content[0].text);
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

    var api = try buildApiMessages(&c, a);
    defer freeApiMessages(&api, a);

    try std.testing.expect(api.items.len == 2);
    try std.testing.expect(@as(std.meta.Tag(types.ApiContent), api.items[0].content[0]) == .tool_use);
    try std.testing.expect(@as(std.meta.Tag(types.ApiContent), api.items[1].content[0]) == .tool_result);
}

test "buildApiMessages empty conversation returns empty" {
    const a = std.testing.allocator;
    var c = Conversation.init(a);
    defer c.deinit();
    var api = try buildApiMessages(&c, a);
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
    var api = try buildApiMessages(&c, a);
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
    var api = try buildApiMessages(&c, a);
    defer freeApiMessages(&api, a);
    try std.testing.expect(api.items[0].content.len == 2);
}

test "StopReason has aborted and max_turns" {
    // 编译时保证 stop_reason 含新枚举值
    const r: StopReason = .aborted;
    try std.testing.expect(r == .aborted);
    const r2: StopReason = .max_turns;
    try std.testing.expect(r2 == .max_turns);
}
