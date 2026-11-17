//! Metask OAuth device-code exchange.
//!
//! Metask's authorization server is `https://www.metask-ai.com` (#527; the
//! bare `metask-ai.com` answers every request, POSTs included, with a 301 that
//! these requests do not follow). The grants here are JSON and every one of
//! them names the client, `metacodes`: the device request, each poll, and the
//! refresh, which the server binds to the client that was issued it. The
//! device request asks for `read model:invoke` (without a scope only `read`
//! is granted, and it cannot call models) and sends no `client_name`: the
//! server shows the registered one. Keeping this transport separate makes
//! those wire rules auditable and prevents a generic provider from
//! accidentally sending a form body to the Metask control plane.

const std = @import("std");
const auth = @import("../core/auth.zig");
const oauth = @import("../provider/oauth.zig");
const http_status = @import("http_status.zig");
const http_connection = @import("http_connection.zig");
const util_time = @import("../util/time.zig");
const util_json = @import("../util/json.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const provider_ids = @import("../provider/ids.zig");

pub const DEFAULT_SITE_URL = auth.METASK_SITE_URL;
pub const CLIENT_ID = auth.OAUTH_CLIENT_ID;

pub const DeviceCode = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    verification_uri_complete: ?[]const u8,
    expires_in: u32,
    interval: u32,
    expires_at: ?i64 = null,
};

pub const Error = error{
    InvalidUrl,
    RequestFailed,
    MalformedResponse,
    AuthorizationPending,
    SlowDown,
    ExpiredToken,
    AccessDenied,
    InvalidGrant,
    TimedOut,
};

pub fn siteUrl() []const u8 {
    if (std.c.getenv("METASK_SITE_URL")) |raw| return std.mem.trimEnd(u8, std.mem.span(raw), "/");
    return DEFAULT_SITE_URL;
}

pub fn deviceCodeUrl(site: []const u8, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/api/oauth/device/code", .{std.mem.trimEnd(u8, site, "/")});
}

pub fn tokenUrl(site: []const u8, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/api/oauth/token", .{std.mem.trimEnd(u8, site, "/")});
}

pub fn revokeUrl(site: []const u8, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/api/oauth/revoke", .{std.mem.trimEnd(u8, site, "/")});
}

/// A gateway override is an origin. Rejecting a request path here prevents a
/// caller from accidentally producing `/v1/messages/v1/messages` (or sending
/// a bearer to an endpoint they did not intend to select).
pub fn isGatewayOrigin(url_raw: []const u8) bool {
    const url = std.mem.trimEnd(u8, url_raw, "/");
    const uri = std.Uri.parse(url) catch return false;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null) return false;
    return uri.path.isEmpty();
}

pub fn deviceRequestBody(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"client_id\":\"" ++ CLIENT_ID ++ "\",\"scope\":\"" ++ auth.METASK_OAUTH_SCOPE ++ "\"}");
}

/// The refresh grant names the client it was issued to: the server binds a
/// refresh token to its client and rejects one presented without it.
pub fn refreshRequestBody(allocator: std.mem.Allocator, refresh_token: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"grant_type\":\"refresh_token\",\"refresh_token\":");
    try appendJsonString(allocator, &out, refresh_token);
    try out.appendSlice(allocator, ",\"client_id\":\"" ++ CLIENT_ID ++ "\"}");
    return out.toOwnedSlice(allocator);
}

/// The revocation request (RFC 7009, as the server takes it): the refresh
/// token, hinted as one, and the public client it was issued to.
pub fn revokeRequestBody(allocator: std.mem.Allocator, refresh_token: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try auth.appendFormField(&aw.writer, "token", refresh_token, true);
    try auth.appendFormField(&aw.writer, "token_type_hint", "refresh_token", false);
    try auth.appendFormField(&aw.writer, "client_id", CLIENT_ID, false);
    return aw.toOwnedSlice();
}

/// What `revokeStoredSession` found and did.
pub const RevokeOutcome = enum {
    /// The server answered 200: the authorization ends there too.
    revoked,
    /// No Metask session is stored: there is nothing to revoke.
    nothing_stored,
    /// The request failed or was refused: the authorization may still be
    /// valid at Metask until it expires.
    failed,
    /// No answer within the wait; the request may still finish.
    timed_out,
};

