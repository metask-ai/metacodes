//! L2: SessionHost, the multi-session service a network Host puts behind its
//! transport, driven the way such a Host drives it: open Sessions by id,
//! enqueue work, read the journal's wire lines, answer UI requests by id,
//! interrupt, close, reopen from the transcript.
//!
//! Each test names the failure a hand-built host (the cloud integration this
//! module absorbs) had: a fresh Session under a reused id resuming its old
//! conversation, an interrupt that could not release a pending prompt,
//! permission settings that did not follow the Session, a poisoned Session
//! that kept accepting work.
//!
//! Cross-module: session_host + agent_session + agent_loop + permission +
//! event_journal + protocol.wire + transcript + Write tool / Host tools.

const std = @import("std");
const pfs = @import("platform").fs;
const harness = @import("harness");
const cc = @import("cc");

const SessionHost = cc.session_host.SessionHost;
const HostedSession = cc.session_host.HostedSession;
const EventJournal = cc.event_journal.EventJournal;

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

const HOST_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_h\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_host\",\"name\":\"HostFail\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"x\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

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
        var seen: usize = 0;
        if (try journal.waitSince(a, 0, 20)) |lines| {
            defer {
                for (lines) |line| a.free(line);
                a.free(lines);
            }
            for (lines) |line| {
                if (std.mem.indexOf(u8, line, needle) != null) seen += 1;
            }
        }
        if (seen >= count) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
    }
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

/// The id of the newest `ui_request` line.
fn pendingRequestId(journal: *EventJournal) !u64 {
    const a = std.testing.allocator;
    const lines = (try journal.waitSince(a, 0, 1)) orelse return error.NoRequest;
    defer {
        for (lines) |line| a.free(line);
        a.free(lines);
    }
    const key = "\"type\":\"ui_request\",\"id\":";
    var id: ?u64 = null;
    for (lines) |line| {
        const at = std.mem.indexOf(u8, line, key) orelse continue;
        const rest = line[at + key.len ..];
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse continue;
        id = try std.fmt.parseInt(u64, rest[0..end], 10);
    }
    return id orelse error.NoRequest;
}

fn baseConfig(url: []const u8, workspace: []const u8, home: []const u8, tools: []const []const u8) cc.agent_session.SessionConfig {
    return .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .default,
        .workspace = .{ .root = workspace, .home = home },
        .allowed_tools = tools,
    };
}

test "L2 SessionHost runs queued work in order, journals wire lines and resumes from the transcript" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    const first = try textSse(a, "pelican noted");
    defer a.free(first);
    const second = try textSse(a, "still here");
    defer a.free(second);
    const third = try textSse(a, "it was the pelican");
    defer a.free(third);
    const bodies = [_][]const u8{ first, second, third };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const config = baseConfig(url, workspace, home, &.{});

    const hosted = try host.open(.{ .config = config });
    const id = hosted.id;
    try hosted.submit(.{ .text = "remember the word pelican", .trace_id = "trace-1" });
    try hosted.submit(.{ .text = "are you there" });
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);

    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":\"trace-1\""));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"text_chunk\",\"run_id\":1,\"trace_id\":\"trace-1\",\"data\":\"pelican noted\""));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"run_done\",\"data\":{\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
    var snapshot = try hosted.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqual(cc.session_host.Phase.idle, snapshot.phase);
    try std.testing.expectEqual(@as(usize, 4), snapshot.messages);
    try std.testing.expectEqualStrings("test-model", snapshot.model);

    // Release, close, then reopen the same id from its transcript.
    host.release(hosted);
    try host.close(id);
    try std.testing.expect(host.acquire(id) == null);
    const resumed = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
    defer host.release(resumed);
    try resumed.submit(.{ .text = "which word was it" });
    try waitFor(&resumed.journal, "\"type\":\"run_done\"", 1);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "remember the word pelican") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "pelican noted") != null);
}

