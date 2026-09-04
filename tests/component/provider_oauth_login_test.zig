//! L2 component tests for interactive provider OAuth login (issue #33).
//!
//! The lifecycle after the first token already had coverage. What these prove
//! is the entry point: a real loopback redirect is served, a real
//! authorization-code grant is exchanged over HTTP, a real device-code grant
//! is polled through `authorization_pending`, and the result lands in the same
//! durable per-provider store the `--oauth-token-json` path writes — including
//! the OAuth client, so the refresh that follows presents the client the grant
//! was issued to.
//!
//! No paid call and no real provider: every endpoint is a local mock server.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const ppaths = @import("platform").paths;
const net = @import("platform").net;

const oauth_login = cc.api_oauth_login;
const provider_login = cc.api_provider_login;
const provider_oauth = cc.provider_oauth;

/// Collects what the flow tells the user. Load-bearing, not decoration: the
/// bound callback port is only discoverable from the URL the user is asked to
/// open, and a flow that printed nothing would be unusable.
const Instructions = struct {
    buffer: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    /// Publishes the buffer to the test thread. The flow runs on its own
    /// thread, so reading `buffer.items` on the strength of a plain length
    /// check would race an append that can reallocate underneath it. Storing
    /// here with `release` and loading with `acquire` is the happens-before
    /// edge that makes the buffer safe to read.
    ready: std.atomic.Value(bool) = .init(false),

    fn write(raw: *anyopaque, text: []const u8) void {
        const self: *Instructions = @ptrCast(@alignCast(raw));
        self.buffer.appendSlice(self.allocator, text) catch {};
        self.ready.store(true, .release);
    }

    /// Wait for the flow to publish its instructions. Returns false if it
    /// never did, so a caller reports that rather than reading an empty
    /// buffer and failing somewhere less obvious.
    fn wait(self: *Instructions) bool {
        var spins: usize = 0;
        while (spins < 500) : (spins += 1) {
            if (self.ready.load(.acquire)) return true;
            cc.util_time.sleepMs(10); // portable: POSIX nanosleep / Windows Sleep
        }
        return false;
    }

    fn notify(self: *Instructions) oauth_login.Notify {
        return .{ .ctx = self, .write = write };
    }

    fn deinit(self: *Instructions) void {
        self.buffer.deinit(self.allocator);
    }

    /// Pull the loopback port out of the redirect the authorize URL carries.
    fn callbackPort(self: *const Instructions) !u16 {
        return callbackPortIn(self.buffer.items);
    }

    fn stateValue(self: *const Instructions) ![]const u8 {
        return stateValueIn(self.buffer.items);
    }
};

fn callbackPortIn(text: []const u8) !u16 {
    const marker = "http%3A%2F%2Flocalhost%3A";
    const at = std.mem.indexOf(u8, text, marker) orelse return error.NoRedirectInInstructions;
    var cursor = at + marker.len;
    var port: u32 = 0;
    while (cursor < text.len and std.ascii.isDigit(text[cursor])) : (cursor += 1) {
        port = port * 10 + (text[cursor] - '0');
    }
    return std.math.cast(u16, port) orelse error.NoRedirectInInstructions;
}

fn stateValueIn(text: []const u8) ![]const u8 {
    const marker = "&state=";
    const at = std.mem.indexOf(u8, text, marker) orelse return error.NoStateInInstructions;
    const start = at + marker.len;
    var end = start;
    while (end < text.len and text[end] != '&' and text[end] != '\n') : (end += 1) {}
    return text[start..end];
}

/// Drive the redirect the authorization server would perform.
fn deliverCallback(port: u16, query: []const u8) !void {
    const socket = try net.connectLoopback(port);
    defer net.closeSocket(socket);
    var request_buffer: [1024]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buffer,
        "GET /auth/callback?{s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{query},
    );
    _ = net.send(socket, request);
    var drain_buffer: [1024]u8 = undefined;
    while (net.recv(socket, &drain_buffer) > 0) {}
}

const LoopbackRun = struct {
    endpoints: oauth_login.Endpoints,
    options: oauth_login.Options,
    allocator: std.mem.Allocator,
    io: std.Io,
    result: ?anyerror![]u8 = null,

    fn run(self: *LoopbackRun) void {
        self.result = oauth_login.acquireFirstToken(
            self.allocator,
            self.io,
            self.endpoints,
            self.options,
        );
    }
};