/// Revoke the stored Metask session's authorization at the server (#527),
/// as the sign-in contract asks a sign-out to do before it removes the local
/// sign-in. Best effort and bounded: the request runs on its own thread with
/// its own copies, `wait_ms` is all the caller waits, and sign-out goes on
/// whatever the outcome. `site` is the authorization server (`siteUrl()`).
pub fn revokeStoredSession(state_root: []const u8, site: []const u8, wait_ms: u64) RevokeOutcome {
    // The request may outlive the caller's wait: nothing it holds is the
    // caller's.
    const gpa = std.heap.page_allocator;
    var session = oauth.Session.initHome(gpa, state_root, provider_ids.Slug.lit("metask")) catch return .failed;
    defer session.deinit();
    if (!(session.load() catch false)) return .nothing_stored;
    const tokens = session.tokens orelse return .nothing_stored;
    var url_buf: [1024]u8 = undefined;
    const url = revokeUrl(site, &url_buf) catch return .failed;
    const job = RevokeJob.create(gpa, url, tokens.refresh_token) catch return .failed;
    const thread = @import("platform").thread.spawn(.full, RevokeJob.run, .{job}) catch {
        // Only the caller's share is left.
        _ = job.owners.fetchSub(1, .acq_rel);
        job.release();
        return .failed;
    };
    thread.detach();
    var waited: u64 = 0;
    while (waited < wait_ms and job.result.load(.acquire) == 0) : (waited += 50) util_time.sleepMs(50);
    const result = job.result.load(.acquire);
    job.release();
    return switch (result) {
        1 => .revoked,
        2 => .failed,
        else => .timed_out,
    };
}

/// One revocation request, shared by the caller and its thread; the last
/// one to let go frees it (the token zeroed).
const RevokeJob = struct {
    url: []u8,
    body: []u8,
    /// 0 while it runs, 1 revoked, 2 failed.
    result: std.atomic.Value(u8) = .init(0),
    owners: std.atomic.Value(u8) = .init(2),

    fn create(gpa: std.mem.Allocator, url: []const u8, refresh_token: []const u8) !*RevokeJob {
        const job = try gpa.create(RevokeJob);
        errdefer gpa.destroy(job);
        const url_copy = try gpa.dupe(u8, url);
        errdefer gpa.free(url_copy);
        job.* = .{ .url = url_copy, .body = try revokeRequestBody(gpa, refresh_token) };
        return job;
    }

    fn release(job: *RevokeJob) void {
        if (job.owners.fetchSub(1, .acq_rel) != 1) return;
        const gpa = std.heap.page_allocator;
        std.crypto.secureZero(u8, job.body);
        gpa.free(job.body);
        gpa.free(job.url);
        gpa.destroy(job);
    }

    fn run(job: *RevokeJob) void {
        defer job.release();
        job.result.store(if (post(job.url, job.body)) 1 else 2, .release);
    }

    fn post(url: []const u8, body: []const u8) bool {
        const gpa = std.heap.page_allocator;
        const uri = std.Uri.parse(url) catch return false;
        var io_runtime = @import("platform").signal.threadedIo(gpa, .{});
        defer io_runtime.deinit();
        var client = std.http.Client{ .allocator = gpa, .io = io_runtime.io() };
        defer client.deinit();
        // The token travels in the body; only the endpoint that received it
        // can answer.
        var request = client.request(.POST, uri, .{ .redirect_behavior = http_status.no_redirects, .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "accept", .value = "application/json" },
        } }) catch return false;
        defer request.deinit();
        http_connection.sendBodyComplete(&request, @constCast(body)) catch return false;
        var redirect: [4096]u8 = undefined;
        const response = request.receiveHead(&redirect) catch return false;
        return http_status.ResponseStatus.capture(&response).code == 200;
    }
};

pub fn deviceTokenRequestBody(allocator: std.mem.Allocator, device_code: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\",\"device_code\":");
    try appendJsonString(allocator, &out, device_code);
    try out.appendSlice(allocator, ",\"client_id\":\"" ++ CLIENT_ID ++ "\"}");
    return out.toOwnedSlice(allocator);
}

pub fn parseDeviceCode(arena: std.mem.Allocator, body: []const u8) Error!DeviceCode {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return error.MalformedResponse;
    if (root != .object) return error.MalformedResponse;
    const device = stringField(root, "device_code") orelse return error.MalformedResponse;
    const user = stringField(root, "user_code") orelse return error.MalformedResponse;
    const uri = stringField(root, "verification_uri") orelse return error.MalformedResponse;
    const expires = intField(root, "expires_in") orelse return error.MalformedResponse;
    if (expires <= 0) return error.MalformedResponse;
    const interval = intField(root, "interval") orelse 5;
    return .{
        .device_code = device,
        .user_code = user,
        .verification_uri = uri,
        .verification_uri_complete = stringField(root, "verification_uri_complete"),
        .expires_in = std.math.cast(u32, expires) orelse return error.MalformedResponse,
        .interval = std.math.cast(u32, @max(interval, 1)) orelse return error.MalformedResponse,
        .expires_at = if (intField(root, "expires_at")) |at| at else null,
    };
}

