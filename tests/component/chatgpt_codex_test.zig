//! L2 for the `chatgpt-codex` provider: a ChatGPT plan's Codex quota, reached
//! the way the Codex CLI reaches it (plan appendix B), and the shared OAuth
//! pieces it needs (plan §4, "阶段 4、5 共用的部分").
//!
//! Every endpoint is a local mock: the authorization server, the token
//! endpoint, the revocation endpoint and the Codex backend. Nothing reaches
//! OpenAI. The real profile is used throughout, with only its OpenAI URLs
//! pointed at the mocks (or, through the real CLI, `METACODES_BASE_URL`).
//!
//! In process:
//! - the browser sign-in asks for the Codex client with its extra parameters,
//!   says it is unofficial first, takes the second registered port when the
//!   first is held, and stores the ChatGPT workspace from the ID token next to
//!   the client, without the ID token itself;
//! - with every registered port held it stops and names them, sending nothing
//!   to whatever holds them;
//! - a refusal carrying the right state ends the wait and says why; one with
//!   the wrong state does not;
//! - a start refreshes an expired sign-in with the client it recorded, and
//!   keeps the workspace;
//! - signing out revokes the refresh token at the endpoint the profile names,
//!   as JSON, then deletes the sign-in;
//! - only this route's requests get the Codex body fields.
//!
//! - a `/model` pick binds the stored sign-in with the Codex request profile,
//!   and the next start resolves the stored default and its sign-in.
//!
//! Through the real CLI (`METACODES_TEST_CLI_BIN`), with `METACODES_BASE_URL`
//! on the mock backend:
//! - `-p` on `--provider chatgpt-codex` signs in with the stored sign-in and
//!   sends the Codex request profile's headers and body;
//! - a used-up plan is not retried and says when it resets; a plan without
//!   Codex is not retried and says so;
//! - without a sign-in, `-p` says how to sign in and offers no key.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;
const net = @import("platform").net;

const testing = std.testing;
const codex = cc.provider_registry.chatgpt_codex;
const oauth_login = cc.api_oauth_login;
const provider_login = cc.api_provider_login;

const ACCOUNT = "acc-workspace-1";
const CLIENT = "app_EMoamEEZ73f0CkXaXp7hrann";

const RESPONSES_TEXT_SSE =
    "event: response.created\n" ++
    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"ok\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":1}}}\n\n";

/// A JWT whose payload is `payload`; header and signature are placeholders,
/// as nothing here verifies them.
fn jwt(a: std.mem.Allocator, payload: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(payload.len));
    defer a.free(encoded);
    _ = encoder.encode(encoded, payload);
    return std.fmt.allocPrint(a, "eyJhbGciOiJSUzI1NiJ9.{s}.c2ln", .{encoded});
}

fn accessToken(a: std.mem.Allocator, account: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(a, "{{\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_plan_type\":\"plus\"}},\"exp\":4102444800}}", .{account});
    defer a.free(payload);
    return jwt(a, payload);
}

/// What the flow tells the user, collected across threads (as in
/// provider_oauth_login_test.zig): the callback port and the state are only
/// discoverable from the URL the user is asked to open.
const Instructions = struct {
    buffer: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    mutex: @import("platform").sync.Mutex = .{},
    url_seen: std.atomic.Value(bool) = .init(false),

    fn write(raw: *anyopaque, text: []const u8) void {
        const self: *Instructions = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.buffer.appendSlice(self.allocator, text) catch {};
        if (std.mem.indexOf(u8, self.buffer.items, "&state=") != null) self.url_seen.store(true, .release);
    }

    fn notify(self: *Instructions) oauth_login.Notify {
        return .{ .ctx = self, .write = write };
    }

    fn waitForUrl(self: *Instructions) !void {
        var spins: usize = 0;
        while (spins < 500) : (spins += 1) {
            if (self.url_seen.load(.acquire)) return;
            cc.util_time.sleepMs(10);
        }
        return error.FlowNeverPublishedInstructions;
    }

    /// A copy of everything said so far.
    fn snapshot(self: *Instructions, a: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return a.dupe(u8, self.buffer.items);
    }

    fn deinit(self: *Instructions) void {
        self.buffer.deinit(self.allocator);
    }
};

/// Aborts after ten seconds unless told it is done first.
const Watchdog = struct {
    signal: cc.util_abort.AbortSignal = cc.util_abort.AbortSignal.init(),
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watchdog) void {
        var waited_ms: u32 = 0;
        while (waited_ms < 10_000) : (waited_ms += 10) {
            if (self.done.load(.acquire)) return;
            cc.util_time.sleepMs(10);
        }
        self.signal.abort(.user_interrupt);
    }
};

