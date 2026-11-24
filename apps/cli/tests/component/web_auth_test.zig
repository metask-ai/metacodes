//! L2: the HTTP surface of `--web` / `serve` / `serve --sessions` (#251-#253),
//! driven over real sockets.
//!
//!   #251 `GET /health`: answers with the version the host passed in and the
//!        session count, needs no token, and never calls the resolver or the
//!        state snapshot.
//!   #252 bearer token: every other route needs `Authorization: Bearer`; a GET
//!        may use `?token=`, a POST may not. A refused request has no side
//!        effect, and is refused from its head alone (no body is awaited).
//!   DNS rebinding: without a token only loopback Host names pass.
//!   #253 bind: an IPv6 literal binds and serves; the flag/environment
//!        resolution and the non-loopback refusal main applies before startup.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pnet = @import("platform").net;

const EventJournal = cc.event_journal.EventJournal;
const WebBackend = cc.web_backend.WebBackend;
const WebServer = cc.web_server.WebServer;
const SubmissionQueue = cc.web_submission.SubmissionQueue;
const Surface = cc.web_server.Surface;

const TOKEN = "t0k3n-for+tests/~";
/// TOKEN as `encodeURIComponent` sends it.
const TOKEN_QUERY = "t0k3n-for%2Btests%2F~";
const VERSION = "9.8.7-dev+0123456789ab";

/// Counts every call into the session snapshot and the resolver: `/health`
/// must reach neither.
const Probe = struct {
    state_calls: std.atomic.Value(usize) = .init(0),
    resolve_calls: std.atomic.Value(usize) = .init(0),
    release_calls: std.atomic.Value(usize) = .init(0),
    sessions: std.atomic.Value(usize) = .init(0),
    view: ?cc.web_server.SessionView = null,

    fn state(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        _ = self.state_calls.fetchAdd(1, .acq_rel);
        return allocator.dupe(u8, "{\"model\":\"probe\"}");
    }

    fn resolve(ctx: *anyopaque, id: []const u8) ?cc.web_server.Lease {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        _ = self.resolve_calls.fetchAdd(1, .acq_rel);
        if (!std.mem.eql(u8, id, "s1")) return null;
        return .{ .view = self.view.?, .ctx = ctx, .release_fn = &release };
    }

    /// Every lease a request took comes back (#254).
    fn release(ctx: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        _ = self.release_calls.fetchAdd(1, .acq_rel);
    }
};

const Fixture = struct {
    journal: EventJournal,
    wb: WebBackend = undefined,
    inbox: SubmissionQueue,
    sig: cc.util_abort.AbortSignal,
    probe: Probe = .{},
    srv: *WebServer = undefined,

    fn init(a: std.mem.Allocator) Fixture {
        return .{
            .journal = EventJournal.init(a),
            .inbox = SubmissionQueue.init(a),
            .sig = cc.util_abort.AbortSignal.init(),
        };
    }

    /// `sessions`: null = single-session host; else a resolver host reporting it.
    fn start(self: *Fixture, a: std.mem.Allocator, surface: Surface, sessions: ?usize) !void {
        self.wb = WebBackend.init(a, &self.journal);
        self.wb.abort = &self.sig;
        self.probe.view = .{
            .journal = &self.journal,
            .web_backend = &self.wb,
            .inbox = &self.inbox,
            .abort = &self.sig,
            .state_ctx = @ptrCast(&self.probe),
            .state_fn = &Probe.state,
        };
        var deps: cc.web_server.Deps = .{
            .journal = &self.journal,
            .web_backend = &self.wb,
            .inbox = &self.inbox,
            .abort = &self.sig,
            .state_ctx = @ptrCast(&self.probe),
            .state_fn = &Probe.state,
        };
        if (sessions) |n| {
            self.probe.sessions.store(n, .release);
            deps.resolver = .{ .resolve = &Probe.resolve, .ctx = @ptrCast(&self.probe), .sessions = &self.probe.sessions };
        }
        self.srv = try WebServer.start(a, surface, deps);
    }

    fn deinit(self: *Fixture) void {
        self.journal.close();
        self.srv.stop();
        self.wb.deinit();
        self.inbox.deinit();
        self.journal.deinit();
    }

    fn inboxEmpty(self: *Fixture) bool {
        if (self.inbox.popFront()) |popped| {
            var m = popped;
            m.deinit(self.inbox.allocator);
            return false;
        }
        return true;
    }
};

