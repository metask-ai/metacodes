//! Headless 模式：`-p "prompt"` / stdin pipe → 跑单次 agent_loop 后退出。
//!
//! 与 REPL 的区别：
//! - 不进交互循环，不开 raw mode / statusline / progress / history。
//! - 流式输出走静默 writer（不把 ANSI / tool 注解打到 stdout）；
//!   运行结束后从 conversation 提取最后一条 assistant 的文本，干净地打到 stdout。
//! - `--json`：改为 NDJSON 事件流（每行一个 JSON），便于 CI/脚本消费。
//!
//! 退出码：end_turn / max_turns → 0；api_error / tool_error / aborted → 1。

const std = @import("std");
const app_mod = @import("../app.zig");
const agent_loop = @import("../core/agent_loop.zig");

/// 静默 writer：吞掉 agent_loop 的流式输出（ANSI + tool 注解），headless 只要最终文本。
const SilentWriter = struct {
    pub fn print(_: *@This(), comptime fmt: []const u8, args: anytype) !void {
        _ = fmt;
        _ = args;
    }
};

/// 跑单次 prompt。返回进程退出码。
pub fn run(
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    json_output: bool,
) !u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) {
        std.debug.print("error: empty prompt\n", .{});
        return 1;
    }

    try app.conversation.appendText(.user, trimmed);

    var writer = SilentWriter{};
    const jobs_ptr = if (app.jobs) |*j| j else null;
    const result = agent_loop.run(
        &app.conversation,
        &app.api_client,
        app.tool_defs,
        &app.permission_ctx,
        .{
            .verbose = app.config.verbose,
            .abort = &app.abort,
            .read_state = &app.read_state,
            .usage_sink = app.usageSink(),
            .jobs = jobs_ptr,
            .plan_prev_mode = &app.plan_prev_mode,
            .tasks = &app.tasks,
            .api_client = &app.api_client,
            .tool_defs = app.tool_defs,
            .system_prompt = app.system_prompt,
            .dyn_registry = &app.dyn_registry,
        },
        &writer,
        allocator,
    ) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };

    app.persistTranscript();

    const final_text = lastAssistantText(&app.conversation, allocator) catch "";
    defer if (final_text.len > 0) allocator.free(final_text);

    if (json_output) {
        try emitJson(allocator, final_text, result, &app.usage, app.config.model);
    } else {
        // 纯文本：直接打模型最终回复 + 结尾换行
        writeStdout(final_text);
        if (final_text.len == 0 or final_text[final_text.len - 1] != '\n') writeStdout("\n");
    }

    return switch (result.stop_reason) {
        .end_turn, .max_turns => 0,
        else => 1,
    };
}

/// 把 conversation 最后一条 assistant message 的所有 text block 拼起来（owned）。
fn lastAssistantText(conv: *const @import("../core/conversation.zig").Conversation, allocator: std.mem.Allocator) ![]const u8 {
    var i: usize = conv.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = conv.messages.items[i];
        if (m.role != .assistant) continue;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        for (m.blocks) |b| {
            switch (b) {
                .text => |t| try buf.appendSlice(allocator, t),
                else => {},
            }
        }
        return buf.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, "");
}

/// NDJSON：一行 result 事件。包含最终文本、stop_reason、turns、tool_calls、usage。
fn emitJson(
    allocator: std.mem.Allocator,
    final_text: []const u8,
    result: agent_loop.RunResult,
    usage: *const app_mod.UsageTotals,
    model: []const u8,
) !void {
    const stop = switch (result.stop_reason) {
        .end_turn => "end_turn",
        .max_turns => "max_turns",
        .aborted => "aborted",
        .api_error => "api_error",
        .tool_error => "tool_error",
    };
    const cost = usage.costUsd(model);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        \\{{"type":"result","stop_reason":"{s}","turns":{d},"tool_calls":{d},"input_tokens":{d},"output_tokens":{d},"cost_usd":{d:.6},"text":
    , .{ stop, result.turns, result.tool_calls, usage.input_tokens, usage.output_tokens, cost });
    try std.json.Stringify.encodeJsonString(final_text, .{}, &aw.writer);
    try aw.writer.writeAll("}\n");
    const line = try aw.toOwnedSlice();
    defer allocator.free(line);
    writeStdout(line);
}

fn writeStdout(bytes: []const u8) void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = std.c.write(1, bytes.ptr + pos, bytes.len - pos);
        if (n <= 0) break;
        pos += @as(usize, @intCast(n));
    }
}

test "lastAssistantText extracts trailing assistant text" {
    const a = std.testing.allocator;
    var conv = @import("../core/conversation.zig").Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    try conv.appendText(.assistant, "hello there");
    const t = try lastAssistantText(&conv, a);
    defer a.free(t);
    try std.testing.expectEqualStrings("hello there", t);
}

test "lastAssistantText empty when no assistant" {
    const a = std.testing.allocator;
    var conv = @import("../core/conversation.zig").Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const t = try lastAssistantText(&conv, a);
    defer a.free(t);
    try std.testing.expectEqualStrings("", t);
}
