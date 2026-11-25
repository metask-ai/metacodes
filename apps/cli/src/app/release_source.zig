//! Where an install's updates come from (doc/UPDATE_DESIGN.md §3): published
//! releases at the default base or at a mirror, or the checkout that built a
//! development install. The installer records it in
//! `etc/metacodes/install.json` as the optional `update_source` member;
//! `metacodes update` reads it back. Both sides validate it here, so a base
//! that one of them accepts the other can use.

const std = @import("std");

/// Releases are published here (`release.yml`); `install.sh` downloads from
/// the same place.
pub const default_release_base = "https://github.com/metask-ai/metacodes/releases";

/// What an install record says about its source. A record without the
/// member means `.default_release`.
pub const UpdateSource = union(enum) {
    /// Published releases at `default_release_base`.
    default_release,
    /// Published releases at a mirror: a validated, normalized base that is
    /// never the default.
    mirror: []const u8,
    /// A development install built from this checkout (an absolute path).
    checkout: []const u8,

    pub fn eql(a: UpdateSource, b: UpdateSource) bool {
        return switch (a) {
            .default_release => b == .default_release,
            .mirror => |base| b == .mirror and std.mem.eql(u8, base, b.mirror),
            .checkout => |path| b == .checkout and std.mem.eql(u8, path, b.checkout),
        };
    }

    /// The release base to download from; null for a checkout.
    pub fn releaseBase(source: UpdateSource) ?[]const u8 {
        return switch (source) {
            .default_release => default_release_base,
            .mirror => |base| base,
            .checkout => null,
        };
    }
};

pub const BaseError = error{
    /// Not an absolute http(s) URL with a host.
    InvalidReleaseBase,
    /// `http://` to a host that is not loopback: nothing would check what
    /// it serves (the sums come from the same place as the archives).
    InsecureReleaseBase,
    /// User-info, a query or a fragment: a credential in a recorded URL would
    /// travel with every request, and across a redirect to another host.
    ReleaseBaseHasCredentials,
};

/// `url` as a release source: the default base becomes `.default_release`,
/// anything else a `.mirror` with trailing `/` dropped. `arena` owns the
/// mirror string.
pub fn parseBase(arena: std.mem.Allocator, url: []const u8) (BaseError || error{OutOfMemory})!UpdateSource {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    const uri = std.Uri.parse(trimmed) catch return error.InvalidReleaseBase;
    const host = uri.host orelse return error.InvalidReleaseBase;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = host.toRaw(&host_buf) catch return error.InvalidReleaseBase;
    if (host_name.len == 0) return error.InvalidReleaseBase;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.ReleaseBaseHasCredentials;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) {
        if (!isLoopbackHost(host_name)) return error.InsecureReleaseBase;
    } else if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.InvalidReleaseBase;
    }
    if (std.mem.eql(u8, trimmed, default_release_base)) return .default_release;
    return .{ .mirror = try arena.dupe(u8, trimmed) };
}

/// The hosts a plain-http base may name: this machine only.
pub fn isLoopbackHost(host: []const u8) bool {
    const bare = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    if (std.ascii.eqlIgnoreCase(bare, "localhost") or std.mem.eql(u8, bare, "::1")) return true;
    // 127.0.0.0/8
    const ip = std.Io.net.Ip4Address.parse(bare, 0) catch return false;
    return ip.bytes[0] == 127;
}

/// The checkout of a development install: an absolute path, stored as given.
pub fn parseCheckout(arena: std.mem.Allocator, path: []const u8) error{ CheckoutNotAbsolute, OutOfMemory }!UpdateSource {
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.CheckoutNotAbsolute;
    return .{ .checkout = try arena.dupe(u8, path) };
}

