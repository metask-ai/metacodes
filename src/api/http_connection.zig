//! Sending a std.http request without handing a broken connection back to the
//! client's pool, and without accepting a body its caller cannot read.
//!
//! `Request.deinit` (Zig 0.16) returns the connection to the pool unless it is
//! marked `closing`, and it counts a request that never received a response
//! head (`reader.state == .ready`) as reusable. `receiveHead` marks the
//! connection when its read fails; a failed send marks nothing. A connection
//! the peer reset in the middle of a request body therefore goes back to the
//! pool, the next request to that host takes it again, its first write fails
//! at once, and so does every retry after it: the client never opens another
//! connection for the rest of the process. `keep_alive = false` does not
//! prevent it, because std applies that option only once a head arrives.
//!
//! Seen 2026-10-29: a 2.5 MB Messages request cut off 71 s into its upload
//! left a TUI failing every later request in 4 ms, ten retries a message, with
//! no new TCP connection, while a fresh process on the same network worked.
//!
//! Content coding (#467). A std.http request accepts `gzip` and `deflate`
//! answers by default: it advertises them in `accept-encoding`, and
//! `receiveHead` takes an answer in either. Nothing in `src/` decodes one.
//! Every body is read as sent, through `Response.reader` or
//! `Reader.bodyReader`, which return the bytes as they are on the wire.
//! DeepSeek honoured the default: the SSE line reader got gzip, found no
//! event in it, and every stream ended as `StreamIncomplete`. Error bodies
//! were just as unreadable, so an overflow was not seen as one. The model
//! clients now omit the header (#468), but that alone leaves the set
//! `receiveHead` checks the answer against at gzip and deflate. Both functions
//! below make a request accept the identity coding only, so a server that
//! compresses anyway fails there, with `error.HttpContentEncodingUnsupported`,
//! before any parser sees the body.
//!
//! Identity. A request whose caller names no `user-agent` says it is
//! metacodes (`metacodes/<semver>`), not std's `zig/<version> (std.http)`.
//! Vendors tell coding tools apart by this header, some of them refuse a
//! client they do not recognise, and their terms forbid a forged one (Kimi
//! Code's community guidelines, for one); an honest name is the only one a
//! vendor can be asked to admit. A caller's own `.override` or `.omit` stays
//! as it is (the OTLP exporter names itself `metacodes-otlp`).
//!
//! Every request in `src/` sends through these two functions instead of the
//! `Request` methods of the same names; a source guard in
//! tests/component/http_send_failure_test.zig keeps it that way.
//!
//! Connection (#573). The model clients ask the server to keep the
//! connection open, and close it themselves. They set `keep_alive = false`,
//! so std closes the socket in `Request.deinit` and never pools it (a stale
//! pooled connection is what that option avoids). At `.default`, though, std
//! also writes `connection: close`, and a server told so closes right after
//! the last byte. Behind a transparent proxy that close can overtake bytes the
//! proxy has not forwarded yet: on 2026-11-18 it cut the end off 3% to 23% of
//! real Responses streams, and the end was the terminal event, so the whole
//! turn was sent again and charged again. `keepServerOpen` makes those
//! requests say `connection: keep-alive` instead: the server leaves the
//! connection open, the client reads what it needs (a stream's terminal event,
//! or the end of a framed body) and closes it.

const std = @import("std");
const version = @import("../version.zig");
const http_status = @import("http_status.zig");

const Request = std.http.Client.Request;
const Response = std.http.Client.Response;

/// What a request says it is when its caller names nothing else.
pub const user_agent = "metacodes/" ++ version.semver;

/// The codings a request accepts: identity only (see the module comment).
const identity_only = blk: {
    var codings: @TypeOf(Request.default_accept_encoding) = @splat(false);
    codings[@intFromEnum(std.http.ContentEncoding.identity)] = true;
    break :blk codings;
};

/// `request.sendBodyComplete(body)`. A connection the send failed on is closed
/// by `Request.deinit` instead of being pooled. The request accepts an
/// uncompressed answer only, and says it is metacodes unless its caller named
/// itself.
pub fn sendBodyComplete(request: *Request, body: []u8) std.Io.Writer.Error!void {
    acceptIdentityOnly(request);
    identify(request);
    request.sendBodyComplete(body) catch |err| return dropConnection(request, err);
}

/// `request.sendBodiless()`, with the same rules as `sendBodyComplete`.
pub fn sendBodiless(request: *Request) std.Io.Writer.Error!void {
    acceptIdentityOnly(request);
    identify(request);
    request.sendBodiless() catch |err| return dropConnection(request, err);
}

pub fn receiveHead(request: *Request, redirect_buffer: []u8) Request.ReceiveHeadError!Response {
    const response = try request.receiveHead(redirect_buffer);
    if (!http_status.answerHasBody(&response.head)) {
        if (request.connection) |connection| connection.closing = true;
    }
    return response;
}

pub fn bodyReader(response: *const Response, transfer_buffer: []u8) *std.Io.Reader {
    const request = response.request;
    const head = &response.head;
    if (!request.method.responseHasBody() or !http_status.answerHasBody(head))
        return request.reader.bodyReader(transfer_buffer, .none, 0);
    return request.reader.bodyReader(transfer_buffer, head.transfer_encoding, head.content_length);
}

/// Make a request say `connection: keep-alive` while its `keep_alive = false`
/// still closes the connection after one answer (see the module comment,
/// #573). A caller's own `.omit` or `.override` stays as it is, and so does a
/// `connection` line among its `extra_headers`: that line is then the only one.
pub fn keepServerOpen(request: *Request) void {
    request.headers.connection = connectionHeader(request.headers.connection, request.extra_headers);
}

fn connectionHeader(current: Request.Headers.Value, extra_headers: []const std.http.Header) Request.Headers.Value {
    if (current != .default) return current;
    for (extra_headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) return .omit;
    }
    return .{ .override = "keep-alive" };
}

/// At `.default`, std writes `zig/<version> (std.http)`; name metacodes
/// instead. A caller's `.omit` or `.override` stays as it is.
fn identify(request: *Request) void {
    if (request.headers.user_agent == .default)
        request.headers.user_agent = .{ .override = user_agent };
}

fn acceptIdentityOnly(request: *Request) void {
    request.accept_encoding = identity_only;
    // At `.default`, Zig 0.16.0 writes an identity-only set as a bare
    // `accept-encoding` line with no colon and no value; name the coding
    // instead. A caller's `.omit` or `.override` stays as it is.
    if (request.headers.accept_encoding == .default)
        request.headers.accept_encoding = .{ .override = "identity" };
}

fn dropConnection(request: *Request, err: std.Io.Writer.Error) std.Io.Writer.Error {
    if (request.connection) |connection| connection.closing = true;
    return err;
}

test "keepServerOpen: a request whose caller names no connection says keep-alive" {
    try std.testing.expectEqualStrings("keep-alive", connectionHeader(.default, &.{}).override);
    const others = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
    try std.testing.expectEqualStrings("keep-alive", connectionHeader(.default, &others).override);
}

test "keepServerOpen: a caller's own connection header stays the only one" {
    try std.testing.expect(connectionHeader(.omit, &.{}) == .omit);
    try std.testing.expectEqualStrings("close", connectionHeader(.{ .override = "close" }, &.{}).override);
    const own = [_]std.http.Header{.{ .name = "Connection", .value = "close" }};
    try std.testing.expect(connectionHeader(.default, &own) == .omit);
}
