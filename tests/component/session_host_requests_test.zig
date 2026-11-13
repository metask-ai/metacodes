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

const TURN_START =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_q\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";
/// Call `tu_q`, content block 0: AskUserQuestion with one question.
const QUESTION_BLOCK =
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_q\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Ship now?\\\",\\\"header\\\":\\\"Decision\\\",\\\"options\\\":[{\\\"label\\\":\\\"Ship\\\",\\\"description\\\":\\\"Release now\\\"},{\\\"label\\\":\\\"Wait\\\",\\\"description\\\":\\\"Hold the release\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n";
const TOOL_TURN_END =
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// The model asks one question (call `tu_q`).
const ASK_SSE = TURN_START ++ QUESTION_BLOCK ++ TOOL_TURN_END;

/// One turn of three calls: the question (`tu_q`), a Write (`tu_w`) and a
/// Read (`tu_r`).
fn mixedTurnSse(allocator: std.mem.Allocator, write_path: []const u8, read_path: []const u8) ![]u8 {
    const write_block = try std.fmt.allocPrint(allocator, "data: {{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_w\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"content\\\":\\\"beside\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":1}}\n\n", .{write_path});
    defer allocator.free(write_block);
    const read_block = try std.fmt.allocPrint(allocator, "data: {{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_r\",\"name\":\"Read\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":2}}\n\n", .{read_path});
    defer allocator.free(read_block);
    return std.mem.concat(allocator, u8, &.{ TURN_START, QUESTION_BLOCK, write_block, read_block, TOOL_TURN_END });
}

/// The directory `SessionHost` keeps Session `id` in.
fn sessionDirOf(a: std.mem.Allocator, config: cc.agent_session.SessionConfig, id: cc.session_id.SessionId) ![]u8 {
    var policy = try cc.workspace_policy.WorkspacePolicy.init(a, config.workspace);
    defer policy.deinit();
    return cc.transcript.sessionDir(a, policy.stateRoot(), policy.root, id);
}

fn readFileIn(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20));
}

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

