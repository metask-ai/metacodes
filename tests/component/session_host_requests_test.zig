//! L2 (#446): UI requests on a long-lived SessionHost, driven the way a
//! network Host drives it. A question asked before a restart is answered
//! after it under its id and its Run resumes once; work submitted while a
//! request is open waits behind it and the snapshot says why; a permission
//! request still blocks under the suspend mode, never denied unasked; the
//! approver an answer names is on its `ui_request_closed`; an unanswered
//! request gets the declared expiry; an interrupt cancels a suspended
//! request; a second or late answer changes nothing.
//!
//! Cross-module: session_host + ui_request_store + suspend_state +
//! agent_session (AdmittedRun.resumeWithResults) + agent_loop + permission
//! + protocol.wire + transcript + AskUserQuestion / Write tools.

const std = @import("std");
const pfs = @import("platform").fs;
const harness = @import("harness");
const cc = @import("cc");

const SessionHost = cc.session_host.SessionHost;
const HostedSession = cc.session_host.HostedSession;
const EventJournal = cc.event_journal.EventJournal;
const Phase = cc.session_host.Phase;
const QueueWaiting = cc.session_host.QueueWaiting;

const TOOLS = [_][]const u8{ "AskUserQuestion", "Write" };

/// The model asks one question (call `tu_q`).
const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_q\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_q\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Ship now?\\\",\\\"header\\\":\\\"Decision\\\",\\\"options\\\":[{\\\"label\\\":\\\"Ship\\\",\\\"description\\\":\\\"Release now\\\"},{\\\"label\\\":\\\"Wait\\\",\\\"description\\\":\\\"Hold the release\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn textSse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_t\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{text});
}

fn writeToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_w\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_w\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"content\\\":\\\"host\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

fn subdir(tmp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, name);
    var sub = try tmp.dir.openDir(std.testing.io, name, .{});
    defer sub.close(std.testing.io);
    const len = try sub.realPath(std.testing.io, buffer);
    for (buffer[0..len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buffer[0..len];
}

fn exists(dir: []const u8, name: []const u8) !bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name });
    return pfs.exists(path.ptr);
}

/// Waits until `needle` occurs in at least `count` journal lines.
fn waitFor(journal: *EventJournal, needle: []const u8, count: usize) !void {
    const a = std.testing.allocator;
    var waited: u64 = 0;
    while (waited < 10_000) : (waited += 20) {
        if (try countLines(journal, needle) >= count) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
    }
    _ = a;
    std.debug.print("journal never showed {d}x {s}\n", .{ count, needle });
    return error.JournalTimeout;
}

fn countLines(journal: *EventJournal, needle: []const u8) !usize {
    const a = std.testing.allocator;
    const lines = (try journal.waitSince(a, 0, 1)) orelse return 0;
    defer {
        for (lines) |line| a.free(line);
        a.free(lines);
    }
    var seen: usize = 0;
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) seen += 1;
    }
    return seen;
}

/// The position of the first journal line containing `needle`.
fn lineIndex(journal: *EventJournal, needle: []const u8) !usize {
    const a = std.testing.allocator;
    const lines = (try journal.waitSince(a, 0, 1)) orelse return error.NoSuchLine;
    defer {
        for (lines) |line| a.free(line);
        a.free(lines);
    }
    for (lines, 0..) |line, index| {
        if (std.mem.indexOf(u8, line, needle) != null) return index;
    }
    return error.NoSuchLine;
}

/// A copy of the first journal line containing `needle`.
fn lineWith(journal: *EventJournal, needle: []const u8) ![]u8 {
    const a = std.testing.allocator;
    const lines = (try journal.waitSince(a, 0, 1)) orelse return error.NoSuchLine;
    defer {
        for (lines) |line| a.free(line);
        a.free(lines);
    }
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return a.dupe(u8, line);
    }
    return error.NoSuchLine;
}

fn baseConfig(url: []const u8, workspace: []const u8, home: []const u8) cc.agent_session.SessionConfig {
    return .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .default,
        .workspace = .{ .root = workspace, .home = home },
        .allowed_tools = &TOOLS,
    };
}

fn expectSnapshot(hosted: *HostedSession, phase: Phase, pending: u64, queued: usize, waiting: QueueWaiting) !void {
    const a = std.testing.allocator;
    var snapshot = try hosted.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqual(phase, snapshot.phase);
    try std.testing.expectEqual(pending, snapshot.pending_request_id);
    try std.testing.expectEqual(queued, snapshot.queued);
    try std.testing.expectEqual(waiting, snapshot.queue_waiting);
}

