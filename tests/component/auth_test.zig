//! L2 component tests for Metask auth resolution.
//!
//! These tests prove declaration -> resolver -> Client request header wiring.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

// 可移植 env 写入走 platform.paths(POSIX setenv / Windows _putenv_s)。
// 保留 POSIX 调用形状的薄壳,免改下面二十多个调用点。
const ppaths = @import("platform").paths;
fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int {
    _ = overwrite;
    ppaths.setEnv(name, value);
    return 0;
}
fn unsetenv(name: [*:0]const u8) c_int {
    ppaths.unsetEnv(name);
    return 0;
}

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

test "L2 auth: ordinary environment credential remains compatible with process teammates" {
    const a = std.testing.allocator;
    const auth_path = "/tmp/cc-zig-auth-l2-runtime-scrub-missing.json";
    const secret = "runtime-env-secret-l2";
    _ = setenv(cc.core_auth.AUTH_FILE_ENV, auth_path, 1);
    _ = setenv(cc.core_auth.METASK_API_KEY_ENV, secret, 1);
    defer _ = unsetenv(cc.core_auth.AUTH_FILE_ENV);
    defer _ = unsetenv(cc.core_auth.METASK_API_KEY_ENV);

    var resolved = try cc.core_auth.resolveRuntimeCredential(a, null, .api_key_first);
    defer resolved.deinit(a);
    try std.testing.expectEqual(cc.core_auth.CredentialSource.env_api_key, resolved.source);
    try std.testing.expectEqualStrings(secret, resolved.bearer_token);
    const inherited = std.c.getenv(cc.core_auth.METASK_API_KEY_ENV) orelse
        return error.EnvironmentCredentialUnexpectedlyScrubbed;
    try std.testing.expectEqualStrings(secret, std.mem.span(inherited));

    // The owned token still authenticates a real provider request after the
    // environment copy has gone away.
    var srv = try harness.MockServer.start(OK_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        a,
        io_runtime.io(),
        resolved.bearer_token,
        "claude-3-5-haiku-20241022",
        url,
    );
    defer client.deinit();
    var resp = try client.sendMessageStream(&.{}, null, null);
    try drain(&resp);
    resp.deinit();
    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(rawHasAuth(cap.raw, secret));
}

test "L2 auth: inherited credential FD authenticates without secret in initial environment" {
    const a = std.testing.allocator;
    const pfs = @import("platform").fs;
    const ppaths_local = @import("platform").paths;
    const secret = "runtime-fd-secret-l2";
    const missing_auth = "/tmp/cc-zig-auth-l2-fd-missing.json";
    _ = setenv(cc.core_auth.AUTH_FILE_ENV, missing_auth, 1);
    defer _ = unsetenv(cc.core_auth.AUTH_FILE_ENV);
    const path = try std.fmt.allocPrint(a, "{s}/metacodes-auth-fd-l2-{d}", .{
        ppaths_local.tempDir(),
        @import("platform").process.currentPid(),
    });
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    defer _ = std.c.unlink(path_z.ptr);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd < 0) return error.CredentialTestFileOpenFailed;
    errdefer pfs.close(fd);
    try std.testing.expectEqual(@as(isize, secret.len), pfs.write(fd, secret));
    try std.testing.expectEqual(@as(i64, 0), pfs.lseek(fd, 0, .set));

    var fd_buf: [32]u8 = undefined;
    const fd_text = try std.fmt.bufPrintZ(&fd_buf, "{d}", .{fd});
    _ = setenv(cc.core_auth.RUNTIME_API_KEY_FD_ENV, fd_text.ptr, 1);
    _ = setenv(cc.core_auth.METASK_API_KEY_ENV, "ambient-key-must-be-scrubbed", 1);
    defer _ = unsetenv(cc.core_auth.RUNTIME_API_KEY_FD_ENV);
    defer _ = unsetenv(cc.core_auth.METASK_API_KEY_ENV);

    // The inherited FD is explicit runtime authority and must win even when
    // the general stored-credential policy says oauth_first.
    var resolved = try cc.core_auth.resolveRuntimeCredential(a, null, .oauth_first);
    defer resolved.deinit(a);
    try std.testing.expectEqual(cc.core_auth.CredentialSource.fd_api_key, resolved.source);
    try std.testing.expectEqualStrings(secret, resolved.bearer_token);
    try std.testing.expect(std.c.getenv(cc.core_auth.RUNTIME_API_KEY_FD_ENV) == null);
    try std.testing.expect(std.c.getenv(cc.core_auth.METASK_API_KEY_ENV) == null);

    var srv = try harness.MockServer.start(OK_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        a,
        io_runtime.io(),
        resolved.bearer_token,
        "claude-3-5-haiku-20241022",
        url,
    );
    defer client.deinit();
    var resp = try client.sendMessageStream(&.{}, null, null);
    try drain(&resp);
    resp.deinit();
    try std.testing.expect(rawHasAuth((srv.lastRequest() orelse return error.NoRequestCaptured).raw, secret));
}

