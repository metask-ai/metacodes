//! L3 component 测试:挂起/恢复端到端(+ L2 custom 的首个真实消费 + 跨进程恢复)。
//!
//! 阶段 A(挂起):模型调一个发起 custom UI 的测试工具 → 异步 mock backend 返 .pending →
//!   工具返 error.UiPending → agent_loop 返 .suspended + suspend_info,conversation 含 pending
//!   tool_use 但无对应 tool_result,落盘 transcript + suspend.json。
//! 阶段 B(跨进程恢复):新建 Conversation + loadTranscript 从盘重建(模拟新进程)→ 读
//!   suspend.json → resumeRun 注入响应 JSON 作为 tool_result → 模型续跑到 end_turn。

const std = @import("std");
const pfs = @import("platform").fs;
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const ui_request = cc.ui_request;
const ui_backend = cc.ui_backend;
const writer_backend = cc.writer_backend;
const suspend_state = cc.suspend_state;

// 阶段 A 的响应:模型调 request_ui 工具(发起 custom UI)。
const SUSPEND_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_dyn1\",\"name\":\"request_ui\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":4}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// 阶段 B 的响应:拿到迟来的 tool_result 后,模型给最终回复 → end_turn。
const RESUME_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":9,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done editing\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// 异步 mock backend:UiRequester 返 .pending(stash 请求不写 out)。custom 请求触发挂起。
fn asyncPendingRequester(_: *anyopaque, _: ui_request.SessionId, _: std.mem.Allocator, req: *const ui_request.UiRequest, _: *ui_request.UiResponse) anyerror!ui_request.RequestOutcome {
    // 只对 custom 请求挂起(本测试只发 custom)。
    return switch (req.*) {
        .custom => .pending,
        else => .unavailable,
    };
}

// 测试工具:发起 custom UI 请求(video_timeline)。同步 backend 会 answered;异步会 pending。
fn requestUiToolExec(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    const result = try ctx.requestUiCustom(ctx.allocator, "video_timeline", "{\"clips\":[1,2,3]}");
    // answered 路径:回结果(本测试走 pending,不到这)。
    return ctx.allocator.dupe(u8, result);
}

test "L3: 挂起 → 跨进程 loadTranscript 恢复 → 续跑到 end_turn(L2 custom 首个真实负载)" {
    const a = std.testing.allocator;

    // 注册测试工具(发起 custom UI)。
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("request_ui", "Open a custom UI and collect params", &.{}, requestUiToolExec, null, false);

    // session 目录(per-pid 隔离)。
    var dirbuf: [256]u8 = undefined;
    const session_dir = makeSessionDir(&dirbuf);
    // 清理上次残留。
    clearSession(session_dir);

    // ── 阶段 A:挂起 ──────────────────────────────────────────────────────
    {
        const bodies = [_][]const u8{SUSPEND_SSE};
        var srv = try harness.MockServer.startCassette(&bodies, 0);
        defer srv.stop();
        const url = try srv.urlOwned(a);
        defer a.free(url);

        var io_rt = std.Io.Threaded.init(a, .{});
        defer io_rt.deinit();
        var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
        defer client.deinit();

        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try conv.appendText(.user, "edit my video");

        const perm = cc.permission.createContext(.bypass_permissions, a);
        const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
        defer a.free(tool_defs);

        var render = writer_backend.WriterBackend.initNull();
        const be = render.backend();
        const requester = ui_request.UiRequester{ .ctx = @ptrCast(&dyn), .requestFn = &asyncPendingRequester };

        const result = agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{
            .max_turns = 3,
            .dyn_registry = &dyn,
            .ui_requester = requester,
        }, &be, a) catch |e| {
            std.debug.print("phase A run failed: {s}\n", .{@errorName(e)});
            return error.SkipZigTest;
        };

        // 断言:挂起 + suspend_info 正确。
        try std.testing.expectEqual(agent_loop.StopReason.suspended, result.stop_reason);
        try std.testing.expect(result.suspend_info != null);
        const si = result.suspend_info.?;
        try std.testing.expectEqualStrings("tu_dyn1", si.tool_use_id);
        try std.testing.expectEqualStrings("video_timeline", si.kind);

        // conversation 含 pending tool_use(assistant)但无对应 tool_result。
        try std.testing.expect(hasToolUse(&conv, "tu_dyn1"));
        try std.testing.expect(!hasToolResult(&conv, "tu_dyn1"));

        // 落盘:transcript + suspend.json(模拟生产路径)。
        var writer = cc.transcript.Writer.openExisting(a, try a.dupe(u8, session_dir), "claude-sonnet-4-20250514", 0);
        defer writer.deinit();
        writer.flush(&conv);
        try suspend_state.write(session_dir, .{ .tool_use_id = si.tool_use_id, .kind = si.kind, .payload_json = si.payload_json }, a);

        si.deinit();
    }

    // ── 阶段 B:跨进程恢复(新 Conversation,从盘重建)──────────────────────
    {
        const bodies = [_][]const u8{RESUME_SSE};
        var srv = try harness.MockServer.startCassette(&bodies, 0);
        defer srv.stop();
        const url = try srv.urlOwned(a);
        defer a.free(url);

        var io_rt = std.Io.Threaded.init(a, .{});
        defer io_rt.deinit();
        var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
        defer client.deinit();

        // 新进程:从盘 loadTranscript 重建 conversation。
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try cc.transcript.loadTranscript(&conv, session_dir, a);
        // 重建后应仍含 pending tool_use,无 tool_result。
        try std.testing.expect(hasToolUse(&conv, "tu_dyn1"));
        try std.testing.expect(!hasToolResult(&conv, "tu_dyn1"));

        // 读 suspend.json 拿挂起点。
        const ss = try suspend_state.read(session_dir, a);
        defer suspend_state.freeState(ss, a);
        try std.testing.expectEqualStrings("tu_dyn1", ss.tool_use_id);

        const perm = cc.permission.createContext(.bypass_permissions, a);
        const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
        defer a.free(tool_defs);
        var render = writer_backend.WriterBackend.initNull();
        const be = render.backend();

        // 用户编辑后的剪辑参数(异步 UI 回收的结果)注入。同轮无其它工具 → completed_results 空。
        const response_json = "{\"in\":3,\"out\":42}";
        const completed = try toAgentLoopCompleted(a, ss.completed_results);
        defer a.free(completed);
        const result = agent_loop.resumeRun(&conv, client.provider(), tool_defs, &perm, ss.tool_use_id, response_json, completed, .{
            .max_turns = 3,
            .dyn_registry = &dyn,
        }, &be, a) catch |e| {
            std.debug.print("phase B resume failed: {s}\n", .{@errorName(e)});
            return error.SkipZigTest;
        };
        try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
        if (result.suspend_info) |si| si.deinit();

        // 注入的 tool_result 在 conversation 里(对得上挂起 tool_use)。
        try std.testing.expect(hasToolResult(&conv, "tu_dyn1"));
        suspend_state.clear(session_dir);
    }

    clearSession(session_dir);
}

