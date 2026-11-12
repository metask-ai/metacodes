//! L2: the multi-session daemon's dynamic session lifecycle over HTTP (#254),
//! driven over real sockets against a real `MultiDaemon` — real Apps (own io
//! runtimes), drivers, journals, the HTTP server and the UDS binding — with a
//! MockServer as the provider.
//!
//!   - create → message → the turn on SSE → listed → destroy: the stream gets
//!     `session_lifecycle.closed` and ends, the session routes are 404 and
//!     `GET /health` drops.
//!   - destroy while a turn generates against a provider that never answers:
//!     bounded, and the driver is joined before the session closes.
//!   - destroy never waits for a lease: SSE and UDS attach end and give their
//!     leases back, and the slot is freed only after the last release
//!     (counters, not a crash: testing.allocator has no page protection, so a
//!     use-after-free test that waits for a crash proves nothing).
//!   - create: caller id, 409 duplicate, 400 malformed, 429 cap, `--sessions 0`.
//!   - `"resume":true` restores the persisted conversation (the provider sees
//!     the earlier turn; the transcript is not written twice);
//!     `/sessions/<id>/resume` is 200 live, 404 otherwise.
//!   - with a token, `/sessions` routes need it; without the daemon they are 404.
//!   - the `--sessions` / `--max-sessions` / `--uds` flag rules.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pnet = @import("platform").net;
const psync = @import("platform").sync;
const ppaths = @import("platform").paths;

const MultiDaemon = cc.daemon_serve_multi.MultiDaemon;
const SessionId = cc.session_id.SessionId;

const TOKEN = "lifecycle-t0ken";
const VERSION = "serve-sessions-test";

fn textSse(comptime text: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ text ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

/// One turn that calls `name` with `input_json`, given escaped as it sits
/// inside a JSON string (`{\"k\":\"v\"}`).
fn toolUseSse(comptime id: []const u8, comptime name: []const u8, comptime input_json: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" ++ input_json ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try std.testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            std.testing.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
    }
};

/// A daemon in a temporary HOME and state root, talking to a MockServer.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    state_root: []const u8,
    guards: [4]EnvGuard,
    provider: *harness.MockServer,
    md: *MultiDaemon,
    uds_path: ?[]const u8,
    token: ?[]const u8,

    const Setup = struct {
        responses: []const []const u8 = &.{textSse("hello from the provider")},
        /// The first provider request gets no response at all (never a head).
        silent_first: bool = false,
        /// Every provider request from this one on gets no response at all.
        silent_from: ?usize = null,
        initial: usize = 0,
        max_sessions: usize = 8,
        token: ?[]const u8 = null,
        uds: bool = false,
        /// `--agent-teams`: sessions offer TeamCreate/SendMessage.
        agent_teams: bool = false,
    };

    /// In place: `self` must be at its final address.
    fn setup(self: *Fixture, options: Setup) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buffer[0..try self.tmp.dir.realPath(std.testing.io, &root_buffer)];
        try self.tmp.dir.createDirPath(std.testing.io, "state");
        self.state_root = try std.fmt.allocPrint(arena, "{s}/state", .{root});

        self.guards[0] = try EnvGuard.set("HOME", (try arena.dupeZ(u8, root)).ptr);
        errdefer self.guards[0].restore();
        self.guards[1] = try EnvGuard.set("METACODES_NO_PROBE", "1");
        errdefer self.guards[1].restore();
        self.guards[2] = try EnvGuard.set("METACODES_KG_AUTOSTART", "0");
        errdefer self.guards[2].restore();
        // Well above every bound below: only the destroy's cancel can end a stalled request in time.
        self.guards[3] = try EnvGuard.set("METACODES_STREAM_IDLE_TIMEOUT_MS", "20000");
        errdefer self.guards[3].restore();

        self.provider = if (options.silent_first)
            try harness.MockServer.startCassetteSilent(options.responses, 0, 0)
        else if (options.silent_from) |first|
            try harness.MockServer.startCassetteSilentFrom(options.responses, first)
        else
            try harness.MockServer.startCassette(options.responses, 0);
        errdefer self.provider.stop();
        const url = try arena.dupeZ(u8, try self.provider.urlOwned(arena));
        const base_argv = [_][*:0]const u8{ "metacodes", "serve", "0", "--base-url", url.ptr, "--model", "test-model", "--permission", "bypassPermissions", "--no-lsp" };
        const teams_argv = base_argv ++ [_][*:0]const u8{"--agent-teams"};
        var config = cc.parseArgsForTest(if (options.agent_teams) &teams_argv else &base_argv, arena);
        try std.testing.expect(config.parse_error == null);
        config.state_root = self.state_root;

        self.uds_path = null;
        if (options.uds) {
            // sun_path holds ~104 bytes: the test's tmp dir path is too long for
            // it. The tmp dir's random name keeps the socket unique.
            self.uds_path = try std.fmt.allocPrint(arena, "/tmp/mc-{s}.sock", .{&self.tmp.sub_path});
        }
        self.token = options.token;
        self.md = try MultiDaemon.start(std.heap.c_allocator, null, config, "test-key", .{
            .initial = options.initial,
            .max_sessions = options.max_sessions,
            .surface = .{ .version = VERSION, .token = options.token },
            .uds_path = self.uds_path,
        });
    }

    fn deinit(self: *Fixture) void {
        self.md.stop();
        self.md.destroy();
        self.provider.stop();
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn port(self: *Fixture) u16 {
        return self.md.port();
    }

    /// One HTTP request, read to the end (owned).
    fn call(self: *Fixture, method: []const u8, path: []const u8, body: []const u8) ![]u8 {
        return self.callAs(self.token, method, path, body);
    }

    fn callAs(self: *Fixture, token: ?[]const u8, method: []const u8, path: []const u8, body: []const u8) ![]u8 {
        const a = std.testing.allocator;
        var auth_buffer: [128]u8 = undefined;
        const auth = if (token) |t| try std.fmt.bufPrint(&auth_buffer, "Authorization: Bearer {s}\r\n", .{t}) else "";
        const raw = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ method, path, auth, body.len, body });
        defer a.free(raw);
        return harness.clientRoundtrip(a, self.port(), raw, null);
    }

    /// `POST /sessions/create` that must answer 201; the new id.
    fn create(self: *Fixture, body: []const u8) !SessionId {
        const response = try self.call("POST", "/sessions/create", body);
        defer std.testing.allocator.free(response);
        try expectStatus(response, "201");
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bodyOf(response), .{});
        defer parsed.deinit();
        return SessionId.fromSlice(parsed.value.object.get("session_id").?.string) orelse error.BadSessionId;
    }

    fn expectHealth(self: *Fixture, sessions: i64) !void {
        const response = try self.callAs(null, "GET", "/health", "");
        defer std.testing.allocator.free(response);
        try expectStatus(response, "200");
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bodyOf(response), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(sessions, parsed.value.object.get("sessions").?.integer);
    }

    /// The status of `method path` (the response is dropped).
    fn status(self: *Fixture, method: []const u8, path: []const u8, body: []const u8) !u16 {
        const response = try self.call(method, path, body);
        defer std.testing.allocator.free(response);
        return statusOf(response);
    }

    fn sessionPath(buffer: []u8, id: SessionId, comptime rest: []const u8) []const u8 {
        return std.fmt.bufPrint(buffer, "/s/{s}" ++ rest, .{id.asSlice()}) catch unreachable;
    }

    fn lifecyclePath(buffer: []u8, id: SessionId, comptime verb: []const u8) []const u8 {
        return std.fmt.bufPrint(buffer, "/sessions/{s}/" ++ verb, .{id.asSlice()}) catch unreachable;
    }

    /// Wait (≤ 5 s) for every lease on a destroyed session to come back, then
    /// reap it, as the daemon's main loop would.
    fn settle(self: *Fixture, id: SessionId) !void {
        const deadline = cc.util_time.nowMs() + 5000;
        while ((self.md.leasesOf(id) orelse 0) != 0) {
            if (cc.util_time.nowMs() >= deadline) return error.LeaseNeverReturned;
            cc.util_time.sleepMs(10);
        }
        self.md.reap();
        if (self.md.leasesOf(id) != null) return error.NotReaped;
    }

    /// Send a prompt to a session; must be accepted.
    fn message(self: *Fixture, id: SessionId, text: []const u8) !void {
        var path_buffer: [64]u8 = undefined;
        var body_buffer: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buffer, "{{\"text\":\"{s}\"}}", .{text});
        const response = try self.call("POST", sessionPath(&path_buffer, id, "/message"), body);
        defer std.testing.allocator.free(response);
        try expectStatus(response, "200");
    }
};

