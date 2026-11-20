//! L2 evidence: OpenRouter's sign-in (`ProviderProfile.key_grant`) — a PKCE
//! grant that ends in an API key of the user's own account.
//!
//! - The browser way: the page address carries the challenge (S256), a
//!   loopback callback and a state; the callback is taken only with that
//!   state; the code and the verifier are traded as JSON; the key is stored in
//!   `keys/openrouter.json` with what `/api/v1/key` said about it.
//! - A refusal ends the wait at once, with or without a state (OpenRouter
//!   sends none with one); an expired or refused code says which. Nothing is
//!   stored in any of these.
//! - The other-device way: the page carries no callback and no state; the
//!   code pasted back is traded with the verifier this machine kept.
//! - `METACODES_OPENROUTER_URL` moves every address, the requests included,
//!   and is taken only for https or a loopback host. Every case here points it
//!   at a local mock and checks the page address is on the mock before a code
//!   is delivered: no made-up code ever reaches openrouter.ai.
//! - Logging out removes the key and names the page where its owner deletes
//!   it (only a management key could delete it from here); a new sign-in can
//!   name the key the previous one left.
//! - The stored key answers for OpenRouter only.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const ppaths = @import("platform").paths;
const net = @import("platform").net;

const testing = std.testing;
const oauth_login = cc.api_oauth_login;
const provider_login = cc.api_provider_login;
const openrouter_login = cc.api_openrouter_login;
const key_store = cc.provider_api_key_store;
const Slug = cc.provider_ids.Slug;
const App = cc.app_module.App;

const OPENROUTER = Slug.lit("openrouter");
const KEY = "sk-or-v1-0e6f44a47a05f1dad2ad7e88c4c1d6b7";
const EXCHANGED = "{\"key\":\"" ++ KEY ++ "\",\"user_id\":\"user_2yOPcMpKoQhcd4bVgSMlELRaIah\"}";
const DESCRIBED = "{\"data\":{\"label\":\"sk-or-v1-0e6...1c96\",\"limit\":null,\"limit_remaining\":null,\"expires_at\":null,\"is_free_tier\":false,\"usage\":0}}";
const OPENAI_SSE =
    "data: {\"id\":\"gen-1\",\"provider\":\"DeepInfra\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"gen-1\",\"provider\":\"DeepInfra\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

const cleared_variables = [_][*:0]const u8{
    "OPENROUTER_API_KEY",
    "METACODES_OPENROUTER_URL",
    "DEEPSEEK_API_KEY",
    "METASK_API_KEY",
    "METASK_GATEWAY_URL",
    "METACODES_PROVIDER",
    "METACODES_KEY_CHECK_URL",
    "METACODES_CONFIG_FILE",
    "SSH_CONNECTION",
    "SSH_TTY",
};

/// A scratch state root as HOME, every key variable cleared, no probe, no KG.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [cleared_variables.len + 4]EnvGuard,
    guard_count: usize,

    fn init(self: *Case) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.tmp = testing.tmpDir(.{});
        self.guard_count = 0;
        self.root = self.root_buf[0..try self.tmp.dir.realPath(testing.io, &self.root_buf)];
        for (cleared_variables) |name| try self.setEnv(name, null);
        try self.setEnv("HOME", (try self.arena.allocator().dupeZ(u8, self.root)).ptr);
        try self.setEnv("METACODES_NO_PROBE", "1");
        try self.setEnv("METACODES_KG_AUTOSTART", "0");
    }

    fn setEnv(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        for (self.guards[0..self.guard_count]) |*guard| {
            if (std.mem.orderZ(u8, guard.name, name) == .eq) {
                if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
                return;
            }
        }
        self.guards[self.guard_count] = try EnvGuard.set(self.arena.allocator(), name, value);
        self.guard_count += 1;
    }

    /// Every OpenRouter address on `server` (`METACODES_OPENROUTER_URL`);
    /// returns the origin.
    fn openRouterAt(self: *Case, server: *harness.MockServer) ![]const u8 {
        const url = try server.urlOwned(self.arena.allocator());
        const origin = url[0 .. url.len - "/v1/messages".len];
        try self.setEnv(openrouter_login.ORIGIN_ENV, (try self.arena.allocator().dupeZ(u8, origin)).ptr);
        return origin;
    }

    fn deinit(self: *Case) void {
        var index = self.guard_count;
        while (index > 0) {
            index -= 1;
            self.guards[index].restore();
        }
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn config(self: *Case, argv: []const [*:0]const u8) !cc.types_mod.Config {
        var parsed = cc.parseArgsForTest(argv, self.arena.allocator());
        try testing.expect(parsed.parse_error == null);
        parsed.state_root = self.root;
        return parsed;
    }
};

/// Collects what the flow tells the user, published with release/acquire.
/// The flow says its instructions in one write before it waits on the
/// callback, so once `ready` is seen nothing appends until the test delivers
/// one.
const Instructions = struct {
    buffer: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    ready: std.atomic.Value(bool) = .init(false),

    fn write(raw: *anyopaque, said: []const u8) void {
        const self: *Instructions = @ptrCast(@alignCast(raw));
        self.buffer.appendSlice(self.allocator, said) catch {};
        self.ready.store(true, .release);
    }

    fn wait(self: *Instructions) bool {
        var spins: usize = 0;
        while (spins < 500) : (spins += 1) {
            if (self.ready.load(.acquire)) return true;
            cc.util_time.sleepMs(10);
        }
        return false;
    }

    fn notify(self: *Instructions) oauth_login.Notify {
        return .{ .ctx = self, .write = write };
    }

    fn snapshot(self: *Instructions) []const u8 {
        return self.buffer.items;
    }

    fn deinit(self: *Instructions) void {
        self.buffer.deinit(self.allocator);
    }
};

/// The page address in what the flow said: the line that starts with the
/// origin's `/auth?`.
fn pageIn(text: []const u8, origin: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, origin) and std.mem.indexOf(u8, line, "/auth?") != null) return line;
    }
    return null;
}

/// The value of query parameter `name` in `url`, still encoded.
fn paramIn(url: []const u8, name: []const u8) ?[]const u8 {
    const query = url[(std.mem.indexOfScalar(u8, url, '?') orelse return null) + 1 ..];
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], name)) return part[eq + 1 ..];
    }
    return null;
}

