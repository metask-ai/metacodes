const std = @import("std");

/// Bounded context-retrieval CLI control plane.
///
/// Concrete argument, Store, retained-reader, search, task, graph, and
/// Markdown representations stay behind `Ops`. This owner keeps
/// `context-plan` and `context-packet` on explicit argument/context lifetimes,
/// retries one recoverable persistent-index read, and publishes JSON only
/// after the complete plan or packet has been rendered successfully.
pub fn ContextCommands(comptime Ops: type) type {
    return struct {
        fn retryable(err: anyerror) bool {
            return switch (err) {
                error.FileNotFound, error.InvalidRecord => true,
                else => false,
            };
        }

        pub fn runPlan(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseArguments(allocator, io, args);
            defer Ops.deinitArguments(allocator, parsed);
            var context = try Ops.PlanContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const output = context.render(allocator, parsed) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.render(allocator, parsed);
            };
            defer allocator.free(output);
            try writer.writeAll(output);
        }

        pub fn runPacket(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseArguments(allocator, io, args);
            defer Ops.deinitArguments(allocator, parsed);
            var context = try Ops.PacketContext.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const output = context.render(allocator, parsed) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.render(allocator, parsed);
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
        parse,
        init_plan,
        init_packet,
        render_plan,
        render_packet,
        repair_plan,
        repair_packet,
        deinit_plan,
        deinit_packet,
        deinit_arguments,
    };

    pub const Arguments = struct {
        db_path: []const u8,
        query: []u8,
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

    pub fn parseArguments(
        allocator: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
    ) !Arguments {
        record(.parse);
        if (args.len > 2 and std.mem.eql(u8, args[2], "parse-error")) return error.InvalidLimit;
        return .{ .db_path = "db", .query = try allocator.dupe(u8, "query") };
    }

    pub fn deinitArguments(allocator: std.mem.Allocator, parsed: Arguments) void {
        record(.deinit_arguments);
        allocator.free(parsed.query);
    }

    fn render(allocator: std.mem.Allocator, output: []const u8, step: Step) ![]u8 {
        record(step);
        if (next_failure) |err| {
            next_failure = null;
            return err;
        }
        return allocator.dupe(u8, output);
    }

    pub const PlanContext = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !PlanContext {
            TestOps.record(.init_plan);
            return .{};
        }

        pub fn deinit(_: *PlanContext) void {
            TestOps.record(.deinit_plan);
        }

        pub fn repair(_: *PlanContext) !void {
            TestOps.record(.repair_plan);
        }

        pub fn render(_: *PlanContext, allocator: std.mem.Allocator, _: Arguments) ![]u8 {
            return TestOps.render(allocator, "{\"kind\":\"context-plan\"}\n", .render_plan);
        }
    };

    pub const PacketContext = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !PacketContext {
            TestOps.record(.init_packet);
            return .{};
        }

        pub fn deinit(_: *PacketContext) void {
            TestOps.record(.deinit_packet);
        }

        pub fn repair(_: *PacketContext) !void {
            TestOps.record(.repair_packet);
        }

        pub fn render(_: *PacketContext, allocator: std.mem.Allocator, _: Arguments) ![]u8 {
            return TestOps.render(allocator, "{\"kind\":\"context-packet\"}\n", .render_packet);
        }
    };
};

const test_commands = ContextCommands(TestOps);

test "context command family owns argument and distinct read-context lifetimes" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try test_commands.runPlan(&.{ "tinykg", "context-plan", "query" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("{\"kind\":\"context-plan\"}\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse, .init_plan, .render_plan, .deinit_plan, .deinit_arguments });

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try test_commands.runPacket(&.{ "tinykg", "context-packet", "query" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("{\"kind\":\"context-packet\"}\n", writer.buffer.items);
    try TestOps.expectSteps(&.{ .parse, .init_packet, .render_packet, .deinit_packet, .deinit_arguments });
}

test "context command family repairs one recoverable read before publishing output" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.next_failure = error.FileNotFound;
    try test_commands.runPlan(&.{ "tinykg", "context-plan", "query" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("{\"kind\":\"context-plan\"}\n", writer.buffer.items);
    try TestOps.expectSteps(&.{
        .parse,
        .init_plan,
        .render_plan,
        .repair_plan,
        .render_plan,
        .deinit_plan,
        .deinit_arguments,
    });

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    TestOps.next_failure = error.InvalidRecord;
    try test_commands.runPacket(&.{ "tinykg", "context-packet", "query" }, &writer, std.testing.allocator, std.testing.io);
    try std.testing.expectEqualStrings("{\"kind\":\"context-packet\"}\n", writer.buffer.items);
    try TestOps.expectSteps(&.{
        .parse,
        .init_packet,
        .render_packet,
        .repair_packet,
        .render_packet,
        .deinit_packet,
        .deinit_arguments,
    });
}

test "context command family does not repair or publish non-recoverable failures" {
    TestOps.reset();
    TestOps.next_failure = error.BudgetExceeded;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.BudgetExceeded,
        test_commands.runPacket(&.{ "tinykg", "context-packet", "query" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{ .parse, .init_packet, .render_packet, .deinit_packet, .deinit_arguments });
}

test "context command arguments fail before context acquisition" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidLimit,
        test_commands.runPlan(&.{ "tinykg", "context-plan", "parse-error" }, &writer, std.testing.allocator, std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
    try TestOps.expectSteps(&.{.parse});
}

test "context command lifetimes close after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_commands.runPacket(&.{ "tinykg", "context-packet", "query" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .parse, .init_packet, .render_packet, .deinit_packet, .deinit_arguments });
}
