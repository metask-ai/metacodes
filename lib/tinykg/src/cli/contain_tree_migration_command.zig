const std = @import("std");

/// `reparent-contain` CLI control plane.
///
/// Concrete Store, traversal, node/edge ids, project-tree classification, and
/// persistence records stay behind `Ops`. This owner validates syntax before
/// opening a context, maps the read-only inspection state machine to the
/// stable CLI output contract, and commits only a fully prepared plan. The
/// commit deliberately preserves append-before-tombstone durability; it does
/// not claim transaction atomicity across individual edge appends.
pub fn ContainTreeMigrationCommand(comptime Ops: type) type {
    return struct {
        const NodeId = Ops.NodeId;

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db = try Ops.parseDbArguments(allocator, io, args);
            const from_id = try Ops.parseNodeId(db.rest[0]);
            const to_id = try Ops.parseNodeId(db.rest[1]);
            if (Ops.nodeIdValue(from_id) == Ops.nodeIdValue(to_id)) return error.InvalidId;

            var context = try Ops.Context.init(allocator, io, db.db_path);
            defer context.deinit();

            var inspection = try context.inspect(from_id, to_id);
            switch (inspection) {
                .scan_cap_exceeded => |cap| {
                    try writer.print(
                        "reparent-contain rejected from={} to={} reason=subtree_exceeds_scan_cap cap={}\n",
                        .{ Ops.nodeIdValue(from_id), Ops.nodeIdValue(to_id), cap },
                    );
                },
                .cycle => {
                    try writer.print(
                        "reparent-contain rejected from={} to={} reason=would_create_contain_cycle\n",
                        .{ Ops.nodeIdValue(from_id), Ops.nodeIdValue(to_id) },
                    );
                },
                .project_violation => |child_id| {
                    try writer.print(
                        "reparent-contain rejected from={} to={} reason=project_child_requires_project_parent child={}\n",
                        .{
                            Ops.nodeIdValue(from_id),
                            Ops.nodeIdValue(to_id),
                            Ops.nodeIdValue(child_id),
                        },
                    );
                    return error.ProjectTreeViolation;
                },
                .ready => |*plan| {
                    defer plan.deinit();
                    const result = try context.commit(plan);
                    try writer.print(
                        "reparented from={} to={} moved={} deduped={} old_edges_removed={}\n",
                        .{
                            Ops.nodeIdValue(from_id),
                            Ops.nodeIdValue(to_id),
                            result.moved,
                            result.deduped,
                            result.old_edges_removed,
                        },
                    );
                },
            }
        }
    };
}

const TestOps = struct {
    pub const NodeId = u64;

    pub const Plan = struct {
        pub fn deinit(_: *Plan) void {
            TestOps.record(.plan_close);
        }
    };

    pub const Inspection = union(enum) {
        scan_cap_exceeded: usize,
        cycle,
        project_violation: NodeId,
        ready: Plan,
    };

    pub const CommitResult = struct {
        moved: usize,
        deduped: usize,
        old_edges_removed: usize,
    };

    const InspectionMode = enum {
        ready,
        missing_endpoint,
        scan_cap_exceeded,
        cycle,
        project_violation,
    };

    const Step = enum {
        parse_node,
        open,
        inspect,
        commit,
        output,
        plan_close,
        close,
    };

    var steps: [32]Step = undefined;
    var step_count: usize = 0;
    var inspection_mode: InspectionMode = .ready;
    var fail_commit = false;
    var inspected_from: NodeId = 0;
    var inspected_to: NodeId = 0;

    fn reset() void {
        step_count = 0;
        inspection_mode = .ready;
        fail_commit = false;
        inspected_from = 0;
        inspected_to = 0;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    pub fn parseDbArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        const rest = args[2..];
        if (rest.len < 2) return error.MissingArgument;
        if (rest.len > 2) return error.TooManyArguments;
        return .{ .db_path = "db", .rest = rest };
    }

    pub fn parseNodeId(value: []const u8) !NodeId {
        record(.parse_node);
        return std.fmt.parseInt(u64, value, 10) catch return error.InvalidNodeId;
    }

    pub fn nodeIdValue(node_id: NodeId) u64 {
        return node_id;
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.record(.open);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.close);
        }

        pub fn inspect(_: *Context, from_id: NodeId, to_id: NodeId) !Inspection {
            TestOps.record(.inspect);
            TestOps.inspected_from = from_id;
            TestOps.inspected_to = to_id;
            return switch (TestOps.inspection_mode) {
                .ready => .{ .ready = .{} },
                .missing_endpoint => error.NotFound,
                .scan_cap_exceeded => .{ .scan_cap_exceeded = 100_000 },
                .cycle => .cycle,
                .project_violation => .{ .project_violation = 37 },
            };
        }

        pub fn commit(_: *Context, _: *Plan) !CommitResult {
            TestOps.record(.commit);
            if (TestOps.fail_commit) return error.InvalidRecord;
            return .{
                .moved = 2,
                .deduped = 1,
                .old_edges_removed = 3,
            };
        }
    };
};

const TestWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestWriter) void {
        self.buffer.deinit(self.allocator);
    }

    fn print(self: *TestWriter, comptime format: []const u8, args: anytype) !void {
        TestOps.record(.output);
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        TestOps.record(.output);
        return error.OutputClosed;
    }
};

const test_command = ContainTreeMigrationCommand(TestOps);

test "contain tree migration commits a prepared plan before success output" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "reparent-contain", "11", "19" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );

    try std.testing.expectEqualStrings(
        "reparented from=11 to=19 moved=2 deduped=1 old_edges_removed=3\n",
        writer.buffer.items,
    );
    try std.testing.expectEqual(@as(u64, 11), TestOps.inspected_from);
    try std.testing.expectEqual(@as(u64, 19), TestOps.inspected_to);
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node, .open, .inspect, .commit, .output, .plan_close, .close },
        TestOps.steps[0..TestOps.step_count],
    );
}

test "contain tree migration rejects self id before context acquisition" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidId,
        test_command.run(
            &.{ "tinykg", "reparent-contain", "7", "7" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node },
        TestOps.steps[0..TestOps.step_count],
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "contain tree migration closes context on missing endpoint without output" {
    TestOps.reset();
    TestOps.inspection_mode = .missing_endpoint;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.NotFound,
        test_command.run(
            &.{ "tinykg", "reparent-contain", "3", "5" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node, .open, .inspect, .close },
        TestOps.steps[0..TestOps.step_count],
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "contain tree migration reports scan cap and cycle without commit" {
    TestOps.reset();
    TestOps.inspection_mode = .scan_cap_exceeded;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "reparent-contain", "2", "9" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings(
        "reparent-contain rejected from=2 to=9 reason=subtree_exceeds_scan_cap cap=100000\n",
        writer.buffer.items,
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node, .open, .inspect, .output, .close },
        TestOps.steps[0..TestOps.step_count],
    );

    TestOps.reset();
    TestOps.inspection_mode = .cycle;
    writer.buffer.clearRetainingCapacity();
    try test_command.run(
        &.{ "tinykg", "reparent-contain", "2", "9" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings(
        "reparent-contain rejected from=2 to=9 reason=would_create_contain_cycle\n",
        writer.buffer.items,
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node, .open, .inspect, .output, .close },
        TestOps.steps[0..TestOps.step_count],
    );
}

test "contain tree migration prints project violation before returning error" {
    TestOps.reset();
    TestOps.inspection_mode = .project_violation;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.ProjectTreeViolation,
        test_command.run(
            &.{ "tinykg", "reparent-contain", "2", "9" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualStrings(
        "reparent-contain rejected from=2 to=9 reason=project_child_requires_project_parent child=37\n",
        writer.buffer.items,
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node, .open, .inspect, .output, .close },
        TestOps.steps[0..TestOps.step_count],
    );
}

test "contain tree migration commit failure closes plan and context without output" {
    TestOps.reset();
    TestOps.fail_commit = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_command.run(
            &.{ "tinykg", "reparent-contain", "2", "9" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node, .open, .inspect, .commit, .plan_close, .close },
        TestOps.steps[0..TestOps.step_count],
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "contain tree migration writer failure preserves committed lifetime cleanup" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(
            &.{ "tinykg", "reparent-contain", "2", "9" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqualSlices(
        TestOps.Step,
        &.{ .parse_node, .parse_node, .open, .inspect, .commit, .output, .plan_close, .close },
        TestOps.steps[0..TestOps.step_count],
    );
}