fn callbackPortIn(url: []const u8) !u16 {
    const callback = paramIn(url, "callback_url") orelse return error.NoCallbackInPage;
    const marker = "http%3A%2F%2Flocalhost%3A";
    if (!std.mem.startsWith(u8, callback, marker)) return error.NoCallbackInPage;
    var port: u32 = 0;
    for (callback[marker.len..]) |c| {
        if (!std.ascii.isDigit(c)) break;
        port = port * 10 + (c - '0');
    }
    return std.math.cast(u16, port) orelse error.NoCallbackInPage;
}

/// Drive the redirect OpenRouter's page would perform.
fn deliverCallback(port: u16, query: []const u8) !void {
    const socket = try net.connectLoopback(port);
    defer net.closeSocket(socket);
    var request_buffer: [1024]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buffer, "GET /auth/callback?{s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{query});
    _ = net.send(socket, request);
    var drain: [1024]u8 = undefined;
    while (net.recv(socket, &drain) > 0) {}
}

/// The S256 challenge of `verifier`, as the page carries it.
fn challengeOf(buffer: []u8, verifier: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return std.base64.url_safe_no_pad.Encoder.encode(buffer, &digest);
}

/// A string field of a captured JSON body, without its quotes (none of the
/// values here carry escapes).
fn jsonString(captured: *const harness.CapturedRequest, key: []const u8) ?[]const u8 {
    const raw = captured.jsonField(key) orelse return null;
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}

fn requestLine(captured: harness.CapturedRequest) []const u8 {
    const end = std.mem.indexOf(u8, captured.raw, "\r\n") orelse captured.raw.len;
    return captured.raw[0..end];
}

fn headerValue(captured: harness.CapturedRequest, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, captured.raw, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

/// OpenRouter's sign-in as `/login openrouter` prepares it.
fn prepared(case: *Case) !provider_login.KeyGrantPrepared {
    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(testing.allocator);
    defer registry.deinit();
    const flow = try provider_login.prepareFlow(registry.find("openrouter").?, .{ .state_root = case.root, .open_browser = false, .port = 0 }, null);
    return flow.key_grant;
}

const FlowRun = struct {
    prepared: provider_login.KeyGrantPrepared,
    io: std.Io,
    notify: oauth_login.Notify,
    result: ?anyerror!provider_login.Outcome = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *FlowRun) void {
        self.result = self.prepared.run(testing.allocator, self.io, self.notify, null);
        self.done.store(true, .release);
    }

    /// Join the flow if it ends within five seconds; otherwise end it through
    /// `abort` and say so, rather than hang the run on a wait that never ends.
    fn finish(self: *FlowRun, thread: std.Thread, abort: *cc.util_abort.AbortSignal) !void {
        var spins: usize = 0;
        while (spins < 500 and !self.done.load(.acquire)) : (spins += 1) cc.util_time.sleepMs(10);
        if (!self.done.load(.acquire)) {
            abort.abort(.user_interrupt);
            thread.join();
            return error.FlowDidNotEnd;
        }
        thread.join();
    }
};

test "L2 OpenRouter: the browser sign-in takes only its own state back, trades code and verifier as JSON, and stores the key with what OpenRouter said" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.startCassette(&.{ EXCHANGED, DESCRIBED }, 0);
    defer server.stop();
    const origin = try case.openRouterAt(server);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();

    var instructions = Instructions{ .allocator = testing.allocator };
    defer instructions.deinit();
    // A failed check below still ends the flow's wait (100 ms steps).
    var abort = cc.util_abort.AbortSignal.init();
    var run = FlowRun{ .prepared = try prepared(&case), .io = io_runtime.io(), .notify = instructions.notify() };
    run.prepared.options.abort_signal = &abort;
    try testing.expectEqualStrings(origin, run.prepared.origin);
    var thread = try std.Thread.spawn(.{}, FlowRun.run, .{&run});
    var joined = false;
    defer if (!joined) {
        abort.abort(.user_interrupt);
        thread.join();
    };

    if (!instructions.wait()) return error.FlowNeverPublishedInstructions;
    const said = try a.dupe(u8, instructions.snapshot());
    // The page is on the mock — the precondition for delivering any code.
    const page = pageIn(said, origin) orelse {
        std.debug.print("instructions:\n{s}\n", .{said});
        return error.PageNotOnTheMock;
    };
    try testing.expect(std.mem.startsWith(u8, page, try std.fmt.allocPrint(a, "{s}/auth?callback_url=http%3A%2F%2Flocalhost%3A", .{origin})));
    try testing.expectEqualStrings("S256", paramIn(page, "code_challenge_method").?);
    try testing.expectEqualStrings("metacodes", paramIn(page, "key_label").?);
    try testing.expect(paramIn(page, "client_id") == null);
    const port = try callbackPortIn(page);
    const state = paramIn(page, "state") orelse return error.NoStateInPage;
    const challenge = paramIn(page, "code_challenge") orelse return error.NoChallengeInPage;
    try testing.expect(std.mem.indexOf(u8, said, try std.fmt.allocPrint(a, "OpenRouter shows this sign-in as \"localhost:{d}\".", .{port})) != null);
    try testing.expect(std.mem.indexOf(u8, said, "Open this URL to sign in:") != null);

    // A callback with another state is neither taken nor exchanged.
    try deliverCallback(port, "code=stray-code&state=not-the-state");
    try testing.expectEqual(@as(usize, 0), server.requestCount());

    try deliverCallback(port, try std.fmt.allocPrint(a, "code=auth-code-42&state={s}", .{state}));
    joined = true;
    try run.finish(thread, &abort);
    _ = try (run.result orelse return error.FlowDidNotRun);

    // The exchange: JSON, the code, S256, and the verifier the page's
    // challenge was made from.
    try testing.expectEqual(@as(usize, 2), server.requestCount());
    const exchange = server.requestAt(0).?;
    try testing.expectEqualStrings("POST /api/v1/auth/keys HTTP/1.1", requestLine(exchange));
    try testing.expectEqualStrings("application/json", headerValue(exchange, "content-type").?);
    try testing.expectEqualStrings("auth-code-42", jsonString(&exchange, "code").?);
    try testing.expectEqualStrings("S256", jsonString(&exchange, "code_challenge_method").?);
    const verifier = jsonString(&exchange, "code_verifier") orelse return error.NoVerifierInExchange;
    var challenge_buf: [64]u8 = undefined;
    try testing.expectEqualStrings(challenge, challengeOf(&challenge_buf, verifier));
    try testing.expect(headerValue(exchange, "authorization") == null);
    try testing.expectEqualStrings("metacodes/" ++ cc.VERSION, headerValue(exchange, "user-agent") orelse "");
    // The description: the new key, on the key page.
    const described = server.requestAt(1).?;
    try testing.expectEqualStrings("GET /api/v1/key HTTP/1.1", requestLine(described));
    try testing.expectEqualStrings("Bearer " ++ KEY, headerValue(described, "authorization").?);

    var stored = (try key_store.load(testing.allocator, case.root, OPENROUTER)).?;
    defer stored.deinit();
    try testing.expectEqualStrings(KEY, stored.secret);
    try testing.expectEqual(cc.provider_credential.CredentialKind.api_key, stored.kind);
    try testing.expectEqual(key_store.Obtained.browser_sign_in, stored.meta.obtained.?);
    try testing.expect(stored.meta.described);
    try testing.expectEqualStrings("sk-or-v1-0e6...1c96", stored.meta.label.?);
    try testing.expect(stored.meta.limit_usd == null and stored.meta.expires_at == null);
    // Nothing the user was shown carries the key or the verifier.
    const shown = instructions.snapshot();
    try testing.expect(std.mem.indexOf(u8, shown, KEY) == null);
    try testing.expect(std.mem.indexOf(u8, shown, verifier) == null);
}

