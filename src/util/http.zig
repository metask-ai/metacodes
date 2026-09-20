//! Request-head parsing shared by the local HTTP servers Metacodes runs (the
//! `--web` UI and the `kgd` TinyKG supervisor). Pure functions over bytes: no
//! sockets, no allocation, no policy. Two servers parsing headers two slightly
//! different ways is how one of them ends up with a header-smuggling bug.

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

/// Read `name` out of `a=1&b=2`. No URL decoding: callers use numeric values.
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

const testing = std.testing;

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