test "L2 provider login: a loopback PKCE grant becomes a durable per-provider login" {
    const a = std.testing.allocator;

    var token_server = try harness.MockServer.start(
        \\{"access_token":"provider-access","refresh_token":"provider-refresh","token_type":"Bearer","expires_in":3600}
    , 0);
    defer token_server.stop();
    const token_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth/token", .{token_server.port});
    defer a.free(token_url);

    var instructions = Instructions{ .allocator = a };
    defer instructions.deinit();

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();

    var run = LoopbackRun{
        .allocator = a,
        .io = io_runtime.io(),
        .endpoints = .{
            .token_url = token_url,
            .authorize_url = "http://127.0.0.1:1/authorize",
            .client_id = "test-client",
            .scope = "offline_access",
        },
        .options = .{
            .method = .loopback,
            // A test must never launch a browser, and 0 lets the kernel pick a
            // port so a developer's real login server cannot collide with it.
            .open_browser = false,
            .port = 0,
            .notify = instructions.notify(),
        },
    };
    var thread = try std.Thread.spawn(.{}, LoopbackRun.run, .{&run});

    // The listener is bound before the instructions are written, so once the
    // URL is visible the callback can be delivered.
    if (!instructions.wait()) return error.FlowNeverPublishedInstructions;
    const port = try instructions.callbackPort();
    const state = try instructions.stateValue();

    // A callback carrying the wrong state must not end the wait: it is either
    // a stale tab or a cross-site attempt, and accepting it would exchange a
    // code this process never asked for.
    try deliverCallback(port, "code=wrong-state-code&state=not-the-state");
    try std.testing.expect(token_server.requestCount() == 0);

    const query = try std.fmt.allocPrint(a, "code=auth-code-42&state={s}", .{state});
    defer a.free(query);
    try deliverCallback(port, query);
    thread.join();

    const token_json = try (run.result orelse return error.FlowDidNotRun);
    defer a.free(token_json);
    try std.testing.expect(std.mem.indexOf(u8, token_json, "provider-access") != null);

    const exchanged = token_server.lastRequest() orelse return error.NoTokenRequestCaptured;
    const body = exchanged.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=auth-code-42") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "client_id=test-client") != null);
    // PKCE is not optional here: without the verifier the code alone would be
    // enough for anyone who observed the redirect.
    try std.testing.expect(std.mem.indexOf(u8, body, "code_verifier=") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "redirect_uri=") != null);
    // The scope the profile declared must reach the authorization request.
    try std.testing.expect(std.mem.indexOf(u8, instructions.buffer.items, "scope=offline_access") != null);

    // The whole point of the entry point: the token becomes a login the
    // session layer can already use.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const oauth_dir = try a.dupeZ(u8, root_buffer[0..root_len]);
    defer a.free(oauth_dir);
    ppaths.setEnv("METACODES_OAUTH_DIR", oauth_dir.ptr);
    defer ppaths.unsetEnv("METACODES_OAUTH_DIR");

    const provider_id = cc.provider_ids.Slug.lit("openai");
    {
        var session = try provider_oauth.Session.initHome(a, provider_id);
        defer session.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const outcome = try provider_oauth.parseTokenResponse(arena.allocator(), token_json);
        try session.setClientId("test-client");
        try session.importOutcome(outcome, 1_000);
    }

    var reloaded = try provider_oauth.Session.initHome(a, provider_id);
    defer reloaded.deinit();
    try std.testing.expect(try reloaded.load());
    try std.testing.expectEqualStrings("provider-access", reloaded.tokens.?.access_token);
    try std.testing.expectEqualStrings("provider-refresh", reloaded.tokens.?.refresh_token);
    // Recorded with the tokens: a refresh that presented a different client
    // would be rejected as `invalid_client`, hours after the login looked fine.
    try std.testing.expectEqualStrings("test-client", reloaded.client_id.?);
}