test "L2 OpenRouter: a refusal ends the sign-in at once, with or without a state, and stores nothing" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.startCassette(&.{EXCHANGED}, 0);
    defer server.stop();
    const origin = try case.openRouterAt(server);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();

    for ([_]bool{ false, true }) |with_state| {
        var instructions = Instructions{ .allocator = testing.allocator };
        defer instructions.deinit();
        var abort = cc.util_abort.AbortSignal.init();
        var run = FlowRun{ .prepared = try prepared(&case), .io = io_runtime.io(), .notify = instructions.notify() };
        run.prepared.options.abort_signal = &abort;
        var thread = try std.Thread.spawn(.{}, FlowRun.run, .{&run});
        if (!instructions.wait()) {
            abort.abort(.user_interrupt);
            thread.join();
            return error.FlowNeverPublishedInstructions;
        }
        const said = try a.dupe(u8, instructions.snapshot());
        const page = pageIn(said, origin) orelse {
            abort.abort(.user_interrupt);
            thread.join();
            return error.PageNotOnTheMock;
        };
        const port = try callbackPortIn(page);
        const query = if (with_state)
            try std.fmt.allocPrint(a, "error=access_denied&state={s}", .{paramIn(page, "state").?})
        else
            "error=access_denied";
        try deliverCallback(port, query);
        // A refusal ends the wait at once; one that left it waiting is a
        // failure here, not a hung run.
        try run.finish(thread, &abort);
        try testing.expectError(error.KeyGrantDeclined, run.result.?);
    }
    try testing.expectEqual(@as(usize, 0), server.requestCount());
    try testing.expect(try key_store.load(testing.allocator, case.root, OPENROUTER) == null);
}

test "L2 OpenRouter: an expired or refused code says which, and stores nothing" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();

    const Expectation = struct { body: []const u8, err: anyerror };
    for ([_]Expectation{
        .{ .body = "{\"error\":{\"code\":403,\"message\":\"Authorization code expired\"}}", .err = error.KeyGrantCodeExpired },
        .{ .body = "{\"error\":{\"code\":403,\"message\":\"Invalid code or code_verifier\"}}", .err = error.KeyGrantCodeRefused },
    }) |expectation| {
        var server = try harness.MockServer.startRepeatingStatus(expectation.body, "HTTP/1.1 403 Forbidden", "");
        defer server.stop();
        const origin = try case.openRouterAt(server);
        var pending = try openrouter_login.Pending.begin(testing.allocator, origin, cc.provider_registry.openrouter.KEY_GRANT);
        defer pending.deinit();
        var flow = try prepared(&case);
        flow.pasted = .{ .code = "pasted-code", .verifier = pending.verifier() };
        try testing.expectError(expectation.err, flow.run(testing.allocator, io_runtime.io(), oauth_login.stderrNotify(), null));
        try testing.expectEqual(@as(usize, 1), server.requestCount());
        try testing.expect(try key_store.load(testing.allocator, case.root, OPENROUTER) == null);
    }
}

test "L2 OpenRouter: on another device the page shows the code; the code pasted back is traded with the verifier kept here" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.startCassette(&.{ EXCHANGED, DESCRIBED }, 0);
    defer server.stop();
    const origin = try case.openRouterAt(server);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();

    var flow = try prepared(&case);
    var pending = try openrouter_login.Pending.begin(testing.allocator, flow.origin, flow.grant);
    defer pending.deinit();
    // No callback and no state: the page shows the code instead.
    try testing.expect(std.mem.startsWith(u8, pending.url, try std.fmt.allocPrint(a, "{s}/auth?code_challenge=", .{origin})));
    try testing.expect(paramIn(pending.url, "callback_url") == null);
    try testing.expect(paramIn(pending.url, "state") == null);
    try testing.expect(std.mem.indexOf(u8, pending.url, pending.verifier()) == null);

    flow.pasted = .{ .code = "  shown-code-7 \n", .verifier = pending.verifier() };
    _ = try flow.run(testing.allocator, io_runtime.io(), oauth_login.stderrNotify(), null);
    const exchange = server.requestAt(0).?;
    // Whitespace a paste carries is not part of the code.
    try testing.expectEqualStrings("shown-code-7", jsonString(&exchange, "code").?);
    var challenge_buf: [64]u8 = undefined;
    try testing.expectEqualStrings(paramIn(pending.url, "code_challenge").?, challengeOf(&challenge_buf, jsonString(&exchange, "code_verifier") orelse return error.NoVerifierInExchange));
    var stored = (try key_store.load(testing.allocator, case.root, OPENROUTER)).?;
    defer stored.deinit();
    try testing.expectEqualStrings(KEY, stored.secret);
}

