const std = @import("std");

/// Owns the allocation, projection, rollback, and teardown order of every
/// heap-backed cache retained by `storage.Store`. Concrete cache types and
/// their type-specific cleanup remain private to the storage facade through
/// `Ops`; this owner controls the complete multi-resource lifetime.
pub fn StoreCacheResources(comptime Ops: type) type {
    return struct {
        index_meta_cache: *Ops.IndexMetaCacheType,
        node_text_delta_header_cache: *Ops.NodeTextDeltaHeaderCacheType,
        node_text_delta_run_cache: *Ops.NodeTextDeltaRunCacheType,
        node_text_run_manifest_cache: *Ops.NodeTextRunManifestCacheType,
        node_text_base_filter_cache: *Ops.NodeTextBaseHashFilterCacheType,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            const index_meta_cache = try Ops.createIndexMetaCache(allocator);
            errdefer Ops.destroyIndexMetaCache(allocator, index_meta_cache);
            const node_text_delta_header_cache = try Ops.createNodeTextDeltaHeaderCache(allocator);
            errdefer Ops.destroyNodeTextDeltaHeaderCache(allocator, node_text_delta_header_cache);
            const node_text_delta_run_cache = try Ops.createNodeTextDeltaRunCache(allocator);
            errdefer Ops.destroyNodeTextDeltaRunCache(allocator, node_text_delta_run_cache);
            const node_text_run_manifest_cache = try Ops.createNodeTextRunManifestCache(allocator);
            errdefer Ops.destroyNodeTextRunManifestCache(allocator, node_text_run_manifest_cache);
            const node_text_base_filter_cache = try Ops.createNodeTextBaseHashFilterCache(allocator);
            errdefer Ops.destroyNodeTextBaseHashFilterCache(allocator, node_text_base_filter_cache);

            return .{
                .index_meta_cache = index_meta_cache,
                .node_text_delta_header_cache = node_text_delta_header_cache,
                .node_text_delta_run_cache = node_text_delta_run_cache,
                .node_text_run_manifest_cache = node_text_run_manifest_cache,
                .node_text_base_filter_cache = node_text_base_filter_cache,
            };
        }

        /// Reconstitutes the resource owner from the stable Store fields so
        /// normal Store teardown follows the same order as partial rollback.
        pub fn borrowOwner(owner: anytype) Self {
            return .{
                .index_meta_cache = owner.index_meta_cache,
                .node_text_delta_header_cache = owner.node_text_delta_header_cache,
                .node_text_delta_run_cache = owner.node_text_delta_run_cache,
                .node_text_run_manifest_cache = owner.node_text_run_manifest_cache,
                .node_text_base_filter_cache = owner.node_text_base_filter_cache,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            Ops.destroyIndexMetaCache(allocator, self.index_meta_cache);
            Ops.destroyNodeTextDeltaHeaderCache(allocator, self.node_text_delta_header_cache);
            Ops.destroyNodeTextDeltaRunCache(allocator, self.node_text_delta_run_cache);
            Ops.destroyNodeTextRunManifestCache(allocator, self.node_text_run_manifest_cache);
            Ops.destroyNodeTextBaseHashFilterCache(allocator, self.node_text_base_filter_cache);
            self.* = undefined;
        }
    };
}

const TestCacheKind = enum(u8) {
    index_meta,
    node_text_delta_header,
    node_text_delta_run,
    node_text_run_manifest,
    node_text_base_filter,
};

const TestCache = struct {
    kind: TestCacheKind,
    nested: []u8,
};

var test_destroyed: [5]TestCacheKind = undefined;
var test_destroyed_count: usize = 0;