/// suspend_state.CompletedResult → agent_loop.SuspendInfo.CompletedResult(同形,转一下;borrow)。
fn toAgentLoopCompleted(a: std.mem.Allocator, src: []const suspend_state.SuspendState.CompletedResult) ![]agent_loop.SuspendInfo.CompletedResult {
    const out = try a.alloc(agent_loop.SuspendInfo.CompletedResult, src.len);
    for (src, 0..) |cr, i| out[i] = .{ .tool_use_id = cr.tool_use_id, .content = cr.content, .is_error = cr.is_error };
    return out;
}

// ── 多工具同轮:A=request_ui(pending) + B=Read(done)。Linus 点的 API 配对回归 ─────────
// 一条 assistant 含两个 tool_use。挂起时**不**能拆两次 user 消息(违反 Anthropic 同 turn 配对)。
// 本测试断言:① 挂起;② B 的结果进 completed_results(没单独提交);③ 挂起后 conversation
// **没有** partial user 消息(A、B 的 tool_result 都不在盘上);④ resume 时 A+B 的 tool_result
// 在**同一条** user 消息里补齐。
const SUSPEND_MULTI_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_A\",\"name\":\"request_ui\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_B\",\"name\":\"done_tool\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":4}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// B:立即返回结果的并发安全测试工具。
fn doneToolExec(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return ctx.allocator.dupe(u8, "{\"b_done\":true}");
}

