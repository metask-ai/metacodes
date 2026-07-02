//! L2 component tests for Metask auth resolution.
//!
//! These tests prove declaration -> resolver -> Client request header wiring.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const OK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 auth: --auth-precedence parses into Config" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{
        "metacodes",
        "--auth-precedence",
        "oauth-first",
    };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expectEqual(cc.types_mod.AuthPrecedence.oauth_first, config.auth_precedence);
}

fn drain(resp: *cc.client_mod.StreamResponse) !void {
    while (true) {
        const maybe = try resp.next();
        const ev = maybe orelse break;
        switch (ev) {
            .text => |t| std.testing.allocator.free(t),
            else => {},
        }
        if (resp.done) break;
    }
}

fn rawHasAuth(raw: []const u8, expected: []const u8) bool {
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "authorization: Bearer {s}", .{expected}) catch return false;
    return std.mem.indexOf(u8, raw, needle) != null;
}

test "L2 auth: stored OAuth resolves into Anthropic Authorization header" {
    const a = std.testing.allocator;
    const auth_path = "/tmp/cc-zig-auth-l2-oauth.json";
    _ = unsetenv(cc.core_auth.METASK_API_KEY_ENV);
    _ = setenv(cc.core_auth.AUTH_FILE_ENV, auth_path, 1);
    defer _ = unsetenv(cc.core_auth.AUTH_FILE_ENV);
    defer {
        if (std.heap.c_allocator.dupeZ(u8, auth_path)) |z| {
            _ = std.c.unlink(z.ptr);
            std.heap.c_allocator.free(z);
        } else |_| {}
    }

    var creds = cc.core_auth.StoredCredentials{ .oauth = .{
        .access_token = try a.dupe(u8, "oauth-access-l2"),
        .refresh_token = try a.dupe(u8, "oauth-refresh-l2"),
        .expires_at = nowSeconds() + 3600,
    } };
    defer creds.deinit(a);
    try cc.core_auth.saveToPath(a, auth_path, creds);

    var resolved = try cc.core_auth.resolveCredential(a, null, .api_key_first);
    defer resolved.deinit(a);
    try std.testing.expectEqual(cc.core_auth.CredentialSource.stored_oauth, resolved.source);

    var srv = try harness.MockServer.start(OK_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), resolved.bearer_token, "claude-3-5-haiku-20241022", url);
    defer client.deinit();
    var resp = try client.sendMessageStream(&.{}, null, null);
    try drain(&resp);
    resp.deinit();

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(rawHasAuth(cap.raw, "oauth-access-l2"));
}

test "L2 auth: env API key wins by default, oauth-first is explicit override" {
    const a = std.testing.allocator;
    const auth_path = "/tmp/cc-zig-auth-l2-precedence.json";
    _ = setenv(cc.core_auth.AUTH_FILE_ENV, auth_path, 1);
    _ = setenv(cc.core_auth.METASK_API_KEY_ENV, "env-key-l2", 1);
    defer _ = unsetenv(cc.core_auth.AUTH_FILE_ENV);
    defer _ = unsetenv(cc.core_auth.METASK_API_KEY_ENV);
    defer {
        if (std.heap.c_allocator.dupeZ(u8, auth_path)) |z| {
            _ = std.c.unlink(z.ptr);
            std.heap.c_allocator.free(z);
        } else |_| {}
    }

    var creds = cc.core_auth.StoredCredentials{ .oauth = .{
        .access_token = try a.dupe(u8, "oauth-precedence-l2"),
        .refresh_token = try a.dupe(u8, "refresh-precedence-l2"),
        .expires_at = nowSeconds() + 3600,
    } };
    defer creds.deinit(a);
    try cc.core_auth.saveToPath(a, auth_path, creds);

    var default_resolved = try cc.core_auth.resolveCredential(a, null, .api_key_first);
    defer default_resolved.deinit(a);
    try std.testing.expectEqual(cc.core_auth.CredentialSource.env_api_key, default_resolved.source);
    try std.testing.expectEqualStrings("env-key-l2", default_resolved.bearer_token);

    var oauth_resolved = try cc.core_auth.resolveCredential(a, null, .oauth_first);
    defer oauth_resolved.deinit(a);
    try std.testing.expectEqual(cc.core_auth.CredentialSource.stored_oauth, oauth_resolved.source);
    try std.testing.expectEqualStrings("oauth-precedence-l2", oauth_resolved.bearer_token);
}