test "L2 SessionHost edit-and-rerun (issue #432): the Run sees messages before the position + the edited text, the resumed Session too, files stay" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);
    const path = try std.fmt.allocPrint(a, "{s}/dropped.txt", .{workspace});
    defer a.free(path);

    const noted = try textSse(a, "pelican noted");
    defer a.free(noted);
    const write = try writeToolSse(a, path);
    defer a.free(write);
    const wrote = try textSse(a, "file written");
    defer a.free(wrote);
    const third = try textSse(a, "third answer");
    defer a.free(third);
    const edited = try textSse(a, "edited answer");
    defer a.free(edited);
    const resumed_reply = try textSse(a, "still the pelican");
    defer a.free(resumed_reply);
    const bodies = [_][]const u8{ noted, write, wrote, third, edited, resumed_reply };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Write"} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    var config = baseConfig(url, workspace, home, &.{"Write"});
    config.permission_mode = .accept_edits;

    const hosted = try host.open(.{ .config = config });
    const id = hosted.id;
    // Messages: 1 user, 2 reply, 3 user, 4 tool_use, 5 tool_result,
    // 6 reply, 7 user, 8 reply.
    try hosted.submit(.{ .text = "remember the word pelican" });
    try hosted.submit(.{ .text = "write the scratch file" });
    try hosted.submit(.{ .text = "the third prompt" });
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 3);
    try std.testing.expect(try exists(workspace, "dropped.txt"));
    {
        var snapshot = try hosted.snapshot(a);
        defer snapshot.deinit(a);
        try std.testing.expectEqual(@as(usize, 8), snapshot.messages);
    }

    // Positions that cannot be rerun fail the Run by name and change nothing.
    const MessagePosition = cc.conversation.MessagePosition;
    try hosted.submit(.{ .text = "not a reply", .replaces = try MessagePosition.fromOrdinal(2) });
    try hosted.submit(.{ .text = "not a tool result", .replaces = try MessagePosition.fromOrdinal(5) });
    try hosted.submit(.{ .text = "past the end", .replaces = try MessagePosition.fromOrdinal(9) });
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 6);
    try std.testing.expectEqual(@as(usize, 2), try countLines(&hosted.journal, "\"error_name\":\"NotUserMessage\""));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"error_name\":\"PositionOutOfRange\""));
    try std.testing.expectEqual(@as(usize, 4), server.requestCount());
    {
        var snapshot = try hosted.snapshot(a);
        defer snapshot.deinit(a);
        try std.testing.expectEqual(@as(usize, 8), snapshot.messages);
    }

    // Edit message 3 and rerun from it.
    try hosted.submit(.{ .text = "do not write anything", .trace_id = "edit", .replaces = try MessagePosition.fromOrdinal(3) });
    try waitFor(&hosted.journal, "\"type\":\"run_done\",\"data\":{\"run_id\":7,\"trace_id\":\"edit\",\"stop_reason\":\"end_turn\"", 1);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":7,\"trace_id\":\"edit\",\"text\":\"do not write anything\",\"replaces\":3}}"));
    {
        const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, body, "remember the word pelican") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "pelican noted") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "do not write anything") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "write the scratch file") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "tu_w") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "file written") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "the third prompt") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "third answer") == null);
    }
    {
        var snapshot = try hosted.snapshot(a);
        defer snapshot.deinit(a);
        try std.testing.expectEqual(@as(usize, 4), snapshot.messages);
    }
    // Context only: what the dropped turns did to the workspace stays.
    try std.testing.expect(try exists(workspace, "dropped.txt"));

    // A restart restores the edited history, never the dropped one.
    host.release(hosted);
    try host.close(id);
    const resumed = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
    defer host.release(resumed);
    {
        var snapshot = try resumed.snapshot(a);
        defer snapshot.deinit(a);
        try std.testing.expectEqual(@as(usize, 4), snapshot.messages);
    }
    try resumed.submit(.{ .text = "which word was it" });
    try waitFor(&resumed.journal, "\"type\":\"run_done\"", 1);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "remember the word pelican") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "do not write anything") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "edited answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "write the scratch file") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "file written") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "the third prompt") == null);
    try std.testing.expect(try exists(workspace, "dropped.txt"));
}

test "L2 SessionHost opening an id fresh replaces its transcript instead of resuming it" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    const first = try textSse(a, "alpha noted");
    defer a.free(first);
    const second = try textSse(a, "fresh start");
    defer a.free(second);
    const bodies = [_][]const u8{ first, second };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const config = baseConfig(url, workspace, home, &.{});
    const id = cc.session_id.gen();

    const before = try host.open(.{ .config = config, .id = id });
    try before.submit(.{ .text = "the secret is alpha" });
    try waitFor(&before.journal, "\"type\":\"run_done\"", 1);
    host.release(before);
    try host.close(id);

    // Start over under the same id, close without running, then resume:
    // nothing of the first conversation may come back.
    host.release(try host.open(.{ .config = config, .id = id }));
    try host.close(id);
    const resumed = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
    defer host.release(resumed);
    var snapshot = try resumed.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), snapshot.messages);
    try resumed.submit(.{ .text = "what is the secret" });
    try waitFor(&resumed.journal, "\"type\":\"run_done\"", 1);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "the secret is alpha") == null);
}

test "L2 SessionHost permissions and working directories follow each Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_a = try subdir(&tmp, "tenant-a", &ws_a_buf);
    var ws_b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_b = try subdir(&tmp, "tenant-b", &ws_b_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    const path_a = try std.fmt.allocPrint(a, "{s}/a.txt", .{ws_a});
    defer a.free(path_a);
    const path_b1 = try std.fmt.allocPrint(a, "{s}/b1.txt", .{ws_b});
    defer a.free(path_b1);
    const path_b2 = try std.fmt.allocPrint(a, "{s}/b2.txt", .{ws_b});
    defer a.free(path_b2);
    const write_a = try writeToolSse(a, path_a);
    defer a.free(write_a);
    const write_b1 = try writeToolSse(a, path_b1);
    defer a.free(write_b1);
    const write_b2 = try writeToolSse(a, path_b2);
    defer a.free(write_b2);
    const done = try textSse(a, "done");
    defer a.free(done);
    const bodies = [_][]const u8{ write_a, done, write_b1, done, write_b2, done };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Write"} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();

    var config_a = baseConfig(url, ws_a, home, &.{"Write"});
    config_a.permission_mode = .accept_edits;
    const config_b = baseConfig(url, ws_b, home, &.{"Write"});
    const session_a = try host.open(.{ .config = config_a });
    defer host.release(session_a);
    const session_b = try host.open(.{ .config = config_b });
    defer host.release(session_b);

    // A edits its own workspace in accept_edits: no prompt.
    try session_a.submit(.{ .text = "write a" });
    try waitFor(&session_a.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 0), try countLines(&session_a.journal, "\"type\":\"ui_request\""));
    try std.testing.expect(try exists(ws_a, "a.txt"));

    // B is in default mode: the same edit asks, through B's own journal.
    try session_b.submit(.{ .text = "write b1" });
    try waitFor(&session_b.journal, "\"type\":\"ui_request\"", 1);
    const request_id = try pendingRequestId(&session_b.journal);
    try std.testing.expectError(error.NoSuchRequest, session_b.respond(request_id + 1, "{\"choice\":\"allow_once\"}"));
    try session_b.respond(request_id, "{\"choice\":\"allow_once\"}");
    try waitFor(&session_b.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expect(try exists(ws_b, "b1.txt"));
    try std.testing.expectError(error.NoSuchRequest, session_b.respond(request_id, "{\"choice\":\"allow_once\"}"));

    // A queued command changes B alone, before the submission behind it.
    try session_b.command(.{ .set_permission_mode = .accept_edits });
    try session_b.submit(.{ .text = "write b2" });
    try waitFor(&session_b.journal, "\"type\":\"run_done\"", 2);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&session_b.journal, "\"command\":\"set_permission_mode\",\"ok\":true"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&session_b.journal, "\"type\":\"ui_request\""));
    try std.testing.expect(try exists(ws_b, "b2.txt"));
    var snapshot_b = try session_b.snapshot(a);
    defer snapshot_b.deinit(a);
    try std.testing.expectEqual(cc.types_mod.PermissionMode.accept_edits, snapshot_b.permission_mode);
}

