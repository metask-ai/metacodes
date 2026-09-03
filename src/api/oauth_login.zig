//! Interactive first-token acquisition for provider-scoped OAuth (issue #33).
//!
//! `provider/oauth.zig` owns the lifecycle once a token exists — expiry
//! margin, single flight, rotated-refresh persistence — and performs no I/O.
//! `api/oauth_exchange.zig` is the `refresh_token` grant over real HTTP. This
//! is the third piece: the grant that produces the *first* token, so a user
//! who cannot obtain a token response by other means still has a way in.
//!
//! Two flows, because one is not enough:
//!
//! - **Loopback redirect + PKCE** is the default. It needs a browser and a
//!   listening socket on the same machine, which is the normal desktop case.
//! - **Device code (RFC 8628)** is the fallback for headless and SSH sessions,
//!   where there is no browser to open and no loopback address the
//!   authorization server could redirect to.
//!
//! The result is deliberately the raw token-response JSON: it goes through
//! exactly the same `provider/oauth.zig` parse and durable import that
//! `--oauth-token-json` already uses, so an interactive login and an
//! out-of-band one produce identical stored state.
//!
//! Nothing here is Metask-specific, and nothing here knows about the
//! credential store. The PKCE, loopback-callback and authorize-URL primitives
//! are shared with `core/auth.zig` rather than reimplemented, so state
//! validation and redirect parsing cannot drift between the two entry points.

const std = @import("std");
const auth = @import("../core/auth.zig");
const http_status = @import("http_status.zig");
const util_time = @import("../util/time.zig");

/// Distinct from Metask's 1455/1457 so a provider login started while a Metask
/// login is waiting does not steal its callback.
pub const DEFAULT_CALLBACK_PORT: u16 = 1456;

/// How long a device-code poll waits when the server states no interval.
const DEFAULT_DEVICE_POLL_SECONDS: u32 = 5;
/// A server may ask us to slow down without bound; this is where we stop.
const MAX_DEVICE_POLL_SECONDS: u32 = 60;

pub const Method = enum {
    /// Browser + loopback redirect, with PKCE.
    loopback,
    /// RFC 8628, for sessions that cannot open a browser.
    device_code,
};

/// Where to authorize, where to exchange, and as whom. Borrowed for the call.
pub const Endpoints = struct {
    token_url: []const u8,
    authorize_url: ?[]const u8 = null,
    device_authorization_url: ?[]const u8 = null,
    client_id: []const u8,
    scope: []const u8 = "",
};

/// Human-facing instructions. A URL the user must open and a code they must
/// type are not diagnostics — they are the flow — so they go through an
/// explicit sink rather than a logger. The TUI supplies its own; the CLI uses
/// `stderrNotify`.
pub const Notify = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, text: []const u8) void,

    pub fn say(self: Notify, text: []const u8) void {
        self.write(self.ctx, text);
    }
};

var stderr_notify_ctx: u8 = 0;

fn writeStderr(_: *anyopaque, text: []const u8) void {
    std.debug.print("{s}", .{text});
}

pub fn stderrNotify() Notify {
    return .{ .ctx = &stderr_notify_ctx, .write = writeStderr };
}

pub const Options = struct {
    method: Method = .loopback,
    /// Launch a browser at the authorization URL. False still prints it, which
    /// is what a remote-desktop or restricted environment needs.
    open_browser: bool = true,
    /// Loopback callback port. Zero lets the kernel pick one, which is what a
    /// test wants so it cannot collide with a real login server.
    port: u16 = DEFAULT_CALLBACK_PORT,
    /// Bounds the device-code poll, together with the server's own expiry:
    /// whichever runs out first ends the flow. The loopback flow instead waits
    /// on the browser for as long as the user leaves it open — the same
    /// behavior the Metask login has always had, interruptible from the
    /// terminal.
    timeout_seconds: u32 = 300,
    notify: ?Notify = null,
    /// Test seam: a fixed `state` makes the redirect reproducible without
    /// weakening the production path, which always generates one.
    force_state: ?[]const u8 = null,
};

pub const Error = error{
    /// The profile declares no endpoint for the requested method.
    OAuthFlowUnavailable,
    OAuthClientIdMissing,
    OAuthLoginTimedOut,
    OAuthDeviceAccessDenied,
    OAuthDeviceCodeExpired,
    MalformedDeviceAuthorizationResponse,
};

