//! The URL arithmetic MCP's HTTP transports and authorization need, kept
//! lexical and testable: origins, well-known metadata locations (RFC 8414
//! §3.1, RFC 9728 §3.1), the canonical resource identifier (RFC 8707,
//! basic/authorization.mdx "Canonical Server URI") and relative references
//! (the HTTP+SSE `endpoint` event).

const std = @import("std");

pub const Parts = struct {
    /// Lowercase is not guaranteed; compare with `sameOrigin`.
    scheme: []const u8,
    /// `host[:port]`, userinfo included if the URL had one.
    authority: []const u8,
    /// Starts with `/` or is empty.
    path: []const u8,
    /// Without the `?`; empty when absent.
    query: []const u8,
};

/// Split an absolute `http(s)://` URL. Null for anything else.
pub fn split(url: []const u8) ?Parts {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;
    var rest = url[scheme_end + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '#')) |hash| rest = rest[0..hash];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0) return null;
    rest = rest[authority_end..];
    const query_start = std.mem.indexOfScalar(u8, rest, '?');
    return .{
        .scheme = scheme,
        .authority = authority,
        .path = if (query_start) |q| rest[0..q] else rest,
        .query = if (query_start) |q| rest[q + 1 ..] else "",
    };
}

/// `scheme://authority`, lowercased.
pub fn origin(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const parts = split(url) orelse return error.InvalidUrl;
    const out = try std.fmt.allocPrint(arena, "{s}://{s}", .{ parts.scheme, parts.authority });
    return std.ascii.lowerString(out, out);
}

pub fn sameOrigin(a: []const u8, b: []const u8) bool {
    const left = split(a) orelse return false;
    const right = split(b) orelse return false;
    return std.ascii.eqlIgnoreCase(left.scheme, right.scheme) and
        std.ascii.eqlIgnoreCase(hostPart(left), hostPart(right)) and
        (portOf(left) == portOf(right));
}

fn hostPart(parts: Parts) []const u8 {
    const authority = parts.authority;
    if (authority.len != 0 and authority[authority.len - 1] == ']') return authority; // [::1]
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return authority;
    return authority[0..colon];
}

fn portOf(parts: Parts) u16 {
    const authority = parts.authority;
    const default: u16 = if (std.ascii.eqlIgnoreCase(parts.scheme, "https")) 443 else 80;
    if (authority.len != 0 and authority[authority.len - 1] == ']') return default;
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return default;
    return std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch default;
}

/// The host without port or brackets, lowercased into `buffer`.
fn hostOf(parts: Parts, buffer: []u8) []const u8 {
    var host = parts.authority;
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (host.len != 0 and host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse host.len;
        host = host[1..close];
    } else if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        host = host[0..colon];
    }
    const len = @min(host.len, buffer.len);
    return std.ascii.lowerString(buffer[0..len], host[0..len]);
}

pub fn isLoopbackHost(url: []const u8) bool {
    const parts = split(url) orelse return false;
    var buffer: [256]u8 = undefined;
    const host = hostOf(parts, &buffer);
    return std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "::1") or isIpv4Loopback(host);
}

/// A dotted-quad literal in 127.0.0.0/8 — not a DNS name that merely starts
/// with `127.` (`127.attacker.example`).
fn isIpv4Loopback(host: []const u8) bool {
    var octets = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    while (octets.next()) |octet| : (count += 1) {
        if (octet.len == 0 or octet.len > 3) return false;
        const value = std.fmt.parseInt(u8, octet, 10) catch return false;
        if (count == 0 and value != 127) return false;
    }
    return count == 4;
}

/// Authorization endpoints must be HTTPS (basic/authorization.mdx
/// "Communication Security"); plain HTTP is accepted on loopback only.
pub fn isSecureEndpoint(url: []const u8) bool {
    const parts = split(url) orelse return false;
    if (std.ascii.eqlIgnoreCase(parts.scheme, "https")) return true;
    return isLoopbackHost(url);
}

/// RFC 8707 resource for an MCP server URL: lowercase scheme and host, no
/// fragment, no trailing slash on a bare origin.
pub fn canonicalResource(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const parts = split(url) orelse return error.InvalidUrl;
    var out: std.Io.Writer.Allocating = .init(arena);
    for (parts.scheme) |c| try out.writer.writeByte(std.ascii.toLower(c));
    try out.writer.writeAll("://");
    for (parts.authority) |c| try out.writer.writeByte(std.ascii.toLower(c));
    if (!std.mem.eql(u8, parts.path, "/")) try out.writer.writeAll(parts.path);
    if (parts.query.len != 0) {
        try out.writer.writeByte('?');
        try out.writer.writeAll(parts.query);
    }
    return out.written();
}

/// Whether a protected resource's advertised `resource` covers `server_url`
/// (RFC 9728 §3.3): same origin, and the server path lies under it.
pub fn resourceCovers(resource: []const u8, server_url: []const u8) bool {
    if (!sameOrigin(resource, server_url)) return false;
    const advertised = std.mem.trimEnd(u8, (split(resource) orelse return false).path, "/");
    const actual = (split(server_url) orelse return false).path;
    if (advertised.len == 0) return true;
    if (!std.mem.startsWith(u8, actual, advertised)) return false;
    return actual.len == advertised.len or actual[advertised.len] == '/';
}

/// RFC 9728 §3.1 then the root: where a protected resource's metadata may
/// be, most specific first.
pub fn protectedResourceMetadataUrls(arena: std.mem.Allocator, server_url: []const u8) ![]const []const u8 {
    const parts = split(server_url) orelse return error.InvalidUrl;
    const base = try origin(arena, server_url);
    const path = std.mem.trimEnd(u8, parts.path, "/");
    var out: std.ArrayList([]const u8) = .empty;
    if (path.len != 0) try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-protected-resource{s}", .{ base, path }));
    try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-protected-resource", .{base}));
    return out.toOwnedSlice(arena);
}