test "L2 SessionHost interrupt releases a pending prompt and stops the Run" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    const path = try std.fmt.allocPrint(a, "{s}/never.txt", .{workspace});
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

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Write"} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, workspace, home, &.{"Write"}) });
    defer host.release(hosted);

    try hosted.submit(.{ .text = "write it" });
    try waitFor(&hosted.journal, "\"type\":\"ui_request\"", 1);
    const request_id = try pendingRequestId(&hosted.journal);
    try std.testing.expectEqual(cc.session_host.InterruptOutcome.requested, hosted.interrupt());
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);

    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\""));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"stop_reason\":\"aborted\""));
    try std.testing.expect(!try exists(workspace, "never.txt"));
    try std.testing.expectError(error.NoSuchRequest, hosted.respond(request_id, "{\"choice\":\"allow_once\"}"));
    try std.testing.expectEqual(cc.session_host.InterruptOutcome.no_run, hosted.interrupt());
}

/// Watches the window between an interrupt's (or close's) decision to cancel
/// and its kernel abort. A Run released from its prompt in that window took
/// the cancelled prompt as a denied tool, sent its next request and, against
/// a fast provider, ended normally before the abort arrived: the interrupt
/// then reported `too_late` and the Run never stopped (seen on Windows CI).
const ResumeWatch = struct {
    var server: ?*harness.MockServer = null;
    var ran = false;
    var resumed_early = false;

    fn beforeAbort(hosted: *HostedSession) void {
        ran = true;
        // A released Run shows itself within milliseconds: it closes the
        // prompt, then sends its next provider request.
        var waited: u32 = 0;
        while (waited < 300) : (waited += 10) {
            if ((countLines(&hosted.journal, "\"type\":\"ui_request_closed\"") catch 0) != 0 or
                server.?.requestCount() >= 2)
            {
                resumed_early = true;
                return;
            }
            std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
        }
    }

    fn arm(watched: *harness.MockServer) void {
        server = watched;
        ran = false;
        resumed_early = false;
        cc.session_host.testing_hooks.before_abort = beforeAbort;
    }

    fn disarm() void {
        cc.session_host.testing_hooks.before_abort = null;
        server = null;
    }
};

const PromptFixture = struct {
    tmp: std.testing.TmpDir,
    ws_buf: [std.fs.max_path_bytes]u8 = undefined,
    home_buf: [std.fs.max_path_bytes]u8 = undefined,
    workspace: []const u8 = "",
    write: []u8 = &.{},
    done: []u8 = &.{},
    server: *harness.MockServer = undefined,
    url: []u8 = &.{},
    runtime: *cc.agent_session.AgentRuntime = undefined,
    host: SessionHost = undefined,
    hosted: *HostedSession = undefined,

    /// In place: a Session whose first Run is parked on a Write prompt.
    fn start(self: *PromptFixture) !void {
        const a = std.testing.allocator;
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        self.workspace = try subdir(&self.tmp, "workspace", &self.ws_buf);
        const home = try subdir(&self.tmp, "home", &self.home_buf);
        const path = try std.fmt.allocPrint(a, "{s}/never.txt", .{self.workspace});
        defer a.free(path);
        self.write = try writeToolSse(a, path);
        self.done = try textSse(a, "done");
        const bodies = [_][]const u8{ self.write, self.done };
        self.server = try harness.MockServer.startCassette(&bodies, 0);
        self.url = try self.server.urlOwned(a);
        self.runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Write"} });
        self.host = SessionHost.init(a, self.runtime, .{});
        self.hosted = try self.host.open(.{ .config = baseConfig(self.url, self.workspace, home, &.{"Write"}) });
        try self.hosted.submit(.{ .text = "write it" });
        try waitFor(&self.hosted.journal, "\"type\":\"ui_request\"", 1);
    }

    fn stop(self: *PromptFixture) void {
        const a = std.testing.allocator;
        self.host.release(self.hosted);
        self.host.deinit();
        self.runtime.destroy() catch unreachable;
        self.server.stop();
        a.free(self.url);
        a.free(self.done);
        a.free(self.write);
        self.tmp.cleanup();
    }
};

test "L2 SessionHost interrupt keeps the prompt pending until the Run's abort is in force" {
    var fx: PromptFixture = undefined;
    try fx.start();
    defer fx.stop();
    ResumeWatch.arm(fx.server);
    defer ResumeWatch.disarm();

    try std.testing.expectEqual(cc.session_host.InterruptOutcome.requested, fx.hosted.interrupt());
    try std.testing.expect(ResumeWatch.ran);
    try std.testing.expect(!ResumeWatch.resumed_early);
    try waitFor(&fx.hosted.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&fx.hosted.journal, "\"stop_reason\":\"aborted\""));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&fx.hosted.journal, "\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\""));
    // The Run stopped at the boundary after the prompt: no second request.
    try std.testing.expectEqual(@as(usize, 1), fx.server.requestCount());
    try std.testing.expect(!try exists(fx.workspace, "never.txt"));
}