fn callbackPortIn(text: []const u8) !u16 {
    const marker = "redirect_uri=http%3A%2F%2Flocalhost%3A";
    const at = std.mem.indexOf(u8, text, marker) orelse return error.NoRedirectInInstructions;
    var cursor = at + marker.len;
    var port: u32 = 0;
    while (cursor < text.len and std.ascii.isDigit(text[cursor])) : (cursor += 1) port = port * 10 + (text[cursor] - '0');
    return std.math.cast(u16, port) orelse error.NoRedirectInInstructions;
}

fn stateIn(text: []const u8) ![]const u8 {
    const marker = "&state=";
    const at = std.mem.indexOf(u8, text, marker) orelse return error.NoStateInInstructions;
    const start = at + marker.len;
    var end = start;
    while (end < text.len and text[end] != '&' and text[end] != '\n') : (end += 1) {}
    return text[start..end];
}

/// The redirect the authorization server would send the browser on.
fn deliverCallback(port: u16, query: []const u8) !void {
    const socket = try net.connectLoopback(port);
    defer net.closeSocket(socket);
    var request_buffer: [1024]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buffer, "GET /auth/callback?{s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{query});
    _ = net.send(socket, request);
    var drain: [1024]u8 = undefined;
    while (net.recv(socket, &drain) > 0) {}
}

/// A loopback port nothing listens on right now.
fn freePort() !u16 {
    const listener = try net.listenLoopback(0, 1);
    defer net.closeSocket(listener.sock);
    return listener.port;
}

const FlowRun = struct {
    flow: provider_login.Flow,
    allocator: std.mem.Allocator,
    io: std.Io,
    notify: oauth_login.Notify,
    result: ?anyerror!provider_login.Outcome = null,

    fn run(self: *FlowRun) void {
        self.result = self.flow.run(self.allocator, self.io, self.notify, null);
    }
};