pub fn parsePollError(body: []const u8) Error {
    const code = errorCode(body) orelse return error.RequestFailed;
    if (std.mem.eql(u8, code, "authorization_pending")) return error.AuthorizationPending;
    if (std.mem.eql(u8, code, "slow_down")) return error.SlowDown;
    if (std.mem.eql(u8, code, "expired_token")) return error.ExpiredToken;
    if (std.mem.eql(u8, code, "access_denied")) return error.AccessDenied;
    if (std.mem.eql(u8, code, "invalid_grant")) return error.InvalidGrant;
    return error.RequestFailed;
}

/// Where the device flow reports what the user must act on: the page to open
/// and the code to enter there. `ctx` is the sink's own state (the TUI login
/// worker's transcript); the CLI passes none.
pub const DeviceNotify = struct {
    ctx: ?*anyopaque = null,
    show: *const fn (ctx: ?*anyopaque, uri: []const u8, code: []const u8) void,
};

/// Run the device flow and return the raw success token JSON.  The callback is
/// called after the device response is parsed, before polling begins, so CLI
/// output is stable even when the first poll blocks.
pub fn acquireDeviceToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    site: []const u8,
    open_browser: bool,
    notify: ?*const fn (uri: []const u8, code: []const u8) void,
) ![]u8 {
    const Write = *const fn (uri: []const u8, code: []const u8) void;
    const Adapter = struct {
        fn show(ctx: ?*anyopaque, uri: []const u8, code: []const u8) void {
            const write: *const Write = @ptrCast(@alignCast(ctx.?));
            write.*(uri, code);
        }
    };
    var write = notify orelse return acquireDeviceTokenWith(allocator, io, site, open_browser, null, null);
    return acquireDeviceTokenWith(allocator, io, site, open_browser, .{ .ctx = @ptrCast(&write), .show = Adapter.show }, null);
}

/// `acquireDeviceToken` with a sink that carries its own state (the TUI login
/// worker's transcript) and an `abort_signal`, checked between polls (every
/// 100 ms of the wait): an aborted flow returns `error.Aborted`, so a TUI can
/// end it with Esc.
pub fn acquireDeviceTokenWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    site: []const u8,
    open_browser: bool,
    notify: ?DeviceNotify,
    abort_signal: ?*const AbortSignal,
) ![]u8 {
    var endpoint_buf: [1024]u8 = undefined;
    const device_url = try deviceCodeUrl(site, &endpoint_buf);
    const request_body = try deviceRequestBody(allocator);
    defer allocator.free(request_body);
    const initial = try postJson(allocator, io, device_url, request_body);
    defer allocator.free(initial.body);
    if (!initial.ok) return parsePollError(initial.body);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const grant = try parseDeviceCode(arena.allocator(), initial.body);
    const verification = grant.verification_uri_complete orelse grant.verification_uri;
    if (notify) |sink| sink.show(sink.ctx, verification, grant.user_code);
    if (open_browser) auth.openBrowser(allocator, verification) catch {};

    const token_url = try tokenUrl(site, &endpoint_buf);
    const started = util_time.nowUnix();
    const deadline = grant.expires_at orelse started + grant.expires_in;
    var interval = @min(grant.interval, 60);
    while (util_time.nowUnix() < deadline) {
        try waitPollInterval(interval, abort_signal);
        const poll_body = try deviceTokenRequestBody(allocator, grant.device_code);
        defer allocator.free(poll_body);
        const response = try postJson(allocator, io, token_url, poll_body);
        if (response.ok) return response.body;
        defer allocator.free(response.body);
        switch (parsePollError(response.body)) {
            error.AuthorizationPending => {},
            error.SlowDown => interval = @min(interval + 5, 60),
            error.ExpiredToken => return error.ExpiredToken,
            error.AccessDenied => return error.AccessDenied,
            error.InvalidGrant => return error.InvalidGrant,
            else => return error.RequestFailed,
        }
    }
    return error.TimedOut;
}

/// Sleep `seconds` in 100 ms steps, returning `error.Aborted` as soon as the
/// signal fires.
fn waitPollInterval(seconds: u32, abort_signal: ?*const AbortSignal) error{Aborted}!void {
    const total_ms = @as(u64, seconds) * 1000;
    var waited: u64 = 0;
    while (waited < total_ms) : (waited += 100) {
        if (abort_signal) |signal| try signal.throwIfAborted();
        util_time.sleepMs(@min(100, total_ms - waited));
    }
    if (abort_signal) |signal| try signal.throwIfAborted();
}

const RawResponse = struct { ok: bool, status: u16, body: []u8 };