test "L2 auth: oversized runtime credential fails closed and closes inherited FD" {
    const a = std.testing.allocator;
    const pfs = @import("platform").fs;
    const ppaths_local = @import("platform").paths;
    const path = try std.fmt.allocPrint(a, "{s}/metacodes-auth-fd-oversize-{d}", .{
        ppaths_local.tempDir(),
        @import("platform").process.currentPid(),
    });
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    defer _ = std.c.unlink(path_z.ptr);

    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd < 0) return error.CredentialTestFileOpenFailed;
    var test_owns_fd = true;
    defer if (test_owns_fd) pfs.close(fd);
    const payload = try a.alloc(u8, 16 * 1024 + 1);
    defer a.free(payload);
    @memset(payload, 'x');
    try std.testing.expectEqual(@as(isize, @intCast(payload.len)), pfs.write(fd, payload));
    try std.testing.expectEqual(@as(i64, 0), pfs.lseek(fd, 0, .set));

    var fd_buf: [32]u8 = undefined;
    const fd_text = try std.fmt.bufPrintZ(&fd_buf, "{d}", .{fd});
    _ = setenv(cc.core_auth.RUNTIME_API_KEY_FD_ENV, fd_text.ptr, 1);
    _ = unsetenv(cc.core_auth.METASK_API_KEY_ENV);
    defer _ = unsetenv(cc.core_auth.RUNTIME_API_KEY_FD_ENV);
    test_owns_fd = false; // resolveRuntimeCredential consumes the descriptor.

    try std.testing.expectError(
        error.CredentialFdTooLarge,
        cc.core_auth.resolveRuntimeCredential(a, null, .api_key_first),
    );
    try std.testing.expect(std.c.getenv(cc.core_auth.RUNTIME_API_KEY_FD_ENV) == null);
    try std.testing.expect(pfs.lseek(fd, 0, .set) < 0);
}

test "L2 auth: malformed runtime credential descriptor is scrubbed before failure" {
    _ = setenv(cc.core_auth.RUNTIME_API_KEY_FD_ENV, "not-a-descriptor", 1);
    defer _ = unsetenv(cc.core_auth.RUNTIME_API_KEY_FD_ENV);
    try std.testing.expectError(
        error.InvalidCredentialFd,
        cc.core_auth.resolveRuntimeCredential(std.testing.allocator, null, .api_key_first),
    );
    try std.testing.expect(std.c.getenv(cc.core_auth.RUNTIME_API_KEY_FD_ENV) == null);
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
    cc.util_time.sleepMs(150);
    var buf: [1024]u8 = undefined;
    const req = std.fmt.bufPrint(
        &buf,
        "GET /auth/callback?code={s}&state={s} HTTP/1.1\r\nHost: localhost:{d}\r\nConnection: close\r\n\r\n",
        .{ input.code, input.state, input.port },
    ) catch return;
    // fire-and-forget:响应内容不重要,只要请求送达回调 server。
    const resp = harness.clientRoundtrip(std.heap.page_allocator, input.port, req, null) catch return;
    std.heap.page_allocator.free(resp);
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