fn toolCallSse(comptime id: []const u8, comptime name: []const u8, comptime input_json: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" ++ input_json ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

test "L2 #446 SessionHost suspend mode: a suspended team lead runs nothing and leaves its inbox unread; queued work, then the mail, run once it resumes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try subdir(&tmp, "team", &root_buf);

    const formed = try textSse(a, "formed");
    defer a.free(formed);
    const thanks = try textSse(a, "thanks");
    defer a.free(thanks);
    const queued_reply = try textSse(a, "queued one done");
    defer a.free(queued_reply);
    const ack = try textSse(a, "ack");
    defer a.free(ack);
    // Run 1 forms the team; Run 2 asks and suspends; the resumed Run, the
    // submission queued meanwhile, then the teammate's mail.
    const lead_bodies = [_][]const u8{ toolCallSse("t1", "TeamCreate", "{\\\"name\\\":\\\"crew\\\"}"), formed, ASK_SSE, thanks, queued_reply, ack };
    var lead_srv = try harness.MockServer.startCassette(&lead_bodies, 0);
    defer lead_srv.stop();
    const lead_url = try lead_srv.urlOwned(a);
    defer a.free(lead_url);
    const idle = try textSse(a, "idle");
    defer a.free(idle);
    const member_bodies = [_][]const u8{
        toolCallSse("s1", "SendMessage", "{\\\"to\\\":\\\"team-lead\\\",\\\"message\\\":\\\"done: 42\\\",\\\"summary\\\":\\\"done\\\"}"),
        idle,
    };
    var member_srv = try harness.MockServer.startCassette(&member_bodies, 0);
    defer member_srv.stop();
    const member_url = try member_srv.urlOwned(a);
    defer a.free(member_url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"AskUserQuestion"}, .enable_teams = true });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
    defer host.deinit();
    var lead_config = baseConfig(lead_url, root, root);
    lead_config.allowed_tools = &.{ "TeamCreate", "SendMessage", "AskUserQuestion" };
    lead_config.permission_mode = .bypass_permissions;
    lead_config.workspace = .{ .root = root, .home = root, .state_root = root, .shell = .disabled };
    lead_config.team = .{ .role = .lead, .team_name = "" };
    const lead = try host.open(.{ .config = lead_config });
    defer host.release(lead);

    try lead.submit(.{ .text = "form a team" });
    try waitFor(&lead.journal, "\"type\":\"run_done\"", 1);
    try lead.submit(.{ .text = "ask me" });
    try waitFor(&lead.journal, "\"stop_reason\":\"suspended\"", 1);

    // The member reports to the lead while the lead is suspended.
    var member_config = baseConfig(member_url, root, root);
    member_config.allowed_tools = &.{"SendMessage"};
    member_config.permission_mode = .bypass_permissions;
    member_config.workspace = lead_config.workspace;
    const lease = cc.session_id.gen();
    member_config.team = .{
        .role = .member,
        .team_name = "crew",
        .member_name = "solver",
        .lead_session_id = lead.id.asSlice(),
        .member_lease = lease.asSlice(),
    };
    const member = try host.open(.{ .config = member_config });
    defer host.release(member);
    try member.submit(.{ .text = "work and report" });
    try waitFor(&member.journal, "\"type\":\"run_done\"", 1);
    try lead.submit(.{ .text = "and then this" });

    // Several poll periods pass: the suspended lead starts nothing, and its
    // inbox is not read (read mail would have been queued as a submission).
    std.Io.sleep(std.testing.io, .fromMilliseconds(3 * cc.session_host.lead_inbox_poll_ms), .awake) catch {};
    try expectSnapshot(lead, .suspended, 1, 1, .ui_request);
    try std.testing.expectEqual(@as(usize, 2), try countLines(&lead.journal, "\"type\":\"user_message\""));
    try std.testing.expectEqual(@as(usize, 0), try countLines(&lead.journal, "done: 42"));
    try std.testing.expectEqual(@as(usize, 3), lead_srv.requestCount());

    // Answered: the suspended Run resumes, then the queued submission, then
    // the mail, once each.
    try lead.respond(1, "{\"answers\":[\"Ship\"]}");
    try waitFor(&lead.journal, "\"type\":\"run_done\"", 5);
    const resumed = try lineIndex(&lead.journal, "\"type\":\"run_resumed\",\"data\":{\"run_id\":3");
    const queued = try lineIndex(&lead.journal, "\"type\":\"user_message\",\"data\":{\"run_id\":4,\"trace_id\":null,\"text\":\"and then this\"");
    const mail = try lineIndex(&lead.journal, "\"type\":\"user_message\",\"data\":{\"run_id\":5");
    try std.testing.expect(resumed < queued);
    try std.testing.expect(queued < mail);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&lead.journal, "done: 42"));
    try std.testing.expectEqual(@as(usize, 6), lead_srv.requestCount());
    const request = lead_srv.requestAt(5).?;
    try std.testing.expect(std.mem.indexOf(u8, request.body(), "done: 42") != null);
    std.Io.sleep(std.testing.io, .fromMilliseconds(3 * cc.session_host.lead_inbox_poll_ms), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 1), try countLines(&lead.journal, "done: 42"));
}