/// A state root of its own, and the variables that would point the store
/// elsewhere cleared for the test.
const Root = struct {
    tmp: testing.TmpDir,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",
    oauth_dir: ?[:0]u8 = null,

    fn init(self: *Root) !void {
        self.tmp = testing.tmpDir(.{});
        self.path = self.path_buffer[0..try self.tmp.dir.realPath(testing.io, &self.path_buffer)];
        if (std.c.getenv("METACODES_OAUTH_DIR")) |raw| self.oauth_dir = try testing.allocator.dupeZ(u8, std.mem.span(raw));
        ppaths.unsetEnv("METACODES_OAUTH_DIR");
    }

    fn deinit(self: *Root) void {
        if (self.oauth_dir) |saved| {
            ppaths.setEnv("METACODES_OAUTH_DIR", saved.ptr);
            testing.allocator.free(saved);
        }
        self.tmp.cleanup();
    }

    fn read(self: *Root, a: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, sub_path, a, .limited(64 * 1024));
    }

    fn exists(self: *Root, sub_path: []const u8) bool {
        self.tmp.dir.access(testing.io, sub_path, .{}) catch return false;
        return true;
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find `{s}` in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("`{s}` must not appear in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
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

// ── the sign-in ──────────────────────────────────────────────────────────────

test "L2 chatgpt-codex: the browser sign-in asks for the Codex client on a registered port and stores the workspace" {
    const a = testing.allocator;
    var root: Root = .{ .tmp = undefined };
    try root.init();
    defer root.deinit();

    const id_token = try jwt(a, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"" ++ ACCOUNT ++ "\",\"chatgpt_plan_type\":\"plus\"},\"email\":\"someone@example.com\"}");
    defer a.free(id_token);
    const access = try accessToken(a, ACCOUNT);
    defer a.free(access);
    const token_body = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt-codex-1\",\"id_token\":\"{s}\",\"token_type\":\"Bearer\",\"expires_in\":864000}}", .{ access, id_token });
    defer a.free(token_body);
    var token_server = try harness.MockServer.start(token_body, 0);
    defer token_server.stop();
    const token_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth/token", .{token_server.port});
    defer a.free(token_url);

    // The first registered port is held by someone else; the second is free.
    const held = try net.listenLoopback(0, 1);
    defer net.closeSocket(held.sock);
    const second = try freePort();

    var profile = codex.PROFILE;
    profile.oauth_token_url = token_url;
    profile.oauth_authorize_url = "http://127.0.0.1:1/oauth/authorize";
    const flow = try provider_login.prepareFlow(&profile, .{
        .open_browser = false,
        .state_root = root.path,
        .callback_ports = &.{ held.port, second },
    }, null);
    try testing.expect(flow == .oauth);
    try testing.expectEqual(provider_login.ClientIdSource.declared, flow.oauth.client_id_source);

    var instructions = Instructions{ .allocator = a };
    defer instructions.deinit();
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var run = FlowRun{ .flow = flow, .allocator = a, .io = io_runtime.io(), .notify = instructions.notify() };
    var thread = try std.Thread.spawn(.{}, FlowRun.run, .{&run});
    instructions.waitForUrl() catch |err| {
        thread.detach();
        return err;
    };
    const said = try instructions.snapshot(a);
    defer a.free(said);

    // Said first, before the URL: the sign-in is unofficial.
    try testing.expect(std.mem.startsWith(u8, said, "ChatGPT (Codex): This sign-in is unofficial and may stop working at any time.\n"));
    // The second registered port, since the first was taken.
    try testing.expectEqual(second, try callbackPortIn(said));
    for ([_][]const u8{
        "http://127.0.0.1:1/oauth/authorize?response_type=code",
        "client_id=" ++ CLIENT,
        "scope=openid%20profile%20email%20offline_access",
        "code_challenge_method=S256",
        "&id_token_add_organizations=true",
        "&codex_cli_simplified_flow=true",
        "&originator=metacodes",
    }) |part| try expectContains(said, part);
    try expectContains(said, try std.fmt.allocPrint(fmtArena(), "Waiting for the login callback on http://localhost:{d}.", .{second}));

    const query = try std.fmt.allocPrint(a, "code=codex-code-1&state={s}", .{try stateIn(said)});
    defer a.free(query);
    try deliverCallback(second, query);
    thread.join();
    const outcome = try (run.result orelse return error.FlowDidNotRun);
    try testing.expectEqualStrings("chatgpt-codex", outcome.provider_id.slice());

    // The grant: the Codex client, the code, the same redirect, PKCE.
    const exchanged = token_server.lastRequest() orelse return error.NoTokenRequest;
    const body = exchanged.body();
    try expectContains(body, "grant_type=authorization_code");
    try expectContains(body, "client_id=" ++ CLIENT);
    try expectContains(body, "code=codex-code-1");
    try expectContains(body, try std.fmt.allocPrint(fmtArena(), "redirect_uri=http%3A%2F%2Flocalhost%3A{d}%2Fauth%2Fcallback", .{second}));
    try expectContains(body, "code_verifier=");
    // Whatever held the first port heard nothing.
    try testing.expect(!net.pollReadable(held.sock, 0));

    // Stored: the tokens, the client the refresh must present, and the
    // workspace from the ID token. Not the ID token, which names the user.
    const stored = try root.read(a, "oauth/chatgpt-codex.json");
    defer a.free(stored);
    try expectContains(stored, "\"account_id\":\"" ++ ACCOUNT ++ "\"");
    try expectContains(stored, "\"client_id\":\"" ++ CLIENT ++ "\"");
    try expectContains(stored, "\"refresh_token\":\"rt-codex-1\"");
    try expectAbsent(stored, "id_token");
    try expectAbsent(stored, "someone@example.com");
}

var fmt_arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// Scratch for formatted expectations and mock URLs; released with the
/// process.
fn fmtArena() std.mem.Allocator {
    return fmt_arena_state.allocator();
}

test "L2 chatgpt-codex: with every registered port held the sign-in stops, names them, and sends nothing to their holders" {
    const a = testing.allocator;
    var root: Root = .{ .tmp = undefined };
    try root.init();
    defer root.deinit();
    var token_server = try harness.MockServer.start("{}", 0);
    defer token_server.stop();

    const first = try net.listenLoopback(0, 1);
    defer net.closeSocket(first.sock);
    const second = try net.listenLoopback(0, 1);
    defer net.closeSocket(second.sock);

    // A sign-in that took another port would wait for a browser forever;
    // the watchdog ends that wait, so a regression fails here, not hangs.
    var watchdog = Watchdog{};
    const watchdog_thread = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});
    defer {
        watchdog.done.store(true, .release);
        watchdog_thread.join();
    }
    var profile = codex.PROFILE;
    profile.oauth_token_url = try std.fmt.allocPrint(fmtArena(), "http://127.0.0.1:{d}/oauth/token", .{token_server.port});
    const flow = try provider_login.prepareFlow(&profile, .{
        .open_browser = false,
        .state_root = root.path,
        .callback_ports = &.{ first.port, second.port },
        .abort_signal = &watchdog.signal,
    }, null);
    var instructions = Instructions{ .allocator = a };
    defer instructions.deinit();
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    try testing.expectError(error.OAuthCallbackPortsInUse, flow.run(a, io_runtime.io(), instructions.notify(), null));

    const said = try instructions.snapshot(a);
    defer a.free(said);
    try expectContains(said, try std.fmt.allocPrint(fmtArena(), "can only receive its callback on port {d} and {d}, and every one of them is in use.", .{ first.port, second.port }));
    try expectContains(said, "Finish or close it, then try again.");
    // No URL to open, no request, nothing knocked on the holders' doors.
    try expectAbsent(said, "&state=");
    try testing.expectEqual(@as(usize, 0), token_server.requestCount());
    try testing.expect(!net.pollReadable(first.sock, 0));
    try testing.expect(!net.pollReadable(second.sock, 0));
    try testing.expect(!root.exists("oauth/chatgpt-codex.json"));
}

