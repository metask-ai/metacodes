const std = @import("std");

/// Process-owned view of an HTTP response status.
///
/// `std.http.Status` models a protocol value with an open wire domain as a
/// non-exhaustive enum. It must not escape this boundary: unnamed values are
/// valid HTTP responses, but operations such as `@tagName` can panic on them.
pub const ResponseStatus = struct {
    code: u16,
    name: []const u8,

    /// The only production conversion from std's wire-facing response type.
    pub fn capture(response: *const std.http.Client.Response) ResponseStatus {
        return fromStd(response.head.status);
    }

    pub fn isOk(self: ResponseStatus) bool {
        return self.code == 200;
    }

    fn fromStd(status: std.http.Status) ResponseStatus {
        return .{
            .code = @intFromEnum(status),
            .name = std.enums.tagName(std.http.Status, status) orelse "unknown",
        };
    }
};

/// Whether the answer with this head carries a body. A 1xx, 204 or 304 one
/// never does (RFC 9110 §15.2, §15.3.5, §15.4.5), yet std 0.16's
/// `receiveHead` returns it without marking its body empty, and a body reader
/// for it reads to the end of the connection (#573).
pub fn answerHasBody(head: *const std.http.Client.Response.Head) bool {
    const status = head.status;
    return !(status.class() == .informational or status == .no_content or status == .not_modified);
}

/// The redirect policy of every request that carries a credential or a body:
/// none. A 3xx comes back as the response and is reported like any other
/// non-2xx answer.
///
/// std's client re-sends `extra_headers` on every hop, to whatever host
/// `Location` names — an Authorization, `x-api-key` or `x-goog-api-key`
/// header went with it — and in 0.16 it never sends the `privileged_headers`
/// it would strip across domains, so there is no header it is safe to follow
/// with. It also turns a POST answered 301/302/303 into a body-less GET, which
/// no API here serves: a token endpoint "answered" by a host that never
/// received the grant is not a token response.
pub const no_redirects: std.http.Client.Request.RedirectBehavior = .unhandled;

/// How much of a Location the provider clients keep. One at this length may
/// have been cut.
pub const REDIRECT_LOCATION_BYTES = 256;

/// Where a 3xx answer points, copied into `buffer` (cut to its length), or
/// null for any other status. Call it before reading the body: the head's
/// bytes live in the connection buffer the body overwrites.
pub fn copyRedirectLocation(response: *const std.http.Client.Response, buffer: []u8) ?[]const u8 {
    const code = @intFromEnum(response.head.status);
    if (code < 300 or code >= 400) return null;
    const location = response.head.location orelse return null;
    const n = @min(location.len, buffer.len);
    @memcpy(buffer[0..n], location[0..n]);
    return buffer[0..n];
}

test "ResponseStatus captures named and unnamed wire values without panic" {
    const ok = ResponseStatus.fromStd(.ok);
    try std.testing.expectEqual(@as(u16, 200), ok.code);
    try std.testing.expectEqualStrings("ok", ok.name);
    try std.testing.expect(ok.isOk());

    const unauthorized = ResponseStatus.fromStd(.unauthorized);
    try std.testing.expectEqual(@as(u16, 401), unauthorized.code);
    try std.testing.expectEqualStrings("unauthorized", unauthorized.name);
    try std.testing.expect(!unauthorized.isOk());

    const unnamed = ResponseStatus.fromStd(@enumFromInt(529));
    try std.testing.expectEqual(@as(u16, 529), unnamed.code);
    try std.testing.expectEqualStrings("unknown", unnamed.name);
    try std.testing.expect(!unnamed.isOk());
}

test "ResponseStatus conversion is total across the HTTP response range" {
    var code: u16 = 100;
    while (code <= 599) : (code += 1) {
        const status = ResponseStatus.fromStd(@enumFromInt(code));
        try std.testing.expectEqual(code, status.code);
        try std.testing.expect(status.name.len > 0);
    }
}

test "answerHasBody: a 1xx, 204 or 304 answer has none" {
    const cases = [_]struct { head: []const u8, has_body: bool }{
        .{ .head = "HTTP/1.1 204 No Content\r\n\r\n", .has_body = false },
        .{ .head = "HTTP/1.1 304 Not Modified\r\n\r\n", .has_body = false },
        .{ .head = "HTTP/1.1 100 Continue\r\n\r\n", .has_body = false },
        .{ .head = "HTTP/1.1 103 Early Hints\r\n\r\n", .has_body = false },
        .{ .head = "HTTP/1.1 200 OK\r\n\r\n", .has_body = true },
        .{ .head = "HTTP/1.1 404 Not Found\r\n\r\n", .has_body = true },
        .{ .head = "HTTP/1.1 500 Internal Server Error\r\n\r\n", .has_body = true },
        .{ .head = "HTTP/1.1 599 Unnamed\r\n\r\n", .has_body = true },
    };
    for (cases) |case| {
        const head = try std.http.Client.Response.Head.parse(case.head);
        try std.testing.expectEqual(case.has_body, answerHasBody(&head));
    }
}
