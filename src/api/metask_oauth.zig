//! Metask OAuth device-code exchange.
//!
//! Metask intentionally differs from the generic RFC 8628 helper: both grants
//! are JSON, the client id is fixed to `metacodes`, and refresh requests must
//! not include a client_id.  Keeping this transport separate makes those wire
//! rules auditable and prevents a generic provider from accidentally sending a
//! form body to the Metask control plane.

const std = @import("std");
const auth = @import("../core/auth.zig");
const oauth = @import("../provider/oauth.zig");
const http_status = @import("http_status.zig");
const util_time = @import("../util/time.zig");

pub const DEFAULT_SITE_URL = "https://metask-ai.com";
pub const CLIENT_ID = "metacodes";

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

pub fn deviceRequestBody(allocator: std.mem.Allocator, hostname: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"client_id\":\"metacodes\",\"client_name\":\"MetaCode on ");
    try appendJsonEscaped(allocator, &out, hostname);
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

/// The refresh grant is deliberately minimal.  In particular there is no
/// client_id field: Metask binds the rotated refresh token to the authorization
/// and presenting an extra client id is rejected by the contract.
pub fn refreshRequestBody(allocator: std.mem.Allocator, refresh_token: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "{\"grant_type\":\"refresh_token\",\"refresh_token\":");
    try appendJsonString(allocator, &out, refresh_token);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn deviceTokenRequestBody(allocator: std.mem.Allocator, device_code: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "{\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\",\"device_code\":");
    try appendJsonString(allocator, &out, device_code);
    try out.append(allocator, '}');
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

/// Run the device flow and return the raw success token JSON.  The callback is
/// called after the device response is parsed, before polling begins, so CLI
/// output is stable even when the first poll blocks.
pub fn acquireDeviceToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    site: []const u8,
    hostname: []const u8,
    open_browser: bool,
    notify: ?*const fn (uri: []const u8, code: []const u8) void,
) ![]u8 {
    var endpoint_buf: [1024]u8 = undefined;
    const device_url = try deviceCodeUrl(site, &endpoint_buf);
    const request_body = try deviceRequestBody(allocator, hostname);
    defer allocator.free(request_body);
    const initial = try postJson(allocator, io, device_url, request_body);
    defer allocator.free(initial.body);
    if (!initial.ok) return parsePollError(initial.body);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const grant = try parseDeviceCode(arena.allocator(), initial.body);
    const verification = grant.verification_uri_complete orelse grant.verification_uri;
    if (notify) |write| write(verification, grant.user_code);
    if (open_browser) auth.openBrowser(allocator, verification) catch {};

    const token_url = try tokenUrl(site, &endpoint_buf);
    const started = util_time.nowUnix();
    const deadline = grant.expires_at orelse started + grant.expires_in;
    var interval = @min(grant.interval, 60);
    while (util_time.nowUnix() < deadline) {
        util_time.sleepMs(@as(u64, interval) * 1000);
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

const RawResponse = struct { ok: bool, status: u16, body: []u8 };

fn postJson(allocator: std.mem.Allocator, io: std.Io, url: []const u8, body: []const u8) !RawResponse {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = client.request(.POST, uri, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json" },
    } }) catch return error.RequestFailed;
    defer request.deinit();
    request.sendBodyComplete(@constCast(body)) catch return error.RequestFailed;
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
    try out.append(allocator, '"');
    try appendJsonEscaped(allocator, out, value);
    try out.append(allocator, '"');
}

fn appendJsonEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, byte),
    };
}

test "Metask grants use JSON and refresh omits client_id" {
    const a = std.testing.allocator;
    const initial = try deviceRequestBody(a, "host");
    defer a.free(initial);
    try std.testing.expectEqualStrings("{\"client_id\":\"metacodes\",\"client_name\":\"MetaCode on host\"}", initial);
    const refresh = try refreshRequestBody(a, "mrt-old");
    defer a.free(refresh);
    try std.testing.expectEqualStrings("{\"grant_type\":\"refresh_token\",\"refresh_token\":\"mrt-old\"}", refresh);
    try std.testing.expect(std.mem.indexOf(u8, refresh, "client_id") == null);
    try std.testing.expect(isGatewayOrigin("http://localhost:9000/"));
    try std.testing.expect(!isGatewayOrigin("http://localhost:9000/v1/messages"));
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