test "L2 chatgpt-codex: a refusal with the right state ends the wait and says why; one with the wrong state does not" {
    const a = testing.allocator;
    var root: Root = .{ .tmp = undefined };
    try root.init();
    defer root.deinit();
    var token_server = try harness.MockServer.start("{}", 0);
    defer token_server.stop();
    const port = try freePort();

    var profile = codex.PROFILE;
    profile.oauth_token_url = try std.fmt.allocPrint(fmtArena(), "http://127.0.0.1:{d}/oauth/token", .{token_server.port});
    const flow = try provider_login.prepareFlow(&profile, .{
        .open_browser = false,
        .state_root = root.path,
        .callback_ports = &.{port},
    }, null);
    var instructions = Instructions{ .allocator = a };
    defer instructions.deinit();
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var run = FlowRun{ .flow = flow, .allocator = a, .io = io_runtime.io(), .notify = instructions.notify() };
    var thread = try std.Thread.spawn(.{}, FlowRun.run, .{&run});
    instructions.waitForUrl() catch |err| {
        thread.detach();
        return err;
    };
    const said = try instructions.snapshot(a);
    defer a.free(said);

    // A stale tab's refusal is not this sign-in's answer.
    try deliverCallback(port, "error=access_denied&error_description=stale&state=not-the-state");
    try testing.expect(run.result == null);
    const refusal = try std.fmt.allocPrint(a, "error=access_denied&error_description=missing_codex_entitlement%3A%20workspace&state={s}", .{try stateIn(said)});
    defer a.free(refusal);
    try deliverCallback(port, refusal);
    thread.join();
    try testing.expectError(error.OAuthAccessDenied, run.result orelse return error.FlowDidNotRun);

    const after = try instructions.snapshot(a);
    defer a.free(after);
    try expectContains(after, "The sign-in was refused: access_denied (missing_codex_entitlement: workspace).");
    try expectAbsent(after, "stale");
    try testing.expectEqual(@as(usize, 0), token_server.requestCount());
    try testing.expect(!root.exists("oauth/chatgpt-codex.json"));
}

// ── the stored sign-in ───────────────────────────────────────────────────────

fn writeStoredSignIn(root: *Root, a: std.mem.Allocator, access: []const u8, expires_at: i64) !void {
    try root.tmp.dir.createDirPath(testing.io, "oauth");
    const stored = try std.fmt.allocPrint(a, "{{\"schema_version\":1,\"access_token\":\"{s}\",\"refresh_token\":\"rt-old\",\"token_type\":\"Bearer\",\"expires_at\":{d},\"account_id\":\"" ++ ACCOUNT ++ "\",\"client_id\":\"" ++ CLIENT ++ "\"}}", .{ access, expires_at });
    defer a.free(stored);
    try root.tmp.dir.writeFile(testing.io, .{ .sub_path = "oauth/chatgpt-codex.json", .data = stored });
}

test "L2 chatgpt-codex: a start refreshes an expired sign-in with the recorded client and keeps the workspace" {
    const a = testing.allocator;
    var root: Root = .{ .tmp = undefined };
    try root.init();
    defer root.deinit();
    const stale = try accessToken(a, ACCOUNT);
    defer a.free(stale);
    try writeStoredSignIn(&root, a, stale, 1);

    const fresh = try jwt(a, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"" ++ ACCOUNT ++ "\"},\"fresh\":true}");
    defer a.free(fresh);
    // The refresh answer names no ID token: the stored workspace stays.
    const refreshed = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt-new\",\"expires_in\":864000}}", .{fresh});
    defer a.free(refreshed);
    var token_server = try harness.MockServer.start(refreshed, 0);
    defer token_server.stop();
    var profile = codex.PROFILE;
    profile.oauth_token_url = try std.fmt.allocPrint(fmtArena(), "http://127.0.0.1:{d}/oauth/token", .{token_server.port});

    const token = (try cc.providerSignInToken(a, root.path, &profile)) orelse return error.NoSignIn;
    defer {
        std.crypto.secureZero(u8, token);
        a.free(token);
    }
    try testing.expectEqualStrings(fresh, token);
    const exchanged = token_server.lastRequest() orelse return error.NoRefreshRequest;
    try testing.expectEqualStrings("grant_type=refresh_token&client_id=" ++ CLIENT ++ "&refresh_token=rt-old", exchanged.body());

    const stored = try root.read(a, "oauth/chatgpt-codex.json");
    defer a.free(stored);
    try expectContains(stored, "\"refresh_token\":\"rt-new\"");
    try expectContains(stored, "\"account_id\":\"" ++ ACCOUNT ++ "\"");
    try expectContains(stored, "\"client_id\":\"" ++ CLIENT ++ "\"");

    // A live sign-in is used as it is: no second request.
    const again = (try cc.providerSignInToken(a, root.path, &profile)) orelse return error.NoSignIn;
    defer {
        std.crypto.secureZero(u8, again);
        a.free(again);
    }
    try testing.expectEqualStrings(fresh, again);
    try testing.expectEqual(@as(usize, 1), token_server.requestCount());
}