/// Run the flow and return the token-response JSON. The caller owns the bytes
/// and must erase them: they carry a refresh token.
pub fn acquireFirstToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoints: Endpoints,
    options: Options,
) ![]u8 {
    if (endpoints.client_id.len == 0) return Error.OAuthClientIdMissing;
    return switch (options.method) {
        .loopback => acquireByLoopback(allocator, io, endpoints, options),
        .device_code => acquireByDeviceCode(allocator, io, endpoints, options),
    };
}

fn acquireByLoopback(
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoints: Endpoints,
    options: Options,
) ![]u8 {
    const authorize_url = endpoints.authorize_url orelse return Error.OAuthFlowUnavailable;

    var pkce = try auth.generatePkce(allocator);
    defer pkce.deinit(allocator);
    const state = if (options.force_state) |forced|
        try allocator.dupe(u8, forced)
    else
        try auth.randomBase64Url(allocator, 32);
    defer auth.secureFree(allocator, state);

    var server = try auth.CallbackServer.bind(options.port);
    defer server.close();

    const redirect_uri = try std.fmt.allocPrint(
        allocator,
        "http://localhost:{d}/auth/callback",
        .{server.port},
    );
    defer allocator.free(redirect_uri);

    const url = try auth.buildAuthorizeUrl(
        allocator,
        authorize_url,
        endpoints.client_id,
        endpoints.scope,
        redirect_uri,
        pkce.code_challenge,
        state,
    );
    defer allocator.free(url);

    if (options.notify) |notify| {
        const text = try std.fmt.allocPrint(
            allocator,
            "Waiting for the login callback on http://localhost:{d}.\nOpen this URL to authorize:\n\n{s}\n\n",
            .{ server.port, url },
        );
        defer allocator.free(text);
        notify.say(text);
    }
    if (options.open_browser) auth.openBrowser(allocator, url) catch |err| {
        if (options.notify) |notify| {
            const text = std.fmt.allocPrint(
                allocator,
                "Could not open a browser automatically ({s}); open the URL above.\n",
                .{@errorName(err)},
            ) catch return err;
            defer allocator.free(text);
            notify.say(text);
        }
    };

    const code = try server.waitForAuthorizationCode(allocator, state);
    defer auth.secureFree(allocator, code);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try auth.appendFormField(&body.writer, "grant_type", "authorization_code", true);
    try auth.appendFormField(&body.writer, "client_id", endpoints.client_id, false);
    try auth.appendFormField(&body.writer, "code", code, false);
    try auth.appendFormField(&body.writer, "redirect_uri", redirect_uri, false);
    try auth.appendFormField(&body.writer, "code_verifier", pkce.code_verifier, false);
    return postForm(allocator, io, endpoints.token_url, body.written());
}

/// What the device authorization endpoint told us. Slices borrow the response
/// arena.
const DeviceAuthorization = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    verification_uri_complete: ?[]const u8,
    expires_in: u32,
    interval: u32,
};

fn acquireByDeviceCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoints: Endpoints,
    options: Options,
) ![]u8 {
    const device_url = endpoints.device_authorization_url orelse return Error.OAuthFlowUnavailable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var request: std.Io.Writer.Allocating = .init(allocator);
    defer request.deinit();
    try auth.appendFormField(&request.writer, "client_id", endpoints.client_id, true);
    if (endpoints.scope.len > 0)
        try auth.appendFormField(&request.writer, "scope", endpoints.scope, false);
    // Propagated, not flattened: the most likely failure here is a client id
    // the server does not recognize, and `OAuthClientRejected` is the only
    // thing that tells the user which of their inputs is wrong.
    const raw = try postForm(allocator, io, device_url, request.written());
    defer auth.secureFree(allocator, raw);

    const grant = try parseDeviceAuthorization(arena.allocator(), raw);
    if (options.notify) |notify| {
        const text = try std.fmt.allocPrint(
            allocator,
            "Open {s} and enter the code {s}\n\n",
            .{ grant.verification_uri_complete orelse grant.verification_uri, grant.user_code },
        );
        defer allocator.free(text);
        notify.say(text);
    }

    // The server's own expiry bounds the poll, capped by the caller's budget:
    // whichever runs out first ends the flow.
    const started = util_time.nowUnix();
    const budget: i64 = @min(@as(i64, grant.expires_in), @as(i64, options.timeout_seconds));
    var interval: u32 = @min(
        if (grant.interval == 0) DEFAULT_DEVICE_POLL_SECONDS else grant.interval,
        MAX_DEVICE_POLL_SECONDS,
    );

    while (util_time.nowUnix() - started < budget) {
        util_time.sleepMs(@as(u64, interval) * 1000);
        var poll: std.Io.Writer.Allocating = .init(allocator);
        defer poll.deinit();
        try auth.appendFormField(
            &poll.writer,
            "grant_type",
            "urn:ietf:params:oauth:grant-type:device_code",
            true,
        );
        try auth.appendFormField(&poll.writer, "client_id", endpoints.client_id, false);
        try auth.appendFormField(&poll.writer, "device_code", grant.device_code, false);

        const outcome = try postFormRaw(allocator, io, endpoints.token_url, poll.written());
        if (outcome.ok) return outcome.body;
        defer auth.secureFree(allocator, outcome.body);
        // RFC 8628 §3.5: `authorization_pending` and `slow_down` are the
        // normal course of a flow the user has not finished yet, not failures.
        switch (classifyDevicePoll(outcome.body)) {
            .pending => {},
            .slow_down => interval = @min(interval + 5, MAX_DEVICE_POLL_SECONDS),
            .denied => return Error.OAuthDeviceAccessDenied,
            .expired => return Error.OAuthDeviceCodeExpired,
            .fatal => return auth.classifyOAuthEndpointError(outcome.status, outcome.body),
        }
    }
    return Error.OAuthLoginTimedOut;
}