fn request(a: std.mem.Allocator, port: u16, raw: []const u8) ![]u8 {
    return harness.clientRoundtrip(a, port, raw, null);
}

fn statusIs(response: []const u8, status: []const u8) bool {
    const line_end = std.mem.indexOf(u8, response, "\r\n") orelse return false;
    return std.mem.indexOf(u8, response[0..line_end], status) != null;
}

fn bodyOf(response: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[at + 4 ..];
}

fn expectHealth(a: std.mem.Allocator, response: []const u8, sessions: i64) !void {
    try std.testing.expect(statusIs(response, "200"));
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bodyOf(response), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("ok", object.get("status").?.string);
    try std.testing.expectEqualStrings(VERSION, object.get("version").?.string);
    try std.testing.expectEqual(sessions, object.get("sessions").?.integer);
}

test "#251 GET /health (single session): version as passed, 1 session, no snapshot taken" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION }, null);

    const response = try request(a, fx.srv.port, "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    defer a.free(response);
    try expectHealth(a, response, 1);
    try std.testing.expect(std.mem.indexOf(u8, response, "Cache-Control: no-store") != null);
    try std.testing.expectEqual(@as(usize, 0), fx.probe.state_calls.load(.acquire));

    // Positive control: the snapshot counter does move when /state is asked.
    const state = try request(a, fx.srv.port, "GET /state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    defer a.free(state);
    try std.testing.expect(statusIs(state, "200"));
    try std.testing.expectEqual(@as(usize, 1), fx.probe.state_calls.load(.acquire));
}

test "#251 GET /health (resolver host): the session count, without calling the resolver" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION }, 3);

    const response = try request(a, fx.srv.port, "GET /health HTTP/1.1\r\n\r\n");
    defer a.free(response);
    try expectHealth(a, response, 3);
    try std.testing.expectEqual(@as(usize, 0), fx.probe.resolve_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), fx.probe.state_calls.load(.acquire));

    // The count is read live, not frozen at start.
    fx.probe.sessions.store(5, .release);
    const later = try request(a, fx.srv.port, "GET /health HTTP/1.1\r\n\r\n");
    defer a.free(later);
    try expectHealth(a, later, 5);

    // Positive control: a session route does go through the resolver, and
    // gives its lease back once the response is out.
    const state = try request(a, fx.srv.port, "GET /s/s1/state HTTP/1.1\r\n\r\n");
    defer a.free(state);
    try std.testing.expect(statusIs(state, "200"));
    try std.testing.expectEqual(@as(usize, 1), fx.probe.resolve_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fx.probe.release_calls.load(.acquire));
}

test "#251/#252 GET /health needs no token and no loopback Host while auth is on" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION, .token = TOKEN }, null);

    for ([_][]const u8{
        "GET /health HTTP/1.1\r\n\r\n",
        "GET /health HTTP/1.1\r\nHost: pod-7.cluster.internal:8080\r\n\r\n",
        "GET /health HTTP/1.1\r\nAuthorization: Bearer wrong\r\n\r\n",
    }) |raw| {
        const response = try request(a, fx.srv.port, raw);
        defer a.free(response);
        try expectHealth(a, response, 1);
    }
}