test "L2 SessionHost close keeps the prompt pending until the Run's abort is in force" {
    var fx: PromptFixture = undefined;
    try fx.start();
    defer fx.stop();
    ResumeWatch.arm(fx.server);
    defer ResumeWatch.disarm();

    try fx.host.close(fx.hosted.id);
    try std.testing.expect(ResumeWatch.ran);
    try std.testing.expect(!ResumeWatch.resumed_early);
    // The shell stays readable after close: the Run was aborted, not finished.
    try std.testing.expectEqual(@as(usize, 1), try countLines(&fx.hosted.journal, "\"stop_reason\":\"aborted\""));
    try std.testing.expectEqual(@as(usize, 1), fx.server.requestCount());
    try std.testing.expect(!try exists(fx.workspace, "never.txt"));
}

test "L2 SessionHost an unreadable answer denies the prompt and closes it as malformed" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    const path = try std.fmt.allocPrint(a, "{s}/garbled.txt", .{workspace});
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

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Write"} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, workspace, home, &.{"Write"}) });
    defer host.release(hosted);

    try hosted.submit(.{ .text = "write it" });
    try waitFor(&hosted.journal, "\"type\":\"ui_request\"", 1);
    try hosted.respond(try pendingRequestId(&hosted.journal), "{\"choice\":\"allow_everything\"}");
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"malformed\""));
    try std.testing.expect(!try exists(workspace, "garbled.txt"));
}

const FatalTool = struct {
    calls: usize = 0,

    fn execute(raw: *anyopaque, _: cc.agent_session.HostRunIdentity, _: []const u8) error{OutOfMemory}!cc.agent_session.HostToolOutcome {
        const self: *FatalTool = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .fatal;
    }

    fn tool(self: *FatalTool) cc.agent_session.HostSyncTool {
        return .{
            .definition = .{
                .name = "HostFail",
                .description = "Fails the embedding Host",
                .input_schema = .{
                    .type = "object",
                    .prop_specs = &.{.{ .name = "text", .type = "string" }},
                    .required = &.{"text"},
                },
            },
            .ctx = self,
            .execute = execute,
            .category = .execute,
        };
    }
};

test "L2 SessionHost reports a poisoned Session, drops its queue and refuses more work" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    // 40 ms per chunk keeps Run 1 in flight while the second submission is
    // queued behind it, whatever the scheduler does between the two calls.
    var server = try harness.MockServer.start(HOST_TOOL_SSE, 40);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var fatal = FatalTool{};
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .host_sync_tools = &.{fatal.tool()} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    var config = baseConfig(url, workspace, home, &.{"HostFail"});
    config.permission_mode = .bypass_permissions;
    config.host_identity_ctx = &fatal;
    const hosted = try host.open(.{ .config = config });

    try hosted.submit(.{ .text = "fail" });
    try hosted.submit(.{ .text = "queued behind the failure" });
    try waitFor(&hosted.journal, "\"type\":\"session_poisoned\"", 1);

    try std.testing.expectEqual(@as(usize, 1), fatal.calls);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"run_done\",\"data\":{\"run_id\":1,\"trace_id\":null,\"stop_reason\":null,\"error_name\":\"CallbackFailed\",\"model_error\":null}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"session_poisoned\",\"data\":{\"error_name\":\"CallbackFailed\",\"dropped\":1}"));
    // The queued submission never ran.
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"user_message\""));
    var snapshot = try hosted.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqual(cc.session_host.Phase.poisoned, snapshot.phase);
    try std.testing.expectError(error.SessionPoisoned, hosted.submit(.{ .text = "more" }));
    // Still closable.
    const id = hosted.id;
    host.release(hosted);
    try host.close(id);
}

test "L2 SessionHost close never waits on references: readers wake, the id reopens, the shell stays readable" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false });
    defer host.deinit();
    const config = baseConfig("http://127.0.0.1:9", workspace, home, &.{});
    const hosted = try host.open(.{ .config = config, .id = cc.session_id.gen() });
    const id = hosted.id;

    // A reader thread, the way an SSE handler holds the Session. Its
    // reference is taken here, so the close below cannot overtake it however
    // late the thread is scheduled.
    const Reader = struct {
        saw_close: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This(), lease: *HostedSession) void {
            defer lease.release();
            while (!lease.journal.isClosed()) {
                const lines = lease.journal.waitSince(std.testing.allocator, lease.journal.count(), 50) catch return;
                if (lines) |batch| {
                    for (batch) |line| std.testing.allocator.free(line);
                    std.testing.allocator.free(batch);
                }
            }
            self.saw_close.store(true, .release);
        }
    };
    var reader = Reader{};
    const reader_lease = host.acquire(id) orelse return error.TestSessionMissing;
    const thread = std.Thread.spawn(.{}, Reader.run, .{ &reader, reader_lease }) catch |err| {
        reader_lease.release();
        return err;
    };
    var joined = false;
    defer if (!joined) thread.join();

    // This thread still holds the reference from `open` while it closes.
    try host.close(id);
    try std.testing.expectError(error.SessionNotFound, host.close(id));
    var snapshot = try hosted.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqual(cc.session_host.Phase.closing, snapshot.phase);
    try std.testing.expect(hosted.journal.isClosed());
    try std.testing.expectError(error.SessionClosed, hosted.submit(.{ .text = "too late" }));
    try std.testing.expectEqual(cc.session_host.InterruptOutcome.no_run, hosted.interrupt());

    // The kernel Session is gone, so the id opens again while the old shell
    // is still held.
    const reopened = try host.open(.{ .config = config, .id = id });
    reopened.release();
    hosted.release();
    thread.join();
    joined = true;
    try std.testing.expect(reader.saw_close.load(.acquire));
}