const DevicePoll = enum { pending, slow_down, denied, expired, fatal };

fn classifyDevicePoll(body: []const u8) DevicePoll {
    if (errorCode(body)) |code| {
        if (std.mem.eql(u8, code, "authorization_pending")) return .pending;
        if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
        if (std.mem.eql(u8, code, "access_denied")) return .denied;
        if (std.mem.eql(u8, code, "expired_token")) return .expired;
    }
    return .fatal;
}

/// Read `error` out of a token-endpoint failure body without allocating: the
/// value is a short RFC-defined token, and the body may carry a secret.
fn errorCode(body: []const u8) ?[]const u8 {
    const key = "\"error\"";
    const key_at = std.mem.indexOf(u8, body, key) orelse return null;
    var index = key_at + key.len;
    while (index < body.len and (body[index] == ' ' or body[index] == ':')) : (index += 1) {}
    if (index >= body.len or body[index] != '"') return null;
    index += 1;
    const end = std.mem.indexOfScalarPos(u8, body, index, '"') orelse return null;
    return body[index..end];
}

fn parseDeviceAuthorization(arena: std.mem.Allocator, body: []const u8) !DeviceAuthorization {
    // `alloc_always` so the parsed strings own their bytes: the response
    // buffer they would otherwise reference is securely zeroed on the way out.
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{
        .allocate = .alloc_always,
    }) catch return Error.MalformedDeviceAuthorizationResponse;
    if (root != .object) return Error.MalformedDeviceAuthorizationResponse;
    const device_code = stringField(root, "device_code") orelse
        return Error.MalformedDeviceAuthorizationResponse;
    const user_code = stringField(root, "user_code") orelse
        return Error.MalformedDeviceAuthorizationResponse;
    const verification_uri = stringField(root, "verification_uri") orelse
        stringField(root, "verification_url") orelse
        return Error.MalformedDeviceAuthorizationResponse;
    const expires_in = intField(root, "expires_in") orelse
        return Error.MalformedDeviceAuthorizationResponse;
    if (expires_in <= 0) return Error.MalformedDeviceAuthorizationResponse;
    return .{
        .device_code = device_code,
        .user_code = user_code,
        .verification_uri = verification_uri,
        .verification_uri_complete = stringField(root, "verification_uri_complete"),
        .expires_in = std.math.cast(u32, expires_in) orelse std.math.maxInt(u32),
        .interval = if (intField(root, "interval")) |value|
            std.math.cast(u32, value) orelse DEFAULT_DEVICE_POLL_SECONDS
        else
            DEFAULT_DEVICE_POLL_SECONDS,
    };
}

