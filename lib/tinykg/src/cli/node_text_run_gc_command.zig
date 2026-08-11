const std = @import("std");

/// Node-text run garbage-collection command control plane.
///
/// Concrete database-path probing, CLI locking, Store/result identities,
/// manifest/process-lease selection and pin-safe deletion stay behind `Ops`.
/// This owner preserves zero-rest syntax, exactly one lease-aware collection,
/// success-only output and reverse cleanup. A writer failure may occur after
/// the destructive operation has committed and does not imply rollback.
pub fn NodeTextRunGcCommand(comptime Ops: type) type {
    return struct {
        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseDbArguments(allocator, io, args, 0, 0);
            var context = try Ops.Context.init(allocator, io, parsed.db_path);
            defer context.deinit();

            const result = try context.gc();
            try writer.print(
                "node_text_runs_gc deleted_runs={} deleted_manifests={}\n",
                .{ result.deleted_runs, result.deleted_manifests },
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
        TestOps.record(.write);
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.buffer.appendSlice(self.allocator, rendered);
    }
};

const FailingWriter = struct {
    fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        TestOps.record(.write);
        return error.OutputClosed;
    }
};

const TestOps = struct {
    const Parsed = struct {
        db_path: []const u8,
        rest: []const []const u8,
    };

    const GcResult = struct {
        deleted_runs: u64 = 13,
        deleted_manifests: u64 = 17,
    };

    const Step = enum {
        parse,
        context_init,
        gc,
        write,
        context_deinit,
    };

    var steps: [16]Step = undefined;
    var step_count: usize = 0;
    var parse_error: ?anyerror = null;
    var context_error: ?anyerror = null;
    var gc_error: ?anyerror = null;
    var context_live: bool = false;
    var gc_count: usize = 0;
    var last_db_path: []const u8 = "";

    fn reset() void {
        step_count = 0;
        parse_error = null;
        context_error = null;
        gc_error = null;
        context_live = false;
        gc_count = 0;
        last_db_path = "";
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
        min_rest: usize,
        max_rest: usize,
    ) !Parsed {
        record(.parse);
        if (parse_error) |err| return err;
        if (args.len < 2) return error.MissingArgument;

        var db_path: []const u8 = "default.kg";
        var rest = args[2..];
        if (rest.len != 0 and std.mem.eql(u8, rest[0], "explicit.kg")) {
            db_path = rest[0];
            rest = rest[1..];
        }
        if (rest.len < min_rest) return error.MissingArgument;
        if (rest.len > max_rest) return error.TooManyArguments;
        return .{ .db_path = db_path, .rest = rest };
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !Context {
            record(.context_init);
            last_db_path = db_path;
            if (context_error) |err| return err;
            std.debug.assert(!context_live);
            context_live = true;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            std.debug.assert(context_live);
            record(.context_deinit);
            context_live = false;
        }

        pub fn gc(_: *Context) !GcResult {
            std.debug.assert(context_live);
            record(.gc);
            gc_count += 1;
            if (gc_error) |err| return err;
            return .{};
        }
    };
};

const node_text_run_gc_command = NodeTextRunGcCommand(TestOps);

test "node text run gc preserves default and explicit database ownership" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try node_text_run_gc_command.run(
        &.{ "tinykg", "gc-node-text-runs" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .gc, .write, .context_deinit });
    try std.testing.expectEqualStrings("default.kg", TestOps.last_db_path);

    TestOps.reset();
    writer.buffer.clearRetainingCapacity();
    try node_text_run_gc_command.run(
        &.{ "tinykg", "gc-node-text-runs", "explicit.kg" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .gc, .write, .context_deinit });
    try std.testing.expectEqualStrings("explicit.kg", TestOps.last_db_path);
}

test "node text run gc rejects extra arguments before context" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        node_text_run_gc_command.run(
            &.{ "tinykg", "gc-node-text-runs", "extra" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{.parse});
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "node text run gc executes once and publishes stable receipt" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    try node_text_run_gc_command.run(
        &.{ "tinykg", "gc-node-text-runs" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .gc, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.gc_count);
    try std.testing.expectEqualStrings(
        "node_text_runs_gc deleted_runs=13 deleted_manifests=17\n",
        writer.buffer.items,
    );
}

test "node text run gc failures preserve cleanup and committed writer boundary" {
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    TestOps.reset();
    TestOps.parse_error = error.InvalidRecord;
    try std.testing.expectError(
        error.InvalidRecord,
        node_text_run_gc_command.run(
            &.{ "tinykg", "gc-node-text-runs" },
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
        node_text_run_gc_command.run(
            &.{ "tinykg", "gc-node-text-runs" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .context_init });
    try std.testing.expect(!TestOps.context_live);

    TestOps.reset();
    TestOps.gc_error = error.AccessDenied;
    try std.testing.expectError(
        error.AccessDenied,
        node_text_run_gc_command.run(
            &.{ "tinykg", "gc-node-text-runs" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .gc, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.gc_count);
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);

    TestOps.reset();
    var failing_writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        node_text_run_gc_command.run(
            &.{ "tinykg", "gc-node-text-runs" },
            &failing_writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .parse, .context_init, .gc, .write, .context_deinit });
    try std.testing.expectEqual(@as(usize, 1), TestOps.gc_count);
    try std.testing.expect(!TestOps.context_live);
}
