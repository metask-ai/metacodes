const std = @import("std");

/// Ordinary edge-mutation CLI control plane.
///
/// Concrete node/edge ids, Store and schema representations, endpoint and
/// contain-tree validation, DAG policy, and external-key indexes stay behind
/// `Ops`. This owner keeps all syntax validation before context acquisition,
/// closes every mutation context, and publishes stable output only after the
/// complete mutation succeeds. `reparent-contain` is intentionally excluded:
/// subtree migration has a distinct cycle/preflight/append/tombstone protocol.
pub fn EdgeMutationCommands(comptime Ops: type) type {
    return struct {
        const NodeId = Ops.NodeId;
        const EdgeId = Ops.EdgeId;

        const AddRequest = struct {
            db_path: []const u8,
            schema_path: ?[]const u8,
            src: NodeId,
            rel_label: []const u8,
            dst: NodeId,
        };

        fn prepareAdd(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
        ) !AddRequest {
            const db = try Ops.parseDbArguments(allocator, io, args, 3, 5);
            const selection = try Ops.parseTrailingSchema(db.rest, 3);
            return .{
                .db_path = db.db_path,
                .schema_path = selection.schema_path,
                .src = try Ops.parseNodeId(selection.positionals[0]),
                .rel_label = selection.positionals[1],
                .dst = try Ops.parseNodeId(selection.positionals[2]),
            };
        }

        pub fn runAdd(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const request = try prepareAdd(allocator, io, args);
            var context = try Ops.Context.init(allocator, io, request.db_path);
            defer context.deinit();

            const edge_id = try context.add(
                request.src,
                request.rel_label,
                request.dst,
                request.schema_path,
            );
            try writer.print("edge {}\n", .{Ops.edgeIdValue(edge_id)});
        }

        pub fn runDelete(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args, 1, 1);
            const edge_id = try Ops.parseEdgeId(db.rest[0]);
            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();

            try context.delete(edge_id);
            try writer.print("deleted edge {}\n", .{Ops.edgeIdValue(edge_id)});
        }

        pub fn runDeleteBatch(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(
                allocator,
                io,
                args,
                1,
                std.math.maxInt(usize),
            );
            var edge_ids = std.ArrayList(EdgeId).empty;
            defer edge_ids.deinit(allocator);
            try edge_ids.ensureTotalCapacityPrecise(allocator, db.rest.len);
            for (db.rest) |arg| {
                edge_ids.appendAssumeCapacity(try Ops.parseEdgeId(arg));
            }

            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();
            try context.deleteBatch(edge_ids.items);
            try writer.print("deleted edges={}\n", .{edge_ids.items.len});
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
    pub const NodeId = u64;
    pub const EdgeId = u64;

    const Selection = struct {
        positionals: []const []const u8,
        schema_path: ?[]const u8 = null,
    };

    const Step = enum {
        parse_node,
        parse_edge,
        open,
        add,
        delete,
        delete_batch,
        close,
    };

    var steps: [32]Step = undefined;
    var step_count: usize = 0;
    var selected_schema_path: ?[]const u8 = null;
    var last_src: NodeId = 0;
    var last_dst: NodeId = 0;
    var last_rel_label: []const u8 = "";
    var last_edge_id: EdgeId = 0;
    var batch_ids: [8]EdgeId = undefined;
    var batch_count: usize = 0;
    var add_result: EdgeId = 17;
    var fail_mutation = false;

    fn reset() void {
        step_count = 0;
        selected_schema_path = null;
        last_src = 0;
        last_dst = 0;
        last_rel_label = "";
        last_edge_id = 0;
        batch_count = 0;
        add_result = 17;
        fail_mutation = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    pub fn parseDbArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
        min_rest: usize,
        max_rest: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const rest = args[2..];
        if (rest.len < min_rest) return error.MissingArgument;
        if (rest.len > max_rest) return error.TooManyArguments;
        return .{ .db_path = "db", .rest = rest };
    }

    pub fn parseTrailingSchema(rest: []const []const u8, positional_count: usize) !Selection {
        if (rest.len == positional_count) return .{ .positionals = rest };
        if (rest.len == positional_count + 2 and std.mem.eql(u8, rest[positional_count], "--schema")) {
            return .{
                .positionals = rest[0..positional_count],
                .schema_path = rest[positional_count + 1],
            };
        }
        if (rest.len > positional_count and std.mem.startsWith(u8, rest[positional_count], "--")) {
            return error.UnknownOption;
        }
        return error.TooManyArguments;
    }

    pub fn parseNodeId(value: []const u8) !NodeId {
        record(.parse_node);
        return std.fmt.parseInt(u64, value, 10) catch return error.InvalidNodeId;
    }

    pub fn parseEdgeId(value: []const u8) !EdgeId {
        record(.parse_edge);
        return std.fmt.parseInt(u64, value, 10) catch return error.InvalidEdgeId;
    }

    pub fn edgeIdValue(edge_id: EdgeId) u64 {
        return edge_id;
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.record(.open);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.close);
        }

        pub fn add(
            _: *Context,
            src: NodeId,
            rel_label: []const u8,
            dst: NodeId,
            schema_path: ?[]const u8,
        ) !EdgeId {
            TestOps.record(.add);
            TestOps.last_src = src;
            TestOps.last_dst = dst;
            TestOps.last_rel_label = rel_label;
            TestOps.selected_schema_path = schema_path;
            if (TestOps.fail_mutation) return error.InvalidRecord;
            return TestOps.add_result;
        }

        pub fn delete(_: *Context, edge_id: EdgeId) !void {
            TestOps.record(.delete);
            TestOps.last_edge_id = edge_id;
            if (TestOps.fail_mutation) return error.InvalidRecord;
        }

        pub fn deleteBatch(_: *Context, edge_ids: []const EdgeId) !void {
            TestOps.record(.delete_batch);
            TestOps.batch_count = edge_ids.len;
            for (edge_ids, 0..) |edge_id, index| TestOps.batch_ids[index] = edge_id;
            if (TestOps.fail_mutation) return error.InvalidRecord;
        }
    };
};