test "L2 chatgpt-codex: signing out revokes the refresh token at the profile's endpoint as JSON, then deletes the sign-in" {
    const a = testing.allocator;
    var root: Root = .{ .tmp = undefined };
    try root.init();
    defer root.deinit();
    const access = try accessToken(a, ACCOUNT);
    defer a.free(access);
    try writeStoredSignIn(&root, a, access, cc.util_time.nowUnix() + 86_400);

    var revoke_server = try harness.MockServer.startCassette(&.{""}, 0);
    defer revoke_server.stop();
    var profile = codex.PROFILE;
    profile.oauth_revocation = .{
        .url = try std.fmt.allocPrint(fmtArena(), "http://127.0.0.1:{d}/oauth/revoke", .{revoke_server.port}),
        .body = codex.PROFILE.oauth_revocation.?.body,
    };
    try testing.expectEqual(@as(u8, 0), cc.logoutProviderProfile(a, root.path, &profile, 10_000));

    try testing.expect(!root.exists("oauth/chatgpt-codex.json"));
    try testing.expectEqual(@as(usize, 1), revoke_server.requestCount());
    const revoke = revoke_server.lastRequest() orelse return error.NoRevokeRequest;
    try testing.expect(std.mem.startsWith(u8, requestLine(revoke), "POST /oauth/revoke "));
    try testing.expectEqualStrings("application/json", headerValue(revoke, "content-type").?);
    try testing.expectEqualStrings("{\"token\":\"rt-old\",\"token_type_hint\":\"refresh_token\",\"client_id\":\"" ++ CLIENT ++ "\"}", revoke.body());
    // The access token goes nowhere at sign-out.
    try expectAbsent(revoke.raw, access);

    // Nothing stored any more: nothing is sent.
    try testing.expectEqual(@as(u8, 0), cc.logoutProviderProfile(a, root.path, &profile, 10_000));
    try testing.expectEqual(@as(usize, 1), revoke_server.requestCount());
}

test "L2 chatgpt-codex: only this route's requests carry the Codex body fields" {
    const a = testing.allocator;
    const messages = [_]cc.types_mod.ApiMessage{.{ .role = .user, .content = &.{.{ .text = "hi" }} }};
    const dialect = cc.api_dialect.dialectFor(.openai, "gpt-6.1-sol");
    var report = cc.json_mod.SerializationReport{};
    defer report.deinit(a);
    const codex_body = try cc.api_openai.serializeOpenAIResponsesRequestProfiled(a, "gpt-6.1-sol", &messages, null, null, .{}, dialect, .chatgpt_codex, &report);
    defer a.free(codex_body);
    try expectContains(codex_body, "\"stream\":true,\"store\":false,\"include\":[\"reasoning.encrypted_content\"]");
    // No system prompt, yet `instructions` is there.
    try expectContains(codex_body, "\"instructions\":\"\"");
    try expectAbsent(codex_body, "max_output_tokens");

    // The same model on an ordinary Responses route gets none of it.
    const plain_body = try cc.api_openai.serializeOpenAIResponsesRequestProfiled(a, "gpt-6.1-sol", &messages, null, null, .{}, dialect, null, &report);
    defer a.free(plain_body);
    try expectAbsent(plain_body, "\"include\"");
    try expectAbsent(plain_body, "\"instructions\"");
    // And the built-in OpenAI profile's routes name no request profile.
    for (cc.provider_registry.openai.PROFILE.channels) |channel| {
        for (channel.routes) |route| try testing.expect(route.request_profile == null);
    }
}

// ── through the real CLI ─────────────────────────────────────────────────────

/// Sets (or unsets, with null) one variable and puts the old value back.
const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            testing.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
    }
};

const cleared = [_][*:0]const u8{
    "METASK_API_KEY",      "OPENAI_API_KEY",     "METACODES_PROVIDER",        "METACODES_MODEL",
    "METACODES_BASE_URL",  "METASK_GATEWAY_URL", "METACODES_CONFIG_FILE",     "METACODES_AUTH_FILE",
    "METACODES_OAUTH_DIR", "METASK_SITE_URL",    "METACODES_OPENAI_PROTOCOL",
};

