//! HTTP token exchange for provider-scoped OAuth (issue #16, delivery slice P1).
//!
//! `provider/oauth.zig` owns the lifecycle — expiry margin, single flight,
//! rotated-refresh persistence — and deliberately performs no I/O, so it stays
//! inside the provider subsystem's dependency boundary. This is the other half:
//! the RFC 6749 `refresh_token` grant over real HTTP, supplied to that module
//! as a function pointer.
//!
//! Keeping the split means every lifecycle test drives a fake exchange and no
//! test needs a network, while the production path is one small, auditable
//! function.

const std = @import("std");
const oauth = @import("../provider/oauth.zig");
const ids = @import("../provider/ids.zig");
const http_status = @import("http_status.zig");
const metask_oauth = @import("metask_oauth.zig");

pub const Slug = ids.Slug;

/// Where to exchange, and as whom. Borrowed for the duration of the call.
pub const Endpoint = struct {
    token_url: []const u8,
    client_id: []const u8,
};

pub const HttpExchange = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: Endpoint,

    pub fn exchange(self: *HttpExchange) oauth.Exchange {
        return .{ .ctx = @ptrCast(self), .run = run };
    }

    fn run(
        ctx: *anyopaque,
        _: Slug,
        refresh_token: []const u8,
        arena: std.mem.Allocator,
    ) oauth.OAuthError!oauth.RefreshOutcome {
        const self: *HttpExchange = @ptrCast(@alignCast(ctx));

        const body = buildFormBody(arena, self.endpoint.client_id, refresh_token) catch
            return error.OutOfMemory;
        const uri = std.Uri.parse(self.endpoint.token_url) catch return error.RefreshFailed;

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var request = client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
                .{ .name = "accept", .value = "application/json" },
            },
        }) catch return error.RefreshFailed;
        defer request.deinit();

        request.sendBodyComplete(@constCast(body)) catch return error.RefreshFailed;
        var redirect_buffer: [4096]u8 = undefined;
        const response = request.receiveHead(&redirect_buffer) catch return error.RefreshFailed;
        // The wire status crosses into process code only through this boundary:
        // `std.http.Status` is non-exhaustive, and an unnamed-but-valid status
        // would panic on `@tagName`.
        const status = http_status.ResponseStatus.capture(&response);

        var transfer_buffer: [8192]u8 = undefined;
        const reader = request.reader.bodyReader(
            &transfer_buffer,
            response.head.transfer_encoding,
            response.head.content_length,
        );
        const payload = reader.allocRemaining(arena, std.Io.Limit.limited(256 * 1024)) catch
            return error.RefreshFailed;

        // A non-2xx answer is classified by the provider's own rule: an
        // `invalid_grant` is terminal (the user must log in again) and must not
        // be retried as though the network hiccuped.
        // Any 2xx is a successful grant. `isOk()` is 200-only, and a token
        // endpoint answering 201 is unusual but not a failure.
        if (status.code < 200 or status.code >= 300) return oauth.classifyTokenError(status.code, payload);
        return oauth.parseTokenResponse(arena, payload);
    }
};

/// Metask's JSON refresh exchange. Unlike RFC 6749 form exchanges this sends
/// exactly `{grant_type,refresh_token}`; the client id is intentionally absent.
pub const MetaskHttpExchange = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    token_url: []const u8,

    pub fn exchange(self: *MetaskHttpExchange) oauth.Exchange {
        return .{ .ctx = @ptrCast(self), .run = run };
    }

    fn run(ctx: *anyopaque, _: Slug, refresh_token: []const u8, arena: std.mem.Allocator) oauth.OAuthError!oauth.RefreshOutcome {
        const self: *MetaskHttpExchange = @ptrCast(@alignCast(ctx));
        const body = metask_oauth.refreshRequestBody(arena, refresh_token) catch
            return error.OutOfMemory;
        const uri = std.Uri.parse(self.token_url) catch return error.RefreshFailed;
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        var request = client.request(.POST, uri, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json" },
        } }) catch return error.RefreshFailed;
        defer request.deinit();
        request.sendBodyComplete(body) catch return error.RefreshFailed;
        var redirect: [4096]u8 = undefined;
        const response = request.receiveHead(&redirect) catch return error.RefreshFailed;
        const status = http_status.ResponseStatus.capture(&response);
        var transfer: [8192]u8 = undefined;
        const payload = request.reader.bodyReader(&transfer, response.head.transfer_encoding, response.head.content_length)
            .allocRemaining(arena, std.Io.Limit.limited(256 * 1024)) catch return error.RefreshFailed;
        if (status.code < 200 or status.code >= 300) return oauth.classifyTokenError(status.code, payload);
        const outcome = try oauth.parseTokenResponse(arena, payload);
        // Metask invalidates the presented refresh token and returns a new one
        // on every successful refresh. Treating an omitted field as "keep the
        // old token" (the generic RFC-6749 behavior) would persist a dead
        // token and turn the next refresh into an avoidable re-login.
        if (outcome.refresh_token == null) return error.MalformedTokenResponse;
        return outcome;
    }
};

fn buildFormBody(
    arena: std.mem.Allocator,
    client_id: []const u8,
    refresh_token: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "grant_type=refresh_token&client_id=");
    try appendEncoded(arena, &out, client_id);
    try out.appendSlice(arena, "&refresh_token=");
    try appendEncoded(arena, &out, refresh_token);
    return out.items;
}

fn appendEncoded(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        const unreserved = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '.' or byte == '_' or byte == '~';
        if (unreserved) {
            try out.append(arena, byte);
        } else {
            const escaped = try std.fmt.allocPrint(arena, "%{X:0>2}", .{byte});
            try out.appendSlice(arena, escaped);
        }
    }
}

test "the form body encodes a token that contains reserved characters" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = try buildFormBody(arena.allocator(), "app/one", "tok+en/with=chars&more");
    // An unencoded `&` would truncate the token and the server would report an
    // invalid grant for a token that is actually fine.
    try std.testing.expectEqualStrings(
        "grant_type=refresh_token&client_id=app%2Fone&refresh_token=tok%2Ben%2Fwith%3Dchars%26more",
        body,
    );
}

test "Metask refresh body is JSON and carries no client id" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ex = MetaskHttpExchange{ .allocator = a, .io = undefined, .token_url = "http://localhost/token" };
    _ = ex;
    // Keep this assertion transport-free; the exact helper is also exercised
    // by the production exchange before any socket is opened.
    const body = @import("metask_oauth.zig").refreshRequestBody(arena.allocator(), "mrt-1") catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, body, "client_id") == null);
}