const Dirs = struct {
    tmp: std.testing.TmpDir,
    ws_buf: [std.fs.max_path_bytes]u8 = undefined,
    home_buf: [std.fs.max_path_bytes]u8 = undefined,
    workspace: []const u8 = "",
    home: []const u8 = "",

    fn init(self: *Dirs) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        self.workspace = try subdir(&self.tmp, "workspace", &self.ws_buf);
        self.home = try subdir(&self.tmp, "home", &self.home_buf);
    }
};

test "L2 #446 SessionHost suspend mode: a question open across a restart is answered under its id; the Run resumes once with its own settings and its Write runs once" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const path = try std.fmt.allocPrint(a, "{s}/after-answer.txt", .{dirs.workspace});
    defer a.free(path);
    const write = try writeToolSse(a, path);
    defer a.free(write);
    const done = try textSse(a, "done");
    defer a.free(done);
    const bodies = [_][]const u8{ ASK_SSE, write, done };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;
    var config = baseConfig(url, dirs.workspace, dirs.home);
    config.permission_mode = .accept_edits;

    // Process 1: the question suspends its Run; nothing holds the driver.
    var id: cc.session_id.SessionId = undefined;
    const announcement = blk: {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend", .max_turns = 1 });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config });
        defer host.release(hosted);
        id = hosted.id;
        try hosted.submit(.{ .text = "ask before writing", .trace_id = "t-446" });
        try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);
        try expectSnapshot(hosted, .suspended, 1, 0, .none);
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"ui_request_closed\""));
        break :blk try lineWith(&hosted.journal, "{\"v\":1,\"type\":\"ui_request\",\"id\":1,\"kind\":\"ask_question\"");
    };
    defer a.free(announcement);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());

    // Process 2, with a larger turn limit: the request is announced again,
    // the same bytes under the same id, and answered there.
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend", .max_turns = 400 });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
        defer host.release(hosted);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, announcement));
        try expectSnapshot(hosted, .suspended, 1, 0, .none);
        try std.testing.expectError(error.NoSuchRequest, hosted.respond(2, "{\"answers\":[\"Ship\"]}"));
        try std.testing.expectError(error.InvalidApprover, hosted.respond(1, "{\"answers\":[\"Ship\"],\"by\":\"\"}"));
        try hosted.respond(1, "{\"answers\":[\"Ship\"],\"by\":\"alice@example.com\"}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);

        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"answered\",\"by\":\"alice@example.com\"}"));
        // Run 1 of this journal resumes the suspended Run, keeping its trace.
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"run_resumed\",\"data\":{\"run_id\":1,\"trace_id\":\"t-446\",\"request_id\":1}}"));
        try std.testing.expect(try lineIndex(&hosted.journal, "\"type\":\"ui_request_closed\"") < try lineIndex(&hosted.journal, "\"type\":\"run_resumed\""));
        // The suspended Run's one-turn limit, not this host's 400: the Write
        // turn is the resumed Run's only one.
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":1,\"trace_id\":\"t-446\",\"stop_reason\":\"max_turns\""));
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"tool_result\",\"run_id\":1"));
        // The answer reached the model as AskUserQuestion's result.
        const resumed = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, resumed, "tu_q") != null);
        try std.testing.expect(std.mem.indexOf(u8, resumed, "{\\\"answers\\\":[\\\"Ship\\\"]}") != null);
        try expectSnapshot(hosted, .idle, 0, 0, .none);
        // Consumed: the same answer again changes nothing.
        try std.testing.expectError(error.NoSuchRequest, hosted.respond(1, "{\"answers\":[\"Ship\"]}"));
    }
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    try std.testing.expect(try exists(dirs.workspace, "after-answer.txt"));

    // Process 3: nothing is left to resume, and the old id stays closed.
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
        defer host.release(hosted);
        try expectSnapshot(hosted, .idle, 0, 0, .none);
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"ui_request\""));
        try std.testing.expectError(error.NoSuchRequest, hosted.respond(1, "{\"answers\":[\"Ship\"]}"));
    }
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
}