test "L3: 多工具同轮(A pending + B done)→ 挂起不拆 turn,resume 同条 user 补齐 A+B" {
    const a = std.testing.allocator;

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("request_ui", "Open custom UI", &.{}, requestUiToolExec, null, false);
    // done_tool 注册为**并发安全**(它无副作用),与 request_ui 同批并行跑。
    try dyn.register("done_tool", "Returns immediately", &.{}, doneToolExec, null, false);

    const bodies = [_][]const u8{SUSPEND_MULTI_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "do two things");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const requester = ui_request.UiRequester{ .ctx = @ptrCast(&dyn), .requestFn = &asyncPendingRequester };

    const result = agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{
        .max_turns = 3,
        .dyn_registry = &dyn,
        .ui_requester = requester,
    }, &be, a) catch |e| {
        std.debug.print("multi run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    // ① 挂起;② A 是挂起点,B 在 completed_results。
    try std.testing.expectEqual(agent_loop.StopReason.suspended, result.stop_reason);
    try std.testing.expect(result.suspend_info != null);
    const si = result.suspend_info.?;
    defer si.deinit();
    try std.testing.expectEqualStrings("tu_A", si.tool_use_id);
    try std.testing.expectEqual(@as(usize, 1), si.completed_results.len);
    try std.testing.expectEqualStrings("tu_B", si.completed_results[0].tool_use_id);

    // ③ 挂起后 conversation **没有** A 或 B 的 tool_result(没拆 turn 单独提交)。
    try std.testing.expect(hasToolUse(&conv, "tu_A"));
    try std.testing.expect(hasToolUse(&conv, "tu_B"));
    try std.testing.expect(!hasToolResult(&conv, "tu_A"));
    try std.testing.expect(!hasToolResult(&conv, "tu_B"));

    // ④ resume:A 的迟来结果 + B 的 stash 结果在**同一条** user 消息里补齐(API 配对合法)。
    const RESUME2 = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":9,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"both done\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const bodies2 = [_][]const u8{RESUME2};
    var srv2 = try harness.MockServer.startCassette(&bodies2, 0);
    defer srv2.stop();
    const url2 = try srv2.urlOwned(a);
    defer a.free(url2);
    var io_rt2 = std.Io.Threaded.init(a, .{});
    defer io_rt2.deinit();
    var client2 = cc.client_mod.Client.initWithBaseUrl(a, io_rt2.io(), "test-key", "claude-sonnet-4-20250514", url2);
    defer client2.deinit();

    const completed = try toAgentLoopCompleted(a, &.{
        .{ .tool_use_id = si.completed_results[0].tool_use_id, .content = si.completed_results[0].content, .is_error = si.completed_results[0].is_error },
    });
    defer a.free(completed);
    const msg_count_before = conv.messages.items.len;
    const result2 = agent_loop.resumeRun(&conv, client2.provider(), tool_defs, &perm, si.tool_use_id, "{\"a\":1}", completed, .{
        .max_turns = 3,
        .dyn_registry = &dyn,
    }, &be, a) catch |e| {
        std.debug.print("multi resume failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    if (result2.suspend_info) |s2| s2.deinit();
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result2.stop_reason);

    // A 和 B 的 tool_result 都注入了,且在**同一条** user 消息(resume 加的那条)。
    try std.testing.expect(hasToolResult(&conv, "tu_A"));
    try std.testing.expect(hasToolResult(&conv, "tu_B"));
    // resume 注入的那条 user 消息(msg_count_before 索引处)同时含 A+B 两个 tool_result。
    const injected = conv.messages.items[msg_count_before];
    try std.testing.expectEqual(cc.core_message.Role.user, injected.role);
    var tr_a = false;
    var tr_b = false;
    for (injected.blocks) |blk| switch (blk) {
        .tool_result => |tr| {
            if (std.mem.eql(u8, tr.tool_use_id, "tu_A")) tr_a = true;
            if (std.mem.eql(u8, tr.tool_use_id, "tu_B")) tr_b = true;
        },
        else => {},
    };
    try std.testing.expect(tr_a and tr_b); // 同一条 user 消息里 A+B 配对(API 合法)
}

// ── helpers ──────────────────────────────────────────────────────────────

fn makeSessionDir(buf: []u8) []const u8 {
    // currentPid 而非 std.c.getpid:Windows 上 pid_t 是 *anyopaque,不能 {d} 格式化。
    // 路径走 tempDir 而非硬编码 /tmp:Windows 无 /tmp(靠盘根 \tmp 恰好存在是假绿,review F2)。
    const pid = @import("platform").process.currentPid();
    const tmp = @import("platform").paths.tempDir();
    const dir = std.fmt.bufPrintZ(buf, "{s}/cc-zig-l3-{d}", .{ tmp, pid }) catch unreachable;
    _ = pfs.mkdir(dir.ptr, 0o755);
    return dir;
}

fn clearSession(dir: []const u8) void {
    var b: [300]u8 = undefined;
    inline for (.{ "transcript.jsonl", "meta.json", "suspend.json" }) |f| {
        const p = std.fmt.bufPrintZ(&b, "{s}/{s}", .{ dir, f }) catch return;
        pfs.unlinkPath(p.ptr) catch {};
    }
}

fn hasToolUse(conv: *const cc.conversation.Conversation, id: []const u8) bool {
    for (conv.messages.items) |m| for (m.blocks) |blk| switch (blk) {
        .tool_use => |tu| if (std.mem.eql(u8, tu.id, id)) return true,
        else => {},
    };
    return false;
}

fn hasToolResult(conv: *const cc.conversation.Conversation, id: []const u8) bool {
    for (conv.messages.items) |m| for (m.blocks) |blk| switch (blk) {
        .tool_result => |tr| if (std.mem.eql(u8, tr.tool_use_id, id)) return true,
        else => {},
    };
    return false;
}