/// A long-lived reader (SSE or UDS attach) on its own thread, reading until
/// the peer closes or 30 s pass.
const Stream = struct {
    conn: pnet.Socket,
    mutex: psync.Mutex = .{},
    bytes: std.ArrayList(u8) = .empty,
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn openSse(fx: *Fixture, id: SessionId) !*Stream {
        const conn = try pnet.connectLoopback(fx.port());
        errdefer pnet.closeSocket(conn);
        var auth_buffer: [128]u8 = undefined;
        const auth = if (fx.token) |t| try std.fmt.bufPrint(&auth_buffer, "Authorization: Bearer {s}\r\n", .{t}) else "";
        var request_buffer: [256]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buffer, "GET /s/{s}/events HTTP/1.1\r\nHost: 127.0.0.1\r\n{s}\r\n", .{ id.asSlice(), auth });
        try sendAll(conn, request);
        return start(conn);
    }

    fn openAttach(path: []const u8, id: SessionId) !*Stream {
        const conn = try pnet.connectUnix(path);
        errdefer pnet.closeSocket(conn);
        var request_buffer: [128]u8 = undefined;
        try sendAll(conn, try std.fmt.bufPrint(&request_buffer, "{{\"op\":\"attach\",\"session\":\"{s}\",\"since\":0}}\n", .{id.asSlice()}));
        return start(conn);
    }

    fn start(conn: pnet.Socket) !*Stream {
        const self = try std.testing.allocator.create(Stream);
        errdefer std.testing.allocator.destroy(self);
        self.* = .{ .conn = conn };
        pnet.setRecvTimeoutMs(conn, 500);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Stream) void {
        const deadline = cc.util_time.nowMs() + 30_000;
        var chunk: [4096]u8 = undefined;
        while (cc.util_time.nowMs() < deadline) {
            const n = pnet.recv(self.conn, &chunk);
            if (n == 0) break; // the peer closed
            if (n < 0) {
                if (pnet.recvRetriable()) continue;
                break;
            }
            self.mutex.lock();
            defer self.mutex.unlock();
            self.bytes.appendSlice(std.testing.allocator, chunk[0..@intCast(n)]) catch break;
        }
        self.done.store(true, .release);
    }

    fn contains(self: *Stream, needle: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return std.mem.indexOf(u8, self.bytes.items, needle) != null;
    }

    /// Wait (≤ 10 s) for `needle` to arrive.
    fn waitFor(self: *Stream, needle: []const u8) !void {
        const deadline = cc.util_time.nowMs() + 10_000;
        while (!self.contains(needle)) {
            if (cc.util_time.nowMs() >= deadline) {
                std.debug.print("stream never showed {s}; got:\n{s}\n", .{ needle, self.bytes.items });
                return error.StreamTimeout;
            }
            cc.util_time.sleepMs(10);
        }
    }

    /// Wait (≤ 10 s) for the peer to close.
    fn waitClosed(self: *Stream) !void {
        const deadline = cc.util_time.nowMs() + 10_000;
        while (!self.done.load(.acquire)) {
            if (cc.util_time.nowMs() >= deadline) return error.StreamStillOpen;
            cc.util_time.sleepMs(10);
        }
    }

    /// Byte offset of `needle`, or null.
    fn offsetOf(self: *Stream, needle: []const u8) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return std.mem.indexOf(u8, self.bytes.items, needle);
    }

    fn destroy(self: *Stream) void {
        pnet.shutdownSocket(self.conn);
        self.thread.join();
        pnet.closeSocket(self.conn);
        self.bytes.deinit(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }
};

