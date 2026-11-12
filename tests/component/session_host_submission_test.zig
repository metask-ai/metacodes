//! L2 #447: typed submissions and a bounded inbox on SessionHost, driven the
//! way a bot or device adapter in front of a Host drives it.
//!
//! - One idempotency key is one Run, whether the repeat arrives while the
//!   first delivery is queued, running or done, and after a restart that
//!   resumes the Session; a delivery the restart lost before its Run is not
//!   spent. A key reused for a different submission is refused.
//! - A full queue refuses before holding anything, after duplicates are
//!   answered; the snapshot shows the depth and the bound.
//! - `source`, `kind` and `attributes` are echoed on `user_message` and leave
//!   the provider's bytes as they were, unless the Session's template renders
//!   them.
//! - The retention window and the key bound are honoured, and a key the Host
//!   cannot record fails its Run without being spent.
//!
//! Cross-module: session_host + typed_submission + idempotency_ledger +
//! agent_session + protocol.wire + transcript, against cassette providers.

const std = @import("std");
const pfs = @import("platform").fs;
const harness = @import("harness");
const cc = @import("cc");

const SessionHost = cc.session_host.SessionHost;
const Submission = cc.session_host.Submission;
const EventJournal = cc.event_journal.EventJournal;

fn textSse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_t\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{text});
}

/// A cassette of `count` plain replies, owned.
const Replies = struct {
    bodies: [8][]u8 = undefined,
    count: usize = 0,

    fn init(count: usize) !Replies {
        var replies = Replies{};
        errdefer replies.deinit();
        while (replies.count < count) : (replies.count += 1) {
            var name_buf: [16]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "reply {d}", .{replies.count + 1});
            replies.bodies[replies.count] = try textSse(std.testing.allocator, name);
        }
        return replies;
    }

    fn slice(self: *const Replies) []const []const u8 {
        return self.bodies[0..self.count];
    }

    fn deinit(self: *Replies) void {
        for (self.bodies[0..self.count]) |body| std.testing.allocator.free(body);
    }
};

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

/// Waits until `needle` occurs in at least `count` journal lines.
fn waitFor(journal: *EventJournal, needle: []const u8, count: usize) !void {
    var waited: u64 = 0;
    while (waited < 10_000) : (waited += 20) {
        if (try countLines(journal, needle) >= count) return;
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

fn baseConfig(url: []const u8, workspace: []const u8, home: []const u8) cc.agent_session.SessionConfig {
    return .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .default,
        .workspace = .{ .root = workspace, .home = home },
        .allowed_tools = &.{},
    };
}

const Dirs = struct {
    tmp: std.testing.TmpDir,
    ws_buf: [std.fs.max_path_bytes]u8 = undefined,
    home_buf: [std.fs.max_path_bytes]u8 = undefined,
    workspace: []const u8 = "",
    home: []const u8 = "",

    /// In place: the slices point into the buffers.
    fn init(self: *Dirs) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        self.workspace = try subdir(&self.tmp, "workspace", &self.ws_buf);
        self.home = try subdir(&self.tmp, "home", &self.home_buf);
    }

    fn deinit(self: *Dirs) void {
        self.tmp.cleanup();
    }
};

/// An IM message as an adapter submits it.
const im_event = Submission{
    .text = "deploy the hotfix",
    .source = "im:lark",
    .kind = "message",
    .idempotency_key = "im:evt-0001",
    .attributes = &.{ .{ .name = "chat", .value = "C1" }, .{ .name = "sender", .value = "alice" } },
};

