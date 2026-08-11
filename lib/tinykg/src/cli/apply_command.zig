const std = @import("std");

/// Explicit-id `apply` command control plane.
///
/// Concrete database-path ambiguity, Store locking, effective-schema loading,
/// JSONL parsing, idempotence/conflict checks, endpoint validation and appends
/// stay behind `Ops`. This owner keeps parse-before-context ordering, one
/// exclusive Store/schema context, one ordered batch execution, stable
/// success-only receipt publication and cleanup together. It does not imply
/// transactional rollback for records accepted before a later batch failure.
pub fn ApplyCommand(comptime Ops: type) type {
    return struct {
        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseDbArguments(allocator, io, args);
            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();

            const result = try context.execute(parsed.batch_path);
            try writer.print(
                "apply version={} nodes_created={} nodes_existing={} edges_created={} edges_existing={}\n",
                .{
                    result.version,
                    result.nodes_created,
                    result.nodes_existing,
                    result.edges_created,
                    result.edges_existing,
                },
            );
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
        std.debug.assert(TestOps.context_live);
        TestOps.record(.write);
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        std.debug.assert(TestOps.context_live);
        TestOps.record(.write);
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Step = enum {
        parse,
        context_init,
        execute,
        write,
        context_deinit,
    };

    const Parsed = struct {
        db_path: []const u8,
        batch_path: []const u8,
    };

    const Result = struct {
        version: u16,
        nodes_created: usize,
        nodes_existing: usize,
        edges_created: usize,
        edges_existing: usize,
    };

    var steps: [16]Step = undefined;
    var step_count: usize = 0;
    var parse_error: ?anyerror = null;
    var context_error: ?anyerror = null;
    var execute_error: ?anyerror = null;
    var context_live = false;
    var expected_db_path: []const u8 = "default.kg";
    var expected_batch_path: []const u8 = "batch.jsonl";
    var execution_count: usize = 0;

    fn reset() void {
        step_count = 0;
        parse_error = null;
        context_error = null;
        execute_error = null;
        context_live = false;
        expected_db_path = "default.kg";
        expected_batch_path = "batch.jsonl";
        execution_count = 0;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn parseDbArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
    ) !Parsed {
        record(.parse);
        if (parse_error) |err| return err;
        if (args.len < 3) return error.MissingArgument;
        if (args.len == 3) {
            return .{ .db_path = "default.kg", .batch_path = args[2] };
        }
        if (args.len == 4) {
            return .{ .db_path = args[2], .batch_path = args[3] };
        }
        return error.TooManyArguments;
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !Context {
            TestOps.record(.context_init);
            try std.testing.expectEqualStrings(TestOps.expected_db_path, db_path);
            if (TestOps.context_error) |err| return err;
            TestOps.context_live = true;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.context_deinit);
            TestOps.context_live = false;
        }

        pub fn execute(_: *Context, batch_path: []const u8) !Result {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.execute);
            TestOps.execution_count += 1;
            try std.testing.expectEqualStrings(TestOps.expected_batch_path, batch_path);
            if (TestOps.execute_error) |err| return err;
            return .{
                .version = 1,
                .nodes_created = 2,
                .nodes_existing = 3,
                .edges_created = 5,
                .edges_existing = 7,
            };
        }
    };
};

const test_command = ApplyCommand(TestOps);

test "apply arguments preserve default and explicit database ownership" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "apply", "batch.jsonl" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .execute, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.execution_count);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    TestOps.expected_db_path = "explicit.kg";
    try test_command.run(
        &.{ "tinykg", "apply", "explicit.kg", "batch.jsonl" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .execute, .write, .context_deinit });
}

test "apply arguments reject missing and extra values before context" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.MissingArgument,
        test_command.run(&.{ "tinykg", "apply" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{.parse});
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        test_command.run(
            &.{ "tinykg", "apply", "explicit.kg", "batch.jsonl", "extra" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse});
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "apply command opens one context executes once and publishes stable receipt" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "apply", "batch.jsonl" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .execute, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.execution_count);
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqualStrings(
        "apply version=1 nodes_created=2 nodes_existing=3 edges_created=5 edges_existing=7\n",
        writer.buffer.items,
    );
}

test "apply command propagates parse and context failures without output" {
    TestOps.reset();
    TestOps.parse_error = error.InvalidRecord;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidRecord,
        test_command.run(
            &.{ "tinykg", "apply", "batch.jsonl" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse});

    TestOps.reset();
    TestOps.context_error = error.FileNotFound;
    try std.testing.expectError(
        error.FileNotFound,
        test_command.run(
            &.{ "tinykg", "apply", "batch.jsonl" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .context_init });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "apply command closes context after execution failure without output" {
    TestOps.reset();
    TestOps.execute_error = error.SchemaEndpointViolation;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.SchemaEndpointViolation,
        test_command.run(
            &.{ "tinykg", "apply", "batch.jsonl" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .execute, .context_deinit });
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "apply command closes context after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(
            &.{ "tinykg", "apply", "batch.jsonl" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .execute, .write, .context_deinit });
    try std.testing.expect(!TestOps.context_live);
}
