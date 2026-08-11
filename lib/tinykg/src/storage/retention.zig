const std = @import("std");

/// Owns manifest paths pinned for the lifetime of one edge-segment read.
pub const EdgeSegmentRetentionWindow = struct {
    allocator: std.mem.Allocator,
    manifest_paths: std.ArrayList([]const u8) = .empty,

    pub fn pinnedManifestPaths(self: *const EdgeSegmentRetentionWindow) []const []const u8 {
        return self.manifest_paths.items;
    }

    pub fn deinit(self: *EdgeSegmentRetentionWindow) void {
        for (self.manifest_paths.items) |path| self.allocator.free(path);
        self.manifest_paths.deinit(self.allocator);
    }
};

pub fn initEdgeSegmentRetentionWindow(allocator: std.mem.Allocator) EdgeSegmentRetentionWindow {
    return .{ .allocator = allocator };
}

/// Takes ownership of `path`, including on allocation failure.
pub fn appendOwnedEdgeSegmentManifestPath(window: *EdgeSegmentRetentionWindow, path: []const u8) !void {
    errdefer window.allocator.free(path);
    try window.manifest_paths.append(window.allocator, path);
}

pub const ManifestProcessLease = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,

    pub fn deinit(self: *ManifestProcessLease) void {
        std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        self.allocator.free(self.path);
        self.path = &.{};
    }
};

pub const EdgeSegmentRetentionRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        path: []u8,
        ref_count: usize,
    };

    pub fn init(allocator: std.mem.Allocator) EdgeSegmentRetentionRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EdgeSegmentRetentionRegistry) void {
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.deinit(self.allocator);
    }

    fn retainOwnedManifestPath(self: *EdgeSegmentRetentionRegistry, path: []u8) ![]const u8 {
        errdefer self.allocator.free(path);
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                entry.ref_count = std.math.add(usize, entry.ref_count, 1) catch return error.RecordTooLarge;
                self.allocator.free(path);
                return entry.path;
            }
        }
        try self.entries.append(self.allocator, .{ .path = path, .ref_count = 1 });
        return path;
    }

    fn releaseManifestPath(self: *EdgeSegmentRetentionRegistry, path: []const u8) void {
        for (self.entries.items, 0..) |*entry, index| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            if (entry.ref_count > 1) {
                entry.ref_count -= 1;
                return;
            }
            const owned_path = entry.path;
            _ = self.entries.orderedRemove(index);
            self.allocator.free(owned_path);
            return;
        }
    }

    pub fn activeManifestPaths(self: *const EdgeSegmentRetentionRegistry, allocator: std.mem.Allocator) ![]const []const u8 {
        const paths = try allocator.alloc([]const u8, self.entries.items.len);
        errdefer allocator.free(paths);
        for (self.entries.items, 0..) |entry, index| paths[index] = entry.path;
        return paths;
    }
};

pub fn retainOwnedEdgeSegmentManifestPath(registry: *EdgeSegmentRetentionRegistry, path: []u8) ![]const u8 {
    return registry.retainOwnedManifestPath(path);
}

pub const EdgeSegmentRegisteredRetentionWindow = struct {
    registry: *EdgeSegmentRetentionRegistry,
    manifest_path: ?[]const u8 = null,
    process_lease: ?ManifestProcessLease = null,

    pub fn deinit(self: *EdgeSegmentRegisteredRetentionWindow) void {
        if (self.process_lease) |*lease| {
            lease.deinit();
            self.process_lease = null;
        }
        if (self.manifest_path) |path| {
            self.registry.releaseManifestPath(path);
            self.manifest_path = null;
        }
    }
};

pub const NodeTextRunRetentionRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        path: []u8,
        ref_count: usize,
    };

    pub fn init(allocator: std.mem.Allocator) NodeTextRunRetentionRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NodeTextRunRetentionRegistry) void {
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.deinit(self.allocator);
    }

    fn retainOwnedManifestPath(self: *NodeTextRunRetentionRegistry, path: []u8) ![]const u8 {
        errdefer self.allocator.free(path);
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                entry.ref_count = std.math.add(usize, entry.ref_count, 1) catch return error.RecordTooLarge;
                self.allocator.free(path);
                return entry.path;
            }
        }
        try self.entries.append(self.allocator, .{ .path = path, .ref_count = 1 });
        return path;
    }

    fn releaseManifestPath(self: *NodeTextRunRetentionRegistry, path: []const u8) void {
        for (self.entries.items, 0..) |*entry, index| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            if (entry.ref_count > 1) {
                entry.ref_count -= 1;
                return;
            }
            const owned_path = entry.path;
            _ = self.entries.orderedRemove(index);
            self.allocator.free(owned_path);
            return;
        }
    }

    pub fn activeManifestPaths(self: *const NodeTextRunRetentionRegistry, allocator: std.mem.Allocator) ![]const []const u8 {
        const paths = try allocator.alloc([]const u8, self.entries.items.len);
        errdefer allocator.free(paths);
        for (self.entries.items, 0..) |entry, index| paths[index] = entry.path;
        return paths;
    }
};