test "L2 auth: stored API key wins over OAuth unless oauth-first is explicit" {
    const a = std.testing.allocator;
    const auth_path = "/tmp/cc-zig-auth-l2-stored-api-key-precedence.json";
    _ = unsetenv(cc.core_auth.METASK_API_KEY_ENV);
    _ = setenv(cc.core_auth.AUTH_FILE_ENV, auth_path, 1);
    defer _ = unsetenv(cc.core_auth.AUTH_FILE_ENV);
    defer {
        if (std.heap.c_allocator.dupeZ(u8, auth_path)) |z| {
            _ = std.c.unlink(z.ptr);
            std.heap.c_allocator.free(z);
        } else |_| {}
    }

    var creds = cc.core_auth.StoredCredentials{
        .api_key = try a.dupe(u8, "stored-api-key-l2"),
        .oauth = .{
            .access_token = try a.dupe(u8, "oauth-stored-precedence-l2"),
            .refresh_token = try a.dupe(u8, "refresh-stored-precedence-l2"),
            .expires_at = nowSeconds() + 3600,
        },
    };
    defer creds.deinit(a);
    try cc.core_auth.saveToPath(a, auth_path, creds);

    var default_resolved = try cc.core_auth.resolveCredential(a, null, .api_key_first);
    defer default_resolved.deinit(a);
    try std.testing.expectEqual(cc.core_auth.CredentialSource.stored_api_key, default_resolved.source);
    try std.testing.expectEqualStrings("stored-api-key-l2", default_resolved.bearer_token);

    var oauth_resolved = try cc.core_auth.resolveCredential(a, null, .oauth_first);
    defer oauth_resolved.deinit(a);
    try std.testing.expectEqual(cc.core_auth.CredentialSource.stored_oauth, oauth_resolved.source);
    try std.testing.expectEqualStrings("oauth-stored-precedence-l2", oauth_resolved.bearer_token);
}

test "L2 auth: expiring OAuth refreshes before request and persists replacement" {
    const a = std.testing.allocator;
    const auth_path = "/tmp/cc-zig-auth-l2-refresh.json";
    _ = unsetenv(cc.core_auth.METASK_API_KEY_ENV);
    _ = setenv(cc.core_auth.AUTH_FILE_ENV, auth_path, 1);
    defer _ = unsetenv(cc.core_auth.AUTH_FILE_ENV);
    defer {
        if (std.heap.c_allocator.dupeZ(u8, auth_path)) |z| {
            _ = std.c.unlink(z.ptr);
            std.heap.c_allocator.free(z);
        } else |_| {}
    }

    var creds = cc.core_auth.StoredCredentials{ .oauth = .{
        .access_token = try a.dupe(u8, "old-access-l2"),
        .refresh_token = try a.dupe(u8, "old refresh/l2"),
        .expires_at = nowSeconds() + 30,
    } };
    defer creds.deinit(a);
    try cc.core_auth.saveToPath(a, auth_path, creds);

    var token_srv = try harness.MockServer.start(
        \\{"access_token":"new-access-l2","refresh_token":"new-refresh-l2","token_type":"Bearer","expires_in":3600,"account_id":"acct-refresh"}
    , 0);
    defer token_srv.stop();
    const token_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth/token", .{token_srv.port});
    defer a.free(token_url);
    const token_url_z = try a.dupeZ(u8, token_url);
    defer a.free(token_url_z);
    _ = setenv(cc.core_auth.OAUTH_TOKEN_URL_ENV, token_url_z.ptr, 1);
    defer _ = unsetenv(cc.core_auth.OAUTH_TOKEN_URL_ENV);

    var resolved = try cc.core_auth.resolveCredential(a, null, .oauth_first);
    defer resolved.deinit(a);
    try std.testing.expectEqual(cc.core_auth.CredentialSource.stored_oauth, resolved.source);
    try std.testing.expectEqualStrings("new-access-l2", resolved.bearer_token);

    const token_req = token_srv.lastRequest() orelse return error.NoRefreshRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, token_req.body(), "grant_type=refresh_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, token_req.body(), "client_id=metacode-cli") != null);
    try std.testing.expect(std.mem.indexOf(u8, token_req.body(), "refresh_token=old%20refresh%2Fl2") != null);

    var loaded = try cc.core_auth.loadFromPath(a, auth_path);
    defer loaded.deinit(a);
    try std.testing.expectEqualStrings("new-access-l2", loaded.oauth.?.access_token);
    try std.testing.expectEqualStrings("new-refresh-l2", loaded.oauth.?.refresh_token);

    var srv = try harness.MockServer.start(OK_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), resolved.bearer_token, "claude-3-5-haiku-20241022", url);
    defer client.deinit();
    var resp = try client.sendMessageStream(&.{}, null, null);
    try drain(&resp);
    resp.deinit();

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(rawHasAuth(cap.raw, "new-access-l2"));
}

