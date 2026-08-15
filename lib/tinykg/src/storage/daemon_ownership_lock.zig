const std = @import("std");

pub const lock_suffix = ".tinykg-daemon.lock";

fn lockPath(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ store_path, lock_suffix });
}

fn openLocked(io: std.Io, path: []const u8, mode: std.Io.File.Lock) !std.Io.File {
    return std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = mode,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.DaemonAlreadyOwnsStore,
        else => |e| return e,
    };
}

pub const OwnershipLock = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    file: std.Io.File,

    pub fn acquire(
        allocator: std.mem.Allocator,
        io: std.Io,
        store_path: []const u8,
    ) !OwnershipLock {
        const path = try lockPath(allocator, store_path);
        errdefer allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        const file = try openLocked(io, path, .exclusive);
        return .{ .allocator = allocator, .io = io, .path = path, .file = file };
    }

    pub fn deinit(self: *OwnershipLock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

/// Held by a standalone CLI command for its complete Store critical section.
/// A daemon cannot acquire its exclusive owner lock between admission and
/// command teardown, while any number of read-only probes can fail closed
/// against an already-running daemon through the same OS primitive.
pub const AccessGuard = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    file: std.Io.File,

    pub fn acquire(
        allocator: std.mem.Allocator,
        io: std.Io,
        store_path: []const u8,
    ) !AccessGuard {
        const path = try lockPath(allocator, store_path);
        errdefer allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        const file = try openLocked(io, path, .shared);
        return .{ .allocator = allocator, .io = io, .path = path, .file = file };
    }

    pub fn deinit(self: *AccessGuard) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub fn rejectExternalAccess(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_path: []const u8,
) !void {
    var guard = try AccessGuard.acquire(allocator, io, store_path);
    guard.deinit();
}

test "daemon ownership lock rejects a second live owner and cleans up" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const store_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(store_path);

    var first = try OwnershipLock.acquire(std.testing.allocator, std.testing.io, store_path);
    try std.testing.expectError(
        error.DaemonAlreadyOwnsStore,
        OwnershipLock.acquire(std.testing.allocator, std.testing.io, store_path),
    );
    try std.testing.expectError(
        error.DaemonAlreadyOwnsStore,
        rejectExternalAccess(std.testing.allocator, std.testing.io, store_path),
    );
    first.deinit();
    try rejectExternalAccess(std.testing.allocator, std.testing.io, store_path);
    var second = try OwnershipLock.acquire(std.testing.allocator, std.testing.io, store_path);
    second.deinit();
}