test "#252 token: missing or wrong → 401 and no side effect; the right header → 200" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION, .token = TOKEN }, null);
    const port = fx.srv.port;

    const refused = [_][]const u8{
        "POST /message HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 14\r\n\r\n{\"text\":\"pwn\"}",
        "POST /message HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer wrong-token\r\nContent-Length: 14\r\n\r\n{\"text\":\"pwn\"}",
        "POST /message HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Basic " ++ TOKEN ++ "\r\nContent-Length: 14\r\n\r\n{\"text\":\"pwn\"}",
        // A POST is never authenticated by query, even with the right token there.
        "POST /message?token=" ++ TOKEN_QUERY ++ " HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 14\r\n\r\n{\"text\":\"pwn\"}",
        "POST /interrupt?token=" ++ TOKEN_QUERY ++ " HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
    };
    for (refused) |raw| {
        const response = try request(a, port, raw);
        defer a.free(response);
        try std.testing.expect(statusIs(response, "401"));
        try std.testing.expect(std.mem.indexOf(u8, response, "WWW-Authenticate: Bearer\r\n") != null);
        try std.testing.expectEqualStrings("{\"error\":\"unauthorized\"}", bodyOf(response));
        // The token is never reflected back.
        try std.testing.expect(std.mem.indexOf(u8, response, TOKEN) == null);
    }
    try std.testing.expect(fx.inboxEmpty());
    try std.testing.expect(!fx.sig.isAborted());

    for ([_][]const u8{ "GET /state HTTP/1.1\r\n\r\n", "GET / HTTP/1.1\r\n\r\n", "GET /state?token=nope HTTP/1.1\r\n\r\n" }) |raw| {
        const response = try request(a, port, raw);
        defer a.free(response);
        try std.testing.expect(statusIs(response, "401"));
    }
    try std.testing.expectEqual(@as(usize, 0), fx.probe.state_calls.load(.acquire));

    const accepted = try request(a, port, "POST /message HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer " ++ TOKEN ++ "\r\nContent-Length: 13\r\n\r\n{\"text\":\"ok\"}");
    defer a.free(accepted);
    try std.testing.expect(statusIs(accepted, "200"));
    var queued = fx.inbox.popFront().?;
    defer queued.deinit(a);
    try std.testing.expectEqualStrings("ok", queued.text);

    // GETs: the header, or the query (the SPA's page load and EventSource).
    for ([_][]const u8{
        "GET /state HTTP/1.1\r\nAuthorization: Bearer " ++ TOKEN ++ "\r\n\r\n",
        "GET /state?token=" ++ TOKEN_QUERY ++ " HTTP/1.1\r\n\r\n",
        "GET /?token=" ++ TOKEN_QUERY ++ " HTTP/1.1\r\n\r\n",
    }) |raw| {
        const response = try request(a, port, raw);
        defer a.free(response);
        try std.testing.expect(statusIs(response, "200"));
    }
    try std.testing.expectEqual(@as(usize, 2), fx.probe.state_calls.load(.acquire));
}

test "#252 token: GET /events streams with ?token=, and refuses without it" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION, .token = TOKEN }, null);
    const be = fx.wb.backend();
    be.emitEvent(cc.session_id.SessionId.single, .{ .text_chunk = "streamed to the token holder" });

    const refused = try request(a, fx.srv.port, "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    defer a.free(refused);
    try std.testing.expect(statusIs(refused, "401"));
    try std.testing.expect(std.mem.indexOf(u8, refused, "streamed to the token holder") == null);

    const streamed = try harness.clientRoundtrip(a, fx.srv.port, "GET /events?since=0&token=" ++ TOKEN_QUERY ++ " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "streamed to the token holder");
    defer a.free(streamed);
    try std.testing.expect(statusIs(streamed, "200"));
    try std.testing.expect(std.mem.indexOf(u8, streamed, "text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, streamed, "streamed to the token holder") != null);
}

test "#252 token: a valid token does not excuse a cross-origin POST" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION, .token = TOKEN }, null);

    const response = try request(a, fx.srv.port, "POST /message HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://evil.com\r\nAuthorization: Bearer " ++ TOKEN ++ "\r\nContent-Length: 14\r\n\r\n{\"text\":\"pwn\"}");
    defer a.free(response);
    try std.testing.expect(statusIs(response, "403"));
    try std.testing.expect(std.mem.indexOf(u8, response, "cross-origin") != null);
    try std.testing.expect(fx.inboxEmpty());

    // Same origin through a TLS-terminating gateway: Origin is https://<Host>.
    const gateway = try request(a, fx.srv.port, "POST /message HTTP/1.1\r\nHost: agent.example.com\r\nOrigin: https://agent.example.com\r\nAuthorization: Bearer " ++ TOKEN ++ "\r\nContent-Length: 13\r\n\r\n{\"text\":\"gw\"}");
    defer a.free(gateway);
    try std.testing.expect(statusIs(gateway, "200"));
    try std.testing.expect(!fx.inboxEmpty());
}