/// A pasted key for OpenRouter, prepared the way `/login openrouter` and
/// `login --provider openrouter --api-key-stdin` prepare it, against the host
/// a session builds (the override moved its key page too).
fn pasteKey(case: *Case, io: std.Io, key: []const u8) !void {
    const host = try cc.provider_host.Host.create(testing.allocator);
    defer host.destroy();
    openrouter_login.applyOriginOverride(host);
    const profile = host.registry.find("openrouter").?;
    const flow = try provider_login.prepareApiKey(profile, null, profile.default_channel, key, .{ .state_root = case.root });
    try testing.expect(flow.describes);
    // The check carries the key: it must be on the mock before anything is sent.
    try testing.expect(std.mem.startsWith(u8, flow.page.check_url.?, "http://127.0.0.1:"));
    _ = try flow.run(testing.allocator, io, oauth_login.stderrNotify(), null);
}

test "L2 OpenRouter: a pasted key is checked at /api/v1/key, stored as pasted with what that said, and a refused one is not stored" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();

    {
        var server = try harness.MockServer.startRepeatingStatus("{\"error\":{\"code\":401,\"message\":\"User not found.\"}}", "HTTP/1.1 401 Unauthorized", "");
        defer server.stop();
        _ = try case.openRouterAt(server);
        try testing.expectError(error.KeyRefused, pasteKey(&case, io_runtime.io(), "sk-or-v1-wrong"));
        try testing.expectEqualStrings("GET /api/v1/key HTTP/1.1", requestLine(server.lastRequest().?));
        try testing.expect(try key_store.load(testing.allocator, case.root, OPENROUTER) == null);
    }
    var server = try harness.MockServer.start(DESCRIBED, 0);
    defer server.stop();
    _ = try case.openRouterAt(server);
    try pasteKey(&case, io_runtime.io(), "  " ++ KEY ++ "\n");
    const check = server.lastRequest().?;
    try testing.expectEqualStrings("GET /api/v1/key HTTP/1.1", requestLine(check));
    try testing.expectEqualStrings("Bearer " ++ KEY, headerValue(check, "authorization").?);
    var stored = (try key_store.load(testing.allocator, case.root, OPENROUTER)).?;
    defer stored.deinit();
    try testing.expectEqualStrings(KEY, stored.secret);
    try testing.expectEqual(key_store.Obtained.pasted, stored.meta.obtained.?);
    try testing.expect(stored.meta.described);
    try testing.expectEqualStrings("sk-or-v1-0e6...1c96", stored.meta.label.?);
    try testing.expectEqualStrings("keys", stored.page.?);
}

test "L2 OpenRouter: the origin override moves every address, requests included, and only to https or a loopback host" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.start(OPENAI_SSE, 0);
    defer server.stop();
    const origin = try case.openRouterAt(server);

    // The sign-in's addresses.
    const flow = try prepared(&case);
    try testing.expectEqualStrings(origin, flow.origin);
    // The requests': the host's profile is moved there too.
    const host = try cc.provider_host.Host.create(testing.allocator);
    defer host.destroy();
    openrouter_login.applyOriginOverride(host);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/api/v1", .{origin}), host.registry.find("openrouter").?.channels[0].base_url);
    for (host.kernel.catalogSnapshot().items()) |item| {
        if (!item.provider_id.eqlText("openrouter")) continue;
        try testing.expect(std.mem.startsWith(u8, item.endpoint_ref, origin));
    }
    // The key page's check, which carries a pasted key.
    const page = host.registry.find("openrouter").?.api_key_setup.?.pages[0];
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/api/v1/key", .{origin}), page.check_url.?);

    // Not a host other than the loopback over plain HTTP: the profile's own.
    try case.setEnv(openrouter_login.ORIGIN_ENV, "http://openrouter.example.com");
    try testing.expectEqualStrings("https://openrouter.ai", (try prepared(&case)).origin);
    const unmoved = try cc.provider_host.Host.create(testing.allocator);
    defer unmoved.destroy();
    openrouter_login.applyOriginOverride(unmoved);
    try testing.expectEqualStrings("https://openrouter.ai/api/v1", unmoved.registry.find("openrouter").?.channels[0].base_url);
}

test "L2 OpenRouter: logging out removes the key and names the page its owner deletes it on; a new sign-in can name the key the last one left" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    const grant = cc.provider_registry.openrouter.KEY_GRANT;
    try key_store.saveWithMeta(testing.allocator, case.root, OPENROUTER, .api_key, KEY, null, .{ .obtained = .browser_sign_in }, 1);

    // Before a new sign-in replaces it: the old key's page.
    const previous = openrouter_login.storedKeyManageUrl(testing.allocator, case.root, OPENROUTER, grant.origin, grant).?;
    defer testing.allocator.free(previous);
    const expected = try openrouter_login.manageUrl(a, grant.origin, grant, KEY);
    try testing.expectEqualStrings(expected, previous);
    try testing.expect(std.mem.startsWith(u8, previous, "https://openrouter.ai/keys/"));
    try testing.expect(std.mem.indexOf(u8, previous, KEY) == null);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const argv = [_][*:0]const u8{"metacodes"};
    const app = try App.init(testing.allocator, io_runtime.io(), try case.config(&argv), "metask-key");
    defer app.deinit();
    const forgotten = try app.forgetProviderKey(OPENROUTER);
    try testing.expect(forgotten.removed);
    try testing.expectEqualStrings(expected, forgotten.manageUrl().?);
    try testing.expect(try key_store.load(testing.allocator, case.root, OPENROUTER) == null);
    // Nothing left to name the second time.
    const again = try app.forgetProviderKey(OPENROUTER);
    try testing.expect(!again.removed and again.manageUrl() == null);
}