fn stringField(root: std.json.Value, name: []const u8) ?[]const u8 {
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn intField(root: std.json.Value, name: []const u8) ?i64 {
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        // RFC 8628's numeric fields are integers. A float from an untrusted
        // endpoint counts only if it names one exactly: `1.5` is malformed,
        // not "1", and a value past i64 is malformed, not a panic inside
        // `@intFromFloat`.
        .float => |number| integralFloat(number),
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn integralFloat(number: f64) ?i64 {
    if (!std.math.isFinite(number) or number != @trunc(number)) return null;
    // 2^53: every integer up to here is exactly representable as f64, so the
    // conversion below cannot round, and no interval or expiry is anywhere
    // near it.
    const exact_limit: f64 = 9007199254740992.0;
    if (number > exact_limit or number < -exact_limit) return null;
    return @intFromFloat(number);
}

const RawResponse = struct {
    ok: bool,
    status: u16,
    body: []u8,
};

/// POST a form and return the body only on success, classifying a failure the
/// way the rest of the OAuth paths do.
fn postForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    form: []const u8,
) ![]u8 {
    const response = try postFormRaw(allocator, io, url, form);
    if (response.ok) return response.body;
    defer auth.secureFree(allocator, response.body);
    return auth.classifyOAuthEndpointError(response.status, response.body);
}

fn postFormRaw(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    form: []const u8,
) !RawResponse {
    const uri = std.Uri.parse(url) catch return error.InvalidOAuthTokenUrl;
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "accept", .value = "application/json" },
        },
    }) catch return error.OAuthTokenExchangeFailed;
    defer request.deinit();
    request.sendBodyComplete(@constCast(form)) catch return error.OAuthTokenExchangeFailed;
    var redirect_buffer: [4096]u8 = undefined;
    const head = request.receiveHead(&redirect_buffer) catch return error.OAuthTokenExchangeFailed;
    // `std.http.Status` is non-exhaustive; capture it before anything can
    // `@tagName` an unnamed-but-valid code.
    const status = http_status.ResponseStatus.capture(&head);
    var transfer_buffer: [8192]u8 = undefined;
    const reader = request.reader.bodyReader(
        &transfer_buffer,
        head.head.transfer_encoding,
        head.head.content_length,
    );
    const payload = reader.allocRemaining(allocator, std.Io.Limit.limited(256 * 1024)) catch
        return error.OAuthTokenExchangeFailed;
    // Any 2xx is a successful grant: `isOk()` is 200-only, and a token
    // endpoint answering 201 is unusual but not a failure.
    return .{
        .ok = status.code >= 200 and status.code < 300,
        .status = status.code,
        .body = payload,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

test "a flow whose endpoint the profile never declared fails before any I/O" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var io_runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_runtime.deinit();

    // No authorize URL: the browser flow has nowhere to send the user.
    try std.testing.expectError(Error.OAuthFlowUnavailable, acquireFirstToken(
        arena.allocator(),
        io_runtime.io(),
        .{ .token_url = "https://example.invalid/token", .client_id = "cli" },
        .{ .method = .loopback, .open_browser = false },
    ));
    // No device endpoint: a headless session has nothing to poll.
    try std.testing.expectError(Error.OAuthFlowUnavailable, acquireFirstToken(
        arena.allocator(),
        io_runtime.io(),
        .{
            .token_url = "https://example.invalid/token",
            .authorize_url = "https://example.invalid/authorize",
            .client_id = "cli",
        },
        .{ .method = .device_code },
    ));
    // No client: presenting an empty client id would fail at the endpoint with
    // a message that says nothing about what is missing locally.
    try std.testing.expectError(Error.OAuthClientIdMissing, acquireFirstToken(
        arena.allocator(),
        io_runtime.io(),
        .{
            .token_url = "https://example.invalid/token",
            .authorize_url = "https://example.invalid/authorize",
            .client_id = "",
        },
        .{ .method = .loopback, .open_browser = false },
    ));
}