/// basic/authorization.mdx "Authorization Server Metadata Discovery": the
/// RFC 8414 and OpenID Connect locations, path-inserted first.
pub fn authorizationServerMetadataUrls(arena: std.mem.Allocator, issuer: []const u8) ![]const []const u8 {
    const parts = split(issuer) orelse return error.InvalidUrl;
    const base = try origin(arena, issuer);
    const path = std.mem.trimEnd(u8, parts.path, "/");
    var out: std.ArrayList([]const u8) = .empty;
    if (path.len != 0) {
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server{s}", .{ base, path }));
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration{s}", .{ base, path }));
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}{s}/.well-known/openid-configuration", .{ base, path }));
    } else {
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server", .{base}));
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration", .{base}));
    }
    return out.toOwnedSlice(arena);
}

/// Resolve `reference` against `base` (RFC 3986 §5.2, without dot-segment
/// removal: an endpoint event carries a path, not `../`).
pub fn resolve(arena: std.mem.Allocator, base: []const u8, reference: []const u8) ![]const u8 {
    if (split(reference) != null) return arena.dupe(u8, reference);
    const parts = split(base) orelse return error.InvalidUrl;
    if (std.mem.startsWith(u8, reference, "//")) return std.fmt.allocPrint(arena, "{s}:{s}", .{ parts.scheme, reference });
    if (std.mem.startsWith(u8, reference, "/")) return std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ parts.scheme, parts.authority, reference });
    if (std.mem.startsWith(u8, reference, "?")) return std.fmt.allocPrint(arena, "{s}://{s}{s}{s}", .{ parts.scheme, parts.authority, parts.path, reference });
    const dir_end = (std.mem.lastIndexOfScalar(u8, parts.path, '/') orelse 0);
    const dir = if (parts.path.len == 0) "/" else parts.path[0 .. dir_end + 1];
    return std.fmt.allocPrint(arena, "{s}://{s}{s}{s}", .{ parts.scheme, parts.authority, dir, reference });
}

const testing = std.testing;

test "well-known metadata locations insert the path, then fall back to the root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prm = try protectedResourceMetadataUrls(a, "https://Example.com/public/mcp?x=1");
    try testing.expectEqual(@as(usize, 2), prm.len);
    try testing.expectEqualStrings("https://example.com/.well-known/oauth-protected-resource/public/mcp", prm[0]);
    try testing.expectEqualStrings("https://example.com/.well-known/oauth-protected-resource", prm[1]);
    try testing.expectEqual(@as(usize, 1), (try protectedResourceMetadataUrls(a, "https://example.com/")).len);

    const tenant = try authorizationServerMetadataUrls(a, "https://auth.example.com/tenant1");
    try testing.expectEqualStrings("https://auth.example.com/.well-known/oauth-authorization-server/tenant1", tenant[0]);
    try testing.expectEqualStrings("https://auth.example.com/.well-known/openid-configuration/tenant1", tenant[1]);
    try testing.expectEqualStrings("https://auth.example.com/tenant1/.well-known/openid-configuration", tenant[2]);
    const root = try authorizationServerMetadataUrls(a, "https://auth.example.com");
    try testing.expectEqual(@as(usize, 2), root.len);
    try testing.expectEqualStrings("https://auth.example.com/.well-known/oauth-authorization-server", root[0]);
}

test "canonical resource, origins and coverage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https://mcp.example.com/mcp", try canonicalResource(a, "HTTPS://MCP.Example.com/mcp#frag"));
    try testing.expectEqualStrings("https://mcp.example.com", try canonicalResource(a, "https://mcp.example.com/"));
    try testing.expect(sameOrigin("https://a.example/x", "https://A.example:443/y"));
    try testing.expect(!sameOrigin("https://a.example/x", "http://a.example/x"));
    try testing.expect(!sameOrigin("http://127.0.0.1:1/x", "http://127.0.0.1:2/x"));
    try testing.expect(resourceCovers("https://a.example/mcp", "https://a.example/mcp"));
    try testing.expect(resourceCovers("https://a.example", "https://a.example/mcp"));
    try testing.expect(!resourceCovers("https://a.example/mc", "https://a.example/mcp"));
    try testing.expect(!resourceCovers("https://evil.example/mcp", "https://a.example/mcp"));
    try testing.expect(isSecureEndpoint("https://as.example/token"));
    try testing.expect(isSecureEndpoint("http://127.0.0.1:9/token"));
    try testing.expect(isSecureEndpoint("http://localhost/token"));
    try testing.expect(!isSecureEndpoint("http://as.example/token"));
    try testing.expect(isSecureEndpoint("http://127.0.0.2:8080/token"));
    try testing.expect(!isSecureEndpoint("http://127.attacker.example/token"));
    try testing.expect(!isSecureEndpoint("http://127.0.0.1.attacker.example/token"));
}

test "relative endpoint references resolve against the stream URL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https://h.example/messages?sessionId=1", try resolve(a, "https://h.example/sse", "/messages?sessionId=1"));
    try testing.expectEqualStrings("https://h.example/v1/messages", try resolve(a, "https://h.example/v1/sse", "messages"));
    try testing.expectEqualStrings("https://h.example/v1/sse?session=2", try resolve(a, "https://h.example/v1/sse?x", "?session=2"));
    try testing.expectEqualStrings("https://o.example/m", try resolve(a, "https://h.example/sse", "https://o.example/m"));
    try testing.expectEqualStrings("https://o.example/m", try resolve(a, "https://h.example/sse", "//o.example/m"));
}
