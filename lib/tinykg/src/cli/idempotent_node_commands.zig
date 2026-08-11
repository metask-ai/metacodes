const std = @import("std");

/// Idempotent node-infrastructure CLI control plane.
///
/// Concrete node ids, schema registries, Store indexes, task status, anchor
/// representations, and contain-edge persistence stay behind `Ops`. This owner
/// keeps `ensure-node` and `ensure-anchor` on one prepare-before-lock, shared
/// context-lifetime, and success-only result-publication protocol. The concrete
/// anchor operation intentionally remains an ordered sequence with a known
/// crash window rather than claiming transaction atomicity.
pub fn IdempotentNodeCommands(comptime Ops: type) type {
    return struct {
        fn publishResult(writer: anytype, result: anytype) !void {
            try writer.print(
                "node {} created={}\n",
                .{ result.node_id, @intFromBool(result.created) },
            );
        }

        pub fn runEnsureNode(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            var prepared = try Ops.prepareEnsureNode(allocator, io, args);
            defer prepared.deinit(allocator);
            var context = try Ops.Context.init(allocator, io, prepared.db_path);
            defer context.deinit();

            const result = try context.ensureNode(allocator, &prepared);
            try publishResult(writer, result);
        }

        pub fn runEnsureAnchor(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            var prepared = try Ops.prepareEnsureAnchor(allocator, io, args);
            defer prepared.deinit(allocator);
            var context = try Ops.Context.init(allocator, io, prepared.db_path);
            defer context.deinit();

            const result = try context.ensureAnchor(allocator, &prepared);
            try publishResult(writer, result);
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
    const Command = enum { ensure_node, ensure_anchor };
    const Step = enum { prepare_node, prepare_anchor, open, ensure_node, ensure_anchor, close, deinit_prepared };

    const Prepared = struct {
        db_path: []const u8 = "db",
        command: Command,

        pub fn deinit(_: *Prepared, _: std.mem.Allocator) void {
            TestOps.record(.deinit_prepared);
        }
    };

    pub const PreparedEnsureNode = Prepared;
    pub const PreparedEnsureAnchor = Prepared;

    var steps: [16]Step = undefined;
    var step_count: usize = 0;
    var fail_prepare = false;
    var fail_ensure = false;
    var existing = false;

    fn reset() void {
        step_count = 0;
        fail_prepare = false;
        fail_ensure = false;
        existing = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn prepareEnsureNode(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !PreparedEnsureNode {
        record(.prepare_node);
        if (fail_prepare) return error.InvalidRecord;
        return .{ .command = .ensure_node };
    }

    pub fn prepareEnsureAnchor(_: std.mem.Allocator, _: std.Io, _: []const []const u8) !PreparedEnsureAnchor {
        record(.prepare_anchor);
        if (fail_prepare) return error.InvalidRecord;
        return .{ .command = .ensure_anchor };
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.record(.open);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.close);
        }

        pub fn ensureNode(_: *Context, _: std.mem.Allocator, prepared: *const PreparedEnsureNode) !struct { node_id: u64, created: bool } {
            TestOps.record(.ensure_node);
            try std.testing.expectEqual(Command.ensure_node, prepared.command);
            if (TestOps.fail_ensure) return error.InvalidRecord;
            return .{ .node_id = 17, .created = !TestOps.existing };
        }

        pub fn ensureAnchor(_: *Context, _: std.mem.Allocator, prepared: *const PreparedEnsureAnchor) !struct { node_id: u64, created: bool } {
            TestOps.record(.ensure_anchor);
            try std.testing.expectEqual(Command.ensure_anchor, prepared.command);
            if (TestOps.fail_ensure) return error.InvalidRecord;
            return .{ .node_id = 23, .created = !TestOps.existing };
        }
    };
};

const test_commands = IdempotentNodeCommands(TestOps);

test "idempotent node commands route both complete results" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try test_commands.runEnsureNode(&.{ "tinykg", "ensure-node", "project", "demo" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node 17 created=1\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .prepare_node, .open, .ensure_node, .close, .deinit_prepared });

    TestOps.reset();
    TestOps.existing = true;
    writer.buffer.clearRetainingCapacity();
    try test_commands.runEnsureAnchor(&.{ "tinykg", "ensure-anchor", "1", "task" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("node 23 created=0\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .prepare_anchor, .open, .ensure_anchor, .close, .deinit_prepared });
}

test "idempotent node command preparation fails before context acquisition" {
    TestOps.reset();
    TestOps.fail_prepare = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runEnsureNode(&.{ "tinykg", "ensure-node" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.prepare_node});
}

test "idempotent node command failures close context without output" {
    TestOps.reset();
    TestOps.fail_ensure = true;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.runEnsureAnchor(&.{ "tinykg", "ensure-anchor", "1", "task" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{ .prepare_anchor, .open, .ensure_anchor, .close, .deinit_prepared });
}

test "idempotent node command lifetimes close after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runEnsureNode(&.{ "tinykg", "ensure-node", "project", "demo" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .prepare_node, .open, .ensure_node, .close, .deinit_prepared });
}
