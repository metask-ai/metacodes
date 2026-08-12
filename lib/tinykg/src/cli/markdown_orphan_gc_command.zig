const std = @import("std");

/// `gc-md-orphans` destructive-maintenance command control plane.
///
/// Concrete Store locking, graph snapshots, managed-node classification,
/// deletion, index repair and persisted representations stay behind
/// `Ops.Context`. This owner keeps the current database/`--apply` grammar,
/// parse-before-context ordering, one exclusive context, one GC operation,
/// stable receipt publication and cleanup together. Markdown import, render
/// and general lifecycle maintenance intentionally remain separate protocols.
pub fn MarkdownOrphanGcCommand(comptime Ops: type) type {
    return struct {
        pub const Arguments = struct {
            db_path: []const u8,
            apply: bool = false,
        };

        pub fn parseArguments(args: []const []const u8) !Arguments {
            if (args.len < 3) return error.MissingArgument;
            var parsed = Arguments{ .db_path = args[2] };
            var pos: usize = 3;
            while (pos < args.len) {
                const option = args[pos];
                if (std.mem.eql(u8, option, "--apply")) {
                    parsed.apply = true;
                    pos += 1;
                } else if (std.mem.startsWith(u8, option, "--")) {
                    return error.UnknownOption;
                } else {
                    return error.TooManyArguments;
                }
            }
            return parsed;
        }

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try parseArguments(args);
            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();

            const result = try context.execute(parsed.apply);
            try writer.print(
                "md_orphan_gc apply={} candidates={} deleted={} skipped_referenced={} skipped_unmanaged={} elapsed_ns={}\n",
                .{
                    @intFromBool(parsed.apply),
                    result.candidates,
                    result.deleted,
                    result.skipped_referenced,
                    result.skipped_unmanaged,
                    result.elapsed_ns,
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
        context_init,
        execute,
        write,
        context_deinit,
    };

    const Result = struct {
        candidates: usize,
        deleted: usize,
        skipped_referenced: usize,
        skipped_unmanaged: usize,
        elapsed_ns: u128,
    };

    var steps: [16]Step = undefined;
    var step_count: usize = 0;
    var context_live = false;
    var context_error: ?anyerror = null;
    var operation_error: ?anyerror = null;
    var operation_count: usize = 0;
    var last_apply = false;

    fn reset() void {
        step_count = 0;
        context_live = false;
        context_error = null;
        operation_error = null;
        operation_count = 0;
        last_apply = false;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !Context {
            TestOps.record(.context_init);
            try std.testing.expectEqualStrings("memory.kg", db_path);
            if (TestOps.context_error) |err| return err;
            TestOps.context_live = true;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.context_deinit);
            TestOps.context_live = false;
        }

        pub fn execute(_: *Context, apply: bool) !Result {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.execute);
            TestOps.operation_count += 1;
            TestOps.last_apply = apply;
            if (TestOps.operation_error) |err| return err;
            return .{
                .candidates = 7,
                .deleted = if (apply) 5 else 0,
                .skipped_referenced = 11,
                .skipped_unmanaged = 13,
                .elapsed_ns = 17,
            };
        }
    };
};

const test_command = MarkdownOrphanGcCommand(TestOps);

test "markdown orphan gc arguments preserve dry run default and explicit apply" {
    const dry_run = try test_command.parseArguments(&.{ "tinykg", "gc-md-orphans", "memory.kg" });
    try std.testing.expectEqualStrings("memory.kg", dry_run.db_path);
    try std.testing.expect(!dry_run.apply);

    const apply = try test_command.parseArguments(&.{ "tinykg", "gc-md-orphans", "memory.kg", "--apply" });
    try std.testing.expectEqualStrings("memory.kg", apply.db_path);
    try std.testing.expect(apply.apply);
}

test "markdown orphan gc arguments preserve repeated apply idempotence" {
    const parsed = try test_command.parseArguments(&.{
        "tinykg",
        "gc-md-orphans",
        "memory.kg",
        "--apply",
        "--apply",
    });
    try std.testing.expect(parsed.apply);
}

test "markdown orphan gc arguments reject missing unknown and extra values before context" {
    TestOps.reset();
    try std.testing.expectError(error.MissingArgument, test_command.parseArguments(&.{ "tinykg", "gc-md-orphans" }));
    try std.testing.expectError(error.UnknownOption, test_command.parseArguments(&.{ "tinykg", "gc-md-orphans", "memory.kg", "--parent" }));
    try std.testing.expectError(error.TooManyArguments, test_command.parseArguments(&.{ "tinykg", "gc-md-orphans", "memory.kg", "extra" }));

    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(
        error.UnknownOption,
        test_command.run(
            &.{ "tinykg", "gc-md-orphans", "memory.kg", "--unknown" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});
}

test "markdown orphan gc rejects unsupported scope selectors before context" {
    TestOps.reset();
    try std.testing.expectError(
        error.UnknownOption,
        test_command.parseArguments(&.{ "tinykg", "gc-md-orphans", "memory.kg", "--parent", "1" }),
    );
    try std.testing.expectError(
        error.UnknownOption,
        test_command.parseArguments(&.{ "tinykg", "gc-md-orphans", "memory.kg", "--project", "1" }),
    );

    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try std.testing.expectError(
        error.UnknownOption,
        test_command.run(
            &.{ "tinykg", "gc-md-orphans", "memory.kg", "--parent", "1", "--apply" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "markdown orphan gc command opens one context after parsing and publishes stable receipt" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "gc-md-orphans", "memory.kg" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .context_init, .execute, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.operation_count);
    try std.testing.expect(!TestOps.last_apply);
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqualStrings(
        "md_orphan_gc apply=0 candidates=7 deleted=0 skipped_referenced=11 skipped_unmanaged=13 elapsed_ns=17\n",
        writer.buffer.items,
    );
}

test "markdown orphan gc command forwards apply to one operation" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try test_command.run(
        &.{ "tinykg", "gc-md-orphans", "memory.kg", "--apply" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .context_init, .execute, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.operation_count);
    try std.testing.expect(TestOps.last_apply);
    try std.testing.expectEqualStrings(
        "md_orphan_gc apply=1 candidates=7 deleted=5 skipped_referenced=11 skipped_unmanaged=13 elapsed_ns=17\n",
        writer.buffer.items,
    );
}

test "markdown orphan gc command propagates context creation failure without cleanup" {
    TestOps.reset();
    TestOps.context_error = error.LockUnavailable;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.LockUnavailable,
        test_command.run(
            &.{ "tinykg", "gc-md-orphans", "memory.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.context_init});
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqual(@as(usize, 0), TestOps.operation_count);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "markdown orphan gc command closes context after operation failure" {
    TestOps.reset();
    TestOps.operation_error = error.InvalidGraph;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.InvalidGraph,
        test_command.run(
            &.{ "tinykg", "gc-md-orphans", "memory.kg", "--apply" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .context_init, .execute, .context_deinit });
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqual(@as(usize, 1), TestOps.operation_count);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "markdown orphan gc command closes context after writer failure" {
    TestOps.reset();
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        test_command.run(
            &.{ "tinykg", "gc-md-orphans", "memory.kg", "--apply" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .context_init, .execute, .write, .context_deinit });
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqual(@as(usize, 1), TestOps.operation_count);
    try std.testing.expect(TestOps.last_apply);
}