test "L2 OpenRouter: the stored key starts an OpenRouter session and reaches its requests, and no other provider's" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    try key_store.saveWithMeta(testing.allocator, case.root, OPENROUTER, .api_key, KEY, null, .{ .obtained = .browser_sign_in }, 1);

    const argv = [_][*:0]const u8{ "metacodes", "--provider", "openrouter" };
    const config = try case.config(&argv);
    const secret = try cc.resolveProviderScopedSecret(testing.allocator, config, "openrouter");
    defer testing.allocator.free(secret);
    try testing.expectEqualStrings(KEY, secret);
    // ...and not for another provider.
    try testing.expectError(error.MissingCredentials, cc.resolveProviderScopedSecret(testing.allocator, config, "deepseek"));

    // `--provider openrouter` the way a start resolves it, with the override
    // moving the route onto the mock: OpenRouter's router channel and model,
    // OpenRouter's dialect, the stored key.
    var server = try harness.MockServer.start(OPENAI_SSE, 0);
    defer server.stop();
    const origin = try case.openRouterAt(server);
    const host = try cc.provider_host.Host.create(testing.allocator);
    defer host.destroy();
    openrouter_login.applyOriginOverride(host);
    const outcome = try cc.provider_startup.resolve(testing.allocator, &host.registry, .{ .provider = "openrouter" });
    var route = switch (outcome) {
        .route => |value| value,
        .failure => return error.RouteNotResolved,
    };
    defer route.deinit();
    try testing.expect(route.channel_id.eqlText("auto"));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/api/v1/chat/completions", .{origin}), route.endpoint_url);
    try testing.expectEqualStrings("openrouter/auto", route.request_model_id);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.api_openai.OpenAIClient.init(testing.allocator, io_runtime.io(), secret, route.request_model_id, route.endpoint_url);
    defer client.deinit();
    client.protocol = route.openai_protocol;
    client.auth_scheme = route.auth_scheme;
    client.declared_dialect = route.dialect;
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try client.provider().sendStream(&messages, null, null, null, null, null, "");
    while (try handle.next()) |event| switch (event) {
        .text, .thinking, .reasoning_item, .web_search_query => |bytes| testing.allocator.free(bytes),
        else => {},
    };
    handle.deinit();
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("POST /api/v1/chat/completions HTTP/1.1", requestLine(captured));
    try testing.expectEqualStrings("Bearer " ++ KEY, headerValue(captured, "authorization").?);
    try testing.expectEqualStrings("\"openrouter/auto\"", captured.jsonField("model").?);
}

// ── the account's models in /model ─────────────────────────────────────────

const LISTING =
    \\{"data": [
    \\  {"id": "deepseek/deepseek-v4.1-flash", "name": "DeepSeek: DeepSeek V4.1 Flash", "context_length": 1048576,
    \\   "top_provider": {"max_completion_tokens": 65536},
    \\   "pricing": {"prompt": "0.0000001", "completion": "0.0000004"},
    \\   "supported_parameters": ["tools", "reasoning"], "endpoints": ["/api/v1/chat/completions"]},
    \\  {"id": "moonshotai/kimi-k3", "name": "MoonshotAI: Kimi K3",
    \\   "pricing": {"prompt": "0.0000006", "completion": "0.0000025"},
    \\   "supported_parameters": ["tools"], "endpoints": ["/api/v1/chat/completions"]},
    \\  {"id": "openai/gpt-6.2-sol:batch", "supported_parameters": ["tools"], "endpoints": ["/api/v1/batches"]},
    \\  {"id": "some/no-tools", "supported_parameters": ["temperature"], "endpoints": ["/api/v1/chat/completions"]}
    \\]}
;

fn openRouterOffers(host: *cc.provider_host.Host) usize {
    var count: usize = 0;
    for (host.kernel.catalogSnapshot().items()) |item| {
        if (item.provider_id.eqlText("openrouter")) count += 1;
    }
    return count;
}

test "L2 OpenRouter: the account's listing is fetched with the key, kept, and a start lists it without a request" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.start(LISTING, 0);
    defer server.stop();
    const origin = try case.openRouterAt(server);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();

    const host = try cc.provider_host.Host.create(testing.allocator);
    defer host.destroy();
    openrouter_login.applyOriginOverride(host);
    // Before: only the compiled router model.
    try testing.expectEqual(@as(usize, 1), openRouterOffers(host));
    const listing_url = try cc.api_openrouter_catalog.listingUrl(a);
    try testing.expect(std.mem.startsWith(u8, listing_url, origin));
    try testing.expectEqual(@as(usize, 2), try cc.api_openrouter_catalog.refresh(testing.allocator, io_runtime.io(), case.root, KEY, host));
    const fetched = server.lastRequest().?;
    try testing.expectEqualStrings("GET /api/v1/models/user HTTP/1.1", requestLine(fetched));
    try testing.expectEqualStrings("Bearer " ++ KEY, headerValue(fetched, "authorization").?);
    // The batch-only and the tool-less models are left out.
    try testing.expectEqual(@as(usize, 2), openRouterOffers(host));
    var pinned: ?cc.provider_ids.OfferId = null;
    for (host.kernel.catalogSnapshot().items()) |item| {
        if (!item.provider_id.eqlText("openrouter")) continue;
        try testing.expect(item.channel_id.eqlText("auto"));
        try testing.expect(std.mem.startsWith(u8, item.endpoint_ref, origin));
        if (std.mem.eql(u8, item.request_model_id, "deepseek/deepseek-v4.1-flash")) pinned = item.offer_id;
    }

    // A later start: the kept copy, no request, the same offer ids.
    const later = try cc.provider_host.Host.create(testing.allocator);
    defer later.destroy();
    openrouter_login.applyOriginOverride(later);
    try testing.expectEqual(cc.api_openrouter_catalog.Kept.fresh, cc.api_openrouter_catalog.adoptKept(later, testing.allocator, case.root));
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    try testing.expectEqual(@as(usize, 2), openRouterOffers(later));
    try testing.expect(later.kernel.catalogSnapshot().find(pinned.?) != null);
}

const PinnedDefault = struct {
    offer_id: cc.provider_ids.OfferId,
    revision: cc.provider_ids.OfferRevision,
};

fn pinOpenRouterDefault(case: *Case, io: std.Io, model: []const u8) !PinnedDefault {
    const a = case.arena.allocator();
    const host = try cc.provider_host.Host.create(testing.allocator);
    defer host.destroy();
    openrouter_login.applyOriginOverride(host);
    _ = try cc.api_openrouter_catalog.refresh(testing.allocator, io, case.root, KEY, host);
    var found: ?PinnedDefault = null;
    for (host.kernel.catalogSnapshot().items()) |item| {
        if (item.provider_id.eqlText("openrouter") and std.mem.eql(u8, item.request_model_id, model))
            found = .{ .offer_id = item.offer_id, .revision = item.offer_revision };
    }
    const pinned = found orelse return error.ModelNotListed;
    const config_path = try std.fs.path.join(a, &.{ case.root, "config.json" });
    var store = try cc.provider_config_store.Store.initPath(testing.allocator, config_path);
    defer store.deinit();
    _ = try cc.provider_config_store.setGlobalSelection(
        &store,
        cc.provider_selection.RuntimeSelection.pinned(pinned.offer_id, pinned.revision, .global),
        null,
        "openrouter-default",
    );
    return pinned;
}