test "L2 provider login: a device grant polls through authorization_pending" {
    const a = std.testing.allocator;

    // One server answers both endpoints in sequence: the device
    // authorization request, then a pending poll, then the grant.
    const bodies = [_][]const u8{
        \\{"device_code":"dev-code-7","user_code":"WXYZ-1234","verification_uri":"https://example.invalid/activate","expires_in":600,"interval":1}
        ,
        \\{"error":"authorization_pending"}
        ,
        \\{"access_token":"device-access","refresh_token":"device-refresh","token_type":"Bearer","expires_in":3600}
        ,
    };
    const statuses = [_][]const u8{
        "HTTP/1.1 200 OK",
        // RFC 8628 §3.5: a pending authorization is reported as an OAuth error
        // response, not as a 200. Treating that status as fatal would abandon
        // every device login the moment it started.
        "HTTP/1.1 400 Bad Request",
        "HTTP/1.1 200 OK",
    };
    var server = try harness.MockServer.startHttpCassette(&bodies, &statuses);
    defer server.stop();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth", .{server.port});
    defer a.free(url);

    var instructions = Instructions{ .allocator = a };
    defer instructions.deinit();
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();

    const token_json = try oauth_login.acquireFirstToken(a, io_runtime.io(), .{
        .token_url = url,
        .device_authorization_url = url,
        .client_id = "device-client",
    }, .{
        .method = .device_code,
        .notify = instructions.notify(),
        .timeout_seconds = 30,
    });
    defer a.free(token_json);
    try std.testing.expect(std.mem.indexOf(u8, token_json, "device-access") != null);

    // The user cannot complete a device login without being told where to go
    // and what to type.
    try std.testing.expect(std.mem.indexOf(u8, instructions.buffer.items, "https://example.invalid/activate") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions.buffer.items, "WXYZ-1234") != null);

    // Three requests: authorize, pending poll, success. Two would mean the
    // pending answer was mistaken for a result.
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    const poll = (server.requestAt(1) orelse return error.NoPollCaptured).body();
    try std.testing.expect(std.mem.indexOf(
        u8,
        poll,
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, poll, "device_code=dev-code-7") != null);
}

test "L2 provider login: a denied device grant fails instead of polling to expiry" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{
        \\{"device_code":"dev-code-8","user_code":"AAAA-0000","verification_uri":"https://example.invalid/activate","expires_in":600,"interval":1}
        ,
        \\{"error":"access_denied"}
        ,
    };
    const statuses = [_][]const u8{ "HTTP/1.1 200 OK", "HTTP/1.1 400 Bad Request" };
    var server = try harness.MockServer.startHttpCassette(&bodies, &statuses);
    defer server.stop();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth", .{server.port});
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    try std.testing.expectError(oauth_login.Error.OAuthDeviceAccessDenied, oauth_login.acquireFirstToken(
        a,
        io_runtime.io(),
        .{ .token_url = url, .device_authorization_url = url, .client_id = "device-client" },
        .{ .method = .device_code, .timeout_seconds = 30 },
    ));
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
}

