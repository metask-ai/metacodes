const std = @import("std");

/// Canonical projection of a graph node into text-searchable document fields.
/// Persistent and in-memory indexes share this lower layer so name/summary and
/// deletion admission cannot drift between their independent data planes.
pub fn SearchableDocument(comptime core: type, comptime storage: type) type {
    return struct {
        const Store = storage.Store;

        pub const TextDocument = struct {
            node_id: core.NodeId,
            kind: core.NodeKind,
            text: []const u8,
            name: ?[]const u8 = null,
            summary: ?[]const u8 = null,
        };

        pub const SearchableNodeMetadata = struct {
            name: ?[]const u8 = null,
            summary: ?[]const u8 = null,
            owned: bool = false,

            pub fn deinit(self: *SearchableNodeMetadata, allocator: std.mem.Allocator) void {
                if (self.owned) {
                    if (self.name) |name| allocator.free(name);
                    if (self.summary) |summary| allocator.free(summary);
                }
                self.* = .{};
            }
        };

        pub fn readSearchableNodeMetadata(
            allocator: std.mem.Allocator,
            store: Store,
            node_id: core.NodeId,
        ) !SearchableNodeMetadata {
            var out = SearchableNodeMetadata{ .owned = true };
            errdefer out.deinit(allocator);
            out.name = try store.getNodeStringProperty(allocator, node_id, "name");
            out.summary = try store.getNodeStringProperty(allocator, node_id, "summary");
            return out;
        }

        pub const SearchableNodeMetadataSnapshot = struct {
            allocator: std.mem.Allocator,
            snapshot: storage.PropertySnapshot,
            by_node: std.AutoHashMap(u64, SearchableNodeMetadata),

            pub fn init(
                allocator: std.mem.Allocator,
                store: Store,
            ) !SearchableNodeMetadataSnapshot {
                const snapshot = try store.loadSearchableNodeMetadataSnapshot(allocator);
                return initFromSnapshotDeadline(allocator, snapshot, .none);
            }

            pub fn initLimited(
                allocator: std.mem.Allocator,
                store: Store,
                max_string_bytes: u64,
                max_delta_scan_bytes: u64,
                deadline: core.QueryDeadline,
            ) !SearchableNodeMetadataSnapshot {
                const snapshot = try store.loadSearchableNodeMetadataSnapshotWithLimitsDeadline(
                    allocator,
                    max_string_bytes,
                    max_delta_scan_bytes,
                    deadline,
                );
                return initFromSnapshotDeadline(allocator, snapshot, deadline);
            }

            pub fn initFromSnapshotDeadline(
                allocator: std.mem.Allocator,
                snapshot_input: storage.PropertySnapshot,
                deadline: core.QueryDeadline,
            ) !SearchableNodeMetadataSnapshot {
                var snapshot = snapshot_input;
                errdefer snapshot.deinit(allocator);
                var by_node = std.AutoHashMap(u64, SearchableNodeMetadata).init(allocator);
                errdefer by_node.deinit();

                const name_hash = storage.propertyKeyHashForLookup("name");
                const summary_hash = storage.propertyKeyHashForLookup("summary");
                for (snapshot.entries) |entry| {
                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    if (entry.value_kind != .string) continue;
                    const node_id = switch (entry.owner) {
                        .node => |id| id.toInt(),
                        .edge => continue,
                    };
                    if (entry.key_hash != name_hash and entry.key_hash != summary_hash) continue;
                    const slot = try by_node.getOrPut(node_id);
                    if (!slot.found_existing) slot.value_ptr.* = .{};
                    if (entry.key_hash == name_hash) {
                        slot.value_ptr.name = entry.string_value;
                    } else {
                        slot.value_ptr.summary = entry.string_value;
                    }
                }
                return .{ .allocator = allocator, .snapshot = snapshot, .by_node = by_node };
            }

            pub fn deinit(self: *SearchableNodeMetadataSnapshot) void {
                self.by_node.deinit();
                self.snapshot.deinit(self.allocator);
                self.* = undefined;
            }

            pub fn get(
                self: *const SearchableNodeMetadataSnapshot,
                node_id: core.NodeId,
            ) SearchableNodeMetadata {
                return self.by_node.get(node_id.toInt()) orelse .{};
            }
        };

        pub const Internal = struct {
            pub const deleted_node_tombstone_prefix = "__tinykg_deleted_node__ ";

            pub fn isDeletedNodeTombstoneText(text: []const u8) bool {
                return std.mem.startsWith(u8, text, deleted_node_tombstone_prefix);
            }

            pub fn isDeletedNodeTombstoneNode(kind: core.NodeKind, text: []const u8) bool {
                return kind == .edit and isDeletedNodeTombstoneText(text);
            }
        };
    };
}

