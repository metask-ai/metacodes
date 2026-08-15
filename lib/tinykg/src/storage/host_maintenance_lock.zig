const std = @import("std");

/// Host-wide maintenance gate (roadmap 12001): co-located stores must not
/// stack O(store) maintenance (rebuild-text, deferred full repair) on top of
/// each other. Holding the lock serializes those jobs across every process
/// on the host that opted in; write and read service paths never take it —
/// maintenance debt defers and retries instead.
///
/// Opt-in by environment: `TINYKG_MAINTENANCE_LOCK=<path>` names the shared
/// lock file. Unset means no host gate (single-store deployments keep
/// today's behavior exactly). The lock is advisory OS file locking, the
/// same primitive as the daemon ownership lock, so a killed process can
/// never leave the host wedged.
pub fn lockPathFromEnvironment() ?[]const u8 {
    const raw = std.c.getenv("TINYKG_MAINTENANCE_LOCK") orelse return null;
    const path = std.mem.span(raw);
    if (path.len == 0) return null;
    return path;
}

pub const HostMaintenanceLock = struct {
    io: std.Io,
    file: std.Io.File,

    /// Blocking acquire for operator-driven maintenance (rebuild-text):
    /// waiting behind another store's job is the intended serialization.
    pub fn acquire(io: std.Io, path: []const u8) !HostMaintenanceLock {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        });
        return .{ .io = io, .file = file };
    }

    /// Non-blocking acquire for the daemon's deferred self-heal: a busy
    /// host keeps the debt pending and the daemon stays responsive; the
    /// next flushed batch retries.
    pub fn tryAcquire(io: std.Io, path: []const u8) !?HostMaintenanceLock {
        const file = std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => |e| return e,
        };
        return .{ .io = io, .file = file };
    }

    pub fn deinit(self: *HostMaintenanceLock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

test "host maintenance lock serializes across handles and frees on release" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temp.dir.realPath(std.testing.io, &path_buffer);
    const lock_path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "maintenance.lock" });
    defer std.testing.allocator.free(lock_path);

    var first = try HostMaintenanceLock.acquire(std.testing.io, lock_path);
    try std.testing.expectEqual(@as(?HostMaintenanceLock, null), try HostMaintenanceLock.tryAcquire(std.testing.io, lock_path));
    first.deinit();

    var second = (try HostMaintenanceLock.tryAcquire(std.testing.io, lock_path)) orelse return error.TestUnexpectedResult;
    second.deinit();
}