test "L2 provider login: the recorded client is the one the refresh grant presents" {
    // Before this, the refresh grant sent the *provider id* as `client_id`,
    // which no real authorization server has ever heard of; a login obtained
    // interactively would have started failing with `invalid_client` at its
    // first expiry. The client that obtained the grant travels with it.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const oauth_dir = try a.dupeZ(u8, root_buffer[0..root_len]);
    defer a.free(oauth_dir);
    ppaths.setEnv("METACODES_OAUTH_DIR", oauth_dir.ptr);
    defer ppaths.unsetEnv("METACODES_OAUTH_DIR");

    const provider_id = cc.provider_ids.Slug.lit("openai");
    {
        var session = try provider_oauth.Session.initHome(a, provider_id);
        defer session.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const outcome = try provider_oauth.parseTokenResponse(arena.allocator(),
            \\{"access_token":"stale","refresh_token":"refresh-1","token_type":"Bearer","expires_in":1}
        );
        try session.setClientId("recorded-client");
        try session.importOutcome(outcome, 1_000);
    }

    var session = try provider_oauth.Session.initHome(a, provider_id);
    defer session.deinit();
    try std.testing.expect(try session.load());
    // Precedence: the recorded client wins over what the profile declares,
    // and the profile wins over the historical provider-id fallback.
    try std.testing.expectEqualStrings("recorded-client", session.clientIdFor("profile-client"));
    try std.testing.expectEqualStrings("recorded-client", session.clientIdFor(null));

    var token_server = try harness.MockServer.start(
        \\{"access_token":"fresh","refresh_token":"refresh-2","token_type":"Bearer","expires_in":3600}
    , 0);
    defer token_server.stop();
    const token_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth/token", .{token_server.port});
    defer a.free(token_url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var exchange = cc.api_oauth_exchange.HttpExchange{
        .allocator = a,
        .io = io_runtime.io(),
        .endpoint = .{
            .token_url = token_url,
            .client_id = session.clientIdFor(null),
        },
    };
    // The stored token expired long ago, so this drives a real refresh.
    const token = try session.accessToken(2_000_000, exchange.exchange());
    defer a.free(token);
    try std.testing.expectEqualStrings("fresh", token);

    const refreshed = token_server.lastRequest() orelse return error.NoRefreshRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, refreshed.body(), "grant_type=refresh_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, refreshed.body(), "client_id=recorded-client") != null);

    // A login persisted before the client was recorded still falls back the
    // way it always did, so upgrading does not break one.
    var legacy = try provider_oauth.Session.init(a, provider_id, "/nonexistent/legacy.json");
    defer legacy.deinit();
    try std.testing.expectEqualStrings("profile-client", legacy.clientIdFor("profile-client"));
    try std.testing.expectEqualStrings("openai", legacy.clientIdFor(null));
}

test "L2 provider login: an imported token response records the explicit client" {
    // `--client-id` was accepted on the `--oauth-token-json` path and then
    // ignored: the import always took the profile's declared client, which for
    // the built-in openai profile is none, so the stored login refreshed as
    // `client_id=openai`. This drives the wiring itself, not the parts.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const oauth_dir = try a.dupeZ(u8, root_buffer[0..root_len]);
    defer a.free(oauth_dir);
    ppaths.setEnv("METACODES_OAUTH_DIR", oauth_dir.ptr);
    defer ppaths.unsetEnv("METACODES_OAUTH_DIR");

    const openai = &cc.provider_registry.openai.PROFILE;
    try std.testing.expect(openai.oauth_client_id == null);
    const token_json =
        \\{"access_token":"imported-access","refresh_token":"imported-refresh","token_type":"Bearer","expires_in":3600}
    ;
    try std.testing.expectEqual(
        @as(u8, 0),
        cc.loginProviderWithTokenResponse(a, openai, token_json, "explicit-client"),
    );

    var session = try provider_oauth.Session.initHome(a, openai.id);
    defer session.deinit();
    try std.testing.expect(try session.load());
    try std.testing.expectEqualStrings("imported-access", session.tokens.?.access_token);
    // The refresh grant will present the client the user named, not the
    // provider id.
    try std.testing.expectEqualStrings("explicit-client", session.clientIdFor(openai.oauth_client_id));
}

test "L2 provider login: a provider that accepts no OAuth kind is refused before anything is stored" {
    // Credential resolution opens the OAuth session only for kinds
    // `servesKind` recognizes. A login stored for any other profile would be
    // reported as a success and then never consulted.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const oauth_dir = try a.dupeZ(u8, root_buffer[0..root_len]);
    defer a.free(oauth_dir);
    ppaths.setEnv("METACODES_OAUTH_DIR", oauth_dir.ptr);
    defer ppaths.unsetEnv("METACODES_OAUTH_DIR");

    const Slug = cc.provider_ids.Slug;
    const key_only = cc.provider_profile.ProviderProfile{
        .id = Slug.lit("keyonly"),
        .implementation_id = Slug.lit("keyonly"),
        .display_name = "Key only",
        .channels = &.{},
        .accepted_credential_kinds = &.{.api_key},
        .oauth_token_url = "https://example.invalid/token",
    };
    const token_json =
        \\{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":3600}
    ;
    try std.testing.expectEqual(
        @as(u8, 2),
        cc.loginProviderWithTokenResponse(a, &key_only, token_json, "some-client"),
    );
    var session = try provider_oauth.Session.initHome(a, key_only.id);
    defer session.deinit();
    try std.testing.expect(!(try session.load()));
}

test "L2 provider login: a configured provider declares its own OAuth endpoints" {
    // The client an installation presents is registered by whoever runs it, so
    // for a configured provider it belongs in configuration. Without this the
    // interactive flow exists but is unreachable for exactly the providers
    // that need it most.
    const a = std.testing.allocator;
    var definitions = try cc.provider_custom.parse(a,
        \\{"custom_providers":{"relay":{
        \\  "models":[{"request_model_id":"m","display_name":"M"}],
        \\  "channels":[{"id":"default","base_url":"https://relay.invalid/v1","protocol":"openai_chat"}],
        \\  "credential_kinds":["openai_oauth"],
        \\  "oauth":{"token_url":"https://relay.invalid/token","authorize_url":"https://relay.invalid/authorize",
        \\           "device_authorization_url":"https://relay.invalid/device","client_id":"relay-cli","scope":"offline"}
        \\}}}
    );
    defer definitions.deinit();
    const built = definitions.find("relay") orelse return error.ProviderNotDefined;
    try std.testing.expect(built.declaresInteractiveOAuth());
    try std.testing.expectEqualStrings("https://relay.invalid/token", built.oauth_token_url.?);
    try std.testing.expectEqualStrings("https://relay.invalid/authorize", built.oauth_authorize_url.?);
    try std.testing.expectEqualStrings("https://relay.invalid/device", built.oauth_device_authorization_url.?);
    try std.testing.expectEqualStrings("relay-cli", built.oauth_client_id.?);
    try std.testing.expectEqualStrings("offline", built.oauth_scope);

    // An `oauth` block on a provider that accepts no OAuth credential kind
    // describes a login the runtime would never consult; it is rejected where
    // the definition is, not after a successful-looking login.
    try std.testing.expectError(error.OAuthWithoutOAuthCredentialKind, cc.provider_custom.parse(a,
        \\{"custom_providers":{"relay":{
        \\  "models":[{"request_model_id":"m","display_name":"M"}],
        \\  "channels":[{"id":"default","base_url":"https://relay.invalid/v1","protocol":"openai_chat"}],
        \\  "oauth":{"token_url":"https://relay.invalid/token","client_id":"relay-cli"}
        \\}}}
    ));

    // An authorization endpoint with nowhere to exchange the code is a
    // definition that could only fail at login time.
    try std.testing.expectError(error.InvalidDocument, cc.provider_custom.parse(a,
        \\{"custom_providers":{"relay":{
        \\  "models":[{"request_model_id":"m","display_name":"M"}],
        \\  "channels":[{"id":"default","base_url":"https://relay.invalid/v1","protocol":"openai_chat"}],
        \\  "oauth":{"authorize_url":"https://relay.invalid/authorize"}
        \\}}}
    ));
}

const InteractiveRun = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: *cc.provider_host.Host,
    notify: oauth_login.Notify,
    result: ?(anyerror!provider_login.Outcome) = null,

    fn run(self: *InteractiveRun) void {
        self.result = provider_login.loginInteractive(self.allocator, self.io, self.host, "relay", .{
            .method = .loopback,
            .open_browser = false,
            .port = 0,
            .client_id = "explicit-client",
        }, self.notify);
    }
};

fn expectNoLogin(allocator: std.mem.Allocator, comptime id: []const u8) !void {
    var session = try provider_oauth.Session.initHome(allocator, cc.provider_ids.Slug.lit(id));
    defer session.deinit();
    try std.testing.expect(!(try session.load()));
}

test "loginInteractive persists the login and reports through the notify sink" {
    // The kernel entry point a front end invokes: the same loopback grant the
    // CLI runs, ending in the same durable import, with the instructions
    // delivered through the caller's sink rather than stderr.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const oauth_dir = try a.dupeZ(u8, root_buffer[0..root_len]);
    defer a.free(oauth_dir);
    ppaths.setEnv("METACODES_OAUTH_DIR", oauth_dir.ptr);
    defer ppaths.unsetEnv("METACODES_OAUTH_DIR");

    var token_server = try harness.MockServer.start(
        \\{"access_token":"relay-access","refresh_token":"relay-refresh","token_type":"Bearer","expires_in":3600}
    , 0);
    defer token_server.stop();
    const definition = try std.fmt.allocPrint(a,
        \\{{"custom_providers":{{"relay":{{
        \\  "models":[{{"request_model_id":"m","display_name":"M"}}],
        \\  "channels":[{{"id":"default","base_url":"https://relay.invalid/v1","protocol":"openai_chat"}}],
        \\  "credential_kinds":["openai_oauth"],
        \\  "oauth":{{"token_url":"http://127.0.0.1:{d}/oauth/token","authorize_url":"http://127.0.0.1:1/authorize","client_id":"relay-cli","scope":"offline"}}
        \\}}}}}}
    , .{token_server.port});
    defer a.free(definition);
    const host = try cc.provider_host.Host.create(a);
    defer host.destroy();
    try host.adoptCustomProviders(definition);

    var instructions = Instructions{ .allocator = a };
    defer instructions.deinit();
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var run = InteractiveRun{ .allocator = a, .io = io_runtime.io(), .host = host, .notify = instructions.notify() };
    var thread = try std.Thread.spawn(.{}, InteractiveRun.run, .{&run});
    if (!instructions.wait()) return error.FlowNeverPublishedInstructions;
    const port = try instructions.callbackPort();
    const state = try instructions.stateValue();
    const query = try std.fmt.allocPrint(a, "code=auth-code-7&state={s}", .{state});
    defer a.free(query);
    try deliverCallback(port, query);
    thread.join();

    const outcome = try (run.result orelse return error.FlowDidNotRun);
    try std.testing.expect(outcome.client_id_source == .explicit);
    try std.testing.expect(outcome.provider_id.eqlText("relay"));
    // The sink, not stderr, carried the authorization URL.
    try std.testing.expect(std.mem.indexOf(u8, instructions.buffer.items, "http://127.0.0.1:1/authorize") != null);
    // The explicit client reached the token request, not the declared one.
    const exchanged = token_server.lastRequest() orelse return error.NoTokenRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, exchanged.body(), "client_id=explicit-client") != null);
    // The durable import both login paths end in.
    var reloaded = try provider_oauth.Session.initHome(a, cc.provider_ids.Slug.lit("relay"));
    defer reloaded.deinit();
    try std.testing.expect(try reloaded.load());
    try std.testing.expectEqualStrings("relay-access", reloaded.tokens.?.access_token);
    try std.testing.expectEqualStrings("explicit-client", reloaded.client_id.?);
}