const TestOps = struct {
    pub const IndexMetaCacheType = TestCache;
    pub const NodeTextDeltaHeaderCacheType = TestCache;
    pub const NodeTextDeltaRunCacheType = TestCache;
    pub const NodeTextRunManifestCacheType = TestCache;
    pub const NodeTextBaseHashFilterCacheType = TestCache;

    fn create(allocator: std.mem.Allocator, kind: TestCacheKind) !*TestCache {
        const cache = try allocator.create(TestCache);
        errdefer allocator.destroy(cache);
        const nested = try allocator.alloc(u8, @intFromEnum(kind) + 1);
        cache.* = .{ .kind = kind, .nested = nested };
        return cache;
    }

    fn destroy(allocator: std.mem.Allocator, cache: *TestCache) void {
        test_destroyed[test_destroyed_count] = cache.kind;
        test_destroyed_count += 1;
        allocator.free(cache.nested);
        allocator.destroy(cache);
    }

    pub fn createIndexMetaCache(allocator: std.mem.Allocator) !*IndexMetaCacheType {
        return create(allocator, .index_meta);
    }

    pub fn destroyIndexMetaCache(allocator: std.mem.Allocator, cache: *IndexMetaCacheType) void {
        destroy(allocator, cache);
    }

    pub fn createNodeTextDeltaHeaderCache(allocator: std.mem.Allocator) !*NodeTextDeltaHeaderCacheType {
        return create(allocator, .node_text_delta_header);
    }

    pub fn destroyNodeTextDeltaHeaderCache(allocator: std.mem.Allocator, cache: *NodeTextDeltaHeaderCacheType) void {
        destroy(allocator, cache);
    }

    pub fn createNodeTextDeltaRunCache(allocator: std.mem.Allocator) !*NodeTextDeltaRunCacheType {
        return create(allocator, .node_text_delta_run);
    }

    pub fn destroyNodeTextDeltaRunCache(allocator: std.mem.Allocator, cache: *NodeTextDeltaRunCacheType) void {
        destroy(allocator, cache);
    }

    pub fn createNodeTextRunManifestCache(allocator: std.mem.Allocator) !*NodeTextRunManifestCacheType {
        return create(allocator, .node_text_run_manifest);
    }

    pub fn destroyNodeTextRunManifestCache(allocator: std.mem.Allocator, cache: *NodeTextRunManifestCacheType) void {
        destroy(allocator, cache);
    }

    pub fn createNodeTextBaseHashFilterCache(allocator: std.mem.Allocator) !*NodeTextBaseHashFilterCacheType {
        return create(allocator, .node_text_base_filter);
    }

    pub fn destroyNodeTextBaseHashFilterCache(allocator: std.mem.Allocator, cache: *NodeTextBaseHashFilterCacheType) void {
        destroy(allocator, cache);
    }
};

const test_resources = StoreCacheResources(TestOps);

fn resetDestroyed() void {
    test_destroyed_count = 0;
}

test "store cache resources construct project and tear down in owner order" {
    resetDestroyed();
    var resources = try test_resources.init(std.testing.allocator);

    const Owner = struct {
        index_meta_cache: *TestCache,
        node_text_delta_header_cache: *TestCache,
        node_text_delta_run_cache: *TestCache,
        node_text_run_manifest_cache: *TestCache,
        node_text_base_filter_cache: *TestCache,
    };
    const owner = Owner{
        .index_meta_cache = resources.index_meta_cache,
        .node_text_delta_header_cache = resources.node_text_delta_header_cache,
        .node_text_delta_run_cache = resources.node_text_delta_run_cache,
        .node_text_run_manifest_cache = resources.node_text_run_manifest_cache,
        .node_text_base_filter_cache = resources.node_text_base_filter_cache,
    };
    const projected = test_resources.borrowOwner(owner);
    try std.testing.expect(projected.index_meta_cache == resources.index_meta_cache);
    try std.testing.expect(projected.node_text_delta_header_cache == resources.node_text_delta_header_cache);
    try std.testing.expect(projected.node_text_delta_run_cache == resources.node_text_delta_run_cache);
    try std.testing.expect(projected.node_text_run_manifest_cache == resources.node_text_run_manifest_cache);
    try std.testing.expect(projected.node_text_base_filter_cache == resources.node_text_base_filter_cache);

    resources.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(TestCacheKind, &.{
        .index_meta,
        .node_text_delta_header,
        .node_text_delta_run,
        .node_text_run_manifest,
        .node_text_base_filter,
    }, test_destroyed[0..test_destroyed_count]);
}

fn storeCacheResourcesAllocationFailure(allocator: std.mem.Allocator) !void {
    resetDestroyed();
    var resources = try test_resources.init(allocator);
    defer resources.deinit(allocator);
}

test "store cache resources roll back every allocation failure including nested state" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        storeCacheResourcesAllocationFailure,
        .{},
    );
}
