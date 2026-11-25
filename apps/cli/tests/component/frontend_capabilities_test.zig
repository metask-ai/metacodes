//! L2: a frontend's capability frame (doc/WIRE_PROTOCOL.md §2) changes what
//! it is asked. Two Hosts, each driven the way its frontend drives it:
//!
//! - the bundled HTTP surface (`WebServer` + `WebBackend`) over loopback. The
//!   test is the browser: it POSTs the frame, reads `/events` and answers
//!   `/respond`, while a tool asks for custom UIs through
//!   `ToolContext.requestUiCustom`.
//! - `SessionHost`, a real AgentSession against a MockServer provider:
//!   AskUserQuestion and a Write permission prompt, routed by the frame the
//!   Host handed to `HostedSession.declareCapabilities`.
//!
//! Every request is shown both ways: announced and answered while the
//! frontend renders it (or never declared), and `ui_request_unavailable`
//! with no announcement, no round trip and the tool's own fallback once the
//! declaration leaves it out. The tool results the provider receives are
//! checked word for word: a request the frontend cannot render reads as
//! that, never as the user's refusal, and a real refusal keeps its wording.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const pnet = @import("platform").net;

const EventJournal = cc.event_journal.EventJournal;
const WebBackend = cc.web_backend.WebBackend;
const WebServer = cc.web_server.WebServer;

// ── journal helpers ──────────────────────────────────────────────────────────

/// Waits until `needle` occurs in at least `count` journal lines.
fn waitFor(journal: *EventJournal, needle: []const u8, count: usize) !void {
    var waited: u64 = 0;
    while (waited < 10_000) : (waited += 20) {
        if (try countLines(journal, needle) >= count) return;
        cc.util_time.sleepMs(20);
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
fn newestRequestId(journal: *EventJournal) !u64 {
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
        id = try std.fmt.parseInt(u64, rest[0 .. std.mem.indexOfScalar(u8, rest, ',') orelse continue], 10);
    }
    return id orelse error.NoRequest;
}

// ── the HTTP surface ─────────────────────────────────────────────────────────

fn request(a: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, body: []const u8, until: ?[]const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ method, path, body.len, body });
    defer a.free(raw);
    const deadline = cc.util_time.nowMs() + 10_000;
    const conn = pnet.connectLoopback(port) catch return error.ConnectFailed;
    defer pnet.closeSocket(conn);
    pnet.setRecvTimeoutMs(conn, 500);
    var pos: usize = 0;
    while (pos < raw.len) {
        const n = pnet.send(conn, raw[pos..]);
        if (n > 0) {
            pos += @intCast(n);
        } else if (n == 0 or !pnet.recvRetriable() or cc.util_time.nowMs() > deadline) {
            return error.WriteFailed;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (cc.util_time.nowMs() <= deadline) {
        const n = pnet.recv(conn, &chunk);
        if (n == 0) break;
        if (n < 0) {
            if (!pnet.recvRetriable()) break;
            continue;
        }
        try out.appendSlice(a, chunk[0..@intCast(n)]);
        if (until) |u| {
            if (std.mem.indexOf(u8, out.items, u) != null) break;
        }
    }
    return out.toOwnedSlice(a);
}

fn responseBody(resp: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return "";
    return resp[sep + 4 ..];
}

const NoState = struct {
    fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "{}");
    }
};

/// A tool asking for a custom UI on its own thread, as a tool does: the call
/// blocks until the frontend answers.
const CustomAsk = struct {
    requester: cc.ui_request.UiRequester,
    kind: []const u8,
    thread: std.Thread = undefined,
    answer: ?[]u8 = null,
    failure: ?anyerror = null,

    fn start(self: *CustomAsk) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *CustomAsk) void {
        self.answer = ask(self.requester, self.kind) catch |err| {
            self.failure = err;
            return;
        };
    }

    fn join(self: *CustomAsk) ![]u8 {
        self.thread.join();
        if (self.failure) |err| return err;
        return self.answer.?;
    }
};