fn sendAll(conn: pnet.Socket, bytes: []const u8) !void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = pnet.send(conn, bytes[pos..]);
        if (n <= 0) return error.WriteFailed;
        pos += @intCast(n);
    }
}

/// One NDJSON request on the UDS binding, one response line (owned).
fn udsRequest(path: []const u8, line: []const u8) ![]u8 {
    const conn = try pnet.connectUnix(path);
    defer pnet.closeSocket(conn);
    pnet.setRecvTimeoutMs(conn, 3000);
    try sendAll(conn, line);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);
    var chunk: [4096]u8 = undefined;
    while (std.mem.indexOfScalar(u8, out.items, '\n') == null) {
        const n = pnet.recv(conn, &chunk);
        if (n <= 0) break;
        try out.appendSlice(std.testing.allocator, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(std.testing.allocator);
}

fn statusOf(response: []const u8) u16 {
    if (response.len < 12 or !std.mem.startsWith(u8, response, "HTTP/1.1 ")) return 0;
    return std.fmt.parseInt(u16, response[9..12], 10) catch 0;
}

fn expectStatus(response: []const u8, comptime code: []const u8) !void {
    const expected = comptime std.fmt.parseInt(u16, code, 10) catch unreachable;
    if (statusOf(response) != expected) {
        std.debug.print("expected {d}, got:\n{s}\n", .{ expected, response });
        return error.UnexpectedStatus;
    }
}

fn bodyOf(response: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[at + 4 ..];
}

fn elapsedSince(start_ms: anytype) u64 {
    return @intCast(cc.util_time.nowMs() - start_ms);
}

// ── the round trip ──────────────────────────────────────────────────────────

test "#254 create → message → the turn on SSE → listed → destroy ends the stream; routes 404, /health drops, slot reaped" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.setup(.{});
    defer fx.deinit();

    try fx.expectHealth(0);
    const id = try fx.create("");
    try fx.expectHealth(1);

    const sse = try Stream.openSse(&fx, id);
    defer sse.destroy();
    var needle_buffer: [96]u8 = undefined;
    try sse.waitFor(try std.fmt.bufPrint(&needle_buffer, "\"type\":\"session_lifecycle\",\"data\":{{\"created\":\"{s}\"}}", .{id.asSlice()}));

    try fx.message(id, "hello daemon");
    try sse.waitFor("hello from the provider");
    try sse.waitFor("\"run_done\"");

    // GET /sessions lists it, with what /state reads the same way.
    {
        const response = try fx.call("GET", "/sessions", "");
        defer a.free(response);
        try expectStatus(response, "200");
        const parsed = try std.json.parseFromSlice(std.json.Value, a, bodyOf(response), .{});
        defer parsed.deinit();
        const sessions = parsed.value.object.get("sessions").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), sessions.len);
        const entry = sessions[0].object;
        try std.testing.expectEqualStrings(id.asSlice(), entry.get("session_id").?.string);
        try std.testing.expectEqualStrings("test-model", entry.get("model").?.string);
        try std.testing.expectEqualStrings("bypass_permissions", entry.get("permission_mode").?.string);
        try std.testing.expectEqual(@as(i64, 0), entry.get("pending_request_id").?.integer);
        try std.testing.expect(entry.get("generating").? == .bool);
    }
    // `generating` is live: it settles to false once the run is over.
    {
        const deadline = cc.util_time.nowMs() + 5000;
        while (true) {
            const response = try fx.call("GET", "/sessions", "");
            defer a.free(response);
            if (std.mem.indexOf(u8, response, "\"generating\":false") != null) break;
            if (cc.util_time.nowMs() >= deadline) return error.GeneratingNeverCleared;
            cc.util_time.sleepMs(20);
        }
    }

    var path_buffer: [96]u8 = undefined;
    {
        const response = try fx.call("POST", Fixture.lifecyclePath(&path_buffer, id, "destroy"), "");
        defer a.free(response);
        try expectStatus(response, "200");
        try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    }
    try std.testing.expectEqual(@as(usize, 1), fx.md.stats().drivers_joined);

    // The stream sees the run end, then the session close, then the transport's close, and ends.
    try sse.waitClosed();
    const closed = try std.fmt.bufPrint(&needle_buffer, "\"type\":\"session_lifecycle\",\"data\":{{\"closed\":\"{s}\"}}", .{id.asSlice()});
    const at_run_done = sse.offsetOf("\"run_done\"").?;
    const at_closed = sse.offsetOf(closed) orelse return error.NoClosedLifecycle;
    const at_transport_close = sse.offsetOf("event: session_closed") orelse return error.NoSessionClosedEvent;
    try std.testing.expect(at_run_done < at_closed and at_closed < at_transport_close);

    try std.testing.expectEqual(@as(u16, 404), try fx.status("GET", Fixture.sessionPath(&path_buffer, id, "/state"), ""));
    try std.testing.expectEqual(@as(u16, 404), try fx.status("POST", Fixture.sessionPath(&path_buffer, id, "/message"), "{\"text\":\"late\"}"));
    try fx.expectHealth(0);
    try std.testing.expectEqual(@as(u16, 404), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "resume"), ""));
    try std.testing.expectEqual(@as(u16, 404), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "destroy"), ""));
    {
        const response = try fx.call("GET", "/sessions", "");
        defer a.free(response);
        try std.testing.expectEqualStrings("{\"sessions\":[]}", bodyOf(response));
    }

    // The stream's lease came back when it ended: the reaper frees the slot.
    try std.testing.expectEqual(@as(?usize, 0), fx.md.leasesOf(id));
    fx.md.reap();
    const stats = fx.md.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.reaped);
    try std.testing.expectEqual(@as(usize, 0), stats.retired);
    try std.testing.expectEqual(@as(?usize, null), fx.md.leasesOf(id));
}