test "L2 SessionHost options: UI timeout, queue bound, turn limit, no transcripts" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    const path = try std.fmt.allocPrint(a, "{s}/unanswered.txt", .{workspace});
    defer a.free(path);
    const write = try writeToolSse(a, path);
    defer a.free(write);
    const done = try textSse(a, "done");
    defer a.free(done);
    // Run 1: the Write prompt times out (denied), then a final answer.
    // Runs 2-3: a Write each, cut off by the one-turn limit.
    const bodies = [_][]const u8{ write, done, write, write };
    // 30 ms per chunk keeps Run 2 in flight while the queue fills behind it.
    var server = try harness.MockServer.startCassette(&bodies, 30);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Write"} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{
        .ui_request_timeout_ms = 100,
        .max_queued = 1,
        .transcripts = false,
    });
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, workspace, home, &.{"Write"}) });
    defer host.release(hosted);

    // Nobody answers: the request is closed as cancelled, the edit denied,
    // and the Run carries on to its final answer.
    try hosted.submit(.{ .text = "write it" });
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\""));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
    try std.testing.expect(!try exists(workspace, "unanswered.txt"));

    // One queued item at most; the driver holds Run 2 while 3 waits.
    var bounded = SessionHost.init(a, runtime, .{ .max_queued = 1, .max_turns = 1, .transcripts = false });
    defer bounded.deinit();
    var bypass = baseConfig(url, workspace, home, &.{"Write"});
    bypass.permission_mode = .bypass_permissions;
    const limited = try bounded.open(.{ .config = bypass });
    defer bounded.release(limited);
    try limited.submit(.{ .text = "run two" });
    try waitFor(&limited.journal, "\"type\":\"user_message\"", 1);
    try limited.submit(.{ .text = "run three" });
    try std.testing.expectError(error.QueueFull, limited.submit(.{ .text = "run four" }));
    try waitFor(&limited.journal, "\"type\":\"run_done\"", 2);
    try std.testing.expectEqual(@as(usize, 2), try countLines(&limited.journal, "\"stop_reason\":\"max_turns\""));

    // transcripts = false: nothing under the state root.
    const legacy = try cc.util_state_root.legacyDefault(a, home);
    defer a.free(legacy);
    var projects_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const projects = try std.fmt.bufPrintZ(&projects_buf, "{s}/projects", .{legacy});
    try std.testing.expect(!pfs.exists(projects.ptr));
}

test "L2 #408 a hosted Run's run_done carries its model failure, and the next Run's does not" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);
    const ok = try textSse(a, "fine now");
    defer a.free(ok);
    var server = try harness.MockServer.startHttpCassette(
        &.{ "{\"error\":{\"code\":\"insufficient_balance\",\"message\":\"Top up\"}}", ok },
        &.{ "HTTP/1.1 402 Payment Required", "HTTP/1.1 200 OK" },
    );
    defer server.stop();
    server.extra_response_headers = "x-request-id: req-hosted-1\r\n";
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, workspace, home, &.{}) });
    defer host.release(hosted);
    try hosted.submit(.{ .text = "fails" });
    try hosted.submit(.{ .text = "succeeds" });
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);

    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"data\":{\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"api_error\",\"error_name\":null,\"model_error\":{\"category\":\"payment_required\",\"code\":\"insufficient_balance\",\"type\":null,\"message\":\"Top up\",\"http_status\":402,\"request_id\":\"req-hosted-1\",\"retry\":\"not_retryable\",\"retry_after_ms\":null,\"attempts\":1,\"truncated\":false}}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"data\":{\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\",\"error_name\":null,\"model_error\":null}"));
}

fn toolSse(comptime id: []const u8, comptime name: []const u8, comptime input_json: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" ++ input_json ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

test "L2 #445 SessionHost: a hosted team lead's next Run is its teammate's reply, as on the bundled daemon" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try subdir(&tmp, "team", &root_buf);

    const formed = try textSse(a, "formed");
    defer a.free(formed);
    const ack = try textSse(a, "ack");
    defer a.free(ack);
    // Run 1: TeamCreate crew, then answer. Run 2 is the teammate's reply.
    const lead_bodies = [_][]const u8{ toolSse("t1", "TeamCreate", "{\\\"name\\\":\\\"crew\\\"}"), formed, ack };
    var lead_srv = try harness.MockServer.startCassette(&lead_bodies, 0);
    defer lead_srv.stop();
    const lead_url = try lead_srv.urlOwned(a);
    defer a.free(lead_url);
    const idle = try textSse(a, "idle");
    defer a.free(idle);
    const member_bodies = [_][]const u8{
        toolSse("s1", "SendMessage", "{\\\"to\\\":\\\"team-lead\\\",\\\"message\\\":\\\"done: 42\\\",\\\"summary\\\":\\\"done\\\"}"),
        idle,
    };
    var member_srv = try harness.MockServer.startCassette(&member_bodies, 0);
    defer member_srv.stop();
    const member_url = try member_srv.urlOwned(a);
    defer a.free(member_url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .enable_teams = true });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false });
    defer host.deinit();
    var lead_config = baseConfig(lead_url, root, root, &.{ "TeamCreate", "SendMessage" });
    lead_config.permission_mode = .bypass_permissions;
    lead_config.workspace = .{ .root = root, .home = root, .state_root = root, .shell = .disabled };
    lead_config.team = .{ .role = .lead, .team_name = "" };
    const lead = try host.open(.{ .config = lead_config });
    defer host.release(lead);

    try lead.submit(.{ .text = "form a team" });
    try waitFor(&lead.journal, "\"type\":\"run_done\"", 1);
    // An empty inbox starts nothing, however often it is read.
    std.Io.sleep(std.testing.io, .fromMilliseconds(3 * cc.session_host.lead_inbox_poll_ms), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 1), try countLines(&lead.journal, "\"type\":\"user_message\""));
    try std.testing.expectEqual(@as(usize, 2), lead_srv.requestCount());

    // The member, opened on the same host, reports to the lead.
    var member_config = baseConfig(member_url, root, root, &.{"SendMessage"});
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

    // Nobody submits to the lead: its driver takes the reply as Run 2, and
    // the provider request carries it.
    try waitFor(&lead.journal, "\"type\":\"run_done\"", 2);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&lead.journal, "\"type\":\"user_message\",\"data\":{\"run_id\":2"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&lead.journal, "done: 42"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&lead.journal, "\"run_id\":2,\"trace_id\":null,\"stop_reason\":\"end_turn\""));
    try std.testing.expectEqual(@as(usize, 3), lead_srv.requestCount());
    const request = lead_srv.requestAt(2).?;
    try std.testing.expect(std.mem.indexOf(u8, request.body(), "done: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.body(), "solver") != null);

    // The mail was taken once: the lead does not run it again.
    std.Io.sleep(std.testing.io, .fromMilliseconds(3 * cc.session_host.lead_inbox_poll_ms), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 2), try countLines(&lead.journal, "\"type\":\"user_message\""));
}