/// `ToolContext.requestUiCustom` through `requester`; the answer is
/// testing.allocator's.
fn ask(requester: cc.ui_request.UiRequester, kind: []const u8) ![]u8 {
    return askReporting(requester, kind, null);
}

/// `ask`, also handing back (testing.allocator's) the error detail the model
/// would read when the request fails.
fn askReporting(requester: cc.ui_request.UiRequester, kind: []const u8, detail_out: ?*?[]u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var detail: ?[]const u8 = null;
    const ctx = cc.tool_context.ToolContext{ .allocator = arena.allocator(), .ui_requester = requester, .error_detail = &detail };
    const answer = ctx.requestUiCustom(arena.allocator(), kind, "{\"clips\":[1,2]}") catch |err| {
        if (detail_out) |out| out.* = if (detail) |text| try std.testing.allocator.dupe(u8, text) else null;
        return err;
    };
    return std.testing.allocator.dupe(u8, answer);
}

/// Aborts `signal` after 5 s unless stopped first, so a request that should
/// have been answered at once but was announced fails instead of hanging.
const Watchdog = struct {
    signal: *cc.util_abort.AbortSignal,
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn start(self: *Watchdog) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Watchdog) void {
        var waited: u64 = 0;
        while (waited < 5_000 and !self.done.load(.acquire)) : (waited += 20) cc.util_time.sleepMs(20);
        if (!self.done.load(.acquire)) self.signal.abort(.user_interrupt);
    }

    fn stop(self: *Watchdog) void {
        self.done.store(true, .release);
        self.thread.join();
    }
};