test "#254 destroy while a turn is generating: bounded, the driver joined, the run ends before the session closes" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    // The provider takes the request and never answers: only the destroy's
    // abort + cancel ends it (the stream idle limit is 20 s).
    try fx.setup(.{ .silent_first = true });
    defer fx.deinit();

    const id = try fx.create("");
    const sse = try Stream.openSse(&fx, id);
    defer sse.destroy();
    try fx.message(id, "stall please");

    // In flight: the provider holds the request and the session is generating.
    var path_buffer: [96]u8 = undefined;
    {
        const deadline = cc.util_time.nowMs() + 10_000;
        while (true) {
            if (fx.provider.requestCount() >= 1) {
                const response = try fx.call("GET", Fixture.sessionPath(&path_buffer, id, "/state"), "");
                defer a.free(response);
                if (std.mem.indexOf(u8, response, "\"generating\":true") != null) break;
            }
            if (cc.util_time.nowMs() >= deadline) return error.NeverGenerating;
            cc.util_time.sleepMs(20);
        }
    }

    const started = cc.util_time.nowMs();
    {
        // The client gives up after 5 s without a byte: past that the status is moot.
        const response = try fx.call("POST", Fixture.lifecyclePath(&path_buffer, id, "destroy"), "");
        defer a.free(response);
        const took = elapsedSince(started);
        if (took >= 5000) {
            std.debug.print("destroy took {d} ms\n", .{took});
            return error.DestroyNotBounded;
        }
        try expectStatus(response, "200");
    }
    try std.testing.expectEqual(@as(usize, 1), fx.md.stats().drivers_joined);

    // Joined before the close: the aborted run's run_done precedes the closed lifecycle.
    try sse.waitClosed();
    var needle_buffer: [96]u8 = undefined;
    const closed = try std.fmt.bufPrint(&needle_buffer, "\"type\":\"session_lifecycle\",\"data\":{{\"closed\":\"{s}\"}}", .{id.asSlice()});
    const at_run_done = sse.offsetOf("\"type\":\"run_done\",\"data\":{\"run_id\":1,\"trace_id\":null,\"stop_reason\":\"aborted\"") orelse return error.NoAbortedRunDone;
    const at_closed = sse.offsetOf(closed) orelse return error.NoClosedLifecycle;
    try std.testing.expect(at_run_done < at_closed);
    try fx.expectHealth(0);
}

test "#254 destroy never waits for leases: SSE and UDS attach end and give theirs back; the slot is freed after the last release" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the UDS binding is POSIX-only
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.setup(.{ .uds = true });
    defer fx.deinit();

    const id = try fx.create("");
    var needle_buffer: [96]u8 = undefined;
    const created = try std.fmt.bufPrint(&needle_buffer, "\"type\":\"session_lifecycle\",\"data\":{{\"created\":\"{s}\"}}", .{id.asSlice()});

    // Both readers hold a lease from the moment they have read anything.
    const sse = try Stream.openSse(&fx, id);
    defer sse.destroy();
    try sse.waitFor(created);
    const attach = try Stream.openAttach(fx.uds_path.?, id);
    defer attach.destroy();
    try attach.waitFor(created);
    try std.testing.expectEqual(@as(?usize, 2), fx.md.leasesOf(id));

    // The UDS `list` op lists the dynamic table.
    {
        const listed = try udsRequest(fx.uds_path.?, "{\"op\":\"list\"}\n");
        defer a.free(listed);
        try std.testing.expect(std.mem.indexOf(u8, listed, id.asSlice()) != null);
    }

    // A third lease that nobody gives back until the test says so.
    const held = fx.md.resolve(id.asSlice()) orelse return error.NotResolvable;
    try std.testing.expectEqual(@as(?usize, 3), fx.md.leasesOf(id));

    const started = cc.util_time.nowMs();
    var path_buffer: [96]u8 = undefined;
    {
        const response = try fx.call("POST", Fixture.lifecyclePath(&path_buffer, id, "destroy"), "");
        defer a.free(response);
        try expectStatus(response, "200");
    }
    try std.testing.expect(elapsedSince(started) < 5000);
    try std.testing.expectEqual(@as(usize, 1), fx.md.stats().retired);
    // Being destroyed: never resolved again, never listed.
    try std.testing.expect(fx.md.resolve(id.asSlice()) == null);
    {
        const listed = try udsRequest(fx.uds_path.?, "{\"op\":\"list\"}\n");
        defer a.free(listed);
        try std.testing.expect(std.mem.indexOf(u8, listed, id.asSlice()) == null);
    }

    // The journal close ends both readers; each sees the closed lifecycle and
    // its transport's close, and gives its lease back.
    const closed = try std.fmt.bufPrint(&needle_buffer, "\"type\":\"session_lifecycle\",\"data\":{{\"closed\":\"{s}\"}}", .{id.asSlice()});
    try sse.waitClosed();
    try attach.waitClosed();
    try std.testing.expect(sse.contains(closed) and sse.contains("event: session_closed"));
    try std.testing.expect(attach.contains(closed) and attach.contains("{\"type\":\"session_closed\"}"));
    try std.testing.expectEqual(@as(?usize, 1), fx.md.leasesOf(id));

    // Not freed while a lease is out, however often the reaper runs.
    fx.md.reap();
    fx.md.reap();
    try std.testing.expectEqual(@as(usize, 0), fx.md.stats().reaped);
    try std.testing.expectEqual(@as(usize, 1), fx.md.stats().retired);
    // The lease still reads the session it was given (nothing was freed under it).
    try std.testing.expect(held.view.journal.isClosed());

    held.release();
    fx.md.reap();
    try std.testing.expectEqual(@as(usize, 1), fx.md.stats().reaped);
    try std.testing.expectEqual(@as(usize, 0), fx.md.stats().retired);
    try std.testing.expectEqual(@as(?usize, null), fx.md.leasesOf(id));
}

