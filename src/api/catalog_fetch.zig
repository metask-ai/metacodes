//! Provider catalog fetching (issue #16, delivery slice P1).
//!
//! `provider/host.zig` ingests catalog *documents* and deliberately cannot
//! fetch them: the provider subsystem must not depend on a transport, which is
//! what keeps `zig build test:provider` able to compile it from a root reaching
//! only `std`, `types.zig`, `util/model.zig`, and `platform`.
//!
//! This is the fetching half. It performs plain authenticated GETs and hands
//! the bytes back; the parsing, offer construction, and events are identical to
//! ingesting the same document from disk, so a catalog refreshed over the
//! network and one refreshed by `curl > file` produce the same offers.

const std = @import("std");
const http_status = @import("http_status.zig");

pub const FetchError = error{
    OutOfMemory,
    InvalidUrl,
    RequestFailed,
    /// A non-2xx answer. The status is reported so a caller can distinguish an
    /// expired key from an outage instead of retrying both the same way.
    HttpError,
    /// Larger than a catalog has any business being. An unbounded read from a
    /// URL in a config file is a memory-exhaustion vector.
    TooLarge,
};

/// Documents above this are refused. OpenRouter's full `/models` is a few
/// hundred kilobytes; 8 MB is generous and still bounded.
pub const MAX_DOCUMENT_BYTES: usize = 8 * 1024 * 1024;

pub const Request = struct {
    url: []const u8,
    /// Optional bearer credential. Catalog endpoints are usually public;
    /// per-account pricing needs one.
    bearer: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    /// Owned by the caller.
    body: []u8,
};

/// GET one catalog document.
pub fn fetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
) FetchError!Response {
    const uri = std.Uri.parse(request.url) catch return error.InvalidUrl;

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var authorization: ?[]u8 = null;
    defer if (authorization) |value| {
        std.crypto.secureZero(u8, value);
        allocator.free(value);
    };
    var headers: [2]std.http.Header = undefined;
    var header_count: usize = 0;
    headers[header_count] = .{ .name = "accept", .value = "application/json" };
    header_count += 1;
    if (request.bearer) |secret| {
        authorization = std.fmt.allocPrint(allocator, "Bearer {s}", .{secret}) catch
            return error.OutOfMemory;
        headers[header_count] = .{ .name = "authorization", .value = authorization.? };
        header_count += 1;
    }

    var http_request = client.request(.GET, uri, .{
        .extra_headers = headers[0..header_count],
    }) catch return error.RequestFailed;
    defer http_request.deinit();

    http_request.sendBodiless() catch return error.RequestFailed;
    var redirect_buffer: [4096]u8 = undefined;
    const response = http_request.receiveHead(&redirect_buffer) catch return error.RequestFailed;
    const status = http_status.ResponseStatus.capture(&response);

    var transfer_buffer: [16384]u8 = undefined;
    const reader = http_request.reader.bodyReader(
        &transfer_buffer,
        response.head.transfer_encoding,
        response.head.content_length,
    );
    const body = reader.allocRemaining(allocator, std.Io.Limit.limited(MAX_DOCUMENT_BYTES)) catch
        return error.TooLarge;
    errdefer allocator.free(body);

    if (status.code < 200 or status.code >= 300) {
        allocator.free(body);
        return error.HttpError;
    }
    return .{ .status = status.code, .body = body };
}