test "#252 token: refused from the head alone, without waiting for the declared body" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION, .token = TOKEN }, null);

    // 512 KiB declared, none sent, connection kept open. A server that read the
    // body before authenticating would sit in recv until its 10 s socket
    // timeout; clientRoundtrip gives up after 5 s and would see no response.
    const sock = try pnet.connectLoopback(fx.srv.port);
    defer pnet.closeSocket(sock);
    pnet.setRecvTimeoutMs(sock, 3000);
    const head = "POST /message HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 524288\r\n\r\n";
    try std.testing.expectEqual(@as(isize, head.len), pnet.send(sock, head));
    var buffer: [512]u8 = undefined;
    const n = pnet.recv(sock, &buffer);
    try std.testing.expect(n > 0);
    try std.testing.expect(statusIs(buffer[0..@intCast(n)], "401"));
}

test "#252 token: a refused POST whose body follows its head still reads a clean 401" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION, .token = TOKEN }, null);

    // The body arrives after the server has answered: it is taken in and
    // dropped, so the connection ends with FIN, not a reset that could
    // swallow the refusal.
    const sock = try pnet.connectLoopback(fx.srv.port);
    defer pnet.closeSocket(sock);
    pnet.setRecvTimeoutMs(sock, 3000);
    const head = "POST /message HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 14\r\n\r\n";
    try std.testing.expectEqual(@as(isize, head.len), pnet.send(sock, head));
    cc.util_time.sleepMs(50);
    try std.testing.expectEqual(@as(isize, 14), pnet.send(sock, "{\"text\":\"pwn\"}"));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var chunk: [512]u8 = undefined;
    while (true) {
        const n = pnet.recv(sock, &chunk);
        if (n < 0) return error.ConnectionReset;
        if (n == 0) break;
        try out.appendSlice(a, chunk[0..@intCast(n)]);
    }
    try std.testing.expect(statusIs(out.items, "401"));
    try std.testing.expect(fx.inboxEmpty());
}

test "#252 no token configured: today's behaviour (no header needed, a query token is ignored)" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION }, null);

    const response = try request(a, fx.srv.port, "POST /message HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 15\r\n\r\n{\"text\":\"open\"}");
    defer a.free(response);
    try std.testing.expect(statusIs(response, "200"));
    var queued = fx.inbox.popFront().?;
    defer queued.deinit(a);
    try std.testing.expectEqualStrings("open", queued.text);

    const state = try request(a, fx.srv.port, "GET /state?token=whatever HTTP/1.1\r\nAuthorization: Bearer whatever\r\n\r\n");
    defer a.free(state);
    try std.testing.expect(statusIs(state, "200"));
}

