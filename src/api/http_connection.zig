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
//! Every request in `src/` sends through these two functions instead of the
//! `Request` methods of the same names; a source guard in
//! tests/component/http_send_failure_test.zig keeps it that way.

const std = @import("std");

const Request = std.http.Client.Request;

/// The codings a request accepts: identity only (see the module comment).
const identity_only = blk: {
    var codings: @TypeOf(Request.default_accept_encoding) = @splat(false);
    codings[@intFromEnum(std.http.ContentEncoding.identity)] = true;
    break :blk codings;
};

/// `request.sendBodyComplete(body)`. A connection the send failed on is closed
/// by `Request.deinit` instead of being pooled. The request accepts an
/// uncompressed answer only.
pub fn sendBodyComplete(request: *Request, body: []u8) std.Io.Writer.Error!void {
    acceptIdentityOnly(request);
    request.sendBodyComplete(body) catch |err| return dropConnection(request, err);
}

/// `request.sendBodiless()`, with the same rules as `sendBodyComplete`.
pub fn sendBodiless(request: *Request) std.Io.Writer.Error!void {
    acceptIdentityOnly(request);
    request.sendBodiless() catch |err| return dropConnection(request, err);
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