test "loginInteractive fails closed with typed errors and persists nothing" {
    // Every refusal happens before a request is made and before anything is
    // written, and each has its own error so a front end can say why.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const oauth_dir = try a.dupeZ(u8, root_buffer[0..root_len]);
    defer a.free(oauth_dir);
    ppaths.setEnv("METACODES_OAUTH_DIR", oauth_dir.ptr);
    defer ppaths.unsetEnv("METACODES_OAUTH_DIR");

    const host = try cc.provider_host.Host.create(a);
    defer host.destroy();
    try host.adoptCustomProviders(
        \\{"custom_providers":{"relay":{
        \\  "models":[{"request_model_id":"m","display_name":"M"}],
        \\  "channels":[{"id":"default","base_url":"https://relay.invalid/v1","protocol":"openai_chat"}],
        \\  "credential_kinds":["openai_oauth"],
        \\  "oauth":{"token_url":"https://relay.invalid/token","authorize_url":"https://relay.invalid/authorize","client_id":"relay-cli"}
        \\},"keyonly":{
        \\  "models":[{"request_model_id":"m","display_name":"M"}],
        \\  "channels":[{"id":"default","base_url":"https://keyonly.invalid/v1","protocol":"openai_chat"}],
        \\  "credential_kinds":["api_key"]
        \\}}}
    );
    var quiet = Instructions{ .allocator = a };
    defer quiet.deinit();
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();
    const no_browser: provider_login.Options = .{ .open_browser = false, .port = 0 };

    try std.testing.expectError(error.UnknownProvider, provider_login.loginInteractive(a, io, host, "nope", no_browser, quiet.notify()));
    try std.testing.expectError(error.ProviderHasNoTokenEndpoint, provider_login.loginInteractive(a, io, host, "keyonly", no_browser, quiet.notify()));
    try std.testing.expectError(error.FlowUnavailable, provider_login.loginInteractive(a, io, host, "relay", .{ .method = .device_code, .open_browser = false, .port = 0 }, quiet.notify()));
    // The built-in openai profile declares no client id (an owner decision):
    // without --client-id the flow must not even start.
    try std.testing.expectError(error.ClientIdMissing, provider_login.loginInteractive(a, io, host, "openai", no_browser, quiet.notify()));
    // A profile with a token endpoint but no OAuth credential kind is refused
    // by the same shared decision the `--oauth-token-json` path uses.
    const Slug = cc.provider_ids.Slug;
    const key_only = cc.provider_profile.ProviderProfile{
        .id = Slug.lit("keyonly2"),
        .implementation_id = Slug.lit("keyonly2"),
        .display_name = "Key only",
        .channels = &.{},
        .accepted_credential_kinds = &.{.api_key},
        .oauth_token_url = "https://example.invalid/token",
    };
    try std.testing.expectError(error.ProviderAcceptsNoOAuthKind, provider_login.requireOAuthCapable(&key_only));

    // Nothing reached the sink and nothing was persisted.
    try std.testing.expectEqual(@as(usize, 0), quiet.buffer.items.len);
    try expectNoLogin(a, "nope");
    try expectNoLogin(a, "keyonly");
    try expectNoLogin(a, "relay");
    try expectNoLogin(a, "openai");
}