test "DNS rebinding: without a token a non-loopback Host is refused, loopback names pass" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .version = VERSION }, null);
    const port = fx.srv.port;

    var buffer: [256]u8 = undefined;
    const rebound = [_][]const u8{ "attacker.example", "localhost.attacker.example", "10.0.0.5" };
    for (rebound) |name| {
        const get = try std.fmt.bufPrint(&buffer, "GET /state HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ name, port });
        const response = try request(a, port, get);
        defer a.free(response);
        try std.testing.expect(statusIs(response, "403"));
        try std.testing.expect(std.mem.indexOf(u8, response, "host not allowed") != null);
        // A rebound page posting with its own (same-origin) Origin: still refused.
        const post = try std.fmt.bufPrint(&buffer, "POST /message HTTP/1.1\r\nHost: {s}:{d}\r\nOrigin: http://{s}:{d}\r\nContent-Length: 14\r\n\r\n{{\"text\":\"pwn\"}}", .{ name, port, name, port });
        const posted = try request(a, port, post);
        defer a.free(posted);
        try std.testing.expect(statusIs(posted, "403"));
    }
    try std.testing.expectEqual(@as(usize, 0), fx.probe.state_calls.load(.acquire));
    try std.testing.expect(fx.inboxEmpty());

    // Right name, wrong port: not this server's origin.
    const wrong_port = try std.fmt.bufPrint(&buffer, "GET /state HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n\r\n", .{port +% 1});
    const wrong = try request(a, port, wrong_port);
    defer a.free(wrong);
    try std.testing.expect(statusIs(wrong, "403"));

    for ([_][]const u8{ "127.0.0.1", "localhost", "[::1]" }) |name| {
        const get = try std.fmt.bufPrint(&buffer, "GET /state HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ name, port });
        const response = try request(a, port, get);
        defer a.free(response);
        try std.testing.expect(statusIs(response, "200"));
        const post = try std.fmt.bufPrint(&buffer, "POST /message HTTP/1.1\r\nHost: {s}:{d}\r\nOrigin: http://{s}:{d}\r\nContent-Length: 13\r\n\r\n{{\"text\":\"ok\"}}", .{ name, port, name, port });
        const posted = try request(a, port, post);
        defer a.free(posted);
        try std.testing.expect(statusIs(posted, "200"));
        try std.testing.expect(!fx.inboxEmpty());
    }

    // With a token the token is the guard: any Host passes.
    var locked = Fixture.init(a);
    defer locked.deinit();
    try locked.start(a, .{ .version = VERSION, .token = TOKEN }, null);
    const proxied = try request(a, locked.srv.port, "GET /state HTTP/1.1\r\nHost: agent.example.com\r\nAuthorization: Bearer " ++ TOKEN ++ "\r\n\r\n");
    defer a.free(proxied);
    try std.testing.expect(statusIs(proxied, "200"));
}

/// Whether this host can listen on [::1], asked of std's own sockets so a
/// defect in the code under test cannot turn into a skip.
fn ipv6LoopbackAvailable() bool {
    var threaded = @import("platform").signal.threadedIo(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address: std.Io.net.IpAddress = .{ .ip6 = .loopback(0) };
    var server = address.listen(io, .{}) catch return false;
    server.deinit(io);
    return true;
}

fn roundtripAt(a: std.mem.Allocator, address: pnet.IpAddress, raw: []const u8) ![]u8 {
    const sock = try pnet.connectAddress(address);
    defer pnet.closeSocket(sock);
    pnet.setRecvTimeoutMs(sock, 5000);
    var sent: usize = 0;
    while (sent < raw.len) {
        const n = pnet.send(sock, raw[sent..]);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pnet.recv(sock, &chunk);
        if (n <= 0) break;
        try out.appendSlice(a, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(a);
}

test "#253 bind: an IPv6 literal binds, reports its real port and serves its own origin" {
    if (!ipv6LoopbackAvailable()) return error.SkipZigTest; // IPv4-only host
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .address = try pnet.parseIpLiteral("::1", 0), .version = VERSION }, null);
    try std.testing.expect(fx.srv.port != 0);

    var url_buffer: [64]u8 = undefined;
    var expected_url: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected_url, "http://[::1]:{d}", .{fx.srv.port}),
        fx.srv.url(&url_buffer),
    );

    const at = try pnet.parseIpLiteral("::1", fx.srv.port);
    const health = try roundtripAt(a, at, "GET /health HTTP/1.1\r\n\r\n");
    defer a.free(health);
    try expectHealth(a, health, 1);

    var buffer: [256]u8 = undefined;
    const post = try std.fmt.bufPrint(&buffer, "POST /message HTTP/1.1\r\nHost: [::1]:{d}\r\nOrigin: http://[::1]:{d}\r\nContent-Length: 13\r\n\r\n{{\"text\":\"v6\"}}", .{ fx.srv.port, fx.srv.port });
    const posted = try roundtripAt(a, at, post);
    defer a.free(posted);
    try std.testing.expect(statusIs(posted, "200"));
    var queued = fx.inbox.popFront().?;
    defer queued.deinit(a);
    try std.testing.expectEqualStrings("v6", queued.text);
}

test "#253 bind: an explicit IPv4 address binds there and the URL names it" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer fx.deinit();
    try fx.start(a, .{ .address = try pnet.parseIpLiteral("127.0.0.1", 0), .version = VERSION }, null);
    var url_buffer: [64]u8 = undefined;
    var expected_url: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected_url, "http://127.0.0.1:{d}", .{fx.srv.port}),
        fx.srv.url(&url_buffer),
    );
    const health = try roundtripAt(a, try pnet.parseIpLiteral("127.0.0.1", fx.srv.port), "GET /health HTTP/1.1\r\n\r\n");
    defer a.free(health);
    try expectHealth(a, health, 1);
}