fn postJson(allocator: std.mem.Allocator, io: std.Io, url: []const u8, body: []const u8) !RawResponse {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    // The device and token grants travel in the body; only the endpoint
    // that received one can answer it.
    var request = client.request(.POST, uri, .{ .redirect_behavior = http_status.no_redirects, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json" },
    } }) catch return error.RequestFailed;
    defer request.deinit();
    http_connection.sendBodyComplete(&request, @constCast(body)) catch return error.RequestFailed;
    var redirect: [4096]u8 = undefined;
    const response = request.receiveHead(&redirect) catch return error.RequestFailed;
    const status = http_status.ResponseStatus.capture(&response);
    var transfer: [8192]u8 = undefined;
    const payload = request.reader.bodyReader(&transfer, response.head.transfer_encoding, response.head.content_length)
        .allocRemaining(allocator, std.Io.Limit.limited(256 * 1024)) catch return error.RequestFailed;
    return .{ .ok = status.code >= 200 and status.code < 300, .status = status.code, .body = payload };
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
        .integer => |n| n,
        else => null,
    };
}

fn errorCode(body: []const u8) ?[]const u8 {
    const key = "\"error\"";
    const start = std.mem.indexOf(u8, body, key) orelse return null;
    var i = start + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == ':')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const end = std.mem.indexOfScalarPos(u8, body, i, '"') orelse return null;
    return body[i..end];
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try util_json.serializeString(value, out, allocator);
}

test "every Metask grant is JSON and names the client; the device request asks for model access (#527)" {
    const a = std.testing.allocator;
    const initial = try deviceRequestBody(a);
    defer a.free(initial);
    try std.testing.expectEqualStrings("{\"client_id\":\"metacodes\",\"scope\":\"read model:invoke\"}", initial);
    const poll = try deviceTokenRequestBody(a, "dev");
    defer a.free(poll);
    try std.testing.expectEqualStrings("{\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\",\"device_code\":\"dev\",\"client_id\":\"metacodes\"}", poll);
    const refresh = try refreshRequestBody(a, "mrt-old");
    defer a.free(refresh);
    try std.testing.expectEqualStrings("{\"grant_type\":\"refresh_token\",\"refresh_token\":\"mrt-old\",\"client_id\":\"metacodes\"}", refresh);
    try std.testing.expect(isGatewayOrigin("http://localhost:9000/"));
    try std.testing.expect(!isGatewayOrigin("http://localhost:9000/v1/messages"));
}

test "sign-out revokes with the refresh token, hinted, as the metacodes client (#527)" {
    const a = std.testing.allocator;
    const body = try revokeRequestBody(a, "mrt-a&b");
    defer a.free(body);
    try std.testing.expectEqualStrings("token=mrt-a%26b&token_type_hint=refresh_token&client_id=metacodes", body);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://www.metask-ai.com/api/oauth/revoke", try revokeUrl(DEFAULT_SITE_URL, &buffer));
}

test "with no Metask session stored, sign-out has nothing to revoke and sends nothing (#527)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    // A dead port: were anything sent, it would be refused, not answered.
    try std.testing.expectEqual(RevokeOutcome.nothing_stored, revokeStoredSession(root_buf[0..root_len], "http://127.0.0.1:9", 1000));
}

test "the device flow talks to www, not the bare host that redirects every request (#527)" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://www.metask-ai.com/api/oauth/device/code", try deviceCodeUrl(DEFAULT_SITE_URL, &buffer));
    try std.testing.expectEqualStrings("https://www.metask-ai.com/api/oauth/token", try tokenUrl(DEFAULT_SITE_URL, &buffer));
}

test "Metask device response and poll errors parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grant = try parseDeviceCode(arena.allocator(), "{\"device_code\":\"dev\",\"user_code\":\"ABCD\",\"verification_uri\":\"https://metask-ai.com/device\",\"verification_uri_complete\":\"https://metask-ai.com/device?code=ABCD\",\"expires_in\":900,\"interval\":7,\"expires_at\":1234}");
    try std.testing.expectEqualStrings("ABCD", grant.user_code);
    try std.testing.expectEqual(@as(u32, 7), grant.interval);
    try std.testing.expectEqual(error.AuthorizationPending, parsePollError("{\"error\":\"authorization_pending\"}"));
    try std.testing.expectEqual(error.InvalidGrant, parsePollError("{\"error\":\"invalid_grant\"}"));
}

test "the device poll wait ends early on abort" {
    var signal = AbortSignal.init();
    signal.abort(.user_interrupt);
    const started = util_time.nowMs();
    try std.testing.expectError(error.Aborted, waitPollInterval(5, &signal));
    try std.testing.expect(util_time.nowMs() - started < 1000);
    try waitPollInterval(0, null);
}