test "L2 #446 SessionHost: work submitted while a request is open waits behind it, and the snapshot says why" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;

    // A blocking permission request (the default).
    {
        const path = try std.fmt.allocPrint(a, "{s}/first.txt", .{dirs.workspace});
        defer a.free(path);
        const write = try writeToolSse(a, path);
        defer a.free(write);
        const done = try textSse(a, "written");
        defer a.free(done);
        const second = try textSse(a, "second done");
        defer a.free(second);
        const bodies = [_][]const u8{ write, done, second };
        var server = try harness.MockServer.startCassette(&bodies, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var host = SessionHost.init(a, runtime, .{ .transcripts = false });
        defer host.deinit();
        const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
        defer host.release(hosted);

        try hosted.submit(.{ .text = "write it" });
        try waitFor(&hosted.journal, "\"type\":\"ui_request\"", 1);
        try hosted.submit(.{ .text = "then this" });
        try expectSnapshot(hosted, .running, 1, 1, .ui_request);
        try hosted.respond(1, "{\"choice\":\"allow_once\"}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
        try std.testing.expect(try lineIndex(&hosted.journal, "\"type\":\"run_done\",\"data\":{\"run_id\":1") <
            try lineIndex(&hosted.journal, "\"type\":\"user_message\",\"data\":{\"run_id\":2"));
        try expectSnapshot(hosted, .idle, 0, 0, .none);
        try std.testing.expect(try exists(dirs.workspace, "first.txt"));
    }

    // A suspended question: the driver is free, and still nothing jumps it.
    {
        const thanks = try textSse(a, "thanks");
        defer a.free(thanks);
        const next = try textSse(a, "next done");
        defer a.free(next);
        const bodies = [_][]const u8{ ASK_SSE, thanks, next };
        var server = try harness.MockServer.startCassette(&bodies, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
        defer host.release(hosted);

        try hosted.submit(.{ .text = "ask me" });
        try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);
        try hosted.submit(.{ .text = "and then this" });
        try hosted.command(.{ .set_permission_mode = .accept_edits });
        try expectSnapshot(hosted, .suspended, 1, 2, .ui_request);
        try std.testing.expectEqual(@as(usize, 1), server.requestCount());
        try hosted.respond(1, "{\"answers\":[\"Wait\"]}");
        try waitFor(&hosted.journal, "\"type\":\"command_result\"", 1);
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 3);
        // The resumed Run first, then the queue in its order.
        const resumed_done = try lineIndex(&hosted.journal, "\"type\":\"run_done\",\"data\":{\"run_id\":2");
        try std.testing.expect(try lineIndex(&hosted.journal, "\"type\":\"run_resumed\",\"data\":{\"run_id\":2") < resumed_done);
        try std.testing.expect(resumed_done < try lineIndex(&hosted.journal, "\"type\":\"user_message\",\"data\":{\"run_id\":3"));
        try expectSnapshot(hosted, .idle, 0, 0, .none);
    }
}

test "L2 #446 SessionHost suspend mode: a permission request still blocks and is answered, never denied unasked; its approver is recorded" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const path = try std.fmt.allocPrint(a, "{s}/approved.txt", .{dirs.workspace});
    defer a.free(path);
    const write = try writeToolSse(a, path);
    defer a.free(write);
    const done = try textSse(a, "done");
    defer a.free(done);
    const bodies = [_][]const u8{ write, done };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
    defer host.release(hosted);

    try hosted.submit(.{ .text = "write it" });
    try waitFor(&hosted.journal, "\"type\":\"ui_request\",\"id\":1,\"kind\":\"permission\"", 1);
    // The Run holds its driver on the prompt: running, not suspended.
    std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake) catch {};
    try expectSnapshot(hosted, .running, 1, 0, .none);
    var snapshot = try hosted.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqual(cc.session_host.UiRequestWait.@"suspend", snapshot.ui_request_wait);
    try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"ui_request_closed\""));
    try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"run_done\""));
    try std.testing.expect(!try exists(dirs.workspace, "approved.txt"));

    // An approver that is not one is refused; the request stays open.
    try std.testing.expectError(error.InvalidApprover, hosted.respond(1, "{\"choice\":\"allow_once\",\"by\":7}"));
    try expectSnapshot(hosted, .running, 1, 0, .none);
    try hosted.respond(1, "{\"choice\":\"allow_once\",\"by\":\"oncall@example.com\"}");
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"answered\",\"by\":\"oncall@example.com\"}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"stop_reason\":\"end_turn\""));
    try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"stop_reason\":\"suspended\""));
    try std.testing.expect(try exists(dirs.workspace, "approved.txt"));
}