pub fn retainOwnedNodeTextRunManifestPath(registry: *NodeTextRunRetentionRegistry, path: []u8) ![]const u8 {
    return registry.retainOwnedManifestPath(path);
}

pub const NodeTextRunRegisteredRetentionWindow = struct {
    registry: *NodeTextRunRetentionRegistry,
    manifest_path: ?[]const u8 = null,
    process_lease: ?ManifestProcessLease = null,

    pub fn deinit(self: *NodeTextRunRegisteredRetentionWindow) void {
        if (self.process_lease) |*lease| {
            lease.deinit();
            self.process_lease = null;
        }
        if (self.manifest_path) |path| {
            self.registry.releaseManifestPath(path);
            self.manifest_path = null;
        }
    }
};

test "edge segment retention window owns appended manifest paths" {
    var window = initEdgeSegmentRetentionWindow(std.testing.allocator);
    defer window.deinit();

    try appendOwnedEdgeSegmentManifestPath(
        &window,
        try std.testing.allocator.dupe(u8, "edge-manifest-current"),
    );

    const pinned = window.pinnedManifestPaths();
    try std.testing.expectEqual(@as(usize, 1), pinned.len);
    try std.testing.expectEqualStrings("edge-manifest-current", pinned[0]);
}

test "manifest process lease deinit removes its lease file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const lease_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ path_buf[0..root_len], "reader.lease" },
    );
    defer std.testing.allocator.free(lease_path);
    {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, lease_path, .{});
        defer file.close(std.testing.io);
    }

    var lease = ManifestProcessLease{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .path = try std.testing.allocator.dupe(u8, lease_path),
    };
    lease.deinit();

    try std.testing.expectEqual(@as(usize, 0), lease.path.len);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().openFile(std.testing.io, lease_path, .{}),
    );
}

test "edge segment retention registry deduplicates and reference counts windows" {
    var registry = EdgeSegmentRetentionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const first = try retainOwnedEdgeSegmentManifestPath(
        &registry,
        try std.testing.allocator.dupe(u8, "edge-manifest-epoch"),
    );
    const second = try retainOwnedEdgeSegmentManifestPath(
        &registry,
        try std.testing.allocator.dupe(u8, "edge-manifest-epoch"),
    );
    try std.testing.expectEqual(first.ptr, second.ptr);

    var first_window = EdgeSegmentRegisteredRetentionWindow{
        .registry = &registry,
        .manifest_path = first,
    };
    var second_window = EdgeSegmentRegisteredRetentionWindow{
        .registry = &registry,
        .manifest_path = second,
    };

    first_window.deinit();
    const after_first = try registry.activeManifestPaths(std.testing.allocator);
    defer std.testing.allocator.free(after_first);
    try std.testing.expectEqual(@as(usize, 1), after_first.len);
    try std.testing.expectEqualStrings("edge-manifest-epoch", after_first[0]);

    second_window.deinit();
    const after_second = try registry.activeManifestPaths(std.testing.allocator);
    defer std.testing.allocator.free(after_second);
    try std.testing.expectEqual(@as(usize, 0), after_second.len);
}

test "node text retention registry deduplicates and reference counts windows" {
    var registry = NodeTextRunRetentionRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const first = try retainOwnedNodeTextRunManifestPath(
        &registry,
        try std.testing.allocator.dupe(u8, "node-text-manifest-epoch"),
    );
    const second = try retainOwnedNodeTextRunManifestPath(
        &registry,
        try std.testing.allocator.dupe(u8, "node-text-manifest-epoch"),
    );
    try std.testing.expectEqual(first.ptr, second.ptr);

    var first_window = NodeTextRunRegisteredRetentionWindow{
        .registry = &registry,
        .manifest_path = first,
    };
    var second_window = NodeTextRunRegisteredRetentionWindow{
        .registry = &registry,
        .manifest_path = second,
    };

    first_window.deinit();
    const after_first = try registry.activeManifestPaths(std.testing.allocator);
    defer std.testing.allocator.free(after_first);
    try std.testing.expectEqual(@as(usize, 1), after_first.len);
    try std.testing.expectEqualStrings("node-text-manifest-epoch", after_first[0]);

    second_window.deinit();
    const after_second = try registry.activeManifestPaths(std.testing.allocator);
    defer std.testing.allocator.free(after_second);
    try std.testing.expectEqual(@as(usize, 0), after_second.len);
}
