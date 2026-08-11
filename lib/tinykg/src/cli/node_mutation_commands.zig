const std = @import("std");

/// Node-mutation CLI control plane.
///
/// Concrete node ids, Store/schema representations, task lifecycle state,
/// governance metadata, Metaknow sidecars, and copy-on-write mechanics stay
/// behind `Ops`. This owner keeps preparation before context acquisition,
/// closes every mutation context, and publishes stable output only after the
/// complete mutation (or an intentional delete rejection) has resolved.
pub fn NodeMutationCommands(comptime Ops: type) type {
    return struct {
        pub fn runAdd(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            var prepared = try Ops.prepareAdd(allocator, io, args);
            defer prepared.deinit(allocator);
            var context = try Ops.Context.init(allocator, io, prepared.db_path);
            defer context.deinit();

            const result = try context.add(allocator, &prepared);
            try writer.print("node {}\n", .{result.node_id});
        }

        pub fn runUpdate(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            var prepared = try Ops.prepareUpdate(allocator, io, args);
            defer prepared.deinit(allocator);
            var context = try Ops.Context.init(allocator, io, prepared.db_path);
            defer context.deinit();

            const result = try context.update(allocator, &prepared);
            switch (result) {
                .rewritten => |value| try writer.print(
                    "updated node={} rewrite_mode=copy_on_write_full_store store_bytes_before={} nodes_rewritten={} edges_rewritten={} edges_removed={} text_rewarmed=0 text_index_current=0\n",
                    .{ value.node_id, value.store_bytes_before, value.nodes_rewritten, value.edges_rewritten, value.edges_removed },
                ),
                .versioned => |value| try writer.print(
                    "updated node={} new={} edge={} rel=deprecated_by update_mode=append_only_version store_bytes_before={} text_rewarmed=0 text_index_current=0\n",
                    .{ value.old_node_id, value.new_node_id, value.edge_id, value.store_bytes_before },
                ),
            }
        }

        pub fn runAppendVersion(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            var prepared = try Ops.prepareAppendVersion(allocator, io, args);
            defer prepared.deinit(allocator);
            var context = try Ops.Context.init(allocator, io, prepared.db_path);
            defer context.deinit();

            const result = try context.appendVersion(allocator, &prepared);
            try writer.print(
                "appended node_version old={} new={} edge={} rel=deprecated_by append_only=1 store_bytes_before={} text_rewarmed=0 text_index_current=0\n",
                .{ result.old_node_id, result.new_node_id, result.edge_id, result.store_bytes_before },
            );
        }

        pub fn runGovern(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            var prepared = try Ops.prepareGovern(allocator, io, args);
            defer prepared.deinit(allocator);
            var context = try Ops.Context.init(allocator, io, prepared.db_path);
            defer context.deinit();

            const result = try context.govern(allocator, &prepared);
            try writer.print(
                "governed node={} parent={s} rewrite_mode=incremental_append\n",
                .{ result.node_id, result.parent_id orelse "*" },
            );
        }

        pub fn runDelete(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            var prepared = try Ops.prepareDelete(allocator, io, args);
            defer prepared.deinit(allocator);
            var context = try Ops.Context.init(allocator, io, prepared.db_path);
            defer context.deinit();

            const result = try context.delete(allocator, &prepared);
            switch (result) {
                .rejected_children => |node_id| try writer.print(
                    "delete-node rejected node={} reason=has_contain_children\n",
                    .{node_id},
                ),
                .deleted => |value| try writer.print(
                    "deleted node={} tombstone=1 rewrite_mode=copy_on_write_full_store store_bytes_before={} nodes_rewritten={} edges_rewritten={} edges_removed={} text_rewarmed=0 text_index_current=0\n",
                    .{ value.node_id, value.store_bytes_before, value.nodes_rewritten, value.edges_rewritten, value.edges_removed },
                ),
            }
        }
    };
}

const TestWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestWriter) void {
        self.buffer.deinit(self.allocator);
    }

    fn print(self: *TestWriter, comptime format: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Command = enum { add, update, append_version, govern, delete };
    const Step = enum { prepare, open, mutate, close, deinit_prepared };

    const Prepared = struct {
        db_path: []const u8 = "db",
        command: Command,

        pub fn deinit(_: *Prepared, _: std.mem.Allocator) void {
            TestOps.record(.deinit_prepared);
        }
    };

    pub const PreparedAdd = Prepared;
    pub const PreparedUpdate = Prepared;
    pub const PreparedAppendVersion = Prepared;
    pub const PreparedGovern = Prepared;
    pub const PreparedDelete = Prepared;

    pub const UpdateResult = union(enum) {
        rewritten: struct {
            node_id: u64,
            store_bytes_before: u64,
            nodes_rewritten: usize,
            edges_rewritten: usize,
            edges_removed: usize,
        },
        versioned: struct {
            old_node_id: u64,
            new_node_id: u64,
            edge_id: u64,
            store_bytes_before: u64,
        },
    };

    pub const DeleteResult = union(enum) {
        rejected_children: u64,
        deleted: struct {
            node_id: u64,
            store_bytes_before: u64,
            nodes_rewritten: usize,
            edges_rewritten: usize,
            edges_removed: usize,
        },
    };

    var steps: [32]Step = undefined;
    var step_count: usize = 0;
    var fail_prepare = false;
    var fail_mutation = false;
    var update_versioned = false;
    var delete_rejected = false;

    fn reset() void {
        step_count = 0;
        fail_prepare = false;
        fail_mutation = false;
        update_versioned = false;
        delete_rejected = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn prepare(command: Command) !Prepared {
        record(.prepare);
        if (fail_prepare) return error.InvalidRecord;
        return .{ .command = command };
    }

    pub fn prepareAdd(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !PreparedAdd {
        return prepare(.add);
    }

    pub fn prepareUpdate(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !PreparedUpdate {
        return prepare(.update);
    }

    pub fn prepareAppendVersion(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !PreparedAppendVersion {
        return prepare(.append_version);
    }

    pub fn prepareGovern(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !PreparedGovern {
        return prepare(.govern);
    }

    pub fn prepareDelete(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !PreparedDelete {
        return prepare(.delete);
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.record(.open);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.close);
        }

        fn mutate(_: *Context, expected: Command, prepared: *const Prepared) !void {
            TestOps.record(.mutate);
            try std.testing.expectEqual(expected, prepared.command);
            if (TestOps.fail_mutation) return error.InvalidRecord;
        }

        pub fn add(self: *Context, _: std.mem.Allocator, prepared: *const PreparedAdd) !struct { node_id: u64 } {
            try self.mutate(.add, prepared);
            return .{ .node_id = 11 };
        }

        pub fn update(self: *Context, _: std.mem.Allocator, prepared: *const PreparedUpdate) !UpdateResult {
            try self.mutate(.update, prepared);
            if (TestOps.update_versioned) return .{ .versioned = .{
                .old_node_id = 12,
                .new_node_id = 13,
                .edge_id = 14,
                .store_bytes_before = 15,
            } };
            return .{ .rewritten = .{
                .node_id = 12,
                .store_bytes_before = 15,
                .nodes_rewritten = 2,
                .edges_rewritten = 3,
                .edges_removed = 4,
            } };
        }

        pub fn appendVersion(self: *Context, _: std.mem.Allocator, prepared: *const PreparedAppendVersion) !struct {
            old_node_id: u64,
            new_node_id: u64,
            edge_id: u64,
            store_bytes_before: u64,
        } {
            try self.mutate(.append_version, prepared);
            return .{ .old_node_id = 21, .new_node_id = 22, .edge_id = 23, .store_bytes_before = 24 };
        }

        pub fn govern(self: *Context, _: std.mem.Allocator, prepared: *const PreparedGovern) !struct {
            node_id: u64,
            parent_id: ?[]const u8,
        } {
            try self.mutate(.govern, prepared);
            return .{ .node_id = 31, .parent_id = "7" };
        }

        pub fn delete(self: *Context, _: std.mem.Allocator, prepared: *const PreparedDelete) !DeleteResult {
            try self.mutate(.delete, prepared);
            if (TestOps.delete_rejected) return .{ .rejected_children = 41 };
            return .{ .deleted = .{
                .node_id = 41,
                .store_bytes_before = 42,
                .nodes_rewritten = 5,
                .edges_rewritten = 6,
                .edges_removed = 7,
            } };
        }
    };
};

const test_commands = NodeMutationCommands(TestOps);

test "node mutation commands route all five bounded operations" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runAdd(&.{ "tinykg", "add-node" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node 11\n", writer.buffer.items);
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .prepare, .open, .mutate, .close, .deinit_prepared }, TestOps.steps[0..TestOps.step_count]);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runAppendVersion(&.{ "tinykg", "append-node-version" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("appended node_version old=21 new=22 edge=23 rel=deprecated_by append_only=1 store_bytes_before=24 text_rewarmed=0 text_index_current=0\n", writer.buffer.items);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runGovern(&.{ "tinykg", "govern-node" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("governed node=31 parent=7 rewrite_mode=incremental_append\n", writer.buffer.items);
}

test "node update commands preserve rewrite and append-only output variants" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runUpdate(&.{ "tinykg", "update-node" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("updated node=12 rewrite_mode=copy_on_write_full_store store_bytes_before=15 nodes_rewritten=2 edges_rewritten=3 edges_removed=4 text_rewarmed=0 text_index_current=0\n", writer.buffer.items);

    TestOps.reset();
    TestOps.update_versioned = true;
    writer.buffer.clearRetainingCapacity();
    try test_commands.runUpdate(&.{ "tinykg", "update-node" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("updated node=12 new=13 edge=14 rel=deprecated_by update_mode=append_only_version store_bytes_before=15 text_rewarmed=0 text_index_current=0\n", writer.buffer.items);
}

test "node delete commands preserve rejection and deletion output" {
    TestOps.reset();
    TestOps.delete_rejected = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runDelete(&.{ "tinykg", "delete-node" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("delete-node rejected node=41 reason=has_contain_children\n", writer.buffer.items);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runDelete(&.{ "tinykg", "delete-node" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("deleted node=41 tombstone=1 rewrite_mode=copy_on_write_full_store store_bytes_before=42 nodes_rewritten=5 edges_rewritten=6 edges_removed=7 text_rewarmed=0 text_index_current=0\n", writer.buffer.items);
}

test "node mutation preparation fails before context acquisition" {
    TestOps.reset();
    TestOps.fail_prepare = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runAdd(&.{ "tinykg", "add-node" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqualSlices(TestOps.Step, &.{.prepare}, TestOps.steps[0..TestOps.step_count]);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "node mutation failures close context without publishing output" {
    TestOps.reset();
    TestOps.fail_mutation = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runUpdate(&.{ "tinykg", "update-node" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .prepare, .open, .mutate, .close, .deinit_prepared }, TestOps.steps[0..TestOps.step_count]);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "node mutation lifetimes close after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runGovern(&.{ "tinykg", "govern-node" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqualSlices(TestOps.Step, &.{ .prepare, .open, .mutate, .close, .deinit_prepared }, TestOps.steps[0..TestOps.step_count]);
}