const test_commands = EdgeMutationCommands(TestOps);

test "edge mutation command family routes add and schema selection" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runAdd(
        &.{ "tinykg", "relate", "3", "related_to", "5", "--schema", "schema.json" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );

    try std.testing.expectEqualStrings("edge 17\n", writer.buffer.items);
    try std.testing.expectEqual(@as(u64, 3), TestOps.last_src);
    try std.testing.expectEqual(@as(u64, 5), TestOps.last_dst);
    try std.testing.expectEqualStrings("related_to", TestOps.last_rel_label);
    try std.testing.expectEqualStrings("schema.json", TestOps.selected_schema_path.?);
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node, .open, .add, .close },
        TestOps.steps[0..TestOps.step_count],
    );
}

test "edge mutation command family preserves single and batch delete output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_commands.runDelete(
        &.{ "tinykg", "delete-edge", "23" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("deleted edge 23\n", writer.buffer.items);
    try std.testing.expectEqual(@as(u64, 23), TestOps.last_edge_id);
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_edge, .open, .delete, .close },
        TestOps.steps[0..TestOps.step_count],
    );

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runDeleteBatch(
        &.{ "tinykg", "delete-edges", "7", "11", "13" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("deleted edges=3\n", writer.buffer.items);
    try std.testing.expectEqualSlices(u64, &.{ 7, 11, 13 }, TestOps.batch_ids[0..TestOps.batch_count]);
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_edge, .parse_edge, .parse_edge, .open, .delete_batch, .close },
        TestOps.steps[0..TestOps.step_count],
    );
}

test "edge mutation arguments fail before context acquisition" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidNodeId,
        test_commands.runAdd(
            &.{ "tinykg", "add-edge", "bad-src", "related_to", "bad-dst" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{.parse_node},
        TestOps.steps[0..TestOps.step_count],
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);

    TestOps.reset();
    try std.testing.expectError(
        error.InvalidEdgeId,
        test_commands.runDeleteBatch(
            &.{ "tinykg", "delete-edges", "1", "bad", "3" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_edge, .parse_edge },
        TestOps.steps[0..TestOps.step_count],
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "edge mutation failures close context without publishing output" {
    TestOps.reset();
    TestOps.fail_mutation = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runAdd(
            &.{ "tinykg", "add-edge", "1", "related_to", "2" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node, .open, .add, .close },
        TestOps.steps[0..TestOps.step_count],
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "edge mutation lifetimes close after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runDelete(
            &.{ "tinykg", "delete-edge", "19" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_edge, .open, .delete, .close },
        TestOps.steps[0..TestOps.step_count],
    );
}