const TestCore = struct {
    pub const Error = error{BudgetExceeded};
    pub const NodeKind = enum(u16) { task, edit };
    pub const NodeId = enum(u64) {
        none = 0,
        _,

        pub fn fromInt(value: u64) NodeId {
            return @enumFromInt(value);
        }

        pub fn toInt(self: NodeId) u64 {
            return @intFromEnum(self);
        }
    };
    pub const QueryDeadline = enum {
        none,
        immediate,

        pub fn expired(self: QueryDeadline) bool {
            return self == .immediate;
        }
    };
};

const TestStorage = struct {
    const ValueKind = enum { string, uint };
    const Owner = union(enum) { node: TestCore.NodeId, edge: u64 };
    const Entry = struct {
        owner: Owner,
        key_hash: u64,
        value_kind: ValueKind,
        string_value: []const u8 = "",
    };

    pub const PropertySnapshot = struct {
        entries: []const Entry,

        pub fn deinit(_: *PropertySnapshot, _: std.mem.Allocator) void {}
    };

    pub fn propertyKeyHashForLookup(key: []const u8) u64 {
        if (std.mem.eql(u8, key, "name")) return 1;
        if (std.mem.eql(u8, key, "summary")) return 2;
        return 3;
    }

    pub const Store = struct {
        entries: []const Entry = &.{},

        pub fn loadSearchableNodeMetadataSnapshot(self: Store, _: std.mem.Allocator) !PropertySnapshot {
            return .{ .entries = self.entries };
        }

        pub fn loadSearchableNodeMetadataSnapshotWithLimitsDeadline(
            self: Store,
            _: std.mem.Allocator,
            _: u64,
            _: u64,
            deadline: TestCore.QueryDeadline,
        ) !PropertySnapshot {
            if (deadline.expired()) return TestCore.Error.BudgetExceeded;
            return .{ .entries = self.entries };
        }

        pub fn getNodeStringProperty(
            _: Store,
            allocator: std.mem.Allocator,
            _: TestCore.NodeId,
            key: []const u8,
        ) !?[]u8 {
            if (std.mem.eql(u8, key, "name")) return @as(?[]u8, try allocator.dupe(u8, "owned-name"));
            return null;
        }
    };
};

const test_document = SearchableDocument(TestCore, TestStorage);

test "searchable document projection keeps node name and summary strings" {
    const entries = [_]TestStorage.Entry{
        .{ .owner = .{ .node = .fromInt(7) }, .key_hash = 1, .value_kind = .string, .string_value = "name" },
        .{ .owner = .{ .node = .fromInt(7) }, .key_hash = 2, .value_kind = .string, .string_value = "summary" },
    };
    var snapshot = try test_document.SearchableNodeMetadataSnapshot.init(
        std.testing.allocator,
        .{ .entries = &entries },
    );
    defer snapshot.deinit();

    const metadata = snapshot.get(.fromInt(7));
    try std.testing.expectEqualStrings("name", metadata.name.?);
    try std.testing.expectEqualStrings("summary", metadata.summary.?);
}

test "searchable document projection excludes edges non-strings and unknown keys" {
    const entries = [_]TestStorage.Entry{
        .{ .owner = .{ .edge = 4 }, .key_hash = 1, .value_kind = .string, .string_value = "edge" },
        .{ .owner = .{ .node = .fromInt(7) }, .key_hash = 1, .value_kind = .uint },
        .{ .owner = .{ .node = .fromInt(7) }, .key_hash = 3, .value_kind = .string, .string_value = "ignored" },
    };
    var snapshot = try test_document.SearchableNodeMetadataSnapshot.init(
        std.testing.allocator,
        .{ .entries = &entries },
    );
    defer snapshot.deinit();
    const metadata = snapshot.get(.fromInt(7));
    try std.testing.expect(metadata.name == null);
    try std.testing.expect(metadata.summary == null);
}

test "searchable document projection enforces deadline before snapshot scan" {
    const entries = [_]TestStorage.Entry{
        .{ .owner = .{ .node = .fromInt(7) }, .key_hash = 1, .value_kind = .string, .string_value = "name" },
    };
    try std.testing.expectError(TestCore.Error.BudgetExceeded, test_document.SearchableNodeMetadataSnapshot.initLimited(
        std.testing.allocator,
        .{ .entries = &entries },
        100,
        100,
        .immediate,
    ));
}

test "searchable document tombstone admission is exact" {
    try std.testing.expect(test_document.Internal.isDeletedNodeTombstoneText("__tinykg_deleted_node__ 7"));
    try std.testing.expect(test_document.Internal.isDeletedNodeTombstoneNode(.edit, "__tinykg_deleted_node__ 7"));
    try std.testing.expect(!test_document.Internal.isDeletedNodeTombstoneNode(.task, "__tinykg_deleted_node__ 7"));
    try std.testing.expect(!test_document.Internal.isDeletedNodeTombstoneNode(.edit, "__tinykg_deleted_node__"));
}

test "searchable document owned metadata deinitializes optional fields" {
    var metadata = try test_document.readSearchableNodeMetadata(
        std.testing.allocator,
        .{},
        .fromInt(1),
    );
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("owned-name", metadata.name.?);
    try std.testing.expect(metadata.summary == null);
}