fn dropKeptListing(case: *Case) !void {
    const models = try std.fs.path.join(case.arena.allocator(), &.{ case.root, "cache", "models" });
    try std.Io.Dir.cwd().deleteTree(testing.io, models);
    try testing.expectEqual(cc.api_openrouter_catalog.Kept.none, cc.api_openrouter_catalog.keptAge(testing.allocator, case.root));
}

test "L2 OpenRouter: a stored default on an OpenRouter model starts with no listing kept: the start downloads the listing first" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", null);
    var server = try harness.MockServer.startCassette(&.{ LISTING, LISTING }, 0);
    defer server.stop();
    _ = try case.openRouterAt(server);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    try key_store.saveWithMeta(testing.allocator, case.root, OPENROUTER, .api_key, KEY, null, .{ .obtained = .browser_sign_in }, 1);
    const pinned = try pinOpenRouterDefault(&case, io_runtime.io(), "deepseek/deepseek-v4.1-flash");
    try dropKeptListing(&case);

    const argv = [_][*:0]const u8{"metacodes"};
    var config = try case.config(&argv);
    try testing.expect(cc.applyPersistedGlobalSelection(&config, a));

    try testing.expectEqualStrings("deepseek/deepseek-v4.1-flash", config.model);
    try testing.expectEqualStrings("openrouter", config.resolved_provider_id.?);
    try testing.expectEqualStrings(&pinned.offer_id.render(), config.selected_offer_id.?);
    try testing.expectEqual(@as(usize, 2), server.requestCount());
    const fetched = server.lastRequest().?;
    try testing.expectEqualStrings("GET /api/v1/models/user HTTP/1.1", requestLine(fetched));
    try testing.expectEqualStrings("Bearer " ++ KEY, headerValue(fetched, "authorization").?);
    try testing.expect(cc.api_openrouter_catalog.keptAge(testing.allocator, case.root) == .fresh);
}

test "L2 OpenRouter: a start downloads a missing listing only with no probe barred, a key set and nothing kept, and says why it failed" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", null);
    var listing_server = try harness.MockServer.start(LISTING, 0);
    defer listing_server.stop();
    _ = try case.openRouterAt(listing_server);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    _ = try pinOpenRouterDefault(&case, io_runtime.io(), "deepseek/deepseek-v4.1-flash");
    const argv = [_][*:0]const u8{"metacodes"};
    const config = try case.config(&argv);

    try key_store.saveWithMeta(testing.allocator, case.root, OPENROUTER, .api_key, KEY, null, .{ .obtained = .browser_sign_in }, 1);
    try testing.expect(cc.fetchMissingOpenRouterListing(a, config) == .skipped);
    try testing.expectEqual(@as(usize, 1), listing_server.requestCount());

    try dropKeptListing(&case);
    try case.setEnv("METACODES_NO_PROBE", "1");
    try testing.expect(cc.fetchMissingOpenRouterListing(a, config) == .skipped);
    try case.setEnv("METACODES_NO_PROBE", null);

    _ = try key_store.remove(testing.allocator, case.root, OPENROUTER);
    try testing.expect(cc.fetchMissingOpenRouterListing(a, config) == .skipped);
    try key_store.saveWithMeta(testing.allocator, case.root, OPENROUTER, .api_key, KEY, null, .{ .obtained = .browser_sign_in }, 1);
    try testing.expectEqual(@as(usize, 1), listing_server.requestCount());

    const answers = [_]struct { status: []const u8, failure: cc.api_openrouter_catalog.Failure }{
        .{ .status = "HTTP/1.1 500 Internal Server Error", .failure = .server_error },
        .{ .status = "HTTP/1.1 401 Unauthorized", .failure = .refused },
    };
    for (answers) |answer| {
        var refusing = try harness.MockServer.startRepeatingStatus("{\"error\":{\"message\":\"no\"}}", answer.status, "");
        defer refusing.stop();
        _ = try case.openRouterAt(refusing);
        const outcome = cc.fetchMissingOpenRouterListing(a, config);
        try testing.expect(outcome == .failed);
        try testing.expectEqual(answer.failure, outcome.failed);
        try testing.expect(cc.api_openrouter_catalog.keptAge(testing.allocator, case.root) == .none);
    }
}

/// A provider of the user's own on the OpenAI wire, at `origin`.
fn relayConfig(a: std.mem.Allocator, origin: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"custom_providers": {{"house-relay": {{
        \\  "display_name": "House relay",
        \\  "credential_kinds": ["api_key"],
        \\  "env_aliases": [{{"name": "HOUSE_RELAY_TOKEN", "kind": "api_key", "canonical": true}}],
        \\  "channels": [{{"id": "primary", "base_url": "{s}/relay/v1", "protocol": "openai_chat"}}],
        \\  "models": [{{"request_model_id": "relay-model", "display_name": "Relay model"}}]}}}}}}
    , .{origin});
}

fn sendHi(app: *App) !void {
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try app.provider().sendStream(&messages, null, null, null, null, null, "");
    while (try handle.next()) |event| switch (event) {
        .text, .thinking, .reasoning_item, .web_search_query => |bytes| app.allocator.free(bytes),
        else => {},
    };
    handle.deinit();
}

/// Pick, in `/model`, the first offer whose name contains `typed`, of
/// `provider`, for this session.
fn pick(app: *App, typed: []const u8, provider: []const u8) !void {
    const picker_host = cc.repl_picker_host;
    var ui: cc.tui_ui_state.UiState = .{};
    picker_host.open(app, &ui, .unguarded);
    for (typed) |byte| _ = picker_host.onKey(app, &ui, .{ .char = byte }, .unguarded);
    const focused = app.model_picker.focusedOffer() orelse return error.NothingToPick;
    try testing.expect(focused.provider_id.eqlText(provider));
    try testing.expectEqual(picker_host.Result.committed, picker_host.onKey(app, &ui, .enter, .unguarded));
}

