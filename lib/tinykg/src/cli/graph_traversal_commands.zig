const std = @import("std");

/// Read-only graph traversal CLI control plane.
///
/// Concrete argument types, schema registries, Store/retention representations,
/// and traversal renderers stay behind `Ops.Context`. This owner keeps the
/// `neighbors`, `incoming`, and `path` commands on one context lifetime,
/// retries one recoverable persistent-index read, and publishes output only
/// after a complete traversal succeeds.
pub fn GraphTraversalCommands(comptime Ops: type) type {
    return struct {
        fn retryable(err: anyerror) bool {
            return switch (err) {
                error.FileNotFound, error.InvalidRecord => true,
                else => false,
            };
        }

        pub fn runNeighbors(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseNeighborsArguments(allocator, io, args);
            var context = try Ops.Context.init(allocator, io, parsed.db_path, parsed.schema_path);
            defer context.deinit();
            const output = context.renderNeighbors(allocator, parsed) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.renderNeighbors(allocator, parsed);
            };
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runIncoming(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseIncomingArguments(allocator, io, args);
            var context = try Ops.Context.init(allocator, io, parsed.db_path, parsed.schema_path);
            defer context.deinit();
            const output = context.renderIncoming(allocator, parsed) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.renderIncoming(allocator, parsed);
            };
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runPath(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parsePathArguments(allocator, io, args);
            var context = try Ops.Context.init(allocator, io, parsed.db_path, parsed.schema_path);
            defer context.deinit();
            const output = context.renderPath(allocator, parsed) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.renderPath(allocator, parsed);
            };
            defer allocator.free(output);
            try writer.writeAll(output);
        }
    };
}

const TestWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestWriter) void {
        self.buffer.deinit(self.allocator);
    }

    fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }
};

const FailingWriter = struct {
    fn writeAll(_: *FailingWriter, _: []const u8) error{OutputClosed}!void {
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Step = enum {
        parse_neighbors,
        parse_incoming,
        parse_path,
        init,
        render_neighbors,
        render_incoming,
        render_path,
        repair,
        deinit,
    };

    const Arguments = struct {
        db_path: []const u8,
        schema_path: ?[]const u8,
        output: []const u8,
    };

    var steps: [24]Step = undefined;
    var step_count: usize = 0;
    var next_failure: ?anyerror = null;

    fn reset() void {
        step_count = 0;
        next_failure = null;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    fn parse(step: Step, args: []const []const u8, output: []const u8) !Arguments {
        record(step);
        if (args.len > 2 and std.mem.eql(u8, args[2], "parse-error")) return error.InvalidNodeId;
        return .{ .db_path = "db", .schema_path = "schema.json", .output = output };
    }

    pub fn parseNeighborsArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
    ) !Arguments {
        return parse(.parse_neighbors, args, "neighbors\n");
    }

    pub fn parseIncomingArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
    ) !Arguments {
        return parse(.parse_incoming, args, "incoming\n");
    }

    pub fn parsePathArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
    ) !Arguments {
        return parse(.parse_path, args, "1 -> 2\n");
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8, _: ?[]const u8) !Context {
            TestOps.record(.init);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.deinit);
        }

        pub fn repair(_: *Context) !void {
            TestOps.record(.repair);
        }

        fn render(_: *Context, allocator: std.mem.Allocator, parsed: Arguments, step: Step) ![]u8 {
            TestOps.record(step);
            if (TestOps.next_failure) |err| {
                TestOps.next_failure = null;
                return err;
            }
            return allocator.dupe(u8, parsed.output);
        }

        pub fn renderNeighbors(self: *Context, allocator: std.mem.Allocator, parsed: Arguments) ![]u8 {
            return self.render(allocator, parsed, .render_neighbors);
        }

        pub fn renderIncoming(self: *Context, allocator: std.mem.Allocator, parsed: Arguments) ![]u8 {
            return self.render(allocator, parsed, .render_incoming);
        }

        pub fn renderPath(self: *Context, allocator: std.mem.Allocator, parsed: Arguments) ![]u8 {
            return self.render(allocator, parsed, .render_path);
        }
    };
};

const test_commands = GraphTraversalCommands(TestOps);

test "graph traversal command family routes complete outputs through one context" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try test_commands.runNeighbors(&.{ "tinykg", "neighbors", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("neighbors\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_neighbors, .init, .render_neighbors, .deinit });

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runIncoming(&.{ "tinykg", "incoming", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("incoming\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_incoming, .init, .render_incoming, .deinit });

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runPath(&.{ "tinykg", "path", "1", "2" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("1 -> 2\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse_path, .init, .render_path, .deinit });
}

test "graph traversal command family repairs one recoverable read before output" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.next_failure = error.FileNotFound;
    try test_commands.runNeighbors(&.{ "tinykg", "neighbors", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("neighbors\n", writer.buffer.items);
    try TestOps.expectSteps(&.{
        .parse_neighbors,
        .init,
        .render_neighbors,
        .repair,
        .render_neighbors,
        .deinit,
    });

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    TestOps.next_failure = error.InvalidRecord;
    try test_commands.runIncoming(&.{ "tinykg", "incoming", "1" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("incoming\n", writer.buffer.items);
    try TestOps.expectSteps(&.{
        .parse_incoming,
        .init,
        .render_incoming,
        .repair,
        .render_incoming,
        .deinit,
    });
}

test "graph traversal command family does not repair non-recoverable failures" {
    TestOps.reset();
    TestOps.next_failure = error.BudgetExceeded;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.BudgetExceeded,
        test_commands.runPath(&.{ "tinykg", "path", "1", "2" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{ .parse_path, .init, .render_path, .deinit });
}

test "graph traversal command arguments fail before context acquisition" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidNodeId,
        test_commands.runNeighbors(&.{ "tinykg", "neighbors", "parse-error" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{.parse_neighbors});
}

test "graph traversal command context closes after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runIncoming(&.{ "tinykg", "incoming", "1" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .parse_incoming, .init, .render_incoming, .deinit });
}
