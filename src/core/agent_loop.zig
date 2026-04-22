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
const log = @import("../util/log.zig");

pub const StopReason = enum { end_turn, max_turns, aborted, tool_error, api_error };

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
        if (opts.abort) |a| if (a.isAborted()) return .{ .stop_reason = .aborted, .turns = turns, .tool_calls = total_tool_calls };

        // 1. 构造当前这一轮的 API 请求（把 Conversation 映射为 types.ApiMessage 数组）。
        var api_messages = try buildApiMessages(conversation, allocator);
        defer freeApiMessages(&api_messages, allocator);

        // 2. 发送流式请求（abortable 版本：abort 通过 EventIterator 检查点传播）
        var stream = api_client.sendMessageStreamAbortable(api_messages.items, opts.system_prompt, tool_defs, opts.abort) catch {
            return .{ .stop_reason = .api_error, .turns = turns, .tool_calls = total_tool_calls };
        };
        defer stream.deinit();

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
                    break;
                },
                else => |e| {
                    stream_error = true;
                    log.warn("agent", "stream returned error {s} at turn {d}", .{ @errorName(e), turns + 1 });
                    break;
                },
            };
            const ev = ev_opt orelse break;
            switch (ev) {
                .text => |text| {
                    try stdout_writer.print("{s}", .{text});
                    try assistant_text.appendSlice(allocator, text);
                    // text bytes 是 stream 分配的 owned——用完必须 free，否则泄漏
                    allocator.free(text);
                },
                .tool_use_start => |tu| {
                    if (opts.verbose) {
                        try stdout_writer.print("\n\x1b[35m[Tool: {s}]\x1b[0m", .{tu.name});
                    }
                    // stream 里 id/name/input_json 都是 owned；转移所有权给 tool_uses（不 dupe）
                    try tool_uses.append(allocator, .{
                        .id = tu.id,
                        .name = tu.name,
                        .input = tu.input_json,
                    });
                },
                .done => {},
            }
        }
        try stdout_writer.print("\x1b[0m\n", .{});

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
            switch (perm_result) {
                .deny => {
                    const err = try std.fmt.allocPrint(allocator, "permission denied by rule: {s}", .{tu.name});
                    errdefer allocator.free(err);
                    try result_blocks.append(allocator, .{ .tool_result = .{
                        .tool_use_id = try allocator.dupe(u8, tu.id),
                        .content = err,
                        .is_error = true,
                    } });
                    continue;
                },
                .ask => {
                    const allowed = permission_mod.promptUser(tu.name, tu.input, allocator) catch false;
                    if (!allowed) {
                        const err = try allocator.dupe(u8, "permission denied by user");
                        errdefer allocator.free(err);
                        try result_blocks.append(allocator, .{ .tool_result = .{
                            .tool_use_id = try allocator.dupe(u8, tu.id),
                            .content = err,
                            .is_error = true,
                        } });
                        continue;
                    }
                },
                .allow => {},
            }

            // 派发到工具
            const tool = tools_mod.getTool(tu.name) orelse {
                const err = try std.fmt.allocPrint(allocator, "unknown tool: {s}", .{tu.name});
                errdefer allocator.free(err);
                try result_blocks.append(allocator, .{ .tool_result = .{
                    .tool_use_id = try allocator.dupe(u8, tu.id),
                    .content = err,
                    .is_error = true,
                } });
                continue;
            };

            const exec_result = blk: {
                const tool_ctx = tools_mod.ToolContext{ .allocator = allocator, .abort = opts.abort };
                break :blk tool.execute(&tool_ctx, tu.input);
            } catch |err| {
                const msg_str = try std.fmt.allocPrint(allocator, "tool error: {s}", .{@errorName(err)});
                errdefer allocator.free(msg_str);
                try result_blocks.append(allocator, .{ .tool_result = .{
                    .tool_use_id = try allocator.dupe(u8, tu.id),
                    .content = msg_str,
                    .is_error = true,
                } });
                continue;
            };

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
