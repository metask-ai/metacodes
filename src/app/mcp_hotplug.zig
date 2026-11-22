const std = @import("std");
const pfs = @import("platform").fs;
const mcp_config = @import("../mcp/config.zig");

pub fn deepCopy(arena: std.mem.Allocator, comptime T: type, value: T) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .slice) @compileError("deepCopy copies slices only");
            if (pointer.child == u8) return arena.dupe(u8, value);
            const copy = try arena.alloc(pointer.child, value.len);
            for (value, copy) |item, *out| out.* = try deepCopy(arena, pointer.child, item);
            return copy;
        },
        .optional => |optional| return if (value) |inner| try deepCopy(arena, optional.child, inner) else null,
        .@"struct" => |info| {
            var out: T = undefined;
            inline for (info.fields) |field| @field(out, field.name) = try deepCopy(arena, field.type, @field(value, field.name));
            return out;
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("deepCopy copies tagged unions only");
            switch (value) {
                inline else => |payload, tag| {
                    const Payload = @FieldType(T, @tagName(tag));
                    comptime std.debug.assert(@TypeOf(tag) == Tag);
                    return @unionInit(T, @tagName(tag), try deepCopy(arena, Payload, payload));
                },
            }
        },
        .int, .float, .bool, .@"enum", .void => return value,
        else => @compileError("deepCopy cannot copy " ++ @typeName(T)),
    }
}

pub fn hashValue(hasher: *std.hash.Wyhash, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .slice) @compileError("hashValue hashes slices only");
            hasher.update(std.mem.asBytes(&value.len));
            if (pointer.child == u8) {
                hasher.update(value);
            } else for (value) |item| hashValue(hasher, pointer.child, item);
        },
        .optional => |optional| {
            hasher.update(&.{@intFromBool(value != null)});
            if (value) |inner| hashValue(hasher, optional.child, inner);
        },
        .@"struct" => |info| inline for (info.fields) |field| hashValue(hasher, field.type, @field(value, field.name)),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                hasher.update(@tagName(tag));
                hashValue(hasher, @FieldType(T, @tagName(tag)), payload);
            },
        },
        .@"enum" => hasher.update(@tagName(value)),
        .int, .bool => hasher.update(std.mem.asBytes(&value)),
        .void => {},
        else => @compileError("hashValue cannot hash " ++ @typeName(T)),
    }
}

pub fn serverKey(server: mcp_config.Server) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashValue(&hasher, mcp_config.Server, server);
    return hasher.final();
}

pub const Observation = struct {
    present: bool = false,
    unobservable: bool = false,
    link: pfs.PathStat = .{ .kind = .other, .size = 0, .modified_ns = 0, .changed_ns = 0, .device = 0, .inode = 0 },
    target_size: u64 = 0,
    target_modified_ns: i128 = 0,

    pub fn eql(a: Observation, b: Observation) bool {
        return a.present == b.present and a.unobservable == b.unobservable and a.link.eql(b.link) and
            a.target_size == b.target_size and a.target_modified_ns == b.target_modified_ns;
    }
};

pub fn observe(path: []const u8) Observation {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return .{ .unobservable = true };
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    const link = pfs.statNoFollow(path_z) catch |err| return switch (err) {
        error.NotFound => .{},
        error.Unavailable => .{ .unobservable = true },
    };
    var seen = Observation{ .present = true, .link = link };
    if (link.kind == .symlink) {
        const fd = pfs.openReadShared(path_z);
        if (fd >= 0) {
            defer pfs.close(fd);
            if (pfs.fileInfo(fd)) |info| {
                seen.target_size = info.size;
                seen.target_modified_ns = info.modified_wall_ns;
            } else |_| seen.unobservable = true;
        } else seen.unobservable = true;
    }
    return seen;
}

pub const Watch = struct {
    allocator: std.mem.Allocator,
    paths: [][]const u8 = &.{},
    seen: []Observation = &.{},

    pub fn init(allocator: std.mem.Allocator, paths: []const []const u8) error{OutOfMemory}!Watch {
        const owned = try allocator.alloc([]const u8, paths.len);
        var copied: usize = 0;
        errdefer {
            for (owned[0..copied]) |path| allocator.free(path);
            allocator.free(owned);
        }
        for (paths, owned) |path, *out| {
            out.* = try allocator.dupe(u8, path);
            copied += 1;
        }
        const seen = try allocator.alloc(Observation, paths.len);
        for (owned, seen) |path, *out| out.* = observe(path);
        return .{ .allocator = allocator, .paths = owned, .seen = seen };
    }

    pub fn deinit(self: *Watch) void {
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
        self.allocator.free(self.seen);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn changed(self: *Watch) bool {
        var any = false;
        for (self.paths, self.seen) |path, *seen| {
            const now = observe(path);
            if (now.eql(seen.*)) continue;
            seen.* = now;
            any = true;
        }
        return any;
    }
};

pub fn within(path: []const u8, root: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, root, "/\\");
    if (trimmed.len == 0) return root.len != 0;
    if (!std.mem.startsWith(u8, path, trimmed)) return false;
    return path.len == trimmed.len or path[trimmed.len] == '/' or path[trimmed.len] == '\\';
}