test "#252 a malformed token never starts a server" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer {
        fx.inbox.deinit();
        fx.journal.deinit();
    }
    try std.testing.expectError(error.EmptyToken, startSurface(&fx, a, .{ .version = VERSION, .token = "" }));
    try std.testing.expectError(error.TokenCharset, startSurface(&fx, a, .{ .version = VERSION, .token = "with space" }));
    try std.testing.expectError(error.TokenCharset, startSurface(&fx, a, .{ .version = VERSION, .token = "line\r\nX-Injected: 1" }));
}

test "#253 WebServer.start itself refuses an unauthenticated non-loopback surface, before any socket" {
    const a = std.testing.allocator;
    var fx = Fixture.init(a);
    defer {
        fx.inbox.deinit();
        fx.journal.deinit();
    }

    // A port nothing listens on any more: reserved on loopback, then released.
    const reserved = try pnet.listenLoopback(0, 1);
    const port = reserved.port;
    pnet.closeSocket(reserved.sock);

    try std.testing.expectError(error.UnauthenticatedNonLoopback, startSurface(&fx, a, .{
        .address = try pnet.parseIpLiteral("0.0.0.0", port),
        .version = VERSION,
    }));
    // A wildcard listener on that port would also take loopback connections.
    switch (pnet.loopbackListenState(port)) {
        .listening => return error.TestUnexpectedResult,
        .not_listening => {},
        .unknown => try std.testing.expectError(error.ConnectFailed, pnet.connectLoopback(port)),
    }
    // `::`, and an address this host does not own (TEST-NET-1): bind would
    // fail on the latter, so this error can only come from the check before it.
    try std.testing.expectError(error.UnauthenticatedNonLoopback, startSurface(&fx, a, .{
        .address = try pnet.parseIpLiteral("::", 0),
        .version = VERSION,
    }));
    try std.testing.expectError(error.UnauthenticatedNonLoopback, startSurface(&fx, a, .{
        .address = try pnet.parseIpLiteral("192.0.2.1", 0),
        .version = VERSION,
    }));
}

/// Start a server for `surface` on the fixture and stop it again at once.
fn startSurface(fx: *Fixture, a: std.mem.Allocator, surface: Surface) !void {
    fx.wb = WebBackend.init(a, &fx.journal);
    defer fx.wb.deinit();
    const srv = try WebServer.start(a, surface, .{
        .journal = &fx.journal,
        .web_backend = &fx.wb,
        .inbox = &fx.inbox,
        .abort = &fx.sig,
        .state_ctx = @ptrCast(&fx.probe),
        .state_fn = &Probe.state,
    });
    srv.stop();
}

// ── flags and environment (main.resolveWebSurface) ─────────────────────────

/// A parsed Config with what the parser allocated: its error message and a
/// `--web-token` copy. A token `resolveWebSurface` takes from the
/// environment stays the caller's and is not freed here.
const Parsed = struct {
    config: cc.types_mod.Config,
    owned_token: ?[]const u8,

    fn deinit(self: *const Parsed, a: std.mem.Allocator) void {
        if (self.config.parse_error) |e| a.free(e);
        if (self.owned_token) |t| a.free(t);
    }
};

fn parse(a: std.mem.Allocator, argv: []const [*:0]const u8) Parsed {
    const config = cc.parseArgsForTest(argv, a);
    return .{ .config = config, .owned_token = config.web_token };
}

test "flags: --web-bind / --web-token / --web-allow-unauth parse into Config" {
    const a = std.testing.allocator;
    {
        const p = parse(a, &.{ "metacodes", "serve", "0", "--web-bind", "::1", "--web-token", TOKEN, "--web-allow-unauth" });
        defer p.deinit(a);
        try std.testing.expect(p.config.parse_error == null);
        try std.testing.expectEqualSlices(u8, &(try pnet.parseIpLiteral("::1", 0)).ip6.bytes, &p.config.web_bind.?.ip6.bytes);
        try std.testing.expectEqualStrings(TOKEN, p.config.web_token.?);
        try std.testing.expect(p.config.web_allow_unauth);
    }
    {
        // The flags may precede the mode.
        const p = parse(a, &.{ "metacodes", "--web-bind", "0.0.0.0", "--web", "8080" });
        defer p.deinit(a);
        try std.testing.expect(p.config.parse_error == null);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &p.config.web_bind.?.ip4.bytes);
        try std.testing.expectEqual(@as(?u16, 8080), p.config.web_port);
    }
    {
        const p = parse(a, &.{ "metacodes", "--web" });
        defer p.deinit(a);
        try std.testing.expect(p.config.web_bind == null);
        try std.testing.expect(p.config.web_token == null);
        try std.testing.expect(!p.config.web_allow_unauth);
    }
}