test "L2 OpenRouter: /model lists the account's models; switching to and from them takes each provider's own key and no other" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    // OpenRouter's mock answers the listing, then the chats.
    var openrouter = try harness.MockServer.startCassette(&.{ LISTING, OPENAI_SSE, OPENAI_SSE }, 0);
    defer openrouter.stop();
    _ = try case.openRouterAt(openrouter);
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    const relay_url = try relay.urlOwned(a);
    try case.tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = try relayConfig(a, relay_url[0 .. relay_url.len - "/v1/messages".len]) });
    // Both keys stored, each in its provider's own file: a lookup that did not
    // keep to the provider being bound would hand one the other's.
    try key_store.save(testing.allocator, case.root, Slug.lit("house-relay"), .api_key, "relay-key-77", null, 1);
    try key_store.saveWithMeta(testing.allocator, case.root, OPENROUTER, .api_key, KEY, null, .{ .obtained = .browser_sign_in }, 1);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const argv = [_][*:0]const u8{"metacodes"};
    const app = try App.init(testing.allocator, io_runtime.io(), try case.config(&argv), "metask-key");
    defer app.deinit();

    // What `/login openrouter` does once the key is stored.
    try testing.expectEqual(@as(?usize, 2), try app.refreshOpenRouterListing());
    try testing.expectEqualStrings("GET /api/v1/models/user HTTP/1.1", requestLine(openrouter.requestAt(0).?));

    // Pick an OpenRouter model: its route, its key.
    try pick(app, "deepseek-v4.1", "openrouter");
    try testing.expectEqualStrings("deepseek/deepseek-v4.1-flash", app.activeModel());
    try testing.expectEqualStrings(KEY, app.api_key);
    try sendHi(app);
    const chat = openrouter.lastRequest().?;
    try testing.expectEqualStrings("POST /api/v1/chat/completions HTTP/1.1", requestLine(chat));
    try testing.expectEqualStrings("Bearer " ++ KEY, headerValue(chat, "authorization") orelse "");
    try testing.expectEqualStrings("\"deepseek/deepseek-v4.1-flash\"", chat.jsonField("model").?);
    // Who is calling, as OpenRouter's app attribution asks: the project's
    // address, its name, a terminal coding agent. Nothing about the user.
    try testing.expectEqualStrings("https://github.com/metask-ai/metacodes", headerValue(chat, "http-referer") orelse "");
    try testing.expectEqualStrings("metacodes", headerValue(chat, "x-openrouter-title") orelse "");
    try testing.expectEqualStrings("cli-agent", headerValue(chat, "x-openrouter-categories") orelse "");
    try testing.expect(headerValue(chat, "x-openrouter-app-visibility") == null);
    try testing.expectEqualStrings("metacodes/" ++ cc.VERSION, headerValue(chat, "user-agent") orelse "");

    // Away to the user's relay: its key, and OpenRouter's stays behind.
    try pick(app, "relay-model", "house-relay");
    try testing.expectEqualStrings("relay-key-77", app.api_key);
    try sendHi(app);
    try testing.expectEqual(@as(usize, 1), relay.requestCount());
    try testing.expectEqualStrings("Bearer relay-key-77", headerValue(relay.lastRequest().?, "authorization") orelse "");
    // OpenRouter's attribution is OpenRouter's: another provider gets none.
    try testing.expect(headerValue(relay.lastRequest().?, "http-referer") == null);
    try testing.expect(headerValue(relay.lastRequest().?, "x-openrouter-title") == null);

    // And back: OpenRouter's key again, never the relay's.
    try pick(app, "kimi-k3", "openrouter");
    try testing.expectEqualStrings(KEY, app.api_key);
    try sendHi(app);
    try testing.expectEqual(@as(usize, 3), openrouter.requestCount());
    for (0..openrouter.requestCount()) |index| {
        const seen = openrouter.requestAt(index).?;
        try testing.expect(std.mem.indexOf(u8, seen.raw, "relay-key-77") == null);
        try testing.expect(std.mem.indexOf(u8, seen.raw, "metask-key") == null);
    }
    for (0..relay.requestCount()) |index| {
        const seen = relay.requestAt(index).?;
        try testing.expect(std.mem.indexOf(u8, seen.raw, KEY) == null);
        try testing.expect(std.mem.indexOf(u8, seen.raw, "metask-key") == null);
    }
}

fn appWithOpenRouterKey(case: *Case, io: std.Io) !*App {
    try key_store.saveWithMeta(testing.allocator, case.root, OPENROUTER, .api_key, KEY, null, .{ .obtained = .browser_sign_in }, 1);
    const argv = [_][*:0]const u8{"metacodes"};
    const app = try App.init(testing.allocator, io, try case.config(&argv), "metask-key");
    app.openrouter_retry_pause_ms = 20;
    return app;
}

fn waitForFetch(app: *App) !App.OpenRouterChange {
    const deadline = cc.util_time.nowMs() + 10_000;
    while (cc.util_time.nowMs() < deadline) {
        const change = app.takeOpenRouterRefresh(cc.util_time.nowMs());
        if (app.openrouter_refresh == null) return change;
        cc.util_time.sleepMs(10);
    }
    return error.FetchNeverFinished;
}

test "L2 OpenRouter: a sign-in's list downloads in the background; /model says so, and fills in with the filter kept (#572)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.start(LISTING, 0);
    defer server.stop();
    _ = try case.openRouterAt(server);
    server.gateNextResponse();
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const app = try appWithOpenRouterKey(&case, io_runtime.io());
    defer app.deinit();

    try app.startOpenRouterRefresh(true);
    try server.waitUntilResponseGated();
    const picker_host = cc.repl_picker_host;
    var ui: cc.tui_ui_state.UiState = .{};
    picker_host.open(app, &ui, .unguarded);
    const waiting = app.model_picker.shownListNote() orelse return error.NoLineAboutTheList;
    try testing.expect(waiting.state == .downloading);
    try testing.expectEqualStrings("OpenRouter", waiting.name());
    for ("kimi-k3") |byte| _ = picker_host.onKey(app, &ui, .{ .char = byte }, .unguarded);
    try testing.expect(app.model_picker.focusedOffer() == null);
    try testing.expect(!app.takeOpenRouterRefresh(cc.util_time.nowMs()).listed);
    try testing.expect(!picker_host.renote(app, .unguarded));

    server.releaseGatedResponse();
    try testing.expect((try waitForFetch(app)).listed);
    picker_host.relist(app, .unguarded);
    try testing.expectEqualStrings("kimi-k3", app.model_picker.filter());
    try testing.expectEqualStrings("moonshotai/kimi-k3", app.model_picker.focusedOffer().?.request_model_id);
    try testing.expect(app.model_picker.shownListNote() == null);
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    try testing.expectEqualStrings("GET /api/v1/models/user HTTP/1.1", requestLine(server.lastRequest().?));
    try testing.expectEqualStrings("Bearer " ++ KEY, headerValue(server.lastRequest().?, "authorization").?);
    const later = try cc.provider_host.Host.create(testing.allocator);
    defer later.destroy();
    openrouter_login.applyOriginOverride(later);
    try testing.expectEqual(cc.api_openrouter_catalog.Kept.fresh, cc.api_openrouter_catalog.adoptKept(later, testing.allocator, case.root));
}