test "L2 #446 SessionHost expiry: interrupt stops the Run, re_announce repeats the request until answered, blocking or suspended; cancel resumes a suspended question without its answer" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;

    // `.interrupt`: the unanswered prompt is cancelled and the Run stops there.
    {
        const path = try std.fmt.allocPrint(a, "{s}/stopped.txt", .{dirs.workspace});
        defer a.free(path);
        const write = try writeToolSse(a, path);
        defer a.free(write);
        const done = try textSse(a, "carried on");
        defer a.free(done);
        const bodies = [_][]const u8{ write, done };
        var server = try harness.MockServer.startCassette(&bodies, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var host = SessionHost.init(a, runtime, .{ .transcripts = false, .ui_request_timeout_ms = 100, .ui_request_expiry = .interrupt });
        defer host.deinit();
        const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
        defer host.release(hosted);
        var snapshot = try hosted.snapshot(a);
        defer snapshot.deinit(a);
        try std.testing.expectEqual(cc.session_host.UiRequestExpiry.interrupt, snapshot.ui_request_expiry);
        try std.testing.expectEqual(@as(?u64, 100), snapshot.ui_request_timeout_ms);

        try hosted.submit(.{ .text = "write it" });
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\"}"));
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"stop_reason\":\"aborted\""));
        try std.testing.expectEqual(@as(usize, 1), server.requestCount());
        try std.testing.expect(!try exists(dirs.workspace, "stopped.txt"));
    }

    // `.re_announce`: the same line again each period, until someone answers.
    {
        const path = try std.fmt.allocPrint(a, "{s}/escalated.txt", .{dirs.workspace});
        defer a.free(path);
        const write = try writeToolSse(a, path);
        defer a.free(write);
        const done = try textSse(a, "done");
        defer a.free(done);
        const bodies = [_][]const u8{ write, done };
        var server = try harness.MockServer.startCassette(&bodies, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var host = SessionHost.init(a, runtime, .{ .transcripts = false, .ui_request_timeout_ms = 50, .ui_request_expiry = .re_announce });
        defer host.deinit();
        const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
        defer host.release(hosted);

        try hosted.submit(.{ .text = "write it" });
        try waitFor(&hosted.journal, "\"type\":\"ui_request\",\"id\":1,", 3);
        const line = try lineWith(&hosted.journal, "\"type\":\"ui_request\",\"id\":1,");
        defer a.free(line);
        try std.testing.expect(try countLines(&hosted.journal, line) >= 3);
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"ui_request_closed\""));
        try hosted.respond(1, "{\"choice\":\"allow_once\"}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"answered\"}"));
        try std.testing.expect(try exists(dirs.workspace, "escalated.txt"));
    }

    // `.cancel` on a suspended question: it resumes with the call aborted,
    // as an unanswered question is answered under `.block`, and goes on.
    {
        const after = try textSse(a, "asked in words instead");
        defer a.free(after);
        const bodies = [_][]const u8{ ASK_SSE, after };
        var server = try harness.MockServer.startCassette(&bodies, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend", .ui_request_timeout_ms = 100 });
        defer host.deinit();
        const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
        defer host.release(hosted);

        try hosted.submit(.{ .text = "ask me" });
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"stop_reason\":\"suspended\""));
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\"}"));
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"run_resumed\",\"data\":{\"run_id\":2,"));
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
        const resumed = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, resumed, "AskUserQuestion failed with InputAborted") != null);
    }

    // `.re_announce` on a suspended question: the idle driver announces it
    // again each period, and an answer still resumes the Run once.
    {
        const thanks = try textSse(a, "thanks");
        defer a.free(thanks);
        const bodies = [_][]const u8{ ASK_SSE, thanks };
        var server = try harness.MockServer.startCassette(&bodies, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend", .ui_request_timeout_ms = 50, .ui_request_expiry = .re_announce });
        defer host.deinit();
        const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
        defer host.release(hosted);

        try hosted.submit(.{ .text = "ask me" });
        try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);
        const line = try lineWith(&hosted.journal, "{\"v\":1,\"type\":\"ui_request\",\"id\":1,");
        defer a.free(line);
        try waitFor(&hosted.journal, line, 3);
        try expectSnapshot(hosted, .suspended, 1, 0, .none);
        try std.testing.expectEqual(@as(usize, 1), server.requestCount());
        try hosted.respond(1, "{\"answers\":[\"Ship\"]}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"answered\"}"));
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
        try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    }

    // `.interrupt` on a suspended question: it resumes only to record the
    // cancellation, with no provider request, and stops.
    {
        const unused = try textSse(a, "never sent");
        defer a.free(unused);
        const bodies = [_][]const u8{ ASK_SSE, unused };
        var server = try harness.MockServer.startCassette(&bodies, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend", .ui_request_timeout_ms = 100, .ui_request_expiry = .interrupt });
        defer host.deinit();
        const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
        defer host.release(hosted);

        try hosted.submit(.{ .text = "ask me" });
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\"}"));
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"aborted\""));
        try std.testing.expectEqual(@as(usize, 1), server.requestCount());
        try expectSnapshot(hosted, .idle, 0, 0, .none);
    }
}