test "L2 #446 SessionHost suspend mode: a question asked beside other calls; across a restart every call of the turn gets its result, and what ran ran once" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const write_path = try std.fmt.allocPrint(a, "{s}/beside.txt", .{dirs.workspace});
    defer a.free(write_path);
    const read_path = try std.fmt.allocPrint(a, "{s}/secret.txt", .{dirs.workspace});
    defer a.free(read_path);
    const mixed = try mixedTurnSse(a, write_path, read_path);
    defer a.free(mixed);
    const done = try textSse(a, "done");
    defer a.free(done);
    const bodies = [_][]const u8{ mixed, done };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const tools = [_][]const u8{ "AskUserQuestion", "Write", "Read" };
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &tools });
    defer runtime.destroy() catch unreachable;
    var config = baseConfig(url, dirs.workspace, dirs.home);
    config.allowed_tools = &tools;
    // The Write runs (in the workspace); the Read is denied by a rule.
    config.permission_mode = .accept_edits;

    var id: cc.session_id.SessionId = undefined;
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config });
        defer host.release(hosted);
        id = hosted.id;
        try hosted.command(.{ .update_permission_rules = .{ .deny = &.{"Read"} } });
        try hosted.submit(.{ .text = "do three things" });
        try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"tool_start\",\"run_id\":1,\"data\":{\"id\":\"tu_w\""));
    }
    try std.testing.expect(try exists(dirs.workspace, "beside.txt"));
    try std.testing.expect(!try exists(dirs.workspace, "secret.txt"));

    // What the Session's directory holds: one self-sufficient record.
    const dir = try sessionDirOf(a, config, id);
    defer a.free(dir);
    try std.testing.expect(!try exists(dir, "suspend.json"));
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const state = (try cc.ui_request_store.load(arena.allocator(), dir)).?;
        const held = state.suspended.?;
        try std.testing.expectEqualStrings("tu_q", held.tool_use_id);
        try std.testing.expectEqual(@as(usize, 2), held.completed.len);
        try std.testing.expectEqualStrings("tu_w", held.completed[0].tool_use_id);
        try std.testing.expect(!held.completed[0].is_error);
        try std.testing.expectEqualStrings("tu_r", held.completed[1].tool_use_id);
        try std.testing.expect(held.completed[1].is_error);
        try std.testing.expect(std.mem.indexOf(u8, held.completed[1].content, "Read did not run") != null);
    }

    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
        defer host.release(hosted);
        try hosted.respond(1, "{\"answers\":[\"Ship\"]}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
        // Nothing ran again on resume.
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"tool_start\""));
    }
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    // The resumed request answers all three calls itself, none by the
    // request builder's stand-in.
    const resumed = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    for ([_][]const u8{ "tu_q", "tu_w", "tu_r", "Read did not run" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, resumed, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, resumed, "tool_use had no result") == null);
    // So does the transcript: one result for each call.
    const transcript = try readFileIn(a, dir, "transcript.jsonl");
    defer a.free(transcript);
    for ([_][]const u8{ "\"tool_use_id\":\"tu_q\"", "\"tool_use_id\":\"tu_w\"", "\"tool_use_id\":\"tu_r\"" }) |needle| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, transcript, needle));
    }
    const written = try readFileIn(a, dirs.workspace, "beside.txt");
    defer a.free(written);
    try std.testing.expectEqualStrings("beside", written);
}

test "L2 #446 SessionHost suspend mode: the transcript is the witness; a recorded answer is applied once after a crash, and never again once it was" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const after = try textSse(a, "after the answer");
    defer a.free(after);
    const bodies = [_][]const u8{ ASK_SSE, after };
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
    }
    const dir = try sessionDirOf(a, config, id);
    defer a.free(dir);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var state = (try cc.ui_request_store.load(arena.allocator(), dir)).?;
    // What the disk holds when the answer was recorded and the process
    // stopped before the resumed Run was written.
    state.suspended.?.settled = .{ .outcome = .answered, .answer = "{\"answers\":[\"Wait\"]}", .by = "carol" };
    try cc.ui_request_store.store(a, dir, state);

    // The next open applies it, once.
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
        defer host.release(hosted);
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"answered\",\"by\":\"carol\"}"));
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"run_resumed\",\"data\":{\"run_id\":1,"));
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
    }
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const resumed = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, resumed, "{\\\"answers\\\":[\\\"Wait\\\"]}") != null);
    try std.testing.expect((try cc.ui_request_store.load(arena.allocator(), dir)).?.suspended == null);

    // What the disk holds when the resumed Run was written and the process
    // stopped before the record was cleared: the transcript already has the
    // call's result, so the next open only drops the record.
    try cc.ui_request_store.store(a, dir, state);
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
        defer host.release(hosted);
        std.Io.sleep(std.testing.io, .fromMilliseconds(200), .awake) catch {};
        try expectSnapshot(hosted, .idle, 0, 0, .none);
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"ui_request"));
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"run_resumed\""));
        try std.testing.expectError(error.NoSuchRequest, hosted.respond(1, "{\"answers\":[\"Wait\"]}"));
    }
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    try std.testing.expect((try cc.ui_request_store.load(arena.allocator(), dir)).?.suspended == null);
    const transcript = try readFileIn(a, dir, "transcript.jsonl");
    defer a.free(transcript);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, transcript, "\"tool_use_id\":\"tu_q\""));
}