/// The `update_source` member as JSON: `{"kind":"release","base":…}` or
/// `{"kind":"checkout","path":…}`. The default is no member at all.
pub const Json = struct {
    kind: []const u8,
    base: ?[]const u8 = null,
    path: ?[]const u8 = null,

    pub fn from(source: UpdateSource) ?Json {
        return switch (source) {
            .default_release => null,
            .mirror => |base| .{ .kind = "release", .base = base },
            .checkout => |path| .{ .kind = "checkout", .path = path },
        };
    }

    /// The source a record names, validated as the installer would write it;
    /// null for a member that is not one (unknown kind, missing or invalid
    /// value, or both values).
    pub fn toSource(self: Json, arena: std.mem.Allocator) error{OutOfMemory}!?UpdateSource {
        if (std.mem.eql(u8, self.kind, "release")) {
            if (self.path != null) return null;
            const base = self.base orelse return null;
            return parseBase(arena, base) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => null,
            };
        }
        if (std.mem.eql(u8, self.kind, "checkout")) {
            if (self.base != null) return null;
            const path = self.path orelse return null;
            return parseCheckout(arena, path) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => null,
            };
        }
        return null;
    }
};

const testing = std.testing;

test "parseBase: the default, mirrors, and what is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect((try parseBase(arena, default_release_base)) == .default_release);
    try testing.expect((try parseBase(arena, default_release_base ++ "/")) == .default_release);
    const mirror = try parseBase(arena, "https://mirror.example/metacodes/releases//");
    try testing.expectEqualStrings("https://mirror.example/metacodes/releases", mirror.mirror);
    try testing.expectEqualStrings("http://127.0.0.1:8123/r", (try parseBase(arena, "http://127.0.0.1:8123/r")).mirror);
    try testing.expectEqualStrings("http://localhost:1/r", (try parseBase(arena, "http://localhost:1/r")).mirror);
    try testing.expectEqualStrings("http://[::1]:9/r", (try parseBase(arena, "http://[::1]:9/r")).mirror);

    try testing.expectError(error.InsecureReleaseBase, parseBase(arena, "http://mirror.example/releases"));
    try testing.expectError(error.InsecureReleaseBase, parseBase(arena, "http://128.0.0.1/releases"));
    try testing.expectError(error.ReleaseBaseHasCredentials, parseBase(arena, "https://user:pw@mirror.example/r"));
    try testing.expectError(error.ReleaseBaseHasCredentials, parseBase(arena, "https://token@mirror.example/r"));
    try testing.expectError(error.ReleaseBaseHasCredentials, parseBase(arena, "https://mirror.example/r?token=x"));
    try testing.expectError(error.ReleaseBaseHasCredentials, parseBase(arena, "https://mirror.example/r#x"));
    try testing.expectError(error.InvalidReleaseBase, parseBase(arena, "ftp://mirror.example/r"));
    try testing.expectError(error.InvalidReleaseBase, parseBase(arena, "file:///srv/releases"));
    try testing.expectError(error.InvalidReleaseBase, parseBase(arena, "mirror.example/releases"));
    try testing.expectError(error.InvalidReleaseBase, parseBase(arena, ""));
}

test "Json round-trips every source and rejects a malformed member" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(Json.from(.default_release) == null);
    const mirror: UpdateSource = .{ .mirror = "https://mirror.example/r" };
    try testing.expect((try Json.from(mirror).?.toSource(arena)).?.eql(mirror));
    const checkout: UpdateSource = .{ .checkout = "/home/me/src/metacodes" };
    try testing.expect((try Json.from(checkout).?.toSource(arena)).?.eql(checkout));

    // A recorded default base is the default, however it was spelled.
    try testing.expect((try (Json{ .kind = "release", .base = default_release_base ++ "/" }).toSource(arena)).? == .default_release);
    try testing.expect((try (Json{ .kind = "release" }).toSource(arena)) == null);
    try testing.expect((try (Json{ .kind = "release", .base = "http://mirror.example/r" }).toSource(arena)) == null);
    try testing.expect((try (Json{ .kind = "release", .base = "https://m.example/r", .path = "/x" }).toSource(arena)) == null);
    try testing.expect((try (Json{ .kind = "checkout", .path = "relative/dir" }).toSource(arena)) == null);
    try testing.expect((try (Json{ .kind = "checkout", .path = "/x", .base = "https://m.example/r" }).toSource(arena)) == null);
    try testing.expect((try (Json{ .kind = "tarball", .path = "/x" }).toSource(arena)) == null);
}