test "flags: bad values and orphaned web flags fail closed, and never echo a token" {
    const a = std.testing.allocator;
    const Case = struct { argv: []const [*:0]const u8, needle: []const u8 };
    const cases = [_]Case{
        .{ .argv = &.{ "metacodes", "serve", "--web-bind", "localhost" }, .needle = "invalid --web-bind 'localhost'" },
        .{ .argv = &.{ "metacodes", "serve", "--web-bind", "fe80::1%en0" }, .needle = "zone" },
        .{ .argv = &.{ "metacodes", "serve", "--web-bind", "::ffff:10.0.0.1" }, .needle = "IPv4 address itself" },
        .{ .argv = &.{ "metacodes", "serve", "--web-bind" }, .needle = "missing value for --web-bind" },
        .{ .argv = &.{ "metacodes", "serve", "--web-token", "" }, .needle = "invalid --web-token: the token is empty" },
        .{ .argv = &.{ "metacodes", "serve", "--web-token", "secret with space" }, .needle = "invalid --web-token: the token may only contain" },
        .{ .argv = &.{ "metacodes", "serve", "--web-token" }, .needle = "missing value for --web-token" },
        .{ .argv = &.{ "metacodes", "--web-bind", "127.0.0.1" }, .needle = "require --web or serve" },
        .{ .argv = &.{ "metacodes", "--web-token", "abc" }, .needle = "require --web or serve" },
        .{ .argv = &.{ "metacodes", "--web-allow-unauth" }, .needle = "require --web or serve" },
    };
    for (cases) |case| {
        const p = parse(a, case.argv);
        defer p.deinit(a);
        const message = p.config.parse_error orelse {
            std.debug.print("expected a parse error containing: {s}\n", .{case.needle});
            return error.TestExpectedError;
        };
        std.testing.expect(std.mem.indexOf(u8, message, case.needle) != null) catch |err| {
            std.debug.print("message: {s}\nexpected: {s}\n", .{ message, case.needle });
            return err;
        };
        try std.testing.expect(std.mem.indexOf(u8, message, "secret with space") == null);
    }
}