/// The Host side of `Options.teammates` in the test below: every member gets
/// the member cassette and `SendMessage`, and each spawn it is asked for is
/// recorded.
const MemberFactory = struct {
    url: []const u8,
    workspace: cc.agent_session.WorkspaceConfig,
    calls: usize = 0,
    lead: ?cc.session_id.SessionId = null,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    team_buf: [64]u8 = undefined,
    team_len: usize = 0,

    fn factory(self: *MemberFactory) cc.session_host.TeammateFactory {
        return .{ .ctx = self, .configure = configure };
    }

    fn configure(ctx: *anyopaque, arena: std.mem.Allocator, spawn: cc.session_host.TeammateSpawn) anyerror!cc.agent_session.SessionConfig {
        const self: *MemberFactory = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.lead = spawn.lead;
        @memcpy(self.name_buf[0..spawn.name.len], spawn.name);
        self.name_len = spawn.name.len;
        @memcpy(self.team_buf[0..spawn.team_name.len], spawn.team_name);
        self.team_len = spawn.team_name.len;
        const tools = try arena.dupe([]const u8, &.{"SendMessage"});
        var config = baseConfig(self.url, self.workspace.root, self.workspace.root, tools);
        config.permission_mode = .bypass_permissions;
        config.workspace = self.workspace;
        return config;
    }
};

test "L2 #445 SessionHost: a hosted lead's SpawnTeammate opens and runs the member on the same host, as the daemon's App starts its teammates" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try subdir(&tmp, "team", &root_buf);

    const delegated = try textSse(a, "delegated");
    defer a.free(delegated);
    const ack = try textSse(a, "ack");
    defer a.free(ack);
    // Run 1: TeamCreate crew, SpawnTeammate solver, then answer. Run 2 is the
    // member's reply.
    const lead_bodies = [_][]const u8{
        toolSse("t1", "TeamCreate", "{\\\"name\\\":\\\"crew\\\"}"),
        toolSse("t2", "SpawnTeammate", "{\\\"name\\\":\\\"solver\\\",\\\"prompt\\\":\\\"fix the parser\\\"}"),
        delegated,
        ack,
    };
    var lead_srv = try harness.MockServer.startCassette(&lead_bodies, 0);
    defer lead_srv.stop();
    const lead_url = try lead_srv.urlOwned(a);
    defer a.free(lead_url);
    const idle = try textSse(a, "idle");
    defer a.free(idle);
    const member_bodies = [_][]const u8{
        toolSse("s1", "SendMessage", "{\\\"to\\\":\\\"team-lead\\\",\\\"message\\\":\\\"done: 42\\\",\\\"summary\\\":\\\"done\\\"}"),
        idle,
    };
    var member_srv = try harness.MockServer.startCassette(&member_bodies, 0);
    defer member_srv.stop();
    const member_url = try member_srv.urlOwned(a);
    defer a.free(member_url);

    const workspace: cc.agent_session.WorkspaceConfig = .{ .root = root, .home = root, .state_root = root, .shell = .disabled };
    var members = MemberFactory{ .url = member_url, .workspace = workspace };
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .enable_teams = true });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false, .teammates = members.factory() });
    defer host.deinit();
    var lead_config = baseConfig(lead_url, root, root, &.{ "TeamCreate", "SpawnTeammate", "SendMessage" });
    lead_config.permission_mode = .bypass_permissions;
    lead_config.workspace = workspace;
    lead_config.team = .{ .role = .lead, .team_name = "" };
    const lead = try host.open(.{ .config = lead_config });
    defer host.release(lead);

    // One submission to the lead and nothing else: its spawn request opens
    // the member, whose Run reaches its own provider with the lead's prompt,
    // and whose reply becomes the lead's Run 2.
    try lead.submit(.{ .text = "form a team and delegate" });
    try waitFor(&lead.journal, "\"type\":\"run_done\"", 2);

    try std.testing.expectEqual(@as(usize, 1), members.calls);
    try std.testing.expectEqualStrings("solver", members.name_buf[0..members.name_len]);
    try std.testing.expectEqualStrings("crew", members.team_buf[0..members.team_len]);
    try std.testing.expectEqualStrings(lead.id.asSlice(), members.lead.?.asSlice());

    try std.testing.expect(member_srv.requestCount() >= 1);
    try std.testing.expect(std.mem.indexOf(u8, member_srv.requestAt(0).?.body(), "fix the parser") != null);

    const ids = try host.list(a);
    defer a.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    const member_id = if (std.mem.eql(u8, ids[0].asSlice(), lead.id.asSlice())) ids[1] else ids[0];
    const member = host.acquire(member_id).?;
    defer host.release(member);
    try waitFor(&member.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 2), member_srv.requestCount());
    try std.testing.expectEqual(@as(usize, 1), try countLines(&member.journal, "\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"fix the parser\""));

    try std.testing.expectEqual(@as(usize, 1), try countLines(&lead.journal, "\"type\":\"user_message\",\"data\":{\"run_id\":2"));
    try std.testing.expectEqual(@as(usize, 4), lead_srv.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, lead_srv.requestAt(3).?.body(), "done: 42") != null);

    // The request was fulfilled once: no second member, no second spawn.
    std.Io.sleep(std.testing.io, .fromMilliseconds(2 * cc.session_host.lead_inbox_poll_ms), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 1), members.calls);

    // Closing the lead closes the member it opened.
    try host.close(lead.id);
    try std.testing.expect(host.acquire(member_id) == null);
    try std.testing.expect(member.journal.isClosed());
}

