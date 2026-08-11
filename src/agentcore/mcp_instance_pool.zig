//! Runtime-local MCP ServerInstance ownership.
//!
//! Catalog generations retain instances by opaque monotonic id. Dispatch takes
//! a second short lease. No catalog value borrows Client or transport memory.

const std = @import("std");
const sync = @import("platform").sync;
const runtime = @import("mcp_runtime.zig");

pub const InstanceId = enum(u64) { _ };

pub const Error = error{
    OutOfMemory,
    InstanceUnavailable,
    ResourceLimit,
};

const Instance = struct {
    id: InstanceId,
    client: *runtime.Client,
    refs: u32 = 1,
};

pub const Lease = struct {
    pool: *Pool,
    instance: *Instance,
    live: bool = true,

    pub fn id(self: *const Lease) InstanceId {
        return self.instance.id;
    }

    pub fn client(self: *const Lease) *runtime.Client {
        return self.instance.client;
    }

    pub fn deinit(self: *Lease) void {
        if (!self.live) return;
        self.pool.releasePointer(self.instance);
        self.live = false;
    }
};

pub const Pool = struct {
    // Thread contract:
    // - all membership and refcount transitions occur under `mutex`;
    // - Client callbacks and deinit always run after releasing `mutex`;
    // - Pool storage must have a stable address while any Lease exists;
    // - deinit requires every catalog-owner and dispatch Lease to be released.
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    instances: std.ArrayList(*Instance) = .empty,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Pool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        const remaining = self.instances.items.len;
        self.mutex.unlock();
        std.debug.assert(remaining == 0);
        self.instances.deinit(self.allocator);
        self.* = undefined;
    }

    /// Transfers one Client ownership reference into the returned id.
    /// The caller must eventually release it with `releaseId`.
    pub fn adopt(self: *Pool, client: *runtime.Client) Error!InstanceId {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.next_id == 0 or self.next_id == std.math.maxInt(u64))
            return error.ResourceLimit;
        const instance = self.allocator.create(Instance) catch
            return error.OutOfMemory;
        errdefer self.allocator.destroy(instance);
        const id: InstanceId = @enumFromInt(self.next_id);
        self.next_id += 1;
        instance.* = .{ .id = id, .client = client };
        self.instances.append(self.allocator, instance) catch
            return error.OutOfMemory;
        return id;
    }

    pub fn retain(self: *Pool, id: InstanceId) Error!Lease {
        self.mutex.lock();
        defer self.mutex.unlock();
        const instance = self.findLocked(id) orelse
            return error.InstanceUnavailable;
        if (instance.refs == std.math.maxInt(u32)) return error.ResourceLimit;
        instance.refs += 1;
        return .{ .pool = self, .instance = instance };
    }

    /// Acquire one ownership reference for a catalog generation. Unlike a
    /// dispatch Lease, this reference is released by Snapshot.release().
    pub fn retainId(self: *Pool, id: InstanceId) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const instance = self.findLocked(id) orelse
            return error.InstanceUnavailable;
        if (instance.refs == std.math.maxInt(u32)) return error.ResourceLimit;
        instance.refs += 1;
    }

    pub fn releaseId(self: *Pool, id: InstanceId) void {
        self.mutex.lock();
        const instance = self.findLocked(id) orelse {
            self.mutex.unlock();
            std.debug.assert(false);
            return;
        };
        self.releaseLocked(instance);
    }

    fn releasePointer(self: *Pool, instance: *Instance) void {
        self.mutex.lock();
        self.releaseLocked(instance);
    }

    fn releaseLocked(self: *Pool, instance: *Instance) void {
        std.debug.assert(instance.refs != 0);
        instance.refs -= 1;
        if (instance.refs != 0) {
            self.mutex.unlock();
            return;
        }
        var found = false;
        for (self.instances.items, 0..) |candidate, index| {
            if (candidate != instance) continue;
            _ = self.instances.swapRemove(index);
            found = true;
            break;
        }
        std.debug.assert(found);
        self.mutex.unlock();

        const client = instance.client;
        self.allocator.destroy(instance);
        client.deinit();
    }

    fn findLocked(self: *Pool, id: InstanceId) ?*Instance {
        for (self.instances.items) |instance|
            if (instance.id == id) return instance;
        return null;
    }
};

fn testClient(server: anytype, binding_byte: u8) !*runtime.Client {
    const outcome = runtime.connectServer(std.testing.allocator, .{
        .connector = server.connector(),
        .transport = .stdio,
        .policy = .modern_only,
        .server_binding_identity = [_]u8{binding_byte} ** 32,
        .client = .{ .name = "instance-pool-test", .version = "1" },
    });
    return switch (outcome) {
        .client => |client| client,
        .failed => error.TestUnexpectedResult,
    };
}

test "InstanceId is never reused and stale ids fail cleanly" {
    const fixture = @import("mcp_test_support.zig");
    var server = fixture.Server{};
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    const first_id = try pool.adopt(try testClient(&server, 0xb1));
    pool.releaseId(first_id);
    try std.testing.expectError(error.InstanceUnavailable, pool.retain(first_id));

    const second_id = try pool.adopt(try testClient(&server, 0xb2));
    try std.testing.expect(@intFromEnum(second_id) > @intFromEnum(first_id));
    pool.releaseId(second_id);
    try std.testing.expectEqual(@as(u32, 2), server.closes);
}

test "dispatch lease keeps Client alive after catalog owner releases" {
    const fixture = @import("mcp_test_support.zig");
    var server = fixture.Server{};
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    const id = try pool.adopt(try testClient(&server, 0xb3));
    var lease = try pool.retain(id);
    pool.releaseId(id);
    try std.testing.expectEqual(@as(u32, 0), server.closes);
    try std.testing.expectEqual(id, lease.id());
    lease.deinit();
    try std.testing.expectEqual(@as(u32, 1), server.closes);
    try std.testing.expectError(error.InstanceUnavailable, pool.retain(id));
}