const START_BACKGROUND_AGENT = toolUseSse("tu_bg", "Task", "{\\\"description\\\":\\\"slow work\\\",\\\"prompt\\\":\\\"run the slow command\\\",\\\"subagent_type\\\":\\\"general-purpose\\\",\\\"run_in_background\\\":true}");

test "#254 destroy stops the session's background work before it returns: an agent job busy in a shell" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the job runs `sleep`
    // The session's next turn and the job's first turn (in either order) each
    // get `sleep 30`: both are in a shell when the destroy lands.
    const sleep_long = toolUseSse("tu_sleep", "Bash", "{\\\"command\\\":\\\"sleep 30\\\"}");
    var fx: Fixture = undefined;
    try fx.setup(.{ .responses = &.{ START_BACKGROUND_AGENT, sleep_long, sleep_long } });
    defer fx.deinit();
    try expectDestroyStopsBackgroundAgent(&fx);
}

test "#254 destroy stops the session's background work before it returns: an agent job stalled in a provider request" {
    // After turn 1 nothing answers: the session and the job both wait on a
    // silent provider, which only a cancel ends (the idle limit is 20 s).
    var fx: Fixture = undefined;
    try fx.setup(.{ .responses = &.{START_BACKGROUND_AGENT}, .silent_from = 1 });
    defer fx.deinit();
    try expectDestroyStopsBackgroundAgent(&fx);
}

/// Turn 1 of the session starts a background agent job; once the job runs
/// (and the session generates), a destroy must return within 5 s with the
/// job already stopped, as a lease that outlives the destroy reads it.
fn expectDestroyStopsBackgroundAgent(fx: *Fixture) !void {
    const a = std.testing.allocator;
    const id = try fx.create("");
    try fx.message(id, "start the background work");

    // Running: the job is on the session's roster and three requests are out
    // (turn 1, the session's turn 2, the job's turn 1).
    var path_buffer: [96]u8 = undefined;
    {
        const deadline = cc.util_time.nowMs() + 15_000;
        while (true) {
            if (fx.provider.requestCount() >= 3) {
                const response = try fx.call("GET", Fixture.sessionPath(&path_buffer, id, "/state"), "");
                defer a.free(response);
                if (std.mem.indexOf(u8, response, "\"state\":\"running\"") != null and
                    std.mem.indexOf(u8, response, "\"generating\":true") != null) break;
            }
            if (cc.util_time.nowMs() >= deadline) return error.BackgroundJobNeverRan;
            cc.util_time.sleepMs(20);
        }
    }
    cc.util_time.sleepMs(300); // both shells are spawned

    // A lease keeps the closed session readable after the destroy.
    const held = fx.md.resolve(id.asSlice()) orelse return error.NotResolvable;
    defer held.release();
    const started = cc.util_time.nowMs();
    {
        const response = try fx.call("POST", Fixture.lifecyclePath(&path_buffer, id, "destroy"), "");
        defer a.free(response);
        const took = elapsedSince(started);
        if (took >= 5000) {
            std.debug.print("destroy took {d} ms\n", .{took});
            return error.DestroyNotBounded;
        }
        try expectStatus(response, "200");
    }

    // By the time destroy answered, the job had been stopped and joined.
    const snapshot = try held.view.state_fn(held.view.state_ctx, a);
    defer a.free(snapshot);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, snapshot, .{});
    defer parsed.deinit();
    const agents = parsed.value.object.get("agents").?.array.items;
    try std.testing.expect(agents.len >= 1);
    for (agents) |agent| {
        const state = agent.object.get("state").?.string;
        if (std.mem.eql(u8, state, "running")) {
            std.debug.print("after destroy: {s}\n", .{snapshot});
            return error.BackgroundJobStillRunning;
        }
    }
}

test "#254 a destroyed session keeps its id until it is reaped: 409 while closing, 201 after" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.setup(.{});
    defer fx.deinit();

    const wanted = "0123456789abcdef0123abcd";
    const id = try fx.create("{\"session_id\":\"" ++ wanted ++ "\"}");
    // A request still using the session keeps it from being reaped.
    const held = fx.md.resolve(wanted) orelse return error.NotResolvable;
    var held_out = true;
    defer if (held_out) held.release();
    var path_buffer: [96]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 200), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "destroy"), ""));
    try std.testing.expectEqual(@as(u16, 404), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "resume"), ""));

    // Its App still owns the session directory: neither a fresh create nor a
    // restore may build a second App on it yet.
    for ([_][]const u8{ "{\"session_id\":\"" ++ wanted ++ "\"}", "{\"session_id\":\"" ++ wanted ++ "\",\"resume\":true}" }) |body| {
        const response = try fx.call("POST", "/sessions/create", body);
        defer a.free(response);
        try expectStatus(response, "409");
        try std.testing.expectEqualStrings("{\"error\":\"session is still closing\"}", bodyOf(response));
    }
    fx.md.reap();
    try std.testing.expectEqual(@as(u16, 409), try fx.status("POST", "/sessions/create", "{\"session_id\":\"" ++ wanted ++ "\"}"));
    // A different id is not affected.
    _ = try fx.create("");

    held.release();
    held_out = false;
    fx.md.reap();
    try std.testing.expectEqual(@as(usize, 1), fx.md.stats().reaped);
    const again = try fx.create("{\"session_id\":\"" ++ wanted ++ "\"}");
    try std.testing.expectEqualStrings(wanted, again.asSlice());
}