test "L2 OpenRouter: a dropped connection is tried once more; failing again, /model says why and Ctrl+R fetches again (#572)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.startFlaky(LISTING, 3);
    defer server.stop();
    _ = try case.openRouterAt(server);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const app = try appWithOpenRouterKey(&case, io_runtime.io());
    defer app.deinit();

    try app.startOpenRouterRefresh(true);
    try testing.expect(!(try waitForFetch(app)).listed);
    try testing.expectEqual(@as(usize, 2), server.requestCount());
    const picker_host = cc.repl_picker_host;
    var ui: cc.tui_ui_state.UiState = .{};
    picker_host.open(app, &ui, .unguarded);
    const failed = app.model_picker.shownListNote() orelse return error.NoLineAboutTheList;
    try testing.expect(failed.state == .failed and failed.state.failed == .connection);
    try testing.expect(failed.retryable());

    try testing.expectEqual(picker_host.Result.redraw, picker_host.onKey(app, &ui, .retry, .unguarded));
    try testing.expect(app.model_picker.shownListNote().?.state == .downloading);
    try testing.expect((try waitForFetch(app)).listed);
    picker_host.relist(app, .unguarded);
    try testing.expect(app.model_picker.shownListNote() == null);
    try testing.expectEqual(@as(usize, 4), server.requestCount());
    try testing.expectEqual(@as(usize, 2), openRouterOffers(try app.providerHost()));
}

test "L2 OpenRouter: a refused key is not tried again, and /model says to sign in again, not Ctrl+R (#572)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.startWithStatus(
        \\{"error":{"code":401,"message":"User not found."}}
    , 0, "HTTP/1.1 401 Unauthorized");
    defer server.stop();
    _ = try case.openRouterAt(server);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const app = try appWithOpenRouterKey(&case, io_runtime.io());
    defer app.deinit();

    try app.startOpenRouterRefresh(true);
    try testing.expect(!(try waitForFetch(app)).listed);
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    const picker_host = cc.repl_picker_host;
    var ui: cc.tui_ui_state.UiState = .{};
    picker_host.open(app, &ui, .unguarded);
    const refused = app.model_picker.shownListNote() orelse return error.NoLineAboutTheList;
    try testing.expect(refused.state == .failed and refused.state.failed == .refused);
    try testing.expectEqual(picker_host.Result.ignored, picker_host.onKey(app, &ui, .retry, .unguarded));
    try testing.expectEqual(@as(usize, 1), server.requestCount());
}

test "L2 OpenRouter: a fetch that only updates a kept list says nothing in /model, and a newer fetch supersedes it (#572)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.startCassette(&.{ LISTING, LISTING }, 0);
    defer server.stop();
    _ = try case.openRouterAt(server);
    server.gateResponseAt(0);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const app = try appWithOpenRouterKey(&case, io_runtime.io());
    defer app.deinit();

    try app.startOpenRouterRefresh(false);
    try server.waitUntilResponseGated();
    try testing.expect(app.openRouterListNote(cc.util_time.nowMs()) == null);
    try app.startOpenRouterRefresh(true);
    try testing.expect(app.openRouterListNote(cc.util_time.nowMs()).?.state == .downloading);
    server.releaseGatedResponse();
    try testing.expect((try waitForFetch(app)).listed);
    try testing.expect(app.openRouterListNote(cc.util_time.nowMs()) == null);
}

test "L2 OpenRouter: a fetch with no new byte for a minute is said to have stalled, and still taken when it comes (#572)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena.allocator();
    var server = try harness.MockServer.start(LISTING, 0);
    defer server.stop();
    _ = try case.openRouterAt(server);
    server.gateNextResponse();
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const app = try appWithOpenRouterKey(&case, io_runtime.io());
    defer app.deinit();

    try app.startOpenRouterRefresh(true);
    try server.waitUntilResponseGated();
    const started = cc.util_time.nowMs();
    try testing.expect(app.openRouterListNote(started).?.state == .downloading);
    const later = started + App.OPENROUTER_STALL_MS + 1;
    _ = app.takeOpenRouterRefresh(later);
    const stalled = app.openRouterListNote(later).?;
    try testing.expect(stalled.state == .failed and stalled.state.failed == .stalled);
    try testing.expect(stalled.retryable());
    server.releaseGatedResponse();
    try testing.expect((try waitForFetch(app)).listed);
    try testing.expect(app.openRouterListNote(cc.util_time.nowMs()) == null);
}

test "L2 catalog fetch: an answer cut off partway is Interrupted, not a parse error, and the bytes that came are counted (#572)" {
    const a = testing.allocator;
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    for ([_]harness.LossyProxy.Framing{ .content_length, .chunked }) |framing| {
        var proxy = try harness.LossyProxy.start(LISTING, .{ .content_type = "application/json", .framing = framing, .cut_at = 100, .cut_always = true });
        defer proxy.stop();
        const url = try proxy.urlOwned(a);
        defer a.free(url);
        var received: std.atomic.Value(u64) = .init(0);
        try testing.expectError(error.Interrupted, cc.api_catalog_fetch.fetch(a, io_runtime.io(), .{ .url = url, .progress = &received }));
        try testing.expectEqual(@as(u64, 100), received.load(.monotonic));
    }
    var whole = try harness.LossyProxy.start(LISTING, .{ .content_type = "application/json", .framing = .content_length });
    defer whole.stop();
    const url = try whole.urlOwned(a);
    defer a.free(url);
    var received: std.atomic.Value(u64) = .init(0);
    const answer = try cc.api_catalog_fetch.fetch(a, io_runtime.io(), .{ .url = url, .progress = &received });
    defer a.free(answer.body);
    try testing.expectEqualStrings(LISTING, answer.body);
    try testing.expectEqual(@as(u64, LISTING.len), received.load(.monotonic));
}
