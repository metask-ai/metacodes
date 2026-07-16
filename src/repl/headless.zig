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
    // scoped 自动召回(一等公民 P1):headless 单次 prompt 也按请求装配相关记忆(cache-safe 尾注入)。
    const scoped_recall = if (app.kg) |*k| (@import("../kg/scoped_recall.zig").build(allocator, k, &app.conversation, &app.abort) catch null) else null;
    defer if (scoped_recall) |s| allocator.free(s);
    const result = agent_loop.run(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        buildOptions(app, scoped_recall),
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
        try emitJson(allocator, final_text, result, &app.usage, app.activeModel());
    } else {
        // 纯文本：直接打模型最终回复 + 结尾换行
        writeStdout(final_text);
        if (final_text.len == 0 or final_text[final_text.len - 1] != '\n') writeStdout("\n");
    }

    return exitCodeFor(result.stop_reason);
}

/// 构造 agent_loop.Options(run + resumeSuspended 共用,消两份字段漂移)。
/// scoped_recall = 本轮尾注入的召回记忆(fresh run 传;resume 传 null——续跑不重新召回)。
/// **task#20:headless 挂起 requester**。恒返 .pending → UI 工具(ask_user/plan_mode)返 error.UiPending
/// → agent_loop 挂起(写 suspend.json)。out 不写(响应经 subprocess resume 的 --resume-response 迟来)。
const ui_request_mod = @import("../core/protocol/ui_request.zig");
fn pendingRequestFn(
    _: *anyopaque,
    _: @import("../core/session_id.zig").SessionId,
    _: std.mem.Allocator,
    _: *const ui_request_mod.UiRequest,
    _: *ui_request_mod.UiResponse,
) anyerror!ui_request_mod.RequestOutcome {
    return .pending;
}
var pending_requester_dummy: u8 = 0;

fn buildOptions(app: *app_mod.App, scoped_recall: ?[]const u8) agent_loop.Options {
    return .{
        // task#20:--suspendable 时装恒 .pending requester → headless 遇 UI 工具挂起而非 NotATty。
        .ui_requester = if (app.config.suspendable)
            .{ .ctx = @ptrCast(&pending_requester_dummy), .requestFn = &pendingRequestFn }
        else
            null,
        .verbose = app.config.verbose,
        .abort = &app.abort,
        .read_state = &app.read_state,
        .lsp = app.lsp_service, // Y2:headless 也接 LSP 诊断
        .jobs = if (app.jobs) |*j| j else null,
        .agent_jobs = if (app.agent_jobs) |*aj| aj else null,
        .swarm = &app.swarm, // SW7:headless 也接 swarm
        .plan_prev_mode = &app.plan_prev_mode,
        .tasks = &app.tasks,
        .kg = if (app.kg) |*k| k else null,
        .kg_projects_dir = app.kg_projects_dir,
        .memdir_abs = app.memdir_abs,
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
        .additional_dirs = app.additionalDirs(),
        .home_dir = app.homeDir(),
        .agents = &app.agents,
        .parent_model = app.activeModel(),
        .skills_set = &app.skills,
        .mcp_sessions = &app.mcp_sessions.items,
        .cron_registry = &app.cron_registry,
    };
}

/// **U8:suspend/resume 生产接线 —— read→resumeRun 闭环**。异步前端(Slack/邮件/工作流)的
/// UI 请求返 error.UiPending → run 挂起落 suspend.json + 退出码 2。响应 out-of-band 到达后,
/// 新进程带 response_json 调本函数:loadTranscript 重建对话 → suspend_state.read 取挂起点
/// (tool_use_id/completed_results)→ resumeRun 注入迟来结果续跑 → 完成清 suspend.json,再挂起则
/// 重写(resume 可链式)。**这是把此前只有 write 侧的挂起机制补成完整闭环**(read 侧原零调用者)。
///
/// 前置:app 已用与挂起时**同一 session_id** init(transcript 目录一致);response_json 是挂起工具
/// (AskUserQuestion/ExitPlanMode/custom)的迟来结果(工具结果 JSON,直接作 tool_result content)。
pub fn resumeSuspended(
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    response_json: []const u8,
    json_output: bool,
) !u8 {
    const suspend_state = @import("../core/suspend_state.zig");
    const transcript = @import("../core/transcript.zig");
    const dir = app.sessionDir() orelse {
        std.debug.print("error: resume 需要 session 目录(--session/持久化 transcript)\n", .{});
        return 1;
    };

    // 读挂起点(tool_use_id/kind/completed_results)。缺 suspend.json = 无挂起可恢复。
    const state = suspend_state.read(dir, allocator) catch |e| {
        std.debug.print("error: 读 suspend.json 失败({s})——该 session 无待恢复挂起?\n", .{@errorName(e)});
        return 1;
    };
    defer suspend_state.freeState(state, allocator);

    // 重建对话(挂起前的完整历史;transcript 是持久真相)。app.conversation 由 init 已建空,
    // loadTranscript 追加历史消息。
    transcript.loadTranscript(&app.conversation, dir, allocator) catch |e| {
        std.debug.print("error: loadTranscript 失败({s})\n", .{@errorName(e)});
        return 1;
    };

    var wb = writer_backend.WriterBackend.initNullWithUsage(&app.usage);
    const be = wb.backend();

    // suspend_state.CompletedResult → agent_loop.SuspendInfo.CompletedResult(同形状,异 nominal 类型)。
    const CR = agent_loop.SuspendInfo.CompletedResult;
    const crs = allocator.alloc(CR, state.completed_results.len) catch {
        std.debug.print("error: resume OOM\n", .{});
        return 1;
    };
    defer allocator.free(crs);
    for (state.completed_results, 0..) |src, i| {
        crs[i] = .{ .tool_use_id = src.tool_use_id, .content = src.content, .is_error = src.is_error };
    }

    const result = agent_loop.resumeRun(
        &app.conversation,
        app.provider(),
        app.tool_defs,
        &app.permission_ctx,
        state.tool_use_id,
        response_json,
        crs,
        buildOptions(app, null), // resume 不重新召回
        &be,
        allocator,
    ) catch |err| {
        std.debug.print("error: resumeRun 失败({s})\n", .{@errorName(err)});
        return 1;
    };

    app.persistTranscript();

    // 完成 → 清 suspend.json;再次挂起(resume 链式)→ 重写新挂起点。
    if (result.suspend_info) |si| {
        defer si.deinit();
        suspend_state.writeFromSuspendInfo(dir, si, allocator) catch |e| {
            std.debug.print("warning: suspend.json 重写失败: {s}\n", .{@errorName(e)});
        };
        std.debug.print("⏸ 再次挂起 (kind={s}) — 续 resume from: {s}\n", .{ si.kind, dir });
    } else {
        suspend_state.clear(dir); // 恢复完成,挂起点作废
    }

    const final_text = lastAssistantText(&app.conversation, allocator) catch "";
    defer if (final_text.len > 0) allocator.free(final_text);
    if (json_output) {
        try emitJson(allocator, final_text, result, &app.usage, app.activeModel());
    } else {
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
