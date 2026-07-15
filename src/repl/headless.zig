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
const pfs = @import("platform").fs;
const app_mod = @import("../app.zig");
const agent_loop = @import("../core/agent_loop.zig");
const writer_backend = @import("../core/writer_backend.zig");

/// headless 用 WriterBackend null-sink:吞掉 agent_loop 的流式输出（ANSI + tool 注解），
/// 只要最终文本。工具卡事件 no-op,text_chunk/颜色括号全丢弃。

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

    var wb = writer_backend.WriterBackend.initNullWithUsage(&app.usage);
    const be = wb.backend();
    const jobs_ptr = if (app.jobs) |*j| j else null;
    // scoped 自动召回(一等公民 P1):headless 单次 prompt 也按请求装配相关记忆(cache-safe 尾注入)。
    const scoped_recall = if (app.kg) |*k| (@import("../kg/scoped_recall.zig").build(allocator, k, &app.conversation, &app.abort) catch null) else null;
    defer if (scoped_recall) |s| allocator.free(s);
    const result = agent_loop.run(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        .{
            .verbose = app.config.verbose,
            .abort = &app.abort,
            .read_state = &app.read_state,
            .lsp = app.lsp_service, // Y2:headless 也接 LSP 诊断
            .jobs = jobs_ptr,
            .agent_jobs = if (app.agent_jobs) |*aj| aj else null,
            .swarm = &app.swarm, // SW7:headless 也接 swarm(TeamCreate/Task(name)/SendMessage 可用)
            .plan_prev_mode = &app.plan_prev_mode,
            .tasks = &app.tasks,
            .kg = if (app.kg) |*k| k else null, .kg_projects_dir = app.kg_projects_dir, .memdir_abs = app.memdir_abs,
            .api_client = &app.api_client,
            .tool_defs = app.tool_defs,
            .system_prompt = app.system_prompt,
            .inject_user_context = app.user_context,
            .synthetic_user_input = scoped_recall,
            .dyn_registry = &app.dyn_registry,
            .host_services = app.hostServices(),
            .project_dir = app.project_dir_or_empty(),
            .sandbox = app.sandboxPtr(),
            .cwd_abs = app.cwdAbs(),
            .home_dir = app.homeDir(),
            .agents = &app.agents,
            .parent_model = app.config.model,
            .skills_set = &app.skills,
            .mcp_sessions = &app.mcp_sessions.items,
            .cron_registry = &app.cron_registry,
        },
        &be,
        allocator,
    ) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };

    app.persistTranscript();

    // L3:挂起 → 落 suspend.json(挂起元数据 + 同轮已完成结果),供跨进程恢复。
    if (result.suspend_info) |si| {
        defer si.deinit();
        if (app.sessionDir()) |dir| {
            const suspend_state = @import("../core/suspend_state.zig");
            suspend_state.writeFromSuspendInfo(dir, si, allocator) catch |e| {
                std.debug.print("warning: suspend.json write failed: {s}\n", .{@errorName(e)});
            };
            std.debug.print("⏸ Suspended (kind={s}) — resume from session dir: {s}\n", .{ si.kind, dir });
        }
    }

    const final_text = lastAssistantText(&app.conversation, allocator) catch "";
    defer if (final_text.len > 0) allocator.free(final_text);

    if (json_output) {
        try emitJson(allocator, final_text, result, &app.usage, app.config.model);
    } else {
        // 纯文本：直接打模型最终回复 + 结尾换行
        writeStdout(final_text);
        if (final_text.len == 0 or final_text[final_text.len - 1] != '\n') writeStdout("\n");
    }

    return exitCodeFor(result.stop_reason);
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
    const line = try buildResultLine(allocator, final_text, result, usage, model);
    defer allocator.free(line);
    writeStdout(line);
}

/// 构造 result NDJSON 行(owned,含尾部 \n)。提 pub 供 L2 断言格式,不直接写 stdout。
pub fn buildResultLine(
    allocator: std.mem.Allocator,
    final_text: []const u8,
    result: agent_loop.RunResult,
    usage: *const app_mod.UsageTotals,
    model: []const u8,
) ![]u8 {
    const stop = switch (result.stop_reason) {
        .end_turn => "end_turn",
        .max_turns => "max_turns",
        .aborted => "aborted",
        .api_error => "api_error",
        .tool_error => "tool_error",
        .tool_loop => "tool_loop",
        .suspended => "suspended",
        .backgrounded => "backgrounded", // headless 不会转后台,但 switch 须穷尽
        .budget => "budget",
    };
    const cost = usage.costUsd(model);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        \\{{"type":"result","stop_reason":"{s}","turns":{d},"tool_calls":{d},"input_tokens":{d},"output_tokens":{d},"cost_usd":{d:.6},"text":
    , .{ stop, result.turns, result.tool_calls, usage.input_tokens, usage.output_tokens, cost });
    try std.json.Stringify.encodeJsonString(final_text, .{}, &aw.writer);
    try aw.writer.writeAll("}\n");
    return try aw.toOwnedSlice();
}

/// 退出码逻辑(提 pub 供 L2):end_turn/max_turns → 0;suspended → 2(挂起待恢复,非失败);
/// 其它(error/loop/aborted)→ 1。
pub fn exitCodeFor(stop_reason: agent_loop.StopReason) u8 {
    return switch (stop_reason) {
        .end_turn, .max_turns, .budget => 0, // budget/max_turns=受控停(非失败),同 end_turn
        .suspended => 2, // 挂起待恢复:区别于完成(0)与失败(1)
        else => 1,
    };
}

fn writeStdout(bytes: []const u8) void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = pfs.write(1, bytes[pos..]); // 可移植(POSIX write / Windows _write),fd 1=stdout
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