/// A state root, a working directory and a home for the real CLI.
const Case = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    state: []const u8,
    work: []const u8,
    home: []const u8,
    guards: [cleared.len + 6]EnvGuard = undefined,
    count: usize = 0,

    fn init(self: *Case) !void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.count = 0;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try a.dupe(u8, root_buf[0..try self.tmp.dir.realPath(testing.io, &root_buf)]);
        for ([_][]const u8{ "state", "state/oauth", "work", "home" }) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        self.state = try std.fs.path.join(a, &.{ root, "state" });
        self.work = try std.fs.path.join(a, &.{ root, "work" });
        self.home = try std.fs.path.join(a, &.{ root, "home" });
        const a2 = self.arena();
        for (cleared) |name| try self.guard(name, null);
        try self.guard("HOME", (try a2.dupeZ(u8, self.home)).ptr);
        try self.guard("METACODES_HOME", (try a2.dupeZ(u8, self.state)).ptr);
        try self.guard("METACODES_NO_PROBE", "1");
        try self.guard("METACODES_KG_AUTOSTART", "0");
        try self.guard("METACODES_JEV_URL", "off");
    }

    fn guard(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        self.guards[self.count] = try EnvGuard.set(name, value);
        self.count += 1;
    }

    fn deinit(self: *Case) void {
        while (self.count > 0) {
            self.count -= 1;
            self.guards[self.count].restore();
        }
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn storeSignIn(self: *Case, access: []const u8) !void {
        const stored = try std.fmt.allocPrint(self.arena(), "{{\"schema_version\":1,\"access_token\":\"{s}\",\"refresh_token\":\"rt-cli\",\"token_type\":\"Bearer\",\"expires_at\":{d},\"account_id\":\"" ++ ACCOUNT ++ "\",\"client_id\":\"" ++ CLIENT ++ "\"}}", .{ access, cc.util_time.nowUnix() + 86_400 });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "state/oauth/chatgpt-codex.json", .data = stored });
    }

    /// `config.json`'s `global_selection` on chatgpt-codex's `model` (what
    /// `/model`'s "every future session" commits).
    fn storeDefault(self: *Case, model: []const u8) !void {
        var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
        defer io_runtime.deinit();
        var config = cc.parseArgsForTest(&.{"metacodes"}, self.arena());
        config.state_root = self.state;
        const app = try cc.app_module.App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
        defer app.deinit();
        const host = try app.providerHost();
        const offer = for (host.kernel.catalogSnapshot().items()) |*candidate| {
            if (candidate.provider_id.eqlText("chatgpt-codex") and std.mem.eql(u8, candidate.request_model_id, model)) break candidate;
        } else return error.OfferMissing;
        var store = try cc.provider_config_store.Store.initHome(self.arena(), self.state);
        defer store.deinit();
        _ = try cc.provider_config_store.setGlobalSelection(&store, cc.provider_selection.RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .global), null, null);
    }
};

const Run = struct {
    exit_code: i32,
    stderr: []const u8,
};

fn cliPath(case: *Case) !?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return null;
    return try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), case.arena());
}

fn runCli(case: *Case, cli: []const u8, env: []const []const u8, args: []const []const u8) !Run {
    const a = case.arena();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    const base = [_][]const u8{
        "/usr/bin/env",
        try std.fmt.allocPrint(a, "HOME={s}", .{case.home}),
        "PATH=/usr/bin:/bin",
        "METACODES_KG_AUTOSTART=0",
        "METACODES_JEV_URL=off",
        "METACODES_NO_PROBE=1",
    };
    for (base) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (env) |assignment| try argv.append(a, (try a.dupeZ(u8, assignment)).ptr);
    for ([_][]const u8{ cli, "--state-dir", case.state }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 60_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, case.work);
    return .{ .exit_code = out.exit_code, .stderr = out.stderr };
}

fn backendUrl(a: std.mem.Allocator, server: *harness.MockServer) ![]const u8 {
    return std.fmt.allocPrint(a, "METACODES_BASE_URL=http://127.0.0.1:{d}/backend-api/codex", .{server.port});
}

/// `name` on `captured` is `expected`; a missing one is reported, not a panic
/// that would end every later test with it.
fn expectHeader(captured: harness.CapturedRequest, name: []const u8, expected: []const u8) !void {
    const value = headerValue(captured, name) orelse {
        std.debug.print("header `{s}` missing from:\n{s}\n", .{ name, captured.raw });
        return error.HeaderMissing;
    };
    try testing.expectEqualStrings(expected, value);
}

fn expectField(captured: harness.CapturedRequest, key: []const u8, expected: []const u8) !void {
    const value = captured.jsonField(key) orelse {
        std.debug.print("body field `{s}` missing from:\n{s}\n", .{ key, captured.body() });
        return error.FieldMissing;
    };
    try testing.expectEqualStrings(expected, value);
}