const Handover = struct {
    var ran = false;
    var refused: ?anyerror = null;

    fn answer(hosted: *HostedSession) void {
        ran = true;
        hosted.respond(1, "{\"answers\":[\"Ship\"],\"by\":\"bot\"}") catch |err| {
            refused = err;
        };
    }
};

test "L2 #446 SessionHost suspend mode: an answer that arrives while the suspension is being held reaches its request, and no later request takes it" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const thanks = try textSse(a, "thanks");
    defer a.free(thanks);
    const path = try std.fmt.allocPrint(a, "{s}/later.txt", .{dirs.workspace});
    defer a.free(path);
    const write = try writeToolSse(a, path);
    defer a.free(write);
    const done = try textSse(a, "done");
    defer a.free(done);
    const bodies = [_][]const u8{ ASK_SSE, thanks, write, done };
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

    Handover.ran = false;
    Handover.refused = null;
    cc.session_host.testing_hooks.before_handover = Handover.answer;
    defer cc.session_host.testing_hooks.before_handover = null;
    try hosted.submit(.{ .text = "ask me" });
    // The answer given in the window resumes the Run, by itself.
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
    try std.testing.expect(Handover.ran);
    try std.testing.expect(Handover.refused == null);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"answered\",\"by\":\"bot\"}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
    cc.session_host.testing_hooks.before_handover = null;

    // The next request, a permission, waits for its own answer.
    try hosted.submit(.{ .text = "write it" });
    try waitFor(&hosted.journal, "\"type\":\"ui_request\",\"id\":2,\"kind\":\"permission\"", 1);
    std.Io.sleep(std.testing.io, .fromMilliseconds(150), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"ui_request_closed\",\"id\":2"));
    try expectSnapshot(hosted, .running, 2, 0, .none);
    try hosted.respond(2, "{\"choice\":\"allow_once\"}");
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 3);
    try std.testing.expect(try exists(dirs.workspace, "later.txt"));
}

/// A Bash call that leaves `sleep 30` running as a background job.
fn backgroundSse(comptime id: []const u8, comptime index: []const u8) []const u8 {
    return "data: {\"type\":\"content_block_start\",\"index\":" ++ index ++ ",\"content_block\":{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":" ++ index ++ ",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"sleep 30\\\",\\\"run_in_background\\\":true}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":" ++ index ++ "}\n\n";
}

/// The question as content block 1.
const QUESTION_BLOCK_1 =
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_q\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Ship now?\\\",\\\"header\\\":\\\"Decision\\\",\\\"options\\\":[{\\\"label\\\":\\\"Ship\\\",\\\"description\\\":\\\"Release now\\\"},{\\\"label\\\":\\\"Wait\\\",\\\"description\\\":\\\"Hold the release\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n";