/// The lead's half of the spawn tests below: Run 1 creates team `crew` and
/// delegates to `solver`.
fn spawnLeadConfig(url: []const u8, workspace: cc.agent_session.WorkspaceConfig) cc.agent_session.SessionConfig {
    var config = baseConfig(url, workspace.root, workspace.root, &.{ "TeamCreate", "SpawnTeammate", "SendMessage" });
    config.permission_mode = .bypass_permissions;
    config.workspace = workspace;
    config.team = .{ .role = .lead, .team_name = "" };
    return config;
}

/// The id on `host` that is not `lead`'s; `host` holds exactly two.
fn memberId(host: *SessionHost, lead: *HostedSession) !cc.session_id.SessionId {
    const ids = try host.list(std.testing.allocator);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    return if (std.mem.eql(u8, ids[0].asSlice(), lead.id.asSlice())) ids[1] else ids[0];
}

test "L2 #445 SessionHost InheritLead: the member runs with its lead's current model and permission mode, as an App teammate inherits them" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try subdir(&tmp, "team", &root_buf);

    const delegated = try textSse(a, "delegated");
    defer a.free(delegated);
    const ack = try textSse(a, "ack");
    defer a.free(ack);
    const lead_bodies = [_][]const u8{
        toolSse("t1", "TeamCreate", "{\\\"name\\\":\\\"crew\\\"}"),
        toolSse("t2", "SpawnTeammate", "{\\\"name\\\":\\\"solver\\\",\\\"prompt\\\":\\\"fix the parser\\\"}"),
        delegated,
        ack,
    };
    var lead_srv = try harness.MockServer.startCassette(&lead_bodies, 0);
    defer lead_srv.stop();
    const lead_url = try lead_srv.urlOwned(a);
    defer a.free(lead_url);
    const idle = try textSse(a, "idle");
    defer a.free(idle);
    const member_bodies = [_][]const u8{
        toolSse("s1", "SendMessage", "{\\\"to\\\":\\\"team-lead\\\",\\\"message\\\":\\\"done: 42\\\",\\\"summary\\\":\\\"done\\\"}"),
        idle,
    };
    var member_srv = try harness.MockServer.startCassette(&member_bodies, 0);
    defer member_srv.stop();
    const member_url = try member_srv.urlOwned(a);
    defer a.free(member_url);

    const workspace: cc.agent_session.WorkspaceConfig = .{ .root = root, .home = root, .state_root = root, .shell = .disabled };
    const lead_config = spawnLeadConfig(lead_url, workspace);
    // The Host's base for its leads, here on the member's cassette. Its
    // model and permission mode are what the lead no longer runs with.
    var base = lead_config;
    base.base_url = member_url;
    base.model = "base-model";
    base.permission_mode = .default;
    var inherit = cc.session_host.InheritLead{ .base = base };
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .enable_teams = true });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false, .teammates = inherit.factory() });
    defer host.deinit();
    const lead = try host.open(.{ .config = lead_config });
    defer host.release(lead);

    // The lead switches model before it delegates; the member follows it.
    try lead.command(.{ .set_model = "lead-live-model" });
    try lead.submit(.{ .text = "form a team and delegate" });
    try waitFor(&lead.journal, "\"type\":\"run_done\"", 2);
    try std.testing.expect(std.mem.indexOf(u8, lead_srv.requestAt(0).?.body(), "\"model\":\"lead-live-model\"") != null);

    const member = host.acquire(try memberId(&host, lead)).?;
    defer host.release(member);
    try waitFor(&member.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 2), member_srv.requestCount());
    const first = member_srv.requestAt(0).?.body();
    try std.testing.expect(std.mem.indexOf(u8, first, "fix the parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"model\":\"lead-live-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "base-model") == null);
    var snap = try member.snapshot(a);
    defer snap.deinit(a);
    try std.testing.expectEqualStrings("lead-live-model", snap.model);
    try std.testing.expectEqual(cc.types_mod.PermissionMode.bypass_permissions, snap.permission_mode);

    // The member's reply reached the lead under the inherited configuration.
    try std.testing.expect(std.mem.indexOf(u8, lead_srv.requestAt(3).?.body(), "done: 42") != null);
}

test "L2 #445 SessionHost: a lead re-spawns a name whose member the Host closed, under a fresh lease, and hears from the new member" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try subdir(&tmp, "team", &root_buf);

    const delegated = try textSse(a, "delegated");
    defer a.free(delegated);
    const ack = try textSse(a, "ack");
    defer a.free(ack);
    const redelegated = try textSse(a, "redelegated");
    defer a.free(redelegated);
    const ack2 = try textSse(a, "ack2");
    defer a.free(ack2);
    // Run 1 delegates "task one", Run 2 is its reply, Run 3 delegates
    // "task two" to the same name, Run 4 is the new member's reply.
    const lead_bodies = [_][]const u8{
        toolSse("t1", "TeamCreate", "{\\\"name\\\":\\\"crew\\\"}"),
        toolSse("t2", "SpawnTeammate", "{\\\"name\\\":\\\"solver\\\",\\\"prompt\\\":\\\"task one\\\"}"),
        delegated,
        ack,
        toolSse("t3", "SpawnTeammate", "{\\\"name\\\":\\\"solver\\\",\\\"prompt\\\":\\\"task two\\\"}"),
        redelegated,
        ack2,
    };
    var lead_srv = try harness.MockServer.startCassette(&lead_bodies, 0);
    defer lead_srv.stop();
    const lead_url = try lead_srv.urlOwned(a);
    defer a.free(lead_url);
    const idle = try textSse(a, "idle");
    defer a.free(idle);
    const member_bodies = [_][]const u8{
        toolSse("s1", "SendMessage", "{\\\"to\\\":\\\"team-lead\\\",\\\"message\\\":\\\"done: 1\\\",\\\"summary\\\":\\\"done\\\"}"),
        idle,
        toolSse("s2", "SendMessage", "{\\\"to\\\":\\\"team-lead\\\",\\\"message\\\":\\\"done: 2\\\",\\\"summary\\\":\\\"done\\\"}"),
        idle,
    };
    var member_srv = try harness.MockServer.startCassette(&member_bodies, 0);
    defer member_srv.stop();
    const member_url = try member_srv.urlOwned(a);
    defer a.free(member_url);

    const workspace: cc.agent_session.WorkspaceConfig = .{ .root = root, .home = root, .state_root = root, .shell = .disabled };
    var members = MemberFactory{ .url = member_url, .workspace = workspace };
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .enable_teams = true });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false, .teammates = members.factory() });
    defer host.deinit();
    const lead = try host.open(.{ .config = spawnLeadConfig(lead_url, workspace) });
    defer host.release(lead);

    try lead.submit(.{ .text = "form a team and delegate" });
    try waitFor(&lead.journal, "\"type\":\"run_done\"", 2);
    const first_id = try memberId(&host, lead);
    const first = host.acquire(first_id).?;
    try waitFor(&first.journal, "\"type\":\"run_done\"", 1);
    host.release(first);
    try std.testing.expect(std.mem.indexOf(u8, lead_srv.requestAt(3).?.body(), "done: 1") != null);

    // The Host closes the member; the lead later delegates to the name again.
    try host.close(first_id);
    try lead.submit(.{ .text = "delegate again" });
    try waitFor(&lead.journal, "\"type\":\"run_done\"", 4);

    try std.testing.expectEqual(@as(usize, 2), members.calls);
    const second_id = try memberId(&host, lead);
    try std.testing.expect(!std.mem.eql(u8, first_id.asSlice(), second_id.asSlice()));
    const second = host.acquire(second_id).?;
    defer host.release(second);
    try waitFor(&second.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&second.journal, "\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"task two\""));
    try std.testing.expect(std.mem.indexOf(u8, member_srv.requestAt(2).?.body(), "task two") != null);

    // The new member's reply is the lead's Run 4; nothing failed.
    try std.testing.expectEqual(@as(usize, 7), lead_srv.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, lead_srv.requestAt(6).?.body(), "done: 2") != null);
    try std.testing.expectEqual(@as(usize, 0), try countLines(&lead.journal, "teammate_spawn_failed"));
}

