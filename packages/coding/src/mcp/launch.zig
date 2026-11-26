//! Turn a configured stdio server into an exact process launch: the child
//! environment, the resolved executable and the working directory.
//!
//! - Environment: `config.EnvPolicy.inherit` copies metacodes' environment
//!   (Claude Code); `.allowlist` copies only Codex's default variables, the CA
//!   bundle variables and `env_vars`. The entry's `env` is applied last.
//! - Executable: a bare command is searched on the *child's* `PATH` (and
//!   `PATHEXT` on Windows), as both Claude Code and Codex do; a relative path
//!   resolves against the working directory. Resolution happens here, in the
//!   parent, because the forked child may not allocate.
//! - Working directory: the entry's `cwd` (relative to the session's) or the
//!   session's working directory.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const exe_lookup = @import("platform").exe_lookup;

pub const Launch = struct {
    /// argv[0] is the resolved executable; null-terminated for execve.
    argv: []const ?[*:0]const u8,
    /// `KEY=VALUE` entries.
    env: []const [:0]const u8,
    cwd: []const u8,
    /// The executable as resolved, for diagnostics.
    executable: []const u8,
};

pub const Error = error{ OutOfMemory, CommandNotFound };

pub fn prepare(
    arena: std.mem.Allocator,
    stdio: config.Stdio,
    environment: config.Environment,
    session_cwd: []const u8,
) Error!Launch {
    var env = EnvBuilder{ .arena = arena };
    switch (stdio.env_policy) {
        .inherit => for (environment.entries) |entry| try env.putEntry(entry),
        .allowlist => {
            for (config.DEFAULT_ENV_VARS) |name| try env.copy(environment, name);
            for (config.CA_ENV_VARS) |name| try env.copy(environment, name);
            for (stdio.env_vars) |name| try env.copy(environment, name);
        },
    }
    for (stdio.env) |pair| try env.put(pair.name, pair.value);

    const cwd = if (stdio.cwd) |configured|
        (if (std.fs.path.isAbsolute(configured)) configured else try std.fs.path.resolve(arena, &.{ session_cwd, configured }))
    else
        session_cwd;

    const executable = try resolveExecutable(arena, stdio.command, env.get("PATH") orelse "", env.get("PATHEXT"), cwd);

    const argv = try arena.alloc(?[*:0]const u8, stdio.args.len + 2);
    argv[0] = (try arena.dupeZ(u8, executable)).ptr;
    for (stdio.args, 1..) |arg, index| argv[index] = (try arena.dupeZ(u8, arg)).ptr;
    argv[argv.len - 1] = null;

    return .{
        .argv = argv,
        .env = try env.finish(),
        .cwd = cwd,
        .executable = executable,
    };
}

fn resolveExecutable(
    arena: std.mem.Allocator,
    command: []const u8,
    path_env: []const u8,
    pathext_env: ?[]const u8,
    cwd: []const u8,
) Error![]const u8 {
    if (command.len == 0) return error.CommandNotFound;
    const style = exe_lookup.host_style;
    var buffer: [exe_lookup.max_exe_path_bytes]u8 = undefined;
    if (exe_lookup.isPathLike(style, command)) {
        // `./server`, `bin/server`: relative to the server's working directory.
        const anchored = if (std.fs.path.isAbsolute(command)) command else try std.fs.path.resolve(arena, &.{ cwd, command });
        const found = exe_lookup.lookupWith(style, anchored, "", pathext_env, exe_lookup.realProbe, null, &buffer) orelse
            return error.CommandNotFound;
        return arena.dupe(u8, found);
    }
    const found = exe_lookup.lookupWith(style, command, path_env, pathext_env, exe_lookup.realProbe, null, &buffer) orelse
        return error.CommandNotFound;
    return arena.dupe(u8, found);
}

/// Ordered `KEY=VALUE` set; a later `put` replaces an earlier value. Windows
/// names compare case-insensitively.
const EnvBuilder = struct {
    arena: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    fn index(self: *const EnvBuilder, name: []const u8) ?usize {
        for (self.names.items, 0..) |existing, position| {
            const same = if (builtin.os.tag == .windows)
                std.ascii.eqlIgnoreCase(existing, name)
            else
                std.mem.eql(u8, existing, name);
            if (same) return position;
        }
        return null;
    }

    fn put(self: *EnvBuilder, name: []const u8, value: []const u8) error{OutOfMemory}!void {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null and name[0] != '=') return;
        if (self.index(name)) |position| {
            self.values.items[position] = value;
            return;
        }
        try self.names.append(self.arena, name);
        try self.values.append(self.arena, value);
    }

    fn putEntry(self: *EnvBuilder, entry: []const u8) error{OutOfMemory}!void {
        // Windows keeps per-drive working directories as `=C:=C:\dir`.
        const eq = std.mem.indexOfScalarPos(u8, entry, 1, '=') orelse return;
        try self.put(entry[0..eq], entry[eq + 1 ..]);
    }

    fn copy(self: *EnvBuilder, environment: config.Environment, name: []const u8) error{OutOfMemory}!void {
        const value = environment.get(name) orelse return;
        if (value.len == 0) return;
        try self.put(name, value);
    }

    fn get(self: *const EnvBuilder, name: []const u8) ?[]const u8 {
        const position = self.index(name) orelse return null;
        return self.values.items[position];
    }

    fn finish(self: *EnvBuilder) error{OutOfMemory}![]const [:0]const u8 {
        const out = try self.arena.alloc([:0]const u8, self.names.items.len);
        for (self.names.items, self.values.items, out) |name, value, *slot| {
            slot.* = try std.fmt.allocPrintSentinel(self.arena, "{s}={s}", .{ name, value }, 0);
        }
        return out;
    }
};