test "L2 #446 SessionHost suspend mode: with a background job running, the suspended turn and the resumed Run are still written, and nothing is applied twice" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const suspended_turn = comptime TURN_START ++ backgroundSse("tu_b", "0") ++ QUESTION_BLOCK_1 ++ TOOL_TURN_END;
    const resumed_turn = comptime TURN_START ++ backgroundSse("tu_b2", "0") ++ TOOL_TURN_END;
    const done = try textSse(a, "done");
    defer a.free(done);
    const bodies = [_][]const u8{ suspended_turn, resumed_turn, done };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const tools = [_][]const u8{ "AskUserQuestion", "Bash" };
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &tools });
    defer runtime.destroy() catch unreachable;
    var config = baseConfig(url, dirs.workspace, dirs.home);
    config.allowed_tools = &tools;
    config.permission_mode = .bypass_permissions;
    config.workspace.shell = .unrestricted;

    var id: cc.session_id.SessionId = undefined;
    var dir: []u8 = &.{};
    defer a.free(dir);
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config });
        defer host.release(hosted);
        id = hosted.id;
        dir = try sessionDirOf(a, config, id);
        try hosted.submit(.{ .text = "start it, then ask" });
        try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);
        // The job still runs; the suspended turn is written all the same.
        const transcript = try readFileIn(a, dir, "transcript.jsonl");
        defer a.free(transcript);
        try std.testing.expect(std.mem.indexOf(u8, transcript, "\"tu_q\"") != null);
        {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const held = (try cc.ui_request_store.load(arena.allocator(), dir)).?.suspended.?;
            try std.testing.expectEqualStrings("AskUserQuestion", held.tool_name);
            try std.testing.expectEqual(@as(usize, 1), held.completed.len);
            try std.testing.expectEqualStrings("tu_b", held.completed[0].tool_use_id);
        }

        // The resumed Run leaves another job running when it ends.
        try hosted.respond(1, "{\"answers\":[\"Ship\"]}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
    }
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    // Its result is written, once, and the record let go all the same.
    {
        const transcript = try readFileIn(a, dir, "transcript.jsonl");
        defer a.free(transcript);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, transcript, "\"tool_use_id\":\"tu_q\""));
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try std.testing.expect((try cc.ui_request_store.load(arena.allocator(), dir)).?.suspended == null);
    }

    // Closed and opened again: nothing to resume, nothing run twice.
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
        defer host.release(hosted);
        std.Io.sleep(std.testing.io, .fromMilliseconds(200), .awake) catch {};
        try expectSnapshot(hosted, .idle, 0, 0, .none);
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"ui_request"));
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"run_resumed\""));
    }
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
}

test "L2 #446 SessionHost suspend mode: a request file this version cannot read is never overwritten and its ids are not reused; an unknown field alone does not make it unreadable" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const thanks = try textSse(a, "thanks");
    defer a.free(thanks);
    const bodies = [_][]const u8{ ASK_SSE, thanks, ASK_SSE, thanks, ASK_SSE };
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
    }
    const dir = try sessionDirOf(a, config, id);
    defer a.free(dir);
    // What a later version might write: a kind this one does not know.
    const unknown = "{\"v\":1,\"next_id\":7,\"suspended\":{\"kind\":\"permission\",\"id\":6,\"announcement\":\"\",\"tool_use_id\":\"tu_p\",\"tool_name\":\"Write\",\"max_turns\":4}}";
    {
        var file_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = try std.fmt.bufPrint(&file_buf, "{s}/" ++ cc.ui_request_store.FILE_NAME, .{dir});
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = target, .data = unknown });
    }
    // Twice, as two processes would: neither starts its ids again, nor
    // repeats the other's, though the file records neither.
    var last_id: u64 = 6;
    for ([_][]const u8{ "ask me", "ask once more" }) |prompt| {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
        defer host.release(hosted);
        try hosted.submit(.{ .text = prompt });
        // Not suspended: with nowhere to keep it, it blocks.
        try waitFor(&hosted.journal, "\"type\":\"ui_request\"", 1);
        var snapshot = try hosted.snapshot(a);
        const request_id = snapshot.pending_request_id;
        snapshot.deinit(a);
        try std.testing.expect(request_id > last_id);
        last_id = request_id;
        try expectSnapshot(hosted, .running, request_id, 0, .none);
        try hosted.respond(request_id, "{\"answers\":[\"Ship\"]}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"stop_reason\":\"suspended\""));
        const kept = try readFileIn(a, dir, cc.ui_request_store.FILE_NAME);
        defer a.free(kept);
        try std.testing.expectEqualStrings(unknown, kept);
    }

    // A field this version does not know, beside ones it does: still read.
    {
        var file_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = try std.fmt.bufPrint(&file_buf, "{s}/" ++ cc.ui_request_store.FILE_NAME, .{dir});
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = target, .data = "{\"v\":1,\"next_id\":9,\"later\":true,\"suspended\":null}" });
    }
    {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend" });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
        defer host.release(hosted);
        try hosted.submit(.{ .text = "ask again" });
        try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request\",\"id\":9,"));
    }
}

