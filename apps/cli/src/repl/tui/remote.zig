const std = @import("std");
const builtin = @import("builtin");

const ssh_variables = [_][*:0]const u8{ "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY" };

pub fn session() bool {
    for (ssh_variables) |name| {
        if (std.c.getenv(name)) |value| {
            if (std.mem.span(value).len > 0) return true;
        }
    }
    return false;
}

pub const LinkHost = struct {
    bytes: [capacity]u8 = undefined,
    len: u8 = 0,

    pub const capacity = 255;

    pub fn of(name: []const u8) LinkHost {
        var host: LinkHost = .{};
        if (name.len > capacity) return host;
        @memcpy(host.bytes[0..name.len], name);
        host.len = @intCast(name.len);
        return host;
    }

    pub fn slice(host: *const LinkHost) []const u8 {
        return host.bytes[0..host.len];
    }
};

pub fn linkHost() LinkHost {
    if (comptime builtin.os.tag == .windows) return .{};
    if (!session()) return .{};
    var name: [std.posix.HOST_NAME_MAX]u8 = undefined;
    return LinkHost.of(std.posix.gethostname(&name) catch return .{});
}

const testing = std.testing;
const ppaths = @import("metacodes-internal").platform.paths;

const SavedEnv = struct {
    name: [*:0]const u8,
    value: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !SavedEnv {
        const previous = if (std.c.getenv(name)) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .value = previous };
    }

    fn restore(self: SavedEnv) void {
        if (self.value) |v| {
            ppaths.setEnv(self.name, v.ptr);
            testing.allocator.free(v);
        } else ppaths.unsetEnv(self.name);
    }
};

fn clearSshVariables() ![ssh_variables.len]SavedEnv {
    var saved: [ssh_variables.len]SavedEnv = undefined;
    for (ssh_variables, 0..) |name, i| saved[i] = try SavedEnv.set(name, null);
    return saved;
}

test "session: any SSH variable with a value marks a remote session, an empty one does not" {
    const saved = try clearSshVariables();
    defer for (saved) |s| s.restore();
    try testing.expect(!session());
    for (ssh_variables) |name| {
        const one = try SavedEnv.set(name, "10.0.0.1 50022 10.0.0.2 22");
        try testing.expect(session());
        one.restore();
    }
    const empty = try SavedEnv.set("SSH_TTY", "");
    defer empty.restore();
    try testing.expect(!session());
}

test "linkHost: the machine's own name over SSH, no host on a local terminal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const saved = try clearSshVariables();
    defer for (saved) |s| s.restore();
    try testing.expectEqualStrings("", linkHost().slice());
    const ssh = try SavedEnv.set("SSH_CONNECTION", "10.0.0.1 50022 10.0.0.2 22");
    defer ssh.restore();
    var name: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const expected = try std.posix.gethostname(&name);
    try testing.expect(expected.len > 0);
    try testing.expectEqualStrings(expected, linkHost().slice());
}

test "LinkHost.of: keeps a name that fits and gives no host for one that does not" {
    try testing.expectEqualStrings("devbox.example", LinkHost.of("devbox.example").slice());
    const long = "h" ** (LinkHost.capacity + 1);
    try testing.expectEqualStrings("", LinkHost.of(long).slice());
}