test "L2 #447 SessionHost: one idempotency key is one Run while queued, running or done; a reused key is refused" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.deinit();
    var replies = try Replies.init(2);
    defer replies.deinit();
    var server = try harness.MockServer.startCassette(replies.slice(), 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
    defer host.release(hosted);

    // Running: Run 1's response is held while the repeat arrives. A retry may
    // trace itself differently; it is the same delivery.
    server.gateResponseAt(0);
    try hosted.submit(im_event);
    try server.waitUntilResponseGated();
    var retry = im_event;
    retry.trace_id = "retry-1";
    try std.testing.expectError(error.DuplicateSubmission, hosted.submit(retry));

    // Queued: a second event waits behind Run 1; its repeat is a duplicate,
    // and its key on a different submission is refused.
    var telemetry = Submission{
        .text = "heart rate high",
        .source = "device:hr-01",
        .kind = "telemetry",
        .idempotency_key = "hr-01:seq-42",
        .attributes = &.{.{ .name = "bpm", .value = "132" }},
    };
    try hosted.submit(telemetry);
    try std.testing.expectError(error.DuplicateSubmission, hosted.submit(telemetry));
    var reused = telemetry;
    reused.attributes = &.{.{ .name = "bpm", .value = "133" }};
    try std.testing.expectError(error.IdempotencyKeyReused, hosted.submit(reused));
    {
        var snapshot = try hosted.snapshot(a);
        defer snapshot.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), snapshot.queued);
    }
    // Typed fields are checked before anything is queued.
    try std.testing.expectError(error.InvalidKind, hosted.submit(.{ .text = "x", .kind = "Telemetry" }));
    try std.testing.expectError(error.InvalidIdempotencyKey, hosted.submit(.{ .text = "x", .idempotency_key = "has space" }));
    try std.testing.expectError(error.InvalidAttributes, hosted.submit(.{ .text = "x", .attributes = &.{ .{ .name = "a", .value = "1" }, .{ .name = "a", .value = "2" } } }));
    try std.testing.expectError(error.InvalidSource, hosted.submit(.{ .text = "x", .source = "" }));

    server.releaseGatedResponse();
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);

    // Done: still the same Run.
    try std.testing.expectError(error.DuplicateSubmission, hosted.submit(im_event));
    telemetry.trace_id = "late-retry";
    try std.testing.expectError(error.DuplicateSubmission, hosted.submit(telemetry));

    // Two Runs, two provider requests, one user_message per key, each
    // echoing what was submitted.
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    try std.testing.expectEqual(@as(usize, 2), try countLines(&hosted.journal, "\"type\":\"user_message\""));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":1,\"trace_id\":null,\"text\":\"deploy the hotfix\",\"replaces\":null,\"source\":\"im:lark\",\"kind\":\"message\",\"idempotency_key\":\"im:evt-0001\",\"attributes\":{\"chat\":\"C1\",\"sender\":\"alice\"}}}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "{\"v\":1,\"type\":\"user_message\",\"data\":{\"run_id\":2,\"trace_id\":null,\"text\":\"heart rate high\",\"replaces\":null,\"source\":\"device:hr-01\",\"kind\":\"telemetry\",\"idempotency_key\":\"hr-01:seq-42\",\"attributes\":{\"bpm\":\"132\"}}}"));
    try std.testing.expectEqual(@as(usize, 2), try countLines(&hosted.journal, "\"stop_reason\":\"end_turn\""));
}

test "L2 #447 SessionHost: after a restart that resumes the Session a started key is still a duplicate; one the restart dropped unrun is not" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.deinit();
    var replies = try Replies.init(3);
    defer replies.deinit();
    var server = try harness.MockServer.startCassette(replies.slice(), 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const config = baseConfig(url, dirs.workspace, dirs.home);
    const id = cc.session_id.gen();
    const dropped = Submission{ .text = "reading 43", .kind = "telemetry", .idempotency_key = "hr-01:seq-43" };

    {
        const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
        defer runtime.destroy() catch unreachable;
        var host = SessionHost.init(a, runtime, .{});
        const hosted = try host.open(.{ .config = config, .id = id });
        try hosted.submit(im_event);
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
        // A Run in flight, and a keyed delivery queued behind it when the
        // Host stops.
        server.gateResponseAt(1);
        try hosted.submit(.{ .text = "busy" });
        try server.waitUntilResponseGated();
        try hosted.submit(dropped);
        hosted.release();
        host.deinit();
        server.releaseGatedResponse();
        try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    }

    // A new Host, as after a process restart, resumes the Session.
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const resumed = try host.open(.{ .config = config, .id = id, .mode = .@"resume" });
    defer host.release(resumed);
    var redelivered = im_event;
    redelivered.trace_id = "after-restart";
    try std.testing.expectError(error.DuplicateSubmission, resumed.submit(redelivered));
    var reused = im_event;
    reused.text = "roll back";
    try std.testing.expectError(error.IdempotencyKeyReused, resumed.submit(reused));
    // The dropped delivery never ran, so its key was never spent.
    try resumed.submit(dropped);
    try waitFor(&resumed.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectError(error.DuplicateSubmission, resumed.submit(dropped));

    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    try std.testing.expectEqual(@as(usize, 1), try countLines(&resumed.journal, "\"type\":\"user_message\""));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&resumed.journal, "\"idempotency_key\":\"hr-01:seq-43\""));
    try std.testing.expectEqual(@as(usize, 0), try countLines(&resumed.journal, "im:evt-0001"));
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "reading 43") != null);
    // The resumed conversation holds the first Run's message once.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "deploy the hotfix"));
}