/// The picker's credential stage runs the login through `LoginWorker` (#67);
/// spin until the worker's transcript satisfies `predicate` or the bound runs out.
fn awaitWorker(worker: *cc.api_login_worker.LoginWorker, comptime predicate: fn (*cc.api_login_worker.LoginWorker) bool) bool {
    var spins: usize = 0;
    while (spins < 1_000) : (spins += 1) {
        if (predicate(worker)) return true;
        cc.util_time.sleepMs(10);
    }
    return false;
}

fn workerNamesState(worker: *cc.api_login_worker.LoginWorker) bool {
    var buffer: [cc.api_login_worker.TRANSCRIPT_CAPACITY]u8 = undefined;
    return std.mem.indexOf(u8, worker.copyTranscript(&buffer), "&state=") != null;
}

fn workerSettled(worker: *cc.api_login_worker.LoginWorker) bool {
    return worker.isSettled();
}

test "L2 picker credential stage: the login worker lands a loopback grant as a durable login, and a cancelled one stores nothing" {
    const a = std.testing.allocator;

    var token_server = try harness.MockServer.start(
        \\{"access_token":"picker-access","refresh_token":"picker-refresh","token_type":"Bearer","expires_in":3600}
    , 0);
    defer token_server.stop();
    const token_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth/token", .{token_server.port});
    defer a.free(token_url);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const oauth_dir = try a.dupeZ(u8, root_buffer[0..root_len]);
    defer a.free(oauth_dir);
    ppaths.setEnv("METACODES_OAUTH_DIR", oauth_dir.ptr);
    defer ppaths.unsetEnv("METACODES_OAUTH_DIR");

    const Slug = cc.provider_ids.Slug;
    const profile = cc.provider_profile.ProviderProfile{
        .id = Slug.lit("picker-oauth"),
        .implementation_id = Slug.lit("picker-oauth"),
        .display_name = "Picker OAuth",
        .channels = &.{},
        .accepted_credential_kinds = &.{.openai_oauth},
        .oauth_token_url = token_url,
        .oauth_authorize_url = "http://127.0.0.1:1/authorize",
    };
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();

    // What picker_host does on MissingCredentials: prepare (typed refusals
    // happen here), then run on the worker. No browser; kernel-chosen port.
    const prepared = try provider_login.prepareProfile(&profile, .{ .open_browser = false, .port = 0, .client_id = "picker-client" });
    var worker = cc.api_login_worker.LoginWorker.init(a, io_runtime.io(), prepared);
    try worker.start();
    defer worker.join();

    // The transcript the picker draws is what the user acts on; the test acts
    // as the browser that follows it.
    if (!awaitWorker(&worker, workerNamesState)) return error.WorkerNeverPublishedInstructions;
    var transcript: [cc.api_login_worker.TRANSCRIPT_CAPACITY]u8 = undefined;
    const text = worker.copyTranscript(&transcript);
    const port = try callbackPortIn(text);
    const state = try stateValueIn(text);
    const query = try std.fmt.allocPrint(a, "code=picker-code&state={s}", .{state});
    defer a.free(query);
    try deliverCallback(port, query);

    if (!awaitWorker(&worker, workerSettled)) return error.WorkerNeverSettled;
    try std.testing.expectEqual(cc.api_login_worker.State.succeeded, worker.currentState());
    try std.testing.expect(token_server.requestCount() == 1);

    // The whole point: the login is durable and carries the client, so the
    // retried commit finds a credential and later refreshes present it.
    var reloaded = try provider_oauth.Session.initHome(a, profile.id);
    defer reloaded.deinit();
    try std.testing.expect(try reloaded.load());
    try std.testing.expectEqualStrings("picker-access", reloaded.tokens.?.access_token);
    try std.testing.expectEqualStrings("picker-client", reloaded.client_id.?);

    // Esc: the worker is cancelled through the signal and nothing is stored.
    const cancelled_profile = cc.provider_profile.ProviderProfile{
        .id = Slug.lit("picker-oauth-esc"),
        .implementation_id = Slug.lit("picker-oauth-esc"),
        .display_name = "Picker OAuth (cancelled)",
        .channels = &.{},
        .accepted_credential_kinds = &.{.openai_oauth},
        .oauth_token_url = token_url,
        .oauth_authorize_url = "http://127.0.0.1:1/authorize",
    };
    const cancelled_prepared = try provider_login.prepareProfile(&cancelled_profile, .{ .open_browser = false, .port = 0, .client_id = "picker-client" });
    var cancelled = cc.api_login_worker.LoginWorker.init(a, io_runtime.io(), cancelled_prepared);
    try cancelled.start();
    defer cancelled.join();
    if (!awaitWorker(&cancelled, workerNamesState)) return error.WorkerNeverPublishedInstructions;
    cancelled.cancel();
    if (!awaitWorker(&cancelled, workerSettled)) return error.WorkerNeverSettled;
    try std.testing.expectEqual(cc.api_login_worker.State.cancelled, cancelled.currentState());
    try std.testing.expect(token_server.requestCount() == 1);
    var absent = try provider_oauth.Session.initHome(a, cancelled_profile.id);
    defer absent.deinit();
    try std.testing.expect(!(try absent.load()));

    // A token endpoint that answers garbage: the worker settles `failed`
    // with the import's typed error, which the picker shows, and nothing
    // is stored.
    var garbage_server = try harness.MockServer.start("not a token response", 0);
    defer garbage_server.stop();
    const garbage_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/oauth/token", .{garbage_server.port});
    defer a.free(garbage_url);
    const failing_profile = cc.provider_profile.ProviderProfile{
        .id = Slug.lit("picker-oauth-bad"),
        .implementation_id = Slug.lit("picker-oauth-bad"),
        .display_name = "Picker OAuth (bad token endpoint)",
        .channels = &.{},
        .accepted_credential_kinds = &.{.openai_oauth},
        .oauth_token_url = garbage_url,
        .oauth_authorize_url = "http://127.0.0.1:1/authorize",
    };
    const failing_prepared = try provider_login.prepareProfile(&failing_profile, .{ .open_browser = false, .port = 0, .client_id = "picker-client" });
    var failing = cc.api_login_worker.LoginWorker.init(a, io_runtime.io(), failing_prepared);
    try failing.start();
    defer failing.join();
    if (!awaitWorker(&failing, workerNamesState)) return error.WorkerNeverPublishedInstructions;
    const failing_text = failing.copyTranscript(&transcript);
    const failing_query = try std.fmt.allocPrint(a, "code=picker-code&state={s}", .{try stateValueIn(failing_text)});
    defer a.free(failing_query);
    try deliverCallback(try callbackPortIn(failing_text), failing_query);
    if (!awaitWorker(&failing, workerSettled)) return error.WorkerNeverSettled;
    try std.testing.expectEqual(cc.api_login_worker.State.failed, failing.currentState());
    try std.testing.expectEqualStrings("InvalidTokenResponse", failing.failureName());
    var not_stored = try provider_oauth.Session.initHome(a, failing_profile.id);
    defer not_stored.deinit();
    try std.testing.expect(!(try not_stored.load()));
}