test "environment: METACODES_WEB_BIND / _TOKEN fill in, a flag wins, bad values fail closed" {
    const a = std.testing.allocator;
    const resolve = cc.resolveWebSurface;
    {
        // Environment only.
        var p = parse(a, &.{ "metacodes", "serve", "0" });
        defer p.deinit(a);
        try std.testing.expect(resolve(&p.config, .{ .bind = "::", .token = "env-token" }, a) == null);
        try std.testing.expect(pnet.isUnspecifiedAddress(p.config.web_bind.?));
        try std.testing.expectEqualStrings("env-token", p.config.web_token.?);
    }
    {
        // A flag wins over the environment, for both.
        var p = parse(a, &.{ "metacodes", "--web", "0", "--web-bind", "127.0.0.1", "--web-token", "flag-token" });
        defer p.deinit(a);
        try std.testing.expect(resolve(&p.config, .{ .bind = "0.0.0.0", .token = "env-token" }, a) == null);
        try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &p.config.web_bind.?.ip4.bytes);
        try std.testing.expectEqualStrings("flag-token", p.config.web_token.?);
    }
    {
        // Neither: loopback, no token.
        var p = parse(a, &.{ "metacodes", "serve" });
        defer p.deinit(a);
        try std.testing.expect(resolve(&p.config, .{}, a) == null);
        try std.testing.expect(p.config.web_bind == null);
        try std.testing.expect(p.config.web_token == null);
    }
    {
        // Not serving: the variables configure nothing and cannot fail a TUI start.
        var p = parse(a, &.{"metacodes"});
        defer p.deinit(a);
        try std.testing.expect(resolve(&p.config, .{ .bind = "not an address", .token = "" }, a) == null);
        try std.testing.expect(p.config.web_bind == null);
        try std.testing.expect(p.config.web_token == null);
    }
    const Bad = struct { env: cc.WebEnv, needle: []const u8 };
    for ([_]Bad{
        .{ .env = .{ .bind = "example.com" }, .needle = "invalid METACODES_WEB_BIND 'example.com'" },
        .{ .env = .{ .bind = "" }, .needle = "invalid METACODES_WEB_BIND ''" },
        .{ .env = .{ .token = "" }, .needle = "invalid METACODES_WEB_TOKEN: the token is empty" },
        .{ .env = .{ .token = "two words" }, .needle = "invalid METACODES_WEB_TOKEN: the token may only contain" },
    }) |bad| {
        var p = parse(a, &.{ "metacodes", "serve" });
        defer p.deinit(a);
        const message = resolve(&p.config, bad.env, a) orelse return error.TestExpectedError;
        defer a.free(message);
        std.testing.expect(std.mem.indexOf(u8, message, bad.needle) != null) catch |err| {
            std.debug.print("message: {s}\nexpected: {s}\n", .{ message, bad.needle });
            return err;
        };
        try std.testing.expect(std.mem.indexOf(u8, message, "two words") == null);
    }
}

test "#253 refusal: a non-loopback bind without a token or --web-allow-unauth does not start" {
    const a = std.testing.allocator;
    const resolve = cc.resolveWebSurface;
    for ([_][]const [*:0]const u8{
        &.{ "metacodes", "serve", "--web-bind", "0.0.0.0" },
        &.{ "metacodes", "--web", "--web-bind", "::" },
        &.{ "metacodes", "serve", "--sessions", "2", "--web-bind", "192.168.1.20" },
    }) |argv| {
        var p = parse(a, argv);
        defer p.deinit(a);
        try std.testing.expect(p.config.parse_error == null);
        const message = resolve(&p.config, .{}, a) orelse return error.TestExpectedError;
        defer a.free(message);
        try std.testing.expect(std.mem.indexOf(u8, message, "refusing to serve on") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "METACODES_WEB_TOKEN") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "--web-allow-unauth") != null);
    }
    {
        // The environment's bind is held to the same rule.
        var p = parse(a, &.{ "metacodes", "serve" });
        defer p.deinit(a);
        const message = resolve(&p.config, .{ .bind = "0.0.0.0" }, a) orelse return error.TestExpectedError;
        defer a.free(message);
        try std.testing.expect(std.mem.indexOf(u8, message, "refusing to serve on 0.0.0.0 ") != null);
    }
    {
        var p = parse(a, &.{ "metacodes", "serve", "--web-bind", "::" });
        defer p.deinit(a);
        const message = resolve(&p.config, .{}, a) orelse return error.TestExpectedError;
        defer a.free(message);
        try std.testing.expect(std.mem.indexOf(u8, message, "refusing to serve on [::] ") != null);
    }
    // Either authentication (flag or environment) or the explicit opt-out lets
    // it start; so does any loopback address.
    {
        var p = parse(a, &.{ "metacodes", "serve", "--web-bind", "0.0.0.0", "--web-token", TOKEN });
        defer p.deinit(a);
        try std.testing.expect(resolve(&p.config, .{}, a) == null);
    }
    {
        var p = parse(a, &.{ "metacodes", "serve", "--web-bind", "0.0.0.0" });
        defer p.deinit(a);
        try std.testing.expect(resolve(&p.config, .{ .token = "from-env" }, a) == null);
    }
    {
        var p = parse(a, &.{ "metacodes", "serve", "--web-bind", "::", "--web-allow-unauth" });
        defer p.deinit(a);
        try std.testing.expect(resolve(&p.config, .{}, a) == null);
    }
    {
        var p = parse(a, &.{ "metacodes", "serve", "--web-bind", "::1" });
        defer p.deinit(a);
        try std.testing.expect(resolve(&p.config, .{}, a) == null);
    }
}