test "L2 #447 SessionHost: a full queue refuses with QueueFull and holds nothing; the snapshot shows the depth and the bound" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.deinit();
    var replies = try Replies.init(4);
    defer replies.deinit();
    var server = try harness.MockServer.startCassette(replies.slice(), 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .max_queued = 2, .transcripts = false });
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
    defer host.release(hosted);

    server.gateResponseAt(0);
    try hosted.submit(.{ .text = "busy" });
    try server.waitUntilResponseGated();
    const first = Submission{ .text = "reading 1", .idempotency_key = "seq-1" };
    const second = Submission{ .text = "reading 2", .idempotency_key = "seq-2" };
    const third = Submission{ .text = "reading 3", .idempotency_key = "seq-3" };
    try hosted.submit(first);
    try hosted.submit(second);
    try std.testing.expectError(error.QueueFull, hosted.submit(third));
    try std.testing.expectError(error.QueueFull, hosted.command(.compact));
    // A repeat of accepted work is a duplicate even now, never told to back off.
    try std.testing.expectError(error.DuplicateSubmission, hosted.submit(first));
    {
        var snapshot = try hosted.snapshot(a);
        defer snapshot.deinit(a);
        try std.testing.expectEqual(@as(usize, 2), snapshot.queued);
        try std.testing.expectEqual(@as(usize, 2), snapshot.max_queued);
    }

    server.releaseGatedResponse();
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 3);
    // Refused for the bound, the delivery held no key: its retry runs.
    try hosted.submit(third);
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 4);
    try std.testing.expectEqual(@as(usize, 4), server.requestCount());
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"idempotency_key\":\"seq-3\""));
    var snapshot = try hosted.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), snapshot.queued);
    try std.testing.expectEqual(@as(usize, 2), snapshot.max_queued);
}