/// The Codex request profile on one captured request.
fn expectCodexRequest(captured: harness.CapturedRequest, access: []const u8) !void {
    try testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /backend-api/codex/responses "));
    try expectHeader(captured, "authorization", try std.fmt.allocPrint(fmtArena(), "Bearer {s}", .{access}));
    try expectHeader(captured, "chatgpt-account-id", ACCOUNT);
    try expectHeader(captured, "originator", "metacodes");
    try expectHeader(captured, "accept", "text/event-stream");
    // The client names itself, as every request does (stage 1).
    try expectHeader(captured, "user-agent", cc.api_http_connection.user_agent);
    try expectField(captured, "store", "false");
    try expectField(captured, "stream", "true");
    try expectField(captured, "include", "[\"reasoning.encrypted_content\"]");
    try testing.expect(captured.jsonField("instructions") != null);
    try testing.expect(captured.jsonField("max_output_tokens") == null);
}

test "L2 chatgpt-codex: -p signs in with the stored sign-in and sends the Codex request profile" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    const a = case.arena();
    const access = try accessToken(a, ACCOUNT);
    try case.storeSignIn(access);
    var backend = try harness.MockServer.startCassette(&.{RESPONSES_TEXT_SSE}, 0);
    defer backend.stop();

    const out = try runCli(&case, cli, &.{try backendUrl(a, backend)}, &.{ "--provider", "chatgpt-codex", "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    const turn = backend.lastRequest() orelse return error.NoRequestCaptured;
    try expectCodexRequest(turn, access);
    try testing.expectEqualStrings("\"gpt-6.1-sol\"", turn.jsonField("model").?);
    try expectAbsent(out.stderr, access);
    try expectAbsent(out.stderr, "rt-cli");
    // A ChatGPT plan with nobody at the keyboard says so, once.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.stderr, "warning: ChatGPT (Codex) is a subscription plan for interactive use"));
}

test "L2 chatgpt-codex: a /model pick binds the sign-in with the Codex request profile, and the next start finds both" {
    // In process, sending nothing: a stored default's route ignores
    // METACODES_BASE_URL, so through the CLI its request would reach the real
    // backend. The start's credential resolution is the one `-p` and the
    // stored-default check share (`resolveProviderScopedCredential`).
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    const access = try accessToken(a, ACCOUNT);
    try case.storeSignIn(access);
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    var config = cc.parseArgsForTest(&.{"metacodes"}, a);
    config.state_root = case.state;
    const app = try cc.app_module.App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
    defer app.deinit();

    // `/model` → ChatGPT (Codex) → "every future session".
    const host = try app.providerHost();
    const offer = for (host.kernel.catalogSnapshot().items()) |*candidate| {
        if (candidate.provider_id.eqlText("chatgpt-codex") and std.mem.eql(u8, candidate.request_model_id, "gpt-6-luna")) break candidate;
    } else return error.OfferMissing;
    try testing.expectEqual(cc.provider_profile.RequestProfile.chatgpt_codex, offer.dialect.request_profile.?);
    const outcome = try app.commitModelSelection(.{
        .offer_id = offer.offer_id,
        .offer_revision = offer.offer_revision,
        .controls = .{},
        .scope = .global,
    });
    try testing.expect(outcome == .committed);
    try testing.expect(app.unbound() == null);
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("gpt-6-luna · signed in", app.bannerModelLine(&line_buf));
    try testing.expectEqualStrings(access, app.api_key);
    try testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", app.config.base_url.?);
    // The client that sends the turn carries the route's request profile.
    try testing.expectEqual(cc.provider_profile.RequestProfile.chatgpt_codex, app.openai_client.?.declared_dialect.request_profile.?);

    // The next plain start: the default stored in this state root resolves
    // to it, and its credential is the sign-in. Read through the store of
    // `case.state` itself: `applyPersistedGlobalSelection` reads the
    // process-wide state root, which another test in the same process may
    // have fixed first (doc: gate-pr local gotchas, unbound_session_test).
    var store = try cc.provider_config_store.Store.initHome(a, case.state);
    defer store.deinit();
    var document = try store.load();
    defer document.deinit();
    const stored = document.global_selection orelse return error.NoDefaultStored;
    const outcome_next = try cc.provider_startup.resolveSelection(a, &host.registry, stored);
    var route = switch (outcome_next) {
        .route => |value| value,
        .failure => return error.StoredDefaultDoesNotResolve,
    };
    defer route.deinit();
    try testing.expectEqualStrings("chatgpt-codex", route.provider_id.slice());
    try testing.expectEqualStrings("gpt-6-luna", route.request_model_id);
    try testing.expectEqual(cc.provider_profile.RequestProfile.chatgpt_codex, route.dialect.request_profile.?);
    var next = cc.parseArgsForTest(&.{"metacodes"}, a);
    next.state_root = case.state;
    const scoped = try cc.resolveProviderScopedCredential(a, next, "chatgpt-codex");
    try testing.expectEqualStrings(access, scoped.secret);
    try testing.expectEqual(cc.app_route_state.CredentialOrigin.sign_in, scoped.origin);

    // `/logout chatgpt-codex` on this session: revoked (at a mock standing in
    // for auth.openai.com), deleted, and the session it ran is left with no
    // credential. The registry's own copy of the profile is pointed at the
    // mock, so nothing reaches OpenAI.
    var revoke_server = try harness.MockServer.startCassette(&.{""}, 0);
    defer revoke_server.stop();
    for (host.registry.profiles.items) |*profile| {
        if (!profile.id.eqlText("chatgpt-codex")) continue;
        profile.oauth_revocation = .{
            .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth/revoke", .{revoke_server.port}),
            .body = .json,
        };
    }
    const forgotten = try app.forgetProviderKey(cc.provider_ids.Slug.lit("chatgpt-codex"));
    try testing.expect(!forgotten.removed);
    try testing.expect(forgotten.sign_in.removed);
    try testing.expectEqual(cc.api_oauth_revoke.RevokeOutcome.revoked, forgotten.sign_in.revoke);
    try testing.expect(forgotten.unbound);
    try testing.expect(app.unbound() != null);
    try testing.expectEqual(@as(usize, 1), revoke_server.requestCount());
    try expectContains(revoke_server.lastRequest().?.body(), "\"token\":\"rt-cli\"");
    try testing.expect(std.mem.eql(u8, app.api_key, ""));
    try testing.expectError(error.FileNotFound, case.tmp.dir.access(testing.io, "state/oauth/chatgpt-codex.json", .{}));
}

test "L2 chatgpt-codex: a used-up plan is asked once and says when it resets" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    const a = case.arena();
    try case.storeSignIn(try accessToken(a, ACCOUNT));
    // Two and a half hours from now.
    const body = try std.fmt.allocPrint(a, "{{\"error\":{{\"type\":\"usage_limit_reached\",\"message\":\"The usage limit has been reached\",\"plan_type\":\"plus\",\"resets_at\":{d}}}}}", .{cc.util_time.nowUnix() + 9_000});
    var backend = try harness.MockServer.startRepeatingStatus(body, "HTTP/1.1 429 Too Many Requests", "");
    defer backend.stop();

    const out = try runCli(&case, cli, &.{try backendUrl(a, backend)}, &.{ "--provider", "chatgpt-codex", "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expect(out.exit_code != 0);
    // Not retried: waiting seconds does not reopen a plan's window.
    try testing.expectEqual(@as(usize, 1), backend.requestCount());
    try expectContains(out.stderr, "ChatGPT usage limit: the plan's Codex quota is used up; it resets at ");
    try expectContains(out.stderr, "ChatGPT (Codex) reports the plan's usage limit is reached; it resets in about 2 h");
    try expectContains(out.stderr, "Wait until then, or switch provider: --provider");
}

test "L2 chatgpt-codex: a plan without Codex is asked once and says so" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    const a = case.arena();
    try case.storeSignIn(try accessToken(a, ACCOUNT));
    var backend = try harness.MockServer.startRepeatingStatus("{\"error\":{\"type\":\"usage_not_included\",\"message\":\"Codex is not included in your plan\"}}", "HTTP/1.1 429 Too Many Requests", "");
    defer backend.stop();

    const out = try runCli(&case, cli, &.{try backendUrl(a, backend)}, &.{ "--provider", "chatgpt-codex", "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expect(out.exit_code != 0);
    try testing.expectEqual(@as(usize, 1), backend.requestCount());
    try expectContains(out.stderr, "ChatGPT plan: this ChatGPT plan does not include Codex");
    try expectContains(out.stderr, "ChatGPT (Codex) reports that the plan does not include it. Switch provider: --provider");
}

test "L2 chatgpt-codex: without a sign-in, -p says how to sign in and offers no key" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    const out = try runCli(&case, cli, &.{}, &.{ "--provider", "chatgpt-codex", "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expect(out.exit_code != 0);
    try expectContains(out.stderr, "Authentication required for provider 'chatgpt-codex'.");
    try expectContains(out.stderr, "login --provider chatgpt-codex   (signs in in the browser, then stores the sign-in)");
    try expectAbsent(out.stderr, "--api-key <key>");

    // And signing out of nothing says so, sending nothing anywhere.
    const logout = try runCli(&case, cli, &.{}, &.{ "logout", "--provider", "chatgpt-codex" });
    try testing.expectEqual(@as(i32, 0), logout.exit_code);
    try expectContains(logout.stderr, "No sign-in is stored for ChatGPT (Codex).");
}