test "L2 #446 SessionHost suspend mode: an interrupt cancels the suspended question; the Run resumes only to record it, and the Session goes on" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const later = try textSse(a, "hello again");
    defer a.free(later);
    const bodies = [_][]const u8{ ASK_SSE, later };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
    defer host.release(hosted);

    try hosted.submit(.{ .text = "ask me" });
    try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);
    try std.testing.expectEqual(cc.session_host.InterruptOutcome.requested, hosted.interrupt());
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\"}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"aborted\""));
    // No provider request for the resumed Run: it only recorded the result.
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    try expectSnapshot(hosted, .idle, 0, 0, .none);
    try std.testing.expectError(error.NoSuchRequest, hosted.respond(1, "{\"answers\":[\"Ship\"]}"));

    // The next Run's conversation pairs the cancelled call with its result.
    try hosted.submit(.{ .text = "hello" });
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 3);
    const next = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, next, "AskUserQuestion failed with InputAborted") != null);
}

const SecondAnswer = struct {
    var refused: ?anyerror = null;
    var ran = false;

    fn tryAgain(hosted: *HostedSession) void {
        ran = true;
        hosted.respond(1, "{\"answers\":[\"Wait\"],\"by\":\"bob\"}") catch |err| {
            refused = err;
        };
    }
};

test "L2 #446 SessionHost suspend mode: a second answer is AlreadyAnswered, a late one NoSuchRequest, a fresh open drops the suspension; none of them changes anything" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const thanks = try textSse(a, "thanks");
    defer a.free(thanks);
    const bodies = [_][]const u8{ ASK_SSE, thanks, ASK_SSE, ASK_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;
    const config = baseConfig(url, dirs.workspace, dirs.home);

    var id: cc.session_id.SessionId = undefined;
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config });
        defer host.release(hosted);
        id = hosted.id;
        try hosted.submit(.{ .text = "ask me" });
        try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);

        SecondAnswer.refused = null;
        SecondAnswer.ran = false;
        cc.session_host.testing_hooks.before_resumption = SecondAnswer.tryAgain;
        defer cc.session_host.testing_hooks.before_resumption = null;
        try hosted.respond(1, "{\"answers\":[\"Ship\"],\"by\":\"alice\"}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
        try std.testing.expect(SecondAnswer.ran);
        try std.testing.expectEqual(@as(?anyerror, error.AlreadyAnswered), SecondAnswer.refused);
        // The first answer is the one applied and recorded.
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"answered\",\"by\":\"alice\""));
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"by\":\"bob\""));
        const resumed = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, resumed, "{\\\"answers\\\":[\\\"Ship\\\"]}") != null);
        try std.testing.expectError(error.NoSuchRequest, hosted.respond(1, "{\"answers\":[\"Wait\"]}"));

        // Another question suspends; it is left open at close.
        try hosted.submit(.{ .text = "ask again" });
        try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 2);
        try expectSnapshot(hosted, .suspended, 2, 0, .none);
    }
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());

    // A fresh open under the id replaces the conversation: the suspension
    // goes with it, the request ids go on.
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config, .id = id });
        defer host.release(hosted);
        try expectSnapshot(hosted, .idle, 0, 0, .none);
        try std.testing.expectError(error.NoSuchRequest, hosted.respond(2, "{\"answers\":[\"Ship\"]}"));
        try hosted.submit(.{ .text = "ask anew" });
        try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request\",\"id\":3,"));
        try expectSnapshot(hosted, .suspended, 3, 0, .none);
    }
    try std.testing.expectEqual(@as(usize, 4), server.requestCount());
}

test "L2 #446 SessionHost: a question cancelled by its expiry fails its call, not the Session" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const after = try textSse(a, "asked in words instead");
    defer a.free(after);
    const later = try textSse(a, "still here");
    defer a.free(later);
    const bodies = [_][]const u8{ ASK_SSE, after, later };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;
    // The defaults but for a timeout: the question blocks, then is cancelled.
    var host = SessionHost.init(a, runtime, .{ .transcripts = false, .ui_request_timeout_ms = 100 });
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
    defer host.release(hosted);

    try hosted.submit(.{ .text = "ask me" });
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\"}"));
    try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"session_poisoned\""));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
    const next = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, next, "AskUserQuestion failed with InputAborted") != null);
    // The Session takes more work.
    try hosted.submit(.{ .text = "hello" });
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
}