test "#254 the destroy's provider cancel is serialized with a route switch (App.route_mutex)" {
    var fx: Fixture = undefined;
    try fx.setup(.{});
    defer fx.deinit();
    const id = try fx.create("");
    const held = fx.md.resolve(id.asSlice()) orelse return error.NotResolvable;
    defer held.release();
    const state: *cc.web_session.StateSource = @ptrCast(@alignCast(held.view.state_ctx));
    const app = state.app;

    const Canceller = struct {
        returned: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This(), target: *cc.app_module.App) void {
            // What app_driver.abortFn does from a destroy thread (nothing is in
            // flight here, so it shuts nothing down).
            target.cancelInFlightRequest(&target.abort);
            self.returned.store(true, .release);
        }
    };
    var canceller: Canceller = .{};
    // A route switch holds the lock while it builds a client and moves the kind.
    app.route_mutex.lock();
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{ &canceller, app });
    cc.util_time.sleepMs(200);
    const returned_during_switch = canceller.returned.load(.acquire);
    app.route_mutex.unlock();
    thread.join();
    try std.testing.expect(!returned_during_switch);
    try std.testing.expect(canceller.returned.load(.acquire));
}

// ── create ──────────────────────────────────────────────────────────────────

test "#254 create: caller id, 409 live duplicate, 400 malformed, 429 at the cap (live sessions only), 404 unknown routes" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.setup(.{ .max_sessions = 2 });
    defer fx.deinit();

    const wanted = "0123456789abcdef01234567";
    const id = try fx.create("{\"session_id\":\"" ++ wanted ++ "\"}");
    try std.testing.expectEqualStrings(wanted, id.asSlice());
    try std.testing.expectEqual(@as(u16, 409), try fx.status("POST", "/sessions/create", "{\"session_id\":\"" ++ wanted ++ "\"}"));

    // Malformed requests are refused before anything is built.
    const bad_bodies = [_][]const u8{
        "{\"session_id\":\"too-short\"}",
        "{\"session_id\":\"0123456789ABCDEF01234567\"}", // upper case
        "{\"session_id\":\"../../../../../../../etc\"}",
        "{\"session_id\":42}",
        "{\"resume\":true}", // resume needs an id
        "{\"resume\":\"yes\",\"session_id\":\"" ++ wanted ++ "\"}",
        "not json",
        "[1,2]",
    };
    for (bad_bodies) |body| {
        const code = try fx.status("POST", "/sessions/create", body);
        if (code != 400) {
            std.debug.print("body {s} → {d}\n", .{ body, code });
            return error.ExpectedBadRequest;
        }
    }
    try fx.expectHealth(1);

    // The cap: 2 live sessions.
    const second = try fx.create("{}");
    {
        const response = try fx.call("POST", "/sessions/create", "");
        defer a.free(response);
        try expectStatus(response, "429");
        try std.testing.expectEqualStrings("{\"error\":\"session limit reached\",\"max_sessions\":2}", bodyOf(response));
    }
    // A destroyed session no longer counts.
    var path_buffer: [96]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 200), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, second, "destroy"), ""));
    _ = try fx.create("");
    try fx.expectHealth(2);

    // Anything else under /sessions, and a wrong method, is 404.
    try std.testing.expectEqual(@as(u16, 404), try fx.status("GET", "/sessions/create", ""));
    try std.testing.expectEqual(@as(u16, 404), try fx.status("POST", "/sessions", ""));
    try std.testing.expectEqual(@as(u16, 404), try fx.status("POST", "/sessions/" ++ wanted ++ "/reboot", ""));
    try std.testing.expectEqual(@as(u16, 404), try fx.status("GET", "/sessions/" ++ wanted ++ "/destroy", ""));
    try std.testing.expectEqual(@as(u16, 404), try fx.status("POST", "/sessions/not-an-id/destroy", ""));
    try fx.expectHealth(2);
}

test "#254 --sessions 0 starts empty and accepts a create; startup sessions are ordinary sessions" {
    const a = std.testing.allocator;
    {
        var fx: Fixture = undefined;
        try fx.setup(.{ .initial = 0 });
        defer fx.deinit();
        try fx.expectHealth(0);
        const listed = try fx.call("GET", "/sessions", "");
        defer a.free(listed);
        try std.testing.expectEqualStrings("{\"sessions\":[]}", bodyOf(listed));
        const page = try fx.call("GET", "/", "");
        defer a.free(page);
        try std.testing.expect(std.mem.indexOf(u8, page, "POST /sessions/create") != null);

        const id = try fx.create("");
        try fx.expectHealth(1);
        const sse = try Stream.openSse(&fx, id);
        defer sse.destroy();
        try fx.message(id, "first");
        try sse.waitFor("hello from the provider");
    }
    {
        var fx: Fixture = undefined;
        try fx.setup(.{ .initial = 2, .max_sessions = 2 });
        defer fx.deinit();
        try fx.expectHealth(2);
        const listed = try fx.call("GET", "/sessions", "");
        defer a.free(listed);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, bodyOf(listed), .{});
        defer parsed.deinit();
        const sessions = parsed.value.object.get("sessions").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), sessions.len);
        // A startup session is destroyed like any other, and frees its place under the cap.
        const first = SessionId.fromSlice(sessions[0].object.get("session_id").?.string).?;
        try std.testing.expectEqual(@as(u16, 429), try fx.status("POST", "/sessions/create", ""));
        var path_buffer: [96]u8 = undefined;
        try std.testing.expectEqual(@as(u16, 200), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, first, "destroy"), ""));
        _ = try fx.create("");
    }
}

// ── resume ──────────────────────────────────────────────────────────────────