test "L2 #447 SessionHost: source, kind, key and attributes leave the provider's bytes unchanged unless the template renders them" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.deinit();
    var replies = try Replies.init(3);
    defer replies.deinit();
    var server = try harness.MockServer.startCassette(replies.slice(), 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false });
    defer host.deinit();
    const config = baseConfig(url, dirs.workspace, dirs.home);
    const id = cc.session_id.gen();

    // The same fresh conversation under the same id, once with the text
    // alone and once typed: the provider receives the same bytes.
    for ([_]Submission{ .{ .text = im_event.text }, im_event }) |submission| {
        const hosted = try host.open(.{ .config = config, .id = id });
        try hosted.submit(submission);
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
        host.release(hosted);
        try host.close(id);
    }
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const plain = (server.requestAt(0) orelse return error.NoRequestCaptured).body();
    const typed = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    try std.testing.expectEqualStrings(plain, typed);
    for ([_][]const u8{ "im:lark", "im:evt-0001", "alice", "sender" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, typed, needle) == null);
    }

    // A template is the one way in, and only for what it names.
    try std.testing.expectError(error.InvalidSubmissionTemplate, host.open(.{ .config = config, .submission_template = "{{text}} from {{trace_id}}" }));
    const templated = try host.open(.{ .config = config, .submission_template = "[{{source}}/{{kind}}] {{text}}\n{{attributes}}" });
    defer host.release(templated);
    try templated.submit(im_event);
    try waitFor(&templated.journal, "\"type\":\"run_done\"", 1);
    const rendered = (server.requestAt(2) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[im:lark/message] deploy the hotfix\\n{\\\"chat\\\":\\\"C1\\\",\\\"sender\\\":\\\"alice\\\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "im:evt-0001") == null);
    // The journal keeps the submitted text; the template shaped only the input.
    try std.testing.expectEqual(@as(usize, 1), try countLines(&templated.journal, "\"text\":\"deploy the hotfix\",\"replaces\":null,\"source\":\"im:lark\""));
}

test "L2 #447 SessionHost options: the retention window and the key bound forget started keys" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.deinit();
    var replies = try Replies.init(5);
    defer replies.deinit();
    var server = try harness.MockServer.startCassette(replies.slice(), 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const config = baseConfig(url, dirs.workspace, dirs.home);
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    const k1 = Submission{ .text = "reading 1", .idempotency_key = "seq-1" };
    const k2 = Submission{ .text = "reading 2", .idempotency_key = "seq-2" };

    {
        // A zero window: a started key is forgotten as soon as time moves.
        var host = SessionHost.init(a, runtime, .{ .transcripts = false, .idempotency_retention_ms = 0 });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config });
        defer host.release(hosted);
        try hosted.submit(k1);
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
        try hosted.submit(k1);
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
        try std.testing.expectEqual(@as(usize, 2), try countLines(&hosted.journal, "\"idempotency_key\":\"seq-1\""));
    }
    {
        // One key kept: the newest started key stays, the older one goes.
        var host = SessionHost.init(a, runtime, .{ .transcripts = false, .idempotency_max_keys = 1 });
        defer host.deinit();
        const hosted = try host.open(.{ .config = config });
        defer host.release(hosted);
        try hosted.submit(k1);
        try hosted.submit(k2);
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
        try std.testing.expectError(error.DuplicateSubmission, hosted.submit(k2));
        try hosted.submit(k1);
        try waitFor(&hosted.journal, "\"type\":\"run_done\"", 3);
        try std.testing.expectEqual(@as(usize, 2), try countLines(&hosted.journal, "\"idempotency_key\":\"seq-1\""));
    }
    try std.testing.expectEqual(@as(usize, 5), server.requestCount());
}

test "L2 #447 SessionHost: a key the Host cannot record fails its Run before any request and stays unspent" {
    const a = std.testing.allocator;
    var dirs: Dirs = undefined;
    try dirs.init();
    defer dirs.deinit();
    var replies = try Replies.init(1);
    defer replies.deinit();
    var server = try harness.MockServer.startCassette(replies.slice(), 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const hosted = try host.open(.{ .config = baseConfig(url, dirs.workspace, dirs.home) });
    defer host.release(hosted);

    // A directory where the ledger file belongs (doc/API.md names it):
    // nothing can be appended.
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const ledger_path = try std.fmt.bufPrintZ(&path_buf, "{s}/idempotency.jsonl", .{hosted.writer.?.dir});
    try std.testing.expectEqual(@as(c_int, 0), pfs.mkdir(ledger_path.ptr, 0o700));
    try hosted.submit(im_event);
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 1);
    try std.testing.expectEqual(@as(usize, 1), try countLines(&hosted.journal, "\"type\":\"run_done\",\"data\":{\"run_id\":1,\"trace_id\":null,\"stop_reason\":null,\"error_name\":\"IdempotencyKeyNotRecorded\",\"model_error\":null}"));
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());

    // Not spent: once the ledger can be written, the same delivery runs once.
    try std.testing.expectEqual(@as(c_int, 0), pfs.rmdir(ledger_path.ptr));
    try hosted.submit(im_event);
    try waitFor(&hosted.journal, "\"type\":\"run_done\"", 2);
    try std.testing.expectError(error.DuplicateSubmission, hosted.submit(im_event));
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    try std.testing.expect(pfs.exists(ledger_path.ptr));
}