test "L2 #446 SessionHost suspend mode: the idempotency key of a suspended Run does not expire while it waits" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const thanks = try textSse(a, "thanks");
    defer a.free(thanks);
    const bodies = [_][]const u8{ ASK_SSE, thanks, ASK_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;
    // Keys expire at once: only the suspension can keep this one.
    var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend", .idempotency_retention_ms = 0 });
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
    defer host.release(hosted);

    try hosted.submit(.{ .text = "ask me", .idempotency_key = "im:evt-1" });
    try waitFor(&hosted.journal, "\"stop_reason\":\"suspended\"", 1);
    std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
    try std.testing.expectError(error.DuplicateSubmission, hosted.submit(.{ .text = "ask me", .idempotency_key = "im:evt-1" }));
    try expectSnapshot(hosted, .suspended, 1, 0, .none);
    try hosted.respond(1, "{\"answers\":[\"Ship\"]}");
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
    std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"user_message\""));
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
}

test "L2 #446 SessionHost: re_announce needs a period; a zero timeout is refused at open" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;
    for ([_]cc.session_host.UiRequestWait{ .block, .@"suspend" }) |wait| {
        var host = SessionHost.init(a, runtime, .{ .ui_request_wait = wait, .ui_request_timeout_ms = 0, .ui_request_expiry = .re_announce });
        defer host.deinit();
        try std.testing.expectError(error.InvalidUiRequestTimeout, host.open(.{ .config = baseConfig("http://127.0.0.1:9", dirs.workspace, dirs.home) }));
    }
    // Zero still means "at once" for the policies that end the request.
    var host = SessionHost.init(a, runtime, .{ .ui_request_timeout_ms = 0, .ui_request_expiry = .cancel, .transcripts = false });
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig("http://127.0.0.1:9", dirs.workspace, dirs.home) });
    host.release(hosted);
}

test "L2 #446 SessionHost: an unreadable answer closes malformed under its approver, blocking or suspended; a question's call fails, not the Session" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.tmp.cleanup();
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &TOOLS });
    defer runtime.destroy() catch unreachable;

    // Blocking: a permission prompt's unreadable answer grants nothing, and
    // its close names who sent it.
    {
        const path = try std.fmt.allocPrint(a, "{s}/garbled.txt", .{dirs.workspace});
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
        var host = SessionHost.init(a, runtime, .{ .transcripts = false });
        defer host.deinit();
        const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
        defer host.release(hosted);

        try hosted.submit(.{ .text = "write it" });
        try waitFor(&hosted.journal, "\"type\":\"ui_request\",\"id\":1,\"kind\":\"permission\"", 1);
        try hosted.respond(1, "{\"choice\":\"allow_everything\",\"by\":\"alice\"}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"malformed\",\"by\":\"alice\"}"));
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"session_poisoned\""));
        try std.testing.expect(!try exists(dirs.workspace, "garbled.txt"));
    }

    // Suspended: the question's call fails with InputAborted, the close
    // names who sent the answer, and the Session goes on.
    {
        const later = try textSse(a, "noted");
        defer a.free(later);
        const bodies = [_][]const u8{ ASK_SSE, later };
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
        try hosted.respond(1, "{\"answers\":\"Ship\",\"by\":\"bob\"}");
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
        try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"malformed\",\"by\":\"bob\"}"));
        try std.testing.expectEqual(@as(usize, 0), try countLines(&hosted.journal, "\"type\":\"session_poisoned\""));
        const resumed = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, resumed, "AskUserQuestion failed with InputAborted") != null);
    }
}