test "#254 create {resume:true} restores the persisted conversation; /sessions/<id>/resume is 200 live, 404 otherwise" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.setup(.{ .responses = &.{ textSse("first answer"), textSse("second answer") } });
    defer fx.deinit();

    const wanted = "00000000000000aa00000001";
    // Nothing persisted yet: a restore has nothing to load.
    try std.testing.expectEqual(@as(u16, 404), try fx.status("POST", "/sessions/create", "{\"session_id\":\"" ++ wanted ++ "\",\"resume\":true}"));
    try fx.expectHealth(0);

    const id = try fx.create("{\"session_id\":\"" ++ wanted ++ "\"}");
    var path_buffer: [96]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 200), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "resume"), ""));
    {
        const sse = try Stream.openSse(&fx, id);
        defer sse.destroy();
        try fx.message(id, "remember the word PELICAN");
        try sse.waitFor("\"run_done\"");
    }
    try std.testing.expectEqual(@as(u16, 200), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "destroy"), ""));
    try std.testing.expectEqual(@as(u16, 404), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "resume"), ""));
    // The id comes back once the closed session is reaped (the daemon's main loop does this).
    try fx.settle(id);

    // A fresh create would overwrite the persisted conversation: refused.
    {
        const response = try fx.call("POST", "/sessions/create", "{\"session_id\":\"" ++ wanted ++ "\"}");
        defer a.free(response);
        try expectStatus(response, "409");
        try std.testing.expect(std.mem.indexOf(u8, response, "a transcript is persisted") != null);
    }

    // Restore: the two persisted messages come back.
    {
        const response = try fx.call("POST", "/sessions/create", "{\"session_id\":\"" ++ wanted ++ "\",\"resume\":true}");
        defer a.free(response);
        try expectStatus(response, "201");
        try std.testing.expectEqualStrings("{\"session_id\":\"" ++ wanted ++ "\",\"messages\":2}", bodyOf(response));
    }
    try std.testing.expectEqual(@as(u16, 200), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "resume"), ""));
    // Live again: a second restore is a live duplicate.
    try std.testing.expectEqual(@as(u16, 409), try fx.status("POST", "/sessions/create", "{\"session_id\":\"" ++ wanted ++ "\",\"resume\":true}"));
    {
        const sse = try Stream.openSse(&fx, id);
        defer sse.destroy();
        try fx.message(id, "which word was it?");
        try sse.waitFor("second answer");
        try sse.waitFor("\"run_done\"");
    }

    // The provider saw the earlier turn: the restored conversation is the context.
    try std.testing.expectEqual(@as(usize, 2), fx.provider.requestCount());
    const second = fx.provider.requestAt(1).?;
    const body = second.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "remember the word PELICAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "first answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "which word was it?") != null);
    try std.testing.expect(std.mem.indexOf(u8, fx.provider.requestAt(0).?.body(), "first answer") == null);

    // The transcript continues: four records, none written twice.
    const cwd = try cc.util_fs.getCwd(a);
    defer a.free(cwd);
    const dir = try cc.transcript.sessionDir(a, .{ .path = fx.state_root }, cwd, id);
    defer a.free(dir);
    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buffer, "{s}/transcript.jsonl", .{dir});
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file, a, .limited(1 << 20));
    defer a.free(content);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, content, "\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "remember the word PELICAN"));
}

// ── access ──────────────────────────────────────────────────────────────────

test "#254 with a token the /sessions routes need it; a refused create builds nothing" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.setup(.{ .token = TOKEN });
    defer fx.deinit();

    const routes = [_]struct { method: []const u8, path: []const u8 }{
        .{ .method = "GET", .path = "/sessions" },
        .{ .method = "POST", .path = "/sessions/create" },
        .{ .method = "POST", .path = "/sessions/0123456789abcdef01234567/resume" },
        .{ .method = "POST", .path = "/sessions/0123456789abcdef01234567/destroy" },
    };
    for (routes) |route| {
        const response = try fx.callAs(null, route.method, route.path, "");
        defer a.free(response);
        try expectStatus(response, "401");
        const wrong = try fx.callAs("not-the-token", route.method, route.path, "");
        defer a.free(wrong);
        try expectStatus(wrong, "401");
    }
    try fx.expectHealth(0);

    // With it: the same routes work.
    const id = try fx.create("");
    try fx.expectHealth(1);
    var path_buffer: [96]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 200), try fx.status("GET", "/sessions", ""));
    try std.testing.expectEqual(@as(u16, 200), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "resume"), ""));
    try std.testing.expectEqual(@as(u16, 200), try fx.status("POST", Fixture.lifecyclePath(&path_buffer, id, "destroy"), ""));
}

test "#254 without the multi-session daemon the /sessions routes are 404 (--web, single-session serve)" {
    const a = std.testing.allocator;
    var journal = cc.event_journal.EventJournal.init(a);
    defer journal.deinit();
    var wb = cc.web_backend.WebBackend.init(a, &journal);
    defer wb.deinit();
    var inbox = cc.web_submission.SubmissionQueue.init(a);
    defer inbox.deinit();
    var abort = cc.util_abort.AbortSignal.init();
    const State = struct {
        fn snapshot(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{}");
        }
    };
    var dummy: u8 = 0;
    const srv = try cc.web_server.WebServer.start(a, .{ .version = VERSION }, .{
        .journal = &journal,
        .web_backend = &wb,
        .inbox = &inbox,
        .abort = &abort,
        .state_ctx = @ptrCast(&dummy),
        .state_fn = &State.snapshot,
    });
    defer srv.stop();
    defer journal.close();

    for ([_][]const u8{
        "GET /sessions HTTP/1.1\r\n\r\n",
        "POST /sessions/create HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        "POST /sessions/0123456789abcdef01234567/destroy HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
    }) |raw| {
        const response = try harness.clientRoundtrip(a, srv.port, raw, null);
        defer a.free(response);
        try expectStatus(response, "404");
    }
    // Positive control: the same server answers its own routes.
    const state = try harness.clientRoundtrip(a, srv.port, "GET /state HTTP/1.1\r\n\r\n", null);
    defer a.free(state);
    try expectStatus(state, "200");
}