test "L2 auth: invalid refresh grant surfaces login required without fallback" {
    const a = std.testing.allocator;
    const auth_path = "/tmp/cc-zig-auth-l2-invalid-grant.json";
    _ = setenv(cc.core_auth.AUTH_FILE_ENV, auth_path, 1);
    _ = setenv(cc.core_auth.METASK_API_KEY_ENV, "env-fallback-must-not-win", 1);
    defer _ = unsetenv(cc.core_auth.AUTH_FILE_ENV);
    defer _ = unsetenv(cc.core_auth.METASK_API_KEY_ENV);
    defer {
        if (std.heap.c_allocator.dupeZ(u8, auth_path)) |z| {
            _ = std.c.unlink(z.ptr);
            std.heap.c_allocator.free(z);
        } else |_| {}
    }

    var creds = cc.core_auth.StoredCredentials{ .oauth = .{
        .access_token = try a.dupe(u8, "expired-access-l2"),
        .refresh_token = try a.dupe(u8, "revoked-refresh-l2"),
        .expires_at = nowSeconds() - 1,
    } };
    defer creds.deinit(a);
    try cc.core_auth.saveToPath(a, auth_path, creds);

    var token_srv = try harness.MockServer.startWithStatus(
        \\{"error":"invalid_grant","error_description":"revoked"}
    , 0, "HTTP/1.1 400 Bad Request");
    defer token_srv.stop();
    const token_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth/token", .{token_srv.port});
    defer a.free(token_url);
    const token_url_z = try a.dupeZ(u8, token_url);
    defer a.free(token_url_z);
    _ = setenv(cc.core_auth.OAUTH_TOKEN_URL_ENV, token_url_z.ptr, 1);
    defer _ = unsetenv(cc.core_auth.OAUTH_TOKEN_URL_ENV);

    try std.testing.expectError(error.OAuthLoginRequired, cc.core_auth.resolveCredential(a, null, .oauth_first));
}

const CallbackInput = struct {
    port: u16,
    state: []const u8,
    code: []const u8,
};

fn sendCallback(input: CallbackInput) void {
    var req_ts = std.c.timespec{ .sec = 0, .nsec = 150 * 1000 * 1000 };
    _ = std.c.nanosleep(&req_ts, null);
    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return;
    defer _ = std.c.close(sock);
    var addr = std.c.sockaddr.in{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, input.port),
        .addr = 0x0100007f,
        .zero = [_]u8{0} ** 8,
    };
    if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return;
    var buf: [1024]u8 = undefined;
    const req = std.fmt.bufPrint(
        &buf,
        "GET /auth/callback?code={s}&state={s} HTTP/1.1\r\nHost: localhost:{d}\r\nConnection: close\r\n\r\n",
        .{ input.code, input.state, input.port },
    ) catch return;
    _ = std.c.write(sock, req.ptr, req.len);
    var tmp: [256]u8 = undefined;
    _ = std.c.read(sock, &tmp, tmp.len);
}

test "L2 auth: browser OAuth callback exchanges code for stored OAuth credentials" {
    const a = std.testing.allocator;
    const port: u16 = 19455;
    const forced_state = "state-l2-browser";
    const callback_code = "code-l2-browser";

    var token_srv = try harness.MockServer.start(
        \\{"access_token":"browser-access-l2","refresh_token":"browser-refresh-l2","token_type":"Bearer","expires_in":3600,"scope":"metask"}
    , 0);
    defer token_srv.stop();
    const token_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth/token", .{token_srv.port});
    defer a.free(token_url);
    const token_url_z = try a.dupeZ(u8, token_url);
    defer a.free(token_url_z);
    _ = setenv(cc.core_auth.OAUTH_TOKEN_URL_ENV, token_url_z.ptr, 1);
    defer _ = unsetenv(cc.core_auth.OAUTH_TOKEN_URL_ENV);
    _ = setenv(cc.core_auth.OAUTH_AUTHORIZE_URL_ENV, "http://127.0.0.1/authorize", 1);
    defer _ = unsetenv(cc.core_auth.OAUTH_AUTHORIZE_URL_ENV);

    const input = CallbackInput{ .port = port, .state = forced_state, .code = callback_code };
    const th = try std.Thread.spawn(.{}, sendCallback, .{input});
    var creds = try cc.core_auth.loginWithBrowser(a, .{
        .open_browser = false,
        .port = port,
        .force_state = forced_state,
    });
    th.join();
    defer creds.deinit(a);

    try std.testing.expect(creds.oauth != null);
    try std.testing.expectEqualStrings("browser-access-l2", creds.oauth.?.access_token);
    try std.testing.expectEqualStrings("browser-refresh-l2", creds.oauth.?.refresh_token);

    const token_req = token_srv.lastRequest() orelse return error.NoTokenExchangeCaptured;
    try std.testing.expect(std.mem.indexOf(u8, token_req.body(), "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, token_req.body(), "code=code-l2-browser") != null);
    try std.testing.expect(std.mem.indexOf(u8, token_req.body(), "redirect_uri=http%3A%2F%2Flocalhost%3A19455%2Fauth%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, token_req.body(), "code_verifier=") != null);
}

fn nowSeconds() i64 {
    return cc.util_time.nowUnix();
}