/// A Host that cannot configure any member.
const RefusingFactory = struct {
    calls: usize = 0,

    fn factory(self: *RefusingFactory) cc.session_host.TeammateFactory {
        return .{ .ctx = self, .configure = configure };
    }

    fn configure(ctx: *anyopaque, _: std.mem.Allocator, _: cc.session_host.TeammateSpawn) anyerror!cc.agent_session.SessionConfig {
        const self: *RefusingFactory = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return error.NoTeammateProvider;
    }
};

test "L2 #445 SessionHost: a spawn that fails is the lead's next Run, so its model learns the teammate was not started" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try subdir(&tmp, "team", &root_buf);

    const delegated = try textSse(a, "delegated");
    defer a.free(delegated);
    const noted = try textSse(a, "noted");
    defer a.free(noted);
    const lead_bodies = [_][]const u8{
        toolSse("t1", "TeamCreate", "{\\\"name\\\":\\\"crew\\\"}"),
        toolSse("t2", "SpawnTeammate", "{\\\"name\\\":\\\"solver\\\",\\\"prompt\\\":\\\"fix the parser\\\"}"),
        delegated,
        noted,
    };
    var lead_srv = try harness.MockServer.startCassette(&lead_bodies, 0);
    defer lead_srv.stop();
    const lead_url = try lead_srv.urlOwned(a);
    defer a.free(lead_url);

    const workspace: cc.agent_session.WorkspaceConfig = .{ .root = root, .home = root, .state_root = root, .shell = .disabled };
    var refusing = RefusingFactory{};
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .enable_teams = true });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false, .teammates = refusing.factory() });
    defer host.deinit();
    const lead = try host.open(.{ .config = spawnLeadConfig(lead_url, workspace) });
    defer host.release(lead);

    try lead.submit(.{ .text = "form a team and delegate" });
    try waitFor(&lead.journal, "\"type\":\"run_done\"", 2);

    try std.testing.expectEqual(@as(usize, 1), refusing.calls);
    const ids = try host.list(a);
    defer a.free(ids);
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    // Run 2 is the failure: typed for the Host, plain text for the provider.
    try std.testing.expectEqual(@as(usize, 1), try countLines(&lead.journal, "\"kind\":\"teammate_spawn_failed\""));
    try std.testing.expectEqual(@as(usize, 4), lead_srv.requestCount());
    const report = lead_srv.requestAt(3).?.body();
    try std.testing.expect(std.mem.indexOf(u8, report, "teammate-status from=\\\"solver\\\" state=\\\"failed\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "teammate was not started: NoTeammateProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "teammate_spawn_failed") == null);
}
