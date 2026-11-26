//! Request-head parsing shared by the local HTTP servers Metacodes runs (the
//! `--web`/`serve` UI and the `kgd` TinyKG supervisor), and the credential
//! comparison both use. Pure functions over bytes: no sockets, no allocation,
//! no policy. Two servers parsing headers two slightly different ways is how
//! one of them ends up with a header-smuggling bug.

const std = @import("std");

pub const RequestLine = struct {
    method: []const u8,
    path: []const u8,
    /// Without the '?'. No query string is the empty slice.
    query: []const u8,
};

/// Parse `METHOD /path?query HTTP/1.1`, the first line of the head.
pub fn parseRequestLine(head: []const u8) ?RequestLine {
    const eol = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const first = head[0..eol];
    var it = std.mem.splitScalar(u8, first, ' ');
    const method = it.next() orelse return null;
    const target = it.next() orelse return null;
    if (method.len == 0 or target.len == 0) return null;
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        return .{ .method = method, .path = target[0..q], .query = target[q + 1 ..] };
    }
    return .{ .method = method, .path = target, .query = "" };
}

/// Read `name` out of `a=1&b=2`, still percent-encoded: a caller that needs
/// the decoded value (a credential) runs it through `percentDecode`.
pub fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.ascii.eqlIgnoreCase(pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// Case-insensitive header lookup, leading and trailing blanks trimmed. The
/// first occurrence wins; a duplicated header is not merged, so a smuggled
/// second copy cannot extend the first one's value.
pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // skip the request line
    while (it.next()) |h| {
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(h[0..colon], name)) continue;
        return std.mem.trim(u8, h[colon + 1 ..], " \t");
    }
    return null;
}

pub fn parseContentLength(head: []const u8) ?usize {
    const v = headerValue(head, "content-length") orelse return null;
    return std.fmt.parseInt(usize, v, 10) catch null;
}

/// Decode the `%XX` escapes of a query value into `out`. `+` stays `+`: the
/// values decoded here (credentials) never contain a space, and a browser's
/// `encodeURIComponent` sends a literal `+` as `%2B`. Null when an escape is
/// malformed or the result does not fit `out`.
pub fn percentDecode(encoded: []const u8, out: []u8) ?[]const u8 {
    var in: usize = 0;
    var len: usize = 0;
    while (in < encoded.len) : (len += 1) {
        if (len == out.len) return null;
        if (encoded[in] != '%') {
            out[len] = encoded[in];
            in += 1;
            continue;
        }
        if (encoded.len - in < 3) return null;
        const high = std.fmt.charToDigit(encoded[in + 1], 16) catch return null;
        const low = std.fmt.charToDigit(encoded[in + 2], 16) catch return null;
        out[len] = high * 16 + low;
        in += 3;
    }
    return out[0..len];
}

/// Compares in time independent of how many leading bytes match, so a peer
/// cannot discover a key one byte at a time (only its length). An empty
/// `expected` never matches: a server whose key is empty must not admit a
/// peer that sent no credential at all.
pub fn constantTimeEql(presented: []const u8, expected: []const u8) bool {
    if (presented.len != expected.len or expected.len == 0) return false;
    var diff: u8 = 0;
    for (presented, expected) |a, b| diff |= a ^ b;
    return diff == 0;
}

const testing = std.testing;

test "Http: credential comparison is length-safe and never matches an empty key" {
    try testing.expect(constantTimeEql("abc", "abc"));
    try testing.expect(!constantTimeEql("abc", "abd"));
    try testing.expect(!constantTimeEql("ab", "abc"));
    // An empty configured key must never authenticate anyone, including a peer
    // that sends no credential at all (which arrives here as "").
    try testing.expect(!constantTimeEql("", ""));
}

test "Http: percentDecode decodes escapes, keeps +, refuses malformed or oversized input" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("a+b/c=", percentDecode("a+b%2Fc%3d", &buf).?);
    try testing.expectEqualStrings("plain", percentDecode("plain", &buf).?);
    try testing.expectEqualStrings("", percentDecode("", &buf).?);
    try testing.expect(percentDecode("%4", &buf) == null);
    try testing.expect(percentDecode("%zz", &buf) == null);
    try testing.expect(percentDecode("abc%", &buf) == null);
    var small: [3]u8 = undefined;
    try testing.expectEqualStrings("abc", percentDecode("abc", &small).?);
    try testing.expect(percentDecode("abcd", &small) == null);
    try testing.expect(percentDecode("ab%41%42", &small) == null);
}

test "Http: the request line splits method, path and query" {
    const line = parseRequestLine("POST /api/run?since=3 HTTP/1.1\r\nhost: x\r\n\r\n").?;
    try testing.expectEqualStrings("POST", line.method);
    try testing.expectEqualStrings("/api/run", line.path);
    try testing.expectEqualStrings("since=3", line.query);
    const bare = parseRequestLine("GET /api/ready HTTP/1.1\r\n").?;
    try testing.expectEqualStrings("/api/ready", bare.path);
    try testing.expectEqualStrings("", bare.query);
    try testing.expect(parseRequestLine("GET") == null);
}

test "Http: header lookup ignores case and takes the first occurrence" {
    const head = "POST / HTTP/1.1\r\nX-Api-Key:  secret \r\nx-api-key: other\r\nContent-Length: 12\r\n\r\n";
    try testing.expectEqualStrings("secret", headerValue(head, "x-api-key").?);
    try testing.expectEqual(@as(?usize, 12), parseContentLength(head));
    try testing.expect(headerValue(head, "authorization") == null);
    // The request line is never mistaken for a header.
    try testing.expect(headerValue("GET /a:b HTTP/1.1\r\n\r\n", "GET /a") == null);
}

test "Http: a malformed content length is absent, not zero" {
    try testing.expect(parseContentLength("POST / HTTP/1.1\r\ncontent-length: abc\r\n\r\n") == null);
    try testing.expect(parseContentLength("POST / HTTP/1.1\r\n\r\n") == null);
}
