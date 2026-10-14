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
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"run_done\",\"data\":{\"run_id\":1,\"trace_id\":null,\"stop_reason\":null,\"error_name\":\"CallbackFailed\"}"));
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
