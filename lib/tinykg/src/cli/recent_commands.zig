const std = @import("std");

/// `list-recent` CLI control plane.
///
/// Concrete node-kind, Store, project traversal, tombstone, and TSV rendering
/// representations stay behind `Ops`. This owner keeps option parsing ahead of
/// context acquisition, retries one recoverable persistent-index read, and
/// publishes output only after the complete recent-node snapshot is rendered.
pub fn RecentCommands(comptime Ops: type) type {
    return struct {
        pub const Arguments = struct {
            db_path: []const u8,
            project: ?[]const u8 = null,
            kind_filter: ?Ops.NodeKind = null,
            limit: usize = 20,
            with_type: bool = false,
        };

        pub fn parseArguments(
            allocator: std.mem.Allocator,
            io: std.Io,
            args: []const []const u8,
        ) !Arguments {
            const parsed = try Ops.parseDbArguments(allocator, io, args, 0, std.math.maxInt(usize));
            var result = Arguments{ .db_path = parsed.db_path };
            var index: usize = 0;
            while (index < parsed.rest.len) {
                const option = parsed.rest[index];
                if (std.mem.eql(u8, option, "--with-type")) {
                    result.with_type = true;
                    index += 1;
                    continue;
                }
                if (index + 1 >= parsed.rest.len) return error.MissingArgument;
                const value = parsed.rest[index + 1];
                if (std.mem.eql(u8, option, "--project")) {
                    result.project = value;
                } else if (std.mem.eql(u8, option, "--kind")) {
                    result.kind_filter = Ops.parseNodeKind(value) orelse return error.InvalidNodeKind;
                } else if (std.mem.eql(u8, option, "--limit")) {
                    result.limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
                    if (result.limit > Ops.maxResults()) return error.InvalidLimit;
                } else {
                    return error.UnknownOption;
                }
                index += 2;
            }
            return result;
        }

        fn retryable(err: anyerror) bool {
            return switch (err) {
                error.FileNotFound, error.InvalidRecord => true,
                else => false,
            };
        }

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseArguments(allocator, io, args);
            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();
            const output = context.render(
                allocator,
                parsed.project,
                parsed.kind_filter,
                parsed.limit,
                parsed.with_type,
            ) catch |err| retry: {
                if (!retryable(err)) return err;
                try context.repair();
                break :retry try context.render(
                    allocator,
                    parsed.project,
                    parsed.kind_filter,
                    parsed.limit,
                    parsed.with_type,
                );
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
    pub const NodeKind = enum {
        observation,
        decision,
    };

    const Step = enum {
        parse_db,
        parse_kind,
        init,
        render,
        repair,
        deinit,
    };

    var steps: [24]Step = undefined;
    var step_count: usize = 0;
    var next_failure: ?anyerror = null;
    var failures_remaining: usize = 0;
    var last_project: ?[]const u8 = null;
    var last_kind: ?NodeKind = null;
    var last_limit: usize = 0;
    var last_with_type: bool = false;

    fn reset() void {
        step_count = 0;
        next_failure = null;
        failures_remaining = 0;
        last_project = null;
        last_kind = null;
        last_limit = 0;
        last_with_type = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn maxResults() usize {
        return 100;
    }

    pub fn parseDbArguments(
        _: std.mem.Allocator,
        _: std.Io,
        args: []const []const u8,
        min_rest: usize,
        _: usize,
    ) !struct { db_path: []const u8, rest: []const []const u8 } {
        record(.parse_db);
        if (args.len < 2 or args.len - 2 < min_rest) return error.MissingArgument;
        return .{ .db_path = "db", .rest = args[2..] };
    }

    pub fn parseNodeKind(value: []const u8) ?NodeKind {
        record(.parse_kind);
        return std.meta.stringToEnum(NodeKind, value);
    }

    fn maybeFail() !void {
        if (next_failure) |err| {
            if (failures_remaining != 0) {
                failures_remaining -= 1;
                return err;
            }
        }
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, _: []const u8) !Context {
            TestOps.record(.init);
            return .{};
        }

        pub fn deinit(_: *Context) void {
            TestOps.record(.deinit);
        }

        pub fn repair(_: *Context) !void {
            TestOps.record(.repair);
        }

        pub fn render(
            _: *Context,
            allocator: std.mem.Allocator,
            project: ?[]const u8,
            kind_filter: ?NodeKind,
            limit: usize,
            with_type: bool,
        ) ![]u8 {
            TestOps.record(.render);
            try TestOps.maybeFail();
            TestOps.last_project = project;
            TestOps.last_kind = kind_filter;
            TestOps.last_limit = limit;
            TestOps.last_with_type = with_type;
            return allocator.dupe(u8, "recent\n");
        }
    };
};

const test_commands = RecentCommands(TestOps);

test "recent list arguments preserve option overwrites and missing-value priority" {
    TestOps.reset();
    const parsed = try test_commands.parseArguments(
        std.testing.allocator,
        std.testing.io,
        &.{
            "tinykg",
            "list-recent",
            "--project",
            "first",
            "--kind",
            "observation",
            "--limit",
            "9",
            "--with-type",
            "--project",
            "second",
            "--kind",
            "decision",
            "--limit",
            "7",
            "--with-type",
        },
    );
    try std.testing.expectEqualStrings("db", parsed.db_path);
    try std.testing.expectEqualStrings("second", parsed.project.?);
    try std.testing.expectEqual(TestOps.NodeKind.decision, parsed.kind_filter.?);
    try std.testing.expectEqual(@as(usize, 7), parsed.limit);
    try std.testing.expect(parsed.with_type);
    try TestOps.expectSteps(&.{ .parse_db, .parse_kind, .parse_kind });

    TestOps.reset();
    try std.testing.expectError(
        error.MissingArgument,
        test_commands.parseArguments(
            std.testing.allocator,
            std.testing.io,
            &.{ "tinykg", "list-recent", "--unknown" },
        ),
    );
    try TestOps.expectSteps(&.{.parse_db});
}

test "recent list arguments reject invalid kind and bounded limits before context" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try std.testing.expectError(
        error.InvalidNodeKind,
        test_commands.run(
            &.{ "tinykg", "list-recent", "--kind", "unknown" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse_db, .parse_kind });

    TestOps.reset();
    try std.testing.expectError(
        error.InvalidLimit,
        test_commands.run(
            &.{ "tinykg", "list-recent", "--limit", "101" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse_db});
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "recent list command owns context repair and complete output publication" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.next_failure = error.FileNotFound;
    TestOps.failures_remaining = 1;
    try test_commands.run(
        &.{ "tinykg", "list-recent", "--project", "42", "--kind", "decision", "--limit", "7", "--with-type" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try std.testing.expectEqualStrings("recent\n", writer.buffer.items);
    try std.testing.expectEqualStrings("42", TestOps.last_project.?);
    try std.testing.expectEqual(TestOps.NodeKind.decision, TestOps.last_kind.?);
    try std.testing.expectEqual(@as(usize, 7), TestOps.last_limit);
    try std.testing.expect(TestOps.last_with_type);
    try TestOps.expectSteps(&.{ .parse_db, .parse_kind, .init, .render, .repair, .render, .deinit });
}

test "recent list command does not repair or publish non-recoverable failures" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.next_failure = error.BudgetExceeded;
    TestOps.failures_remaining = 1;
    try std.testing.expectError(
        error.BudgetExceeded,
        test_commands.run(&.{ "tinykg", "list-recent" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .parse_db, .init, .render, .deinit });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);

    TestOps.reset();
    TestOps.next_failure = error.InvalidRecord;
    TestOps.failures_remaining = 2;
    try std.testing.expectError(
        error.InvalidRecord,
        test_commands.run(&.{ "tinykg", "list-recent" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .parse_db, .init, .render, .repair, .render, .deinit });
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "recent list command closes context after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_commands.run(&.{ "tinykg", "list-recent" }, &writer, std.testing.allocator, std.testing.io),
    );
    try TestOps.expectSteps(&.{ .parse_db, .init, .render, .deinit });
}