test "L2 web: custom kinds reach the frontend only as declared, by exact version; a refused frame changes nothing" {
    const a = std.testing.allocator;
    var journal = EventJournal.init(a);
    defer journal.deinit();
    var wb = WebBackend.init(a, &journal);
    defer wb.deinit();
    var signal = cc.util_abort.AbortSignal.init();
    wb.abort = &signal;
    var inbox = cc.web_submission.SubmissionQueue.init(a);
    defer inbox.deinit();
    var dummy: u8 = 0;
    const server = try WebServer.start(a, .{ .version = "0.0.0-test" }, .{
        .journal = &journal,
        .web_backend = &wb,
        .inbox = &inbox,
        .abort = &signal,
        .state_ctx = @ptrCast(&dummy),
        .state_fn = &NoState.state,
    });
    defer server.stop();
    const port = server.port;

    // Undeclared: the frontend receives every kind, the unversioned one too,
    // exactly as before the exchange existed.
    var legacy = CustomAsk{ .requester = wb.requester(), .kind = "video_timeline" };
    try legacy.start();
    try waitFor(&journal, "\"kind\":\"custom\",\"request\":{\"kind\":\"video_timeline\"", 1);
    const legacy_id = try newestRequestId(&journal);
    var legacy_body: [96]u8 = undefined;
    const legacy_reply = try request(a, port, "POST", "/respond", try std.fmt.bufPrint(&legacy_body, "{{\"id\":{d},\"result\":{{\"cut\":[0,4]}}}}", .{legacy_id}), null);
    defer a.free(legacy_reply);
    try std.testing.expect(std.mem.indexOf(u8, legacy_reply, "200 OK") != null);
    const legacy_answer = try legacy.join();
    defer a.free(legacy_answer);
    try std.testing.expectEqualStrings("{\"cut\":[0,4]}", legacy_answer);

    // A frame of another version is refused with this core's version and
    // installs nothing.
    const refused = try request(a, port, "POST", "/capabilities", "{\"v\":2,\"type\":\"capabilities\",\"ui_requests\":[]}", null);
    defer a.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "400 Bad Request") != null);
    try std.testing.expectEqualStrings("{\"v\":1,\"type\":\"capabilities_refused\",\"reason\":\"SchemaVersionMismatch\"}", responseBody(refused));
    try std.testing.expectEqual(@as(?[]u8, null), try wb.acceptedCapabilities(a));
    try std.testing.expectEqual(@as(usize, 0), try countLines(&journal, "capabilities_accepted"));

    // The frontend renders permission prompts and video_timeline@1 only.
    const frame = "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[\"permission\"],\"custom\":[\"video_timeline@1\"],\"events\":[\"text_chunk\"]}";
    const accepted = try request(a, port, "POST", "/capabilities", frame, null);
    defer a.free(accepted);
    try std.testing.expect(std.mem.indexOf(u8, accepted, "200 OK") != null);
    const ack = "{\"v\":1,\"type\":\"capabilities_accepted\",\"ui_requests\":[\"permission\"],\"custom\":[\"video_timeline@1\"],\"events\":[\"text_chunk\"],\"ignored\":{\"ui_requests\":[],\"events\":[]}}";
    try std.testing.expectEqualStrings(ack, responseBody(accepted));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&journal, ack));
    const in_force = (try wb.acceptedCapabilities(a)).?;
    defer a.free(in_force);
    try std.testing.expectEqualStrings(ack, in_force);
    // The SSE stream a reconnecting frontend replays shows the declaration.
    const replay = try request(a, port, "GET", "/events?since=0", "", "capabilities_accepted");
    defer a.free(replay);
    try std.testing.expect(std.mem.indexOf(u8, replay, ack) != null);

    // Another major and an unversioned kind: no announcement, no wait, the
    // tool's fallback at once.
    var watchdog = Watchdog{ .signal = &signal };
    try watchdog.start();
    var other_major_detail: ?[]u8 = null;
    defer if (other_major_detail) |text| a.free(text);
    const other_major = askReporting(wb.requester(), "video_timeline@2", &other_major_detail);
    const unversioned = ask(wb.requester(), "video_timeline");
    watchdog.stop();
    try std.testing.expectError(error.CustomUiUnsupported, other_major);
    try std.testing.expectError(error.CustomUiUnsupported, unversioned);
    // What the model reads if the tool does not recover: the frontend, not
    // the user, is why nothing appeared.
    try std.testing.expectEqualStrings(
        "The custom UI 'video_timeline@2' was not shown: the frontend connected to this session did not declare that it renders this kind. This is not a decision by the user.",
        other_major_detail.?,
    );
    try std.testing.expect(!signal.isAborted());
    try std.testing.expectEqual(@as(usize, 1), try countLines(&journal, "{\"v\":1,\"type\":\"ui_request_unavailable\",\"kind\":\"custom\",\"custom_kind\":\"video_timeline@2\",\"reason\":\"custom_kind_not_declared\"}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&journal, "{\"v\":1,\"type\":\"ui_request_unavailable\",\"kind\":\"custom\",\"custom_kind\":\"video_timeline\",\"reason\":\"custom_kind_unversioned\"}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(&journal, "\"type\":\"ui_request\","));
    try std.testing.expectEqual(@as(u64, 0), wb.pendingId());

    // The declared kind is announced, takes a later id and is answered.
    var declared = CustomAsk{ .requester = wb.requester(), .kind = "video_timeline@1" };
    try declared.start();
    try waitFor(&journal, "\"kind\":\"custom\",\"request\":{\"kind\":\"video_timeline@1\"", 1);
    const declared_id = try newestRequestId(&journal);
    try std.testing.expect(declared_id > legacy_id);
    var declared_body: [96]u8 = undefined;
    const reply = try request(a, port, "POST", "/respond", try std.fmt.bufPrint(&declared_body, "{{\"id\":{d},\"result\":{{\"cut\":[1,3]}}}}", .{declared_id}), null);
    defer a.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "200 OK") != null);
    const answer = try declared.join();
    defer a.free(answer);
    try std.testing.expectEqualStrings("{\"cut\":[1,3]}", answer);
    try std.testing.expectEqual(@as(usize, 2), try countLines(&journal, "\"type\":\"ui_request\","));
}