pub fn resolvedPath(buf: *[std.fs.max_path_bytes + 1]u8, path: []const u8) []const u8 {
    var input: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= input.len) return path;
    @memcpy(input[0..path.len], path);
    input[path.len] = 0;
    const real = pfs.realpath(@ptrCast(&input), buf) orelse return path;
    return std.mem.span(real);
}

pub fn withinAny(path: []const u8, roots: []const []const u8) bool {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const real_path = resolvedPath(&path_buf, path);
    for (roots) |root| {
        if (root.len == 0) continue;
        var root_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (within(real_path, resolvedPath(&root_buf, root)) or within(path, root)) return true;
    }
    return false;
}

const testing = std.testing;

fn sampleServer(arena: std.mem.Allocator) !mcp_config.Server {
    const args = try arena.alloc([]const u8, 2);
    args[0] = try arena.dupe(u8, "-y");
    args[1] = try arena.dupe(u8, "pkg");
    const env = try arena.alloc(mcp_config.KeyValue, 1);
    env[0] = .{ .name = try arena.dupe(u8, "K"), .value = try arena.dupe(u8, "V") };
    return .{
        .name = try arena.dupe(u8, "s"),
        .transport = .{ .stdio = .{
            .command = try arena.dupe(u8, "npx"),
            .args = args,
            .env = env,
            .env_vars = &.{},
            .cwd = null,
            .env_policy = .inherit,
        } },
        .startup_timeout_ms = 1000,
        .tool_timeout_ms = null,
        .enabled_tools = null,
        .disabled_tools = &.{},
        .origin = .metacodes,
        .origin_path = try arena.dupe(u8, "/x/config.json"),
    };
}

test "a deep copy owns every byte and keeps the server's identity" {
    var source_arena = std.heap.ArenaAllocator.init(testing.allocator);
    const original = try sampleServer(source_arena.allocator());
    const key = serverKey(original);
    var copy_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer copy_arena.deinit();
    const copy = try deepCopy(copy_arena.allocator(), mcp_config.Server, original);
    source_arena.deinit();
    try testing.expectEqualStrings("npx", copy.transport.stdio.command);
    try testing.expectEqualStrings("pkg", copy.transport.stdio.args[1]);
    try testing.expectEqualStrings("V", copy.transport.stdio.env[0].value);
    try testing.expectEqual(key, serverKey(copy));
}

test "the server key moves with any connection field and not otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base = try sampleServer(arena.allocator());
    var same = try sampleServer(arena.allocator());
    try testing.expectEqual(serverKey(base), serverKey(same));
    const other_args = [_][]const u8{ "-y", "other" };
    same.transport.stdio.args = &other_args;
    try testing.expect(serverKey(base) != serverKey(same));
    var timeout = try sampleServer(arena.allocator());
    timeout.tool_timeout_ms = 5;
    try testing.expect(serverKey(base) != serverKey(timeout));
}

test "a path is within a root only at a separator boundary" {
    try testing.expect(within("/a/b/c.json", "/a/b"));
    try testing.expect(within("/a/b/c.json", "/a/b/"));
    try testing.expect(within("/a/b", "/a/b"));
    try testing.expect(!within("/a/bc/c.json", "/a/b"));
    try testing.expect(!within("/a/b/c.json", ""));
}

test "a watch sees a file appear, change and go, and is quiet otherwise" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const path = try std.fs.path.join(testing.allocator, &.{ root_buffer[0..root_len], "config.json" });
    defer testing.allocator.free(path);
    var watch = try Watch.init(testing.allocator, &.{path});
    defer watch.deinit();
    try testing.expect(!watch.changed());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{}" });
    try testing.expect(watch.changed());
    try testing.expect(!watch.changed());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{\"mcpServers\":{\"a\":{}}}" });
    try testing.expect(watch.changed());
    try tmp.dir.deleteFile(testing.io, "config.json");
    try testing.expect(watch.changed());
    try testing.expect(!watch.changed());
}