test "device authorization responses are parsed, including the RFC's optional fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const complete = try parseDeviceAuthorization(a,
        \\{"device_code":"dev","user_code":"WXYZ-1234","verification_uri":"https://example.invalid/device",
        \\ "verification_uri_complete":"https://example.invalid/device?user_code=WXYZ-1234",
        \\ "expires_in":900,"interval":7}
    );
    try std.testing.expectEqualStrings("dev", complete.device_code);
    try std.testing.expectEqualStrings("WXYZ-1234", complete.user_code);
    try std.testing.expectEqualStrings(
        "https://example.invalid/device?user_code=WXYZ-1234",
        complete.verification_uri_complete.?,
    );
    try std.testing.expectEqual(@as(u32, 900), complete.expires_in);
    try std.testing.expectEqual(@as(u32, 7), complete.interval);

    // `interval` is optional; RFC 8628 §3.2 makes 5 seconds the default.
    const minimal = try parseDeviceAuthorization(a,
        \\{"device_code":"dev","user_code":"CODE","verification_uri":"https://example.invalid/d","expires_in":600}
    );
    try std.testing.expectEqual(DEFAULT_DEVICE_POLL_SECONDS, minimal.interval);
    try std.testing.expect(minimal.verification_uri_complete == null);

    // A response without a device code is not a grant we can poll for.
    try std.testing.expectError(Error.MalformedDeviceAuthorizationResponse, parseDeviceAuthorization(a,
        \\{"user_code":"CODE","verification_uri":"https://example.invalid/d","expires_in":600}
    ));
    // A zero or negative expiry would make the poll loop exit immediately and
    // report a timeout for a grant that was never usable.
    try std.testing.expectError(Error.MalformedDeviceAuthorizationResponse, parseDeviceAuthorization(a,
        \\{"device_code":"dev","user_code":"C","verification_uri":"https://example.invalid/d","expires_in":0}
    ));

    // Floats that name an integer exactly are that integer; anything else from
    // an untrusted endpoint is malformed rather than truncated or, past i64,
    // a runtime panic.
    const float_exact = try parseDeviceAuthorization(a,
        \\{"device_code":"dev","user_code":"C","verification_uri":"https://example.invalid/d","expires_in":600.0,"interval":2.0}
    );
    try std.testing.expectEqual(@as(u32, 600), float_exact.expires_in);
    try std.testing.expectEqual(@as(u32, 2), float_exact.interval);
    try std.testing.expectError(Error.MalformedDeviceAuthorizationResponse, parseDeviceAuthorization(a,
        \\{"device_code":"dev","user_code":"C","verification_uri":"https://example.invalid/d","expires_in":1.5}
    ));
    try std.testing.expectError(Error.MalformedDeviceAuthorizationResponse, parseDeviceAuthorization(a,
        \\{"device_code":"dev","user_code":"C","verification_uri":"https://example.invalid/d","expires_in":1e300}
    ));
    // A fractional interval falls back to the RFC default rather than
    // becoming a malformed grant: the interval is advisory, the expiry is not.
    const fractional_interval = try parseDeviceAuthorization(a,
        \\{"device_code":"dev","user_code":"C","verification_uri":"https://example.invalid/d","expires_in":600,"interval":2.5}
    );
    try std.testing.expectEqual(DEFAULT_DEVICE_POLL_SECONDS, fractional_interval.interval);
}

test "device poll classification separates waiting from failing" {
    // Treating `authorization_pending` as a failure would abandon every login
    // the moment it started; treating `access_denied` as pending would poll a
    // refusal until the grant expired.
    try std.testing.expectEqual(DevicePoll.pending, classifyDevicePoll(
        "{\"error\":\"authorization_pending\"}",
    ));
    try std.testing.expectEqual(DevicePoll.slow_down, classifyDevicePoll(
        "{\"error\": \"slow_down\",\"error_description\":\"too fast\"}",
    ));
    try std.testing.expectEqual(DevicePoll.denied, classifyDevicePoll("{\"error\":\"access_denied\"}"));
    try std.testing.expectEqual(DevicePoll.expired, classifyDevicePoll("{\"error\":\"expired_token\"}"));
    try std.testing.expectEqual(DevicePoll.fatal, classifyDevicePoll("{\"error\":\"invalid_client\"}"));
    try std.testing.expectEqual(DevicePoll.fatal, classifyDevicePoll("not json at all"));
}

test "the authorization URL carries PKCE, state and the declared client" {
    const a = std.testing.allocator;
    const url = try auth.buildAuthorizeUrl(
        a,
        "https://example.invalid/authorize",
        "cli-client",
        "openid profile",
        "http://localhost:1456/auth/callback",
        "challenge-value",
        "state-value",
    );
    defer a.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "response_type=code") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=cli-client") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=challenge-value") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=state-value") != null);
    // A scope the profile declares must actually be requested; an empty one
    // must not appear at all, because some servers reject `scope=`.
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=openid%20profile") != null);

    const unscoped = try auth.buildAuthorizeUrl(
        a,
        "https://example.invalid/authorize",
        "cli-client",
        "",
        "http://localhost:1456/auth/callback",
        "challenge-value",
        "state-value",
    );
    defer a.free(unscoped);
    try std.testing.expect(std.mem.indexOf(u8, unscoped, "scope=") == null);
}

test "an error code is read without allocating and without echoing the body" {
    try std.testing.expectEqualStrings("slow_down", errorCode("{\"error\":\"slow_down\"}").?);
    try std.testing.expectEqualStrings("x", errorCode("{\"a\":1,\"error\"  :  \"x\"}").?);
    try std.testing.expect(errorCode("{\"error\":42}") == null);
    try std.testing.expect(errorCode("{\"errors\":[\"nope\"]}") == null);
    try std.testing.expect(errorCode("{\"error\":\"unterminated") == null);
}