// ── SessionHost ──────────────────────────────────────────────────────────────

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_a\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Favorite color?\\\",\\\"header\\\":\\\"Color\\\",\\\"options\\\":[{\\\"label\\\":\\\"Red\\\",\\\"description\\\":\\\"r\\\"},{\\\"label\\\":\\\"Blue\\\",\\\"description\\\":\\\"b\\\"}],\\\"multiSelect\\\":false}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const DONE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_t\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

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

/// The newest tool_result the provider received in request `index`, as the
/// model reads it (earlier turns' results ride along before it).
fn newestToolResult(server: *harness.MockServer, index: usize) ![]const u8 {
    const body = (server.requestAt(index) orelse return error.NoRequestCaptured).body();
    const at = std.mem.lastIndexOf(u8, body, "\"tool_result\"") orelse return error.NoToolResult;
    return body[at..];
}

fn toolResultIsError(server: *harness.MockServer, index: usize) !bool {
    return std.mem.indexOf(u8, try newestToolResult(server, index), "\"is_error\":true") != null;
}

/// Whether the model read `text` in the newest tool_result of request `index`.
fn modelRead(server: *harness.MockServer, index: usize, text: []const u8) !bool {
    return std.mem.indexOf(u8, try newestToolResult(server, index), text) != null;
}

const UNRENDERABLE_PERMISSION = "'Write' was denied without asking: the frontend connected to this session cannot render permission prompts";

