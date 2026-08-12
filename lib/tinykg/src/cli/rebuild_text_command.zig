const std = @import("std");

/// `rebuild-text` derived-index maintenance control plane.
///
/// Concrete Store locking/opening, persistent text catalog bytes and durable
/// publication stay behind `Ops.Context`. This owner keeps path admission
/// ahead of timing and effects, starts elapsed accounting before lock wait,
/// retains the exclusive context through result publication, and emits output
/// only after one successful catalog rebuild.
pub fn RebuildTextCommand(comptime Ops: type) type {
    return struct {
        fn parseDbPath(args: []const []const u8, index: usize) ![]const u8 {
            if (args.len <= index) return Ops.defaultPath();
            if (args.len == index + 1) return args[index];
            return error.TooManyArguments;
        }

        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const db_path = try parseDbPath(args, 2);
            const start_ns = Ops.startTimer(io);
            var context = try Ops.Context.init(allocator, io, db_path);
            defer context.deinit();

            const result = try context.rebuild();
            const elapsed_ns = Ops.elapsedSince(io, start_ns);
            try writer.print(
                "rebuild_text db={s} doc_count={} total_text_tokens={} term_count={} term_bytes={} posting_count={} elapsed_ns={}\n",
                .{
                    db_path,
                    result.doc_count,
                    result.total_text_tokens,
                    result.term_count,
                    result.term_bytes,
                    result.posting_count,
                    elapsed_ns,
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
        default_path,
        start_timer,
        context_init,
        rebuild,
        elapsed,
        write,
        context_deinit,
    };

    const Result = struct {
        doc_count: u64,
        total_text_tokens: u64,
        term_count: u64,
        term_bytes: u64,
        posting_count: u64,
    };

    var steps: [16]Step = undefined;
    var step_count: usize = 0;
    var expected_path: []const u8 = "default.kg";
    var context_error: ?anyerror = null;
    var rebuild_error: ?anyerror = null;
    var context_live: bool = false;
    var elapsed_start_ns: u128 = 0;

    fn reset() void {
        step_count = 0;
        expected_path = "default.kg";
        context_error = null;
        rebuild_error = null;
        context_live = false;
        elapsed_start_ns = 0;
    }

    fn record(step: Step) void {
        steps[step_count] = step;
        step_count += 1;
    }

    fn expectSteps(expected: []const Step) !void {
        try std.testing.expectEqualSlices(Step, expected, steps[0..step_count]);
    }

    pub fn defaultPath() []const u8 {
        record(.default_path);
        return "default.kg";
    }

    pub fn startTimer(_: std.Io) u128 {
        record(.start_timer);
        return 101;
    }

    pub fn elapsedSince(_: std.Io, start_ns: u128) u128 {
        record(.elapsed);
        elapsed_start_ns = start_ns;
        return 23;
    }

    pub const Context = struct {
        pub fn init(_: std.mem.Allocator, _: std.Io, db_path: []const u8) !Context {
            TestOps.record(.context_init);
            try std.testing.expectEqualStrings(TestOps.expected_path, db_path);
            if (TestOps.context_error) |err| return err;
            TestOps.context_live = true;
            return .{};
        }

        pub fn deinit(_: *Context) void {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.context_deinit);
            TestOps.context_live = false;
        }

        pub fn rebuild(_: *Context) !Result {
            std.debug.assert(TestOps.context_live);
            TestOps.record(.rebuild);
            if (TestOps.rebuild_error) |err| return err;
            return .{
                .doc_count = 7,
                .total_text_tokens = 31,
                .term_count = 11,
                .term_bytes = 47,
                .posting_count = 19,
            };
        }
    };
};

const rebuild_text_command = RebuildTextCommand(TestOps);

test "rebuild text command starts timing before context and publishes exact metrics" {
    TestOps.reset();
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try rebuild_text_command.run(
        &.{ "tinykg", "rebuild-text" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{
        .default_path,
        .start_timer,
        .context_init,
        .rebuild,
        .elapsed,
        .write,
        .context_deinit,
    });
    try std.testing.expectEqual(@as(u128, 101), TestOps.elapsed_start_ns);
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqualStrings(
        "rebuild_text db=default.kg doc_count=7 total_text_tokens=31 term_count=11 term_bytes=47 posting_count=19 elapsed_ns=23\n",
        writer.buffer.items,
    );
}

test "rebuild text command accepts explicit path and rejects extras before timing" {
    TestOps.reset();
    TestOps.expected_path = "explicit.kg";
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try rebuild_text_command.run(
        &.{ "tinykg", "rebuild-text", "explicit.kg" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );
    try TestOps.expectSteps(&.{
        .start_timer,
        .context_init,
        .rebuild,
        .elapsed,
        .write,
        .context_deinit,
    });

    TestOps.reset();
    try std.testing.expectError(
        error.TooManyArguments,
        rebuild_text_command.run(
            &.{ "tinykg", "rebuild-text", "one.kg", "two.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{});
}

test "rebuild text command propagates context creation failure without cleanup" {
    TestOps.reset();
    TestOps.expected_path = "locked.kg";
    TestOps.context_error = error.LockUnavailable;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.LockUnavailable,
        rebuild_text_command.run(
            &.{ "tinykg", "rebuild-text", "locked.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .start_timer, .context_init });
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "rebuild text command closes context after rebuild failure" {
    TestOps.reset();
    TestOps.expected_path = "broken.kg";
    TestOps.rebuild_error = error.CatalogWriteFailed;
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.CatalogWriteFailed,
        rebuild_text_command.run(
            &.{ "tinykg", "rebuild-text", "broken.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{ .start_timer, .context_init, .rebuild, .context_deinit });
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "rebuild text command captures elapsed before writer and closes context after writer failure" {
    TestOps.reset();
    TestOps.expected_path = "writer-failure.kg";
    var writer = FailingWriter{};

    try std.testing.expectError(
        error.OutputClosed,
        rebuild_text_command.run(
            &.{ "tinykg", "rebuild-text", "writer-failure.kg" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try TestOps.expectSteps(&.{
        .start_timer,
        .context_init,
        .rebuild,
        .elapsed,
        .write,
        .context_deinit,
    });
    try std.testing.expectEqual(@as(u128, 101), TestOps.elapsed_start_ns);
    try std.testing.expect(!TestOps.context_live);
}