/// A file name for a server's stderr log (`<state root>/logs/mcp/<name>.log`).
pub fn logFileName(arena: std.mem.Allocator, server: []const u8) error{OutOfMemory}![]const u8 {
    const name = try arena.alloc(u8, server.len);
    for (server, name) |byte, *slot| {
        slot.* = if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') byte else '_';
    }
    return std.fmt.allocPrint(arena, "{s}.log", .{name});
}

const testing = std.testing;

fn findEntry(entries: []const [:0]const u8, name: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.startsWith(u8, entry, name) and entry.len > name.len and entry[name.len] == '=')
            return entry[name.len + 1 ..];
    }
    return null;
}

test "allowlist keeps Codex's variables, env_vars and env; inherit keeps everything" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parent = config.Environment{ .entries = &.{ "PATH=/usr/bin:/bin", "HOME=/home/u", "SECRET_API_KEY=s3cret", "GITHUB_TOKEN=ghp", "SSL_CERT_FILE=/ca.pem" } };
    const allowlisted = try prepare(arena.allocator(), .{
        .command = "sh",
        .args = &.{ "-c", "true" },
        .env = &.{.{ .name = "EXTRA", .value = "1" }},
        .env_vars = &.{"GITHUB_TOKEN"},
        .cwd = null,
        .env_policy = .allowlist,
    }, parent, "/");
    try testing.expectEqualStrings("/home/u", findEntry(allowlisted.env, "HOME").?);
    try testing.expectEqualStrings("ghp", findEntry(allowlisted.env, "GITHUB_TOKEN").?);
    try testing.expectEqualStrings("/ca.pem", findEntry(allowlisted.env, "SSL_CERT_FILE").?);
    try testing.expectEqualStrings("1", findEntry(allowlisted.env, "EXTRA").?);
    try testing.expect(findEntry(allowlisted.env, "SECRET_API_KEY") == null);
    // The bare command was found on the child's PATH.
    try testing.expect(std.mem.endsWith(u8, allowlisted.executable, "/sh"));
    try testing.expectEqualStrings(allowlisted.executable, std.mem.span(allowlisted.argv[0].?));
    try testing.expect(allowlisted.argv[3] == null);

    const inherited = try prepare(arena.allocator(), .{
        .command = "/bin/sh",
        .args = &.{},
        .env = &.{.{ .name = "HOME", .value = "/override" }},
        .env_vars = &.{},
        .cwd = null,
        .env_policy = .inherit,
    }, parent, "/");
    try testing.expectEqualStrings("s3cret", findEntry(inherited.env, "SECRET_API_KEY").?);
    try testing.expectEqualStrings("/override", findEntry(inherited.env, "HOME").?);
}

test "commands resolve on the child's PATH and relative paths on the working directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const no_path = config.Environment{ .entries = &.{} };
    try testing.expectError(error.CommandNotFound, prepare(arena.allocator(), .{
        .command = "sh",
        .args = &.{},
        .env = &.{},
        .env_vars = &.{},
        .cwd = null,
        .env_policy = .allowlist,
    }, no_path, "/"));
    // An entry's own PATH decides the lookup.
    const own_path = try prepare(arena.allocator(), .{
        .command = "sh",
        .args = &.{},
        .env = &.{.{ .name = "PATH", .value = "/bin" }},
        .env_vars = &.{},
        .cwd = null,
        .env_policy = .allowlist,
    }, no_path, "/");
    try testing.expectEqualStrings("/bin/sh", own_path.executable);
    const relative = try prepare(arena.allocator(), .{
        .command = "./sh",
        .args = &.{},
        .env = &.{},
        .env_vars = &.{},
        .cwd = "bin",
        .env_policy = .allowlist,
    }, no_path, "/");
    try testing.expectEqualStrings("/bin/sh", relative.executable);
    try testing.expectEqualStrings("/bin", relative.cwd);
}

test "log file names are safe on every platform" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("org_team_srv.v2.log", try logFileName(arena.allocator(), "org/team:srv.v2"));
}