test "L2 SessionHost: AskUserQuestion and permission prompts are routed by the declared capabilities" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);
    const denied_path = try std.fmt.allocPrint(a, "{s}/denied.txt", .{workspace});
    defer a.free(denied_path);
    const allowed_path = try std.fmt.allocPrint(a, "{s}/allowed.txt", .{workspace});
    defer a.free(allowed_path);
    const write_denied = try writeToolSse(a, denied_path);
    defer a.free(write_denied);
    const write_allowed = try writeToolSse(a, allowed_path);
    defer a.free(write_allowed);
    const declined_path = try std.fmt.allocPrint(a, "{s}/declined.txt", .{workspace});
    defer a.free(declined_path);
    const write_declined = try writeToolSse(a, declined_path);
    defer a.free(write_declined);

    // Provider requests, in order: 0-1 ask (undeclared), 2-3 ask (declared
    // without ask_question), 4-5 write (declared nothing), 6-7 write
    // (declared permission, granted), 8-9 write (declared, user declines).
    const bodies = [_][]const u8{ ASK_SSE, DONE_SSE, ASK_SSE, DONE_SSE, write_denied, DONE_SSE, write_allowed, DONE_SSE, write_declined, DONE_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const tools = [_][]const u8{ "AskUserQuestion", "Write" };
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &tools });
    defer runtime.destroy() catch unreachable;
    var host = cc.session_host.SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const hosted = try host.open(.{ .config = .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .default,
        .workspace = .{ .root = workspace, .home = home },
        .allowed_tools = &tools,
    } });
    defer host.release(hosted);
    const journal = &hosted.journal;

    // Undeclared: the question is announced and answered.
    try hosted.submit(.{ .text = "ask while undeclared" });
    try waitFor(journal, "\"type\":\"ui_request\",\"id\":1,\"kind\":\"ask_question\"", 1);
    try hosted.respond(1, "{\"answers\":[\"Red\"]}");
    try waitFor(journal, "\"type\":\"run_done\"", 1);
    try std.testing.expect(!try toolResultIsError(server, 1));
    try std.testing.expect(std.mem.indexOf(u8, server.requestAt(1).?.body(), "Red") != null);

    // A refused frame leaves the Session undeclared.
    try std.testing.expectError(error.SchemaVersionMismatch, hosted.declareCapabilities(a, "{\"type\":\"capabilities\",\"ui_requests\":[]}"));

    // Declared without ask_question: AskUserQuestion fails at once, nothing
    // is announced, the Run still ends.
    const ack = try hosted.declareCapabilities(a, "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[\"permission\"]}");
    defer a.free(ack);
    try std.testing.expectEqualStrings("{\"v\":1,\"type\":\"capabilities_accepted\",\"ui_requests\":[\"permission\"],\"custom\":[],\"events\":null,\"ignored\":{\"ui_requests\":[],\"events\":[]}}", ack);
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, ack));
    try hosted.submit(.{ .text = "ask while declared without questions" });
    try waitFor(journal, "\"type\":\"run_done\"", 2);
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, "{\"v\":1,\"type\":\"ui_request_unavailable\",\"kind\":\"ask_question\",\"reason\":\"kind_not_declared\"}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, "\"type\":\"ui_request\","));
    // The model is told the truth: no one saw the question.
    try std.testing.expect(try toolResultIsError(server, 3));
    try std.testing.expect(try modelRead(server, 3, "AskUserQuestion was not shown: the frontend connected to this session cannot render questions"));
    try std.testing.expect(try modelRead(server, 3, "This is not an answer or a refusal from the user."));
    try std.testing.expect(try modelRead(server, 3, "capability_unsupported"));
    try std.testing.expect(!try modelRead(server, 3, "NotATty"));

    // Declared nothing: the Write permission prompt is unrenderable, which
    // the gate answers as a denial. The file is never written, and the model
    // is not told the user declined.
    const nothing = try hosted.declareCapabilities(a, "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[]}");
    defer a.free(nothing);
    try hosted.submit(.{ .text = "write while declared nothing" });
    try waitFor(journal, "\"type\":\"run_done\"", 3);
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, "{\"v\":1,\"type\":\"ui_request_unavailable\",\"kind\":\"permission\",\"reason\":\"kind_not_declared\"}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, "\"type\":\"ui_request\","));
    try std.testing.expect(!try exists(workspace, "denied.txt"));
    try std.testing.expect(try toolResultIsError(server, 5));
    try std.testing.expect(try modelRead(server, 5, UNRENDERABLE_PERMISSION));
    try std.testing.expect(try modelRead(server, 5, "This is not the user's decision; the user never saw the request."));
    try std.testing.expect(try modelRead(server, 5, "permission_denied"));
    try std.testing.expect(!try modelRead(server, 5, "user declined"));

    // Declared permission again: the same prompt is announced and granted.
    const permission = try hosted.declareCapabilities(a, "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[\"permission\",\"ask_question\"]}");
    defer a.free(permission);
    try hosted.submit(.{ .text = "write while declared permission" });
    try waitFor(journal, "\"type\":\"ui_request\",\"id\":2,\"kind\":\"permission\"", 1);
    try hosted.respond(2, "{\"choice\":\"allow_once\"}");
    try waitFor(journal, "\"type\":\"run_done\"", 4);
    try std.testing.expect(try exists(workspace, "allowed.txt"));
    try std.testing.expect(!try toolResultIsError(server, 7));

    // A real decline still reads as the user's decline, word for word.
    try hosted.submit(.{ .text = "write and decline" });
    try waitFor(journal, "\"type\":\"ui_request\",\"id\":3,\"kind\":\"permission\"", 1);
    try hosted.respond(3, "{\"choice\":\"deny_once\"}");
    try waitFor(journal, "\"type\":\"run_done\"", 5);
    try std.testing.expect(!try exists(workspace, "declined.txt"));
    try std.testing.expect(try modelRead(server, 9, "user declined 'Write' via prompt"));
    try std.testing.expect(!try modelRead(server, 9, "without asking"));
    try std.testing.expectEqual(@as(usize, 3), try countLines(journal, "\"type\":\"capabilities_accepted\""));
}