// ── flags ───────────────────────────────────────────────────────────────────

test "#254 flags: --sessions N ≥ 0 and --max-sessions M ≥ 1 for serve only; N ≤ M; --max-sessions needs the multi-session daemon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Case = struct { argv: []const [*:0]const u8, ok: bool };
    const cases = [_]Case{
        .{ .argv = &.{ "metacodes", "serve", "--sessions", "0" }, .ok = true },
        .{ .argv = &.{ "metacodes", "serve", "--sessions", "2", "--max-sessions", "4" }, .ok = true },
        .{ .argv = &.{ "metacodes", "serve", "--sessions", "4", "--max-sessions", "4" }, .ok = true },
        .{ .argv = &.{ "metacodes", "serve", "--uds", "/tmp/x.sock", "--max-sessions", "3" }, .ok = true },
        .{ .argv = &.{ "metacodes", "serve", "--sessions", "-1" }, .ok = false },
        .{ .argv = &.{ "metacodes", "serve", "--sessions", "two" }, .ok = false },
        .{ .argv = &.{ "metacodes", "serve", "--sessions" }, .ok = false },
        .{ .argv = &.{ "metacodes", "serve", "--sessions", "5", "--max-sessions", "4" }, .ok = false },
        .{ .argv = &.{ "metacodes", "serve", "--sessions", "33" }, .ok = false }, // over the default cap
        .{ .argv = &.{ "metacodes", "serve", "--sessions", "1", "--max-sessions", "0" }, .ok = false },
        .{ .argv = &.{ "metacodes", "serve", "--max-sessions", "4" }, .ok = false }, // single-session serve has no cap
        .{ .argv = &.{ "metacodes", "--sessions", "2" }, .ok = false }, // not serving
        .{ .argv = &.{ "metacodes", "--web", "--max-sessions", "2" }, .ok = false },
        .{ .argv = &.{ "metacodes", "--uds", "/tmp/x.sock" }, .ok = false },
    };
    for (cases) |case| {
        const config = cc.parseArgsForTest(case.argv, allocator);
        if ((config.parse_error == null) != case.ok) {
            for (case.argv) |arg| std.debug.print("{s} ", .{arg});
            std.debug.print("→ {?s}\n", .{config.parse_error});
            return error.UnexpectedParse;
        }
    }
    const zero = cc.parseArgsForTest(&.{ "metacodes", "serve", "--sessions", "0", "--max-sessions", "3" }, allocator);
    try std.testing.expectEqual(@as(?usize, 0), zero.serve_sessions);
    try std.testing.expectEqual(@as(?usize, 3), zero.serve_max_sessions);
    const plain = cc.parseArgsForTest(&.{ "metacodes", "serve" }, allocator);
    try std.testing.expectEqual(@as(?usize, null), plain.serve_sessions);
}

const swarm_team = cc.swarm_team;
const swarm_mailbox = cc.swarm_mailbox;

const AddMemberCtx = struct { name: []const u8, agent_id: []const u8, session: []const u8, lease: []const u8 };
fn addMember(c: AddMemberCtx, tf: *swarm_team.TeamFile) anyerror!void {
    // addMember copies the strings.
    try tf.addMember(.{
        .agent_id = c.agent_id,
        .name = c.name,
        .session_id = c.session,
        .lease_id = c.lease,
        .backend_type = "process",
    });
}

test "#277 an idle daemon lead takes a teammate's reply as its next turn, without a new message" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.setup(.{
        .agent_teams = true,
        .responses = &.{
            toolUseSse("tu_team", "TeamCreate", "{\\\"name\\\":\\\"crew\\\"}"),
            textSse("team ready"),
            textSse("thanks solver"),
        },
    });
    defer fx.deinit();

    const id = try fx.create("");
    const sse = try Stream.openSse(&fx, id);
    defer sse.destroy();
    try fx.message(id, "form a team");
    try sse.waitFor("team ready");
    try sse.waitFor("\"run_done\"");
    try std.testing.expectEqual(@as(usize, 2), fx.provider.requestCount());

    // A teammate of this lead session answers into the lead's inbox (what
    // its SendMessage does), with the identity the roster records.
    var config_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = swarm_team.configPath(fx.state_root, "crew", &config_buffer);
    const lease = cc.session_id.gen();
    try swarm_team.updateTeam(a, config_path, AddMemberCtx{
        .name = "solver",
        .agent_id = "solver@crew",
        .session = id.asSlice(),
        .lease = lease.asSlice(),
    }, addMember);
    var inbox_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const inbox = swarm_team.inboxPath(fx.state_root, "crew", swarm_team.TEAM_LEAD_NAME, &inbox_buffer);
    try swarm_mailbox.deliverWithIdentity(a, inbox, "solver", "the answer is 42", null, "done", id.asSlice(), lease.asSlice());

    // No message from the client: the idle driver delivers the mail itself.
    try sse.waitFor("thanks solver");
    const deadline = cc.util_time.nowMs() + 5000;
    while (fx.provider.requestCount() < 3) {
        if (cc.util_time.nowMs() >= deadline) return error.NoTurnForTheMail;
        cc.util_time.sleepMs(20);
    }
    const third = (fx.provider.requestAt(2) orelse return error.MissingRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, third, "teammate_id=\\\"solver\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, third, "the answer is 42") != null);
    // Read once: the next idle poll finds nothing, so no fourth request.
    cc.util_time.sleepMs(3 * swarm_lead_poll_ms);
    try std.testing.expectEqual(@as(usize, 3), fx.provider.requestCount());
}

const swarm_lead_poll_ms: u64 = @intCast(cc.session_service.LeadMail.POLL_MS);
